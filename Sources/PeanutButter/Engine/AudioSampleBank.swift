import Foundation
import AVFoundation
import Accelerate

/// Subdivisions for metronome click audio playback
public enum ClickSubdivision: String, Sendable {
    case accent = "Accent"
    case quarter = "Quarter"
    case eighth = "Eighth"
    case sixteenth = "Sixteenth"
}

/// Spoken audio buffer paired with its perceptual onset offset
public struct SpokenPhraseData: Sendable {
    public let buffer: AVAudioPCMBuffer
    public let onsetOffset: TimeInterval
    
    public init(buffer: AVAudioPCMBuffer, onsetOffset: TimeInterval) {
        self.buffer = buffer
        self.onsetOffset = onsetOffset
    }
}

/// Central audio sample bank providing pre-recorded studio MultiTracks clicks and Rita guide audio
public final class AudioSampleBank: @unchecked Sendable {
    public static let shared = AudioSampleBank()
    
    private let lock = NSLock()
    private var bufferCache: [String: AVAudioPCMBuffer] = [:]
    private var ritaPhraseCache: [String: SpokenPhraseData] = [:]
    private var customPhraseCache: [String: SpokenPhraseData] = [:]
    
    private init() {}
    
    // MARK: - Resource Directory Resolution
    
    public func audioBaseURL() -> URL? {
        let fm = FileManager.default
        
        // 1. App Bundle Resources
        if let resURL = Bundle.main.resourceURL {
            let audioInRes = resURL.appendingPathComponent("Audio")
            if fm.fileExists(atPath: audioInRes.path) {
                return audioInRes
            }
            if fm.fileExists(atPath: resURL.appendingPathComponent("Click").path) {
                return resURL
            }
        }
        
        // 2. Relative to working directory in development / testing
        let localAudio = URL(fileURLWithPath: "Sources/PeanutButter/Resources/Audio")
        if fm.fileExists(atPath: localAudio.path) {
            return localAudio
        }
        
        return nil
    }
    
    // MARK: - Pad Audio Sample Loading
    
