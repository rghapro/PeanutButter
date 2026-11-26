import Accelerate
import AVFoundation
import Foundation
import os

/// Compiles reference voice prompts, synthesizes fallback phrases via LuxTTS, caches 48 kHz WAVs
/// to disk, and serves thread-safe `SpokenPhraseData` buffers aligned to the perceptual vowel attack.
public final class VoiceCloneService: @unchecked Sendable {
    public static let shared = VoiceCloneService()

    public static let didFinishBackgroundPhraseNotification = Notification.Name("PeanutButter.VoiceCloneDidFinishBackgroundPhrase")

    public struct CompiledReferencePrompt: Sendable {
        public let packId: String
        public let samples24k: [Float]
        public let promptText: String
        public let packActiveRMS: Float
        public let fingerprint: String
        public var durationSeconds: Double { Double(samples24k.count) / 24_000.0 }
    }

    private let logger = Logger(subsystem: PeanutButterLog.subsystem, category: "VoiceCloneService")
    private let coreEngine = LuxTtsCoreEngine()
    private let lock = NSLock()
    private let synthLock = NSLock()
    private let cacheDirectory: URL

    private var memoryCache: [String: SpokenPhraseData] = [:]
    private var referenceCache: [String: CompiledReferencePrompt] = [:]
    private var inFlightDiskKeys: Set<String> = []

