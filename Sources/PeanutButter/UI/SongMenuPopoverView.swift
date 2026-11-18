import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Authentic MultiTracks Playback Song Menu Popover matching Photo 1 & Photo 2
public struct SongMenuPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var padManager = PadLibraryManager.shared
    @ObservedObject var libraryManager = LibraryBrowserManager.shared
    var songIndex: Int?
    let onClose: () -> Void
    var onEditSong: (() -> Void)? = nil
    var onBackToLibrary: (() -> Void)? = nil
    var onConfirmAddToSetlist: ((Song) -> Void)? = nil
    
    public enum MenuScreen {
        case main
        case arrangementSelection
        case saveAsNewArrangement
        case keySelection
        case tempoSelection
        case padSelection
    }
    
    @State private var stagedSong: Song?
    @State private var currentScreen: MenuScreen = .main
    @State private var playlistText: String = ""
    @State private var playlistItemText: String = ""
    @State private var midiCuesStatusMessage: String? = nil
    @State private var tempoInputText: String = ""
    @State private var pendingTransposeSemitones: Int
    @State private var pendingPreserveVocalFormants: Bool
    @State private var pendingTempoBPM: Double
    @State private var pendingArrangementId: UUID?
    @State private var isHoveringTempoWheel: Bool = false
    @State private var scrollWheelMonitor: Any? = nil
    @State private var scrollWheelAccumulator: CGFloat = 0.0
    @State private var newArrangementName: String = ""
    @State private var showSavedConfirmation: Bool = false
    @State private var showRestoredConfirmation: Bool = false
    @State private var isPracticeBouncePresented: Bool = false
    @State private var savedToLocalConfirmation: Bool = false
    @State private var savedToCloudConfirmation: Bool = false
    @State private var savedChangesConfirmation: Bool = false
    
    public init(
        engine: MultitrackAudioEngine,
        songIndex: Int? = nil,
        stagedSong: Song? = nil,
        onClose: @escaping () -> Void,
        onEditSong: (() -> Void)? = nil,
        onBackToLibrary: (() -> Void)? = nil,
        onConfirmAddToSetlist: ((Song) -> Void)? = nil
    ) {
        self.engine = engine
        self.songIndex = songIndex
        self.onClose = onClose
        self.onEditSong = onEditSong
        self.onBackToLibrary = onBackToLibrary
        self.onConfirmAddToSetlist = onConfirmAddToSetlist
        let s: Song = {
            if let staged = stagedSong {
                return staged
            }
            if let idx = songIndex, idx >= 0 && idx < engine.currentSetlist.songs.count {
                return engine.currentSetlist.songs[idx]
            }
            return engine.currentSong
        }()
        _stagedSong = State(initialValue: stagedSong)
        _playlistText = State(initialValue: s.proPresenterPlaylist.map { "\($0)" } ?? "")
        _playlistItemText = State(initialValue: s.proPresenterPlaylistItem.map { "\($0)" } ?? "")
        _tempoInputText = State(initialValue: Self.formatBPM(s.bpm, minDecimals: Song.tempoDecimalPrecision(for: s.originalBPM > 0 ? s.originalBPM : s.bpm)))
        _pendingTransposeSemitones = State(initialValue: s.transposeSemitones)
        _pendingPreserveVocalFormants = State(initialValue: s.preserveVocalFormants)
        _pendingTempoBPM = State(initialValue: (s.bpm * 100.0).rounded() / 100.0)
        _pendingArrangementId = State(initialValue: s.activeArrangementId)
    }
    
    private var isPreAddMode: Bool {
        stagedSong != nil && onConfirmAddToSetlist != nil
    }
    
    private static func formatBPM(_ bpm: Double, minDecimals: Int = 0) -> String {
        let rounded = (bpm * 100.0).rounded() / 100.0
        let decimals = max(minDecimals, Song.tempoDecimalPrecision(for: rounded))
        return Song.formatBPM(rounded, decimals: decimals)
    }
    
    private var targetSong: Song {
        if let staged = stagedSong {
            return staged
        }
        if let idx = songIndex, idx >= 0 && idx < engine.currentSetlist.songs.count {
            return engine.currentSetlist.songs[idx]
        }
        return engine.currentSong
    }
    
    private var effectiveSongIndex: Int {
        return songIndex ?? engine.currentSongIndex
    }
    
    private var activePadPackName: String {
        let chosenId = targetSong.padPresetId ?? padManager.activePackId
        return padManager.availablePacks.first(where: { $0.id == chosenId })?.name ?? "Fundamental"
    }
    
    private var songDurationString: String {
        let totalSecs = targetSong.sections.map { $0.endTime }.max() ?? 0.0
        let m = Int(totalSecs) / 60
        let s = Int(totalSecs) % 60
        return String(format: "%d:%02d", m, s)
    }
    
    public var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.13)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                switch currentScreen {
                case .main:
                    mainMenuHeader
                    Divider().background(Color(white: 0.18))
                    ScrollView(showsIndicators: true) {
                        mainMenuContent
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    
                case .arrangementSelection:
                    arrangementSubmenuHeader
                    Divider().background(Color(white: 0.18))
                    ScrollView(showsIndicators: true) {
                        arrangementSubmenuContent
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    
                case .saveAsNewArrangement:
                    saveAsNewArrangementHeader
                    Divider().background(Color(white: 0.18))
                    ScrollView(showsIndicators: true) {
                        saveAsNewArrangementContent
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    
                case .keySelection:
                    keySubmenuHeader
                    Divider().background(Color(white: 0.18))
                    ScrollView(showsIndicators: true) {
                        keySubmenuContent
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    
                case .tempoSelection:
                    tempoSubmenuHeader
                    Divider().background(Color(white: 0.18))
                    tempoSubmenuContent
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    
                case .padSelection:
                    padSubmenuHeader
                    Divider().background(Color(white: 0.18))
                    ScrollView(showsIndicators: true) {
                        padSubmenuContent
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .frame(width: 325, height: 530)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: targetSong.id) { _ in
            playlistText = targetSong.proPresenterPlaylist.map { "\($0)" } ?? ""
            playlistItemText = targetSong.proPresenterPlaylistItem.map { "\($0)" } ?? ""
            let orig = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
            tempoInputText = Self.formatBPM(targetSong.bpm, minDecimals: Song.tempoDecimalPrecision(for: orig))
            pendingTransposeSemitones = targetSong.transposeSemitones
            pendingPreserveVocalFormants = targetSong.preserveVocalFormants
            pendingTempoBPM = (targetSong.bpm * 100.0).rounded() / 100.0
            pendingArrangementId = targetSong.activeArrangementId
        }
        .onDisappear {
            removeScrollWheelMonitor()
        }
    }
    
    private func commitTypedTempoInput() {
        let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
        let cleaned = tempoInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = Double(cleaned), raw.isFinite {
            let clamped = Song.clampedShiftedTempo(raw, originalBPM: origBPM)
            pendingTempoBPM = clamped
            tempoInputText = Self.formatBPM(clamped, minDecimals: Song.tempoDecimalPrecision(for: origBPM))
        } else {
            tempoInputText = Self.formatBPM(pendingTempoBPM, minDecimals: Song.tempoDecimalPrecision(for: origBPM))
        }
    }
    
    private func handleDone() {
        commitTypedTempoInput()
        if isPreAddMode, var staged = stagedSong, let onConfirm = onConfirmAddToSetlist {
            staged.activeArrangementId = pendingArrangementId
            if let arrId = pendingArrangementId,
               let arr = staged.savedArrangements.first(where: { $0.id == arrId }) {
                staged.sections = arr.sections
            } else if pendingArrangementId == nil && !staged.defaultSections.isEmpty {
                staged.sections = staged.defaultSections
            }
            staged.transposeSemitones = pendingTransposeSemitones
            staged.preserveVocalFormants = pendingPreserveVocalFormants
            let origBPM = staged.originalBPM > 0 ? staged.originalBPM : staged.bpm
            if staged.originalBPM <= 0 {
                staged.originalBPM = origBPM
            }
            staged.bpm = Song.clampedShiftedTempo(pendingTempoBPM, originalBPM: origBPM)
            onConfirm(staged)
            return
        }
        let idx = songIndex
        if pendingArrangementId != targetSong.activeArrangementId {
            engine.selectArrangement(id: pendingArrangementId, forSongIndex: idx)
        }
        let formantChanged = pendingPreserveVocalFormants != targetSong.preserveVocalFormants
        let transposeChanged = pendingTransposeSemitones != targetSong.transposeSemitones
        let tempoChanged = abs(pendingTempoBPM - targetSong.bpm) > 0.005
        if formantChanged || transposeChanged || tempoChanged {
            engine.setKeyAndTempo(
                semitones: pendingTransposeSemitones,
                preserveVocalFormants: pendingPreserveVocalFormants,
                tempoBPM: tempoChanged ? pendingTempoBPM : nil,
                forSongIndex: idx
            )
        }
        onClose()
    }
    
    // MARK: - Headers
    
    private var mainMenuHeader: some View {
        HStack {
            if isPreAddMode, let onBackToLibrary {
                Button(action: onBackToLibrary) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Songs")
                            .font(.system(size: 14, weight: .regular))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onClose) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            Text(targetSong.title.isEmpty ? "Song Menu" : targetSong.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            Button(action: handleDone) {
                Text(isPreAddMode ? "Add" : "Done")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private var arrangementSubmenuHeader: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .regular))
                }
                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Arrangement")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: handleDone) {
                Text("Done")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private var saveAsNewArrangementHeader: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }) {
                Text("Cancel")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Save As New")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            let canCommit = !newArrangementName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: commitSaveAsNewArrangement) {
                Text("Save")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(canCommit ? Color(red: 0.25, green: 0.65, blue: 1.0) : Color(white: 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private func commitSaveAsNewArrangement() {
        let trimmed = newArrangementName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newId = engine.saveAsNewArrangement(name: trimmed, forSongIndex: effectiveSongIndex)
        pendingArrangementId = newId
        newArrangementName = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            currentScreen = .main
        }
    }
    
    private var keySubmenuHeader: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .regular))
                }
                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Key")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: handleDone) {
                Text("Done")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private var tempoSubmenuHeader: some View {
        HStack {
            Button(action: {
                commitTypedTempoInput()
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .regular))
                }
                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Tempo")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: handleDone) {
                Text("Done")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private var padSubmenuHeader: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .regular))
                }
                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Pad Sound")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: handleDone) {
                Text("Done")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    // MARK: - Main Menu Content (Matching Photo 1)
    
    private var mainMenuContent: some View {
        VStack(spacing: 16) {
            // 1. ARRANGEMENTS SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("ARRANGEMENTS")
                
                VStack(spacing: 0) {
                    // Arrangement row (Opens Arrangement Submenu)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .arrangementSelection
                        }
                    }) {
                        HStack {
                            Text("Arrangement")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                let dispArrName = targetSong.arrangementName(for: pendingArrangementId)
                                Text(dispArrName)
                                    .font(.system(size: 13, weight: pendingArrangementId != nil ? .medium : .regular))
                                    .foregroundColor(pendingArrangementId != nil ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(white: 0.55))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    rowDivider
                    
                    // Restore From Save
                    Button(action: {
                        engine.restoreArrangementFromSave(forSongIndex: effectiveSongIndex)
                        pendingArrangementId = targetSong.activeArrangementId
                        showRestoredConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            showRestoredConfirmation = false
                        }
                    }) {
                        HStack {
                            Text(showRestoredConfirmation ? "Restored ✓" : "Restore From Save")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    rowDivider
                    
                    // Save (Strictly disabled when "Default" is active — Default can never be saved over)
                    let canSaveToActiveArrangement = (targetSong.activeArrangementId != nil)
                    Button(action: {
                        guard canSaveToActiveArrangement else { return }
                        engine.saveCurrentArrangement(forSongIndex: effectiveSongIndex)
                        showSavedConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            showSavedConfirmation = false
                        }
                    }) {
                        HStack {
                            Text(showSavedConfirmation ? "Saved ✓" : "Save")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(canSaveToActiveArrangement ? Color(red: 0.25, green: 0.65, blue: 1.0) : Color(white: 0.35))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSaveToActiveArrangement)
                    
                    rowDivider
                    
                    // Save As New (Opens context screen to name the new arrangement)
                    Button(action: {
                        let nextCount = targetSong.savedArrangements.count + 1
                        newArrangementName = "Arrangement \(nextCount)"
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .saveAsNewArrangement
                        }
                    }) {
                        HStack {
                            Text("Save As New")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 2. CONTENT SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("CONTENT")
                
                VStack(spacing: 0) {
                    HStack {
                        Text("Tracks")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(engine.tracks.isEmpty ? "None" : "All")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(Color(white: 0.55))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(white: 0.40))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 3. KEY & TEMPO SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("KEY & TEMPO")
                
                VStack(spacing: 0) {
                    // Key Row (Opens Key Submenu)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .keySelection
                        }
                    }) {
                        HStack {
                            Text("Key")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                let baseKey = (targetSong.musicalKey.isEmpty || targetSong.musicalKey == "—") ? "C" : targetSong.musicalKey
                                let displayedKey = targetSong.musicalKey.isEmpty && pendingTransposeSemitones == 0
                                    ? "—"
                                    : MusicalKeyHelper.transposedKey(originalKey: baseKey, semitones: pendingTransposeSemitones)
                                Text(displayedKey)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(pendingTransposeSemitones != 0 ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(white: 0.55))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    rowDivider
                    
                    // Tempo Row (Opens Tempo Wheel & Entry Submenu)
                    Button(action: {
                        let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
                        tempoInputText = Self.formatBPM(pendingTempoBPM, minDecimals: Song.tempoDecimalPrecision(for: origBPM))
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .tempoSelection
                        }
                    }) {
                        HStack {
                            Text("Tempo")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
                                let isShifted = abs(pendingTempoBPM - origBPM) > 0.005
                                Text("\(Self.formatBPM(pendingTempoBPM, minDecimals: Song.tempoDecimalPrecision(for: origBPM))) BPM")
                                    .font(.system(size: 13, weight: isShifted ? .medium : .regular))
                                    .foregroundColor(isShifted ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(white: 0.55))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    rowDivider

                    // Render Source Indicator (WAV vs M4A) + Force Re-render
                    HStack(spacing: 8) {
                        Text("Render Source")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)

                        Spacer()

                        let srcLabel = engine.transposeInputSourceLabel(for: targetSong, atIndex: songIndex)
                        let isLossless = srcLabel == "WAV"
                        Text(srcLabel)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isLossless ? Color(red: 0.25, green: 0.88, blue: 0.62) : (srcLabel == "WAV + M4A" ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(red: 0.98, green: 0.68, blue: 0.25)))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background((isLossless ? Color(red: 0.25, green: 0.88, blue: 0.62) : (srcLabel == "WAV + M4A" ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(red: 0.98, green: 0.68, blue: 0.25))).opacity(0.16))
                            .cornerRadius(4)

                        let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
                        let isSongTransformed = targetSong.transposeSemitones != 0 || abs(targetSong.bpm - origBPM) > 0.005 || pendingTransposeSemitones != 0 || abs(pendingTempoBPM - origBPM) > 0.005
                        if isSongTransformed {
                            Button(action: {
                                if let idx = songIndex {
                                    engine.forceRerenderKeyAndTempo(forSongIndex: idx)
                                } else {
                                    engine.forceRerenderKeyAndTempo()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10.5, weight: .bold))
                                    Text("Re-render")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.28))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .disabled(engine.isTransposing)
                            .help("Clear cached audio and force a fresh transpose/tempo render")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 4. DURATION SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("DURATION")
                
                VStack(spacing: 0) {
                    HStack {
                        Text("Start Point")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)
                        Spacer()
                        Text("0:00")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Color(white: 0.55))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    
                    rowDivider
                    
                    HStack {
                        Text("End Point")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)
                        Spacer()
                        Text(songDurationString)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Color(white: 0.55))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 5. 5-SECOND FADE OUT SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("SONG END")
                
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("5 Second Fade Out")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Text("Fades music stems over final 5s of song")
                                .font(.system(size: 9.5))
                                .foregroundColor(Color(white: 0.45))
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { targetSong.endFadeOutEnabled },
                            set: { newValue in
                                if isPreAddMode {
                                    stagedSong?.endFadeOutEnabled = newValue
                                } else {
                                    engine.updateSongEndFadeOut(at: effectiveSongIndex, enabled: newValue)
                                }
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.85, blue: 0.65)))
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 6. PAD PLAYER SECTION
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("PAD PLAYER")
                
                VStack(spacing: 0) {
                    // Start Pad With Song
                    HStack {
                        Text("Start Pad With Song")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { targetSong.startPadWithSong },
                            set: { newValue in
                                if isPreAddMode {
                                    stagedSong?.startPadWithSong = newValue
                                } else {
                                    engine.updateSongStartPadWithSong(at: effectiveSongIndex, enabled: newValue)
                                }
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.85, blue: 0.55)))
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    
                    rowDivider
                    
                    // Choose Pad Sound
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .padSelection
                        }
                    }) {
                        HStack {
                            Text("Pad Sound")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                Text(activePadPackName)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(Color(white: 0.55))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    rowDivider
                    
                    // Intro/Outro Only Toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Intro/Outro Only")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Text("Only plays pad during Count In, Intro, and Outro")
                                .font(.system(size: 9.5))
                                .foregroundColor(Color(white: 0.45))
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { targetSong.padIntroOutroOnly },
                            set: { newValue in
                                if isPreAddMode {
                                    stagedSong?.padIntroOutroOnly = newValue
                                } else {
                                    engine.updateSongPadIntroOutroOnly(at: effectiveSongIndex, enabled: newValue)
                                }
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.85, blue: 0.55)))
                        .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 7. MIDI OUT SECTION (Formerly ProPresenter MIDI)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    sectionHeader("MIDI OUT")
                    Spacer()
                    if targetSong.proPresenterPlaylist != nil || targetSong.proPresenterPlaylistItem != nil {
                        Button("Test") {
                            MIDICueEngine.shared.fireProPresenterSongStart(
                                playlist: targetSong.proPresenterPlaylist,
                                playlistItem: targetSong.proPresenterPlaylistItem
                            )
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.75, blue: 1.0))
                        .buttonStyle(.plain)
                    }
                }
                
                VStack(spacing: 0) {
                    // Playlist Trigger (Note F-1)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Playlist")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Text("Sends Note F-1 at velocity")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.45))
                        }
                        
                        Spacer()
                        
                        TextField("Off", text: $playlistText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 44)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.20))
                            .cornerRadius(4)
                            .onChange(of: playlistText) { newText in
                                let digits = newText.filter { $0.isNumber }
                                if let v = Int(digits), v >= 1 {
                                    let clamped = min(127, v)
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylist = clamped
                                    } else {
                                        engine.setProPresenterPlaylist(clamped, forSongIndex: songIndex)
                                    }
                                } else if digits.isEmpty {
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylist = nil
                                    } else {
                                        engine.setProPresenterPlaylist(nil, forSongIndex: songIndex)
                                    }
                                }
                            }
                        
                        Menu {
                            Button("Off") {
                                playlistText = ""
                                if isPreAddMode {
                                    stagedSong?.proPresenterPlaylist = nil
                                } else {
                                    engine.setProPresenterPlaylist(nil, forSongIndex: songIndex)
                                }
                            }
                            Divider()
                            ForEach(1...127, id: \.self) { num in
                                Button("\(num)") {
                                    playlistText = "\(num)"
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylist = num
                                    } else {
                                        engine.setProPresenterPlaylist(num, forSongIndex: songIndex)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(white: 0.65))
                                .frame(width: 22, height: 22)
                                .background(Color(white: 0.20))
                                .cornerRadius(4)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    
                    rowDivider
                    
                    // Playlist Item Trigger (Note F#-1)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Playlist Item")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            Text("Sends Note F#-1 at velocity")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.45))
                        }
                        
                        Spacer()
                        
                        TextField("Off", text: $playlistItemText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 44)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.20))
                            .cornerRadius(4)
                            .onChange(of: playlistItemText) { newText in
                                let digits = newText.filter { $0.isNumber }
                                if let v = Int(digits), v >= 1 {
                                    let clamped = min(127, v)
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylistItem = clamped
                                    } else {
                                        engine.setProPresenterPlaylistItem(clamped, forSongIndex: songIndex)
                                    }
                                } else if digits.isEmpty {
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylistItem = nil
                                    } else {
                                        engine.setProPresenterPlaylistItem(nil, forSongIndex: songIndex)
                                    }
                                }
                            }
                        
                        Menu {
                            Button("Off") {
                                playlistItemText = ""
                                if isPreAddMode {
                                    stagedSong?.proPresenterPlaylistItem = nil
                                } else {
                                    engine.setProPresenterPlaylistItem(nil, forSongIndex: songIndex)
                                }
                            }
                            Divider()
                            ForEach(1...127, id: \.self) { num in
                                Button("\(num)") {
                                    playlistItemText = "\(num)"
                                    if isPreAddMode {
                                        stagedSong?.proPresenterPlaylistItem = num
                                    } else {
                                        engine.setProPresenterPlaylistItem(num, forSongIndex: songIndex)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(white: 0.65))
                                .frame(width: 22, height: 22)
                                .background(Color(white: 0.20))
                                .cornerRadius(4)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 7B. REFRESH & SAVE MIDI CUES
            if !isPreAddMode {
                VStack(spacing: 0) {
                    Button(action: {
                        let status = engine.refreshMIDICuesFromLibrary(forSongIndex: songIndex)
                        playlistText = targetSong.proPresenterPlaylist.map { "\($0)" } ?? ""
                        playlistItemText = targetSong.proPresenterPlaylistItem.map { "\($0)" } ?? ""
                        midiCuesStatusMessage = status
                    }) {
                        HStack {
                            Text("Refresh MIDI Cues")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            Spacer()
                            if let msg = midiCuesStatusMessage, msg.hasPrefix("Refreshed") || msg.hasPrefix("No ") || msg.hasPrefix("Failed") {
                                Text(msg)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color(white: 0.55))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    rowDivider
                    
                    Button(action: {
                        midiCuesStatusMessage = engine.saveMIDICuesToLibrary(forSongIndex: songIndex)
                    }) {
                        HStack {
                            Text("Save MIDI Cues")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            Spacer()
                            if let msg = midiCuesStatusMessage, msg.hasPrefix("Saved") || msg.hasPrefix("Save ") {
                                Text(msg)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(Color(white: 0.55))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(cardBackground)
                .cornerRadius(10)
            }
            
            // 8. ACTIONS & EXPORT
            if !isPreAddMode {
            VStack(spacing: 0) {
                if let onEditSong {
                    Button(action: {
                        onClose()
                        onEditSong()
                    }) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                                .frame(width: 18)
                            Text("Edit Song")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(white: 0.40))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    rowDivider
                }

                Button(action: {
                    engine.autoDetectTempoFromClick()
                    onClose()
                }) {
                    HStack {
                        Image(systemName: "metronome")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.25, green: 0.75, blue: 1.0))
                            .frame(width: 18)
                        Text("Auto-Detect Tempo from Click")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                rowDivider
                
                Button(action: {
                    engine.autoLabelSectionsFromGuide()
                    onClose()
                }) {
                    HStack {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.25, green: 0.75, blue: 1.0))
                            .frame(width: 18)
                        Text("Auto-Label Sections from Guide")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if libraryManager.hasExistingLibraryCopy(for: targetSong) {
                    rowDivider

                    Button(action: {
                        saveCurrentSongChangesToLibrary()
                    }) {
                        HStack {
                            Image(systemName: savedChangesConfirmation ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(savedChangesConfirmation ? Color.green : Color(red: 1.0, green: 0.72, blue: 0.25))
                                .frame(width: 18)
                            Text(savedChangesConfirmation ? "Changes Saved to Library" : "Save Changes to Library")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(savedChangesConfirmation ? Color.green : .white)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                rowDivider
                
                Button(action: {
                    saveCurrentSongToLocalLibrary()
                }) {
                    HStack {
                        Image(systemName: savedToLocalConfirmation ? "checkmark.circle.fill" : "internaldrive.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(savedToLocalConfirmation ? Color.green : Color(red: 0.35, green: 0.85, blue: 0.55))
                            .frame(width: 18)
                        Text(savedToLocalConfirmation ? "Saved to Local Library" : "Save to Local Library")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(savedToLocalConfirmation ? Color.green : .white)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if libraryManager.isCloudConnected {
                    rowDivider

                    Button(action: {
                        saveCurrentSongToCloudLibrary()
                    }) {
                        HStack {
                            Image(systemName: savedToCloudConfirmation ? "checkmark.circle.fill" : "icloud.and.arrow.up.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(savedToCloudConfirmation ? Color.green : Color(red: 0.35, green: 0.78, blue: 1.0))
                                .frame(width: 18)
                            Text(savedToCloudConfirmation ? "Saved to Cloud Library" : "Save to Cloud Library")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(savedToCloudConfirmation ? Color.green : .white)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                rowDivider
                
                Button(action: {
                    exportCurrentSongPackage()
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.25, green: 0.75, blue: 1.0))
                            .frame(width: 18)
                        Text("Export as .pbsong...")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                rowDivider

                Button(action: {
                    isPracticeBouncePresented = true
                }) {
                    HStack {
                        Image(systemName: "waveform.and.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.35, green: 0.85, blue: 0.55))
                            .frame(width: 18)
                        Text("Export Practice Tracks...")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isPracticeBouncePresented) {
                    OfflineBounceSheetView(
                        engine: engine,
                        initialMode: .practiceTracks,
                        lockMode: true,
                        targetSong: targetSong
                    ) {
                        isPracticeBouncePresented = false
                    }
                }
            }
            .background(cardBackground)
            .cornerRadius(10)
            }
        }
    }
    
    // MARK: - Arrangement Submenu Content (Matching Key Submenu Layout)
    
    private var arrangementSubmenuContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                // 1. Default Arrangement Row (Always first, protected)
                let isDefaultSelected = (pendingArrangementId == nil)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        pendingArrangementId = nil
                    }
                }) {
                    HStack {
                        Text("Default")
                            .font(.system(size: 13, weight: isDefaultSelected ? .bold : .regular))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        if isDefaultSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // 2. User-Created Arrangements
                ForEach(Array(targetSong.savedArrangements.enumerated()), id: \.element.id) { idx, arrangement in
                    rowDivider
                    
                    let isSelected = (pendingArrangementId == arrangement.id)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            pendingArrangementId = arrangement.id
                        }
                    }) {
                        HStack {
                            Text(arrangement.name)
                                .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            if pendingArrangementId == arrangement.id {
                                pendingArrangementId = nil
                            }
                            engine.deleteSavedArrangement(id: arrangement.id, forSongIndex: effectiveSongIndex)
                        } label: {
                            Label("Delete Arrangement", systemImage: "trash")
                        }
                    }
                }
            }
            .background(cardBackground)
            .cornerRadius(10)
        }
    }
    
    // MARK: - Save As New Arrangement Content
    
    private var saveAsNewArrangementContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ARRANGEMENT NAME")
            
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Enter arrangement name...", text: $newArrangementName, onCommit: {
                        commitSaveAsNewArrangement()
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    
                    if !newArrangementName.isEmpty {
                        Button(action: { newArrangementName = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .background(cardBackground)
            .cornerRadius(10)
            
            Text("Creates a new arrangement from your current song sections and cues while keeping Default untouched.")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.48))
                .padding(.horizontal, 6)
                .padding(.top, 2)
        }
    }
    
    // MARK: - Tempo Submenu Content
    
    /// Hundredths-of-a-BPM scroll step matching the song's native tempo precision:
    /// e.g. `74` -> `100` (whole BPMs), `120.5` -> `10` (tenths), `72.25` -> `1` (hundredths).
    private static func tempoWheelStepHundredths(for origBPM: Double) -> Int {
        switch Song.tempoDecimalPrecision(for: origBPM) {
        case 0: return 100
        case 1: return 10
        default: return 1
        }
    }
    
    private func tempoWheelStopsHundredths(for origBPM: Double) -> [Int] {
        let range = Song.allowedTempoRange(forOriginalBPM: origBPM)
        let minH = Int((range.lowerBound * 100.0).rounded(.up))
        let maxH = Int((range.upperBound * 100.0).rounded(.down))
        let origH = Int((Song.clampedShiftedTempo(origBPM, originalBPM: origBPM) * 100.0).rounded())
        let stepH = Self.tempoWheelStepHundredths(for: origBPM)
        guard minH <= maxH else { return [origH] }
        
        var values: [Int] = []
        if stepH == 1 {
            values = Array(minH...maxH)
        } else {
            // Walk outward/inward aligned to `origH` so the original tempo always appears at its natural precision
            let stepsDown = (origH - minH) / stepH
            let first = origH - stepsDown * stepH
            var cur = first
            while cur <= maxH {
                if cur >= minH {
                    values.append(cur)
                }
                cur += stepH
            }
            if !values.contains(origH) {
                values.append(origH)
                values.sort()
            }
        }
        return values
    }
    
    private func nearestTempoWheelStopHundredths(to bpm: Double, in stops: [Int]) -> Int? {
        let targetH = Int((bpm * 100.0).rounded())
        return stops.min(by: { abs($0 - targetH) < abs($1 - targetH) })
    }
    
    private func stepPendingTempo(by delta: Double) {
        let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
        let decimals = Song.tempoDecimalPrecision(for: origBPM)
        let next = Song.clampedShiftedTempo(pendingTempoBPM + delta, originalBPM: origBPM)
        pendingTempoBPM = next
        tempoInputText = Self.formatBPM(next, minDecimals: decimals)
    }
    
    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard currentScreen == .tempoSelection, isHoveringTempoWheel else {
                return event
            }
            let dy = event.scrollingDeltaY
            guard abs(dy) > 0.01 else { return nil }
            let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
            let baseStep = Double(Self.tempoWheelStepHundredths(for: origBPM)) / 100.0
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
            scrollWheelAccumulator += dy
            if abs(scrollWheelAccumulator) >= scale {
                let rawSteps = Int((scrollWheelAccumulator / scale).rounded(.towardZero))
                scrollWheelAccumulator -= CGFloat(rawSteps) * scale
                let multiplier: Double = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
                let direction = rawSteps > 0 ? -1.0 : 1.0
                let steps = min(8, max(1, abs(rawSteps)))
                stepPendingTempo(by: direction * baseStep * multiplier * Double(steps))
            }
            return nil
        }
    }
    
    private func removeScrollWheelMonitor() {
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
        }
        scrollWheelAccumulator = 0.0
        isHoveringTempoWheel = false
    }
    
    private var tempoSubmenuContent: some View {
        let origBPM = targetSong.originalBPM > 0 ? targetSong.originalBPM : targetSong.bpm
        let precision = Song.tempoDecimalPrecision(for: origBPM)
        let range = Song.allowedTempoRange(forOriginalBPM: origBPM)
        let stopsH = tempoWheelStopsHundredths(for: origBPM)
        let ratio = pendingTempoBPM / max(20.0, origBPM)
        let isShifted = abs(pendingTempoBPM - origBPM) > 0.005
        let clampedOrig = Song.clampedShiftedTempo(origBPM, originalBPM: origBPM)
        let origStopH = Int((clampedOrig * 100.0).rounded())
        let selectedStopH = nearestTempoWheelStopHundredths(to: pendingTempoBPM, in: stopsH)
        let nudgeButtons: [(Double, String)] = {
            switch precision {
            case 0: return [(-5.0, "-5"), (-1.0, "-1"), (1.0, "+1"), (5.0, "+5")]
            case 1: return [(-1.0, "-1"), (-0.1, "-0.1"), (0.1, "+0.1"), (1.0, "+1")]
            default: return [(-1.0, "-1"), (-0.01, "-0.01"), (0.01, "+0.01"), (1.0, "+1")]
            }
        }()
        let wheelSubtitle: String = {
            switch precision {
            case 0: return "Whole BPM steps · Scroll or click"
            case 1: return "0.1 BPM steps · ⇧ for 1.0"
            default: return "0.01 BPM steps · ⇧ for 0.1"
            }
        }()
        
        return VStack(spacing: 10) {
            if engine.isTransposing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rendering tempo shift (\(Int(engine.transposeProgress * 100))%)...")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.85, blue: 1.0))
                    Spacer()
                }
                .padding(10)
                .background(Color(white: 0.16))
                .cornerRadius(8)
            }
            
            // Typed BPM Input + Fine Nudge + Reset Card
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        TextField("120", text: $tempoInputText, onCommit: {
                            commitTypedTempoInput()
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(width: 92)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.20))
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isShifted ? Color(red: 0.25, green: 0.85, blue: 1.0).opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                        
                        Text("BPM")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.55))
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(format: "%.2f×", ratio))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(isShifted ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(white: 0.65))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(white: 0.20))
                            .cornerRadius(5)
                        
                        Button(action: {
                            pendingTempoBPM = clampedOrig
                            tempoInputText = Self.formatBPM(clampedOrig, minDecimals: precision)
                        }) {
                            Text("Reset to \(Self.formatBPM(origBPM, minDecimals: precision))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(isShifted ? Color(red: 0.25, green: 0.65, blue: 1.0) : Color(white: 0.40))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isShifted)
                    }
                }
                
                HStack(spacing: 6) {
                    ForEach(nudgeButtons, id: \.1) { delta, label in
                        Button(action: { stepPendingTempo(by: delta) }) {
                            Text(label)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color(white: 0.21))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Text("Range: \(Self.formatBPM(range.lowerBound, minDecimals: precision))–\(Self.formatBPM(range.upperBound, minDecimals: precision)) BPM (±20 BPM within 0.75×–1.5×)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.48))
            }
            .padding(12)
            .background(cardBackground)
            .cornerRadius(10)
            
            // Scroll-Wheel & Clickable Tempo Drum
            VStack(spacing: 4) {
                HStack {
                    Text("SCROLL WHEEL SELECTOR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: 0.50))
                    Spacer()
                    Text(wheelSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.45))
                }
                .padding(.horizontal, 4)
                
                ScrollViewReader { proxy in
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.20, green: 0.48, blue: 0.75).opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(red: 0.25, green: 0.75, blue: 1.0).opacity(0.45), lineWidth: 1)
                            )
                            .frame(height: 32)
                            .allowsHitTesting(false)
                        
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                Color.clear.frame(height: 86)
                                ForEach(stopsH, id: \.self) { stopH in
                                    let val = Double(stopH) / 100.0
                                    let isSelected = (stopH == selectedStopH)
                                    let isOrig = (stopH == origStopH)
                                    let deltaFromOrig = val - clampedOrig
                                    
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            pendingTempoBPM = val
                                            tempoInputText = Self.formatBPM(val, minDecimals: precision)
                                        }
                                    }) {
                                        HStack {
                                            Text(Self.formatBPM(val, minDecimals: precision))
                                                .font(.system(size: isSelected ? 17 : 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                                                .foregroundColor(isSelected ? .white : Color(white: 0.62))
                                            
                                            if isOrig {
                                                Text("Original")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundColor(Color(red: 0.25, green: 0.85, blue: 1.0))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color(red: 0.25, green: 0.85, blue: 1.0).opacity(0.14))
                                                    .cornerRadius(4)
                                            }
                                            
                                            Spacer()
                                            
                                            if !isOrig {
                                                let sign = deltaFromOrig > 0 ? "+" : ""
                                                Text("\(sign)\(Self.formatBPM(deltaFromOrig, minDecimals: precision))")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(isSelected ? Color(red: 0.25, green: 0.85, blue: 1.0) : Color(white: 0.45))
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(height: 30)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(stopH)
                                }
                                Color.clear.frame(height: 86)
                            }
                        }
                    }
                    .frame(height: 210)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.15))
                    .cornerRadius(10)
                    .overlay(
                        VStack {
                            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.15), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 32)
                            Spacer()
                            LinearGradient(colors: [.clear, Color(red: 0.12, green: 0.13, blue: 0.15)], startPoint: .top, endPoint: .bottom)
                                .frame(height: 32)
                        }
                        .allowsHitTesting(false)
                        .cornerRadius(10)
                    )
                    .onHover { hovering in
                        isHoveringTempoWheel = hovering
                    }
                    .onAppear {
                        installScrollWheelMonitor()
                        if let nearestH = nearestTempoWheelStopHundredths(to: pendingTempoBPM, in: stopsH) {
                            DispatchQueue.main.async {
                                proxy.scrollTo(nearestH, anchor: .center)
                            }
                        }
                    }
                    .onDisappear {
                        removeScrollWheelMonitor()
                    }
                    .onChange(of: pendingTempoBPM) { newVal in
                        if let nearestH = nearestTempoWheelStopHundredths(to: newVal, in: stopsH) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(nearestH, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Key Submenu Content (Matching Photo 2)
    
    private var keySubmenuContent: some View {
        VStack(spacing: 8) {
            // Transposing progress indicator if active
            if engine.isTransposing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Pre-rendering stems (\(Int(engine.transposeProgress * 100))%)...")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.85, blue: 1.0))
                    Spacer()
                }
                .padding(10)
                .background(Color(white: 0.16))
                .cornerRadius(8)
            }
            
            // Formant Preservation Toggle (Rubber Band R3)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preserve Vocal Formants")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    Text("Keeps Vocals, BGVs & Choir natural when transposing")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.50))
                }
                Spacer()
                Toggle("", isOn: $pendingPreserveVocalFormants)
                    .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.72, blue: 1.0)))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(cardBackground)
            .cornerRadius(10)

            VStack(spacing: 0) {
                // 12 Chromatic Transposition Rows (-6 to +5), with 0 (Original) in the middle
                let safeBaseKey = (targetSong.musicalKey.isEmpty || targetSong.musicalKey == "—") ? "C" : targetSong.musicalKey
                ForEach(-6...5, id: \.self) { st in
                    let resultingKey = MusicalKeyHelper.transposedKey(originalKey: safeBaseKey, semitones: st)
                    let isOriginal = (st == 0)
                    let isSelected = (pendingTransposeSemitones == st)
                    
                    let keyLabel: String = {
                        if isOriginal {
                            return "\(resultingKey) (Original)"
                        }
                        return resultingKey
                    }()
                    
                    let octaveLabel: String = {
                        if st < -2 {
                            return "Low \(st)"
                        } else if st == -2 {
                            return "Low -2"
                        } else if st == -1 {
                            return "Mid -1"
                        } else if st == 0 {
                            return "Mid"
                        } else if st == 1 {
                            return "Mid +1"
                        } else {
                            return "High +\(st)"
                        }
                    }()
                    
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            pendingTransposeSemitones = st
                        }
                    }) {
                        HStack {
                            Text(keyLabel)
                                .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            HStack(spacing: 6) {
                                Text(octaveLabel)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(Color(white: 0.55))
                                
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if st < 5 {
                        rowDivider
                    }
                }
            }
            .background(cardBackground)
            .cornerRadius(10)
        }
    }
    
    // MARK: - Pad Submenu Content
    
    private var padSubmenuContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                ForEach(Array(padManager.availablePacks.enumerated()), id: \.element.id) { idx, pack in
                    let isSelected = (targetSong.padPresetId ?? padManager.activePackId) == pack.id
                    
                    Button(action: {
                        if isPreAddMode {
                            stagedSong?.padPresetId = pack.id
                        } else {
                            engine.updateSongPadPreset(at: effectiveSongIndex, presetId: pack.id)
                        }
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pack.name)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                    .foregroundColor(.white)
                                Text(pack.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.50))
                            }
                            
                            Spacer()
                            
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if idx < padManager.availablePacks.count - 1 {
                        rowDivider
                    }
                }
            }
            .background(cardBackground)
            .cornerRadius(10)
            
            // Import Pad Sound Pack
            Button(action: {
                padManager.promptUploadPadPack { success in
                    if success {
                        if isPreAddMode {
                            stagedSong?.padPresetId = padManager.activePackId
                        } else {
                            engine.updateSongPadPreset(at: effectiveSongIndex, presetId: padManager.activePackId)
                        }
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                    Text("Import Pad Sound Pack...")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(cardBackground)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Helpers
    
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(white: 0.52))
            .padding(.leading, 6)
    }
    
    private var cardBackground: some View {
        Color(red: 0.16, green: 0.17, blue: 0.19)
    }
    
    private var rowDivider: some View {
        Divider()
            .background(Color(white: 0.23))
            .padding(.leading, 14)
    }
    
    private func saveCurrentSongChangesToLibrary() {
        let idx = songIndex ?? engine.currentSongIndex
        do {
            let updated = try libraryManager.saveSongChangesToExistingLibraries(engine: engine, songIndex: idx)
            if !updated.isEmpty {
                withAnimation { savedChangesConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation { savedChangesConfirmation = false }
                }
            }
        } catch {
            print("Save Changes to Library error: \(error.localizedDescription)")
        }
    }

    private func saveCurrentSongToLocalLibrary() {
        let idx = songIndex ?? engine.currentSongIndex
        do {
            _ = try libraryManager.saveSongToLocalLibrary(engine: engine, songIndex: idx)
            withAnimation { savedToLocalConfirmation = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { savedToLocalConfirmation = false }
            }
        } catch {
            print("Save to Local Library error: \(error.localizedDescription)")
        }
    }

    private func saveCurrentSongToCloudLibrary() {
        let idx = songIndex ?? engine.currentSongIndex
        do {
            _ = try libraryManager.saveSongToCloudLibrary(engine: engine, songIndex: idx)
            withAnimation { savedToCloudConfirmation = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { savedToCloudConfirmation = false }
            }
        } catch {
            print("Save to Cloud Library error: \(error.localizedDescription)")
        }
    }

    private func exportCurrentSongPackage() {
        libraryManager.ensureDefaultDirectoriesExist()
        let panel = NSSavePanel()
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = libraryManager.songsDirectory
        if let songType = UTType(filenameExtension: "pbsong") {
            panel.allowedContentTypes = [songType]
        }
        let songTitle = targetSong.title.isEmpty ? "Untitled Song" : targetSong.title
        panel.nameFieldStringValue = "\(songTitle).pbsong"
        panel.message = "Export Song Package (.pbsong)"
        panel.prompt = "Export"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.exportSongPackage(forSongIndex: songIndex, to: url)
                libraryManager.refreshSongs()
                onClose()
            } catch {
                print("Export error: \(error.localizedDescription)")
            }
        }
    }
}
