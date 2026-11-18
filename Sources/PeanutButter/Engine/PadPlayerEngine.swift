import Foundation
import AVFoundation
import Combine
import os

/// Ambient Pad Player engine designed for continuous, seamless worship pads.
/// Features:
/// - 3.0-second smooth exponential/equal-power fade-in
/// - 5.0-second smooth fade-out on stop
/// - Continuous sample-accurate self-crossfade loop indefinitely
/// - Seamless crossfading when transitioning between musical keys
/// - CoreAudio hardware-clocked sample rendering via AVAudioSourceNode
public final class PadPlayerEngine: ObservableObject, @unchecked Sendable {
    private var lock = os_unfair_lock()
    
    // CoreAudio integration
    private weak var audioEngine: AVAudioEngine?
    private weak var masterMixer: AVAudioMixerNode?
    private var sourceNode: AVAudioSourceNode?
    private var processingFormat: AVAudioFormat?
    
    // State
    public let meter = StereoMeterModel()
    private var peakAccumL: Float = 0.0
    private var peakAccumR: Float = 0.0
    @Published public private(set) var activeKey: String = "C"
    @Published public private(set) var activePackId: String? = nil
    @Published public private(set) var isPlaying: Bool = false
    public private(set) var isFadingIn: Bool = false
    public private(set) var isFadingOut: Bool = false
    
    private var fadeGain: Float = 0.0
    private var padBusGain: Float = 1.0
    private var padVolume: Float = 1.0
    private var padPan: Float = 0.0
    private var targetOutputChannelL: Int = 0
    private var targetOutputChannelR: Int = 1
    
    public func setTargetOutputChannels(left: Int, right: Int) {
        os_unfair_lock_lock(&lock)
        self.targetOutputChannelL = left
        self.targetOutputChannelR = right
        os_unfair_lock_unlock(&lock)
    }
    
    // Active looping buffer
    private var activeBuffer: AVAudioPCMBuffer?
    private var activeBufferLength: Int64 = 0
    private var activeDataL: UnsafeMutablePointer<Float>?
    private var activeDataR: UnsafeMutablePointer<Float>?
    private var primaryFrame: Int64 = 0
    private var crossfadeFrame: Int64 = 0
    
    // Key transition buffer
    private var nextBuffer: AVAudioPCMBuffer?
    private var nextBufferLength: Int64 = 0
    private var nextDataL: UnsafeMutablePointer<Float>?
    private var nextDataR: UnsafeMutablePointer<Float>?
    private var nextFrame: Int64 = 0
    private var isKeyCrossfading: Bool = false
    private var keyCrossfadeProgress: Float = 0.0
    
    // Configurable Fade Durations (4.6)
    public static let fadeInDefaultsKey = "Playback_PadFadeInDuration"
    public static let fadeOutDefaultsKey = "Playback_PadFadeOutDuration"
    public static let defaultFadeInSeconds: Double = 2.5
    public static let defaultFadeOutSeconds: Double = 3.0
    
    @Published public var fadeInSeconds: Double {
        didSet {
            UserDefaults.standard.set(fadeInSeconds, forKey: Self.fadeInDefaultsKey)
        }
    }
    @Published public var fadeOutSeconds: Double {
        didSet {
            UserDefaults.standard.set(fadeOutSeconds, forKey: Self.fadeOutDefaultsKey)
        }
    }
    
    private let loopCrossfadeSeconds: Double = 5.0
    private let keyCrossfadeSeconds: Double = 4.0
    
    public init() {
        let savedIn = UserDefaults.standard.object(forKey: Self.fadeInDefaultsKey) as? Double
        let savedOut = UserDefaults.standard.object(forKey: Self.fadeOutDefaultsKey) as? Double
        self.fadeInSeconds = max(0.25, min(15.0, savedIn ?? Self.defaultFadeInSeconds))
        self.fadeOutSeconds = max(0.25, min(15.0, savedOut ?? Self.defaultFadeOutSeconds))
    }
    
    deinit {
        detach()
    }
    
    public func setProcessingFormat(_ format: AVAudioFormat) {
        os_unfair_lock_lock(&lock)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000.0
        self.processingFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        os_unfair_lock_unlock(&lock)
    }
    
    public func attach(to engine: AVAudioEngine, masterMixer: AVAudioMixerNode, format: AVAudioFormat) {
        detach()
        self.audioEngine = engine
        self.masterMixer = masterMixer
        self.processingFormat = format
    }
    
