import SwiftUI

/// Lightweight GPU-composited Stereo VU Meter that observes only `StereoMeterModel` inside an
/// isolated inner view and scales a static bottom-anchored mask instead of re-rasterizing Canvas paths.
public struct StereoVUMeterPairView: View {
    let meter: StereoMeterModel
    var isMuted: Bool = false

    fileprivate static let meterGradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 0.15, green: 0.85, blue: 0.35), location: 0.0),
            .init(color: Color(red: 0.95, green: 0.85, blue: 0.15), location: 0.75),
            .init(color: Color(red: 0.95, green: 0.25, blue: 0.15), location: 0.95)
        ]),
        startPoint: .bottom,
        endPoint: .top
    )

    public init(meter: StereoMeterModel, isMuted: Bool = false) {
        self.meter = meter
        self.isMuted = isMuted
    }

    public var body: some View {
        GeometryReader { geo in
            let barHeight = max(1.0, geo.size.height - 4.0)
            let barWidth: CGFloat = 3.0
            let bgColor = Color(white: 0.08)

            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(bgColor)
                    StereoVUMeterChannelBar(meter: meter, isRightChannel: false, isMuted: isMuted, width: barWidth, height: barHeight)
                }
                .frame(width: barWidth, height: barHeight)

                Spacer(minLength: 0)

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(bgColor)
                    StereoVUMeterChannelBar(meter: meter, isRightChannel: true, isMuted: isMuted, width: barWidth, height: barHeight)
                }
                .frame(width: barWidth, height: barHeight)
            }
            .padding(.top, 2.0)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

private struct StereoVUMeterChannelBar: View {
    @ObservedObject var meter: StereoMeterModel
    let isRightChannel: Bool
    let isMuted: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let lvl = isMuted ? 0.0 : CGFloat(max(0.0, min(1.0, isRightChannel ? meter.right : meter.left)))
        RoundedRectangle(cornerRadius: 1.5)
            .fill(StereoVUMeterPairView.meterGradient)
            .frame(width: width, height: height)
            .opacity(lvl > 0.002 ? 1.0 : 0.0)
            .mask(alignment: .bottom) {
                Rectangle()
                    .frame(width: width, height: height)
                    .scaleEffect(x: 1.0, y: max(0.0001, lvl), anchor: .bottom)
            }
    }
}

/// High-precision VUMeterBar for authentic audio level metering
public struct VUMeterBar: View {
    let level: Float

    public init(level: Float) {
        self.level = level
    }

    public var body: some View {
        let clamped = max(0.0, min(1.0, CGFloat(level)))
        ZStack(alignment: .bottom) {
            // Background meter track
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(white: 0.08))

            // Active bouncing level (static full-height gradient revealed by GPU-scaled mask)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(StereoVUMeterPairView.meterGradient)
                .opacity(clamped > 0.002 ? 1.0 : 0.0)
                .mask(alignment: .bottom) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(x: 1.0, y: max(0.0001, clamped), anchor: .bottom)
                    }
                }
        }
    }
}

private struct TrackFaderCapView: View {
    @ObservedObject var faderDisplay: FaderDisplayModel
    let travel: CGFloat
    let slotWidth: CGFloat
    let capWidth: CGFloat
    let capHeight: CGFloat
    let isClick: Bool
    let isEffectivelyDimmed: Bool
    let isMapping: Bool
    let onDoubleTapReset: () -> Void

    var body: some View {
        let currentY = (1.0 - CGFloat(faderDisplay.normalizedPosition)) * travel + (capHeight / 2)
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

            // Center Alignment Line (MultiTracks cyan line on Click fader, white on others; dims when muted)
            Rectangle()
                .fill(isClick ? Color(red: 0.25, green: 0.75, blue: 0.95) : Color.white)
                .opacity(isEffectivelyDimmed ? 0.35 : 1.0)
                .frame(width: capWidth - 6, height: 2)
        }
        .drawingGroup() // Cache fader cap gradient + shadow as a Metal GPU texture
        .position(x: slotWidth / 2, y: currentY)
        .onTapGesture(count: 2) {
            if !isMapping {
                onDoubleTapReset()
            }
        }
    }
}

