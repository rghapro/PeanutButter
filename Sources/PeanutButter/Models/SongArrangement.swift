import Foundation
import SwiftUI

/// Musical section in an arrangement (Intro, Verse, Chorus, etc.)
public struct SongSection: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var abbreviation: String
    public var startTime: TimeInterval
    public var audioStartTime: TimeInterval?
    public var duration: TimeInterval
    public var startMeasure: Int
    public var measureCount: Int
    
    // Non-destructive trim properties
    public var originalAudioStartTime: TimeInterval?
    public var originalDuration: TimeInterval?
    public var leadingTrimDuration: TimeInterval
    public var trailingTrimDuration: TimeInterval
    
    // Guide cue and count-in toggles
    public var playSectionGuideCue: Bool
    public var playSectionCountIn: Bool
    public var includeNumberInGuide: Bool
    
    // Click Section mode (mutes all musical instrument stems, plays Click + Guide + Pad only)
    public var isClickSection: Bool
    
    public var effectiveIsClickSection: Bool {
        isClickSection || name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click section"
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        abbreviation: String? = nil,
        startTime: TimeInterval,
        audioStartTime: TimeInterval? = nil,
        duration: TimeInterval,
        startMeasure: Int = 1,
        measureCount: Int = 8,
        originalAudioStartTime: TimeInterval? = nil,
        originalDuration: TimeInterval? = nil,
        leadingTrimDuration: TimeInterval = 0.0,
        trailingTrimDuration: TimeInterval = 0.0,
        playSectionGuideCue: Bool = true,
        playSectionCountIn: Bool = true,
        includeNumberInGuide: Bool? = nil,
        isClickSection: Bool = false
    ) {
        self.id = id
        self.name = name
        self.abbreviation = SongSection.abbreviation(for: name)
        self.startTime = startTime
        self.audioStartTime = audioStartTime ?? startTime
        self.duration = duration
        self.startMeasure = startMeasure
        self.measureCount = measureCount
        self.originalAudioStartTime = originalAudioStartTime ?? audioStartTime ?? startTime
        self.originalDuration = originalDuration ?? duration
        self.leadingTrimDuration = leadingTrimDuration
        self.trailingTrimDuration = trailingTrimDuration
        self.playSectionGuideCue = playSectionGuideCue
        self.playSectionCountIn = playSectionCountIn
        self.includeNumberInGuide = includeNumberInGuide ?? UserDefaults.standard.bool(forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        self.isClickSection = isClickSection
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, abbreviation, startTime, audioStartTime, duration, startMeasure, measureCount
        case originalAudioStartTime, originalDuration, leadingTrimDuration, trailingTrimDuration
        case playSectionGuideCue, playSectionCountIn, includeNumberInGuide, isClickSection
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let decodedAbbrev = try container.decodeIfPresent(String.self, forKey: .abbreviation)
        self.abbreviation = SongSection.abbreviation(for: self.name.isEmpty ? (decodedAbbrev ?? "") : self.name)
        self.startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        self.audioStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .audioStartTime)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.startMeasure = try container.decode(Int.self, forKey: .startMeasure)
        self.measureCount = try container.decode(Int.self, forKey: .measureCount)
        
        let origAudio = try container.decodeIfPresent(TimeInterval.self, forKey: .originalAudioStartTime)
        let origDur = try container.decodeIfPresent(TimeInterval.self, forKey: .originalDuration)
        self.originalAudioStartTime = origAudio ?? self.audioStartTime ?? self.startTime
        self.originalDuration = origDur ?? self.duration
        self.leadingTrimDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .leadingTrimDuration) ?? 0.0
        self.trailingTrimDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .trailingTrimDuration) ?? 0.0
        self.playSectionGuideCue = try container.decodeIfPresent(Bool.self, forKey: .playSectionGuideCue) ?? true
        self.playSectionCountIn = try container.decodeIfPresent(Bool.self, forKey: .playSectionCountIn) ?? true
        self.includeNumberInGuide = try container.decodeIfPresent(Bool.self, forKey: .includeNumberInGuide) ?? UserDefaults.standard.bool(forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        self.isClickSection = try container.decodeIfPresent(Bool.self, forKey: .isClickSection) ?? false
    }
    
    public var sourceAudioStartTime: TimeInterval {
        audioStartTime ?? startTime
    }
    
    public var baseAudioStartTime: TimeInterval {
        originalAudioStartTime ?? audioStartTime ?? startTime
    }
    
    public var baseDuration: TimeInterval {
        originalDuration ?? duration
    }
    
    public var isTrimmed: Bool {
        leadingTrimDuration > 0.001 || trailingTrimDuration > 0.001
    }
    
    public var endTime: TimeInterval {
        startTime + duration
    }
    
    /// Standardized shorthand abbreviation for section pills across all songs
    public var displayAbbreviation: String {
        SongSection.abbreviation(for: name.isEmpty ? abbreviation : name)
    }
    
    /// Whether this section is a Count In, Intro, or Outro / Ending
    public var isIntroOrOutro: Bool {
        let ab = displayAbbreviation.lowercased()
        let lower = name.lowercased()
        if ab.hasPrefix("co") || lower.contains("count") { return true }
        if ab.hasPrefix("cl") || lower.contains("click") { return true }
        if (ab.hasPrefix("i") && !ab.hasPrefix("it")) || lower.contains("intro") { return true }
        if ab.hasPrefix("o") || ab.hasPrefix("e") || lower.contains("outro") || lower.contains("ending") { return true }
        return false
    }
    
    public static func abbreviation(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let digits = trimmed.filter { $0.isNumber }
        
        if lower.starts(with: "count") || lower.contains("count off") || lower.contains("count in") || lower == "cnt" || lower.starts(with: "cnt") || lower == "co" {
            return "Co"
        }
        if lower.starts(with: "click") || lower == "cl" {
            return "Cl"
        }
        if lower.starts(with: "intro") || lower == "in" || (lower.starts(with: "in") && !lower.starts(with: "inst") && !lower.starts(with: "inter")) || lower == "i" {
            return digits.isEmpty ? "I" : "I\(digits)"
        }
        
        if lower.starts(with: "turnaround") || lower.starts(with: "turn around") || lower == "ta" || lower.starts(with: "ta") {
            return digits.isEmpty ? "Ta" : "Ta\(digits)"
        }
        if lower.starts(with: "interlude") || lower == "int" || (lower.starts(with: "int") && !lower.starts(with: "intro")) || lower == "it" || lower.starts(with: "it") {
            return digits.isEmpty ? "It" : "It\(digits)"
        }
        if lower.starts(with: "instrumental") || lower == "inst" || lower.starts(with: "inst") || lower == "is" || lower.starts(with: "is") {
            return digits.isEmpty ? "Is" : "Is\(digits)"
        }
        if lower.starts(with: "vamp") || lower == "vmp" || lower.starts(with: "vmp") || lower == "vp" || lower.starts(with: "vp") {
            return digits.isEmpty ? "Vp" : "Vp\(digits)"
        }
        if lower.starts(with: "tag") || lower == "tg" || lower.starts(with: "tg") {
            return digits.isEmpty ? "Tg" : "Tg\(digits)"
        }
        if lower.starts(with: "outro") || lower == "out" || lower.starts(with: "out") || lower == "o" {
            return digits.isEmpty ? "O" : "O\(digits)"
        }
        if lower.starts(with: "ending") || lower == "end" || lower.starts(with: "end") || lower == "e" {
            return digits.isEmpty ? "E" : "E\(digits)"
        }
        if lower.starts(with: "solo") || lower == "s" {
            return digits.isEmpty ? "S" : "S\(digits)"
        }
        
        if lower.starts(with: "pre-chorus") || lower.starts(with: "pre chorus") || lower.starts(with: "prechorus") || lower.starts(with: "pre") || lower == "pc" || lower.starts(with: "pc") {
            return digits.isEmpty ? "Pc" : "Pc\(digits)"
        }
        if lower.starts(with: "post-chorus") || lower.starts(with: "post chorus") || lower.starts(with: "postchorus") || lower.starts(with: "post") || lower == "po" || lower.starts(with: "po") {
            return digits.isEmpty ? "Po" : "Po\(digits)"
        }
        if lower.starts(with: "chorus") || lower == "c" || (lower.starts(with: "c") && !digits.isEmpty && trimmed.count <= 3) {
            return digits.isEmpty ? "C" : "C\(digits)"
        }
        if lower.starts(with: "verse") || lower == "v" || (lower.starts(with: "v") && !digits.isEmpty && trimmed.count <= 3) {
            return digits.isEmpty ? "V" : "V\(digits)"
        }
        if lower.starts(with: "bridge") || lower == "br" || lower.starts(with: "br") || lower == "b" || (lower.starts(with: "b") && !digits.isEmpty && trimmed.count <= 3) {
            return digits.isEmpty ? "B" : "B\(digits)"
        }
        if lower.starts(with: "refrain") || lower == "rf" || lower.starts(with: "rf") {
            return digits.isEmpty ? "Rf" : "Rf\(digits)"
        }
        if lower.starts(with: "passage") || lower == "pa" || lower.starts(with: "pa") {
            return digits.isEmpty ? "Pa" : "Pa\(digits)"
        }
        
        // Exact 2-letter tokens like V1, C1, Ta, It, Is, Tg, Vp
        if trimmed.count <= 3 {
            return trimmed.capitalized
        }
        
        // Custom name: first 2 characters capitalized + digits
        let prefixLetters = String(trimmed.prefix(2)).capitalized
        return digits.isEmpty ? prefixLetters : "\(prefixLetters)\(digits)"
    }
    
    private var colorRGB: (r: Int, g: Int, b: Int) {
        let lower = name.lowercased()
        let abbr = abbreviation.lowercased()
        
        // 1. Click / Count Off / Pad (160, 160, 160)
        if lower.contains("count") || lower.contains("click") || lower == "pad" || abbr == "co" || abbr == "cl" || abbr == "p" {
            return (160, 160, 160)
        }
        
        // 2. Specific Vamp variants (Vamp on 1, Vamp on 4, Vamp Bridge, Vamp Chorus, etc.) (0, 150, 255)
        // Must be evaluated before Pre-Chorus, Chorus, Bridge, Verse, Ending, and generic Vamp.
        if (lower.contains("vamp") && lower != "vamp") ||
           abbr == "vb" || abbr == "vc" || abbr == "e1" || abbr == "e4" ||
           abbr == "v1" && lower.contains("vamp") || abbr == "vs" || abbr == "v4" && lower.contains("vamp") ||
           abbr == "vp" && lower.contains("pre") || abbr == "vv" {
            return (0, 150, 255)
        }
        
        // 3. Pre-Chorus (254, 186, 0) - evaluated before Chorus
        if lower.contains("pre-chorus") || lower.contains("pre chorus") || lower.contains("prechorus") ||
           lower.starts(with: "pre") || abbr.starts(with: "pr") || abbr.starts(with: "pc") {
            return (254, 186, 0)
        }
        
        // 4. Post-Chorus / Acapella / Breakdown / Refrain (67, 168, 115) - evaluated before Chorus and Bridge
        if lower.contains("post-chorus") || lower.contains("post chorus") || lower.contains("postchorus") ||
           lower.contains("acapella") || lower.contains("breakdown") || lower.contains("refrain") ||
           abbr.starts(with: "po") || abbr == "ac" || abbr == "bd" || abbr.starts(with: "rf") || abbr == "r" {
            return (67, 168, 115)
        }
        
        // 5. Chorus / Tag (252, 98, 15)
        if lower.contains("chorus") || lower.contains("tag") || abbr.starts(with: "c") && abbr != "cn" || abbr.starts(with: "tg") || abbr == "t" {
            return (252, 98, 15)
        }
        
        // 6. Bridge / Rap (229, 94, 115)
        if lower.contains("bridge") || lower.contains("rap") || abbr.starts(with: "b") || abbr == "rp" {
            return (229, 94, 115)
        }
        
        // 7. Verse / Exhortation (117, 102, 255)
        if lower.contains("verse") || lower.contains("exhortation") || abbr.starts(with: "v") && abbr != "vp" || abbr == "ex" {
            return (117, 102, 255)
        }
        
        // 8. Instrumental / Turnaround (120, 203, 31)
        if lower.contains("instrumental") || lower.contains("turnaround") || abbr == "is" || abbr.starts(with: "ta") {
            return (120, 203, 31)
        }
        
        // 9. Channel / Interlude / Vamp (219, 68, 57)
        if lower.contains("channel") || lower.contains("interlude") || lower.contains("vamp") || lower.contains("passage") ||
           abbr == "cn" || abbr == "it" || abbr == "vp" || abbr == "in" || abbr == "pa" {
            return (219, 68, 57)
        }
        
        // 10. Intro / Outro / Ending / Solo (42, 181, 189)
        if lower.contains("intro") || lower.contains("outro") || lower.contains("ending") || lower.contains("solo") ||
           abbr == "i" || abbr.starts(with: "o") || abbr.starts(with: "e") || abbr == "s" {
            return (42, 181, 189)
        }
        
        return (160, 160, 160)
    }

    /// Exact per-section color matching MultiTracks Playback (sections-en.json)
    public var color: Color {
        let rgb = colorRGB
        return Color(red: Double(rgb.r) / 255.0, green: Double(rgb.g) / 255.0, blue: Double(rgb.b) / 255.0)
    }

    /// Hex string representation (`#rrggbb`) of this section's color for web/Remote rendering.
    public var colorHex: String {
        let rgb = colorRGB
        return String(format: "#%02x%02x%02x", rgb.r, rgb.g, rgb.b)
    }
}

