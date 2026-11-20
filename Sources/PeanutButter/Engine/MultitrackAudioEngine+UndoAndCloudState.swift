import Foundation
import AVFoundation
import Combine
import CoreAudio
import Accelerate
import AppKit
import QuartzCore
import SwiftUI
import os

final class WeakUndoBufferPair {
    weak var pristineBuffer: AVAudioPCMBuffer?
    weak var activeBuffer: AVAudioPCMBuffer?

    init(pristine: AVAudioPCMBuffer?, active: AVAudioPCMBuffer?) {
        self.pristineBuffer = pristine
        self.activeBuffer = active
    }
}

struct TrackUndoSnapshot: Equatable {
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
    let weakBuffers: WeakUndoBufferPair
    let cachedStemURL: URL?
    let songId: UUID
    let transposeSemitones: Int
    let bpm: Double
    let originalBPM: Double
    let preserveVocalFormants: Bool

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
            lhs.duration == rhs.duration &&
            lhs.songId == rhs.songId &&
            lhs.transposeSemitones == rhs.transposeSemitones &&
            lhs.bpm == rhs.bpm &&
            lhs.originalBPM == rhs.originalBPM &&
            lhs.preserveVocalFormants == rhs.preserveVocalFormants
    }
}

struct BusUndoSnapshot: Equatable {
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

struct SessionUndoSnapshot: Equatable {
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


@MainActor
extension MultitrackAudioEngine {
    func retainInUndoOrphanLRU(trackId: UUID, buffer: AVAudioPCMBuffer?) {
        guard let buffer = buffer, buffer.frameLength > 100 else { return }
        undoRecentOrphanBuffers.removeAll { $0.trackId == trackId }
        undoRecentOrphanBuffers.append((trackId: trackId, buffer: buffer))
        if undoRecentOrphanBuffers.count > 28 {
            undoRecentOrphanBuffers.removeFirst(undoRecentOrphanBuffers.count - 28)
        }
    }

    func resolveUndoTrackBuffers(for snap: TrackUndoSnapshot) -> (pristine: AVAudioPCMBuffer?, active: AVAudioPCMBuffer?) {
        let canonicalFormat = getCanonicalProcessingFormat()
        var pristine = snap.weakBuffers.pristineBuffer
            ?? pristineMasterBuffers[snap.id]
            ?? undoRecentOrphanBuffers.first(where: { $0.trackId == snap.id })?.buffer

        if pristine == nil {
            let candidateURLs: [URL] = [
                snap.cachedStemURL,
                PlaybackFileManager.shared.hasValidCachedStem(for: snap.id) ? PlaybackFileManager.shared.cachedStemURL(for: snap.id) : nil,
                snap.fileURL,
                snap.sourceFileURL
            ].compactMap { $0 }

            for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
                if let loaded = try? PlaybackFileManager.shared.readPCMBuffer(from: url),
                   loaded.frameLength > 10 {
                    pristine = normalizeBufferToCanonical(buffer: loaded, targetFormat: canonicalFormat)
                    break
                }
            }
        }

        let isTransformed = snap.transposeSemitones != 0 || abs(snap.bpm - snap.originalBPM) > 0.005
        var active = snap.weakBuffers.activeBuffer
        if !isTransformed {
            active = pristine ?? active
        } else if active == nil {
            let transDir = PlaybackFileManager.shared.transposedStemCacheDirectory(
                songId: snap.songId,
                semitones: snap.transposeSemitones,
                preserveVocalFormants: snap.preserveVocalFormants,
                bpm: snap.bpm,
                originalBPM: snap.originalBPM
            )
            for ext in ["wav", "m4a"] {
                let transURL = transDir.appendingPathComponent("\(snap.id.uuidString).\(ext)")
                if FileManager.default.fileExists(atPath: transURL.path),
                   let loaded = try? PlaybackFileManager.shared.readPCMBuffer(from: transURL),
                   loaded.frameLength > 10 {
                    active = normalizeBufferToCanonical(buffer: loaded, targetFormat: canonicalFormat)
                    break
                }
            }
            if active == nil {
                active = pristine
            }
        }

        return (pristine, active)
    }

