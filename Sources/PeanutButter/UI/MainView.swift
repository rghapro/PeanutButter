import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main PeanutButter Workspace console UI
public struct MainView: View {
    @StateObject private var engine = MultitrackAudioEngine()
    @ObservedObject private var midiEngine = MIDICueEngine.shared
    @ObservedObject private var midiManager = MIDIMappingManager.shared
    @ObservedObject private var keyboardManager = KeyboardMappingManager.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    
    // UI Drawer & Modal State
    @State private var isSettingsMenuOpen: Bool = false
    @State private var isSetlistMenuOpen: Bool = false
    @State private var expandedBusIds: Set<UUID> = []
    @State private var activeSongCardMenuSongId: UUID? = nil
    @State private var activeTransitionSongIndex: Int? = nil
    @State private var isTopLeftMIDICuesMenuOpen: Bool = false
    @State private var isTopLeftDirectionalCuesMenuOpen: Bool = false
    @State private var isTopLeftAutomationMenuOpen: Bool = false
    @State private var isTopLeftSMPTEMenuOpen: Bool = false
    @State private var isSongBuilderPresented: Bool = false
    @State private var isSongLibraryBrowserPresented: Bool = false
    @State private var isOfflineBouncePresented: Bool = false
    @State private var isPlaybackImportWizardPresented: Bool = false
    @State private var isCreatingNewSongInBuilder: Bool = false
    @State private var previousSongIndexBeforeNewSong: Int? = nil
    @State private var isBussesDrawerPresented: Bool = false
    @State private var isFileImporterPresented: Bool = false
    @State private var statusMessage: String?
    
    // Drag-and-drop song reordering state
    @State private var draggedSong: Song?
    
    // Drag-and-drop track reordering state
    @State private var draggedTrack: StemTrack?
    
    // Horizontal Mixer Scroll Tracker State (Scrollbar on top of tracks)
    @State private var mixerScrollOffset: CGFloat = 0
    @State private var mixerContentWidth: CGFloat = 0
    @State private var mixerContainerWidth: CGFloat = 0
    @State private var mixerScrollView: NSScrollView?
    
    // Global Event Monitor for Reliable Keyboard Shortcuts
    @State private var eventMonitor: Any?
    
    public init() {}
    
