import Foundation
import AVFoundation
import Combine
import CoreAudio
import Accelerate
import AppKit
import QuartzCore
import SwiftUI
import os

/// Controls the physical-RAM-scaled sliding window of resident decoded song PCM buffers.
public struct MemoryWindowPolicy: Equatable, Sendable {
    public let maxResidentSongs: Int
    public let softPCMByteBudget: Int64

    public init(maxResidentSongs: Int, softPCMByteBudget: Int64) {
        self.maxResidentSongs = maxResidentSongs
        self.softPCMByteBudget = softPCMByteBudget
    }

    public static func forPhysicalMemory(_ bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryWindowPolicy {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb <= 18.0 {
            // 8 GB / 16 GB Macs: Active + Next + Prev hot in RAM (~3.5 GB soft PCM budget)
            return MemoryWindowPolicy(maxResidentSongs: 3, softPCMByteBudget: 3_500_000_000)
        } else if gb <= 36.0 {
            // 24 GB / 32 GB Macs: 6-song sliding window (~8 GB soft PCM budget)
            return MemoryWindowPolicy(maxResidentSongs: 6, softPCMByteBudget: 8_000_000_000)
        } else {
            // 48 GB+ Macs: 12-song sliding window (~18 GB soft PCM budget)
            return MemoryWindowPolicy(maxResidentSongs: 12, softPCMByteBudget: 18_000_000_000)
        }
    }
}

public enum SessionStorageLocation: String, Equatable, Sendable {
    case cloud = "Cloud"
    case local = "Local"
    case unsaved = "Unsaved"
}

/// Core multitrack audio engine managing sample-accurate 26+ track synchronized playback, bussing, and transport
@MainActor
public final class MultitrackAudioEngine: ObservableObject {

    public nonisolated static func sessionStorageLocation(
        for sessionURL: URL?,
        cloudRootURL: URL?
    ) -> SessionStorageLocation {
        guard let url = sessionURL else { return .unsaved }
        if let cloudRoot = cloudRootURL {
            let rootPath = cloudRoot.standardizedFileURL.path
            let targetPath = url.standardizedFileURL.path
            let normalizedPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return (targetPath == rootPath || targetPath.hasPrefix(normalizedPrefix)) ? .cloud : .local
        }
        return LibraryBrowserManager.isURLInCloudLibrary(url) ? .cloud : .local
    }

    public var currentSessionStorageLocation: SessionStorageLocation {
        Self.sessionStorageLocation(
            for: currentSessionURL,
            cloudRootURL: LibraryBrowserManager.shared.cloudRootURL
        )
    }

    public func activeSessionSongAndTrackIds() -> (songIds: Set<UUID>, trackIds: Set<UUID>) {
        var songIds = Set(currentSetlist.songs.map(\.id))
        songIds.insert(currentSong.id)
        var trackIds = Set(tracks.map(\.id))
        for (_, items) in songBuffersCache {
            for item in items {
                trackIds.insert(item.track.id)
            }
        }
        for (_, backupTracks) in songTrackMetadataBackup {
            for tr in backupTracks {
                trackIds.insert(tr.id)
            }
        }
        return (songIds, trackIds)
    }
    
    // MARK: - Published Properties
    @Published public internal(set) var tracks: [StemTrack] = []
    @Published public internal(set) var playbackState: PlaybackState = .stopped {
        didSet {
            if playbackState != oldValue {
                LibraryBrowserManager.shared.setPlaybackActive(playbackState == .playing)
            }
        }
    }
    public internal(set) var transportPosition: TransportPosition = TransportPosition()
    public let transportClock = TransportClockModel()
    public let transportDisplayClock = TransportDisplayClockModel()
    @Published public internal(set) var aggregateWaveform: [Float] = []
    @Published public internal(set) var renderedWaveformImage: NSImage?
    @Published public internal(set) var waveformVersion: UInt64 = 0
    public internal(set) var masterWaveformPeaks: [Float] = []
    public internal(set) var soloWaveformPeaks: [Float]? = nil
    private var lastSoloWaveformTrackIds: [UUID] = []
    
    // Master Volume & Busses
    var liveInteractiveMasterVolume: Float? = nil
    var suppressMasterVolumeSessionMark: Bool = false
    var masterVolumeCommitWorkItem: DispatchWorkItem? = nil

    @Published public var masterVolume: Float = 0.80 { // Defaults to 0.0 dB (80% travel)
        didSet {
            liveInteractiveMasterVolume = nil
            updateMasterVolume()
            if !suppressMasterVolumeSessionMark {
                markSessionChanged()
            }
        }
    }
    @Published public var busses: [AudioBus] = AudioBus.defaultBusses()
    
    public enum MixerMode: String, CaseIterable, Sendable {
        case tracks = "Tracks"
        case busses = "Busses"
        case padPlayer = "Pad Player"
    }
    @Published public var mixerMode: MixerMode = .tracks
    
    // Real-time Master VU Meter Levels (isolated into `masterMeter` so MainView/MasterMixerControlView never re-evaluate on meter ticks)
    public let masterMeter = StereoMeterModel()
    public var masterPeakLeft: Float = 0.0
    public var masterPeakRight: Float = 0.0
    var rawMasterPeakL: Float = 0.0
    var rawMasterPeakR: Float = 0.0
    var uiFallbackTimer: Timer?
    var uiDisplayLink: CADisplayLink?
    var uiDisplayLinkProxy: DisplayLinkTickProxy?
    var uiDisplayLinkScreenNumber: CGDirectDisplayID?
    var transportWatchdogTimer: DispatchSourceTimer?
    var lastPlaybackClockTickTimestamp: CFTimeInterval = 0
    var playbackActivityToken: NSObjectProtocol?
    var memoryPressureSource: DispatchSourceMemoryPressure?
    @Published public internal(set) var cachedEffectiveBeatGrid: [BeatGridMarker] = []
    @Published public internal(set) var beatGridVersion: UInt64 = 0
    public internal(set) var precomputedDownbeatMarkers: [BeatGridMarker] = []
    public internal(set) var precomputedSubdivisionMarkers: [BeatGridMarker] = []
    var cachedActiveAutomation: [(point: AutomationPoint, startSec: TimeInterval)] = []

    /// Rebuilds pre-computed beat & downbeat marker arrays once on song load/tempo change so timeline Canvas never filters `beatGrid` per frame.
    @Published public var isFadedOut: Bool = false
    @Published public var isFadeActive: Bool = false
    @Published public var fadeInDuration: TimeInterval = 5.0
    @Published public var fadeOutDuration: TimeInterval = 5.0
    public var preFadeVolumes: [UUID: Float] = [:]
    public var songEndBaseVolumes: [UUID: Float] = [:]
    @Published public internal(set) var currentFadeGain: Float = 1.0
    
    public enum LoopMode: String, CaseIterable, Sendable {
        case none = "None"
        case single = "Single (1x)"
        case infinite = "Infinite (∞)"
    }
    @Published public var loopMode: LoopMode = .none
    @Published public var isLoopActive: Bool = false
    @Published public var loopedSection: SongSection?
    @Published public var singleLoopRemaining: Int = 0
    @Published public var isPadActive: Bool = false
    @Published public var currentPadKey: String = "C"
    @Published public var isPadLinked: Bool = true
    @Published public var unlinkedKeyID: String? = nil
    /// Temporary pad pack chosen in the Pad Player / Remote without altering the Song Menu's default `padPresetId`.
    @Published public var manualPadPackId: String? = nil
    
    // Click Subdivisions Drawer & Solo Controls
    @Published public var isClickSubdivisionDrawerExpanded: Bool = false
    @Published public var clickSoloedSubdivisions: Set<ClickSubdivision> = []

    // Guide Sub-Channels Drawer & Solo Controls
    @Published public var isGuideSubChannelDrawerExpanded: Bool = false
    @Published public var guideSoloedSubChannels: Set<GuideSubChannel> = []

    public var visibleGuideSubChannels: [GuideSubChannel] {
        GuideSubChannel.visibleChannels(for: currentSong.guideSource)
    }
    
    // Bottom-Right Edit Drawer & Active Edit Mode (MultiTracks Playback Style)
    public enum EditDrawerItem: String, CaseIterable, Sendable {
        case setlistSongMap = "Setlist / Song Map"
        case midiCues = "MIDI Cues"
        case directionalCues = "Directional Cues"
        case automation = "Automation"
        case midiMapping = "MIDI Mapping"
        case keyboardMapping = "Keyboard Mapping"
        case songSections = "Song Sections"
        case smpte = "SMPTE"
    }
    @Published public var isEditDrawerOpen: Bool = false
    @Published public var isEditDrawerCollapsed: Bool = false
    @Published public var selectedEditDrawerItem: EditDrawerItem = .setlistSongMap
    
    // Song Section Edit Mode (Non-destructive Add/Remove Sections)
    @Published public var isEditSectionsMode: Bool = false
    @Published public var isEditingTempoCurve: Bool = false
    
    // Song Map Edit Mode (Adding / Labeling Sections at Playhead)
    @Published public var isEditSongMapMode: Bool = false
    
    // MIDI Cues Edit Mode (Adding / Editing MIDI Cues at Playhead)
    @Published public var isEditMIDICuesMode: Bool = false
    
    // Directional Cues Edit Mode & 16th-Note Nudge State
    @Published public var isEditDirectionalCuesMode: Bool = false
    @Published public var selectedDirectionalCueId: UUID? = nil
    @Published public var isNudgingDirectionalCue: Bool = false
    @Published public var requestedEditDirectionalCueId: UUID? = nil
    
    // Automation Edit Mode & 1-Beat Nudge State
    @Published public var isEditAutomationMode: Bool = false
    @Published public var selectedAutomationPointId: UUID? = nil
    @Published public var isNudgingAutomation: Bool = false
    @Published public var requestedEditAutomationId: UUID? = nil
    
    // MIDI & Keyboard Mapping Mode
    @Published public var isEditMIDIMappingMode: Bool = false {
        didSet {
            MIDIMappingManager.shared.setLearningModeActive(isEditMIDIMappingMode)
        }
    }
    @Published public var isEditKeyboardMappingMode: Bool = false
    @Published public var audioDeviceBannerMessage: String? = nil
    var audioDeviceBannerDismissTask: Task<Void, Never>? = nil
    var hardwareDeviceCancellable: AnyCancellable? = nil
    var padStateCancellable: AnyCancellable? = nil
    var engineConfigObserver: NSObjectProtocol? = nil
    var voiceCloneReadyObserver: NSObjectProtocol? = nil
    var voiceClonePhraseObserver: NSObjectProtocol? = nil
    var guidePreviewGeneration: UInt64 = 0
    var lastAppliedHardwareDeviceID: AudioDeviceID? = nil
    var lastAppliedHardwareChannelCount: Int = 0
    var lastConfiguredSampleRate: Double = 0.0
    var isApplyingHardwareReconfiguration: Bool = false
    var ignoreConfigNotificationsUntil: TimeInterval = 0.0
    @Published public var browsedSectionStartTime: TimeInterval? = nil
    
    // Baseline snapshot for restoring mix when exiting automation editing
    public var baseTrackVolumes: [UUID: Float] = [:]
    public var baseTrackPans: [UUID: Float] = [:]
    public var baseTrackMutes: [UUID: Bool] = [:]
    public var baseBusVolumes: [String: Float] = [:]
    public var baseBusMutes: [String: Bool] = [:]
    public var basePadVolume: Float = 0.80
    public var basePadPan: Float = 0.0
    public var basePadMuted: Bool = false
    public var baseMIDIMuted: Bool = false
    
    /// True when the user is in Automation edit mode AND the playhead is currently positioned on an automation cue
    // MARK: - Redundancy Feature (1kHz Persistent Pilot Tone)
    @Published public var isRedundancyEnabled: Bool = false
    @Published public var redundancyOutputChannel: String = "Out 1"

    // MARK: - SMPTE Timecode Output Feature
    @Published public var isSMPTEEnabled: Bool = false
    @Published public var smpteFrameRate: SMPTEFrameRate = .fps30
    @Published public var smpteOutputChannel: String = "Out 2"

    // MARK: - PeanutButter Remote (5.1 Local Network Control)
    @Published public var isRemoteControlEnabled: Bool = false
    public let remoteServer = RemoteControlServer()

    public func setRemoteControlEnabled(_ enabled: Bool) {
        isRemoteControlEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_RemoteControlEnabled")
        if enabled {
            remoteServer.start()
        } else {
            remoteServer.stop()
        }
    }

    /// Applies a single track's volume directly to the audio render state without rebuilding the full matrix (used by Remote sliders).
    public func applyDirectTrackVolume(_ track: StemTrack) {
        guard let channel = channels[track.id] else { return }
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let res = computeTrackOutputGain(
            track: track,
            channel: channel,
            anyTrackSoloed: anyTrackSoloed,
            anyBusSoloed: anyBusSoloed
        )
        mixState.updateTrackGains(
            trackId: track.id,
            gainL: res.gainL,
            gainR: res.gainR,
            outChannelL: res.outL,
            outChannelR: res.outR
        )
    }

    /// Returns `(StemTrack, AVAudioPCMBuffer)` pairs for offline bouncing of any song in the setlist.
    public func tracksWithBuffersForBounce(song: Song) -> [(track: StemTrack, buffer: AVAudioPCMBuffer)] {
        if song.id == currentSong.id {
            return tracks.compactMap { track in
                if let buf = channels[track.id]?.buffer ?? pristineMasterBuffers[track.id] {
                    return (track, buf)
                }
                return nil
            }
        }
        rehydrateEvictedSongBuffersIfNeeded(for: song)
        if let cached = songBuffersCache[song.id] {
            return cached.map { ($0.0, $0.1) }
        }
        return []
    }
    @Published public var isEditSMPTEMode: Bool = false
    @Published public var isNudgingSMPTECue: Bool = false
    @Published public var requestedEditSMPTECue: Bool = false
    
    // MARK: - Song Section Pre-Roll Feature
    @Published public var isSongSectionPreRollEnabled: Bool = false
    @Published public var sectionPreRollLengthBars: Int = 2
    @Published public var preRollTargetSectionId: UUID? = nil
    @Published public var isBeatFlashing: Bool = false
    
    // MARK: - Global Pad Settings
    @Published public var isGlobalStartPadWithSongEnabled: Bool = false
    
    public func setGlobalStartPadWithSong(_ enabled: Bool) {
        isGlobalStartPadWithSongEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_GlobalStartPadWithSongEnabled")
        objectWillChange.send()
    }

    // MARK: - Global Guide Section Number Settings
    @Published public var isGlobalIncludeGuideSectionNumbersEnabled: Bool = false

