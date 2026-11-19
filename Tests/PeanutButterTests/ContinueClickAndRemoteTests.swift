import Testing
import Foundation
import AVFoundation
import CoreAudio
@testable import PeanutButter

@Suite("Continue Click & Remote Tests", .serialized)
struct ContinueClickAndRemoteTests {

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

    private func renderMixBlocks(
        mixState: RealTimeMixEngineState,
        blockCount: Int,
        frameCount: Int = 512
    ) -> [Float] {
        var maxPerChannel = [Float](repeating: 0.0, count: 4)
        var c0 = [Float](repeating: 0.0, count: frameCount)
        var c1 = [Float](repeating: 0.0, count: frameCount)
        var c2 = [Float](repeating: 0.0, count: frameCount)
        var c3 = [Float](repeating: 0.0, count: frameCount)
        let ablSize = MemoryLayout<AudioBufferList>.size + 3 * MemoryLayout<AudioBuffer>.size
        let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawABL.deallocate() }
        let abl = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)

        for _ in 0..<blockCount {
            for i in 0..<frameCount {
                c0[i] = 0.0
                c1[i] = 0.0
                c2[i] = 0.0
                c3[i] = 0.0
            }
            abl.pointee.mNumberBuffers = 4
            c0.withUnsafeMutableBufferPointer { p0 in
                c1.withUnsafeMutableBufferPointer { p1 in
                    c2.withUnsafeMutableBufferPointer { p2 in
                        c3.withUnsafeMutableBufferPointer { p3 in
                            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
                            let ptrs = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!, p3.baseAddress!]
                            for ch in 0..<4 {
                                ablPtr[ch].mNumberChannels = 1
                                ablPtr[ch].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                                ablPtr[ch].mData = UnsafeMutableRawPointer(ptrs[ch])
                            }
                            var isSilence = ObjCBool(false)
                            mixState.render(isSilence: &isSilence, frameCount: frameCount, audioBufferList: abl)
                        }
                    }
                }
            }
            for i in 0..<frameCount {
                maxPerChannel[0] = max(maxPerChannel[0], abs(c0[i]))
                maxPerChannel[1] = max(maxPerChannel[1], abs(c1[i]))
                maxPerChannel[2] = max(maxPerChannel[2], abs(c2[i]))
                maxPerChannel[3] = max(maxPerChannel[3], abs(c3[i]))
            }
        }
        return maxPerChannel
    }

    @Test
    @MainActor
    func continueClickPersistenceBackwardsCompatAndAutoReset() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_cc_persist_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempRoot)
        }

        // 1. Backwards-compatible decoding when continueClick key is absent
        let baseSong = Song(
            title: "Continue Click Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "G",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 4.0)],
            transitionType: .cueNextSong,
            continuePad: true,
            continueClick: true
        )
        let encoded = try JSONEncoder().encode(baseSong)
        var obj = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj.removeValue(forKey: "continueClick")
        let strippedData = try JSONSerialization.data(withJSONObject: obj)
        let legacyDecoded = try JSONDecoder().decode(Song.self, from: strippedData)
        #expect(!legacyDecoded.continueClick)
        #expect(legacyDecoded.continuePad)

        // 2. .pbsong and .pbsession round-trip persistence
        let buf = try makeTestPCMBuffer(frameCount: 4_800, sampleRate: 48_000.0)
        let track = StemTrack(name: "Keys", role: .stem)
        track.duration = 0.1
        createdTrackIds.append(track.id)

        let songURL = tempRoot.appendingPathComponent("ContinueClick.pbsong")
        try PlaybackFileManager.shared.exportSongPackage(
            song: baseSong,
            tracks: [track],
            buffers: [track.id: buf],
            to: songURL,
            asDirectoryPackage: true
        )
        let loadedSongPkg = try PlaybackFileManager.shared.loadSongPackage(from: songURL)
        #expect(loadedSongPkg.song.continueClick)

        let song2 = Song(
            title: "Second Song",
            artist: "Band",
            bpm: 132.0,
            musicalKey: "A",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 4.0)]
        )
        let sessionURL = tempRoot.appendingPathComponent("ContinueClick.pbsession")
        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "CC Set", songs: [baseSong, song2]),
            currentSongIndex: 0,
            allSongsData: [
                (song: baseSong, tracks: [track], buffers: [track.id: buf]),
                (song: song2, tracks: [], buffers: [:])
            ],
            transposedBuffersMap: [:],
            to: sessionURL,
            asDirectoryPackage: true
        )
        let loadedSession = try PlaybackFileManager.shared.loadSession(from: sessionURL)
        #expect(loadedSession.setlist.songs.count == 2)
        #expect(loadedSession.setlist.songs[0].continueClick)
        #expect(!loadedSession.setlist.songs[1].continueClick)

        // 3. Switching to autoLink, overlap, or crossfade resets continueClick to false
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }
        engine.currentSetlist = Setlist(name: "Reset Test", songs: [baseSong, song2])
        engine.currentSongIndex = 0
        engine.loadSong(baseSong)

        for incompatible in [SongTransitionType.autoLink, .overlap, .crossfade] {
            engine.updateSongTransition(at: 0, type: .cueNextSong)
            engine.updateSongContinueClick(at: 0, continueClick: true)
            #expect(engine.currentSetlist.songs[0].continueClick)
            #expect(engine.currentSong.continueClick)

            engine.updateSongTransition(at: 0, type: incompatible)
            #expect(!engine.currentSetlist.songs[0].continueClick)
            #expect(!engine.currentSong.continueClick)
        }
    }

    @Test
    func clickGeneratorEndCutoffSuppression() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        let gen = ClickGenerator()
        let sections = [
            SongSection(name: "Intro", startTime: 0.0, duration: 2.0),
            SongSection(name: "End", startTime: 2.0, duration: 2.0)
        ]

        let cutOffBuf = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            duration: 4.0,
            sections: sections,
            soundType: .beep,
            suppressEndCutoff: false,
            format: format
        ))
        let continuedBuf = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            duration: 4.0,
            sections: sections,
            soundType: .beep,
            suppressEndCutoff: true,
            format: format
        ))

        let startSample = Int(2.4 * format.sampleRate)
        let endSample = min(Int(cutOffBuf.frameLength), Int(3.9 * format.sampleRate))
        let ptrCut = try #require(cutOffBuf.floatChannelData?[0])
        let ptrCont = try #require(continuedBuf.floatChannelData?[0])

        var maxCut: Float = 0.0
        var maxCont: Float = 0.0
        for i in startSample..<endSample {
            maxCut = max(maxCut, abs(ptrCut[i]))
            maxCont = max(maxCont, abs(ptrCont[i]))
        }
        #expect(maxCut < 1e-5, "Normal End section must cut off click beats after downbeat")
        #expect(maxCont > 0.05, "suppressEndCutoff: true must keep click playing through End section")
    }

    @Test
    @MainActor
    func postSongClickStayInSongCueNextSongRoutingMIDIClockAndStopLifecycle() async throws {
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        let savedMIDIClock = MIDICueEngine.shared.isMIDIClockEnabled
        MIDICueEngine.shared.stopMIDIClock()

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.stopPostSongClick()
            engine.clearAllTracks()
            MIDICueEngine.shared.stopMIDIClock()
            MIDICueEngine.shared.isMIDIClockEnabled = savedMIDIClock
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        MIDICueEngine.shared.isMIDIClockEnabled = true
        engine.isMIDIMuted = false

        // Configure Click -> Out 2 (ch 1) and Tracks -> Out 1 (ch 0) in memory without persisting UserDefaults
        // so Routing Isolation passes identically on both 2-channel built-in audio and multi-channel interfaces.
        if let clickBusIdx = engine.busses.firstIndex(where: { $0.name.lowercased() == "click" }) {
            engine.busses[clickBusIdx].physicalOutputChannel = "Out 2"
            engine.busses[clickBusIdx].isMuted = false
            engine.busses[clickBusIdx].isMono = false
        }
        if let tracksBusIdx = engine.busses.firstIndex(where: { $0.name.lowercased() == "tracks" }) {
            engine.busses[tracksBusIdx].physicalOutputChannel = "Out 1"
            engine.busses[tracksBusIdx].isMuted = false
        }

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let stemBuf = try makeTestPCMBuffer(frameCount: AVAudioFrameCount(max(4_800, Int(round(2.4 * sr)))), sampleRate: sr)

        let song1 = Song(
            title: "Song One",
            artist: "Band",
            bpm: 100.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 2.4)],
            transitionType: .stayInSong,
            continueClick: true,
            clickSound: .beep,
            usesDefaultClickSound: false
        )
        let song2 = Song(
            title: "Song Two",
            artist: "Band",
            bpm: 132.0,
            timeSignatureNumerator: 6,
            timeSignatureDenominator: 8,
            musicalKey: "D",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 3.0)],
            transitionType: .cueNextSong,
            continueClick: false,
            clickSound: .beep,
            usesDefaultClickSound: false
        )

        let s1Keys = StemTrack(name: "Keys", role: .stem)
        let s1Click = StemTrack(name: "Click", role: .click)
        let s2Keys = StemTrack(name: "Keys", role: .stem)
        let s2Click = StemTrack(name: "Click", role: .click)

        engine.currentSetlist = Setlist(name: "Post Click Set", songs: [song1, song2])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song1.id] = [(s1Keys, stemBuf), (s1Click, stemBuf)]
        engine.songBuffersCache[song2.id] = [(s2Keys, stemBuf), (s2Click, stemBuf)]
        engine.loadSong(song1)

        // 1. Stay In Song: keeps Click & MIDI Clock running at Song 1's 100 BPM strictly on Out 3/4
        engine.handleSongEndTransition()
        #expect(engine.isPostSongClickActive)
        #expect(engine.currentSongIndex == 0)
        #expect(abs(engine.activePostSongClickBPM - 100.0) < 1e-5)

        let blocksForOneSec = max(40, Int(ceil(sr / 512.0)))
        let peaksActive = renderMixBlocks(mixState: engine.mixState, blockCount: blocksForOneSec)
        #expect(peaksActive[0] < 1e-5, "Post-song click must not bleed to FOH Tracks channel (Out 1)")
        #expect(peaksActive[1] > 0.05, "Post-song click must output to Click bus channel (Out 2)")
        #expect(peaksActive[2] < 1e-5 && peaksActive[3] < 1e-5, "Post-song click must not bleed to unrelated channels")

        // Muting Click channel silences post-song click immediately; unmuting restores it
        let clickTrack = try #require(engine.tracks.first(where: { $0.isClickTrackCached }))
        clickTrack.isMuted = true
        engine.updateSingleTrackGain(clickTrack)
        let peaksMuted = renderMixBlocks(mixState: engine.mixState, blockCount: blocksForOneSec)
        #expect(peaksMuted[1] < 1e-5, "Muting Click must silence post-song click")

        clickTrack.isMuted = false
        engine.updateSingleTrackGain(clickTrack)
        let peaksUnmuted = renderMixBlocks(mixState: engine.mixState, blockCount: blocksForOneSec)
        #expect(peaksUnmuted[1] > 0.05, "Unmuting Click must restore post-song click")

        try await Task.sleep(nanoseconds: 60_000_000)
        let clockRunningStay = MIDICueEngine.shared.currentMIDIClockStatusForTesting()
        #expect(clockRunningStay.isRunning)
        #expect(abs(clockRunningStay.bpm - 100.0) < 1e-5)

        // RTZ / Stop button stops post-song click and MIDI Clock
        engine.returnToZero()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!engine.isPostSongClickActive)
        #expect(!MIDICueEngine.shared.currentMIDIClockStatusForTesting().isRunning)

        // 2. Cue Next Song: cues Song 2 and runs Click at Song 2's 132 BPM in 6/8
        engine.updateSongTransition(at: 0, type: .cueNextSong)
        engine.updateSongContinueClick(at: 0, continueClick: true)
        engine.handleSongEndTransition()

        #expect(engine.currentSongIndex == 1)
        #expect(engine.isPostSongClickActive)
        #expect(abs(engine.activePostSongClickBPM - 132.0) < 1e-5)
        #expect(engine.activePostSongClickNumerator == 6)
        #expect(engine.activePostSongClickDenominator == 8)

        // Live BPM edit while post-song click is active updates post-song click & MIDI clock live
        engine.setBPM(140.0)
        #expect(abs(engine.activePostSongClickBPM - 140.0) < 1e-5)

        // Starting playback hands over cleanly with no post-song click active
        engine.play()
        #expect(!engine.isPostSongClickActive)
        engine.stop()
        #expect(!engine.isPostSongClickActive)
    }

    @Test
    @MainActor
    func remoteLoopControlsAndTapTempoRemoval() throws {
        let fm = FileManager.default
        let padsRoot = fm.temporaryDirectory.appendingPathComponent("pb_remote_loop_pads_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: padsRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: padsRoot) }

        let suiteName = "com.peanutbutter.tests.remote.loop.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let lastSessionBackup = UserDefaults.standard.object(forKey: "Playback_LastSessionPath")
        UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            if let v = lastSessionBackup {
                UserDefaults.standard.set(v, forKey: "Playback_LastSessionPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        // 1. HTML controls layout check
        let html = RemoteControlServer.remoteWebClientHTML
        #expect(!html.contains("tapTempoBtn"))
        #expect(!html.contains("TAP TEMPO"))
        #expect(html.contains("id=\"prevSongBtn\" class=\"span2\""))
        #expect(html.contains("id=\"nextSongBtn\" class=\"span2\""))
        #expect(html.contains("id=\"loop1xBtn\" class=\"span2\""))
        #expect(html.contains("id=\"loopInfBtn\" class=\"span2\""))

        // 2. Remote command dispatch + snapshot state
        let padLib = PadLibraryManager(customPadsDirectoryOverride: padsRoot)
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let song = Song(
            title: "Remote Loop Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Chorus", startTime: 0.0, duration: 8.0)]
        )
        engine.currentSetlist = Setlist(name: "Remote Set", songs: [song])
        engine.currentSongIndex = 0
        engine.loadSong(song)

        let server = RemoteControlServer(engine: engine, userDefaults: isolatedDefaults, padLibrary: padLib)
        server.attach(to: engine)

        let cmd1x = try JSONDecoder().decode(RemoteCommand.self, from: Data("{\"type\":\"toggleSingleLoop\"}".utf8))
        server.applyCommand(cmd1x)
        let snap1x = try #require(server.buildStateSnapshot())
        #expect(snap1x.isLoopActive)
        #expect(snap1x.loopMode == "single")

        let cmdInf = try JSONDecoder().decode(RemoteCommand.self, from: Data("{\"type\":\"toggleInfiniteLoop\"}".utf8))
        server.applyCommand(cmdInf)
        let snapInf = try #require(server.buildStateSnapshot())
        #expect(snapInf.isLoopActive)
        #expect(snapInf.loopMode == "infinite")
    }
}