/// Authentic MultiTracks Playback channel strip matching the exact layout and sleek styling of Playback
public struct ChannelStripView: View {
    @ObservedObject var track: StemTrack
    @ObservedObject private var midiManager = MIDIMappingManager.shared
    @ObservedObject private var keyboardManager = KeyboardMappingManager.shared
    @ObservedObject var engine: MultitrackAudioEngine
    let index: Int
    var isBeingDragged: Bool = false
    let onParametersChanged: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovering: Bool = false
    @State private var isLongPressed: Bool = false
    @State private var isShowingClickOptions: Bool = false
    @State private var isShowingGuideOptions: Bool = false
    
    // Fader calibration: 0.0 = -inf, 0.80 = 0.0 dB (unity), 1.0 = +6.0 dB
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42
    public var isInTray: Bool = false
    
    private var isClick: Bool {
        track.role == .click || StemCategory.category(for: track.name, role: track.role) == .click
    }
    
    private var isGuide: Bool {
        track.role == .guide || StemCategory.category(for: track.name, role: track.role) == .guide
    }
    
    private var displayedTrackName: String {
        if isClick {
            return "Click"
        }
        if isGuide {
            return "Guide"
        }
        return StemCategory.abbreviatedName(for: track.name, role: track.role)
    }
    
    private var isBusMuted: Bool {
        engine.busses.first(where: { $0.name.caseInsensitiveCompare(track.assignedBusName) == .orderedSame })?.isMuted ?? false
    }
    
    private var isEffectivelyDimmed: Bool {
        let anySoloed = engine.tracks.contains(where: { $0.isSoloed }) || engine.padChannelSoloed
        if anySoloed {
            return !(track.isSoloed || (track.isSoloSafe && !track.isMuted && !isBusMuted))
        }
        return track.isMuted || isBusMuted
    }

    private var trackNameColor: Color {
        if isLongPressed { return Color.cyan }
        let isMapping = engine.isEditMIDIMappingMode || engine.isEditKeyboardMappingMode
        if !isMapping && (engine.isAutomationHighlightActive || engine.isTrackAutomated(track.id)) {
            let green = Color(red: 0.25, green: 0.88, blue: 0.45)
            return isEffectivelyDimmed ? green.opacity(0.38) : green
        }
        return isEffectivelyDimmed ? Color(white: 0.38) : Color.white
    }
    
    public init(
        track: StemTrack,
        engine: MultitrackAudioEngine,
        index: Int,
        isBeingDragged: Bool = false,
        isInTray: Bool = false,
        onParametersChanged: @escaping () -> Void,
        onDelete: @escaping () -> Void = {}
    ) {
        self.track = track
        self.engine = engine
        self.index = index
        self.isBeingDragged = isBeingDragged
        self.isInTray = isInTray
        self.onParametersChanged = onParametersChanged
        self.onDelete = onDelete
    }
    
