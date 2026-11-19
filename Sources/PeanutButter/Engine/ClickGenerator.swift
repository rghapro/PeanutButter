import Foundation
import AVFoundation

/// Synthesizes sample-accurate musical click / metronome audio buffers
public final class ClickGenerator: @unchecked Sendable {
    
    public init() {}
    
    /// Generates a metronome click audio buffer following either a dynamic beat grid or fixed tempo & meter.
    /// If an "End" section is present, the click stops immediately on its downbeat.
    public func generateClickBuffer(
        bpm: Double,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        duration: TimeInterval,
        beatGrid: [BeatGridMarker] = [],
        sections: [SongSection] = [],
        soundType: ClickSoundType = .classic,
        accentEnabled: Bool = true,
        quarterEnabled: Bool = true,
        eighthEnabled: Bool = true,
        sixteenthEnabled: Bool = false,
        accentVolume: Float = 0.80,
        quarterVolume: Float = 0.80,
        eighthVolume: Float = 0.70,
        sixteenthVolume: Float = 0.0,
        soloedSubdivisions: Set<ClickSubdivision> = [],
        suppressEndCutoff: Bool = false,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard duration > 0 else { return nil }
        
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard totalFrames > 0 else { return nil }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return nil
        }
        buffer.frameLength = totalFrames
        
        // Zero-fill buffer memory
        for ch in 0..<channelCount {
            if let ptr = buffer.floatChannelData?[ch] {
                memset(ptr, 0, Int(totalFrames) * MemoryLayout<Float>.size)
            }
        }
        
        // Find downbeat time of the section labeled "End" (or "Ending")
        let endSection = sections.first(where: { sec in
            let lowerName = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let lowerAbbrev = sec.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowerName == "end" || lowerName == "ending" || lowerName == "the end" ||
                   lowerName.starts(with: "end ") || lowerName.hasSuffix(" end") ||
                   lowerAbbrev == "end" || (lowerAbbrev == "e" && lowerName.contains("end"))
        })
        let endCutoffTime: TimeInterval? = suppressEndCutoff ? nil : endSection?.startTime
        
        let accentFreq: Double
        let quarterFreq: Double
        let eighthFreq: Double
        let sixteenthFreq: Double
        let accentDecay: Double
        let quarterDecay: Double
        
        switch soundType {
        case .classic, .synthClassic:
            accentFreq = 2400.0
            quarterFreq = 1500.0
            eighthFreq = 1100.0
            sixteenthFreq = 850.0
            accentDecay = 180.0
            quarterDecay = 160.0
        case .woodblock, .synthWoodblock:
            accentFreq = 1150.0
            quarterFreq = 820.0
            eighthFreq = 680.0
            sixteenthFreq = 560.0
            accentDecay = 130.0
            quarterDecay = 120.0
        case .beep:
            accentFreq = 1760.0
            quarterFreq = 1200.0
            eighthFreq = 880.0
            sixteenthFreq = 700.0
            accentDecay = 100.0
            quarterDecay = 90.0
        case .sticks:
            accentFreq = 1600.0
            quarterFreq = 1100.0
            eighthFreq = 950.0
            sixteenthFreq = 750.0
            accentDecay = 240.0
            quarterDecay = 220.0
        case .cowbell, .synthCowbell:
            accentFreq = 800.0
            quarterFreq = 540.0
            eighthFreq = 480.0
            sixteenthFreq = 420.0
            accentDecay = 140.0
            quarterDecay = 130.0
        case .shaker:
            accentFreq = 4800.0
            quarterFreq = 3800.0
            eighthFreq = 3400.0
            sixteenthFreq = 3000.0
            accentDecay = 190.0
            quarterDecay = 175.0
        case .tambourine:
            accentFreq = 6200.0
            quarterFreq = 4500.0
            eighthFreq = 4000.0
            sixteenthFreq = 3600.0
            accentDecay = 150.0
            quarterDecay = 140.0
        default:
            accentFreq = 2400.0
            quarterFreq = 1500.0
            eighthFreq = 1100.0
            sixteenthFreq = 850.0
            accentDecay = 180.0
            quarterDecay = 160.0
        }
        
