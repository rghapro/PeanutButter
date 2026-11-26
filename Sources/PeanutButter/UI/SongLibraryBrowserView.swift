import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Slide-over Song Library Browser shown when tapping "+ Add a Song" (5.2).
/// Scans `~/Music/PeanutButter/Songs/` for `.pbsong` packages, supports real-time search,
/// displays BPM & Key, and allows one-tap insertion into the active setlist.
public struct SongLibraryBrowserView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var library = LibraryBrowserManager.shared

    let onImportFromFinder: () -> Void
    let onImportFromFolder: () -> Void
    let onBuildNewSong: () -> Void
    let onDismiss: () -> Void
    let onBack: (() -> Void)?

    @State private var searchText: String = ""
    @State private var sourceFilter: LibrarySourceFilter = .all
    @State private var sortByArtist: Bool = false
    @State private var hoveredSongId: URL? = nil
    @State private var statusError: String? = nil
    @State private var statusSuccess: String? = nil
    @State private var selectedLibraryItem: SongLibraryItem? = nil
    @State private var stagedSong: Song? = nil
    @State private var songPendingDelete: SongLibraryItem? = nil

    public init(
        engine: MultitrackAudioEngine,
        onImportFromFinder: @escaping () -> Void,
        onImportFromFolder: @escaping () -> Void = {},
        onBuildNewSong: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onBack: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.onImportFromFinder = onImportFromFinder
        self.onImportFromFolder = onImportFromFolder
        self.onBuildNewSong = onBuildNewSong
        self.onDismiss = onDismiss
        self.onBack = onBack
    }

    private var filteredSongs: [SongLibraryItem] {
        let bySource: [SongLibraryItem]
        switch sourceFilter {
        case .all:
            bySource = library.songs
        case .local:
            bySource = library.songs.filter { $0.source == .local }
        case .cloud:
            bySource = library.songs.filter { $0.source == .cloud }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched: [SongLibraryItem]
        if q.isEmpty {
            searched = bySource
        } else {
            searched = bySource.filter {
                $0.title.lowercased().contains(q)
                    || $0.artist.lowercased().contains(q)
            }
        }
        if sortByArtist {
            return searched.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } else {
            return searched.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    public var body: some View {
        Group {
            if let item = selectedLibraryItem, let staged = stagedSong {
                SongMenuPopoverView(
                    engine: engine,
                    stagedSong: staged,
                    onClose: onDismiss,
                    onBackToLibrary: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedLibraryItem = nil
                            stagedSong = nil
                        }
                    },
                    onConfirmAddToSetlist: { configuredSong in
                        do {
                            try engine.importSongPackage(from: item.url, configuredWith: configuredSong)
                            onDismiss()
                        } catch {
                            selectedLibraryItem = nil
                            stagedSong = nil
                            statusError = "Failed to add song: \(error.localizedDescription)"
                        }
                    }
                )
            } else {
                libraryListBody
            }
        }
    }

    private var libraryListBody: some View {
        VStack(spacing: 0) {
            // Header
            ZStack {
                Text("Songs")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                HStack {
                    if let onBack = onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                        }
                        .buttonStyle(.plain)
                        .help("Back to Add a Song")
                    } else {
                        addActionsMenu
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        if onBack != nil {
                            addActionsMenu
                        }

                        Button(action: { library.refreshSongs() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Color(white: 0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Local & Cloud Song Libraries")

                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13.5))
                                .foregroundColor(Color(white: 0.48))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            // Search ("Filter")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(white: 0.48))
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.48))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.16))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Segmented Source Filter Tabs (All | Local | Cloud)
            HStack(spacing: 2) {
                ForEach(LibrarySourceFilter.allCases, id: \.self) { filter in
                    let isSelected = sourceFilter == filter
                    Button(action: { sourceFilter = filter }) {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .white : Color(white: 0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4.5)
                            .background(isSelected ? Color(white: 0.36) : Color.clear)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color(white: 0.16))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Sort Row
            Button(action: { sortByArtist.toggle() }) {
                Text(sortByArtist ? "Sort by Artist" : "Sort by Title")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            if let err = statusError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.38))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else if let msg = statusSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(msg)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.40, green: 0.92, blue: 0.58))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Library List
            if library.isScanningSongs {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Scanning Local & Cloud Song Libraries...")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.55))
                    .padding(.top, 6)
                Spacer()
            } else if filteredSongs.isEmpty {
                Spacer()
                if sourceFilter == .cloud && !library.isCloudConnected {
                    VStack(spacing: 8) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 26))
                            .foregroundColor(Color(white: 0.45))
                        Text("Cloud Library Not Connected")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.85))
                        Text("Open Settings (gear icon) and select an iCloud Drive, Dropbox, Google Drive, or OneDrive folder.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 26))
                            .foregroundColor(Color(white: 0.45))
                        Text(library.songs.isEmpty ? "No Songs in Library" : "No Matching Songs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.85))
                        Text(sourceFilter == .cloud ? (library.cloudSongsDirectory?.path ?? "Cloud/Songs") : "~/Music/PeanutButter/Songs")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 16)
                        Text("Exported .pbsong packages placed here appear automatically.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSongs) { item in
                            HStack(spacing: 0) {
                                Button(action: {
                                    do {
                                        let metaSong = try PlaybackFileManager.shared.loadSongMetadataOnly(from: item.url)
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            selectedLibraryItem = item
                                            stagedSong = metaSong
                                        }
                                    } catch {
                                        statusError = "Failed to load song details: \(error.localizedDescription)"
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        if let art = item.artwork {
                                            Image(nsImage: art)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 34, height: 34)
                                                .clipped()
                                                .cornerRadius(3)
                                        } else {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color(white: 0.20))
                                                    .frame(width: 34, height: 34)
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color(white: 0.55))
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)

                                            if !item.artist.isEmpty {
                                                Text(item.artist)
                                                    .font(.system(size: 10.5))
                                                    .foregroundColor(Color(white: 0.58))
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        if item.source == .cloud && !item.isDownloaded {
                                            Image(systemName: "icloud.and.arrow.down")
                                                .font(.system(size: 10))
                                                .foregroundColor(.orange)
                                                .help("In Cloud — will download automatically when added")
                                        }

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Color(white: 0.42))
                                    }
                                    .padding(.leading, 12)
                                    .padding(.trailing, hoveredSongId == item.id ? 6 : 12)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if hoveredSongId == item.id {
                                    Button(action: {
                                        songPendingDelete = item
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 8)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete from \(item.source == .cloud ? "Cloud" : "Local") Library")
                                }
                            }
                            .background(hoveredSongId == item.id ? Color.white.opacity(0.08) : Color.clear)
                            .onHover { hovering in
                                hoveredSongId = hovering ? item.id : (hoveredSongId == item.id ? nil : hoveredSongId)
                            }
                            .contextMenu {
                                if item.source == .local, let cloudSongsDir = library.cloudSongsDirectory {
                                    Button("Copy to Cloud Library") {
                                        let fileName = LibraryBrowserManager.sanitizedPackageFilename(item.title, ext: "pbsong")
                                        let src = item.url
                                        let dest = cloudSongsDir.appendingPathComponent(fileName)
                                        Task.detached(priority: .userInitiated) {
                                            do {
                                                try PlaybackFileManager.shared.copyLibraryPackage(from: src, to: dest, isSong: true)
                                                await MainActor.run {
                                                    library.refreshSongs()
                                                    statusSuccess = "Copied to Cloud Library"
                                                }
                                            } catch {
                                                await MainActor.run {
                                                    statusError = "Copy to Cloud failed: \(error.localizedDescription)"
                                                }
                                            }
                                        }
                                    }
                                } else if item.source == .cloud {
                                    Button("Copy to Local Library") {
                                        let fileName = LibraryBrowserManager.sanitizedPackageFilename(item.title, ext: "pbsong")
                                        let src = item.url
                                        let dest = library.songsDirectory.appendingPathComponent(fileName)
                                        Task.detached(priority: .userInitiated) {
                                            do {
                                                try PlaybackFileManager.shared.copyLibraryPackage(from: src, to: dest, isSong: true)
                                                await MainActor.run {
                                                    library.refreshSongs()
                                                    statusSuccess = "Copied to Local Library"
                                                }
                                            } catch {
                                                await MainActor.run {
                                                    statusError = "Copy to Local failed: \(error.localizedDescription)"
                                                }
                                            }
                                        }
                                    }
                                }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                Divider()
                                Button("Delete from Library", role: .destructive) {
                                    songPendingDelete = item
                                }
                            }

                            Divider()
                                .background(Color.white.opacity(0.07))
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .frame(width: 330, height: 470)
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
        .onAppear {
            library.refreshSongs()
        }
        .alert(
            "Delete Song from Library?",
            isPresented: Binding(
                get: { songPendingDelete != nil },
                set: { if !$0 { songPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                songPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let item = songPendingDelete {
                    songPendingDelete = nil
                    do {
                        try library.deleteSong(item)
                        statusError = nil
                        statusSuccess = "Deleted \"\(item.title)\" from \(item.source == .cloud ? "Cloud" : "Local") Library"
                    } catch {
                        statusError = "Failed to delete song: \(error.localizedDescription)"
                    }
                }
            }
        } message: {
            if let item = songPendingDelete {
                Text("This will permanently delete \"\(item.title)\" from your \(item.source == .cloud ? "Cloud" : "Local") Song Library.")
            }
        }
    }

    private var addActionsMenu: some View {
        Menu {
            Button(action: {
                onDismiss()
                onBuildNewSong()
            }) {
                Label("Build from Stems", systemImage: "waveform.badge.plus")
            }

            Button(action: {
                onDismiss()
                onImportFromFolder()
            }) {
                Label("Import Song From Folder...", systemImage: "folder.badge.plus")
            }

            Button(action: {
                onDismiss()
                onImportFromFinder()
            }) {
                Label("Import .pbsong to Setlist...", systemImage: "folder")
            }

            Divider()

            Button(action: {
                importSongPackagesIntoLibrary(toCloud: false)
            }) {
                Label("Add .pbsong to Local Library...", systemImage: "internaldrive")
            }

            if library.isCloudConnected {
                Button(action: {
                    importSongPackagesIntoLibrary(toCloud: true)
                }) {
                    Label("Add .pbsong to Cloud Library...", systemImage: "icloud.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Build or Import Songs")
    }

    private func importSongPackagesIntoLibrary(toCloud: Bool) {
        statusError = nil
        statusSuccess = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        var allowed: [UTType] = [.data, .package]
        if let songType = UTType(filenameExtension: "pbsong") {
            allowed.insert(songType, at: 0)
        }
        if let multiType = UTType(filenameExtension: "multitrack") {
            allowed.insert(multiType, at: 1)
        }
        panel.allowedContentTypes = allowed
        panel.message = toCloud
            ? "Choose Song Package(s) (.pbsong) to Add to Cloud Library"
            : "Choose Song Package(s) (.pbsong) to Add to Local Library"
        panel.prompt = toCloud ? "Add to Cloud Library" : "Add to Local Library"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            do {
                let count = try library.importSongPackagesToLibrary(from: panel.urls, toCloud: toCloud)
                if count > 0 {
                    sourceFilter = toCloud ? .cloud : .local
                    statusSuccess = "Added \(count) song\(count == 1 ? "" : "s") to \(toCloud ? "Cloud" : "Local") Library"
                } else {
                    statusError = "No valid .pbsong packages selected."
                }
            } catch {
                statusError = "Failed to add to library: \(error.localizedDescription)"
            }
        }
    }
}
