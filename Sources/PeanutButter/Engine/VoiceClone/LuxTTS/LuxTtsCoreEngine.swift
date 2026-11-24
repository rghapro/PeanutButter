import Accelerate
import AVFoundation
@preconcurrency import CoreML
import Foundation
import os

/// One LuxTTS synthesis run: 48 kHz mono samples plus frame accounting.
public struct LuxTtsSynthesisResult: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let promptFrames: Int
    public let generatedFrames: Int
    public let featuresLength: Int
    public let redraws: Int
    public let residualPauses: Int
}

/// Self-contained synchronous CoreML LuxTTS synthesis engine (GPU + CPU placement).
///
/// Always configures `MLComputeUnits.cpuAndGPU` for `gpu/` graphs and `vocoder/` models
/// because running the `gpu/` graph on the ANE corrupts attention output.
public final class LuxTtsCoreEngine: @unchecked Sendable {

    private let logger = Logger(subsystem: PeanutButterLog.subsystem, category: "LuxTtsCoreEngine")
    private let lock = NSLock()
    private let synthQueue = DispatchQueue(label: "com.peanutbutter.luxtts.synth", qos: .userInitiated)

    private var loadedModelDirectory: URL?
    private var textEncoderModel: MLModel?
    private var fmDecoderModel: MLModel?
    private var vocoderModels: [Int: MLModel] = [:]
    private var tokenizer: LuxTtsTokenizer?
    private var g2p: LuxTtsG2p?

    public init() {}

