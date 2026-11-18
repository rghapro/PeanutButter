import SwiftUI

/// Right-hand control sidebar and Master output strip from MultiTracks Playback
public struct MasterMixerControlView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var midiManager = MIDIMappingManager.shared
    @ObservedObject private var keyboardManager = KeyboardMappingManager.shared
    let onOpenBussesSheet: () -> Void
    let onTogglePadPlayer: () -> Void
    
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42
    
    public init(
        engine: MultitrackAudioEngine,
        onOpenBussesSheet: @escaping () -> Void,
        onTogglePadPlayer: @escaping () -> Void
    ) {
        self.engine = engine
        self.onOpenBussesSheet = onOpenBussesSheet
        self.onTogglePadPlayer = onTogglePadPlayer
    }
    
    public var body: some View {
        HStack(spacing: 6) {
            // 1. Vertical Action Toolbar (Mixer, Buses, Pad Player, Mute MIDI, Loop, Link)
            VStack(spacing: 10) {
                // Tracks / Mixer Mode Button
                MIDIMappableButton(targetId: "faders_button", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.mixerMode = .tracks
                    }
                }) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(engine.mixerMode == .tracks ? .white : Color(white: 0.55))
                        .frame(width: 54, height: 42)
                        .background(Color(white: 0.15))
                        .cornerRadius(4)
                }
                .help("Track Faders Mode")
                
                // BUSES Mode Button (Swaps mixer to the 16 Busses)
                MIDIMappableButton(targetId: "buses_button", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.mixerMode = (engine.mixerMode == .busses ? .tracks : .busses)
                    }
                }) {
                    Text("BUSES")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(engine.mixerMode == .busses ? .white : Color(white: 0.55))
                        .frame(width: 54, height: 42)
                        .background(Color(white: 0.15))
                        .cornerRadius(4)
                }
                .help("Busses Mode (Click to toggle bus faders, right click/menu for routing)")
                .contextMenu {
                    Button("Configure Busses & Physical Outputs...") {
                        onOpenBussesSheet()
                    }
                }
                
                // PAD PLAYER button
                MIDIMappableButton(targetId: "pad_player_button", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.mixerMode = (engine.mixerMode == .padPlayer ? .tracks : .padPlayer)
                    }
                }) {
                    VStack(spacing: 1.5) {
                        Text("PAD")
                            .font(.system(size: 10, weight: .black))
                        Text("PLAYER")
                            .font(.system(size: 9, weight: .black))
                    }
                    .foregroundColor(engine.mixerMode == .padPlayer ? .white : Color(white: 0.55))
                    .frame(width: 54, height: 42)
                    .background(Color(white: 0.15))
                    .cornerRadius(4)
                }
                .help("Toggle Pad Player View")
                
                // MUTE MIDI button
                MIDIMappableButton(targetId: "mute_midi", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    engine.isMIDIMuted.toggle()
                    if engine.isEditAutomationMode {
                        engine.recordCurrentAutomationPointValues()
                    }
                }) {
                    VStack(spacing: 1.5) {
                        Text("MUTE")
                            .font(.system(size: 10, weight: .black))
                        Text("MIDI")
                            .font(.system(size: 9, weight: .black))
                    }
                    .foregroundColor(engine.isMIDIMuted ? Color.red : Color(white: 0.55))
                    .frame(width: 54, height: 42)
                    .background(engine.isMIDIMuted ? Color.red.opacity(0.22) : Color(white: 0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : (engine.isMIDIMuted ? Color.red : Color.clear), lineWidth: engine.isAutomationHighlightActive ? 1.2 : 1.5)
                    )
                    .cornerRadius(4)
                }
                .help("Mute all outgoing MIDI cues")
                
                // Single Loop Button (1x)
                MIDIMappableButton(targetId: "toggle_single_loop", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    engine.toggleSingleLoop()
                }) {
                    ZStack {
                        Image(systemName: "repeat")
                            .font(.system(size: 14, weight: .bold))
                            .offset(x: -6)
                        
                        Text("1x")
                            .font(.system(size: 10.5, weight: .black, design: .monospaced))
                            .offset(x: 10, y: -3)
                    }
                    .foregroundColor(engine.isLoopActive && engine.loopMode == .single ? .white : Color(white: 0.55))
                    .frame(width: 54, height: 42)
                    .background(Color(white: 0.15))
                    .cornerRadius(4)
                }
                .help("Single Loop Section (1x) - Hotkey: L")
                
                // Infinite Loop Button (∞)
                MIDIMappableButton(targetId: "toggle_infinite_loop", isMappingMode: engine.isEditMIDIMappingMode, action: {
                    engine.toggleInfiniteLoop()
                }) {
                    ZStack {
                        Image(systemName: "repeat")
                            .font(.system(size: 14, weight: .bold))
                            .offset(x: -6)
                        
                        Image(systemName: "infinity")
                            .font(.system(size: 12, weight: .bold))
                            .offset(x: 10, y: -3)
                    }
                    .foregroundColor(engine.isLoopActive && engine.loopMode == .infinite ? .white : Color(white: 0.55))
                    .frame(width: 54, height: 42)
                    .background(Color(white: 0.15))
                    .cornerRadius(4)
                }
                .help("Infinite Loop Section (∞) - Hotkey: I")
                
                Spacer()
            }
            .frame(width: 54)
            .padding(.top, 8)
            .padding(.bottom, 14)
            
            // 2. Master Channel Strip
            VStack(spacing: 8) {
                // Fader Slot with Real VU Meter and Dynamic Full-Height Travel
                GeometryReader { faderGeo in
                    let slotHeight = faderGeo.size.height
                    let travel = max(10, slotHeight - capHeight)
                    let currentY = (1.0 - CGFloat(engine.masterVolume)) * travel + (capHeight / 2)
                    let slotWidth = capWidth + 18
                    let isMIDIMasterMapping = engine.isEditMIDIMappingMode
                    let isKeyboardMasterMapping = engine.isEditKeyboardMappingMode
                    let isMasterMapping = isMIDIMasterMapping || isKeyboardMasterMapping
                    let isMasterSelected = isMasterMapping && (isKeyboardMasterMapping ? keyboardManager.selectedTargetId == "master_fader" : midiManager.selectedTargetId == "master_fader")
                    let masterMappingBadge = isKeyboardMasterMapping ? keyboardManager.mapping(for: "master_fader")?.displayString : midiManager.mapping(for: "master_fader")?.displayString
                    let masterFill = isMasterSelected ? Color.white : (isKeyboardMasterMapping ? Color(red: 0.50, green: 0.25, blue: 0.08) : Color(red: 0.16, green: 0.28, blue: 0.42))
                    let masterStroke = isMasterSelected ? Color.white : (isKeyboardMasterMapping ? Color(red: 0.95, green: 0.52, blue: 0.15) : Color(red: 0.28, green: 0.50, blue: 0.75))
                    
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            // Background for MIDI or Keyboard mapping mode
                            if isMasterMapping {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(masterFill)
                            }
                            
                            // Background Center Slot Groove
                            Rectangle()
                                .fill(Color(white: 0.06))
                                .frame(width: 3, height: slotHeight)
                            
                            // Master dB Tick Marks (0 dB at 0.80)
                            masterTickMarksView(slotHeight: slotHeight)
                            
                            // Real Live Master Stereo VU Meters (isolated from MasterMixerControlView re-renders)
                            StereoVUMeterPairView(meter: engine.masterMeter)
                                .frame(width: capWidth + 8, height: slotHeight)
                            
                            // Tactile Master Fader Cap
                            ZStack {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color(white: 0.36),
                                                Color(white: 0.22),
                                                Color(white: 0.15)
                                            ]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: capWidth, height: capHeight)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(Color(white: 0.42), lineWidth: 0.7)
                                    )
                                    .shadow(color: Color.black.opacity(0.7), radius: 3, x: 0, y: 2)
                                
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: capWidth - 6, height: 2)
                            }
                            .position(x: slotWidth / 2, y: currentY)
                            .onTapGesture(count: 2) {
                                if !isMasterMapping {
                                    engine.masterVolume = 0.80 // 0 dB unity
                                }
                            }
                        }
                        .frame(width: slotWidth, height: slotHeight)
                        .overlay(
                            Group {
                                if isMasterMapping {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(masterStroke, lineWidth: 1.5)
                                }
                            }
                        )
                        .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isMasterMapping {
                                if isKeyboardMasterMapping {
                                    keyboardManager.selectTarget("master_fader")
                                } else {
                                    midiManager.selectTarget("master_fader")
                                }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if isMasterMapping {
                                        if isKeyboardMasterMapping {
                                            keyboardManager.selectTarget("master_fader")
                                        } else {
                                            midiManager.selectTarget("master_fader")
                                        }
                                    } else {
                                        let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                                        let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                                        engine.masterVolume = max(0.0, min(1.0, norm))
                                    }
                                }
                        )
                        
                        if isMasterMapping, let badge = masterMappingBadge, !isMasterSelected {
                            MIDIMappingBadgeView(text: badge)
                                .offset(x: 4, y: -6)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Track Label
                Text("Master")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(white: 0.85))
                    .frame(width: 76, height: 20)
            }
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .background(Color(red: 0.09, green: 0.10, blue: 0.11))
            .cornerRadius(4)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(red: 0.08, green: 0.09, blue: 0.10))
    }
    
    private func masterTickMarksView(slotHeight: CGFloat) -> some View {
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
