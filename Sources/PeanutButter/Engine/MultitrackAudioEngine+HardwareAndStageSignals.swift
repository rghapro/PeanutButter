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

    public func availableMonoChannelsForRedundancy(for targetDevice: AudioOutputDevice? = nil) -> [String] {
        let (_, monoOuts) = deviceManager.availableOutputs(for: targetDevice ?? deviceManager.selectedDevice)
        let channels = monoOuts.isEmpty ? ["Out 1", "Out 2"] : monoOuts
        let occupied = occupiedMonoChannelIndices(excludingRedundancy: true, excludingSMPTE: false)
        return channels.filter { !occupied.contains(Self.monoChannelIndex(for: $0)) }
    }

    public func availableMonoChannelsForSMPTE(for targetDevice: AudioOutputDevice? = nil) -> [String] {
        let (_, monoOuts) = deviceManager.availableOutputs(for: targetDevice ?? deviceManager.selectedDevice)
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

    public struct DeviceStageSignalPreset: Codable, Sendable, Equatable {
        public let isRedundancyEnabled: Bool
        public let redundancyOutputChannel: String
        public let isSMPTEEnabled: Bool
        public let smpteOutputChannel: String
        public let smpteFrameRate: SMPTEFrameRate

        public init(
            isRedundancyEnabled: Bool,
            redundancyOutputChannel: String,
            isSMPTEEnabled: Bool,
            smpteOutputChannel: String,
            smpteFrameRate: SMPTEFrameRate
        ) {
            self.isRedundancyEnabled = isRedundancyEnabled
            self.redundancyOutputChannel = redundancyOutputChannel
            self.isSMPTEEnabled = isSMPTEEnabled
            self.smpteOutputChannel = smpteOutputChannel
            self.smpteFrameRate = smpteFrameRate
        }
    }

    public func stageSignalPresetStorageKey(for device: AudioOutputDevice?) -> String? {
        guard let dev = device else { return nil }
        let idStr = !dev.uid.isEmpty ? dev.uid : dev.name
        guard !idStr.isEmpty else { return nil }
        return "Playback_StageSignals_\(idStr)"
    }

    public func stageSignalPresetNameStorageKey(for device: AudioOutputDevice?) -> String? {
        guard let dev = device else { return nil }
        let normalized = dev.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return "Playback_StageSignals_Name_\(normalized)"
    }

    public func saveStageSignalPreset(for device: AudioOutputDevice?, defaults: UserDefaults = .standard) {
        let primaryKey = stageSignalPresetStorageKey(for: device)
        let nameKey = stageSignalPresetNameStorageKey(for: device)
        guard primaryKey != nil || nameKey != nil else { return }
        let preset = DeviceStageSignalPreset(
            isRedundancyEnabled: isRedundancyEnabled,
            redundancyOutputChannel: redundancyOutputChannel,
            isSMPTEEnabled: isSMPTEEnabled,
            smpteOutputChannel: smpteOutputChannel,
            smpteFrameRate: smpteFrameRate
        )
        if let data = try? JSONEncoder().encode(preset) {
            if let key = primaryKey {
                defaults.set(data, forKey: key)
            }
            if let nKey = nameKey, nKey != primaryKey {
                defaults.set(data, forKey: nKey)
            }
        }
    }

    public func loadStageSignalPreset(for device: AudioOutputDevice?, allowLegacyGlobalFallback: Bool = false, defaults: UserDefaults = .standard) {
        isRedundancyEnabled = false
        isSMPTEEnabled = false

        let primaryKey = stageSignalPresetStorageKey(for: device)
        let nameKey = stageSignalPresetNameStorageKey(for: device)
        var loadedData: Data? = nil
        var loadedFromNameFallback = false
        if let key = primaryKey, let data = defaults.data(forKey: key) {
            loadedData = data
        } else if let nKey = nameKey, let data = defaults.data(forKey: nKey) {
            loadedData = data
            loadedFromNameFallback = true
        }

        if let data = loadedData,
           let preset = try? JSONDecoder().decode(DeviceStageSignalPreset.self, from: data) {
            if loadedFromNameFallback, let key = primaryKey {
                defaults.set(data, forKey: key)
            }
            redundancyOutputChannel = preset.redundancyOutputChannel
            smpteOutputChannel = preset.smpteOutputChannel
            smpteFrameRate = preset.smpteFrameRate
            if preset.isRedundancyEnabled && availableMonoChannelsForRedundancy(for: device).contains(preset.redundancyOutputChannel) {
                isRedundancyEnabled = true
            }
            if preset.isSMPTEEnabled && availableMonoChannelsForSMPTE(for: device).contains(preset.smpteOutputChannel) {
                isSMPTEEnabled = true
            }
        } else if allowLegacyGlobalFallback {
            let savedRedundancyEnabled = defaults.bool(forKey: "Playback_RedundancyEnabled")
            self.redundancyOutputChannel = defaults.string(forKey: "Playback_RedundancyChannel") ?? "Out 1"
            if savedRedundancyEnabled && availableMonoChannelsForRedundancy(for: device).contains(self.redundancyOutputChannel) {
                self.isRedundancyEnabled = true
            }

            let savedSMPTEEnabled = defaults.bool(forKey: "Playback_SMPTEEnabled")
            if let rawRate = defaults.string(forKey: "Playback_SMPTEFrameRate"),
               let rate = SMPTEFrameRate(rawValue: rawRate) {
                self.smpteFrameRate = rate
            }
            self.smpteOutputChannel = defaults.string(forKey: "Playback_SMPTEOutputChannel") ?? "Out 2"
            if savedSMPTEEnabled && availableMonoChannelsForSMPTE(for: device).contains(self.smpteOutputChannel) {
                self.isSMPTEEnabled = true
            }
            if device != nil && (self.isRedundancyEnabled || self.isSMPTEEnabled) {
                saveStageSignalPreset(for: device, defaults: defaults)
            }
        }

        updateRedundancyState(persistDevicePreset: false)
        updateSMPTEState(persistDevicePreset: false)
    }

    public func disableRedundancyAndSMPTEOnDeviceChange() {
        if isRedundancyEnabled {
            isRedundancyEnabled = false
            updateRedundancyState(persistDevicePreset: false)
        }
        if isSMPTEEnabled {
            isSMPTEEnabled = false
            updateSMPTEState(persistDevicePreset: false)
        }
    }
    
    public func updateRedundancyState(persistDevicePreset: Bool = true) {
        let channelIndex = Self.monoChannelIndex(for: redundancyOutputChannel)
        mixState.setRedundancy(enabled: isRedundancyEnabled, channelIndex: channelIndex)
        UserDefaults.standard.set(isRedundancyEnabled, forKey: "Playback_RedundancyEnabled")
        UserDefaults.standard.set(redundancyOutputChannel, forKey: "Playback_RedundancyChannel")
        if persistDevicePreset {
            saveStageSignalPreset(for: deviceManager.selectedDevice)
        }
    }
    
    public func updateSMPTEState(persistDevicePreset: Bool = true) {
        let channelIndex: Int = {
            let digits = smpteOutputChannel.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let num = Int(digits), num >= 1 {
                return num - 1
            }
            return 1
        }()
        
        let hasCue = currentSong.smpteCue != nil
        let cueTime = currentSong.smpteCue?.time ?? 0.0
        let cueStartSec = currentSong.smpteCue?.totalStartSeconds(for: smpteFrameRate) ?? 0.0
        let canonicalRate = getCanonicalProcessingFormat().sampleRate
        let sr = canonicalRate > 0 ? canonicalRate : 48000.0
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
        if persistDevicePreset {
            saveStageSignalPreset(for: deviceManager.selectedDevice)
        }
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
        updateSMPTEState(persistDevicePreset: false)
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
        updateSMPTEState(persistDevicePreset: false)
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
        updateSMPTEState(persistDevicePreset: false)
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
        updateSMPTEState(persistDevicePreset: false)
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
    
    func setupMemoryPressureMonitoring() {
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

    // MARK: - Proactive Sliding-Window Memory Management

    public func effectiveMemoryWindowPolicy() -> MemoryWindowPolicy {
        memoryWindowPolicyOverride ?? .forPhysicalMemory()
    }

    static func pcmBufferByteSize(_ buffer: AVAudioPCMBuffer) -> Int64 {
        Int64(buffer.frameLength) * Int64(max(1, buffer.format.channelCount)) * Int64(MemoryLayout<Float>.size)
    }

    func estimatedResidentPCMBytes(for songId: UUID) -> Int64 {
        var seen = Set<ObjectIdentifier>()
        var total: Int64 = 0

        func account(_ buf: AVAudioPCMBuffer?) {
            guard let buf = buf, buf.frameLength > 1 else { return }
            let oid = ObjectIdentifier(buf)
            if seen.insert(oid).inserted {
                total += Self.pcmBufferByteSize(buf)
            }
        }

        if songId == currentSong.id {
            for buf in pristineMasterBuffers.values {
                account(buf)
            }
            for ch in channels.values {
                account(ch.buffer)
            }
        }
        if let cached = songBuffersCache[songId] {
            for item in cached {
                account(item.buffer)
            }
        }
        if let transposed = songTransposedBuffersCache[songId]?.buffers {
            for buf in transposed.values {
                account(buf)
            }
        }
        account(uploadedClickBuffers[songId])
        account(uploadedGuideBuffers[songId])
        account(generatedClickBuffers[songId])
        account(generatedGuideBuffers[songId])
        return total
    }

    func totalResidentPCMBytes() -> Int64 {
        var total: Int64 = 0
        for song in currentSetlist.songs {
            total += estimatedResidentPCMBytes(for: song.id)
        }
        return total
    }

    func prioritizedWindowSongIds(around centerIndex: Int, maxCount: Int) -> [UUID] {
        let count = currentSetlist.songs.count
        guard count > 0, maxCount > 0 else { return [] }
        let center = max(0, min(count - 1, centerIndex))
        var result: [UUID] = []
        var seen = Set<UUID>()

        func appendIfValid(_ idx: Int) {
            guard idx >= 0, idx < count, result.count < maxCount else { return }
            let id = currentSetlist.songs[idx].id
            if seen.insert(id).inserted {
                result.append(id)
            }
        }

        // Priority 0: Active song
        appendIfValid(center)
        // Priority 1: Next song (always protected for 0.00ms Auto-Link/Overlap/Crossfade transitions)
        appendIfValid(center + 1)
        // Priority 2: Previous song
        appendIfValid(center - 1)
        // Priority 3+: Expand outward (+offset, -offset)
        var offset = 2
        while result.count < min(maxCount, count) && offset <= count {
            appendIfValid(center + offset)
            appendIfValid(center - offset)
            offset += 1
        }
        return result
    }

    func isSongInProtectedRAMWindow(_ songId: UUID) -> Bool {
        let windowIds = prioritizedWindowSongIds(
            around: currentSongIndex,
            maxCount: effectiveMemoryWindowPolicy().maxResidentSongs
        )
        return windowIds.contains(songId)
    }

    @discardableResult
    func evictSongFromMemory(
        _ songId: UUID,
        allowWaveformEviction: Bool = false,
        forceDropTransposedWithoutDiskCache: Bool = false
    ) -> Bool {
        guard songId != currentSong.id else { return false }
        if downloadingSongProgress[songId] != nil ||
           transposeTasksBySong[songId] != nil ||
           transposingSongId == songId ||
           hydratingSongIds.contains(songId) {
            return false
        }

        var didRelease = false
        let song = currentSetlist.songs.first(where: { $0.id == songId })

        if let transEntry = songTransposedBuffersCache[songId] {
            let canDropTransposed: Bool
            if forceDropTransposedWithoutDiskCache {
                canDropTransposed = true
            } else if let song = song {
                let targetTrackIds = Array(transEntry.buffers.keys)
                canDropTransposed = PlaybackFileManager.shared.hasTransposedBuffersOnDisk(
                    songId: songId,
                    semitones: song.transposeSemitones,
                    preserveVocalFormants: song.preserveVocalFormants,
                    bpm: song.bpm,
                    originalBPM: song.originalBPM,
                    trackIds: targetTrackIds
                )
            } else {
                canDropTransposed = true
            }
            if canDropTransposed {
                songTransposedBuffersCache.removeValue(forKey: songId)
                didRelease = true
            }
        }

        if let existing = songBuffersCache[songId],
           !existing.isEmpty,
           existing.contains(where: { $0.buffer.frameLength > 100 }) {
            let allHaveLocalFiles = existing.allSatisfy { (track, _) in
                if track.fileURL == nil && Self.isClickOrGuideTrack(track) {
                    return true
                }
                return Self.hasLocalBackingAudioFile(for: track)
            }
            if allHaveLocalFiles, let stub = makeSilentStub(format: getCanonicalProcessingFormat()) {
                recordTrackMetadataBackup(for: songId, tracks: existing.map { $0.track })
                var stubbed: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []
                stubbed.reserveCapacity(existing.count)
                for (track, _) in existing {
                    if track.fileURL == nil && PlaybackFileManager.shared.hasValidCachedStem(for: track.id) {
                        track.fileURL = PlaybackFileManager.shared.cachedStemURL(for: track.id)
                    }
                    stubbed.append((track: track, buffer: stub))
                }
                songBuffersCache[songId] = stubbed
                uploadedClickBuffers.removeValue(forKey: songId)
                uploadedGuideBuffers.removeValue(forKey: songId)
                generatedClickBuffers.removeValue(forKey: songId)
                generatedGuideBuffers.removeValue(forKey: songId)
                generatedGuideLoopStates.removeValue(forKey: songId)
                memoryEvictedSongIds.insert(songId)
                didRelease = true
            }
        }

        if generatedClickBuffers.removeValue(forKey: songId) != nil {
            didRelease = true
        }
        if generatedGuideBuffers.removeValue(forKey: songId) != nil {
            generatedGuideLoopStates.removeValue(forKey: songId)
            didRelease = true
        }

        if allowWaveformEviction {
            songWaveformCache.removeValue(forKey: songId)
        }
        return didRelease
    }

    public func rebalanceSlidingWindowMemory(prefetchNeighbors: Bool = true) {
        let count = currentSetlist.songs.count
        guard count > 0 else { return }

        let policy = effectiveMemoryWindowPolicy()
        let windowIds = prioritizedWindowSongIds(around: currentSongIndex, maxCount: policy.maxResidentSongs)
        let windowSet = Set(windowIds)

        // Pass 1: Evict songs outside the active sliding window
        for song in currentSetlist.songs where !windowSet.contains(song.id) {
            backgroundPrefetchTasksBySong.removeValue(forKey: song.id)?.cancel()
            _ = evictSongFromMemory(
                song.id,
                allowWaveformEviction: false,
                forceDropTransposedWithoutDiskCache: false
            )
        }

        // Pass 2: Enforce soft PCM byte budget without ever evicting Active (index 0) or Next (index 1)
        if totalResidentPCMBytes() > policy.softPCMByteBudget && windowIds.count > 2 {
            for idx in stride(from: windowIds.count - 1, through: 2, by: -1) {
                if totalResidentPCMBytes() <= policy.softPCMByteBudget {
                    break
                }
                let candidateId = windowIds[idx]
                backgroundPrefetchTasksBySong.removeValue(forKey: candidateId)?.cancel()
                _ = evictSongFromMemory(
                    candidateId,
                    allowWaveformEviction: false,
                    forceDropTransposedWithoutDiskCache: false
                )
            }
        }

        guard prefetchNeighbors else { return }

        // Pass 3: Proactively prefetch Next song (0.00ms transitions) and Prev song (if within budget)
        let nextIdx = currentSongIndex + 1
        if nextIdx >= 0 && nextIdx < count {
            let nextSong = currentSetlist.songs[nextIdx]
            let need = songNeedsBufferHydration(nextSong)
            if need.needsPristine || need.needsTransposedDisk {
                prefetchSongInBackgroundIfNeeded(song: nextSong)
            }
        }

        let prevIdx = currentSongIndex - 1
        if prevIdx >= 0 && prevIdx < count {
            let prevSong = currentSetlist.songs[prevIdx]
            if windowSet.contains(prevSong.id) && totalResidentPCMBytes() < policy.softPCMByteBudget {
                let need = songNeedsBufferHydration(prevSong)
                if need.needsPristine || need.needsTransposedDisk {
                    prefetchSongInBackgroundIfNeeded(song: prevSong)
                }
            }
        }
    }

    func scheduleSlidingWindowRebalance(delayNanoseconds: UInt64 = 220_000_000) {
        slidingWindowRebalanceTask?.cancel()
        slidingWindowRebalanceTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self = self else { return }
            self.rebalanceSlidingWindowMemory(prefetchNeighbors: true)
        }
    }

    /// Graceful fallback for lower-RAM Macs under memory pressure: preserves active + immediate next song
    /// in RAM for 0.00ms transitions while unloading distant locally-backed song PCM buffers without ever
    /// discarding track metadata (names, roles, mutes, faders, routing, or buses).
    public func handleMemoryPressure(critical: Bool) {
        // Release transient orphan buffers immediately on any memory pressure warning,
        // and purge redo / excess undo snapshots on critical memory pressure.
        undoRecentOrphanBuffers.removeAll()
        if critical {
            redoStack.removeAll()
            canRedo = false
            if undoStack.count > 10 {
                undoStack.removeFirst(undoStack.count - 10)
            }
            canUndo = !undoStack.isEmpty
        }

        guard currentSetlist.songs.count > 2 else { return }
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
            backgroundPrefetchTasksBySong.removeValue(forKey: song.id)?.cancel()
            if critical || currentSetlist.songs.count > 3 {
                _ = evictSongFromMemory(
                    song.id,
                    allowWaveformEviction: critical,
                    forceDropTransposedWithoutDiskCache: true
                )
            } else if critical {
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
    // MARK: - Hardware Device Output Switching & Persistence
    
    public struct BusRoutingPreset: Codable, Sendable {
        public let physicalOutput: String
        public let isMono: Bool
        
        public init(physicalOutput: String, isMono: Bool) {
            self.physicalOutput = physicalOutput
            self.isMono = isMono
        }
    }
    
    func busRoutingStorageKey(for device: AudioOutputDevice?) -> String? {
        guard let dev = device else { return nil }
        let idStr = !dev.uid.isEmpty ? dev.uid : dev.name
        guard !idStr.isEmpty else { return nil }
        return "Playback_BusRouting_\(idStr)"
    }

    func busRoutingNameStorageKey(for device: AudioOutputDevice?) -> String? {
        guard let dev = device else { return nil }
        let normalized = dev.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return "Playback_BusRouting_Name_\(normalized)"
    }
    
    public func saveBusRouting(for device: AudioOutputDevice?, defaults: UserDefaults = .standard) {
        let primaryKey = busRoutingStorageKey(for: device)
        let nameKey = busRoutingNameStorageKey(for: device)
        guard primaryKey != nil || nameKey != nil else { return }
        var dict: [String: BusRoutingPreset] = [:]
        for bus in busses {
            dict[bus.name.lowercased()] = BusRoutingPreset(
                physicalOutput: bus.physicalOutputChannel,
                isMono: bus.isMono
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(dict) {
            let isStandardDefaults = (defaults === UserDefaults.standard)
            if isStandardDefaults, let key = primaryKey, key == lastSavedBusRoutingKey && data == lastSavedBusRoutingData {
                if let nKey = nameKey, nKey != key, defaults.data(forKey: nKey) == data {
                    return
                }
            }
            if let key = primaryKey {
                defaults.set(data, forKey: key)
                if isStandardDefaults {
                    lastSavedBusRoutingKey = key
                    lastSavedBusRoutingData = data
                }
            }
            if let nKey = nameKey, nKey != primaryKey {
                defaults.set(data, forKey: nKey)
            }
        }
    }
    
    public func loadBusRouting(for device: AudioOutputDevice?, defaults: UserDefaults = .standard) {
        guard let dev = device else { return }
        let (stereoOuts, monoOuts) = deviceManager.availableOutputs(for: dev)
        let defaultStereo = stereoOuts.first ?? "Out 1/2"
        let defaultMono = monoOuts.first ?? "Out 1"
        let defaultOut = dev.outputChannelCount > 1 ? defaultStereo : defaultMono
        let defaultIsMono = dev.outputChannelCount <= 1

        let primaryKey = busRoutingStorageKey(for: dev)
        let nameKey = busRoutingNameStorageKey(for: dev)
        var resolvedDict: [String: BusRoutingPreset]? = nil
        var rawLoadedData: Data? = nil
        var loadedFromNameFallback = false

        if let key = primaryKey,
           let data = defaults.data(forKey: key),
           let dict = try? JSONDecoder().decode([String: BusRoutingPreset].self, from: data) {
            resolvedDict = dict
            rawLoadedData = data
        } else if let nKey = nameKey,
                  let data = defaults.data(forKey: nKey),
                  let dict = try? JSONDecoder().decode([String: BusRoutingPreset].self, from: data) {
            resolvedDict = dict
            rawLoadedData = data
            loadedFromNameFallback = true
        }

        guard let dict = resolvedDict else {
            // Brand-new audio interface used: all busses default to Out 1/2 (or Out 1 for mono)
            for bus in busses {
                bus.physicalOutputChannel = defaultOut
                bus.isMono = defaultIsMono
            }
            validateBusOutputRouting(maxChannels: dev.outputChannelCount)
            return
        }

        if loadedFromNameFallback, let key = primaryKey, let rawLoadedData {
            defaults.set(rawLoadedData, forKey: key)
        }
        if defaults === UserDefaults.standard, let key = primaryKey, let rawLoadedData {
            lastSavedBusRoutingKey = key
            lastSavedBusRoutingData = rawLoadedData
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

    public func setOutputDevice(_ device: AudioOutputDevice, showBanner: Bool = true, persistAsPreferred: Bool = false) {
        if persistAsPreferred {
            deviceManager.persistPreferredDevice(device)
        }
        if lastAppliedHardwareDeviceID == device.id &&
           lastAppliedHardwareChannelCount == device.outputChannelCount &&
           deviceManager.selectedDevice?.id == device.id &&
           isEngineRunning && sourceNode != nil {
            return
        }
        isApplyingHardwareReconfiguration = true
        ignoreConfigNotificationsUntil = ProcessInfo.processInfo.systemUptime + 0.35
        defer { isApplyingHardwareReconfiguration = false }

        let previousSampleRate = lastConfiguredSampleRate
        lastAppliedHardwareDeviceID = device.id
        lastAppliedHardwareChannelCount = device.outputChannelCount

        if playbackState != .stopped {
            self.stop()
        }
        stopPadPlayerImmediately()
        audioEngine.stop()
        isEngineRunning = false
        
        var deviceID = device.id
        guard let outputUnit = audioEngine.outputNode.audioUnit else {
            do {
                try audioEngine.start()
                isEngineRunning = true
            } catch {
                isEngineRunning = false
                showAudioDeviceBanner("Audio engine start failed: \(error.localizedDescription)")
            }
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
            PeanutButterLog.hardware.info("Switched audio output device to \(device.name, privacy: .public) (\(device.outputChannelCount) ch)")
        } else {
            PeanutButterLog.hardware.error("Failed to set audio device to \(device.name, privacy: .public): OSStatus \(error)")
        }
        
        loadBusRouting(for: device)
        validateBusOutputRouting(maxChannels: device.outputChannelCount)
        loadStageSignalPreset(for: device)
        setupSingleClockSourceNode()
        if previousSampleRate > 0 && abs(lastConfiguredSampleRate - previousSampleRate) >= 1.0 {
            renormalizeLoadedBuffersForNewCanonicalFormat()
        }
        
        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            isEngineRunning = false
            PeanutButterLog.hardware.error("Failed to start audio engine on \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showAudioDeviceBanner("Failed to start audio engine on \(device.name): \(error.localizedDescription)")
        }
        updateMatrix(persistBusRouting: false)
        syncMixState()
        objectWillChange.send()
        if showBanner {
            showAudioDeviceBanner("Switched to \(device.name) (\(device.outputChannelCount) Outputs)")
        }
    }

    func handleAudioEngineConfigurationChange() {
        guard !isApplyingHardwareReconfiguration else { return }

        deviceManager.refreshDevices()
        let outFmt = audioEngine.outputNode.outputFormat(forBus: 0)
        let newSR = outFmt.sampleRate > 0 ? outFmt.sampleRate : 48000.0
        let newCh = max(2, deviceManager.selectedDevice?.outputChannelCount ?? Int(outFmt.channelCount))

        if ProcessInfo.processInfo.systemUptime < ignoreConfigNotificationsUntil &&
           audioEngine.isRunning &&
           sourceNode != nil &&
           abs(newSR - lastConfiguredSampleRate) < 1.0 &&
           newCh == lastAppliedHardwareChannelCount {
            return
        }

        isApplyingHardwareReconfiguration = true
        ignoreConfigNotificationsUntil = ProcessInfo.processInfo.systemUptime + 0.35
        defer { isApplyingHardwareReconfiguration = false }

        let wasPlaying = (playbackState == .playing)
        let savedTime = mixState.currentSeconds()
        if wasPlaying {
            pause()
        }

        audioEngine.stop()
        isEngineRunning = false

        let previousSampleRate = lastConfiguredSampleRate
        let prevDeviceID = lastAppliedHardwareDeviceID
        let prevChannelCount = lastAppliedHardwareChannelCount
        lastAppliedHardwareChannelCount = newCh
        if let dev = deviceManager.selectedDevice {
            lastAppliedHardwareDeviceID = dev.id
            if dev.id != prevDeviceID || dev.outputChannelCount != prevChannelCount {
                loadBusRouting(for: dev)
                loadStageSignalPreset(for: dev)
            }
        }
        validateBusOutputRouting(maxChannels: newCh)
        setupSingleClockSourceNode()

        let sampleRateChanged = previousSampleRate > 0 && abs(lastConfiguredSampleRate - previousSampleRate) >= 1.0
        if sampleRateChanged {
            renormalizeLoadedBuffersForNewCanonicalFormat()
        }

        do {
            try audioEngine.start()
            isEngineRunning = true
            PeanutButterLog.hardware.info("Reconfigured AVAudioEngine (\(Int(self.lastConfiguredSampleRate)) Hz, \(newCh) ch)")
        } catch {
            isEngineRunning = false
            PeanutButterLog.hardware.error("Audio engine restart failed on configuration change: \(error.localizedDescription, privacy: .public)")
            showAudioDeviceBanner("Audio engine restart failed: \(error.localizedDescription)")
        }

        updateMatrix(persistBusRouting: false)
        syncMixState()

        if wasPlaying && isEngineRunning {
            seek(to: savedTime)
            play()
        }
        if sampleRateChanged {
            showAudioDeviceBanner("Audio interface reconfigured (\(Int(lastConfiguredSampleRate)) Hz)")
        }
    }

    func renormalizeLoadedBuffersForNewCanonicalFormat() {
        let canonicalFormat = getCanonicalProcessingFormat()
        let targetSR = canonicalFormat.sampleRate
        let stub = makeSilentStub(format: canonicalFormat)

        for (trackId, buf) in pristineMasterBuffers where abs(buf.format.sampleRate - targetSR) >= 1.0 {
            pristineMasterBuffers[trackId] = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
        }
        for (songId, buf) in uploadedClickBuffers where buf.frameLength > 100 && abs(buf.format.sampleRate - targetSR) >= 1.0 {
            uploadedClickBuffers[songId] = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
        }
        for (songId, buf) in uploadedGuideBuffers where buf.frameLength > 100 && abs(buf.format.sampleRate - targetSR) >= 1.0 {
            uploadedGuideBuffers[songId] = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
        }

        generatedClickBuffers.removeAll()
        generatedGuideBuffers.removeAll()
        generatedGuideLoopStates.removeAll()
        songTransposedBuffersCache.removeAll()

        for (songId, entries) in songBuffersCache {
            var updated: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = []
            updated.reserveCapacity(entries.count)
            for (trk, buf) in entries {
                if buf.frameLength <= 100, let stub {
                    updated.append((trk, stub))
                } else if abs(buf.format.sampleRate - targetSR) >= 1.0 {
                    updated.append((trk, normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)))
                } else {
                    updated.append((trk, buf))
                }
            }
            songBuffersCache[songId] = updated
        }

        for (trackId, ch) in channels {
            if let pristine = pristineMasterBuffers[trackId] {
                ch.buffer = pristine
            } else if let buf = ch.buffer, buf.frameLength > 100, abs(buf.format.sampleRate - targetSR) >= 1.0 {
                ch.buffer = normalizeBufferToCanonical(buffer: buf, targetFormat: canonicalFormat)
            } else if let buf = ch.buffer, buf.frameLength <= 100, let stub {
                ch.buffer = stub
            }
        }

        if !currentSong.excludesClickAndGuide {
            if currentSong.clickSource == .generated {
                regenerateClickTrack()
            } else {
                applyClickBuffer()
            }
            if currentSong.guideSource == .generated {
                regenerateGuideTrack()
            } else {
                applyGuideBuffer()
            }
        }
        if currentSong.transposeSemitones != 0 || currentSong.isTempoShifted {
            preRenderTranspose(forSongIndex: currentSongIndex)
        }
        updateSMPTEState(persistDevicePreset: false)
    }
    
    public func validateBusOutputRouting(maxChannels: Int) {
        let syntheticDevice = AudioOutputDevice(id: 0, uid: "", name: "", outputChannelCount: max(2, maxChannels))
        let (stereo, mono) = deviceManager.availableOutputs(for: syntheticDevice)
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
    
}
