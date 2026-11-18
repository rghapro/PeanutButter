import Foundation
import AppKit

// MARK: - Library Source & Item Models

public enum LibrarySource: String, Codable, Sendable, CaseIterable {
    case local = "Local"
    case cloud = "Cloud"
}

public enum LibrarySourceFilter: String, CaseIterable, Sendable {
    case all = "All"
    case local = "Local"
    case cloud = "Cloud"
}

public struct SongLibraryItem: Identifiable {
    public let id: URL
    public let url: URL
    public let title: String
    public let artist: String
    public let bpm: Double
    public let musicalKey: String
    public let duration: TimeInterval
    public let artwork: NSImage?
    public let modifiedDate: Date
    public let source: LibrarySource
    public let isDownloaded: Bool

    public var formattedDuration: String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct SetlistSongPreview: Identifiable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let bpm: Double
    public let musicalKey: String
    public let timeSignature: String
    public let duration: TimeInterval
    public let artwork: NSImage?
    public let isDownloaded: Bool

    public var formattedDuration: String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct SetlistLibraryItem: Identifiable {
    public let id: URL
    public let url: URL
    public let name: String
    public let songCount: Int
    public let formattedDate: String
    public let formattedDuration: String
    public let artworks: [NSImage]
    public let modifiedDate: Date
    public let source: LibrarySource
    public let isDownloaded: Bool
    public let hasCloudUpdate: Bool
    public let changeDescription: String?
    public let hasUnresolvedServerUpdate: Bool
    public let lastSavedRevisionId: UUID?
    public let lastSavedByDeviceId: String?

    public init(
        id: URL,
        url: URL,
        name: String,
        songCount: Int,
        formattedDate: String,
        formattedDuration: String,
        artworks: [NSImage],
        modifiedDate: Date,
        source: LibrarySource,
        isDownloaded: Bool,
        hasCloudUpdate: Bool,
        changeDescription: String? = nil,
        hasUnresolvedServerUpdate: Bool = false,
        lastSavedRevisionId: UUID? = nil,
        lastSavedByDeviceId: String? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.songCount = songCount
        self.formattedDate = formattedDate
        self.formattedDuration = formattedDuration
        self.artworks = artworks
        self.modifiedDate = modifiedDate
        self.source = source
        self.isDownloaded = isDownloaded
        self.hasCloudUpdate = hasCloudUpdate
        self.changeDescription = changeDescription
        self.hasUnresolvedServerUpdate = hasUnresolvedServerUpdate
        self.lastSavedRevisionId = lastSavedRevisionId
        self.lastSavedByDeviceId = lastSavedByDeviceId
    }
}

// MARK: - Library Browser Manager (5.2 In-App Song & Setlist Browser + BYOC Cloud Sync)

/// Scans and manages both Local (`~/Library/Application Support/PeanutButter/`) and optional user-selected Cloud
/// (`Songs/`, `Setlists/`, `Stems/`, `Pads/`) libraries without loading audio stems.
@MainActor
public final class LibraryBrowserManager: ObservableObject {
    public static let shared = LibraryBrowserManager()

    private nonisolated static let cloudPathDefaultsKey = "Playback_CloudLibraryPath"
    private nonisolated static let cloudBookmarkDefaultsKey = "Playback_CloudLibraryBookmark"

    @Published public private(set) var songs: [SongLibraryItem] = []
    @Published public private(set) var setlists: [SetlistLibraryItem] = []
    @Published public private(set) var isScanningSongs: Bool = false
    @Published public private(set) var isScanningSetlists: Bool = false
    @Published public private(set) var cloudRootURL: URL? = nil

    private var activeSecurityScopedCloudURL: URL? = nil
    private var cloudSongsWatcher: DispatchSourceFileSystemObject?
    private var cloudSetlistsWatcher: DispatchSourceFileSystemObject?
    private var watcherDebounceWorkItem: DispatchWorkItem?
    private var cloudSetlistPollTimer: Timer?
    private var isPlaybackActive: Bool = false
    private var needsDeferredSetlistRefresh: Bool = false

    private final class SetlistPackageCache: @unchecked Sendable {
        struct Entry {
            let modDate: Date
            let isDownloaded: Bool
            let hasCloudUpdate: Bool
            let source: LibrarySource
            let item: SetlistLibraryItem
        }

        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]

        func get(url: URL, modDate: Date, isDownloaded: Bool, hasCloudUpdate: Bool, source: LibrarySource) -> SetlistLibraryItem? {
            let key = url.standardizedFileURL
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            guard entry.modDate == modDate,
                  entry.isDownloaded == isDownloaded,
                  entry.hasCloudUpdate == hasCloudUpdate,
                  entry.source == source else {
                return nil
            }
            // If a cloud setlist previously had undownloaded stems while its root was present, allow re-checking stem status.
            if source == .cloud && isDownloaded && !entry.item.isDownloaded {
                return nil
            }
            return entry.item
        }

        func set(url: URL, modDate: Date, isDownloaded: Bool, hasCloudUpdate: Bool, source: LibrarySource, item: SetlistLibraryItem) {
            let key = url.standardizedFileURL
            lock.lock()
            defer { lock.unlock() }
            if entries.count > 200 {
                entries.removeAll()
            }
            entries[key] = Entry(
                modDate: modDate,
                isDownloaded: isDownloaded,
                hasCloudUpdate: hasCloudUpdate,
                source: source,
                item: item
            )
        }

        func invalidate(url: URL) {
            let key = url.standardizedFileURL
            lock.lock()
            entries.removeValue(forKey: key)
            lock.unlock()
        }

