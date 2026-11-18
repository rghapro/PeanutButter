import SwiftUI
import AppKit

/// AppKit view that installs a local event monitor for reliable 2-finger horizontal trackpad scrolling
struct TrackpadScrollWheelReceiver: NSViewRepresentable {
    let onScrollDeltaX: (CGFloat) -> Void
    
    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScrollDeltaX = onScrollDeltaX
        return view
    }
    
    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScrollDeltaX = onScrollDeltaX
    }
    
    final class ScrollWheelNSView: NSView {
        var onScrollDeltaX: ((CGFloat) -> Void)?
        private var monitor: Any?
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            // NEVER consume mouse clicks! Allow all clicks to pass directly through to SwiftUI buttons beneath.
            return nil
        }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self = self, self.window != nil else { return event }
                    let loc = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(loc) {
                        let dx = event.scrollingDeltaX
                        if abs(dx) > 0.05 {
                            self.onScrollDeltaX?(dx)
                            return nil // Consumed
                        }
                    }
                    return event
                }
            }
        }
        
        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Pixel-perfect upward triangle whose apex is mathematically at rect.midX
struct UpwardTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Authentic MultiTracks Playback Timeline with Pre-Rendered High-Def Waveform, Crisp Beat Grid, and Pinch-to-Zoom
public struct WaveformTimelineView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var midiEngine = MIDICueEngine.shared
    let clock: TransportClockModel
    
    let aggregateWaveform: [Float]
    let sections: [SongSection]
    let totalDuration: TimeInterval
    let bpm: Double
    let timeSignatureNumerator: Int
    let isLoopActive: Bool
    let loopedSection: SongSection?
    var isStationary: Bool = false
    
    let onSeek: (TimeInterval) -> Void
    let onToggleSectionLoop: (SongSection) -> Void
    
    // Section Add Popover Index (-2 for playhead, -1 for beginning, >= 0 for section index)
    @State private var activeAddPopoverIndex: Int? = nil
    @State private var activePopoverSection: SongSection?
    
    // Trim Mode Handle Tracking (anchors Cancel/Apply popout to last interacted handle)
    enum TrimHandleSide { case left, right }
    @State private var trimActiveHandleSide: TrimHandleSide = .left
    
    // MIDI Cue Section Copy/Paste Popover
    @State private var activeMIDICueSection: SongSection? = nil
    
    // MIDI Cue Add / Edit Popover State
    @State private var isAddingMIDICueAtPlayhead: Bool = false
    @State private var editingMIDICue: MIDICue? = nil
    
    // Directional Cue Add / Edit Popover State
    @State private var isAddingDirectionalCueAtPlayhead: Bool = false
    @State private var editingDirectionalCue: DirectionalCue? = nil
    
    // Automation Add / Edit Popover State
    @State private var isAddingAutomationAtPlayhead: Bool = false
    @State private var editingAutomationPoint: AutomationPoint? = nil
    
    // Time Signature Change Badge Popover State
    @State private var editingTimeSignatureChange: TimeSignatureChange? = nil
    
    // SMPTE Add / Edit Popover State
    @State private var isAddingSMPTECueAtPlayhead: Bool = false
    @State private var editingSMPTECue: SMPTECue? = nil
    
    // Cue Mouse Drag-and-Drop State (4.1)
    @State private var draggingCueId: UUID? = nil
    @State private var isDraggingSMPTECue: Bool = false
    @State private var draggingCuePreviewTime: TimeInterval? = nil
    @State private var draggingCueStartTime: TimeInterval? = nil
    
    // Scrubbing drag state
    @State private var isScrubbing: Bool = false
    @State private var scrubStartTime: TimeInterval = 0.0
    @State private var scrubAccumulatedDelta: CGFloat = 0.0
    
    // Two-finger scroll tracking state
    @State private var trackpadScrollAccumulator: CGFloat = 0.0
    @State private var snapTimer: Timer?
    @State private var userPlayingScrollOffset: CGFloat = 0.0
    @State private var frozenScrollTime: TimeInterval? = nil
    @State private var lastDragTranslation: CGFloat = 0.0
    @State private var autoSnapTimer: Timer? = nil
    
    // Smooth paused waveform scrolling & landing state
    @State private var userStoppedScrollOffset: CGFloat = 0.0
    @State private var stoppedScrollBaseTime: TimeInterval? = nil
    @State private var isStoppedScrolling: Bool = false
    @State private var lockedStationaryTime: TimeInterval? = nil
    @State private var snapCommitWorkItem: DispatchWorkItem? = nil
    @State private var gridTileCache = BeatGridTileCache()
    
    private func scheduleAutoSnapTimer() {
        autoSnapTimer?.invalidate()
        // If a section is queued to play next, do NOT snap back! Keep the view focused there until it plays.
        guard engine.queuedNextSection == nil else { return }
        autoSnapTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                if engine.playbackState == .playing && engine.queuedNextSection == nil {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        frozenScrollTime = nil
                        userPlayingScrollOffset = 0.0
                    }
                    engine.browsedSectionStartTime = nil
                }
            }
        }
    }
    
    // Fixed playhead anchor position from left edge
    private let playheadAnchorX: CGFloat = 36.0
    // Base measure width in pixels (69% scale readjusted as 100% default: 90 * 0.69 = 62.1px)
    private let baseMeasureWidth: CGFloat = 62.1
    
    public init(
        engine: MultitrackAudioEngine,
        clock: TransportClockModel,
        aggregateWaveform: [Float],
        sections: [SongSection],
        totalDuration: TimeInterval,
        bpm: Double,
        timeSignatureNumerator: Int,
        isLoopActive: Bool,
        loopedSection: SongSection?,
        isStationary: Bool = false,
        onSeek: @escaping (TimeInterval) -> Void,
        onToggleSectionLoop: @escaping (SongSection) -> Void
    ) {
        self.engine = engine
        self.clock = clock
        self.aggregateWaveform = aggregateWaveform
        self.sections = sections
        self.totalDuration = totalDuration
        self.bpm = bpm
        self.timeSignatureNumerator = timeSignatureNumerator
        self.isLoopActive = isLoopActive
        self.loopedSection = loopedSection
        self.isStationary = isStationary
        self.onSeek = onSeek
        self.onToggleSectionLoop = onToggleSectionLoop
    }

    private func computeClampedDisplayTime(rawTime: TimeInterval, effectiveDuration: TimeInterval) -> TimeInterval {
        max(0.0, min(effectiveDuration > 0 ? effectiveDuration : 300, rawTime))
    }

    private func computeBaseScrollTime(clampedDisplayTime: TimeInterval, isEditTimeline: Bool) -> TimeInterval {
        let rawBaseScrollTime: TimeInterval = {
            if isStationary, let locked = lockedStationaryTime {
                return locked
            }
            if engine.playbackState == .playing, let frozen = frozenScrollTime {
                return frozen
            }
            if engine.playbackState != .playing, let stoppedBase = stoppedScrollBaseTime {
                return stoppedBase
            }
            return clampedDisplayTime
        }()
        return isEditTimeline ? engine.displayTimeForSongPosition(rawBaseScrollTime) : rawBaseScrollTime
    }

    private func computeScrollX(displayTime: TimeInterval, pixelsPerSecond: CGFloat, effectiveDuration: TimeInterval, isEditTimeline: Bool) -> CGFloat {
        let clamped = computeClampedDisplayTime(rawTime: displayTime, effectiveDuration: effectiveDuration)
        let baseScroll = computeBaseScrollTime(clampedDisplayTime: clamped, isEditTimeline: isEditTimeline)
        return playheadAnchorX - (CGFloat(baseScroll) * pixelsPerSecond) + (isStationary ? 0 : (engine.playbackState == .playing ? userPlayingScrollOffset : userStoppedScrollOffset))
    }
    
    public var body: some View {
        GeometryReader { geo in
            let zoomScale = engine.waveformZoomScale
            // Time-based timeline: pixelsPerSecond scales with zoom, allowing the grid size to dynamically reflect song tempo
            let basePixelsPerSecond: CGFloat = baseMeasureWidth / 2.0 // 31.05 px/sec (calibrated so a 120 BPM 4/4 bar is 62.1px at 1.0x zoom)
            let pixelsPerSecond = basePixelsPerSecond * zoomScale
            let secPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, engine.currentSong.timeSignatureDenominator)))
            let secPerMeasure = max(0.25, secPerBeat * Double(max(1, timeSignatureNumerator)))
            let isEditTimeline = engine.isEditingArrangement
            let effectiveDuration: TimeInterval = {
                if isEditTimeline {
                    let baseMax = engine.displaySections.map { $0.endTime }.max() ?? 0.0
                    return baseMax > 0 ? baseMax : totalDuration
                }
                return totalDuration
            }()
            let totalContentWidth = max(geo.size.width * 2, CGFloat(max(effectiveDuration, 60.0)) * pixelsPerSecond + 1200)
            let waveformWidth = CGFloat(max(effectiveDuration, 1.0)) * pixelsPerSecond
            
            let isBlankSession = engine.tracks.isEmpty || effectiveDuration <= 0
            let liveSections = isEditTimeline ? engine.displaySections : (engine.currentSong.sections.isEmpty ? sections : engine.currentSong.sections)
            let visibleMIDICues = engine.currentSong.midiCues.filter { !midiEngine.disabledBuses.contains($0.bus) }
            let dynamicGrid = engine.cachedEffectiveBeatGrid.isEmpty ? engine.currentSong.effectiveBeatGrid(totalDuration: effectiveDuration) : engine.cachedEffectiveBeatGrid
            let gridKey = BeatGridTileCache.CacheKey(
                songId: engine.currentSong.id,
                waveformWidth: waveformWidth,
                height: max(100.0, geo.size.height - 22.0),
                secPerMeasure: secPerMeasure,
                pixelsPerSecond: pixelsPerSecond,
                beatsPerMeasure: timeSignatureNumerator,
                bpm: engine.currentSong.bpm,
                beatGridCount: dynamicGrid.count,
                firstMarkerTime: dynamicGrid.first?.time ?? -1.0,
                lastMarkerTime: dynamicGrid.last?.time ?? -1.0
            )
            let laneHeight: CGFloat = 22.0
            let waveformHeight = max(100.0, geo.size.height - laneHeight)
            let midY = waveformHeight * 0.50
            let badgeY = geo.size.height - 44.0
            let leadPlusX: CGFloat = 18.0
            let currentScrollXProvider: () -> CGFloat = {
                computeScrollX(
                    displayTime: clock.position.currentTime,
                    pixelsPerSecond: pixelsPerSecond,
                    effectiveDuration: effectiveDuration,
                    isEditTimeline: isEditTimeline
                )
            }
            let currentTimeProvider: () -> TimeInterval = {
                clock.position.currentTime
            }
            
            ZStack(alignment: .leading) {
                // 1. Dark Timeline Canvas Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.09))
                
                // 1b. Dedicated Cue Lane Background under waveform window
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(Color(red: 0.05, green: 0.06, blue: 0.07))
                        .frame(height: laneHeight)
                        .overlay(
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1),
                            alignment: .top
                        )
                }
                .allowsHitTesting(false)
                
                // Popover presenters (observe clock ONLY when a popover is actually open)
                TimelinePopoverAnchorsOverlay(
                    clock: clock,
                    engine: engine,
                    geoSize: geo.size,
                    midY: midY,
                    badgeY: badgeY,
                    leadPlusX: leadPlusX,
                    pixelsPerSecond: pixelsPerSecond,
                    liveSections: liveSections,
                    activeAddPopoverIndex: $activeAddPopoverIndex,
                    isAddingMIDICueAtPlayhead: $isAddingMIDICueAtPlayhead,
                    editingMIDICue: $editingMIDICue,
                    isAddingDirectionalCueAtPlayhead: $isAddingDirectionalCueAtPlayhead,
                    editingDirectionalCue: $editingDirectionalCue,
                    isAddingAutomationAtPlayhead: $isAddingAutomationAtPlayhead,
                    editingAutomationPoint: $editingAutomationPoint,
                    isAddingSMPTECueAtPlayhead: $isAddingSMPTECueAtPlayhead,
                    editingSMPTECue: $editingSMPTECue,
                    computePopoverRectWithScroll: { scrollX in
                        computePopoverRect(
                            liveSections: liveSections,
                            leadPlusX: leadPlusX,
                            scrollX: scrollX,
                            midY: midY,
                            pixelsPerSecond: pixelsPerSecond
                        )
                    },
                    scrollXForTime: { rawTime in
                        computeScrollX(
                            displayTime: rawTime,
                            pixelsPerSecond: pixelsPerSecond,
                            effectiveDuration: effectiveDuration,
                            isEditTimeline: isEditTimeline
                        )
                    }
                )
                
                if !isBlankSession {
                    trackpadScrollLayer(
                        pixelsPerSecond: pixelsPerSecond,
                        effectiveDuration: effectiveDuration,
                        currentTimeProvider: currentTimeProvider
                    )
                    
                    TimelinePlayheadScrollContainer(
                        clock: clock,
                        engine: engine,
                        gridTileCache: gridTileCache,
                        gridKey: gridKey,
                        waveformWidth: waveformWidth,
                        waveformHeight: waveformHeight,
                        viewportWidth: geo.size.width,
                        secPerMeasure: secPerMeasure,
                        pixelsPerSecond: pixelsPerSecond,
                        beatsPerMeasure: timeSignatureNumerator,
                        effectiveDuration: effectiveDuration,
                        playheadAnchorX: playheadAnchorX,
                        isEditTimeline: isEditTimeline,
                        isStationary: isStationary,
                        lockedStationaryTime: lockedStationaryTime,
                        frozenScrollTime: frozenScrollTime,
                        stoppedScrollBaseTime: stoppedScrollBaseTime,
                        userPlayingScrollOffset: userPlayingScrollOffset,
                        userStoppedScrollOffset: userStoppedScrollOffset,
                        scrollingStaticContent: scrollingStaticContentLayer(
                            geo: geo,
                            waveformWidth: waveformWidth,
                            totalContentWidth: totalContentWidth,
                            pixelsPerSecond: pixelsPerSecond,
                            liveSections: liveSections,
                            visibleMIDICues: visibleMIDICues,
                            leadPlusX: leadPlusX,
                            midY: midY,
                            currentScrollX: currentScrollXProvider,
                            currentPlaybackTime: currentTimeProvider
                        )
                    )
                    .simultaneousGesture(
                        (engine.isEditingArrangement || isStationary || draggingCueId != nil || isDraggingSMPTECue) ? nil :
                        DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                guard draggingCueId == nil && !isDraggingSMPTECue else { return }
                                if engine.playbackState == .playing {
                                    if frozenScrollTime == nil {
                                        frozenScrollTime = computeClampedDisplayTime(rawTime: currentTimeProvider(), effectiveDuration: effectiveDuration)
                                    }
                                    let delta = value.translation.width - lastDragTranslation
                                    userPlayingScrollOffset += delta
                                    lastDragTranslation = value.translation.width
                                    scheduleAutoSnapTimer()
                                } else {
                                    snapCommitWorkItem?.cancel()
                                    snapCommitWorkItem = nil
                                    if !isScrubbing {
                                        isScrubbing = true
                                        scrubStartTime = currentTimeProvider()
                                    }
                                    userStoppedScrollOffset = value.translation.width
                                }
                            }
                            .onEnded { value in
                                guard draggingCueId == nil && !isDraggingSMPTECue else { return }
                                if engine.playbackState == .playing {
                                    lastDragTranslation = 0.0
                                    scheduleAutoSnapTimer()
                                } else {
                                    isScrubbing = false
                                    let maxDuration = totalDuration > 0 ? totalDuration : 300.0
                                    let rawTarget = max(0.0, min(maxDuration, scrubStartTime - TimeInterval(value.translation.width / pixelsPerSecond)))
                                    let snappedTime = snapTimeToBeatGrid(rawTarget)
                                    let targetOffset = CGFloat(scrubStartTime - snappedTime) * pixelsPerSecond
                                    
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        userStoppedScrollOffset = targetOffset
                                    }
                                    
                                    snapCommitWorkItem?.cancel()
                                    let work = DispatchWorkItem {
                                        onSeek(snappedTime)
                                        userStoppedScrollOffset = 0.0
                                        scrubStartTime = snappedTime
                                        snapCommitWorkItem = nil
                                    }
                                    snapCommitWorkItem = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
                                }
                            }
                    )
                }
                
                fixedPlayheadLayer(
                    geoHeight: geo.size.height,
                    midY: midY,
                    isBlankSession: isBlankSession
                )
                .zIndex(100)
            }
            .coordinateSpace(name: "timelineViewport")
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard !isStationary else { return }
                        engine.waveformZoomScale = max(0.4, min(4.0, 1.0 * value))
                    }
            )
            .onChange(of: isStationary) { stationary in
                if stationary {
                    if lockedStationaryTime == nil {
                        let clamped = computeClampedDisplayTime(rawTime: clock.position.currentTime, effectiveDuration: effectiveDuration)
                        lockedStationaryTime = computeBaseScrollTime(clampedDisplayTime: clamped, isEditTimeline: isEditTimeline)
                    }
                } else {
                    lockedStationaryTime = nil
                }
            }
            .onAppear {
                if isStationary && lockedStationaryTime == nil {
                    let clamped = computeClampedDisplayTime(rawTime: clock.position.currentTime, effectiveDuration: effectiveDuration)
                    lockedStationaryTime = computeBaseScrollTime(clampedDisplayTime: clamped, isEditTimeline: isEditTimeline)
                }
            }
            .onChange(of: engine.trimmingSection?.id) { _ in
                trimActiveHandleSide = .left
            }
            .onChange(of: engine.requestedEditMIDICueId) { reqId in
                guard let id = reqId else { return }
                if let cue = engine.currentSong.midiCues.first(where: { $0.id == id }) {
                    isAddingMIDICueAtPlayhead = false
                    editingMIDICue = cue
                }
                engine.requestedEditMIDICueId = nil
            }
            .onChange(of: engine.isEditDrawerOpen) { isOpen in
                if !isOpen {
                    activeAddPopoverIndex = nil
                }
            }
            .onChange(of: engine.playbackState) { state in
                if state == .playing {
                    activeAddPopoverIndex = nil
                    userStoppedScrollOffset = 0.0
                    stoppedScrollBaseTime = nil
                    isStoppedScrolling = false
                } else {
                    frozenScrollTime = nil
                    userPlayingScrollOffset = 0.0
                    autoSnapTimer?.invalidate()
                    autoSnapTimer = nil
                    userStoppedScrollOffset = 0.0
                    stoppedScrollBaseTime = nil
                    isStoppedScrolling = false
                }
            }
            .onChange(of: engine.currentSongIndex) { _ in
                lockedStationaryTime = nil
                frozenScrollTime = nil
                userPlayingScrollOffset = 0.0
                userStoppedScrollOffset = 0.0
                stoppedScrollBaseTime = nil
                isStoppedScrolling = false
                autoSnapTimer?.invalidate()
                autoSnapTimer = nil
            }
            .onChange(of: engine.queuedNextSection?.id) { newId in
                if let queued = engine.queuedNextSection {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        frozenScrollTime = queued.startTime
                        userPlayingScrollOffset = 0.0
                    }
                } else if engine.playbackState == .playing {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        frozenScrollTime = nil
                        userPlayingScrollOffset = 0.0
                    }
                } else {
                    frozenScrollTime = nil
                    userPlayingScrollOffset = 0.0
                }
            }
            .onChange(of: engine.browsedSectionStartTime) { newTime in
                if let targetTime = newTime, engine.playbackState == .playing {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        frozenScrollTime = targetTime
                        userPlayingScrollOffset = 0.0
                    }
                    scheduleAutoSnapTimer()
                }
            }
            .onChange(of: engine.requestedEditDirectionalCueId) { reqId in
                guard let id = reqId else { return }
                if let cue = engine.currentSong.directionalCues.first(where: { $0.id == id }) {
                    isAddingDirectionalCueAtPlayhead = false
                    editingDirectionalCue = cue
                }
                engine.requestedEditDirectionalCueId = nil
            }
            .onChange(of: engine.requestedEditAutomationId) { reqId in
                guard let id = reqId else { return }
                if let pt = engine.currentSong.automationPoints.first(where: { $0.id == id }) {
                    isAddingAutomationAtPlayhead = false
                    editingAutomationPoint = pt
                }
                engine.requestedEditAutomationId = nil
            }
            .onChange(of: engine.requestedEditSMPTECue) { req in
                guard req else { return }
                if let cue = engine.currentSong.smpteCue {
                    isAddingSMPTECueAtPlayhead = false
                    editingSMPTECue = cue
                }
                engine.requestedEditSMPTECue = false
            }
        }
        .frame(minHeight: 220, maxHeight: 290)
    }
    
    // MARK: - Subview Helpers
    
    private func minusXForSection(startX: CGFloat, width: CGFloat) -> CGFloat {
        if width < 46 {
            return startX + max(10, width * 0.28)
        }
        return startX + 13
    }
    
    private func plusXForSection(startX: CGFloat, width: CGFloat) -> CGFloat {
        if width < 46 {
            return startX + min(width - 10, width * 0.72)
        }
        return startX + width - 13
    }
    
    private func computePopoverRect(
        liveSections: [SongSection],
        leadPlusX: CGFloat,
        scrollX: CGFloat,
        midY: CGFloat,
        pixelsPerSecond: CGFloat
    ) -> NSRect? {
        guard let activeIdx = activeAddPopoverIndex else { return nil }
        if activeIdx == -2 {
            return NSRect(x: playheadAnchorX - 14, y: midY - 14, width: 28, height: 28)
        } else if activeIdx == -1 {
            return NSRect(x: leadPlusX - 14, y: midY - 14, width: 28, height: 28)
        } else if activeIdx >= 0 && activeIdx < liveSections.count {
            let sec = liveSections[activeIdx]
            let startX = CGFloat(sec.startTime) * pixelsPerSecond
            let width = CGFloat(sec.duration) * pixelsPerSecond
            let plusX = plusXForSection(startX: startX, width: width)
            let targetX = plusX + scrollX
            return NSRect(x: targetX - 14, y: midY - 14, width: 28, height: 28)
        }
        return nil
    }
    
    /// Snaps an arbitrary timestamp to the nearest beat in `engine.currentSong.beatGrid` (if available) or fixed BPM grid
    private func snapTimeToBeatGrid(_ rawTime: TimeInterval) -> TimeInterval {
        let maxTime = totalDuration > 0 ? totalDuration : 300
        let clamped = max(0.0, min(maxTime, rawTime))
        let grid = engine.cachedEffectiveBeatGrid.isEmpty ? engine.currentSong.effectiveBeatGrid(totalDuration: maxTime) : engine.cachedEffectiveBeatGrid
        if !grid.isEmpty {
            var low = 0
            var high = grid.count - 1
            while low < high {
                let mid = (low + high) / 2
                if grid[mid].time < clamped {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            var bestTime = grid[low].time
            if low > 0 && abs(grid[low - 1].time - clamped) < abs(bestTime - clamped) {
                bestTime = grid[low - 1].time
            }
            return max(0.0, min(totalDuration > 0 ? totalDuration : 300, bestTime))
        }
        let beatDuration = max(0.1, (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, engine.currentSong.timeSignatureDenominator))))
        let snapped = round(clamped / beatDuration) * beatDuration
        return max(0.0, min(totalDuration > 0 ? totalDuration : 300, snapped))
    }
    
    private func trackpadScrollLayer(pixelsPerSecond: CGFloat, effectiveDuration: TimeInterval, currentTimeProvider: @escaping () -> TimeInterval) -> some View {
        TrackpadScrollWheelReceiver { deltaX in
            guard !isStationary else { return }
            if engine.playbackState == .playing {
                // Free waveform scrolling while song is playing without moving audio
                if frozenScrollTime == nil {
                    frozenScrollTime = computeClampedDisplayTime(rawTime: currentTimeProvider(), effectiveDuration: effectiveDuration)
                }
                userPlayingScrollOffset += deltaX
                scheduleAutoSnapTimer()
            } else {
                snapCommitWorkItem?.cancel()
                snapCommitWorkItem = nil
                if !isStoppedScrolling {
                    isStoppedScrolling = true
                    stoppedScrollBaseTime = currentTimeProvider()
                    userStoppedScrollOffset = 0.0
                }
                userStoppedScrollOffset += deltaX
                
                let maxDuration = totalDuration > 0 ? totalDuration : 300.0
                let base = stoppedScrollBaseTime ?? currentTimeProvider()
                let minOffset = -CGFloat(maxDuration - base) * pixelsPerSecond
                let maxOffset = CGFloat(base) * pixelsPerSecond
                userStoppedScrollOffset = min(maxOffset, max(minOffset, userStoppedScrollOffset))
                
                snapTimer?.invalidate()
                snapTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: false) { _ in
                    Task { @MainActor in
                        guard let baseTime = stoppedScrollBaseTime else {
                            isStoppedScrolling = false
                            userStoppedScrollOffset = 0.0
                            return
                        }
                        let rawTarget = max(0.0, min(maxDuration, baseTime - TimeInterval(userStoppedScrollOffset / pixelsPerSecond)))
                        let snappedTime = snapTimeToBeatGrid(rawTarget)
                        let targetOffset = CGFloat(baseTime - snappedTime) * pixelsPerSecond
                        
                        withAnimation(.easeOut(duration: 0.16)) {
                            userStoppedScrollOffset = targetOffset
                        }
                        
                        snapCommitWorkItem?.cancel()
                        let work = DispatchWorkItem {
                            onSeek(snappedTime)
                            userStoppedScrollOffset = 0.0
                            stoppedScrollBaseTime = nil
                            isStoppedScrolling = false
                            snapCommitWorkItem = nil
                        }
                        snapCommitWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
    
    @ViewBuilder
    private func scrollingStaticContentLayer(
        geo: GeometryProxy,
        waveformWidth: CGFloat,
        totalContentWidth: CGFloat,
        pixelsPerSecond: CGFloat,
        liveSections: [SongSection],
        visibleMIDICues: [MIDICue],
        leadPlusX: CGFloat,
        midY: CGFloat,
        currentScrollX: @escaping () -> CGFloat,
        currentPlaybackTime: @escaping () -> TimeInterval
    ) -> some View {
        let laneHeight: CGFloat = 22.0
        let waveformHeight = max(100.0, geo.size.height - laneHeight)
        
        ZStack(alignment: .topLeading) {
            // 1. Waveform & Centerline (confined to upper window above cue lane)
            waveformView(waveformWidth: waveformWidth, height: waveformHeight)
            
            // 2. Time Signature Badges in timeline coordinates (move natively with scroll offset)
            if !engine.currentSong.timeSignatureChanges.isEmpty {
                ForEach(engine.currentSong.timeSignatureChanges) { tsChange in
                    let dispTime: TimeInterval = {
                        if let sec = engine.currentSong.sections.first(where: {
                            tsChange.audioTime >= $0.sourceAudioStartTime - 0.01 &&
                            tsChange.audioTime <= $0.sourceAudioStartTime + $0.duration + 0.01
                        }) {
                            return sec.startTime + (tsChange.audioTime - sec.sourceAudioStartTime)
                        }
                        return tsChange.audioTime
                    }()
                    let badgeX = CGFloat(dispTime) * pixelsPerSecond
                    Button(action: {
                        editingTimeSignatureChange = tsChange
                    }) {
                        Text(tsChange.label)
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.30, green: 0.88, blue: 0.98))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .position(x: badgeX, y: 34)
                    .popover(item: Binding<TimeSignatureChange?>(
                        get: { editingTimeSignatureChange?.id == tsChange.id ? editingTimeSignatureChange : nil },
                        set: { if $0 == nil { editingTimeSignatureChange = nil } }
                    )) { item in
                        TimeSignatureChangeEditorPopover(
                            change: item,
                            onUpdate: { num, den in
                                engine.updateTimeSignatureChange(id: item.id, numerator: num, denominator: den)
                                editingTimeSignatureChange = nil
                            },
                            onDelete: {
                                engine.removeTimeSignatureChange(id: item.id)
                                editingTimeSignatureChange = nil
                            }
                        )
                    }
                    .zIndex(50)
                }
            }
            
            // 3. Sections Map with Text & Badges (confined to upper window above cue lane)
            EquatableView(content: TimelineSectionsLayerView(
                liveSections: liveSections,
                pixelsPerSecond: pixelsPerSecond,
                height: waveformHeight,
                isLoopActive: isLoopActive,
                loopedSectionId: loopedSection?.id,
                isEditMode: engine.isEditingArrangement,
                loopMode: engine.loopMode,
                queuedNextSectionId: engine.queuedNextSection?.id,
                preRollTargetSectionId: engine.preRollTargetSectionId,
                isBeatFlashing: engine.isBeatFlashing,
                isStationary: isStationary,
                bpm: bpm,
                engine: engine,
                activePopoverSection: $activePopoverSection,
                activeMIDICueSection: $activeMIDICueSection,
                onSeek: onSeek,
                onToggleSectionLoop: onToggleSectionLoop,
                onAddSectionAfter: { idx in
                    if activeAddPopoverIndex == idx {
                        activeAddPopoverIndex = nil
                    } else {
                        activeAddPopoverIndex = idx
                    }
                },
                onClearAutoSnap: {
                    autoSnapTimer?.invalidate()
                    autoSnapTimer = nil
                }
            ))
            
            // 4. Section Edit Markers (Displayed in Setlist / Song Map mode while stopped and not trimming)
            if (engine.isEditSongMapMode || (engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .setlistSongMap)) && engine.playbackState != .playing && engine.trimmingSection == nil {
                sectionEditMarkers(
                    liveSections: liveSections,
                    pixelsPerSecond: pixelsPerSecond,
                    leadPlusX: leadPlusX,
                    midY: midY
                )
            }
            
            // 5. Section Trim Mode Overlay (Yellow outline + drag handles)
            if let trimming = engine.trimmingSection {
                trimModeOverlay(
                    trimming: trimming,
                    liveSections: liveSections,
                    totalContentWidth: totalContentWidth,
                    pixelsPerSecond: pixelsPerSecond,
                    height: waveformHeight,
                    midY: midY
                )
            }
            
            // 6. Active Cue Vertical Guideline (Ends at the bottom of the shape)
            activeCueGuidelineLayer(
                pixelsPerSecond: pixelsPerSecond,
                totalHeight: geo.size.height,
                laneHeight: laneHeight
            )
            .zIndex(100)
            
            // 7. Cues in the Bottom Lane (Rendered ON TOP of the guideline shape)
            EquatableView(content: TimelineCuesLaneLayerView(
                automationPoints: engine.currentSong.automationPoints,
                directionalCues: engine.currentSong.directionalCues,
                smpteCue: engine.currentSong.smpteCue,
                midiCues: visibleMIDICues,
                liveSections: liveSections,
                pixelsPerSecond: pixelsPerSecond,
                totalHeight: geo.size.height,
                laneHeight: laneHeight,
                showSMPTECueOnLane: engine.isSMPTEEnabled || (engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte),
                isEditingArrangement: engine.isEditingArrangement,
                trimLeadingDuration: engine.trimLeadingDuration,
                trimTrailingDuration: engine.trimTrailingDuration,
                isEditAutomationMode: engine.isEditAutomationMode,
                isEditDirectionalCuesMode: engine.isEditDirectionalCuesMode,
                isEditMIDICuesMode: engine.isEditMIDICuesMode,
                isEditSMPTEMode: engine.isEditSMPTEMode,
                isEditDrawerOpen: engine.isEditDrawerOpen,
                selectedEditDrawerItem: engine.selectedEditDrawerItem,
                selectedAutomationPointId: engine.selectedAutomationPointId,
                selectedDirectionalCueId: engine.selectedDirectionalCueId,
                selectedMIDICueId: engine.selectedMIDICueId,
                engine: engine,
                isAddingAutomationAtPlayhead: $isAddingAutomationAtPlayhead,
                editingAutomationPoint: $editingAutomationPoint,
                isAddingDirectionalCueAtPlayhead: $isAddingDirectionalCueAtPlayhead,
                editingDirectionalCue: $editingDirectionalCue,
                isAddingSMPTECueAtPlayhead: $isAddingSMPTECueAtPlayhead,
                editingSMPTECue: $editingSMPTECue,
                isAddingMIDICueAtPlayhead: $isAddingMIDICueAtPlayhead,
                editingMIDICue: $editingMIDICue,
                draggingCueId: $draggingCueId,
                isDraggingSMPTECue: $isDraggingSMPTECue,
                draggingCuePreviewTime: $draggingCuePreviewTime,
                draggingCueStartTime: $draggingCueStartTime,
                viewportWidth: geo.size.width,
                totalDuration: totalDuration,
                isStationary: isStationary,
                currentScrollX: currentScrollX,
                currentTimeProvider: currentPlaybackTime,
                onSeek: onSeek
            ))
            .zIndex(150)
            
            // 8. ACTIVE CUE FLOATING PILL BADGE LAYER (RENDERED ABOVE EVERYTHING ELSE!)
            activeCueBadgeLayer(
                pixelsPerSecond: pixelsPerSecond,
                totalHeight: geo.size.height,
                waveformHeight: waveformHeight,
                currentScrollX: currentScrollX,
                currentTimeProvider: currentPlaybackTime,
                viewportWidth: geo.size.width
            )
            .zIndex(200)
        }
    }
    
    @ViewBuilder
    private func waveformView(waveformWidth: CGFloat, height: CGFloat) -> some View {
        if let img = engine.renderedWaveformImage {
            Image(nsImage: img)
                .resizable(resizingMode: .stretch)
                .frame(width: waveformWidth, height: height)
        } else if !aggregateWaveform.isEmpty {
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let midY = size.height * 0.50
                let maxH = size.height * 0.30 // Equal ~50pt margin above (for section pills) and below (for cues track)
                let count = aggregateWaveform.count
                let step = size.width / CGFloat(max(1, count - 1))
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                for i in 0..<count {
                    let x = CGFloat(i) * step
                    let peak = CGFloat(max(0.02, aggregateWaveform[i]))
                    path.addLine(to: CGPoint(x: x, y: midY - peak * maxH))
                }
                path.addLine(to: CGPoint(x: size.width, y: midY))
                for i in (0..<count).reversed() {
                    let x = CGFloat(i) * step
                    let peak = CGFloat(max(0.02, aggregateWaveform[i]))
                    path.addLine(to: CGPoint(x: x, y: midY + peak * maxH))
                }
                path.closeSubpath()
                context.fill(path, with: .color(Color(red: 0.82, green: 0.85, blue: 0.88).opacity(0.85)))
            }
            .frame(width: waveformWidth, height: height)
        }
        
        Path { p in
            let midY = height * 0.50
            p.move(to: CGPoint(x: 0, y: midY))
            p.addLine(to: CGPoint(x: waveformWidth, y: midY))
        }
        .stroke(Color.white.opacity(0.18), lineWidth: 1)
    }
    
    @ViewBuilder
    private func sectionEditMarkers(
        liveSections: [SongSection],
        pixelsPerSecond: CGFloat,
        leadPlusX: CGFloat,
        midY: CGFloat
    ) -> some View {
        if liveSections.isEmpty {
            Button(action: {
                if activeAddPopoverIndex == -1 {
                    activeAddPopoverIndex = nil
                } else {
                    activeAddPopoverIndex = -1
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.17, green: 0.19, blue: 0.22))
                        .frame(width: 20, height: 20)
                    Circle()
                        .stroke(Color(white: 0.38), lineWidth: 1.2)
                        .frame(width: 20, height: 20)
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: Color.black.opacity(0.5), radius: 2)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .offset(x: leadPlusX - 16, y: midY - 16)
            .help("Add Section at Beginning")
        }
        
        // Per-Section Minus & Plus Markers
        ForEach(Array(liveSections.enumerated()), id: \.element.id) { index, section in
            let startX = CGFloat(section.startTime) * pixelsPerSecond
            let width = CGFloat(section.duration) * pixelsPerSecond
            let leftTrimW = section.leadingTrimDuration > 0.001 ? CGFloat(section.leadingTrimDuration) * pixelsPerSecond : 0.0
            let rightTrimW = section.trailingTrimDuration > 0.001 ? CGFloat(section.trailingTrimDuration) * pixelsPerSecond : 0.0
            let activeStartX = startX + leftTrimW
            let activeWidth = max(20, width - leftTrimW - rightTrimW)
            
            // Narrow sections use the section's overflow (•••) popover instead of overlapping inline -/+ circles
            if activeWidth >= 58 {
            let minusX = minusXForSection(startX: activeStartX, width: activeWidth)
            let plusX = plusXForSection(startX: startX, width: width)
            let btnScale: CGFloat = activeWidth < 46 ? max(0.65, activeWidth / 46.0) : 1.0
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    engine.removeSection(at: index)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.98, green: 0.18, blue: 0.32))
                        .frame(width: 22 * btnScale, height: 22 * btnScale)
                    Circle()
                        .stroke(Color.white, lineWidth: 1.5 * btnScale)
                        .frame(width: 22 * btnScale, height: 22 * btnScale)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 10 * btnScale, height: 2.2 * btnScale)
                        .cornerRadius(1)
                }
                .shadow(color: Color.black.opacity(0.5), radius: 2)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .offset(x: minusX - 16, y: midY - 16)
            .help("Remove Section: \(section.name)")
            
            Button(action: {
                if activeAddPopoverIndex == index {
                    activeAddPopoverIndex = nil
                } else {
                    activeAddPopoverIndex = index
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.17, green: 0.19, blue: 0.22))
                        .frame(width: 20 * btnScale, height: 20 * btnScale)
                    Circle()
                        .stroke(Color(white: 0.38), lineWidth: 1.2 * btnScale)
                        .frame(width: 20 * btnScale, height: 20 * btnScale)
                    Image(systemName: "plus")
                        .font(.system(size: 9 * btnScale, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: Color.black.opacity(0.5), radius: 2)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .offset(x: plusX - 16, y: midY - 16)
            .help("Add Section After \(section.name)")
            }
        }
    }
    
    // MARK: - Trim Mode Interactive Overlay (Matching Image 2)
    
    @ViewBuilder
    private func trimModeOverlay(
        trimming: SongSection,
        liveSections: [SongSection],
        totalContentWidth: CGFloat,
        pixelsPerSecond: CGFloat,
        height: CGFloat,
        midY: CGFloat
    ) -> some View {
        let secStartX = CGFloat(trimming.startTime) * pixelsPerSecond
        let secWidth = CGFloat(trimming.baseDuration) * pixelsPerSecond
        let leftTrimW = CGFloat(engine.trimLeadingDuration) * pixelsPerSecond
        let rightTrimW = CGFloat(engine.trimTrailingDuration) * pixelsPerSecond
        let activeX = secStartX + leftTrimW
        let activeW = max(16, secWidth - leftTrimW - rightTrimW)
        
        // 1. Dim timeline canvas outside of the trimming section
        if secStartX > 0 {
            Rectangle()
                .fill(Color.black.opacity(0.62))
                .frame(width: max(0, secStartX), height: height)
                .allowsHitTesting(false)
        }
        let afterSecX = secStartX + secWidth
        if afterSecX < totalContentWidth + 1000 {
            Rectangle()
                .fill(Color.black.opacity(0.62))
                .frame(width: max(0, totalContentWidth - afterSecX + 1000), height: height)
                .offset(x: afterSecX)
                .allowsHitTesting(false)
        }
        
        // 2. Dim trimmed areas within section
        if leftTrimW > 0.5 {
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .frame(width: leftTrimW, height: height)
                .offset(x: secStartX)
                .allowsHitTesting(false)
        }
        if rightTrimW > 0.5 {
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .frame(width: rightTrimW, height: height)
                .offset(x: secStartX + secWidth - rightTrimW)
                .allowsHitTesting(false)
        }
        
        // 3. Bright Yellow Bounding Box around Active (Untrimmed) Region
        RoundedRectangle(cornerRadius: 3)
            .stroke(Color(red: 1.0, green: 0.85, blue: 0.0), lineWidth: 3)
            .frame(width: activeW, height: height)
            .offset(x: activeX)
            .allowsHitTesting(false)
        
        // 4. Left Drag Handle '<'
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 1.0, green: 0.85, blue: 0.0))
                .frame(width: 16, height: 44)
            Text("<")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.black)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 2)
        .offset(x: activeX - 8, y: midY - 22)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    trimActiveHandleSide = .left
                    let localBPM = engine.currentSong.instantaneousBPM(atSourceTime: trimming.baseAudioStartTime)
                    let (_, tsDen) = engine.currentSong.timeSignature(atSourceTime: trimming.baseAudioStartTime)
                    let secPerBeat = (60.0 / localBPM) * (4.0 / Double(max(1, tsDen)))
                    let pxPerBeat = CGFloat(secPerBeat) * pixelsPerSecond
                    let deltaBeats = round(Double(gesture.translation.width / pxPerBeat))
                    let baseBeats = Int(round(trimming.baseDuration / secPerBeat))
                    let currentTrailingBeats = Int(round(engine.trimTrailingDuration / secPerBeat))
                    let startLeadingBeats = Int(round(trimming.leadingTrimDuration / secPerBeat))
                    let maxLeadingBeats = max(0, baseBeats - currentTrailingBeats - 1)
                    let newLeadingBeats = max(0, min(maxLeadingBeats, startLeadingBeats + Int(deltaBeats)))
                    let newLeadDur = Double(newLeadingBeats) * secPerBeat
                    if abs(engine.trimLeadingDuration - newLeadDur) > 0.001 {
                        engine.trimLeadingDuration = newLeadDur
                    }
                }
        )
        
        // 5. Right Drag Handle '>'
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 1.0, green: 0.85, blue: 0.0))
                .frame(width: 16, height: 44)
            Text(">")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.black)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 2)
        .offset(x: activeX + activeW - 8, y: midY - 22)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    trimActiveHandleSide = .right
                    let endRefTime = trimming.baseAudioStartTime + max(0.0, trimming.baseDuration - 0.1)
                    let localBPM = engine.currentSong.instantaneousBPM(atSourceTime: endRefTime)
                    let (_, tsDen) = engine.currentSong.timeSignature(atSourceTime: endRefTime)
                    let secPerBeat = (60.0 / localBPM) * (4.0 / Double(max(1, tsDen)))
                    let pxPerBeat = CGFloat(secPerBeat) * pixelsPerSecond
                    let deltaBeats = round(Double(-gesture.translation.width / pxPerBeat))
                    let baseBeats = Int(round(trimming.baseDuration / secPerBeat))
                    let currentLeadingBeats = Int(round(engine.trimLeadingDuration / secPerBeat))
                    let startTrailingBeats = Int(round(trimming.trailingTrimDuration / secPerBeat))
                    let maxTrailingBeats = max(0, baseBeats - currentLeadingBeats - 1)
                    let newTrailingBeats = max(0, min(maxTrailingBeats, startTrailingBeats + Int(deltaBeats)))
                    let newTrailDur = Double(newTrailingBeats) * secPerBeat
                    if abs(engine.trimTrailingDuration - newTrailDur) > 0.001 {
                        engine.trimTrailingDuration = newTrailDur
                    }
                }
        )
        
        // 6. Floating Popout Menu (Cancel / Apply) pointing to whichever handle was last interacted with
        let bubbleWidth: CGFloat = 126
        let bubbleX = (trimActiveHandleSide == .left) ? (activeX - 6) : (activeX + activeW - bubbleWidth + 6)
        
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.cancelTrimming()
                    }
                }) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.applyTrimming()
                    }
                }) {
                    Text("Apply")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.18, green: 0.55, blue: 1.0))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(red: 0.14, green: 0.15, blue: 0.17))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.7), radius: 6, y: 3)
            
            // Pointer Caret
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 10, y: 0))
                p.addLine(to: CGPoint(x: 5, y: 6))
                p.closeSubpath()
            }
            .fill(Color(red: 0.14, green: 0.15, blue: 0.17))
            .frame(width: 10, height: 6)
            .offset(x: (trimActiveHandleSide == .left) ? -(bubbleWidth / 2 - 14) : (bubbleWidth / 2 - 14))
        }
        .offset(x: bubbleX, y: 12)
    }
    
    // MARK: - Active Cue Vertical Guideline Layer (Ends at the bottom of the shape)
    
    @ViewBuilder
    private func activeCueGuidelineLayer(
        pixelsPerSecond: CGFloat,
        totalHeight: CGFloat,
        laneHeight: CGFloat
    ) -> some View {
        let laneTop = totalHeight - laneHeight
        let upperShapeBottomY = laneTop + 10.0 // bottom edge of diamond / circle in upper row
        let lowerShapeBottomY = laneTop + 20.0 // bottom edge of upward triangle in lower row
        
        if engine.isEditDrawerOpen {
            switch engine.selectedEditDrawerItem {
            case .midiCues:
                if let cueId = engine.selectedMIDICueId,
                   let cue = engine.currentSong.midiCues.first(where: { $0.id == cueId }),
                   !midiEngine.disabledBuses.contains(cue.bus),
                   (!engine.isMIDICueTrimmedOut(cue) || engine.isEditingArrangement) {
                    let cueTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? engine.displayTime(forMIDICue: cue)
                    let cueX = CGFloat(cueTime) * pixelsPerSecond
                    let busColor = cue.bus.color
                    
                    Rectangle()
                        .fill(busColor)
                        .frame(width: 1.8, height: lowerShapeBottomY)
                        .shadow(color: Color.black.opacity(0.75), radius: 2)
                        .position(x: cueX, y: lowerShapeBottomY * 0.5)
                        .allowsHitTesting(false)
                }
                
            case .directionalCues:
                if let cueId = engine.selectedDirectionalCueId,
                   let cue = engine.currentSong.directionalCues.first(where: { $0.id == cueId }),
                   (!engine.isDirectionalCueTrimmedOut(cue) || engine.isEditingArrangement) {
                    let cueTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? engine.displayTime(forDirectionalCue: cue)
                    let cueX = CGFloat(cueTime) * pixelsPerSecond
                    let cyanColor = Color(red: 0.0, green: 0.85, blue: 0.98)
                    
                    Rectangle()
                        .fill(cyanColor)
                        .frame(width: 1.8, height: upperShapeBottomY)
                        .shadow(color: Color.black.opacity(0.75), radius: 2)
                        .position(x: cueX, y: upperShapeBottomY * 0.5)
                        .allowsHitTesting(false)
                }
                
            case .automation:
                if let ptId = engine.selectedAutomationPointId,
                   let pt = engine.currentSong.automationPoints.first(where: { $0.id == ptId }),
                   (!engine.isAutomationPointTrimmedOut(pt) || engine.isEditingArrangement) {
                    let cueTime = (draggingCueId == pt.id ? draggingCuePreviewTime : nil) ?? engine.displayTime(forAutomationPoint: pt)
                    let cueX = CGFloat(cueTime) * pixelsPerSecond
                    let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                    
                    Rectangle()
                        .fill(greenColor)
                        .frame(width: 1.8, height: upperShapeBottomY)
                        .shadow(color: Color.black.opacity(0.75), radius: 2)
                        .position(x: cueX, y: upperShapeBottomY * 0.5)
                        .allowsHitTesting(false)
                }
                
            case .smpte:
                if let cue = engine.currentSong.smpteCue {
                    let cueTime = (isDraggingSMPTECue ? draggingCuePreviewTime : nil) ?? cue.time
                    let cueX = CGFloat(cueTime) * pixelsPerSecond
                    let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                    
                    Rectangle()
                        .fill(greenColor)
                        .frame(width: 1.8, height: upperShapeBottomY)
                        .shadow(color: Color.black.opacity(0.75), radius: 2)
                        .position(x: cueX, y: upperShapeBottomY * 0.5)
                        .allowsHitTesting(false)
                }
                
            default:
                EmptyView()
            }
        }
    }
    
    // MARK: - Active Cue Floating Pill Badge Layer (Rendered ABOVE Everything Else)
    
    private func cueDragGesture(
        id: UUID? = nil,
        isSMPTE: Bool = false,
        baseTime: TimeInterval,
        pixelsPerSecond: CGFloat,
        currentScrollX: @escaping () -> CGFloat,
        currentTimeProvider: @escaping () -> TimeInterval,
        viewportWidth: CGFloat,
        onTap: @escaping () -> Void,
        onCommit: @escaping (TimeInterval) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineViewport"))
            .onChanged { value in
                guard !isStationary else { return }
                if draggingCueStartTime == nil {
                    draggingCueStartTime = baseTime
                    if isSMPTE {
                        isDraggingSMPTECue = true
                        draggingCueId = nil
                    } else {
                        draggingCueId = id
                        isDraggingSMPTECue = false
                    }
                }
                let dist = hypot(value.translation.width, value.translation.height)
                guard dist >= 3.0 || draggingCuePreviewTime != nil else { return }
                
                let scrollX = currentScrollX()
                let viewportX = value.location.x
                let rawTarget = TimeInterval((viewportX - scrollX) / max(1.0, pixelsPerSecond))
                draggingCuePreviewTime = snapTimeToBeatGrid(rawTarget)
                
                // Auto-pan waveform only when dragged to extreme left or right edge
                if engine.playbackState != .playing {
                    let curTime = currentTimeProvider()
                    let maxDur = totalDuration > 0 ? totalDuration : 300.0
                    if viewportX < 36 {
                        onSeek(max(0.0, curTime - 0.15))
                    } else if viewportX > viewportWidth - 36 {
                        onSeek(min(maxDur, curTime + 0.15))
                    }
                }
            }
            .onEnded { value in
                defer {
                    draggingCueId = nil
                    isDraggingSMPTECue = false
                    draggingCuePreviewTime = nil
                    draggingCueStartTime = nil
                }
                guard !isStationary else { return }
                if let snapped = draggingCuePreviewTime {
                    onCommit(snapped)
                } else {
                    onTap()
                }
            }
    }
    
    @ViewBuilder
    private func activeCueBadgeLayer(
        pixelsPerSecond: CGFloat,
        totalHeight: CGFloat,
        waveformHeight: CGFloat,
        currentScrollX: @escaping () -> CGFloat,
        currentTimeProvider: @escaping () -> TimeInterval,
        viewportWidth: CGFloat
    ) -> some View {
        let badgeY = totalHeight - 44.0
        
        if engine.isEditDrawerOpen {
            switch engine.selectedEditDrawerItem {
            case .midiCues:
                if let cueId = engine.selectedMIDICueId,
                   let cue = engine.currentSong.midiCues.first(where: { $0.id == cueId }),
                   !midiEngine.disabledBuses.contains(cue.bus),
                   (!engine.isMIDICueTrimmedOut(cue) || engine.isEditingArrangement) {
                    let baseTime = engine.displayTime(forMIDICue: cue)
                    let dispTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    let busColor = cue.bus.color
                    
                    // Floating interactive pill badge (4.3: clean text badge without shape icon)
                    Text(cue.pillBadgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.96))
                        )
                        .overlay(
                            Capsule()
                                .stroke(busColor, lineWidth: 1.5)
                        )
                        .shadow(color: Color.black.opacity(0.85), radius: 4, x: 0, y: 2)
                        .contentShape(Capsule())
                        .position(x: cueX, y: badgeY)
                        .highPriorityGesture(cueDragGesture(
                            id: cue.id,
                            baseTime: baseTime,
                            pixelsPerSecond: pixelsPerSecond,
                            currentScrollX: currentScrollX,
                            currentTimeProvider: currentTimeProvider,
                            viewportWidth: viewportWidth,
                            onTap: {
                                isAddingMIDICueAtPlayhead = false
                                editingMIDICue = cue
                            },
                            onCommit: { newTime in
                                engine.moveMIDICue(id: cue.id, toDisplayTime: newTime)
                            }
                        ))
                        .help("Click to Edit or Drag to Move MIDI Cue (\(cue.pillBadgeText))")
                }
                
            case .directionalCues:
                if let cueId = engine.selectedDirectionalCueId,
                   let cue = engine.currentSong.directionalCues.first(where: { $0.id == cueId }),
                   (!engine.isDirectionalCueTrimmedOut(cue) || engine.isEditingArrangement) {
                    let baseTime = engine.displayTime(forDirectionalCue: cue)
                    let dispTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    let cyanColor = Color(red: 0.0, green: 0.85, blue: 0.98)
                    
                    // Floating interactive pill badge (4.3: clean text badge without shape icon)
                    Text(cue.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(cyanColor)
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.92), lineWidth: 1.2)
                        )
                        .shadow(color: Color.black.opacity(0.85), radius: 4, x: 0, y: 2)
                        .contentShape(Capsule())
                        .position(x: cueX, y: badgeY)
                        .highPriorityGesture(cueDragGesture(
                            id: cue.id,
                            baseTime: baseTime,
                            pixelsPerSecond: pixelsPerSecond,
                            currentScrollX: currentScrollX,
                            currentTimeProvider: currentTimeProvider,
                            viewportWidth: viewportWidth,
                            onTap: {
                                isAddingDirectionalCueAtPlayhead = false
                                editingDirectionalCue = cue
                            },
                            onCommit: { newTime in
                                engine.moveDirectionalCue(id: cue.id, toDisplayTime: newTime)
                            }
                        ))
                        .help("Click to Edit or Drag to Move Directional Cue (\(cue.label))")
                }
                
            case .automation:
                if let ptId = engine.selectedAutomationPointId,
                   let pt = engine.currentSong.automationPoints.first(where: { $0.id == ptId }),
                   (!engine.isAutomationPointTrimmedOut(pt) || engine.isEditingArrangement) {
                    let baseTime = engine.displayTime(forAutomationPoint: pt)
                    let dispTime = (draggingCueId == pt.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                    
                    // Floating interactive pill badge (4.3: clean text badge without shape icon)
                    Text(pt.name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.08, green: 0.16, blue: 0.11).opacity(0.96))
                        )
                        .overlay(
                            Capsule()
                                .stroke(greenColor, lineWidth: 1.5)
                        )
                        .shadow(color: Color.black.opacity(0.85), radius: 4, x: 0, y: 2)
                        .contentShape(Capsule())
                        .position(x: cueX, y: badgeY)
                        .highPriorityGesture(cueDragGesture(
                            id: pt.id,
                            baseTime: baseTime,
                            pixelsPerSecond: pixelsPerSecond,
                            currentScrollX: currentScrollX,
                            currentTimeProvider: currentTimeProvider,
                            viewportWidth: viewportWidth,
                            onTap: {
                                isAddingAutomationAtPlayhead = false
                                engine.selectAutomationPoint(id: pt.id)
                                editingAutomationPoint = pt
                            },
                            onCommit: { newTime in
                                engine.moveAutomationPoint(id: pt.id, toDisplayTime: newTime)
                            }
                        ))
                        .help("Click to Edit or Drag to Move Automation (\(pt.name))")
                }
                
            case .smpte:
                if let cue = engine.currentSong.smpteCue {
                    let baseTime = cue.time
                    let dispTime = (isDraggingSMPTECue ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                    
                    // Floating interactive pill badge (4.3: clean text badge without shape icon)
                    Text("SMPTE \(cue.displayTimeStart)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(greenColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.08, green: 0.16, blue: 0.11).opacity(0.96))
                        )
                        .overlay(
                            Capsule()
                                .stroke(greenColor, lineWidth: 1.5)
                        )
                        .shadow(color: Color.black.opacity(0.85), radius: 4, x: 0, y: 2)
                        .contentShape(Capsule())
                        .position(x: cueX, y: badgeY)
                        .highPriorityGesture(cueDragGesture(
                            isSMPTE: true,
                            baseTime: baseTime,
                            pixelsPerSecond: pixelsPerSecond,
                            currentScrollX: currentScrollX,
                            currentTimeProvider: currentTimeProvider,
                            viewportWidth: viewportWidth,
                            onTap: {
                                isAddingSMPTECueAtPlayhead = false
                                editingSMPTECue = cue
                            },
                            onCommit: { newTime in
                                engine.moveSMPTECue(to: newTime, snapToGrid: false)
                            }
                        ))
                        .help("SMPTE Start: \(cue.displayTimeStart) (Click to Edit or Drag to Move)")
                }
                
            default:
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func fixedPlayheadLayer(
        geoHeight: CGFloat,
        midY: CGFloat,
        isBlankSession: Bool
    ) -> some View {
        let playheadX: CGFloat = playheadAnchorX
        
        ZStack(alignment: .topLeading) {
            // Playhead Vertical Line (Centered directly on playheadAnchorX and the grid)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geoHeight)
                    .shadow(color: Color.black.opacity(0.8), radius: 2)
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: 6, height: 16)
                    .shadow(color: Color.black.opacity(0.8), radius: 2)
            }
            .frame(width: 6, height: geoHeight)
            .position(x: playheadX, y: geoHeight * 0.5)
            .allowsHitTesting(false)
            
            // "Snap to Playhead" floating pill if user has scrolled away while playing
            if engine.playbackState == .playing && (frozenScrollTime != nil || abs(userPlayingScrollOffset) > 20) && engine.queuedNextSection == nil {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        frozenScrollTime = nil
                        userPlayingScrollOffset = 0.0
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .bold))
                        Text("Snap to Playhead")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.92))
                    .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(red: 0.28, green: 0.68, blue: 0.98).opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 3)
                }
                .buttonStyle(.plain)
                .offset(x: 14, y: geoHeight - 32)
            }
            
            // Playhead '+' Button centered on the playhead (visible in "Song Sections", "MIDI Cues", "Directional Cues", "Automation", or "SMPTE" mode - hidden in "Setlist / Song Map" mode)
            let isSMPTEActive = engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte
            let isSetlistSongMap = engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .setlistSongMap
            if !isBlankSession && !isSetlistSongMap && (engine.isEditSectionsMode || engine.isEditSongMapMode || engine.isEditMIDICuesMode || engine.isEditDirectionalCuesMode || engine.isEditAutomationMode || isSMPTEActive) {
                Button(action: {
                    triggerAddAtPlayhead()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.17, green: 0.19, blue: 0.22))
                            .frame(width: 22, height: 22)
                        Circle()
                            .stroke(Color(white: 0.44), lineWidth: 1.2)
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: Color.black.opacity(0.7), radius: 2)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .offset(x: playheadAnchorX - 14, y: midY - 14)
                .onTapGesture {
                    triggerAddAtPlayhead()
                }
                .help(engine.isEditMIDICuesMode ? "Add MIDI Cue at Playhead Position" : (engine.isEditDirectionalCuesMode ? "Add Directional Cue at Playhead Position" : (engine.isEditAutomationMode ? "Add Automation at Playhead Position" : (engine.isEditSMPTEMode ? "Add / Move SMPTE Cue at Playhead Position" : "Add / Label Song Section at Playhead Position"))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func triggerAddAtPlayhead() {
        NSLog("TRIGGER_ADD_AT_PLAYHEAD called! isEditMIDICuesMode=%d, isEditSectionsMode=%d, selectedDrawerItem=%@", engine.isEditMIDICuesMode, engine.isEditSectionsMode, engine.selectedEditDrawerItem.rawValue)
        let isSMPTEActive = engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte
        if engine.isEditMIDICuesMode {
            editingMIDICue = nil
            isAddingMIDICueAtPlayhead.toggle()
        } else if engine.isEditDirectionalCuesMode {
            editingDirectionalCue = nil
            isAddingDirectionalCueAtPlayhead.toggle()
        } else if engine.isEditAutomationMode {
            editingAutomationPoint = nil
            isAddingAutomationAtPlayhead.toggle()
        } else if isSMPTEActive {
            // User requirement: "If the user presses + after a cue has been placed, the cue should move to where the user has pressed +."
            let playheadTime = engine.snapTimeToBeatGrid(engine.transportPosition.currentTime)
            if engine.currentSong.smpteCue != nil {
                engine.moveSMPTECue(to: playheadTime)
            } else {
                _ = engine.addSMPTECue(at: playheadTime)
            }
            editingSMPTECue = engine.currentSong.smpteCue
            isAddingSMPTECueAtPlayhead = true
        } else {
            if activeAddPopoverIndex == -2 {
                activeAddPopoverIndex = nil
            } else {
                activeAddPopoverIndex = -2
            }
        }
    }
    
    // MARK: - Pre-Rendered Cached Beat & Measure Grid Tile Renderer (helper classes below)
}

private struct TimelinePlayheadScrollContainer<StaticContent: View>: View {
    @ObservedObject var clock: TransportClockModel
    let engine: MultitrackAudioEngine
    let gridTileCache: BeatGridTileCache
    let gridKey: BeatGridTileCache.CacheKey
    let waveformWidth: CGFloat
    let waveformHeight: CGFloat
    let viewportWidth: CGFloat
    let secPerMeasure: Double
    let pixelsPerSecond: CGFloat
    let beatsPerMeasure: Int
    let effectiveDuration: TimeInterval
    let playheadAnchorX: CGFloat
    let isEditTimeline: Bool
    let isStationary: Bool
    let lockedStationaryTime: TimeInterval?
    let frozenScrollTime: TimeInterval?
    let stoppedScrollBaseTime: TimeInterval?
    let userPlayingScrollOffset: CGFloat
    let userStoppedScrollOffset: CGFloat
    let scrollingStaticContent: StaticContent

    var body: some View {
        let rawTime = clock.position.currentTime
        let clampedDisplayTime = max(0.0, min(effectiveDuration > 0 ? effectiveDuration : 300, rawTime))
        let rawBaseScrollTime: TimeInterval = {
            if isStationary, let locked = lockedStationaryTime {
                return locked
            }
            if engine.playbackState == .playing, let frozen = frozenScrollTime {
                return frozen
            }
            if engine.playbackState != .playing, let stoppedBase = stoppedScrollBaseTime {
                return stoppedBase
            }
            return clampedDisplayTime
        }()
        let baseScrollTime: TimeInterval = isEditTimeline ? engine.displayTimeForSongPosition(rawBaseScrollTime) : rawBaseScrollTime
        let scrollX = playheadAnchorX - (CGFloat(baseScrollTime) * pixelsPerSecond) + (isStationary ? 0 : (engine.playbackState == .playing ? userPlayingScrollOffset : userStoppedScrollOffset))

        let tileW = BeatGridTileCache.tileWidth
        let totalTiles = max(1, Int(ceil((waveformWidth + 4.0) / tileW)))
        let minVisibleX = max(0, -scrollX - 24.0)
        let maxVisibleX = min(waveformWidth + 4.0, -scrollX + viewportWidth + 24.0)
        let firstTile = max(0, Int(floor(minVisibleX / tileW)))
        let lastTile = min(totalTiles - 1, Int(ceil(maxVisibleX / tileW)))

        ZStack(alignment: .topLeading) {
            if effectiveDuration > 0, waveformWidth > 0, viewportWidth > 0, waveformHeight > 0 {
                EquatableView(content: TimelineBeatGridBandView(
                    key: gridKey,
                    cache: gridTileCache,
                    waveformWidth: waveformWidth,
                    height: waveformHeight,
                    secPerMeasure: secPerMeasure,
                    pixelsPerSecond: pixelsPerSecond,
                    beatsPerMeasure: beatsPerMeasure,
                    engine: engine,
                    firstTile: firstTile,
                    lastTile: lastTile
                ))
            }

            scrollingStaticContent
        }
        .offset(x: scrollX)
    }
}

private struct TimelineBeatGridBandView: View, Equatable {
    let key: BeatGridTileCache.CacheKey
    let cache: BeatGridTileCache
    let waveformWidth: CGFloat
    let height: CGFloat
    let secPerMeasure: Double
    let pixelsPerSecond: CGFloat
    let beatsPerMeasure: Int
    let engine: MultitrackAudioEngine
    let firstTile: Int
    let lastTile: Int

    static func == (lhs: TimelineBeatGridBandView, rhs: TimelineBeatGridBandView) -> Bool {
        lhs.key == rhs.key &&
        lhs.firstTile == rhs.firstTile &&
        lhs.lastTile == rhs.lastTile &&
        lhs.height == rhs.height
    }

    var body: some View {
        let _ = cache.ensureKey(key)
        let tileW = BeatGridTileCache.tileWidth
        ZStack(alignment: .topLeading) {
            if firstTile <= lastTile {
                ForEach(firstTile...lastTile, id: \.self) { tileIdx in
                    let tileStartX = CGFloat(tileIdx) * tileW
                    let actualW = min(tileW, (waveformWidth + 4.0) - tileStartX)
                    if actualW > 0 {
                        let img = cache.tileImage(
                            index: tileIdx,
                            tileWidth: actualW,
                            height: height,
                            waveformWidth: waveformWidth,
                            secPerMeasure: secPerMeasure,
                            pixelsPerSecond: pixelsPerSecond,
                            beatsPerMeasure: beatsPerMeasure,
                            engine: engine
                        )
                        Image(nsImage: img)
                            .frame(width: actualW, height: height)
                            .offset(x: tileStartX)
                    }
                }
            }
        }
        .frame(width: max(1, waveformWidth + 4.0), height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct TimelinePopoverAnchorsOverlay: View {
    @ObservedObject var clock: TransportClockModel
    let engine: MultitrackAudioEngine
    let geoSize: CGSize
    let midY: CGFloat
    let badgeY: CGFloat
    let leadPlusX: CGFloat
    let pixelsPerSecond: CGFloat
    let liveSections: [SongSection]

    @Binding var activeAddPopoverIndex: Int?
    @Binding var isAddingMIDICueAtPlayhead: Bool
    @Binding var editingMIDICue: MIDICue?
    @Binding var isAddingDirectionalCueAtPlayhead: Bool
    @Binding var editingDirectionalCue: DirectionalCue?
    @Binding var isAddingAutomationAtPlayhead: Bool
    @Binding var editingAutomationPoint: AutomationPoint?
    @Binding var isAddingSMPTECueAtPlayhead: Bool
    @Binding var editingSMPTECue: SMPTECue?

    let computePopoverRectWithScroll: (CGFloat) -> NSRect?
    let scrollXForTime: (TimeInterval) -> CGFloat
    private let playheadAnchorX: CGFloat = 36.0

    var body: some View {
        let anyPopoverActive = activeAddPopoverIndex != nil ||
            isAddingMIDICueAtPlayhead || editingMIDICue != nil ||
            isAddingDirectionalCueAtPlayhead || editingDirectionalCue != nil ||
            isAddingAutomationAtPlayhead || editingAutomationPoint != nil ||
            isAddingSMPTECueAtPlayhead || editingSMPTECue != nil

        let scrollX: CGFloat = anyPopoverActive ? scrollXForTime(clock.position.currentTime) : 0.0

        let activePopoverTargetRect: NSRect? = (activeAddPopoverIndex != nil) ? computePopoverRectWithScroll(scrollX) : nil

        let activeMIDICueTargetRect: NSRect? = {
            if isAddingMIDICueAtPlayhead {
                return NSRect(x: playheadAnchorX - 14, y: midY - 14, width: 28, height: 28)
            } else if let cue = editingMIDICue {
                let dispTime = engine.displayTime(forMIDICue: cue)
                let rawCueX = CGFloat(dispTime) * pixelsPerSecond + scrollX
                let clampedCueX = max(24.0, min(max(48.0, geoSize.width - 24.0), rawCueX))
                let isMIDIEdit = engine.isEditMIDICuesMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .midiCues
                let yPos = isMIDIEdit ? badgeY : (geoSize.height - 11)
                return NSRect(x: clampedCueX - 10, y: yPos - 10, width: 20, height: 20)
            }
            return nil
        }()

        let activeDirectionalCueTargetRect: NSRect? = {
            if isAddingDirectionalCueAtPlayhead {
                return NSRect(x: playheadAnchorX - 14, y: midY - 14, width: 28, height: 28)
            } else if let cue = editingDirectionalCue {
                let dispTime = engine.displayTime(forDirectionalCue: cue)
                let rawCueX = CGFloat(dispTime) * pixelsPerSecond + scrollX
                let clampedCueX = max(24.0, min(max(48.0, geoSize.width - 24.0), rawCueX))
                let isDirEdit = engine.isEditDirectionalCuesMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .directionalCues
                let yPos = isDirEdit ? badgeY : (geoSize.height - 16)
                return NSRect(x: clampedCueX - 10, y: yPos - 10, width: 20, height: 20)
            }
            return nil
        }()

        let activeAutomationTargetRect: NSRect? = {
            if isAddingAutomationAtPlayhead {
                return NSRect(x: playheadAnchorX - 14, y: midY - 14, width: 28, height: 28)
            } else if let pt = editingAutomationPoint {
                let dispTime = engine.displayTime(forAutomationPoint: pt)
                let rawCueX = CGFloat(dispTime) * pixelsPerSecond + scrollX
                let clampedCueX = max(24.0, min(max(48.0, geoSize.width - 24.0), rawCueX))
                let isAutoEdit = engine.isEditAutomationMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .automation
                let yPos = isAutoEdit ? badgeY : (geoSize.height - 16)
                return NSRect(x: clampedCueX - 10, y: yPos - 10, width: 20, height: 20)
            }
            return nil
        }()

        let activeSMPTETargetRect: NSRect? = {
            if isAddingSMPTECueAtPlayhead {
                return NSRect(x: playheadAnchorX - 14, y: midY - 14, width: 28, height: 28)
            } else if let cue = editingSMPTECue {
                let rawCueX = CGFloat(cue.time) * pixelsPerSecond + scrollX
                let clampedCueX = max(24.0, min(max(48.0, geoSize.width - 24.0), rawCueX))
                let isSMPTEEdit = engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte
                let yPos = isSMPTEEdit ? badgeY : (geoSize.height - 16)
                return NSRect(x: clampedCueX - 10, y: yPos - 10, width: 20, height: 20)
            }
            return nil
        }()

        ZStack(alignment: .topLeading) {
            SongSectionPopoverPresenter(
                activeIndex: $activeAddPopoverIndex,
                targetRect: activePopoverTargetRect,
                engine: engine
            )
            .frame(width: geoSize.width, height: geoSize.height)
            .allowsHitTesting(false)

            MIDICuePopoverPresenter(
                isAddingAtPlayhead: $isAddingMIDICueAtPlayhead,
                editingCue: $editingMIDICue,
                targetRect: activeMIDICueTargetRect,
                engine: engine
            )
            .frame(width: geoSize.width, height: geoSize.height)
            .allowsHitTesting(false)

            DirectionalCuePopoverPresenter(
                isAddingAtPlayhead: $isAddingDirectionalCueAtPlayhead,
                editingCue: $editingDirectionalCue,
                targetRect: activeDirectionalCueTargetRect,
                engine: engine
            )
            .frame(width: geoSize.width, height: geoSize.height)
            .allowsHitTesting(false)

            AutomationPopoverPresenter(
                isAddingAtPlayhead: $isAddingAutomationAtPlayhead,
                editingPoint: $editingAutomationPoint,
                targetRect: activeAutomationTargetRect,
                engine: engine
            )
            .frame(width: geoSize.width, height: geoSize.height)
            .allowsHitTesting(false)

            SMPTEPopoverPresenter(
                isAddingAtPlayhead: $isAddingSMPTECueAtPlayhead,
                editingCue: $editingSMPTECue,
                targetRect: activeSMPTETargetRect,
                engine: engine
            )
            .frame(width: geoSize.width, height: geoSize.height)
            .allowsHitTesting(false)
        }
    }
}

/// Renders and caches 1024pt-wide Retina bitmap tiles of the Beat & Measure Grid
/// so scrolling and 60/120 Hz playback only blit static textures with zero per-frame Path/Text work.
@MainActor
fileprivate final class BeatGridTileCache {
    static let tileWidth: CGFloat = 1024.0
    
    struct CacheKey: Equatable {
        let songId: UUID
        let waveformWidth: CGFloat
        let height: CGFloat
        let secPerMeasure: Double
        let pixelsPerSecond: CGFloat
        let beatsPerMeasure: Int
        let bpm: Double
        let beatGridCount: Int
        let firstMarkerTime: Double
        let lastMarkerTime: Double
    }
    
    private var currentKey: CacheKey?
    private var tiles: [Int: NSImage] = [:]
    
    func ensureKey(_ key: CacheKey) {
        if currentKey != key {
            currentKey = key
            tiles.removeAll(keepingCapacity: true)
        }
    }
    
    func tileImage(
        index: Int,
        tileWidth actualW: CGFloat,
        height: CGFloat,
        waveformWidth: CGFloat,
        secPerMeasure: Double,
        pixelsPerSecond: CGFloat,
        beatsPerMeasure: Int,
        engine: MultitrackAudioEngine
    ) -> NSImage {
        if let existing = tiles[index] {
            return existing
        }
        
        let scale: CGFloat = 2.0
        let pxW = max(1, Int(ceil(actualW * scale)))
        let pxH = max(1, Int(ceil(height * scale)))
        
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: actualW, height: height))
        }
        rep.size = NSSize(width: actualW, height: height)
        
        NSGraphicsContext.saveGraphicsState()
        if let baseCtx = NSGraphicsContext(bitmapImageRep: rep) {
            let cg = baseCtx.cgContext
            // Flip to top-left origin matching SwiftUI Canvas coordinates, and wrap in a flipped NSGraphicsContext
            // so NSAttributedString.draw(at:) renders measure numbers right-side up.
            cg.translateBy(x: 0, y: height)
            cg.scaleBy(x: 1, y: -1)
            let nsCtx = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.current = nsCtx
            
            let tileStartX = CGFloat(index) * Self.tileWidth
            let tileEndX = tileStartX + actualW
            let effectiveBottomY = height - 1.0
            let estDuration = TimeInterval(waveformWidth / max(1.0, pixelsPerSecond))
            let dynamicGrid = engine.cachedEffectiveBeatGrid.isEmpty ? engine.currentSong.effectiveBeatGrid(totalDuration: estDuration) : engine.cachedEffectiveBeatGrid
            let baseSongBPM = engine.currentSong.bpm
            
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .black),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
            let bpmAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor(red: 0.30, green: 0.88, blue: 0.98, alpha: 1.0)
            ]
            
            func firstIndex(in markers: [BeatGridMarker], time: Double) -> Int {
                var low = 0
                var high = markers.count - 1
                var startIdx = 0
                while low <= high {
                    let mid = (low + high) / 2
                    if markers[mid].time < time {
                        low = mid + 1
                        startIdx = low
                    } else {
                        high = mid - 1
                    }
                }
                return max(0, min(max(0, markers.count - 1), startIdx))
            }
            
            if !dynamicGrid.isEmpty {
                let minVisibleTime = Double(max(0, tileStartX - 32.0)) / Double(max(1.0, pixelsPerSecond))
                let maxVisibleTime = Double(tileEndX + 32.0) / Double(max(1.0, pixelsPerSecond))
                let subMarkers = engine.precomputedSubdivisionMarkers.isEmpty ? dynamicGrid.filter { !$0.isDownbeat } : engine.precomputedSubdivisionMarkers
                let downbeatMarkers = engine.precomputedDownbeatMarkers.isEmpty ? dynamicGrid.filter { $0.isDownbeat } : engine.precomputedDownbeatMarkers
                
                if !subMarkers.isEmpty {
                    cg.beginPath()
                    let startSub = firstIndex(in: subMarkers, time: minVisibleTime)
                    for idx in startSub..<subMarkers.count {
                        let marker = subMarkers[idx]
                        if marker.time > maxVisibleTime { break }
                        let beatX = CGFloat(marker.time) * pixelsPerSecond
                        guard beatX >= tileStartX - 2 && beatX <= tileEndX + 2 && beatX < waveformWidth - 2 else { continue }
                        let lx = beatX - tileStartX
                        cg.move(to: CGPoint(x: lx, y: 0))
                        cg.addLine(to: CGPoint(x: lx, y: effectiveBottomY))
                    }
                    let subPath = cg.path
                    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.50).cgColor)
                    cg.setLineWidth(1.6)
                    cg.strokePath()
                    if let p = subPath {
                        cg.addPath(p)
                        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.38).cgColor)
                        cg.setLineWidth(0.8)
                        cg.strokePath()
                    }
                }
                
                var lastDisplayedBarBPM: Int = Int(round(baseSongBPM))
                if !downbeatMarkers.isEmpty {
                    cg.beginPath()
                    let startBar = firstIndex(in: downbeatMarkers, time: minVisibleTime)
                    for idx in startBar..<downbeatMarkers.count {
                        let marker = downbeatMarkers[idx]
                        if marker.time > maxVisibleTime { break }
                        let barX = CGFloat(marker.time) * pixelsPerSecond
                        guard barX >= tileStartX - 48 && barX <= tileEndX + 4 && barX <= waveformWidth else { continue }
                        let lx = barX - tileStartX
                        if lx >= -2 && lx <= actualW + 2 {
                            cg.move(to: CGPoint(x: lx, y: 0))
                            cg.addLine(to: CGPoint(x: lx, y: effectiveBottomY))
                        }
                    }
                    let measurePath = cg.path
                    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.80).cgColor)
                    cg.setLineWidth(2.6)
                    cg.strokePath()
                    if let p = measurePath {
                        cg.addPath(p)
                        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                        cg.setLineWidth(1.2)
                        cg.strokePath()
                    }
                    
                    // Draw bar numbers & BPM badges in flipped NSGraphicsContext
                    for idx in startBar..<downbeatMarkers.count {
                        let marker = downbeatMarkers[idx]
                        if marker.time > maxVisibleTime { break }
                        let barX = CGFloat(marker.time) * pixelsPerSecond
                        guard barX >= tileStartX - 48 && barX <= tileEndX + 4 && barX + 24 <= waveformWidth else { continue }
                        let lx = barX - tileStartX
                        let numStr = NSAttributedString(string: String(marker.bar), attributes: labelAttrs)
                        numStr.draw(at: NSPoint(x: lx + 4, y: effectiveBottomY - 19))
                        
                        let roundedBarBPM = Int(round(marker.instantaneousBPM))
                        if abs(roundedBarBPM - lastDisplayedBarBPM) >= 2 && abs(roundedBarBPM - Int(round(baseSongBPM))) >= 2 {
                            lastDisplayedBarBPM = roundedBarBPM
                            let bpmStr = NSAttributedString(string: "\(roundedBarBPM) BPM", attributes: bpmAttrs)
                            bpmStr.draw(at: NSPoint(x: lx + 4, y: effectiveBottomY - 30))
                        } else if abs(roundedBarBPM - Int(round(baseSongBPM))) <= 1 {
                            lastDisplayedBarBPM = Int(round(baseSongBPM))
                        }
                    }
                }
            } else {
                let barPixelWidth = max(4.0, CGFloat(secPerMeasure) * pixelsPerSecond)
                let beatPixelWidth = barPixelWidth / CGFloat(max(1, beatsPerMeasure))
                let totalBars = max(1, Int(floor(waveformWidth / barPixelWidth)) + 1)
                let firstBar = max(0, Int(floor(max(0, tileStartX - barPixelWidth) / barPixelWidth)))
                let lastBar = min(totalBars - 1, Int(ceil((tileEndX + barPixelWidth) / barPixelWidth)))
                
                if firstBar <= lastBar {
                    if beatsPerMeasure > 1 {
                        cg.beginPath()
                        for bar in firstBar...lastBar {
                            let barX = CGFloat(bar) * barPixelWidth
                            guard barX < waveformWidth else { break }
                            for beat in 1..<beatsPerMeasure {
                                let beatX = barX + (CGFloat(beat) * beatPixelWidth)
                                guard beatX < waveformWidth - 2 else { break }
                                if beatX >= tileStartX - 2 && beatX <= tileEndX + 2 {
                                    let lx = beatX - tileStartX
                                    cg.move(to: CGPoint(x: lx, y: 0))
                                    cg.addLine(to: CGPoint(x: lx, y: effectiveBottomY))
                                }
                            }
                        }
                        let subPath = cg.path
                        cg.setStrokeColor(NSColor.black.withAlphaComponent(0.50).cgColor)
                        cg.setLineWidth(1.6)
                        cg.strokePath()
                        if let p = subPath {
                            cg.addPath(p)
                            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.38).cgColor)
                            cg.setLineWidth(0.8)
                            cg.strokePath()
                        }
                    }
                    
                    cg.beginPath()
                    for bar in firstBar...lastBar {
                        let barX = CGFloat(bar) * barPixelWidth
                        guard barX <= waveformWidth else { break }
                        if barX >= tileStartX - 2 && barX <= tileEndX + 2 {
                            let lx = barX - tileStartX
                            cg.move(to: CGPoint(x: lx, y: 0))
                            cg.addLine(to: CGPoint(x: lx, y: effectiveBottomY))
                        }
                    }
                    let measurePath = cg.path
                    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.80).cgColor)
                    cg.setLineWidth(2.6)
                    cg.strokePath()
                    if let p = measurePath {
                        cg.addPath(p)
                        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                        cg.setLineWidth(1.2)
                        cg.strokePath()
                    }
                    
                    for bar in firstBar...lastBar {
                        let barX = CGFloat(bar) * barPixelWidth
                        guard barX + 24 <= waveformWidth else { break }
                        if barX >= tileStartX - 40 && barX <= tileEndX + 4 {
                            let lx = barX - tileStartX
                            let numStr = NSAttributedString(string: String(bar + 1), attributes: labelAttrs)
                            numStr.draw(at: NSPoint(x: lx + 4, y: effectiveBottomY - 19))
                        }
                    }
                }
            }
            
            // End-of-Audio Measure Bar Line
            if waveformWidth >= tileStartX - 2 && waveformWidth <= tileEndX + 2 {
                let endLx = waveformWidth - tileStartX
                cg.beginPath()
                cg.move(to: CGPoint(x: endLx, y: 0))
                cg.addLine(to: CGPoint(x: endLx, y: effectiveBottomY))
                cg.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                cg.setLineWidth(2.0)
                cg.strokePath()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        
        let image = NSImage(size: NSSize(width: actualW, height: height))
        image.addRepresentation(rep)
        tiles[index] = image
        return image
    }
}