    public func detach() {
        if let existing = sourceNode {
            if let engine = audioEngine {
                engine.disconnectNodeOutput(existing)
                engine.detach(existing)
            }
            sourceNode = nil
        }
    }
    
    public func setBusGain(_ gain: Float) {
        os_unfair_lock_lock(&lock)
        self.padBusGain = max(0.0, gain)
        os_unfair_lock_unlock(&lock)
    }
    
    public func setVolume(_ volume: Float) {
        os_unfair_lock_lock(&lock)
        self.padVolume = max(0.0, volume)
        os_unfair_lock_unlock(&lock)
    }

    public func setPan(_ pan: Float) {
        os_unfair_lock_lock(&lock)
        self.padPan = max(-1.0, min(1.0, pan))
        os_unfair_lock_unlock(&lock)
    }

    public func consumeMeterPeaks() -> (Float, Float) {
        os_unfair_lock_lock(&lock)
        let l = peakAccumL
        let r = peakAccumR
        peakAccumL = 0.0
        peakAccumR = 0.0
        os_unfair_lock_unlock(&lock)
        return (l, r)
    }
    
    private func applyMicroEdgeFades(to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 1024 else { return }
        let fadeLen = min(512, Int(buffer.frameLength / 4))
        for ch in 0..<Int(buffer.format.channelCount) {
            let ptr = data[ch]
            for f in 0..<fadeLen {
                let ramp = Float(f) / Float(fadeLen)
                let w = (1.0 - cos(ramp * Float.pi)) * 0.5
                ptr[f] *= w
                let endIdx = Int(buffer.frameLength) - 1 - f
                ptr[endIdx] *= w
            }
        }
    }
    
    public func start(key: String, packId: String? = nil) {
        let normKey = AudioSampleBank.normalizeKeyForPad(key)
        let fmt = processingFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        
        guard let buffer = PadLibraryManager.shared.getPadBuffer(for: normKey, packId: packId, format: fmt) else {
            print("PadPlayerEngine: Failed to load sample for key \(normKey)")
            return
        }
        applyMicroEdgeFades(to: buffer)
        
        os_unfair_lock_lock(&lock)
        
        // If already playing the same key and same pack and fading out, reverse to fade in smoothly
        if isPlaying && activeKey == normKey && activePackId == packId {
            isFadingOut = false
            isFadingIn = true
            os_unfair_lock_unlock(&lock)
            return
        }
        
        // If playing a DIFFERENT key or pack, smoothly crossfade
        if isPlaying && activeBuffer != nil {
            activeKey = normKey
            activePackId = packId
            nextBuffer = buffer
            nextBufferLength = Int64(buffer.frameLength)
            if let ch = buffer.floatChannelData {
                nextDataL = ch[0]
                nextDataR = buffer.format.channelCount > 1 ? ch[1] : ch[0]
            } else {
                nextDataL = nil
                nextDataR = nil
            }
            nextFrame = 0
            isKeyCrossfading = true
            keyCrossfadeProgress = 0.0
            isFadingOut = false
            os_unfair_lock_unlock(&lock)
            return
        }
        
        // Fresh start
        activeKey = normKey
        activePackId = packId ?? PadLibraryManager.shared.activePackId
        activeBuffer = buffer
        activeBufferLength = Int64(buffer.frameLength)
        if let ch = buffer.floatChannelData {
            activeDataL = ch[0]
            activeDataR = buffer.format.channelCount > 1 ? ch[1] : ch[0]
        } else {
            activeDataL = nil
            activeDataR = nil
        }
        primaryFrame = 0
        crossfadeFrame = 0
        
        nextBuffer = nil
        isKeyCrossfading = false
        
        isPlaying = true
        isFadingIn = true
        isFadingOut = false
        fadeGain = 0.0
        
        os_unfair_lock_unlock(&lock)
    }
    
    public func transitionToKey(_ key: String, packId: String? = nil) {
        let normKey = AudioSampleBank.normalizeKeyForPad(key)
        let resolvedPack = packId ?? PadLibraryManager.shared.activePackId
        os_unfair_lock_lock(&lock)
        guard isPlaying, (activeKey != normKey || activePackId != resolvedPack) else {
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)
        
        let fmt = processingFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        guard let buffer = PadLibraryManager.shared.getPadBuffer(for: normKey, packId: resolvedPack, format: fmt) else {
            return
        }
        applyMicroEdgeFades(to: buffer)
        
        os_unfair_lock_lock(&lock)
        activeKey = normKey
        activePackId = resolvedPack
        nextBuffer = buffer
        nextBufferLength = Int64(buffer.frameLength)
        if let ch = buffer.floatChannelData {
            nextDataL = ch[0]
            nextDataR = buffer.format.channelCount > 1 ? ch[1] : ch[0]
        } else {
            nextDataL = nil
            nextDataR = nil
        }
        nextFrame = 0
        isKeyCrossfading = true
        keyCrossfadeProgress = 0.0
        os_unfair_lock_unlock(&lock)
    }
    