    public var body: some View {
        let isMIDIMapping = engine.isEditMIDIMappingMode
        let isKeyboardMapping = engine.isEditKeyboardMappingMode
        let isMapping = isMIDIMapping || isKeyboardMapping
        let soloTarget = "track_solo_\(track.id.uuidString)"
        let faderTarget = "track_fader_\(track.id.uuidString)"
        let muteTarget = "track_mute_\(track.id.uuidString)"
        let isFaderSelected = isMapping && (isKeyboardMapping ? keyboardManager.selectedTargetId == faderTarget : midiManager.selectedTargetId == faderTarget)
        let faderMappingBadge = isKeyboardMapping ? keyboardManager.mapping(for: faderTarget)?.displayString : midiManager.mapping(for: faderTarget)?.displayString
        
        let mappingFill = isFaderSelected ? Color.white : (isKeyboardMapping ? Color(red: 0.50, green: 0.25, blue: 0.08) : Color(red: 0.16, green: 0.28, blue: 0.42))
        let mappingStroke = isFaderSelected ? Color.white : (isKeyboardMapping ? Color(red: 0.95, green: 0.52, blue: 0.15) : Color(red: 0.28, green: 0.50, blue: 0.75))
        
        return VStack(spacing: 8) {
            // 1. Solo Button (Circular 'S')
            MIDIMappableButton(
                targetId: soloTarget,
                isMappingMode: isMapping,
                cornerRadius: 12,
                badgeOffset: CGPoint(x: 8, y: -6),
                action: {
                    if NSEvent.modifierFlags.contains(.command) {
                        track.isSoloSafe.toggle()
                    } else {
                        track.isSoloed.toggle()
                    }
                    onParametersChanged()
                }
            ) {
                ZStack {
                    Circle()
                        .fill(track.isSoloed ? Color(red: 0.98, green: 0.72, blue: 0.12) : (isMapping ? Color.clear : Color(white: 0.18)))
                        .frame(width: 24, height: 24)
                    
                    if track.isSoloSafe {
                        Circle()
                            .stroke(Color(red: 0.98, green: 0.72, blue: 0.12), lineWidth: 2.0)
                            .frame(width: 24, height: 24)
                    }
                    
                    Text("S")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(track.isSoloed ? .black : (track.isSoloSafe ? Color(red: 0.98, green: 0.72, blue: 0.12) : Color(white: 0.6)))
                }
            }
            .help("Solo Track (CMD+Click for Solo Safe)")
            
            // 2. Pan / Balance Control
            PanBalanceControlView(
                pan: Binding(
                    get: { track.pan },
                    set: {
                        track.pan = $0
                        engine.updateSingleTrackGain(track)
                    }
                ),
                isAutomationMode: engine.isAutomationHighlightActive,
                onCommit: onParametersChanged
            )
            
            // 4. Fader Slot with Real VU Meter and Dynamic Full-Height Travel
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let travel = max(10, slotHeight - capHeight)
                let slotWidth = capWidth + 18
                
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        // Background for MIDI or Keyboard mapping mode
                        if isMapping {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(mappingFill)
                        }
                        
                        // Background Center Slot Groove
                        Rectangle()
                            .fill(isInTray ? Color(white: 0.12) : Color(white: 0.06))
                            .frame(width: 3, height: slotHeight)
                        
                        // Tick Marks at Standard Console dB Intervals (0 dB at 0.80)
                        faderTickMarksView(slotHeight: slotHeight)
                            .drawingGroup()
                        
                        // Real Live Audio VU Meters on the sides of the track (isolated from ChannelStripView re-renders)
                        StereoVUMeterPairView(meter: track.meter, isMuted: track.isMuted || isBusMuted)
                            .frame(width: capWidth + 8, height: slotHeight)
                        
                        // Tactile Fader Cap Positioned via Isolated FaderDisplayModel
                        TrackFaderCapView(
                            faderDisplay: track.faderDisplay,
                            travel: travel,
                            slotWidth: slotWidth,
                            capWidth: capWidth,
                            capHeight: capHeight,
                            isClick: isClick,
                            isEffectivelyDimmed: isEffectivelyDimmed,
                            isMapping: isMapping,
                            onDoubleTapReset: {
                                // Double-click resets to default level (100% or 0 dB)
                                track.volume = engine.defaultChannelFaderLevel
                                onParametersChanged()
                            }
                        )
                    }
                    .frame(width: slotWidth, height: slotHeight)
                    .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
                    .contentShape(Rectangle())
                    .overlay(
                        Group {
                            if isMapping {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(mappingStroke, lineWidth: 1.5)
                            } else if engine.isAutomationHighlightActive {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(red: 0.25, green: 0.88, blue: 0.45), lineWidth: 1.2)
                            }
                        }
                    )
                    .onTapGesture {
                        if isMapping {
                            if isKeyboardMapping {
                                keyboardManager.selectTarget(faderTarget)
                            } else {
                                midiManager.selectTarget(faderTarget)
                            }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if isMapping {
                                    if isKeyboardMapping {
                                        keyboardManager.selectTarget(faderTarget)
                                    } else {
                                        midiManager.selectTarget(faderTarget)
                                    }
                                } else {
                                    let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                                    let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                                    track.setLiveVolume(max(0.0, min(1.0, norm)), forceDisplay: true)
                                    engine.updateSingleTrackGain(track)
                                }
                            }
                            .onEnded { _ in
                                if !isMapping {
                                    onParametersChanged()
                                }
                            }
                    )
                    