// MARK: - Native Popover Presenter

struct SongSectionPopoverPresenter: NSViewRepresentable {
    @Binding var activeIndex: Int?
    let targetRect: NSRect?
    let engine: MultitrackAudioEngine
    
    func makeNSView(context: Context) -> PopoverAnchorNSView {
        let view = PopoverAnchorNSView()
        context.coordinator.anchorView = view
        return view
    }
    
    func updateNSView(_ nsView: PopoverAnchorNSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(
            activeIndex: activeIndex,
            targetRect: targetRect,
            engine: engine,
            onClose: {
                self.activeIndex = nil
            }
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: PopoverAnchorNSView?
        private var popover: NSPopover?
        private var currentlyPresentedIndex: Int?
        var onClose: (() -> Void)?
        private var isProgrammaticClose = false
        
        func closeProgrammatically() {
            guard let p = popover else {
                currentlyPresentedIndex = nil
                return
            }
            isProgrammaticClose = true
            p.delegate = nil
            p.close()
            popover = nil
            currentlyPresentedIndex = nil
            isProgrammaticClose = false
        }
        
        func update(activeIndex: Int?, targetRect: NSRect?, engine: MultitrackAudioEngine, onClose: @escaping () -> Void) {
            self.onClose = onClose
            
            guard let index = activeIndex, let rect = targetRect else {
                closeProgrammatically()
                return
            }
            
            if let p = popover, currentlyPresentedIndex == index {
                if p.isShown {
                    p.positioningRect = rect
                }
                return
            }
            
            closeProgrammatically()
            
            guard let anchorView = anchorView else { return }
            guard anchorView.window != nil else {
                anchorView.onMoveToWindow = { [weak self] in
                    self?.update(activeIndex: activeIndex, targetRect: targetRect, engine: engine, onClose: onClose)
                }
                return
            }
            
            let p = NSPopover()
            p.appearance = NSAppearance(named: .darkAqua)
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            
            let atTime: TimeInterval?
            let insertIdx: Int?
            if engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .songSections {
                if index == -2 {
                    atTime = engine.transportPosition.currentTime
                } else if index == -1 {
                    atTime = engine.currentSong.sections.isEmpty ? engine.transportPosition.currentTime : 0.0
                } else if index >= 0 && index < engine.currentSong.sections.count {
                    atTime = engine.currentSong.sections[index].endTime
                } else {
                    atTime = engine.transportPosition.currentTime
                }
                insertIdx = nil
            } else {
                atTime = (index == -2 || (index == -1 && engine.currentSong.sections.isEmpty)) ? engine.transportPosition.currentTime : nil
                insertIdx = (atTime == nil && index >= -1) ? index : nil
            }
            let contentView = AddSongSectionPopoverView(
                engine: engine,
                insertAfterIndex: insertIdx,
                atTime: atTime
            ) { [weak self] in
                self?.closeProgrammatically()
                self?.onClose?()
            }
            
            let hostingController = NSHostingController(rootView: contentView)
            let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 300, height: 600))
            let finalSize = NSSize(width: max(fittingSize.width, 260), height: max(fittingSize.height, 140))
            hostingController.preferredContentSize = finalSize
            p.contentSize = finalSize
            p.contentViewController = hostingController
            self.popover = p
            self.currentlyPresentedIndex = index
            
            p.show(relativeTo: rect, of: anchorView, preferredEdge: .maxX)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard !isProgrammaticClose else { return }
            popover = nil
            currentlyPresentedIndex = nil
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
            }
        }
    }
    
    final class PopoverAnchorNSView: NSView {
        override var isFlipped: Bool { return true }
        override func hitTest(_ point: NSPoint) -> NSView? { return nil }
        var onMoveToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
                onMoveToWindow = nil
            }
        }
    }
}

