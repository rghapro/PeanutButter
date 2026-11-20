import SwiftUI

/// Channel strip for Sub-Mix Busses when the mixer is switched to BUSES mode (matching Playback)
public struct BusChannelStripView: View {
    @ObservedObject var bus: AudioBus
    @ObservedObject private var deviceManager = AudioDeviceManager.shared
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil
    let onParametersChanged: () -> Void
    
    // Fader calibration
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42
    
    private var displayedBusName: String {
        bus.abbreviatedName
    }
    
    var isAutomationMode: Bool = false
    var isBusAutomated: Bool = false
    var onLiveDragChanged: (() -> Void)? = nil
    var reservedOutputLabel: ((String, Bool) -> String?)? = nil
    
    public init(
        bus: AudioBus,
        isExpanded: Bool = false,
        isAutomationMode: Bool = false,
        isBusAutomated: Bool = false,
        onToggleExpand: (() -> Void)? = nil,
        onLiveDragChanged: (() -> Void)? = nil,
        reservedOutputLabel: ((String, Bool) -> String?)? = nil,
        onParametersChanged: @escaping () -> Void
    ) {
        self.bus = bus
        self.isExpanded = isExpanded
        self.isAutomationMode = isAutomationMode
        self.isBusAutomated = isBusAutomated
        self.onToggleExpand = onToggleExpand
        self.onLiveDragChanged = onLiveDragChanged
        self.reservedOutputLabel = reservedOutputLabel
        self.onParametersChanged = onParametersChanged
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // 1. Solo Button
            Button(action: {
                if NSEvent.modifierFlags.contains(.command) {
                    bus.isSoloSafe.toggle()
                } else {
                    bus.isSoloed.toggle()
                }
                onParametersChanged()
            }) {
                ZStack {
                    Circle()
                        .fill(bus.isSoloed ? Color(red: 0.98, green: 0.72, blue: 0.12) : Color(white: 0.18))
                        .frame(width: 24, height: 24)
                    
                    if bus.isSoloSafe {
                        Circle()
                            .stroke(Color(red: 0.98, green: 0.72, blue: 0.12), lineWidth: 2.0)
                            .frame(width: 24, height: 24)
                    }
                    
                    Text("S")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(bus.isSoloed ? .black : (bus.isSoloSafe ? Color(red: 0.98, green: 0.72, blue: 0.12) : Color(white: 0.6)))
                }
            }
            .buttonStyle(.plain)
            .help("Solo Bus: \(bus.name) (CMD+Click for Solo Safe)")
            
            // 2. Physical Output Channel Menu (Matched to Mixer Pan control size & position)
            Menu {
                let (stereoOuts, monoOuts) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
                Section("Stereo Pairs") {
                    ForEach(stereoOuts, id: \.self) { outChan in
                        let reserved = reservedOutputLabel?(outChan, false)
                        Button(action: {
                            bus.physicalOutputChannel = outChan
                            bus.isMono = false
                            onParametersChanged()
                        }) {
                            HStack {
                                Text(reserved != nil ? "\(outChan) (\(reserved!))" : outChan)
                                if bus.physicalOutputChannel == outChan && !bus.isMono {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(reserved != nil)
                    }
                }
                
                Section("Mono Outputs") {
                    ForEach(monoOuts, id: \.self) { outChan in
                        let reserved = reservedOutputLabel?(outChan, true)
                        Button(action: {
                            bus.physicalOutputChannel = outChan
                            bus.isMono = true
                            onParametersChanged()
                        }) {
                            HStack {
                                Text(reserved != nil ? "\(outChan) (\(reserved!))" : outChan)
                                if bus.physicalOutputChannel == outChan && bus.isMono {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(reserved != nil)
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.12))
                        .frame(width: 50, height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(white: 0.22), lineWidth: 0.8)
                        )
                    
                    Text(bus.physicalOutputChannel)
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                }
                .frame(width: 50, height: 12)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 50, height: 12)
            .help("Bus Output: \(bus.physicalOutputChannel)")
            
            // 3. Fader Slot & Dual Metering with Dynamic Full-Height Geometry
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let travel = max(10, slotHeight - capHeight)
                let currentY = (1.0 - CGFloat(bus.volume)) * travel + (capHeight / 2)
                let slotWidth = capWidth + 18
                
                ZStack {
                    // Background Center Slot Groove
                    Rectangle()
                        .fill(Color(white: 0.06))
                        .frame(width: 3, height: slotHeight)
                    
                    // Tick Marks (0 dB at 0.80)
                    faderTickMarksView(slotHeight: slotHeight)
                    
                    // Real Live Bus Stereo VU Meters (isolated from BusChannelStripView re-renders)
                    StereoVUMeterPairView(meter: bus.meter, isMuted: bus.isMuted)
                        .frame(width: capWidth + 8, height: slotHeight)
                    
                    // Tactile Fader Cap
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
                                    .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.7), radius: 3, x: 0, y: 2)
                        
                        Rectangle()
                            .fill(bus.isMuted ? Color(white: 0.38) : Color.white)
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .position(x: slotWidth / 2, y: currentY)
                    .onTapGesture(count: 2) {
                        bus.volume = 0.80 // 0.0 dB unity
                        onParametersChanged()
                    }
                }
                .frame(width: slotWidth, height: slotHeight)
                .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
                .contentShape(Rectangle())
                .overlay(
                    Group {
                        if isAutomationMode {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(red: 0.25, green: 0.88, blue: 0.45), lineWidth: 1.2)
                        }
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                            let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                            bus.volume = max(0.0, min(1.0, norm))
                            if let liveDrag = onLiveDragChanged {
                                liveDrag()
                            } else {
                                onParametersChanged()
                            }
                        }
                        .onEnded { _ in
                            onParametersChanged()
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 4. Bus Name Label (Clicking mutes bus; grays out when muted; height matched to Mixer ChannelStripView)
            let busGreen = Color(red: 0.25, green: 0.88, blue: 0.45)
            let busNameColor: Color = (isAutomationMode || isBusAutomated)
                ? (bus.isMuted ? busGreen.opacity(0.38) : busGreen)
                : (bus.isMuted ? Color(white: 0.38) : Color.white)
            Button(action: {
                bus.isMuted.toggle()
                onParametersChanged()
            }) {
                Text(displayedBusName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(busNameColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 76, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 82, height: 36)
            .help(bus.isMuted ? "Unmute Bus: \(bus.name)" : "Mute Bus: \(bus.name)")
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color(red: 0.10, green: 0.11, blue: 0.12))
        .cornerRadius(4)
        .overlay(
            ZStack(alignment: .trailing) {
                // Subtle 1px right border divider
                Rectangle()
                    .fill(Color(white: 0.16))
                    .frame(width: 1)
                
                // Bus Assigned Channels Tray Toggle Arrow (matching Click channel strip tray)
                if let onToggleExpand = onToggleExpand {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.20)) {
                            onToggleExpand()
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(Color(white: 0.50))
                            .frame(width: 12, height: 26)
                            .background(Color(red: 0.10, green: 0.11, blue: 0.12).opacity(0.85))
                            .cornerRadius(2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5)
                    .help(isExpanded ? "Collapse \(bus.name) Channels" : "Expand \(bus.name) Channels")
                }
            },
            alignment: .trailing
        )
    }
    
    private func faderTickMarksView(slotHeight: CGFloat) -> some View {
        let travel = max(10, slotHeight - capHeight)
        let slotWidth = capWidth + 18
        
        return ZStack {
            tickMarkRow(y: capHeight / 2)
            tickMarkRow(y: (1.0 - 0.80) * travel + (capHeight / 2), isProminent: true)
            tickMarkRow(y: (1.0 - 0.56) * travel + (capHeight / 2))
            tickMarkRow(y: (1.0 - 0.40) * travel + (capHeight / 2))
            tickMarkRow(y: (1.0 - 0.20) * travel + (capHeight / 2))
            tickMarkRow(y: travel + (capHeight / 2))
        }
        .frame(width: slotWidth, height: slotHeight)
    }
    
    private func tickMarkRow(y: CGFloat, isProminent: Bool = false) -> some View {
        let slotWidth = capWidth + 18
        return HStack {
            Rectangle()
                .fill(Color(white: isProminent ? 0.6 : 0.3))
                .frame(width: isProminent ? 5 : 3.5, height: 1)
            
            Spacer()
            
            Rectangle()
                .fill(Color(white: isProminent ? 0.6 : 0.3))
                .frame(width: isProminent ? 5 : 3.5, height: 1)
        }
        .frame(width: slotWidth)
        .position(x: slotWidth / 2, y: y)
    }
}
