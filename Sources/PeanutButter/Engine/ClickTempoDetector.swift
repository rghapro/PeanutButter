import Foundation
import AVFoundation
import Accelerate

/// Result of analyzing a Click / Metronome track for tempo and dynamic beat grid mapping
public struct ClickTempoAnalysisResult: Sendable {
    public let baseBPM: Double
    public let detectedTimeSignatureNumerator: Int
    public let beatGrid: [BeatGridMarker]
    public let hasDynamicTempoChanges: Bool
    public let minBPM: Double
    public let maxBPM: Double
}

/// High-precision Click / Metronome Track analyzer that detects every beat transient,
/// identifies accented downbeats, and constructs a dynamic beat & measure grid supporting
/// ritardandos, accelerandos, and mid-song tempo changes.
public final class ClickTempoDetector: Sendable {
    
    private struct ClickOnset: Sendable {
        let time: TimeInterval
        let peakAmp: Float
        let brightness: Float
        var accentScore: Float = 0.0
    }
    
    /// Analyzes an isolated Click / Metronome audio buffer and builds a sample-accurate `BeatGridMarker` map.
    public static func analyzeClickTrack(
        clickBuffer: AVAudioPCMBuffer,
        preferredTimeSignatureNumerator: Int = 4,
        preferredTimeSignatureDenominator: Int = 4,
        totalSongDuration: TimeInterval
    ) -> ClickTempoAnalysisResult? {
        guard let floatData = clickBuffer.floatChannelData,
              clickBuffer.frameLength > 0 else {
            return nil
        }
        
        let sampleRate = clickBuffer.format.sampleRate
        let totalFrames = Int(clickBuffer.frameLength)
        let channelPtr = floatData[0]
        
        // 1. Extract 1ms peak envelope across the entire Click track using SIMD `vDSP_maxmgv`
        let windowFrames = max(1, Int(round(sampleRate * 0.001))) // 1ms resolution
        let numWindows = totalFrames / windowFrames
        guard numWindows > 100 else { return nil }
        
        var envelope = [Float](repeating: 0.0, count: numWindows)
        for w in 0..<numWindows {
            let start = w * windowFrames
            var maxVal: Float = 0.0
            vDSP_maxmgv(channelPtr.advanced(by: start), 1, &maxVal, vDSP_Length(windowFrames))
            envelope[w] = maxVal
        }
        
        // Determine noise floor and active click peak reference
        let nonZeroPeaks = envelope.filter { $0 > 0.005 }.sorted()
        guard !nonZeroPeaks.isEmpty else { return nil }
        let refPeak = nonZeroPeaks[min(nonZeroPeaks.count - 1, Int(Double(nonZeroPeaks.count) * 0.90))]
        let threshold = max(0.015, refPeak * 0.18)
        
        // 2. Detect sharp click transient onsets (with 110ms refractory window to ignore click decay/ringing)
        let refractoryWindows = 110 // 110ms
        var rawOnsets: [ClickOnset] = []
        var w = 1
        while w < numWindows - 25 {
            if envelope[w] >= threshold && envelope[w] >= envelope[w - 1] {
                // Find local maximum within the next 20ms
                var localMaxIdx = w
                var localMaxVal = envelope[w]
                let searchEnd = min(numWindows - 1, w + 20)
                for k in w...searchEnd {
                    if envelope[k] > localMaxVal {
                        localMaxVal = envelope[k]
                        localMaxIdx = k
                    }
                }
                
                // Walk back to the sharp leading edge of the click transient (25% of localMaxVal)
                var attackIdx = localMaxIdx
                let edgeThreshold = max(threshold * 0.6, localMaxVal * 0.25)
                while attackIdx > max(0, localMaxIdx - 12) && envelope[attackIdx - 1] >= edgeThreshold {
                    attackIdx -= 1
                }
                
                // Refine to exact sample within `attackIdx` window
                let sampleStart = max(0, (attackIdx - 1) * windowFrames)
                let sampleEnd = min(totalFrames - 1, (localMaxIdx + 2) * windowFrames)
                var exactSample = sampleStart
                for s in sampleStart...sampleEnd {
                    if abs(channelPtr[s]) >= edgeThreshold {
                        exactSample = s
                        break
                    }
                }
                
                // Measure spectral brightness (first-difference / high-frequency content) over 18ms click body
                // Accented downbeat clicks have higher pitch (1.5kHz-3kHz) than normal beat clicks (700Hz-1.2kHz)
                let bodySamples = min(Int(sampleRate * 0.018), totalFrames - exactSample - 1)
                var diffSum: Float = 0.0
                var absSum: Float = 0.0001
                if bodySamples > 16 {
                    for s in 0..<bodySamples {
                        let cur = channelPtr[exactSample + s]
                        let nxt = channelPtr[exactSample + s + 1]
                        diffSum += abs(nxt - cur)
                        absSum += abs(cur)
                    }
                }
                let brightness = diffSum / absSum
                let exactTime = Double(exactSample) / sampleRate
                
                rawOnsets.append(ClickOnset(
                    time: exactTime,
                    peakAmp: localMaxVal,
                    brightness: brightness
                ))
                
                w = localMaxIdx + refractoryWindows
            } else {
                w += 1
            }
        }
        
        guard rawOnsets.count >= 4 else { return nil }
        
        // Normalize peakAmp and brightness into a unified `accentScore` for each click
        let maxAmp = rawOnsets.map { $0.peakAmp }.max() ?? 1.0
        let minBri = rawOnsets.map { $0.brightness }.min() ?? 0.0
        let maxBri = rawOnsets.map { $0.brightness }.max() ?? 1.0
        let briSpan = max(0.01, maxBri - minBri)
        
        for i in 0..<rawOnsets.count {
            let normAmp = rawOnsets[i].peakAmp / max(0.01, maxAmp)
            let normBri = (rawOnsets[i].brightness - minBri) / briSpan
            rawOnsets[i].accentScore = normAmp * 0.45 + normBri * 0.55
        }
        
        // 3. Detect & Filter Out 8th-Note / 16th-Note Subdivision Clicks
        // Many slow worship click tracks play 8th notes (alternating strong beat + weak "&" subdivision)
        var beatOnsets = filterSubdivisionClicks(
            rawOnsets,
            timeSignatureNumerator: preferredTimeSignatureNumerator,
            timeSignatureDenominator: preferredTimeSignatureDenominator
        )
        guard beatOnsets.count >= 4 else { return nil }
        
        // 4. Fill in Half-Time Count-In Gaps (e.g. Bar 1 clicking on Beats 1 & 3 in 4/4, or Beats 1 & 4 in 6/8)
        let (interpolatedOnsets, countInTransitionIndex) = interpolateCountInAndShortGaps(beatOnsets)
        beatOnsets = interpolatedOnsets
        
        // 5. Determine Downbeat Phase (Beat 1 of each measure)
        // In MultiTracks & DAW click tracks, if a half-time count-in transitions to 1x clicks at `countInTransitionIndex`,
        // that transition click is unconditionally Beat 1 of Bar 2 (and index 0 is Beat 1 of Bar 1).
        // Likewise, if clicking starts near 0.0s, index 0 is Beat 1 of Bar 1.
        let timeSig = max(2, min(12, preferredTimeSignatureNumerator))
        let bestPhase: Int
        if let transitionIdx = countInTransitionIndex {
            bestPhase = transitionIdx % timeSig
        } else if beatOnsets[0].time < 1.5 {
            bestPhase = 0
        } else {
            var phaseScores = [Float](repeating: 0.0, count: timeSig)
            var phaseCounts = [Int](repeating: 0, count: timeSig)
            for (idx, onset) in beatOnsets.enumerated() {
                let p = idx % timeSig
                phaseScores[p] += onset.accentScore
                phaseCounts[p] += 1
            }
            for p in 0..<timeSig where phaseCounts[p] > 0 {
                phaseScores[p] /= Float(phaseCounts[p])
            }
            let maxPhaseScore = phaseScores.max() ?? 0.0
            let minPhaseScore = phaseScores.min() ?? 0.0
            if maxPhaseScore - minPhaseScore > 0.20 {
                bestPhase = phaseScores.firstIndex(of: maxPhaseScore) ?? 0
            } else {
                bestPhase = 0
            }
        }
        
        // 6. Compute Instantaneous BPM per Beat & Extrapolate Leading/Trailing Beats to cover 0..totalSongDuration
        var intervals: [Double] = []
        for i in 0..<(beatOnsets.count - 1) {
            let dt = beatOnsets[i + 1].time - beatOnsets[i].time
            if dt >= 0.22 && dt <= 2.2 {
                intervals.append(dt)
            }
        }
        guard !intervals.isEmpty else { return nil }
        
        let beatScale = 4.0 / Double(max(1, preferredTimeSignatureDenominator))
        let sortedIntervals = intervals.sorted()
        let medianInterval = sortedIntervals[sortedIntervals.count / 2]
        let rawMedianBPM = (60.0 / medianInterval) * beatScale
        let baseBPM: Double = abs(rawMedianBPM - round(rawMedianBPM)) < 0.25 ? round(rawMedianBPM) : (round(rawMedianBPM * 10.0) / 10.0)
        
        // Build complete beat timeline including any leading beats before the first click
        let firstInterval = intervals.first ?? medianInterval
        var allBeatTimes: [TimeInterval] = []
        var firstDetectedIndexInAll = 0
        
        if beatOnsets[0].time > firstInterval * 0.85 {
            var preTime = beatOnsets[0].time - firstInterval
            var preList: [TimeInterval] = []
            while preTime >= -0.02 {
                preList.append(max(0.0, preTime))
                preTime -= firstInterval
            }
            preList.reverse()
            allBeatTimes.append(contentsOf: preList)
            firstDetectedIndexInAll = preList.count
        }
        
        for onset in beatOnsets {
            allBeatTimes.append(onset.time)
        }
        
        // Append trailing beats after the last click up to `totalSongDuration` using the final tempo
        let lastInterval = intervals.last ?? medianInterval
        if let lastBeatTime = allBeatTimes.last, lastBeatTime < totalSongDuration - lastInterval * 0.5 {
            var postTime = lastBeatTime + lastInterval
            while postTime <= totalSongDuration + 0.05 {
                allBeatTimes.append(postTime)
                postTime += lastInterval
            }
        }
        
        // Align bar/beat numbering so `firstDetectedIndexInAll + bestPhase` lands on Beat 1
        let downbeatAnchorIndex = firstDetectedIndexInAll + bestPhase
        
        var markers: [BeatGridMarker] = []
        markers.reserveCapacity(allBeatTimes.count)
        
        var minBPM = baseBPM
        var maxBPM = baseBPM
        
        for i in 0..<allBeatTimes.count {
            let t = allBeatTimes[i]
            let rawDt: Double
            if i < allBeatTimes.count - 1 {
                rawDt = max(0.18, min(3.0, allBeatTimes[i + 1] - t))
            } else if i > 0 {
                rawDt = max(0.18, min(3.0, t - allBeatTimes[i - 1]))
            } else {
                rawDt = medianInterval
            }
            
            var instBPM = (60.0 / rawDt) * beatScale
            // Snap micro-jitter (< 0.4 BPM from baseBPM) to clean baseBPM while preserving ritardandos/accelerandos!
            if abs(instBPM - baseBPM) < 0.45 {
                instBPM = baseBPM
            } else {
                instBPM = round(instBPM * 10.0) / 10.0
            }
            
            minBPM = min(minBPM, instBPM)
            maxBPM = max(maxBPM, instBPM)
            
            let relIdx = i - downbeatAnchorIndex
            var beatZeroBased = relIdx % timeSig
            if beatZeroBased < 0 { beatZeroBased += timeSig }
            let beatNumber = beatZeroBased + 1
            let barOffset = Int(floor(Double(relIdx) / Double(timeSig)))
            let barNumber = max(1, barOffset + 1 + (downbeatAnchorIndex > 0 ? 1 : 0))
            
            markers.append(BeatGridMarker(
                time: t,
                bar: barNumber,
                beat: beatNumber,
                instantaneousBPM: instBPM
            ))
        }
        
        // Re-index bar numbers sequentially starting at Bar 1 on the first marker
        var sequentialMarkers: [BeatGridMarker] = []
        sequentialMarkers.reserveCapacity(markers.count)
        var currentBar = 1
        for i in 0..<markers.count {
            if i > 0 && markers[i].beat == 1 {
                currentBar += 1
            }
            sequentialMarkers.append(BeatGridMarker(
                id: markers[i].id,
                time: markers[i].time,
                bar: currentBar,
                beat: markers[i].beat,
                instantaneousBPM: markers[i].instantaneousBPM
            ))
        }
        
        let hasDynamicTempo = (maxBPM - minBPM) >= 1.2
        return ClickTempoAnalysisResult(
            baseBPM: baseBPM,
            detectedTimeSignatureNumerator: timeSig,
            beatGrid: sequentialMarkers,
            hasDynamicTempoChanges: hasDynamicTempo,
            minBPM: minBPM,
            maxBPM: maxBPM
        )
    }
    
