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
    
    // MARK: - MIDI Cues Management
    
    func syncCurrentSongMIDICuesToSetlist() {
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
    func resolveSongLibraryPackageURL(for song: Song) -> (url: URL, isCloud: Bool)? {
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
    
    func syncCurrentSongDirectionalCuesToSetlist() {
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
    
    func applyAutomatedPadInstantTargets(for point: AutomationPoint, applyZeroBeatFaders: Bool) {
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
    
    func syncCurrentSongAutomationToSetlist() {
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
    
    func deduplicateUtilityTracks(inCurrentSong: Bool, check: (StemTrack) -> Bool) {
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

    func makeSilentStub(format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
        } else if isPostSongClickActive {
            activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
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
        
        let suppressEndCutoff = currentSong.isContinueClickEffective(isLastSongInSetlist: currentSongIndex >= currentSetlist.songs.count - 1)
        isGeneratingClick = true
        updateGenerationStatus()
        objectWillChange.send()
        if isPostSongClickActive {
            activateOrRefreshPostSongClick(mode: postSongClickOriginMode, preserveRunningPhase: true)
        }
        
        Task {
            let genBuf = await Task.detached(priority: .userInitiated) { [currentSong = self.currentSong, canonicalFormat, durationToUse, subdivisions = self.clickSoloedSubdivisions, suppressEndCutoff] in
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
                    suppressEndCutoff: suppressEndCutoff,
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
    
}
