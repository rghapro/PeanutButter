import Foundation
import Accelerate

/// Professional SMPTE 12M Linear Timecode (LTC) Generator
/// Produces broadcast-standard 80-bit biphase mark audio signal directly into CoreAudio output buffers
public final class SMPTELTCGenerator: @unchecked Sendable {
    public static let shared = SMPTELTCGenerator()
    
    public init() {}
    
    /// Converts a time offset (in seconds) to SMPTE Timecode (Hours, Minutes, Seconds, Frames)
    public static func timecode(
        forSeconds seconds: Double,
        frameRate: SMPTEFrameRate
    ) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        let fps = frameRate.framesPerSecond
        let clampedSeconds = max(0.0, seconds)
        
        if frameRate.isDropFrame {
            // Standard SMPTE 12M 30 Drop-Frame calculation (29.97 fps)
            // 2 frames dropped every minute except every 10th minute
            let totalFrames = Int64(round(clampedSeconds * 29.97))
            let framesPer10Min: Int64 = 17982 // 10 * 60 * 30 - 18
            let framesPerMin: Int64 = 1798   // 60 * 30 - 2
            
            let d = totalFrames / framesPer10Min
            let m = totalFrames % framesPer10Min
            
            var dropFrameCount: Int64 = 0
            if m > 1 {
                dropFrameCount = 2 * ((m - 2) / framesPerMin + 1)
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
            let totalFrames = Int64(floor(clampedSeconds * fps))
            let intFps = max(1, Int(round(fps)))
            let ff = Int(totalFrames % Int64(intFps))
            let totalSecs = totalFrames / Int64(intFps)
            let ss = Int(totalSecs % 60)
            let totalMins = totalSecs / 60
            let mm = Int(totalMins % 60)
            let hh = Int((totalMins / 60) % 24)
            return (hh, mm, ss, ff)
        }
    }
    
    /// Encodes Hours, Minutes, Seconds, Frames into standard 80-bit SMPTE 12M frame
    public static func encodeLTCFrame(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        isDropFrame: Bool
    ) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 80)
        
        func setBits(start: Int, count: Int, value: Int) {
            for b in 0..<count {
                bits[start + b] = UInt8((value >> b) & 1)
            }
        }
        
        // Frame units (0..3) & Frame tens (8..9)
        setBits(start: 0, count: 4, value: frames % 10)
        setBits(start: 8, count: 2, value: (frames / 10) % 10)
        bits[10] = isDropFrame ? 1 : 0 // Drop frame flag
        bits[11] = 0 // Color frame flag
        
        // Second units (16..19) & Second tens (24..26)
        setBits(start: 16, count: 4, value: seconds % 10)
        setBits(start: 24, count: 3, value: (seconds / 10) % 10)
        bits[27] = 0 // Bi-phase mark phase correction
        
        // Minute units (32..35) & Minute tens (40..42)
        setBits(start: 32, count: 4, value: minutes % 10)
        setBits(start: 40, count: 3, value: (minutes / 10) % 10)
        bits[43] = 0 // Binary group flag
        
        // Hour units (48..51) & Hour tens (56..57)
        setBits(start: 48, count: 4, value: hours % 10)
        setBits(start: 56, count: 2, value: (hours / 10) % 10)
        bits[58] = 0 // Reserved
        bits[59] = 0 // Binary group flag
        
        // Sync Word: 0011 1111 1111 1101 (Bits 64..79)
        let syncWord: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for i in 0..<16 {
            bits[64 + i] = syncWord[i]
        }
        
        return bits
    }
    
    /// Renders SMPTE LTC biphase mark audio signal directly into target output buffer
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
        
        for i in 0..<frameCount {
            let currentTimelineFrame = startTimelineFrame + Int64(i)
            let relativeSamples = currentTimelineFrame - cueTimelineFrame
            
            if relativeSamples < 0 {
                // Before SMPTE cue location: silence
                continue
            }
            
            let elapsedSeconds = Double(relativeSamples) / sampleRate
            let currentSMPTESeconds = cueStartSeconds + elapsedSeconds
            
            let (hh, mm, ss, ff) = timecode(forSeconds: currentSMPTESeconds, frameRate: frameRate)
            let bits = encodeLTCFrame(hours: hh, minutes: mm, seconds: ss, frames: ff, isDropFrame: frameRate.isDropFrame)
            
            // Sample within current video frame
            let videoFrameIndex = Int64(floor(Double(relativeSamples) / samplesPerVideoFrame))
            let sampleInFrame = Double(relativeSamples) - (Double(videoFrameIndex) * samplesPerVideoFrame)
            let bitIndex = min(79, max(0, Int(floor(sampleInFrame / samplesPerBit))))
            let sampleInBit = sampleInFrame - (Double(bitIndex) * samplesPerBit)
            let phaseInBit = sampleInBit / samplesPerBit // 0.0 ... 1.0
            
            // Compute starting polarity of bitIndex using parity of preceding '0' bits in this frame
            var zeroCount = 0
            for b in 0..<bitIndex {
                if bits[b] == 0 {
                    zeroCount += 1
                }
            }
            // Video frame boundary initial polarity derived from videoFrameIndex parity
            let frameInitialPolarity: Float = (videoFrameIndex % 2 == 0) ? 1.0 : -1.0
            let bitStartPolarity: Float = (zeroCount % 2 == 0) ? frameInitialPolarity : -frameInitialPolarity
            
            let bitVal = bits[bitIndex]
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
