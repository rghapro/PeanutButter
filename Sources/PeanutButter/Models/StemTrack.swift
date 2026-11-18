import Foundation
import SwiftUI

/// Functional role of an audio track within the worship multitrack arrangement
public enum TrackRole: String, CaseIterable, Identifiable, Sendable, Codable {
    case stem = "Stem"
    case click = "Click"
    case guide = "Guide"
    case pad = "Pad"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .click: return "metronome.fill"
        case .guide: return "person.wave.2.fill"
        case .pad: return "waveform"
        case .stem: return "music.note"
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .click: return Color.purple
        case .guide: return Color.yellow
        case .pad: return Color.green
        case .stem: return Color.blue
        }
    }
}

/// Represents an individual audio stem within a multitrack arrangement
public final class StemTrack: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: UUID
    @Published public var name: String {
        didSet {
            if name != oldValue {
                refreshCachedRoleFlags()
            }
        }
    }
    @Published public var role: TrackRole {
        didSet {
            if role != oldValue {
                refreshCachedRoleFlags()
            }
        }
    }
    public private(set) var isClickTrackCached: Bool = false
    public private(set) var isGuideTrackCached: Bool = false
    public var fileURL: URL?
    /// Original lossless source file URL (e.g., .wav) retained for high-quality offline pitch/tempo rendering even when playback uses cached .m4a
    public var sourceFileURL: URL?
    
    // Normalized fader position (0.0 to 1.0)
    // 0.0 = -inf dB
    // 0.80 = 0.0 dB (Unity Gain)
    // 1.0 = +6.0 dB
    @Published public var volume: Float = 0.80
    @Published public var pan: Float = 0.0 // -1.0 (Left) to 1.0 (Right)
    @Published public var isMuted: Bool = false
    @Published public var isSoloed: Bool = false
    @Published public var isSoloSafe: Bool = false
    @Published public var routing: OutputRoutingOption = .mainOut
    @Published public var assignedBusName: String = "Tracks"
    
    // Exclude click/guide from waveform rendering
    @Published public var includeInWaveform: Bool
    
    // Real-time Audio VU Meter levels (isolated into `meter` so ChannelStripView never re-evaluates on meter ticks)
    public let meter = StereoMeterModel()
    public var peakLevelLeft: Float = 0.0
    public var peakLevelRight: Float = 0.0
    public var rawPeakL: Float = 0.0
    public var rawPeakR: Float = 0.0
    
    public var duration: TimeInterval = 0.0
    public var waveformPeaks: [Float] = []
    
    public init(
        id: UUID = UUID(),
        name: String,
        role: TrackRole = .stem,
        fileURL: URL? = nil,
        sourceFileURL: URL? = nil,
        volume: Float = 0.80, // Defaults to 0 dB (80% travel)
        pan: Float = 0.0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isSoloSafe: Bool = false,
        routing: OutputRoutingOption? = nil,
        assignedBusName: String? = nil,
        includeInWaveform: Bool? = nil
    ) {
        self.id = id
        let normalizedName = StemTrack.abbreviatedDisplayName(for: name)
        self.name = normalizedName
        
        // Auto-detect role from track name if default .stem was provided
        let resolvedRole: TrackRole
        if role == .stem {
            resolvedRole = StemTrack.autoDetectRole(for: normalizedName)
        } else {
            resolvedRole = role
        }
        self.role = resolvedRole
        
        self.fileURL = fileURL
        self.sourceFileURL = sourceFileURL ?? fileURL
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isSoloSafe = isSoloSafe
        self.routing = routing ?? (resolvedRole == .click ? .clickOut : resolvedRole == .guide ? .guideOut : .mainOut)
        self.assignedBusName = assignedBusName ?? StemTrack.autoAssignBus(for: name)
        
        // Auto-detect click/guide/tick/metronome/cue in name and exclude from waveform
        if let inc = includeInWaveform {
            self.includeInWaveform = inc
        } else {
            let lower = name.lowercased()
            let isClickOrGuide = resolvedRole == .click || resolvedRole == .guide ||
                lower.contains("click") || lower.contains("guide") ||
                lower.contains("metronome") || lower.contains("tick") ||
                lower.contains("cue") || lower.contains("count")
            self.includeInWaveform = !isClickOrGuide
        }
        refreshCachedRoleFlags()
    }

    private func refreshCachedRoleFlags() {
        isClickTrackCached = (role == .click || StemCategory.category(for: name, role: role) == .click)
        isGuideTrackCached = (role == .guide || StemCategory.category(for: name, role: role) == .guide)
    }
    
    /// Auto-shortens verbose background vocal names (e.g. "Background Vocals 1", "Backing Vocal 2") to "BGVS" / "BGVS 1" / "BGVS 2".
    public static func abbreviatedDisplayName(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:background\s+vocals?|backing\s+vocals?|back\s+vocals?|bg\s+vocals?|bgvs?)(?:\s*[-_]*\s*(.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return rawName
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
            return rawName
        }
        if match.numberOfRanges > 1,
           let suffixRange = Range(match.range(at: 1), in: trimmed) {
            let suffix = trimmed[suffixRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                return "BGVS \(suffix)"
            }
        }
        return "BGVS"
    }
    
    /// Auto-detects track role from name
    public static func autoDetectRole(for trackName: String) -> TrackRole {
        let lower = trackName.lowercased()
        if lower.contains("click") || lower.contains("accent") || lower.contains("1/4") || lower.contains("1/8") || lower.contains("1/16") || lower.contains("metronome") || lower.contains("tick") {
            return .click
        } else if lower.contains("guide") || lower.contains("cue") || lower.contains("count") {
            return .guide
        } else if lower.contains("pad") {
            return .pad
        } else {
            return .stem
        }
    }
    
    /// Smart bus assignment matching MultiTracks Playback's 16 official busses:
    /// Click, Guide, Drums, Percussion, Loops, Bass, Piano, Keys, Electric Guitars, Acoustic Guitars, Strings, Horns, Pad, Vocals, FX, Aux
    public static func autoAssignBus(for trackName: String) -> String {
        let lower = trackName.lowercased()
        
        // 1. Click
        if lower.contains("click") || lower.contains("accent") || lower.contains("1/4") || lower.contains("1/8") || lower.contains("1/16") || lower.contains("metronome") || lower.contains("tick") {
            return "Click"
        }
        
        // 2. Guide
        if lower.contains("guide") || lower.contains("cue") || lower.contains("count") || lower.contains("spoken") {
            return "Guide"
        }
        
        // 3. Drums
        if lower.contains("drum") || lower.contains("kick") || lower.contains("snare") || lower.contains("tom") || lower.contains("hat") || lower.contains("cymbal") || lower.contains("overhead") || lower.contains("ride") || lower.contains("crash") {
            return "Drums"
        }
        
        // 4. Loops (prioritized when explicitly loops/beats)
        if lower.contains("loop") || lower.contains("synloop") || lower.contains("beat") || lower.contains("groove") {
            return "Loops"
        }
        
        // 5. Percussion
        if lower.contains("perc") || lower.contains("tamb") || lower.contains("shaker") || lower.contains("clap") || lower.contains("conga") || lower.contains("bongo") || lower.contains("timbal") || lower.contains("djembe") || lower.contains("cowbell") {
            return "Percussion"
        }
        
        // 6. Bass
        if lower.contains("sbass") || lower.contains("bass") || lower.contains("sub") || lower.contains("808") {
            return "Bass"
        }
        
        // 7. Piano
        if lower.contains("piano") || lower.contains("grand") || lower.contains("upright") || lower.contains("pno") {
            return "Piano"
        }
        
        // 8. Acoustic Guitars
        if lower.contains("acoustic") || lower.contains("ac gtr") || lower.contains("nylon") || lower.contains("12 string") || lower.contains("banjo") || lower.contains("mandolin") || lower.contains("ukulele") || lower == "ag" || lower.hasPrefix("ag ") || lower.hasPrefix("ag_") || lower.hasPrefix("ag1") || lower.hasPrefix("ag2") || lower.contains(" ag ") {
            return "Acoustic Guitars"
        }
        
        // 9. Electric Guitars
        if lower.contains("electric") || lower.contains("e.gtr") || lower.contains("lead gtr") || lower.contains("rhythm gtr") || lower.contains("guitar") || lower.contains("gtr") || lower == "eg" || lower.hasPrefix("eg ") || lower.hasPrefix("eg_") || lower.hasPrefix("eg1") || lower.hasPrefix("eg2") || lower.hasPrefix("eg3") || lower.hasPrefix("eg4") || lower.hasPrefix("eg5") || lower.hasPrefix("eg6") || lower.contains(" eg ") {
            return "Electric Guitars"
        }
        
        // 10. Strings (Violins, Cellos, Violas, Orchestral)
        if lower.contains("string") || lower.contains("violin") || lower.contains("cello") || lower.contains("viola") || lower.contains("orchestra") || lower.contains("quartet") || lower.contains("fiddle") {
            return "Strings"
        }
        
        // 11. Horns (Brass, Woodwinds, Trumpet, Sax, Trombone)
        if lower.contains("horn") || lower.contains("brass") || lower.contains("trumpet") || lower.contains("sax") || lower.contains("woodwind") || lower.contains("flute") || lower.contains("trombone") || lower.contains("clarinet") || lower.contains("oboe") {
            return "Horns"
        }
        
        // 12. Pad (Ambient drones & atmospheric textures — but Synth Pad routes to Keys)
        if lower.contains("synth pad") {
            return "Keys"
        }
        if lower.contains("pad") || lower.contains("ambient") || lower.contains("drone") || lower.contains("atmosphere") {
            return "Pad"
        }
        
        // 13. Keys (Rhodes, Organ, Synths, Arps)
        if lower.contains("rhodes") || lower.contains("organ") || lower.contains("b3") || lower.contains("wurl") || lower.contains("keys") || lower.contains("synth") || lower.contains("arp") || lower.contains("clav") || lower.contains("lead") {
            return "Keys"
        }
        
        // 14. Vocals
        if lower.contains("vox") || lower.contains("vocal") || lower.contains("bgv") || lower.contains("choir") || lower.contains("harm") || lower.contains("back") || lower.contains("sing") {
            return "Vocals"
        }
        
        // 15. FX
        if lower.contains("fx") || lower.contains("sfx") || lower.contains("sweep") || lower.contains("riser") || lower.contains("hit") || lower.contains("drop") || lower.contains("swell") || lower.contains("noise") {
            return "FX"
        }
        
        // 16. Aux
        if lower.contains("aux") || lower.contains("track") || lower.contains("stem") {
            return "Aux"
        }
        
        return "Aux"
    }
    
    /// Calculated linear gain for AVAudioMixerNode outputVolume (Logarithmic taper)
    public var linearGain: Float {
        if volume <= 0.001 { return 0.0 }
        if volume >= 0.80 {
            let db = ((volume - 0.80) / 0.20) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = volume / 0.80
            return pow(norm, 2.0)
        }
    }
    
    /// Calculated gain in decibels: 0.0 -> -inf dB, 0.80 -> 0.0 dB, 1.0 -> +6.0 dB (Logarithmic scale)
    public var volumeInDecibels: Float {
        if volume <= 0.001 { return -80.0 }
        if volume >= 0.80 {
            return ((volume - 0.80) / 0.20) * 6.0
        } else {
            let norm = max(0.001, volume / 0.80)
            let db = 40.0 * log10(norm)
            return max(-60.0, db)
        }
    }
    
    public var dbFormattedString: String {
        if volume <= 0.01 { return "-∞" }
        let db = volumeInDecibels
        if abs(db) < 0.2 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }

    /// Creates an independent `StemTrack` instance with a fresh `UUID` while preserving mix/routing metadata.
    public func cloneWithNewId() -> StemTrack {
        let resolvedFileURL: URL? = {
            if let existing = fileURL { return existing }
            if PlaybackFileManager.shared.hasValidCachedStem(for: id) {
                return PlaybackFileManager.shared.cachedStemURL(for: id)
            }
            return nil
        }()
        let copy = StemTrack(
            id: UUID(),
            name: name,
            role: role,
            fileURL: resolvedFileURL,
            sourceFileURL: sourceFileURL ?? resolvedFileURL,
            volume: volume,
            pan: pan,
            isMuted: isMuted,
            isSoloed: isSoloed,
            isSoloSafe: isSoloSafe,
            routing: routing,
            assignedBusName: assignedBusName,
            includeInWaveform: includeInWaveform
        )
        copy.duration = duration
        copy.waveformPeaks = waveformPeaks
        return copy
    }
}
