import Foundation

/// Automation point along the timeline that automates Levels, Panning, Mutes, MIDI Mute, and Pad Player
public struct AutomationPoint: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var time: TimeInterval
    public var name: String
    public var transitionBeats: Int // 0 = Instant, 1, 2, ... up to 4 bars
    public var descriptionText: String
    public var sectionId: UUID?
    
    // Target parameters at this automation point
    // Track-level targets: keyed by track.id
    public var trackFaders: [UUID: Float] // volume 0.0 ... 1.0
    public var trackPans: [UUID: Float]   // pan -1.0 ... 1.0
    public var trackMutes: [UUID: Bool]   // isMuted
    
    // Bus-level targets: keyed by bus.name
    public var busFaders: [String: Float] // volume 0.0 ... 1.0
    public var busMutes: [String: Bool]   // isMuted
    
    // Global & Pad Player toggles / targets (nil = unchanged by this automation point)
    public var padActive: Bool?           // nil = unchanged, true = start pad, false = stop pad
    public var padMuted: Bool?            // nil = unchanged, true = mute pad channel, false = unmute
    public var padVolume: Float?          // nil = unchanged, 0.0 ... 1.0
    public var padPan: Float?             // nil = unchanged, -1.0 ... 1.0
    public var padKey: String?            // nil = unchanged, e.g. "C", "Db", ...
    public var padPackId: String?         // nil = unchanged, pad sound pack ID
    public var padLinked: Bool?           // nil = unchanged, true = linked to song key, false = unlinked
    public var midiMuted: Bool?           // nil = unchanged, true = mute MIDI, false = unmute MIDI
    
    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        name: String = "Automation 1",
        transitionBeats: Int = 0,
        descriptionText: String = "",
        sectionId: UUID? = nil,
        trackFaders: [UUID: Float] = [:],
        trackPans: [UUID: Float] = [:],
        trackMutes: [UUID: Bool] = [:],
        busFaders: [String: Float] = [:],
        busMutes: [String: Bool] = [:],
        padActive: Bool? = nil,
        padMuted: Bool? = nil,
        padVolume: Float? = nil,
        padPan: Float? = nil,
        padKey: String? = nil,
        padPackId: String? = nil,
        padLinked: Bool? = nil,
        midiMuted: Bool? = nil
    ) {
        self.id = id
        self.time = time
        self.name = name
        self.transitionBeats = transitionBeats
        self.descriptionText = descriptionText
        self.sectionId = sectionId
        self.trackFaders = trackFaders
        self.trackPans = trackPans
        self.trackMutes = trackMutes
        self.busFaders = busFaders
        self.busMutes = busMutes
        self.padActive = padActive
        self.padMuted = padMuted
        self.padVolume = padVolume
        self.padPan = padPan
        self.padKey = padKey
        self.padPackId = padPackId
        self.padLinked = padLinked
        self.midiMuted = midiMuted
    }
}
