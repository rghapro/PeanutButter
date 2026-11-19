import Testing
import Foundation
import AVFoundation
import Accelerate
import CRubberBand
@testable import PeanutButter

@Suite("Pass 1 and Pass 2 Audit Tests")
struct Pass1AndPass2AuditTests {

    // MARK: - Pass 1 Regressions

    @Test
    func smpteLTCParitySyncWordsAndClockEdges() {
        let rates: [SMPTEFrameRate] = [.fps24, .fps25, .fps2997, .fps30, .fps30df]
        for rate in rates {
            var sawPolarityOne = false
            var sawPolarityZero = false
            let parityIdx = (rate == .fps25) ? 59 : 27
            for step in 0...1500 {
                let t = Double(step) * 0.1
                let tc = SMPTELTCGenerator.timecode(forSeconds: t, frameRate: rate)
                let word = SMPTELTCGenerator.encodeLTCFrameBits(
                    hours: tc.hours,
                    minutes: tc.minutes,
                    seconds: tc.seconds,
                    frames: tc.frames,
                    isDropFrame: rate.isDropFrame,
                    frameRate: rate
                )
                let ones = word.low.nonzeroBitCount + word.high.nonzeroBitCount
                #expect((ones & 1) == 0, "Odd bit parity for \(rate.rawValue) at t=\(t)")
                #expect(word.high == 0xBFFC, "Sync word mismatch for \(rate.rawValue)")
                if word.bit(at: parityIdx) == 1 {
                    sawPolarityOne = true
                } else {
                    sawPolarityZero = true
                }
            }
            #expect(sawPolarityOne && sawPolarityZero, "Polarity bit \(parityIdx) stayed constant for \(rate.rawValue)")
        }

        for sr in [48000.0, 44100.0] {
            for rate in rates {
                let framesToRender = 10
                let samplesPerFrame = sr / rate.framesPerSecond
                let totalSamples = Int(ceil(Double(framesToRender) * samplesPerFrame))
                var buf = [Float](repeating: 0.0, count: totalSamples)
                buf.withUnsafeMutableBufferPointer { ptr in
                    SMPTELTCGenerator.renderLTC(
                        frameCount: totalSamples,
                        outBuffer: ptr.baseAddress!,
                        startTimelineFrame: 0,
                        cueTimelineFrame: 0,
                        cueStartSeconds: 3661.0,
                        sampleRate: sr,
                        frameRate: rate,
                        amplitude: 0.5
                    )
                }
                let samplesPerBit = samplesPerFrame / 80.0
                for fIdx in 0..<(framesToRender - 1) {
                    var decodedHigh: UInt16 = 0
                    for b in 0..<80 {
                        let bStart = Int(round((Double(fIdx) * samplesPerFrame + Double(b) * samplesPerBit) + samplesPerBit * 0.25))
                        let bEnd = Int(round((Double(fIdx) * samplesPerFrame + Double(b) * samplesPerBit) + samplesPerBit * 0.75))
                        let prevSampleIdx = max(0, Int(round((Double(fIdx) * samplesPerFrame + Double(b) * samplesPerBit) - samplesPerBit * 0.2)))
                        if fIdx > 0 || b > 0 {
                            #expect(buf[prevSampleIdx] * buf[bStart] < 0.0)
                        }
                        if b >= 64 && (buf[bStart] * buf[bEnd]) < 0.0 {
                            decodedHigh |= (UInt16(1) << UInt16(b - 64))
                        }
                    }
                    #expect(decodedHigh == 0xBFFC)
                }
            }
        }
    }