    // MARK: - Non-Edit Menu & Sheet Stationary Waveform Tracking
    private var isNonEditMenuOpen: Bool {
        isSettingsMenuOpen ||
        isSetlistMenuOpen ||
        activeSongCardMenuSongId != nil ||
        isSongBuilderPresented ||
        isSongLibraryBrowserPresented ||
        isOfflineBouncePresented ||
        isPlaybackImportWizardPresented ||
        isBussesDrawerPresented ||
        isFileImporterPresented ||
        activeTransitionSongIndex != nil ||
        updateManager.isUpdateSheetPresented
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // Main Playback Console
            VStack(spacing: 0) {
                // Tier 1: Top Header & Hardware Transport Bar
                topTransportBarView
                
                // Tier 2: Setlist Song Carousel Row (continuous slate background with Tier 1)
                setlistSongCarouselView
                
                // Tier 3: Fixed Playhead, Scrolling Aggregate Waveform & Bottom MIDI Cues Track
                VStack(spacing: 0) {
                    LiveWaveformTimelineContainer(
                        engine: engine,
                        clock: engine.transportClock,
                        isStationary: false
                    )
                    .frame(height: 255)
                    .overlay(
                        Group {
                            if engine.isEditMIDIMappingMode {
                                Color(red: 0.12, green: 0.22, blue: 0.35).opacity(0.35)
                                    .allowsHitTesting(false)
                            } else if engine.isEditKeyboardMappingMode {
                                Color(red: 0.45, green: 0.22, blue: 0.05).opacity(0.35)
                                    .allowsHitTesting(false)
                            }
                        }
                    )
                }
                .background(Color(red: 0.05, green: 0.06, blue: 0.07))
                
                Divider()
                    .background(Color(white: 0.14))
                
                // Tier 4: Bottom Mixer Rack + Pinned Master & Action Toolbar + Edit Drawer Overlay
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: 0) {
                        if engine.mixerMode == .padPlayer {
                            PadPlayerView(engine: engine)
                        } else {
                            // Horizontally scrolling Channel Strips with Scroller rendered on top of channel strips at bottom of screen
                            ZStack(alignment: .bottom) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    if engine.mixerMode == .busses {
                                        // 16 Sub-Mix Busses Mode (MultiTracks Playback Style)
                                        ForEach(engine.busses) { bus in
                                            busStripRow(for: bus)
                                        }
                                    } else {
                                        // Individual Stem Tracks Mode
                                        if engine.tracks.isEmpty {
                                            // Blank session placeholders matching MultiTracks Playback
                                            ForEach(0..<12, id: \.self) { _ in
                                                EmptyFaderStripPlaceholderView()
                                            }
                                        } else {
                                            ForEach(Array(engine.tracks.enumerated()), id: \.element.id) { index, track in
                                                ChannelStripView(
                                                    track: track,
                                                    engine: engine,
                                                    index: index + 1,
                                                    isBeingDragged: draggedTrack?.id == track.id,
                                                    onParametersChanged: {
                                                        engine.updateTrackParameters(track: track)
                                                    },
                                                    onDelete: {
                                                        engine.removeTrack(id: track.id)
                                                    }
                                                )
                                                .onDrag {
                                                    draggedTrack = track
                                                    return NSItemProvider(object: track.id.uuidString as NSString)
                                                }
                                                .onDrop(of: [.text], delegate: TrackDropDelegate(
                                                    targetTrack: track,
                                                    draggedTrack: $draggedTrack,
                                                    onMove: { fromId, toId in
                                                        if let fromIdx = engine.tracks.firstIndex(where: { $0.id == fromId }),
                                                           let toIdx = engine.tracks.firstIndex(where: { $0.id == toId }) {
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                engine.moveTrack(from: fromIdx, to: toIdx)
                                                            }
                                                        }
                                                    }
                                                ))
                                                
                                                // Click Subdivision Drawer (Accent, 1/4, 1/8, 1/16) - Matching Photo 2
                                                let isClickTrack = (track.role == .click || StemCategory.category(for: track.name, role: track.role) == .click)
                                                if isClickTrack && engine.isClickSubdivisionDrawerExpanded {
                                                    ClickSubdivisionChannelStripView(subdivision: .accent, engine: engine)
                                                        .transition(.asymmetric(
                                                            insertion: .opacity.combined(with: .move(edge: .leading)),
                                                            removal: .opacity.combined(with: .move(edge: .leading))
                                                        ))
                                                    ClickSubdivisionChannelStripView(subdivision: .quarter, engine: engine)
                                                        .transition(.asymmetric(
                                                            insertion: .opacity.combined(with: .move(edge: .leading)),
                                                            removal: .opacity.combined(with: .move(edge: .leading))
                                                        ))
                                                    ClickSubdivisionChannelStripView(subdivision: .eighth, engine: engine)
                                                        .transition(.asymmetric(
                                                            insertion: .opacity.combined(with: .move(edge: .leading)),
                                                            removal: .opacity.combined(with: .move(edge: .leading))
                                                        ))
                                                    ClickSubdivisionChannelStripView(subdivision: .sixteenth, engine: engine)
                                                        .transition(.asymmetric(
                                                            insertion: .opacity.combined(with: .move(edge: .leading)),
                                                            removal: .opacity.combined(with: .move(edge: .leading))
                                                        ))
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: .infinity)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(MixerScrollTracker(
                                    scrollOffset: $mixerScrollOffset,
                                    contentWidth: $mixerContentWidth,
                                    containerWidth: $mixerContainerWidth,
                                    scrollViewRef: $mixerScrollView
                                ))
                            }
                            .frame(maxHeight: .infinity)
                            .background(Color(red: 0.06, green: 0.07, blue: 0.08))
                            
                            // Bottom Overlay Scroll Bar (rendered on top of the channel strips at the bottom of the screen)
                            if mixerContentWidth > mixerContainerWidth && mixerContainerWidth > 0 {
                                BottomMixerScrollerOverlayView(
                                    scrollOffset: $mixerScrollOffset,
                                    contentWidth: mixerContentWidth,
                                    containerWidth: mixerContainerWidth,
                                    onScrolled: { newOffset in
                                        guard let sv = mixerScrollView else { return }
                                        let maxScroll = max(0, mixerContentWidth - mixerContainerWidth)
                                        let clampedOffset = max(0, min(maxScroll, newOffset))
                                        sv.contentView.scroll(to: NSPoint(x: clampedOffset, y: 0))
                                        sv.reflectScrolledClipView(sv.contentView)
                                    }
                                )
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                            }
                        }
                    }
                    
                    Divider()
                            .background(Color(white: 0.18))
                        
                        // Pinned Right Action Toolbar & Master Strip
                        MasterMixerControlView(
                            engine: engine,
                            onOpenBussesSheet: {
                                isBussesDrawerPresented = true
                            },
                            onTogglePadPlayer: {
                                engine.togglePadPlayer()
                                if engine.isEditAutomationMode {
                                    engine.recordAutomationPadActive(engine.isPadActive)
                                }
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Bottom-Right Edit Menu Drawer (MultiTracks Playback Style)
                    if engine.isEditDrawerOpen {
                        Group {
                            if !engine.isEditDrawerCollapsed {
                                editBottomDrawerView
                                    .padding(.trailing, 10)
                                    .padding(.bottom, 8)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            } else {
                                Button(action: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        engine.expandEditDrawer()
                                    }
                                }) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(Color(white: 0.85))
                                        .frame(width: 32, height: 38)
                                        .background(Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.black.opacity(0.8), lineWidth: 1)
                                        )
                                        .shadow(color: Color.black.opacity(0.65), radius: 6, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 10)
                                .padding(.bottom, 8)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                                .help("Show Edit Drawer")
                            }
                        }
                        .zIndex(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: engine.isEditDrawerOpen)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: engine.isEditDrawerCollapsed)
                .disabled(engine.trimmingSection != nil)
                .opacity(engine.trimmingSection != nil ? 0.35 : 1.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 1120, minHeight: 700)
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            if let banner = engine.audioDeviceBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan)
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.10).opacity(0.95))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cyan.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
                .padding(.top, 12)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if updateManager.shouldShowTopBanner && engine.playbackState != .playing {
                AppUpdateTopBannerView(updateManager: updateManager)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if engine.isShowingCustomClickSampleManager || engine.isShowingCustomGuideSampleManager || updateManager.isUpdateSheetPresented {
                ZStack {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                engine.isShowingCustomClickSampleManager = false
                                engine.isShowingCustomGuideSampleManager = false
                                if case .downloading = updateManager.phase {
                                    // Keep sheet open while actively showing progress unless explicitly closed
                                } else {
                                    updateManager.isUpdateSheetPresented = false
                                }
                            }
                        }
                    
                    if engine.isShowingCustomClickSampleManager {
                        CustomClickSampleManagerSheet(engine: engine) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                engine.isShowingCustomClickSampleManager = false
                            }
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else if engine.isShowingCustomGuideSampleManager {
                        CustomGuideSampleManagerSheet(engine: engine) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                engine.isShowingCustomGuideSampleManager = false
                            }
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else if updateManager.isUpdateSheetPresented {
                        AppUpdateModalView(updateManager: updateManager)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .zIndex(50)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.audioDeviceBannerMessage)
        .animation(.easeInOut(duration: 0.25), value: updateManager.shouldShowTopBanner)
        .onAppear {
            setupKeyboardShortcuts()
            updateManager.onBeforeRelaunch = { [engine] in
                engine.performAutoSave()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let isStageActive = engine.playbackState == .playing || engine.isPadActive
                AppUpdateManager.shared.checkForUpdates(manual: false, isStagePlaybackActive: isStageActive)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            engine.performAutoSave()
        }
        .onDisappear {
            removeKeyboardShortcuts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackNewSession"))) { _ in
            engine.newSession()
            showStatus("New Session Created")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackOpenSession"))) { _ in
            openSessionDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackSaveSession"))) { _ in
            saveSessionDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleSetlistDrawer"))) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                isSetlistMenuOpen.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackExportSong"))) { _ in
            exportSongDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackImportSong"))) { _ in
            importSongDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackToggleEditSections"))) { _ in
            engine.toggleEditDrawer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackUndo"))) { _ in
            let activeResponder = NSApp.keyWindow?.firstResponder
            if activeResponder is NSTextView || activeResponder is NSTextField {
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                return
            }
            if engine.canUndo {
                engine.undo()
                showStatus("Undo")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackRedo"))) { _ in
            let activeResponder = NSApp.keyWindow?.firstResponder
            if activeResponder is NSTextView || activeResponder is NSTextField {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                return
            }
            if engine.canRedo {
                engine.redo()
                showStatus("Redo")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaybackOpenImportWizard"))) { _ in
            isPlaybackImportWizardPresented = true
        }
        .sheet(isPresented: $isPlaybackImportWizardPresented) {
            PlaybackImportWizardView(engine: engine) {
                isPlaybackImportWizardPresented = false
            }
        }
        .sheet(isPresented: $isSongBuilderPresented) {
            SongBuilderView(
                engine: engine,
                isCreatingNewSong: isCreatingNewSongInBuilder,
                previousSongIndex: previousSongIndexBeforeNewSong
            )
        }
        .sheet(isPresented: $isBussesDrawerPresented) {
            BussesDrawerView(engine: engine)
        }
        .sheet(isPresented: $isOfflineBouncePresented) {
            OfflineBounceSheetView(engine: engine) {
                isOfflineBouncePresented = false
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImportedFiles(result)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async {
                        handleDroppedURL(url)
                    }
                }
            }
            return true
        }
        .alert("Remove MIDI Mapping?", isPresented: Binding(
            get: { midiManager.pendingUnassignTarget != nil },
            set: { if !$0 { midiManager.pendingUnassignTarget = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let target = midiManager.pendingUnassignTarget?.targetId {
                    midiManager.removeMapping(for: target)
                }
            }
            Button("Cancel", role: .cancel) {
                midiManager.pendingUnassignTarget = nil
            }
        } message: {
            Text("Are you sure you want to remove the MIDI mapping for this control?")
        }
        .alert("Delete All MIDI Mappings?", isPresented: $midiManager.isShowingDeleteAllAlert) {
            Button("Delete All", role: .destructive) {
                midiManager.removeAllMappings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all MIDI note and CC assignments.")
        }
        .alert("Remove Keyboard Mapping?", isPresented: Binding(
            get: { keyboardManager.pendingUnassignTarget != nil },
            set: { if !$0 { keyboardManager.pendingUnassignTarget = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let target = keyboardManager.pendingUnassignTarget?.targetId {
                    keyboardManager.removeMapping(for: target)
                }
            }
            Button("Cancel", role: .cancel) {
                keyboardManager.pendingUnassignTarget = nil
            }
        } message: {
            Text("Are you sure you want to remove the keyboard shortcut for this control?")
        }
        .alert("Delete All Keyboard Mappings?", isPresented: $keyboardManager.isShowingDeleteAllAlert) {
            Button("Delete All", role: .destructive) {
                keyboardManager.removeAllMappings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all custom keyboard shortcuts.")
        }
        .alert("Mapping Already Assigned", isPresented: Binding(
            get: { keyboardManager.pendingCollision != nil },
            set: { if !$0 { keyboardManager.cancelCollision() } }
        )) {
            Button("Keep Current", role: .cancel) {
                keyboardManager.cancelCollision()
            }
            Button("Reassign") {
                keyboardManager.confirmReassignCollision()
            }
        } message: {
            if let col = keyboardManager.pendingCollision {
                let existingName = KeyboardMappingManager.friendlyTargetName(col.existingTargetId)
                let newName = KeyboardMappingManager.friendlyTargetName(col.newTargetId)
                Text("\"\(col.mapping.displayString)\" is already assigned to \(existingName). Do you want to keep the current assignment, or reassign it to \(newName)?")
            }
        }
        .alert("MIDI Mapping Already Assigned", isPresented: Binding(
            get: { midiManager.pendingCollision != nil },
            set: { if !$0 { midiManager.cancelCollision() } }
        )) {
            Button("Keep Current", role: .cancel) {
                midiManager.cancelCollision()
            }
            Button("Reassign") {
                midiManager.confirmReassignCollision()
            }
        } message: {
            if let col = midiManager.pendingCollision {
                let existingName = KeyboardMappingManager.friendlyTargetName(col.existingTargetId)
                let newName = KeyboardMappingManager.friendlyTargetName(col.newTargetId)
                Text("\"\(col.mapping.displayString)\" is already assigned to \(existingName). Do you want to keep the current assignment, or reassign it to \(newName)?")
            }
        }
        .alert("Transposition in Progress", isPresented: $engine.showTranspositionWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please wait until audio stems have finished transposing before playing.")
        }
        .alert("Download in Progress", isPresented: $engine.showDownloadingWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please wait until audio stems have finished downloading before playing.")
        }
    }
    
    // MARK: - Tier 1: Top Header & Hardware Transport Bar
    
    private var topTransportBarView: some View {
        let isBlankSession = engine.currentSong.title.isEmpty || engine.tracks.isEmpty
        let baseSessionName = engine.currentSetlist.name.isEmpty ? "New Setlist" : engine.currentSetlist.name
        let sessionDisplayName: String = {
            if engine.trimmingSection != nil {
                let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                return "\(songPart) (Trim Section)"
            } else if engine.isEditDrawerOpen {
                let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                return "\(songPart) (\(engine.selectedEditDrawerItem.rawValue))"
            } else {
                return baseSessionName
            }
        }()
        let isEditActive = engine.isEditDrawerOpen
        let boxBackground = Color(red: 0.08, green: 0.09, blue: 0.10)
        let boxBorder = Color.black.opacity(0.60)
        
        return VStack(spacing: 4) {
            // Window Title Bar Row (aligned horizontally with macOS traffic light buttons)
            HStack(spacing: 2) {
                if engine.isEditAutomationMode {
                    let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                    Text(songPart)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(" (Automation)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
                } else if engine.isEditMIDIMappingMode {
                    let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                    Text(songPart)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(" (MIDI Mapping)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.28, green: 0.60, blue: 1.0))
                } else if engine.isEditKeyboardMappingMode {
                    let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                    Text(songPart)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(" (Keyboard Mapping)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.95, green: 0.52, blue: 0.15))
                } else if engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte {
                    let songPart = engine.currentSong.title.isEmpty ? baseSessionName : engine.currentSong.title
                    Text(songPart)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(" (SMPTE)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
                } else {
                    Text(sessionDisplayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            
            // Main Transport Controls Row (all controls share identical 67pt height & top/bottom alignment)
            ZStack {
                // Exact Center Transport Cluster (RTZ, PLAY/PAUSE, FADE)
                if engine.isEditMIDIMappingMode || engine.isEditKeyboardMappingMode {
                    HStack(spacing: 8) {
                        // Transition button
                        MIDIMappableButton(
                            targetId: "transition",
                            isMappingMode: true,
                            action: { engine.cycleTransition() }
                        ) {
                            Canvas { context, size in
                                let midY = size.height / 2
                                let midX = size.width / 2
                                let cyanColor = Color(red: 0.25, green: 0.85, blue: 0.80)
                                let p1 = CGPoint(x: midX - 12, y: midY + 7)
                                let p2 = CGPoint(x: midX + 12, y: midY - 7)
                                var linePath = Path()
                                linePath.move(to: p1)
                                linePath.addLine(to: p2)
                                context.stroke(linePath, with: .color(cyanColor), lineWidth: 2.0)
                                
                                let c1 = Path(ellipseIn: CGRect(x: p1.x - 3.5, y: p1.y - 3.5, width: 7, height: 7))
                                let c2 = Path(ellipseIn: CGRect(x: p2.x - 3.5, y: p2.y - 3.5, width: 7, height: 7))
                                context.fill(c1, with: .color(cyanColor))
                                context.fill(c2, with: .color(cyanColor))
                            }
                            .frame(width: 74, height: 67)
                        }
                        .help("Song Transition")
                        
                        // RTZ Button
                        MIDIMappableButton(
                            targetId: "restart_song",
                            isMappingMode: true,
                            action: { engine.returnToZero() }
                        ) {
                            Canvas { context, size in
                                let strokeColor = Color(white: 0.65)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                let barRect = CGRect(x: midX - 9.3, y: midY - 9.3, width: 2.5, height: 18.7)
                                context.stroke(Path(barRect), with: .color(strokeColor), lineWidth: 1.2)
                                var tri = Path()
                                tri.move(to: CGPoint(x: midX - 3.3, y: midY))
                                tri.addLine(to: CGPoint(x: midX + 9.3, y: midY - 9.3))
                                tri.addLine(to: CGPoint(x: midX + 9.3, y: midY + 9.3))
                                tri.closeSubpath()
                                context.stroke(tri, with: .color(strokeColor), lineWidth: 1.3)
                            }
                            .frame(width: 95, height: 67)
                        }
                        .help("Return to Zero")
                        
                        // PLAY / PAUSE Button
                        MIDIMappableButton(
                            targetId: "play_pause",
                            isMappingMode: true,
                            badgeOffset: CGPoint(x: 4, y: -6),
                            action: { engine.togglePlayPause() }
                        ) {
                            Canvas { context, size in
                                let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                var tri = Path()
                                tri.move(to: CGPoint(x: midX - 7.2, y: midY - 10.5))
                                tri.addLine(to: CGPoint(x: midX + 10.5, y: midY))
                                tri.addLine(to: CGPoint(x: midX - 7.2, y: midY + 10.5))
                                tri.closeSubpath()
                                context.stroke(tri, with: .color(greenColor), lineWidth: 1.6)
                            }
                            .frame(width: 140, height: 67)
                            .opacity(engine.isCurrentSongDownloading ? 0.35 : 1.0)
                        }
                        .help(engine.isCurrentSongDownloading ? "Downloading stems..." : "Play / Pause")
                        
                        // FADE Button
                        MIDIMappableButton(
                            targetId: "fade_out",
                            isMappingMode: true,
                            badgeOffset: CGPoint(x: 4, y: -6),
                            action: { engine.toggleFade() }
                        ) {
                            Canvas { context, size in
                                let strokeColor = Color(white: 0.65)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                var fadePath = Path()
                                let leftX = midX - 12.6
                                let rightX = midX + 12.6
                                let topY = midY - 9.3
                                let botY = midY + 9.3
                                fadePath.move(to: CGPoint(x: leftX, y: topY))
                                fadePath.addLine(to: CGPoint(x: leftX, y: botY))
                                fadePath.addLine(to: CGPoint(x: rightX, y: botY))
                                fadePath.addQuadCurve(
                                    to: CGPoint(x: leftX, y: topY),
                                    control: CGPoint(x: leftX + 6.9, y: botY - 2.3)
                                )
                                fadePath.closeSubpath()
                                context.stroke(fadePath, with: .color(strokeColor), lineWidth: 1.3)
                            }
                            .frame(width: 95, height: 67)
                        }
                        .help("Fade Out")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    HStack(spacing: 9) {
                        // RTZ (Return to Zero) - 130x67 box with outline |◁ icon
                        Button(action: {
                            engine.returnToZero()
                        }) {
                            Canvas { context, size in
                                let strokeColor = Color(white: 0.55)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                
                                // Left vertical bar
                                let barRect = CGRect(x: midX - 9.3, y: midY - 9.3, width: 2.5, height: 18.7)
                                context.stroke(Path(barRect), with: .color(strokeColor), lineWidth: 1.2)
                                
                                // Right left-pointing triangle
                                var tri = Path()
                                tri.move(to: CGPoint(x: midX - 3.3, y: midY))
                                tri.addLine(to: CGPoint(x: midX + 9.3, y: midY - 9.3))
                                tri.addLine(to: CGPoint(x: midX + 9.3, y: midY + 9.3))
                                tri.closeSubpath()
                                context.stroke(tri, with: .color(strokeColor), lineWidth: 1.3)
                            }
                            .frame(width: 130, height: 67)
                            .background(boxBackground)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(boxBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Return to Zero (R)")
                        
                        // PLAY / PAUSE Button - 194x67 box with green outline triangle
                        Button(action: {
                            if engine.playbackState != .playing && (engine.isEditDrawerOpen || engine.isEditingArrangement) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    engine.closeEditMode()
                                }
                            }
                            engine.togglePlayPause()
                        }) {
                            Canvas { context, size in
                                let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                
                                if engine.playbackState == .playing {
                                    let leftBar = CGRect(x: midX - 8.2, y: midY - 10.5, width: 4.6, height: 21)
                                    let rightBar = CGRect(x: midX + 3.8, y: midY - 10.5, width: 4.6, height: 21)
                                    context.stroke(Path(leftBar), with: .color(greenColor), lineWidth: 1.6)
                                    context.stroke(Path(rightBar), with: .color(greenColor), lineWidth: 1.6)
                                } else {
                                    var tri = Path()
                                    tri.move(to: CGPoint(x: midX - 7.2, y: midY - 10.5))
                                    tri.addLine(to: CGPoint(x: midX + 10.5, y: midY))
                                    tri.addLine(to: CGPoint(x: midX - 7.2, y: midY + 10.5))
                                    tri.closeSubpath()
                                    context.stroke(tri, with: .color(greenColor), lineWidth: 1.6)
                                }
                            }
                            .frame(width: 194, height: 67)
                            .background(boxBackground)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(boxBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Play / Pause (Space)")
                        
                        // FADE Button - 130x67 box with concave fade-out curve icon (flips to ramp up when faded)
                        Button(action: {
                            engine.toggleFade()
                        }) {
                            Canvas { context, size in
                                let strokeColor = Color(white: 0.55)
                                let midY = size.height / 2
                                let midX = size.width / 2
                                
                                var fadePath = Path()
                                let leftX = midX - 12.6
                                let rightX = midX + 12.6
                                let topY = midY - 9.3
                                let botY = midY + 9.3
                                
                                fadePath.move(to: CGPoint(x: leftX, y: topY))
                                fadePath.addLine(to: CGPoint(x: leftX, y: botY))
                                fadePath.addLine(to: CGPoint(x: rightX, y: botY))
                                fadePath.addQuadCurve(
                                    to: CGPoint(x: leftX, y: topY),
                                    control: CGPoint(x: leftX + 6.9, y: botY - 2.3)
                                )
                                fadePath.closeSubpath()
                                context.stroke(fadePath, with: .color(strokeColor), lineWidth: 1.3)
                            }
                            .scaleEffect(x: engine.isFadedOut ? -1 : 1, y: 1)
                            .frame(width: 130, height: 67)
                            .background(boxBackground)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(boxBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(engine.isFadedOut ? "Fade In Stems (F)" : "Fade Out Stems (F)")
                        .contextMenu {
                            Menu("Fade Out Duration: \(Int(engine.fadeOutDuration))s") {
                                ForEach([1.0, 2.0, 3.0, 5.0, 8.0, 10.0], id: \.self) { seconds in
                                    Button("\(Int(seconds)) Seconds\(seconds == 5.0 ? " (Default)" : "")\(engine.fadeOutDuration == seconds ? " ✓" : "")") {
                                        engine.fadeOutDuration = seconds
                                    }
                                }
                            }
                            Menu("Fade In Duration: \(Int(engine.fadeInDuration))s") {
                                ForEach([1.0, 2.0, 3.0, 5.0, 8.0, 10.0], id: \.self) { seconds in
                                    Button("\(Int(seconds)) Seconds\(seconds == 5.0 ? " (Default)" : "")\(engine.fadeInDuration == seconds ? " ✓" : "")") {
                                        engine.fadeInDuration = seconds
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                
                // Left Group & Right Group pinned to outer edges
                HStack(alignment: .center, spacing: 0) {
                    // Top-Left Group (Tempo/Sig, Time Counter, PAD)
                    HStack(spacing: 8) {
                        if engine.isEditMIDIMappingMode || engine.isEditKeyboardMappingMode {
                            VStack(alignment: .leading, spacing: 4) {
                                // Row 1: Hand Tap Tempo & PAD button
                                HStack(spacing: 4) {
                                    MIDIMappableButton(targetId: "tap_tempo", isMappingMode: true, action: { engine.tapTempo() }) {
                                        Image(systemName: "hand.tap.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 44, height: 31)
                                    }
                                    .help("Tap Tempo")
                                    
                                    MIDIMappableButton(targetId: "toggle_pad", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: { engine.togglePadPlayer() }) {
                                        Text("PAD")
                                            .font(.system(size: 11.5, weight: .bold))
                                            .foregroundColor(Color(red: 0.35, green: 0.85, blue: 0.55))
                                            .frame(width: 54, height: 31)
                                    }
                                    .help("Toggle Pad Player")
                                }
                                
                                // Row 2: 5 navigation buttons (|<<, <<, ✓, >>, >>|)
                                HStack(spacing: 4) {
                                    MIDIMappableButton(targetId: "prev_song", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: {
                                        if engine.currentSongIndex > 0 { engine.selectSongInSetlist(at: engine.currentSongIndex - 1) }
                                    }) {
                                        Image(systemName: "backward.end.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 42, height: 31)
                                    }
                                    .help("Previous Song")
                                    
                                    MIDIMappableButton(targetId: "prev_section", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: {
                                        engine.navigatePreviousSection()
                                    }) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 42, height: 31)
                                    }
                                    .help("Previous Section")
                                    
                                    MIDIMappableButton(targetId: "select_action", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: {
                                        engine.triggerSelectAction()
                                    }) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 42, height: 31)
                                    }
                                    .help("Select Section (Jump / Queue)")
                                    
                                    MIDIMappableButton(targetId: "next_section", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: {
                                        engine.navigateNextSection()
                                    }) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 42, height: 31)
                                    }
                                    .help("Next Section")
                                    
                                    MIDIMappableButton(targetId: "next_song", isMappingMode: true, badgeOffset: CGPoint(x: 4, y: -6), action: {
                                        if engine.currentSongIndex + 1 < engine.currentSetlist.songs.count { engine.selectSongInSetlist(at: engine.currentSongIndex + 1) }
                                    }) {
                                        Image(systemName: "forward.end.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.90))
                                            .frame(width: 42, height: 31)
                                    }
                                    .help("Next Song")
                                }
                            }
                        } else if isBlankSession {
                            // Blank State Horizontal Dash for Tempo/Sig (no box)
                            ZStack {
                                Rectangle()
                                    .fill(Color(white: 0.45))
                                    .frame(width: 35, height: 1.2)
                            }
                            .frame(width: 60, height: 67)
                            
                            // Blank State Time Counter Card (--:-- / -- / --)
                            VStack(alignment: .center, spacing: 2) {
                                Text("--:--")
                                    .font(.system(size: 23, weight: .regular, design: .monospaced))
                                    .foregroundColor(Color(white: 0.55))
                                
                                Text("-- / --")
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundColor(Color(white: 0.45))
                            }
                            .frame(width: 114, height: 67)
                            .background(boxBackground)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(boxBorder, lineWidth: 1)
                            )
                        } else if engine.isEditMIDICuesMode {
                            // Top-Left MIDI Cues Navigation & Actions Cluster ([ < ] [ ... / ✓ ] [ > ]) matching MultiTracks Playback
                            HStack(spacing: 4) {
                                Button(action: {
                                    engine.stepLeftMIDICueButton()
                                }) {
                                    Image(systemName: "arrowtriangle.left")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingMIDICue ? "Nudge MIDI Cue Earlier (1/16th Note)" : "Select Previous MIDI Cue")
                                
                                if engine.isNudgingMIDICue {
                                    // Checkmark button between < and > to accept 16th-note nudge position
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            engine.isNudgingMIDICue = false
                                        }
                                    }) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.system(size: 20, weight: .regular))
                                            .foregroundColor(.white)
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Accept MIDI Cue Position")
                                } else {
                                    // '...' Button opening Edit / Nudge / Delete MIDI Cue popover
                                    Button(action: {
                                        if engine.selectedMIDICueId == nil,
                                           let first = engine.currentSong.midiCues.sorted(by: { $0.time < $1.time }).first {
                                            engine.selectedMIDICueId = first.id
                                        }
                                        isTopLeftMIDICuesMenuOpen.toggle()
                                    }) {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 16.5, weight: .bold))
                                            .foregroundColor(Color(white: 0.80))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 55, height: 67)
                                    .help("MIDI Cue Actions (Edit, Nudge, Delete)")
                                    .popover(isPresented: $isTopLeftMIDICuesMenuOpen, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            let hasSelected = (engine.selectedMIDICue != nil)
                                            
                                            Button(action: {
                                                isTopLeftMIDICuesMenuOpen = false
                                                if let selId = engine.selectedMIDICueId {
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                        engine.requestedEditMIDICueId = selId
                                                    }
                                                }
                                            }) {
                                                HStack {
                                                    Text("Edit MIDI Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftMIDICuesMenuOpen = false
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    engine.isNudgingMIDICue = true
                                                }
                                            }) {
                                                HStack {
                                                    Text("Nudge MIDI Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftMIDICuesMenuOpen = false
                                                if let selId = engine.selectedMIDICueId {
                                                    engine.removeMIDICue(id: selId)
                                                }
                                            }) {
                                                HStack {
                                                    Text("Delete MIDI Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? Color(red: 0.98, green: 0.24, blue: 0.28) : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                        }
                                        .frame(width: 176)
                                        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                                    }
                                }
                                
                                Button(action: {
                                    engine.stepRightMIDICueButton()
                                }) {
                                    Image(systemName: "arrowtriangle.right")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingMIDICue ? "Nudge MIDI Cue Later (1/16th Note)" : "Select Next MIDI Cue")
                            }
                        } else if engine.isEditDirectionalCuesMode {
                            // Top-Left Directional Cues Navigation & Actions Cluster ([ < ] [ ... / ✓ ] [ > ]) matching MultiTracks Playback
                            HStack(spacing: 4) {
                                Button(action: {
                                    engine.stepLeftDirectionalCueButton()
                                }) {
                                    Image(systemName: "arrowtriangle.left")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingDirectionalCue ? "Nudge Directional Cue Earlier (1/16th Note)" : "Select Previous Directional Cue")
                                
                                if engine.isNudgingDirectionalCue {
                                    // Checkmark button between < and > to accept 16th-note nudge position
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            engine.isNudgingDirectionalCue = false
                                        }
                                    }) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.system(size: 20, weight: .regular))
                                            .foregroundColor(.cyan)
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Accept Directional Cue Position")
                                } else {
                                    // '...' Button opening Edit / Nudge / Delete Directional Cue popover
                                    Button(action: {
                                        if engine.selectedDirectionalCueId == nil,
                                           let first = engine.currentSong.directionalCues.sorted(by: { $0.time < $1.time }).first {
                                            engine.selectedDirectionalCueId = first.id
                                        }
                                        isTopLeftDirectionalCuesMenuOpen.toggle()
                                    }) {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 16.5, weight: .bold))
                                            .foregroundColor(Color(white: 0.80))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 55, height: 67)
                                    .help("Directional Cue Actions (Edit, Nudge, Delete)")
                                    .popover(isPresented: $isTopLeftDirectionalCuesMenuOpen, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            let hasSelected = (engine.selectedDirectionalCue != nil)
                                            
                                            Button(action: {
                                                isTopLeftDirectionalCuesMenuOpen = false
                                                if let selId = engine.selectedDirectionalCueId {
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                        engine.requestedEditDirectionalCueId = selId
                                                    }
                                                }
                                            }) {
                                                HStack {
                                                    Text("Edit Directional Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftDirectionalCuesMenuOpen = false
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    engine.isNudgingDirectionalCue = true
                                                }
                                            }) {
                                                HStack {
                                                    Text("Nudge Directional Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftDirectionalCuesMenuOpen = false
                                                if let selId = engine.selectedDirectionalCueId {
                                                    engine.removeDirectionalCue(id: selId)
                                                }
                                            }) {
                                                HStack {
                                                    Text("Delete Directional Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? Color(red: 0.98, green: 0.24, blue: 0.28) : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                        }
                                        .frame(width: 190)
                                        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                                    }
                                }
                                
                                Button(action: {
                                    engine.stepRightDirectionalCueButton()
                                }) {
                                    Image(systemName: "arrowtriangle.right")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingDirectionalCue ? "Nudge Directional Cue Later (1/16th Note)" : "Select Next Directional Cue")
                            }
                        } else if engine.isEditAutomationMode {
                            // Top-Left Automation Navigation & Actions Cluster ([ < ] [ ... / ✓ ] [ > ]) matching MultiTracks Playback
                            HStack(spacing: 4) {
                                Button(action: {
                                    engine.stepLeftAutomationButton()
                                }) {
                                    Image(systemName: "arrowtriangle.left")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingAutomation ? "Nudge Automation Earlier (1 Beat)" : "Select Previous Automation Point")
                                
                                if engine.isNudgingAutomation {
                                    // Checkmark button between < and > to accept beat nudge position
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            engine.isNudgingAutomation = false
                                        }
                                    }) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.system(size: 20, weight: .regular))
                                            .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Accept Automation Position")
                                } else {
                                    // '...' Button opening Edit / Nudge / Delete Automation popover
                                    Button(action: {
                                        if engine.selectedAutomationPointId == nil,
                                           let first = engine.currentSong.automationPoints.sorted(by: { $0.time < $1.time }).first {
                                            engine.selectAutomationPoint(id: first.id)
                                        }
                                        isTopLeftAutomationMenuOpen.toggle()
                                    }) {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 16.5, weight: .bold))
                                            .foregroundColor(Color(white: 0.80))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 55, height: 67)
                                    .help("Automation Actions (Edit, Nudge, Delete)")
                                    .popover(isPresented: $isTopLeftAutomationMenuOpen, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            let hasSelected = (engine.selectedAutomationPoint != nil)
                                            
                                            Button(action: {
                                                isTopLeftAutomationMenuOpen = false
                                                if let selId = engine.selectedAutomationPointId {
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                        engine.requestedEditAutomationId = selId
                                                    }
                                                }
                                            }) {
                                                HStack {
                                                    Text("Edit Automation")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftAutomationMenuOpen = false
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    engine.isNudgingAutomation = true
                                                }
                                            }) {
                                                HStack {
                                                    Text("Nudge Automation")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftAutomationMenuOpen = false
                                                if let selId = engine.selectedAutomationPointId {
                                                    engine.removeAutomationPoint(id: selId)
                                                }
                                            }) {
                                                HStack {
                                                    Text("Delete Automation")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasSelected ? Color(red: 0.98, green: 0.24, blue: 0.28) : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasSelected)
                                        }
                                        .frame(width: 190)
                                        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                                    }
                                }
                                
                                Button(action: {
                                    engine.stepRightAutomationButton()
                                }) {
                                    Image(systemName: "arrowtriangle.right")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(engine.isNudgingAutomation ? "Nudge Automation Later (1 Beat)" : "Select Next Automation Point")
                            }
                        } else if engine.isEditSMPTEMode && engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .smpte {
                            // Top-Left SMPTE Navigation & Actions Cluster ([ < ] [ ... / ✓ ] [ > ]) matching Automation
                            HStack(spacing: 4) {
                                Button(action: {
                                    engine.nudgeSMPTECue(earlier: true)
                                }) {
                                    Image(systemName: "arrowtriangle.left")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Nudge SMPTE Earlier (1 Beat)")
                                
                                if engine.isNudgingSMPTECue {
                                    // Green Checkmark Button to commit / accept nudge position
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            engine.isNudgingSMPTECue = false
                                        }
                                    }) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Accept SMPTE Position")
                                } else {
                                    // '...' Button opening Edit / Nudge / Delete SMPTE popover
                                    Button(action: {
                                        isTopLeftSMPTEMenuOpen.toggle()
                                    }) {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 16.5, weight: .bold))
                                            .foregroundColor(Color(white: 0.80))
                                            .frame(width: 55, height: 67)
                                            .background(boxBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(boxBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 55, height: 67)
                                    .help("SMPTE Actions (Edit, Nudge, Delete)")
                                    .popover(isPresented: $isTopLeftSMPTEMenuOpen, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            let hasCue = (engine.currentSong.smpteCue != nil)
                                            
                                            Button(action: {
                                                isTopLeftSMPTEMenuOpen = false
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                    engine.requestedEditSMPTECue = true
                                                }
                                            }) {
                                                HStack {
                                                    Text("Edit SMPTE Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasCue ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasCue)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftSMPTEMenuOpen = false
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    engine.isNudgingSMPTECue = true
                                                }
                                            }) {
                                                HStack {
                                                    Text("Nudge SMPTE")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasCue ? .white : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasCue)
                                            
                                            Divider()
                                                .background(Color(white: 0.22))
                                            
                                            Button(action: {
                                                isTopLeftSMPTEMenuOpen = false
                                                engine.removeSMPTECue()
                                            }) {
                                                HStack {
                                                    Text("Delete SMPTE Cue")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(hasCue ? Color(red: 0.98, green: 0.24, blue: 0.28) : Color(white: 0.45))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!hasCue)
                                        }
                                        .frame(width: 190)
                                        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                                    }
                                }
                                
                                Button(action: {
                                    engine.nudgeSMPTECue(earlier: false)
                                }) {
                                    Image(systemName: "arrowtriangle.right")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(Color(white: 0.80))
                                        .frame(width: 55, height: 67)
                                        .background(boxBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(boxBorder, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Nudge SMPTE Later (1 Beat)")
                            }
                        } else {
                            // Stacked BPM & Time Signature (isolated view so live ritardando BPM changes never redraw MainView)
                            LiveBPMTimeSigView(
                                clock: engine.transportDisplayClock,
                                baseBPM: engine.currentSong.bpm,
                                timeSignatureNumerator: engine.currentSong.timeSignatureNumerator,
                                timeSignatureDenominator: engine.currentSong.timeSignatureDenominator,
                                isPlaying: engine.playbackState == .playing
                            )
                            
                            // Active Time Display Card (isolated from MainView body re-renders)
                            LiveTransportTimeCardView(
                                clock: engine.transportDisplayClock,
                                boxBackground: boxBackground,
                                boxBorder: boxBorder
                            )
                        }
                        
                        if !engine.isEditMIDIMappingMode && !engine.isEditKeyboardMappingMode {
                            // PAD Player Button (69x67 box)
                            Button(action: {
                                engine.togglePadPlayer()
                                if engine.isEditAutomationMode {
                                    engine.recordAutomationPadActive(engine.isPadActive)
                                }
                            }) {
                                Text("PAD")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(engine.isPadActive ? Color(red: 0.25, green: 0.90, blue: 0.45) : Color(red: 0.22, green: 0.62, blue: 0.36))
                                    .frame(width: 69, height: 67)
                                    .background(boxBackground)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(
                                                (engine.isAutomationHighlightActive || engine.isPadActive) ? Color(red: 0.25, green: 0.90, blue: 0.45) : boxBorder,
                                                lineWidth: engine.isAutomationHighlightActive ? 1.5 : 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Toggle Ambient Pad Player (P)")
                        }
                    }
                    
                    Spacer()
                    
                    // Top-Right Action Controls (EDIT, Song Menu, Settings)
                    HStack(spacing: 9) {
                        if engine.isBouncingReference || !engine.referenceBounceStatus.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(engine.isBouncingReference ? "Exporting..." : (engine.referenceBounceStatus.isEmpty ? "Exporting..." : engine.referenceBounceStatus))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(engine.referenceBounceError != nil
                                        ? Color(red: 0.98, green: 0.35, blue: 0.38)
                                        : Color(red: 0.25, green: 0.85, blue: 1.0))
                                    .lineLimit(1)
                                ProgressView(value: engine.referenceBounceProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                                    .frame(width: 155)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.16))
                            .cornerRadius(4)
                        }
                        if engine.isAutoLabelingSections {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(engine.autoLabelStatusText.isEmpty ? "Listening to Guide..." : engine.autoLabelStatusText)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(red: 0.25, green: 0.85, blue: 1.0))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.16))
                            .cornerRadius(4)
                        } else if engine.isAnalyzingClickTempo {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Analyzing Click Track Tempo...")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(red: 0.25, green: 0.85, blue: 1.0))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.16))
                            .cornerRadius(4)
                        }
                        
                        if engine.isEditKeyboardMappingMode {
                            Button(action: {
                                keyboardManager.restoreDefaultMappings()
                                showStatus("Keyboard mappings reset to defaults")
                            }) {
                                VStack(spacing: 2) {
                                    Text("RESET")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("DEFAULTS")
                                        .font(.system(size: 9.5, weight: .bold))
                                }
                                .foregroundColor(Color(red: 0.98, green: 0.62, blue: 0.22))
                                .frame(width: 69, height: 67)
                                .background(boxBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color(red: 0.98, green: 0.62, blue: 0.22).opacity(0.45), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(width: 69, height: 67)
                            .help("Reset all keyboard shortcuts to factory defaults")
                        }
                        
                        // EDIT / DONE Button (Opens & Closes Bottom-Right Edit Menu Drawer)
                        Button(action: {
                            engine.toggleEditDrawer()
                        }) {
                            Text(isEditActive ? "DONE" : "EDIT")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(isEditActive ? .white : Color(white: 0.78))
                                .frame(width: 69, height: 67)
                                .background(boxBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(boxBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 69, height: 67)
                        .help("Toggle Edit Menu Drawer")
                        
                        // Setlist Menu Button (MultiTracks Playback Style)
                        Button(action: {
                            isSetlistMenuOpen.toggle()
                        }) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Color(white: 0.78))
                                .overlay(alignment: .topTrailing) {
                                    if engine.hasCloudSetlistUpdate {
                                        Circle()
                                            .fill(Color(red: 0.30, green: 0.88, blue: 0.98))
                                            .frame(width: 7, height: 7)
                                            .offset(x: 5, y: -4)
                                    } else if engine.hasUnsavedChanges {
                                        Circle()
                                            .fill(Color(red: 0.95, green: 0.25, blue: 0.25))
                                            .frame(width: 7, height: 7)
                                            .offset(x: 5, y: -4)
                                    }
                                }
                                .frame(width: 69, height: 67)
                                .background(isSetlistMenuOpen ? Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.35) : boxBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isSetlistMenuOpen ? Color(red: 0.20, green: 0.75, blue: 0.95) : boxBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 69, height: 67)
                        .help("Setlists Menu")
                        .popover(isPresented: $isSetlistMenuOpen, arrowEdge: .bottom) {
                            SetlistMenuPopoverView(engine: engine) {
                                isSetlistMenuOpen = false
                            }
                        }
                        
                        // Settings Menu Button (MultiTracks Playback Style)
                        Button(action: {
                            isSettingsMenuOpen.toggle()
                        }) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundColor(Color(white: 0.78))
                                .frame(width: 69, height: 67)
                                .background(isSettingsMenuOpen ? Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.35) : boxBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isSettingsMenuOpen ? Color(red: 0.20, green: 0.75, blue: 0.95) : boxBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 69, height: 67)
                        .contentShape(Rectangle())
                        .help("Settings Menu")
                        .popover(isPresented: $isSettingsMenuOpen, arrowEdge: .bottom) {
                            SettingsMenuPopoverView(
                                engine: engine,
                                isPresented: $isSettingsMenuOpen,
                                onOpenBusses: {
                                    isSettingsMenuOpen = false
                                    isBussesDrawerPresented = true
                                },
                                onAddTracks: {
                                    isSettingsMenuOpen = false
                                    isFileImporterPresented = true
                                },
                                onOpenOfflineBounce: {
                                    isSettingsMenuOpen = false
                                    isOfflineBouncePresented = true
                                },
                                onStatus: { msg in
                                    showStatus(msg)
                                }
                            )
                        }
                    }
                }
            }
            .disabled(engine.trimmingSection != nil)
            .opacity(engine.trimmingSection != nil ? 0.35 : 1.0)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
    }
    
    // MARK: - Tier 2: Setlist Song Carousel Row
    
    private var setlistSongCarouselView: some View {
        Group {
            if engine.isEditMIDIMappingMode || engine.isEditKeyboardMappingMode {
                midiMappingSongCarouselView
            } else {
                normalSetlistSongCarouselView
            }
        }
    }
    
    private var midiMappingSongCarouselView: some View {
        let cardCount = max(10, engine.currentSetlist.songs.count)
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<cardCount, id: \.self) { idx in
                        MIDIMappingSongCardView(
                            index: idx,
                            song: idx < engine.currentSetlist.songs.count ? engine.currentSetlist.songs[idx] : nil,
                            onSelect: {
                                if idx < engine.currentSetlist.songs.count {
                                    engine.selectSongInSetlist(at: idx)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            
            // Trailing "DELETE ALL" button matching MultiTracks Playback mapping view
            Button(action: {
                if engine.isEditKeyboardMappingMode {
                    keyboardManager.isShowingDeleteAllAlert = true
                } else {
                    midiManager.isShowingDeleteAllAlert = true
                }
            }) {
                VStack(spacing: 2) {
                    Text("DELETE")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("ALL")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .foregroundColor(Color(white: 0.75))
                .frame(width: 58, height: 62)
                .background(Color(red: 0.08, green: 0.09, blue: 0.10))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.60), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .help(engine.isEditKeyboardMappingMode ? "Delete All Keyboard Mappings" : "Delete All MIDI Mappings")
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
    }
    
    private var normalSetlistSongCarouselView: some View {
        let isEditingSetlistSongMap = engine.isSetlistSongMapEditingActive
        let cardGap: CGFloat = 12.0
        let cardWidth: CGFloat = 226.0
        let cardStride: CGFloat = cardWidth + cardGap
        
        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Layer 1: Song Cards and Placeholder Slots
                HStack(alignment: .top, spacing: cardGap) {
                    if engine.currentSetlist.songs.isEmpty {
                        // Blank Session Carousel: + Add a Song card followed by 5 placeholder slots
                        addSongCardView
                        
                        ForEach(0..<5, id: \.self) { _ in
                            placeholderSongSlotView
                        }
                    } else {
                        // Active Songs with Mouse Drag-and-Drop Reordering
                        ForEach(Array(engine.currentSetlist.songs.enumerated()), id: \.element.id) { index, song in
                            let isActive = (index == engine.currentSongIndex)
                            let transposeProgForSong = engine.transposeProgressBySong[song.id]
                            let isTransposingThisSong = (transposeProgForSong != nil) || (engine.isTransposing && (engine.transposingSongId == song.id || (engine.transposingSongId == nil && isActive)))
                            let downloadProgForSong = engine.downloadingSongProgress[song.id]
                            let isDownloadingThisSong = (downloadProgForSong != nil) && !isTransposingThisSong
                            let activeOverlayProgress: Double = isTransposingThisSong
                                ? Double(transposeProgForSong ?? engine.transposeProgress)
                                : (downloadProgForSong ?? 0.0)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                // Album Art Card
                                ZStack {
                                    if let img = song.albumArtwork {
                                        Image(nsImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: cardWidth, height: 120)
                                            .clipped()
                                            .cornerRadius(4)
                                    } else {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(coverGradient(for: index))
                                            .frame(width: cardWidth, height: 120)
                                    }
                                    
                                    if isTransposingThisSong || isDownloadingThisSong {
                                        VStack(spacing: 0) {
                                            Spacer()
                                            
                                            VStack(spacing: 5) {
                                                HStack(spacing: 5) {
                                                    Image(systemName: isDownloadingThisSong ? "icloud.and.arrow.down" : (song.isTempoShifted && song.transposeSemitones == 0 ? "metronome.fill" : "music.note"))
                                                        .font(.system(size: 9.5, weight: .bold))
                                                        .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                                                    Text(
                                                        isDownloadingThisSong
                                                            ? "Downloading..."
                                                            : ((song.transposeSemitones != 0 && song.isTempoShifted)
                                                                ? "Key & Tempo..."
                                                                : (song.isTempoShifted ? "Tempo..." : "Transposing..."))
                                                    )
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundColor(.white)
                                                    Spacer()
                                                    Text("\(Int(activeOverlayProgress * 100))%")
                                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                        .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                                                    if isDownloadingThisSong {
                                                        Button(action: {
                                                            engine.cancelSongDownload(songId: song.id)
                                                        }) {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .font(.system(size: 12))
                                                                .foregroundColor(Color(white: 0.75))
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Stop downloading this song")
                                                    }
                                                }
                                                .padding(.horizontal, 8)
                                                
                                                GeometryReader { barGeo in
                                                    ZStack(alignment: .leading) {
                                                        RoundedRectangle(cornerRadius: 2.5)
                                                            .fill(Color(white: 0.25))
                                                            .frame(height: 5)
                                                        
                                                        RoundedRectangle(cornerRadius: 2.5)
                                                            .fill(
                                                                LinearGradient(
                                                                    gradient: Gradient(colors: [
                                                                        Color(red: 0.20, green: 0.75, blue: 0.95),
                                                                        Color(red: 0.35, green: 0.90, blue: 0.75)
                                                                    ]),
                                                                    startPoint: .leading,
                                                                    endPoint: .trailing
                                                                )
                                                            )
                                                            .frame(width: max(0, barGeo.size.width * CGFloat(min(1.0, max(0.0, activeOverlayProgress)))), height: 5)
                                                    }
                                                }
                                                .frame(height: 5)
                                                .padding(.horizontal, 8)
                                            }
                                            .padding(.vertical, 7)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.black.opacity(0.85))
                                            )
                                        }
                                        .frame(width: cardWidth, height: 120)
                                        .transition(.opacity)
                                    }
                                    
                                    if isEditingSetlistSongMap {
                                        // Edit Mode Overlays: Red Minus Button on Left, Dark '...' Circle in Center
                                        ZStack {
                                            // Center '...' Song Menu, Transpose & ProPresenter Trigger Button
                                            Button(action: {
                                                activeSongCardMenuSongId = song.id
                                            }) {
                                                ZStack {
                                                    Circle()
                                                        .fill(Color(red: 0.16, green: 0.18, blue: 0.20).opacity(0.92))
                                                        .frame(width: 30, height: 30)
                                                    Circle()
                                                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                                        .frame(width: 30, height: 30)
                                                    Image(systemName: "ellipsis")
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundColor(.white)
                                                }
                                                .shadow(color: Color.black.opacity(0.5), radius: 2)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Song Menu, Transpose & ProPresenter MIDI Triggers")
                                            .modifier(DynamicSidePopover(
                                                isPresented: Binding(
                                                    get: { activeSongCardMenuSongId == song.id },
                                                    set: { if !$0 { activeSongCardMenuSongId = nil } }
                                                ),
                                                popoverWidth: 325,
                                                popoverContent: {
                                                    songCardMenuPopover(index: index)
                                                }
                                            ))
                                            
                                            // Left Red Minus Remove Song Button
                                            HStack {
                                                Button(action: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        engine.removeSongFromSetlist(at: index)
                                                    }
                                                }) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(Color(red: 0.98, green: 0.18, blue: 0.32))
                                                            .frame(width: 24, height: 24)
                                                        Circle()
                                                            .stroke(Color.white, lineWidth: 1.5)
                                                            .frame(width: 24, height: 24)
                                                        Rectangle()
                                                            .fill(Color.white)
                                                            .frame(width: 11, height: 2.3)
                                                            .cornerRadius(1)
                                                    }
                                                    .shadow(color: Color.black.opacity(0.5), radius: 2)
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.leading, 8)
                                                .help("Remove Song from Setlist")
                                                
                                                Spacer()
                                            }
                                        }
                                        .frame(width: cardWidth, height: 120)
                                    }
                                }
                                .frame(width: cardWidth, height: 120)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isActive ? Color(white: 0.82) : Color.clear, lineWidth: 1.4)
                                )
                                
                                // Song Title & Key Underneath (16pt font)
                                HStack(spacing: 5) {
                                    if isActive {
                                        // Green outline right-pointing triangle matching MultiTracks Playback
                                        Canvas { context, size in
                                            let green = Color(red: 0.25, green: 0.88, blue: 0.45)
                                            var tri = Path()
                                            tri.move(to: CGPoint(x: 1, y: 1))
                                            tri.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                                            tri.addLine(to: CGPoint(x: 1, y: size.height - 1))
                                            tri.closeSubpath()
                                            context.stroke(tri, with: .color(green), lineWidth: 1.5)
                                        }
                                        .frame(width: 10, height: 12)
                                    }
                                    
                                    HStack(spacing: 4) {
                                        Text(song.title)
                                            .font(.system(size: 16, weight: isActive ? .bold : .semibold))
                                            .foregroundColor(isActive ? .white : Color(white: 0.70))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        if !song.effectiveKey.isEmpty {
                                            Text("(\(song.effectiveKey))")
                                                .font(.system(size: 16, weight: isActive ? .bold : .semibold))
                                                .foregroundColor(isActive ? .white : Color(white: 0.70))
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }
                                    .frame(maxWidth: 210, alignment: .leading)
                                }
                                .frame(height: 24)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                engine.selectSongInSetlist(at: index)
                            }
                            .contextMenu {
                                Button("Song Menu & Transpose...") {
                                    activeSongCardMenuSongId = song.id
                                }
                                Divider()
                                Button("Remove from Setlist") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        engine.removeSongFromSetlist(at: index)
                                    }
                                }
                            }
                            .onDrag {
                                self.draggedSong = song
                                return NSItemProvider(object: song.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: SongDropDelegate(
                                targetSong: song,
                                draggedSong: $draggedSong,
                                onMove: { fromId, toId in
                                    if let fromIdx = engine.currentSetlist.songs.firstIndex(where: { $0.id == fromId }),
                                       let toIdx = engine.currentSetlist.songs.firstIndex(where: { $0.id == toId }) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            engine.moveSong(from: fromIdx, to: toIdx)
                                        }
                                    }
                                }
                            ))
                        }
                        
                        // Fill remaining carousel slots with placeholder cards; in edit mode, the first empty card becomes "+ Add a Song"
                        let occupiedSlots = engine.currentSetlist.songs.count
                        let placeholderCount = max(2, 6 - occupiedSlots)
                        ForEach(0..<placeholderCount, id: \.self) { placeholderIdx in
                            if placeholderIdx == 0 && isEditingSetlistSongMap {
                                addSongCardView
                            } else {
                                placeholderSongSlotView
                            }
                        }
                    }
                }
                
                // Layer 2: Transition Badges at Top Corners (Overlapping Current & Next Card)
                // Using precise layout spacers so SwiftUI popover anchors directly to each transition badge
                if !engine.currentSetlist.songs.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(engine.currentSetlist.songs.enumerated()), id: \.element.id) { index, song in
                            let isLastSong = (index == engine.currentSetlist.songs.count - 1)
                            let transitionIconName: String = {
                                if isLastSong {
                                    return song.transitionType == .stayInSong ? "arrow.right.to.line" : "arrow.uturn.backward"
                                } else {
                                    return song.transitionType.iconName
                                }
                            }()
                            
                            let badgeSize: CGFloat = 28.0
                            let leadingSpacer: CGFloat = (index == 0)
                                ? (cardWidth + (cardGap - badgeSize) / 2.0)
                                : (cardStride - badgeSize)
                            
                            Color.clear
                                .frame(width: max(0, leadingSpacer), height: badgeSize)
                            
                            let isContinuePad = song.continuePad
                            let greenColor = Color(red: 0.25, green: 0.88, blue: 0.45)
                            
                            Button(action: {
                                activeTransitionSongIndex = index
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(isContinuePad ? Color(red: 0.08, green: 0.20, blue: 0.12) : Color(red: 0.12, green: 0.13, blue: 0.15))
                                        .frame(width: badgeSize, height: badgeSize)
                                    Circle()
                                        .stroke(isContinuePad ? greenColor : Color.white.opacity(0.35), lineWidth: isContinuePad ? 1.8 : 1.0)
                                        .frame(width: badgeSize, height: badgeSize)
                                    Image(systemName: transitionIconName)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundColor(isContinuePad ? greenColor : .white.opacity(0.95))
                                }
                                .frame(width: badgeSize, height: badgeSize)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isLastSong ? "Setlist End Transition" : "Transition to Next Song")
                            .popover(
                                isPresented: Binding(
                                    get: { activeTransitionSongIndex == index },
                                    set: { if !$0 { activeTransitionSongIndex = nil } }
                                ),
                                arrowEdge: .bottom
                            ) {
                                SongTransitionPopoverView(engine: engine, songIndex: index) {
                                    activeTransitionSongIndex = nil
                                }
                            }
                        }
                    }
                    .padding(.top, 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
        .disabled(engine.trimmingSection != nil)
        .opacity(engine.trimmingSection != nil ? 0.35 : 1.0)
    }
    
    private func songCardMenuPopover(index: Int) -> some View {
        SongMenuPopoverView(
            engine: engine,
            songIndex: index,
            onClose: {
                activeSongCardMenuSongId = nil
            },
            onEditSong: {
                if index != engine.currentSongIndex {
                    engine.selectSongInSetlist(at: index)
                }
                isCreatingNewSongInBuilder = false
                previousSongIndexBeforeNewSong = nil
                isSongBuilderPresented = true
            }
        )
    }

    private var placeholderSongSlotView: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.16))
                .frame(width: 226, height: 120)
            
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.16))
                .frame(width: 176, height: 16)
        }
    }
    
    // MARK: - Bottom-Right Edit Menu Drawer (MultiTracks Playback Style)
    
    private var editBottomDrawerView: some View {
        HStack(spacing: 8) {
            // Left Collapse Chevron '>' Button
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    engine.collapseEditDrawer()
                }
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .frame(width: 25, height: 35)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide Edit Drawer")
            
            ForEach(MultitrackAudioEngine.EditDrawerItem.allCases, id: \.self) { item in
                let isSelected = (engine.selectedEditDrawerItem == item)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.selectEditDrawerItem(item)
                    }
                }) {
                    Text(item.rawValue)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 33)
                        .background(Color(white: 0.16))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.white.opacity(0.85) : Color.clear, lineWidth: 1.2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.65), radius: 8, x: 0, y: 2)
    }
    
    // MARK: - Add a Song Card View
    
    private var addSongCardView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                isSongLibraryBrowserPresented = true
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.16))
                        .frame(width: 226, height: 120)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text("Add a Song")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .frame(width: 226, height: 120)
            .help("Add a Song, Click & Pad, or Import")
            .modifier(DynamicSidePopover(
                isPresented: $isSongLibraryBrowserPresented,
                popoverWidth: 330,
                popoverContent: {
                    AddSongMenuPopoverView(
                        engine: engine,
                        onImportFromFinder: {
                            importSongDialog()
                        },
                        onBuildNewSong: {
                            previousSongIndexBeforeNewSong = engine.beginBuildingNewSong()
                            isCreatingNewSongInBuilder = true
                            isSongBuilderPresented = true
                        },
                        onDismiss: {
                            isSongLibraryBrowserPresented = false
                        }
                    )
                }
            ))
            
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.16))
                .frame(width: 176, height: 16)
        }
    }
    
    // MARK: - Bus Expandable Tray (Channels Assigned to Bus)
    
    private func busAssignedItemsCount(for bus: AudioBus) -> Int {
        let lower = bus.name.lowercased()
        if lower == "click" {
            let clickTracks = engine.tracks.filter { $0.assignedBusName.lowercased() == "click" }
            return 4 + clickTracks.count
        } else if lower == "pad" {
            let padTracks = engine.tracks.filter { $0.assignedBusName.lowercased() == "pad" }
            return 1 + padTracks.count
        } else {
            return engine.tracks.filter { $0.assignedBusName.lowercased() == lower }.count
        }
    }
    
    @ViewBuilder
    private func busStripRow(for bus: AudioBus) -> some View {
        let itemCount = busAssignedItemsCount(for: bus)
        let canExpand = itemCount >= 2
        let isExpanded = canExpand && expandedBusIds.contains(bus.id)
        BusChannelStripView(
            bus: bus,
            isExpanded: isExpanded,
            isAutomationMode: engine.isAutomationHighlightActive,
            isBusAutomated: engine.isBusAutomated(bus.name),
            onToggleExpand: canExpand ? {
                if isExpanded {
                    expandedBusIds.remove(bus.id)
                } else {
                    expandedBusIds.insert(bus.id)
                }
            } : nil,
            onLiveDragChanged: {
                engine.updateSingleBusGain(bus)
            },
            reservedOutputLabel: { outName, isMono in
                engine.reservedOutputLabel(for: outName, isMono: isMono)
            }
        ) {
            engine.updateBusParameters(bus: bus)
        }
        
        // Expandable tray showing channels assigned to this bus (visible when 2+ items)
        if isExpanded {
            busAssignedChannelsTray(for: bus)
        }
    }

    @ViewBuilder
    private func busAssignedChannelsTray(for bus: AudioBus) -> some View {
        let busNameLower = bus.name.lowercased()
        
        if busNameLower == "click" {
            // Click stem tracks + Click subdivisions tray
            let clickTracks = engine.tracks.filter { $0.assignedBusName.lowercased() == "click" }
            ForEach(Array(clickTracks.enumerated()), id: \.element.id) { index, track in
                ChannelStripView(
                    track: track,
                    engine: engine,
                    index: index + 1,
                    isBeingDragged: false,
                    isInTray: true,
                    onParametersChanged: { engine.updateTrackParameters(track: track) },
                    onDelete: { engine.removeTrack(id: track.id) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
            }
            ClickSubdivisionChannelStripView(subdivision: .accent, engine: engine)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity.combined(with: .move(edge: .leading))))
            ClickSubdivisionChannelStripView(subdivision: .quarter, engine: engine)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity.combined(with: .move(edge: .leading))))
            ClickSubdivisionChannelStripView(subdivision: .eighth, engine: engine)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity.combined(with: .move(edge: .leading))))
            ClickSubdivisionChannelStripView(subdivision: .sixteenth, engine: engine)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity.combined(with: .move(edge: .leading))))
        } else if busNameLower == "pad" {
            // Pad stem tracks + Pad Channel strip feeding into Pad Bus
            let padTracks = engine.tracks.filter { $0.assignedBusName.lowercased() == "pad" }
            ForEach(Array(padTracks.enumerated()), id: \.element.id) { index, track in
                ChannelStripView(
                    track: track,
                    engine: engine,
                    index: index + 1,
                    isBeingDragged: false,
                    isInTray: true,
                    onParametersChanged: { engine.updateTrackParameters(track: track) },
                    onDelete: { engine.removeTrack(id: track.id) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
            }
            padBusChannelFaderStrip
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
        } else {
            let assignedTracks = engine.tracks.filter { $0.assignedBusName.lowercased() == busNameLower }
            if assignedTracks.isEmpty {
                emptyBusTrayPlaceholder(busName: bus.name)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .leading)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            } else {
                ForEach(Array(assignedTracks.enumerated()), id: \.element.id) { index, track in
                    ChannelStripView(
                        track: track,
                        engine: engine,
                        index: index + 1,
                        isBeingDragged: false,
                        isInTray: true,
                        onParametersChanged: { engine.updateTrackParameters(track: track) },
                        onDelete: { engine.removeTrack(id: track.id) }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .leading)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
                }
            }
        }
    }
    
    private var padBusChannelFaderStrip: some View {
        VStack(spacing: 8) {
            // Solo
            Button(action: {
                engine.padChannelSoloed.toggle()
                engine.updateMatrix()
                engine.markSessionChanged()
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
            
            // Mute
            Button(action: {
                engine.padChannelMuted.toggle()
                engine.updateMatrix()
                engine.markSessionChanged()
                if engine.isEditAutomationMode {
                    engine.recordAutomationPadMuted(engine.padChannelMuted)
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(engine.padChannelMuted ? Color(red: 0.85, green: 0.20, blue: 0.20) : Color(white: 0.16))
                        .frame(width: 44, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(engine.isAutomationHighlightActive ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color.clear, lineWidth: 1.0)
                        )
                    Rectangle()
                        .fill(engine.padChannelMuted ? Color.white : Color(red: 0.20, green: 0.75, blue: 0.95))
                        .frame(width: 18, height: 2)
                }
            }
            .buttonStyle(.plain)
            
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
                    engine.markSessionChanged()
                    if engine.isEditAutomationMode {
                        engine.recordAutomationPadPan(engine.padChannelPan)
                    }
                }
            )
            .frame(width: 68)
            
            // Fader
            GeometryReader { faderGeo in
                let slotHeight = faderGeo.size.height
                let capHeight: CGFloat = 34
                let capWidth: CGFloat = 42
                let travel = max(10, slotHeight - capHeight)
                let volume = CGFloat(engine.padChannelVolume)
                let currentY = (1.0 - volume) * travel + (capHeight / 2)
                let slotWidth = capWidth + 18
                
                ZStack {
                    Rectangle().fill(Color(white: 0.12)).frame(width: 3, height: slotHeight)
                    
                    StereoVUMeterPairView(meter: engine.padPlayer.meter, isMuted: engine.padChannelMuted)
                        .frame(width: 14, height: slotHeight - 8)
                        .allowsHitTesting(false)
                    
                    // Cap
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color(white: 0.38), Color(white: 0.26), Color(white: 0.18)]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: capWidth, height: capHeight)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                        Rectangle()
                            .fill(engine.padChannelMuted ? Color(white: 0.38) : Color.white)
                            .frame(width: capWidth - 6, height: 2)
                    }
                    .position(x: slotWidth / 2, y: currentY)
                    .onTapGesture(count: 2) {
                        engine.padChannelVolume = 0.80
                        engine.updateMatrix()
                        engine.markSessionChanged()
                        if engine.isEditAutomationMode {
                            engine.recordAutomationPadVolume(engine.padChannelVolume)
                        }
                    }
                }
                .frame(width: slotWidth, height: slotHeight)
                .position(x: faderGeo.size.width / 2, y: slotHeight / 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let clampedY = max(capHeight / 2, min(slotHeight - capHeight / 2, value.location.y))
                        let norm = 1.0 - Float((clampedY - capHeight / 2) / travel)
                        engine.padChannelVolume = max(0.0, min(1.0, norm))
                        engine.updateMatrix()
                    }.onEnded { _ in
                        engine.markSessionChanged()
                        if engine.isEditAutomationMode {
                            engine.recordAutomationPadVolume(engine.padChannelVolume)
                        }
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Text("Pad Ch")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.85))
                .frame(height: 20)
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
        .cornerRadius(4)
        .overlay(Rectangle().fill(Color(white: 0.22)).frame(width: 1), alignment: .trailing)
    }
    
    private func uploadArtworkDialog(for song: Song) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.message = "Choose an Image / Artwork for \(song.title)"
        panel.prompt = "Choose Image"
        
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            if let idx = engine.currentSetlist.songs.firstIndex(where: { $0.id == song.id }) {
                engine.currentSetlist.songs[idx].artworkData = data
                if engine.currentSong.id == song.id {
                    engine.currentSong.artworkData = data
                }
            }
        }
    }
    
    private func emptyBusTrayPlaceholder(busName: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundColor(Color(white: 0.35))
            Text("No Channels\nin \(busName)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(Color(white: 0.40))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.08, blue: 0.09).opacity(0.8))
        .cornerRadius(4)
        .overlay(Rectangle().fill(Color(white: 0.14)).frame(width: 1), alignment: .trailing)
    }
    
    // MARK: - MIDI Cues & Automation Track Lane (Blank Path for Future MIDI Cue Triangles)
    
    private var midiCuesLaneView: some View {
        Rectangle()
            .fill(Color(red: 0.06, green: 0.07, blue: 0.08))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
    }
    
    // MARK: - Native AppKit File Dialogs (Sessions & Songs)
    
    private func openSessionDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if let sessionType = UTType(filenameExtension: "pbsession") {
            panel.allowedContentTypes = [sessionType, .data, .package]
        }
        panel.message = "Choose a Playback Session File (.pbsession)"
        panel.prompt = "Open Session"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.loadSession(from: url)
                showStatus("Opened session: \(url.deletingPathExtension().lastPathComponent)")
            } catch {
                showStatus("Open error: \(error.localizedDescription)")
            }
        }
    }
    
    private func saveSessionDialog() {
        let panel = NSSavePanel()
        panel.treatsFilePackagesAsDirectories = false
        if let sessionType = UTType(filenameExtension: "pbsession") {
            panel.allowedContentTypes = [sessionType]
        }
        let defaultName = engine.currentSetlist.name.isEmpty ? "Untitled Session" : engine.currentSetlist.name
        panel.nameFieldStringValue = "\(defaultName).pbsession"
        panel.message = "Save Playback Session File (.pbsession)"
        panel.prompt = "Save Session"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.saveSession(to: url)
                showStatus("Saved session to \(url.lastPathComponent)")
            } catch {
                showStatus("Save error: \(error.localizedDescription)")
            }
        }
    }
    
    private func exportSongDialog() {
        guard !engine.currentSong.title.isEmpty else {
            showStatus("No song currently loaded to export")
            return
        }
        LibraryBrowserManager.shared.ensureDefaultDirectoriesExist()
        let panel = NSSavePanel()
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = LibraryBrowserManager.shared.songsDirectory
        if let songType = UTType(filenameExtension: "pbsong") {
            panel.allowedContentTypes = [songType]
        }
        panel.nameFieldStringValue = "\(engine.currentSong.title).pbsong"
        panel.message = "Export Song Package (.pbsong)"
        panel.prompt = "Export Song"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.saveCurrentSongPackage(to: url)
                LibraryBrowserManager.shared.refreshSongs()
                showStatus("Exported song package to \(url.lastPathComponent)")
            } catch {
                showStatus("Export error: \(error.localizedDescription)")
            }
        }
    }
    
    private func importSongDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        var allowed: [UTType] = [.data, .package]
        if let songType = UTType(filenameExtension: "pbsong") {
            allowed.insert(songType, at: 0)
        }
        if let multiType = UTType(filenameExtension: "multitrack") {
            allowed.insert(multiType, at: 1)
        }
        panel.allowedContentTypes = allowed
        panel.message = "Choose a Song Package (.pbsong or .multitrack)"
        panel.prompt = "Import Song"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.importSongPackage(from: url)
                showStatus("Imported song: \(url.deletingPathExtension().lastPathComponent)")
            } catch {
                showStatus("Import error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Album Art Stylers
    
    private func coverGradient(for index: Int) -> LinearGradient {
        switch index % 4 {
        case 0:
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.40, blue: 0.50), Color(red: 0.05, green: 0.15, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case 1:
            return LinearGradient(
                colors: [Color(red: 0.45, green: 0.25, blue: 0.15), Color(red: 0.15, green: 0.10, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case 2:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.35, blue: 0.40), Color(red: 0.10, green: 0.15, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.20, blue: 0.10), Color(red: 0.08, green: 0.05, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    private func transitionIconName(for index: Int) -> String {
        switch index % 3 {
        case 0: return "link"
        case 1: return "arrow.right.arrow.left"
        default: return "forward.end.alt"
        }
    }
    
    // MARK: - Global Keyboard Shortcuts
    
    private func setupKeyboardShortcuts() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let activeResponder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            if activeResponder is NSTextView || activeResponder is NSTextField {
                return event
            }
            
            let isCommand = event.modifierFlags.contains(.command)
            if !isCommand && (isNonEditMenuOpen || event.window?.sheetParent != nil || (event.window != nil && event.window != NSApp.mainWindow)) {
                return event
            }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            
            // CMD combinations take highest priority and bypass mapping managers
            if isCommand {
                if event.keyCode == 35 || chars == "p" {
                    engine.stopPadPlayerImmediately()
                    showStatus("Pad Stopped (Immediate)")
                    return nil
                }
                
                switch chars {
                case "o":
                    openSessionDialog()
                    return nil
                case "s":
                    saveSessionDialog()
                    return nil
                case "e":
                    exportSongDialog()
                    return nil
                case "i":
                    importSongDialog()
                    return nil
                case "n":
                    engine.newSession()
                    showStatus("New Blank Session")
                    return nil
                case "z":
                    if event.modifierFlags.contains(.shift) {
                        if engine.canRedo {
                            engine.redo()
                            showStatus("Redo")
                        }
                    } else {
                        if engine.canUndo {
                            engine.undo()
                            showStatus("Undo")
                        }
                    }
                    return nil
                case "=", "+":
                    engine.waveformZoomScale = min(4.0, engine.waveformZoomScale + 0.25)
                    return nil
                case "-":
                    engine.waveformZoomScale = max(0.4, engine.waveformZoomScale - 0.25)
                    return nil
                default:
                    return event
                }
            }
            
            // Allow KeyboardMappingManager to intercept (for learning or mapped shortcuts)
            if KeyboardMappingManager.shared.handleKeyDown(event: event) {
                return nil
            }
            
            // Spacebar: Play / Pause
            if event.keyCode == 49 {
                if engine.playbackState != .playing && (engine.isEditDrawerOpen || engine.isEditingArrangement) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        engine.closeEditMode()
                    }
                }
                engine.togglePlayPause()
                return nil
            }
            if let chars = chars {
                switch chars {
                case "p":
                    engine.togglePadPlayer()
                    if engine.isEditAutomationMode {
                        engine.recordAutomationPadActive(engine.isPadActive)
                    }
                    return nil
                case "f":
                    engine.toggleFade()
                    showStatus(engine.isFadeActive ? "Fading Out Music Stems..." : "Fading In...")
                    return nil
                case "r":
                    engine.returnToZero()
                    showStatus("Return to Zero")
                    return nil
                case "l":
                    engine.toggleSingleLoop()
                    return nil
                case "i":
                    engine.toggleInfiniteLoop()
                    return nil
                case "s":
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSetlistMenuOpen.toggle()
                    }
                    return nil
                case "e":
                    isSongBuilderPresented = true
                    return nil
                case "b":
                    isBussesDrawerPresented = true
                    return nil
                default:
                    break
                }
            }
            
            if event.keyCode == 123 {
                engine.jumpToPreviousSection()
                return nil
            } else if event.keyCode == 124 {
                engine.jumpToNextSection()
                return nil
            }
            
            return event
        }
    }
    
    private func removeKeyboardShortcuts() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    private var currentSection: SongSection? {
        let cur = engine.transportPosition.currentTime
        return engine.currentSong.sections.first(where: { cur >= $0.startTime && cur < $0.endTime })
    }
    
    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var audioURLs: [URL] = []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ext == "pbsong" || ext == "multitrack" {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    try engine.importSongPackage(from: url)
                    showStatus("Imported song package: \(url.deletingPathExtension().lastPathComponent)")
                } else if ext == "pbsession" {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    try engine.loadSession(from: url)
                    showStatus("Loaded session: \(url.deletingPathExtension().lastPathComponent)")
                } else {
                    audioURLs.append(url)
                }
            }
            if !audioURLs.isEmpty {
                engine.addTracksConcurrently(from: audioURLs)
                engine.ensureClickAndGuideTracksExist()
                engine.autoSortTracks()
                engine.recalculateAggregateWaveform(samplesCount: 4000)
                engine.updateMatrix()
                showStatus("Successfully imported and sorted stems")
            }
        } catch {
            showStatus("Import error: \(error.localizedDescription)")
        }
    }
    
    private func handleDroppedURL(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "pbsong" || ext == "multitrack" {
                try engine.importSongPackage(from: url)
                showStatus("Imported song: \(url.deletingPathExtension().lastPathComponent)")
            } else if ext == "pbsession" {
                try engine.loadSession(from: url)
                showStatus("Loaded session: \(url.deletingPathExtension().lastPathComponent)")
            } else if ["wav", "mp3", "m4a", "aif", "aiff"].contains(ext) {
                handleImportedFiles(.success([url]))
            } else {
                showStatus("Unsupported file type: .\(ext)")
            }
        } catch {
            showStatus("Error loading file: \(error.localizedDescription)")
        }
    }
    
    private func showStatus(_ msg: String) {
        withAnimation {
            statusMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation {
                if statusMessage == msg {
                    statusMessage = nil
                }
            }
        }
    }
}

