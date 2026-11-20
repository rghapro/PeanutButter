import Testing
import Foundation
import AVFoundation
@testable import PeanutButter

@Suite("Memory Window & Async Song Switching", .serialized)
@MainActor
struct MemoryWindowAndAsyncHydrationTests {

    private func makeFreshEngine() -> MultitrackAudioEngine {
        let savedLastSession = UserDefaults.standard.object(forKey: "Playback_LastSessionPath")
        UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                UserDefaults.standard.set(v, forKey: "Playback_LastSessionPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        engine.stop()
        engine.currentSessionURL = nil
        engine.songBuffersCache.removeAll()
        engine.memoryEvictedSongIds.removeAll()
        engine.songTrackMetadataBackup.removeAll()
        engine.songWaveformCache.removeAll()
        engine.songTransposedBuffersCache.removeAll()
        engine.generatedClickBuffers.removeAll()
        engine.generatedGuideBuffers.removeAll()
        engine.generatedGuideLoopStates.removeAll()
        engine.uploadedClickBuffers.removeAll()
        engine.uploadedGuideBuffers.removeAll()
        engine.currentSetlist = Setlist(name: "Test Setlist", songs: [])
        engine.currentSongIndex = 0
        return engine
    }

    private func makeTestPCMBuffer(
        frequency: Float = 440.0,
        amplitude: Float = 0.25,
        durationSeconds: TimeInterval = 0.5,
        sampleRate: Double = 48_000.0
    ) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frameCount = AVAudioFrameCount(max(1, Int(round(durationSeconds * sampleRate))))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let ch0 = try #require(buffer.floatChannelData?[0])
        let ch1 = try #require(buffer.floatChannelData?[1])
        let phaseInc = 2.0 * Float.pi * frequency / Float(sampleRate)
        for i in 0..<Int(frameCount) {
            let sample = amplitude * sin(phaseInc * Float(i))
            ch0[i] = sample
            ch1[i] = sample
        }
        return buffer
    }

    private func writeTempM4A(
        in directory: URL,
        name: String,
        sampleRate: Double,
        frequency: Float = 330.0
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let buf = try makeTestPCMBuffer(frequency: frequency, durationSeconds: 0.4, sampleRate: sampleRate)
        try PlaybackFileManager.shared.writeCompressedStem(buf, to: url)
        return url
    }

