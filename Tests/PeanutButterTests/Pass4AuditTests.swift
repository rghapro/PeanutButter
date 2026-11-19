import Testing
import Foundation
import AVFoundation
import Accelerate
import zlib
@testable import PeanutButter

@Suite("Pass 4 Audit Tests")
struct Pass4AuditTests {

    private func makeTestPCMBuffer(frequency: Float = 440.0, frameCount: AVAudioFrameCount = 4_800, sampleRate: Double = 48_000.0) throws -> AVAudioPCMBuffer {
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

    private func buildDifferentialZip(
        cdName: String,
        localName: String,
        payload: Data,
        method: UInt16 = 0,
        spoofedUncompressedSize: UInt32? = nil
    ) -> Data {
        var fileData = Data()
        var cd = Data()

        func appendU16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendU32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }

        let lhNameData = Data(localName.utf8)
        let cdNameData = Data(cdName.utf8)
        let uncompSize = spoofedUncompressedSize ?? UInt32(payload.count)
        let localOffset: UInt32 = 0

        // Local file header (0x04034b50)
        appendU32(&fileData, 0x04034b50)
        appendU16(&fileData, 20)
        appendU16(&fileData, 0)
        appendU16(&fileData, method)
        appendU16(&fileData, 0)
        appendU16(&fileData, 0)
        appendU32(&fileData, 0)
        appendU32(&fileData, UInt32(payload.count))
        appendU32(&fileData, uncompSize)
        appendU16(&fileData, UInt16(lhNameData.count))
        appendU16(&fileData, 0)
        fileData.append(lhNameData)
        fileData.append(payload)

        // Central directory header (0x02014b50)
        appendU32(&cd, 0x02014b50)
        appendU16(&cd, (3 << 8) | 20)
        appendU16(&cd, 20)
        appendU16(&cd, 0)
        appendU16(&cd, method)
        appendU16(&cd, 0)
        appendU16(&cd, 0)
        appendU32(&cd, 0)
        appendU32(&cd, UInt32(payload.count))
        appendU32(&cd, uncompSize)
        appendU16(&cd, UInt16(cdNameData.count))
        appendU16(&cd, 0)
        appendU16(&cd, 0)
        appendU16(&cd, 0)
        appendU16(&cd, 0)
        appendU32(&cd, 0o100644 << 16)
        appendU32(&cd, localOffset)
        cd.append(cdNameData)

        let cdOffset = UInt32(fileData.count)
        fileData.append(cd)

        // EOCD (0x06054b50)
        appendU32(&fileData, 0x06054b50)
        appendU16(&fileData, 0)
        appendU16(&fileData, 0)
        appendU16(&fileData, 1)
        appendU16(&fileData, 1)
        appendU32(&fileData, UInt32(cd.count))
        appendU32(&fileData, cdOffset)
        appendU16(&fileData, 0)
        return fileData
    }