/// A user-saved song arrangement containing section layout and arrangement-specific cues
public struct SavedArrangement: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var sections: [SongSection]
    public var midiCues: [MIDICue]
    public var directionalCues: [DirectionalCue]
    public var automationPoints: [AutomationPoint]
    public var smpteCue: SMPTECue?
    
    public init(
        id: UUID = UUID(),
        name: String,
        sections: [SongSection],
        midiCues: [MIDICue] = [],
        directionalCues: [DirectionalCue] = [],
        automationPoints: [AutomationPoint] = [],
        smpteCue: SMPTECue? = nil
    ) {
        self.id = id
        self.name = name
        self.sections = sections
        self.midiCues = midiCues
        self.directionalCues = directionalCues
        self.automationPoints = automationPoints
        self.smpteCue = smpteCue
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, sections, midiCues, directionalCues, automationPoints, smpteCue
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.sections = try container.decode([SongSection].self, forKey: .sections)
        self.midiCues = try container.decodeIfPresent([MIDICue].self, forKey: .midiCues) ?? []
        self.directionalCues = try container.decodeIfPresent([DirectionalCue].self, forKey: .directionalCues) ?? []
        self.automationPoints = try container.decodeIfPresent([AutomationPoint].self, forKey: .automationPoints) ?? []
        self.smpteCue = try container.decodeIfPresent(SMPTECue.self, forKey: .smpteCue)
    }
}

