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
    /// True when editing sections or arrangement (drawer open to Setlist/Song Map or Song Sections, or in Trim mode)
    public var isEditingArrangement: Bool {
        return (isEditDrawerOpen && (selectedEditDrawerItem == .setlistSongMap || selectedEditDrawerItem == .songSections)) ||
            isEditSectionsMode || isEditSongMapMode || trimmingSection != nil
    }
    
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
        if let sCue = song.smpteCue,
           (rebindByCurrentTime || sCue.sectionId == nil || !validIds.contains(sCue.sectionId!)) {
            let t = sCue.time
            if let sec = song.sections.first(where: { t >= $0.startTime - 0.005 && t < $0.endTime - 0.005 }) ?? song.sections.last(where: { t >= $0.startTime - 0.005 }) {
                song.smpteCue?.sectionId = sec.id
            }
        }
    }
    
    /// Captures the Default arrangement's baseline sections and cues right before Default's section map is altered
    func snapshotDefaultBaselineIfUnmodified() {
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
        let hasDynamicGrid = !currentSong.beatGrid.isEmpty || !currentSong.timeSignatureChanges.isEmpty || !currentSong.tempoEvents.isEmpty
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
                if var sCue = currentSong.smpteCue, sCue.sectionId == secId {
                    sCue.time = max(0.0, sCue.time + shiftDelta)
                    currentSong.smpteCue = sCue
                    if currentSong.activeArrangementId == nil && currentSong.isCurrentSectionsMatchingDefault {
                        currentSong.defaultSmpteCue = sCue
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
            currentSetlist.songs[currentSongIndex].smpteCue = currentSong.smpteCue
            currentSetlist.songs[currentSongIndex].defaultSmpteCue = currentSong.defaultSmpteCue
        }
        updateSMPTEState(persistDevicePreset: false)
        
        updateArrangementWaveform()
        syncMixState()
        if currentSongIndex > 0, currentSetlist.songs.indices.contains(currentSongIndex - 1), currentSetlist.songs[currentSongIndex - 1].cueNextSongSection {
            invalidateStaleNextSongSectionGuides()
        }
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
        
        let prev = currentSong.sections[index - 1]
        let removed = currentSong.sections[index]
        let prevId = prev.id
        let mergedDuration = prev.duration + removed.duration
        let mergedTrailingTrim = removed.trailingTrimDuration
        let mergedBaseDuration = mergedDuration + prev.leadingTrimDuration + mergedTrailingTrim
        
        currentSong.sections[index - 1].duration = mergedDuration
        currentSong.sections[index - 1].originalDuration = mergedBaseDuration
        currentSong.sections[index - 1].measureCount += removed.measureCount
        currentSong.sections[index - 1].trailingTrimDuration = mergedTrailingTrim
        
        for i in 0..<currentSong.midiCues.count where currentSong.midiCues[i].sectionId == removed.id {
            currentSong.midiCues[i].sectionId = prevId
        }
        for i in 0..<currentSong.directionalCues.count where currentSong.directionalCues[i].sectionId == removed.id {
            currentSong.directionalCues[i].sectionId = prevId
        }
        for i in 0..<currentSong.automationPoints.count where currentSong.automationPoints[i].sectionId == removed.id {
            currentSong.automationPoints[i].sectionId = prevId
        }
        if var smpte = currentSong.smpteCue, smpte.sectionId == removed.id {
            smpte.sectionId = prevId
            currentSong.smpteCue = smpte
        }
        
        let wasLoopedOnMerged = (loopedSection?.id == removed.id || loopedSection?.id == prevId)
        currentSong.sections.remove(at: index)
        
        reindexArrangement()
        if wasLoopedOnMerged {
            loopedSection = currentSong.sections.first(where: { $0.id == prevId })
        }
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
    func copyCues(from sourceSection: SongSection, to targetSection: SongSection) {
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
    
    func syncTimeSignatureChangesToSetlist() {
        currentSong.reconcileSectionMeasuresWithBeatGrid()
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].timeSignatureChanges = currentSong.timeSignatureChanges
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
            currentSetlist.songs[currentSongIndex].defaultSections = currentSong.defaultSections
            currentSetlist.songs[currentSongIndex].savedArrangements = currentSong.savedArrangements
        }
        rebuildPrecomputedBeatGrid()
        updateTransportPosition(to: playbackOffsetSeconds)
        regenerateClickTrack()
        regenerateGuideTrack()
        markSessionChanged()
        objectWillChange.send()
    }

    // MARK: - Mid-Song Tempo Changes & DAW Curve Automation (Phase 5.7)

    public func openTempoCurveEditor() {
        isEditDrawerOpen = true
        selectEditDrawerItem(.songSections)
        isEditingTempoCurve = true
    }

    public func setTempoCurveEditing(_ enabled: Bool) {
        isEditingTempoCurve = enabled
    }

    public func addInstantTempoChange(atDisplayTime displayTime: TimeInterval, bpm: Double, snap: Bool = true) {
        let targetDisp = snap ? snapTimeToBeatGrid(displayTime) : max(0.0, displayTime)
        let sourceTime = max(0.0, audioTime(forArrangementTime: targetDisp))
        let clampedBPM = max(20.0, min(300.0, bpm))

        currentSong.tempoEvents.removeAll { abs($0.audioTime - sourceTime) < 0.05 }
        currentSong.tempoEvents.append(
            TempoChangeEvent(
                audioTime: sourceTime,
                targetBPM: clampedBPM,
                isRamp: false
            )
        )
        currentSong.tempoEvents.sort { $0.audioTime < $1.audioTime }
        syncTempoEventsToSetlist(commit: true)
    }

    public func addTempoRamp(
        atDisplayTime displayTime: TimeInterval,
        targetBPM: Double,
        spanMode: TempoRampSpanMode = .barsBeats,
        rampBeats: Double? = nil,
        endDisplayTime: TimeInterval? = nil,
        lockBeatCount: Bool = true,
        curve: TempoCurveType = .linear,
        curveTension: Double = 0.0,
        customPoints: [TempoCurvePoint] = [],
        snap: Bool = true
    ) {
        let targetStartDisp = snap ? snapTimeToBeatGrid(displayTime) : max(0.0, displayTime)
        let startSrc = max(0.0, audioTime(forArrangementTime: targetStartDisp))
        let activeTS = currentSong.timeSignature(atSourceTime: startSrc)
        let resolvedBeats = max(0.25, rampBeats ?? Double(max(1, activeTS.numerator) * 2))

        let endSrc: TimeInterval? = {
            guard spanMode == .audioAnchor || curve == .custom else { return nil }
            if let explicitEndDisp = endDisplayTime {
                let targetEndDisp = snap ? snapTimeToBeatGrid(explicitEndDisp) : explicitEndDisp
                return max(startSrc + 0.1, audioTime(forArrangementTime: targetEndDisp))
            }
            let approxBPM = max(20.0, min(300.0, (currentSong.evaluateBPM(atSourceTime: startSrc) + targetBPM) * 0.5))
            let beatDur = (60.0 / approxBPM) * (4.0 / Double(max(1, activeTS.denominator)))
            return startSrc + max(0.25, resolvedBeats * beatDur)
        }()

        let resolvedSpanMode: TempoRampSpanMode = (curve == .custom) ? .audioAnchor : spanMode
        currentSong.tempoEvents.removeAll { abs($0.audioTime - startSrc) < 0.05 }
        currentSong.tempoEvents.append(
            TempoChangeEvent(
                audioTime: startSrc,
                targetBPM: max(20.0, min(300.0, targetBPM)),
                isRamp: true,
                endAudioTime: endSrc,
                spanMode: resolvedSpanMode,
                rampBeats: resolvedBeats,
                lockBeatCountToAudioEnd: (curve == .custom) ? false : lockBeatCount,
                curve: curve,
                curveTension: curveTension,
                customPoints: customPoints
            )
        )
        currentSong.tempoEvents.sort { $0.audioTime < $1.audioTime }
        syncTempoEventsToSetlist(commit: true)
    }

    public func updateTempoChangeEvent(_ event: TempoChangeEvent, commit: Bool = true) {
        guard let idx = currentSong.tempoEvents.firstIndex(where: { $0.id == event.id }) else { return }
        var normalized = event
        normalized.audioTime = max(0.0, normalized.audioTime)
        normalized.targetBPM = max(20.0, min(300.0, normalized.targetBPM))
        if let endT = normalized.endAudioTime {
            normalized.endAudioTime = max(normalized.audioTime + 0.05, endT)
        }
        normalized.customPoints = normalized.customPoints.sorted { $0.normalizedTime < $1.normalizedTime }
        currentSong.tempoEvents[idx] = normalized
        currentSong.tempoEvents.sort { $0.audioTime < $1.audioTime }
        syncTempoEventsToSetlist(commit: commit)
    }

    public func removeTempoChangeEvent(id: UUID) {
        currentSong.tempoEvents.removeAll { $0.id == id }
        syncTempoEventsToSetlist(commit: true)
    }

    public func clearAllTempoEvents() {
        guard !currentSong.tempoEvents.isEmpty else { return }
        currentSong.tempoEvents.removeAll()
        syncTempoEventsToSetlist(commit: true)
    }

    /// Converts a drawn stroke of `(displayTime, bpm)` samples into a clean custom `.audioAnchor` tempo event.
    public func applyDrawnTempoStroke(points: [(displayTime: TimeInterval, bpm: Double)]) {
        guard points.count >= 2 else { return }
        var sourceSamples: [(time: TimeInterval, bpm: Double)] = []
        sourceSamples.reserveCapacity(points.count)
        let converted = points
            .map { (time: max(0.0, audioTime(forArrangementTime: $0.displayTime)), bpm: max(20.0, min(300.0, $0.bpm))) }
            .sorted { $0.time < $1.time }

        for sample in converted {
            if let last = sourceSamples.last, abs(sample.time - last.time) < 0.015 {
                sourceSamples[sourceSamples.count - 1].bpm = sample.bpm
            } else {
                sourceSamples.append(sample)
            }
        }
        guard sourceSamples.count >= 2,
              let firstSample = sourceSamples.first,
              let lastSample = sourceSamples.last,
              (lastSample.time - firstSample.time) >= 0.1 else {
            return
        }

        let startSrc = firstSample.time
        let endSrc = lastSample.time
        let spanDur = max(0.1, endSrc - startSrc)
        let minBPMVal = sourceSamples.map(\.bpm).min() ?? firstSample.bpm
        let maxBPMVal = sourceSamples.map(\.bpm).max() ?? lastSample.bpm
        let bpmSpan = max(20.0, maxBPMVal - minBPMVal)

        let normPoints: [(x: Double, y: Double, time: TimeInterval, bpm: Double)] = sourceSamples.map {
            (
                x: ($0.time - startSrc) / spanDur,
                y: ($0.bpm - minBPMVal) / bpmSpan,
                time: $0.time,
                bpm: $0.bpm
            )
        }

        func perpendicularDistance(
            _ pt: (x: Double, y: Double, time: TimeInterval, bpm: Double),
            from start: (x: Double, y: Double, time: TimeInterval, bpm: Double),
            to end: (x: Double, y: Double, time: TimeInterval, bpm: Double)
        ) -> Double {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let mag = hypot(dx, dy)
            if mag < 1e-9 { return hypot(pt.x - start.x, pt.y - start.y) }
            return abs(dy * pt.x - dx * pt.y + end.x * start.y - end.y * start.x) / mag
        }

        func simplifyRDP(_ slice: ArraySlice<(x: Double, y: Double, time: TimeInterval, bpm: Double)>, epsilon: Double) -> [(x: Double, y: Double, time: TimeInterval, bpm: Double)] {
            guard slice.count > 2, let first = slice.first, let last = slice.last else {
                return Array(slice)
            }
            var maxDist = 0.0
            var splitIdx = slice.startIndex
            for i in (slice.startIndex + 1)..<(slice.endIndex - 1) {
                let d = perpendicularDistance(slice[i], from: first, to: last)
                if d > maxDist {
                    maxDist = d
                    splitIdx = i
                }
            }
            if maxDist > epsilon {
                let left = simplifyRDP(slice[slice.startIndex...splitIdx], epsilon: epsilon)
                let right = simplifyRDP(slice[splitIdx..<slice.endIndex], epsilon: epsilon)
                return Array(left.dropLast()) + right
            } else {
                return [first, last]
            }
        }

        let simplified = simplifyRDP(ArraySlice(normPoints), epsilon: 0.028)
        let baseStartBPM = currentSong.evaluateBPM(atSourceTime: max(0.0, startSrc - 0.01))

        var interiorPoints: [TempoCurvePoint] = []
        if abs(firstSample.bpm - baseStartBPM) >= 1.5 {
            interiorPoints.append(TempoCurvePoint(normalizedTime: 0.001, bpm: firstSample.bpm))
        }
        if simplified.count > 2 {
            for idx in 1..<(simplified.count - 1) {
                let pt = simplified[idx]
                let normT = max(0.005, min(0.995, pt.x))
                interiorPoints.append(TempoCurvePoint(normalizedTime: normT, bpm: pt.bpm))
            }
        }

        currentSong.tempoEvents.removeAll { $0.audioTime >= startSrc - 0.05 && $0.audioTime <= endSrc + 0.05 }
        currentSong.tempoEvents.append(
            TempoChangeEvent(
                audioTime: startSrc,
                targetBPM: lastSample.bpm,
                isRamp: true,
                endAudioTime: endSrc,
                spanMode: .audioAnchor,
                lockBeatCountToAudioEnd: false,
                curve: .custom,
                curveTension: 0.0,
                customPoints: interiorPoints
            )
        )
        currentSong.tempoEvents.sort { $0.audioTime < $1.audioTime }
        syncTempoEventsToSetlist(commit: true)
    }

    func syncTempoEventsToSetlist(commit: Bool = true) {
        currentSong.reconcileSectionMeasuresWithBeatGrid()
        if currentSongIndex >= 0 && currentSongIndex < currentSetlist.songs.count {
            currentSetlist.songs[currentSongIndex].tempoEvents = currentSong.tempoEvents
            currentSetlist.songs[currentSongIndex].sections = currentSong.sections
            currentSetlist.songs[currentSongIndex].defaultSections = currentSong.defaultSections
            currentSetlist.songs[currentSongIndex].savedArrangements = currentSong.savedArrangements
        }
        rebuildPrecomputedBeatGrid()
        updateTransportPosition(to: playbackOffsetSeconds)
        if commit {
            regenerateClickTrack()
            regenerateGuideTrack()
            markSessionChanged()
        }
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
    func projectCuesOntoSections(
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
            updateSMPTEState(persistDevicePreset: false)
            syncMixState()
            if playbackOffsetSeconds > currentSongDuration {
                seek(to: 0.0)
            }
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = (idx == currentSongIndex) ? currentSong : song
            if idx == currentSongIndex + 1 {
                syncMixState()
            }
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
            updateSMPTEState(persistDevicePreset: false)
            syncMixState()
            if playbackOffsetSeconds > currentSongDuration {
                seek(to: 0.0)
            }
        }
        if idx >= 0 && idx < currentSetlist.songs.count {
            currentSetlist.songs[idx] = (idx == currentSongIndex) ? currentSong : song
            if idx == currentSongIndex + 1 {
                syncMixState()
            }
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
                self.updateSMPTEState(persistDevicePreset: false)
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
    
    
}
