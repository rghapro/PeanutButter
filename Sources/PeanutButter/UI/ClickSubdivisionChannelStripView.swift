import SwiftUI

/// Channel strip for individual Click Metronome subdivisions (Accent, 1/4, 1/8, 1/16),
/// presented in the slide-out drawer directly beside the main Click channel strip
public struct ClickSubdivisionChannelStripView: View {
    let subdivision: ClickSubdivision
    @ObservedObject var engine: MultitrackAudioEngine
    
    // Fader calibration: 0.0 = -inf, 0.80 = 0.0 dB (unity), 1.0 = +6.0 dB
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42
    
    public init(subdivision: ClickSubdivision, engine: MultitrackAudioEngine) {
        self.subdivision = subdivision
        self.engine = engine
    }
    
    private var title: String {
        switch subdivision {
        case .accent: return "Accent"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        }
    }
    
    private var volume: Float {
        switch subdivision {
        case .accent: return engine.currentSong.clickAccentVolume
        case .quarter: return engine.currentSong.clickQuarterVolume
        case .eighth: return engine.currentSong.clickEighthVolume
        case .sixteenth: return engine.currentSong.clickSixteenthVolume
        }
    }
    
    private var isSubdivisionEnabled: Bool {
        switch subdivision {
        case .accent: return engine.currentSong.clickAccentEnabled
        case .quarter: return engine.currentSong.clickQuarterEnabled
        case .eighth: return engine.currentSong.clickEighthEnabled
        case .sixteenth: return engine.currentSong.clickSixteenthEnabled
        }
    }

    private var isEffectivelyMuted: Bool {
        !isSubdivisionEnabled || volume < 0.001
    }

    private var isSoloed: Bool {
        engine.clickSoloedSubdivisions.contains(subdivision)
    }
    
    private var clickMeterModel: StereoMeterModel? {
        switch subdivision {
        case .accent: return engine.clickAccentMeter
        case .quarter: return engine.clickQuarterMeter
        case .eighth: return engine.clickEighthMeter
        case .sixteenth: return engine.clickSixteenthMeter
        }
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // 1. Top Bar: Solo Button ('S') positioned at top left matching Photo 2
            HStack {
                Button(action: {
                    engine.toggleClickSubdivisionSolo(subdivision)
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
                .help("Solo \(title) Subdivision")
                
                Spacer()
            }
            .frame(width: 76)
            .padding(.top, 2)
            
            // 2. Fader Slot with Real VU Meter Line, Tick Marks, and Tactile Fader Cap
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
                    
                    // Left VU Meter Level Indicator Line (matching ChannelStripView)
                    if let meter = clickMeterModel {
                        StereoVUMeterPairView(meter: meter, isMuted: isEffectivelyMuted)
                            .frame(width: capWidth + 8, height: slotHeight)
                    } else {
                        Rectangle()
                            .fill(Color(white: 0.18))
                            .frame(width: 2, height: slotHeight)
                            .offset(x: -(slotWidth / 2 - 4))
                    }
                    
                    // Tactile Fader Cap with White Horizontal Center Line (matching ChannelStripView)
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
                        
                        // Crisp White Horizontal Line on Cap (dims when muted)
                        Rectangle()
                            .fill(Color.white)
                            .opacity(isEffectivelyMuted ? 0.35 : 1.0)
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .drawingGroup()
                    .position(x: slotWidth / 2, y: currentY)
                    .onTapGesture(count: 2) {
                        // Double-click resets to default fader level
                        engine.setClickSubdivisionVolume(subdivision: subdivision, volume: engine.defaultChannelFaderLevel, commit: true)
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
                            engine.setClickSubdivisionVolume(subdivision: subdivision, volume: max(0.0, min(1.0, norm)), commit: false)
                        }
                        .onEnded { value in
                            let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                            let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                            engine.setClickSubdivisionVolume(subdivision: subdivision, volume: max(0.0, min(1.0, norm)), commit: true)
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 3. Subdivision Label at Bottom (Click to Mute/Unmute + syncs with Click Options toggles)
            Button(action: {
                engine.toggleClickSubdivisionMute(subdivision)
            }) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isSoloed ? .white : (isEffectivelyMuted ? Color(white: 0.38) : Color.white))
                    .lineLimit(1)
                    .frame(width: 76, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isEffectivelyMuted ? "Unmute \(title)" : "Mute \(title)")
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
            let zeroDby = (1.0 - 0.80) * travel + (capHeight / 2)
            tickMarkRow(y: zeroDby)
            
            // -5 dB
            let m5y = (1.0 - 0.65) * travel + (capHeight / 2)
            tickMarkRow(y: m5y)
            
            // -10 dB
            let m10y = (1.0 - 0.50) * travel + (capHeight / 2)
            tickMarkRow(y: m10y)
            
            // -20 dB
            let m20y = (1.0 - 0.35) * travel + (capHeight / 2)
            tickMarkRow(y: m20y)
            
            // -30 dB
            let m30y = (1.0 - 0.22) * travel + (capHeight / 2)
            tickMarkRow(y: m30y)
            
            // -40 dB
            let m40y = (1.0 - 0.12) * travel + (capHeight / 2)
            tickMarkRow(y: m40y)
            
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
