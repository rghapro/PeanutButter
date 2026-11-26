import Testing
import Foundation
import AVFoundation
import AppKit
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

    @Test
    func sessionStorageLocationDetectsCloudLocalAndUnsaved() {
        let cloudRoot = URL(fileURLWithPath: "/tmp/PeanutButterCloud", isDirectory: true)
        let cloudSetlist = URL(fileURLWithPath: "/tmp/PeanutButterCloud/Setlists/Sunday.pbsession", isDirectory: true)
        let localSetlist = URL(fileURLWithPath: "/tmp/LocalSetlists/Sunday.pbsession", isDirectory: true)
        let siblingPrefixSetlist = URL(fileURLWithPath: "/tmp/PeanutButterCloudBackup/Setlists/Sunday.pbsession", isDirectory: true)

        #expect(MultitrackAudioEngine.sessionStorageLocation(for: nil, cloudRootURL: cloudRoot) == .unsaved)
        #expect(MultitrackAudioEngine.sessionStorageLocation(for: cloudSetlist, cloudRootURL: cloudRoot) == .cloud)
        #expect(MultitrackAudioEngine.sessionStorageLocation(for: localSetlist, cloudRootURL: cloudRoot) == .local)
        #expect(MultitrackAudioEngine.sessionStorageLocation(for: siblingPrefixSetlist, cloudRootURL: cloudRoot) == .local)
    }

    @Test
    @MainActor
    func localSetlistNeverShowsCloudUpdateAlertWhileCloudSetlistDoes() {
        let engine = MultitrackAudioEngine()
        let localURL = URL(fileURLWithPath: "/tmp/PBLocalSetlists/Sunday.pbsession", isDirectory: true)
        let cloudItemURL = (LibraryBrowserManager.shared.cloudSetlistsDirectory
            ?? URL(fileURLWithPath: "/tmp/PBCloud/Setlists", isDirectory: true))
            .appendingPathComponent("Sunday.pbsession", isDirectory: true)

        let cloudUpdateItem = SetlistLibraryItem(
            id: cloudItemURL,
            url: cloudItemURL,
            name: "Sunday",
            songCount: 1,
            formattedDate: "Nov 22, 2026",
            formattedDuration: "4:00",
            artworks: [],
            modifiedDate: Date().addingTimeInterval(300),
            source: .cloud,
            isDownloaded: true,
            hasCloudUpdate: true,
            changeDescription: "Updated key",
            hasUnresolvedServerUpdate: true,
            lastSavedRevisionId: UUID(),
            lastSavedByDeviceId: "other-mac"
        )

        // Open session is Local: even with the same filename ("Sunday.pbsession"), Cloud update alert must stay off
        engine.currentSessionURL = localURL
        engine.updateCloudSetlistUpdateFlag(from: [cloudUpdateItem])
        #expect(engine.hasCloudSetlistUpdate == false)

        // Open session is Cloud at the exact Cloud URL: update alert activates
        if let cloudDir = LibraryBrowserManager.shared.cloudSetlistsDirectory {
            let liveCloudURL = cloudDir.appendingPathComponent("Sunday.pbsession", isDirectory: true)
            let liveCloudItem = SetlistLibraryItem(
                id: liveCloudURL,
                url: liveCloudURL,
                name: "Sunday",
                songCount: 1,
                formattedDate: "Nov 22, 2026",
                formattedDuration: "4:00",
                artworks: [],
                modifiedDate: Date().addingTimeInterval(300),
                source: .cloud,
                isDownloaded: true,
                hasCloudUpdate: true,
                changeDescription: "Updated key",
                hasUnresolvedServerUpdate: true,
                lastSavedRevisionId: UUID(),
                lastSavedByDeviceId: "other-mac"
            )
            engine.currentSessionURL = liveCloudURL
            #expect(engine.shouldShowCloudUpdate(for: liveCloudItem) == true)
            engine.updateCloudSetlistUpdateFlag(from: [liveCloudItem])
            #expect(engine.hasCloudSetlistUpdate == true)
        }
    }

    @Test
    func cloudSetlistReusesLocalSongStemsBeforeCloudUnpack() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_local_stem_reuse_\(UUID().uuidString)", isDirectory: true)
        let tempSongsDir = tempRoot.appendingPathComponent("Songs", isDirectory: true)
        let localSongPkg = tempSongsDir.appendingPathComponent("AmazingGrace.pbsong", isDirectory: true)
        let localStemsDir = localSongPkg.appendingPathComponent("stems", isDirectory: true)
        try fm.createDirectory(at: localStemsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let localSongId = UUID()
        let localKickId = UUID()
        let dummyAudio = Data(repeating: 0x2A, count: 2048)
        try dummyAudio.write(to: localStemsDir.appendingPathComponent("kick.m4a"))

        let localMeta = SongPackageMetadata(
            id: localSongId,
            title: "Amazing Grace",
            artist: "Test Band",
            bpm: 72.0,
            originalBPM: 72.0,
            tracks: [
                TrackFileMetadata(
                    id: localKickId,
                    name: "Kick",
                    role: .stem,
                    relativeAudioPath: "stems/kick.m4a"
                )
            ]
        )
        try JSONEncoder().encode(localMeta).write(to: localSongPkg.appendingPathComponent("song.json"))

        let localIndex = PlaybackFileManager.shared.buildLocalLibraryStemIndex(in: tempSongsDir)
        #expect(localIndex.count == 1)

        // Cloud setlist entry has different song/track UUIDs, matching Title + Artist + BPM + Track Name
        let cloudSongId = UUID()
        let cloudKickId = UUID()
        let cloudEntry = SongPackageMetadata(
            id: cloudSongId,
            title: "Amazing Grace",
            artist: "Test Band",
            bpm: 72.0,
            originalBPM: 72.0,
            tracks: [
                TrackFileMetadata(
                    id: cloudKickId,
                    name: "Kick",
                    role: .stem,
                    relativeAudioPath: "cloudstems/\(cloudSongId.uuidString)/\(cloudKickId.uuidString).m4a"
                )
            ]
        )

        let satisfied = PlaybackFileManager.shared.locallyAvailableTrackIds(
            for: cloudEntry,
            localLibraryIndex: localIndex
        )
        #expect(satisfied == [cloudKickId])

        let cloudPkgPlaceholder = tempRoot.appendingPathComponent("CloudSetlists/Sunday.pbsession", isDirectory: true)
        #expect(
            PlaybackFileManager.shared.unpackCloudStemPackIfNeeded(
                for: cloudEntry,
                rootFolder: cloudPkgPlaceholder,
                satisfiedTrackIds: satisfied
            ) == true
        )
    }

    @Test
    func pruneCloudOnlyDeviceCachesPreservesLocalFilesAndStems() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pb_prune_cloud_\(UUID().uuidString)", isDirectory: true)
        let stemCache = root.appendingPathComponent("StemCache", isDirectory: true)
        let localSetlists = root.appendingPathComponent("Setlists", isDirectory: true)
        let localSongs = root.appendingPathComponent("Songs", isDirectory: true)
        let autoSave = root.appendingPathComponent("AutoSaveSession.pbsession", isDirectory: true)
        try fm.createDirectory(at: stemCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: localSetlists.appendingPathComponent("LocalShow.pbsession", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: localSongs.appendingPathComponent("LocalSong.pbsong", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: autoSave, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let localSetSongId = UUID()
        let localSetTrackId = UUID()
        let localLibSongId = UUID()
        let localLibTrackId = UUID()
        let cloudOnlySongId = UUID()
        let cloudOnlyTrackId = UUID()

        let encoder = JSONEncoder()
        let sessionMeta = SessionPackageMetadata(
            name: "LocalShow",
            songEntries: [
                SongPackageMetadata(
                    id: localSetSongId,
                    title: "Local Set Song",
                    artist: "Band",
                    bpm: 120.0,
                    tracks: [TrackFileMetadata(id: localSetTrackId, name: "Drums", role: .stem, relativeAudioPath: "songs/s/stems/drums.m4a")]
                )
            ]
        )
        try encoder.encode(sessionMeta).write(to: localSetlists.appendingPathComponent("LocalShow.pbsession/session.json"))

        let songMeta = SongPackageMetadata(
            id: localLibSongId,
            title: "Local Lib Song",
            artist: "Band",
            bpm: 120.0,
            tracks: [TrackFileMetadata(id: localLibTrackId, name: "Bass", role: .stem, relativeAudioPath: "stems/bass.m4a")]
        )
        try encoder.encode(songMeta).write(to: localSongs.appendingPathComponent("LocalSong.pbsong/song.json"))
        try Data("autosave".utf8).write(to: autoSave.appendingPathComponent("session.json"))

        let localSetStem = stemCache.appendingPathComponent("\(localSetTrackId.uuidString).m4a")
        let localLibStem = stemCache.appendingPathComponent("\(localLibTrackId.uuidString).m4a")
        let cloudOnlyStem = stemCache.appendingPathComponent("\(cloudOnlyTrackId.uuidString).m4a")
        let localSetTransposed = stemCache.appendingPathComponent("transposed_rb32_\(localSetSongId.uuidString)_2_vf1", isDirectory: true)
        let localLibTransposed = stemCache.appendingPathComponent("transposed_rb32_\(localLibSongId.uuidString)_-1_vf1", isDirectory: true)
        let cloudOnlyTransposed = stemCache.appendingPathComponent("transposed_rb32_\(cloudOnlySongId.uuidString)_2_vf1", isDirectory: true)

        try Data("local1".utf8).write(to: localSetStem)
        try Data("local2".utf8).write(to: localLibStem)
        try Data("cloud".utf8).write(to: cloudOnlyStem)
        for dir in [localSetTransposed, localLibTransposed, cloudOnlyTransposed] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("wav".utf8).write(to: dir.appendingPathComponent("t.wav"))
        }

        // Case A: Non-cloud active session keeps local AutoSave + local caches, removes Cloud-only caches
        LibraryBrowserManager.pruneCloudOnlyDeviceCaches(
            stemCacheDir: stemCache,
            localSetlistsDir: localSetlists,
            localSongsDir: localSongs,
            autoSaveURL: autoSave,
            shouldRemoveAutoSave: false
        )

        #expect(fm.fileExists(atPath: localSetStem.path))
        #expect(fm.fileExists(atPath: localLibStem.path))
        #expect(fm.fileExists(atPath: localSetTransposed.path))
        #expect(fm.fileExists(atPath: localLibTransposed.path))
        #expect(fm.fileExists(atPath: localSetlists.appendingPathComponent("LocalShow.pbsession/session.json").path))
        #expect(fm.fileExists(atPath: localSongs.appendingPathComponent("LocalSong.pbsong/song.json").path))
        #expect(fm.fileExists(atPath: autoSave.path))
        #expect(!fm.fileExists(atPath: cloudOnlyStem.path))
        #expect(!fm.fileExists(atPath: cloudOnlyTransposed.path))

        // Case B: Cloud active session also removes Cloud AutoSave while leaving local files untouched
        LibraryBrowserManager.pruneCloudOnlyDeviceCaches(
            stemCacheDir: stemCache,
            localSetlistsDir: localSetlists,
            localSongsDir: localSongs,
            autoSaveURL: autoSave,
            shouldRemoveAutoSave: true
        )
        #expect(!fm.fileExists(atPath: autoSave.path))
        #expect(fm.fileExists(atPath: localSetStem.path))
        #expect(fm.fileExists(atPath: localLibStem.path))
    }

    @Test
    func uniqueLocalCopyNameAvoidsCollisions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pb_unique_local_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        #expect(LibraryBrowserManager.uniqueLocalCopyName(baseName: "RR - 11.22.26", in: dir) == "RR - 11.22.26 (Local)")
        try fm.createDirectory(at: dir.appendingPathComponent("RR - 11.22.26 (Local).pbsession", isDirectory: true), withIntermediateDirectories: true)
        #expect(LibraryBrowserManager.uniqueLocalCopyName(baseName: "RR - 11.22.26", in: dir) == "RR - 11.22.26 (Local 2)")
        #expect(LibraryBrowserManager.uniqueLocalCopyName(baseName: "RR - 11.22.26 (Local)", in: dir) == "RR - 11.22.26 (Local 2)")
    }

    @Test
    func songAnnouncementPhraseFormatsKeysAndAllCapsTitles() {
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Holy Forever", key: "B") == "Holy Forever, Key of B")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "WASHED", key: "Bb") == "Washed, Key of B flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Spirit & Truth", key: "F#m") == "Spirit and Truth, Key of F sharp minor")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "GREAT ARE YOU LORD", key: "C#m") == "Great Are You Lord, Key of C sharp minor")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "No Key Anthem", key: "") == "No Key Anthem")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "No Key Anthem", key: "—") == "No Key Anthem")
        #expect(MusicalKeyHelper.spokenKeyName(for: "A") == "A")
        #expect(MusicalKeyHelper.spokenKeyName(for: "Ab") == "A flat")
        #expect(MusicalKeyHelper.spokenKeyName(for: "Am") == "A minor")

        var song = Song(
            title: "Holy Forever",
            artist: "Chris Tomlin",
            bpm: 72.0,
            musicalKey: "B",
            transposeSemitones: 2,
            sections: []
        )
        #expect(GuideAudioGenerator.songAnnouncementPhrase(for: song) == "Holy Forever, Key of D flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(for: song, overrideTransposeSemitones: 0) == "Holy Forever, Key of B")
        song.musicalKey = "F#"
        song.transposeSemitones = 2
        #expect(song.title == "Holy Forever" || !song.title.isEmpty)
        #expect(GuideAudioGenerator.songAnnouncementPhrase(for: song) == "Holy Forever, Key of G sharp")

        // Skip standalone "(Live)" / "[Live]" tags in song title announcements
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Who Else (Live)", key: "Ab") == "Who Else, Key of A flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "WHO ELSE (LIVE)", key: "Ab") == "Who Else, Key of A flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Praise You [Live]", key: "B") == "Praise You, Key of B")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Who Else - (Live)", key: "Ab") == "Who Else, Key of A flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "I Live For You (Live)", key: "G") == "I Live For You, Key of G")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "Who Else (Live at Red Rocks)", key: "Ab") == "Who Else (Live at Red Rocks), Key of A flat")
        #expect(GuideAudioGenerator.songAnnouncementPhrase(title: "(Live)", key: "") == "(Live)")
    }

    @Test
    func luxTtsG2pPronouncesMusicalKeyOfAAsLetterName() throws {
        let g2p = try LuxTtsG2p()

        let keyOfAFlat = g2p.phonemize(text: "Holy Forever, Key of A flat.")
        #expect(keyOfAFlat.contains("kˈiː ʌv ˈeeɪ flˌæt"))
        #expect(!keyOfAFlat.contains("ˈeeɪ flˈæt"))
        #expect(!keyOfAFlat.contains("əvə"))
        #expect(!keyOfAFlat.contains("ɐ"))

        let keyOfAMinor = g2p.phonemize(text: "Song Two, Key of A minor.")
        #expect(keyOfAMinor.contains("kˈiː ʌv ˈeeɪ mˌaɪnɚ"))

        let keyOfASharp = g2p.phonemize(text: "Praise, Key of A sharp.")
        #expect(keyOfASharp.contains("kˈiː ʌv ˈeeɪ ʃˌɑːɹp"))

        let keyOfAFlatMinor = g2p.phonemize(text: "Praise, Key of A flat minor.")
        #expect(keyOfAFlatMinor.contains("kˈiː ʌv ˈeeɪ flˌæt mˈaɪnɚ"))

        let keyOfAPlain = g2p.phonemize(text: "Goodness of God, Key of A.")
        #expect(keyOfAPlain.contains("kˈiː ʌv ˈeɪ."))
        #expect(!keyOfAPlain.contains("ˈeeɪ"))
        #expect(!keyOfAPlain.contains("əvə"))

        let articleSong = g2p.phonemize(text: "A Thousand Hallelujahs.")
        #expect(!articleSong.hasPrefix("ˈeɪ"))
        #expect(!articleSong.hasPrefix("ˈeeɪ"))

        let lowercaseArticle = g2p.phonemize(text: "I have a flat tire.")
        #expect(!lowercaseArticle.contains("ˈeeɪ"))

        let normalOfA = g2p.phonemize(text: "Heart of a Servant.")
        #expect(normalOfA.contains("əvə"))

        // Other musical keys retain exact letter phonemes and secondary-stressed modifiers
        #expect(g2p.phonemize(text: "Who Else, Key of B flat.").contains("kˈiː ʌv bˈiː flˌæt"))
        #expect(g2p.phonemize(text: "Who Else, Key of C sharp minor.").contains("kˈiː ʌv sˈiː ʃˌɑːɹp mˈaɪnɚ"))
        #expect(g2p.phonemize(text: "Who Else, Key of D flat.").contains("kˈiː ʌv dˈiː flˌæt"))
        #expect(g2p.phonemize(text: "Who Else, Key of E flat.").contains("kˈiː ʌv ˈiː flˌæt"))
        #expect(g2p.phonemize(text: "Who Else, Key of F sharp minor.").contains("kˈiː ʌv ˈɛf ʃˌɑːɹp mˈaɪnɚ"))
        #expect(g2p.phonemize(text: "Who Else, Key of G.").contains("kˈiː ʌv dʒˈiː."))
    }

    @Test
    func transitionAnnouncementTimingRespectsAutoLinkOverlapCrossfadeAndCueNextSection() {
        let endLongSections = [
            SongSection(name: "Chorus", abbreviation: "C", startTime: 0.0, audioStartTime: 0.0, duration: 60.0, startMeasure: 1, measureCount: 30, playSectionGuideCue: true),
            SongSection(name: "Ending", abbreviation: "E", startTime: 60.0, audioStartTime: 60.0, duration: 12.0, startMeasure: 31, measureCount: 6, playSectionGuideCue: true)
        ]
        var nextSong = Song(
            title: "Holy Forever",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "B",
            sections: [
                SongSection(name: "Count In", abbreviation: "Co", startTime: 0.0, audioStartTime: 0.0, duration: 2.0, startMeasure: 1, measureCount: 1)
            ],
            announceSongEnabled: true
        )

        // 1. Auto-Link (no Cue Next Section): finishes 0.25s before 72.0s -> starts at 69.75s inside Ending
        var songA = Song(
            title: "Song A",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "G",
            sections: endLongSections,
            transitionType: .autoLink
        )
        let autoStart = MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: songA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.0,
            nextSongCueFirstBeatTime: nil
        )
        #expect(autoStart != nil)
        #expect(abs((autoStart ?? -1) - 69.75) < 0.001)

        // 2. Auto-Link + Cue Next Section cue bar starting at 70.0s: finishes 0.25s before 70.0s -> 67.75s
        let autoWithCueStart = MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: songA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.0,
            nextSongCueFirstBeatTime: 70.0
        )
        #expect(autoWithCueStart != nil)
        #expect(abs((autoWithCueStart ?? -1) - 67.75) < 0.001)

        // 3. Overlap (1-bar Count In = 2.0s -> overlap starts at 70.0s): finishes 0.25s before 70.0s -> 67.75s
        songA.transitionType = .overlap
        let overlapStart = MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: songA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.0,
            nextSongCueFirstBeatTime: nil
        )
        #expect(overlapStart != nil)
        #expect(abs((overlapStart ?? -1) - 67.75) < 0.001)

        // 4. Overlap with short Ending (69..72): shifts earlier before Ending's own guide cue bar (67..69)
        var shortEndSongA = songA
        shortEndSongA.sections = [
            SongSection(name: "Chorus", abbreviation: "C", startTime: 0.0, audioStartTime: 0.0, duration: 69.0, startMeasure: 1, measureCount: 34, playSectionGuideCue: true),
            SongSection(name: "Ending", abbreviation: "E", startTime: 69.0, audioStartTime: 69.0, duration: 3.0, startMeasure: 35, measureCount: 2, playSectionGuideCue: true)
        ]
        let shortOverlapStart = MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: shortEndSongA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.5,
            nextSongCueFirstBeatTime: nil
        )
        #expect(shortOverlapStart != nil)
        #expect(abs((shortOverlapStart ?? -1) - 64.25) < 0.02)

        // 5. Crossfade (2 bars of 120 BPM 4/4 = 4.0s -> fade starts at 68.0s): finishes 0.25s before 68.0s -> 65.75s
        songA.transitionType = .crossfade
        let crossfadeStart = MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: songA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.0,
            nextSongCueFirstBeatTime: nil
        )
        #expect(crossfadeStart != nil)
        #expect(abs((crossfadeStart ?? -1) - 65.75) < 0.001)

        // 6. Non-automatic transitions & disabled toggle return nil
        for manualMode in [SongTransitionType.cueNextSong, .stayInSong, .cueFirstSong] {
            songA.transitionType = manualMode
            #expect(MultitrackAudioEngine.transitionAnnouncementStartTime(
                from: songA,
                currentDuration: 72.0,
                to: nextSong,
                announcementDuration: 2.0,
                nextSongCueFirstBeatTime: nil
            ) == nil)
        }
        songA.transitionType = .autoLink
        nextSong.announceSongEnabled = false
        #expect(MultitrackAudioEngine.transitionAnnouncementStartTime(
            from: songA,
            currentDuration: 72.0,
            to: nextSong,
            announcementDuration: 2.0,
            nextSongCueFirstBeatTime: nil
        ) == nil)
    }

    @Test
    func realTimeMixEngineRendersPreSongAndTransitionAnnouncementsOnGuideChannelsOnly() throws {
        let sampleRate = 48_000.0
        let annBuf = try makeTestPCMBuffer(frequency: 660.0, frameCount: 1_024, sampleRate: sampleRate)
        let guideTrackId = UUID()
        let mixState = RealTimeMixEngineState()

        let dummySilent = try makeTestPCMBuffer(frequency: 0.0, frameCount: 256, sampleRate: sampleRate)
        if let d0 = dummySilent.floatChannelData?[0], let d1 = dummySilent.floatChannelData?[1] {
            for i in 0..<256 { d0[i] = 0; d1[i] = 0 }
        }
        let dummyEntry = RenderTrackEntry(
            trackId: guideTrackId,
            peakIndex: 0,
            leftPtr: dummySilent.floatChannelData![0],
            rightPtr: dummySilent.floatChannelData![1],
            frameLength: 256,
            gainL: 0.0,
            gainR: 0.0,
            isClickOrGuide: true,
            isTimelineAligned: true,
            outChannelL: 2,
            outChannelR: 3
        )
        mixState.configure(
            sampleRate: sampleRate,
            totalDuration: 1.0,
            slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: 48_000, sourceStartFrame: 0)],
            tracks: [dummyEntry],
            retainedBuffers: [dummySilent],
            loopActive: false,
            loopIsSingle: false,
            loopStart: 0.0,
            loopEnd: 0.0,
            masterGain: 1.0
        )

        func renderBlocks(blockCount: Int, frameCount: Int = 512) -> [Float] {
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
                for i in 0..<frameCount { c0[i] = 0; c1[i] = 0; c2[i] = 0; c3[i] = 0 }
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
                                var isSil: ObjCBool = false
                                _ = mixState.render(isSilence: &isSil, frameCount: frameCount, audioBufferList: abl)
                            }
                        }
                    }
                }
                let chArr = [c0, c1, c2, c3]
                for ch in 0..<4 {
                    for s in chArr[ch] {
                        let a = abs(s)
                        if a > maxPerChannel[ch] { maxPerChannel[ch] = a }
                    }
                }
            }
            return maxPerChannel
        }

        // Case A: Pre-song manual announcement while stopped renders ONLY on Guide channels (2, 3) and fires completion after breath
        mixState.startPreSongAnnouncement(
            buffer: annBuf,
            trailingBreathSeconds: 0.02, // 960 frames; total = 1024 + 960 = 1984 frames (4 blocks of 512)
            trackId: guideTrackId,
            gainL: 1.0,
            gainR: 1.0,
            outL: 2,
            outR: 3
        )
        let preFirstBlocks = renderBlocks(blockCount: 2, frameCount: 512)
        #expect(preFirstBlocks[0] == 0.0)
        #expect(preFirstBlocks[1] == 0.0)
        #expect(preFirstBlocks[2] > 0.05)
        #expect(preFirstBlocks[3] > 0.05)
        #expect(mixState.consumePreSongAnnouncementFinished() == false)

        let preFinishBlocks = renderBlocks(blockCount: 2, frameCount: 512)
        #expect(preFinishBlocks[0] == 0.0)
        #expect(preFinishBlocks[1] == 0.0)
        #expect(mixState.consumePreSongAnnouncementFinished() == true)

        let postSilent = renderBlocks(blockCount: 1, frameCount: 512)
        #expect(postSilent == [0.0, 0.0, 0.0, 0.0])

        // Case B: Transition announcement is suppressed when loopActive == true
        mixState.configure(
            sampleRate: sampleRate,
            totalDuration: 1.0,
            slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: 48_000, sourceStartFrame: 0)],
            tracks: [dummyEntry],
            retainedBuffers: [dummySilent],
            loopActive: true,
            loopIsSingle: false,
            loopStart: 0.05,
            loopEnd: 0.25,
            masterGain: 1.0
        )
        mixState.configureTransitionAnnouncement(
            enabled: true,
            buffer: annBuf,
            startFrame: 4_800,
            trackId: guideTrackId,
            gainL: 1.0,
            gainR: 1.0,
            outL: 2,
            outR: 3
        )
        mixState.setPlayhead(seconds: 0.0, resumePlaying: true)
        let loopPeaks = renderBlocks(blockCount: 16, frameCount: 512)
        #expect(loopPeaks == [0.0, 0.0, 0.0, 0.0])

        // Case C: With loopActive == false, transition announcement renders ONLY on Guide channels at startFrame = 4800
        mixState.configure(
            sampleRate: sampleRate,
            totalDuration: 1.0,
            slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: 48_000, sourceStartFrame: 0)],
            tracks: [dummyEntry],
            retainedBuffers: [dummySilent],
            loopActive: false,
            loopIsSingle: false,
            loopStart: 0.0,
            loopEnd: 0.0,
            masterGain: 1.0
        )
        mixState.setPlayhead(seconds: 0.0, resumePlaying: true)
        let transPeaks = renderBlocks(blockCount: 16, frameCount: 512)
        #expect(transPeaks[0] == 0.0)
        #expect(transPeaks[1] == 0.0)
        #expect(transPeaks[2] > 0.05)
        #expect(transPeaks[3] > 0.05)
    }

    @Test
    func announceSongEnabledPersistsAcrossSongAndSongEntryCodable() throws {
        let song = Song(
            title: "Holy Forever",
            artist: "Chris Tomlin",
            bpm: 72.0,
            musicalKey: "B",
            sections: [],
            announceSongEnabled: true
        )
        let songData = try JSONEncoder().encode(song)
        let decodedSong = try JSONDecoder().decode(Song.self, from: songData)
        #expect(decodedSong.announceSongEnabled == true)

        let entry = SongPackageMetadata(
            title: "Holy Forever",
            artist: "Chris Tomlin",
            bpm: 72.0,
            musicalKey: "B",
            announceSongEnabled: true
        )
        let entryData = try JSONEncoder().encode(entry)
        let decodedEntry = try JSONDecoder().decode(SongPackageMetadata.self, from: entryData)
        #expect(decodedEntry.announceSongEnabled == true)

        // Backward compatibility when field is absent in older .pbsong / .pbsession files
        var rawSongObj = try #require(try JSONSerialization.jsonObject(with: songData) as? [String: Any])
        rawSongObj.removeValue(forKey: "announceSongEnabled")
        let legacySongData = try JSONSerialization.data(withJSONObject: rawSongObj)
        let decodedLegacySong = try JSONDecoder().decode(Song.self, from: legacySongData)
        #expect(decodedLegacySong.announceSongEnabled == false)

        var rawEntryObj = try #require(try JSONSerialization.jsonObject(with: entryData) as? [String: Any])
        rawEntryObj.removeValue(forKey: "announceSongEnabled")
        let legacyEntryData = try JSONSerialization.data(withJSONObject: rawEntryObj)
        let decodedLegacyEntry = try JSONDecoder().decode(SongPackageMetadata.self, from: legacyEntryData)
        #expect(decodedLegacyEntry.announceSongEnabled == false)
    }

    @Test
    @MainActor
    func audioDeviceSelectionPersistsPreferredInterfaceAcrossRelaunchAndPortChanges() throws {
        let macSpeakers = AudioOutputDevice(id: 10, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", outputChannelCount: 2)
        let x32Port1 = AudioOutputDevice(id: 20, uid: "AppleUSBAudioEngine:BEHRINGER:X-USB:14100000", name: "X-USB", outputChannelCount: 16)
        let x32Port2 = AudioOutputDevice(id: 21, uid: "AppleUSBAudioEngine:BEHRINGER:X-USB:02100000", name: "X-USB", outputChannelCount: 16)

        let suiteName = "com.peanutbutter.tests.deviceref.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // 1. Without a saved preference, resolution picks the macOS System Default
        let initialResolved = AudioDeviceManager.resolveTargetDevice(
            from: [macSpeakers, x32Port1],
            currentSelected: nil,
            preferredUID: suite.string(forKey: AudioDeviceManager.preferredDeviceUIDKey),
            preferredName: suite.string(forKey: AudioDeviceManager.preferredDeviceNameKey),
            systemDefaultID: macSpeakers.id
        )
        #expect(initialResolved?.id == macSpeakers.id)

        // 2. Persist X-USB and simulate app relaunch where macOS System Default is still MacBook Speakers
        AudioDeviceManager.shared.persistPreferredDevice(x32Port1, defaults: suite)
        let relaunchResolved = AudioDeviceManager.resolveTargetDevice(
            from: [macSpeakers, x32Port1],
            currentSelected: nil,
            preferredUID: suite.string(forKey: AudioDeviceManager.preferredDeviceUIDKey),
            preferredName: suite.string(forKey: AudioDeviceManager.preferredDeviceNameKey),
            systemDefaultID: macSpeakers.id
        )
        #expect(relaunchResolved?.uid == x32Port1.uid)

        // 3. Port swap (new UID on X-USB) still resolves to X-USB via case-insensitive name fallback
        let portSwapResolved = AudioDeviceManager.resolveTargetDevice(
            from: [macSpeakers, AudioOutputDevice(id: 21, uid: x32Port2.uid, name: "x-usb", outputChannelCount: 16)],
            currentSelected: macSpeakers,
            preferredUID: suite.string(forKey: AudioDeviceManager.preferredDeviceUIDKey),
            preferredName: suite.string(forKey: AudioDeviceManager.preferredDeviceNameKey),
            systemDefaultID: macSpeakers.id
        )
        #expect(portSwapResolved?.id == x32Port2.id)

        // 4. Unplugging X-USB temporarily falls back to macOS System Default, then snapping back restores X-USB when reconnected
        let unpluggedResolved = AudioDeviceManager.resolveTargetDevice(
            from: [macSpeakers],
            currentSelected: x32Port1,
            preferredUID: suite.string(forKey: AudioDeviceManager.preferredDeviceUIDKey),
            preferredName: suite.string(forKey: AudioDeviceManager.preferredDeviceNameKey),
            systemDefaultID: macSpeakers.id
        )
        #expect(unpluggedResolved?.id == macSpeakers.id)

        let reconnectedResolved = AudioDeviceManager.resolveTargetDevice(
            from: [macSpeakers, x32Port2],
            currentSelected: macSpeakers,
            preferredUID: suite.string(forKey: AudioDeviceManager.preferredDeviceUIDKey),
            preferredName: suite.string(forKey: AudioDeviceManager.preferredDeviceNameKey),
            systemDefaultID: macSpeakers.id
        )
        #expect(reconnectedResolved?.id == x32Port2.id)
    }

    @Test
    @MainActor
    func busRoutingAndStageSignalsSurviveUIDChangeAndDeviceSwitches() throws {
        let suiteName = "com.peanutbutter.tests.busrouting.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer {
            engine.playbackState = .stopped
            engine.clearAllTracks()
        }

        let x32Port1 = AudioOutputDevice(id: 101, uid: "AppleUSB:X32:14200000", name: "X-USB", outputChannelCount: 16)
        let x32Port2 = AudioOutputDevice(id: 102, uid: "AppleUSB:X32:02100000", name: "X-USB", outputChannelCount: 16)
        let macSpeakers = AudioOutputDevice(id: 50, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", outputChannelCount: 2)

        let clickBus = try #require(engine.busses.first(where: { $0.name == "Click" }))
        let guideBus = try #require(engine.busses.first(where: { $0.name == "Guide" }))
        let drumsBus = try #require(engine.busses.first(where: { $0.name == "Drums" }))
        let vocalsBus = try #require(engine.busses.first(where: { $0.name == "Vocals" }))

        clickBus.physicalOutputChannel = "Out 3/4"
        clickBus.isMono = false
        guideBus.physicalOutputChannel = "Out 3/4"
        guideBus.isMono = false
        drumsBus.physicalOutputChannel = "Out 5/6"
        drumsBus.isMono = false
        vocalsBus.physicalOutputChannel = "Out 9"
        vocalsBus.isMono = true

        engine.isRedundancyEnabled = true
        engine.redundancyOutputChannel = "Out 15"
        engine.isSMPTEEnabled = true
        engine.smpteOutputChannel = "Out 16"
        engine.smpteFrameRate = .fps25

        engine.saveBusRouting(for: x32Port1, defaults: suite)
        engine.saveStageSignalPreset(for: x32Port1, defaults: suite)

        // Switching onto 2-ch MacBook Speakers resets active busses for that device without wiping X-USB storage
        engine.loadBusRouting(for: macSpeakers, defaults: suite)
        engine.loadStageSignalPreset(for: macSpeakers, defaults: suite)
        #expect(drumsBus.physicalOutputChannel == "Out 1/2")
        #expect(vocalsBus.physicalOutputChannel == "Out 1/2")
        #expect(vocalsBus.isMono == false)
        #expect(engine.isRedundancyEnabled == false)
        #expect(engine.isSMPTEEnabled == false)

        // Reconnecting X-USB under a brand-new USB port UID restores every bus & stage signal via name fallback
        engine.loadBusRouting(for: x32Port2, defaults: suite)
        engine.loadStageSignalPreset(for: x32Port2, defaults: suite)
        #expect(clickBus.physicalOutputChannel == "Out 3/4")
        #expect(guideBus.physicalOutputChannel == "Out 3/4")
        #expect(drumsBus.physicalOutputChannel == "Out 5/6")
        #expect(drumsBus.isMono == false)
        #expect(vocalsBus.physicalOutputChannel == "Out 9")
        #expect(vocalsBus.isMono == true)
        #expect(engine.isRedundancyEnabled == true)
        #expect(engine.redundancyOutputChannel == "Out 15")
        #expect(engine.isSMPTEEnabled == true)
        #expect(engine.smpteOutputChannel == "Out 16")
        #expect(engine.smpteFrameRate == .fps25)

        // Primary UID keys should now also be populated for the new port UID
        #expect(suite.data(forKey: "Playback_BusRouting_\(x32Port2.uid)") != nil)
        #expect(suite.data(forKey: "Playback_StageSignals_\(x32Port2.uid)") != nil)
    }

    @Test
    @MainActor
    func clearAllMIDICuesClearsCurrentSongSetlistAndSelection() throws {
        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        defer { engine.clearAllTracks() }

        let cue1 = MIDICue(time: 1.0, bus: .lyrics, messageType: .note, primaryValue: 19, secondaryValue: 1)
        let cue2 = MIDICue(time: 4.0, bus: .lights1, messageType: .note, primaryValue: 24, secondaryValue: 127)
        let song = Song(
            title: "Cue Test Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 8.0)],
            defaultMidiCues: [cue1, cue2],
            midiCues: [cue1, cue2]
        )

        engine.currentSetlist = Setlist(name: "MIDI Clear Set", songs: [song])
        engine.currentSongIndex = 0
        engine.currentSong = song
        engine.selectedMIDICueId = cue1.id
        engine.isNudgingMIDICue = true
        engine.requestedEditMIDICueId = cue2.id

        engine.clearAllMIDICues()

        #expect(engine.currentSong.midiCues.isEmpty)
        #expect(engine.currentSong.defaultMidiCues.isEmpty)
        #expect(engine.currentSetlist.songs[0].midiCues.isEmpty)
        #expect(engine.currentSetlist.songs[0].defaultMidiCues.isEmpty)
        #expect(engine.selectedMIDICueId == nil)
        #expect(engine.isNudgingMIDICue == false)
        #expect(engine.requestedEditMIDICueId == nil)

        // Calling again when already empty is a clean no-op
        engine.clearAllMIDICues()
        #expect(engine.currentSong.midiCues.isEmpty)
        #expect(engine.selectedMIDICueId == nil)
        #expect(engine.isNudgingMIDICue == false)
        #expect(engine.requestedEditMIDICueId == nil)
    }

    @Test
    func luxTtsG2pPronouncesParentheticalLiveAsLivePerformance() throws {
        let g2p = try LuxTtsG2p()

        let whoElseLive = g2p.phonemize(text: "Who Else (Live), Key of A flat.")
        #expect(whoElseLive.contains("ˈɛls lˈaaɪv,"))
        #expect(!whoElseLive.contains("ˈɛls, lˈaaɪv"))
        #expect(!whoElseLive.contains("lˈɪv"))
        #expect(whoElseLive.contains("ˈeeɪ flˌæt"))
        #expect(!whoElseLive.contains("ˈeeɪ flˈæt"))

        let praiseYouLive = g2p.phonemize(text: "Praise You (Live), Key of B.")
        #expect(praiseYouLive.contains("juː lˈaaɪv,"))
        #expect(!praiseYouLive.contains("lˈɪv"))

        let liveAtShow = g2p.phonemize(text: "Who (Live at Sunset), Key of C.")
        #expect(liveAtShow.contains("lˈaɪv"))
        #expect(!liveAtShow.contains("lˈɪv"))

        let mixedVerbAndLive = g2p.phonemize(text: "I Live For You (Live), Key of G.")
        #expect(mixedVerbAndLive.contains("lˈɪv"))
        #expect(mixedVerbAndLive.contains("lˈaaɪv"))

        let pureVerb = g2p.phonemize(text: "To Live Is Christ.")
        #expect(pureVerb.contains("lˈɪv"))
        #expect(!pureVerb.contains("lˈaɪv"))
        #expect(!pureVerb.contains("lˈaaɪv"))
    }

    @Test
    func voiceCloneTrimRemovesLeadingClickAndDetachedTrailingGruntWhileKeepingSpeech() {
        let sr = 48_000.0
        func toneSamples(seconds: Double, amplitude: Float, freq: Double = 220.0) -> [Float] {
            let count = Int(round(seconds * sr))
            return (0..<count).map { i in
                amplitude * Float(sin(2.0 * Double.pi * freq * Double(i) / sr))
            }
        }
        func silenceSamples(seconds: Double) -> [Float] {
            [Float](repeating: 0.0, count: Int(round(seconds * sr)))
        }
        func rmsPeak(_ samples: [Float], from sSec: Double, to eSec: Double) -> Float {
            let s = max(0, min(samples.count, Int(round(sSec * sr))))
            let e = max(s, min(samples.count, Int(round(eSec * sr))))
            guard e > s else { return 0.0 }
            var peak: Float = 0.0
            for i in s..<e { peak = max(peak, abs(samples[i])) }
            return peak
        }

        // 0.00..0.06s leading blip (-16 dB) -> 0.16s silence -> 0.22..1.20s real speech (-8 dB) -> 0.50s silence -> 1.70..1.84s trailing "mm" grunt (-15 dB)
        var rawWithBothArtifacts: [Float] = []
        rawWithBothArtifacts.append(contentsOf: toneSamples(seconds: 0.06, amplitude: 0.15, freq: 140.0))
        rawWithBothArtifacts.append(contentsOf: silenceSamples(seconds: 0.16))
        rawWithBothArtifacts.append(contentsOf: toneSamples(seconds: 0.98, amplitude: 0.40, freq: 310.0))
        rawWithBothArtifacts.append(contentsOf: silenceSamples(seconds: 0.50))
        rawWithBothArtifacts.append(contentsOf: toneSamples(seconds: 0.14, amplitude: 0.18, freq: 130.0))
        rawWithBothArtifacts.append(contentsOf: silenceSamples(seconds: 0.10))

        #expect(VoiceCloneService.countBoundaryArtifactIslands(rawWithBothArtifacts, sampleRate: sr) == 2)
        let cleaned = VoiceCloneService.trimCleanHeadPreserveTail(rawWithBothArtifacts, sampleRate: sr)
        let cleanedDur = Double(cleaned.count) / sr
        #expect(cleanedDur > 0.90 && cleanedDur < 1.25)
        // Main speech peak is preserved; leading blip and trailing grunt were stripped
        #expect(rmsPeak(cleaned, from: 0.05, to: cleanedDur - 0.05) > 0.35)
        #expect(VoiceCloneService.countBoundaryArtifactIslands(cleaned, sampleRate: sr) == 0)

        // Short pause between title word ("Key of A") and final word ("Flat", 0.10s gap, 0.26s word) must NOT be dropped
        var legitimateTwoWords: [Float] = []
        legitimateTwoWords.append(contentsOf: silenceSamples(seconds: 0.20))
        legitimateTwoWords.append(contentsOf: toneSamples(seconds: 0.70, amplitude: 0.35, freq: 280.0))
        legitimateTwoWords.append(contentsOf: silenceSamples(seconds: 0.10))
        legitimateTwoWords.append(contentsOf: toneSamples(seconds: 0.26, amplitude: 0.32, freq: 340.0))
        legitimateTwoWords.append(contentsOf: silenceSamples(seconds: 0.15))

        #expect(VoiceCloneService.countBoundaryArtifactIslands(legitimateTwoWords, sampleRate: sr) == 0)
        let keptLegit = VoiceCloneService.trimCleanHeadPreserveTail(legitimateTwoWords, sampleRate: sr)
        let keptDur = Double(keptLegit.count) / sr
        #expect(keptDur > 1.00)
        #expect(rmsPeak(keptLegit, from: keptDur - 0.25, to: keptDur - 0.05) > 0.25)
    }

    @Test
    @MainActor
    func transitionAnnouncementsRenderAcrossAutoLinkOverlapCrossfadeSeekPreRollAndExcludedSong() throws {
        let sampleRate = 48_000.0
        let blockFrames = 512

        func renderRange(mixState: RealTimeMixEngineState, totalSeconds: TimeInterval) -> [Float] {
            var maxPerChannel = [Float](repeating: 0.0, count: 4)
            let blocks = max(1, Int(ceil((totalSeconds * sampleRate) / Double(blockFrames))))
            var c0 = [Float](repeating: 0.0, count: blockFrames)
            var c1 = [Float](repeating: 0.0, count: blockFrames)
            var c2 = [Float](repeating: 0.0, count: blockFrames)
            var c3 = [Float](repeating: 0.0, count: blockFrames)
            let ablSize = MemoryLayout<AudioBufferList>.size + 3 * MemoryLayout<AudioBuffer>.size
            let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawABL.deallocate() }
            let abl = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)

            for _ in 0..<blocks {
                for i in 0..<blockFrames { c0[i] = 0; c1[i] = 0; c2[i] = 0; c3[i] = 0 }
                abl.pointee.mNumberBuffers = 4
                c0.withUnsafeMutableBufferPointer { p0 in
                    c1.withUnsafeMutableBufferPointer { p1 in
                        c2.withUnsafeMutableBufferPointer { p2 in
                            c3.withUnsafeMutableBufferPointer { p3 in
                                let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
                                let ptrs = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!, p3.baseAddress!]
                                for ch in 0..<4 {
                                    ablPtr[ch].mNumberChannels = 1
                                    ablPtr[ch].mDataByteSize = UInt32(blockFrames * MemoryLayout<Float>.size)
                                    ablPtr[ch].mData = UnsafeMutableRawPointer(ptrs[ch])
                                }
                                var isSil: ObjCBool = false
                                _ = mixState.render(isSilence: &isSil, frameCount: blockFrames, audioBufferList: abl)
                            }
                        }
                    }
                }
                let chArr = [c0, c1, c2, c3]
                for ch in 0..<4 {
                    for s in chArr[ch] {
                        let a = abs(s)
                        if a > maxPerChannel[ch] { maxPerChannel[ch] = a }
                    }
                }
            }
            return maxPerChannel
        }

        let annDuration = 1.0
        let annFrames = Int(round(annDuration * sampleRate))
        let annBuf = try makeTestPCMBuffer(frequency: 660.0, frameCount: AVAudioFrameCount(annFrames), sampleRate: sampleRate)
        let guideTrackId = UUID()
        let mixState = RealTimeMixEngineState()

        let songDur = 10.0
        let songFrames = Int(round(songDur * sampleRate))
        let dummySilent = try makeTestPCMBuffer(frequency: 0.0, frameCount: AVAudioFrameCount(songFrames), sampleRate: sampleRate)
        if let d0 = dummySilent.floatChannelData?[0], let d1 = dummySilent.floatChannelData?[1] {
            for i in 0..<songFrames { d0[i] = 0; d1[i] = 0 }
        }
        let nextStem = try makeTestPCMBuffer(frequency: 440.0, frameCount: AVAudioFrameCount(songFrames), sampleRate: sampleRate)

        let guideEntry = RenderTrackEntry(
            trackId: guideTrackId,
            peakIndex: 0,
            leftPtr: dummySilent.floatChannelData![0],
            rightPtr: dummySilent.floatChannelData![1],
            frameLength: Int64(songFrames),
            gainL: 0.0,
            gainR: 0.0,
            isClickOrGuide: true,
            isTimelineAligned: true,
            outChannelL: 2,
            outChannelR: 3
        )
        let nextMusicEntry = RenderTrackEntry(
            trackId: UUID(),
            peakIndex: 0,
            leftPtr: nextStem.floatChannelData![0],
            rightPtr: nextStem.floatChannelData![1],
            frameLength: Int64(songFrames),
            gainL: 1.0,
            gainR: 1.0,
            isClickOrGuide: false,
            isTimelineAligned: false,
            outChannelL: 0,
            outChannelR: 1
        )

        let endingSections = [
            SongSection(name: "Chorus", abbreviation: "C", startTime: 0.0, audioStartTime: 0.0, duration: 5.0, startMeasure: 1, measureCount: 2, playSectionGuideCue: false),
            SongSection(name: "Ending", abbreviation: "E", startTime: 5.0, audioStartTime: 5.0, duration: 5.0, startMeasure: 3, measureCount: 3, playSectionGuideCue: false)
        ]
        let nextSong = Song(
            title: "Who Else (Live)",
            artist: "Band",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "Ab",
            sections: [SongSection(name: "Count In", abbreviation: "Co", startTime: 0.0, duration: 2.0, startMeasure: 1, measureCount: 1)],
            announceSongEnabled: true
        )

        // Verify all 3 modes (autoLink, overlap, crossfade) + excludesClickAndGuide outgoing song + deadline re-anchoring
        for mode in [SongTransitionType.autoLink, .overlap, .crossfade] {
            let songA = Song(
                title: "Excluded Opener",
                artist: "Band",
                bpm: 120.0,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 4,
                musicalKey: "C",
                sections: endingSections,
                transitionType: mode,
                excludesClickAndGuide: true
            )
            let timing = try #require(
                MultitrackAudioEngine.transitionAnnouncementTiming(
                    from: songA,
                    currentDuration: songDur,
                    to: nextSong,
                    announcementDuration: annDuration,
                    nextSongCueFirstBeatTime: nil
                )
            )
            let transitionSec: TimeInterval = {
                switch mode {
                case .autoLink: return 10.0
                case .overlap: return 8.0
                case .crossfade: return 6.0
                default: return 10.0
                }
            }()
            #expect(timing.startTime + annDuration <= transitionSec - 0.24)
            #expect(timing.deadline <= transitionSec - 0.04)

            let transFrame = Int64(round(transitionSec * sampleRate))
            let startFrame = Int64(round(timing.startTime * sampleRate))
            let deadlineFrame = Int64(round(timing.deadline * sampleRate))

            mixState.configure(
                sampleRate: sampleRate,
                totalDuration: songDur,
                slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: Int64(songFrames), sourceStartFrame: 0)],
                tracks: [guideEntry],
                retainedBuffers: [dummySilent, nextStem],
                loopActive: false,
                loopIsSingle: false,
                loopStart: 0.0,
                loopEnd: 0.0,
                masterGain: 1.0,
                transitionMode: mode,
                transitionStartFrame: transFrame,
                nextTotalTimelineFrames: Int64(songFrames),
                nextSlices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: Int64(songFrames), sourceStartFrame: 0)],
                nextTracks: [nextMusicEntry]
            )
            mixState.configureTransitionAnnouncement(
                enabled: true,
                buffer: annBuf,
                startFrame: startFrame,
                deadlineFrame: deadlineFrame,
                trackId: guideTrackId,
                gainL: 1.0,
                gainR: 1.0,
                outL: 2,
                outR: 3
            )

            // 1. Seek slightly AFTER scheduled start (leaving 0.1s extra headroom before deadline): still re-anchors and plays!
            let lateButValidSeek = timing.startTime + 0.10
            mixState.setPlayhead(seconds: lateButValidSeek, resumePlaying: true)
            let beforeTransition = renderRange(mixState: mixState, totalSeconds: max(0.2, transitionSec - lateButValidSeek - 0.02))
            #expect(beforeTransition[2] > 0.05)
            #expect(beforeTransition[3] > 0.05)

            // 2. Seek TOO late (after deadline - annDuration + 0.15s): stays disarmed so it won't crash into Song B
            let tooLateSeek = min(songDur - 0.2, timing.deadline - annDuration + 0.15)
            mixState.setPlayhead(seconds: tooLateSeek, resumePlaying: true)
            let disarmedPeaks = renderRange(mixState: mixState, totalSeconds: max(0.1, transitionSec - tooLateSeek - 0.02))
            #expect(disarmedPeaks[2] == 0.0)
            #expect(disarmedPeaks[3] == 0.0)

            // 3. Start via Section Pre-Roll (startPreRoll) earlier than scheduled start: arms cleanly!
            let preRollStartFrame = max(0, startFrame - Int64(round(0.5 * sampleRate)))
            mixState.startPreRoll(preRollStartFrame: preRollStartFrame, targetDownbeatFrame: preRollStartFrame + 4800)
            mixState.setPlaying(true)
            let preRollPeaks = renderRange(mixState: mixState, totalSeconds: 1.8)
            #expect(preRollPeaks[2] > 0.05)
            #expect(preRollPeaks[3] > 0.05)

            _ = songA.id
        }
    }

    @Test
    func songFolderImporterScansStemsAndDefaultsArtwork() throws {
        let fm = FileManager.default
        let rootDir = fm.temporaryDirectory.appendingPathComponent("pb_folder_import_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootDir) }

        func makeValidPNGData(color: NSColor) throws -> Data {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 8,
                pixelsHigh: 8,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                color.setFill()
                NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return try #require(rep.representation(using: .png, properties: [:]))
        }

        let validPNG = try makeValidPNGData(color: .systemBlue)
        let secondaryPNG = try makeValidPNGData(color: .systemGreen)

        // 1. Folder with nested stems, __MACOSX / ._ noise, corrupt album.jpg, valid cover.png, and valid random.png
        let songDir = rootDir.appendingPathComponent("Holy Forever", isDirectory: true)
        let nestedStems = songDir.appendingPathComponent("Stems", isDirectory: true)
        let macosxDir = songDir.appendingPathComponent("__MACOSX", isDirectory: true)
        try fm.createDirectory(at: nestedStems, withIntermediateDirectories: true)
        try fm.createDirectory(at: macosxDir, withIntermediateDirectories: true)

        try Data([0x00, 0x01]).write(to: songDir.appendingPathComponent("Drums.wav"))
        try Data([0x00, 0x01]).write(to: songDir.appendingPathComponent("Bass.m4a"))
        try Data([0x00, 0x01]).write(to: nestedStems.appendingPathComponent("Keys.mp3"))
        try Data([0x00, 0x01]).write(to: songDir.appendingPathComponent("._Drums.wav"))
        try Data([0x00, 0x01]).write(to: macosxDir.appendingPathComponent("Drums.wav"))

        try Data("not-an-image".utf8).write(to: songDir.appendingPathComponent("album.jpg"))
        try validPNG.write(to: songDir.appendingPathComponent("cover.png"))
        try secondaryPNG.write(to: songDir.appendingPathComponent("random.png"))

        let scan = SongFolderImporter.scan(folderURL: songDir)
        #expect(scan.inferredTitle == "Holy Forever")
        #expect(scan.audioURLs.map(\.lastPathComponent) == ["Bass.m4a", "Drums.wav", "Keys.mp3"])
        #expect(scan.artworkURL?.lastPathComponent == "cover.png")
        #expect(scan.artworkData != nil)
        if let artData = scan.artworkData {
            #expect(NSImage(data: artData) != nil)
        }

        // 2. Folder with only a non-cover-named image still defaults to it
        let photoOnlyDir = rootDir.appendingPathComponent("Praise", isDirectory: true)
        try fm.createDirectory(at: photoOnlyDir, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: photoOnlyDir.appendingPathComponent("Click.wav"))
        try secondaryPNG.write(to: photoOnlyDir.appendingPathComponent("photo.png"))

        let photoScan = SongFolderImporter.scan(folderURL: photoOnlyDir)
        #expect(photoScan.inferredTitle == "Praise")
        #expect(photoScan.audioURLs.map(\.lastPathComponent) == ["Click.wav"])
        #expect(photoScan.artworkURL?.lastPathComponent == "photo.png")
        #expect(photoScan.artworkData != nil)

        // 3. Generic folder names fall back to parent title, and findDefaultArtwork ignores Downloads
        let parentSongDir = rootDir.appendingPathComponent("Goodness of God", isDirectory: true)
        let genericStemsDir = parentSongDir.appendingPathComponent("Stems", isDirectory: true)
        try fm.createDirectory(at: genericStemsDir, withIntermediateDirectories: true)
        #expect(SongFolderImporter.inferSongTitle(from: genericStemsDir) == "Goodness of God")

        let downloadsDir = rootDir.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try validPNG.write(to: downloadsDir.appendingPathComponent("cover.png"))
        #expect(SongFolderImporter.findDefaultArtwork(in: downloadsDir) == nil)
    }

    @Test
    func songFolderImporterParsesTitleKeyAndTempoFromFolderNames() throws {
        let gratitude = SongFolderImporter.parseMetadata(fromFolderName: "Gratitude-House of Miracles-B-78.00bpm")
        #expect(gratitude.title == "Gratitude")
        #expect(gratitude.musicalKey == "B")
        #expect(gratitude.bpm == 78.0)

        let holyForever = SongFolderImporter.parseMetadata(fromFolderName: "Holy Forever - Chris Tomlin - Bb - 72 BPM")
        #expect(holyForever.title == "Holy Forever")
        #expect(holyForever.musicalKey == "Bb")
        #expect(holyForever.bpm == 72.0)

        let goodness = SongFolderImporter.parseMetadata(fromFolderName: "Goodness of God - Eb - 63bpm")
        #expect(goodness.title == "Goodness of God")
        #expect(goodness.musicalKey == "Eb")
        #expect(goodness.bpm == 63.0)

        let wayMaker = SongFolderImporter.parseMetadata(fromFolderName: "Way Maker - C#m - 68")
        #expect(wayMaker.title == "Way Maker")
        #expect(wayMaker.musicalKey == "C#m")
        #expect(wayMaker.bpm == 68.0)

        let amazingGrace = SongFolderImporter.parseMetadata(fromFolderName: "This Is Amazing Grace_F#_98.5bpm")
        #expect(amazingGrace.title == "This Is Amazing Grace")
        #expect(amazingGrace.musicalKey == "F#")
        #expect(amazingGrace.bpm == 98.5)

        let oceans = SongFolderImporter.parseMetadata(fromFolderName: "Oceans | D# | 66 BPM")
        #expect(oceans.title == "Oceans")
        #expect(oceans.musicalKey == "Eb")
        #expect(oceans.bpm == 66.0)

        let graves = SongFolderImporter.parseMetadata(fromFolderName: "Graves Into Gardens (Live) - Elevation Worship - B - 70.00 BPM - 6-8")
        #expect(graves.title == "Graves Into Gardens (Live)")
        #expect(graves.musicalKey == "B")
        #expect(graves.bpm == 70.0)

        let tenThousand = SongFolderImporter.parseMetadata(fromFolderName: "10,000 Reasons")
        #expect(tenThousand.title == "10,000 Reasons")
        #expect(tenThousand.musicalKey == nil)
        #expect(tenThousand.bpm == nil)

        let thousand = SongFolderImporter.parseMetadata(fromFolderName: "A Thousand Hallelujahs")
        #expect(thousand.title == "A Thousand Hallelujahs")
        #expect(thousand.musicalKey == nil)
        #expect(thousand.bpm == nil)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_gratitude_scan_\(UUID().uuidString)", isDirectory: true)
        let gratitudeDir = tempDir.appendingPathComponent("Gratitude-House of Miracles-B-78.00bpm", isDirectory: true)
        try fm.createDirectory(at: gratitudeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        try Data([0x00, 0x01]).write(to: gratitudeDir.appendingPathComponent("Drums.wav"))

        let scan = SongFolderImporter.scan(folderURL: gratitudeDir)
        #expect(scan.inferredTitle == "Gratitude")
        #expect(scan.inferredKey == "B")
        #expect(scan.inferredBPM == 78.0)
    }

    @Test
    func offlineBounceExportsValidMP3NativelyWithEmbeddedLame() throws {
        let fm = FileManager.default
        let mp3URL = fm.temporaryDirectory.appendingPathComponent("pb_native_lame_\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: mp3URL) }

        let sampleRate = 48_000.0
        let count = Int(sampleRate * 1.0)
        let phaseStep = 2.0 * Float.pi * 440.0 / Float(sampleRate)
        let left = (0..<count).map { Float(0.25) * sin(phaseStep * Float($0)) }
        let right = (0..<count).map { Float(0.25) * cos(phaseStep * Float($0)) }

        try OfflineBounceEngine.encodeStereoFloatToMP3(
            left: left,
            right: right,
            sampleRate: sampleRate,
            to: mp3URL
        )

        let attrs = try fm.attributesOfItem(atPath: mp3URL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(fileSize > 4_000)

        let decodedFile = try AVAudioFile(forReading: mp3URL)
        #expect(decodedFile.processingFormat.channelCount == 2)
        let decodedFrames = AVAudioFrameCount(decodedFile.length)
        let dur = Double(decodedFrames) / decodedFile.processingFormat.sampleRate
        #expect(dur >= 0.8 && dur <= 1.5)

        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decodedFile.processingFormat, frameCapacity: decodedFrames))
        try decodedFile.read(into: buf)
        let ch0 = try #require(buf.floatChannelData?[0])
        var sumSq: Double = 0
        for i in 0..<Int(buf.frameLength) {
            let s = Double(ch0[i])
            sumSq += s * s
        }
        let rms = sqrt(sumSq / Double(max(1, Int(buf.frameLength))))
        #expect(rms >= 0.05)
    }

    @Test
    func masteringResamplerPreservesDurationLevelAndTimingAcrossSampleRates() throws {
        let ratePairs: [(from: Double, to: Double)] = [
            (44_100, 48_000),
            (48_000, 44_100),
            (44_100, 88_200),
            (48_000, 96_000),
            (48_000, 192_000),
            (96_000, 48_000),
            (96_000, 44_100),
            (192_000, 48_000)
        ]

        for pair in ratePairs {
            let srcCount = Int(round(0.5 * pair.from))
            let onsetIdx = Int(round(0.100 * pair.from))
            let endIdx = Int(round(0.400 * pair.from))
            let phaseStep = 2.0 * Float.pi * 1000.0 / Float(pair.from)

            var left = [Float](repeating: 0, count: srcCount)
            var right = [Float](repeating: 0, count: srcCount)
            for i in onsetIdx..<endIdx {
                let s = Float(0.4) * sin(phaseStep * Float(i - onsetIdx))
                left[i] = s
                right[i] = -s
            }

            let res = try #require(
                MasteringAudioResampler.resampleStereoFloat(
                    left: left,
                    right: right,
                    fromRate: pair.from,
                    toRate: pair.to
                )
            )
            #expect(res.left.count == res.right.count)

            let outDur = Double(res.left.count) / pair.to
            #expect(abs(outDur - 0.5) <= 0.025)

            let midStart = Int(round(0.15 * pair.to))
            let midEnd = min(res.left.count, Int(round(0.35 * pair.to)))
            var sumSq: Double = 0
            for i in midStart..<midEnd {
                let v = Double(res.left[i])
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Double(max(1, midEnd - midStart)))
            #expect(rms >= 0.24 && rms <= 0.33)

            if let firstHit = res.left.firstIndex(where: { abs($0) > 0.05 }) {
                let onsetSec = Double(firstHit) / pair.to
                #expect(abs(onsetSec - 0.100) <= 0.003)
            } else {
                Issue.record("No onset detected for \(pair.from) -> \(pair.to)")
            }
        }
    }

    @Test
    func offlineBounceMP3ExportHandles96kHzAnd176kHzSources() throws {
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 44_100) == 44_100)
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 48_000) == 48_000)
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 88_200) == 44_100)
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 176_400) == 44_100)
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 96_000) == 48_000)
        #expect(MasteringAudioResampler.targetMP3SampleRate(for: 192_000) == 48_000)

        let fm = FileManager.default
        let mp3URL = fm.temporaryDirectory.appendingPathComponent("pb_96k_lame_\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: mp3URL) }

        let sampleRate = 96_000.0
        let count = Int(sampleRate * 1.0)
        let phaseStep = 2.0 * Float.pi * 440.0 / Float(sampleRate)
        let left = (0..<count).map { Float(0.25) * sin(phaseStep * Float($0)) }
        let right = (0..<count).map { Float(0.25) * cos(phaseStep * Float($0)) }

        try OfflineBounceEngine.encodeStereoFloatToMP3(
            left: left,
            right: right,
            sampleRate: sampleRate,
            to: mp3URL
        )

        let decodedFile = try AVAudioFile(forReading: mp3URL)
        #expect(decodedFile.processingFormat.sampleRate == 48_000.0)
        #expect(decodedFile.processingFormat.channelCount == 2)
        let decodedFrames = AVAudioFrameCount(decodedFile.length)
        let dur = Double(decodedFrames) / decodedFile.processingFormat.sampleRate
        #expect(dur >= 0.90 && dur <= 1.15)

        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decodedFile.processingFormat, frameCapacity: decodedFrames))
        try decodedFile.read(into: buf)
        let ch0 = try #require(buf.floatChannelData?[0])
        var sumSq: Double = 0
        for i in 0..<Int(buf.frameLength) {
            let s = Double(ch0[i])
            sumSq += s * s
        }
        let rms = sqrt(sumSq / Double(max(1, Int(buf.frameLength))))
        #expect(rms >= 0.05)
    }
}
