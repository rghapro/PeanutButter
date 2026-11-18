import Foundation

/// Frame rate options for SMPTE Timecode output
public enum SMPTEFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = "24fps"
    case fps25 = "25fps"
    case fps2997 = "29.97fps"
    case fps30 = "30fps"
    case fps30df = "30 drop frame fps"
    
    public var id: String { rawValue }
    
    public var framesPerSecond: Double {
        switch self {
        case .fps24: return 24.0
        case .fps25: return 25.0
        case .fps2997: return 29.97
        case .fps30: return 30.0
        case .fps30df: return 29.97
        }
    }
    
    public var isDropFrame: Bool {
        return self == .fps30df
    }
}

/// Represents a single SMPTE Timecode cue in a song (maximum 1 cue per song)
public struct SMPTECue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var time: TimeInterval         // Timeline Location (exact time in seconds where transmission begins)
    public var timeStartHours: Int        // SMPTE Time Start hours (0..23)
    public var timeStartMinutes: Int      // SMPTE Time Start minutes (0..59)
    public var timeStartSeconds: Int      // SMPTE Time Start seconds (0..59)
    public var timeStartFrames: Int       // SMPTE Time Start frames (0..29)
    
    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        timeStartHours: Int = 0,
        timeStartMinutes: Int = 0,
        timeStartSeconds: Int = 0,
        timeStartFrames: Int = 0
    ) {
        self.id = id
        self.time = time
        self.timeStartHours = timeStartHours
        self.timeStartMinutes = timeStartMinutes
        self.timeStartSeconds = timeStartSeconds
        self.timeStartFrames = timeStartFrames
    }
    
    public var displayTimeStart: String {
        return String(format: "%02dh %02dm", timeStartHours, timeStartMinutes)
    }
    
    public var totalStartSeconds: Double {
        return Double(timeStartHours * 3600 + timeStartMinutes * 60 + timeStartSeconds)
    }
    
    public func formattedTimelineLocation() -> String {
        let totalMs = Int(max(0, time) * 1000)
        let mins = totalMs / 60000
        let secs = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%03d", mins, secs, ms)
    }
    
    public func frameLocation(fps: Double) -> Int {
        return Int(round(max(0, time) * fps))
    }
}