    public func setGlobalIncludeGuideSectionNumbers(_ enabled: Bool) {
        isGlobalIncludeGuideSectionNumbersEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        for i in 0..<currentSong.sections.count {
            currentSong.sections[i].includeNumberInGuide = enabled
        }
        for sIdx in 0..<currentSetlist.songs.count {
            for secIdx in 0..<currentSetlist.songs[sIdx].sections.count {
                currentSetlist.songs[sIdx].sections[secIdx].includeNumberInGuide = enabled
            }
        }
        regenerateGuideTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Default Click & Guide Source Preferences
    @Published public var defaultClickSourcePreference: ClickSource = .uploaded
    @Published public var defaultGuideSourcePreference: GuideSource = .uploaded
    
    public func setDefaultClickSourcePreference(_ source: ClickSource) {
        defaultClickSourcePreference = source
        UserDefaults.standard.set(source.rawValue, forKey: "Playback_DefaultClickSource")
        for i in 0..<currentSetlist.songs.count {
            let sid = currentSetlist.songs[i].id
            let target: ClickSource = (source == .uploaded && uploadedClickBuffers[sid] != nil) ? .uploaded : .generated
            currentSetlist.songs[i].clickSource = target
        }
        let curTarget: ClickSource = (source == .uploaded && uploadedClickBuffers[currentSong.id] != nil) ? .uploaded : .generated
        if currentSong.clickSource != curTarget {
            setClickSource(curTarget)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func setDefaultGuideSourcePreference(_ source: GuideSource) {
        defaultGuideSourcePreference = source
        UserDefaults.standard.set(source.rawValue, forKey: "Playback_DefaultGuideSource")
        for i in 0..<currentSetlist.songs.count {
            let sid = currentSetlist.songs[i].id
            let target: GuideSource = (source == .uploaded && uploadedGuideBuffers[sid] != nil) ? .uploaded : .generated
            currentSetlist.songs[i].guideSource = target
        }
        let curTarget: GuideSource = (source == .uploaded && uploadedGuideBuffers[currentSong.id] != nil) ? .uploaded : .generated
        if currentSong.guideSource != curTarget {
            setGuideSource(curTarget)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    

    // MARK: - Channel Faders Default Level
    @Published public var isFadersDefault100Enabled: Bool = false
    
    public var defaultChannelFaderLevel: Float {
        isFadersDefault100Enabled ? 1.0 : 0.80
    }
    
    public func setFadersDefault100(_ enabled: Bool) {
        isFadersDefault100Enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_FadersDefault100")
        for track in tracks {
            track.volume = enabled ? 1.0 : 0.80
        }
        updateMatrix()
        objectWillChange.send()
    }
    
    // Active / Selected MIDI Cue on Timeline & 16th-Note Nudge State
    @Published public var selectedMIDICueId: UUID? = nil
    @Published public var isNudgingMIDICue: Bool = false
    @Published public var requestedEditMIDICueId: UUID? = nil
    
    // MIDI Cue Section Clipboard (relative offsets and metadata)
    public struct CopiedMIDICueItem: Sendable {
        public let relativeTime: TimeInterval // offset from section startTime
        public let bus: MIDIBus
        public let messageType: MIDIMessageType
        public let primaryValue: Int
        public let originalVelocity: Int
        public let disableLoop: Bool
        public let cueDescription: String
    }
    
    @Published public var copiedMIDICuesClipboard: [CopiedMIDICueItem]? = nil
    @Published public var copiedSourceSectionName: String? = nil
    
    // Master MIDI Mute State ("MUTE MIDI" on right toolbar)
    @Published public var isMIDIMuted: Bool = false {
        didSet {
            if playbackState == .playing {
                let activeBPM = currentSong.activeMarker(at: playbackOffsetSeconds)?.instantaneousBPM ?? currentSong.bpm
                MIDICueEngine.shared.syncMIDIClockPlayback(isPlayingAndUnmuted: !isMIDIMuted, bpm: activeBPM, isResume: true)
            } else if isPostSongClickActive {
                MIDICueEngine.shared.syncMIDIClockPlayback(isPlayingAndUnmuted: !isMIDIMuted, bpm: activePostSongClickBPM, isResume: true)
            }
        }
    }
    
    // Section Trim Mode State
    @Published public var trimmingSection: SongSection? = nil
    @Published public var trimLeadingDuration: TimeInterval = 0.0
    @Published public var trimTrailingDuration: TimeInterval = 0.0
    
    struct DisplaySectionsCacheKey: Equatable {
        let songId: UUID
        let sections: [SongSection]
        let bpm: Double
        let timeSigNum: Int
        let timeSigDen: Int
        let isEditing: Bool
    }
    var cachedDisplaySectionsKey: DisplaySectionsCacheKey?
    var cachedDisplaySectionsValue: [SongSection] = []

    public func closeEditMode() {
        if isEditDrawerOpen || isEditingTempoCurve || isEditSectionsMode || isEditSongMapMode || isEditMIDICuesMode || isEditDirectionalCuesMode || isEditAutomationMode || isEditMIDIMappingMode || isEditKeyboardMappingMode || isEditSMPTEMode || trimmingSection != nil {
            isEditDrawerOpen = false
            isEditDrawerCollapsed = false
            isEditingTempoCurve = false
            isEditSectionsMode = false
            isEditSongMapMode = false
            isEditMIDICuesMode = false
            isEditDirectionalCuesMode = false
            isEditAutomationMode = false
            isEditMIDIMappingMode = false
            isEditKeyboardMappingMode = false
            isEditSMPTEMode = false
            isNudgingMIDICue = false
            isNudgingDirectionalCue = false
            isNudgingAutomation = false
            isNudgingSMPTECue = false
            selectedAutomationPointId = nil
            MIDIMappingManager.shared.selectedTargetId = nil
            KeyboardMappingManager.shared.selectedTargetId = nil
            restoreBaseMixSnapshot()
            trimmingSection = nil
            updateArrangementWaveform()
        }
    }
    
    public func toggleEditDrawer() {
        if isEditDrawerOpen {
            closeEditMode()
        } else {
            isEditDrawerOpen = true
            isEditDrawerCollapsed = false
            syncEditModesWithDrawerSelection()
        }
    }
    
    /// Hides the edit drawer drawer UI while maintaining the currently active edit mode
    public func collapseEditDrawer() {
        isEditDrawerCollapsed = true
    }
    
    /// Expands the edit drawer drawer UI back out
    public func expandEditDrawer() {
        isEditDrawerCollapsed = false
    }
    
    public func selectEditDrawerItem(_ item: EditDrawerItem) {
        selectedEditDrawerItem = item
        syncEditModesWithDrawerSelection()
    }
    
    func syncEditModesWithDrawerSelection() {
        // Reset all edit modes first so no lingering mode stays active
        isEditSectionsMode = false
        isEditSongMapMode = false
        isEditMIDICuesMode = false
        isEditDirectionalCuesMode = false
        isEditAutomationMode = false
        isEditMIDIMappingMode = false
        isEditKeyboardMappingMode = false
        isEditSMPTEMode = false
        isNudgingMIDICue = false
        isNudgingDirectionalCue = false
        isNudgingAutomation = false
        isNudgingSMPTECue = false
        MIDIMappingManager.shared.selectedTargetId = nil
        KeyboardMappingManager.shared.selectedTargetId = nil
        
        guard isEditDrawerOpen else {
            isEditingTempoCurve = false
            updateArrangementWaveform()
            return
        }
        if selectedEditDrawerItem != .songSections {
            isEditingTempoCurve = false
        }
        
        switch selectedEditDrawerItem {
        case .setlistSongMap:
            isEditSongMapMode = true
        case .songSections:
            isEditSectionsMode = true
        case .midiCues:
            isEditMIDICuesMode = true
            let activeMidiCues = currentSong.midiCues.filter { !isMIDICueTrimmedOut($0) }.sorted(by: { $0.time < $1.time })
            if selectedMIDICueId == nil || !activeMidiCues.contains(where: { $0.id == selectedMIDICueId }), let first = activeMidiCues.first {
                selectedMIDICueId = first.id
            }
        case .directionalCues:
            isEditDirectionalCuesMode = true
            let activeDirCues = currentSong.directionalCues.filter { !isDirectionalCueTrimmedOut($0) }.sorted(by: { $0.time < $1.time })
            if selectedDirectionalCueId == nil || !activeDirCues.contains(where: { $0.id == selectedDirectionalCueId }), let first = activeDirCues.first {
                selectedDirectionalCueId = first.id
            }
        case .automation:
            isEditAutomationMode = true
            captureBaseMixSnapshot()
            if let pt = automationPoint(at: playbackOffsetSeconds) {
                selectedAutomationPointId = pt.id
                loadAutomationPointValues(id: pt.id)
            } else {
                selectedAutomationPointId = nil
            }
        case .midiMapping:
            isEditMIDIMappingMode = true
            MIDIMappingManager.shared.reconnectAllSources()
        case .keyboardMapping:
            isEditKeyboardMappingMode = true
        case .smpte:
            isEditSMPTEMode = true
        default:
            break
        }
        updateArrangementWaveform()
    }
    
    // Waveform Zoom State (Default 100% = 69% of baseline)
    @Published public var waveformZoomScale: CGFloat = 1.0
    
    // Song & Setlist State (Starts in Blank Session State)
    @Published public var currentSong: Song = Song(
        title: "",
        artist: "",
        bpm: 120.0,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
        musicalKey: "—",
        sections: []
    ) {
        didSet {
            if currentSong.id != oldValue.id ||
               currentSong.beatGrid.count != oldValue.beatGrid.count ||
               currentSong.bpm != oldValue.bpm ||
               currentSong.timeSignatureNumerator != oldValue.timeSignatureNumerator ||
               currentSong.timeSignatureDenominator != oldValue.timeSignatureDenominator ||
               currentSong.timeSignatureChanges != oldValue.timeSignatureChanges ||
               currentSong.tempoEvents != oldValue.tempoEvents ||
               currentSong.sections != oldValue.sections ||
               (precomputedDownbeatMarkers.isEmpty && !currentSong.beatGrid.isEmpty) {
                rebuildPrecomputedBeatGrid()
            }
            if currentSong.id != oldValue.id ||
               currentSong.automationPoints != oldValue.automationPoints ||
               currentSong.sections != oldValue.sections {
                rebuildCachedActiveAutomation()
            }
        }
    }
    
    @Published public var currentSetlist: Setlist = Setlist(
        name: "New Setlist",
        songs: []
    )
    @Published public var currentSessionURL: URL? = nil
    @Published public var currentSessionLoadedModDate: Date? = nil
    @Published public var currentSessionLoadedRevisionId: UUID? = nil
    
    // Unsaved Changes & Cloud Update Tracking (Setlist Menu Indicator Dot)
    @Published public var hasUnsavedChanges: Bool = false
    @Published public var hasCloudSetlistUpdate: Bool = false
    var acknowledgedCloudRevisionIds: Set<UUID> = []
    var acknowledgedCloudModDatesByFileName: [String: Date] = [:]
    @Published public internal(set) var canUndo: Bool = false
    @Published public internal(set) var canRedo: Bool = false
    var undoStack: [SessionUndoSnapshot] = []
    var redoStack: [SessionUndoSnapshot] = []
    var baselineUndoSnapshot: SessionUndoSnapshot? = nil
    var lastUndoCommitTime: TimeInterval = 0
    var isApplyingUndoRedo: Bool = false
    var undoRecentOrphanBuffers: [(trackId: UUID, buffer: AVAudioPCMBuffer)] = []
    var cloudSetlistsCancellable: AnyCancellable? = nil

    @Published public var currentSongIndex: Int = 0
    @Published public var isEngineRunning: Bool = false
    
    // Offline Pre-Rendered Transposition & Tempo-Stretch State
    @Published public var isTransposing: Bool = false
    @Published public var transposeProgress: Float = 0.0
    @Published public var lastTransposeSourceBySong: [UUID: String] = [:]
    @Published public var showTranspositionWarning: Bool = false
    @Published public var showDownloadingWarning: Bool = false
    @Published public var transposingSongId: UUID? = nil
    @Published public var renderStatusText: String = "Transposing..."
    @Published public var transposeProgressBySong: [UUID: Float] = [:]
    @Published public var downloadingSongProgress: [UUID: Double] = [:]
    @Published public var cancelledDownloadSongIds: Set<UUID> = []

    final class CancelledDownloadTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func insert(_ id: UUID) {
            lock.lock()
            ids.insert(id)
            lock.unlock()
        }
        func removeAll() {
            lock.lock()
            ids.removeAll()
            lock.unlock()
        }
        func contains(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }
    }
    nonisolated let cancelledDownloadTracker = CancelledDownloadTracker()

    public nonisolated func isSongDownloadCancelled(_ songId: UUID) -> Bool {
        cancelledDownloadTracker.contains(songId)
    }

    public func cancelSongDownload(songId: UUID) {
        cancelledDownloadTracker.insert(songId)
        cancelledDownloadSongIds.insert(songId)
        downloadingSongProgress.removeValue(forKey: songId)
    }

    func clearCancelledSongDownloads() {
        cancelledDownloadTracker.removeAll()
        cancelledDownloadSongIds.removeAll()
    }
    var pristineMasterBuffers: [UUID: AVAudioPCMBuffer] = [:]
    var transposeTask: Task<Void, Never>?
    var transposeTasksBySong: [UUID: Task<Void, Never>] = [:]
    var transposeTaskTokensBySong: [UUID: UUID] = [:]
    var transposeGeneration: Int = 0
    
    // Automatic Guide Section Labeling State
    @Published public var isAutoLabelingSections: Bool = false
    @Published public var autoLabelProgress: Float = 0.0
    @Published public var autoLabelStatusText: String = ""
    
    // Automatic Click Track Tempo & Dynamic Beat Grid Detection State
    @Published public var isAnalyzingClickTempo: Bool = false
    
    // Dedicated per-division Click VU meters (flash in time with each subdivision)
    public let clickAccentMeter = StereoMeterModel()
    public let clickQuarterMeter = StereoMeterModel()
    public let clickEighthMeter = StereoMeterModel()
    public let clickSixteenthMeter = StereoMeterModel()

    // Dedicated per-sub-channel Guide VU meters
    public let guideSectionsMeter = StereoMeterModel()
    public let guideDirectionsMeter = StereoMeterModel()
    public let guideFallbackMeter = StereoMeterModel()
    var guideCueMeterEvents: [UUID: [GuideCueMeterEvent]] = [:]
    
    // Click & Guide Audio Generation State & Progress
    @Published public var isGeneratingClick: Bool = false
    @Published public var isGeneratingGuide: Bool = false
    @Published public var clickGuideStatusText: String = ""
    
    // Reference Track Offline Bounce State & Progress
    @Published public var isBouncingReference: Bool = false
    @Published public var referenceBounceProgress: Double = 0.0
    @Published public var referenceBounceStatus: String = ""
    @Published public var referenceBounceError: String? = nil
    
    // In-window pop-out sample managers
    @Published public var isShowingCustomClickSampleManager: Bool = false
    @Published public var isShowingCustomGuideSampleManager: Bool = false
    
    // Audio buffers cache for all songs currently in the setlist
    var songBuffersCache: [UUID: [(track: StemTrack, buffer: AVAudioPCMBuffer)]] = [:]
    var memoryEvictedSongIds: Set<UUID> = []
    var songTrackMetadataBackup: [UUID: [StemTrack]] = [:]
    var songWaveformCache: [UUID: (peaks: [Float], image: NSImage?)] = [:]
    // Transformed audio buffers cache for transposed / tempo-shifted songs in the setlist
    var songTransposedBuffersCache: [UUID: (semitones: Int, preserveVocalFormants: Bool, bpmHundredths: Int, buffers: [UUID: AVAudioPCMBuffer])] = [:]
    @Published public internal(set) var hydratingSongIds: Set<UUID> = []
    @Published public internal(set) var pendingPlayAfterHydration: Bool = false
    var pendingPlaySectionAfterHydration: SongSection? = nil
    public var isCurrentSongHydrating: Bool { hydratingSongIds.contains(currentSong.id) }
    var songSwitchGeneration: UInt64 = 0
    var activeSongHydrationTask: Task<Void, Never>? = nil
    var backgroundPrefetchTasksBySong: [UUID: Task<Void, Never>] = [:]
    var slidingWindowRebalanceTask: Task<Void, Never>? = nil
    var memoryWindowPolicyOverride: MemoryWindowPolicy? = nil
    var lastSavedBusRoutingKey: String? = nil
    var lastSavedBusRoutingData: Data? = nil

    // Hardware Audio Devices
    public let deviceManager = AudioDeviceManager.shared
    
    // MARK: - Audio Engine Nodes (Single-Clock SIMD Architecture)
    let audioEngine: AVAudioEngine
    let masterMixer: AVAudioMixerNode
    var sourceNode: AVAudioSourceNode?
    let mixState = RealTimeMixEngineState()
    var channels: [UUID: TrackChannel] = [:]
    
    struct ActiveManualFade {
        let isFadingOut: Bool
        let startTime: CFTimeInterval
        let duration: TimeInterval
        let startVolumes: [UUID: Float]
        let targetVolumes: [UUID: Float]
        var overriddenTrackIds: Set<UUID> = []
        var lastTickTime: CFTimeInterval = 0
    }

    enum PostSongClickOriginMode {
        case stayInSongEnd
        case cuedSongStart
    }
    struct PostSongClickSpec: Equatable {
        let bpmHundredths: Int
        let numerator: Int
        let denominator: Int
        let soundType: ClickSoundType
        let accentEnabled: Bool
        let quarterEnabled: Bool
        let eighthEnabled: Bool
        let sixteenthEnabled: Bool
        let accentVolPermille: Int
        let quarterVolPermille: Int
        let eighthVolPermille: Int
        let sixteenthVolPermille: Int
        let soloedSubdivisions: Set<ClickSubdivision>
        let sampleRateHz: Int
    }
    @Published public internal(set) var isPostSongClickActive: Bool = false
    public internal(set) var activePostSongClickBPM: Double = 120.0
    public internal(set) var activePostSongClickNumerator: Int = 4
    public internal(set) var activePostSongClickDenominator: Int = 4
    var postSongClickOriginMode: PostSongClickOriginMode = .cuedSongStart
    var isTransitioningIntoPostSongClick: Bool = false
    var cachedStagedPostSongClickSpec: PostSongClickSpec? = nil
    var cachedStagedPostSongClickBuffer: AVAudioPCMBuffer? = nil
    var cachedActivePostSongClickSpec: PostSongClickSpec? = nil
    var cachedActivePostSongClickBuffer: AVAudioPCMBuffer? = nil

    @Published public internal(set) var isAnnouncingSong: Bool = false
    struct CachedSongAnnouncement {
        let phrase: String
        let packId: String?
        let voiceSignature: String
        let usedAIClone: Bool
        let sampleRateHz: Int
        let buffer: AVAudioPCMBuffer
    }
    var songAnnouncementCache: [UUID: CachedSongAnnouncement] = [:]
    var songAnnouncementWarmingKeys: Set<String> = []
    var songAnnouncementRunGeneration: UInt64 = 0
    var songAnnouncementTask: Task<Void, Never>? = nil

    // MARK: - Clock & Synchronization
    var activeManualFade: ActiveManualFade?
    var crossfadeTimer: Timer?
    var hasTriggeredEarlyTransition: Bool = false
    var hasTriggeredDualTransitionPad: Bool = false
    @Published public var pendingTransitionNextSongIndex: Int? = nil
    var pendingTransitionStartOffset: TimeInterval = 0.0
    var scheduledStartOffset: TimeInterval = 0.0
    public internal(set) var playbackOffsetSeconds: TimeInterval = 0.0
    public internal(set) var currentSongDuration: TimeInterval = 0.0
    var currentPlayingSectionId: UUID? = nil
    
    // Click & Guide Audio Generators and Buffer Caches
    public let clickGenerator = ClickGenerator()
    public let guideAudioGenerator = GuideAudioGenerator.shared
    public let padPlayer = PadPlayerEngine()
    @Published public var padChannelVolume: Float = 0.80
    @Published public var padChannelPan: Float = 0.0
    @Published public var padChannelMuted: Bool = false
    @Published public var padChannelSoloed: Bool = false
    var padMeterPeakL: Float = 0.0
    var padMeterPeakR: Float = 0.0
    public var uploadedClickBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var uploadedGuideBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var generatedClickBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var generatedGuideBuffers: [UUID: AVAudioPCMBuffer] = [:]
    struct GeneratedGuideLoopState: Equatable {
        let isLoopActive: Bool
        let loopedSectionId: UUID?
        let loopMode: LoopMode
        let singleLoopRemaining: Int
        let queuedNextSectionId: UUID?
        let nextSongCueSectionId: UUID?
        let nextSongCueSectionName: String?
        let nextSongCueIncludeNumber: Bool?
        let nextSongCuePlayGuide: Bool
        let nextSongCuePlayCountIn: Bool
        let nextSongCueTargetTimeMs: Int
        let sectionsVolPermille: Int
        let sectionsEnabled: Bool
        let directionsVolPermille: Int
        let directionsEnabled: Bool
        let fallbackVolPermille: Int
        let fallbackEnabled: Bool
        let soloedSubChannels: Set<GuideSubChannel>
    }

    func songDurationForGuide(for song: Song) -> TimeInterval {
        if song.id == currentSong.id {
            if !song.sections.isEmpty {
                return song.sections.map { $0.endTime }.max() ?? currentSongDuration
            }
            return currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? 240.0)
        }
        let cachedItems = songBuffersCache[song.id] ?? []
        let maxAudioDur = cachedItems
            .filter { !Self.isClickOrGuideTrack($0.track) }
            .map { Double($0.buffer.frameLength) / max(1.0, $0.buffer.format.sampleRate) }
            .max() ?? 0.0
        return max(maxAudioDur, song.totalDuration)
    }

    func resolvedNextSongSectionCue(forSongAt songIndex: Int, song: Song, duration: TimeInterval) -> (section: SongSection, targetTime: TimeInterval)? {
        guard songIndex >= 0, songIndex + 1 < currentSetlist.songs.count else { return nil }
        guard song.isCueNextSongSectionEffective(isLastSongInSetlist: false) else { return nil }
        let nextSong = currentSetlist.songs[songIndex + 1]
        let nextOrdered = nextSong.sections.sorted { $0.startTime < $1.startTime }
        guard let nextFirst = nextOrdered.first else { return nil }
        let lowerFirst = nextFirst.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if nextFirst.abbreviation == "Co" || lowerFirst.contains("count") {
            return nil
        }

        let targetTime: TimeInterval
        switch song.transitionType {
        case .autoLink:
            let ordered = song.sections.sorted { $0.startTime < $1.startTime }
            targetTime = ordered.last?.endTime ?? duration
        case .overlap:
            targetTime = Self.overlapTransitionStartTime(from: song, currentDuration: duration, to: nextSong)
        case .crossfade:
            let nextBPM = max(20.0, nextSong.bpm)
            let beatsPerBar = Double(max(1, nextSong.timeSignatureNumerator))
            let secPerBar = (60.0 / nextBPM) * (4.0 / Double(max(1, nextSong.timeSignatureDenominator))) * beatsPerBar
            let fadeSec = min(duration, max(0.5, secPerBar * 2.0))
            targetTime = max(0.0, duration - fadeSec)
        case .cueNextSong, .stayInSong, .cueFirstSong:
            return nil
        }
        guard targetTime > 0 else { return nil }
        return (nextFirst, targetTime)
    }

    func invalidateStaleNextSongSectionGuides() {
        var didTouchActiveSong = false
        for (idx, song) in currentSetlist.songs.enumerated() where song.cueNextSongSection {
            let sid = song.id
            if sid == currentSong.id {
                let dur = songDurationForGuide(for: currentSong)
                let expected = expectedDefaultGuideLoopState(forSongAt: idx, song: currentSong, duration: dur)
                let cachedMatches = generatedGuideLoopStates[sid]?.nextSongCueSectionId == expected.nextSongCueSectionId &&
                    generatedGuideLoopStates[sid]?.nextSongCueSectionName == expected.nextSongCueSectionName &&
                    generatedGuideLoopStates[sid]?.nextSongCueTargetTimeMs == expected.nextSongCueTargetTimeMs
                if !cachedMatches || currentSong.guideSource == .uploaded {
                    generatedGuideBuffers.removeValue(forKey: sid)
                    generatedGuideLoopStates.removeValue(forKey: sid)
                    didTouchActiveSong = true
                }
            } else {
                let expected = expectedDefaultGuideLoopState(forSongAt: idx, song: song)
                if generatedGuideLoopStates[sid] != expected {
                    generatedGuideBuffers.removeValue(forKey: sid)
                    generatedGuideLoopStates.removeValue(forKey: sid)
                }
            }
        }
        if didTouchActiveSong && !currentSong.excludesClickAndGuide {
            if currentSong.guideSource == .generated {
                regenerateGuideTrack()
            } else {
                applyGuideBuffer()
            }
        }
    }
    var generatedGuideLoopStates: [UUID: GeneratedGuideLoopState] = [:]
    var guideRegenerationGeneration: UInt64 = 0
    var preGeneratingClickGuideSongIds: Set<UUID> = []
    var preGeneratingClickGuideCompletions: [UUID: [() -> Void]] = [:]
    
    var sessionHydrationTask: Task<Void, Never>? = nil
    var sessionHydrationGeneration: Int = 0
    
    public init() {
        self.audioEngine = AVAudioEngine()
        self.masterMixer = audioEngine.mainMixerNode
        
        if let dev = deviceManager.selectedDevice {
            lastAppliedHardwareDeviceID = dev.id
            lastAppliedHardwareChannelCount = dev.outputChannelCount
            if dev.id != deviceManager.getDefaultSystemDeviceID(),
               let outputUnit = audioEngine.outputNode.audioUnit {
                var devID = dev.id
                let status = AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    PeanutButterLog.hardware.error("Failed to bind restored audio device \(dev.name, privacy: .public) on init: OSStatus \(status)")
                }
            }
            loadBusRouting(for: dev)
        }
        setupSingleClockSourceNode()
        
        hardwareDeviceCancellable = deviceManager.$selectedDevice
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDevice in
                guard let self = self, let dev = newDevice else { return }
                let didChange = (dev.id != self.lastAppliedHardwareDeviceID) || (dev.outputChannelCount != self.lastAppliedHardwareChannelCount)
                guard didChange else { return }
                self.setOutputDevice(dev, showBanner: true, persistAsPreferred: false)
            }
        
        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            isEngineRunning = false
            PeanutButterLog.audio.error("Failed to start AVAudioEngine on init: \(error.localizedDescription, privacy: .public)")
        }

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioEngineConfigurationChange()
            }
        }