struct MIDICuePopoverPresenter: NSViewRepresentable {
    @Binding var isAddingAtPlayhead: Bool
    @Binding var editingCue: MIDICue?
    let targetRect: NSRect?
    let engine: MultitrackAudioEngine
    
    func makeNSView(context: Context) -> SongSectionPopoverPresenter.PopoverAnchorNSView {
        let view = SongSectionPopoverPresenter.PopoverAnchorNSView()
        context.coordinator.anchorView = view
        return view
    }
    
    func updateNSView(_ nsView: SongSectionPopoverPresenter.PopoverAnchorNSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(
            isAddingAtPlayhead: isAddingAtPlayhead,
            editingCue: editingCue,
            targetRect: targetRect,
            engine: engine,
            onClose: {
                self.isAddingAtPlayhead = false
                self.editingCue = nil
            }
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: SongSectionPopoverPresenter.PopoverAnchorNSView?
        private var popover: NSPopover?
        private var currentlyPresentedKey: String?
        var onClose: (() -> Void)?
        private var isProgrammaticClose = false
        
        func closeProgrammatically() {
            guard let p = popover else {
                currentlyPresentedKey = nil
                return
            }
            isProgrammaticClose = true
            p.delegate = nil
            p.close()
            popover = nil
            currentlyPresentedKey = nil
            isProgrammaticClose = false
        }
        
        func update(
            isAddingAtPlayhead: Bool,
            editingCue: MIDICue?,
            targetRect: NSRect?,
            engine: MultitrackAudioEngine,
            onClose: @escaping () -> Void
        ) {
            if !isAddingAtPlayhead && editingCue == nil && currentlyPresentedKey == nil {
                return
            }
            self.onClose = onClose
            
            let presentationKey: String? = {
                if isAddingAtPlayhead {
                    return "add_playhead"
                } else if let cue = editingCue {
                    return "edit_\(cue.id.uuidString)"
                }
                return nil
            }()
            
            guard let key = presentationKey, let rect = targetRect else {
                closeProgrammatically()
                return
            }
            
            if let p = popover, currentlyPresentedKey == key {
                if p.isShown {
                    p.positioningRect = rect
                }
                return
            }
            
            closeProgrammatically()
            
            guard let anchorView = anchorView else { return }
            guard anchorView.window != nil else {
                anchorView.onMoveToWindow = { [weak self] in
                    self?.update(isAddingAtPlayhead: isAddingAtPlayhead, editingCue: editingCue, targetRect: targetRect, engine: engine, onClose: onClose)
                }
                return
            }
            
            let p = NSPopover()
            p.appearance = NSAppearance(named: .darkAqua)
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            
            let cueTime = editingCue?.time ?? engine.transportPosition.currentTime
            let contentView = AddMIDICuePopoverView(
                engine: engine,
                atTime: cueTime,
                existingCue: editingCue
            ) { [weak self] in
                self?.closeProgrammatically()
                self?.onClose?()
            }
            
            let hostingController = NSHostingController(rootView: contentView)
            let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 320, height: 650))
            let finalSize = NSSize(width: max(fittingSize.width, 270), height: max(fittingSize.height, 140))
            hostingController.preferredContentSize = finalSize
            p.contentSize = finalSize
            p.contentViewController = hostingController
            self.popover = p
            self.currentlyPresentedKey = key
            
            let edge: NSRectEdge = isAddingAtPlayhead ? .maxX : .minY
            p.show(relativeTo: rect, of: anchorView, preferredEdge: edge)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard !isProgrammaticClose else { return }
            popover = nil
            currentlyPresentedKey = nil
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
            }
        }
    }
}

