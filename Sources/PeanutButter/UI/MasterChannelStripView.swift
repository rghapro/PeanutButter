import SwiftUI

/// Master output strip for the mixer with real audio VU meter
public struct MasterChannelStripView: View {
    @Binding var volume: Float
    let leftPeak: Float
    let rightPeak: Float
    
    public init(volume: Binding<Float>, leftPeak: Float, rightPeak: Float) {
        self._volume = volume
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
    }
    
    public var body: some View {
        VStack(spacing: 5) {
            // Header
            VStack(spacing: 2) {
                Text("MASTER")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.white)
                
                Text("MAIN 1/2")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(3)
            }
            .frame(height: 48)
            
            // Fader & Stereo Meters
            HStack(spacing: 4) {
                // dB Scale Marks
                VStack(alignment: .trailing, spacing: 0) {
                    Text("+6").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.35))
                    Spacer()
                    Text(" 0").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.55))
                    Spacer()
                    Text("-6").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.35))
                    Spacer()
                    Text("-12").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.35))
                    Spacer()
                    Text("-24").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.35))
                    Spacer()
                    Text("-∞").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.35))
                }
                .frame(width: 18)
                .frame(height: 180)
                
                // Master Fader (White/Metallic Cap with Red Center Mark)
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: 0.06))
                            .frame(width: 8)
                        
                        let capHeight: CGFloat = 34
                        let capWidth: CGFloat = 34
                        let availableTravel = geo.size.height - capHeight
                        let yOffset = -CGFloat(volume) * availableTravel
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color.white,
                                            Color(white: 0.8),
                                            Color(white: 0.4)
                                        ]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: capWidth, height: capHeight)
                                .shadow(color: Color.black.opacity(0.7), radius: 4, x: 0, y: 2)
                            
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: capWidth - 4, height: 2)
                        }
                        .offset(y: yOffset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let normalized = 1.0 - Float(value.location.y / geo.size.height)
                                    volume = max(0.0, min(1.0, normalized))
                                }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(width: 36, height: 180)
                
                // Real Live Master Stereo VU Meters
                HStack(spacing: 2) {
                    VUMeterBar(level: leftPeak)
                    VUMeterBar(level: rightPeak)
                }
                .frame(width: 14, height: 180)
            }
            .frame(height: 180)
            
            // Readout
            Text(dbString)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.12))
                .cornerRadius(3)
        }
        .padding(8)
        .frame(width: 104)
        .background(Color(white: 0.16))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(white: 0.28), lineWidth: 1.5)
        )
    }
    
    private var dbString: String {
        if volume <= 0.001 { return "-∞" }
        let db = 20.0 * log10(volume)
        if abs(db) < 0.2 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }
}
