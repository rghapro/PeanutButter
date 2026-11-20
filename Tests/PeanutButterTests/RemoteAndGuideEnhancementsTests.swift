import Testing
import Foundation
import AVFoundation
@testable import PeanutButter

@Suite("Remote, Pad Lock & Custom Guide Labeling Tests", .serialized)
struct RemoteAndGuideEnhancementsTests {

    private func makeTestPCMBuffer(
        frequency: Float = 880.0,
        frameCount: AVAudioFrameCount = 2_400,
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
            ch1[i] = sample * 0.9
        }
        return buffer
    }

    private func writeTestWAVFile(
        to url: URL,
        frequency: Float = 880.0,
        frameCount: AVAudioFrameCount = 2_400,
        sampleRate: Double = 48_000.0
    ) throws {
        let buf = try makeTestPCMBuffer(frequency: frequency, frameCount: frameCount, sampleRate: sampleRate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buf)
    }

    @Test
    @MainActor
    func padLinkKeyLockDuringPlaybackAndRemote() throws {
        let fm = FileManager.default
        let padsRoot = fm.temporaryDirectory.appendingPathComponent("pb_padlock_pads_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: padsRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: padsRoot) }

        let suiteName = "com.peanutbutter.tests.padlock.\(UUID().uuidString)"
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

        let padLib = PadLibraryManager(customPadsDirectoryOverride: padsRoot)
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.stopPadPlayerImmediately()
            engine.clearAllTracks()
        }

        let song = Song(
            title: "Amazing Grace",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "G",
            transposeSemitones: 2, // Transposed to "A"
            sections: [SongSection(name: "Verse 1", startTime: 0.0, duration: 8.0)],
            excludesClickAndGuide: true
        )
        let buf = try makeTestPCMBuffer()
        engine.currentSetlist = Setlist(name: "Pad Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [(StemTrack(name: "Keys", role: .stem), buf)]
        engine.loadSong(song)

        let server = RemoteControlServer(engine: engine, userDefaults: isolatedDefaults, padLibrary: padLib)
        server.attach(to: engine)

        // Stopped with LINK enabled: changing to any manual key succeeds
        engine.isPadLinked = true
        engine.playbackState = .stopped
        engine.startPadPlayer(key: "D")
        #expect(engine.isPadActive)
        #expect(engine.currentPadKey == "D")
        #expect(!engine.isPadKeyLockedToSong)
        #expect(server.buildStateSnapshot()?.pad.lockedKey == nil)

        // Playing with LINK enabled: locked to song's active transposed key ("A")
        engine.playbackState = .playing
        engine.syncActivePadToCurrentSongIfNeeded()
        #expect(engine.linkedSongPadKey == "A")
        #expect(engine.isPadKeyLockedToSong)
        #expect(engine.currentPadKey == "A")
        #expect(server.buildStateSnapshot()?.pad.lockedKey == "A")

        // Engine blocks switching to any other key while playing + LINK
        engine.startPadPlayer(key: "D")
        #expect(engine.currentPadKey == "A")

        // Remote blocks switching to any other key, but allows toggling the song's key ("A")
        let cmdOther = try JSONDecoder().decode(RemoteCommand.self, from: Data("{\"type\":\"setPadKey\",\"padKey\":\"Eb\"}".utf8))
        server.applyCommand(cmdOther)
        #expect(engine.currentPadKey == "A")
        #expect(engine.isPadActive)

        let cmdSongKey = try JSONDecoder().decode(RemoteCommand.self, from: Data("{\"type\":\"setPadKey\",\"padKey\":\"A\"}".utf8))
        server.applyCommand(cmdSongKey)
        #expect(!engine.isPadActive)
        server.applyCommand(cmdSongKey)
        #expect(engine.isPadActive)
        #expect(engine.currentPadKey == "A")

        // Disabling LINK unlocks other keys immediately during playback
        engine.togglePadLink()
        #expect(!engine.isPadLinked)
        #expect(!engine.isPadKeyLockedToSong)
        #expect(server.buildStateSnapshot()?.pad.lockedKey == nil)
        server.applyCommand(cmdOther)
        #expect(engine.currentPadKey == "Eb")

        // Song without key set does not lock pad keys even when playing + LINK
        let keylessSong = Song(
            title: "Interlude",
            artist: "Band",
            bpm: 100.0,
            musicalKey: "—",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 4.0)],
            excludesClickAndGuide: true
        )
        engine.songBuffersCache[keylessSong.id] = [(StemTrack(name: "Keys", role: .stem), buf)]
        engine.loadSong(keylessSong)
        engine.isPadLinked = true
        engine.playbackState = .playing
        #expect(engine.linkedSongPadKey == nil)
        #expect(!engine.isPadKeyLockedToSong)
        #expect(server.buildStateSnapshot()?.pad.lockedKey == nil)
    }

    @Test
    @MainActor
    func remoteShortNamesPanningBusesMetersAndLayoutHTML() throws {
        let fm = FileManager.default
        let padsRoot = fm.temporaryDirectory.appendingPathComponent("pb_remote_enh_pads_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: padsRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: padsRoot) }

        let suiteName = "com.peanutbutter.tests.remote.enh.\(UUID().uuidString)"
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

        let padLib = PadLibraryManager(customPadsDirectoryOverride: padsRoot)
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let egTrack = StemTrack(name: "Electric Guitar 1", role: .stem)
        let bgTrack = StemTrack(name: "Background Vocals", role: .stem)
        let song = Song(
            title: "Mix Check",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Chorus", startTime: 0.0, duration: 8.0)],
            excludesClickAndGuide: true
        )
        let buf = try makeTestPCMBuffer()
        engine.currentSetlist = Setlist(name: "Mix Set", songs: [song])
        engine.songBuffersCache[song.id] = [(egTrack, buf), (bgTrack, buf)]
        engine.loadSong(song)

        let server = RemoteControlServer(engine: engine, userDefaults: isolatedDefaults, padLibrary: padLib)
        server.attach(to: engine)

        // 1. Shortened track and bus names
        let snap0 = try #require(server.buildStateSnapshot())
        let remoteEG = try #require(snap0.tracks.first(where: { $0.id == egTrack.id.uuidString }))
        let remoteBG = try #require(snap0.tracks.first(where: { $0.id == bgTrack.id.uuidString }))
        #expect(remoteEG.shortName == "EG 1")
        #expect(remoteBG.shortName == "BGVS")

        let remoteEGBus = try #require(snap0.buses.first(where: { $0.name == "Electric Guitars" }))
        let remoteAGBus = try #require(snap0.buses.first(where: { $0.name == "Acoustic Guitars" }))
        let remotePercBus = try #require(snap0.buses.first(where: { $0.name == "Percussion" }))
        #expect(remoteEGBus.shortName == "EG")
        #expect(remoteAGBus.shortName == "AG")
        #expect(remotePercBus.shortName == "Perc")

        // 2. Track pan, Pad pan, and Bus commands
        let cmdTrackPan = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"setTrackPan\",\"trackId\":\"\(egTrack.id.uuidString)\",\"pan\":-0.55}".utf8)
        )
        server.applyCommand(cmdTrackPan)
        #expect(abs(egTrack.pan - (-0.55)) < 0.001)

        let cmdPadPan = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"setPadPan\",\"pan\":0.40}".utf8)
        )
        server.applyCommand(cmdPadPan)
        #expect(abs(engine.padChannelPan - 0.40) < 0.001)

        let egBusModel = try #require(engine.busses.first(where: { $0.id.uuidString == remoteEGBus.id }))
        let cmdBusVol = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"setBusVolume\",\"busId\":\"\(egBusModel.id.uuidString)\",\"volume\":0.65}".utf8)
        )
        server.applyCommand(cmdBusVol)
        #expect(abs(egBusModel.volume - 0.65) < 0.001)

        let cmdBusMute = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"toggleBusMute\",\"busId\":\"\(egBusModel.id.uuidString)\"}".utf8)
        )
        server.applyCommand(cmdBusMute)
        #expect(egBusModel.isMuted)

        let cmdBusSolo = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"toggleBusSolo\",\"busId\":\"\(egBusModel.id.uuidString)\"}".utf8)
        )
        server.applyCommand(cmdBusSolo)
        #expect(egBusModel.isSoloed)

        let snap1 = try #require(server.buildStateSnapshot())
        let updatedEGTrack = try #require(snap1.tracks.first(where: { $0.id == egTrack.id.uuidString }))
        #expect(abs(updatedEGTrack.pan - (-0.55)) < 0.001)
        #expect(abs(snap1.pad.pan - 0.40) < 0.001)
        let updatedEGBus = try #require(snap1.buses.first(where: { $0.id == egBusModel.id.uuidString }))
        #expect(abs(updatedEGBus.volume - 0.65) < 0.001)
        #expect(updatedEGBus.isMuted)
        #expect(updatedEGBus.isSoloed)

        // 3. Meter packet quantization & mute masking
        engine.masterPeakLeft = 0.82
        engine.masterPeakRight = 0.50
        engine.padMeterPeakL = 0.60
        engine.padMeterPeakR = 0.45
        engine.padChannelMuted = false
        egTrack.peakLevelLeft = 0.72
        egTrack.peakLevelRight = 0.72
        egTrack.isMuted = false
        bgTrack.peakLevelLeft = 0.90
        bgTrack.peakLevelRight = 0.90
        bgTrack.isMuted = true
        egBusModel.isMuted = true
        egBusModel.peakLevelLeft = 0.70
        let padBusModel = try #require(engine.busses.first(where: { $0.name == "Pad" }))
        padBusModel.isMuted = false
        padBusModel.peakLevelLeft = 0.55
        padBusModel.peakLevelRight = 0.55

        let meterResult = try #require(server.buildMetersPacket())
        #expect(meterResult.isNonZero)
        #expect(meterResult.packet.master == [82, 50])
        #expect(meterResult.packet.pad == [60, 45])
        #expect(meterResult.packet.tracks[egTrack.id.uuidString] == [72, 72])
        #expect(meterResult.packet.tracks[bgTrack.id.uuidString] == nil)
        #expect(meterResult.packet.buses[egBusModel.id.uuidString] == nil)
        #expect(meterResult.packet.buses[padBusModel.id.uuidString] == [55, 55])

        // 4. HTML structure & CSP/XSS invariants
        let html = RemoteControlServer.buildRemoteWebClientHTML(cspNonce: "nonceCheck")
        #expect(html.contains("<script nonce=\"nonceCheck\">"))
        #expect(!html.contains(".innerHTML"))
        #expect(html.contains("id=\"mixerTabTracks\""))
        #expect(html.contains("id=\"mixerTabBuses\""))
        #expect(html.contains("id=\"mixerLayoutBtn\""))
        #expect(html.contains("id=\"splitterLeft\""))
        #expect(html.contains("id=\"splitterRight\""))
        #expect(html.contains("id=\"splitterBottom\""))
        #expect(html.contains("id=\"padPanSlot\""))
        #expect(html.contains("id: \"padPan\""))
        #expect(html.contains("layout-horizontal"))
        #expect(html.contains("id=\"prevSongBtn\" class=\"span2\""))
        #expect(html.contains("id=\"nextSongBtn\" class=\"span2\""))
        #expect(html.contains("id=\"loop1xBtn\" class=\"span2\""))
        #expect(html.contains("id=\"loopInfBtn\" class=\"span2\""))
    }

    @Test
    @MainActor
    func remoteTimelineWaveformSeekColorHexAndCapOnlyFaders() throws {
        let fm = FileManager.default
        let padsRoot = fm.temporaryDirectory.appendingPathComponent("pb_timeline_pads_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: padsRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: padsRoot) }

        let suiteName = "com.peanutbutter.tests.timeline.\(UUID().uuidString)"
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

        let padLib = PadLibraryManager(customPadsDirectoryOverride: padsRoot)
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.stopPadPlayerImmediately()
            engine.clearAllTracks()
        }

        let intro = SongSection(name: "Intro", startTime: 0.0, duration: 4.0)
        let chorus = SongSection(name: "Chorus", startTime: 4.0, duration: 6.0)
        #expect(intro.colorHex.hasPrefix("#"))
        #expect(intro.colorHex.count == 7)
        #expect(chorus.colorHex.hasPrefix("#"))
        #expect(chorus.colorHex.count == 7)

        let song = Song(
            title: "Timeline Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [intro, chorus],
            excludesClickAndGuide: true
        )
        let stem = StemTrack(name: "Keys", role: .stem)
        let buf = try makeTestPCMBuffer()
        engine.currentSetlist = Setlist(name: "Timeline Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [(stem, buf)]
        engine.loadSong(song)

        let server = RemoteControlServer(engine: engine, userDefaults: isolatedDefaults, padLibrary: padLib)
        server.attach(to: engine)

        // 1. Section colorHex and waveformVersion in state snapshot
        engine.waveformVersion = 7
        engine.aggregateWaveform = (0..<720).map { i in
            i % 2 == 0 ? 0.25 : 0.75
        }
        let snap = try #require(server.buildStateSnapshot())
        #expect(snap.waveformVersion == 7)
        #expect(snap.sections.count == 2)
        #expect(snap.sections[0].colorHex == intro.colorHex)
        #expect(snap.sections[1].colorHex == chorus.colorHex)

        // 2. Downsampled waveform packet generation
        let packet = try #require(server.buildWaveformPacket(targetBuckets: 360))
        #expect(packet.type == "waveform")
        #expect(packet.version == 7)
        #expect(packet.duration == engine.currentSongDuration)
        #expect(packet.peaks.count == 360)
        #expect(packet.peaks.allSatisfy { $0 == 75 })

        engine.aggregateWaveform = [0.1, 0.5, 1.2, .nan]
        let smallPacket = try #require(server.buildWaveformPacket(targetBuckets: 360))
        #expect(smallPacket.peaks == [10, 50, 100, 0])

        engine.aggregateWaveform = []
        let emptyPacket = try #require(server.buildWaveformPacket(targetBuckets: 360))
        #expect(emptyPacket.peaks.isEmpty)

        // 3. Remote seek command only seeks when stopped
        engine.playbackState = .stopped
        let seekCmd = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"seek\",\"time\":4.5}".utf8)
        )
        server.applyCommand(seekCmd)
        #expect(abs(engine.playbackOffsetSeconds - 4.5) < 0.01)

        let negativeSeekCmd = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"seek\",\"time\":-3.0}".utf8)
        )
        server.applyCommand(negativeSeekCmd)
        #expect(abs(engine.playbackOffsetSeconds - 0.0) < 0.01)

        server.applyCommand(seekCmd)
        engine.playbackState = .playing
        let blockedSeekCmd = try JSONDecoder().decode(
            RemoteCommand.self,
            from: Data("{\"type\":\"seek\",\"time\":1.0}".utf8)
        )
        server.applyCommand(blockedSeekCmd)
        #expect(abs(engine.playbackOffsetSeconds - 4.5) < 0.01)

        // 4. Compact timeline UI & cap-only fader HTML invariants
        let html = RemoteControlServer.buildRemoteWebClientHTML(cspNonce: "timelineNonce")
        #expect(html.contains("id=\"timelineModeSelect\""))
        #expect(html.contains("id=\"waveformCanvas\""))
        #expect(html.contains("id=\"progressBarTrack\""))
        #expect(html.contains("hfader-cap"))
        #expect(html.contains("vfader-cap"))
        #expect(!html.contains("type=\"range\""))
        #expect(html.contains("color-scheme: dark;"))
        #expect(html.contains("::-webkit-scrollbar"))
        #expect(html.contains("scrollbar-color:"))
    }

    @Test
    @MainActor
    func customGuidePackAutoAssignAndUserCueKindLabeling() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_guide_labels_\(UUID().uuidString)", isDirectory: true)
        let importSource = tempRoot.appendingPathComponent("ImportSource", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: importSource, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let filenames = [
            "1.wav",
            "Chorus 1.wav",
            "All In.wav",
            "Turnaround.wav",
            "Altar Call.wav",
            "Horns In.wav"
        ]
        for name in filenames {
            try writeTestWAVFile(to: importSource.appendingPathComponent(name), frameCount: 600)
        }

        let mgr = CustomSampleLibraryManager(isolatedRootDirectory: tempRoot)
        let prepared = mgr.prepareGuideImportItems(from: [importSource])
        #expect(prepared.derivedPackName == "ImportSource")
        #expect(prepared.items.count == filenames.count)

        var items = prepared.items
        func indexFor(_ key: String) -> Int? {
            items.firstIndex(where: { $0.phraseKey == key })
        }

        let countIdx = try #require(indexFor("1"))
        let chorusIdx = try #require(indexFor("chorus 1"))
        let allInIdx = try #require(indexFor("all in"))
        let turnaroundIdx = try #require(indexFor("turnaround"))
        let altarIdx = try #require(indexFor("altar call"))
        let hornsIdx = try #require(indexFor("horns in"))

        // Auto-assign defaults are preserved
        #expect(items[countIdx].isCountIn)
        #expect(items[chorusIdx].isStandardMatch)
        #expect(items[chorusIdx].cueKind == .songSection)
        #expect(items[allInIdx].isStandardMatch)
        #expect(items[allInIdx].cueKind == .directional)
        #expect(items[turnaroundIdx].isStandardMatch)
        #expect(items[turnaroundIdx].cueKind == .songSection)
        #expect(!items[altarIdx].isStandardMatch)
        #expect(items[altarIdx].cueKind == .songSection)
        #expect(!items[hornsIdx].isStandardMatch)
        #expect(items[hornsIdx].cueKind == .directional)

        // User re-labels both a custom cue ("Horns In" -> Song Section) and a standard cue ("Turnaround" -> Directional)
        items[hornsIdx].cueKind = .songSection
        items[turnaroundIdx].cueKind = .directional

        let pack = try #require(mgr.importCustomGuidePack(name: "Custom Voice Pack", items: items))
        #expect(pack.phraseCount == filenames.count)

        // Re-scan from disk (pack.json) to confirm persistence across reloads
        mgr.refreshPacks()
        let reloaded = try #require(mgr.guidePack(forId: pack.id))
        #expect(reloaded.cueKind(forNormalizedPhrase: "horns in") == .songSection)
        #expect(reloaded.cueKind(forNormalizedPhrase: "altar call") == .songSection)
        #expect(reloaded.cueKind(forNormalizedPhrase: "turnaround") == .directional)
        #expect(reloaded.cueKind(forNormalizedPhrase: "chorus 1") == .songSection)
        #expect(reloaded.cueKind(forNormalizedPhrase: "all in") == .directional)

        let sectionOptions = mgr.userCustomCueOptions(ofKind: .songSection, preferredVoice: reloaded.guideVoice)
        let directionalOptions = mgr.userCustomCueOptions(ofKind: .directional, preferredVoice: reloaded.guideVoice)
        #expect(sectionOptions.contains("Horns In"))
        #expect(sectionOptions.contains("Altar Call"))
        #expect(!directionalOptions.contains("Horns In"))
        #expect(directionalOptions.contains("Turnaround"))

        // Post-import toggle also persists cleanly and count-in remains protected
        mgr.setCustomGuideCueKind(packId: pack.id, phraseKey: "turnaround", kind: .songSection)
        mgr.setCustomGuideCueKind(packId: pack.id, phraseKey: "1", kind: .directional)
        mgr.refreshPacks()
        let reloadedAfter = try #require(mgr.guidePack(forId: pack.id))
        #expect(reloadedAfter.cueKind(forNormalizedPhrase: "turnaround") == .songSection)
        #expect(reloadedAfter.customCueKinds["1"] == nil)
        #expect(!mgr.userCustomCueOptions(ofKind: .directional, preferredVoice: reloadedAfter.guideVoice).contains("Turnaround"))
    }

    @Test
    @MainActor
    func soloTrackAndBusWaveformPreservesCacheAndClearsSolos() throws {
        func makeWindowedBuffer(firstHalfAmp: Float, secondHalfAmp: Float, sampleRate: Double) throws -> AVAudioPCMBuffer {
            let frameCount = AVAudioFrameCount(max(4_410, Int(round(sampleRate))))
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let ch0 = try #require(buffer.floatChannelData?[0])
            let ch1 = try #require(buffer.floatChannelData?[1])
            let half = Int(frameCount) / 2
            for i in 0..<Int(frameCount) {
                let amp = i < half ? firstHalfAmp : secondHalfAmp
                let sample = amp * sin(Float(i) * 0.2)
                ch0[i] = sample
                ch1[i] = sample
            }
            return buffer
        }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.clearAllSolos()
            engine.clearAllTracks()
        }

        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0

        let eg1Track = StemTrack(name: "Electric Guitar 1", role: .stem, assignedBusName: "Electric Guitars")
        let eg2Track = StemTrack(name: "Electric Guitar 2", role: .stem, assignedBusName: "Electric Guitars")
        let bassTrack = StemTrack(name: "Bass", role: .stem, assignedBusName: "Bass")
        let pianoTrack = StemTrack(name: "Piano", role: .stem, isSoloSafe: true, assignedBusName: "Piano")
        let clickTrack = StemTrack(name: "Click", role: .click, assignedBusName: "Click")
        let guideTrack = StemTrack(name: "Guide", role: .guide, assignedBusName: "Guide")

        let eg1Buf = try makeWindowedBuffer(firstHalfAmp: 0.65, secondHalfAmp: 0.0, sampleRate: sr)
        let eg2Buf = try makeWindowedBuffer(firstHalfAmp: 0.35, secondHalfAmp: 0.0, sampleRate: sr)
        let bassBuf = try makeWindowedBuffer(firstHalfAmp: 0.0, secondHalfAmp: 0.65, sampleRate: sr)
        let pianoBuf = try makeWindowedBuffer(firstHalfAmp: 0.0, secondHalfAmp: 0.45, sampleRate: sr)
        let clickBuf = try makeWindowedBuffer(firstHalfAmp: 0.85, secondHalfAmp: 0.85, sampleRate: sr)
        let guideBuf = try makeWindowedBuffer(firstHalfAmp: 0.85, secondHalfAmp: 0.85, sampleRate: sr)

        let song = Song(
            title: "Solo Waveform Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [
                SongSection(name: "Intro", startTime: 0.0, duration: 0.5),
                SongSection(name: "Chorus", startTime: 0.5, duration: 0.5)
            ],
            excludesClickAndGuide: false
        )

        engine.currentSetlist = Setlist(name: "Solo Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [
            (eg1Track, eg1Buf),
            (eg2Track, eg2Buf),
            (bassTrack, bassBuf),
            (pianoTrack, pianoBuf),
            (clickTrack, clickBuf),
            (guideTrack, guideBuf)
        ]
        engine.loadSong(song)

        let cachedFullMix = try #require(engine.songWaveformCache[song.id]?.peaks)
        #expect(!cachedFullMix.isEmpty)
        #expect(engine.masterWaveformPeaks == cachedFullMix)
        #expect(engine.aggregateWaveform == cachedFullMix)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(!engine.hasAnySolo)

        let firstHalfRange = 100..<1_700
        let secondHalfRange = 2_300..<3_900
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.5)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 0) > 0.5)

        // 1. Single soloed track shows only that track and preserves cached full mix
        let versionBeforeSolo = engine.waveformVersion
        eg1Track.isSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks != nil)
        #expect(engine.waveformVersion > versionBeforeSolo)
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.8)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 1) < 0.01)
        #expect(engine.masterWaveformPeaks == cachedFullMix)
        #expect(engine.songWaveformCache[song.id]?.peaks == cachedFullMix)

        // 2. Non-solo matrix updates do not trigger redundant waveformVersion bumps
        let versionBeforeMute = engine.waveformVersion
        bassTrack.isMuted.toggle()
        engine.updateMatrix()
        #expect(engine.waveformVersion == versionBeforeMute)
        bassTrack.isMuted = false

        // 3. Multiple soloed tracks combine without mutating songWaveformCache
        bassTrack.isSoloed = true
        engine.updateMatrix()
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.8)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 0) > 0.8)
        #expect(engine.songWaveformCache[song.id]?.peaks == cachedFullMix)

        // 4. Solo-safe track & solo-safe bus do not appear in solo waveform
        bassTrack.isSoloed = false
        let pianoBus = try #require(engine.busses.first(where: { $0.name == "Piano" }))
        pianoBus.isSoloSafe = true
        engine.updateMatrix()
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.8)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 1) < 0.01)

        // 5. Soloing one bus and multiple busses combines routed musical stems
        eg1Track.isSoloed = false
        let egBus = try #require(engine.busses.first(where: { $0.name == "Electric Guitars" }))
        let bassBus = try #require(engine.busses.first(where: { $0.name == "Bass" }))
        egBus.isSoloed = true
        engine.updateMatrix()
        #expect(engine.soloWaveformPeaks != nil)
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.8)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 1) < 0.01)
        #expect(engine.songWaveformCache[song.id]?.peaks == cachedFullMix)

        bassBus.isSoloed = true
        engine.updateMatrix()
        #expect((engine.aggregateWaveform[firstHalfRange].max() ?? 0) > 0.8)
        #expect((engine.aggregateWaveform[secondHalfRange].max() ?? 0) > 0.7)
        #expect(engine.songWaveformCache[song.id]?.peaks == cachedFullMix)

        // Clearing bus solos restores cached full-mix waveform
        egBus.isSoloed = false
        bassBus.isSoloed = false
        pianoBus.isSoloSafe = false
        engine.updateMatrix()
        #expect(!engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.aggregateWaveform == cachedFullMix)

        // 6. Click, Guide, Pad, and Click/Guide/Pad bus solos stay out of timeline waveform
        clickTrack.isSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.aggregateWaveform == cachedFullMix)
        clickTrack.isSoloed = false

        guideTrack.isSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.aggregateWaveform == cachedFullMix)
        guideTrack.isSoloed = false

        engine.padChannelSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.aggregateWaveform == cachedFullMix)

        let clickBus = try #require(engine.busses.first(where: { $0.name == "Click" }))
        let guideBus = try #require(engine.busses.first(where: { $0.name == "Guide" }))
        let padBus = try #require(engine.busses.first(where: { $0.name == "Pad" }))
        clickBus.isSoloed = true
        guideBus.isSoloed = true
        padBus.isSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.aggregateWaveform == cachedFullMix)
        clickBus.isSoloed = false
        guideBus.isSoloed = false
        padBus.isSoloed = false
        engine.padChannelSoloed = false
        engine.updateMatrix()

        // 7. clearAllSolos() clears all track, bus, and pad solos and snaps back to cached full mix
        eg1Track.isSoloed = true
        bassBus.isSoloed = true
        clickTrack.isSoloed = true
        engine.padChannelSoloed = true
        engine.updateMatrix()
        #expect(engine.hasAnySolo)
        #expect(engine.soloWaveformPeaks != nil)

        engine.clearAllSolos()
        #expect(!engine.hasAnySolo)
        #expect(!eg1Track.isSoloed)
        #expect(!bassBus.isSoloed)
        #expect(!clickTrack.isSoloed)
        #expect(!engine.padChannelSoloed)
        #expect(engine.soloWaveformPeaks == nil)
        #expect(engine.masterWaveformPeaks == cachedFullMix)
        #expect(engine.songWaveformCache[song.id]?.peaks == cachedFullMix)
        #expect(engine.aggregateWaveform == cachedFullMix)

        let versionAfterClear = engine.waveformVersion
        bassTrack.isMuted.toggle()
        engine.updateMatrix()
        #expect(engine.waveformVersion == versionAfterClear)
    }

    @Test
    @MainActor
    func multipleTimeSignatureChangesUpdateBeatGridVersionDenominatorAndMeasures() throws {
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let bufFrames = AVAudioFrameCount(max(4_410, Int(round(16.0 * sr))))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let dummyStemBuf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: bufFrames))
        dummyStemBuf.frameLength = bufFrames

        let song = Song(
            title: "Odd Meter Song",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [
                SongSection(name: "Intro", startTime: 0.0, duration: 4.0),
                SongSection(name: "Turn", startTime: 4.0, duration: 1.0),
                SongSection(name: "Verse 1", startTime: 5.0, duration: 4.0),
                SongSection(name: "Bridge", startTime: 9.0, duration: 1.5),
                SongSection(name: "Chorus", startTime: 10.5, duration: 5.5)
            ],
            excludesClickAndGuide: true
        )

        let stemTrack = StemTrack(name: "Keys", role: .stem)
        engine.currentSetlist = Setlist(name: "Meter Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [(stemTrack, dummyStemBuf)]
        engine.loadSong(song)

        let v0 = engine.beatGridVersion

        // Change #1: 2/4 at 4.0s (Bar 3 -> beats at 4.0, 4.5)
        engine.addTimeSignatureChange(atDisplayTime: 4.0, numerator: 2, denominator: 4)
        let v1 = engine.beatGridVersion
        #expect(v1 > v0)
        #expect(engine.currentSong.timeSignatureChanges.count == 1)

        // Change #2: back to 4/4 at 5.0s (Bar 4 -> beats at 5.0, 5.5, 6.0, 6.5)
        engine.addTimeSignatureChange(atDisplayTime: 5.0, numerator: 4, denominator: 4)
        let v2 = engine.beatGridVersion
        #expect(v2 > v1)
        #expect(engine.currentSong.timeSignatureChanges.count == 2)

        // Change #3: 6/8 at 9.0s (eighth-note beats: 9.0, 9.25, 9.5, 9.75, 10.0, 10.25)
        engine.addTimeSignatureChange(atDisplayTime: 9.0, numerator: 6, denominator: 8)
        let v3 = engine.beatGridVersion
        #expect(v3 > v2)

        // Change #4: 4/4 at 10.5s (quarter-note beats: 10.5, 11.0, 11.5, 12.0)
        engine.addTimeSignatureChange(atDisplayTime: 10.5, numerator: 4, denominator: 4)
        let v4 = engine.beatGridVersion
        #expect(v4 > v3)
        #expect(engine.currentSong.timeSignatureChanges.count == 4)

        let downbeats = engine.precomputedDownbeatMarkers
        let bar4Downbeat = try #require(downbeats.first(where: { $0.bar == 4 }))
        let bar5Downbeat = try #require(downbeats.first(where: { $0.bar == 5 }))
        let bar6Downbeat = try #require(downbeats.first(where: { $0.bar == 6 }))
        let bar7Downbeat = try #require(downbeats.first(where: { $0.bar == 7 }))
        #expect(abs(bar4Downbeat.time - 5.0) < 0.02)
        #expect(abs(bar5Downbeat.time - 7.0) < 0.02)
        #expect(abs(bar6Downbeat.time - 9.0) < 0.02)
        #expect(abs(bar7Downbeat.time - 10.5) < 0.02)

        let bar6Beats = engine.cachedEffectiveBeatGrid.filter { $0.bar == 6 }
        let bar7Beats = engine.cachedEffectiveBeatGrid.filter { $0.bar == 7 }
        #expect(bar6Beats.count == 6)
        #expect(abs((bar6Beats[1].time - bar6Beats[0].time) - 0.25) < 0.01)
        #expect(bar7Beats.count == 4)
        #expect(abs((bar7Beats[1].time - bar7Beats[0].time) - 0.50) < 0.01)

        // Verify section measures reconciled cleanly across all changes
        #expect(engine.currentSong.sections[0].measureCount == 2) // 0..4s in 4/4
        #expect(engine.currentSong.sections[1].measureCount == 1) // 4..5s in 2/4
        #expect(engine.currentSong.sections[2].measureCount == 2) // 5..9s in 4/4
        #expect(engine.currentSong.sections[3].measureCount == 1) // 9..10.5s in 6/8
        #expect(engine.currentSetlist.songs[0].sections == engine.currentSong.sections)

        // Verify update and removal also bump beatGridVersion and update markers
        let thirdChange = engine.currentSong.timeSignatureChanges[2]
        engine.updateTimeSignatureChange(id: thirdChange.id, numerator: 3, denominator: 4)
        let v5 = engine.beatGridVersion
        #expect(v5 > v4)
        let updatedBar6Beats = engine.cachedEffectiveBeatGrid.filter { $0.bar == 6 }
        #expect(updatedBar6Beats.count == 3)
        #expect(abs((updatedBar6Beats[1].time - updatedBar6Beats[0].time) - 0.50) < 0.01)

        engine.removeTimeSignatureChange(id: thirdChange.id)
        let v6 = engine.beatGridVersion
        #expect(v6 > v5)
        #expect(engine.currentSong.timeSignatureChanges.count == 3)

        // Pre-populated quarter-note beatGrid should subdivide when switching into 6/8 and return to 1:1 on 4/4
        let quarterGrid = (0..<32).map { idx in
            BeatGridMarker(time: Double(idx) * 0.5, bar: (idx / 4) + 1, beat: (idx % 4) + 1, instantaneousBPM: 120.0)
        }
        let populatedSong = Song(
            title: "Populated Grid",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [
                SongSection(name: "Intro", startTime: 0.0, duration: 4.0),
                SongSection(name: "Interlude", startTime: 4.0, duration: 1.5),
                SongSection(name: "Outro", startTime: 5.5, duration: 10.5)
            ],
            timeSignatureChanges: [
                TimeSignatureChange(audioTime: 4.0, numerator: 6, denominator: 8),
                TimeSignatureChange(audioTime: 5.5, numerator: 4, denominator: 4)
            ],
            beatGrid: quarterGrid,
            excludesClickAndGuide: true
        )
        let resolvedPopulated = populatedSong.sourceBeatGrid()
        let popBar3Beats = resolvedPopulated.filter { $0.bar == 3 }
        let popBar4Beats = resolvedPopulated.filter { $0.bar == 4 }
        #expect(popBar3Beats.count == 6)
        #expect(abs((popBar3Beats[1].time - popBar3Beats[0].time) - 0.25) < 0.01)
        #expect(popBar4Beats.count == 4)
        #expect(abs(popBar4Beats[0].time - 5.5) < 0.01)
        #expect(abs((popBar4Beats[1].time - popBar4Beats[0].time) - 0.50) < 0.01)
    }

    @Test
    @MainActor
    func cueNextSongSectionToggleGeneratedAndUploadedGuideOverlay() async throws {
        func peakAmplitude(in buffer: AVAudioPCMBuffer, from startTime: TimeInterval, to endTime: TimeInterval) -> Float {
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

        // 1. Codable backwards compatibility & effective transition helper
        var baseSong = Song(
            title: "Segue Part 1",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 8.0)],
            transitionType: .autoLink,
            cueNextSongSection: true
        )
        let encoded = try JSONEncoder().encode(baseSong)
        let decoded = try JSONDecoder().decode(Song.self, from: encoded)
        #expect(decoded.cueNextSongSection)
        #expect(decoded.isCueNextSongSectionEffective(isLastSongInSetlist: false))
        #expect(!decoded.isCueNextSongSectionEffective(isLastSongInSetlist: true))

        var jsonObj = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObj.removeValue(forKey: "cueNextSongSection")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObj)
        let legacyDecoded = try JSONDecoder().decode(Song.self, from: legacyData)
        #expect(!legacyDecoded.cueNextSongSection)

        baseSong.transitionType = .cueNextSong
        #expect(!baseSong.isCueNextSongSectionEffective(isLastSongInSetlist: false))

        // 2. GuideAudioGenerator renders next-song cue in the final bar cleanly
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        let introOnly = [SongSection(name: "Intro", startTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4)]
        let nextChorus = SongSection(name: "Chorus", startTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4)

        let plainGuide = try #require(await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: introOnly,
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 8.0,
                voice: .zoe,
                fallbackVoice: .rita,
                format: format
            )
        }.value)
        #expect(peakAmplitude(in: plainGuide, from: 5.5, to: 8.0) < 0.001)

        let segueGuide = try #require(await Task.detached {
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: introOnly,
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                duration: 8.0,
                voice: .zoe,
                fallbackVoice: .rita,
                nextSongFirstSection: nextChorus,
                nextSongCueTargetTime: 8.0,
                format: format
            )
        }.value)
        #expect(peakAmplitude(in: segueGuide, from: 0.0, to: 5.5) < 0.001)
        #expect(peakAmplitude(in: segueGuide, from: 5.5, to: 8.0) > 0.02)

        // 3. Engine transition toggle, Count In skip rule, and uploaded guide overlay
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let canonSR = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let canonFmt = AVAudioFormat(standardFormatWithSampleRate: canonSR, channels: 2)!
        let song1Frames = AVAudioFrameCount(max(1, Int(round(8.0 * canonSR))))
        let song1StemBuf = try #require(AVAudioPCMBuffer(pcmFormat: canonFmt, frameCapacity: song1Frames))
        song1StemBuf.frameLength = song1Frames
        let silentUploadedGuideBuf = try #require(AVAudioPCMBuffer(pcmFormat: canonFmt, frameCapacity: song1Frames))
        silentUploadedGuideBuf.frameLength = song1Frames

        let song1Stem = StemTrack(name: "Keys", role: .stem)
        let uploadedGuideTrack = StemTrack(
            name: "Guide",
            role: .guide,
            fileURL: URL(fileURLWithPath: "/tmp/pb_uploaded_guide_test.wav")
        )
        let song1 = Song(
            title: "Part 1",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: introOnly,
            transitionType: .autoLink,
            guideSource: .uploaded,
            excludesClickAndGuide: false
        )
        let song2ChorusFirst = Song(
            title: "Part 2",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [nextChorus],
            excludesClickAndGuide: false
        )

        engine.currentSetlist = Setlist(name: "Uploaded Segue Set", songs: [song1, song2ChorusFirst])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song1.id] = [
            (song1Stem, song1StemBuf),
            (uploadedGuideTrack, silentUploadedGuideBuf)
        ]
        engine.uploadedGuideBuffers[song1.id] = silentUploadedGuideBuf
        engine.loadSong(song1)

        // Initially disabled: active uploaded guide remains silent in final bar
        let initialGuideChannelBuf = try #require(engine.channels[uploadedGuideTrack.id]?.buffer)
        #expect(peakAmplitude(in: initialGuideChannelBuf, from: 5.5, to: 8.0) < 0.001)

        // Toggling Cue Next Section ON overlays Chorus + 2, 3, 4 onto uploaded guide without mutating pristine buffer
        engine.updateSongCueNextSongSection(at: 0, enabled: true)
        #expect(engine.currentSong.cueNextSongSection)
        #expect(engine.currentSetlist.songs[0].cueNextSongSection)
        let overlaidChannelBuf = try #require(engine.channels[uploadedGuideTrack.id]?.buffer)
        #expect(peakAmplitude(in: overlaidChannelBuf, from: 5.5, to: 8.0) > 0.02)
        #expect(peakAmplitude(in: silentUploadedGuideBuf, from: 0.0, to: 8.0) < 0.001)

        // Toggling OFF cleanly restores pure uploaded buffer silence
        engine.updateSongCueNextSongSection(at: 0, enabled: false)
        #expect(!engine.currentSong.cueNextSongSection)
        let restoredBuf = try #require(engine.channels[uploadedGuideTrack.id]?.buffer)
        #expect(peakAmplitude(in: restoredBuf, from: 5.5, to: 8.0) < 0.001)

        // Re-enable, then switch to Cue Next Song -> auto-clears cueNextSongSection
        engine.updateSongCueNextSongSection(at: 0, enabled: true)
        #expect(engine.currentSong.cueNextSongSection)
        engine.updateSongTransition(at: 0, type: .cueNextSong)
        #expect(!engine.currentSong.cueNextSongSection)
        #expect(!engine.currentSetlist.songs[0].cueNextSongSection)
        let afterSwitchBuf = try #require(engine.channels[uploadedGuideTrack.id]?.buffer)
        #expect(peakAmplitude(in: afterSwitchBuf, from: 5.5, to: 8.0) < 0.001)

        // If Song 2 starts with Count In, resolvedNextSongSectionCue returns nil to avoid double count-in
        engine.updateSongTransition(at: 0, type: .autoLink)
        engine.updateSongCueNextSongSection(at: 0, enabled: true)
        engine.currentSetlist.songs[1].sections = [
            SongSection(name: "Count In", abbreviation: "Co", startTime: 0.0, duration: 2.0, startMeasure: 1, measureCount: 1),
            SongSection(name: "Chorus", startTime: 2.0, duration: 6.0, startMeasure: 2, measureCount: 3)
        ]
        engine.invalidateStaleNextSongSectionGuides()
        #expect(engine.resolvedNextSongSectionCue(forSongAt: 0, song: engine.currentSong, duration: 8.0) == nil)
        let skipCountInBuf = try #require(engine.channels[uploadedGuideTrack.id]?.buffer)
        #expect(peakAmplitude(in: skipCountInBuf, from: 5.5, to: 8.0) < 0.001)
    }

    @Test
    @MainActor
    func guideSubChannelTrayLevelsMutesSolosAndPersistence() async throws {
        func peakAmplitude(in buffer: AVAudioPCMBuffer, from startTime: TimeInterval, to endTime: TimeInterval) -> Float {
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

        // 1. Gain curve & visible channel titles by guide source
        #expect(abs(GuideSubChannel.linearGain(forFaderVolume: 0.0) - 0.0) < 0.0001)
        #expect(abs(GuideSubChannel.linearGain(forFaderVolume: 0.40) - 0.25) < 0.001)
        #expect(abs(GuideSubChannel.linearGain(forFaderVolume: 0.80) - 1.0) < 0.0001)
        #expect(abs(GuideSubChannel.linearGain(forFaderVolume: 1.0) - powf(10.0, 6.0 / 20.0)) < 0.002)

        #expect(GuideSubChannel.visibleChannels(for: .generated) == [.sections, .directions, .fallback])
        #expect(GuideSubChannel.visibleChannels(for: .generated).map { $0.displayTitle(for: .generated) } == ["Sections", "Directions", "Fallback"])
        #expect(GuideSubChannel.visibleChannels(for: .uploaded) == [.directions, .fallback])
        #expect(GuideSubChannel.visibleChannels(for: .uploaded).map { $0.displayTitle(for: .uploaded) } == ["Guide", "Fallback"])

        // 2. Song & SongPackageMetadata Codable round-trip + backwards-compatibility defaults
        let configuredSong = Song(
            title: "Tray Persistence Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            guideSectionsVolume: 0.65,
            guideSectionsEnabled: false,
            guideDirectionsVolume: 0.90,
            guideDirectionsEnabled: true,
            guideFallbackVolume: 0.40,
            guideFallbackEnabled: false
        )
        let encodedSong = try JSONEncoder().encode(configuredSong)
        let decodedSong = try JSONDecoder().decode(Song.self, from: encodedSong)
        #expect(abs(decodedSong.guideSectionsVolume - 0.65) < 0.0001)
        #expect(decodedSong.guideSectionsEnabled == false)
        #expect(abs(decodedSong.guideDirectionsVolume - 0.90) < 0.0001)
        #expect(decodedSong.guideDirectionsEnabled == true)
        #expect(abs(decodedSong.guideFallbackVolume - 0.40) < 0.0001)
        #expect(decodedSong.guideFallbackEnabled == false)

        var legacyObj = try #require(try JSONSerialization.jsonObject(with: encodedSong) as? [String: Any])
        for k in [
            "guideSectionsVolume", "guideSectionsEnabled",
            "guideDirectionsVolume", "guideDirectionsEnabled",
            "guideFallbackVolume", "guideFallbackEnabled"
        ] {
            legacyObj.removeValue(forKey: k)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObj)
        let legacySong = try JSONDecoder().decode(Song.self, from: legacyData)
        #expect(abs(legacySong.guideSectionsVolume - 0.80) < 0.0001)
        #expect(legacySong.guideSectionsEnabled == true)
        #expect(abs(legacySong.guideDirectionsVolume - 0.80) < 0.0001)
        #expect(legacySong.guideDirectionsEnabled == true)
        #expect(abs(legacySong.guideFallbackVolume - 0.80) < 0.0001)
        #expect(legacySong.guideFallbackEnabled == true)

        let pkgMeta = SongPackageMetadata(
            id: configuredSong.id,
            title: configuredSong.title,
            artist: configuredSong.artist,
            bpm: 120.0,
            guideSectionsVolume: 0.55,
            guideSectionsEnabled: false,
            guideDirectionsVolume: 0.72,
            guideDirectionsEnabled: true,
            guideFallbackVolume: 0.45,
            guideFallbackEnabled: false
        )
        let decodedPkg = try JSONDecoder().decode(SongPackageMetadata.self, from: try JSONEncoder().encode(pkgMeta))
        #expect(abs((decodedPkg.guideSectionsVolume ?? -1) - 0.55) < 0.0001)
        #expect(decodedPkg.guideSectionsEnabled == false)
        #expect(abs((decodedPkg.guideDirectionsVolume ?? -1) - 0.72) < 0.0001)
        #expect(decodedPkg.guideDirectionsEnabled == true)
        #expect(abs((decodedPkg.guideFallbackVolume ?? -1) - 0.45) < 0.0001)
        #expect(decodedPkg.guideFallbackEnabled == false)

        // 3. Fallback phrase detection & Generated Guide mix math
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        let resolvedPrimary = await Task.detached {
            GuideAudioGenerator.shared.resolvePhraseWithFallbackInfo("All In", voice: .rita, fallbackVoice: .zoe, targetFormat: format)
        }.value
        #expect(resolvedPrimary != nil)
        #expect(resolvedPrimary?.usedFallback == false)

        let resolvedSection = await Task.detached {
            GuideAudioGenerator.shared.resolvePhraseWithFallbackInfo("Chorus", voice: .rita, fallbackVoice: .zoe, targetFormat: format)
        }.value
        #expect(resolvedSection != nil)
        #expect(resolvedSection?.usedFallback == false)

        let resolvedFallback = await Task.detached {
            GuideAudioGenerator.shared.resolvePhraseWithFallbackInfo("Zebra Synth Swell", voice: .rita, fallbackVoice: .zoe, targetFormat: format)
        }.value
        #expect(resolvedFallback != nil)
        #expect(resolvedFallback?.usedFallback == true)

        let sections = [
            SongSection(name: "Intro", startTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4),
            SongSection(name: "Chorus", startTime: 8.0, duration: 8.0, startMeasure: 5, measureCount: 4)
        ]
        let cues = [
            DirectionalCue(time: 2.0, label: "All In"),
            DirectionalCue(time: 10.0, label: "Zebra Synth Swell")
        ]

        func renderGenerated(
            sectionsVol: Float = 0.80,
            sectionsEnabled: Bool = true,
            directionsVol: Float = 0.80,
            directionsEnabled: Bool = true,
            fallbackVol: Float = 0.80,
            fallbackEnabled: Bool = true,
            solo: Set<GuideSubChannel> = []
        ) async throws -> (buffer: AVAudioPCMBuffer, meterEvents: [GuideCueMeterEvent]) {
            let res = await Task.detached {
                GuideAudioGenerator.shared.generateGuideBufferWithMeterEvents(
                    sections: sections,
                    directionalCues: cues,
                    bpm: 120.0,
                    timeSignatureNumerator: 4,
                    timeSignatureDenominator: 4,
                    duration: 16.0,
                    voice: .rita,
                    fallbackVoice: .zoe,
                    countInEnabled: true,
                    sectionsVolume: sectionsVol,
                    sectionsEnabled: sectionsEnabled,
                    directionsVolume: directionsVol,
                    directionsEnabled: directionsEnabled,
                    fallbackVolume: fallbackVol,
                    fallbackEnabled: fallbackEnabled,
                    soloedSubChannels: solo,
                    format: format
                )
            }.value
            return try #require(res)
        }

        let unity = try await renderGenerated()
        let basePrimaryDirPeak = peakAmplitude(in: unity.buffer, from: 1.75, to: 3.50)
        let baseSecNamePeak = peakAmplitude(in: unity.buffer, from: 5.75, to: 6.45)
        let baseCountInPeak = peakAmplitude(in: unity.buffer, from: 6.45, to: 7.95)
        let baseFallbackDirPeak = peakAmplitude(in: unity.buffer, from: 9.75, to: 13.0)
        #expect(basePrimaryDirPeak > 0.02)
        #expect(baseSecNamePeak > 0.02)
        #expect(baseCountInPeak > 0.02)
        #expect(baseFallbackDirPeak > 0.02)

        #expect(unity.meterEvents.contains { $0.category == .sections && !$0.usedFallback })
        #expect(unity.meterEvents.contains { $0.category == .directions && !$0.usedFallback })
        #expect(unity.meterEvents.contains { $0.category == .directions && $0.usedFallback })

        // Reducing Sections to 0.40 (~0.25 linear) scales both section name AND count-in, leaving Directions untouched
        let scaledSections = try await renderGenerated(sectionsVol: 0.40)
        #expect(abs(peakAmplitude(in: scaledSections.buffer, from: 5.75, to: 6.45) / baseSecNamePeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: scaledSections.buffer, from: 6.45, to: 7.95) / baseCountInPeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: scaledSections.buffer, from: 1.75, to: 3.50) / basePrimaryDirPeak - 1.0) < 0.02)

        // Reducing Directions to 0.40 scales BOTH primary directional cue AND fallback directional cue (stacked trim)
        let scaledDirections = try await renderGenerated(directionsVol: 0.40)
        #expect(abs(peakAmplitude(in: scaledDirections.buffer, from: 1.75, to: 3.50) / basePrimaryDirPeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: scaledDirections.buffer, from: 9.75, to: 13.0) / baseFallbackDirPeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: scaledDirections.buffer, from: 5.75, to: 6.45) / baseSecNamePeak - 1.0) < 0.02)

        // Reducing Fallback to 0.40 trims ONLY fallback-voiced phrases
        let scaledFallback = try await renderGenerated(fallbackVol: 0.40)
        #expect(abs(peakAmplitude(in: scaledFallback.buffer, from: 9.75, to: 13.0) / baseFallbackDirPeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: scaledFallback.buffer, from: 1.75, to: 3.50) / basePrimaryDirPeak - 1.0) < 0.02)
        #expect(abs(peakAmplitude(in: scaledFallback.buffer, from: 5.75, to: 6.45) / baseSecNamePeak - 1.0) < 0.02)

        // Muting Directions mutes both primary & fallback directional cues; muting Fallback mutes ONLY fallback
        let mutedDirections = try await renderGenerated(directionsEnabled: false)
        #expect(peakAmplitude(in: mutedDirections.buffer, from: 1.75, to: 3.50) < 0.001)
        #expect(peakAmplitude(in: mutedDirections.buffer, from: 9.75, to: 13.0) < 0.001)
        #expect(peakAmplitude(in: mutedDirections.buffer, from: 5.75, to: 6.45) > 0.02)

        let mutedFallback = try await renderGenerated(fallbackEnabled: false)
        #expect(peakAmplitude(in: mutedFallback.buffer, from: 9.75, to: 13.0) < 0.001)
        #expect(peakAmplitude(in: mutedFallback.buffer, from: 1.75, to: 3.50) > 0.02)
        #expect(peakAmplitude(in: mutedFallback.buffer, from: 5.75, to: 6.45) > 0.02)

        // Soloing Fallback isolates only fallback phrases; soloing Sections isolates section + count-in
        let soloFallback = try await renderGenerated(solo: [.fallback])
        #expect(peakAmplitude(in: soloFallback.buffer, from: 1.75, to: 3.50) < 0.001)
        #expect(peakAmplitude(in: soloFallback.buffer, from: 5.75, to: 7.95) < 0.001)
        #expect(peakAmplitude(in: soloFallback.buffer, from: 9.75, to: 13.0) > 0.02)

        let soloSections = try await renderGenerated(solo: [.sections])
        #expect(peakAmplitude(in: soloSections.buffer, from: 1.75, to: 3.50) < 0.001)
        #expect(peakAmplitude(in: soloSections.buffer, from: 9.75, to: 13.0) < 0.001)
        #expect(peakAmplitude(in: soloSections.buffer, from: 5.75, to: 7.95) > 0.02)

        // 4. Uploaded Guide mode + Engine setters, mute preserve/restore, solo, and setlist sync
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let canonSR = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let canonFmt = AVAudioFormat(standardFormatWithSampleRate: canonSR, channels: 2)!
        let songDur: TimeInterval = 8.0
        let totalFrames = AVAudioFrameCount(max(1, Int(round(songDur * canonSR))))
        let stemBuf = try #require(AVAudioPCMBuffer(pcmFormat: canonFmt, frameCapacity: totalFrames))
        stemBuf.frameLength = totalFrames

        // Pristine uploaded guide stem carries a 440 Hz tone during 0.0..1.0s and silence elsewhere
        let uploadedBaseBuf = try #require(AVAudioPCMBuffer(pcmFormat: canonFmt, frameCapacity: totalFrames))
        uploadedBaseBuf.frameLength = totalFrames
        let toneFrames = min(Int(totalFrames), Int(round(1.0 * canonSR)))
        let phaseInc = 2.0 * Float.pi * 440.0 / Float(canonSR)
        for i in 0..<toneFrames {
            let s = 0.25 * sin(phaseInc * Float(i))
            uploadedBaseBuf.floatChannelData?[0][i] = s
            uploadedBaseBuf.floatChannelData?[1][i] = s
        }

        let stemTrack = StemTrack(name: "Keys", role: .stem)
        let guideTrack = StemTrack(name: "Guide", role: .guide, fileURL: URL(fileURLWithPath: "/tmp/pb_uploaded_guide_tray.wav"))
        let uploadedSong = Song(
            title: "Uploaded Tray Test",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: songDur, startMeasure: 1, measureCount: 4)],
            directionalCues: [
                DirectionalCue(time: 2.5, label: "All In"),
                DirectionalCue(time: 5.5, label: "Zebra Synth Swell")
            ],
            guideSource: .uploaded,
            guideVoice: .rita,
            guideFallbackVoice: .zoe,
            speakDirectionalCuesOnUploadedGuide: true,
            excludesClickAndGuide: false
        )

        engine.currentSetlist = Setlist(name: "Guide Tray Set", songs: [uploadedSong])
        engine.currentSongIndex = 0
        engine.songBuffersCache[uploadedSong.id] = [(stemTrack, stemBuf), (guideTrack, uploadedBaseBuf)]
        engine.uploadedGuideBuffers[uploadedSong.id] = uploadedBaseBuf
        engine.loadSong(uploadedSong)

        #expect(engine.visibleGuideSubChannels == [.directions, .fallback])
        let unityUpBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        let upBaseStemPeak = peakAmplitude(in: unityUpBuf, from: 0.0, to: 1.0)
        let upPrimaryPeak = peakAmplitude(in: unityUpBuf, from: 2.2, to: 4.0)
        let upFallbackPeak = peakAmplitude(in: unityUpBuf, from: 5.2, to: 7.5)
        #expect(abs(upBaseStemPeak - 0.25) < 0.01)
        #expect(upPrimaryPeak > 0.02)
        #expect(upFallbackPeak > 0.02)
        // Pristine uploaded buffer must remain untouched beyond 1.0s
        #expect(peakAmplitude(in: uploadedBaseBuf, from: 1.5, to: 8.0) < 0.001)

        // Fallback fader trim affects fallback overlay only and syncs setlist
        engine.setGuideSubChannelVolume(channel: .fallback, volume: 0.40, commit: true)
        #expect(abs(engine.currentSong.guideFallbackVolume - 0.40) < 0.0001)
        #expect(abs(engine.currentSetlist.songs[0].guideFallbackVolume - 0.40) < 0.0001)
        let fbTrimmedUpBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        #expect(abs(peakAmplitude(in: fbTrimmedUpBuf, from: 5.2, to: 7.5) / upFallbackPeak - 0.25) < 0.03)
        #expect(abs(peakAmplitude(in: fbTrimmedUpBuf, from: 2.2, to: 4.0) / upPrimaryPeak - 1.0) < 0.02)
        #expect(abs(peakAmplitude(in: fbTrimmedUpBuf, from: 0.0, to: 1.0) - 0.25) < 0.01)

        // Mute Guide sub-channel mutes overlaid cues while keeping uploaded base audio + preserving fader volume
        engine.setGuideSubChannelVolume(channel: .fallback, volume: 0.80, commit: true)
        engine.toggleGuideSubChannelMute(.directions)
        #expect(engine.currentSong.guideDirectionsEnabled == false)
        #expect(engine.currentSetlist.songs[0].guideDirectionsEnabled == false)
        #expect(abs(engine.currentSong.guideDirectionsVolume - 0.80) < 0.0001)
        let mutedUpBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        #expect(abs(peakAmplitude(in: mutedUpBuf, from: 0.0, to: 1.0) - 0.25) < 0.01)
        #expect(peakAmplitude(in: mutedUpBuf, from: 2.2, to: 4.0) < 0.001)
        #expect(peakAmplitude(in: mutedUpBuf, from: 5.2, to: 7.5) < 0.001)

        engine.toggleGuideSubChannelMute(.directions)
        #expect(engine.currentSong.guideDirectionsEnabled == true)
        let unmutedUpBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        #expect(peakAmplitude(in: unmutedUpBuf, from: 2.2, to: 4.0) > 0.02)

        // Unmuting from 0.0 volume restores unity 0.80
        engine.setGuideSubChannelVolume(channel: .directions, volume: 0.0, commit: true)
        #expect(engine.currentSong.guideDirectionsEnabled == false)
        engine.toggleGuideSubChannelMute(.directions)
        #expect(engine.currentSong.guideDirectionsEnabled == true)
        #expect(abs(engine.currentSong.guideDirectionsVolume - 0.80) < 0.0001)

        // Solo Fallback silences uploaded stem + primary overlay and isolates fallback overlay
        engine.toggleGuideSubChannelSolo(.fallback)
        #expect(engine.guideSoloedSubChannels == [.fallback])
        let soloUpFallbackBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        #expect(peakAmplitude(in: soloUpFallbackBuf, from: 0.0, to: 1.0) < 0.001)
        #expect(peakAmplitude(in: soloUpFallbackBuf, from: 2.2, to: 4.0) < 0.001)
        #expect(peakAmplitude(in: soloUpFallbackBuf, from: 5.2, to: 7.5) > 0.02)

        engine.toggleGuideSubChannelSolo(.fallback)
        #expect(engine.guideSoloedSubChannels.isEmpty)
        let restoredUpBuf = try #require(engine.channels[guideTrack.id]?.buffer)
        #expect(abs(peakAmplitude(in: restoredUpBuf, from: 0.0, to: 1.0) - 0.25) < 0.01)

        // Switching guide source clears guideSoloedSubChannels
        engine.toggleGuideSubChannelSolo(.directions)
        #expect(!engine.guideSoloedSubChannels.isEmpty)
        engine.setGuideSource(.generated)
        #expect(engine.guideSoloedSubChannels.isEmpty)
        #expect(engine.visibleGuideSubChannels == [.sections, .directions, .fallback])
    }

    @Test
    @MainActor
    func midSongTempoChangesRampsCustomCurveAndLiveSync() async throws {
        // 1. Persistence & Legacy Backwards Compatibility
        let customPts = [
            TempoCurvePoint(normalizedTime: 0.25, bpm: 105.0, curveTension: 0.2),
            TempoCurvePoint(normalizedTime: 0.70, bpm: 78.0, curveTension: -0.2)
        ]
        let events: [TempoChangeEvent] = [
            TempoChangeEvent(audioTime: 4.0, targetBPM: 140.0, isRamp: false),
            TempoChangeEvent(audioTime: 8.0, targetBPM: 70.0, isRamp: true, spanMode: .barsBeats, rampBeats: 8.0, curve: .easeIn, curveTension: 0.15),
            TempoChangeEvent(audioTime: 16.0, targetBPM: 96.0, isRamp: true, endAudioTime: 20.0, spanMode: .audioAnchor, lockBeatCountToAudioEnd: false, curve: .custom, customPoints: customPts)
        ]
        let encodedSong = Song(
            title: "Tempo Event Persist",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "G",
            sections: [
                SongSection(name: "Intro", startTime: 0.0, duration: 4.0, startMeasure: 1, measureCount: 2),
                SongSection(name: "Chorus", startTime: 4.0, duration: 20.0, startMeasure: 3, measureCount: 8)
            ],
            tempoEvents: events
        )
        let songData = try JSONEncoder().encode(encodedSong)
        let decodedSong = try JSONDecoder().decode(Song.self, from: songData)
        #expect(decodedSong.tempoEvents.count == 3)
        #expect(decodedSong.tempoEvents[0].isRamp == false)
        #expect(decodedSong.tempoEvents[1].curve == .easeIn)
        #expect(decodedSong.tempoEvents[2].curve == .custom)
        #expect(decodedSong.tempoEvents[2].customPoints.count == 2)

        var legacyJSON = try #require(try JSONSerialization.jsonObject(with: songData) as? [String: Any])
        legacyJSON.removeValue(forKey: "tempoEvents")
        let legacyDecoded = try JSONDecoder().decode(Song.self, from: try JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(legacyDecoded.tempoEvents.isEmpty)

        let pkg = SongPackageMetadata(
            id: encodedSong.id,
            title: encodedSong.title,
            artist: encodedSong.artist,
            bpm: 120.0,
            tempoEvents: events
        )
        let decodedPkg = try JSONDecoder().decode(SongPackageMetadata.self, from: try JSONEncoder().encode(pkg))
        #expect(decodedPkg.tempoEvents.count == 3)

        // 2. Instant Tempo Change + Multiple Time Signatures + Global Tempo Scaling
        var stepSong = Song(
            title: "Instant Jump",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [
                SongSection(name: "Verse", startTime: 0.0, duration: 4.0, startMeasure: 1, measureCount: 2),
                SongSection(name: "Bridge", startTime: 4.0, duration: 8.0, startMeasure: 3, measureCount: 2)
            ],
            tempoEvents: [TempoChangeEvent(audioTime: 4.0, targetBPM: 60.0, isRamp: false)]
        )
        let stepGrid = stepSong.sourceBeatGrid(upToDuration: 12.0)
        let preJump = stepGrid.filter { $0.time < 3.99 }
        #expect(preJump.count == 8)
        #expect(abs((preJump[1].time - preJump[0].time) - 0.5) < 0.01)
        let rawJumpDownbeat = stepGrid.first(where: { abs($0.time - 4.0) < 0.02 })
        let jumpDownbeat = try #require(rawJumpDownbeat)
        #expect(jumpDownbeat.bar == 3 && jumpDownbeat.beat == 1)
        #expect(abs(jumpDownbeat.instantaneousBPM - 60.0) < 0.1)
        let postJumpBeats = stepGrid.filter { $0.time >= 4.0 }
        #expect(postJumpBeats.count >= 4)
        #expect(abs((postJumpBeats[1].time - postJumpBeats[0].time) - 1.0) < 0.01)

        stepSong.reconcileSectionMeasuresWithBeatGrid()
        #expect(stepSong.sections[0].measureCount == 2)
        #expect(stepSong.sections[1].measureCount == 2)

        MultitrackAudioEngine.scaleSongTimeline(&stepSong, from: 120.0, to: 150.0)
        #expect(abs(stepSong.tempoEvents[0].audioTime - 3.2) < 0.01)
        #expect(abs(stepSong.tempoEvents[0].targetBPM - 75.0) < 0.01)

        // 3. Bars/Beats Ramp across curves & Audio-Anchor Auto-Solve
        for curve in [TempoCurveType.linear, .easeIn, .easeOut, .sCurve] {
            let rampEvent = TempoChangeEvent(
                audioTime: 4.0,
                targetBPM: 60.0,
                isRamp: true,
                spanMode: .barsBeats,
                rampBeats: 4.0,
                curve: curve
            )
            let rampSong = Song(
                title: "Ramp \(curve.rawValue)",
                artist: "Band",
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                musicalKey: "D",
                sections: [SongSection(name: "Full", startTime: 0.0, duration: 12.0, startMeasure: 1, measureCount: 5)],
                tempoEvents: [rampEvent]
            )
            let span = try #require(rampSong.resolvedTempoSpans().first)
            let rampGrid = rampSong.sourceBeatGrid(upToDuration: 12.0)
            let bar3Beats = rampGrid.filter { $0.bar == 3 }
            #expect(bar3Beats.count == 4)
            let d0 = bar3Beats[1].time - bar3Beats[0].time
            let d1 = bar3Beats[2].time - bar3Beats[1].time
            let d2 = bar3Beats[3].time - bar3Beats[2].time
            #expect(d0 < d1 && d1 < d2)
            let rawBar4Beat1 = rampGrid.first(where: { $0.bar == 4 && $0.beat == 1 })
            let bar4Beat1 = try #require(rawBar4Beat1)
            #expect(abs(bar4Beat1.time - span.endTime) < 0.025)
            #expect(abs(bar4Beat1.instantaneousBPM - 60.0) < 0.5)
        }

        // Audio-Anchor Lock Beat Count Auto-Solve (120 BPM start, 4 beats from 4.0s to 7.0s -> mean 80 BPM -> linear solved end = 40 BPM)
        let anchorLocked = TempoChangeEvent(
            audioTime: 4.0,
            targetBPM: 90.0,
            isRamp: true,
            endAudioTime: 7.0,
            spanMode: .audioAnchor,
            rampBeats: 4.0,
            lockBeatCountToAudioEnd: true,
            curve: .linear
        )
        let anchorSong = Song(
            title: "Anchor Solve",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "E",
            sections: [SongSection(name: "Full", startTime: 0.0, duration: 12.0, startMeasure: 1, measureCount: 5)],
            tempoEvents: [anchorLocked]
        )
        let anchorSpan = try #require(anchorSong.resolvedTempoSpans().first)
        #expect(abs(anchorSpan.endBPM - 40.0) < 0.5)
        let anchorGrid = anchorSong.sourceBeatGrid(upToDuration: 12.0)
        let rawAnchorBar4Beat1 = anchorGrid.first(where: { $0.bar == 4 && $0.beat == 1 })
        let anchorBar4Beat1 = try #require(rawAnchorBar4Beat1)
        #expect(abs(anchorBar4Beat1.time - 7.0) < 0.025)

        // Unlocked Audio-Anchor preserves explicit targetBPM
        var anchorUnlocked = anchorLocked
        anchorUnlocked.lockBeatCountToAudioEnd = false
        let unlockedSong = Song(title: "Anchor Free", artist: "Band", bpm: 120.0, musicalKey: "E", tempoEvents: [anchorUnlocked])
        #expect(abs((unlockedSong.resolvedTempoSpans().first?.endBPM ?? 0) - 90.0) < 0.1)

        // 4. Drawn Custom DAW Stroke + Live Transport BPM + Continue Click + Click/Guide Sync
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let stemTrack = StemTrack(name: "Keys", role: .stem)
        let testSong = Song(
            title: "Live Curve Sync",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: [
                SongSection(name: "Verse", startTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4),
                SongSection(name: "Outro", startTime: 8.0, duration: 4.0, startMeasure: 5, measureCount: 1)
            ],
            continueClick: true,
            excludesClickAndGuide: false
        )
        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let stemFrames = AVAudioFrameCount(max(1, Int(round(12.0 * sr))))
        let stemBuf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: stemFrames))
        stemBuf.frameLength = stemFrames

        engine.currentSetlist = Setlist(name: "Tempo Curve Set", songs: [testSong])
        engine.currentSongIndex = 0
        engine.songBuffersCache[testSong.id] = [(stemTrack, stemBuf)]
        engine.loadSong(testSong)

        // Draw a 40-point dense S-curve ritardando stroke from (4.0s, 120 BPM) to (8.0s, 60 BPM)
        let strokePoints: [(displayTime: TimeInterval, bpm: Double)] = (0...40).map { idx in
            let u = Double(idx) / 40.0
            let s = u * u * (3.0 - 2.0 * u)
            return (displayTime: 4.0 + u * 4.0, bpm: 120.0 - 60.0 * s)
        }
        engine.applyDrawnTempoStroke(points: strokePoints)

        #expect(engine.currentSong.tempoEvents.count == 1)
        let drawnEv = try #require(engine.currentSong.tempoEvents.first)
        #expect(drawnEv.curve == .custom)
        #expect(drawnEv.spanMode == .audioAnchor)
        #expect(drawnEv.customPoints.count <= 15)
        #expect(abs(engine.currentSong.evaluateBPM(atSourceTime: 6.0) - 90.0) < 8.0)
        #expect(abs(engine.currentSong.evaluateBPM(atSourceTime: 8.5) - 60.0) < 0.5)

        // Live Transport BPM updates smoothly through the ramp and holds ending BPM afterwards
        engine.updateTransportPosition(to: 6.0)
        #expect(engine.transportPosition.currentBPM > 75.0 && engine.transportPosition.currentBPM < 105.0)
        engine.updateTransportPosition(to: 8.5)
        #expect(abs(engine.transportPosition.currentBPM - 60.0) < 0.5)

        // Continue Click resolves to ending BPM (60 BPM), not opening 120 BPM
        let postClickParams = engine.resolvePostSongClickParams(for: engine.currentSong, mode: .stayInSongEnd, duration: 12.0)
        #expect(abs(postClickParams.bpm - 60.0) < 0.5)

        // ClickGenerator & GuideAudioGenerator honor the ramped beat grid
        let effectiveGrid = engine.currentSong.effectiveBeatGrid(totalDuration: 12.0)
        let clickBuf = try #require(ClickGenerator().generateClickBuffer(
            bpm: engine.currentSong.bpm,
            duration: 12.0,
            beatGrid: effectiveGrid,
            sections: engine.currentSong.sections,
            soundType: .beep,
            eighthEnabled: false,
            sixteenthEnabled: false,
            format: fmt
        ))
        let ch0 = try #require(clickBuf.floatChannelData?[0])
        func hasPeak(around t: TimeInterval) -> Bool {
            let center = Int(t * sr)
            let lo = max(0, center - Int(0.02 * sr))
            let hi = min(Int(clickBuf.frameLength) - 1, center + Int(0.02 * sr))
            for i in lo...hi where abs(ch0[i]) > 0.05 { return true }
            return false
        }
        // Check a ramped beat inside [4.0, 8.0] and an ending beat >= 8.0 both trigger clicks accurately
        let rawMidRampMarker = effectiveGrid.first(where: { $0.time > 4.2 && $0.time < 7.8 })
        let rawEndMarker = effectiveGrid.first(where: { $0.time > 8.1 && $0.time < 11.5 })
        let midRampMarker = try #require(rawMidRampMarker)
        let endMarker = try #require(rawEndMarker)
        #expect(hasPeak(around: midRampMarker.time))
        #expect(hasPeak(around: endMarker.time))

        let guideBuf = await Task.detached { [sections = engine.currentSong.sections] in
            GuideAudioGenerator.shared.generateGuideBuffer(
                sections: sections,
                bpm: 120.0,
                duration: 12.0,
                beatGrid: effectiveGrid,
                voice: .zoe,
                fallbackVoice: .zoe,
                format: fmt
            )
        }.value
        #expect(guideBuf != nil)
    }

    @Test
    @MainActor
    func threeFourClickDivisionsAndDoneClosesTempoCurve() async throws {
        // 1. Clicking top-right DONE (toggleEditDrawer -> closeEditMode) closes the Draw Tempo Curve overlay
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        engine.openTempoCurveEditor()
        #expect(engine.isEditDrawerOpen == true)
        #expect(engine.isEditingTempoCurve == true)

        engine.toggleEditDrawer()
        #expect(engine.isEditDrawerOpen == false)
        #expect(engine.isEditingTempoCurve == false)

        // 2. Helper to inspect peak amplitude near an exact timestamp
        let sr = 48_000.0
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        let gen = ClickGenerator()

        func peakAmp(in buf: AVAudioPCMBuffer, around t: TimeInterval) -> Float {
            guard let ch0 = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
            let center = Int(round(t * sr))
            let lo = max(0, center - Int(0.005 * sr))
            let hi = min(Int(buf.frameLength) - 1, center + Int(0.025 * sr))
            guard lo <= hi else { return 0 }
            var m: Float = 0
            for i in lo...hi {
                let v = abs(ch0[i])
                if v > m { m = v }
            }
            return m
        }

        // 3. Fixed BPM Grid in 3/4 (120 BPM -> beats at 0.0, 0.5, 1.0 | 1.5, 2.0, 2.5):
        // Beat 1 = 1/4 (+ Accent), Beats 2 & 3 = 1/8
        let qOnly34 = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            duration: 3.0,
            beatGrid: [],
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: true,
            eighthEnabled: false,
            sixteenthEnabled: false,
            format: fmt
        ))
        #expect(peakAmp(in: qOnly34, around: 0.0) > 0.05)
        #expect(peakAmp(in: qOnly34, around: 0.5) < 0.001)
        #expect(peakAmp(in: qOnly34, around: 1.0) < 0.001)
        #expect(peakAmp(in: qOnly34, around: 1.5) > 0.05)
        #expect(peakAmp(in: qOnly34, around: 2.0) < 0.001)
        #expect(peakAmp(in: qOnly34, around: 2.5) < 0.001)

        let eOnly34 = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            duration: 3.0,
            beatGrid: [],
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: false,
            eighthEnabled: true,
            sixteenthEnabled: false,
            format: fmt
        ))
        #expect(peakAmp(in: eOnly34, around: 0.0) < 0.001)
        #expect(peakAmp(in: eOnly34, around: 0.25) < 0.001)
        #expect(peakAmp(in: eOnly34, around: 0.5) > 0.05)
        #expect(peakAmp(in: eOnly34, around: 0.75) < 0.001)
        #expect(peakAmp(in: eOnly34, around: 1.0) > 0.05)
        #expect(peakAmp(in: eOnly34, around: 1.25) < 0.001)
        #expect(peakAmp(in: eOnly34, around: 1.5) < 0.001)
        #expect(peakAmp(in: eOnly34, around: 2.0) > 0.05)
        #expect(peakAmp(in: eOnly34, around: 2.5) > 0.05)

        let sOnly34 = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            duration: 3.0,
            beatGrid: [],
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: false,
            eighthEnabled: false,
            sixteenthEnabled: true,
            sixteenthVolume: 0.8,
            format: fmt
        ))
        #expect(peakAmp(in: sOnly34, around: 0.0) < 0.001)
        #expect(peakAmp(in: sOnly34, around: 0.25) > 0.05)
        #expect(peakAmp(in: sOnly34, around: 0.5) < 0.001)
        #expect(peakAmp(in: sOnly34, around: 0.75) > 0.05)
        #expect(peakAmp(in: sOnly34, around: 1.0) < 0.001)
        #expect(peakAmp(in: sOnly34, around: 1.25) > 0.05)

        // 4. Dynamic beatGrid with mid-song 4/4 -> 3/4 switch at 2.0s (Bar 2)
        let modMeterSong = Song(
            title: "Meter 4/4 to 3/4",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            timeSignatureChanges: [TimeSignatureChange(audioTime: 2.0, numerator: 3, denominator: 4)]
        )
        let modGrid = modMeterSong.effectiveBeatGrid(totalDuration: 4.0)
        let rawBar2Beat1 = modGrid.first(where: { $0.time >= 1.98 && $0.time <= 2.02 })
        let bar2Beat1 = try #require(rawBar2Beat1)
        #expect(bar2Beat1.beat == 1)
        #expect(bar2Beat1.timeSignatureNumerator == 3)
        #expect(bar2Beat1.timeSignatureDenominator == 4)

        let dynQ = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            duration: 4.0,
            beatGrid: modGrid,
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: true,
            eighthEnabled: false,
            sixteenthEnabled: false,
            format: fmt
        ))
        // Bar 1 (4/4): beat 2 at 0.5s uses 1/4 click
        #expect(peakAmp(in: dynQ, around: 0.5) > 0.05)
        // Bar 2 (3/4): beat 1 at 2.0s uses 1/4 click, beats 2 & 3 at 2.5s & 3.0s do not
        #expect(peakAmp(in: dynQ, around: 2.0) > 0.05)
        #expect(peakAmp(in: dynQ, around: 2.5) < 0.001)
        #expect(peakAmp(in: dynQ, around: 3.0) < 0.001)

        let dynE = try #require(gen.generateClickBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            duration: 4.0,
            beatGrid: modGrid,
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: false,
            eighthEnabled: true,
            sixteenthEnabled: false,
            format: fmt
        ))
        #expect(peakAmp(in: dynE, around: 2.0) < 0.001)
        #expect(peakAmp(in: dynE, around: 2.25) < 0.001)
        #expect(peakAmp(in: dynE, around: 2.5) > 0.05)
        #expect(peakAmp(in: dynE, around: 2.75) < 0.001)
        #expect(peakAmp(in: dynE, around: 3.0) > 0.05)

        // 5. One-bar loop buffer (Continue Click) in 3/4 follows Beat 1 = 1/4, Beats 2 & 3 = 1/8
        let loopQ = try #require(gen.generateOneBarLoopBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: true,
            eighthEnabled: false,
            sixteenthEnabled: false,
            format: fmt
        ))
        #expect(peakAmp(in: loopQ, around: 0.0) > 0.05)
        #expect(peakAmp(in: loopQ, around: 0.5) < 0.001)
        #expect(peakAmp(in: loopQ, around: 1.0) < 0.001)

        let loopE = try #require(gen.generateOneBarLoopBuffer(
            bpm: 120.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            soundType: .beep,
            accentEnabled: false,
            quarterEnabled: false,
            eighthEnabled: true,
            sixteenthEnabled: false,
            format: fmt
        ))
        #expect(peakAmp(in: loopE, around: 0.0) < 0.001)
        #expect(peakAmp(in: loopE, around: 0.5) > 0.05)
        #expect(peakAmp(in: loopE, around: 1.0) > 0.05)
    }

    @Test
    @MainActor
    func removingTempoChangesAndEditingSongBuilderPreservesStemSectionTimings() async throws {
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let barSec = (60.0 / 67.5) * (4.0 / 8.0) * 6.0 // 2.6667s
        let baseSections = [
            SongSection(name: "Count Off", startTime: 0.0, audioStartTime: 0.0, duration: 2 * barSec, startMeasure: 1, measureCount: 2),
            SongSection(name: "Refrain", startTime: 2 * barSec, audioStartTime: 2 * barSec, duration: 2 * barSec, startMeasure: 3, measureCount: 2),
            SongSection(name: "Intro", startTime: 4 * barSec, audioStartTime: 4 * barSec, duration: 22 * barSec, startMeasure: 5, measureCount: 22),
            SongSection(name: "Verse", startTime: 26 * barSec, audioStartTime: 26 * barSec, duration: 10 * barSec, startMeasure: 27, measureCount: 10),
            SongSection(name: "Chorus", startTime: 36 * barSec, audioStartTime: 36 * barSec, duration: 10 * barSec, startMeasure: 37, measureCount: 10)
        ]
        let stemTrack = StemTrack(name: "Drums", role: .stem)
        let song = Song(
            title: "Main Theme Repro",
            artist: "Band",
            bpm: 67.5,
            timeSignatureNumerator: 6,
            timeSignatureDenominator: 8,
            musicalKey: "E",
            sections: baseSections,
            defaultSections: baseSections,
            excludesClickAndGuide: true
        )

        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        let stemBuf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 4.0)))
        stemBuf.frameLength = AVAudioFrameCount(sr * 4.0)

        engine.currentSetlist = Setlist(name: "Stem Preservation Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [(stemTrack, stemBuf)]
        engine.loadSong(song)

        let totalDurBefore = engine.currentSong.sections.map(\.endTime).max() ?? 0.0
        #expect(abs(totalDurBefore - 46.0 * barSec) < 0.05)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) == 46)

        // 1. Add a fast mid-song tempo change -> measure counts inflate while durations remain pinned
        engine.addInstantTempoChange(atDisplayTime: 4 * barSec, bpm: 150.0, snap: false)
        #expect(engine.currentSong.tempoEvents.count == 1)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) > 60)
        let durDuringOverride = engine.currentSong.sections.map(\.endTime).max() ?? 0.0
        #expect(abs(durDuringOverride - totalDurBefore) < 0.05)

        // 2. Clear all tempo events -> measure counts & startMeasure immediately reconcile back to 46 bars
        engine.clearAllTempoEvents()
        #expect(engine.currentSong.tempoEvents.isEmpty)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) == 46)
        #expect(engine.currentSong.defaultSections.map(\.measureCount).reduce(0, +) == 46)
        #expect(engine.currentSong.sections.last?.startMeasure == 37)

        // 3. Add and remove a mid-song time signature change -> measure counts reconcile cleanly back to 46 bars
        engine.addTimeSignatureChange(atDisplayTime: 4 * barSec, numerator: 3, denominator: 8)
        let rawTSChange = engine.currentSong.timeSignatureChanges.first
        let tsChange = try #require(rawTSChange)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) > 60)
        engine.removeTimeSignatureChange(id: tsChange.id)
        #expect(engine.currentSong.timeSignatureChanges.isEmpty)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) == 46)

        // 4. Switch meter/BPM via Song Builder on an existing stem song -> keep timestamps pinned to stems!
        engine.applySongBuilderTempoAndGrid(
            bpm: 135.0,
            timeSignatureNumerator: 3,
            timeSignatureDenominator: 4,
            sections: engine.currentSong.sections,
            isCreatingNewSong: false
        )
        let durAfter135 = engine.currentSong.sections.map(\.endTime).max() ?? 0.0
        #expect(abs(durAfter135 - totalDurBefore) < 0.05)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) == 92)

        engine.applySongBuilderTempoAndGrid(
            bpm: 67.5,
            timeSignatureNumerator: 6,
            timeSignatureDenominator: 8,
            sections: engine.currentSong.sections,
            isCreatingNewSong: false
        )
        let durAfterBack = engine.currentSong.sections.map(\.endTime).max() ?? 0.0
        #expect(abs(durAfterBack - totalDurBefore) < 0.05)
        #expect(engine.currentSong.sections.map(\.measureCount).reduce(0, +) == 46)

        // 5. Click & Pad song (no .stem tracks) still scales durations from measureCount * barDuration
        let clickOnlySong = Song(
            title: "Click Only",
            artist: "",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: Song.makeClickAndPadSections(bpm: 120.0, timeSignatureNumerator: 4, timeSignatureDenominator: 4, infiniteLoop: false, measures: 4)
        )
        engine.currentSetlist = Setlist(name: "Click Only Set", songs: [clickOnlySong])
        engine.currentSongIndex = 0
        engine.loadSong(clickOnlySong)
        engine.applySongBuilderTempoAndGrid(
            bpm: 60.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            sections: engine.currentSong.sections,
            isCreatingNewSong: false
        )
        let clickOnlyDur = engine.currentSong.sections.map(\.endTime).max() ?? 0.0
        // 2 + 4 + 1 = 7 bars at 60 BPM 4/4 = 28.0s
        #expect(abs(clickOnlyDur - 28.0) < 0.05)
    }

    @Test
    @MainActor
    func fadeEndSectionOptionCurvesPersistenceAndExclusivity() async throws {
        // 1. Song.isEndSection & endSectionForFade matching rules
        for name in ["End", "Ending", "The End", "Big End", "End Tag"] {
            let s = SongSection(name: name, startTime: 0, duration: 8.0)
            #expect(Song.isEndSection(s) == true)
        }
        for name in ["Outro", "Bridge", "Verse 2", "Endless"] {
            let s = SongSection(name: name, abbreviation: name == "Outro" ? "O" : "B", startTime: 0, duration: 8.0)
            #expect(Song.isEndSection(s) == false)
        }

        // 2. Song & SongPackageMetadata Codable persistence + legacy backwards compatibility
        let songSections = [
            SongSection(name: "Verse", startTime: 0.0, audioStartTime: 0.0, duration: 10.0, startMeasure: 1, measureCount: 5),
            SongSection(name: "Chorus", startTime: 10.0, audioStartTime: 10.0, duration: 10.0, startMeasure: 6, measureCount: 5),
            SongSection(name: "Ending", abbreviation: "E", startTime: 20.0, audioStartTime: 20.0, duration: 8.0, startMeasure: 11, measureCount: 4)
        ]
        let originalSong = Song(
            title: "Fade End Persist",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "D",
            sections: songSections,
            fadeEndSectionEnabled: true,
            excludesClickAndGuide: false
        )
        let encoded = try JSONEncoder().encode(originalSong)
        let decoded = try JSONDecoder().decode(Song.self, from: encoded)
        #expect(decoded.fadeEndSectionEnabled == true)
        #expect(decoded.endFadeOutEnabled == false)
        #expect(decoded.endSectionForFade?.name == "Ending")

        let meta = SongPackageMetadata(
            id: originalSong.id,
            title: originalSong.title,
            artist: originalSong.artist,
            bpm: originalSong.bpm,
            fadeEndSectionEnabled: true
        )
        let metaData = try JSONEncoder().encode(meta)
        let decodedMeta = try JSONDecoder().decode(SongPackageMetadata.self, from: metaData)
        #expect(decodedMeta.fadeEndSectionEnabled == true)

        // Legacy JSON missing fadeEndSectionEnabled defaults to false
        let rawObj = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var stripped = rawObj
        stripped.removeValue(forKey: "fadeEndSectionEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: stripped)
        let legacyDecoded = try JSONDecoder().decode(Song.self, from: legacyData)
        #expect(legacyDecoded.fadeEndSectionEnabled == false)

        // 3. Engine mutual exclusivity, fade curve, Click/Guide exemption, seek & missing-End safety
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let stemTrack = StemTrack(name: "Keys", role: .stem, volume: 0.80)
        let clickTrack = StemTrack(name: "Click", role: .click, volume: 0.80)
        let guideTrack = StemTrack(name: "Guide", role: .guide, volume: 0.80)

        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        let stemBuf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 2.0)))
        stemBuf.frameLength = AVAudioFrameCount(sr * 2.0)

        engine.currentSetlist = Setlist(name: "Fade End Set", songs: [originalSong])
        engine.currentSongIndex = 0
        engine.songBuffersCache[originalSong.id] = [(stemTrack, stemBuf), (clickTrack, stemBuf), (guideTrack, stemBuf)]
        engine.loadSong(originalSong)
        engine.currentSongDuration = 28.0

        // Mutual exclusivity
        engine.updateSongEndFadeOut(at: 0, enabled: true)
        #expect(engine.currentSong.endFadeOutEnabled == true)
        #expect(engine.currentSong.fadeEndSectionEnabled == false)
        #expect(engine.currentSetlist.songs[0].fadeEndSectionEnabled == false)

        engine.updateSongFadeEndSection(at: 0, enabled: true)
        #expect(engine.currentSong.fadeEndSectionEnabled == true)
        #expect(engine.currentSong.endFadeOutEnabled == false)
        #expect(engine.currentSetlist.songs[0].endFadeOutEnabled == false)

        // Fade window resolves exactly to Ending [20.0, 28.0]
        let rawWin = engine.resolveSongEndFadeWindow(for: engine.currentSong, fallbackDuration: 28.0)
        let win = try #require(rawWin)
        #expect(abs(win.start - 20.0) < 0.01)
        #expect(abs(win.end - 28.0) < 0.01)

        // Pre-fade (18.0s): base volume
        engine.applySongEndFadeIfNeeded(at: 18.0)
        #expect(abs(stemTrack.volume - 0.80) < 0.001)
        #expect(abs(clickTrack.volume - 0.80) < 0.001)
        #expect(abs(guideTrack.volume - 0.80) < 0.001)

        // Midpoint of 8s Ending (24.0s): cosine fade progress 0.5 -> volume 0.40, Click/Guide unaffected
        engine.applySongEndFadeIfNeeded(at: 24.0)
        #expect(abs(stemTrack.volume - 0.40) < 0.01)
        #expect(abs(clickTrack.volume - 0.80) < 0.001)
        #expect(abs(guideTrack.volume - 0.80) < 0.001)

        // End of Ending (28.0s) and slightly beyond (28.5s): volume clamped at 0.0
        engine.applySongEndFadeIfNeeded(at: 28.0)
        #expect(abs(stemTrack.volume - 0.0) < 0.001)
        engine.applySongEndFadeIfNeeded(at: 28.5)
        #expect(abs(stemTrack.volume - 0.0) < 0.001)

        // Seek back before 20.0s -> restores base volume
        engine.seek(to: 10.0)
        #expect(abs(stemTrack.volume - 0.80) < 0.001)

        // Toggling off mid-fade -> restores base volume
        engine.applySongEndFadeIfNeeded(at: 24.0)
        #expect(abs(stemTrack.volume - 0.40) < 0.01)
        engine.updateSongFadeEndSection(at: 0, enabled: false)
        #expect(abs(stemTrack.volume - 0.80) < 0.001)

        // Song with no "End" section safely yields nil window and leaves stem volume untouched
        let noEndSong = Song(
            title: "No End Label",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Outro", abbreviation: "O", startTime: 0.0, audioStartTime: 0.0, duration: 12.0, startMeasure: 1, measureCount: 6)],
            fadeEndSectionEnabled: true
        )
        #expect(engine.resolveSongEndFadeWindow(for: noEndSong, fallbackDuration: 12.0) == nil)
        engine.currentSetlist = Setlist(name: "No End Set", songs: [noEndSong])
        engine.songBuffersCache[noEndSong.id] = [(stemTrack, stemBuf)]
        engine.loadSong(noEndSong)
        engine.currentSongDuration = 12.0
        engine.applySongEndFadeIfNeeded(at: 10.0)
        #expect(abs(stemTrack.volume - 0.80) < 0.001)
    }

    @Test
    @MainActor
    func autoLinkHandoverResetsPreviousSongMetersAndRestoresFadeEndVolumes() async throws {
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.playbackState = .stopped
            engine.clearAllTracks()
        }

        let song1 = Song(
            title: "Song One AutoLink",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [
                SongSection(name: "Verse", startTime: 0.0, audioStartTime: 0.0, duration: 4.0, startMeasure: 1, measureCount: 2),
                SongSection(name: "Ending", abbreviation: "E", startTime: 4.0, audioStartTime: 4.0, duration: 4.0, startMeasure: 3, measureCount: 2)
            ],
            transitionType: .autoLink,
            fadeEndSectionEnabled: true,
            excludesClickAndGuide: true
        )
        let song2 = Song(
            title: "Song Two Next",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "D",
            sections: [
                SongSection(name: "Intro", startTime: 0.0, audioStartTime: 0.0, duration: 8.0, startMeasure: 1, measureCount: 4)
            ],
            excludesClickAndGuide: true
        )

        let sr = engine.getCanonicalProcessingFormat().sampleRate > 0 ? engine.getCanonicalProcessingFormat().sampleRate : 44_100.0
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 2.0)))
        buf.frameLength = AVAudioFrameCount(sr * 2.0)

        let s1Stem = StemTrack(name: "Drums", role: .stem, volume: 0.80)
        let s1Click = StemTrack(name: "Click", role: .click, volume: 0.80)
        let s2Stem = StemTrack(name: "Piano", role: .stem, volume: 0.80)

        engine.currentSetlist = Setlist(name: "AutoLink Meters Set", songs: [song1, song2])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song1.id] = [(s1Stem, buf), (s1Click, buf)]
        engine.songBuffersCache[song2.id] = [(s2Stem, buf)]
        engine.loadSong(song1)
        engine.currentSongDuration = 8.0

        // Simulate hot meters & active Fade End mid-fade right before Song 1 finishes
        s1Stem.peakLevelLeft = 0.82
        s1Stem.peakLevelRight = 0.76
        s1Stem.rawPeakL = 0.82
        s1Stem.rawPeakR = 0.76
        s1Stem.meter.update(left: 0.85, right: 0.72, dt: 0.5)
        s1Click.peakLevelLeft = 0.65
        s1Click.meter.update(left: 0.65, right: 0.65, dt: 0.5)
        engine.clickQuarterMeter.update(left: 0.70, right: 0.70, dt: 0.5)
        engine.guideSectionsMeter.update(left: 0.60, right: 0.60, dt: 0.5)

        engine.applySongEndFadeIfNeeded(at: 6.0)
        #expect(abs(s1Stem.volume - 0.40) < 0.01)

        // Real-time Auto-Link handover to Song 2
        engine.completeRealtimeHandoverToNextSong(currentSeconds: 0.02)
        #expect(engine.currentSong.id == song2.id)
        #expect(engine.songEndBaseVolumes.isEmpty)
        #expect(engine.clickQuarterMeter.left == 0.0)
        #expect(engine.guideSectionsMeter.left == 0.0)

        let rawCached = engine.songBuffersCache[song1.id]
        let cachedSong1Tracks = try #require(rawCached)
        for (cachedTrack, _) in cachedSong1Tracks {
            #expect(cachedTrack.peakLevelLeft == 0.0)
            #expect(cachedTrack.peakLevelRight == 0.0)
            #expect(cachedTrack.rawPeakL == 0.0)
            #expect(cachedTrack.rawPeakR == 0.0)
            #expect(cachedTrack.meter.left == 0.0)
            #expect(cachedTrack.meter.right == 0.0)
        }
        let rawCachedDrums = cachedSong1Tracks.first(where: { $0.0.name == "Drums" })?.0
        let cachedDrums = try #require(rawCachedDrums)
        #expect(abs(cachedDrums.volume - 0.80) < 0.001)

        // Switching back to Song 1 leaves all meters cleanly at 0.0
        engine.selectSongInSetlist(at: 0)
        for tr in engine.tracks {
            #expect(tr.peakLevelLeft == 0.0)
            #expect(tr.peakLevelRight == 0.0)
            #expect(tr.meter.left == 0.0)
            #expect(tr.meter.right == 0.0)
        }

        // Ballistic decay tail: once peakLevel returns to 0.0, tickMeters still drains track.meter all the way to 0.0
        let rawPlayDrums = engine.tracks.first(where: { $0.name == "Drums" })
        let playDrums = try #require(rawPlayDrums)
        playDrums.peakLevelLeft = 0.0
        playDrums.peakLevelRight = 0.0
        playDrums.meter.update(left: 0.25, right: 0.25, dt: 1.0)
        #expect(playDrums.meter.left > 0.2)

        engine.playbackState = .playing
        for _ in 0..<20 {
            engine.tickMeters(dt: 1.0 / 60.0)
        }
        #expect(playDrums.meter.left == 0.0)
        #expect(playDrums.meter.right == 0.0)
    }

    @Test
    func devBuildVersionSemVerComparison() {
        #expect(AppUpdateManager.isVersion("1.1.1", newerThan: "1.1.1-dev.1") == false)
        #expect(AppUpdateManager.isVersion("1.1.1", newerThan: "1.1.1-dev.42") == false)
        #expect(AppUpdateManager.isVersion("1.1.2", newerThan: "1.1.1-dev.1") == true)
        #expect(AppUpdateManager.isVersion("1.2.0", newerThan: "1.1.1-dev.12") == true)
        #expect(AppUpdateManager.isVersion("1.1.1", newerThan: "1.1.1-beta.1") == true)
    }
}
