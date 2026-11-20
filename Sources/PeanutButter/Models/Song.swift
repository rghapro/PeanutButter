import Foundation
import SwiftUI
import AppKit

/// Thread-safe in-memory cache of decoded album artwork NSImage instances so SwiftUI
/// receives stable object identity across view re-evaluations instead of re-decoding Data.
private final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()
    private let cache = NSCache<NSString, NSImage>()
    
    private init() {
        cache.countLimit = 100
    }
    
    func image(for songId: UUID, data: Data) -> NSImage? {
        let key = "\(songId.uuidString)_\(data.count)_\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = NSImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

/// Preset section names commonly used in MultiTracks Playback
public enum PresetSectionName: String, CaseIterable, Identifiable, Sendable {
    case countIn = "Count In"
    case intro = "Intro"
    case verse1 = "Verse 1"
    case verse2 = "Verse 2"
    case verse3 = "Verse 3"
    case preChorus = "Pre-Chorus"
    case chorus1 = "Chorus 1"
    case chorus2 = "Chorus 2"
    case chorus3 = "Chorus 3"
    case bridge = "Bridge"
    case bridge2 = "Bridge 2"
    case interlude = "Interlude"
    case vamp = "Vamp"
    case instrumental = "Instrumental"
    case outro = "Outro"
    case ending = "Ending"
    
    public var id: String { rawValue }
    
    public var abbreviation: String {
        switch self {
        case .countIn: return "Co"
        case .intro: return "I"
        case .verse1: return "V1"
        case .verse2: return "V2"
        case .verse3: return "V3"
        case .preChorus: return "Pc"
        case .chorus1: return "C1"
        case .chorus2: return "C2"
        case .chorus3: return "C3"
        case .bridge: return "B"
        case .bridge2: return "B2"
        case .interlude: return "It"
        case .vamp: return "Vp"
        case .instrumental: return "Is"
        case .outro: return "O"
        case .ending: return "E"
        }
    }
}

/// Output routing channel options for audio interfaces
public enum OutputRoutingOption: String, CaseIterable, Identifiable, Sendable, Codable {
    case mainOut = "Out 1/2 (Main)"
    case clickOut = "Out 3 (Click)"
    case guideOut = "Out 4 (Guide)"
    case aux12 = "Out 5/6 (Aux 1)"
    case aux34 = "Out 7/8 (Aux 2)"
    case bus1 = "Bus 1 (Drums/Bass)"
    case bus2 = "Bus 2 (Instruments)"
    case bus3 = "Bus 3 (Vocals)"
    
    public var id: String { rawValue }
    
    public var shortName: String {
        switch self {
        case .mainOut: return "1/2"
        case .clickOut: return "3"
        case .guideOut: return "4"
        case .aux12: return "5/6"
        case .aux34: return "7/8"
        case .bus1: return "B1"
        case .bus2: return "B2"
        case .bus3: return "B3"
        }
    }
}

/// Helper for chromatic transpositions and musical key display
public struct MusicalKeyHelper: Sendable {
    public static let chromaticKeys = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    public static let chromaticSharpKeys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    public static func transposedKey(originalKey: String, semitones: Int) -> String {
        guard semitones != 0 else { return originalKey }
        let clean = originalKey.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty && clean != "—" else { return originalKey }
        
        let isMinor = clean.lowercased().hasSuffix("m")
        let root = isMinor ? String(clean.dropLast()) : clean
        
        let preferSharps = clean.contains("#")
        let list = preferSharps ? chromaticSharpKeys : chromaticKeys
        
        guard let idx = list.firstIndex(where: { $0.caseInsensitiveCompare(root) == .orderedSame }) ??
                        (preferSharps ? chromaticKeys : chromaticSharpKeys).firstIndex(where: { $0.caseInsensitiveCompare(root) == .orderedSame }) else {
            return originalKey
        }
        
        var newIdx = (idx + semitones) % 12
        if newIdx < 0 { newIdx += 12 }
        
        let newRoot = list[newIdx]
        return isMinor ? "\(newRoot)m" : newRoot
    }
}

/// Represents a single beat or measure downbeat marker in a dynamic click-derived beat grid
public struct BeatGridMarker: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var time: TimeInterval
    public var bar: Int
    public var beat: Int
    public var instantaneousBPM: Double
    public var timeSignatureNumerator: Int?
    public var timeSignatureDenominator: Int?
    
    public var isDownbeat: Bool { beat == 1 }
    
    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        bar: Int,
        beat: Int,
        instantaneousBPM: Double,
        timeSignatureNumerator: Int? = nil,
        timeSignatureDenominator: Int? = nil
    ) {
        self.id = id
        self.time = time
        self.bar = bar
        self.beat = beat
        self.instantaneousBPM = instantaneousBPM
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
    }
}

/// The 8 standard MultiTracks Playback MIDI Buses
public enum MIDIBus: String, CaseIterable, Identifiable, Sendable, Codable {
    case lyrics = "Lyrics"
    case lights1 = "Lights 1"
    case lights2 = "Lights 2"
    case patches1 = "Patches 1"
    case patches2 = "Patches 2"
    case guitar = "Guitar"
    case aux1 = "Aux 1"
    case aux2 = "Aux 2"
    
    public var id: String { rawValue }
    
    /// Default 1-based MIDI channel (1..8) associated with each bus
    public var defaultChannel: UInt8 {
        switch self {
        case .lyrics: return 1
        case .lights1: return 2
        case .lights2: return 3
        case .patches1: return 4
        case .patches2: return 5
        case .guitar: return 6
        case .aux1: return 7
        case .aux2: return 8
        }
    }
    
    /// Exact per-bus color matching MultiTracks Playback
    public var color: Color {
        switch self {
        case .lyrics:   return Color(red: 247.0 / 255.0, green: 148.0 / 255.0, blue: 29.0 / 255.0)
        case .lights1:  return Color(red: 255.0 / 255.0, green: 240.0 / 255.0, blue: 103.0 / 255.0)
        case .lights2:  return Color(red: 69.0 / 255.0,  green: 145.0 / 255.0, blue: 107.0 / 255.0)
        case .patches1: return Color(red: 146.0 / 255.0, green: 39.0 / 255.0,  blue: 143.0 / 255.0)
        case .patches2: return Color(red: 171.0 / 255.0, green: 41.0 / 255.0,  blue: 41.0 / 255.0)
        case .guitar:   return Color(red: 93.0 / 255.0,  green: 164.0 / 255.0, blue: 181.0 / 255.0)
        case .aux1:     return Color(red: 255.0 / 255.0, green: 85.0 / 255.0,  blue: 107.0 / 255.0)
        case .aux2:     return Color(red: 145.0 / 255.0, green: 183.0 / 255.0, blue: 64.0 / 255.0)
        }
    }
}

/// Supported MIDI Cue message types
public enum MIDIMessageType: String, CaseIterable, Identifiable, Sendable, Codable {
    case note = "Note"
    case controlChange = "Control Change"
    case programChange = "Program Change"
    
    public var id: String { rawValue }
    
    public var shortLabel: String {
        switch self {
        case .note: return "Note"
        case .controlChange: return "CC"
        case .programChange: return "PC"
        }
    }
}

/// A single timeline-positioned MIDI Cue event stored within a Song
public struct MIDICue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var time: TimeInterval
    public var sectionId: UUID?
    public var bus: MIDIBus
    public var messageType: MIDIMessageType
    /// For `.note`: MIDI Note (0..127). For `.controlChange`: CC# (0..127). For `.programChange`: Program Value (0..127).
    public var primaryValue: Int
    /// For `.note`: Velocity (1..127). For `.controlChange`: CC Value (0..127). Unused for `.programChange`.
    public var secondaryValue: Int
    public var disableLoop: Bool
    public var cueDescription: String
    
    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        sectionId: UUID? = nil,
        bus: MIDIBus = .lyrics,
        messageType: MIDIMessageType = .note,
        primaryValue: Int = 19, // Default G-1 (19) matching MultiTracks Playback
        secondaryValue: Int = 127,
        disableLoop: Bool = false,
        cueDescription: String = ""
    ) {
        self.id = id
        self.time = time
        self.sectionId = sectionId
        self.bus = bus
        self.messageType = messageType
        self.primaryValue = max(0, min(127, primaryValue))
        self.secondaryValue = max(0, min(127, secondaryValue))
        self.disableLoop = disableLoop
        self.cueDescription = cueDescription
    }
    
    enum CodingKeys: String, CodingKey {
        case id, time, sectionId, bus, messageType, primaryValue, secondaryValue, disableLoop, cueDescription
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.time = try container.decode(TimeInterval.self, forKey: .time)
        self.sectionId = try container.decodeIfPresent(UUID.self, forKey: .sectionId)
        self.bus = try container.decode(MIDIBus.self, forKey: .bus)
        self.messageType = try container.decode(MIDIMessageType.self, forKey: .messageType)
        self.primaryValue = try container.decode(Int.self, forKey: .primaryValue)
        self.secondaryValue = try container.decode(Int.self, forKey: .secondaryValue)
        self.disableLoop = try container.decode(Bool.self, forKey: .disableLoop)
        self.cueDescription = try container.decodeIfPresent(String.self, forKey: .cueDescription) ?? ""
    }
    
    private static let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    /// Converts a MIDI note number (0..127) to MultiTracks Playback / Yamaha notation (C-2 = 0, G-1 = 19, C3 = 60, G8 = 127)
    public static func noteName(for noteNumber: Int) -> String {
        let clamped = max(0, min(127, noteNumber))
        let pitch = pitchClasses[clamped % 12]
        let octave = (clamped / 12) - 2
        return "\(pitch)\(octave)"
    }
    
    /// Compact summary label for timeline hover or cue list display
    public var displaySummary: String {
        if !cueDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cueDescription
        }
        switch messageType {
        case .note:
            return "\(bus.rawValue): \(Self.noteName(for: primaryValue)) (Vel \(secondaryValue))"
        case .controlChange:
            return "\(bus.rawValue): CC \(primaryValue) = \(secondaryValue)"
        case .programChange:
            return "\(bus.rawValue): PC \(primaryValue)"
        }
    }
    
    /// Pill label displayed on the selected orange MIDI cue line in the timeline (e.g. "Note, G-1, 2")
    public var pillBadgeText: String {
        switch messageType {
        case .note:
            return "Note, \(Self.noteName(for: primaryValue)), \(secondaryValue)"
        case .controlChange:
            return "CC, \(primaryValue), \(secondaryValue)"
        case .programChange:
            return "PC, \(primaryValue)"
        }
    }
}

