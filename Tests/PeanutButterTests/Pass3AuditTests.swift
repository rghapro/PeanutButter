import Testing
import Foundation
import AVFoundation
import AppKit
@testable import PeanutButter

@Suite("Pass 3 Audit Tests")
struct Pass3AuditTests {

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

    private func makeSolidPNGData(width: Int, height: Int, color: NSColor) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func makePeaks(seed: Int, count: Int = 4_000) -> [Float] {
        (0..<count).map { i in
            Float(((i + seed * 37) % 1000)) / 1000.0
        }
    }

    @Test
    func peaksSidecarCodecAndTinySessionJSON() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_pass3_peaks_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        defer {
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempDir)
        }

        let buf = try makeTestPCMBuffer()

        let song1 = Song(title: "Opening Song", artist: "Band A", bpm: 120.0, musicalKey: "G")
        let s1Track1 = StemTrack(name: "Drums", role: .stem)
        s1Track1.duration = 0.1
        s1Track1.waveformPeaks = makePeaks(seed: 1)
        let s1Track2 = StemTrack(name: "Bass", role: .stem)
        s1Track2.duration = 0.1
        s1Track2.waveformPeaks = makePeaks(seed: 2)

        let song2 = Song(title: "Closing Song", artist: "Band B", bpm: 92.0, musicalKey: "D")
        let s2Track1 = StemTrack(name: "Keys", role: .stem)
        s2Track1.duration = 0.1
        s2Track1.waveformPeaks = makePeaks(seed: 3)
        let s2Track2 = StemTrack(name: "Electric Guitar", role: .stem)
        s2Track2.duration = 0.1
        s2Track2.waveformPeaks = makePeaks(seed: 4)

        createdTrackIds.append(contentsOf: [s1Track1.id, s1Track2.id, s2Track1.id, s2Track2.id])

        let setlist = Setlist(name: "Pass 3 Test Set", songs: [song1, song2])
        let sessionURL = tempDir.appendingPathComponent("TestSet.pbsession", isDirectory: true)

        try PlaybackFileManager.shared.exportSession(
            setlist: setlist,
            currentSongIndex: 0,
            allSongsData: [
                (song: song1, tracks: [s1Track1, s1Track2], buffers: [s1Track1.id: buf, s1Track2.id: buf]),
                (song: song2, tracks: [s2Track1, s2Track2], buffers: [s2Track1.id: buf, s2Track2.id: buf])
            ],
            to: sessionURL,
            asDirectoryPackage: true
        )

        // 1. Verify binary "PBPK" peaks.bin exists in songs/<songUUID>/ and decodes exact floats
        let song1PeaksURL = sessionURL.appendingPathComponent("songs/\(song1.id.uuidString)/peaks.bin")
        let song2PeaksURL = sessionURL.appendingPathComponent("songs/\(song2.id.uuidString)/peaks.bin")
        #expect(fm.fileExists(atPath: song1PeaksURL.path))
        #expect(fm.fileExists(atPath: song2PeaksURL.path))

        let peaksData1 = try Data(contentsOf: song1PeaksURL)
        let peaksData2 = try Data(contentsOf: song2PeaksURL)
        #expect(String(decoding: peaksData1.prefix(4), as: UTF8.self) == "PBPK")
        #expect(String(decoding: peaksData2.prefix(4), as: UTF8.self) == "PBPK")

        let decoded1 = PlaybackFileManager.decodeSongPeaksSidecar(peaksData1)
        let decoded2 = PlaybackFileManager.decodeSongPeaksSidecar(peaksData2)
        #expect(decoded1[s1Track1.id] == s1Track1.waveformPeaks)
        #expect(decoded1[s1Track2.id] == s1Track2.waveformPeaks)
        #expect(decoded2[s2Track1.id] == s2Track1.waveformPeaks)
        #expect(decoded2[s2Track2.id] == s2Track2.waveformPeaks)

        // 2. Verify session.json no longer carries base64 waveformPeaksData blobs and stays compact
        let sessionJSONURL = sessionURL.appendingPathComponent("session.json")
        let sessionJSONData = try Data(contentsOf: sessionJSONURL)
        let sessionJSONString = try #require(String(data: sessionJSONData, encoding: .utf8))
        #expect(!sessionJSONString.contains("\"waveformPeaksData\""))
        #expect(sessionJSONData.count < 20_000)

        // 3. Verify both Stage-1 fast metadata load and full session load restore exact 4,000-float peaks
        let hydrated = try PlaybackFileManager.shared.loadSessionMetadataFast(from: sessionURL)
        defer {
            if let cleanup = hydrated.cleanupFolder {
                try? fm.removeItem(at: cleanup)
            }
        }
        #expect(hydrated.songsPlaceholderData.count == 2)
        let fastSong1Tracks = Dictionary(uniqueKeysWithValues: hydrated.songsPlaceholderData[0].tracks.map { ($0.0.id, $0.0) })
        let fastSong2Tracks = Dictionary(uniqueKeysWithValues: hydrated.songsPlaceholderData[1].tracks.map { ($0.0.id, $0.0) })
        #expect(fastSong1Tracks[s1Track1.id]?.waveformPeaks == s1Track1.waveformPeaks)
        #expect(fastSong1Tracks[s1Track2.id]?.waveformPeaks == s1Track2.waveformPeaks)
        #expect(fastSong2Tracks[s2Track1.id]?.waveformPeaks == s2Track1.waveformPeaks)
        #expect(fastSong2Tracks[s2Track2.id]?.waveformPeaks == s2Track2.waveformPeaks)

        let fullLoaded = try PlaybackFileManager.shared.loadSession(from: sessionURL)
        #expect(fullLoaded.songsData.count == 2)
        let fullSong1Tracks = Dictionary(uniqueKeysWithValues: fullLoaded.songsData[0].tracks.map { ($0.0.id, $0.0) })
        let fullSong2Tracks = Dictionary(uniqueKeysWithValues: fullLoaded.songsData[1].tracks.map { ($0.0.id, $0.0) })
        #expect(fullSong1Tracks[s1Track1.id]?.waveformPeaks == s1Track1.waveformPeaks)
        #expect(fullSong1Tracks[s1Track2.id]?.waveformPeaks == s1Track2.waveformPeaks)
        #expect(fullSong2Tracks[s2Track1.id]?.waveformPeaks == s2Track1.waveformPeaks)
        #expect(fullSong2Tracks[s2Track2.id]?.waveformPeaks == s2Track2.waveformPeaks)
    }

    @Test
    func uuidSongFoldersSurviveSetlistReorderAndLegacySessionFallbackWorks() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_pass3_dirs_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var createdTrackIds: [UUID] = []
        defer {
            for tid in createdTrackIds {
                try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: tid))
            }
            try? fm.removeItem(at: tempDir)
        }

        // Part A: UUID song folders survive reordering without breaking artwork resolution
        let buf = try makeTestPCMBuffer()
        let artAData = try makeSolidPNGData(width: 16, height: 16, color: .red)
        let artBData = try makeSolidPNGData(width: 32, height: 20, color: .blue)

        let songA = Song(title: "Song Alpha", artist: "Artist A", bpm: 118.0, musicalKey: "C", artworkData: artAData)
        let trackA = StemTrack(name: "Synth", role: .stem)
        trackA.duration = 0.1
        trackA.waveformPeaks = makePeaks(seed: 10)

        let songB = Song(title: "Song Beta", artist: "Artist B", bpm: 130.0, musicalKey: "E", artworkData: artBData)
        let trackB = StemTrack(name: "Pads", role: .stem)
        trackB.duration = 0.1
        trackB.waveformPeaks = makePeaks(seed: 11)

        createdTrackIds.append(contentsOf: [trackA.id, trackB.id])

        let reorderedURL = tempDir.appendingPathComponent("Reordered.pbsession", isDirectory: true)
        try PlaybackFileManager.shared.exportSession(
            setlist: Setlist(name: "Reorder Test", songs: [songA, songB]),
            currentSongIndex: 0,
            allSongsData: [
                (song: songA, tracks: [trackA], buffers: [trackA.id: buf]),
                (song: songB, tracks: [trackB], buffers: [trackB.id: buf])
            ],
            to: reorderedURL,
            asDirectoryPackage: true
        )

        #expect(fm.fileExists(atPath: reorderedURL.appendingPathComponent("songs/\(songA.id.uuidString)/artwork.png").path))
        #expect(fm.fileExists(atPath: reorderedURL.appendingPathComponent("songs/\(songB.id.uuidString)/artwork.png").path))
        #expect(!fm.fileExists(atPath: reorderedURL.appendingPathComponent("songs/song_0").path))

        // Swap song order in session.json ([A, B] -> [B, A]) without renaming folders on disk
        let sessionJSONURL = reorderedURL.appendingPathComponent("session.json")
        var sessionMeta = try JSONDecoder().decode(SessionPackageMetadata.self, from: try Data(contentsOf: sessionJSONURL))
        sessionMeta.songEntries.reverse()
        try JSONEncoder().encode(sessionMeta).write(to: sessionJSONURL, options: .atomic)

        let reorderItem = SetlistLibraryItem(
            id: reorderedURL,
            url: reorderedURL,
            name: "Reorder Test",
            songCount: 2,
            formattedDate: "",
            formattedDuration: "0:01",
            artworks: [],
            modifiedDate: Date(),
            source: .local,
            isDownloaded: true,
            hasCloudUpdate: false
        )
        let previews = LibraryBrowserManager.loadSetlistSongsPreview(for: reorderItem)
        #expect(previews.count == 2)
        #expect(previews[0].id == songB.id)
        #expect(previews[1].id == songA.id)

        let rep0 = previews[0].artwork?.representations.first
        let rep1 = previews[1].artwork?.representations.first
        #expect(rep0?.pixelsWide == 32 && rep0?.pixelsHigh == 20)
        #expect(rep1?.pixelsWide == 16 && rep1?.pixelsHigh == 16)

        // Part B: Legacy `songs/song_0/` + inline `waveformPeaksData` session without `peaks.bin` still loads cleanly
        let legacyURL = tempDir.appendingPathComponent("Legacy.pbsession", isDirectory: true)
        let legacySongDir = legacyURL.appendingPathComponent("songs/song_0", isDirectory: true)
        let legacyStemsDir = legacySongDir.appendingPathComponent("stems", isDirectory: true)
        try fm.createDirectory(at: legacyStemsDir, withIntermediateDirectories: true)

        let legacyArtworkData = try makeSolidPNGData(width: 24, height: 24, color: .green)
        try legacyArtworkData.write(to: legacySongDir.appendingPathComponent("artwork.png"), options: .atomic)

        let legacyStemURL = legacyStemsDir.appendingPathComponent("Drums.m4a")
        try PlaybackFileManager.shared.writeCompressedStem(buf, to: legacyStemURL)

        let legacySongId = UUID()
        let legacyTrackId = UUID()
        createdTrackIds.append(legacyTrackId)
        try? fm.removeItem(at: PlaybackFileManager.shared.cachedStemURL(for: legacyTrackId))

        let expectedLegacyPeaks = makePeaks(seed: 99)
        let legacyTrackMeta = TrackFileMetadata(
            id: legacyTrackId,
            name: "Drums",
            role: .stem,
            relativeAudioPath: "songs/song_0/stems/Drums.m4a",
            duration: 0.1,
            waveformPeaksData: TrackFileMetadata.encodePeaks(expectedLegacyPeaks)
        )
        let legacySongMeta = SongPackageMetadata(
            version: 2,
            id: legacySongId,
            title: "Legacy Song",
            artist: "Legacy Artist",
            bpm: 110.0,
            musicalKey: "A",
            tracks: [legacyTrackMeta],
            artworkData: nil
        )
        let legacySessionMeta = SessionPackageMetadata(
            version: 2,
            name: "Legacy Set",
            currentSongIndex: 0,
            songEntries: [legacySongMeta]
        )
        let legacyEncoder = JSONEncoder()
        try legacyEncoder.encode(legacySessionMeta).write(to: legacyURL.appendingPathComponent("session.json"), options: .atomic)

        // Confirm no peaks.bin or UUID dir exists
        #expect(!fm.fileExists(atPath: legacySongDir.appendingPathComponent("peaks.bin").path))
        #expect(!fm.fileExists(atPath: legacyURL.appendingPathComponent("songs/\(legacySongId.uuidString)").path))

        let legacyFast = try PlaybackFileManager.shared.loadSessionMetadataFast(from: legacyURL)
        defer {
            if let cleanup = legacyFast.cleanupFolder {
                try? fm.removeItem(at: cleanup)
            }
        }
        #expect(legacyFast.songsPlaceholderData.count == 1)
        #expect(legacyFast.songsPlaceholderData[0].song.artworkData != nil)
        #expect(legacyFast.songsPlaceholderData[0].tracks[0].0.waveformPeaks == expectedLegacyPeaks)

        let legacyFull = try PlaybackFileManager.shared.loadSession(from: legacyURL)
        #expect(legacyFull.songsData.count == 1)
        #expect(legacyFull.songsData[0].song.artworkData != nil)
        #expect(legacyFull.songsData[0].tracks.count == 1)
        #expect(legacyFull.songsData[0].tracks[0].0.waveformPeaks == expectedLegacyPeaks)
        #expect(legacyFull.songsData[0].tracks[0].1.frameLength > 0)

        let legacyPreviewItem = SetlistLibraryItem(
            id: legacyURL,
            url: legacyURL,
            name: "Legacy Set",
            songCount: 1,
            formattedDate: "",
            formattedDuration: "0:01",
            artworks: [],
            modifiedDate: Date(),
            source: .local,
            isDownloaded: true,
            hasCloudUpdate: false
        )
        let legacyPreviews = LibraryBrowserManager.loadSetlistSongsPreview(for: legacyPreviewItem)
        #expect(legacyPreviews.count == 1)
        let legacyPreviewRep = legacyPreviews[0].artwork?.representations.first
        #expect(legacyPreviewRep?.pixelsWide == 24 && legacyPreviewRep?.pixelsHigh == 24)
    }
}