// MARK: - Native Directional Cue Popover Presenter

struct DirectionalCuePopoverPresenter: NSViewRepresentable {
    @Binding var isAddingAtPlayhead: Bool
    @Binding var editingCue: DirectionalCue?
    let targetRect: NSRect?
    let engine: MultitrackAudioEngine
    
    func makeNSView(context: Context) -> SongSectionPopoverPresenter.PopoverAnchorNSView {
        let view = SongSectionPopoverPresenter.PopoverAnchorNSView()
        context.coordinator.anchorView = view
        return view
    }
    
    func updateNSView(_ nsView: SongSectionPopoverPresenter.PopoverAnchorNSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(
            isAddingAtPlayhead: isAddingAtPlayhead,
            editingCue: editingCue,
            targetRect: targetRect,
            engine: engine
        ) {
            DispatchQueue.main.async {
                self.isAddingAtPlayhead = false
                self.editingCue = nil
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: SongSectionPopoverPresenter.PopoverAnchorNSView?
        var popover: NSPopover?
        var currentlyPresentedKey: String?
        var onClose: (() -> Void)?
        private var isProgrammaticClose = false
        
        func closeProgrammatically() {
            guard let p = popover else {
                currentlyPresentedKey = nil
                return
            }
            isProgrammaticClose = true
            p.delegate = nil
            p.close()
            popover = nil
            currentlyPresentedKey = nil
            isProgrammaticClose = false
        }
        
        func update(
            isAddingAtPlayhead: Bool,
            editingCue: DirectionalCue?,
            targetRect: NSRect?,
            engine: MultitrackAudioEngine,
            onClose: @escaping () -> Void
        ) {
            if !isAddingAtPlayhead && editingCue == nil && currentlyPresentedKey == nil {
                return
            }
            self.onClose = onClose
            
            let presentationKey: String? = {
                if isAddingAtPlayhead {
                    return "add_directional_playhead"
                } else if let cue = editingCue {
                    return "edit_directional_\(cue.id.uuidString)"
                }
                return nil
            }()
            
            guard let key = presentationKey, let rect = targetRect else {
                closeProgrammatically()
                return
            }
            
            if let p = popover, currentlyPresentedKey == key {
                if p.isShown {
                    p.positioningRect = rect
                }
                return
            }
            
            closeProgrammatically()
            
            guard let anchorView = anchorView else { return }
            guard anchorView.window != nil else {
                anchorView.onMoveToWindow = { [weak self] in
                    self?.update(isAddingAtPlayhead: isAddingAtPlayhead, editingCue: editingCue, targetRect: targetRect, engine: engine, onClose: onClose)
                }
                return
            }
            
            let p = NSPopover()
            p.appearance = NSAppearance(named: .darkAqua)
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            
            let cueTime = editingCue?.time ?? engine.transportPosition.currentTime
            let contentView: AnyView
            if let cue = editingCue {
                contentView = AnyView(EditDirectionalCuePopoverView(
                    engine: engine,
                    cue: cue
                ) { [weak self] in
                    self?.closeProgrammatically()
                    self?.onClose?()
                })
            } else {
                contentView = AnyView(AddDirectionalCuePopoverView(
                    engine: engine,
                    targetTime: cueTime
                ) { [weak self] in
                    self?.closeProgrammatically()
                    self?.onClose?()
                })
            }
            
            let hostingController = NSHostingController(rootView: contentView)
            let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 320, height: 600))
            let finalSize = NSSize(width: max(fittingSize.width, 270), height: max(fittingSize.height, 140))
            hostingController.preferredContentSize = finalSize
            p.contentSize = finalSize
            p.contentViewController = hostingController
            self.popover = p
            self.currentlyPresentedKey = key
            
            let edge: NSRectEdge = isAddingAtPlayhead ? .maxX : .minY
            p.show(relativeTo: rect, of: anchorView, preferredEdge: edge)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard !isProgrammaticClose else { return }
            popover = nil
            currentlyPresentedKey = nil
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
            }
        }
    }
}

