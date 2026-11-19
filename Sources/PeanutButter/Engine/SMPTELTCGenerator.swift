import Foundation
import Accelerate

/// Professional SMPTE 12M Linear Timecode (LTC) Generator
/// Produces broadcast-standard 80-bit biphase mark audio signal directly into CoreAudio output buffers
public final class SMPTELTCGenerator: @unchecked Sendable {
    public static let shared = SMPTELTCGenerator()
    
    public init() {}

    /// Stack-allocated 80-bit SMPTE 12M LTC word (bits 0...63 in `low`, bits 64...79 in `high`).
    public struct LTCFrameBits: Sendable, Equatable {
        public var low: UInt64 = 0
        public var high: UInt16 = 0

        public init(low: UInt64 = 0, high: UInt16 = 0) {
            self.low = low
            self.high = high
        }

        @inline(__always)
        public func bit(at index: Int) -> UInt8 {
            if index < 64 {
                return UInt8((low >> UInt64(index)) & 1)
            }
            return UInt8((high >> UInt16(index - 64)) & 1)
        }

        @inline(__always)
        public mutating func setBit(_ index: Int, to value: Int) {
            if index < 64 {
                let mask = UInt64(1) << UInt64(index)
                if (value & 1) != 0 {
                    low |= mask
                } else {
                    low &= ~mask
                }
            } else {
                let mask = UInt16(1) << UInt16(index - 64)
                if (value & 1) != 0 {
                    high |= mask
                } else {
                    high &= ~mask
                }
            }
        }

        @inline(__always)
        public func zerosBefore(_ bitIndex: Int) -> Int {
            if bitIndex <= 0 { return 0 }
            if bitIndex <= 64 {
                let mask: UInt64 = (bitIndex == 64) ? UInt64.max : ((UInt64(1) << UInt64(bitIndex)) &- 1)
                return bitIndex - (low & mask).nonzeroBitCount
            }
            let onesLow = low.nonzeroBitCount
            let highBits = min(16, bitIndex - 64)
            let highMask = UInt16((UInt32(1) << UInt32(highBits)) &- 1)
            let onesHigh = (high & highMask).nonzeroBitCount
            return bitIndex - (onesLow + onesHigh)
        }
    }
    
    /// Converts a time offset (in seconds) to SMPTE Timecode (Hours, Minutes, Seconds, Frames)
    public static func timecode(
        forSeconds seconds: Double,
        frameRate: SMPTEFrameRate
    ) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        let fps = frameRate.framesPerSecond
        let clampedSeconds = max(0.0, seconds)
        