        func invalidateAll() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }
    }

    private nonisolated static let setlistPackageCache = SetlistPackageCache()

    public nonisolated static func invalidateSetlistPackageCache(for url: URL? = nil) {
        if let url = url {
            setlistPackageCache.invalidate(url: url)
        } else {
            setlistPackageCache.invalidateAll()
        }
    }

    public var isCloudConnected: Bool { cloudRootURL != nil }

    public nonisolated var songsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("PeanutButter/Songs", isDirectory: true)
    }

    public nonisolated var setlistsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("PeanutButter/Setlists", isDirectory: true)
    }

    public nonisolated static var cloudRootDirectoryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: cloudPathDefaultsKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public nonisolated static var cloudStemsDirectoryURL: URL? {
        cloudRootDirectoryURL?.appendingPathComponent("Stems", isDirectory: true)
    }

    public nonisolated static var cloudPadsDirectoryURL: URL? {
        cloudRootDirectoryURL?.appendingPathComponent("Pads", isDirectory: true)
    }

    public nonisolated static var cloudClicksDirectoryURL: URL? {
        cloudRootDirectoryURL?.appendingPathComponent("ClickSamples", isDirectory: true)
    }

    public nonisolated static var cloudGuidesDirectoryURL: URL? {
        cloudRootDirectoryURL?.appendingPathComponent("GuideSamples", isDirectory: true)
    }

    public nonisolated static func isURLInCloudLibrary(_ url: URL) -> Bool {
        guard let root = cloudRootDirectoryURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    /// Returns `true` if `url` resides inside the connected Cloud Library, macOS `~/Library/CloudStorage/`
    /// (Google Drive, OneDrive, Dropbox, Box), iCloud Drive (`Mobile Documents`), or is a ubiquitous item.
    public nonisolated static func isCloudStorageURL(_ url: URL) -> Bool {
        if isURLInCloudLibrary(url) { return true }
        let path = url.standardizedFileURL.path
        if path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/") {
            return true
        }
        if let vals = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           vals.isUbiquitousItem == true {
            return true
        }
        return false
    }

    public nonisolated var cloudRootDirectory: URL? {
        Self.cloudRootDirectoryURL
    }

    public nonisolated var cloudSongsDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("Songs", isDirectory: true)
    }

    public nonisolated var cloudSetlistsDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("Setlists", isDirectory: true)
    }

    public nonisolated var cloudStemsDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("Stems", isDirectory: true)
    }

    public nonisolated var cloudPadsDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("Pads", isDirectory: true)
    }

    public nonisolated var cloudClicksDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("ClickSamples", isDirectory: true)
    }

    public nonisolated var cloudGuidesDirectory: URL? {
        cloudRootDirectory?.appendingPathComponent("GuideSamples", isDirectory: true)
    }

    private init() {
        ensureDefaultDirectoriesExist()
        migrateLegacyMusicLibraryIfNeeded()
        restoreCloudLibraryFolder()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      !self.isPlaybackActive,
                      self.needsDeferredSetlistRefresh,
                      self.isCloudConnected,
                      !self.isScanningSetlists else { return }
                self.needsDeferredSetlistRefresh = false
                self.refreshSetlists()
            }
        }
    }

    public func setPlaybackActive(_ active: Bool) {
        isPlaybackActive = active
        if !active && needsDeferredSetlistRefresh && isCloudConnected && !isScanningSetlists {
            needsDeferredSetlistRefresh = false
            refreshSetlists()
        }
    }

    private nonisolated func migrateLegacyMusicLibraryIfNeeded() {
        let fm = FileManager.default
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let legacyRoot = music.appendingPathComponent("PeanutButter", isDirectory: true)
        guard fm.fileExists(atPath: legacyRoot.path) else { return }
        
        let pairs: [(URL, URL)] = [
            (legacyRoot.appendingPathComponent("Songs", isDirectory: true), songsDirectory),
            (legacyRoot.appendingPathComponent("Setlists", isDirectory: true), setlistsDirectory)
        ]
        for (srcDir, dstDir) in pairs where fm.fileExists(atPath: srcDir.path) {
            guard let items = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let dstItem = dstDir.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dstItem.path) {
                    try? fm.moveItem(at: item, to: dstItem)
                }
            }
        }
    }

    public nonisolated func ensureDefaultDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: songsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: setlistsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cloud Library Configuration & Watchers

    private func restoreCloudLibraryFolder() {
        let fm = FileManager.default
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.cloudBookmarkDefaultsKey) {
            var isStale = false
            if let resolved = (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) {
                _ = resolved.startAccessingSecurityScopedResource()
                activeSecurityScopedCloudURL = resolved
                UserDefaults.standard.set(resolved.path, forKey: Self.cloudPathDefaultsKey)
                cloudRootURL = resolved
                ensureCloudSubdirectoriesExist(at: resolved)
                startCloudWatchers()
                PlaybackFileManager.shared.migrateLegacyCloudStemsInBackground()
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.cloudPathDefaultsKey),
           !path.isEmpty,
           fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            cloudRootURL = url
            ensureCloudSubdirectoriesExist(at: url)
            startCloudWatchers()
            PlaybackFileManager.shared.migrateLegacyCloudStemsInBackground()
        }
    }

    public func setCloudLibraryFolder(_ url: URL) {
        stopCloudWatchers()
        activeSecurityScopedCloudURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedCloudURL = nil

        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedCloudURL = url
        }

        if let bookmark = (try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) {
            UserDefaults.standard.set(bookmark, forKey: Self.cloudBookmarkDefaultsKey)
        }
        UserDefaults.standard.set(url.path, forKey: Self.cloudPathDefaultsKey)
        cloudRootURL = url
        ensureCloudSubdirectoriesExist(at: url)
        startCloudWatchers()
        PlaybackFileManager.shared.migrateLegacyCloudStemsInBackground()
        refreshSongs()
        refreshSetlists()
        PadLibraryManager.shared.reloadPacks()
    }

    public func disconnectCloudLibrary() {
        stopCloudWatchers()
        activeSecurityScopedCloudURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedCloudURL = nil
        UserDefaults.standard.removeObject(forKey: Self.cloudBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.cloudPathDefaultsKey)
        cloudRootURL = nil
        refreshSongs()
        refreshSetlists()
        PadLibraryManager.shared.reloadPacks()
    }

    private func ensureCloudSubdirectoriesExist(at root: URL) {
        let fm = FileManager.default
        for sub in ["Songs", "Setlists", "Stems", "Pads"] {
            try? fm.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    public nonisolated func isURLInCloudLibrary(_ url: URL) -> Bool {
        Self.isURLInCloudLibrary(url)
    }

    private func startCloudWatchers() {
        stopCloudWatchers()
        if let songsDir = cloudSongsDirectory {
            cloudSongsWatcher = makeWatcher(for: songsDir)
        }
        if let setlistsDir = cloudSetlistsDirectory {
            cloudSetlistsWatcher = makeWatcher(for: setlistsDir)
            // Also poll periodically because DispatchSource on the parent folder does not fire
            // when iCloud Drive updates `session.json` inside an existing `.pbsession` directory.
            cloudSetlistPollTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isCloudConnected, !self.isScanningSetlists else { return }
                    if self.isPlaybackActive || !NSApp.isActive {
                        self.needsDeferredSetlistRefresh = true
                        return
                    }
                    self.needsDeferredSetlistRefresh = false
                    self.refreshSetlists()
                }
            }
        }
    }

    private func stopCloudWatchers() {
        cloudSongsWatcher?.cancel()
        cloudSongsWatcher = nil
        cloudSetlistsWatcher?.cancel()
        cloudSetlistsWatcher = nil
        watcherDebounceWorkItem?.cancel()
        watcherDebounceWorkItem = nil
        cloudSetlistPollTimer?.invalidate()
        cloudSetlistPollTimer = nil
    }

    private func makeWatcher(for directory: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleCloudRefresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func scheduleCloudRefresh() {
        watcherDebounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshSongs()
            self?.refreshSetlists()
            PadLibraryManager.shared.reloadPacks()
        }
        watcherDebounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
    }

    // MARK: - Refresh Local + Cloud Libraries

    public func refreshSongs() {
        ensureDefaultDirectoriesExist()
        isScanningSongs = true
        let localDir = songsDirectory
        let cloudDir = cloudSongsDirectory

        Task.detached(priority: .userInitiated) {
            var combined = Self.scanSongsSync(in: localDir, source: .local)
            if let cDir = cloudDir {
                combined.append(contentsOf: Self.scanSongsSync(in: cDir, source: .cloud))
            }
            combined.sort {
                let cmp = $0.title.localizedCaseInsensitiveCompare($1.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.source == .local && $1.source == .cloud
            }
            let finalItems = combined
            await MainActor.run {
                self.songs = finalItems
                self.isScanningSongs = false
            }
        }
    }

    public func refreshSetlists() {
        ensureDefaultDirectoriesExist()
        isScanningSetlists = true
        let localDir = setlistsDirectory
        let cloudDir = cloudSetlistsDirectory

        Task.detached(priority: .userInitiated) {
            let localItems = Self.scanSetlistsSync(in: localDir, source: .local)
            var localModByKey: [String: Date] = [:]
            var localRevByKey: [String: UUID] = [:]
            for local in localItems {
                let key = Self.sanitizedPackageFilename(local.name, ext: "pbsession").lowercased()
                let prevMod = localModByKey[key] ?? .distantPast
                if local.modifiedDate >= prevMod {
                    localModByKey[key] = local.modifiedDate
                    if let rev = local.lastSavedRevisionId {
                        localRevByKey[key] = rev
                    }
                }
            }

            let currentDeviceId = PlaybackFileManager.currentDeviceInstanceId
            var combined = localItems
            if let cDir = cloudDir {
                let cloudItems = Self.scanSetlistsSync(in: cDir, source: .cloud).map { item -> SetlistLibraryItem in
                    let key = Self.sanitizedPackageFilename(item.name, ext: "pbsession").lowercased()
                    let isSelfAuthored = (item.lastSavedByDeviceId != nil && item.lastSavedByDeviceId == currentDeviceId) && !item.hasUnresolvedServerUpdate
                    let isNewerThanLocal: Bool = {
                        guard !isSelfAuthored, let localMod = localModByKey[key] else { return false }
                        if let cRev = item.lastSavedRevisionId, let lRev = localRevByKey[key] {
                            return (cRev != lRev) && (item.modifiedDate > localMod)
                        }
                        return item.modifiedDate.timeIntervalSince(localMod) > 2.0
                    }()
                    let resolvedHasUpdate = item.hasUnresolvedServerUpdate || isNewerThanLocal
                    if resolvedHasUpdate != item.hasCloudUpdate {
                        return SetlistLibraryItem(
                            id: item.id,
                            url: item.url,
                            name: item.name,
                            songCount: item.songCount,
                            formattedDate: item.formattedDate,
                            formattedDuration: item.formattedDuration,
                            artworks: item.artworks,
                            modifiedDate: item.modifiedDate,
                            source: item.source,
                            isDownloaded: item.isDownloaded,
                            hasCloudUpdate: resolvedHasUpdate,
                            changeDescription: item.changeDescription,
                            hasUnresolvedServerUpdate: item.hasUnresolvedServerUpdate,
                            lastSavedRevisionId: item.lastSavedRevisionId,
                            lastSavedByDeviceId: item.lastSavedByDeviceId
                        )
                    }
                    return item
                }
                combined.append(contentsOf: cloudItems)
            }
            combined.sort { $0.modifiedDate > $1.modifiedDate }
            let finalItems = combined
            await MainActor.run {
                self.setlists = finalItems
                self.isScanningSetlists = false
            }
        }
    }

    /// Immediately clears cloud-update indicators on matching in-memory setlist items after a local or cloud save on this Mac.
    public func markSetlistSavedOnThisDevice(urls: [URL], setlistName: String, revisionId: UUID) {
        if urls.isEmpty {
            Self.invalidateSetlistPackageCache(for: nil)
        } else {
            for u in urls {
                Self.invalidateSetlistPackageCache(for: u)
            }
        }
        let targetStdPaths = Set(urls.map { $0.standardizedFileURL.path })
        let targetFileName = Self.sanitizedPackageFilename(setlistName, ext: "pbsession").lowercased()
        let deviceId = PlaybackFileManager.currentDeviceInstanceId
        let now = Date()
        var didModify = false
        var updated = setlists
        for idx in updated.indices {
            let item = updated[idx]
            let matchesURL = targetStdPaths.contains(item.url.standardizedFileURL.path)
            let matchesName = !targetFileName.isEmpty && (
                Self.sanitizedPackageFilename(item.name, ext: "pbsession").lowercased() == targetFileName
                    || item.url.lastPathComponent.lowercased() == targetFileName
            )
            if matchesURL || matchesName {
                updated[idx] = SetlistLibraryItem(
                    id: item.id,
                    url: item.url,
                    name: item.name,
                    songCount: item.songCount,
                    formattedDate: item.formattedDate,
                    formattedDuration: item.formattedDuration,
                    artworks: item.artworks,
                    modifiedDate: matchesURL ? max(item.modifiedDate, now) : item.modifiedDate,
                    source: item.source,
                    isDownloaded: matchesURL ? true : item.isDownloaded,
                    hasCloudUpdate: false,
                    changeDescription: item.changeDescription,
                    hasUnresolvedServerUpdate: false,
                    lastSavedRevisionId: matchesURL ? revisionId : item.lastSavedRevisionId,
                    lastSavedByDeviceId: matchesURL ? deviceId : item.lastSavedByDeviceId
                )
                didModify = true
            }
        }
        if didModify {
            setlists = updated
        }
    }

    /// Evicts all downloaded Cloud Library content from this device (iCloud ubiquitous items across
    /// Setlists, Songs, Stems, Pads, Clicks, Guides) and clears local downloaded caches (StemCache
    /// and AutoSaveSession), while leaving saved local library files and cloud-stored files intact.
    public func deleteAllCloudSetlistsFromDevice() {
        let cloudDirs = [
            cloudSetlistsDirectory,
            cloudSongsDirectory,
            cloudStemsDirectory,
            cloudPadsDirectory,
            cloudClicksDirectory,
            cloudGuidesDirectory
        ].compactMap { $0 }
        let stemCacheDir = PlaybackFileManager.shared.stemCacheDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default

            // 1. Instant StemCache swap: move aside and recreate empty cache dir, then delete old folder in background
            var trashCacheURL: URL? = nil
            if fm.fileExists(atPath: stemCacheDir.path) {
                let trashURL = stemCacheDir.deletingLastPathComponent()
                    .appendingPathComponent("StemCache_trash_\(UUID().uuidString)", isDirectory: true)
                if (try? fm.moveItem(at: stemCacheDir, to: trashURL)) != nil {
                    try? fm.createDirectory(at: stemCacheDir, withIntermediateDirectories: true)
                    trashCacheURL = trashURL
                } else if let cachedItems = try? fm.contentsOfDirectory(at: stemCacheDir, includingPropertiesForKeys: nil) {
                    for url in cachedItems {
                        try? fm.removeItem(at: url)
                    }
                }
            }

            // 2. Clear AutoSaveSession.pbsession (unsaved local session changes on device)
            if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let autoSaveURL = appSupport.appendingPathComponent("PeanutButter/AutoSaveSession.pbsession")
                if fm.fileExists(atPath: autoSaveURL.path) {
                    try? fm.removeItem(at: autoSaveURL)
                }
            }

            // 3. Collect only downloaded, non-directory ubiquitous files (skip .notDownloaded & .icloud placeholders)
            let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
            var urlsToEvict: [URL] = []

            for dir in cloudDirs {
                guard let contents = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for itemURL in contents {
                    let itemVals = try? itemURL.resourceValues(forKeys: keys)
                    let isUbiquitous = itemVals?.isUbiquitousItem ?? fm.isUbiquitousItem(at: itemURL)
                    guard isUbiquitous else { continue }

                    if itemVals?.isDirectory == true {
                        if let enumerator = fm.enumerator(at: itemURL, includingPropertiesForKeys: Array(keys)) {
                            for case let child as URL in enumerator {
                                let name = child.lastPathComponent
                                if name.hasPrefix(".") && name.hasSuffix(".icloud") { continue }
                                // Keep lightweight metadata & artwork files locally so the built-in browser
                                // continues showing all Cloud Songs & Cloud Setlists with titles, keys, and art.
                                let ext = child.pathExtension.lowercased()
                                if ext == "json" || ext == "png" || ext == "jpg" || ext == "jpeg" { continue }
                                let childVals = try? child.resourceValues(forKeys: keys)
                                if childVals?.isDirectory == true { continue }
                                if childVals?.ubiquitousItemDownloadingStatus == .notDownloaded { continue }
                                urlsToEvict.append(child)
                            }
                        }
                    } else if itemVals?.ubiquitousItemDownloadingStatus != .notDownloaded {
                        let ext = itemURL.pathExtension.lowercased()
                        if ext != "json" && ext != "png" && ext != "jpg" && ext != "jpeg" {
                            urlsToEvict.append(itemURL)
                        }
                    }
                }
            }

            // 4. Evict downloaded ubiquitous files concurrently off the main thread
            if !urlsToEvict.isEmpty {
                DispatchQueue.concurrentPerform(iterations: urlsToEvict.count) { idx in
                    try? FileManager.default.evictUbiquitousItem(at: urlsToEvict[idx])
                }
            }

            if let trashURL = trashCacheURL {
                try? fm.removeItem(at: trashURL)
            }

            await MainActor.run {
                self?.refreshSetlists()
                self?.refreshSongs()
            }
        }
    }

    /// Fires `startDownloadingUbiquitousItem` without blocking so iCloud Drive can pipeline downloads.
    public nonisolated static func triggerCloudDownload(at packageURL: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: packageURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: packageURL, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) {
                    for case let child as URL in enumerator {
                        if child.lastPathComponent.hasPrefix(".") && child.pathExtension == "icloud" {
                            try? fm.startDownloadingUbiquitousItem(at: child)
                        } else if let vals = try? child.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                                  vals.ubiquitousItemDownloadingStatus == .notDownloaded || vals.ubiquitousItemDownloadingStatus == .downloaded {
                            try? fm.startDownloadingUbiquitousItem(at: child)
                        }
                    }
                }
            } else {
                if let vals = try? packageURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   vals.ubiquitousItemDownloadingStatus == .notDownloaded || vals.ubiquitousItemDownloadingStatus == .downloaded {
                    try? fm.startDownloadingUbiquitousItem(at: packageURL)
                } else if fm.isUbiquitousItem(at: packageURL) {
                    try? fm.startDownloadingUbiquitousItem(at: packageURL)
                }
            }
        } else {
            let placeholder = packageURL.deletingLastPathComponent()
                .appendingPathComponent(".\(packageURL.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: placeholder)
            } else {
                try? fm.startDownloadingUbiquitousItem(at: packageURL)
            }
        }
    }

    /// Triggers iCloud Drive / Google Drive / FileProvider download for any evicted `.icloud` placeholder
    /// files or dataless files inside `packageURL` (or for `packageURL` itself) and waits for local availability.
    /// Resets the timeout window whenever `fileAllocatedSize` increases so active transfers never time out mid-stream.
    public nonisolated static func ensureCloudItemDownloaded(at packageURL: URL, timeout: TimeInterval = 60.0, isCancelled: (() -> Bool)? = nil, progressHandler: ((Double) -> Void)? = nil) {
        let fm = FileManager.default
        let placeholder = packageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(packageURL.lastPathComponent).icloud")
        let hasFile = fm.fileExists(atPath: packageURL.path)
        let hasPlaceholder = fm.fileExists(atPath: placeholder.path)
        // If neither the file nor an .icloud placeholder exists, there is nothing to download — return immediately.
        guard hasFile || hasPlaceholder else { return }
        if checkIsDownloaded(at: packageURL) {
            progressHandler?(1.0)
            return
        }

        triggerCloudDownload(at: packageURL)

        var deadline = Date().addingTimeInterval(timeout)
        var lastRetrigger = Date()
        let initialVals = try? packageURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        var lastAllocated: Int = initialVals?.fileAllocatedSize ?? 0
        var lastReportedFrac: Double = 0.0

        while Date() < deadline && !checkIsDownloaded(at: packageURL) {
            if isCancelled?() == true { return }
            Thread.sleep(forTimeInterval: 0.15)
            if let vals = try? packageURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey]) {
                let curAlloc = vals.fileAllocatedSize ?? 0
                let totalSize = vals.fileSize ?? 0
                if curAlloc > lastAllocated {
                    lastAllocated = curAlloc
                    // Active bytes are arriving on disk — extend idle timeout window
                    deadline = max(deadline, Date().addingTimeInterval(min(timeout, 45.0)))
                }
                if totalSize > 0 && curAlloc > 0 {
                    let frac = min(0.99, Double(curAlloc) / Double(totalSize))
                    if frac - lastReportedFrac >= 0.01 {
                        lastReportedFrac = frac
                        progressHandler?(frac)
                    }
                }
            }
            if Date().timeIntervalSince(lastRetrigger) >= 4.0 {
                lastRetrigger = Date()
                triggerCloudDownload(at: packageURL)
            }
        }
        if checkIsDownloaded(at: packageURL) {
            progressHandler?(1.0)
        }
    }

    public nonisolated static func checkIsDownloaded(at packageURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.path) else {
            return false
        }
        var isDir: ObjCBool = false
        let resourceKeys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .fileSizeKey,
            .fileAllocatedSizeKey
        ]
        guard fm.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            if let vals = try? packageURL.resourceValues(forKeys: resourceKeys) {
                if vals.ubiquitousItemDownloadingStatus == .notDownloaded {
                    return false
                }
                if vals.ubiquitousItemIsDownloading == true {
                    return false
                }
                // On macOS FileProvider (Google Drive, OneDrive, Dropbox), dataless files have fileSize > 0 and fileAllocatedSize == 0
                if isCloudStorageURL(packageURL),
                   let size = vals.fileSize, size > 0,
                   let alloc = vals.fileAllocatedSize, alloc == 0 {
                    return false
                }
            }
            return true
        }
        if let enumerator = fm.enumerator(
            at: packageURL,
            includingPropertiesForKeys: Array(resourceKeys.union([.isDirectoryKey])),
            options: []
        ) {
            for case let child as URL in enumerator {
                let name = child.lastPathComponent
                if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                    return false
                }
                if let vals = try? child.resourceValues(forKeys: resourceKeys.union([.isDirectoryKey])) {
                    if vals.isDirectory == true { continue }
                    if vals.ubiquitousItemDownloadingStatus == .notDownloaded {
                        return false
                    }
                    if vals.ubiquitousItemIsDownloading == true {
                        return false
                    }
                    if isCloudStorageURL(child),
                       let size = vals.fileSize, size > 0,
                       let alloc = vals.fileAllocatedSize, alloc == 0 {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Checks whether all audio stems referenced by `meta` are available locally on this device
    /// (either in `StemCache`, downloaded as `<CloudRoot>/Stems/<songId>.pbstems`, or downloaded inside `<CloudRoot>/Stems/` or `rootFolder`).
    public nonisolated static func areSongStemsDownloaded(meta: SongPackageMetadata, rootFolder: URL) -> Bool {
        let fm = FileManager.default
        let cloudStems = cloudStemsDirectoryURL
        let inferredStems = rootFolder
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Stems", isDirectory: true)
        let stemsRoots = [cloudStems, inferredStems].compactMap { $0 }

        // Check if the single atomic `<songId>.pbstems` pack is already downloaded
        for stemsRoot in stemsRoots {
            let packURL = PlaybackFileManager.shared.resolveCloudStemPackURL(cloudStemsDir: stemsRoot, songId: meta.id)
            if fm.fileExists(atPath: packURL.path) && checkIsDownloaded(at: packURL) {
                return true
            }
        }

        for tm in meta.tracks where !tm.relativeAudioPath.isEmpty {
            if PlaybackFileManager.shared.hasValidCachedStem(for: tm.id) {
                continue
            }
            if tm.relativeAudioPath.hasPrefix("cloudstems/") {
                let subPath = String(tm.relativeAudioPath.dropFirst("cloudstems/".count))
                let comps = subPath.split(separator: "/")
                if comps.count >= 2, let parsedSongId = UUID(uuidString: String(comps[0])) {
                    let packReady = stemsRoots.contains { root in
                        let p = PlaybackFileManager.shared.resolveCloudStemPackURL(cloudStemsDir: root, songId: parsedSongId)
                        return fm.fileExists(atPath: p.path) && checkIsDownloaded(at: p)
                    }
                    if packReady { continue }
                }
                let candidates = [cloudStems?.appendingPathComponent(subPath), inferredStems.appendingPathComponent(subPath)].compactMap { $0 }
                guard let existing = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
                    return false
                }
                if !checkIsDownloaded(at: existing) {
                    return false
                }
            } else {
                let localURL = rootFolder.appendingPathComponent(tm.relativeAudioPath)
                if !checkIsDownloaded(at: localURL) {
                    return false
                }
            }
        }
        return true
    }

    private nonisolated static func hasServerUpdateResourceValues(_ values: URLResourceValues) -> Bool {
        if values.ubiquitousItemHasUnresolvedConflicts == true {
            return true
        }
        // While an item is still uploading from this Mac, do not mistake it for an incoming server update.
        if values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsUploaded == false {
            return false
        }
        return values.ubiquitousItemDownloadingStatus == .downloaded
    }

    /// Returns `true` when an iCloud Drive item has a newer version on the server (`.downloaded`
    /// stale local copy or unresolved conflict) compared to what is currently on disk.
    public nonisolated static func checkHasCloudUpdate(at packageURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.path) else {
            return false
        }
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey
        ]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            if let vals = try? packageURL.resourceValues(forKeys: keys), hasServerUpdateResourceValues(vals) {
                return true
            }
            return false
        }
        if let enumerator = fm.enumerator(
            at: packageURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            for case let child as URL in enumerator {
                if let vals = try? child.resourceValues(forKeys: keys), hasServerUpdateResourceValues(vals) {
                    return true
                }
            }
        }
        return false
    }

    /// Sanitizes a title or name for safe filenames on macOS / iCloud / Dropbox / Google Drive
    public nonisolated static func sanitizedPackageFilename(_ rawName: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Untitled" : cleaned
        return base.lowercased().hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
    }

    // MARK: - Direct Song Library Save & Import Helpers

    /// Exports a song from `engine` directly into the Local Song Library (`~/Library/Application Support/PeanutButter/Songs`) and refreshes the library list.
    @discardableResult
    public func saveSongToLocalLibrary(engine: MultitrackAudioEngine, songIndex: Int) throws -> URL {
        ensureDefaultDirectoriesExist()
        let song = (songIndex >= 0 && songIndex < engine.currentSetlist.songs.count)
            ? engine.currentSetlist.songs[songIndex]
            : engine.currentSong
        let rawTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Song" : song.title
        let fileName = Self.sanitizedPackageFilename(rawTitle, ext: "pbsong")
        let destURL = songsDirectory.appendingPathComponent(fileName)
        try engine.exportSongPackage(forSongIndex: songIndex, to: destURL)
        refreshSongs()
        return destURL
    }

    /// Exports a song from `engine` directly into the connected Cloud Song Library (`<CloudRoot>/Songs`) and refreshes the library list.
    @discardableResult
    public func saveSongToCloudLibrary(engine: MultitrackAudioEngine, songIndex: Int) throws -> URL {
        guard let cloudDir = cloudSongsDirectory else {
            throw NSError(
                domain: "LibraryBrowserManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No Cloud Library folder is connected. Connect a Cloud folder in Settings first."]
            )
        }
        try FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        let song = (songIndex >= 0 && songIndex < engine.currentSetlist.songs.count)
            ? engine.currentSetlist.songs[songIndex]
            : engine.currentSong
        let rawTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Song" : song.title
        let fileName = Self.sanitizedPackageFilename(rawTitle, ext: "pbsong")
        let destURL = cloudDir.appendingPathComponent(fileName)
        try engine.exportSongPackage(forSongIndex: songIndex, to: destURL)
        refreshSongs()
        return destURL
    }

    /// Copies one or more `.pbsong` / `.multitrack` packages from Finder directly into the Local or Cloud Song Library.
    @discardableResult
    public func importSongPackagesToLibrary(from urls: [URL], toCloud: Bool = false) throws -> Int {
        let targetDir: URL
        if toCloud {
            guard let cloudDir = cloudSongsDirectory else {
                throw NSError(
                    domain: "LibraryBrowserManager",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "No Cloud Library folder is connected."]
                )
            }
            try FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
            targetDir = cloudDir
        } else {
            ensureDefaultDirectoriesExist()
            targetDir = songsDirectory
        }

        var importedCount = 0
        for sourceURL in urls {
            let ext = sourceURL.pathExtension.lowercased()
            guard ext == "pbsong" || ext == "multitrack" else { continue }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            Self.ensureCloudItemDownloaded(at: sourceURL)
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let destFileName = Self.sanitizedPackageFilename(baseName, ext: ext)
            let destURL = targetDir.appendingPathComponent(destFileName)
            if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
                try PlaybackFileManager.shared.copyLibraryPackage(from: sourceURL, to: destURL, isSong: true)
            }
            importedCount += 1
        }
        refreshSongs()
        return importedCount
    }

    // MARK: - Fast Metadata Scanning (No Audio Stems Loaded)

    private nonisolated static func scanSongsSync(in directory: URL, source: LibrarySource) -> [SongLibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SongLibraryItem] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "pbsong" || ext == "multitrack" else { continue }
            if let item = inspectSongPackage(at: url, source: source) {
                results.append(item)
            }
        }
        return results
    }

    private nonisolated static func scanSetlistsSync(in directory: URL, source: LibrarySource) -> [SetlistLibraryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SetlistLibraryItem] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "pbsession" else { continue }
            if let item = inspectSetlistPackage(at: url, source: source) {
                results.append(item)
            }
        }
        return results
    }

    private nonisolated static func inspectSongPackage(at url: URL, source: LibrarySource) -> SongLibraryItem? {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        let modDate = values?.contentModificationDate ?? Date.distantPast
        let isDir = values?.isDirectory ?? false
        let downloaded = checkIsDownloaded(at: url)

        var jsonData: Data?
        var artwork: NSImage?

        if isDir {
            let jsonURL = url.appendingPathComponent("song.json")
            jsonData = try? Data(contentsOf: jsonURL)
            let artURL = url.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: artURL.path) {
                artwork = NSImage(contentsOf: artURL)
            }
        } else if downloaded {
            let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_scan_song_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempDir) }
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", url.path, "song.json", "artwork.png", "-d", tempDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            let jsonURL = tempDir.appendingPathComponent("song.json")
            jsonData = try? Data(contentsOf: jsonURL)
            let artURL = tempDir.appendingPathComponent("artwork.png")
            if fm.fileExists(atPath: artURL.path) {
                artwork = NSImage(contentsOf: artURL)
            }
        }

        if let data = jsonData,
           let meta = try? JSONDecoder().decode(SongPackageMetadata.self, from: data) {
            let duration = meta.tracks.compactMap { $0.duration }.max()
                ?? meta.sections.map { $0.endTime }.max()
                ?? 0.0
            let stemsDownloaded = (source == .local)
                ? true
                : (downloaded && areSongStemsDownloaded(meta: meta, rootFolder: url))
            return SongLibraryItem(
                id: url,
                url: url,
                title: meta.title.isEmpty ? url.deletingPathExtension().lastPathComponent : meta.title,
                artist: meta.artist,
                bpm: meta.bpm,
                musicalKey: meta.musicalKey,
                duration: duration,
                artwork: artwork,
                modifiedDate: modDate,
                source: source,
                isDownloaded: stemsDownloaded
            )
        }

        return SongLibraryItem(
            id: url,
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            bpm: 120.0,
            musicalKey: "C",
            duration: 0,
            artwork: artwork,
            modifiedDate: modDate,
            source: source,
            isDownloaded: downloaded
        )
    }

    /// Returns the newest modification date between the `.pbsession` package itself and its inner `session.json`.
    public nonisolated static func packageModificationDate(at url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        let rootMod = values?.contentModificationDate ?? Date.distantPast
        guard values?.isDirectory == true else { return rootMod }
        let jsonURL = url.appendingPathComponent("session.json")
        let jsonMod = (try? jsonURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        return max(rootMod, jsonMod)
    }

    private nonisolated static func inspectSetlistPackage(at url: URL, source: LibrarySource) -> SetlistLibraryItem? {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        let isDir = values?.isDirectory ?? false
        let modDate = packageModificationDate(at: url)
        let downloaded = checkIsDownloaded(at: url)
        let rawServerCloudUpdate = (source == .cloud) ? checkHasCloudUpdate(at: url) : false

        if let cached = setlistPackageCache.get(
            url: url,
            modDate: modDate,
            isDownloaded: downloaded,
            hasCloudUpdate: rawServerCloudUpdate,
            source: source
        ) {
            return cached
        }

        var jsonData: Data?
        var artworks: [NSImage] = []

        if isDir {
            let jsonURL = url.appendingPathComponent("session.json")
            jsonData = try? Data(contentsOf: jsonURL)
            let songsDir = url.appendingPathComponent("songs")
            if let songDirs = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                for sDir in songDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(4) {
                    let artURL = sDir.appendingPathComponent("artwork.png")
                    if let img = NSImage(contentsOf: artURL) {
                        artworks.append(img)
                    }
                }
            }
        } else if downloaded {
            let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_scan_sess_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempDir) }
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", url.path, "session.json", "songs/*/artwork.png", "-d", tempDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            let jsonURL = tempDir.appendingPathComponent("session.json")
            jsonData = try? Data(contentsOf: jsonURL)
            let songsDir = tempDir.appendingPathComponent("songs")
            if let songDirs = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                for sDir in songDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(4) {
                    let artURL = sDir.appendingPathComponent("artwork.png")
                    if let img = NSImage(contentsOf: artURL) {
                        artworks.append(img)
                    }
                }
            }
        }

        if let data = jsonData,
           let meta = try? JSONDecoder().decode(SessionPackageMetadata.self, from: data) {
            let name = meta.name.isEmpty ? url.deletingPathExtension().lastPathComponent : meta.name
            let songCount = meta.songEntries.count
            let totalDuration = meta.songEntries.reduce(0.0) { acc, song in
                let d = song.tracks.compactMap { $0.duration }.max()
                    ?? song.sections.map { $0.endTime }.max()
                    ?? 0.0
                return acc + d
            }
            let totalSec = max(0, Int(totalDuration.rounded()))
            let mins = totalSec / 60
            let secs = totalSec % 60
            let formattedDur = String(format: "%d:%02d", mins, secs)

            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .short
            let dateStr = dateFmt.string(from: meta.scheduledDate ?? modDate)

            let allSongsDownloaded = (source == .local)
                ? true
                : (downloaded && meta.songEntries.allSatisfy { areSongStemsDownloaded(meta: $0, rootFolder: url) })

            let item = SetlistLibraryItem(
                id: url,
                url: url,
                name: name,
                songCount: songCount,
                formattedDate: dateStr,
                formattedDuration: formattedDur,
                artworks: artworks,
                modifiedDate: modDate,
                source: source,
                isDownloaded: allSongsDownloaded,
                hasCloudUpdate: rawServerCloudUpdate,
                changeDescription: meta.changeDescription,
                hasUnresolvedServerUpdate: rawServerCloudUpdate,
                lastSavedRevisionId: meta.lastSavedRevisionId,
                lastSavedByDeviceId: meta.lastSavedByDeviceId
            )
            setlistPackageCache.set(
                url: url,
                modDate: modDate,
                isDownloaded: downloaded,
                hasCloudUpdate: rawServerCloudUpdate,
                source: source,
                item: item
            )
            return item
        }

        let item = SetlistLibraryItem(
            id: url,
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            songCount: 0,
            formattedDate: "",
            formattedDuration: "0:00",
            artworks: artworks,
            modifiedDate: modDate,
            source: source,
            isDownloaded: downloaded,
            hasCloudUpdate: rawServerCloudUpdate,
            hasUnresolvedServerUpdate: rawServerCloudUpdate
        )
        setlistPackageCache.set(
            url: url,
            modDate: modDate,
            isDownloaded: downloaded,
            hasCloudUpdate: rawServerCloudUpdate,
            source: source,
            item: item
        )
        return item
    }

    /// Loads lightweight song previews (title, key, BPM, duration, artwork) from a `.pbsession` package or archive.
    public nonisolated static func loadSetlistSongsPreview(for item: SetlistLibraryItem) -> [SetlistSongPreview] {
        let fm = FileManager.default
        let url = item.url
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let downloaded = checkIsDownloaded(at: url)

        var jsonData: Data?
        var artworkByIndex: [Int: NSImage] = [:]

        if isDir {
            jsonData = try? Data(contentsOf: url.appendingPathComponent("session.json"))
            let songsDir = url.appendingPathComponent("songs")
            if let songDirs = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                for sDir in songDirs {
                    let name = sDir.lastPathComponent
                    if name.hasPrefix("song_"), let idx = Int(name.dropFirst(5)) {
                        if let img = NSImage(contentsOf: sDir.appendingPathComponent("artwork.png")) {
                            artworkByIndex[idx] = img
                        }
                    }
                }
            }
        } else if downloaded {
            let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_preview_sess_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempDir) }
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", url.path, "session.json", "songs/*/artwork.png", "-d", tempDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            jsonData = try? Data(contentsOf: tempDir.appendingPathComponent("session.json"))
            let songsDir = tempDir.appendingPathComponent("songs")
            if let songDirs = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
                for sDir in songDirs {
                    let name = sDir.lastPathComponent
                    if name.hasPrefix("song_"), let idx = Int(name.dropFirst(5)) {
                        if let img = NSImage(contentsOf: sDir.appendingPathComponent("artwork.png")) {
                            artworkByIndex[idx] = img
                        }
                    }
                }
            }
        }

        guard let data = jsonData,
              let meta = try? JSONDecoder().decode(SessionPackageMetadata.self, from: data) else {
            return []
        }

        return meta.songEntries.enumerated().map { idx, song in
            let dur = song.tracks.compactMap { $0.duration }.max()
                ?? song.sections.map { $0.endTime }.max()
                ?? 0.0
            let sig = "\(song.timeSignatureNumerator)/\(song.timeSignatureDenominator)"
            let songDownloaded = (item.source == .local)
                ? true
                : (downloaded && areSongStemsDownloaded(meta: song, rootFolder: url))
            return SetlistSongPreview(
                id: song.id,
                title: song.title.isEmpty ? "Untitled Song" : song.title,
                artist: song.artist,
                bpm: song.bpm,
                musicalKey: song.musicalKey.isEmpty ? "C" : song.musicalKey,
                timeSignature: sig,
                duration: dur,
                artwork: artworkByIndex[idx],
                isDownloaded: songDownloaded
            )
        }
    }

    /// Evicts the local downloaded copy of a cloud setlist and its unshared cloud song stems
    /// (and StemCache / transposed WAV renders) from this device while leaving files in the cloud.
    public func removeSetlistFromDevice(_ item: SetlistLibraryItem) {
        let fm = FileManager.default
        let url = item.url

        // 1. Read this setlist's songEntries before evicting it
        let targetMeta = Self.readSessionMetadata(at: url)

        // 2. Collect song/track IDs still referenced by other downloaded cloud setlists
        var stillNeededSongIds = Set<UUID>()
        var stillNeededTrackIds = Set<UUID>()
        if let cloudDir = cloudSetlistsDirectory,
           let siblings = try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for sibling in siblings where sibling.pathExtension.lowercased() == "pbsession" {
                if sibling.standardizedFileURL == url.standardizedFileURL { continue }
                if let sibMeta = Self.readSessionMetadata(at: sibling),
                   sibMeta.songEntries.allSatisfy({ Self.areSongStemsDownloaded(meta: $0, rootFolder: sibling) }) {
                    for s in sibMeta.songEntries {
                        stillNeededSongIds.insert(s.id)
                        for t in s.tracks {
                            stillNeededTrackIds.insert(t.id)
                        }
                    }
                }
            }
        }

        // 3. Evict cloud stems & clear StemCache / transposed caches for songs not used elsewhere
        let stemCacheDir = PlaybackFileManager.shared.stemCacheDirectory
        let transposedDirs = (try? fm.contentsOfDirectory(at: stemCacheDir, includingPropertiesForKeys: nil)) ?? []

        if let meta = targetMeta {
            for song in meta.songEntries {
                if !stillNeededSongIds.contains(song.id) {
                    if let cStems = cloudStemsDirectory {
                        let packURL = PlaybackFileManager.shared.resolveCloudStemPackURL(cloudStemsDir: cStems, songId: song.id)
                        if fm.fileExists(atPath: packURL.path) {
                            Self.evictItemRecursively(at: packURL)
                        }
                        let stemsDir = cStems.appendingPathComponent(song.id.uuidString, isDirectory: true)
                        if fm.fileExists(atPath: stemsDir.path) {
                            Self.evictItemRecursively(at: stemsDir)
                        }
                    }
                    if let songsDir = cloudSongsDirectory {
                        let songFile = songsDir.appendingPathComponent(Self.sanitizedPackageFilename(song.title, ext: "pbsong"))
                        if fm.fileExists(atPath: songFile.path) {
                            Self.evictItemRecursively(at: songFile)
                        }
                    }
                    let songIdStr = song.id.uuidString
                    for dir in transposedDirs where dir.lastPathComponent.hasPrefix("transposed_") && dir.lastPathComponent.contains(songIdStr) {
                        try? fm.removeItem(at: dir)
                    }
                }
                for track in song.tracks where !stillNeededTrackIds.contains(track.id) {
                    let cached = PlaybackFileManager.shared.cachedStemURL(for: track.id)
                    if fm.fileExists(atPath: cached.path) {
                        try? fm.removeItem(at: cached)
                    }
                }
            }
        }

        // 4. Evict heavy files inside the .pbsession while preserving lightweight JSON & artwork metadata
        Self.evictItemRecursively(at: url)
        refreshSetlists()
        refreshSongs()
    }

    private nonisolated static func evictItemRecursively(at url: URL) {
        let fm = FileManager.default
        let isUbiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? fm.isUbiquitousItem(at: url)
        guard isUbiquitous else { return }
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let child as URL in enumerator {
                let ext = child.pathExtension.lowercased()
                if ext == "json" || ext == "png" || ext == "jpg" || ext == "jpeg" { continue }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                try? fm.evictUbiquitousItem(at: child)
            }
        } else {
            let ext = url.pathExtension.lowercased()
            if ext != "json" && ext != "png" && ext != "jpg" && ext != "jpeg" {
                try? fm.evictUbiquitousItem(at: url)
            }
        }
    }

    private nonisolated static func readSessionMetadata(at url: URL) -> SessionPackageMetadata? {
        let fm = FileManager.default
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("session.json")) else { return nil }
            return try? JSONDecoder().decode(SessionPackageMetadata.self, from: data)
        }
        guard checkIsDownloaded(at: url) else { return nil }
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_meta_read_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", url.path, "session.json", "-d", tempDir.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: tempDir.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionPackageMetadata.self, from: data)
    }

    /// Deletes only the `.pbsession` file/package from either Local or Cloud Setlists,
    /// without deleting any songs from the user's song library.
    public func deleteSetlist(_ item: SetlistLibraryItem) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: item.url.path) {
            try fm.removeItem(at: item.url)
        } else {
            let placeholder = item.url.deletingLastPathComponent()
                .appendingPathComponent(".\(item.url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try fm.removeItem(at: placeholder)
            }
        }
        refreshSetlists()
    }

    /// Deletes a `.pbsong` / `.multitrack` package from either Local or Cloud Songs library
    /// and refreshes the song library list.
    public func deleteSong(_ item: SongLibraryItem) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: item.url.path) {
            try fm.removeItem(at: item.url)
        } else {
            let placeholder = item.url.deletingLastPathComponent()
                .appendingPathComponent(".\(item.url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try fm.removeItem(at: placeholder)
            }
        }
        refreshSongs()
    }

    /// Updates any existing `.pbsong` copy of the given song in Local and/or Cloud Song Libraries.
    /// Returns the list of library locations updated ("Local", "Cloud").
    @discardableResult
    public func saveSongChangesToExistingLibraries(engine: MultitrackAudioEngine, songIndex: Int) throws -> [String] {
        let fm = FileManager.default
        let song = (songIndex >= 0 && songIndex < engine.currentSetlist.songs.count)
            ? engine.currentSetlist.songs[songIndex]
            : engine.currentSong
        let rawTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Song" : song.title
        let fileName = Self.sanitizedPackageFilename(rawTitle, ext: "pbsong")

        var updatedLocations: [String] = []

        let localMatch = songs.first(where: {
            $0.source == .local && $0.title.caseInsensitiveCompare(rawTitle) == .orderedSame
        })?.url ?? songsDirectory.appendingPathComponent(fileName)
        if fm.fileExists(atPath: localMatch.path) {
            try engine.exportSongPackage(forSongIndex: songIndex, to: localMatch)
            updatedLocations.append("Local")
        }

        if let cloudDir = cloudSongsDirectory {
            let cloudMatch = songs.first(where: {
                $0.source == .cloud && $0.title.caseInsensitiveCompare(rawTitle) == .orderedSame
            })?.url ?? cloudDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: cloudMatch.path) {
                try engine.exportSongPackage(forSongIndex: songIndex, to: cloudMatch)
                updatedLocations.append("Cloud")
            }
        }

        if !updatedLocations.isEmpty {
            refreshSongs()
        }
        return updatedLocations
    }

    public func hasExistingLibraryCopy(for song: Song) -> Bool {
        let fm = FileManager.default
        let rawTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Song" : song.title
        let fileName = Self.sanitizedPackageFilename(rawTitle, ext: "pbsong")
        if songs.contains(where: { $0.title.caseInsensitiveCompare(rawTitle) == .orderedSame }) { return true }
        if fm.fileExists(atPath: songsDirectory.appendingPathComponent(fileName).path) { return true }
        if let cloudDir = cloudSongsDirectory,
           fm.fileExists(atPath: cloudDir.appendingPathComponent(fileName).path) {
            return true
        }
        return false
    }
}
