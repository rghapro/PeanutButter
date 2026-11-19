import Foundation
import SQLite3
import AVFoundation
import AppKit

// MARK: - Playback Import Models

public enum PlaybackImportScope: String, CaseIterable, Identifiable {
    case single = "Single Playlist"
    case upcoming = "Upcoming Playlists"
    case all = "All Playlists"
    public var id: String { rawValue }
}

public struct PlaybackSetlistSummary: Identifiable, Hashable {
    public let pk: Int64
    public let setlistId: Int64
    public let title: String
    public let performanceDate: Date?
    public let serviceTypeTitle: String?
    public let notes: String?
    public let songCount: Int
    
    public var id: Int64 { pk }
    
    public var isUpcoming: Bool {
        guard let date = performanceDate else { return false }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return date >= startOfToday
    }
    
    public var formattedDate: String {
        guard let date = performanceDate else { return "No Date" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}

public struct PlaybackTrackSlot: Identifiable, Hashable {
    public let pk: Int64
    public let title: String
    public let abbreviation: String
    public let volume: Float
    public let isMuted: Bool
    public let isClickOrGuide: Bool
    public let filename: String
    public let orderBy: Int
    public let partId: Int
    public let storedUUID: String
    public let localM4AURL: URL?
    
    public var id: Int64 { pk }
    
    public var isGeneratedClickSubdivision: Bool {
        let f = filename.lowercased()
        return f == "quarter" || f == "eighth" || f == "sixteenth" || f == "accents"
    }
    
    public var isSilencePlaceholder: Bool {
        let f = filename.lowercased()
        return f.isEmpty || f == "silence-long.m4a"
    }
    
    public var needsUserAudio: Bool {
        if isGeneratedClickSubdivision { return false }
        if localM4AURL != nil { return false }
        return true
    }
}

public struct PlaybackUniqueSong: Identifiable, Hashable {
    public let id: String // contentKey
    public let representativeSongPK: Int64
    public let title: String
    public let artist: String
    public let contentId: Int64
    public let contentTypeId: Int64
    public let bpm: Double
    public let musicalKey: String
    public let artworkData: Data?
    public let tracks: [PlaybackTrackSlot]
    public let isClickAndPad: Bool
    public let timeSignatureNumerator: Int
    public let timeSignatureDenominator: Int
    
    public init(
        id: String,
        representativeSongPK: Int64,
        title: String,
        artist: String,
        contentId: Int64,
        contentTypeId: Int64,
        bpm: Double,
        musicalKey: String,
        artworkData: Data?,
        tracks: [PlaybackTrackSlot],
        isClickAndPad: Bool = false,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4
    ) {
        self.id = id
        self.representativeSongPK = representativeSongPK
        self.title = title
        self.artist = artist
        self.contentId = contentId
        self.contentTypeId = contentTypeId
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.artworkData = artworkData
        self.tracks = tracks
        self.isClickAndPad = isClickAndPad
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
    }
    
    public var needsAudioCount: Int {
        if isClickAndPad { return 0 }
        return tracks.filter { $0.needsUserAudio }.count
    }
    
    public var embeddedM4ACount: Int {
        tracks.filter { $0.localM4AURL != nil }.count
    }
}

public struct PlaybackSongMatch: Identifiable {
    public let song: PlaybackUniqueSong
    public var matchedFolderURL: URL?
    /// Maps PlaybackTrackSlot.pk -> matched audio file URL
    public var trackFileMatches: [Int64: URL]
    /// Cached audio files inside matchedFolderURL for manual dropdown selection
    public var availableAudioFiles: [URL]
    
    public var id: String { song.id }
    
    public var tracksNeedingUserAudio: [PlaybackTrackSlot] {
        if song.isClickAndPad { return [] }
        return song.tracks.filter { $0.needsUserAudio }
    }
    
    public var matchedUserTrackCount: Int {
        tracksNeedingUserAudio.filter { trackFileMatches[$0.pk] != nil }.count
    }
    
    public var totalPlayableCount: Int {
        song.embeddedM4ACount + matchedUserTrackCount
    }
}

public struct PlaybackImportResult {
    public let importedSessionURLs: [URL]
    public let setlistCount: Int
    public let songCount: Int
    public let linkedAudioFilesCount: Int
}

public enum PlaybackImporterError: LocalizedError {
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case noSetlistsSelected
    
    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Could not find Playback's database at \(path)."
        case .databaseOpenFailed(let msg):
            return "Could not open Playback's database: \(msg)"
        case .noSetlistsSelected:
            return "No setlists were selected to import."
        }
    }
}

// MARK: - Playback Importer Service

public final class PlaybackImporter {
    public static let shared = PlaybackImporter()
    
    private static let coreDataEpochOffset: TimeInterval = 978307200.0
    private static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aif", "aiff", "flac"]
    