    @Test
    func cRubberBandExceptionAndNaNGuards() throws {
        #expect(!rubberband_r3_process_exact(nil, 100, nil, 100, 2, 48000.0, 0.0, 0.0, false))

        var dummySamples = [Float](repeating: 0.0, count: 512)
        var dummyOut = [Float](repeating: 0.0, count: 512)
        let invalidNaNOk: Bool = dummySamples.withUnsafeMutableBufferPointer { inPtr in
            dummyOut.withUnsafeMutableBufferPointer { outPtr in
                let inArr: [UnsafePointer<Float>?] = [UnsafePointer(inPtr.baseAddress!)]
                var outArr: [UnsafeMutablePointer<Float>?] = [outPtr.baseAddress!]
                return inArr.withUnsafeBufferPointer { ip in
                    outArr.withUnsafeMutableBufferPointer { op in
                        rubberband_r3_process_exact(ip.baseAddress, 512, op.baseAddress, 512, 1, 48000.0, Double.nan, 0.0, false)
                    }
                }
            }
        }
        #expect(!invalidNaNOk)

        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096))
        buf.frameLength = 4096
        for i in 0..<4096 {
            let v = sinf(Float(i) * 0.05) * 0.4
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        let shifted = try AudioPitchRenderer.renderPitchShiftedBuffer(sourceBuffer: buf, semitones: 2)
        #expect(shifted.frameLength == 4096)
    }

    @Test
    func realTimeMixEnginePassThroughSoftClipNaNScrubAndBufferRetirement() throws {
        let mixState = RealTimeMixEngineState()
        let frameCount = 512
        let trackId = UUID()
        var audioL = [Float](repeating: 0.5, count: frameCount)
        var audioR = [Float](repeating: 0.5, count: frameCount)

        func runMix(gain: Float, enableRedundancy: Bool = false, enableSMPTE: Bool = false) -> (channels: [[Float]], peaks: [UUID: (Float, Float)]) {
            let chCount = 4
            var b0 = [Float](repeating: 0.0, count: frameCount)
            var b1 = [Float](repeating: 0.0, count: frameCount)
            var b2 = [Float](repeating: 0.0, count: frameCount)
            var b3 = [Float](repeating: 0.0, count: frameCount)
            let ablSize = MemoryLayout<AudioBufferList>.size + (chCount - 1) * MemoryLayout<AudioBuffer>.size
            let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawABL.deallocate() }
            let abl = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)
            abl.pointee.mNumberBuffers = UInt32(chCount)

            audioL.withUnsafeMutableBufferPointer { srcL in
                audioR.withUnsafeMutableBufferPointer { srcR in
                    let entry = RenderTrackEntry(
                        trackId: trackId,
                        leftPtr: srcL.baseAddress!,
                        rightPtr: srcR.baseAddress!,
                        frameLength: Int64(frameCount),
                        gainL: gain,
                        gainR: gain,
                        isClickOrGuide: false,
                        isTimelineAligned: true,
                        outChannelL: 0,
                        outChannelR: 1
                    )
                    mixState.configure(
                        sampleRate: 48000.0,
                        totalDuration: 1.0,
                        slices: [RenderTimelineSlice(timelineStartFrame: 0, timelineEndFrame: 48000, sourceStartFrame: 0)],
                        tracks: [entry],
                        retainedBuffers: [],
                        loopActive: false,
                        loopIsSingle: false,
                        loopStart: 0.0,
                        loopEnd: 0.0,
                        masterGain: 1.0
                    )
                    mixState.setRedundancy(enabled: enableRedundancy, channelIndex: 2)
                    mixState.setSMPTE(enabled: enableSMPTE, channelIndex: 3, frameRate: .fps30, hasCue: true, cueTimelineFrame: 0, cueStartSeconds: 0.0)
                    mixState.setPlayhead(seconds: 0.0, resumePlaying: true)

                    b0.withUnsafeMutableBufferPointer { p0 in
                        b1.withUnsafeMutableBufferPointer { p1 in
                            b2.withUnsafeMutableBufferPointer { p2 in
                                b3.withUnsafeMutableBufferPointer { p3 in
                                    let ptrs = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!, p3.baseAddress!]
                                    let mBuffers = UnsafeMutableAudioBufferListPointer(abl)
                                    for c in 0..<chCount {
                                        mBuffers[c].mNumberChannels = 1
                                        mBuffers[c].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                                        mBuffers[c].mData = UnsafeMutableRawPointer(ptrs[c])
                                    }
                                    var isSil = ObjCBool(false)
                                    mixState.render(isSilence: &isSil, frameCount: frameCount, audioBufferList: abl)
                                }
                            }
                        }
                    }
                }
            }
            return ([b0, b1, b2, b3], mixState.consumeTrackPeaks())
        }

        let resLow = runMix(gain: 1.0, enableRedundancy: true, enableSMPTE: true)
        #expect(abs(resLow.channels[0][0] - 0.5) < 1e-6)
        #expect(abs((resLow.peaks[trackId]?.0 ?? 0) - 0.5) < 1e-5)
        #expect(mixState.consumeTrackPeaks().isEmpty)

        let resHot = runMix(gain: 8.0, enableRedundancy: true, enableSMPTE: true)
        #expect(resHot.channels[0][10] > 0.89125)
        #expect(resHot.channels[0][10] <= 1.0)
        #expect(abs((resHot.channels[2].map { abs($0) }.max() ?? 0) - 0.25) < 0.01)
        #expect(abs((resHot.channels[3].map { abs($0) }.max() ?? 0) - 0.50) < 0.01)

        audioL[5] = Float.nan
        audioL[6] = Float.infinity
        audioL[7] = -Float.infinity
        let resNaN = runMix(gain: 1.0)
        let allFinite = resNaN.channels[0].allSatisfy(\.isFinite)
        #expect(allFinite)
        #expect(resNaN.channels[0][5] == 0.0)
        #expect(resNaN.channels[0][6] == 0.0)
        #expect(resNaN.channels[0][7] == 0.0)
        #expect(abs(resNaN.channels[0][0] - 0.5) < 1e-6)

        let testFmt = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2))
        weak var weakHeld: AVAudioPCMBuffer?
        autoreleasepool {
            let held = AVAudioPCMBuffer(pcmFormat: testFmt, frameCapacity: 512)!
            held.frameLength = 512
            weakHeld = held
            mixState.configure(
                sampleRate: 48000.0,
                totalDuration: 1.0,
                slices: [],
                tracks: [],
                retainedBuffers: [held],
                loopActive: false,
                loopIsSingle: false,
                loopStart: 0.0,
                loopEnd: 0.0,
                masterGain: 1.0
            )
        }
        #expect(weakHeld != nil)
        mixState.configure(sampleRate: 48000.0, totalDuration: 1.0, slices: [], tracks: [], retainedBuffers: [], loopActive: false, loopIsSingle: false, loopStart: 0.0, loopEnd: 0.0, masterGain: 1.0)
        _ = mixState.consumeTrackPeaks()
        #expect(weakHeld == nil)
    }

    @Test
    @MainActor
    func padPlayerEngineOffMainThreadSafety() throws {
        let testFmt = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2))
        let padEngine = PadPlayerEngine()
        padEngine.setProcessingFormat(testFmt)
        padEngine.fadeOutSeconds = 0.05
        padEngine.start(key: "C", packId: "simple")
        #expect(padEngine.isPlaying)
        padEngine.stop()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var outL = [Float](repeating: 0.0, count: 512)
            var outR = [Float](repeating: 0.0, count: 512)
            outL.withUnsafeMutableBufferPointer { pL in
                outR.withUnsafeMutableBufferPointer { pR in
                    let chans = [pL.baseAddress!, pR.baseAddress!]
                    chans.withUnsafeBufferPointer { bufPtr in
                        for _ in 0..<25 {
                            padEngine.renderDirect(frameCount: 512, channelPointers: bufPtr)
                        }
                    }
                }
            }
            done.signal()
        }
        done.wait()
        #expect(!padEngine.hasActiveAudioToRender)
        #expect(padEngine.isPlaying, "@Published isPlaying must not mutate from RT background thread")
        padEngine.syncUIStateAndDrainRetiredBuffers()
        #expect(!padEngine.isPlaying)
    }

    // MARK: - Pass 2: AutomationPoint Serialization & Dual-Format Reader (4.3)

    @Test
    func automationPointObjectEncodingAndDualFormatDecoding() throws {
        let trackA = UUID()
        let trackB = UUID()
        let point = AutomationPoint(
            time: 42.5,
            name: "Chorus Lift",
            transitionBeats: 2,
            descriptionText: "Boost keys",
            trackFaders: [trackA: 0.75, trackB: 0.40],
            trackPans: [trackA: -0.25],
            trackMutes: [trackB: true],
            busFaders: ["Keys": 0.90],
            busMutes: ["BGVs": false],
            padActive: true,
            padKey: "G"
        )

        let encoded = try JSONEncoder().encode(point)
        let rawObj = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let fadersObj = try #require(rawObj["trackFaders"] as? [String: Any], "trackFaders must encode as JSON object instead of flat array")
        #expect(fadersObj.count == 2)

        let decodedNew = try JSONDecoder().decode(AutomationPoint.self, from: encoded)
        #expect(abs((decodedNew.trackFaders[trackA] ?? -1) - 0.75) < 1e-6)
        #expect(abs((decodedNew.trackPans[trackA] ?? 99) - (-0.25)) < 1e-6)
        #expect(decodedNew.trackMutes[trackB] == true)
        #expect(decodedNew.padKey == "G")

        // Decode legacy Foundation alternating-array format from v1.0.5
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "time": 12.0,
          "name": "Legacy Point",
          "trackFaders": ["\(trackA.uuidString)", 0.65, "\(trackB.uuidString)", 0.25],
          "trackPans": ["\(trackA.uuidString)", 0.5],
          "trackMutes": ["\(trackB.uuidString)", false]
        }
        """
        let decodedLegacy = try JSONDecoder().decode(AutomationPoint.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.name == "Legacy Point")
        #expect(decodedLegacy.transitionBeats == 0)
        #expect(abs((decodedLegacy.trackFaders[trackA] ?? -1) - 0.65) < 1e-6)
        #expect(abs((decodedLegacy.trackFaders[trackB] ?? -1) - 0.25) < 1e-6)
        #expect(abs((decodedLegacy.trackPans[trackA] ?? -1) - 0.5) < 1e-6)
        #expect(decodedLegacy.trackMutes[trackB] == false)
    }

    // MARK: - Pass 2: Archive Security & Canonical Path Containment (1.5)

    private struct SyntheticZipEntry {
        let name: String
        let payload: Data
        let externalAttrs: UInt32
        let versionMadeBy: UInt16
        let uncompressedSizeOverride: UInt32?
    }

    private func buildSyntheticZip(entries: [SyntheticZipEntry]) -> Data {
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

        for entry in entries {
            let localOffset = UInt32(fileData.count)
            let nameData = Data(entry.name.utf8)
            let uncompSize = entry.uncompressedSizeOverride ?? UInt32(entry.payload.count)

            appendU32(&fileData, 0x04034b50)
            appendU16(&fileData, 20)
            appendU16(&fileData, 0)
            appendU16(&fileData, 0)
            appendU16(&fileData, 0)
            appendU16(&fileData, 0)
            appendU32(&fileData, 0)
            appendU32(&fileData, UInt32(entry.payload.count))
            appendU32(&fileData, uncompSize)
            appendU16(&fileData, UInt16(nameData.count))
            appendU16(&fileData, 0)
            fileData.append(nameData)
            fileData.append(entry.payload)

            appendU32(&cd, 0x02014b50)
            appendU16(&cd, entry.versionMadeBy)
            appendU16(&cd, 20)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU32(&cd, 0)
            appendU32(&cd, UInt32(entry.payload.count))
            appendU32(&cd, uncompSize)
            appendU16(&cd, UInt16(nameData.count))
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU32(&cd, entry.externalAttrs)
            appendU32(&cd, localOffset)
            cd.append(nameData)
        }

        let cdOffset = UInt32(fileData.count)
        fileData.append(cd)

        appendU32(&fileData, 0x06054b50)
        appendU16(&fileData, 0)
        appendU16(&fileData, 0)
        appendU16(&fileData, UInt16(entries.count))
        appendU16(&fileData, UInt16(entries.count))
        appendU32(&fileData, UInt32(cd.count))
        appendU32(&fileData, cdOffset)
        appendU16(&fileData, 0)
        return fileData
    }

    @Test
    func archiveSecurityRejectsZipSlipSymlinksAndBombCapWhileAllowingColons() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_zipsec_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // (a) ../escape.txt Zip Slip entry
        let slipZip = tempRoot.appendingPathComponent("slip.zip")
        try buildSyntheticZip(entries: [
            SyntheticZipEntry(name: "../escape.txt", payload: Data("bad".utf8), externalAttrs: 0o100644 << 16, versionMadeBy: (3 << 8) | 20, uncompressedSizeOverride: nil)
        ]).write(to: slipZip)
        #expect(throws: ArchiveSecurityError.unsafeEntryPath("../escape.txt")) {
            try PlaybackFileManager.validateZipArchive(at: slipZip)
        }

        // (b) POSIX symlink entry
        let symlinkZip = tempRoot.appendingPathComponent("symlink.zip")
        try buildSyntheticZip(entries: [
            SyntheticZipEntry(name: "stems/link.m4a", payload: Data("/etc/passwd".utf8), externalAttrs: 0o120777 << 16, versionMadeBy: (3 << 8) | 20, uncompressedSizeOverride: nil)
        ]).write(to: symlinkZip)
        #expect(throws: ArchiveSecurityError.symlinkEntry("stems/link.m4a")) {
            try PlaybackFileManager.validateZipArchive(at: symlinkZip)
        }

        // (c) Uncompressed size cap exceedance
        let bombZip = tempRoot.appendingPathComponent("bomb.zip")
        try buildSyntheticZip(entries: [
            SyntheticZipEntry(name: "song.json", payload: Data(), externalAttrs: 0o100644 << 16, versionMadeBy: (3 << 8) | 20, uncompressedSizeOverride: 2_000_000)
        ]).write(to: bombZip)
        #expect(throws: ArchiveSecurityError.uncompressedSizeExceeded(2_000_000)) {
            try PlaybackFileManager.validateZipArchive(at: bombZip, maxUncompressedBytes: 1_000_000)
        }

        // Windows C:\ drive prefix still rejected
        let driveZip = tempRoot.appendingPathComponent("drive.zip")
        try buildSyntheticZip(entries: [
            SyntheticZipEntry(name: "C:evil.txt", payload: Data(), externalAttrs: 0o100644 << 16, versionMadeBy: (3 << 8) | 20, uncompressedSizeOverride: nil)
        ]).write(to: driveZip)
        #expect(throws: (any Error).self) {
            try PlaybackFileManager.validateZipArchive(at: driveZip)
        }

        // (d) Real archive with colon in filename extracts cleanly
        let srcDir = tempRoot.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("{\"ok\":true}".utf8).write(to: srcDir.appendingPathComponent("track:1.txt"))
        let validZip = tempRoot.appendingPathComponent("valid.zip")
        let zipProc = Process()
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.currentDirectoryURL = srcDir
        zipProc.arguments = ["-0", "-r", "-q", validZip.path, "."]
        try zipProc.run()
        zipProc.waitUntilExit()
        #expect(zipProc.terminationStatus == 0)

        let outDir = tempRoot.appendingPathComponent("out", isDirectory: true)
        try PlaybackFileManager.shared.unzipArchive(archiveURL: validZip, toFolderURL: outDir)
        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("track:1.txt").path))

        // Path containment checks
        let baseDir = tempRoot.appendingPathComponent("pkg", isDirectory: true)
        let stemsDir = baseDir.appendingPathComponent("stems", isDirectory: true)
        try fm.createDirectory(at: stemsDir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: stemsDir.appendingPathComponent("track.m4a"))

        #expect(PlaybackFileManager.containedFileURL(baseDirectory: baseDir, relativePath: "../secret") == nil)
        #expect(PlaybackFileManager.containedFileURL(baseDirectory: baseDir, relativePath: "/etc/passwd") == nil)
        #expect(PlaybackFileManager.containedFileURL(baseDirectory: baseDir, relativePath: "a/../../b") == nil)
        #expect(PlaybackFileManager.containedFileURL(baseDirectory: baseDir, relativePath: "stems/track.m4a") != nil)

        let symlinkOut = tempRoot.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: symlinkOut)
        let escapingLink = stemsDir.appendingPathComponent("escape.m4a")
        try fm.createSymbolicLink(at: escapingLink, withDestinationURL: symlinkOut)
        #expect(PlaybackFileManager.containedFileURL(baseDirectory: baseDir, relativePath: "stems/escape.m4a") == nil)
    }

    // MARK: - Pass 2: Coordinated Atomic Cloud Writes (4.1)

    @Test
    func coordinatedAtomicCloudWritesLeaveNoPbTmpFiles() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("pb_atomic_\(UUID().uuidString)", isDirectory: true)
        let cloudSimDir = tempRoot.appendingPathComponent("CloudRoot/Stems", isDirectory: true)
        try fm.createDirectory(at: cloudSimDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let srcFile = tempRoot.appendingPathComponent("source.m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: srcFile)

        let destFile = cloudSimDir.appendingPathComponent("copied.m4a")
        try PlaybackFileManager.shared.linkOrCopyFile(from: srcFile, to: destFile)
        #expect(fm.fileExists(atPath: destFile.path))

        let contentsAfterCopy = try fm.contentsOfDirectory(at: cloudSimDir, includingPropertiesForKeys: nil)
        #expect(!contentsAfterCopy.contains(where: { $0.lastPathComponent.hasPrefix(".pb_tmp_") }))

        // Build valid cloud stem pack + tracks.json sidecar with zero `.pb_tmp_*` files
        let songId = UUID()
        let trackId = UUID()
        let looseSongDir = cloudSimDir.appendingPathComponent(songId.uuidString, isDirectory: true)
        try fm.createDirectory(at: looseSongDir, withIntermediateDirectories: true)
        let looseStem = looseSongDir.appendingPathComponent("\(trackId.uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: looseStem)

        let tm = TrackFileMetadata(
            id: trackId,
            name: "Drums",
            role: .stem,
            relativeAudioPath: "cloudstems/\(songId.uuidString)/\(trackId.uuidString).m4a"
        )
        PlaybackFileManager.shared.writeCloudStemPack(cloudStemsDir: cloudSimDir, songId: songId, tracks: [tm])

        let packURL = PlaybackFileManager.shared.resolveCloudStemPackURL(cloudStemsDir: cloudSimDir, songId: songId)
        let sidecarURL = PlaybackFileManager.shared.resolveCloudStemPackManifestURL(cloudStemsDir: cloudSimDir, songId: songId)
        #expect(fm.fileExists(atPath: packURL.path))
        #expect(fm.fileExists(atPath: sidecarURL.path))

        let allItems = try fm.contentsOfDirectory(at: cloudSimDir, includingPropertiesForKeys: nil)
        #expect(!allItems.contains(where: { $0.lastPathComponent.hasPrefix(".pb_tmp_") }))
    }

    // MARK: - Pass 2: Remote Control Hardening (1.3, 1.4, 1.6)

    @Test
    @MainActor
    func remoteControlOriginValidationPasswordHashMigrationRateLimitAndNoInnerHTML() throws {
        #expect(RemoteControlServer.isAllowedWebSocketOrigin("http://192.168.1.10:8085", hostHeader: "192.168.1.10:8085", serverPort: 8085))
        #expect(!RemoteControlServer.isAllowedWebSocketOrigin("https://evil.com", hostHeader: "192.168.1.10:8085", serverPort: 8085))
        #expect(!RemoteControlServer.isAllowedWebSocketOrigin("http://127.0.0.1:3000", hostHeader: "127.0.0.1:8085", serverPort: 8085))
        #expect(!RemoteControlServer.isAllowedWebSocketOrigin("null", hostHeader: "192.168.1.10:8085", serverPort: 8085))
        #expect(!RemoteControlServer.isAllowedWebSocketOrigin(nil, hostHeader: "192.168.1.10:8085", serverPort: 8085))

        let suiteName = "com.peanutbutter.tests.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("stage123", forKey: "Playback_RemotePassword")
        let server = RemoteControlServer(engine: nil, userDefaults: defaults)
        #expect(!server.isPasswordRequired)
        #expect(defaults.string(forKey: "Playback_RemotePassword") == nil, "Legacy plaintext password must be deleted on init")
        #expect(server.hasConfiguredPassword)
        #expect(server.verifyPassword("stage123"))
        #expect(!server.verifyPassword("wrongpw"))

        let now = Date()
        for attempt in 1...4 {
            server.recordAuthResult(success: false, forIP: "192.168.1.99", now: now)
            #expect(!server.isIPRateLimited("192.168.1.99", now: now), "Lockout fired too early at attempt \(attempt)")
        }
        server.recordAuthResult(success: false, forIP: "192.168.1.99", now: now)
        #expect(server.isIPRateLimited("192.168.1.99", now: now.addingTimeInterval(5)))
        #expect(!server.isIPRateLimited("192.168.1.99", now: now.addingTimeInterval(35)))

        let html = RemoteControlServer.buildRemoteWebClientHTML(cspNonce: "testNonce123")
        #expect(html.contains("<script nonce=\"testNonce123\">"))
        #expect(!html.contains(".innerHTML"))

        let inlineEventRegex = try NSRegularExpression(
            pattern: "\\son(click|input|change|keydown|pointerdown|pointerup|pointercancel|dblclick)\\s*=",
            options: [.caseInsensitive]
        )
        let range = NSRange(location: 0, length: (html as NSString).length)
        #expect(inlineEventRegex.firstMatch(in: html, options: [], range: range) == nil, "HTML must not contain inline on*= event handlers")
    }

    // MARK: - Pass 2: Lightweight Undo & Filename Sanitization (4.2, 4.4)

    @Test
    @MainActor
    func lightweightUndoReleasesBuffersUnderCriticalMemoryPressureAndFilenameSanitization() {
        #expect(LibraryBrowserManager.sanitizedPackageFilename("Sunday: 9/11 Set", ext: "pbsession") == "Sunday- 9-11 Set.pbsession")
        #expect(!LibraryBrowserManager.sanitizedPackageFilename("A/B:C", ext: "pbsong").contains("/"))
        #expect(!LibraryBrowserManager.sanitizedPackageFilename("A/B:C", ext: "pbsong").contains(":"))

        let engine = MultitrackAudioEngine()
        let canonicalFormat = engine.getCanonicalProcessingFormat()
        let trackId = UUID()
        weak var weakBuffer: AVAudioPCMBuffer?

        autoreleasepool {
            let track = StemTrack(id: trackId, name: "Synth", role: .stem)
            let buf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: 4096)!
            buf.frameLength = 4096
            weakBuffer = buf
            engine.addTrack(track, with: buf, recalculateWaveform: false)
            engine.removeTrack(id: trackId)
        }

        #expect(weakBuffer != nil, "Undo orphan cache keeps recently removed track temporarily available")
        engine.handleMemoryPressure(critical: true)
        #expect(weakBuffer == nil, "Critical memory pressure must release removed track buffer even with undo history present")
    }
}