        // Calculate effective volume per subdivision, honoring solo states and studio click boost
        let isSoloActive = !soloedSubdivisions.isEmpty
        let effAccentVol = (accentEnabled && (!isSoloActive || soloedSubdivisions.contains(.accent))) ? max(0.0, accentVolume) : 0.0
        let effQuarterVol = (quarterEnabled && (!isSoloActive || soloedSubdivisions.contains(.quarter))) ? max(0.0, quarterVolume) : 0.0
        let effEighthVol = (eighthEnabled && (!isSoloActive || soloedSubdivisions.contains(.eighth))) ? max(0.0, eighthVolume) : 0.0
        let effSixteenthVol = (sixteenthEnabled && (!isSoloActive || soloedSubdivisions.contains(.sixteenth))) ? max(0.0, sixteenthVolume) : 0.0
        
        // Studio clicks gain boost (+3.2 dB) so pre-recorded clicks cut through clearly and prominently
        let studioGain: Float = soundType.isSampled ? 1.45 : 1.0
        
        // Pre-fetch subdivision sample buffers ONCE to avoid repeated lock/file lookups inside the audio loop
        let accentSample = soundType.isSampled ? AudioSampleBank.shared.getClickSample(sound: soundType, subdivision: .accent, format: format) : nil
        let quarterSample = soundType.isSampled ? AudioSampleBank.shared.getClickSample(sound: soundType, subdivision: .quarter, format: format) : nil
        let eighthSample = soundType.isSampled ? AudioSampleBank.shared.getClickSample(sound: soundType, subdivision: .eighth, format: format) : nil
        let sixteenthSample = soundType.isSampled ? AudioSampleBank.shared.getClickSample(sound: soundType, subdivision: .sixteenth, format: format) : nil
        
        let is68 = (timeSignatureNumerator == 6 && timeSignatureDenominator == 8)
        let beatScale = 4.0 / Double(max(1, timeSignatureDenominator))