    private func makeStubBuffer(sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buf.frameLength = 1
        return buf
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 5.0,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - 1. Physical RAM Policy Scaling

    @Test
    func memoryWindowPolicyScalesByPhysicalRAM() {
        let gib: UInt64 = 1_073_741_824

        let policy16GB = MemoryWindowPolicy.forPhysicalMemory(16 * gib)
        #expect(policy16GB.maxResidentSongs == 3)

        let policy32GB = MemoryWindowPolicy.forPhysicalMemory(32 * gib)
        #expect(policy32GB.maxResidentSongs == 6)

        let policy64GB = MemoryWindowPolicy.forPhysicalMemory(64 * gib)
        #expect(policy64GB.maxResidentSongs == 12)
    }

    // MARK: - 2. Sliding-Window Eviction Protects Active, Next, Prev, Waveforms & Metadata

    @Test
    func slidingWindowEvictsDistantSongsWhileProtectingActiveNextPrevAndWaveforms() throws {
        let engine = makeFreshEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pb_mem_win_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        engine.memoryWindowPolicyOverride = MemoryWindowPolicy(maxResidentSongs: 3, softPCMByteBudget: 3_500_000_000)
        let sr = engine.getCanonicalProcessingFormat().sampleRate

        var songs: [Song] = []
        var tracksBySong: [UUID: StemTrack] = [:]

        for idx in 0..<6 {
            let m4aURL = try writeTempM4A(in: tempDir, name: "song_\(idx)_keys.m4a", sampleRate: sr, frequency: Float(220 + idx * 40))
            let song = Song(
                title: "Song \(idx)",
                artist: "Test",
                bpm: 120.0,
                musicalKey: "C",
                sections: [SongSection(name: "Intro", startTime: 0.0, duration: 0.4)],
                stemURLs: [m4aURL],
                excludesClickAndGuide: true
            )
            let track = StemTrack(
                name: "Keys \(idx)",
                role: .stem,
                fileURL: m4aURL,
                volume: 0.42,
                isMuted: (idx % 2 == 0),
                assignedBusName: "Keys"
            )
            track.waveformPeaks = [0.2, 0.5, 0.8]
            let fullBuf = try makeTestPCMBuffer(frequency: Float(220 + idx * 40), durationSeconds: 0.4, sampleRate: sr)
            engine.songBuffersCache[song.id] = [(track, fullBuf)]
            engine.songWaveformCache[song.id] = ([0.1, 0.4, 0.9], nil)
            engine.generatedClickBuffers[song.id] = fullBuf
            songs.append(song)
            tracksBySong[song.id] = track
        }

        engine.currentSetlist = Setlist(name: "6 Song Set", songs: songs)
        engine.selectSongInSetlist(at: 2)
        engine.rebalanceSlidingWindowMemory(prefetchNeighbors: false)

        // Window centered on index 2 keeps [2 (active), 3 (next), 1 (prev)]
        for protectedIdx in [1, 2, 3] {
            let sid = songs[protectedIdx].id
            #expect(!engine.memoryEvictedSongIds.contains(sid), "Song \(protectedIdx) should stay resident in 3-song window")
            let cachedBuf = try #require(engine.songBuffersCache[sid]?.first?.buffer)
            #expect(cachedBuf.frameLength > 100, "Song \(protectedIdx) should retain full PCM buffer")
        }

        // Distant songs [0, 4, 5] must be evicted to stubs, keeping waveforms & metadata intact
        for distantIdx in [0, 4, 5] {
            let sid = songs[distantIdx].id
            #expect(engine.memoryEvictedSongIds.contains(sid), "Distant song \(distantIdx) should be evicted")
            let stubBuf = try #require(engine.songBuffersCache[sid]?.first?.buffer)
            #expect(stubBuf.frameLength <= 1, "Distant song \(distantIdx) buffer should be stubbed")
            #expect(engine.generatedClickBuffers[sid] == nil, "Distant song generated click should be cleared")
            #expect(engine.songWaveformCache[sid]?.peaks.isEmpty == false, "Waveform peaks must stay cached for distant song \(distantIdx)")

            let cachedTrack = try #require(engine.songBuffersCache[sid]?.first?.track)
            #expect(cachedTrack.name == "Keys \(distantIdx)")
            #expect(abs(cachedTrack.volume - 0.42) < 1e-4)
            #expect(cachedTrack.isMuted == (distantIdx % 2 == 0))
            #expect(cachedTrack.assignedBusName == "Keys")
        }
    }

    // MARK: - 3. Rapid Song Switching Hydrates Asynchronously & Cancels Skipped Songs

    @Test
    func rapidSongSwitchHydratesAsynchronouslyAndCancelsSkippedSongs() async throws {
        let engine = makeFreshEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pb_rapid_switch_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let stub = try makeStubBuffer(sampleRate: sr)

        var songs: [Song] = []
        for idx in 0..<5 {
            let m4aURL = try writeTempM4A(in: tempDir, name: "rapid_\(idx).m4a", sampleRate: sr)
            let song = Song(
                title: "Rapid \(idx)",
                artist: "Test",
                bpm: 120.0,
                musicalKey: "G",
                sections: [SongSection(name: "Verse", startTime: 0.0, duration: 0.4)],
                stemURLs: [m4aURL],
                excludesClickAndGuide: true
            )
            let track = StemTrack(name: "Guitar \(idx)", role: .stem, fileURL: m4aURL, volume: 0.75, isMuted: false)
            if idx < 2 {
                let fullBuf = try makeTestPCMBuffer(durationSeconds: 0.4, sampleRate: sr)
                engine.songBuffersCache[song.id] = [(track, fullBuf)]
            } else {
                engine.songBuffersCache[song.id] = [(track, stub)]
                engine.memoryEvictedSongIds.insert(song.id)
            }
            songs.append(song)
        }

        engine.currentSetlist = Setlist(name: "Rapid Set", songs: songs)
        engine.selectSongInSetlist(at: 0)

        // Rapidly click through 2 -> 3 -> 4
        engine.selectSongInSetlist(at: 2)
        engine.selectSongInSetlist(at: 3)
        engine.selectSongInSetlist(at: 4)

        let song4Id = songs[4].id
        #expect(engine.currentSong.id == song4Id)
        #expect(engine.isCurrentSongHydrating, "Switching to evicted Song 4 should trigger async hydration without blocking MainActor")

        // Mutate live track mix state while hydration is in flight
        let liveTrack = try #require(engine.tracks.first(where: { $0.name == "Guitar 4" }))
        liveTrack.volume = 0.33
        liveTrack.isMuted = true

        let finished = await waitUntil(timeoutSeconds: 5.0) {
            !engine.isCurrentSongHydrating && !engine.memoryEvictedSongIds.contains(song4Id)
        }
        #expect(finished, "Song 4 should finish hydrating within timeout")

        let hydratedBuf = try #require(engine.songBuffersCache[song4Id]?.first(where: { $0.track.id == liveTrack.id })?.buffer)
        #expect(hydratedBuf.frameLength > 100)
        #expect(abs(liveTrack.volume - 0.33) < 1e-4, "User fader edits made during async hydration must persist")
        #expect(liveTrack.isMuted == true, "User mute edits made during async hydration must persist")

        // Skipped intermediate songs should still be evicted (cancelled before wasting decode/cache work)
        #expect(engine.memoryEvictedSongIds.contains(songs[2].id))
        #expect(engine.memoryEvictedSongIds.contains(songs[3].id))
    }

    // MARK: - 4. Queued Play During Async Hydration Auto-Starts & Cancels Cleanly

    @Test
    func queuedPlayDuringAsyncHydrationAutoStartsAndCancelsOnStop() async throws {
        let engine = makeFreshEngine()
        defer {
            engine.stop()
            engine.cancelAllSessionBackgroundTasks()
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pb_queued_play_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let stub = try makeStubBuffer(sampleRate: sr)

        var songs: [Song] = []
        for idx in 0..<4 {
            let m4aURL = try writeTempM4A(in: tempDir, name: "qplay_\(idx).m4a", sampleRate: sr)
            let song = Song(
                title: "QPlay \(idx)",
                artist: "Test",
                bpm: 120.0,
                musicalKey: "D",
                sections: [SongSection(name: "Intro", startTime: 0.0, duration: 0.4)],
                stemURLs: [m4aURL],
                excludesClickAndGuide: true
            )
            let track = StemTrack(name: "Synth \(idx)", role: .stem, fileURL: m4aURL)
            if idx == 0 {
                let fullBuf = try makeTestPCMBuffer(durationSeconds: 0.4, sampleRate: sr)
                engine.songBuffersCache[song.id] = [(track, fullBuf)]
            } else {
                engine.songBuffersCache[song.id] = [(track, stub)]
                engine.memoryEvictedSongIds.insert(song.id)
            }
            songs.append(song)
        }

        engine.currentSetlist = Setlist(name: "Queued Play Set", songs: songs)
        engine.selectSongInSetlist(at: 0)

        // Part A: Queue Play during hydration then cancel via togglePlayPause
        engine.selectSongInSetlist(at: 2)
        #expect(engine.isCurrentSongHydrating)
        engine.play()
        #expect(engine.pendingPlayAfterHydration == true)
        #expect(engine.showDownloadingWarning == false)
        engine.togglePlayPause()
        #expect(engine.pendingPlayAfterHydration == false)

        let partADone = await waitUntil(timeoutSeconds: 5.0) { !engine.isCurrentSongHydrating }
        #expect(partADone)
        #expect(engine.playbackState == .stopped, "Cancelled queued Play must stay stopped after hydration completes")

        // Part B: Queue Play during hydration and let it auto-start on completion
        engine.selectSongInSetlist(at: 3)
        #expect(engine.isCurrentSongHydrating)
        engine.play()
        #expect(engine.pendingPlayAfterHydration == true)

        let started = await waitUntil(timeoutSeconds: 5.0) {
            !engine.isCurrentSongHydrating && engine.pendingPlayAfterHydration == false
        }
        #expect(started)
        #expect(engine.playbackState == .playing, "Playback must auto-start once async hydration completes")
        engine.stop()
        #expect(engine.playbackState == .stopped)
    }

    // MARK: - 5. Non-Blocking Next-Song Staging & Background Prefetch

    @Test
    func buildNextSongRenderStateDoesNotSynchronouslyRehydrateEvictedNextSong() async throws {
        let engine = makeFreshEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pb_prefetch_next_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let stub = try makeStubBuffer(sampleRate: sr)

        let s0URL = try writeTempM4A(in: tempDir, name: "s0.m4a", sampleRate: sr)
        let s1URL = try writeTempM4A(in: tempDir, name: "s1.m4a", sampleRate: sr)

        let savedSMPTEEnabled = UserDefaults.standard.object(forKey: "Playback_SMPTEEnabled")
        let savedSMPTERate = UserDefaults.standard.object(forKey: "Playback_SMPTEFrameRate")
        let savedSMPTECh = UserDefaults.standard.object(forKey: "Playback_SMPTEOutputChannel")
        defer {
            if let v = savedSMPTEEnabled { UserDefaults.standard.set(v, forKey: "Playback_SMPTEEnabled") } else { UserDefaults.standard.removeObject(forKey: "Playback_SMPTEEnabled") }
            if let v = savedSMPTERate { UserDefaults.standard.set(v, forKey: "Playback_SMPTEFrameRate") } else { UserDefaults.standard.removeObject(forKey: "Playback_SMPTEFrameRate") }
            if let v = savedSMPTECh { UserDefaults.standard.set(v, forKey: "Playback_SMPTEOutputChannel") } else { UserDefaults.standard.removeObject(forKey: "Playback_SMPTEOutputChannel") }
        }
        engine.isSMPTEEnabled = true
        engine.smpteFrameRate = .fps30
        engine.smpteOutputChannel = "Out 4"
        engine.updateSMPTEState(persistDevicePreset: false)

        let cueNext = SMPTECue(time: 0.0, timeStartHours: 1, timeStartMinutes: 10, timeStartSeconds: 0, timeStartFrames: 0)
        let song0 = Song(
            title: "Song 0",
            artist: "Test",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Outro", startTime: 0.0, duration: 0.4)],
            stemURLs: [s0URL],
            transitionType: .autoLink,
            excludesClickAndGuide: true
        )
        let song1 = Song(
            title: "Song 1",
            artist: "Test",
            bpm: 120.0,
            musicalKey: "D",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 0.4)],
            stemURLs: [s1URL],
            smpteCue: cueNext,
            excludesClickAndGuide: true
        )

        let s0Buf = try makeTestPCMBuffer(durationSeconds: 0.4, sampleRate: sr)
        engine.songBuffersCache[song0.id] = [(StemTrack(name: "Keys", role: .stem, fileURL: s0URL), s0Buf)]
        engine.songBuffersCache[song1.id] = [(StemTrack(name: "Keys", role: .stem, fileURL: s1URL), stub)]
        engine.memoryEvictedSongIds.insert(song1.id)
        engine.currentSetlist = Setlist(name: "AutoLink Prefetch", songs: [song0, song1])

        engine.selectSongInSetlist(at: 0)

        // Must NOT have synchronously rehydrated Song 1 on MainActor inside selectSongInSetlist
        #expect(engine.memoryEvictedSongIds.contains(song1.id))

        // Background prefetch from syncMixState / buildNextSongRenderState must hydrate Song 1 & stage it into mixState
        let prefetched = await waitUntil(timeoutSeconds: 5.0) {
            !engine.memoryEvictedSongIds.contains(song1.id)
        }
        #expect(prefetched, "Background prefetch should rehydrate Song 1 for auto-link transition")
        let snap = engine.mixState.currentSMPTESnapshot()
        #expect(snap.nextHasCue && abs(snap.nextCueStartSeconds - 4200.0) < 1e-6)
    }

    // MARK: - 6. Generated Click Cannot Mask Unhydrated Evicted Musical Stems

    @Test
    func evictedSongRetainsEvictionMarkerWhenGeneratedClickExists() throws {
        let engine = makeFreshEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pb_evict_guard_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let stub = try makeStubBuffer(sampleRate: sr)
        let clickBuf = try makeTestPCMBuffer(durationSeconds: 0.5, sampleRate: sr)
        let keysURL = try writeTempM4A(in: tempDir, name: "keys.m4a", sampleRate: sr)

        let clickTrack = StemTrack(name: "Click", role: .click, fileURL: nil)
        let keysTrack = StemTrack(name: "Keys", role: .stem, fileURL: keysURL)

        let items: [(track: StemTrack, buffer: AVAudioPCMBuffer)] = [
            (clickTrack, clickBuf),
            (keysTrack, stub)
        ]

        #expect(
            engine.hasAllRequiredAudioHydrated(in: items) == false,
            "Generated Click buffer must not treat a song with stubbed musical stems as hydrated"
        )
    }
}