    func captureCurrentUndoSnapshot() -> SessionUndoSnapshot {
        let trackSnaps: [TrackUndoSnapshot] = tracks.map { track in
            let ch = channels[track.id]
            let pBuf = pristineMasterBuffers[track.id] ?? ch?.buffer
            let aBuf = ch?.buffer ?? pristineMasterBuffers[track.id]
            let cachedURL = PlaybackFileManager.shared.hasValidCachedStem(for: track.id)
                ? PlaybackFileManager.shared.cachedStemURL(for: track.id)
                : nil
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
                weakBuffers: WeakUndoBufferPair(pristine: pBuf, active: aBuf),
                cachedStemURL: cachedURL,
                songId: currentSong.id,
                transposeSemitones: currentSong.transposeSemitones,
                bpm: currentSong.bpm,
                originalBPM: currentSong.originalBPM,
                preserveVocalFormants: currentSong.preserveVocalFormants
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
        undoRecentOrphanBuffers.removeAll()
        baselineUndoSnapshot = captureCurrentUndoSnapshot()
        lastUndoCommitTime = 0
        canUndo = false
        canRedo = false
    }

    func recordUndoCheckpointIfNeeded() {
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

    func applyUndoSnapshot(_ snapshot: SessionUndoSnapshot) {
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
                    let resolved = resolveUndoTrackBuffers(for: snap)
                    guard let buf = resolved.pristine ?? resolved.active else { return nil }
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
            if !PlaybackFileManager.shared.hasValidCachedStem(for: key) {
                retainInUndoOrphanLRU(trackId: key, buffer: pristineMasterBuffers[key] ?? channels[key]?.buffer)
            }
            pristineMasterBuffers.removeValue(forKey: key)
        }
        for key in Array(channels.keys) where !targetIdSet.contains(key) {
            if !PlaybackFileManager.shared.hasValidCachedStem(for: key) {
                retainInUndoOrphanLRU(trackId: key, buffer: channels[key]?.buffer)
            }
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

            let resolved = resolveUndoTrackBuffers(for: ts)
            if let pBuf = resolved.pristine {
                pristineMasterBuffers[ts.id] = pBuf
            }
            let buf = resolved.active ?? resolved.pristine
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
                snapshot.tracks.contains(where: { $0.role == .click && channels[$0.id]?.buffer == nil }) ||
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
                prevSong.tempoEvents != currentSong.tempoEvents ||
                prevSong.sections != currentSong.sections ||
                prevSong.beatGrid != currentSong.beatGrid

            let guideNeedsRefresh =
                snapshot.tracks.contains(where: { $0.role == .guide && channels[$0.id]?.buffer == nil }) ||
                prevSong.guideSource != currentSong.guideSource ||
                prevSong.guideVoice != currentSong.guideVoice ||
                prevSong.guideFallbackVoice != currentSong.guideFallbackVoice ||
                prevSong.guideCountInEnabled != currentSong.guideCountInEnabled ||
                prevSong.speakDirectionalCuesOnUploadedGuide != currentSong.speakDirectionalCuesOnUploadedGuide ||
                prevSong.guideSectionsVolume != currentSong.guideSectionsVolume ||
                prevSong.guideSectionsEnabled != currentSong.guideSectionsEnabled ||
                prevSong.guideDirectionsVolume != currentSong.guideDirectionsVolume ||
                prevSong.guideDirectionsEnabled != currentSong.guideDirectionsEnabled ||
                prevSong.guideFallbackVolume != currentSong.guideFallbackVolume ||
                prevSong.guideFallbackEnabled != currentSong.guideFallbackEnabled ||
                prevSong.bpm != currentSong.bpm ||
                prevSong.timeSignatureNumerator != currentSong.timeSignatureNumerator ||
                prevSong.timeSignatureDenominator != currentSong.timeSignatureDenominator ||
                prevSong.timeSignatureChanges != currentSong.timeSignatureChanges ||
                prevSong.tempoEvents != currentSong.tempoEvents ||
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
        updateSMPTEState(persistDevicePreset: false)
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
    
    nonisolated static func isLikelyUUIDString(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    func recordTrackMetadataBackup(for songId: UUID, tracks: [StemTrack]) {
        let nonUUIDTracks = tracks.filter { !Self.isLikelyUUIDString($0.name) }
        guard !nonUUIDTracks.isEmpty else { return }
        songTrackMetadataBackup[songId] = nonUUIDTracks
    }

    static func hasLocalBackingAudioFile(for track: StemTrack) -> Bool {
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

    func resolveLocalBackingURL(for track: StemTrack) -> URL? {
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

    func rehydrateEvictedSongBuffersIfNeeded(for song: Song) {
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
                        let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == song.id })
                        let expectedState = isActiveSong
                            ? currentLiveGuideLoopState()
                            : expectedDefaultGuideLoopState(forSongAt: songIdx ?? -1, song: song)
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
                let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == song.id })
                let expectedState = isActiveSong
                    ? currentLiveGuideLoopState()
                    : expectedDefaultGuideLoopState(forSongAt: songIdx ?? -1, song: song)
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
        if hasAllRequiredAudioHydrated(in: rehydrated) {
            memoryEvictedSongIds.remove(song.id)
        }
    }

    func reconstructTracksFromStemURLs(for song: Song, canonicalFormat: AVAudioFormat) -> [(track: StemTrack, buffer: AVAudioPCMBuffer)] {
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
                let restoredSourceURL = tm.sourceFilePath.map { URL(fileURLWithPath: $0) }
                    ?? PlaybackFileManager.shared.lookupLocalLosslessSourceURL(for: tm.id)
                let t = StemTrack(
                    id: tm.id,
                    name: tm.name,
                    role: tm.role,
                    fileURL: url,
                    sourceFileURL: restoredSourceURL,
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
                    let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == song.id })
                    let expectedState = isActiveSong
                        ? currentLiveGuideLoopState()
                        : expectedDefaultGuideLoopState(forSongAt: songIdx ?? -1, song: song)
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
            if hasAllRequiredAudioHydrated(in: loaded) {
                memoryEvictedSongIds.remove(song.id)
            }
        }
        return loaded
    }

