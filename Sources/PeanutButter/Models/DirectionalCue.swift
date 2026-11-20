import Foundation

/// Directional cue marker along the timeline that is spoken aloud by the Guide track
public struct DirectionalCue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var time: TimeInterval
    public var label: String
    public var sectionId: UUID?
    
    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        label: String,
        sectionId: UUID? = nil
    ) {
        self.id = id
        self.time = time
        self.label = label
        self.sectionId = sectionId
    }
}

/// Source selection for the Click track
public enum ClickSource: String, Codable, CaseIterable, Sendable {
    case uploaded = "Uploaded Click"
    case generated = "App Generated"
}

/// Source selection for the Guide track
public enum GuideSource: String, Codable, CaseIterable, Sendable {
    case uploaded = "Uploaded Guide"
    case generated = "App Generated"
}

/// Sub-channels exposed in the slide-out Guide Mixer Tray
public enum GuideSubChannel: String, CaseIterable, Hashable, Sendable, Codable {
    case sections
    case directions
    case fallback

    public static func visibleChannels(for source: GuideSource) -> [GuideSubChannel] {
        switch source {
        case .generated:
            return [.sections, .directions, .fallback]
        case .uploaded:
            return [.directions, .fallback]
        }
    }

    public func displayTitle(for source: GuideSource) -> String {
        switch self {
        case .sections:
            return "Sections"
        case .directions:
            return source == .uploaded ? "Guide" : "Directions"
        case .fallback:
            return "Fallback"
        }
    }

    /// Matches StemTrack.linearGain: 0.0 = -inf, 0.80 = 0.0 dB (unity), 1.0 = +6.0 dB
    public static func linearGain(forFaderVolume volume: Float) -> Float {
        let clamped = max(0.0, min(1.0, volume))
        if clamped <= 0.001 { return 0.0 }
        if clamped >= 0.80 {
            let db = ((clamped - 0.80) / 0.20) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = clamped / 0.80
            return pow(norm, 2.0)
        }
    }
}

/// Time window metadata for a mixed phrase so per-sub-channel Guide VU meters track playback
public struct GuideCueMeterEvent: Sendable, Equatable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let category: GuideSubChannel
    public let usedFallback: Bool

    public init(startTime: TimeInterval, endTime: TimeInterval, category: GuideSubChannel, usedFallback: Bool) {
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.usedFallback = usedFallback
    }
}

