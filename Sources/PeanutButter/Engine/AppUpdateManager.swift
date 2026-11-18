import Foundation
import AppKit

/// Checks GitHub Releases (`rghapro/PeanutButter`), downloads `PeanutButter.zip` updates
/// with live progress, verifies code signing, and swaps the `.app` bundle cleanly on relaunch or quit.
@MainActor
public final class AppUpdateManager: ObservableObject {
    public static let shared = AppUpdateManager()

    public static let repoOwner = "rghapro"
    public static let repoName = "PeanutButter"
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/rghapro/PeanutButter/releases/latest")!
    public static let releasesWebURL = URL(string: "https://github.com/rghapro/PeanutButter/releases/latest")!

    private static let lastCheckTimestampKey = "PeanutButter_LastUpdateCheckTimestamp"
    private static let skippedVersionKey = "PeanutButter_SkippedUpdateVersion"
    private static let suppressMoveToApplicationsKey = "PeanutButter_SuppressMoveToApplications"
    private static let autoCheckInterval: TimeInterval = 86_400
    private static let expectedBundleIdentifier = "com.peanutbutter.app"

    public struct ReleaseInfo: Equatable, Sendable {
        public let tagName: String
        public let displayVersion: String
        public let title: String
        public let releaseNotes: String
        public let htmlURL: URL
        public let zipAssetURL: URL?

        public init(
            tagName: String,
            displayVersion: String,
            title: String,
            releaseNotes: String,
            htmlURL: URL,
            zipAssetURL: URL?
        ) {
            self.tagName = tagName
            self.displayVersion = displayVersion
            self.title = title
            self.releaseNotes = releaseNotes
            self.htmlURL = htmlURL
            self.zipAssetURL = zipAssetURL
        }
    }