    private func rawDeflate(_ input: Data) -> Data {
        var strm = z_stream()
        let rcInit = deflateInit2_(
            &strm,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        #expect(rcInit == Z_OK)
        defer { deflateEnd(&strm) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        input.withUnsafeBytes { rawIn in
            strm.next_in = UnsafeMutablePointer(mutating: rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self))
            strm.avail_in = uInt(input.count)
            while true {
                var produced = 0
                let status = buf.withUnsafeMutableBufferPointer { outPtr in
                    strm.next_out = outPtr.baseAddress
                    strm.avail_out = uInt(outPtr.count)
                    let rc = deflate(&strm, strm.avail_in == 0 ? Z_FINISH : Z_NO_FLUSH)
                    produced = outPtr.count - Int(strm.avail_out)
                    return rc
                }
                if produced > 0 {
                    out.append(contentsOf: buf[0..<produced])
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
            }
        }
        return out
    }

    // MARK: - P2-01: Sample Pack Containment Guards

    @Test
    func customSampleLibraryPathTraversalGuard() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p4_samples_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let mgr = CustomSampleLibraryManager(isolatedRootDirectory: tempRoot)
        let outsideFile = tempRoot.appendingPathComponent("outside.wav")
        try Data("important".utf8).write(to: outsideFile)

        let badClickPack = CustomClickPack(
            id: "evil-click",
            name: "Evil Click",
            folderPath: mgr.localClickSamplesDirectory.appendingPathComponent("evil-click").path,
            accentFile: "../outside.wav",
            quarterFile: "/etc/passwd",
            eighthFile: nil,
            sixteenthFile: nil,
            isCloud: false
        )
        #expect(badClickPack.resolvedURL(for: .accent) == nil)
        #expect(badClickPack.resolvedURL(for: .quarter) == nil)

        let badGuidePack = CustomGuidePack(
            id: "evil-guide",
            name: "Evil Guide",
            folderPath: mgr.localGuideSamplesDirectory.appendingPathComponent("evil-guide").path,
            phraseFiles: ["verse": "../outside.wav", "chorus": "/etc/passwd"],
            isCloud: false
        )
        #expect(badGuidePack.fileURL(forNormalizedPhrase: "verse") == nil)
        #expect(badGuidePack.fileURL(forNormalizedPhrase: "chorus") == nil)

        // Attempt deletion via tampered pack.json when clearing a subdivision/phrase
        let clickFolder = mgr.localClickSamplesDirectory.appendingPathComponent("tampered-click", isDirectory: true)
        try fm.createDirectory(at: clickFolder, withIntermediateDirectories: true)
        let clickManifest = """
        {"id":"tampered-click","name":"Tampered Click","accentFile":"../../outside.wav"}
        """
        try Data(clickManifest.utf8).write(to: clickFolder.appendingPathComponent("pack.json"))

        let guideFolder = mgr.localGuideSamplesDirectory.appendingPathComponent("tampered-guide", isDirectory: true)
        try fm.createDirectory(at: guideFolder, withIntermediateDirectories: true)
        let guideManifest = """
        {"id":"tampered-guide","name":"Tampered Guide","phraseFiles":{"verse":"../../outside.wav"}}
        """
        try Data(guideManifest.utf8).write(to: guideFolder.appendingPathComponent("pack.json"))

        mgr.refreshPacks()
        _ = mgr.setClickSubdivisionFile(packId: "tampered-click", subdivision: .accent, sourceURL: nil)
        _ = mgr.setGuidePhraseFile(packId: "tampered-guide", phrase: "Verse", sourceURL: nil)

        #expect(fm.fileExists(atPath: outsideFile.path), "Path traversal in pack.json must never delete outside files")
    }

    // MARK: - P2-02: Remote Control Hardening, Debounced PBKDF2 & Opaque Custom Pad IDs

    @Test
    @MainActor
    func remoteControlClearUnchecksFailClosedPBKDF2DebounceDNSRebindAndOpaquePadIds() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p4_remote_\(UUID().uuidString)", isDirectory: true)
        let padsRoot = tempRoot.appendingPathComponent("Pads", isDirectory: true)
        let warmPadDir = padsRoot.appendingPathComponent("WarmPad", isDirectory: true)
        try fm.createDirectory(at: warmPadDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let suiteName = "com.peanutbutter.tests.p4.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let padLib = PadLibraryManager(customPadsDirectoryOverride: padsRoot)
        let engine = MultitrackAudioEngine()
        let server = RemoteControlServer(engine: engine, userDefaults: defaults, padLibrary: padLib)
        server.attach(to: engine)

        // 1. Default remains false per user preference
        #expect(!server.isPasswordRequired)

        // 2. Typing keystrokes must not rehash on every character; commits cleanly on submit/blur/timer
        server.remotePassword = "s"
        server.remotePassword = "st"
        server.remotePassword = "sta"
        server.remotePassword = "stage99"
        #expect(server.pbkdf2DerivationCountForTesting == 0)

        server.commitPendingPassword()
        #expect(server.pbkdf2DerivationCountForTesting == 1)
        #expect(server.hasConfiguredPassword)
        #expect(defaults.string(forKey: "Playback_RemotePasswordKDF") == "pbkdf2-sha256-100000")
        #expect(server.verifyPassword("stage99"))
        #expect(!server.verifyPassword("wrong"))

        // 3. Clear unchecks Require Password & removes stored hash; empty Require Password fails closed
        server.isPasswordRequired = true
        server.clearPassword()
        #expect(!server.hasConfiguredPassword)
        #expect(!server.isPasswordRequired)

        server.isPasswordRequired = true
        #expect(!server.verifyPassword(""))
        #expect(!server.verifyPassword("stage99"))

        // 4. DNS rebinding host/origin guard
        #expect(!RemoteControlServer.isAllowedWebSocketOrigin("http://evil-rebind.com:8085", hostHeader: "evil-rebind.com:8085", serverPort: 8085))
        #expect(RemoteControlServer.isAllowedWebSocketOrigin("http://localhost:8085", hostHeader: "localhost:8085", serverPort: 8085))
        #expect(RemoteControlServer.isAllowedWebSocketOrigin("http://192.168.1.10:8085", hostHeader: "192.168.1.10:8085", serverPort: 8085))

        // 5. Opaque custom pad IDs + no filesystem path leak in remote state snapshot
        let warmPack = try #require(padLib.availablePacks.first(where: { $0.name == "WarmPad" }))
        #expect(warmPack.id.hasPrefix("custom-"))
        #expect(padLib.resolvePack(for: warmPadDir.path)?.id == warmPack.id)
        engine.manualPadPackId = warmPadDir.path

        let snapshot = try #require(server.buildStateSnapshot())
        let snapshotData = try JSONEncoder().encode(snapshot)
        let snapshotJSON = try #require(String(data: snapshotData, encoding: .utf8))
        #expect(!snapshotJSON.contains("/Users/"))
        #expect(!snapshotJSON.contains(tempRoot.path))
        #expect(snapshot.pad.activePackId == warmPack.id)
    }

    // MARK: - P2-03 & P2-04: ZIP Differential, Stream Bomb Cap & GitHub HTTPS Pinning

    @Test
    func zipLocalHeaderDifferentialSpoofedStreamBombAndUpdaterHostAllowlist() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p4_zip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // (a) Central Directory vs Local File Header name differential
        let diffZip = tempRoot.appendingPathComponent("diff.zip")
        try buildDifferentialZip(
            cdName: "song.json",
            localName: "../escaped.txt",
            payload: Data("pwned".utf8)
        ).write(to: diffZip)

        #expect(throws: (any Error).self) {
            try PlaybackFileManager.validateZipArchive(at: diffZip)
        }
        let diffOut = tempRoot.appendingPathComponent("diff_out", isDirectory: true)
        #expect(throws: (any Error).self) {
            try PlaybackFileManager.shared.unzipArchive(archiveURL: diffZip, toFolderURL: diffOut)
        }
        #expect(!fm.fileExists(atPath: tempRoot.appendingPathComponent("escaped.txt").path))

        // (b) Deflate stream bomb spoofing uncompressedSize = 64 in headers while expanding to 200,000 bytes
        let rawBombPayload = Data(repeating: 0x41, count: 200_000)
        let compressedBomb = rawDeflate(rawBombPayload)
        #expect(compressedBomb.count < 2_000)

        let spoofedBombZip = tempRoot.appendingPathComponent("spoofed_bomb.zip")
        try buildDifferentialZip(
            cdName: "song.json",
            localName: "song.json",
            payload: compressedBomb,
            method: 8,
            spoofedUncompressedSize: 64
        ).write(to: spoofedBombZip)

        let bombOut = tempRoot.appendingPathComponent("bomb_out", isDirectory: true)
        #expect(throws: (any Error).self) {
            try PlaybackFileManager.shared.unzipArchive(
                archiveURL: spoofedBombZip,
                toFolderURL: bombOut,
                maxUncompressedBytes: 50_000
            )
        }
        #expect(!fm.fileExists(atPath: bombOut.path))

        // (c) AppUpdateManager URL allowlist
        #expect(AppUpdateManager.isAllowedGitHubUpdateURL(URL(string: "https://github.com/rghapro/PeanutButter/releases/download/v1.0.5/PeanutButter.zip")!))
        #expect(AppUpdateManager.isAllowedGitHubUpdateURL(URL(string: "https://objects.githubusercontent.com/asset.zip")!))
        #expect(!AppUpdateManager.isAllowedGitHubUpdateURL(URL(string: "http://github.com/rghapro/PeanutButter/releases/latest")!))
        #expect(!AppUpdateManager.isAllowedGitHubUpdateURL(URL(string: "https://evil.example/PeanutButter.zip")!))
    }

    // MARK: - P2-05: SMPTE Frame Offset & Exact NTSC 29.97 Timing

    @Test
    func smpteCueFrameOffsetAndExactNTSC2997Timing() {
        #expect(abs(SMPTEFrameRate.fps2997.framesPerSecond - (30000.0 / 1001.0)) < 1e-12)
        #expect(abs(SMPTEFrameRate.fps30df.framesPerSecond - (30000.0 / 1001.0)) < 1e-12)

        let cue = SMPTECue(
            time: 0.0,
            timeStartHours: 1,
            timeStartMinutes: 0,
            timeStartSeconds: 0,
            timeStartFrames: 15
        )
        #expect(cue.startFrameIndex(for: .fps30) == 108_015)
        #expect(abs(cue.totalStartSeconds(for: .fps30) - 3600.5) < 1e-9)

        for rate in [SMPTEFrameRate.fps30, .fps2997, .fps30df] {
            let startSec = cue.totalStartSeconds(for: rate)
            let tc = SMPTELTCGenerator.timecode(forSeconds: startSec, frameRate: rate)
            #expect(tc.hours == 1 && tc.minutes == 0 && tc.seconds == 0 && tc.frames == 15)
        }

        // Verify 30DF drops :00 and :01 at the 1-minute mark
        let fpsDF = SMPTEFrameRate.fps30df.framesPerSecond
        let f1799 = SMPTELTCGenerator.timecode(forSeconds: 1799.5 / fpsDF, frameRate: .fps30df)
        let f1800 = SMPTELTCGenerator.timecode(forSeconds: 1800.5 / fpsDF, frameRate: .fps30df)
        #expect(f1799 == (0, 0, 59, 29))
        #expect(f1800 == (0, 1, 0, 2))
    }

    // MARK: - P2-10 & P2-11: Cross-Song Transpose Cancellation & Local WAV Source Persistence

    @Test
    @MainActor
    func crossSongTranspositionCancellationIsolationAndLocalWAVSourcePersistence() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p4_trans_wav_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let sourcesJSON = tempRoot.appendingPathComponent("local_stem_sources.json")
        PlaybackFileManager.shared.localStemSourcesFileURLOverride = sourcesJSON
        PlaybackFileManager.shared.reloadLocalStemSourcesForTesting()

        var createdTrackIds: [UUID] = []
        defer {
            PlaybackFileManager.shared.localStemSourcesFileURLOverride = nil
            PlaybackFileManager.shared.reloadLocalStemSourcesForTesting()
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempRoot)
        }

        // 1. Per-song transpose cancellation isolation
        let engine = MultitrackAudioEngine()
        let songA = Song(title: "Song A", artist: "Artist", bpm: 120.0, musicalKey: "C")
        let songB = Song(title: "Song B", artist: "Artist", bpm: 120.0, musicalKey: "G")
        engine.currentSetlist = Setlist(name: "Test", songs: [songA, songB])
        engine.loadSong(songA)

        let activeTaskA: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        engine.transposeTasksBySong[songA.id] = activeTaskA
        engine.transposeProgressBySong[songA.id] = 0.4
        engine.isTransposing = true
        engine.transposingSongId = songA.id

        // Trigger Fast Path 1 on Song B -> must NOT cancel Song A
        engine.setKeyAndTempo(semitones: 0, forSongIndex: 1)
        #expect(!activeTaskA.isCancelled)
        #expect(engine.transposeProgressBySong[songA.id] == 0.4)
        #expect(engine.isTransposing)

        engine.cancelTransposeTask(for: songA.id)
        #expect(activeTaskA.isCancelled)
        #expect(engine.transposeProgressBySong[songA.id] == nil)
        #expect(!engine.isCurrentSongTransposing)

        // 2. Local lossless WAV source persistence across reload (with sourceFilePath omitted from session.json)
        let wavURL = tempRoot.appendingPathComponent("Drums.wav")
        let buf = try makeTestPCMBuffer()
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let wavFile = try AVAudioFile(forWriting: wavURL, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try wavFile.write(from: buf)

        let wavTrack = StemTrack(name: "Drums", role: .stem, fileURL: wavURL, sourceFileURL: wavURL)
        createdTrackIds.append(wavTrack.id)
        let wavSong = Song(title: "Lossless Song", artist: "Artist", bpm: 120.0, musicalKey: "C")
        let sessionURL = tempRoot.appendingPathComponent("Lossless.pbsession", isDirectory: true)
        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "Lossless Set", songs: [wavSong]),
            currentSongIndex: 0,
            allSongsData: [(song: wavSong, tracks: [wavTrack], buffers: [wavTrack.id: buf])],
            to: sessionURL,
            asDirectoryPackage: true
        )

        let sessionJSON = try String(contentsOf: sessionURL.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(!sessionJSON.contains("sourceFilePath"))
        #expect(!sessionJSON.contains(wavURL.path))

        let reloaded = try PlaybackFileManager.shared.loadSession(from: sessionURL)
        let loadedTrack = try #require(reloaded.songsData.first?.tracks.first?.0)
        let resolvedLossless = MultitrackAudioEngine.resolveLosslessSourceURL(for: loadedTrack)
        #expect(resolvedLossless?.standardizedFileURL == wavURL.standardizedFileURL)
    }

    // MARK: - P2-06 & P2-08: Offline Bounce & Master Meter Inf/NaN Resilience

    @Test
    func offlineBounceAndMasterMeterInfNaNResilience() {
        // 1. OfflineBounceEngine.softLimitStereo scrubs Inf/NaN without zeroing normal signal
        var left: [Float] = [0.35, .infinity, -.infinity, .nan, 1.5, -1.5]
        var right: [Float] = [0.35, .nan, .infinity, -.infinity, 0.95, -0.95]
        OfflineBounceEngine.softLimitStereo(left: &left, right: &right)

        let leftFinite = left.allSatisfy(\.isFinite)
        let rightFinite = right.allSatisfy(\.isFinite)
        #expect(leftFinite && rightFinite)
        #expect(left[1] == 0.0 && left[2] == 0.0 && left[3] == 0.0)
        #expect(abs(left[0] - 0.35) < 1e-6)
        #expect(left[4] > 0.89 && left[4] <= 1.0)
        #expect(left[5] < -0.89 && left[5] >= -1.0)

        // 2. RealTimeMixEngineState Master VU scrubs Inf and still excludes Click/Guide
        let mixState = RealTimeMixEngineState()
        let frameCount = 256
        var musicL = [Float](repeating: 0.4, count: frameCount)
        var musicR = [Float](repeating: 0.4, count: frameCount)
        musicL[10] = .infinity
        musicR[11] = -.infinity
        var clickL = [Float](repeating: 0.85, count: frameCount)
        var clickR = [Float](repeating: 0.85, count: frameCount)

        let chCount = 2
        var b0 = [Float](repeating: 0.0, count: frameCount)
        var b1 = [Float](repeating: 0.0, count: frameCount)
        let ablSize = MemoryLayout<AudioBufferList>.size + (chCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawABL.deallocate() }
        let abl = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)
        abl.pointee.mNumberBuffers = UInt32(chCount)

        musicL.withUnsafeMutableBufferPointer { mL in
            musicR.withUnsafeMutableBufferPointer { mR in
                clickL.withUnsafeMutableBufferPointer { cL in
                    clickR.withUnsafeMutableBufferPointer { cR in
                        let musicEntry = RenderTrackEntry(
                            trackId: UUID(),
                            leftPtr: mL.baseAddress!,
                            rightPtr: mR.baseAddress!,
                            frameLength: Int64(frameCount),
                            gainL: 1.0,
                            gainR: 1.0,
                            isClickOrGuide: false,
                            isTimelineAligned: true,
                            outChannelL: 0,
                            outChannelR: 1
                        )
                        let clickEntry = RenderTrackEntry(
                            trackId: UUID(),
                            leftPtr: cL.baseAddress!,
                            rightPtr: cR.baseAddress!,
                            frameLength: Int64(frameCount),
                            gainL: 1.0,
                            gainR: 1.0,
                            isClickOrGuide: true,
                            isTimelineAligned: true,
                            outChannelL: 0,
                            outChannelR: 1
                        )
                        mixState.configure(
                            sampleRate: 48_000.0,
                            totalDuration: 1.0,
                            slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: 48_000, sourceStartFrame: 0)],
                            tracks: [musicEntry, clickEntry],
                            retainedBuffers: [],
                            loopActive: false,
                            loopIsSingle: false,
                            loopStart: 0.0,
                            loopEnd: 0.0,
                            masterGain: 1.0
                        )
                        mixState.setPlayhead(seconds: 0.0, resumePlaying: true)

                        b0.withUnsafeMutableBufferPointer { p0 in
                            b1.withUnsafeMutableBufferPointer { p1 in
                                let mBuffers = UnsafeMutableAudioBufferListPointer(abl)
                                mBuffers[0].mNumberChannels = 1
                                mBuffers[0].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                                mBuffers[0].mData = UnsafeMutableRawPointer(p0.baseAddress!)
                                mBuffers[1].mNumberChannels = 1
                                mBuffers[1].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                                mBuffers[1].mData = UnsafeMutableRawPointer(p1.baseAddress!)
                                var isSil = ObjCBool(false)
                                mixState.render(isSilence: &isSil, frameCount: frameCount, audioBufferList: abl)
                            }
                        }
                    }
                }
            }
        }

        let masterPeaks = mixState.consumeMasterPeaks()
        #expect(masterPeaks.0.isFinite && masterPeaks.1.isFinite)
        #expect(abs(masterPeaks.0 - 0.4) < 1e-5)
        #expect(abs(masterPeaks.1 - 0.4) < 1e-5)
        let b0Finite = b0.allSatisfy(\.isFinite)
        let b1Finite = b1.allSatisfy(\.isFinite)
        #expect(b0Finite && b1Finite)
    }
}