    // MARK: - Asynchronous Cancellable Song Hydration & Prefetch

    final class HydrationCancellationFlag: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { lock.withLock { $0 } }
        func cancel() { lock.withLock { $0 = true } }
    }

    struct TrackHydrationDescriptor: @unchecked Sendable {
        let trackId: UUID
        let localBackingURL: URL?
        let includeInWaveform: Bool
        let needsPeaks: Bool
        let isClick: Bool
        let isGuide: Bool
        let needsTransform: Bool
    }

    struct SongHydrationRequest: @unchecked Sendable {
        let songId: UUID
        let sourceSongId: UUID?
        let sessionURL: URL?
        let stemURLs: [URL]
        let descriptors: [TrackHydrationDescriptor]
        let canonicalFormat: AVAudioFormat
        let needsPristine: Bool
        let needsTransposedDisk: Bool
        let transposeSemitones: Int
        let preserveVocalFormants: Bool
        let bpm: Double
        let originalBPM: Double
        let clickSource: ClickSource
        let guideSource: GuideSource
    }

    struct DecodedHydrationTrackItem: @unchecked Sendable {
        let trackId: UUID
        let resolvedURL: URL?
        let buffer: AVAudioPCMBuffer
        let peaks: [Float]?
        let reconstructedTrack: StemTrack?
    }

    struct AsyncSongHydrationResult: @unchecked Sendable {
        let songId: UUID
        let decodedItems: [DecodedHydrationTrackItem]
        let reconstructedFromStemURLs: Bool
        let loadedTransposedBuffers: [UUID: AVAudioPCMBuffer]?
        let transposeSemitones: Int
        let preserveVocalFormants: Bool
        let bpmHundredths: Int
    }

    func hasAllRequiredAudioHydrated(in items: [(track: StemTrack, buffer: AVAudioPCMBuffer)]) -> Bool {
        let nonUtility = items.filter { !Self.isClickOrGuideTrack($0.track) }
        if !nonUtility.isEmpty {
            let hasAnyPlayableStem = nonUtility.contains { $0.buffer.frameLength > 100 }
            let allBackingFilesHydrated = nonUtility.allSatisfy {
                $0.buffer.frameLength > 100 || ($0.track.fileURL == nil && !Self.hasLocalBackingAudioFile(for: $0.track))
            }
            return hasAnyPlayableStem && allBackingFilesHydrated
        }
        guard !items.isEmpty else { return false }
        return items.allSatisfy {
            $0.buffer.frameLength > 100 || $0.track.fileURL == nil
        }
    }

    func songNeedsBufferHydration(_ song: Song) -> (needsPristine: Bool, needsTransposedDisk: Bool) {
        if downloadingSongProgress[song.id] != nil {
            return (false, false)
        }

        let existing = songBuffersCache[song.id]
        let needsPristine: Bool
        if let existing = existing, !existing.isEmpty {
            if hasAllRequiredAudioHydrated(in: existing) {
                needsPristine = false
            } else {
                needsPristine = existing.contains { track, buf in
                    buf.frameLength <= 100 && resolveLocalBackingURL(for: track) != nil
                }
            }
        } else if let backed = songTrackMetadataBackup[song.id], !backed.isEmpty {
            needsPristine = backed.contains { resolveLocalBackingURL(for: $0) != nil }
        } else {
            needsPristine = !song.stemURLs.isEmpty && song.stemURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
        }

        let needsTransform = (song.transposeSemitones != 0 || song.isTempoShifted)
        let needsTransposedDisk: Bool
        if needsTransform &&
           cachedTransformedBuffers(for: song) == nil &&
           transposeTasksBySong[song.id] == nil {
            if needsPristine {
                needsTransposedDisk = true
            } else {
                let tracksList: [StemTrack] = (song.id == currentSong.id && !channels.isEmpty)
                    ? channels.values.map { $0.track }
                    : ((existing?.map { $0.track }) ?? songTrackMetadataBackup[song.id] ?? [])
                let targetTrackIds = tracksList
                    .filter { shouldRenderTransformedTrack($0, for: song, tempoShifted: song.isTempoShifted) }
                    .map { $0.id }
                needsTransposedDisk = PlaybackFileManager.shared.hasTransposedBuffersOnDisk(
                    songId: song.id,
                    semitones: song.transposeSemitones,
                    preserveVocalFormants: song.preserveVocalFormants,
                    bpm: song.bpm,
                    originalBPM: song.originalBPM,
                    trackIds: targetTrackIds
                )
            }
        } else {
            needsTransposedDisk = false
        }

        return (needsPristine, needsTransposedDisk)
    }

