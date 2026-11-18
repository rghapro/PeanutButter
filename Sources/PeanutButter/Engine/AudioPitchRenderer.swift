import Foundation
import AVFoundation
import CRubberBand

/// Offline High-Speed Audio Pitch Renderer powered by Rubber Band R3 ("Finer" multi-resolution engine).
/// Renders offline with zero real-time AudioUnit CPU overhead during live playback.
public enum AudioPitchRenderer {
    
    /// Pre-renders an audio buffer pitch-shifted by integer semitones (-12 to +12) and/or time-stretched by `tempoScale` (`targetBPM / originalBPM`), with optional formant preservation/shift.
    public static func renderPitchShiftedBuffer(
        sourceBuffer: AVAudioPCMBuffer,
        semitones: Int,
        tonalityLimitHz: Double = 8000.0,
        formantSemitones: Double = 0.0,
        compensateFormants: Bool = false,
        tempoScale: Double = 1.0
    ) throws -> AVAudioPCMBuffer {
        try renderPitchShiftedBuffer(
            sourceBuffer: sourceBuffer,
            semitones: Double(semitones),
            tonalityLimitHz: tonalityLimitHz,
            formantSemitones: formantSemitones,
            compensateFormants: compensateFormants,
            tempoScale: tempoScale
        )
    }
    
    /// Pre-renders an audio buffer pitch-shifted by arbitrary semitones and/or time-stretched by `tempoScale` (`targetBPM / originalBPM`), with optional formant preservation/shift.
    public static func renderPitchShiftedBuffer(
        sourceBuffer: AVAudioPCMBuffer,
        semitones: Double,
        tonalityLimitHz: Double = 8000.0,
        formantSemitones: Double = 0.0,
        compensateFormants: Bool = false,
        tempoScale: Double = 1.0
    ) throws -> AVAudioPCMBuffer {
        let safeTempoScale = (tempoScale.isFinite && tempoScale > 0.0) ? max(0.1, min(4.0, tempoScale)) : 1.0
        guard abs(semitones) > 1e-6 || abs(formantSemitones) > 1e-6 || abs(safeTempoScale - 1.0) > 1e-6 else {
            return sourceBuffer
        }
        
        let totalFrames = Int(sourceBuffer.frameLength)
        guard totalFrames > 0 else { return sourceBuffer }
        
        // Ensure standard non-interleaved Float32 PCM format before passing channel pointers to C++
        let workingBuffer: AVAudioPCMBuffer
        if sourceBuffer.format.commonFormat == .pcmFormatFloat32 && !sourceBuffer.format.isInterleaved,
           sourceBuffer.floatChannelData != nil {
            workingBuffer = sourceBuffer
        } else {
            guard let targetFormat = AVAudioFormat(
                standardFormatWithSampleRate: sourceBuffer.format.sampleRate,
                channels: sourceBuffer.format.channelCount
            ),
                  let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat),
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: sourceBuffer.frameLength) else {
                throw NSError(
                    domain: "PlaybackPitch",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported PCM format for pitch transposition"]
                )
            }
            var convError: NSError?
            var consumed = false
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let convError = convError {
                throw convError
            }
            workingBuffer = converted
        }
        
        let format = workingBuffer.format
        let channels = Int(format.channelCount)
        let frameCount = Int(workingBuffer.frameLength)
        guard channels > 0, frameCount > 0, let srcChannelData = workingBuffer.floatChannelData else {
            return sourceBuffer
        }
        
        let outputFrameCount = abs(safeTempoScale - 1.0) > 1e-6
            ? max(1, Int((Double(frameCount) / safeTempoScale).rounded()))
            : frameCount
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrameCount)),
              let dstChannelData = outputBuffer.floatChannelData else {
            throw NSError(
                domain: "PlaybackPitch",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output buffer"]
            )
        }
        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)
        
        var inputPtrs = [UnsafePointer<Float>?](repeating: nil, count: channels)
        var outputPtrs = [UnsafeMutablePointer<Float>?](repeating: nil, count: channels)
        for ch in 0..<channels {
            inputPtrs[ch] = UnsafePointer(srcChannelData[ch])
            outputPtrs[ch] = dstChannelData[ch]
        }
        
        let success = inputPtrs.withUnsafeBufferPointer { inBuf in
            outputPtrs.withUnsafeMutableBufferPointer { outBuf in
                return rubberband_r3_process_exact(
                    inBuf.baseAddress,
                    frameCount,
                    outBuf.baseAddress,
                    outputFrameCount,
                    Int32(channels),
                    format.sampleRate,
                    semitones,
                    formantSemitones,
                    compensateFormants
                )
            }
        }
        
        guard success else {
            throw NSError(
                domain: "PlaybackPitch",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Rubber Band R3 failed to render pitch-shifted buffer"]
            )
        }
        
        return outputBuffer
    }
}