    /// Lazily loads and caches the offline espeak-parity English G2P tables (~1 MB bundled).
    public func englishG2p() throws -> LuxTtsG2p {
        lock.lock()
        if let cached = g2p {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = try LuxTtsG2p()
        lock.lock()
        if g2p == nil {
            g2p = loaded
        }
        let result = g2p ?? loaded
        lock.unlock()
        return result
    }

    /// Unloads CoreML models and cached G2P tables from memory.
    public func unloadModels() {
        synthQueue.sync {
            lock.lock()
            textEncoderModel = nil
            fmDecoderModel = nil
            vocoderModels.removeAll()
            tokenizer = nil
            loadedModelDirectory = nil
            g2p = nil
            lock.unlock()
        }
    }

    /// Preloads `TextEncoder`, `FmDecoder`, and `tokens.txt` from `modelDirectory`.
    public func prepareModels(in modelDirectory: URL) throws {
        try synthQueue.sync {
            _ = try ensureCoreModelsLoadedLocked(in: modelDirectory)
        }
    }

    /// Synthesizes pre-phonemized espeak IPA strings synchronously using LuxTTS continuation
    /// chunking and built-in spurious-pause redraws.
    public func synthesizePhonemes(
        _ phonemes: String,
        promptAudio24k: [Float],
        promptPhonemes: String,
        modelDirectory: URL,
        speed: Float = LuxTtsConstants.defaultSpeed,
        seed: UInt64 = LuxTtsConstants.defaultSeed,
        maxRedraws: Int = LuxTtsConstants.spuriousPauseRetries,
        extraPauseAllowance: Int = 0
    ) throws -> LuxTtsSynthesisResult {
        return try synthQueue.sync {
            let models = try ensureCoreModelsLoadedLocked(in: modelDirectory)
            let tok = models.tokenizer
            let textIds = tok.tokenIds(phonemes: phonemes)
            let promptIds = tok.tokenIds(phonemes: promptPhonemes)
            let count = max(0, extraPauseAllowance)
            let extraPositions = (0..<count).map { (Double($0) + 0.5) / Double(count) }

            return try synthesizeTokens(
                tokenIds: textIds,
                promptAudio24k: promptAudio24k,
                promptTokenIds: promptIds,
                modelDirectory: modelDirectory,
                tokenizer: tok,
                speed: speed,
                seed: seed,
                maxRedraws: maxRedraws,
                extraPausePositions: extraPositions
            )
        }
    }

    /// Synthesizes raw token IDs across one or more continuation spans with spurious-pause redraws.
    private func synthesizeTokens(
        tokenIds: [Int],
        promptAudio24k: [Float],
        promptTokenIds: [Int],
        modelDirectory: URL,
        tokenizer: LuxTtsTokenizer,
        speed: Float,
        seed: UInt64,
        maxRedraws: Int,
        extraPausePositions: [Double]
    ) throws -> LuxTtsSynthesisResult {
        let pauseTokens = Set([",", ".", ";", ":", "!", "?", "-"].compactMap { tokenizer.tokenToId[$0] })
        let boundaryTokens = pauseTokens.union([tokenizer.tokenToId[" "]].compactMap { $0 })
        let promptFrames = LuxTtsMelExtractor().frameCount(
            sampleCount: min(promptAudio24k.count, LuxTtsConstants.maxPromptSamples)
        )

        let spans: [[Int]]
        if LuxTtsContinuation.fitsSinglePass(
            textTokenCount: tokenIds.count,
            promptFrames: promptFrames,
            promptTokenCount: promptTokenIds.count,
            speed: Double(speed))
        {
            spans = [tokenIds]
        } else {
            let maxSpanTokens = LuxTtsContinuation.maxSpanTokens(
                promptFrames: promptFrames,
                promptTokenCount: promptTokenIds.count,
                speed: Double(speed))
            let ratio = Double(promptFrames) / Double(max(1, promptTokenIds.count))
            guard ratio <= LuxTtsConstants.maxPromptFramesPerToken,
                  maxSpanTokens >= LuxTtsConstants.minimumSpanTokens
            else {
                throw LuxTtsError.inputTooLong(
                    "prompt yields \(String(format: "%.1f", ratio)) mel frames per token at speed \(speed), "
                        + "leaving spans of \(maxSpanTokens) tokens"
                )
            }
            spans = LuxTtsContinuation.chunks(
                tokenIds: tokenIds,
                maxTokens: maxSpanTokens,
                boundaryTokenIds: boundaryTokens)
        }

        let crossfadeSamples = Int(
            LuxTtsConstants.continuationCrossfadeSeconds * Double(LuxTtsConstants.outputSampleRate)
        )
        var currentPromptAudio = promptAudio24k
        var currentPromptTokens = promptTokenIds
        var samples: [Float] = []
        var originalPromptFrames = 0
        var totalGeneratedFrames = 0
        var totalRedraws = 0
        var totalResidualPauses = 0
        let spanExtraPauses = LuxTtsContinuation.spanPauseAllowances(
            spanLengths: spans.map(\.count),
            positions: extraPausePositions
        )

        for (index, span) in spans.enumerated() {
            let pass = try synthesizeSpanWithRedraws(
                textTokenIds: span,
                promptTokenIds: currentPromptTokens,
                promptAudio24k: currentPromptAudio,
                modelDirectory: modelDirectory,
                speed: index == 0 ? speed : 1.0,
                seed: seed &+ UInt64(index) &* LuxTtsConstants.continuationSeedStride,
                maxRedraws: maxRedraws,
                allowedPauses: spanExtraPauses[index]
                    + LuxTtsContinuation.expectedPauseCount(
                        in: span,
                        pauseTokenIds: pauseTokens,
                        boundaryTokenIds: boundaryTokens)
            )
            totalRedraws += pass.redraws
            totalResidualPauses += pass.residualPauses
            let result = pass.result

            if spans.count == 1 {
                return LuxTtsSynthesisResult(
                    samples: result.samples,
                    sampleRate: result.sampleRate,
                    promptFrames: result.promptFrames,
                    generatedFrames: result.generatedFrames,
                    featuresLength: result.featuresLength,
                    redraws: totalRedraws,
                    residualPauses: totalResidualPauses
                )
            }

            if index == 0 { originalPromptFrames = result.promptFrames }
            totalGeneratedFrames += result.generatedFrames

            let hasNextSpan = index + 1 < spans.count
            let keepTail = !hasNextSpan
                || LuxTtsContinuation.endsWithPausePunctuation(
                    span,
                    pauseTokenIds: pauseTokens,
                    boundaryTokenIds: boundaryTokens)
            let slice = LuxTtsContinuation.speechSlice(
                pass.speech,
                sampleCount: result.samples.count,
                sampleRate: result.sampleRate,
                trimLeading: index > 0,
                trimTrailing: !keepTail)
            LuxTtsContinuation.appendWithCrossfade(
                result.samples[slice],
                to: &samples,
                crossfadeSamples: crossfadeSamples)

            guard hasNextSpan else { continue }
            currentPromptAudio = try resampleTo24k(samples: result.samples, fromRate: Double(result.sampleRate))
            LuxTtsContinuation.fitPromptLength(&currentPromptAudio, frames: result.generatedFrames)
            currentPromptTokens = span
        }

        return LuxTtsSynthesisResult(
            samples: samples,
            sampleRate: LuxTtsConstants.outputSampleRate,
            promptFrames: originalPromptFrames,
            generatedFrames: totalGeneratedFrames,
            featuresLength: originalPromptFrames + totalGeneratedFrames,
            redraws: totalRedraws,
            residualPauses: totalResidualPauses
        )
    }

    private struct SpanPass {
        let result: LuxTtsSynthesisResult
        let speech: LuxTtsContinuation.SpeechRuns
        let redraws: Int
        let residualPauses: Int
    }

    private func synthesizeSpanWithRedraws(
        textTokenIds: [Int],
        promptTokenIds: [Int],
        promptAudio24k: [Float],
        modelDirectory: URL,
        speed: Float,
        seed: UInt64,
        maxRedraws: Int,
        allowedPauses: Int
    ) throws -> SpanPass {
        func render(_ attempt: Int) throws -> SpanPass {
            let result = try synthesizeSinglePass(
                promptTokenIds: promptTokenIds,
                textTokenIds: textTokenIds,
                promptAudio24k: promptAudio24k,
                modelDirectory: modelDirectory,
                speed: speed,
                seed: seed &+ UInt64(attempt)
            )
            let speech = LuxTtsContinuation.speechRuns(result.samples, sampleRate: result.sampleRate)
            let pauses = LuxTtsContinuation.innerPauseCount(speech, sampleRate: result.sampleRate)
            return SpanPass(
                result: result,
                speech: speech,
                redraws: attempt,
                residualPauses: max(0, pauses - allowedPauses)
            )
        }

        var best = try render(0)
        guard best.residualPauses > 0, maxRedraws > 0 else { return best }

        var redraws = 0
        for attempt in 1...maxRedraws {
            let candidate = try render(attempt)
            redraws = attempt
            if candidate.residualPauses < best.residualPauses {
                best = candidate
            }
            if candidate.residualPauses == 0 { break }
        }
        return SpanPass(
            result: best.result,
            speech: best.speech,
            redraws: redraws,
            residualPauses: best.residualPauses
        )
    }

    /// Runs one single-pass CoreML TextEncoder -> FmDecoder (x4 steps) -> Vocoder pass.
    public func synthesizeSinglePass(
        promptTokenIds: [Int],
        textTokenIds: [Int],
        promptAudio24k: [Float],
        modelDirectory: URL,
        speed: Float,
        seed: UInt64
    ) throws -> LuxTtsSynthesisResult {
        guard !promptTokenIds.isEmpty else {
            throw LuxTtsError.tokenizerFailed("prompt produced no tokens")
        }
        guard !textTokenIds.isEmpty else {
            throw LuxTtsError.tokenizerFailed("text produced no tokens")
        }
        guard !promptAudio24k.isEmpty else {
            throw LuxTtsError.invalidPromptAudio("no samples")
        }
        guard speed > 0 else {
            throw LuxTtsError.invalidPromptAudio("speed must be > 0 (got \(speed))")
        }

        let core = try ensureCoreModelsLoadedLocked(in: modelDirectory)
        let featDim = LuxTtsConstants.featDim
        let maxTokens = LuxTtsConstants.maxTokens
        let maxFrames = LuxTtsConstants.maxFrames

        let maxPromptSamples = Int(LuxTtsConstants.maxPromptSeconds * Double(LuxTtsConstants.melSampleRate))
        var prompt = Array(promptAudio24k.prefix(maxPromptSamples))

        var meanSquare: Float = 0
        vDSP_measqv(prompt, 1, &meanSquare, vDSP_Length(prompt.count))
        let promptRms = sqrt(meanSquare)
        guard promptRms > 0 else {
            throw LuxTtsError.invalidPromptAudio("prompt audio is silent")
        }
        if promptRms < LuxTtsConstants.targetRms {
            var gain = LuxTtsConstants.targetRms / promptRms
            vDSP_vsmul(prompt, 1, &gain, &prompt, 1, vDSP_Length(prompt.count))
        }

        let extractor = LuxTtsMelExtractor()
        let promptMel = extractor.extract(audio: prompt)
        let promptFrames = promptMel.count
        guard promptFrames > 0 else {
            throw LuxTtsError.invalidPromptAudio("prompt too short for one mel frame")
        }

        let cat = promptTokenIds + textTokenIds
        let tokenCount = cat.count
        guard tokenCount + 1 <= maxTokens else {
            throw LuxTtsError.inputTooLong("prompt + text tokens \(tokenCount) + pad slot > \(maxTokens)")
        }

        let featuresLength = LuxTtsSolver.featuresLength(
            promptFrames: promptFrames,
            promptTokenCount: promptTokenIds.count,
            textTokenCount: textTokenIds.count,
            speed: Double(speed))
        guard featuresLength <= maxFrames else {
            throw LuxTtsError.inputTooLong("features length \(featuresLength) > \(maxFrames) frames")
        }
        let genFrames = featuresLength - promptFrames
        guard genFrames >= 2 else {
            throw LuxTtsError.tokenizerFailed("estimated only \(genFrames) generated frames")
        }
        guard let bucket = LuxTtsConstants.vocoderBuckets.first(where: { $0 >= genFrames }) else {
            throw LuxTtsError.inputTooLong("generated frames \(genFrames) exceed vocoder buckets")
        }

        // Stage 1: TextEncoder
        let tokens = try makeZeroedArray(shape: [1, maxTokens], dataType: .int32)
        let tokenMask = try makeZeroedArray(shape: [1, maxTokens], dataType: .float32)
        tokens.withUnsafeMutableBufferPointer(ofType: Int32.self) { buf, _ in
            for i in 0..<tokenCount { buf[i] = Int32(cat[i]) }
        }
        tokenMask.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
            for i in tokenCount..<maxTokens { buf[i] = 1.0 }
        }

        let encoderOut = try predict(
            stage: "TextEncoder",
            model: core.textEncoder,
            inputs: [
                "tokens": MLFeatureValue(multiArray: tokens),
                "padding_mask": MLFeatureValue(multiArray: tokenMask)
            ]
        )
        guard let embedsArray = encoderOut.featureValue(for: "token_embeds")?.multiArrayValue else {
            throw LuxTtsError.inferenceFailed(stage: "TextEncoder", underlying: "no token_embeds")
        }
        let embeds = try copyRows(
            from: embedsArray,
            rowCount: tokenCount + 1,
            rowLength: featDim,
            stage: "TextEncoder"
        )

        // Stage 2: Alignment & conditioning tensors
        let textCondition = try makeZeroedArray(shape: [1, maxFrames, featDim], dataType: .float32)
        let speechCondition = try makeZeroedArray(shape: [1, maxFrames, featDim], dataType: .float32)
        let frameMask = try makeZeroedArray(shape: [1, maxFrames], dataType: .float32)

        let tokensIndex = try LuxTtsSolver.tokensIndex(tokensCount: tokenCount, featuresLength: featuresLength)
        textCondition.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for frame in 0..<featuresLength {
                let src = tokensIndex[frame] * featDim
                let dst = frame * featDim
                for d in 0..<featDim { out[dst + d] = embeds[src + d] }
            }
        }
        speechCondition.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for frame in 0..<promptFrames {
                let dst = frame * featDim
                for d in 0..<featDim {
                    out[dst + d] = promptMel[frame][d] * LuxTtsConstants.featScale
                }
            }
        }
        frameMask.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
            for i in featuresLength..<maxFrames { buf[i] = 1.0 }
        }

        // Stage 3: 4-step anchor-Euler flow matching
        let activeCount = featuresLength * featDim
        var noise = LuxTtsNoiseSource(seed: seed)
        var x = noise.nextGaussianArray(count: activeCount)

        let xArray = try makeZeroedArray(shape: [1, maxFrames, featDim], dataType: .float32)
        let tArray = try makeZeroedArray(shape: [1], dataType: .float32)
        let guidance = try makeZeroedArray(shape: [1], dataType: .float32)
        guidance[0] = NSNumber(value: LuxTtsConstants.guidanceScale)

        let timeSteps = LuxTtsSolver.timeSteps(numSteps: LuxTtsConstants.numSteps, tShift: LuxTtsConstants.tShift)
        var x0p = [Float](repeating: 0, count: activeCount)
        var x1p = [Float](repeating: 0, count: activeCount)
        var v = [Float](repeating: 0, count: activeCount)

        for step in 0..<LuxTtsConstants.numSteps {
            let tCur = Float(timeSteps[step])
            let tNext = Float(timeSteps[step + 1])
            let isLast = step == LuxTtsConstants.numSteps - 1

            tArray[0] = NSNumber(value: tCur)
            xArray.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                x.withUnsafeBufferPointer { src in
                    buf.baseAddress!.update(from: src.baseAddress!, count: activeCount)
                }
            }

            let out = try predict(
                stage: "FmDecoder step \(step)",
                model: core.fmDecoder,
                inputs: [
                    "t": MLFeatureValue(multiArray: tArray),
                    "x": MLFeatureValue(multiArray: xArray),
                    "text_condition": MLFeatureValue(multiArray: textCondition),
                    "speech_condition": MLFeatureValue(multiArray: speechCondition),
                    "guidance_scale": MLFeatureValue(multiArray: guidance),
                    "padding_mask": MLFeatureValue(multiArray: frameMask)
                ]
            )
            guard let vArray = out.featureValue(for: "v")?.multiArrayValue else {
                throw LuxTtsError.inferenceFailed(stage: "FmDecoder step \(step)", underlying: "no v output")
            }
            try copyRows(from: vArray, into: &v, rowCount: featuresLength, rowLength: featDim, stage: "FmDecoder step \(step)")

            var oneMinusT = 1.0 - tCur
            vDSP_vsma(v, 1, &oneMinusT, x, 1, &x1p, 1, vDSP_Length(activeCount))
            if isLast {
                x = x1p
            } else {
                var negT = -tCur
                vDSP_vsma(v, 1, &negT, x, 1, &x0p, 1, vDSP_Length(activeCount))
                var w0 = 1.0 - tNext
                var w1 = tNext
                vDSP_vsmsma(x0p, 1, &w0, x1p, 1, &w1, &x, 1, vDSP_Length(activeCount))
            }
        }

        // Stage 4: Vocoder (48 kHz)
        let melInput = try makeZeroedArray(shape: [1, featDim, bucket], dataType: .float32)
        let logFloor = log(LuxTtsConstants.logMelFloor)
        let invScale = 1.0 / LuxTtsConstants.featScale
        melInput.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
            for m in 0..<featDim {
                let row = m * bucket
                for f in 0..<genFrames {
                    buf[row + f] = x[(promptFrames + f) * featDim + m] * invScale
                }
                for f in genFrames..<bucket { buf[row + f] = logFloor }
            }
        }

        let vocoderModel = try ensureVocoderLoadedLocked(bucket: bucket, in: modelDirectory)
        let vocoderOut = try predict(
            stage: "Vocoder\(bucket)",
            model: vocoderModel,
            inputs: ["mel": MLFeatureValue(multiArray: melInput)]
        )
        guard let audioArray = vocoderOut.featureValue(for: "audio")?.multiArrayValue else {
            throw LuxTtsError.inferenceFailed(stage: "Vocoder\(bucket)", underlying: "no audio output")
        }

        let outputSamples = audioArray.shape.last?.intValue ?? audioArray.count
        let sampleCount = min((genFrames - 1) * LuxTtsConstants.hop48k, outputSamples)
        var samples = try copyRows(from: audioArray, rowCount: 1, rowLength: sampleCount, stage: "Vocoder\(bucket)")

        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(sampleCount))

        if promptRms < LuxTtsConstants.targetRms {
            var gain = promptRms / LuxTtsConstants.targetRms
            vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(sampleCount))
        }

        return LuxTtsSynthesisResult(
            samples: samples,
            sampleRate: LuxTtsConstants.outputSampleRate,
            promptFrames: promptFrames,
            generatedFrames: genFrames,
            featuresLength: featuresLength,
            redraws: 0,
            residualPauses: 0
        )
    }

    // MARK: - CoreML Loading & Tensor Helpers

    private struct CoreModels {
        let textEncoder: MLModel
        let fmDecoder: MLModel
        let tokenizer: LuxTtsTokenizer
    }

    private func ensureCoreModelsLoadedLocked(in dir: URL) throws -> CoreModels {
        lock.lock()
        let needsReload = loadedModelDirectory?.path != dir.path
        if needsReload {
            textEncoderModel = nil
            fmDecoderModel = nil
            vocoderModels.removeAll()
            tokenizer = nil
            loadedModelDirectory = dir
        }
        let existingText = textEncoderModel
        let existingFm = fmDecoderModel
        let existingTok = tokenizer
        lock.unlock()

        if let t = existingText, let f = existingFm, let k = existingTok {
            return CoreModels(textEncoder: t, fmDecoder: f, tokenizer: k)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        let textURL = dir.appendingPathComponent("gpu/TextEncoder.mlmodelc")
        let fmURL = dir.appendingPathComponent("gpu/FmDecoder.mlmodelc")
        let tokURL = dir.appendingPathComponent("tokens.txt")

        guard FileManager.default.fileExists(atPath: textURL.path) else {
            throw LuxTtsError.modelFileNotFound("gpu/TextEncoder.mlmodelc")
        }
        guard FileManager.default.fileExists(atPath: fmURL.path) else {
            throw LuxTtsError.modelFileNotFound("gpu/FmDecoder.mlmodelc")
        }

        let loadedText: MLModel
        do {
            loadedText = try MLModel(contentsOf: textURL, configuration: config)
        } catch {
            throw LuxTtsError.corruptedModel("gpu/TextEncoder.mlmodelc", underlying: error.localizedDescription)
        }

        let loadedFm: MLModel
        do {
            loadedFm = try MLModel(contentsOf: fmURL, configuration: config)
        } catch {
            throw LuxTtsError.corruptedModel("gpu/FmDecoder.mlmodelc", underlying: error.localizedDescription)
        }

        let loadedTok = try LuxTtsTokenizer(tokensFileURL: tokURL)

        lock.lock()
        textEncoderModel = loadedText
        fmDecoderModel = loadedFm
        tokenizer = loadedTok
        loadedModelDirectory = dir
        lock.unlock()

        logger.info("Loaded LuxTTS CoreML models from \(dir.path, privacy: .public)")
        return CoreModels(textEncoder: loadedText, fmDecoder: loadedFm, tokenizer: loadedTok)
    }

    private func ensureVocoderLoadedLocked(bucket: Int, in dir: URL) throws -> MLModel {
        lock.lock()
        if loadedModelDirectory?.path == dir.path, let cached = vocoderModels[bucket] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fileName = bucket == 282 ? "vocoder/Vocoder282.mlmodelc" : "vocoder/Vocoder555.mlmodelc"
        let vocURL = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: vocURL.path) else {
            throw LuxTtsError.modelFileNotFound(fileName)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let model: MLModel
        do {
            model = try MLModel(contentsOf: vocURL, configuration: config)
        } catch {
            throw LuxTtsError.corruptedModel(fileName, underlying: error.localizedDescription)
        }

        lock.lock()
        vocoderModels[bucket] = model
        lock.unlock()
        return model
    }

    private func makeZeroedArray(shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        do {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
            array.withUnsafeMutableBytes { bytes, _ in
                if let base = bytes.baseAddress, bytes.count > 0 {
                    memset(base, 0, bytes.count)
                }
            }
            return array
        } catch {
            throw LuxTtsError.inferenceFailed(stage: "allocation", underlying: "\(error)")
        }
    }

    private func predict(stage: String, model: MLModel, inputs: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            return try model.prediction(from: provider)
        } catch {
            throw LuxTtsError.inferenceFailed(stage: stage, underlying: error.localizedDescription)
        }
    }

    private func copyRows(from array: MLMultiArray, rowCount: Int, rowLength: Int, stage: String) throws -> [Float] {
        var out = [Float](repeating: 0, count: rowCount * rowLength)
        try copyRows(from: array, into: &out, rowCount: rowCount, rowLength: rowLength, stage: stage)
        return out
    }

    private func copyRows(
        from array: MLMultiArray,
        into out: inout [Float],
        rowCount: Int,
        rowLength: Int,
        stage: String
    ) throws {
        precondition(out.count >= rowCount * rowLength, "copyRows destination too small")
        let dims = array.shape.count
        guard array.dataType == .float32, dims >= 2,
              array.strides[dims - 1].intValue == 1,
              rowLength <= array.shape[dims - 1].intValue,
              rowCount <= array.shape[dims - 2].intValue
        else {
            throw LuxTtsError.inferenceFailed(
                stage: stage,
                underlying: "unexpected output layout: shape \(array.shape) strides \(array.strides)"
            )
        }
        let rowStride = array.strides[dims - 2].intValue
        array.withUnsafeBufferPointer(ofType: Float.self) { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rowCount {
                    dst.baseAddress!.advanced(by: row * rowLength)
                        .update(from: src.baseAddress!.advanced(by: row * rowStride), count: rowLength)
                }
            }
        }
    }

    private func resampleTo24k(samples: [Float], fromRate: Double) throws -> [Float] {
        let targetRate = Double(LuxTtsConstants.melSampleRate)
        if abs(fromRate - targetRate) < 1.0 { return samples }
        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: srcFmt, to: dstFmt)
        else {
            throw LuxTtsError.inferenceFailed(stage: "continuation resample", underlying: "converter setup failed")
        }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        _ = samples.withUnsafeBufferPointer { sPtr in
            memcpy(srcBuf.floatChannelData![0], sPtr.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        let cap = AVAudioFrameCount(Double(samples.count) * (targetRate / fromRate)) + 1024
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: cap) else {
            throw LuxTtsError.inferenceFailed(stage: "continuation resample", underlying: "buffer alloc failed")
        }
        nonisolated(unsafe) let srcRef = srcBuf
        nonisolated(unsafe) var done = false
        var err: NSError?
        let status = converter.convert(to: dstBuf, error: &err) { _, outStatus in
            if done {
                outStatus.pointee = .noDataNow
                return nil
            }
            done = true
            outStatus.pointee = .haveData
            return srcRef
        }
        guard status != .error, err == nil, dstBuf.frameLength > 0, let ch0 = dstBuf.floatChannelData?[0] else {
            throw LuxTtsError.inferenceFailed(stage: "continuation resample", underlying: err?.localizedDescription ?? "conversion failed")
        }
        return Array(UnsafeBufferPointer(start: ch0, count: Int(dstBuf.frameLength)))
    }
}
