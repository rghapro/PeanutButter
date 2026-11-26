import Foundation
import AVFoundation
import Accelerate
import CLame

public enum PracticeInstrument: String, CaseIterable, Identifiable, Sendable {
    case electricGuitars = "Electric Guitars (All)"
    case bass = "Bass"
    case drums = "Drums"
    case acoustic = "Acoustic"
    case piano = "Piano"
    case vocals = "Vocals"

    public var id: String { rawValue }

    public var fileLabel: String {
        switch self {
        case .electricGuitars: return "Electric Guitars (All)"
        case .bass: return "Bass"
        case .drums: return "Drums"
        case .acoustic: return "Acoustic"
        case .piano: return "Piano"
        case .vocals: return "Vocals"
        }
    }

    public func matches(category: StemCategory) -> Bool {
        switch self {
        case .electricGuitars:
            return category == .electricGuitars
        case .bass:
            return category == .bass || category == .synthBass
        case .drums:
            return category == .drums || category == .percussion
        case .acoustic:
            return category == .acousticGuitars
        case .piano:
            return category == .piano
        case .vocals:
            return category == .vocals
        }
    }
}

public enum BounceAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3 = "MP3 (256kbps)"
    case m4a = "M4A (AAC)"
    case wav = "WAV (PCM)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        case .wav: return "wav"
        }
    }
}

/// Faster-than-real-time offline audio renderer for Session Reference Tracks and Song Practice Tracks (5.3).
public final class OfflineBounceEngine {
    public static let secondaryInstrumentGain: Float = powf(10.0, -10.0 / 20.0) // -10 dB (~0.3162)
    public static let backgroundTrackGain: Float = powf(10.0, -20.0 / 20.0)     // -20 dB (0.1000)
    public static let stopCueGapSeconds: TimeInterval = 5.0

    public init() {}

    // MARK: - Gain Staging & Naming Rules

    public static func isCoreInstrument(_ category: StemCategory) -> Bool {
        switch category {
        case .drums, .percussion, .bass, .synthBass,
             .acousticGuitars, .electricGuitars,
             .piano, .vocals:
            return true
        default:
            return false
        }
    }

    public static func computePracticeGain(
        category: StemCategory,
        targetInstrument: PracticeInstrument,
        includeClick: Bool,
        includeGuide: Bool
    ) -> Float {
        if category == .click {
            return includeClick ? 1.0 : 0.0
        }
        if category == .guide {
            return includeGuide ? 1.0 : 0.0
        }
        if targetInstrument.matches(category: category) {
            return 1.0 // 0 dB (Prominent / Target)
        }
        if isCoreInstrument(category) {
            return secondaryInstrumentGain // -10 dB
        }
        return backgroundTrackGain // -20 dB (Synths, Loops, FX, BGV/Other)
    }

    public static func practiceTrackFileName(
        song: Song,
        instrument: PracticeInstrument,
        fileExtension: String
    ) -> String {
        let safeTitle = sanitizeFileComponent(song.title.isEmpty ? "Untitled" : song.title)
        let safeKey = sanitizeFileComponent(song.musicalKey.isEmpty ? "C" : song.musicalKey)
        return "\(safeTitle) - \(instrument.fileLabel) - Key of \(safeKey).\(fileExtension)"
    }

    public static func transitionGapSeconds(for transition: SongTransitionType) -> TimeInterval {
        switch transition {
        case .stayInSong, .cueNextSong, .cueFirstSong:
            return stopCueGapSeconds // 5-second gap
        case .autoLink, .overlap, .crossfade:
            return 0.0
        }
    }

    // MARK: - Session Reference Track Bounce (5.3A)