    /// Filters out 8th-note or 16th-note subdivision clicks if the click track plays subdivisions
    private static func filterSubdivisionClicks(_ onsets: [ClickOnset], timeSignatureNumerator: Int = 4, timeSignatureDenominator: Int = 4) -> [ClickOnset] {
        guard onsets.count >= 8 else { return onsets }
        
        var iois: [Double] = []
        for i in 0..<(onsets.count - 1) {
            let dt = onsets[i + 1].time - onsets[i].time
            if dt > 0.12 && dt < 2.0 {
                iois.append(dt)
            }
        }
        guard !iois.isEmpty else { return onsets }
        let medianIOI = iois.sorted()[iois.count / 2]
        let impliedBPM = 60.0 / medianIOI

        // In 6/8 (or X/8), each beat IS an eighth-note pulse (e.g. 156 eighth-notes/min for 78 BPM),
        // so keep all 6 beats per measure unless the click is clicking 16th-note subdivisions (> 240 BPM).
        if timeSignatureDenominator == 8 && impliedBPM <= 240.0 {
            return onsets
        }
        
        // If implied BPM is fast (> 118 BPM), check if even/odd clicks alternate strong/weak (8th note subdivisions)
        // or if the detected pulse is in double-time (e.g. 156 BPM for a 78 BPM song).
        if impliedBPM > 118.0 {
            var evenAmp: Float = 0.0
            var oddAmp: Float = 0.0
            var evenScore: Float = 0.0
            var oddScore: Float = 0.0
            var evenCount = 0
            var oddCount = 0
            
            for i in 0..<onsets.count {
                if i % 2 == 0 {
                    evenAmp += onsets[i].peakAmp
                    evenScore += onsets[i].accentScore
                    evenCount += 1
                } else {
                    oddAmp += onsets[i].peakAmp
                    oddScore += onsets[i].accentScore
                    oddCount += 1
                }
            }
            let avgEvenAmp = evenAmp / Float(max(1, evenCount))
            let avgOddAmp = oddAmp / Float(max(1, oddCount))
            let ampRatio = max(avgEvenAmp, avgOddAmp) / max(0.001, min(avgEvenAmp, avgOddAmp))

            let avgEvenScore = evenScore / Float(max(1, evenCount))
            let avgOddScore = oddScore / Float(max(1, oddCount))
            let scoreRatio = max(avgEvenScore, avgOddScore) / max(0.001, min(avgEvenScore, avgOddScore))

            let isDoubleTime68 = (timeSignatureNumerator == 6) && (impliedBPM >= 145.0 || (impliedBPM >= 136.0 && (ampRatio > 1.06 || scoreRatio > 1.05)))
            let isAlternatingOrFast = ampRatio > 1.15 || scoreRatio > 1.12 || impliedBPM > 150.0
            
            if isAlternatingOrFast || isDoubleTime68 {
                let keepEven = (avgEvenAmp >= avgOddAmp) || (avgEvenScore >= avgOddScore && ampRatio < 1.05)
                return onsets.enumerated().compactMap { idx, onset in
                    (idx % 2 == (keepEven ? 0 : 1)) ? onset : nil
                }
            }
        }
        
        return onsets
    }
    