// MARK: - Drag & Drop Song Reordering Delegate

struct SongDropDelegate: DropDelegate {
    let targetSong: Song
    @Binding var draggedSong: Song?
    let onMove: (UUID, UUID) -> Void
    
    func dropEntered(info: DropInfo) {
        guard let dragged = draggedSong, dragged.id != targetSong.id else { return }
        onMove(dragged.id, targetSong.id)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        draggedSong = nil
        return true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Drag & Drop Track Reordering Delegate

struct TrackDropDelegate: DropDelegate {
    let targetTrack: StemTrack
    @Binding var draggedTrack: StemTrack?
    let onMove: (UUID, UUID) -> Void
    
    func dropEntered(info: DropInfo) {
        guard let dragged = draggedTrack, dragged.id != targetTrack.id else { return }
        onMove(dragged.id, targetTrack.id)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        draggedTrack = nil
        return true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Isolated High-Frequency Transport Subviews (Prevents Re-Evaluating 26+ Channel Strips)

private struct LiveBPMTimeSigView: View {
    @ObservedObject var clock: TransportDisplayClockModel
    let baseBPM: Double
    let timeSignatureNumerator: Int
    let timeSignatureDenominator: Int
    let isPlaying: Bool
    
    private func formattedBPM(_ bpm: Double) -> String {
        // If whole number (e.g. 64.0), display as integer "64".
        // If fractional (e.g. 74.5 or 128.35), display down to the hundredths place trimming trailing zero if any.
        let roundedHundredth = (bpm * 100).rounded() / 100.0
        if abs(roundedHundredth - roundedHundredth.rounded()) < 0.001 {
            return "\(Int(roundedHundredth.rounded()))"
        } else {
            // Check if tenths place is enough
            let roundedTenth = (bpm * 10).rounded() / 10.0
            if abs(roundedHundredth - roundedTenth) < 0.001 {
                return String(format: "%.1f", bpm)
            } else {
                return String(format: "%.2f", bpm)
            }
        }
    }
    
    var body: some View {
        let displayedBPM: Double = {
            if isPlaying && clock.position.currentBPM > 20 {
                return clock.position.currentBPM
            }
            return baseBPM
        }()
        let isDynamicShift = isPlaying && abs(displayedBPM - baseBPM) >= 1.5
        let bpmStr = formattedBPM(displayedBPM)
        let fontSize: CGFloat = 17
        
        VStack(spacing: 2) {
            Text(bpmStr)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(isDynamicShift ? Color(red: 0.30, green: 0.88, blue: 0.98) : .white)
                .minimumScaleFactor(0.85)
                .lineLimit(1)
            
            Rectangle()
                .fill(Color(white: 0.45))
                .frame(width: 35, height: 1.2)
            
            let dispNum = clock.position.currentTimeSignatureNumerator > 0 ? clock.position.currentTimeSignatureNumerator : timeSignatureNumerator
            let dispDen = clock.position.currentTimeSignatureDenominator > 0 ? clock.position.currentTimeSignatureDenominator : timeSignatureDenominator
            Text("\(dispNum)/\(dispDen)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(
                    (dispNum != timeSignatureNumerator || dispDen != timeSignatureDenominator)
                    ? Color(red: 0.30, green: 0.88, blue: 0.98)
                    : .white
                )
        }
        .frame(width: 60, height: 67)
    }
}

private struct LiveTransportTimeCardView: View {
    @ObservedObject var clock: TransportDisplayClockModel
    let boxBackground: Color
    let boxBorder: Color
    
    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(clock.position.formattedCurrentTime)
                .font(.system(size: 23, weight: .regular, design: .monospaced))
                .foregroundColor(.white)
            
            Text("\(clock.position.formattedShortTime) / \(clock.position.formattedDuration)")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.60))
        }
        .frame(width: 114, height: 67)
        .background(boxBackground)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(boxBorder, lineWidth: 1)
        )
    }
}