    public func reloadCurrentKey(packId: String? = nil) {
        os_unfair_lock_lock(&lock)
        let curKey = activeKey
        let targetPack = packId ?? PadLibraryManager.shared.activePackId
        guard isPlaying else {
            activePackId = targetPack
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)
        
        let fmt = processingFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        guard let buffer = PadLibraryManager.shared.getPadBuffer(for: curKey, packId: targetPack, format: fmt) else {
            return
        }
        applyMicroEdgeFades(to: buffer)
        
        os_unfair_lock_lock(&lock)
        activePackId = targetPack
        nextBuffer = buffer
        nextBufferLength = Int64(buffer.frameLength)
        if let ch = buffer.floatChannelData {
            nextDataL = ch[0]
            nextDataR = buffer.format.channelCount > 1 ? ch[1] : ch[0]
        } else {
            nextDataL = nil
            nextDataR = nil
        }
        nextFrame = 0
        isKeyCrossfading = true
        keyCrossfadeProgress = 0.0
        os_unfair_lock_unlock(&lock)
    }
    
    public func stop() {
        os_unfair_lock_lock(&lock)
        if isPlaying {
            isFadingIn = false
            isFadingOut = true
        }
        os_unfair_lock_unlock(&lock)
    }
    
    public func stopImmediately() {
        os_unfair_lock_lock(&lock)
        isPlaying = false
        isFadingIn = false
        isFadingOut = false
        fadeGain = 0.0
        os_unfair_lock_unlock(&lock)
    }
    
    public var hasActiveAudioToRender: Bool {
        os_unfair_lock_lock(&lock)
        let active = (isPlaying || fadeGain > 0.0001) && activeDataL != nil && activeDataR != nil && activeBufferLength > 0
        os_unfair_lock_unlock(&lock)
        return active
    }

