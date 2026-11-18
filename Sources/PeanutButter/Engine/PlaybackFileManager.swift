import Foundation
import AVFoundation
import Accelerate
import AppKit
import Darwin

/// Serialized track metadata inside a .pbsong or .pbsession package
public struct TrackFileMetadata: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var role: TrackRole
    public var relativeAudioPath: String
    public var volume: Float
    public var pan: Float
    public var isMuted: Bool
    public var isSoloed: Bool
    public var isSoloSafe: Bool
    public var routing: OutputRoutingOption
    public var assignedBusName: String
    public var includeInWaveform: Bool
    public var duration: TimeInterval?
    public var waveformPeaksData: Data?
    public var relativeTransposedAudioPath: String?
    public var transposedSemitones: Int?
    public var sourceFilePath: String?
    
    public init(
        id: UUID = UUID(),
        name: String,
        role: TrackRole,
        relativeAudioPath: String,
        volume: Float = 0.80,
        pan: Float = 0.0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isSoloSafe: Bool = false,
        routing: OutputRoutingOption = .mainOut,
        assignedBusName: String = "Tracks",
        includeInWaveform: Bool = true,
        duration: TimeInterval? = nil,
        waveformPeaksData: Data? = nil,
        relativeTransposedAudioPath: String? = nil,
        transposedSemitones: Int? = nil,
        sourceFilePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.relativeAudioPath = relativeAudioPath
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isSoloSafe = isSoloSafe
        self.routing = routing
        self.assignedBusName = assignedBusName
        self.includeInWaveform = includeInWaveform
        self.duration = duration
        self.waveformPeaksData = waveformPeaksData
        self.relativeTransposedAudioPath = relativeTransposedAudioPath
        self.transposedSemitones = transposedSemitones
        self.sourceFilePath = sourceFilePath
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, role, relativeAudioPath, volume, pan, isMuted, isSoloed
        case isSoloSafe, routing, assignedBusName, includeInWaveform, duration
        case waveformPeaksData, relativeTransposedAudioPath, transposedSemitones
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.role = try container.decode(TrackRole.self, forKey: .role)
        self.relativeAudioPath = (try container.decodeIfPresent(String.self, forKey: .relativeAudioPath)) ?? ""
        self.volume = (try container.decodeIfPresent(Float.self, forKey: .volume)) ?? 0.80
        self.pan = (try container.decodeIfPresent(Float.self, forKey: .pan)) ?? 0.0
        self.isMuted = (try container.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? false
        self.isSoloed = (try container.decodeIfPresent(Bool.self, forKey: .isSoloed)) ?? false
        self.isSoloSafe = (try container.decodeIfPresent(Bool.self, forKey: .isSoloSafe)) ?? false
        self.routing = (try container.decodeIfPresent(OutputRoutingOption.self, forKey: .routing)) ?? .mainOut
        self.assignedBusName = (try container.decodeIfPresent(String.self, forKey: .assignedBusName)) ?? "Tracks"
        self.includeInWaveform = (try container.decodeIfPresent(Bool.self, forKey: .includeInWaveform)) ?? true
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.waveformPeaksData = try container.decodeIfPresent(Data.self, forKey: .waveformPeaksData)
        self.relativeTransposedAudioPath = try container.decodeIfPresent(String.self, forKey: .relativeTransposedAudioPath)
        self.transposedSemitones = try container.decodeIfPresent(Int.self, forKey: .transposedSemitones)
    }
    
    public static func encodePeaks(_ peaks: [Float]) -> Data? {
        guard !peaks.isEmpty else { return nil }
        return peaks.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return Data(bytes: base, count: ptr.count * MemoryLayout<Float>.size)
        }
    }
    
    public static func decodePeaks(_ data: Data?) -> [Float] {
        guard let data = data, data.count >= MemoryLayout<Float>.size else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0.0, count: count)
        _ = result.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        return result
    }
}

/// Metadata specification for a standalone song package (.pbsong or .multitrack)
public struct SongPackageMetadata: Codable, Sendable {
    public var version: Int = 2
    public var id: UUID
    public var title: String
    public var artist: String
    public var bpm: Double
    public var originalBPM: Double
    public var timeSignatureNumerator: Int
    public var timeSignatureDenominator: Int
    public var musicalKey: String
    public var transposeSemitones: Int = 0
    public var preserveVocalFormants: Bool = true
    public var sections: [SongSection]
    public var defaultSections: [SongSection] = []
    public var savedArrangements: [SavedArrangement] = []
    public var activeArrangementId: UUID? = nil
    public var tracks: [TrackFileMetadata]
    public var beatGrid: [BeatGridMarker] = []
    public var timeSignatureChanges: [TimeSignatureChange] = []
    public var midiCues: [MIDICue] = []
    public var directionalCues: [DirectionalCue] = []
    public var automationPoints: [AutomationPoint] = []
    public var smpteCue: SMPTECue? = nil
    public var defaultMidiCues: [MIDICue]? = nil
    public var defaultDirectionalCues: [DirectionalCue]? = nil
    public var defaultAutomationPoints: [AutomationPoint]? = nil
    public var defaultSmpteCue: SMPTECue? = nil
    public var proPresenterPlaylist: Int? = nil
    public var proPresenterPlaylistItem: Int? = nil
    public var transitionType: SongTransitionType = .cueNextSong
    public var continuePad: Bool = false
    public var endFadeOutEnabled: Bool = false
    public var startPadWithSong: Bool = false
    public var padPresetId: String? = nil
    public var padIntroOutroOnly: Bool = false
    public var artworkData: Data? = nil
    
    // Click & Guide settings
    public var clickSource: ClickSource? = nil
    public var guideSource: GuideSource? = nil
    public var guideVoice: GuideVoice? = nil
    public var guideFallbackVoice: GuideVoice? = nil
    public var clickSound: ClickSoundType? = nil
    public var usesDefaultClickSound: Bool? = nil
    public var usesDefaultGuideVoice: Bool? = nil
    public var clickAccentEnabled: Bool? = nil
    public var clickQuarterEnabled: Bool? = nil
    public var clickEighthEnabled: Bool? = nil
    public var clickSixteenthEnabled: Bool? = nil
    public var clickAccentVolume: Float? = nil
    public var clickQuarterVolume: Float? = nil
    public var clickEighthVolume: Float? = nil
    public var clickSixteenthVolume: Float? = nil
    public var guideCountInEnabled: Bool? = nil
    public var speakDirectionalCuesOnUploadedGuide: Bool? = nil
    public var autoInfiniteLoop: Bool? = nil
    public var excludesClickAndGuide: Bool? = nil
    
    public init(
        version: Int = 2,
        id: UUID = UUID(),
        title: String,
        artist: String,
        bpm: Double,
        originalBPM: Double? = nil,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        musicalKey: String = "D",
        transposeSemitones: Int = 0,
        preserveVocalFormants: Bool = true,
        sections: [SongSection] = [],
        defaultSections: [SongSection] = [],
        savedArrangements: [SavedArrangement] = [],
        activeArrangementId: UUID? = nil,
        tracks: [TrackFileMetadata] = [],
        beatGrid: [BeatGridMarker] = [],
        timeSignatureChanges: [TimeSignatureChange] = [],
        midiCues: [MIDICue] = [],
        directionalCues: [DirectionalCue] = [],
        automationPoints: [AutomationPoint] = [],
        smpteCue: SMPTECue? = nil,
        defaultMidiCues: [MIDICue]? = nil,
        defaultDirectionalCues: [DirectionalCue]? = nil,
        defaultAutomationPoints: [AutomationPoint]? = nil,
        defaultSmpteCue: SMPTECue? = nil,
        proPresenterPlaylist: Int? = nil,
        proPresenterPlaylistItem: Int? = nil,
        transitionType: SongTransitionType = .cueNextSong,
        continuePad: Bool = false,
        endFadeOutEnabled: Bool = false,
        startPadWithSong: Bool = false,
        padPresetId: String? = nil,
        padIntroOutroOnly: Bool = false,
        artworkData: Data? = nil,
        clickSource: ClickSource? = nil,
        guideSource: GuideSource? = nil,
        guideVoice: GuideVoice? = nil,
        guideFallbackVoice: GuideVoice? = nil,
        clickSound: ClickSoundType? = nil,
        usesDefaultClickSound: Bool? = nil,
        usesDefaultGuideVoice: Bool? = nil,
        clickAccentEnabled: Bool? = nil,
        clickQuarterEnabled: Bool? = nil,
        clickEighthEnabled: Bool? = nil,
        clickSixteenthEnabled: Bool? = nil,
        clickAccentVolume: Float? = nil,
        clickQuarterVolume: Float? = nil,
        clickEighthVolume: Float? = nil,
        clickSixteenthVolume: Float? = nil,
        guideCountInEnabled: Bool? = nil,
        speakDirectionalCuesOnUploadedGuide: Bool? = nil,
        autoInfiniteLoop: Bool? = nil,
        excludesClickAndGuide: Bool? = nil
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.originalBPM = originalBPM ?? bpm
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
        self.musicalKey = musicalKey
        self.transposeSemitones = transposeSemitones
        self.preserveVocalFormants = preserveVocalFormants
        self.sections = sections
        self.defaultSections = defaultSections.isEmpty ? sections : defaultSections
        self.savedArrangements = savedArrangements
        self.activeArrangementId = activeArrangementId
        self.tracks = tracks
        self.beatGrid = beatGrid
        self.timeSignatureChanges = timeSignatureChanges
        self.midiCues = midiCues
        self.directionalCues = directionalCues
        self.automationPoints = automationPoints
        self.smpteCue = smpteCue
        self.defaultMidiCues = defaultMidiCues
        self.defaultDirectionalCues = defaultDirectionalCues
        self.defaultAutomationPoints = defaultAutomationPoints
        self.defaultSmpteCue = defaultSmpteCue
        self.proPresenterPlaylist = proPresenterPlaylist
        self.proPresenterPlaylistItem = proPresenterPlaylistItem
        self.transitionType = transitionType
        self.continuePad = continuePad
        self.endFadeOutEnabled = endFadeOutEnabled
        self.startPadWithSong = startPadWithSong
        self.padPresetId = padPresetId
        self.padIntroOutroOnly = padIntroOutroOnly
        self.artworkData = artworkData
        self.clickSource = clickSource
        self.guideSource = guideSource
        self.guideVoice = guideVoice
        self.guideFallbackVoice = guideFallbackVoice
        self.clickSound = clickSound
        self.usesDefaultClickSound = usesDefaultClickSound
        self.usesDefaultGuideVoice = usesDefaultGuideVoice
        self.clickAccentEnabled = clickAccentEnabled
        self.clickQuarterEnabled = clickQuarterEnabled
        self.clickEighthEnabled = clickEighthEnabled
        self.clickSixteenthEnabled = clickSixteenthEnabled
        self.clickAccentVolume = clickAccentVolume
        self.clickQuarterVolume = clickQuarterVolume
        self.clickEighthVolume = clickEighthVolume
        self.clickSixteenthVolume = clickSixteenthVolume
        self.guideCountInEnabled = guideCountInEnabled
        self.speakDirectionalCuesOnUploadedGuide = speakDirectionalCuesOnUploadedGuide
        self.autoInfiniteLoop = autoInfiniteLoop
        self.excludesClickAndGuide = excludesClickAndGuide
    }
    
    enum CodingKeys: String, CodingKey {
        case version, id, title, artist, bpm, originalBPM, timeSignatureNumerator, timeSignatureDenominator
        case musicalKey, transposeSemitones, preserveVocalFormants, sections, defaultSections, savedArrangements, activeArrangementId, tracks
        case beatGrid, timeSignatureChanges, midiCues, directionalCues, automationPoints, smpteCue
        case defaultMidiCues, defaultDirectionalCues, defaultAutomationPoints, defaultSmpteCue
        case proPresenterPlaylist, proPresenterPlaylistItem, transitionType, continuePad, endFadeOutEnabled, startPadWithSong, padPresetId, padIntroOutroOnly, artworkData
        case clickSource, guideSource, guideVoice, guideFallbackVoice, clickSound, usesDefaultClickSound, usesDefaultGuideVoice
        case clickAccentEnabled, clickQuarterEnabled, clickEighthEnabled, clickSixteenthEnabled
        case clickAccentVolume, clickQuarterVolume, clickEighthVolume, clickSixteenthVolume
        case guideCountInEnabled, speakDirectionalCuesOnUploadedGuide, autoInfiniteLoop, excludesClickAndGuide
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.bpm = try container.decode(Double.self, forKey: .bpm)
        self.originalBPM = try container.decodeIfPresent(Double.self, forKey: .originalBPM) ?? self.bpm
        self.timeSignatureNumerator = try container.decode(Int.self, forKey: .timeSignatureNumerator)
        self.timeSignatureDenominator = try container.decode(Int.self, forKey: .timeSignatureDenominator)
        self.musicalKey = try container.decode(String.self, forKey: .musicalKey)
        self.transposeSemitones = try container.decodeIfPresent(Int.self, forKey: .transposeSemitones) ?? 0
        self.preserveVocalFormants = try container.decodeIfPresent(Bool.self, forKey: .preserveVocalFormants) ?? true
        let secs = try container.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        self.sections = secs
        let defSecs = try container.decodeIfPresent([SongSection].self, forKey: .defaultSections) ?? []
        self.defaultSections = defSecs.isEmpty ? secs : defSecs
        self.savedArrangements = try container.decodeIfPresent([SavedArrangement].self, forKey: .savedArrangements) ?? []
        self.activeArrangementId = try container.decodeIfPresent(UUID.self, forKey: .activeArrangementId)
        self.tracks = try container.decodeIfPresent([TrackFileMetadata].self, forKey: .tracks) ?? []
        self.beatGrid = try container.decodeIfPresent([BeatGridMarker].self, forKey: .beatGrid) ?? []
        self.timeSignatureChanges = try container.decodeIfPresent([TimeSignatureChange].self, forKey: .timeSignatureChanges) ?? []
        self.midiCues = try container.decodeIfPresent([MIDICue].self, forKey: .midiCues) ?? []
        self.directionalCues = try container.decodeIfPresent([DirectionalCue].self, forKey: .directionalCues) ?? []
        self.automationPoints = try container.decodeIfPresent([AutomationPoint].self, forKey: .automationPoints) ?? []
        self.smpteCue = try container.decodeIfPresent(SMPTECue.self, forKey: .smpteCue)
        self.defaultMidiCues = try container.decodeIfPresent([MIDICue].self, forKey: .defaultMidiCues)
        self.defaultDirectionalCues = try container.decodeIfPresent([DirectionalCue].self, forKey: .defaultDirectionalCues)
        self.defaultAutomationPoints = try container.decodeIfPresent([AutomationPoint].self, forKey: .defaultAutomationPoints)
        self.defaultSmpteCue = try container.decodeIfPresent(SMPTECue.self, forKey: .defaultSmpteCue)
        self.proPresenterPlaylist = try container.decodeIfPresent(Int.self, forKey: .proPresenterPlaylist)
        self.proPresenterPlaylistItem = try container.decodeIfPresent(Int.self, forKey: .proPresenterPlaylistItem)
        self.transitionType = try container.decodeIfPresent(SongTransitionType.self, forKey: .transitionType) ?? .cueNextSong
        self.continuePad = try container.decodeIfPresent(Bool.self, forKey: .continuePad) ?? false
        self.endFadeOutEnabled = try container.decodeIfPresent(Bool.self, forKey: .endFadeOutEnabled) ?? false
        self.startPadWithSong = try container.decodeIfPresent(Bool.self, forKey: .startPadWithSong) ?? false
        self.padPresetId = try container.decodeIfPresent(String.self, forKey: .padPresetId)
        self.padIntroOutroOnly = try container.decodeIfPresent(Bool.self, forKey: .padIntroOutroOnly) ?? false
        self.artworkData = try container.decodeIfPresent(Data.self, forKey: .artworkData)
        self.clickSource = try container.decodeIfPresent(ClickSource.self, forKey: .clickSource)
        self.guideSource = try container.decodeIfPresent(GuideSource.self, forKey: .guideSource)
        self.guideVoice = try container.decodeIfPresent(GuideVoice.self, forKey: .guideVoice)
        self.guideFallbackVoice = try container.decodeIfPresent(GuideVoice.self, forKey: .guideFallbackVoice)
        self.clickSound = try container.decodeIfPresent(ClickSoundType.self, forKey: .clickSound)
        self.usesDefaultClickSound = try container.decodeIfPresent(Bool.self, forKey: .usesDefaultClickSound)
        self.usesDefaultGuideVoice = try container.decodeIfPresent(Bool.self, forKey: .usesDefaultGuideVoice)
        self.clickAccentEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickAccentEnabled)
        self.clickQuarterEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickQuarterEnabled)
        self.clickEighthEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickEighthEnabled)
        self.clickSixteenthEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickSixteenthEnabled)
        self.clickAccentVolume = try container.decodeIfPresent(Float.self, forKey: .clickAccentVolume)
        self.clickQuarterVolume = try container.decodeIfPresent(Float.self, forKey: .clickQuarterVolume)
        self.clickEighthVolume = try container.decodeIfPresent(Float.self, forKey: .clickEighthVolume)
        self.clickSixteenthVolume = try container.decodeIfPresent(Float.self, forKey: .clickSixteenthVolume)
        self.guideCountInEnabled = try container.decodeIfPresent(Bool.self, forKey: .guideCountInEnabled)
        self.speakDirectionalCuesOnUploadedGuide = try container.decodeIfPresent(Bool.self, forKey: .speakDirectionalCuesOnUploadedGuide)
        self.autoInfiniteLoop = try container.decodeIfPresent(Bool.self, forKey: .autoInfiniteLoop)
        self.excludesClickAndGuide = try container.decodeIfPresent(Bool.self, forKey: .excludesClickAndGuide)
    }
}

