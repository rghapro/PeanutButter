import Testing
import Foundation
import AVFoundation
import Combine
import QuartzCore
@testable import PeanutButter

@Suite("UI Performance Tests")
struct UIPerformanceTests {

    private func makeTestPCMBuffer(
        frequency: Float = 440.0,
        frameCount: AVAudioFrameCount = 4_800,
        sampleRate: Double = 48_000.0
    ) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let ch0 = try #require(buffer.floatChannelData?[0])
        let ch1 = try #require(buffer.floatChannelData?[1])
        let phaseInc = 2.0 * Float.pi * frequency / Float(sampleRate)
        for i in 0..<Int(frameCount) {
            let sample = 0.25 * sin(phaseInc * Float(i))
            ch0[i] = sample
            ch1[i] = sample * 0.8
        }
        return buffer
    }

    @Test
    @MainActor
    func masterFaderInteractiveDragZeroInvalidationUntilCommit() {
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        engine.masterVolume = 0.80
        engine.markSessionSaved()
        engine.resetUndoHistoryToCurrentState()

        var engineInvalidations = 0
        let cancellable = engine.objectWillChange.sink { _ in
            engineInvalidations += 1
        }
        defer { cancellable.cancel() }

        // Simulate 120 high-rate drag updates across 0.80 -> 0.15 -> 0.90
        for step in 0..<60 {
            let v = 0.80 - Float(step) * (0.65 / 59.0)
            engine.applyInteractiveMasterVolume(v)
        }
        for step in 0..<60 {
            let v = 0.15 + Float(step) * (0.75 / 59.0)
            engine.applyInteractiveMasterVolume(v)
        }

        #expect(engineInvalidations == 0, "Live Master fader drag must not fire engine.objectWillChange")
        #expect(!engine.hasUnsavedChanges, "Live Master fader drag must not mark session dirty before gesture end")
        #expect(!engine.canUndo, "Live Master fader drag must not snapshot undo state per pixel")
        let expectedLiveGain = MultitrackAudioEngine.masterLinearGain(for: 0.90)
        #expect(abs(engine.currentMasterLinearGain - expectedLiveGain) < 1e-5)
        #expect(abs(engine.masterVolume - 0.80) < 1e-5)

        // Commit on drag release (masterVolume, hasUnsavedChanges, canUndo, canRedo)
        engine.commitInteractiveMasterVolume(0.90)
        #expect(engineInvalidations >= 1 && engineInvalidations <= 4, "Drag release commits masterVolume cleanly once")
        #expect(abs(engine.masterVolume - 0.90) < 1e-5)
        #expect(engine.hasUnsavedChanges)
        #expect(engine.canUndo)
    }

    @Test
    @MainActor
    func fadeOutAndFadeInZeroEngineAndChannelStripBodyInvalidation() throws {
        let defaults = UserDefaults.standard
        let savedLastSession = defaults.object(forKey: "Playback_LastSessionPath")
        defaults.removeObject(forKey: "Playback_LastSessionPath")
        defer {
            if let v = savedLastSession {
                defaults.set(v, forKey: "Playback_LastSessionPath")
            } else {
                defaults.removeObject(forKey: "Playback_LastSessionPath")
            }
        }

        let engine = MultitrackAudioEngine()
        engine.cancelAllSessionBackgroundTasks()
        let sr = engine.getCanonicalProcessingFormat().sampleRate
        let buf = try makeTestPCMBuffer(frameCount: 4_800, sampleRate: sr)

        let keysTrack = StemTrack(name: "Keys", role: .stem, volume: 0.80)
        let drumsTrack = StemTrack(name: "Drums", role: .stem, volume: 0.80)
        let clickTrack = StemTrack(name: "Click", role: .click, volume: 0.80)
        let guideTrack = StemTrack(name: "Guide", role: .guide, volume: 0.80)
        let song = Song(
            title: "Fade Perf Song",
            artist: "Band",
            bpm: 120.0,
            musicalKey: "C",
            sections: [SongSection(name: "Intro", startTime: 0.0, duration: 8.0)]
        )
        engine.currentSetlist = Setlist(name: "UI Perf Set", songs: [song])
        engine.currentSongIndex = 0
        engine.songBuffersCache[song.id] = [
            (keysTrack, buf),
            (drumsTrack, buf),
            (clickTrack, buf),
            (guideTrack, buf)
        ]
        engine.loadSong(song)

        var engineInvalidations = 0
        var stripBodyInvalidations = 0
        var faderCapUpdates = 0

        let cEngine = engine.objectWillChange.sink { _ in engineInvalidations += 1 }
        let cTrack = keysTrack.objectWillChange.sink { _ in stripBodyInvalidations += 1 }
        let cCap = keysTrack.faderDisplay.objectWillChange.sink { _ in faderCapUpdates += 1 }
        defer {
            cEngine.cancel()
            cTrack.cancel()
            cCap.cancel()
            engine.clearAllTracks()
        }

        // Fade Out
        engine.startFadeOut(duration: 0.30)
        // Reset counters right after the initial FADE button state flip
        engineInvalidations = 0
        stripBodyInvalidations = 0
        faderCapUpdates = 0

        let outStart = CACurrentMediaTime()
        for step in 1...30 {
            engine.tickActiveManualFade(now: outStart + Double(step) * 0.015)
        }

        #expect(engineInvalidations == 0, "Fade Out ticks must not fire engine.objectWillChange")
        #expect(stripBodyInvalidations == 0, "Fade Out ticks must not invalidate ChannelStripView bodies")
        #expect(faderCapUpdates > 0, "Isolated faderDisplay must still animate the fader cap")
        #expect(abs(keysTrack.volume - 0.0) < 1e-5)
        #expect(abs(drumsTrack.volume - 0.0) < 1e-5)
        #expect(abs(clickTrack.volume - 0.80) < 1e-5)
        #expect(abs(guideTrack.volume - 0.80) < 1e-5)

        // Fade In
        engine.startFadeIn(duration: 0.30)
        engineInvalidations = 0
        stripBodyInvalidations = 0
        faderCapUpdates = 0

        let inStart = CACurrentMediaTime()
        for step in 1...30 {
            engine.tickActiveManualFade(now: inStart + Double(step) * 0.015)
        }

        #expect(engineInvalidations == 0, "Fade In ticks must not fire engine.objectWillChange")
        #expect(stripBodyInvalidations == 0, "Fade In ticks must not invalidate ChannelStripView bodies")
        #expect(faderCapUpdates > 0, "Isolated faderDisplay must animate fader cap back up")
        #expect(abs(keysTrack.volume - 0.80) < 1e-5)
        #expect(abs(drumsTrack.volume - 0.80) < 1e-5)
        #expect(abs(clickTrack.volume - 0.80) < 1e-5)
        #expect(abs(guideTrack.volume - 0.80) < 1e-5)
    }
}
