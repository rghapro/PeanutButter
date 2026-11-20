import SwiftUI

/// Channel strip for individual Guide sub-channels (Sections, Directions/Guide, Fallback),
/// presented in the slide-out drawer directly beside the main Guide channel strip.
public struct GuideSubChannelStripView: View {
    let channel: GuideSubChannel
    @ObservedObject var engine: MultitrackAudioEngine

    // Fader calibration: 0.0 = -inf, 0.80 = 0.0 dB (unity), 1.0 = +6.0 dB
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42

    public init(channel: GuideSubChannel, engine: MultitrackAudioEngine) {
        self.channel = channel
        self.engine = engine
    }

    private var title: String {
        channel.displayTitle(for: engine.currentSong.guideSource)
    }

    private var volume: Float {
        switch channel {
        case .sections: return engine.currentSong.guideSectionsVolume
        case .directions: return engine.currentSong.guideDirectionsVolume
        case .fallback: return engine.currentSong.guideFallbackVolume
        }
    }

    private var isChannelEnabled: Bool {
        switch channel {
        case .sections: return engine.currentSong.guideSectionsEnabled
        case .directions: return engine.currentSong.guideDirectionsEnabled
        case .fallback: return engine.currentSong.guideFallbackEnabled
        }
    }

    private var isEffectivelyMuted: Bool {
        !isChannelEnabled || volume < 0.001
    }

    private var isSoloed: Bool {
        engine.guideSoloedSubChannels.contains(channel)
    }

    private var meterModel: StereoMeterModel {
        switch channel {
        case .sections: return engine.guideSectionsMeter
        case .directions: return engine.guideDirectionsMeter
        case .fallback: return engine.guideFallbackMeter
        }
    }

    private var helpText: String {
        switch channel {
        case .sections:
            return isEffectivelyMuted ? "Unmute Section Cues & Count-Ins" : "Mute Section Cues & Count-Ins"
        case .directions:
            if engine.currentSong.guideSource == .uploaded {
                return isEffectivelyMuted ? "Unmute Overlaid Guide Cues" : "Mute Overlaid Guide Cues"
            }
            return isEffectivelyMuted ? "Unmute Directional Cues" : "Mute Directional Cues"
        case .fallback:
            return isEffectivelyMuted
                ? "Unmute Fallback Voice Trim (loudness multiplier for fallback phrases)"
                : "Mute Fallback Voice Trim (loudness multiplier for fallback phrases)"
        }
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 1. Top Bar: Solo Button ('S') positioned at top left matching Click tray
            HStack {
                Button(action: {
                    engine.toggleGuideSubChannelSolo(channel)
                }) {
                    ZStack {
                        Circle()
                            .fill(isSoloed ? Color(red: 0.98, green: 0.72, blue: 0.12) : Color(white: 0.18))
                            .frame(width: 24, height: 24)

                        Text("S")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(isSoloed ? .black : Color(white: 0.6))
                    }
                }
                .buttonStyle(.plain)
                .help("Solo \(title)")

                Spacer()
            }
            .frame(width: 76)
            .padding(.top, 2)

            // 2. Fader Slot with VU Meter Line, Console Tick Marks, and Tactile Fader Cap
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let travel = max(10, slotHeight - capHeight)
                let currentY = (1.0 - CGFloat(volume)) * travel + (capHeight / 2)
                let slotWidth = capWidth + 18

                ZStack {
                    // Background Center Slot Groove
                    Rectangle()
                        .fill(Color(white: 0.12))
                        .frame(width: 3, height: slotHeight)

                    // Tick Marks at Standard Console dB Intervals (0 dB at 0.80)
                    faderTickMarksView(slotHeight: slotHeight)
                        .drawingGroup()

                    // Left VU Meter Level Indicator Line
                    StereoVUMeterPairView(meter: meterModel, isMuted: isEffectivelyMuted)
                        .frame(width: capWidth + 8, height: slotHeight)

                    // Tactile Fader Cap with White Horizontal Center Line
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(white: 0.32),
                                        Color(white: 0.20),
                                        Color(white: 0.14)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: capWidth, height: capHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(white: 0.38), lineWidth: 0.7)
                            )
                            .shadow(color: Color.black.opacity(0.7), radius: 3, x: 0, y: 2)

                        Rectangle()
                            .fill(Color.white)
                            .opacity(isEffectivelyMuted ? 0.35 : 1.0)
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .drawingGroup()
                    .position(x: slotWidth / 2, y: currentY)
                    .onTapGesture(count: 2) {
                        let resetLevel: Float = (channel == .fallback) ? 0.80 : engine.defaultChannelFaderLevel
                        engine.setGuideSubChannelVolume(channel: channel, volume: resetLevel, commit: true)
                    }
                }
                .frame(width: slotWidth, height: slotHeight)
                .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                            let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                            engine.setGuideSubChannelVolume(channel: channel, volume: max(0.0, min(1.0, norm)), commit: false)
                        }
                        .onEnded { value in
                            let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                            let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                            engine.setGuideSubChannelVolume(channel: channel, volume: max(0.0, min(1.0, norm)), commit: true)
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 3. Sub-Channel Label at Bottom (Click to Mute/Unmute)
            Button(action: {
                engine.toggleGuideSubChannelMute(channel)
            }) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isSoloed ? .white : (isEffectivelyMuted ? Color(white: 0.38) : Color.white))
                    .lineLimit(1)
                    .frame(width: 76, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
        .cornerRadius(4)
        .overlay(
            Rectangle()
                .fill(Color(white: 0.22))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    // MARK: - Tick Marks Component

    private func faderTickMarksView(slotHeight: CGFloat) -> some View {
        let travel = max(10, slotHeight - capHeight)
        let slotWidth = capWidth + 18

        return ZStack {
            // +6 dB mark (top)
            tickMarkRow(y: capHeight / 2)

            // 0 dB Unity mark (at 0.80 normalized volume)
            tickMarkRow(y: (1.0 - 0.80) * travel + (capHeight / 2))

            // -5 dB
            tickMarkRow(y: (1.0 - 0.65) * travel + (capHeight / 2))

            // -10 dB
            tickMarkRow(y: (1.0 - 0.50) * travel + (capHeight / 2))

            // -20 dB
            tickMarkRow(y: (1.0 - 0.35) * travel + (capHeight / 2))

            // -30 dB
            tickMarkRow(y: (1.0 - 0.22) * travel + (capHeight / 2))

            // -40 dB
            tickMarkRow(y: (1.0 - 0.12) * travel + (capHeight / 2))

            // -inf mark (bottom)
            tickMarkRow(y: slotHeight - (capHeight / 2))
        }
        .frame(width: slotWidth, height: slotHeight)
    }

    private func tickMarkRow(y: CGFloat) -> some View {
        HStack {
            Rectangle()
                .fill(Color(white: 0.28))
                .frame(width: 6, height: 1)
            Spacer()
            Rectangle()
                .fill(Color(white: 0.28))
                .frame(width: 6, height: 1)
        }
        .position(x: (capWidth + 18) / 2, y: y)
    }
}