    @discardableResult
    public func renderDirect(
        frameCount: Int,
        channelPointers: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
        masterGain: Float = 1.0,
        masterSumL: UnsafeMutablePointer<Float>? = nil,
        masterSumR: UnsafeMutablePointer<Float>? = nil
    ) -> (didRender: Bool, outChL: Int, outChR: Int) {
        guard frameCount > 0, !channelPointers.isEmpty else { return (false, 0, 0) }
        
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        guard (isPlaying || fadeGain > 0.0001),
              let initialBufL = activeDataL,
              let initialBufR = activeDataR,
              activeBufferLength > 0 else {
            return (false, 0, 0)
        }
        var bufL = initialBufL
        var bufR = initialBufR
        var curBufferLength = activeBufferLength
        
        let chL = min(targetOutputChannelL, channelPointers.count - 1)
        let chR = min(targetOutputChannelR, channelPointers.count - 1)
        let outL = channelPointers[chL]
        let outR = channelPointers[chR]
        
        let sampleRate = processingFormat?.sampleRate ?? 44100.0
        let fadeInStep = Float(1.0 / (max(0.05, fadeInSeconds) * sampleRate))
        let fadeOutStep = Float(1.0 / (max(0.05, fadeOutSeconds) * sampleRate))
        let keyStep = Float(1.0 / (keyCrossfadeSeconds * sampleRate))
        
        var crossfadeFrames = min(Int64(loopCrossfadeSeconds * sampleRate), max(1, curBufferLength / 3))
        var loopPoint = max(1, curBufferLength - crossfadeFrames)
        
        let busVol = padBusGain * padVolume * 0.355 // Boosted +3 dB (-9 dB total trim vs raw sample) while keeping fader in place
        let panGainL: Float = padPan <= 0 ? 1.0 : max(0.0, 1.0 - padPan)
        let panGainR: Float = padPan >= 0 ? 1.0 : max(0.0, 1.0 + padPan)
        var blockPeakL: Float = 0.0
        var blockPeakR: Float = 0.0
        
        for i in 0..<frameCount {
            // Envelope update
            if isFadingIn {
                fadeGain += fadeInStep
                if fadeGain >= 1.0 {
                    fadeGain = 1.0
                    isFadingIn = false
                }
            } else if isFadingOut {
                fadeGain -= fadeOutStep
                if fadeGain <= 0.0 {
                    fadeGain = 0.0
                    isFadingOut = false
                    isPlaying = false
                    break
                }
            }
            
            // Primary stream sample
            var sL: Float = 0.0
            var sR: Float = 0.0
            
            if primaryFrame < loopPoint {
                sL = bufL[Int(primaryFrame)]
                sR = bufR[Int(primaryFrame)]
                primaryFrame += 1
            } else {
                // In loop self-crossfade region
                let crossIdx = primaryFrame - loopPoint
                let t = Float(crossIdx) / Float(max(1, crossfadeFrames))
                let clampedT = max(0.0, min(1.0, t))
                
                // Equal-power crossfade weights
                let angle = clampedT * (Float.pi * 0.5)
                let w1 = cos(angle)
                let w2 = sin(angle)
                
                let s1L = bufL[Int(min(primaryFrame, curBufferLength - 1))]
                let s1R = bufR[Int(min(primaryFrame, curBufferLength - 1))]
                
                let s2L = bufL[Int(crossfadeFrame % curBufferLength)]
                let s2R = bufR[Int(crossfadeFrame % curBufferLength)]
                
                sL = (s1L * w1) + (s2L * w2)
                sR = (s1R * w1) + (s2R * w2)
                
                primaryFrame += 1
                crossfadeFrame += 1
                
                if primaryFrame >= curBufferLength {
                    // Loop wrap: stream 2 is now stream 1
                    primaryFrame = crossfadeFrame
                    crossfadeFrame = 0
                }
            }
            
            // Key crossfading if transitioning between keys
            if isKeyCrossfading,
               let nL = nextDataL,
               let nR = nextDataR,
               nextBufferLength > 0 {
                let kt = max(0.0, min(1.0, keyCrossfadeProgress))
                let kAngle = kt * (Float.pi * 0.5)
                let kwOld = cos(kAngle)
                let kwNew = sin(kAngle)
                
                let nSampL = nL[Int(nextFrame % nextBufferLength)]
                let nSampR = nR[Int(nextFrame % nextBufferLength)]
                nextFrame += 1
                
                sL = (sL * kwOld) + (nSampL * kwNew)
                sR = (sR * kwOld) + (nSampR * kwNew)
                
                keyCrossfadeProgress += keyStep
                if keyCrossfadeProgress >= 1.0 {
                    isKeyCrossfading = false
                    activeBuffer = nextBuffer
                    activeBufferLength = nextBufferLength
                    activeDataL = nextDataL
                    activeDataR = nextDataR
                    let effNextCrossfade = min(Int64(loopCrossfadeSeconds * sampleRate), max(1, nextBufferLength / 3))
                    let lp = max(1, nextBufferLength - effNextCrossfade)
                    let wrappedNext = nextFrame % max(1, nextBufferLength)
                    primaryFrame = wrappedNext
                    crossfadeFrame = wrappedNext >= lp ? (wrappedNext - lp) : 0
                    if let newL = nextDataL, let newR = nextDataR {
                        bufL = newL
                        bufR = newR
                        curBufferLength = nextBufferLength
                        crossfadeFrames = effNextCrossfade
                        loopPoint = lp
                    }
                    nextBuffer = nil
                }
            }
            
            let curGain = fadeGain * busVol
            let preMasterL = sL * curGain * panGainL
            let preMasterR = sR * curGain * panGainR
            let outSampleL = preMasterL * masterGain
            let outSampleR = preMasterR * masterGain
            outL[i] += outSampleL
            if chR != chL {
                outR[i] += outSampleR
            }
            if let mSumL = masterSumL {
                mSumL[i] += outSampleL
            }
            if let mSumR = masterSumR {
                mSumR[i] += outSampleR
            }
            let absL = abs(preMasterL)
            let absR = abs(preMasterR)
            if absL > blockPeakL { blockPeakL = absL }
            if absR > blockPeakR { blockPeakR = absR }
        }
        if blockPeakL > peakAccumL { peakAccumL = blockPeakL }
        if blockPeakR > peakAccumR { peakAccumR = blockPeakR }
        return (true, chL, chR)
    }

    public func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard frameCount > 0, abl.count > 0 else { return noErr }
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: abl.count) { temp in
            var count = 0
            for ch in 0..<abl.count {
                if let ptr = abl[ch].mData?.assumingMemoryBound(to: Float.self) {
                    temp[count] = ptr
                    count += 1
                }
            }
            guard count > 0 else { return }
            renderDirect(frameCount: frameCount, channelPointers: UnsafeBufferPointer(start: temp.baseAddress, count: count))
        }
        return noErr
    }
}