    public enum UpdatePhase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double, receivedBytes: Int64, totalBytes: Int64)
        case readyToInstall(ReleaseInfo, stagedAppURL: URL, installOnQuitArmed: Bool)
        case installing
        case error(String)
    }

    @Published public private(set) var phase: UpdatePhase = .idle
    @Published public var isUpdateSheetPresented: Bool = false
    @Published public var isBannerDismissedForSession: Bool = false

    /// Called right before quitting to install an update so unsaved sessions can auto-save cleanly.
    public var onBeforeRelaunch: (() -> Void)?

    private var downloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadDelegate: DownloadSessionDelegate?
    private var activeStagingRootURL: URL?
    private var hasSpawnedSwapHelper: Bool = false
    private var hasPromptedMoveToApplications: Bool = false

    private init() {}

    public var currentVersion: String {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "1.0.0" : trimmed
    }

    public var availableRelease: ReleaseInfo? {
        switch phase {
        case .available(let release),
             .downloading(let release, _, _, _),
             .readyToInstall(let release, _, _):
            return release
        default:
            return nil
        }
    }

    public var isReadyToInstall: Bool {
        if case .readyToInstall = phase { return true }
        return false
    }

    public var shouldShowTopBanner: Bool {
        availableRelease != nil && !isBannerDismissedForSession
    }

    private var lastCheckTimestamp: TimeInterval {
        get { UserDefaults.standard.double(forKey: Self.lastCheckTimestampKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCheckTimestampKey) }
    }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: Self.skippedVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }

    // MARK: - Semantic Version & Release JSON Helpers

    /// Returns `true` when `candidate` represents a strictly newer semver than `current`.
    public nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let parsedCandidate = parseSemVer(candidate)
        let parsedCurrent = parseSemVer(current)

        let maxCount = max(parsedCandidate.numbers.count, parsedCurrent.numbers.count)
        for idx in 0..<maxCount {
            let lhs = idx < parsedCandidate.numbers.count ? parsedCandidate.numbers[idx] : 0
            let rhs = idx < parsedCurrent.numbers.count ? parsedCurrent.numbers[idx] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }

        // Equal numeric parts: a stable release is newer than a pre-release (`1.0.0` > `1.0.0-beta.1`)
        if parsedCandidate.prerelease == nil && parsedCurrent.prerelease != nil {
            return true
        }
        return false
    }

    private nonisolated static func parseSemVer(_ raw: String) -> (numbers: [Int], prerelease: String?) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let plusIdx = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIdx])
        }
        let corePart: String
        let prerelease: String?
        if let dashIdx = cleaned.firstIndex(of: "-") {
            corePart = String(cleaned[..<dashIdx])
            let suffix = String(cleaned[cleaned.index(after: dashIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            prerelease = suffix.isEmpty ? nil : suffix
        } else {
            corePart = cleaned
            prerelease = nil
        }

        let numbers = corePart
            .split(separator: ".")
            .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return (numbers.isEmpty ? [0] : numbers, prerelease)
    }

    private struct GitHubReleaseAssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct GitHubReleaseDTO: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GitHubReleaseAssetDTO]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    public enum ParseError: LocalizedError {
        case invalidHTMLURL
        public var errorDescription: String? {
            switch self {
            case .invalidHTMLURL: return "GitHub release metadata did not contain a valid release URL."
            }
        }
    }

    /// Parses GitHub `/releases/latest` JSON payload into `ReleaseInfo`.
    public nonisolated static func parseReleaseJSON(_ data: Data) throws -> (release: ReleaseInfo, isDraftOrPrerelease: Bool) {
        let dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        guard let htmlURL = URL(string: dto.htmlURL) else {
            throw ParseError.invalidHTMLURL
        }

        var display = dto.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.hasPrefix("v") || display.hasPrefix("V") {
            display.removeFirst()
        }

        let assets = dto.assets ?? []
        let zipAsset = assets.first(where: { $0.name.caseInsensitiveCompare("PeanutButter.zip") == .orderedSame })
            ?? assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
        let zipAssetURL = zipAsset.flatMap { URL(string: $0.browserDownloadURL) }

        let rawTitle = (dto.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "PeanutButter v\(display)" : rawTitle
        let notes = (dto.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isDraftOrPre = (dto.draft ?? false) || (dto.prerelease ?? false)

        let info = ReleaseInfo(
            tagName: dto.tagName,
            displayVersion: display,
            title: title,
            releaseNotes: notes,
            htmlURL: htmlURL,
            zipAssetURL: zipAssetURL
        )
        return (info, isDraftOrPre)
    }

    // MARK: - Checking for Updates

    /// Checks GitHub Releases for a newer version.
    /// Background checks are throttled to once per 24h and skipped during active playback.
    public func checkForUpdates(
        manual: Bool,
        isStagePlaybackActive: Bool = false,
        customAPIURL: URL? = nil
    ) {
        switch phase {
        case .downloading, .readyToInstall, .installing:
            if manual {
                isUpdateSheetPresented = true
            }
            return
        case .checking:
            if manual {
                isUpdateSheetPresented = true
            }
            return
        default:
            break
        }

        if !manual {
            if isStagePlaybackActive { return }
            let elapsed = Date().timeIntervalSince1970 - lastCheckTimestamp
            if elapsed >= 0 && elapsed < Self.autoCheckInterval {
                return
            }
        } else {
            phase = .checking
            isUpdateSheetPresented = true
        }

        let endpoint = customAPIURL ?? Self.latestReleaseAPIURL
        let versionString = currentVersion
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PeanutButter/\(versionString)", forHTTPHeaderField: "User-Agent")

        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200

                if statusCode == 404 {
                    self.lastCheckTimestamp = Date().timeIntervalSince1970
                    self.phase = manual ? .upToDate : .idle
                    return
                }

                guard (200...299).contains(statusCode) else {
                    self.phase = manual ? .error("GitHub returned status \(statusCode). Check again later.") : .idle
                    return
                }

                self.lastCheckTimestamp = Date().timeIntervalSince1970
                let parsed = try Self.parseReleaseJSON(data)
                let release = parsed.release

                if !parsed.isDraftOrPrerelease && Self.isVersion(release.tagName, newerThan: versionString) {
                    if !manual && self.skippedVersion == release.tagName {
                        self.phase = .idle
                        return
                    }
                    self.isBannerDismissedForSession = false
                    self.phase = .available(release)
                } else {
                    self.phase = manual ? .upToDate : .idle
                }
            } catch {
                if manual {
                    self.phase = .error("Could not reach GitHub: \(error.localizedDescription)")
                } else {
                    self.phase = .idle
                }
            }
        }
    }

    public func skipVersion(_ release: ReleaseInfo) {
        skippedVersion = release.tagName
        isUpdateSheetPresented = false
        isBannerDismissedForSession = true
        phase = .idle
    }

    public func remindMeLater() {
        isUpdateSheetPresented = false
        isBannerDismissedForSession = true
    }

    public func openReleasePageInBrowser() {
        let url = availableRelease?.htmlURL ?? Self.releasesWebURL
        NSWorkspace.shared.open(url)
    }

    // MARK: - Download, Extract, & Verify

    /// Downloads and stages `PeanutButter.zip` into `stagingRoot` without disrupting playback.
    public func downloadUpdate(from overrideAssetURL: URL? = nil, customStagingRoot: URL? = nil) {
        guard let release = availableRelease else { return }
        switch phase {
        case .downloading, .installing:
            return
        default:
            break
        }

        guard let assetURL = overrideAssetURL ?? release.zipAssetURL else {
            openReleasePageInBrowser()
            return
        }

        let rootDir: URL
        if let customStagingRoot {
            rootDir = customStagingRoot
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            rootDir = caches.appendingPathComponent("PeanutButter/Updates", isDirectory: true)
        }
        activeStagingRootURL = rootDir

        let safeTag = release.tagName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let tagDir = rootDir.appendingPathComponent(safeTag, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: tagDir)
        do {
            try fm.createDirectory(at: tagDir, withIntermediateDirectories: true)
        } catch {
            phase = .error("Could not prepare update folder: \(error.localizedDescription)")
            return
        }

        let zipDestination = tagDir.appendingPathComponent("PeanutButter.zip")
        isBannerDismissedForSession = false
        phase = .downloading(release, progress: 0.0, receivedBytes: 0, totalBytes: 0)

        let delegate = DownloadSessionDelegate(
            zipDestination: zipDestination,
            onProgress: { [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case let .downloading(currentRelease, _, _, _) = self.phase else { return }
                    let frac = total > 0 ? min(1.0, max(0.0, Double(received) / Double(total))) : 0.0
                    self.phase = .downloading(currentRelease, progress: frac, receivedBytes: received, totalBytes: total)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeDownloadTask = nil
                    switch result {
                    case .success(let savedZipURL):
                        await self.unpackAndVerify(zipURL: savedZipURL, tagDir: tagDir, release: release)
                    case .failure(let err):
                        let nsErr = err as NSError
                        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                            self.phase = .available(release)
                        } else {
                            self.phase = .error("Download failed: \(err.localizedDescription)")
                        }
                    }
                }
            }
        )

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        downloadSession?.invalidateAndCancel()
        downloadSession = session
        activeDownloadDelegate = delegate

        var request = URLRequest(url: assetURL)
        request.setValue("PeanutButter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        activeDownloadTask = task
        task.resume()
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        activeDownloadDelegate = nil
        if case let .downloading(release, _, _, _) = phase {
            phase = .available(release)
        }
    }

    private func unpackAndVerify(zipURL: URL, tagDir: URL, release: ReleaseInfo) async {
        let unpackDir = tagDir.appendingPathComponent("Unpacked", isDirectory: true)
        do {
            let stagedAppURL: URL = try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: unpackDir)
                try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)

                let dittoStatus = Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, unpackDir.path])
                guard dittoStatus == 0 else {
                    throw NSError(domain: "AppUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to unpack PeanutButter.zip (exit \(dittoStatus))."])
                }

                let preferredApp = unpackDir.appendingPathComponent("PeanutButter.app")
                let stagedApp: URL
                if fm.fileExists(atPath: preferredApp.path) {
                    stagedApp = preferredApp
                } else if let contents = try? fm.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil),
                          let foundApp = contents.first(where: { $0.pathExtension.lowercased() == "app" }) {
                    stagedApp = foundApp
                } else {
                    throw NSError(domain: "AppUpdateManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Downloaded archive did not contain PeanutButter.app."])
                }

                // Strip any quarantine attributes so relaunch does not nag Gatekeeper.
                _ = Self.runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagedApp.path])

                // Verify bundle identifier and strict code signature before arming install.
                let plistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
                guard let plistData = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                      (plist["CFBundleIdentifier"] as? String) == Self.expectedBundleIdentifier else {
                    throw NSError(domain: "AppUpdateManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Staged app bundle identifier mismatch."])
                }

                let codesignStatus = Self.runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedApp.path])
                guard codesignStatus == 0 else {
                    throw NSError(domain: "AppUpdateManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Code signature verification failed for downloaded update."])
                }

                try? fm.removeItem(at: zipURL)
                return stagedApp
            }.value

            isBannerDismissedForSession = false
            phase = .readyToInstall(release, stagedAppURL: stagedAppURL, installOnQuitArmed: true)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private nonisolated static func runProcess(_ launchPath: String, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - Move to Applications & In-Place Bundle Swap (On Quit or Relaunch)

    public nonisolated static func shouldOfferMoveToApplications(bundlePath: String, downloadsPath: String? = nil) -> Bool {
        guard bundlePath.hasSuffix(".app") else { return false }
        let stdBundle = URL(fileURLWithPath: bundlePath).standardized.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardized.path
        if stdBundle.hasPrefix("/Applications/") || stdBundle == "/Applications" ||
           stdBundle.hasPrefix(userApps + "/") || stdBundle == userApps {
            return false
        }
        if stdBundle.contains("/AppTranslocation/") {
            return true
        }
        let resolvedDownloads = downloadsPath ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        if let dl = resolvedDownloads, !dl.isEmpty {
            let stdDownloads = URL(fileURLWithPath: dl).standardized.path
            if stdBundle.hasPrefix(stdDownloads + "/") {
                return true
            }
        }
        return false
    }

    public func promptMoveToApplicationsIfNeeded() {
        guard !hasPromptedMoveToApplications else { return }
        guard !UserDefaults.standard.bool(forKey: Self.suppressMoveToApplicationsKey) else { return }
        let bundlePath = Bundle.main.bundlePath
        guard Self.shouldOfferMoveToApplications(bundlePath: bundlePath) else { return }
        hasPromptedMoveToApplications = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move PeanutButter to Applications?"
        alert.informativeText = "PeanutButter is currently running from your Downloads folder. Moving it to Applications keeps future updates fast and password-free."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let destURL = URL(fileURLWithPath: "/Applications/PeanutButter.app")
            let downloadsAppURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PeanutButter.app")
            let extraCleanup = bundlePath.contains("/AppTranslocation/") ? downloadsAppURL : nil
            onBeforeRelaunch?()
            if spawnSwapHelper(
                targetAppURL: destURL,
                stagedAppURL: Bundle.main.bundleURL,
                relaunch: true,
                stagingRootPath: "",
                extraCleanupAppPath: extraCleanup?.path ?? ""
            ) {
                hasSpawnedSwapHelper = true
                NSApplication.shared.terminate(nil)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: Self.suppressMoveToApplicationsKey)
        default:
            break
        }
    }

    /// Returns a self-cleaning `/bin/sh` script that waits for `PID`, swaps the staged `.app` bundle
    /// cleanly (using instant `mv` when possible with `ditto` fallback, automatic rollback, and an osascript
    /// admin prompt fallback if `/Applications` is locked), relaunches first, and cleans up in the background.
    public nonisolated static func buildSwapShellScript() -> String {
        return """
        #!/bin/sh
        APP_PID="$1"
        TARGET_APP="$2"
        STAGED_APP="$3"
        RELAUNCH="$4"
        STAGING_ROOT="$5"
        EXTRA_CLEANUP_APP="${6:-}"

        if [ -n "$APP_PID" ] && [ "$APP_PID" -gt 0 ] 2>/dev/null; then
            TRIES=0
            while kill -0 "$APP_PID" 2>/dev/null; do
                sleep 0.1
                TRIES=$((TRIES + 1))
                if [ "$TRIES" -ge 300 ]; then
                    rm -f "$0"
                    exit 1
                fi
            done
        fi

        if [ ! -d "$STAGED_APP" ]; then
            rm -f "$0"
            exit 1
        fi

        PARENT_DIR=$(dirname "$TARGET_APP")
        BACKUP_APP="${TARGET_APP}.pb_backup_$$"

        perform_swap() {
            if [ -e "$TARGET_APP" ]; then
                mv "$TARGET_APP" "$BACKUP_APP" || return 1
            fi
            if ! mv "$STAGED_APP" "$TARGET_APP" 2>/dev/null; then
                if ! /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"; then
                    rm -rf "$TARGET_APP" 2>/dev/null || true
                    if [ -e "$BACKUP_APP" ]; then
                        mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
                    fi
                    return 1
                fi
            fi
            if /usr/bin/xattr -p com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1; then
                /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
            fi
            return 0
        }

        if [ -w "$PARENT_DIR" ]; then
            if ! perform_swap; then
                rm -f "$0"
                exit 1
            fi
        else
            ESC_TARGET=$(printf '%s' "$TARGET_APP" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
            ESC_STAGED=$(printf '%s' "$STAGED_APP" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
            ESC_BACKUP=$(printf '%s' "$BACKUP_APP" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
            ADMIN_CMD="rm -rf \\"${ESC_BACKUP}\\" && ([ ! -e \\"${ESC_TARGET}\\" ] || mv \\"${ESC_TARGET}\\" \\"${ESC_BACKUP}\\") && (mv \\"${ESC_STAGED}\\" \\"${ESC_TARGET}\\" 2>/dev/null || /usr/bin/ditto \\"${ESC_STAGED}\\" \\"${ESC_TARGET}\\" || (rm -rf \\"${ESC_TARGET}\\"; [ -e \\"${ESC_BACKUP}\\" ] && mv \\"${ESC_BACKUP}\\" \\"${ESC_TARGET}\\"; exit 1)) && /usr/bin/xattr -dr com.apple.quarantine \\"${ESC_TARGET}\\" 2>/dev/null; rm -rf \\"${ESC_BACKUP}\\""
            ESC_ADMIN=$(printf '%s' "$ADMIN_CMD" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
            if ! /usr/bin/osascript -e "do shell script \\"${ESC_ADMIN}\\" with administrator privileges" >/dev/null 2>&1; then
                rm -f "$0"
                exit 1
            fi
        fi

        if [ "$RELAUNCH" = "1" ]; then
            /usr/bin/open "$TARGET_APP" >/dev/null 2>&1 || true
        fi

        if [ -e "$BACKUP_APP" ]; then
            rm -rf "$BACKUP_APP" 2>/dev/null || true
        fi

        if [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
            rm -rf "$STAGING_ROOT" 2>/dev/null || true
        fi

        if [ -n "$EXTRA_CLEANUP_APP" ] && [ "$EXTRA_CLEANUP_APP" != "$TARGET_APP" ] && [ -d "$EXTRA_CLEANUP_APP" ]; then
            rm -rf "$EXTRA_CLEANUP_APP" 2>/dev/null || true
        fi

        rm -f "$0"
        exit 0
        """
    }

    private func resolvedInstallTargetAndCleanup() -> (targetURL: URL, extraCleanupPath: String) {
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            let destURL = URL(fileURLWithPath: "/Applications/PeanutButter.app")
            let downloadsApp = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PeanutButter.app")
            let extra = (downloadsApp != nil && FileManager.default.fileExists(atPath: downloadsApp!.path)) ? downloadsApp!.path : ""
            return (destURL, extra)
        }
        return (Bundle.main.bundleURL, "")
    }

    public func installAndRelaunchNow() {
        guard case let .readyToInstall(_, stagedURL, _) = phase else { return }
        guard FileManager.default.fileExists(atPath: stagedURL.path) else {
            phase = .error("Staged update could not be found on disk. Please download again.")
            return
        }

        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            NSWorkspace.shared.activateFileViewerSelecting([stagedURL])
            phase = .error("Running unbundled dev build — revealed staged PeanutButter.app in Finder.")
            return
        }

        onBeforeRelaunch?()
        let resolved = resolvedInstallTargetAndCleanup()
        guard spawnSwapHelper(
            targetAppURL: resolved.targetURL,
            stagedAppURL: stagedURL,
            relaunch: true,
            extraCleanupAppPath: resolved.extraCleanupPath
        ) else {
            phase = .error("Could not launch installer helper. Please drag the update manually.")
            return
        }

        hasSpawnedSwapHelper = true
        phase = .installing
        NSApplication.shared.terminate(nil)
    }

    /// Invoked from `AppDelegate.applicationWillTerminate` to swap a downloaded `.app` on close.
    public func performPendingInstallOnQuitIfNeeded() {
        guard !hasSpawnedSwapHelper else { return }
        guard case let .readyToInstall(_, stagedURL, installOnQuitArmed) = phase,
              installOnQuitArmed,
              FileManager.default.fileExists(atPath: stagedURL.path),
              Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }

        let resolved = resolvedInstallTargetAndCleanup()
        if spawnSwapHelper(
            targetAppURL: resolved.targetURL,
            stagedAppURL: stagedURL,
            relaunch: false,
            extraCleanupAppPath: resolved.extraCleanupPath
        ) {
            hasSpawnedSwapHelper = true
        }
    }

    private func spawnSwapHelper(
        targetAppURL: URL,
        stagedAppURL: URL,
        relaunch: Bool,
        stagingRootPath: String? = nil,
        extraCleanupAppPath: String = ""
    ) -> Bool {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pb_install_update_\(UUID().uuidString).sh")
        let scriptContent = Self.buildSwapShellScript()
        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }

        let stagingRoot = stagingRootPath ?? (activeStagingRootURL?.path ?? stagedAppURL.deletingLastPathComponent().deletingLastPathComponent().path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            targetAppURL.path,
            stagedAppURL.path,
            relaunch ? "1" : "0",
            stagingRoot,
            extraCleanupAppPath
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return false
        }
    }
}

private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let zipDestination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var didComplete = false

    init(
        zipDestination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinish: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.zipDestination = zipDestination
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    private func completeOnce(_ result: Result<URL, Error>) {
        lock.lock()
        let alreadyCompleted = didComplete
        didComplete = true
        lock.unlock()
        guard !alreadyCompleted else { return }
        onFinish(result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        if let httpResp = downloadTask.response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
            completeOnce(.failure(NSError(
                domain: "AppUpdateManager",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub download returned status \(httpResp.statusCode)."]
            )))
            return
        }

        // URLSession deletes `location` immediately upon return, so move/copy synchronously here.
        do {
            try? fm.removeItem(at: zipDestination)
            try fm.moveItem(at: location, to: zipDestination)
            completeOnce(.success(zipDestination))
        } catch {
            completeOnce(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeOnce(.failure(error))
        }
    }
}
