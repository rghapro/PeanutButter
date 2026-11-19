import Testing
import Foundation
import AVFoundation
@testable import PeanutButter

@Suite("Pass 6 Audit Tests")
struct Pass6AuditTests {

    private func makeTestPCMBuffer(
        frequency: Float = 440.0,
        frameCount: AVAudioFrameCount = 4_800,
        sampleRate: Double = 48_000.0
    ) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let ch0 = try #require(buffer.floatChannelData?[0])
        let ch1 = try #require(buffer.floatChannelData?[1])
        let phaseInc = 2.0 * Float.pi * frequency / Float(sampleRate)
        for i in 0..<Int(frameCount) {
            let sample = 0.25 * sin(phaseInc * Float(i))
            ch0[i] = sample
            ch1[i] = sample * 0.8
        }
        return buffer
    }

    // MARK: - P4-01: Stem Export Failures Must Propagate Without Corrupting Saved Package

    @Test
    func exportSessionPropagatesStemWriteFailureWithoutCorruptingExistingPackage() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p6_export_err_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        defer {
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempRoot)
        }

        let buf = try makeTestPCMBuffer()
        let song = Song(title: "Anchor Song", artist: "Band", bpm: 120.0, musicalKey: "C")
        let goodTrack = StemTrack(name: "Drums", role: .stem)
        goodTrack.duration = 0.1
        goodTrack.waveformPeaks = [0.2, 0.4, 0.6]
        createdTrackIds.append(goodTrack.id)

        let sessionURL = tempRoot.appendingPathComponent("SafeSession.pbsession", isDirectory: true)
        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "Safe Set", songs: [song]),
            currentSongIndex: 0,
            allSongsData: [(song: song, tracks: [goodTrack], buffers: [goodTrack.id: buf])],
            to: sessionURL,
            asDirectoryPackage: true
        )

        let missingFileURL = tempRoot.appendingPathComponent("does_not_exist_anywhere.wav")
        let brokenTrack = StemTrack(name: "MissingSynth", role: .stem, fileURL: missingFileURL)
        brokenTrack.duration = 0.1
        createdTrackIds.append(brokenTrack.id)

        let stub = try #require(AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: 1))
        stub.frameLength = 1

        #expect(throws: (any Error).self) {
            try PlaybackFileManager.shared.exportSession(
                setlist: Setlist(name: "Safe Set", songs: [song]),
                currentSongIndex: 0,
                allSongsData: [
                    (
                        song: song,
                        tracks: [goodTrack, brokenTrack],
                        buffers: [goodTrack.id: buf, brokenTrack.id: stub]
                    )
                ],
                to: sessionURL,
                asDirectoryPackage: true
            )
        }

        // Prior good session must still load intact with 1 healthy stem and zero broken tracks
        let reloaded = try PlaybackFileManager.shared.loadSession(from: sessionURL)
        #expect(reloaded.songsData.count == 1)
        #expect(reloaded.songsData[0].tracks.count == 1)
        #expect(reloaded.songsData[0].tracks[0].0.id == goodTrack.id)
        #expect(reloaded.songsData[0].tracks[0].1.frameLength > 100)
    }

    // MARK: - P4-02: Pad Player Housekeeping Drains & Publishes Stopped State Without DisplayLink

    @Test
    @MainActor
    func padPlayerDrainsRetiredBuffersAndUpdatesStateWithoutDisplayLink() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        let buf = try makeTestPCMBuffer(frequency: 220.0, frameCount: 4_800, sampleRate: 48_000.0)

        let padPlayer = PadPlayerEngine()
        padPlayer.fadeOutSeconds = 0.25
        padPlayer.setProcessingFormat(format)
        padPlayer.loadBufferForTesting(buf, key: "C", immediateGain: 1.0)
        padPlayer.syncUIStateAndDrainRetiredBuffers()
        #expect(padPlayer.isPlaying)

        // Trigger fade-out and drive RT render until fadeGain reaches 0 without calling tickMeters()
        padPlayer.stop()

        let blockFrames = 512
        var ch0 = [Float](repeating: 0.0, count: blockFrames)
        var ch1 = [Float](repeating: 0.0, count: blockFrames)
        ch0.withUnsafeMutableBufferPointer { p0 in
            ch1.withUnsafeMutableBufferPointer { p1 in
                var rawPtrs: [UnsafeMutablePointer<Float>] = [p0.baseAddress!, p1.baseAddress!]
                rawPtrs.withUnsafeMutableBufferPointer { ptrBuf in
                    let immutableBuf = UnsafeBufferPointer<UnsafeMutablePointer<Float>>(start: ptrBuf.baseAddress, count: 2)
                    for _ in 0..<40 {
                        padPlayer.renderDirect(frameCount: blockFrames, channelPointers: immutableBuf)
                        if !padPlayer.hasActiveAudioToRender { break }
                    }
                }
            }
        }
        #expect(!padPlayer.hasActiveAudioToRender)

        // Wait briefly for PadPlayerEngine's MainActor housekeeping timer (simulating occluded window where CADisplayLink is paused)
        for _ in 0..<25 {
            if !padPlayer.isPlaying { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!padPlayer.isPlaying)
        padPlayer.detach()
    }

    // MARK: - P4-03 (Part 1): Move to Applications Guard Rejects Unsigned Dev Bundles

    @Test
    func moveToApplicationsVerifyNotarizedBundleRejectsUnsignedBundle() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p6_appsig_\(UUID().uuidString)", isDirectory: true)
        let fakeApp = tempRoot.appendingPathComponent("PeanutButter.app", isDirectory: true)
        let contentsDir = fakeApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.peanutbutter.app"],
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

        #expect(!AppUpdateManager.verifyNotarizedProductionBundle(at: fakeApp))
    }

    // MARK: - P4-04: SMPTE Updates on setBPM, Section Reindex, Next-Song Arrangement & Overlap Transition

    @Test
    @MainActor
    func smpteUpdatesOnSetBPMNextSongArrangementAndOverlapTransition() throws {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "Playback_SMPTEEnabled")
        let savedRate = defaults.object(forKey: "Playback_SMPTEFrameRate")
        let savedCh = defaults.object(forKey: "Playback_SMPTEOutputChannel")
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedEnabled { defaults.set(v, forKey: "Playback_SMPTEEnabled") } else { defaults.removeObject(forKey: "Playback_SMPTEEnabled") }
            if let v = savedRate { defaults.set(v, forKey: "Playback_SMPTEFrameRate") } else { defaults.removeObject(forKey: "Playback_SMPTEFrameRate") }
            if let v = savedCh { defaults.set(v, forKey: "Playback_SMPTEOutputChannel") } else { defaults.removeObject(forKey: "Playback_SMPTEOutputChannel") }
            if let v = savedLastSession { defaults.set(v, forKey: "Playback_LastSessionPath") } else { defaults.removeObject(forKey: "Playback_LastSessionPath") }
        }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        engine.currentSongIndex = 0
        engine.isSMPTEEnabled = true
        engine.smpteFrameRate = .fps30
        engine.smpteOutputChannel = "Out 4"
        engine.updateSMPTEState(persistDevicePreset: false)

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let bufFrames = AVAudioFrameCount(max(4_800, Int(round(8.0 * sr))))
        let buf = try makeTestPCMBuffer(frequency: 330.0, frameCount: bufFrames, sampleRate: sr)

        let introSec = SongSection(name: "Intro", startTime: 0.0, duration: 4.0)
        let chorusSec = SongSection(name: "Chorus", startTime: 4.0, duration: 4.0)
        let cue1 = SMPTECue(time: 4.0, timeStartHours: 1, timeStartMinutes: 0, timeStartSeconds: 0, timeStartFrames: 0)

        let song1 = Song(
            title: "Song One",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [introSec, chorusSec],
            smpteCue: cue1,
            transitionType: .overlap
        )

        let s2CountSec = SongSection(name: "Count In", startTime: 0.0, duration: 2.0)
        let s2IntroSec = SongSection(name: "Intro", startTime: 2.0, duration: 4.0)
        let altArrangement = SavedArrangement(
            name: "With Timecode",
            sections: [s2CountSec, s2IntroSec],
            midiCues: [],
            directionalCues: [],
            automationPoints: [],
            smpteCue: SMPTECue(time: 0.0, timeStartHours: 2, timeStartMinutes: 0, timeStartSeconds: 0, timeStartFrames: 0)
        )
        let song2 = Song(
            title: "Song Two",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "D",
            sections: [s2CountSec, s2IntroSec],
            savedArrangements: [altArrangement],
            activeArrangementId: nil,
            smpteCue: nil
        )

        let t1 = StemTrack(name: "Keys", role: .stem)
        let t2 = StemTrack(name: "Keys", role: .stem)
        engine.currentSetlist = Setlist(name: "P6 SMPTE Set", songs: [song1, song2])
        engine.songBuffersCache[song1.id] = [(t1, buf)]
        engine.songBuffersCache[song2.id] = [(t2, buf)]
        engine.loadSong(song1)

        // 1. setBPM refreshes current song BPM and SMPTE state cleanly
        engine.setBPM(125.0, forSongIndex: 0)
        #expect(abs(engine.currentSong.bpm - 125.0) < 1e-6)
        #expect(engine.mixState.currentSMPTESnapshot().hasCue)

        // 2. Reordering sections + reindexArrangement shifts section-bound SMPTECue time & mixState cueTimelineFrame
        engine.ensureCuesTaggedToSections(in: &engine.currentSong, rebindByCurrentTime: true)
        #expect(engine.currentSong.smpteCue?.sectionId == chorusSec.id)
        engine.currentSong.sections = [chorusSec, introSec]
        engine.reindexArrangement()
        #expect(abs((engine.currentSong.smpteCue?.time ?? -1.0) - 0.0) < 1e-6)
        #expect(engine.mixState.currentSMPTESnapshot().cueTimelineFrame == 0)

        // Move cue back to t = 7.0s (past the overlap boundary so overlap handover isolates Song B's cue at t = 6.0s)
        engine.moveSMPTECue(to: 7.0, snapToGrid: false)
        #expect(!engine.mixState.currentSMPTESnapshot().nextHasCue)

        // 3. Switching Song B's arrangement while Song A is loaded updates staged nextHasSMPTECue
        engine.selectArrangement(id: altArrangement.id, forSongIndex: 1)
        let afterArrSnap = engine.mixState.currentSMPTESnapshot()
        #expect(afterArrSnap.nextHasCue)
        #expect(abs(afterArrSnap.nextCueStartSeconds - 7200.0) < 1e-6)

        // 4. Inside Overlap transition window ([6.0s ..< 8.0s)), renderLTC immediately outputs Song B's 02:00:00:00 LTC on Out 4
        engine.mixState.setPlayhead(seconds: 6.0, resumePlaying: true)
        let frameCount = 512
        let chCount = 4
        var c0 = [Float](repeating: 0.0, count: frameCount)
        var c1 = [Float](repeating: 0.0, count: frameCount)
        var c2 = [Float](repeating: 0.0, count: frameCount)
        var c3 = [Float](repeating: 0.0, count: frameCount)
        let ablSize = MemoryLayout<AudioBufferList>.size + (chCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawABL.deallocate() }
        let abl = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)
        abl.pointee.mNumberBuffers = UInt32(chCount)

        c0.withUnsafeMutableBufferPointer { p0 in
            c1.withUnsafeMutableBufferPointer { p1 in
                c2.withUnsafeMutableBufferPointer { p2 in
                    c3.withUnsafeMutableBufferPointer { p3 in
                        let bufs = UnsafeMutableAudioBufferListPointer(abl)
                        let ptrs = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!, p3.baseAddress!]
                        for idx in 0..<chCount {
                            bufs[idx].mNumberChannels = 1
                            bufs[idx].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                            bufs[idx].mData = UnsafeMutableRawPointer(ptrs[idx])
                        }
                        var isSil = ObjCBool(false)
                        engine.mixState.render(isSilence: &isSil, frameCount: frameCount, audioBufferList: abl)
                    }
                }
            }
        }

        #expect(c3.contains(where: { abs($0) > 0.1 }), "Overlap transition window must transmit Song B LTC starting at transitionStartFrame")
    }

    // MARK: - P4-06: CoreMIDI Input Fast Filter Blocks Unmapped Events Off Main Thread

    @Test
    @MainActor
    func midiInputFastFilterBlocksUnmappedMessagesUnlessLearning() {
        let mgr = MIDIMappingManager.shared
        let saved = mgr.mappings
        defer {
            mgr.setMappingsInMemoryForTesting(saved)
            mgr.setLearningModeActive(false)
        }

        mgr.setMappingsInMemoryForTesting([:])
        mgr.setLearningModeActive(false)
        #expect(!MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 64, isNote: false))
        #expect(!MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 60, isNote: true))

        mgr.setMappingsInMemoryForTesting([
            "fade_out": MIDIMappingItem(targetId: "fade_out", channel: 1, noteOrCC: 64, isNote: false)
        ])
        #expect(MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 64, isNote: false))
        #expect(!MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 65, isNote: false))

        mgr.setLearningModeActive(true)
        #expect(MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 65, isNote: false))
        mgr.setLearningModeActive(false)
        #expect(!MIDIMappingManager.shouldForwardForTesting(channel: 1, number: 65, isNote: false))
    }

    // MARK: - P4-07: zipFolder & Target-Staged Stem Encoding Round-Trip Cleanly

    @Test
    func zipFolderArchiveRoundTripSucceedsWithoutPipeBlock() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p6_zip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        defer {
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempRoot)
        }

        let buf = try makeTestPCMBuffer()
        let song = Song(title: "Zip Song", artist: "Band", bpm: 120.0, musicalKey: "E")
        let track = StemTrack(name: "Bass", role: .stem)
        track.duration = 0.1
        track.waveformPeaks = [0.1, 0.5, 0.9]
        createdTrackIds.append(track.id)

        let archiveURL = tempRoot.appendingPathComponent("ZipSong.pbsong")
        try PlaybackFileManager.shared.exportSongPackage(
            song: song,
            tracks: [track],
            buffers: [track.id: buf],
            to: archiveURL,
            asDirectoryPackage: false
        )
        #expect(fm.fileExists(atPath: archiveURL.path))

        let loaded = try PlaybackFileManager.shared.loadSongPackage(from: archiveURL)
        #expect(loaded.song.id == song.id)
        #expect(loaded.tracks.count == 1)
        #expect(loaded.tracks[0].0.waveformPeaks == [0.1, 0.5, 0.9])
        #expect(loaded.tracks[0].1.frameLength > 100)
    }
}