/// Types of transitions between songs
public enum SongTransitionType: String, CaseIterable, Identifiable, Sendable, Codable {
    case cueNextSong = "Cue Next Song"
    case stayInSong = "Stay In Song"
    case autoLink = "AutoLink"
    case overlap = "Overlap"
    case crossfade = "Crossfade"
    case cueFirstSong = "Cue First Song"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .cueNextSong: return "arrow.right"
        case .stayInSong: return "arrow.right.to.line"
        case .autoLink: return "link"
        case .overlap: return "rectangle.on.rectangle"
        case .crossfade: return "shuffle"
        case .cueFirstSong: return "arrow.uturn.backward"
        }
    }
}

/// A song definition containing metadata, tempo, key, sections, and stems
/// A mid-song meter change marker stored in source audio timeline coordinates.
public struct TimeSignatureChange: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var audioTime: TimeInterval
    public var numerator: Int
    public var denominator: Int
    
    public var label: String { "\(numerator)/\(denominator)" }
    
    public init(
        id: UUID = UUID(),
        audioTime: TimeInterval,
        numerator: Int,
        denominator: Int
    ) {
        self.id = id
        self.audioTime = max(0.0, audioTime)
        self.numerator = max(1, min(16, numerator))
        self.denominator = [2, 4, 8, 16].contains(denominator) ? denominator : 4
    }
}

/// Curve shape for gradual tempo changes (ritardando / accelerando / DAW-drawn custom curves)
public enum TempoCurveType: String, Codable, CaseIterable, Hashable, Sendable {
    case linear = "Linear"
    case easeIn = "Ease In"
    case easeOut = "Ease Out"
    case sCurve = "S-Curve"
    case custom = "Custom"
}

/// How the duration of a tempo ramp is anchored
public enum TempoRampSpanMode: String, Codable, CaseIterable, Hashable, Sendable {
    case barsBeats = "Bars / Beats"
    case audioAnchor = "Audio End"
}

/// Interior control point inside a custom DAW-style tempo curve segment
public struct TempoCurvePoint: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var normalizedTime: Double
    public var bpm: Double
    public var curveTension: Double

    public init(
        id: UUID = UUID(),
        normalizedTime: Double,
        bpm: Double,
        curveTension: Double = 0.0
    ) {
        self.id = id
        self.normalizedTime = max(0.001, min(0.999, normalizedTime))
        self.bpm = max(20.0, min(300.0, bpm))
        self.curveTension = max(-1.0, min(1.0, curveTension))
    }
}

/// A mid-song instant tempo change or gradual ramp stored in source audio timeline coordinates.
public struct TempoChangeEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var audioTime: TimeInterval
    public var targetBPM: Double
    public var isRamp: Bool
    public var endAudioTime: TimeInterval?
    public var spanMode: TempoRampSpanMode
    public var rampBeats: Double?
    public var lockBeatCountToAudioEnd: Bool
    public var curve: TempoCurveType
    public var curveTension: Double
    public var customPoints: [TempoCurvePoint]

    public init(
        id: UUID = UUID(),
        audioTime: TimeInterval,
        targetBPM: Double,
        isRamp: Bool = false,
        endAudioTime: TimeInterval? = nil,
        spanMode: TempoRampSpanMode = .barsBeats,
        rampBeats: Double? = nil,
        lockBeatCountToAudioEnd: Bool = true,
        curve: TempoCurveType = .linear,
        curveTension: Double = 0.0,
        customPoints: [TempoCurvePoint] = []
    ) {
        let safeAudioTime = max(0.0, audioTime)
        self.id = id
        self.audioTime = safeAudioTime
        self.targetBPM = max(20.0, min(300.0, targetBPM))
        self.isRamp = isRamp
        self.endAudioTime = endAudioTime.map { max(safeAudioTime + 0.05, $0) }
        self.spanMode = spanMode
        self.rampBeats = rampBeats.map { max(0.25, $0) }
        self.lockBeatCountToAudioEnd = lockBeatCountToAudioEnd
        self.curve = curve
        self.curveTension = max(-1.0, min(1.0, curveTension))
        self.customPoints = customPoints.sorted { $0.normalizedTime < $1.normalizedTime }
    }

    public func pillLabel(from startBPM: Double) -> String {
        let endStr = Song.formatBPM(targetBPM, decimals: Song.tempoDecimalPrecision(for: targetBPM))
        guard isRamp else {
            return "\(endStr) BPM"
        }
        let startStr = Song.formatBPM(startBPM, decimals: Song.tempoDecimalPrecision(for: startBPM))
        return "\(startStr) → \(endStr)"
    }
}

/// Evaluated concrete time/BPM bounds for a `TempoChangeEvent` in sequence
public struct ResolvedTempoSpan: Equatable, Sendable {
    public let event: TempoChangeEvent
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let startBPM: Double
    public let endBPM: Double

    public init(
        event: TempoChangeEvent,
        startTime: TimeInterval,
        endTime: TimeInterval,
        startBPM: Double,
        endBPM: Double
    ) {
        self.event = event
        self.startTime = startTime
        self.endTime = endTime
        self.startBPM = startBPM
        self.endBPM = endBPM
    }
}