/// Song arrangement containing stems, tempo, time signature, and sections
public final class SongArrangement: ObservableObject, @unchecked Sendable {
    @Published public var title: String
    @Published public var artist: String
    @Published public var bpm: Double
    @Published public var timeSignatureNumerator: Int
    @Published public var timeSignatureDenominator: Int
    @Published public var musicalKey: String
    @Published public var sections: [SongSection]
    
    public init(
        title: String = "Glorious Day (Live)",
        artist: String = "Passion",
        bpm: Double = 128.0,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        musicalKey: String = "D",
        sections: [SongSection] = []
    ) {
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
        self.musicalKey = musicalKey
        self.sections = sections
    }
    
    public static func defaultDemoSections(bpm: Double = 128.0) -> [SongSection] {
        let secPerBeat = 60.0 / bpm
        let secPerMeasure = secPerBeat * 4.0
        
        // Exact arrangement sections matching MultiTracks Playback:
        // Co (Count In), I (Intro), I (Intro), V1, V2, C (Chorus), Pa (Passage), Rf (Refrain), V3, C, B, O
        return [
            SongSection(name: "Count In", abbreviation: "Co", startTime: 0, duration: secPerMeasure * 2, startMeasure: 1, measureCount: 2),
            SongSection(name: "Intro", abbreviation: "I", startTime: secPerMeasure * 2, duration: secPerMeasure * 4, startMeasure: 3, measureCount: 4),
            SongSection(name: "Intro", abbreviation: "I", startTime: secPerMeasure * 6, duration: secPerMeasure * 4, startMeasure: 7, measureCount: 4),
            SongSection(name: "Verse 1", abbreviation: "V1", startTime: secPerMeasure * 10, duration: secPerMeasure * 8, startMeasure: 11, measureCount: 8),
            SongSection(name: "Verse 2", abbreviation: "V2", startTime: secPerMeasure * 18, duration: secPerMeasure * 8, startMeasure: 19, measureCount: 8),
            SongSection(name: "Chorus", abbreviation: "C", startTime: secPerMeasure * 26, duration: secPerMeasure * 8, startMeasure: 27, measureCount: 8),
            SongSection(name: "Passage", abbreviation: "Pa", startTime: secPerMeasure * 34, duration: secPerMeasure * 4, startMeasure: 35, measureCount: 4),
            SongSection(name: "Refrain", abbreviation: "Rf", startTime: secPerMeasure * 38, duration: secPerMeasure * 4, startMeasure: 39, measureCount: 4),
            SongSection(name: "Verse 3", abbreviation: "V3", startTime: secPerMeasure * 42, duration: secPerMeasure * 8, startMeasure: 43, measureCount: 8),
            SongSection(name: "Chorus 2", abbreviation: "C", startTime: secPerMeasure * 50, duration: secPerMeasure * 8, startMeasure: 51, measureCount: 8),
            SongSection(name: "Bridge", abbreviation: "B", startTime: secPerMeasure * 58, duration: secPerMeasure * 8, startMeasure: 59, measureCount: 8),
            SongSection(name: "Outro", abbreviation: "O", startTime: secPerMeasure * 66, duration: secPerMeasure * 4, startMeasure: 67, measureCount: 4)
        ]
    }
}