        // If a dynamic beat grid is available, render pulses exactly at grid positions
        if !beatGrid.isEmpty {
            let sortedGrid = beatGrid.sorted { $0.time < $1.time }
            for i in 0..<sortedGrid.count {
                let marker = sortedGrid[i]
                guard marker.time < duration else { break }
                
                // Stop after the downbeat of the section labeled "End"
                if let cutoff = endCutoffTime, marker.time > cutoff + 0.03 {
                    break
                }
                
                let isAccent = (marker.beat == 1)
                
                if is68 {
                    // 6/8 Playback-style divisions:
                    // Beat 1 = Accent + 1/4 (when both enabled), Beat 4 = 1/4, Beats 2,3,5,6 = 1/8
                    if isAccent && effAccentVol > 0.001 {
                        playClick(
                            to: buffer,
                            atTime: marker.time,
                            sampleBuffer: accentSample,
                            soundType: soundType,
                            frequency: accentFreq,
                            decay: accentDecay,
                            amplitude: 0.95 * effAccentVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                    if (marker.beat == 1 || marker.beat == 4) && effQuarterVol > 0.001 {
                        playClick(
                            to: buffer,
                            atTime: marker.time,
                            sampleBuffer: quarterSample,
                            soundType: soundType,
                            frequency: quarterFreq,
                            decay: quarterDecay,
                            amplitude: 0.85 * effQuarterVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    } else if (marker.beat != 1 && marker.beat != 4) && effEighthVol > 0.001 {
                        playClick(
                            to: buffer,
                            atTime: marker.time,
                            sampleBuffer: eighthSample,
                            soundType: soundType,
                            frequency: eighthFreq,
                            decay: quarterDecay + 20.0,
                            amplitude: 0.70 * effEighthVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                } else {
                    // 1. Downbeat Accent (in addition to Quarter Note Beat when both enabled)
                    if isAccent && effAccentVol > 0.001 {
                        playClick(
                            to: buffer,
                            atTime: marker.time,
                            sampleBuffer: accentSample,
                            soundType: soundType,
                            frequency: accentFreq,
                            decay: accentDecay,
                            amplitude: 0.95 * effAccentVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                    if effQuarterVol > 0.001 {
                        // Regular 1/4 Beat (plays on all beats including beat 1)
                        playClick(
                            to: buffer,
                            atTime: marker.time,
                            sampleBuffer: quarterSample,
                            soundType: soundType,
                            frequency: quarterFreq,
                            decay: quarterDecay,
                            amplitude: 0.85 * effQuarterVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                }
                
                // If this pulse was the downbeat of the End section, stop immediately!
                if let cutoff = endCutoffTime, abs(marker.time - cutoff) < 0.05 {
                    break
                }
                
                // Subdivisions between this beat and next beat
                let tailBPM = marker.instantaneousBPM > 20.0 ? marker.instantaneousBPM : bpm
                let nextTime: TimeInterval = (i + 1 < sortedGrid.count) ? sortedGrid[i + 1].time : (marker.time + (60.0 / max(20.0, tailBPM)) * beatScale)
                let beatDur = nextTime - marker.time
                guard beatDur > 0.1 else { continue }
                
                if is68 {
                    // 1/16 in 6/8 counts "1 & 2 & 3 & 4 & 5 & 6 &" (midpoint between each 8th-note beat)
                    if effSixteenthVol > 0.001 {
                        let andTime = marker.time + (beatDur * 0.5)
                        if andTime < duration {
                            playClick(
                                to: buffer,
                                atTime: andTime,
                                sampleBuffer: sixteenthSample,
                                soundType: soundType,
                                frequency: sixteenthFreq,
                                decay: quarterDecay + 40.0,
                                amplitude: 0.60 * effSixteenthVol * studioGain,
                                sampleRate: sampleRate,
                                channelCount: channelCount,
                                totalFrames: totalFrames
                            )
                        }
                    }
                } else {
                    // 3. Eighth Note ("&")
                    if effEighthVol > 0.001 {
                        let eighthTime = marker.time + (beatDur * 0.5)
                        if eighthTime < duration {
                            playClick(
                                to: buffer,
                                atTime: eighthTime,
                                sampleBuffer: eighthSample,
                                soundType: soundType,
                                frequency: eighthFreq,
                                decay: quarterDecay + 20.0,
                                amplitude: 0.70 * effEighthVol * studioGain,
                                sampleRate: sampleRate,
                                channelCount: channelCount,
                                totalFrames: totalFrames
                            )
                        }
                    }
                    
                    // 4. Sixteenth Notes ("e", "a")
                    if effSixteenthVol > 0.001 {
                        let sixteenth1 = marker.time + (beatDur * 0.25)
                        let sixteenth2 = marker.time + (beatDur * 0.75)
                        if sixteenth1 < duration {
                            playClick(
                                to: buffer,
                                atTime: sixteenth1,
                                sampleBuffer: sixteenthSample,
                                soundType: soundType,
                                frequency: sixteenthFreq,
                                decay: quarterDecay + 40.0,
                                amplitude: 0.60 * effSixteenthVol * studioGain,
                                sampleRate: sampleRate,
                                channelCount: channelCount,
                                totalFrames: totalFrames
                            )
                        }
                        if sixteenth2 < duration {
                            playClick(
                                to: buffer,
                                atTime: sixteenth2,
                                sampleBuffer: sixteenthSample,
                                soundType: soundType,
                                frequency: sixteenthFreq,
                                decay: quarterDecay + 40.0,
                                amplitude: 0.60 * effSixteenthVol * studioGain,
                                sampleRate: sampleRate,
                                channelCount: channelCount,
                                totalFrames: totalFrames
                            )
                        }
                    }
                }
            }
            return buffer
        }
        
        // Fixed BPM Grid path
        let safeBpm = max(20.0, min(300.0, bpm))
        let secPerBeat = (60.0 / safeBpm) * beatScale
        let beatsPerBar = max(1, timeSignatureNumerator)
        
        var currentBeat = 0
        var currentTime: TimeInterval = 0.0
        
        while currentTime < duration {
            // Stop after the downbeat of the section labeled "End"
            if let cutoff = endCutoffTime, currentTime > cutoff + 0.03 {
                break
            }
            
            let beatInBar = (currentBeat % beatsPerBar) + 1
            let isAccent = (beatInBar == 1)
            
            if is68 {
                // 6/8 Playback-style divisions:
                // Beat 1 = Accent + 1/4 (when both enabled), Beat 4 = 1/4, Beats 2,3,5,6 = 1/8
                if isAccent && effAccentVol > 0.001 {
                    playClick(
                        to: buffer,
                        atTime: currentTime,
                        sampleBuffer: accentSample,
                        soundType: soundType,
                        frequency: accentFreq,
                        decay: accentDecay,
                        amplitude: 0.95 * effAccentVol * studioGain,
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        totalFrames: totalFrames
                    )
                }
                if (beatInBar == 1 || beatInBar == 4) && effQuarterVol > 0.001 {
                    playClick(
                        to: buffer,
                        atTime: currentTime,
                        sampleBuffer: quarterSample,
                        soundType: soundType,
                        frequency: quarterFreq,
                        decay: quarterDecay,
                        amplitude: 0.85 * effQuarterVol * studioGain,
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        totalFrames: totalFrames
                    )
                } else if (beatInBar != 1 && beatInBar != 4) && effEighthVol > 0.001 {
                    playClick(
                        to: buffer,
                        atTime: currentTime,
                        sampleBuffer: eighthSample,
                        soundType: soundType,
                        frequency: eighthFreq,
                        decay: quarterDecay + 20.0,
                        amplitude: 0.70 * effEighthVol * studioGain,
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        totalFrames: totalFrames
                    )
                }
            } else {
                // Downbeat Accent (in addition to Quarter Note Beat when both enabled)
                if isAccent && effAccentVol > 0.001 {
                    playClick(
                        to: buffer,
                        atTime: currentTime,
                        sampleBuffer: accentSample,
                        soundType: soundType,
                        frequency: accentFreq,
                        decay: accentDecay,
                        amplitude: 0.95 * effAccentVol * studioGain,
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        totalFrames: totalFrames
                    )
                }
                if effQuarterVol > 0.001 {
                    // Quarter Note Beat (plays on all beats including beat 1)
                    playClick(
                        to: buffer,
                        atTime: currentTime,
                        sampleBuffer: quarterSample,
                        soundType: soundType,
                        frequency: quarterFreq,
                        decay: quarterDecay,
                        amplitude: 0.85 * effQuarterVol * studioGain,
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        totalFrames: totalFrames
                    )
                }
            }
            
            // If this pulse was the downbeat of the End section, stop immediately!
            if let cutoff = endCutoffTime, abs(currentTime - cutoff) < 0.05 {
                break
            }
            
            if is68 {
                // 1/16 in 6/8 counts "1 & 2 & 3 & 4 & 5 & 6 &"
                if effSixteenthVol > 0.001 {
                    let andTime = currentTime + (secPerBeat * 0.5)
                    if andTime < duration {
                        playClick(
                            to: buffer,
                            atTime: andTime,
                            sampleBuffer: sixteenthSample,
                            soundType: soundType,
                            frequency: sixteenthFreq,
                            decay: quarterDecay + 40.0,
                            amplitude: 0.60 * effSixteenthVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                }
            } else {
                // Eighth Note Subdivision ("&")
                if effEighthVol > 0.001 {
                    let eighthTime = currentTime + (secPerBeat * 0.5)
                    if eighthTime < duration {
                        playClick(
                            to: buffer,
                            atTime: eighthTime,
                            sampleBuffer: eighthSample,
                            soundType: soundType,
                            frequency: eighthFreq,
                            decay: quarterDecay + 20.0,
                            amplitude: 0.70 * effEighthVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                }
                
                // Sixteenth Note Subdivisions ("e", "a")
                if effSixteenthVol > 0.001 {
                    let s1 = currentTime + (secPerBeat * 0.25)
                    let s2 = currentTime + (secPerBeat * 0.75)
                    if s1 < duration {
                        playClick(
                            to: buffer,
                            atTime: s1,
                            sampleBuffer: sixteenthSample,
                            soundType: soundType,
                            frequency: sixteenthFreq,
                            decay: quarterDecay + 40.0,
                            amplitude: 0.60 * effSixteenthVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                    if s2 < duration {
                        playClick(
                            to: buffer,
                            atTime: s2,
                            sampleBuffer: sixteenthSample,
                            soundType: soundType,
                            frequency: sixteenthFreq,
                            decay: quarterDecay + 40.0,
                            amplitude: 0.60 * effSixteenthVol * studioGain,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            totalFrames: totalFrames
                        )
                    }
                }
            }
            
            currentTime += secPerBeat
            currentBeat += 1
        }
        
        return buffer
    }

    /// Synthesizes a phase-exact, sample-seamless 1-bar looping click buffer for continuous post-song click playback.
    public func generateOneBarLoopBuffer(
        bpm: Double,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        soundType: ClickSoundType = .classic,
        accentEnabled: Bool = true,
        quarterEnabled: Bool = true,
        eighthEnabled: Bool = true,
        sixteenthEnabled: Bool = false,
        accentVolume: Float = 0.80,
        quarterVolume: Float = 0.80,
        eighthVolume: Float = 0.70,
        sixteenthVolume: Float = 0.0,
        soloedSubdivisions: Set<ClickSubdivision> = [],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate > 0 ? format.sampleRate : 48000.0
        let safeBPM = max(20.0, min(300.0, bpm))
        let beatsPerBar = max(1, timeSignatureNumerator)
        let beatScale = 4.0 / Double(max(1, timeSignatureDenominator))
        let secPerBeat = (60.0 / safeBPM) * beatScale
        let barFrames = max(1, Int((Double(beatsPerBar) * secPerBeat * sr).rounded()))
        let barSec = Double(barFrames) / sr
        let exactBeatSec = barSec / Double(beatsPerBar)

        var twoBarGrid: [BeatGridMarker] = []
        twoBarGrid.reserveCapacity(beatsPerBar * 2)
        for b in 0..<beatsPerBar {
            twoBarGrid.append(BeatGridMarker(time: Double(b) * exactBeatSec, bar: 1, beat: b + 1, instantaneousBPM: safeBPM))
        }
        for b in 0..<beatsPerBar {
            twoBarGrid.append(BeatGridMarker(time: barSec + Double(b) * exactBeatSec, bar: 2, beat: b + 1, instantaneousBPM: safeBPM))
        }

        guard let rendered = generateClickBuffer(
            bpm: safeBPM,
            timeSignatureNumerator: timeSignatureNumerator,
            timeSignatureDenominator: timeSignatureDenominator,
            duration: barSec * 2.5,
            beatGrid: twoBarGrid,
            sections: [],
            soundType: soundType,
            accentEnabled: accentEnabled,
            quarterEnabled: quarterEnabled,
            eighthEnabled: eighthEnabled,
            sixteenthEnabled: sixteenthEnabled,
            accentVolume: accentVolume,
            quarterVolume: quarterVolume,
            eighthVolume: eighthVolume,
            sixteenthVolume: sixteenthVolume,
            soloedSubdivisions: soloedSubdivisions,
            suppressEndCutoff: true,
            format: format
        ) else {
            return nil
        }

        let targetFrameCount = AVAudioFrameCount(barFrames)
        guard let loopBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: targetFrameCount) else {
            return nil
        }
        loopBuffer.frameLength = targetFrameCount

        let channelCount = Int(min(format.channelCount, rendered.format.channelCount))
        let renderedTotal = Int(rendered.frameLength)
        let copyCount = min(barFrames, max(0, renderedTotal - barFrames))
        for ch in 0..<channelCount {
            if let dst = loopBuffer.floatChannelData?[ch] {
                memset(dst, 0, barFrames * MemoryLayout<Float>.size)
                if copyCount > 0, let src = rendered.floatChannelData?[ch] {
                    memcpy(dst, src.advanced(by: barFrames), copyCount * MemoryLayout<Float>.size)
                }
            }
        }
        return loopBuffer
    }
    
    // MARK: - Internal Unified Click Playback Helper
    
    private func playClick(
        to buffer: AVAudioPCMBuffer,
        atTime time: TimeInterval,
        sampleBuffer: AVAudioPCMBuffer?,
        soundType: ClickSoundType,
        frequency: Double,
        decay: Double,
        amplitude: Float,
        sampleRate: Double,
        channelCount: Int,
        totalFrames: AVAudioFrameCount
    ) {
        // +6.0 dB total gain boost for generated click (10^(6.0 / 20.0) ≈ 1.995)
        let boostedAmplitude = amplitude * 1.995
        
        if let sampleBuf = sampleBuffer {
            writeSample(
                from: sampleBuf,
                to: buffer,
                atTime: time,
                amplitude: boostedAmplitude,
                sampleRate: sampleRate,
                channelCount: channelCount,
                totalFrames: totalFrames
            )
        } else {
            writePulse(
                to: buffer,
                atTime: time,
                frequency: frequency,
                decay: decay,
                amplitude: boostedAmplitude,
                soundType: soundType,
                sampleRate: sampleRate,
                channelCount: channelCount,
                totalFrames: totalFrames
            )
        }
    }
    
    private func writeSample(
        from sampleBuffer: AVAudioPCMBuffer,
        to buffer: AVAudioPCMBuffer,
        atTime time: TimeInterval,
        amplitude: Float,
        sampleRate: Double,
        channelCount: Int,
        totalFrames: AVAudioFrameCount
    ) {
        guard time >= 0 else { return }
        let startFrame = Int(time * sampleRate)
        guard startFrame < Int(totalFrames) else { return }
        
        let framesToCopy = min(Int(sampleBuffer.frameLength), Int(totalFrames) - startFrame)
        guard framesToCopy > 0 else { return }
        let sampleChannels = Int(sampleBuffer.format.channelCount)
        
        for ch in 0..<channelCount {
            guard let destPtr = buffer.floatChannelData?[ch] else { continue }
            let srcCh = min(ch, sampleChannels - 1)
            guard let srcPtr = sampleBuffer.floatChannelData?[srcCh] else { continue }
            
            for f in 0..<framesToCopy {
                let destIdx = startFrame + f
                let mixed = destPtr[destIdx] + srcPtr[f] * amplitude
                destPtr[destIdx] = max(-1.0, min(1.0, mixed))
            }
        }
    }
    
    // MARK: - Internal Pulse Synthesis Helper
    
    private func writePulse(
        to buffer: AVAudioPCMBuffer,
        atTime time: TimeInterval,
        frequency: Double,
        decay: Double,
        amplitude: Float,
        soundType: ClickSoundType,
        sampleRate: Double,
        channelCount: Int,
        totalFrames: AVAudioFrameCount
    ) {
        guard time >= 0 else { return }
        let startFrame = Int(time * sampleRate)
        guard startFrame < Int(totalFrames) else { return }
        
        let pulseDuration: Double
        switch soundType {
        case .classic, .synthClassic:
            pulseDuration = 0.024
        case .woodblock, .synthWoodblock:
            pulseDuration = 0.055
        case .beep:
            pulseDuration = 0.035
        case .sticks:
            pulseDuration = 0.028
        case .cowbell, .synthCowbell:
            pulseDuration = 0.085
        case .shaker:
            pulseDuration = frequency >= 4500.0 ? 0.075 : (frequency >= 3600.0 ? 0.055 : 0.038)
        case .tambourine:
            pulseDuration = frequency >= 5500.0 ? 0.095 : (frequency >= 4300.0 ? 0.070 : 0.045)
        default:
            pulseDuration = 0.024
        }
        
        let pulseFrames = min(Int(pulseDuration * sampleRate), Int(totalFrames) - startFrame)
        guard pulseFrames > 0 else { return }
        
        var noiseSeed: UInt32 = UInt32(startFrame & 0xFFFF)
        var prevNoise: Float = 0.0
        var lpState: Float = 0.0
        
        for f in 0..<pulseFrames {
            let t = Double(f) / sampleRate
            let envelope = Float(exp(-t * decay))
            let sampleVal: Float
            
            switch soundType {
            case .classic, .synthClassic:
                // Clean transient digital metronome blip with rapid exponential decay
                let clickEnv = Float(exp(-t * max(decay, 180.0)))
                let transient = (t < 0.0015) ? Float(sin(2.0 * .pi * 2400.0 * t)) * 0.25 : 0.0
                let wave = sin(2.0 * .pi * frequency * t)
                sampleVal = (Float(wave) * clickEnv + transient) * amplitude
                
            case .woodblock, .synthWoodblock:
                // Two-tone pitched formant pop with resonant hollow wooden clave body
                let pitchMod = (frequency * 0.85) * (1.0 + 0.18 * exp(-t * 350.0))
                let f1 = sin(2.0 * .pi * pitchMod * t)
                let f2 = sin(2.0 * .pi * (pitchMod * 2.42) * t) * 0.42 * exp(-t * 140.0)
                let strikeEnv = Float(exp(-t * 40.0))
                let bodyEnv = Float(exp(-t * 85.0))
                let attack = min(1.0, Float(t / 0.0008))
                sampleVal = Float(f1 * Double(bodyEnv) + f2 * Double(strikeEnv)) * amplitude * attack
                
            case .beep:
                // Pure smooth sine wave with 1.5ms soft attack
                let attack = min(1.0, Float(t / 0.0015))
                let wave = sin(2.0 * .pi * frequency * t)
                sampleVal = Float(wave) * amplitude * attack * envelope
                
            case .sticks:
                // Drumstick cross-stick: sharp initial noise crack + woody body resonance
                noiseSeed = noiseSeed &* 1664525 &+ 1013904223
                let noise = Float((noiseSeed >> 16) & 0x7FFF) / 16384.0 - 1.0
                let noiseBurst = (t < 0.004) ? noise * Float(1.0 - t / 0.004) * 0.7 : 0.0
                let body = sin(2.0 * .pi * frequency * t) * 0.75 + sin(2.0 * .pi * (frequency * 0.7) * t) * 0.25
                sampleVal = (Float(body) * 0.65 + noiseBurst) * amplitude * envelope
                
            case .cowbell, .synthCowbell:
                // Roland TR-808 style dual-frequency square-wave blend (~800 Hz & ~540 Hz) with metallic bandpass ring
                let scale = frequency >= 700.0 ? 1.12 : (frequency >= 500.0 ? 1.0 : 0.86)
                let sq1: Float = sin(2.0 * .pi * (800.0 * scale) * t) >= 0 ? 1.0 : -1.0
                let sq2: Float = sin(2.0 * .pi * (540.0 * scale) * t) >= 0 ? 1.0 : -1.0
                let rawMix = (sq1 * 0.52 + sq2 * 0.48)
                lpState = lpState + 0.35 * (rawMix - lpState)
                let ringEnv = Float(exp(-t * 55.0) * 0.7 + exp(-t * 22.0) * 0.3)
                sampleVal = lpState * amplitude * ringEnv * 0.75
                
            case .shaker:
                // Distinct subdivision shaping: Accent (open bright shake), 1/4 (crisp), 1/8 (tighter), 1/16 (soft muted brush)
                noiseSeed = noiseSeed &* 1664525 &+ 1013904223
                let white = Float((noiseSeed >> 16) & 0x7FFF) / 16384.0 - 1.0
                let hp = (white - prevNoise) * 0.65
                prevNoise = white
                let lpAlpha: Float = frequency >= 4500.0 ? 0.78 : (frequency >= 3600.0 ? 0.52 : (frequency >= 3200.0 ? 0.30 : 0.16))
                let decayRate: Double = frequency >= 4500.0 ? 30.0 : (frequency >= 3600.0 ? 48.0 : (frequency >= 3200.0 ? 72.0 : 105.0))
                let attackSec: Double = frequency >= 4500.0 ? 0.004 : 0.008
                lpState = lpState + lpAlpha * (hp - lpState)
                let softAttack = min(1.0, Float(t / attackSec))
                let shakerDecay = Float(exp(-t * decayRate))
                let accentChirp: Float = (frequency >= 4500.0 && t < 0.003) ? Float(sin(2.0 * .pi * 5200.0 * t)) * 0.18 : 0.0
                sampleVal = (lpState * 1.2 + accentChirp) * amplitude * softAttack * shakerDecay
                
            case .tambourine:
                // Distinct subdivision shaping: Accent (bright full ring), 1/4 (crisp jingle), 1/8 (tighter), 1/16 (short tick)
                noiseSeed = noiseSeed &* 1664525 &+ 1013904223
                let white = Float((noiseSeed >> 16) & 0x7FFF) / 16384.0 - 1.0
                let hpNoise = (white - prevNoise) * 0.7
                prevNoise = white
                let jingleScale: Double = frequency >= 5500.0 ? 1.18 : (frequency >= 4300.0 ? 1.0 : (frequency >= 3800.0 ? 0.84 : 0.70))
                let jingleDecay: Double = frequency >= 5500.0 ? 22.0 : (frequency >= 4300.0 ? 38.0 : (frequency >= 3800.0 ? 60.0 : 90.0))
                let shimmerWeight: Float = frequency >= 5500.0 ? 0.65 : (frequency >= 4300.0 ? 0.48 : 0.25)
                let impact = (t < 0.0025) ? hpNoise * Float(1.0 - t / 0.0025) * (frequency >= 5500.0 ? 1.0 : 0.65) : 0.0
                let jingle1 = sin(2.0 * .pi * (4350.0 * jingleScale) * t)
                let jingle2 = sin(2.0 * .pi * (5890.0 * jingleScale) * t)
                let jingle3 = sin(2.0 * .pi * (7420.0 * jingleScale) * t)
                let jingles = Float(jingle1 * 0.4 + jingle2 * 0.35 + jingle3 * 0.25) * Float(exp(-t * jingleDecay))
                let shimmer = hpNoise * Float(exp(-t * (jingleDecay * 1.15))) * shimmerWeight
                sampleVal = (impact + jingles * 0.65 + shimmer) * amplitude * 0.85
                
            default:
                let wave = sin(2.0 * .pi * frequency * t) * 0.8 + sin(2.0 * .pi * (frequency * 1.5) * t) * 0.2
                sampleVal = Float(wave) * amplitude * envelope
            }
            
            let frameIdx = startFrame + f
            for ch in 0..<channelCount {
                if let ptr = buffer.floatChannelData?[ch] {
                    let current = ptr[frameIdx]
                    ptr[frameIdx] = max(-1.0, min(1.0, current + sampleVal))
                }
            }
        }
    }
}