public struct Song: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    /// Original package ID when a song is added multiple times to a setlist so each instance has a unique `id`.
    public var sourceSongId: UUID? = nil
    public var title: String
    public var artist: String
    public var bpm: Double
    public var originalBPM: Double
    public var timeSignatureNumerator: Int
    public var timeSignatureDenominator: Int
    public var musicalKey: String
    public var transposeSemitones: Int = 0
    public var preserveVocalFormants: Bool = true
    public var beatGrid: [BeatGridMarker] = []
    public var midiCues: [MIDICue] = []
    public var directionalCues: [DirectionalCue] = []
    public var automationPoints: [AutomationPoint] = []
    public var smpteCue: SMPTECue? = nil
    /// Optional ProPresenter Playlist number (1..127). Sends MIDI Note F-1 (17) at this velocity when the song starts.
    public var proPresenterPlaylist: Int? = nil
    /// Optional ProPresenter Playlist Item number (1..127). Sends MIDI Note F#-1 (18) at this velocity when the song starts.
    public var proPresenterPlaylistItem: Int? = nil
    /// Song transition behavior when the song finishes
    public var transitionType: SongTransitionType = .cueNextSong
    /// Whether ambient Pad playback should continue through this transition
    public var continuePad: Bool = false
    /// Whether click and MIDI clock should continue running after this song ends
    public var continueClick: Bool = false
    /// Whether the guide track should count in the opening section of the following song across an automatic transition
    public var cueNextSongSection: Bool = false
    /// Whether the song should automatically fade out non-click/guide tracks over the final 5 seconds
    public var endFadeOutEnabled: Bool = false
    /// Whether the song should automatically fade out non-click/guide tracks over the section labeled "End"
    public var fadeEndSectionEnabled: Bool = false
    /// Whether the ambient Pad should automatically start when song playback begins
    public var startPadWithSong: Bool = false
    /// ID of the ambient Pad audio pack to use for this song (nil uses system default)
    public var padPresetId: String? = nil
    /// Whether ambient Pad should only play during Count In, Intro, and Outro sections
    public var padIntroOutroOnly: Bool = false
    
    /// Optional embedded album cover artwork data (JPEG/PNG)
    public var artworkData: Data? = nil
    
    public var albumArtwork: NSImage? {
        get {
            guard let data = artworkData else { return nil }
            return ArtworkImageCache.shared.image(for: id, data: data)
        }
        set {
            if let img = newValue {
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    artworkData = rep.representation(using: .png, properties: [:]) ?? tiff
                } else {
                    artworkData = nil
                }
            } else {
                artworkData = nil
            }
        }
    }
    
    // Click & Guide source selection and subdivisions
    public var clickSource: ClickSource = .generated
    public var guideSource: GuideSource = .generated
    public var guideVoice: GuideVoice = GuideVoice.defaultVoice
    public var guideFallbackVoice: GuideVoice = CustomSampleLibraryManager.shared.defaultGuideFallbackVoice
    public var clickSound: ClickSoundType = ClickSoundType.defaultSound
    public var usesDefaultClickSound: Bool = true
    public var usesDefaultGuideVoice: Bool = true
    public var clickAccentEnabled: Bool = true
    public var clickQuarterEnabled: Bool = true
    public var clickEighthEnabled: Bool = true
    public var clickSixteenthEnabled: Bool = false
    public var clickAccentVolume: Float = 0.80
    public var clickQuarterVolume: Float = 0.80
    public var clickEighthVolume: Float = 0.70
    public var clickSixteenthVolume: Float = 0.0
    public var guideCountInEnabled: Bool = true
    public var speakDirectionalCuesOnUploadedGuide: Bool = true
    public var guideSectionsVolume: Float = 0.80
    public var guideSectionsEnabled: Bool = true
    public var guideDirectionsVolume: Float = 0.80
    public var guideDirectionsEnabled: Bool = true
    public var guideFallbackVolume: Float = 0.80
    public var guideFallbackEnabled: Bool = true
    public var autoInfiniteLoop: Bool = false
    public var excludesClickAndGuide: Bool = false
    
    public var effectiveKey: String {
        MusicalKeyHelper.transposedKey(originalKey: musicalKey, semitones: transposeSemitones)
    }
    
    public var currentTransposedKey: String {
        effectiveKey
    }
    
    /// Returns the number of decimal places (0, 1, or 2) carried by `bpm`, so UI controls
    /// (such as a scroll wheel) step at whole numbers for `74`, tenths for `120.5`, and hundredths for `72.25`.
    public static func tempoDecimalPrecision(for bpm: Double) -> Int {
        let hundredths = Int((bpm * 100.0).rounded())
        if hundredths % 100 == 0 { return 0 }
        if hundredths % 10 == 0 { return 1 }
        return 2
    }
    
    /// Formats a BPM value using the specified decimal precision (0, 1, or 2).
    public static func formatBPM(_ bpm: Double, decimals: Int) -> String {
        switch decimals {
        case 0:
            return "\(Int(bpm.rounded()))"
        case 1:
            return String(format: "%.1f", (bpm * 10.0).rounded() / 10.0)
        default:
            return String(format: "%.2f", (bpm * 100.0).rounded() / 100.0)
        }
    }
    
    /// Builds the canonical Click & Pad sections (`Count Off` -> `Click` -> `Ending`).
    public static func makeClickAndPadSections(
        bpm: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int,
        infiniteLoop: Bool,
        measures: Int
    ) -> [SongSection] {
        let safeBpm = max(20.0, min(300.0, bpm))
        let tsNum = max(1, timeSignatureNumerator)
        let tsDen = max(1, timeSignatureDenominator)
        let secPerBeat = (60.0 / safeBpm) * (4.0 / Double(tsDen))
        let secPerBar = secPerBeat * Double(tsNum)

        let countOffDur = 2.0 * secPerBar
        let clickBars = infiniteLoop ? 4 : max(1, measures)
        let clickDur = Double(clickBars) * secPerBar
        let endingDur = 1.0 * secPerBar

        let countOffSection = SongSection(
            name: "Count Off",
            abbreviation: "Co",
            startTime: 0.0,
            audioStartTime: 0.0,
            duration: countOffDur,
            startMeasure: 1,
            measureCount: 2,
            playSectionGuideCue: false,
            playSectionCountIn: true,
            includeNumberInGuide: false
        )
        let clickSection = SongSection(
            name: "Click",
            abbreviation: "Cl",
            startTime: countOffDur,
            audioStartTime: countOffDur,
            duration: clickDur,
            startMeasure: 3,
            measureCount: clickBars,
            playSectionGuideCue: false,
            playSectionCountIn: true,
            includeNumberInGuide: false
        )
        let endingSection = SongSection(
            name: "Ending",
            abbreviation: "E",
            startTime: countOffDur + clickDur,
            audioStartTime: countOffDur + clickDur,
            duration: endingDur,
            startMeasure: 3 + clickBars,
            measureCount: 1,
            playSectionGuideCue: true,
            playSectionCountIn: true,
            includeNumberInGuide: false
        )
        return [countOffSection, clickSection, endingSection]
    }

    /// Canonical predicate matching sections labeled "End" / "Ending" (shared by Click cutoff and Fade End).
    public static func isEndSection(_ sec: SongSection) -> Bool {
        let lowerName = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerAbbrev = sec.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerName == "end" || lowerName == "ending" || lowerName == "the end" ||
           lowerName.starts(with: "end ") || lowerName.hasSuffix(" end") ||
           lowerName.starts(with: "ending ") || lowerName.hasSuffix(" ending") ||
           lowerAbbrev == "end" {
            return true
        }
        if lowerAbbrev == "e" {
            let words = lowerName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            return words.contains("end") || words.contains("ending") || words == ["e"]
        }
        return false
    }

    /// Returns the final non-zero section labeled "End" / "Ending" for Fade End playback.
    public var endSectionForFade: SongSection? {
        sections.last(where: { Self.isEndSection($0) && $0.duration > 0.05 })
    }
    
    /// Clean tempo bounds: intersection of `originalBPM ± 20` and `[originalBPM * 0.75, originalBPM * 1.50]`, clamped within `[20, 300]`.
    public static func allowedTempoRange(forOriginalBPM originalBPM: Double) -> ClosedRange<Double> {
        let base = max(20.0, min(300.0, originalBPM))
        let lower = max(20.0, max(base - 20.0, base * 0.75))
        let upper = min(300.0, min(base + 20.0, base * 1.50))
        let roundedLower = (lower * 100.0).rounded(.up) / 100.0
        let roundedUpper = (upper * 100.0).rounded(.down) / 100.0
        return roundedLower...max(roundedLower, roundedUpper)
    }
    
    public static func clampedShiftedTempo(_ bpm: Double, originalBPM: Double) -> Double {
        let range = allowedTempoRange(forOriginalBPM: originalBPM)
        let rounded = (bpm * 100.0).rounded() / 100.0
        return max(range.lowerBound, min(range.upperBound, rounded))
    }
    
    public var isTempoShifted: Bool {
        abs(bpm - originalBPM) > 0.005
    }
    
    public var sections: [SongSection] {
        didSet {
            if defaultSections.isEmpty && !sections.isEmpty {
                defaultSections = sections
            }
        }
    }
    public var defaultSections: [SongSection]
    public var savedArrangements: [SavedArrangement] = []
    /// nil represents the "Default" arrangement; a UUID points to an entry in `savedArrangements`
    public var activeArrangementId: UUID? = nil
    public var defaultMidiCues: [MIDICue] = []
    public var defaultDirectionalCues: [DirectionalCue] = []
    public var defaultAutomationPoints: [AutomationPoint] = []
    public var defaultSmpteCue: SMPTECue? = nil
    public var stemURLs: [URL]
    public var timeSignatureChanges: [TimeSignatureChange] = []
    public var tempoEvents: [TempoChangeEvent] = []
    
    public var activeArrangementName: String {
        if let id = activeArrangementId,
           let found = savedArrangements.first(where: { $0.id == id }) {
            return found.name
        }
        return "Default"
    }
    
    /// Returns the active meter `(numerator, denominator)` at `sourceTime` in the song's source audio timeline.
    public func timeSignature(atSourceTime sourceTime: TimeInterval) -> (numerator: Int, denominator: Int) {
        let sorted = timeSignatureChanges.sorted { $0.audioTime < $1.audioTime }
        if let active = sorted.last(where: { sourceTime + 0.005 >= $0.audioTime }) {
            return (active.numerator, active.denominator)
        }
        return (timeSignatureNumerator, timeSignatureDenominator)
    }

    /// Evaluates normalized curve factor `0...1` for preset curve shapes and tension (`-1.0...1.0`).
    public static func evaluateCurveFactor(curve: TempoCurveType, tension: Double, u: Double) -> Double {
        let clampedU = max(0.0, min(1.0, u))
        let t = max(-1.0, min(1.0, tension))
        switch curve {
        case .linear, .custom:
            if abs(t) < 0.001 { return clampedU }
            if t > 0 {
                return pow(clampedU, 1.0 + t * 2.0)
            } else {
                return 1.0 - pow(1.0 - clampedU, 1.0 - t * 2.0)
            }
        case .easeIn:
            let exponent = max(1.1, 2.0 + t * 1.2)
            return pow(clampedU, exponent)
        case .easeOut:
            let exponent = max(1.1, 2.0 - t * 1.2)
            return 1.0 - pow(1.0 - clampedU, exponent)
        case .sCurve:
            let smooth = clampedU * clampedU * (3.0 - 2.0 * clampedU)
            if abs(t) < 0.001 { return smooth }
            if t > 0 {
                return pow(smooth, 1.0 + t * 0.8)
            } else {
                return 1.0 - pow(1.0 - smooth, 1.0 - t * 0.8)
            }
        }
    }

    /// Evaluates the BPM at normalized progress `u` (`0...1`) inside a ramp event from `startBPM` to `endBPM`.
    public static func evaluateRampBPM(
        event: TempoChangeEvent,
        startBPM: Double,
        endBPM: Double,
        u: Double
    ) -> Double {
        let clampedU = max(0.0, min(1.0, u))
        let safeStart = max(20.0, min(300.0, startBPM))
        let safeEnd = max(20.0, min(300.0, endBPM))

        if event.curve == .custom && !event.customPoints.isEmpty {
            let sortedPts = event.customPoints.sorted { $0.normalizedTime < $1.normalizedTime }
            var waypoints: [(t: Double, bpm: Double, tension: Double)] = [(0.0, safeStart, event.curveTension)]
            waypoints.reserveCapacity(sortedPts.count + 2)
            for pt in sortedPts {
                waypoints.append((max(0.001, min(0.999, pt.normalizedTime)), max(20.0, min(300.0, pt.bpm)), pt.curveTension))
            }
            waypoints.append((1.0, safeEnd, 0.0))

            var segIdx = 0
            for idx in 0..<(waypoints.count - 1) {
                if clampedU >= waypoints[idx].t {
                    segIdx = idx
                }
            }
            let p0 = waypoints[segIdx]
            let p1 = waypoints[min(waypoints.count - 1, segIdx + 1)]
            let localU = (clampedU - p0.t) / max(1e-6, p1.t - p0.t)
            let factor = evaluateCurveFactor(curve: .linear, tension: p0.tension, u: localU)
            let val = p0.bpm + (p1.bpm - p0.bpm) * factor
            return max(20.0, min(300.0, val))
        }

        let factor = evaluateCurveFactor(curve: event.curve, tension: event.curveTension, u: clampedU)
        let val = safeStart + (safeEnd - safeStart) * factor
        return max(20.0, min(300.0, val))
    }

    /// Resolves sequential concrete source-time bounds and start/end BPMs for all `tempoEvents`.
    public func resolvedTempoSpans() -> [ResolvedTempoSpan] {
        guard !tempoEvents.isEmpty else { return [] }
        let sorted = tempoEvents.sorted { $0.audioTime < $1.audioTime }
        var spans: [ResolvedTempoSpan] = []
        spans.reserveCapacity(sorted.count)
        var activeBPM = max(20.0, min(300.0, bpm))

        for idx in sorted.indices {
            let ev = sorted[idx]
            let startT = max(0.0, ev.audioTime)
            let startB = activeBPM
            var endT = startT
            var endB = max(20.0, min(300.0, ev.targetBPM))

            if ev.isRamp {
                let ts = timeSignature(atSourceTime: startT)
                let den = max(1, ts.denominator)
                if ev.spanMode == .barsBeats {
                    let beats = max(0.5, ev.rampBeats ?? Double(max(1, ts.numerator) * 2))
                    let steps = 64
                    var bpmSum = 0.0
                    for s in 0...steps {
                        let u = Double(s) / Double(steps)
                        let w = (s == 0 || s == steps) ? 0.5 : 1.0
                        bpmSum += w * Self.evaluateRampBPM(event: ev, startBPM: startB, endBPM: endB, u: u)
                    }
                    let meanBPM = max(20.0, bpmSum / Double(steps))
                    let dur = beats / ((Double(den) / 240.0) * meanBPM)
                    endT = startT + max(0.05, dur)
                } else {
                    endT = max(startT + 0.05, ev.endAudioTime ?? (startT + 2.0))
                    if ev.lockBeatCountToAudioEnd, ev.curve != .custom, let beats = ev.rampBeats, beats > 0.25 {
                        let requiredMeanBPM = (beats * 240.0) / (Double(den) * max(0.05, endT - startT))
                        let steps = 64
                        var factorSum = 0.0
                        for s in 0...steps {
                            let u = Double(s) / Double(steps)
                            let w = (s == 0 || s == steps) ? 0.5 : 1.0
                            factorSum += w * Self.evaluateCurveFactor(curve: ev.curve, tension: ev.curveTension, u: u)
                        }
                        let curveMean = max(0.05, factorSum / Double(steps))
                        let solvedEnd = startB + (requiredMeanBPM - startB) / curveMean
                        endB = max(20.0, min(300.0, solvedEnd))
                    }
                }
                if idx + 1 < sorted.count && sorted[idx + 1].audioTime > startT + 0.05 {
                    endT = min(endT, sorted[idx + 1].audioTime)
                }
            }

            spans.append(ResolvedTempoSpan(
                event: ev,
                startTime: startT,
                endTime: endT,
                startBPM: startB,
                endBPM: endB
            ))
            activeBPM = endB
        }

        return spans
    }

    /// Evaluates continuous or stepped BPM at `sourceTime` across resolved `tempoEvents`.
    public func evaluateBPM(atSourceTime sourceTime: TimeInterval) -> Double {
        let spans = resolvedTempoSpans()
        guard !spans.isEmpty else { return max(20.0, min(300.0, bpm)) }
        var activeBPM = max(20.0, min(300.0, bpm))
        for span in spans {
            if sourceTime < span.startTime - 0.0005 {
                break
            }
            if span.event.isRamp && sourceTime < span.endTime - 0.0005 {
                let u = (sourceTime - span.startTime) / max(0.001, span.endTime - span.startTime)
                return Self.evaluateRampBPM(event: span.event, startBPM: span.startBPM, endBPM: span.endBPM, u: u)
            }
            activeBPM = span.endBPM
        }
        return activeBPM
    }

    private func evaluateBPM(atSourceTime sourceTime: TimeInterval, spans: [ResolvedTempoSpan]) -> Double {
        guard !spans.isEmpty else { return max(20.0, min(300.0, bpm)) }
        var activeBPM = max(20.0, min(300.0, bpm))
        for span in spans {
            if sourceTime < span.startTime - 0.0005 {
                break
            }
            if span.event.isRamp && sourceTime < span.endTime - 0.0005 {
                let u = (sourceTime - span.startTime) / max(0.001, span.endTime - span.startTime)
                return Self.evaluateRampBPM(event: span.event, startBPM: span.startBPM, endBPM: span.endBPM, u: u)
            }
            activeBPM = span.endBPM
        }
        return activeBPM
    }

    private func nextBeatTime(
        from t: TimeInterval,
        denominator: Int,
        spans: [ResolvedTempoSpan],
        nextTimeSigTime: TimeInterval?
    ) -> TimeInterval {
        let denFactor = Double(max(1, denominator)) / 240.0
        let localBPM = evaluateBPM(atSourceTime: t, spans: spans)
        let constDur = max(0.05, 1.0 / (denFactor * max(20.0, localBPM)))
        let candidateEnd = t + constDur

        let overlapsSpan = spans.contains { span in
            if span.event.isRamp {
                return candidateEnd > span.startTime - 0.001 && t < span.endTime + 0.001
            } else {
                return span.startTime > t + 0.0005 && span.startTime < candidateEnd - 0.0005
            }
        }
        if !overlapsSpan {
            return candidateEnd
        }

        let dt = 0.004
        var curT = t
        var phase = 0.0
        let maxIter = 20_000
        for _ in 0..<maxIter {
            let stepEnd = curT + dt
            if let tsBoundary = nextTimeSigTime, curT < tsBoundary - 0.0005 && stepEnd >= tsBoundary + 0.0005 {
                let partialDt = max(0.0001, tsBoundary - curT)
                let segBPM = evaluateBPM(atSourceTime: curT + 0.5 * partialDt, spans: spans)
                phase += segBPM * denFactor * partialDt
                if phase >= 1.0 {
                    let excess = (phase - 1.0) / max(1e-9, segBPM * denFactor)
                    return max(t + 0.02, tsBoundary - excess)
                }
                curT = tsBoundary
                continue
            }
            let segBPM = evaluateBPM(atSourceTime: curT + 0.5 * dt, spans: spans)
            let dPhase = segBPM * denFactor * dt
            if phase + dPhase >= 1.0 {
                let remain = max(0.0, 1.0 - phase)
                let frac = remain / max(1e-9, dPhase)
                var resultT = max(t + 0.02, curT + frac * dt)
                for span in spans where span.event.isRamp && (span.event.spanMode == .barsBeats || span.event.lockBeatCountToAudioEnd) {
                    if abs(resultT - span.endTime) <= 0.015 {
                        resultT = span.endTime
                        break
                    }
                }
                return resultT
            }
            phase += dPhase
            curT = stepEnd
        }
        return candidateEnd
    }
    
    /// Returns the instantaneous BPM from `tempoEvents` / `beatGrid` at `sourceTime` (falling back to `bpm`).
    public func instantaneousBPM(atSourceTime sourceTime: TimeInterval) -> Double {
        if !tempoEvents.isEmpty {
            let firstEventTime = tempoEvents.map(\.audioTime).min() ?? 0.0
            if beatGrid.isEmpty || sourceTime + 0.008 >= firstEventTime {
                return evaluateBPM(atSourceTime: sourceTime)
            }
        }
        guard !beatGrid.isEmpty else { return max(20.0, bpm) }
        let target = sourceTime + 0.008
        var low = 0
        var high = beatGrid.count - 1
        var bestIdx = 0
        while low <= high {
            let mid = (low + high) / 2
            if beatGrid[mid].time <= target {
                bestIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let val = beatGrid[bestIdx].instantaneousBPM
        return val > 20.0 ? val : max(20.0, bpm)
    }
    
    /// Builds the source-timeline beat grid incorporating any mid-song `timeSignatureChanges` and `tempoEvents`.
    public func sourceBeatGrid(upToDuration: TimeInterval? = nil) -> [BeatGridMarker] {
        let sortedChanges = timeSignatureChanges.sorted { $0.audioTime < $1.audioTime }
        let spans = resolvedTempoSpans()
        if sortedChanges.isEmpty && spans.isEmpty {
            if beatGrid.count <= 1 { return beatGrid }
            var isSorted = true
            for i in 1..<beatGrid.count where beatGrid[i].time < beatGrid[i - 1].time {
                isSorted = false
                break
            }
            return isSorted ? beatGrid : beatGrid.sorted { $0.time < $1.time }
        }

        if spans.isEmpty && !beatGrid.isEmpty {
            let orderedGrid: [BeatGridMarker] = {
                var isSorted = true
                for i in 1..<beatGrid.count where beatGrid[i].time < beatGrid[i - 1].time {
                    isSorted = false
                    break
                }
                return isSorted ? beatGrid : beatGrid.sorted { $0.time < $1.time }
            }()
            var result: [BeatGridMarker] = []
            result.reserveCapacity(orderedGrid.count)
            var bar = 1
            var beat = 1
            var changeIdx = 0
            var curNum = max(1, timeSignatureNumerator)
            var curDen = max(1, timeSignatureDenominator)

            var i = 0
            while i < orderedGrid.count {
                let marker = orderedGrid[i]
                while changeIdx < sortedChanges.count && marker.time + 0.01 >= sortedChanges[changeIdx].audioTime {
                    curNum = max(1, sortedChanges[changeIdx].numerator)
                    curDen = max(1, sortedChanges[changeIdx].denominator)
                    if !result.isEmpty && beat != 1 {
                        bar += 1
                        beat = 1
                    }
                    changeIdx += 1
                }
                result.append(BeatGridMarker(time: marker.time, bar: bar, beat: beat, instantaneousBPM: marker.instantaneousBPM, timeSignatureNumerator: curNum, timeSignatureDenominator: curDen))
                beat += 1
                if beat > curNum {
                    beat = 1
                    bar += 1
                }

                if i + 1 < orderedGrid.count {
                    let localBPM = max(20.0, marker.instantaneousBPM > 20.0 ? marker.instantaneousBPM : bpm)
                    let expectedBeatDur = (60.0 / localBPM) * (4.0 / Double(curDen))
                    let segDur = orderedGrid[i + 1].time - marker.time
                    if segDur > 0.01 {
                        if segDur / expectedBeatDur >= 1.65 {
                            let subCount = max(2, min(8, Int((segDur / expectedBeatDur).rounded())))
                            for sub in 1..<subCount {
                                let subTime = marker.time + (Double(sub) / Double(subCount)) * segDur
                                if changeIdx < sortedChanges.count && subTime + 0.01 >= sortedChanges[changeIdx].audioTime {
                                    break
                                }
                                result.append(BeatGridMarker(time: subTime, bar: bar, beat: beat, instantaneousBPM: marker.instantaneousBPM, timeSignatureNumerator: curNum, timeSignatureDenominator: curDen))
                                beat += 1
                                if beat > curNum {
                                    beat = 1
                                    bar += 1
                                }
                            }
                            i += 1
                        } else if expectedBeatDur / segDur >= 1.65 {
                            let strideCount = max(2, min(8, Int((expectedBeatDur / segDur).rounded())))
                            var step = 1
                            while step < strideCount && (i + step) < orderedGrid.count {
                                let probeTime = orderedGrid[i + step].time
                                if changeIdx < sortedChanges.count && probeTime + 0.01 >= sortedChanges[changeIdx].audioTime {
                                    break
                                }
                                step += 1
                            }
                            i += step
                        } else {
                            i += 1
                        }
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
            return result
        }

        let maxSectionSrcEnd = max(
            sections.map { $0.sourceAudioStartTime + $0.duration }.max() ?? 0.0,
            defaultSections.map { $0.sourceAudioStartTime + $0.duration }.max() ?? 0.0
        )
        let maxSpanEnd = spans.map(\.endTime).max() ?? 0.0
        let dur = max(upToDuration ?? 0.0, max(maxSectionSrcEnd, maxSpanEnd > 0 ? maxSpanEnd + 4.0 : 0.0))
        guard dur > 0.1 else { return [] }

        var markers: [BeatGridMarker] = []
        var bar = 1
        var beat = 1
        var changeIdx = 0
        var curNum = max(1, timeSignatureNumerator)
        var curDen = max(1, timeSignatureDenominator)
        var t: TimeInterval = 0.0

        // Preserve any imported/detected beatGrid markers strictly before the first manual tempo event
        if !beatGrid.isEmpty, let firstTempoTime = spans.first?.startTime, firstTempoTime > 0.02 {
            let orderedGrid: [BeatGridMarker] = {
                var isSorted = true
                for i in 1..<beatGrid.count where beatGrid[i].time < beatGrid[i - 1].time {
                    isSorted = false
                    break
                }
                return isSorted ? beatGrid : beatGrid.sorted { $0.time < $1.time }
            }()
            var lastKeptMarker: BeatGridMarker? = nil
            var i = 0
            while i < orderedGrid.count && orderedGrid[i].time + 0.01 < firstTempoTime {
                let marker = orderedGrid[i]
                while changeIdx < sortedChanges.count && marker.time + 0.01 >= sortedChanges[changeIdx].audioTime {
                    curNum = max(1, sortedChanges[changeIdx].numerator)
                    curDen = max(1, sortedChanges[changeIdx].denominator)
                    if !markers.isEmpty && beat != 1 {
                        bar += 1
                        beat = 1
                    }
                    changeIdx += 1
                }
                markers.append(BeatGridMarker(time: marker.time, bar: bar, beat: beat, instantaneousBPM: marker.instantaneousBPM, timeSignatureNumerator: curNum, timeSignatureDenominator: curDen))
                lastKeptMarker = marker
                beat += 1
                if beat > curNum {
                    beat = 1
                    bar += 1
                }

                if i + 1 < orderedGrid.count && orderedGrid[i + 1].time + 0.01 < firstTempoTime {
                    let localBPM = max(20.0, marker.instantaneousBPM > 20.0 ? marker.instantaneousBPM : bpm)
                    let expectedBeatDur = (60.0 / localBPM) * (4.0 / Double(curDen))
                    let segDur = orderedGrid[i + 1].time - marker.time
                    if segDur > 0.01 && segDur / expectedBeatDur >= 1.65 {
                        let subCount = max(2, min(8, Int((segDur / expectedBeatDur).rounded())))
                        for sub in 1..<subCount {
                            let subTime = marker.time + (Double(sub) / Double(subCount)) * segDur
                            if subTime + 0.01 >= firstTempoTime { break }
                            if changeIdx < sortedChanges.count && subTime + 0.01 >= sortedChanges[changeIdx].audioTime {
                                break
                            }
                            markers.append(BeatGridMarker(time: subTime, bar: bar, beat: beat, instantaneousBPM: marker.instantaneousBPM, timeSignatureNumerator: curNum, timeSignatureDenominator: curDen))
                            beat += 1
                            if beat > curNum {
                                beat = 1
                                bar += 1
                            }
                        }
                    }
                }
                i += 1
            }

            if let lastKept = lastKeptMarker {
                let prevBPM = max(20.0, lastKept.instantaneousBPM > 20.0 ? lastKept.instantaneousBPM : bpm)
                let prevBeatDur = (60.0 / prevBPM) * (4.0 / Double(curDen))
                let nextExpected = lastKept.time + prevBeatDur
                t = abs(nextExpected - firstTempoTime) <= 0.025 ? firstTempoTime : nextExpected
            } else {
                t = 0.0
            }
        }

        while t < dur - 0.01 && markers.count < 8000 {
            while changeIdx < sortedChanges.count && t + 0.01 >= sortedChanges[changeIdx].audioTime {
                curNum = max(1, sortedChanges[changeIdx].numerator)
                curDen = max(1, sortedChanges[changeIdx].denominator)
                if !markers.isEmpty && beat != 1 {
                    bar += 1
                    beat = 1
                }
                changeIdx += 1
            }
            let instBPM = spans.isEmpty ? max(20.0, bpm) : evaluateBPM(atSourceTime: t, spans: spans)
            markers.append(BeatGridMarker(time: t, bar: bar, beat: beat, instantaneousBPM: instBPM, timeSignatureNumerator: curNum, timeSignatureDenominator: curDen))

            let nextTS = (changeIdx < sortedChanges.count) ? sortedChanges[changeIdx].audioTime : nil
            let tNext = spans.isEmpty
                ? (t + (60.0 / max(20.0, bpm)) * (4.0 / Double(curDen)))
                : nextBeatTime(from: t, denominator: curDen, spans: spans, nextTimeSigTime: nextTS)
            t = max(t + 0.02, tNext)
            beat += 1
            if beat > curNum {
                beat = 1
                bar += 1
            }
        }
        return markers
    }
    
    /// Counts how many measures a section `[audioStart, audioStart + duration)` spans in `srcGrid`,
    /// accurately accounting for mid-song tempo and meter changes.
    public static func measureCount(
        inSourceGrid srcGrid: [BeatGridMarker],
        audioStart: TimeInterval,
        duration: TimeInterval,
        fallbackBPM: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int
    ) -> Int {
        guard duration > 0.05 else { return 1 }
        if !srcGrid.isEmpty {
            let winStart = audioStart - 0.08
            let winEnd = audioStart + duration - 0.15
            var count = 0
            for m in srcGrid where m.beat == 1 {
                if m.time >= winStart && m.time < winEnd {
                    count += 1
                } else if m.time >= winEnd {
                    break
                }
            }
            if count >= 1 {
                return count
            }
            let target = audioStart + 0.008
            var bestIdx = 0
            for (idx, m) in srcGrid.enumerated() {
                if m.time <= target { bestIdx = idx } else { break }
            }
            let localBPM = max(20.0, srcGrid[bestIdx].instantaneousBPM)
            let beatDur = (60.0 / localBPM) * (4.0 / Double(max(1, timeSignatureDenominator)))
            let barDur = beatDur * Double(max(1, timeSignatureNumerator))
            return max(1, Int((duration / max(0.1, barDur)).rounded()))
        }
        let safeBPM = max(20.0, fallbackBPM)
        let beatDur = (60.0 / safeBPM) * (4.0 / Double(max(1, timeSignatureDenominator)))
        let barDur = beatDur * Double(max(1, timeSignatureNumerator))
        return max(1, Int((duration / max(0.1, barDur)).rounded()))
    }
    
    /// Recomputes `measureCount` and `startMeasure` for `sections`, `defaultSections`, and `savedArrangements`
    /// using `sourceBeatGrid()` (or base `bpm` and time signature when no mid-song overrides exist).
    public mutating func reconcileSectionMeasuresWithBeatGrid() {
        let hasDynamicGrid = !beatGrid.isEmpty || !timeSignatureChanges.isEmpty || !tempoEvents.isEmpty
        let srcGrid = hasDynamicGrid ? sourceBeatGrid() : []
        let fallbackBPM = bpm
        let baseNum = timeSignatureNumerator
        let baseDen = timeSignatureDenominator
        let sortedTSChanges = timeSignatureChanges.sorted { $0.audioTime < $1.audioTime }
        
        func reconcile(_ list: inout [SongSection]) {
            var currentMeasure = 1
            for i in 0..<list.count {
                let sec = list[i]
                let isBlankClick = sec.effectiveIsClickSection &&
                    (sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click section" || sec.abbreviation == "CLK")
                let bars: Int
                if isBlankClick || sec.duration <= 0.05 {
                    bars = max(1, sec.measureCount)
                } else {
                    let srcStart = sec.sourceAudioStartTime
                    let activeTS = sortedTSChanges.last(where: { srcStart + 0.005 >= $0.audioTime })
                    let tsNum = activeTS?.numerator ?? baseNum
                    let tsDen = activeTS?.denominator ?? baseDen
                    bars = Self.measureCount(
                        inSourceGrid: srcGrid,
                        audioStart: srcStart,
                        duration: sec.duration,
                        fallbackBPM: fallbackBPM,
                        timeSignatureNumerator: tsNum,
                        timeSignatureDenominator: tsDen
                    )
                }
                list[i].startMeasure = currentMeasure
                list[i].measureCount = bars
                currentMeasure += bars
            }
        }
        
        reconcile(&sections)
        if !defaultSections.isEmpty {
            reconcile(&defaultSections)
        }
        for idx in 0..<savedArrangements.count {
            reconcile(&savedArrangements[idx].sections)
        }
    }
    
    /// Builds the effective beat grid in arrangement timeline coordinates, incorporating mid-song
    /// `timeSignatureChanges`, rearranged/trimmed sections, and Click Sections.
    public func effectiveBeatGrid(totalDuration: TimeInterval) -> [BeatGridMarker] {
        let srcGrid = sourceBeatGrid(upToDuration: totalDuration)
        guard !srcGrid.isEmpty else { return [] }
        
        let sortedSections = sections.sorted { $0.startTime < $1.startTime }
        let isLinear = sortedSections.isEmpty || sortedSections.allSatisfy {
            !$0.effectiveIsClickSection && abs($0.startTime - $0.sourceAudioStartTime) < 0.008
        }
        if isLinear {
            return srcGrid
        }
        
        var outMarkers: [BeatGridMarker] = []
        outMarkers.reserveCapacity(srcGrid.count)
        var currentBar = 0
        var prevSourceEnd: TimeInterval = 0.0
        
        for sec in sortedSections {
            guard sec.duration > 0.02 else { continue }
            let isBlankClick = sec.effectiveIsClickSection &&
                (sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click section" || sec.abbreviation == "CLK")
            
            if isBlankClick {
                let (tsNum, tsDen) = timeSignature(atSourceTime: prevSourceEnd)
                let bars = max(1, sec.measureCount)
                let num = max(1, tsNum)
                let beatsTotal = bars * num
                let beatDur = sec.duration / Double(max(1, beatsTotal))
                let instBPM = (60.0 / max(0.05, beatDur)) * (4.0 / Double(max(1, tsDen)))
                for b in 0..<bars {
                    currentBar += 1
                    for beatInBar in 1...num {
                        let beatOffset = Double(b * num + (beatInBar - 1)) * beatDur
                        outMarkers.append(BeatGridMarker(
                            time: sec.startTime + beatOffset,
                            bar: currentBar,
                            beat: beatInBar,
                            instantaneousBPM: instBPM,
                            timeSignatureNumerator: tsNum,
                            timeSignatureDenominator: tsDen
                        ))
                    }
                }
                continue
            }
            
            let srcStart = sec.sourceAudioStartTime
            let srcEnd = srcStart + sec.duration
            let winStart = srcStart - 0.02
            let winEnd = srcEnd - 0.02
            
            var sectionMarkers: [BeatGridMarker] = []
            for m in srcGrid {
                if m.time >= winStart && m.time < winEnd {
                    sectionMarkers.append(m)
                } else if m.time >= winEnd {
                    break
                }
            }
            
            if !sectionMarkers.isEmpty {
                var isFirstInSection = true
                for m in sectionMarkers {
                    let arrTime = sec.startTime + max(0.0, m.time - srcStart)
                    if m.beat == 1 || isFirstInSection {
                        currentBar += 1
                    }
                    isFirstInSection = false
                    outMarkers.append(BeatGridMarker(
                        time: arrTime,
                        bar: max(1, currentBar),
                        beat: m.beat,
                        instantaneousBPM: m.instantaneousBPM,
                        timeSignatureNumerator: m.timeSignatureNumerator,
                        timeSignatureDenominator: m.timeSignatureDenominator
                    ))
                }
            } else {
                // Section lies beyond srcGrid end: synthesize markers at local BPM & meter so Click/Guide never drop out
                let localBPM = instantaneousBPM(atSourceTime: srcStart)
                let (tsNum, tsDen) = timeSignature(atSourceTime: srcStart)
                let beatDur = (60.0 / max(20.0, localBPM)) * (4.0 / Double(max(1, tsDen)))
                let num = max(1, tsNum)
                var t = 0.0
                var beatInBar = 1
                var isFirst = true
                while t < sec.duration - 0.02 && outMarkers.count < 8000 {
                    if beatInBar == 1 || isFirst {
                        currentBar += 1
                        isFirst = false
                    }
                    outMarkers.append(BeatGridMarker(
                        time: sec.startTime + t,
                        bar: max(1, currentBar),
                        beat: beatInBar,
                        instantaneousBPM: localBPM,
                        timeSignatureNumerator: tsNum,
                        timeSignatureDenominator: tsDen
                    ))
                    t += beatDur
                    beatInBar += 1
                    if beatInBar > num { beatInBar = 1 }
                }
            }
            prevSourceEnd = srcEnd
        }
        
        return outMarkers
    }
    
    public func arrangementName(for id: UUID?) -> String {
        guard let id = id,
              let found = savedArrangements.first(where: { $0.id == id }) else {
            return "Default"
        }
        return found.name
    }
    
    /// True when the song's current sections match its pristine Default sections (no cuts, additions, reorderings, or trims)
    public var isCurrentSectionsMatchingDefault: Bool {
        guard !defaultSections.isEmpty else { return true }
        guard sections.count == defaultSections.count else { return false }
        for (sec, def) in zip(sections, defaultSections) {
            if sec.name != def.name ||
               abs(sec.sourceAudioStartTime - def.sourceAudioStartTime) > 0.01 ||
               abs(sec.duration - def.duration) > 0.01 ||
               sec.isTrimmed {
                return false
            }
        }
        return true
    }
    
    public init(
        id: UUID = UUID(),
        title: String = "Untitled Song",
        artist: String = "Unknown Artist",
        bpm: Double = 128.0,
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
        defaultMidiCues: [MIDICue]? = nil,
        defaultDirectionalCues: [DirectionalCue]? = nil,
        defaultAutomationPoints: [AutomationPoint]? = nil,
        defaultSmpteCue: SMPTECue? = nil,
        stemURLs: [URL] = [],
        timeSignatureChanges: [TimeSignatureChange] = [],
        tempoEvents: [TempoChangeEvent] = [],
        beatGrid: [BeatGridMarker] = [],
        midiCues: [MIDICue] = [],
        directionalCues: [DirectionalCue] = [],
        automationPoints: [AutomationPoint] = [],
        smpteCue: SMPTECue? = nil,
        proPresenterPlaylist: Int? = nil,
        proPresenterPlaylistItem: Int? = nil,
        transitionType: SongTransitionType = .cueNextSong,
        continuePad: Bool = false,
        continueClick: Bool = false,
        cueNextSongSection: Bool = false,
        endFadeOutEnabled: Bool = false,
        fadeEndSectionEnabled: Bool = false,
        startPadWithSong: Bool = false,
        padPresetId: String? = nil,
        padIntroOutroOnly: Bool = false,
        artworkData: Data? = nil,
        clickSource: ClickSource = .generated,
        guideSource: GuideSource = .generated,
        guideVoice: GuideVoice = GuideVoice.defaultVoice,
        guideFallbackVoice: GuideVoice = CustomSampleLibraryManager.shared.defaultGuideFallbackVoice,
        clickSound: ClickSoundType = ClickSoundType.defaultSound,
        usesDefaultClickSound: Bool = true,
        usesDefaultGuideVoice: Bool = true,
        clickAccentEnabled: Bool = true,
        clickQuarterEnabled: Bool = true,
        clickEighthEnabled: Bool = true,
        clickSixteenthEnabled: Bool = false,
        clickAccentVolume: Float = 0.80,
        clickQuarterVolume: Float = 0.80,
        clickEighthVolume: Float = 0.70,
        clickSixteenthVolume: Float = 0.0,
        guideCountInEnabled: Bool = true,
        speakDirectionalCuesOnUploadedGuide: Bool = true,
        guideSectionsVolume: Float = 0.80,
        guideSectionsEnabled: Bool = true,
        guideDirectionsVolume: Float = 0.80,
        guideDirectionsEnabled: Bool = true,
        guideFallbackVolume: Float = 0.80,
        guideFallbackEnabled: Bool = true,
        autoInfiniteLoop: Bool = false,
        excludesClickAndGuide: Bool = false
    ) {
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
        self.defaultMidiCues = defaultMidiCues ?? (activeArrangementId == nil ? midiCues : [])
        self.defaultDirectionalCues = defaultDirectionalCues ?? (activeArrangementId == nil ? directionalCues : [])
        self.defaultAutomationPoints = defaultAutomationPoints ?? (activeArrangementId == nil ? automationPoints : [])
        self.defaultSmpteCue = defaultSmpteCue ?? smpteCue
        self.stemURLs = stemURLs
        self.timeSignatureChanges = timeSignatureChanges.sorted { $0.audioTime < $1.audioTime }
        self.tempoEvents = tempoEvents.sorted { $0.audioTime < $1.audioTime }
        self.beatGrid = beatGrid
        self.midiCues = midiCues
        self.directionalCues = directionalCues
        self.automationPoints = automationPoints
        self.smpteCue = smpteCue
        self.proPresenterPlaylist = proPresenterPlaylist
        self.proPresenterPlaylistItem = proPresenterPlaylistItem
        self.transitionType = transitionType
        self.continuePad = continuePad
        self.continueClick = continueClick
        self.cueNextSongSection = cueNextSongSection
        self.endFadeOutEnabled = endFadeOutEnabled
        self.fadeEndSectionEnabled = fadeEndSectionEnabled
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
        self.guideSectionsVolume = guideSectionsVolume
        self.guideSectionsEnabled = guideSectionsEnabled
        self.guideDirectionsVolume = guideDirectionsVolume
        self.guideDirectionsEnabled = guideDirectionsEnabled
        self.guideFallbackVolume = guideFallbackVolume
        self.guideFallbackEnabled = guideFallbackEnabled
        self.autoInfiniteLoop = autoInfiniteLoop
        self.excludesClickAndGuide = excludesClickAndGuide
        
        if !self.beatGrid.isEmpty || !self.timeSignatureChanges.isEmpty || !self.tempoEvents.isEmpty {
            self.reconcileSectionMeasuresWithBeatGrid()
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, artist, bpm, originalBPM, timeSignatureNumerator, timeSignatureDenominator, timeSignatureChanges, tempoEvents, musicalKey, transposeSemitones, preserveVocalFormants, sections, defaultSections, savedArrangements, activeArrangementId, defaultMidiCues, defaultDirectionalCues, defaultAutomationPoints, defaultSmpteCue, stemURLs, beatGrid, midiCues, directionalCues, automationPoints, smpteCue, proPresenterPlaylist, proPresenterPlaylistItem, transitionType, continuePad, continueClick, cueNextSongSection, endFadeOutEnabled, fadeEndSectionEnabled, startPadWithSong, padPresetId, padIntroOutroOnly
        case clickSource, guideSource, guideVoice, guideFallbackVoice, clickSound, usesDefaultClickSound, usesDefaultGuideVoice, clickAccentEnabled, clickQuarterEnabled, clickEighthEnabled, clickSixteenthEnabled, clickAccentVolume, clickQuarterVolume, clickEighthVolume, clickSixteenthVolume, guideCountInEnabled, speakDirectionalCuesOnUploadedGuide, guideSectionsVolume, guideSectionsEnabled, guideDirectionsVolume, guideDirectionsEnabled, guideFallbackVolume, guideFallbackEnabled, autoInfiniteLoop, excludesClickAndGuide
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        self.sections = try container.decode([SongSection].self, forKey: .sections)
        let defSecs = try container.decodeIfPresent([SongSection].self, forKey: .defaultSections) ?? []
        self.defaultSections = defSecs.isEmpty ? self.sections : defSecs
        self.savedArrangements = try container.decodeIfPresent([SavedArrangement].self, forKey: .savedArrangements) ?? []
        self.activeArrangementId = try container.decodeIfPresent(UUID.self, forKey: .activeArrangementId)
        self.stemURLs = try container.decodeIfPresent([URL].self, forKey: .stemURLs) ?? []
        self.timeSignatureChanges = (try container.decodeIfPresent([TimeSignatureChange].self, forKey: .timeSignatureChanges) ?? []).sorted { $0.audioTime < $1.audioTime }
        self.tempoEvents = (try container.decodeIfPresent([TempoChangeEvent].self, forKey: .tempoEvents) ?? []).sorted { $0.audioTime < $1.audioTime }
        self.beatGrid = try container.decodeIfPresent([BeatGridMarker].self, forKey: .beatGrid) ?? []
        self.midiCues = try container.decodeIfPresent([MIDICue].self, forKey: .midiCues) ?? []
        self.directionalCues = try container.decodeIfPresent([DirectionalCue].self, forKey: .directionalCues) ?? []
        self.automationPoints = try container.decodeIfPresent([AutomationPoint].self, forKey: .automationPoints) ?? []
        self.smpteCue = try container.decodeIfPresent(SMPTECue.self, forKey: .smpteCue)
        self.defaultMidiCues = try container.decodeIfPresent([MIDICue].self, forKey: .defaultMidiCues) ?? (self.activeArrangementId == nil ? self.midiCues : [])
        self.defaultDirectionalCues = try container.decodeIfPresent([DirectionalCue].self, forKey: .defaultDirectionalCues) ?? (self.activeArrangementId == nil ? self.directionalCues : [])
        self.defaultAutomationPoints = try container.decodeIfPresent([AutomationPoint].self, forKey: .defaultAutomationPoints) ?? (self.activeArrangementId == nil ? self.automationPoints : [])
        self.defaultSmpteCue = try container.decodeIfPresent(SMPTECue.self, forKey: .defaultSmpteCue) ?? (self.activeArrangementId == nil ? self.smpteCue : nil)
        self.proPresenterPlaylist = try container.decodeIfPresent(Int.self, forKey: .proPresenterPlaylist)
        self.proPresenterPlaylistItem = try container.decodeIfPresent(Int.self, forKey: .proPresenterPlaylistItem)
        self.transitionType = try container.decodeIfPresent(SongTransitionType.self, forKey: .transitionType) ?? .cueNextSong
        self.continuePad = try container.decodeIfPresent(Bool.self, forKey: .continuePad) ?? false
        self.continueClick = try container.decodeIfPresent(Bool.self, forKey: .continueClick) ?? false
        self.cueNextSongSection = try container.decodeIfPresent(Bool.self, forKey: .cueNextSongSection) ?? false
        self.endFadeOutEnabled = try container.decodeIfPresent(Bool.self, forKey: .endFadeOutEnabled) ?? false
        self.fadeEndSectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .fadeEndSectionEnabled) ?? false
        self.startPadWithSong = try container.decodeIfPresent(Bool.self, forKey: .startPadWithSong) ?? false
        self.padPresetId = try container.decodeIfPresent(String.self, forKey: .padPresetId)
        self.padIntroOutroOnly = try container.decodeIfPresent(Bool.self, forKey: .padIntroOutroOnly) ?? false
        self.clickSource = try container.decodeIfPresent(ClickSource.self, forKey: .clickSource) ?? .generated
        self.guideSource = try container.decodeIfPresent(GuideSource.self, forKey: .guideSource) ?? .generated
        let decodedGuideVoice = try container.decodeIfPresent(GuideVoice.self, forKey: .guideVoice)
        let decodedClickSound = try container.decodeIfPresent(ClickSoundType.self, forKey: .clickSound)
        self.guideVoice = decodedGuideVoice ?? GuideVoice.defaultVoice
        self.guideFallbackVoice = try container.decodeIfPresent(GuideVoice.self, forKey: .guideFallbackVoice) ?? CustomSampleLibraryManager.shared.defaultGuideFallbackVoice
        self.clickSound = decodedClickSound ?? ClickSoundType.defaultSound
        self.usesDefaultClickSound = try container.decodeIfPresent(Bool.self, forKey: .usesDefaultClickSound) ?? (decodedClickSound == nil)
        self.usesDefaultGuideVoice = try container.decodeIfPresent(Bool.self, forKey: .usesDefaultGuideVoice) ?? (decodedGuideVoice == nil)
        self.clickAccentEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickAccentEnabled) ?? true
        self.clickQuarterEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickQuarterEnabled) ?? true
        self.clickEighthEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickEighthEnabled) ?? true
        self.clickSixteenthEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickSixteenthEnabled) ?? false
        self.clickAccentVolume = try container.decodeIfPresent(Float.self, forKey: .clickAccentVolume) ?? 0.80
        self.clickQuarterVolume = try container.decodeIfPresent(Float.self, forKey: .clickQuarterVolume) ?? 0.80
        self.clickEighthVolume = try container.decodeIfPresent(Float.self, forKey: .clickEighthVolume) ?? 0.70
        self.clickSixteenthVolume = try container.decodeIfPresent(Float.self, forKey: .clickSixteenthVolume) ?? 0.0
        self.guideCountInEnabled = try container.decodeIfPresent(Bool.self, forKey: .guideCountInEnabled) ?? true
        self.speakDirectionalCuesOnUploadedGuide = try container.decodeIfPresent(Bool.self, forKey: .speakDirectionalCuesOnUploadedGuide) ?? true
        self.guideSectionsVolume = try container.decodeIfPresent(Float.self, forKey: .guideSectionsVolume) ?? 0.80
        self.guideSectionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .guideSectionsEnabled) ?? true
        self.guideDirectionsVolume = try container.decodeIfPresent(Float.self, forKey: .guideDirectionsVolume) ?? 0.80
        self.guideDirectionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .guideDirectionsEnabled) ?? true
        self.guideFallbackVolume = try container.decodeIfPresent(Float.self, forKey: .guideFallbackVolume) ?? 0.80
        self.guideFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .guideFallbackEnabled) ?? true
        self.autoInfiniteLoop = try container.decodeIfPresent(Bool.self, forKey: .autoInfiniteLoop) ?? false
        self.excludesClickAndGuide = try container.decodeIfPresent(Bool.self, forKey: .excludesClickAndGuide) ?? false
        
        if !self.beatGrid.isEmpty || !self.timeSignatureChanges.isEmpty || !self.tempoEvents.isEmpty {
            self.reconcileSectionMeasuresWithBeatGrid()
        }
    }
    
    /// Estimated or actual duration of the song's count-in intro section
    public var countInDuration: TimeInterval {
        if let countSec = sections.first(where: {
            $0.abbreviation == "Co" || $0.name.localizedCaseInsensitiveContains("count")
        }) {
            return countSec.duration
        }
        if !beatGrid.isEmpty {
            let downbeats = beatGrid.filter { $0.isDownbeat }.sorted { $0.time < $1.time }
            if downbeats.count >= 2 {
                let firstBarDur = downbeats[1].time - downbeats[0].time
                if firstBarDur > 0.1 { return firstBarDur }
            }
            let firstBPM = beatGrid[0].instantaneousBPM > 20.0 ? beatGrid[0].instantaneousBPM : max(20.0, bpm)
            let beatScale = 4.0 / Double(max(1, timeSignatureDenominator))
            return Double(max(1, timeSignatureNumerator)) * (60.0 / firstBPM) * beatScale
        }
        // Fallback: 1 bar at song BPM and time signature
        let beats = Double(timeSignatureNumerator)
        let safeBpm = max(20.0, bpm)
        return (beats * 60.0) / safeBpm
    }
    
    /// Fast binary search for the active beat marker at a given timestamp
    public func activeMarker(at time: TimeInterval) -> BeatGridMarker? {
        guard !beatGrid.isEmpty else { return nil }
        let target = time + 0.008 // 8ms lookahead tolerance for exact transient alignment
        var low = 0
        var high = beatGrid.count - 1
        var bestIdx = 0
        while low <= high {
            let mid = (low + high) / 2
            if beatGrid[mid].time <= target {
                bestIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return beatGrid[bestIdx]
    }
    
    public var totalDuration: TimeInterval {
        sections.map { $0.endTime }.max() ?? (Double(sections.reduce(0) { $0 + $1.measureCount } * 4) * (60.0 / bpm))
    }
    
    public var formattedDuration: String {
        let sec = Int(totalDuration)
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    public func isContinueClickEffective(isLastSongInSetlist: Bool) -> Bool {
        guard continueClick && !excludesClickAndGuide else { return false }
        if isLastSongInSetlist { return true }
        switch transitionType {
        case .cueNextSong, .cueFirstSong, .stayInSong:
            return true
        case .autoLink, .overlap, .crossfade:
            return false
        }
    }

    public func isCueNextSongSectionEffective(isLastSongInSetlist: Bool) -> Bool {
        guard cueNextSongSection && !excludesClickAndGuide && !isLastSongInSetlist else { return false }
        switch transitionType {
        case .autoLink, .overlap, .crossfade:
            return true
        case .cueNextSong, .stayInSong, .cueFirstSong:
            return false
        }
    }
}

/// A setlist containing an ordered collection of songs
public struct Setlist: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var date: Date
    public var serviceType: String?
    public var serviceTime: String?
    public var scheduledDate: Date?
    public var songs: [Song]
    
    public init(
        id: UUID = UUID(),
        name: String = "Sunday Morning Set",
        date: Date = Date(),
        serviceType: String? = nil,
        serviceTime: String? = nil,
        scheduledDate: Date? = nil,
        songs: [Song] = []
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.serviceType = serviceType
        self.serviceTime = serviceTime
        self.scheduledDate = scheduledDate ?? date
        self.songs = songs
    }
    
    public var totalSongsCount: Int {
        songs.count
    }
    
    public var totalDuration: TimeInterval {
        songs.reduce(0.0) { $0 + ($1.sections.last?.endTime ?? 0.0) }
    }
    
    public var formattedDuration: String {
        let total = Int(totalDuration)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
    
    public var formattedDate: String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: scheduledDate ?? date)
    }
    
    public var formattedUserDateTime: String {
        let targetDate = scheduledDate ?? date
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        let datePart = df.string(from: targetDate)
        if let time = serviceTime, !time.isEmpty, time.lowercased() != "none" {
            return "\(datePart) at \(time)"
        } else {
            let tf = DateFormatter()
            tf.dateFormat = "h:mm a"
            return "\(datePart) at \(tf.string(from: targetDate))"
        }
    }
    
    public var totalDurationFormatted: String {
        let totalSec = Int(songs.reduce(0) { $0 + $1.totalDuration })
        return String(format: "%d:%02d", totalSec / 60, totalSec % 60)
    }
}