// MARK: - Equatable Static Layers (Zero View Diffing on Playhead Ticks!)

struct TimelineSectionsLayerView: View, Equatable {
    let liveSections: [SongSection]
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let isLoopActive: Bool
    let loopedSectionId: UUID?
    let isEditMode: Bool
    let loopMode: MultitrackAudioEngine.LoopMode
    let queuedNextSectionId: UUID?
    let preRollTargetSectionId: UUID?
    let isBeatFlashing: Bool
    let isStationary: Bool
    let bpm: Double
    let engine: MultitrackAudioEngine
    @Binding var activePopoverSection: SongSection?
    @Binding var activeMIDICueSection: SongSection?
    let onSeek: (TimeInterval) -> Void
    let onToggleSectionLoop: (SongSection) -> Void
    let onAddSectionAfter: (Int) -> Void
    let onClearAutoSnap: () -> Void
    
    static func == (lhs: TimelineSectionsLayerView, rhs: TimelineSectionsLayerView) -> Bool {
        lhs.liveSections == rhs.liveSections &&
        lhs.pixelsPerSecond == rhs.pixelsPerSecond &&
        lhs.height == rhs.height &&
        lhs.isLoopActive == rhs.isLoopActive &&
        lhs.loopedSectionId == rhs.loopedSectionId &&
        lhs.isEditMode == rhs.isEditMode &&
        lhs.loopMode == rhs.loopMode &&
        lhs.queuedNextSectionId == rhs.queuedNextSectionId &&
        lhs.preRollTargetSectionId == rhs.preRollTargetSectionId &&
        lhs.isBeatFlashing == rhs.isBeatFlashing &&
        lhs.isStationary == rhs.isStationary &&
        lhs.bpm == rhs.bpm &&
        lhs.activePopoverSection?.id == rhs.activePopoverSection?.id &&
        lhs.activeMIDICueSection?.id == rhs.activeMIDICueSection?.id
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(liveSections.enumerated()), id: \.element.id) { index, section in
                let startX = CGFloat(section.startTime) * pixelsPerSecond
                let width = CGFloat(section.duration) * pixelsPerSecond
                let isLooped = isLoopActive && loopedSectionId == section.id
                let isQueuedNext = (queuedNextSectionId == section.id) || (preRollTargetSectionId == section.id)
                let isBeatFlash = isQueuedNext && isBeatFlashing
                
                SingleSectionView(
                    section: section,
                    sectionIndex: index,
                    width: width,
                    height: height,
                    isLooped: isLooped,
                    isEditMode: isEditMode,
                    pixelsPerSecond: pixelsPerSecond,
                    loopMode: loopMode,
                    isQueuedNext: isQueuedNext,
                    isBeatFlash: isBeatFlash,
                    engine: engine,
                    activePopoverSection: $activePopoverSection,
                    activeMIDICueSection: $activeMIDICueSection,
                    bpm: bpm,
                    onSeek: {
                        if isStationary { return }
                        if engine.trimmingSection != nil { return }
                        if engine.isEditingArrangement {
                            activePopoverSection = section
                        } else {
                            onSeek(section.startTime)
                        }
                    },
                    onToggleLoop: {
                        if engine.trimmingSection != nil { return }
                        onToggleSectionLoop(section)
                    },
                    onAddSectionAfter: {
                        onAddSectionAfter(index)
                    },
                    onQueueSection: onClearAutoSnap
                )
                .offset(x: startX)
            }
        }
    }
}

