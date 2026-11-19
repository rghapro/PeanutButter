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

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case name
        case transitionBeats
        case descriptionText
        case sectionId
        case trackFaders
        case trackPans
        case trackMutes
        case busFaders
        case busMutes
        case padActive
        case padMuted
        case padVolume
        case padPan
        case padKey
        case padPackId
        case padLinked
        case midiMuted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.time = (try container.decodeIfPresent(TimeInterval.self, forKey: .time)) ?? 0.0
        self.name = (try container.decodeIfPresent(String.self, forKey: .name)) ?? "Automation 1"
        self.transitionBeats = (try container.decodeIfPresent(Int.self, forKey: .transitionBeats)) ?? 0
        self.descriptionText = (try container.decodeIfPresent(String.self, forKey: .descriptionText)) ?? ""
        self.sectionId = try container.decodeIfPresent(UUID.self, forKey: .sectionId)

        self.trackFaders = Self.decodeUUIDDictionary(Float.self, from: container, forKey: .trackFaders)
        self.trackPans = Self.decodeUUIDDictionary(Float.self, from: container, forKey: .trackPans)
        self.trackMutes = Self.decodeUUIDDictionary(Bool.self, from: container, forKey: .trackMutes)

        self.busFaders = (try container.decodeIfPresent([String: Float].self, forKey: .busFaders)) ?? [:]
        self.busMutes = (try container.decodeIfPresent([String: Bool].self, forKey: .busMutes)) ?? [:]

        self.padActive = try container.decodeIfPresent(Bool.self, forKey: .padActive)
        self.padMuted = try container.decodeIfPresent(Bool.self, forKey: .padMuted)
        self.padVolume = try container.decodeIfPresent(Float.self, forKey: .padVolume)
        self.padPan = try container.decodeIfPresent(Float.self, forKey: .padPan)
        self.padKey = try container.decodeIfPresent(String.self, forKey: .padKey)
        self.padPackId = try container.decodeIfPresent(String.self, forKey: .padPackId)
        self.padLinked = try container.decodeIfPresent(Bool.self, forKey: .padLinked)
        self.midiMuted = try container.decodeIfPresent(Bool.self, forKey: .midiMuted)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(name, forKey: .name)
        try container.encode(transitionBeats, forKey: .transitionBeats)
        try container.encode(descriptionText, forKey: .descriptionText)
        try container.encodeIfPresent(sectionId, forKey: .sectionId)

        try container.encode(Self.encodeUUIDDictionary(trackFaders), forKey: .trackFaders)
        try container.encode(Self.encodeUUIDDictionary(trackPans), forKey: .trackPans)
        try container.encode(Self.encodeUUIDDictionary(trackMutes), forKey: .trackMutes)

        try container.encode(busFaders, forKey: .busFaders)
        try container.encode(busMutes, forKey: .busMutes)

        try container.encodeIfPresent(padActive, forKey: .padActive)
        try container.encodeIfPresent(padMuted, forKey: .padMuted)
        try container.encodeIfPresent(padVolume, forKey: .padVolume)
        try container.encodeIfPresent(padPan, forKey: .padPan)
        try container.encodeIfPresent(padKey, forKey: .padKey)
        try container.encodeIfPresent(padPackId, forKey: .padPackId)
        try container.encodeIfPresent(padLinked, forKey: .padLinked)
        try container.encodeIfPresent(midiMuted, forKey: .midiMuted)
    }

    private static func encodeUUIDDictionary<Value>(_ map: [UUID: Value]) -> [String: Value] {
        Dictionary(map.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { _, new in new })
    }

    private static func decodeUUIDDictionary<Value: Decodable>(
        _ valueType: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [UUID: Value] {
        if let stringDict = try? container.decodeIfPresent([String: Value].self, forKey: key) {
            var result: [UUID: Value] = [:]
            result.reserveCapacity(stringDict.count)
            for (k, v) in stringDict {
                if let uuid = UUID(uuidString: k) {
                    result[uuid] = v
                }
            }
            return result
        }
        if var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) {
            var result: [UUID: Value] = [:]
            while !unkeyed.isAtEnd {
                guard let keyStr = try? unkeyed.decode(String.self),
                      !unkeyed.isAtEnd,
                      let val = try? unkeyed.decode(Value.self) else {
                    break
                }
                if let uuid = UUID(uuidString: keyStr) {
                    result[uuid] = val
                }
            }
            return result
        }
        return [:]
    }
}
