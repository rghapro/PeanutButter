import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Analyzes a Guide stem audio buffer, detects vocal cue bursts, transcribes section callouts,
/// filters out musical/dynamic instructional cues ("cymbals", "all in", "breakdown", "softly", etc.),
/// and maps valid section titles ("Intro", "Verse 1", "Chorus", "Bridge", etc.) to the following measure downbeat.
public final class GuideSectionDetector: @unchecked Sendable {
    
    public struct VocalSegment: Sendable {
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let peakRMS: Float
        
        public init(startTime: TimeInterval, endTime: TimeInterval, peakRMS: Float) {
            self.startTime = startTime
            self.endTime = endTime
            self.peakRMS = peakRMS
        }
    }
    
    public struct DetectedSectionCallout: Sendable {
        public let canonicalName: String
        public let spokenTime: TimeInterval
        public let downbeatTime: TimeInterval
        public let downbeatMeasure: Int
        
        public init(canonicalName: String, spokenTime: TimeInterval, downbeatTime: TimeInterval, downbeatMeasure: Int) {
            self.canonicalName = canonicalName
            self.spokenTime = spokenTime
            self.downbeatTime = downbeatTime
            self.downbeatMeasure = downbeatMeasure
        }
    }
    
    /// Instructional / dynamic cues that must be strictly ignored when spoken by the guide track
    private static let ignoredInstructionalTerms: Set<String> = [
        "cymbal", "cymbals", "swell", "swells",
        "all in", "full band", "band in", "everybody in", "everyone in",
        "breakdown", "break down", "drop", "drop out", "drums in", "drums out",
        "softly", "soft", "quiet", "quietly", "down", "bring it down", "keep it down",
        "build", "building", "keep building", "big build", "slowly build", "crescendo",
        "accents", "accent", "hits", "hit", "big hit", "pushes", "push", "stops", "stop",
        "hold", "diamond", "diamonds", "whole notes", "eighth notes", "quarter notes", "sixteenth",
        "kick", "snare", "tom", "toms", "hi hat", "hat", "ride", "crash", "wash",
        "bass in", "keys in", "piano only", "acoustic only", "guitars in", "electric in",
        "vocals only", "a cappella", "acappella", "pads only", "pad only",
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "1", "2", "3", "4", "5", "6", "7", "8",
        "and", "ready", "go", "here we go", "watch", "listen", "stay", "again", "repeat",
        "last time", "one more time", "double", "half time", "halftime", "double time",
        "cut", "fade", "ritard", "slow down", "click", "only", "loud", "big", "huge"
    ]
    
    /// Contextual strings provided to SFSpeechRecognizer so it strongly favors section names
    private static let contextualSectionHints: [String] = [
        "Intro",
        "Verse", "Verse 1", "Verse 2", "Verse 3", "Verse 4",
        "Pre-Chorus", "Pre Chorus", "Pre-Chorus 1", "Pre-Chorus 2",
        "Chorus", "Chorus 1", "Chorus 2", "Chorus 3",
        "Post-Chorus", "Post Chorus",
        "Instrumental", "Interlude", "Turnaround",
        "Bridge", "Bridge 1", "Bridge 2", "Bridge 3", "Bridge 4", "Bridge 5",
        "Vamp", "Refrain", "Tag", "Passage", "Solo",
        "Outro", "Ending"
    ]
    
    // MARK: - 1. Vocal Burst Detection
    
    /// Scans the PCM buffer in 40ms windows to find distinct spoken voice bursts in the guide track
    public static func detectVocalSegments(in buffer: AVAudioPCMBuffer) -> [VocalSegment] {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return []
        }
        
        let sampleRate = buffer.format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let windowFrames = max(256, Int(sampleRate * 0.04)) // 40ms window
        let numWindows = totalFrames / windowFrames
        guard numWindows > 0 else { return [] }
        
        var rmsValues = [Float](repeating: 0, count: numWindows)
        var maxRMS: Float = 0.0
        
        for w in 0..<numWindows {
            let start = w * windowFrames
            let end = min(totalFrames, start + windowFrames)
            var sumSq: Float = 0.0
            for i in start..<end {
                let s = channelData[i]
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Float(max(1, end - start)))
            rmsValues[w] = rms
            if rms > maxRMS { maxRMS = rms }
        }
        
        guard maxRMS > 0.002 else { return [] }
        