private struct TimeSignatureChangeEditorPopover: View {
    let change: TimeSignatureChange
    let onUpdate: (Int, Int) -> Void
    let onDelete: () -> Void
    @State private var num: Int
    @State private var den: Int
    
    init(change: TimeSignatureChange, onUpdate: @escaping (Int, Int) -> Void, onDelete: @escaping () -> Void) {
        self.change = change
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _num = State(initialValue: change.numerator)
        _den = State(initialValue: change.denominator)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Time Signature")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            HStack(spacing: 12) {
                Stepper("Beats: \(num)", value: $num, in: 1...16)
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $den) {
                    ForEach([2, 4, 8, 16], id: \.self) { d in
                        Text("/\(d)").tag(d)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }
            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") { onUpdate(num, den) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }
}

struct TimelineCuesLaneLayerView: View, Equatable {
    let automationPoints: [AutomationPoint]
    let directionalCues: [DirectionalCue]
    let smpteCue: SMPTECue?
    let midiCues: [MIDICue]
    let liveSections: [SongSection]
    let pixelsPerSecond: CGFloat
    let totalHeight: CGFloat
    let laneHeight: CGFloat
    let showSMPTECueOnLane: Bool
    let isEditingArrangement: Bool
    let trimLeadingDuration: TimeInterval
    let trimTrailingDuration: TimeInterval
    let isEditAutomationMode: Bool
    let isEditDirectionalCuesMode: Bool
    let isEditMIDICuesMode: Bool
    let isEditSMPTEMode: Bool
    let isEditDrawerOpen: Bool
    let selectedEditDrawerItem: MultitrackAudioEngine.EditDrawerItem
    let selectedAutomationPointId: UUID?
    let selectedDirectionalCueId: UUID?
    let selectedMIDICueId: UUID?
    let engine: MultitrackAudioEngine
    @Binding var isAddingAutomationAtPlayhead: Bool
    @Binding var editingAutomationPoint: AutomationPoint?
    @Binding var isAddingDirectionalCueAtPlayhead: Bool
    @Binding var editingDirectionalCue: DirectionalCue?
    @Binding var isAddingSMPTECueAtPlayhead: Bool
    @Binding var editingSMPTECue: SMPTECue?
    @Binding var isAddingMIDICueAtPlayhead: Bool
    @Binding var editingMIDICue: MIDICue?
    @Binding var draggingCueId: UUID?
    @Binding var isDraggingSMPTECue: Bool
    @Binding var draggingCuePreviewTime: TimeInterval?
    @Binding var draggingCueStartTime: TimeInterval?
    let viewportWidth: CGFloat
    let totalDuration: TimeInterval
    let isStationary: Bool
    let currentScrollX: () -> CGFloat
    let currentTimeProvider: () -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    
    static func == (lhs: TimelineCuesLaneLayerView, rhs: TimelineCuesLaneLayerView) -> Bool {
        lhs.automationPoints == rhs.automationPoints &&
        lhs.directionalCues == rhs.directionalCues &&
        lhs.smpteCue == rhs.smpteCue &&
        lhs.midiCues == rhs.midiCues &&
        lhs.liveSections == rhs.liveSections &&
        lhs.pixelsPerSecond == rhs.pixelsPerSecond &&
        lhs.totalHeight == rhs.totalHeight &&
        lhs.laneHeight == rhs.laneHeight &&
        lhs.showSMPTECueOnLane == rhs.showSMPTECueOnLane &&
        lhs.isEditingArrangement == rhs.isEditingArrangement &&
        lhs.trimLeadingDuration == rhs.trimLeadingDuration &&
        lhs.trimTrailingDuration == rhs.trimTrailingDuration &&
        lhs.isEditAutomationMode == rhs.isEditAutomationMode &&
        lhs.isEditDirectionalCuesMode == rhs.isEditDirectionalCuesMode &&
        lhs.isEditMIDICuesMode == rhs.isEditMIDICuesMode &&
        lhs.isEditSMPTEMode == rhs.isEditSMPTEMode &&
        lhs.isEditDrawerOpen == rhs.isEditDrawerOpen &&
        lhs.selectedEditDrawerItem == rhs.selectedEditDrawerItem &&
        lhs.selectedAutomationPointId == rhs.selectedAutomationPointId &&
        lhs.selectedDirectionalCueId == rhs.selectedDirectionalCueId &&
        lhs.selectedMIDICueId == rhs.selectedMIDICueId &&
        lhs.editingAutomationPoint?.id == rhs.editingAutomationPoint?.id &&
        lhs.editingDirectionalCue?.id == rhs.editingDirectionalCue?.id &&
        lhs.editingSMPTECue?.id == rhs.editingSMPTECue?.id &&
        lhs.editingMIDICue?.id == rhs.editingMIDICue?.id &&
        lhs.draggingCueId == rhs.draggingCueId &&
        lhs.isDraggingSMPTECue == rhs.isDraggingSMPTECue &&
        lhs.draggingCuePreviewTime == rhs.draggingCuePreviewTime &&
        lhs.isStationary == rhs.isStationary
    }
    