private struct LiveWaveformTimelineContainer: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let clock: TransportClockModel
    var isStationary: Bool = false
    
    var body: some View {
        WaveformTimelineView(
            engine: engine,
            clock: clock,
            aggregateWaveform: engine.aggregateWaveform,
            sections: engine.currentSong.sections,
            totalDuration: engine.currentSongDuration,
            bpm: engine.currentSong.bpm,
            timeSignatureNumerator: engine.currentSong.timeSignatureNumerator,
            isLoopActive: engine.isLoopActive,
            loopedSection: engine.loopedSection,
            isStationary: isStationary,
            onSeek: { targetTime in
                engine.seek(to: targetTime)
            },
            onToggleSectionLoop: { section in
                engine.toggleSectionLoop(section)
            }
        )
    }
}

// MARK: - Bottom Mixer Scroll Bar Overlay & Cocoa Scroll Tracker

/// Sleek draggable overlay scroll bar rendered at the bottom of the screen on top of the channel strips
private struct BottomMixerScrollerOverlayView: View {
    @Binding var scrollOffset: CGFloat
    let contentWidth: CGFloat
    let containerWidth: CGFloat
    let onScrolled: (CGFloat) -> Void
    
    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false
    
    private var maxScroll: CGFloat {
        max(1.0, contentWidth - containerWidth)
    }
    
