import Foundation
import os

/// Manages the on-demand ~348 MB CoreML LuxTTS model bundle downloaded outside the app bundle.
@MainActor
public final class VoiceCloneModelManager: ObservableObject {
    public static let shared = VoiceCloneModelManager()

    nonisolated public static let didBecomeReadyNotification = Notification.Name("PeanutButter.VoiceCloneModelDidBecomeReady")

    nonisolated public static var isPlatformSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private final class AtomicBoolFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool = false
        func get() -> Bool { lock.withLock { value } }
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    }

    nonisolated public static let defaultAppSupportRootURL: URL = {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("PeanutButter", isDirectory: true)
    }()

    nonisolated public static let sharedModelDirectoryURL: URL = {
        defaultAppSupportRootURL
            .appendingPathComponent("VoiceModels", isDirectory: true)
            .appendingPathComponent("luxtts", isDirectory: true)
    }()

    nonisolated private static let sharedReadyFlag: AtomicBoolFlag = {
        let flag = AtomicBoolFlag()
        if isPlatformSupported && areModelFilesComplete(in: sharedModelDirectoryURL) {
            flag.set(true)
        }
        return flag
    }()

    nonisolated public static var isSharedModelReady: Bool {
        sharedReadyFlag.get()
    }

    public enum ModelState: Equatable, Sendable {
        case unsupportedIntel
        case notInstalled
        case downloading(progress: Double, downloadedMB: Double, totalMB: Double)
        case ready(sizeMB: Double)
        case failed(String)
    }

    private struct DownloadEntry: Sendable {
        let relativePath: String
        let expectedBytes: Int64
    }

    private struct HFTreeNode: Decodable {
        let path: String
        let type: String
        let size: Int64?
    }

    /// Fallback manifest matching `FluidInference/luxtts-coreml` (`gpu/` + `vocoder/` + tokenizer/config, ~347.7 MB).
    private static let fallbackManifest: [DownloadEntry] = [
        DownloadEntry(relativePath: "config.json", expectedBytes: 697),
        DownloadEntry(relativePath: "tokens.txt", expectedBytes: 2_570),
        DownloadEntry(relativePath: "gpu/TextEncoder.mlmodelc/analytics/coremldata.bin", expectedBytes: 243),
        DownloadEntry(relativePath: "gpu/TextEncoder.mlmodelc/coremldata.bin", expectedBytes: 408),
        DownloadEntry(relativePath: "gpu/TextEncoder.mlmodelc/model.mil", expectedBytes: 1_513_493),
        DownloadEntry(relativePath: "gpu/TextEncoder.mlmodelc/weights/weight.bin", expectedBytes: 8_486_088),
        DownloadEntry(relativePath: "gpu/FmDecoder.mlmodelc/analytics/coremldata.bin", expectedBytes: 243),
        DownloadEntry(relativePath: "gpu/FmDecoder.mlmodelc/coremldata.bin", expectedBytes: 504),
        DownloadEntry(relativePath: "gpu/FmDecoder.mlmodelc/model.mil", expectedBytes: 30_583_551),
        DownloadEntry(relativePath: "gpu/FmDecoder.mlmodelc/weights/weight.bin", expectedBytes: 237_665_992),
        DownloadEntry(relativePath: "vocoder/Vocoder282.mlmodelc/analytics/coremldata.bin", expectedBytes: 243),
        DownloadEntry(relativePath: "vocoder/Vocoder282.mlmodelc/coremldata.bin", expectedBytes: 370),
        DownloadEntry(relativePath: "vocoder/Vocoder282.mlmodelc/model.mil", expectedBytes: 114_953),
        DownloadEntry(relativePath: "vocoder/Vocoder282.mlmodelc/weights/weight.bin", expectedBytes: 34_407_998),
        DownloadEntry(relativePath: "vocoder/Vocoder555.mlmodelc/analytics/coremldata.bin", expectedBytes: 243),
        DownloadEntry(relativePath: "vocoder/Vocoder555.mlmodelc/coremldata.bin", expectedBytes: 370),
        DownloadEntry(relativePath: "vocoder/Vocoder555.mlmodelc/model.mil", expectedBytes: 115_072),
        DownloadEntry(relativePath: "vocoder/Vocoder555.mlmodelc/weights/weight.bin", expectedBytes: 34_827_326)
    ]

    nonisolated public static let requiredRelativePaths: [String] = [
        "config.json",
        "tokens.txt",
        "gpu/TextEncoder.mlmodelc/model.mil",
        "gpu/TextEncoder.mlmodelc/coremldata.bin",
        "gpu/TextEncoder.mlmodelc/weights/weight.bin",
        "gpu/FmDecoder.mlmodelc/model.mil",
        "gpu/FmDecoder.mlmodelc/coremldata.bin",
        "gpu/FmDecoder.mlmodelc/weights/weight.bin",
        "vocoder/Vocoder282.mlmodelc/model.mil",
        "vocoder/Vocoder282.mlmodelc/coremldata.bin",
        "vocoder/Vocoder282.mlmodelc/weights/weight.bin",
        "vocoder/Vocoder555.mlmodelc/model.mil",
        "vocoder/Vocoder555.mlmodelc/coremldata.bin",
        "vocoder/Vocoder555.mlmodelc/weights/weight.bin"
    ]

    @Published public private(set) var state: ModelState
    @Published public private(set) var activeSynthesisCount: Int = 0

    public var isSynthesizing: Bool { activeSynthesisCount > 0 }

    nonisolated public static func beginSharedSynthesis() {
        Task { @MainActor in
            shared.activeSynthesisCount += 1
        }
    }

    nonisolated public static func endSharedSynthesis() {
        Task { @MainActor in
            shared.activeSynthesisCount = max(0, shared.activeSynthesisCount - 1)
        }
    }

    private let logger = Logger(subsystem: PeanutButterLog.subsystem, category: "VoiceCloneModelManager")
    private let readyFlag = AtomicBoolFlag()
    private var downloadTask: Task<Void, Never>?

    nonisolated public let voiceModelsRootURL: URL
    nonisolated public let modelDirectoryURL: URL
    nonisolated private let stagingDirectoryURL: URL

    public init(baseSupportDirectory: URL? = nil) {
        let appSupport = baseSupportDirectory ?? Self.defaultAppSupportRootURL
        let root = appSupport.appendingPathComponent("VoiceModels", isDirectory: true)
        let modelDir = root.appendingPathComponent("luxtts", isDirectory: true)
        let stagingDir = root.appendingPathComponent("luxtts.downloading", isDirectory: true)

        self.voiceModelsRootURL = root
        self.modelDirectoryURL = modelDir
        self.stagingDirectoryURL = stagingDir

        if !Self.isPlatformSupported {
            self.state = .unsupportedIntel
            self.setModelReadyFlag(false)
        } else if Self.areModelFilesComplete(in: modelDir) {
            let sizeMB = Double(Self.directorySizeBytes(modelDir)) / 1_000_000.0
            self.state = .ready(sizeMB: sizeMB)
            self.setModelReadyFlag(true)
        } else {
            self.state = .notInstalled
            self.setModelReadyFlag(false)
        }
    }

    nonisolated public var isModelReady: Bool {
        readyFlag.get()
    }

    nonisolated private func setModelReadyFlag(_ value: Bool) {
        readyFlag.set(value)
        if modelDirectoryURL.path == Self.sharedModelDirectoryURL.path {
            Self.sharedReadyFlag.set(value)
        }
    }

    nonisolated public static func areModelFilesComplete(in dir: URL) -> Bool {
        let fm = FileManager.default
        for rel in requiredRelativePaths {
            let url = dir.appendingPathComponent(rel)
            guard fm.fileExists(atPath: url.path) else { return false }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size <= 0 { return false }
        }
        return true
    }

    nonisolated public static func directorySizeBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   vals.isRegularFile == true {
                    total += Int64(vals.fileSize ?? 0)
                }
            }
        }
        return total
    }

    public func refreshState() {
        if case .downloading = state { return }
        guard Self.isPlatformSupported else {
            setModelReadyFlag(false)
            state = .unsupportedIntel
            return
        }
        if Self.areModelFilesComplete(in: modelDirectoryURL) {
            setModelReadyFlag(true)
            let sizeMB = Double(Self.directorySizeBytes(modelDirectoryURL)) / 1_000_000.0
            state = .ready(sizeMB: sizeMB)
        } else {
            setModelReadyFlag(false)
            state = .notInstalled
        }
    }

    public func startDownload() {
        guard Self.isPlatformSupported else {
            state = .unsupportedIntel
            return
        }
        if case .downloading = state { return }
        if Self.areModelFilesComplete(in: modelDirectoryURL) {
            setModelReadyFlag(true)
            let sizeMB = Double(Self.directorySizeBytes(modelDirectoryURL)) / 1_000_000.0
            state = .ready(sizeMB: sizeMB)
            return
        }

        downloadTask?.cancel()
        state = .downloading(progress: 0.0, downloadedMB: 0.0, totalMB: 348.0)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownload()
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
        refreshState()
    }

    public func deleteModel() {
        downloadTask?.cancel()
        downloadTask = nil
        VoiceCloneService.shared.unloadAndClearCache(deleteModelFiles: true)
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDirectoryURL)
        try? fm.removeItem(at: modelDirectoryURL)
        setModelReadyFlag(false)
        state = Self.isPlatformSupported ? .notInstalled : .unsupportedIntel
    }

    public func clearClonedPhraseCache() {
        VoiceCloneService.shared.clearDiskAndMemoryCache()
    }

    // MARK: - Download Implementation

    private func performDownload() async {
        let fm = FileManager.default
        var activeDownloader: ConcurrentFileDownloader?
        do {
            try fm.createDirectory(at: voiceModelsRootURL, withIntermediateDirectories: true)
            try? fm.removeItem(at: stagingDirectoryURL)
            try fm.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)

            let entries = await resolveDownloadManifest()
            let sortedEntries = entries.sorted { $0.expectedBytes > $1.expectedBytes }
            let totalBytes = max(Int64(1), sortedEntries.reduce(0) { $0 + max(0, $1.expectedBytes) })
            let totalMB = Double(totalBytes) / 1_000_000.0

            state = .downloading(progress: 0.0, downloadedMB: 0.0, totalMB: totalMB)

            let downloader = ConcurrentFileDownloader { [weak self] downloadedBytes in
                let fraction = min(0.995, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
                let downloadedMB = Double(downloadedBytes) / 1_000_000.0
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .downloading = self.state {
                        self.state = .downloading(
                            progress: fraction,
                            downloadedMB: downloadedMB,
                            totalMB: totalMB
                        )
                    }
                }
            }
            activeDownloader = downloader

            let stagingRoot = self.stagingDirectoryURL
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var nextIndex = 0
                    let maxConcurrent = min(4, sortedEntries.count)

                    func enqueueNext() {
                        guard nextIndex < sortedEntries.count else { return }
                        let entry = sortedEntries[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try Task.checkCancellation()
                            let encodedPath = entry.relativePath
                                .split(separator: "/")
                                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                                .joined(separator: "/")
                            guard let url = URL(string: "https://huggingface.co/FluidInference/luxtts-coreml/resolve/main/\(encodedPath)") else {
                                throw NSError(
                                    domain: "VoiceCloneModelManager",
                                    code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid download URL for \(entry.relativePath)"]
                                )
                            }
                            let destURL = stagingRoot.appendingPathComponent(entry.relativePath)
                            try await downloader.download(
                                url: url,
                                relativePath: entry.relativePath,
                                expectedBytes: entry.expectedBytes,
                                to: destURL
                            )
                        }
                    }

                    for _ in 0..<maxConcurrent {
                        enqueueNext()
                    }

                    while try await group.next() != nil {
                        enqueueNext()
                    }
                }
            } onCancel: {
                downloader.cancelAll()
            }
            downloader.finishAndInvalidate()
            activeDownloader = nil

            try Task.checkCancellation()
            guard Self.areModelFilesComplete(in: stagingDirectoryURL) else {
                throw NSError(
                    domain: "VoiceCloneModelManager",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model files are incomplete."]
                )
            }

            if fm.fileExists(atPath: modelDirectoryURL.path) {
                try fm.removeItem(at: modelDirectoryURL)
            }
            try fm.moveItem(at: stagingDirectoryURL, to: modelDirectoryURL)

            setModelReadyFlag(true)
            let finalSizeMB = Double(Self.directorySizeBytes(modelDirectoryURL)) / 1_000_000.0
            state = .ready(sizeMB: finalSizeMB)
            downloadTask = nil
            logger.info("LuxTTS model ready (\(String(format: "%.1f", finalSizeMB)) MB)")
            NotificationCenter.default.post(name: Self.didBecomeReadyNotification, object: self)
        } catch is CancellationError {
            activeDownloader?.cancelAll()
            try? fm.removeItem(at: stagingDirectoryURL)
            downloadTask = nil
            refreshState()
        } catch {
            activeDownloader?.cancelAll()
            try? fm.removeItem(at: stagingDirectoryURL)
            setModelReadyFlag(false)
            downloadTask = nil
            state = .failed(error.localizedDescription)
            logger.error("LuxTTS download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveDownloadManifest() async -> [DownloadEntry] {
        guard let treeURL = URL(string: "https://huggingface.co/api/models/FluidInference/luxtts-coreml/tree/main?recursive=true") else {
            return Self.fallbackManifest
        }
        var req = URLRequest(url: treeURL)
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return Self.fallbackManifest
            }
            let nodes = try JSONDecoder().decode([HFTreeNode].self, from: data)
            let filtered = nodes.compactMap { node -> DownloadEntry? in
                guard node.type == "file" else { return nil }
                let p = node.path
                let keep = (p == "config.json" || p == "tokens.txt" || p.hasPrefix("gpu/") || p.hasPrefix("vocoder/"))
                guard keep else { return nil }
                return DownloadEntry(relativePath: p, expectedBytes: max(1, node.size ?? 1))
            }
            let pathSet = Set(filtered.map(\.relativePath))
            let hasAllRequired = Self.requiredRelativePaths.allSatisfy { pathSet.contains($0) }
            if hasAllRequired && !filtered.isEmpty {
                return filtered.sorted { $0.relativePath < $1.relativePath }
            }
        } catch {
            logger.info("HF tree API lookup fell back to static manifest: \(error.localizedDescription, privacy: .public)")
        }
        return Self.fallbackManifest
    }
}