    private func cueDragGesture(
        id: UUID? = nil,
        isSMPTE: Bool = false,
        baseTime: TimeInterval,
        onSelect: @escaping () -> Void,
        onTap: @escaping () -> Void,
        onCommit: @escaping (TimeInterval) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineViewport"))
            .onChanged { value in
                guard !isStationary else { return }
                if draggingCueStartTime == nil {
                    draggingCueStartTime = baseTime
                    if isSMPTE {
                        isDraggingSMPTECue = true
                        draggingCueId = nil
                    } else {
                        draggingCueId = id
                        isDraggingSMPTECue = false
                    }
                    onSelect()
                }
                let dist = hypot(value.translation.width, value.translation.height)
                guard dist >= 3.0 || draggingCuePreviewTime != nil else { return }
                
                let viewportX = value.location.x
                let rawTarget = TimeInterval((viewportX - currentScrollX()) / max(1.0, pixelsPerSecond))
                draggingCuePreviewTime = engine.snapTimeToBeatGrid(rawTarget)
                
                if engine.playbackState != .playing {
                    let maxDur = totalDuration > 0 ? totalDuration : 300.0
                    let nowTime = currentTimeProvider()
                    if viewportX < 36 {
                        onSeek(max(0.0, nowTime - 0.15))
                    } else if viewportX > viewportWidth - 36 {
                        onSeek(min(maxDur, nowTime + 0.15))
                    }
                }
            }
            .onEnded { value in
                defer {
                    draggingCueId = nil
                    isDraggingSMPTECue = false
                    draggingCuePreviewTime = nil
                    draggingCueStartTime = nil
                }
                guard !isStationary else { return }
                if let snapped = draggingCuePreviewTime {
                    onCommit(snapped)
                } else {
                    onTap()
                }
            }
    }
    
    var body: some View {
        let laneTop = totalHeight - laneHeight
        let upperRowY = laneTop + 6.5
        let lowerRowY = laneTop + 16.5
        let isAnyCueInteractiveMode = isEditAutomationMode || isEditDirectionalCuesMode || isEditMIDICuesMode || isEditSMPTEMode
        
        if !isAnyCueInteractiveMode {
            // Fast single-layer Canvas pass during normal playback/viewing and section editing
            Canvas { context, _ in
                let autoColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                for point in automationPoints {
                    let isTrimmedOut = engine.isAutomationPointTrimmedOut(point)
                    if isTrimmedOut && !isEditingArrangement { continue }
                    let cueX = CGFloat(engine.displayTime(forAutomationPoint: point)) * pixelsPerSecond
                    let rect = CGRect(x: cueX - 3.5, y: upperRowY - 3.5, width: 7.0, height: 7.0)
                    context.fill(Path(ellipseIn: rect), with: .color(autoColor.opacity(isTrimmedOut ? 0.32 : 1.0)))
                }
                
                let dirColor = Color(red: 0.0, green: 0.85, blue: 0.98)
                for cue in directionalCues {
                    let isTrimmedOut = engine.isDirectionalCueTrimmedOut(cue)
                    if isTrimmedOut && !isEditingArrangement { continue }
                    let cueX = CGFloat(engine.displayTime(forDirectionalCue: cue)) * pixelsPerSecond
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: cueX, y: upperRowY - 4.5))
                    diamond.addLine(to: CGPoint(x: cueX + 4.5, y: upperRowY))
                    diamond.addLine(to: CGPoint(x: cueX, y: upperRowY + 4.5))
                    diamond.addLine(to: CGPoint(x: cueX - 4.5, y: upperRowY))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(dirColor.opacity(isTrimmedOut ? 0.32 : 1.0)))
                }
                
                if showSMPTECueOnLane, let smpte = smpteCue {
                    let cueX = CGFloat(smpte.time) * pixelsPerSecond
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: cueX, y: upperRowY - 4.8))
                    diamond.addLine(to: CGPoint(x: cueX + 4.8, y: upperRowY))
                    diamond.addLine(to: CGPoint(x: cueX, y: upperRowY + 4.8))
                    diamond.addLine(to: CGPoint(x: cueX - 4.8, y: upperRowY))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(autoColor))
                }
                
                for cue in midiCues {
                    let isTrimmedOut = engine.isMIDICueTrimmedOut(cue)
                    if isTrimmedOut && !isEditingArrangement { continue }
                    let cueX = CGFloat(engine.displayTime(forMIDICue: cue)) * pixelsPerSecond
                    var tri = Path()
                    tri.move(to: CGPoint(x: cueX, y: lowerRowY - 3.5))
                    tri.addLine(to: CGPoint(x: cueX + 5.0, y: lowerRowY + 3.5))
                    tri.addLine(to: CGPoint(x: cueX - 5.0, y: lowerRowY + 3.5))
                    tri.closeSubpath()
                    context.fill(tri, with: .color(cue.bus.color.opacity(isTrimmedOut ? 0.32 : 1.0)))
                }
            }
            .allowsHitTesting(false)
        } else {
        ZStack(alignment: .topLeading) {
            // 1. Automation Points (Green Circles in Upper Half of Lane)
            ForEach(automationPoints) { point in
                let isTrimmedOut = engine.isAutomationPointTrimmedOut(point)
                if !isTrimmedOut || isEditingArrangement {
                    let baseTime = engine.displayTime(forAutomationPoint: point)
                    let dispTime = (draggingCueId == point.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    Circle()
                        .fill(Color(red: 0.25, green: 0.88, blue: 0.45))
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.black.opacity(0.65), radius: 1, x: 0, y: 1)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                        .opacity(isTrimmedOut ? 0.32 : 1.0)
                        .position(x: cueX, y: upperRowY)
                        .highPriorityGesture(cueDragGesture(
                            id: point.id,
                            baseTime: baseTime,
                            onSelect: { engine.selectAutomationPoint(id: point.id) },
                            onTap: {
                                if isEditAutomationMode {
                                    isAddingAutomationAtPlayhead = false
                                    engine.selectAutomationPoint(id: point.id)
                                    editingAutomationPoint = point
                                } else {
                                    onSeek(dispTime)
                                }
                            },
                            onCommit: { newTime in engine.moveAutomationPoint(id: point.id, toDisplayTime: newTime) }
                        ))
                    .help("Automation: \(point.name)")
                    .contextMenu {
                        Button("Edit Automation") {
                            engine.selectAutomationPoint(id: point.id)
                            isAddingAutomationAtPlayhead = false
                            editingAutomationPoint = point
                        }
                        Button("Nudge Automation") {
                            engine.selectAutomationPoint(id: point.id)
                            engine.isNudgingAutomation = true
                        }
                        Divider()
                        Button("Delete Automation", role: .destructive) {
                            engine.removeAutomationPoint(id: point.id)
                        }
                    }
                }
            }
            
            // 2. Directional Cues (Cyan Diamonds in Upper Half of Lane)
            ForEach(directionalCues) { cue in
                let isTrimmedOut = engine.isDirectionalCueTrimmedOut(cue)
                if !isTrimmedOut || isEditingArrangement {
                    let baseTime = engine.displayTime(forDirectionalCue: cue)
                    let dispTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    Rectangle()
                        .fill(Color(red: 0.0, green: 0.85, blue: 0.98))
                        .frame(width: 6.5, height: 6.5)
                        .rotationEffect(.degrees(45))
                        .shadow(color: Color.black.opacity(0.65), radius: 1, x: 0, y: 1)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                        .opacity(isTrimmedOut ? 0.32 : 1.0)
                        .position(x: cueX, y: upperRowY)
                        .highPriorityGesture(cueDragGesture(
                            id: cue.id,
                            baseTime: baseTime,
                            onSelect: { engine.selectedDirectionalCueId = cue.id },
                            onTap: {
                                if isEditDirectionalCuesMode {
                                    isAddingDirectionalCueAtPlayhead = false
                                    if selectedDirectionalCueId != cue.id {
                                        engine.selectedDirectionalCueId = cue.id
                                    }
                                    editingDirectionalCue = cue
                                } else {
                                    onSeek(dispTime)
                                }
                            },
                            onCommit: { newTime in engine.moveDirectionalCue(id: cue.id, toDisplayTime: newTime) }
                        ))
                    .help("Directional Cue: \(cue.label)")
                    .contextMenu {
                        Button("Edit Directional Cue (\(cue.label))...") {
                            engine.selectedDirectionalCueId = cue.id
                            isAddingDirectionalCueAtPlayhead = false
                            editingDirectionalCue = cue
                        }
                        Button("Nudge Directional Cue") {
                            engine.selectedDirectionalCueId = cue.id
                            engine.isNudgingDirectionalCue = true
                        }
                        Divider()
                        Button("Delete Directional Cue", role: .destructive) {
                            engine.removeDirectionalCue(id: cue.id)
                        }
                    }
                }
            }
            
            // 3. SMPTE Cue (Green Diamond in Upper Half of Lane)
            if showSMPTECueOnLane, let smpte = smpteCue {
                let baseTime = smpte.time
                let dispTime = (isDraggingSMPTECue ? draggingCuePreviewTime : nil) ?? baseTime
                let cueX = CGFloat(dispTime) * pixelsPerSecond
                Rectangle()
                    .fill(Color(red: 0.25, green: 0.88, blue: 0.45))
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45))
                    .shadow(color: Color.black.opacity(0.65), radius: 1, x: 0, y: 1)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
                    .position(x: cueX, y: upperRowY)
                    .highPriorityGesture(cueDragGesture(
                        isSMPTE: true,
                        baseTime: baseTime,
                        onSelect: {},
                        onTap: {
                            let isSMPTESelected = isEditSMPTEMode && isEditDrawerOpen && selectedEditDrawerItem == .smpte
                            if isSMPTESelected {
                                isAddingSMPTECueAtPlayhead = false
                                editingSMPTECue = smpte
                            } else {
                                onSeek(dispTime)
                            }
                        },
                        onCommit: { newTime in engine.moveSMPTECue(to: newTime, snapToGrid: false) }
                    ))
                .help("SMPTE Cue Marker (Start: \(smpte.displayTimeStart))")
                .contextMenu {
                    Button("Edit SMPTE Cue") {
                        isAddingSMPTECueAtPlayhead = false
                        editingSMPTECue = smpte
                    }
                    Button("Nudge SMPTE Earlier (1 Beat)") {
                        engine.nudgeSMPTECue(earlier: true)
                    }
                    Button("Nudge SMPTE Later (1 Beat)") {
                        engine.nudgeSMPTECue(earlier: false)
                    }
                    Divider()
                    Button("Delete SMPTE Cue", role: .destructive) {
                        engine.removeSMPTECue()
                    }
                }
            }
            
            // 4. MIDI Cues (Orange Upward-Pointing Triangles in Lower Half of Lane)
            ForEach(midiCues) { cue in
                let isTrimmedOut = engine.isMIDICueTrimmedOut(cue)
                if !isTrimmedOut || isEditingArrangement {
                    let baseTime = engine.displayTime(forMIDICue: cue)
                    let dispTime = (draggingCueId == cue.id ? draggingCuePreviewTime : nil) ?? baseTime
                    let cueX = CGFloat(dispTime) * pixelsPerSecond
                    UpwardTriangle()
                        .fill(cue.bus.color)
                        .frame(width: 10, height: 7)
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                        .opacity(isTrimmedOut ? 0.32 : 1.0)
                        .position(x: cueX, y: lowerRowY)
                        .highPriorityGesture(cueDragGesture(
                            id: cue.id,
                            baseTime: baseTime,
                            onSelect: { engine.selectedMIDICueId = cue.id },
                            onTap: {
                                if isEditMIDICuesMode {
                                    isAddingMIDICueAtPlayhead = false
                                    if selectedMIDICueId != cue.id {
                                        engine.selectedMIDICueId = cue.id
                                    }
                                    editingMIDICue = cue
                                } else {
                                    onSeek(dispTime)
                                }
                            },
                            onCommit: { newTime in engine.moveMIDICue(id: cue.id, toDisplayTime: newTime) }
                        ))
                    .help(cue.displaySummary)
                    .contextMenu {
                        Button("Edit MIDI Cue (\(cue.displaySummary))...") {
                            engine.selectedMIDICueId = cue.id
                            isAddingMIDICueAtPlayhead = false
                            editingMIDICue = cue
                        }
                        Button("Nudge MIDI Cue") {
                            engine.selectedMIDICueId = cue.id
                            engine.isNudgingMIDICue = true
                        }
                        Button("Test MIDI Cue") {
                            MIDICueEngine.shared.fire(cue: cue)
                        }
                        Divider()
                        Button("Delete MIDI Cue", role: .destructive) {
                            engine.removeMIDICue(id: cue.id)
                        }
                    }
                }
            }
        }
        }
    }
}

// MARK: - Individual Song Section View

struct SingleSectionView: View {
    let section: SongSection
    var sectionIndex: Int = 0
    let width: CGFloat
    let height: CGFloat
    let isLooped: Bool
    var isEditMode: Bool = false
    var pixelsPerSecond: CGFloat = 40.0
    let loopMode: MultitrackAudioEngine.LoopMode
    var isQueuedNext: Bool = false
    var isBeatFlash: Bool = false
    let engine: MultitrackAudioEngine
    @Binding var activePopoverSection: SongSection?
    @Binding var activeMIDICueSection: SongSection?
    var bpm: Double = 120.0
    let onSeek: () -> Void
    let onToggleLoop: () -> Void
    var onAddSectionAfter: (() -> Void)? = nil
    var onQueueSection: (() -> Void)? = nil
    
    @State private var showNarrowMorePopover: Bool = false
    
