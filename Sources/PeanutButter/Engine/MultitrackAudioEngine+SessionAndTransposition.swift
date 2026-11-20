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
    func cachedTransformedBuffers(for song: Song) -> [UUID: AVAudioPCMBuffer]? {
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
    
    func shouldRenderTransformedTrack(_ track: StemTrack, for song: Song, tempoShifted: Bool) -> Bool {
        if !Self.isClickOrGuideTrack(track) {
            return true
        }
        guard tempoShifted else { return false }
        let isGenClick = Self.isClickTrack(track) && song.clickSource == .generated
        let isGenGuide = Self.isGuideTrack(track) && song.guideSource == .generated
        return !isGenClick && !isGenGuide
    }
    
    struct SendablePCMBufferRef: @unchecked Sendable {
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
            if !songEndBaseVolumes.isEmpty {
                for track in tracks {
                    if let baseVol = songEndBaseVolumes[track.id] {
                        track.setLiveVolume(baseVol, forceDisplay: true)
                    }
                }
                songEndBaseVolumes.removeAll()
            }
            resetTrackMeters(tracks)
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
    
    static func resolvedAutoInfiniteLoopSection(for song: Song) -> SongSection? {
        guard song.autoInfiniteLoop else { return nil }
        return song.sections.first(where: {
            $0.abbreviation == "Cl" ||
            $0.displayAbbreviation == "Cl" ||
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click"
        }) ?? (song.sections.count >= 2 ? song.sections[1] : song.sections.first)
    }

    static func defaultGuideLoopState(
        for song: Song,
        nextCue: (section: SongSection, targetTime: TimeInterval)? = nil
    ) -> GeneratedGuideLoopState {
        let secVol = Int((song.guideSectionsVolume * 1000.0).rounded())
        let dirVol = Int((song.guideDirectionsVolume * 1000.0).rounded())
        let fbVol = Int((song.guideFallbackVolume * 1000.0).rounded())
        if let sec = resolvedAutoInfiniteLoopSection(for: song) {
            return GeneratedGuideLoopState(
                isLoopActive: true,
                loopedSectionId: sec.id,
                loopMode: .infinite,
                singleLoopRemaining: 0,
                queuedNextSectionId: nil,
                nextSongCueSectionId: nextCue?.section.id,
                nextSongCueSectionName: nextCue?.section.name,
                nextSongCueIncludeNumber: nextCue?.section.includeNumberInGuide,
                nextSongCuePlayGuide: nextCue?.section.playSectionGuideCue ?? false,
                nextSongCuePlayCountIn: nextCue?.section.playSectionCountIn ?? false,
                nextSongCueTargetTimeMs: nextCue.map { Int(round($0.targetTime * 1000.0)) } ?? -1,
                sectionsVolPermille: secVol,
                sectionsEnabled: song.guideSectionsEnabled,
                directionsVolPermille: dirVol,
                directionsEnabled: song.guideDirectionsEnabled,
                fallbackVolPermille: fbVol,
                fallbackEnabled: song.guideFallbackEnabled,
                soloedSubChannels: []
            )
        }
        return GeneratedGuideLoopState(
            isLoopActive: false,
            loopedSectionId: nil,
            loopMode: .none,
            singleLoopRemaining: 0,
            queuedNextSectionId: nil,
            nextSongCueSectionId: nextCue?.section.id,
            nextSongCueSectionName: nextCue?.section.name,
            nextSongCueIncludeNumber: nextCue?.section.includeNumberInGuide,
            nextSongCuePlayGuide: nextCue?.section.playSectionGuideCue ?? false,
            nextSongCuePlayCountIn: nextCue?.section.playSectionCountIn ?? false,
            nextSongCueTargetTimeMs: nextCue.map { Int(round($0.targetTime * 1000.0)) } ?? -1,
            sectionsVolPermille: secVol,
            sectionsEnabled: song.guideSectionsEnabled,
            directionsVolPermille: dirVol,
            directionsEnabled: song.guideDirectionsEnabled,
            fallbackVolPermille: fbVol,
            fallbackEnabled: song.guideFallbackEnabled,
            soloedSubChannels: []
        )
    }

    func expectedDefaultGuideLoopState(forSongAt index: Int, song: Song, duration: TimeInterval? = nil) -> GeneratedGuideLoopState {
        let resolvedDur = duration ?? songDurationForGuide(for: song)
        let nextCue = resolvedNextSongSectionCue(forSongAt: index, song: song, duration: resolvedDur)
        return Self.defaultGuideLoopState(for: song, nextCue: nextCue)
    }

    func currentLiveGuideLoopState() -> GeneratedGuideLoopState {
        let dur = songDurationForGuide(for: currentSong)
        let nextCue = resolvedNextSongSectionCue(forSongAt: currentSongIndex, song: currentSong, duration: dur)
        return GeneratedGuideLoopState(
            isLoopActive: isLoopActive,
            loopedSectionId: isLoopActive ? loopedSection?.id : nil,
            loopMode: isLoopActive ? loopMode : .none,
            singleLoopRemaining: (isLoopActive && loopMode == .single) ? singleLoopRemaining : 0,
            queuedNextSectionId: queuedNextSection?.id,
            nextSongCueSectionId: nextCue?.section.id,
            nextSongCueSectionName: nextCue?.section.name,
            nextSongCueIncludeNumber: nextCue?.section.includeNumberInGuide,
            nextSongCuePlayGuide: nextCue?.section.playSectionGuideCue ?? false,
            nextSongCuePlayCountIn: nextCue?.section.playSectionCountIn ?? false,
            nextSongCueTargetTimeMs: nextCue.map { Int(round($0.targetTime * 1000.0)) } ?? -1,
            sectionsVolPermille: Int((currentSong.guideSectionsVolume * 1000.0).rounded()),
            sectionsEnabled: currentSong.guideSectionsEnabled,
            directionsVolPermille: Int((currentSong.guideDirectionsVolume * 1000.0).rounded()),
            directionsEnabled: currentSong.guideDirectionsEnabled,
            fallbackVolPermille: Int((currentSong.guideFallbackVolume * 1000.0).rounded()),
            fallbackEnabled: currentSong.guideFallbackEnabled,
            soloedSubChannels: guideSoloedSubChannels
        )
    }

    func applyAutoInfiniteLoopIfNeeded(for song: Song) {
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
        isEditingTempoCurve = false
        guideSoloedSubChannels.removeAll()
        resetGuideSubChannelMeters()
        manualPadPackId = nil
        activeManualFade = nil
        isFadedOut = false
        isFadeActive = false
        currentFadeGain = 1.0
        preFadeVolumes.removeAll()
        songEndBaseVolumes.removeAll()
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
            track.peakLevelLeft = 0.0
            track.peakLevelRight = 0.0
            track.rawPeakL = 0.0
            track.rawPeakR = 0.0
            track.meter.reset()
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
        
        if let cachedWf = songWaveformCache[song.id], !cachedWf.peaks.isEmpty {
            masterWaveformPeaks = cachedWf.peaks
            refreshSoloWaveformIfNeeded(forceRecompute: true, triggerArrangementUpdate: false)
            updateArrangementWaveform()
        } else {
            recalculateAggregateWaveform(samplesCount: 4000)
        }
        
        updateSMPTEState(persistDevicePreset: false)
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
            } else if !currentSong.excludesClickAndGuide &&
                      currentSong.guideSource == .uploaded &&
                      uploadedGuideBuffers[song.id] != nil {
                applyGuideBuffer()
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
        if let restored = PlaybackFileManager.shared.lookupLocalLosslessSourceURL(for: track.id),
           isLosslessAudioURL(restored),
           FileManager.default.fileExists(atPath: restored.path) {
            return restored
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

    public func cancelTransposeTask(for songId: UUID) {
        transposeTasksBySong.removeValue(forKey: songId)?.cancel()
        transposeTaskTokensBySong.removeValue(forKey: songId)
        transposeProgressBySong.removeValue(forKey: songId)
        isTransposing = !transposeProgressBySong.isEmpty
        if let currentId = transposingSongId, transposeProgressBySong[currentId] != nil {
            transposeProgress = transposeProgressBySong[currentId] ?? 0.0
        } else {
            transposingSongId = transposeProgressBySong.keys.first
            transposeProgress = transposingSongId.flatMap { transposeProgressBySong[$0] } ?? 0.0
        }
        objectWillChange.send()
    }

    public func forceRerenderKeyAndTempo(forSongIndex targetIndex: Int? = nil) {
        let idx = targetIndex ?? currentSongIndex
        guard idx >= 0 && idx < currentSetlist.songs.count else { return }
        let song = currentSetlist.songs[idx]
        cancelTransposeTask(for: song.id)
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

    func areSongStemsHydratedForTransform(atIndex idx: Int) -> Bool {
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
                updateSMPTEState(persistDevicePreset: false)
            }
            syncActivePadToCurrentSongIfNeeded()
        } else if idx == currentSongIndex + 1 && bpmChanged {
            syncMixState()
        }
        markSessionChanged()
        
        // Fast path 1: Original key AND original tempo -> immediately revert to pristine stems
        if clampedSemitones == 0 && !isTempoShifted {
            cancelTransposeTask(for: targetSongId)
            transposeGeneration &+= 1
            songTransposedBuffersCache.removeValue(forKey: targetSongId)
            applyTransformedBuffers([:], forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
            return
        }

        guard areSongStemsHydratedForTransform(atIndex: idx) else {
            // Stems are still downloading or holding 1-frame Stage-1 placeholders; defer Rubber Band render until hydration finishes!
            songTransposedBuffersCache.removeValue(forKey: targetSongId)
            if bpmChanged {
                refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
                if idx == currentSongIndex {
                    updateSMPTEState(persistDevicePreset: false)
                }
                if idx == currentSongIndex || idx == currentSongIndex + 1 {
                    syncMixState()
                }
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
            cancelTransposeTask(for: targetSongId)
            transposeGeneration &+= 1
            applyTransformedBuffers(cached.buffers, forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
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
            cancelTransposeTask(for: targetSongId)
            transposeGeneration &+= 1
            songTransposedBuffersCache[targetSongId] = (clampedSemitones, newPreserveFormants, bpmHundredths, diskShifted)
            applyTransformedBuffers(diskShifted, forSongId: targetSongId, atIndex: idx, bpmChanged: bpmChanged)
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
            cancelTransposeTask(for: targetSongId)
            return
        }
        
        transposeTasksBySong[targetSongId]?.cancel()
        let taskToken = UUID()
        transposeTaskTokensBySong[targetSongId] = taskToken
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
        let task = Task.detached(priority: .userInitiated) { [weak self, sendableSnapshot, canonicalFormat, targetSongId, clampedSemitones, newPreserveFormants, targetBPM, origBPM, tempoScale, bpmHundredths, activeGeneration, taskToken, idx, forceRerender] in
            @Sendable func cleanupCancelledIfTokenMatches() async {
                await MainActor.run { [weak self] in
                    guard let self = self,
                          self.transposeTaskTokensBySong[targetSongId] == taskToken else { return }
                    self.cancelTransposeTask(for: targetSongId)
                }
            }

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
            
            let cancelledInGroup = await withTaskGroup(of: (UUID, SendablePCMBufferRef?, Bool).self, returning: Bool.self) { group in
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
                        return true
                    }
                    if let shiftedRef = shiftedRef {
                        rendered[trackId] = shiftedRef.buffer
                        if usedLossless { actualWavCount += 1 } else { actualM4aCount += 1 }
                    }
                    completedCount += 1
                    let currentProg = min(0.95, Float(completedCount) / Float(total))
                    
                    await MainActor.run { [weak self] in
                        guard let self = self,
                              self.transposeTaskTokensBySong[targetSongId] == taskToken else { return }
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
                return Task.isCancelled
            }
            
            if cancelledInGroup || Task.isCancelled {
                await cleanupCancelledIfTokenMatches()
                return
            }
            let finalRendered = rendered
            let finalSourceLabel: String = {
                if actualWavCount > 0 && actualM4aCount == 0 { return "WAV" }
                if actualWavCount > 0 && actualM4aCount > 0 { return "WAV + M4A" }
                return "M4A"
            }()
            
            let isValidRenderedSet = !finalRendered.isEmpty && finalRendered.values.allSatisfy { $0.frameLength > 100 }
            // Mark 100% complete
            await MainActor.run { [weak self] in
                guard let self = self,
                      self.transposeTaskTokensBySong[targetSongId] == taskToken else { return }
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
                guard let self = self,
                      self.transposeTaskTokensBySong[targetSongId] == taskToken else { return }
                self.transposeProgressBySong.removeValue(forKey: targetSongId)
                self.transposeTasksBySong.removeValue(forKey: targetSongId)
                self.transposeTaskTokensBySong.removeValue(forKey: targetSongId)
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
    
    func applyTransformedBuffers(_ rendered: [UUID: AVAudioPCMBuffer], forSongId targetSongId: UUID, atIndex idx: Int, bpmChanged: Bool) {
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
            if bpmChanged {
                updateSMPTEState(persistDevicePreset: false)
            }
            syncMixState()
        } else if bpmChanged {
            refreshGeneratedClickAndGuide(forSongId: targetSongId, atIndex: idx)
            if idx == currentSongIndex + 1 {
                syncMixState()
            }
        }
    }
    
    func refreshGeneratedClickAndGuide(forSongId songId: UUID, atIndex idx: Int) {
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
        for i in song.tempoEvents.indices {
            song.tempoEvents[i].audioTime *= scale
            if let endT = song.tempoEvents[i].endAudioTime {
                song.tempoEvents[i].endAudioTime = endT * scale
            }
            song.tempoEvents[i].targetBPM = max(20.0, min(300.0, song.tempoEvents[i].targetBPM / scale))
            for j in song.tempoEvents[i].customPoints.indices {
                song.tempoEvents[i].customPoints[j].bpm = max(20.0, min(300.0, song.tempoEvents[i].customPoints[j].bpm / scale))
            }
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
    
    nonisolated static func isClickTrack(_ track: StemTrack) -> Bool {
        return track.isClickTrackCached ||
            track.assignedBusName.lowercased() == "click"
    }

    nonisolated static func isGuideTrack(_ track: StemTrack) -> Bool {
        return track.isGuideTrackCached ||
            track.assignedBusName.lowercased() == "guide"
    }

    /// Synchronizes `generatedClickBuffers` / `generatedGuideBuffers` into `songBuffersCache[songId]`
    /// so non-active setlist songs never retain 1-frame stubs or silent placeholders when staged or promoted.
    func syncCachedClickAndGuideBuffers(forSongId songId: UUID) {
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
                    guard let sIdx = self.currentSetlist.songs.firstIndex(where: { $0.id == sid }) else { return false }
                    let s = self.currentSetlist.songs[sIdx]
                    guard !s.excludesClickAndGuide else { return false }
                    let expectedState = self.expectedDefaultGuideLoopState(forSongAt: sIdx, song: s)
                    let needC = s.clickSource == .generated && (self.generatedClickBuffers[sid]?.frameLength ?? 0) <= 1
                    let needG = s.guideSource == .generated &&
                        ((self.generatedGuideBuffers[sid]?.frameLength ?? 0) <= 1 || self.generatedGuideLoopStates[sid] != expectedState)
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
        guard let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == songId }) else { return }
        let song = currentSetlist.songs[songIdx]
        guard !song.excludesClickAndGuide else {
            completion?()
            return
        }
        let suppressEndCutoff = song.isContinueClickEffective(isLastSongInSetlist: songIdx >= currentSetlist.songs.count - 1)

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
        let earlyNextCue = resolvedNextSongSectionCue(forSongAt: songIdx, song: song, duration: songDurationForGuide(for: song))
        let earlyTargetGuideState = Self.defaultGuideLoopState(for: song, nextCue: earlyNextCue)
        let needsClick = song.clickSource == .generated && (force || (generatedClickBuffers[songId]?.frameLength ?? 0) <= 1)
        let needsGuide = song.guideSource == .generated && (force || (generatedGuideBuffers[songId]?.frameLength ?? 0) <= 1 || generatedGuideLoopStates[songId] != earlyTargetGuideState)

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
        let nextCue = resolvedNextSongSectionCue(forSongAt: songIdx, song: song, duration: duration)
        let targetGuideState = Self.defaultGuideLoopState(for: song, nextCue: nextCue)

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
        let guideSectionsVol = song.guideSectionsVolume
        let guideSectionsEnabled = song.guideSectionsEnabled
        let guideDirectionsVol = song.guideDirectionsVolume
        let guideDirectionsEnabled = song.guideDirectionsEnabled
        let guideFallbackVol = song.guideFallbackVolume
        let guideFallbackEnabled = song.guideFallbackEnabled
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
                suppressEndCutoff: suppressEndCutoff,
                format: canonicalFormat
            ) : nil

            let guideResult: (buffer: AVAudioPCMBuffer, meterEvents: [GuideCueMeterEvent])? = needsGuide ? guideGen.generateGuideBufferWithMeterEvents(
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
                nextSongFirstSection: nextCue?.section,
                nextSongCueTargetTime: nextCue?.targetTime,
                sectionsVolume: guideSectionsVol,
                sectionsEnabled: guideSectionsEnabled,
                directionsVolume: guideDirectionsVol,
                directionsEnabled: guideDirectionsEnabled,
                fallbackVolume: guideFallbackVol,
                fallbackEnabled: guideFallbackEnabled,
                soloedSubChannels: [],
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
                if let gRes = guideResult {
                    if songId == self.currentSong.id {
                        if self.currentLiveGuideLoopState() == targetGuideState {
                            self.generatedGuideBuffers[songId] = gRes.buffer
                            self.generatedGuideLoopStates[songId] = targetGuideState
                            self.guideCueMeterEvents[songId] = gRes.meterEvents
                        } else {
                            needsLiveActiveRegen = true
                        }
                    } else {
                        self.generatedGuideBuffers[songId] = gRes.buffer
                        self.generatedGuideLoopStates[songId] = targetGuideState
                        self.guideCueMeterEvents[songId] = gRes.meterEvents
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
        invalidateStaleNextSongSectionGuides()
        syncMixState()
        markSessionChanged()
    }
    
    @discardableResult
    func cancelAllSessionBackgroundTasks() -> Int {
        sessionHydrationTask?.cancel()
        sessionHydrationTask = nil
        sessionHydrationGeneration &+= 1

        preGenerateSetlistTask?.cancel()
        preGenerateSetlistTask = nil

        transposeTask?.cancel()
        transposeTask = nil
        transposeGeneration &+= 1
        transposeTasksBySong.values.forEach { $0.cancel() }
        transposeTasksBySong.removeAll()
        transposeTaskTokensBySong.removeAll()
        transposeProgressBySong.removeAll()
        downloadingSongProgress.removeAll()
        clearCancelledSongDownloads()
        isTransposing = false
        transposeProgress = 0.0
        transposingSongId = nil
        return sessionHydrationGeneration
    }

    public func removeSongFromSetlist(at index: Int) {
        guard index >= 0 && index < currentSetlist.songs.count else { return }
        let removedSong = currentSetlist.songs.remove(at: index)
        cancelTransposeTask(for: removedSong.id)
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
            updateSMPTEState(persistDevicePreset: false)
            syncMixState()
        } else {
            let nextIdx = min(currentSongIndex, currentSetlist.songs.count - 1)
            currentSongIndex = max(0, nextIdx)
            loadSong(currentSetlist.songs[currentSongIndex])
            invalidateStaleNextSongSectionGuides()
        }
        markSessionChanged()
    }
    
    public func newSession(
        name: String = "New Setlist",
        date: Date = Date(),
        serviceType: String? = nil,
        serviceTime: String? = nil
    ) {
        _ = cancelAllSessionBackgroundTasks()
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
        updateSMPTEState(persistDevicePreset: false)
        syncMixState()
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
        updateSMPTEState(persistDevicePreset: false)
        syncMixState()
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
        invalidateStaleNextSongSectionGuides()
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
            fadeEndSectionEnabled: false,
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
    
    func tracksForSavingSong(_ song: Song, rawTracks: [StemTrack]) -> [StemTrack] {
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
            s.continueClick = ov.continueClick
            s.cueNextSongSection = ov.cueNextSongSection
            s.endFadeOutEnabled = ov.endFadeOutEnabled
            s.fadeEndSectionEnabled = ov.fadeEndSectionEnabled
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
                do {
                    try PlaybackFileManager.shared.extractFullArchiveForHydration(
                        archiveURL: fast.sourceURL,
                        toFolderURL: fast.rootFolder
                    )
                } catch {
                    PeanutButterLog.storage.error("Failed extracting song package \(fast.sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
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

    func sharedBuffersForDuplicatingSong(_ existingSong: Song) -> [(StemTrack, AVAudioPCMBuffer)]? {
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
                    _ = acknowledgedCloudRevisionIds.insert(revId)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.acknowledgedCloudRevisionIds.insert(revId)
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
                    do {
                        try PlaybackFileManager.shared.exportSession(
                            setlist: currentSetlist,
                            currentSongIndex: currentSongIndex,
                            allSongsData: allSongsData,
                            transposedBuffersMap: songTransposedBuffersCache.mapValues { ($0.semitones, $0.buffers) },
                            to: autoSaveSessionURL,
                            asDirectoryPackage: true,
                            associatedSessionPath: url.path,
                            revisionId: effectiveRevisionId
                        )
                    } catch {
                        PeanutButterLog.storage.error("Failed syncing AutoSave mirror session: \(error.localizedDescription, privacy: .public)")
                    }
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
                _ = acknowledgedCloudRevisionIds.insert(revId)
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
                do {
                    try PlaybackFileManager.shared.exportSession(
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
                } catch {
                    PeanutButterLog.storage.error("Failed syncing AutoSave mirror session: \(error.localizedDescription, privacy: .public)")
                }
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
        acknowledgedCloudRevisionIds.insert(sharedRevisionId)

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
                self.clearSaveAndCloudUpdateIndicators(revisionId: sharedRevisionId, targetURLs: allTargets)
                library.refreshSetlists()
            } catch {
                self.hasUnsavedChanges = true
                PeanutButterLog.storage.error("Quick save failed: \(error.localizedDescription, privacy: .public)")
                self.showAudioDeviceBanner("Save failed: \(error.localizedDescription)")
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
        let generation = cancelAllSessionBackgroundTasks()
        
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
    
    func applyHydratedSessionMetadata(
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
            updateSMPTEState(persistDevicePreset: false)
            syncMixState()
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
                do {
                    try PlaybackFileManager.shared.extractFullArchiveForHydration(
                        archiveURL: hydrated.sourceURL,
                        toFolderURL: hydrated.metadataRootFolder
                    )
                } catch {
                    PeanutButterLog.storage.error("Failed extracting session archive \(hydrated.sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
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
                                let songIdx = hydrated.songEntries.firstIndex(where: { $0.id == entry.id }) ?? 0
                                let res = PlaybackFileManager.shared.decodeSongEntryAudio(
                                    songEntry: entry,
                                    songIndex: songIdx,
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
    
    func applyHydratedSongAudioBuffers(
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
                    let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == songId })
                    let expectedState = isActiveSong
                        ? currentLiveGuideLoopState()
                        : expectedDefaultGuideLoopState(forSongAt: songIdx ?? -1, song: song)
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
        do {
            try saveSession(
                to: autoSaveSessionURL,
                recordAsLastSession: false,
                asDirectoryPackage: true,
                associatedSessionPath: lastPath
            )
        } catch {
            PeanutButterLog.storage.error("Auto-save failed: \(error.localizedDescription, privacy: .public)")
            showAudioDeviceBanner("Auto-save failed: \(error.localizedDescription)")
        }
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
        
        let generation = cancelAllSessionBackgroundTasks()
        memoryEvictedSongIds.removeAll()
        songTrackMetadataBackup.removeAll()
        
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
                PeanutButterLog.storage.error("Fast session metadata restore from \(candidate.url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    /// Commits tempo, time signature, and optional metadata/sections from the Song Builder
    /// onto the active song & setlist, rebuilding the beat grid, Click, Guide, and section layout
    /// while remaining open in the Song Builder.
    public func applySongBuilderTempoAndGrid(
        bpm: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int,
        title: String? = nil,
        artist: String? = nil,
        musicalKey: String? = nil,
        artworkData: Data? = nil,
        sections: [SongSection]? = nil,
        isCreatingNewSong: Bool = false,
        preserveExistingSectionTimings: Bool? = nil
    ) {
        let safeBPM = max(20.0, min(300.0, (bpm * 100.0).rounded() / 100.0))
        let safeNum = max(1, min(16, timeSignatureNumerator))
        let safeDen = [2, 4, 8, 16].contains(timeSignatureDenominator) ? timeSignatureDenominator : 4

        let bpmChanged = abs(safeBPM - currentSong.bpm) > 0.005
        let timeSigChanged = (safeNum != currentSong.timeSignatureNumerator || safeDen != currentSong.timeSignatureDenominator)
        let wasTempoShifted = currentSong.isTempoShifted
        let hasAudioStems = tracks.contains { $0.role == .stem }
        let shouldPreserveTimings = preserveExistingSectionTimings ?? (!isCreatingNewSong && hasAudioStems)

        if bpmChanged || timeSigChanged {
            currentSong.beatGrid.removeAll()
        }

        currentSong.bpm = safeBPM
        if isCreatingNewSong || !wasTempoShifted {
            currentSong.originalBPM = safeBPM
        }
        currentSong.timeSignatureNumerator = safeNum
        currentSong.timeSignatureDenominator = safeDen

        if let title {
            currentSong.title = title
        }
        if let artist {
            currentSong.artist = artist
        }
        if let musicalKey {
            currentSong.musicalKey = musicalKey
        }
        if let artworkData {
            currentSong.artworkData = artworkData
        }

        let targetSections = sections ?? currentSong.sections
        if !targetSections.isEmpty && (sections != nil || bpmChanged || timeSigChanged) {
            let secPerBeat = (60.0 / safeBPM) * (4.0 / Double(safeDen))
            let secPerMeasure = secPerBeat * Double(safeNum)

            if shouldPreserveTimings {
                let sectionListChanged: Bool = {
                    guard let provided = sections else { return false }
                    guard provided.count == currentSong.sections.count else { return true }
                    for (a, b) in zip(provided, currentSong.sections) {
                        if a.id != b.id || a.name != b.name || abs(a.duration - b.duration) > 0.05 {
                            return true
                        }
                    }
                    return false
                }()

                if sectionListChanged {
                    var curTime: TimeInterval = 0.0
                    var updated: [SongSection] = []
                    updated.reserveCapacity(targetSections.count)
                    for var sec in targetSections {
                        let secDur = sec.duration > 0.05 ? sec.duration : (Double(max(1, sec.measureCount)) * secPerMeasure)
                        sec.startTime = curTime
                        sec.duration = secDur
                        if !sec.isTrimmed && sec.audioStartTime == nil {
                            sec.audioStartTime = curTime
                            sec.originalAudioStartTime = curTime
                            sec.originalDuration = secDur
                        }
                        updated.append(sec)
                        curTime += secDur
                    }
                    currentSong.sections = updated
                    if currentSong.activeArrangementId == nil {
                        currentSong.defaultSections = updated
                    }
                }
                currentSong.reconcileSectionMeasuresWithBeatGrid()
            } else {
                let srcGrid = currentSong.sourceBeatGrid()
                let downbeats = srcGrid.filter { $0.isDownbeat }

                var curTime: TimeInterval = 0.0
                var curMeasure = 1
                var recalculated: [SongSection] = []
                recalculated.reserveCapacity(targetSections.count)

                for var sec in targetSections {
                    let dur: TimeInterval
                    if !downbeats.isEmpty && curMeasure - 1 < downbeats.count {
                        let startIdx = curMeasure - 1
                        let endIdx = startIdx + sec.measureCount
                        if endIdx < downbeats.count {
                            dur = max(secPerBeat, downbeats[endIdx].time - downbeats[startIdx].time)
                        } else {
                            let tailBPM = downbeats[startIdx].instantaneousBPM > 20.0 ? downbeats[startIdx].instantaneousBPM : safeBPM
                            let tailBarDur = (60.0 / tailBPM) * (4.0 / Double(safeDen)) * Double(safeNum)
                            dur = Double(sec.measureCount) * tailBarDur
                        }
                    } else {
                        dur = Double(sec.measureCount) * secPerMeasure
                    }
                    sec.startTime = curTime
                    sec.duration = dur
                    sec.startMeasure = curMeasure
                    if !sec.isTrimmed {
                        sec.audioStartTime = curTime
                        sec.originalAudioStartTime = curTime
                        sec.originalDuration = dur
                    }
                    recalculated.append(sec)
                    curTime += dur
                    curMeasure += sec.measureCount
                }

                currentSong.sections = recalculated
                currentSong.defaultSections = recalculated
            }
        }

        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex] = currentSong
        }

        transportPosition.currentBPM = safeBPM
        transportClock.position.currentBPM = safeBPM
        transportDisplayClock.update(with: transportPosition)

        if !currentSong.excludesClickAndGuide {
            if uploadedClickBuffers[currentSong.id] == nil {
                currentSong.clickSource = .generated
            }
            if uploadedGuideBuffers[currentSong.id] == nil {
                currentSong.guideSource = .generated
            }
            if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
                currentSetlist.songs[currentSongIndex].clickSource = currentSong.clickSource
                currentSetlist.songs[currentSongIndex].guideSource = currentSong.guideSource
            }
        }

        syncActivePadToCurrentSongIfNeeded()
        rebuildPrecomputedBeatGrid()
        reindexArrangement()
        if !tracks.isEmpty {
            ensureClickAndGuideTracksExist()
        }
        updateSMPTEState(persistDevicePreset: false)
        if isPostSongClickActive {
            activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
        }
        if !isMIDIMuted {
            MIDICueEngine.shared.updateMIDIClockTempo(safeBPM)
        }
        markSessionChanged()
        objectWillChange.send()
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
        updateSMPTEState(persistDevicePreset: false)
        if isPostSongClickActive {
            activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
        }
        updateArrangementWaveform()
        markSessionChanged()
        objectWillChange.send()
    }
    
    
}