        // Adaptive threshold: 8% of peak RMS (or at least 0.008)
        let threshold = max(0.008, maxRMS * 0.08)
        let windowDuration = Double(windowFrames) / sampleRate
        
        var rawSegments: [VocalSegment] = []
        var inSegment = false
        var segStartWindow = 0
        var segPeak: Float = 0.0
        
        for w in 0..<numWindows {
            let rms = rmsValues[w]
            if rms >= threshold {
                if !inSegment {
                    inSegment = true
                    segStartWindow = w
                    segPeak = rms
                } else if rms > segPeak {
                    segPeak = rms
                }
            } else if inSegment {
                inSegment = false
                let startSec = Double(segStartWindow) * windowDuration
                let endSec = Double(w) * windowDuration
                rawSegments.append(VocalSegment(startTime: startSec, endTime: endSec, peakRMS: segPeak))
            }
        }
        if inSegment {
            let startSec = Double(segStartWindow) * windowDuration
            let endSec = Double(numWindows) * windowDuration
            rawSegments.append(VocalSegment(startTime: startSec, endTime: endSec, peakRMS: segPeak))
        }
        
        // Merge segments separated by less than 0.48s (e.g. "Pre" + "Chorus" or "Verse" + "Two")
        var merged: [VocalSegment] = []
        for seg in rawSegments {
            if let last = merged.last, (seg.startTime - last.endTime) < 0.48 {
                let combined = VocalSegment(
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    peakRMS: max(last.peakRMS, seg.peakRMS)
                )
                merged[merged.count - 1] = combined
            } else {
                merged.append(seg)
            }
        }
        