/// Metadata specification for a complete session package (.pbsession) containing ordered songs
public struct SessionPackageMetadata: Codable, Sendable {
    public var version: Int = 2
    public var id: UUID
    public var name: String
    public var date: Date
    public var serviceType: String?
    public var serviceTime: String?
    public var scheduledDate: Date?
    public var currentSongIndex: Int
    public var associatedSessionPath: String?
    public var changeDescription: String?
    public var songEntries: [SongPackageMetadata]
    
    public init(
        version: Int = 2,
        id: UUID = UUID(),
        name: String = "Sunday Morning Set",
        date: Date = Date(),
        serviceType: String? = nil,
        serviceTime: String? = nil,
        scheduledDate: Date? = nil,
        currentSongIndex: Int = 0,
        associatedSessionPath: String? = nil,
        changeDescription: String? = nil,
        songEntries: [SongPackageMetadata] = []
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.date = date
        self.serviceType = serviceType
        self.serviceTime = serviceTime
        self.scheduledDate = scheduledDate
        self.currentSongIndex = currentSongIndex
        self.associatedSessionPath = associatedSessionPath
        self.changeDescription = changeDescription
        self.songEntries = songEntries
    }
}

/// Robust, high-speed file management for saving & loading self-contained .pbsong and .pbsession packages
public final class PlaybackFileManager: @unchecked Sendable {
    public static let shared = PlaybackFileManager()
    
    private let cacheQueue = DispatchQueue(label: "com.peanutbutter.stemcache", qos: .utility, attributes: .concurrent)
    private let cacheLock = NSLock()
    private var inFlightCacheIds: Set<UUID> = []
    
    public var stemCacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PeanutButter/StemCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private init() {
        cleanupStaleTempDirectoriesAsync()
    }
    
    /// Cleans up any leftover temporary import/export directories in the system temp folder
    private func cleanupStaleTempDirectoriesAsync() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix("pbsession_import_") ||
                   name.hasPrefix("pbsession_export_") ||
                   name.hasPrefix("pbsong_import_") ||
                   name.hasPrefix("pbsong_export_") {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }
    
    public func cachedStemURL(for trackId: UUID) -> URL {
        stemCacheDirectory.appendingPathComponent("\(trackId.uuidString).m4a")
    }
    
    public func hasValidCachedStem(for trackId: UUID) -> Bool {
        let url = cachedStemURL(for: trackId)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > 256 else {
            return false
        }
        return true
    }
    
    /// Zero-copy APFS hardlink for purely local files, or data-only copy (with no hardlink or xattr carryover)
    /// whenever either endpoint touches Cloud Storage (Google Drive, iCloud Drive, OneDrive, Dropbox).
    /// macOS `fileproviderd` bounces multi-linked inodes (`st_nlink > 1`) to `<name> 2.m4a` and Google Drive
    /// rejects files copied with stale `com.google.drivefs.item-id#S` extended attributes.
    public func linkOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL { return }

        let srcIsCloud = LibraryBrowserManager.isCloudStorageURL(sourceURL)
        let dstIsCloud = LibraryBrowserManager.isCloudStorageURL(destinationURL)

