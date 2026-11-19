import Testing
import Foundation
import AVFoundation
import Accelerate
import Darwin
import zlib
@testable import PeanutButter

@Suite("Pass 5 Audit Tests")
struct Pass5AuditTests {

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

    private struct ZipRawEntrySpec {
        let name: String
        let payload: Data
        let method: UInt16
        let spoofedUncompressedSize: UInt32?
        let omitFromCentralDirectory: Bool
        let trailingGapBytes: Data

        init(
            name: String,
            payload: Data,
            method: UInt16 = 0,
            spoofedUncompressedSize: UInt32? = nil,
            omitFromCentralDirectory: Bool = false,
            trailingGapBytes: Data = Data()
        ) {
            self.name = name
            self.payload = payload
            self.method = method
            self.spoofedUncompressedSize = spoofedUncompressedSize
            self.omitFromCentralDirectory = omitFromCentralDirectory
            self.trailingGapBytes = trailingGapBytes
        }
    }

    private func buildCustomZipArchive(entries: [ZipRawEntrySpec]) -> Data {
        var fileData = Data()
        var cd = Data()
        var cdEntryCount: UInt16 = 0

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

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let localOffset = UInt32(fileData.count)
            let compSize = UInt32(entry.payload.count)
            let uncompSize = entry.spoofedUncompressedSize ?? compSize

            // Local file header (0x04034b50)
            appendU32(&fileData, 0x04034b50)
            appendU16(&fileData, 20)
            appendU16(&fileData, 0)
            appendU16(&fileData, entry.method)
            appendU16(&fileData, 0)
            appendU16(&fileData, 0)
            appendU32(&fileData, 0)
            appendU32(&fileData, compSize)
            appendU32(&fileData, uncompSize)
            appendU16(&fileData, UInt16(nameData.count))
            appendU16(&fileData, 0)
            fileData.append(nameData)
            fileData.append(entry.payload)
            fileData.append(entry.trailingGapBytes)

            if !entry.omitFromCentralDirectory {
                appendU32(&cd, 0x02014b50)
                appendU16(&cd, (3 << 8) | 20)
                appendU16(&cd, 20)
                appendU16(&cd, 0)
                appendU16(&cd, entry.method)
                appendU16(&cd, 0)
                appendU16(&cd, 0)
                appendU32(&cd, 0)
                appendU32(&cd, compSize)
                appendU32(&cd, uncompSize)
                appendU16(&cd, UInt16(nameData.count))
                appendU16(&cd, 0)
                appendU16(&cd, 0)
                appendU16(&cd, 0)
                appendU16(&cd, 0)
                appendU32(&cd, 0o100644 << 16)
                appendU32(&cd, localOffset)
                cd.append(nameData)
                cdEntryCount &+= 1
            }
        }

        let cdOffset = UInt32(fileData.count)
        fileData.append(cd)

