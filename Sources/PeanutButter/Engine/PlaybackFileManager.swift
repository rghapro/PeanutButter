import Foundation
import AVFoundation
import Accelerate
import AppKit
import Darwin
import zlib

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
    public var version: Int = 3
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
    public var continueClick: Bool = false
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
        version: Int = 3,
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
        continueClick: Bool = false,
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
        self.continueClick = continueClick
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
        case proPresenterPlaylist, proPresenterPlaylistItem, transitionType, continuePad, continueClick, endFadeOutEnabled, startPadWithSong, padPresetId, padIntroOutroOnly, artworkData
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
        self.continueClick = try container.decodeIfPresent(Bool.self, forKey: .continueClick) ?? false
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
    public var version: Int = 3
    public var id: UUID
    public var name: String
    public var date: Date
    public var serviceType: String?
    public var serviceTime: String?
    public var scheduledDate: Date?
    public var currentSongIndex: Int
    public var associatedSessionPath: String?
    public var changeDescription: String?
    public var lastSavedRevisionId: UUID?
    public var lastSavedByDeviceId: String?
    public var songEntries: [SongPackageMetadata]
    
    public init(
        version: Int = 3,
        id: UUID = UUID(),
        name: String = "Sunday Morning Set",
        date: Date = Date(),
        serviceType: String? = nil,
        serviceTime: String? = nil,
        scheduledDate: Date? = nil,
        currentSongIndex: Int = 0,
        associatedSessionPath: String? = nil,
        changeDescription: String? = nil,
        lastSavedRevisionId: UUID? = nil,
        lastSavedByDeviceId: String? = nil,
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
        self.lastSavedRevisionId = lastSavedRevisionId
        self.lastSavedByDeviceId = lastSavedByDeviceId
        self.songEntries = songEntries
    }
}

/// Security & validation errors raised while inspecting archives or package paths.
public enum ArchiveSecurityError: LocalizedError, Equatable {
    case invalidArchive
    case unsafeEntryPath(String)
    case symlinkEntry(String)
    case tooManyEntries(Int)
    case uncompressedSizeExceeded(UInt64)
    case pathTraversal(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "The archive is corrupted or not a valid zip package."
        case .unsafeEntryPath(let path):
            return "Rejected archive containing unsafe entry path: \(path)"
        case .symlinkEntry(let path):
            return "Rejected archive containing symbolic link entry: \(path)"
        case .tooManyEntries(let count):
            return "Rejected archive exceeding maximum entry limit (\(count))."
        case .uncompressedSizeExceeded(let bytes):
            return "Rejected archive exceeding maximum uncompressed size limit (\(bytes) bytes)."
        case .pathTraversal(let path):
            return "Rejected path escaping package directory: \(path)"
        }
    }
}

/// Robust, high-speed file management for saving & loading self-contained .pbsong and .pbsession packages
public final class PlaybackFileManager: @unchecked Sendable {
    public static let shared = PlaybackFileManager()

    private static let deviceInstanceDefaultsKey = "PeanutButter_DeviceInstanceID"
    private static let deviceInstanceLock = NSLock()
    private nonisolated(unsafe) static var cachedDeviceInstanceId: String?
    public nonisolated(unsafe) static var overrideDeviceInstanceIdForTesting: String?

    /// Persistent per-Mac instance identifier stored only in local UserDefaults (never synced to Cloud).
    public nonisolated static var currentDeviceInstanceId: String {
        deviceInstanceLock.lock()
        defer { deviceInstanceLock.unlock() }
        if let override = overrideDeviceInstanceIdForTesting, !override.isEmpty {
            return override
        }
        if let cached = cachedDeviceInstanceId {
            return cached
        }
        if let existing = UserDefaults.standard.string(forKey: deviceInstanceDefaultsKey), !existing.isEmpty {
            cachedDeviceInstanceId = existing
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceInstanceDefaultsKey)
        cachedDeviceInstanceId = generated
        return generated
    }
    
    private let cacheQueue = DispatchQueue(label: "com.peanutbutter.stemcache", qos: .utility, attributes: .concurrent)
    private let cacheLock = NSLock()
    private var inFlightCacheIds: Set<UUID> = []

