import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct PlaybackImportWizardView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    var onDismiss: () -> Void
    
    private enum WizardStep: Int, CaseIterable {
        case selectSetlists = 0
        case audioFolder = 1
        case reviewMatches = 2
        case importing = 3
        
        var title: String {
            switch self {
            case .selectSetlists: return "1. Choose Playlists"
            case .audioFolder: return "2. Audio Folder"
            case .reviewMatches: return "3. Match Songs"
            case .importing: return "4. Import"
            }
        }
    }
    
    @State private var currentStep: WizardStep = .selectSetlists
    @State private var dbURL: URL? = nil
    @State private var songsDirURL: URL? = nil
    @State private var loadError: String? = nil
    @State private var isLoadingDB: Bool = true
    
    // Step 1 state
    @State private var allSetlists: [PlaybackSetlistSummary] = []
    @State private var scope: PlaybackImportScope = .upcoming
    @State private var selectedSinglePK: Int64? = nil
    @State private var selectedMultiplePKs: Set<Int64> = []
    @State private var searchText: String = ""
    
    // Step 2 state
    @State private var selectedAudioRootURL: URL? = nil
    @State private var isDropTargeted: Bool = false
    @State private var isScanningAudio: Bool = false
    
    // Step 3 state
    @State private var uniqueSongs: [PlaybackUniqueSong] = []
    @State private var songMatches: [PlaybackSongMatch] = []
    @State private var expandedSongIds: Set<String> = []
    
    // Step 4 state
    @State private var isImporting: Bool = false
    @State private var importProgress: Double = 0.0
    @State private var importStatusText: String = "Preparing import..."
    @State private var importResult: PlaybackImportResult? = nil
    @State private var importError: String? = nil
    
    private let bgDark = Color(red: 0.11, green: 0.12, blue: 0.13)
    private let cardBg = Color(red: 0.16, green: 0.17, blue: 0.19)
    private let accentBlue = Color(red: 0.28, green: 0.68, blue: 0.98)
    
    public init(engine: MultitrackAudioEngine, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(Color.white.opacity(0.12))
            stepIndicatorBar
            Divider().background(Color.white.opacity(0.08))
            
            Group {
                switch currentStep {
                case .selectSetlists:
                    step1SelectSetlists
                case .audioFolder:
                    step2AudioFolder
                case .reviewMatches:
                    step3ReviewMatches
                case .importing:
                    step4Importing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider().background(Color.white.opacity(0.12))
            footerBar
        }
        .frame(width: 720, height: 560)
        .background(bgDark)
        .onAppear {
            loadPlaybackDatabase()
        }
    }
    
    // MARK: - Header & Step Bar
    
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Playback")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Bring over setlists, arrangements, trimmed sections, MIDI cues, artwork, and stems")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(white: 0.6))
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Color(white: 0.45))
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var stepIndicatorBar: some View {
        HStack(spacing: 12) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                let isActive = step == currentStep
                let isDone = step.rawValue < currentStep.rawValue || (step == .importing && importResult != nil)
                HStack(spacing: 6) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: isDone ? 12 : 7))
                        .foregroundColor(isDone ? .green : (isActive ? accentBlue : Color(white: 0.35)))
                    Text(step.title)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .white : (isDone ? Color(white: 0.8) : Color(white: 0.45)))
                }
                if step != .importing {
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    // MARK: - Step 1: Select Setlists
    
    private var filteredSetlists: [PlaybackSetlistSummary] {
        let base: [PlaybackSetlistSummary]
        switch scope {
        case .upcoming:
            base = allSetlists.filter { $0.isUpcoming }
        case .single, .all:
            base = allSetlists
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.lowercased().contains(q) }
    }
    
    private var chosenSetlists: [PlaybackSetlistSummary] {
        switch scope {
        case .single:
            guard let pk = selectedSinglePK,
                  let found = allSetlists.first(where: { $0.pk == pk }) else { return [] }
            return [found]
        case .upcoming:
            return allSetlists.filter { $0.isUpcoming && selectedMultiplePKs.contains($0.pk) }
        case .all:
            return allSetlists.filter { selectedMultiplePKs.contains($0.pk) }
        }
    }
    
    private var step1SelectSetlists: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingDB {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("Reading Playback library...")
                        .foregroundColor(.white)
                    Spacer()
                }
                Spacer()
            } else if let error = loadError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text("Could Not Access Playback Library")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button("Locate Playback Folder or AppData.storedata...") {
                        pickPlaybackContainerManually()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Picker("Import Scope", selection: $scope) {
                    ForEach(PlaybackImportScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { newScope in
                    syncSelectionForScope(newScope)
                }
                
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Color(white: 0.5))
                        TextField("Search Playback setlists...", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(cardBg)
                    .cornerRadius(6)
                    
                    if scope != .single {
                        Button("Select All") {
                            selectedMultiplePKs = Set(filteredSetlists.map { $0.pk })
                        }
                        .buttonStyle(.bordered)
                        Button("Clear") {
                            selectedMultiplePKs.removeAll()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                if filteredSetlists.isEmpty {
                    Spacer()
                    Text(scope == .upcoming ? "No upcoming playlists found in Playback. Try 'Single Playlist' or 'All Playlists'." : "No matching playlists found.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredSetlists) { item in
                                setlistRow(item)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
    }
    
    private func setlistRow(_ item: PlaybackSetlistSummary) -> some View {
        let isSelected: Bool = {
            switch scope {
            case .single: return selectedSinglePK == item.pk
            case .upcoming, .all: return selectedMultiplePKs.contains(item.pk)
            }
        }()
        
        return Button(action: {
            switch scope {
            case .single:
                selectedSinglePK = item.pk
            case .upcoming, .all:
                if selectedMultiplePKs.contains(item.pk) {
                    selectedMultiplePKs.remove(item.pk)
                } else {
                    selectedMultiplePKs.insert(item.pk)
                }
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: scope == .single
                      ? (isSelected ? "largecircle.fill.circle" : "circle")
                      : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? accentBlue : Color(white: 0.45))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(item.formattedDate)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(white: 0.6))
                }
                
                Spacer()
                
                Text("\(item.songCount) \(item.songCount == 1 ? "song" : "songs")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(white: 0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? accentBlue.opacity(0.14) : cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? accentBlue.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Step 2: Audio Folder
    
    private var step2AudioFolder: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Point to Your Song Audio Folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Select or drop a parent folder containing subfolders for your songs (e.g. Song Name/Drums.wav, Keys.wav). We'll automatically match them to your \(uniqueSongs.count) unique songs.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            
            VStack(spacing: 12) {
                Image(systemName: selectedAudioRootURL != nil ? "folder.fill.badge.checkmark" : "folder.badge.plus")
                    .font(.system(size: 40))
                    .foregroundColor(selectedAudioRootURL != nil ? .green : accentBlue)
                
                if let url = selectedAudioRootURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(url.path)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Drag & drop your stems folder here")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white)
                }
                
                HStack(spacing: 12) {
                    Button(selectedAudioRootURL == nil ? "Choose Audio Folder..." : "Change Folder...") {
                        pickAudioLibraryFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    if selectedAudioRootURL != nil {
                        Button("Clear") {
                            selectedAudioRootURL = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(isDropTargeted ? accentBlue.opacity(0.18) : cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundColor(isDropTargeted ? accentBlue : Color.white.opacity(0.2))
            )
            .cornerRadius(12)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleAudioFolderDrop(providers)
            }
            
            let clickPadCount = uniqueSongs.filter { $0.isClickAndPad }.count
            if clickPadCount > 0 {
                Text("\(clickPadCount) Click & Pad \(clickPadCount == 1 ? "track" : "tracks") detected and will be created natively with Click & Pad.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.green.opacity(0.9))
            }
            
            let embeddedCount = uniqueSongs.filter { !$0.isClickAndPad && $0.embeddedM4ACount > 0 && $0.needsAudioCount == 0 }.count
            if embeddedCount > 0 {
                Text("\(embeddedCount) song(s) already have playable .m4a stems in Playback and will import automatically.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.green.opacity(0.9))
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    // MARK: - Step 3: Review Matches
    
    private var step3ReviewMatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isScanningAudio {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("Scanning audio folders and matching tracks...")
                        .foregroundColor(.white)
                    Spacer()
                }
                Spacer()
            } else {
                HStack {
                    let matchedSongs = songMatches.filter { $0.matchedFolderURL != nil || $0.song.needsAudioCount == 0 }.count
                    Text("\(matchedSongs) of \(songMatches.count) unique songs have audio matched")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("Click a song to inspect individual tracks")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.55))
                }
                
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(songMatches.enumerated()), id: \.element.id) { idx, match in
                            songMatchCard(index: idx, match: match)
                        }
                    }
                }
            }
        }
        .padding(18)
    }
    
    private func songMatchCard(index: Int, match: PlaybackSongMatch) -> some View {
        let isExpanded = expandedSongIds.contains(match.id)
        let song = match.song
        let needsCount = song.needsAudioCount
        let matchedCount = match.matchedUserTrackCount
        let allSatisfied = needsCount == 0 || matchedCount == needsCount
        
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if song.isClickAndPad {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(accentBlue.opacity(0.16))
                        .frame(width: 42, height: 42)
                        .overlay(Image(systemName: "metronome").foregroundColor(accentBlue))
                } else if let artData = song.artworkData, let img = NSImage(data: artData) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 42, height: 42)
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 42, height: 42)
                        .overlay(Image(systemName: "music.note").foregroundColor(Color(white: 0.5)))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if song.isClickAndPad {
                        let decimals = Song.tempoDecimalPrecision(for: song.bpm)
                        let bpmLabel = Song.formatBPM(song.bpm, decimals: decimals)
                        Text("\(bpmLabel) BPM • \(song.timeSignatureNumerator)/\(song.timeSignatureDenominator)" + (song.musicalKey.isEmpty ? " • Click Only" : " • Pad in \(song.musicalKey)"))
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.6))
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            if !song.artist.isEmpty {
                                Text(song.artist)
                            }
                            Text("• \(Int(song.bpm.rounded())) BPM • Key \(song.musicalKey)")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.6))
                        .lineLimit(1)
                    }
                }
                
                Spacer()
                
                if song.isClickAndPad {
                    Text("Click & Pad ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                } else {
                    if needsCount == 0 && song.embeddedM4ACount > 0 {
                        Text("\(song.embeddedM4ACount) .m4a ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(4)
                    } else if let folder = match.matchedFolderURL {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(matchedCount)/\(needsCount) tracks matched")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(allSatisfied ? .green : .orange)
                            Text(folder.lastPathComponent)
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.55))
                                .lineLimit(1)
                        }
                    } else {
                        Text("No audio folder matched")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    
                    Button("Pick Folder...") {
                        pickFolderForSong(at: index)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: {
                        if isExpanded {
                            expandedSongIds.remove(match.id)
                        } else {
                            expandedSongIds.insert(match.id)
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(white: 0.6))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            
            if isExpanded && !song.isClickAndPad {
                Divider().background(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(song.tracks.filter { !$0.isGeneratedClickSubdivision }) { track in
                        HStack {
                            Text(track.title)
                                .font(.system(size: 11.5))
                                .foregroundColor(.white)
                                .frame(width: 170, alignment: .leading)
                                .lineLimit(1)
                            
                            if let localM4A = track.localM4AURL {
                                Text("Playback .m4a (\(localM4A.lastPathComponent))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.green)
                            } else if !match.availableAudioFiles.isEmpty {
                                Picker("", selection: Binding<URL?>(
                                    get: { songMatches[index].trackFileMatches[track.pk] },
                                    set: { newVal in
                                        if let url = newVal {
                                            songMatches[index].trackFileMatches[track.pk] = url
                                        } else {
                                            songMatches[index].trackFileMatches.removeValue(forKey: track.pk)
                                        }
                                    }
                                )) {
                                    Text("— Unlinked —").tag(URL?.none)
                                    ForEach(match.availableAudioFiles, id: \.self) { fileURL in
                                        Text(fileURL.lastPathComponent).tag(URL?.some(fileURL))
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            } else {
                                Text("Unlinked (pick a folder above)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.5))
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.2))
            }
        }
        .background(cardBg)
        .cornerRadius(8)
    }
    
    // MARK: - Step 4: Importing / Done
    
    private var step4Importing: some View {
        VStack(spacing: 16) {
            Spacer()
            if isImporting {
                ProgressView(value: importProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 360)
                Text(importStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.75))
            } else if let err = importError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.red)
                Text("Import Failed")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else if let res = importResult {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
                Text("Import Complete")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Imported \(res.setlistCount) \(res.setlistCount == 1 ? "setlist" : "setlists") (\(res.songCount) songs, \(res.linkedAudioFilesCount) audio tracks linked) into your Local Setlists.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(white: 0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                
                if let firstURL = res.importedSessionURLs.first {
                    Button("Open First Imported Setlist") {
                        try? engine.loadSession(from: firstURL)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(20)
    }
    
    // MARK: - Footer Navigation
    
    private var footerBar: some View {
        HStack {
            if currentStep == .audioFolder || currentStep == .reviewMatches {
                Button("Back") {
                    if currentStep == .reviewMatches {
                        currentStep = .audioFolder
                    } else if currentStep == .audioFolder {
                        currentStep = .selectSetlists
                    }
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
            
            switch currentStep {
            case .selectSetlists:
                let count = chosenSetlists.count
                Button("Next (\(count) selected)") {
                    advanceFromStep1()
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || isLoadingDB)
                
            case .audioFolder:
                let songsNeedingStems = uniqueSongs.filter { !$0.isClickAndPad && $0.needsAudioCount > 0 }.count
                if !uniqueSongs.isEmpty && songsNeedingStems == 0 && selectedAudioRootURL == nil {
                    Button("Continue") {
                        advanceFromStep2()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip Audio for Now") {
                        selectedAudioRootURL = nil
                        advanceFromStep2()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Match Songs") {
                        advanceFromStep2()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAudioRootURL == nil)
                }
                
            case .reviewMatches:
                Button("Import \(chosenSetlists.count) \(chosenSetlists.count == 1 ? "Playlist" : "Playlists")") {
                    startImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanningAudio)
                
            case .importing:
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - Actions
    
    private func loadPlaybackDatabase(customURL: URL? = nil) {
        isLoadingDB = true
        loadError = nil
        
        Task.detached(priority: .userInitiated) {
            guard let resolved = PlaybackImporter.shared.resolveDefaultDatabase(customContainerOrDB: customURL) else {
                await MainActor.run {
                    self.isLoadingDB = false
                    self.loadError = "Playback's local database was not readable at ~/Library/Containers/com.multitracks.custommixplayer/. Click below to grant access to that folder or pick AppData.storedata."
                }
                return
            }
            
            do {
                let setlists = try PlaybackImporter.shared.fetchSetlists(dbURL: resolved.dbURL)
                await MainActor.run {
                    self.dbURL = resolved.dbURL
                    self.songsDirURL = resolved.songsURL
                    self.allSetlists = setlists
                    self.syncSelectionForScope(self.scope)
                    self.isLoadingDB = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingDB = false
                    self.loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func syncSelectionForScope(_ newScope: PlaybackImportScope) {
        switch newScope {
        case .single:
            if selectedSinglePK == nil {
                selectedSinglePK = allSetlists.first?.pk
            }
        case .upcoming:
            selectedMultiplePKs = Set(allSetlists.filter { $0.isUpcoming }.map { $0.pk })
        case .all:
            selectedMultiplePKs = Set(allSetlists.map { $0.pk })
        }
    }
    
    private func pickPlaybackContainerManually() {
        let panel = NSOpenPanel()
        panel.title = "Select Playback Data Folder or AppData.storedata"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = PlaybackImporter.defaultContainerURL
        if panel.runModal() == .OK, let url = panel.url {
            loadPlaybackDatabase(customURL: url)
        }
    }
    
    private func advanceFromStep1() {
        guard let dbURL = dbURL, let songsDirURL = songsDirURL else { return }
        let pks = chosenSetlists.map { $0.pk }
        currentStep = .audioFolder
        
        Task.detached(priority: .userInitiated) {
            let unique = (try? PlaybackImporter.shared.fetchUniqueSongs(dbURL: dbURL, songsDirURL: songsDirURL, forSetlistPKs: pks)) ?? []
            await MainActor.run {
                self.uniqueSongs = unique
            }
        }
    }
    
    private func pickAudioLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder Containing Song Audio Subfolders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedAudioRootURL = url
        }
    }
    
    private func handleAudioFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                DispatchQueue.main.async {
                    self.selectedAudioRootURL = url
                }
            }
        }
        return true
    }
    
    private func advanceFromStep2() {
        currentStep = .reviewMatches
        isScanningAudio = true
        let songsSnapshot = uniqueSongs
        let rootURL = selectedAudioRootURL
        
        Task.detached(priority: .userInitiated) {
            let matches: [PlaybackSongMatch]
            if let root = rootURL {
                matches = PlaybackImporter.shared.scanAudioLibrary(rootURL: root, for: songsSnapshot)
            } else {
                matches = songsSnapshot.map { PlaybackImporter.shared.buildMatchState(for: $0, folderURL: nil) }
            }
            await MainActor.run {
                self.songMatches = matches
                self.isScanningAudio = false
            }
        }
    }
    
    private func pickFolderForSong(at index: Int) {
        let song = songMatches[index].song
        let panel = NSOpenPanel()
        panel.title = "Select Audio Stems Folder for \"\(song.title)\""
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedAudioRootURL
        if panel.runModal() == .OK, let url = panel.url {
            songMatches[index] = PlaybackImporter.shared.buildMatchState(for: song, folderURL: url)
            expandedSongIds.insert(song.id)
        }
    }
    
    private func startImport() {
        guard let dbURL = dbURL, let songsDirURL = songsDirURL else { return }
        currentStep = .importing
        isImporting = true
        importProgress = 0.0
        importError = nil
        importResult = nil
        
        let setlistsToImport = chosenSetlists
        let matchMap = Dictionary(uniqueKeysWithValues: songMatches.map { ($0.song.id, $0) })
        
        Task.detached(priority: .userInitiated) {
            do {
                let res = try PlaybackImporter.shared.performImport(
                    dbURL: dbURL,
                    songsDirURL: songsDirURL,
                    selectedSetlists: setlistsToImport,
                    matchByContentKey: matchMap
                ) { prog, status in
                    DispatchQueue.main.async {
                        self.importProgress = prog
                        self.importStatusText = status
                    }
                }
                await MainActor.run {
                    LibraryBrowserManager.shared.refreshSetlists()
                    self.importResult = res
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.importError = error.localizedDescription
                    self.isImporting = false
                }
            }
        }
    }
}