    public static func normalizeKeyForPad(_ rawKey: String) -> String {
        var str = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty || str == "—" {
            return "C"
        }
        
        // Remove enclosing parentheses or brackets if any, e.g. "(E)" -> "E"
        if str.hasPrefix("(") && str.hasSuffix(")") {
            str = String(str.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        
        // Strip out descriptors like "minor", "min", "major", "maj"
        let lower = str.lowercased()
        if lower.contains("minor") {
            str = str.replacingOccurrences(of: "minor", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        } else if lower.contains("min") {
            str = str.replacingOccurrences(of: "min", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        } else if lower.contains("major") {
            str = str.replacingOccurrences(of: "major", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        } else if lower.contains("maj") {
            str = str.replacingOccurrences(of: "maj", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        } else if str.hasSuffix("m") && str.count > 1 {
            str = String(str.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        
        guard let firstChar = str.first, ("A"..."G").contains(firstChar) else {
            return "C"
        }
        
        var root = String(firstChar)
        let remaining = String(str.dropFirst())
        
        if remaining.hasPrefix("#") || remaining.hasPrefix("♯") {
            root += "#"
        } else if remaining.hasPrefix("b") || remaining.hasPrefix("♭") {
            root += "b"
        }
        
        // Normalize enharmonics to Fundamental pad filenames (which use flats)
        switch root {
        case "C#": return "Db"
        case "D#": return "Eb"
        case "F#": return "Gb"
        case "G#": return "Ab"
        case "A#": return "Bb"
        case "Cb": return "B"
        case "B#": return "C"
        case "E#": return "F"
        case "Fb": return "E"
        default: break
        }
        
        let validKeys: Set<String> = ["A", "Ab", "B", "Bb", "C", "D", "Db", "E", "Eb", "F", "G", "Gb"]
        return validKeys.contains(root) ? root : "C"
    }
    
    public func padFilename(for key: String, packId: String = "simple", ext: String = "m4a") -> String {
        let norm = Self.normalizeKeyForPad(key)
        let packName = (packId.lowercased() == "soft") ? "Soft" : "Simple"
        return "\(norm) - \(packName).\(ext)"
    }
    
    public func getPadSample(for key: String, packId: String = "simple", format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let packFolder = (packId.lowercased() == "soft") ? "Soft" : "Simple"
        let filenames = [
            padFilename(for: key, packId: packId, ext: "m4a"),
            padFilename(for: key, packId: packId, ext: "wav")
        ]
        let fm = FileManager.default
        var candidates: [URL] = []

        for filename in filenames {
            if let base = audioBaseURL() {
                candidates.append(base.appendingPathComponent("Pads").appendingPathComponent(packFolder).appendingPathComponent(filename))
                candidates.append(base.appendingPathComponent("Pads").appendingPathComponent(filename))
                candidates.append(base.appendingPathComponent(filename))
            }
            if let res = Bundle.main.resourceURL {
                candidates.append(res.appendingPathComponent("Audio/Pads/\(packFolder)/\(filename)"))
                candidates.append(res.appendingPathComponent("Pads/\(packFolder)/\(filename)"))
                candidates.append(res.appendingPathComponent("Audio/Pads/\(filename)"))
                candidates.append(res.appendingPathComponent("Pads/\(filename)"))
                candidates.append(res.appendingPathComponent(filename))
            }
            candidates.append(URL(fileURLWithPath: "Sources/PeanutButter/Resources/Audio/Pads/\(packFolder)/\(filename)"))
        }
        
        for url in candidates {
            if fm.fileExists(atPath: url.path) {
                if let buf = loadAndConvertBuffer(at: url, targetFormat: format) {
                    return Self.normalizePadBufferRMS(buf)
                }
            }
        }
        if packId.lowercased() != "simple" {
            return getPadSample(for: key, packId: "simple", format: format)
        }
        return nil
    }
    
    /// Non-destructive loudness normalization for ambient pad buffers targeting -28.4 dB RMS (matching Playback's default pad level).
    /// Measures sustained RMS across active blocks (ignoring quiet fade-in/tail regions) and scales
    /// in-memory with peak headroom protection so all stock and custom pads match seamlessly.
    @discardableResult
    public static func normalizePadBufferRMS(_ buffer: AVAudioPCMBuffer, targetDB: Float = -28.4) -> AVAudioPCMBuffer {
        let frameCount = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        guard frameCount > 0, chCount > 0, let floatChannels = buffer.floatChannelData else {
            return buffer
        }
        
        let blockSize = 4096
        let numBlocks = max(1, frameCount / blockSize)
        var blockEnergies: [Float] = []
        blockEnergies.reserveCapacity(numBlocks)
        var maxPeak: Float = 0.0
        
        for ch in 0..<chCount {
            var chPeak: Float = 0.0
            vDSP_maxmgv(floatChannels[ch], 1, &chPeak, vDSP_Length(frameCount))
            if chPeak > maxPeak { maxPeak = chPeak }
        }
        
        if maxPeak < 1e-5 { return buffer }
        
        for b in 0..<numBlocks {
            let offset = b * blockSize
            let len = min(blockSize, frameCount - offset)
            if len <= 0 { continue }
            var sumSq: Float = 0.0
            for ch in 0..<chCount {
                var rms: Float = 0.0
                vDSP_rmsqv(floatChannels[ch].advanced(by: offset), 1, &rms, vDSP_Length(len))
                sumSq += rms * rms
            }
            let blockRMS = sqrtf(sumSq / Float(chCount))
            // Gate out silent/fade-in blocks below -50 dB (~0.00316) so sustained pad body drives loudness
            if blockRMS > 0.00316 {
                blockEnergies.append(blockRMS * blockRMS)
            }
        }
        
        let sustainedRMS: Float
        if !blockEnergies.isEmpty {
            let meanEnergy = blockEnergies.reduce(0, +) / Float(blockEnergies.count)
            sustainedRMS = sqrtf(meanEnergy)
        } else {
            var totalSq: Float = 0.0
            for ch in 0..<chCount {
                var rms: Float = 0.0
                vDSP_rmsqv(floatChannels[ch], 1, &rms, vDSP_Length(frameCount))
                totalSq += rms * rms
            }
            sustainedRMS = sqrtf(totalSq / Float(chCount))
        }
        
        guard sustainedRMS > 1e-5 else { return buffer }
        
        let targetLinear = powf(10.0, targetDB / 20.0)
        var gain = targetLinear / sustainedRMS
        // Clamp gain safely and prevent digital clipping
        gain = max(0.15, min(8.0, gain))
        if maxPeak * gain > 0.98 {
            gain = 0.98 / maxPeak
        }
        
        if abs(gain - 1.0) > 0.005 {
            for ch in 0..<chCount {
                var g = gain
                vDSP_vsmul(floatChannels[ch], 1, &g, floatChannels[ch], 1, vDSP_Length(frameCount))
            }
        }
        return buffer
    }
    
    // MARK: - Click Audio Sample Loading
    
    public func getClickSample(
        sound: ClickSoundType,
        subdivision: ClickSubdivision,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if let customPackId = sound.customPackId {
            return CustomSampleLibraryManager.shared.getClickSample(
                packId: customPackId,
                subdivision: subdivision,
                format: format
            )
        }
        guard let filename = clickFilename(for: sound, subdivision: subdivision) else { return nil }
        guard let base = audioBaseURL() else { return nil }
        
        let fileURL = base.appendingPathComponent("Click").appendingPathComponent(filename)
        return loadAndConvertBuffer(at: fileURL, targetFormat: format)
    }

    /// True when the local/bundled Click WAVs are present on disk.
    /// On a fresh open-source download (without MultiTracks WAVs), this returns false
    /// and the app defaults cleanly to synthesized clicks.
    public var hasSampledClicks: Bool {
        let fm = FileManager.default
        if let base = audioBaseURL(),
           fm.fileExists(atPath: base.appendingPathComponent("Click/New Click -  Classic-accents.wav").path) {
            return true
        }
        if let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("Audio/Click/New Click -  Classic-accents.wav").path) {
            return true
        }
        return false
    }

    /// True when the local/bundled Rita Guide WAVs are present on disk.
    /// On a fresh open-source download (without MultiTracks WAVs), this returns false
    /// so Rita is hidden from the voice menus.
    public var hasSampledGuides: Bool {
        let fm = FileManager.default
        if let base = audioBaseURL(),
           fm.fileExists(atPath: base.appendingPathComponent("Song Sections").path) ||
           fm.fileExists(atPath: base.appendingPathComponent("Dynamic Cues").path) {
            return true
        }
        if let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("Audio/Song Sections").path) ||
           fm.fileExists(atPath: res.appendingPathComponent("Audio/Dynamic Cues").path) {
            return true
        }
        return false
    }
    
    private func clickFilename(for sound: ClickSoundType, subdivision: ClickSubdivision) -> String? {
        let prefix: String
        switch sound {
        case .classic:
            prefix = "New Click -  Classic"
        case .gentle:
            prefix = "New Click -  Gentle"
        case .woodblock:
            prefix = "New Click -  Woodblock"
        case .percussive:
            prefix = "New Click -  Percussive"
        case .blip:
            prefix = "New Click -  Blip"
        case .saw:
            prefix = "New Click -  Saw"
        case .cowbell:
            prefix = "New Click -  Cowbell"
        case .digital:
            prefix = "New Click -  Digital"
        default:
            return nil
        }
        
        switch sound {
        case .saw:
            switch subdivision {
            case .accent: return "\(prefix)-accents.wav"
            case .quarter: return "\(prefix)-quarter.wav"
            case .eighth, .sixteenth: return "\(prefix)-eighth.wav"
            }
        case .digital:
            switch subdivision {
            case .accent, .quarter: return "\(prefix)-accents.wav"
            case .eighth, .sixteenth: return "\(prefix)-sixteenth.wav"
            }
        default:
            switch subdivision {
            case .accent: return "\(prefix)-accents.wav"
            case .quarter: return "\(prefix)-quarter.wav"
            case .eighth: return "\(prefix)-eighth.wav"
            case .sixteenth: return "\(prefix)-sixteenth.wav"
            }
        }
    }
    
    // MARK: - Rita Voice Phrases Loading

    public func hasRitaPhraseSample(phrase: String) -> Bool {
        let normalized = normalizePhraseKey(phrase)
        guard !normalized.isEmpty, let base = audioBaseURL() else { return false }
        let fm = FileManager.default
        if let cueFilename = ritaDynamicCueMap[normalized] {
            let cueURL = base.appendingPathComponent("Dynamic Cues").appendingPathComponent(cueFilename)
            if fm.fileExists(atPath: cueURL.path) {
                return true
            }
        }
        if let secFilename = ritaSectionMap[normalized] {
            let secURL = base.appendingPathComponent("Song Sections").appendingPathComponent(secFilename)
            if fm.fileExists(atPath: secURL.path) {
                return true
            }
        }
        return false
    }
    
    public func getRitaPhraseSample(
        phrase: String,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        let normalized = normalizePhraseKey(phrase)
        guard !normalized.isEmpty else { return nil }
        
        let cacheKey = "rita_\(normalized)_\(Int(targetFormat.sampleRate))_\(targetFormat.channelCount)"
        lock.lock()
        if let cached = ritaPhraseCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        guard let base = audioBaseURL() else { return nil }
        
        // 1. Check Dynamic Cues
        if let cueFilename = ritaDynamicCueMap[normalized] {
            let cueURL = base.appendingPathComponent("Dynamic Cues").appendingPathComponent(cueFilename)
            if let phraseData = loadPhraseData(at: cueURL, targetFormat: targetFormat) {
                lock.lock()
                ritaPhraseCache[cacheKey] = phraseData
                lock.unlock()
                return phraseData
            }
        }
        
        // 2. Check Song Sections
        if let secFilename = ritaSectionMap[normalized] {
            let secURL = base.appendingPathComponent("Song Sections").appendingPathComponent(secFilename)
            if let phraseData = loadPhraseData(at: secURL, targetFormat: targetFormat) {
                lock.lock()
                ritaPhraseCache[cacheKey] = phraseData
                lock.unlock()
                return phraseData
            }
        }
        
        return nil
    }
    
    public func loadCustomPhraseData(at url: URL, targetFormat: AVAudioFormat) -> SpokenPhraseData? {
        return loadPhraseData(at: url, targetFormat: targetFormat)
    }
    
    /// Computes the perceptual vowel-attack onset offset (in seconds, clamped to 0...0.18s)
    /// for a spoken guide buffer without running sample-trimming or syllable compression.
    public func computePerceptualOnsetOffset(buffer: AVAudioPCMBuffer) -> TimeInterval {
        computeOnsetOffset(buffer: buffer)
    }

    /// Returns prioritized studio Rita WAV URLs paired with exact spoken transcripts for zero-shot voice cloning.
    public func ritaReferenceClipCandidates() -> [(url: URL, transcript: String)] {
        guard let base = audioBaseURL() else { return [] }
        let orderedKeys: [(key: String, spoken: String, isDynamic: Bool)] = [
            ("key change up", "key change up", true),
            ("worship freely", "worship freely", true),
            ("slowly build", "slowly build", true),
            ("big ending", "big ending", true),
            ("pre chorus 1", "pre chorus one", false),
            ("instrumental", "instrumental", false),
            ("breakdown", "breakdown", false),
            ("interlude", "interlude", false),
            ("key change down", "key change down", true),
            ("last time", "last time", true),
            ("chorus 1", "chorus one", false),
            ("bridge 1", "bridge one", false)
        ]

        var results: [(url: URL, transcript: String)] = []
        let fm = FileManager.default
        for item in orderedKeys {
            let folderName = item.isDynamic ? "Dynamic Cues" : "Song Sections"
            let filename = item.isDynamic ? ritaDynamicCueMap[item.key] : ritaSectionMap[item.key]
            guard let filename else { continue }
            let url = base.appendingPathComponent(folderName).appendingPathComponent(filename)
            if fm.fileExists(atPath: url.path) {
                results.append((url, item.spoken))
            }
        }
        return results
    }

    public func invalidateCachedBuffers(matchingPathPrefix prefix: String) {
        lock.lock()
        bufferCache = bufferCache.filter { !$0.key.hasPrefix(prefix) }
        customPhraseCache = customPhraseCache.filter { !$0.key.hasPrefix(prefix) }
        ritaPhraseCache.removeAll()
        lock.unlock()
    }
    
    private func loadPhraseData(at url: URL, targetFormat: AVAudioFormat) -> SpokenPhraseData? {
        let cacheKey = "\(url.path)_\(Int(targetFormat.sampleRate))_\(targetFormat.channelCount)"
        lock.lock()
        if let cached = customPhraseCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let rawBuffer = loadAndConvertBuffer(at: url, targetFormat: targetFormat) else { return nil }
        let isPreMasteredBundledGuide = url.path.contains("/Guides/sam-male/")
        let trimmedBuffer = isPreMasteredBundledGuide ? rawBuffer : trimLeadingAndTrailingSilence(buffer: rawBuffer)
        
        // Compute perceptual vowel onset offset on the silence-trimmed buffer
        let onset = computeOnsetOffset(buffer: trimmedBuffer)
        let data = SpokenPhraseData(buffer: trimmedBuffer, onsetOffset: onset)

        lock.lock()
        customPhraseCache[cacheKey] = data
        lock.unlock()
        return data
    }

    /// Trims leading and trailing dead air from guide cue samples while preserving unvoiced leading consonants
    /// ("S-", "F-", "T-", "Ch-", "St-") and ignoring isolated early mouth clicks before the word.
    private func trimLeadingAndTrailingSilence(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let ch0 = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return buffer }
        let totalFrames = Int(buffer.frameLength)
        let sampleRate = max(8000.0, buffer.format.sampleRate)
        let chCount = Int(buffer.format.channelCount)

        var peak: Float = 0.0
        vDSP_maxmgv(ch0, 1, &peak, vDSP_Length(totalFrames))
        guard peak > 0.002 else { return buffer }

        let strongThresh = peak * 0.18
        let leadConsonantThresh = max(0.0035, peak * 0.022)
        let tailConsonantThresh = max(0.0020, peak * 0.012)
        let leadMaxGapFrames = Int(0.075 * sampleRate)
        let tailMaxGapFrames = Int(0.140 * sampleRate)

        var firstStrong = 0
        for i in 0..<totalFrames {
            if abs(ch0[i]) >= strongThresh {
                firstStrong = i
                break
            }
        }

        // Walk backward from the voiced vowel body across contiguous leading consonants (bridging < 75ms plosive closures)
        var leadFrame = firstStrong
        var silentRun = 0
        for i in stride(from: firstStrong, through: 0, by: -1) {
            if abs(ch0[i]) >= leadConsonantThresh {
                leadFrame = i
                silentRun = 0
            } else {
                silentRun += 1
                if silentRun > leadMaxGapFrames {
                    break
                }
            }
        }
        leadFrame = max(0, leadFrame - Int(0.010 * sampleRate))

        var lastStrong = totalFrames - 1
        for i in stride(from: totalFrames - 1, through: leadFrame, by: -1) {
            if abs(ch0[i]) >= peak * 0.15 {
                lastStrong = i
                break
            }
        }

        var tailFrame = lastStrong
        silentRun = 0
        for i in lastStrong..<totalFrames {
            if abs(ch0[i]) >= tailConsonantThresh {
                tailFrame = i
                silentRun = 0
            } else {
                silentRun += 1
                if silentRun > tailMaxGapFrames {
                    break
                }
            }
        }
        tailFrame = min(totalFrames - 1, tailFrame + Int(0.020 * sampleRate))

        // Only allocate a trimmed copy if at least 25ms of leading/trailing silence was found
        let minTrimFrames = Int(0.025 * sampleRate)
        guard leadFrame >= minTrimFrames || (totalFrames - 1 - tailFrame) >= minTrimFrames else {
            return buffer
        }

        let newLength = max(1, tailFrame - leadFrame + 1)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(newLength)) else {
            return buffer
        }
        trimmed.frameLength = AVAudioFrameCount(newLength)

        let fadeInFrames = min(newLength / 4, Int(0.003 * sampleRate))
        let fadeOutFrames = min(newLength / 4, Int(0.005 * sampleRate))

        for c in 0..<chCount {
            if let src = buffer.floatChannelData?[c], let dst = trimmed.floatChannelData?[c] {
                memcpy(dst, src.advanced(by: leadFrame), newLength * MemoryLayout<Float>.size)
                if leadFrame > 0 && fadeInFrames > 1 {
                    for i in 0..<fadeInFrames {
                        dst[i] *= Float(i) / Float(fadeInFrames)
                    }
                }
                if fadeOutFrames > 1 {
                    for i in 0..<fadeOutFrames {
                        let idx = newLength - 1 - i
                        dst[idx] *= Float(i) / Float(fadeOutFrames)
                    }
                }
            }
        }
        return trimmed
    }
    
    private func computeOnsetOffset(buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0.0 }
        let totalFrames = Int(buffer.frameLength)
        let sampleRate = max(8000.0, buffer.format.sampleRate)

        // Low-pass (~1200 Hz) + 12ms smoothed envelope so high-frequency sibilants ("S" in Six/Seven)
        // don't trigger early; aligns the voiced vowel attack directly onto the beat.
        let alpha = Float(min(0.95, (2.0 * Double.pi * 1200.0) / (sampleRate + 2.0 * Double.pi * 1200.0)))
        let decay = Float(exp(-1.0 / (0.012 * sampleRate)))
        var lp: Float = 0.0
        var env: Float = 0.0
        var envelopes = [Float](repeating: 0.0, count: totalFrames)
        var maxEnv: Float = 0.0

        for i in 0..<totalFrames {
            lp += alpha * (channelData[i] - lp)
            let mag = abs(lp)
            env = max(mag, env * decay)
            envelopes[i] = env
            if env > maxEnv { maxEnv = env }
        }
        guard maxEnv > 0.001 else { return 0.0 }

        let onsetThreshold = maxEnv * 0.30
        for i in 0..<totalFrames {
            if envelopes[i] >= onsetThreshold {
                return min(0.18, max(0.0, Double(i) / sampleRate))
            }
        }
        return 0.0
    }
    
    // MARK: - Normalization and Mapping
    
    public func normalizePhraseKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        
        // Spoken number words -> digit keys ("1"..."8")
        switch s {
        case "one": return "1"
        case "two": return "2"
        case "three": return "3"
        case "four": return "4"
        case "five": return "5"
        case "six": return "6"
        case "seven": return "7"
        case "eight": return "8"
        default: break
        }
        
        // Common Synonyms & Abbreviations
        if s == "end" || s == "the end" || s == "ending" { return "ending" }
        if s == "a cappella" { return "acapella" }
        if s == "vamp 1" { return "vamp" }
        if s == "tag 1" { return "tag" }
        if s == "intro 1" || s == "in" || s == "int" { return "intro" }
        if s == "outro 1" || s == "out" { return "outro" }
        if s == "instrumental 1" || s == "inst" { return "instrumental" }
        if s == "interlude 1" || s == "inter" { return "interlude" }
        if s == "breakdown 1" { return "breakdown" }
        if s == "v1" { return "verse 1" }
        if s == "v2" { return "verse 2" }
        if s == "v3" { return "verse 3" }
        if s == "v4" { return "verse 4" }
        if s == "v5" { return "verse 5" }
        if s == "v6" { return "verse 6" }
        if s == "v" { return "verse" }
        if s == "c1" || s == "ch1" { return "chorus 1" }
        if s == "c2" || s == "ch2" { return "chorus 2" }
        if s == "c3" || s == "ch3" { return "chorus 3" }
        if s == "c4" || s == "ch4" { return "chorus 4" }
        if s == "c" || s == "ch" { return "chorus" }
        if s == "pc1" || s == "pre 1" { return "pre chorus 1" }
        if s == "pc2" || s == "pre 2" { return "pre chorus 2" }
        if s == "pc" || s == "pre" { return "pre chorus" }
        if s == "b1" || s == "br1" { return "bridge 1" }
        if s == "b2" || s == "br2" { return "bridge 2" }
        if s == "b3" || s == "br3" { return "bridge 3" }
        if s == "b4" || s == "br4" { return "bridge 4" }
        if s == "b5" || s == "br5" { return "bridge 5" }
        if s == "b" || s == "br" { return "bridge" }
        
        return s
    }
    
    /// Pre-warms common Rita phrases and Click samples into RAM cache for zero-latency instant generation
    public func warmupCommonSamples(format: AVAudioFormat) {
        let commonPhrases = [
            "1", "2", "3", "4", "5", "6", "7",
            "intro", "verse", "verse 1", "verse 2", "verse 3",
            "pre chorus", "chorus", "chorus 1", "chorus 2",
            "bridge", "bridge 1", "ending", "outro", "instrumental"
        ]
        DispatchQueue.global(qos: .userInitiated).async {
            for phrase in commonPhrases {
                _ = self.getRitaPhraseSample(phrase: phrase, targetFormat: format)
            }
            for sub in [ClickSubdivision.accent, .quarter, .eighth, .sixteenth] {
                _ = self.getClickSample(sound: .classic, subdivision: sub, format: format)
            }
        }
    }
    
    // Rita's Dynamic Cues mapping
    private let ritaDynamicCueMap: [String: String] = [
        "ad lib": "English Female - Ad Lib.wav",
        "all in": "English Female - All In.wav",
        "bass": "English Female - Bass.wav",
        "big ending": "English Female - Big Ending.wav",
        "break": "English Female - Break.wav",
        "build": "English Female - Build.wav",
        "drums in": "English Female - Drums In.wav",
        "drums": "English Female - Drums.wav",
        "hits": "English Female - Hits.wav",
        "hold": "English Female - Hold.wav",
        "key change down": "English Female - Key Change Down.wav",
        "key change up": "English Female - Key Change Up.wav",
        "keys": "English Female - Keys.wav",
        "last time": "English Female - Last Time.wav",
        "slowly build": "English Female - Slowly Build.wav",
        "softly": "English Female - Softly.wav",
        "swell": "English Female - Swell.wav",
        "worship freely": "English Female - Worship Freely.wav"
    ]
    
    // Rita's Song Sections and Count-in Numbers mapping
    private let ritaSectionMap: [String: String] = [
        // Numbers
        "1": "English Female - 1.wav",
        "2": "English Female - 2.wav",
        "3": "English Female - 3.wav",
        "4": "English Female - 4.wav",
        "5": "English Female - 5.wav",
        "6": "English Female - 6.wav",
        "7": "English Female - 7.wav",
        
        // Sections
        "intro": "English Female - Intro.wav",
        "verse": "English Female - Verse.wav",
        "verse 1": "English Female - Verse 1.wav",
        "verse 2": "English Female - Verse 2.wav",
        "verse 3": "English Female - Verse 3.wav",
        "verse 4": "English Female - Verse 4.wav",
        "verse 5": "English Female - Verse 5.wav",
        "verse 6": "English Female - Verse 6.wav",
        "pre chorus": "English Female - Pre Chorus.wav",
        "pre chorus 1": "English Female - Pre Chorus 1.wav",
        "pre chorus 2": "English Female - Pre Chorus 2.wav",
        "pre chorus 3": "English Female - Pre Chorus 3.wav",
        "pre chorus 4": "English Female - Pre Chorus 4.wav",
        "chorus": "English Female - Chorus.wav",
        "chorus 1": "English Female - Chorus 1.wav",
        "chorus 2": "English Female - Chorus 2.wav",
        "chorus 3": "English Female - Chorus 3.wav",
        "chorus 4": "English Female - Chorus 4.wav",
        "post chorus": "English Female - Post Chorus.wav",
        "bridge": "English Female - Bridge.wav",
        "bridge 1": "English Female - Bridge 1.wav",
        "bridge 2": "English Female - Bridge 2.wav",
        "bridge 3": "English Female - Bridge 3.wav",
        "bridge 4": "English Female - Bridge 4.wav",
        "bridge 5": "English Female - Bridge 5.wav",
        "instrumental": "English Female - Instrumental.wav",
        "interlude": "English Female - Interlude.wav",
        "vamp": "English Female - Vamp.wav",
        "tag": "English Female - Tag.wav",
        "ending": "English Female - Ending.wav",
        "outro": "English Female - Outro.wav",
        "acapella": "English Female - Acapella.wav",
        "breakdown": "English Female - Breakdown.wav",
        "refrain": "English Female - Refrain.wav",
        "solo": "English Female - Solo.wav",
        "rap": "English Female - Rap.wav",
        "turnaround": "English Female - Turnaround.wav",
        "exhortation": "English Female - Exhortation.wav"
    ]
    
    // MARK: - PCM Buffer Loader & Converter
    
    public func loadAndConvertBuffer(at fileURL: URL, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let cacheKey = "\(fileURL.path)_\(Int(targetFormat.sampleRate))_\(targetFormat.channelCount)"
        lock.lock()
        if let cached = bufferCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return nil }
        let srcFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return nil
        }
        guard (try? audioFile.read(into: srcBuffer)) != nil else { return nil }
        
        // If format already matches target, use as-is
        if srcFormat.sampleRate == targetFormat.sampleRate && srcFormat.channelCount == targetFormat.channelCount {
            lock.lock()
            bufferCache[cacheKey] = srcBuffer
            lock.unlock()
            return srcBuffer
        }
        
        // Format Conversion
        guard let outBuffer = MasteringAudioResampler.convertBuffer(srcBuffer, to: targetFormat) else { return nil }
        
        lock.lock()
        bufferCache[cacheKey] = outBuffer
        lock.unlock()
        return outBuffer
    }
}