    public init(cacheDirectory: URL? = nil) {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = cacheDirectory
            ?? caches.appendingPathComponent("PeanutButterVoiceCloneCache_v1", isDirectory: true)
        try? fm.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache & Lifecycle Management

    public func invalidatePack(packId: String) {
        let safePrefix = sanitizeComponent(packId) + "_"
        lock.lock()
        referenceCache.removeValue(forKey: packId)
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(safePrefix) }
        lock.unlock()

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasPrefix(safePrefix) {
                try? fm.removeItem(at: url)
            }
        }
    }

    public func clearDiskAndMemoryCache() {
        lock.lock()
        memoryCache.removeAll()
        referenceCache.removeAll()
        inFlightDiskKeys.removeAll()
        lock.unlock()

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in files {
                try? fm.removeItem(at: url)
            }
        }
    }

    public func unloadAndClearCache(deleteModelFiles: Bool = false) {
        coreEngine.unloadModels()
        clearDiskAndMemoryCache()
        if deleteModelFiles {
            try? FileManager.default.removeItem(at: VoiceCloneModelManager.sharedModelDirectoryURL)
        }
    }

    // MARK: - Reference Prompt Compilation

    public func compileReferencePrompt(forPackId packId: String) -> CompiledReferencePrompt? {
        lock.lock()
        if let cached = referenceCache[packId] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let candidates: [(url: URL, transcript: String)]
        if let pack = CustomSampleLibraryManager.shared.guidePack(forId: packId) {
            candidates = buildPackReferenceCandidates(pack: pack)
        } else if packId.caseInsensitiveCompare("rita") == .orderedSame {
            guard AudioSampleBank.shared.hasSampledGuides else { return nil }
            candidates = AudioSampleBank.shared.ritaReferenceClipCandidates()
        } else {
            return nil
        }

        guard !candidates.isEmpty else { return nil }

        let maxSamples = Int(4.65 * 24_000.0) // strictly under LuxTtsConstants.maxPromptSeconds (5.0s)
        let trailingSilenceSamples = Int(0.12 * 24_000.0) // matches trailing period in promptText without bleeding into generation t=0
        let gapSamples = Int(0.065 * 24_000.0)
        var stitched: [Float] = []
        var activeRmsValues: [Float] = []
        var usedTranscripts: [String] = []
        var usedFilesSignature: [String] = [packId]
        var totalSpeechSamples = 0
        let fm = FileManager.default

        for candidate in candidates {
            guard let raw = loadMonoFloatSamples(from: candidate.url, targetSampleRate: 24_000.0) else {
                continue
            }
            let trimmed = trimSilence(raw, sampleRate: 24_000.0, thresholdDB: -40.0, marginMs: 10.0, fadeMs: 8.0)
            guard trimmed.count > 2_400 else { continue } // >= 100ms speech

            let clipRMS = Self.computeActiveRMS(trimmed, thresholdDB: -38.0)
            let gapNeeded = stitched.isEmpty ? 0 : gapSamples
            if stitched.count + gapNeeded + trimmed.count + trailingSilenceSamples > maxSamples {
                continue
            }

            if clipRMS > 0 { activeRmsValues.append(clipRMS) }
            if gapNeeded > 0 {
                stitched.append(contentsOf: repeatElement(Float(0), count: gapNeeded))
            }
            stitched.append(contentsOf: trimmed)
            totalSpeechSamples += trimmed.count
            usedTranscripts.append(candidate.transcript)

            let attrs = try? fm.attributesOfItem(atPath: candidate.url.path)
            let fSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int64(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
            usedFilesSignature.append("\(candidate.url.lastPathComponent):\(fSize):\(mtime)")
        }

        // Require at least ~1.0s of active spoken audio so duration-ratio estimation stays stable
        guard totalSpeechSamples >= 24_000, !usedTranscripts.isEmpty else {
            return nil
        }

        Self.normalizeActiveRMS(&stitched, desiredRMS: 0.12, peakCap: 0.85, thresholdDB: -38.0)
        stitched.append(contentsOf: repeatElement(Float(0), count: trailingSilenceSamples))
        let packActiveRMS = activeRmsValues.isEmpty
            ? 0.12
            : (activeRmsValues.reduce(0, +) / Float(activeRmsValues.count))
        let joined = usedTranscripts.joined(separator: ", ")
        let promptText = joined.first.map { $0.uppercased() + joined.dropFirst() + "." } ?? ""
        let fingerprint = fnv1aHex(usedFilesSignature.joined(separator: "|"))

        let compiled = CompiledReferencePrompt(
            packId: packId,
            samples24k: stitched,
            promptText: promptText,
            packActiveRMS: packActiveRMS,
            fingerprint: fingerprint
        )

        lock.lock()
        referenceCache[packId] = compiled
        lock.unlock()
        return compiled
    }

    private func buildPackReferenceCandidates(pack: CustomGuidePack) -> [(url: URL, transcript: String)] {
        let priorityOrder: [String] = [
            "bring it down",
            "key change up",
            "worship freely",
            "slowly build",
            "big ending",
            "pre chorus 1",
            "instrumental",
            "vocals only",
            "breakdown",
            "interlude",
            "key change down",
            "turnaround",
            "exhortation",
            "chorus 1",
            "bridge 1"
        ]

        let countInKeys = CustomSampleLibraryManager.standardCountInNormalizedKeys
        let availableKeys = pack.phraseFiles.keys.filter { !countInKeys.contains($0) }

        var orderedKeys: [String] = []
        var seen = Set<String>()

        for k in priorityOrder where pack.phraseFiles[k] != nil && !seen.contains(k) {
            orderedKeys.append(k)
            seen.insert(k)
        }

        let remainingMultiWord = availableKeys
            .filter { !seen.contains($0) && $0.contains(" ") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for k in remainingMultiWord {
            orderedKeys.append(k)
            seen.insert(k)
        }

        let remainingSingleWord = availableKeys
            .filter { !seen.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for k in remainingSingleWord {
            orderedKeys.append(k)
            seen.insert(k)
        }

        return orderedKeys.compactMap { key in
            guard let url = pack.fileURL(forNormalizedPhrase: key) else { return nil }
            let rawLabel = pack.displayLabel(forNormalizedPhrase: key)
            let spoken = Self.spokenTranscript(from: rawLabel)
            guard !spoken.isEmpty else { return nil }
            return (url, spoken)
        }
    }

    public static func spokenTranscript(from rawLabel: String) -> String {
        let numberWords: [String: String] = [
            "1": "one", "2": "two", "3": "three", "4": "four",
            "5": "five", "6": "six", "7": "seven", "8": "eight"
        ]
        var cleaned = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map { tok -> String in
            let w = String(tok).lowercased()
            return numberWords[w] ?? w
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Synchronous Phrase Resolution

    private static let diskCacheVersion = "v6"

    public func resolvePhraseSync(
        phrase: String,
        targetPackId: String,
        targetFormat: AVAudioFormat,
        modelDirectoryOverride: URL? = nil,
        allowCloningExistingPackPhrase: Bool = false,
        enqueueBackgroundIfMissing: Bool = true
    ) -> SpokenPhraseData? {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhrase.isEmpty else { return nil }

        // Never AI-clone or return cached clone WAVs for a phrase that already has a studio recording in the target pack.
        if !allowCloningExistingPackPhrase {
            if let existingStudio = CustomSampleLibraryManager.shared.getGuidePhraseSample(
                phrase: cleanPhrase,
                packId: targetPackId,
                targetFormat: targetFormat
            ) {
                return existingStudio
            }
            if targetPackId.caseInsensitiveCompare("rita") == .orderedSame,
               let legacyStudio = AudioSampleBank.shared.getRitaPhraseSample(
                   phrase: cleanPhrase,
                   targetFormat: targetFormat
               ) {
                return legacyStudio
            }
        }

        guard VoiceCloneModelManager.isPlatformSupported else { return nil }
        let modelDirectory: URL
        if let override = modelDirectoryOverride {
            guard VoiceCloneModelManager.areModelFilesComplete(in: override) else { return nil }
            modelDirectory = override
        } else {
            guard VoiceCloneModelManager.isSharedModelReady else { return nil }
            modelDirectory = VoiceCloneModelManager.sharedModelDirectoryURL
        }

        guard let ref = compileReferencePrompt(forPackId: targetPackId) else { return nil }

        let safePack = sanitizeComponent(targetPackId)
        let safePhrase = sanitizeComponent(cleanPhrase.lowercased())
        let diskKey = "\(safePack)_\(ref.fingerprint)_\(safePhrase)_\(Self.diskCacheVersion)"
        let memKey = "\(diskKey)_\(Int(targetFormat.sampleRate))_\(targetFormat.channelCount)"

        lock.lock()
        if let cached = memoryCache[memKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let wavURL = cacheDirectory.appendingPathComponent("\(diskKey).wav")
        if FileManager.default.fileExists(atPath: wavURL.path),
           let loaded = loadCachedPhraseData(at: wavURL, memKey: memKey, targetFormat: targetFormat) {
            return loaded
        }

        // Never block @MainActor with CoreML inference; optionally warm asynchronously instead
        if Thread.isMainThread {
            if enqueueBackgroundIfMissing {
                enqueueBackgroundWarm(
                    cleanPhrase: cleanPhrase,
                    ref: ref,
                    diskKey: diskKey,
                    wavURL: wavURL,
                    modelDirectory: modelDirectory
                )
            }
            return nil
        }

        synthLock.lock()
        defer { synthLock.unlock() }

        if !FileManager.default.fileExists(atPath: wavURL.path) {
            do {
                try synthesizeAndWriteWAV(
                    cleanPhrase: cleanPhrase,
                    ref: ref,
                    to: wavURL,
                    modelDirectory: modelDirectory
                )
            } catch {
                logger.error("VoiceClone synthesis failed for '\(cleanPhrase, privacy: .public)' (\(targetPackId, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        return loadCachedPhraseData(at: wavURL, memKey: memKey, targetFormat: targetFormat)
    }

    private func enqueueBackgroundWarm(
        cleanPhrase: String,
        ref: CompiledReferencePrompt,
        diskKey: String,
        wavURL: URL,
        modelDirectory: URL
    ) {
        lock.lock()
        let alreadyRunning = inFlightDiskKeys.contains(diskKey)
        if !alreadyRunning {
            inFlightDiskKeys.insert(diskKey)
        }
        lock.unlock()
        guard !alreadyRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.synthLock.lock()
            let shouldSynth = !FileManager.default.fileExists(atPath: wavURL.path)
            if shouldSynth {
                do {
                    try self.synthesizeAndWriteWAV(
                        cleanPhrase: cleanPhrase,
                        ref: ref,
                        to: wavURL,
                        modelDirectory: modelDirectory
                    )
                } catch {
                    self.logger.error("Background VoiceClone warm failed for '\(cleanPhrase, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
            self.synthLock.unlock()

            self.lock.lock()
            self.inFlightDiskKeys.remove(diskKey)
            self.lock.unlock()

            if FileManager.default.fileExists(atPath: wavURL.path) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.didFinishBackgroundPhraseNotification, object: self)
                }
            }
        }
    }

    private func loadCachedPhraseData(
        at wavURL: URL,
        memKey: String,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        guard let converted = AudioSampleBank.shared.loadAndConvertBuffer(at: wavURL, targetFormat: targetFormat) else {
            return nil
        }
        let onset = AudioSampleBank.shared.computePerceptualOnsetOffset(buffer: converted)
        let data = SpokenPhraseData(buffer: converted, onsetOffset: onset)
        lock.lock()
        memoryCache[memKey] = data
        lock.unlock()
        return data
    }

    private func synthesizeAndWriteWAV(
        cleanPhrase: String,
        ref: CompiledReferencePrompt,
        to destinationURL: URL,
        modelDirectory: URL
    ) throws {
        VoiceCloneModelManager.beginSharedSynthesis()
        defer { VoiceCloneModelManager.endSharedSynthesis() }
        let g2p = try coreEngine.englishG2p()
        let spokenInput = Self.spokenTranscriptForSynthesis(cleanPhrase)
        let promptPhonemes = g2p.phonemize(text: ref.promptText)
        let targetPhonemes = g2p.phonemize(text: spokenInput) + " ."

        var bestSamples: [Float]?
        var bestResidualPauses = Int.max
        var bestBoundaryArtifacts = Int.max
        var bestTailRMS: Float = Float.greatestFiniteMagnitude

        for seed in [UInt64(42), UInt64(43), UInt64(44)] {
            let res = try coreEngine.synthesizePhonemes(
                targetPhonemes,
                promptAudio24k: ref.samples24k,
                promptPhonemes: promptPhonemes,
                modelDirectory: modelDirectory,
                speed: 0.95,
                seed: seed,
                maxRedraws: 3
            )
            let tailRMS = Self.tailLast40msRMS(res.samples, sampleRate: 48_000.0)
            let boundaryArtifacts = Self.countBoundaryArtifactIslands(res.samples, sampleRate: 48_000.0)
            let isClean = (res.residualPauses == 0 && boundaryArtifacts == 0 && tailRMS <= 0.025)

            let better = (res.residualPauses < bestResidualPauses)
                || (res.residualPauses == bestResidualPauses && boundaryArtifacts < bestBoundaryArtifacts)
                || (res.residualPauses == bestResidualPauses && boundaryArtifacts == bestBoundaryArtifacts && tailRMS < bestTailRMS)
            if better || bestSamples == nil {
                bestSamples = res.samples
                bestResidualPauses = res.residualPauses
                bestBoundaryArtifacts = boundaryArtifacts
                bestTailRMS = tailRMS
            }
            if isClean {
                break
            }
        }

        guard let rawWinner = bestSamples else { return }
        var cleaned48k = Self.trimCleanHeadPreserveTail(rawWinner, sampleRate: 48_000.0)
        Self.loudnessMatch(&cleaned48k, targetRMS: ref.packActiveRMS, peakCap: 0.891, thresholdDB: -38.0)

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let tmpURL = cacheDirectory.appendingPathComponent("tmp_\(UUID().uuidString).wav")
        try Self.writeMono16BitWAV(samples: cleaned48k, sampleRate: 48_000.0, to: tmpURL)
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tmpURL, to: destinationURL)
    }

    // MARK: - DSP & Text Helpers

    public static func spokenTranscriptForSynthesis(_ rawPhrase: String) -> String {
        var s = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = s.last, !".!?".contains(last) {
            s.append(".")
        }
        return s
    }

    public static func tailLast40msRMS(_ samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let n = min(samples.count, max(1, Int(0.040 * sampleRate)))
        let start = samples.count - n
        var ms: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress! + start, 1, &ms, vDSP_Length(n))
        }
        return sqrt(ms)
    }

    private struct SpeechIsland {
        var startWin: Int
        var endWin: Int
        var maxRMS: Float
    }

    private struct SpeechIslandAnalysis {
        let winSize: Int
        let winCount: Int
        let keptStartWin: Int
        let keptEndWin: Int
        let droppedLeadingEndWin: Int
        let droppedTrailingStartWin: Int?
        let droppedCount: Int
    }

    private static func analyzeSpeechIslands(_ samples: [Float], sampleRate: Double) -> SpeechIslandAnalysis? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let winSize = max(1, Int(round(0.010 * sampleRate))) // 10ms RMS windows
        let winCount = samples.count / winSize
        guard winCount > 0 else { return nil }

        var winRMS = [Float](repeating: 0, count: winCount)
        var maxWinRMS: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let vLen = vDSP_Length(winSize)
            for w in 0..<winCount {
                var ms: Float = 0
                vDSP_measqv(base + w * winSize, 1, &ms, vLen)
                let rms = sqrt(ms)
                winRMS[w] = rms
                if rms > maxWinRMS { maxWinRMS = rms }
            }
        }
        guard maxWinRMS > 1e-5 else { return nil }

        let coreSpeechThresh = max(
            maxWinRMS * pow(Float(10.0), Float(-24.0) / 20.0),
            pow(Float(10.0), Float(-38.0) / 20.0)
        )
        let quietFloorThresh = pow(Float(10.0), Float(-46.0) / 20.0)
        let mergeGapWins = 8 // < 80ms gap joins stop-consonant closures cleanly

        var islands: [SpeechIsland] = []
        var curStart: Int? = nil
        var curMaxRMS: Float = 0
        for w in 0..<winCount {
            let rms = winRMS[w]
            if rms >= coreSpeechThresh {
                if curStart == nil {
                    curStart = w
                    curMaxRMS = rms
                } else if rms > curMaxRMS {
                    curMaxRMS = rms
                }
            } else if let s = curStart {
                if var prev = islands.last, s - prev.endWin < mergeGapWins {
                    prev.endWin = w
                    prev.maxRMS = max(prev.maxRMS, curMaxRMS)
                    islands[islands.count - 1] = prev
                } else {
                    islands.append(SpeechIsland(startWin: s, endWin: w, maxRMS: curMaxRMS))
                }
                curStart = nil
                curMaxRMS = 0
            }
        }
        if let s = curStart {
            if var prev = islands.last, s - prev.endWin < mergeGapWins {
                prev.endWin = winCount
                prev.maxRMS = max(prev.maxRMS, curMaxRMS)
                islands[islands.count - 1] = prev
            } else {
                islands.append(SpeechIsland(startWin: s, endWin: winCount, maxRMS: curMaxRMS))
            }
        }

        guard !islands.isEmpty else { return nil }

        var droppedLeadingEndWin = 0
        var droppedTrailingStartWin: Int? = nil
        var droppedCount = 0
        let weakLeadingThresh = max(
            maxWinRMS * pow(Float(10.0), Float(-14.0) / 20.0),
            pow(Float(10.0), Float(-30.0) / 20.0)
        )
        let weakTrailingThresh = max(
            maxWinRMS * pow(Float(10.0), Float(-16.0) / 20.0),
            pow(Float(10.0), Float(-34.0) / 20.0)
        )

        func gapIsQuiet(from startWin: Int, to endWin: Int) -> Bool {
            guard endWin > startWin else { return false }
            var sum: Float = 0
            var minVal = Float.greatestFiniteMagnitude
            for w in startWin..<endWin {
                let r = winRMS[w]
                sum += r
                if r < minVal { minVal = r }
            }
            let avg = sum / Float(endWin - startWin)
            return avg < quietFloorThresh || minVal < quietFloorThresh
        }

        while islands.count >= 2 {
            var didDrop = false

            let first = islands[0]
            let second = islands[1]
            let leadGapWin = second.startWin - first.endWin
            let leadDurWin = first.endWin - first.startWin
            if leadGapWin >= 7 && gapIsQuiet(from: first.endWin, to: second.startWin) {
                let isWeakLeading = first.maxRMS < weakLeadingThresh
                let isBoundaryBlip = first.startWin <= 6 && leadDurWin <= 14 && leadGapWin >= 12
                if isWeakLeading || isBoundaryBlip {
                    droppedLeadingEndWin = first.endWin
                    droppedCount += 1
                    islands.removeFirst()
                    didDrop = true
                }
            }

            if islands.count >= 2 {
                let last = islands[islands.count - 1]
                let prev = islands[islands.count - 2]
                let tailGapWin = last.startWin - prev.endWin
                let tailDurWin = last.endWin - last.startWin
                if tailGapWin >= 14 && gapIsQuiet(from: prev.endWin, to: last.startWin) {
                    let isDetachedTailNoise = tailGapWin >= 24 && tailDurWin <= 28
                    let isWeakTrailing = last.maxRMS < weakTrailingThresh
                    if isDetachedTailNoise || isWeakTrailing {
                        droppedTrailingStartWin = last.startWin
                        droppedCount += 1
                        islands.removeLast()
                        didDrop = true
                    }
                }
            }

            if !didDrop { break }
        }

        return SpeechIslandAnalysis(
            winSize: winSize,
            winCount: winCount,
            keptStartWin: islands[0].startWin,
            keptEndWin: islands[islands.count - 1].endWin,
            droppedLeadingEndWin: droppedLeadingEndWin,
            droppedTrailingStartWin: droppedTrailingStartWin,
            droppedCount: droppedCount
        )
    }

    public static func countBoundaryArtifactIslands(_ samples: [Float], sampleRate: Double) -> Int {
        analyzeSpeechIslands(samples, sampleRate: sampleRate)?.droppedCount ?? 0
    }

    public static func trimCleanHeadPreserveTail(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let analysis = analyzeSpeechIslands(samples, sampleRate: sampleRate) else {
            return samples
        }

        let subWin = max(1, Int(round(0.005 * sampleRate)))
        let leadFloorRMS = pow(Float(10.0), Float(-46.0) / 20.0)
        let tailFloorRMS = pow(Float(10.0), Float(-50.0) / 20.0)
        let minAllowedStart = min(samples.count, analysis.droppedLeadingEndWin * analysis.winSize)
        let maxAllowedEnd = min(samples.count, (analysis.droppedTrailingStartWin ?? analysis.winCount) * analysis.winSize)

        var headSample = analysis.keptStartWin * analysis.winSize
        for step in 0..<9 {
            let probeEnd = headSample - step * subWin
            let probeStart = probeEnd - subWin
            if probeStart < minAllowedStart { break }
            var ms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_measqv(ptr.baseAddress! + probeStart, 1, &ms, vDSP_Length(subWin))
            }
            if sqrt(ms) >= leadFloorRMS {
                headSample = probeStart
            } else {
                break
            }
        }

        var tailSample = min(maxAllowedEnd, analysis.keptEndWin * analysis.winSize)
        for step in 0..<20 {
            let probeStart = tailSample + step * subWin
            let probeEnd = probeStart + subWin
            if probeEnd > maxAllowedEnd { break }
            var ms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_measqv(ptr.baseAddress! + probeStart, 1, &ms, vDSP_Length(subWin))
            }
            if sqrt(ms) >= tailFloorRMS {
                tailSample = probeEnd
            } else {
                break
            }
        }

        let preRoll = Int(0.015 * sampleRate)
        let postRoll = Int(0.040 * sampleRate)
        let start = max(minAllowedStart, headSample - preRoll)
        let end = min(maxAllowedEnd, max(start + 1, tailSample + postRoll))
        if start >= end { return samples }

        var slice = Array(samples[start..<end])

        let fadeIn = min(slice.count / 6, Int(0.008 * sampleRate))
        if fadeIn > 1 {
            for i in 0..<fadeIn {
                let t = Float(i) / Float(fadeIn - 1)
                slice[i] *= 0.5 * (1.0 - cos(Float.pi * t))
            }
        }

        let fadeOut = min(slice.count / 4, Int(0.035 * sampleRate))
        if fadeOut > 1 {
            let base = slice.count - fadeOut
            for i in 0..<fadeOut {
                let t = Float(i) / Float(fadeOut - 1)
                let gain = 0.5 * (1.0 + cos(Float.pi * t))
                slice[base + i] *= gain
            }
        }
        return slice
    }

    public static func loudnessMatch(_ samples: inout [Float], targetRMS: Float, peakCap: Float, thresholdDB: Float) {
        let activeRMS = computeActiveRMS(samples, thresholdDB: thresholdDB)
        let peak = maxAbs(samples)
        if activeRMS > 1e-4 && peak > 0 {
            var gain = min(targetRMS / activeRMS, peakCap / peak)
            vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
        }
    }

    public static func normalizeActiveRMS(_ samples: inout [Float], desiredRMS: Float, peakCap: Float, thresholdDB: Float) {
        let activeRMS = computeActiveRMS(samples, thresholdDB: thresholdDB)
        let peak = maxAbs(samples)
        if activeRMS > 1e-4 && peak > 0 {
            var scale = min(desiredRMS / activeRMS, peakCap / peak)
            vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(samples.count))
        }
    }

    public static func computeActiveRMS(_ samples: [Float], thresholdDB: Float) -> Float {
        guard !samples.isEmpty else { return 0 }
        let threshold = pow(Float(10.0), thresholdDB / 20.0)
        var sumSq: Double = 0.0
        var activeCount = 0
        for s in samples where abs(s) >= threshold {
            sumSq += Double(s * s)
            activeCount += 1
        }
        guard activeCount > 0 else { return 0 }
        return Float(sqrt(sumSq / Double(activeCount)))
    }

    public static func maxAbs(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0.0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    private func loadMonoFloatSamples(from url: URL, targetSampleRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames),
              (try? file.read(into: inBuf)) != nil
        else { return nil }

        guard let monoInFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoInFormat, frameCapacity: inBuf.frameLength)
        else { return nil }
        monoBuf.frameLength = inBuf.frameLength

        if let chData = inBuf.floatChannelData, let dst = monoBuf.floatChannelData?[0] {
            let n = Int(inBuf.frameLength)
            if inFormat.channelCount == 1 {
                memcpy(dst, chData[0], n * MemoryLayout<Float>.size)
            } else {
                var half: Float = 0.5
                vDSP_vadd(chData[0], 1, chData[1], 1, dst, 1, vDSP_Length(n))
                vDSP_vsmul(dst, 1, &half, dst, 1, vDSP_Length(n))
            }
        }

        let ptr = monoBuf.floatChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: ptr, count: Int(monoBuf.frameLength)))
        if abs(inFormat.sampleRate - targetSampleRate) < 1.0 {
            return samples
        }
        return resampleMonoFloat(samples, fromRate: inFormat.sampleRate, toRate: targetSampleRate)
    }

    private func resampleMonoFloat(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        MasteringAudioResampler.resampleMonoFloat(samples, fromRate: fromRate, toRate: toRate) ?? samples
    }

    private func trimSilence(
        _ samples: [Float],
        sampleRate: Double,
        thresholdDB: Float,
        marginMs: Double,
        fadeMs: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let threshold = pow(Float(10.0), thresholdDB / 20.0)
        var firstIdx = 0
        while firstIdx < samples.count && abs(samples[firstIdx]) < threshold {
            firstIdx += 1
        }
        var lastIdx = samples.count - 1
        while lastIdx > firstIdx && abs(samples[lastIdx]) < threshold {
            lastIdx -= 1
        }
        if firstIdx >= lastIdx { return samples }

        let marginSamples = Int((marginMs / 1000.0) * sampleRate)
        let start = max(0, firstIdx - marginSamples)
        let end = min(samples.count, lastIdx + marginSamples + 1)
        var slice = Array(samples[start..<end])

        let fade = min(slice.count / 4, Int((fadeMs / 1000.0) * sampleRate))
        if fade > 1 {
            for i in 0..<fade {
                let w = Float(i) / Float(fade)
                slice[i] *= w
                slice[slice.count - 1 - i] *= w
            }
        }
        return slice
    }

    private static func writeMono16BitWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw LuxTtsError.inferenceFailed(stage: "WAV write", underlying: "buffer allocation failed")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        _ = samples.withUnsafeBufferPointer { sPtr in
            memcpy(buf.floatChannelData![0], sPtr.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let outFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try outFile.write(from: buf)
    }

    private func sanitizeComponent(_ s: String) -> String {
        let joined = s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        return joined.isEmpty ? "item" : joined
    }

    private func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
