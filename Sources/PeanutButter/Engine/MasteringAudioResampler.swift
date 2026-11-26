import Foundation
import AVFoundation

public enum MasteringAudioResampler {
    public static func configureConverter(
        _ converter: AVAudioConverter,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) {
        if abs(sourceFormat.sampleRate - targetFormat.sampleRate) > 0.5 {
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
    }

    public static func outputCapacity(
        forSourceFrames sourceFrames: AVAudioFrameCount,
        fromRate: Double,
        toRate: Double
    ) -> AVAudioFrameCount {
        let safeFrom = max(1.0, fromRate)
        let ratio = toRate / safeFrom
        let expected = ceil(Double(sourceFrames) * ratio)
        let headroom = max(2048.0, ceil(2048.0 * max(1.0, ratio)))
        return AVAudioFrameCount(expected + headroom)
    }

    public static func convertBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if sourceBuffer.format == targetFormat {
            return sourceBuffer
        }
        guard sourceBuffer.frameLength > 0,
              let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            return nil
        }

        configureConverter(converter, from: sourceBuffer.format, to: targetFormat)

        let outCapacity = outputCapacity(
            forSourceFrames: sourceBuffer.frameLength,
            fromRate: sourceBuffer.format.sampleRate,
            toRate: targetFormat.sampleRate
        )
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        nonisolated(unsafe) let srcRef = sourceBuffer
        nonisolated(unsafe) var sentInput = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if !sentInput {
                sentInput = true
                outStatus.pointee = .haveData
                return srcRef
            } else {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        guard status != .error, error == nil, outBuffer.frameLength > 0 else {
            return nil
        }
        return outBuffer
    }

    public static func resampleMonoFloat(
        _ samples: [Float],
        fromRate: Double,
        toRate: Double
    ) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        if abs(fromRate - toRate) <= 0.5 { return samples }

        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate, channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let srcPtr = srcBuf.floatChannelData?[0] else {
            return nil
        }

        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                srcPtr.update(from: base, count: samples.count)
            }
        }

        guard let dstBuf = convertBuffer(srcBuf, to: dstFmt),
              let dstPtr = dstBuf.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: dstPtr, count: Int(dstBuf.frameLength)))
    }

    public static func resampleStereoFloat(
        left: [Float],
        right: [Float],
        fromRate: Double,
        toRate: Double
    ) -> (left: [Float], right: [Float])? {
        guard left.count == right.count else { return nil }
        guard !left.isEmpty else { return ([], []) }
        if abs(fromRate - toRate) <= 0.5 { return (left, right) }

        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 2, interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate, channels: 2, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(left.count)),
              let srcChannels = srcBuf.floatChannelData else {
            return nil
        }

        srcBuf.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                srcChannels[0].update(from: base, count: left.count)
            }
        }
        right.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                srcChannels[1].update(from: base, count: right.count)
            }
        }

        guard let dstBuf = convertBuffer(srcBuf, to: dstFmt),
              let dstChannels = dstBuf.floatChannelData else {
            return nil
        }
        let outCount = Int(dstBuf.frameLength)
        let leftOut = Array(UnsafeBufferPointer(start: dstChannels[0], count: outCount))
        let rightOut = Array(UnsafeBufferPointer(start: dstChannels[1], count: outCount))
        return (leftOut, rightOut)
    }

    public static func targetMP3SampleRate(for sourceSampleRate: Double) -> Double {
        if sourceSampleRate <= 48_000.5 {
            return max(8_000.0, sourceSampleRate)
        }
        if abs(sourceSampleRate.remainder(dividingBy: 44_100.0)) < 10.0 {
            return 44_100.0
        }
        return 48_000.0
    }
}