                    if isMapping, let badge = faderMappingBadge, !isFaderSelected {
                        MIDIMappingBadgeView(text: badge)
                            .offset(x: 4, y: -6)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 4. Track Name Label (Clicking mutes track) + Separated Click/Guide Options Button (>= 36x36 hit target)
            HStack(spacing: 4) {
                MIDIMappableButton(
                    targetId: muteTarget,
                    isMappingMode: isMapping,
                    cornerRadius: 4,
                    badgeOffset: CGPoint(x: 6, y: -6),
                    action: {
                        track.isMuted.toggle()
                        onParametersChanged()
                    }
                ) {
                    ZStack {
                        if !isMapping {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isLongPressed ? Color.cyan.opacity(0.35) : (isHovering ? Color(white: 0.16) : Color.clear))
                        }
                        
                        Text(displayedTrackName)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(trackNameColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentShape(Rectangle())
                        .padding(.horizontal, 3)
                    }
                    .frame(width: (isClick || isGuide) && !isMapping ? 42 : 76, height: 24)
                }
                
                if (isClick || isGuide) && !isMapping {
                    Button(action: {
                        if isClick { isShowingClickOptions = true }
                        else if isGuide { isShowingGuideOptions = true }
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.72))
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(white: 0.22).opacity(0.65))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isClick ? "Click Options" : "Guide Options")
                    .popover(isPresented: isClick ? $isShowingClickOptions : $isShowingGuideOptions, arrowEdge: .top) {
                        if isClick {
                            ClickOptionsPopoverView(engine: engine) {
                                isShowingClickOptions = false
                            }
                        } else {
                            GuideOptionsPopoverView(engine: engine) {
                                isShowingGuideOptions = false
                            }
                        }
                    }
                }
            }
            .frame(width: 82, height: 36)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25)
                    .onEnded { _ in
                        isLongPressed = true
                    }
            )
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(isInTray ? Color(red: 0.17, green: 0.18, blue: 0.20) : Color(red: 0.10, green: 0.11, blue: 0.12))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isBeingDragged ? Color.cyan : (isLongPressed ? Color.cyan.opacity(0.7) : Color.clear), lineWidth: 2)
        )
        .opacity(isBeingDragged ? 0.35 : 1.0)
        .scaleEffect(isBeingDragged ? 0.95 : (isLongPressed ? 1.03 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isBeingDragged)
        .animation(.easeInOut(duration: 0.15), value: isLongPressed)
        .overlay(
            ZStack(alignment: .trailing) {
                // Subtle 1px right border divider
                Rectangle()
                    .fill(Color(white: 0.16))
                    .frame(width: 1)
                
                // Click Subdivisions Drawer Toggle Arrow (matching Photo 1 & 2)
                if isClick {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.20)) {
                            engine.isClickSubdivisionDrawerExpanded.toggle()
                        }
                    }) {
                        Image(systemName: engine.isClickSubdivisionDrawerExpanded ? "chevron.left" : "chevron.right")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(Color(white: 0.50))
                            .frame(width: 12, height: 26)
                            .background(Color(red: 0.10, green: 0.11, blue: 0.12).opacity(0.85))
                            .cornerRadius(2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5)
                    .help(engine.isClickSubdivisionDrawerExpanded ? "Collapse Click Subdivisions" : "Expand Click Subdivisions")
                }
            },
            alignment: .trailing
        )
        .onHover { hovering in
            isHovering = hovering
            if !hovering && !isBeingDragged {
                isLongPressed = false
            }
        }
    }
    
    // MARK: - Tick Marks Component
    
    private func faderTickMarksView(slotHeight: CGFloat) -> some View {
        let travel = max(10, slotHeight - capHeight)
        let slotWidth = capWidth + 18
        
        return ZStack {
            // +6 dB mark (top)
            tickMarkRow(y: capHeight / 2, label: nil)
            
            // 0 dB mark (unity gain at norm 0.80)
            tickMarkRow(y: (1.0 - 0.80) * travel + (capHeight / 2), isProminent: true)
            
            // -6 dB mark (norm ~0.56)
            tickMarkRow(y: (1.0 - 0.56) * travel + (capHeight / 2), label: nil)
            
            // -12 dB mark (norm ~0.40)
            tickMarkRow(y: (1.0 - 0.40) * travel + (capHeight / 2), label: nil)
            
            // -24 dB mark (norm ~0.20)
            tickMarkRow(y: (1.0 - 0.20) * travel + (capHeight / 2), label: nil)
            
            // -∞ dB mark (bottom)
            tickMarkRow(y: travel + (capHeight / 2), label: nil)
        }
        .frame(width: slotWidth, height: slotHeight)
        .drawingGroup() // Flatten 12 tick mark shapes into a single cached GPU texture
    }
    
    private func tickMarkRow(y: CGFloat, isProminent: Bool = false, label: String? = nil) -> some View {
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

/// Blank channel strip placeholder shown when opening to an empty session (matching Playback)
public struct EmptyFaderStripPlaceholderView: View {
    private let capHeight: CGFloat = 34
    private let capWidth: CGFloat = 42
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 8) {
            // Solo Button
            ZStack {
                Circle()
                    .fill(Color(white: 0.16))
                    .frame(width: 24, height: 24)
                Text("S")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(Color(white: 0.40))
            }
            
            // Mute Pill
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.14))
                    .frame(width: 44, height: 14)
                Rectangle()
                    .fill(Color(white: 0.30))
                    .frame(width: 18, height: 2)
            }
            
            // Pan Placeholder
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.10))
                .frame(width: 50, height: 12)
                .overlay(
                    Rectangle()
                        .fill(Color(white: 0.20))
                        .frame(width: 1, height: 8)
                )
            
            // Dynamic Fader Slot with Groove & Cap at bottom (-inf)
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let travel = max(10, slotHeight - capHeight)
                let capY = travel + (capHeight / 2)
                let slotWidth = capWidth + 18
                
                ZStack {
                    Rectangle()
                        .fill(Color(white: 0.06))
                        .frame(width: 3, height: slotHeight)
                    
                    // Tick marks
                    ZStack {
                        tickRow(y: capHeight / 2)
                        tickRow(y: (1.0 - 0.80) * travel + (capHeight / 2), isProminent: true)
                        tickRow(y: (1.0 - 0.56) * travel + (capHeight / 2))
                        tickRow(y: (1.0 - 0.40) * travel + (capHeight / 2))
                        tickRow(y: (1.0 - 0.20) * travel + (capHeight / 2))
                        tickRow(y: capY)
                    }
                    .frame(width: slotWidth, height: slotHeight)
                    
                    // Tactile Fader Cap parked at -inf
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(white: 0.25),
                                        Color(white: 0.16),
                                        Color(white: 0.12)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: capWidth, height: capHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(white: 0.28), lineWidth: 0.7)
                            )
                        
                        Rectangle()
                            .fill(Color(white: 0.60))
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .position(x: slotWidth / 2, y: capY)
                }
                .frame(width: slotWidth, height: slotHeight)
                .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Empty label spacer
            Text("")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 76, height: 20)
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color(red: 0.10, green: 0.11, blue: 0.12))
        .cornerRadius(4)
        .overlay(
            Rectangle()
                .fill(Color(white: 0.16))
                .frame(width: 1),
            alignment: .trailing
        )
    }
    
    private func tickRow(y: CGFloat, isProminent: Bool = false) -> some View {
        let slotWidth = capWidth + 18
        return HStack {
            Rectangle()
                .fill(Color(white: isProminent ? 0.45 : 0.25))
                .frame(width: isProminent ? 5 : 3.5, height: 1)
            Spacer()
            Rectangle()
                .fill(Color(white: isProminent ? 0.45 : 0.25))
                .frame(width: isProminent ? 5 : 3.5, height: 1)
        }
        .frame(width: slotWidth)
        .position(x: slotWidth / 2, y: y)
    }
}