    private var visibleRatio: CGFloat {
        min(1.0, max(0.05, containerWidth / max(1.0, contentWidth)))
    }
    
    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let thumbWidth = max(40.0, min(trackWidth, visibleRatio * trackWidth))
            let maxThumbTravel = max(0.0, trackWidth - thumbWidth)
            let currentOffset = maxThumbTravel > 0 && maxScroll > 0 ? (max(0.0, min(maxScroll, scrollOffset)) / maxScroll) * maxThumbTravel : 0
            
            ZStack(alignment: .leading) {
                // Background Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(isHovered ? 0.60 : 0.35))
                    .frame(height: isHovered || isDragging ? 6 : 5)
                
                // Draggable Thumb
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: isDragging ? 0.80 : (isHovered ? 0.65 : 0.48)),
                                Color(white: isDragging ? 0.68 : (isHovered ? 0.52 : 0.36))
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: thumbWidth, height: isHovered || isDragging ? 6 : 5)
                    .offset(x: currentOffset)
                    .shadow(color: Color.black.opacity(0.40), radius: 1, x: 0, y: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        if maxThumbTravel > 0 {
                            let fraction = max(0.0, min(1.0, (gesture.location.x - thumbWidth / 2) / maxThumbTravel))
                            let target = fraction * maxScroll
                            scrollOffset = target
                            onScrolled(target)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
        .frame(height: 7)
    }
}