    @MainActor
    public static func bounceSessionReference(
        engine: MultitrackAudioEngine,
        includedSongIds: Set<UUID>? = nil,
        includeClick: Bool,
        includeGuide: Bool,
        format: BounceAudioFormat,
        outputURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let songs: [Song]
        if let includedIds = includedSongIds {
            songs = engine.currentSetlist.songs.filter { includedIds.contains($0.id) }
        } else {
            songs = engine.currentSetlist.songs
        }
        guard !songs.isEmpty else {
            let message = includedSongIds != nil ? "Select at least one song to bounce." : "Setlist has no songs to bounce."
            throw NSError(domain: "OfflineBounceEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let sampleRate: Double = 44100.0
        let padFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let padFadeIn = engine.padPlayer.fadeInSeconds
        let padFadeOut = engine.padPlayer.fadeOutSeconds
        let basePadVolume = engine.padChannelVolume
        let basePadPan = engine.padChannelPan
        let basePadMuted = engine.padChannelMuted
        let padBus = engine.busses.first(where: { $0.name.lowercased() == "pad" })
        let anyBusSoloed = engine.busses.contains(where: { $0.isSoloed })
        let padBusGain: Float = {
            if let pb = padBus {
                let muted = anyBusSoloed ? (!pb.isSoloed || pb.isMuted) : pb.isMuted
                return muted ? 0.0 : pb.linearGain
            }
            return anyBusSoloed ? 0.0 : 1.0
        }()
        let defaultPackId = PadLibraryManager.shared.activePackId

        let totalSongs = songs.count
        var songMixes: [(song: Song, left: [Float], right: [Float])] = []
        var prevEndedWithPad = false

        for (idx, song) in songs.enumerated() {
            progress(Double(idx) / Double(totalSongs) * 0.85, "Rendering \(song.title)...")
            let trackBuffers = engine.tracksWithBuffersForBounce(song: song)

            let wasContinuingFromPrevSong = idx > 0 && songs[idx - 1].continuePad && prevEndedWithPad
            let initialPadActive = song.startPadWithSong || wasContinuingFromPrevSong
            let songBaseKey = AudioSampleBank.normalizeKeyForPad(
                (!song.currentTransposedKey.isEmpty && song.currentTransposedKey != "—")
                    ? song.currentTransposedKey
                    : ((!song.musicalKey.isEmpty && song.musicalKey != "—") ? song.musicalKey : "C")
            )
            let songBasePack = song.padPresetId ?? defaultPackId

            // Pre-load pad buffers needed for this song's base key/pack and any pad automation points
            var padBuffers: [String: AVAudioPCMBuffer] = [:]
            let loadPadBuf: (String, String) -> Void = { key, pack in
                let norm = AudioSampleBank.normalizeKeyForPad(key)
                let mapKey = "\(norm)|\(pack)"
                if padBuffers[mapKey] == nil,
                   let buf = PadLibraryManager.shared.getPadBuffer(for: norm, packId: pack, format: padFormat) {
                    padBuffers[mapKey] = buf
                }
            }
            loadPadBuf(songBaseKey, songBasePack)
            for pt in song.automationPoints {
                if pt.padKey != nil || pt.padPackId != nil {
                    loadPadBuf(pt.padKey ?? songBaseKey, pt.padPackId ?? songBasePack)
                }
            }

            let shouldContinueAfterSong = (idx < songs.count - 1) && song.continuePad
            let (renderedMix, endedWithPad) = await Task.detached(priority: .userInitiated) {
                var mix = Self.renderSongMix(
                    song: song,
                    trackBuffers: trackBuffers,
                    sampleRate: sampleRate,
                    applyAutomation: true,
                    gainProvider: { track in
                        if track.role == .click { return includeClick ? track.volume : 0.0 }
                        if track.role == .guide { return includeGuide ? track.volume : 0.0 }
                        return track.isMuted ? 0.0 : track.volume
                    }
                )
                let endedActive = Self.mixPadIntoSong(
                    left: &mix.left,
                    right: &mix.right,
                    song: song,
                    sampleRate: sampleRate,
                    initialPadActive: initialPadActive,
                    wasContinuingFromPrevSong: wasContinuingFromPrevSong,
                    shouldContinueAfterSong: shouldContinueAfterSong,
                    baseKey: songBaseKey,
                    basePackId: songBasePack,
                    padBuffers: padBuffers,
                    fadeInSeconds: padFadeIn,
                    fadeOutSeconds: padFadeOut,
                    basePadVolume: basePadVolume,
                    basePadPan: basePadPan,
                    basePadMuted: basePadMuted,
                    padBusGain: padBusGain
                )
                return (mix, endedActive)
            }.value
            prevEndedWithPad = endedWithPad
            songMixes.append((song, renderedMix.left, renderedMix.right))
        }

        progress(0.88, "Assembling continuous service track...")
        let gapFrames = Int(stopCueGapSeconds * sampleRate)

        let totalFrames = songMixes.enumerated().reduce(0) { acc, pair in
            let (idx, item) = pair
            let gap = (idx < songMixes.count - 1) ? Int(transitionGapSeconds(for: item.song.transitionType) * sampleRate) : 0
            return acc + item.left.count + gap
        }

        var outLeft = [Float](repeating: 0, count: totalFrames)
        var outRight = [Float](repeating: 0, count: totalFrames)
        var cursor = 0

        for (idx, item) in songMixes.enumerated() {
            let count = item.left.count
            if count > 0 {
                outLeft.replaceSubrange(cursor..<(cursor + count), with: item.left)
                outRight.replaceSubrange(cursor..<(cursor + count), with: item.right)
                cursor += count
            }
            if idx < songMixes.count - 1 {
                let gap = Int(transitionGapSeconds(for: item.song.transitionType) * sampleRate)
                cursor += min(gap, gapFrames)
            }
        }

        progress(0.94, "Writing \(outputURL.lastPathComponent)...")
        try await Task.detached(priority: .userInitiated) {
            Self.softLimitStereo(left: &outLeft, right: &outRight)
            try Self.writeAudioFile(left: outLeft, right: outRight, sampleRate: sampleRate, format: format, to: outputURL)
        }.value

        progress(1.0, "Bounce complete!")
    }

    // MARK: - Song Practice Tracks Bounce (5.3B)

    @MainActor
    public static func bouncePracticeTracks(
        song: Song,
        trackBuffers: [(track: StemTrack, buffer: AVAudioPCMBuffer)],
        instruments: [PracticeInstrument],
        includeClick: Bool,
        includeGuide: Bool,
        format: BounceAudioFormat,
        outputDirectory: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [URL] {
        guard !instruments.isEmpty else {
            throw NSError(domain: "OfflineBounceEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Select at least one practice instrument."])
        }

        let sampleRate: Double = 44100.0
        var writtenURLs: [URL] = []

        for (idx, instrument) in instruments.enumerated() {
            let fileName = practiceTrackFileName(song: song, instrument: instrument, fileExtension: format.fileExtension)
            let destURL = outputDirectory.appendingPathComponent(fileName)
            progress(Double(idx) / Double(instruments.count), "Rendering \(instrument.fileLabel)...")

            try await Task.detached(priority: .userInitiated) {
                var rendered = Self.renderSongMix(
                    song: song,
                    trackBuffers: trackBuffers,
                    sampleRate: sampleRate,
                    gainProvider: { track in
                        let category = StemCategory.category(for: track.name, role: track.role)
                        return Self.computePracticeGain(
                            category: category,
                            targetInstrument: instrument,
                            includeClick: includeClick,
                            includeGuide: includeGuide
                        )
                    }
                )
                Self.softLimitStereo(left: &rendered.left, right: &rendered.right)
                try Self.writeAudioFile(left: rendered.left, right: rendered.right, sampleRate: sampleRate, format: format, to: destURL)
            }.value

            writtenURLs.append(destURL)
        }

        progress(1.0, "Exported \(writtenURLs.count) practice tracks!")
        return writtenURLs
    }

    // MARK: - Offline Mix Kernel

    private static func renderSongMix(
        song: Song,
        trackBuffers: [(track: StemTrack, buffer: AVAudioPCMBuffer)],
        sampleRate: Double,
        applyAutomation: Bool = false,
        gainProvider: (StemTrack) -> Float
    ) -> (left: [Float], right: [Float]) {
        let arrangementSlices: [(startSec: Double, endSec: Double, sourceStartSec: Double, muteStems: Bool)] = {
            if !song.sections.isEmpty {
                return song.sections.map { sec in
                    let dur = max(0.0, sec.endTime - sec.startTime)
                    let srcStart = sec.sourceAudioStartTime ?? sec.startTime
                    return (sec.startTime, sec.startTime + dur, srcStart, sec.effectiveIsClickSection)
                }
            } else {
                let maxDur = trackBuffers.map { Double($0.buffer.frameLength) / $0.buffer.format.sampleRate }.max() ?? 0.0
                return [(0.0, maxDur, 0.0, false)]
            }
        }()

        let totalSeconds = arrangementSlices.map { $0.endSec }.max() ?? 0.0
        let totalFrames = max(1, Int((totalSeconds * sampleRate).rounded()))

        var outLeft = [Float](repeating: 0, count: totalFrames)
        var outRight = [Float](repeating: 0, count: totalFrames)

        let sortedAutomation: [AutomationPoint] = (applyAutomation && !song.automationPoints.isEmpty)
            ? song.automationPoints.sorted { $0.time < $1.time }
            : []
        let secPerBeat = (60.0 / max(20.0, song.bpm)) * (4.0 / Double(max(1, song.timeSignatureDenominator)))
        let blockSize = 64

        let bounceStereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        for (track, rawBuffer) in trackBuffers {
            let baseGain = gainProvider(track)
            let isUtility = (track.role == .click || track.role == .guide)
            let isTimelineAligned = (track.role == .click && song.clickSource == .generated)
                || (track.role == .guide && song.guideSource == .generated)
            let hasTrackAutomation = !sortedAutomation.isEmpty && !isUtility && sortedAutomation.contains {
                $0.trackFaders[track.id] != nil || $0.trackPans[track.id] != nil || $0.trackMutes[track.id] != nil
            }
            if !hasTrackAutomation && baseGain <= 0.0001 { continue }

            let buffer: AVAudioPCMBuffer
            if abs(rawBuffer.format.sampleRate - sampleRate) > 0.5 {
                buffer = PlaybackFileManager.normalizeBuffer(rawBuffer, to: bounceStereoFormat)
            } else {
                buffer = rawBuffer
            }
            guard let channelData = buffer.floatChannelData else { continue }

            let bufRate = buffer.format.sampleRate
            let bufFrames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard bufFrames > 0, channelCount > 0 else { continue }

            let basePan = max(-1.0, min(1.0, track.pan))
            let staticLeftGain = baseGain * cosf((basePan + 1.0) * Float.pi * 0.25) * 1.4142135
            let staticRightGain = baseGain * sinf((basePan + 1.0) * Float.pi * 0.25) * 1.4142135

            let srcLeft = channelData[0]
            let srcRight = channelCount > 1 ? channelData[1] : channelData[0]

            for slice in arrangementSlices {
                if slice.muteStems && !isUtility { continue }

                let destStartFrame = max(0, Int((slice.startSec * sampleRate).rounded()))
                let destEndFrame = min(totalFrames, Int((slice.endSec * sampleRate).rounded()))
                let sliceFrameCount = destEndFrame - destStartFrame
                guard sliceFrameCount > 0 else { continue }

                let effectiveSourceStartSec = isTimelineAligned ? slice.startSec : slice.sourceStartSec
                let srcStartSample = Int((effectiveSourceStartSec * bufRate).rounded())
                let rateRatio = bufRate / sampleRate

                if !hasTrackAutomation {
                    for i in 0..<sliceFrameCount {
                        let srcIdx = srcStartSample + Int(Double(i) * rateRatio)
                        guard srcIdx >= 0 && srcIdx < bufFrames else { continue }
                        let dIdx = destStartFrame + i
                        outLeft[dIdx] += srcLeft[srcIdx] * staticLeftGain
                        outRight[dIdx] += srcRight[srcIdx] * staticRightGain
                    }
                } else {
                    var i = 0
                    while i < sliceFrameCount {
                        let blockEnd = min(sliceFrameCount, i + blockSize)
                        let tSec = Double(destStartFrame + i) / sampleRate
                        let (effVol, effPan, effMuted) = Self.evaluateTrackAutomation(
                            track: track,
                            at: tSec,
                            sortedPoints: sortedAutomation,
                            secPerBeat: secPerBeat
                        )
                        if !effMuted && effVol > 0.0001 {
                            let pan = max(-1.0, min(1.0, effPan))
                            let lGain = effVol * cosf((pan + 1.0) * Float.pi * 0.25) * 1.4142135
                            let rGain = effVol * sinf((pan + 1.0) * Float.pi * 0.25) * 1.4142135
                            for j in i..<blockEnd {
                                let srcIdx = srcStartSample + Int(Double(j) * rateRatio)
                                guard srcIdx >= 0 && srcIdx < bufFrames else { continue }
                                let dIdx = destStartFrame + j
                                outLeft[dIdx] += srcLeft[srcIdx] * lGain
                                outRight[dIdx] += srcRight[srcIdx] * rGain
                            }
                        }
                        i = blockEnd
                    }
                }
            }
        }

        return (outLeft, outRight)
    }

    private static func evaluateTrackAutomation(
        track: StemTrack,
        at time: TimeInterval,
        sortedPoints: [AutomationPoint],
        secPerBeat: Double
    ) -> (volume: Float, pan: Float, isMuted: Bool) {
        var vol = track.volume
        var pan = track.pan
        var muted = track.isMuted

        if let activeIdx = sortedPoints.firstIndex(where: {
            let durationSec = Double($0.transitionBeats) * secPerBeat
            return durationSec > 0.001 && time >= $0.time && time <= ($0.time + durationSec)
        }) {
            let activePoint = sortedPoints[activeIdx]
            let durationSec = Double(activePoint.transitionBeats) * secPerBeat
            let progress = Float((time - activePoint.time) / durationSec)
            let prevPoint = activeIdx > 0 ? sortedPoints[activeIdx - 1] : nil

            if let targetVol = activePoint.trackFaders[track.id] {
                let startVol = prevPoint?.trackFaders[track.id] ?? track.volume
                vol = max(0.0, min(1.0, startVol + (targetVol - startVol) * progress))
            }
            if let targetPan = activePoint.trackPans[track.id] {
                let startPan = prevPoint?.trackPans[track.id] ?? track.pan
                pan = max(-1.0, min(1.0, startPan + (targetPan - startPan) * progress))
            }
            if let m = activePoint.trackMutes[track.id] {
                muted = m
            }
            return (vol, pan, muted)
        }

        if let lastPassed = sortedPoints.last(where: { $0.time <= time }) {
            if let v = lastPassed.trackFaders[track.id] { vol = v }
            if let p = lastPassed.trackPans[track.id] { pan = p }
            if let m = lastPassed.trackMutes[track.id] { muted = m }
        }
        return (vol, pan, muted)
    }

    private static func mixPadIntoSong(
        left: inout [Float],
        right: inout [Float],
        song: Song,
        sampleRate: Double,
        initialPadActive: Bool,
        wasContinuingFromPrevSong: Bool,
        shouldContinueAfterSong: Bool,
        baseKey: String,
        basePackId: String,
        padBuffers: [String: AVAudioPCMBuffer],
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        basePadVolume: Float,
        basePadPan: Float,
        basePadMuted: Bool,
        padBusGain: Float
    ) -> Bool {
        let totalFrames = left.count
        guard totalFrames > 0 else { return initialPadActive }

        let sortedAutomation = song.automationPoints.sorted { $0.time < $1.time }
        let hasAnyPadAutomation = sortedAutomation.contains {
            $0.padActive == true || $0.padMuted != nil || $0.padVolume != nil || $0.padPan != nil || $0.padKey != nil || $0.padPackId != nil
        }
        if !initialPadActive && !hasAnyPadAutomation {
            return false
        }

        let songDuration = Double(totalFrames) / sampleRate
        let secPerBeat = (60.0 / max(20.0, song.bpm)) * (4.0 / Double(max(1, song.timeSignatureDenominator)))
        let fadeInStep = Float(1.0 / (max(0.05, fadeInSeconds) * sampleRate))
        let fadeOutStep = Float(1.0 / (max(0.05, fadeOutSeconds) * sampleRate))
        let keyCrossfadeStep = Float(1.0 / (1.5 * sampleRate))
        let loopCrossfadeSeconds = 5.0
        let blockSize = 64

        var fadeGain: Float = wasContinuingFromPrevSong ? 1.0 : 0.0
        var primaryFrame = 0
        var crossfadeFrame = 0
        var lastActiveState = initialPadActive

        var currentMapKey = "\(baseKey)|\(basePackId)"
        var outgoingBuf: AVAudioPCMBuffer? = nil
        var outgoingFrame = 0
        var keyCrossfadeProgress: Float = 1.0

        func sampleLoopingPad(_ buf: AVAudioPCMBuffer, primary: inout Int, crossfade: inout Int) -> (Float, Float) {
            guard let chData = buf.floatChannelData, buf.frameLength > 0 else { return (0, 0) }
            let bufLen = Int(buf.frameLength)
            let pL = chData[0]
            let pR = buf.format.channelCount > 1 ? chData[1] : chData[0]
            let crossfadeFrames = min(Int(loopCrossfadeSeconds * sampleRate), max(1, bufLen / 3))
            let loopPoint = max(1, bufLen - crossfadeFrames)

            let sL: Float
            let sR: Float
            if primary < loopPoint {
                sL = pL[primary % bufLen]
                sR = pR[primary % bufLen]
                primary += 1
            } else {
                let crossIdx = primary - loopPoint
                let t = max(0.0, min(1.0, Float(crossIdx) / Float(max(1, crossfadeFrames))))
                let angle = t * (Float.pi * 0.5)
                let w1 = cos(angle)
                let w2 = sin(angle)
                let idx1 = min(primary, bufLen - 1)
                let idx2 = crossfade % bufLen
                sL = pL[idx1] * w1 + pL[idx2] * w2
                sR = pR[idx1] * w1 + pR[idx2] * w2
                primary += 1
                crossfade += 1
                if primary >= bufLen {
                    primary = crossfade
                    crossfade = 0
                }
            }
            return (sL, sR)
        }

        var frame = 0
        while frame < totalFrames {
            let blockEnd = min(totalFrames, frame + blockSize)
            let tSec = Double(frame) / sampleRate

            // Evaluate effective pad state at tSec
            var padOn = initialPadActive
            var effKey = baseKey
            var effPack = basePackId
            var effVol = basePadVolume
            var effPan = basePadPan
            var effMuted = basePadMuted

            if song.padIntroOutroOnly, !song.sections.isEmpty {
                if let sec = song.sections.first(where: { tSec >= $0.startTime && tSec < $0.endTime }) {
                    if !sec.isIntroOrOutro {
                        padOn = false
                    }
                }
            }

            if !sortedAutomation.isEmpty {
                if let activeIdx = sortedAutomation.firstIndex(where: {
                    let dur = Double($0.transitionBeats) * secPerBeat
                    return dur > 0.001 && tSec >= $0.time && tSec <= ($0.time + dur)
                }) {
                    let pt = sortedAutomation[activeIdx]
                    let dur = Double(pt.transitionBeats) * secPerBeat
                    let progress = Float((tSec - pt.time) / dur)
                    let prev = activeIdx > 0 ? sortedAutomation[activeIdx - 1] : nil
                    if let a = pt.padActive { padOn = a }
                    if let k = pt.padKey { effKey = AudioSampleBank.normalizeKeyForPad(k) }
                    if let p = pt.padPackId { effPack = p }
                    if let m = pt.padMuted { effMuted = m }
                    if let tv = pt.padVolume {
                        let sv = prev?.padVolume ?? basePadVolume
                        effVol = max(0.0, min(1.0, sv + (tv - sv) * progress))
                    }
                    if let tp = pt.padPan {
                        let sp = prev?.padPan ?? basePadPan
                        effPan = max(-1.0, min(1.0, sp + (tp - sp) * progress))
                    }
                } else if let lastPt = sortedAutomation.last(where: { $0.time <= tSec }) {
                    if let a = lastPt.padActive { padOn = a }
                    if let k = lastPt.padKey { effKey = AudioSampleBank.normalizeKeyForPad(k) }
                    if let p = lastPt.padPackId { effPack = p }
                    if let m = lastPt.padMuted { effMuted = m }
                    if let v = lastPt.padVolume { effVol = v }
                    if let p = lastPt.padPan { effPan = p }
                }
            }

            // Fade out smoothly at the end of the song when not continuing into the next song
            if !shouldContinueAfterSong && fadeOutSeconds > 0.05 && songDuration > fadeOutSeconds && tSec >= (songDuration - fadeOutSeconds) {
                padOn = false
            }

            lastActiveState = padOn

            let mapKey = "\(effKey)|\(effPack)"
            guard let padBuf = padBuffers[mapKey] ?? padBuffers["\(baseKey)|\(basePackId)"],
                  padBuf.frameLength > 0 else {
                frame = blockEnd
                continue
            }

            if mapKey != currentMapKey {
                if let prevBuf = padBuffers[currentMapKey] ?? padBuffers["\(baseKey)|\(basePackId)"] {
                    outgoingBuf = prevBuf
                    outgoingFrame = primaryFrame
                    keyCrossfadeProgress = 0.0
                }
                currentMapKey = mapKey
                primaryFrame = 0
                crossfadeFrame = 0
            }

            let padChannelGain: Float = {
                if effMuted || effVol <= 0.01 { return 0.0 }
                if effVol >= 0.80 {
                    let db = ((effVol - 0.80) / 0.20) * 6.0
                    return pow(10.0, db / 20.0)
                }
                let norm = (effVol - 0.01) / 0.79
                let db = -60.0 * (1.0 - norm)
                return pow(10.0, db / 20.0)
            }()
            let busVol = padBusGain * padChannelGain
            let clampedPan = max(-1.0, min(1.0, effPan))
            let panL: Float = clampedPan <= 0 ? 1.0 : max(0.0, 1.0 - clampedPan)
            let panR: Float = clampedPan >= 0 ? 1.0 : max(0.0, 1.0 + clampedPan)

            for i in frame..<blockEnd {
                if padOn {
                    if fadeGain < 1.0 { fadeGain = min(1.0, fadeGain + fadeInStep) }
                } else {
                    if fadeGain > 0.0 { fadeGain = max(0.0, fadeGain - fadeOutStep) }
                }
                if fadeGain <= 0.0001 {
                    continue
                }

                var (sL, sR) = sampleLoopingPad(padBuf, primary: &primaryFrame, crossfade: &crossfadeFrame)
                if keyCrossfadeProgress < 1.0, let outBuf = outgoingBuf, let outCh = outBuf.floatChannelData, outBuf.frameLength > 0 {
                    let outLen = Int(outBuf.frameLength)
                    let idx = outgoingFrame % outLen
                    let oL = outCh[0][idx]
                    let oR = (outBuf.format.channelCount > 1 ? outCh[1] : outCh[0])[idx]
                    outgoingFrame += 1
                    let angle = keyCrossfadeProgress * (Float.pi * 0.5)
                    sL = oL * cos(angle) + sL * sin(angle)
                    sR = oR * cos(angle) + sR * sin(angle)
                    keyCrossfadeProgress = min(1.0, keyCrossfadeProgress + keyCrossfadeStep)
                    if keyCrossfadeProgress >= 1.0 {
                        outgoingBuf = nil
                    }
                }

                let g = fadeGain * busVol
                left[i] += sL * g * panL
                right[i] += sR * g * panR
            }

            frame = blockEnd
        }

        return lastActiveState
    }

    internal static func softLimitStereo(left: inout [Float], right: inout [Float]) {
        let softKnee: Float = 0.8912509 // -1.0 dBFS
        let softHeadroom: Float = 1.0 - softKnee

        func scrubAndLimitChannel(_ samples: inout [Float]) {
            guard !samples.isEmpty else { return }
            let n = samples.count
            var sumCheck: Float = 0
            var peakCheck: Float = 0
            vDSP_sve(samples, 1, &sumCheck, vDSP_Length(n))
            vDSP_maxmgv(samples, 1, &peakCheck, vDSP_Length(n))
            if sumCheck.isFinite && peakCheck.isFinite && peakCheck <= softKnee {
                return
            }
            for i in 0..<n {
                let x = samples[i]
                if !x.isFinite {
                    samples[i] = 0.0
                } else if x > softKnee {
                    samples[i] = min(1.0, softKnee + softHeadroom * tanhf((x - softKnee) / softHeadroom))
                } else if x < -softKnee {
                    samples[i] = max(-1.0, -(softKnee + softHeadroom * tanhf((-x - softKnee) / softHeadroom)))
                }
            }
        }

        scrubAndLimitChannel(&left)
        scrubAndLimitChannel(&right)
    }

    private static func writeAudioFile(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        format: BounceAudioFormat,
        to url: URL
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(left.count)) else {
            throw NSError(domain: "OfflineBounceEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer."])
        }
        pcmBuffer.frameLength = AVAudioFrameCount(left.count)

        if let dst = pcmBuffer.floatChannelData {
            left.withUnsafeBufferPointer { srcL in
                if let base = srcL.baseAddress {
                    dst[0].update(from: base, count: left.count)
                }
            }
            right.withUnsafeBufferPointer { srcR in
                if let base = srcR.baseAddress {
                    dst[1].update(from: base, count: right.count)
                }
            }
        }

        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000
            ]
        case .mp3:
            try encodeStereoFloatToMP3(left: left, right: right, sampleRate: sampleRate, to: url)
            return
        }

        let audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: pcmBuffer)
    }

    static func encodeStereoFloatToMP3(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        to mp3URL: URL
    ) throws {
        guard left.count == right.count, !left.isEmpty else {
            throw NSError(
                domain: "OfflineBounceEngine",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid audio buffer for MP3 export."]
            )
        }

        guard let gfp = lame_init() else {
            throw NSError(
                domain: "OfflineBounceEngine",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize LAME MP3 encoder."]
            )
        }
        defer { lame_close(gfp) }

        let targetSR = MasteringAudioResampler.targetMP3SampleRate(for: sampleRate)
        let encodeLeft: [Float]
        let encodeRight: [Float]
        if abs(targetSR - sampleRate) > 0.5 {
            guard let resampled = MasteringAudioResampler.resampleStereoFloat(
                left: left,
                right: right,
                fromRate: sampleRate,
                toRate: targetSR
            ) else {
                throw NSError(
                    domain: "OfflineBounceEngine",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to resample audio from \(Int(sampleRate)) Hz to \(Int(targetSR)) Hz for MP3 export."]
                )
            }
            encodeLeft = resampled.left
            encodeRight = resampled.right
        } else {
            encodeLeft = left
            encodeRight = right
        }

        let srInt = Int32(targetSR.rounded())
        lame_set_in_samplerate(gfp, srInt)
        lame_set_out_samplerate(gfp, srInt)
        lame_set_num_channels(gfp, 2)
        lame_set_mode(gfp, JOINT_STEREO)
        lame_set_brate(gfp, 256)
        lame_set_quality(gfp, 2)
        lame_set_bWriteVbrTag(gfp, 0)

        guard lame_init_params(gfp) >= 0 else {
            throw NSError(
                domain: "OfflineBounceEngine",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to configure LAME MP3 encoder parameters."]
            )
        }

        let totalSamples = encodeLeft.count
        let chunkSize = 16_384
        var leftChunk = [Float](repeating: 0, count: chunkSize)
        var rightChunk = [Float](repeating: 0, count: chunkSize)
        var mp3Chunk = [UInt8](repeating: 0, count: 32_768)
        var mp3Data = Data()
        mp3Data.reserveCapacity(max(8_192, totalSamples / 6))

        var offset = 0
        while offset < totalSamples {
            let count = min(chunkSize, totalSamples - offset)
            for i in 0..<count {
                let l = encodeLeft[offset + i]
                let r = encodeRight[offset + i]
                leftChunk[i] = l.isFinite ? max(-1.0, min(1.0, l)) : 0
                rightChunk[i] = r.isFinite ? max(-1.0, min(1.0, r)) : 0
            }

            let bytesWritten: Int32 = leftChunk.withUnsafeMutableBufferPointer { lPtr in
                rightChunk.withUnsafeMutableBufferPointer { rPtr in
                    mp3Chunk.withUnsafeMutableBufferPointer { outPtr in
                        lame_encode_buffer_ieee_float(
                            gfp,
                            lPtr.baseAddress,
                            rPtr.baseAddress,
                            Int32(count),
                            outPtr.baseAddress,
                            Int32(outPtr.count)
                        )
                    }
                }
            }

            if bytesWritten < 0 {
                throw NSError(
                    domain: "OfflineBounceEngine",
                    code: Int(bytesWritten),
                    userInfo: [NSLocalizedDescriptionKey: "LAME MP3 encoder failed with code \(bytesWritten)."]
                )
            }
            if bytesWritten > 0 {
                mp3Data.append(contentsOf: mp3Chunk[0..<Int(bytesWritten)])
            }
            offset += count
        }

        let flushedBytes: Int32 = mp3Chunk.withUnsafeMutableBufferPointer { outPtr in
            lame_encode_flush(gfp, outPtr.baseAddress, Int32(outPtr.count))
        }
        if flushedBytes < 0 {
            throw NSError(
                domain: "OfflineBounceEngine",
                code: Int(flushedBytes),
                userInfo: [NSLocalizedDescriptionKey: "LAME MP3 flush failed with code \(flushedBytes)."]
            )
        }
        if flushedBytes > 0 {
            mp3Data.append(contentsOf: mp3Chunk[0..<Int(flushedBytes)])
        }

        try mp3Data.write(to: mp3URL, options: .atomic)
    }

    private static func sanitizeFileComponent(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}