        // EOCD (0x06054b50)
        appendU32(&fileData, 0x06054b50)
        appendU16(&fileData, 0)
        appendU16(&fileData, 0)
        appendU16(&fileData, cdEntryCount)
        appendU16(&fileData, cdEntryCount)
        appendU32(&fileData, UInt32(cd.count))
        appendU32(&fileData, cdOffset)
        appendU16(&fileData, 0)
        return fileData
    }

    private func runProcess(_ launchPath: String, arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func sendRawLoopbackHTTPRequest(port: UInt16, request: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                throw NSError(domain: "Pass5AuditTests", code: Int(errno))
            }
            defer { Darwin.close(sock) }

            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let connectStatus = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectStatus == 0 else {
                throw NSError(domain: "Pass5AuditTests", code: Int(errno))
            }

            let reqBytes = Array(request.utf8)
            var sent = 0
            while sent < reqBytes.count {
                let n = reqBytes.withUnsafeBytes { raw in
                    Darwin.send(sock, raw.baseAddress!.advanced(by: sent), reqBytes.count - sent, 0)
                }
                guard n > 0 else {
                    throw NSError(domain: "Pass5AuditTests", code: Int(errno))
                }
                sent += n
            }

            var response = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    response.append(contentsOf: buf[0..<n])
                    if let text = String(data: response, encoding: .utf8),
                       text.contains("\r\n\r\n"),
                       response.count >= 16 {
                        if let headerEnd = text.range(of: "\r\n\r\n") {
                            let headerPart = text[..<headerEnd.lowerBound]
                            if let clLine = headerPart
                                .components(separatedBy: "\r\n")
                                .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                               let clVal = Int(clLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""),
                               let bodyStartOffset = text.utf8.distance(from: text.startIndex, to: headerEnd.upperBound) as Int?,
                               response.count >= bodyStartOffset + clVal {
                                break
                            }
                        }
                    }
                } else {
                    break
                }
            }
            return String(decoding: response, as: UTF8.self)
        }.value
    }

    // MARK: - P3-01: SMPTE LTC Lifecycle Refresh & Sample-Accurate Handover

    @Test
    @MainActor
    func smpteLTCLifecycleRefreshAndSampleAccurateHandover() throws {
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

        let cue1 = SMPTECue(time: 0.0, timeStartHours: 1, timeStartMinutes: 0, timeStartSeconds: 0, timeStartFrames: 0)
        let cue2 = SMPTECue(time: 0.0, timeStartHours: 2, timeStartMinutes: 0, timeStartSeconds: 0, timeStartFrames: 0)

        let song1 = Song(
            title: "Song One",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 0.25)],
            smpteCue: cue1,
            transitionType: .autoLink
        )
        let song2 = Song(
            title: "Song Two",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "D",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 0.25)],
            smpteCue: cue2,
            transitionType: .cueNextSong
        )

        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let bufFrames = AVAudioFrameCount(max(1200, Int(round(0.25 * sr))))
        let buf = try makeTestPCMBuffer(frequency: 330.0, frameCount: bufFrames, sampleRate: sr)
        let t1 = StemTrack(name: "Keys", role: .stem)
        let t2 = StemTrack(name: "Keys", role: .stem)

        engine.currentSetlist = Setlist(name: "SMPTE Set", songs: [song1, song2])
        engine.songBuffersCache[song1.id] = [(t1, buf)]
        engine.songBuffersCache[song2.id] = [(t2, buf)]
        engine.loadSong(song1)

        // 1. Active Song 1 + Staged Song 2 both reflected in RealTimeMixEngineState
        let snap1 = engine.mixState.currentSMPTESnapshot()
        #expect(snap1.enabled)
        #expect(snap1.hasCue && abs(snap1.cueStartSeconds - 3600.0) < 1e-6)
        #expect(snap1.nextHasCue && abs(snap1.nextCueStartSeconds - 7200.0) < 1e-6)

        // 2. Switching to Song 2 refreshes active SMPTE state immediately
        engine.selectSongInSetlist(at: 1)
        let snap2 = engine.mixState.currentSMPTESnapshot()
        #expect(snap2.hasCue && abs(snap2.cueStartSeconds - 7200.0) < 1e-6)
        #expect(!snap2.nextHasCue)

        // 3. Tempo scaling updates timeline frame in mixState for non-zero cue time
        engine.selectSongInSetlist(at: 0)
        engine.moveSMPTECue(to: 0.1, snapToGrid: false)
        let beforeTempoSnap = engine.mixState.currentSMPTESnapshot()
        #expect(beforeTempoSnap.cueTimelineFrame == Int64(round(0.1 * sr)))

        engine.setKeyAndTempo(tempoBPM: 100.0, forSongIndex: 0)
        let afterTempoSnap = engine.mixState.currentSMPTESnapshot()
        #expect(abs((engine.currentSong.smpteCue?.time ?? 0.0) - 0.12) < 1e-4)
        #expect(afterTempoSnap.cueTimelineFrame == Int64(round(0.12 * sr)))

        // 4. Undo snapshot restoration refreshes SMPTE state (Song 1 -> Song 2 -> undo back to Song 1)
        engine.selectSongInSetlist(at: 0)
        engine.updateSMPTECue(hours: 1, minutes: 0, seconds: 0, frames: 0)
        engine.moveSMPTECue(to: 0.0, snapToGrid: false)
        let undoBaseline = engine.captureCurrentUndoSnapshot()

        engine.selectSongInSetlist(at: 1)
        #expect(abs(engine.mixState.currentSMPTESnapshot().cueStartSeconds - 7200.0) < 1e-6)
        engine.applyUndoSnapshot(undoBaseline)
        #expect(abs(engine.mixState.currentSMPTESnapshot().cueStartSeconds - 3600.0) < 1e-6)

        // 5. Sample-accurate mid-buffer Song 1 -> Song 2 promotion inside RealTimeMixEngineState.render
        engine.currentSetlist.songs[0].transitionType = .autoLink
        engine.currentSong = engine.currentSetlist.songs[0]
        engine.syncMixState()
        let endTime = engine.currentSong.sections[0].endTime
        let preBoundarySec = max(0.0, endTime - (100.0 / sr))
        engine.mixState.setPlayhead(seconds: preBoundarySec, resumePlaying: true)

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

        let postPromotionSnap = engine.mixState.currentSMPTESnapshot()
        #expect(postPromotionSnap.hasCue && abs(postPromotionSnap.cueStartSeconds - 7200.0) < 1e-6)
        // Out 4 (index 3) must contain non-zero LTC signal in both pre-handover and post-handover halves
        #expect(c3[0..<100].contains(where: { abs($0) > 0.1 }))
        #expect(c3[150..<frameCount].contains(where: { abs($0) > 0.1 }))

        // 6. newSession resets SMPTE state cleanly
        engine.newSession()
        #expect(!engine.mixState.currentSMPTESnapshot().hasCue)
    }

    // MARK: - P3-02: Updater Contiguous Layout, Streaming Deflate & Real ditto Compatibility

    @Test
    func validateZipContiguousLayoutStreamingDeflateAndDittoCompatibility() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p5_zip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Real /usr/bin/ditto -c -k --sequesterRsrc --keepParent archive (uses bit 3 + 0x08074b50 descriptors)
        let bundleDir = tempRoot.appendingPathComponent("SampleBundle", isDirectory: true)
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let innerPayload = Data((0..<4096).map { UInt8(($0 * 13) & 0xFF) })
        try innerPayload.write(to: bundleDir.appendingPathComponent("Info.bin"))
        let dittoZip = tempRoot.appendingPathComponent("ditto_release.zip")
        let dittoStatus = try runProcess(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", bundleDir.path, dittoZip.path]
        )
        #expect(dittoStatus == 0)

        try PlaybackFileManager.validateZipArchive(
            at: dittoZip,
            maxUncompressedBytes: 50_000_000,
            maxEntries: 1_000,
            verifyContiguousLayoutAndStreams: true
        )

        // 2. Reject unindexed prepended Local File Header at byte 0 (CD only indexes entry 2)
        let prependedUnindexedZip = tempRoot.appendingPathComponent("unindexed_prepend.zip")
        try buildCustomZipArchive(entries: [
            ZipRawEntrySpec(name: "../evil.txt", payload: Data("hidden".utf8), omitFromCentralDirectory: true),
            ZipRawEntrySpec(name: "good.txt", payload: Data("ok".utf8))
        ]).write(to: prependedUnindexedZip)

        #expect(throws: (any Error).self) {
            try PlaybackFileManager.validateZipArchive(
                at: prependedUnindexedZip,
                verifyContiguousLayoutAndStreams: true
            )
        }

        // 3. Reject non-contiguous gap before cdOffset
        let gapZip = tempRoot.appendingPathComponent("gap_before_cd.zip")
        try buildCustomZipArchive(entries: [
            ZipRawEntrySpec(name: "good.txt", payload: Data("ok".utf8), trailingGapBytes: Data(repeating: 0xAA, count: 16))
        ]).write(to: gapZip)

        #expect(throws: (any Error).self) {
            try PlaybackFileManager.validateZipArchive(
                at: gapZip,
                verifyContiguousLayoutAndStreams: true
            )
        }

        // 4. Reject spoofed-header Deflate bomb during updater pre-ditto verification
        let rawBomb = Data(repeating: 0x42, count: 200_000)
        let compressedBomb = rawDeflate(rawBomb)
        let spoofedBombZip = tempRoot.appendingPathComponent("spoofed_updater_bomb.zip")
        try buildCustomZipArchive(entries: [
            ZipRawEntrySpec(
                name: "PeanutButter.app/Contents/MacOS/blob",
                payload: compressedBomb,
                method: 8,
                spoofedUncompressedSize: 64
            )
        ]).write(to: spoofedBombZip)

        #expect(throws: (any Error).self) {
            try PlaybackFileManager.validateZipArchive(
                at: spoofedBombZip,
                maxUncompressedBytes: 50_000,
                maxEntries: 1_000,
                verifyContiguousLayoutAndStreams: true
            )
        }
    }

    // MARK: - P3-03: Duplicated Song In-Place .pbsession Save Preserves Stems After Original Deletion

    @Test
    func duplicatedSongHardlinksSurviveOriginalSongDeletionOnInPlaceSave() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p5_dup_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        defer {
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempRoot)
        }

        let sharedBuf = try makeTestPCMBuffer(frequency: 523.25)
        let stubFormat = sharedBuf.format
        let unhydratedStub = try #require(AVAudioPCMBuffer(pcmFormat: stubFormat, frameCapacity: 1))
        unhydratedStub.frameLength = 1

        let songA = Song(title: "Original Song", artist: "Band", bpm: 120.0, musicalKey: "C")
        let trackA = StemTrack(name: "Drums", role: .stem)
        trackA.duration = 0.1

        let songB = Song(title: "Duplicate Song", artist: "Band", bpm: 120.0, musicalKey: "C")
        let trackB = StemTrack(name: "Drums", role: .stem)
        trackB.duration = 0.1

        createdTrackIds.append(contentsOf: [trackA.id, trackB.id])

        let sessionURL = tempRoot.appendingPathComponent("DupSession.pbsession", isDirectory: true)
        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "Dup Test", songs: [songA, songB]),
            currentSongIndex: 0,
            allSongsData: [
                (song: songA, tracks: [trackA], buffers: [trackA.id: sharedBuf]),
                (song: songB, tracks: [trackB], buffers: [trackB.id: sharedBuf])
            ],
            to: sessionURL,
            asDirectoryPackage: true
        )

        let stemsA = sessionURL.appendingPathComponent("songs/\(songA.id.uuidString)/stems", isDirectory: true)
        let stemsB = sessionURL.appendingPathComponent("songs/\(songB.id.uuidString)/stems", isDirectory: true)
        let filesB = try fm.contentsOfDirectory(at: stemsB, includingPropertiesForKeys: nil)
        #expect((try fm.contentsOfDirectory(at: stemsA, includingPropertiesForKeys: nil)).count == 1)
        #expect(filesB.count == 1, "Duplicated Song B must own its own hardlinked stem inside its UUID song folder")

        // Simulate second launch / evicted cache + unhydrated placeholder on Song B, then delete Song A and re-save in place
        try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: trackA.id))
        try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: trackB.id))

        let reloadedTrackB = StemTrack(id: trackB.id, name: "Drums", role: .stem, fileURL: nil)
        reloadedTrackB.duration = 0.1

        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "Dup Test", songs: [songB]),
            currentSongIndex: 0,
            allSongsData: [
                (song: songB, tracks: [reloadedTrackB], buffers: [reloadedTrackB.id: unhydratedStub])
            ],
            to: sessionURL,
            asDirectoryPackage: true
        )

        #expect(!fm.fileExists(atPath: sessionURL.appendingPathComponent("songs/\(songA.id.uuidString)").path))
        let stemBFile = try #require(filesB.first)
        #expect(fm.fileExists(atPath: stemBFile.path), "Song B stem must remain intact after removing Song A")

        let finalLoaded = try PlaybackFileManager.shared.loadSession(from: sessionURL)
        #expect(finalLoaded.songsData.count == 1)
        #expect(finalLoaded.songsData[0].tracks.first?.1.frameLength ?? 0 > 100)
    }

    // MARK: - P3-04: Fail-Closed HTTP Host Validation & Off-MainActor Async Auth

    @Test
    @MainActor
    func remoteControlHTTPRejectsMissingOrMalformedHostAndVerifiesAsync() async throws {
        let suiteName = "com.peanutbutter.tests.p5.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pb_p5_pads_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let padLib = PadLibraryManager(customPadsDirectoryOverride: tempRoot)
        let engine = MultitrackAudioEngine()
        let server = RemoteControlServer(engine: engine, userDefaults: defaults, padLibrary: padLib)
        server.attach(to: engine)
        server.setPassword("bandpass")
        server.isPasswordRequired = true
        server.start(preferredPort: 0)
        defer { server.stop() }

        for _ in 0..<100 {
            if server.isRunning && server.port > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.isRunning && server.port > 0)

        let asyncOk = await server.verifyPasswordAsync("bandpass")
        let asyncBad = await server.verifyPasswordAsync("nope")
        #expect(asyncOk)
        #expect(!asyncBad)

        // 1. Missing Host header (HTTP/1.0) -> 403 Forbidden
        let respMissingHost = try await sendRawLoopbackHTTPRequest(
            port: server.port,
            request: "GET /api/state HTTP/1.0\r\nConnection: close\r\n\r\n"
        )
        #expect(respMissingHost.hasPrefix("HTTP/1.1 403 Forbidden"))

        // 2. Unparseable port in Host header -> 403 Forbidden
        let respMalformedPort = try await sendRawLoopbackHTTPRequest(
            port: server.port,
            request: "GET / HTTP/1.1\r\nHost: evil.example:abc\r\nConnection: close\r\n\r\n"
        )
        #expect(respMalformedPort.hasPrefix("HTTP/1.1 403 Forbidden"))

        // 3. Disallowed DNS hostname -> 403 Forbidden
        let respEvilHost = try await sendRawLoopbackHTTPRequest(
            port: server.port,
            request: "GET / HTTP/1.1\r\nHost: attacker.example\r\nConnection: close\r\n\r\n"
        )
        #expect(respEvilHost.hasPrefix("HTTP/1.1 403 Forbidden"))

        // 4. Allowed loopback host + wrong password -> 401 Unauthorized
        let respBadAuth = try await sendRawLoopbackHTTPRequest(
            port: server.port,
            request: "GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nX-Remote-Password: wrong\r\nConnection: close\r\n\r\n"
        )
        #expect(respBadAuth.hasPrefix("HTTP/1.1 401 Unauthorized"))

        // 5. Allowed loopback host + valid password -> 200 OK
        let respGoodAuth = try await sendRawLoopbackHTTPRequest(
            port: server.port,
            request: "GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nX-Remote-Password: bandpass\r\nConnection: close\r\n\r\n"
        )
        #expect(respGoodAuth.hasPrefix("HTTP/1.1 200 OK"))
    }

    // MARK: - P3-05: PadPlayerEngine Non-Finite Sample Scrubbing on Out 3-4 & Lock-Free Retirement

    @Test
    func padPlayerScrubsNaNAndInfOnAuxOutputs3And4() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        let frameCount = 256
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ch0 = try #require(buf.floatChannelData?[0])
        let ch1 = try #require(buf.floatChannelData?[1])
        for i in 0..<frameCount {
            ch0[i] = 0.25
            ch1[i] = 0.25
        }
        ch0[4] = .nan
        ch0[5] = .infinity
        ch1[6] = -.infinity
        ch1[7] = .nan

        let padPlayer = PadPlayerEngine()
        padPlayer.setProcessingFormat(format)
        padPlayer.setTargetOutputChannels(left: 2, right: 3) // Out 3/4
        padPlayer.setVolume(1.0)
        padPlayer.setBusGain(1.0)
        padPlayer.loadBufferForTesting(buf, key: "C", immediateGain: 1.0)

        let mixState = RealTimeMixEngineState()
        mixState.setPadEngine(padPlayer)

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
                        let mBuffers = UnsafeMutableAudioBufferListPointer(abl)
                        let ptrs = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!, p3.baseAddress!]
                        for idx in 0..<chCount {
                            mBuffers[idx].mNumberChannels = 1
                            mBuffers[idx].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                            mBuffers[idx].mData = UnsafeMutableRawPointer(ptrs[idx])
                        }
                        var isSil = ObjCBool(false)
                        mixState.render(isSilence: &isSil, frameCount: frameCount, audioBufferList: abl)
                    }
                }
            }
        }

        let c0Finite = c0.allSatisfy(\.isFinite)
        let c1Finite = c1.allSatisfy(\.isFinite)
        let c2Finite = c2.allSatisfy(\.isFinite)
        let c3Finite = c3.allSatisfy(\.isFinite)
        #expect(c0Finite && c1Finite && c2Finite && c3Finite)
        #expect(c2.contains(where: { abs($0) > 0.01 }) && c3.contains(where: { abs($0) > 0.01 }))

        let padPeaks = padPlayer.consumeMeterPeaks()
        #expect(padPeaks.0.isFinite && padPeaks.1.isFinite && padPeaks.0 > 0.0)
    }

    // MARK: - P3-06: newSession Cancels All In-Flight Background Tasks

    @Test
    @MainActor
    func newSessionCancelsInFlightBackgroundTasks() {
        let savedLastSession = UserDefaults.standard.object(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                UserDefaults.standard.set(v, forKey: "Playback_LastSessionPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "Playback_LastSessionPath")
            }
        }
        let engine = MultitrackAudioEngine()
        let song = Song(title: "Pending", artist: "Artist", bpm: 120.0, musicalKey: "C")
        engine.currentSetlist = Setlist(name: "Old", songs: [song])

        let hydrationTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let preGenTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let transposeTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        engine.sessionHydrationTask = hydrationTask
        engine.preGenerateSetlistTask = preGenTask
        engine.transposeTasksBySong[song.id] = transposeTask
        engine.transposeTaskTokensBySong[song.id] = UUID()
        engine.transposeProgressBySong[song.id] = 0.5
        engine.downloadingSongProgress[song.id] = 0.25
        engine.isTransposing = true
        engine.transposingSongId = song.id
        let genBefore = engine.sessionHydrationGeneration

        engine.newSession()

        #expect(engine.sessionHydrationGeneration != genBefore)
        #expect(hydrationTask.isCancelled)
        #expect(preGenTask.isCancelled)
        #expect(transposeTask.isCancelled)
        #expect(engine.transposeTasksBySong.isEmpty)
        #expect(engine.transposeProgressBySong.isEmpty)
        #expect(engine.downloadingSongProgress.isEmpty)
        #expect(!engine.isTransposing)
    }

    // MARK: - P3-07: Punctuation-Colliding Custom Sample Slugs Disambiguate Without Breaking Normal Slugs

    @Test
    @MainActor
    func collidingCustomSampleFolderSlugsDisambiguateWithoutBreakingBackwardsCompat() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_p5_slugs_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let mgr = CustomSampleLibraryManager(isolatedRootDirectory: tempRoot)

        // Single non-colliding folder retains exact legacy slug "warm-wood"
        let warmWood = mgr.localClickSamplesDirectory.appendingPathComponent("Warm Wood", isDirectory: true)
        // Colliding punctuation folders both sanitize cleanly only with disambiguation suffix
        let studioPlus = mgr.localClickSamplesDirectory.appendingPathComponent("Studio + Live", isDirectory: true)
        let studioAmp = mgr.localClickSamplesDirectory.appendingPathComponent("Studio & Live", isDirectory: true)

        for folder in [warmWood, studioPlus, studioAmp] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeTestWAVFile(to: folder.appendingPathComponent("accent.wav"), frameCount: 600)
            try writeTestWAVFile(to: folder.appendingPathComponent("quarter.wav"), frameCount: 600)
        }

        mgr.refreshPacks()

        let warmPack = try #require(mgr.clickPack(forId: "warm-wood"))
        #expect(warmPack.name == "Warm Wood")

        let plusPack = try #require(mgr.customClickPacks.first(where: { $0.name == "Studio + Live" }))
        let ampPack = try #require(mgr.customClickPacks.first(where: { $0.name == "Studio & Live" }))
        #expect(plusPack.id.hasPrefix("studio-live-"))
        #expect(ampPack.id.hasPrefix("studio-live-"))
        #expect(plusPack.id != ampPack.id)
        #expect(mgr.clickPack(forId: plusPack.id)?.folderPath == plusPack.folderPath)
        #expect(mgr.clickPack(forId: ampPack.id)?.folderPath == ampPack.folderPath)
    }
}
