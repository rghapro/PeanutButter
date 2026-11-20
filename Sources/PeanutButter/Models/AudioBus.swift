import Foundation
import SwiftUI

/// Audio Sub-Mix Bus model matching MultiTracks Playback's 16 standard busses
public final class AudioBus: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: UUID
    @Published public var name: String
    @Published public var volume: Float = 0.80 // 0.80 = 0.0 dB Unity Gain (80% travel)
    @Published public var isMuted: Bool = false
    @Published public var isSoloed: Bool = false
    @Published public var isSoloSafe: Bool = false
    @Published public var isMono: Bool = false
    @Published public var physicalOutputChannel: String // e.g. "Out 1/2", "Out 3/4", "Out 1"
    @Published public var color: Color

    /// Shortened bus display label matching Playback's narrow mixer strips (`EG`, `AG`, `Perc`).
    public var abbreviatedName: String {
        let lower = name.lowercased()
        if lower.contains("electric") {
            return "EG"
        } else if lower.contains("acoustic") {
            return "AG"
        } else if lower == "percussion" {
            return "Perc"
        }
        return name
    }
    
    // Live VU Metering for Bus Channel Strip (isolated into `meter` so BusChannelStripView never re-evaluates on meter ticks)
    public let meter = StereoMeterModel()
    public var peakLevelLeft: Float = 0.0
    public var peakLevelRight: Float = 0.0
    public var rawPeakL: Float = 0.0
    public var rawPeakR: Float = 0.0
    
    public init(
        id: UUID = UUID(),
        name: String,
        volume: Float = 0.80,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isSoloSafe: Bool = false,
        isMono: Bool = false,
        physicalOutputChannel: String = "Out 1/2",
        color: Color = .blue
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isSoloSafe = isSoloSafe
        self.isMono = isMono || !physicalOutputChannel.contains("/")
        self.physicalOutputChannel = physicalOutputChannel
        self.color = color
    }
    
    /// Calculated linear gain for AVAudioMixerNode outputVolume (0.80 = 0.0 dB, 1.0 = +6.0 dB, 0.0 = -inf)
    public var linearGain: Float {
        if volume <= 0.001 { return 0.0 }
        if volume >= 0.80 {
            let db = ((volume - 0.80) / 0.20) * 6.0
            return pow(10.0, db / 20.0)
        } else {
            let norm = volume / 0.80
            return pow(norm, 2.0)
        }
    }
    
    /// The 16 standard MultiTracks Playback Busses
    public static func defaultBusses() -> [AudioBus] {
        let defaultChannelColor = Color(red: 0.20, green: 0.75, blue: 0.95)
        return [
            AudioBus(name: "Click", volume: 0.80, physicalOutputChannel: "Out 3/4", color: defaultChannelColor),
            AudioBus(name: "Guide", volume: 0.80, physicalOutputChannel: "Out 3/4", color: defaultChannelColor),
            AudioBus(name: "Drums", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Percussion", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Loops", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Bass", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Piano", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Keys", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Electric Guitars", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Acoustic Guitars", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Strings", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Horns", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Pad", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Vocals", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "FX", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor),
            AudioBus(name: "Aux", volume: 0.80, physicalOutputChannel: "Out 1/2", color: defaultChannelColor)
        ]
    }
}
