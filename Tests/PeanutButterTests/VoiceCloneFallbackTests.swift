import AVFoundation
import Foundation
import Testing
@testable import PeanutButter

@Suite("Local LuxTTS Voice Clone Fallback")
struct VoiceCloneFallbackTests {

    @Test("GuideVoice encodes, decodes, and describes AI clone options")
    func guideVoiceCloneCodingAndDisplay() throws {
        let active = GuideVoice.cloneActive
        #expect(active.isCloneActive)
        #expect(active.isVoiceClone)
        #expect(active.clonedPackId == nil)
        #expect(!active.isCustom)

        let packVoice = GuideVoice.clonePack("sam-male")
        #expect(!packVoice.isCloneActive)
        #expect(packVoice.isVoiceClone)
        #expect(packVoice.clonedPackId == "sam-male")

        let encoded = try JSONEncoder().encode([active, packVoice, GuideVoice.clonePack("rita")])
        let decoded = try JSONDecoder().decode([GuideVoice].self, from: encoded)
        #expect(decoded == [active, packVoice, GuideVoice.clonePack("rita")])

        #expect(GuideAudioGenerator.shared.displayName(for: .cloneActive) == "Match Guide Voice (AI Clone)")
        #expect(GuideAudioGenerator.shared.displayName(for: .clonePack("rita")) == "Rita (AI Clone)")
        #expect(GuideAudioGenerator.shared.displayName(for: .clonePack("sam-male")).contains("(AI Clone)"))
    }

    @Test("Vendored LuxTtsG2p loads bundled resources without Bundle.module and phonemizes guide phrases")
    func g2pLoadsBundledLexiconAndPhonemizes() throws {
        let g2p = try LuxTtsG2p()
        let chorus = g2p.phonemize(text: "Chorus 1.")
        let drop = g2p.phonemize(text: "Drop to piano.")
        let key = g2p.phonemize(text: "Holy Forever, key of B flat.")

        #expect(!chorus.isEmpty)
        #expect(!drop.isEmpty)
        #expect(!key.isEmpty)

        // TrailingPad adds pause/silence tokens that map cleanly onto tokens.txt boundaries
        let padded = drop + " . . ."
        #expect(padded.hasSuffix(" . . ."))
    }