        // Filter out micro-clicks (< 0.14s) and pad start/end slightly for clean ASR
        let totalDuration = Double(totalFrames) / sampleRate
        return merged.compactMap { seg in
            let dur = seg.endTime - seg.startTime
            guard dur >= 0.14 else { return nil }
            let paddedStart = max(0.0, seg.startTime - 0.15)
            let paddedEnd = min(totalDuration, seg.endTime + 0.20)
            return VocalSegment(startTime: paddedStart, endTime: paddedEnd, peakRMS: seg.peakRMS)
        }
    }
    
    // MARK: - 2. Strictly Filtered Section Name Classifier
    
    /// Parses a spoken phrase and returns a canonical section name ONLY if it is a valid song section
    /// (Intro, Verse, Pre-Chorus, Chorus, Post-Chorus, Bridge, Instrumental, Interlude, Turnaround, Vamp, Tag, Refrain, Solo, Passage, Outro, Ending).
    /// Returns `nil` for instructional cues ("cymbals", "all in", "breakdown", "softly", count-ins, etc.).
    public static func classifySectionCallout(_ rawText: String) -> String? {
        let cleaned = rawText
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleaned.isEmpty else { return nil }
        
        // Quick reject if the entire utterance is an ignored instructional term
        if ignoredInstructionalTerms.contains(cleaned) {
            return nil
        }
        
        // Helper to extract trailing section number (1-6) if spoken ("verse two" -> "2", "bridge 3" -> "3"),
        // while strictly ignoring count-ins spoken immediately after the section name (e.g. "Intro, two, three, four" or "Verse, two, three, four")
        func extractSectionNumber(from text: String, after keyword: String) -> String? {
            guard let range = text.range(of: keyword) else { return nil }
            let afterText = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let tokens = afterText.split(separator: " ").map(String.init)
            guard let first = tokens.first else { return nil }
            
            // If followed by count-in numbers ("two three", "2 3", "one two", "1 2"), it is a count-in, NOT a section number!
            if tokens.count >= 2 {
                let second = tokens[1]
                let countFollowTokens: Set<String> = ["2", "two", "to", "too", "3", "three", "4", "four", "for"]
                if countFollowTokens.contains(second) {
                    return nil
                }
            }
            
            switch first {
            case "1", "one", "won", "first": return "1"
            case "2", "two", "to", "too", "second": return "2"
            case "3", "three", "third": return "3"
            case "4", "four", "for", "fourth": return "4"
            case "5", "five", "fifth": return "5"
            case "6", "six", "sixth": return "6"
            default: return nil
            }
        }
        
        // Check Pre-Chorus & Post-Chorus BEFORE Chorus!
        if cleaned.contains("pre chorus") || cleaned.contains("prechorus") {
            let num = extractSectionNumber(from: cleaned, after: "chorus")
            return num != nil ? "Pre-Chorus \(num!)" : "Pre-Chorus"
        }
        
        if cleaned.contains("post chorus") || cleaned.contains("postchorus") {
            let num = extractSectionNumber(from: cleaned, after: "chorus")
            return num != nil ? "Post-Chorus \(num!)" : "Post-Chorus"
        }
        
        // Chorus (including common phonetic transcriptions like "course" when spoken in isolation)
        let words = cleaned.split(separator: " ").map(String.init)
        if words.contains("chorus") || (words.first == "course" && words.count <= 2) {
            let kw = words.contains("chorus") ? "chorus" : "course"
            let num = extractSectionNumber(from: cleaned, after: kw)
            return num != nil ? "Chorus \(num!)" : "Chorus"
        }
        
        // Verse (including common phonetic transcription "first" only when followed by a number or alone as "verse")
        if words.contains("verse") || words.contains("verses") {
            let kw = words.contains("verses") ? "verses" : "verse"
            let num = extractSectionNumber(from: cleaned, after: kw)
            return num != nil ? "Verse \(num!)" : "Verse"
        }
        
        // Intro / Introduction (always canonical "Intro", never "Intro 2" from count-ins like "Intro, two, three, four")
        if words.contains("intro") || words.contains("introduction") {
            return "Intro"
        }
        
        // Bridge
        if words.contains("bridge") || words.contains("bridges") {
            let kw = words.contains("bridges") ? "bridges" : "bridge"
            let num = extractSectionNumber(from: cleaned, after: kw)
            return num != nil ? "Bridge \(num!)" : "Bridge"
        }
        
        // Instrumental
        if words.contains("instrumental") {
            return "Instrumental"
        }
        
        // Interlude
        if words.contains("interlude") {
            return "Interlude"
        }
        
        // Turnaround
        if words.contains("turnaround") || cleaned.contains("turn around") {
            return "Turnaround"
        }
        
        // Vamp
        if words.contains("vamp") {
            return "Vamp"
        }
        
        // Tag
        if words.contains("tag") {
            return "Tag"
        }
        
        // Refrain
        if words.contains("refrain") {
            return "Refrain"
        }
        
        // Solo
        if words.contains("solo") {
            return "Solo"
        }
        
        // Passage
        if words.contains("passage") {
            return "Passage"
        }
        
        // Outro / Ending
        if words.contains("outro") {
            return "Outro"
        }
        if words.contains("ending") || (words.contains("end") && !cleaned.contains("send")) {
            return "Ending"
        }
        
        // Anything else ("cymbals", "all in", "breakdown", "softly", "drums", "one two three four", etc.) is ignored!
        return nil
    }
    
    // MARK: - 3. Speech Recognition & Downbeat Mapping Pipeline
    
    /// Requests Speech Recognition authorization if not yet determined
    public static func requestSpeechAuthorization() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .authorized {
            return true
        }
        if currentStatus == .denied || currentStatus == .restricted {
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    /// Recognizes speech in a sliced audio buffer corresponding to a single vocal segment
    private static func transcribeBufferSlice(
        _ slice: AVAudioPCMBuffer,
        recognizer: SFSpeechRecognizer
    ) async -> String? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.ContextualStringsSetter(Self.contextualSectionHints)
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }
        request.append(slice)
        request.endAudio()
        
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let ResumeOnce: (String?) -> Void = { text in
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: text)
                }
            }
            
            // Safety timeout (3.5s per short clip)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) {
                ResumeOnce(nil)
            }
            
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    ResumeOnce(result.bestTranscription.formattedString)
                } else if error != nil {
                    ResumeOnce(result?.bestTranscription.formattedString)
                }
            }
        }
    }
    
    /// Full pipeline: detects vocal segments on the Guide buffer, transcribes each segment,
    /// filters out instructional cues, snaps each valid section callout to the FOLLOWING measure downbeat,
    /// and returns a contiguous array of `SongSection`s covering the entire song.
    public static func analyzeGuideAndBuildSections(
        guideBuffer: AVAudioPCMBuffer,
        bpm: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int = 4,
        totalSongDuration: TimeInterval,
        beatGrid: [BeatGridMarker] = [],
        onProgress: @escaping @Sendable (Float, String) -> Void
    ) async -> [SongSection] {
        let vocalSegments = detectVocalSegments(in: guideBuffer)
        let secPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, timeSignatureNumerator))
        let sampleRate = guideBuffer.format.sampleRate
        let downbeatMarkers = beatGrid.filter { $0.isDownbeat }
        
        var callouts: [DetectedSectionCallout] = []
        
        let isAuthorized = await requestSpeechAuthorization()
        let recognizer = isAuthorized ? (SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()) : nil
        
        if let recognizer = recognizer, recognizer.isAvailable, !vocalSegments.isEmpty {
            let totalSegs = vocalSegments.count
            for (index, seg) in vocalSegments.enumerated() {
                let progress = Float(index) / Float(max(1, totalSegs))
                onProgress(progress, "Listening to Guide cue \(index + 1) of \(totalSegs)...")
                
                let startFrame = AVAudioFramePosition(seg.startTime * sampleRate)
                let frameCount = AVAudioFrameCount((seg.endTime - seg.startTime) * sampleRate)
                guard let slice = sliceMonoBuffer(guideBuffer, startFrame: startFrame, frameCount: frameCount) else {
                    continue
                }
                
                if let transcript = await transcribeBufferSlice(slice, recognizer: recognizer),
                   let canonicalName = classifySectionCallout(transcript) {
                    // Snap to the FOLLOWING measure downbeat after the cue begins
                    // In MultiTracks guide tracks, the cue ("Intro", "Verse 1", "Chorus") is called out
                    // 2 to 4 beats BEFORE the downbeat of that section.
                    let cueMidTime = (seg.startTime + seg.endTime) * 0.5
                    let downbeatTime: TimeInterval
                    let downbeatMeasure: Int
                    
                    if let nextDownbeat = downbeatMarkers.first(where: { $0.time >= cueMidTime + 0.08 }) {
                        downbeatTime = nextDownbeat.time
                        downbeatMeasure = nextDownbeat.bar
                    } else {
                        let nextMeasureIndex = max(1, Int(ceil((cueMidTime + 0.08) / secPerMeasure)))
                        downbeatTime = Double(nextMeasureIndex) * secPerMeasure
                        downbeatMeasure = nextMeasureIndex + 1 // 1-indexed measure number
                    }
                    
                    if downbeatTime < totalSongDuration - (secPerMeasure * 0.5) {
                        // If multiple callouts map to the exact same downbeat, keep the latest one
                        if let existingIdx = callouts.firstIndex(where: { $0.downbeatMeasure == downbeatMeasure }) {
                            callouts[existingIdx] = DetectedSectionCallout(
                                canonicalName: canonicalName,
                                spokenTime: seg.startTime,
                                downbeatTime: downbeatTime,
                                downbeatMeasure: downbeatMeasure
                            )
                        } else {
                            callouts.append(
                                DetectedSectionCallout(
                                    canonicalName: canonicalName,
                                    spokenTime: seg.startTime,
                                    downbeatTime: downbeatTime,
                                    downbeatMeasure: downbeatMeasure
                                )
                            )
                        }
                    }
                }
            }
        }
        
        callouts.sort { $0.downbeatTime < $1.downbeatTime }
        
        // If the song opens with an unannounced count-in (e.g. "one, two, one, two, three, four")
        // followed by music before the first called section, split Count In from the unlabeled Intro.
        if let inferredIntro = inferIntroCalloutIfNeeded(
            callouts: callouts,
            vocalSegments: vocalSegments,
            bpm: bpm,
            timeSignatureNumerator: timeSignatureNumerator,
            timeSignatureDenominator: timeSignatureDenominator,
            totalSongDuration: totalSongDuration,
            beatGrid: beatGrid
        ) {
            callouts.insert(inferredIntro, at: 0)
        }
        
        // Auto-number repeated sections ("Verse" -> "Verse 1", "Verse 2") if the guide just said "Verse"
        callouts = autoNumberRepeatedSections(callouts)
        
        onProgress(1.0, "Building song section roadmap...")
        return buildContiguousSections(
            from: callouts,
            secPerMeasure: secPerMeasure,
            totalSongDuration: totalSongDuration,
            beatGrid: beatGrid,
            bpm: bpm,
            timeSignatureNumerator: timeSignatureNumerator,
            timeSignatureDenominator: timeSignatureDenominator
        )
    }
    
    /// When the top of a song only contains spoken count-in bursts (without naming the incoming section)
    /// and at least one measure passes before the first called section, labels the section right after the count-in as "Intro".
    public static func inferIntroCalloutIfNeeded(
        callouts: [DetectedSectionCallout],
        vocalSegments: [VocalSegment],
        bpm: Double,
        timeSignatureNumerator: Int,
        timeSignatureDenominator: Int = 4,
        totalSongDuration: TimeInterval,
        beatGrid: [BeatGridMarker] = []
    ) -> DetectedSectionCallout? {
        let sortedCallouts = callouts.sorted { $0.downbeatTime < $1.downbeatTime }
        let firstCallout = sortedCallouts.first
        
        // If the first detected section is already Intro, nothing needs inferring
        if firstCallout?.canonicalName == "Intro" {
            return nil
        }
        
        let secPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, timeSignatureDenominator)))
        let secPerMeasure = secPerBeat * Double(max(1, timeSignatureNumerator))
        let downbeatMarkers = beatGrid.filter { $0.isDownbeat }.sorted { $0.time < $1.time }
        
        // Only infer an "Intro" if the guide does not call another section during the opening count-in.
        // For example, "one, two, verse, two, three, four" calls Verse right inside the 2-bar count-in
        // and should produce a 2-bar Count In directly into Verse (not 1-bar Count In + 1-bar Intro).
        if let first = firstCallout, first.spokenTime < secPerMeasure * 2.5 {
            return nil
        }
        
        let sortedSegs = vocalSegments.sorted { $0.startTime < $1.startTime }
        guard let opener = sortedSegs.first else { return nil }
        
        // Opener must start inside the count-in window at the top of the song
        guard opener.startTime < secPerMeasure * 2.5 else { return nil }
        
        let maxGapBetweenCountBursts = max(secPerMeasure * 0.85, secPerBeat * 2.5)
        let latestAllowedEnd = firstCallout.map { $0.spokenTime - secPerBeat * 0.5 }
            ?? (totalSongDuration - secPerMeasure)
        guard opener.endTime <= latestAllowedEnd + 0.25 else { return nil }
        
        var clusterEnd = opener.endTime
        for seg in sortedSegs.dropFirst() {
            let gap = seg.startTime - clusterEnd
            guard gap <= maxGapBetweenCountBursts,
                  seg.startTime < secPerMeasure * 4.0,
                  seg.endTime <= latestAllowedEnd + 0.25 else {
                break
            }
            clusterEnd = max(clusterEnd, seg.endTime)
        }
        
        // Subtract the +0.20s ASR padding added by detectVocalSegments
        let rawCountEnd = max(0.0, clusterEnd - 0.20)
        let tolerance = min(0.20, secPerBeat * 0.35)
        
        let introTime: TimeInterval
        let introMeasure: Int
        if let nextDownbeat = downbeatMarkers.first(where: { $0.time >= rawCountEnd - tolerance && $0.bar >= 2 }) {
            introTime = nextDownbeat.time
            introMeasure = nextDownbeat.bar
        } else {
            let measureIndex = max(1, Int(ceil((rawCountEnd - tolerance) / secPerMeasure)))
            introTime = Double(measureIndex) * secPerMeasure
            introMeasure = measureIndex + 1
        }
        
        guard introMeasure >= 2 else { return nil }
        if let first = firstCallout {
            guard first.downbeatMeasure - introMeasure >= 2,
                  introTime < first.downbeatTime - (secPerMeasure * 1.5) else {
                return nil
            }
        } else {
            guard introTime < totalSongDuration - (secPerMeasure * 0.75) else {
                return nil
            }
        }
        
        return DetectedSectionCallout(
            canonicalName: "Intro",
            spokenTime: opener.startTime,
            downbeatTime: introTime,
            downbeatMeasure: introMeasure
        )
    }
    
    /// Builds contiguous sections from the detected downbeat callouts, automatically adding "Count In"
    /// from 0.0 up to the first detected section downbeat if the first section starts after bar 1.
    public static func buildContiguousSections(
        from callouts: [DetectedSectionCallout],
        secPerMeasure: Double,
        totalSongDuration: TimeInterval,
        beatGrid: [BeatGridMarker] = [],
        bpm: Double = 120.0,
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4
    ) -> [SongSection] {
        guard !callouts.isEmpty else { return [] }
        
        var sections: [SongSection] = []
        let sorted = callouts.sorted { $0.downbeatTime < $1.downbeatTime }
        
        // 1. If the first detected section starts at measure 2 or later, insert "Count In" from 0.0 to first.downbeatTime
        if let first = sorted.first, first.downbeatTime >= secPerMeasure * 0.75 {
            let countInMeasures = max(1, first.downbeatMeasure - 1)
            let countInSection = SongSection(
                name: "Count In",
                abbreviation: "Co",
                startTime: 0.0,
                audioStartTime: 0.0,
                duration: first.downbeatTime,
                startMeasure: 1,
                measureCount: countInMeasures
            )
            sections.append(countInSection)
        }
        
        // 2. Build each detected section extending until the start of the next detected section (or end of song audio)
        for i in 0..<sorted.count {
            let current = sorted[i]
            let nextStartTime = (i + 1 < sorted.count) ? sorted[i + 1].downbeatTime : totalSongDuration
            let duration = max(secPerMeasure, nextStartTime - current.downbeatTime)
            let measureCount: Int = {
                if !beatGrid.isEmpty {
                    if i + 1 < sorted.count {
                        let span = sorted[i + 1].downbeatMeasure - current.downbeatMeasure
                        if span >= 1 { return span }
                    }
                    return Song.measureCount(
                        inSourceGrid: beatGrid,
                        audioStart: current.downbeatTime,
                        duration: duration,
                        fallbackBPM: bpm,
                        timeSignatureNumerator: timeSignatureNumerator,
                        timeSignatureDenominator: timeSignatureDenominator
                    )
                }
                return max(1, Int(round(duration / secPerMeasure)))
            }()
            
            let sec = SongSection(
                name: current.canonicalName,
                abbreviation: SongSection.abbreviation(for: current.canonicalName),
                startTime: current.downbeatTime,
                audioStartTime: current.downbeatTime,
                duration: duration,
                startMeasure: current.downbeatMeasure,
                measureCount: measureCount
            )
            sections.append(sec)
        }
        
        return sections
    }
    
    /// Numbers unnumbered repeated sections (e.g., if "Verse" appears twice without a number, labels them "Verse 1", "Verse 2")
    private static func autoNumberRepeatedSections(_ callouts: [DetectedSectionCallout]) -> [DetectedSectionCallout] {
        let numberableBaseNames: Set<String> = ["Verse", "Bridge"]
        var counts: [String: Int] = [:]
        for c in callouts {
            if numberableBaseNames.contains(c.canonicalName) {
                counts[c.canonicalName, default: 0] += 1
            }
        }
        
        var runningIndex: [String: Int] = [:]
        return callouts.map { c in
            if numberableBaseNames.contains(c.canonicalName), (counts[c.canonicalName] ?? 0) > 1 {
                let nextIdx = (runningIndex[c.canonicalName] ?? 0) + 1
                runningIndex[c.canonicalName] = nextIdx
                return DetectedSectionCallout(
                    canonicalName: "\(c.canonicalName) \(nextIdx)",
                    spokenTime: c.spokenTime,
                    downbeatTime: c.downbeatTime,
                    downbeatMeasure: c.downbeatMeasure
                )
            }
            return c
        }
    }
    
    /// Extracts a mono 16kHz/44.1kHz float buffer slice suitable for SFSpeechAudioBufferRecognitionRequest
    private static func sliceMonoBuffer(
        _ buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        let totalFrames = Int64(buffer.frameLength)
        let clampedStart = max(0, min(totalFrames, startFrame))
        let available = max(0, totalFrames - clampedStart)
        let copyCount = AVAudioFrameCount(min(Int64(frameCount), available))
        guard copyCount > 0,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: copyCount),
              let dst = outBuffer.floatChannelData?[0],
              let src0 = buffer.floatChannelData?[0] else {
            return nil
        }
        
        outBuffer.frameLength = copyCount
        let count = Int(copyCount)
        let start = Int(clampedStart)
        
        if buffer.format.channelCount > 1, let src1 = buffer.floatChannelData?[1] {
            for i in 0..<count {
                dst[i] = (src0[start + i] + src1[start + i]) * 0.5
            }
        } else {
            memcpy(dst, src0.advanced(by: start), count * MemoryLayout<Float>.size)
        }
        
        return outBuffer
    }
}

private extension SFSpeechAudioBufferRecognitionRequest {
    func ContextualStringsSetter(_ strings: [String]) {
        self.contextualStrings = strings
    }
}