        if frameRate.isDropFrame {
            // Standard SMPTE 12M 30 Drop-Frame calculation (30000/1001 fps):
            // 2 frames dropped at start of every minute except every 10th minute.
            let totalFrames = Int64(floor(clampedSeconds * fps + 1e-9))
            let framesPer10Min: Int64 = 17982 // 10 * 60 * 30 - 18
            let framesPerMin: Int64 = 1798   // 60 * 30 - 2
            
            let d = totalFrames / framesPer10Min
            let m = totalFrames % framesPer10Min
            
            var dropFrameCount: Int64 = 0
            if m >= 1800 {
                dropFrameCount = 2 * (((m - 1800) / framesPerMin) + 1)
            }
            let adjustedFrames = totalFrames + (18 * d) + dropFrameCount
            
            let ff = Int(adjustedFrames % 30)
            let totalSecs = adjustedFrames / 30
            let ss = Int(totalSecs % 60)
            let totalMins = totalSecs / 60
            let mm = Int(totalMins % 60)
            let hh = Int((totalMins / 60) % 24)
            return (hh, mm, ss, ff)
        } else {
            let totalFrames = Int64(floor(clampedSeconds * fps + 1e-9))
            let intFps = Int64(frameRate.nominalFPS)
            let ff = Int(totalFrames % intFps)
            let totalSecs = totalFrames / intFps
            let ss = Int(totalSecs % 60)
            let totalMins = totalSecs / 60
            let mm = Int(totalMins % 60)
            let hh = Int((totalMins / 60) % 24)
            return (hh, mm, ss, ff)
        }
    }

    /// Zero-allocation SMPTE 12M 80-bit LTC word encoder with biphase mark polarity correction bit.
    @inline(__always)
    public static func encodeLTCFrameBits(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        isDropFrame: Bool,
        frameRate: SMPTEFrameRate = .fps30
    ) -> LTCFrameBits {
        var bits = LTCFrameBits()

        @inline(__always)
        func setField(start: Int, count: Int, value: Int) {
            let mask = UInt64((1 << count) - 1)
            bits.low |= (UInt64(value) & mask) << UInt64(start)
        }

        // Frame units (0..3), Frame tens (8..9), Drop-Frame flag (10)
        setField(start: 0, count: 4, value: frames % 10)
        setField(start: 8, count: 2, value: (frames / 10) % 10)
        if isDropFrame {
            bits.setBit(10, to: 1)
        }

        // Second units (16..19), Second tens (24..26)
        setField(start: 16, count: 4, value: seconds % 10)
        setField(start: 24, count: 3, value: (seconds / 10) % 10)

        // Minute units (32..35), Minute tens (40..42)
        setField(start: 32, count: 4, value: minutes % 10)
        setField(start: 40, count: 3, value: (minutes / 10) % 10)

        // Hour units (48..51), Hour tens (56..57)
        setField(start: 48, count: 4, value: hours % 10)
        setField(start: 56, count: 2, value: (hours / 10) % 10)

        // Sync Word: bits 64..79 = 0011 1111 1111 1101 -> 0xBFFC
        bits.high = 0xBFFC

        // SMPTE 12M / EBU Biphase Mark Phase Correction Bit:
        // Guarantees an even number of '0' bits (and '1' bits) across all 80 bits so every frame boundary stays DC-balanced.
        // SMPTE (24/29.97/30) uses bit 27; EBU (25 fps) uses bit 59.
        let oneCount = bits.low.nonzeroBitCount + bits.high.nonzeroBitCount
        if (oneCount & 1) != 0 {
            let polarityBitIndex = (frameRate == .fps25) ? 59 : 27
            bits.setBit(polarityBitIndex, to: 1)
        }

        return bits
    }
    
    /// Encodes Hours, Minutes, Seconds, Frames into standard 80-bit SMPTE 12M frame
    public static func encodeLTCFrame(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        isDropFrame: Bool,
        frameRate: SMPTEFrameRate = .fps30
    ) -> [UInt8] {
        let word = encodeLTCFrameBits(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            isDropFrame: isDropFrame,
            frameRate: frameRate
        )
        var bits = [UInt8](repeating: 0, count: 80)
        for i in 0..<80 {
            bits[i] = word.bit(at: i)
        }
        return bits
    }
    
    /// Renders SMPTE LTC biphase mark audio signal directly into target output buffer (zero heap allocations).
    public static func renderLTC(
        frameCount: Int,
        outBuffer: UnsafeMutablePointer<Float>,
        startTimelineFrame: Int64,
        cueTimelineFrame: Int64,
        cueStartSeconds: Double,
        sampleRate: Double,
        frameRate: SMPTEFrameRate,
        amplitude: Float = 0.50
    ) {
        let fps = frameRate.framesPerSecond
        let samplesPerVideoFrame = sampleRate / fps
        let samplesPerBit = samplesPerVideoFrame / 80.0
        guard samplesPerBit > 0 else { return }

        var cachedVideoFrameIndex: Int64 = -1
        var cachedBits = LTCFrameBits()
        
        for i in 0..<frameCount {
            let currentTimelineFrame = startTimelineFrame + Int64(i)
            let relativeSamples = currentTimelineFrame - cueTimelineFrame
            
            if relativeSamples < 0 {
                // Before SMPTE cue location: silence
                continue
            }
            
            // Identify current video frame index and sample position within frame
            let videoFrameIndex = Int64(floor(Double(relativeSamples) / samplesPerVideoFrame))
            if videoFrameIndex != cachedVideoFrameIndex {
                cachedVideoFrameIndex = videoFrameIndex
                let frameElapsedSeconds = (Double(videoFrameIndex) + 0.1) / fps
                let currentSMPTESeconds = cueStartSeconds + frameElapsedSeconds
                let (hh, mm, ss, ff) = timecode(forSeconds: currentSMPTESeconds, frameRate: frameRate)
                cachedBits = encodeLTCFrameBits(
                    hours: hh,
                    minutes: mm,
                    seconds: ss,
                    frames: ff,
                    isDropFrame: frameRate.isDropFrame,
                    frameRate: frameRate
                )
            }

            let sampleInFrame = Double(relativeSamples) - (Double(videoFrameIndex) * samplesPerVideoFrame)
            let bitIndex = min(79, max(0, Int(floor(sampleInFrame / samplesPerBit))))
            let sampleInBit = sampleInFrame - (Double(bitIndex) * samplesPerBit)
            let phaseInBit = sampleInBit / samplesPerBit // 0.0 ... 1.0
            
            // With SMPTE 12M parity correction enforcing an even zero-count in every 80-bit frame,
            // bit 79 always terminates at -1.0 when frameInitialPolarity is +1.0, giving a continuous clock edge at bit 0.
            let zerosBefore = cachedBits.zerosBefore(bitIndex)
            let bitStartPolarity: Float = ((zerosBefore & 1) == 0) ? 1.0 : -1.0
            
            let bitVal = cachedBits.bit(at: bitIndex)
            let sampleVal: Float
            if bitVal == 1 {
                // Transition at start (0.0) and at midpoint (0.5)
                sampleVal = (phaseInBit < 0.5) ? bitStartPolarity : -bitStartPolarity
            } else {
                // Transition only at start (0.0); constant through midpoint
                sampleVal = bitStartPolarity
            }
            
            outBuffer[i] += sampleVal * amplitude
        }
    }
}
