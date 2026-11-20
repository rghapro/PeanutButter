import Testing
import Foundation
import AVFoundation
@testable import PeanutButter

@Suite("User Reported Bug Fixes", .serialized)
struct UserReportedBugFixesTests {

    private func makeTestPCMBuffer(
        frequency: Float = 440.0,
        amplitude: Float = 0.25,
        durationSeconds: TimeInterval = 2.0,
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

    private func peakAmplitude(
        in buffer: AVAudioPCMBuffer,
        from startTime: TimeInterval,
        to endTime: TimeInterval
    ) -> Float {
        guard let ch0 = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0.0 }
        let sr = buffer.format.sampleRate
        let startFrame = max(0, min(Int(buffer.frameLength), Int(floor(startTime * sr))))
        let endFrame = max(startFrame, min(Int(buffer.frameLength), Int(ceil(endTime * sr))))
        var peak: Float = 0.0
        for i in startFrame..<endFrame {
            peak = max(peak, abs(ch0[i]))
        }
        return peak
    }

    @Test
    func guideDoesNotCountIntoOpeningSectionWhilePlaying() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!

        // Case A: Song starts directly with Intro (0..16s, 8 bars at 120 BPM 4/4) -> Verse 1 (16..32s).
        // Guide MUST be silent during Bars 1-2 (Intro already playing) and cue Verse 1 during Bar 8 (14..16s).
        let intro8 = SongSection(name: "Intro", startTime: 0.0, duration: 16.0, startMeasure: 1, measureCount: 8)
        let verse1 = SongSection(name: "Verse 1", startTime: 16.0, duration: 16.0, startMeasure: 9, measureCount: 8)
        let bufA = await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: [intro8, verse1],
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 32.0,
                voice: .rita,
                fallbackVoice: .zoe,
                countInEnabled: true,
                format: format
            )
        }.value
        let unwrappedA = try #require(bufA)
        #expect(peakAmplitude(in: unwrappedA, from: 0.0, to: 13.5) == 0.0)
        #expect(peakAmplitude(in: unwrappedA, from: 13.8, to: 16.0) > 0.01)

        // Case B: Song starts directly with a 1-bar Intro (0..2s) -> Verse 1 (2..18s), no Count In.
        // Bar 1 (0..2s) cues Verse 1 strictly before 2.0s; Bar 2 (2.2..4.0s) must stay silent.
        let intro1 = SongSection(name: "Intro", startTime: 0.0, duration: 2.0, startMeasure: 1, measureCount: 1)
        let verseAfterIntro1 = SongSection(name: "Verse 1", startTime: 2.0, duration: 16.0, startMeasure: 2, measureCount: 8)
        let bufB = await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: [intro1, verseAfterIntro1],
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 18.0,
                voice: .rita,
                fallbackVoice: .zoe,
                countInEnabled: true,
                format: format
            )
        }.value
        let unwrappedB = try #require(bufB)
        #expect(peakAmplitude(in: unwrappedB, from: 0.0, to: 2.0) > 0.01)
        #expect(peakAmplitude(in: unwrappedB, from: 2.25, to: 4.5) == 0.0)

        // Case C: Explicit 2-bar Count In (0..4s) -> Intro (4..20s): Bar 1 and Bar 2 count into Intro strictly before 4.0s;
        // Bar 3 (4.25..6.0s) must stay silent.
        let countIn2 = SongSection(name: "Count In", abbreviation: "Co", startTime: 0.0, duration: 4.0, startMeasure: 1, measureCount: 2)
        let introAfterCount = SongSection(name: "Intro", startTime: 4.0, duration: 16.0, startMeasure: 3, measureCount: 8)
        let bufC = await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: [countIn2, introAfterCount],
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 20.0,
                voice: .rita,
                fallbackVoice: .zoe,
                countInEnabled: true,
                format: format
            )
        }.value
        let unwrappedC = try #require(bufC)
        #expect(peakAmplitude(in: unwrappedC, from: 0.0, to: 1.9) > 0.01)
        #expect(peakAmplitude(in: unwrappedC, from: 1.9, to: 4.0) > 0.01)
        #expect(peakAmplitude(in: unwrappedC, from: 4.25, to: 6.5) == 0.0)

        // Case D: Sub-bar Count In (0..1.0s) -> Intro (1.0..17.0s) must not spill count-in speech into Intro.
        let tinyCount = SongSection(name: "Count In", abbreviation: "Co", startTime: 0.0, duration: 1.0, startMeasure: 1, measureCount: 1)
        let introAfterTiny = SongSection(name: "Intro", startTime: 1.0, duration: 16.0, startMeasure: 2, measureCount: 8)
        let bufD = await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: [tinyCount, introAfterTiny],
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 17.0,
                voice: .rita,
                fallbackVoice: .zoe,
                countInEnabled: true,
                format: format
            )
        }.value
        let unwrappedD = try #require(bufD)
        #expect(peakAmplitude(in: unwrappedD, from: 0.0, to: 4.0) == 0.0)
    }

    @Test
    @MainActor
    func removeSectionLabelKeepsMergedSectionAndDisplayDuration() throws {
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let s1 = SongSection(name: "Intro", startTime: 0.0, duration: 16.0, startMeasure: 1, measureCount: 8)
        let s2 = SongSection(name: "Verse 1", startTime: 16.0, duration: 16.0, startMeasure: 9, measureCount: 8)
        let s3 = SongSection(name: "Chorus", startTime: 32.0, duration: 16.0, startMeasure: 17, measureCount: 8)
        let song = Song(
            title: "Merge Label Test",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            sections: [s1, s2, s3],
            excludesClickAndGuide: true
        )
        engine.currentSetlist = Setlist(name: "Test Set", songs: [song])
        engine.loadSong(song)

        engine.isEditDrawerOpen = true
        engine.selectEditDrawerItem(.songSections)
        #expect(engine.isEditingArrangement)

        engine.removeSectionLabel(id: s2.id)

        #expect(engine.currentSong.sections.count == 2)
        #expect(engine.currentSong.sections[0].name == "Intro")
        #expect(abs(engine.currentSong.sections[0].duration - 32.0) < 1e-6)
        #expect(abs(engine.currentSong.sections[0].baseDuration - 32.0) < 1e-6)
        #expect(engine.currentSong.sections[0].measureCount == 16)
        #expect(abs(engine.currentSong.sections[1].startTime - 32.0) < 1e-6)

        // While still in Song Sections edit mode, displaySections MUST also retain the full 48s timeline (32s + 16s)
        #expect(engine.displaySections.count == 2)
        #expect(abs(engine.displaySections[0].duration - 32.0) < 1e-6)
        #expect(engine.displaySections[0].measureCount == 16)
        #expect(abs(engine.displaySections[1].startTime - 32.0) < 1e-6)
        #expect(abs((engine.displaySections.last?.endTime ?? 0.0) - 48.0) < 1e-6)

        // Check trim-preserving merge math
        let trimmedPrev = SongSection(
            name: "Intro",
            startTime: 0.0,
            audioStartTime: 2.0,
            duration: 14.0,
            startMeasure: 1,
            measureCount: 7,
            originalAudioStartTime: 0.0,
            originalDuration: 16.0,
            leadingTrimDuration: 2.0,
            trailingTrimDuration: 0.0
        )
        let trimmedNext = SongSection(
            name: "Verse 1",
            startTime: 14.0,
            audioStartTime: 16.0,
            duration: 14.0,
            startMeasure: 8,
            measureCount: 7,
            originalAudioStartTime: 16.0,
            originalDuration: 16.0,
            leadingTrimDuration: 0.0,
            trailingTrimDuration: 2.0
        )
        engine.currentSong.sections = [trimmedPrev, trimmedNext]
        engine.removeSectionLabel(id: trimmedNext.id)
        #expect(engine.currentSong.sections.count == 1)
        let merged = try #require(engine.currentSong.sections.first)
        #expect(abs(merged.duration - 28.0) < 1e-6)
        #expect(abs(merged.leadingTrimDuration - 2.0) < 1e-6)
        #expect(abs(merged.trailingTrimDuration - 2.0) < 1e-6)
        #expect(abs(merged.baseDuration - 32.0) < 1e-6)
    }

    @Test
    @MainActor
    func stemImportWaveformVersionDurationAndAsyncDecode() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_wf_test_\(UUID().uuidString)", isDirectory: true)
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

        let engine = MultitrackAudioEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        // Build a 10.0s stem (< 240s) whose tail (7.5s..10.0s) has strong peaks and first 7.5s is quieter.
        let sr = 48_000.0
        let stemFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let totalFrames = AVAudioFrameCount(10.0 * sr)
        let stemBuf = try #require(AVAudioPCMBuffer(pcmFormat: stemFormat, frameCapacity: totalFrames))
        stemBuf.frameLength = totalFrames
        let ch0 = try #require(stemBuf.floatChannelData?[0])
        let ch1 = try #require(stemBuf.floatChannelData?[1])
        let cutoff = Int(7.5 * sr)
        for i in 0..<Int(totalFrames) {
            let amp: Float = (i >= cutoff) ? 0.8 : 0.15
            let s = amp * sin(2.0 * Float.pi * 220.0 * Float(i) / Float(sr))
            ch0[i] = s
            ch1[i] = s
        }

        let initialVersion = engine.waveformVersion
        let keysTrack = StemTrack(name: "Keys", role: .stem)
        createdTrackIds.append(keysTrack.id)
        engine.addTrack(keysTrack, with: stemBuf)
        engine.ensureClickAndGuideTracksExist()
        engine.recalculateAggregateWaveform(samplesCount: 4000)

        let clickTrack = try #require(engine.tracks.first(where: { $0.role == .click }))
        let guideTrack = try #require(engine.tracks.first(where: { $0.role == .guide }))
        #expect(abs(clickTrack.duration - 10.0) < 0.05)
        #expect(abs(guideTrack.duration - 10.0) < 0.05)
        #expect(abs(engine.currentSongDuration - 10.0) < 0.05)
        #expect(engine.waveformVersion > initialVersion)
        #expect(engine.aggregateWaveform.count == 4000)
        // Tail region must represent the 7.5s..10.0s audio (not zero-padded out to 240s)
        let tailPeak = engine.aggregateWaveform[3500..<3990].max() ?? 0.0
        #expect(tailPeak > 0.7)

        // Verify async file import off main thread
        let wavURL = tempRoot.appendingPathComponent("Electric Guitar.wav")
        do {
            let shortBuf = try makeTestPCMBuffer(frequency: 330.0, amplitude: 0.4, durationSeconds: 2.0, sampleRate: sr)
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let wavFile = try AVAudioFile(forWriting: wavURL, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try wavFile.write(from: shortBuf)
        }

        let engineAsync = MultitrackAudioEngine()
        defer { engineAsync.cancelAllSessionBackgroundTasks() }
        var progressCalls = 0
        await engineAsync.addTracksConcurrentlyAsync(from: [wavURL]) { _, total in
            if total == 1 {
                progressCalls += 1
            }
        }
        for t in engineAsync.tracks {
            createdTrackIds.append(t.id)
        }
        #expect(progressCalls == 1)
        let guitar = try #require(engineAsync.tracks.first(where: { $0.name == "Electric Guitar" }))
        #expect(!guitar.waveformPeaks.isEmpty)
        #expect(abs(engineAsync.currentSongDuration - 2.0) < 0.05)
    }

    @Test
    @MainActor
    func confirmTempoAndGridUpdatesEngineAndClearsStaleBeatGrid() throws {
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let staleGrid = [
            BeatGridMarker(time: 0.0, bar: 1, beat: 1, instantaneousBPM: 120.0),
            BeatGridMarker(time: 0.5, bar: 1, beat: 2, instantaneousBPM: 120.0),
            BeatGridMarker(time: 1.0, bar: 1, beat: 3, instantaneousBPM: 120.0),
            BeatGridMarker(time: 1.5, bar: 1, beat: 4, instantaneousBPM: 120.0)
        ]
        let s1 = SongSection(name: "Intro", startTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4)
        let s2 = SongSection(name: "Verse 1", startTime: 8.0, duration: 8.0, startMeasure: 5, measureCount: 4)
        let song = Song(
            title: "",
            artist: "",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [s1, s2],
            beatGrid: staleGrid
        )
        engine.currentSetlist = Setlist(name: "Builder Set", songs: [song])
        engine.loadSong(song)

        let buf = try makeTestPCMBuffer(durationSeconds: 4.0)
        engine.addTrack(StemTrack(name: "Drums", role: .stem), with: buf)

        engine.applySongBuilderTempoAndGrid(
            bpm: 75.0,
            timeSignatureNumerator: 6,
            timeSignatureDenominator: 8,
            title: "Build From Stems Song",
            artist: "Worship Band",
            musicalKey: "G",
            sections: [s1, s2],
            isCreatingNewSong: true
        )

        #expect(engine.currentSong.title == "Build From Stems Song")
        #expect(engine.currentSong.artist == "Worship Band")
        #expect(engine.currentSong.musicalKey == "G")
        #expect(abs(engine.currentSong.bpm - 75.0) < 1e-6)
        #expect(abs(engine.currentSong.originalBPM - 75.0) < 1e-6)
        #expect(engine.currentSong.timeSignatureNumerator == 6)
        #expect(engine.currentSong.timeSignatureDenominator == 8)
        #expect(engine.currentSong.beatGrid.isEmpty)
        #expect(abs(engine.transportPosition.currentBPM - 75.0) < 1e-6)
        #expect(engine.currentSetlist.songs[0].bpm == 75.0)
        #expect(engine.currentSetlist.songs[0].timeSignatureNumerator == 6)
        #expect(engine.currentSetlist.songs[0].timeSignatureDenominator == 8)

        // 4 bars of 6/8 at 75 BPM = 4 * 6 * (60/75 * 4/8) = 9.6s per section
        #expect(engine.currentSong.sections.count == 2)
        #expect(abs(engine.currentSong.sections[0].duration - 9.6) < 1e-4)
        #expect(abs(engine.currentSong.sections[1].startTime - 9.6) < 1e-4)
        #expect(engine.tracks.contains { $0.role == .click })
        #expect(engine.tracks.contains { $0.role == .guide })
    }

    @Test
    @MainActor
    func remoteControlServerReportsActiveTransposedKeys() throws {
        let suiteName = "pb_remote_keys_\(UUID().uuidString)"
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        let savedLastSession = UserDefaults.standard.object(forKey: "Playback_LastSessionPath")
        UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
            if let v = savedLastSession {
                UserDefaults.standard.set(v, forKey: "Playback_LastSessionPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        defer { engine.cancelAllSessionBackgroundTasks() }

        let song1 = Song(
            title: "Transposed Up",
            artist: "Artist A",
            bpm: 120.0,
            musicalKey: "D",
            transposeSemitones: 2,
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 4.0)],
            excludesClickAndGuide: true
        )
        let song2 = Song(
            title: "Transposed Down",
            artist: "Artist B",
            bpm: 100.0,
            musicalKey: "G",
            transposeSemitones: -2,
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 4.0)],
            excludesClickAndGuide: true
        )

        let buf = try makeTestPCMBuffer(durationSeconds: 1.0)
        engine.currentSetlist = Setlist(name: "Key Test", songs: [song1, song2])
        engine.songBuffersCache[song1.id] = [(StemTrack(name: "Keys", role: .stem), buf)]
        engine.songBuffersCache[song2.id] = [(StemTrack(name: "Keys", role: .stem), buf)]
        engine.loadSong(song1)

        let server = RemoteControlServer(engine: engine, userDefaults: testDefaults)
        let initialSnapshot = try #require(server.buildStateSnapshot())
        #expect(initialSnapshot.musicalKey == "E")
        #expect(initialSnapshot.setlist.count == 2)
        #expect(initialSnapshot.setlist[0].musicalKey == "E")
        #expect(initialSnapshot.setlist[1].musicalKey == "F")

        // Transpose active song down -1 semitone from D -> Db and verify snapshot updates to Db
        engine.setKeyAndTempo(semitones: -1, forSongIndex: 0)
        let updatedSnapshot = try #require(server.buildStateSnapshot())
        #expect(updatedSnapshot.musicalKey == "Db")
        #expect(updatedSnapshot.setlist[0].musicalKey == "Db")
        #expect(updatedSnapshot.setlist[1].musicalKey == "F")
    }
}