    public static var defaultContainerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.multitracks.custommixplayer/Data")
    }
    
    public static var defaultDatabaseURL: URL {
        defaultContainerURL
            .appendingPathComponent("Library/Application Support/com.multitracks.playback/AppData.storedata")
    }
    
    public static var defaultSongsDirectoryURL: URL {
        defaultContainerURL.appendingPathComponent("Documents/Songs")
    }
    
    private init() {}
    
    /// Checks whether Playback's default database is readable right now.
    public func resolveDefaultDatabase(customContainerOrDB: URL? = nil) -> (dbURL: URL, songsURL: URL)? {
        let fm = FileManager.default
        if let custom = customContainerOrDB {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: custom.path, isDirectory: &isDir) {
                if !isDir.boolValue && custom.lastPathComponent.hasSuffix(".storedata") {
                    // User picked AppData.storedata directly; infer Songs folder
                    let songs = custom
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("Documents/Songs")
                    return (custom, songs)
                } else if isDir.boolValue {
                    // User picked Data/ or container root
                    let directDB = custom.appendingPathComponent("Library/Application Support/com.multitracks.playback/AppData.storedata")
                    if fm.isReadableFile(atPath: directDB.path) {
                        return (directDB, custom.appendingPathComponent("Documents/Songs"))
                    }
                    let nestedDB = custom.appendingPathComponent("Data/Library/Application Support/com.multitracks.playback/AppData.storedata")
                    if fm.isReadableFile(atPath: nestedDB.path) {
                        return (nestedDB, custom.appendingPathComponent("Data/Documents/Songs"))
                    }
                }
            }
        }
        
        let defDB = Self.defaultDatabaseURL
        if fm.isReadableFile(atPath: defDB.path) {
            return (defDB, Self.defaultSongsDirectoryURL)
        }
        return nil
    }
    
    // MARK: - Safe Read-Only SQLite Snapshot
    
    private func withReadOnlySnapshot<T>(dbURL: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else {
            throw PlaybackImporterError.databaseNotFound(dbURL.path)
        }
        
        let tempDir = fm.temporaryDirectory.appendingPathComponent("playback_import_db_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        let destDB = tempDir.appendingPathComponent("AppData.storedata")
        try fm.copyItem(at: dbURL, to: destDB)
        
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: destDB.path + suffix))
            }
        }
        
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(destDB.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error (\(rc))"
            if let db { sqlite3_close(db) }
            throw PlaybackImporterError.databaseOpenFailed(msg)
        }
        defer { sqlite3_close(handle) }
        
        return try body(handle)
    }
    
    // MARK: - SQLite Helpers
    
    private func columnString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }
    
    private func columnData(_ stmt: OpaquePointer?, _ idx: Int32) -> Data? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, idx) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, idx))
        guard len > 0 else { return nil }
        return Data(bytes: ptr, count: len)
    }
    
    private func columnDate(_ stmt: OpaquePointer?, _ idx: Int32) -> Date? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        let val = sqlite3_column_double(stmt, idx)
        // Filter out sentinel far-future demo dates (> year 2100) or zero
        guard val != 0 && val < 4_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: val + Self.coreDataEpochOffset)
    }
    
    private func loadKeyMap(db: OpaquePointer) -> [Int64: String] {
        var map: [Int64: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT ZID, ZTITLE FROM ZMETADATAKEY WHERE ZID IS NOT NULL AND ZTITLE IS NOT NULL"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                if let title = columnString(stmt, 1) {
                    map[id] = title
                }
            }
        }
        sqlite3_finalize(stmt)
        return map
    }
    
    private func loadSectionMetadataMap(db: OpaquePointer) -> [Int64: (title: String, abbr: String)] {
        var map: [Int64: (title: String, abbr: String)] = [:]
        var stmt: OpaquePointer?
        let sql = """
        SELECT ZPARTID, ZTITLE, ZABBREVIATION
        FROM ZMETADATASECTION
        WHERE ZLOCALE = 'en' OR ZLOCALE IS NULL
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let partId = sqlite3_column_int64(stmt, 0)
                let title = columnString(stmt, 1) ?? "Section"
                let abbr = columnString(stmt, 2) ?? SongSection.abbreviation(for: title)
                map[partId] = (title, abbr)
            }
        }
        sqlite3_finalize(stmt)
        return map
    }

    private func loadTimeSignatureMetadataMap(db: OpaquePointer) -> [Int64: (num: Int, den: Int)] {
        var map: [Int64: (num: Int, den: Int)] = [:]
        var stmt: OpaquePointer?
        let sql = """
        SELECT ZSTOREDID, COALESCE(ZBEATSPERBAR, 4), COALESCE(ZBEATUNIT, 4)
        FROM ZMETADATATIMESIGNATURE
        WHERE ZSTOREDID IS NOT NULL
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let storedId = sqlite3_column_int64(stmt, 0)
                let num = max(1, Int(sqlite3_column_int64(stmt, 1)))
                let den = max(1, Int(sqlite3_column_int64(stmt, 2)))
                map[storedId] = (num, den)
            }
        }
        sqlite3_finalize(stmt)
        return map
    }

    private func loadPadTitleMap(db: OpaquePointer) -> [Int64: String] {
        var map: [Int64: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT Z_PK, ZTITLE FROM ZPAD WHERE ZTITLE IS NOT NULL"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                if let title = columnString(stmt, 1) {
                    map[pk] = title
                }
            }
        }
        sqlite3_finalize(stmt)
        return map
    }

    /// MultiTracks Playback marks native Click & Pad items with ZCONTENTTYPEID = 12 and ZSTOREDBEHAVIORTYPE = 5.
    public static func isClickAndPadSong(contentTypeId: Int64, storedBehaviorType: Int64) -> Bool {
        contentTypeId == 12 || storedBehaviorType == 5
    }

    private func resolveClickAndPadTimeSignature(
        timeSignaturesData: Data?,
        storedTimeSigId: Int64,
        rawTitle: String,
        timeSigMap: [Int64: (num: Int, den: Int)]
    ) -> (num: Int, den: Int) {
        if let first = parseTimeSignaturesJSON(timeSignaturesData).first {
            return (first.numerator, first.denominator)
        }
        if storedTimeSigId > 0, let mapped = timeSigMap[storedTimeSigId] {
            return mapped
        }
        for token in rawTitle.split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "/")
            if parts.count == 2,
               let num = Int(parts[0]), (1...32).contains(num),
               let den = Int(parts[1]), (1...32).contains(den) {
                return (num, den)
            }
        }
        return (4, 4)
    }

    private func resolveClickAndPadTitle(
        customName: String?,
        snapshotsData: Data?,
        rawTitle: String,
        bpm: Double,
        tsNum: Int,
        tsDen: Int
    ) -> String {
        if let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let data = snapshotsData,
           let snapshots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for snap in snapshots {
                if let custom = (snap["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !custom.isEmpty {
                    return custom
                }
            }
        }
        let trimmedRaw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty && trimmedRaw != "Untitled Song" {
            return trimmedRaw
        }
        let decimals = Song.tempoDecimalPrecision(for: bpm)
        return "\(Song.formatBPM(bpm, decimals: decimals)) BPM \(tsNum)/\(tsDen)"
    }

    private func fetchClickAndPadLoopAndMeasures(
        db: OpaquePointer,
        arrangementPK: Int64?,
        clickSongMeasureCount: Int64,
        secPerBar: Double
    ) -> (infiniteLoop: Bool, measures: Int) {
        struct ClickSectionRow {
            let typeId: Int64
            let origStart: Double
            let origEnd: Double
            let trimStart: Double
            let trimEnd: Double
            let presetInfiniteLoop: Int64
            let loopInfinite: Int64
        }

        var rows: [ClickSectionRow] = []
        if let apk = arrangementPK {
            var stmt: OpaquePointer?
            let sql = """
            SELECT COALESCE(NULLIF(ZEDITEDSECTIONTYPEID, 0), ZSTOREDSECTIONTYPE, 0),
                   COALESCE(ZSTARTTIMEORIGINAL, 0.0),
                   COALESCE(ZENDTIMEORIGINAL, 0.0),
                   COALESCE(ZSTOREDSTARTTIMETRIMOFFSET, 0.0),
                   COALESCE(ZSTOREDENDTIMETRIMOFFSET, 0.0),
                   COALESCE(ZPRESETINFINITELOOP, 0),
                   COALESCE(ZLOOPINFINITE, 0)
            FROM ZSONGSECTION
            WHERE ZARRANGEMENT = ?
            ORDER BY COALESCE(Z_FOK_ARRANGEMENT, Z_PK)
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, apk)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(ClickSectionRow(
                        typeId: sqlite3_column_int64(stmt, 0),
                        origStart: sqlite3_column_double(stmt, 1),
                        origEnd: sqlite3_column_double(stmt, 2),
                        trimStart: max(0.0, sqlite3_column_double(stmt, 3)),
                        trimEnd: max(0.0, sqlite3_column_double(stmt, 4)),
                        presetInfiniteLoop: sqlite3_column_int64(stmt, 5),
                        loopInfinite: sqlite3_column_int64(stmt, 6)
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }

        if !rows.isEmpty {
            if rows.contains(where: { $0.presetInfiniteLoop != 0 || $0.loopInfinite != 0 }) {
                return (true, 4)
            }
            let clickRow = rows.first(where: { $0.typeId == 61 })
                ?? (rows.count >= 2 ? rows[1] : rows[0])
            let effectiveDur = max(0.1, (clickRow.origEnd - clickRow.origStart) - clickRow.trimStart - clickRow.trimEnd)
            let barsFromSection = max(1, Int((effectiveDur / max(0.1, secPerBar)).rounded()))
            let resolvedMeasures = (clickRow.typeId == 61)
                ? barsFromSection
                : (clickSongMeasureCount > 0 ? Int(clickSongMeasureCount) : barsFromSection)
            return (false, max(1, resolvedMeasures))
        }

        if clickSongMeasureCount > 0 {
            return (false, Int(clickSongMeasureCount))
        }
        return (true, 4)
    }

    private struct ParsedClickSubdivisions {
        var quarterVol: Float = 0.80
        var eighthVol: Float = 0.70
        var sixteenthVol: Float = 0.0
        var accentVol: Float = 0.80
        var quarterOn: Bool = true
        var eighthOn: Bool = true
        var sixteenthOn: Bool = false
        var accentOn: Bool = true
    }

    private func parseClickSubdivisions(from slots: [PlaybackTrackSlot]) -> ParsedClickSubdivisions {
        var result = ParsedClickSubdivisions()
        for slot in slots {
            let fnLower = slot.filename.lowercased()
            let vol = min(1.0, max(0.0, slot.volume * 0.80))
            let enabled = !slot.isMuted && slot.volume > 0.001
            if fnLower == "quarter" {
                result.quarterVol = vol
                result.quarterOn = enabled
            } else if fnLower == "eighth" {
                result.eighthVol = vol
                result.eighthOn = enabled
            } else if fnLower == "sixteenth" {
                result.sixteenthVol = vol
                result.sixteenthOn = enabled
            } else if fnLower == "accents" {
                result.accentVol = vol
                result.accentOn = enabled
            }
        }
        return result
    }
    
    // MARK: - Step 1: Load Setlist Summaries
    
    public func fetchSetlists(dbURL: URL) throws -> [PlaybackSetlistSummary] {
        try withReadOnlySnapshot(dbURL: dbURL) { db in
            var results: [PlaybackSetlistSummary] = []
            var stmt: OpaquePointer?
            let sql = """
            SELECT sl.Z_PK, COALESCE(sl.ZSETLISTID, 0), COALESCE(sl.ZTITLE, 'Untitled Setlist'),
                   sl.ZPERFORMANCEDATE, sl.ZSERVICETYPETITLE, sl.ZNOTES, COUNT(s.Z_PK) AS song_cnt
            FROM ZSETLIST sl
            LEFT JOIN ZSONG s ON s.ZSETLIST = sl.Z_PK
            GROUP BY sl.Z_PK
            HAVING song_cnt > 0
            ORDER BY COALESCE(sl.ZPERFORMANCEDATE, 0) DESC, sl.Z_PK DESC
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PlaybackImporterError.databaseOpenFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let setlistId = sqlite3_column_int64(stmt, 1)
                let title = columnString(stmt, 2) ?? "Untitled Setlist"
                let perfDate = columnDate(stmt, 3)
                let serviceType = columnString(stmt, 4)
                let notes = columnString(stmt, 5)
                let songCount = Int(sqlite3_column_int64(stmt, 6))
                results.append(PlaybackSetlistSummary(
                    pk: pk,
                    setlistId: setlistId,
                    title: title,
                    performanceDate: perfDate,
                    serviceTypeTitle: serviceType,
                    notes: notes,
                    songCount: songCount
                ))
            }
            return results
        }
    }
    
    // MARK: - Step 2/3: Inspect Unique Songs in Selected Setlists
    
    public func fetchUniqueSongs(dbURL: URL, songsDirURL: URL, forSetlistPKs pks: [Int64]) throws -> [PlaybackUniqueSong] {
        guard !pks.isEmpty else { return [] }
        return try withReadOnlySnapshot(dbURL: dbURL) { db in
            let keyMap = loadKeyMap(db: db)
            let timeSigMap = loadTimeSignatureMetadataMap(db: db)
            let placeholders = pks.map { _ in "?" }.joined(separator: ",")
            
            let sql = """
            SELECT Z_PK, COALESCE(ZTITLE, 'Untitled Song'), COALESCE(ZARTISTNAME, ''),
                   COALESCE(ZCONTENTID, 0), COALESCE(ZCONTENTTYPEID, 0),
                   COALESCE(ZBPM, 120.0), COALESCE(ZKEYID, 0),
                   COALESCE(ZWORKINGCOPYARRANGEMENTID, 0), ZARTWORKDATA,
                   ZCUSTOMNAME, COALESCE(ZSTOREDBEHAVIORTYPE, 0), ZTIMESIGNATURESDATA,
                   COALESCE(ZSTOREDTIMESIGNATUREIDORIGINAL, 0), ZSTOREDARRANGEMENTSNAPSHOTS
            FROM ZSONG
            WHERE ZSETLIST IN (\(placeholders))
            ORDER BY ZSETLIST, COALESCE(Z_FOK_SETLIST, ZORDER, Z_PK)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw PlaybackImporterError.databaseOpenFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (i, pk) in pks.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), pk)
            }
            
            var seenKeys = Set<String>()
            var uniqueSongs: [PlaybackUniqueSong] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let songPK = sqlite3_column_int64(stmt, 0)
                let title = columnString(stmt, 1) ?? "Untitled Song"
                let artist = columnString(stmt, 2) ?? ""
                let contentId = sqlite3_column_int64(stmt, 3)
                let contentTypeId = sqlite3_column_int64(stmt, 4)
                let bpm = sqlite3_column_double(stmt, 5)
                let keyId = sqlite3_column_int64(stmt, 6)
                let workingArrId = sqlite3_column_int64(stmt, 7)
                let artwork = columnData(stmt, 8)
                let customName = columnString(stmt, 9)
                let behaviorType = sqlite3_column_int64(stmt, 10)
                let timeSignaturesData = columnData(stmt, 11)
                let storedTimeSigId = sqlite3_column_int64(stmt, 12)
                let snapshotsData = columnData(stmt, 13)
                
                if Self.isClickAndPadSong(contentTypeId: contentTypeId, storedBehaviorType: behaviorType) {
                    let safeBpm = max(20.0, min(300.0, bpm > 0 ? bpm : 120.0))
                    let ts = resolveClickAndPadTimeSignature(
                        timeSignaturesData: timeSignaturesData,
                        storedTimeSigId: storedTimeSigId,
                        rawTitle: title,
                        timeSigMap: timeSigMap
                    )
                    let displayTitle = resolveClickAndPadTitle(
                        customName: customName,
                        snapshotsData: snapshotsData,
                        rawTitle: title,
                        bpm: safeBpm,
                        tsNum: ts.num,
                        tsDen: ts.den
                    )
                    let arrPK = resolveWorkingArrangementPK(db: db, songPK: songPK, workingArrId: workingArrId)
                    let arrSettings = arrPK.flatMap { fetchArrangementSettings(db: db, arrangementPK: $0) }
                    let ambientPadEnabled = arrSettings?.includePad ?? false
                    let effectiveKey = ambientPadEnabled ? (keyMap[keyId] ?? "C") : ""
                    let contentKey = "clickpad|\(displayTitle.lowercased())|\(Int((safeBpm * 100.0).rounded()))|\(ts.num)/\(ts.den)|\(effectiveKey)"
                    guard !seenKeys.contains(contentKey) else { continue }
                    seenKeys.insert(contentKey)
                    
                    uniqueSongs.append(PlaybackUniqueSong(
                        id: contentKey,
                        representativeSongPK: songPK,
                        title: displayTitle,
                        artist: "",
                        contentId: contentId,
                        contentTypeId: contentTypeId,
                        bpm: safeBpm,
                        musicalKey: effectiveKey,
                        artworkData: nil,
                        tracks: [],
                        isClickAndPad: true,
                        timeSignatureNumerator: ts.num,
                        timeSignatureDenominator: ts.den
                    ))
                    continue
                }
                
                let contentKey = Self.makeContentKey(contentTypeId: contentTypeId, contentId: contentId, title: title, artist: artist)
                guard !seenKeys.contains(contentKey) else { continue }
                seenKeys.insert(contentKey)
                
                let arrPK = resolveWorkingArrangementPK(db: db, songPK: songPK, workingArrId: workingArrId)
                let tracks = arrPK.map {
                    fetchTrackSlots(db: db, arrangementPK: $0, songsDirURL: songsDirURL, contentTypeId: contentTypeId, contentId: contentId)
                } ?? []
                let firstTS = parseTimeSignaturesJSON(timeSignaturesData).first
                
                uniqueSongs.append(PlaybackUniqueSong(
                    id: contentKey,
                    representativeSongPK: songPK,
                    title: title,
                    artist: artist,
                    contentId: contentId,
                    contentTypeId: contentTypeId,
                    bpm: bpm > 0 ? bpm : 120.0,
                    musicalKey: keyMap[keyId] ?? "C",
                    artworkData: artwork,
                    tracks: tracks,
                    isClickAndPad: false,
                    timeSignatureNumerator: firstTS?.numerator ?? 4,
                    timeSignatureDenominator: firstTS?.denominator ?? 4
                ))
            }
            return uniqueSongs
        }
    }
    
    private static func makeContentKey(contentTypeId: Int64, contentId: Int64, title: String, artist: String) -> String {
        if contentId > 0 {
            return "\(contentTypeId)-\(contentId)"
        }
        return "\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    
    private func resolveWorkingArrangementPK(db: OpaquePointer, songPK: Int64, workingArrId: Int64) -> Int64? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT Z_PK FROM ZSONGARRANGEMENT
        WHERE ZSONG = ?
        ORDER BY CASE WHEN ZID = ? THEN 0 ELSE 1 END, Z_PK DESC
        LIMIT 1
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, songPK)
        sqlite3_bind_int64(stmt, 2, workingArrId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }
    
    private func findSongCacheFolder(songsDirURL: URL, contentTypeId: Int64, contentId: Int64) -> URL? {
        guard contentId > 0 else { return nil }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: songsDirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let prefix = "\(contentTypeId)-\(contentId)-"
        let exact = "\(contentTypeId)-\(contentId)"
        return contents.first { url in
            let name = url.lastPathComponent
            return name == exact || name.hasPrefix(prefix)
        }
    }
    
    private func fetchTrackSlots(
        db: OpaquePointer,
        arrangementPK: Int64,
        songsDirURL: URL,
        contentTypeId: Int64,
        contentId: Int64
    ) -> [PlaybackTrackSlot] {
        let songFolder = findSongCacheFolder(songsDirURL: songsDirURL, contentTypeId: contentTypeId, contentId: contentId)
        var slots: [PlaybackTrackSlot] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT Z_PK, COALESCE(ZTITLE, ''), COALESCE(ZSTOREDABBREVIATION, ''),
               COALESCE(ZVOLUME, 1.0), COALESCE(ZISMUTED, 0), COALESCE(ZISCLICKORGUIDE, 0),
               COALESCE(ZFILENAME, ''), COALESCE(ZORDERBY, 0), COALESCE(ZSTOREDUUID, ''),
               COALESCE(ZPARTID, 0)
        FROM ZSONGTRACK
        WHERE ZARRANGEMENT = ?
        ORDER BY ZORDERBY, Z_PK
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, arrangementPK)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let title = columnString(stmt, 1) ?? ""
            let abbr = columnString(stmt, 2) ?? ""
            let volume = Float(sqlite3_column_double(stmt, 3))
            let isMuted = sqlite3_column_int64(stmt, 4) != 0
            let isClickOrGuide = sqlite3_column_int64(stmt, 5) != 0
            let filename = columnString(stmt, 6) ?? ""
            let orderBy = Int(sqlite3_column_int64(stmt, 7))
            let storedUUID = columnString(stmt, 8) ?? ""
            let partId = Int(sqlite3_column_int64(stmt, 9))
            
            // Skip unnamed internal Left/Right master bus stubs and "Original Song" reference track
            if title.isEmpty && filename.isEmpty { continue }
            if title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "original song" { continue }
            
            var localM4A: URL? = nil
            if filename.lowercased().hasSuffix(".m4a"),
               filename.lowercased() != "silence-long.m4a",
               let folder = songFolder {
                let candidate = folder.appendingPathComponent(filename)
                if FileManager.default.isReadableFile(atPath: candidate.path) {
                    localM4A = candidate
                }
            }
            
            slots.append(PlaybackTrackSlot(
                pk: pk,
                title: title.isEmpty ? filename : title,
                abbreviation: abbr,
                volume: volume,
                isMuted: isMuted,
                isClickOrGuide: isClickOrGuide,
                filename: filename,
                orderBy: orderBy,
                partId: partId,
                storedUUID: storedUUID,
                localM4AURL: localM4A
            ))
        }
        return slots
    }
    
    // MARK: - Smart Folder & Track Auto-Matching
    
    public func scanAudioLibrary(rootURL: URL, for songs: [PlaybackUniqueSong]) -> [PlaybackSongMatch] {
        let needsDiskScan = songs.contains { !$0.isClickAndPad }
        let candidateFolders = needsDiskScan ? collectAudioFolders(under: rootURL) : []
        return songs.map { song in
            if song.isClickAndPad {
                return buildMatchState(for: song, folderURL: nil)
            }
            let bestFolder = findBestMatchingFolder(for: song, in: candidateFolders)
            return buildMatchState(for: song, folderURL: bestFolder)
        }
    }
    
    public func buildMatchState(for song: PlaybackUniqueSong, folderURL: URL?) -> PlaybackSongMatch {
        guard !song.isClickAndPad, let folderURL = folderURL else {
            return PlaybackSongMatch(song: song, matchedFolderURL: nil, trackFileMatches: [:], availableAudioFiles: [])
        }
        let audioFiles = audioFilesInFolder(folderURL)
        let matches = autoMatchTracks(audioFiles: audioFiles, tracks: song.tracks)
        return PlaybackSongMatch(
            song: song,
            matchedFolderURL: folderURL,
            trackFileMatches: matches,
            availableAudioFiles: audioFiles
        )
    }
    
    private func collectAudioFolders(under rootURL: URL) -> [URL] {
        let fm = FileManager.default
        var folders: [URL] = []
        var visited = Set<URL>()
        
        func scan(_ dir: URL, depth: Int) {
            guard depth <= 3, !visited.contains(dir) else { return }
            visited.insert(dir)
            
            // Never treat the parent rootURL itself as a song folder if it contains subdirectories
            // (e.g. STEMS/<Song Title>/multitracks/*.wav).
            if dir != rootURL {
                if resolvedStemSubfolder(in: dir) != nil || !directAudioFiles(in: dir).isEmpty {
                    folders.append(dir)
                    return
                }
            }
            
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                if dir == rootURL && !directAudioFiles(in: dir).isEmpty {
                    folders.append(dir)
                }
                return
            }
            var hasSubdir = false
            for child in children {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    hasSubdir = true
                    scan(child, depth: depth + 1)
                }
            }
            if dir == rootURL && !hasSubdir && !directAudioFiles(in: dir).isEmpty {
                folders.append(dir)
            }
        }
        
        scan(rootURL, depth: 0)
        return folders
    }
    
    private func directAudioFiles(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.filter { url in
            Self.audioExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    
    private func resolvedStemSubfolder(in folderURL: URL) -> URL? {
        let fm = FileManager.default
        let preferredNames = ["multitracks", "multitrack", "stems", "tracks", "audio", "wav", "m4a"]
        guard let children = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        
        var bestSubfolder: URL? = nil
        var bestScore = -1
        
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            
            let lowerName = child.lastPathComponent.lowercased()
            let isPreferred = preferredNames.contains(where: { lowerName.contains($0) })
            let direct = directAudioFiles(in: child)
            if !direct.isEmpty && (isPreferred || children.count == 1) {
                let score = (isPreferred ? 1000 : 0) + direct.count
                if score > bestScore {
                    bestScore = score
                    bestSubfolder = child
                }
            }
        }
        return bestSubfolder
    }
    
    private func audioFilesInFolder(_ folderURL: URL) -> [URL] {
        // Always prefer a dedicated "MultiTracks" / "Stems" subfolder if present
        // (so stray files in the parent song folder don't shadow the stems folder).
        if let sub = resolvedStemSubfolder(in: folderURL) {
            let subFiles = directAudioFiles(in: sub)
            if !subFiles.isEmpty {
                return subFiles
            }
        }
        return directAudioFiles(in: folderURL)
    }
    
    private func highResArtworkData(in folderURL: URL?) -> Data? {
        guard let folderURL = folderURL else { return nil }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let imageExts: Set<String> = ["jpg", "jpeg", "png"]
        let images = items.filter { imageExts.contains($0.pathExtension.lowercased()) }
        let preferred = images.first {
            let n = $0.deletingPathExtension().lastPathComponent.lowercased()
            return n.contains("album") || n.contains("artwork") || n.contains("cover")
        } ?? images.first
        if let imgURL = preferred, let data = try? Data(contentsOf: imgURL), !data.isEmpty {
            return data
        }
        return nil
    }
    
    private func findBestMatchingFolder(for song: PlaybackUniqueSong, in folders: [URL]) -> URL? {
        let targetTokens = normalizedTokens(song.title)
        guard !targetTokens.isEmpty else { return nil }
        let artistTokens = normalizedTokens(song.artist)
        
        var bestURL: URL? = nil
        var bestScore: Double = 0.0
        
        for folder in folders {
            let folderTokens = normalizedTokens(folder.lastPathComponent)
            guard !folderTokens.isEmpty else { continue }
            
            let overlap = targetTokens.intersection(folderTokens).count
            guard overlap > 0 else { continue }
            
            var score = Double(overlap) / Double(targetTokens.count)
            // Bonus for matching artist or exact normalized substring
            let normTitle = normalizedString(song.title)
            let normFolder = normalizedString(folder.lastPathComponent)
            if normFolder == normTitle {
                score += 1.0
            } else if normFolder.contains(normTitle) || normTitle.contains(normFolder) {
                score += 0.4
            }
            if !artistTokens.isEmpty && !artistTokens.intersection(folderTokens).isEmpty {
                score += 0.25
            }
            
            if score >= 0.75 && score > bestScore {
                bestScore = score
                bestURL = folder
            }
        }
        return bestURL
    }
    
    private func autoMatchTracks(audioFiles: [URL], tracks: [PlaybackTrackSlot]) -> [Int64: URL] {
        var result: [Int64: URL] = [:]
        var usedFiles = Set<URL>()
        
        // Pass 1: exact normalized name match
        for track in tracks where track.needsUserAudio {
            let trackNorm = normalizedStemName(track.title)
            guard !trackNorm.isEmpty else { continue }
            if let exact = audioFiles.first(where: { !usedFiles.contains($0) && normalizedStemName($0.deletingPathExtension().lastPathComponent) == trackNorm }) {
                result[track.pk] = exact
                usedFiles.insert(exact)
            }
        }
        
        // Pass 2: token / alias similarity match
        for track in tracks where track.needsUserAudio && result[track.pk] == nil {
            let trackTokens = stemAliasTokens(track.title)
            guard !trackTokens.isEmpty else { continue }
            
            var bestFile: URL? = nil
            var bestScore: Double = 0.0
            for file in audioFiles where !usedFiles.contains(file) {
                let fileTokens = stemAliasTokens(file.deletingPathExtension().lastPathComponent)
                guard !fileTokens.isEmpty else { continue }
                let overlap = trackTokens.intersection(fileTokens).count
                guard overlap > 0 else { continue }
                let union = trackTokens.union(fileTokens).count
                let score = Double(overlap) / Double(max(1, union))
                if score > bestScore && score >= 0.45 {
                    bestScore = score
                    bestFile = file
                }
            }
            if let matched = bestFile {
                result[track.pk] = matched
                usedFiles.insert(matched)
            }
        }
        return result
    }
    
    private func normalizedString(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func normalizedTokens(_ s: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "a", "an", "and", "of", "live", "multi", "multitrack", "multitracks", "stems", "bpm"]
        let words = normalizedString(s).split(separator: " ").map(String.init)
        return Set(words.filter { $0.count > 1 && !stopWords.contains($0) })
    }
    
    private func normalizedStemName(_ s: String) -> String {
        // Strip leading track numbers like "01 ", "01_", "1 - "
        let stripped = s.replacingOccurrences(of: "^\\d+\\s*[-_.]*\\s*", with: "", options: .regularExpression)
        return normalizedString(stripped)
    }
    
    private func stemAliasTokens(_ s: String) -> Set<String> {
        var tokens = Set(normalizedStemName(s).split(separator: " ").map(String.init))
        let replacements: [String: [String]] = [
            "eg": ["electric", "guitar"],
            "ag": ["acoustic", "guitar"],
            "bgv": ["background", "vocals", "bgvs", "backing", "vox"],
            "bgvs": ["background", "vocals", "bgv", "backing", "vox"],
            "background": ["bgv", "bgvs", "backing"],
            "vocals": ["bgv", "bgvs", "vox"],
            "vox": ["vocals", "lead", "bgv", "bgvs"],
            "sax": ["saxophone"],
            "saxophone": ["sax"],
            "perc": ["percussion"],
            "percussion": ["perc"],
            "md": ["guide", "cue"],
            "kb": ["keys", "keyboard"],
            "kbd": ["keys", "keyboard"],
            "synth": ["keys", "synth"],
            "b": ["bass"]
        ]
        for (abbr, expanded) in replacements {
            if tokens.contains(abbr) {
                tokens.formUnion(expanded)
            }
        }
        return tokens
    }
    
    // MARK: - Step 4: Execute Full Import into .pbsession Packages
    
    public func performImport(
        dbURL: URL,
        songsDirURL: URL,
        selectedSetlists: [PlaybackSetlistSummary],
        matchByContentKey: [String: PlaybackSongMatch],
        overrideSetlistTitle: String? = nil,
        destinationDirectory: URL? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) throws -> PlaybackImportResult {
        guard !selectedSetlists.isEmpty else {
            throw PlaybackImporterError.noSetlistsSelected
        }
        
        let fm = FileManager.default
        let setlistsDir = destinationDirectory ?? LibraryBrowserManager.localSetlistsDirectoryURL
        try fm.createDirectory(at: setlistsDir, withIntermediateDirectories: true)
        
        return try withReadOnlySnapshot(dbURL: dbURL) { db in
            let keyMap = loadKeyMap(db: db)
            let sectionMetaMap = loadSectionMetadataMap(db: db)
            let timeSigMap = loadTimeSignatureMetadataMap(db: db)
            let padTitleMap = loadPadTitleMap(db: db)
            
            var importedURLs: [URL] = []
            var totalSongsImported = 0
            var totalAudioFilesLinked = 0
            
            for (idx, setlistSummary) in selectedSetlists.enumerated() {
                progressHandler?(Double(idx) / Double(selectedSetlists.count), "Importing \(setlistSummary.title)...")
                
                let importedSongsData = try buildSongsForSetlist(
                    db: db,
                    setlistPK: setlistSummary.pk,
                    songsDirURL: songsDirURL,
                    keyMap: keyMap,
                    sectionMetaMap: sectionMetaMap,
                    timeSigMap: timeSigMap,
                    padTitleMap: padTitleMap,
                    matchByContentKey: matchByContentKey
                )
                
                let songs = importedSongsData.map { $0.song }
                let linkedCount = importedSongsData.reduce(0) { sum, item in
                    sum + item.tracks.filter { $0.fileURL != nil }.count
                }
                totalSongsImported += songs.count
                totalAudioFilesLinked += linkedCount
                
                let effectiveTitle = (selectedSetlists.count == 1 ? overrideSetlistTitle : nil) ?? setlistSummary.title
                let setlist = Setlist(
                    name: effectiveTitle,
                    date: setlistSummary.performanceDate ?? Date(),
                    serviceType: setlistSummary.serviceTypeTitle,
                    scheduledDate: setlistSummary.performanceDate,
                    songs: songs
                )
                
                let fileName = uniqueSessionFilename(baseName: effectiveTitle, in: setlistsDir)
                let destURL = setlistsDir.appendingPathComponent(fileName)
                
                try PlaybackFileManager.shared.exportSession(
                    setlist: setlist,
                    currentSongIndex: 0,
                    allSongsData: importedSongsData,
                    to: destURL,
                    asDirectoryPackage: true
                )
                importedURLs.append(destURL)
            }
            
            progressHandler?(1.0, "Finalizing library...")
            return PlaybackImportResult(
                importedSessionURLs: importedURLs,
                setlistCount: importedURLs.count,
                songCount: totalSongsImported,
                linkedAudioFilesCount: totalAudioFilesLinked
            )
        }
    }
    
    private func uniqueSessionFilename(baseName: String, in directory: URL) -> String {
        let sanitized = LibraryBrowserManager.sanitizedPackageFilename(baseName.isEmpty ? "Imported Setlist" : baseName, ext: "pbsession")
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.appendingPathComponent(sanitized).path) {
            return sanitized
        }
        let stem = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let candidate = "\(stem) (\(counter)).pbsession"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }
    
    private func buildSongsForSetlist(
        db: OpaquePointer,
        setlistPK: Int64,
        songsDirURL: URL,
        keyMap: [Int64: String],
        sectionMetaMap: [Int64: (title: String, abbr: String)],
        timeSigMap: [Int64: (num: Int, den: Int)],
        padTitleMap: [Int64: String],
        matchByContentKey: [String: PlaybackSongMatch]
    ) throws -> [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT Z_PK, COALESCE(ZTITLE, 'Untitled Song'), COALESCE(ZARTISTNAME, ''),
               COALESCE(ZCONTENTID, 0), COALESCE(ZCONTENTTYPEID, 0),
               COALESCE(ZBPM, 120.0), COALESCE(ZBPMORIGINAL, 120.0),
               COALESCE(ZKEYID, 0), COALESCE(ZKEYIDORIGINAL, 0), COALESCE(ZSTOREDOFFICIALKEYID, 0),
               COALESCE(ZWORKINGCOPYARRANGEMENTID, 0), ZARTWORKDATA, ZTIMESIGNATURESDATA,
               ZSTOREDARRANGEMENTSNAPSHOTS,
               COALESCE(ZMIDIPROPRESENTERPLAYLIST, 0), COALESCE(ZMIDIPROPRESENTERPLAYLISTITEM, 0),
               ZCUSTOMNAME, COALESCE(ZSTOREDBEHAVIORTYPE, 0),
               COALESCE(ZCLICKSONGMEASURECOUNT, -1), COALESCE(ZSTOREDTIMESIGNATUREIDORIGINAL, 0)
        FROM ZSONG
        WHERE ZSETLIST = ?
        ORDER BY COALESCE(Z_FOK_SETLIST, ZORDER, Z_PK)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PlaybackImporterError.databaseOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, setlistPK)
        
        var result: [(song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer])] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let songPK = sqlite3_column_int64(stmt, 0)
            let title = columnString(stmt, 1) ?? "Untitled Song"
            let artist = columnString(stmt, 2) ?? ""
            let contentId = sqlite3_column_int64(stmt, 3)
            let contentTypeId = sqlite3_column_int64(stmt, 4)
            let bpmRaw = sqlite3_column_double(stmt, 5)
            let origBpmRaw = sqlite3_column_double(stmt, 6)
            let keyId = sqlite3_column_int64(stmt, 7)
            let origKeyId = sqlite3_column_int64(stmt, 8)
            let officialKeyId = sqlite3_column_int64(stmt, 9)
            let workingArrId = sqlite3_column_int64(stmt, 10)
            let artworkData = columnData(stmt, 11)
            let timeSignaturesData = columnData(stmt, 12)
            let arrangementSnapshotsData = columnData(stmt, 13)
            let ppPlaylistRaw = Int(sqlite3_column_int64(stmt, 14))
            let ppItemRaw = Int(sqlite3_column_int64(stmt, 15))
            let customName = columnString(stmt, 16)
            let behaviorType = sqlite3_column_int64(stmt, 17)
            let clickSongMeasureCount = sqlite3_column_int64(stmt, 18)
            let storedTimeSigId = sqlite3_column_int64(stmt, 19)
            
            let bpm = bpmRaw > 0 ? bpmRaw : 120.0
            let originalBPM = origBpmRaw > 0 ? origBpmRaw : bpm
            
            let arrPK = resolveWorkingArrangementPK(db: db, songPK: songPK, workingArrId: workingArrId)
            let arrSettings = arrPK.flatMap { fetchArrangementSettings(db: db, arrangementPK: $0) }
            let trackSlots = arrPK.map {
                fetchTrackSlots(db: db, arrangementPK: $0, songsDirURL: songsDirURL, contentTypeId: contentTypeId, contentId: contentId)
            } ?? []
            
            if Self.isClickAndPadSong(contentTypeId: contentTypeId, storedBehaviorType: behaviorType) {
                let clickPadItem = buildClickAndPadSong(
                    db: db,
                    songPK: songPK,
                    rawTitle: title,
                    customName: customName,
                    bpm: bpm,
                    keyId: keyId,
                    arrPK: arrPK,
                    arrSettings: arrSettings,
                    trackSlots: trackSlots,
                    clickSongMeasureCount: clickSongMeasureCount,
                    storedTimeSigId: storedTimeSigId,
                    timeSignaturesData: timeSignaturesData,
                    arrangementSnapshotsData: arrangementSnapshotsData,
                    ppPlaylistRaw: ppPlaylistRaw,
                    ppItemRaw: ppItemRaw,
                    keyMap: keyMap,
                    timeSigMap: timeSigMap,
                    padTitleMap: padTitleMap
                )
                result.append(clickPadItem)
                continue
            }
            
            let contentKey = Self.makeContentKey(contentTypeId: contentTypeId, contentId: contentId, title: title, artist: artist)
            let songMatch = matchByContentKey[contentKey]
            
            let sections = arrPK.map { fetchSections(db: db, arrangementPK: $0, sectionMetaMap: sectionMetaMap, bpm: bpm) } ?? []
            
            let (defaultSections, savedArrangements, activeArrangementId) = buildArrangements(
                db: db,
                songPK: songPK,
                workingArrPK: arrPK,
                workingArrId: workingArrId,
                workingSections: sections,
                snapshotsData: arrangementSnapshotsData,
                sectionMetaMap: sectionMetaMap,
                bpm: bpm
            )
            
            let usesPlaybackM4A = trackSlots.contains { $0.localM4AURL != nil }
            let resolvedOrigKeyId: Int64 = {
                if !usesPlaybackM4A && officialKeyId > 0 {
                    return officialKeyId
                }
                if origKeyId > 0 { return origKeyId }
                if officialKeyId > 0 { return officialKeyId }
                return keyId
            }()
            let originalKey = keyMap[resolvedOrigKeyId] ?? "C"
            let targetKey = keyMap[keyId] ?? originalKey
            let transposeSemitones = computeSemitoneDelta(from: originalKey, to: targetKey)
            
            let subdivisions = parseClickSubdivisions(from: trackSlots)
            var stemTracks: [StemTrack] = []
            var trackUUIDByPlaybackUUID: [String: UUID] = [:]
            var trackIDByOrderBy: [Int: UUID] = [:]
            
            for slot in trackSlots {
                if slot.isGeneratedClickSubdivision { continue }
                
                // Resolve audio URL: matched folder file -> Playback local .m4a -> nil
                let resolvedURL: URL? = songMatch?.trackFileMatches[slot.pk] ?? slot.localM4AURL
                let role: TrackRole = slot.isClickOrGuide
                    ? (slot.title.lowercased().contains("guide") ? .guide : .click)
                    : StemTrack.autoDetectRole(for: slot.title)
                
                // Skip unlinked Click/Guide placeholder slots so we don't create duplicate empty channels
                // alongside the app's generated Click/Guide tracks.
                if (role == .click || role == .guide) && resolvedURL == nil {
                    continue
                }
                
                // Playback stores linear 0..1 volume where 1.0 = unity; our fader uses 0.80 = 0dB
                let normalizedFader = min(1.0, max(0.0, slot.volume * 0.80))
                let trackDisplayName = (role == .click) ? "Click" : slot.title
                if role == .click && stemTracks.contains(where: { $0.role == .click }) {
                    continue
                }
                let stemTrack = StemTrack(
                    name: trackDisplayName,
                    role: role,
                    fileURL: resolvedURL,
                    sourceFileURL: resolvedURL,
                    volume: normalizedFader,
                    isMuted: slot.isMuted
                )
                if !slot.storedUUID.isEmpty {
                    trackUUIDByPlaybackUUID[slot.storedUUID] = stemTrack.id
                }
                if slot.partId > 0 {
                    trackIDByOrderBy[slot.partId] = stemTrack.id
                }
                stemTracks.append(stemTrack)
            }
            
            let midiCues = fetchMIDICues(db: db, songPK: songPK, sections: sections)
            let automationPoints = arrPK.map {
                fetchAutomationCues(
                    db: db,
                    arrangementPK: $0,
                    sections: sections,
                    trackMap: trackUUIDByPlaybackUUID,
                    trackOrderMap: trackIDByOrderBy
                )
            } ?? []
            
            let timeSignatures = parseTimeSignaturesJSON(timeSignaturesData)
            let initialTS = timeSignatures.first ?? PlaybackTimeSigEntry(time: 0.0, numerator: 4, denominator: 4)
            let tempoPoints = fetchTempoPoints(db: db, songPK: songPK)
            let songClicks = fetchSongClickTimestamps(db: db, songPK: songPK)
            let totalEndTime = max(sections.last?.endTime ?? 0.0, defaultSections.last?.endTime ?? 0.0)
            let beatGrid = buildBeatGrid(
                totalDuration: totalEndTime,
                baseBPM: bpm,
                tempoPoints: tempoPoints,
                timeSignatures: timeSignatures,
                clickAccents: songClicks.accents,
                clickQuarters: songClicks.quarters
            )
            
            let resolvedArtwork: Data? = {
                if let folderArt = highResArtworkData(in: songMatch?.matchedFolderURL) {
                    return folderArt
                }
                if let cacheDir = findSongCacheFolder(songsDirURL: songsDirURL, contentTypeId: contentTypeId, contentId: contentId) {
                    let album2x = cacheDir.appendingPathComponent("Album2x.jpg")
                    if let d = try? Data(contentsOf: album2x), !d.isEmpty {
                        return d
                    }
                }
                return artworkData
            }()
            
            let hasUploadedClick = stemTracks.contains {
                ($0.role == .click || StemCategory.category(for: $0.name, role: $0.role) == .click) && $0.fileURL != nil
            }
            let hasUploadedGuide = stemTracks.contains {
                ($0.role == .guide || StemCategory.category(for: $0.name, role: $0.role) == .guide) && $0.fileURL != nil
            }
            let hasPlaybackClickOrGuide = trackSlots.contains { slot in
                if slot.isClickOrGuide || slot.isGeneratedClickSubdivision { return true }
                let cat = StemCategory.category(for: slot.title, role: StemTrack.autoDetectRole(for: slot.title))
                return cat == .click || cat == .guide
            }
            let excludesClickAndGuide = !hasPlaybackClickOrGuide && !hasUploadedClick && !hasUploadedGuide
            
            let defaultClickPref = UserDefaults.standard.string(forKey: "Playback_DefaultClickSource")
                .flatMap(ClickSource.init(rawValue:)) ?? .uploaded
            let defaultGuidePref = UserDefaults.standard.string(forKey: "Playback_DefaultGuideSource")
                .flatMap(GuideSource.init(rawValue:)) ?? .uploaded
            let resolvedClickSource: ClickSource = (defaultClickPref == .uploaded && hasUploadedClick) ? .uploaded : .generated
            let resolvedGuideSource: GuideSource = (defaultGuidePref == .uploaded && hasUploadedGuide) ? .uploaded : .generated
            let globalStartPad = UserDefaults.standard.bool(forKey: "Playback_GlobalStartPadWithSongEnabled")
            let defaultPadPreset = PadLibraryManager.shared.activePackId
            
            let tsChanges: [TimeSignatureChange] = timeSignatures.dropFirst().map {
                TimeSignatureChange(audioTime: $0.time, numerator: $0.numerator, denominator: $0.denominator)
            }
            
            let song = Song(
                title: title,
                artist: artist,
                bpm: bpm,
                originalBPM: originalBPM,
                timeSignatureNumerator: initialTS.numerator,
                timeSignatureDenominator: initialTS.denominator,
                musicalKey: originalKey,
                transposeSemitones: transposeSemitones,
                sections: sections,
                defaultSections: defaultSections,
                savedArrangements: savedArrangements,
                activeArrangementId: activeArrangementId,
                stemURLs: stemTracks.compactMap { $0.fileURL },
                timeSignatureChanges: tsChanges,
                beatGrid: beatGrid,
                midiCues: midiCues,
                automationPoints: automationPoints,
                proPresenterPlaylist: (ppPlaylistRaw > 0 && ppPlaylistRaw <= 127) ? ppPlaylistRaw : nil,
                proPresenterPlaylistItem: (ppItemRaw > 0 && ppItemRaw <= 127) ? ppItemRaw : nil,
                transitionType: {
                    switch arrSettings?.storedTransition ?? 0 {
                    case 1: return .autoLink
                    case 2: return .overlap
                    case 3: return .crossfade
                    case 4: return .stayInSong
                    default: return (arrSettings?.transitionContinuePad == true) ? .overlap : .cueNextSong
                    }
                }(),
                continuePad: arrSettings?.transitionContinuePad ?? false,
                endFadeOutEnabled: arrSettings?.endFade ?? false,
                startPadWithSong: globalStartPad || (arrSettings?.includePad ?? false),
                padPresetId: defaultPadPreset,
                padIntroOutroOnly: arrSettings?.padIntroOutroOnly ?? false,
                artworkData: resolvedArtwork,
                clickSource: resolvedClickSource,
                guideSource: resolvedGuideSource,
                clickAccentEnabled: subdivisions.accentOn,
                clickQuarterEnabled: subdivisions.quarterOn,
                clickEighthEnabled: subdivisions.eighthOn,
                clickSixteenthEnabled: subdivisions.sixteenthOn,
                clickAccentVolume: subdivisions.accentVol,
                clickQuarterVolume: subdivisions.quarterVol,
                clickEighthVolume: subdivisions.eighthVol,
                clickSixteenthVolume: subdivisions.sixteenthVol,
                excludesClickAndGuide: excludesClickAndGuide
            )
            
            result.append((song: song, tracks: stemTracks, buffers: [:]))
        }
        return result
    }

    private func buildClickAndPadSong(
        db: OpaquePointer,
        songPK: Int64,
        rawTitle: String,
        customName: String?,
        bpm: Double,
        keyId: Int64,
        arrPK: Int64?,
        arrSettings: ArrangementSettings?,
        trackSlots: [PlaybackTrackSlot],
        clickSongMeasureCount: Int64,
        storedTimeSigId: Int64,
        timeSignaturesData: Data?,
        arrangementSnapshotsData: Data?,
        ppPlaylistRaw: Int,
        ppItemRaw: Int,
        keyMap: [Int64: String],
        timeSigMap: [Int64: (num: Int, den: Int)],
        padTitleMap: [Int64: String]
    ) -> (song: Song, tracks: [StemTrack], buffers: [UUID: AVAudioPCMBuffer]) {
        let safeBpm = max(20.0, min(300.0, bpm))
        let ts = resolveClickAndPadTimeSignature(
            timeSignaturesData: timeSignaturesData,
            storedTimeSigId: storedTimeSigId,
            rawTitle: rawTitle,
            timeSigMap: timeSigMap
        )
        let secPerBeat = (60.0 / safeBpm) * (4.0 / Double(max(1, ts.den)))
        let secPerBar = secPerBeat * Double(max(1, ts.num))
        let finalTitle = resolveClickAndPadTitle(
            customName: customName,
            snapshotsData: arrangementSnapshotsData,
            rawTitle: rawTitle,
            bpm: safeBpm,
            tsNum: ts.num,
            tsDen: ts.den
        )
        let (infiniteLoop, measures) = fetchClickAndPadLoopAndMeasures(
            db: db,
            arrangementPK: arrPK,
            clickSongMeasureCount: clickSongMeasureCount,
            secPerBar: secPerBar
        )
        let sections = Song.makeClickAndPadSections(
            bpm: safeBpm,
            timeSignatureNumerator: ts.num,
            timeSignatureDenominator: ts.den,
            infiniteLoop: infiniteLoop,
            measures: measures
        )
        let totalDur = sections.last?.endTime ?? 0.0

        let subdivisions = parseClickSubdivisions(from: trackSlots)
        var clickTrackVol: Float = 0.80
        var clickTrackMuted = false
        var guideTrackVol: Float = 0.80
        var guideTrackMuted = false
        for slot in trackSlots {
            if slot.isGeneratedClickSubdivision { continue }
            let lowerTitle = slot.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if slot.partId == 44 || lowerTitle == "click" {
                clickTrackVol = min(1.0, max(0.0, slot.volume * 0.80))
                clickTrackMuted = slot.isMuted
            } else if slot.partId == 51 || lowerTitle.contains("guide") {
                guideTrackVol = min(1.0, max(0.0, slot.volume * 0.80))
                guideTrackMuted = slot.isMuted
            }
        }

        let clickTrack = StemTrack(
            name: "Click",
            role: .click,
            volume: clickTrackVol,
            isMuted: clickTrackMuted,
            routing: .clickOut
        )
        clickTrack.duration = totalDur

        let guideTrack = StemTrack(
            name: "Guide",
            role: .guide,
            volume: guideTrackVol,
            isMuted: guideTrackMuted,
            routing: .guideOut
        )
        guideTrack.duration = totalDur

        let ambientPadEnabled = arrSettings?.includePad ?? false
        let musicalKey = ambientPadEnabled ? (keyMap[keyId] ?? "C") : ""
        let resolvedPadPreset: String = {
            if let padPK = arrSettings?.storedPadPK, padPK > 0, let padTitle = padTitleMap[padPK],
               let matchingPack = PadLibraryManager.shared.availablePacks.first(where: {
                   $0.name.caseInsensitiveCompare(padTitle) == .orderedSame
               }) {
                return matchingPack.id
            }
            return PadLibraryManager.shared.activePackId
        }()
        let resolvedTransition: SongTransitionType = {
            switch arrSettings?.storedTransition ?? 0 {
            case 1: return .autoLink
            case 2: return .overlap
            case 3: return .crossfade
            case 4: return .stayInSong
            default: return (arrSettings == nil && infiniteLoop) ? .stayInSong : .cueNextSong
            }
        }()
        let resolvedContinuePad = arrSettings?.transitionContinuePad ?? ambientPadEnabled

        let rawMidiCues = fetchMIDICues(db: db, songPK: songPK, sections: sections)
        let midiCues: [MIDICue] = rawMidiCues.map { cue in
            var c = cue
            c.time = min(max(0.0, cue.time), max(0.0, totalDur - 0.01))
            c.sectionId = sections.first(where: { c.time >= $0.startTime - 0.015 && c.time < $0.endTime - 0.015 })?.id
                ?? sections.last?.id
            return c
        }

        let song = Song(
            title: finalTitle,
            artist: "",
            bpm: safeBpm,
            originalBPM: safeBpm,
            timeSignatureNumerator: ts.num,
            timeSignatureDenominator: ts.den,
            musicalKey: musicalKey,
            transposeSemitones: 0,
            sections: sections,
            defaultSections: sections,
            savedArrangements: [],
            activeArrangementId: nil,
            stemURLs: [],
            midiCues: midiCues,
            proPresenterPlaylist: (ppPlaylistRaw > 0 && ppPlaylistRaw <= 127) ? ppPlaylistRaw : nil,
            proPresenterPlaylistItem: (ppItemRaw > 0 && ppItemRaw <= 127) ? ppItemRaw : nil,
            transitionType: resolvedTransition,
            continuePad: resolvedContinuePad,
            endFadeOutEnabled: arrSettings?.endFade ?? false,
            startPadWithSong: ambientPadEnabled,
            padPresetId: resolvedPadPreset,
            padIntroOutroOnly: false,
            artworkData: nil,
            clickSource: .generated,
            guideSource: .generated,
            guideVoice: GuideVoice.defaultVoice,
            clickSound: ClickSoundType.defaultSound,
            usesDefaultClickSound: true,
            usesDefaultGuideVoice: true,
            clickAccentEnabled: subdivisions.accentOn,
            clickQuarterEnabled: subdivisions.quarterOn,
            clickEighthEnabled: subdivisions.eighthOn,
            clickSixteenthEnabled: subdivisions.sixteenthOn,
            clickAccentVolume: subdivisions.accentVol,
            clickQuarterVolume: subdivisions.quarterVol,
            clickEighthVolume: subdivisions.eighthVol,
            clickSixteenthVolume: subdivisions.sixteenthVol,
            guideCountInEnabled: true,
            autoInfiniteLoop: infiniteLoop
        )

        return (song: song, tracks: [clickTrack, guideTrack], buffers: [:])
    }
    
    private struct ArrangementSettings {
        let endFade: Bool
        let includePad: Bool
        let padIntroOutroOnly: Bool
        let transitionContinuePad: Bool
        let storedTransition: Int
        let storedPadPK: Int64
    }
    
    private func buildArrangements(
        db: OpaquePointer,
        songPK: Int64,
        workingArrPK: Int64?,
        workingArrId: Int64,
        workingSections: [SongSection],
        snapshotsData: Data?,
        sectionMetaMap: [Int64: (title: String, abbr: String)],
        bpm: Double
    ) -> (defaultSections: [SongSection], savedArrangements: [SavedArrangement], activeArrangementId: UUID?) {
        // 1. Load ZSONGARRANGEMENT rows (ZID == 0 is Default; workingArrPK is the active working copy)
        var stmt: OpaquePointer?
        let sql = """
        SELECT Z_PK, COALESCE(ZID, 0), COALESCE(ZTITLE, 'Default')
        FROM ZSONGARRANGEMENT
        WHERE ZSONG = ?
        ORDER BY CASE WHEN ZID = 0 THEN 0 ELSE 1 END, Z_PK
        """
        var defaultSecsFromTable: [SongSection]? = nil
        var workingTitleFromTable: String = "Default"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, songPK)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let zid = sqlite3_column_int64(stmt, 1)
                let rawTitle = columnString(stmt, 2) ?? "Default"
                if zid == 0 && defaultSecsFromTable == nil {
                    defaultSecsFromTable = (pk == workingArrPK)
                        ? workingSections
                        : fetchSections(db: db, arrangementPK: pk, sectionMetaMap: sectionMetaMap, bpm: bpm)
                }
                if pk == workingArrPK {
                    workingTitleFromTable = rawTitle
                }
            }
        }
        sqlite3_finalize(stmt)
        
        // 2. Parse ZSTOREDARRANGEMENTSNAPSHOTS JSON for ALL saved arrangements and their real names
        var snapshotDefaultSecs: [SongSection]? = nil
        var saved: [SavedArrangement] = []
        var activeId: UUID? = nil
        var workingIsExplicitDefault = false
        
        if let data = snapshotsData,
           let snapshots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !snapshots.isEmpty {
            // Build lookup of original section durations from ZID=0 Default sections (or Default snapshot)
            var durationByAudioStart: [Int: TimeInterval] = [:]
            if let defSecs = defaultSecsFromTable {
                for sec in defSecs {
                    let key = Int((sec.baseAudioStartTime * 100.0).rounded())
                    durationByAudioStart[key] = sec.baseDuration
                }
            }
            if let defSnap = snapshots.first(where: { ($0["isDefault"] as? Bool) == true }),
               let defRawSecs = defSnap["sections"] as? [[String: Any]] {
                let defEnd = (defSnap["endTime"] as? Double) ?? 0.0
                for idx in 0..<defRawSecs.count {
                    let s = (defRawSecs[idx]["startTime"] as? Double) ?? 0.0
                    let nextS = (idx + 1 < defRawSecs.count) ? ((defRawSecs[idx + 1]["startTime"] as? Double) ?? defEnd) : defEnd
                    let dur = max(0.1, nextS - s)
                    let key = Int((s * 100.0).rounded())
                    if durationByAudioStart[key] == nil {
                        durationByAudioStart[key] = dur
                    }
                }
            }
            
            let secPerBar = (60.0 / max(20.0, bpm)) * 4.0
            for snap in snapshots {
                let snapId = (snap["id"] as? NSNumber)?.int64Value ?? 0
                let isDef = (snap["isDefault"] as? Bool) ?? false
                let snapTitle = (snap["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Default"
                let customTitle = (snap["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let parsedSections: [SongSection]
                if snapId != 0 && snapId == workingArrId && !workingSections.isEmpty {
                    parsedSections = workingSections
                } else if isDef, let defFromTable = defaultSecsFromTable, !defFromTable.isEmpty {
                    parsedSections = defFromTable
                } else if let rawSecs = snap["sections"] as? [[String: Any]] {
                    let snapEnd = (snap["endTime"] as? Double) ?? 0.0
                    var cursorTime: TimeInterval = 0.0
                    var currentMeasure = 1
                    var built: [SongSection] = []
                    for idx in 0..<rawSecs.count {
                        let raw = rawSecs[idx]
                        let partId = (raw["partID"] as? NSNumber)?.int64Value ?? 0
                        let origStart = (raw["startTime"] as? Double) ?? 0.0
                        let trimStart = max(0.0, (raw["startTimeTrimOffset"] as? Double) ?? 0.0)
                        let trimEnd = max(0.0, (raw["endTimeTrimOffset"] as? Double) ?? 0.0)
                        let key = Int((origStart * 100.0).rounded())
                        let fallbackNext = (idx + 1 < rawSecs.count) ? ((rawSecs[idx + 1]["startTime"] as? Double) ?? snapEnd) : snapEnd
                        let origDur = durationByAudioStart[key] ?? max(0.1, fallbackNext - origStart)
                        let effectiveDur = max(0.1, origDur - trimStart - trimEnd)
                        let bars = max(1, Int((effectiveDur / secPerBar).rounded()))
                        let meta = sectionMetaMap[partId]
                        let name = meta?.title ?? "Section"
                        built.append(SongSection(
                            name: name,
                            abbreviation: meta?.abbr,
                            startTime: cursorTime,
                            audioStartTime: origStart + trimStart,
                            duration: effectiveDur,
                            startMeasure: currentMeasure,
                            measureCount: bars,
                            originalAudioStartTime: origStart,
                            originalDuration: origDur,
                            leadingTrimDuration: trimStart,
                            trailingTrimDuration: trimEnd
                        ))
                        cursorTime += effectiveDur
                        currentMeasure += bars
                    }
                    parsedSections = built
                } else {
                    parsedSections = []
                }
                
                if isDef && snapTitle == "Default" && (customTitle == nil || customTitle?.isEmpty == true) {
                    if snapshotDefaultSecs == nil && !parsedSections.isEmpty {
                        snapshotDefaultSecs = parsedSections
                    }
                    if snapId == workingArrId {
                        workingIsExplicitDefault = true
                    }
                } else {
                    let displayName = (snapTitle != "Default" && !snapTitle.isEmpty)
                        ? snapTitle
                        : ((customTitle?.isEmpty == false) ? customTitle! : "Playback Arrangement")
                    let arr = SavedArrangement(name: displayName, sections: parsedSections)
                    saved.append(arr)
                    if snapId != 0 && snapId == workingArrId {
                        activeId = arr.id
                    }
                }
            }
        }
        
        let resolvedDefault = defaultSecsFromTable ?? snapshotDefaultSecs ?? workingSections
        
        // Fallback if working arrangement wasn't in snapshots and wasn't explicitly Default
        if activeId == nil && !workingIsExplicitDefault && workingArrId != 0 {
            let differs = workingSections.count != resolvedDefault.count ||
                zip(workingSections, resolvedDefault).contains {
                    $0.name != $1.name || abs($0.duration - $1.duration) >= 0.05 || $0.isTrimmed != $1.isTrimmed
                }
            if differs {
                let fallbackName = (workingTitleFromTable != "Default" && !workingTitleFromTable.isEmpty)
                    ? workingTitleFromTable
                    : "Playback Arrangement"
                let arr = SavedArrangement(name: fallbackName, sections: workingSections)
                saved.insert(arr, at: 0)
                activeId = arr.id
            }
        }
        
        return (resolvedDefault, saved, activeId)
    }
    
    private func fetchArrangementSettings(db: OpaquePointer, arrangementPK: Int64) -> ArrangementSettings? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT COALESCE(ZENDFADE, 0), COALESCE(ZINCLUDEPAD, 0),
               COALESCE(ZPADINTROOUTROONLY, 0), COALESCE(ZTRANSITIONCONTINUEPAD, 0),
               COALESCE(ZSTOREDTRANSITION, 0), COALESCE(ZSTOREDPAD, 0)
        FROM ZSONGARRANGEMENT
        WHERE Z_PK = ?
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, arrangementPK)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ArrangementSettings(
            endFade: sqlite3_column_int64(stmt, 0) != 0,
            includePad: sqlite3_column_int64(stmt, 1) != 0,
            padIntroOutroOnly: sqlite3_column_int64(stmt, 2) != 0,
            transitionContinuePad: sqlite3_column_int64(stmt, 3) != 0,
            storedTransition: Int(sqlite3_column_int64(stmt, 4)),
            storedPadPK: sqlite3_column_int64(stmt, 5)
        )
    }
    
    private func fetchSections(
        db: OpaquePointer,
        arrangementPK: Int64,
        sectionMetaMap: [Int64: (title: String, abbr: String)],
        bpm: Double
    ) -> [SongSection] {
        var sections: [SongSection] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT COALESCE(NULLIF(ZEDITEDSECTIONTYPEID, 0), ZSTOREDSECTIONTYPE, 0),
               COALESCE(ZSTARTTIMEORIGINAL, 0.0),
               COALESCE(ZENDTIMEORIGINAL, 0.0),
               COALESCE(ZSTOREDSTARTTIMETRIMOFFSET, 0.0),
               COALESCE(ZSTOREDENDTIMETRIMOFFSET, 0.0),
               COALESCE(ZSTOREDPLAYGUIDECUE, 1),
               COALESCE(ZSTOREDPLAYCOUNTIN, 1)
        FROM ZSONGSECTION
        WHERE ZARRANGEMENT = ?
        ORDER BY COALESCE(Z_FOK_ARRANGEMENT, Z_PK)
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, arrangementPK)
        
        var cursorTime: TimeInterval = 0.0
        var currentMeasure = 1
        let secPerBar = (60.0 / max(20.0, bpm)) * 4.0
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let typeId = sqlite3_column_int64(stmt, 0)
            let origStart = sqlite3_column_double(stmt, 1)
            let origEnd = sqlite3_column_double(stmt, 2)
            let trimStart = max(0.0, sqlite3_column_double(stmt, 3))
            let trimEnd = max(0.0, sqlite3_column_double(stmt, 4))
            let playGuide = sqlite3_column_int64(stmt, 5) != 0
            let playCountIn = sqlite3_column_int64(stmt, 6) != 0
            
            let origDur = max(0.1, origEnd - origStart)
            let effectiveDur = max(0.1, origDur - trimStart - trimEnd)
            let audioStart = origStart + trimStart
            let bars = max(1, Int((effectiveDur / secPerBar).rounded()))
            
            let meta = sectionMetaMap[typeId]
            let name = meta?.title ?? "Section"
            let abbr = meta?.abbr
            
            let section = SongSection(
                name: name,
                abbreviation: abbr,
                startTime: cursorTime,
                audioStartTime: audioStart,
                duration: effectiveDur,
                startMeasure: currentMeasure,
                measureCount: bars,
                originalAudioStartTime: origStart,
                originalDuration: origDur,
                leadingTrimDuration: trimStart,
                trailingTrimDuration: trimEnd,
                playSectionGuideCue: playGuide,
                playSectionCountIn: playCountIn
            )
            sections.append(section)
            cursorTime += effectiveDur
            currentMeasure += bars
        }
        return sections
    }
    
    private func fetchMIDICues(db: OpaquePointer, songPK: Int64, sections: [SongSection]) -> [MIDICue] {
        var cues: [MIDICue] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT COALESCE(ZSTOREDTYPE, 0), COALESCE(ZNOTE, 0), COALESCE(ZVELOCITY, 127),
               COALESCE(ZDISABLELOOP, 0), COALESCE(ZBUSID, 1),
               COALESCE(ZSEQUENCETIMECODE, ZSAMPLETIMECODE, 0.0),
               COALESCE(ZEVENTDESCRIPTION, '')
        FROM ZMIDIEVENT
        WHERE ZSONG = ?
        ORDER BY COALESCE(ZSEQUENCETIMECODE, ZSAMPLETIMECODE, 0.0)
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, songPK)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let storedType = Int(sqlite3_column_int64(stmt, 0))
            let note = Int(sqlite3_column_int64(stmt, 1))
            let velocity = Int(sqlite3_column_int64(stmt, 2))
            let disableLoop = sqlite3_column_int64(stmt, 3) != 0
            let busId = Int(sqlite3_column_int64(stmt, 4))
            let time = max(0.0, sqlite3_column_double(stmt, 5))
            let desc = columnString(stmt, 6) ?? ""
            
            let msgType: MIDIMessageType
            switch storedType {
            case 3: msgType = .controlChange
            case 4: msgType = .programChange
            default: msgType = .note
            }
            
            let busIndex = max(0, min(MIDIBus.allCases.count - 1, busId - 1))
            let bus = MIDIBus.allCases[busIndex]
            let sectionId = sections.first(where: { time >= $0.startTime - 0.015 && time < $0.endTime - 0.015 })?.id
                ?? sections.last(where: { time >= $0.startTime - 0.015 })?.id
            
            cues.append(MIDICue(
                time: time,
                sectionId: sectionId,
                bus: bus,
                messageType: msgType,
                primaryValue: note,
                secondaryValue: velocity,
                disableLoop: disableLoop,
                cueDescription: desc
            ))
        }
        return cues
    }
    
    private func fetchAutomationCues(
        db: OpaquePointer,
        arrangementPK: Int64,
        sections: [SongSection],
        trackMap: [String: UUID],
        trackOrderMap: [Int: UUID]
    ) -> [AutomationPoint] {
        var points: [AutomationPoint] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT c.Z_PK, COALESCE(c.ZNAME, 'Automation'), COALESCE(c.ZDETAILS, ''),
               COALESCE(c.ZTRANSITIONBEATS, 0),
               COALESCE(c.ZSTOREDSEQUENCETIMECODE, c.ZSTOREDSAMPLETIMECODE, 0.0)
        FROM ZAUTOMATIONCUE c
        JOIN ZSONGSECTION s ON c.ZSONGSECTION = s.Z_PK
        WHERE s.ZARRANGEMENT = ?
        ORDER BY COALESCE(c.ZSTOREDSEQUENCETIMECODE, c.ZSTOREDSAMPLETIMECODE, 0.0)
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, arrangementPK)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cuePK = sqlite3_column_int64(stmt, 0)
            let name = columnString(stmt, 1) ?? "Automation"
            let details = columnString(stmt, 2) ?? ""
            let beats = Int(sqlite3_column_int64(stmt, 3))
            let time = max(0.0, sqlite3_column_double(stmt, 4))
            let sectionId = sections.first(where: { time >= $0.startTime - 0.015 && time < $0.endTime - 0.015 })?.id
                ?? sections.last(where: { time >= $0.startTime - 0.015 })?.id
            
            var trackFaders: [UUID: Float] = [:]
            var trackMutes: [UUID: Bool] = [:]
            var busFaders: [String: Float] = [:]
            var busMutes: [String: Bool] = [:]
            var midiMuted: Bool? = nil
            var itemStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT ZAUTOMATIONID, ZSTOREDVALUE FROM ZAUTOMATIONITEM WHERE ZCUE = ?", -1, &itemStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(itemStmt, 1, cuePK)
                while sqlite3_step(itemStmt) == SQLITE_ROW {
                    if let autoId = columnString(itemStmt, 0) {
                        let val = Float(sqlite3_column_double(itemStmt, 1))
                        if autoId.hasPrefix("TrackMute_SongTrack_"),
                           let orderNum = Int(autoId.replacingOccurrences(of: "TrackMute_SongTrack_", with: "")),
                           let trackID = trackOrderMap[orderNum] {
                            trackMutes[trackID] = val >= 0.5
                        } else if autoId.hasPrefix("TrackVolume_SongTrack_"),
                                  let orderNum = Int(autoId.replacingOccurrences(of: "TrackVolume_SongTrack_", with: "")),
                                  let trackID = trackOrderMap[orderNum] {
                            trackFaders[trackID] = min(1.0, max(0.0, val * 0.80))
                        } else if autoId.hasPrefix("TrackMute_Bus_"),
                                  let busNum = Int(autoId.replacingOccurrences(of: "TrackMute_Bus_", with: "")),
                                  let busName = Self.playbackBusName(for: busNum) {
                            busMutes[busName] = val >= 0.5
                        } else if autoId.hasPrefix("TrackVolume_Bus_"),
                                  let busNum = Int(autoId.replacingOccurrences(of: "TrackVolume_Bus_", with: "")),
                                  let busName = Self.playbackBusName(for: busNum) {
                            busFaders[busName] = min(1.0, max(0.0, val * 0.80))
                        } else if autoId == "MixerMuteMIDIButton" {
                            midiMuted = val >= 0.5
                        } else if let trackID = trackMap[autoId] {
                            trackFaders[trackID] = min(1.0, max(0.0, val * 0.80))
                        }
                    }
                }
            }
            sqlite3_finalize(itemStmt)
            
            points.append(AutomationPoint(
                time: time,
                name: name,
                transitionBeats: beats,
                descriptionText: details,
                sectionId: sectionId,
                trackFaders: trackFaders,
                trackMutes: trackMutes,
                busFaders: busFaders,
                busMutes: busMutes,
                midiMuted: midiMuted
            ))
        }
        return points
    }
    
    private static func playbackBusName(for busId: Int) -> String? {
        switch busId {
        case 1: return "Click"
        case 2: return "Drums"
        case 3: return "Loops"
        case 4: return "Bass"
        case 5: return "Piano"
        case 6: return "Keys"
        case 7: return "Electric Guitars"
        case 8: return "Acoustic Guitars"
        case 9: return "Vocals"
        case 10: return "Aux"
        case 11: return "Pad"
        case 13: return "Strings"
        case 14: return "Horns"
        case 15: return "FX"
        case 16: return "Guide"
        case 18: return "Percussion"
        default: return nil
        }
    }
    
    private func computeSemitoneDelta(from originalKey: String, to targetKey: String) -> Int {
        guard originalKey != targetKey else { return 0 }
        let list = MusicalKeyHelper.chromaticKeys
        let sharpList = MusicalKeyHelper.chromaticSharpKeys
        func indexOf(_ key: String) -> Int? {
            let root = key.lowercased().hasSuffix("m") ? String(key.dropLast()) : key
            return list.firstIndex(where: { $0.caseInsensitiveCompare(root) == .orderedSame })
                ?? sharpList.firstIndex(where: { $0.caseInsensitiveCompare(root) == .orderedSame })
        }
        guard let i1 = indexOf(originalKey), let i2 = indexOf(targetKey) else { return 0 }
        var diff = i2 - i1
        if diff > 6 { diff -= 12 }
        if diff < -6 { diff += 12 }
        return diff
    }
    
    // MARK: - Tempo & Time Signature Parsing
    
    private struct PlaybackTimeSigEntry {
        let time: TimeInterval
        let numerator: Int
        let denominator: Int
    }
    
    private struct PlaybackTempoEntry {
        let time: TimeInterval
        let bpm: Double
    }
    
    private func parseTimeCodeSeconds(_ timeCode: String) -> TimeInterval? {
        let parts = timeCode.split(separator: ":")
        guard parts.count == 3,
              let mins = Double(parts[0]),
              let secs = Double(parts[1]),
              let millis = Double(parts[2]) else { return nil }
        return mins * 60.0 + secs + (millis / 1000.0)
    }
    
    private func parseTimeSignaturesJSON(_ data: Data?) -> [PlaybackTimeSigEntry] {
        guard let data = data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var entries: [PlaybackTimeSigEntry] = []
        for item in array {
            guard let num = item["beatsPerBar"] as? Int,
                  let den = item["beatUnit"] as? Int else { continue }
            let tc = (item["timeCode"] as? String) ?? "00:00:000"
            let t = parseTimeCodeSeconds(tc) ?? 0.0
            entries.append(PlaybackTimeSigEntry(time: t, numerator: max(1, num), denominator: max(1, den)))
        }
        return entries.sorted { $0.time < $1.time }
    }
    
    private func fetchTempoPoints(db: OpaquePointer, songPK: Int64) -> [PlaybackTempoEntry] {
        var points: [PlaybackTempoEntry] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT COALESCE(ZSTOREDTIMECODE, 0.0), COALESCE(ZSTOREDBPM, 120.0)
        FROM ZSONGTEMPO
        WHERE ZSONG = ?
        ORDER BY COALESCE(ZSTOREDTIMECODE, 0.0), COALESCE(Z_FOK_SONG, Z_PK)
        """
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, songPK)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let t = max(0.0, sqlite3_column_double(stmt, 0))
            let b = sqlite3_column_double(stmt, 1)
            if b > 0 {
                // If two points share the exact same timestamp, the later Z_FOK_SONG value takes effect from that time forward
                if let last = points.last, abs(last.time - t) < 0.0005 {
                    points[points.count - 1] = PlaybackTempoEntry(time: t, bpm: b)
                } else {
                    points.append(PlaybackTempoEntry(time: t, bpm: b))
                }
            }
        }
        return points
    }
    
    private func fetchSongClickTimestamps(db: OpaquePointer, songPK: Int64) -> (accents: [TimeInterval], quarters: [TimeInterval]) {
        let query = "SELECT ZSTOREDACCENTS, ZSTOREDQUARTERS FROM ZSONGCLICKS WHERE ZSONG = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return ([], []) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, songPK)
        
        func decodeBlob(_ col: Int32) -> [TimeInterval] {
            guard let ptr = sqlite3_column_blob(stmt, col) else { return [] }
            let len = Int(sqlite3_column_bytes(stmt, col))
            guard len > 0 else { return [] }
            let data = Data(bytes: ptr, count: len)
            guard let numbers = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSNumber.self], from: data) as? [NSNumber] else {
                return []
            }
            return numbers.map { max(0.0, $0.doubleValue) }
        }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (decodeBlob(0), decodeBlob(1))
        }
        return ([], [])
    }
    
    private func buildBeatGrid(
        totalDuration: TimeInterval,
        baseBPM: Double,
        tempoPoints: [PlaybackTempoEntry],
        timeSignatures: [PlaybackTimeSigEntry],
        clickAccents: [TimeInterval] = [],
        clickQuarters: [TimeInterval] = []
    ) -> [BeatGridMarker] {
        let hasTempoChanges = tempoPoints.count > 1
        let hasMeterChanges = timeSignatures.count > 1
        guard (hasTempoChanges || hasMeterChanges), totalDuration > 0.1 else {
            return []
        }
        
        if !clickQuarters.isEmpty {
            var markers: [BeatGridMarker] = []
            var bar = 0
            var beat = 1
            var accentIdx = 0
            var tempoIdx = 0
            var currentBPM = tempoPoints.first?.bpm ?? baseBPM
            var prevTime: TimeInterval = -1.0
            
            for qt in clickQuarters {
                guard qt < totalDuration - 0.01 else { break }
                if prevTime >= 0 && qt - prevTime < 0.05 { continue }
                prevTime = qt
                
                while tempoIdx + 1 < tempoPoints.count && qt + 0.02 >= tempoPoints[tempoIdx + 1].time {
                    tempoIdx += 1
                    currentBPM = tempoPoints[tempoIdx].bpm
                }
                
                while accentIdx < clickAccents.count && clickAccents[accentIdx] < qt - 0.03 {
                    accentIdx += 1
                }
                
                let isDownbeat = accentIdx < clickAccents.count && abs(clickAccents[accentIdx] - qt) <= 0.03
                if isDownbeat {
                    bar += 1
                    beat = 1
                    accentIdx += 1
                } else if bar == 0 {
                    bar = 1
                    beat = 1
                } else {
                    beat += 1
                }
                
                markers.append(BeatGridMarker(
                    time: qt,
                    bar: bar,
                    beat: beat,
                    instantaneousBPM: currentBPM
                ))
            }
            
            if !markers.isEmpty {
                return markers
            }
        }
        
        var markers: [BeatGridMarker] = []
        var t: TimeInterval = 0.0
        var bar = 1
        var beat = 1
        var tsIdx = 0
        var tempoIdx = 0
        
        var currentNum = timeSignatures.first?.numerator ?? 4
        var currentDen = timeSignatures.first?.denominator ?? 4
        var currentBPM = tempoPoints.first?.bpm ?? baseBPM
        
        while t < totalDuration - 0.01 && markers.count < 8000 {
            // Advance time signature if we've reached the next meter change
            while tsIdx + 1 < timeSignatures.count && t + 0.01 >= timeSignatures[tsIdx + 1].time {
                tsIdx += 1
                currentNum = timeSignatures[tsIdx].numerator
                currentDen = timeSignatures[tsIdx].denominator
                if beat != 1 {
                    bar += 1
                    beat = 1
                }
            }
            
            // Advance tempo if we've reached the next tempo point
            while tempoIdx + 1 < tempoPoints.count && t + 0.005 >= tempoPoints[tempoIdx + 1].time {
                tempoIdx += 1
                currentBPM = tempoPoints[tempoIdx].bpm
            }
            
            markers.append(BeatGridMarker(
                time: t,
                bar: bar,
                beat: beat,
                instantaneousBPM: currentBPM
            ))
            
            let beatDur = (60.0 / max(20.0, currentBPM)) * (4.0 / Double(max(1, currentDen)))
            t += beatDur
            beat += 1
            if beat > currentNum {
                beat = 1
                bar += 1
            }
        }
        
        return markers
    }
}