    private func buildSongHydrationRequest(
        for song: Song,
        needsPristine: Bool,
        needsTransposedDisk: Bool
    ) -> SongHydrationRequest {
        let canonicalFormat = getCanonicalProcessingFormat()
        let savedTracks: [StemTrack] = {
            if song.id == currentSong.id && !tracks.isEmpty {
                return tracks
            }
            if let existing = songBuffersCache[song.id], !existing.isEmpty {
                return existing.map { $0.track }
            }
            return songTrackMetadataBackup[song.id] ?? []
        }()

        let existingBufferByTrackId: [UUID: AVAudioPCMBuffer] = {
            if song.id == currentSong.id && !pristineMasterBuffers.isEmpty {
                return pristineMasterBuffers
            }
            var map: [UUID: AVAudioPCMBuffer] = [:]
            for item in songBuffersCache[song.id] ?? [] {
                map[item.track.id] = item.buffer
            }
            return map
        }()

        let descriptors: [TrackHydrationDescriptor] = savedTracks.map { track in
            let existingLen = existingBufferByTrackId[track.id]?.frameLength ?? 0
            let needsTrackRead = needsPristine && existingLen <= 100
            return TrackHydrationDescriptor(
                trackId: track.id,
                localBackingURL: needsTrackRead ? resolveLocalBackingURL(for: track) : nil,
                includeInWaveform: track.includeInWaveform,
                needsPeaks: track.waveformPeaks.isEmpty,
                isClick: Self.isClickTrack(track),
                isGuide: Self.isGuideTrack(track),
                needsTransform: shouldRenderTransformedTrack(track, for: song, tempoShifted: song.isTempoShifted)
            )
        }

        return SongHydrationRequest(
            songId: song.id,
            sourceSongId: song.sourceSongId,
            sessionURL: currentSessionURL,
            stemURLs: song.stemURLs,
            descriptors: descriptors,
            canonicalFormat: canonicalFormat,
            needsPristine: needsPristine,
            needsTransposedDisk: needsTransposedDisk,
            transposeSemitones: song.transposeSemitones,
            preserveVocalFormants: song.preserveVocalFormants,
            bpm: song.bpm,
            originalBPM: song.originalBPM,
            clickSource: song.clickSource,
            guideSource: song.guideSource
        )
    }