// MARK: - Pan / Balance Control View

/// Sleek console pan/balance slider with center detent, text readout, and double-click reset
public struct PanBalanceControlView: View {
    @Binding var pan: Float // -1.0 (Left) to +1.0 (Right), 0.0 (Center)
    var isAutomationMode: Bool = false
    var onCommit: (() -> Void)? = nil
    @State private var lastClickTime: TimeInterval = 0
    
    private let controlWidth: CGFloat = 50
    private let controlHeight: CGFloat = 12
    
    public init(pan: Binding<Float>, isAutomationMode: Bool = false, onCommit: (() -> Void)? = nil) {
        self._pan = pan
        self.isAutomationMode = isAutomationMode
        self.onCommit = onCommit
    }
    
    public var body: some View {
        let clampedPan = max(-1.0, min(1.0, pan))
        let thumbX = CGFloat((clampedPan + 1.0) / 2.0) * (controlWidth - 8) + 4
        
        let panText: String = {
            if abs(clampedPan) < 0.05 {
                return "C"
            } else if clampedPan < 0 {
                return "L\(Int(abs(clampedPan) * 100))"
            } else {
                return "R\(Int(clampedPan * 100))"
            }
        }()
        
        ZStack {
            // Background track groove
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.12))
                .frame(width: controlWidth, height: controlHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(white: 0.22), lineWidth: 0.8)
                )
            
            // Center detent tick
            Rectangle()
                .fill(Color(white: 0.35))
                .frame(width: 1, height: controlHeight - 2)
            
            // Active pan indicator thumb
            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    abs(clampedPan) < 0.05 ?
                    Color(white: 0.85) :
                    Color(red: 0.20, green: 0.80, blue: 0.95)
                )
                .frame(width: 6, height: controlHeight - 2)
                .position(x: thumbX, y: controlHeight / 2)
            
            // Readout text overlay
            Text(panText)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
                .allowsHitTesting(false)
        }
        .frame(width: controlWidth, height: controlHeight)
        .contentShape(Rectangle())
        .overlay(
            Group {
                if isAutomationMode {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.25, green: 0.88, blue: 0.45), lineWidth: 1.2)
                }
            }
        )
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    pan = 0.0
                    onCommit?()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let now = Date().timeIntervalSince1970
                    if now - lastClickTime < 0.35 {
                        pan = 0.0
                        lastClickTime = 0
                        onCommit?()
                        return
                    }
                    let norm = max(0.0, min(1.0, value.location.x / controlWidth))
                    let rawPan = Float(norm * 2.0 - 1.0)
                    if abs(rawPan) < 0.08 {
                        pan = 0.0
                    } else {
                        pan = max(-1.0, min(1.0, rawPan))
                    }
                }
                .onEnded { _ in
                    lastClickTime = Date().timeIntervalSince1970
                    onCommit?()
                }
        )
        .onTapGesture(count: 2) {
            pan = 0.0
            onCommit?()
        }
        .help("Pan / Balance: \(panText) (Double-click to center)")
    }
}