    private static let losslessAudioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "flac", "caf"]
    private let localStemSourcesLock = NSLock()
    private var localStemSourcesCache: [String: String]?
    public var localStemSourcesFileURLOverride: URL?

    private var activeLocalStemSourcesURL: URL {
        if let override = localStemSourcesFileURLOverride {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PeanutButter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local_stem_sources.json")
    }

    private func loadLocalStemSourcesMapLocked() -> [String: String] {
        if let cached = localStemSourcesCache {
            return cached
        }
        let url = activeLocalStemSourcesURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            localStemSourcesCache = decoded
            return decoded
        }
        localStemSourcesCache = [:]
        return [:]
    }

    public func reloadLocalStemSourcesForTesting() {
        localStemSourcesLock.lock()
        localStemSourcesCache = nil
        _ = loadLocalStemSourcesMapLocked()
        localStemSourcesLock.unlock()
    }

    public func recordLocalLosslessSources(_ entries: [(UUID, URL?)]) {
        guard !entries.isEmpty else { return }
        let fm = FileManager.default
        localStemSourcesLock.lock()
        var map = loadLocalStemSourcesMapLocked()
        var changed = false
        for (trackId, candidateURL) in entries {
            guard let url = candidateURL,
                  url.isFileURL,
                  Self.losslessAudioExtensions.contains(url.pathExtension.lowercased()),
                  fm.fileExists(atPath: url.path) else {
                continue
            }
            let path = url.standardizedFileURL.path
            let key = trackId.uuidString
            if map[key] != path {
                map[key] = path
                changed = true
            }
        }
        if changed {
            localStemSourcesCache = map
            let dest = activeLocalStemSourcesURL
            if let data = try? JSONEncoder().encode(map) {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: dest, options: .atomic)
            }
        }
        localStemSourcesLock.unlock()
    }

    public func lookupLocalLosslessSourceURL(for trackId: UUID) -> URL? {
        localStemSourcesLock.lock()
        let map = loadLocalStemSourcesMapLocked()
        let path = map[trackId.uuidString]
        localStemSourcesLock.unlock()
        guard let path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
    
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
    
    private static func allocateReplacementStagingDirectory(appropriateFor destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }
        if let replacementDir = try? fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationDir,
            create: true
        ) {
            return replacementDir
        }
        let fallbackDir = fm.temporaryDirectory.appendingPathComponent("pb_stage_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir
    }

    /// Commits a staged local file into `destinationURL` atomically using `FileManager.replaceItemAt`,
    /// wrapping Cloud Storage destinations in `NSFileCoordinator(.forReplacing)` so cloud sync daemons
    /// never observe partially written `.pb_tmp_*` files or split writes.
    public func coordinatedReplaceFile(stagedFileURL: URL, destinationURL: URL) throws {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        func performReplace(at targetURL: URL) throws {
            if fm.fileExists(atPath: targetURL.path) {
                do {
                    _ = try fm.replaceItemAt(
                        targetURL,
                        withItemAt: stagedFileURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                    Self.stripCloudExtendedAttributes(at: targetURL)
                    return
                } catch {
                    let nsErr = error as NSError
                    let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError
                    let isCrossDevice = (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(EXDEV))
                        || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EXDEV))
                    guard isCrossDevice else {
                        throw error
                    }
                    try fm.removeItem(at: targetURL)
                }
            }

            do {
                try fm.moveItem(at: stagedFileURL, to: targetURL)
                Self.stripCloudExtendedAttributes(at: targetURL)
            } catch {
                let rc = Darwin.copyfile(stagedFileURL.path, targetURL.path, nil, copyfile_flags_t(COPYFILE_DATA))
                if rc != 0 {
                    try fm.copyItem(at: stagedFileURL, to: targetURL)
                }
                Self.stripCloudExtendedAttributes(at: targetURL)
                try? fm.removeItem(at: stagedFileURL)
            }
        }

        if LibraryBrowserManager.isCloudStorageURL(destinationURL) {
            var coordError: NSError?
            var innerError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: destinationURL, options: .forReplacing, error: &coordError) { coordinatedURL in
                do {
                    try performReplace(at: coordinatedURL)
                } catch {
                    innerError = error
                }
            }
            if let coordErr = coordError {
                throw coordErr
            }
            if let inner = innerError {
                throw inner
            }
        } else {
            try performReplace(at: destinationURL)
        }
    }

    /// Commits a staged package directory atomically into `destinationURL` via `replaceItemAt`,
    /// preserving the prior package if replacement fails or runs inside a Cloud Storage folder.
    public func coordinatedReplaceDirectory(stagedDirectoryURL: URL, destinationURL: URL) throws {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        func performReplace(at targetURL: URL) throws {
            if fm.fileExists(atPath: targetURL.path) {
                do {
                    _ = try fm.replaceItemAt(
                        targetURL,
                        withItemAt: stagedDirectoryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                    return
                } catch {
                    let nsErr = error as NSError
                    let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError
                    let isCrossDevice = (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(EXDEV))
                        || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EXDEV))
                    guard isCrossDevice else {
                        throw error
                    }
                    let backupURL = parentDir.appendingPathComponent(".pb_bak_\(UUID().uuidString)")
                    try fm.moveItem(at: targetURL, to: backupURL)
                    do {
                        try fm.moveItem(at: stagedDirectoryURL, to: targetURL)
                        try? fm.removeItem(at: backupURL)
                    } catch {
                        try? fm.moveItem(at: backupURL, to: targetURL)
                        throw error
                    }
                    return
                }
            }
            try fm.moveItem(at: stagedDirectoryURL, to: targetURL)
        }

        if LibraryBrowserManager.isCloudStorageURL(destinationURL) {
            var coordError: NSError?
            var innerError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: destinationURL, options: .forReplacing, error: &coordError) { coordinatedURL in
                do {
                    try performReplace(at: coordinatedURL)
                } catch {
                    innerError = error
                }
            }
            if let coordErr = coordError { throw coordErr }
            if let inner = innerError { throw inner }
        } else {
            try performReplace(at: destinationURL)
        }
    }

    /// Writes `data` to an out-of-folder `itemReplacementDirectory` staging file and commits it
    /// into `destinationURL` using `coordinatedReplaceFile`.
    public func coordinatedWriteData(_ data: Data, to destinationURL: URL) throws {
        let fm = FileManager.default
        let stagingDir = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
        defer { try? fm.removeItem(at: stagingDir) }

        let stagedURL = stagingDir.appendingPathComponent(destinationURL.lastPathComponent)
        try data.write(to: stagedURL, options: .atomic)
        Self.stripCloudExtendedAttributes(at: stagedURL)
        try coordinatedReplaceFile(stagedFileURL: stagedURL, destinationURL: destinationURL)
    }

    public static func encodeSongPeaksSidecar(_ peaksByTrackId: [UUID: [Float]]) -> Data {
        let nonEmpty = peaksByTrackId
            .filter { !$0.value.isEmpty }
            .sorted { $0.key.uuidString < $1.key.uuidString }

        var data = Data()
        data.append(contentsOf: [0x50, 0x42, 0x50, 0x4B]) // "PBPK"

        func appendUInt32LE(_ val: UInt32) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendUInt32LE(1) // sidecar format version 1
        appendUInt32LE(UInt32(nonEmpty.count))

        for (trackId, peaks) in nonEmpty {
            var uuidBytes = trackId.uuid
            withUnsafeBytes(of: &uuidBytes) { data.append(contentsOf: $0) }
            appendUInt32LE(UInt32(peaks.count))
            for sample in peaks {
                appendUInt32LE(sample.bitPattern)
            }
        }
        return data
    }

    public static func decodeSongPeaksSidecar(_ data: Data) -> [UUID: [Float]] {
        guard data.count >= 12 else { return [:] }
        let base = data.startIndex
        guard data[base] == 0x50,
              data[base + 1] == 0x42,
              data[base + 2] == 0x50,
              data[base + 3] == 0x4B else {
            return [:]
        }

        let version = readUInt32LE(data, at: 4)
        guard version == 1 else { return [:] }
        let entryCount = Int(min(readUInt32LE(data, at: 8), 10_000))

        var result: [UUID: [Float]] = [:]
        result.reserveCapacity(entryCount)
        var cursor = 12

        for _ in 0..<entryCount {
            guard cursor + 20 <= data.count else { break }
            var rawUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            _ = withUnsafeMutableBytes(of: &rawUUID) { dst in
                data.copyBytes(to: dst, from: (base + cursor)..<(base + cursor + 16))
            }
            let trackId = UUID(uuid: rawUUID)
            let floatCount = Int(readUInt32LE(data, at: cursor + 16))
            cursor += 20

            guard floatCount >= 0, floatCount <= 1_000_000 else { break }
            let byteCount = floatCount * MemoryLayout<UInt32>.size
            guard cursor + byteCount <= data.count else { break }

            var peaks = [Float]()
            peaks.reserveCapacity(floatCount)
            for i in 0..<floatCount {
                let bits = readUInt32LE(data, at: cursor + i * 4)
                peaks.append(Float(bitPattern: bits))
            }
            cursor += byteCount
            if !peaks.isEmpty {
                result[trackId] = peaks
            }
        }
        return result
    }

    public static func sessionSongFolderName(for songId: UUID, usedNames: inout Set<String>, fallbackIndex: Int) -> String {
        let primary = songId.uuidString
        if !usedNames.contains(primary) {
            usedNames.insert(primary)
            return primary
        }
        let disambiguated = "\(primary)_\(fallbackIndex)"
        usedNames.insert(disambiguated)
        return disambiguated
    }

    public static func resolveSessionSongDirectory(rootFolder: URL, songId: UUID, fallbackIndex: Int) -> URL {
        let fm = FileManager.default
        let uuidDir = rootFolder.appendingPathComponent("songs/\(songId.uuidString)", isDirectory: true)
        if fm.fileExists(atPath: uuidDir.path) {
            return uuidDir
        }
        let disambigDir = rootFolder.appendingPathComponent("songs/\(songId.uuidString)_\(fallbackIndex)", isDirectory: true)
        if fm.fileExists(atPath: disambigDir.path) {
            return disambigDir
        }
        return rootFolder.appendingPathComponent("songs/song_\(fallbackIndex)", isDirectory: true)
    }

    private func writePeaksSidecarIfNeeded(_ peaksByTrackId: [UUID: [Float]], to peaksURL: URL) {
        let nonEmpty = peaksByTrackId.filter { !$0.value.isEmpty }
        let fm = FileManager.default
        if nonEmpty.isEmpty {
            if fm.fileExists(atPath: peaksURL.path) {
                try? fm.removeItem(at: peaksURL)
            }
            return
        }
        let newData = Self.encodeSongPeaksSidecar(nonEmpty)
        if fm.fileExists(atPath: peaksURL.path),
           let existing = try? Data(contentsOf: peaksURL),
           existing == newData {
            return
        }
        do {
            try coordinatedWriteData(newData, to: peaksURL)
        } catch {
            PeanutButterLog.storage.error("Failed writing peaks.bin at \(peaksURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadPeaksSidecarMap(from directoryURL: URL, triggerDownload: Bool = false) -> [UUID: [Float]] {
        let fm = FileManager.default
        let peaksURL = directoryURL.appendingPathComponent("peaks.bin")
        let placeholderURL = directoryURL.appendingPathComponent(".peaks.bin.icloud")
        guard fm.fileExists(atPath: peaksURL.path) || fm.fileExists(atPath: placeholderURL.path) else {
            return [:]
        }
        if !LibraryBrowserManager.checkIsDownloaded(at: peaksURL) {
            if triggerDownload {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: peaksURL, timeout: 10.0)
            } else {
                LibraryBrowserManager.triggerCloudDownload(at: peaksURL)
                return [:]
            }
        }
        guard let data = try? Data(contentsOf: peaksURL) else { return [:] }
        return Self.decodeSongPeaksSidecar(data)
    }

    /// Zero-copy APFS hardlink for purely local files, or data-only copy (staged outside synced
    /// cloud folders via `itemReplacementDirectory` and committed with `NSFileCoordinator` +
    /// `replaceItemAt`) whenever either endpoint touches Cloud Storage or carries cloud xattrs.
    public func linkOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL { return }

        let srcIsCloud = LibraryBrowserManager.isCloudStorageURL(sourceURL)
        let dstIsCloud = LibraryBrowserManager.isCloudStorageURL(destinationURL)

        if srcIsCloud && !LibraryBrowserManager.checkIsDownloaded(at: sourceURL) {
            LibraryBrowserManager.ensureCloudItemDownloaded(at: sourceURL, timeout: 120.0)
        }

        let destParent = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destParent, withIntermediateDirectories: true)

        let stagingDir = try Self.allocateReplacementStagingDirectory(appropriateFor: destParent)
        defer { try? fm.removeItem(at: stagingDir) }
        let stagedURL = stagingDir.appendingPathComponent(destinationURL.lastPathComponent)

        if srcIsCloud || dstIsCloud || Self.hasCloudExtendedAttributes(at: sourceURL) {
            let rc = Darwin.copyfile(sourceURL.path, stagedURL.path, nil, copyfile_flags_t(COPYFILE_DATA))
            if rc != 0 {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: stagedURL, options: .atomic)
            }
            Self.stripCloudExtendedAttributes(at: stagedURL)
            try coordinatedReplaceFile(stagedFileURL: stagedURL, destinationURL: destinationURL)
            return
        }

        do {
            try fm.linkItem(at: sourceURL, to: stagedURL)
        } catch {
            let rc = Darwin.copyfile(sourceURL.path, stagedURL.path, nil, copyfile_flags_t(COPYFILE_DATA))
            if rc != 0 {
                try fm.copyItem(at: sourceURL, to: stagedURL)
                Self.stripCloudExtendedAttributes(at: stagedURL)
            }
        }
        try coordinatedReplaceFile(stagedFileURL: stagedURL, destinationURL: destinationURL)
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
        buffers: [UUID: AVAudioPCMBuffer],
        overwrite: Bool = false
    ) {
        let tempoChanged = (bpm != nil && originalBPM != nil && abs(bpm! - originalBPM!) > 0.005)
        guard semitones != 0 || tempoChanged else { return }
        let validBuffers = buffers.filter { $0.value.frameLength > 100 }
        guard !validBuffers.isEmpty else { return }
        let dir = transposedStemCacheDirectory(
            songId: songId,
            semitones: semitones,
            preserveVocalFormants: preserveVocalFormants,
            bpm: bpm,
            originalBPM: originalBPM
        )
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            for (trackId, buf) in validBuffers {
                let targetURL = dir.appendingPathComponent("\(trackId.uuidString).wav")
                if !overwrite && fm.fileExists(atPath: targetURL.path) {
                    let existingSize = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? Int64) ?? 0
                    if existingSize > 8192 {
                        continue
                    }
                }
                let tmp = dir.appendingPathComponent("tmp_\(UUID().uuidString).wav")
                defer { try? fm.removeItem(at: tmp) }
                do {
                    try self.writeWAVBuffer(buf, to: tmp)
                    if fm.fileExists(atPath: targetURL.path) {
                        try? fm.removeItem(at: targetURL)
                    }
                    try fm.moveItem(at: tmp, to: targetURL)
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
            guard let raw = try? self.readPCMBuffer(from: fileURL), raw.frameLength > 100 else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
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
                try? fm.createDirectory(at: stemCacheDirectory, withIntermediateDirectories: true)
                try? linkOrCopyFile(from: origURL, to: cacheURL)
                try linkOrCopyFile(from: origURL, to: destinationStemURL)
                return
            }
        }
        
        // 3. Encode from RAM buffer into the target staging directory, then populate StemCache best-effort
        if let buf = buffer, buf.frameLength > 100 {
            let destDir = destinationStemURL.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let tmpDestURL = destDir.appendingPathComponent(".enc_\(UUID().uuidString).m4a")
            defer { try? fm.removeItem(at: tmpDestURL) }
            try writeCompressedStem(buf, to: tmpDestURL)
            try linkOrCopyFile(from: tmpDestURL, to: destinationStemURL)
            if !hasValidCachedStem(for: track.id) {
                try? fm.createDirectory(at: stemCacheDirectory, withIntermediateDirectories: true)
                try? linkOrCopyFile(from: destinationStemURL, to: cacheURL)
            }
            return
        }
        
        // 4. Fallback: read from original non-M4A fileURL or sourceFileURL, encode to M4A in target staging directory
        for origURL in candidateFileURLs {
            if LibraryBrowserManager.isCloudStorageURL(origURL) && !LibraryBrowserManager.checkIsDownloaded(at: origURL) {
                LibraryBrowserManager.ensureCloudItemDownloaded(at: origURL, timeout: 120.0)
            }
            guard fm.fileExists(atPath: origURL.path) else { continue }
            if let fileBuf = try? readPCMBuffer(from: origURL), fileBuf.frameLength > 10 {
                let destDir = destinationStemURL.deletingLastPathComponent()
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                let tmpDestURL = destDir.appendingPathComponent(".enc_\(UUID().uuidString).m4a")
                defer { try? fm.removeItem(at: tmpDestURL) }
                try writeCompressedStem(fileBuf, to: tmpDestURL)
                try linkOrCopyFile(from: tmpDestURL, to: destinationStemURL)
                if !hasValidCachedStem(for: track.id) {
                    try? fm.createDirectory(at: stemCacheDirectory, withIntermediateDirectories: true)
                    try? linkOrCopyFile(from: destinationStemURL, to: cacheURL)
                }
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
                } else if let existByName = byName[tm.name.lowercased()],
                          let altStaged = Self.containedFileURL(baseDirectory: stagingDir, relativePath: existByName) {
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
        guard let manifestData = try? JSONEncoder().encode(manifest) else { return }
        try? manifestData.write(to: stagingDir.appendingPathComponent("tracks.json"), options: .atomic)

        let replacementDir = try? Self.allocateReplacementStagingDirectory(appropriateFor: cloudStemsDir)
        defer {
            if let dir = replacementDir {
                try? fm.removeItem(at: dir)
            }
        }
        let tempZip = (replacementDir ?? fm.temporaryDirectory)
            .appendingPathComponent("pbstems_out_\(UUID().uuidString).pbstems")
        defer { try? fm.removeItem(at: tempZip) }

        let process = Process()
        process.currentDirectoryURL = stagingDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-0", "-r", "-q", tempZip.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, fm.fileExists(atPath: tempZip.path) else { return }

        // Commit `.pbstems` pack FIRST via coordinated atomic replacement, then commit `.tracks.json` sidecar.
        do {
            try coordinatedReplaceFile(stagedFileURL: tempZip, destinationURL: packURL)
            try coordinatedWriteData(manifestData, to: sidecarURL)
            if fm.fileExists(atPath: looseDir.path) {
                try? fm.removeItem(at: looseDir)
            }
        } catch {
            PeanutButterLog.storage.error("Failed to commit coordinated cloud stem pack \(packURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                                    if let matchedFileName = manifest.byId[tm.id.uuidString] ?? manifest.byName[tm.name.lowercased()],
                                       let srcFile = Self.containedFileURL(baseDirectory: unpackDir, relativePath: matchedFileName) {
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
            if let configured = LibraryBrowserManager.cloudStemsDirectoryURL,
               let containedConfigured = Self.containedFileURL(baseDirectory: configured, relativePath: subPath) {
                candidates.append(containedConfigured)
            }
            // Also resolve relative to `<CloudRoot>/{Songs|Setlists}/Package` -> `<CloudRoot>/Stems`
            let inferredStemsRoot = rootFolder
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Stems", isDirectory: true)
            if let inferredStems = Self.containedFileURL(baseDirectory: inferredStemsRoot, relativePath: subPath),
               !candidates.contains(where: { $0.standardizedFileURL == inferredStems.standardizedFileURL }) {
                candidates.append(inferredStems)
            }
            guard !candidates.isEmpty else { return nil }

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
            if let targetFileName = subPath.split(separator: "/").last.map(String.init),
               !targetFileName.isEmpty && targetFileName != "." && targetFileName != ".." {
                let stemsRoots = [LibraryBrowserManager.cloudStemsDirectoryURL, inferredStemsRoot].compactMap { $0 }
                for stemsRoot in stemsRoots {
                    guard let songDirs = try? fm.contentsOfDirectory(at: stemsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                    for sDir in songDirs {
                        if let altCandidate = Self.containedFileURL(baseDirectory: sDir, relativePath: targetFileName),
                           fm.fileExists(atPath: altCandidate.path) {
                            if !LibraryBrowserManager.checkIsDownloaded(at: altCandidate) {
                                LibraryBrowserManager.ensureCloudItemDownloaded(at: altCandidate, timeout: 90.0)
                            }
                            return altCandidate
                        }
                    }
                }
            }

            return candidates.first
        }

        guard let localURL = Self.containedFileURL(baseDirectory: rootFolder, relativePath: relativePath) else {
            return nil
        }
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
            try? coordinatedWriteData(newData, to: artURL)
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

        let stagingRoot = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
        let stagingDir = stagingRoot.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            if fm.fileExists(atPath: stagingRoot.path) {
                try? fm.removeItem(at: stagingRoot)
            }
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        if isSong {
            let srcJSON = rootFolder.appendingPathComponent("song.json")
            var meta = try decoder.decode(SongPackageMetadata.self, from: try Data(contentsOf: srcJSON))
            _ = unpackCloudStemPackIfNeeded(for: meta, rootFolder: rootFolder)
            let srcPeaks = loadPeaksSidecarMap(from: rootFolder, triggerDownload: true)
            let srcArt = rootFolder.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: srcArt.path) {
                try? fm.copyItem(at: srcArt, to: stagingDir.appendingPathComponent("artwork.png"))
            }
            let stemsDir = stagingDir.appendingPathComponent("stems", isDirectory: true)
            if cloudStemsDir == nil {
                try fm.createDirectory(at: stemsDir, withIntermediateDirectories: true)
            }

            var updatedTracks: [TrackFileMetadata] = []
            var copiedPeaksByTrackId: [UUID: [Float]] = [:]
            for var tm in meta.tracks {
                let existingTrackPeaks = srcPeaks[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                if !existingTrackPeaks.isEmpty {
                    copiedPeaksByTrackId[tm.id] = existingTrackPeaks
                }
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
                            duration: tm.duration, waveformPeaksData: nil,
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
                            duration: tm.duration, waveformPeaksData: nil,
                            relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                            sourceFilePath: tm.sourceFilePath
                        )
                    }
                } else {
                    tm.waveformPeaksData = nil
                }
                updatedTracks.append(tm)
            }

            meta.tracks = updatedTracks
            writePeaksSidecarIfNeeded(copiedPeaksByTrackId, to: stagingDir.appendingPathComponent("peaks.bin"))
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
            var usedDestSongFolders = Set<String>()
            for (songIndex, songEntry) in meta.songEntries.enumerated() {
                _ = unpackCloudStemPackIfNeeded(for: songEntry, rootFolder: rootFolder)
                let destFolderName = Self.sessionSongFolderName(for: songEntry.id, usedNames: &usedDestSongFolders, fallbackIndex: songIndex)
                let songSubDir = songsDir.appendingPathComponent(destFolderName, isDirectory: true)
                try fm.createDirectory(at: songSubDir, withIntermediateDirectories: true)
                let srcSongDir = Self.resolveSessionSongDirectory(rootFolder: rootFolder, songId: songEntry.id, fallbackIndex: songIndex)
                let srcArt = srcSongDir.appendingPathComponent("artwork.png")
                if fm.fileExists(atPath: srcArt.path) {
                    try? fm.copyItem(at: srcArt, to: songSubDir.appendingPathComponent("artwork.png"))
                }
                let srcPeaks = loadPeaksSidecarMap(from: srcSongDir, triggerDownload: true)
                let stemsSubDir = songSubDir.appendingPathComponent("stems", isDirectory: true)
                if cloudStemsDir == nil {
                    try fm.createDirectory(at: stemsSubDir, withIntermediateDirectories: true)
                }

                var updatedTracks: [TrackFileMetadata] = []
                var copiedPeaksByTrackId: [UUID: [Float]] = [:]
                for tm in songEntry.tracks {
                    let existingTrackPeaks = srcPeaks[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                    if !existingTrackPeaks.isEmpty {
                        copiedPeaksByTrackId[tm.id] = existingTrackPeaks
                    }
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
                                duration: tm.duration, waveformPeaksData: nil,
                                relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                                sourceFilePath: tm.sourceFilePath
                            ))
                        } else {
                            let filename = srcAudio.lastPathComponent
                            let dstStem = stemsSubDir.appendingPathComponent(filename)
                            try linkOrCopyFile(from: srcAudio, to: dstStem)
                            updatedTracks.append(TrackFileMetadata(
                                id: tm.id, name: tm.name, role: tm.role,
                                relativeAudioPath: "songs/\(destFolderName)/stems/\(filename)",
                                volume: tm.volume, pan: tm.pan, isMuted: tm.isMuted, isSoloed: tm.isSoloed, isSoloSafe: tm.isSoloSafe,
                                routing: tm.routing, assignedBusName: tm.assignedBusName, includeInWaveform: tm.includeInWaveform,
                                duration: tm.duration, waveformPeaksData: nil,
                                relativeTransposedAudioPath: nil, transposedSemitones: tm.transposedSemitones,
                                sourceFilePath: tm.sourceFilePath
                            ))
                        }
                    } else {
                        var strippedTrack = tm
                        strippedTrack.waveformPeaksData = nil
                        updatedTracks.append(strippedTrack)
                    }
                }

                writePeaksSidecarIfNeeded(copiedPeaksByTrackId, to: songSubDir.appendingPathComponent("peaks.bin"))
                var updatedEntry = songEntry
                updatedEntry.tracks = updatedTracks
                updatedEntries.append(updatedEntry)
                if let csDir = cloudStemsDir {
                    writeCloudStemPack(cloudStemsDir: csDir, songId: songEntry.id, tracks: updatedTracks)
                }
            }

            meta.associatedSessionPath = nil
            if isCloudDest {
                if meta.lastSavedRevisionId == nil {
                    meta.lastSavedRevisionId = UUID()
                }
                meta.lastSavedByDeviceId = Self.currentDeviceInstanceId
            }
            meta.songEntries = updatedEntries
            try encoder.encode(meta).write(to: stagingDir.appendingPathComponent("session.json"), options: .atomic)
        }

        try coordinatedReplaceDirectory(stagedDirectoryURL: stagingDir, destinationURL: destinationURL)
        if !isSong {
            LibraryBrowserManager.invalidateSetlistPackageCache(for: destinationURL)
        }
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

        let stagingRoot: URL?
        let tempDir: URL
        let targetRoot: URL
        if canUpdateInPlace {
            stagingRoot = nil
            tempDir = destinationURL
            targetRoot = destinationURL
        } else if asDirectoryPackage {
            let allocRoot = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
            let dir = allocRoot.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingRoot = allocRoot
            tempDir = dir
            targetRoot = dir
        } else {
            let dir = fileManager.temporaryDirectory.appendingPathComponent("pbsong_export_\(UUID().uuidString)")
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingRoot = dir
            tempDir = dir
            targetRoot = dir
        }
        
        defer {
            if let root = stagingRoot, fileManager.fileExists(atPath: root.path) {
                try? fileManager.removeItem(at: root)
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
        
        let stemSongId = song.sourceSongId ?? song.id

        // Safe-Save Guard: Read existing song.json and peaks.bin (if updating an existing package)
        // so an unhydrated track in RAM never overwrites valid metadata or peaks.
        var existingRelPathById: [UUID: String] = [:]
        var existingRelPathByName: [String: String] = [:]
        var existingPeaksById: [UUID: [Float]] = loadPeaksSidecarMap(from: destinationURL, triggerDownload: false)
        let existingSongJSONURL = destinationURL.appendingPathComponent("song.json")
        if let oldData = try? Data(contentsOf: existingSongJSONURL),
           let oldMeta = try? JSONDecoder().decode(SongPackageMetadata.self, from: oldData) {
            for ot in oldMeta.tracks {
                if !ot.relativeAudioPath.isEmpty {
                    existingRelPathById[ot.id] = ot.relativeAudioPath
                    existingRelPathByName[ot.name.lowercased()] = ot.relativeAudioPath
                }
                if existingPeaksById[ot.id] == nil {
                    let legacyPeaks = TrackFileMetadata.decodePeaks(ot.waveformPeaksData)
                    if !legacyPeaks.isEmpty {
                        existingPeaksById[ot.id] = legacyPeaks
                    }
                }
            }
        }

        let peaksBox = UnsafeMutableBufferPointer<[Float]?>.allocate(capacity: max(1, tracks.count))
        peaksBox.initialize(repeating: nil)
        defer {
            peaksBox.deinitialize()
            peaksBox.deallocate()
        }
        
        let exportErrorLock = NSLock()
        var firstExportError: Error? = nil
        func recordExportError(_ error: Error) {
            exportErrorLock.lock()
            if firstExportError == nil { firstExportError = error }
            exportErrorLock.unlock()
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
            let isUnhydratedPlaceholder = (buffers[track.id]?.frameLength ?? 0) <= 100
            
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
                        if isUnhydratedPlaceholder,
                           let preserved = existingRelPathById[track.id] ?? existingRelPathByName[track.name.lowercased()],
                           !preserved.isEmpty {
                            relativePath = preserved
                        } else {
                            recordExportError(error)
                        }
                        PeanutButterLog.storage.error("Failed to write cloud stem \(track.name, privacy: .public) (preserved \(relativePath, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    let stemURL = stemsDir.appendingPathComponent(stemFileName)
                    do {
                        if !canUpdateInPlace || !self.hasValidStemFile(at: stemURL) {
                            try self.writeOrLinkStem(track: track, buffer: buffers[track.id], to: stemURL)
                        }
                        relativePath = "stems/\(stemFileName)"
                    } catch {
                        if canUpdateInPlace,
                           isUnhydratedPlaceholder,
                           let preserved = existingRelPathById[track.id] ?? existingRelPathByName[track.name.lowercased()],
                           let oldLocal = Self.containedFileURL(baseDirectory: destinationURL, relativePath: preserved),
                           fileManager.fileExists(atPath: oldLocal.path) {
                            relativePath = preserved
                        } else {
                            recordExportError(error)
                        }
                        PeanutButterLog.storage.error("Failed to write stem \(track.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            
            let relTransPath: String? = nil
            
            var peaks = track.waveformPeaks
            if peaks.isEmpty, let preservedPeaks = existingPeaksById[track.id] {
                peaks = preservedPeaks
            } else if peaks.isEmpty && track.includeInWaveform, let buf = buffers[track.id], buf.frameLength > 100 {
                peaks = Self.extractPeaks(from: buf, samplesCount: 4000)
            }
            if !peaks.isEmpty {
                peaksBox[idx] = peaks
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
                waveformPeaksData: nil,
                relativeTransposedAudioPath: relTransPath,
                transposedSemitones: (relTransPath != nil) ? song.transposeSemitones : nil,
                sourceFilePath: (track.sourceFileURL ?? track.fileURL)?.path
            )
        }
        
        let trackEntries = (0..<tracks.count).compactMap { metaBox[$0] }
        if let err = firstExportError {
            throw err
        }
        var peaksByTrackId: [UUID: [Float]] = [:]
        for idx in 0..<tracks.count {
            if let p = peaksBox[idx], !p.isEmpty {
                peaksByTrackId[tracks[idx].id] = p
            }
        }
        
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
        writePeaksSidecarIfNeeded(peaksByTrackId, to: targetRoot.appendingPathComponent("peaks.bin"))
        
        let songMeta = makeSongPackageMetadata(song: song, tracks: trackEntries, embedArtworkInJSON: false)
        
        let encoder = JSONEncoder()
        let metaData = try encoder.encode(songMeta)
        try coordinatedWriteData(metaData, to: targetRoot.appendingPathComponent("song.json"))
        recordLocalLosslessSources(tracks.map { ($0.id, $0.sourceFileURL ?? $0.fileURL) })
        
        if !canUpdateInPlace {
            if asDirectoryPackage {
                try coordinatedReplaceDirectory(stagedDirectoryURL: tempDir, destinationURL: destinationURL)
            } else {
                let archiveStageDir = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
                defer { try? fileManager.removeItem(at: archiveStageDir) }
                let stagedZip = archiveStageDir.appendingPathComponent(destinationURL.lastPathComponent)
                try zipFolder(folderURL: tempDir, toArchiveURL: stagedZip)
                try coordinatedReplaceFile(stagedFileURL: stagedZip, destinationURL: destinationURL)
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
        
        let sidecarPeaks = loadPeaksSidecarMap(from: folderURL, triggerDownload: true)
        return decodeSongEntry(
            songEntry: songMeta,
            rootFolder: folderURL,
            artworkOverride: loadedArtwork,
            canonicalFormat: canonicalFormat,
            preloadedPeaksByTrackId: sidecarPeaks
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
            do {
                try unzipSelectedEntries(
                    archiveURL: sourceURL,
                    entryPatterns: ["song.json", "artwork.png", "peaks.bin"],
                    toFolderURL: tempDir,
                    requiredRelativeFile: "song.json"
                )
            } catch {
                try? fm.removeItem(at: tempDir)
                throw NSError(domain: "PlaybackFileManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Corrupted song package: missing song.json (\(error.localizedDescription))"])
            }

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

        let sidecarPeaks = loadPeaksSidecarMap(from: rootFolder, triggerDownload: true)

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
                sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) }
                    ?? self.lookupLocalLosslessSourceURL(for: tm.id)
                    ?? resolvedURL,
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
            stemTrack.waveformPeaks = sidecarPeaks[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
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
        changeDescription: String? = nil,
        revisionId: UUID? = nil,
        authorDeviceId: String? = nil
    ) throws {
        let fileManager = FileManager.default
        let isCloudDest = LibraryBrowserManager.isURLInCloudLibrary(destinationURL)
        let cloudStemsDir = isCloudDest ? LibraryBrowserManager.cloudStemsDirectoryURL : nil

        var existingIsDir: ObjCBool = false
        let canUpdateInPlace = asDirectoryPackage &&
            fileManager.fileExists(atPath: destinationURL.path, isDirectory: &existingIsDir) &&
            existingIsDir.boolValue

        let stagingRoot: URL?
        let stagingDir: URL
        let targetRoot: URL
        if canUpdateInPlace {
            stagingRoot = nil
            stagingDir = destinationURL
            targetRoot = destinationURL
        } else if asDirectoryPackage {
            let allocRoot = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
            let dir = allocRoot.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingRoot = allocRoot
            stagingDir = dir
            targetRoot = dir
        } else {
            let dir = fileManager.temporaryDirectory.appendingPathComponent("pbsession_export_\(UUID().uuidString)")
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingRoot = dir
            stagingDir = dir
            targetRoot = dir
        }
        
        defer {
            if let root = stagingRoot, fileManager.fileExists(atPath: root.path) {
                try? fileManager.removeItem(at: root)
            }
        }
        
        let songsDir = targetRoot.appendingPathComponent("songs")
        try fileManager.createDirectory(at: songsDir, withIntermediateDirectories: true)

        // Safe-Save Guard: Read existing session.json and peaks (if updating an existing session)
        // so unhydrated tracks in RAM never lose previously valid `relativeAudioPath` or `peaks.bin` entries.
        var existingRelPathByTrackId: [UUID: String] = [:]
        var existingRelPathBySongAndName: [String: String] = [:]
        var existingPeaksByTrackId: [UUID: [Float]] = [:]
        let existingSessionJSONURL = destinationURL.appendingPathComponent("session.json")
        if let oldData = try? Data(contentsOf: existingSessionJSONURL),
           let oldSession = try? JSONDecoder().decode(SessionPackageMetadata.self, from: oldData) {
            for (oldIdx, oldSong) in oldSession.songEntries.enumerated() {
                if canUpdateInPlace {
                    let oldSongDir = Self.resolveSessionSongDirectory(rootFolder: destinationURL, songId: oldSong.id, fallbackIndex: oldIdx)
                    let oldSidecarPeaks = loadPeaksSidecarMap(from: oldSongDir, triggerDownload: false)
                    for (tid, p) in oldSidecarPeaks where !p.isEmpty {
                        existingPeaksByTrackId[tid] = p
                    }
                }
                for ot in oldSong.tracks {
                    if !ot.relativeAudioPath.isEmpty {
                        existingRelPathByTrackId[ot.id] = ot.relativeAudioPath
                        existingRelPathBySongAndName["\(oldSong.id.uuidString)::\(ot.name.lowercased())"] = ot.relativeAudioPath
                    }
                    if existingPeaksByTrackId[ot.id] == nil {
                        let legacyPeaks = TrackFileMetadata.decodePeaks(ot.waveformPeaksData)
                        if !legacyPeaks.isEmpty {
                            existingPeaksByTrackId[ot.id] = legacyPeaks
                        }
                    }
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
            let primaryJobIndex: Int?
            let relativeTransposedPath: String?
            let transposedURL: URL?
        }
        
        var jobs: [StemExportJob] = []
        var songTrackCounts: [Int] = []
        var songFolderNames: [String] = []
        var songSubDirs: [URL] = []
        var usedSongFolders = Set<String>()
        var seenBufferPrimaryJobIndex: [ObjectIdentifier: Int] = [:]
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
            let songFolderName = Self.sessionSongFolderName(for: songData.song.id, usedNames: &usedSongFolders, fallbackIndex: songIndex)
            let songSubDir = songsDir.appendingPathComponent(songFolderName)
            let stemsSubDir = songSubDir.appendingPathComponent("stems")
            try fileManager.createDirectory(at: songSubDir, withIntermediateDirectories: true)
            if cloudStemsDir == nil {
                try fileManager.createDirectory(at: stemsSubDir, withIntermediateDirectories: true)
            }
            songFolderNames.append(songFolderName)
            songSubDirs.append(songSubDir)
            
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
                    relativePath = "songs/\(songFolderName)/stems/\(stemFileName)"
                }

                let cat = StemCategory.category(for: track.name, role: track.role)
                let isGeneratedClick = (track.role == .click || cat == .click) && songData.song.clickSource == .generated
                let isGeneratedGuide = (track.role == .guide || cat == .guide) && songData.song.guideSource == .generated
                let hasBackingAudio = self.hasValidCachedStem(for: track.id)
                    || (track.fileURL != nil && fileManager.fileExists(atPath: track.fileURL!.path))
                    || (track.sourceFileURL != nil && fileManager.fileExists(atPath: track.sourceFileURL!.path))
                let shouldSkipAudioExport = (isGeneratedClick || isGeneratedGuide) && !hasBackingAudio
                let buf = songData.buffers[track.id]
                let currentJobIndex = jobs.count
                var primaryJobIdx: Int? = nil
                // Deduplicate encoding of identical in-RAM buffers for local embedded packages when buffer is hydrated (> 100 frames)
                if !shouldSkipAudioExport, cloudStemsDir == nil, let b = buf, b.frameLength > 100 {
                    let bufKey = ObjectIdentifier(b)
                    if let existingJobIdx = seenBufferPrimaryJobIndex[bufKey] {
                        primaryJobIdx = existingJobIdx
                    } else {
                        seenBufferPrimaryJobIndex[bufKey] = currentJobIndex
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
                        primaryJobIndex: primaryJobIdx,
                        relativeTransposedPath: relTransPath,
                        transposedURL: transURL
                    )
                )
            }
        }
        
        let resultsBox = UnsafeMutableBufferPointer<TrackFileMetadata?>.allocate(capacity: max(1, jobs.count))
        resultsBox.initialize(repeating: nil)
        let peaksBox = UnsafeMutableBufferPointer<[Float]?>.allocate(capacity: max(1, jobs.count))
        peaksBox.initialize(repeating: nil)
        defer {
            resultsBox.deinitialize()
            resultsBox.deallocate()
            peaksBox.deinitialize()
            peaksBox.deallocate()
        }
        
        let sessionErrorLock = NSLock()
        var firstSessionExportError: Error? = nil
        func recordSessionExportError(_ error: Error) {
            sessionErrorLock.lock()
            if firstSessionExportError == nil { firstSessionExportError = error }
            sessionErrorLock.unlock()
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
                let isUnhydratedPlaceholder = (job.buffer?.frameLength ?? 0) <= 100
                
                var relPath = ""
                if !shouldSkipAudioExport {
                    if job.primaryJobIndex != nil {
                        // Link after parallel encoding of primary jobs completes so every song owns its own stem file/hardlink.
                        relPath = job.relativePath
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
                                if canUpdateInPlace,
                                   cloudStemsDir == nil,
                                   !self.hasValidCachedStem(for: track.id),
                                   track.fileURL == nil,
                                   let oldRel = existingRelPathByTrackId[track.id] ?? existingRelPathBySongAndName["\(song.id.uuidString)::\(track.name.lowercased())"],
                                   let oldLocalFile = Self.containedFileURL(baseDirectory: destinationURL, relativePath: oldRel),
                                   fileManager.fileExists(atPath: oldLocalFile.path) {
                                    try self.linkOrCopyFile(from: oldLocalFile, to: job.stemURL)
                                } else {
                                    try self.writeOrLinkStem(track: track, buffer: job.buffer, to: job.stemURL)
                                }
                            }
                            relPath = job.relativePath
                        } catch {
                            let stemSongId = song.sourceSongId ?? song.id
                            let preserved = existingRelPathByTrackId[track.id]
                                ?? existingRelPathBySongAndName["\(song.id.uuidString)::\(track.name.lowercased())"]
                                ?? existingRelPathBySongAndName["\(stemSongId.uuidString)::\(track.name.lowercased())"]
                            if cloudStemsDir != nil {
                                if isUnhydratedPlaceholder, let p = preserved, !p.isEmpty {
                                    relPath = p
                                } else {
                                    recordSessionExportError(error)
                                }
                            } else if canUpdateInPlace,
                                      isUnhydratedPlaceholder,
                                      let p = preserved,
                                      let oldLocal = Self.containedFileURL(baseDirectory: destinationURL, relativePath: p),
                                      fileManager.fileExists(atPath: oldLocal.path) {
                                relPath = p
                            } else {
                                recordSessionExportError(error)
                            }
                            PeanutButterLog.storage.error("Failed to export session stem \(track.name, privacy: .public) (preserved \(relPath, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                
                if let transBuf = job.transposedBuffer, let transURL = job.transposedURL {
                    try? self.writeCompressedStem(transBuf, to: transURL)
                }
                
                var peaks = track.waveformPeaks
                var resolvedDuration: TimeInterval? = track.duration > 0 ? track.duration : nil
                if peaks.isEmpty, let preservedPeaks = existingPeaksByTrackId[track.id] {
                    peaks = preservedPeaks
                }
                if peaks.isEmpty && track.includeInWaveform {
                    if let buf = job.buffer, buf.frameLength > 100 {
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
                if !peaks.isEmpty {
                    peaksBox[jobIdx] = peaks
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
                    waveformPeaksData: nil,
                    relativeTransposedAudioPath: job.relativeTransposedPath,
                    transposedSemitones: (job.song.transposeSemitones != 0) ? job.song.transposeSemitones : nil,
                    sourceFilePath: (track.sourceFileURL ?? track.fileURL)?.path
                )
            }
        }

        if let err = firstSessionExportError {
            throw err
        }

        // Link/copy duplicated in-RAM song stems per song directory sequentially after primary writes finish
        // so deleting the original song later never deletes another song's stems via shared paths.
        if cloudStemsDir == nil {
            for jobIdx in jobs.indices {
                guard let primaryIdx = jobs[jobIdx].primaryJobIndex else { continue }
                let job = jobs[jobIdx]
                let primaryURL = jobs[primaryIdx].stemURL
                try fileManager.createDirectory(at: job.stemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !self.isSameFile(primaryURL, job.stemURL) {
                    if fileManager.fileExists(atPath: primaryURL.path) {
                        try self.linkOrCopyFile(from: primaryURL, to: job.stemURL)
                    } else {
                        try self.writeOrLinkStem(track: job.track, buffer: job.buffer, to: job.stemURL)
                    }
                }
                if !self.hasValidCachedStem(for: job.track.id), fileManager.fileExists(atPath: job.stemURL.path) {
                    try? self.linkOrCopyFile(from: job.stemURL, to: self.cachedStemURL(for: job.track.id))
                }
            }
        }
        
        var songPackageEntries: [SongPackageMetadata] = []
        var cursor = 0
        for (songIndex, songData) in allSongsData.enumerated() {
            let count = songTrackCounts[songIndex]
            var trackEntries: [TrackFileMetadata] = []
            trackEntries.reserveCapacity(count)
            var songPeaksByTrackId: [UUID: [Float]] = [:]
            for i in 0..<count {
                if let m = resultsBox[cursor + i] {
                    trackEntries.append(m)
                }
                if let p = peaksBox[cursor + i], !p.isEmpty {
                    songPeaksByTrackId[songData.tracks[i].id] = p
                }
            }
            cursor += count
            writePeaksSidecarIfNeeded(songPeaksByTrackId, to: songSubDirs[songIndex].appendingPathComponent("peaks.bin"))
            let songMeta = makeSongPackageMetadata(song: songData.song, tracks: trackEntries, embedArtworkInJSON: false)
            songPackageEntries.append(songMeta)
            if let csDir = cloudStemsDir {
                let stemSongId = songData.song.sourceSongId ?? songData.song.id
                writeCloudStemPack(cloudStemsDir: csDir, songId: stemSongId, tracks: trackEntries)
            }
        }
        
        let effectiveRevisionId = revisionId ?? UUID()
        let effectiveDeviceId = authorDeviceId ?? Self.currentDeviceInstanceId
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
            lastSavedRevisionId: effectiveRevisionId,
            lastSavedByDeviceId: effectiveDeviceId,
            songEntries: songPackageEntries
        )
        
        let encoder = JSONEncoder()
        let sessionData = try encoder.encode(sessionMeta)
        try coordinatedWriteData(sessionData, to: targetRoot.appendingPathComponent("session.json"))
        let allLosslessPairs: [(UUID, URL?)] = allSongsData.flatMap { songData in
            songData.tracks.map { ($0.id, $0.sourceFileURL ?? $0.fileURL) }
        }
        recordLocalLosslessSources(allLosslessPairs)
        
        if canUpdateInPlace {
            if let existingSubDirs = try? fileManager.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                let validSongFolderNames = Set(songFolderNames)
                var referencedSongFolders = Set<String>()
                for songMeta in songPackageEntries {
                    for trackMeta in songMeta.tracks where trackMeta.relativeAudioPath.hasPrefix("songs/") {
                        let parts = trackMeta.relativeAudioPath.split(separator: "/", omittingEmptySubsequences: true)
                        if parts.count >= 2 {
                            referencedSongFolders.insert(String(parts[1]))
                        }
                    }
                }
                for subDir in existingSubDirs {
                    let name = subDir.lastPathComponent
                    if !validSongFolderNames.contains(name) && !referencedSongFolders.contains(name) {
                        try? fileManager.removeItem(at: subDir)
                    }
                }
            }
            for (songIndex, songMeta) in songPackageEntries.enumerated() {
                let folderName = songFolderNames[songIndex]
                let stemsSubDir = songsDir.appendingPathComponent("\(folderName)/stems")
                if cloudStemsDir != nil {
                    if fileManager.fileExists(atPath: stemsSubDir.path) {
                        try? fileManager.removeItem(at: stemsSubDir)
                    }
                } else if let existingStems = try? fileManager.contentsOfDirectory(at: stemsSubDir, includingPropertiesForKeys: nil) {
                    let validRelPaths = Set(songMeta.tracks.map { $0.relativeAudioPath })
                    for file in existingStems {
                        let rel = "songs/\(folderName)/stems/\(file.lastPathComponent)"
                        if !validRelPaths.contains(rel) {
                            try? fileManager.removeItem(at: file)
                        }
                    }
                }
            }
        } else {
            if asDirectoryPackage {
                try coordinatedReplaceDirectory(stagedDirectoryURL: stagingDir, destinationURL: destinationURL)
            } else {
                let archiveStageDir = try Self.allocateReplacementStagingDirectory(appropriateFor: destinationURL.deletingLastPathComponent())
                defer { try? fileManager.removeItem(at: archiveStageDir) }
                let stagedZip = archiveStageDir.appendingPathComponent(destinationURL.lastPathComponent)
                try zipFolder(folderURL: stagingDir, toArchiveURL: stagedZip)
                try coordinatedReplaceFile(stagedFileURL: stagedZip, destinationURL: destinationURL)
            }
        }
        LibraryBrowserManager.invalidateSetlistPackageCache(for: destinationURL)
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
            let songDir = Self.resolveSessionSongDirectory(rootFolder: rootFolder, songId: songEntry.id, fallbackIndex: songIndex)
            var loadedArtwork = songEntry.artworkData
            if loadedArtwork == nil {
                let artURL = songDir.appendingPathComponent("artwork.png")
                if fileManager.fileExists(atPath: artURL.path) {
                    loadedArtwork = try? Data(contentsOf: artURL)
                }
            }
            let sidecarPeaks = loadPeaksSidecarMap(from: songDir, triggerDownload: true)
            
            let (song, loadedTracks, loadedTransposed) = decodeSongEntry(
                songEntry: songEntry,
                rootFolder: rootFolder,
                artworkOverride: loadedArtwork,
                canonicalFormat: canonicalFormat,
                preloadedPeaksByTrackId: sidecarPeaks
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
        public let lastSavedRevisionId: UUID?
        public let lastSavedByDeviceId: String?
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
            let songDir = Self.resolveSessionSongDirectory(rootFolder: rootFolder, songId: songEntry.id, fallbackIndex: songIndex)
            var loadedArtwork = songEntry.artworkData
            if loadedArtwork == nil {
                let artURL = songDir.appendingPathComponent("artwork.png")
                if fileManager.fileExists(atPath: artURL.path) {
                    if LibraryBrowserManager.checkIsDownloaded(at: artURL) {
                        loadedArtwork = try? Data(contentsOf: artURL)
                    } else {
                        LibraryBrowserManager.triggerCloudDownload(at: artURL)
                    }
                }
            }
            let songSidecarPeaks = loadPeaksSidecarMap(from: songDir, triggerDownload: true)
            
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
                    sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) }
                        ?? self.lookupLocalLosslessSourceURL(for: tm.id),
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
                stemTrack.waveformPeaks = songSidecarPeaks[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
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
                continueClick: songEntry.continueClick,
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
            cleanupFolder: cleanupFolder,
            lastSavedRevisionId: sessionMeta.lastSavedRevisionId,
            lastSavedByDeviceId: sessionMeta.lastSavedByDeviceId
        )
    }

    public func loadSongTrackMetadataFromSession(songId: UUID, sessionURL: URL) -> [TrackFileMetadata]? {
        let jsonURL = sessionURL.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }
        if LibraryBrowserManager.isCloudStorageURL(jsonURL) && !LibraryBrowserManager.checkIsDownloaded(at: jsonURL) {
            return nil
        }
        guard let data = try? Data(contentsOf: jsonURL),
              let sessionMeta = try? JSONDecoder().decode(SessionPackageMetadata.self, from: data),
              let idx = sessionMeta.songEntries.firstIndex(where: { $0.id == songId }) else {
            return nil
        }
        let songEntry = sessionMeta.songEntries[idx]
        let songDir = Self.resolveSessionSongDirectory(rootFolder: sessionURL, songId: songEntry.id, fallbackIndex: idx)
        let sidecarPeaks = loadPeaksSidecarMap(from: songDir, triggerDownload: false)
        guard !sidecarPeaks.isEmpty else {
            return songEntry.tracks
        }
        return songEntry.tracks.map { tm in
            guard tm.waveformPeaksData == nil, let p = sidecarPeaks[tm.id], !p.isEmpty else {
                return tm
            }
            var copy = tm
            copy.waveformPeaksData = TrackFileMetadata.encodePeaks(p)
            return copy
        }
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
        songIndex: Int = 0,
        rootFolder: URL,
        canonicalFormat: AVAudioFormat?,
        localLibraryIndex: [LocalLibrarySongEntry]? = nil,
        isCancelled: (() -> Bool)? = nil,
        progressHandler: ((Int, Int) -> Void)? = nil
    ) -> (tracks: [(StemTrack, AVAudioPCMBuffer)], transposedBuffers: [UUID: AVAudioPCMBuffer]) {
        let songDir = Self.resolveSessionSongDirectory(rootFolder: rootFolder, songId: songEntry.id, fallbackIndex: songIndex)
        let preloadedPeaks = loadPeaksSidecarMap(from: songDir, triggerDownload: false)
        let (_, loadedTracks, loadedTransposed) = decodeSongEntry(
            songEntry: songEntry,
            rootFolder: rootFolder,
            artworkOverride: songEntry.artworkData,
            canonicalFormat: canonicalFormat,
            preloadedPeaksByTrackId: preloadedPeaks,
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
                    guard let stemURL = Self.containedFileURL(baseDirectory: pkgURL, relativePath: lt.relativeAudioPath) else {
                        continue
                    }
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
        preloadedPeaksByTrackId: [UUID: [Float]] = [:],
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
                    stemTrack.waveformPeaks = preloadedPeaksByTrackId[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
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
                       let rawTrans = try? self.readPCMBuffer(from: transAudioURL),
                       rawTrans.frameLength > 100 {
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
                        if fm.fileExists(atPath: diskTransURL.path) {
                            if let rawTrans = try? self.readPCMBuffer(from: diskTransURL), rawTrans.frameLength > 100 {
                                transposedBuffer = canonicalFormat != nil ? Self.normalizeBuffer(rawTrans, to: canonicalFormat!) : rawTrans
                            } else {
                                try? fm.removeItem(at: diskTransURL)
                            }
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
                    sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) }
                        ?? self.lookupLocalLosslessSourceURL(for: tm.id),
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
                
                let cachedPeaks = preloadedPeaksByTrackId[tm.id] ?? TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
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
            continueClick: songEntry.continueClick,
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
            version: 3,
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
            continueClick: song.continueClick,
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
    
    // MARK: - Archive Security & Path Containment

    public static let defaultMaxArchiveUncompressedBytes: UInt64 = 50 * 1024 * 1024 * 1024 // 50 GiB
    public static let defaultMaxArchiveEntries: Int = 25_000

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, at: offset))
        let hi = UInt64(readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }

    private struct ValidatedZipEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let declaredUncompressedSize: UInt64
        let dataOffset: UInt64
        let isDirectory: Bool
    }

    private static func hasZip64ExtraField(in extraData: Data) -> Bool {
        var pos = 0
        while pos + 4 <= extraData.count {
            let headerId = readUInt16LE(extraData, at: pos)
            let dataSize = Int(readUInt16LE(extraData, at: pos + 2))
            let fieldEnd = pos + 4 + dataSize
            guard fieldEnd <= extraData.count else { break }
            if headerId == 0x0001 {
                return true
            }
            pos = fieldEnd
        }
        return false
    }

    private static func parseValidatedZipEntries(
        handle: FileHandle,
        maxUncompressedBytes: UInt64,
        maxEntries: Int,
        verifyContiguousLayoutAndStreams: Bool = false
    ) throws -> [ValidatedZipEntry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else {
            throw ArchiveSecurityError.invalidArchive
        }

        // EOCD + max 64 KiB comment + optional 20B ZIP64 locator + 56B ZIP64 record
        let tailWindow = Int(min(fileSize, UInt64(65_557 + 98)))
        let tailStartOffset = fileSize - UInt64(tailWindow)
        try handle.seek(toOffset: tailStartOffset)
        guard let tail = try handle.read(upToCount: tailWindow), tail.count >= 22 else {
            throw ArchiveSecurityError.invalidArchive
        }

        var foundEocdOffsetInTail: Int?
        var scan = tail.count - 22
        while scan >= 0 {
            if readUInt32LE(tail, at: scan) == 0x06054b50 {
                let commentLen = Int(readUInt16LE(tail, at: scan + 20))
                if scan + 22 + commentLen == tail.count {
                    foundEocdOffsetInTail = scan
                    break
                }
            }
            if scan == 0 { break }
            scan -= 1
        }

        guard let eocdTailOffset = foundEocdOffsetInTail else {
            throw ArchiveSecurityError.invalidArchive
        }

        let eocdAbsOffset = tailStartOffset + UInt64(eocdTailOffset)
        let entryCount16 = readUInt16LE(tail, at: eocdTailOffset + 10)
        let cdSize32 = readUInt32LE(tail, at: eocdTailOffset + 12)
        let cdOffset32 = readUInt32LE(tail, at: eocdTailOffset + 16)

        var cdEntries = UInt64(entryCount16)
        var cdSize = UInt64(cdSize32)
        var cdOffset = UInt64(cdOffset32)
        var preTrailingStructureOffset = eocdAbsOffset

        if entryCount16 == 0xFFFF || cdSize32 == 0xFFFFFFFF || cdOffset32 == 0xFFFFFFFF {
            guard eocdAbsOffset >= 20 else {
                throw ArchiveSecurityError.invalidArchive
            }
            try handle.seek(toOffset: eocdAbsOffset - 20)
            guard let locData = try handle.read(upToCount: 20), locData.count == 20,
                  readUInt32LE(locData, at: 0) == 0x07064b50 else {
                throw ArchiveSecurityError.invalidArchive
            }
            let zip64EocdOffset = readUInt64LE(locData, at: 8)
            guard zip64EocdOffset + 56 <= eocdAbsOffset - 20 else {
                throw ArchiveSecurityError.invalidArchive
            }
            try handle.seek(toOffset: zip64EocdOffset)
            guard let zip64Record = try handle.read(upToCount: 56), zip64Record.count == 56,
                  readUInt32LE(zip64Record, at: 0) == 0x06064b50 else {
                throw ArchiveSecurityError.invalidArchive
            }
            cdEntries = readUInt64LE(zip64Record, at: 32)
            cdSize = readUInt64LE(zip64Record, at: 40)
            cdOffset = readUInt64LE(zip64Record, at: 48)
            preTrailingStructureOffset = zip64EocdOffset
        }

        if cdEntries > UInt64(maxEntries) {
            throw ArchiveSecurityError.tooManyEntries(Int(min(cdEntries, UInt64(Int.max))))
        }
        guard cdOffset <= fileSize, cdSize <= fileSize - cdOffset else {
            throw ArchiveSecurityError.invalidArchive
        }
        guard cdSize <= 512 * 1024 * 1024 else {
            throw ArchiveSecurityError.invalidArchive
        }
        if verifyContiguousLayoutAndStreams {
            guard cdOffset + cdSize == preTrailingStructureOffset else {
                throw ArchiveSecurityError.invalidArchive
            }
        }

        if cdSize == 0 && cdEntries == 0 {
            if verifyContiguousLayoutAndStreams {
                guard cdOffset == 0 else {
                    throw ArchiveSecurityError.invalidArchive
                }
            }
            return []
        }

        try handle.seek(toOffset: cdOffset)
        guard let cdData = try handle.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else {
            throw ArchiveSecurityError.invalidArchive
        }

        var pos = 0
        var entriesSeen = 0
        var totalUncompressedBytes: UInt64 = 0
        var parsedEntries: [ValidatedZipEntry] = []
        parsedEntries.reserveCapacity(Int(min(cdEntries, 4096)))
        var entrySpans: [(start: UInt64, end: UInt64)] = []
        if verifyContiguousLayoutAndStreams {
            entrySpans.reserveCapacity(Int(min(cdEntries, 4096)))
        }

        while pos < cdData.count {
            guard pos + 46 <= cdData.count,
                  readUInt32LE(cdData, at: pos) == 0x02014b50 else {
                throw ArchiveSecurityError.invalidArchive
            }

            let versionMadeBy = readUInt16LE(cdData, at: pos + 4)
            let gpFlags = readUInt16LE(cdData, at: pos + 8)
            let method = readUInt16LE(cdData, at: pos + 10)
            let cdCRC32 = readUInt32LE(cdData, at: pos + 16)
            let compressedSize32 = readUInt32LE(cdData, at: pos + 20)
            let uncompressedSize32 = readUInt32LE(cdData, at: pos + 24)
            let nameLen = Int(readUInt16LE(cdData, at: pos + 28))
            let extraLen = Int(readUInt16LE(cdData, at: pos + 30))
            let commentLen = Int(readUInt16LE(cdData, at: pos + 32))
            let externalAttrs = readUInt32LE(cdData, at: pos + 38)
            let localHeaderOffset32 = readUInt32LE(cdData, at: pos + 42)

            let nameStart = pos + 46
            let extraStart = nameStart + nameLen
            let commentStart = extraStart + extraLen
            let headerEnd = commentStart + commentLen
            guard headerEnd <= cdData.count else {
                throw ArchiveSecurityError.invalidArchive
            }

            let nameData = cdData[(cdData.startIndex + nameStart)..<(cdData.startIndex + extraStart)]
            guard let entryName = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1),
                  !entryName.isEmpty else {
                throw ArchiveSecurityError.unsafeEntryPath("<invalid>")
            }

            let hasDrivePrefix = entryName.utf8.count >= 2
                && entryName.utf8[entryName.utf8.index(after: entryName.utf8.startIndex)] == UInt8(ascii: ":")
            if entryName.contains("\0")
                || entryName.contains("\\")
                || hasDrivePrefix
                || entryName.hasPrefix("/")
                || entryName.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw ArchiveSecurityError.unsafeEntryPath(entryName)
            }

            let creatorOS = versionMadeBy >> 8
            let posixType = (externalAttrs >> 16) & 0o170000
            if ((creatorOS == 3 || creatorOS == 19) || (externalAttrs >> 16) != 0) && posixType == 0o120000 {
                throw ArchiveSecurityError.symlinkEntry(entryName)
            }

            var entryUncompressedSize = UInt64(uncompressedSize32)
            var entryCompressedSize = UInt64(compressedSize32)
            var localHeaderOffset = UInt64(localHeaderOffset32)

            if uncompressedSize32 == 0xFFFFFFFF || compressedSize32 == 0xFFFFFFFF || localHeaderOffset32 == 0xFFFFFFFF {
                var zip64ExtraData: Data?
                var exPos = extraStart
                while exPos + 4 <= commentStart {
                    let headerId = readUInt16LE(cdData, at: exPos)
                    let dataSize = Int(readUInt16LE(cdData, at: exPos + 2))
                    let fieldBodyStart = exPos + 4
                    let fieldBodyEnd = fieldBodyStart + dataSize
                    guard fieldBodyEnd <= commentStart else { break }
                    if headerId == 0x0001 {
                        zip64ExtraData = Data(cdData[(cdData.startIndex + fieldBodyStart)..<(cdData.startIndex + fieldBodyEnd)])
                        break
                    }
                    exPos = fieldBodyEnd
                }
                guard let z64 = zip64ExtraData else {
                    throw ArchiveSecurityError.invalidArchive
                }
                var zPos = 0
                if uncompressedSize32 == 0xFFFFFFFF {
                    guard zPos + 8 <= z64.count else { throw ArchiveSecurityError.invalidArchive }
                    entryUncompressedSize = readUInt64LE(z64, at: zPos)
                    zPos += 8
                }
                if compressedSize32 == 0xFFFFFFFF {
                    guard zPos + 8 <= z64.count else { throw ArchiveSecurityError.invalidArchive }
                    entryCompressedSize = readUInt64LE(z64, at: zPos)
                    zPos += 8
                }
                if localHeaderOffset32 == 0xFFFFFFFF {
                    guard zPos + 8 <= z64.count else { throw ArchiveSecurityError.invalidArchive }
                    localHeaderOffset = readUInt64LE(z64, at: zPos)
                    zPos += 8
                }
            }

            let (nextTotal, overflow) = totalUncompressedBytes.addingReportingOverflow(entryUncompressedSize)
            if overflow || nextTotal > maxUncompressedBytes {
                throw ArchiveSecurityError.uncompressedSizeExceeded(overflow ? UInt64.max : nextTotal)
            }
            totalUncompressedBytes = nextTotal

            guard (gpFlags & 0x0001) == 0, method == 0 || method == 8 else {
                throw ArchiveSecurityError.invalidArchive
            }

            // Cross-check Local File Header (0x04034b50) to defeat header-differential attacks
            guard localHeaderOffset + 30 <= cdOffset else {
                throw ArchiveSecurityError.invalidArchive
            }
            try handle.seek(toOffset: localHeaderOffset)
            guard let lhData = try handle.read(upToCount: 30), lhData.count == 30,
                  readUInt32LE(lhData, at: 0) == 0x04034b50 else {
                throw ArchiveSecurityError.invalidArchive
            }
            let lhFlags = readUInt16LE(lhData, at: 6)
            let lhMethod = readUInt16LE(lhData, at: 8)
            let lhCRC32 = readUInt32LE(lhData, at: 14)
            let lhCompressed32 = readUInt32LE(lhData, at: 18)
            let lhUncompressed32 = readUInt32LE(lhData, at: 22)
            let lhNameLen = Int(readUInt16LE(lhData, at: 26))
            let lhExtraLen = Int(readUInt16LE(lhData, at: 28))
            guard (lhFlags & 0x0001) == 0, lhMethod == method else {
                throw ArchiveSecurityError.invalidArchive
            }
            let lhMetaEnd = localHeaderOffset + 30 + UInt64(lhNameLen) + UInt64(lhExtraLen)
            guard lhMetaEnd <= cdOffset else {
                throw ArchiveSecurityError.invalidArchive
            }
            let lhNameData = try handle.read(upToCount: lhNameLen) ?? Data()
            guard lhNameData.count == lhNameLen else {
                throw ArchiveSecurityError.invalidArchive
            }
            if Data(nameData) != lhNameData {
                let lhName = String(data: lhNameData, encoding: .utf8) ?? "<mismatched>"
                throw ArchiveSecurityError.unsafeEntryPath(lhName)
            }
            let (dataEnd, dataOverflow) = lhMetaEnd.addingReportingOverflow(entryCompressedSize)
            guard !dataOverflow, dataEnd <= cdOffset else {
                throw ArchiveSecurityError.invalidArchive
            }

            if verifyContiguousLayoutAndStreams {
                let lhExtraData: Data
                if lhExtraLen > 0 {
                    guard let extraBytes = try handle.read(upToCount: lhExtraLen), extraBytes.count == lhExtraLen else {
                        throw ArchiveSecurityError.invalidArchive
                    }
                    lhExtraData = extraBytes
                } else {
                    lhExtraData = Data()
                }

                let spanEnd: UInt64
                if (lhFlags & 0x0008) == 0 {
                    guard lhCRC32 == cdCRC32,
                          (lhCompressed32 == 0xFFFFFFFF || UInt64(lhCompressed32) == entryCompressedSize),
                          (lhUncompressed32 == 0xFFFFFFFF || UInt64(lhUncompressed32) == entryUncompressedSize) else {
                        throw ArchiveSecurityError.invalidArchive
                    }
                    spanEnd = dataEnd
                } else {
                    let hasLHZip64 = !lhExtraData.isEmpty && hasZip64ExtraField(in: lhExtraData)
                    let expectZip64Descriptor = hasLHZip64
                        || entryCompressedSize > UInt64(UInt32.max)
                        || entryUncompressedSize > UInt64(UInt32.max)
                    let maxDescAvail = cdOffset - dataEnd
                    try handle.seek(toOffset: dataEnd)

                    if expectZip64Descriptor {
                        let toRead = Int(min(24, maxDescAvail))
                        guard toRead >= 20, let dd = try handle.read(upToCount: toRead), dd.count == toRead else {
                            throw ArchiveSecurityError.invalidArchive
                        }
                        if dd.count >= 24,
                           readUInt32LE(dd, at: 0) == 0x08074b50,
                           readUInt32LE(dd, at: 4) == cdCRC32,
                           readUInt64LE(dd, at: 8) == entryCompressedSize,
                           readUInt64LE(dd, at: 16) == entryUncompressedSize {
                            spanEnd = dataEnd + 24
                        } else if readUInt32LE(dd, at: 0) == cdCRC32,
                                  readUInt64LE(dd, at: 4) == entryCompressedSize,
                                  readUInt64LE(dd, at: 12) == entryUncompressedSize {
                            spanEnd = dataEnd + 20
                        } else {
                            throw ArchiveSecurityError.invalidArchive
                        }
                    } else {
                        let toRead = Int(min(16, maxDescAvail))
                        guard toRead >= 12, let dd = try handle.read(upToCount: toRead), dd.count == toRead else {
                            throw ArchiveSecurityError.invalidArchive
                        }
                        let comp32 = UInt32(truncatingIfNeeded: entryCompressedSize)
                        let uncomp32 = UInt32(truncatingIfNeeded: entryUncompressedSize)
                        if dd.count >= 16,
                           readUInt32LE(dd, at: 0) == 0x08074b50,
                           readUInt32LE(dd, at: 4) == cdCRC32,
                           readUInt32LE(dd, at: 8) == comp32,
                           readUInt32LE(dd, at: 12) == uncomp32 {
                            spanEnd = dataEnd + 16
                        } else if readUInt32LE(dd, at: 0) == cdCRC32,
                                  readUInt32LE(dd, at: 4) == comp32,
                                  readUInt32LE(dd, at: 8) == uncomp32 {
                            spanEnd = dataEnd + 12
                        } else {
                            throw ArchiveSecurityError.invalidArchive
                        }
                    }
                }
                entrySpans.append((start: localHeaderOffset, end: spanEnd))
            }

            let isDir = entryName.hasSuffix("/") || ((creatorOS == 3 || creatorOS == 19) && posixType == 0o040000)
            parsedEntries.append(ValidatedZipEntry(
                name: entryName,
                compressionMethod: method,
                compressedSize: entryCompressedSize,
                declaredUncompressedSize: entryUncompressedSize,
                dataOffset: lhMetaEnd,
                isDirectory: isDir
            ))

            entriesSeen += 1
            if entriesSeen > maxEntries {
                throw ArchiveSecurityError.tooManyEntries(entriesSeen)
            }

            pos = headerEnd
        }

        guard entriesSeen == Int(cdEntries) else {
            throw ArchiveSecurityError.invalidArchive
        }

        if verifyContiguousLayoutAndStreams {
            entrySpans.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            guard let firstSpan = entrySpans.first, firstSpan.start == 0 else {
                throw ArchiveSecurityError.invalidArchive
            }
            for idx in 0..<(entrySpans.count - 1) {
                guard entrySpans[idx].end == entrySpans[idx + 1].start else {
                    throw ArchiveSecurityError.invalidArchive
                }
            }
            guard entrySpans[entrySpans.count - 1].end == cdOffset else {
                throw ArchiveSecurityError.invalidArchive
            }
        }
        return parsedEntries
    }

    private static func inflateRawDeflateStream(
        handle: FileHandle,
        entry: ValidatedZipEntry,
        scratch: inout [UInt8],
        onProduced: (_ slice: ArraySlice<UInt8>) throws -> Void
    ) throws -> UInt64 {
        if entry.compressedSize == 0 {
            guard entry.declaredUncompressedSize == 0 else {
                throw ArchiveSecurityError.invalidArchive
            }
            return 0
        }

        try handle.seek(toOffset: entry.dataOffset)
        var strm = z_stream()
        let initStatus = inflateInit2_(&strm, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ArchiveSecurityError.invalidArchive
        }
        defer { inflateEnd(&strm) }

        let ioChunkSize = scratch.count
        var remaining = entry.compressedSize
        var reachedStreamEnd = false
        var entryInflated: UInt64 = 0

        while remaining > 0 && !reachedStreamEnd {
            let toRead = Int(min(UInt64(ioChunkSize), remaining))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                throw ArchiveSecurityError.invalidArchive
            }
            remaining -= UInt64(chunk.count)

            var trailingInputAfterEnd = false
            try chunk.withUnsafeBytes { inRaw in
                guard let baseIn = inRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                strm.next_in = UnsafeMutablePointer(mutating: baseIn)
                strm.avail_in = uInt(chunk.count)

                while (strm.avail_in > 0 || !reachedStreamEnd) && !reachedStreamEnd {
                    var produced = 0
                    let status: Int32 = scratch.withUnsafeMutableBufferPointer { outPtr in
                        strm.next_out = outPtr.baseAddress
                        strm.avail_out = uInt(ioChunkSize)
                        let rc = inflate(&strm, Z_NO_FLUSH)
                        produced = ioChunkSize - Int(strm.avail_out)
                        return rc
                    }
                    if produced > 0 {
                        let (nextEntry, entryOverflow) = entryInflated.addingReportingOverflow(UInt64(produced))
                        if entryOverflow {
                            throw ArchiveSecurityError.uncompressedSizeExceeded(UInt64.max)
                        }
                        entryInflated = nextEntry
                        try onProduced(scratch[..<produced])
                    }
                    if status == Z_STREAM_END {
                        reachedStreamEnd = true
                        if strm.avail_in > 0 {
                            trailingInputAfterEnd = true
                        }
                        break
                    } else if status != Z_OK && status != Z_BUF_ERROR {
                        throw ArchiveSecurityError.invalidArchive
                    }
                    if strm.avail_in == 0 && produced < ioChunkSize {
                        break
                    }
                    if produced == 0 && strm.avail_in > 0 && status == Z_BUF_ERROR {
                        break
                    }
                }
            }
            if trailingInputAfterEnd {
                throw ArchiveSecurityError.invalidArchive
            }
        }

        if !reachedStreamEnd {
            while !reachedStreamEnd {
                var produced = 0
                let status: Int32 = scratch.withUnsafeMutableBufferPointer { outPtr in
                    strm.next_in = nil
                    strm.avail_in = 0
                    strm.next_out = outPtr.baseAddress
                    strm.avail_out = uInt(ioChunkSize)
                    let rc = inflate(&strm, Z_FINISH)
                    produced = ioChunkSize - Int(strm.avail_out)
                    return rc
                }
                if produced > 0 {
                    let (nextEntry, entryOverflow) = entryInflated.addingReportingOverflow(UInt64(produced))
                    if entryOverflow {
                        throw ArchiveSecurityError.uncompressedSizeExceeded(UInt64.max)
                    }
                    entryInflated = nextEntry
                    try onProduced(scratch[..<produced])
                }
                if status == Z_STREAM_END {
                    reachedStreamEnd = true
                    break
                } else if status != Z_OK && status != Z_BUF_ERROR {
                    break
                }
                if produced == 0 {
                    break
                }
            }
        }

        guard reachedStreamEnd && remaining == 0 else {
            throw ArchiveSecurityError.invalidArchive
        }
        return entryInflated
    }

    /// Validates a ZIP archive's Central Directory (ZIP32 & ZIP64) and Local File Headers prior to extraction,
    /// rejecting header differentials, Zip Slip (`..` / leading `/` / `\`), symbolic links (`0o120000`),
    /// excessive entry counts, and decompression bombs above `maxUncompressedBytes`.
    /// When `verifyContiguousLayoutAndStreams` is enabled (used before invoking `/usr/bin/ditto`), it also
    /// verifies contiguous `[0 ..< cdOffset]` coverage and inflates Deflate streams into a 64 KiB scratch
    /// buffer to verify actual uncompressed byte counts against declared sizes and `maxUncompressedBytes`.
    public static func validateZipArchive(
        at archiveURL: URL,
        maxUncompressedBytes: UInt64 = defaultMaxArchiveUncompressedBytes,
        maxEntries: Int = defaultMaxArchiveEntries,
        verifyContiguousLayoutAndStreams: Bool = false
    ) throws {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let entries = try parseValidatedZipEntries(
            handle: handle,
            maxUncompressedBytes: maxUncompressedBytes,
            maxEntries: maxEntries,
            verifyContiguousLayoutAndStreams: verifyContiguousLayoutAndStreams
        )
        guard verifyContiguousLayoutAndStreams else { return }

        var totalActualBytes: UInt64 = 0
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        func accountVerified(_ delta: UInt64) throws {
            let (nextTotal, overflow) = totalActualBytes.addingReportingOverflow(delta)
            if overflow || nextTotal > maxUncompressedBytes {
                throw ArchiveSecurityError.uncompressedSizeExceeded(overflow ? UInt64.max : nextTotal)
            }
            totalActualBytes = nextTotal
        }

        for entry in entries {
            if entry.compressionMethod == 0 {
                guard entry.compressedSize == entry.declaredUncompressedSize else {
                    throw ArchiveSecurityError.invalidArchive
                }
                try accountVerified(entry.compressedSize)
            } else {
                let actualEntryBytes = try inflateRawDeflateStream(
                    handle: handle,
                    entry: entry,
                    scratch: &scratch
                ) { slice in
                    try accountVerified(UInt64(slice.count))
                }
                guard actualEntryBytes == entry.declaredUncompressedSize else {
                    throw ArchiveSecurityError.invalidArchive
                }
            }
        }
    }

    public static func rejectSymlinksAndOutsideFiles(in directoryURL: URL) throws {
        let fm = FileManager.default
        let canonicalRoot = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            return
        }
        for case let itemURL as URL in enumerator {
            let isSym = (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isSym {
                try? fm.removeItem(at: directoryURL)
                throw ArchiveSecurityError.symlinkEntry(itemURL.lastPathComponent)
            }
            let resolved = itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            if !resolved.hasPrefix(rootPrefix) {
                try? fm.removeItem(at: directoryURL)
                throw ArchiveSecurityError.pathTraversal(itemURL.path)
            }
        }
    }

    /// Resolves `relativePath` beneath `baseDirectory`, returning `nil` if the path attempts traversal
    /// (`..`, leading `/`, backslash, NUL) or traverses a symlink pointing outside `baseDirectory`.
    public static func containedFileURL(baseDirectory: URL, relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.isEmpty, !rawComponents.contains("..") else {
            return nil
        }

        let stdBase = baseDirectory.standardizedFileURL.path
        let stdBasePrefix = stdBase.hasSuffix("/") ? stdBase : stdBase + "/"
        let candidate = baseDirectory.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(stdBasePrefix) else {
            return nil
        }

        let fm = FileManager.default
        let realBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let realBasePrefix = realBase.hasSuffix("/") ? realBase : realBase + "/"
        var cursor = baseDirectory.standardizedFileURL
        for comp in rawComponents {
            cursor.appendPathComponent(String(comp))
            let attrs = try? fm.attributesOfItem(atPath: cursor.path)
            let isSymLinkAttr = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            let isSymRes = (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isSymLinkAttr || isSymRes {
                return nil
            }
            if attrs != nil {
                let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(realBasePrefix) else {
                    return nil
                }
            }
        }
        return candidate
    }

    // MARK: - Zip & Process Helpers
    
    private func zipFolder(folderURL: URL, toArchiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folderURL
        process.arguments = ["-0", "-r", "-q", toArchiveURL.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "PlaybackFileManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Zip process failed with code \(process.terminationStatus)"])
        }
    }
    
    private static func normalizedZipRelativePath(_ raw: String) -> String {
        var s = raw
        while s.hasPrefix("./") {
            s.removeFirst(2)
        }
        return s
    }

    private static func matchesZipGlob(pattern: String, path: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    private func extractValidatedZip(
        archiveURL: URL,
        toFolderURL: URL,
        entryPatterns: [String]?,
        maxUncompressedBytes: UInt64,
        maxEntries: Int
    ) throws {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let entries = try Self.parseValidatedZipEntries(
            handle: handle,
            maxUncompressedBytes: maxUncompressedBytes,
            maxEntries: maxEntries
        )
        try fm.createDirectory(at: toFolderURL, withIntermediateDirectories: true)

        var totalWrittenBytes: UInt64 = 0
        let ioChunkSize = 64 * 1024

        do {
            for entry in entries {
                let relPath = Self.normalizedZipRelativePath(entry.name)
                if relPath.isEmpty || relPath == "." || relPath == "./" {
                    continue
                }
                if entry.isDirectory {
                    if entryPatterns == nil {
                        let trimmedDir = relPath.hasSuffix("/") ? String(relPath.dropLast()) : relPath
                        guard let dirURL = Self.containedFileURL(baseDirectory: toFolderURL, relativePath: trimmedDir) else {
                            throw ArchiveSecurityError.unsafeEntryPath(entry.name)
                        }
                        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    }
                    continue
                }
                if relPath.hasPrefix("__MACOSX/") {
                    continue
                }
                if let patterns = entryPatterns {
                    let matched = patterns.contains { Self.matchesZipGlob(pattern: $0, path: relPath) }
                    if !matched { continue }
                }

                guard let destURL = Self.containedFileURL(baseDirectory: toFolderURL, relativePath: relPath) else {
                    throw ArchiveSecurityError.unsafeEntryPath(entry.name)
                }
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                fm.createFile(atPath: destURL.path, contents: nil)
                let outHandle = try FileHandle(forWritingTo: destURL)

                func accountWritten(_ delta: Int) throws {
                    guard delta > 0 else { return }
                    let uDelta = UInt64(delta)
                    let (nextTotal, overflow) = totalWrittenBytes.addingReportingOverflow(uDelta)
                    if overflow || nextTotal > maxUncompressedBytes {
                        try? outHandle.close()
                        throw ArchiveSecurityError.uncompressedSizeExceeded(overflow ? UInt64.max : nextTotal)
                    }
                    totalWrittenBytes = nextTotal
                }

                try handle.seek(toOffset: entry.dataOffset)

                if entry.compressionMethod == 0 {
                    var remaining = entry.compressedSize
                    while remaining > 0 {
                        let toRead = Int(min(UInt64(ioChunkSize), remaining))
                        guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                            try? outHandle.close()
                            throw ArchiveSecurityError.invalidArchive
                        }
                        try accountWritten(chunk.count)
                        try outHandle.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                    }
                } else {
                    var scratch = [UInt8](repeating: 0, count: ioChunkSize)
                    do {
                        _ = try Self.inflateRawDeflateStream(
                            handle: handle,
                            entry: entry,
                            scratch: &scratch
                        ) { slice in
                            try accountWritten(slice.count)
                            try outHandle.write(contentsOf: slice)
                        }
                    } catch {
                        try? outHandle.close()
                        throw error
                    }
                }
                try outHandle.close()
            }
            try Self.rejectSymlinksAndOutsideFiles(in: toFolderURL)
        } catch {
            try? fm.removeItem(at: toFolderURL)
            throw error
        }
    }

    public func unzipArchive(
        archiveURL: URL,
        toFolderURL: URL,
        maxUncompressedBytes: UInt64 = defaultMaxArchiveUncompressedBytes,
        maxEntries: Int = defaultMaxArchiveEntries
    ) throws {
        try extractValidatedZip(
            archiveURL: archiveURL,
            toFolderURL: toFolderURL,
            entryPatterns: nil,
            maxUncompressedBytes: maxUncompressedBytes,
            maxEntries: maxEntries
        )
    }

    public func unzipSelectedEntries(
        archiveURL: URL,
        entryPatterns: [String],
        toFolderURL: URL,
        requiredRelativeFile: String? = nil,
        maxUncompressedBytes: UInt64 = defaultMaxArchiveUncompressedBytes,
        maxEntries: Int = defaultMaxArchiveEntries
    ) throws {
        try extractValidatedZip(
            archiveURL: archiveURL,
            toFolderURL: toFolderURL,
            entryPatterns: entryPatterns,
            maxUncompressedBytes: maxUncompressedBytes,
            maxEntries: maxEntries
        )

        if let req = requiredRelativeFile {
            guard let targetURL = Self.containedFileURL(baseDirectory: toFolderURL, relativePath: req),
                  FileManager.default.fileExists(atPath: targetURL.path) else {
                throw NSError(domain: "PlaybackFileManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Archive missing required metadata file \(req)."])
            }
        }
    }
    
    /// Extracts only `session.json`, `songs/*/artwork.png`, and `songs/*/peaks.bin` from a `.pbsession` zip archive in milliseconds, skipping all heavy `.m4a` stems
    private func unzipMetadataOnly(archiveURL: URL, toFolderURL: URL) throws {
        try unzipSelectedEntries(
            archiveURL: archiveURL,
            entryPatterns: ["session.json", "songs/*/artwork.png", "songs/*/peaks.bin"],
            toFolderURL: toFolderURL,
            requiredRelativeFile: "session.json"
        )
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
                            if let embeddedURL = Self.containedFileURL(baseDirectory: pkgURL, relativePath: tm.relativeAudioPath),
                               self.hasValidStemFile(at: embeddedURL) {
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
                            try? self.coordinatedWriteData(outData, to: jsonURL)
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