    var body: some View {
        let leftTrimW = (isEditMode && section.leadingTrimDuration > 0.001) ? CGFloat(section.leadingTrimDuration) * pixelsPerSecond : 0.0
        let rightTrimW = (isEditMode && section.trailingTrimDuration > 0.001) ? CGFloat(section.trailingTrimDuration) * pixelsPerSecond : 0.0
        
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isQueuedNext ? (isBeatFlash ? Color(red: 0.20, green: 0.75, blue: 0.98).opacity(0.45) : Color(red: 0.12, green: 0.60, blue: 0.90).opacity(0.30)) : section.color.opacity(isLooped ? 0.28 : 0.12))
            
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isQueuedNext ? (isBeatFlash ? Color.white : Color(red: 0.25, green: 0.85, blue: 1.0)) : (isLooped ? Color.yellow : section.color.opacity(0.65)),
                    lineWidth: (isQueuedNext || isLooped) ? 2.0 : 1.0
                )
                .shadow(color: (isQueuedNext && isBeatFlash) ? Color(red: 0.25, green: 0.85, blue: 1.0).opacity(0.7) : Color.clear, radius: (isQueuedNext && isBeatFlash) ? 5 : 0)
            
            // Grayed-out overlay for trimmed regions in Edit Mode (matching Photo 3)
            if leftTrimW > 0.5 {
                Rectangle()
                    .fill(Color.black.opacity(0.68))
                    .frame(width: min(width, leftTrimW), height: height)
                    .allowsHitTesting(false)
            }
            if rightTrimW > 0.5 {
                Rectangle()
                    .fill(Color.black.opacity(0.68))
                    .frame(width: min(width, rightTrimW), height: height)
                    .offset(x: max(0, width - rightTrimW))
                    .allowsHitTesting(false)
            }
            
            HStack {
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(isBeatFlash ? Color.white : (isQueuedNext ? Color(red: 0.12, green: 0.50, blue: 0.70) : Color(red: 0.08, green: 0.09, blue: 0.11)))
                            .frame(width: 22, height: 22)
                        
                        Circle()
                            .stroke(isBeatFlash ? Color.white : (isQueuedNext ? Color(red: 0.25, green: 0.85, blue: 1.0) : section.color), lineWidth: isQueuedNext ? 2.0 : 1.5)
                            .frame(width: 22, height: 22)
                            .shadow(color: isBeatFlash ? Color.white.opacity(0.9) : Color.clear, radius: isBeatFlash ? 4 : 0)
                        
                        Text(section.displayAbbreviation.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(isBeatFlash ? Color.black : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .frame(width: 20, height: 20, alignment: .center)
                    }
                    .frame(width: 22, height: 22)
                    
                    if width > 65 && section.effectiveIsClickSection {
                        Image(systemName: "metronome")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(red: 0.35, green: 0.78, blue: 1.0))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.90))
                            .cornerRadius(3)
                    }
                    
                    if isQueuedNext {
                        Text("NEXT")
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(isBeatFlash ? Color.white : Color(red: 0.25, green: 0.85, blue: 1.0))
                            .cornerRadius(3)
                            .shadow(color: Color(red: 0.25, green: 0.85, blue: 1.0).opacity(0.6), radius: 3)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if engine.playbackState == .playing {
                        engine.queueNextSection(section)
                        onQueueSection?()
                    } else {
                        onSeek()
                    }
                }
                .onTapGesture(count: 1) {
                    if engine.isEditingArrangement {
                        activePopoverSection = section
                    } else if engine.isEditMIDICuesMode {
                        activeMIDICueSection = section
                    } else if engine.playbackState != .playing {
                        onSeek()
                    }
                }
                .background {
                    if activePopoverSection?.id == section.id {
                        Color.clear
                            .popover(
                                isPresented: Binding(
                                    get: { activePopoverSection?.id == section.id },
                                    set: { if !$0 { activePopoverSection = nil } }
                                ),
                                arrowEdge: .bottom
                            ) {
                                EditSongSectionPopoverView(
                                    engine: engine,
                                    section: section,
                                    onDismiss: { activePopoverSection = nil },
                                    onEnterTrimMode: {
                                        activePopoverSection = nil
                                        engine.beginTrimming(section: section)
                                    }
                                )
                            }
                    }
                    if activeMIDICueSection?.id == section.id {
                        Color.clear
                            .popover(
                                isPresented: Binding(
                                    get: { activeMIDICueSection?.id == section.id },
                                    set: { if !$0 { activeMIDICueSection = nil } }
                                ),
                                arrowEdge: .bottom
                            ) {
                                SectionMIDICueActionPopover(
                                    engine: engine,
                                    section: section,
                                    onDismiss: { activeMIDICueSection = nil }
                                )
                            }
                    }
                }
                
                Spacer(minLength: 0)
                
                if width < 64 {
                    Button(action: { showNarrowMorePopover.toggle() }) {
                        HStack(spacing: 2) {
                            if isLooped {
                                Image(systemName: loopMode == .infinite ? "infinity" : "repeat")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(isLooped ? Color(red: 1.0, green: 0.85, blue: 0.20) : Color(white: 0.85))
                        .frame(height: 20)
                        .padding(.horizontal, 4)
                        .background(isLooped ? Color(red: 0.15, green: 0.12, blue: 0.02) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.85))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isLooped ? Color(red: 1.0, green: 0.85, blue: 0.20) : Color.white.opacity(0.25), lineWidth: isLooped ? 1.5 : 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Section Options: \(section.name)")
                    .popover(isPresented: $showNarrowMorePopover, arrowEdge: .bottom) {
                        narrowSectionMorePopover
                    }
                } else {
                    Button(action: onToggleLoop) {
                        HStack(spacing: 3) {
                            Image(systemName: "repeat")
                                .font(.system(size: isLooped ? 13 : 11, weight: .bold))
                            if isLooped {
                                if loopMode == .single {
                                    Text("1x")
                                        .font(.system(size: 11, weight: .bold))
                                } else {
                                    Image(systemName: "infinity")
                                        .font(.system(size: 15, weight: .heavy))
                                }
                            }
                        }
                        .foregroundColor(isLooped ? Color(red: 1.0, green: 0.85, blue: 0.20) : Color(white: 0.80))
                        .frame(height: 22)
                        .padding(.horizontal, isLooped ? 6 : 4)
                        .background(isLooped ? Color(red: 0.15, green: 0.12, blue: 0.02) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.85))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isLooped ? Color(red: 1.0, green: 0.85, blue: 0.20) : Color.white.opacity(0.25), lineWidth: isLooped ? 1.5 : 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Loop Section: \(section.name)")
                }
            }
            .padding(.horizontal, width < 64 ? 3 : 5)
            .padding(.top, 5)
        }
        .frame(width: max(24, width - 2), height: height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if engine.playbackState == .playing {
                engine.queueNextSection(section)
                onQueueSection?()
            } else {
                onSeek()
            }
        }
        .onTapGesture(count: 1) {
            if engine.isEditingArrangement {
                activePopoverSection = section
            } else if engine.playbackState != .playing {
                onSeek()
            }
        }
    }
    
    private var narrowSectionMorePopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(section.color)
                    .frame(width: 8, height: 8)
                Text(section.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(section.measureCount) bars")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.55))
            }
            .padding(.bottom, 2)
            
            Divider()
                .background(Color(white: 0.22))
            
            Button(action: {
                showNarrowMorePopover = false
                if engine.playbackState == .playing {
                    engine.queueNextSection(section)
                    onQueueSection?()
                } else {
                    onSeek()
                }
            }) {
                Label(engine.playbackState == .playing ? "Queue Next" : "Jump to Section", systemImage: engine.playbackState == .playing ? "arrow.right.to.line" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            
            Button(action: {
                showNarrowMorePopover = false
                engine.setSectionLoop(section, mode: .single)
            }) {
                Label("Loop Section (1x)", systemImage: "repeat.1")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background((isLooped && loopMode == .single) ? Color.yellow.opacity(0.18) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor((isLooped && loopMode == .single) ? Color.yellow : .white)
            
            Button(action: {
                showNarrowMorePopover = false
                engine.setSectionLoop(section, mode: .infinite)
            }) {
                Label("Infinite Loop", systemImage: "infinity")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background((isLooped && loopMode == .infinite) ? Color.yellow.opacity(0.18) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor((isLooped && loopMode == .infinite) ? Color.yellow : .white)
            
            if engine.isEditingArrangement {
                Divider()
                    .background(Color(white: 0.22))
                
                Button(action: {
                    showNarrowMorePopover = false
                    activePopoverSection = section
                }) {
                    Label("Edit Section...", systemImage: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                
                if engine.isEditSongMapMode {
                    Button(action: {
                        showNarrowMorePopover = false
                        onAddSectionAfter?()
                    }) {
                        Label("Add Section After...", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    
                    Button(action: {
                        showNarrowMorePopover = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            engine.removeSection(at: sectionIndex)
                        }
                    }) {
                        Label("Remove Section", systemImage: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.40))
                } else if engine.isEditSectionsMode && sectionIndex > 0 {
                    Button(action: {
                        showNarrowMorePopover = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            engine.removeSectionLabel(id: section.id)
                        }
                    }) {
                        Label("Remove Section Label", systemImage: "tag.slash")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.40))
                }
            }
        }
        .padding(10)
        .frame(width: 190)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
    }
}

// MARK: - Section MIDI Cue Action Popover (Copy & Paste with Auto Velocity Adjustment)

struct SectionMIDICueActionPopover: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let section: SongSection
    let onDismiss: () -> Void
    
    var body: some View {
        let sectionCues = engine.midiCues(in: section)
        let hasCopied = (engine.copiedMIDICuesClipboard != nil && !engine.copiedMIDICuesClipboard!.isEmpty)
        
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(section.color, lineWidth: 1.4)
                        .frame(width: 20, height: 20)
                    Text(section.displayAbbreviation)
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(sectionCues.count) MIDI \(sectionCues.count == 1 ? "Cue" : "Cues") in section")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(white: 0.55))
                }
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))
            
            Divider()
                .background(Color(white: 0.20))
            
            VStack(spacing: 1) {
                // 1. Copy MIDI Cues
                Button(action: {
                    engine.copyMIDICues(from: section)
                    onDismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(sectionCues.isEmpty ? Color(white: 0.35) : Color(red: 0.25, green: 0.75, blue: 1.0))
                            .frame(width: 16)
                        
                        Text("Copy MIDI Cues")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(sectionCues.isEmpty ? Color(white: 0.40) : .white)
                        
                        Spacer()
                        
                        if !sectionCues.isEmpty {
                            Text("(\(sectionCues.count))")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.50))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sectionCues.isEmpty)
                
                Divider()
                    .background(Color(white: 0.18))
                
                // 2. Paste with Auto-Adjust Velocity (N+1, N+2, ...)
                Button(action: {
                    engine.pasteMIDICues(to: section, autoAdjustVelocity: true)
                    onDismiss()
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(!hasCopied ? Color(white: 0.35) : Color(red: 0.98, green: 0.65, blue: 0.20))
                                .frame(width: 16)
                            
                            Text("Paste & Auto-Adjust Velocity")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(!hasCopied ? Color(white: 0.40) : .white)
                            
                            Spacer()
                        }
                        
                        Text("Auto-increments velocity (N+1, N+2...) from prior cue on same bus")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.45))
                            .padding(.leading, 24)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasCopied)
                
                Divider()
                    .background(Color(white: 0.18))
                
                // 3. Paste Original Cues
                Button(action: {
                    engine.pasteMIDICues(to: section, autoAdjustVelocity: false)
                    onDismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(!hasCopied ? Color(white: 0.35) : Color(red: 0.25, green: 0.85, blue: 0.55))
                            .frame(width: 16)
                        
                        Text("Paste Original Velocities")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(!hasCopied ? Color(white: 0.40) : .white)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasCopied)
                
                // Clipboard status footer if clipboard has cues
                if let clip = engine.copiedMIDICuesClipboard, let srcName = engine.copiedSourceSectionName {
                    Divider()
                        .background(Color(white: 0.18))
                    
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                        Text("Clipboard: \(clip.count) cues copied from \(srcName)")
                            .font(.system(size: 8.5))
                            .foregroundColor(Color(white: 0.55))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.08))
                }
            }
        }
        .frame(width: 250)
        .background(Color(red: 0.10, green: 0.11, blue: 0.12))
    }
}

struct AutomationPopoverPresenter: NSViewRepresentable {
    @Binding var isAddingAtPlayhead: Bool
    @Binding var editingPoint: AutomationPoint?
    let targetRect: NSRect?
    let engine: MultitrackAudioEngine
    
    func makeNSView(context: Context) -> SongSectionPopoverPresenter.PopoverAnchorNSView {
        let view = SongSectionPopoverPresenter.PopoverAnchorNSView()
        context.coordinator.anchorView = view
        return view
    }
    
    func updateNSView(_ nsView: SongSectionPopoverPresenter.PopoverAnchorNSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(
            isAddingAtPlayhead: isAddingAtPlayhead,
            editingPoint: editingPoint,
            targetRect: targetRect,
            engine: engine
        ) {
            DispatchQueue.main.async {
                self.isAddingAtPlayhead = false
                self.editingPoint = nil
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: SongSectionPopoverPresenter.PopoverAnchorNSView?
        var popover: NSPopover?
        var currentlyPresentedKey: String?
        var onClose: (() -> Void)?
        private var isProgrammaticClose = false
        
        func closeProgrammatically() {
            guard let p = popover else {
                currentlyPresentedKey = nil
                return
            }
            isProgrammaticClose = true
            p.delegate = nil
            p.close()
            popover = nil
            currentlyPresentedKey = nil
            isProgrammaticClose = false
        }
        
        func update(
            isAddingAtPlayhead: Bool,
            editingPoint: AutomationPoint?,
            targetRect: NSRect?,
            engine: MultitrackAudioEngine,
            onClose: @escaping () -> Void
        ) {
            self.onClose = onClose
            
            let presentationKey: String? = {
                if isAddingAtPlayhead {
                    return "add_automation_playhead"
                } else if let pt = editingPoint {
                    return "edit_automation_\(pt.id.uuidString)"
                }
                return nil
            }()
            
            guard let key = presentationKey, let rect = targetRect else {
                closeProgrammatically()
                return
            }
            
            if let p = popover, currentlyPresentedKey == key {
                if p.isShown {
                    p.positioningRect = rect
                }
                return
            }
            
            closeProgrammatically()
            
            guard let anchorView = anchorView else { return }
            guard anchorView.window != nil else {
                anchorView.onMoveToWindow = { [weak self] in
                    self?.update(isAddingAtPlayhead: isAddingAtPlayhead, editingPoint: editingPoint, targetRect: targetRect, engine: engine, onClose: onClose)
                }
                return
            }
            
            let p = NSPopover()
            p.appearance = NSAppearance(named: .darkAqua)
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            
            let pointTime = editingPoint?.time ?? engine.transportPosition.currentTime
            let contentView = AnyView(AddAutomationPopoverView(
                engine: engine,
                targetTime: pointTime,
                editingPoint: editingPoint
            ) { [weak self] in
                self?.closeProgrammatically()
                self?.onClose?()
            })
            
            let hostingController = NSHostingController(rootView: contentView)
            let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 320, height: 600))
            let finalSize = NSSize(width: max(fittingSize.width, 270), height: max(fittingSize.height, 140))
            hostingController.preferredContentSize = finalSize
            p.contentSize = finalSize
            p.contentViewController = hostingController
            self.popover = p
            self.currentlyPresentedKey = key
            
            let edge: NSRectEdge = isAddingAtPlayhead ? .maxX : .minY
            p.show(relativeTo: rect, of: anchorView, preferredEdge: edge)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard !isProgrammaticClose else { return }
            popover = nil
            currentlyPresentedKey = nil
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
            }
        }
    }
}

// MARK: - Native SMPTE Cue Popover Presenter

struct SMPTEPopoverPresenter: NSViewRepresentable {
    @Binding var isAddingAtPlayhead: Bool
    @Binding var editingCue: SMPTECue?
    let targetRect: NSRect?
    let engine: MultitrackAudioEngine
    
    func makeNSView(context: Context) -> SongSectionPopoverPresenter.PopoverAnchorNSView {
        let view = SongSectionPopoverPresenter.PopoverAnchorNSView()
        context.coordinator.anchorView = view
        return view
    }
    
    func updateNSView(_ nsView: SongSectionPopoverPresenter.PopoverAnchorNSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.update(
            isAddingAtPlayhead: isAddingAtPlayhead,
            editingCue: editingCue,
            targetRect: targetRect,
            engine: engine
        ) {
            DispatchQueue.main.async {
                self.isAddingAtPlayhead = false
                self.editingCue = nil
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: SongSectionPopoverPresenter.PopoverAnchorNSView?
        var popover: NSPopover?
        var currentlyPresentedKey: String?
        var onClose: (() -> Void)?
        private var isProgrammaticClose = false
        
        func closeProgrammatically() {
            guard let p = popover else {
                currentlyPresentedKey = nil
                return
            }
            isProgrammaticClose = true
            p.delegate = nil
            p.close()
            popover = nil
            currentlyPresentedKey = nil
            isProgrammaticClose = false
        }
        
        func update(
            isAddingAtPlayhead: Bool,
            editingCue: SMPTECue?,
            targetRect: NSRect?,
            engine: MultitrackAudioEngine,
            onClose: @escaping () -> Void
        ) {
            self.onClose = onClose
            
            let presentationKey: String? = {
                if isAddingAtPlayhead {
                    return "add_smpte_playhead"
                } else if let cue = editingCue {
                    return "edit_smpte_\(cue.id.uuidString)"
                }
                return nil
            }()
            
            guard let key = presentationKey, let rect = targetRect else {
                closeProgrammatically()
                return
            }
            
            if let p = popover, currentlyPresentedKey == key {
                if p.isShown {
                    p.positioningRect = rect
                }
                return
            }
            
            closeProgrammatically()
            
            guard let anchorView = anchorView else { return }
            guard anchorView.window != nil else {
                anchorView.onMoveToWindow = { [weak self] in
                    self?.update(isAddingAtPlayhead: isAddingAtPlayhead, editingCue: editingCue, targetRect: targetRect, engine: engine, onClose: onClose)
                }
                return
            }
            
            let p = NSPopover()
            p.appearance = NSAppearance(named: .darkAqua)
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            
            let cueTime = editingCue?.time ?? engine.transportPosition.currentTime
            let contentView = AnyView(AddSMPTEPopoverView(
                engine: engine,
                targetTime: cueTime,
                editingCue: editingCue
            ) { [weak self] in
                self?.closeProgrammatically()
                self?.onClose?()
            })
            
            let hostingController = NSHostingController(rootView: contentView)
            let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 320, height: 600))
            let finalSize = NSSize(width: max(fittingSize.width, 270), height: max(fittingSize.height, 140))
            hostingController.preferredContentSize = finalSize
            p.contentSize = finalSize
            p.contentViewController = hostingController
            self.popover = p
            self.currentlyPresentedKey = key
            
            let edge: NSRectEdge = isAddingAtPlayhead ? .maxX : .minY
            p.show(relativeTo: rect, of: anchorView, preferredEdge: edge)
        }
        
        func popoverDidClose(_ notification: Notification) {
            guard !isProgrammaticClose else { return }
            popover = nil
            currentlyPresentedKey = nil
            DispatchQueue.main.async { [weak self] in
                self?.onClose?()
            }
        }
    }
}