        voiceCloneReadyObserver = NotificationCenter.default.addObserver(
            forName: VoiceCloneModelManager.didBecomeReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVoiceCloneModelOrPhraseUpdated()
            }
        }

        voiceClonePhraseObserver = NotificationCenter.default.addObserver(
            forName: VoiceCloneService.didFinishBackgroundPhraseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVoiceCloneModelOrPhraseUpdated()
            }
        }
        
        // Stage 1: Synchronously hydrate session metadata (<10ms) so the window opens with the session already populated on Frame 1,
        // while Stage 2 loads the audio buffers in the background starting with the active song.
        restoreLastSessionIfAvailable()
        
        DispatchQueue.main.async { [weak self] in
            if let self {
                let canonicalFormat = self.getCanonicalProcessingFormat()
                AudioSampleBank.shared.warmupCommonSamples(format: canonicalFormat)
            }
            self?.setupMemoryPressureMonitoring()
            self?.rebuildPrecomputedBeatGrid()
            self?.rebuildCachedActiveAutomation()
            self?.cloudSetlistsCancellable = LibraryBrowserManager.shared.$setlists
                .receive(on: DispatchQueue.main)
                .sink { [weak self] items in
                    self?.updateCloudSetlistUpdateFlag(from: items)
                }
            LibraryBrowserManager.shared.refreshSetlists()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performAutoSave()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebindUIDisplayLinkIfNeeded()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebindUIDisplayLinkIfNeeded()
        }
        
        MIDIMappingManager.shared.engine = self
        MIDIMappingManager.shared.setLearningModeActive(isEditMIDIMappingMode)
        padStateCancellable = padPlayer.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playingNow in
                guard let self = self else { return }
                if !playingNow && !self.padPlayer.isFadingOutState && self.isPadActive {
                    self.isPadActive = false
                    self.updatePlaybackActivityAssertion()
                }
            }
        KeyboardMappingManager.shared.engine = self
        remoteServer.attach(to: self)
        if UserDefaults.standard.bool(forKey: "Playback_RemoteControlEnabled") {
            self.setRemoteControlEnabled(true)
        }
        
        loadStageSignalPreset(for: deviceManager.selectedDevice, allowLegacyGlobalFallback: true)
        
        self.isSongSectionPreRollEnabled = UserDefaults.standard.bool(forKey: "Playback_SongSectionPreRollEnabled")
        let storedBars = UserDefaults.standard.integer(forKey: "Playback_SectionPreRollLengthBars")
        self.sectionPreRollLengthBars = storedBars > 0 ? storedBars : 2
        
        self.isGlobalStartPadWithSongEnabled = UserDefaults.standard.bool(forKey: "Playback_GlobalStartPadWithSongEnabled")
        self.isGlobalIncludeGuideSectionNumbersEnabled = UserDefaults.standard.bool(forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        self.isFadersDefault100Enabled = UserDefaults.standard.bool(forKey: "Playback_FadersDefault100")
        if let rawClickSrc = UserDefaults.standard.string(forKey: "Playback_DefaultClickSource"),
           let clickSrc = ClickSource(rawValue: rawClickSrc) {
            self.defaultClickSourcePreference = clickSrc
        }
        if let rawGuideSrc = UserDefaults.standard.string(forKey: "Playback_DefaultGuideSource"),
           let guideSrc = GuideSource(rawValue: rawGuideSrc) {
            self.defaultGuideSourcePreference = guideSrc
        }
        resetUndoHistoryToCurrentState()
    }
    
    var tapTimestamps: [Date] = []
    
    // Spontaneous Queued Next Section (Playback Style Double-Click)
    @Published public var queuedNextSection: SongSection? = nil
    

    var preGenerateSetlistTask: Task<Void, Never>? = nil

    deinit {
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        activeSongHydrationTask?.cancel()
        slidingWindowRebalanceTask?.cancel()
        backgroundPrefetchTasksBySong.values.forEach { $0.cancel() }
        uiFallbackTimer?.invalidate()
        uiDisplayLink?.invalidate()
        transportWatchdogTimer?.cancel()
        if let token = playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        memoryPressureSource?.cancel()
        masterVolumeCommitWorkItem?.cancel()
        crossfadeTimer?.invalidate()
        padPlayer.detach()
        audioEngine.stop()
    }

    func setupSingleClockSourceNode() {
        if let existing = sourceNode {
            audioEngine.disconnectNodeOutput(existing)
            audioEngine.detach(existing)
            sourceNode = nil
        }
        
        let multichannelFormat = getHardwareMultichannelFormat()
        lastConfiguredSampleRate = multichannelFormat.sampleRate
        
        mixState.setPadEngine(padPlayer)
        
        let state = mixState
        let node = AVAudioSourceNode(format: multichannelFormat) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            return state.render(isSilence: isSilence, frameCount: Int(frameCount), audioBufferList: audioBufferList)
        }
        audioEngine.attach(node)
        let hwOutFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        if hwOutFormat.channelCount > 0 && hwOutFormat.sampleRate > 0 {
            audioEngine.connect(node, to: audioEngine.outputNode, format: multichannelFormat)
        }
        sourceNode = node
        
        // Ambient Pad Player engine
        padPlayer.setProcessingFormat(multichannelFormat)
        let padBus = busses.first { $0.name.lowercased() == "pad" }
        let (padL, padR) = resolvePhysicalOutputChannels(for: padBus?.physicalOutputChannel ?? "Out 1/2", isMono: padBus?.isMono ?? false)
        padPlayer.setTargetOutputChannels(left: padL, right: padR)
        updateRedundancyState(persistDevicePreset: false)
        updateSMPTEState(persistDevicePreset: false)
    }
    
    // MARK: - Track Management & Sample-Accurate Setup
    
    /// Adds a track with an in-memory PCM audio buffer into the single-clock SIMD mixer
    public func addTrack(_ track: StemTrack, with buffer: AVAudioPCMBuffer, recalculateWaveform: Bool = true) {
        if channels[track.id] != nil {
            tracks.removeAll { $0.id == track.id }
            pristineMasterBuffers.removeValue(forKey: track.id)
            channels.removeValue(forKey: track.id)
        }
        
        let canonicalFormat = getCanonicalProcessingFormat()
        let finalBuffer = normalizeBufferToCanonical(buffer: buffer, targetFormat: canonicalFormat)
        
        pristineMasterBuffers[track.id] = finalBuffer
        let channel = TrackChannel(track: track, buffer: finalBuffer)
        channels[track.id] = channel
        
        let trackDuration = Double(finalBuffer.frameLength) / finalBuffer.format.sampleRate
        track.duration = trackDuration
        if track.waveformPeaks.isEmpty && track.includeInWaveform {
            track.waveformPeaks = extractWaveformPeaks(from: finalBuffer, samplesCount: 4000)
        }
        
        tracks.append(track)
        
        if trackDuration > currentSongDuration {
            currentSongDuration = trackDuration
            transportPosition.totalDuration = currentSongDuration
            transportClock.position.totalDuration = currentSongDuration
            transportDisplayClock.update(with: transportPosition)
        }
        
        if recalculateWaveform {
            recalculateAggregateWaveform(samplesCount: 4000)
            updateMatrix()
            ensureClickAndGuideTracksExist()
        }
        markSessionChanged()
    }
    
    /// Returns the engine's canonical stereo processing format matching the hardware output
    public func getCanonicalProcessingFormat() -> AVAudioFormat {
        let outFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000.0
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
    
    /// Normalizes any input buffer (mono/stereo, any sample rate) to the engine's canonical stereo format
    func normalizeBufferToCanonical(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        // Step 1: ensure 2 channels (stereo)
        let stereoBuffer: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 {
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2)!
            if let sBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: buffer.frameLength) {
                sBuf.frameLength = buffer.frameLength
                if let mono = buffer.floatChannelData?[0],
                   let left = sBuf.floatChannelData?[0],
                   let right = sBuf.floatChannelData?[1] {
                    let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
                    memcpy(left, mono, bytes)
                    memcpy(right, mono, bytes)
                }
                stereoBuffer = sBuf
            } else {
                stereoBuffer = buffer
            }
        } else {
            stereoBuffer = buffer
        }
        
        // Step 2: if sample rate matches canonical format, we're done
        if stereoBuffer.format.sampleRate == targetFormat.sampleRate && stereoBuffer.format.channelCount == targetFormat.channelCount {
            return stereoBuffer
        }
        
        // Step 3: resample cleanly with AVAudioConverter
        guard let converter = AVAudioConverter(from: stereoBuffer.format, to: targetFormat) else {
            return stereoBuffer
        }
        
        let ratio = targetFormat.sampleRate / stereoBuffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(stereoBuffer.frameLength) * ratio) + 2048
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return stereoBuffer
        }
        
        var error: NSError?
        var isDone = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return stereoBuffer
        }
        
        if status != .error && error == nil && converted.frameLength > 0 {
            return converted
        } else {
            return stereoBuffer
        }
    }
    
    /// Loads an audio file from disk into a stem track, converting it into a sample-accurate RAM buffer
    public func addTrack(from fileURL: URL, name: String? = nil, role: TrackRole = .stem, recalculateWaveform: Bool = true) throws -> StemTrack {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let trackName = name ?? fileURL.deletingPathExtension().lastPathComponent
        let track = StemTrack(name: trackName, role: role, fileURL: fileURL)
        
        let canonicalFormat = getCanonicalProcessingFormat()
        
        // Read file into memory buffer
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw NSError(domain: "PlaybackEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"])
        }
        try audioFile.read(into: fileBuffer)
        
        // Normalize into engine canonical stereo format (no sample rate drift or channel mismatch)
        let finalBuffer = normalizeBufferToCanonical(buffer: fileBuffer, targetFormat: canonicalFormat)
        
        pristineMasterBuffers[track.id] = finalBuffer
        let channel = TrackChannel(track: track, buffer: finalBuffer, audioFile: nil)
        channels[track.id] = channel
        
        let cat = StemCategory.category(for: trackName, role: role)
        if role == .click || cat == .click {
            track.role = .click
            uploadedClickBuffers[currentSong.id] = finalBuffer
            let src = defaultClickSourcePreference
            currentSong.excludesClickAndGuide = false
            currentSong.clickSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                currentSetlist.songs[currentSongIndex].clickSource = src
            }
        } else if role == .guide || cat == .guide {
            track.role = .guide
            uploadedGuideBuffers[currentSong.id] = finalBuffer
            let src = defaultGuideSourcePreference
            currentSong.excludesClickAndGuide = false
            currentSong.guideSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                currentSetlist.songs[currentSongIndex].guideSource = src
            }
        }
        
        let trackDuration = Double(finalBuffer.frameLength) / finalBuffer.format.sampleRate
        track.duration = trackDuration
        if track.waveformPeaks.isEmpty && track.includeInWaveform {
            track.waveformPeaks = extractWaveformPeaks(from: finalBuffer, samplesCount: 4000)
        }
        
        PlaybackFileManager.shared.cacheStemInBackground(trackId: track.id, buffer: finalBuffer, sourceURL: fileURL)
        PlaybackFileManager.shared.recordLocalLosslessSources([(track.id, fileURL)])
        
        tracks.append(track)
        if trackDuration > currentSongDuration {
            currentSongDuration = trackDuration
            transportPosition.totalDuration = currentSongDuration
            transportClock.position.totalDuration = currentSongDuration
            transportDisplayClock.update(with: transportPosition)
        }
        
        if recalculateWaveform {
            recalculateAggregateWaveform(samplesCount: 4000)
            updateMatrix()
            ensureClickAndGuideTracksExist()
        }
        return track
    }
    
    private struct LoadedStemPayload: @unchecked Sendable {
        let index: Int
        let track: StemTrack
        let buffer: AVAudioPCMBuffer
        let url: URL
    }

    private struct SendableFormatBox: @unchecked Sendable {
        let format: AVAudioFormat
    }

    private nonisolated static func decodeAndNormalizeStem(
        index: Int,
        from url: URL,
        canonicalFormat: AVAudioFormat
    ) -> LoadedStemPayload? {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope { url.stopAccessingSecurityScopedResource() }
        }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            PeanutButterLog.storage.error("Failed opening stem file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            return nil
        }
        do {
            try audioFile.read(into: fileBuffer)
        } catch {
            PeanutButterLog.storage.error("Failed reading stem audio \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let finalBuffer = PlaybackFileManager.normalizeBuffer(fileBuffer, to: canonicalFormat)
        let trackName = url.deletingPathExtension().lastPathComponent
        let cat = StemCategory.category(for: trackName)
        let role: TrackRole = cat == .click ? .click : (cat == .guide ? .guide : .stem)
        let track = StemTrack(name: trackName, role: role, fileURL: url)
        track.duration = Double(finalBuffer.frameLength) / max(1.0, finalBuffer.format.sampleRate)
        if track.includeInWaveform {
            track.waveformPeaks = PlaybackFileManager.extractPeaks(from: finalBuffer, samplesCount: 4000)
        }
        return LoadedStemPayload(index: index, track: track, buffer: finalBuffer, url: url)
    }

    private func attachDecodedStems(_ items: [LoadedStemPayload]) {
        guard !items.isEmpty else { return }

        let losslessPairs: [(UUID, URL?)] = items.map { ($0.track.id, $0.url) }
        PlaybackFileManager.shared.recordLocalLosslessSources(losslessPairs)

        for item in items {
            let track = item.track
            let finalBuffer = item.buffer

            pristineMasterBuffers[track.id] = finalBuffer
            channels[track.id] = TrackChannel(track: track, buffer: finalBuffer, audioFile: nil)

            let cat = StemCategory.category(for: track.name, role: track.role)
            if track.role == .click || cat == .click {
                track.role = .click
                uploadedClickBuffers[currentSong.id] = finalBuffer
                let src = defaultClickSourcePreference
                currentSong.excludesClickAndGuide = false
                currentSong.clickSource = src
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                    currentSetlist.songs[currentSongIndex].clickSource = src
                }
            } else if track.role == .guide || cat == .guide {
                track.role = .guide
                uploadedGuideBuffers[currentSong.id] = finalBuffer
                let src = defaultGuideSourcePreference
                currentSong.excludesClickAndGuide = false
                currentSong.guideSource = src
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                    currentSetlist.songs[currentSongIndex].guideSource = src
                }
            }

            if isFadersDefault100Enabled && track.volume >= 0.79 && track.volume <= 0.81 {
                track.volume = 1.0
            }

            tracks.append(track)
        }

        // Update song duration from real imported tracks so any earlier 240s empty Click/Guide placeholder does not linger
        let realMaxDur = tracks
            .filter { !Self.isClickOrGuideTrack($0) || $0.fileURL != nil }
            .map { $0.duration }
            .max() ?? 0.0
        if realMaxDur > 0.01 {
            for utility in tracks where Self.isClickOrGuideTrack(utility) && utility.fileURL == nil {
                utility.duration = realMaxDur
            }
            if currentSong.sections.isEmpty || realMaxDur > currentSongDuration {
                currentSongDuration = currentSong.sections.isEmpty
                    ? realMaxDur
                    : max(currentSongDuration, realMaxDur)
                transportPosition.totalDuration = currentSongDuration
                transportClock.position.totalDuration = currentSongDuration
                transportDisplayClock.update(with: transportPosition)
            }
        }

        // Start background .m4a caching only after all stems are decoded & peak-extracted
        for item in items {
            PlaybackFileManager.shared.cacheStemInBackground(trackId: item.track.id, buffer: item.buffer, sourceURL: item.url)
        }
    }

    /// Loads multiple audio files concurrently across all CPU cores for rapid multi-stem import
    public func addTracksConcurrently(from fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let canonicalFormat = getCanonicalProcessingFormat()

        let count = fileURLs.count
        let box = UnsafeMutableBufferPointer<LoadedStemPayload?>.allocate(capacity: count)
        box.initialize(repeating: nil)
        defer {
            box.deinitialize()
            box.deallocate()
        }

        DispatchQueue.concurrentPerform(iterations: count) { idx in
            box[idx] = Self.decodeAndNormalizeStem(index: idx, from: fileURLs[idx], canonicalFormat: canonicalFormat)
        }

        let orderedItems = (0..<count).compactMap { box[$0] }
        attachDecodedStems(orderedItems)
    }

    /// Asynchronously decodes, normalizes, and extracts waveform peaks off `@MainActor` so the UI stays responsive during multi-stem imports.
    public func addTracksConcurrentlyAsync(
        from fileURLs: [URL],
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async {
        guard !fileURLs.isEmpty else { return }
        let targetSongId = currentSong.id
        let formatBox = SendableFormatBox(format: getCanonicalProcessingFormat())
        let totalCount = fileURLs.count

        let decodedItems: [LoadedStemPayload] = await Task.detached(priority: .userInitiated) {
            let maxConcurrency = max(2, min(ProcessInfo.processInfo.activeProcessorCount, totalCount))
            var collected: [LoadedStemPayload] = []
            collected.reserveCapacity(totalCount)

            await withTaskGroup(of: LoadedStemPayload?.self) { group in
                var nextIdx = 0
                let initial = min(maxConcurrency, totalCount)
                while nextIdx < initial {
                    let idx = nextIdx
                    let url = fileURLs[idx]
                    nextIdx += 1
                    group.addTask {
                        Self.decodeAndNormalizeStem(index: idx, from: url, canonicalFormat: formatBox.format)
                    }
                }

                var completed = 0
                for await item in group {
                    completed += 1
                    if let item {
                        collected.append(item)
                    }
                    if let onProgress {
                        let done = completed
                        await MainActor.run {
                            onProgress(done, totalCount)
                        }
                    }
                    if nextIdx < totalCount {
                        let idx = nextIdx
                        let url = fileURLs[idx]
                        nextIdx += 1
                        group.addTask {
                            Self.decodeAndNormalizeStem(index: idx, from: url, canonicalFormat: formatBox.format)
                        }
                    }
                }
            }

            return collected.sorted { $0.index < $1.index }
        }.value

        guard currentSong.id == targetSongId else { return }
        attachDecodedStems(decodedItems)
    }
    
    // Unified V-Sync synchronized CADisplayLink driving both transport playhead & isolated `StereoMeterModel`s
    final class DisplayLinkTickProxy: NSObject {
        private let onTick: (TimeInterval) -> Void
        init(onTick: @escaping (TimeInterval) -> Void) {
            self.onTick = onTick
            super.init()
        }
        @objc func step(_ sender: CADisplayLink) {
            let rawDt = sender.targetTimestamp - sender.timestamp
            let dt = (rawDt > 0.001 && rawDt < 0.25) ? rawDt : (sender.duration > 0.001 ? sender.duration : (1.0 / 60.0))
            onTick(dt)
        }
    }

    func screenDisplayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let num = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    func ensureUIDisplayLinkRunning() {
        if uiDisplayLink != nil || uiFallbackTimer != nil {
            return
        }

        let targetWindow = NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
        let targetScreen = targetWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let maxFPS = Float(max(30, min(120, targetScreen?.maximumFramesPerSecond ?? 60)))

        let proxy = DisplayLinkTickProxy { [weak self] dt in
            self?.tickUIDisplayLink(dt: dt)
        }

        if let link = targetWindow?.displayLink(target: proxy, selector: #selector(DisplayLinkTickProxy.step(_:)))
            ?? targetScreen?.displayLink(target: proxy, selector: #selector(DisplayLinkTickProxy.step(_:))) {
            uiDisplayLinkProxy = proxy
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
            link.add(to: .main, forMode: .common)
            uiDisplayLink = link
            uiDisplayLinkScreenNumber = screenDisplayID(for: targetScreen)
        } else {
            let interval = 1.0 / Double(maxFPS)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.tickUIDisplayLink(dt: interval)
            }
            timer.tolerance = 0.002
            uiFallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func rebindUIDisplayLinkIfNeeded() {
        guard uiDisplayLink != nil else { return }
        let targetWindow = NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
        let targetScreen = targetWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let currentScreenID = screenDisplayID(for: targetScreen)
        if currentScreenID != uiDisplayLinkScreenNumber {
            stopUIDisplayLink()
            ensureUIDisplayLinkRunning()
        } else if let link = uiDisplayLink, let screen = targetScreen {
            let maxFPS = Float(max(30, min(120, screen.maximumFramesPerSecond)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        }
    }

    func updatePlaybackActivityAssertion() {
        let active = (playbackState == .playing) || isAnnouncingSong || isPadActive || isPostSongClickActive
        if active && playbackActivityToken == nil {
            playbackActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Live multitrack audio and MIDI playback"
            )
        } else if !active, let token = playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            playbackActivityToken = nil
        }
    }

    func startTransportWatchdogTimer() {
        if transportWatchdogTimer != nil { return }
        lastPlaybackClockTickTimestamp = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.playbackState == .playing || self.isAnnouncingSong else {
                self.stopTransportWatchdogTimer()
                return
            }
            if CACurrentMediaTime() - self.lastPlaybackClockTickTimestamp >= 0.030 {
                self.tickPlaybackClock()
                self.padPlayer.syncUIStateAndDrainRetiredBuffers()
                self.mixState.drainRetiredGenerations()
            }
        }
        transportWatchdogTimer = timer
        timer.resume()
    }

    func stopTransportWatchdogTimer() {
        transportWatchdogTimer?.cancel()
        transportWatchdogTimer = nil
    }

    func stopUIDisplayLink() {
        uiFallbackTimer?.invalidate()
        uiFallbackTimer = nil
        uiDisplayLink?.invalidate()
        uiDisplayLink = nil
        uiDisplayLinkProxy = nil
        uiDisplayLinkScreenNumber = nil
    }

    func tickUIDisplayLink(dt: TimeInterval) {
        if playbackState == .playing || isAnnouncingSong {
            tickPlaybackClock()
        }
        if activeManualFade != nil {
            tickActiveManualFade()
        }
        tickMeters(dt: dt)
    }

    func startMeteringTimer() {
        ensureUIDisplayLinkRunning()
    }
    
    func resetGuideSubChannelMeters() {
        guideSectionsMeter.reset()
        guideDirectionsMeter.reset()
        guideFallbackMeter.reset()
    }

    func resetClickMeters() {
        clickAccentMeter.reset()
        clickQuarterMeter.reset()
        clickEighthMeter.reset()
        clickSixteenthMeter.reset()
        resetGuideSubChannelMeters()
        for track in tracks where track.isClickTrackCached {
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            track.peakLevelLeft = 0.0
            track.peakLevelRight = 0.0
            track.meter.reset()
        }
    }

    func stopMeteringTimer() {
        if playbackState != .playing {
            stopUIDisplayLink()
        }
        resetClickMeters()
    }
    
    func updatePadMeter(dt: TimeInterval) {
        let (rawPadL, rawPadR) = padPlayer.consumeMeterPeaks()
        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let targetL: Float = rawPadL > 0.0005 ? min(1.0, pow(rawPadL, 0.62)) : 0.0
        let targetR: Float = (rawPadR == rawPadL) ? targetL : (rawPadR > 0.0005 ? min(1.0, pow(rawPadR, 0.62)) : 0.0)
        let baseRelease: Float = (padPlayer.isPlaying || padPlayer.isFadingOutState) ? 0.82 : 0.72
        let releaseFactor = powf(baseRelease, frames60)
        let attackBlend = 1.0 - powf(0.20, frames60)
        let nextL: Float = targetL >= padMeterPeakL ? (padMeterPeakL + (targetL - padMeterPeakL) * attackBlend) : (padMeterPeakL * releaseFactor)
        let nextR: Float = targetR >= padMeterPeakR ? (padMeterPeakR + (targetR - padMeterPeakR) * attackBlend) : (padMeterPeakR * releaseFactor)
        padMeterPeakL = nextL < 0.01 ? 0.0 : nextL
        padMeterPeakR = nextR < 0.01 ? 0.0 : nextR
        padPlayer.meter.update(left: padMeterPeakL, right: padMeterPeakR, dt: dt)
    }

    func tickMeters(dt: TimeInterval = 1.0 / 60.0) {
        padPlayer.syncUIStateAndDrainRetiredBuffers()
        let padNeedsUpdate = padPlayer.hasActiveAudioToRender || padPlayer.isPlaying || padPlayer.isFadingOutState || padMeterPeakL > 0.0 || padMeterPeakR > 0.0 || padPlayer.meter.left > 0.0 || padPlayer.meter.right > 0.0
        if padNeedsUpdate {
            updatePadMeter(dt: dt)
        }
        guard playbackState == .playing else {
            if isAnnouncingSong {
                let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
                let trackAttack = 1.0 - powf(0.20, frames60)
                let trackDecay = powf(0.82, frames60)
                let trackPeaks = mixState.consumeTrackPeaks()
                for track in tracks where !track.isClickTrackCached {
                    let (rawL, rawR) = trackPeaks[track.id] ?? (0.0, 0.0)
                    if rawL == 0.0 && rawR == 0.0 && track.peakLevelLeft == 0.0 && track.peakLevelRight == 0.0 && track.meter.left == 0.0 && track.meter.right == 0.0 {
                        continue
                    }
                    let targetL: Float = rawL > 0.0005 ? min(1.0, pow(rawL, 0.62)) : 0.0
                    let targetR: Float = (rawR == rawL) ? targetL : (rawR > 0.0005 ? min(1.0, pow(rawR, 0.62)) : 0.0)
                    let nextL: Float = targetL >= track.peakLevelLeft
                        ? (track.peakLevelLeft + (targetL - track.peakLevelLeft) * trackAttack)
                        : (track.peakLevelLeft * trackDecay)
                    let nextR: Float = targetR >= track.peakLevelRight
                        ? (track.peakLevelRight + (targetR - track.peakLevelRight) * trackAttack)
                        : (track.peakLevelRight * trackDecay)
                    track.peakLevelLeft = nextL < 0.004 ? 0.0 : nextL
                    track.peakLevelRight = nextR < 0.004 ? 0.0 : nextR
                    track.meter.update(left: track.peakLevelLeft, right: track.peakLevelRight, dt: dt)
                }
            }
            if isPostSongClickActive {
                updatePostSongClickMeters(dt: dt)
            } else {
                resetClickMeters()
            }
            let busNeedsUpdate = isPostSongClickActive || isAnnouncingSong || padNeedsUpdate || busses.contains { $0.peakLevelLeft > 0.0 || $0.peakLevelRight > 0.0 || $0.meter.left > 0.0 || $0.meter.right > 0.0 }
            if busNeedsUpdate && (mixerMode == .busses || remoteServer.connectedClientCount > 0 || isAnnouncingSong) {
                updateBusMeters(dt: dt)
            }
            if !isPostSongClickActive && !isAnnouncingSong && !padNeedsUpdate && !busNeedsUpdate && activeManualFade == nil {
                stopUIDisplayLink()
            }
            return
        }

        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let trackAttack = 1.0 - powf(0.20, frames60)
        let trackDecay = powf(0.82, frames60)
        let masterAttack = 1.0 - powf(0.22, frames60)
        let masterDecay = powf(0.86, frames60)

        let trackPeaks = mixState.consumeTrackPeaks()
        
        for track in tracks {
            if track.isClickTrackCached {
                // Main Click VU flashes on quarter notes
                continue
            }
            let (rawL, rawR) = trackPeaks[track.id] ?? (0.0, 0.0)
            if rawL == 0.0 && rawR == 0.0 && track.peakLevelLeft == 0.0 && track.peakLevelRight == 0.0 && track.meter.left == 0.0 && track.meter.right == 0.0 {
                continue
            }
            
            // Perceptual console meter scaling (pow 0.62) so low/mid details are clearly visible
            let targetL: Float = rawL > 0.0005 ? min(1.0, pow(rawL, 0.62)) : 0.0
            let targetR: Float = (rawR == rawL) ? targetL : (rawR > 0.0005 ? min(1.0, pow(rawR, 0.62)) : 0.0)
            
            // Time-normalized attack & analog-style exponential release
            let nextL: Float = targetL >= track.peakLevelLeft
                ? (track.peakLevelLeft + (targetL - track.peakLevelLeft) * trackAttack)
                : (track.peakLevelLeft * trackDecay)
            let nextR: Float = targetR >= track.peakLevelRight
                ? (track.peakLevelRight + (targetR - track.peakLevelRight) * trackAttack)
                : (track.peakLevelRight * trackDecay)
            
            track.peakLevelLeft = nextL < 0.004 ? 0.0 : nextL
            track.peakLevelRight = nextR < 0.004 ? 0.0 : nextR
            track.meter.update(left: track.peakLevelLeft, right: track.peakLevelRight, dt: dt)
        }
        
        updateFlashingClickMeters(dt: dt)
        updateGuideSubChannelMeters(dt: dt)

        if mixerMode == .busses || remoteServer.connectedClientCount > 0 {
            updateBusMeters(dt: dt)
        }
        
        let (rawMasterL, rawMasterR) = mixState.consumeMasterPeaks()
        let targetMasterL = rawMasterL > 0.0005 ? min(1.0, pow(rawMasterL, 0.62)) : 0.0
        let targetMasterR = rawMasterR > 0.0005 ? min(1.0, pow(rawMasterR, 0.62)) : 0.0
        
        let nextMasterL: Float = targetMasterL >= masterPeakLeft
            ? (masterPeakLeft + (targetMasterL - masterPeakLeft) * masterAttack)
            : (masterPeakLeft * masterDecay)
        let nextMasterR: Float = targetMasterR >= masterPeakRight
            ? (masterPeakRight + (targetMasterR - masterPeakRight) * masterAttack)
            : (masterPeakRight * masterDecay)
        
        masterPeakLeft = nextMasterL < 0.003 ? 0.0 : nextMasterL
        masterPeakRight = nextMasterR < 0.003 ? 0.0 : nextMasterR
        masterMeter.update(left: masterPeakLeft, right: masterPeakRight, dt: dt)
    }
    
    /// Refreshes Click channel and subdivision VU meters for the current playhead position.
    public func refreshClickMetersForCurrentPosition(dt: TimeInterval = 1.0 / 60.0) {
        updateFlashingClickMeters(dt: dt)
    }

    func updateGuideSubChannelMeters(dt: TimeInterval = 1.0 / 60.0) {
        guard !currentSong.excludesClickAndGuide, playbackState == .playing else {
            guideSectionsMeter.update(left: 0.0, right: 0.0, dt: dt)
            guideDirectionsMeter.update(left: 0.0, right: 0.0, dt: dt)
            guideFallbackMeter.update(left: 0.0, right: 0.0, dt: dt)
            return
        }
        let guideTrack = tracks.first(where: { $0.isGuideTrackCached })
        let guideL = guideTrack?.peakLevelLeft ?? 0.0
        let guideR = guideTrack?.peakLevelRight ?? 0.0
        let nowSec = (currentSong.guideSource == .generated)
            ? playbackOffsetSeconds
            : audioTime(forArrangementTime: playbackOffsetSeconds)
        let events = guideCueMeterEvents[currentSong.id] ?? []

        var sectionsActive = false
        var directionsActive = false
        var fallbackActive = false
        for event in events where event.startTime <= nowSec && nowSec <= event.endTime + 0.03 {
            if event.category == .sections { sectionsActive = true }
            if event.category == .directions { directionsActive = true }
            if event.usedFallback { fallbackActive = true }
        }

        guideSectionsMeter.update(left: sectionsActive ? guideL : 0.0, right: sectionsActive ? guideR : 0.0, dt: dt)
        guideDirectionsMeter.update(left: directionsActive ? guideL : 0.0, right: directionsActive ? guideR : 0.0, dt: dt)
        guideFallbackMeter.update(left: fallbackActive ? guideL : 0.0, right: fallbackActive ? guideR : 0.0, dt: dt)
    }

    func updateBusMeters(dt: TimeInterval = 1.0 / 60.0) {
        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let busDecay = powf(0.85, frames60)

        var busPeaks: [String: (left: Float, right: Float)] = [:]
        for track in tracks {
            let busKey = track.assignedBusName.lowercased()
            let cur = busPeaks[busKey] ?? (0.0, 0.0)
            busPeaks[busKey] = (max(cur.left, track.peakLevelLeft), max(cur.right, track.peakLevelRight))
        }
        if padMeterPeakL > 0.0 || padMeterPeakR > 0.0 {
            let cur = busPeaks["pad"] ?? (0.0, 0.0)
            busPeaks["pad"] = (max(cur.left, padMeterPeakL), max(cur.right, padMeterPeakR))
        }

        for bus in busses {
            let busKey = bus.name.lowercased()
            if let peaks = busPeaks[busKey] {
                if bus.isMono {
                    let monoPeak = max(peaks.left, peaks.right)
                    let decayed = bus.peakLevelLeft * busDecay
                    bus.peakLevelLeft = max(monoPeak, decayed < 0.003 ? 0.0 : decayed)
                    bus.peakLevelRight = bus.peakLevelLeft
                } else {
                    let decayedL = bus.peakLevelLeft * busDecay
                    let decayedR = bus.peakLevelRight * busDecay
                    bus.peakLevelLeft = max(peaks.left, decayedL < 0.003 ? 0.0 : decayedL)
                    bus.peakLevelRight = max(peaks.right, decayedR < 0.003 ? 0.0 : decayedR)
                }
            } else {
                bus.peakLevelLeft = bus.peakLevelLeft < 0.003 ? 0.0 : bus.peakLevelLeft * busDecay
                bus.peakLevelRight = bus.peakLevelRight < 0.003 ? 0.0 : bus.peakLevelRight * busDecay
            }
            bus.meter.update(left: bus.peakLevelLeft, right: bus.peakLevelRight, dt: dt)
        }
    }

    func updateFlashingClickMeters(dt: TimeInterval = 1.0 / 60.0) {
        let nowSec = playbackOffsetSeconds
        let sourceSec = audioTime(forArrangementTime: nowSec)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sourceSec)
        
        let activeGrid = cachedEffectiveBeatGrid
        let activeMarker: BeatGridMarker? = {
            if !activeGrid.isEmpty {
                let target = nowSec + 0.008
                var low = 0
                var high = activeGrid.count - 1
                var bestIdx = -1
                while low <= high {
                    let mid = (low + high) / 2
                    if activeGrid[mid].time <= target {
                        bestIdx = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                if bestIdx >= 0 {
                    return activeGrid[bestIdx]
                }
            }
            return currentSong.activeMarker(at: nowSec)
        }()
        
        let activeBPM = max(20.0, activeMarker?.instantaneousBPM ?? currentSong.bpm)
        let beatSec = (60.0 / activeBPM) * (4.0 / Double(max(1, tsDen)))
        let beatsPerBar = max(1, tsNum)
        let downbeatFlashWindow = min(0.095, beatSec * 0.42)
        
        func zeroAllClickMeters() {
            clickAccentMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickQuarterMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickEighthMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickSixteenthMeter.update(left: 0.0, right: 0.0, dt: dt)
            for track in tracks where track.isClickTrackCached {
                track.peakLevelLeft = 0.0
                track.peakLevelRight = 0.0
                track.meter.update(left: 0.0, right: 0.0, dt: dt)
            }
        }
        
        if currentSong.excludesClickAndGuide || !tracks.contains(where: { $0.isClickTrackCached }) {
            zeroAllClickMeters()
            return
        }
        
        // Stop flashing Click meters once past the single downbeat hit of an End / Ending section
        let endSection = currentSong.sections.first(where: { sec in
            let lowerName = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let lowerAbbrev = sec.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowerName == "end" || lowerName == "ending" || lowerName == "the end" ||
                   lowerName.starts(with: "end ") || lowerName.hasSuffix(" end") ||
                   lowerAbbrev == "end" || (lowerAbbrev == "e" && lowerName.contains("end"))
        })
        let endCutoffTime: TimeInterval? = currentSong.isContinueClickEffective(isLastSongInSetlist: currentSongIndex >= currentSetlist.songs.count - 1) ? nil : endSection?.startTime
        if let cutoff = endCutoffTime, nowSec > cutoff + downbeatFlashWindow {
            zeroAllClickMeters()
            return
        }
        
        // For uploaded click tracks, suppress flashing if the click stem has gone silent around nowSec
        if currentSong.clickSource == .uploaded, let upClick = uploadedClickBuffers[currentSong.id] {
            let sr = upClick.format.sampleRate
            let totalFrames = Int(upClick.frameLength)
            if sr > 0, totalFrames > 0, let ptr = upClick.floatChannelData?[0] {
                let startF = max(0, Int((sourceSec - 0.08) * sr))
                let endF = min(totalFrames, Int((sourceSec + 0.03) * sr))
                var maxAmp: Float = 0.0
                var idx = startF
                while idx < endF {
                    let a = abs(ptr[idx])
                    if a > maxAmp {
                        maxAmp = a
                        if maxAmp >= 0.002 { break }
                    }
                    idx += 16
                }
                if maxAmp < 0.002 {
                    zeroAllClickMeters()
                    return
                }
            }
        }
        
        let beatFloat: Double
        if let marker = activeMarker {
            let localBeat = max(0.0, (nowSec - marker.time) / max(0.05, beatSec))
            beatFloat = Double((max(1, marker.bar) - 1) * beatsPerBar + (max(1, marker.beat) - 1)) + localBeat
        } else {
            beatFloat = max(0.0, nowSec / max(0.05, beatSec))
        }
        
        let quarterPhase = beatFloat.truncatingRemainder(dividingBy: 1.0)
        let eighthPhase = (beatFloat * 2.0).truncatingRemainder(dividingBy: 1.0)
        let sixteenthPhase = (beatFloat * 4.0).truncatingRemainder(dividingBy: 1.0)
        let isBeatOne: Bool = {
            if let marker = activeMarker {
                return marker.beat == 1 && (nowSec - marker.time) < downbeatFlashWindow
            }
            return Int(floor(beatFloat)) % beatsPerBar == 0
        }()
        let isOnEndingDownbeat = endCutoffTime != nil && nowSec >= (endCutoffTime! - 0.01)
        
        func flashLevel(phase: Double, subPeriodSec: Double, volume: Float, enabled: Bool) -> Float {
            guard enabled && volume > 0.001 else { return 0.0 }
            let elapsed = phase * subPeriodSec
            let flashWindow = min(0.095, subPeriodSec * 0.42)
            guard elapsed < flashWindow else { return 0.0 }
            let decay = Float(1.0 - (elapsed / flashWindow))
            return min(1.0, max(0.0, volume * (0.45 + 0.55 * decay)))
        }
        
        let isSoloActive = !clickSoloedSubdivisions.isEmpty
        let accentOn = currentSong.clickAccentEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.accent))
        let quarterOn = currentSong.clickQuarterEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.quarter))
        let eighthOn = currentSong.clickEighthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.eighth))
        let sixteenthOn = currentSong.clickSixteenthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.sixteenth))
        
        let accentLvl = isBeatOne ? flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickAccentVolume, enabled: accentOn) : 0.0
        let quarterLvl = flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickQuarterVolume, enabled: quarterOn)
        let eighthLvl = isOnEndingDownbeat ? 0.0 : flashLevel(phase: eighthPhase, subPeriodSec: beatSec * 0.5, volume: currentSong.clickEighthVolume, enabled: eighthOn)
        let sixteenthLvl = isOnEndingDownbeat ? 0.0 : flashLevel(phase: sixteenthPhase, subPeriodSec: beatSec * 0.25, volume: currentSong.clickSixteenthVolume, enabled: sixteenthOn)
        
        clickAccentMeter.update(left: accentLvl, right: accentLvl, dt: dt)
        clickQuarterMeter.update(left: quarterLvl, right: quarterLvl, dt: dt)
        clickEighthMeter.update(left: eighthLvl, right: eighthLvl, dt: dt)
        clickSixteenthMeter.update(left: sixteenthLvl, right: sixteenthLvl, dt: dt)
        
        // Main Click track VU flashes on active click beats
        for track in tracks where track.isClickTrackCached {
            let anySubFlash = max(max(accentLvl, quarterLvl), max(eighthLvl * 0.85, sixteenthLvl * 0.70))
            let mainLvl: Float = track.isMuted ? 0.0 : min(1.0, anySubFlash * track.volume)
            track.peakLevelLeft = mainLvl
            track.peakLevelRight = mainLvl
            track.meter.update(left: mainLvl, right: mainLvl, dt: dt)
        }
    }

    func updatePostSongClickMeters(dt: TimeInterval = 1.0 / 60.0) {
        func zeroClick() {
            clickAccentMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickQuarterMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickEighthMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickSixteenthMeter.update(left: 0.0, right: 0.0, dt: dt)
            for track in tracks where track.isClickTrackCached {
                track.peakLevelLeft = 0.0
                track.peakLevelRight = 0.0
                track.meter.update(left: 0.0, right: 0.0, dt: dt)
            }
        }

        let status = mixState.currentPostSongClickStatus()
        guard status.isActive && status.totalFrames > 0 && !currentSong.excludesClickAndGuide else {
            zeroClick()
            return
        }

        let clickTrack = tracks.first { $0.isClickTrackCached }
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let clickBus = busses.first { $0.name.caseInsensitiveCompare("Click") == .orderedSame }
        let trackMuted: Bool = {
            guard let ct = clickTrack else { return false }
            return anyTrackSoloed ? ((!ct.isSoloed && !ct.isSoloSafe) || ct.isMuted) : ct.isMuted
        }()
        let busMuted: Bool = {
            guard let b = clickBus else { return anyBusSoloed }
            return anyBusSoloed ? ((!b.isSoloed && !b.isSoloSafe) || b.isMuted) : b.isMuted
        }()
        if trackMuted || busMuted {
            zeroClick()
            return
        }

        let beatsPerBar = max(1, activePostSongClickNumerator)
        let beatScale = 4.0 / Double(max(1, activePostSongClickDenominator))
        let beatSec = (60.0 / max(20.0, activePostSongClickBPM)) * beatScale
        let barProgress = max(0.0, min(0.999999, Double(status.currentFrame) / Double(status.totalFrames)))
        let beatFloat = barProgress * Double(beatsPerBar)
        let beatIndex = Int(floor(beatFloat)) % beatsPerBar
        let quarterPhase = beatFloat.truncatingRemainder(dividingBy: 1.0)
        let eighthPhase = (beatFloat * 2.0).truncatingRemainder(dividingBy: 1.0)
        let sixteenthPhase = (beatFloat * 4.0).truncatingRemainder(dividingBy: 1.0)
        let isBeatOne = (beatIndex == 0)

        func flashLevel(phase: Double, subPeriodSec: Double, volume: Float, enabled: Bool) -> Float {
            guard enabled && volume > 0.001 else { return 0.0 }
            let elapsed = phase * subPeriodSec
            let flashWindow = min(0.095, subPeriodSec * 0.42)
            guard elapsed < flashWindow else { return 0.0 }
            let decay = Float(1.0 - (elapsed / flashWindow))
            return min(1.0, max(0.0, volume * (0.45 + 0.55 * decay)))
        }

        let isSoloActive = !clickSoloedSubdivisions.isEmpty
        let accentOn = currentSong.clickAccentEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.accent))
        let quarterOn = currentSong.clickQuarterEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.quarter))
        let eighthOn = currentSong.clickEighthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.eighth))
        let sixteenthOn = currentSong.clickSixteenthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.sixteenth))

        let accentLvl = isBeatOne ? flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickAccentVolume, enabled: accentOn) : 0.0
        let quarterLvl = flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickQuarterVolume, enabled: quarterOn)
        let eighthLvl = flashLevel(phase: eighthPhase, subPeriodSec: beatSec * 0.5, volume: currentSong.clickEighthVolume, enabled: eighthOn)
        let sixteenthLvl = flashLevel(phase: sixteenthPhase, subPeriodSec: beatSec * 0.25, volume: currentSong.clickSixteenthVolume, enabled: sixteenthOn)

        clickAccentMeter.update(left: accentLvl, right: accentLvl, dt: dt)
        clickQuarterMeter.update(left: quarterLvl, right: quarterLvl, dt: dt)
        clickEighthMeter.update(left: eighthLvl, right: eighthLvl, dt: dt)
        clickSixteenthMeter.update(left: sixteenthLvl, right: sixteenthLvl, dt: dt)

        for track in tracks where track.isClickTrackCached {
            let anySubFlash = max(max(accentLvl, quarterLvl), max(eighthLvl * 0.85, sixteenthLvl * 0.70))
            let mainLvl: Float = track.isMuted ? 0.0 : min(1.0, anySubFlash * track.volume)
            track.peakLevelLeft = mainLvl
            track.peakLevelRight = mainLvl
            track.meter.update(left: mainLvl, right: mainLvl, dt: dt)
        }
    }
    
    public func removeTrack(id: UUID) {
        if !PlaybackFileManager.shared.hasValidCachedStem(for: id) {
            retainInUndoOrphanLRU(trackId: id, buffer: pristineMasterBuffers[id] ?? channels[id]?.buffer)
        }
        tracks.removeAll { $0.id == id }
        pristineMasterBuffers.removeValue(forKey: id)
        channels.removeValue(forKey: id)
        
        currentSongDuration = tracks.map { $0.duration }.max() ?? 0.0
        transportPosition.totalDuration = currentSongDuration
        transportClock.position.totalDuration = currentSongDuration
        recalculateAggregateWaveform(samplesCount: 4000)
        updateMatrix()
        markSessionChanged()
    }
    
    /// Reorders tracks in the mixer
    public func moveTrack(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0 && fromIndex < tracks.count,
              toIndex >= 0 && toIndex < tracks.count else { return }
        let moved = tracks.remove(at: fromIndex)
        tracks.insert(moved, at: toIndex)
        markSessionChanged()
        
        // Update songBuffersCache to maintain identical ordering
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            let activeSong = currentSetlist.songs[currentSongIndex]
            if let cached = songBuffersCache[activeSong.id] {
                var reordered: [(StemTrack, AVAudioPCMBuffer)] = []
                for t in tracks {
                    if let found = cached.first(where: { $0.0.id == t.id }) {
                        reordered.append(found)
                    }
                }
                if reordered.count == cached.count {
                    songBuffersCache[activeSong.id] = reordered
                }
            }
        }
    }
    
    /// Auto-sorts tracks according to standard MultiTracks canonical order:
    /// 1. Click, 2. Guide, 3. Drums, 4. Percussion, 5. Loops, 6. FX, 7. Bass, 8. Synth Bass,
    /// 9. Acoustic Guitars, 10. Electric Guitars, 11. Piano, 12. Organs, 13. Keys, 14. Arps,
    /// 15. Synths, 16. Orchestral, 17. Vocals, 18. Other
    public func autoSortTracks() {
        guard tracks.count > 1 else { return }
        tracks.sort { (t1, t2) -> Bool in
            let ord1 = StemCategory.playbackOrder(for: t1.name, role: t1.role)
            let ord2 = StemCategory.playbackOrder(for: t2.name, role: t2.role)
            if ord1 != ord2 {
                return ord1 < ord2
            }
            let cat1 = StemCategory.category(for: t1.name, role: t1.role)
            let cat2 = StemCategory.category(for: t2.name, role: t2.role)
            if cat1 != cat2 {
                return cat1 < cat2
            }
            return t1.name.localizedStandardCompare(t2.name) == .orderedAscending
        }
        
        // Ensure proper track role assignment based on detection
        for track in tracks {
            let cat = StemCategory.category(for: track.name, role: track.role)
            if cat == .click {
                track.role = .click
            } else if cat == .guide {
                track.role = .guide
            }
        }
        
        // Update songBuffersCache to maintain identical ordering
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            let activeSong = currentSetlist.songs[currentSongIndex]
            if let cached = songBuffersCache[activeSong.id] {
                var reordered: [(StemTrack, AVAudioPCMBuffer)] = []
                for t in tracks {
                    if let found = cached.first(where: { $0.0.id == t.id }) {
                        reordered.append(found)
                    }
                }
                if reordered.count == cached.count {
                    songBuffersCache[activeSong.id] = reordered
                }
            }
        }
        
        updateMatrix()
        objectWillChange.send()
    }
    
    /// Ensures Click and Guide channel strips are immediately present at canonical MultiTracks positions
    /// (Click at Position 1, Guide at Position 2) with silent initial buffers, and triggers fast background synthesis.
    public func ensureClickAndGuideTracksExist(duration: TimeInterval? = nil) {
        if currentSong.excludesClickAndGuide { return }
        let canonicalFormat = getCanonicalProcessingFormat()
        let sampleRate = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
        let musicalMaxDur = tracks.filter { !Self.isClickOrGuideTrack($0) }.map { $0.duration }.max() ?? 0.0
        let uploadedUtilMaxDur = tracks.filter { Self.isClickOrGuideTrack($0) && $0.fileURL != nil }.map { $0.duration }.max() ?? 0.0
        let sectionsEndDur = !currentSong.sections.isEmpty ? (currentSong.sections.map { $0.endTime }.max() ?? 0.0) : 0.0
        let knownDur = max(musicalMaxDur, uploadedUtilMaxDur, duration ?? 0.0, sectionsEndDur)
        let masterDur = knownDur > 0.1 ? knownDur : (currentSongDuration > 0.1 ? currentSongDuration : 240.0)
        let initialFrames = AVAudioFrameCount(max(1, Int64(round(masterDur * sampleRate))))

        if knownDur > 0.1 {
            for utility in tracks where Self.isClickOrGuideTrack(utility) && utility.fileURL == nil {
                if abs(utility.duration - masterDur) > 0.05 {
                    utility.duration = masterDur
                }
            }
            if currentSong.sections.isEmpty && abs(currentSongDuration - masterDur) > 0.05 {
                currentSongDuration = masterDur
                transportPosition.totalDuration = currentSongDuration
                transportClock.position.totalDuration = currentSongDuration
                transportDisplayClock.update(with: transportPosition)
            }
        }
        
        var didAdd = false
        
        // 1. Ensure Click track exists
        if !tracks.contains(where: { $0.role == .click || StemCategory.category(for: $0.name, role: $0.role) == .click }) {
            let newClick = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
            newClick.duration = masterDur
            tracks.append(newClick)
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                channels[newClick.id] = TrackChannel(track: newClick, buffer: silentBuf)
                pristineMasterBuffers[newClick.id] = silentBuf
            }
            didAdd = true
        }
        
        // 2. Ensure Guide track exists
        if !tracks.contains(where: { $0.role == .guide || StemCategory.category(for: $0.name, role: $0.role) == .guide }) {
            let newGuide = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
            newGuide.duration = masterDur
            tracks.append(newGuide)
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                channels[newGuide.id] = TrackChannel(track: newGuide, buffer: silentBuf)
                pristineMasterBuffers[newGuide.id] = silentBuf
            }
            didAdd = true
        }
        
        // If the song has no uploaded click or guide file, default source to .generated; otherwise use user's default preference
        if uploadedClickBuffers[currentSong.id] == nil {
            currentSong.clickSource = .generated
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].clickSource = .generated
            }
        } else {
            let src = defaultClickSourcePreference
            currentSong.clickSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].clickSource = src
            }
            applyClickBuffer()
        }
        
        if uploadedGuideBuffers[currentSong.id] == nil {
            currentSong.guideSource = .generated
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].guideSource = .generated
            }
        } else {
            let src = defaultGuideSourcePreference
            currentSong.guideSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].guideSource = src
            }
            applyGuideBuffer()
        }
        
        // Canonical ordering: Click is ALWAYS position 1, Guide is ALWAYS position 2
        autoSortTracks()
        updateMatrix()
        syncMixState()
        
        // Trigger fast background generation
        regenerateClickTrack()
        regenerateGuideTrack()
        
        objectWillChange.send()
    }
    
    public func clearAllTracks() {
        stop()
        channels.removeAll()
        pristineMasterBuffers.removeAll()
        tracks.removeAll()
        aggregateWaveform.removeAll()
        masterWaveformPeaks.removeAll()
        soloWaveformPeaks = nil
        lastSoloWaveformTrackIds = []
        renderedWaveformImage = nil
        waveformVersion &+= 1
        currentSongDuration = 0.0
        transportPosition = TransportPosition()
        transportClock.position = TransportPosition()
        activeManualFade = nil
        isFadedOut = false
        isFadeActive = false
        currentFadeGain = 1.0
        preFadeVolumes.removeAll()
        songEndBaseVolumes.removeAll()
        isLoopActive = false
        loopedSection = nil
        isTransposing = false
        transposeProgress = 0.0
        transposingSongId = nil
        syncMixState()
    }
    
    // MARK: - Solo Waveform & Clear Solos

    public var hasAnySolo: Bool {
        tracks.contains(where: { $0.isSoloed }) ||
        busses.contains(where: { $0.isSoloed }) ||
        padChannelSoloed
    }

    public func clearAllSolos() {
        guard hasAnySolo else { return }
        for track in tracks where track.isSoloed {
            track.isSoloed = false
        }
        for bus in busses where bus.isSoloed {
            bus.isSoloed = false
        }
        if padChannelSoloed {
            padChannelSoloed = false
        }
        markSessionChanged()
        updateMatrix()
    }

    private func resolvedBusForWaveform(track: StemTrack) -> AudioBus? {
        if let direct = busses.first(where: { $0.name.lowercased() == track.assignedBusName.lowercased() }) {
            return direct
        }
        let autoBusName = StemTrack.autoAssignBus(for: track.name)
        return busses.first(where: { $0.name.lowercased() == autoBusName.lowercased() })
    }

    func soloedMusicalWaveformTracks() -> [StemTrack] {
        let eligible = tracks.filter { $0.includeInWaveform && !Self.isClickOrGuideTrack($0) }
        guard !eligible.isEmpty else { return [] }

        let directSoloed = eligible.filter { $0.isSoloed }
        let soloedBusNames = Set(busses.filter { $0.isSoloed }.map { $0.name.lowercased() })
        let busSoloed: [StemTrack] = soloedBusNames.isEmpty ? [] : eligible.filter { track in
            guard let bus = resolvedBusForWaveform(track: track) else { return false }
            return soloedBusNames.contains(bus.name.lowercased())
        }

        if !directSoloed.isEmpty && !busSoloed.isEmpty {
            let directIds = Set(directSoloed.map { $0.id })
            let intersection = busSoloed.filter { directIds.contains($0.id) }
            if !intersection.isEmpty {
                return intersection
            }
            let busIds = Set(busSoloed.map { $0.id })
            return eligible.filter { directIds.contains($0.id) || busIds.contains($0.id) }
        } else if !directSoloed.isEmpty {
            return directSoloed
        } else if !busSoloed.isEmpty {
            return busSoloed
        }
        return []
    }

    public func refreshSoloWaveformIfNeeded(forceRecompute: Bool = false, triggerArrangementUpdate: Bool = true) {
        let soloedStems = soloedMusicalWaveformTracks()
        for stem in soloedStems where stem.waveformPeaks.isEmpty {
            if let buf = pristineMasterBuffers[stem.id] ?? channels[stem.id]?.buffer, buf.frameLength > 100 {
                stem.waveformPeaks = extractWaveformPeaks(from: buf, samplesCount: 4000)
            }
        }
        let stemsWithPeaks = soloedStems.filter { !$0.waveformPeaks.isEmpty }
        let targetIds = stemsWithPeaks.map { $0.id }

        if !forceRecompute && targetIds == lastSoloWaveformTrackIds {
            return
        }
        lastSoloWaveformTrackIds = targetIds

        if stemsWithPeaks.isEmpty {
            let wasShowingSolo = (soloWaveformPeaks != nil)
            soloWaveformPeaks = nil
            if triggerArrangementUpdate && (wasShowingSolo || forceRecompute) {
                updateArrangementWaveform()
            }
            return
        }

        let musicalMaxDuration = tracks.filter { $0.includeInWaveform && !Self.isClickOrGuideTrack($0) }.map { $0.duration }.max() ?? 0.0
        let fallbackDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let masterDuration = max(0.01, musicalMaxDuration > 0.01 ? musicalMaxDuration : fallbackDuration)
        soloWaveformPeaks = combineWaveformPeaks(for: stemsWithPeaks, masterDuration: masterDuration, samplesCount: 4000)
        if triggerArrangementUpdate {
            updateArrangementWaveform()
        }
    }

    private func combineWaveformPeaks(for stems: [StemTrack], masterDuration: TimeInterval, samplesCount: Int = 4000) -> [Float] {
        guard !stems.isEmpty, samplesCount > 0 else { return [] }
        let safeMasterDuration = max(0.01, masterDuration)
        var combined = Array(repeating: Float(0.0), count: samplesCount)
        for stem in stems {
            let peaks = stem.waveformPeaks
            guard !peaks.isEmpty else { continue }
            let stemDuration = stem.duration > 0 ? stem.duration : safeMasterDuration
            let durationRatio = safeMasterDuration / max(0.01, stemDuration)
            let maxPeakIndex = peaks.count - 1

            for i in 0..<samplesCount {
                let songProgress = Double(i) / Double(max(1, samplesCount - 1))
                let stemProgress = songProgress * durationRatio
                if stemProgress <= 1.0 {
                    let srcIdx = min(maxPeakIndex, max(0, Int(round(stemProgress * Double(maxPeakIndex)))))
                    combined[i] += peaks[srcIdx]
                }
            }
        }

        let maxVal = combined.max() ?? 1.0
        if maxVal > 0.01 {
            return combined.map { peak in
                let norm = peak / maxVal
                return min(1.0, pow(norm, 0.72))
            }
        } else {
            return combined
        }
    }

    // MARK: - Aggregate Waveform Calculation & Pre-Rendering (Excludes Click & Guide)
    
    public func recalculateAggregateWaveform(samplesCount: Int = 4000) {
        // Exclude tracks that have includeInWaveform == false (Click, Guide, Tick, etc.)
        let musicalStems = tracks.filter { $0.includeInWaveform }
        guard !musicalStems.isEmpty else {
            masterWaveformPeaks = []
            soloWaveformPeaks = nil
            lastSoloWaveformTrackIds = []
            aggregateWaveform = []
            renderedWaveformImage = nil
            waveformVersion &+= 1
            return
        }
        
        let musicalMaxDuration = musicalStems.map { $0.duration }.max() ?? 0.0
        let fallbackDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let masterDuration = max(0.01, musicalMaxDuration > 0.01 ? musicalMaxDuration : fallbackDuration)
        masterWaveformPeaks = combineWaveformPeaks(for: musicalStems, masterDuration: masterDuration, samplesCount: samplesCount)
        if !masterWaveformPeaks.isEmpty {
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, nil)
        }
        refreshSoloWaveformIfNeeded(forceRecompute: true, triggerArrangementUpdate: false)
        updateArrangementWaveform()
    }
    
    // MARK: - Arrangement Waveform Mapping & Non-Destructive Slicing
    
    /// Re-renders the aggregate waveform reflecting the current active arrangement
    public func updateArrangementWaveform() {
        let isShowingSoloWaveform = (soloWaveformPeaks != nil)
        let sourcePeaks = soloWaveformPeaks ?? masterWaveformPeaks
        guard !sourcePeaks.isEmpty else {
            renderedWaveformImage = nil
            aggregateWaveform = []
            waveformVersion &+= 1
            return
        }
        
        let musicalMaxDuration = tracks.filter { $0.includeInWaveform }.map { $0.duration }.max() ?? 0.0
        let fallbackDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let masterDuration = musicalMaxDuration > 0.01 ? musicalMaxDuration : fallbackDuration
        guard masterDuration > 0 else {
            aggregateWaveform = sourcePeaks
            renderedWaveformImage = nil
            waveformVersion &+= 1
            return
        }
        
        let inEditMode = isEditingArrangement
        let secs = inEditMode ? displaySections : currentSong.sections
        let sorted = secs.sorted { $0.startTime < $1.startTime }
        let maxSectionEnd = sorted.last?.endTime ?? masterDuration
        let fullDuration = !sorted.isEmpty ? maxSectionEnd : masterDuration
        
        let hasClickSections = sorted.contains { $0.effectiveIsClickSection }
        let isLinearSequence = !hasClickSections && (sorted.isEmpty || sorted.allSatisfy { abs($0.startTime - $0.sourceAudioStartTime) < 0.005 })
        
        // Fast zero-drift path when in edit mode with linear sequence (so full waveform is displayed!)
        if inEditMode && isLinearSequence && abs(fullDuration - masterDuration) < 0.05 {
            aggregateWaveform = sourcePeaks
            renderedWaveformImage = nil
            if !isShowingSoloWaveform && !masterWaveformPeaks.isEmpty {
                songWaveformCache[currentSong.id] = (masterWaveformPeaks, nil)
            }
            waveformVersion &+= 1
            return
        }
        
        let hasTrimmedSections = sorted.contains { $0.isTrimmed }
        let isLinearUnmodifiedArrangement = !hasClickSections && !hasTrimmedSections && isLinearSequence && abs(fullDuration - masterDuration) < 0.05
        
        // Fast zero-drift path when sections have not been non-destructively rearranged or trimmed
        if !inEditMode && isLinearUnmodifiedArrangement {
            aggregateWaveform = sourcePeaks
            renderedWaveformImage = nil
            if !isShowingSoloWaveform && !masterWaveformPeaks.isEmpty {
                songWaveformCache[currentSong.id] = (masterWaveformPeaks, nil)
            }
            waveformVersion &+= 1
            return
        }
        
        let masterCount = sourcePeaks.count
        guard masterCount > 1, fullDuration > 0 else { return }
        
        let targetSamples = 4000
        var arrangedPeaks = [Float](repeating: 0.0, count: targetSamples)
        let clickPeaks = tracks.first(where: { $0.role == .click })?.waveformPeaks ?? []
        let clickPeakMax = clickPeaks.max() ?? 0.0
        let beatSec = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let beatsPerBar = max(1, currentSong.timeSignatureNumerator)
        let sampleWindow = fullDuration / Double(targetSamples)
        
        // Direct sample-by-sample timeline -> source audio time mapping (zero per-slice rounding drift!)
        for i in 0..<targetSamples {
            let arrTime = (Double(i) / Double(max(1, targetSamples - 1))) * fullDuration
            if let clickSec = sorted.first(where: { $0.effectiveIsClickSection && arrTime >= $0.startTime && arrTime < $0.endTime }) {
                if isShowingSoloWaveform {
                    arrangedPeaks[i] = 0.0
                } else if !clickPeaks.isEmpty && clickPeakMax > 0.02 {
                    let cFrac = max(0.0, min(1.0, arrTime / max(0.01, masterDuration)))
                    let cIdx = min(clickPeaks.count - 1, max(0, Int(round(cFrac * Double(clickPeaks.count - 1)))))
                    arrangedPeaks[i] = min(1.0, (clickPeaks[cIdx] / clickPeakMax) * 0.72)
                } else {
                    let rel = max(0.0, arrTime - clickSec.startTime)
                    let beatFloat = rel / max(0.05, beatSec)
                    let nearestBeat = round(beatFloat)
                    let distSec = abs(beatFloat - nearestBeat) * beatSec
                    if distSec <= max(0.018, sampleWindow * 0.9) {
                        let isDownbeat = Int(nearestBeat) % beatsPerBar == 0
                        arrangedPeaks[i] = isDownbeat ? 0.62 : 0.36
                    } else {
                        arrangedPeaks[i] = 0.0
                    }
                }
                continue
            }
            let srcTime = audioTime(forArrangementTime: arrTime)
            let srcFrac = max(0.0, min(1.0, srcTime / masterDuration))
            let masterPos = Double(masterCount - 1) * srcFrac
            let lowIdx = Int(floor(masterPos))
            let highIdx = min(masterCount - 1, lowIdx + 1)
            let frac = Float(masterPos - Double(lowIdx))
            let p0 = sourcePeaks[max(0, min(masterCount - 1, lowIdx))]
            let p1 = sourcePeaks[highIdx]
            arrangedPeaks[i] = p0 * (1.0 - frac) + p1 * frac
        }
        
        aggregateWaveform = arrangedPeaks
        renderedWaveformImage = nil
        if !isShowingSoloWaveform && !masterWaveformPeaks.isEmpty {
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, nil)
        }
        waveformVersion &+= 1
    }
    
    public func generateArrangedWaveform() {
        updateArrangementWaveform()
    }
    
    /// Maps an arrangement timeline position to its corresponding source audio position
    public func audioTime(forArrangementTime arrTime: TimeInterval) -> TimeInterval {
        let inEditMode = isEditingArrangement
        let secs = inEditMode ? displaySections : currentSong.sections
        guard !secs.isEmpty else { return arrTime }
        if let sec = secs.first(where: { arrTime >= $0.startTime && arrTime < $0.endTime }) {
            let offset = arrTime - sec.startTime
            return sec.sourceAudioStartTime + offset
        } else if let lastSec = secs.last, arrTime >= lastSec.endTime {
            return inEditMode ? (lastSec.sourceAudioStartTime + (arrTime - lastSec.startTime)) : (lastSec.sourceAudioStartTime + lastSec.duration)
        } else if let firstSec = secs.first, arrTime < firstSec.startTime {
            return firstSec.sourceAudioStartTime
        }
        return arrTime
    }
    
    /// Pre-renders ultra-fine retina audio waveform texture via modern offscreen bitmap graphics context
    func generatePreRenderedWaveformImage(peaks: [Float], width: CGFloat = 2400, height: CGFloat = 233) -> NSImage? {
        guard !peaks.isEmpty, width > 0, height > 0 else { return nil }
        let scale: CGFloat = 2.0
        let pxW = max(1, Int(ceil(width * scale)))
        let pxH = max(1, Int(ceil(height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext
        
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        
        let midY = height * 0.50
        let maxAmp = height * 0.30 // Equal ~50pt margin above (for section pills) and below (for cues track)
        let count = peaks.count
        let step = width / CGFloat(max(1, count - 1))
        
        // 1. Build smooth mirrored symmetrical contour path
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: midY))
        for i in 0..<count {
            let x = CGFloat(i) * step
            let peak = CGFloat(max(0.015, peaks[i]))
            let y = midY - (peak * maxAmp)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: midY))
        for i in (0..<count).reversed() {
            let x = CGFloat(i) * step
            let peak = CGFloat(max(0.015, peaks[i]))
            let y = midY + (peak * maxAmp)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        
        // 2. MultiTracks silver-slate gradient fill
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.95, alpha: 0.95).cgColor,
            NSColor(calibratedRed: 0.75, green: 0.79, blue: 0.83, alpha: 0.90).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.59, blue: 0.63, alpha: 0.85).cgColor
        ] as CFArray
        
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 0.5, 1.0]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
        
        // 3. Crisp anti-aliased vertical transient lines (1px fine lines across the body)
        ctx.setLineWidth(1.0)
        let strokeColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.45).cgColor
        ctx.setStrokeColor(strokeColor)
        
        for i in stride(from: 0, to: count, by: 2) {
            let peak = CGFloat(peaks[i])
            if peak > 0.035 {
                let x = CGFloat(i) * step
                let amp = peak * maxAmp
                ctx.strokeLineSegments(between: [
                    CGPoint(x: x, y: midY - amp),
                    CGPoint(x: x, y: midY + amp)
                ])
            }
        }
        
        // 4. Center zero crossing line
        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.25).cgColor)
        ctx.strokeLineSegments(between: [
            CGPoint(x: 0, y: midY),
            CGPoint(x: width, y: midY)
        ])
        
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
    
    // MARK: - Mixer Matrix & Output Routing
    
    static func busLinearGain(forFader volume: Float) -> Float {
        if volume <= 0.001 { return 0.0 }
        if volume >= 0.80 {
            let db = ((volume - 0.80) / 0.20) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = volume / 0.80
            return pow(norm, 2.0)
        }
    }

    public func updateTrackParameters(track: StemTrack) {
        markSessionChanged()
        updateMatrix()
        if isEditAutomationMode {
            recordCurrentAutomationPointValues()
        } else {
            let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
            let firstAffectingTime = activePoints
                .filter { $0.trackFaders[track.id] != nil || $0.trackPans[track.id] != nil || $0.trackMutes[track.id] != nil }
                .map { displayTime(forAutomationPoint: $0) }
                .min()
            let isPreAutomation = firstAffectingTime.map { playbackOffsetSeconds < $0 - 0.005 } ?? true
            if isPreAutomation || !isTrackAutomated(track.id) {
                baseTrackVolumes[track.id] = track.volume
                baseTrackPans[track.id] = track.pan
                baseTrackMutes[track.id] = track.isMuted
            }
        }
    }

    public func updateBusParameters(bus: AudioBus) {
        markSessionChanged()
        updateMatrix()
        if isEditAutomationMode {
            recordCurrentAutomationPointValues()
        } else {
            let busLower = bus.name.lowercased()
            let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
            let firstAffectingTime = activePoints
                .filter { pt in
                    pt.busFaders.keys.contains { $0.lowercased() == busLower } ||
                    pt.busMutes.keys.contains { $0.lowercased() == busLower }
                }
                .map { displayTime(forAutomationPoint: $0) }
                .min()
            let isPreAutomation = firstAffectingTime.map { playbackOffsetSeconds < $0 - 0.005 } ?? true
            if isPreAutomation || !isBusAutomated(bus.name) {
                baseBusVolumes[bus.name] = bus.volume
                baseBusMutes[bus.name] = bus.isMuted
            }
        }
    }

    /// Fast-path gain & pan update for a single track during live fader/pan dragging.
    /// Avoids looping all channels, writing UserDefaults, or invalidating MainView via `markSessionChanged()` / `objectWillChange`.
    public func updateSingleTrackGain(_ track: StemTrack) {
        if activeManualFade != nil {
            activeManualFade?.overriddenTrackIds.insert(track.id)
            if track.volume > 0.001 {
                preFadeVolumes[track.id] = track.volume
            }
        }
        guard let channel = channels[track.id] else { return }
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let result = computeTrackOutputGain(
            track: track,
            channel: channel,
            anyTrackSoloed: anyTrackSoloed,
            anyBusSoloed: anyBusSoloed
        )
        mixState.updateAllTrackGains([track.id: result])
    }

    /// Fast-path gain update for all tracks routed to a single bus during live bus fader dragging.
    public func updateSingleBusGain(_ bus: AudioBus) {
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let targetBusLower = bus.name.lowercased()
        var gainsToUpdate: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)] = [:]

        for channel in channels.values where channel.track.assignedBusName.lowercased() == targetBusLower {
            gainsToUpdate[channel.track.id] = computeTrackOutputGain(
                track: channel.track,
                channel: channel,
                anyTrackSoloed: anyTrackSoloed,
                anyBusSoloed: anyBusSoloed
            )
        }
        if targetBusLower == "pad" {
            let busMuted = anyBusSoloed ? (!bus.isSoloed || bus.isMuted) : bus.isMuted
            padPlayer.setBusGain(busMuted ? 0.0 : bus.linearGain)
        }
        if !gainsToUpdate.isEmpty {
            mixState.updateAllTrackGains(gainsToUpdate)
        }
    }

    func computeTrackOutputGain(
        track: StemTrack,
        channel: TrackChannel,
        anyTrackSoloed: Bool,
        anyBusSoloed: Bool
    ) -> (gainL: Float, gainR: Float, outL: Int, outR: Int) {
        // Find assigned bus (or fallback to auto-assign match)
        var bus = busses.first { $0.name.lowercased() == track.assignedBusName.lowercased() }
        if bus == nil {
            let autoBusName = StemTrack.autoAssignBus(for: track.name)
            bus = busses.first { $0.name.lowercased() == autoBusName.lowercased() }
            if let matched = bus {
                track.assignedBusName = matched.name
            }
        }

        // 1. Track-level mute / solo / solo-safe
        let trackMuted: Bool
        if anyTrackSoloed {
            trackMuted = (!track.isSoloed && !track.isSoloSafe) || track.isMuted
        } else {
            trackMuted = track.isMuted
        }

        // 2. Bus-level mute / solo / solo-safe
        let busMuted: Bool
        if let b = bus {
            if anyBusSoloed {
                busMuted = (!b.isSoloed && !b.isSoloSafe) || b.isMuted
            } else {
                busMuted = b.isMuted
            }
        } else {
            busMuted = anyBusSoloed
        }

        let effectiveMute = trackMuted || busMuted

        var gain = effectiveMute ? 0.0 : track.linearGain
        if let b = bus {
            gain *= b.linearGain
        }

        if !Self.isClickOrGuideTrack(track) {
            gain *= currentFadeGain
        }

        // Compute stereo pan law gains (unity at center 0.0)
        let effectivePan: Float
        if let b = bus, b.isMono {
            effectivePan = 0.0
        } else {
            effectivePan = max(-1.0, min(1.0, track.pan))
        }

        let gainL: Float
        let gainR: Float
        if effectivePan < 0.0 {
            gainL = gain
            gainR = gain * (1.0 + effectivePan)
        } else if effectivePan > 0.0 {
            gainL = gain * (1.0 - effectivePan)
            gainR = gain
        } else {
            gainL = gain
            gainR = gain
        }

        channel.effectiveGainL = gainL
        channel.effectiveGainR = gainR

        let (outL, outR) = resolvePhysicalOutputChannels(for: bus?.physicalOutputChannel ?? "Out 1/2", isMono: bus?.isMono ?? false)
        channel.outChannelL = outL
        channel.outChannelR = outR
        return (gainL, gainR, outL, outR)
    }
    
    /// Updates real-time stem channel gains in `mixState` without encoding bus presets to UserDefaults
    /// or firing `engine.objectWillChange.send()`, keeping `WaveformTimelineView` and `MainView` untouched.
    func updateAllNonPadTrackGainsFastPath() {
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        var gainsToUpdate: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)] = [:]
        gainsToUpdate.reserveCapacity(channels.count)

        for channel in channels.values {
            gainsToUpdate[channel.track.id] = computeTrackOutputGain(
                track: channel.track,
                channel: channel,
                anyTrackSoloed: anyTrackSoloed,
                anyBusSoloed: anyBusSoloed
            )
        }

        if playbackState == .playing || isAnnouncingSong {
            mixState.updateAllTrackGains(gainsToUpdate)
        } else {
            syncMixState()
        }
    }

    public func updateMatrix(persistBusRouting: Bool = true) {
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        
        var gainsToUpdate: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)] = [:]
        
        for channel in channels.values {
            gainsToUpdate[channel.track.id] = computeTrackOutputGain(
                track: channel.track,
                channel: channel,
                anyTrackSoloed: anyTrackSoloed,
                anyBusSoloed: anyBusSoloed
            )
        }
        
        // Update ambient Pad Player output routing
        let padBus = busses.first { $0.name.lowercased() == "pad" }
        let (padL, padR) = resolvePhysicalOutputChannels(for: padBus?.physicalOutputChannel ?? "Out 1/2", isMono: padBus?.isMono ?? false)
        padPlayer.setTargetOutputChannels(left: padL, right: padR)
        
        // Update ambient Pad Player channel fader gain (channel strip feeding into Pad bus)
        let padChannelGain: Float
        if padChannelMuted || (anyTrackSoloed && !padChannelSoloed) {
            padChannelGain = 0.0
        } else if padChannelVolume <= 0.01 {
            padChannelGain = 0.0
        } else if padChannelVolume >= 0.80 {
            let db = ((padChannelVolume - 0.80) / 0.20) * 6.0
            padChannelGain = pow(10.0, db / 20.0)
        } else {
            let norm = (padChannelVolume - 0.01) / 0.79
            let db = -60.0 * (1.0 - norm)
            padChannelGain = pow(10.0, db / 20.0)
        }
        padPlayer.setVolume(padChannelGain)
        padPlayer.setPan(padChannelPan)
        
        // Update ambient Pad Player bus gain
        if let padBus = busses.first(where: { $0.name.lowercased() == "pad" }) {
            let busMuted = anyBusSoloed ? (!padBus.isSoloed || padBus.isMuted) : padBus.isMuted
            padPlayer.setBusGain(busMuted ? 0.0 : padBus.linearGain)
        } else {
            padPlayer.setBusGain(anyBusSoloed ? 0.0 : 1.0)
        }
        
        if playbackState == .playing || isAnnouncingSong {
            mixState.updateAllTrackGains(gainsToUpdate)
        } else {
            syncMixState()
        }
        if persistBusRouting {
            saveBusRouting(for: deviceManager.selectedDevice)
        }
        refreshSoloWaveformIfNeeded()
        objectWillChange.send()
    }
    
    public static func masterLinearGain(for normalizedVolume: Float) -> Float {
        let v = max(0.0, min(1.0, normalizedVolume))
        if v <= 0.01 {
            return 0.0
        } else if v >= 0.75 {
            let db = ((v - 0.75) / 0.25) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = (v - 0.01) / 0.74
            let db = -60.0 * (1.0 - norm)
            return pow(10.0, db / 20.0)
        }
    }

    public var currentMasterLinearGain: Float {
        Self.masterLinearGain(for: liveInteractiveMasterVolume ?? masterVolume)
    }

    func updateMasterVolume() {
        let gain = currentMasterLinearGain
        masterMixer.outputVolume = gain
        mixState.setMasterGain(gain)
    }

    /// Updates real-time Master output gain immediately during interactive fader drags without
    /// mutating `@Published masterVolume`, firing `engine.objectWillChange`, or running `markSessionChanged()`.
    public func applyInteractiveMasterVolume(_ normalizedVolume: Float) {
        let clamped = max(0.0, min(1.0, normalizedVolume))
        liveInteractiveMasterVolume = clamped
        let gain = Self.masterLinearGain(for: clamped)
        masterMixer.outputVolume = gain
        mixState.setMasterGain(gain)
    }

    /// Commits a finished interactive Master Fader drag to `@Published masterVolume`, triggering
    /// session change marking and a single clean Undo checkpoint.
    public func commitInteractiveMasterVolume(_ finalVol: Float) {
        let clamped = max(0.0, min(1.0, finalVol))
        if abs(masterVolume - clamped) > 0.0001 {
            masterVolume = clamped
        } else {
            liveInteractiveMasterVolume = nil
            updateMasterVolume()
        }
    }

    /// Updates Master volume for continuous external streams (MIDI CC / Remote WebSocket) while coalescing
    /// `markSessionChanged()` undo snapshotting to a 300 ms trailing debounce.
    public func setMasterVolumeContinuous(_ normalizedVolume: Float) {
        let clamped = max(0.0, min(1.0, normalizedVolume))
        guard abs(masterVolume - clamped) > 0.0001 else { return }
        suppressMasterVolumeSessionMark = true
        masterVolume = clamped
        suppressMasterVolumeSessionMark = false
        masterVolumeCommitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.markSessionChanged()
        }
        masterVolumeCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }
    
    func updateTransportPosition(to seconds: TimeInterval) {
        let bpm = currentSong.bpm
        let timeSig = max(1, currentSong.timeSignatureNumerator)
        let bar: Int
        let beat: Int
        let liveBPM: Double
        
        let sourceSec = audioTime(forArrangementTime: seconds)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sourceSec)
        let activeGrid = cachedEffectiveBeatGrid
        var matchedMarker: BeatGridMarker? = nil
        if !activeGrid.isEmpty {
            let target = seconds + 0.0005
            var low = 0
            var high = activeGrid.count - 1
            var bestIdx = -1
            while low <= high {
                let mid = (low + high) / 2
                if activeGrid[mid].time <= target {
                    bestIdx = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            if bestIdx >= 0 {
                matchedMarker = activeGrid[bestIdx]
            }
        }
        if let timelineMarker = matchedMarker {
            bar = timelineMarker.bar
            beat = timelineMarker.beat
            liveBPM = !currentSong.tempoEvents.isEmpty
                ? currentSong.evaluateBPM(atSourceTime: sourceSec)
                : (currentSong.activeMarker(at: sourceSec)?.instantaneousBPM ?? timelineMarker.instantaneousBPM)
        } else if let timelineMarker = currentSong.activeMarker(at: seconds) {
            bar = timelineMarker.bar
            beat = timelineMarker.beat
            liveBPM = !currentSong.tempoEvents.isEmpty
                ? currentSong.evaluateBPM(atSourceTime: sourceSec)
                : (currentSong.activeMarker(at: sourceSec)?.instantaneousBPM ?? timelineMarker.instantaneousBPM)
        } else {
            let secondsPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, tsDen)))
            let totalBeats = Int(seconds / secondsPerBeat)
            bar = (totalBeats / max(1, tsNum)) + 1
            beat = (totalBeats % max(1, tsNum)) + 1
            liveBPM = !currentSong.tempoEvents.isEmpty ? currentSong.evaluateBPM(atSourceTime: sourceSec) : bpm
        }
        
        let secIdx = currentSong.sections.firstIndex(where: { seconds >= $0.startTime && seconds < $0.endTime }) ?? 0
        
        let updated = TransportPosition(
            currentTime: seconds,
            totalDuration: currentSongDuration,
            bar: bar,
            beat: beat,
            currentSectionIndex: secIdx,
            currentBPM: liveBPM,
            currentTimeSignatureNumerator: tsNum,
            currentTimeSignatureDenominator: tsDen
        )
        transportPosition = updated
        transportClock.position = updated
        transportDisplayClock.update(with: updated)
    }
    
    func resetTrackMeters(_ targetTracks: [StemTrack]) {
        for track in targetTracks {
            track.peakLevelLeft = 0.0
            track.peakLevelRight = 0.0
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            track.meter.reset()
        }
    }

    func resetPeakLevels() {
        resetTrackMeters(tracks)
        for bus in busses {
            bus.peakLevelLeft = 0.0
            bus.peakLevelRight = 0.0
            bus.rawPeakL = 0.0
            bus.rawPeakR = 0.0
            bus.meter.reset()
        }
        masterPeakLeft = 0.0
        masterPeakRight = 0.0
        rawMasterPeakL = 0.0
        rawMasterPeakR = 0.0
        masterMeter.reset()
        resetClickMeters()
    }
    
    func extractWaveformPeaks(from buffer: AVAudioPCMBuffer, samplesCount: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0, samplesCount > 0 else {
            return Array(repeating: 0.1, count: max(1, samplesCount))
        }
        
        let totalFrames = Int(buffer.frameLength)
        var peaks = [Float](repeating: 0.0, count: samplesCount)
        
        // SIMD-accelerated peak extraction via `vDSP_maxmgv` using floating-point frame bounds so 0..samplesCount spans 100% of audio
        for bucket in 0..<samplesCount {
            let startFrame = Int((Double(bucket) * Double(totalFrames)) / Double(samplesCount))
            let endFrame = min(totalFrames, max(startFrame + 1, Int((Double(bucket + 1) * Double(totalFrames)) / Double(samplesCount))))
            let count = endFrame - startFrame
            if count > 0 {
                var maxPeak: Float = 0.0
                vDSP_maxmgv(channelData.advanced(by: startFrame), 1, &maxPeak, vDSP_Length(count))
                peaks[bucket] = min(1.0, maxPeak)
            }
        }
        return peaks
    }
    
}
