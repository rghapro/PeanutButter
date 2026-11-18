import SwiftUI
import AVFoundation

/// Full-screen Pad Player UI modeled directly on MultiTracks Playback (Photo 1 & Photo 2)
public struct PadPlayerView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var padPlayer: PadPlayerEngine
    @ObservedObject private var padLibrary = PadLibraryManager.shared
    
    @State private var isPadsPopoverPresented: Bool = false
    @State private var isUploadingPad: Bool = false
    
    // Key layout order matching MultiTracks Playback exactly (2 rows x 6 columns)
    private let topRowKeys = ["Db", "Eb", "Gb", "Ab", "Bb", "B"]
    private let bottomRowKeys = ["C", "D", "E", "F", "G", "A"]
    
    public init(engine: MultitrackAudioEngine) {
        self.engine = engine
        self._padPlayer = ObservedObject(wrappedValue: engine.padPlayer)
    }
    
    private var displayedPack: PadSoundPack {
        let targetId = (padPlayer.isPlaying ? padPlayer.activePackId : nil) ?? engine.manualPadPackId ?? engine.currentSong.padPresetId ?? padPlayer.activePackId ?? padLibrary.activePackId
        return padLibrary.availablePacks.first(where: { $0.id == targetId }) ?? padLibrary.activePack
    }
    
    private var padBus: AudioBus? {
        engine.busses.first(where: { $0.name.lowercased() == "pad" })
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // 1. Left Dedicated Pad Channel Strip (Photo 1)
            padChannelStrip
                .frame(width: 76)
                .background(Color(red: 0.08, green: 0.09, blue: 0.10))
            
            Divider()
                .background(Color(white: 0.18))
            
            // 2. Main Pad Player Center Grid
            VStack(spacing: 14) {
                Spacer(minLength: 10)
                
                // Top Header Row: Active Pad Card (Columns 1-5) & LINK Button (Column 6)
                GeometryReader { geo in
                    let totalWidth = min(geo.size.width - 40, 780)
                    let spacing: CGFloat = 10
                    let colWidth = (totalWidth - (spacing * 5)) / 6
                    let cardWidth = (colWidth * 5) + (spacing * 4)
                    
                    VStack(spacing: 12) {
                        HStack(spacing: spacing) {
                            // Active Pad Pack Display Button
                            Button(action: {
                                isPadsPopoverPresented = true
                            }) {
                                HStack(spacing: 10) {
                                    // Artwork thumbnail
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color(red: 0.35, green: 0.25, blue: 0.55),
                                                        Color(red: 0.15, green: 0.45, blue: 0.65)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 32, height: 32)
                                        
                                        Image(systemName: "waveform.badge.magnifyingglass")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.85))
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayedPack.name)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(displayedPack.subtitle)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundColor(Color(white: 0.55))
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(white: 0.45))
                                }
                                .padding(.horizontal, 10)
                                .frame(width: cardWidth, height: 42)
                                .background(Color(white: 0.13))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color(white: 0.20), lineWidth: engine.isAutomationHighlightActive ? 1.2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $isPadsPopoverPresented, arrowEdge: .trailing) {
                                AmbientPadsPopoverView(
                                    engine: engine,
                                    padLibrary: padLibrary,
                                    onDismiss: { isPadsPopoverPresented = false }
                                )
                            }
                            
                            // LINK Button
                            Button(action: {
                                engine.togglePadLink()
                                if engine.isEditAutomationMode {
                                    engine.recordAutomationPadLinked(engine.isPadLinked)
                                }
                            }) {
                                Text("LINK")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundColor(engine.isPadLinked ? Color(red: 0.25, green: 0.90, blue: 0.45) : Color.white.opacity(0.40))
                                    .frame(width: colWidth, height: 42)
                                    .background(Color(white: 0.13))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : (engine.isPadLinked ? Color(red: 0.25, green: 0.90, blue: 0.45).opacity(0.8) : Color(white: 0.20)), lineWidth: engine.isAutomationHighlightActive ? 1.2 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Toggle Pad Link")
                        }
                        .frame(width: totalWidth)
                        
                        // 12 Keys Grid (2 rows x 6 columns)
                        VStack(spacing: spacing) {
                            // Row 1: Db, Eb, Gb, Ab, Bb, B
                            HStack(spacing: spacing) {
                                ForEach(topRowKeys, id: \.self) { key in
                                    padKeyButton(key: key, width: colWidth)
                                }
                            }
                            .frame(width: totalWidth)
                            
                            // Row 2: C, D, E, F, G, A
                            HStack(spacing: spacing) {
                                ForEach(bottomRowKeys, id: \.self) { key in
                                    padKeyButton(key: key, width: colWidth)
                                }
                            }
                            .frame(width: totalWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                
                Spacer(minLength: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        }
    }
    
    // MARK: - Key Square Button
    
    private func padKeyButton(key: String, width: CGFloat) -> some View {
        let isCurrentKey = (engine.currentPadKey == key)
        let isActive = engine.isPadActive && isCurrentKey
        
        return Button(action: {
            if engine.isPadActive && isCurrentKey {
                engine.stopPadPlayer()
                if engine.isEditAutomationMode {
                    engine.recordAutomationPadActive(false)
                }
            } else {
                engine.startPadPlayer(key: key)
                if engine.isEditAutomationMode {
                    engine.recordAutomationPadActive(true)
                    engine.recordAutomationPadKey(key)
                }
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Color(red: 0.16, green: 0.32, blue: 0.22) : Color(white: 0.13))
                
                Text(key)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isActive ? Color(red: 0.25, green: 0.95, blue: 0.50) : .white)
            }
            .frame(width: width, height: max(60, width * 0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : (isActive ? Color(red: 0.25, green: 0.90, blue: 0.45) : Color(white: 0.19)),
                        lineWidth: (engine.isAutomationHighlightActive || isActive) ? 1.4 : 1.0
                    )
            )
            .shadow(color: isActive ? Color.green.opacity(0.2) : Color.clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help("Play pad in key of \(key)")
    }
    
    // MARK: - Left Channel Strip
    
    private var padChannelStrip: some View {
        VStack(spacing: 8) {
            // Solo Button
            Button(action: {
                engine.padChannelSoloed.toggle()
                engine.updateMatrix()
            }) {
                ZStack {
                    Circle()
                        .fill(engine.padChannelSoloed ? Color(red: 0.98, green: 0.72, blue: 0.12) : Color(white: 0.18))
                        .frame(width: 24, height: 24)
                    
                    Text("S")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(engine.padChannelSoloed ? .black : Color(white: 0.6))
                }
            }
            .buttonStyle(.plain)
            .help("Solo Pad Channel")
            
            // Pan Slider
            PanBalanceControlView(
                pan: Binding(
                    get: { engine.padChannelPan },
                    set: { newVal in
                        engine.padChannelPan = newVal
                        engine.updateMatrix()
                    }
                ),
                isAutomationMode: engine.isAutomationHighlightActive,
                onCommit: {
                    if engine.isEditAutomationMode {
                        engine.recordAutomationPadPan(engine.padChannelPan)
                    }
                }
            )
            .frame(width: 60)
            
            // Fader Area
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let capHeight: CGFloat = 34
                let capWidth: CGFloat = 42
                let travel = max(10, slotHeight - capHeight)
                let volume = CGFloat(engine.padChannelVolume)
                let currentY = (1.0 - volume) * travel + (capHeight / 2)
                let slotWidth = capWidth + 18
                
                ZStack {
                    // Center Groove
                    Rectangle()
                        .fill(Color(white: 0.06))
                        .frame(width: 3, height: slotHeight)
                    
                    // Ticks
                    faderTicks(slotHeight: slotHeight)
                        .drawingGroup()
                    
                    // Stereo VU Meter LED bars (driven by padPlayer.meter)
                    StereoVUMeterPairView(meter: engine.padPlayer.meter, isMuted: engine.padChannelMuted)
                        .frame(width: 14, height: slotHeight - 8)
                        .allowsHitTesting(false)
                    
                    // Fader Cap (matches rest of the app)
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
                                    .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color(white: 0.38), lineWidth: engine.isAutomationHighlightActive ? 1.2 : 0.7)
                            )
                            .shadow(color: Color.black.opacity(0.7), radius: 3, x: 0, y: 2)
                        
                        Rectangle()
                            .fill(engine.padChannelMuted ? Color(white: 0.38) : Color.white)
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .position(x: slotWidth / 2, y: currentY)
                    .onTapGesture(count: 2) {
                        engine.padChannelVolume = 0.80
                        engine.updateMatrix()
                        if engine.isEditAutomationMode {
                            engine.recordAutomationPadVolume(engine.padChannelVolume)
                        }
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
                            engine.padChannelVolume = max(0.0, min(1.0, norm))
                            engine.updateMatrix()
                        }
                        .onEnded { _ in
                            if engine.isEditAutomationMode {
                                engine.recordAutomationPadVolume(engine.padChannelVolume)
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Bottom Label: "Pad ▸" (Click to Mute/Unmute — white when active, greyed out when muted)
            let anySoloed = engine.tracks.contains(where: { $0.isSoloed }) || engine.padChannelSoloed
            let isEffectivelyMuted = anySoloed ? !engine.padChannelSoloed : engine.padChannelMuted
            let padTitleColor = isEffectivelyMuted ? Color(white: 0.38) : Color.white
            Button(action: {
                engine.padChannelMuted.toggle()
                engine.updateMatrix()
                if engine.isEditAutomationMode {
                    engine.recordAutomationPadMuted(engine.padChannelMuted)
                }
            }) {
                HStack(spacing: 3) {
                    Text("Pad")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(padTitleColor)
                    
                    Image(systemName: "play.fill")
                        .font(.system(size: 7))
                        .foregroundColor(isEffectivelyMuted ? Color(white: 0.32) : Color(white: 0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color.clear, lineWidth: 1.0)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(engine.padChannelMuted ? "Unmute Pad" : "Mute Pad")
            .frame(height: 22)
            .padding(.bottom, 6)
        }
        .padding(.top, 10)
    }
    
    private func faderTicks(slotHeight: CGFloat) -> some View {
        VStack {
            ForEach(0..<9) { _ in
                HStack {
                    Rectangle().fill(Color(white: 0.22)).frame(width: 4, height: 1)
                    Spacer()
                    Rectangle().fill(Color(white: 0.22)).frame(width: 4, height: 1)
                }
                .frame(width: 52)
                Spacer()
            }
        }
        .padding(.vertical, 14)
    }
}

/// Popover for selecting and uploading ambient pad sound packs (Photo 2)
public struct AmbientPadsPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var padLibrary: PadLibraryManager
    @ObservedObject var padPlayer: PadPlayerEngine
    let onDismiss: () -> Void
    
    @State private var hoveredPackId: String? = nil
    @State private var pendingDeletePack: PadSoundPack? = nil
    
    public init(engine: MultitrackAudioEngine, padLibrary: PadLibraryManager, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.padLibrary = padLibrary
        self.padPlayer = engine.padPlayer
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header: Cancel (left), Ambient Pads (center), Upload (right)
            HStack {
                Button(action: onDismiss) {
                    Text("Cancel")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Ambient Pads")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    padLibrary.promptUploadPadPack { success in
                        if success {
                            engine.padPlayer.reloadCurrentKey(packId: padLibrary.activePackId)
                        }
                    }
                }) {
                    Text("Upload")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(white: 0.12))
            
            Divider()
                .background(Color(white: 0.20))
            
            // Section: DOWNLOADED
            VStack(alignment: .leading, spacing: 8) {
                Text("DOWNLOADED")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                
                ScrollView {
                    let activeDisplayedId = (engine.padPlayer.isPlaying ? engine.padPlayer.activePackId : nil) ?? engine.manualPadPackId ?? engine.currentSong.padPresetId ?? engine.padPlayer.activePackId ?? padLibrary.activePackId
                    VStack(spacing: 2) {
                        ForEach(padLibrary.availablePacks) { pack in
                            let isSelected = (pack.id == activeDisplayedId)
                            
                            Button(action: {
                                engine.selectManualPadPack(id: pack.id)
                                if engine.isEditAutomationMode {
                                    engine.recordAutomationPadPackId(pack.id)
                                }
                            }) {
                                HStack(spacing: 10) {
                                    // Pack artwork / icon
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color(red: 0.40, green: 0.30, blue: 0.60),
                                                        Color(red: 0.20, green: 0.50, blue: 0.70)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 34, height: 34)
                                        
                                        Image(systemName: "waveform")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.85))
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text(pack.subtitle)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(Color(white: 0.50))
                                    }
                                    
                                    Spacer()
                                    
                                    if !pack.isBundled && hoveredPackId == pack.id {
                                        Button(action: {
                                            pendingDeletePack = pack
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11.5))
                                                .foregroundColor(Color(red: 0.96, green: 0.35, blue: 0.35))
                                                .padding(4)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Delete Pad Pack...")
                                    }
                                    
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                                            .padding(.trailing, 4)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.white.opacity(0.06) : (hoveredPackId == pack.id ? Color.white.opacity(0.03) : Color.clear))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering {
                                    hoveredPackId = pack.id
                                } else if hoveredPackId == pack.id {
                                    hoveredPackId = nil
                                }
                            }
                            .contextMenu {
                                if !pack.isBundled {
                                    Button("Delete Pad Pack...", role: .destructive) {
                                        pendingDeletePack = pack
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                
                Divider()
                    .background(Color(white: 0.18))
                
                // Fade In / Fade Out Duration Controls (4.6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("FADE TIMING")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(Color(white: 0.45))
                    
                    VStack(spacing: 4) {
                        HStack {
                            Text("Fade In")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Text(String(format: "%.1fs", padPlayer.fadeInSeconds))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                        }
                        Slider(value: $padPlayer.fadeInSeconds, in: 1.0...10.0, step: 0.5)
                            .controlSize(.mini)
                    }
                    
                    VStack(spacing: 4) {
                        HStack {
                            Text("Fade Out")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Text(String(format: "%.1fs", padPlayer.fadeOutSeconds))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                        }
                        Slider(value: $padPlayer.fadeOutSeconds, in: 1.0...10.0, step: 0.5)
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Divider()
                    .background(Color(white: 0.18))
                
                // Add / Upload Pad Pack Button
                Button(action: {
                    padLibrary.promptUploadPadPack { success in
                        if success {
                            engine.padPlayer.reloadCurrentKey(packId: padLibrary.activePackId)
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                        
                        Text("Upload Custom Pad Sound...")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.95))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 290, height: 455)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        .cornerRadius(10)
        .alert("Delete Pad Pack?", isPresented: Binding(
            get: { pendingDeletePack != nil },
            set: { if !$0 { pendingDeletePack = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pack = pendingDeletePack {
                    let wasActive = (engine.padPlayer.activePackId == pack.id) || (engine.currentSong.padPresetId == pack.id)
                    padLibrary.deletePack(id: pack.id)
                    if wasActive {
                        if engine.currentSongIndex >= 0 && engine.currentSongIndex < engine.currentSetlist.songs.count {
                            engine.updateSongPadPreset(at: engine.currentSongIndex, presetId: "simple")
                        }
                        engine.padPlayer.reloadCurrentKey(packId: "simple")
                    }
                    pendingDeletePack = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePack = nil
            }
        } message: {
            if let pack = pendingDeletePack {
                Text("Are you sure you want to delete \"\(pack.name)\"? This removes the custom pad files from disk.")
            }
        }
    }
}