private final class ConcurrentFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct TaskState {
        let relativePath: String
        let destURL: URL
        let expectedBytes: Int64
        var continuation: CheckedContinuation<Void, Error>?
        var httpError: Error?
        var moveError: Error?
    }

    private final class TaskCancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var task: URLSessionDownloadTask?

        func attach(_ downloadTask: URLSessionDownloadTask) -> Bool {
            lock.lock()
            let wasCancelled = cancelled
            if !wasCancelled {
                task = downloadTask
            }
            lock.unlock()
            if wasCancelled {
                downloadTask.cancel()
                return false
            }
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            task = nil
            lock.unlock()
            current?.cancel()
        }
    }

    private let onProgress: @Sendable (Int64) -> Void
    private let stateLock = NSLock()
    private var tasks: [Int: TaskState] = [:]
    private var activeDownloadTasks: [Int: URLSessionDownloadTask] = [:]
    private var bytesByPath: [String: Int64] = [:]
    private var lastProgressTick: CFTimeInterval = 0
    private var isCancelled = false
    private var session: URLSession!

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true

        let queue = OperationQueue()
        queue.name = "PeanutButter.VoiceCloneModelDownloader"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func download(url: URL, relativePath: String, expectedBytes: Int64, to destURL: URL) async throws {
        try Task.checkCancellation()
        let box = TaskCancelBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var request = URLRequest(url: url)
                request.timeoutInterval = 120

                let downloadTask = session.downloadTask(with: request)
                let taskID = downloadTask.taskIdentifier

                var rejectCancelled = false
                stateLock.lock()
                if self.isCancelled || !box.attach(downloadTask) {
                    rejectCancelled = true
                } else {
                    tasks[taskID] = TaskState(
                        relativePath: relativePath,
                        destURL: destURL,
                        expectedBytes: expectedBytes,
                        continuation: continuation
                    )
                    activeDownloadTasks[taskID] = downloadTask
                }
                stateLock.unlock()

                if rejectCancelled {
                    downloadTask.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                downloadTask.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    func finishAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    func cancelAll() {
        stateLock.lock()
        isCancelled = true
        let active = Array(activeDownloadTasks.values)
        stateLock.unlock()

        for task in active {
            task.cancel()
        }
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        var totalToReport: Int64?

        stateLock.lock()
        if !isCancelled, let state = tasks[taskID] {
            bytesByPath[state.relativePath] = max(0, totalBytesWritten)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgressTick >= 0.10 {
                lastProgressTick = now
                totalToReport = bytesByPath.values.reduce(0, +)
            }
        }
        stateLock.unlock()

        if let totalToReport {
            onProgress(totalToReport)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier

        stateLock.lock()
        let taskState = tasks[taskID]
        let cancelled = isCancelled
        stateLock.unlock()

        guard !cancelled, let taskState else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let err = NSError(
                domain: "VoiceCloneModelManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) downloading \(taskState.relativePath)"]
            )
            stateLock.lock()
            tasks[taskID]?.httpError = err
            stateLock.unlock()
            return
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: taskState.destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: taskState.destURL.path) {
                try fm.removeItem(at: taskState.destURL)
            }
            try fm.moveItem(at: location, to: taskState.destURL)

            let attrs = try? fm.attributesOfItem(atPath: taskState.destURL.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? taskState.expectedBytes

            stateLock.lock()
            bytesByPath[taskState.relativePath] = max(fileSize, taskState.expectedBytes)
            lastProgressTick = CFAbsoluteTimeGetCurrent()
            let totalDownloaded = bytesByPath.values.reduce(0, +)
            stateLock.unlock()

            onProgress(totalDownloaded)
        } catch {
            stateLock.lock()
            tasks[taskID]?.moveError = error
            stateLock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier

        stateLock.lock()
        let removed = tasks.removeValue(forKey: taskID)
        activeDownloadTasks.removeValue(forKey: taskID)
        let cancelled = isCancelled
        stateLock.unlock()

        guard let continuation = removed?.continuation else { return }

        if cancelled || (error as NSError?)?.code == NSURLErrorCancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let httpError = removed?.httpError {
            continuation.resume(throwing: httpError)
        } else if let moveError = removed?.moveError {
            continuation.resume(throwing: moveError)
        } else {
            continuation.resume()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        stateLock.lock()
        let remaining = Array(tasks.values)
        tasks.removeAll()
        activeDownloadTasks.removeAll()
        stateLock.unlock()

        let err = error ?? CancellationError()
        for item in remaining {
            item.continuation?.resume(throwing: err)
        }
    }
}