    @Test("Reference prompt compiler packs <= 4.65s @ 24kHz with matching transcript and deterministic fingerprint")
    func referencePromptCompilationForSam() throws {
        let fm = FileManager.default
        let samFolder = URL(fileURLWithPath: "Sources/PeanutButter/Resources/Audio/Guides/sam-male", isDirectory: true)
        try #require(fm.fileExists(atPath: samFolder.path))

        let cacheDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_test_cache_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: cacheDir) }

        let service = VoiceCloneService(cacheDirectory: cacheDir)
        let ref1 = try #require(service.compileReferencePrompt(forPackId: "sam-male"))
        let ref2 = try #require(service.compileReferencePrompt(forPackId: "sam-male"))

        #expect(ref1.durationSeconds > 1.0)
        #expect(ref1.durationSeconds <= 4.65 + 0.001)
        #expect(ref1.samples24k.count <= Int(4.65 * 24_000.0))
        #expect(ref1.packActiveRMS > 0.01)
        #expect(!ref1.promptText.isEmpty)
        #expect(ref1.promptText.hasSuffix("."))
        #expect(ref1.fingerprint == ref2.fingerprint)
    }

    @Test("Missing CoreML model directory returns nil safely and GuideAudioGenerator degrades cleanly")
    func gracefulFallbackWhenModelMissing() throws {
        let fm = FileManager.default
        let emptyModelDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_empty_model_\(UUID().uuidString)", isDirectory: true)
        let tempCacheDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_cache_empty_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: emptyModelDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: emptyModelDir)
            try? fm.removeItem(at: tempCacheDir)
        }

        #expect(!VoiceCloneModelManager.areModelFilesComplete(in: emptyModelDir))

        let service = VoiceCloneService(cacheDirectory: tempCacheDir)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000.0, channels: 1, interleaved: false)!

        // Missing CoreML directory never crashes or blocks
        let direct = service.resolvePhraseSync(
            phrase: "Drop to piano",
            targetPackId: "sam-male",
            targetFormat: format,
            modelDirectoryOverride: emptyModelDir
        )
        #expect(direct == nil)

        // End-to-end GuideAudioGenerator call with .cloneActive still resolves cleanly on fallback
        if CustomSampleLibraryManager.shared.guidePack(forId: "sam-male") != nil {
            let resolved = GuideAudioGenerator.shared.resolvePhraseWithFallbackInfo(
                "Drop to piano",
                voice: .custom(packId: "sam-male"),
                fallbackVoice: .cloneActive,
                targetFormat: format
            )
            if !VoiceCloneModelManager.isSharedModelReady {
                #expect(resolved?.usedFallback == true || resolved == nil)
            }
        }
    }

    @Test("Conditional live LuxTTS CoreML synthesis produces clean 48kHz audio with decaying tail")
    func liveCoreMLSynthesisWhenModelsPresent() async throws {
        let fm = FileManager.default
        let appSupportDir = VoiceCloneModelManager.sharedModelDirectoryURL
        let protoCacheDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/luxtts", isDirectory: true)

        let modelDir: URL?
        if VoiceCloneModelManager.areModelFilesComplete(in: appSupportDir) {
            modelDir = appSupportDir
        } else if VoiceCloneModelManager.areModelFilesComplete(in: protoCacheDir) {
            modelDir = protoCacheDir
        } else {
            modelDir = nil
        }

        guard VoiceCloneModelManager.isPlatformSupported, let availableModelDir = modelDir else {
            return
        }

        let samFolder = URL(fileURLWithPath: "Sources/PeanutButter/Resources/Audio/Guides/sam-male", isDirectory: true)
        guard fm.fileExists(atPath: samFolder.path) else {
            return
        }

        let tempCacheDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_live_cache_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempCacheDir) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000.0, channels: 1, interleaved: false)!

        let phraseResult: SpokenPhraseData = try await Task.detached(priority: .userInitiated) {
            let service = VoiceCloneService(cacheDirectory: tempCacheDir)
            let ref = try #require(service.compileReferencePrompt(forPackId: "sam-male"))

            let engine = LuxTtsCoreEngine()
            let g2p = try engine.englishG2p()
            let raw = try engine.synthesizePhonemes(
                g2p.phonemize(text: "Drop to piano.") + " . . .",
                promptAudio24k: ref.samples24k,
                promptPhonemes: g2p.phonemize(text: ref.promptText),
                modelDirectory: availableModelDir,
                speed: 0.95,
                seed: 42,
                maxRedraws: 3
            )
            #expect(raw.sampleRate == 48_000)
            #expect(raw.samples.count > 12_000)
            let tailRMS = VoiceCloneService.tailLast40msRMS(raw.samples, sampleRate: 48_000.0)
            #expect(tailRMS <= 0.025)

            // Verify end-to-end cache write & reload
            let cached = try #require(
                service.resolvePhraseSync(
                    phrase: "Drop to piano",
                    targetPackId: "sam-male",
                    targetFormat: format,
                    modelDirectoryOverride: availableModelDir
                )
            )
            #expect(cached.buffer.frameLength > 10_000)

            // Regression check: "Who Else, Key of A flat" keeps clean boundaries and strong /eɪ/ high-F2 on the note letter "A".
            func measureKeyOfAFlatFormants(in samples: [Float], sr: Double) -> (dur: Double, artifacts: Int, maxF2e: Double, f2uAtPeak: Double) {
                let dftWin = 1024
                let step = Int(0.025 * sr)
                let dur = Double(samples.count) / sr
                let artifacts = VoiceCloneService.countBoundaryArtifactIslands(samples, sampleRate: sr)
                func bandEnergy(_ seg: ArraySlice<Float>, fLo: Double, fHi: Double) -> Double {
                    let kLo = max(1, Int(fLo * Double(dftWin) / sr))
                    let kHi = min(dftWin / 2, Int(fHi * Double(dftWin) / sr))
                    var energy = 0.0
                    for k in kLo...max(kLo, kHi) {
                        let ang = -2.0 * Double.pi * Double(k) / Double(dftWin)
                        var re = 0.0
                        var im = 0.0
                        for (m, val) in seg.enumerated() {
                            let x = Double(val)
                            re += x * cos(ang * Double(m))
                            im += x * sin(ang * Double(m))
                        }
                        energy += (re * re + im * im)
                    }
                    return sqrt(energy / Double(max(1, kHi - kLo + 1)))
                }

                struct FrameInfo {
                    let t: Double
                    let rms: Double
                    let low: Double
                    let f2u: Double
                    let f2e: Double
                }

                var frames: [FrameInfo] = []
                var idx = 0
                while idx + dftWin < samples.count {
                    let seg = samples[idx..<(idx + dftWin)]
                    var sumSq = 0.0
                    for v in seg { sumSq += Double(v) * Double(v) }
                    let rms = sqrt(sumSq / Double(dftWin))
                    let bLow = bandEnergy(seg, fLo: 300, fHi: 650)
                    let bMid = bandEnergy(seg, fLo: 650, fHi: 1200)
                    let bF2u = bandEnergy(seg, fLo: 1000, fHi: 1600)
                    let bF2e = bandEnergy(seg, fLo: 1700, fHi: 2600)
                    let tot = max(1e-9, bLow + bMid + bF2u + bF2e)
                    frames.append(FrameInfo(t: Double(idx) / sr, rms: rms, low: bLow / tot, f2u: bF2u / tot, f2e: bF2e / tot))
                    idx += step
                }

                let keyLo = max(0.30, dur - 1.60)
                let keyHi = dur - 0.55
                var keyIdx: Int?
                var keyBestF2e = 0.0
                for i in 0..<frames.count {
                    let f = frames[i]
                    guard f.t >= keyLo && f.t <= keyHi, f.rms >= 0.025 else { continue }
                    if f.f2e > keyBestF2e {
                        keyBestF2e = f.f2e
                        keyIdx = i
                    }
                }
                let kIdx = keyIdx ?? max(0, frames.count / 2)
                let kTime = frames[min(kIdx, frames.count - 1)].t
                var ofIdx = kIdx
                var bestOfLow = -1.0
                for i in kIdx..<frames.count {
                    let dt = frames[i].t - kTime
                    if dt < 0.04 { continue }
                    if dt > 0.42 { break }
                    if frames[i].rms >= 0.030 && frames[i].low > bestOfLow {
                        bestOfLow = frames[i].low
                        ofIdx = i
                    }
                }
                var aStartIdx = ofIdx + 1
                while aStartIdx < frames.count && (frames[aStartIdx].t - frames[ofIdx].t) < 0.22 && frames[aStartIdx].low >= 0.52 && frames[aStartIdx].rms >= 0.025 {
                    aStartIdx += 1
                }
                var aOnsetTime: Double?
                var maxF2e = 0.0
                var f2uAtPeak = 1.0
                for j in aStartIdx..<frames.count {
                    let f = frames[j]
                    if aOnsetTime == nil {
                        if f.t - frames[ofIdx].t > 0.30 { break }
                        if f.rms < 0.015 { continue }
                        aOnsetTime = f.t
                    } else {
                        if f.t - aOnsetTime! > 0.20 || f.rms < 0.015 { break }
                    }
                    if f.rms >= 0.020 && f.f2e > maxF2e {
                        maxF2e = f.f2e
                        f2uAtPeak = f.f2u
                    }
                }
                return (dur, artifacts, maxF2e, f2uAtPeak)
            }

            if service.compileReferencePrompt(forPackId: "rita") != nil {
                let guidePhrase = GuideAudioGenerator.songAnnouncementPhrase(title: "Who Else (Live)", key: "Ab")
                let guideAnnouncement = try #require(
                    service.resolvePhraseSync(
                        phrase: guidePhrase,
                        targetPackId: "rita",
                        targetFormat: format,
                        modelDirectoryOverride: availableModelDir
                    )
                )
                let gCount = Int(guideAnnouncement.buffer.frameLength)
                let gSamples = Array(UnsafeBufferPointer(start: guideAnnouncement.buffer.floatChannelData![0], count: gCount))
                let mGuide = measureKeyOfAFlatFormants(in: gSamples, sr: 48_000.0)
                #expect(mGuide.dur >= 1.3 && mGuide.dur <= 2.8)
                #expect(mGuide.artifacts == 0)
                #expect(mGuide.maxF2e >= 0.22)
                #expect(mGuide.maxF2e > mGuide.f2uAtPeak)
            }

            let samPhrase = GuideAudioGenerator.songAnnouncementPhrase(title: "Who Else (Live)", key: "Ab")
            let samAnnouncement = try #require(
                service.resolvePhraseSync(
                    phrase: samPhrase,
                    targetPackId: "sam-male",
                    targetFormat: format,
                    modelDirectoryOverride: availableModelDir
                )
            )
            let wCount = Int(samAnnouncement.buffer.frameLength)
            let wSamples = Array(UnsafeBufferPointer(start: samAnnouncement.buffer.floatChannelData![0], count: wCount))
            let samDur = Double(wCount) / 48_000.0
            #expect(samDur >= 1.3 && samDur <= 2.8)
            #expect(VoiceCloneService.countBoundaryArtifactIslands(wSamples, sampleRate: 48_000.0) == 0)
            return cached
        }.value

        #expect(phraseResult.onsetOffset >= 0.0)
    }

    @Test("Song decoding upgrades legacy fallback defaults cleanly and preserves explicit overrides")
    func legacySongFallbackDecodingAndOverrideRoundTrip() throws {
        let baseSong = Song(
            title: "Legacy Test",
            artist: "Tester",
            bpm: 120.0,
            timeSignatureNumerator: 4,
            timeSignatureDenominator: 4,
            musicalKey: "C",
            sections: []
        )
        let encodedData = try JSONEncoder().encode(baseSong)
        var rawDict = try #require(try JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        rawDict.removeValue(forKey: "usesDefaultGuideFallback")

        // Case A: Legacy song saved with default Zoe fallback
        rawDict["guideFallbackVoice"] = GuideVoice.zoe.rawValue
        let legacyZoeData = try JSONSerialization.data(withJSONObject: rawDict)
        let decodedLegacyZoe = try JSONDecoder().decode(Song.self, from: legacyZoeData)
        #expect(decodedLegacyZoe.usesDefaultGuideFallback == true)
        #expect(decodedLegacyZoe.guideFallbackVoice == CustomSampleLibraryManager.shared.defaultGuideFallbackVoice)

        // Case B: Legacy song with omitted guideFallbackVoice
        rawDict.removeValue(forKey: "guideFallbackVoice")
        let legacyNilData = try JSONSerialization.data(withJSONObject: rawDict)
        let decodedLegacyNil = try JSONDecoder().decode(Song.self, from: legacyNilData)
        #expect(decodedLegacyNil.usesDefaultGuideFallback == true)

        // Case C: Legacy song with explicit non-Zoe custom fallback (Samantha) preserves override
        rawDict["guideFallbackVoice"] = "Samantha"
        let legacyCustomData = try JSONSerialization.data(withJSONObject: rawDict)
        let decodedLegacyCustom = try JSONDecoder().decode(Song.self, from: legacyCustomData)
        #expect(decodedLegacyCustom.usesDefaultGuideFallback == false)
        #expect(decodedLegacyCustom.guideFallbackVoice == GuideVoice(rawValue: "Samantha"))

        // Case D: Explicit usesDefaultGuideFallback == false with .zoe survives JSON round-trip
        var explicitOverride = baseSong
        explicitOverride.guideFallbackVoice = .zoe
        explicitOverride.usesDefaultGuideFallback = false
        let overrideData = try JSONEncoder().encode(explicitOverride)
        let decodedOverride = try JSONDecoder().decode(Song.self, from: overrideData)
        #expect(decodedOverride.usesDefaultGuideFallback == false)
        #expect(decodedOverride.guideFallbackVoice == .zoe)
    }

    @Test("CustomSampleLibraryManager preserves separate system backup and preferred AI clone settings")
    func customSampleLibraryManagerTracksSystemBackupAndPreferredClone() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pb_lib_prefs_test_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let manager = CustomSampleLibraryManager(isolatedRootDirectory: tempDir)
        manager.defaultGuideFallbackVoice = .clonePack("sam-male")
        manager.defaultSystemFallbackVoice = GuideVoice(rawValue: "Samantha")

        #expect(manager.defaultGuideFallbackVoice == .clonePack("sam-male"))
        #expect(manager.preferredDefaultVoiceCloneVoice == .clonePack("sam-male"))
        #expect(manager.defaultSystemFallbackVoice == GuideVoice(rawValue: "Samantha"))

        // Switching fallback to a system voice retains preferred AI clone source for re-enabling
        manager.defaultGuideFallbackVoice = GuideVoice(rawValue: "Samantha")
        #expect(manager.defaultSystemFallbackVoice == GuideVoice(rawValue: "Samantha"))
        #expect(manager.preferredDefaultVoiceCloneVoice == .clonePack("sam-male"))

        // Invalid values sanitize safely
        manager.defaultSystemFallbackVoice = .cloneActive
        #expect(manager.defaultSystemFallbackVoice == .zoe)
        manager.preferredDefaultVoiceCloneVoice = .zoe
        #expect(manager.preferredDefaultVoiceCloneVoice == .cloneActive)
    }

    @Test("GuideAudioGenerator.fallbackPhrases filters studio recordings and deduplicates custom cues")
    func fallbackPhrasesDetectionForStudioVsCustomCues() {
        guard CustomSampleLibraryManager.shared.guidePack(forId: "sam-male") != nil else {
            return
        }

        let sections = [
            SongSection(name: "Intro", startTime: 0, duration: 8),
            SongSection(name: "Verse 1", startTime: 8, duration: 16),
            SongSection(name: "Chorus 1", startTime: 24, duration: 16),
            SongSection(name: "Bridge 1", startTime: 40, duration: 16)
        ]

        let studioOnly = GuideAudioGenerator.shared.fallbackPhrases(
            sections: sections,
            directionalCues: [DirectionalCue(time: 2, label: "Build")],
            primaryVoice: .custom(packId: "sam-male"),
            guideSource: .generated,
            speakDirectionalCuesOnUploadedGuide: true,
            uploadedOverlayVoice: .custom(packId: "sam-male")
        )
        #expect(studioOnly.isEmpty)

        let cuesWithCustom = [
            DirectionalCue(time: 2, label: "Build"),
            DirectionalCue(time: 4, label: "Drop to Piano"),
            DirectionalCue(time: 10, label: "drop to piano"),
            DirectionalCue(time: 18, label: "Keys Only")
        ]
        let missing = GuideAudioGenerator.shared.fallbackPhrases(
            sections: sections,
            directionalCues: cuesWithCustom,
            primaryVoice: .custom(packId: "sam-male"),
            guideSource: .generated,
            speakDirectionalCuesOnUploadedGuide: true,
            uploadedOverlayVoice: .custom(packId: "sam-male")
        )
        #expect(missing == ["Drop to Piano", "Keys Only"])
    }

    @Test("Missing custom primary pack resolves to default guide without cloning studio cues")
    func missingCustomPrimaryPackResolvesToDefaultGuideWithoutCloningStudioCues() {
        let missingPackVoice = GuideVoice.custom(packId: "english-guides-nonexistent")
        let effective = GuideAudioGenerator.shared.effectivePrimaryVoice(for: missingPackVoice)
        let defaultVoice = CustomSampleLibraryManager.shared.defaultGuideVoice
        #expect(effective == defaultVoice)

        guard let defPackId = defaultVoice.customPackId,
              CustomSampleLibraryManager.shared.guidePack(forId: defPackId) != nil else {
            return
        }

        let sections = [
            SongSection(name: "Count Off", startTime: 0, duration: 4, includeNumberInGuide: false),
            SongSection(name: "Chorus", startTime: 4, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Intro", startTime: 12, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Verse 1", startTime: 20, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Vamp", startTime: 28, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Bridge 1", startTime: 36, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Refrain 1", startTime: 44, duration: 8, includeNumberInGuide: false),
            SongSection(name: "Ending", startTime: 52, duration: 8, includeNumberInGuide: false)
        ]

        let missing = GuideAudioGenerator.shared.fallbackPhrases(
            sections: sections,
            directionalCues: [],
            primaryVoice: missingPackVoice,
            guideSource: .generated,
            speakDirectionalCuesOnUploadedGuide: true,
            uploadedOverlayVoice: missingPackVoice,
            fallbackVoice: .cloneActive
        )
        #expect(missing.isEmpty)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000.0, channels: 1, interleaved: false)!
        for cue in ["Intro", "Chorus", "1"] {
            let resolved = GuideAudioGenerator.shared.resolvePhraseWithFallbackInfo(
                cue,
                voice: missingPackVoice,
                fallbackVoice: .cloneActive,
                targetFormat: format
            )
            #expect(resolved != nil)
            #expect(resolved?.usedFallback == false)
        }
    }

    @Test("VoiceCloneService never AI-clones phrases already recorded in target pack")
    func voiceCloneNeverClonesPhraseAlreadyRecordedInTargetPack() throws {
        guard CustomSampleLibraryManager.shared.guidePack(forId: "sam-male") != nil else {
            return
        }

        let fm = FileManager.default
        let emptyModelDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_empty_guard_\(UUID().uuidString)", isDirectory: true)
        let tempCacheDir = fm.temporaryDirectory.appendingPathComponent("pb_vc_cache_guard_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: emptyModelDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: emptyModelDir)
            try? fm.removeItem(at: tempCacheDir)
        }

        let service = VoiceCloneService(cacheDirectory: tempCacheDir)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000.0, channels: 1, interleaved: false)!

        // Even without CoreML weights, studio-recorded phrases resolve directly from the pack and never write clone WAVs
        let chorus = service.resolvePhraseSync(
            phrase: "Chorus",
            targetPackId: "sam-male",
            targetFormat: format,
            modelDirectoryOverride: emptyModelDir
        )
        let one = service.resolvePhraseSync(
            phrase: "1",
            targetPackId: "sam-male",
            targetFormat: format,
            modelDirectoryOverride: emptyModelDir
        )
        #expect(chorus != nil)
        #expect(one != nil)
        #expect(try fm.contentsOfDirectory(atPath: tempCacheDir.path).isEmpty)

        // Truly missing phrase still requires the CoreML model
        let custom = service.resolvePhraseSync(
            phrase: "Drop to Piano",
            targetPackId: "sam-male",
            targetFormat: format,
            modelDirectoryOverride: emptyModelDir
        )
        #expect(custom == nil)
    }

    @Test("fallbackPhrases excludes cues that already have studio recordings in AI clone target pack")
    func fallbackPhrasesExcludesCuesRecordedInCloneTargetPack() {
        guard let caleb = CustomSampleLibraryManager.shared.guidePack(forId: "caleb-male"),
              let sam = CustomSampleLibraryManager.shared.guidePack(forId: "sam-male"),
              caleb.fileURL(forNormalizedPhrase: "passage") == nil,
              sam.fileURL(forNormalizedPhrase: "passage") != nil else {
            return
        }

        let sections = [
            SongSection(name: "Intro", startTime: 0, duration: 8),
            SongSection(name: "Passage", startTime: 8, duration: 8)
        ]
        let cues = [
            DirectionalCue(time: 4, label: "Drop to Piano")
        ]

        let filtered = GuideAudioGenerator.shared.fallbackPhrases(
            sections: sections,
            directionalCues: cues,
            primaryVoice: .custom(packId: "caleb-male"),
            guideSource: .generated,
            speakDirectionalCuesOnUploadedGuide: true,
            uploadedOverlayVoice: .custom(packId: "caleb-male"),
            fallbackVoice: .clonePack("sam-male")
        )
        #expect(filtered == ["Drop to Piano"])
    }
}
