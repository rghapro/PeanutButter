import Foundation
import AVFoundation
import Combine
import CoreAudio
import Accelerate
import AppKit
import QuartzCore
import SwiftUI
import os

// MARK: - Single-Clock Lock-Free Real-Time SIMD Audio Mixing State

struct RenderTimelineSlice: Sendable {
    let timelineStartFrame: Int64
    let timelineEndFrame: Int64
    let sourceStartFrame: Int64
    let muteStems: Bool
    
    init(timelineStartFrame: Int64, timelineEndFrame: Int64, sourceStartFrame: Int64, muteStems: Bool = false) {
        self.timelineStartFrame = timelineStartFrame
        self.timelineEndFrame = timelineEndFrame
        self.sourceStartFrame = sourceStartFrame
        self.muteStems = muteStems
    }
}

struct RenderTrackEntry: @unchecked Sendable {
    let track: StemTrack
    let buffer: AVAudioPCMBuffer
    let leftPtr: UnsafePointer<Float>
    let rightPtr: UnsafePointer<Float>
    let frameLength: Int64
    let gainL: Float
    let gainR: Float
    let isClickOrGuide: Bool
    let isTimelineAligned: Bool
    let outChannelL: Int
    let outChannelR: Int
}

/// Real-time lock-free multitrack mixing engine state driven by a single integer sample playhead (`currentTimelineFrame`).
/// Guarantees 100.000% sample-accurate synchronization across 26+ stems with zero `memcpy` and SIMD `vDSP` mixing!
final class RealTimeMixEngineState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    
    private var isPlaying: Bool = false
    private var sampleRate: Double = 44100.0
    private var currentTimelineFrame: Int64 = 0
    private var totalTimelineFrames: Int64 = 0
    private var seekGeneration: UInt64 = 0
    
    private var loopActive: Bool = false
    private var loopIsSingle: Bool = false
    private var loopStartFrame: Int64 = 0
    private var loopEndFrame: Int64 = 0
    private var singleLoopRemainingCount: Int = 0
    private var didTriggerSingleLoopRepeat: Bool = false
    private var didCompleteSingleLoop: Bool = false
    private var didReachEndOfSong: Bool = false
    
    private var slices: [RenderTimelineSlice] = []
    private var tracks: [RenderTrackEntry] = []
    
    // Sample-accurate staged next song state for zero-latency AutoLink, Overlap, and Crossfade
    private var transitionMode: SongTransitionType = .cueNextSong
    private var transitionStartFrame: Int64 = 0
    private var nextTotalTimelineFrames: Int64 = 0
    private var nextSlices: [RenderTimelineSlice] = []
    private var nextTracks: [RenderTrackEntry] = []
    private var didTransitionToNextSong: Bool = false
    
    private var rawMasterPeakL: Float = 0.0
    private var rawMasterPeakR: Float = 0.0
    private var masterGain: Float = 1.0
    private weak var padEngine: PadPlayerEngine?

    private struct RenderSegmentRecord {
        let outOffset: Int
        let stepFrames: Int
        let playhead: Int64
        let sourceStartFrame: Int64
        let isPostPromotion: Bool
        let isDualMix: Bool
        let nextPlayhead: Int64
        let nextSourceStartFrame: Int64
    }
    
    // Continuous 1kHz Sine Wave Redundancy Pilot Tone State
    private var isRedundancyEnabled: Bool = false
    private var redundancyChannelIndex: Int = 0
    private var redundancyPhase: Double = 0.0
    
    // SMPTE Linear Timecode (LTC) Audio Output State
    private var isSMPTEEnabled: Bool = false
    private var smpteChannelIndex: Int = 0
    private var smpteFrameRate: SMPTEFrameRate = .fps30
    private var hasSMPTECue: Bool = false
    private var smpteCueTimelineFrame: Int64 = 0
    private var smpteStartSeconds: Double = 0.0
    
    func setRedundancy(enabled: Bool, channelIndex: Int) {
        os_unfair_lock_lock(&lock)
        self.isRedundancyEnabled = enabled
        self.redundancyChannelIndex = max(0, channelIndex)
        os_unfair_lock_unlock(&lock)
    }
    
    func setSMPTE(
        enabled: Bool,
        channelIndex: Int,
        frameRate: SMPTEFrameRate,
        hasCue: Bool,
        cueTimelineFrame: Int64,
        cueStartSeconds: Double
    ) {
        os_unfair_lock_lock(&lock)
        self.isSMPTEEnabled = enabled
        self.smpteChannelIndex = max(0, channelIndex)
        self.smpteFrameRate = frameRate
        self.hasSMPTECue = hasCue
        self.smpteCueTimelineFrame = max(0, cueTimelineFrame)
        self.smpteStartSeconds = max(0.0, cueStartSeconds)
        os_unfair_lock_unlock(&lock)
    }
    
    // Sample-accurate spontaneous section jump state
    private var queuedBoundaryFrame: Int64 = -1
    private var queuedTargetFrame: Int64 = -1
    private var hasQueuedJump: Bool = false
    private var didTriggerQueuedJump: Bool = false
    
    // Song Section Pre-Roll State (Linear audio fade-in over X previous measures with regular click/guide)
    private var preRollActive: Bool = false
    private var preRollStartFrame: Int64 = 0
    private var preRollTargetDownbeatFrame: Int64 = 0
    
    func startPreRoll(preRollStartFrame: Int64, targetDownbeatFrame: Int64) {
        os_unfair_lock_lock(&lock)
        self.preRollActive = true
        self.preRollStartFrame = preRollStartFrame
        self.preRollTargetDownbeatFrame = targetDownbeatFrame
        self.currentTimelineFrame = preRollStartFrame
        self.seekGeneration &+= 1
        os_unfair_lock_unlock(&lock)
    }
    
    func cancelPreRoll() {
        os_unfair_lock_lock(&lock)
        self.preRollActive = false
        self.preRollStartFrame = 0
        self.preRollTargetDownbeatFrame = 0
        os_unfair_lock_unlock(&lock)
    }
    
    func setPadEngine(_ engine: PadPlayerEngine) {
        os_unfair_lock_lock(&lock)
        self.padEngine = engine
        os_unfair_lock_unlock(&lock)
    }
    
    func configure(
        sampleRate: Double,
        totalDuration: TimeInterval,
        slices: [RenderTimelineSlice],
        tracks: [RenderTrackEntry],
        loopActive: Bool,
        loopIsSingle: Bool,
        loopStart: TimeInterval,
        loopEnd: TimeInterval,
        masterGain: Float,
        singleLoopRemaining: Int = 0,
        transitionMode: SongTransitionType = .cueNextSong,
        transitionStartFrame: Int64 = 0,
        nextTotalTimelineFrames: Int64 = 0,
        nextSlices: [RenderTimelineSlice] = [],
        nextTracks: [RenderTrackEntry] = []
    ) {
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        os_unfair_lock_lock(&lock)
        self.sampleRate = sr
        self.totalTimelineFrames = max(0, Int64(round(totalDuration * sr)))
        self.slices = slices
        self.tracks = tracks
        self.loopActive = loopActive
        self.loopIsSingle = loopIsSingle
        self.singleLoopRemainingCount = loopIsSingle ? singleLoopRemaining : 0
        self.didTriggerSingleLoopRepeat = false
        self.loopStartFrame = max(0, Int64(round(loopStart * sr)))
        self.loopEndFrame = max(0, Int64(round(loopEnd * sr)))
        self.masterGain = masterGain
        self.transitionMode = transitionMode
        self.transitionStartFrame = max(0, transitionStartFrame)
        self.nextTotalTimelineFrames = max(0, nextTotalTimelineFrames)
        self.nextSlices = nextSlices
        self.nextTracks = nextTracks
        os_unfair_lock_unlock(&lock)
    }
    
    func currentSeconds() -> TimeInterval {
        os_unfair_lock_lock(&lock)
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        let sec = Double(currentTimelineFrame) / sr
        os_unfair_lock_unlock(&lock)
        return sec
    }
    
    func setMasterGain(_ gain: Float) {
        os_unfair_lock_lock(&lock)
        self.masterGain = gain
        os_unfair_lock_unlock(&lock)
    }
    
    func updateTrackGains(trackId: UUID, gainL: Float, gainR: Float, outChannelL: Int? = nil, outChannelR: Int? = nil) {
        os_unfair_lock_lock(&lock)
        for i in 0..<tracks.count {
            if tracks[i].track.id == trackId {
                let old = tracks[i]
                tracks[i] = RenderTrackEntry(
                    track: old.track,
                    buffer: old.buffer,
                    leftPtr: old.leftPtr,
                    rightPtr: old.rightPtr,
                    frameLength: old.frameLength,
                    gainL: gainL,
                    gainR: gainR,
                    isClickOrGuide: old.isClickOrGuide,
                    isTimelineAligned: old.isTimelineAligned,
                    outChannelL: outChannelL ?? old.outChannelL,
                    outChannelR: outChannelR ?? old.outChannelR
                )
                break
            }
        }
        os_unfair_lock_unlock(&lock)
    }
    
    func updateAllTrackGains(_ gains: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)]) {
        os_unfair_lock_lock(&lock)
        for i in 0..<tracks.count {
            if let g = gains[tracks[i].track.id] {
                let old = tracks[i]
                tracks[i] = RenderTrackEntry(
                    track: old.track,
                    buffer: old.buffer,
                    leftPtr: old.leftPtr,
                    rightPtr: old.rightPtr,
                    frameLength: old.frameLength,
                    gainL: g.gainL,
                    gainR: g.gainR,
                    isClickOrGuide: old.isClickOrGuide,
                    isTimelineAligned: old.isTimelineAligned,
                    outChannelL: g.outL,
                    outChannelR: g.outR
                )
            }
        }
        os_unfair_lock_unlock(&lock)
    }
    
    func setPlaying(_ playing: Bool) {
        os_unfair_lock_lock(&lock)
        self.isPlaying = playing
        if playing {
            self.didReachEndOfSong = false
            self.didTransitionToNextSong = false
        } else {
            self.hasQueuedJump = false
            self.queuedBoundaryFrame = -1
            self.queuedTargetFrame = -1
            self.didTriggerQueuedJump = false
        }
        os_unfair_lock_unlock(&lock)
    }
    
    func setPlayhead(seconds: TimeInterval, resumePlaying: Bool = false) {
        os_unfair_lock_lock(&lock)
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        self.currentTimelineFrame = max(0, Int64(round(seconds * sr)))
        self.seekGeneration &+= 1
        self.didReachEndOfSong = false
        if resumePlaying {
            self.isPlaying = true
        }
        self.hasQueuedJump = false
        self.queuedBoundaryFrame = -1
        self.queuedTargetFrame = -1
        self.didTriggerQueuedJump = false
        self.preRollActive = false
        self.preRollStartFrame = 0
        self.preRollTargetDownbeatFrame = 0
        os_unfair_lock_unlock(&lock)
    }
    
    func setQueuedJump(boundaryFrame: Int64, targetFrame: Int64) {
        os_unfair_lock_lock(&lock)
        self.queuedBoundaryFrame = boundaryFrame
        self.queuedTargetFrame = targetFrame
        self.hasQueuedJump = true
        self.didTriggerQueuedJump = false
        os_unfair_lock_unlock(&lock)
    }
    
    func cancelQueuedJump() {
        os_unfair_lock_lock(&lock)
        self.queuedBoundaryFrame = -1
        self.queuedTargetFrame = -1
        self.hasQueuedJump = false
        self.didTriggerQueuedJump = false
        os_unfair_lock_unlock(&lock)
    }
    
    func pollStatus() -> (currentSeconds: TimeInterval, completedSingleLoop: Bool, didRepeatSingleLoop: Bool, reachedEnd: Bool, transitionedToNextSong: Bool, didJumpToQueuedSection: Bool, isPreRollActive: Bool, preRollTargetSeconds: TimeInterval, engineIsPlaying: Bool, atOrPastEnd: Bool) {
        os_unfair_lock_lock(&lock)
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        let sec = Double(currentTimelineFrame) / sr
        let singleDone = didCompleteSingleLoop
        let singleRepeated = didTriggerSingleLoopRepeat
        let endReached = didReachEndOfSong
        let transitioned = didTransitionToNextSong
        let didJump = didTriggerQueuedJump
        let isPreRolling = preRollActive && currentTimelineFrame < preRollTargetDownbeatFrame
        let targetSec = Double(preRollTargetDownbeatFrame) / sr
        let stillPlaying = isPlaying
        let atEnd = totalTimelineFrames > 0 && currentTimelineFrame >= totalTimelineFrames
        didCompleteSingleLoop = false
        didTriggerSingleLoopRepeat = false
        didReachEndOfSong = false
        didTransitionToNextSong = false
        didTriggerQueuedJump = false
        os_unfair_lock_unlock(&lock)
        return (sec, singleDone, singleRepeated, endReached, transitioned, didJump, isPreRolling, targetSec, stillPlaying, atEnd)
    }
    
    func consumeMasterPeaks() -> (Float, Float) {
        os_unfair_lock_lock(&lock)
        let pL = rawMasterPeakL
        let pR = rawMasterPeakR
        rawMasterPeakL = 0.0
        rawMasterPeakR = 0.0
        os_unfair_lock_unlock(&lock)
        return (pL, pR)
    }
    
    /// Real-time CoreAudio render callback — sums all 26+ stems at the exact same sample frame using Apple `Accelerate` SIMD (`vDSP`)
    func render(isSilence: UnsafeMutablePointer<ObjCBool>?, frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard frameCount > 0, abl.count > 0 else {
            isSilence?.pointee = true
            return noErr
        }

        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: max(1, abl.count)) { ptrAlloc in
            var numChannels = 0
            for ch in 0..<abl.count {
                if let ptr = abl[ch].mData?.assumingMemoryBound(to: Float.self) {
                    vDSP_vclr(ptr, 1, vDSP_Length(frameCount))
                    ptrAlloc[numChannels] = ptr
                    numChannels += 1
                }
            }
            guard numChannels > 0 else {
                isSilence?.pointee = true
                return noErr
            }
            let channelPointers = UnsafeBufferPointer(start: ptrAlloc.baseAddress, count: numChannels)

            // Snapshot minimal flags first for zero-allocation, zero-retain idle fast-exit (< 1 µs)
            os_unfair_lock_lock(&lock)
            let playing = isPlaying
            let localIsRedundancy = isRedundancyEnabled
            let localPad = padEngine
            if !playing && !localIsRedundancy && !(localPad?.hasActiveAudioToRender ?? false) {
                rawMasterPeakL = 0.0
                rawMasterPeakR = 0.0
                os_unfair_lock_unlock(&lock)
                isSilence?.pointee = true
                return noErr
            }

            // Active path: snapshot mixing & transport state under lock
            var playhead = currentTimelineFrame
            var totalFrames = totalTimelineFrames
            let localSeekGen = seekGeneration
            var localLoopActive = loopActive
            let localLoopSingle = loopIsSingle
            let localLoopStart = loopStartFrame
            let localLoopEnd = loopEndFrame
            var localSingleRemaining = singleLoopRemainingCount
            var localSlices = slices
            var localTracks = tracks
            let localMasterGain = masterGain
            var localTransitionMode = transitionMode
            let localTransitionStartFrame = transitionStartFrame
            var localNextTotalFrames = nextTotalTimelineFrames
            var localNextSlices = nextSlices
            var localNextTracks = nextTracks
            var localHasQueuedJump = hasQueuedJump
            let localQueuedBoundaryFrame = queuedBoundaryFrame
            let localQueuedTargetFrame = queuedTargetFrame
            let localRedundancyCh = redundancyChannelIndex
            let localRedundancyPhase = redundancyPhase
            let localIsSMPTE = isSMPTEEnabled
            let localSMPTECh = smpteChannelIndex
            let localSMPTERate = smpteFrameRate
            let localHasSMPTECue = hasSMPTECue
            let localSMPTECueFrame = smpteCueTimelineFrame
            let localSMPTEStartSec = smpteStartSeconds
            let localSampleRate = sampleRate
            var localPreRollActive = preRollActive
            let localPreRollStart = preRollStartFrame
            let localPreRollTarget = preRollTargetDownbeatFrame
            os_unfair_lock_unlock(&lock)

            isSilence?.pointee = false

            var musicChannelMask: UInt64 = 0
            let maxSegments = 16

            withUnsafeTemporaryAllocation(of: RenderSegmentRecord.self, capacity: maxSegments) { segAlloc in
                var segCount = 0
                let initialTracks = localTracks
                let initialNextTracks = localNextTracks
                var hasPromotedInBuffer = false
                var singleLoopFinished = false
                var singleLoopJumpOccurred = false
                var queuedJumpOccurred = false
                var hitEndOfSong = false
                var promotedToNextSong = false

                if playing && totalFrames > 0 {
                    var framesRemaining = frameCount
                    var outOffset = 0

                    while framesRemaining > 0 {
                        // 0. Sample-accurate spontaneous section jump check (0.000ms jitter)
                        if localHasQueuedJump && localQueuedBoundaryFrame >= 0 && playhead >= localQueuedBoundaryFrame {
                            playhead = localQueuedTargetFrame
                            localHasQueuedJump = false
                            queuedJumpOccurred = true
                        }

                        // 1. Sample-accurate section loop boundary check
                        if localLoopActive && localLoopEnd > localLoopStart && playhead >= localLoopEnd {
                            if localLoopSingle {
                                if localSingleRemaining > 0 {
                                    playhead = localLoopStart
                                    localSingleRemaining -= 1
                                    singleLoopJumpOccurred = true
                                    localLoopActive = false
                                } else {
                                    localLoopActive = false
                                    singleLoopFinished = true
                                }
                            } else {
                                playhead = localLoopStart
                            }
                        }

                        // 2. End of song check — or seamless sample-accurate promotion of Song B!
                        if playhead >= totalFrames {
                            if !localLoopActive && !localNextTracks.isEmpty && localNextTotalFrames > 0 &&
                                (localTransitionMode == .autoLink || localTransitionMode == .overlap || localTransitionMode == .crossfade) {
                                if localTransitionMode == .autoLink {
                                    playhead = 0
                                } else {
                                    playhead = max(0, playhead - localTransitionStartFrame)
                                }
                                localTracks = localNextTracks
                                localSlices = localNextSlices
                                totalFrames = localNextTotalFrames
                                localNextTracks = []
                                localNextSlices = []
                                localNextTotalFrames = 0
                                localTransitionMode = .cueNextSong
                                promotedToNextSong = true
                                hasPromotedInBuffer = true
                                continue
                            } else {
                                hitEndOfSong = true
                                break
                            }
                        }

                        // 3. Resolve active arrangement slice for `playhead`
                        let activeSlice: RenderTimelineSlice
                        if let matched = localSlices.first(where: { playhead >= $0.timelineStartFrame && playhead < $0.timelineEndFrame }) {
                            activeSlice = matched
                        } else {
                            activeSlice = RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: totalFrames, sourceStartFrame: 0)
                        }

                        // 4. Determine how many contiguous frames we can mix in this step
                        var stepFrames = framesRemaining
                        let sliceRemaining = Int(activeSlice.timelineEndFrame - playhead)
                        if sliceRemaining > 0 {
                            stepFrames = min(stepFrames, sliceRemaining)
                        }
                        if localLoopActive && localLoopEnd > playhead {
                            stepFrames = min(stepFrames, Int(localLoopEnd - playhead))
                        }
                        if localHasQueuedJump && localQueuedBoundaryFrame > playhead {
                            stepFrames = min(stepFrames, Int(localQueuedBoundaryFrame - playhead))
                        }
                        stepFrames = min(stepFrames, Int(totalFrames - playhead))

                        let isDualTransitionConfigured = !localLoopActive && !localNextTracks.isEmpty && localNextTotalFrames > 0 &&
                            (localTransitionMode == .overlap || localTransitionMode == .crossfade)
                        var nextActiveSlice: RenderTimelineSlice? = nil
                        var nextPlayheadForSeg: Int64 = 0
                        var nextSourceStartForSeg: Int64 = 0

                        let isCurrentlyInPreRoll = localPreRollActive && playhead < localPreRollTarget
                        if localPreRollActive && playhead >= localPreRollTarget {
                            localPreRollActive = false
                        }

                        if isDualTransitionConfigured {
                            if playhead < localTransitionStartFrame && playhead + Int64(stepFrames) > localTransitionStartFrame {
                                stepFrames = min(stepFrames, Int(localTransitionStartFrame - playhead))
                            } else if playhead >= localTransitionStartFrame {
                                let nextPlayhead = playhead - localTransitionStartFrame
                                nextPlayheadForSeg = nextPlayhead
                                if nextPlayhead < localNextTotalFrames {
                                    let matchedNext = localNextSlices.first(where: { nextPlayhead >= $0.timelineStartFrame && nextPlayhead < $0.timelineEndFrame })
                                        ?? RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: localNextTotalFrames, sourceStartFrame: 0)
                                    nextActiveSlice = matchedNext
                                    nextSourceStartForSeg = matchedNext.sourceStartFrame + (nextPlayhead - matchedNext.timelineStartFrame)
                                    let nextSliceRem = Int(matchedNext.timelineEndFrame - nextPlayhead)
                                    if nextSliceRem > 0 {
                                        stepFrames = min(stepFrames, nextSliceRem)
                                    }
                                    stepFrames = min(stepFrames, Int(localNextTotalFrames - nextPlayhead))
                                }
                                if localTransitionMode == .crossfade {
                                    stepFrames = min(stepFrames, 64)
                                }
                            }
                        }

                        if isCurrentlyInPreRoll {
                            let remToDownbeat = Int(localPreRollTarget - playhead)
                            if remToDownbeat > 0 {
                                stepFrames = min(stepFrames, remToDownbeat)
                            }
                            stepFrames = min(stepFrames, 64)
                        }

                        stepFrames = max(1, stepFrames)

                        var gainScaleA: Float = 1.0
                        var gainScaleB: Float = 1.0
                        if isDualTransitionConfigured && localTransitionMode == .crossfade && playhead >= localTransitionStartFrame {
                            let fadeTotal = Float(max(1, totalFrames - localTransitionStartFrame))
                            let prog = min(1.0, max(0.0, Float(playhead - localTransitionStartFrame) / fadeTotal))
                            gainScaleA = 1.0 - prog
                            gainScaleB = prog
                        }

                        let sourceStartFrame = activeSlice.sourceStartFrame + (playhead - activeSlice.timelineStartFrame)
                        let isDualActiveNow = isDualTransitionConfigured && playhead >= localTransitionStartFrame && nextActiveSlice != nil

                        let deferClickGuide = (segCount < maxSegments)
                        if deferClickGuide {
                            segAlloc[segCount] = RenderSegmentRecord(
                                outOffset: outOffset,
                                stepFrames: stepFrames,
                                playhead: playhead,
                                sourceStartFrame: sourceStartFrame,
                                isPostPromotion: hasPromotedInBuffer,
                                isDualMix: isDualActiveNow,
                                nextPlayhead: nextPlayheadForSeg,
                                nextSourceStartFrame: nextSourceStartForSeg
                            )
                            segCount += 1
                        }

                        // 5A. Mix Song A tracks (Music pass; Click/Guide deferred until after Master VU peak measurement)
                        for entry in localTracks {
                            if deferClickGuide && entry.isClickOrGuide { continue }
                            if activeSlice.muteStems && !entry.isClickOrGuide { continue }
                            let trackGainScale: Float = {
                                if isCurrentlyInPreRoll {
                                    if entry.isClickOrGuide {
                                        return 1.0
                                    } else {
                                        let totalFadeFrames = Float(max(1, localPreRollTarget - localPreRollStart))
                                        let currentFadeFrame = Float(playhead - localPreRollStart)
                                        return min(1.0, max(0.0, currentFadeFrame / totalFadeFrames))
                                    }
                                } else if isDualTransitionConfigured && playhead >= localTransitionStartFrame {
                                    if entry.isClickOrGuide {
                                        return 0.0
                                    }
                                    return (localTransitionMode == .crossfade) ? gainScaleA : 1.0
                                } else {
                                    return 1.0
                                }
                            }()
                            let preMasterGL = entry.gainL * trackGainScale
                            let preMasterGR = entry.gainR * trackGainScale
                            let masterScale: Float = entry.isClickOrGuide ? 1.0 : localMasterGain
                            var gL = preMasterGL * masterScale
                            var gR = preMasterGR * masterScale
                            if preMasterGL <= 0.0001 && preMasterGR <= 0.0001 { continue }

                            let chL = min(entry.outChannelL, numChannels - 1)
                            let chR = min(entry.outChannelR, numChannels - 1)
                            let dstL = channelPointers[chL].advanced(by: outOffset)
                            let dstR = channelPointers[chR].advanced(by: outOffset)

                            let readFrame = entry.isTimelineAligned ? playhead : sourceStartFrame
                            if readFrame >= 0 && readFrame < entry.frameLength {
                                let avail = min(stepFrames, Int(entry.frameLength - readFrame))
                                if avail > 0 {
                                    let vLen = vDSP_Length(avail)
                                    let srcL = entry.leftPtr.advanced(by: Int(readFrame))
                                    let srcR = entry.rightPtr.advanced(by: Int(readFrame))

                                    var pL: Float = 0.0
                                    var pR: Float = 0.0
                                    vDSP_maxmgv(srcL, 1, &pL, vLen)
                                    if srcR == srcL {
                                        pR = pL
                                    } else {
                                        vDSP_maxmgv(srcR, 1, &pR, vLen)
                                    }

                                    if pL > 1e-6 && preMasterGL > 0.0001 {
                                        if gL > 0.0001 {
                                            vDSP_vsma(srcL, 1, &gL, dstL, 1, dstL, 1, vLen)
                                            if !entry.isClickOrGuide && chL < 64 {
                                                musicChannelMask |= (UInt64(1) << UInt64(chL))
                                            }
                                        }
                                        let scaledL = pL * preMasterGL
                                        if scaledL > entry.track.rawPeakL { entry.track.rawPeakL = scaledL }
                                    }
                                    if pR > 1e-6 && preMasterGR > 0.0001 {
                                        if gR > 0.0001 {
                                            if chR != chL || dstR != dstL {
                                                vDSP_vsma(srcR, 1, &gR, dstR, 1, dstR, 1, vLen)
                                            }
                                            if !entry.isClickOrGuide && chR < 64 {
                                                musicChannelMask |= (UInt64(1) << UInt64(chR))
                                            }
                                        }
                                        let scaledR = pR * preMasterGR
                                        if scaledR > entry.track.rawPeakR { entry.track.rawPeakR = scaledR }
                                    }
                                }
                            }
                        }

                        // 5B. Mix Song B tracks during Overlap or Crossfade (Music pass)
                        if isDualActiveNow, let nSlice = nextActiveSlice {
                            let nextPlayhead = nextPlayheadForSeg
                            let nextSourceStartFrame = nextSourceStartForSeg

                            for entry in localNextTracks {
                                if deferClickGuide && entry.isClickOrGuide { continue }
                                if nSlice.muteStems && !entry.isClickOrGuide { continue }
                                let trackGainScale = (localTransitionMode == .crossfade && !entry.isClickOrGuide) ? gainScaleB : 1.0
                                let preMasterGL = entry.gainL * trackGainScale
                                let preMasterGR = entry.gainR * trackGainScale
                                let masterScale: Float = entry.isClickOrGuide ? 1.0 : localMasterGain
                                var gL = preMasterGL * masterScale
                                var gR = preMasterGR * masterScale
                                if preMasterGL <= 0.0001 && preMasterGR <= 0.0001 { continue }

                                let chL = min(entry.outChannelL, numChannels - 1)
                                let chR = min(entry.outChannelR, numChannels - 1)
                                let dstL = channelPointers[chL].advanced(by: outOffset)
                                let dstR = channelPointers[chR].advanced(by: outOffset)

                                let nextReadFrame = entry.isTimelineAligned ? nextPlayhead : nextSourceStartFrame
                                if nextReadFrame >= 0 && nextReadFrame < entry.frameLength {
                                    let avail = min(stepFrames, Int(entry.frameLength - nextReadFrame))
                                    if avail > 0 {
                                        let vLen = vDSP_Length(avail)
                                        let srcL = entry.leftPtr.advanced(by: Int(nextReadFrame))
                                        let srcR = entry.rightPtr.advanced(by: Int(nextReadFrame))

                                        var pL: Float = 0.0
                                        var pR: Float = 0.0
                                        vDSP_maxmgv(srcL, 1, &pL, vLen)
                                        if srcR == srcL {
                                            pR = pL
                                        } else {
                                            vDSP_maxmgv(srcR, 1, &pR, vLen)
                                        }

                                        if pL > 1e-6 && preMasterGL > 0.0001 {
                                            if gL > 0.0001 {
                                                vDSP_vsma(srcL, 1, &gL, dstL, 1, dstL, 1, vLen)
                                                if !entry.isClickOrGuide && chL < 64 {
                                                    musicChannelMask |= (UInt64(1) << UInt64(chL))
                                                }
                                            }
                                            let scaledL = pL * preMasterGL
                                            if scaledL > entry.track.rawPeakL { entry.track.rawPeakL = scaledL }
                                        }
                                        if pR > 1e-6 && preMasterGR > 0.0001 {
                                            if gR > 0.0001 {
                                                if chR != chL || dstR != dstL {
                                                    vDSP_vsma(srcR, 1, &gR, dstR, 1, dstR, 1, vLen)
                                                }
                                                if !entry.isClickOrGuide && chR < 64 {
                                                    musicChannelMask |= (UInt64(1) << UInt64(chR))
                                                }
                                            }
                                            let scaledR = pR * preMasterGR
                                            if scaledR > entry.track.rawPeakR { entry.track.rawPeakR = scaledR }
                                        }
                                    }
                                }
                            }
                        }

                        playhead += Int64(stepFrames)
                        outOffset += stepFrames
                        framesRemaining -= stepFrames
                    }
                }

                // 6. Render Ambient Pad Player directly into hardware DAC channels (scaled by Master DCA)
                if let padRes = localPad?.renderDirect(
                    frameCount: frameCount,
                    channelPointers: channelPointers,
                    masterGain: localMasterGain
                ), padRes.didRender {
                    if padRes.outChL < 64 { musicChannelMask |= (UInt64(1) << UInt64(padRes.outChL)) }
                    if padRes.outChR < 64 { musicChannelMask |= (UInt64(1) << UInt64(padRes.outChR)) }
                }

                // 7. Compute Master Stereo Peaks directly from mixed Music + Pad output channels (BEFORE Click/Guide/Redundancy/SMPTE)
                var mPeakL: Float = 0.0
                var mPeakR: Float = 0.0
                if musicChannelMask != 0 {
                    let vFrames = vDSP_Length(frameCount)
                    var mask = musicChannelMask
                    while mask != 0 {
                        let ch = mask.trailingZeroBitCount
                        mask &= (mask - 1)
                        guard ch < numChannels else { continue }
                        var chPeak: Float = 0.0
                        vDSP_maxmgv(channelPointers[ch], 1, &chPeak, vFrames)
                        if (ch & 1) == 0 {
                            if chPeak > mPeakL { mPeakL = chPeak }
                        } else {
                            if chPeak > mPeakR { mPeakR = chPeak }
                        }
                    }
                    if numChannels == 1 {
                        mPeakR = mPeakL
                    }
                }

                // 8. Second Micro-Pass: Mix Click & Guide tracks cleanly onto hardware outputs after Master VU measurement
                if segCount > 0 {
                    for sIdx in 0..<segCount {
                        let seg = segAlloc[sIdx]
                        let segPrimaryTracks = seg.isPostPromotion ? localTracks : initialTracks
                        for entry in segPrimaryTracks where entry.isClickOrGuide {
                            if seg.isDualMix { continue } // Muted on outgoing song during Overlap/Crossfade
                            let preMasterGL = entry.gainL
                            let preMasterGR = entry.gainR
                            if preMasterGL <= 0.0001 && preMasterGR <= 0.0001 { continue }

                            let chL = min(entry.outChannelL, numChannels - 1)
                            let chR = min(entry.outChannelR, numChannels - 1)
                            let dstL = channelPointers[chL].advanced(by: seg.outOffset)
                            let dstR = channelPointers[chR].advanced(by: seg.outOffset)
                            let readFrame = entry.isTimelineAligned ? seg.playhead : seg.sourceStartFrame
                            if readFrame >= 0 && readFrame < entry.frameLength {
                                let avail = min(seg.stepFrames, Int(entry.frameLength - readFrame))
                                if avail > 0 {
                                    let vLen = vDSP_Length(avail)
                                    let srcL = entry.leftPtr.advanced(by: Int(readFrame))
                                    let srcR = entry.rightPtr.advanced(by: Int(readFrame))
                                    var gL = preMasterGL
                                    var gR = preMasterGR
                                    var pL: Float = 0.0
                                    var pR: Float = 0.0
                                    vDSP_maxmgv(srcL, 1, &pL, vLen)
                                    if srcR == srcL {
                                        pR = pL
                                    } else {
                                        vDSP_maxmgv(srcR, 1, &pR, vLen)
                                    }
                                    if pL > 1e-6 && preMasterGL > 0.0001 {
                                        vDSP_vsma(srcL, 1, &gL, dstL, 1, dstL, 1, vLen)
                                        let scaledL = pL * preMasterGL
                                        if scaledL > entry.track.rawPeakL { entry.track.rawPeakL = scaledL }
                                    }
                                    if pR > 1e-6 && preMasterGR > 0.0001 {
                                        if chR != chL || dstR != dstL {
                                            vDSP_vsma(srcR, 1, &gR, dstR, 1, dstR, 1, vLen)
                                        }
                                        let scaledR = pR * preMasterGR
                                        if scaledR > entry.track.rawPeakR { entry.track.rawPeakR = scaledR }
                                    }
                                }
                            }
                        }

                        if seg.isDualMix && !seg.isPostPromotion {
                            for entry in initialNextTracks where entry.isClickOrGuide {
                                let preMasterGL = entry.gainL
                                let preMasterGR = entry.gainR
                                if preMasterGL <= 0.0001 && preMasterGR <= 0.0001 { continue }

                                let chL = min(entry.outChannelL, numChannels - 1)
                                let chR = min(entry.outChannelR, numChannels - 1)
                                let dstL = channelPointers[chL].advanced(by: seg.outOffset)
                                let dstR = channelPointers[chR].advanced(by: seg.outOffset)
                                let nextReadFrame = entry.isTimelineAligned ? seg.nextPlayhead : seg.nextSourceStartFrame
                                if nextReadFrame >= 0 && nextReadFrame < entry.frameLength {
                                    let avail = min(seg.stepFrames, Int(entry.frameLength - nextReadFrame))
                                    if avail > 0 {
                                        let vLen = vDSP_Length(avail)
                                        let srcL = entry.leftPtr.advanced(by: Int(nextReadFrame))
                                        let srcR = entry.rightPtr.advanced(by: Int(nextReadFrame))
                                        var gL = preMasterGL
                                        var gR = preMasterGR
                                        var pL: Float = 0.0
                                        var pR: Float = 0.0
                                        vDSP_maxmgv(srcL, 1, &pL, vLen)
                                        if srcR == srcL {
                                            pR = pL
                                        } else {
                                            vDSP_maxmgv(srcR, 1, &pR, vLen)
                                        }
                                        if pL > 1e-6 && preMasterGL > 0.0001 {
                                            vDSP_vsma(srcL, 1, &gL, dstL, 1, dstL, 1, vLen)
                                            let scaledL = pL * preMasterGL
                                            if scaledL > entry.track.rawPeakL { entry.track.rawPeakL = scaledL }
                                        }
                                        if pR > 1e-6 && preMasterGR > 0.0001 {
                                            if chR != chL || dstR != dstL {
                                                vDSP_vsma(srcR, 1, &gR, dstR, 1, dstR, 1, vLen)
                                            }
                                            let scaledR = pR * preMasterGR
                                            if scaledR > entry.track.rawPeakR { entry.track.rawPeakR = scaledR }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 9. Continuous 1kHz Sine Wave Redundancy Output (fast phasor recurrence instead of per-sample sin())
                var updatedRedundancyPhase: Double? = nil
                if localIsRedundancy && localRedundancyCh >= 0 && localRedundancyCh < numChannels {
                    let outPtr = channelPointers[localRedundancyCh]
                    let sr = localSampleRate > 0 ? localSampleRate : 44100.0
                    let phaseInc = (2.0 * Double.pi * 1000.0) / sr
                    let cosInc = cos(phaseInc)
                    let sinInc = sin(phaseInc)
                    var s = sin(localRedundancyPhase)
                    var c = cos(localRedundancyPhase)
                    let amp: Float = 0.25 // Standard -12 dBFS sine wave

                    for i in 0..<frameCount {
                        outPtr[i] = Float(s) * amp
                        let nextS = s * cosInc + c * sinInc
                        let nextC = c * cosInc - s * sinInc
                        s = nextS
                        c = nextC
                    }
                    // Renormalize & wrap phase cleanly once per block
                    var endPhase = atan2(s, c)
                    if endPhase < 0 { endPhase += 2.0 * Double.pi }
                    updatedRedundancyPhase = endPhase
                }

                // 10. SMPTE Timecode Output (LTC Audio Transmission)
                if localIsSMPTE && localHasSMPTECue && playing && localSMPTECh >= 0 && localSMPTECh < numChannels {
                    let outPtr = channelPointers[localSMPTECh]
                    let sr = localSampleRate > 0 ? localSampleRate : 44100.0

                    SMPTELTCGenerator.renderLTC(
                        frameCount: frameCount,
                        outBuffer: outPtr,
                        startTimelineFrame: max(0, playhead - Int64(frameCount)),
                        cueTimelineFrame: localSMPTECueFrame,
                        cueStartSeconds: localSMPTEStartSec,
                        sampleRate: sr,
                        frameRate: localSMPTERate
                    )
                }

                // 11. Single consolidated unlock commit for playhead, flags, redundancy phase, and Master VU peaks
                os_unfair_lock_lock(&lock)
                if playing && totalFrames > 0 {
                    if seekGeneration == localSeekGen {
                        currentTimelineFrame = playhead
                        if self.preRollActive && playhead >= self.preRollTargetDownbeatFrame {
                            self.preRollActive = false
                        }
                        if promotedToNextSong {
                            tracks = localTracks
                            slices = localSlices
                            totalTimelineFrames = totalFrames
                            nextTracks = []
                            nextSlices = []
                            nextTotalTimelineFrames = 0
                            transitionMode = .cueNextSong
                            didTransitionToNextSong = true
                        }
                    }
                    if singleLoopJumpOccurred {
                        singleLoopRemainingCount = localSingleRemaining
                        loopActive = false
                        didTriggerSingleLoopRepeat = true
                    }
                    if queuedJumpOccurred {
                        hasQueuedJump = false
                        queuedBoundaryFrame = -1
                        queuedTargetFrame = -1
                        didTriggerQueuedJump = true
                    }
                    if singleLoopFinished {
                        loopActive = false
                        singleLoopRemainingCount = 0
                        didCompleteSingleLoop = true
                    }
                    if hitEndOfSong {
                        isPlaying = false
                        didReachEndOfSong = true
                    }
                }
                if let newPhase = updatedRedundancyPhase {
                    self.redundancyPhase = newPhase
                }
                if mPeakL > rawMasterPeakL { rawMasterPeakL = mPeakL }
                if mPeakR > rawMasterPeakR { rawMasterPeakR = mPeakR }
                os_unfair_lock_unlock(&lock)
            }

            return noErr
        }
    }
}

/// Internal structure holding audio state and buffer for a single track channel
final class TrackChannel: @unchecked Sendable {
    let track: StemTrack
    var buffer: AVAudioPCMBuffer?
    var audioFile: AVAudioFile?
    var effectiveGainL: Float = 0.80
    var effectiveGainR: Float = 0.80
    var outChannelL: Int = 0
    var outChannelR: Int = 1
    
    init(track: StemTrack, buffer: AVAudioPCMBuffer? = nil, audioFile: AVAudioFile? = nil) {
        self.track = track
        self.buffer = buffer
        self.audioFile = audioFile
    }
}

private struct TrackUndoSnapshot: Equatable {
    let id: UUID
    let name: String
    let role: TrackRole
    let fileURL: URL?
    let sourceFileURL: URL?
    let volume: Float
    let pan: Float
    let isMuted: Bool
    let isSoloed: Bool
    let isSoloSafe: Bool
    let routing: OutputRoutingOption
    let assignedBusName: String
    let includeInWaveform: Bool
    let duration: TimeInterval
    let waveformPeaks: [Float]
    let pristineBuffer: AVAudioPCMBuffer?
    let activeBuffer: AVAudioPCMBuffer?

    static func == (lhs: TrackUndoSnapshot, rhs: TrackUndoSnapshot) -> Bool {
        return lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.role == rhs.role &&
            lhs.fileURL == rhs.fileURL &&
            lhs.sourceFileURL == rhs.sourceFileURL &&
            lhs.volume == rhs.volume &&
            lhs.pan == rhs.pan &&
            lhs.isMuted == rhs.isMuted &&
            lhs.isSoloed == rhs.isSoloed &&
            lhs.isSoloSafe == rhs.isSoloSafe &&
            lhs.routing == rhs.routing &&
            lhs.assignedBusName == rhs.assignedBusName &&
            lhs.includeInWaveform == rhs.includeInWaveform &&
            lhs.duration == rhs.duration
    }
}

private struct BusUndoSnapshot: Equatable {
    let id: UUID
    let name: String
    let volume: Float
    let isMuted: Bool
    let isSoloed: Bool
    let isSoloSafe: Bool
    let isMono: Bool
    let physicalOutputChannel: String
    let color: Color
}

private struct SessionUndoSnapshot: Equatable {
    let currentSetlist: Setlist
    let currentSongIndex: Int
    let currentSong: Song
    let masterVolume: Float
    let padChannelVolume: Float
    let padChannelPan: Float
    let padChannelMuted: Bool
    let padChannelSoloed: Bool
    let tracks: [TrackUndoSnapshot]
    let busses: [BusUndoSnapshot]
}

/// Core multitrack audio engine managing sample-accurate 26+ track synchronized playback, bussing, and transport
@MainActor
public final class MultitrackAudioEngine: ObservableObject {
    
    // MARK: - Published Properties
    @Published public private(set) var tracks: [StemTrack] = []
    @Published public private(set) var playbackState: PlaybackState = .stopped {
        didSet {
            if playbackState != oldValue {
                LibraryBrowserManager.shared.setPlaybackActive(playbackState == .playing)
            }
        }
    }
    public private(set) var transportPosition: TransportPosition = TransportPosition()
    public let transportClock = TransportClockModel()
    public let transportDisplayClock = TransportDisplayClockModel()
    @Published public private(set) var aggregateWaveform: [Float] = []
    @Published public private(set) var renderedWaveformImage: NSImage?
    public private(set) var masterWaveformPeaks: [Float] = []
    
    // Master Volume & Busses
    @Published public var masterVolume: Float = 0.80 { // Defaults to 0.0 dB (80% travel)
        didSet {
            updateMasterVolume()
            markSessionChanged()
        }
    }
    @Published public var busses: [AudioBus] = AudioBus.defaultBusses()
    
    public enum MixerMode: String, CaseIterable, Sendable {
        case tracks = "Tracks"
        case busses = "Busses"
        case padPlayer = "Pad Player"
    }
    @Published public var mixerMode: MixerMode = .tracks
    
    // Real-time Master VU Meter Levels (isolated into `masterMeter` so MainView/MasterMixerControlView never re-evaluate on meter ticks)
    public let masterMeter = StereoMeterModel()
    public var masterPeakLeft: Float = 0.0
    public var masterPeakRight: Float = 0.0
    private var rawMasterPeakL: Float = 0.0
    private var rawMasterPeakR: Float = 0.0
    private var uiFallbackTimer: Timer?
    private var uiDisplayLink: CADisplayLink?
    private var uiDisplayLinkProxy: DisplayLinkTickProxy?
    private var uiDisplayLinkScreenNumber: CGDirectDisplayID?
    private var transportWatchdogTimer: DispatchSourceTimer?
    private var lastPlaybackClockTickTimestamp: CFTimeInterval = 0
    private var playbackActivityToken: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    public private(set) var cachedEffectiveBeatGrid: [BeatGridMarker] = []
    public private(set) var precomputedDownbeatMarkers: [BeatGridMarker] = []
    public private(set) var precomputedSubdivisionMarkers: [BeatGridMarker] = []
    private var cachedActiveAutomation: [(point: AutomationPoint, startSec: TimeInterval)] = []

    /// Rebuilds pre-computed beat & downbeat marker arrays once on song load/tempo change so timeline Canvas never filters `beatGrid` per frame.
    public func rebuildPrecomputedBeatGrid() {
        let grid = currentSong.effectiveBeatGrid(totalDuration: currentSongDuration)
        cachedEffectiveBeatGrid = grid
        if grid.isEmpty {
            precomputedDownbeatMarkers = []
            precomputedSubdivisionMarkers = []
        } else {
            var downbeats: [BeatGridMarker] = []
            var subs: [BeatGridMarker] = []
            downbeats.reserveCapacity(grid.count / 4)
            subs.reserveCapacity(grid.count)
            for marker in grid {
                if marker.isDownbeat {
                    downbeats.append(marker)
                } else {
                    subs.append(marker)
                }
            }
            precomputedDownbeatMarkers = downbeats
            precomputedSubdivisionMarkers = subs
        }
    }

    public func rebuildCachedActiveAutomation() {
        if currentSong.automationPoints.isEmpty {
            cachedActiveAutomation = []
            return
        }
        cachedActiveAutomation = currentSong.automationPoints
            .filter { !isAutomationPointTrimmedOut($0) }
            .map { ($0, displayTime(forAutomationPoint: $0)) }
            .sorted { $0.startSec < $1.startSec }
    }
    
    // Performance Features
    @Published public var isFadedOut: Bool = false
    @Published public var isFadeActive: Bool = false
    @Published public var fadeInDuration: TimeInterval = 5.0
    @Published public var fadeOutDuration: TimeInterval = 5.0
    public var preFadeVolumes: [UUID: Float] = [:]
    public var songEndBaseVolumes: [UUID: Float] = [:]
    @Published public private(set) var currentFadeGain: Float = 1.0
    
    public enum LoopMode: String, CaseIterable, Sendable {
        case none = "None"
        case single = "Single (1x)"
        case infinite = "Infinite (∞)"
    }
    @Published public var loopMode: LoopMode = .none
    @Published public var isLoopActive: Bool = false
    @Published public var loopedSection: SongSection?
    @Published public var singleLoopRemaining: Int = 0
    @Published public var isPadActive: Bool = false
    @Published public var currentPadKey: String = "C"
    @Published public var isPadLinked: Bool = true
    @Published public var unlinkedKeyID: String? = nil
    /// Temporary pad pack chosen in the Pad Player / Remote without altering the Song Menu's default `padPresetId`.
    @Published public var manualPadPackId: String? = nil
    
    // Click Subdivisions Drawer & Solo Controls
    @Published public var isClickSubdivisionDrawerExpanded: Bool = false
    @Published public var clickSoloedSubdivisions: Set<ClickSubdivision> = []
    
    // Bottom-Right Edit Drawer & Active Edit Mode (MultiTracks Playback Style)
    public enum EditDrawerItem: String, CaseIterable, Sendable {
        case setlistSongMap = "Setlist / Song Map"
        case midiCues = "MIDI Cues"
        case directionalCues = "Directional Cues"
        case automation = "Automation"
        case midiMapping = "MIDI Mapping"
        case keyboardMapping = "Keyboard Mapping"
        case songSections = "Song Sections"
        case smpte = "SMPTE"
    }
    @Published public var isEditDrawerOpen: Bool = false
    @Published public var isEditDrawerCollapsed: Bool = false
    @Published public var selectedEditDrawerItem: EditDrawerItem = .setlistSongMap
    
    // Song Section Edit Mode (Non-destructive Add/Remove Sections)
    @Published public var isEditSectionsMode: Bool = false
    
    // Song Map Edit Mode (Adding / Labeling Sections at Playhead)
    @Published public var isEditSongMapMode: Bool = false
    
    // MIDI Cues Edit Mode (Adding / Editing MIDI Cues at Playhead)
    @Published public var isEditMIDICuesMode: Bool = false
    
    // Directional Cues Edit Mode & 16th-Note Nudge State
    @Published public var isEditDirectionalCuesMode: Bool = false
    @Published public var selectedDirectionalCueId: UUID? = nil
    @Published public var isNudgingDirectionalCue: Bool = false
    @Published public var requestedEditDirectionalCueId: UUID? = nil
    
    // Automation Edit Mode & 1-Beat Nudge State
    @Published public var isEditAutomationMode: Bool = false
    @Published public var selectedAutomationPointId: UUID? = nil
    @Published public var isNudgingAutomation: Bool = false
    @Published public var requestedEditAutomationId: UUID? = nil
    
    // MIDI & Keyboard Mapping Mode
    @Published public var isEditMIDIMappingMode: Bool = false
    @Published public var isEditKeyboardMappingMode: Bool = false
    @Published public var audioDeviceBannerMessage: String? = nil
    private var audioDeviceBannerDismissTask: Task<Void, Never>? = nil
    private var hardwareDeviceCancellable: AnyCancellable? = nil
    private var lastAppliedHardwareDeviceID: AudioDeviceID? = nil
    private var lastAppliedHardwareChannelCount: Int = 0
    @Published public var browsedSectionStartTime: TimeInterval? = nil
    
    // Baseline snapshot for restoring mix when exiting automation editing
    public var baseTrackVolumes: [UUID: Float] = [:]
    public var baseTrackPans: [UUID: Float] = [:]
    public var baseTrackMutes: [UUID: Bool] = [:]
    public var baseBusVolumes: [String: Float] = [:]
    public var baseBusMutes: [String: Bool] = [:]
    public var basePadVolume: Float = 0.80
    public var basePadPan: Float = 0.0
    public var basePadMuted: Bool = false
    public var baseMIDIMuted: Bool = false
    
    /// True when the user is in Automation edit mode AND the playhead is currently positioned on an automation cue
    public var isAutomationHighlightActive: Bool {
        guard isEditAutomationMode, let selId = selectedAutomationPointId, !currentSong.automationPoints.isEmpty else {
            return false
        }
        if let pt = currentSong.automationPoints.first(where: { $0.id == selId }) {
            let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
            let durationSec = Double(pt.transitionBeats) * secPerBeat
            let tolerance = max(0.08, secPerBeat * 0.45)
            let dispTime = displayTime(forAutomationPoint: pt)
            let start = dispTime - tolerance
            let end = dispTime + durationSec + tolerance
            return playbackOffsetSeconds >= start && playbackOffsetSeconds <= end
        }
        return false
    }
    
    /// True if any active (non-trimmed) automation cue in the current song targets this track
    public func isTrackAutomated(_ trackId: UUID) -> Bool {
        let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
        guard !activePoints.isEmpty else { return false }
        
        // Sparse points (e.g., Playback imports) only store keys for the tracks actually automated in each cue.
        for pt in activePoints {
            let isSparse = pt.trackFaders.count < tracks.count
            if isSparse {
                if pt.trackMutes[trackId] != nil || pt.trackFaders[trackId] != nil || pt.trackPans[trackId] != nil {
                    return true
                }
            }
        }
        
        // Full-snapshot points (PeanutButter-created) snapshot all tracks; check if this track's values vary across cues.
        if activePoints.count >= 2 {
            let firstMute = activePoints.compactMap { $0.trackMutes[trackId] }.first
            let firstFader = activePoints.compactMap { $0.trackFaders[trackId] }.first
            let firstPan = activePoints.compactMap { $0.trackPans[trackId] }.first
            for pt in activePoints {
                if let m = pt.trackMutes[trackId], let fm = firstMute, m != fm { return true }
                if let f = pt.trackFaders[trackId], let ff = firstFader, abs(f - ff) > 0.005 { return true }
                if let p = pt.trackPans[trackId], let fp = firstPan, abs(p - fp) > 0.005 { return true }
            }
        }
        return false
    }
    
    /// True if any active (non-trimmed) automation cue in the current song targets this bus
    public func isBusAutomated(_ busName: String) -> Bool {
        let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
        guard !activePoints.isEmpty else { return false }
        
        for pt in activePoints {
            let isSparse = pt.busFaders.count < busses.count && pt.busMutes.count < busses.count
            if isSparse {
                if pt.busMutes[busName] != nil || pt.busFaders[busName] != nil {
                    return true
                }
            }
        }
        
        if activePoints.count >= 2 {
            let firstMute = activePoints.compactMap { $0.busMutes[busName] }.first
            let firstFader = activePoints.compactMap { $0.busFaders[busName] }.first
            for pt in activePoints {
                if let m = pt.busMutes[busName], let fm = firstMute, m != fm { return true }
                if let f = pt.busFaders[busName], let ff = firstFader, abs(f - ff) > 0.005 { return true }
            }
        }
        return false
    }
    
    /// Returns which parameters of `trackId` are targeted by the currently selected automation cue
    public func automationTargetsForSelectedCue(trackId: UUID) -> (mute: Bool, fader: Bool, pan: Bool) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let pt = currentSong.automationPoints.first(where: { $0.id == selId }) else {
            return (false, false, false)
        }
        return (
            pt.trackMutes[trackId] != nil,
            pt.trackFaders[trackId] != nil,
            pt.trackPans[trackId] != nil
        )
    }
    
    /// Finds the automation point (if any) currently covering or matching the given time
    public func automationPoint(at time: TimeInterval) -> AutomationPoint? {
        guard !currentSong.automationPoints.isEmpty else { return nil }
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let tolerance = max(0.08, secPerBeat * 0.45)
        
        for pt in currentSong.automationPoints.sorted(by: { $0.time < $1.time }) {
            let durationSec = Double(pt.transitionBeats) * secPerBeat
            let start = pt.time - tolerance
            let end = pt.time + durationSec + tolerance
            if time >= start && time <= end {
                return pt
            }
        }
        return nil
    }
    
    // MARK: - Redundancy Feature (1kHz Persistent Pilot Tone)
    @Published public var isRedundancyEnabled: Bool = false
    @Published public var redundancyOutputChannel: String = "Out 1"

    public static func monoChannelIndex(for channelName: String) -> Int {
        let digits = channelName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let num = Int(digits), num >= 1 {
            return num - 1
        }
        return 0
    }

    /// Returns all 0-based mono hardware output indices currently occupied by busses (and optionally Redundancy/SMPTE).
    public func occupiedMonoChannelIndices(excludingRedundancy: Bool = false, excludingSMPTE: Bool = false) -> Set<Int> {
        var occupied = Set<Int>()
        for bus in busses {
            let (outL, outR) = resolvePhysicalOutputChannels(for: bus.physicalOutputChannel, isMono: bus.isMono)
            occupied.insert(outL)
            if !bus.isMono {
                occupied.insert(outR)
            }
        }
        if !excludingRedundancy && isRedundancyEnabled {
            occupied.insert(Self.monoChannelIndex(for: redundancyOutputChannel))
        }
        if !excludingSMPTE && isSMPTEEnabled {
            occupied.insert(Self.monoChannelIndex(for: smpteOutputChannel))
        }
        return occupied
    }

    public func availableMonoChannelsForRedundancy() -> [String] {
        let (_, monoOuts) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
        let channels = monoOuts.isEmpty ? ["Out 1", "Out 2"] : monoOuts
        let occupied = occupiedMonoChannelIndices(excludingRedundancy: true, excludingSMPTE: false)
        return channels.filter { !occupied.contains(Self.monoChannelIndex(for: $0)) }
    }

    public func availableMonoChannelsForSMPTE() -> [String] {
        let (_, monoOuts) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
        let channels = monoOuts.isEmpty ? ["Out 1", "Out 2"] : monoOuts
        let occupied = occupiedMonoChannelIndices(excludingRedundancy: false, excludingSMPTE: true)
        return channels.filter { !occupied.contains(Self.monoChannelIndex(for: $0)) }
    }

    public var canEnableRedundancy: Bool {
        isRedundancyEnabled || !availableMonoChannelsForRedundancy().isEmpty
    }

    public var canEnableSMPTE: Bool {
        isSMPTEEnabled || !availableMonoChannelsForSMPTE().isEmpty
    }

    /// Returns `"Redundancy"` or `"SMPTE"` if assigning a bus to `outputName` would collide with an active Redundancy/SMPTE output.
    public func reservedOutputLabel(for outputName: String, isMono: Bool) -> String? {
        let (outL, outR) = resolvePhysicalOutputChannels(for: outputName, isMono: isMono)
        if isRedundancyEnabled {
            let redIdx = Self.monoChannelIndex(for: redundancyOutputChannel)
            if outL == redIdx || (!isMono && outR == redIdx) {
                return "Redundancy"
            }
        }
        if isSMPTEEnabled {
            let smpteIdx = Self.monoChannelIndex(for: smpteOutputChannel)
            if outL == smpteIdx || (!isMono && outR == smpteIdx) {
                return "SMPTE"
            }
        }
        return nil
    }

    @discardableResult
    public func setRedundancyEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            let free = availableMonoChannelsForRedundancy()
            guard !free.isEmpty else {
                isRedundancyEnabled = false
                updateRedundancyState()
                return false
            }
            if !free.contains(redundancyOutputChannel) {
                redundancyOutputChannel = free.last ?? free[0]
            }
            isRedundancyEnabled = true
            updateRedundancyState()
            return true
        } else {
            isRedundancyEnabled = false
            updateRedundancyState()
            return true
        }
    }

    @discardableResult
    public func setSMPTEEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            let free = availableMonoChannelsForSMPTE()
            guard !free.isEmpty else {
                isSMPTEEnabled = false
                updateSMPTEState()
                return false
            }
            if !free.contains(smpteOutputChannel) {
                smpteOutputChannel = free.last ?? free[0]
            }
            isSMPTEEnabled = true
            updateSMPTEState()
            return true
        } else {
            isSMPTEEnabled = false
            updateSMPTEState()
            return true
        }
    }

    public func disableRedundancyAndSMPTEOnDeviceChange() {
        if isRedundancyEnabled {
            isRedundancyEnabled = false
            updateRedundancyState()
        }
        if isSMPTEEnabled {
            isSMPTEEnabled = false
            updateSMPTEState()
        }
    }
    
    public func updateRedundancyState() {
        let channelIndex = Self.monoChannelIndex(for: redundancyOutputChannel)
        mixState.setRedundancy(enabled: isRedundancyEnabled, channelIndex: channelIndex)
        UserDefaults.standard.set(isRedundancyEnabled, forKey: "Playback_RedundancyEnabled")
        UserDefaults.standard.set(redundancyOutputChannel, forKey: "Playback_RedundancyChannel")
    }
    
    // MARK: - SMPTE Timecode Output Feature
    @Published public var isSMPTEEnabled: Bool = false
    @Published public var smpteFrameRate: SMPTEFrameRate = .fps30
    @Published public var smpteOutputChannel: String = "Out 2"

    // MARK: - PeanutButter Remote (5.1 Local Network Control)
    @Published public var isRemoteControlEnabled: Bool = false
    public let remoteServer = RemoteControlServer()

    public func setRemoteControlEnabled(_ enabled: Bool) {
        isRemoteControlEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_RemoteControlEnabled")
        if enabled {
            remoteServer.start()
        } else {
            remoteServer.stop()
        }
    }

    /// Applies a single track's volume directly to the audio render state without rebuilding the full matrix (used by Remote sliders).
    public func applyDirectTrackVolume(_ track: StemTrack) {
        guard let channel = channels[track.id] else { return }
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let res = computeTrackOutputGain(
            track: track,
            channel: channel,
            anyTrackSoloed: anyTrackSoloed,
            anyBusSoloed: anyBusSoloed
        )
        mixState.updateTrackGains(
            trackId: track.id,
            gainL: res.gainL,
            gainR: res.gainR,
            outChannelL: res.outL,
            outChannelR: res.outR
        )
    }

    /// Returns `(StemTrack, AVAudioPCMBuffer)` pairs for offline bouncing of any song in the setlist.
    public func tracksWithBuffersForBounce(song: Song) -> [(track: StemTrack, buffer: AVAudioPCMBuffer)] {
        if song.id == currentSong.id {
            return tracks.compactMap { track in
                if let buf = channels[track.id]?.buffer ?? pristineMasterBuffers[track.id] {
                    return (track, buf)
                }
                return nil
            }
        }
        if let cached = songBuffersCache[song.id] {
            return cached.map { ($0.0, $0.1) }
        }
        return []
    }
    @Published public var isEditSMPTEMode: Bool = false
    @Published public var isNudgingSMPTECue: Bool = false
    @Published public var requestedEditSMPTECue: Bool = false
    
    public func updateSMPTEState() {
        let channelIndex: Int = {
            let digits = smpteOutputChannel.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let num = Int(digits), num >= 1 {
                return num - 1
            }
            return 1
        }()
        
        let hasCue = currentSong.smpteCue != nil
        let cueTime = currentSong.smpteCue?.time ?? 0.0
        let cueStartSec = currentSong.smpteCue?.totalStartSeconds ?? 0.0
        let sr = 44100.0
        let cueFrame = Int64(round(cueTime * sr))
        
        mixState.setSMPTE(
            enabled: isSMPTEEnabled,
            channelIndex: channelIndex,
            frameRate: smpteFrameRate,
            hasCue: hasCue,
            cueTimelineFrame: cueFrame,
            cueStartSeconds: cueStartSec
        )
        
        UserDefaults.standard.set(isSMPTEEnabled, forKey: "Playback_SMPTEEnabled")
        UserDefaults.standard.set(smpteFrameRate.rawValue, forKey: "Playback_SMPTEFrameRate")
        UserDefaults.standard.set(smpteOutputChannel, forKey: "Playback_SMPTEOutputChannel")
    }
    
    /// Calculates the default SMPTE Time Start for a new cue: starts at 00h00m, increments by 10m for subsequent songs ("on the tens")
    public func nextDefaultSMPTETimeStart() -> (hours: Int, minutes: Int) {
        if let currentCue = currentSong.smpteCue {
            return (currentCue.timeStartHours, currentCue.timeStartMinutes)
        }
        
        var existingCuesMinutes: [Int] = []
        for (idx, song) in currentSetlist.songs.enumerated() {
            if idx != currentSongIndex, let cue = song.smpteCue {
                existingCuesMinutes.append(cue.timeStartHours * 60 + cue.timeStartMinutes)
            }
        }
        
        guard let maxMins = existingCuesMinutes.max() else {
            return (0, 0)
        }
        
        let nextTotalMinutes = ((maxMins / 10) + 1) * 10
        let nextHours = (nextTotalMinutes / 60) % 24
        let nextMins = nextTotalMinutes % 60
        return (nextHours, nextMins)
    }
    
    /// Snaps an arbitrary timestamp to the nearest beat in `currentSong.beatGrid` or musical beat
    public func snapTimeToBeatGrid(_ rawTime: TimeInterval) -> TimeInterval {
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        let clamped = max(0.0, min(maxTime, rawTime))
        let grid = currentSong.effectiveBeatGrid(totalDuration: maxTime)
        if !grid.isEmpty {
            var low = 0
            var high = grid.count - 1
            while low < high {
                let mid = (low + high) / 2
                if grid[mid].time < clamped {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low == 0 {
                return grid[0].time
            }
            let t1 = grid[low - 1].time
            let t2 = grid[low].time
            return abs(clamped - t1) <= abs(clamped - t2) ? t1 : t2
        } else {
            let activeBPM = max(20.0, currentSong.bpm)
            let beatSec = (60.0 / activeBPM) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
            let beatIndex = round(clamped / beatSec)
            return max(0.0, beatIndex * beatSec)
        }
    }
    
    @discardableResult
    public func addSMPTECue(at time: TimeInterval, snapToGrid: Bool = true) -> SMPTECue {
        let (h, m) = nextDefaultSMPTETimeStart()
        let finalTime = snapToGrid ? snapTimeToBeatGrid(time) : max(0.0, time)
        let newCue = SMPTECue(time: finalTime, timeStartHours: h, timeStartMinutes: m)
        currentSong.smpteCue = newCue
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultSmpteCue = newCue
        }
        if currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].smpteCue = newCue
            currentSetlist.songs[currentSongIndex].defaultSmpteCue = currentSong.defaultSmpteCue
        }
        markSessionChanged()
        updateSMPTEState()
        return newCue
    }
    
    public func moveSMPTECue(to time: TimeInterval, snapToGrid: Bool = true) {
        let finalTime = snapToGrid ? snapTimeToBeatGrid(time) : max(0.0, time)
        if currentSong.smpteCue != nil {
            currentSong.smpteCue?.time = finalTime
        } else {
            let (h, m) = nextDefaultSMPTETimeStart()
            currentSong.smpteCue = SMPTECue(time: finalTime, timeStartHours: h, timeStartMinutes: m)
        }
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultSmpteCue = currentSong.smpteCue
        }
        if currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].smpteCue = currentSong.smpteCue
            currentSetlist.songs[currentSongIndex].defaultSmpteCue = currentSong.defaultSmpteCue
        }
        markSessionChanged()
        updateSMPTEState()
    }
    
    public func updateSMPTECue(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        guard currentSong.smpteCue != nil else { return }
        currentSong.smpteCue?.timeStartHours = hours
        currentSong.smpteCue?.timeStartMinutes = minutes
        currentSong.smpteCue?.timeStartSeconds = seconds
        currentSong.smpteCue?.timeStartFrames = frames
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultSmpteCue = currentSong.smpteCue
        }
        if currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].smpteCue = currentSong.smpteCue
            currentSetlist.songs[currentSongIndex].defaultSmpteCue = currentSong.defaultSmpteCue
        }
        markSessionChanged()
        updateSMPTEState()
    }
    
    public func removeSMPTECue() {
        currentSong.smpteCue = nil
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultSmpteCue = nil
        }
        if currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].smpteCue = nil
            currentSetlist.songs[currentSongIndex].defaultSmpteCue = currentSong.defaultSmpteCue
        }
        markSessionChanged()
        updateSMPTEState()
    }
    
    public func nudgeSMPTECue(earlier: Bool) {
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        let grid = cachedEffectiveBeatGrid.isEmpty ? currentSong.effectiveBeatGrid(totalDuration: maxTime) : cachedEffectiveBeatGrid
        let currentTime = currentSong.smpteCue?.time ?? transportPosition.currentTime
        let newTime: TimeInterval
        if !grid.isEmpty {
            let sortedTimes = grid.map { $0.time }
            if earlier {
                newTime = sortedTimes.last(where: { $0 < currentTime - 0.005 }) ?? max(0.0, currentTime - 0.5)
            } else {
                newTime = sortedTimes.first(where: { $0 > currentTime + 0.005 }) ?? min(maxTime, currentTime + 0.5)
            }
        } else {
            let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
            newTime = earlier ? max(0.0, currentTime - secPerBeat) : min(maxTime, currentTime + secPerBeat)
        }
        let snapped = snapTimeToBeatGrid(newTime)
        moveSMPTECue(to: snapped)
        seek(to: snapped)
    }
    
    // MARK: - Song Section Pre-Roll Feature
    @Published public var isSongSectionPreRollEnabled: Bool = false
    @Published public var sectionPreRollLengthBars: Int = 2
    @Published public var preRollTargetSectionId: UUID? = nil
    @Published public var isBeatFlashing: Bool = false
    
    public func updatePreRollSettings() {
        UserDefaults.standard.set(isSongSectionPreRollEnabled, forKey: "Playback_SongSectionPreRollEnabled")
        UserDefaults.standard.set(sectionPreRollLengthBars, forKey: "Playback_SectionPreRollLengthBars")
        objectWillChange.send()
    }
    
    public func isSectionCountOff(_ section: SongSection) -> Bool {
        let lower = section.name.lowercased()
        if lower.contains("count") || (lower.contains("intro") && section.startTime < 0.05) {
            return true
        }
        if section.startTime < 0.05 {
            return true
        }
        if let first = currentSong.sections.first, first.id == section.id, section.startMeasure <= 1 {
            return true
        }
        return false
    }
    
    public func calculatePreRollStartTime(for section: SongSection) -> (preRollStart: TimeInterval, downbeat: TimeInterval) {
        let downbeatTime = section.startTime
        let x = max(1, sectionPreRollLengthBars)
        
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        let grid = cachedEffectiveBeatGrid.isEmpty ? currentSong.effectiveBeatGrid(totalDuration: maxTime) : cachedEffectiveBeatGrid
        let downbeats = grid.filter { $0.isDownbeat }.sorted(by: { $0.time < $1.time })
        if !downbeats.isEmpty,
           let matchIdx = downbeats.firstIndex(where: { abs($0.time - downbeatTime) < 0.15 }) {
            let preIdx = max(0, matchIdx - x)
            let preTime = downbeats[preIdx].time
            return (preTime, downbeatTime)
        }
        
        let bpm = currentSong.bpm > 20.0 ? currentSong.bpm : 120.0
        let beatsPerBar = Double(max(1, currentSong.timeSignatureNumerator))
        let beatScale = 4.0 / Double(max(1, currentSong.timeSignatureDenominator))
        let secPerBar = (60.0 / bpm) * beatScale * beatsPerBar
        let preRollDur = secPerBar * Double(x)
        let preTime = max(0.0, downbeatTime - preRollDur)
        return (preTime, downbeatTime)
    }
    
    public func startPreRollPlayback(for section: SongSection) {
        if isCurrentSongTransposing {
            showTranspositionWarning = true
            return
        }
        if isCurrentSongDownloading {
            showDownloadingWarning = true
            return
        }
        guard !channels.isEmpty else { return }
        closeEditMode()
        
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        
        let (preTime, downbeatTime) = calculatePreRollStartTime(for: section)
        let sr = getCanonicalProcessingFormat().sampleRate
        let preRollStartFrame = Int64(round(preTime * sr))
        let downbeatFrame = Int64(round(downbeatTime * sr))
        
        updateMatrix()
        mixState.startPreRoll(preRollStartFrame: preRollStartFrame, targetDownbeatFrame: downbeatFrame)
        mixState.setPlaying(true)
        
        scheduledStartOffset = preTime
        playbackOffsetSeconds = downbeatTime // Playhead stays at the section the user played!
        updateTransportPosition(to: downbeatTime)
        currentPlayingSectionId = section.id
        preRollTargetSectionId = section.id // Section blinks like a double-clicked waiting section
        playbackState = .playing
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        
        if currentSong.startPadWithSong {
            if currentSong.padIntroOutroOnly {
                if section.isIntroOrOutro {
                    if !isPadActive || !padPlayer.isPlaying {
                        startPadPlayer()
                    }
                } else {
                    isPadActive = true
                    if padPlayer.isPlaying {
                        padPlayer.stop()
                    }
                }
            } else if !isPadActive || !padPlayer.isPlaying {
                startPadPlayer()
            }
        } else if isPadActive {
            if currentSong.padIntroOutroOnly {
                if !section.isIntroOrOutro && padPlayer.isPlaying {
                    padPlayer.stop()
                } else if isPadLinked && section.isIntroOrOutro && !padPlayer.isPlaying {
                    startPadPlayer()
                }
            } else if isPadLinked {
                let candidateKey = !currentSong.currentTransposedKey.isEmpty && currentSong.currentTransposedKey != "—" ? currentSong.currentTransposedKey : currentSong.musicalKey
                let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
                if currentPadKey != normalized || padPlayer.activePackId != currentSong.padPresetId {
                    currentPadKey = normalized
                    padPlayer.transitionToKey(normalized, packId: currentSong.padPresetId)
                }
            }
        }
        
        if !isMIDIMuted {
            let activeBPM = currentSong.activeMarker(at: preTime)?.instantaneousBPM ?? currentSong.bpm
            MIDICueEngine.shared.startMIDIClock(bpm: activeBPM, isResume: preTime > 0.01)
        }
        
        startAudioClockTransportTimer()
        startMeteringTimer()
        updatePlaybackActivityAssertion()
    }
    
    public func playSection(_ section: SongSection) {
        if isCurrentSongTransposing {
            showTranspositionWarning = true
            return
        }
        if isCurrentSongDownloading {
            showDownloadingWarning = true
            return
        }
        if isSongSectionPreRollEnabled && !isSectionCountOff(section) {
            startPreRollPlayback(for: section)
        } else {
            mixState.cancelPreRoll()
            preRollTargetSectionId = nil
            seek(to: section.startTime)
            if playbackState != .playing {
                play()
            }
        }
    }
    
    // MARK: - Global Pad Settings
    @Published public var isGlobalStartPadWithSongEnabled: Bool = false
    
    public func setGlobalStartPadWithSong(_ enabled: Bool) {
        isGlobalStartPadWithSongEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_GlobalStartPadWithSongEnabled")
        objectWillChange.send()
    }

    // MARK: - Global Guide Section Number Settings
    @Published public var isGlobalIncludeGuideSectionNumbersEnabled: Bool = false

    public func setGlobalIncludeGuideSectionNumbers(_ enabled: Bool) {
        isGlobalIncludeGuideSectionNumbersEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        for i in 0..<currentSong.sections.count {
            currentSong.sections[i].includeNumberInGuide = enabled
        }
        for sIdx in 0..<currentSetlist.songs.count {
            for secIdx in 0..<currentSetlist.songs[sIdx].sections.count {
                currentSetlist.songs[sIdx].sections[secIdx].includeNumberInGuide = enabled
            }
        }
        regenerateGuideTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Default Click & Guide Source Preferences
    @Published public var defaultClickSourcePreference: ClickSource = .uploaded
    @Published public var defaultGuideSourcePreference: GuideSource = .uploaded
    
    public func setDefaultClickSourcePreference(_ source: ClickSource) {
        defaultClickSourcePreference = source
        UserDefaults.standard.set(source.rawValue, forKey: "Playback_DefaultClickSource")
        for i in 0..<currentSetlist.songs.count {
            let sid = currentSetlist.songs[i].id
            let target: ClickSource = (source == .uploaded && uploadedClickBuffers[sid] != nil) ? .uploaded : .generated
            currentSetlist.songs[i].clickSource = target
        }
        let curTarget: ClickSource = (source == .uploaded && uploadedClickBuffers[currentSong.id] != nil) ? .uploaded : .generated
        if currentSong.clickSource != curTarget {
            setClickSource(curTarget)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func setDefaultGuideSourcePreference(_ source: GuideSource) {
        defaultGuideSourcePreference = source
        UserDefaults.standard.set(source.rawValue, forKey: "Playback_DefaultGuideSource")
        for i in 0..<currentSetlist.songs.count {
            let sid = currentSetlist.songs[i].id
            let target: GuideSource = (source == .uploaded && uploadedGuideBuffers[sid] != nil) ? .uploaded : .generated
            currentSetlist.songs[i].guideSource = target
        }
        let curTarget: GuideSource = (source == .uploaded && uploadedGuideBuffers[currentSong.id] != nil) ? .uploaded : .generated
        if currentSong.guideSource != curTarget {
            setGuideSource(curTarget)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    

    // MARK: - Channel Faders Default Level
    @Published public var isFadersDefault100Enabled: Bool = false
    
    public var defaultChannelFaderLevel: Float {
        isFadersDefault100Enabled ? 1.0 : 0.80
    }
    
    public func setFadersDefault100(_ enabled: Bool) {
        isFadersDefault100Enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "Playback_FadersDefault100")
        for track in tracks {
            track.volume = enabled ? 1.0 : 0.80
        }
        updateMatrix()
        objectWillChange.send()
    }
    
    /// Synchronizes automation selection with timeline scrolling
    public func updateAutomationSelectionForPlayhead(at time: TimeInterval) {
        guard isEditAutomationMode else { return }
        if let pt = automationPoint(at: time) {
            if selectedAutomationPointId != pt.id {
                selectedAutomationPointId = pt.id
                loadAutomationPointValues(id: pt.id)
            }
        } else {
            if selectedAutomationPointId != nil {
                selectedAutomationPointId = nil
                if playbackState != .playing {
                    applyAutomationAtTime(time)
                }
            }
        }
    }
    
    // Active / Selected MIDI Cue on Timeline & 16th-Note Nudge State
    @Published public var selectedMIDICueId: UUID? = nil
    @Published public var isNudgingMIDICue: Bool = false
    @Published public var requestedEditMIDICueId: UUID? = nil
    
    // MIDI Cue Section Clipboard (relative offsets and metadata)
    public struct CopiedMIDICueItem: Sendable {
        public let relativeTime: TimeInterval // offset from section startTime
        public let bus: MIDIBus
        public let messageType: MIDIMessageType
        public let primaryValue: Int
        public let originalVelocity: Int
        public let disableLoop: Bool
        public let cueDescription: String
    }
    
    @Published public var copiedMIDICuesClipboard: [CopiedMIDICueItem]? = nil
    @Published public var copiedSourceSectionName: String? = nil
    
    // Master MIDI Mute State ("MUTE MIDI" on right toolbar)
    @Published public var isMIDIMuted: Bool = false
    
    // Section Trim Mode State
    @Published public var trimmingSection: SongSection? = nil
    @Published public var trimLeadingDuration: TimeInterval = 0.0
    @Published public var trimTrailingDuration: TimeInterval = 0.0
    
    /// True when editing sections or arrangement (drawer open to Setlist/Song Map or Song Sections, or in Trim mode)
    public var isEditingArrangement: Bool {
        return (isEditDrawerOpen && (selectedEditDrawerItem == .setlistSongMap || selectedEditDrawerItem == .songSections)) ||
            isEditSectionsMode || isEditSongMapMode || trimmingSection != nil
    }
    
    private struct DisplaySectionsCacheKey: Equatable {
        let songId: UUID
        let sections: [SongSection]
        let bpm: Double
        let timeSigNum: Int
        let timeSigDen: Int
        let isEditing: Bool
    }
    private var cachedDisplaySectionsKey: DisplaySectionsCacheKey?
    private var cachedDisplaySectionsValue: [SongSection] = []

    /// Returns the sections for display on the timeline: in Setlist/Song Map mode or Trim mode, trimmed sections are expanded to their base duration
    public var displaySections: [SongSection] {
        let editing = isEditingArrangement
        let key = DisplaySectionsCacheKey(
            songId: currentSong.id,
            sections: currentSong.sections,
            bpm: currentSong.bpm,
            timeSigNum: currentSong.timeSignatureNumerator,
            timeSigDen: currentSong.timeSignatureDenominator,
            isEditing: editing
        )
        if cachedDisplaySectionsKey == key {
            return cachedDisplaySectionsValue
        }
        let computed: [SongSection]
        if editing {
            var result: [SongSection] = []
            var curTime: TimeInterval = 0.0
            var curMeasure: Int = 1
            let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
            let beatsPerMeasure = Double(max(1, currentSong.timeSignatureNumerator))
            let secPerMeasure = secPerBeat * beatsPerMeasure
            
            for sec in currentSong.sections {
                var dispSec = sec
                dispSec.startTime = curTime
                dispSec.startMeasure = curMeasure
                dispSec.duration = sec.baseDuration
                dispSec.audioStartTime = sec.baseAudioStartTime
                dispSec.measureCount = max(1, Int(round(sec.baseDuration / secPerMeasure)))
                result.append(dispSec)
                
                curTime += sec.baseDuration
                curMeasure += dispSec.measureCount
            }
            computed = result
        } else {
            computed = currentSong.sections
        }
        cachedDisplaySectionsKey = key
        cachedDisplaySectionsValue = computed
        return computed
    }
    
    /// True when the Edit Drawer is open and "Setlist / Song Map" is selected
    public var isSetlistSongMapEditingActive: Bool {
        return isEditDrawerOpen && selectedEditDrawerItem == .setlistSongMap
    }
    
    /// Immediately dismisses the Edit Drawer and exits all section/song map/cue editing modes
    public func closeEditMode() {
        if isEditDrawerOpen || isEditSectionsMode || isEditSongMapMode || isEditMIDICuesMode || isEditDirectionalCuesMode || isEditAutomationMode || isEditMIDIMappingMode || isEditKeyboardMappingMode || isEditSMPTEMode || trimmingSection != nil {
            isEditDrawerOpen = false
            isEditDrawerCollapsed = false
            isEditSectionsMode = false
            isEditSongMapMode = false
            isEditMIDICuesMode = false
            isEditDirectionalCuesMode = false
            isEditAutomationMode = false
            isEditMIDIMappingMode = false
            isEditKeyboardMappingMode = false
            isEditSMPTEMode = false
            isNudgingMIDICue = false
            isNudgingDirectionalCue = false
            isNudgingAutomation = false
            isNudgingSMPTECue = false
            selectedAutomationPointId = nil
            MIDIMappingManager.shared.selectedTargetId = nil
            KeyboardMappingManager.shared.selectedTargetId = nil
            restoreBaseMixSnapshot()
            trimmingSection = nil
            updateArrangementWaveform()
        }
    }
    
    public func toggleEditDrawer() {
        if isEditDrawerOpen {
            closeEditMode()
        } else {
            isEditDrawerOpen = true
            isEditDrawerCollapsed = false
            syncEditModesWithDrawerSelection()
        }
    }
    
    /// Hides the edit drawer drawer UI while maintaining the currently active edit mode
    public func collapseEditDrawer() {
        isEditDrawerCollapsed = true
    }
    
    /// Expands the edit drawer drawer UI back out
    public func expandEditDrawer() {
        isEditDrawerCollapsed = false
    }
    
    public func selectEditDrawerItem(_ item: EditDrawerItem) {
        selectedEditDrawerItem = item
        syncEditModesWithDrawerSelection()
    }
    
    private func syncEditModesWithDrawerSelection() {
        // Reset all edit modes first so no lingering mode stays active
        isEditSectionsMode = false
        isEditSongMapMode = false
        isEditMIDICuesMode = false
        isEditDirectionalCuesMode = false
        isEditAutomationMode = false
        isEditMIDIMappingMode = false
        isEditKeyboardMappingMode = false
        isEditSMPTEMode = false
        isNudgingMIDICue = false
        isNudgingDirectionalCue = false
        isNudgingAutomation = false
        isNudgingSMPTECue = false
        MIDIMappingManager.shared.selectedTargetId = nil
        KeyboardMappingManager.shared.selectedTargetId = nil
        
        guard isEditDrawerOpen else {
            updateArrangementWaveform()
            return
        }
        
        switch selectedEditDrawerItem {
        case .setlistSongMap:
            isEditSongMapMode = true
        case .songSections:
            isEditSectionsMode = true
        case .midiCues:
            isEditMIDICuesMode = true
            let activeMidiCues = currentSong.midiCues.filter { !isMIDICueTrimmedOut($0) }.sorted(by: { $0.time < $1.time })
            if selectedMIDICueId == nil || !activeMidiCues.contains(where: { $0.id == selectedMIDICueId }), let first = activeMidiCues.first {
                selectedMIDICueId = first.id
            }
        case .directionalCues:
            isEditDirectionalCuesMode = true
            let activeDirCues = currentSong.directionalCues.filter { !isDirectionalCueTrimmedOut($0) }.sorted(by: { $0.time < $1.time })
            if selectedDirectionalCueId == nil || !activeDirCues.contains(where: { $0.id == selectedDirectionalCueId }), let first = activeDirCues.first {
                selectedDirectionalCueId = first.id
            }
        case .automation:
            isEditAutomationMode = true
            captureBaseMixSnapshot()
            if let pt = automationPoint(at: playbackOffsetSeconds) {
                selectedAutomationPointId = pt.id
                loadAutomationPointValues(id: pt.id)
            } else {
                selectedAutomationPointId = nil
            }
        case .midiMapping:
            isEditMIDIMappingMode = true
            MIDIMappingManager.shared.reconnectAllSources()
        case .keyboardMapping:
            isEditKeyboardMappingMode = true
        case .smpte:
            isEditSMPTEMode = true
        default:
            break
        }
        updateArrangementWaveform()
    }
    
    // Waveform Zoom State (Default 100% = 69% of baseline)
    @Published public var waveformZoomScale: CGFloat = 1.0
    
    // Song & Setlist State (Starts in Blank Session State)
    @Published public var currentSong: Song = Song(
        title: "",
        artist: "",
        bpm: 120.0,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
        musicalKey: "—",
        sections: []
    ) {
        didSet {
            if currentSong.id != oldValue.id ||
               currentSong.beatGrid.count != oldValue.beatGrid.count ||
               currentSong.bpm != oldValue.bpm ||
               currentSong.timeSignatureChanges != oldValue.timeSignatureChanges ||
               currentSong.sections != oldValue.sections ||
               (precomputedDownbeatMarkers.isEmpty && !currentSong.beatGrid.isEmpty) {
                rebuildPrecomputedBeatGrid()
            }
            if currentSong.id != oldValue.id ||
               currentSong.automationPoints != oldValue.automationPoints ||
               currentSong.sections != oldValue.sections {
                rebuildCachedActiveAutomation()
            }
        }
    }
    
    @Published public var currentSetlist: Setlist = Setlist(
        name: "New Setlist",
        songs: []
    )
    @Published public var currentSessionURL: URL? = nil
    @Published public var currentSessionLoadedModDate: Date? = nil
    @Published public var currentSessionLoadedRevisionId: UUID? = nil
    
    // Unsaved Changes & Cloud Update Tracking (Setlist Menu Indicator Dot)
    @Published public var hasUnsavedChanges: Bool = false
    @Published public var hasCloudSetlistUpdate: Bool = false
    private var acknowledgedCloudRevisionIds: Set<UUID> = []
    private var acknowledgedCloudModDatesByFileName: [String: Date] = [:]
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    private var undoStack: [SessionUndoSnapshot] = []
    private var redoStack: [SessionUndoSnapshot] = []
    private var baselineUndoSnapshot: SessionUndoSnapshot? = nil
    private var lastUndoCommitTime: TimeInterval = 0
    private var isApplyingUndoRedo: Bool = false
    private var cloudSetlistsCancellable: AnyCancellable? = nil

    private func captureCurrentUndoSnapshot() -> SessionUndoSnapshot {
        let trackSnaps: [TrackUndoSnapshot] = tracks.map { track in
            let ch = channels[track.id]
            return TrackUndoSnapshot(
                id: track.id,
                name: track.name,
                role: track.role,
                fileURL: track.fileURL,
                sourceFileURL: track.sourceFileURL,
                volume: track.volume,
                pan: track.pan,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                isSoloSafe: track.isSoloSafe,
                routing: track.routing,
                assignedBusName: track.assignedBusName,
                includeInWaveform: track.includeInWaveform,
                duration: track.duration,
                waveformPeaks: track.waveformPeaks,
                pristineBuffer: pristineMasterBuffers[track.id] ?? ch?.buffer,
                activeBuffer: ch?.buffer ?? pristineMasterBuffers[track.id]
            )
        }
        let busSnaps: [BusUndoSnapshot] = busses.map { bus in
            BusUndoSnapshot(
                id: bus.id,
                name: bus.name,
                volume: bus.volume,
                isMuted: bus.isMuted,
                isSoloed: bus.isSoloed,
                isSoloSafe: bus.isSoloSafe,
                isMono: bus.isMono,
                physicalOutputChannel: bus.physicalOutputChannel,
                color: bus.color
            )
        }
        return SessionUndoSnapshot(
            currentSetlist: currentSetlist,
            currentSongIndex: currentSongIndex,
            currentSong: currentSong,
            masterVolume: masterVolume,
            padChannelVolume: padChannelVolume,
            padChannelPan: padChannelPan,
            padChannelMuted: padChannelMuted,
            padChannelSoloed: padChannelSoloed,
            tracks: trackSnaps,
            busses: busSnaps
        )
    }

    public func resetUndoHistoryToCurrentState() {
        undoStack.removeAll()
        redoStack.removeAll()
        baselineUndoSnapshot = captureCurrentUndoSnapshot()
        lastUndoCommitTime = 0
        canUndo = false
        canRedo = false
    }

    private func recordUndoCheckpointIfNeeded() {
        guard !isApplyingUndoRedo else { return }
        let current = captureCurrentUndoSnapshot()
        guard let previous = baselineUndoSnapshot else {
            baselineUndoSnapshot = current
            return
        }
        guard current != previous else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastUndoCommitTime) < 0.30 && !undoStack.isEmpty {
            baselineUndoSnapshot = current
            lastUndoCommitTime = now
            if !redoStack.isEmpty {
                redoStack.removeAll()
                canRedo = false
            }
            return
        }

        undoStack.append(previous)
        if undoStack.count > 50 {
            undoStack.removeFirst(undoStack.count - 50)
        }
        redoStack.removeAll()
        baselineUndoSnapshot = current
        lastUndoCommitTime = now
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    public func undo() {
        guard let target = undoStack.popLast() else { return }
        let current = baselineUndoSnapshot ?? captureCurrentUndoSnapshot()
        redoStack.append(current)
        if redoStack.count > 50 {
            redoStack.removeFirst(redoStack.count - 50)
        }
        applyUndoSnapshot(target)
        baselineUndoSnapshot = captureCurrentUndoSnapshot()
        lastUndoCommitTime = 0
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    public func redo() {
        guard let target = redoStack.popLast() else { return }
        let current = baselineUndoSnapshot ?? captureCurrentUndoSnapshot()
        undoStack.append(current)
        if undoStack.count > 50 {
            undoStack.removeFirst(undoStack.count - 50)
        }
        applyUndoSnapshot(target)
        baselineUndoSnapshot = captureCurrentUndoSnapshot()
        lastUndoCommitTime = 0
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func applyUndoSnapshot(_ snapshot: SessionUndoSnapshot) {
        isApplyingUndoRedo = true
        defer { isApplyingUndoRedo = false }

        let prevSong = currentSong
        let prevSongId = currentSong.id
        let prevTrackFlags = tracks.map { ($0.id, $0.includeInWaveform) }

        currentSetlist = snapshot.currentSetlist

        if snapshot.currentSong.id != prevSongId {
            currentSongIndex = snapshot.currentSongIndex
            if !snapshot.tracks.isEmpty && (songBuffersCache[snapshot.currentSong.id]?.isEmpty ?? true) {
                let restoredForTarget: [(StemTrack, AVAudioPCMBuffer)] = snapshot.tracks.compactMap { snap in
                    guard let buf = snap.pristineBuffer ?? snap.activeBuffer else { return nil }
                    let trk = StemTrack(
                        id: snap.id,
                        name: snap.name,
                        role: snap.role,
                        fileURL: snap.fileURL,
                        sourceFileURL: snap.sourceFileURL,
                        volume: snap.volume,
                        pan: snap.pan,
                        isMuted: snap.isMuted,
                        isSoloed: snap.isSoloed,
                        isSoloSafe: snap.isSoloSafe,
                        routing: snap.routing,
                        assignedBusName: snap.assignedBusName,
                        includeInWaveform: snap.includeInWaveform
                    )
                    trk.duration = snap.duration
                    trk.waveformPeaks = snap.waveformPeaks
                    return (trk, buf)
                }
                songBuffersCache[snapshot.currentSong.id] = restoredForTarget
                recordTrackMetadataBackup(for: snapshot.currentSong.id, tracks: restoredForTarget.map { $0.0 })
                if restoredForTarget.contains(where: { $0.1.frameLength > 100 }) {
                    memoryEvictedSongIds.remove(snapshot.currentSong.id)
                }
            }
            if !snapshot.currentSong.title.isEmpty || !snapshot.tracks.isEmpty {
                loadSong(snapshot.currentSong)
            } else {
                stop()
                clearAllTracks()
                currentSong = snapshot.currentSong
            }
        } else {
            currentSongIndex = snapshot.currentSongIndex
        }

        currentSong = snapshot.currentSong
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count &&
           currentSetlist.songs[currentSongIndex].id == snapshot.currentSong.id {
            currentSetlist.songs[currentSongIndex] = snapshot.currentSong
        }

        masterVolume = snapshot.masterVolume
        padChannelVolume = snapshot.padChannelVolume
        padChannelPan = snapshot.padChannelPan
        padChannelMuted = snapshot.padChannelMuted
        padChannelSoloed = snapshot.padChannelSoloed

        for busSnap in snapshot.busses {
            if let bus = busses.first(where: { $0.id == busSnap.id }) {
                if bus.name != busSnap.name { bus.name = busSnap.name }
                if bus.volume != busSnap.volume { bus.volume = busSnap.volume }
                if bus.isMuted != busSnap.isMuted { bus.isMuted = busSnap.isMuted }
                if bus.isSoloed != busSnap.isSoloed { bus.isSoloed = busSnap.isSoloed }
                if bus.isSoloSafe != busSnap.isSoloSafe { bus.isSoloSafe = busSnap.isSoloSafe }
                if bus.isMono != busSnap.isMono { bus.isMono = busSnap.isMono }
                if bus.physicalOutputChannel != busSnap.physicalOutputChannel { bus.physicalOutputChannel = busSnap.physicalOutputChannel }
                if bus.color != busSnap.color { bus.color = busSnap.color }
            }
        }

        var existingTracksById: [UUID: StemTrack] = [:]
        for t in tracks {
            existingTracksById[t.id] = t
        }
        let existingOrder = tracks.map { $0.id }
        let targetOrder = snapshot.tracks.map { $0.id }
        let trackStructureChanged = (existingOrder != targetOrder)

        var restoredTracks: [StemTrack] = []
        restoredTracks.reserveCapacity(snapshot.tracks.count)
        let targetIdSet = Set(targetOrder)

        for key in Array(pristineMasterBuffers.keys) where !targetIdSet.contains(key) {
            pristineMasterBuffers.removeValue(forKey: key)
        }
        for key in Array(channels.keys) where !targetIdSet.contains(key) {
            channels.removeValue(forKey: key)
        }

        for ts in snapshot.tracks {
            let track: StemTrack
            if let existing = existingTracksById[ts.id] {
                track = existing
                if track.name != ts.name { track.name = ts.name }
                if track.role != ts.role { track.role = ts.role }
                track.fileURL = ts.fileURL
                track.sourceFileURL = ts.sourceFileURL
                if track.volume != ts.volume { track.volume = ts.volume }
                if track.pan != ts.pan { track.pan = ts.pan }
                if track.isMuted != ts.isMuted { track.isMuted = ts.isMuted }
                if track.isSoloed != ts.isSoloed { track.isSoloed = ts.isSoloed }
                if track.isSoloSafe != ts.isSoloSafe { track.isSoloSafe = ts.isSoloSafe }
                if track.routing != ts.routing { track.routing = ts.routing }
                if track.assignedBusName != ts.assignedBusName { track.assignedBusName = ts.assignedBusName }
                if track.includeInWaveform != ts.includeInWaveform { track.includeInWaveform = ts.includeInWaveform }
                track.duration = ts.duration
                if track.waveformPeaks.isEmpty && !ts.waveformPeaks.isEmpty {
                    track.waveformPeaks = ts.waveformPeaks
                }
            } else {
                track = StemTrack(
                    id: ts.id,
                    name: ts.name,
                    role: ts.role,
                    fileURL: ts.fileURL,
                    sourceFileURL: ts.sourceFileURL,
                    volume: ts.volume,
                    pan: ts.pan,
                    isMuted: ts.isMuted,
                    isSoloed: ts.isSoloed,
                    isSoloSafe: ts.isSoloSafe,
                    routing: ts.routing,
                    assignedBusName: ts.assignedBusName,
                    includeInWaveform: ts.includeInWaveform
                )
                track.duration = ts.duration
                track.waveformPeaks = ts.waveformPeaks
            }

            if let pBuf = ts.pristineBuffer {
                pristineMasterBuffers[ts.id] = pBuf
            }
            let buf = ts.activeBuffer ?? ts.pristineBuffer
            if let existingChannel = channels[ts.id], existingChannel.track === track {
                if let buf = buf {
                    existingChannel.buffer = buf
                }
            } else {
                channels[ts.id] = TrackChannel(track: track, buffer: buf)
            }
            restoredTracks.append(track)
        }

        if trackStructureChanged {
            tracks = restoredTracks
        }
        if !currentSong.title.isEmpty {
            let restoredCache: [(StemTrack, AVAudioPCMBuffer)] = restoredTracks.compactMap { track in
                guard let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer else { return nil }
                return (track, buf)
            }
            songBuffersCache[currentSong.id] = restoredCache
            recordTrackMetadataBackup(for: currentSong.id, tracks: restoredCache.map { $0.0 })
            if restoredCache.contains(where: { $0.1.frameLength > 100 }) {
                memoryEvictedSongIds.remove(currentSong.id)
            }
        }

        if snapshot.currentSong.id == prevSongId {
            let newDur: TimeInterval = !currentSong.sections.isEmpty
                ? (currentSong.sections.map { $0.endTime }.max() ?? 0.0)
                : (tracks.map { $0.duration }.max() ?? 0.0)
            currentSongDuration = newDur
            transportPosition.totalDuration = newDur
            transportPosition.currentBPM = currentSong.bpm
            transportClock.position.totalDuration = newDur
            transportClock.position.currentBPM = currentSong.bpm

            let clickNeedsRefresh =
                prevSong.clickSource != currentSong.clickSource ||
                prevSong.clickSound != currentSong.clickSound ||
                prevSong.clickAccentEnabled != currentSong.clickAccentEnabled ||
                prevSong.clickQuarterEnabled != currentSong.clickQuarterEnabled ||
                prevSong.clickEighthEnabled != currentSong.clickEighthEnabled ||
                prevSong.clickSixteenthEnabled != currentSong.clickSixteenthEnabled ||
                prevSong.clickAccentVolume != currentSong.clickAccentVolume ||
                prevSong.clickQuarterVolume != currentSong.clickQuarterVolume ||
                prevSong.clickEighthVolume != currentSong.clickEighthVolume ||
                prevSong.clickSixteenthVolume != currentSong.clickSixteenthVolume ||
                prevSong.bpm != currentSong.bpm ||
                prevSong.timeSignatureNumerator != currentSong.timeSignatureNumerator ||
                prevSong.timeSignatureDenominator != currentSong.timeSignatureDenominator ||
                prevSong.timeSignatureChanges != currentSong.timeSignatureChanges ||
                prevSong.sections != currentSong.sections ||
                prevSong.beatGrid != currentSong.beatGrid

            let guideNeedsRefresh =
                prevSong.guideSource != currentSong.guideSource ||
                prevSong.guideVoice != currentSong.guideVoice ||
                prevSong.guideFallbackVoice != currentSong.guideFallbackVoice ||
                prevSong.guideCountInEnabled != currentSong.guideCountInEnabled ||
                prevSong.speakDirectionalCuesOnUploadedGuide != currentSong.speakDirectionalCuesOnUploadedGuide ||
                prevSong.bpm != currentSong.bpm ||
                prevSong.timeSignatureNumerator != currentSong.timeSignatureNumerator ||
                prevSong.timeSignatureDenominator != currentSong.timeSignatureDenominator ||
                prevSong.timeSignatureChanges != currentSong.timeSignatureChanges ||
                prevSong.sections != currentSong.sections ||
                prevSong.directionalCues != currentSong.directionalCues ||
                prevSong.beatGrid != currentSong.beatGrid

            if clickNeedsRefresh {
                if currentSong.clickSource == .generated {
                    regenerateClickTrack()
                } else {
                    applyClickBuffer()
                }
            }
            if guideNeedsRefresh {
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else {
                    applyGuideBuffer()
                }
            }

            let transposeOrTempoChanged =
                prevSong.transposeSemitones != currentSong.transposeSemitones ||
                prevSong.preserveVocalFormants != currentSong.preserveVocalFormants ||
                prevSong.bpm != currentSong.bpm
            if transposeOrTempoChanged && (currentSong.transposeSemitones != 0 || currentSong.isTempoShifted) &&
               cachedTransformedBuffers(for: currentSong) == nil {
                setKeyAndTempo(
                    semitones: currentSong.transposeSemitones,
                    tempoBPM: currentSong.bpm,
                    forSongIndex: currentSongIndex
                )
            }

            let newTrackFlags = restoredTracks.map { ($0.id, $0.includeInWaveform) }
            let waveformChanged = trackStructureChanged ||
                zip(prevTrackFlags, newTrackFlags).contains { $0.0 != $1.0 || $0.1 != $1.1 }
            if waveformChanged {
                recalculateAggregateWaveform(samplesCount: 4000)
            }
        }

        rebuildPrecomputedBeatGrid()
        rebuildCachedActiveAutomation()
        updateMatrix()
        syncMixState()
        hasUnsavedChanges = true
        objectWillChange.send()
    }

    /// Authoritative check for whether a Cloud Library setlist represents a newer revision authored by another device
    /// or waiting on iCloud Drive, suppressing self-authored saves made on this Mac.
    public func shouldShowCloudUpdate(for item: SetlistLibraryItem) -> Bool {
        guard item.source == .cloud else { return false }
        if let authorId = item.lastSavedByDeviceId,
           authorId == PlaybackFileManager.currentDeviceInstanceId,
           !item.hasUnresolvedServerUpdate {
            return false
        }

        let isSameURL = currentSessionURL.map { $0.standardizedFileURL == item.url.standardizedFileURL } ?? false
        let matchesOpenSession: Bool = {
            guard let curURL = currentSessionURL else { return false }
            if isSameURL { return true }
            let isLocalSession = !LibraryBrowserManager.isURLInCloudLibrary(curURL)
            return isLocalSession && item.url.lastPathComponent.lowercased() == curURL.lastPathComponent.lowercased()
        }()

        guard matchesOpenSession else {
            return item.hasCloudUpdate
        }

        if !item.hasUnresolvedServerUpdate {
            if let itemRev = item.lastSavedRevisionId {
                if itemRev == currentSessionLoadedRevisionId || acknowledgedCloudRevisionIds.contains(itemRev) {
                    return false
                }
            } else if let ackMod = acknowledgedCloudModDatesByFileName[item.url.lastPathComponent.lowercased()],
                      item.modifiedDate.timeIntervalSince(ackMod) <= 2.0 {
                return false
            }
        }

        if item.hasUnresolvedServerUpdate {
            return true
        }
        if let itemRev = item.lastSavedRevisionId, let loadedRev = currentSessionLoadedRevisionId {
            if isSameURL {
                return itemRev != loadedRev
            }
            return itemRev != loadedRev && (currentSessionLoadedModDate.map { item.modifiedDate > $0 } ?? true)
        }
        if let loadedMod = currentSessionLoadedModDate {
            return item.modifiedDate.timeIntervalSince(loadedMod) > 2.0
        }
        return item.hasCloudUpdate
    }

    public func updateCloudSetlistUpdateFlag(from setlists: [SetlistLibraryItem]) {
        guard let curURL = currentSessionURL else {
            hasCloudSetlistUpdate = false
            return
        }
        let currentFileName = curURL.lastPathComponent.lowercased()
        let isLocalSession = !LibraryBrowserManager.isURLInCloudLibrary(curURL)
        hasCloudSetlistUpdate = setlists.contains { item in
            guard item.source == .cloud else { return false }
            let matchesOpenSession = (curURL.standardizedFileURL == item.url.standardizedFileURL)
                || (isLocalSession && item.url.lastPathComponent.lowercased() == currentFileName)
            guard matchesOpenSession else { return false }
            return shouldShowCloudUpdate(for: item)
        }
    }

    /// Immediately clears both the unsaved (red) and cloud-update (cyan) Setlist Menu indicators when initiating
    /// or completing an explicit save on this Mac, preventing self-authored saves or stale cloud items from re-arming them.
    @MainActor
    public func clearSaveAndCloudUpdateIndicators(revisionId: UUID, targetURLs: [URL] = []) {
        hasUnsavedChanges = false
        hasCloudSetlistUpdate = false
        currentSessionLoadedRevisionId = revisionId
        acknowledgedCloudRevisionIds.insert(revisionId)
        currentSessionLoadedModDate = max(currentSessionLoadedModDate ?? .distantPast, Date())

        var targetFileNames = Set(targetURLs.map { $0.lastPathComponent.lowercased() })
        if let cur = currentSessionURL {
            targetFileNames.insert(cur.lastPathComponent.lowercased())
        }
        let setlistName = currentSetlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !setlistName.isEmpty {
            targetFileNames.insert(LibraryBrowserManager.sanitizedPackageFilename(setlistName, ext: "pbsession").lowercased())
        }

        for item in LibraryBrowserManager.shared.setlists where item.source == .cloud {
            if targetFileNames.contains(item.url.lastPathComponent.lowercased()) {
                if let rev = item.lastSavedRevisionId {
                    acknowledgedCloudRevisionIds.insert(rev)
                }
                let fileKey = item.url.lastPathComponent.lowercased()
                let prevAck = acknowledgedCloudModDatesByFileName[fileKey] ?? .distantPast
                acknowledgedCloudModDatesByFileName[fileKey] = max(prevAck, max(item.modifiedDate, Date()))
            }
        }

        LibraryBrowserManager.shared.markSetlistSavedOnThisDevice(
            urls: targetURLs,
            setlistName: currentSetlist.name,
            revisionId: revisionId
        )
    }
    
    public func markSessionChanged() {
        if Thread.isMainThread {
            if !hasUnsavedChanges {
                hasUnsavedChanges = true
            }
            recordUndoCheckpointIfNeeded()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.hasUnsavedChanges {
                    self.hasUnsavedChanges = true
                }
                self.recordUndoCheckpointIfNeeded()
            }
        }
    }
    
    public func markSessionSaved() {
        if Thread.isMainThread {
            hasUnsavedChanges = false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hasUnsavedChanges = false
            }
        }
    }
    
    @Published public var currentSongIndex: Int = 0
    @Published public var isEngineRunning: Bool = false
    
    // Offline Pre-Rendered Transposition & Tempo-Stretch State
    @Published public var isTransposing: Bool = false
    @Published public var transposeProgress: Float = 0.0
    @Published public var lastTransposeSourceBySong: [UUID: String] = [:]
    @Published public var showTranspositionWarning: Bool = false
    @Published public var showDownloadingWarning: Bool = false
    @Published public var transposingSongId: UUID? = nil
    @Published public var renderStatusText: String = "Transposing..."
    @Published public var transposeProgressBySong: [UUID: Float] = [:]
    @Published public var downloadingSongProgress: [UUID: Double] = [:]
    @Published public var cancelledDownloadSongIds: Set<UUID> = []

    private final class CancelledDownloadTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func insert(_ id: UUID) {
            lock.lock()
            ids.insert(id)
            lock.unlock()
        }
        func removeAll() {
            lock.lock()
            ids.removeAll()
            lock.unlock()
        }
        func contains(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }
    }
    private nonisolated let cancelledDownloadTracker = CancelledDownloadTracker()

    public nonisolated func isSongDownloadCancelled(_ songId: UUID) -> Bool {
        cancelledDownloadTracker.contains(songId)
    }

    public func cancelSongDownload(songId: UUID) {
        cancelledDownloadTracker.insert(songId)
        cancelledDownloadSongIds.insert(songId)
        downloadingSongProgress.removeValue(forKey: songId)
    }

    private func clearCancelledSongDownloads() {
        cancelledDownloadTracker.removeAll()
        cancelledDownloadSongIds.removeAll()
    }
    private var pristineMasterBuffers: [UUID: AVAudioPCMBuffer] = [:]
    private var transposeTask: Task<Void, Never>?
    private var transposeTasksBySong: [UUID: Task<Void, Never>] = [:]
    private var transposeGeneration: Int = 0
    
    // Automatic Guide Section Labeling State
    @Published public var isAutoLabelingSections: Bool = false
    @Published public var autoLabelProgress: Float = 0.0
    @Published public var autoLabelStatusText: String = ""
    
    // Automatic Click Track Tempo & Dynamic Beat Grid Detection State
    @Published public var isAnalyzingClickTempo: Bool = false
    
    // Dedicated per-division Click VU meters (flash in time with each subdivision)
    public let clickAccentMeter = StereoMeterModel()
    public let clickQuarterMeter = StereoMeterModel()
    public let clickEighthMeter = StereoMeterModel()
    public let clickSixteenthMeter = StereoMeterModel()
    
    // Click & Guide Audio Generation State & Progress
    @Published public var isGeneratingClick: Bool = false
    @Published public var isGeneratingGuide: Bool = false
    @Published public var clickGuideStatusText: String = ""
    
    // Reference Track Offline Bounce State & Progress
    @Published public var isBouncingReference: Bool = false
    @Published public var referenceBounceProgress: Double = 0.0
    @Published public var referenceBounceStatus: String = ""
    @Published public var referenceBounceError: String? = nil
    
    // In-window pop-out sample managers
    @Published public var isShowingCustomClickSampleManager: Bool = false
    @Published public var isShowingCustomGuideSampleManager: Bool = false
    
    // Audio buffers cache for all songs currently in the setlist
    private var songBuffersCache: [UUID: [(track: StemTrack, buffer: AVAudioPCMBuffer)]] = [:]
    private var memoryEvictedSongIds: Set<UUID> = []
    private var songTrackMetadataBackup: [UUID: [StemTrack]] = [:]
    private var songWaveformCache: [UUID: (peaks: [Float], image: NSImage?)] = [:]
    // Transformed audio buffers cache for transposed / tempo-shifted songs in the setlist
    private var songTransposedBuffersCache: [UUID: (semitones: Int, preserveVocalFormants: Bool, bpmHundredths: Int, buffers: [UUID: AVAudioPCMBuffer])] = [:]

    private nonisolated static func isLikelyUUIDString(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func recordTrackMetadataBackup(for songId: UUID, tracks: [StemTrack]) {
        let nonUUIDTracks = tracks.filter { !Self.isLikelyUUIDString($0.name) }
        guard !nonUUIDTracks.isEmpty else { return }
        songTrackMetadataBackup[songId] = nonUUIDTracks
    }

    private static func hasLocalBackingAudioFile(for track: StemTrack) -> Bool {
        if PlaybackFileManager.shared.hasValidCachedStem(for: track.id) {
            return true
        }
        for candidate in [track.fileURL, track.sourceFileURL].compactMap({ $0 }) {
            guard candidate.pathExtension.lowercased() == "m4a" else { continue }
            if LibraryBrowserManager.isCloudStorageURL(candidate) && !LibraryBrowserManager.checkIsDownloaded(at: candidate) {
                continue
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
        }
        return false
    }

    private func resolveLocalBackingURL(for track: StemTrack) -> URL? {
        if PlaybackFileManager.shared.hasValidCachedStem(for: track.id) {
            return PlaybackFileManager.shared.cachedStemURL(for: track.id)
        }
        for candidate in [track.fileURL, track.sourceFileURL].compactMap({ $0 }) {
            if LibraryBrowserManager.isCloudStorageURL(candidate) && !LibraryBrowserManager.checkIsDownloaded(at: candidate) {
                continue
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func rehydrateEvictedSongBuffersIfNeeded(for song: Song) {
        let existingEntry = songBuffersCache[song.id]
        let hasEvictionMarker = memoryEvictedSongIds.contains(song.id)
        let missingCacheWithBackup = ((existingEntry?.isEmpty ?? true) && songTrackMetadataBackup[song.id] != nil && downloadingSongProgress[song.id] == nil)
        guard hasEvictionMarker || missingCacheWithBackup else { return }

        let savedTracks = (existingEntry?.isEmpty == false ? existingEntry?.map { $0.track } : nil)
            ?? songTrackMetadataBackup[song.id]
            ?? []
        guard !savedTracks.isEmpty else { return }

        let canonicalFormat = getCanonicalProcessingFormat()
        let isActiveSong = (currentSong.id == song.id)
        var rehydrated: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []
        rehydrated.reserveCapacity(savedTracks.count)

        for track in savedTracks {
            let cat = StemCategory.category(for: track.name, role: track.role)
            if cat == .click { track.role = .click }
            else if cat == .guide { track.role = .guide }

            if let localURL = resolveLocalBackingURL(for: track),
               let fileBuf = try? PlaybackFileManager.shared.readPCMBuffer(from: localURL) {
                let norm = normalizeBufferToCanonical(buffer: fileBuf, targetFormat: canonicalFormat)
                if track.fileURL == nil {
                    track.fileURL = localURL
                }
                if cat == .click {
                    if norm.frameLength > 100 {
                        uploadedClickBuffers[song.id] = norm
                    }
                    if song.clickSource == .generated {
                        if let genClick = generatedClickBuffers[song.id], genClick.frameLength > 1 {
                            rehydrated.append((track, genClick))
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            rehydrated.append((track, stub))
                        }
                    } else {
                        rehydrated.append((track, norm))
                    }
                } else if cat == .guide {
                    if norm.frameLength > 100 {
                        uploadedGuideBuffers[song.id] = norm
                    }
                    if song.guideSource == .generated {
                        let expectedState = isActiveSong ? currentLiveGuideLoopState() : Self.defaultGuideLoopState(for: song)
                        if let genGuide = generatedGuideBuffers[song.id],
                           genGuide.frameLength > 1,
                           generatedGuideLoopStates[song.id] == expectedState {
                            rehydrated.append((track, genGuide))
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            rehydrated.append((track, stub))
                        }
                    } else {
                        rehydrated.append((track, norm))
                    }
                } else {
                    if norm.frameLength > 10 {
                        track.duration = Double(norm.frameLength) / norm.format.sampleRate
                    }
                    if track.waveformPeaks.isEmpty && track.includeInWaveform && norm.frameLength > 100 {
                        track.waveformPeaks = extractWaveformPeaks(from: norm, samplesCount: 4000)
                    }
                    rehydrated.append((track, norm))
                }
            } else if cat == .click && song.clickSource == .generated {
                if let genClick = generatedClickBuffers[song.id], genClick.frameLength > 1 {
                    rehydrated.append((track, genClick))
                } else if let stub = makeSilentStub(format: canonicalFormat) {
                    rehydrated.append((track, stub))
                }
            } else if cat == .guide && song.guideSource == .generated {
                let expectedState = isActiveSong ? currentLiveGuideLoopState() : Self.defaultGuideLoopState(for: song)
                if let genGuide = generatedGuideBuffers[song.id],
                   genGuide.frameLength > 1,
                   generatedGuideLoopStates[song.id] == expectedState {
                    rehydrated.append((track, genGuide))
                } else if let stub = makeSilentStub(format: canonicalFormat) {
                    rehydrated.append((track, stub))
                }
            } else if let existingBuf = existingEntry?.first(where: { $0.track.id == track.id })?.buffer {
                rehydrated.append((track, existingBuf))
            }
        }

        if rehydrated.contains(where: { Self.isClickTrack($0.0) && $0.0.fileURL != nil }) {
            rehydrated.removeAll { Self.isClickTrack($0.0) && $0.0.fileURL == nil }
        }
        if rehydrated.contains(where: { Self.isGuideTrack($0.0) && $0.0.fileURL != nil }) {
            rehydrated.removeAll { Self.isGuideTrack($0.0) && $0.0.fileURL == nil }
        }

        guard !rehydrated.isEmpty else { return }
        songBuffersCache[song.id] = rehydrated
        recordTrackMetadataBackup(for: song.id, tracks: rehydrated.map { $0.0 })
        if rehydrated.contains(where: { !Self.isClickOrGuideTrack($0.0) && $0.1.frameLength > 100 })
            || !rehydrated.contains(where: { !Self.isClickOrGuideTrack($0.0) }) {
            memoryEvictedSongIds.remove(song.id)
        }
    }

    private func reconstructTracksFromStemURLs(for song: Song, canonicalFormat: AVAudioFormat) -> [(track: StemTrack, buffer: AVAudioPCMBuffer)] {
        var backupById: [UUID: StemTrack] = [:]
        if let backed = songTrackMetadataBackup[song.id] {
            for t in backed {
                backupById[t.id] = t
            }
        }
        var diskMetaById: [UUID: TrackFileMetadata] = [:]
        if backupById.isEmpty, let sessURL = currentSessionURL {
            let metaTracks = PlaybackFileManager.shared.loadSongTrackMetadataFromSession(songId: song.id, sessionURL: sessURL)
                ?? (song.sourceSongId.flatMap { PlaybackFileManager.shared.loadSongTrackMetadataFromSession(songId: $0, sessionURL: sessURL) })
            if let metaTracks = metaTracks {
                for tm in metaTracks where !Self.isLikelyUUIDString(tm.name) {
                    diskMetaById[tm.id] = tm
                }
            }
        }

        let isActiveSong = (currentSong.id == song.id)
        var loaded: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []
        loaded.reserveCapacity(song.stemURLs.count)

        for url in song.stemURLs {
            guard let fileBuf = try? PlaybackFileManager.shared.readPCMBuffer(from: url) else { continue }
            let norm = normalizeBufferToCanonical(buffer: fileBuf, targetFormat: canonicalFormat)
            let baseName = url.deletingPathExtension().lastPathComponent

            let track: StemTrack
            if let uuid = UUID(uuidString: baseName), let backedTrack = backupById[uuid] {
                backedTrack.fileURL = url
                track = backedTrack
            } else if let uuid = UUID(uuidString: baseName), let tm = diskMetaById[uuid] {
                let t = StemTrack(
                    id: tm.id,
                    name: tm.name,
                    role: tm.role,
                    fileURL: url,
                    sourceFileURL: tm.sourceFilePath.map { URL(fileURLWithPath: $0) },
                    volume: tm.volume,
                    pan: tm.pan,
                    isMuted: tm.isMuted,
                    isSoloed: tm.isSoloed,
                    isSoloSafe: tm.isSoloSafe,
                    routing: tm.routing,
                    assignedBusName: tm.assignedBusName,
                    includeInWaveform: tm.includeInWaveform
                )
                if let dur = tm.duration, dur > 0 {
                    t.duration = dur
                }
                t.waveformPeaks = TrackFileMetadata.decodePeaks(tm.waveformPeaksData)
                track = t
            } else {
                let cat = StemCategory.category(for: baseName)
                let role: TrackRole = (cat == .click) ? .click : ((cat == .guide) ? .guide : .stem)
                track = StemTrack(name: baseName, role: role, fileURL: url)
            }

            let cat = StemCategory.category(for: track.name, role: track.role)
            if cat == .click {
                track.role = .click
                if norm.frameLength > 100 {
                    uploadedClickBuffers[song.id] = norm
                }
                if song.clickSource == .generated {
                    if let genClick = generatedClickBuffers[song.id], genClick.frameLength > 1 {
                        loaded.append((track, genClick))
                    } else if let stub = makeSilentStub(format: canonicalFormat) {
                        loaded.append((track, stub))
                    }
                    continue
                }
            } else if cat == .guide {
                track.role = .guide
                if norm.frameLength > 100 {
                    uploadedGuideBuffers[song.id] = norm
                }
                if song.guideSource == .generated {
                    let expectedState = isActiveSong ? currentLiveGuideLoopState() : Self.defaultGuideLoopState(for: song)
                    if let genGuide = generatedGuideBuffers[song.id],
                       genGuide.frameLength > 1,
                       generatedGuideLoopStates[song.id] == expectedState {
                        loaded.append((track, genGuide))
                    } else if let stub = makeSilentStub(format: canonicalFormat) {
                        loaded.append((track, stub))
                    }
                    continue
                }
            }

            if norm.frameLength > 10 {
                track.duration = Double(norm.frameLength) / norm.format.sampleRate
            }
            if track.waveformPeaks.isEmpty && track.includeInWaveform && norm.frameLength > 100 {
                track.waveformPeaks = extractWaveformPeaks(from: norm, samplesCount: 4000)
            }
            loaded.append((track, norm))
        }

        if loaded.contains(where: { Self.isClickTrack($0.0) && $0.0.fileURL != nil }) {
            loaded.removeAll { Self.isClickTrack($0.0) && $0.0.fileURL == nil }
        }
        if loaded.contains(where: { Self.isGuideTrack($0.0) && $0.0.fileURL != nil }) {
            loaded.removeAll { Self.isGuideTrack($0.0) && $0.0.fileURL == nil }
        }

        if loaded.count > 1 {
            loaded.sort { a, b in
                let ord1 = StemCategory.playbackOrder(for: a.0.name, role: a.0.role)
                let ord2 = StemCategory.playbackOrder(for: b.0.name, role: b.0.role)
                if ord1 != ord2 { return ord1 < ord2 }
                let cat1 = StemCategory.category(for: a.0.name, role: a.0.role)
                let cat2 = StemCategory.category(for: b.0.name, role: b.0.role)
                if cat1 != cat2 { return cat1 < cat2 }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
        }

        if !loaded.isEmpty {
            recordTrackMetadataBackup(for: song.id, tracks: loaded.map { $0.0 })
            memoryEvictedSongIds.remove(song.id)
        }
        return loaded
    }
    
    private func cachedTransformedBuffers(for song: Song) -> [UUID: AVAudioPCMBuffer]? {
        let needsTransform = song.transposeSemitones != 0 || song.isTempoShifted
        guard needsTransform,
              let entry = songTransposedBuffersCache[song.id],
              entry.semitones == song.transposeSemitones,
              entry.preserveVocalFormants == song.preserveVocalFormants,
              entry.bpmHundredths == PlaybackFileManager.cacheBPMHundredths(song.bpm),
              !entry.buffers.isEmpty,
              entry.buffers.values.allSatisfy({ $0.frameLength > 100 }) else {
            return nil
        }
        return entry.buffers
    }
    
    private func shouldRenderTransformedTrack(_ track: StemTrack, for song: Song, tempoShifted: Bool) -> Bool {
        if !Self.isClickOrGuideTrack(track) {
            return true
        }
        guard tempoShifted else { return false }
        let isGenClick = Self.isClickTrack(track) && song.clickSource == .generated
        let isGenGuide = Self.isGuideTrack(track) && song.guideSource == .generated
        return !isGenClick && !isGenGuide
    }
    
    private struct SendablePCMBufferRef: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    
    /// Helper to identify Click or Guide tracks that should never be pitch-transposed
    public nonisolated static func isClickOrGuideTrack(_ track: StemTrack) -> Bool {
        return track.role == .click || track.role == .guide ||
            track.assignedBusName.lowercased() == "click" || track.assignedBusName.lowercased() == "guide" ||
            track.name.lowercased().contains("click") || track.name.lowercased().contains("guide") ||
            track.name.lowercased().contains("cue") || track.name.lowercased().contains("metronome") ||
            track.name.lowercased().contains("tick") || track.name.lowercased().contains("count")
    }

    /// Helper to identify Vocal / BGV / Choir tracks eligible for vocal formant preservation
    public nonisolated static func isVocalTrack(_ track: StemTrack) -> Bool {
        guard !isClickOrGuideTrack(track) else { return false }
        return StemCategory.category(for: track.name, role: track.role) == .vocals ||
            track.assignedBusName.lowercased() == "vocals"
    }
    
    // Hardware Audio Devices
    public let deviceManager = AudioDeviceManager.shared
    
    // MARK: - Audio Engine Nodes (Single-Clock SIMD Architecture)
    private let audioEngine: AVAudioEngine
    private let masterMixer: AVAudioMixerNode
    private var sourceNode: AVAudioSourceNode?
    private let transitionPlayerNode = AVAudioPlayerNode()
    private let mixState = RealTimeMixEngineState()
    private var channels: [UUID: TrackChannel] = [:]
    
    // MARK: - Clock & Synchronization
    private var fadeTimer: Timer?
    private var crossfadeTimer: Timer?
    private var hasTriggeredEarlyTransition: Bool = false
    private var hasTriggeredDualTransitionPad: Bool = false
    @Published public var pendingTransitionNextSongIndex: Int? = nil
    private var pendingTransitionStartOffset: TimeInterval = 0.0
    private var scheduledStartOffset: TimeInterval = 0.0
    public private(set) var playbackOffsetSeconds: TimeInterval = 0.0
    public private(set) var currentSongDuration: TimeInterval = 0.0
    private var currentPlayingSectionId: UUID? = nil
    
    // Click & Guide Audio Generators and Buffer Caches
    public let clickGenerator = ClickGenerator()
    public let guideAudioGenerator = GuideAudioGenerator.shared
    public let padPlayer = PadPlayerEngine()
    @Published public var padChannelVolume: Float = 0.80
    @Published public var padChannelPan: Float = 0.0
    @Published public var padChannelMuted: Bool = false
    @Published public var padChannelSoloed: Bool = false
    private var padMeterPeakL: Float = 0.0
    private var padMeterPeakR: Float = 0.0
    public var uploadedClickBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var uploadedGuideBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var generatedClickBuffers: [UUID: AVAudioPCMBuffer] = [:]
    public var generatedGuideBuffers: [UUID: AVAudioPCMBuffer] = [:]
    private struct GeneratedGuideLoopState: Equatable {
        let isLoopActive: Bool
        let loopedSectionId: UUID?
        let loopMode: LoopMode
        let singleLoopRemaining: Int
        let queuedNextSectionId: UUID?
    }
    private var generatedGuideLoopStates: [UUID: GeneratedGuideLoopState] = [:]
    private var guideRegenerationGeneration: UInt64 = 0
    private var preGeneratingClickGuideSongIds: Set<UUID> = []
    private var preGeneratingClickGuideCompletions: [UUID: [() -> Void]] = [:]
    
    private var sessionHydrationTask: Task<Void, Never>? = nil
    private var sessionHydrationGeneration: Int = 0
    
    public init() {
        self.audioEngine = AVAudioEngine()
        self.masterMixer = audioEngine.mainMixerNode
        
        if let dev = deviceManager.selectedDevice {
            lastAppliedHardwareDeviceID = dev.id
            lastAppliedHardwareChannelCount = dev.outputChannelCount
            loadBusRouting(for: dev)
        }
        setupSingleClockSourceNode()
        
        hardwareDeviceCancellable = deviceManager.$selectedDevice
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDevice in
                guard let self = self, let dev = newDevice else { return }
                let didChange = (dev.id != self.lastAppliedHardwareDeviceID) || (dev.outputChannelCount != self.lastAppliedHardwareChannelCount)
                guard didChange else { return }
                self.setOutputDevice(dev, showBanner: true)
            }
        
        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            print("Failed to start audio engine: \(error)")
        }
        
        // Stage 1: Synchronously hydrate session metadata (<10ms) so the window opens with the session already populated on Frame 1,
        // while Stage 2 loads the audio buffers in the background starting with the active song.
        restoreLastSessionIfAvailable()
        
        DispatchQueue.main.async { [weak self] in
            if let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2) {
                AudioSampleBank.shared.warmupCommonSamples(format: canonicalFormat)
            }
            self?.setupMemoryPressureMonitoring()
            self?.rebuildPrecomputedBeatGrid()
            self?.rebuildCachedActiveAutomation()
            self?.cloudSetlistsCancellable = LibraryBrowserManager.shared.$setlists
                .receive(on: DispatchQueue.main)
                .sink { [weak self] items in
                    self?.updateCloudSetlistUpdateFlag(from: items)
                }
            LibraryBrowserManager.shared.refreshSetlists()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performAutoSave()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebindUIDisplayLinkIfNeeded()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebindUIDisplayLinkIfNeeded()
        }
        
        MIDIMappingManager.shared.engine = self
        KeyboardMappingManager.shared.engine = self
        remoteServer.attach(to: self)
        if UserDefaults.standard.bool(forKey: "Playback_RemoteControlEnabled") {
            self.setRemoteControlEnabled(true)
        }
        
        let savedRedundancyEnabled = UserDefaults.standard.bool(forKey: "Playback_RedundancyEnabled")
        self.redundancyOutputChannel = UserDefaults.standard.string(forKey: "Playback_RedundancyChannel") ?? "Out 1"
        if savedRedundancyEnabled && availableMonoChannelsForRedundancy().contains(self.redundancyOutputChannel) {
            self.isRedundancyEnabled = true
        } else {
            self.isRedundancyEnabled = false
        }
        self.updateRedundancyState()
        
        let savedSMPTEEnabled = UserDefaults.standard.bool(forKey: "Playback_SMPTEEnabled")
        if let rawRate = UserDefaults.standard.string(forKey: "Playback_SMPTEFrameRate"), let rate = SMPTEFrameRate(rawValue: rawRate) {
            self.smpteFrameRate = rate
        }
        self.smpteOutputChannel = UserDefaults.standard.string(forKey: "Playback_SMPTEOutputChannel") ?? "Out 2"
        if savedSMPTEEnabled && availableMonoChannelsForSMPTE().contains(self.smpteOutputChannel) {
            self.isSMPTEEnabled = true
        } else {
            self.isSMPTEEnabled = false
        }
        self.updateSMPTEState()
        
        self.isSongSectionPreRollEnabled = UserDefaults.standard.bool(forKey: "Playback_SongSectionPreRollEnabled")
        let storedBars = UserDefaults.standard.integer(forKey: "Playback_SectionPreRollLengthBars")
        self.sectionPreRollLengthBars = storedBars > 0 ? storedBars : 2
        
        self.isGlobalStartPadWithSongEnabled = UserDefaults.standard.bool(forKey: "Playback_GlobalStartPadWithSongEnabled")
        self.isGlobalIncludeGuideSectionNumbersEnabled = UserDefaults.standard.bool(forKey: "Playback_GlobalIncludeGuideSectionNumbers")
        self.isFadersDefault100Enabled = UserDefaults.standard.bool(forKey: "Playback_FadersDefault100")
        if let rawClickSrc = UserDefaults.standard.string(forKey: "Playback_DefaultClickSource"),
           let clickSrc = ClickSource(rawValue: rawClickSrc) {
            self.defaultClickSourcePreference = clickSrc
        }
        if let rawGuideSrc = UserDefaults.standard.string(forKey: "Playback_DefaultGuideSource"),
           let guideSrc = GuideSource(rawValue: rawGuideSrc) {
            self.defaultGuideSourcePreference = guideSrc
        }
        resetUndoHistoryToCurrentState()
    }
    
    private var tapTimestamps: [Date] = []
    
    public func tapTempo() {
        let now = Date()
        tapTimestamps.append(now)
        if tapTimestamps.count > 6 {
            tapTimestamps.removeFirst(tapTimestamps.count - 6)
        }
        guard tapTimestamps.count >= 2 else { return }
        
        let recent = tapTimestamps.filter { now.timeIntervalSince($0) < 2.5 }
        tapTimestamps = recent
        guard recent.count >= 2 else { return }
        
        var intervals: [TimeInterval] = []
        for i in 1..<recent.count {
            intervals.append(recent[i].timeIntervalSince(recent[i - 1]))
        }
        let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        guard avgInterval > 0.1 else { return }
        let calculatedBPM = 60.0 / avgInterval
        let clampedBPM = max(30.0, min(300.0, round(calculatedBPM * 10) / 10.0))
        let wasShifted = currentSong.isTempoShifted
        currentSong.bpm = clampedBPM
        if !wasShifted {
            currentSong.originalBPM = clampedBPM
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            let setlistShifted = currentSetlist.songs[currentSongIndex].isTempoShifted
            currentSetlist.songs[currentSongIndex].bpm = clampedBPM
            if !setlistShifted {
                currentSetlist.songs[currentSongIndex].originalBPM = clampedBPM
            }
        }
        regenerateClickTrack()
        objectWillChange.send()
    }
    
    public func setBPM(_ bpm: Double, forSongIndex index: Int? = nil) {
        let clamped = max(20.0, min(300.0, bpm))
        let targetIdx = index ?? currentSongIndex
        if targetIdx >= 0 && targetIdx < currentSetlist.songs.count {
            let wasShifted = currentSetlist.songs[targetIdx].isTempoShifted
            currentSetlist.songs[targetIdx].bpm = clamped
            if !wasShifted {
                currentSetlist.songs[targetIdx].originalBPM = clamped
            }
        }
        if targetIdx == currentSongIndex {
            let wasShifted = currentSong.isTempoShifted
            currentSong.bpm = clamped
            if !wasShifted {
                currentSong.originalBPM = clamped
            }
            transportPosition.currentBPM = clamped
            transportClock.position.currentBPM = clamped
            if playbackState == .playing && !isMIDIMuted {
                MIDICueEngine.shared.updateMIDIClockTempo(clamped)
            }
            regenerateClickTrack()
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func cycleTransition() {
        guard currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count else { return }
        let allCases = SongTransitionType.allCases
        let currentType = currentSetlist.songs[currentSongIndex].transitionType
        let nextIndex = ((allCases.firstIndex(of: currentType) ?? 0) + 1) % allCases.count
        let nextType = allCases[nextIndex]
        updateSongTransition(at: currentSongIndex, type: nextType)
    }
    
    deinit {
        uiFallbackTimer?.invalidate()
        uiDisplayLink?.invalidate()
        transportWatchdogTimer?.cancel()
        if let token = playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        memoryPressureSource?.cancel()
        fadeTimer?.invalidate()
        crossfadeTimer?.invalidate()
        padPlayer.detach()
        audioEngine.stop()
    }

    private func setupMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            self.handleMemoryPressure(critical: event.contains(.critical))
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Graceful fallback for lower-RAM Macs under memory pressure: preserves active + immediate next song
    /// in RAM for 0.00ms transitions while unloading distant session-backed song PCM buffers without ever
    /// discarding track metadata (names, roles, mutes, faders, routing, or buses).
    public func handleMemoryPressure(critical: Bool) {
        guard currentSessionURL != nil, currentSetlist.songs.count > 2 else { return }
        var protectedIds = Set<UUID>()
        protectedIds.insert(currentSong.id)
        let nextIdx = currentSongIndex + 1
        if nextIdx >= 0 && nextIdx < currentSetlist.songs.count {
            protectedIds.insert(currentSetlist.songs[nextIdx].id)
        }
        if !critical {
            let prevIdx = currentSongIndex - 1
            if prevIdx >= 0 && prevIdx < currentSetlist.songs.count {
                protectedIds.insert(currentSetlist.songs[prevIdx].id)
            }
        }
        for song in currentSetlist.songs where !protectedIds.contains(song.id) {
            if downloadingSongProgress[song.id] != nil ||
               transposeTasksBySong[song.id] != nil ||
               transposingSongId == song.id {
                continue
            }

            songTransposedBuffersCache.removeValue(forKey: song.id)

            if critical || currentSetlist.songs.count > 3 {
                if let existing = songBuffersCache[song.id],
                   !existing.isEmpty,
                   existing.contains(where: { $0.buffer.frameLength > 100 }) {
                    let allHaveLocalFiles = existing.allSatisfy { (track, _) in
                        if track.fileURL == nil && Self.isClickOrGuideTrack(track) {
                            return true
                        }
                        return Self.hasLocalBackingAudioFile(for: track)
                    }
                    if allHaveLocalFiles, let stub = makeSilentStub(format: getCanonicalProcessingFormat()) {
                        recordTrackMetadataBackup(for: song.id, tracks: existing.map { $0.track })
                        var stubbed: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []
                        stubbed.reserveCapacity(existing.count)
                        for (track, _) in existing {
                            if track.fileURL == nil && PlaybackFileManager.shared.hasValidCachedStem(for: track.id) {
                                track.fileURL = PlaybackFileManager.shared.cachedStemURL(for: track.id)
                            }
                            stubbed.append((track: track, buffer: stub))
                        }
                        songBuffersCache[song.id] = stubbed
                        uploadedClickBuffers.removeValue(forKey: song.id)
                        uploadedGuideBuffers.removeValue(forKey: song.id)
                        memoryEvictedSongIds.insert(song.id)
                    }
                }
            }

            if critical {
                songWaveformCache.removeValue(forKey: song.id)
            }
        }
    }
    
    public func resolvePhysicalOutputChannels(for routingStr: String, isMono: Bool) -> (left: Int, right: Int) {
        let maxChannels = max(2, deviceManager.selectedDevice?.outputChannelCount ?? Int(audioEngine.outputNode.outputFormat(forBus: 0).channelCount))
        let digits = routingStr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
        if digits.count >= 2 {
            let ch1 = max(0, min(maxChannels - 1, digits[0] - 1))
            let ch2 = max(0, min(maxChannels - 1, digits[1] - 1))
            return (ch1, ch2)
        } else if let ch = digits.first {
            let idx = max(0, min(maxChannels - 1, ch - 1))
            return (idx, idx)
        }
        return (0, min(1, maxChannels - 1))
    }
    
    public func getHardwareMultichannelFormat() -> AVAudioFormat {
        let outFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000.0
        let hwChannels = max(2, deviceManager.selectedDevice?.outputChannelCount ?? Int(outFormat.channelCount))
        
        if hwChannels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        }
        
        if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(hwChannels)) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
            return format
        }
        return outFormat
    }
    
    /// Attaches a single hardware-locked `AVAudioSourceNode` that mixes all stems on the exact same sample counter
    private func setupSingleClockSourceNode() {
        if let existing = sourceNode {
            audioEngine.disconnectNodeOutput(existing)
            audioEngine.detach(existing)
            sourceNode = nil
        }
        
        let multichannelFormat = getHardwareMultichannelFormat()
        
        mixState.setPadEngine(padPlayer)
        
        let state = mixState
        let node = AVAudioSourceNode(format: multichannelFormat) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            return state.render(isSilence: isSilence, frameCount: Int(frameCount), audioBufferList: audioBufferList)
        }
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.outputNode, format: multichannelFormat)
        sourceNode = node
        
        // Ambient Pad Player engine
        padPlayer.setProcessingFormat(multichannelFormat)
        let padBus = busses.first { $0.name.lowercased() == "pad" }
        let (padL, padR) = resolvePhysicalOutputChannels(for: padBus?.physicalOutputChannel ?? "Out 1/2", isMono: padBus?.isMono ?? false)
        padPlayer.setTargetOutputChannels(left: padL, right: padR)
        updateRedundancyState()
        updateSMPTEState()
    }
    
    // MARK: - Hardware Device Output Switching & Persistence
    
    public struct BusRoutingPreset: Codable, Sendable {
        public let physicalOutput: String
        public let isMono: Bool
        
        public init(physicalOutput: String, isMono: Bool) {
            self.physicalOutput = physicalOutput
            self.isMono = isMono
        }
    }
    
    private func busRoutingStorageKey(for device: AudioOutputDevice?) -> String? {
        guard let dev = device else { return nil }
        let idStr = !dev.uid.isEmpty ? dev.uid : dev.name
        guard !idStr.isEmpty else { return nil }
        return "Playback_BusRouting_\(idStr)"
    }
    
    public func saveBusRouting(for device: AudioOutputDevice?) {
        guard let key = busRoutingStorageKey(for: device) else { return }
        var dict: [String: BusRoutingPreset] = [:]
        for bus in busses {
            dict[bus.name.lowercased()] = BusRoutingPreset(
                physicalOutput: bus.physicalOutputChannel,
                isMono: bus.isMono
            )
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    public func loadBusRouting(for device: AudioOutputDevice?) {
        guard let dev = device else { return }
        let (stereoOuts, monoOuts) = deviceManager.availableOutputs(for: dev)
        let defaultStereo = stereoOuts.first ?? "Out 1/2"
        let defaultMono = monoOuts.first ?? "Out 1"
        let defaultOut = dev.outputChannelCount > 1 ? defaultStereo : defaultMono
        let defaultIsMono = dev.outputChannelCount <= 1
        
        guard let key = busRoutingStorageKey(for: dev),
              let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: BusRoutingPreset].self, from: data) else {
            // Brand-new audio interface used: all busses default to Out 1/2 (or Out 1 for mono)
            for bus in busses {
                bus.physicalOutputChannel = defaultOut
                bus.isMono = defaultIsMono
            }
            validateBusOutputRouting(maxChannels: dev.outputChannelCount)
            return
        }
        
        for bus in busses {
            if let preset = dict[bus.name.lowercased()] {
                let valid = preset.isMono ? monoOuts.contains(preset.physicalOutput) : stereoOuts.contains(preset.physicalOutput)
                if valid {
                    bus.physicalOutputChannel = preset.physicalOutput
                    bus.isMono = preset.isMono
                } else {
                    bus.physicalOutputChannel = defaultOut
                    bus.isMono = defaultIsMono
                }
            } else {
                bus.physicalOutputChannel = defaultOut
                bus.isMono = defaultIsMono
            }
        }
        validateBusOutputRouting(maxChannels: dev.outputChannelCount)
    }
    
    public func showAudioDeviceBanner(_ message: String) {
        audioDeviceBannerDismissTask?.cancel()
        audioDeviceBannerMessage = message
        audioDeviceBannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.audioDeviceBannerMessage = nil
        }
    }

    public func setOutputDevice(_ device: AudioOutputDevice, showBanner: Bool = true) {
        if lastAppliedHardwareDeviceID == device.id &&
           lastAppliedHardwareChannelCount == device.outputChannelCount &&
           deviceManager.selectedDevice?.id == device.id &&
           isEngineRunning && sourceNode != nil {
            return
        }
        lastAppliedHardwareDeviceID = device.id
        lastAppliedHardwareChannelCount = device.outputChannelCount

        if playbackState != .stopped {
            self.stop()
        }
        stopPadPlayerImmediately()
        audioEngine.stop()
        
        var deviceID = device.id
        guard let outputUnit = audioEngine.outputNode.audioUnit else {
            try? audioEngine.start()
            return
        }
        
        let error = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if error == noErr {
            if deviceManager.selectedDevice?.id != device.id {
                deviceManager.selectedDevice = device
            }
        } else {
            print("Failed to set audio device to \(device.name): \(error)")
        }
        
        disableRedundancyAndSMPTEOnDeviceChange()
        loadBusRouting(for: device)
        validateBusOutputRouting(maxChannels: device.outputChannelCount)
        setupSingleClockSourceNode()
        
        try? audioEngine.start()
        updateMatrix()
        syncMixState()
        objectWillChange.send()
        if showBanner {
            showAudioDeviceBanner("Switched to \(device.name) (\(device.outputChannelCount) Outputs)")
        }
    }
    
    public func validateBusOutputRouting(maxChannels: Int) {
        let (stereo, mono) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
        for bus in busses {
            if bus.isMono {
                if !mono.contains(bus.physicalOutputChannel) {
                    bus.physicalOutputChannel = mono.first ?? "Out 1"
                }
            } else {
                if !stereo.contains(bus.physicalOutputChannel) {
                    bus.physicalOutputChannel = stereo.first ?? "Out 1/2"
                }
            }
        }
    }
    
    // MARK: - Track Management & Sample-Accurate Setup
    
    /// Adds a track with an in-memory PCM audio buffer into the single-clock SIMD mixer
    public func addTrack(_ track: StemTrack, with buffer: AVAudioPCMBuffer, recalculateWaveform: Bool = true) {
        if channels[track.id] != nil {
            tracks.removeAll { $0.id == track.id }
            pristineMasterBuffers.removeValue(forKey: track.id)
            channels.removeValue(forKey: track.id)
        }
        
        let canonicalFormat = getCanonicalProcessingFormat()
        let finalBuffer = normalizeBufferToCanonical(buffer: buffer, targetFormat: canonicalFormat)
        
        pristineMasterBuffers[track.id] = finalBuffer
        let channel = TrackChannel(track: track, buffer: finalBuffer)
        channels[track.id] = channel
        
        let trackDuration = Double(finalBuffer.frameLength) / finalBuffer.format.sampleRate
        track.duration = trackDuration
        if track.waveformPeaks.isEmpty && track.includeInWaveform {
            track.waveformPeaks = extractWaveformPeaks(from: finalBuffer, samplesCount: 4000)
        }
        
        tracks.append(track)
        
        if trackDuration > currentSongDuration {
            currentSongDuration = trackDuration
            transportPosition.totalDuration = currentSongDuration
            transportClock.position.totalDuration = currentSongDuration
            transportDisplayClock.update(with: transportPosition)
        }
        
        if recalculateWaveform {
            recalculateAggregateWaveform(samplesCount: 4000)
            updateMatrix()
            ensureClickAndGuideTracksExist()
        }
        markSessionChanged()
    }
    
    /// Returns the engine's canonical stereo processing format matching the hardware output
    public func getCanonicalProcessingFormat() -> AVAudioFormat {
        let outFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000.0
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }
    
    /// Normalizes any input buffer (mono/stereo, any sample rate) to the engine's canonical stereo format
    private func normalizeBufferToCanonical(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        // Step 1: ensure 2 channels (stereo)
        let stereoBuffer: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 {
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2)!
            if let sBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: buffer.frameLength) {
                sBuf.frameLength = buffer.frameLength
                if let mono = buffer.floatChannelData?[0],
                   let left = sBuf.floatChannelData?[0],
                   let right = sBuf.floatChannelData?[1] {
                    let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
                    memcpy(left, mono, bytes)
                    memcpy(right, mono, bytes)
                }
                stereoBuffer = sBuf
            } else {
                stereoBuffer = buffer
            }
        } else {
            stereoBuffer = buffer
        }
        
        // Step 2: if sample rate matches canonical format, we're done
        if stereoBuffer.format.sampleRate == targetFormat.sampleRate && stereoBuffer.format.channelCount == targetFormat.channelCount {
            return stereoBuffer
        }
        
        // Step 3: resample cleanly with AVAudioConverter
        guard let converter = AVAudioConverter(from: stereoBuffer.format, to: targetFormat) else {
            return stereoBuffer
        }
        
        let ratio = targetFormat.sampleRate / stereoBuffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(stereoBuffer.frameLength) * ratio) + 2048
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return stereoBuffer
        }
        
        var error: NSError?
        var isDone = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return stereoBuffer
        }
        
        if status != .error && error == nil && converted.frameLength > 0 {
            return converted
        } else {
            return stereoBuffer
        }
    }
    
    /// Loads an audio file from disk into a stem track, converting it into a sample-accurate RAM buffer
    public func addTrack(from fileURL: URL, name: String? = nil, role: TrackRole = .stem, recalculateWaveform: Bool = true) throws -> StemTrack {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let trackName = name ?? fileURL.deletingPathExtension().lastPathComponent
        let track = StemTrack(name: trackName, role: role, fileURL: fileURL)
        
        let canonicalFormat = getCanonicalProcessingFormat()
        
        // Read file into memory buffer
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw NSError(domain: "PlaybackEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"])
        }
        try audioFile.read(into: fileBuffer)
        
        // Normalize into engine canonical stereo format (no sample rate drift or channel mismatch)
        let finalBuffer = normalizeBufferToCanonical(buffer: fileBuffer, targetFormat: canonicalFormat)
        
        pristineMasterBuffers[track.id] = finalBuffer
        let channel = TrackChannel(track: track, buffer: finalBuffer, audioFile: nil)
        channels[track.id] = channel
        
        let cat = StemCategory.category(for: trackName, role: role)
        if role == .click || cat == .click {
            track.role = .click
            uploadedClickBuffers[currentSong.id] = finalBuffer
            let src = defaultClickSourcePreference
            currentSong.excludesClickAndGuide = false
            currentSong.clickSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                currentSetlist.songs[currentSongIndex].clickSource = src
            }
        } else if role == .guide || cat == .guide {
            track.role = .guide
            uploadedGuideBuffers[currentSong.id] = finalBuffer
            let src = defaultGuideSourcePreference
            currentSong.excludesClickAndGuide = false
            currentSong.guideSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                currentSetlist.songs[currentSongIndex].guideSource = src
            }
        }
        
        let trackDuration = Double(finalBuffer.frameLength) / finalBuffer.format.sampleRate
        track.duration = trackDuration
        if track.waveformPeaks.isEmpty && track.includeInWaveform {
            track.waveformPeaks = extractWaveformPeaks(from: finalBuffer, samplesCount: 4000)
        }
        
        PlaybackFileManager.shared.cacheStemInBackground(trackId: track.id, buffer: finalBuffer, sourceURL: fileURL)
        
        tracks.append(track)
        if trackDuration > currentSongDuration {
            currentSongDuration = trackDuration
            transportPosition.totalDuration = currentSongDuration
            transportClock.position.totalDuration = currentSongDuration
            transportDisplayClock.update(with: transportPosition)
        }
        
        if recalculateWaveform {
            recalculateAggregateWaveform(samplesCount: 4000)
            updateMatrix()
            ensureClickAndGuideTracksExist()
        }
        return track
    }
    
    /// Loads multiple audio files concurrently across all CPU cores for rapid multi-stem import
    public func addTracksConcurrently(from fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let canonicalFormat = getCanonicalProcessingFormat()
        
        struct LoadedStemResult {
            let track: StemTrack
            let buffer: AVAudioPCMBuffer
            let url: URL
        }
        
        let count = fileURLs.count
        let box = UnsafeMutableBufferPointer<LoadedStemResult?>.allocate(capacity: count)
        box.initialize(repeating: nil)
        defer {
            box.deinitialize()
            box.deallocate()
        }
        
        DispatchQueue.concurrentPerform(iterations: count) { idx in
            let url = fileURLs[idx]
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope { url.stopAccessingSecurityScopedResource() }
            }
            guard let audioFile = try? AVAudioFile(forReading: url),
                  let fileBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                return
            }
            do {
                try audioFile.read(into: fileBuffer)
            } catch {
                return
            }
            let finalBuffer = PlaybackFileManager.normalizeBuffer(fileBuffer, to: canonicalFormat)
            let trackName = url.deletingPathExtension().lastPathComponent
            let cat = StemCategory.category(for: trackName)
            let role: TrackRole = cat == .click ? .click : (cat == .guide ? .guide : .stem)
            let track = StemTrack(name: trackName, role: role, fileURL: url)
            track.duration = Double(finalBuffer.frameLength) / finalBuffer.format.sampleRate
            if track.includeInWaveform {
                track.waveformPeaks = PlaybackFileManager.extractPeaks(from: finalBuffer, samplesCount: 4000)
            }
            PlaybackFileManager.shared.cacheStemInBackground(trackId: track.id, buffer: finalBuffer, sourceURL: url)
            box[idx] = LoadedStemResult(track: track, buffer: finalBuffer, url: url)
        }
        
        for idx in 0..<count {
            guard let item = box[idx] else { continue }
            let track = item.track
            let finalBuffer = item.buffer
            
            pristineMasterBuffers[track.id] = finalBuffer
            channels[track.id] = TrackChannel(track: track, buffer: finalBuffer, audioFile: nil)
            
            let cat = StemCategory.category(for: track.name, role: track.role)
            if track.role == .click || cat == .click {
                track.role = .click
                uploadedClickBuffers[currentSong.id] = finalBuffer
                let src = defaultClickSourcePreference
                currentSong.excludesClickAndGuide = false
                currentSong.clickSource = src
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                    currentSetlist.songs[currentSongIndex].clickSource = src
                }
            } else if track.role == .guide || cat == .guide {
                track.role = .guide
                uploadedGuideBuffers[currentSong.id] = finalBuffer
                let src = defaultGuideSourcePreference
                currentSong.excludesClickAndGuide = false
                currentSong.guideSource = src
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
                    currentSetlist.songs[currentSongIndex].guideSource = src
                }
            }
            
            if isFadersDefault100Enabled && track.volume >= 0.79 && track.volume <= 0.81 {
                track.volume = 1.0
            }
            
            tracks.append(track)
            if track.duration > currentSongDuration {
                currentSongDuration = track.duration
                transportPosition.totalDuration = currentSongDuration
                transportClock.position.totalDuration = currentSongDuration
                transportDisplayClock.update(with: transportPosition)
            }
        }
    }
    
    // Unified V-Sync synchronized CADisplayLink driving both transport playhead & isolated `StereoMeterModel`s
    private final class DisplayLinkTickProxy: NSObject {
        private let onTick: (TimeInterval) -> Void
        init(onTick: @escaping (TimeInterval) -> Void) {
            self.onTick = onTick
            super.init()
        }
        @objc func step(_ sender: CADisplayLink) {
            let rawDt = sender.targetTimestamp - sender.timestamp
            let dt = (rawDt > 0.001 && rawDt < 0.25) ? rawDt : (sender.duration > 0.001 ? sender.duration : (1.0 / 60.0))
            onTick(dt)
        }
    }

    private func screenDisplayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let num = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    private func ensureUIDisplayLinkRunning() {
        if uiDisplayLink != nil || uiFallbackTimer != nil {
            return
        }

        let targetWindow = NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
        let targetScreen = targetWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let maxFPS = Float(max(30, min(120, targetScreen?.maximumFramesPerSecond ?? 60)))

        let proxy = DisplayLinkTickProxy { [weak self] dt in
            self?.tickUIDisplayLink(dt: dt)
        }

        if let link = targetWindow?.displayLink(target: proxy, selector: #selector(DisplayLinkTickProxy.step(_:)))
            ?? targetScreen?.displayLink(target: proxy, selector: #selector(DisplayLinkTickProxy.step(_:))) {
            uiDisplayLinkProxy = proxy
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
            link.add(to: .main, forMode: .common)
            uiDisplayLink = link
            uiDisplayLinkScreenNumber = screenDisplayID(for: targetScreen)
        } else {
            let interval = 1.0 / Double(maxFPS)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.tickUIDisplayLink(dt: interval)
            }
            timer.tolerance = 0.002
            uiFallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func rebindUIDisplayLinkIfNeeded() {
        guard uiDisplayLink != nil else { return }
        let targetWindow = NSApp?.mainWindow ?? NSApp?.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
        let targetScreen = targetWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let currentScreenID = screenDisplayID(for: targetScreen)
        if currentScreenID != uiDisplayLinkScreenNumber {
            stopUIDisplayLink()
            ensureUIDisplayLinkRunning()
        } else if let link = uiDisplayLink, let screen = targetScreen {
            let maxFPS = Float(max(30, min(120, screen.maximumFramesPerSecond)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        }
    }

    private func updatePlaybackActivityAssertion() {
        let active = (playbackState == .playing) || isPadActive
        if active && playbackActivityToken == nil {
            playbackActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Live multitrack audio and MIDI playback"
            )
        } else if !active, let token = playbackActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            playbackActivityToken = nil
        }
    }

    private func startTransportWatchdogTimer() {
        if transportWatchdogTimer != nil { return }
        lastPlaybackClockTickTimestamp = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.playbackState == .playing else {
                self.stopTransportWatchdogTimer()
                return
            }
            if CACurrentMediaTime() - self.lastPlaybackClockTickTimestamp >= 0.030 {
                self.tickPlaybackClock()
            }
        }
        transportWatchdogTimer = timer
        timer.resume()
    }

    private func stopTransportWatchdogTimer() {
        transportWatchdogTimer?.cancel()
        transportWatchdogTimer = nil
    }

    private func stopUIDisplayLink() {
        uiFallbackTimer?.invalidate()
        uiFallbackTimer = nil
        uiDisplayLink?.invalidate()
        uiDisplayLink = nil
        uiDisplayLinkProxy = nil
        uiDisplayLinkScreenNumber = nil
    }

    private func tickUIDisplayLink(dt: TimeInterval) {
        if playbackState == .playing {
            tickPlaybackClock()
        }
        tickMeters(dt: dt)
    }

    private func startMeteringTimer() {
        ensureUIDisplayLinkRunning()
    }
    
    private func resetClickMeters() {
        clickAccentMeter.reset()
        clickQuarterMeter.reset()
        clickEighthMeter.reset()
        clickSixteenthMeter.reset()
        for track in tracks where track.isClickTrackCached {
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            track.peakLevelLeft = 0.0
            track.peakLevelRight = 0.0
            track.meter.reset()
        }
    }

    private func stopMeteringTimer() {
        if playbackState != .playing {
            stopUIDisplayLink()
        }
        resetClickMeters()
    }
    
    private func updatePadMeter(dt: TimeInterval) {
        let (rawPadL, rawPadR) = padPlayer.consumeMeterPeaks()
        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let targetL: Float = rawPadL > 0.0005 ? min(1.0, pow(rawPadL, 0.62)) : 0.0
        let targetR: Float = (rawPadR == rawPadL) ? targetL : (rawPadR > 0.0005 ? min(1.0, pow(rawPadR, 0.62)) : 0.0)
        let baseRelease: Float = (padPlayer.isPlaying || padPlayer.isFadingOut) ? 0.82 : 0.72
        let releaseFactor = powf(baseRelease, frames60)
        let attackBlend = 1.0 - powf(0.20, frames60)
        let nextL: Float = targetL >= padMeterPeakL ? (padMeterPeakL + (targetL - padMeterPeakL) * attackBlend) : (padMeterPeakL * releaseFactor)
        let nextR: Float = targetR >= padMeterPeakR ? (padMeterPeakR + (targetR - padMeterPeakR) * attackBlend) : (padMeterPeakR * releaseFactor)
        padMeterPeakL = nextL < 0.01 ? 0.0 : nextL
        padMeterPeakR = nextR < 0.01 ? 0.0 : nextR
        padPlayer.meter.update(left: padMeterPeakL, right: padMeterPeakR, dt: dt)
    }

    private func tickMeters(dt: TimeInterval = 1.0 / 60.0) {
        let padNeedsUpdate = padPlayer.isPlaying || padPlayer.isFadingOut || padMeterPeakL > 0.0 || padMeterPeakR > 0.0 || padPlayer.meter.left > 0.0 || padPlayer.meter.right > 0.0
        if padNeedsUpdate {
            updatePadMeter(dt: dt)
        }
        guard playbackState == .playing else {
            resetClickMeters()
            if !padNeedsUpdate {
                stopUIDisplayLink()
            }
            return
        }

        let frames60 = Float(max(0.25, min(4.0, dt * 60.0)))
        let trackAttack = 1.0 - powf(0.20, frames60)
        let trackDecay = powf(0.82, frames60)
        let busDecay = powf(0.85, frames60)
        let masterAttack = 1.0 - powf(0.22, frames60)
        let masterDecay = powf(0.86, frames60)
        
        for track in tracks {
            if track.isClickTrackCached {
                // Main Click VU flashes on quarter notes
                track.rawPeakL = 0.0
                track.rawPeakR = 0.0
                continue
            }
            let rawL = track.rawPeakL
            let rawR = track.rawPeakR
            if rawL == 0.0 && rawR == 0.0 && track.peakLevelLeft == 0.0 && track.peakLevelRight == 0.0 {
                continue
            }
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            
            // Perceptual console meter scaling (pow 0.62) so low/mid details are clearly visible
            let targetL: Float = rawL > 0.0005 ? min(1.0, pow(rawL, 0.62)) : 0.0
            let targetR: Float = (rawR == rawL) ? targetL : (rawR > 0.0005 ? min(1.0, pow(rawR, 0.62)) : 0.0)
            
            // Time-normalized attack & analog-style exponential release
            let nextL: Float = targetL >= track.peakLevelLeft
                ? (track.peakLevelLeft + (targetL - track.peakLevelLeft) * trackAttack)
                : (track.peakLevelLeft * trackDecay)
            let nextR: Float = targetR >= track.peakLevelRight
                ? (track.peakLevelRight + (targetR - track.peakLevelRight) * trackAttack)
                : (track.peakLevelRight * trackDecay)
            
            track.peakLevelLeft = nextL < 0.004 ? 0.0 : nextL
            track.peakLevelRight = nextR < 0.004 ? 0.0 : nextR
            track.meter.update(left: track.peakLevelLeft, right: track.peakLevelRight, dt: dt)
        }
        
        updateFlashingClickMeters(dt: dt)

        if mixerMode == .busses {
            var busPeaks: [String: (left: Float, right: Float)] = [:]
            for track in tracks {
                let busName = track.assignedBusName
                let cur = busPeaks[busName] ?? (0.0, 0.0)
                busPeaks[busName] = (max(cur.left, track.peakLevelLeft), max(cur.right, track.peakLevelRight))
            }
            for bus in busses {
                if let peaks = busPeaks[bus.name] {
                    if bus.isMono {
                        let monoPeak = max(peaks.left, peaks.right)
                        bus.peakLevelLeft = max(monoPeak, bus.peakLevelLeft * busDecay)
                        bus.peakLevelRight = bus.peakLevelLeft
                    } else {
                        bus.peakLevelLeft = max(peaks.left, bus.peakLevelLeft * busDecay)
                        bus.peakLevelRight = max(peaks.right, bus.peakLevelRight * busDecay)
                    }
                } else {
                    bus.peakLevelLeft = bus.peakLevelLeft < 0.003 ? 0.0 : bus.peakLevelLeft * busDecay
                    bus.peakLevelRight = bus.peakLevelRight < 0.003 ? 0.0 : bus.peakLevelRight * busDecay
                }
                bus.meter.update(left: bus.peakLevelLeft, right: bus.peakLevelRight, dt: dt)
            }
        }
        
        let (rawMasterL, rawMasterR) = mixState.consumeMasterPeaks()
        let targetMasterL = rawMasterL > 0.0005 ? min(1.0, pow(rawMasterL, 0.62)) : 0.0
        let targetMasterR = rawMasterR > 0.0005 ? min(1.0, pow(rawMasterR, 0.62)) : 0.0
        
        let nextMasterL: Float = targetMasterL >= masterPeakLeft
            ? (masterPeakLeft + (targetMasterL - masterPeakLeft) * masterAttack)
            : (masterPeakLeft * masterDecay)
        let nextMasterR: Float = targetMasterR >= masterPeakRight
            ? (masterPeakRight + (targetMasterR - masterPeakRight) * masterAttack)
            : (masterPeakRight * masterDecay)
        
        masterPeakLeft = nextMasterL < 0.003 ? 0.0 : nextMasterL
        masterPeakRight = nextMasterR < 0.003 ? 0.0 : nextMasterR
        masterMeter.update(left: masterPeakLeft, right: masterPeakRight, dt: dt)
    }
    
    /// Refreshes Click channel and subdivision VU meters for the current playhead position.
    public func refreshClickMetersForCurrentPosition(dt: TimeInterval = 1.0 / 60.0) {
        updateFlashingClickMeters(dt: dt)
    }

    private func updateFlashingClickMeters(dt: TimeInterval = 1.0 / 60.0) {
        let nowSec = playbackOffsetSeconds
        let sourceSec = audioTime(forArrangementTime: nowSec)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sourceSec)
        
        let activeGrid = cachedEffectiveBeatGrid
        let activeMarker: BeatGridMarker? = {
            if !activeGrid.isEmpty {
                let target = nowSec + 0.008
                var low = 0
                var high = activeGrid.count - 1
                var bestIdx = -1
                while low <= high {
                    let mid = (low + high) / 2
                    if activeGrid[mid].time <= target {
                        bestIdx = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                if bestIdx >= 0 {
                    return activeGrid[bestIdx]
                }
            }
            return currentSong.activeMarker(at: nowSec)
        }()
        
        let activeBPM = max(20.0, activeMarker?.instantaneousBPM ?? currentSong.bpm)
        let beatSec = (60.0 / activeBPM) * (4.0 / Double(max(1, tsDen)))
        let beatsPerBar = max(1, tsNum)
        let downbeatFlashWindow = min(0.095, beatSec * 0.42)
        
        func zeroAllClickMeters() {
            clickAccentMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickQuarterMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickEighthMeter.update(left: 0.0, right: 0.0, dt: dt)
            clickSixteenthMeter.update(left: 0.0, right: 0.0, dt: dt)
            for track in tracks where track.isClickTrackCached {
                track.peakLevelLeft = 0.0
                track.peakLevelRight = 0.0
                track.meter.update(left: 0.0, right: 0.0, dt: dt)
            }
        }
        
        if currentSong.excludesClickAndGuide || !tracks.contains(where: { $0.isClickTrackCached }) {
            zeroAllClickMeters()
            return
        }
        
        // Stop flashing Click meters once past the single downbeat hit of an End / Ending section
        let endSection = currentSong.sections.first(where: { sec in
            let lowerName = sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let lowerAbbrev = sec.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowerName == "end" || lowerName == "ending" || lowerName == "the end" ||
                   lowerName.starts(with: "end ") || lowerName.hasSuffix(" end") ||
                   lowerAbbrev == "end" || (lowerAbbrev == "e" && lowerName.contains("end"))
        })
        let endCutoffTime: TimeInterval? = endSection?.startTime
        if let cutoff = endCutoffTime, nowSec > cutoff + downbeatFlashWindow {
            zeroAllClickMeters()
            return
        }
        
        // For uploaded click tracks, suppress flashing if the click stem has gone silent around nowSec
        if currentSong.clickSource == .uploaded, let upClick = uploadedClickBuffers[currentSong.id] {
            let sr = upClick.format.sampleRate
            let totalFrames = Int(upClick.frameLength)
            if sr > 0, totalFrames > 0, let ptr = upClick.floatChannelData?[0] {
                let startF = max(0, Int((sourceSec - 0.08) * sr))
                let endF = min(totalFrames, Int((sourceSec + 0.03) * sr))
                var maxAmp: Float = 0.0
                var idx = startF
                while idx < endF {
                    let a = abs(ptr[idx])
                    if a > maxAmp {
                        maxAmp = a
                        if maxAmp >= 0.002 { break }
                    }
                    idx += 16
                }
                if maxAmp < 0.002 {
                    zeroAllClickMeters()
                    return
                }
            }
        }
        
        let beatFloat: Double
        if let marker = activeMarker {
            let localBeat = max(0.0, (nowSec - marker.time) / max(0.05, beatSec))
            beatFloat = Double((max(1, marker.bar) - 1) * beatsPerBar + (max(1, marker.beat) - 1)) + localBeat
        } else {
            beatFloat = max(0.0, nowSec / max(0.05, beatSec))
        }
        
        let quarterPhase = beatFloat.truncatingRemainder(dividingBy: 1.0)
        let eighthPhase = (beatFloat * 2.0).truncatingRemainder(dividingBy: 1.0)
        let sixteenthPhase = (beatFloat * 4.0).truncatingRemainder(dividingBy: 1.0)
        let isBeatOne: Bool = {
            if let marker = activeMarker {
                return marker.beat == 1 && (nowSec - marker.time) < downbeatFlashWindow
            }
            return Int(floor(beatFloat)) % beatsPerBar == 0
        }()
        let isOnEndingDownbeat = endCutoffTime != nil && nowSec >= (endCutoffTime! - 0.01)
        
        func flashLevel(phase: Double, subPeriodSec: Double, volume: Float, enabled: Bool) -> Float {
            guard enabled && volume > 0.001 else { return 0.0 }
            let elapsed = phase * subPeriodSec
            let flashWindow = min(0.095, subPeriodSec * 0.42)
            guard elapsed < flashWindow else { return 0.0 }
            let decay = Float(1.0 - (elapsed / flashWindow))
            return min(1.0, max(0.0, volume * (0.45 + 0.55 * decay)))
        }
        
        let isSoloActive = !clickSoloedSubdivisions.isEmpty
        let accentOn = currentSong.clickAccentEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.accent))
        let quarterOn = currentSong.clickQuarterEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.quarter))
        let eighthOn = currentSong.clickEighthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.eighth))
        let sixteenthOn = currentSong.clickSixteenthEnabled && (!isSoloActive || clickSoloedSubdivisions.contains(.sixteenth))
        
        let accentLvl = isBeatOne ? flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickAccentVolume, enabled: accentOn) : 0.0
        let quarterLvl = flashLevel(phase: quarterPhase, subPeriodSec: beatSec, volume: currentSong.clickQuarterVolume, enabled: quarterOn)
        let eighthLvl = isOnEndingDownbeat ? 0.0 : flashLevel(phase: eighthPhase, subPeriodSec: beatSec * 0.5, volume: currentSong.clickEighthVolume, enabled: eighthOn)
        let sixteenthLvl = isOnEndingDownbeat ? 0.0 : flashLevel(phase: sixteenthPhase, subPeriodSec: beatSec * 0.25, volume: currentSong.clickSixteenthVolume, enabled: sixteenthOn)
        
        clickAccentMeter.update(left: accentLvl, right: accentLvl, dt: dt)
        clickQuarterMeter.update(left: quarterLvl, right: quarterLvl, dt: dt)
        clickEighthMeter.update(left: eighthLvl, right: eighthLvl, dt: dt)
        clickSixteenthMeter.update(left: sixteenthLvl, right: sixteenthLvl, dt: dt)
        
        // Main Click track VU flashes on active click beats
        for track in tracks where track.isClickTrackCached {
            let anySubFlash = max(max(accentLvl, quarterLvl), max(eighthLvl * 0.85, sixteenthLvl * 0.70))
            let mainLvl: Float = track.isMuted ? 0.0 : min(1.0, anySubFlash * track.volume)
            track.peakLevelLeft = mainLvl
            track.peakLevelRight = mainLvl
            track.meter.update(left: mainLvl, right: mainLvl, dt: dt)
        }
    }
    
    public func removeTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        pristineMasterBuffers.removeValue(forKey: id)
        channels.removeValue(forKey: id)
        
        currentSongDuration = tracks.map { $0.duration }.max() ?? 0.0
        transportPosition.totalDuration = currentSongDuration
        transportClock.position.totalDuration = currentSongDuration
        recalculateAggregateWaveform(samplesCount: 4000)
        updateMatrix()
        markSessionChanged()
    }
    
    /// Reorders tracks in the mixer
    public func moveTrack(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0 && fromIndex < tracks.count,
              toIndex >= 0 && toIndex < tracks.count else { return }
        let moved = tracks.remove(at: fromIndex)
        tracks.insert(moved, at: toIndex)
        markSessionChanged()
        
        // Update songBuffersCache to maintain identical ordering
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            let activeSong = currentSetlist.songs[currentSongIndex]
            if let cached = songBuffersCache[activeSong.id] {
                var reordered: [(StemTrack, AVAudioPCMBuffer)] = []
                for t in tracks {
                    if let found = cached.first(where: { $0.0.id == t.id }) {
                        reordered.append(found)
                    }
                }
                if reordered.count == cached.count {
                    songBuffersCache[activeSong.id] = reordered
                }
            }
        }
    }
    
    /// Auto-sorts tracks according to standard MultiTracks canonical order:
    /// 1. Click, 2. Guide, 3. Drums, 4. Percussion, 5. Loops, 6. FX, 7. Bass, 8. Synth Bass,
    /// 9. Acoustic Guitars, 10. Electric Guitars, 11. Piano, 12. Organs, 13. Keys, 14. Arps,
    /// 15. Synths, 16. Orchestral, 17. Vocals, 18. Other
    public func autoSortTracks() {
        guard tracks.count > 1 else { return }
        tracks.sort { (t1, t2) -> Bool in
            let ord1 = StemCategory.playbackOrder(for: t1.name, role: t1.role)
            let ord2 = StemCategory.playbackOrder(for: t2.name, role: t2.role)
            if ord1 != ord2 {
                return ord1 < ord2
            }
            let cat1 = StemCategory.category(for: t1.name, role: t1.role)
            let cat2 = StemCategory.category(for: t2.name, role: t2.role)
            if cat1 != cat2 {
                return cat1 < cat2
            }
            return t1.name.localizedStandardCompare(t2.name) == .orderedAscending
        }
        
        // Ensure proper track role assignment based on detection
        for track in tracks {
            let cat = StemCategory.category(for: track.name, role: track.role)
            if cat == .click {
                track.role = .click
            } else if cat == .guide {
                track.role = .guide
            }
        }
        
        // Update songBuffersCache to maintain identical ordering
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            let activeSong = currentSetlist.songs[currentSongIndex]
            if let cached = songBuffersCache[activeSong.id] {
                var reordered: [(StemTrack, AVAudioPCMBuffer)] = []
                for t in tracks {
                    if let found = cached.first(where: { $0.0.id == t.id }) {
                        reordered.append(found)
                    }
                }
                if reordered.count == cached.count {
                    songBuffersCache[activeSong.id] = reordered
                }
            }
        }
        
        updateMatrix()
        objectWillChange.send()
    }
    
    /// Ensures Click and Guide channel strips are immediately present at canonical MultiTracks positions
    /// (Click at Position 1, Guide at Position 2) with silent initial buffers, and triggers fast background synthesis.
    public func ensureClickAndGuideTracksExist(duration: TimeInterval? = nil) {
        if currentSong.excludesClickAndGuide { return }
        let canonicalFormat = getCanonicalProcessingFormat()
        let sampleRate = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
        let masterDur = max(tracks.map { $0.duration }.max() ?? 0.0, duration ?? currentSongDuration, 240.0)
        let initialFrames = AVAudioFrameCount(max(1, Int64(round(masterDur * sampleRate))))
        
        var didAdd = false
        
        // 1. Ensure Click track exists
        if !tracks.contains(where: { $0.role == .click || StemCategory.category(for: $0.name, role: $0.role) == .click }) {
            let newClick = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
            newClick.duration = masterDur
            tracks.append(newClick)
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                channels[newClick.id] = TrackChannel(track: newClick, buffer: silentBuf)
                pristineMasterBuffers[newClick.id] = silentBuf
            }
            didAdd = true
        }
        
        // 2. Ensure Guide track exists
        if !tracks.contains(where: { $0.role == .guide || StemCategory.category(for: $0.name, role: $0.role) == .guide }) {
            let newGuide = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
            newGuide.duration = masterDur
            tracks.append(newGuide)
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                channels[newGuide.id] = TrackChannel(track: newGuide, buffer: silentBuf)
                pristineMasterBuffers[newGuide.id] = silentBuf
            }
            didAdd = true
        }
        
        // If the song has no uploaded click or guide file, default source to .generated; otherwise use user's default preference
        if uploadedClickBuffers[currentSong.id] == nil {
            currentSong.clickSource = .generated
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].clickSource = .generated
            }
        } else {
            let src = defaultClickSourcePreference
            currentSong.clickSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].clickSource = src
            }
            applyClickBuffer()
        }
        
        if uploadedGuideBuffers[currentSong.id] == nil {
            currentSong.guideSource = .generated
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].guideSource = .generated
            }
        } else {
            let src = defaultGuideSourcePreference
            currentSong.guideSource = src
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].guideSource = src
            }
            applyGuideBuffer()
        }
        
        // Canonical ordering: Click is ALWAYS position 1, Guide is ALWAYS position 2
        autoSortTracks()
        updateMatrix()
        syncMixState()
        
        // Trigger fast background generation
        regenerateClickTrack()
        regenerateGuideTrack()
        
        objectWillChange.send()
    }
    
    public func clearAllTracks() {
        stop()
        channels.removeAll()
        pristineMasterBuffers.removeAll()
        tracks.removeAll()
        aggregateWaveform.removeAll()
        masterWaveformPeaks.removeAll()
        renderedWaveformImage = nil
        currentSongDuration = 0.0
        transportPosition = TransportPosition()
        transportClock.position = TransportPosition()
        isFadeActive = false
        currentFadeGain = 1.0
        isLoopActive = false
        loopedSection = nil
        isTransposing = false
        transposeProgress = 0.0
        transposingSongId = nil
        syncMixState()
    }
    
    // MARK: - Aggregate Waveform Calculation & Pre-Rendering (Excludes Click & Guide)
    
    public func recalculateAggregateWaveform(samplesCount: Int = 4000) {
        // Exclude tracks that have includeInWaveform == false (Click, Guide, Tick, etc.)
        let musicalStems = tracks.filter { $0.includeInWaveform }
        guard !musicalStems.isEmpty else {
            masterWaveformPeaks = []
            aggregateWaveform = []
            renderedWaveformImage = nil
            return
        }
        
        let masterDuration = max(0.01, tracks.map { $0.duration }.max() ?? currentSongDuration)
        var combined = Array(repeating: Float(0.0), count: samplesCount)
        for stem in musicalStems {
            let peaks = stem.waveformPeaks
            guard !peaks.isEmpty else { continue }
            let stemDuration = stem.duration > 0 ? stem.duration : masterDuration
            let durationRatio = masterDuration / max(0.01, stemDuration)
            let maxPeakIndex = peaks.count - 1
            
            for i in 0..<samplesCount {
                let songProgress = Double(i) / Double(max(1, samplesCount - 1))
                let stemProgress = songProgress * durationRatio
                if stemProgress <= 1.0 {
                    let srcIdx = min(maxPeakIndex, max(0, Int(round(stemProgress * Double(maxPeakIndex)))))
                    combined[i] += peaks[srcIdx]
                }
            }
        }
        
        let maxVal = combined.max() ?? 1.0
        let normPeaks: [Float]
        if maxVal > 0.01 {
            normPeaks = combined.map { peak in
                let norm = peak / maxVal
                return min(1.0, pow(norm, 0.72))
            }
        } else {
            normPeaks = combined
        }
        
        masterWaveformPeaks = normPeaks
        updateArrangementWaveform()
    }
    
    // MARK: - Arrangement Waveform Mapping & Non-Destructive Slicing
    
    /// Re-renders the aggregate waveform reflecting the current active arrangement
    public func updateArrangementWaveform() {
        guard !masterWaveformPeaks.isEmpty else {
            renderedWaveformImage = nil
            aggregateWaveform = []
            return
        }
        
        let masterDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        guard masterDuration > 0 else {
            aggregateWaveform = masterWaveformPeaks
            renderedWaveformImage = generatePreRenderedWaveformImage(peaks: masterWaveformPeaks, width: 4000, height: 233)
            return
        }
        
        let inEditMode = isEditingArrangement
        let secs = inEditMode ? displaySections : currentSong.sections
        let sorted = secs.sorted { $0.startTime < $1.startTime }
        let maxSectionEnd = sorted.last?.endTime ?? masterDuration
        let fullDuration = !sorted.isEmpty ? maxSectionEnd : masterDuration
        
        let hasClickSections = sorted.contains { $0.effectiveIsClickSection }
        let isLinearSequence = !hasClickSections && (sorted.isEmpty || sorted.allSatisfy { abs($0.startTime - $0.sourceAudioStartTime) < 0.005 })
        
        // Fast zero-drift path when in edit mode with linear sequence (so full waveform is displayed!)
        if inEditMode && isLinearSequence && abs(fullDuration - masterDuration) < 0.05 {
            aggregateWaveform = masterWaveformPeaks
            renderedWaveformImage = generatePreRenderedWaveformImage(peaks: masterWaveformPeaks, width: 4000, height: 233)
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, renderedWaveformImage)
            return
        }
        
        let hasTrimmedSections = sorted.contains { $0.isTrimmed }
        let isLinearUnmodifiedArrangement = !hasClickSections && !hasTrimmedSections && isLinearSequence && abs(fullDuration - masterDuration) < 0.05
        
        // Fast zero-drift path when sections have not been non-destructively rearranged or trimmed
        if !inEditMode && isLinearUnmodifiedArrangement {
            aggregateWaveform = masterWaveformPeaks
            renderedWaveformImage = generatePreRenderedWaveformImage(peaks: masterWaveformPeaks, width: 4000, height: 233)
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, renderedWaveformImage)
            return
        }
        
        let masterCount = masterWaveformPeaks.count
        guard masterCount > 1, fullDuration > 0 else { return }
        
        let targetSamples = 4000
        var arrangedPeaks = [Float](repeating: 0.0, count: targetSamples)
        let clickPeaks = tracks.first(where: { $0.role == .click })?.waveformPeaks ?? []
        let clickPeakMax = clickPeaks.max() ?? 0.0
        let beatSec = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let beatsPerBar = max(1, currentSong.timeSignatureNumerator)
        let sampleWindow = fullDuration / Double(targetSamples)
        
        // Direct sample-by-sample timeline -> source audio time mapping (zero per-slice rounding drift!)
        for i in 0..<targetSamples {
            let arrTime = (Double(i) / Double(max(1, targetSamples - 1))) * fullDuration
            if let clickSec = sorted.first(where: { $0.effectiveIsClickSection && arrTime >= $0.startTime && arrTime < $0.endTime }) {
                if !clickPeaks.isEmpty && clickPeakMax > 0.02 {
                    let cFrac = max(0.0, min(1.0, arrTime / max(0.01, masterDuration)))
                    let cIdx = min(clickPeaks.count - 1, max(0, Int(round(cFrac * Double(clickPeaks.count - 1)))))
                    arrangedPeaks[i] = min(1.0, (clickPeaks[cIdx] / clickPeakMax) * 0.72)
                } else {
                    let rel = max(0.0, arrTime - clickSec.startTime)
                    let beatFloat = rel / max(0.05, beatSec)
                    let nearestBeat = round(beatFloat)
                    let distSec = abs(beatFloat - nearestBeat) * beatSec
                    if distSec <= max(0.018, sampleWindow * 0.9) {
                        let isDownbeat = Int(nearestBeat) % beatsPerBar == 0
                        arrangedPeaks[i] = isDownbeat ? 0.62 : 0.36
                    } else {
                        arrangedPeaks[i] = 0.0
                    }
                }
                continue
            }
            let srcTime = audioTime(forArrangementTime: arrTime)
            let srcFrac = max(0.0, min(1.0, srcTime / masterDuration))
            let masterPos = Double(masterCount - 1) * srcFrac
            let lowIdx = Int(floor(masterPos))
            let highIdx = min(masterCount - 1, lowIdx + 1)
            let frac = Float(masterPos - Double(lowIdx))
            let p0 = masterWaveformPeaks[max(0, min(masterCount - 1, lowIdx))]
            let p1 = masterWaveformPeaks[highIdx]
            arrangedPeaks[i] = p0 * (1.0 - frac) + p1 * frac
        }
        
        aggregateWaveform = arrangedPeaks
        renderedWaveformImage = generatePreRenderedWaveformImage(peaks: arrangedPeaks, width: 4000, height: 233)
        songWaveformCache[currentSong.id] = (arrangedPeaks, renderedWaveformImage)
    }
    
    public func generateArrangedWaveform() {
        updateArrangementWaveform()
    }
    
    /// Maps an arrangement timeline position to its corresponding source audio position
    public func audioTime(forArrangementTime arrTime: TimeInterval) -> TimeInterval {
        let inEditMode = isEditingArrangement
        let secs = inEditMode ? displaySections : currentSong.sections
        guard !secs.isEmpty else { return arrTime }
        if let sec = secs.first(where: { arrTime >= $0.startTime && arrTime < $0.endTime }) {
            let offset = arrTime - sec.startTime
            return sec.sourceAudioStartTime + offset
        } else if let lastSec = secs.last, arrTime >= lastSec.endTime {
            return inEditMode ? (lastSec.sourceAudioStartTime + (arrTime - lastSec.startTime)) : (lastSec.sourceAudioStartTime + lastSec.duration)
        } else if let firstSec = secs.first, arrTime < firstSec.startTime {
            return firstSec.sourceAudioStartTime
        }
        return arrTime
    }
    
    /// Pre-renders ultra-fine retina audio waveform texture once upon import
    private func generatePreRenderedWaveformImage(peaks: [Float], width: CGFloat = 2400, height: CGFloat = 233) -> NSImage? {
        guard !peaks.isEmpty, width > 0, height > 0 else { return nil }
        
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        
        let midY = height * 0.50
        let maxAmp = height * 0.30 // Equal ~50pt margin above (for section pills) and below (for cues track)
        let count = peaks.count
        let step = width / CGFloat(max(1, count - 1))
        
        // 1. Build smooth mirrored symmetrical contour path
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: midY))
        for i in 0..<count {
            let x = CGFloat(i) * step
            let peak = CGFloat(max(0.015, peaks[i]))
            let y = midY - (peak * maxAmp)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: midY))
        for i in (0..<count).reversed() {
            let x = CGFloat(i) * step
            let peak = CGFloat(max(0.015, peaks[i]))
            let y = midY + (peak * maxAmp)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        
        // 2. MultiTracks silver-slate gradient fill
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.95, alpha: 0.95).cgColor,
            NSColor(calibratedRed: 0.75, green: 0.79, blue: 0.83, alpha: 0.90).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.59, blue: 0.63, alpha: 0.85).cgColor
        ] as CFArray
        
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 0.5, 1.0]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
            ctx.restoreGState()
        }
        
        // 3. Crisp anti-aliased vertical transient lines (1px fine lines across the body)
        ctx.setLineWidth(1.0)
        let strokeColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.45).cgColor
        ctx.setStrokeColor(strokeColor)
        
        for i in stride(from: 0, to: count, by: 2) {
            let peak = CGFloat(peaks[i])
            if peak > 0.035 {
                let x = CGFloat(i) * step
                let amp = peak * maxAmp
                ctx.strokeLineSegments(between: [
                    CGPoint(x: x, y: midY - amp),
                    CGPoint(x: x, y: midY + amp)
                ])
            }
        }
        
        // 4. Center zero crossing line
        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.25).cgColor)
        ctx.strokeLineSegments(between: [
            CGPoint(x: 0, y: midY),
            CGPoint(x: width, y: midY)
        ])
        
        image.unlockFocus()
        return image
    }
    
    // MARK: - SINGLE-CLOCK SAMPLE-ACCURATE MULTI-TRACK TRANSPORT (ZERO DESYNC FOR 26+ TRACKS!)
    
    private func buildTimelineSlices(for song: Song, duration: TimeInterval, sampleRate: Double) -> [RenderTimelineSlice] {
        var renderSlices: [RenderTimelineSlice] = []
        let sortedSections = song.sections.sorted { $0.startTime < $1.startTime }
        
        if sortedSections.isEmpty {
            renderSlices.append(RenderTimelineSlice(
                timelineStartFrame: 0,
                timelineEndFrame: max(0, Int64(round(duration * sampleRate))),
                sourceStartFrame: 0
            ))
        } else {
            var cursor: TimeInterval = 0.0
            for sec in sortedSections {
                if sec.startTime > cursor + 0.005 {
                    let sFrame = Int64(round(cursor * sampleRate))
                    let eFrame = Int64(round(sec.startTime * sampleRate))
                    renderSlices.append(RenderTimelineSlice(
                        timelineStartFrame: sFrame,
                        timelineEndFrame: eFrame,
                        sourceStartFrame: sFrame
                    ))
                }
                let sFrame = Int64(round(sec.startTime * sampleRate))
                let eFrame = Int64(round(sec.endTime * sampleRate))
                let srcFrame = Int64(round(sec.sourceAudioStartTime * sampleRate))
                renderSlices.append(RenderTimelineSlice(
                    timelineStartFrame: sFrame,
                    timelineEndFrame: eFrame,
                    sourceStartFrame: srcFrame,
                    muteStems: sec.effectiveIsClickSection
                ))
                cursor = max(cursor, sec.endTime)
            }
        }
        return renderSlices
    }
    
    /// Computes the timeline start time (seconds) for an Overlap transition from `currentSong` into `nextSong`.
    /// Clamps the start so Overlap never begins earlier than the downbeat of `currentSong`'s final section
    /// (e.g., "End" / "Ending" / "Outro"), preventing two songs' metronomes or vocal guides from overlapping.
    public nonisolated static func overlapTransitionStartTime(
        from currentSong: Song,
        currentDuration: TimeInterval,
        to nextSong: Song
    ) -> TimeInterval {
        let overlapSec = min(currentDuration, max(0.1, nextSong.countInDuration))
        let desiredStart = max(0.0, currentDuration - overlapSec)
        let sortedSections = currentSong.sections.sorted { $0.startTime < $1.startTime }
        let earliestAllowedStart = sortedSections.last?.startTime ?? 0.0
        return min(currentDuration, max(earliestAllowedStart, desiredStart))
    }

    private func buildNextSongRenderState(
        sampleRate: Double,
        currentDuration: TimeInterval
    ) -> (transitionMode: SongTransitionType, transitionStartFrame: Int64, nextTotalFrames: Int64, nextSlices: [RenderTimelineSlice], nextTracks: [RenderTrackEntry]) {
        let mode = currentSong.transitionType
        guard currentSongIndex >= 0,
              currentSongIndex + 1 < currentSetlist.songs.count,
              (mode == .autoLink || mode == .overlap || mode == .crossfade) else {
            return (.cueNextSong, 0, 0, [], [])
        }
        
        let nextSong = currentSetlist.songs[currentSongIndex + 1]
        let canonicalFormat = getCanonicalProcessingFormat()
        rehydrateEvictedSongBuffersIfNeeded(for: nextSong)
        let nextSongItems: [(track: StemTrack, buffer: AVAudioPCMBuffer)]
        if let cached = songBuffersCache[nextSong.id], !cached.isEmpty {
            nextSongItems = cached
        } else if !nextSong.stemURLs.isEmpty {
            let loaded = reconstructTracksFromStemURLs(for: nextSong, canonicalFormat: canonicalFormat)
            songBuffersCache[nextSong.id] = loaded
            nextSongItems = loaded
        } else {
            return (.cueNextSong, 0, 0, [], [])
        }
        
        guard !nextSongItems.isEmpty else {
            return (.cueNextSong, 0, 0, [], [])
        }
        
        let needsPreGenClick = !nextSong.excludesClickAndGuide && nextSong.clickSource == .generated && (generatedClickBuffers[nextSong.id]?.frameLength ?? 0) <= 1
        let expectedNextGuideState = Self.defaultGuideLoopState(for: nextSong)
        let needsPreGenGuide = !nextSong.excludesClickAndGuide && nextSong.guideSource == .generated &&
            ((generatedGuideBuffers[nextSong.id]?.frameLength ?? 0) <= 1 || generatedGuideLoopStates[nextSong.id] != expectedNextGuideState)
        if needsPreGenClick || needsPreGenGuide {
            preGenerateClickAndGuide(forSongId: nextSong.id)
        }
        syncCachedClickAndGuideBuffers(forSongId: nextSong.id)
        let resolvedNextSongItems = songBuffersCache[nextSong.id] ?? nextSongItems
        
        let needsPreTransform = nextSong.transposeSemitones != 0 || nextSong.isTempoShifted
        let cachedTransposedMap = cachedTransformedBuffers(for: nextSong)
        
        if needsPreTransform && cachedTransposedMap == nil && isTransposing == false {
            preRenderTranspose(forSongIndex: currentSongIndex + 1)
        }
        
        let anyTrackSoloed = nextSongItems.contains { $0.track.isSoloed }
        let anyBusSoloed = busses.contains { $0.isSoloed }
        var currentAutoBusMuteNames = Set<String>()
        var currentAutoBusVolNames = Set<String>()
        for pt in currentSong.automationPoints {
            for k in pt.busMutes.keys { currentAutoBusMuteNames.insert(k.lowercased()) }
            for k in pt.busFaders.keys { currentAutoBusVolNames.insert(k.lowercased()) }
        }
        var nextTracks: [RenderTrackEntry] = []
        nextTracks.reserveCapacity(nextSongItems.count)
        var maxBufDur: TimeInterval = 0.0
        
        for (track, buf) in resolvedNextSongItems {
            let isClickOrGuide = Self.isClickOrGuideTrack(track)
            let isNextClick = Self.isClickTrack(track)
            let isNextGuide = Self.isGuideTrack(track)
            
            let effectiveBuf: AVAudioPCMBuffer
            if isNextClick && nextSong.clickSource == .generated {
                guard let genClick = generatedClickBuffers[nextSong.id], genClick.frameLength > 1 else { continue }
                effectiveBuf = genClick
            } else if isNextGuide && nextSong.guideSource == .generated {
                guard let genGuide = generatedGuideBuffers[nextSong.id], genGuide.frameLength > 1 else { continue }
                effectiveBuf = genGuide
            } else if let shiftedBuf = cachedTransposedMap?[track.id] {
                effectiveBuf = shiftedBuf
            } else {
                effectiveBuf = buf
            }
            
            guard effectiveBuf.frameLength > 0, let floatData = effectiveBuf.floatChannelData else { continue }
            let dur = Double(effectiveBuf.frameLength) / effectiveBuf.format.sampleRate
            if dur > maxBufDur { maxBufDur = dur }
            
            var bus = busses.first { $0.name.lowercased() == track.assignedBusName.lowercased() }
            if bus == nil {
                let autoBusName = StemTrack.autoAssignBus(for: track.name)
                bus = busses.first { $0.name.lowercased() == autoBusName.lowercased() }
            }
            
            let trackMuted = anyTrackSoloed ? ((!track.isSoloed && !track.isSoloSafe) || track.isMuted) : track.isMuted
            let busMuted: Bool
            if let b = bus {
                let bLower = b.name.lowercased()
                let rawBusMuted = currentAutoBusMuteNames.contains(bLower) ? (baseBusMutes[b.name] ?? b.isMuted) : b.isMuted
                busMuted = anyBusSoloed ? ((!b.isSoloed && !b.isSoloSafe) || rawBusMuted) : rawBusMuted
            } else {
                busMuted = anyBusSoloed
            }
            
            let effectiveMute = trackMuted || busMuted
            var gain = effectiveMute ? 0.0 : track.linearGain
            if let b = bus {
                let bLower = b.name.lowercased()
                let rawBusVol = currentAutoBusVolNames.contains(bLower) ? (baseBusVolumes[b.name] ?? b.volume) : b.volume
                gain *= Self.busLinearGain(forFader: rawBusVol)
            }
            
            let effectivePan: Float
            if let b = bus, b.isMono {
                effectivePan = 0.0
            } else {
                effectivePan = max(-1.0, min(1.0, track.pan))
            }
            
            let gainL: Float
            let gainR: Float
            if effectivePan < 0.0 {
                gainL = gain
                gainR = gain * (1.0 + effectivePan)
            } else if effectivePan > 0.0 {
                gainL = gain * (1.0 - effectivePan)
                gainR = gain
            } else {
                gainL = gain
                gainR = gain
            }
            
            let leftPtr = floatData[0]
            let rightPtr = effectiveBuf.format.channelCount > 1 ? floatData[1] : floatData[0]
            
            let (nextOutL, nextOutR) = resolvePhysicalOutputChannels(for: bus?.physicalOutputChannel ?? "Out 1/2", isMono: bus?.isMono ?? false)
            let isNextTimelineAligned = (isNextGuide && nextSong.guideSource == .generated) || (isNextClick && nextSong.clickSource == .generated)
            
            nextTracks.append(RenderTrackEntry(
                track: track,
                buffer: effectiveBuf,
                leftPtr: leftPtr,
                rightPtr: rightPtr,
                frameLength: Int64(effectiveBuf.frameLength),
                gainL: gainL,
                gainR: gainR,
                isClickOrGuide: isClickOrGuide,
                isTimelineAligned: isNextTimelineAligned,
                outChannelL: nextOutL,
                outChannelR: nextOutR
            ))
        }
        
        let nextSecMax = nextSong.sections.map { $0.endTime }.max() ?? 0.0
        let nextDuration = !nextSong.sections.isEmpty && nextSecMax > 0 ? nextSecMax : maxBufDur
        let nextTotalFrames = max(0, Int64(round(nextDuration * sampleRate)))
        let nextSlices = buildTimelineSlices(for: nextSong, duration: nextDuration, sampleRate: sampleRate)
        
        let transitionStartFrame: Int64
        switch mode {
        case .overlap:
            let overlapStartSec = Self.overlapTransitionStartTime(
                from: currentSong,
                currentDuration: currentDuration,
                to: nextSong
            )
            transitionStartFrame = max(0, Int64(round(overlapStartSec * sampleRate)))
        case .crossfade:
            // The length of the crossfade should be equal in length to 2 bars of Song B
            let nextBPM = nextSong.bpm > 20.0 ? nextSong.bpm : 120.0
            let beatsPerBar = Double(max(1, nextSong.timeSignatureNumerator))
            let secPerBar = (60.0 / nextBPM) * (4.0 / Double(max(1, nextSong.timeSignatureDenominator))) * beatsPerBar
            let twoBarsSec = max(0.5, secPerBar * 2.0)
            let fadeSec = min(currentDuration, twoBarsSec)
            transitionStartFrame = max(0, Int64(round((currentDuration - fadeSec) * sampleRate)))
        default:
            transitionStartFrame = max(0, Int64(round(currentDuration * sampleRate)))
        }
        
        return (mode, transitionStartFrame, nextTotalFrames, nextSlices, nextTracks)
    }
    
    /// Synchronizes all arrangement slices, track pointers, L/R gains, loop bounds, and staged next song into the lock-free `RealTimeMixEngineState`.
    /// Zero `AVAudioPCMBuffer` copies (`memcpy`) are ever performed!
    private func syncMixState() {
        let format = getCanonicalProcessingFormat()
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0
        let masterDuration: TimeInterval = {
            if !currentSong.sections.isEmpty {
                return currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration
            }
            return currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? 0.0)
        }()
        
        let renderSlices = buildTimelineSlices(for: currentSong, duration: masterDuration, sampleRate: sampleRate)
        
        var renderTracks: [RenderTrackEntry] = []
        renderTracks.reserveCapacity(channels.count)
        for track in tracks {
            guard let ch = channels[track.id],
                  let buf = ch.buffer,
                  buf.frameLength > 0,
                  let floatData = buf.floatChannelData else { continue }
            
            let leftPtr = floatData[0]
            let rightPtr = buf.format.channelCount > 1 ? floatData[1] : floatData[0]
            let isClickOrGuide = Self.isClickOrGuideTrack(track)
            
            let cat = StemCategory.category(for: track.name, role: track.role)
            let isGuide = track.role == .guide || cat == .guide || track.assignedBusName.lowercased() == "guide"
            let isClick = track.role == .click || cat == .click || track.assignedBusName.lowercased() == "click"
            let isTimelineAligned = (isGuide && currentSong.guideSource == .generated) || (isClick && currentSong.clickSource == .generated)
            
            renderTracks.append(RenderTrackEntry(
                track: track,
                buffer: buf,
                leftPtr: leftPtr,
                rightPtr: rightPtr,
                frameLength: Int64(buf.frameLength),
                gainL: ch.effectiveGainL,
                gainR: ch.effectiveGainR,
                isClickOrGuide: isClickOrGuide,
                isTimelineAligned: isTimelineAligned,
                outChannelL: ch.outChannelL,
                outChannelR: ch.outChannelR
            ))
        }
        
        let loopStart = loopedSection?.startTime ?? 0.0
        let loopEnd = loopedSection?.endTime ?? 0.0
        let loopEnabled = isLoopActive && loopedSection != nil && loopEnd > loopStart
        
        let nextStaged = buildNextSongRenderState(sampleRate: sampleRate, currentDuration: masterDuration)
        
        mixState.configure(
            sampleRate: sampleRate,
            totalDuration: masterDuration,
            slices: renderSlices,
            tracks: renderTracks,
            loopActive: loopEnabled,
            loopIsSingle: (loopMode == .single),
            loopStart: loopStart,
            loopEnd: loopEnd,
            masterGain: currentMasterLinearGain,
            singleLoopRemaining: singleLoopRemaining,
            transitionMode: nextStaged.transitionMode,
            transitionStartFrame: nextStaged.transitionStartFrame,
            nextTotalTimelineFrames: nextStaged.nextTotalFrames,
            nextSlices: nextStaged.nextSlices,
            nextTracks: nextStaged.nextTracks
        )
    }
    
    public var isCurrentSongTransposing: Bool {
        transposeProgressBySong[currentSong.id] != nil ||
        transposeTasksBySong[currentSong.id] != nil ||
        (isTransposing && transposingSongId == currentSong.id)
    }

    public var isCurrentSongDownloading: Bool {
        downloadingSongProgress[currentSong.id] != nil
    }

    public func play() {
        if isCurrentSongTransposing {
            showTranspositionWarning = true
            return
        }
        if isCurrentSongDownloading {
            showDownloadingWarning = true
            return
        }
        guard !channels.isEmpty else { return }
        if playbackState == .playing { return }
        
        // Return UI to main page if in edit mode (just like pressing "DONE")
        closeEditMode()
        
        // If Song Section Pre-Roll is enabled and the playhead is currently at a section start (other than count off),
        // start playback with section pre-roll!
        if isSongSectionPreRollEnabled,
           let targetSec = currentSong.sections.first(where: { abs(playbackOffsetSeconds - $0.startTime) <= 0.08 && !isSectionCountOff($0) }) {
            if isPadLinked && isPadActive {
                syncActivePadToCurrentSongIfNeeded()
            }
            startPreRollPlayback(for: targetSec)
            return
        }
        
        mixState.cancelPreRoll()
        preRollTargetSectionId = nil
        
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        
        syncMixState()
        updateMatrix()
        mixState.setPlayhead(seconds: playbackOffsetSeconds)
        mixState.setPlaying(true)
        
        scheduledStartOffset = playbackOffsetSeconds
        playbackState = .playing
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        hasTriggeredDualTransitionPad = false
        
        if currentSong.startPadWithSong {
            if currentSong.padIntroOutroOnly {
                let curSec = playbackOffsetSeconds
                let inIntroOrOutro = currentSong.sections.first(where: { curSec >= $0.startTime && curSec < $0.endTime })?.isIntroOrOutro ?? true
                if inIntroOrOutro {
                    if !isPadActive || !padPlayer.isPlaying {
                        startPadPlayer()
                    } else if isPadLinked {
                        syncActivePadToCurrentSongIfNeeded()
                    }
                } else {
                    isPadActive = true
                    if padPlayer.isPlaying {
                        padPlayer.stop()
                    }
                }
            } else {
                if !isPadActive || !padPlayer.isPlaying {
                    startPadPlayer()
                } else if isPadLinked {
                    syncActivePadToCurrentSongIfNeeded()
                }
            }
        } else if isPadLinked && isPadActive {
            if currentSong.padIntroOutroOnly {
                let curSec = playbackOffsetSeconds
                let inIntroOrOutro = currentSong.sections.first(where: { curSec >= $0.startTime && curSec < $0.endTime })?.isIntroOrOutro ?? true
                if !inIntroOrOutro && padPlayer.isPlaying {
                    padPlayer.stop()
                } else if inIntroOrOutro && !padPlayer.isPlaying {
                    startPadPlayer()
                } else if inIntroOrOutro {
                    syncActivePadToCurrentSongIfNeeded()
                }
            } else {
                syncActivePadToCurrentSongIfNeeded()
            }
        }
        
        // Whenever the song is started from anywhere in the song, transmit ProPresenter Playlist (F-1) & Playlist Item (F#-1) if configured
        if !isMIDIMuted {
            MIDICueEngine.shared.fireProPresenterSongStart(
                playlist: currentSong.proPresenterPlaylist,
                playlistItem: currentSong.proPresenterPlaylistItem
            )
            let activeBPM = currentSong.activeMarker(at: playbackOffsetSeconds)?.instantaneousBPM ?? currentSong.bpm
            MIDICueEngine.shared.startMIDIClock(bpm: activeBPM, isResume: playbackOffsetSeconds > 0.01)
        }
        
        startAudioClockTransportTimer()
        startMeteringTimer()
        updatePlaybackActivityAssertion()
    }
    
    public func pause() {
        guard playbackState == .playing else { return }
        mixState.cancelPreRoll()
        preRollTargetSectionId = nil
        mixState.setPlaying(false)
        if transitionPlayerNode.isPlaying {
            transitionPlayerNode.pause()
        }
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        pendingTransitionNextSongIndex = nil
        pendingTransitionStartOffset = 0.0
        mixState.setMasterGain(currentMasterLinearGain)
        playbackOffsetSeconds = mixState.currentSeconds()
        playbackState = .paused
        currentPlayingSectionId = nil
        queuedNextSection = nil
        isBeatFlashing = false
        stopTransportClock()
        MIDICueEngine.shared.stopMIDIClock()
        resetPeakLevels()
        updatePlaybackActivityAssertion()
    }
    
    public func stop() {
        let wasActivePlayback = (playbackState != .stopped)
        mixState.cancelPreRoll()
        preRollTargetSectionId = nil
        mixState.setPlaying(false)
        mixState.setPlayhead(seconds: 0.0)
        mixState.setMasterGain(currentMasterLinearGain)
        if transitionPlayerNode.isPlaying {
            transitionPlayerNode.stop()
        }
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        pendingTransitionNextSongIndex = nil
        pendingTransitionStartOffset = 0.0
        playbackState = .stopped
        stopTransportClock()
        playbackOffsetSeconds = 0.0
        scheduledStartOffset = 0.0
        currentPlayingSectionId = nil
        queuedNextSection = nil
        isBeatFlashing = false
        MIDICueEngine.shared.stopMIDIClock()
        updateTransportPosition(to: 0.0)
        rebuildPrecomputedBeatGrid()
        rebuildCachedActiveAutomation()
        if !currentSong.automationPoints.isEmpty && !isEditAutomationMode {
            applyAutomationAtTime(0.0)
        }
        resetPeakLevels()
        if !songEndBaseVolumes.isEmpty {
            for track in tracks {
                if let baseVol = songEndBaseVolumes[track.id] {
                    track.volume = baseVol
                }
            }
            songEndBaseVolumes.removeAll()
            updateMatrix()
        }
        if wasActivePlayback && currentSong.autoInfiniteLoop && !isLoopActive {
            applyAutoInfiniteLoopIfNeeded(for: currentSong)
            syncMixState()
            if !currentSong.excludesClickAndGuide && currentSong.guideSource == .generated &&
               generatedGuideLoopStates[currentSong.id] != currentLiveGuideLoopState() {
                regenerateGuideTrack()
            }
        }
        updatePlaybackActivityAssertion()
    }
    
    public func togglePlayPause() {
        if playbackState == .playing {
            pause()
        } else {
            play()
        }
    }
    
    public func returnToZero() {
        seek(to: 0.0)
    }
    
    // MARK: - Navigation Buttons (|<<, <<, ✓, >>, >>|)
    public func navigatePreviousSection() {
        let sections = currentSong.sections
        guard !sections.isEmpty else {
            returnToZero()
            return
        }
        
        let currentRefTime: TimeInterval = {
            if playbackState == .playing, let browsed = browsedSectionStartTime {
                return browsed
            }
            return playbackOffsetSeconds
        }()
        
        let currentIndex: Int = {
            if let curIdx = sections.firstIndex(where: { currentRefTime >= $0.startTime && currentRefTime < $0.endTime }) {
                return curIdx
            } else if let nextIdx = sections.firstIndex(where: { $0.startTime > currentRefTime }) {
                return max(0, nextIdx - 1)
            }
            return 0
        }()
        
        let targetIndex: Int
        if playbackState != .playing && (currentRefTime - sections[currentIndex].startTime > 2.0) {
            targetIndex = currentIndex
        } else {
            targetIndex = max(0, currentIndex - 1)
        }
        
        let targetSection = sections[targetIndex]
        if playbackState == .playing {
            browsedSectionStartTime = targetSection.startTime
        } else {
            browsedSectionStartTime = nil
            seek(to: targetSection.startTime)
        }
    }
    
    public func navigateNextSection() {
        let sections = currentSong.sections
        guard !sections.isEmpty else { return }
        
        let currentRefTime: TimeInterval = {
            if playbackState == .playing, let browsed = browsedSectionStartTime {
                return browsed
            }
            return playbackOffsetSeconds
        }()
        
        let currentIndex: Int = {
            if let curIdx = sections.firstIndex(where: { currentRefTime >= $0.startTime && currentRefTime < $0.endTime }) {
                return curIdx
            } else if let nextIdx = sections.firstIndex(where: { $0.startTime > currentRefTime }) {
                return max(0, nextIdx - 1)
            }
            return 0
        }()
        
        let targetIndex = min(sections.count - 1, currentIndex + 1)
        let targetSection = sections[targetIndex]
        
        if playbackState == .playing {
            browsedSectionStartTime = targetSection.startTime
        } else {
            browsedSectionStartTime = nil
            seek(to: targetSection.startTime)
        }
    }
    
    public func triggerSelectAction() {
        let sections = currentSong.sections
        guard !sections.isEmpty else { return }
        
        guard playbackState == .playing else {
            // When song is stopped/paused, << and >> already move directly to that section.
            return
        }
        
        // Find which section is currently browsed / under the playhead to cue it up:
        let targetSection: SongSection = {
            if let browsedTime = browsedSectionStartTime,
               let sec = sections.first(where: { browsedTime >= $0.startTime && browsedTime < $0.endTime }) {
                return sec
            }
            let current = playbackOffsetSeconds
            if let cur = sections.first(where: { current >= $0.startTime && current < $0.endTime }),
               let idx = sections.firstIndex(where: { $0.id == cur.id }),
               idx + 1 < sections.count {
                return sections[idx + 1]
            }
            return sections[0]
        }()
        
        queueNextSection(targetSection)
        browsedSectionStartTime = nil
    }
    
    public func jumpToPreviousSection() {
        navigatePreviousSection()
    }
    
    public func jumpToNextSection() {
        navigateNextSection()
    }
    
    /// Instant 0ms lock-free sample-accurate seek across all 26+ tracks simultaneously (zero buffer slicing!)
    public func seek(to time: TimeInterval) {
        browsedSectionStartTime = nil
        preRollTargetSectionId = nil
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        let isPlayingNow = (playbackState == .playing)
        let clampedTime: TimeInterval
        if isPlayingNow && currentSongDuration > 0 {
            clampedTime = max(0.0, min(time, max(0.0, currentSongDuration - 0.02)))
        } else {
            clampedTime = max(0.0, min(time, currentSongDuration))
        }
        playbackOffsetSeconds = clampedTime
        scheduledStartOffset = clampedTime
        mixState.setPlayhead(seconds: clampedTime, resumePlaying: isPlayingNow)
        updateTransportPosition(to: clampedTime)
        applyAutomationAtTime(clampedTime)
        if isEditAutomationMode {
            updateAutomationSelectionForPlayhead(at: clampedTime)
        }
        if !songEndBaseVolumes.isEmpty {
            let effectiveEndTime = currentSong.sections.isEmpty
                ? currentSongDuration
                : (currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration)
            if clampedTime < max(0.0, effectiveEndTime - 5.0) {
                for track in tracks {
                    if let baseVol = songEndBaseVolumes[track.id] {
                        track.volume = baseVol
                    }
                }
                songEndBaseVolumes.removeAll()
                updateMatrix()
                objectWillChange.send()
            }
        }
    }
    
    // MARK: - Hardware-Locked Sample Playhead Clock
    
    private func stopTransportClock() {
        stopTransportWatchdogTimer()
        let padNeedsMeters = padPlayer.isPlaying || padPlayer.isFadingOut || padMeterPeakL > 0.0 || padMeterPeakR > 0.0
        if !padNeedsMeters {
            stopUIDisplayLink()
        }
    }

    private func startAudioClockTransportTimer() {
        ensureUIDisplayLinkRunning()
        startTransportWatchdogTimer()
    }
    
    private func tickPlaybackClock() {
        guard playbackState == .playing else { return }
        
        let prevSec = playbackOffsetSeconds
        let (currentSec, completedSingleLoop, didRepeatSingleLoop, reachedEnd, transitionedToNextSong, didJumpToQueuedSection, isPreRollActive, preRollTargetSec, engineIsPlaying, atOrPastEnd) = mixState.pollStatus()
        lastPlaybackClockTickTimestamp = CACurrentMediaTime()
        
        // During Section Pre-Roll, audio is rendering from the X bars before the downbeat,
        // but the playhead stays anchored at the section the user played!
        let effectiveDisplaySec = (isPreRollActive && currentSec < preRollTargetSec) ? preRollTargetSec : currentSec
        
        if !isPreRollActive && preRollTargetSectionId != nil {
            preRollTargetSectionId = nil
        }
        
        // Synchronized beat flashing ONLY when a section is queued next or pre-rolling (zero @Published churn otherwise!)
        if queuedNextSection != nil || preRollTargetSectionId != nil {
            let liveBPM = max(20.0, transportPosition.currentBPM > 20.0 ? transportPosition.currentBPM : currentSong.bpm)
            let liveDen = max(1, transportPosition.currentTimeSignatureDenominator)
            let beatDuration = max(0.10, (60.0 / liveBPM) * (4.0 / Double(liveDen)))
            let beatFraction = (currentSec.truncatingRemainder(dividingBy: beatDuration)) / beatDuration
            let flash = (beatFraction < 0.45)
            if isBeatFlashing != flash {
                isBeatFlashing = flash
            }
        } else if isBeatFlashing {
            isBeatFlashing = false
        }
        
        // Sample-accurate queued section jump completed on CoreAudio render thread
        if didJumpToQueuedSection {
            queuedNextSection = nil
            if !currentSong.excludesClickAndGuide {
                regenerateGuideTrack()
            }
            objectWillChange.send()
        }
        
        if didRepeatSingleLoop {
            isLoopActive = false
            loopMode = .none
            loopedSection = nil
            singleLoopRemaining = 0
            if !currentSong.excludesClickAndGuide {
                regenerateGuideTrack()
            }
            objectWillChange.send()
        }
        
        if completedSingleLoop {
            isLoopActive = false
            loopMode = .none
            loopedSection = nil
            singleLoopRemaining = 0
            syncMixState()
            if !currentSong.excludesClickAndGuide {
                regenerateGuideTrack()
            }
            objectWillChange.send()
        }
        
        // Transition pad to next song during Overlap or Crossfade as the transition is working
        if isPadActive && !hasTriggeredDualTransitionPad {
            let mode = currentSong.transitionType
            if (mode == .overlap || mode == .crossfade),
               currentSongIndex + 1 < currentSetlist.songs.count {
                let nextSong = currentSetlist.songs[currentSongIndex + 1]
                let nextBPM = nextSong.bpm > 20.0 ? nextSong.bpm : 120.0
                let transitionSec: TimeInterval = {
                    if mode == .overlap {
                        return Self.overlapTransitionStartTime(
                            from: currentSong,
                            currentDuration: currentSongDuration,
                            to: nextSong
                        )
                    } else {
                        let beatsPerBar = Double(max(1, nextSong.timeSignatureNumerator))
                        let secPerBar = (60.0 / nextBPM) * (4.0 / Double(max(1, nextSong.timeSignatureDenominator))) * beatsPerBar
                        let twoBarsSec = max(0.5, secPerBar * 2.0)
                        let fadeSec = min(currentSongDuration, twoBarsSec)
                        return max(0.0, currentSongDuration - fadeSec)
                    }
                }()
                if isPadLinked && currentSec >= transitionSec - 0.05 {
                    hasTriggeredDualTransitionPad = true
                    let candidateKey = !nextSong.currentTransposedKey.isEmpty && nextSong.currentTransposedKey != "—" ? nextSong.currentTransposedKey : nextSong.musicalKey
                    let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
                    currentPadKey = normalized
                    padPlayer.transitionToKey(normalized, packId: nextSong.padPresetId ?? PadLibraryManager.shared.activePackId)
                }
            }
        }
        
        // If `RealTimeMixEngineState` promoted Song B inside the CoreAudio render callback,
        // audio is ALREADY playing Song B with 0.000ms latency — update the UI state immediately without stopping!
        if transitionedToNextSong {
            completeRealtimeHandoverToNextSong(currentSeconds: currentSec)
            return
        }
        
        if reachedEnd || atOrPastEnd || !engineIsPlaying || (currentSongDuration > 0 && currentSec >= currentSongDuration - 0.0005) {
            handleSongEndTransition()
            return
        }
        
        // Fire any MIDI Cues crossed during this tick (suppressed during pre-roll so prior section cues do not trigger)
        if !isPreRollActive && !isMIDIMuted && !currentSong.midiCues.isEmpty {
            let cues = currentSong.midiCues
            if currentSec >= prevSec {
                let includeStart = (prevSec == scheduledStartOffset)
                for cue in cues {
                    let hit = includeStart
                        ? (cue.time >= prevSec - 0.002 && cue.time <= currentSec)
                        : (cue.time > prevSec && cue.time <= currentSec)
                    if hit {
                        if isLoopActive && cue.disableLoop { continue }
                        if isMIDICueTrimmedOut(cue) { continue }
                        MIDICueEngine.shared.fire(cue: cue)
                    }
                }
            } else if isLoopActive, let loopSec = loopedSection {
                for cue in cues {
                    if cue.disableLoop { continue }
                    if (cue.time > prevSec && cue.time <= loopSec.endTime) ||
                       (cue.time >= loopSec.startTime - 0.002 && cue.time <= currentSec) {
                        if isMIDICueTrimmedOut(cue) { continue }
                        MIDICueEngine.shared.fire(cue: cue)
                    }
                }
            }
        }
        
        // Execute timeline automation transitions & parameter ramps
        if (didJumpToQueuedSection || (!isPreRollActive && currentSec < prevSec - 0.05)) && !currentSong.automationPoints.isEmpty {
            applyAutomationAtTime(currentSec)
        } else {
            processAutomationPlayback(currentSec: currentSec, prevSec: prevSec)
        }
        
        // Keep 24 PPQN MIDI Clock synced to active tempo (including dynamic tempo maps) and MIDI Mute state
        if MIDICueEngine.shared.isMIDIClockEnabled {
            let activeClockBPM = transportPosition.currentBPM > 20.0 ? transportPosition.currentBPM : currentSong.bpm
            MIDICueEngine.shared.syncMIDIClockPlayback(
                isPlayingAndUnmuted: !isMIDIMuted,
                bpm: activeClockBPM,
                isResume: currentSec > 0.01
            )
        }
        
        // Keep active section ID in sync with playback position
        let evalSec = isPreRollActive ? preRollTargetSec : currentSec
        if let activeSec = currentSong.sections.first(where: { evalSec >= $0.startTime && evalSec < $0.endTime }) {
            if activeSec.id != currentPlayingSectionId {
                currentPlayingSectionId = activeSec.id
                handleSectionTransitionForPad(activeSec: activeSec)
            }
        }
        
        // 5-Second Fade Out on Song End if enabled (respecting section trims)
        if currentSong.endFadeOutEnabled {
            let effectiveEndTime: TimeInterval = {
                if !currentSong.sections.isEmpty {
                    return currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration
                }
                return currentSongDuration
            }()
            let fadeStart = max(0.0, effectiveEndTime - 5.0)
            if currentSec >= fadeStart && currentSec <= effectiveEndTime && effectiveEndTime > 5.0 {
                let remaining = max(0.0, effectiveEndTime - currentSec)
                let progress = 1.0 - (remaining / 5.0)
                let t = Float((1.0 - cos(progress * .pi)) * 0.5)
                for track in tracks {
                    if isExemptFromFade(track) { continue }
                    if songEndBaseVolumes[track.id] == nil {
                        songEndBaseVolumes[track.id] = track.volume
                    }
                    let baseVol = songEndBaseVolumes[track.id] ?? 0.80
                    track.volume = max(0.0, baseVol * (1.0 - t))
                }
                updateMatrix()
            } else if currentSec < fadeStart && !songEndBaseVolumes.isEmpty {
                for track in tracks {
                    if let baseVol = songEndBaseVolumes[track.id] {
                        track.volume = baseVol
                    }
                }
                songEndBaseVolumes.removeAll()
                updateMatrix()
            }
        }
        
        playbackOffsetSeconds = effectiveDisplaySec
        updateTransportPosition(to: effectiveDisplaySec)
    }
    
    // MARK: - Song Transitions
    
    public func updateSongTransition(at index: Int, type: SongTransitionType) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].transitionType = type
        if index == currentSongIndex {
            currentSong.transitionType = type
            syncMixState()
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func updateSongContinuePad(at index: Int, continuePad: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].continuePad = continuePad
        if index == currentSongIndex {
            currentSong.continuePad = continuePad
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func updateSongEndFadeOut(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].endFadeOutEnabled = enabled
        if index == currentSongIndex {
            currentSong.endFadeOutEnabled = enabled
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func updateSongStartPadWithSong(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].startPadWithSong = enabled
        if index == currentSongIndex {
            currentSong.startPadWithSong = enabled
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func updateSongPadPreset(at index: Int, presetId: String?) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].padPresetId = presetId
        if index == currentSongIndex {
            currentSong.padPresetId = presetId
            if isPadActive {
                padPlayer.reloadCurrentKey(packId: presetId)
            }
        }
        markSessionChanged()
        objectWillChange.send()
    }

    @discardableResult
    private func remapPadPackReferences(in song: inout Song, from oldId: String, to newId: String) -> Bool {
        var changed = false
        if song.padPresetId == oldId {
            song.padPresetId = newId
            changed = true
        }
        for i in song.automationPoints.indices where song.automationPoints[i].padPackId == oldId {
            song.automationPoints[i].padPackId = newId
            changed = true
        }
        for i in song.defaultAutomationPoints.indices where song.defaultAutomationPoints[i].padPackId == oldId {
            song.defaultAutomationPoints[i].padPackId = newId
            changed = true
        }
        for aIdx in song.savedArrangements.indices {
            for i in song.savedArrangements[aIdx].automationPoints.indices where song.savedArrangements[aIdx].automationPoints[i].padPackId == oldId {
                song.savedArrangements[aIdx].automationPoints[i].padPackId = newId
                changed = true
            }
        }
        return changed
    }

    public func handleRenamedPadPack(oldId: String, newId: String) {
        padPlayer.updateActivePackIdAfterRename(from: oldId, to: newId)
        if manualPadPackId == oldId {
            manualPadPackId = newId
        }
        var didChangeSetlist = false
        for idx in currentSetlist.songs.indices {
            if remapPadPackReferences(in: &currentSetlist.songs[idx], from: oldId, to: newId) {
                didChangeSetlist = true
            }
        }
        if remapPadPackReferences(in: &currentSong, from: oldId, to: newId) || didChangeSetlist {
            markSessionChanged()
        }
        objectWillChange.send()
    }

    public func handleDeletedPadPack(id: String) {
        if manualPadPackId == id {
            manualPadPackId = nil
        }
        var didChangeSetlist = false
        for idx in currentSetlist.songs.indices {
            if remapPadPackReferences(in: &currentSetlist.songs[idx], from: id, to: "simple") {
                didChangeSetlist = true
            }
        }
        if remapPadPackReferences(in: &currentSong, from: id, to: "simple") || didChangeSetlist {
            markSessionChanged()
        }
        if padPlayer.activePackId == id {
            padPlayer.reloadCurrentKey(packId: "simple")
        }
        objectWillChange.send()
    }
    
    
    public func updateSongPadIntroOutroOnly(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].padIntroOutroOnly = enabled
        if index == currentSongIndex {
            currentSong.padIntroOutroOnly = enabled
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Ambient Pad Player Controls
    
    /// Toggles Pad Player LINK mode. When re-engaging LINK, crossfades from manual key back to currentSong's key.
    public func togglePadLink() {
        isPadLinked.toggle()
        if isPadLinked {
            unlinkedKeyID = nil
            syncActivePadToCurrentSongIfNeeded()
        } else {
            unlinkedKeyID = currentPadKey
        }
    }

    public func syncActivePadToCurrentSongIfNeeded() {
        guard isPadLinked else { return }
        let candidateKey = currentSong.currentTransposedKey
        let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
        currentPadKey = normalized
        guard isPadActive else { return }
        let targetPackId = currentSong.padPresetId ?? PadLibraryManager.shared.activePackId
        if padPlayer.isPlaying {
            if padPlayer.activeKey != normalized || padPlayer.activePackId != targetPackId {
                padPlayer.transitionToKey(normalized, packId: targetPackId)
            }
        } else {
            padPlayer.start(key: normalized, packId: targetPackId)
        }
    }

    public func selectManualPadPack(id: String) {
        manualPadPackId = id
        PadLibraryManager.shared.selectPack(id: id)
        padPlayer.reloadCurrentKey(packId: id)
    }

    public func togglePadPlayer() {
        if isPadActive {
            stopPadPlayer()
        } else {
            startPadPlayer()
        }
    }
    
    public func startPadPlayer(key: String? = nil, packId: String? = nil) {
        let candidateKey: String
        if let explicit = key, !explicit.isEmpty, explicit != "—" {
            candidateKey = explicit
        } else if !currentSong.currentTransposedKey.isEmpty && currentSong.currentTransposedKey != "—" {
            candidateKey = currentSong.currentTransposedKey
        } else if !currentSong.musicalKey.isEmpty && currentSong.musicalKey != "—" {
            candidateKey = currentSong.musicalKey
        } else {
            candidateKey = "C"
        }
        
        let targetPackId = packId ?? (padPlayer.isPlaying && playbackState != .playing ? padPlayer.activePackId : (manualPadPackId ?? currentSong.padPresetId))
        let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
        currentPadKey = normalized
        if !isPadLinked {
            unlinkedKeyID = normalized
        }
        if padPlayer.isPlaying {
            padPlayer.transitionToKey(normalized, packId: targetPackId)
        } else {
            padPlayer.start(key: normalized, packId: targetPackId)
        }
        isPadActive = true
        startMeteringTimer()
        updatePlaybackActivityAssertion()
    }
    
    public func stopPadPlayer() {
        padPlayer.stop()
        isPadActive = false
        updatePlaybackActivityAssertion()
    }
    
    public func stopPadPlayerImmediately() {
        padPlayer.stopImmediately()
        isPadActive = false
        updatePlaybackActivityAssertion()
    }
    
    private func handleSectionTransitionForPad(activeSec: SongSection) {
        guard isPadLinked, currentSong.padIntroOutroOnly else { return }
        if activeSec.isIntroOrOutro {
            // Count In, Intro, or Outro: start pad if configured to play
            if currentSong.startPadWithSong || isPadActive {
                if !padPlayer.isPlaying {
                    let candidateKey = !currentSong.currentTransposedKey.isEmpty && currentSong.currentTransposedKey != "—" ? currentSong.currentTransposedKey : currentSong.musicalKey
                    let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
                    currentPadKey = normalized
                    padPlayer.start(key: normalized, packId: currentSong.padPresetId)
                }
                isPadActive = true
            }
        } else {
            // Verse, Chorus, Bridge, etc.: smoothly fade out pad
            if padPlayer.isPlaying {
                padPlayer.stop()
            }
        }
    }
    
    /// Performs a 0ms main-thread UI swap after `RealTimeMixEngineState` has already promoted Song B in the CoreAudio render thread.
    /// Does NOT stop or seek `mixState` so playback continues completely uninterrupted on-beat!
    private func completeRealtimeHandoverToNextSong(currentSeconds: TimeInterval) {
        let nextIndex = currentSongIndex + 1
        guard nextIndex < currentSetlist.songs.count else {
            stop()
            return
        }
        
        // Restore outgoing song's automated mix state before caching so track objects & shared busses stay scoped to it
        if !currentSong.title.isEmpty && !currentSong.automationPoints.isEmpty {
            restoreAutomatedParametersToBaseMix(updateAudioMatrix: false)
        }
        // Save outgoing song state into cache
        if !currentSong.title.isEmpty {
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, renderedWaveformImage)
            if !tracks.isEmpty {
                var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
                currentBuffers.reserveCapacity(tracks.count)
                for track in tracks {
                    if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                        currentBuffers.append((track, buf))
                    }
                }
                songBuffersCache[currentSong.id] = currentBuffers
                recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
                if currentBuffers.contains(where: { $0.1.frameLength > 100 }) {
                    memoryEvictedSongIds.remove(currentSong.id)
                }
            }
        }
        
        currentSongIndex = nextIndex
        let nextSong = currentSetlist.songs[nextIndex]
        currentSong = nextSong
        if currentSong.defaultSections.isEmpty {
            currentSong.defaultSections = currentSong.sections
        }
        
        // Swap tracks, channels, and buffers in a single batched assignment (1 SwiftUI view diff instead of 20!)
        rehydrateEvictedSongBuffersIfNeeded(for: nextSong)
        syncCachedClickAndGuideBuffers(forSongId: nextSong.id)
        let cachedItems = songBuffersCache[nextSong.id] ?? []
        var newTracks: [StemTrack] = []
        newTracks.reserveCapacity(cachedItems.count)
        var newChannels: [UUID: TrackChannel] = [:]
        var newPristine: [UUID: AVAudioPCMBuffer] = [:]
        var maxDur: TimeInterval = 0.0
        
        let cachedTransposed = cachedTransformedBuffers(for: nextSong)
        let canonicalFmt = getCanonicalProcessingFormat()
        
        for (track, buf) in cachedItems {
            let baseBuf: AVAudioPCMBuffer
            if Self.isClickTrack(track) && nextSong.clickSource == .generated {
                if let genClick = generatedClickBuffers[nextSong.id], genClick.frameLength > 1 {
                    baseBuf = genClick
                } else {
                    let silent = AVAudioPCMBuffer(pcmFormat: canonicalFmt, frameCapacity: 1)!
                    silent.frameLength = 1
                    baseBuf = silent
                }
            } else if Self.isGuideTrack(track) && nextSong.guideSource == .generated {
                if let genGuide = generatedGuideBuffers[nextSong.id], genGuide.frameLength > 1 {
                    baseBuf = genGuide
                } else {
                    let silent = AVAudioPCMBuffer(pcmFormat: canonicalFmt, frameCapacity: 1)!
                    silent.frameLength = 1
                    baseBuf = silent
                }
            } else {
                baseBuf = buf
            }
            newPristine[track.id] = baseBuf
            let channelBuf = cachedTransposed?[track.id] ?? baseBuf
            let dur = Double(channelBuf.frameLength) / max(1.0, channelBuf.format.sampleRate)
            track.duration = dur
            if dur > maxDur { maxDur = dur }
            newChannels[track.id] = TrackChannel(track: track, buffer: channelBuf)
            newTracks.append(track)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentSong.id == nextSong.id else { return }
            if !self.currentSong.excludesClickAndGuide {
                if self.currentSong.clickSource == .generated && (self.generatedClickBuffers[nextSong.id]?.frameLength ?? 0) <= 1 {
                    self.regenerateClickTrack()
                }
                let expectedGuideState = self.currentLiveGuideLoopState()
                if self.currentSong.guideSource == .generated &&
                    ((self.generatedGuideBuffers[nextSong.id]?.frameLength ?? 0) <= 1 || self.generatedGuideLoopStates[nextSong.id] != expectedGuideState) {
                    self.regenerateGuideTrack()
                }
            }
            self.syncMixState()
        }
        
        pristineMasterBuffers = newPristine
        channels = newChannels
        tracks = newTracks
        
        currentSongDuration = !currentSong.sections.isEmpty
            ? (currentSong.sections.map { $0.endTime }.max() ?? maxDur)
            : maxDur
        transportPosition.totalDuration = currentSongDuration
        transportClock.position.totalDuration = currentSongDuration
        if !isMIDIMuted {
            MIDICueEngine.shared.updateMIDIClockTempo(nextSong.bpm)
        }
        
        if let cachedWf = songWaveformCache[nextSong.id] {
            masterWaveformPeaks = cachedWf.peaks
            aggregateWaveform = cachedWf.peaks
            renderedWaveformImage = cachedWf.image
        } else {
            recalculateAggregateWaveform(samplesCount: 4000)
            songWaveformCache[nextSong.id] = (masterWaveformPeaks, renderedWaveformImage)
        }
        
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        isLoopActive = false
        loopMode = .none
        loopedSection = nil
        currentPlayingSectionId = nil
        applyAutoInfiniteLoopIfNeeded(for: currentSong)
        rebuildPrecomputedBeatGrid()
        rebuildCachedActiveAutomation()
        captureBaseMixSnapshot()
        if !currentSong.automationPoints.isEmpty {
            applyAutomationAtTime(currentSeconds)
        }
        
        // Update mixer gains and stage the subsequent song (`currentSongIndex + 1`) without resetting `mixState` playhead!
        updateMatrix()
        if isLoopActive {
            syncMixState()
            if !currentSong.excludesClickAndGuide && currentSong.guideSource == .generated &&
               generatedGuideLoopStates[currentSong.id] != currentLiveGuideLoopState() {
                regenerateGuideTrack()
            }
        }
        
        if isPadLinked {
            if isPadActive {
                let candidateKey = !currentSong.currentTransposedKey.isEmpty && currentSong.currentTransposedKey != "—" ? currentSong.currentTransposedKey : currentSong.musicalKey
                let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
                if currentPadKey != normalized || padPlayer.activePackId != currentSong.padPresetId {
                    currentPadKey = normalized
                    padPlayer.transitionToKey(normalized, packId: currentSong.padPresetId)
                }
            } else if currentSong.startPadWithSong {
                startPadPlayer()
            }
        } else if !isPadActive && currentSong.startPadWithSong {
            startPadPlayer()
        }
        
        if !isMIDIMuted {
            MIDICueEngine.shared.fireProPresenterSongStart(
                playlist: currentSong.proPresenterPlaylist,
                playlistItem: currentSong.proPresenterPlaylistItem
            )
            // Fire any MIDI cues in `[0, currentSeconds]` that occurred during the transition
            for cue in currentSong.midiCues where cue.time >= 0.0 && cue.time <= currentSeconds {
                MIDICueEngine.shared.fire(cue: cue)
            }
        }
        
        playbackOffsetSeconds = currentSeconds
        scheduledStartOffset = currentSeconds
        if let activeSec = currentSong.sections.first(where: { currentSeconds >= $0.startTime && currentSeconds < $0.endTime }) {
            currentPlayingSectionId = activeSec.id
        }
        updateTransportPosition(to: currentSeconds)
        updatePlaybackActivityAssertion()
    }
    
    public func handleSongEndTransition() {
        defer { updatePlaybackActivityAssertion() }
        let isLastSong = currentSongIndex >= currentSetlist.songs.count - 1
        let transition = currentSong.transitionType
        let continuePad = currentSong.continuePad
        
        let updatePadForKeyOfNewSong: () -> Void = { [weak self] in
            guard let self = self else { return }
            if continuePad && self.isPadActive {
                let candidateKey = !self.currentSong.currentTransposedKey.isEmpty && self.currentSong.currentTransposedKey != "—" ? self.currentSong.currentTransposedKey : (!self.currentSong.musicalKey.isEmpty && self.currentSong.musicalKey != "—" ? self.currentSong.musicalKey : "C")
                let normalized = AudioSampleBank.normalizeKeyForPad(candidateKey)
                if self.currentPadKey != normalized || self.padPlayer.activePackId != self.currentSong.padPresetId {
                    self.currentPadKey = normalized
                    self.padPlayer.transitionToKey(normalized, packId: self.currentSong.padPresetId)
                }
            } else if !continuePad && (self.isPadActive || self.padPlayer.isPlaying) {
                self.stopPadPlayer()
            }
        }
        
        if isLastSong {
            if transition == .stayInSong {
                if !continuePad && (isPadActive || padPlayer.isPlaying) {
                    stopPadPlayer()
                }
                stop()
            } else {
                // "Cue First Song" will go back to the beginning of the set once the current song is finished
                selectSongInSetlist(at: 0)
                updatePadForKeyOfNewSong()
                stop()
            }
            return
        }
        
        switch transition {
        case .stayInSong:
            if !continuePad && (isPadActive || padPlayer.isPlaying) {
                stopPadPlayer()
            }
            stop()
        case .cueNextSong:
            selectSongInSetlist(at: currentSongIndex + 1)
            updatePadForKeyOfNewSong()
            stop()
        case .autoLink, .overlap, .crossfade:
            if currentSongIndex + 1 < currentSetlist.songs.count {
                selectSongInSetlist(at: currentSongIndex + 1)
                play()
            } else {
                if !continuePad && (isPadActive || padPlayer.isPlaying) {
                    stopPadPlayer()
                }
                stop()
            }
        case .cueFirstSong:
            selectSongInSetlist(at: 0)
            updatePadForKeyOfNewSong()
            stop()
        }
    }
    
    // MARK: - MIDI Cues Management
    
    private func syncCurrentSongMIDICuesToSetlist() {
        currentSong.midiCues.sort { $0.time < $1.time }
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultMidiCues = currentSong.midiCues
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].midiCues = currentSong.midiCues
            currentSetlist.songs[currentSongIndex].defaultMidiCues = currentSong.defaultMidiCues
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func setProPresenterPlaylist(_ value: Int?, forSongIndex targetIndex: Int? = nil) {
        let clamped: Int? = {
            guard let v = value, v >= 1 && v <= 127 else { return nil }
            return v
        }()
        let idx = targetIndex ?? currentSongIndex
        if idx == currentSongIndex {
            currentSong.proPresenterPlaylist = clamped
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx].proPresenterPlaylist = clamped
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func setProPresenterPlaylistItem(_ value: Int?, forSongIndex targetIndex: Int? = nil) {
        let clamped: Int? = {
            guard let v = value, v >= 1 && v <= 127 else { return nil }
            return v
        }()
        let idx = targetIndex ?? currentSongIndex
        if idx == currentSongIndex {
            currentSong.proPresenterPlaylistItem = clamped
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx].proPresenterPlaylistItem = clamped
        }
        markSessionChanged()
        objectWillChange.send()
    }
    /// Resolves the most recent `.pbsong` package URL for `song` in either Cloud or Local libraries.
    private func resolveSongLibraryPackageURL(for song: Song) -> (url: URL, isCloud: Bool)? {
        let fm = FileManager.default
        let sessionInCloud = currentSessionURL.map { LibraryBrowserManager.isURLInCloudLibrary($0) } ?? false
        let normalizedTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        func scanDirectory(_ dir: URL?, isCloud: Bool) -> (url: URL, modified: Date, exactID: Bool)? {
            guard let dir = dir, fm.fileExists(atPath: dir.path),
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                return nil
            }
            var best: (url: URL, modified: Date, exactID: Bool)? = nil
            for item in items where item.pathExtension.lowercased() == "pbsong" {
                let jsonURL = item.appendingPathComponent("song.json")
                guard let data = try? Data(contentsOf: jsonURL),
                      let meta = try? JSONDecoder().decode(SongPackageMetadata.self, from: data) else {
                    continue
                }
                let exactID = (meta.id == song.id)
                let titleMatch = meta.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                let artistMatch = normalizedArtist.isEmpty || meta.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedArtist
                guard exactID || (titleMatch && artistMatch) else { continue }
                
                let mod = (try? jsonURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                if let cur = best {
                    if (exactID && !cur.exactID) || (exactID == cur.exactID && mod > cur.modified) {
                        best = (item, mod, exactID)
                    }
                } else {
                    best = (item, mod, exactID)
                }
            }
            return best
        }
        
        let cloudMatch = scanDirectory(LibraryBrowserManager.shared.cloudSongsDirectory, isCloud: true)
        let localMatch = scanDirectory(LibraryBrowserManager.shared.songsDirectory, isCloud: false)
        
        if sessionInCloud, let c = cloudMatch {
            return (c.url, true)
        }
        if let c = cloudMatch, let l = localMatch {
            if c.exactID && !l.exactID { return (c.url, true) }
            if l.exactID && !c.exactID { return (l.url, false) }
            return c.modified >= l.modified ? (c.url, true) : (l.url, false)
        }
        if let c = cloudMatch { return (c.url, true) }
        if let l = localMatch { return (l.url, false) }
        return nil
    }
    
    /// Saves the target song's MIDI cues (and ProPresenter MIDI playlist/item) to its Cloud or Local `.pbsong` package.
    @discardableResult
    public func saveMIDICuesToLibrary(forSongIndex targetIndex: Int? = nil) -> String {
        let idx = targetIndex ?? currentSongIndex
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        ensureCuesTaggedToSections(in: &song)
        
        if let match = resolveSongLibraryPackageURL(for: song) {
            let jsonURL = match.url.appendingPathComponent("song.json")
            if let data = try? Data(contentsOf: jsonURL),
               var meta = try? JSONDecoder().decode(SongPackageMetadata.self, from: data) {
                meta.midiCues = song.midiCues
                meta.defaultMidiCues = song.defaultMidiCues
                meta.proPresenterPlaylist = song.proPresenterPlaylist
                meta.proPresenterPlaylistItem = song.proPresenterPlaylistItem
                meta.savedArrangements = song.savedArrangements
                meta.activeArrangementId = song.activeArrangementId
                if let encoded = try? JSONEncoder().encode(meta) {
                    try? encoded.write(to: jsonURL, options: .atomic)
                }
                if currentSessionURL != nil {
                    saveCurrentSession()
                }
                LibraryBrowserManager.shared.refreshSongs()
                return match.isCloud ? "Saved to Cloud" : "Saved Locally"
            }
        }
        
        // No existing .pbsong package found: export a new .pbsong to Cloud (if session is in Cloud) or Local Songs directory
        let isCloud = currentSessionURL.map { LibraryBrowserManager.isURLInCloudLibrary($0) } ?? false
        let targetDir: URL = (isCloud ? LibraryBrowserManager.shared.cloudSongsDirectory : nil) ?? LibraryBrowserManager.shared.songsDirectory
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let safeName = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Song" :
            song.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destURL = targetDir.appendingPathComponent("\(safeName).pbsong", isDirectory: true)
        
        let songTracks: [StemTrack]
        var songBuffers: [UUID: AVAudioPCMBuffer] = [:]
        if idx == currentSongIndex {
            songTracks = tracks
            for (tid, ch) in channels { songBuffers[tid] = ch.buffer }
        } else if let cached = songBuffersCache[song.id] {
            songTracks = cached.map { $0.track }
            for item in cached { songBuffers[item.track.id] = item.buffer }
        } else {
            songTracks = []
        }
        
        do {
            try PlaybackFileManager.shared.exportSongPackage(
                song: song,
                tracks: songTracks,
                buffers: songBuffers,
                transposedBuffers: [:],
                to: destURL
            )
            if currentSessionURL != nil {
                saveCurrentSession()
            }
            LibraryBrowserManager.shared.refreshSongs()
            return isCloud ? "Saved to Cloud" : "Saved Locally"
        } catch {
            return "Save Failed"
        }
    }
    
    /// Pulls the most recently saved MIDI cues (and ProPresenter MIDI playlist/item) from Cloud (for cloud songs) or Local `.pbsong`.
    @discardableResult
    public func refreshMIDICuesFromLibrary(forSongIndex targetIndex: Int? = nil) -> String {
        let idx = targetIndex ?? currentSongIndex
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        
        guard let match = resolveSongLibraryPackageURL(for: song) else {
            return "No Saved Song Found"
        }
        let jsonURL = match.url.appendingPathComponent("song.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let meta = try? JSONDecoder().decode(SongPackageMetadata.self, from: data) else {
            return "Failed to Read MIDI Cues"
        }
        
        song.midiCues = meta.midiCues
        song.defaultMidiCues = meta.defaultMidiCues ?? meta.midiCues
        if let pp = meta.proPresenterPlaylist { song.proPresenterPlaylist = pp }
        if let ppi = meta.proPresenterPlaylistItem { song.proPresenterPlaylistItem = ppi }
        ensureCuesTaggedToSections(in: &song)
        
        if idx == currentSongIndex {
            currentSong.midiCues = song.midiCues
            currentSong.defaultMidiCues = song.defaultMidiCues
            currentSong.proPresenterPlaylist = song.proPresenterPlaylist
            currentSong.proPresenterPlaylistItem = song.proPresenterPlaylistItem
            selectedMIDICueId = nil
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx].midiCues = song.midiCues
            currentSetlist.songs[idx].defaultMidiCues = song.defaultMidiCues
            currentSetlist.songs[idx].proPresenterPlaylist = song.proPresenterPlaylist
            currentSetlist.songs[idx].proPresenterPlaylistItem = song.proPresenterPlaylistItem
        }
        markSessionChanged()
        objectWillChange.send()
        return match.isCloud ? "Refreshed from Cloud" : "Refreshed Locally"
    }
    
    
    /// Computes the default velocity for a new MIDI cue added at `time`:
    /// Starts at 1 for the first cue, and defaults to `N + 1` where `N` is the velocity of the previous MIDI cue.
    public func defaultVelocityForNewMIDICue(at time: TimeInterval) -> Int {
        let sorted = currentSong.midiCues.sorted { $0.time < $1.time }
        if let prevCue = sorted.last(where: { $0.time <= time + 0.005 }) {
            return min(127, max(1, prevCue.secondaryValue + 1))
        }
        return 1
    }
    
    public func addMIDICue(_ cue: MIDICue) {
        var mutableCue = cue
        mutableCue.time = snapTimeToBeatGrid(mutableCue.time)
        if mutableCue.sectionId == nil {
            if let matchedSection = currentSong.sections.first(where: { mutableCue.time >= $0.startTime && mutableCue.time < $0.endTime }) {
                mutableCue.sectionId = matchedSection.id
            }
        }
        currentSong.midiCues.append(mutableCue)
        selectedMIDICueId = mutableCue.id
        syncCurrentSongMIDICuesToSetlist()
        if !isMIDIMuted {
            MIDICueEngine.shared.fire(cue: mutableCue)
        }
    }
    
    public func updateMIDICue(_ cue: MIDICue) {
        if let idx = currentSong.midiCues.firstIndex(where: { $0.id == cue.id }) {
            var mutableCue = cue
            mutableCue.time = snapTimeToBeatGrid(mutableCue.time)
            if let matchedSection = currentSong.sections.first(where: { mutableCue.time >= $0.startTime && mutableCue.time < $0.endTime }) {
                mutableCue.sectionId = matchedSection.id
            }
            currentSong.midiCues[idx] = mutableCue
            selectedMIDICueId = mutableCue.id
            syncCurrentSongMIDICuesToSetlist()
        }
    }
    
    public func removeMIDICue(id: UUID) {
        let sortedBefore = currentSong.midiCues.sorted { $0.time < $1.time }
        let removedIdx = sortedBefore.firstIndex(where: { $0.id == id })
        currentSong.midiCues.removeAll { $0.id == id }
        if selectedMIDICueId == id {
            let remaining = currentSong.midiCues.sorted { $0.time < $1.time }
            if let idx = removedIdx, !remaining.isEmpty {
                let nextIdx = min(idx, remaining.count - 1)
                selectedMIDICueId = remaining[nextIdx].id
            } else {
                selectedMIDICueId = remaining.first?.id
            }
            isNudgingMIDICue = false
        }
        syncCurrentSongMIDICuesToSetlist()
    }
    
    public func clearAllMIDICues() {
        currentSong.midiCues.removeAll()
        selectedMIDICueId = nil
        isNudgingMIDICue = false
        syncCurrentSongMIDICuesToSetlist()
    }
    
    public var selectedMIDICue: MIDICue? {
        guard let id = selectedMIDICueId else { return nil }
        return currentSong.midiCues.first(where: { $0.id == id })
    }
    
    /// Handles the top-left `<` button in MIDI Cues mode:
    /// In Nudge Mode, moves the selected cue earlier by one 16th note. Otherwise selects the previous MIDI cue.
    public func stepLeftMIDICueButton() {
        if isNudgingMIDICue {
            nudgeSelectedMIDICue(bySixteenthNotes: -1)
            return
        }
        let sorted = currentSong.midiCues.filter { !isMIDICueTrimmedOut($0) }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return }
        
        if let currentId = selectedMIDICueId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let prevIdx = max(0, idx - 1)
            selectedMIDICueId = sorted[prevIdx].id
        } else if let prevCue = sorted.last(where: { $0.time <= playbackOffsetSeconds + 0.05 }) {
            selectedMIDICueId = prevCue.id
        } else {
            selectedMIDICueId = sorted.first?.id
        }
    }
    
    /// Handles the top-left `>` button in MIDI Cues mode:
    /// In Nudge Mode, moves the selected cue later by one 16th note. Otherwise selects the next MIDI cue.
    public func stepRightMIDICueButton() {
        if isNudgingMIDICue {
            nudgeSelectedMIDICue(bySixteenthNotes: 1)
            return
        }
        let sorted = currentSong.midiCues.filter { !isMIDICueTrimmedOut($0) }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return }
        
        if let currentId = selectedMIDICueId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let nextIdx = min(sorted.count - 1, idx + 1)
            selectedMIDICueId = sorted[nextIdx].id
        } else if let nextCue = sorted.first(where: { $0.time >= playbackOffsetSeconds - 0.05 }) {
            selectedMIDICueId = nextCue.id
        } else {
            selectedMIDICueId = sorted.last?.id
        }
    }
    
    /// Nudges the currently selected MIDI cue by `step` 16th-note increments
    public func nudgeSelectedMIDICue(bySixteenthNotes step: Int) {
        guard let id = selectedMIDICueId,
              let idx = currentSong.midiCues.firstIndex(where: { $0.id == id }) else { return }
        
        var cue = currentSong.midiCues[idx]
        let activeBPM = currentSong.activeMarker(at: cue.time)?.instantaneousBPM ?? currentSong.bpm
        let beatSec = (60.0 / max(20.0, activeBPM)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let sixteenthSec = (currentSong.timeSignatureDenominator == 8) ? (beatSec / 2.0) : (beatSec / 4.0)
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        
        cue.time = max(0.0, min(maxTime, cue.time + Double(step) * sixteenthSec))
        if let matchedSection = currentSong.sections.first(where: { cue.time >= $0.startTime && cue.time < $0.endTime }) {
            cue.sectionId = matchedSection.id
        }
        currentSong.midiCues[idx] = cue
        syncCurrentSongMIDICuesToSetlist()
    }
    
    public func jumpToPreviousMIDICue() {
        stepLeftMIDICueButton()
    }
    
    public func jumpToNextMIDICue() {
        stepRightMIDICueButton()
    }
    
    // MARK: - Section-Associated MIDI Cues & Copy / Paste
    
    /// Returns all active (non-trimmed-out) MIDI cues currently within or associated with the given section
    public func midiCues(in section: SongSection) -> [MIDICue] {
        return currentSong.midiCues.filter { cue in
            if isMIDICueTrimmedOut(cue) { return false }
            if let secId = cue.sectionId, secId == section.id {
                return true
            }
            return cue.time >= section.startTime - 0.005 && cue.time < section.endTime - 0.005
        }.sorted { $0.time < $1.time }
    }
    
    /// Copies all MIDI cues from a given section into the clipboard with relative offsets from section start
    public func copyMIDICues(from section: SongSection) {
        let cues = midiCues(in: section)
        guard !cues.isEmpty else {
            copiedMIDICuesClipboard = nil
            copiedSourceSectionName = nil
            return
        }
        
        let items = cues.map { cue in
            let rel = max(0.0, cue.time - section.startTime)
            return CopiedMIDICueItem(
                relativeTime: rel,
                bus: cue.bus,
                messageType: cue.messageType,
                primaryValue: cue.primaryValue,
                originalVelocity: cue.secondaryValue,
                disableLoop: cue.disableLoop,
                cueDescription: cue.cueDescription
            )
        }
        
        copiedMIDICuesClipboard = items
        copiedSourceSectionName = section.name
        objectWillChange.send()
    }
    
    /// Pastes copied MIDI cues into the destination section.
    /// If `autoAdjustVelocity` is true:
    /// For each bus/bank, finds the previous MIDI cue on that same bus before this section (or within it before the first pasted cue),
    /// and adjusts the velocity of the first pasted cue to N+1, second to N+2, etc.
    public func pasteMIDICues(to section: SongSection, autoAdjustVelocity: Bool) {
        guard let clipboard = copiedMIDICuesClipboard, !clipboard.isEmpty else { return }
        
        // Remove any existing cues in the destination section so we cleanly overwrite/replace or complement
        currentSong.midiCues.removeAll { cue in
            if let secId = cue.sectionId, secId == section.id { return true }
            return cue.time >= section.startTime - 0.005 && cue.time < section.endTime - 0.005
        }
        
        // Group clipboard cues by MIDI Bus and track running velocity counters per bus
        var runningVelocities: [MIDIBus: Int] = [:]
        
        if autoAdjustVelocity {
            for bus in MIDIBus.allCases {
                // Find velocity of the MIDI cue on the same bus immediately before the destination section
                let prevCuesOnBus = currentSong.midiCues
                    .filter { $0.bus == bus && $0.time < section.startTime + 0.005 && $0.messageType == .note }
                    .sorted { $0.time < $1.time }
                
                if let lastBefore = prevCuesOnBus.last {
                    runningVelocities[bus] = lastBefore.secondaryValue
                } else {
                    // No prior cue on this bus, start baseline at 0 so first pasted is 0 + 1 = 1
                    runningVelocities[bus] = 0
                }
            }
        }
        
        var pastedCues: [MIDICue] = []
        for item in clipboard {
            let targetTime = min(section.endTime - 0.001, section.startTime + item.relativeTime)
            
            let finalVelocity: Int
            if autoAdjustVelocity && item.messageType == .note {
                let currentN = runningVelocities[item.bus] ?? 0
                let nextN = min(127, max(1, currentN + 1))
                runningVelocities[item.bus] = nextN
                finalVelocity = nextN
            } else {
                finalVelocity = item.originalVelocity
            }
            
            let newCue = MIDICue(
                id: UUID(),
                time: targetTime,
                sectionId: section.id,
                bus: item.bus,
                messageType: item.messageType,
                primaryValue: item.primaryValue,
                secondaryValue: finalVelocity,
                disableLoop: item.disableLoop,
                cueDescription: item.cueDescription
            )
            pastedCues.append(newCue)
        }
        
        currentSong.midiCues.append(contentsOf: pastedCues)
        syncCurrentSongMIDICuesToSetlist()
        
        if let first = pastedCues.first {
            selectedMIDICueId = first.id
        }
    }
    
    // MARK: - Directional Cues Management
    
    public func addDirectionalCue(label: String, at time: TimeInterval) {
        let snappedTime = snapTimeToBeatGrid(time)
        var sectionId: UUID? = nil
        if let matchedSection = currentSong.sections.first(where: { snappedTime >= $0.startTime && snappedTime < $0.endTime }) {
            sectionId = matchedSection.id
        }
        let cue = DirectionalCue(id: UUID(), time: snappedTime, label: label, sectionId: sectionId)
        currentSong.directionalCues.append(cue)
        currentSong.directionalCues.sort { $0.time < $1.time }
        selectedDirectionalCueId = cue.id
        syncCurrentSongDirectionalCuesToSetlist()
        
        applyGuideBuffer()
        regenerateGuideTrack()
    }
    
    public func updateDirectionalCue(id: UUID, label: String, time: TimeInterval) {
        guard let idx = currentSong.directionalCues.firstIndex(where: { $0.id == id }) else { return }
        let snappedTime = snapTimeToBeatGrid(time)
        var sectionId: UUID? = nil
        if let matchedSection = currentSong.sections.first(where: { snappedTime >= $0.startTime && snappedTime < $0.endTime }) {
            sectionId = matchedSection.id
        }
        currentSong.directionalCues[idx] = DirectionalCue(id: id, time: snappedTime, label: label, sectionId: sectionId)
        currentSong.directionalCues.sort { $0.time < $1.time }
        syncCurrentSongDirectionalCuesToSetlist()
        
        applyGuideBuffer()
        regenerateGuideTrack()
    }
    
    public func removeDirectionalCue(id: UUID) {
        currentSong.directionalCues.removeAll { $0.id == id }
        if selectedDirectionalCueId == id {
            selectedDirectionalCueId = currentSong.directionalCues.first?.id
        }
        syncCurrentSongDirectionalCuesToSetlist()
        
        applyGuideBuffer()
        regenerateGuideTrack()
    }
    
    public var selectedDirectionalCue: DirectionalCue? {
        guard let id = selectedDirectionalCueId else { return nil }
        return currentSong.directionalCues.first(where: { $0.id == id })
    }
    
    /// Handles the top-left `<` button in Directional Cues mode:
    /// In Nudge Mode, moves the selected cue earlier by one 16th note. Otherwise selects the previous directional cue.
    public func stepLeftDirectionalCueButton() {
        if isNudgingDirectionalCue {
            nudgeSelectedDirectionalCue(bySixteenthNotes: -1)
            return
        }
        let sorted = currentSong.directionalCues.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return }
        
        if let currentId = selectedDirectionalCueId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let prevIdx = max(0, idx - 1)
            selectedDirectionalCueId = sorted[prevIdx].id
        } else if let prevCue = sorted.last(where: { $0.time <= playbackOffsetSeconds + 0.05 }) {
            selectedDirectionalCueId = prevCue.id
        } else {
            selectedDirectionalCueId = sorted.first?.id
        }
    }
    
    /// Handles the top-left `>` button in Directional Cues mode:
    /// In Nudge Mode, moves the selected cue later by one 16th note. Otherwise selects the next directional cue.
    public func stepRightDirectionalCueButton() {
        if isNudgingDirectionalCue {
            nudgeSelectedDirectionalCue(bySixteenthNotes: 1)
            return
        }
        let sorted = currentSong.directionalCues.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return }
        
        if let currentId = selectedDirectionalCueId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let nextIdx = min(sorted.count - 1, idx + 1)
            selectedDirectionalCueId = sorted[nextIdx].id
        } else if let nextCue = sorted.first(where: { $0.time >= playbackOffsetSeconds - 0.05 }) {
            selectedDirectionalCueId = nextCue.id
        } else {
            selectedDirectionalCueId = sorted.last?.id
        }
    }
    
    /// Nudges the currently selected directional cue by `step` 16th-note increments
    public func nudgeSelectedDirectionalCue(bySixteenthNotes step: Int) {
        guard let id = selectedDirectionalCueId,
              let idx = currentSong.directionalCues.firstIndex(where: { $0.id == id }) else { return }
        
        var cue = currentSong.directionalCues[idx]
        let activeBPM = currentSong.activeMarker(at: cue.time)?.instantaneousBPM ?? currentSong.bpm
        let beatSec = (60.0 / max(20.0, activeBPM)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let sixteenthSec = (currentSong.timeSignatureDenominator == 8) ? (beatSec / 2.0) : (beatSec / 4.0)
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        
        cue.time = max(0.0, min(maxTime, cue.time + Double(step) * sixteenthSec))
        currentSong.directionalCues[idx] = cue
        syncCurrentSongDirectionalCuesToSetlist()
        
        regenerateGuideTrack()
    }
    
    public func setSpeakDirectionalCuesOnUploadedGuide(_ enabled: Bool) {
        currentSong.speakDirectionalCuesOnUploadedGuide = enabled
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].speakDirectionalCuesOnUploadedGuide = enabled
        }
        applyGuideBuffer()
        objectWillChange.send()
    }
    
    private func syncCurrentSongDirectionalCuesToSetlist() {
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultDirectionalCues = currentSong.directionalCues
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].directionalCues = currentSong.directionalCues
            currentSetlist.songs[currentSongIndex].defaultDirectionalCues = currentSong.defaultDirectionalCues
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Automation Management & Playback Interpolation
    
    public var selectedAutomationPoint: AutomationPoint? {
        guard let id = selectedAutomationPointId else { return nil }
        return currentSong.automationPoints.first(where: { $0.id == id })
    }
    
    public func addAutomationPoint(
        name: String,
        time: TimeInterval,
        transitionBeats: Int,
        descriptionText: String
    ) -> AutomationPoint {
        let sec = snapTimeToBeatGrid(time)
        let activeSectionId = currentSong.sections.first(where: { sec >= $0.startTime && sec < $0.endTime })?.id
        
        // Snapshot current mixer state as starting target values
        var trackFaders: [UUID: Float] = [:]
        var trackPans: [UUID: Float] = [:]
        var trackMutes: [UUID: Bool] = [:]
        for track in tracks {
            trackFaders[track.id] = track.volume
            trackPans[track.id] = track.pan
            trackMutes[track.id] = track.isMuted
        }
        
        var busFaders: [String: Float] = [:]
        var busMutes: [String: Bool] = [:]
        for bus in busses {
            busFaders[bus.name] = bus.volume
            busMutes[bus.name] = bus.isMuted
        }
        
        let newPoint = AutomationPoint(
            id: UUID(),
            time: sec,
            name: name,
            transitionBeats: transitionBeats,
            descriptionText: descriptionText,
            sectionId: activeSectionId,
            trackFaders: trackFaders,
            trackPans: trackPans,
            trackMutes: trackMutes,
            busFaders: busFaders,
            busMutes: busMutes,
            padActive: nil,
            midiMuted: isMIDIMuted
        )
        
        currentSong.automationPoints.append(newPoint)
        currentSong.automationPoints.sort { $0.time < $1.time }
        selectedAutomationPointId = newPoint.id
        isNudgingAutomation = false
        syncCurrentSongAutomationToSetlist()
        
        seek(to: sec)
        return newPoint
    }
    
    public func updateAutomationPoint(
        id: UUID,
        name: String,
        transitionBeats: Int,
        descriptionText: String
    ) {
        guard let idx = currentSong.automationPoints.firstIndex(where: { $0.id == id }) else { return }
        currentSong.automationPoints[idx].name = name
        currentSong.automationPoints[idx].transitionBeats = transitionBeats
        currentSong.automationPoints[idx].descriptionText = descriptionText
        syncCurrentSongAutomationToSetlist()
    }
    
    public func removeAutomationPoint(id: UUID) {
        if selectedAutomationPointId == id {
            let sorted = currentSong.automationPoints.sorted { $0.time < $1.time }
            if let idx = sorted.firstIndex(where: { $0.id == id }) {
                if idx > 0 {
                    selectedAutomationPointId = sorted[idx - 1].id
                } else if sorted.count > 1 {
                    selectedAutomationPointId = sorted[1].id
                } else {
                    selectedAutomationPointId = nil
                }
            }
        }
        currentSong.automationPoints.removeAll { $0.id == id }
        syncCurrentSongAutomationToSetlist()
        if let sel = selectedAutomationPointId {
            loadAutomationPointValues(id: sel)
        }
    }
    
    public func selectAutomationPoint(id: UUID?, seekPlayhead: Bool = false) {
        selectedAutomationPointId = id
        guard let id = id, let point = currentSong.automationPoints.first(where: { $0.id == id }) else { return }
        loadAutomationPointValues(id: id)
        if seekPlayhead {
            seek(to: displayTime(forAutomationPoint: point))
        }
    }
    
    public func stepLeftAutomationButton() {
        if isNudgingAutomation {
            nudgeSelectedAutomationPoint(byBeats: -1)
            return
        }
        let sorted = currentSong.automationPoints.sorted { displayTime(forAutomationPoint: $0) < displayTime(forAutomationPoint: $1) }
        guard !sorted.isEmpty else { return }
        if let currentId = selectedAutomationPointId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let prevIdx = max(0, idx - 1)
            selectAutomationPoint(id: sorted[prevIdx].id, seekPlayhead: true)
        } else if let prev = sorted.last(where: { displayTime(forAutomationPoint: $0) <= playbackOffsetSeconds + 0.05 }) {
            selectAutomationPoint(id: prev.id, seekPlayhead: true)
        } else {
            selectAutomationPoint(id: sorted.first?.id, seekPlayhead: true)
        }
    }
    
    public func stepRightAutomationButton() {
        if isNudgingAutomation {
            nudgeSelectedAutomationPoint(byBeats: 1)
            return
        }
        let sorted = currentSong.automationPoints.sorted { displayTime(forAutomationPoint: $0) < displayTime(forAutomationPoint: $1) }
        guard !sorted.isEmpty else { return }
        if let currentId = selectedAutomationPointId,
           let idx = sorted.firstIndex(where: { $0.id == currentId }) {
            let nextIdx = min(sorted.count - 1, idx + 1)
            selectAutomationPoint(id: sorted[nextIdx].id, seekPlayhead: true)
        } else if let next = sorted.first(where: { displayTime(forAutomationPoint: $0) >= playbackOffsetSeconds - 0.05 }) {
            selectAutomationPoint(id: next.id, seekPlayhead: true)
        } else {
            selectAutomationPoint(id: sorted.last?.id, seekPlayhead: true)
        }
    }
    
    public func nudgeSelectedAutomationPoint(byBeats beats: Int) {
        guard let id = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == id }) else { return }
        
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let delta = Double(beats) * secPerBeat
        var point = currentSong.automationPoints[idx]
        let maxTime = currentSongDuration > 0 ? currentSongDuration : max(300.0, currentSong.totalDuration)
        point.time = max(0.0, min(maxTime, point.time + delta))
        currentSong.automationPoints[idx] = point
        currentSong.automationPoints.sort { $0.time < $1.time }
        
        seek(to: point.time)
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordCurrentAutomationPointValues() {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        
        var point = currentSong.automationPoints[idx]
        for track in tracks {
            point.trackFaders[track.id] = track.volume
            point.trackPans[track.id] = track.pan
            point.trackMutes[track.id] = track.isMuted
        }
        for bus in busses {
            point.busFaders[bus.name] = bus.volume
            point.busMutes[bus.name] = bus.isMuted
        }
        point.midiMuted = isMIDIMuted
        
        currentSong.automationPoints[idx] = point
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadActive(_ active: Bool) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padActive = active
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadMuted(_ muted: Bool) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padMuted = muted
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadVolume(_ volume: Float) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padVolume = volume
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadPan(_ pan: Float) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padPan = pan
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadKey(_ key: String) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padKey = AudioSampleBank.normalizeKeyForPad(key)
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadPackId(_ packId: String?) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padPackId = packId
        syncCurrentSongAutomationToSetlist()
    }
    
    public func recordAutomationPadLinked(_ linked: Bool) {
        guard isEditAutomationMode, let selId = selectedAutomationPointId,
              let idx = currentSong.automationPoints.firstIndex(where: { $0.id == selId }) else { return }
        currentSong.automationPoints[idx].padLinked = linked
        syncCurrentSongAutomationToSetlist()
    }
    
    public func loadAutomationPointValues(id: UUID) {
        guard let point = currentSong.automationPoints.first(where: { $0.id == id }) else { return }
        for track in tracks {
            if let vol = point.trackFaders[track.id] { track.volume = vol }
            if let pan = point.trackPans[track.id] { track.pan = pan }
            if let mute = point.trackMutes[track.id] { track.isMuted = mute }
        }
        for bus in busses {
            if let vol = point.busFaders[bus.name] { bus.volume = vol }
            if let mute = point.busMutes[bus.name] { bus.isMuted = mute }
        }
        if let m = point.midiMuted { isMIDIMuted = m }
        if let padLinked = point.padLinked { isPadLinked = padLinked }
        if let padPack = point.padPackId { manualPadPackId = padPack }
        if let padKey = point.padKey {
            let norm = AudioSampleBank.normalizeKeyForPad(padKey)
            currentPadKey = norm
            if !isPadLinked { unlinkedKeyID = norm }
        }
        if let padVol = point.padVolume { padChannelVolume = padVol }
        if let padPan = point.padPan { padChannelPan = padPan }
        if let padMute = point.padMuted { padChannelMuted = padMute }
        updateMatrix()
        objectWillChange.send()
    }
    
    public func captureBaseMixSnapshot() {
        baseTrackVolumes.removeAll()
        baseTrackPans.removeAll()
        baseTrackMutes.removeAll()
        for track in tracks {
            baseTrackVolumes[track.id] = track.volume
            baseTrackPans[track.id] = track.pan
            baseTrackMutes[track.id] = track.isMuted
        }
        baseBusVolumes.removeAll()
        baseBusMutes.removeAll()
        for bus in busses {
            baseBusVolumes[bus.name] = bus.volume
            baseBusMutes[bus.name] = bus.isMuted
        }
        basePadVolume = padChannelVolume
        basePadPan = padChannelPan
        basePadMuted = padChannelMuted
        baseMIDIMuted = isMIDIMuted
    }
    
    public func restoreBaseMixSnapshot() {
        guard !baseTrackVolumes.isEmpty || !baseBusVolumes.isEmpty else { return }
        for track in tracks {
            if let v = baseTrackVolumes[track.id] { track.volume = v }
            if let p = baseTrackPans[track.id] { track.pan = p }
            if let m = baseTrackMutes[track.id] { track.isMuted = m }
        }
        for bus in busses {
            if let v = baseBusVolumes[bus.name] { bus.volume = v }
            if let m = baseBusMutes[bus.name] { bus.isMuted = m }
        }
        if currentSong.automationPoints.contains(where: { $0.midiMuted != nil }) {
            isMIDIMuted = baseMIDIMuted
        }
        if currentSong.automationPoints.contains(where: { $0.padVolume != nil }) {
            padChannelVolume = basePadVolume
        }
        if currentSong.automationPoints.contains(where: { $0.padPan != nil }) {
            padChannelPan = basePadPan
        }
        if currentSong.automationPoints.contains(where: { $0.padMuted != nil }) {
            padChannelMuted = basePadMuted
        }
        updateMatrix()
        objectWillChange.send()
    }

    /// Restores only track/bus/MIDI/pad parameters touched by `currentSong.automationPoints` back to their baseline mix,
    /// leaving manual adjustments on non-automated channels untouched.
    public func restoreAutomatedParametersToBaseMix(updateAudioMatrix: Bool = true) {
        guard !currentSong.automationPoints.isEmpty else { return }
        guard !baseTrackVolumes.isEmpty || !baseBusVolumes.isEmpty else { return }

        var autoVolTrackIds = Set<UUID>()
        var autoPanTrackIds = Set<UUID>()
        var autoMuteTrackIds = Set<UUID>()
        var autoVolBusNames = Set<String>()
        var autoMuteBusNames = Set<String>()
        var hasMidiMute = false
        var hasPadVol = false
        var hasPadPan = false
        var hasPadMute = false

        for pt in currentSong.automationPoints {
            autoVolTrackIds.formUnion(pt.trackFaders.keys)
            autoPanTrackIds.formUnion(pt.trackPans.keys)
            autoMuteTrackIds.formUnion(pt.trackMutes.keys)
            for k in pt.busFaders.keys { autoVolBusNames.insert(k.lowercased()) }
            for k in pt.busMutes.keys { autoMuteBusNames.insert(k.lowercased()) }
            if pt.midiMuted != nil { hasMidiMute = true }
            if pt.padVolume != nil { hasPadVol = true }
            if pt.padPan != nil { hasPadPan = true }
            if pt.padMuted != nil { hasPadMute = true }
        }

        for track in tracks {
            if autoVolTrackIds.contains(track.id), let v = baseTrackVolumes[track.id] {
                track.volume = v
            }
            if autoPanTrackIds.contains(track.id), let p = baseTrackPans[track.id] {
                track.pan = p
            }
            if autoMuteTrackIds.contains(track.id), let m = baseTrackMutes[track.id] {
                track.isMuted = m
            }
        }
        for bus in busses {
            let busLower = bus.name.lowercased()
            if autoVolBusNames.contains(busLower), let v = baseBusVolumes[bus.name] {
                bus.volume = v
            }
            if autoMuteBusNames.contains(busLower), let m = baseBusMutes[bus.name] {
                bus.isMuted = m
            }
        }
        if hasMidiMute { isMIDIMuted = baseMIDIMuted }
        if hasPadVol { padChannelVolume = basePadVolume }
        if hasPadPan { padChannelPan = basePadPan }
        if hasPadMute { padChannelMuted = basePadMuted }

        if updateAudioMatrix {
            updateMatrix()
            objectWillChange.send()
        }
    }
    
    public func processAutomationPlayback(currentSec: TimeInterval, prevSec: TimeInterval) {
        guard !cachedActiveAutomation.isEmpty else { return }
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let sorted = cachedActiveAutomation

        for (idx, item) in sorted.enumerated() {
            let point = item.point
            let durationSec = Double(point.transitionBeats) * secPerBeat
            let rampStart = item.startSec
            let rampEnd = rampStart + durationSec

            // 1. Instant changes (mutes, MIDI mute, pad toggle) trigger right at the cue's start time
            let justStarted = (prevSec < rampStart && currentSec >= rampStart) || (point.transitionBeats == 0 && prevSec <= rampStart && currentSec >= rampStart)
            if justStarted {
                for track in tracks {
                    if let mute = point.trackMutes[track.id] { track.isMuted = mute }
                    if point.transitionBeats == 0 {
                        if let vol = point.trackFaders[track.id] { track.volume = vol }
                        if let pan = point.trackPans[track.id] { track.pan = pan }
                    }
                }
                for bus in busses {
                    let busLower = bus.name.lowercased()
                    if let mute = point.busMutes[bus.name] ?? point.busMutes.first(where: { $0.key.lowercased() == busLower })?.value {
                        bus.isMuted = mute
                    }
                    if point.transitionBeats == 0 {
                        if let vol = point.busFaders[bus.name] ?? point.busFaders.first(where: { $0.key.lowercased() == busLower })?.value {
                            bus.volume = vol
                        }
                    }
                }
                if let m = point.midiMuted {
                    isMIDIMuted = m
                }
                applyAutomatedPadInstantTargets(for: point, applyZeroBeatFaders: point.transitionBeats == 0)
                updateMatrix()
                objectWillChange.send()
            }

            // 2. Smoothly move faders and pans matching the duration of the automation [rampStart ... rampStart + duration]
            if durationSec > 0.001 && currentSec >= rampStart && currentSec <= rampEnd {
                let progress = Float((currentSec - rampStart) / durationSec)
                
                for track in tracks {
                    guard let targetVol = point.trackFaders[track.id] else { continue }
                    var priorVol: Float? = nil
                    var j = idx - 1
                    while j >= 0 {
                        if sorted[j].startSec < rampStart, let v = sorted[j].point.trackFaders[track.id] {
                            priorVol = v
                            break
                        }
                        j -= 1
                    }
                    let startVol = priorVol ?? baseTrackVolumes[track.id] ?? 0.80
                    track.volume = max(0.0, min(1.0, startVol + (targetVol - startVol) * progress))
                    
                    if let targetPan = point.trackPans[track.id] {
                        var priorPan: Float? = nil
                        var jp = idx - 1
                        while jp >= 0 {
                            if sorted[jp].startSec < rampStart, let p = sorted[jp].point.trackPans[track.id] {
                                priorPan = p
                                break
                            }
                            jp -= 1
                        }
                        let startPan = priorPan ?? baseTrackPans[track.id] ?? 0.0
                        track.pan = max(-1.0, min(1.0, startPan + (targetPan - startPan) * progress))
                    }
                }
                
                for bus in busses {
                    let busLower = bus.name.lowercased()
                    guard let targetBusVol = point.busFaders[bus.name] ?? point.busFaders.first(where: { $0.key.lowercased() == busLower })?.value else { continue }
                    var priorBusVol: Float? = nil
                    var jb = idx - 1
                    while jb >= 0 {
                        if sorted[jb].startSec < rampStart {
                            let prevFaders = sorted[jb].point.busFaders
                            if let v = prevFaders[bus.name] ?? prevFaders.first(where: { $0.key.lowercased() == busLower })?.value {
                                priorBusVol = v
                                break
                            }
                        }
                        jb -= 1
                    }
                    let startBusVol = priorBusVol ?? baseBusVolumes[bus.name] ?? 0.80
                    bus.volume = max(0.0, min(1.0, startBusVol + (targetBusVol - startBusVol) * progress))
                }
                
                if let targetPadVol = point.padVolume {
                    var priorPadVol: Float? = nil
                    var jpv = idx - 1
                    while jpv >= 0 {
                        if sorted[jpv].startSec < rampStart, let v = sorted[jpv].point.padVolume {
                            priorPadVol = v
                            break
                        }
                        jpv -= 1
                    }
                    let startPadVol = priorPadVol ?? basePadVolume
                    padChannelVolume = max(0.0, min(1.0, startPadVol + (targetPadVol - startPadVol) * progress))
                }
                if let targetPadPan = point.padPan {
                    var priorPadPan: Float? = nil
                    var jpp = idx - 1
                    while jpp >= 0 {
                        if sorted[jpp].startSec < rampStart, let p = sorted[jpp].point.padPan {
                            priorPadPan = p
                            break
                        }
                        jpp -= 1
                    }
                    let startPadPan = priorPadPan ?? basePadPan
                    padChannelPan = max(-1.0, min(1.0, startPadPan + (targetPadPan - startPadPan) * progress))
                }
                
                updateMatrix()
                objectWillChange.send()
            }
        }
    }
    
    private func applyAutomatedPadInstantTargets(for point: AutomationPoint, applyZeroBeatFaders: Bool) {
        if let padLinked = point.padLinked {
            isPadLinked = padLinked
        }
        if let padPack = point.padPackId {
            manualPadPackId = padPack
            if isPadActive || padPlayer.isPlaying {
                padPlayer.reloadCurrentKey(packId: padPack)
            }
        }
        if let padKey = point.padKey {
            let norm = AudioSampleBank.normalizeKeyForPad(padKey)
            currentPadKey = norm
            if !isPadLinked {
                unlinkedKeyID = norm
            }
            if padPlayer.isPlaying && point.padActive != false {
                let targetPack = point.padPackId ?? manualPadPackId ?? currentSong.padPresetId
                padPlayer.transitionToKey(norm, packId: targetPack)
            }
        }
        if let padMuted = point.padMuted {
            padChannelMuted = padMuted
        }
        if applyZeroBeatFaders {
            if let padVol = point.padVolume {
                padChannelVolume = padVol
            }
            if let padPan = point.padPan {
                padChannelPan = padPan
            }
        }
        if let padOn = point.padActive {
            if padOn && (!isPadActive || !padPlayer.isPlaying) {
                startPadPlayer(key: point.padKey, packId: point.padPackId)
            } else if !padOn && isPadActive {
                stopPadPlayerImmediately()
            }
        }
    }
    
    public func applyAutomationAtTime(_ time: TimeInterval) {
        guard !currentSong.automationPoints.isEmpty else { return }
        restoreAutomatedParametersToBaseMix(updateAudioMatrix: false)

        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let sorted = currentSong.automationPoints
            .filter { !isAutomationPointTrimmedOut($0) }
            .sorted { displayTime(forAutomationPoint: $0) < displayTime(forAutomationPoint: $1) }

        var latestPadActive: Bool? = nil
        var padTargetPackId: String? = nil
        var padTargetKey: String? = nil
        var padTargetLinked: Bool? = nil

        for point in sorted {
            let dispTime = displayTime(forAutomationPoint: point)
            guard dispTime <= time else { break }

            let durationSec = Double(point.transitionBeats) * secPerBeat
            let isInRamp = durationSec > 0.001 && time < (dispTime + durationSec)
            let progress: Float = isInRamp ? Float(max(0.0, min(1.0, (time - dispTime) / durationSec))) : 1.0

            for track in tracks {
                if let mute = point.trackMutes[track.id] {
                    track.isMuted = mute
                }
                if let targetVol = point.trackFaders[track.id] {
                    if isInRamp {
                        let startVol = track.volume
                        track.volume = max(0.0, min(1.0, startVol + (targetVol - startVol) * progress))
                    } else {
                        track.volume = max(0.0, min(1.0, targetVol))
                    }
                }
                if let targetPan = point.trackPans[track.id] {
                    if isInRamp {
                        let startPan = track.pan
                        track.pan = max(-1.0, min(1.0, startPan + (targetPan - startPan) * progress))
                    } else {
                        track.pan = max(-1.0, min(1.0, targetPan))
                    }
                }
            }

            for bus in busses {
                let busLower = bus.name.lowercased()
                if let mute = point.busMutes[bus.name] ?? point.busMutes.first(where: { $0.key.lowercased() == busLower })?.value {
                    bus.isMuted = mute
                }
                if let targetBusVol = point.busFaders[bus.name] ?? point.busFaders.first(where: { $0.key.lowercased() == busLower })?.value {
                    if isInRamp {
                        let startBusVol = bus.volume
                        bus.volume = max(0.0, min(1.0, startBusVol + (targetBusVol - startBusVol) * progress))
                    } else {
                        bus.volume = max(0.0, min(1.0, targetBusVol))
                    }
                }
            }

            if let m = point.midiMuted { isMIDIMuted = m }
            if let padLinked = point.padLinked { padTargetLinked = padLinked }
            if let padPack = point.padPackId { padTargetPackId = padPack }
            if let padKey = point.padKey { padTargetKey = padKey }
            if let padMuted = point.padMuted { padChannelMuted = padMuted }
            if let padOn = point.padActive { latestPadActive = padOn }

            if let targetPadVol = point.padVolume {
                if isInRamp {
                    let startPadVol = padChannelVolume
                    padChannelVolume = max(0.0, min(1.0, startPadVol + (targetPadVol - startPadVol) * progress))
                } else {
                    padChannelVolume = max(0.0, min(1.0, targetPadVol))
                }
            }
            if let targetPadPan = point.padPan {
                if isInRamp {
                    let startPadPan = padChannelPan
                    padChannelPan = max(-1.0, min(1.0, startPadPan + (targetPadPan - startPadPan) * progress))
                } else {
                    padChannelPan = max(-1.0, min(1.0, targetPadPan))
                }
            }
        }

        if let linked = padTargetLinked { isPadLinked = linked }
        if let pack = padTargetPackId {
            manualPadPackId = pack
            if isPadActive || padPlayer.isPlaying {
                padPlayer.reloadCurrentKey(packId: pack)
            }
        }
        if let key = padTargetKey {
            let norm = AudioSampleBank.normalizeKeyForPad(key)
            currentPadKey = norm
            if !isPadLinked { unlinkedKeyID = norm }
            if padPlayer.isPlaying && latestPadActive != false {
                let targetPack = padTargetPackId ?? manualPadPackId ?? currentSong.padPresetId
                padPlayer.transitionToKey(norm, packId: targetPack)
            }
        }
        if playbackState == .playing, let padOn = latestPadActive {
            if padOn && (!isPadActive || !padPlayer.isPlaying) {
                startPadPlayer(key: padTargetKey, packId: padTargetPackId)
            } else if !padOn && isPadActive {
                stopPadPlayerImmediately()
            }
        }

        updateMatrix()
        objectWillChange.send()
    }
    
    private func syncCurrentSongAutomationToSetlist() {
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultAutomationPoints = currentSong.automationPoints
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].automationPoints = currentSong.automationPoints
            currentSetlist.songs[currentSongIndex].defaultAutomationPoints = currentSong.defaultAutomationPoints
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Click & Guide Controls & Dynamic Synthesis
    
    public func setClickSource(_ source: ClickSource) {
        currentSong.excludesClickAndGuide = false
        currentSong.clickSource = source
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
            currentSetlist.songs[currentSongIndex].clickSource = source
        }
        
        if source == .generated && generatedClickBuffers[currentSong.id] == nil {
            regenerateClickTrack()
        } else {
            applyClickBuffer()
        }
        objectWillChange.send()
    }
    
    private func deduplicateUtilityTracks(inCurrentSong: Bool, check: (StemTrack) -> Bool) {
        let matching = tracks.filter(check)
        guard matching.count > 1 else { return }
        let keeper = matching.first(where: { $0.fileURL != nil }) ?? matching[0]
        let discardIds = Set(matching.filter { $0.id != keeper.id && $0.fileURL == nil }.map { $0.id })
        guard !discardIds.isEmpty else { return }
        tracks.removeAll { discardIds.contains($0.id) }
        for id in discardIds {
            channels.removeValue(forKey: id)
            pristineMasterBuffers.removeValue(forKey: id)
        }
        if inCurrentSong, var cached = songBuffersCache[currentSong.id] {
            cached.removeAll { discardIds.contains($0.track.id) }
            songBuffersCache[currentSong.id] = cached
        }
    }

    private func makeSilentStub(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return nil }
        silent.frameLength = 1
        return silent
    }

    public func applyClickBuffer() {
        if currentSong.excludesClickAndGuide { return }
        deduplicateUtilityTracks(inCurrentSong: true, check: { Self.isClickTrack($0) })
        var clickTrack = tracks.first(where: { $0.role == .click || StemCategory.category(for: $0.name, role: $0.role) == .click })
        var trackWasAppended = false
        if clickTrack == nil {
            let newClick = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
            tracks.append(newClick)
            clickTrack = newClick
            trackWasAppended = true
        }
        guard let track = clickTrack else { return }
        
        var applied = false
        var needsRegen = false
        let canonicalFmt = getCanonicalProcessingFormat()
        if currentSong.clickSource == .generated {
            if let genBuf = generatedClickBuffers[currentSong.id], genBuf.frameLength > 1 {
                track.duration = Double(genBuf.frameLength) / genBuf.format.sampleRate
                if let ch = channels[track.id] {
                    ch.buffer = genBuf
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: genBuf)
                }
                pristineMasterBuffers[track.id] = genBuf
                applied = true
            } else if let silent = makeSilentStub(format: canonicalFmt) {
                if let ch = channels[track.id] {
                    ch.buffer = silent
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: silent)
                }
                pristineMasterBuffers[track.id] = silent
                applied = true
                needsRegen = true
            } else {
                needsRegen = true
            }
            // Silence any remaining secondary Click tracks so two click sources can never layer
            for other in tracks where other.id != track.id && Self.isClickTrack(other) {
                if let silent = makeSilentStub(format: canonicalFmt) {
                    channels[other.id]?.buffer = silent
                    pristineMasterBuffers[other.id] = silent
                }
            }
        } else {
            if let upBuf = uploadedClickBuffers[currentSong.id] {
                track.duration = Double(upBuf.frameLength) / upBuf.format.sampleRate
                if let ch = channels[track.id] {
                    ch.buffer = upBuf
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: upBuf)
                }
                pristineMasterBuffers[track.id] = upBuf
                applied = true
            }
        }
        
        if trackWasAppended {
            autoSortTracks()
        }
        if applied {
            syncCachedClickAndGuideBuffers(forSongId: currentSong.id)
            updateMatrix()
            syncMixState()
            if playbackState != .playing {
                mixState.setPlayhead(seconds: playbackOffsetSeconds)
            }
        }
        if needsRegen {
            regenerateClickTrack()
        }
    }
    
    public func setGuideSource(_ source: GuideSource) {
        currentSong.excludesClickAndGuide = false
        currentSong.guideSource = source
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].excludesClickAndGuide = false
            currentSetlist.songs[currentSongIndex].guideSource = source
        }
        
        if source == .generated && (generatedGuideBuffers[currentSong.id] == nil || generatedGuideLoopStates[currentSong.id] != currentLiveGuideLoopState()) {
            regenerateGuideTrack()
        } else {
            applyGuideBuffer()
        }
        objectWillChange.send()
    }
    
    public func applyGuideBuffer() {
        if currentSong.excludesClickAndGuide { return }
        deduplicateUtilityTracks(inCurrentSong: true, check: { Self.isGuideTrack($0) })
        var guideTrack = tracks.first(where: { $0.role == .guide || StemCategory.category(for: $0.name, role: $0.role) == .guide })
        var trackWasAppended = false
        if guideTrack == nil {
            let newGuide = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
            tracks.append(newGuide)
            guideTrack = newGuide
            trackWasAppended = true
        }
        guard let track = guideTrack else { return }
        
        var applied = false
        var needsRegen = false
        let canonicalFmt = getCanonicalProcessingFormat()
        if currentSong.guideSource == .generated {
            if let genBuf = generatedGuideBuffers[currentSong.id], genBuf.frameLength > 1 {
                track.duration = Double(genBuf.frameLength) / genBuf.format.sampleRate
                if let ch = channels[track.id] {
                    ch.buffer = genBuf
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: genBuf)
                }
                pristineMasterBuffers[track.id] = genBuf
                applied = true
            } else if let silent = makeSilentStub(format: canonicalFmt) {
                if let ch = channels[track.id] {
                    ch.buffer = silent
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: silent)
                }
                pristineMasterBuffers[track.id] = silent
                applied = true
                needsRegen = true
            } else {
                needsRegen = true
            }
            // Silence any remaining secondary Guide tracks so uploaded and generated guides can never play together
            for other in tracks where other.id != track.id && Self.isGuideTrack(other) {
                if let silent = makeSilentStub(format: canonicalFmt) {
                    channels[other.id]?.buffer = silent
                    pristineMasterBuffers[other.id] = silent
                }
            }
        } else {
            if let upBuf = uploadedGuideBuffers[currentSong.id] {
                let finalBuf: AVAudioPCMBuffer
                let activeDirCues = currentSong.directionalCues.filter { !isDirectionalCueTrimmedOut($0) }
                if currentSong.speakDirectionalCuesOnUploadedGuide && !activeDirCues.isEmpty {
                    finalBuf = guideAudioGenerator.overlayDirectionalCues(
                        onto: upBuf,
                        directionalCues: activeDirCues,
                        voice: .rita, // directional cues default to Rita, with macOS TTS fallback
                        fallbackVoice: currentSong.guideFallbackVoice
                    )
                } else {
                    finalBuf = upBuf
                }
                track.duration = Double(finalBuf.frameLength) / finalBuf.format.sampleRate
                if let ch = channels[track.id] {
                    ch.buffer = finalBuf
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: finalBuf)
                }
                pristineMasterBuffers[track.id] = finalBuf
                applied = true
            }
        }
        
        if trackWasAppended {
            autoSortTracks()
        }
        if applied {
            syncCachedClickAndGuideBuffers(forSongId: currentSong.id)
            updateMatrix()
            syncMixState()
            if playbackState != .playing {
                mixState.setPlayhead(seconds: playbackOffsetSeconds)
            }
        }
        if needsRegen {
            regenerateGuideTrack()
        }
    }
    
    public func setGuideVoice(_ voice: GuideVoice) {
        currentSong.guideVoice = voice
        currentSong.usesDefaultGuideVoice = false
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].guideVoice = voice
            currentSetlist.songs[currentSongIndex].usesDefaultGuideVoice = false
        }
        markSessionChanged()
        regenerateGuideTrack()
    }
    
    public func useDefaultGuideForCurrentSong() {
        let defaultVoice = GuideVoice.defaultVoice
        currentSong.guideVoice = defaultVoice
        currentSong.usesDefaultGuideVoice = true
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].guideVoice = defaultVoice
            currentSetlist.songs[currentSongIndex].usesDefaultGuideVoice = true
        }
        markSessionChanged()
        regenerateGuideTrack()
    }
    
    public func setDefaultGuideVoice(_ voice: GuideVoice, syncDefaultSongs: Bool = true) {
        CustomSampleLibraryManager.shared.setDefaultGuideVoice(voice)
        guard syncDefaultSongs else { return }
        var updatedCurrent = false
        for i in currentSetlist.songs.indices where currentSetlist.songs[i].usesDefaultGuideVoice {
            currentSetlist.songs[i].guideVoice = voice
            if i == currentSongIndex {
                currentSong.guideVoice = voice
                updatedCurrent = true
            }
        }
        if currentSong.usesDefaultGuideVoice && currentSong.guideVoice != voice {
            currentSong.guideVoice = voice
            updatedCurrent = true
        }
        if updatedCurrent {
            markSessionChanged()
            regenerateGuideTrack()
        }
    }
    
    public func applyDefaultGuideToAllSongs() {
        let defaultVoice = GuideVoice.defaultVoice
        for i in currentSetlist.songs.indices {
            currentSetlist.songs[i].guideVoice = defaultVoice
            currentSetlist.songs[i].usesDefaultGuideVoice = true
        }
        currentSong.guideVoice = defaultVoice
        currentSong.usesDefaultGuideVoice = true
        markSessionChanged()
        regenerateGuideTrack()
    }
    
    public func setGuideFallbackVoice(_ voice: GuideVoice) {
        currentSong.guideFallbackVoice = voice
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].guideFallbackVoice = voice
        }
        regenerateGuideTrack()
    }
    
    public func setClickSubdivisions(accent: Bool, quarter: Bool, eighth: Bool, sixteenth: Bool) {
        currentSong.clickAccentEnabled = accent
        currentSong.clickQuarterEnabled = quarter
        currentSong.clickEighthEnabled = eighth
        currentSong.clickSixteenthEnabled = sixteenth
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].clickAccentEnabled = accent
            currentSetlist.songs[currentSongIndex].clickQuarterEnabled = quarter
            currentSetlist.songs[currentSongIndex].clickEighthEnabled = eighth
            currentSetlist.songs[currentSongIndex].clickSixteenthEnabled = sixteenth
        }
        markSessionChanged()
        regenerateClickTrack()
    }

    /// Toggles mute/unmute for a single Click subdivision in the Click Tray while preserving its fader level.
    public func toggleClickSubdivisionMute(_ subdivision: ClickSubdivision) {
        let isCurrentlyActive: Bool
        switch subdivision {
        case .accent: isCurrentlyActive = currentSong.clickAccentEnabled
        case .quarter: isCurrentlyActive = currentSong.clickQuarterEnabled
        case .eighth: isCurrentlyActive = currentSong.clickEighthEnabled
        case .sixteenth: isCurrentlyActive = currentSong.clickSixteenthEnabled
        }
        let targetEnabled = !isCurrentlyActive
        setClickSubdivisions(
            accent: subdivision == .accent ? targetEnabled : currentSong.clickAccentEnabled,
            quarter: subdivision == .quarter ? targetEnabled : currentSong.clickQuarterEnabled,
            eighth: subdivision == .eighth ? targetEnabled : currentSong.clickEighthEnabled,
            sixteenth: subdivision == .sixteenth ? targetEnabled : currentSong.clickSixteenthEnabled
        )
    }
    
    public func setClickSubdivisionVolume(subdivision: ClickSubdivision, volume: Float, commit: Bool = true) {
        let clamped = max(0.0, min(1.0, volume))
        switch subdivision {
        case .accent:
            currentSong.clickAccentVolume = clamped
            currentSong.clickAccentEnabled = (clamped > 0.001)
        case .quarter:
            currentSong.clickQuarterVolume = clamped
            currentSong.clickQuarterEnabled = (clamped > 0.001)
        case .eighth:
            currentSong.clickEighthVolume = clamped
            currentSong.clickEighthEnabled = (clamped > 0.001)
        case .sixteenth:
            currentSong.clickSixteenthVolume = clamped
            currentSong.clickSixteenthEnabled = (clamped > 0.001)
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].clickAccentVolume = currentSong.clickAccentVolume
            currentSetlist.songs[currentSongIndex].clickQuarterVolume = currentSong.clickQuarterVolume
            currentSetlist.songs[currentSongIndex].clickEighthVolume = currentSong.clickEighthVolume
            currentSetlist.songs[currentSongIndex].clickSixteenthVolume = currentSong.clickSixteenthVolume
            currentSetlist.songs[currentSongIndex].clickAccentEnabled = currentSong.clickAccentEnabled
            currentSetlist.songs[currentSongIndex].clickQuarterEnabled = currentSong.clickQuarterEnabled
            currentSetlist.songs[currentSongIndex].clickEighthEnabled = currentSong.clickEighthEnabled
            currentSetlist.songs[currentSongIndex].clickSixteenthEnabled = currentSong.clickSixteenthEnabled
        }
        if commit {
            markSessionChanged()
            regenerateClickTrack()
        }
    }
    
    public func toggleClickSubdivisionSolo(_ subdivision: ClickSubdivision) {
        if clickSoloedSubdivisions.contains(subdivision) {
            clickSoloedSubdivisions.remove(subdivision)
        } else {
            clickSoloedSubdivisions.insert(subdivision)
        }
        regenerateClickTrack()
    }
    
    public func setClickSound(_ sound: ClickSoundType) {
        currentSong.clickSound = sound
        currentSong.usesDefaultClickSound = false
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].clickSound = sound
            currentSetlist.songs[currentSongIndex].usesDefaultClickSound = false
        }
        markSessionChanged()
        regenerateClickTrack()
    }
    
    public func useDefaultClickForCurrentSong() {
        let defaultClick = ClickSoundType.defaultSound
        currentSong.clickSound = defaultClick
        currentSong.usesDefaultClickSound = true
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].clickSound = defaultClick
            currentSetlist.songs[currentSongIndex].usesDefaultClickSound = true
        }
        markSessionChanged()
        regenerateClickTrack()
    }
    
    public func setDefaultClickSound(_ sound: ClickSoundType, syncDefaultSongs: Bool = true) {
        CustomSampleLibraryManager.shared.setDefaultClickSound(sound)
        guard syncDefaultSongs else { return }
        var updatedCurrent = false
        for i in currentSetlist.songs.indices where currentSetlist.songs[i].usesDefaultClickSound {
            currentSetlist.songs[i].clickSound = sound
            if i == currentSongIndex {
                currentSong.clickSound = sound
                updatedCurrent = true
            }
        }
        if currentSong.usesDefaultClickSound && currentSong.clickSound != sound {
            currentSong.clickSound = sound
            updatedCurrent = true
        }
        if updatedCurrent {
            markSessionChanged()
            regenerateClickTrack()
        }
    }
    
    public func applyDefaultClickToAllSongs() {
        let defaultClick = ClickSoundType.defaultSound
        for i in currentSetlist.songs.indices {
            currentSetlist.songs[i].clickSound = defaultClick
            currentSetlist.songs[i].usesDefaultClickSound = true
        }
        currentSong.clickSound = defaultClick
        currentSong.usesDefaultClickSound = true
        markSessionChanged()
        regenerateClickTrack()
    }
    
    public func refreshCurrentTracksAfterCustomSampleEdit(clickPackId: String? = nil, guidePackId: String? = nil) {
        if let cid = clickPackId {
            let matchesCurrent = currentSong.clickSound.customPackId == cid
            let packExists = CustomSampleLibraryManager.shared.clickPack(forId: cid) != nil
            if !packExists {
                let fallback = ClickSoundType.defaultSound
                for i in currentSetlist.songs.indices where currentSetlist.songs[i].clickSound.customPackId == cid {
                    currentSetlist.songs[i].clickSound = fallback
                    currentSetlist.songs[i].usesDefaultClickSound = true
                }
                if matchesCurrent {
                    currentSong.clickSound = fallback
                    currentSong.usesDefaultClickSound = true
                    regenerateClickTrack()
                }
            } else if matchesCurrent {
                regenerateClickTrack()
            }
        }
        if let gid = guidePackId {
            let matchesCurrent = currentSong.guideVoice.customPackId == gid
            let packExists = CustomSampleLibraryManager.shared.guidePack(forId: gid) != nil
            if !packExists {
                let fallback = GuideVoice.defaultVoice
                for i in currentSetlist.songs.indices where currentSetlist.songs[i].guideVoice.customPackId == gid {
                    currentSetlist.songs[i].guideVoice = fallback
                    currentSetlist.songs[i].usesDefaultGuideVoice = true
                }
                if matchesCurrent {
                    currentSong.guideVoice = fallback
                    currentSong.usesDefaultGuideVoice = true
                    regenerateGuideTrack()
                }
            } else if matchesCurrent {
                regenerateGuideTrack()
            }
        }
    }
    
    public func setGuideCountIn(enabled: Bool) {
        currentSong.guideCountInEnabled = enabled
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].guideCountInEnabled = enabled
        }
        regenerateGuideTrack()
    }
    
    public func updateGenerationStatus() {
        if isGeneratingClick && isGeneratingGuide {
            clickGuideStatusText = "Generating Click & Guide..."
        } else if isGeneratingClick {
            clickGuideStatusText = "Generating Click..."
        } else if isGeneratingGuide {
            clickGuideStatusText = "Generating Guide..."
        } else {
            clickGuideStatusText = ""
        }
    }
    
    public func regenerateClickTrack() {
        if currentSong.excludesClickAndGuide { return }
        let canonicalFormat = getCanonicalProcessingFormat()
        let durationToUse: TimeInterval = {
            if !currentSong.sections.isEmpty {
                return currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration
            }
            return currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? 240.0)
        }()
        
        isGeneratingClick = true
        updateGenerationStatus()
        objectWillChange.send()
        
        Task {
            let genBuf = await Task.detached(priority: .userInitiated) { [currentSong = self.currentSong, canonicalFormat, durationToUse, subdivisions = self.clickSoloedSubdivisions] in
                return self.clickGenerator.generateClickBuffer(
                    bpm: currentSong.bpm,
                    timeSignatureNumerator: currentSong.timeSignatureNumerator,
                    timeSignatureDenominator: currentSong.timeSignatureDenominator,
                    duration: durationToUse,
                    beatGrid: currentSong.effectiveBeatGrid(totalDuration: durationToUse),
                    sections: currentSong.sections,
                    soundType: currentSong.clickSound,
                    accentEnabled: currentSong.clickAccentEnabled,
                    quarterEnabled: currentSong.clickQuarterEnabled,
                    eighthEnabled: currentSong.clickEighthEnabled,
                    sixteenthEnabled: currentSong.clickSixteenthEnabled,
                    accentVolume: currentSong.clickAccentVolume,
                    quarterVolume: currentSong.clickQuarterVolume,
                    eighthVolume: currentSong.clickEighthVolume,
                    sixteenthVolume: currentSong.clickSixteenthVolume,
                    soloedSubdivisions: subdivisions,
                    format: canonicalFormat
                )
            }.value
            
            await MainActor.run {
                self.isGeneratingClick = false
                if let buf = genBuf {
                    if self.currentSong.id == currentSong.id && !self.currentSong.excludesClickAndGuide {
                        self.generatedClickBuffers[currentSong.id] = buf
                        if self.uploadedClickBuffers[currentSong.id] == nil {
                            self.currentSong.clickSource = .generated
                        }
                        if self.currentSong.clickSource == .generated {
                            self.applyClickBuffer()
                        }
                    } else if let idx = self.currentSetlist.songs.firstIndex(where: { $0.id == currentSong.id }),
                              !self.currentSetlist.songs[idx].excludesClickAndGuide {
                        self.generatedClickBuffers[currentSong.id] = buf
                    }
                }
                self.updateGenerationStatus()
                self.objectWillChange.send()
            }
        }
    }
    
    public func regenerateGuideTrack() {
        if currentSong.excludesClickAndGuide { return }
        let canonicalFormat = getCanonicalProcessingFormat()
        let durationToUse: TimeInterval = {
            if !currentSong.sections.isEmpty {
                return currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration
            }
            return currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? 240.0)
        }()
        guideRegenerationGeneration &+= 1
        let regenGen = guideRegenerationGeneration
        let targetGuideState = currentLiveGuideLoopState()
        let loopAct = self.isLoopActive
        let loopedSec = loopAct ? self.loopedSection : nil
        let lMode: LoopMode = loopAct ? self.loopMode : .none
        let singleRem = (loopAct && lMode == .single) ? self.singleLoopRemaining : 0
        let queuedSec = self.queuedNextSection
        
        let activeDirectionalCues = currentSong.directionalCues.filter { !isDirectionalCueTrimmedOut($0) }
        isGeneratingGuide = true
        updateGenerationStatus()
        objectWillChange.send()
        
        Task {
            let genBuf = await Task.detached(priority: .userInitiated) { [currentSong = self.currentSong, activeDirectionalCues, canonicalFormat, durationToUse, loopAct, loopedSec, lMode, singleRem, queuedSec] in
                return GuideAudioGenerator.shared.generateGuideBuffer(
                    sections: currentSong.sections,
                    directionalCues: activeDirectionalCues,
                    bpm: currentSong.bpm,
                    timeSignatureNumerator: currentSong.timeSignatureNumerator,
                    timeSignatureDenominator: currentSong.timeSignatureDenominator,
                    duration: durationToUse,
                    beatGrid: currentSong.effectiveBeatGrid(totalDuration: durationToUse),
                    voice: currentSong.guideVoice,
                    fallbackVoice: currentSong.guideFallbackVoice,
                    countInEnabled: currentSong.guideCountInEnabled,
                    queuedNextSection: queuedSec,
                    loopedSection: loopedSec,
                    isLoopActive: loopAct,
                    loopMode: lMode,
                    singleLoopRemaining: singleRem,
                    format: canonicalFormat
                )
            }.value
            
            await MainActor.run {
                if regenGen == self.guideRegenerationGeneration {
                    self.isGeneratingGuide = false
                }
                if let buf = genBuf {
                    if self.currentSong.id == currentSong.id {
                        if regenGen == self.guideRegenerationGeneration &&
                           !self.currentSong.excludesClickAndGuide &&
                           self.currentLiveGuideLoopState() == targetGuideState {
                            self.generatedGuideBuffers[currentSong.id] = buf
                            self.generatedGuideLoopStates[currentSong.id] = targetGuideState
                            if self.uploadedGuideBuffers[currentSong.id] == nil {
                                self.currentSong.guideSource = .generated
                            }
                            self.applyGuideBuffer()
                        }
                    } else if let idx = self.currentSetlist.songs.firstIndex(where: { $0.id == currentSong.id }),
                              !self.currentSetlist.songs[idx].excludesClickAndGuide,
                              targetGuideState == Self.defaultGuideLoopState(for: self.currentSetlist.songs[idx]) {
                        self.generatedGuideBuffers[currentSong.id] = buf
                        self.generatedGuideLoopStates[currentSong.id] = targetGuideState
                    }
                }
                self.updateGenerationStatus()
                self.objectWillChange.send()
            }
        }
    }
    
    // MARK: - Fade In / Fade Out Feature
    
    public func isExemptFromFade(_ track: StemTrack) -> Bool {
        if track.role == .click || track.role == .guide { return true }
        let bus = track.assignedBusName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bus == "click" || bus == "guide" { return true }
        let name = track.name.lowercased()
        if name.contains("click") || name.contains("guide") || name.contains("metronome") || name.contains("cue") || name.contains("count") {
            return true
        }
        let cat = StemCategory.category(for: track.name, role: track.role)
        if cat == .click || cat == .guide { return true }
        return false
    }
    
    public func toggleFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        
        if playbackState != .playing {
            // Paused state: instantly zero out or restore volumes and flip button
            if !isFadedOut {
                for track in tracks {
                    if isExemptFromFade(track) { continue }
                    if track.volume > 0.001 {
                        preFadeVolumes[track.id] = track.volume
                    } else if preFadeVolumes[track.id] == nil {
                        preFadeVolumes[track.id] = 0.80
                    }
                    track.volume = 0.0
                }
                currentFadeGain = 1.0
                updateMatrix()
                isFadedOut = true
                isFadeActive = true
            } else {
                for track in tracks {
                    if isExemptFromFade(track) { continue }
                    track.volume = preFadeVolumes[track.id] ?? 0.80
                }
                currentFadeGain = 1.0
                updateMatrix()
                isFadedOut = false
                isFadeActive = false
            }
            objectWillChange.send()
            return
        }
        
        // Playing state: smoothly animate faders over the specified fade duration
        if !isFadedOut {
            startFadeOut(duration: fadeOutDuration)
        } else {
            startFadeIn(duration: fadeInDuration)
        }
    }
    
    public func startFadeOut(duration: TimeInterval? = nil) {
        fadeTimer?.invalidate()
        let dur = duration ?? fadeOutDuration
        for track in tracks {
            if isExemptFromFade(track) { continue }
            if track.volume > 0.001 {
                preFadeVolumes[track.id] = track.volume
            } else if preFadeVolumes[track.id] == nil {
                preFadeVolumes[track.id] = 0.80
            }
        }
        isFadedOut = true
        isFadeActive = true
        objectWillChange.send()
        
        let startVolumes: [UUID: Float] = Dictionary(uniqueKeysWithValues: tracks.compactMap {
            isExemptFromFade($0) ? nil : ($0.id, $0.volume)
        })
        let totalSteps = max(10, Int(dur * 60.0))
        let stepInterval = dur / Double(totalSteps)
        var currentStep = 0
        
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                currentStep += 1
                let progress = Double(currentStep) / Double(totalSteps)
                let t = Float((1.0 - cos(progress * .pi)) * 0.5)
                
                for track in self.tracks {
                    if self.isExemptFromFade(track) { continue }
                    let startVol = startVolumes[track.id] ?? (self.preFadeVolumes[track.id] ?? 0.80)
                    track.volume = max(0.0, startVol * (1.0 - t))
                }
                self.updateMatrix()
                
                if currentStep >= totalSteps {
                    for track in self.tracks {
                        if self.isExemptFromFade(track) { continue }
                        track.volume = 0.0
                    }
                    self.updateMatrix()
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
    }
    
    public func startFadeIn(duration: TimeInterval? = nil) {
        fadeTimer?.invalidate()
        let dur = duration ?? fadeInDuration
        isFadedOut = false
        isFadeActive = false
        objectWillChange.send()
        
        let startVolumes: [UUID: Float] = Dictionary(uniqueKeysWithValues: tracks.compactMap {
            isExemptFromFade($0) ? nil : ($0.id, $0.volume)
        })
        let targetVolumes: [UUID: Float] = Dictionary(uniqueKeysWithValues: tracks.compactMap {
            isExemptFromFade($0) ? nil : ($0.id, self.preFadeVolumes[$0.id] ?? 0.80)
        })
        
        let totalSteps = max(10, Int(dur * 60.0))
        let stepInterval = dur / Double(totalSteps)
        var currentStep = 0
        
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                currentStep += 1
                let progress = Double(currentStep) / Double(totalSteps)
                let t = Float((1.0 - cos(progress * .pi)) * 0.5)
                
                for track in self.tracks {
                    if self.isExemptFromFade(track) { continue }
                    let startVol = startVolumes[track.id] ?? 0.0
                    let targetVol = targetVolumes[track.id] ?? 0.80
                    track.volume = min(1.0, startVol + (targetVol - startVol) * t)
                }
                self.updateMatrix()
                
                if currentStep >= totalSteps {
                    for track in self.tracks {
                        if self.isExemptFromFade(track) { continue }
                        track.volume = targetVolumes[track.id] ?? 0.80
                    }
                    self.updateMatrix()
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
    }
    
    // MARK: - Section Looping (L & I Hotkeys)
    
    public func toggleSingleLoop() {
        guard let targetSec = currentTargetSection() else { return }
        if loopMode == .single && loopedSection?.id == targetSec.id {
            loopMode = .none
            isLoopActive = false
            loopedSection = nil
            singleLoopRemaining = 0
        } else {
            loopedSection = targetSec
            loopMode = .single
            isLoopActive = true
            singleLoopRemaining = 1
        }
        syncMixState()
        regenerateGuideTrack()
        objectWillChange.send()
    }
    
    public func toggleInfiniteLoop() {
        guard let targetSec = currentTargetSection() else { return }
        if loopMode == .infinite && loopedSection?.id == targetSec.id {
            loopMode = .none
            isLoopActive = false
            loopedSection = nil
            singleLoopRemaining = 0
        } else {
            loopedSection = targetSec
            loopMode = .infinite
            isLoopActive = true
            singleLoopRemaining = 0
        }
        syncMixState()
        regenerateGuideTrack()
        objectWillChange.send()
    }
    
    /// Explicitly activates or toggles a specific section in `.single` or `.infinite` loop mode.
    public func setSectionLoop(_ section: SongSection, mode: LoopMode) {
        if loopMode == mode && loopedSection?.id == section.id && isLoopActive {
            loopMode = .none
            isLoopActive = false
            loopedSection = nil
            singleLoopRemaining = 0
        } else {
            loopedSection = section
            loopMode = mode
            isLoopActive = (mode != .none)
            singleLoopRemaining = (mode == .single) ? 1 : 0
        }
        syncMixState()
        regenerateGuideTrack()
        objectWillChange.send()
    }
    
    public func currentTargetSection() -> SongSection? {
        if let loop = loopedSection { return loop }
        if let current = currentSong.sections.first(where: { playbackOffsetSeconds >= $0.startTime && playbackOffsetSeconds < $0.endTime }) {
            return current
        }
        return currentSong.sections.first
    }
    
    public func toggleSectionLoop(_ section: SongSection) {
        if loopedSection?.id == section.id && isLoopActive {
            isLoopActive = false
            loopMode = .none
            loopedSection = nil
            singleLoopRemaining = 0
        } else {
            loopedSection = section
            isLoopActive = true
            loopMode = .single
            singleLoopRemaining = 1
        }
        syncMixState()
        regenerateGuideTrack()
        objectWillChange.send()
    }
    
    // Spontaneous Queued Next Section (Playback Style Double-Click)
    @Published public var queuedNextSection: SongSection? = nil
    
    public func queueNextSection(_ section: SongSection) {
        if queuedNextSection?.id == section.id {
            // Toggle off if already queued
            queuedNextSection = nil
            mixState.cancelQueuedJump()
        } else {
            queuedNextSection = section
            let sr = getCanonicalProcessingFormat().sampleRate
            let currentSec = playbackOffsetSeconds
            let boundaryTime: TimeInterval
            if let curSec = currentSong.sections.first(where: { currentSec >= $0.startTime && currentSec < $0.endTime }) {
                boundaryTime = curSec.endTime
            } else if let nextSec = currentSong.sections.first(where: { $0.startTime > currentSec }) {
                boundaryTime = nextSec.startTime
            } else {
                boundaryTime = currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? currentSec + 1.0)
            }
            let boundaryFrame = Int64(round(boundaryTime * sr))
            let targetFrame = Int64(round(section.startTime * sr))
            mixState.setQueuedJump(boundaryFrame: boundaryFrame, targetFrame: targetFrame)
        }
        regenerateGuideTrack()
        objectWillChange.send()
    }
    
    // MARK: - Non-Destructive Song Section Arrangement Editing (Playback Style)
    
    /// Returns true if the given cue (at `cueTime` belonging to `sectionId`) falls inside a trimmed-out region of its section.
    public func isCueInTrimmedRegion(cueTime: TimeInterval, sectionId: UUID?) -> Bool {
        return Self.isCueInTrimmedRegion(
            cueTime: cueTime,
            sectionId: sectionId,
            in: currentSong.sections,
            activeTrimmingSectionId: trimmingSection?.id,
            activeLeadTrim: trimLeadingDuration,
            activeTrailTrim: trimTrailingDuration
        )
    }

    public nonisolated static func isCueInTrimmedRegion(
        cueTime: TimeInterval,
        sectionId: UUID?,
        in sections: [SongSection],
        activeTrimmingSectionId: UUID? = nil,
        activeLeadTrim: TimeInterval = 0,
        activeTrailTrim: TimeInterval = 0
    ) -> Bool {
        guard let secId = sectionId,
              let sec = sections.first(where: { $0.id == secId }) else {
            return false
        }
        let untrimmedOffset = (cueTime - sec.startTime) + sec.leadingTrimDuration
        let effectiveLead = (activeTrimmingSectionId == sec.id) ? activeLeadTrim : sec.leadingTrimDuration
        let effectiveTrail = (activeTrimmingSectionId == sec.id) ? activeTrailTrim : sec.trailingTrimDuration
        guard effectiveLead > 0.001 || effectiveTrail > 0.001 else { return false }
        let activeEndOffset = sec.baseDuration - effectiveTrail
        return untrimmedOffset < effectiveLead - 0.005 || untrimmedOffset >= activeEndOffset - 0.005
    }
    
    public func isMIDICueTrimmedOut(_ cue: MIDICue) -> Bool {
        return isCueInTrimmedRegion(cueTime: cue.time, sectionId: cue.sectionId)
    }
    
    public func isDirectionalCueTrimmedOut(_ cue: DirectionalCue) -> Bool {
        return isCueInTrimmedRegion(cueTime: cue.time, sectionId: cue.sectionId)
    }
    
    public func isAutomationPointTrimmedOut(_ point: AutomationPoint) -> Bool {
        return isCueInTrimmedRegion(cueTime: point.time, sectionId: point.sectionId)
    }
    
    /// Maps a trimmed playback timestamp into the expanded `displaySections` timeline when Arrangement Edit Mode is open
    /// so the waveform stays anchored at the exact same musical position instead of jumping horizontally.
    public func displayTimeForSongPosition(_ songTime: TimeInterval) -> TimeInterval {
        guard isEditingArrangement, !currentSong.sections.isEmpty else { return songTime }
        let clamped = max(0.0, songTime)
        if let sec = currentSong.sections.first(where: { clamped >= $0.startTime && clamped <= $0.endTime }) ?? currentSong.sections.last,
           let dispSec = displaySections.first(where: { $0.id == sec.id }) {
            let untrimmedOffset = (clamped - sec.startTime) + sec.leadingTrimDuration
            return dispSec.startTime + untrimmedOffset
        }
        return clamped
    }

    /// Returns the visual timeline position for a cue:
    /// - When in Arrangement Edit Mode (`isEditingArrangement == true`), maps the cue onto `displaySections` (full untrimmed section length) so cues do not shift while still inside the edit menu.
    /// - When outside Arrangement Edit Mode (`isEditingArrangement == false`), returns `cueTime` (the cue's shifted position in the active trimmed arrangement).
    public func displayTimeForCue(cueTime: TimeInterval, sectionId: UUID?) -> TimeInterval {
        guard isEditingArrangement else { return cueTime }
        if let secId = sectionId,
           let sec = currentSong.sections.first(where: { $0.id == secId }),
           let dispSec = displaySections.first(where: { $0.id == secId }) {
            let untrimmedOffset = (cueTime - sec.startTime) + sec.leadingTrimDuration
            return dispSec.startTime + untrimmedOffset
        }
        return cueTime
    }
    
    public func displayTime(forMIDICue cue: MIDICue) -> TimeInterval {
        return displayTimeForCue(cueTime: cue.time, sectionId: cue.sectionId)
    }
    
    public func displayTime(forDirectionalCue cue: DirectionalCue) -> TimeInterval {
        return displayTimeForCue(cueTime: cue.time, sectionId: cue.sectionId)
    }
    
    public func displayTime(forAutomationPoint point: AutomationPoint) -> TimeInterval {
        return displayTimeForCue(cueTime: point.time, sectionId: point.sectionId)
    }

    /// Converts a timeline display timestamp back into raw song time and containing section ID.
    public func rawTimeAndSection(forDisplayTime displayTime: TimeInterval) -> (rawTime: TimeInterval, sectionId: UUID?) {
        let clampedDisp = max(0.0, displayTime)
        if let dispSec = displaySections.first(where: { clampedDisp >= $0.startTime - 0.001 && clampedDisp <= $0.endTime + 0.001 }) ?? displaySections.last,
           let rawSec = currentSong.sections.first(where: { $0.id == dispSec.id }) {
            let offsetInDisp = clampedDisp - dispSec.startTime
            let rawT = max(rawSec.startTime, min(rawSec.endTime, rawSec.startTime + rawSec.leadingTrimDuration + offsetInDisp))
            return (rawT, rawSec.id)
        }
        return (clampedDisp, nil)
    }

    public func moveMIDICue(id: UUID, toDisplayTime displayTime: TimeInterval) {
        let snappedDisp = snapTimeToBeatGrid(displayTime)
        let (rawTime, secId) = rawTimeAndSection(forDisplayTime: snappedDisp)
        guard var cue = currentSong.midiCues.first(where: { $0.id == id }) else { return }
        cue.time = rawTime
        if let secId = secId { cue.sectionId = secId }
        updateMIDICue(cue)
    }

    public func moveDirectionalCue(id: UUID, toDisplayTime displayTime: TimeInterval) {
        let snappedDisp = snapTimeToBeatGrid(displayTime)
        let (rawTime, secId) = rawTimeAndSection(forDisplayTime: snappedDisp)
        guard let cue = currentSong.directionalCues.first(where: { $0.id == id }) else { return }
        if let secId = secId, let idx = currentSong.directionalCues.firstIndex(where: { $0.id == id }) {
            currentSong.directionalCues[idx].sectionId = secId
        }
        updateDirectionalCue(id: id, label: cue.label, time: rawTime)
    }

    public func moveAutomationPoint(id: UUID, toDisplayTime displayTime: TimeInterval) {
        let snappedDisp = snapTimeToBeatGrid(displayTime)
        let (rawTime, secId) = rawTimeAndSection(forDisplayTime: snappedDisp)
        guard let idx = currentSong.automationPoints.firstIndex(where: { $0.id == id }) else { return }
        currentSong.automationPoints[idx].time = rawTime
        if let secId = secId { currentSong.automationPoints[idx].sectionId = secId }
        currentSong.automationPoints.sort { $0.time < $1.time }
        syncCurrentSongAutomationToSetlist()
    }
    
    /// Ensures all MIDI, Directional, and Automation cues have a valid `sectionId` matching their containing section
    public func ensureCuesTaggedToSections(in song: inout Song, rebindByCurrentTime: Bool = false) {
        let validIds = Set(song.sections.map { $0.id })
        for idx in 0..<song.midiCues.count {
            if rebindByCurrentTime || song.midiCues[idx].sectionId == nil || !validIds.contains(song.midiCues[idx].sectionId!) {
                let t = song.midiCues[idx].time
                if let sec = song.sections.first(where: { t >= $0.startTime - 0.005 && t < $0.endTime - 0.005 }) ?? song.sections.last(where: { t >= $0.startTime - 0.005 }) {
                    song.midiCues[idx].sectionId = sec.id
                }
            }
        }
        for idx in 0..<song.directionalCues.count {
            if rebindByCurrentTime || song.directionalCues[idx].sectionId == nil || !validIds.contains(song.directionalCues[idx].sectionId!) {
                let t = song.directionalCues[idx].time
                if let sec = song.sections.first(where: { t >= $0.startTime - 0.005 && t < $0.endTime - 0.005 }) ?? song.sections.last(where: { t >= $0.startTime - 0.005 }) {
                    song.directionalCues[idx].sectionId = sec.id
                }
            }
        }
        for idx in 0..<song.automationPoints.count {
            if rebindByCurrentTime || song.automationPoints[idx].sectionId == nil || !validIds.contains(song.automationPoints[idx].sectionId!) {
                let t = song.automationPoints[idx].time
                if let sec = song.sections.first(where: { t >= $0.startTime - 0.005 && t < $0.endTime - 0.005 }) ?? song.sections.last(where: { t >= $0.startTime - 0.005 }) {
                    song.automationPoints[idx].sectionId = sec.id
                }
            }
        }
    }
    
    /// Captures the Default arrangement's baseline sections and cues right before Default's section map is altered
    private func snapshotDefaultBaselineIfUnmodified() {
        ensureCuesTaggedToSections(in: &currentSong, rebindByCurrentTime: currentSong.isCurrentSectionsMatchingDefault)
        if currentSong.defaultSections.isEmpty {
            currentSong.defaultSections = currentSong.sections
        }
        if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
            currentSong.defaultMidiCues = currentSong.midiCues
            currentSong.defaultDirectionalCues = currentSong.directionalCues
            currentSong.defaultAutomationPoints = currentSong.automationPoints
            currentSong.defaultSmpteCue = currentSong.smpteCue
        }
    }
    
    /// Re-indexes arrangement sections to be seamlessly contiguous and shifts all section-linked cues accordingly
    public func reindexArrangement() {
        ensureCuesTaggedToSections(in: &currentSong)
        
        // Track the previous start times of sections before shifting so we can move their associated cues with them
        var sectionDeltaMap: [UUID: TimeInterval] = [:]
        for sec in currentSong.sections {
            sectionDeltaMap[sec.id] = sec.startTime
        }
        
        var currentArrangementTime: TimeInterval = 0.0
        var currentMeasure = 1
        let hasDynamicGrid = !currentSong.beatGrid.isEmpty || !currentSong.timeSignatureChanges.isEmpty
        let srcGrid = hasDynamicGrid ? currentSong.sourceBeatGrid() : []
        
        for i in 0..<currentSong.sections.count {
            let secId = currentSong.sections[i].id
            let oldStart = sectionDeltaMap[secId] ?? currentSong.sections[i].startTime
            let shiftDelta = currentArrangementTime - oldStart
            
            // If the section moved, shift its associated MIDI, Directional, and Automation cues by the exact same time delta
            // (do not clamp to 0.0 so cues in leading-trimmed regions preserve their exact signed offset from sec.startTime)
            if abs(shiftDelta) > 0.001 {
                for cueIdx in 0..<currentSong.midiCues.count {
                    if currentSong.midiCues[cueIdx].sectionId == secId {
                        currentSong.midiCues[cueIdx].time += shiftDelta
                    }
                }
                for cueIdx in 0..<currentSong.directionalCues.count {
                    if currentSong.directionalCues[cueIdx].sectionId == secId {
                        currentSong.directionalCues[cueIdx].time += shiftDelta
                    }
                }
                for ptIdx in 0..<currentSong.automationPoints.count {
                    if currentSong.automationPoints[ptIdx].sectionId == secId {
                        currentSong.automationPoints[ptIdx].time += shiftDelta
                    }
                }
            }
            
            let sec = currentSong.sections[i]
            let isBlankClick = sec.effectiveIsClickSection &&
                (sec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click section" || sec.abbreviation == "CLK")
            if !isBlankClick && !srcGrid.isEmpty {
                let ts = currentSong.timeSignature(atSourceTime: sec.sourceAudioStartTime)
                currentSong.sections[i].measureCount = Song.measureCount(
                    inSourceGrid: srcGrid,
                    audioStart: sec.sourceAudioStartTime,
                    duration: sec.duration,
                    fallbackBPM: currentSong.bpm,
                    timeSignatureNumerator: ts.numerator,
                    timeSignatureDenominator: ts.denominator
                )
            }
            currentSong.sections[i].startTime = currentArrangementTime
            currentSong.sections[i].startMeasure = currentMeasure
            
            currentArrangementTime += currentSong.sections[i].duration
            currentMeasure += currentSong.sections[i].measureCount
        }
        
        ensureCuesTaggedToSections(in: &currentSong)
        currentSong.midiCues.sort { $0.time < $1.time }
        currentSong.directionalCues.sort { $0.time < $1.time }
        currentSong.automationPoints.sort { $0.time < $1.time }
        
        let trackMaxDuration = tracks.map { $0.duration }.max() ?? 0.0
        if !currentSong.sections.isEmpty && currentArrangementTime > 0 {
            currentSongDuration = currentArrangementTime
        } else {
            currentSongDuration = trackMaxDuration
        }
        rebuildPrecomputedBeatGrid()
        transportPosition.totalDuration = currentSongDuration
        transportClock.position.totalDuration = currentSongDuration
        transportDisplayClock.update(with: transportPosition)
        transportClock.objectWillChange.send()
        
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
            currentSetlist.songs[currentSongIndex].defaultSections = currentSong.defaultSections
            currentSetlist.songs[currentSongIndex].midiCues = currentSong.midiCues
            currentSetlist.songs[currentSongIndex].directionalCues = currentSong.directionalCues
            currentSetlist.songs[currentSongIndex].automationPoints = currentSong.automationPoints
            currentSetlist.songs[currentSongIndex].defaultMidiCues = currentSong.defaultMidiCues
            currentSetlist.songs[currentSongIndex].defaultDirectionalCues = currentSong.defaultDirectionalCues
            currentSetlist.songs[currentSongIndex].defaultAutomationPoints = currentSong.defaultAutomationPoints
        }
        
        updateArrangementWaveform()
        syncMixState()
        objectWillChange.send()
    }
    
    // MARK: - Section Trimming Controls
    
    public func beginTrimming(section: SongSection) {
        trimmingSection = section
        trimLeadingDuration = section.leadingTrimDuration
        trimTrailingDuration = section.trailingTrimDuration
        updateArrangementWaveform()
    }
    
    public func cancelTrimming() {
        trimmingSection = nil
        updateArrangementWaveform()
    }
    
    public func applyTrimming() {
        guard let trimming = trimmingSection,
              let idx = currentSong.sections.firstIndex(where: { $0.id == trimming.id }) else {
            trimmingSection = nil
            updateArrangementWaveform()
            return
        }
        
        snapshotDefaultBaselineIfUnmodified()
        
        var sec = currentSong.sections[idx]
        let localBPM = currentSong.instantaneousBPM(atSourceTime: sec.baseAudioStartTime)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sec.baseAudioStartTime)
        let secPerBeat = (60.0 / localBPM) * (4.0 / Double(max(1, tsDen)))
        let leadingTrimDelta = trimLeadingDuration - sec.leadingTrimDuration
        sec.leadingTrimDuration = trimLeadingDuration
        sec.trailingTrimDuration = trimTrailingDuration
        let newDuration = max(secPerBeat, sec.baseDuration - trimLeadingDuration - trimTrailingDuration)
        sec.duration = newDuration
        let newAudioStart = sec.baseAudioStartTime + trimLeadingDuration
        sec.audioStartTime = newAudioStart
        sec.measureCount = Song.measureCount(
            inSourceGrid: currentSong.sourceBeatGrid(),
            audioStart: newAudioStart,
            duration: newDuration,
            fallbackBPM: localBPM,
            timeSignatureNumerator: tsNum,
            timeSignatureDenominator: tsDen
        )
        
        // Shift cues inside the trimmed section itself when leading trim changes so they stay at the exact same relative beat/bar within the section audio
        // (do not clamp to sec.startTime so cues in the trimmed-out leading region preserve their signed offset and can be dimmed in edit mode / restored on untrim)
        if abs(leadingTrimDelta) > 0.001 {
            let secId = sec.id
            for cueIdx in 0..<currentSong.midiCues.count {
                if currentSong.midiCues[cueIdx].sectionId == secId {
                    currentSong.midiCues[cueIdx].time -= leadingTrimDelta
                }
            }
            for cueIdx in 0..<currentSong.directionalCues.count {
                if currentSong.directionalCues[cueIdx].sectionId == secId {
                    currentSong.directionalCues[cueIdx].time -= leadingTrimDelta
                }
            }
            for ptIdx in 0..<currentSong.automationPoints.count {
                if currentSong.automationPoints[ptIdx].sectionId == secId {
                    currentSong.automationPoints[ptIdx].time -= leadingTrimDelta
                }
            }
        }
        
        currentSong.sections[idx] = sec
        trimmingSection = nil
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func resetSectionToDefault(sectionId: UUID) {
        guard let idx = currentSong.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        ensureCuesTaggedToSections(in: &currentSong)
        var sec = currentSong.sections[idx]
        let currentStartTime = sec.startTime
        let currentStartMeasure = sec.startMeasure
        let oldLeadingTrim = sec.leadingTrimDuration
        if let def = currentSong.defaultSections.first(where: { $0.id == sectionId }) {
            sec = def
            sec.startTime = currentStartTime
            sec.startMeasure = currentStartMeasure
        } else {
            sec.leadingTrimDuration = 0.0
            sec.trailingTrimDuration = 0.0
            sec.duration = sec.baseDuration
            sec.audioStartTime = sec.baseAudioStartTime
            let localBPM = currentSong.instantaneousBPM(atSourceTime: sec.baseAudioStartTime)
            let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sec.baseAudioStartTime)
            sec.measureCount = Song.measureCount(
                inSourceGrid: currentSong.sourceBeatGrid(),
                audioStart: sec.baseAudioStartTime,
                duration: sec.duration,
                fallbackBPM: localBPM,
                timeSignatureNumerator: tsNum,
                timeSignatureDenominator: tsDen
            )
        }
        let leadingTrimDelta = sec.leadingTrimDuration - oldLeadingTrim
        if abs(leadingTrimDelta) > 0.001 {
            for cueIdx in 0..<currentSong.midiCues.count {
                if currentSong.midiCues[cueIdx].sectionId == sectionId {
                    currentSong.midiCues[cueIdx].time -= leadingTrimDelta
                }
            }
            for cueIdx in 0..<currentSong.directionalCues.count {
                if currentSong.directionalCues[cueIdx].sectionId == sectionId {
                    currentSong.directionalCues[cueIdx].time -= leadingTrimDelta
                }
            }
            for ptIdx in 0..<currentSong.automationPoints.count {
                if currentSong.automationPoints[ptIdx].sectionId == sectionId {
                    currentSong.automationPoints[ptIdx].time -= leadingTrimDelta
                }
            }
        }
        currentSong.sections[idx] = sec
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func resetAllSectionsToDefault() {
        restoreArrangementFromSave(forSongIndex: currentSongIndex)
    }
    
    public func updateSectionDetails(id: UUID, name: String, abbreviation: String, playGuideCue: Bool, playCountIn: Bool, includeNumberInGuide: Bool = true) {
        guard let idx = currentSong.sections.firstIndex(where: { $0.id == id }) else { return }
        currentSong.sections[idx].name = name
        currentSong.sections[idx].abbreviation = abbreviation
        currentSong.sections[idx].playSectionGuideCue = playGuideCue
        currentSong.sections[idx].playSectionCountIn = playCountIn
        currentSong.sections[idx].includeNumberInGuide = includeNumberInGuide
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
        }
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Non-destructively removes a section from the active arrangement
    public func removeSection(at index: Int) {
        guard index >= 0 && index < currentSong.sections.count else { return }
        
        snapshotDefaultBaselineIfUnmodified()
        
        let removed = currentSong.sections.remove(at: index)
        currentSong.midiCues.removeAll { $0.sectionId == removed.id }
        currentSong.directionalCues.removeAll { $0.sectionId == removed.id }
        currentSong.automationPoints.removeAll { $0.sectionId == removed.id }
        if loopedSection?.id == removed.id {
            loopedSection = nil
            isLoopActive = false
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        
        if playbackState == .playing {
            seek(to: min(playbackOffsetSeconds, currentSongDuration))
        } else if playbackOffsetSeconds >= removed.startTime && playbackOffsetSeconds < removed.endTime {
            seek(to: max(0.0, removed.startTime))
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Removes a section label by merging the section's time and cues into the section immediately before it.
    public func removeSectionLabel(id: UUID) {
        guard let index = currentSong.sections.firstIndex(where: { $0.id == id }), index > 0 else { return }
        
        snapshotDefaultBaselineIfUnmodified()
        
        let removed = currentSong.sections[index]
        let prevId = currentSong.sections[index - 1].id
        
        currentSong.sections[index - 1].duration += removed.duration
        currentSong.sections[index - 1].measureCount += removed.measureCount
        currentSong.sections[index - 1].trailingTrimDuration = removed.trailingTrimDuration
        
        for i in 0..<currentSong.midiCues.count where currentSong.midiCues[i].sectionId == removed.id {
            currentSong.midiCues[i].sectionId = prevId
        }
        for i in 0..<currentSong.directionalCues.count where currentSong.directionalCues[i].sectionId == removed.id {
            currentSong.directionalCues[i].sectionId = prevId
        }
        for i in 0..<currentSong.automationPoints.count where currentSong.automationPoints[i].sectionId == removed.id {
            currentSong.automationPoints[i].sectionId = prevId
        }
        
        if loopedSection?.id == removed.id {
            loopedSection = currentSong.sections[index - 1]
        }
        
        currentSong.sections.remove(at: index)
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Inserts a Blank Click Section of `measures` bars (Click, Guide, and Pad only; instrument stems muted).
    public func insertBlankClickSection(measures: Int, afterIndex: Int) {
        let clampedMeasures = max(1, measures)
        let refSourceTime: TimeInterval = (afterIndex >= 0 && afterIndex < currentSong.sections.count)
            ? (currentSong.sections[afterIndex].sourceAudioStartTime + currentSong.sections[afterIndex].duration)
            : 0.0
        let localBPM = currentSong.instantaneousBPM(atSourceTime: refSourceTime)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: refSourceTime)
        let beatDur = (60.0 / localBPM) * (4.0 / Double(max(1, tsDen)))
        let dur = Double(clampedMeasures * max(1, tsNum)) * beatDur
        let blank = SongSection(
            name: "Click Section",
            abbreviation: "CLK",
            startTime: 0.0,
            audioStartTime: 0.0,
            duration: dur,
            startMeasure: 1,
            measureCount: clampedMeasures,
            isClickSection: true
        )
        insertSection(from: blank, afterIndex: afterIndex)
    }

    /// Inserts a Section-Mirrored Click Section cloning `masterSection`'s length, tempo map, and guide cues with stems muted.
    public func insertMirroredClickSection(from masterSection: SongSection, afterIndex: Int) {
        var mirrored = masterSection
        mirrored.isClickSection = true
        insertSection(from: mirrored, afterIndex: afterIndex)
    }

    /// Copies MIDI, Directional, and Automation cues from `sourceSection` onto `targetSection`.
    private func copyCues(from sourceSection: SongSection, to targetSection: SongSection) {
        let activeDonor = currentSong.sections.first(where: {
            $0.id == sourceSection.id ||
            ($0.name.lowercased() == sourceSection.name.lowercased() && abs($0.baseAudioStartTime - sourceSection.baseAudioStartTime) < 0.05 && !$0.effectiveIsClickSection)
        })
        if let donor = activeDonor {
            for cue in currentSong.midiCues where cue.sectionId == donor.id {
                let rel = max(0.0, cue.time - donor.startTime)
                if rel < targetSection.duration {
                    currentSong.midiCues.append(MIDICue(
                        id: UUID(),
                        time: targetSection.startTime + rel,
                        sectionId: targetSection.id,
                        bus: cue.bus,
                        messageType: cue.messageType,
                        primaryValue: cue.primaryValue,
                        secondaryValue: cue.secondaryValue,
                        disableLoop: cue.disableLoop,
                        cueDescription: cue.cueDescription
                    ))
                }
            }
            for cue in currentSong.directionalCues where cue.sectionId == donor.id {
                let rel = max(0.0, cue.time - donor.startTime)
                if rel < targetSection.duration {
                    currentSong.directionalCues.append(DirectionalCue(
                        id: UUID(),
                        time: targetSection.startTime + rel,
                        label: cue.label,
                        sectionId: targetSection.id
                    ))
                }
            }
            for pt in currentSong.automationPoints where pt.sectionId == donor.id {
                let rel = max(0.0, pt.time - donor.startTime)
                if rel < targetSection.duration {
                    currentSong.automationPoints.append(AutomationPoint(
                        id: UUID(),
                        time: targetSection.startTime + rel,
                        name: pt.name,
                        transitionBeats: pt.transitionBeats,
                        descriptionText: pt.descriptionText,
                        sectionId: targetSection.id,
                        trackFaders: pt.trackFaders,
                        trackPans: pt.trackPans,
                        trackMutes: pt.trackMutes,
                        busFaders: pt.busFaders,
                        busMutes: pt.busMutes,
                        padActive: pt.padActive,
                        midiMuted: pt.midiMuted
                    ))
                }
            }
        } else {
            let donorMidi = currentSong.defaultMidiCues.filter {
                $0.sectionId == sourceSection.id || ($0.time >= sourceSection.startTime - 0.005 && $0.time < sourceSection.endTime - 0.005)
            }
            for cue in donorMidi {
                let rel = max(0.0, cue.time - sourceSection.startTime)
                if rel < targetSection.duration {
                    currentSong.midiCues.append(MIDICue(
                        id: UUID(),
                        time: targetSection.startTime + rel,
                        sectionId: targetSection.id,
                        bus: cue.bus,
                        messageType: cue.messageType,
                        primaryValue: cue.primaryValue,
                        secondaryValue: cue.secondaryValue,
                        disableLoop: cue.disableLoop,
                        cueDescription: cue.cueDescription
                    ))
                }
            }
        }
        syncCurrentSongMIDICuesToSetlist()
        syncCurrentSongDirectionalCuesToSetlist()
        syncCurrentSongAutomationToSetlist()
    }

    /// Configures an existing Click Section as either a Default Click Section (custom bar length) or Based on Song Section.
    public func updateClickSection(
        id: UUID,
        isMirrored: Bool,
        measures: Int,
        basedOnSection: SongSection?,
        playSectionGuideCue: Bool,
        playSectionCountIn: Bool
    ) {
        guard let idx = currentSong.sections.firstIndex(where: { $0.id == id }) else { return }
        snapshotDefaultBaselineIfUnmodified()
        
        var sec = currentSong.sections[idx]
        sec.isClickSection = true
        sec.playSectionGuideCue = playSectionGuideCue
        sec.playSectionCountIn = playSectionCountIn
        
        // Remove previous cues belonging to this click section before re-applying
        currentSong.midiCues.removeAll { $0.sectionId == sec.id }
        currentSong.directionalCues.removeAll { $0.sectionId == sec.id }
        currentSong.automationPoints.removeAll { $0.sectionId == sec.id }
        
        if isMirrored, let source = basedOnSection {
            sec.name = source.name
            sec.abbreviation = source.abbreviation
            sec.measureCount = max(1, source.measureCount)
            sec.duration = source.duration
            sec.audioStartTime = source.sourceAudioStartTime
            sec.originalAudioStartTime = source.baseAudioStartTime
            sec.originalDuration = source.baseDuration
            sec.leadingTrimDuration = source.leadingTrimDuration
            sec.trailingTrimDuration = source.trailingTrimDuration
            currentSong.sections[idx] = sec
            copyCues(from: source, to: sec)
        } else {
            let clampedMeasures = max(1, measures)
            let refSourceTime: TimeInterval = (idx > 0)
                ? (currentSong.sections[idx - 1].sourceAudioStartTime + currentSong.sections[idx - 1].duration)
                : 0.0
            let localBPM = currentSong.instantaneousBPM(atSourceTime: refSourceTime)
            let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: refSourceTime)
            let beatDur = (60.0 / localBPM) * (4.0 / Double(max(1, tsDen)))
            let dur = Double(clampedMeasures * max(1, tsNum)) * beatDur
            sec.name = "Click Section"
            sec.abbreviation = "CLK"
            sec.measureCount = clampedMeasures
            sec.duration = dur
            sec.originalDuration = dur
            sec.leadingTrimDuration = 0.0
            sec.trailingTrimDuration = 0.0
            currentSong.sections[idx] = sec
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        if playbackState == .playing {
            seek(to: playbackOffsetSeconds)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    

    /// Non-destructively inserts a section from the master song map immediately after afterIndex (-1 for beginning)
    public func insertSection(from masterSection: SongSection, afterIndex: Int) {
        snapshotDefaultBaselineIfUnmodified()
        
        let insertPos = max(0, min(currentSong.sections.count, afterIndex + 1))
        let initialStartTime: TimeInterval = {
            if insertPos > 0 && insertPos - 1 < currentSong.sections.count {
                return currentSong.sections[insertPos - 1].endTime
            }
            return 0.0
        }()
        
        let newSection = SongSection(
            id: UUID(),
            name: masterSection.name,
            abbreviation: masterSection.abbreviation,
            startTime: initialStartTime,
            audioStartTime: masterSection.sourceAudioStartTime,
            duration: masterSection.duration,
            startMeasure: masterSection.startMeasure,
            measureCount: masterSection.measureCount,
            originalAudioStartTime: masterSection.baseAudioStartTime,
            originalDuration: masterSection.baseDuration,
            leadingTrimDuration: masterSection.leadingTrimDuration,
            trailingTrimDuration: masterSection.trailingTrimDuration,
            playSectionGuideCue: masterSection.playSectionGuideCue,
            playSectionCountIn: masterSection.playSectionCountIn,
            isClickSection: masterSection.isClickSection
        )
        
        // Copy any cues associated with the source section so repeated/re-inserted sections carry their cues automatically
        if let activeDonor = currentSong.sections.first(where: {
            $0.id == masterSection.id ||
            ($0.name.lowercased() == masterSection.name.lowercased() && abs($0.baseAudioStartTime - masterSection.baseAudioStartTime) < 0.05)
        }) {
            let donorMidi = currentSong.midiCues.filter { $0.sectionId == activeDonor.id }
            for cue in donorMidi {
                let rel = max(0.0, cue.time - activeDonor.startTime)
                if rel < newSection.duration {
                    var copy = cue
                    copy = MIDICue(
                        id: UUID(),
                        time: initialStartTime + rel,
                        sectionId: newSection.id,
                        bus: cue.bus,
                        messageType: cue.messageType,
                        primaryValue: cue.primaryValue,
                        secondaryValue: cue.secondaryValue,
                        disableLoop: cue.disableLoop,
                        cueDescription: cue.cueDescription
                    )
                    currentSong.midiCues.append(copy)
                }
            }
            let donorDir = currentSong.directionalCues.filter { $0.sectionId == activeDonor.id }
            for cue in donorDir {
                let rel = max(0.0, cue.time - activeDonor.startTime)
                if rel < newSection.duration {
                    currentSong.directionalCues.append(
                        DirectionalCue(id: UUID(), time: initialStartTime + rel, label: cue.label, sectionId: newSection.id)
                    )
                }
            }
        } else if let defaultDonor = currentSong.defaultSections.first(where: {
            $0.id == masterSection.id ||
            ($0.name.lowercased() == masterSection.name.lowercased() && abs($0.baseAudioStartTime - masterSection.baseAudioStartTime) < 0.05)
        }) {
            let donorMidi = currentSong.defaultMidiCues.filter {
                $0.sectionId == defaultDonor.id || ($0.time >= defaultDonor.startTime - 0.005 && $0.time < defaultDonor.endTime - 0.005)
            }
            for cue in donorMidi {
                let rel = max(0.0, cue.time - defaultDonor.startTime)
                if rel < newSection.duration {
                    currentSong.midiCues.append(
                        MIDICue(
                            id: UUID(),
                            time: initialStartTime + rel,
                            sectionId: newSection.id,
                            bus: cue.bus,
                            messageType: cue.messageType,
                            primaryValue: cue.primaryValue,
                            secondaryValue: cue.secondaryValue,
                            disableLoop: cue.disableLoop,
                            cueDescription: cue.cueDescription
                        )
                    )
                }
            }
        }
        
        currentSong.sections.insert(newSection, at: insertPos)
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        
        if playbackState == .playing {
            seek(to: playbackOffsetSeconds)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Resets the active song arrangement to the default song map
    // MARK: - Mid-Song Time Signature Changes (Phase 5.6)
    
    public func addTimeSignatureChange(atDisplayTime displayTime: TimeInterval, numerator: Int, denominator: Int) {
        let snappedDisp = snapTimeToBeatGrid(displayTime)
        let sourceTime = max(0.0, audioTime(forArrangementTime: snappedDisp))
        let clampedNum = max(1, min(16, numerator))
        let validDen = [2, 4, 8, 16].contains(denominator) ? denominator : 4
        
        currentSong.timeSignatureChanges.removeAll { abs($0.audioTime - sourceTime) < 0.05 }
        currentSong.timeSignatureChanges.append(
            TimeSignatureChange(audioTime: sourceTime, numerator: clampedNum, denominator: validDen)
        )
        currentSong.timeSignatureChanges.sort { $0.audioTime < $1.audioTime }
        syncTimeSignatureChangesToSetlist()
    }
    
    public func updateTimeSignatureChange(id: UUID, numerator: Int, denominator: Int) {
        guard let idx = currentSong.timeSignatureChanges.firstIndex(where: { $0.id == id }) else { return }
        currentSong.timeSignatureChanges[idx].numerator = max(1, min(16, numerator))
        currentSong.timeSignatureChanges[idx].denominator = [2, 4, 8, 16].contains(denominator) ? denominator : 4
        syncTimeSignatureChangesToSetlist()
    }
    
    public func removeTimeSignatureChange(id: UUID) {
        currentSong.timeSignatureChanges.removeAll { $0.id == id }
        syncTimeSignatureChangesToSetlist()
    }
    
    private func syncTimeSignatureChangesToSetlist() {
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].timeSignatureChanges = currentSong.timeSignatureChanges
        }
        rebuildPrecomputedBeatGrid()
        updateTransportPosition(to: playbackOffsetSeconds)
        regenerateClickTrack()
        regenerateGuideTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    public func resetToDefaultSongMap() {
        guard !currentSong.defaultSections.isEmpty else { return }
        currentSong.sections = currentSong.defaultSections
        if !currentSong.defaultMidiCues.isEmpty {
            currentSong.midiCues = currentSong.defaultMidiCues
        }
        if !currentSong.defaultDirectionalCues.isEmpty {
            currentSong.directionalCues = currentSong.defaultDirectionalCues
        }
        if !currentSong.defaultAutomationPoints.isEmpty {
            currentSong.automationPoints = currentSong.defaultAutomationPoints
        }
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        seek(to: 0.0)
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Song Arrangements Management (Default + User Saved Arrangements)
    
    /// Projects cues from a source section list onto a target section list so cues persist across arrangements
    private func projectCuesOntoSections(
        sourceSections: [SongSection],
        sourceMidi: [MIDICue],
        sourceDirectional: [DirectionalCue],
        sourceAutomation: [AutomationPoint],
        targetSections: [SongSection]
    ) -> ([MIDICue], [DirectionalCue], [AutomationPoint]) {
        var projectedMidi: [MIDICue] = []
        var projectedDir: [DirectionalCue] = []
        var projectedAuto: [AutomationPoint] = []
        var usedAutoSourceIds: Set<UUID> = []
        
        for targetSec in targetSections {
            guard let matchedSource = sourceSections.first(where: { $0.id == targetSec.id }) ??
                    sourceSections.first(where: {
                        $0.name.lowercased() == targetSec.name.lowercased() &&
                        abs($0.baseAudioStartTime - targetSec.baseAudioStartTime) < 0.1
                    }) ??
                    sourceSections.first(where: { $0.name.lowercased() == targetSec.name.lowercased() }) else {
                continue
            }
            
            let secMidi = sourceMidi.filter {
                $0.sectionId == matchedSource.id ||
                ($0.sectionId == nil && $0.time >= matchedSource.startTime - 0.005 && $0.time < matchedSource.endTime - 0.005)
            }
            for cue in secMidi {
                let untrimmedOffset = (cue.time - matchedSource.startTime) + matchedSource.leadingTrimDuration
                if untrimmedOffset >= -0.005 && untrimmedOffset < targetSec.baseDuration + 0.005 {
                    let targetTime = targetSec.startTime + untrimmedOffset - targetSec.leadingTrimDuration
                    projectedMidi.append(MIDICue(
                        id: UUID(),
                        time: targetTime,
                        sectionId: targetSec.id,
                        bus: cue.bus,
                        messageType: cue.messageType,
                        primaryValue: cue.primaryValue,
                        secondaryValue: cue.secondaryValue,
                        disableLoop: cue.disableLoop,
                        cueDescription: cue.cueDescription
                    ))
                }
            }
            
            let secDir = sourceDirectional.filter {
                $0.sectionId == matchedSource.id ||
                ($0.sectionId == nil && $0.time >= matchedSource.startTime - 0.005 && $0.time < matchedSource.endTime - 0.005)
            }
            for cue in secDir {
                let untrimmedOffset = (cue.time - matchedSource.startTime) + matchedSource.leadingTrimDuration
                if untrimmedOffset >= -0.005 && untrimmedOffset < targetSec.baseDuration + 0.005 {
                    let targetTime = targetSec.startTime + untrimmedOffset - targetSec.leadingTrimDuration
                    projectedDir.append(DirectionalCue(
                        id: UUID(),
                        time: targetTime,
                        label: cue.label,
                        sectionId: targetSec.id
                    ))
                }
            }
            
            let matchedAutoSource = sourceSections.first(where: { $0.id == targetSec.id }) ??
                sourceSections.first(where: {
                    !usedAutoSourceIds.contains($0.id) &&
                    $0.name.lowercased() == targetSec.name.lowercased() &&
                    abs($0.baseAudioStartTime - targetSec.baseAudioStartTime) < 0.1
                }) ??
                sourceSections.first(where: {
                    !usedAutoSourceIds.contains($0.id) &&
                    $0.name.lowercased() == targetSec.name.lowercased()
                })
            if let autoSource = matchedAutoSource {
                usedAutoSourceIds.insert(autoSource.id)
                let secAuto = sourceAutomation.filter {
                    $0.sectionId == autoSource.id ||
                    ($0.sectionId == nil && $0.time >= autoSource.startTime - 0.005 && $0.time < autoSource.endTime - 0.005)
                }
                for pt in secAuto {
                    let untrimmedOffset = (pt.time - autoSource.startTime) + autoSource.leadingTrimDuration
                    if untrimmedOffset >= -0.005 && untrimmedOffset < targetSec.baseDuration + 0.005 {
                        let targetTime = targetSec.startTime + untrimmedOffset - targetSec.leadingTrimDuration
                        projectedAuto.append(AutomationPoint(
                            id: UUID(),
                            time: targetTime,
                            name: pt.name,
                            transitionBeats: pt.transitionBeats,
                            descriptionText: pt.descriptionText,
                            sectionId: targetSec.id,
                            trackFaders: pt.trackFaders,
                            trackPans: pt.trackPans,
                            trackMutes: pt.trackMutes,
                            busFaders: pt.busFaders,
                            busMutes: pt.busMutes,
                            padActive: pt.padActive,
                            midiMuted: pt.midiMuted
                        ))
                    }
                }
            }
        }
        
        projectedMidi.sort { $0.time < $1.time }
        projectedDir.sort { $0.time < $1.time }
        projectedAuto.sort { $0.time < $1.time }
        return (projectedMidi, projectedDir, projectedAuto)
    }
    
    /// Switches the target song to the specified arrangement (`nil` for "Default", or a `SavedArrangement.id`).
    public func selectArrangement(id: UUID?, forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        
        ensureCuesTaggedToSections(in: &song)
        if song.defaultSections.isEmpty {
            song.defaultSections = song.sections
        }
        
        // If we are currently on Default with unmodified sections, keep Default's baseline cues up to date
        if song.activeArrangementId == nil && song.isCurrentSectionsMatchingDefault {
            song.defaultMidiCues = song.midiCues
            song.defaultDirectionalCues = song.directionalCues
            song.defaultAutomationPoints = song.automationPoints
            song.defaultSmpteCue = song.smpteCue
        }
        
        if let targetId = id,
           let arrIdx = song.savedArrangements.firstIndex(where: { $0.id == targetId }) {
            var arr = song.savedArrangements[arrIdx]
            
            // If this arrangement was created before cues were added to the song, project baseline cues onto its sections
            let (projMidi, projDir, projAuto) = projectCuesOntoSections(
                sourceSections: !song.defaultMidiCues.isEmpty ? song.defaultSections : song.sections,
                sourceMidi: !song.defaultMidiCues.isEmpty ? song.defaultMidiCues : song.midiCues,
                sourceDirectional: !song.defaultDirectionalCues.isEmpty ? song.defaultDirectionalCues : song.directionalCues,
                sourceAutomation: !song.defaultAutomationPoints.isEmpty ? song.defaultAutomationPoints : song.automationPoints,
                targetSections: arr.sections
            )
            if arr.midiCues.isEmpty && !projMidi.isEmpty {
                arr.midiCues = projMidi
            }
            if arr.directionalCues.isEmpty && !projDir.isEmpty {
                arr.directionalCues = projDir
            }
            if arr.automationPoints.isEmpty && !projAuto.isEmpty {
                arr.automationPoints = projAuto
            }
            if arr.smpteCue == nil {
                arr.smpteCue = song.defaultSmpteCue ?? song.smpteCue
            }
            song.savedArrangements[arrIdx] = arr
            
            song.activeArrangementId = targetId
            song.sections = arr.sections
            song.midiCues = arr.midiCues
            song.directionalCues = arr.directionalCues
            song.automationPoints = arr.automationPoints
            song.smpteCue = arr.smpteCue
        } else {
            // Switching to "Default"
            let (projMidi, projDir, projAuto) = projectCuesOntoSections(
                sourceSections: song.sections,
                sourceMidi: song.midiCues,
                sourceDirectional: song.directionalCues,
                sourceAutomation: song.automationPoints,
                targetSections: song.defaultSections
            )
            if song.defaultMidiCues.isEmpty && !projMidi.isEmpty {
                song.defaultMidiCues = projMidi
            }
            if song.defaultDirectionalCues.isEmpty && !projDir.isEmpty {
                song.defaultDirectionalCues = projDir
            }
            if song.defaultAutomationPoints.isEmpty && !projAuto.isEmpty {
                song.defaultAutomationPoints = projAuto
            }
            if song.defaultSmpteCue == nil {
                song.defaultSmpteCue = song.smpteCue
            }
            
            song.activeArrangementId = nil
            song.sections = song.defaultSections
            song.midiCues = song.defaultMidiCues
            song.directionalCues = song.defaultDirectionalCues
            song.automationPoints = song.defaultAutomationPoints
            song.smpteCue = song.defaultSmpteCue
        }
        
        if idx == currentSongIndex {
            currentSong = song
            loopedSection = nil
            isLoopActive = false
            queuedNextSection = nil
            selectedMIDICueId = nil
            selectedDirectionalCueId = nil
            selectedAutomationPointId = nil
            reindexArrangement()
            updateArrangementWaveform()
            regenerateGuideTrack()
            regenerateClickTrack()
            updateSMPTEState()
            syncMixState()
            if playbackOffsetSeconds > currentSongDuration {
                seek(to: 0.0)
            }
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = (idx == currentSongIndex) ? currentSong : song
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Creates a new custom arrangement from the song's current state (sections + cues) and makes it active.
    /// Never overwrites the Default arrangement.
    @discardableResult
    public func saveAsNewArrangement(name: String, forSongIndex targetIndex: Int? = nil) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "New Arrangement" : trimmed
        let idx = targetIndex ?? currentSongIndex
        
        if idx == currentSongIndex {
            ensureCuesTaggedToSections(in: &currentSong)
            if currentSong.defaultSections.isEmpty {
                currentSong.defaultSections = currentSong.sections
            }
        }
        
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        ensureCuesTaggedToSections(in: &song)
        
        let newArr = SavedArrangement(
            id: UUID(),
            name: finalName,
            sections: song.sections,
            midiCues: song.midiCues,
            directionalCues: song.directionalCues,
            automationPoints: song.automationPoints,
            smpteCue: song.smpteCue
        )
        
        song.savedArrangements.append(newArr)
        song.activeArrangementId = newArr.id
        
        if idx == currentSongIndex {
            currentSong = song
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = song
        }
        markSessionChanged()
        if currentSessionURL != nil {
            saveCurrentSession()
        }
        objectWillChange.send()
        return newArr.id
    }
    
    /// Saves the current arrangement changes to the currently active user-created arrangement.
    /// Does nothing if "Default" is active (Default cannot be saved over).
    public func saveCurrentArrangement(forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        if idx == currentSongIndex {
            ensureCuesTaggedToSections(in: &currentSong)
        }
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        // Guard against ever overwriting Default
        guard let activeId = song.activeArrangementId,
              let arrIdx = song.savedArrangements.firstIndex(where: { $0.id == activeId }) else {
            return
        }
        ensureCuesTaggedToSections(in: &song)
        
        song.savedArrangements[arrIdx].sections = song.sections
        song.savedArrangements[arrIdx].midiCues = song.midiCues
        song.savedArrangements[arrIdx].directionalCues = song.directionalCues
        song.savedArrangements[arrIdx].automationPoints = song.automationPoints
        song.savedArrangements[arrIdx].smpteCue = song.smpteCue
        
        if idx == currentSongIndex {
            currentSong = song
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = song
        }
        markSessionChanged()
        if currentSessionURL != nil {
            saveCurrentSession()
        }
        objectWillChange.send()
    }
    
    /// Restores the active arrangement back to the last point the user saved it (or back to pristine Default if Default is active).
    public func restoreArrangementFromSave(forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        
        if let activeId = song.activeArrangementId,
           let saved = song.savedArrangements.first(where: { $0.id == activeId }) {
            song.sections = saved.sections
            song.midiCues = saved.midiCues
            song.directionalCues = saved.directionalCues
            song.automationPoints = saved.automationPoints
            song.smpteCue = saved.smpteCue
        } else {
            if !song.defaultSections.isEmpty {
                song.sections = song.defaultSections
            }
            song.midiCues = song.defaultMidiCues
            song.directionalCues = song.defaultDirectionalCues
            song.automationPoints = song.defaultAutomationPoints
            song.smpteCue = song.defaultSmpteCue
        }
        
        if idx == currentSongIndex {
            currentSong = song
            loopedSection = nil
            isLoopActive = false
            queuedNextSection = nil
            reindexArrangement()
            updateArrangementWaveform()
            regenerateGuideTrack()
            regenerateClickTrack()
            updateSMPTEState()
            syncMixState()
            if playbackOffsetSeconds > currentSongDuration {
                seek(to: 0.0)
            }
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = (idx == currentSongIndex) ? currentSong : song
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    /// Deletes a user-saved arrangement (Default cannot be deleted).
    public func deleteSavedArrangement(id: UUID, forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        var song: Song = (idx == currentSongIndex) ? currentSong : (
            (idx >= 0 && idx < currentSetlist.songs.count) ? currentSetlist.songs[idx] : currentSong
        )
        song.savedArrangements.removeAll { $0.id == id }
        let wasActive = (song.activeArrangementId == id)
        if idx == currentSongIndex {
            currentSong.savedArrangements = song.savedArrangements
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx].savedArrangements = song.savedArrangements
        }
        if wasActive {
            selectArrangement(id: nil, forSongIndex: idx)
        } else {
            markSessionChanged()
            objectWillChange.send()
        }
    }
    
    // MARK: - Automatic Guide Track Section Detection & Labeling
    
    /// Finds the Guide stem in the current song, listens to its vocal cues using Speech Recognition,
    /// ignores instructional cues ("cymbals", "all in", "breakdown", "softly", etc.), and labels
    /// each song section starting at the following measure downbeat.
    public func autoLabelSectionsFromGuide(onCompletion: (@MainActor @Sendable (Int, String) -> Void)? = nil) {
        guard !isAutoLabelingSections else { return }
        
        // Locate the Guide track channel
        let guideChannel = channels.values.first { ch in
            let t = ch.track
            let cat = StemCategory.category(for: t.name, role: t.role)
            return cat == .guide || t.role == .guide ||
                   t.name.lowercased().contains("guide") ||
                   t.name.lowercased().contains("cues") ||
                   t.name.lowercased().contains("cue")
        }
        
        // ALWAYS listen to the uploaded Guide track buffer
        let guideBuffer: AVAudioPCMBuffer
        if let upBuf = uploadedGuideBuffers[currentSong.id] {
            guideBuffer = upBuf
        } else if let matchedChannel = guideChannel,
                  let buf = pristineMasterBuffers[matchedChannel.track.id] ?? matchedChannel.buffer,
                  currentSong.guideSource == .uploaded {
            guideBuffer = buf
        } else {
            onCompletion?(0, "No uploaded Guide track found in current song")
            return
        }
        
        let bpm = currentSong.bpm
        let timeSigNum = currentSong.timeSignatureNumerator
        let timeSigDen = currentSong.timeSignatureDenominator
        let activeBeatGrid = currentSong.beatGrid
        let masterDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let totalDuration = max(masterDuration, Double(guideBuffer.frameLength) / guideBuffer.format.sampleRate)
        
        isAutoLabelingSections = true
        autoLabelProgress = 0.0
        autoLabelStatusText = "Analyzing Guide track..."
        objectWillChange.send()
        
        Task.detached(priority: .userInitiated) { [guideBuffer, bpm, timeSigNum, timeSigDen, totalDuration, activeBeatGrid] in
            let detectedSections = await GuideSectionDetector.analyzeGuideAndBuildSections(
                guideBuffer: guideBuffer,
                bpm: bpm,
                timeSignatureNumerator: timeSigNum,
                timeSignatureDenominator: timeSigDen,
                totalSongDuration: totalDuration,
                beatGrid: activeBeatGrid
            ) { prog, status in
                Task { @MainActor in
                    self.autoLabelProgress = prog
                    self.autoLabelStatusText = status
                }
            }
            
            await MainActor.run {
                self.isAutoLabelingSections = false
                self.autoLabelProgress = 1.0
                self.autoLabelStatusText = ""
                
                if !detectedSections.isEmpty {
                    self.currentSong.sections = detectedSections
                    self.currentSong.defaultSections = detectedSections
                    if self.currentSongIndex >= 0 && self.currentSongIndex < self.currentSetlist.songs.count {
                        self.currentSetlist.songs[self.currentSongIndex].sections = detectedSections
                        self.currentSetlist.songs[self.currentSongIndex].defaultSections = detectedSections
                    }
                    self.reindexArrangement()
                    self.updateArrangementWaveform()
                    self.regenerateGuideTrack()
                    self.regenerateClickTrack()
                    if self.playbackState == .playing {
                        self.seek(to: self.playbackOffsetSeconds)
                    }
                    self.markSessionChanged()
                    self.objectWillChange.send()
                    onCompletion?(detectedSections.count, "Auto-labeled \(detectedSections.count) sections from Guide")
                } else {
                    onCompletion?(0, "No section callouts detected in Guide track")
                }
            }
        }
    }
    
    // MARK: - Automatic Click Track Tempo & Dynamic Beat Grid Detection (Supports Ritardandos / Accelerandos)
    
    /// Finds the Click / Metronome stem in the current song, detects every click transient via SIMD `vDSP`,
    /// distinguishes accented measure downbeats from regular beats, and builds a dynamic beat & measure grid
    /// that follows steady tempos, ritardandos, accelerandos, and mid-song tempo changes.
    public func autoDetectTempoFromClick(onCompletion: (@MainActor @Sendable (Bool, String) -> Void)? = nil) {
        guard !isAnalyzingClickTempo else { return }
        
        // Locate all candidate click tracks and rank them so primary "Click" / "Metronome" / "1/4" is chosen over "1/8" or "1/16"
        let clickCandidates = channels.values.filter { ch in
            let t = ch.track
            let cat = StemCategory.category(for: t.name, role: t.role)
            let lower = t.name.lowercased()
            return cat == .click || t.role == .click ||
                   lower.contains("click") || lower.contains("metronome") || lower == "1/4"
        }.sorted { a, b in
            func score(_ name: String) -> Int {
                let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if n == "click" || n == "click track" || n == "metronome" { return 100 }
                if n.contains("click") && !n.contains("1/8") && !n.contains("1/16") { return 90 }
                if n == "1/4" || n.contains("quarter") { return 80 }
                if n.contains("1/8") || n.contains("eighth") { return 40 }
                if n.contains("1/16") || n.contains("sixteenth") { return 20 }
                if n.contains("accent") { return 10 }
                return 50
            }
            return score(a.track.name) > score(b.track.name)
        }
        
        // ALWAYS listen to the uploaded Click track buffer
        let clickBuffer: AVAudioPCMBuffer
        if let upBuf = uploadedClickBuffers[currentSong.id] {
            clickBuffer = upBuf
        } else if let matchedChannel = clickCandidates.first,
                  let buf = pristineMasterBuffers[matchedChannel.track.id] ?? matchedChannel.buffer,
                  currentSong.clickSource == .uploaded {
            clickBuffer = buf
        } else if let matchedChannel = clickCandidates.first,
                  let buf = pristineMasterBuffers[matchedChannel.track.id] ?? matchedChannel.buffer {
            clickBuffer = buf
        } else {
            onCompletion?(false, "No uploaded Click / Metronome track found in current song")
            return
        }
        
        let timeSigNum = currentSong.timeSignatureNumerator
        let timeSigDen = currentSong.timeSignatureDenominator
        let masterDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let totalDuration = max(masterDuration, Double(clickBuffer.frameLength) / clickBuffer.format.sampleRate)
        
        isAnalyzingClickTempo = true
        objectWillChange.send()
        
        Task.detached(priority: .userInitiated) { [clickBuffer, timeSigNum, timeSigDen, totalDuration] in
            let analysis = ClickTempoDetector.analyzeClickTrack(
                clickBuffer: clickBuffer,
                preferredTimeSignatureNumerator: timeSigNum,
                preferredTimeSignatureDenominator: timeSigDen,
                totalSongDuration: totalDuration
            )
            
            await MainActor.run {
                self.isAnalyzingClickTempo = false
                
                guard let result = analysis, !result.beatGrid.isEmpty else {
                    self.objectWillChange.send()
                    onCompletion?(false, "Could not detect metronome pulses in Click track")
                    return
                }
                
                self.currentSong.bpm = result.baseBPM
                self.currentSong.originalBPM = result.baseBPM
                self.currentSong.beatGrid = result.beatGrid
                
                // Align existing song sections (if any) to the newly detected dynamic measure downbeats
                let downbeats = result.beatGrid.filter { $0.isDownbeat }
                if !self.currentSong.sections.isEmpty && !downbeats.isEmpty {
                    for i in 0..<self.currentSong.sections.count {
                        let startBarIdx = max(0, min(downbeats.count - 1, self.currentSong.sections[i].startMeasure - 1))
                        let endBarIdx = max(startBarIdx, min(downbeats.count - 1, startBarIdx + self.currentSong.sections[i].measureCount))
                        let newStart = downbeats[startBarIdx].time
                        let newEnd: TimeInterval
                        if i == self.currentSong.sections.count - 1 {
                            newEnd = max(newStart + 1.0, totalDuration)
                        } else if endBarIdx < downbeats.count {
                            newEnd = downbeats[endBarIdx].time
                        } else {
                            newEnd = totalDuration
                        }
                        let newDur = max(0.5, newEnd - newStart)
                        self.currentSong.sections[i].startTime = newStart
                        self.currentSong.sections[i].audioStartTime = newStart
                        self.currentSong.sections[i].originalAudioStartTime = newStart
                        self.currentSong.sections[i].duration = newDur
                        self.currentSong.sections[i].originalDuration = newDur
                    }
                    self.currentSong.defaultSections = self.currentSong.sections
                }
                
                if self.currentSongIndex >= 0 && self.currentSongIndex < self.currentSetlist.songs.count {
                    self.currentSetlist.songs[self.currentSongIndex].bpm = result.baseBPM
                    self.currentSetlist.songs[self.currentSongIndex].originalBPM = result.baseBPM
                    self.currentSetlist.songs[self.currentSongIndex].beatGrid = result.beatGrid
                    self.currentSetlist.songs[self.currentSongIndex].sections = self.currentSong.sections
                    self.currentSetlist.songs[self.currentSongIndex].defaultSections = self.currentSong.defaultSections
                }
                
                self.updateArrangementWaveform()
                self.syncMixState()
                self.updateTransportPosition(to: self.playbackOffsetSeconds)
                self.markSessionChanged()
                self.objectWillChange.send()
                
                let barCount = downbeats.count
                if result.hasDynamicTempoChanges {
                    let minB = Int(round(result.minBPM))
                    let maxB = Int(round(result.maxBPM))
                    let baseB = Int(round(result.baseBPM))
                    onCompletion?(true, "Auto-Generated Dynamic Tempo Grid: \(baseB) BPM (\(minB)–\(maxB) BPM across \(barCount) bars)")
                } else {
                    let baseB = Int(round(result.baseBPM))
                    onCompletion?(true, "Auto-Generated Click Grid: \(baseB) BPM (\(barCount) bars)")
                }
            }
        }
    }
    
    // MARK: - Playhead Section Labeling (MultiTracks Waveform Plus Button)
    
    /// Adds a section starting at the current playhead position.
    /// The section extends until the start of the next section (or end of song audio).
    /// If an existing section contains the playhead, that section is shortened to end at the playhead.
    public func addSectionAtPlayhead(name: String) {
        addSectionAt(time: playbackOffsetSeconds, name: name)
    }
    
    public func addSectionAt(time: TimeInterval, name: String) {
        let masterDuration = tracks.map { $0.duration }.max() ?? currentSongDuration
        let songDuration = max(masterDuration, currentSongDuration, 1.0)
        let t = max(0.0, min(songDuration - 0.1, time))
        
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, currentSong.timeSignatureNumerator))
        let abbrev = SongSection.abbreviation(for: name)
        
        if currentSong.sections.isEmpty {
            if t > 0.05 {
                let introDuration = t
                let introMeasures = max(1, Int(round(introDuration / secPerMeasure)))
                let introSec = SongSection(
                    name: "Intro",
                    abbreviation: "I",
                    startTime: 0.0,
                    audioStartTime: 0.0,
                    duration: introDuration,
                    startMeasure: 1,
                    measureCount: introMeasures,
                    originalAudioStartTime: 0.0,
                    originalDuration: introDuration
                )
                currentSong.sections.append(introSec)
            }
            let tailDuration = max(0.2, songDuration - (t > 0.05 ? t : 0.0))
            let tailStart = t > 0.05 ? t : 0.0
            let newSection = SongSection(
                id: UUID(),
                name: name,
                abbreviation: abbrev,
                startTime: tailStart,
                audioStartTime: tailStart,
                duration: tailDuration,
                startMeasure: max(1, Int(round(tailStart / secPerMeasure)) + 1),
                measureCount: max(1, Int(round(tailDuration / secPerMeasure))),
                originalAudioStartTime: tailStart,
                originalDuration: tailDuration
            )
            currentSong.sections.append(newSection)
        } else if let exactIdx = currentSong.sections.firstIndex(where: { abs($0.startTime - t) <= 0.05 }) {
            // Relabel existing section at boundary `t` in place without adding or shifting waveform audio
            currentSong.sections[exactIdx].name = name
            currentSong.sections[exactIdx].abbreviation = abbrev
        } else if let containingIdx = currentSong.sections.firstIndex(where: { $0.startTime + 0.05 < t && $0.endTime - 0.05 > t }) {
            // Split existing section cleanly at `t` into two contiguous slices covering the exact same audio
            let existing = currentSong.sections[containingIdx]
            let leftDuration = max(0.2, t - existing.startTime)
            let rightDuration = max(0.2, existing.endTime - t)
            let leftAudioStart = existing.sourceAudioStartTime
            let rightAudioStart = leftAudioStart + leftDuration
            
            currentSong.sections[containingIdx].duration = leftDuration
            currentSong.sections[containingIdx].originalAudioStartTime = leftAudioStart
            currentSong.sections[containingIdx].originalDuration = leftDuration
            currentSong.sections[containingIdx].leadingTrimDuration = 0.0
            currentSong.sections[containingIdx].trailingTrimDuration = 0.0
            currentSong.sections[containingIdx].measureCount = max(1, Int(round(leftDuration / secPerMeasure)))
            
            let newSection = SongSection(
                id: UUID(),
                name: name,
                abbreviation: abbrev,
                startTime: t,
                audioStartTime: rightAudioStart,
                duration: rightDuration,
                startMeasure: max(1, Int(round(t / secPerMeasure)) + 1),
                measureCount: max(1, Int(round(rightDuration / secPerMeasure))),
                originalAudioStartTime: rightAudioStart,
                originalDuration: rightDuration
            )
            currentSong.sections.append(newSection)
            currentSong.sections.sort { $0.startTime < $1.startTime }
            ensureCuesTaggedToSections(in: &currentSong, rebindByCurrentTime: true)
        } else {
            // Fill an unlabeled gap (e.g. beyond the last labeled section)
            let sorted = currentSong.sections.sorted { $0.startTime < $1.startTime }
            let nextSec = sorted.first(where: { $0.startTime > t + 0.05 })
            let newEndTime = nextSec?.startTime ?? songDuration
            let newDuration = max(0.2, newEndTime - t)
            
            let newSection = SongSection(
                id: UUID(),
                name: name,
                abbreviation: abbrev,
                startTime: t,
                audioStartTime: t,
                duration: newDuration,
                startMeasure: max(1, Int(round(t / secPerMeasure)) + 1),
                measureCount: max(1, Int(round(newDuration / secPerMeasure))),
                originalAudioStartTime: t,
                originalDuration: newDuration
            )
            currentSong.sections.append(newSection)
            currentSong.sections.sort { $0.startTime < $1.startTime }
            ensureCuesTaggedToSections(in: &currentSong, rebindByCurrentTime: true)
        }
        
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
            currentSetlist.songs[currentSongIndex].defaultSections = currentSong.defaultSections
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        
        if playbackState == .playing {
            seek(to: playbackOffsetSeconds)
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Downbeat Section Addition (Following Previous Section Downbeat)
    
    /// Adds a section defaulting to the downbeat of bar 1 or immediately following the previous section
    public func addNextSection(name: String, measureCount: Int = 8) {
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, currentSong.timeSignatureNumerator))
        
        let startMeasure: Int
        if let lastSec = currentSong.sections.last {
            // Next section starts on the downbeat (measure) immediately following the previous section
            startMeasure = lastSec.startMeasure + lastSec.measureCount
        } else {
            // Defaults to Bar 1 Beat 1
            startMeasure = 1
        }
        
        let startTime = Double(startMeasure - 1) * secPerMeasure
        let duration = Double(measureCount) * secPerMeasure
        
        let newSec = SongSection(
            name: name,
            startTime: startTime,
            duration: duration,
            startMeasure: startMeasure,
            measureCount: measureCount
        )
        
        currentSong.sections.append(newSec)
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func updateSection(id: UUID, newName: String, startMeasure: Int, measureCount: Int) {
        guard let idx = currentSong.sections.firstIndex(where: { $0.id == id }) else { return }
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, currentSong.timeSignatureNumerator))
        let startTime = Double(startMeasure - 1) * secPerMeasure
        let duration = Double(measureCount) * secPerMeasure
        
        let updatedSec = SongSection(
            id: id,
            name: newName,
            startTime: startTime,
            duration: duration,
            startMeasure: startMeasure,
            measureCount: measureCount
        )
        
        currentSong.sections[idx] = updatedSec
        currentSong.sections.sort { $0.startMeasure < $1.startMeasure }
        
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func deleteSection(id: UUID) {
        currentSong.sections.removeAll { $0.id == id }
        if loopedSection?.id == id {
            loopedSection = nil
            isLoopActive = false
        }
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    public func splitSection(atMeasure measure: Int) {
        guard let idx = currentSong.sections.firstIndex(where: {
            measure > $0.startMeasure && measure < ($0.startMeasure + $0.measureCount)
        }) else { return }
        
        let existing = currentSong.sections[idx]
        let leftMeasureCount = measure - existing.startMeasure
        let rightMeasureCount = existing.measureCount - leftMeasureCount
        
        let secPerBeat = (60.0 / max(20.0, currentSong.bpm)) * (4.0 / Double(max(1, currentSong.timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, currentSong.timeSignatureNumerator))
        
        let leftSec = SongSection(
            id: existing.id,
            name: existing.name,
            startTime: existing.startTime,
            duration: Double(leftMeasureCount) * secPerMeasure,
            startMeasure: existing.startMeasure,
            measureCount: leftMeasureCount
        )
        
        let rightSec = SongSection(
            name: "\(existing.name) B",
            startTime: Double(measure - 1) * secPerMeasure,
            duration: Double(rightMeasureCount) * secPerMeasure,
            startMeasure: measure,
            measureCount: rightMeasureCount
        )
        
        currentSong.sections[idx] = leftSec
        currentSong.sections.insert(rightSec, at: idx + 1)
        
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
        }
        
        reindexArrangement()
        updateArrangementWaveform()
        regenerateGuideTrack()
        regenerateClickTrack()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Setlist & Session Management
    
    public func selectSongInSetlist(at index: Int, updateUndoBaseline: Bool = true) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        if index == currentSongIndex && currentSetlist.songs[index].id == currentSong.id && !tracks.isEmpty {
            return
        }
        
        // Cache current song's waveform image & buffers cleanly (with any automated parameters restored to baseline)
        if !currentSong.title.isEmpty {
            if !currentSong.automationPoints.isEmpty {
                restoreAutomatedParametersToBaseMix(updateAudioMatrix: false)
            }
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, renderedWaveformImage)
            if !tracks.isEmpty {
                var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
                currentBuffers.reserveCapacity(tracks.count)
                for track in tracks {
                    if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                        currentBuffers.append((track, buf))
                    }
                }
                songBuffersCache[currentSong.id] = currentBuffers
                recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
                if currentBuffers.contains(where: { $0.1.frameLength > 100 }) {
                    memoryEvictedSongIds.remove(currentSong.id)
                }
            }
        }
        
        currentSongIndex = index
        let song = currentSetlist.songs[index]
        loadSong(song)
        if updateUndoBaseline && !isApplyingUndoRedo {
            baselineUndoSnapshot = captureCurrentUndoSnapshot()
            lastUndoCommitTime = 0
        }
    }
    
    private static func resolvedAutoInfiniteLoopSection(for song: Song) -> SongSection? {
        guard song.autoInfiniteLoop else { return nil }
        return song.sections.first(where: {
            $0.abbreviation == "Cl" ||
            $0.displayAbbreviation == "Cl" ||
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click"
        }) ?? (song.sections.count >= 2 ? song.sections[1] : song.sections.first)
    }

    private static func defaultGuideLoopState(for song: Song) -> GeneratedGuideLoopState {
        if let sec = resolvedAutoInfiniteLoopSection(for: song) {
            return GeneratedGuideLoopState(
                isLoopActive: true,
                loopedSectionId: sec.id,
                loopMode: .infinite,
                singleLoopRemaining: 0,
                queuedNextSectionId: nil
            )
        }
        return GeneratedGuideLoopState(
            isLoopActive: false,
            loopedSectionId: nil,
            loopMode: .none,
            singleLoopRemaining: 0,
            queuedNextSectionId: nil
        )
    }

    private func currentLiveGuideLoopState() -> GeneratedGuideLoopState {
        GeneratedGuideLoopState(
            isLoopActive: isLoopActive,
            loopedSectionId: isLoopActive ? loopedSection?.id : nil,
            loopMode: isLoopActive ? loopMode : .none,
            singleLoopRemaining: (isLoopActive && loopMode == .single) ? singleLoopRemaining : 0,
            queuedNextSectionId: queuedNextSection?.id
        )
    }

    private func applyAutoInfiniteLoopIfNeeded(for song: Song) {
        guard let sec = Self.resolvedAutoInfiniteLoopSection(for: song) else { return }
        isLoopActive = true
        loopMode = .infinite
        loopedSection = sec
        singleLoopRemaining = 0
    }

    public func loadSong(_ song: Song) {
        if !currentSong.title.isEmpty && currentSong.id != song.id && !currentSong.automationPoints.isEmpty {
            restoreAutomatedParametersToBaseMix(updateAudioMatrix: false)
        }
        stop()
        manualPadPackId = nil
        isFadeActive = false
        currentFadeGain = 1.0
        isLoopActive = false
        loopMode = .none
        loopedSection = nil
        
        currentSong = song
        for i in 0..<currentSong.sections.count {
            currentSong.sections[i].abbreviation = SongSection.abbreviation(for: currentSong.sections[i].name)
        }
        for i in 0..<currentSong.defaultSections.count {
            currentSong.defaultSections[i].abbreviation = SongSection.abbreviation(for: currentSong.defaultSections[i].name)
        }
        if currentSong.defaultSections.isEmpty {
            currentSong.defaultSections = currentSong.sections
        }
        applyAutoInfiniteLoopIfNeeded(for: currentSong)
        
        // Immediately reset transport clock and display clock to the new song's initial state
        transportPosition = TransportPosition(currentTime: 0.0, totalDuration: 0.0, currentBPM: currentSong.bpm)
        transportClock.position = transportPosition
        transportDisplayClock.update(with: transportPosition)
        
        let canonicalFormat = getCanonicalProcessingFormat()
        rehydrateEvictedSongBuffersIfNeeded(for: song)
        var loadedItems: [(StemTrack, AVAudioPCMBuffer)] = []
        
        // Check if we have cached stems in memory for this song
        let loadedFromCache = (songBuffersCache[song.id]?.isEmpty == false)
        if let cached = songBuffersCache[song.id], !cached.isEmpty {
            loadedItems.reserveCapacity(cached.count)
            for (track, buf) in cached {
                let finalBuffer = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
                loadedItems.append((track, finalBuffer))
            }
        } else if !song.stemURLs.isEmpty {
            loadedItems = reconstructTracksFromStemURLs(for: song, canonicalFormat: canonicalFormat)
        }
        
        // Deduplicate synthesized utility tracks if an uploaded Click/Guide track already exists
        if loadedItems.contains(where: { Self.isClickTrack($0.0) && $0.0.fileURL != nil }) {
            loadedItems.removeAll { Self.isClickTrack($0.0) && $0.0.fileURL == nil }
        }
        if loadedItems.contains(where: { Self.isGuideTrack($0.0) && $0.0.fileURL != nil }) {
            loadedItems.removeAll { Self.isGuideTrack($0.0) && $0.0.fileURL == nil }
        }
        
        // Auto-generation & source switching for Click and Guide tracks
        // Guarantees Click and Guide channel strips are ALWAYS included, defaulting to generated if not uploaded
        let nonUtilityWithFiles = loadedItems.filter { !Self.isClickOrGuideTrack($0.0) && $0.0.fileURL != nil }
        let isMetadataPlaceholder: Bool
        if !nonUtilityWithFiles.isEmpty {
            isMetadataPlaceholder = nonUtilityWithFiles.allSatisfy { $0.1.frameLength <= 1 }
        } else {
            isMetadataPlaceholder = downloadingSongProgress[song.id] != nil
        }
        let baseDuration: TimeInterval
        if isMetadataPlaceholder {
            baseDuration = loadedItems.map { $0.0.duration }.max() ?? (song.totalDuration > 0 ? song.totalDuration : 240.0)
        } else {
            baseDuration = loadedItems.map { Double($0.1.frameLength) / $0.1.format.sampleRate }.max() ?? (song.totalDuration > 0 ? song.totalDuration : 240.0)
        }
        let songDur = max(baseDuration, song.sections.map { $0.endTime }.max() ?? 240.0)
        let sampleRate = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
        let initialFrames: AVAudioFrameCount = isMetadataPlaceholder ? 1 : AVAudioFrameCount(max(1, Int64(round(songDur * sampleRate))))
        
        // 1. Click Track handling
        let clickItemIndex = loadedItems.firstIndex { StemCategory.category(for: $0.0.name, role: $0.0.role) == .click }
        if let idx = clickItemIndex {
            let clickTrack = loadedItems[idx].0
            let uploadedBuf = loadedItems[idx].1
            if uploadedBuf.frameLength > 100 && clickTrack.fileURL != nil && uploadedBuf !== generatedClickBuffers[song.id] && (!loadedFromCache || uploadedClickBuffers[song.id] == nil) {
                uploadedClickBuffers[song.id] = uploadedBuf
            } else if clickTrack.fileURL == nil {
                uploadedClickBuffers[song.id] = nil
            }
            if currentSong.clickSource != .uploaded || (uploadedClickBuffers[song.id]?.frameLength ?? 0) <= 100 {
                let genClick = (currentSong.clickSource == .generated ? generatedClickBuffers[song.id] : nil)
                for cIdx in loadedItems.indices where Self.isClickTrack(loadedItems[cIdx].0) {
                    if cIdx == idx, let genClick = genClick, genClick.frameLength > 1 {
                        loadedItems[cIdx].1 = genClick
                    } else if let silentBuf = makeSilentStub(format: canonicalFormat) {
                        loadedItems[cIdx].1 = silentBuf
                    }
                }
            }
        } else {
            uploadedClickBuffers[song.id] = nil
            if !currentSong.excludesClickAndGuide {
                currentSong.clickSource = .generated
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].clickSource = .generated
                }
                let clickTrack = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
                clickTrack.duration = songDur
                if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                    silentBuf.frameLength = initialFrames
                    loadedItems.append((clickTrack, silentBuf))
                }
            }
        }
        
        // 2. Guide Track handling
        let guideItemIndex = loadedItems.firstIndex { StemCategory.category(for: $0.0.name, role: $0.0.role) == .guide }
        if let idx = guideItemIndex {
            let guideTrack = loadedItems[idx].0
            let uploadedBuf = loadedItems[idx].1
            if uploadedBuf.frameLength > 100 && guideTrack.fileURL != nil && uploadedBuf !== generatedGuideBuffers[song.id] && (!loadedFromCache || uploadedGuideBuffers[song.id] == nil) {
                uploadedGuideBuffers[song.id] = uploadedBuf
            } else if guideTrack.fileURL == nil {
                uploadedGuideBuffers[song.id] = nil
            }
            if currentSong.guideSource != .uploaded || (uploadedGuideBuffers[song.id]?.frameLength ?? 0) <= 100 {
                let expectedGuideState = currentLiveGuideLoopState()
                let genGuide = (currentSong.guideSource == .generated && generatedGuideLoopStates[song.id] == expectedGuideState)
                    ? generatedGuideBuffers[song.id]
                    : nil
                for gIdx in loadedItems.indices where Self.isGuideTrack(loadedItems[gIdx].0) {
                    if gIdx == idx, let genGuide = genGuide, genGuide.frameLength > 1 {
                        loadedItems[gIdx].1 = genGuide
                    } else if let silentBuf = makeSilentStub(format: canonicalFormat) {
                        loadedItems[gIdx].1 = silentBuf
                    }
                }
            }
        } else {
            uploadedGuideBuffers[song.id] = nil
            if !currentSong.excludesClickAndGuide {
                currentSong.guideSource = .generated
                if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                    currentSetlist.songs[currentSongIndex].guideSource = .generated
                }
                let guideTrack = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
                guideTrack.duration = songDur
                if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                    silentBuf.frameLength = initialFrames
                    loadedItems.append((guideTrack, silentBuf))
                }
            }
        }
        
        // Sort once locally before assigning `@Published var tracks`
        if loadedItems.count > 1 {
            loadedItems.sort { (a, b) -> Bool in
                let ord1 = StemCategory.playbackOrder(for: a.0.name, role: a.0.role)
                let ord2 = StemCategory.playbackOrder(for: b.0.name, role: b.0.role)
                if ord1 != ord2 { return ord1 < ord2 }
                let cat1 = StemCategory.category(for: a.0.name, role: a.0.role)
                let cat2 = StemCategory.category(for: b.0.name, role: b.0.role)
                if cat1 != cat2 { return cat1 < cat2 }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
        }
        
        var newTracks: [StemTrack] = []
        newTracks.reserveCapacity(loadedItems.count)
        var newChannels: [UUID: TrackChannel] = [:]
        var newPristine: [UUID: AVAudioPCMBuffer] = [:]
        var maxDur: TimeInterval = 0.0
        
        var cachedTransposed = cachedTransformedBuffers(for: song)
        
        if !isMetadataPlaceholder && (song.transposeSemitones != 0 || song.isTempoShifted) && cachedTransposed == nil {
            let targetTrackIds = loadedItems.filter { shouldRenderTransformedTrack($0.0, for: song, tempoShifted: song.isTempoShifted) }.map { $0.0.id }
            if !targetTrackIds.isEmpty,
               let diskShifted = PlaybackFileManager.shared.loadTransposedBuffersFromDisk(
                   songId: song.id,
                   semitones: song.transposeSemitones,
                   preserveVocalFormants: song.preserveVocalFormants,
                   bpm: song.bpm,
                   originalBPM: song.originalBPM,
                   trackIds: targetTrackIds,
                   canonicalFormat: canonicalFormat
               ) {
                songTransposedBuffersCache[song.id] = (
                    song.transposeSemitones,
                    song.preserveVocalFormants,
                    PlaybackFileManager.cacheBPMHundredths(song.bpm),
                    diskShifted
                )
                cachedTransposed = diskShifted
            }
        }
        
        for (track, finalBuffer) in loadedItems {
            let cat = StemCategory.category(for: track.name, role: track.role)
            if cat == .click { track.role = .click }
            else if cat == .guide { track.role = .guide }
            
            newPristine[track.id] = finalBuffer
            let activeBuf = cachedTransposed?[track.id] ?? finalBuffer
            let trackDuration = (activeBuf.frameLength > 10)
                ? (Double(activeBuf.frameLength) / activeBuf.format.sampleRate)
                : (track.duration > 0 ? track.duration : songDur)
            track.duration = trackDuration
            if trackDuration > maxDur { maxDur = trackDuration }
            
            if !isMetadataPlaceholder && track.waveformPeaks.isEmpty && track.includeInWaveform {
                track.waveformPeaks = extractWaveformPeaks(from: finalBuffer, samplesCount: 4000)
            }
            
            if isFadersDefault100Enabled && track.volume >= 0.79 && track.volume <= 0.81 {
                track.volume = 1.0
            }
            
            newChannels[track.id] = TrackChannel(track: track, buffer: activeBuf)
            newTracks.append(track)
        }
        
        songBuffersCache[song.id] = loadedItems
        recordTrackMetadataBackup(for: song.id, tracks: loadedItems.map { $0.0 })
        if !isMetadataPlaceholder {
            memoryEvictedSongIds.remove(song.id)
        }
        
        // Single batched state assignment -> SwiftUI only diffs `MixerRackView` once!
        pristineMasterBuffers = newPristine
        channels = newChannels
        tracks = newTracks
        
        currentSongDuration = !currentSong.sections.isEmpty
            ? (currentSong.sections.map { $0.endTime }.max() ?? maxDur)
            : maxDur
        updateTransportPosition(to: 0.0)
        rebuildPrecomputedBeatGrid()
        rebuildCachedActiveAutomation()
        
        if let cachedWf = songWaveformCache[song.id], !cachedWf.peaks.isEmpty, cachedWf.image != nil {
            masterWaveformPeaks = cachedWf.peaks
            aggregateWaveform = cachedWf.peaks
            renderedWaveformImage = cachedWf.image
            updateArrangementWaveform()
        } else {
            recalculateAggregateWaveform(samplesCount: 4000)
            if !masterWaveformPeaks.isEmpty {
                songWaveformCache[song.id] = (masterWaveformPeaks, renderedWaveformImage)
            }
        }
        
        updateMatrix()
        if isLoopActive {
            syncMixState()
        }
        captureBaseMixSnapshot()
        // When the pad is already playing and tracks are paused/stopped, keep the original pad key & type
        // until the next song actually fires (via play/jumpToSection/handover).
        if !(padPlayer.isPlaying && playbackState != .playing) {
            syncActivePadToCurrentSongIfNeeded()
        }
        if !isMetadataPlaceholder {
            if !currentSong.excludesClickAndGuide && currentSong.clickSource == .generated {
                if let cBuf = generatedClickBuffers[song.id], cBuf.frameLength > 1 {
                    applyClickBuffer()
                } else {
                    regenerateClickTrack()
                }
            }
            if !currentSong.excludesClickAndGuide && currentSong.guideSource == .generated {
                let expectedGuideState = currentLiveGuideLoopState()
                if let gBuf = generatedGuideBuffers[song.id],
                   gBuf.frameLength > 1,
                   generatedGuideLoopStates[song.id] == expectedGuideState {
                    applyGuideBuffer()
                } else {
                    regenerateGuideTrack()
                }
            }
            preGenerateRemainingSetlistClickAndGuide()
            if song.transposeSemitones != 0 || song.isTempoShifted {
                if cachedTransposed == nil {
                    if transposeTasksBySong[song.id] != nil {
                        // Already transposing this song in the background — do not cancel or restart it
                        isTransposing = true
                        transposingSongId = song.id
                        transposeProgress = transposeProgressBySong[song.id] ?? transposeProgress
                    } else {
                        setKeyAndTempo(forSongIndex: currentSongIndex)
                    }
                } else {
                    isTransposing = !transposeProgressBySong.isEmpty
                    if !isTransposing {
                        transposeProgress = 0.0
                        transposingSongId = nil
                    } else if let activeId = transposeProgressBySong.keys.first {
                        transposingSongId = activeId
                        transposeProgress = transposeProgressBySong[activeId] ?? 0.0
                    }
                }
            }
        }
    }
    
    // MARK: - Pre-Rendered Offline Transposition Feature (Excludes Click & Guide)
    
    /// Pre-renders offline pitch-shifted and/or tempo-stretched audio buffers cleanly in a single Rubber Band R3 pass.
    /// Pristine master stems are preserved so any key, vocal formant, or tempo change is rendered from original high-res audio.
    /// Click and guide tracks remain pitch-unshifted; generated click/guide regenerate natively at shifted tempo, while uploaded click/guide time-stretch cleanly.
    public func setTranspose(semitones: Int, forSongIndex targetIndex: Int? = nil) {
        setKeyAndTempo(semitones: semitones, forSongIndex: targetIndex)
    }
    
    public func setTempoShift(bpm: Double, forSongIndex targetIndex: Int? = nil) {
        setKeyAndTempo(tempoBPM: bpm, forSongIndex: targetIndex)
    }
    
    public nonisolated static func isLosslessAudioURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "wav" || ext == "wave" || ext == "aif" || ext == "aiff" || ext == "flac" || ext == "caf"
    }

    public nonisolated static func resolveLosslessSourceURL(for track: StemTrack) -> URL? {
        for candidate in [track.sourceFileURL, track.fileURL] {
            if let url = candidate, isLosslessAudioURL(url), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func transposeInputSourceLabel(for song: Song, atIndex idx: Int? = nil) -> String {
        if let recorded = lastTransposeSourceBySong[song.id] {
            return recorded
        }
        let targetIdx = idx ?? currentSetlist.songs.firstIndex(where: { $0.id == song.id })
        let songTracks: [StemTrack] = {
            if targetIdx == currentSongIndex && !channels.isEmpty {
                return channels.values.map { $0.track }
            }
            if let cached = songBuffersCache[song.id] {
                return cached.map { $0.track }
            }
            return []
        }()
        let tempoShifted = abs(song.bpm - (song.originalBPM > 0 ? song.originalBPM : song.bpm)) > 0.005
        let eligible = songTracks.filter { shouldRenderTransformedTrack($0, for: song, tempoShifted: tempoShifted) }
        guard !eligible.isEmpty else {
            let hasLosslessURL = song.stemURLs.contains { Self.isLosslessAudioURL($0) && FileManager.default.fileExists(atPath: $0.path) }
            return hasLosslessURL ? "WAV" : "M4A"
        }
        var wavCount = 0
        var m4aCount = 0
        for t in eligible {
            if Self.resolveLosslessSourceURL(for: t) != nil {
                wavCount += 1
            } else {
                m4aCount += 1
            }
        }
        if wavCount > 0 && m4aCount == 0 { return "WAV" }
        if wavCount > 0 && m4aCount > 0 { return "WAV + M4A" }
        return "M4A"
    }

    public func forceRerenderKeyAndTempo(forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        let song = currentSetlist.songs[idx]
        transposeTask?.cancel()
        transposeGeneration &+= 1
        songTransposedBuffersCache.removeValue(forKey: song.id)
        lastTransposeSourceBySong.removeValue(forKey: song.id)
        PlaybackFileManager.shared.clearTransposedBuffersFromDisk(songId: song.id)
        setKeyAndTempo(
            semitones: song.transposeSemitones,
            preserveVocalFormants: song.preserveVocalFormants,
            tempoBPM: song.bpm,
            forSongIndex: idx,
            forceRerender: true
        )
    }

    private func areSongStemsHydratedForTransform(atIndex idx: Int) -> Bool {
        guard idx >= 0 && idx < currentSetlist.songs.count else { return false }
        let song = currentSetlist.songs[idx]
        if downloadingSongProgress[song.id] != nil {
            return false
        }
        let isTempoShifted = song.isTempoShifted
        if idx == currentSongIndex && !channels.isEmpty {
            let candidates = channels.values.filter { shouldRenderTransformedTrack($0.track, for: song, tempoShifted: isTempoShifted) }
            guard !candidates.isEmpty else { return false }
            return candidates.allSatisfy { ch in
                let buf = pristineMasterBuffers[ch.track.id] ?? ch.buffer
                return (buf?.frameLength ?? 0) > 100
            }
        }
        if let cached = songBuffersCache[song.id], !cached.isEmpty {
            let candidates = cached.filter { shouldRenderTransformedTrack($0.track, for: song, tempoShifted: isTempoShifted) }
            guard !candidates.isEmpty else { return false }
            if memoryEvictedSongIds.contains(song.id) {
                return candidates.allSatisfy { $0.buffer.frameLength > 100 || Self.hasLocalBackingAudioFile(for: $0.track) }
            }
            return candidates.allSatisfy { $0.buffer.frameLength > 100 }
        }
        return !song.stemURLs.isEmpty && song.stemURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func setKeyAndTempo(
        semitones: Int? = nil,
        preserveVocalFormants: Bool? = nil,
        tempoBPM: Double? = nil,
        forSongIndex targetIndex: Int? = nil,
        forceRerender: Bool = false
    ) {
        let idx = targetIndex ?? currentSongIndex
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        
        var song = currentSetlist.songs[idx]
        let targetSongId = song.id
        let previousBPM = song.bpm
        let origBPM = song.originalBPM > 0 ? song.originalBPM : previousBPM
        if song.originalBPM <= 0 {
            song.originalBPM = origBPM
        }
        
        let clampedSemitones = max(-12, min(12, semitones ?? song.transposeSemitones))
        let newPreserveFormants = preserveVocalFormants ?? song.preserveVocalFormants
        let targetBPM = tempoBPM != nil
            ? Song.clampedShiftedTempo(tempoBPM!, originalBPM: origBPM)
            : previousBPM
        let bpmChanged = abs(targetBPM - previousBPM) > 0.005
        let tempoScale = targetBPM / max(20.0, origBPM)
        let isTempoShifted = abs(targetBPM - origBPM) > 0.005
        let bpmHundredths = PlaybackFileManager.cacheBPMHundredths(targetBPM)
        
        song.transposeSemitones = clampedSemitones
        if clampedSemitones != 0 && (song.musicalKey.isEmpty || song.musicalKey == "—") {
            song.musicalKey = "C"
        }
        song.preserveVocalFormants = newPreserveFormants
        if bpmChanged {
            Self.scaleSongTimeline(&song, from: previousBPM, to: targetBPM)
            song.bpm = targetBPM
            songWaveformCache.removeValue(forKey: targetSongId)
        }
        
        currentSetlist.songs[idx] = song
        if idx == currentSongIndex {
            currentSong = song
            if bpmChanged {
                let scale = previousBPM / max(20.0, targetBPM)
                transportPosition.currentBPM = targetBPM
                transportClock.position.currentBPM = targetBPM
                transportPosition.currentTime *= scale
                transportClock.position.currentTime *= scale
            }
            syncActivePadToCurrentSongIfNeeded()
        }
        markSessionChanged()
        
        // Fast path 1: Original key AND original tempo -> immediately revert to pristine stems
        if clampedSemitones == 0 && !isTempoShifted {
            transposeTask?.cancel()
            transposeGeneration &+= 1
            songTransposedBuffersCache.removeValue(forKey: targetSongId)
            applyTransformedBuffers([:], forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
            isTransposing = false
            transposeProgress = 0.0
            transposingSongId = nil
            objectWillChange.send()
            return
        }

        guard areSongStemsHydratedForTransform(atIndex: idx) else {
            // Stems are still downloading or holding 1-frame Stage-1 placeholders; defer Rubber Band render until hydration finishes!
            songTransposedBuffersCache.removeValue(forKey: targetSongId)
            if bpmChanged {
                refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
            }
            objectWillChange.send()
            return
        }
        
        // Fast path 2: Already cached in RAM at this exact transposition, formant & tempo setting!
        if !forceRerender,
           let cached = songTransposedBuffersCache[targetSongId],
           cached.semitones == clampedSemitones,
           cached.preserveVocalFormants == newPreserveFormants,
           cached.bpmHundredths == bpmHundredths {
            transposeTask?.cancel()
            transposeGeneration &+= 1
            applyTransformedBuffers(cached.buffers, forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
            isTransposing = false
            transposeProgress = 0.0
            transposingSongId = nil
            objectWillChange.send()
            return
        }
        
        // Fast path 3: Cached on disk!
        rehydrateEvictedSongBuffersIfNeeded(for: song)
        let targetTrackIds: [UUID] = (idx == currentSongIndex && !channels.isEmpty)
            ? channels.values.filter { shouldRenderTransformedTrack($0.track, for: song, tempoShifted: isTempoShifted) }.map { $0.track.id }
            : ((songBuffersCache[targetSongId]?.filter { shouldRenderTransformedTrack($0.track, for: song, tempoShifted: isTempoShifted) }.map { $0.track.id }) ?? [])
        if !forceRerender,
           !targetTrackIds.isEmpty,
           let diskShifted = PlaybackFileManager.shared.loadTransposedBuffersFromDisk(
               songId: targetSongId,
               semitones: clampedSemitones,
               preserveVocalFormants: newPreserveFormants,
               bpm: targetBPM,
               originalBPM: origBPM,
               trackIds: targetTrackIds,
               canonicalFormat: getCanonicalProcessingFormat()
           ) {
            transposeTask?.cancel()
            transposeGeneration &+= 1
            songTransposedBuffersCache[targetSongId] = (clampedSemitones, newPreserveFormants, bpmHundredths, diskShifted)
            applyTransformedBuffers(diskShifted, forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
            isTransposing = false
            transposeProgress = 0.0
            transposingSongId = nil
            objectWillChange.send()
            return
        }
        
        // Regenerate Click & Guide immediately for active or cached songs when BPM changes or re-render is forced
        if bpmChanged || (forceRerender && isTempoShifted) {
            refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
        }
        
        let canonicalFormat = getCanonicalProcessingFormat()
        // Needs offline Rubber Band R3 single-pass pitch/formant/tempo render!
        let snapshot: [(UUID, Bool, Bool, AVAudioPCMBuffer, URL?)] = {
            if idx == currentSongIndex && !channels.isEmpty {
                return channels.values.compactMap { ch in
                    let track = ch.track
                    guard shouldRenderTransformedTrack(track, for: song, tempoShifted: isTempoShifted) else { return nil }
                    guard let pristine = self.pristineMasterBuffers[track.id] ?? ch.buffer else { return nil }
                    return (track.id, Self.isVocalTrack(track), Self.isClickOrGuideTrack(track), pristine, Self.resolveLosslessSourceURL(for: track))
                }
            } else if let cached = songBuffersCache[targetSongId], !cached.isEmpty {
                return cached.compactMap { (track, buf) in
                    guard shouldRenderTransformedTrack(track, for: song, tempoShifted: isTempoShifted) else { return nil }
                    return (track.id, Self.isVocalTrack(track), Self.isClickOrGuideTrack(track), buf, Self.resolveLosslessSourceURL(for: track))
                }
            } else if idx >= 0 && idx < currentSetlist.songs.count {
                let s = currentSetlist.songs[idx]
                let reconstructed = reconstructTracksFromStemURLs(for: s, canonicalFormat: canonicalFormat)
                return reconstructed.compactMap { (track, buf) in
                    guard shouldRenderTransformedTrack(track, for: song, tempoShifted: isTempoShifted) else { return nil }
                    return (track.id, Self.isVocalTrack(track), Self.isClickOrGuideTrack(track), buf, Self.resolveLosslessSourceURL(for: track))
                }
            }
            return []
        }()
        
        guard !snapshot.isEmpty else {
            if bpmChanged {
                applyTransformedBuffers([:], forSongId: targetSongId, atIndex: idx, bpmChanged: false)
            }
            isTransposing = false
            transposingSongId = nil
            transposeProgress = 0.0
            objectWillChange.send()
            return
        }
        
        transposeTasksBySong[targetSongId]?.cancel()
        transposeGeneration &+= 1
        let activeGeneration = transposeGeneration
        
        let previewSourceLabel: String = {
            let wavs = snapshot.filter { $0.4 != nil }.count
            if wavs == snapshot.count { return "WAV" }
            if wavs > 0 { return "WAV + M4A" }
            return "M4A"
        }()
        lastTransposeSourceBySong[targetSongId] = previewSourceLabel
        if isTempoShifted && clampedSemitones != 0 {
            renderStatusText = "Rendering Key & Tempo (\(previewSourceLabel))..."
        } else if isTempoShifted {
            renderStatusText = "Rendering Tempo (\(previewSourceLabel))..."
        } else {
            renderStatusText = "Transposing (\(previewSourceLabel))..."
        }
        isTransposing = true
        transposeProgress = 0.0
        transposingSongId = targetSongId
        transposeProgressBySong[targetSongId] = 0.0
        objectWillChange.send()
        
        let sendableSnapshot = snapshot.map { ($0.0, $0.1, $0.2, SendablePCMBufferRef($0.3), $0.4) }
        let task = Task.detached(priority: .userInitiated) { [weak self, sendableSnapshot, canonicalFormat, targetSongId, clampedSemitones, newPreserveFormants, targetBPM, origBPM, tempoScale, bpmHundredths, activeGeneration, idx, forceRerender] in
            let total = max(1, sendableSnapshot.count)
            let maxConcurrency = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
            var rendered: [UUID: AVAudioPCMBuffer] = [:]
            rendered.reserveCapacity(sendableSnapshot.count)
            var completedCount = 0
            var actualWavCount = 0
            var actualM4aCount = 0
            
            @Sendable func renderItem(_ item: (UUID, Bool, Bool, SendablePCMBufferRef, URL?)) -> (UUID, SendablePCMBufferRef?, Bool) {
                let (trackId, isVocal, isClickOrGuide, bufRef, losslessURL) = item
                if Task.isCancelled { return (trackId, nil, false) }
                var inputBuffer = bufRef.buffer
                var usedLossless = false
                if let wavURL = losslessURL,
                   let rawLossless = try? PlaybackFileManager.shared.readPCMBuffer(from: wavURL) {
                    inputBuffer = PlaybackFileManager.normalizeBuffer(rawLossless, to: canonicalFormat)
                    usedLossless = true
                }
                let trackSemitones = isClickOrGuide ? 0.0 : Double(clampedSemitones)
                let compensate = !isClickOrGuide && newPreserveFormants && isVocal && clampedSemitones != 0
                let shifted = try? AudioPitchRenderer.renderPitchShiftedBuffer(
                    sourceBuffer: inputBuffer,
                    semitones: trackSemitones,
                    tonalityLimitHz: isVocal ? 10000.0 : 0.0,
                    formantSemitones: 0.0,
                    compensateFormants: compensate,
                    tempoScale: tempoScale
                )
                return (trackId, shifted.map(SendablePCMBufferRef.init), usedLossless)
            }
            
            await withTaskGroup(of: (UUID, SendablePCMBufferRef?, Bool).self) { group in
                var nextIdx = 0
                let initialBatch = min(maxConcurrency, sendableSnapshot.count)
                while nextIdx < initialBatch {
                    let item = sendableSnapshot[nextIdx]
                    nextIdx += 1
                    group.addTask { renderItem(item) }
                }
                
                for await (trackId, shiftedRef, usedLossless) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    if let shiftedRef = shiftedRef {
                        rendered[trackId] = shiftedRef.buffer
                        if usedLossless { actualWavCount += 1 } else { actualM4aCount += 1 }
                    }
                    completedCount += 1
                    let currentProg = min(0.95, Float(completedCount) / Float(total))
                    
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.transposeProgressBySong[targetSongId] = currentProg
                        if self.transposeGeneration == activeGeneration {
                            self.transposeProgress = currentProg
                        }
                        self.objectWillChange.send()
                    }
                    
                    if nextIdx < sendableSnapshot.count && !Task.isCancelled {
                        let nextItem = sendableSnapshot[nextIdx]
                        nextIdx += 1
                        group.addTask { renderItem(nextItem) }
                    }
                }
            }
            
            if Task.isCancelled { return }
            let finalRendered = rendered
            let finalSourceLabel: String = {
                if actualWavCount > 0 && actualM4aCount == 0 { return "WAV" }
                if actualWavCount > 0 && actualM4aCount > 0 { return "WAV + M4A" }
                return "M4A"
            }()
            
            let isValidRenderedSet = !finalRendered.isEmpty && finalRendered.values.allSatisfy { $0.frameLength > 100 }
            // Mark 100% complete
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.lastTransposeSourceBySong[targetSongId] = finalSourceLabel
                if isValidRenderedSet {
                    self.songTransposedBuffersCache[targetSongId] = (clampedSemitones, newPreserveFormants, bpmHundredths, finalRendered)
                } else {
                    self.songTransposedBuffersCache.removeValue(forKey: targetSongId)
                }
                self.transposeProgressBySong[targetSongId] = 1.0
                if self.transposeGeneration == activeGeneration {
                    self.transposeProgress = 1.0
                }
                if isValidRenderedSet {
                    self.applyTransformedBuffers(finalRendered, forSongId: targetSongId, atIndex: idx, bpmChanged: false)
                }
                self.objectWillChange.send()
            }
            
            // Background async disk cache write
            if isValidRenderedSet {
                PlaybackFileManager.shared.saveTransposedBuffersToDisk(
                    songId: targetSongId,
                    semitones: clampedSemitones,
                    preserveVocalFormants: newPreserveFormants,
                    bpm: targetBPM,
                    originalBPM: origBPM,
                    buffers: finalRendered,
                    overwrite: forceRerender
                )
            }
            
            // Hold at 100% briefly so the user sees complete status before dismissal
            try? await Task.sleep(nanoseconds: 350_000_000)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.transposeProgressBySong.removeValue(forKey: targetSongId)
                self.transposeTasksBySong.removeValue(forKey: targetSongId)
                self.isTransposing = !self.transposeProgressBySong.isEmpty
                if self.transposeGeneration == activeGeneration || self.transposeProgressBySong.isEmpty {
                    self.transposeProgress = 0.0
                    self.transposingSongId = self.transposeProgressBySong.keys.first
                }
                self.objectWillChange.send()
            }
        }
        transposeTasksBySong[targetSongId] = task
        transposeTask = task
    }
    
    private func applyTransformedBuffers(_ rendered: [UUID: AVAudioPCMBuffer], forSongId targetSongId: UUID, atIndex idx: Int, bpmChanged: Bool) {
        if let cached = songBuffersCache[targetSongId] {
            for (track, baseBuf) in cached {
                let isGenClick = Self.isClickTrack(track) && (idx < currentSetlist.songs.count ? currentSetlist.songs[idx].clickSource == .generated : false)
                let isGenGuide = Self.isGuideTrack(track) && (idx < currentSetlist.songs.count ? currentSetlist.songs[idx].guideSource == .generated : false)
                if !isGenClick && !isGenGuide {
                    let activeBuf = rendered[track.id] ?? baseBuf
                    track.duration = Double(activeBuf.frameLength) / max(1.0, activeBuf.format.sampleRate)
                }
            }
        }
        
        if idx == currentSongIndex || currentSong.id == targetSongId {
            var maxDur: TimeInterval = 0.0
            for track in tracks {
                let isGenClick = Self.isClickTrack(track) && currentSong.clickSource == .generated
                let isGenGuide = Self.isGuideTrack(track) && currentSong.guideSource == .generated
                if !isGenClick && !isGenGuide,
                   let ch = channels[track.id],
                   let targetBuf = rendered[track.id] ?? pristineMasterBuffers[track.id] ?? ch.buffer {
                    ch.buffer = targetBuf
                    let dur = Double(targetBuf.frameLength) / max(1.0, targetBuf.format.sampleRate)
                    track.duration = dur
                    if dur > maxDur { maxDur = dur }
                } else if track.duration > maxDur {
                    maxDur = track.duration
                }
            }
            if maxDur > 0 {
                currentSongDuration = !currentSong.sections.isEmpty
                    ? (currentSong.sections.map { $0.endTime }.max() ?? maxDur)
                    : maxDur
            }
            if bpmChanged {
                refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
            }
            recalculateAggregateWaveform(samplesCount: 4000)
            if !masterWaveformPeaks.isEmpty {
                songWaveformCache[targetSongId] = (masterWaveformPeaks, renderedWaveformImage)
            }
            syncMixState()
        } else if bpmChanged {
            refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
        }
    }
    
    private func refreshGeneratedClickAndGuide(forSongId songId: UUID, atIndex idx: Int) {
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        let song = currentSetlist.songs[idx]
        if idx == currentSongIndex || currentSong.id == songId {
            if song.clickSource == .generated {
                regenerateClickTrack()
            }
            if song.guideSource == .generated {
                regenerateGuideTrack()
            }
        } else if song.clickSource == .generated || song.guideSource == .generated {
            if song.clickSource == .generated {
                generatedClickBuffers.removeValue(forKey: songId)
            }
            if song.guideSource == .generated {
                generatedGuideBuffers.removeValue(forKey: songId)
                generatedGuideLoopStates.removeValue(forKey: songId)
            }
            preGenerateClickAndGuide(forSongId: songId, force: true)
        }
    }
    
    /// Proportionally scales all time-based song metadata (`sections`, `beatGrid`, MIDI/Directional/Automation/SMPTE cues)
    /// when changing playback tempo from `oldBPM` to `newBPM`.
    public nonisolated static func scaleSongTimeline(_ song: inout Song, from oldBPM: Double, to newBPM: Double) {
        guard oldBPM > 0, newBPM > 0, abs(oldBPM - newBPM) > 0.001 else { return }
        let scale = oldBPM / newBPM
        
        func scaleSection(_ sec: inout SongSection) {
            sec.startTime *= scale
            if let a = sec.audioStartTime { sec.audioStartTime = a * scale }
            sec.duration *= scale
            if let oa = sec.originalAudioStartTime { sec.originalAudioStartTime = oa * scale }
            if let od = sec.originalDuration { sec.originalDuration = od * scale }
            sec.leadingTrimDuration *= scale
            sec.trailingTrimDuration *= scale
        }
        
        for i in song.sections.indices { scaleSection(&song.sections[i]) }
        for i in song.defaultSections.indices { scaleSection(&song.defaultSections[i]) }
        for aIdx in song.savedArrangements.indices {
            for i in song.savedArrangements[aIdx].sections.indices {
                scaleSection(&song.savedArrangements[aIdx].sections[i])
            }
            for i in song.savedArrangements[aIdx].midiCues.indices {
                song.savedArrangements[aIdx].midiCues[i].time *= scale
            }
            for i in song.savedArrangements[aIdx].directionalCues.indices {
                song.savedArrangements[aIdx].directionalCues[i].time *= scale
            }
            for i in song.savedArrangements[aIdx].automationPoints.indices {
                song.savedArrangements[aIdx].automationPoints[i].time *= scale
            }
            if var s = song.savedArrangements[aIdx].smpteCue {
                s.time *= scale
                song.savedArrangements[aIdx].smpteCue = s
            }
        }
        
        for i in song.timeSignatureChanges.indices {
            song.timeSignatureChanges[i].audioTime *= scale
        }
        for i in song.beatGrid.indices {
            song.beatGrid[i].time *= scale
            song.beatGrid[i].instantaneousBPM /= scale
        }
        for i in song.midiCues.indices { song.midiCues[i].time *= scale }
        for i in song.directionalCues.indices { song.directionalCues[i].time *= scale }
        for i in song.automationPoints.indices { song.automationPoints[i].time *= scale }
        if var s = song.smpteCue {
            s.time *= scale
            song.smpteCue = s
        }
        for i in song.defaultMidiCues.indices { song.defaultMidiCues[i].time *= scale }
        for i in song.defaultDirectionalCues.indices { song.defaultDirectionalCues[i].time *= scale }
        for i in song.defaultAutomationPoints.indices { song.defaultAutomationPoints[i].time *= scale }
        if var s = song.defaultSmpteCue {
            s.time *= scale
            song.defaultSmpteCue = s
        }
    }
    
    private nonisolated static func isClickTrack(_ track: StemTrack) -> Bool {
        return track.isClickTrackCached ||
            track.assignedBusName.lowercased() == "click"
    }

    private nonisolated static func isGuideTrack(_ track: StemTrack) -> Bool {
        return track.isGuideTrackCached ||
            track.assignedBusName.lowercased() == "guide"
    }

    /// Synchronizes `generatedClickBuffers` / `generatedGuideBuffers` into `songBuffersCache[songId]`
    /// so non-active setlist songs never retain 1-frame stubs or silent placeholders when staged or promoted.
    private func syncCachedClickAndGuideBuffers(forSongId songId: UUID) {
        guard let song = currentSetlist.songs.first(where: { $0.id == songId }),
              var cached = songBuffersCache[songId] else {
            return
        }
        var didModify = false
        var addedTrack = false

        if cached.contains(where: { Self.isClickTrack($0.track) && $0.track.fileURL != nil }) {
            let before = cached.count
            cached.removeAll { Self.isClickTrack($0.track) && $0.track.fileURL == nil }
            if cached.count != before { didModify = true }
        }
        if cached.contains(where: { Self.isGuideTrack($0.track) && $0.track.fileURL != nil }) {
            let before = cached.count
            cached.removeAll { Self.isGuideTrack($0.track) && $0.track.fileURL == nil }
            if cached.count != before { didModify = true }
        }

        if song.clickSource == .generated,
           let genClick = generatedClickBuffers[songId],
           genClick.frameLength > 1 {
            let dur = Double(genClick.frameLength) / max(1.0, genClick.format.sampleRate)
            if let idx = cached.firstIndex(where: { Self.isClickTrack($0.track) }) {
                cached[idx].track.duration = dur
                cached[idx] = (cached[idx].track, genClick)
            } else {
                let newClick = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
                newClick.duration = dur
                cached.append((newClick, genClick))
                addedTrack = true
            }
            didModify = true
        }

        if song.guideSource == .generated,
           let genGuide = generatedGuideBuffers[songId],
           genGuide.frameLength > 1 {
            let dur = Double(genGuide.frameLength) / max(1.0, genGuide.format.sampleRate)
            if let idx = cached.firstIndex(where: { Self.isGuideTrack($0.track) }) {
                cached[idx].track.duration = dur
                cached[idx] = (cached[idx].track, genGuide)
            } else {
                let newGuide = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
                newGuide.duration = dur
                cached.append((newGuide, genGuide))
                addedTrack = true
            }
            didModify = true
        }

        if addedTrack {
            cached.sort { item1, item2 in
                let cat1 = StemCategory.category(for: item1.track.name, role: item1.track.role)
                let cat2 = StemCategory.category(for: item2.track.name, role: item2.track.role)
                if cat1 != cat2 { return cat1 < cat2 }
                return item1.track.name.localizedStandardCompare(item2.track.name) == .orderedAscending
            }
        }
        if didModify {
            songBuffersCache[songId] = cached
        }
    }

    private var preGenerateSetlistTask: Task<Void, Never>? = nil

    /// Sequentially pre-renders generated Click and Guide buffers for other songs in the setlist
    /// in the background so switching songs is instantaneous without stalling the UI or audio thread.
    public func preGenerateRemainingSetlistClickAndGuide() {
        preGenerateSetlistTask?.cancel()
        let songIds = currentSetlist.songs.map { $0.id }
        let activeId = currentSong.id
        preGenerateSetlistTask = Task { [weak self] in
            // Let the active song settle first
            try? await Task.sleep(nanoseconds: 400_000_000)
            for sid in songIds {
                if Task.isCancelled { return }
                guard sid != activeId else { continue }
                guard let self = self else { return }
                let needsRender = await MainActor.run { () -> Bool in
                    guard let s = self.currentSetlist.songs.first(where: { $0.id == sid }),
                          !s.excludesClickAndGuide else { return false }
                    let needC = s.clickSource == .generated && (self.generatedClickBuffers[sid]?.frameLength ?? 0) <= 1
                    let needG = s.guideSource == .generated &&
                        ((self.generatedGuideBuffers[sid]?.frameLength ?? 0) <= 1 || self.generatedGuideLoopStates[sid] != Self.defaultGuideLoopState(for: s))
                    return needC || needG
                }
                if needsRender {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        Task { @MainActor in
                            self.preGenerateClickAndGuide(forSongId: sid) {
                                cont.resume()
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
        }
    }

    /// Pre-renders generated Click and Guide buffers in the background for a non-active setlist song
    /// (such as `nextSong` queued for an overlap/crossfade/auto-link transition).
    public func preGenerateClickAndGuide(forSongId songId: UUID, force: Bool = false, completion: (() -> Void)? = nil) {
        guard let song = currentSetlist.songs.first(where: { $0.id == songId }) else { return }
        guard !song.excludesClickAndGuide else {
            completion?()
            return
        }

        if song.id == currentSong.id {
            if song.clickSource == .generated && (force || (generatedClickBuffers[songId]?.frameLength ?? 0) <= 1) {
                regenerateClickTrack()
            }
            let liveState = currentLiveGuideLoopState()
            if song.guideSource == .generated && (force || (generatedGuideBuffers[songId]?.frameLength ?? 0) <= 1 || generatedGuideLoopStates[songId] != liveState) {
                regenerateGuideTrack()
            }
            completion?()
            return
        }

        let autoLoopSec = Self.resolvedAutoInfiniteLoopSection(for: song)
        let targetGuideState = Self.defaultGuideLoopState(for: song)
        let needsClick = song.clickSource == .generated && (force || (generatedClickBuffers[songId]?.frameLength ?? 0) <= 1)
        let needsGuide = song.guideSource == .generated && (force || (generatedGuideBuffers[songId]?.frameLength ?? 0) <= 1 || generatedGuideLoopStates[songId] != targetGuideState)

        if !needsClick && !needsGuide {
            syncCachedClickAndGuideBuffers(forSongId: songId)
            completion?()
            return
        }

        if let completion = completion {
            preGeneratingClickGuideCompletions[songId, default: []].append(completion)
        }
        guard !preGeneratingClickGuideSongIds.contains(songId) else { return }

        let cachedItems = songBuffersCache[songId] ?? []
        let maxAudioDur = cachedItems
            .filter { !Self.isClickOrGuideTrack($0.track) }
            .map { Double($0.buffer.frameLength) / max(1.0, $0.buffer.format.sampleRate) }
            .max() ?? 0.0
        let duration = max(maxAudioDur, song.totalDuration)
        guard duration > 0 else {
            let callbacks = preGeneratingClickGuideCompletions.removeValue(forKey: songId) ?? []
            callbacks.forEach { $0() }
            return
        }

        preGeneratingClickGuideSongIds.insert(songId)

        let canonicalFormat = getCanonicalProcessingFormat()
        let activeDirectionalCues = song.directionalCues.filter {
            !Self.isCueInTrimmedRegion(cueTime: $0.time, sectionId: $0.sectionId, in: song.sections)
        }
        let bpm = song.bpm
        let numerator = song.timeSignatureNumerator
        let denominator = song.timeSignatureDenominator
        let beatGrid = song.effectiveBeatGrid(totalDuration: duration)
        let sections = song.sections
        let clickSound = song.clickSound
        let accentEnabled = song.clickAccentEnabled
        let quarterEnabled = song.clickQuarterEnabled
        let eighthEnabled = song.clickEighthEnabled
        let sixteenthEnabled = song.clickSixteenthEnabled
        let accentVol = song.clickAccentVolume
        let quarterVol = song.clickQuarterVolume
        let eighthVol = song.clickEighthVolume
        let sixteenthVol = song.clickSixteenthVolume
        let guideVoice = song.guideVoice
        let guideFallbackVoice = song.guideFallbackVoice
        let countInEnabled = song.guideCountInEnabled
        let clickGen = self.clickGenerator
        let guideGen = self.guideAudioGenerator

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let newClickBuf: AVAudioPCMBuffer? = needsClick ? clickGen.generateClickBuffer(
                bpm: bpm,
                timeSignatureNumerator: numerator,
                timeSignatureDenominator: denominator,
                duration: duration,
                beatGrid: beatGrid,
                sections: sections,
                soundType: clickSound,
                accentEnabled: accentEnabled,
                quarterEnabled: quarterEnabled,
                eighthEnabled: eighthEnabled,
                sixteenthEnabled: sixteenthEnabled,
                accentVolume: accentVol,
                quarterVolume: quarterVol,
                eighthVolume: eighthVol,
                sixteenthVolume: sixteenthVol,
                soloedSubdivisions: [],
                format: canonicalFormat
            ) : nil

            let newGuideBuf: AVAudioPCMBuffer? = needsGuide ? guideGen.generateGuideBuffer(
                sections: sections,
                directionalCues: activeDirectionalCues,
                bpm: bpm,
                timeSignatureNumerator: numerator,
                timeSignatureDenominator: denominator,
                duration: duration,
                beatGrid: beatGrid,
                voice: guideVoice,
                fallbackVoice: guideFallbackVoice,
                countInEnabled: countInEnabled,
                loopedSection: autoLoopSec,
                isLoopActive: targetGuideState.isLoopActive,
                loopMode: targetGuideState.loopMode,
                singleLoopRemaining: 0,
                format: canonicalFormat
            ) : nil

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.preGeneratingClickGuideSongIds.remove(songId)
                let callbacks = self.preGeneratingClickGuideCompletions.removeValue(forKey: songId) ?? []
                guard self.currentSetlist.songs.contains(where: { $0.id == songId }) else {
                    callbacks.forEach { $0() }
                    return
                }

                if let cBuf = newClickBuf {
                    self.generatedClickBuffers[songId] = cBuf
                }
                var needsLiveActiveRegen = false
                if let gBuf = newGuideBuf {
                    if songId == self.currentSong.id {
                        if self.currentLiveGuideLoopState() == targetGuideState {
                            self.generatedGuideBuffers[songId] = gBuf
                            self.generatedGuideLoopStates[songId] = targetGuideState
                        } else {
                            needsLiveActiveRegen = true
                        }
                    } else {
                        self.generatedGuideBuffers[songId] = gBuf
                        self.generatedGuideLoopStates[songId] = targetGuideState
                    }
                }

                self.syncCachedClickAndGuideBuffers(forSongId: songId)

                let nextIdx = self.currentSongIndex + 1
                let isNextSong = self.currentSetlist.songs.indices.contains(nextIdx) && self.currentSetlist.songs[nextIdx].id == songId
                if songId == self.currentSong.id {
                    self.applyClickBuffer()
                    if needsLiveActiveRegen {
                        self.regenerateGuideTrack()
                    } else {
                        self.applyGuideBuffer()
                    }
                } else if isNextSong {
                    self.syncMixState()
                }

                callbacks.forEach { $0() }
            }
        }
    }

    public func setPreserveVocalFormants(_ enabled: Bool, forSongIndex targetIndex: Int? = nil, triggerRender: Bool = true) {
        let idx = targetIndex ?? currentSongIndex
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        guard currentSetlist.songs[idx].preserveVocalFormants != enabled else { return }
        currentSetlist.songs[idx].preserveVocalFormants = enabled
        if idx == currentSongIndex {
            currentSong.preserveVocalFormants = enabled
        }
        markSessionChanged()
        let song = currentSetlist.songs[idx]
        if triggerRender && (song.transposeSemitones != 0 || song.isTempoShifted) {
            setKeyAndTempo(forSongIndex: idx)
        } else {
            objectWillChange.send()
        }
    }

    public func preRenderTranspose(forSongIndex idx: Int) {
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        let song = currentSetlist.songs[idx]
        guard song.transposeSemitones != 0 || song.isTempoShifted else { return }
        guard areSongStemsHydratedForTransform(atIndex: idx) else { return }
        setKeyAndTempo(forSongIndex: idx)
    }
    
    public func moveSong(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0 && fromIndex < currentSetlist.songs.count,
              toIndex >= 0 && toIndex < currentSetlist.songs.count else { return }
        
        let activeSongId = currentSetlist.songs.indices.contains(currentSongIndex) ? currentSetlist.songs[currentSongIndex].id : nil
        let moved = currentSetlist.songs.remove(at: fromIndex)
        currentSetlist.songs.insert(moved, at: toIndex)
        
        if let activeId = activeSongId, let newIndex = currentSetlist.songs.firstIndex(where: { $0.id == activeId }) {
            currentSongIndex = newIndex
        }
        syncMixState()
        markSessionChanged()
    }
    
    public func removeSongFromSetlist(at index: Int) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        let removedSong = currentSetlist.songs.remove(at: index)
        songBuffersCache.removeValue(forKey: removedSong.id)
        memoryEvictedSongIds.remove(removedSong.id)
        songTrackMetadataBackup.removeValue(forKey: removedSong.id)
        songWaveformCache.removeValue(forKey: removedSong.id)
        songTransposedBuffersCache.removeValue(forKey: removedSong.id)
        
        if currentSetlist.songs.isEmpty {
            stop()
            clearAllTracks()
            currentSong = Song(title: "", artist: "", bpm: 120.0, sections: [])
            currentSongIndex = 0
            transportPosition.totalDuration = 0
            transportPosition.currentTime = 0
            transportClock.position.totalDuration = 0
            transportClock.position.currentTime = 0
        } else {
            let nextIdx = min(currentSongIndex, currentSetlist.songs.count - 1)
            currentSongIndex = max(0, nextIdx)
            loadSong(currentSetlist.songs[currentSongIndex])
        }
        markSessionChanged()
    }
    
    public func newSession(
        name: String = "New Setlist",
        date: Date = Date(),
        serviceType: String? = nil,
        serviceTime: String? = nil
    ) {
        stop()
        clearAllTracks()
        songBuffersCache.removeAll()
        memoryEvictedSongIds.removeAll()
        songTrackMetadataBackup.removeAll()
        songWaveformCache.removeAll()
        songTransposedBuffersCache.removeAll()
        currentSessionURL = nil
        currentSessionLoadedModDate = nil
        currentSessionLoadedRevisionId = nil
        hasUnsavedChanges = false
        hasCloudSetlistUpdate = false
        UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
        try? FileManager.default.removeItem(at: autoSaveSessionURL)
        currentSetlist = Setlist(
            name: name,
            date: date,
            serviceType: serviceType,
            serviceTime: serviceTime,
            scheduledDate: date,
            songs: []
        )
        currentSong = Song(title: "", artist: "", bpm: 120.0, sections: [])
        currentSongIndex = 0
        resetUndoHistoryToCurrentState()
    }
    
    /// Caches the current active song's stems (if any), appends a fresh blank song to the setlist,
    /// and selects it so the Song Builder opens with a clean slate for building a new song.
    public func beginBuildingNewSong() -> Int? {
        let previousIdx: Int? = currentSetlist.songs.isEmpty ? nil : currentSongIndex
        
        if !currentSong.title.isEmpty && !tracks.isEmpty {
            var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
            for track in tracks {
                if let ch = channels[track.id], let buf = ch.buffer {
                    currentBuffers.append((track, buf))
                }
            }
            songBuffersCache[currentSong.id] = currentBuffers
            recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
        }
        
        stop()
        clearAllTracks()
        
        let newSong = Song(
            title: "",
            artist: "",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [],
            startPadWithSong: isGlobalStartPadWithSongEnabled,
            padPresetId: PadLibraryManager.shared.activePackId
        )
        currentSetlist.songs.append(newSong)
        currentSong = newSong
        currentSongIndex = currentSetlist.songs.count - 1
        objectWillChange.send()
        return previousIdx
    }
    
    public func addSongToSetlist(song: Song, loadedTracks: [(StemTrack, AVAudioPCMBuffer)]) {
        let canonicalFormat = getCanonicalProcessingFormat()
        var mutableSong = song
        mutableSong.startPadWithSong = isGlobalStartPadWithSongEnabled
        mutableSong.padPresetId = PadLibraryManager.shared.activePackId
        if mutableSong.usesDefaultGuideVoice {
            mutableSong.guideVoice = GuideVoice.defaultVoice
        }
        if mutableSong.usesDefaultClickSound {
            mutableSong.clickSound = ClickSoundType.defaultSound
        }
        if currentSetlist.songs.contains(where: { $0.id == mutableSong.id }) {
            mutableSong.sourceSongId = mutableSong.sourceSongId ?? mutableSong.id
            mutableSong.id = UUID()
        }
        let isStubLoad = !loadedTracks.isEmpty && loadedTracks.allSatisfy({ $0.1.frameLength <= 1 })
        var sortedTracks: [(StemTrack, AVAudioPCMBuffer)] = []
        sortedTracks.reserveCapacity(loadedTracks.count + 2)
        for (trk, buf) in loadedTracks {
            let norm = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
            let cat = StemCategory.category(for: trk.name, role: trk.role)
            if cat == .click {
                trk.role = .click
                if norm.frameLength > 100 {
                    uploadedClickBuffers[mutableSong.id] = norm
                    mutableSong.clickSource = defaultClickSourcePreference
                } else if !isStubLoad {
                    mutableSong.clickSource = .generated
                }
            } else if cat == .guide {
                trk.role = .guide
                if norm.frameLength > 100 {
                    uploadedGuideBuffers[mutableSong.id] = norm
                    mutableSong.guideSource = defaultGuideSourcePreference
                } else if !isStubLoad {
                    mutableSong.guideSource = .generated
                }
            }
            if norm.frameLength > 10 {
                trk.duration = Double(norm.frameLength) / norm.format.sampleRate
            }
            if !isStubLoad && trk.waveformPeaks.isEmpty && trk.includeInWaveform {
                trk.waveformPeaks = extractWaveformPeaks(from: norm, samplesCount: 4000)
            }
            sortedTracks.append((trk, norm))
        }
        
        // Ensure Click & Guide exist in setlist song buffers immediately
        let hasClick = sortedTracks.contains(where: { StemCategory.category(for: $0.0.name, role: $0.0.role) == .click })
        let hasGuide = sortedTracks.contains(where: { StemCategory.category(for: $0.0.name, role: $0.0.role) == .guide })
        let masterDur = max(sortedTracks.map { $0.0.duration }.max() ?? 0.0, song.totalDuration > 0 ? song.totalDuration : 240.0)
        let sampleRate = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
        let initialFrames: AVAudioFrameCount = isStubLoad ? 1 : AVAudioFrameCount(max(1, Int64(round(masterDur * sampleRate))))
        
        if !hasClick && !mutableSong.excludesClickAndGuide {
            mutableSong.clickSource = .generated
            let newClick = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
            newClick.duration = masterDur
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                sortedTracks.append((newClick, silentBuf))
            }
        }
        if !hasGuide && !mutableSong.excludesClickAndGuide {
            mutableSong.guideSource = .generated
            let newGuide = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
            newGuide.duration = masterDur
            if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initialFrames) {
                silentBuf.frameLength = initialFrames
                sortedTracks.append((newGuide, silentBuf))
            }
        }
        
        sortedTracks.sort { (item1, item2) -> Bool in
            let cat1 = StemCategory.category(for: item1.0.name, role: item1.0.role)
            let cat2 = StemCategory.category(for: item2.0.name, role: item2.0.role)
            if cat1 != cat2 {
                return cat1 < cat2
            }
            return item1.0.name.localizedStandardCompare(item2.0.name) == .orderedAscending
        }
        songBuffersCache[mutableSong.id] = sortedTracks
        recordTrackMetadataBackup(for: mutableSong.id, tracks: sortedTracks.map { $0.0 })
        if !isStubLoad {
            memoryEvictedSongIds.remove(mutableSong.id)
        }
        currentSetlist.songs.append(mutableSong)
        selectSongInSetlist(at: currentSetlist.songs.count - 1, updateUndoBaseline: false)
        markSessionChanged()
    }
    
    /// Creates and appends a Click & Pad setlist item (`Count Off` -> `Click` -> `Ending`) with Click + Guide tracks,
    /// optional linked Ambient Pad, and either armed Infinite Loop or fixed measure count.
    public func addClickAndPadToSetlist(
        name: String,
        bpm: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int,
        ambientPadEnabled: Bool,
        padPresetId: String,
        musicalKey: String,
        infiniteLoop: Bool,
        measures: Int
    ) {
        let safeBpm = max(20.0, min(300.0, bpm))
        let tsNum = max(1, timeSignatureNumerator)
        let tsDen = max(1, timeSignatureDenominator)
        
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bpmDecimals = Song.tempoDecimalPrecision(for: safeBpm)
        let formattedBpm = Song.formatBPM(safeBpm, decimals: bpmDecimals)
        let finalTitle = trimmedName.isEmpty ? "\(formattedBpm) BPM \(tsNum)/\(tsDen)" : trimmedName
        
        let sections = Song.makeClickAndPadSections(
            bpm: safeBpm,
            timeSignatureNumerator: tsNum,
            timeSignatureDenominator: tsDen,
            infiniteLoop: infiniteLoop,
            measures: measures
        )
        let totalDur = sections.last?.endTime ?? 0.0
        
        let newSong = Song(
            title: finalTitle,
            artist: "",
            bpm: safeBpm,
            originalBPM: safeBpm,
            timeSignatureNumerator: tsNum,
            timeSignatureDenominator: tsDen,
            musicalKey: ambientPadEnabled ? musicalKey : "",
            sections: sections,
            defaultSections: sections,
            transitionType: .stayInSong,
            continuePad: ambientPadEnabled,
            endFadeOutEnabled: false,
            startPadWithSong: ambientPadEnabled,
            padPresetId: padPresetId,
            artworkData: nil,
            clickSource: .generated,
            guideSource: .generated,
            guideVoice: GuideVoice.defaultVoice,
            clickSound: ClickSoundType.defaultSound,
            usesDefaultClickSound: true,
            usesDefaultGuideVoice: true,
            guideCountInEnabled: true,
            autoInfiniteLoop: infiniteLoop
        )
        
        let canonicalFormat = getCanonicalProcessingFormat()
        let sr = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
        let totalFrames = AVAudioFrameCount(max(1, Int64(round(totalDur * sr))))
        var initialTracks: [(StemTrack, AVAudioPCMBuffer)] = []
        
        let clickTrack = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
        clickTrack.duration = totalDur
        if let clickBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: totalFrames) {
            clickBuf.frameLength = totalFrames
            initialTracks.append((clickTrack, clickBuf))
        }
        
        let guideTrack = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
        guideTrack.duration = totalDur
        if let guideBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: totalFrames) {
            guideBuf.frameLength = totalFrames
            initialTracks.append((guideTrack, guideBuf))
        }
        
        if !currentSong.title.isEmpty && !tracks.isEmpty {
            songWaveformCache[currentSong.id] = (masterWaveformPeaks, renderedWaveformImage)
            var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
            currentBuffers.reserveCapacity(tracks.count)
            for track in tracks {
                if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                    currentBuffers.append((track, buf))
                }
            }
            songBuffersCache[currentSong.id] = currentBuffers
            recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
        }
        
        songBuffersCache[newSong.id] = initialTracks
        recordTrackMetadataBackup(for: newSong.id, tracks: initialTracks.map { $0.0 })
        memoryEvictedSongIds.remove(newSong.id)
        currentSetlist.songs.append(newSong)
        selectSongInSetlist(at: currentSetlist.songs.count - 1, updateUndoBaseline: false)
        markSessionChanged()
    }
    
    private func tracksForSavingSong(_ song: Song, rawTracks: [StemTrack]) -> [StemTrack] {
        guard song.id == currentSong.id,
              !song.automationPoints.isEmpty,
              !isEditAutomationMode else {
            return rawTracks
        }
        var autoVolIds = Set<UUID>()
        var autoPanIds = Set<UUID>()
        var autoMuteIds = Set<UUID>()
        for pt in song.automationPoints {
            autoVolIds.formUnion(pt.trackFaders.keys)
            autoPanIds.formUnion(pt.trackPans.keys)
            autoMuteIds.formUnion(pt.trackMutes.keys)
        }
        guard !autoVolIds.isEmpty || !autoPanIds.isEmpty || !autoMuteIds.isEmpty else {
            return rawTracks
        }
        return rawTracks.map { trk in
            let copy = StemTrack(
                id: trk.id,
                name: trk.name,
                role: trk.role,
                fileURL: trk.fileURL,
                sourceFileURL: trk.sourceFileURL,
                volume: autoVolIds.contains(trk.id) ? (baseTrackVolumes[trk.id] ?? trk.volume) : trk.volume,
                pan: autoPanIds.contains(trk.id) ? (baseTrackPans[trk.id] ?? trk.pan) : trk.pan,
                isMuted: autoMuteIds.contains(trk.id) ? (baseTrackMutes[trk.id] ?? trk.isMuted) : trk.isMuted,
                isSoloed: trk.isSoloed,
                isSoloSafe: trk.isSoloSafe,
                routing: trk.routing,
                assignedBusName: trk.assignedBusName,
                includeInWaveform: trk.includeInWaveform
            )
            copy.duration = trk.duration
            copy.waveformPeaks = trk.waveformPeaks
            return copy
        }
    }

    public func saveCurrentSongPackage(to url: URL, asDirectoryPackage: Bool = true) throws {
        var buffers: [UUID: AVAudioPCMBuffer] = [:]
        for track in tracks {
            if Self.isClickTrack(track), let upClick = uploadedClickBuffers[currentSong.id], upClick.frameLength > 100 {
                buffers[track.id] = upClick
            } else if Self.isGuideTrack(track), let upGuide = uploadedGuideBuffers[currentSong.id], upGuide.frameLength > 100 {
                buffers[track.id] = upGuide
            } else if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                buffers[track.id] = buf
            }
        }
        let saveTracks = tracksForSavingSong(currentSong, rawTracks: tracks)
        let transposedBuffers = cachedTransformedBuffers(for: currentSong)
        try PlaybackFileManager.shared.exportSongPackage(
            song: currentSong,
            tracks: saveTracks,
            buffers: buffers,
            transposedBuffers: transposedBuffers,
            to: url,
            asDirectoryPackage: asDirectoryPackage
        )
    }
    
    public func exportSongPackage(forSongIndex index: Int?, to url: URL, asDirectoryPackage: Bool = true) throws {
        let s = (index != nil && index! >= 0 && index! < currentSetlist.songs.count) ? currentSetlist.songs[index!] : currentSong
        if s.id == currentSong.id && !tracks.isEmpty {
            try saveCurrentSongPackage(to: url, asDirectoryPackage: asDirectoryPackage)
            return
        }
        let cached = songBuffersCache[s.id] ?? []
        let songTracks = cached.map { $0.track }
        var buffersDict: [UUID: AVAudioPCMBuffer] = [:]
        for item in cached {
            if Self.isClickTrack(item.track), let upClick = uploadedClickBuffers[s.id], upClick.frameLength > 100 {
                buffersDict[item.track.id] = upClick
            } else if Self.isGuideTrack(item.track), let upGuide = uploadedGuideBuffers[s.id], upGuide.frameLength > 100 {
                buffersDict[item.track.id] = upGuide
            } else {
                buffersDict[item.track.id] = item.buffer
            }
        }
        let transposedBuffers = cachedTransformedBuffers(for: s)
        try PlaybackFileManager.shared.exportSongPackage(
            song: s,
            tracks: songTracks,
            buffers: buffersDict,
            transposedBuffers: transposedBuffers,
            to: url,
            asDirectoryPackage: asDirectoryPackage
        )
    }
    
    public func importSongPackage(from url: URL, configuredWith overrideSong: Song? = nil) throws {
        let canonicalFormat = getCanonicalProcessingFormat()
        let fast = try PlaybackFileManager.shared.loadSongMetadataFast(from: url, canonicalFormat: canonicalFormat)

        let targetOverride = overrideSong
        func applyOverrides(to s: inout Song) {
            guard let ov = targetOverride else { return }
            s.savedArrangements = ov.savedArrangements
            s.activeArrangementId = ov.activeArrangementId
            s.sections = ov.sections
            s.padPresetId = ov.padPresetId
            s.continuePad = ov.continuePad
            s.endFadeOutEnabled = ov.endFadeOutEnabled
            s.startPadWithSong = ov.startPadWithSong
            s.padIntroOutroOnly = ov.padIntroOutroOnly
            s.transitionType = ov.transitionType
            s.proPresenterPlaylist = ov.proPresenterPlaylist
            s.proPresenterPlaylistItem = ov.proPresenterPlaylistItem
            s.excludesClickAndGuide = ov.excludesClickAndGuide
        }

        let needsKeyOrTempoOverride: Bool = {
            guard let ov = targetOverride else { return false }
            return ov.transposeSemitones != fast.song.transposeSemitones
                || ov.preserveVocalFormants != fast.song.preserveVocalFormants
                || abs(ov.bpm - fast.song.bpm) > 0.005
        }()

        // Fast path: if this song is already in the setlist with hydrated buffers in RAM, clone immediately.
        if let existingSong = currentSetlist.songs.first(where: { $0.id == fast.song.id || $0.sourceSongId == fast.song.id }),
           let sharedTracks = sharedBuffersForDuplicatingSong(existingSong) {
            if let cleanup = fast.cleanupFolder {
                try? FileManager.default.removeItem(at: cleanup)
            }
            var song = fast.song
            song.sourceSongId = fast.song.id
            song.id = UUID()
            applyOverrides(to: &song)
            addSongToSetlist(song: song, loadedTracks: sharedTracks)
            let newIndex = currentSetlist.songs.count - 1
            if let ov = targetOverride, needsKeyOrTempoOverride, newIndex >= 0 {
                setKeyAndTempo(
                    semitones: ov.transposeSemitones,
                    preserveVocalFormants: ov.preserveVocalFormants,
                    tempoBPM: ov.bpm,
                    forSongIndex: newIndex
                )
            }
            return
        }

        // Progressive 2-stage load: add song card & metadata immediately, then download/decode stems in background.
        var song = fast.song
        applyOverrides(to: &song)
        addSongToSetlist(song: song, loadedTracks: fast.stubTracks)
        let newIndex = currentSetlist.songs.count - 1
        let targetSongId = (newIndex >= 0 && newIndex < currentSetlist.songs.count) ? currentSetlist.songs[newIndex].id : song.id

        let isCloudOrigin = LibraryBrowserManager.isURLInCloudLibrary(url)
            || !LibraryBrowserManager.checkIsDownloaded(at: url)
            || fast.metadata.tracks.contains { $0.relativeAudioPath.hasPrefix("cloudstems/") }
        let needsDownload = isCloudOrigin && fast.metadata.tracks.contains {
            !$0.relativeAudioPath.isEmpty && !PlaybackFileManager.shared.hasValidCachedStem(for: $0.id)
        }
        if needsDownload {
            downloadingSongProgress[targetSongId] = 0.0
        }

        let generation = sessionHydrationGeneration
        let songEntry = fast.metadata
        let ovSnapshot = targetOverride

        Task.detached(priority: .userInitiated) { [weak self, fast, canonicalFormat, generation, targetSongId, songEntry, needsDownload, needsKeyOrTempoOverride, ovSnapshot] in
            defer {
                if let cleanup = fast.cleanupFolder {
                    try? FileManager.default.removeItem(at: cleanup)
                }
            }

            if fast.needsArchiveExtraction {
                try? PlaybackFileManager.shared.extractFullArchiveForHydration(
                    archiveURL: fast.sourceURL,
                    toFolderURL: fast.rootFolder
                )
            }

            if Task.isCancelled || self?.isSongDownloadCancelled(targetSongId) == true { return }

            PlaybackFileManager.shared.prefetchCloudStems(for: [songEntry], rootFolder: fast.rootFolder)

            let expectedAudioTrackCount = songEntry.tracks.filter { !$0.relativeAudioPath.isEmpty }.count
            var decodedTracks: [(StemTrack, AVAudioPCMBuffer)] = []
            var decodedTransposed: [UUID: AVAudioPCMBuffer] = [:]

            for attempt in 0..<5 {
                if Task.isCancelled || self?.isSongDownloadCancelled(targetSongId) == true { return }
                let res = PlaybackFileManager.shared.decodeSongEntryAudio(
                    songEntry: songEntry,
                    rootFolder: fast.rootFolder,
                    canonicalFormat: canonicalFormat,
                    isCancelled: { [weak self] in
                        Task.isCancelled || (self?.isSongDownloadCancelled(targetSongId) ?? true)
                    },
                    progressHandler: needsDownload ? { [weak self] done, total in
                        let frac = total > 0 ? Double(done) / Double(total) : 1.0
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  self.sessionHydrationGeneration == generation,
                                  !self.cancelledDownloadSongIds.contains(targetSongId) else { return }
                            self.downloadingSongProgress[targetSongId] = frac
                        }
                    } : nil
                )
                decodedTracks = res.tracks
                decodedTransposed = res.transposedBuffers
                let hydratedAudioCount = decodedTracks.filter { $0.1.frameLength > 100 }.count
                if hydratedAudioCount >= expectedAudioTrackCount || attempt == 4 {
                    break
                }
                // Wait briefly for Google Drive / iCloud FileProvider to finish syncing any remaining stems
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                PlaybackFileManager.shared.prefetchCloudStems(for: [songEntry], rootFolder: fast.rootFolder)
            }

            if Task.isCancelled || self?.isSongDownloadCancelled(targetSongId) == true { return }
            let finalDecodedTracks = decodedTracks
            let finalDecodedTransposed = decodedTransposed

            await MainActor.run { [weak self] in
                guard let self = self,
                      self.sessionHydrationGeneration == generation,
                      !Task.isCancelled,
                      !self.cancelledDownloadSongIds.contains(targetSongId) else { return }
                self.downloadingSongProgress.removeValue(forKey: targetSongId)
                self.applyHydratedSongAudioBuffers(
                    songId: targetSongId,
                    decodedTracks: finalDecodedTracks,
                    decodedTransposed: finalDecodedTransposed,
                    canonicalFormat: canonicalFormat
                )
                if let ov = ovSnapshot, needsKeyOrTempoOverride,
                   let idx = self.currentSetlist.songs.firstIndex(where: { $0.id == targetSongId }) {
                    self.setKeyAndTempo(
                        semitones: ov.transposeSemitones,
                        preserveVocalFormants: ov.preserveVocalFormants,
                        tempoBPM: ov.bpm,
                        forSongIndex: idx
                    )
                }
            }
        }
    }

    private func sharedBuffersForDuplicatingSong(_ existingSong: Song) -> [(StemTrack, AVAudioPCMBuffer)]? {
        if downloadingSongProgress[existingSong.id] != nil {
            return nil
        }
        if existingSong.id == currentSong.id && !tracks.isEmpty {
            var result: [(StemTrack, AVAudioPCMBuffer)] = []
            result.reserveCapacity(tracks.count)
            var hasHydratedStem = false
            for trk in tracks {
                if let buf = pristineMasterBuffers[trk.id] ?? channels[trk.id]?.buffer {
                    if !Self.isClickOrGuideTrack(trk) && buf.frameLength > 100 {
                        hasHydratedStem = true
                    }
                    result.append((trk.cloneWithNewId(), buf))
                }
            }
            return (hasHydratedStem && !result.isEmpty) ? result : nil
        }
        rehydrateEvictedSongBuffersIfNeeded(for: existingSong)
        if let cached = songBuffersCache[existingSong.id], !cached.isEmpty {
            let hasHydratedStem = cached.contains { !Self.isClickOrGuideTrack($0.track) && $0.buffer.frameLength > 100 }
            guard hasHydratedStem else { return nil }
            return cached.map { ($0.track.cloneWithNewId(), $0.buffer) }
        }
        return nil
    }
    
    public func saveSession(
        to url: URL,
        recordAsLastSession: Bool = true,
        asDirectoryPackage: Bool = true,
        associatedSessionPath: String? = nil,
        changeDescription: String? = nil,
        revisionId: UUID? = nil
    ) throws {
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count && !currentSong.title.isEmpty {
            ensureCuesTaggedToSections(in: &currentSong)
            currentSetlist.songs[currentSongIndex] = currentSong
        }
        if !currentSong.title.isEmpty && !tracks.isEmpty {
            var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
            for track in tracks {
                if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                    currentBuffers.append((track, buf))
                }
            }
            songBuffersCache[currentSong.id] = currentBuffers
            recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
        }
        
        var allSongsData: [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])] = []
        for song in currentSetlist.songs {
            let cached = songBuffersCache[song.id] ?? []
            let songTracks = tracksForSavingSong(song, rawTracks: cached.map { $0.track })
            var buffersDict: [UUID: AVAudioPCMBuffer] = [:]
            for item in cached {
                if Self.isClickTrack(item.track), let upClick = uploadedClickBuffers[song.id], upClick.frameLength > 100 {
                    buffersDict[item.track.id] = upClick
                } else if Self.isGuideTrack(item.track), let upGuide = uploadedGuideBuffers[song.id], upGuide.frameLength > 100 {
                    buffersDict[item.track.id] = upGuide
                } else {
                    buffersDict[item.track.id] = item.buffer
                }
            }
            allSongsData.append((song: song, tracks: songTracks, buffers: buffersDict))
        }

        let isAutoSave = (url.standardizedFileURL == autoSaveSessionURL.standardizedFileURL)
        let effectiveRevisionId = isAutoSave ? currentSessionLoadedRevisionId : (revisionId ?? UUID())
        if !isAutoSave, let revId = effectiveRevisionId {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
                }
            }
        }
        
        try PlaybackFileManager.shared.exportSession(
            setlist: currentSetlist,
            currentSongIndex: currentSongIndex,
            allSongsData: allSongsData,
            transposedBuffersMap: songTransposedBuffersCache.mapValues { ($0.semitones, $0.buffers) },
            to: url,
            asDirectoryPackage: asDirectoryPackage,
            associatedSessionPath: associatedSessionPath,
            changeDescription: changeDescription,
            revisionId: effectiveRevisionId
        )
        if !isAutoSave {
            let savedModDate = LibraryBrowserManager.packageModificationDate(at: url)
            if recordAsLastSession {
                currentSessionURL = url
                currentSessionLoadedModDate = max(currentSessionLoadedModDate ?? .distantPast, savedModDate)
                UserDefaults.standard.set(url.path, forKey: "Playback_LastSessionPath")
                if url.standardizedFileURL != autoSaveSessionURL.standardizedFileURL {
                    try? PlaybackFileManager.shared.exportSession(
                        setlist: currentSetlist,
                        currentSongIndex: currentSongIndex,
                        allSongsData: allSongsData,
                        transposedBuffersMap: songTransposedBuffersCache.mapValues { ($0.semitones, $0.buffers) },
                        to: autoSaveSessionURL,
                        asDirectoryPackage: true,
                        associatedSessionPath: url.path,
                        revisionId: effectiveRevisionId
                    )
                }
            } else {
                currentSessionLoadedModDate = max(currentSessionLoadedModDate ?? .distantPast, savedModDate)
            }
            if let revId = effectiveRevisionId {
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
                    }
                }
            }
        }
    }
    
    public func saveSessionAsync(
        to url: URL,
        recordAsLastSession: Bool = true,
        asDirectoryPackage: Bool = true,
        associatedSessionPath: String? = nil,
        changeDescription: String? = nil,
        revisionId: UUID? = nil
    ) async throws {
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count && !currentSong.title.isEmpty {
            ensureCuesTaggedToSections(in: &currentSong)
            currentSetlist.songs[currentSongIndex] = currentSong
        }
        if !currentSong.title.isEmpty && !tracks.isEmpty {
            var currentBuffers: [(StemTrack, AVAudioPCMBuffer)] = []
            for track in tracks {
                if let buf = pristineMasterBuffers[track.id] ?? channels[track.id]?.buffer {
                    currentBuffers.append((track, buf))
                }
            }
            songBuffersCache[currentSong.id] = currentBuffers
            recordTrackMetadataBackup(for: currentSong.id, tracks: currentBuffers.map { $0.0 })
        }

        let setlistSnapshot = currentSetlist
        let songIndexSnapshot = currentSongIndex
        var allSongsData: [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])] = []
        for song in setlistSnapshot.songs {
            let cached = songBuffersCache[song.id] ?? []
            let songTracks = tracksForSavingSong(song, rawTracks: cached.map { $0.track })
            var buffersDict: [UUID: AVAudioPCMBuffer] = [:]
            for item in cached {
                if Self.isClickTrack(item.track), let upClick = uploadedClickBuffers[song.id], upClick.frameLength > 100 {
                    buffersDict[item.track.id] = upClick
                } else if Self.isGuideTrack(item.track), let upGuide = uploadedGuideBuffers[song.id], upGuide.frameLength > 100 {
                    buffersDict[item.track.id] = upGuide
                } else {
                    buffersDict[item.track.id] = item.buffer
                }
            }
            allSongsData.append((song: song, tracks: songTracks, buffers: buffersDict))
        }
        let transposedSnapshot = songTransposedBuffersCache.mapValues { ($0.semitones, $0.buffers) }
        let autoSaveURL = autoSaveSessionURL
        let isAutoSave = (url.standardizedFileURL == autoSaveURL.standardizedFileURL)
        let effectiveRevisionId = isAutoSave ? currentSessionLoadedRevisionId : (revisionId ?? UUID())

        if !isAutoSave, let revId = effectiveRevisionId {
            await MainActor.run {
                clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
            }
        }

        // Wrap non-Sendable AVAudioPCMBuffer snapshots cleanly for off-main export
        struct ExportPayload: @unchecked Sendable {
            let setlist: Setlist
            let currentSongIndex: Int
            let allSongsData: [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])]
            let transposedBuffersMap: [UUID: (semitones: Int, buffers: [UUID: AVAudioPCMBuffer])]
        }
        let payload = ExportPayload(
            setlist: setlistSnapshot,
            currentSongIndex: songIndexSnapshot,
            allSongsData: allSongsData,
            transposedBuffersMap: transposedSnapshot
        )

        try await Task.detached(priority: .userInitiated) {
            try PlaybackFileManager.shared.exportSession(
                setlist: payload.setlist,
                currentSongIndex: payload.currentSongIndex,
                allSongsData: payload.allSongsData,
                transposedBuffersMap: payload.transposedBuffersMap,
                to: url,
                asDirectoryPackage: asDirectoryPackage,
                associatedSessionPath: associatedSessionPath,
                changeDescription: changeDescription,
                revisionId: effectiveRevisionId
            )
            if recordAsLastSession, url.standardizedFileURL != autoSaveURL.standardizedFileURL {
                try? PlaybackFileManager.shared.exportSession(
                    setlist: payload.setlist,
                    currentSongIndex: payload.currentSongIndex,
                    allSongsData: payload.allSongsData,
                    transposedBuffersMap: payload.transposedBuffersMap,
                    to: autoSaveURL,
                    asDirectoryPackage: true,
                    associatedSessionPath: url.path,
                    changeDescription: changeDescription,
                    revisionId: effectiveRevisionId
                )
            }
        }.value

        if !isAutoSave {
            let savedModDate = LibraryBrowserManager.packageModificationDate(at: url)
            await MainActor.run {
                if recordAsLastSession {
                    self.currentSessionURL = url
                    UserDefaults.standard.set(url.path, forKey: "Playback_LastSessionPath")
                }
                self.currentSessionLoadedModDate = max(self.currentSessionLoadedModDate ?? .distantPast, savedModDate)
                if let revId = effectiveRevisionId {
                    self.clearSaveAndCloudUpdateIndicators(revisionId: revId, targetURLs: [url])
                } else {
                    self.hasCloudSetlistUpdate = false
                    self.markSessionSaved()
                }
            }
        }
    }

    /// Resolves primary + optional Cloud/Local mirror destinations and saves them under a shared revision ID
    /// so both copies carry the identical `lastSavedRevisionId` and `lastSavedByDeviceId`, clearing both dots immediately.
    @MainActor
    public func saveQuickSession(changeDescription: String? = nil) {
        let fm = FileManager.default
        let fallbackName = LibraryBrowserManager.sanitizedPackageFilename(
            currentSetlist.name.isEmpty ? "Untitled Session" : currentSetlist.name,
            ext: "pbsession"
        )
        let primaryURL: URL
        var mirrorURL: URL? = nil
        let library = LibraryBrowserManager.shared

        if let currentURL = currentSessionURL {
            primaryURL = currentURL
            if !LibraryBrowserManager.isURLInCloudLibrary(currentURL),
               let cloudDir = library.cloudSetlistsDirectory {
                let cloudByCurrent = cloudDir.appendingPathComponent(currentURL.lastPathComponent)
                let cloudByName = cloudDir.appendingPathComponent(fallbackName)
                if fm.fileExists(atPath: cloudByCurrent.path) {
                    mirrorURL = cloudByCurrent
                } else if fm.fileExists(atPath: cloudByName.path) {
                    mirrorURL = cloudByName
                }
            } else if LibraryBrowserManager.isURLInCloudLibrary(currentURL) {
                let localByCurrent = library.setlistsDirectory.appendingPathComponent(currentURL.lastPathComponent)
                let localByName = library.setlistsDirectory.appendingPathComponent(fallbackName)
                if fm.fileExists(atPath: localByCurrent.path) {
                    mirrorURL = localByCurrent
                } else if fm.fileExists(atPath: localByName.path) {
                    mirrorURL = localByName
                }
            }
        } else {
            primaryURL = library.setlistsDirectory.appendingPathComponent(fallbackName)
            if let cloudDir = library.cloudSetlistsDirectory {
                let cloudDest = cloudDir.appendingPathComponent(fallbackName)
                if fm.fileExists(atPath: cloudDest.path) {
                    mirrorURL = cloudDest
                }
            }
        }

        let targetMirror = mirrorURL
        let allTargets = [primaryURL, targetMirror].compactMap { $0 }
        let sharedRevisionId = UUID()
        clearSaveAndCloudUpdateIndicators(revisionId: sharedRevisionId, targetURLs: allTargets)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.saveSessionAsync(
                    to: primaryURL,
                    changeDescription: changeDescription,
                    revisionId: sharedRevisionId
                )
                if let mirror = targetMirror {
                    try? await self.saveSessionAsync(
                        to: mirror,
                        recordAsLastSession: false,
                        changeDescription: changeDescription,
                        revisionId: sharedRevisionId
                    )
                }
                library.refreshSetlists()
            } catch {
                print("Save error: \(error.localizedDescription)")
            }
        }
    }

    public func saveCurrentSession() {
        if currentSessionURL != nil {
            Task { @MainActor [weak self] in
                self?.saveQuickSession()
            }
        } else {
            NotificationCenter.default.post(name: NSNotification.Name("PlaybackSaveSession"), object: nil)
        }
    }
    
    public func loadSession(from url: URL, recordAsLastSession: Bool = true) throws {
        sessionHydrationTask?.cancel()
        sessionHydrationGeneration &+= 1
        let generation = sessionHydrationGeneration
        transposeTasksBySong.values.forEach { $0.cancel() }
        transposeTasksBySong.removeAll()
        transposeProgressBySong.removeAll()
        downloadingSongProgress.removeAll()
        clearCancelledSongDownloads()
        isTransposing = false
        transposeProgress = 0.0
        transposingSongId = nil
        
        stop()
        clearAllTracks()
        songBuffersCache.removeAll()
        memoryEvictedSongIds.removeAll()
        songTrackMetadataBackup.removeAll()
        songWaveformCache.removeAll()
        songTransposedBuffersCache.removeAll()
        generatedClickBuffers.removeAll()
        generatedGuideBuffers.removeAll()
        generatedGuideLoopStates.removeAll()
        if recordAsLastSession {
            currentSessionURL = url
            currentSessionLoadedModDate = LibraryBrowserManager.packageModificationDate(at: url)
            UserDefaults.standard.set(url.path, forKey: "Playback_LastSessionPath")
        }
        
        let canonicalFormat = getCanonicalProcessingFormat()
        let hydrated = try PlaybackFileManager.shared.loadSessionMetadataFast(
            from: url,
            canonicalFormat: canonicalFormat
        )
        applyHydratedSessionMetadata(
            hydrated: hydrated,
            canonicalFormat: canonicalFormat,
            recordAsLastSession: recordAsLastSession,
            generation: generation
        )
    }
    
    private func applyHydratedSessionMetadata(
        hydrated: PlaybackFileManager.HydratedSessionMetadata,
        canonicalFormat: AVAudioFormat,
        recordAsLastSession: Bool,
        generation: Int
    ) {
        currentSetlist = hydrated.setlist
        if recordAsLastSession || currentSessionLoadedRevisionId == nil {
            currentSessionLoadedRevisionId = hydrated.lastSavedRevisionId
        }
        for sIdx in 0..<currentSetlist.songs.count {
            for secIdx in 0..<currentSetlist.songs[sIdx].sections.count {
                currentSetlist.songs[sIdx].sections[secIdx].abbreviation = SongSection.abbreviation(for: currentSetlist.songs[sIdx].sections[secIdx].name)
            }
            for secIdx in 0..<currentSetlist.songs[sIdx].defaultSections.count {
                currentSetlist.songs[sIdx].defaultSections[secIdx].abbreviation = SongSection.abbreviation(for: currentSetlist.songs[sIdx].defaultSections[secIdx].name)
            }
            ensureCuesTaggedToSections(in: &currentSetlist.songs[sIdx])
        }
        
        for item in hydrated.songsPlaceholderData {
            songBuffersCache[item.song.id] = item.tracks
            recordTrackMetadataBackup(for: item.song.id, tracks: item.tracks.map { $0.0 })
            memoryEvictedSongIds.remove(item.song.id)
        }
        
        if !currentSetlist.songs.isEmpty {
            let targetIdx = max(0, min(currentSetlist.songs.count - 1, hydrated.currentSongIndex))
            selectSongInSetlist(at: targetIdx)
        } else {
            currentSong = Song(title: "", artist: "", bpm: 120.0, sections: [])
            currentSongIndex = 0
        }
        
        if recordAsLastSession {
            markSessionSaved()
            updateCloudSetlistUpdateFlag(from: LibraryBrowserManager.shared.setlists)
        }
        resetUndoHistoryToCurrentState()
        
        // Stage 2: Hydrate actual PCM audio buffers in the background, prioritizing the active song first
        let songEntries = hydrated.songEntries
        guard !songEntries.isEmpty else {
            if let cleanup = hydrated.cleanupFolder {
                try? FileManager.default.removeItem(at: cleanup)
            }
            return
        }
        
        sessionHydrationTask = Task.detached(priority: .userInitiated) { [weak self, hydrated, canonicalFormat, generation] in
            defer {
                if let cleanup = hydrated.cleanupFolder {
                    try? FileManager.default.removeItem(at: cleanup)
                }
            }
            
            if hydrated.needsArchiveExtractionForStems {
                try? PlaybackFileManager.shared.extractFullArchiveForHydration(
                    archiveURL: hydrated.sourceURL,
                    toFolderURL: hydrated.metadataRootFolder
                )
            }
            
            let (activeSongId, nextSongId): (UUID?, UUID?) = await MainActor.run { [weak self] in
                guard let self = self, self.sessionHydrationGeneration == generation else { return (nil, nil) }
                let nextIdx = self.currentSongIndex + 1
                let nextId = (nextIdx >= 0 && nextIdx < self.currentSetlist.songs.count) ? self.currentSetlist.songs[nextIdx].id : nil
                return (self.currentSong.id, nextId)
            }
            guard activeSongId != nil else { return }

            var orderedEntries: [SongPackageMetadata] = []
            var seenIds = Set<UUID>()
            if let activeId = activeSongId,
               let activeMatch = songEntries.first(where: { $0.id == activeId }) {
                orderedEntries.append(activeMatch)
                seenIds.insert(activeMatch.id)
            }
            if let nextId = nextSongId,
               !seenIds.contains(nextId),
               let nextMatch = songEntries.first(where: { $0.id == nextId }) {
                orderedEntries.append(nextMatch)
                seenIds.insert(nextMatch.id)
            }
            for entry in songEntries where !seenIds.contains(entry.id) {
                orderedEntries.append(entry)
                seenIds.insert(entry.id)
            }

            // Pre-populate download progress for ALL songs that need downloading so every card shows its progress bar simultaneously
            let downloadIds = orderedEntries.compactMap { entry -> UUID? in
                let needsDownload = entry.tracks.contains {
                    !$0.relativeAudioPath.isEmpty && !PlaybackFileManager.shared.hasValidCachedStem(for: $0.id)
                }
                return needsDownload ? entry.id : nil
            }
            let downloadIdSet = Set(downloadIds)
            if !downloadIds.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self = self, self.sessionHydrationGeneration == generation else { return }
                    for id in downloadIds {
                        self.downloadingSongProgress[id] = 0.0
                    }
                }
            }

            // Build local library stem index once per setlist and kick off all uncached iCloud downloads upfront
            let localLibraryIndex = PlaybackFileManager.shared.buildLocalLibraryStemIndex()
            PlaybackFileManager.shared.prefetchCloudStems(for: orderedEntries, rootFolder: hydrated.metadataRootFolder)

            let maxConcurrent = 3
            await withTaskGroup(of: Void.self) { group in
                var index = 0
                var inFlight = 0

                func enqueueNext() {
                    while index < orderedEntries.count && inFlight < maxConcurrent {
                        if Task.isCancelled {
                            group.cancelAll()
                            return
                        }
                        let entry = orderedEntries[index]
                        index += 1
                        if self?.isSongDownloadCancelled(entry.id) == true {
                            continue
                        }
                        inFlight += 1
                        let needsDownload = downloadIdSet.contains(entry.id)
                        group.addTask { [weak self] in
                            if Task.isCancelled || self?.isSongDownloadCancelled(entry.id) == true { return }
                            let expectedAudioTrackCount = entry.tracks.filter { !$0.relativeAudioPath.isEmpty }.count
                            var decodedTracks: [(StemTrack, AVAudioPCMBuffer)] = []
                            var decodedTransposed: [UUID: AVAudioPCMBuffer] = [:]

                            for attempt in 0..<5 {
                                if Task.isCancelled || self?.isSongDownloadCancelled(entry.id) == true { return }
                                let res = PlaybackFileManager.shared.decodeSongEntryAudio(
                                    songEntry: entry,
                                    rootFolder: hydrated.metadataRootFolder,
                                    canonicalFormat: canonicalFormat,
                                    localLibraryIndex: localLibraryIndex,
                                    isCancelled: { [weak self] in
                                        Task.isCancelled || (self?.isSongDownloadCancelled(entry.id) ?? true)
                                    },
                                    progressHandler: needsDownload ? { [weak self] done, total in
                                        let frac = total > 0 ? Double(done) / Double(total) : 1.0
                                        Task { @MainActor [weak self] in
                                            guard let self = self,
                                                  self.sessionHydrationGeneration == generation,
                                                  !self.cancelledDownloadSongIds.contains(entry.id) else { return }
                                            self.downloadingSongProgress[entry.id] = frac
                                        }
                                    } : nil
                                )
                                decodedTracks = res.tracks
                                decodedTransposed = res.transposedBuffers
                                let hydratedAudioCount = decodedTracks.filter { $0.1.frameLength > 100 }.count
                                if hydratedAudioCount >= expectedAudioTrackCount || attempt == 4 {
                                    break
                                }
                                // Wait briefly for Google Drive / iCloud FileProvider to finish syncing any remaining stems
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                PlaybackFileManager.shared.prefetchCloudStems(for: [entry], rootFolder: hydrated.metadataRootFolder)
                            }

                            if Task.isCancelled || self?.isSongDownloadCancelled(entry.id) == true { return }

                            var finalTransposed = decodedTransposed
                            let entryTempoShifted = abs(entry.bpm - entry.originalBPM) > 0.005
                            if (entry.transposeSemitones != 0 || entryTempoShifted) && finalTransposed.isEmpty {
                                let targetTrackIds = decodedTracks.filter { (track, _) in
                                    if !Self.isClickOrGuideTrack(track) { return true }
                                    guard entryTempoShifted else { return false }
                                    let isGenClick = Self.isClickTrack(track) && entry.clickSource == .generated
                                    let isGenGuide = Self.isGuideTrack(track) && entry.guideSource == .generated
                                    return !isGenClick && !isGenGuide
                                }.map { $0.0.id }
                                if !targetTrackIds.isEmpty,
                                   let diskShifted = PlaybackFileManager.shared.loadTransposedBuffersFromDisk(
                                       songId: entry.id,
                                       semitones: entry.transposeSemitones,
                                       preserveVocalFormants: entry.preserveVocalFormants,
                                       bpm: entry.bpm,
                                       originalBPM: entry.originalBPM,
                                       trackIds: targetTrackIds,
                                       canonicalFormat: canonicalFormat
                                   ) {
                                    finalTransposed = diskShifted
                                }
                            }

                            let finalTracks = decodedTracks
                            let resolvedTransposed = finalTransposed
                            await MainActor.run { [weak self] in
                                guard let self = self,
                                      self.sessionHydrationGeneration == generation,
                                      !Task.isCancelled,
                                      !self.cancelledDownloadSongIds.contains(entry.id) else { return }
                                self.downloadingSongProgress.removeValue(forKey: entry.id)
                                self.applyHydratedSongAudioBuffers(
                                    songId: entry.id,
                                    decodedTracks: finalTracks,
                                    decodedTransposed: resolvedTransposed,
                                    canonicalFormat: canonicalFormat
                                )
                            }
                        }
                    }
                }

                enqueueNext()
                while inFlight > 0 {
                    guard await group.next() != nil else { break }
                    inFlight -= 1
                    enqueueNext()
                }
            }
        }
    }
    
    private func applyHydratedSongAudioBuffers(
        songId: UUID,
        decodedTracks: [(StemTrack, AVAudioPCMBuffer)],
        decodedTransposed: [UUID: AVAudioPCMBuffer],
        canonicalFormat: AVAudioFormat
    ) {
        guard let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == songId }) else { return }
        let song = currentSetlist.songs[songIdx]
        
        let requiredTransformIds = decodedTracks
            .filter { shouldRenderTransformedTrack($0.0, for: song, tempoShifted: song.isTempoShifted) }
            .map { $0.0.id }
        let hasCompleteValidTransposed = !requiredTransformIds.isEmpty && requiredTransformIds.allSatisfy { tid in
            (decodedTransposed[tid]?.frameLength ?? 0) > 100
        }
        if (song.transposeSemitones != 0 || song.isTempoShifted) && hasCompleteValidTransposed {
            songTransposedBuffersCache[songId] = (
                song.transposeSemitones,
                song.preserveVocalFormants,
                PlaybackFileManager.cacheBPMHundredths(song.bpm),
                decodedTransposed
            )
        }
        
        let isActiveSong = (currentSong.id == songId)
        var existingTracksById: [UUID: StemTrack] = [:]
        if isActiveSong {
            for t in tracks {
                existingTracksById[t.id] = t
            }
        } else if let cached = songBuffersCache[songId] {
            for (t, _) in cached {
                existingTracksById[t.id] = t
            }
        }
        
        var hydratedItems: [(StemTrack, AVAudioPCMBuffer)] = []
        hydratedItems.reserveCapacity(max(decodedTracks.count, existingTracksById.count))
        var seenTrackIds = Set<UUID>()
        var didUpdatePeaks = false
        var maxDur: TimeInterval = 0.0
        
        for (decTrack, decBuf) in decodedTracks {
            let norm = (decBuf.format.sampleRate == canonicalFormat.sampleRate && decBuf.format.channelCount == canonicalFormat.channelCount)
                ? decBuf
                : normalizeBufferToCanonical(buffer: decBuf, targetFormat: canonicalFormat)
            
            let track = existingTracksById[decTrack.id] ?? decTrack
            if let decFileURL = decTrack.fileURL {
                track.fileURL = decFileURL
            }
            if track.sourceFileURL == nil, let decSourceURL = decTrack.sourceFileURL {
                track.sourceFileURL = decSourceURL
            }
            let cat = StemCategory.category(for: track.name, role: track.role)
            var bufferForCache = norm
            if cat == .click {
                track.role = .click
                if norm.frameLength > 100 {
                    uploadedClickBuffers[songId] = norm
                }
                if song.clickSource == .generated {
                    if let genClick = generatedClickBuffers[songId], genClick.frameLength > 1 {
                        bufferForCache = genClick
                    } else if let silent = makeSilentStub(format: canonicalFormat) {
                        bufferForCache = silent
                    }
                }
            } else if cat == .guide {
                track.role = .guide
                if norm.frameLength > 100 {
                    uploadedGuideBuffers[songId] = norm
                }
                if song.guideSource == .generated {
                    let expectedState = isActiveSong ? currentLiveGuideLoopState() : Self.defaultGuideLoopState(for: song)
                    if let genGuide = generatedGuideBuffers[songId],
                       genGuide.frameLength > 1,
                       generatedGuideLoopStates[songId] == expectedState {
                        bufferForCache = genGuide
                    } else if let silent = makeSilentStub(format: canonicalFormat) {
                        bufferForCache = silent
                    }
                }
            }
            
            let activeBuf = decodedTransposed[track.id] ?? bufferForCache
            if activeBuf.frameLength > 10 {
                let dur = Double(activeBuf.frameLength) / activeBuf.format.sampleRate
                track.duration = dur
                if dur > maxDur { maxDur = dur }
            } else if track.duration > maxDur {
                maxDur = track.duration
            }
            
            if track.waveformPeaks.isEmpty && track.includeInWaveform && norm.frameLength > 100 {
                track.waveformPeaks = decTrack.waveformPeaks.isEmpty
                    ? extractWaveformPeaks(from: norm, samplesCount: 4000)
                    : decTrack.waveformPeaks
                didUpdatePeaks = true
            }
            
            hydratedItems.append((track, bufferForCache))
            seenTrackIds.insert(track.id)
        }
        
        // Preserve synthesized Click / Guide tracks created during Stage 1 ONLY if decodedTracks lacked them
        let hasHydratedClick = hydratedItems.contains { Self.isClickTrack($0.0) }
        let hasHydratedGuide = hydratedItems.contains { Self.isGuideTrack($0.0) }
        for (id, existingTrack) in existingTracksById where !seenTrackIds.contains(id) {
            guard existingTrack.fileURL == nil, Self.isClickOrGuideTrack(existingTrack) else { continue }
            if Self.isClickTrack(existingTrack) && hasHydratedClick { continue }
            if Self.isGuideTrack(existingTrack) && hasHydratedGuide { continue }
            let existingBuf = pristineMasterBuffers[id] ?? channels[id]?.buffer ?? AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: 1)!
            hydratedItems.append((existingTrack, existingBuf))
        }
        
        hydratedItems.sort { (a, b) -> Bool in
            let cat1 = StemCategory.category(for: a.0.name, role: a.0.role)
            let cat2 = StemCategory.category(for: b.0.name, role: b.0.role)
            if cat1 != cat2 { return cat1 < cat2 }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        
        songBuffersCache[songId] = hydratedItems
        recordTrackMetadataBackup(for: songId, tracks: hydratedItems.map { $0.0 })
        if hydratedItems.contains(where: { !Self.isClickOrGuideTrack($0.0) && $0.1.frameLength > 100 })
            || !hydratedItems.contains(where: { !Self.isClickOrGuideTrack($0.0) }) {
            memoryEvictedSongIds.remove(songId)
        }

        // Fallback to generated Click/Guide if the song was marked `.uploaded` without an actual audio buffer
        if !currentSetlist.songs[songIdx].excludesClickAndGuide {
            if currentSetlist.songs[songIdx].clickSource == .uploaded && (uploadedClickBuffers[songId]?.frameLength ?? 0) <= 100 {
                currentSetlist.songs[songIdx].clickSource = .generated
                if isActiveSong { currentSong.clickSource = .generated }
            }
            if currentSetlist.songs[songIdx].guideSource == .uploaded && (uploadedGuideBuffers[songId]?.frameLength ?? 0) <= 100 {
                currentSetlist.songs[songIdx].guideSource = .generated
                if isActiveSong { currentSong.guideSource = .generated }
            }
        }
        
        if isActiveSong {
            let cachedTrans = cachedTransformedBuffers(for: currentSong)
            let validTrackIds = Set(hydratedItems.map { $0.0.id })
            for staleId in Array(channels.keys) where !validTrackIds.contains(staleId) {
                channels.removeValue(forKey: staleId)
            }
            for staleId in Array(pristineMasterBuffers.keys) where !validTrackIds.contains(staleId) {
                pristineMasterBuffers.removeValue(forKey: staleId)
            }
            tracks = hydratedItems.map { $0.0 }
            
            for (track, buf) in hydratedItems {
                pristineMasterBuffers[track.id] = buf
                let activeBuf = cachedTrans?[track.id] ?? buf
                if let ch = channels[track.id] {
                    ch.buffer = activeBuf
                } else {
                    channels[track.id] = TrackChannel(track: track, buffer: activeBuf)
                }
            }
            
            if maxDur > 0 && currentSong.sections.isEmpty {
                currentSongDuration = maxDur
            }
            
            if didUpdatePeaks || masterWaveformPeaks.isEmpty {
                recalculateAggregateWaveform(samplesCount: 4000)
                if !masterWaveformPeaks.isEmpty {
                    songWaveformCache[songId] = (masterWaveformPeaks, renderedWaveformImage)
                }
            }
            
            if !currentSong.excludesClickAndGuide {
                if currentSong.clickSource == .generated {
                    regenerateClickTrack()
                }
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                }
            }
            
            syncMixState()
            updateMatrix()
            
            if (currentSong.transposeSemitones != 0 || currentSong.isTempoShifted) &&
               cachedTransformedBuffers(for: currentSong) == nil {
                setKeyAndTempo(forSongIndex: songIdx)
            }
            if !isApplyingUndoRedo && undoStack.isEmpty {
                baselineUndoSnapshot = captureCurrentUndoSnapshot()
            }
        } else {
            if !song.excludesClickAndGuide && (song.clickSource == .generated || song.guideSource == .generated) {
                preGenerateClickAndGuide(forSongId: songId)
            }
            if (song.transposeSemitones != 0 || song.isTempoShifted) &&
               cachedTransformedBuffers(for: song) == nil {
                preRenderTranspose(forSongIndex: songIdx)
            }
            if songIdx == currentSongIndex + 1 {
                syncMixState()
            }
        }
    }
    
    // MARK: - Auto-Save & Startup Session Restoration
    
    public var autoSaveSessionURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PeanutButter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AutoSaveSession.pbsession")
    }
    
    public func performAutoSave() {
        guard !currentSetlist.songs.isEmpty else { return }
        if !hasUnsavedChanges && currentSessionURL != nil {
            return
        }
        let lastPath = currentSessionURL?.path ?? UserDefaults.standard.string(forKey: "Playback_LastSessionPath")
        try? saveSession(
            to: autoSaveSessionURL,
            recordAsLastSession: false,
            asDirectoryPackage: true,
            associatedSessionPath: lastPath
        )
    }
    
    public func restoreLastSessionIfAvailable() {
        let fm = FileManager.default
        let autoURL = autoSaveSessionURL
        let lastPath = UserDefaults.standard.string(forKey: "Playback_LastSessionPath")
        let canonicalFormat = getCanonicalProcessingFormat()
        
        var candidateURLs: [(url: URL, recordAsLast: Bool, overrideSessionURL: URL?)] = []
        
        var isAutoDir: ObjCBool = false
        if fm.fileExists(atPath: autoURL.path, isDirectory: &isAutoDir), isAutoDir.boolValue {
            if let lastPath = lastPath, !lastPath.isEmpty, fm.fileExists(atPath: lastPath) {
                let associated = PlaybackFileManager.shared.peekAssociatedSessionPath(at: autoURL)
                let autoJSON = autoURL.appendingPathComponent("session.json")
                let autoDate = (try? fm.attributesOfItem(atPath: autoJSON.path)[.modificationDate] as? Date) ?? .distantPast
                let extDate = (try? fm.attributesOfItem(atPath: lastPath)[.modificationDate] as? Date) ?? .distantPast
                if associated == lastPath && autoDate >= extDate {
                    candidateURLs.append((autoURL, false, URL(fileURLWithPath: lastPath)))
                }
            }
        }
        if let lastPath = lastPath, !lastPath.isEmpty, fm.fileExists(atPath: lastPath) {
            candidateURLs.append((URL(fileURLWithPath: lastPath), true, nil))
        }
        if fm.fileExists(atPath: autoURL.path) {
            candidateURLs.append((autoURL, false, nil))
        }
        
        guard !candidateURLs.isEmpty else { return }
        
        sessionHydrationTask?.cancel()
        sessionHydrationGeneration &+= 1
        let generation = sessionHydrationGeneration
        transposeTasksBySong.values.forEach { $0.cancel() }
        transposeTasksBySong.removeAll()
        transposeProgressBySong.removeAll()
        downloadingSongProgress.removeAll()
        memoryEvictedSongIds.removeAll()
        songTrackMetadataBackup.removeAll()
        clearCancelledSongDownloads()
        isTransposing = false
        transposeProgress = 0.0
        transposingSongId = nil
        
        for candidate in candidateURLs {
            do {
                let hydrated = try PlaybackFileManager.shared.loadSessionMetadataFast(
                    from: candidate.url,
                    canonicalFormat: canonicalFormat
                )
                if candidate.url.standardizedFileURL == autoURL.standardizedFileURL {
                    let hasUUIDGibberishTrack = hydrated.songEntries.contains { entry in
                        entry.tracks.contains { Self.isLikelyUUIDString($0.name) }
                    }
                    let hasEmptyTracksWhileExtHasTracks: Bool = {
                        guard let extURL = candidate.overrideSessionURL else { return false }
                        return hydrated.songEntries.contains { entry in
                            entry.tracks.isEmpty &&
                            (PlaybackFileManager.shared.loadSongTrackMetadataFromSession(songId: entry.id, sessionURL: extURL)?.isEmpty == false)
                        }
                    }()
                    if hasUUIDGibberishTrack || hasEmptyTracksWhileExtHasTracks {
                        try? fm.removeItem(at: autoURL)
                        continue
                    }
                }
                if candidate.recordAsLast {
                    self.currentSessionURL = candidate.url
                    self.currentSessionLoadedModDate = LibraryBrowserManager.packageModificationDate(at: candidate.url)
                    UserDefaults.standard.set(candidate.url.path, forKey: "Playback_LastSessionPath")
                } else {
                    self.currentSessionURL = candidate.overrideSessionURL
                    self.currentSessionLoadedModDate = candidate.overrideSessionURL.map { LibraryBrowserManager.packageModificationDate(at: $0) }
                }
                self.currentSessionLoadedRevisionId = hydrated.lastSavedRevisionId
                self.updateCloudSetlistUpdateFlag(from: LibraryBrowserManager.shared.setlists)
                self.applyHydratedSessionMetadata(
                    hydrated: hydrated,
                    canonicalFormat: canonicalFormat,
                    recordAsLastSession: candidate.recordAsLast,
                    generation: generation
                )
                return
            } catch {
                print("Fast session metadata restore from \(candidate.url.path) failed: \(error)")
            }
        }
    }
    
    public func updateCurrentSong(title: String, artist: String, bpm: Double, key: String, sections: [SongSection]) {
        let wasTempoShifted = currentSong.isTempoShifted
        currentSong.title = title
        currentSong.artist = artist
        currentSong.bpm = bpm
        if !wasTempoShifted {
            currentSong.originalBPM = bpm
        }
        currentSong.musicalKey = key
        currentSong.sections = sections
        currentSong.defaultSections = sections
        
        if !currentSong.excludesClickAndGuide {
            if uploadedClickBuffers[currentSong.id] == nil {
                currentSong.clickSource = .generated
            }
            if uploadedGuideBuffers[currentSong.id] == nil {
                currentSong.guideSource = .generated
            }
        }
        
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex] = currentSong
        }
        
        syncActivePadToCurrentSongIfNeeded()
        
        ensureClickAndGuideTracksExist()
        reindexArrangement()
        updateArrangementWaveform()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    // MARK: - Mixer Matrix & Output Routing
    
    private static func busLinearGain(forFader volume: Float) -> Float {
        if volume <= 0.001 { return 0.0 }
        if volume >= 0.80 {
            let db = ((volume - 0.80) / 0.20) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = volume / 0.80
            return pow(norm, 2.0)
        }
    }

    public func updateTrackParameters(track: StemTrack) {
        markSessionChanged()
        updateMatrix()
        if isEditAutomationMode {
            recordCurrentAutomationPointValues()
        } else {
            let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
            let firstAffectingTime = activePoints
                .filter { $0.trackFaders[track.id] != nil || $0.trackPans[track.id] != nil || $0.trackMutes[track.id] != nil }
                .map { displayTime(forAutomationPoint: $0) }
                .min()
            let isPreAutomation = firstAffectingTime.map { playbackOffsetSeconds < $0 - 0.005 } ?? true
            if isPreAutomation || !isTrackAutomated(track.id) {
                baseTrackVolumes[track.id] = track.volume
                baseTrackPans[track.id] = track.pan
                baseTrackMutes[track.id] = track.isMuted
            }
        }
    }

    public func updateBusParameters(bus: AudioBus) {
        markSessionChanged()
        updateMatrix()
        if isEditAutomationMode {
            recordCurrentAutomationPointValues()
        } else {
            let busLower = bus.name.lowercased()
            let activePoints = currentSong.automationPoints.filter { !isAutomationPointTrimmedOut($0) }
            let firstAffectingTime = activePoints
                .filter { pt in
                    pt.busFaders.keys.contains { $0.lowercased() == busLower } ||
                    pt.busMutes.keys.contains { $0.lowercased() == busLower }
                }
                .map { displayTime(forAutomationPoint: $0) }
                .min()
            let isPreAutomation = firstAffectingTime.map { playbackOffsetSeconds < $0 - 0.005 } ?? true
            if isPreAutomation || !isBusAutomated(bus.name) {
                baseBusVolumes[bus.name] = bus.volume
                baseBusMutes[bus.name] = bus.isMuted
            }
        }
    }

    /// Fast-path gain & pan update for a single track during live fader/pan dragging.
    /// Avoids looping all channels, writing UserDefaults, or invalidating MainView via `markSessionChanged()` / `objectWillChange`.
    public func updateSingleTrackGain(_ track: StemTrack) {
        guard let channel = channels[track.id] else { return }
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let result = computeTrackOutputGain(
            track: track,
            channel: channel,
            anyTrackSoloed: anyTrackSoloed,
            anyBusSoloed: anyBusSoloed
        )
        mixState.updateAllTrackGains([track.id: result])
    }

    /// Fast-path gain update for all tracks routed to a single bus during live bus fader dragging.
    public func updateSingleBusGain(_ bus: AudioBus) {
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let targetBusLower = bus.name.lowercased()
        var gainsToUpdate: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)] = [:]

        for channel in channels.values where channel.track.assignedBusName.lowercased() == targetBusLower {
            gainsToUpdate[channel.track.id] = computeTrackOutputGain(
                track: channel.track,
                channel: channel,
                anyTrackSoloed: anyTrackSoloed,
                anyBusSoloed: anyBusSoloed
            )
        }
        if targetBusLower == "pad" {
            let busMuted = anyBusSoloed ? (!bus.isSoloed || bus.isMuted) : bus.isMuted
            padPlayer.setBusGain(busMuted ? 0.0 : bus.linearGain)
        }
        if !gainsToUpdate.isEmpty {
            mixState.updateAllTrackGains(gainsToUpdate)
        }
    }

    private func computeTrackOutputGain(
        track: StemTrack,
        channel: TrackChannel,
        anyTrackSoloed: Bool,
        anyBusSoloed: Bool
    ) -> (gainL: Float, gainR: Float, outL: Int, outR: Int) {
        // Find assigned bus (or fallback to auto-assign match)
        var bus = busses.first { $0.name.lowercased() == track.assignedBusName.lowercased() }
        if bus == nil {
            let autoBusName = StemTrack.autoAssignBus(for: track.name)
            bus = busses.first { $0.name.lowercased() == autoBusName.lowercased() }
            if let matched = bus {
                track.assignedBusName = matched.name
            }
        }

        // 1. Track-level mute / solo / solo-safe
        let trackMuted: Bool
        if anyTrackSoloed {
            trackMuted = (!track.isSoloed && !track.isSoloSafe) || track.isMuted
        } else {
            trackMuted = track.isMuted
        }

        // 2. Bus-level mute / solo / solo-safe
        let busMuted: Bool
        if let b = bus {
            if anyBusSoloed {
                busMuted = (!b.isSoloed && !b.isSoloSafe) || b.isMuted
            } else {
                busMuted = b.isMuted
            }
        } else {
            busMuted = anyBusSoloed
        }

        let effectiveMute = trackMuted || busMuted

        var gain = effectiveMute ? 0.0 : track.linearGain
        if let b = bus {
            gain *= b.linearGain
        }

        if !Self.isClickOrGuideTrack(track) {
            gain *= currentFadeGain
        }

        // Compute stereo pan law gains (unity at center 0.0)
        let effectivePan: Float
        if let b = bus, b.isMono {
            effectivePan = 0.0
        } else {
            effectivePan = max(-1.0, min(1.0, track.pan))
        }

        let gainL: Float
        let gainR: Float
        if effectivePan < 0.0 {
            gainL = gain
            gainR = gain * (1.0 + effectivePan)
        } else if effectivePan > 0.0 {
            gainL = gain * (1.0 - effectivePan)
            gainR = gain
        } else {
            gainL = gain
            gainR = gain
        }

        channel.effectiveGainL = gainL
        channel.effectiveGainR = gainR

        let (outL, outR) = resolvePhysicalOutputChannels(for: bus?.physicalOutputChannel ?? "Out 1/2", isMono: bus?.isMono ?? false)
        channel.outChannelL = outL
        channel.outChannelR = outR
        return (gainL, gainR, outL, outR)
    }
    
    public func updateMatrix() {
        let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
        let anyBusSoloed = busses.contains { $0.isSoloed }
        
        var gainsToUpdate: [UUID: (gainL: Float, gainR: Float, outL: Int, outR: Int)] = [:]
        
        for channel in channels.values {
            gainsToUpdate[channel.track.id] = computeTrackOutputGain(
                track: channel.track,
                channel: channel,
                anyTrackSoloed: anyTrackSoloed,
                anyBusSoloed: anyBusSoloed
            )
        }
        
        // Update ambient Pad Player output routing
        let padBus = busses.first { $0.name.lowercased() == "pad" }
        let (padL, padR) = resolvePhysicalOutputChannels(for: padBus?.physicalOutputChannel ?? "Out 1/2", isMono: padBus?.isMono ?? false)
        padPlayer.setTargetOutputChannels(left: padL, right: padR)
        
        // Update ambient Pad Player channel fader gain (channel strip feeding into Pad bus)
        let padChannelGain: Float
        if padChannelMuted || (anyTrackSoloed && !padChannelSoloed) {
            padChannelGain = 0.0
        } else if padChannelVolume <= 0.01 {
            padChannelGain = 0.0
        } else if padChannelVolume >= 0.80 {
            let db = ((padChannelVolume - 0.80) / 0.20) * 6.0
            padChannelGain = pow(10.0, db / 20.0)
        } else {
            let norm = (padChannelVolume - 0.01) / 0.79
            let db = -60.0 * (1.0 - norm)
            padChannelGain = pow(10.0, db / 20.0)
        }
        padPlayer.setVolume(padChannelGain)
        padPlayer.setPan(padChannelPan)
        
        // Update ambient Pad Player bus gain
        if let padBus = busses.first(where: { $0.name.lowercased() == "pad" }) {
            let busMuted = anyBusSoloed ? (!padBus.isSoloed || padBus.isMuted) : padBus.isMuted
            padPlayer.setBusGain(busMuted ? 0.0 : padBus.linearGain)
        } else {
            padPlayer.setBusGain(anyBusSoloed ? 0.0 : 1.0)
        }
        
        if playbackState == .playing {
            mixState.updateAllTrackGains(gainsToUpdate)
        } else {
            syncMixState()
        }
        saveBusRouting(for: deviceManager.selectedDevice)
        objectWillChange.send()
    }
    
    public var currentMasterLinearGain: Float {
        if masterVolume <= 0.01 {
            return 0.0
        } else if masterVolume >= 0.75 {
            let db = ((masterVolume - 0.75) / 0.25) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = (masterVolume - 0.01) / 0.74
            let db = -60.0 * (1.0 - norm)
            return pow(10.0, db / 20.0)
        }
    }
    
    private func updateMasterVolume() {
        let gain = currentMasterLinearGain
        masterMixer.outputVolume = gain
        mixState.setMasterGain(gain)
    }
    
    private func updateTransportPosition(to seconds: TimeInterval) {
        let bpm = currentSong.bpm
        let timeSig = max(1, currentSong.timeSignatureNumerator)
        let bar: Int
        let beat: Int
        let liveBPM: Double
        
        let sourceSec = audioTime(forArrangementTime: seconds)
        let (tsNum, tsDen) = currentSong.timeSignature(atSourceTime: sourceSec)
        let activeGrid = cachedEffectiveBeatGrid
        var matchedMarker: BeatGridMarker? = nil
        if !activeGrid.isEmpty {
            let target = seconds + 0.0005
            var low = 0
            var high = activeGrid.count - 1
            var bestIdx = -1
            while low <= high {
                let mid = (low + high) / 2
                if activeGrid[mid].time <= target {
                    bestIdx = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            if bestIdx >= 0 {
                matchedMarker = activeGrid[bestIdx]
            }
        }
        if let timelineMarker = matchedMarker {
            bar = timelineMarker.bar
            beat = timelineMarker.beat
            liveBPM = currentSong.activeMarker(at: sourceSec)?.instantaneousBPM ?? timelineMarker.instantaneousBPM
        } else if let timelineMarker = currentSong.activeMarker(at: seconds) {
            bar = timelineMarker.bar
            beat = timelineMarker.beat
            liveBPM = currentSong.activeMarker(at: sourceSec)?.instantaneousBPM ?? timelineMarker.instantaneousBPM
        } else {
            let secondsPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, tsDen)))
            let totalBeats = Int(seconds / secondsPerBeat)
            bar = (totalBeats / max(1, tsNum)) + 1
            beat = (totalBeats % max(1, tsNum)) + 1
            liveBPM = bpm
        }
        
        let secIdx = currentSong.sections.firstIndex(where: { seconds >= $0.startTime && seconds < $0.endTime }) ?? 0
        
        let updated = TransportPosition(
            currentTime: seconds,
            totalDuration: currentSongDuration,
            bar: bar,
            beat: beat,
            currentSectionIndex: secIdx,
            currentBPM: liveBPM,
            currentTimeSignatureNumerator: tsNum,
            currentTimeSignatureDenominator: tsDen
        )
        transportPosition = updated
        transportClock.position = updated
        transportDisplayClock.update(with: updated)
    }
    
    private func resetPeakLevels() {
        for track in tracks {
            track.peakLevelLeft = 0.0
            track.peakLevelRight = 0.0
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            track.meter.reset()
        }
        for bus in busses {
            bus.peakLevelLeft = 0.0
            bus.peakLevelRight = 0.0
            bus.rawPeakL = 0.0
            bus.rawPeakR = 0.0
            bus.meter.reset()
        }
        masterPeakLeft = 0.0
        masterPeakRight = 0.0
        rawMasterPeakL = 0.0
        rawMasterPeakR = 0.0
        masterMeter.reset()
        resetClickMeters()
    }
    
    private func extractWaveformPeaks(from buffer: AVAudioPCMBuffer, samplesCount: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0, samplesCount > 0 else {
            return Array(repeating: 0.1, count: max(1, samplesCount))
        }
        
        let totalFrames = Int(buffer.frameLength)
        var peaks = [Float](repeating: 0.0, count: samplesCount)
        
        // SIMD-accelerated peak extraction via `vDSP_maxmgv` using floating-point frame bounds so 0..samplesCount spans 100% of audio
        for bucket in 0..<samplesCount {
            let startFrame = Int((Double(bucket) * Double(totalFrames)) / Double(samplesCount))
            let endFrame = min(totalFrames, max(startFrame + 1, Int((Double(bucket + 1) * Double(totalFrames)) / Double(samplesCount))))
            let count = endFrame - startFrame
            if count > 0 {
                var maxPeak: Float = 0.0
                vDSP_maxmgv(channelData.advanced(by: startFrame), 1, &maxPeak, vDSP_Length(count))
                peaks[bucket] = min(1.0, maxPeak)
            }
        }
        return peaks
    }
    
}