    private nonisolated static func performOffMainSongHydration(
        request: SongHydrationRequest,
        flag: HydrationCancellationFlag
    ) -> AsyncSongHydrationResult? {
        if flag.isCancelled || Task.isCancelled { return nil }

        var decodedItems: [DecodedHydrationTrackItem] = []
        var reconstructedFromStemURLs = false
        var transformTrackIds: [UUID] = []

        if !request.descriptors.isEmpty {
            transformTrackIds = request.descriptors.filter { $0.needsTransform }.map { $0.trackId }

            if request.needsPristine {
                let count = request.descriptors.count
                let box = UnsafeMutableBufferPointer<DecodedHydrationTrackItem?>.allocate(capacity: count)
                box.initialize(repeating: nil)
                defer {
                    box.deinitialize()
                    box.deallocate()
                }
                DispatchQueue.concurrentPerform(iterations: count) { idx in
                    if flag.isCancelled { return }
                    let desc = request.descriptors[idx]
                    guard let localURL = desc.localBackingURL,
                          let raw = try? PlaybackFileManager.shared.readPCMBuffer(from: localURL) else {
                        return
                    }
                    if flag.isCancelled { return }
                    let norm = PlaybackFileManager.normalizeBuffer(raw, to: request.canonicalFormat)
                    if flag.isCancelled { return }
                    let peaks: [Float]? = (desc.needsPeaks && desc.includeInWaveform && norm.frameLength > 100 && !desc.isClick && !desc.isGuide)
                        ? PlaybackFileManager.extractPeaks(from: norm, samplesCount: 4000)
                        : nil
                    box[idx] = DecodedHydrationTrackItem(
                        trackId: desc.trackId,
                        resolvedURL: localURL,
                        buffer: norm,
                        peaks: peaks,
                        reconstructedTrack: nil
                    )
                }
                if flag.isCancelled || Task.isCancelled { return nil }
                decodedItems.reserveCapacity(count)
                for idx in 0..<count {
                    if let item = box[idx] {
                        decodedItems.append(item)
                    }
                }
            }
        } else if request.needsPristine && !request.stemURLs.isEmpty {
            reconstructedFromStemURLs = true
            var diskMetaById: [UUID: TrackFileMetadata] = [:]
            if let sessURL = request.sessionURL {
                let metaTracks = PlaybackFileManager.shared.loadSongTrackMetadataFromSession(songId: request.songId, sessionURL: sessURL)
                    ?? (request.sourceSongId.flatMap { PlaybackFileManager.shared.loadSongTrackMetadataFromSession(songId: $0, sessionURL: sessURL) })
                if let metaTracks = metaTracks {
                    for tm in metaTracks where !Self.isLikelyUUIDString(tm.name) {
                        diskMetaById[tm.id] = tm
                    }
                }
            }
            if flag.isCancelled || Task.isCancelled { return nil }

            let count = request.stemURLs.count
            let box = UnsafeMutableBufferPointer<DecodedHydrationTrackItem?>.allocate(capacity: count)
            box.initialize(repeating: nil)
            defer {
                box.deinitialize()
                box.deallocate()
            }
            DispatchQueue.concurrentPerform(iterations: count) { idx in
                if flag.isCancelled { return }
                let url = request.stemURLs[idx]
                guard let raw = try? PlaybackFileManager.shared.readPCMBuffer(from: url) else { return }
                if flag.isCancelled { return }
                let norm = PlaybackFileManager.normalizeBuffer(raw, to: request.canonicalFormat)
                if flag.isCancelled { return }
                let baseName = url.deletingPathExtension().lastPathComponent

                let track: StemTrack
                if let uuid = UUID(uuidString: baseName), let tm = diskMetaById[uuid] {
                    let restoredSourceURL = tm.sourceFilePath.map { URL(fileURLWithPath: $0) }
                        ?? PlaybackFileManager.shared.lookupLocalLosslessSourceURL(for: tm.id)
                    let t = StemTrack(
                        id: tm.id,
                        name: tm.name,
                        role: tm.role,
                        fileURL: url,
                        sourceFileURL: restoredSourceURL,
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
                if cat == .click { track.role = .click }
                else if cat == .guide { track.role = .guide }
                if norm.frameLength > 10 && track.duration <= 0 {
                    track.duration = Double(norm.frameLength) / norm.format.sampleRate
                }
                var computedPeaks: [Float]? = nil
                if track.waveformPeaks.isEmpty && track.includeInWaveform && norm.frameLength > 100 && cat != .click && cat != .guide {
                    computedPeaks = PlaybackFileManager.extractPeaks(from: norm, samplesCount: 4000)
                    if let p = computedPeaks {
                        track.waveformPeaks = p
                    }
                }
                box[idx] = DecodedHydrationTrackItem(
                    trackId: track.id,
                    resolvedURL: url,
                    buffer: norm,
                    peaks: computedPeaks,
                    reconstructedTrack: track
                )
            }
            if flag.isCancelled || Task.isCancelled { return nil }
            decodedItems.reserveCapacity(count)
            for idx in 0..<count {
                if let item = box[idx] {
                    decodedItems.append(item)
                    if let t = item.reconstructedTrack {
                        let tempoShifted = abs(request.bpm - request.originalBPM) > 0.005
                        let isClick = Self.isClickTrack(t)
                        let isGuide = Self.isGuideTrack(t)
                        let includeTrack: Bool
                        if !isClick && !isGuide {
                            includeTrack = true
                        } else if tempoShifted {
                            let isGenClick = isClick && request.clickSource == .generated
                            let isGenGuide = isGuide && request.guideSource == .generated
                            includeTrack = !isGenClick && !isGenGuide
                        } else {
                            includeTrack = false
                        }
                        if includeTrack {
                            transformTrackIds.append(t.id)
                        }
                    }
                }
            }
        }

        if flag.isCancelled || Task.isCancelled { return nil }

        var loadedTransposed: [UUID: AVAudioPCMBuffer]? = nil
        if request.needsTransposedDisk && !transformTrackIds.isEmpty {
            loadedTransposed = PlaybackFileManager.shared.loadTransposedBuffersFromDisk(
                songId: request.songId,
                semitones: request.transposeSemitones,
                preserveVocalFormants: request.preserveVocalFormants,
                bpm: request.bpm,
                originalBPM: request.originalBPM,
                trackIds: transformTrackIds,
                canonicalFormat: request.canonicalFormat,
                isCancelled: { flag.isCancelled }
            )
        }

        if flag.isCancelled || Task.isCancelled { return nil }

        return AsyncSongHydrationResult(
            songId: request.songId,
            decodedItems: decodedItems,
            reconstructedFromStemURLs: reconstructedFromStemURLs,
            loadedTransposedBuffers: loadedTransposed,
            transposeSemitones: request.transposeSemitones,
            preserveVocalFormants: request.preserveVocalFormants,
            bpmHundredths: PlaybackFileManager.cacheBPMHundredths(request.bpm)
        )
    }

    func startAsyncHydrationForActiveSong(_ song: Song, generation: UInt64) {
        activeSongHydrationTask?.cancel()
        backgroundPrefetchTasksBySong.removeValue(forKey: song.id)?.cancel()

        let need = songNeedsBufferHydration(song)
        guard need.needsPristine || need.needsTransposedDisk else {
            hydratingSongIds.remove(song.id)
            return
        }

        hydratingSongIds.insert(song.id)
        let request = buildSongHydrationRequest(
            for: song,
            needsPristine: need.needsPristine,
            needsTransposedDisk: need.needsTransposedDisk
        )
        let flag = HydrationCancellationFlag()

        activeSongHydrationTask = Task.detached(priority: .userInitiated) { [weak self, request, flag, generation] in
            let result = await withTaskCancellationHandler {
                Self.performOffMainSongHydration(request: request, flag: flag)
            } onCancel: {
                flag.cancel()
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.songSwitchGeneration == generation else { return }
                self.activeSongHydrationTask = nil
                guard !flag.isCancelled, !Task.isCancelled, let result = result else {
                    self.hydratingSongIds.remove(request.songId)
                    return
                }
                self.applyAsyncHydratedSongResult(result, expectedGeneration: generation, isPriorityActive: true)
            }
        }
    }

    func prefetchSongInBackgroundIfNeeded(song: Song) {
        guard song.id != currentSong.id else { return }
        guard downloadingSongProgress[song.id] == nil else { return }
        guard backgroundPrefetchTasksBySong[song.id] == nil else { return }

        let need = songNeedsBufferHydration(song)
        guard need.needsPristine || need.needsTransposedDisk else { return }

        let request = buildSongHydrationRequest(
            for: song,
            needsPristine: need.needsPristine,
            needsTransposedDisk: need.needsTransposedDisk
        )
        let flag = HydrationCancellationFlag()

        backgroundPrefetchTasksBySong[song.id] = Task.detached(priority: .utility) { [weak self, request, flag] in
            let result = await withTaskCancellationHandler {
                Self.performOffMainSongHydration(request: request, flag: flag)
            } onCancel: {
                flag.cancel()
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.backgroundPrefetchTasksBySong.removeValue(forKey: request.songId)
                guard !flag.isCancelled, !Task.isCancelled, let result = result else { return }
                guard self.currentSetlist.songs.contains(where: { $0.id == request.songId }) else { return }
                guard self.isSongInProtectedRAMWindow(request.songId) else { return }
                self.applyAsyncHydratedSongResult(result, expectedGeneration: nil, isPriorityActive: false)
            }
        }
    }

    func applyAsyncHydratedSongResult(
        _ result: AsyncSongHydrationResult,
        expectedGeneration: UInt64?,
        isPriorityActive: Bool
    ) {
        if isPriorityActive, let expectedGeneration = expectedGeneration, expectedGeneration != songSwitchGeneration {
            return
        }
        guard let songIdx = currentSetlist.songs.firstIndex(where: { $0.id == result.songId }) else {
            hydratingSongIds.remove(result.songId)
            return
        }
        let song = currentSetlist.songs[songIdx]
        let isActiveSong = (currentSong.id == result.songId)
        let canonicalFormat = getCanonicalProcessingFormat()

        if let loadedTransposed = result.loadedTransposedBuffers, !loadedTransposed.isEmpty,
           (song.transposeSemitones != 0 || song.isTempoShifted),
           song.transposeSemitones == result.transposeSemitones,
           song.preserveVocalFormants == result.preserveVocalFormants,
           PlaybackFileManager.cacheBPMHundredths(song.bpm) == result.bpmHundredths {
            songTransposedBuffersCache[result.songId] = (
                song.transposeSemitones,
                song.preserveVocalFormants,
                result.bpmHundredths,
                loadedTransposed
            )
        }

        let cachedTransposed = cachedTransformedBuffers(for: song)
        var didUpdatePeaks = false
        var maxDur: TimeInterval = 0.0

        var existingOrderTracks: [(StemTrack, AVAudioPCMBuffer)] = {
            if isActiveSong && !tracks.isEmpty {
                return tracks.map { ($0, pristineMasterBuffers[$0.id] ?? channels[$0.id]?.buffer ?? makeSilentStub(format: canonicalFormat)!) }
            }
            return songBuffersCache[result.songId] ?? []
        }()

        let decodedById = Dictionary(uniqueKeysWithValues: result.decodedItems.map { ($0.trackId, $0) })
        var rebuiltItems: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []

        if !result.reconstructedFromStemURLs && !existingOrderTracks.isEmpty {
            rebuiltItems.reserveCapacity(existingOrderTracks.count)
            for (track, existingBuf) in existingOrderTracks {
                let cat = StemCategory.category(for: track.name, role: track.role)
                if cat == .click { track.role = .click }
                else if cat == .guide { track.role = .guide }

                let decoded = decodedById[track.id]
                if track.fileURL == nil, let resolvedURL = decoded?.resolvedURL {
                    track.fileURL = resolvedURL
                }
                let rawPristineBuf = decoded?.buffer ?? existingBuf

                var bufferForCache = rawPristineBuf
                if cat == .click {
                    if rawPristineBuf.frameLength > 100 && (decoded != nil || track.fileURL != nil) {
                        uploadedClickBuffers[song.id] = rawPristineBuf
                    }
                    if song.clickSource == .generated {
                        if let genClick = generatedClickBuffers[song.id], genClick.frameLength > 1 {
                            bufferForCache = genClick
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            bufferForCache = stub
                        }
                    }
                } else if cat == .guide {
                    if rawPristineBuf.frameLength > 100 && (decoded != nil || track.fileURL != nil) {
                        uploadedGuideBuffers[song.id] = rawPristineBuf
                    }
                    if song.guideSource == .generated {
                        let expectedState = isActiveSong
                            ? currentLiveGuideLoopState()
                            : expectedDefaultGuideLoopState(forSongAt: songIdx, song: song)
                        if let genGuide = generatedGuideBuffers[song.id],
                           genGuide.frameLength > 1,
                           generatedGuideLoopStates[song.id] == expectedState {
                            bufferForCache = genGuide
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            bufferForCache = stub
                        }
                    }
                }

                let activeBuf = cachedTransposed?[track.id] ?? bufferForCache
                if activeBuf.frameLength > 10 {
                    let dur = Double(activeBuf.frameLength) / activeBuf.format.sampleRate
                    track.duration = dur
                    if dur > maxDur { maxDur = dur }
                } else if track.duration > maxDur {
                    maxDur = track.duration
                }
                if track.waveformPeaks.isEmpty, let peaks = decoded?.peaks, !peaks.isEmpty {
                    track.waveformPeaks = peaks
                    didUpdatePeaks = true
                }
                rebuiltItems.append((track, bufferForCache))
            }
        } else {
            // Reconstructed from `song.stemURLs`
            rebuiltItems.reserveCapacity(result.decodedItems.count)
            for item in result.decodedItems {
                guard let track = item.reconstructedTrack else { continue }
                let norm = item.buffer
                let cat = StemCategory.category(for: track.name, role: track.role)
                var bufferForCache = norm
                if cat == .click {
                    track.role = .click
                    if norm.frameLength > 100 {
                        uploadedClickBuffers[song.id] = norm
                    }
                    if song.clickSource == .generated {
                        if let genClick = generatedClickBuffers[song.id], genClick.frameLength > 1 {
                            bufferForCache = genClick
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            bufferForCache = stub
                        }
                    }
                } else if cat == .guide {
                    track.role = .guide
                    if norm.frameLength > 100 {
                        uploadedGuideBuffers[song.id] = norm
                    }
                    if song.guideSource == .generated {
                        let expectedState = isActiveSong
                            ? currentLiveGuideLoopState()
                            : expectedDefaultGuideLoopState(forSongAt: songIdx, song: song)
                        if let genGuide = generatedGuideBuffers[song.id],
                           genGuide.frameLength > 1,
                           generatedGuideLoopStates[song.id] == expectedState {
                            bufferForCache = genGuide
                        } else if let stub = makeSilentStub(format: canonicalFormat) {
                            bufferForCache = stub
                        }
                    }
                }
                let activeBuf = cachedTransposed?[track.id] ?? bufferForCache
                if activeBuf.frameLength > 10 {
                    let dur = Double(activeBuf.frameLength) / activeBuf.format.sampleRate
                    track.duration = dur
                    if dur > maxDur { maxDur = dur }
                } else if track.duration > maxDur {
                    maxDur = track.duration
                }
                if track.waveformPeaks.isEmpty, let peaks = item.peaks, !peaks.isEmpty {
                    track.waveformPeaks = peaks
                    didUpdatePeaks = true
                }
                rebuiltItems.append((track, bufferForCache))
            }
        }

        if rebuiltItems.contains(where: { Self.isClickTrack($0.track) && $0.track.fileURL != nil }) {
            rebuiltItems.removeAll { Self.isClickTrack($0.track) && $0.track.fileURL == nil }
        }
        if rebuiltItems.contains(where: { Self.isGuideTrack($0.track) && $0.track.fileURL != nil }) {
            rebuiltItems.removeAll { Self.isGuideTrack($0.track) && $0.track.fileURL == nil }
        }

        let songDur = max(maxDur, song.sections.map { $0.endTime }.max() ?? (song.totalDuration > 0 ? song.totalDuration : 240.0))
        if result.reconstructedFromStemURLs && !song.excludesClickAndGuide {
            let sr = canonicalFormat.sampleRate > 0 ? canonicalFormat.sampleRate : 44100.0
            let initFrames = AVAudioFrameCount(max(1, Int64(round(songDur * sr))))
            if !rebuiltItems.contains(where: { StemCategory.category(for: $0.track.name, role: $0.track.role) == .click }) {
                let clickTrack = StemTrack(name: "Click", role: .click, volume: 0.8, routing: .clickOut)
                clickTrack.duration = songDur
                if let genClick = (song.clickSource == .generated ? generatedClickBuffers[song.id] : nil), genClick.frameLength > 1 {
                    rebuiltItems.append((clickTrack, genClick))
                } else if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initFrames) {
                    silentBuf.frameLength = initFrames
                    rebuiltItems.append((clickTrack, silentBuf))
                }
            }
            if !rebuiltItems.contains(where: { StemCategory.category(for: $0.track.name, role: $0.track.role) == .guide }) {
                let guideTrack = StemTrack(name: "Guide", role: .guide, volume: 0.8, routing: .guideOut)
                guideTrack.duration = songDur
                let expectedState = isActiveSong
                    ? currentLiveGuideLoopState()
                    : expectedDefaultGuideLoopState(forSongAt: songIdx, song: song)
                if let genGuide = (song.guideSource == .generated && generatedGuideLoopStates[song.id] == expectedState ? generatedGuideBuffers[song.id] : nil),
                   genGuide.frameLength > 1 {
                    rebuiltItems.append((guideTrack, genGuide))
                } else if let silentBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: initFrames) {
                    silentBuf.frameLength = initFrames
                    rebuiltItems.append((guideTrack, silentBuf))
                }
            }
        }

        if rebuiltItems.count > 1 && (result.reconstructedFromStemURLs || tracks.isEmpty) {
            rebuiltItems.sort { a, b in
                let ord1 = StemCategory.playbackOrder(for: a.track.name, role: a.track.role)
                let ord2 = StemCategory.playbackOrder(for: b.track.name, role: b.track.role)
                if ord1 != ord2 { return ord1 < ord2 }
                let cat1 = StemCategory.category(for: a.track.name, role: a.track.role)
                let cat2 = StemCategory.category(for: b.track.name, role: b.track.role)
                if cat1 != cat2 { return cat1 < cat2 }
                return a.track.name.localizedStandardCompare(b.track.name) == .orderedAscending
            }
        }

        if !rebuiltItems.isEmpty {
            songBuffersCache[song.id] = rebuiltItems
            recordTrackMetadataBackup(for: song.id, tracks: rebuiltItems.map { $0.track })
            if hasAllRequiredAudioHydrated(in: rebuiltItems) {
                memoryEvictedSongIds.remove(song.id)
            }
        }
        hydratingSongIds.remove(song.id)

        if isActiveSong {
            var newPristine: [UUID: AVAudioPCMBuffer] = [:]
            var newChannels: [UUID: TrackChannel] = result.reconstructedFromStemURLs ? [:] : channels
            for (track, buf) in rebuiltItems {
                newPristine[track.id] = buf
                let activeBuf = cachedTransposed?[track.id] ?? buf
                if let ch = newChannels[track.id] {
                    ch.buffer = activeBuf
                } else {
                    newChannels[track.id] = TrackChannel(track: track, buffer: activeBuf)
                }
            }
            pristineMasterBuffers = newPristine
            channels = newChannels
            if result.reconstructedFromStemURLs || tracks.isEmpty {
                tracks = rebuiltItems.map { $0.track }
            }

            if maxDur > 0 && currentSong.sections.isEmpty {
                currentSongDuration = maxDur
            }

            if didUpdatePeaks || masterWaveformPeaks.isEmpty {
                recalculateAggregateWaveform(samplesCount: 4000)
                if !masterWaveformPeaks.isEmpty {
                    songWaveformCache[song.id] = (masterWaveformPeaks, renderedWaveformImage)
                }
            }

            if !currentSong.excludesClickAndGuide {
                if currentSong.clickSource == .generated {
                    if let cBuf = generatedClickBuffers[song.id], cBuf.frameLength > 1 {
                        applyClickBuffer()
                    } else {
                        regenerateClickTrack()
                    }
                } else if currentSong.clickSource == .uploaded, uploadedClickBuffers[song.id] != nil {
                    applyClickBuffer()
                }
                if currentSong.guideSource == .generated {
                    let expectedGuideState = currentLiveGuideLoopState()
                    if let gBuf = generatedGuideBuffers[song.id],
                       gBuf.frameLength > 1,
                       generatedGuideLoopStates[song.id] == expectedGuideState {
                        applyGuideBuffer()
                    } else {
                        regenerateGuideTrack()
                    }
                } else if currentSong.guideSource == .uploaded, uploadedGuideBuffers[song.id] != nil {
                    applyGuideBuffer()
                }
            }

            updateMatrix(persistBusRouting: false)

            if (currentSong.transposeSemitones != 0 || currentSong.isTempoShifted) &&
               cachedTransformedBuffers(for: currentSong) == nil &&
               transposeTasksBySong[currentSong.id] == nil {
                setKeyAndTempo(forSongIndex: currentSongIndex)
            }

            if pendingPlayAfterHydration && !isCurrentSongTransposing && !isCurrentSongDownloading {
                let queuedSection = pendingPlaySectionAfterHydration
                pendingPlayAfterHydration = false
                pendingPlaySectionAfterHydration = nil
                if let sec = queuedSection {
                    playSection(sec)
                } else {
                    play()
                }
            }

            scheduleSlidingWindowRebalance()
        } else {
            if !song.excludesClickAndGuide && (song.clickSource == .generated || song.guideSource == .generated) {
                preGenerateClickAndGuide(forSongId: song.id)
            }
            if (song.transposeSemitones != 0 || song.isTempoShifted) &&
               cachedTransformedBuffers(for: song) == nil &&
               transposeTasksBySong[song.id] == nil {
                preRenderTranspose(forSongIndex: songIdx)
            }
            if songIdx == currentSongIndex + 1 {
                syncMixState()
            }
        }
    }
    
}