/// Attaches to the inner HStack to observe the NSScrollView's bounds & dimensions and disable native bottom scroller
private struct MixerScrollTracker: NSViewRepresentable {
    @Binding var scrollOffset: CGFloat
    @Binding var contentWidth: CGFloat
    @Binding var containerWidth: CGFloat
    @Binding var scrollViewRef: NSScrollView?
    
    func makeNSView(context: Context) -> ScrollObservingNSView {
        let view = ScrollObservingNSView()
        view.onUpdate = { offset, contentW, containerW, sv in
            DispatchQueue.main.async {
                if abs(self.scrollOffset - offset) > 0.5 {
                    self.scrollOffset = offset
                }
                if abs(self.contentWidth - contentW) > 1.0 {
                    self.contentWidth = contentW
                }
                if abs(self.containerWidth - containerW) > 1.0 {
                    self.containerWidth = containerW
                }
                if self.scrollViewRef !== sv {
                    self.scrollViewRef = sv
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: ScrollObservingNSView, context: Context) {
        if nsView.observedClipView == nil {
            nsView.attachObserver()
        }
    }
}

private final class ScrollObservingNSView: NSView {
    var onUpdate: ((CGFloat, CGFloat, CGFloat, NSScrollView?) -> Void)?
    private var clipObserver: Any?
    private var frameObserver: Any?
    private var selfFrameObserver: Any?
    weak var observedClipView: NSClipView?
    private var lastOffset: CGFloat = -99999
    private var lastContentW: CGFloat = -99999
    private var lastContainerW: CGFloat = -99999
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachObserver()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachObserver()
    }
    
    func attachObserver() {
        guard let sv = enclosingScrollView, let clipView = sv.contentView as NSClipView? else { return }
        if sv.hasHorizontalScroller {
            sv.hasHorizontalScroller = false
        }
        
        if observedClipView === clipView {
            notifyIfChanged()
            return
        }
        
        if let obs = clipObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = frameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = selfFrameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        self.postsFrameChangedNotifications = true
        
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.notifyIfChanged()
        }
        
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.notifyIfChanged()
        }
        
        selfFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.notifyIfChanged()
        }
        
