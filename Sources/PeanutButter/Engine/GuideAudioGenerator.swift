import Foundation
import AVFoundation

/// Synthesizes sample-accurate spoken Guide audio tracks with count-ins, section cues, and directional cues
public final class GuideAudioGenerator: @unchecked Sendable {
    public static let shared = GuideAudioGenerator()
    
    public typealias SpokenPhraseData = PeanutButter.SpokenPhraseData
    
    // In-memory cache of synthesized speech audio buffers keyed by "[voice]_[phrase]"
    private var speechCache: [String: SpokenPhraseData] = [:]
    private let cacheLock = NSLock()
    
    private let cacheDirectory: URL
    
    public init() {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = caches.appendingPathComponent("PeanutButterGuideSpeech_v3", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Clean up legacy caches to guarantee fresh synthesis with slow tempo & neural Siri
        try? fileManager.removeItem(at: caches.appendingPathComponent("PeanutButterGuideSpeech", isDirectory: true))
        try? fileManager.removeItem(at: caches.appendingPathComponent("PeanutButterGuideSpeech_v2", isDirectory: true))
    }
    
    /// Siri voice aliases mapping directly to real macOS AVSpeechSynthesisVoice identifiers
    private static let siriVoiceKeyMap: [String: String] = [
        "voice 1": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "voice 2": "com.apple.ttsbundle.siri_aaron_en-US_compact",
        "voice 3": "com.apple.ttsbundle.siri_martha_en-GB_compact",
        "voice 4": "com.apple.ttsbundle.siri_arthur_en-GB_compact",
        "voice 5": "com.apple.ttsbundle.siri_catherine_en-AU_compact",
        "voice 6": "com.apple.ttsbundle.siri_gordon_en-AU_compact",
        "siri voice 1": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "siri voice 2": "com.apple.ttsbundle.siri_aaron_en-US_compact",
        "siri voice 3": "com.apple.ttsbundle.siri_martha_en-GB_compact",
        "siri voice 4": "com.apple.ttsbundle.siri_arthur_en-GB_compact",
        "siri voice 5": "com.apple.ttsbundle.siri_catherine_en-AU_compact",
        "siri voice 6": "com.apple.ttsbundle.siri_gordon_en-AU_compact",
        "siri 1 (us female)": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "siri 2 (us male)": "com.apple.ttsbundle.siri_aaron_en-US_compact",
        "siri 3 (uk female)": "com.apple.ttsbundle.siri_martha_en-GB_compact",
        "siri 4 (uk male)": "com.apple.ttsbundle.siri_arthur_en-GB_compact",
        "siri 5 (au female)": "com.apple.ttsbundle.siri_catherine_en-AU_compact",
        "siri 6 (au male)": "com.apple.ttsbundle.siri_gordon_en-AU_compact",
        "quinn": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "nora": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "damon": "com.apple.ttsbundle.siri_aaron_en-US_compact",
        "aaron": "com.apple.ttsbundle.siri_aaron_en-US_compact",
        "simone": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "nicky": "com.apple.ttsbundle.siri_nicky_en-US_compact",
        "martha": "com.apple.ttsbundle.siri_martha_en-GB_compact",
        "arthur": "com.apple.ttsbundle.siri_arthur_en-GB_compact",
        "catherine": "com.apple.ttsbundle.siri_catherine_en-AU_compact",
        "gordon": "com.apple.ttsbundle.siri_gordon_en-AU_compact",
        "zoe": "com.apple.voice.premium.en-US.Zoe",
        "female": "com.apple.voice.compact.en-US.Samantha",
        "samantha": "com.apple.voice.compact.en-US.Samantha",
        "male": "com.apple.voice.compact.en-GB.Daniel",
        "daniel": "com.apple.voice.compact.en-GB.Daniel"
    ]
    
    /// Resolves any GuideVoice to an installed English AVSpeechSynthesisVoice
    public func resolveSystemVoice(for voice: GuideVoice) -> AVSpeechSynthesisVoice? {
        let key = voice.rawValue
        let lower = key.lowercased()
        
        // 1. Direct alias / preset match
        if let mapped = Self.siriVoiceKeyMap[lower], let v = AVSpeechSynthesisVoice(identifier: mapped) {
            return v
        }
        
        // 2. Direct identifier match
        if let direct = AVSpeechSynthesisVoice(identifier: key) {
            return direct
        }
        
        // 3. Search English voices only (avoids French Daniel, German Helena, etc.)
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: "en") }
        if let byName = englishVoices.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return byName
        }
        if let byIdSub = englishVoices.first(where: { $0.identifier.localizedCaseInsensitiveContains(key) }) {
            return byIdSub
        }
        
        // 4. Default fallback to Samantha
        return AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
    
    /// Returns the system voice identifier matching the requested GuideVoice
    public func systemVoiceIdentifier(for voice: GuideVoice) -> String {
        return resolveSystemVoice(for: voice)?.identifier ?? voice.rawValue
    }
    
    /// Returns the human-readable system voice name
    public func systemVoiceName(for voice: GuideVoice) -> String {
        return resolveSystemVoice(for: voice)?.name ?? voice.rawValue
    }
    
    /// Returns formatted display name for the voice (e.g. "Rita", "Zoe (Premium)", "Nicky (Siri)", "Samantha")
    public func displayName(for voice: GuideVoice) -> String {
        if let customId = voice.customPackId {
            return CustomSampleLibraryManager.shared.guidePack(forId: customId)?.name ?? "Custom Guide"
        }
        let key = voice.rawValue.lowercased()
        if key == "rita" {
            return "Rita"
        } else if key.contains("nicky") || key == "voice 1" || key == "siri voice 1" || key == "quinn" || key == "nora" {
            return "Nicky (Siri)"
        } else if key.contains("aaron") || key == "voice 2" || key == "siri voice 2" || key == "damon" {
            return "Aaron (Siri)"
        } else if key.contains("martha") || key == "voice 3" {
            return "Martha (Siri)"
        } else if key.contains("arthur") || key == "voice 4" {
            return "Arthur (Siri)"
        } else if key.contains("catherine") || key == "voice 5" {
            return "Catherine (Siri)"
        } else if key.contains("gordon") || key == "voice 6" {
            return "Gordon (Siri)"
        } else if key.contains("zoe") {
            return "Zoe (Premium)"
        } else if key.contains("samantha") || key == "female" {
            return "Samantha"
        } else if key.contains("daniel") || key == "male" {
            return "Daniel"
        }
        
        if let v = resolveSystemVoice(for: voice) {
            let isSiri = v.identifier.contains("siri")
            if isSiri {
                return "\(v.name) (Siri)"
            } else if v.quality == .premium {
                return "\(v.name) (Premium)"
            } else if v.quality == .enhanced {
                return "\(v.name) (Enhanced)"
            } else {
                return v.name
            }
        }
        
        return voice.rawValue
    }
    
    /// Returns downloaded and installed English voices on the user's macOS system
    public func installedVoiceList() -> [InstalledVoiceInfo] {
        var list: [InstalledVoiceInfo] = []
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: "en") }
        
        // 1. Siri Voices
        let siriVoices = all.filter { $0.identifier.contains("siri") }
        for v in siriVoices {
            list.append(InstalledVoiceInfo(
                id: v.identifier,
                name: "\(v.name) (Siri)",
                language: v.language,
                localizedLanguage: v.language == "en-US" ? "American" : (v.language == "en-GB" ? "British" : "Australian"),
                qualityRaw: 3,
                isSiri: true,
                isNovelty: false
            ))
        }
        
        // 2. Premium Neural Natural Voices (e.g. Zoe)
        let premiumVoices = all.filter { $0.quality == .premium && !$0.identifier.contains("siri") }
        for v in premiumVoices {
            list.append(InstalledVoiceInfo(
                id: v.identifier,
                name: "\(v.name) (Premium)",
                language: v.language,
                localizedLanguage: "American",
                qualityRaw: 3,
                isSiri: false,
                isNovelty: false
            ))
        }
        
        // 3. Popular Standard / Classic Voices (Samantha, Daniel, Karen, Moira, Rishi, Tessa)
        let classicVoices = all.filter {
            $0.quality != .premium &&
            !$0.identifier.contains("siri") &&
            !$0.identifier.contains("eloquence") &&
            !$0.identifier.contains(".speech.synthesis.voice.")
        }
        for v in classicVoices {
            let locLang = v.language == "en-US" ? "American" : (v.language == "en-GB" ? "British" : (v.language == "en-AU" ? "Australian" : "English"))
            let name = v.quality == .enhanced ? "\(v.name) (Enhanced)" : v.name
            list.append(InstalledVoiceInfo(
                id: v.identifier,
                name: name,
                language: v.language,
                localizedLanguage: locLang,
                qualityRaw: 1,
                isSiri: false,
                isNovelty: false
            ))
        }
        
        // 4. Other English Voices (Eloquence & System)
        let others = all.filter { cand in !list.contains(where: { $0.id == cand.identifier }) }
        for v in others {
            let isNovelty = v.identifier.contains(".speech.synthesis.voice.")
            list.append(InstalledVoiceInfo(
                id: v.identifier,
                name: v.name,
                language: v.language,
                localizedLanguage: "English",
                qualityRaw: v.quality.rawValue,
                isSiri: false,
                isNovelty: isNovelty
            ))
        }
        
        return list
    }
    
    private final class UtteranceCompletionBox: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [AVAudioPCMBuffer] = []
        private var finished = false
        private let onComplete: ([AVAudioPCMBuffer]) -> Void

        init(onComplete: @escaping ([AVAudioPCMBuffer]) -> Void) {
            self.onComplete = onComplete
            super.init()
        }

        func appendBuffer(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                finish()
                return
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else {
                return
            }
            copy.frameLength = pcm.frameLength
            for c in 0..<Int(pcm.format.channelCount) {
                if let src = pcm.floatChannelData?[c], let dst = copy.floatChannelData?[c] {
                    memcpy(dst, src, Int(pcm.frameLength) * MemoryLayout<Float>.size)
                }
            }
            lock.lock()
            let ignore = finished
            if !ignore {
                chunks.append(copy)
            }
            lock.unlock()
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let collected = chunks
            chunks.removeAll(keepingCapacity: false)
            lock.unlock()
            onComplete(collected)
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            finish()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            finish()
        }
    }

    private static func combineSpeechChunks(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard !chunks.isEmpty else { return nil }
        let format = chunks[0].format
        let totalFrames = chunks.reduce(0) { $0 + $1.frameLength }
        guard totalFrames > 0, let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return nil
        }
        combined.frameLength = totalFrames

        var offset: AVAudioFrameCount = 0
        for chunk in chunks {
            for c in 0..<Int(format.channelCount) {
                if let src = chunk.floatChannelData?[c], let dst = combined.floatChannelData?[c] {
                    memcpy(dst.advanced(by: Int(offset)), src, Int(chunk.frameLength) * MemoryLayout<Float>.size)
                }
            }
            offset += chunk.frameLength
        }
        return combined
    }

    /// Async neural speech synthesis using `AVSpeechSynthesizerDelegate` + `withCheckedContinuation`
    /// without blocking or recursively spinning `RunLoop.current`.
    public func synthesizeWithAVSpeechAsync(phrase: String, voice: GuideVoice) async -> AVAudioPCMBuffer? {
        guard let avVoice = resolveSystemVoice(for: voice) else { return nil }
        let collectedChunks: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let synthesizer = AVSpeechSynthesizer()
                let utterance = AVSpeechUtterance(string: phrase)
                utterance.voice = avVoice
                utterance.rate = 0.46

                var boxRef: UtteranceCompletionBox?
                let box = UtteranceCompletionBox { chunks in
                    synthesizer.delegate = nil
                    boxRef = nil
                    _ = synthesizer
                    continuation.resume(returning: chunks)
                }
                boxRef = box
                synthesizer.delegate = box

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4.0) { [weak box] in
                    box?.finish()
                }

                synthesizer.write(utterance) { buffer in
                    boxRef?.appendBuffer(buffer)
                }
            }
        }
        return Self.combineSpeechChunks(collectedChunks)
    }

    /// Synthesizes speech using AVSpeechSynthesizer without spinning `RunLoop.current`.
    private func synthesizeWithAVSpeech(phrase: String, voice: GuideVoice) -> AVAudioPCMBuffer? {
        // Never spin Main RunLoop recursively; main-thread callers use pre-cached WAVs or fast `say` fallback
        guard !Thread.isMainThread else { return nil }
        guard let avVoice = resolveSystemVoice(for: voice) else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var collectedChunks: [AVAudioPCMBuffer] = []

        DispatchQueue.main.async {
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = avVoice
            utterance.rate = 0.46

            var boxRef: UtteranceCompletionBox?
            let box = UtteranceCompletionBox { chunks in
                collectedChunks = chunks
                synthesizer.delegate = nil
                boxRef = nil
                _ = synthesizer
                semaphore.signal()
            }
            boxRef = box
            synthesizer.delegate = box

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4.0) { [weak box] in
                box?.finish()
            }

            synthesizer.write(utterance) { buffer in
                boxRef?.appendBuffer(buffer)
            }
        }

        _ = semaphore.wait(timeout: .now() + 4.2)
        return Self.combineSpeechChunks(collectedChunks)
    }
    
    private func resolveFallbackPhrase(
        _ cleanPhrase: String,
        fallbackVoice: GuideVoice,
        allowRita: Bool,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        let isRitaFallback = fallbackVoice == .rita || fallbackVoice.rawValue.caseInsensitiveCompare("rita") == .orderedSame
        if let fbPackId = fallbackVoice.customPackId,
           let packSample = CustomSampleLibraryManager.shared.getGuidePhraseSample(
               phrase: cleanPhrase,
               packId: fbPackId,
               targetFormat: targetFormat
           ) {
            return packSample
        }
        let primaryFallback: GuideVoice
        if fallbackVoice.isCustom || (isRitaFallback && !allowRita) {
            primaryFallback = .zoe
        } else {
            primaryFallback = fallbackVoice
        }
        
        if let synth = getOrSynthesizePhrase(cleanPhrase, voice: primaryFallback, fallbackVoice: .zoe, targetFormat: targetFormat) {
            return synth
        }
        
        let secondaryVoices: [GuideVoice] = [.zoe, GuideVoice(rawValue: "Samantha"), GuideVoice(rawValue: "system")]
        for fb in secondaryVoices {
            if let synth = getOrSynthesizePhrase(cleanPhrase, voice: fb, fallbackVoice: fb, targetFormat: targetFormat) {
                return synth
            }
        }
        return nil
    }
    
    /// Synthesizes or retrieves a cached spoken audio buffer for a given phrase and voice.
    /// When voice is Rita, queries pre-recorded audio from AudioSampleBank; if a phrase is missing (e.g. custom cue),
    /// falls back to synthesizing via `fallbackVoice`.
    public func getOrSynthesizePhrase(
        _ phrase: String,
        voice: GuideVoice,
        fallbackVoice: GuideVoice = .zoe,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhrase.isEmpty else { return nil }
        
        // 0. User & Included Custom Guide Voice sample pack handler
        if let customPackId = voice.customPackId {
            if let customSample = CustomSampleLibraryManager.shared.getGuidePhraseSample(
                phrase: cleanPhrase,
                packId: customPackId,
                targetFormat: targetFormat
            ) {
                return customSample
            }
            if CustomSampleLibraryManager.shared.guidePack(forId: customPackId)?.isBundled == true,
               let userSample = CustomSampleLibraryManager.shared.getAnyUserCustomPhraseSample(
                   phrase: cleanPhrase,
                   targetFormat: targetFormat
               ) {
                return userSample
            }
            return resolveFallbackPhrase(cleanPhrase, fallbackVoice: fallbackVoice, allowRita: true, targetFormat: targetFormat)
        }
        
        // 1. Pre-recorded Rita voice handler
        if voice == .rita || voice.rawValue.caseInsensitiveCompare("rita") == .orderedSame {
            if let ritaSample = AudioSampleBank.shared.getRitaPhraseSample(phrase: cleanPhrase, targetFormat: targetFormat) {
                return ritaSample
            }
            if let userSample = CustomSampleLibraryManager.shared.getAnyUserCustomPhraseSample(
                phrase: cleanPhrase,
                targetFormat: targetFormat
            ) {
                return userSample
            }
            let defVoice = CustomSampleLibraryManager.shared.defaultGuideVoice
            if defVoice != .rita && defVoice.rawValue.caseInsensitiveCompare("rita") != .orderedSame {
                if let defSample = getOrSynthesizePhrase(cleanPhrase, voice: defVoice, fallbackVoice: fallbackVoice, targetFormat: targetFormat) {
                    return defSample
                }
            }
            return resolveFallbackPhrase(cleanPhrase, fallbackVoice: fallbackVoice, allowRita: false, targetFormat: targetFormat)
        }
        
        let voiceId = systemVoiceIdentifier(for: voice)
        let cacheKey = "\(voiceId)_\(cleanPhrase.lowercased())"
        
        cacheLock.lock()
        if let cached = speechCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        // Check disk cache
        let safeVoiceId = voiceId
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let safeFilename = cleanPhrase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let wavURL = cacheDirectory.appendingPathComponent("\(safeVoiceId)_\(safeFilename).wav")
        
        var fileBuffer: AVAudioPCMBuffer? = nil
        
        if FileManager.default.fileExists(atPath: wavURL.path),
           let file = try? AVAudioFile(forReading: wavURL) {
            let frameCount = AVAudioFrameCount(file.length)
            if frameCount > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) {
                if (try? file.read(into: buf)) != nil && buf.frameLength > 0 {
                    fileBuffer = buf
                } else {
                    try? FileManager.default.removeItem(at: wavURL)
                }
            } else {
                try? FileManager.default.removeItem(at: wavURL)
            }
        }
        
        // If not cached on disk, synthesize via AVSpeechSynthesizer (neural Siri / natural TTS)
        if fileBuffer == nil {
            if let synthBuf = synthesizeWithAVSpeech(phrase: cleanPhrase, voice: voice) {
                fileBuffer = synthBuf
                try? FileManager.default.removeItem(at: wavURL)
                if let file = try? AVAudioFile(forWriting: wavURL, settings: synthBuf.format.settings) {
                    try? file.write(from: synthBuf)
                }
            } else {
                // Fallback to legacy say CLI with relaxed speech rate (160 wpm)
                let voiceName = systemVoiceName(for: voice)
                try? FileManager.default.removeItem(at: wavURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", voiceName, "-r", "160", "--file-format=WAVE", "--data-format=LEI16", "-o", wavURL.path, cleanPhrase]
                try? process.run()
                process.waitUntilExit()
                
                if let file = try? AVAudioFile(forReading: wavURL) {
                    let frameCount = AVAudioFrameCount(file.length)
                    if frameCount > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) {
                        try? file.read(into: buf)
                        if buf.frameLength > 0 {
                            fileBuffer = buf
                        }
                    }
                }
                
                // Fallback to macOS system default TTS without -v if specific voice failed
                if fileBuffer == nil {
                    try? FileManager.default.removeItem(at: wavURL)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    p.arguments = ["-r", "160", "--file-format=WAVE", "--data-format=LEI16", "-o", wavURL.path, cleanPhrase]
                    try? p.run()
                    p.waitUntilExit()
                    
                    if let file = try? AVAudioFile(forReading: wavURL) {
                        let frameCount = AVAudioFrameCount(file.length)
                        if frameCount > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) {
                            try? file.read(into: buf)
                            if buf.frameLength > 0 {
                                fileBuffer = buf
                            }
                        }
                    }
                }
            }
        }
        
        guard let sourceBuffer = fileBuffer else { return nil }
        
        // Resample/format convert if format differs
        let normalizedBuffer: AVAudioPCMBuffer
        if sourceBuffer.format == targetFormat {
            normalizedBuffer = sourceBuffer
        } else if let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) {
            let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * (targetFormat.sampleRate / sourceBuffer.format.sampleRate) + 2048)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }
            var error: NSError?
            var isConsumed = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if !isConsumed {
                    isConsumed = true
                    outStatus.pointee = .haveData
                    return sourceBuffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            normalizedBuffer = converted
        } else {
            normalizedBuffer = sourceBuffer
        }
        
        // Auto-trim dead silence, compress mid-word syllable breaks, and calculate perceptual onset advance
        let phraseData: SpokenPhraseData
        if let (trimmedBuf, onset) = trimSilenceAndComputeOnset(buffer: normalizedBuffer) {
            phraseData = SpokenPhraseData(buffer: trimmedBuf, onsetOffset: onset)
        } else {
            phraseData = SpokenPhraseData(buffer: normalizedBuffer, onsetOffset: 0.0)
        }
        
        cacheLock.lock()
        speechCache[cacheKey] = phraseData
        cacheLock.unlock()
        
        return phraseData
    }
    
    /// Trims leading and trailing digital silence (< 2% peak), compresses internal syllable pauses (> 25ms down to 18ms), and computes perceptual onset
    private func trimSilenceAndComputeOnset(buffer: AVAudioPCMBuffer) -> (trimmed: AVAudioPCMBuffer, onsetOffset: TimeInterval)? {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let totalFrames = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        
        var peak: Float = 0.0
        for i in 0..<totalFrames {
            let a = abs(channelData[i])
            if a > peak { peak = a }
        }
        guard peak > 0.001 else { return (buffer, 0.0) }
        
        let silenceThreshold = peak * 0.02
        let onsetThreshold = peak * 0.25 // Perceptual vowel attack
        
        var leadFrame = 0
        for i in 0..<totalFrames {
            if abs(channelData[i]) >= silenceThreshold {
                leadFrame = i
                break
            }
        }
        
        var tailFrame = totalFrames - 1
        for i in stride(from: totalFrames - 1, through: leadFrame, by: -1) {
            if abs(channelData[i]) >= silenceThreshold {
                tailFrame = i
                break
            }
        }
        
        var onsetFrame = leadFrame
        for i in leadFrame...tailFrame {
            if abs(channelData[i]) >= onsetThreshold {
                onsetFrame = i
                break
            }
        }
        
        let onsetOffset = max(0.0, Double(onsetFrame - leadFrame) / sampleRate)
        
        // Internal syllable break compression:
        // Neural TTS models insert a 100-150ms dead closure gap inside words like "In... tro".
        // We detect any gap inside the word (> 30ms) and compress it to a tight natural 18ms closure.
        let targetGapFrames = Int(0.018 * sampleRate)
        let detectGapFrames = Int(0.028 * sampleRate)
        let internalMargin = Int(0.040 * sampleRate)
        let internalStart = min(tailFrame, leadFrame + internalMargin)
        let internalEnd = max(leadFrame, tailFrame - internalMargin)
        let gapThreshold = peak * 0.035
        
        var keptIndices: [Int] = []
        keptIndices.reserveCapacity(tailFrame - leadFrame + 1)
        
        var i = leadFrame
        while i <= tailFrame {
            if i >= internalStart && i < internalEnd && abs(channelData[i]) < gapThreshold {
                let gapStart = i
                while i < internalEnd && abs(channelData[i]) < gapThreshold {
                    i += 1
                }
                let gapLen = i - gapStart
                if gapLen > detectGapFrames {
                    let keepCount = min(gapLen, targetGapFrames)
                    for k in 0..<keepCount {
                        keptIndices.append(gapStart + k)
                    }
                } else {
                    for k in gapStart..<i {
                        keptIndices.append(k)
                    }
                }
            } else {
                keptIndices.append(i)
                i += 1
            }
        }
        
        let newLength = max(1, keptIndices.count)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(newLength)) else {
            return (buffer, 0.0)
        }
        outBuf.frameLength = AVAudioFrameCount(newLength)
        
        for c in 0..<channelCount {
            if let src = buffer.floatChannelData?[c], let dst = outBuf.floatChannelData?[c] {
                for dstIdx in 0..<newLength {
                    let srcIdx = keptIndices[dstIdx]
                    dst[dstIdx] = src[srcIdx]
                }
            }
        }
        
        return (outBuf, onsetOffset)
    }
    
    /// Generates a complete Guide audio track buffer for a song
    public func generateGuideBuffer(
        sections: [SongSection],
        directionalCues: [DirectionalCue] = [],
        bpm: Double,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        duration: TimeInterval,
        beatGrid: [BeatGridMarker] = [],
        voice: GuideVoice = .rita,
        fallbackVoice: GuideVoice = .zoe,
        countInEnabled: Bool = true,
        queuedNextSection: SongSection? = nil,
        loopedSection: SongSection? = nil,
        isLoopActive: Bool = false,
        loopMode: MultitrackAudioEngine.LoopMode = .none,
        singleLoopRemaining: Int = 0,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard duration > 0 else { return nil }
        
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard totalFrames > 0 else { return nil }
        
        guard let guideBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return nil
        }
        guideBuffer.frameLength = totalFrames
        
        // Zero-fill buffer to silence
        for ch in 0..<channelCount {
            if let ptr = guideBuffer.floatChannelData?[ch] {
                memset(ptr, 0, Int(totalFrames) * MemoryLayout<Float>.size)
            }
        }
        
        let safeBpm = max(20.0, min(300.0, bpm))
        let secPerBeat = (60.0 / safeBpm) * (4.0 / Double(max(1, timeSignatureDenominator)))
        let beatsPerBar = max(1, timeSignatureNumerator)
        let secPerBar = secPerBeat * Double(beatsPerBar)
        let is68 = (timeSignatureNumerator == 6 && timeSignatureDenominator == 8)
        let orderedSections = sections.sorted { $0.startTime < $1.startTime }
        
        // Partition beatGrid into ordered measures so count-ins and section cues follow mid-song tempo & meter changes
        let sortedGrid = beatGrid.sorted { $0.time < $1.time }
        var gridMeasures: [[BeatGridMarker]] = []
        for marker in sortedGrid {
            if marker.beat == 1 || gridMeasures.isEmpty {
                gridMeasures.append([marker])
            } else {
                gridMeasures[gridMeasures.count - 1].append(marker)
            }
        }
        let maxCueBeats = max(is68 ? 6 : beatsPerBar, gridMeasures.map(\.count).max() ?? beatsPerBar)
        
        // Pre-gather all distinct phrases needed and synthesize concurrently for near-instant rendering
        var phrasesToWarm: Set<String> = ["1", "2"]
        if countInEnabled {
            for b in 2...max(2, maxCueBeats) {
                phrasesToWarm.insert("\(b)")
            }
        }
        for sec in orderedSections {
            let label = simplifySectionNameForSpeech(sec.name)
            if !label.isEmpty { phrasesToWarm.insert(label) }
        }
        for cue in directionalCues {
            let label = cue.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { phrasesToWarm.insert(label) }
        }
        
        let phraseList = Array(phrasesToWarm)
        DispatchQueue.concurrentPerform(iterations: phraseList.count) { idx in
            let p = phraseList[idx]
            _ = self.getOrSynthesizePhrase(p, voice: voice, fallbackVoice: fallbackVoice, targetFormat: format)
        }
        
        // Helper to determine the precise timestamp of a specific measure and beat (fallback for gridless songs)
        func timeForMeasureBeat(bar: Int, beat: Int) -> TimeInterval {
            if !sortedGrid.isEmpty {
                if let m = sortedGrid.first(where: { $0.bar == bar && $0.beat == beat }) {
                    return m.time
                }
            }
            return Double(bar - 1) * secPerBar + Double(beat - 1) * secPerBeat
        }
        
        // Resolves exact timestamps for the 1-bar cue measure immediately preceding `targetTime`,
        // anchored to `gridMeasures` (respecting ritardandos, tempo changes, mid-song meters, and arrangements).
        func cueMeasureTimestamps(before targetTime: TimeInterval) -> [TimeInterval] {
            if !gridMeasures.isEmpty {
                // a. Match targetTime to its nearest measure downbeat
                var bestMeasureIdx = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (idx, measure) in gridMeasures.enumerated() {
                    guard let downbeat = measure.first else { continue }
                    let dist = abs(downbeat.time - targetTime)
                    if dist < bestDist {
                        bestDist = dist
                        bestMeasureIdx = idx
                    }
                }
                if bestDist <= 0.25 {
                    guard bestMeasureIdx > 0 else { return [] }
                    return gridMeasures[bestMeasureIdx - 1].map { $0.time }
                }
                
                // b. Target is after the final downbeat in the grid (e.g., final section loop/queued cue at section.endTime)
                if let lastDownbeat = gridMeasures.last?.first, targetTime > lastDownbeat.time + 0.25 {
                    if let lastIdx = gridMeasures.lastIndex(where: { ($0.first?.time ?? .greatestFiniteMagnitude) < targetTime - 0.20 }) {
                        var times = gridMeasures[lastIdx].map { $0.time }.filter { $0 < targetTime - 0.05 }
                        let expectedBeats = max(gridMeasures[lastIdx].count, beatsPerBar)
                        if times.count < expectedBeats, let lastT = times.last {
                            let localBPM = max(20.0, gridMeasures[lastIdx].last?.instantaneousBPM ?? safeBpm)
                            let localBeatDur = (60.0 / localBPM) * (4.0 / Double(max(1, timeSignatureDenominator)))
                            var nextT = lastT + localBeatDur
                            while times.count < expectedBeats && nextT < targetTime - 0.05 {
                                times.append(nextT)
                                nextT += localBeatDur
                            }
                        }
                        if !times.isEmpty { return times }
                    }
                }
                
                // c. Mid-bar or unaligned boundary: look up beats immediately before `targetTime`
                var closestBeatIdx = 0
                var closestBeatDist = Double.greatestFiniteMagnitude
                for (idx, marker) in sortedGrid.enumerated() {
                    let dist = abs(marker.time - targetTime)
                    if dist < closestBeatDist {
                        closestBeatDist = dist
                        closestBeatIdx = idx
                    }
                }
                if closestBeatDist <= 0.25 {
                    guard closestBeatIdx >= beatsPerBar else { return [] }
                    return sortedGrid[(closestBeatIdx - beatsPerBar)..<closestBeatIdx].map { $0.time }
                }
                
                let activeMarker = sortedGrid.last(where: { $0.time <= targetTime + 0.008 }) ?? sortedGrid.first
                let localBPM = max(20.0, activeMarker?.instantaneousBPM ?? safeBpm)
                let localBeatDur = (60.0 / localBPM) * (4.0 / Double(max(1, timeSignatureDenominator)))
                let localBeatsPerBar = max(1, activeMarker != nil ? timeSignatureNumerator : beatsPerBar)
                guard targetTime >= Double(localBeatsPerBar) * localBeatDur - 0.05 else { return [] }
                return (0..<localBeatsPerBar).compactMap { k in
                    let t = targetTime - Double(localBeatsPerBar - k) * localBeatDur
                    return t >= -0.05 ? max(0.0, t) : nil
                }
            }
            
            // Fixed-BPM path when no beatGrid is available
            guard targetTime >= secPerBar - 0.05 else { return [] }
            let cueCount = is68 ? 6 : beatsPerBar
            return (0..<cueCount).map { k in
                max(0.0, targetTime - Double(cueCount - k) * secPerBeat)
            }
        }
        
        // Helper to mix a phrase into guideBuffer at a specific timestamp
        func speak(phrase: String, atTime time: TimeInterval) {
            guard let phraseData = getOrSynthesizePhrase(phrase, voice: voice, fallbackVoice: fallbackVoice, targetFormat: format) else { return }
            
            // Advance audio start by the perceptual acoustic onset offset so the vowel hit lands dead-on the click downbeat
            let alignedTime = max(0.0, time - phraseData.onsetOffset)
            guard alignedTime < duration else { return }
            
            let startFrame = Int(alignedTime * sampleRate)
            let framesToCopy = min(Int(phraseData.buffer.frameLength), Int(totalFrames) - startFrame)
            guard framesToCopy > 0 else { return }
            
            for ch in 0..<channelCount {
                guard let destPtr = guideBuffer.floatChannelData?[ch] else { continue }
                let srcCh = min(ch, Int(phraseData.buffer.format.channelCount) - 1)
                guard let srcPtr = phraseData.buffer.floatChannelData?[srcCh] else { continue }
                
                for f in 0..<framesToCopy {
                    let destIdx = startFrame + f
                    let mixed = destPtr[destIdx] + srcPtr[f] * 0.95
                    destPtr[destIdx] = max(-1.0, min(1.0, mixed))
                }
            }
        }
        
        func speakSectionCue(for targetCueSec: SongSection, beatTimes: [TimeInterval]) {
            guard let firstBeat = beatTimes.first else { return }
            let isUnlabeled = isSectionUnlabeled(targetCueSec.name)
            if !isUnlabeled && targetCueSec.playSectionGuideCue {
                let spokenName = simplifySectionNameForSpeech(targetCueSec.name, includeNumber: targetCueSec.includeNumberInGuide)
                speak(phrase: spokenName, atTime: firstBeat)
            } else if countInEnabled && targetCueSec.playSectionCountIn {
                speak(phrase: "1", atTime: firstBeat)
            }
            if countInEnabled && targetCueSec.playSectionCountIn && beatTimes.count >= 2 {
                for bIdx in 1..<beatTimes.count {
                    speak(phrase: "\(bIdx + 1)", atTime: beatTimes[bIdx])
                }
            }
        }
        
        func halfwayBeatTime(in barTimes: [TimeInterval]) -> TimeInterval? {
            if barTimes.count == 6 { return barTimes[3] } // Beat 4 in 6/8 or 6/4
            if barTimes.count >= 3 { return barTimes[2] } // Beat 3 in 4/4, 3/4, etc.
            if barTimes.count == 2 { return barTimes[1] } // Beat 2 in 2/4
            return nil
        }
        
        func speakHalfNoteLeadIn(before cueStartTime: TimeInterval) {
            guard countInEnabled else { return }
            let prevBarTimes = cueMeasureTimestamps(before: cueStartTime)
            guard !prevBarTimes.isEmpty,
                  (prevBarTimes.last ?? 0.0) < cueStartTime - 0.05 else {
                return
            }
            speak(phrase: "1", atTime: prevBarTimes[0])
            if let halfBeat = halfwayBeatTime(in: prevBarTimes),
               halfBeat < cueStartTime - 0.05 {
                speak(phrase: "2", atTime: halfBeat)
            }
        }
        
        // MARK: - 1. Count In at beginning of song
        let firstSection = orderedSections.first
        let startsWithCountIn = firstSection != nil && (firstSection!.abbreviation == "Co" || firstSection!.name.localizedCaseInsensitiveContains("count"))
        let bar1Times: [TimeInterval] = !gridMeasures.isEmpty
            ? gridMeasures[0].map(\.time)
            : (1...(is68 ? 6 : beatsPerBar)).map { timeForMeasureBeat(bar: 1, beat: $0) }
        let fallbackBar2Times: [TimeInterval] = gridMeasures.count >= 2
            ? gridMeasures[1].map(\.time)
            : (1...(is68 ? 6 : beatsPerBar)).map { timeForMeasureBeat(bar: 2, beat: $0) }
        
        if startsWithCountIn, let firstSec = firstSection {
            // Speak cues strictly inside the Count In measure(s) preceding the next section (never overlapping what is already playing)
            if orderedSections.count > 1 {
                let targetSec = orderedSections[1]
                let cueTimes = cueMeasureTimestamps(before: targetSec.startTime)
                if !cueTimes.isEmpty && (cueTimes.last ?? 0.0) < targetSec.startTime - 0.02 {
                    speakHalfNoteLeadIn(before: cueTimes[0])
                    speakSectionCue(for: targetSec, beatTimes: cueTimes)
                }
            } else if firstSec.duration >= 2.0 * secPerBar - 0.1,
                      (fallbackBar2Times.last ?? 0.0) < firstSec.endTime - 0.02 {
                if countInEnabled, let bar1Start = bar1Times.first {
                    speak(phrase: "1", atTime: bar1Start)
                    if let halfBeat = halfwayBeatTime(in: bar1Times) {
                        speak(phrase: "2", atTime: halfBeat)
                    }
                }
                speakSectionCue(for: firstSec, beatTimes: fallbackBar2Times)
            } else if firstSec.duration >= secPerBar - 0.1 {
                speakSectionCue(for: firstSec, beatTimes: bar1Times)
            }
        } else if let targetSec = firstSection {
            // Song starts with a non-Count-In section (e.g. Intro, Verse 1, Click Section).
            // Only speak its cue if there is an unlabeled pre-roll bar strictly before targetSec.startTime.
            let preRollCueTimes = cueMeasureTimestamps(before: targetSec.startTime)
            if !preRollCueTimes.isEmpty && (preRollCueTimes.last ?? 0.0) < targetSec.startTime - 0.02 {
                speakHalfNoteLeadIn(before: preRollCueTimes[0])
                speakSectionCue(for: targetSec, beatTimes: preRollCueTimes)
            }
        } else if countInEnabled {
            // No sections defined yet: count in 1..2 on bar 1 and 2..4 on bar 2 so the user hears the guide track immediately.
            speak(phrase: "1", atTime: bar1Times.first ?? 0.0)
            if let halfBeat = halfwayBeatTime(in: bar1Times) {
                speak(phrase: "2", atTime: halfBeat)
            }
            if fallbackBar2Times.count >= 2 {
                for bIdx in 1..<fallbackBar2Times.count {
                    speak(phrase: "\(bIdx + 1)", atTime: fallbackBar2Times[bIdx])
                }
            }
        }
        
        // MARK: - 2. Regular Section Guide Cues
        // The guide speaks the section name 1 bar before that section, followed by count in.
        // If the current section is set to loop, the guide dynamically calls out the looped section name instead!
        let startIndex: Int = startsWithCountIn ? 2 : 1
        
        if orderedSections.count > startIndex {
            for i in startIndex..<orderedSections.count {
                let sec = orderedSections[i]
                let cueTimes = cueMeasureTimestamps(before: sec.startTime)
                guard !cueTimes.isEmpty, cueTimes.allSatisfy({ $0 < sec.startTime - 0.02 }) else { continue }
                
                // Determine whether the currently ending section is looping or moving to a queued section
                let currentSec = orderedSections[i - 1]
                let isCurrentSectionLooped = isLoopActive && (loopedSection?.id == currentSec.id)
                let shouldLoopBack = isCurrentSectionLooped && (loopMode == .infinite || (loopMode == .single && singleLoopRemaining > 0))
                let isClickLoopSec = currentSec.abbreviation == "Cl" ||
                    currentSec.displayAbbreviation == "Cl" ||
                    currentSec.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click"
                if shouldLoopBack && isClickLoopSec && !currentSec.playSectionGuideCue && queuedNextSection == nil {
                    continue
                }
                
                let targetCueSec: SongSection
                if let q = queuedNextSection {
                    targetCueSec = q
                } else if shouldLoopBack {
                    targetCueSec = currentSec
                } else {
                    targetCueSec = sec
                }
                
                speakSectionCue(for: targetCueSec, beatTimes: cueTimes)
            }
        }
        
        // Handle when the very last section of the song is looped or has a queued section
        if let lastSec = orderedSections.last {
            let isLooped = isLoopActive && (loopedSection?.id == lastSec.id)
            let shouldLoopBack = isLooped && (loopMode == .infinite || (loopMode == .single && singleLoopRemaining > 0))
            if shouldLoopBack || queuedNextSection != nil {
                let cueTimes = cueMeasureTimestamps(before: lastSec.endTime)
                if !cueTimes.isEmpty, cueTimes[0] >= lastSec.startTime - 0.05 {
                    let targetCueSec = queuedNextSection ?? lastSec
                    speakSectionCue(for: targetCueSec, beatTimes: cueTimes)
                }
            }
        }
        
        // MARK: - 3. Directional Cues
        for cue in directionalCues {
            speak(phrase: cue.label, atTime: cue.time)
        }
        
        return guideBuffer
    }
    
    /// Overlays directional cues speech on top of an existing base guide audio buffer (e.g. uploaded guide stem)
    public func overlayDirectionalCues(
        onto baseBuffer: AVAudioPCMBuffer,
        directionalCues: [DirectionalCue],
        voice: GuideVoice,
        fallbackVoice: GuideVoice = .zoe
    ) -> AVAudioPCMBuffer {
        guard !directionalCues.isEmpty else { return baseBuffer }
        let format = baseBuffer.format
        let totalFrames = baseBuffer.frameLength
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let duration = Double(totalFrames) / sampleRate
        
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return baseBuffer
        }
        output.frameLength = totalFrames
        
        // Copy base buffer data
        for ch in 0..<channelCount {
            if let src = baseBuffer.floatChannelData?[ch], let dst = output.floatChannelData?[ch] {
                memcpy(dst, src, Int(totalFrames) * MemoryLayout<Float>.size)
            }
        }
        
        // Mix in each directional cue
        for cue in directionalCues {
            guard let phraseData = getOrSynthesizePhrase(cue.label, voice: voice, fallbackVoice: fallbackVoice, targetFormat: format) else { continue }
            let alignedTime = max(0.0, cue.time - phraseData.onsetOffset)
            guard alignedTime < duration else { continue }
            
            let startFrame = Int(alignedTime * sampleRate)
            let framesToCopy = min(Int(phraseData.buffer.frameLength), Int(totalFrames) - startFrame)
            guard framesToCopy > 0 else { continue }
            
            for ch in 0..<channelCount {
                guard let destPtr = output.floatChannelData?[ch] else { continue }
                let srcCh = min(ch, Int(phraseData.buffer.format.channelCount) - 1)
                guard let srcPtr = phraseData.buffer.floatChannelData?[srcCh] else { continue }
                
                for f in 0..<framesToCopy {
                    let destIdx = startFrame + f
                    let mixed = destPtr[destIdx] + srcPtr[f] * 0.95
                    destPtr[destIdx] = max(-1.0, min(1.0, mixed))
                }
            }
        }
        
        return output
    }
    
    // Checks whether a section is considered unlabeled
    private func isSectionUnlabeled(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return lower == "unlabeled" || lower == "section" || lower == "none" || lower == "no label" || lower == "empty" || lower == "—" || lower == "-"
    }
    
    // Simplifies section names for natural guide speech (e.g. "Verse 2" -> "Verse" when includeNumber is false)
    private func simplifySectionNameForSpeech(_ name: String, includeNumber: Bool = true) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.starts(with: "count") || lower.starts(with: "click") {
            return "Intro"
        }
        if !includeNumber {
            let stripped = trimmed.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return trimmed
    }
}