    /// Interpolates missing beats during half-time count-ins (e.g. "1... 2... 1, 2, 3, 4" in 4/4 or "1... 4... 1, 2, 3, 4, 5, 6" in 6/8)
    /// and returns both the interpolated onsets and the index where regular 1x beat clicking begins (Bar 2 Beat 1).
    private static func interpolateCountInAndShortGaps(_ onsets: [ClickOnset]) -> ([ClickOnset], Int?) {
        guard onsets.count >= 4 else { return (onsets, nil) }
        
        var iois: [Double] = []
        for i in 0..<(onsets.count - 1) {
            let dt = onsets[i + 1].time - onsets[i].time
            if dt > 0.18 && dt < 1.8 {
                iois.append(dt)
            }
        }
        guard !iois.isEmpty else { return (onsets, nil) }
        let medianBeat = iois.sorted()[iois.count / 2]
        
        // Helper to find the nearest true 1x single-beat interval around index `i`
        // (avoids using another count-in gap like onsets[2]-onsets[1] as the reference beat!)
        func nearestSingleBeatInterval(around idx: Int) -> Double {
            for radius in 0...8 {
                for candidate in [idx + radius, idx - radius] {
                    if candidate >= 0 && candidate < onsets.count - 1 {
                        let dt = onsets[candidate + 1].time - onsets[candidate].time
                        if dt >= medianBeat * 0.68 && dt <= medianBeat * 1.38 {
                            return dt
                        }
                    }
                }
            }
            return medianBeat
        }
        
        var result: [ClickOnset] = []
        result.reserveCapacity(onsets.count + 8)
        var countInTransitionIndex: Int? = nil
        var inInitialCountInGap = false
        
        for i in 0..<onsets.count {
            let current = onsets[i]
            let insertedIndex = result.count
            result.append(current)
            
            if i < onsets.count - 1 {
                let next = onsets[i + 1]
                let gap = next.time - current.time
                let localRef = nearestSingleBeatInterval(around: i)
                
                // Check if gap is ~2x, ~3x, ~4x, or ~6x a single beat (e.g. 4/4 half-note count-in = 2x, 6/8 dotted-quarter count-in = 3x)
                let multiple = Int(round(gap / localRef))
                if multiple >= 2 && multiple <= 6 {
                    let expectedGap = Double(multiple) * localRef
                    if abs(gap - expectedGap) < localRef * 0.25 {
                        if i <= 3 {
                            inInitialCountInGap = true
                        }
                        let step = gap / Double(multiple)
                        for m in 1..<multiple {
                            let interpTime = current.time + step * Double(m)
                            result.append(ClickOnset(
                                time: interpTime,
                                peakAmp: current.peakAmp * 0.7,
                                brightness: current.brightness * 0.9,
                                accentScore: current.accentScore * 0.6
                            ))
                        }
                    }
                } else if multiple == 1 && inInitialCountInGap && countInTransitionIndex == nil {
                    // The very first onset where steady 1x beat clicking begins after the initial count-in gap is Bar 2 Beat 1!
                    countInTransitionIndex = insertedIndex
                    inInitialCountInGap = false
                }
            }
        }
        
        return (result, countInTransitionIndex)
    }
}