/// Click / metronome sound type (built-in MultiTracks clicks, synthesized clicks, and user custom click packs)
public struct ClickSoundType: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public var rawValue: String
    public var id: String { rawValue }
    
    public static let customPrefix = "custom_click:"
    
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    
    // MultiTracks Recorded Clicks
    public static let classic = ClickSoundType(rawValue: "Classic")
    public static let gentle = ClickSoundType(rawValue: "Gentle")
    public static let woodblock = ClickSoundType(rawValue: "Woodblock")
    public static let percussive = ClickSoundType(rawValue: "Percussive")
    public static let blip = ClickSoundType(rawValue: "Blip")
    public static let saw = ClickSoundType(rawValue: "Saw")
    public static let cowbell = ClickSoundType(rawValue: "Cowbell")
    public static let digital = ClickSoundType(rawValue: "Digital")
    
    // Synthesized Metronomes
    public static let synthClassic = ClickSoundType(rawValue: "Classic (Synth)")
    public static let synthWoodblock = ClickSoundType(rawValue: "Woodblock (Synth)")
    public static let beep = ClickSoundType(rawValue: "Beep / Synth")
    public static let sticks = ClickSoundType(rawValue: "Sticks / Rimshot")
    public static let synthCowbell = ClickSoundType(rawValue: "Cowbell (Synth)")
    public static let shaker = ClickSoundType(rawValue: "Shaker")
    public static let tambourine = ClickSoundType(rawValue: "Tambourine")
    
    public static func custom(packId: String) -> ClickSoundType {
        ClickSoundType(rawValue: "\(customPrefix)\(packId)")
    }
    
    public var isCustom: Bool {
        rawValue.hasPrefix(Self.customPrefix)
    }
    
    public var customPackId: String? {
        guard isCustom else { return nil }
        let id = String(rawValue.dropFirst(Self.customPrefix.count))
        return id.isEmpty ? nil : id
    }
    
    public var displayName: String {
        if let packId = customPackId {
            return CustomSampleLibraryManager.shared.clickPack(forId: packId)?.name ?? "Custom Click"
        }
        return rawValue
    }
    
    public var isSampled: Bool {
        if isCustom { return true }
        switch self {
        case .classic, .gentle, .woodblock, .percussive, .blip, .saw, .cowbell, .digital:
            return true
        default:
            return false
        }
    }
    
    public static var sampledClicks: [ClickSoundType] {
        [.classic, .gentle, .woodblock, .percussive, .blip, .saw, .cowbell, .digital]
    }
    
    public static var synthClicks: [ClickSoundType] {
        [.synthClassic, .synthWoodblock, .beep, .sticks, .synthCowbell, .shaker, .tambourine]
    }
    
    public static var allCases: [ClickSoundType] {
        sampledClicks + synthClicks
    }
    
    public static var defaultSound: ClickSoundType {
        CustomSampleLibraryManager.shared.defaultClickSound
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if str == "Classic Click" || str == "Classic" {
            self = .classic
        } else if str == "Woodblock" {
            self = .woodblock
        } else if str == "Cowbell" {
            self = .cowbell
        } else {
            self = ClickSoundType(rawValue: str)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Voice selection for the synthesized Guide track (supports all downloaded, system TTS, and user custom voices)
public struct GuideVoice: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public var rawValue: String
    public var id: String { rawValue }
    
    public static let customPrefix = "custom_guide:"
    
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    
    public static func custom(packId: String) -> GuideVoice {
        GuideVoice(rawValue: "\(customPrefix)\(packId)")
    }
    
    public var isCustom: Bool {
        rawValue.hasPrefix(Self.customPrefix)
    }
    
    public var customPackId: String? {
        guard isCustom else { return nil }
        let id = String(rawValue.dropFirst(Self.customPrefix.count))
        return id.isEmpty ? nil : id
    }
    
    public static var defaultVoice: GuideVoice {
        CustomSampleLibraryManager.shared.defaultGuideVoice
    }
    
    // MultiTracks Pre-recorded Studio Guide Voice
    public static let rita = GuideVoice(rawValue: "Rita")
    
    // United States Siri Voices (Voice 1 through Voice 5 matching macOS Siri settings)
    public static let siriVoice1 = GuideVoice(rawValue: "Quinn")
    public static let siriVoice2 = GuideVoice(rawValue: "Nora")
    public static let siriVoice3 = GuideVoice(rawValue: "Damon")
    public static let siriVoice4 = GuideVoice(rawValue: "Aaron")
    public static let siriVoice5 = GuideVoice(rawValue: "Simone")
    public static let siriNicky = GuideVoice(rawValue: "Nicky")
    
    // International Siri Voices
    public static let siriMartha = GuideVoice(rawValue: "Martha")
    public static let siriArthur = GuideVoice(rawValue: "Arthur")
    public static let siriCatherine = GuideVoice(rawValue: "Catherine")
    public static let siriGordon = GuideVoice(rawValue: "Gordon")
    
    // Premium & Standard Presets
    public static let zoe = GuideVoice(rawValue: "Zoe")
    public static let siriAaron = GuideVoice.siriVoice4
    public static let female = GuideVoice(rawValue: "Samantha")
    public static let male = GuideVoice(rawValue: "Daniel")
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if str == "Voice 1" || str == "Siri Voice 1" || str == "Quinn" {
            self = .siriVoice1
        } else if str == "Voice 2" || str == "Siri Voice 2" || str == "Nora" {
            self = .siriVoice2
        } else if str == "Voice 3" || str == "Siri Voice 3" || str == "Damon" {
            self = .siriVoice3
        } else if str == "Voice 4" || str == "Siri Voice 4" || str == "Aaron" || str == "Siri 2 (US Male)" {
            self = .siriVoice4
        } else if str == "Voice 5" || str == "Siri Voice 5" || str == "Simone" {
            self = .siriVoice5
        } else if str == "Female" || str == "Samantha" {
            self = .female
        } else if str == "Male" || str == "Daniel" {
            self = .male
        } else if str == "Siri 1 (US Female)" || str == "Nicky" {
            self = .siriNicky
        } else if str == "Siri 3 (UK Female)" || str == "Martha" {
            self = .siriMartha
        } else if str == "Siri 4 (UK Male)" || str == "Arthur" {
            self = .siriArthur
        } else if str == "Siri 5 (AU Female)" || str == "Catherine" {
            self = .siriCatherine
        } else if str == "Siri 6 (AU Male)" || str == "Gordon" {
            self = .siriGordon
        } else {
            self = GuideVoice(rawValue: str)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Information describing an installed macOS text-to-speech voice
public struct InstalledVoiceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let localizedLanguage: String
    public let qualityRaw: Int
    public let isSiri: Bool
    public let isNovelty: Bool
    
    public init(
        id: String,
        name: String,
        language: String,
        localizedLanguage: String,
        qualityRaw: Int,
        isSiri: Bool,
        isNovelty: Bool
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.localizedLanguage = localizedLanguage
        self.qualityRaw = qualityRaw
        self.isSiri = isSiri
        self.isNovelty = isNovelty
    }
    
    public var displayName: String {
        var str = name
        if isSiri {
            str += " (Siri · \(localizedLanguage))"
        } else if qualityRaw == 3 {
            str += " (Premium · \(localizedLanguage))"
        } else if qualityRaw == 2 {
            str += " (Enhanced · \(localizedLanguage))"
        } else if isNovelty {
            str += " (Classic · \(localizedLanguage))"
        } else {
            str += " (\(localizedLanguage))"
        }
        return str
    }
}