        if srcIsCloud && !LibraryBrowserManager.checkIsDownloaded(at: sourceURL) {
            LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL, timeout: 120.0)
        }

        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if srcIsCloud || dstIsCloud || Self.hasCloudExtendedAttributes(at: sourceURL) {
            let tmpURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".pb_tmp_\(UUID().uuidString)_\(destinationURL.lastPathComponent)")
            defer {
                if fm.fileExists(atPath: tmpURL.path) {
                    try? fm.removeItem(at: tmpURL)
                }
            }
            let rc = Darwin.copyfile(sourceURL.path, tmpURL.path, nil, copyfile_flags_t(COPYFILE_DATA))
            if rc != 0 {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: tmpURL, options: .atomic)
            }
            Self.stripCloudExtendedAttributes(at: tmpURL)
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: tmpURL, to: destinationURL)
            return
        }

        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        do {
            try fm.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            let rc = Darwin.copyfile(sourceURL.path, destinationURL.path, nil, copyfile_flags_t(COPYFILE_DATA))
            if rc != 0 {
                try fm.copyItem(at: sourceURL, to: destinationURL)
                Self.stripCloudExtendedAttributes(at: destinationURL)
            }
        }
    }

    private static func hasCloudExtendedAttributes(at url: URL) -> Bool {
        let path = url.path
        if getxattr(path, "com.google.drivefs.item-id#S", nil, 0, 0, 0) >= 0 { return true }
        if getxattr(path, "com.apple.fileprovider.before-bounce#P", nil, 0, 0, 0) >= 0 { return true }
        return false
    }

    private static func stripCloudExtendedAttributes(at url: URL) {
        let path = url.path
        _ = removexattr(path, "com.google.drivefs.item-id#S", 0)
        _ = removexattr(path, "com.apple.fileprovider.before-bounce#P", 0)
    }

    /// Checks that a stem file exists on disk, is non-empty (> 1 KB), and has not been bounced by FileProvider.
    private func hasValidStemFile(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let path = url.path
        if getxattr(path, "com.apple.fileprovider.before-bounce#P", nil, 0, 0, 0) >= 0 {
            return false
        }
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = vals.fileSize {
            return size > 1024
        }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int {
            return size > 1024
        }
        return false
    }

    private func isSameFile(_ urlA: URL, _ urlB: URL) -> Bool {
        let fm = FileManager.default
        guard let attrA = try? fm.attributesOfItem(atPath: urlA.path),
              let attrB = try? fm.attributesOfItem(atPath: urlB.path),
              let inoA = attrA[.systemFileNumber] as? NSNumber,
              let inoB = attrB[.systemFileNumber] as? NSNumber,
              let devA = attrA[.systemNumber] as? NSNumber,
              let devB = attrB[.systemNumber] as? NSNumber else {
            return false
        }
        return inoA == inoB && devA == devB
    }
    
    /// Pre-encodes a stem buffer into the persistent `.m4a` StemCache in the background so future saves/exports are instantaneous
    public func cacheStemInBackground(trackId: UUID, buffer: AVAudioPCMBuffer, sourceURL: URL? = nil) {
        if hasValidCachedStem(for: trackId) { return }
        
        cacheLock.lock()
        if inFlightCacheIds.contains(trackId) {
            cacheLock.unlock()
            return
        }
        inFlightCacheIds.insert(trackId)
        cacheLock.unlock()
        
        let targetCacheURL = cachedStemURL(for: trackId)
        if let src = sourceURL, src.pathExtension.lowercased() == "m4a", FileManager.default.fileExists(atPath: src.path) {
            try? linkOrCopyFile(from: src, to: targetCacheURL)
            cacheLock.lock()
            inFlightCacheIds.remove(trackId)
            cacheLock.unlock()
            return
        }
        
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.cacheLock.lock()
                self.inFlightCacheIds.remove(trackId)
                self.cacheLock.unlock()
            }
            guard !self.hasValidCachedStem(for: trackId) else { return }
            let tempFile = self.stemCacheDirectory.appendingPathComponent("tmp_\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: tempFile) }
            do {
                try self.writeCompressedStem(buffer, to: tempFile)
                if FileManager.default.fileExists(atPath: targetCacheURL.path) {
                    try? FileManager.default.removeItem(at: targetCacheURL)
                }
                try FileManager.default.moveItem(at: tempFile, to: targetCacheURL)
            } catch {
                // Ignore background cache errors
            }
        }
    }
    
    // MARK: - Persistent Transposed & Tempo-Stretched Audio Cache
    
    public static func cacheBPMHundredths(_ bpm: Double) -> Int {
        Int((bpm * 100.0).rounded())
    }
    
    public func transposedStemCacheDirectory(
        songId: UUID,
        semitones: Int,
        preserveVocalFormants: Bool = true,
        bpm: Double? = nil,
        originalBPM: Double? = nil
    ) -> URL {
        let formantTag = preserveVocalFormants ? "vf1" : "vf0"
        let tempoChanged: Bool = {
            guard let bpm = bpm, let orig = originalBPM else { return false }
            return abs(bpm - orig) > 0.005
        }()
        let enginePrefix = "rb3"
        let folderName: String
        if tempoChanged, let bpm = bpm {
            // Versioned directory isolates combined engine+key+formant+tempo caches cleanly
            folderName = "transposed_\(enginePrefix)3_\(songId.uuidString)_st\(semitones)_\(formantTag)_bpm\(Self.cacheBPMHundredths(bpm))"
        } else {
            folderName = "transposed_\(enginePrefix)2_\(songId.uuidString)_\(semitones)_\(formantTag)"
        }
        let dir = stemCacheDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    public func saveTransposedBuffersToDisk(
        songId: UUID,
        semitones: Int,
        preserveVocalFormants: Bool = true,
        bpm: Double? = nil,
        originalBPM: Double? = nil,
        buffers: [UUID: AVAudioPCMBuffer]
    ) {
        let tempoChanged = (bpm != nil && originalBPM != nil && abs(bpm! - originalBPM!) > 0.005)
        guard semitones != 0 || tempoChanged else { return }
        let dir = transposedStemCacheDirectory(
            songId: songId,
            semitones: semitones,
            preserveVocalFormants: preserveVocalFormants,
            bpm: bpm,
            originalBPM: originalBPM
        )
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            for (trackId, buf) in buffers {
                let targetURL = dir.appendingPathComponent("\(trackId.uuidString).wav")
                guard !FileManager.default.fileExists(atPath: targetURL.path) else { continue }
                let tmp = dir.appendingPathComponent("tmp_\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: tmp) }
                do {
                    try self.writeWAVBuffer(buf, to: tmp)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try? FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.moveItem(at: tmp, to: targetURL)
                } catch {}
            }
        }
    }

    public func writeWAVBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    public func clearTransposedBuffersFromDisk(songId: UUID) {
        let fm = FileManager.default
        let root = stemCacheDirectory
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let token = "_\(songId.uuidString)"
        for item in items where item.lastPathComponent.hasPrefix("transposed_") && item.lastPathComponent.contains(token) {
            try? fm.removeItem(at: item)
        }
    }
    
    public func loadTransposedBuffersFromDisk(
        songId: UUID,
        semitones: Int,
        preserveVocalFormants: Bool = true,
        bpm: Double? = nil,
        originalBPM: Double? = nil,
        trackIds: [UUID],
        canonicalFormat: AVAudioFormat
    ) -> [UUID: AVAudioPCMBuffer]? {
        let tempoChanged = (bpm != nil && originalBPM != nil && abs(bpm! - originalBPM!) > 0.005)
        guard (semitones != 0 || tempoChanged), !trackIds.isEmpty else { return nil }
        let dir = transposedStemCacheDirectory(
            songId: songId,
            semitones: semitones,
            preserveVocalFormants: preserveVocalFormants,
            bpm: bpm,
            originalBPM: originalBPM
        )
        let fm = FileManager.default
        let count = trackIds.count
        var resolvedURLs: [URL] = []
        resolvedURLs.reserveCapacity(count)
        for trackId in trackIds {
            let wavURL = dir.appendingPathComponent("\(trackId.uuidString).wav")
            let m4aURL = dir.appendingPathComponent("\(trackId.uuidString).m4a")
            if fm.fileExists(atPath: wavURL.path) {
                resolvedURLs.append(wavURL)
            } else if fm.fileExists(atPath: m4aURL.path) {
                resolvedURLs.append(m4aURL)
            } else {
                return nil
            }
        }
        let box = UnsafeMutableBufferPointer<AVAudioPCMBuffer?>.allocate(capacity: count)
        box.initialize(repeating: nil)
        defer {
            box.deinitialize()
            box.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: count) { idx in
            let fileURL = resolvedURLs[idx]
            guard let raw = try? self.readPCMBuffer(from: fileURL) else { return }
            box[idx] = Self.normalizeBuffer(raw, to: canonicalFormat)
        }
        var result: [UUID: AVAudioPCMBuffer] = [:]
        result.reserveCapacity(count)
        for idx in 0..<count {
            guard let buf = box[idx] else { return nil }
            result[trackIds[idx]] = buf
        }
        return result.isEmpty ? nil : result
    }
    
    /// Ensures a compressed `.m4a` file for `track` is written to `destinationStemURL` and cached in `StemCache`
    private func writeOrLinkStem(
        track: StemTrack,
        buffer: AVAudioPCMBuffer?,
        to destinationStemURL: URL
    ) throws {
        let fm = FileManager.default
        let cacheURL = cachedStemURL(for: track.id)
        let candidateFileURLs = [track.fileURL, track.sourceFileURL].compactMap { $0 }
        
        // 1. Fast path: already in StemCache
        if hasValidCachedStem(for: track.id) {
            try linkOrCopyFile(from: cacheURL, to: destinationStemURL)
            return
        }
        
        // 2. Fast path: track's fileURL or sourceFileURL is already an .m4a file on disk
        for origURL in candidateFileURLs where origURL.pathExtension.lowercased() == "m4a" {
            if LibraryBrowserManager.isCloudStorageURL(origURL) && !LibraryBrowserManager.checkIsDownloaded(at: origURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: origURL, timeout: 120.0)
            }
            if fm.fileExists(atPath: origURL.path) {
                try? linkOrCopyFile(from: origURL, to: cacheURL)
                try linkOrCopyFile(from: origURL, to: destinationStemURL)
                return
            }
        }
        
        // 3. Encode from RAM buffer into StemCache, then copy/link to destination
        if let buf = buffer, buf.frameLength > 100 {
            let tmpCacheURL = stemCacheDirectory.appendingPathComponent("enc_\(UUID().uuidString).m4a")
            defer { try? fm.removeItem(at: tmpCacheURL) }
            try writeCompressedStem(buf, to: tmpCacheURL)
            if !hasValidCachedStem(for: track.id) {
                try? linkOrCopyFile(from: tmpCacheURL, to: cacheURL)
            }
            try linkOrCopyFile(from: tmpCacheURL, to: destinationStemURL)
            return
        }
        
        // 4. Fallback: read from original non-M4A fileURL or sourceFileURL, encode to M4A
        for origURL in candidateFileURLs {
            if LibraryBrowserManager.isCloudStorageURL(origURL) && !LibraryBrowserManager.checkIsDownloaded(at: origURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: origURL, timeout: 120.0)
            }
            guard fm.fileExists(atPath: origURL.path) else { continue }
            if let fileBuf = try? readPCMBuffer(from: origURL), fileBuf.frameLength > 10 {
                let tmpCacheURL = stemCacheDirectory.appendingPathComponent("enc_\(UUID().uuidString).m4a")
                defer { try? fm.removeItem(at: tmpCacheURL) }
                try writeCompressedStem(fileBuf, to: tmpCacheURL)
                if !hasValidCachedStem(for: track.id) {
                    try? linkOrCopyFile(from: tmpCacheURL, to: cacheURL)
                }
                try linkOrCopyFile(from: tmpCacheURL, to: destinationStemURL)
                return
            } else {
                try linkOrCopyFile(from: origURL, to: destinationStemURL)
                return
            }
        }

        if !fm.fileExists(atPath: destinationStemURL.path) {
            throw NSError(
                domain: "PlaybackFileManager",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Missing audio source for track \(track.name) (\(track.id))"]
            )
        }
    }
    
    // MARK: - BYOC Cloud Stem & Incremental Package Helpers

    public struct CloudStemPackManifest: Codable, Sendable {
        public let songId: UUID
        public var byId: [String: String]
        public var byName: [String: String]
    }

    private let cloudPackLock = NSLock()

    private func cloudStemRelativePath(songId: UUID, trackId: UUID) -> String {
        "cloudstems/\(songId.uuidString)/\(trackId.uuidString).m4a"
    }

    private func resolveCloudStemDestination(cloudStemsDir: URL, songId: UUID, trackId: UUID) -> URL {
        cloudStemsDir
            .appendingPathComponent(songId.uuidString, isDirectory: true)
            .appendingPathComponent("\(trackId.uuidString).m4a")
    }

    public func resolveCloudStemPackURL(cloudStemsDir: URL, songId: UUID) -> URL {
        cloudStemsDir.appendingPathComponent("\(songId.uuidString).pbstems")
    }

    public func resolveCloudStemPackManifestURL(cloudStemsDir: URL, songId: UUID) -> URL {
        cloudStemsDir.appendingPathComponent("\(songId.uuidString).tracks.json")
    }

    /// Packs all `.m4a` stems + a `tracks.json` manifest (`byId` & `byName`) for `songId` into a single
    /// uncompressed archive (`<CloudRoot>/Stems/<songId>.pbstems`) so Google Drive / iCloud / Dropbox
    /// syncs one atomic file per song instead of 20–40 loose files.
    public func writeCloudStemPack(cloudStemsDir: URL, songId: UUID, tracks: [TrackFileMetadata]) {
        let fm = FileManager.default
        let audioTracks = tracks.filter { !$0.relativeAudioPath.isEmpty }
        guard !audioTracks.isEmpty else { return }

        cloudPackLock.lock()
        defer { cloudPackLock.unlock() }

        try? fm.createDirectory(at: cloudStemsDir, withIntermediateDirectories: true)
        let packURL = resolveCloudStemPackURL(cloudStemsDir: cloudStemsDir, songId: songId)
        let sidecarURL = resolveCloudStemPackManifestURL(cloudStemsDir: cloudStemsDir, songId: songId)
        let looseDir = cloudStemsDir.appendingPathComponent(songId.uuidString, isDirectory: true)

        // Fast-path check: if `<songId>.pbstems` and `<songId>.tracks.json` already exist and contain all tracks, skip repack
        if fm.fileExists(atPath: packURL.path),
           let packSize = (try? packURL.resourceValues(forKeys: [.fileSizeKey]).fileSize), packSize > 1024,
           let sidecarData = try? Data(contentsOf: sidecarURL),
           let existingManifest = try? JSONDecoder().decode(CloudStemPackManifest.self, from: sidecarData) {
            let allPresent = audioTracks.allSatisfy { tm in
                existingManifest.byId[tm.id.uuidString] != nil &&
                existingManifest.byName[tm.name.lowercased()] != nil
            }
            if allPresent && !fm.fileExists(atPath: looseDir.path) {
                return
            }
        }

        let stagingDir = fm.temporaryDirectory.appendingPathComponent("pbstems_stage_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        // Seed stagingDir with any existing stems inside `<songId>.pbstems` or legacy `Stems/<songId>/`
        var byId: [String: String] = [:]
        var byName: [String: String] = [:]

        if fm.fileExists(atPath: packURL.path) {
            if !LibraryBrowserManager.checkIsDownloaded(at: packURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: packURL, timeout: 120.0)
            }
            try? unzipArchive(archiveURL: packURL, toFolderURL: stagingDir)
            let oldManifestURL = stagingDir.appendingPathComponent("tracks.json")
            if let data = try? Data(contentsOf: oldManifestURL),
               let oldManifest = try? JSONDecoder().decode(CloudStemPackManifest.self, from: data) {
                byId = oldManifest.byId
                byName = oldManifest.byName
            }
        }

        if fm.fileExists(atPath: looseDir.path),
           let looseFiles = try? fm.contentsOfDirectory(at: looseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for lf in looseFiles where lf.pathExtension.lowercased() == "m4a" {
                let dst = stagingDir.appendingPathComponent(lf.lastPathComponent)
                if !hasValidStemFile(at: dst) && hasValidStemFile(at: lf) {
                    try? linkOrCopyFile(from: lf, to: dst)
                }
            }
        }

        // Overlay current tracks from StemCache or looseDir
        for tm in audioTracks {
            let fileName = "\(tm.id.uuidString).m4a"
            let stagedFile = stagingDir.appendingPathComponent(fileName)
            if !hasValidStemFile(at: stagedFile) {
                let cached = cachedStemURL(for: tm.id)
                let loose = looseDir.appendingPathComponent(fileName)
                if hasValidCachedStem(for: tm.id) {
                    try? linkOrCopyFile(from: cached, to: stagedFile)
                } else if hasValidStemFile(at: loose) {
                    try? linkOrCopyFile(from: loose, to: stagedFile)
                    if !hasValidCachedStem(for: tm.id) {
                        try? linkOrCopyFile(from: loose, to: cached)
                    }
                } else if let existByName = byName[tm.name.lowercased()] {
                    let altStaged = stagingDir.appendingPathComponent(existByName)
                    if hasValidStemFile(at: altStaged) {
                        try? linkOrCopyFile(from: altStaged, to: stagedFile)
                    }
                }
            }
            if hasValidStemFile(at: stagedFile) {
                byId[tm.id.uuidString] = fileName
                byName[tm.name.lowercased()] = fileName
            }
        }

        guard !byId.isEmpty else { return }

        let manifest = CloudStemPackManifest(songId: songId, byId: byId, byName: byName)
        if let manifestData = try? JSONEncoder().encode(manifest) {
            try? manifestData.write(to: stagingDir.appendingPathComponent("tracks.json"), options: .atomic)
            try? manifestData.write(to: sidecarURL, options: .atomic)
        }

        let tempZip = fm.temporaryDirectory.appendingPathComponent("pbstems_out_\(UUID().uuidString).pbstems")
        defer { try? fm.removeItem(at: tempZip) }

        let process = Process()
        process.currentDirectoryURL = stagingDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-0", "-r", "-q", tempZip.path, "."]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        if fm.fileExists(atPath: tempZip.path) {
            try? linkOrCopyFile(from: tempZip, to: packURL)
            if fm.fileExists(atPath: looseDir.path) {
                try? fm.removeItem(at: looseDir)
            }
        }
    }

    /// Ensures that if `songEntry` references cloud stems not yet in `StemCache`, its atomic `<songId>.pbstems`
    /// pack is downloaded and extracted directly into `StemCache` (including track-name fallback mapping).
    @discardableResult
    public func unpackCloudStemPackIfNeeded(
        for songEntry: SongPackageMetadata,
        rootFolder: URL,
        isCancelled: (() -> Bool)? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) -> Bool {
        let fm = FileManager.default
        let missingTracks = songEntry.tracks.filter { !$0.relativeAudioPath.isEmpty && !hasValidCachedStem(for: $0.id) }
        guard !missingTracks.isEmpty else { return true }

        // Collect candidate cloud Stems root directories and song IDs
        let inferredStemsRoot = rootFolder
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Stems", isDirectory: true)
        var stemsRoots: [URL] = []
        if let configured = LibraryBrowserManager.cloudStemsDirectoryURL {
            stemsRoots.append(configured)
        }
        if !stemsRoots.contains(where: { $0.standardizedFileURL == inferredStemsRoot.standardizedFileURL }) {
            stemsRoots.append(inferredStemsRoot)
        }

        var candidateSongIds: [UUID] = [songEntry.id]
        for tm in songEntry.tracks where tm.relativeAudioPath.hasPrefix("cloudstems/") {
            let comps = tm.relativeAudioPath.split(separator: "/")
            if comps.count >= 3, let parsedId = UUID(uuidString: String(comps[1])), !candidateSongIds.contains(parsedId) {
                candidateSongIds.append(parsedId)
            }
        }

        for stemsRoot in stemsRoots {
            for sId in candidateSongIds {
                if isCancelled?() == true { return false }
                let packURL = resolveCloudStemPackURL(cloudStemsDir: stemsRoot, songId: sId)
                let packPlaceholder = stemsRoot.appendingPathComponent(".\(packURL.lastPathComponent).icloud")
                if fm.fileExists(atPath: packURL.path) || fm.fileExists(atPath: packPlaceholder.path) {
                    if !LibraryBrowserManager.checkIsDownloaded(at: packURL) {
                        LibraryBrowserManager.ensureCloudItemDownloaded(at: packURL, timeout: 180.0, isCancelled: isCancelled) { dlFrac in
                            progressHandler?(dlFrac * 0.85)
                        }
                    } else {
                        progressHandler?(0.85)
                    }
                    if isCancelled?() == true { return false }
                    if fm.fileExists(atPath: packURL.path) {
                        let unpackDir = fm.temporaryDirectory.appendingPathComponent("pbstems_unpack_\(UUID().uuidString)", isDirectory: true)
                        try? fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)
                        defer { try? fm.removeItem(at: unpackDir) }

                        if (try? unzipArchive(archiveURL: packURL, toFolderURL: unpackDir)) != nil {
                            progressHandler?(0.92)
                            var manifest: CloudStemPackManifest? = nil
                            let manifestURL = unpackDir.appendingPathComponent("tracks.json")
                            if let data = try? Data(contentsOf: manifestURL) {
                                manifest = try? JSONDecoder().decode(CloudStemPackManifest.self, from: data)
                            } else if let sidecarData = try? Data(contentsOf: resolveCloudStemPackManifestURL(cloudStemsDir: stemsRoot, songId: sId)) {
                                manifest = try? JSONDecoder().decode(CloudStemPackManifest.self, from: sidecarData)
                            }

                            // 1. Copy every <uuid>.m4a directly into StemCache
                            if let unpackedFiles = try? fm.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                                for file in unpackedFiles where file.pathExtension.lowercased() == "m4a" {
                                    let baseName = file.deletingPathExtension().lastPathComponent
                                    if let trackUUID = UUID(uuidString: baseName), !hasValidCachedStem(for: trackUUID) {
                                        try? linkOrCopyFile(from: file, to: cachedStemURL(for: trackUUID))
                                    }
                                }
                            }

                            // 2. Track-Name Fallback: if a track's UUID changed across imports, resolve by lowercased track name
                            if let manifest = manifest {
                                for tm in songEntry.tracks where !tm.relativeAudioPath.isEmpty && !hasValidCachedStem(for: tm.id) {
                                    if let matchedFileName = manifest.byId[tm.id.uuidString] ?? manifest.byName[tm.name.lowercased()] {
                                        let srcFile = unpackDir.appendingPathComponent(matchedFileName)
                                        if hasValidStemFile(at: srcFile) {
                                            try? linkOrCopyFile(from: srcFile, to: cachedStemURL(for: tm.id))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return songEntry.tracks.allSatisfy { $0.relativeAudioPath.isEmpty || hasValidCachedStem(for: $0.id) }
    }

    private func resolvePackageStemURL(relativePath: String, rootFolder: URL, triggerDownload: Bool = false) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let fm = FileManager.default
        if relativePath.hasPrefix("cloudstems/") {
            let subPath = String(relativePath.dropFirst("cloudstems/".count))
            var candidates: [URL] = []
            if let configured = LibraryBrowserManager.cloudStemsDirectoryURL {
                candidates.append(configured.appendingPathComponent(subPath))
            }
            // Also resolve relative to `<CloudRoot>/{Songs|Setlists}/Package` -> `<CloudRoot>/Stems`
            let inferredStemsRoot = rootFolder
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Stems", isDirectory: true)
            let inferredStems = inferredStemsRoot.appendingPathComponent(subPath)
            if !candidates.contains(where: { $0.standardizedFileURL == inferredStems.standardizedFileURL }) {
                candidates.append(inferredStems)
            }

            // Fast non-blocking path for Stage 1 metadata loading on @MainActor
            if !triggerDownload {
                return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates.first
            }

            for candidate in candidates {
                let placeholder = candidate.deletingLastPathComponent()
                    .appendingPathComponent(".\(candidate.lastPathComponent).icloud")
                if fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: placeholder.path) {
                    if !LibraryBrowserManager.checkIsDownloaded(at: candidate) {
                        LibraryBrowserManager.ensureCloudItemDownloaded(at: candidate, timeout: 90.0)
                    }
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }

                // Heal FileProvider-bounced sibling (`<trackId> 2.m4a`) if Google Drive renamed a hardlinked file
                let parentDir = candidate.deletingLastPathComponent()
                let baseUUID = candidate.deletingPathExtension().lastPathComponent
                if let siblings = try? fm.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) {
                    if let bounced = siblings.first(where: {
                        $0.pathExtension.lowercased() == "m4a" && $0.deletingPathExtension().lastPathComponent.hasPrefix(baseUUID + " ")
                    }) {
                        if !LibraryBrowserManager.checkIsDownloaded(at: bounced) {
                            LibraryBrowserManager.ensureCloudItemDownloaded(at: bounced, timeout: 90.0)
                        }
                        try? linkOrCopyFile(from: bounced, to: candidate)
                        if fm.fileExists(atPath: candidate.path) {
                            try? fm.removeItem(at: bounced)
                            return candidate
                        }
                        return bounced
                    }
                }
            }

            // Cross-song-folder fallback: search `<CloudRoot>/Stems/*/<trackId>.m4a` if songId changed
            let targetFileName = URL(fileURLWithPath: subPath).lastPathComponent
            let stemsRoots = [LibraryBrowserManager.cloudStemsDirectoryURL, inferredStemsRoot].compactMap { $0 }
            for stemsRoot in stemsRoots {
                guard let songDirs = try? fm.contentsOfDirectory(at: stemsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for sDir in songDirs {
                    let altCandidate = sDir.appendingPathComponent(targetFileName)
                    if fm.fileExists(atPath: altCandidate.path) {
                        if !LibraryBrowserManager.checkIsDownloaded(at: altCandidate) {
                            LibraryBrowserManager.ensureCloudItemDownloaded(at: altCandidate, timeout: 90.0)
                        }
                        return altCandidate
                    }
                }
            }

            return candidates.first
        }

        let localURL = rootFolder.appendingPathComponent(relativePath)
        if triggerDownload && !LibraryBrowserManager.checkIsDownloaded(at: localURL) {
            LibraryBrowserManager.ensureCloudItemDownloaded(at: localURL, timeout: 90.0)
        }
        return localURL
    }

    private func writeArtworkIfNeeded(_ artworkData: Data?, to artURL: URL) {
        let fm = FileManager.default
        if let newData = artworkData {
            if fm.fileExists(atPath: artURL.path),
               let existing = try? Data(contentsOf: artURL),
               existing == newData {
                return
            }
            try? newData.write(to: artURL, options: .atomic)
        } else if fm.fileExists(atPath: artURL.path) {
            try? fm.removeItem(at: artURL)
        }
    }

    /// Copies a `.pbsong` or `.pbsession` package between Local and Cloud libraries without decoding PCM stems into CoreAudio.
    /// When targeting Cloud, heavy `.m4a` stems are deduplicated into `<CloudRoot>/Stems/<songId>/<trackId>.m4a`;
    /// when targeting Local, stems are materialized back inside the package so local exports stay 100% self-contained.
    public func copyLibraryPackage(from sourceURL: URL, to destinationURL: URL, isSong: Bool) throws {
        let fm = FileManager.default
        LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL)

        var srcIsDir: ObjCBool = false
        let isDirSource = fm.fileExists(atPath: sourceURL.path, isDirectory: &srcIsDir) && srcIsDir.boolValue
        let tempExtract = fm.temporaryDirectory.appendingPathComponent("pb_copy_src_\(UUID().uuidString)")
        let rootFolder: URL
        if isDirSource {
            rootFolder = sourceURL
        } else {
            try fm.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            try unzipArchive(archiveURL: sourceURL, toFolderURL: tempExtract)
            rootFolder = tempExtract
        }
        defer {
            if !isDirSource {
                try? fm.removeItem(at: tempExtract)
            }
        }

        let isCloudDest = LibraryBrowserManager.isURLInCloudLibrary(destinationURL)
        let cloudStemsDir = isCloudDest ? LibraryBrowserManager.cloudStemsDirectoryURL : nil

        let stagingDir = fm.temporaryDirectory.appendingPathComponent("pb_copy_dst_\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        if isSong {
            let srcJSON = rootFolder.appendingPathComponent("song.json")
            var meta = try decoder.decode(SongPackageMetadata.self, from: try Data(contentsOf: srcJSON))
            _ = unpackCloudStemPackIfNeeded(for: meta, rootFolder: rootFolder)
            let srcArt = rootFolder.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: srcArt.path) {
                try? fm.copyItem(at: srcArt, to: stagingDir.appendingPathComponent("artwork.png"))
            }
            let stemsDir = stagingDir.appendingPathComponent("stems", isDirectory: true)
            if cloudStemsDir == nil {
                try fm.createDirectory(at: stemsDir, withIntermediateDirectories: true)
            }

            var updatedTracks: [TrackFileMetadata] = []
            for var tm in meta.tracks {
                let resolvedAudioURL: URL? = {
                    if hasValidCachedStem(for: tm.id) {
                        return cachedStemURL(for: tm.id)
                    }
                    if !tm.relativeAudioPath.isEmpty,
                       let pkgAudio = resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: true),
                       fm.fileExists(atPath: pkgAudio.path) {
                        return pkgAudio
                    }
                    if let srcPath = tm.sourceFilePath {
                        let srcURL = URL(fileURLWithPath: srcPath)
                        if fm.fileExists(atPath: srcURL.path) {
                            return srcURL
                        }
                    }
                    return nil
                }()
                if let srcAudio = resolvedAudioURL, fm.fileExists(atPath: srcAudio.path) {
                    if !hasValidCachedStem(for: tm.id) && srcAudio.pathExtension.lowercased() == "m4a" {
                        try? linkOrCopyFile(from: srcAudio, to: cachedStemURL(for: tm.id))
                    }
                    if let csDir = cloudStemsDir {
                        let dstStem = resolveCloudStemDestination(cloudStemsDir: csDir, songId: meta.id, trackId: tm.id)
                        try fm.createDirectory(at: dstStem.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !hasValidStemFile(at: dstStem) {
                            try linkOrCopyFile(from: srcAudio, to: dstStem)
                        }
                        tm = TrackFileMetadata(
                            id: tm.id, name: tm.name, role: tm.role,
                            relativeAudioPath: cloudStemRelativePath(songId: meta.id, trackId: tm.id),
                            volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                            routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                            duration: tm.duration, waveformPeaksData: tm.waveformPeaksData,
                            relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                            sourceFilePath: tm.sourceFilePath
                        )
                    } else {
                        let filename = srcAudio.lastPathComponent
                        let dstStem = stemsDir.appendingPathComponent(filename)
                        try linkOrCopyFile(from: srcAudio, to: dstStem)
                        tm = TrackFileMetadata(
                            id: tm.id, name: tm.name, role: tm.role,
                            relativeAudioPath: "stems/\(filename)",
                            volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                            routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                            duration: tm.duration, waveformPeaksData: tm.waveformPeaksData,
                            relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                            sourceFilePath: tm.sourceFilePath
                        )
                    }
                }
                updatedTracks.append(tm)
            }

            meta.tracks = updatedTracks
            try encoder.encode(meta).write(to: stagingDir.appendingPathComponent("song.json"), options: .atomic)
            if let csDir = cloudStemsDir {
                writeCloudStemPack(cloudStemsDir: csDir, songId: meta.id, tracks: updatedTracks)
            }
        } else {
            let srcJSON = rootFolder.appendingPathComponent("session.json")
            var meta = try decoder.decode(SessionPackageMetadata.self, from: try Data(contentsOf: srcJSON))
            let songsDir = stagingDir.appendingPathComponent("songs", isDirectory: true)
            try fm.createDirectory(at: songsDir, withIntermediateDirectories: true)

            var updatedEntries: [SongPackageMetadata] = []
            for (songIndex, songEntry) in meta.songEntries.enumerated() {
                _ = unpackCloudStemPackIfNeeded(for: songEntry, rootFolder: rootFolder)
                let songSubDir = songsDir.appendingPathComponent("song_\(songIndex)", isDirectory: true)
                try fm.createDirectory(at: songSubDir, withIntermediateDirectories: true)
                let srcArt = rootFolder.appendingPathComponent("songs/song_\(songIndex)/artwork.png")
                if fm.fileExists(atPath: srcArt.path) {
                    try? fm.copyItem(at: srcArt, to: songSubDir.appendingPathComponent("artwork.png"))
                }
                let stemsSubDir = songSubDir.appendingPathComponent("stems", isDirectory: true)
                if cloudStemsDir == nil {
                    try fm.createDirectory(at: stemsSubDir, withIntermediateDirectories: true)
                }

                var updatedTracks: [TrackFileMetadata] = []
                for tm in songEntry.tracks {
                    let resolvedAudioURL: URL? = {
                        if hasValidCachedStem(for: tm.id) {
                            return cachedStemURL(for: tm.id)
                        }
                        if !tm.relativeAudioPath.isEmpty,
                           let pkgAudio = resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: true),
                           fm.fileExists(atPath: pkgAudio.path) {
                            return pkgAudio
                        }
                        if let srcPath = tm.sourceFilePath {
                            let srcURL = URL(fileURLWithPath: srcPath)
                            if fm.fileExists(atPath: srcURL.path) {
                                return srcURL
                            }
                        }
                        return nil
                    }()
                    if let srcAudio = resolvedAudioURL, fm.fileExists(atPath: srcAudio.path) {
                        if !hasValidCachedStem(for: tm.id) && srcAudio.pathExtension.lowercased() == "m4a" {
                            try? linkOrCopyFile(from: srcAudio, to: cachedStemURL(for: tm.id))
                        }
                        if let csDir = cloudStemsDir {
                            let dstStem = resolveCloudStemDestination(cloudStemsDir: csDir, songId: songEntry.id, trackId: tm.id)
                            try fm.createDirectory(at: dstStem.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if !hasValidStemFile(at: dstStem) {
                                try linkOrCopyFile(from: srcAudio, to: dstStem)
                            }
                            updatedTracks.append(TrackFileMetadata(
                                id: tm.id, name: tm.name, role: tm.role,
                                relativeAudioPath: cloudStemRelativePath(songId: songEntry.id, trackId: tm.id),
                                volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                                routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                                duration: tm.duration, waveformPeaksData: tm.waveformPeaksData,
                                relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                                sourceFilePath: tm.sourceFilePath
                            ))
                        } else {
                            let filename = srcAudio.lastPathComponent
                            let dstStem = stemsSubDir.appendingPathComponent(filename)
                            try linkOrCopyFile(from: srcAudio, to: dstStem)
                            updatedTracks.append(TrackFileMetadata(
                                id: tm.id, name: tm.name, role: tm.role,
                                relativeAudioPath: "songs/song_\(songIndex)/stems/\(filename)",
                                volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                                routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                                duration: tm.duration, waveformPeaksData: tm.waveformPeaksData,
                                relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                                sourceFilePath: tm.sourceFilePath
                            ))
                        }
                    } else {
                        updatedTracks.append(tm)
                    }
                }

                var updatedEntry = songEntry
                updatedEntry.tracks = updatedTracks
                updatedEntries.append(updatedEntry)
                if let csDir = cloudStemsDir {
                    writeCloudStemPack(cloudStemsDir: csDir, songId: songEntry.id, tracks: updatedTracks)
                }
            }

            meta.associatedSessionPath = nil
            meta.songEntries = updatedEntries
            try encoder.encode(meta).write(to: stagingDir.appendingPathComponent("session.json"), options: .atomic)
        }

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: stagingDir, to: destinationURL)
    }

    // MARK: - Song Package Export (.pbsong / .multitrack)
    
    /// Exports a song with all stems, sections, tempo, and metadata into a portable, compact .pbsong package
    public func exportSongPackage(
        song: Song,
        tracks: [StemTrack],
        buffers: [UUID: AVAudioPCMBuffer],
        transposedBuffers: [UUID: AVAudioPCMBuffer]? = nil,
        to destinationURL: URL,
        asDirectoryPackage: Bool = true
    ) throws {
        let fileManager = FileManager.default
        let isCloudDest = LibraryBrowserManager.isURLInCloudLibrary(destinationURL)
        let cloudStemsDir = isCloudDest ? LibraryBrowserManager.cloudStemsDirectoryURL : nil

        var existingIsDir: ObjCBool = false
        let canUpdateInPlace = asDirectoryPackage &&
            fileManager.fileExists(atPath: destinationURL.path, isDirectory: &existingIsDir) &&
            existingIsDir.boolValue

        let parentDir = asDirectoryPackage ? destinationURL.deletingLastPathComponent() : fileManager.temporaryDirectory
        let tempDir = parentDir.appendingPathComponent("pbsong_export_\(UUID().uuidString)")
        let targetRoot: URL
        if canUpdateInPlace {
            targetRoot = destinationURL
        } else {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            targetRoot = tempDir
        }
        
        defer {
            if !canUpdateInPlace && fileManager.fileExists(atPath: tempDir.path) {
                try? fileManager.removeItem(at: tempDir)
            }
        }
        
        let stemsDir = targetRoot.appendingPathComponent("stems")
        if cloudStemsDir == nil {
            try fileManager.createDirectory(at: stemsDir, withIntermediateDirectories: true)
        }
        
        let stemFileNames = buildUniqueStemFileNames(for: tracks, ext: "m4a")
        let metaBox = UnsafeMutableBufferPointer<TrackFileMetadata?>.allocate(capacity: tracks.count)
        metaBox.initialize(repeating: nil)
        defer {
            metaBox.deinitialize()
            metaBox.deallocate()
        }
        
        let isTransposed = song.transposeSemitones != 0 && transposedBuffers != nil
        
        let stemSongId = song.sourceSongId ?? song.id

        // Safe-Save Guard: Read existing song.json (if updating an existing package) so an unhydrated
        // track in RAM never overwrites a previously valid `relativeAudioPath` with `""`.
        var existingRelPathById: [UUID: String] = [:]
        var existingRelPathByName: [String: String] = [:]
        let existingSongJSONURL = destinationURL.appendingPathComponent("song.json")
        if let oldData = try? Data(contentsOf: existingSongJSONURL),
           let oldMeta = try? JSONDecoder().decode(SongPackageMetadata.self, from: oldData) {
            for ot in oldMeta.tracks where !ot.relativeAudioPath.isEmpty {
                existingRelPathById[ot.id] = ot.relativeAudioPath
                existingRelPathByName[ot.name.lowercased()] = ot.relativeAudioPath
            }
        }
        
        // Encode/link all stems concurrently across all CPU cores (skipping existing files on in-place/cloud updates)
        DispatchQueue.concurrentPerform(iterations: tracks.count) { idx in
            let track = tracks[idx]
            let cat = StemCategory.category(for: track.name, role: track.role)
            let isGeneratedClick = (track.role == .click || cat == .click) && song.clickSource == .generated
            let isGeneratedGuide = (track.role == .guide || cat == .guide) && song.guideSource == .generated
            let hasBackingAudio = self.hasValidCachedStem(for: track.id)
                || (track.fileURL != nil && fileManager.fileExists(atPath: track.fileURL!.path))
                || (track.sourceFileURL != nil && fileManager.fileExists(atPath: track.sourceFileURL!.path))
            let shouldSkipAudioExport = (isGeneratedClick || isGeneratedGuide) && !hasBackingAudio
            let stemFileName = stemFileNames[idx]
            
            var relativePath = ""
            if !shouldSkipAudioExport {
                if let csDir = cloudStemsDir {
                    let csURL = self.resolveCloudStemDestination(cloudStemsDir: csDir, songId: stemSongId, trackId: track.id)
                    do {
                        try fileManager.createDirectory(at: csURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !self.hasValidStemFile(at: csURL) {
                            try self.writeOrLinkStem(track: track, buffer: buffers[track.id], to: csURL)
                        }
                        relativePath = self.cloudStemRelativePath(songId: stemSongId, trackId: track.id)
                    } catch {
                        if let preserved = existingRelPathById[track.id] ?? existingRelPathByName[track.name.lowercased()] {
                            relativePath = preserved
                        } else {
                            relativePath = self.cloudStemRelativePath(songId: stemSongId, trackId: track.id)
                        }
                        print("Failed to write cloud stem \(track.name) (preserved \(relativePath)): \(error)")
                    }
                } else {
                    let stemURL = stemsDir.appendingPathComponent(stemFileName)
                    do {
                        if !canUpdateInPlace || !self.hasValidStemFile(at: stemURL) {
                            try self.writeOrLinkStem(track: track, buffer: buffers[track.id], to: stemURL)
                        }
                        relativePath = "stems/\(stemFileName)"
                    } catch {
                        if let preserved = existingRelPathById[track.id] ?? existingRelPathByName[track.name.lowercased()] {
                            relativePath = preserved
                        }
                        print("Failed to write stem \(track.name): \(error)")
                    }
                }
            }
            
            let isClickOrGuide = track.role == .click || track.role == .guide ||
                track.assignedBusName.lowercased() == "click" || track.assignedBusName.lowercased() == "guide" ||
                track.name.lowercased().contains("click") || track.name.lowercased().contains("guide")
            
            let relTransPath: String? = nil
            
            var peaks = track.waveformPeaks
            if peaks.isEmpty && track.includeInWaveform, let buf = buffers[track.id] {
                peaks = Self.extractPeaks(from: buf, samplesCount: 4000)
            }
            
            metaBox[idx] = TrackFileMetadata(
                id: track.id,
                name: track.name,
                role: track.role,
                relativeAudioPath: relativePath,
                volume: track.volume,
                pan: track.pan,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                isSoloSafe: track.isSoloSafe,
                routing: track.routing,
                assignedBusName: track.assignedBusName,
                includeInWaveform: track.includeInWaveform,
                duration: track.duration > 0 ? track.duration : nil,
                waveformPeaksData: TrackFileMetadata.encodePeaks(peaks),
                relativeTransposedAudioPath: relTransPath,
                transposedSemitones: (relTransPath != nil) ? song.transposeSemitones : nil,
                sourceFilePath: (track.sourceFileURL ?? track.fileURL)?.path
            )
        }
        
        let trackEntries = (0..<tracks.count).compactMap { metaBox[$0] }
        
        if let csDir = cloudStemsDir {
            writeCloudStemPack(cloudStemsDir: csDir, songId: stemSongId, tracks: trackEntries)
        }
        
        if canUpdateInPlace {
            if cloudStemsDir != nil {
                if fileManager.fileExists(atPath: stemsDir.path) {
                    try? fileManager.removeItem(at: stemsDir)
                }
            } else if let existingStems = try? fileManager.contentsOfDirectory(at: stemsDir, includingPropertiesForKeys: nil) {
                let validRelPaths = Set(trackEntries.map { $0.relativeAudioPath })
                for file in existingStems {
                    if !validRelPaths.contains("stems/\(file.lastPathComponent)") {
                        try? fileManager.removeItem(at: file)
                    }
                }
            }
        }
        
        writeArtworkIfNeeded(song.artworkData, to: targetRoot.appendingPathComponent("artwork.png"))
        
        let songMeta = makeSongPackageMetadata(song: song, tracks: trackEntries, embedArtworkInJSON: false)
        
        let encoder = JSONEncoder()
        let metaData = try encoder.encode(songMeta)
        try metaData.write(to: targetRoot.appendingPathComponent("song.json"), options: .atomic)
        
        if !canUpdateInPlace {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            if asDirectoryPackage {
                try fileManager.moveItem(at: tempDir, to: destinationURL)
            } else {
                try zipFolder(folderURL: tempDir, toArchiveURL: destinationURL)
            }
        }
    }
    
    /// Loads a .pbsong or .multitrack package, restoring all stem buffers, sections, tempo, and key in parallel
    public func loadSongPackage(
        from sourceURL: URL,
        canonicalFormat: AVAudioFormat? = nil
    ) throws -> (song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)], transposedBuffers: [UUID: AVAudioPCMBuffer]) {
        LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("pbsong_import_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
            return try parseSongDirectory(folderURL: sourceURL, canonicalFormat: canonicalFormat)
        } else {
            try unzipArchive(archiveURL: sourceURL, toFolderURL: tempDir)
            return try parseSongDirectory(folderURL: tempDir, canonicalFormat: canonicalFormat)
        }
    }
    
    private func parseSongDirectory(
        folderURL: URL,
        canonicalFormat: AVAudioFormat?
    ) throws -> (song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)], transposedBuffers: [UUID: AVAudioPCMBuffer]) {
        let metaURL = folderURL.appendingPathComponent("song.json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw NSError(domain: "PlaybackFileManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Corrupted song package: missing song.json"])
        }
        
        let data = try Data(contentsOf: metaURL)
        let songMeta = try JSONDecoder().decode(SongPackageMetadata.self, from: data)
        
        var loadedArtwork = songMeta.artworkData
        if loadedArtwork == nil {
            let artURL = folderURL.appendingPathComponent("artwork.png")
            if FileManager.default.fileExists(atPath: artURL.path) {
                loadedArtwork = try? Data(contentsOf: artURL)
            }
        }
        
        return decodeSongEntry(
            songEntry: songMeta,
            rootFolder: folderURL,
            artworkOverride: loadedArtwork,
            canonicalFormat: canonicalFormat
        )
    }

    public struct FastHydratedSong: @unchecked Sendable {
        public let song: Song
        public let stubTracks: [(StemTrack, AVAudioPCMBuffer)]
        public let metadata: SongPackageMetadata
        public let sourceURL: URL
        public let rootFolder: URL
        public let cleanupFolder: URL?
        public let needsArchiveExtraction: Bool
    }

    /// Reads only `song.json` and `artwork.png` from a `.pbsong` package without downloading or decoding audio stems.
    public func loadSongMetadataOnly(from sourceURL: URL) throws -> Song {
        return try loadSongMetadataFast(from: sourceURL, canonicalFormat: nil).song
    }

    /// Stage 1 fast song loader: reads `song.json` and `artwork.png` and builds lightweight stub tracks
    /// so the song card can appear immediately while audio stems download/decode in the background.
    public func loadSongMetadataFast(from sourceURL: URL, canonicalFormat: AVAudioFormat?) throws -> FastHydratedSong {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var exists = fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        if !exists {
            LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL)
            exists = fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        }
        guard exists else {
            throw NSError(domain: "PlaybackFileManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Song package not found"])
        }

        let jsonData: Data
        var loadedArtwork: Data? = nil
        let rootFolder: URL
        var cleanupFolder: URL? = nil
        let needsArchiveExtraction: Bool

        if isDir.boolValue {
            let metaURL = sourceURL.appendingPathComponent("song.json")
            if !LibraryBrowserManager.checkIsDownloaded(at: metaURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: metaURL)
            }
            jsonData = try Data(contentsOf: metaURL)
            let artURL = sourceURL.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: artURL.path) {
                if LibraryBrowserManager.checkIsDownloaded(at: artURL) {
                    loadedArtwork = try? Data(contentsOf: artURL)
                } else {
                    LibraryBrowserManager.triggerCloudDownload(at: artURL)
                }
            } else if fm.fileExists(atPath: sourceURL.appendingPathComponent(".artwork.png.icloud").path) {
                LibraryBrowserManager.triggerCloudDownload(at: artURL)
            }
            rootFolder = sourceURL
            needsArchiveExtraction = false
        } else {
            if !LibraryBrowserManager.checkIsDownloaded(at: sourceURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL)
            }
            let tempDir = fm.temporaryDirectory.appendingPathComponent("pbsong_meta_\(UUID().uuidString)")
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qq", "-o", sourceURL.path, "song.json", "artwork.png", "-d", tempDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            let metaURL = tempDir.appendingPathComponent("song.json")
            guard fm.fileExists(atPath: metaURL.path) else {
                try? fm.removeItem(at: tempDir)
                throw NSError(domain: "PlaybackFileManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Corrupted song package: missing song.json"])
            }
            jsonData = try Data(contentsOf: metaURL)
            let artURL = tempDir.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: artURL.path) {
                loadedArtwork = try? Data(contentsOf: artURL)
            }
            rootFolder = tempDir
            cleanupFolder = tempDir
            needsArchiveExtraction = true
        }

        let songMeta = try JSONDecoder().decode(SongPackageMetadata.self, from: jsonData)
        let hasUploadedClickFile = songMeta.tracks.contains { tm in
            let cat = StemCategory.category(for: tm.name, role: tm.role)
            return cat == .click && !tm.relativeAudioPath.isEmpty
        }
        let hasUploadedGuideFile = songMeta.tracks.contains { tm in
            let cat = StemCategory.category(for: tm.name, role: tm.role)
            return cat == .guide && !tm.relativeAudioPath.isEmpty
        }
        let resolvedClickSource: ClickSource = hasUploadedClickFile ? (songMeta.clickSource ?? .uploaded) : .generated
        let resolvedGuideSource: GuideSource = hasUploadedGuideFile ? (songMeta.guideSource ?? .uploaded) : .generated

        let stubFmt = canonicalFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
        var stubTracks: [(StemTrack, AVAudioPCMBuffer)] = []
        stubTracks.reserveCapacity(songMeta.tracks.count)
        var resolvedStemURLs: [URL] = []
        for tm in songMeta.tracks {
            guard let tinyBuf = AVAudioPCMBuffer(pcmFormat: stubFmt, frameCapacity: 1) else { continue }
            tinyBuf.frameLength = 1
            let resolvedURL: URL? = {
                if tm.relativeAudioPath.isEmpty { return nil }
                if self.hasValidCachedStem(for: tm.id) { return self.cachedStemURL(for: tm.id) }
                return self.resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: false)
            }()
            if let u = resolvedURL {
                resolvedStemURLs.append(u)
            }
            let stemTrack = StemTrack(
                id: tm.id,
                name: tm.name,
                role: tm.role,
                fileURL: resolvedURL,
                sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) } ?? resolvedURL,
                volume: tm.volume,
                pan: tm.pan,
                isMuted: tm.isMuted,
                isSoloed: tm.isSoloed,
                isSoloSafe: tm.isSoloSafe,
                routing: tm.routing,
                assignedBusName: tm.assignedBusName,
                includeInWaveform: tm.includeInWaveform
            )
            stemTrack.duration = tm.duration ?? 0.0
            stemTrack.waveformPeaks = TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
            stubTracks.append((stemTrack, tinyBuf))
        }

        let builtSong = buildSong(
            from: songMeta,
            artworkOverride: loadedArtwork ?? songMeta.artworkData,
            stemURLs: resolvedStemURLs,
            resolvedClickSource: resolvedClickSource,
            resolvedGuideSource: resolvedGuideSource
        )
        return FastHydratedSong(
            song: builtSong,
            stubTracks: stubTracks,
            metadata: songMeta,
            sourceURL: sourceURL,
            rootFolder: rootFolder,
            cleanupFolder: cleanupFolder,
            needsArchiveExtraction: needsArchiveExtraction
        )
    }
    
    // MARK: - Session Package Export & Import (.pbsession)
    
    /// Saves an ordered collection of songs, complete with all their audio stems and sections, into a .pbsession file or directory
    public func exportSession(
        setlist: Setlist,
        currentSongIndex: Int,
        allSongsData: [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])],
        transposedBuffersMap: [UUID: (semitones: Int, buffers: [UUID: AVAudioPCMBuffer])] = [:],
        to destinationURL: URL,
        asDirectoryPackage: Bool = true,
        associatedSessionPath: String? = nil,
        changeDescription: String? = nil
    ) throws {
        let fileManager = FileManager.default
        let isCloudDest = LibraryBrowserManager.isURLInCloudLibrary(destinationURL)
        let cloudStemsDir = isCloudDest ? LibraryBrowserManager.cloudStemsDirectoryURL : nil

        var existingIsDir: ObjCBool = false
        let canUpdateInPlace = asDirectoryPackage &&
            fileManager.fileExists(atPath: destinationURL.path, isDirectory: &existingIsDir) &&
            existingIsDir.boolValue

        let parentDir = asDirectoryPackage ? destinationURL.deletingLastPathComponent() : fileManager.temporaryDirectory
        let stagingDir = parentDir.appendingPathComponent("pbsession_export_\(UUID().uuidString)")
        let targetRoot: URL
        if canUpdateInPlace {
            targetRoot = destinationURL
        } else {
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            targetRoot = stagingDir
        }
        
        defer {
            if !canUpdateInPlace && fileManager.fileExists(atPath: stagingDir.path) {
                try? fileManager.removeItem(at: stagingDir)
            }
        }
        
        let songsDir = targetRoot.appendingPathComponent("songs")
        try fileManager.createDirectory(at: songsDir, withIntermediateDirectories: true)

        // Safe-Save Guard: Read existing session.json (if updating an existing session) so unhydrated
        // tracks in RAM never overwrite a previously valid `relativeAudioPath` with `""`.
        var existingRelPathByTrackId: [UUID: String] = [:]
        var existingRelPathBySongAndName: [String: String] = [:]
        let existingSessionJSONURL = destinationURL.appendingPathComponent("session.json")
        if let oldData = try? Data(contentsOf: existingSessionJSONURL),
           let oldSession = try? JSONDecoder().decode(SessionPackageMetadata.self, from: oldData) {
            for oldSong in oldSession.songEntries {
                for ot in oldSong.tracks where !ot.relativeAudioPath.isEmpty {
                    existingRelPathByTrackId[ot.id] = ot.relativeAudioPath
                    existingRelPathBySongAndName["\(oldSong.id.uuidString)::\(ot.name.lowercased())"] = ot.relativeAudioPath
                }
            }
        }
        
        // Pre-create song subdirectories and build flat work list for maximum multi-core parallelism
        struct StemExportJob {
            let songIndex: Int
            let trackIndex: Int
            let song: Song
            let track: StemTrack
            let buffer: AVAudioPCMBuffer?
            let transposedBuffer: AVAudioPCMBuffer?
            let stemFileName: String
            let stemURL: URL
            let relativePath: String
            let sharedRelativeAudioPath: String?
            let relativeTransposedPath: String?
            let transposedURL: URL?
        }
        
        var jobs: [StemExportJob] = []
        var songTrackCounts: [Int] = []
        var seenBufferRelativePaths: [ObjectIdentifier: String] = [:]
        var packedCloudTrackIdsBySong: [UUID: Set<String>] = [:]
        if let csDir = cloudStemsDir {
            for songData in allSongsData {
                let stemSongId = songData.song.sourceSongId ?? songData.song.id
                if packedCloudTrackIdsBySong[stemSongId] != nil { continue }
                let packURL = resolveCloudStemPackURL(cloudStemsDir: csDir, songId: stemSongId)
                let sidecarURL = resolveCloudStemPackManifestURL(cloudStemsDir: csDir, songId: stemSongId)
                if fileManager.fileExists(atPath: packURL.path),
                   let packSize = (try? packURL.resourceValues(forKeys: [.fileSizeKey]).fileSize), packSize > 1024,
                   let sidecarData = try? Data(contentsOf: sidecarURL),
                   let existingManifest = try? JSONDecoder().decode(CloudStemPackManifest.self, from: sidecarData) {
                    packedCloudTrackIdsBySong[stemSongId] = Set(existingManifest.byId.keys)
                } else {
                    packedCloudTrackIdsBySong[stemSongId] = []
                }
            }
        }
        
        for (songIndex, songData) in allSongsData.enumerated() {
            let songSubDir = songsDir.appendingPathComponent("song_\(songIndex)")
            let stemsSubDir = songSubDir.appendingPathComponent("stems")
            try fileManager.createDirectory(at: songSubDir, withIntermediateDirectories: true)
            if cloudStemsDir == nil {
                try fileManager.createDirectory(at: stemsSubDir, withIntermediateDirectories: true)
            }
            
            writeArtworkIfNeeded(songData.song.artworkData, to: songSubDir.appendingPathComponent("artwork.png"))
            
            let fileNames = buildUniqueStemFileNames(for: songData.tracks, ext: "m4a")
            songTrackCounts.append(songData.tracks.count)
            
            let stemSongId = songData.song.sourceSongId ?? songData.song.id
            for (tIdx, track) in songData.tracks.enumerated() {
                let stemFileName = fileNames[tIdx]
                let stemURL: URL
                let relativePath: String
                if let csDir = cloudStemsDir {
                    stemURL = self.resolveCloudStemDestination(cloudStemsDir: csDir, songId: stemSongId, trackId: track.id)
                    relativePath = self.cloudStemRelativePath(songId: stemSongId, trackId: track.id)
                } else {
                    stemURL = stemsSubDir.appendingPathComponent(stemFileName)
                    relativePath = "songs/song_\(songIndex)/stems/\(stemFileName)"
                }

                let cat = StemCategory.category(for: track.name, role: track.role)
                let isGeneratedClick = (track.role == .click || cat == .click) && songData.song.clickSource == .generated
                let isGeneratedGuide = (track.role == .guide || cat == .guide) && songData.song.guideSource == .generated
                let hasBackingAudio = self.hasValidCachedStem(for: track.id)
                    || (track.fileURL != nil && fileManager.fileExists(atPath: track.fileURL!.path))
                    || (track.sourceFileURL != nil && fileManager.fileExists(atPath: track.sourceFileURL!.path))
                let shouldSkipAudioExport = (isGeneratedClick || isGeneratedGuide) && !hasBackingAudio
                let buf = songData.buffers[track.id]
                var sharedRelPath: String? = nil
                // Only deduplicate identical in-RAM buffers for local embedded packages when buffer is hydrated (> 100 frames)
                if !shouldSkipAudioExport, cloudStemsDir == nil, let b = buf, b.frameLength > 100 {
                    let bufKey = ObjectIdentifier(b)
                    if let existingPath = seenBufferRelativePaths[bufKey] {
                        sharedRelPath = existingPath
                    } else {
                        seenBufferRelativePaths[bufKey] = relativePath
                    }
                }
                
                let transBuf: AVAudioPCMBuffer? = nil
                let transURL: URL? = nil
                let relTransPath: String? = nil
                
                jobs.append(
                    StemExportJob(
                        songIndex: songIndex,
                        trackIndex: tIdx,
                        song: songData.song,
                        track: track,
                        buffer: buf,
                        transposedBuffer: transBuf,
                        stemFileName: stemFileName,
                        stemURL: stemURL,
                        relativePath: relativePath,
                        sharedRelativeAudioPath: sharedRelPath,
                        relativeTransposedPath: relTransPath,
                        transposedURL: transURL
                    )
                )
            }
        }
        
        let resultsBox = UnsafeMutableBufferPointer<TrackFileMetadata?>.allocate(capacity: max(1, jobs.count))
        resultsBox.initialize(repeating: nil)
        defer {
            resultsBox.deinitialize()
            resultsBox.deallocate()
        }
        
        if !jobs.isEmpty {
            DispatchQueue.concurrentPerform(iterations: jobs.count) { jobIdx in
                let job = jobs[jobIdx]
                let track = job.track
                let song = job.song
                let cat = StemCategory.category(for: track.name, role: track.role)
                let isGeneratedClick = (track.role == .click || cat == .click) && song.clickSource == .generated
                let isGeneratedGuide = (track.role == .guide || cat == .guide) && song.guideSource == .generated
                let hasBackingAudio = self.hasValidCachedStem(for: track.id)
                    || (track.fileURL != nil && fileManager.fileExists(atPath: track.fileURL!.path))
                    || (track.sourceFileURL != nil && fileManager.fileExists(atPath: track.sourceFileURL!.path))
                let shouldSkipAudioExport = (isGeneratedClick || isGeneratedGuide) && !hasBackingAudio
                
                var relPath = ""
                if !shouldSkipAudioExport {
                    if let sharedRelPath = job.sharedRelativeAudioPath {
                        relPath = sharedRelPath
                    } else {
                        do {
                            try fileManager.createDirectory(at: job.stemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            let stemSongId = song.sourceSongId ?? song.id
                            let alreadyInCloudPack = (cloudStemsDir != nil) && (packedCloudTrackIdsBySong[stemSongId]?.contains(track.id.uuidString) == true)
                            let skipExisting: Bool = {
                                if alreadyInCloudPack { return true }
                                guard self.hasValidStemFile(at: job.stemURL) else { return false }
                                if cloudStemsDir != nil { return true }
                                if canUpdateInPlace && self.hasValidCachedStem(for: track.id) {
                                    return self.isSameFile(self.cachedStemURL(for: track.id), job.stemURL)
                                }
                                return false
                            }()
                            if !skipExisting {
                                try self.writeOrLinkStem(track: track, buffer: job.buffer, to: job.stemURL)
                            }
                            relPath = job.relativePath
                        } catch {
                            let stemSongId = song.sourceSongId ?? song.id
                            if let preserved = existingRelPathByTrackId[track.id] ?? existingRelPathBySongAndName["\(song.id.uuidString)::\(track.name.lowercased())"] ?? existingRelPathBySongAndName["\(stemSongId.uuidString)::\(track.name.lowercased())"] {
                                relPath = preserved
                            } else if cloudStemsDir != nil {
                                relPath = job.relativePath
                            }
                            print("Failed to export session stem \(track.name) (preserved \(relPath)): \(error)")
                        }
                    }
                }
                
                if let transBuf = job.transposedBuffer, let transURL = job.transposedURL {
                    try? self.writeCompressedStem(transBuf, to: transURL)
                }
                
                var peaks = track.waveformPeaks
                var resolvedDuration: TimeInterval? = track.duration > 0 ? track.duration : nil
                if peaks.isEmpty && track.includeInWaveform {
                    if let buf = job.buffer {
                        peaks = Self.extractPeaks(from: buf, samplesCount: 4000)
                        if resolvedDuration == nil && buf.frameLength > 0 {
                            resolvedDuration = Double(buf.frameLength) / buf.format.sampleRate
                        }
                    } else if !relPath.isEmpty {
                        let audioSource = fileManager.fileExists(atPath: job.stemURL.path) ? job.stemURL : track.fileURL
                        if let srcURL = audioSource,
                           (!LibraryBrowserManager.isCloudStorageURL(srcURL) || LibraryBrowserManager.checkIsDownloaded(at: srcURL)),
                           let fileBuf = try? self.readPCMBuffer(from: srcURL), fileBuf.frameLength > 10 {
                            peaks = Self.extractPeaks(from: fileBuf, samplesCount: 4000)
                            if resolvedDuration == nil {
                                resolvedDuration = Double(fileBuf.frameLength) / fileBuf.format.sampleRate
                            }
                        }
                    }
                }
                
                resultsBox[jobIdx] = TrackFileMetadata(
                    id: track.id,
                    name: track.name,
                    role: track.role,
                    relativeAudioPath: relPath,
                    volume: track.volume,
                    pan: track.pan,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    isSoloSafe: track.isSoloSafe,
                    routing: track.routing,
                    assignedBusName: track.assignedBusName,
                    includeInWaveform: track.includeInWaveform,
                    duration: resolvedDuration,
                    waveformPeaksData: TrackFileMetadata.encodePeaks(peaks),
                    relativeTransposedAudioPath: job.relativeTransposedPath,
                    transposedSemitones: (job.song.transposeSemitones != 0) ? job.song.transposeSemitones : nil,
                    sourceFilePath: (track.sourceFileURL ?? track.fileURL)?.path
                )
            }
        }
        
        var songPackageEntries: [SongPackageMetadata] = []
        var cursor = 0
        for (songIndex, songData) in allSongsData.enumerated() {
            let count = songTrackCounts[songIndex]
            var trackEntries: [TrackFileMetadata] = []
            trackEntries.reserveCapacity(count)
            for i in 0..<count {
                if let m = resultsBox[cursor + i] {
                    trackEntries.append(m)
                }
            }
            cursor += count
            let songMeta = makeSongPackageMetadata(song: songData.song, tracks: trackEntries, embedArtworkInJSON: false)
            songPackageEntries.append(songMeta)
            if let csDir = cloudStemsDir {
                let stemSongId = songData.song.sourceSongId ?? songData.song.id
                writeCloudStemPack(cloudStemsDir: csDir, songId: stemSongId, tracks: trackEntries)
            }
        }
        
        let sessionMeta = SessionPackageMetadata(
            id: setlist.id,
            name: setlist.name,
            date: setlist.date,
            serviceType: setlist.serviceType,
            serviceTime: setlist.serviceTime,
            scheduledDate: setlist.scheduledDate,
            currentSongIndex: currentSongIndex,
            associatedSessionPath: associatedSessionPath,
            changeDescription: changeDescription,
            songEntries: songPackageEntries
        )
        
        let encoder = JSONEncoder()
        let sessionData = try encoder.encode(sessionMeta)
        try sessionData.write(to: targetRoot.appendingPathComponent("session.json"), options: .atomic)
        
        if canUpdateInPlace {
            if let existingSubDirs = try? fileManager.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                let validSongFolderNames = Set((0..<allSongsData.count).map { "song_\($0)" })
                for subDir in existingSubDirs where !validSongFolderNames.contains(subDir.lastPathComponent) {
                    try? fileManager.removeItem(at: subDir)
                }
            }
            for (songIndex, songMeta) in songPackageEntries.enumerated() {
                let stemsSubDir = songsDir.appendingPathComponent("song_\(songIndex)/stems")
                if cloudStemsDir != nil {
                    if fileManager.fileExists(atPath: stemsSubDir.path) {
                        try? fileManager.removeItem(at: stemsSubDir)
                    }
                } else if let existingStems = try? fileManager.contentsOfDirectory(at: stemsSubDir, includingPropertiesForKeys: nil) {
                    let validRelPaths = Set(songMeta.tracks.map { $0.relativeAudioPath })
                    for file in existingStems {
                        let rel = "songs/song_\(songIndex)/stems/\(file.lastPathComponent)"
                        if !validRelPaths.contains(rel) {
                            try? fileManager.removeItem(at: file)
                        }
                    }
                }
            }
        } else {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            if asDirectoryPackage {
                try fileManager.moveItem(at: stagingDir, to: destinationURL)
            } else {
                try zipFolder(folderURL: stagingDir, toArchiveURL: destinationURL)
            }
        }
    }
    
    /// Peek at `associatedSessionPath` inside an uncompressed session directory (e.g. AutoSaveSession.pbsession) without loading audio
    public func peekAssociatedSessionPath(at sessionURL: URL) -> String? {
        let jsonURL = sessionURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let meta = try? JSONDecoder().decode(SessionPackageMetadata.self, from: data) else {
            return nil
        }
        return meta.associatedSessionPath
    }
    
    /// Loads a complete session (.pbsession) from Finder or directory, reconstructing the full ordered setlist and stems in parallel
    public func loadSession(
        from sourceURL: URL,
        canonicalFormat: AVAudioFormat? = nil
    ) throws -> (setlist: Setlist, currentSongIndex: Int, songsData: [(song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)])], transposedBuffersMap: [UUID: (semitones: Int, buffers: [UUID: AVAudioPCMBuffer])]) {
        LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("pbsession_import_\(UUID().uuidString)")
        
        var isDir: ObjCBool = false
        let isDirectorySource = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir) && isDir.boolValue
        let rootFolder: URL
        
        if isDirectorySource {
            rootFolder = sourceURL
        } else {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try unzipArchive(archiveURL: sourceURL, toFolderURL: tempDir)
            rootFolder = tempDir
        }
        
        defer {
            if !isDirectorySource {
                try? fileManager.removeItem(at: tempDir)
            }
        }
        
        let sessionJSONURL = rootFolder.appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: sessionJSONURL.path) else {
            throw NSError(domain: "PlaybackFileManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid session file: missing session.json"])
        }
        
        let data = try Data(contentsOf: sessionJSONURL)
        let sessionMeta = try JSONDecoder().decode(SessionPackageMetadata.self, from: data)
        
        var restoredSongs: [Song] = []
        var restoredSongsData: [(song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)])] = []
        var restoredTransposed: [UUID: (semitones: Int, buffers: [UUID: AVAudioPCMBuffer])] = [:]
        
        for (songIndex, songEntry) in sessionMeta.songEntries.enumerated() {
            var loadedArtwork = songEntry.artworkData
            if loadedArtwork == nil {
                let artURL = rootFolder.appendingPathComponent("songs/song_\(songIndex)/artwork.png")
                if fileManager.fileExists(atPath: artURL.path) {
                    loadedArtwork = try? Data(contentsOf: artURL)
                }
            }
            
            let (song, loadedTracks, loadedTransposed) = decodeSongEntry(
                songEntry: songEntry,
                rootFolder: rootFolder,
                artworkOverride: loadedArtwork,
                canonicalFormat: canonicalFormat
            )
            
            restoredSongs.append(song)
            restoredSongsData.append((song: song, tracks: loadedTracks))
            if song.transposeSemitones != 0 && !loadedTransposed.isEmpty {
                restoredTransposed[song.id] = (song.transposeSemitones, loadedTransposed)
            }
        }
        
        let setlist = Setlist(
            id: sessionMeta.id,
            name: sessionMeta.name,
            date: sessionMeta.date,
            serviceType: sessionMeta.serviceType,
            serviceTime: sessionMeta.serviceTime,
            scheduledDate: sessionMeta.scheduledDate,
            songs: restoredSongs
        )
        
        return (setlist, sessionMeta.currentSongIndex, restoredSongsData, restoredTransposed)
    }
    
    // MARK: - Two-Stage Instant Session Metadata + Lazy Audio Hydration
    
    public struct HydratedSessionMetadata: @unchecked Sendable {
        public let setlist: Setlist
        public let currentSongIndex: Int
        public let songEntries: [SongPackageMetadata]
        public let songsPlaceholderData: [(song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)])]
        public let sourceURL: URL
        public let isDirectorySource: Bool
        public let needsArchiveExtractionForStems: Bool
        public let metadataRootFolder: URL
        public let cleanupFolder: URL?
    }
    
    /// Stage 1: Reads `session.json` and artwork in a few milliseconds without decoding audio stems,
    /// constructing all `Song` and `StemTrack` models (including cached `waveformPeaks` and `duration`)
    /// so the entire UI renders immediately on launch with zero pop-in.
    public func loadSessionMetadataFast(
        from sourceURL: URL,
        canonicalFormat: AVAudioFormat? = nil
    ) throws -> HydratedSessionMetadata {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        var exists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        if !exists {
            LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL, timeout: 15.0)
            exists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        }
        let isDirectorySource = exists && isDir.boolValue
        
        let rootFolder: URL
        let cleanupFolder: URL?
        
        if isDirectorySource {
            rootFolder = sourceURL
            cleanupFolder = nil
            let jsonURL = sourceURL.appendingPathComponent("session.json")
            if !LibraryBrowserManager.checkIsDownloaded(at: jsonURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: jsonURL, timeout: 15.0)
            }
        } else {
            if !LibraryBrowserManager.checkIsDownloaded(at: sourceURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL, timeout: 30.0)
            }
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("pbsession_meta_\(UUID().uuidString)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try unzipMetadataOnly(archiveURL: sourceURL, toFolderURL: tempDir)
            rootFolder = tempDir
            cleanupFolder = tempDir
        }
        
        let sessionJSONURL = rootFolder.appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: sessionJSONURL.path) else {
            if let cleanup = cleanupFolder {
                try? fileManager.removeItem(at: cleanup)
            }
            throw NSError(domain: "PlaybackFileManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid session file: missing session.json"])
        }
        
        let data = try Data(contentsOf: sessionJSONURL)
        let sessionMeta = try JSONDecoder().decode(SessionPackageMetadata.self, from: data)
        
        let fallbackFormat = canonicalFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let sharedPlaceholderBuffer = AVAudioPCMBuffer(pcmFormat: fallbackFormat, frameCapacity: 1)!
        sharedPlaceholderBuffer.frameLength = 1
        
        var restoredSongs: [Song] = []
        var songsPlaceholderData: [(song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)])] = []
        var anyMissingFromStemCache = false
        
        for (songIndex, songEntry) in sessionMeta.songEntries.enumerated() {
            var loadedArtwork = songEntry.artworkData
            if loadedArtwork == nil {
                let artURL = rootFolder.appendingPathComponent("songs/song_\(songIndex)/artwork.png")
                if fileManager.fileExists(atPath: artURL.path) {
                    if LibraryBrowserManager.checkIsDownloaded(at: artURL) {
                        loadedArtwork = try? Data(contentsOf: artURL)
                    } else {
                        LibraryBrowserManager.triggerCloudDownload(at: artURL)
                    }
                }
            }
            
            let fallbackSongDur = songEntry.sections.map { $0.endTime }.max() ?? 240.0
            var placeholderTracks: [(StemTrack, AVAudioPCMBuffer)] = []
            placeholderTracks.reserveCapacity(songEntry.tracks.count)
            var stemURLs: [URL] = []
            var hasUploadedClickFile = false
            var hasUploadedGuideFile = false
            
            for tm in songEntry.tracks {
                let cat = StemCategory.category(for: tm.name, role: tm.role)
                let cachedURL = self.cachedStemURL(for: tm.id)
                let inCache = self.hasValidCachedStem(for: tm.id)
                
                let resolvedURL: URL?
                if tm.relativeAudioPath.isEmpty {
                    resolvedURL = nil
                } else if inCache {
                    resolvedURL = cachedURL
                } else {
                    if !isDirectorySource && !tm.relativeAudioPath.hasPrefix("cloudstems/") {
                        anyMissingFromStemCache = true
                    }
                    resolvedURL = self.resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: false)
                }
                
                if cat == .click && resolvedURL != nil {
                    hasUploadedClickFile = true
                } else if cat == .guide && resolvedURL != nil {
                    hasUploadedGuideFile = true
                }
                if let u = resolvedURL {
                    stemURLs.append(u)
                }
                
                let stemTrack = StemTrack(
                    id: tm.id,
                    name: tm.name,
                    role: tm.role,
                    fileURL: resolvedURL,
                    sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) },
                    volume: tm.volume,
                    pan: tm.pan,
                    isMuted: tm.isMuted,
                    isSoloed: tm.isSoloed,
                    isSoloSafe: tm.isSoloSafe,
                    routing: tm.routing,
                    assignedBusName: tm.assignedBusName,
                    includeInWaveform: tm.includeInWaveform
                )
                stemTrack.duration = (tm.duration ?? 0.0) > 0 ? (tm.duration ?? fallbackSongDur) : fallbackSongDur
                stemTrack.waveformPeaks = TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                placeholderTracks.append((stemTrack, sharedPlaceholderBuffer))
            }
            
            placeholderTracks.sort { (a, b) -> Bool in
                let cat1 = StemCategory.category(for: a.0.name, role: a.0.role)
                let cat2 = StemCategory.category(for: b.0.name, role: b.0.role)
                if cat1 != cat2 { return cat1 < cat2 }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            
            let resolvedClickSource: ClickSource = hasUploadedClickFile ? (songEntry.clickSource ?? .uploaded) : .generated
            let resolvedGuideSource: GuideSource = hasUploadedGuideFile ? (songEntry.guideSource ?? .uploaded) : .generated
            
            var song = Song(
                id: songEntry.id,
                title: songEntry.title,
                artist: songEntry.artist,
                bpm: songEntry.bpm,
                originalBPM: songEntry.originalBPM,
                timeSignatureNumerator: songEntry.timeSignatureNumerator,
                timeSignatureDenominator: songEntry.timeSignatureDenominator,
                musicalKey: songEntry.musicalKey,
                transposeSemitones: songEntry.transposeSemitones,
                preserveVocalFormants: songEntry.preserveVocalFormants,
                sections: songEntry.sections,
                defaultSections: songEntry.defaultSections,
                savedArrangements: songEntry.savedArrangements,
                activeArrangementId: songEntry.activeArrangementId,
                defaultMidiCues: songEntry.defaultMidiCues,
                defaultDirectionalCues: songEntry.defaultDirectionalCues,
                defaultAutomationPoints: songEntry.defaultAutomationPoints,
                defaultSmpteCue: songEntry.defaultSmpteCue,
                stemURLs: stemURLs,
                timeSignatureChanges: songEntry.timeSignatureChanges,
                beatGrid: songEntry.beatGrid,
                midiCues: songEntry.midiCues,
                directionalCues: songEntry.directionalCues,
                automationPoints: songEntry.automationPoints,
                smpteCue: songEntry.smpteCue,
                proPresenterPlaylist: songEntry.proPresenterPlaylist,
                proPresenterPlaylistItem: songEntry.proPresenterPlaylistItem,
                transitionType: songEntry.transitionType,
                continuePad: songEntry.continuePad,
                endFadeOutEnabled: songEntry.endFadeOutEnabled,
                startPadWithSong: songEntry.startPadWithSong,
                padPresetId: songEntry.padPresetId,
                padIntroOutroOnly: songEntry.padIntroOutroOnly,
                artworkData: loadedArtwork,
                clickSource: resolvedClickSource,
                guideSource: resolvedGuideSource,
                guideVoice: (songEntry.usesDefaultGuideVoice == true) ? GuideVoice.defaultVoice : (songEntry.guideVoice ?? GuideVoice.defaultVoice),
                guideFallbackVoice: songEntry.guideFallbackVoice ?? CustomSampleLibraryManager.shared.defaultGuideFallbackVoice,
                clickSound: (songEntry.usesDefaultClickSound == true) ? ClickSoundType.defaultSound : (songEntry.clickSound ?? ClickSoundType.defaultSound),
                usesDefaultClickSound: songEntry.usesDefaultClickSound ?? (songEntry.clickSound == nil),
                usesDefaultGuideVoice: songEntry.usesDefaultGuideVoice ?? (songEntry.guideVoice == nil),
                clickAccentEnabled: songEntry.clickAccentEnabled ?? true,
                clickQuarterEnabled: songEntry.clickQuarterEnabled ?? true,
                clickEighthEnabled: songEntry.clickEighthEnabled ?? true,
                clickSixteenthEnabled: songEntry.clickSixteenthEnabled ?? false,
                clickAccentVolume: songEntry.clickAccentVolume ?? 0.80,
                clickQuarterVolume: songEntry.clickQuarterVolume ?? 0.80,
                clickEighthVolume: songEntry.clickEighthVolume ?? 0.70,
                clickSixteenthVolume: songEntry.clickSixteenthVolume ?? 0.0,
                guideCountInEnabled: songEntry.guideCountInEnabled ?? true,
                speakDirectionalCuesOnUploadedGuide: songEntry.speakDirectionalCuesOnUploadedGuide ?? true,
                autoInfiniteLoop: songEntry.autoInfiniteLoop ?? false,
                excludesClickAndGuide: songEntry.excludesClickAndGuide ?? false
            )
            song.timeSignatureChanges = songEntry.timeSignatureChanges
            
            restoredSongs.append(song)
            songsPlaceholderData.append((song: song, tracks: placeholderTracks))
        }
        
        let setlist = Setlist(
            id: sessionMeta.id,
            name: sessionMeta.name,
            date: sessionMeta.date,
            serviceType: sessionMeta.serviceType,
            serviceTime: sessionMeta.serviceTime,
            scheduledDate: sessionMeta.scheduledDate,
            songs: restoredSongs
        )
        
        return HydratedSessionMetadata(
            setlist: setlist,
            currentSongIndex: sessionMeta.currentSongIndex,
            songEntries: sessionMeta.songEntries,
            songsPlaceholderData: songsPlaceholderData,
            sourceURL: sourceURL,
            isDirectorySource: isDirectorySource,
            needsArchiveExtractionForStems: !isDirectorySource && anyMissingFromStemCache,
            metadataRootFolder: rootFolder,
            cleanupFolder: cleanupFolder
        )
    }
    
    public struct LocalLibrarySongEntry: @unchecked Sendable {
        public let meta: SongPackageMetadata
        public let packageURL: URL
    }

    public func buildLocalLibraryStemIndex() -> [LocalLibrarySongEntry] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let localSongsDir = appSupport.appendingPathComponent("PeanutButter/Songs", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: localSongsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        var index: [LocalLibrarySongEntry] = []
        for pkgURL in entries where pkgURL.pathExtension.lowercased() == "pbsong" {
            let metaURL = pkgURL.appendingPathComponent("song.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let localMeta = try? decoder.decode(SongPackageMetadata.self, from: data) else {
                continue
            }
            index.append(LocalLibrarySongEntry(meta: localMeta, packageURL: pkgURL))
        }
        return index
    }

    /// Fires non-blocking iCloud download requests for all uncached stems across the ordered song entries
    /// so macOS FileProvider / bird pipelines downloads in the background while earlier songs decode.
    public func prefetchCloudStems(for songEntries: [SongPackageMetadata], rootFolder: URL) {
        let fm = FileManager.default
        let inferredStemsRoot = rootFolder
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Stems", isDirectory: true)
        let stemsRoots = [LibraryBrowserManager.cloudStemsDirectoryURL, inferredStemsRoot].compactMap { $0 }

        for entry in songEntries {
            let hasUncached = entry.tracks.contains { !$0.relativeAudioPath.isEmpty && !hasValidCachedStem(for: $0.id) }
            guard hasUncached else { continue }

            // 1. Trigger download of the single atomic `<songId>.pbstems` pack if present
            for stemsRoot in stemsRoots {
                let packURL = resolveCloudStemPackURL(cloudStemsDir: stemsRoot, songId: entry.id)
                let placeholder = stemsRoot.appendingPathComponent(".\(packURL.lastPathComponent).icloud")
                if fm.fileExists(atPath: packURL.path) || fm.fileExists(atPath: placeholder.path) {
                    if !LibraryBrowserManager.checkIsDownloaded(at: packURL) {
                        LibraryBrowserManager.triggerCloudDownload(at: packURL)
                    }
                }
            }

            // 2. Also trigger any legacy loose stem files if present
            for tm in entry.tracks where !tm.relativeAudioPath.isEmpty && !hasValidCachedStem(for: tm.id) {
                if let url = resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: false) {
                    if !LibraryBrowserManager.checkIsDownloaded(at: url) {
                        LibraryBrowserManager.triggerCloudDownload(at: url)
                    }
                }
            }
        }
    }

    /// Stage 2 helper: Ensures archive stems are extracted if needed and decodes a single song's audio buffers in parallel.
    public func decodeSongEntryAudio(
        songEntry: SongPackageMetadata,
        rootFolder: URL,
        canonicalFormat: AVAudioFormat?,
        localLibraryIndex: [LocalLibrarySongEntry]? = nil,
        isCancelled: (() -> Bool)? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) -> (tracks: [(StemTrack, AVAudioPCMBuffer)], transposedBuffers: [UUID: AVAudioPCMBuffer]) {
        let (_, loadedTracks, loadedTransposed) = decodeSongEntry(
            songEntry: songEntry,
            rootFolder: rootFolder,
            artworkOverride: songEntry.artworkData,
            canonicalFormat: canonicalFormat,
            localLibraryIndex: localLibraryIndex,
            isCancelled: isCancelled,
            progressHandler: progressHandler
        )
        return (loadedTracks, loadedTransposed)
    }
    
    public func extractFullArchiveForHydration(archiveURL: URL, toFolderURL: URL) throws {
        try unzipArchive(archiveURL: archiveURL, toFolderURL: toFolderURL)
    }
    
    // MARK: - Parallel Song & Track Decoding Helper

    /// Checks the local Songs library (`~/Library/Application Support/PeanutButter/Songs`) for a
    /// matching `.pbsong` package (by song ID, or by title + artist + BPM) and returns stem file
    /// URLs indexed by track ID and lowercased track name so cloud setlists can reuse local stems
    /// without re-downloading them.
    private func resolveLocalLibraryStemURLs(
        for songEntry: SongPackageMetadata,
        localLibraryIndex: [LocalLibrarySongEntry]? = nil
    ) -> (byId: [UUID: URL], byName: [String: URL]) {
        let fm = FileManager.default
        let entries = localLibraryIndex ?? buildLocalLibraryStemIndex()

        for entry in entries {
            let localMeta = entry.meta
            let pkgURL = entry.packageURL

            let idMatches = localMeta.id == songEntry.id
            let titleMatches = localMeta.title.localizedCaseInsensitiveCompare(songEntry.title) == .orderedSame
            let artistMatches = localMeta.artist.isEmpty || songEntry.artist.isEmpty ||
                localMeta.artist.localizedCaseInsensitiveCompare(songEntry.artist) == .orderedSame
            let bpmMatches = abs(localMeta.originalBPM - songEntry.originalBPM) < 0.5

            if idMatches || (titleMatches && artistMatches && bpmMatches) {
                var byId: [UUID: URL] = [:]
                var byName: [String: URL] = [:]
                for lt in localMeta.tracks where !lt.relativeAudioPath.isEmpty {
                    let stemURL = pkgURL.appendingPathComponent(lt.relativeAudioPath)
                    if fm.fileExists(atPath: stemURL.path) {
                        byId[lt.id] = stemURL
                        byName[lt.name.lowercased()] = stemURL
                    }
                }
                if !byId.isEmpty {
                    return (byId, byName)
                }
            }
        }
        return ([:], [:])
    }

    private func decodeSongEntry(
        songEntry: SongPackageMetadata,
        rootFolder: URL,
        artworkOverride: Data?,
        canonicalFormat: AVAudioFormat?,
        localLibraryIndex: [LocalLibrarySongEntry]? = nil,
        isCancelled: (() -> Bool)? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) -> (song: Song, tracks: [(StemTrack, AVAudioPCMBuffer)], transposedBuffers: [UUID: AVAudioPCMBuffer]) {
        let fm = FileManager.default
        let trackCount = songEntry.tracks.count
        let localStems = resolveLocalLibraryStemURLs(for: songEntry, localLibraryIndex: localLibraryIndex)
        
        struct DecodedTrackItem {
            let track: StemTrack
            let buffer: AVAudioPCMBuffer
            let persistentURL: URL?
            let transposedBuffer: AVAudioPCMBuffer?
        }
        
        let decodedBox = UnsafeMutableBufferPointer<DecodedTrackItem?>.allocate(capacity: max(1, trackCount))
        decodedBox.initialize(repeating: nil)
        defer {
            decodedBox.deinitialize()
            decodedBox.deallocate()
        }
        
        let fallbackFormat = canonicalFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
        let progressLock = NSLock()
        var completedTracks = 0
        // Limit active blocking cloud download waits per song so 30+ stems don't expire their timeout while queued behind earlier stems
        let cloudDownloadSemaphore = DispatchSemaphore(value: 4)
        
        if trackCount > 0 {
            var packReportedProgress = false
            // Unpack the single atomic `<songId>.pbstems` pack (if present) directly into StemCache first
            _ = self.unpackCloudStemPackIfNeeded(for: songEntry, rootFolder: rootFolder, isCancelled: isCancelled) { packFrac in
                packReportedProgress = true
                if let progressHandler = progressHandler {
                    let scaled = max(0, min(800, Int((packFrac * 800.0).rounded())))
                    progressHandler(scaled, 1000)
                }
            }

            // Queue any remaining uncached cloud stems upfront so FileProvider / Google Drive pipelines them immediately
            for tm in songEntry.tracks where !tm.relativeAudioPath.isEmpty && !self.hasValidCachedStem(for: tm.id) {
                if let u = self.resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: false),
                   !LibraryBrowserManager.checkIsDownloaded(at: u) {
                    LibraryBrowserManager.triggerCloudDownload(at: u)
                }
            }

            DispatchQueue.concurrentPerform(iterations: trackCount) { idx in
                defer {
                    if let progressHandler = progressHandler {
                        progressLock.lock()
                        completedTracks += 1
                        let done = completedTracks
                        progressLock.unlock()
                        if packReportedProgress {
                            let scaled = 800 + (done * 200) / trackCount
                            progressHandler(scaled, 1000)
                        } else {
                            progressHandler(done, trackCount)
                        }
                    }
                }
                if isCancelled?() == true { return }
                let tm = songEntry.tracks[idx]
                let cachedURL = self.cachedStemURL(for: tm.id)
                
                // Case 1: Generated Click / Guide track with no audio file on disk
                if tm.relativeAudioPath.isEmpty {
                    guard let tinyBuf = AVAudioPCMBuffer(pcmFormat: fallbackFormat, frameCapacity: 1) else { return }
                    tinyBuf.frameLength = 1
                    let fallbackSongDur = songEntry.sections.map { $0.endTime }.max() ?? 0.0
                    let stemTrack = StemTrack(
                        id: tm.id,
                        name: tm.name,
                        role: tm.role,
                        fileURL: nil,
                        volume: tm.volume,
                        pan: tm.pan,
                        isMuted: tm.isMuted,
                        isSoloed: tm.isSoloed,
                        isSoloSafe: tm.isSoloSafe,
                        routing: tm.routing,
                        assignedBusName: tm.assignedBusName,
                        includeInWaveform: tm.includeInWaveform
                    )
                    stemTrack.duration = (tm.duration ?? 0.0) > 0 ? (tm.duration ?? fallbackSongDur) : fallbackSongDur
                    stemTrack.waveformPeaks = TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                    decodedBox[idx] = DecodedTrackItem(track: stemTrack, buffer: tinyBuf, persistentURL: nil, transposedBuffer: nil)
                    return
                }
                
                let packageAudioURL = self.resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: false)
                let sourceAudioURL: URL
                var usedCachedStem = false
                if self.hasValidCachedStem(for: tm.id) {
                    sourceAudioURL = cachedURL
                    usedCachedStem = true
                } else if let localStemURL = localStems.byId[tm.id] ?? localStems.byName[tm.name.lowercased()],
                          fm.fileExists(atPath: localStemURL.path) {
                    sourceAudioURL = localStemURL
                } else if let pkgURL = packageAudioURL {
                    if !LibraryBrowserManager.checkIsDownloaded(at: pkgURL) {
                        cloudDownloadSemaphore.wait()
                        defer { cloudDownloadSemaphore.signal() }
                        if isCancelled?() == true { return }
                        LibraryBrowserManager.ensureCloudItemDownloaded(at: pkgURL, timeout: 120.0, isCancelled: isCancelled)
                    }
                    if isCancelled?() == true { return }
                    if fm.fileExists(atPath: pkgURL.path) {
                        sourceAudioURL = pkgURL
                    } else if let fallbackURL = self.resolvePackageStemURL(relativePath: tm.relativeAudioPath, rootFolder: rootFolder, triggerDownload: true),
                              fm.fileExists(atPath: fallbackURL.path) {
                        sourceAudioURL = fallbackURL
                    } else {
                        return
                    }
                } else {
                    return
                }
                
                var decodedRaw = try? self.readPCMBuffer(from: sourceAudioURL)
                if decodedRaw == nil && usedCachedStem {
                    // Evict corrupted/incomplete cached stem and retry from cloud/package source
                    try? fm.removeItem(at: cachedURL)
                    if let pkgURL = packageAudioURL {
                        if !LibraryBrowserManager.checkIsDownloaded(at: pkgURL) {
                            cloudDownloadSemaphore.wait()
                            defer { cloudDownloadSemaphore.signal() }
                            LibraryBrowserManager.ensureCloudItemDownloaded(at: pkgURL, timeout: 120.0, isCancelled: isCancelled)
                        }
                        if isCancelled?() == true { return }
                        if fm.fileExists(atPath: pkgURL.path) {
                            decodedRaw = try? self.readPCMBuffer(from: pkgURL)
                        }
                    }
                } else if decodedRaw == nil {
                    for _ in 0..<3 {
                        if isCancelled?() == true { return }
                        if LibraryBrowserManager.isCloudStorageURL(sourceAudioURL) && !LibraryBrowserManager.checkIsDownloaded(at: sourceAudioURL) {
                            cloudDownloadSemaphore.wait()
                            LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceAudioURL, timeout: 60.0, isCancelled: isCancelled)
                            cloudDownloadSemaphore.signal()
                        }
                        Thread.sleep(forTimeInterval: 0.4)
                        if let retryBuf = try? self.readPCMBuffer(from: sourceAudioURL) {
                            decodedRaw = retryBuf
                            break
                        }
                    }
                }
                guard let rawBuffer = decodedRaw else { return }
                let finalBuffer: AVAudioPCMBuffer
                if let targetFmt = canonicalFormat {
                    finalBuffer = Self.normalizeBuffer(rawBuffer, to: targetFmt)
                } else {
                    finalBuffer = rawBuffer
                }
                
                // Read optional pre-rendered transposed/time-stretched buffer if saved in package or disk cache
                var transposedBuffer: AVAudioPCMBuffer? = nil
                let tempoChanged = abs(songEntry.bpm - songEntry.originalBPM) > 0.005
                if !tempoChanged, let transRel = tm.relativeTransposedAudioPath, !transRel.isEmpty, tm.transposedSemitones == songEntry.transposeSemitones {
                    if let transAudioURL = self.resolvePackageStemURL(relativePath: transRel, rootFolder: rootFolder),
                       fm.fileExists(atPath: transAudioURL.path),
                       let rawTrans = try? self.readPCMBuffer(from: transAudioURL) {
                        transposedBuffer = canonicalFormat != nil ? Self.normalizeBuffer(rawTrans, to: canonicalFormat!) : rawTrans
                    }
                }
                if transposedBuffer == nil && (songEntry.transposeSemitones != 0 || tempoChanged) {
                    let cat = StemCategory.category(for: tm.name, role: tm.role)
                    let isClickOrGuideRole = (cat == .click || cat == .guide || tm.role == .click || tm.role == .guide)
                    let isGeneratedClickOrGuide = (cat == .click && songEntry.clickSource == .generated)
                        || (cat == .guide && songEntry.guideSource == .generated)
                        || (isClickOrGuideRole && tm.relativeAudioPath.isEmpty)
                    let shouldCheckCache = tempoChanged ? !isGeneratedClickOrGuide : !isClickOrGuideRole
                    if shouldCheckCache {
                        let cacheDir = self.transposedStemCacheDirectory(
                            songId: songEntry.id,
                            semitones: songEntry.transposeSemitones,
                            preserveVocalFormants: songEntry.preserveVocalFormants,
                            bpm: songEntry.bpm,
                            originalBPM: songEntry.originalBPM
                        )
                        let diskWavURL = cacheDir.appendingPathComponent("\(tm.id.uuidString).wav")
                        let diskM4aURL = cacheDir.appendingPathComponent("\(tm.id.uuidString).m4a")
                        let diskTransURL = fm.fileExists(atPath: diskWavURL.path) ? diskWavURL : diskM4aURL
                        if fm.fileExists(atPath: diskTransURL.path), let rawTrans = try? self.readPCMBuffer(from: diskTransURL) {
                            transposedBuffer = canonicalFormat != nil ? Self.normalizeBuffer(rawTrans, to: canonicalFormat!) : rawTrans
                        }
                    }
                }
                
                // Ensure StemCache holds the compressed .m4a so tempDir can be safely deleted and future saves are instant
                if sourceAudioURL.pathExtension.lowercased() == "m4a" {
                    if !self.hasValidCachedStem(for: tm.id) {
                        try? self.linkOrCopyFile(from: sourceAudioURL, to: cachedURL)
                    }
                } else {
                    self.cacheStemInBackground(trackId: tm.id, buffer: finalBuffer)
                }
                
                let persistentURL = self.hasValidCachedStem(for: tm.id) ? cachedURL : sourceAudioURL
                let stemTrack = StemTrack(
                    id: tm.id,
                    name: tm.name,
                    role: tm.role,
                    fileURL: persistentURL,
                    sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) },
                    volume: tm.volume,
                    pan: tm.pan,
                    isMuted: tm.isMuted,
                    isSoloed: tm.isSoloed,
                    isSoloSafe: tm.isSoloSafe,
                    routing: tm.routing,
                    assignedBusName: tm.assignedBusName,
                    includeInWaveform: tm.includeInWaveform
                )
                stemTrack.duration = Double((transposedBuffer ?? finalBuffer).frameLength) / (transposedBuffer ?? finalBuffer).format.sampleRate
                
                let cachedPeaks = TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                if !cachedPeaks.isEmpty {
                    stemTrack.waveformPeaks = cachedPeaks
                } else if stemTrack.includeInWaveform {
                    stemTrack.waveformPeaks = Self.extractPeaks(from: finalBuffer, samplesCount: 4000)
                }
                
                decodedBox[idx] = DecodedTrackItem(track: stemTrack, buffer: finalBuffer, persistentURL: persistentURL, transposedBuffer: transposedBuffer)
            }
        }
        
        var loadedTracks: [(StemTrack, AVAudioPCMBuffer)] = []
        loadedTracks.reserveCapacity(trackCount)
        var loadedTransposed: [UUID: AVAudioPCMBuffer] = [:]
        var stemURLs: [URL] = []
        var hasUploadedClickFile = false
        var hasUploadedGuideFile = false
        
        for idx in 0..<trackCount {
            guard let item = decodedBox[idx] else { continue }
            let cat = StemCategory.category(for: item.track.name, role: item.track.role)
            if cat == .click && item.persistentURL != nil {
                hasUploadedClickFile = true
            } else if cat == .guide && item.persistentURL != nil {
                hasUploadedGuideFile = true
            }
            loadedTracks.append((item.track, item.buffer))
            if let trBuf = item.transposedBuffer {
                loadedTransposed[item.track.id] = trBuf
            }
            if let u = item.persistentURL {
                stemURLs.append(u)
            }
        }
        
        let resolvedClickSource: ClickSource = hasUploadedClickFile ? (songEntry.clickSource ?? .uploaded) : .generated
        let resolvedGuideSource: GuideSource = hasUploadedGuideFile ? (songEntry.guideSource ?? .uploaded) : .generated
        
        let song = buildSong(
            from: songEntry,
            artworkOverride: artworkOverride,
            stemURLs: stemURLs,
            resolvedClickSource: resolvedClickSource,
            resolvedGuideSource: resolvedGuideSource
        )
        
        return (song, loadedTracks, loadedTransposed)
    }

    private func buildSong(
        from songEntry: SongPackageMetadata,
        artworkOverride: Data?,
        stemURLs: [URL],
        resolvedClickSource: ClickSource,
        resolvedGuideSource: GuideSource
    ) -> Song {
        Song(
            id: songEntry.id,
            title: songEntry.title,
            artist: songEntry.artist,
            bpm: songEntry.bpm,
            originalBPM: songEntry.originalBPM,
            timeSignatureNumerator: songEntry.timeSignatureNumerator,
            timeSignatureDenominator: songEntry.timeSignatureDenominator,
            musicalKey: songEntry.musicalKey,
            transposeSemitones: songEntry.transposeSemitones,
            preserveVocalFormants: songEntry.preserveVocalFormants,
            sections: songEntry.sections,
            defaultSections: songEntry.defaultSections,
            savedArrangements: songEntry.savedArrangements,
            activeArrangementId: songEntry.activeArrangementId,
            defaultMidiCues: songEntry.defaultMidiCues,
            defaultDirectionalCues: songEntry.defaultDirectionalCues,
            defaultAutomationPoints: songEntry.defaultAutomationPoints,
            defaultSmpteCue: songEntry.defaultSmpteCue,
            stemURLs: stemURLs,
            timeSignatureChanges: songEntry.timeSignatureChanges,
            beatGrid: songEntry.beatGrid,
            midiCues: songEntry.midiCues,
            directionalCues: songEntry.directionalCues,
            automationPoints: songEntry.automationPoints,
            smpteCue: songEntry.smpteCue,
            proPresenterPlaylist: songEntry.proPresenterPlaylist,
            proPresenterPlaylistItem: songEntry.proPresenterPlaylistItem,
            transitionType: songEntry.transitionType,
            continuePad: songEntry.continuePad,
            endFadeOutEnabled: songEntry.endFadeOutEnabled,
            startPadWithSong: songEntry.startPadWithSong,
            padPresetId: songEntry.padPresetId,
            padIntroOutroOnly: songEntry.padIntroOutroOnly,
            artworkData: artworkOverride ?? songEntry.artworkData,
            clickSource: resolvedClickSource,
            guideSource: resolvedGuideSource,
            guideVoice: (songEntry.usesDefaultGuideVoice == true) ? GuideVoice.defaultVoice : (songEntry.guideVoice ?? GuideVoice.defaultVoice),
            guideFallbackVoice: songEntry.guideFallbackVoice ?? CustomSampleLibraryManager.shared.defaultGuideFallbackVoice,
            clickSound: (songEntry.usesDefaultClickSound == true) ? ClickSoundType.defaultSound : (songEntry.clickSound ?? ClickSoundType.defaultSound),
            usesDefaultClickSound: songEntry.usesDefaultClickSound ?? (songEntry.clickSound == nil),
            usesDefaultGuideVoice: songEntry.usesDefaultGuideVoice ?? (songEntry.guideVoice == nil),
            clickAccentEnabled: songEntry.clickAccentEnabled ?? true,
            clickQuarterEnabled: songEntry.clickQuarterEnabled ?? true,
            clickEighthEnabled: songEntry.clickEighthEnabled ?? true,
            clickSixteenthEnabled: songEntry.clickSixteenthEnabled ?? false,
            clickAccentVolume: songEntry.clickAccentVolume ?? 0.80,
            clickQuarterVolume: songEntry.clickQuarterVolume ?? 0.80,
            clickEighthVolume: songEntry.clickEighthVolume ?? 0.70,
            clickSixteenthVolume: songEntry.clickSixteenthVolume ?? 0.0,
            guideCountInEnabled: songEntry.guideCountInEnabled ?? true,
            speakDirectionalCuesOnUploadedGuide: songEntry.speakDirectionalCuesOnUploadedGuide ?? true,
            autoInfiniteLoop: songEntry.autoInfiniteLoop ?? false,
            excludesClickAndGuide: songEntry.excludesClickAndGuide ?? false
        )
    }
    
    private func makeSongPackageMetadata(
        song: Song,
        tracks: [TrackFileMetadata],
        embedArtworkInJSON: Bool
    ) -> SongPackageMetadata {
        SongPackageMetadata(
            version: 2,
            id: song.id,
            title: song.title,
            artist: song.artist,
            bpm: song.bpm,
            originalBPM: song.originalBPM,
            timeSignatureNumerator: song.timeSignatureNumerator,
            timeSignatureDenominator: song.timeSignatureDenominator,
            musicalKey: song.musicalKey,
            transposeSemitones: song.transposeSemitones,
            preserveVocalFormants: song.preserveVocalFormants,
            sections: song.sections,
            defaultSections: song.defaultSections,
            savedArrangements: song.savedArrangements,
            activeArrangementId: song.activeArrangementId,
            tracks: tracks,
            beatGrid: song.beatGrid,
            timeSignatureChanges: song.timeSignatureChanges,
            midiCues: song.midiCues,
            directionalCues: song.directionalCues,
            automationPoints: song.automationPoints,
            smpteCue: song.smpteCue,
            defaultMidiCues: song.defaultMidiCues,
            defaultDirectionalCues: song.defaultDirectionalCues,
            defaultAutomationPoints: song.defaultAutomationPoints,
            defaultSmpteCue: song.defaultSmpteCue,
            proPresenterPlaylist: song.proPresenterPlaylist,
            proPresenterPlaylistItem: song.proPresenterPlaylistItem,
            transitionType: song.transitionType,
            continuePad: song.continuePad,
            endFadeOutEnabled: song.endFadeOutEnabled,
            startPadWithSong: song.startPadWithSong,
            padPresetId: song.padPresetId,
            padIntroOutroOnly: song.padIntroOutroOnly,
            artworkData: embedArtworkInJSON ? song.artworkData : nil,
            clickSource: song.clickSource,
            guideSource: song.guideSource,
            guideVoice: song.guideVoice,
            guideFallbackVoice: song.guideFallbackVoice,
            clickSound: song.clickSound,
            usesDefaultClickSound: song.usesDefaultClickSound,
            usesDefaultGuideVoice: song.usesDefaultGuideVoice,
            clickAccentEnabled: song.clickAccentEnabled,
            clickQuarterEnabled: song.clickQuarterEnabled,
            clickEighthEnabled: song.clickEighthEnabled,
            clickSixteenthEnabled: song.clickSixteenthEnabled,
            clickAccentVolume: song.clickAccentVolume,
            clickQuarterVolume: song.clickQuarterVolume,
            clickEighthVolume: song.clickEighthVolume,
            clickSixteenthVolume: song.clickSixteenthVolume,
            guideCountInEnabled: song.guideCountInEnabled,
            speakDirectionalCuesOnUploadedGuide: song.speakDirectionalCuesOnUploadedGuide,
            autoInfiniteLoop: song.autoInfiniteLoop,
            excludesClickAndGuide: song.excludesClickAndGuide ? true : nil
        )
    }
    
    private func buildUniqueStemFileNames(for tracks: [StemTrack], ext: String) -> [String] {
        var usedNames: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(tracks.count)
        
        for (idx, track) in tracks.enumerated() {
            let base = sanitizeFileName(track.name)
            var candidate = "\(base).\(ext)"
            if usedNames.contains(candidate.lowercased()) {
                candidate = "\(base)_\(idx + 1).\(ext)"
            }
            usedNames.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }
    
    // MARK: - Audio Buffer & Compression Utilities
    
    private func isMonoBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.channelCount == 2,
              let ch0 = buffer.floatChannelData?[0],
              let ch1 = buffer.floatChannelData?[1] else {
            return buffer.format.channelCount == 1
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return true }
        let step = max(1, frames / 2048)
        for i in stride(from: 0, to: frames, by: step) {
            if abs(ch0[i] - ch1[i]) > 1e-5 {
                return false
            }
        }
        return true
    }
    
    /// Writes a high-efficiency AAC `.m4a` file (160 kbps mono for identical L/R stems, 256 kbps stereo for stereo stems)
    public func writeCompressedStem(_ buffer: AVAudioPCMBuffer, to fileURL: URL) throws {
        let sampleRate = buffer.format.sampleRate
        let writeMono = isMonoBuffer(buffer)
        
        if sampleRate >= 44100.0 && sampleRate <= 48000.0 {
            do {
                if writeMono, buffer.format.channelCount > 1,
                   let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                   let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) {
                    monoBuffer.frameLength = buffer.frameLength
                    if let src = buffer.floatChannelData?[0], let dst = monoBuffer.floatChannelData?[0] {
                        memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                    }
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 160_000
                    ]
                    let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    try audioFile.write(from: monoBuffer)
                    return
                } else {
                    let channels = Int(buffer.format.channelCount)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: channels == 1 ? 160_000 : 256_000
                    ]
                    let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    try audioFile.write(from: buffer)
                    return
                }
            } catch {
                // Fall back to 16-bit PCM if AAC fails for any reason
            }
        }
        
        try writePCMBuffer(buffer, to: fileURL)
    }
    
    public func writePCMBuffer(_ buffer: AVAudioPCMBuffer, to fileURL: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: buffer)
    }
    
    public func readPCMBuffer(from fileURL: URL) throws -> AVAudioPCMBuffer {
        var coordError: NSError?
        var readError: Error?
        var resultBuffer: AVAudioPCMBuffer?

        // Coordinate reading so FileProvider-backed cloud drives (Google Drive, iCloud Drive,
        // Dropbox, OneDrive) materialize the full audio file before AVAudioFile opens it.
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: fileURL, options: [], error: &coordError) { coordinatedURL in
            do {
                let audioFile = try AVAudioFile(forReading: coordinatedURL)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                    throw NSError(domain: "PlaybackFileManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer for \(coordinatedURL.lastPathComponent)"])
                }
                try audioFile.read(into: buffer)
                resultBuffer = buffer
            } catch {
                readError = error
            }
        }

        if let err = readError ?? coordError {
            throw err
        }
        guard let buffer = resultBuffer else {
            throw NSError(domain: "PlaybackFileManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Empty audio buffer for \(fileURL.lastPathComponent)"])
        }
        return buffer
    }
    
    /// Thread-safe stereo/sample-rate buffer normalization for parallel stem loading
    public static func normalizeBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer {
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
        
        if stereoBuffer.format.sampleRate == targetFormat.sampleRate && stereoBuffer.format.channelCount == targetFormat.channelCount {
            return stereoBuffer
        }
        
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
    
    /// SIMD-accelerated peak extraction via `vDSP_maxmgv` safe for concurrent worker threads
    public static func extractPeaks(from buffer: AVAudioPCMBuffer, samplesCount: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0, samplesCount > 0 else {
            return Array(repeating: 0.1, count: max(1, samplesCount))
        }
        
        let totalFrames = Int(buffer.frameLength)
        var peaks = [Float](repeating: 0.0, count: samplesCount)
        
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
    
    // MARK: - Zip & Process Helpers
    
    private func zipFolder(folderURL: URL, toArchiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folderURL
        process.arguments = ["-0", "-r", "-q", toArchiveURL.path, "."]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "PlaybackFileManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Zip process failed with code \(process.terminationStatus)"])
        }
    }
    
    private func unzipArchive(archiveURL: URL, toFolderURL: URL) throws {
        try FileManager.default.createDirectory(at: toFolderURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "-d", toFolderURL.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "PlaybackFileManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Unzip process failed with code \(process.terminationStatus)"])
        }
    }
    
    /// Extracts only `session.json` and `songs/*/artwork.png` from a `.pbsession` zip archive in milliseconds, skipping all heavy `.m4a` stems
    private func unzipMetadataOnly(archiveURL: URL, toFolderURL: URL) throws {
        try FileManager.default.createDirectory(at: toFolderURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "session.json", "songs/*/artwork.png", "-d", toFolderURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // Note: unzip returns 11 when optional "songs/*/artwork.png" wildcard doesn't match any file, while still extracting session.json
        let jsonURL = toFolderURL.appendingPathComponent("session.json")
        if !FileManager.default.fileExists(atPath: jsonURL.path) {
            throw NSError(domain: "PlaybackFileManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Unzip metadata failed with code \(process.terminationStatus)"])
        }
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    // MARK: - Background Cloud Stem Pack Migration

    /// Automatically migrates any legacy loose `<CloudRoot>/Stems/<songId>/` directories or manually
    /// dropped `.pbsong` packages with embedded `stems/` in `<CloudRoot>/Songs/` into atomic
    /// `<CloudRoot>/Stems/<songId>.pbstems` packs + `<songId>.tracks.json` manifests.
    public func migrateLegacyCloudStemsInBackground() {
        Task.detached(priority: .utility) {
            guard let cloudRoot = LibraryBrowserManager.cloudRootDirectoryURL else { return }
            let fm = FileManager.default
            let songsDir = cloudRoot.appendingPathComponent("Songs", isDirectory: true)
            let setlistsDir = cloudRoot.appendingPathComponent("Setlists", isDirectory: true)
            let stemsDir = cloudRoot.appendingPathComponent("Stems", isDirectory: true)
            guard fm.fileExists(atPath: stemsDir.path) else { return }

            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            var tracksBySongId: [UUID: [TrackFileMetadata]] = [:]

            // 1. Scan Cloud Songs (and migrate any manually dropped `.pbsong` with embedded `stems/`)
            if let songItems = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for pkgURL in songItems where pkgURL.pathExtension.lowercased() == "pbsong" || pkgURL.pathExtension.lowercased() == "multitrack" {
                    let isDir = (try? pkgURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir else { continue }
                    let jsonURL = pkgURL.appendingPathComponent("song.json")
                    guard let data = try? Data(contentsOf: jsonURL),
                          var meta = try? decoder.decode(SongPackageMetadata.self, from: data) else { continue }

                    var didUpdateJSON = false
                    let embeddedStemsDir = pkgURL.appendingPathComponent("stems", isDirectory: true)
                    var updatedTracks: [TrackFileMetadata] = []
                    for var tm in meta.tracks {
                        if !tm.relativeAudioPath.isEmpty && !tm.relativeAudioPath.hasPrefix("cloudstems/") {
                            let embeddedURL = pkgURL.appendingPathComponent(tm.relativeAudioPath)
                            if self.hasValidStemFile(at: embeddedURL) {
                                if !self.hasValidCachedStem(for: tm.id) {
                                    try? self.linkOrCopyFile(from: embeddedURL, to: self.cachedStemURL(for: tm.id))
                                }
                                let dstStem = self.resolveCloudStemDestination(cloudStemsDir: stemsDir, songId: meta.id, trackId: tm.id)
                                try? fm.createDirectory(at: dstStem.deletingLastPathComponent(), withIntermediateDirectories: true)
                                if !self.hasValidStemFile(at: dstStem) {
                                    try? self.linkOrCopyFile(from: embeddedURL, to: dstStem)
                                }
                                tm = TrackFileMetadata(
                                    id: tm.id, name: tm.name, role: tm.role,
                                    relativeAudioPath: self.cloudStemRelativePath(songId: meta.id, trackId: tm.id),
                                    volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                                    routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                                    duration: tm.duration, waveformPeaksData: tm.waveformPeaksData,
                                    relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                                    sourceFilePath: tm.sourceFilePath
                                )
                                didUpdateJSON = true
                            }
                        }
                        updatedTracks.append(tm)
                    }
                    if didUpdateJSON {
                        meta.tracks = updatedTracks
                        if let outData = try? encoder.encode(meta) {
                            try? outData.write(to: jsonURL, options: .atomic)
                        }
                        if fm.fileExists(atPath: embeddedStemsDir.path) {
                            try? fm.removeItem(at: embeddedStemsDir)
                        }
                    }
                    var merged = tracksBySongId[meta.id] ?? []
                    let existingIds = Set(merged.map { $0.id })
                    for t in meta.tracks where !t.relativeAudioPath.isEmpty && !existingIds.contains(t.id) {
                        merged.append(t)
                    }
                    tracksBySongId[meta.id] = merged
                }
            }

            // 2. Scan Cloud Setlists to collect track metadata for songs only present in setlists
            if let setlistItems = try? fm.contentsOfDirectory(at: setlistsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for sessURL in setlistItems where sessURL.pathExtension.lowercased() == "pbsession" {
                    let isDir = (try? sessURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir else { continue }
                    let jsonURL = sessURL.appendingPathComponent("session.json")
                    guard let data = try? Data(contentsOf: jsonURL),
                          let sessMeta = try? decoder.decode(SessionPackageMetadata.self, from: data) else { continue }
                    for songEntry in sessMeta.songEntries {
                        var merged = tracksBySongId[songEntry.id] ?? []
                        let existingIds = Set(merged.map { $0.id })
                        for t in songEntry.tracks where !t.relativeAudioPath.isEmpty && !existingIds.contains(t.id) {
                            merged.append(t)
                        }
                        tracksBySongId[songEntry.id] = merged
                    }
                }
            }

            // 3. Build `<songId>.pbstems` for any song that has a loose `Stems/<songId>/` folder or lacks a `.pbstems` pack
            for (songId, tracks) in tracksBySongId {
                let packURL = self.resolveCloudStemPackURL(cloudStemsDir: stemsDir, songId: songId)
                let looseDir = stemsDir.appendingPathComponent(songId.uuidString, isDirectory: true)
                if fm.fileExists(atPath: looseDir.path) || !fm.fileExists(atPath: packURL.path) {
                    self.writeCloudStemPack(cloudStemsDir: stemsDir, songId: songId, tracks: tracks)
                }
            }
        }
    }
}