        notifyIfChanged()
    }
    
    func notifyIfChanged() {
        guard let sv = enclosingScrollView, let clipView = sv.contentView as NSClipView? else { return }
        let offset = clipView.bounds.origin.x
        let contentW = max(clipView.documentRect.width, self.bounds.width)
        let containerW = clipView.bounds.width
        
        guard abs(offset - lastOffset) > 0.5 ||
              abs(contentW - lastContentW) > 1.0 ||
              abs(containerW - lastContainerW) > 1.0 else {
            return
        }
        lastOffset = offset
        lastContentW = contentW
        lastContainerW = containerW
        onUpdate?(offset, contentW, containerW, sv)
    }
    
    deinit {
        if let obs = clipObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = frameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = selfFrameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

/// Presents a popover on the right (`.trailing`) side of its anchor if space permits
/// within the window and screen, or dynamically switches to the left (`.leading`) side.
private struct DynamicSidePopover<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let popoverWidth: CGFloat
    let popoverContent: () -> PopoverContent

    @State private var preferredEdge: Edge = .trailing

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            updatePreferredEdge(for: geo.frame(in: .global))
                        }
                        .onChange(of: isPresented) { presented in
                            if presented {
                                updatePreferredEdge(for: geo.frame(in: .global))
                            }
                        }
                }
            )
            .popover(isPresented: $isPresented, arrowEdge: preferredEdge) {
                popoverContent()
            }
    }

    private func updatePreferredEdge(for anchorFrame: CGRect) {
        let margin: CGFloat = 16.0
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let windowWidth = window?.contentView?.bounds.width ?? window?.frame.width ?? NSScreen.main?.visibleFrame.width ?? 1440
        let fitsInWindowRight = (anchorFrame.maxX + popoverWidth + margin) <= windowWidth

        var fitsOnScreenRight = true
        if let window, let screen = window.screen ?? NSScreen.main {
            let screenAnchorMaxX = window.frame.minX + anchorFrame.maxX
            fitsOnScreenRight = (screenAnchorMaxX + popoverWidth + margin) <= screen.visibleFrame.maxX
        }

        if fitsInWindowRight && fitsOnScreenRight {
            preferredEdge = .trailing
        } else {
            let fitsInWindowLeft = (anchorFrame.minX - popoverWidth - margin) >= 0
            if fitsInWindowLeft {
                preferredEdge = .leading
            } else {
                preferredEdge = (windowWidth - anchorFrame.maxX) >= anchorFrame.minX ? .trailing : .leading
            }
        }
    }
}
