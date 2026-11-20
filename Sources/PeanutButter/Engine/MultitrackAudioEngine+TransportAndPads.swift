import Foundation
import AVFoundation
import Combine
import CoreAudio
import Accelerate
import AppKit
import QuartzCore
import SwiftUI
import os

@MainActor
extension MultitrackAudioEngine {
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
        if isPostSongClickActive {
            mixState.stopPostSongClick()
            isPostSongClickActive = false
        }
        
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                isEngineRunning = true
            } catch {
                isEngineRunning = false
                PeanutButterLog.audio.error("Failed to start AVAudioEngine for pre-roll: \(error.localizedDescription, privacy: .public)")
                showAudioDeviceBanner("Audio engine failed to start: \(error.localizedDescription)")
                return
            }
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
                    } else if isPadLinked {
                        syncActivePadToCurrentSongIfNeeded()
                    }
                } else {
                    if isPadLinked, let lockedKey = linkedSongPadKey {
                        currentPadKey = lockedKey
                    }
                    isPadActive = true
                    if padPlayer.isPlaying {
                        padPlayer.stop()
                    }
                }
            } else if !isPadActive || !padPlayer.isPlaying {
                startPadPlayer()
            } else if isPadLinked {
                syncActivePadToCurrentSongIfNeeded()
            }
        } else if isPadActive {
            if currentSong.padIntroOutroOnly {
                if !section.isIntroOrOutro && padPlayer.isPlaying {
                    padPlayer.stop()
                } else if isPadLinked && section.isIntroOrOutro && !padPlayer.isPlaying {
                    startPadPlayer()
                }
            } else if isPadLinked, let normalized = linkedSongPadKey {
                if currentPadKey != normalized || padPlayer.activePackId != currentSong.padPresetId {
                    currentPadKey = normalized
                    padPlayer.transitionToKey(normalized, packId: currentSong.padPresetId)
                }
            }
        } else if isPadLinked, let normalized = linkedSongPadKey {
            currentPadKey = normalized
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
        updateSMPTEState(persistDevicePreset: false)
        if isPostSongClickActive {
            activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
        }
        if playbackState != .playing {
            syncMixState()
        }
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
            updateSMPTEState(persistDevicePreset: false)
            if isPostSongClickActive {
                activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
            }
            if playbackState != .playing {
                syncMixState()
            }
        } else if targetIdx == currentSongIndex + 1 {
            syncMixState()
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
    
    // MARK: - SINGLE-CLOCK SAMPLE-ACCURATE MULTI-TRACK TRANSPORT (ZERO DESYNC FOR 26+ TRACKS!)
    
    func buildTimelineSlices(for song: Song, duration: TimeInterval, sampleRate: Double) -> [RenderTimelineSlice] {
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

    func buildNextSongRenderState(
        sampleRate: Double,
        currentDuration: TimeInterval
    ) -> (
        transitionMode: SongTransitionType,
        transitionStartFrame: Int64,
        nextTotalFrames: Int64,
        nextSlices: [RenderTimelineSlice],
        nextTracks: [RenderTrackEntry],
        nextRetainedBuffers: [AVAudioPCMBuffer],
        nextHasSMPTECue: Bool,
        nextSMPTECueTimelineFrame: Int64,
        nextSMPTEStartSeconds: Double
    ) {
        let mode = currentSong.transitionType
        guard currentSongIndex >= 0,
              currentSongIndex + 1 < currentSetlist.songs.count,
              (mode == .autoLink || mode == .overlap || mode == .crossfade) else {
            return (.cueNextSong, 0, 0, [], [], [], false, 0, 0.0)
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
            return (.cueNextSong, 0, 0, [], [], [], false, 0, 0.0)
        }
        
        guard !nextSongItems.isEmpty else {
            return (.cueNextSong, 0, 0, [], [], [], false, 0, 0.0)
        }
        
        let needsPreGenClick = !nextSong.excludesClickAndGuide && nextSong.clickSource == .generated && (generatedClickBuffers[nextSong.id]?.frameLength ?? 0) <= 1
        let expectedNextGuideState = expectedDefaultGuideLoopState(forSongAt: currentSongIndex + 1, song: nextSong)
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
        var nextRetainedBuffers: [AVAudioPCMBuffer] = []
        nextRetainedBuffers.reserveCapacity(nextSongItems.count)
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

            nextRetainedBuffers.append(effectiveBuf)
            nextTracks.append(RenderTrackEntry(
                trackId: track.id,
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

        let nextHasSMPTECue = nextSong.smpteCue != nil
        let nextSMPTECueTimelineFrame = Int64(round(max(0.0, nextSong.smpteCue?.time ?? 0.0) * sampleRate))
        let nextSMPTEStartSeconds = nextSong.smpteCue?.totalStartSeconds(for: smpteFrameRate) ?? 0.0

        return (
            mode,
            transitionStartFrame,
            nextTotalFrames,
            nextSlices,
            nextTracks,
            nextRetainedBuffers,
            nextHasSMPTECue,
            nextSMPTECueTimelineFrame,
            nextSMPTEStartSeconds
        )
    }
    
    /// Synchronizes all arrangement slices, track pointers, L/R gains, loop bounds, and staged next song into the lock-free `RealTimeMixEngineState`.
    /// Zero `AVAudioPCMBuffer` copies (`memcpy`) are ever performed!
    func syncMixState() {
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
        var retainedBuffers: [AVAudioPCMBuffer] = []
        retainedBuffers.reserveCapacity(channels.count)
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
            
            retainedBuffers.append(buf)
            renderTracks.append(RenderTrackEntry(
                trackId: track.id,
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
        retainedBuffers.append(contentsOf: nextStaged.nextRetainedBuffers)
        
        mixState.configure(
            sampleRate: sampleRate,
            totalDuration: masterDuration,
            slices: renderSlices,
            tracks: renderTracks,
            retainedBuffers: retainedBuffers,
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
            nextTracks: nextStaged.nextTracks,
            nextHasSMPTECue: nextStaged.nextHasSMPTECue,
            nextSMPTECueTimelineFrame: nextStaged.nextSMPTECueTimelineFrame,
            nextSMPTEStartSeconds: nextStaged.nextSMPTEStartSeconds
        )
        syncStagedPostSongClickOnEnd(sampleRate: sampleRate, currentDuration: masterDuration)
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
        if isPostSongClickActive {
            mixState.stopPostSongClick()
            isPostSongClickActive = false
        }
        
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
            do {
                try audioEngine.start()
                isEngineRunning = true
            } catch {
                isEngineRunning = false
                PeanutButterLog.audio.error("Failed to start AVAudioEngine for playback: \(error.localizedDescription, privacy: .public)")
                showAudioDeviceBanner("Audio engine failed to start: \(error.localizedDescription)")
                return
            }
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
                    if isPadLinked, let lockedKey = linkedSongPadKey {
                        currentPadKey = lockedKey
                    }
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
        } else if isPadLinked, let lockedKey = linkedSongPadKey {
            currentPadKey = lockedKey
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
        finishOrCancelActiveManualFade(snapToTarget: true)
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
        finishOrCancelActiveManualFade(snapToTarget: true)
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        hasTriggeredEarlyTransition = false
        hasTriggeredDualTransitionPad = false
        pendingTransitionNextSongIndex = nil
        pendingTransitionStartOffset = 0.0
        playbackState = .stopped
        if !isTransitioningIntoPostSongClick {
            if isPostSongClickActive {
                mixState.stopPostSongClick()
                isPostSongClickActive = false
            }
            MIDICueEngine.shared.stopMIDIClock()
            resetClickMeters()
        }
        stopTransportClock()
        playbackOffsetSeconds = 0.0
        scheduledStartOffset = 0.0
        currentPlayingSectionId = nil
        queuedNextSection = nil
        isBeatFlashing = false
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
                    track.setLiveVolume(baseVol, forceDisplay: true)
                }
            }
            songEndBaseVolumes.removeAll()
            updateAllNonPadTrackGainsFastPath()
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
        if isPostSongClickActive {
            stopPostSongClick()
        }
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
            let fadeWindow = resolveSongEndFadeWindow(for: currentSong, fallbackDuration: currentSongDuration)
            if fadeWindow == nil || clampedTime < (fadeWindow?.start ?? 0.0) {
                restoreSongEndFadeVolumesIfNeeded()
            }
        }
    }
    
    // MARK: - Hardware-Locked Sample Playhead Clock
    
    func stopTransportClock() {
        stopTransportWatchdogTimer()
        let padNeedsMeters = padPlayer.isPlaying || padPlayer.isFadingOut || padMeterPeakL > 0.0 || padMeterPeakR > 0.0
        if !padNeedsMeters && !isPostSongClickActive && activeManualFade == nil {
            stopUIDisplayLink()
        }
    }

    func startAudioClockTransportTimer() {
        ensureUIDisplayLinkRunning()
        startTransportWatchdogTimer()
    }
    
    func tickPlaybackClock() {
        guard playbackState == .playing else { return }
        
        let prevSec = playbackOffsetSeconds
        let (currentSec, completedSingleLoop, didRepeatSingleLoop, reachedEnd, transitionedToNextSong, didJumpToQueuedSection, isPreRollActive, preRollTargetSec, engineIsPlaying, atOrPastEnd) = mixState.pollStatus()
        lastPlaybackClockTickTimestamp = CACurrentMediaTime()
        if activeManualFade != nil {
            tickActiveManualFade(now: lastPlaybackClockTickTimestamp)
        }
        
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
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else if currentSong.cueNextSongSection {
                    applyGuideBuffer()
                }
            }
            objectWillChange.send()
        }
        
        if didRepeatSingleLoop {
            isLoopActive = false
            loopMode = .none
            loopedSection = nil
            singleLoopRemaining = 0
            if !currentSong.excludesClickAndGuide {
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else if currentSong.cueNextSongSection {
                    applyGuideBuffer()
                }
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
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else if currentSong.cueNextSongSection {
                    applyGuideBuffer()
                }
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
        
        // Automatic Fade Out on Song End ("Fade End" over End section or "5 Second Fade Out")
        applySongEndFadeIfNeeded(at: currentSec)
        
        playbackOffsetSeconds = effectiveDisplaySec
        updateTransportPosition(to: effectiveDisplaySec)
    }
    
    // MARK: - Song Transitions
    
    public func updateSongTransition(at index: Int, type: SongTransitionType) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        let songId = currentSetlist.songs[index].id
        let isLastSong = index >= currentSetlist.songs.count - 1
        let incompatible = !isLastSong && (type == .autoLink || type == .overlap || type == .crossfade)
        let prevClickCutoff = currentSetlist.songs[index].isContinueClickEffective(isLastSongInSetlist: isLastSong)
        let prevType = currentSetlist.songs[index].transitionType
        let prevCueNext = currentSetlist.songs[index].isCueNextSongSectionEffective(isLastSongInSetlist: isLastSong)
        currentSetlist.songs[index].transitionType = type
        if incompatible {
            currentSetlist.songs[index].continuePad = false
            currentSetlist.songs[index].continueClick = false
        } else {
            currentSetlist.songs[index].cueNextSongSection = false
        }
        let nextClickCutoff = currentSetlist.songs[index].isContinueClickEffective(isLastSongInSetlist: isLastSong)
        let nextCueNext = currentSetlist.songs[index].isCueNextSongSectionEffective(isLastSongInSetlist: isLastSong)
        if prevClickCutoff != nextClickCutoff {
            generatedClickBuffers.removeValue(forKey: songId)
        }
        let guideCueChanged = (prevCueNext != nextCueNext) || (nextCueNext && prevType != type)
        if guideCueChanged {
            generatedGuideBuffers.removeValue(forKey: songId)
            generatedGuideLoopStates.removeValue(forKey: songId)
        }
        if index == currentSongIndex {
            currentSong.transitionType = type
            if incompatible {
                currentSong.continuePad = false
                currentSong.continueClick = false
            } else {
                currentSong.cueNextSongSection = false
            }
            if prevClickCutoff != nextClickCutoff && !currentSong.excludesClickAndGuide && currentSong.clickSource == .generated {
                regenerateClickTrack()
            }
            if guideCueChanged && !currentSong.excludesClickAndGuide {
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else {
                    applyGuideBuffer()
                }
            }
            syncMixState()
        } else if index == currentSongIndex + 1 {
            syncMixState()
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    public func updateSongCueNextSongSection(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        let isLastSong = index >= currentSetlist.songs.count - 1
        let t = currentSetlist.songs[index].transitionType
        let allowed = !isLastSong && (t == .autoLink || t == .overlap || t == .crossfade)
        let resolved = allowed ? enabled : false
        let songId = currentSetlist.songs[index].id

        currentSetlist.songs[index].cueNextSongSection = resolved
        generatedGuideBuffers.removeValue(forKey: songId)
        generatedGuideLoopStates.removeValue(forKey: songId)
        if index == currentSongIndex {
            currentSong.cueNextSongSection = resolved
            if !currentSong.excludesClickAndGuide {
                if currentSong.guideSource == .generated {
                    regenerateGuideTrack()
                } else {
                    applyGuideBuffer()
                }
            }
            syncMixState()
        } else if index == currentSongIndex + 1 {
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

    public func updateSongContinueClick(at index: Int, continueClick: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        let isLastSong = index >= currentSetlist.songs.count - 1
        let t = currentSetlist.songs[index].transitionType
        let allowed = isLastSong || (t == .cueNextSong || t == .stayInSong || t == .cueFirstSong)
        let resolved = allowed ? continueClick : false
        let songId = currentSetlist.songs[index].id

        currentSetlist.songs[index].continueClick = resolved
        generatedClickBuffers.removeValue(forKey: songId)
        if index == currentSongIndex {
            currentSong.continueClick = resolved
            if !currentSong.excludesClickAndGuide && currentSong.clickSource == .generated {
                regenerateClickTrack()
            }
            syncMixState()
        } else if index == currentSongIndex + 1 {
            syncMixState()
        }
        markSessionChanged()
        objectWillChange.send()
    }
    
    
    func resolveSongEndFadeWindow(for song: Song, fallbackDuration: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        if song.fadeEndSectionEnabled {
            return song.endSectionForFade.map { (start: max(0.0, $0.startTime), end: $0.endTime) }
        }
        if song.endFadeOutEnabled {
            let effectiveEndTime: TimeInterval = song.sections.isEmpty
                ? fallbackDuration
                : (song.sections.map { $0.endTime }.max() ?? fallbackDuration)
            guard effectiveEndTime > 5.0 else { return nil }
            return (start: max(0.0, effectiveEndTime - 5.0), end: effectiveEndTime)
        }
        return nil
    }

    func restoreSongEndFadeVolumesIfNeeded() {
        guard !songEndBaseVolumes.isEmpty else { return }
        for track in tracks {
            if let baseVol = songEndBaseVolumes[track.id] {
                track.setLiveVolume(baseVol, forceDisplay: true)
            }
        }
        songEndBaseVolumes.removeAll()
        updateAllNonPadTrackGainsFastPath()
    }

    func applySongEndFadeIfNeeded(at currentSec: TimeInterval) {
        guard let window = resolveSongEndFadeWindow(for: currentSong, fallbackDuration: currentSongDuration) else {
            restoreSongEndFadeVolumesIfNeeded()
            return
        }
        let fadeDuration = max(0.05, window.end - window.start)
        if currentSec >= window.start {
            let remaining = max(0.0, window.end - currentSec)
            let progress = min(1.0, max(0.0, 1.0 - (remaining / fadeDuration)))
            let t = Float((1.0 - cos(progress * .pi)) * 0.5)
            for track in tracks {
                if isExemptFromFade(track) { continue }
                if songEndBaseVolumes[track.id] == nil {
                    songEndBaseVolumes[track.id] = track.volume
                }
                let baseVol = songEndBaseVolumes[track.id] ?? 0.80
                track.setLiveVolume(max(0.0, baseVol * (1.0 - t)), forceDisplay: remaining <= 0.01)
            }
            updateAllNonPadTrackGainsFastPath()
        } else {
            restoreSongEndFadeVolumesIfNeeded()
        }
    }

    public func updateSongEndFadeOut(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].endFadeOutEnabled = enabled
        if enabled {
            currentSetlist.songs[index].fadeEndSectionEnabled = false
        }
        if index == currentSongIndex {
            currentSong.endFadeOutEnabled = enabled
            if enabled {
                currentSong.fadeEndSectionEnabled = false
            }
            if !currentSong.endFadeOutEnabled && !currentSong.fadeEndSectionEnabled {
                restoreSongEndFadeVolumesIfNeeded()
            }
        }
        markSessionChanged()
        objectWillChange.send()
    }

    public func updateSongFadeEndSection(at index: Int, enabled: Bool) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        currentSetlist.songs[index].fadeEndSectionEnabled = enabled
        if enabled {
            currentSetlist.songs[index].endFadeOutEnabled = false
        }
        if index == currentSongIndex {
            currentSong.fadeEndSectionEnabled = enabled
            if enabled {
                currentSong.endFadeOutEnabled = false
            }
            if !currentSong.endFadeOutEnabled && !currentSong.fadeEndSectionEnabled {
                restoreSongEndFadeVolumesIfNeeded()
            }
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
    func remapPadPackReferences(in song: inout Song, from oldId: String, to newId: String) -> Bool {
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

    /// Normalized pad key matching the current song's active transposed key (or `nil` if the song has no key set).
    public var linkedSongPadKey: String? {
        let transposed = currentSong.currentTransposedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if !transposed.isEmpty && transposed != "—" && transposed != "--" {
            raw = transposed
        } else {
            let musical = currentSong.musicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !musical.isEmpty && musical != "—" && musical != "--" else {
                return nil
            }
            raw = musical
        }
        return AudioSampleBank.normalizeKeyForPad(raw)
    }

    /// True when playback is active with Pad `LINK` enabled and the song has a valid musical key.
    public var isPadKeyLockedToSong: Bool {
        playbackState == .playing && isPadLinked && linkedSongPadKey != nil
    }

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
        guard isPadLinked, let normalized = linkedSongPadKey else { return }
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
        if isPadKeyLockedToSong, let lockedKey = linkedSongPadKey {
            if let explicit = key {
                let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "—" && trimmed != "--" {
                    let normalizedExplicit = AudioSampleBank.normalizeKeyForPad(trimmed)
                    if normalizedExplicit != lockedKey {
                        return
                    }
                }
            }
        }

        let candidateKey: String
        if isPadKeyLockedToSong, let lockedKey = linkedSongPadKey {
            candidateKey = lockedKey
        } else if let explicit = key {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "—" && trimmed != "--" {
                candidateKey = trimmed
            } else {
                candidateKey = linkedSongPadKey ?? "C"
            }
        } else {
            candidateKey = linkedSongPadKey ?? "C"
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
    
    func handleSectionTransitionForPad(activeSec: SongSection) {
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
    func completeRealtimeHandoverToNextSong(currentSeconds: TimeInterval) {
        let nextIndex = currentSongIndex + 1
        guard nextIndex < currentSetlist.songs.count else {
            stop()
            return
        }
        
        // Restore outgoing song's automated mix state before caching so track objects & shared busses stay scoped to it
        if !currentSong.title.isEmpty && !currentSong.automationPoints.isEmpty {
            restoreAutomatedParametersToBaseMix(updateAudioMatrix: false)
        }
        if !songEndBaseVolumes.isEmpty {
            for track in tracks {
                if let baseVol = songEndBaseVolumes[track.id] {
                    track.setLiveVolume(baseVol, forceDisplay: true)
                }
            }
            songEndBaseVolumes.removeAll()
        }
        resetTrackMeters(tracks)
        resetClickMeters()
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
                } else if self.currentSong.guideSource == .uploaded &&
                          self.currentSong.cueNextSongSection &&
                          self.uploadedGuideBuffers[nextSong.id] != nil {
                    self.applyGuideBuffer()
                }
            }
            self.syncMixState()
        }
        
        resetTrackMeters(newTracks)
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
        
        if let cachedWf = songWaveformCache[nextSong.id], !cachedWf.peaks.isEmpty {
            masterWaveformPeaks = cachedWf.peaks
            refreshSoloWaveformIfNeeded(forceRecompute: true, triggerArrangementUpdate: false)
            updateArrangementWaveform()
        } else {
            recalculateAggregateWaveform(samplesCount: 4000)
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
        updateSMPTEState(persistDevicePreset: false)
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
    
    // MARK: - Post-Song Continue Click Support

    func resolvePostSongClickParams(
        for song: Song,
        mode: PostSongClickOriginMode,
        duration: TimeInterval
    ) -> (bpm: Double, num: Int, den: Int, initialPhaseRatio: Double) {
        switch mode {
        case .stayInSongEnd:
            let safeDur = max(0.0, duration)
            let endArrSec = max(0.0, safeDur - 0.001)
            let endSourceSec = (song.id == currentSong.id) ? audioTime(forArrangementTime: endArrSec) : endArrSec
            let (endNum, endDen) = song.timeSignature(atSourceTime: endSourceSec)
            let beatsPerBar = max(1, endNum)
            let grid = song.effectiveBeatGrid(totalDuration: max(4.0, safeDur)).sorted { $0.time < $1.time }
            if let lastMarker = grid.last(where: { $0.time <= safeDur + 0.001 }) {
                let rawEndBPM = !song.tempoEvents.isEmpty
                    ? song.evaluateBPM(atSourceTime: endSourceSec)
                    : lastMarker.instantaneousBPM
                let endBPM = max(20.0, rawEndBPM > 20.0 ? rawEndBPM : song.bpm)
                let secPerBeat = (60.0 / endBPM) * (4.0 / Double(max(1, endDen)))
                let rawBarBeats = Double(max(1, lastMarker.beat) - 1) + ((safeDur - lastMarker.time) / max(0.05, secPerBeat))
                var modBeats = rawBarBeats.truncatingRemainder(dividingBy: Double(beatsPerBar))
                if modBeats < 0 { modBeats += Double(beatsPerBar) }
                return (endBPM, endNum, endDen, modBeats / Double(beatsPerBar))
            } else {
                let endBPM = max(20.0, !song.tempoEvents.isEmpty ? song.evaluateBPM(atSourceTime: endSourceSec) : song.bpm)
                let secPerBeat = (60.0 / endBPM) * (4.0 / Double(max(1, endDen)))
                let barSec = Double(beatsPerBar) * secPerBeat
                let remSec = max(0.0, safeDur.truncatingRemainder(dividingBy: max(0.05, barSec)))
                return (endBPM, endNum, endDen, remSec / max(0.05, barSec))
            }
        case .cuedSongStart:
            let (startNum, startDen) = song.timeSignature(atSourceTime: 0.0)
            let startGrid = song.effectiveBeatGrid(totalDuration: max(4.0, song.totalDuration)).sorted { $0.time < $1.time }
            let rawStartBPM = !song.tempoEvents.isEmpty
                ? song.evaluateBPM(atSourceTime: 0.0)
                : (startGrid.first?.instantaneousBPM ?? song.bpm)
            let startBPM = max(20.0, rawStartBPM > 20.0 ? rawStartBPM : song.bpm)
            return (startBPM, startNum, startDen, 0.0)
        }
    }

    func buildCachedPostSongClickBuffer(
        for song: Song,
        bpm: Double,
        num: Int,
        den: Int,
        isStagedCache: Bool
    ) -> AVAudioPCMBuffer? {
        let format = getCanonicalProcessingFormat()
        let sr = format.sampleRate > 0 ? format.sampleRate : 48000.0
        let soloed = (song.id == currentSong.id) ? clickSoloedSubdivisions : []
        let spec = PostSongClickSpec(
            bpmHundredths: Int((bpm * 100.0).rounded()),
            numerator: num,
            denominator: den,
            soundType: song.clickSound,
            accentEnabled: song.clickAccentEnabled,
            quarterEnabled: song.clickQuarterEnabled,
            eighthEnabled: song.clickEighthEnabled,
            sixteenthEnabled: song.clickSixteenthEnabled,
            accentVolPermille: Int((song.clickAccentVolume * 1000.0).rounded()),
            quarterVolPermille: Int((song.clickQuarterVolume * 1000.0).rounded()),
            eighthVolPermille: Int((song.clickEighthVolume * 1000.0).rounded()),
            sixteenthVolPermille: Int((song.clickSixteenthVolume * 1000.0).rounded()),
            soloedSubdivisions: soloed,
            sampleRateHz: Int(sr.rounded())
        )
        if isStagedCache {
            if cachedStagedPostSongClickSpec == spec, let buf = cachedStagedPostSongClickBuffer {
                return buf
            }
        } else {
            if cachedActivePostSongClickSpec == spec, let buf = cachedActivePostSongClickBuffer {
                return buf
            }
        }
        guard let buf = clickGenerator.generateOneBarLoopBuffer(
            bpm: bpm,
            timeSignatureNumerator: num,
            timeSignatureDenominator: den,
            soundType: song.clickSound,
            accentEnabled: song.clickAccentEnabled,
            quarterEnabled: song.clickQuarterEnabled,
            eighthEnabled: song.clickEighthEnabled,
            sixteenthEnabled: song.clickSixteenthEnabled,
            accentVolume: song.clickAccentVolume,
            quarterVolume: song.clickQuarterVolume,
            eighthVolume: song.clickEighthVolume,
            sixteenthVolume: song.clickSixteenthVolume,
            soloedSubdivisions: soloed,
            format: format
        ) else {
            return nil
        }
        if isStagedCache {
            cachedStagedPostSongClickSpec = spec
            cachedStagedPostSongClickBuffer = buf
        } else {
            cachedActivePostSongClickSpec = spec
            cachedActivePostSongClickBuffer = buf
        }
        return buf
    }

    func resolveClickTrackGainAndChannels(for targetSong: Song) -> (trackId: UUID?, gainL: Float, gainR: Float, outL: Int, outR: Int) {
        if targetSong.id == currentSong.id,
           let ct = tracks.first(where: { Self.isClickTrack($0) }),
           let ch = channels[ct.id] {
            let anyTrackSoloed = channels.values.contains { $0.track.isSoloed } || padChannelSoloed
            let anyBusSoloed = busses.contains { $0.isSoloed }
            let g = computeTrackOutputGain(track: ct, channel: ch, anyTrackSoloed: anyTrackSoloed, anyBusSoloed: anyBusSoloed)
            return (ct.id, g.gainL, g.gainR, g.outL, g.outR)
        }

        let cachedTrack = songBuffersCache[targetSong.id]?.first(where: { Self.isClickTrack($0.0) })?.0
        let clickBus = busses.first { $0.name.lowercased() == (cachedTrack?.assignedBusName.lowercased() ?? "click") }
            ?? busses.first { $0.name.lowercased() == "click" }
        let anyBusSoloed = busses.contains { $0.isSoloed }
        let busMuted: Bool = {
            guard let b = clickBus else { return anyBusSoloed }
            return anyBusSoloed ? ((!b.isSoloed && !b.isSoloSafe) || b.isMuted) : b.isMuted
        }()
        let trackMuted = cachedTrack?.isMuted ?? false
        let effectiveMute = trackMuted || busMuted
        var gain: Float = effectiveMute ? 0.0 : (cachedTrack?.linearGain ?? 1.0)
        if let b = clickBus {
            gain *= b.linearGain
        }
        let effectivePan: Float = (clickBus?.isMono == true) ? 0.0 : max(-1.0, min(1.0, cachedTrack?.pan ?? 0.0))
        let gainL = effectivePan > 0.0 ? gain * (1.0 - effectivePan) : gain
        let gainR = effectivePan < 0.0 ? gain * (1.0 + effectivePan) : gain
        let (outL, outR) = resolvePhysicalOutputChannels(for: clickBus?.physicalOutputChannel ?? "Out 3/4", isMono: clickBus?.isMono ?? false)
        return (cachedTrack?.id, gainL, gainR, outL, outR)
    }

    func syncStagedPostSongClickOnEnd(sampleRate: Double, currentDuration: TimeInterval) {
        guard !currentSetlist.songs.isEmpty,
              currentSongIndex >= 0,
              currentSongIndex < currentSetlist.songs.count else {
            mixState.configureStagedPostSongClickOnEnd(enabled: false, buffer: nil, initialPhaseFrame: 0, trackId: nil, gainL: 0, gainR: 0, outL: 2, outR: 3)
            return
        }
        let isLast = currentSongIndex >= currentSetlist.songs.count - 1
        guard currentSong.isContinueClickEffective(isLastSongInSetlist: isLast) else {
            mixState.configureStagedPostSongClickOnEnd(enabled: false, buffer: nil, initialPhaseFrame: 0, trackId: nil, gainL: 0, gainR: 0, outL: 2, outR: 3)
            return
        }

        let targetSong: Song?
        let mode: PostSongClickOriginMode
        if currentSong.transitionType == .stayInSong {
            targetSong = currentSong
            mode = .stayInSongEnd
        } else if isLast || currentSong.transitionType == .cueFirstSong {
            targetSong = currentSetlist.songs.first
            mode = .cuedSongStart
        } else {
            targetSong = (currentSongIndex + 1 < currentSetlist.songs.count) ? currentSetlist.songs[currentSongIndex + 1] : nil
            mode = .cuedSongStart
        }

        guard let target = targetSong, !target.excludesClickAndGuide else {
            mixState.configureStagedPostSongClickOnEnd(enabled: false, buffer: nil, initialPhaseFrame: 0, trackId: nil, gainL: 0, gainR: 0, outL: 2, outR: 3)
            return
        }

        let resolved = resolvePostSongClickParams(for: target, mode: mode, duration: currentDuration)
        guard let buf = buildCachedPostSongClickBuffer(for: target, bpm: resolved.bpm, num: resolved.num, den: resolved.den, isStagedCache: true),
              buf.frameLength > 0 else {
            mixState.configureStagedPostSongClickOnEnd(enabled: false, buffer: nil, initialPhaseFrame: 0, trackId: nil, gainL: 0, gainR: 0, outL: 2, outR: 3)
            return
        }

        let totalFrames = max(1, Int64(buf.frameLength))
        let initPhaseFrame = max(0, Int64((resolved.initialPhaseRatio * Double(totalFrames)).rounded())) % totalFrames
        let routing = resolveClickTrackGainAndChannels(for: target)
        mixState.configureStagedPostSongClickOnEnd(
            enabled: true,
            buffer: buf,
            initialPhaseFrame: initPhaseFrame,
            trackId: routing.trackId,
            gainL: routing.gainL,
            gainR: routing.gainR,
            outL: routing.outL,
            outR: routing.outR
        )
    }

    public func stopPostSongClick() {
        let wasActive = isPostSongClickActive
        mixState.stopPostSongClick()
        if isPostSongClickActive {
            isPostSongClickActive = false
        }
        if playbackState != .playing {
            MIDICueEngine.shared.stopMIDIClock()
            resetClickMeters()
        }
        if wasActive {
            stopTransportClock()
            updatePlaybackActivityAssertion()
        }
    }

    func activateOrRefreshPostSongClick(mode: PostSongClickOriginMode, preserveRunningPhase: Bool) {
        guard !currentSong.excludesClickAndGuide else {
            stopPostSongClick()
            return
        }

        let masterDuration: TimeInterval = {
            if !currentSong.sections.isEmpty {
                return currentSong.sections.map { $0.endTime }.max() ?? currentSongDuration
            }
            return currentSongDuration > 0 ? currentSongDuration : (tracks.map { $0.duration }.max() ?? 0.0)
        }()

        let resolved = resolvePostSongClickParams(for: currentSong, mode: mode, duration: masterDuration)
        guard let buf = buildCachedPostSongClickBuffer(for: currentSong, bpm: resolved.bpm, num: resolved.num, den: resolved.den, isStagedCache: false),
              buf.frameLength > 0 else {
            stopPostSongClick()
            return
        }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                isEngineRunning = true
            } catch {
                PeanutButterLog.audio.error("Failed to start AVAudioEngine for post-song click: \(error.localizedDescription, privacy: .public)")
            }
        }

        let routing = resolveClickTrackGainAndChannels(for: currentSong)
        let totalFrames = max(1, Int64(buf.frameLength))
        let computedInitFrame = max(0, Int64((resolved.initialPhaseRatio * Double(totalFrames)).rounded())) % totalFrames
        let alreadyRunningOnRT = mixState.currentPostSongClickStatus().isActive

        mixState.activateOrUpdatePostSongClick(
            buffer: buf,
            initialPhaseFrame: (preserveRunningPhase && alreadyRunningOnRT) ? nil : computedInitFrame,
            preserveNormalizedPhase: preserveRunningPhase && alreadyRunningOnRT,
            trackId: routing.trackId,
            gainL: routing.gainL,
            gainR: routing.gainR,
            outL: routing.outL,
            outR: routing.outR
        )

        postSongClickOriginMode = mode
        activePostSongClickBPM = resolved.bpm
        activePostSongClickNumerator = resolved.num
        activePostSongClickDenominator = resolved.den
        if !isPostSongClickActive {
            isPostSongClickActive = true
        }
        MIDICueEngine.shared.syncMIDIClockPlayback(isPlayingAndUnmuted: !isMIDIMuted, bpm: resolved.bpm, isResume: true)
        ensureUIDisplayLinkRunning()
        updatePlaybackActivityAssertion()
    }

    public func handleSongEndTransition() {
        defer {
            isTransitioningIntoPostSongClick = false
            updatePlaybackActivityAssertion()
        }
        let isLastSong = currentSongIndex >= currentSetlist.songs.count - 1
        let transition = currentSong.transitionType
        let continuePad = currentSong.continuePad
        let shouldContinueClick = currentSong.isContinueClickEffective(isLastSongInSetlist: isLastSong)
        isTransitioningIntoPostSongClick = shouldContinueClick
        
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
                if shouldContinueClick {
                    activateOrRefreshPostSongClick(mode: .stayInSongEnd, preserveRunningPhase: true)
                } else {
                    stopPostSongClick()
                }
            } else {
                // "Cue First Song" will go back to the beginning of the set once the current song is finished
                selectSongInSetlist(at: 0)
                updatePadForKeyOfNewSong()
                stop()
                if shouldContinueClick && !currentSong.excludesClickAndGuide {
                    activateOrRefreshPostSongClick(mode: .cuedSongStart, preserveRunningPhase: true)
                } else {
                    stopPostSongClick()
                }
            }
            return
        }
        
        switch transition {
        case .stayInSong:
            if !continuePad && (isPadActive || padPlayer.isPlaying) {
                stopPadPlayer()
            }
            stop()
            if shouldContinueClick {
                activateOrRefreshPostSongClick(mode: .stayInSongEnd, preserveRunningPhase: true)
            } else {
                stopPostSongClick()
            }
        case .cueNextSong:
            selectSongInSetlist(at: currentSongIndex + 1)
            updatePadForKeyOfNewSong()
            stop()
            if shouldContinueClick && !currentSong.excludesClickAndGuide {
                activateOrRefreshPostSongClick(mode: .cuedSongStart, preserveRunningPhase: true)
            } else {
                stopPostSongClick()
            }
        case .autoLink, .overlap, .crossfade:
            if currentSongIndex + 1 < currentSetlist.songs.count {
                selectSongInSetlist(at: currentSongIndex + 1)
                play()
            } else {
                if !continuePad && (isPadActive || padPlayer.isPlaying) {
                    stopPadPlayer()
                }
                stop()
                stopPostSongClick()
            }
        case .cueFirstSong:
            selectSongInSetlist(at: 0)
            updatePadForKeyOfNewSong()
            stop()
            if shouldContinueClick && !currentSong.excludesClickAndGuide {
                activateOrRefreshPostSongClick(mode: .cuedSongStart, preserveRunningPhase: true)
            } else {
                stopPostSongClick()
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
    
    func finishOrCancelActiveManualFade(snapToTarget: Bool) {
        guard let fade = activeManualFade else { return }
        activeManualFade = nil
        if snapToTarget {
            for track in tracks {
                if isExemptFromFade(track) || fade.overriddenTrackIds.contains(track.id) { continue }
                let targetVol = fade.targetVolumes[track.id] ?? (fade.isFadingOut ? 0.0 : (preFadeVolumes[track.id] ?? 0.80))
                track.setLiveVolume(targetVol, forceDisplay: true)
            }
            updateAllNonPadTrackGainsFastPath()
        }
    }

    public func toggleFade() {
        activeManualFade = nil
        
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
                    track.setLiveVolume(0.0, forceDisplay: true)
                }
                currentFadeGain = 1.0
                updateAllNonPadTrackGainsFastPath()
                isFadedOut = true
                isFadeActive = true
            } else {
                for track in tracks {
                    if isExemptFromFade(track) { continue }
                    track.setLiveVolume(preFadeVolumes[track.id] ?? 0.80, forceDisplay: true)
                }
                currentFadeGain = 1.0
                updateAllNonPadTrackGainsFastPath()
                isFadedOut = false
                isFadeActive = false
            }
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
        activeManualFade = nil
        let dur = duration ?? fadeOutDuration
        var startVolumes: [UUID: Float] = [:]
        var targetVolumes: [UUID: Float] = [:]
        for track in tracks {
            if isExemptFromFade(track) { continue }
            if track.volume > 0.001 {
                preFadeVolumes[track.id] = track.volume
            } else if preFadeVolumes[track.id] == nil {
                preFadeVolumes[track.id] = 0.80
            }
            startVolumes[track.id] = track.volume
            targetVolumes[track.id] = 0.0
        }
        isFadedOut = true
        isFadeActive = true

        if dur <= 0.01 {
            for track in tracks {
                if isExemptFromFade(track) { continue }
                track.setLiveVolume(0.0, forceDisplay: true)
            }
            updateAllNonPadTrackGainsFastPath()
            return
        }

        activeManualFade = ActiveManualFade(
            isFadingOut: true,
            startTime: CACurrentMediaTime(),
            duration: dur,
            startVolumes: startVolumes,
            targetVolumes: targetVolumes
        )
        ensureUIDisplayLinkRunning()
    }
    
    public func startFadeIn(duration: TimeInterval? = nil) {
        activeManualFade = nil
        let dur = duration ?? fadeInDuration
        isFadedOut = false
        isFadeActive = false

        var startVolumes: [UUID: Float] = [:]
        var targetVolumes: [UUID: Float] = [:]
        for track in tracks {
            if isExemptFromFade(track) { continue }
            startVolumes[track.id] = track.volume
            targetVolumes[track.id] = preFadeVolumes[track.id] ?? 0.80
        }

        if dur <= 0.01 {
            for track in tracks {
                if isExemptFromFade(track) { continue }
                track.setLiveVolume(targetVolumes[track.id] ?? 0.80, forceDisplay: true)
            }
            updateAllNonPadTrackGainsFastPath()
            return
        }

        activeManualFade = ActiveManualFade(
            isFadingOut: false,
            startTime: CACurrentMediaTime(),
            duration: dur,
            startVolumes: startVolumes,
            targetVolumes: targetVolumes
        )
        ensureUIDisplayLinkRunning()
    }

    public func tickActiveManualFade(now: CFTimeInterval = CACurrentMediaTime()) {
        guard var fade = activeManualFade else { return }
        if fade.lastTickTime > 0 && (now - fade.lastTickTime) >= 0 && (now - fade.lastTickTime) < 0.002 {
            return
        }
        fade.lastTickTime = now
        let elapsed = max(0.0, now - fade.startTime)
        let progress = min(1.0, elapsed / max(0.01, fade.duration))
        let isComplete = progress >= 1.0
        let t = Float((1.0 - cos(progress * .pi)) * 0.5)

        for track in tracks {
            if isExemptFromFade(track) || fade.overriddenTrackIds.contains(track.id) { continue }
            let startVol = fade.startVolumes[track.id] ?? track.volume
            let targetVol = fade.targetVolumes[track.id] ?? (fade.isFadingOut ? 0.0 : (preFadeVolumes[track.id] ?? 0.80))
            let nextVol = isComplete ? targetVol : min(1.0, max(0.0, startVol + (targetVol - startVol) * t))
            track.setLiveVolume(nextVol, forceDisplay: isComplete)
        }
        updateAllNonPadTrackGainsFastPath()

        if isComplete {
            activeManualFade = nil
        } else {
            activeManualFade = fade
        }
    }
    
    // MARK: - Section Looping (L & I Hotkeys)
    
    private func refreshGuideAfterLoopOrQueueChange() {
        guard !currentSong.excludesClickAndGuide else { return }
        if currentSong.guideSource == .generated {
            regenerateGuideTrack()
        } else if currentSong.cueNextSongSection {
            applyGuideBuffer()
        }
    }

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
        refreshGuideAfterLoopOrQueueChange()
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
        refreshGuideAfterLoopOrQueueChange()
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
        refreshGuideAfterLoopOrQueueChange()
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
        refreshGuideAfterLoopOrQueueChange()
        objectWillChange.send()
    }
    
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
        refreshGuideAfterLoopOrQueueChange()
        objectWillChange.send()
    }
    
}
