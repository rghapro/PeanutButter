import Foundation

public enum PlaybackState: String, Sendable {
    case stopped
    case playing
    case paused
}

public struct TransportPosition: Sendable {
    public var currentTime: TimeInterval
    public var totalDuration: TimeInterval
    public var bar: Int
    public var beat: Int
    public var currentSectionIndex: Int
    public var currentBPM: Double
    public var currentTimeSignatureNumerator: Int
    public var currentTimeSignatureDenominator: Int
    
    public init(
        currentTime: TimeInterval = 0,
        totalDuration: TimeInterval = 0,
        bar: Int = 1,
        beat: Int = 1,
        currentSectionIndex: Int = 0,
        currentBPM: Double = 0,
        currentTimeSignatureNumerator: Int = 4,
        currentTimeSignatureDenominator: Int = 4
    ) {
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.bar = bar
        self.beat = beat
        self.currentSectionIndex = currentSectionIndex
        self.currentBPM = currentBPM
        self.currentTimeSignatureNumerator = currentTimeSignatureNumerator
        self.currentTimeSignatureDenominator = currentTimeSignatureDenominator
    }
    
    /// Formatted time string "MM:SS.s"
    public var timeString: String {
        let totalSeconds = max(0, Int(currentTime))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let tenths = Int((currentTime.truncatingRemainder(dividingBy: 1.0)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, abs(tenths))
    }
    
    /// Formatted display time "00:00"
    public var formattedCurrentTime: String {
        let totalSeconds = max(0, Int(currentTime))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// Formatted short time "0:00"
    public var formattedShortTime: String {
        let totalSeconds = max(0, Int(currentTime))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Formatted total duration "4:19"
    public var formattedDuration: String {
        let totalSeconds = max(0, Int(totalDuration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Formatted total duration "MM:SS"
    public var totalDurationString: String {
        let totalSeconds = max(0, Int(totalDuration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// Formatted musical position "001.1"
    public var barBeatString: String {
        String(format: "%03d.%d", bar, beat)
    }
}

/// Isolated ObservableObject for Stereo VU Metering so updating meters
/// NEVER invalidates parent ChannelStripView, BusChannelStripView, or MainView hierarchies!
public final class StereoMeterModel: ObservableObject, @unchecked Sendable {
    public private(set) var left: Float = 0.0
    public private(set) var right: Float = 0.0
    
    // Ballistic attack/decay clamping per display frame (60 Hz)
    private let maxAscentDelta: Float = 0.25
    private let maxDecayDelta: Float = 0.045
    
    public init() {}
    
    @MainActor
    public func update(left newL: Float, right newR: Float, dt: TimeInterval = 1.0 / 60.0) {
        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let stepAscent = min(1.0, maxAscentDelta * frames60)
        let stepDecay = min(1.0, maxDecayDelta * frames60)
        let clampedL = newL < 0.006 ? 0.0 : newL
        let clampedR = newR < 0.006 ? 0.0 : newR
        let nextL = clampedL > left ? min(clampedL, left + stepAscent) : max(clampedL, left - stepDecay)
        let nextR = clampedR > right ? min(clampedR, right + stepAscent) : max(clampedR, right - stepDecay)
        let finalL: Float = nextL < 0.006 ? 0.0 : nextL
        let finalR: Float = nextR < 0.006 ? 0.0 : nextR
        let changedL = abs(finalL - left) > 0.004 || (finalL == 0 && left != 0)
        let changedR = abs(finalR - right) > 0.004 || (finalR == 0 && right != 0)
        if changedL || changedR {
            objectWillChange.send()
            left = finalL
            right = finalR
        }
    }
    
    @MainActor
    public func reset() {
        if left != 0 || right != 0 {
            objectWillChange.send()
            left = 0
            right = 0
        }
    }
}

/// Isolated ObservableObject for the smooth Transport Playhead Clock so playhead ticks
/// only update the WaveformTimelineView scroll offset, never the 26+ Mixer Channel Strips!
public final class TransportClockModel: ObservableObject, @unchecked Sendable {
    @Published public var position: TransportPosition = TransportPosition()
    
    public init() {}
}

/// Low-frequency ObservableObject for the Top-Left Timecode Card & BPM Display.
/// Only publishes when the displayed whole second, duration, or BPM actually changes (~1 Hz instead of 60 Hz)!
public final class TransportDisplayClockModel: ObservableObject, @unchecked Sendable {
    public private(set) var position: TransportPosition = TransportPosition()
    
    public init() {}
    
    @MainActor
    public func update(with newPos: TransportPosition) {
        let oldSec = max(0, Int(position.currentTime))
        let newSec = max(0, Int(newPos.currentTime))
        let oldDur = max(0, Int(position.totalDuration))
        let newDur = max(0, Int(newPos.totalDuration))
        let bpmChanged = abs(newPos.currentBPM - position.currentBPM) >= 0.01
        let barBeatChanged = (newPos.bar != position.bar) || (newPos.beat != position.beat)
        
        if oldSec != newSec || oldDur != newDur || bpmChanged || barBeatChanged {
            objectWillChange.send()
            position = newPos
        } else {
            position = newPos
        }
    }
}
