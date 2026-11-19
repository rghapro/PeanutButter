import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum SetlistNavScreen {
    case main
    case newSetlist
    case setlistDetail
    case setlistsBrowser
    case librarySetlistDetail
    case exportReference
}

public struct SetlistMenuPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    var onDismiss: () -> Void
    
    @ObservedObject private var library = LibraryBrowserManager.shared
    @State private var currentScreen: SetlistNavScreen = .main
    @State private var setlistSearchText: String = ""
    @State private var setlistSourceFilter: LibrarySourceFilter = .all
    
    // New Setlist form state (Photo 1)
    @State private var newSetlistName: String = ""
    @State private var newSetlistDate: Date = Date()
    @State private var newSetlistServiceType: String = ""
    @State private var newSetlistTime: Date = {
        var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comp.hour = 9
        comp.minute = 0
        return Calendar.current.date(from: comp) ?? Date()
    }()
    
    // Dialog & alert state
    @State private var showingRenameAlert: Bool = false
    @State private var setlistRenameText: String = ""
    @State private var showingDeleteConfirmation: Bool = false
    @State private var showingDeleteSetlistAlert: Bool = false
    @State private var selectedLibrarySetlist: SetlistLibraryItem? = nil
    @State private var selectedSetlistSongs: [SetlistSongPreview] = []
    @State private var isLoadingSetlistSongs: Bool = false
    @State private var showingDeleteSelectedSetlistAlert: Bool = false
    private enum PendingSaveTarget {
        case quick
        case cloudLibrary
    }

    @State private var statusMessage: String? = nil
    @State private var isReferenceBouncePresented: Bool = false
    @State private var showSaveNotesAlert: Bool = false
    @State private var saveNotesText: String = ""
    @State private var pendingSaveTarget: PendingSaveTarget? = nil
    @State private var pendingCloudUpdateItem: SetlistLibraryItem? = nil
    @State private var showCloudUpdateConfirmAlert: Bool = false
    
    public init(engine: MultitrackAudioEngine, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        Group {
            switch currentScreen {
            case .main:
                mainSetlistsView
            case .newSetlist:
                newSetlistView
            case .setlistDetail:
                setlistDetailView
            case .setlistsBrowser:
                setlistsBrowserView
            case .librarySetlistDetail:
                librarySetlistDetailView
            case .exportReference:
                OfflineBounceSheetView(
                    engine: engine,
                    initialMode: .sessionReference,
                    lockMode: true,
                    embeddedInPopover: true
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        currentScreen = .main
                    }
                }
            }
        }
        .frame(width: 325, height: 460)
        .background(Color(red: 0.12, green: 0.13, blue: 0.14))
        .onAppear {
            library.refreshSetlists()
        }
        .alert("Save Setlist", isPresented: $showSaveNotesAlert) {
            TextField("Describe your changes (optional)", text: $saveNotesText)
            Button("Cancel", role: .cancel) {
                pendingSaveTarget = nil
            }
            Button("Save") {
                let notes = saveNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = notes.isEmpty ? nil : notes
                let target = pendingSaveTarget
                pendingSaveTarget = nil
                switch target {
                case .quick:
                    saveSessionQuick(changeDescription: desc)
                case .cloudLibrary:
                    saveSessionToLibrary(cloud: true, changeDescription: desc)
                case .none:
                    break
                }
            }
        } message: {
            Text("Add a short note describing your changes so other users know what was updated.")
        }
        .alert("Cloud Update Available", isPresented: $showCloudUpdateConfirmAlert, presenting: pendingCloudUpdateItem) { item in
            Button("Cancel", role: .cancel) {
                pendingCloudUpdateItem = nil
            }
            Button("Download Update") {
                pendingCloudUpdateItem = nil
                try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
                do {
                    try engine.loadSession(from: item.url)
                    library.refreshSetlists()
                    onDismiss()
                } catch {
                    statusMessage = "Update error: \(error.localizedDescription)"
                }
            }
        } message: { item in
            if let desc = item.changeDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                Text("Changes:\n\(desc)\n\nWould you like to download and load this update?")
            } else {
                Text("A newer version of \"\(item.name)\" is available in the cloud. Would you like to download and load this update?")
            }
        }
    }
    
    // MARK: - 1. Main Setlists View
    
    private var mainSetlistsView: some View {
        VStack(spacing: 0) {
            // Header: Cancel (left), Setlists (center)
            HStack {
                Button(action: {
                    onDismiss()
                }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Setlists")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("Cancel")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.clear)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Top Actions Group
                    VStack(spacing: 0) {
                        // New Setlist (Navigates to Photo 1 screen)
                        menuRow(title: "New Setlist", showChevron: true) {
                            newSetlistName = ""
                            newSetlistDate = Date()
                            newSetlistServiceType = ""
                            withAnimation(.easeInOut(duration: 0.18)) {
                                currentScreen = .newSetlist
                            }
                        }
                        
                        rowDivider
                        
                        // Open Setlist (Slide-over Browser)
                        Button(action: {
                            setlistSearchText = ""
                            library.refreshSetlists()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                currentScreen = .setlistsBrowser
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("Open Setlist")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundColor(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        rowDivider
                        
                        // Import from MultiTracks Playback
                        menuRow(title: "Import from Playback...", showChevron: true) {
                            onDismiss()
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: NSNotification.Name("PlaybackOpenImportWizard"), object: nil)
                            }
                        }
                    }
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    
                    // CURRENT SETLIST Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CURRENT SETLIST")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(white: 0.52))
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        
                        // Current Setlist Card (Navigates to Photo 2 submenu)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                currentScreen = .setlistDetail
                            }
                        }) {
                            HStack(spacing: 12) {
                                // Thumbnail (2x2 grid or fallback icon)
                                setlistThumbnail
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.currentSetlist.name.isEmpty ? "Untitled Setlist" : engine.currentSetlist.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    
                                    // User entered date and time!
                                    Text(engine.currentSetlist.formattedUserDateTime)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(Color(white: 0.6))
                                        .lineLimit(1)
                                    
                                    Text("\(engine.currentSetlist.songs.count) Songs • \(engine.currentSetlist.formattedDuration)")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(Color(white: 0.6))
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.19, green: 0.20, blue: 0.22))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Actions below Card
                    VStack(spacing: 0) {
                        if let cloudUpdateItem = currentSetlistCloudUpdateItem {
                            Button(action: {
                                pendingCloudUpdateItem = cloudUpdateItem
                                showCloudUpdateConfirmAlert = true
                            }) {
                                HStack {
                                    Text("Update Available")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))
                                    Spacer()
                                    Image(systemName: "icloud.and.arrow.down")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            rowDivider
                        }

                        // Restore From Previous Save
                        menuRow(
                            title: "Restore From Previous Save",
                            showChevron: false,
                            isEnabled: true
                        ) {
                            restoreFromPreviousSave()
                        }
                        
                        rowDivider
                        
                        // Save
                        menuRow(title: "Save", showChevron: false) {
                            saveNotesText = ""
                            pendingSaveTarget = .quick
                            showSaveNotesAlert = true
                        }
                        
                        rowDivider
                        
                        // Save As New
                        menuRow(title: "Save As New", showChevron: true) {
                            saveSessionAsNew()
                        }

                        if library.isCloudConnected {
                            rowDivider

                            menuRow(title: "Save to Cloud Setlists", showChevron: false) {
                                saveNotesText = ""
                                pendingSaveTarget = .cloudLibrary
                                showSaveNotesAlert = true
                            }
                        }

                        rowDivider

                        menuRow(title: "Save to Local Setlists", showChevron: false) {
                            saveSessionToLibrary(cloud: false)
                        }

                        rowDivider

                        // Export Session Reference Track (5.3A)
                        menuRow(title: "Export Reference Track...", showChevron: true) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                currentScreen = .exportReference
                            }
                        }
                    }
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    .padding(.top, 4)
                    
                    // Destructive Section
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Text("Delete All Setlists From Device")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(Color(red: 0.95, green: 0.25, blue: 0.25))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        Text("Deleting Setlists only removes them from this device, your Setlists will still be available in saved files.")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.48))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    .padding(.top, 14)
                    
                    if let status = statusMessage {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .alert("Delete All Setlists From Device?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                library.deleteAllCloudSetlistsFromDevice()
                engine.newSession(name: "New Setlist")
                onDismiss()
            }
        } message: {
            Text("Local setlist changes not saved to Cloud will be lost, and all downloaded content will be deleted.")
        }
    }
    
    // MARK: - 2. New Setlist View (Matching Photo 1)
    
    private var newSetlistView: some View {
        VStack(spacing: 0) {
            // Header: < Back (left), New Setlist (center), Create (right)
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        currentScreen = .main
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("New Setlist")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                let isCreateEnabled = !newSetlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: {
                    createNewSetlistAction()
                }) {
                    Text("Create")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isCreateEnabled ? Color(red: 0.28, green: 0.68, blue: 0.98) : Color(white: 0.40))
                }
                .buttonStyle(.plain)
                .disabled(!isCreateEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Form fields card
                    VStack(spacing: 0) {
                        // 1. Name Row
                        HStack {
                            Text("Name")
                                .font(.system(size: 13.5))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            TextField("Setlist Name", text: $newSetlistName)
                                .font(.system(size: 13.5))
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .frame(maxWidth: 180)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        
                        rowDivider
                        
                        // 2. Date Row
                        HStack {
                            Text("Date")
                                .font(.system(size: 13.5))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            DatePicker(
                                "",
                                selection: $newSetlistDate,
                                displayedComponents: [.date]
                            )
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .colorScheme(.dark)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    
                    // Service Type & Service Times Group
                    VStack(spacing: 0) {
                        // 3. Service Type Row
                        HStack {
                            Text("Service Type")
                                .font(.system(size: 13.5))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            TextField("None", text: $newSetlistServiceType)
                                .font(.system(size: 13.5))
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .foregroundColor(newSetlistServiceType.isEmpty ? Color(white: 0.5) : Color(red: 0.28, green: 0.68, blue: 0.98))
                                .frame(maxWidth: 150)
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: 0.40))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        
                        rowDivider
                        
                        // 4. Service Times Row (12-hour AM/PM clock)
                        HStack {
                            Text("Service Times")
                                .font(.system(size: 13.5))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            DatePicker(
                                "",
                                selection: $newSetlistTime,
                                displayedComponents: [.hourAndMinute]
                            )
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .colorScheme(.dark)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    .padding(.top, 16)
                }
            }
        }
    }
    
    private func createNewSetlistAction() {
        let name = newSetlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        
        // Merge date and 12-hour time into scheduled Date
        let calendar = Calendar.current
        let timeComps = calendar.dateComponents([.hour, .minute], from: newSetlistTime)
        var dateComps = calendar.dateComponents([.year, .month, .day], from: newSetlistDate)
        dateComps.hour = timeComps.hour
        dateComps.minute = timeComps.minute
        let mergedDate = calendar.date(from: dateComps) ?? newSetlistDate
        
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let timeString = tf.string(from: newSetlistTime)
        
        engine.newSession(
            name: name,
            date: mergedDate,
            serviceType: newSetlistServiceType.isEmpty ? nil : newSetlistServiceType,
            serviceTime: timeString
        )
        onDismiss()
    }
    
    // MARK: - 3. Current Setlist Detail View (Matching Photo 2)
    
    private var setlistDetailView: some View {
        VStack(spacing: 0) {
            // Header: < Back (left), Setlist (center)
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        currentScreen = .main
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Setlist")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Balancer
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.clear)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Top Card: Artwork + Setlist Name + User Date/Time + Songs Count
                    HStack(spacing: 12) {
                        setlistThumbnail
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.currentSetlist.name.isEmpty ? "Untitled Setlist" : engine.currentSetlist.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            Text(engine.currentSetlist.formattedUserDateTime)
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(white: 0.6))
                                .lineLimit(1)
                            
                            Text("\(engine.currentSetlist.songs.count) Songs • \(engine.currentSetlist.formattedDuration)")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(white: 0.6))
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            setlistRenameText = engine.currentSetlist.name
                            showingRenameAlert = true
                        }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.50))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    
                    // SONGS Section Header
                    Text("SONGS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: 0.52))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    
                    // Song List
                    if engine.currentSetlist.songs.isEmpty {
                        HStack {
                            Spacer()
                            Text("No songs in setlist")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.45))
                                .padding(.vertical, 20)
                            Spacer()
                        }
                        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(engine.currentSetlist.songs.enumerated()), id: \.element.id) { index, song in
                                HStack(spacing: 12) {
                                    // Song thumbnail
                                    if let img = song.albumArtwork {
                                        Image(nsImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 36, height: 36)
                                            .clipped()
                                            .cornerRadius(3)
                                    } else {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(coverGradient(for: index))
                                            .frame(width: 36, height: 36)
                                            .overlay(
                                                Text(song.title.prefix(2).uppercased())
                                                    .font(.system(size: 11, weight: .black))
                                                    .foregroundColor(.white.opacity(0.85))
                                            )
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        Text("Default Arrangement")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(white: 0.55))
                                            .lineLimit(1)
                                        
                                        Text("\(song.formattedDuration) • \(song.effectiveKey) • \(Int(song.bpm)) BPM")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(white: 0.55))
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.35))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                
                                if index < engine.currentSetlist.songs.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    }
                    
                    // Bottom Destructive: Delete Setlist (Photo 2)
                    VStack(spacing: 0) {
                        Button(action: {
                            showingDeleteSetlistAlert = true
                        }) {
                            HStack {
                                Text("Delete Setlist")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(Color(red: 0.95, green: 0.25, blue: 0.25))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .alert("Rename Setlist", isPresented: $showingRenameAlert) {
            TextField("Setlist Name", text: $setlistRenameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if !setlistRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    engine.currentSetlist.name = setlistRenameText
                }
            }
        }
        .alert("Delete Setlist?", isPresented: $showingDeleteSetlistAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                engine.newSession(name: "New Setlist")
                withAnimation(.easeInOut(duration: 0.18)) {
                    currentScreen = .main
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(engine.currentSetlist.name)'? This action cannot be undone.")
        }
    }
    
    // MARK: - Row Builder
    
    private func menuRow(
        title: String,
        showChevron: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundColor(isEnabled ? .white : Color(white: 0.45))
                
                Spacer()
                
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var rowDivider: some View {
        Divider()
            .background(Color.white.opacity(0.08))
            .padding(.leading, 16)
    }
    
    // MARK: - Thumbnail Builder
    
    private var setlistThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.10))
                .frame(width: 44, height: 44)
            
            let songs = engine.currentSetlist.songs
            if songs.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.system(size: 18))
                    .foregroundColor(Color(white: 0.5))
            } else if songs.count == 1 {
                if let art = songs[0].albumArtwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipped()
                        .cornerRadius(3)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(coverGradient(for: 0))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Text(songs[0].title.prefix(2).uppercased())
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                        )
                }
            } else {
                // 2x2 collage
                VStack(spacing: 1.5) {
                    HStack(spacing: 1.5) {
                        miniCell(index: 0, song: songs.indices.contains(0) ? songs[0] : nil)
                        miniCell(index: 1, song: songs.indices.contains(1) ? songs[1] : nil)
                    }
                    HStack(spacing: 1.5) {
                        miniCell(index: 2, song: songs.indices.contains(2) ? songs[2] : nil)
                        miniCell(index: 3, song: songs.indices.contains(3) ? songs[3] : nil)
                    }
                }
                .frame(width: 44, height: 44)
                .cornerRadius(3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func miniCell(index: Int, song: Song?) -> some View {
        if let s = song {
            if let art = s.albumArtwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 21, height: 21)
                    .clipped()
            } else {
                Rectangle()
                    .fill(coverGradient(for: index))
                    .frame(width: 21, height: 21)
                    .overlay(
                        Text(s.title.prefix(1).uppercased())
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white.opacity(0.8))
                    )
            }
        } else {
            Rectangle()
                .fill(Color(red: 0.14, green: 0.15, blue: 0.18))
                .frame(width: 21, height: 21)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 8))
                        .foregroundColor(Color(white: 0.35))
                )
        }
    }
    
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
                colors: [Color(red: 0.25, green: 0.20, blue: 0.45), Color(red: 0.10, green: 0.08, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.15, green: 0.35, blue: 0.25), Color(red: 0.06, green: 0.15, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    // MARK: - 4. Saved Setlists Browser (~/Music/PeanutButter/Setlists/)

    private var filteredLibrarySetlists: [SetlistLibraryItem] {
        let bySource: [SetlistLibraryItem]
        switch setlistSourceFilter {
        case .all:
            bySource = library.setlists
        case .local:
            bySource = library.setlists.filter { $0.source == .local }
        case .cloud:
            bySource = library.setlists.filter { $0.source == .cloud }
        }
        let q = setlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return bySource }
        return bySource.filter { $0.name.lowercased().contains(q) }
    }

    private var setlistsBrowserView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        currentScreen = .main
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Setlists")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Open Setlist")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Button("Browse...") {
                    openSessionDialog()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.12))

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                TextField("Search setlists...", text: $setlistSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                if !setlistSearchText.isEmpty {
                    Button(action: { setlistSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.18))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Source Filter Tabs (All | Local | Cloud)
            HStack(spacing: 6) {
                ForEach(LibrarySourceFilter.allCases, id: \.self) { filter in
                    let isSelected = setlistSourceFilter == filter
                    Button(action: { setlistSourceFilter = filter }) {
                        HStack(spacing: 4) {
                            if filter == .cloud {
                                Image(systemName: library.isCloudConnected ? "icloud.fill" : "icloud")
                                    .font(.system(size: 10))
                            } else if filter == .local {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 10))
                            }
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundColor(isSelected ? .white : Color(white: 0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color(red: 0.22, green: 0.45, blue: 0.72) : Color(white: 0.16))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if library.isScanningSetlists {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Scanning Local & Cloud Setlists...")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.55))
                    .padding(.top, 6)
                Spacer()
            } else if filteredLibrarySetlists.isEmpty {
                Spacer()
                if setlistSourceFilter == .cloud && !library.isCloudConnected {
                    VStack(spacing: 8) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 24))
                            .foregroundColor(Color(white: 0.45))
                        Text("Cloud Library Not Connected")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.8))
                        Text("Open Settings (gear icon) and select an iCloud Drive, Dropbox, Google Drive, or OneDrive folder.")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(white: 0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 24))
                            .foregroundColor(Color(white: 0.45))
                        Text(library.setlists.isEmpty ? "No Saved Setlists Found" : "No Matching Setlists")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.8))
                        Text(setlistSourceFilter == .cloud ? (library.cloudSetlistsDirectory?.path ?? "Cloud/Setlists") : "~/Music/PeanutButter/Setlists")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 16)
                        Button("Open from Finder...") {
                            openSessionDialog()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.28, green: 0.68, blue: 0.98).opacity(0.25))
                        .cornerRadius(5)
                        .padding(.top, 4)
                    }
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredLibrarySetlists) { item in
                            HStack(spacing: 10) {
                                Button(action: {
                                    openLibrarySetlistDetail(item)
                                }) {
                                    HStack(spacing: 10) {
                                        setlistLibraryThumbnail(item.artworks)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Text(item.name)
                                                    .font(.system(size: 12.5, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)

                                                HStack(spacing: 3) {
                                                    Image(systemName: item.source == .cloud ? "icloud.fill" : "internaldrive")
                                                        .font(.system(size: 8.5))
                                                    Text(item.source.rawValue)
                                                        .font(.system(size: 9, weight: .bold))
                                                }
                                                .foregroundColor(item.source == .cloud ? Color(red: 0.45, green: 0.80, blue: 1.0) : Color(white: 0.65))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(item.source == .cloud ? Color(red: 0.12, green: 0.24, blue: 0.34) : Color(white: 0.2))
                                                .cornerRadius(3)

                                                if setlistHasCloudUpdate(item) {
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "arrow.triangle.2.circlepath")
                                                            .font(.system(size: 8.5, weight: .bold))
                                                        Text("Update")
                                                            .font(.system(size: 9, weight: .bold))
                                                    }
                                                    .foregroundColor(.black)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color(red: 0.30, green: 0.88, blue: 0.98))
                                                    .cornerRadius(3)
                                                    .help("A newer version of this Cloud Setlist is available")
                                                } else if item.source == .cloud && !item.isDownloaded {
                                                    Image(systemName: "icloud.and.arrow.down")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.orange)
                                                        .help("In Cloud — will download automatically when opened")
                                                }
                                            }
                                            if !item.formattedDate.isEmpty {
                                                Text(item.formattedDate)
                                                    .font(.system(size: 10.5))
                                                    .foregroundColor(Color(white: 0.58))
                                                    .lineLimit(1)
                                            }
                                            Text("\(item.songCount) Songs • \(item.formattedDuration)")
                                                .font(.system(size: 10.5))
                                                .foregroundColor(Color(white: 0.58))
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if item.source == .local, let cloudSetlistsDir = library.cloudSetlistsDirectory {
                                    Button(action: {
                                        let fileName = LibraryBrowserManager.sanitizedPackageFilename(item.name, ext: "pbsession")
                                        let src = item.url
                                        let dest = cloudSetlistsDir.appendingPathComponent(fileName)
                                        statusMessage = "Copying to Cloud..."
                                        Task.detached(priority: .userInitiated) {
                                            do {
                                                try PlaybackFileManager.shared.copyLibraryPackage(from: src, to: dest, isSong: false)
                                                await MainActor.run {
                                                    statusMessage = nil
                                                    library.refreshSetlists()
                                                }
                                            } catch {
                                                await MainActor.run {
                                                    statusMessage = "Copy to Cloud failed: \(error.localizedDescription)"
                                                }
                                            }
                                        }
                                    }) {
                                        Image(systemName: "icloud.and.arrow.up")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(Color(red: 0.45, green: 0.80, blue: 1.0))
                                            .padding(5)
                                            .background(Color(red: 0.14, green: 0.22, blue: 0.30))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy Setlist to Cloud Library")
                                } else if item.source == .cloud {
                                    Button(action: {
                                        let fileName = LibraryBrowserManager.sanitizedPackageFilename(item.name, ext: "pbsession")
                                        let src = item.url
                                        let dest = library.setlistsDirectory.appendingPathComponent(fileName)
                                        statusMessage = "Downloading to Local..."
                                        Task.detached(priority: .userInitiated) {
                                            do {
                                                try PlaybackFileManager.shared.copyLibraryPackage(from: src, to: dest, isSong: false)
                                                await MainActor.run {
                                                    statusMessage = nil
                                                    library.refreshSetlists()
                                                }
                                            } catch {
                                                await MainActor.run {
                                                    statusMessage = "Copy to Local failed: \(error.localizedDescription)"
                                                }
                                            }
                                        }
                                    }) {
                                        Image(systemName: "arrow.down.to.line.compact")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(Color(white: 0.85))
                                            .padding(5)
                                            .background(Color(white: 0.22))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy Setlist to Local Library")
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(white: 0.45))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Library Setlist Detail View

    private var currentSetlistCloudUpdateItem: SetlistLibraryItem? {
        let currentFileName = engine.currentSessionURL?.lastPathComponent.lowercased()
            ?? LibraryBrowserManager.sanitizedPackageFilename(engine.currentSetlist.name, ext: "pbsession").lowercased()
        return library.setlists.first { item in
            guard item.source == .cloud, setlistHasCloudUpdate(item) else { return false }
            if let curURL = engine.currentSessionURL, curURL == item.url {
                return true
            }
            return item.url.lastPathComponent.lowercased() == currentFileName
        }
    }

    private func setlistHasCloudUpdate(_ item: SetlistLibraryItem) -> Bool {
        engine.shouldShowCloudUpdate(for: item)
    }

    private func openLibrarySetlistDetail(_ item: SetlistLibraryItem) {
        selectedLibrarySetlist = item
        selectedSetlistSongs = []
        isLoadingSetlistSongs = true
        withAnimation(.easeInOut(duration: 0.18)) {
            currentScreen = .librarySetlistDetail
        }
        let targetItem = item
        Task.detached(priority: .userInitiated) {
            let previews = LibraryBrowserManager.loadSetlistSongsPreview(for: targetItem)
            await MainActor.run {
                if self.selectedLibrarySetlist?.id == targetItem.id {
                    self.selectedSetlistSongs = previews
                    self.isLoadingSetlistSongs = false
                }
            }
        }
    }

    @ViewBuilder
    private var librarySetlistDetailView: some View {
        if let item = selectedLibrarySetlist {
            VStack(spacing: 0) {
                // Header: < (left), Setlist (center), Load (right)
                HStack {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .setlistsBrowser
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Setlist")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    Spacer()

                    Button(action: {
                        if setlistHasCloudUpdate(item) {
                            pendingCloudUpdateItem = item
                            showCloudUpdateConfirmAlert = true
                        } else {
                            do {
                                try engine.loadSession(from: item.url)
                                onDismiss()
                            } catch {
                                statusMessage = "Open error: \(error.localizedDescription)"
                            }
                        }
                    }) {
                        Text("Load")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.white.opacity(0.12))

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Setlist Summary Card
                        HStack(spacing: 12) {
                            setlistLibraryThumbnail(item.artworks)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                if !item.formattedDate.isEmpty {
                                    Text(item.formattedDate)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(Color(white: 0.6))
                                        .lineLimit(1)
                                }

                                Text("\(item.songCount) Songs • \(item.formattedDuration)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(white: 0.6))
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: setlistHasCloudUpdate(item) ? "arrow.triangle.2.circlepath" : (item.isDownloaded ? "checkmark.square" : "icloud.and.arrow.down"))
                                .font(.system(size: 14))
                                .foregroundColor(setlistHasCloudUpdate(item) ? Color(red: 0.30, green: 0.88, blue: 0.98) : (item.isDownloaded ? Color(white: 0.55) : .orange))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.16, green: 0.17, blue: 0.18))

                        if setlistHasCloudUpdate(item) {
                            HStack(spacing: 8) {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))
                                Text("Cloud update available")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.white)
                                Spacer()
                                Button(action: {
                                    pendingCloudUpdateItem = item
                                    showCloudUpdateConfirmAlert = true
                                }) {
                                    Text(engine.currentSessionURL == item.url ? "Reload Update" : "Download & Load")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color(red: 0.30, green: 0.88, blue: 0.98))
                                        .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.12, green: 0.20, blue: 0.25))
                        }

                        // SONGS Section Header
                        Text("SONGS")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.55))
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        if isLoadingSetlistSongs {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 16)
                                Spacer()
                            }
                            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        } else if selectedSetlistSongs.isEmpty {
                            Text(item.isDownloaded ? "No songs in this setlist." : "Setlist is in iCloud — tap Load to download.")
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(white: 0.55))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(selectedSetlistSongs.enumerated()), id: \.element.id) { idx, song in
                                    HStack(spacing: 10) {
                                        if let img = song.artwork {
                                            Image(nsImage: img)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 34, height: 34)
                                                .cornerRadius(4)
                                                .clipped()
                                        } else {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color(white: 0.22))
                                                    .frame(width: 34, height: 34)
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 13))
                                                    .foregroundColor(Color(white: 0.6))
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 1.5) {
                                            Text(song.title)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)

                                            Text(song.artist.isEmpty ? "Default Arrangement" : song.artist)
                                                .font(.system(size: 10.5))
                                                .foregroundColor(Color(white: 0.58))
                                                .lineLimit(1)

                                            Text("\(song.formattedDuration) • \(song.musicalKey) • \(Int(song.bpm.rounded())) BPM \(song.timeSignature)")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(white: 0.52))
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: song.isDownloaded ? "checkmark.square" : "icloud.and.arrow.down")
                                            .font(.system(size: 13.5))
                                            .foregroundColor(song.isDownloaded ? Color(white: 0.5) : .orange)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)

                                    if idx < selectedSetlistSongs.count - 1 {
                                        rowDivider
                                    }
                                }
                            }
                            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        }

                        // Bottom Actions
                        VStack(spacing: 0) {
                            if item.source == .cloud {
                                Button(action: {
                                    library.removeSetlistFromDevice(item)
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        currentScreen = .setlistsBrowser
                                    }
                                }) {
                                    HStack {
                                        Text("Remove Setlist From Device")
                                            .font(.system(size: 13.5, weight: .regular))
                                            .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                rowDivider
                            }

                            Button(action: {
                                showingDeleteSelectedSetlistAlert = true
                            }) {
                                HStack {
                                    Text("Delete Setlist")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundColor(Color(red: 0.95, green: 0.25, blue: 0.25))
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
            .alert("Delete Setlist?", isPresented: $showingDeleteSelectedSetlistAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Setlist", role: .destructive) {
                    do {
                        try library.deleteSetlist(item)
                        withAnimation(.easeInOut(duration: 0.18)) {
                            currentScreen = .setlistsBrowser
                        }
                    } catch {
                        statusMessage = "Delete error: \(error.localizedDescription)"
                    }
                }
            } message: {
                Text("Are you sure you want to delete \"\(item.name)\" from \(item.source.rawValue) Setlists? Songs in your library will not be deleted.")
            }
        }
    }

    private func setlistLibraryThumbnail(_ artworks: [NSImage]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.22))
                .frame(width: 40, height: 40)
            if artworks.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.6))
            } else if artworks.count == 1 {
                Image(nsImage: artworks[0])
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipped()
                    .cornerRadius(4)
            } else {
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        Image(nsImage: artworks[0]).resizable().scaledToFill().frame(width: 19, height: 19).clipped()
                        Image(nsImage: artworks.count > 1 ? artworks[1] : artworks[0]).resizable().scaledToFill().frame(width: 19, height: 19).clipped()
                    }
                    HStack(spacing: 1) {
                        Image(nsImage: artworks.count > 2 ? artworks[2] : artworks[0]).resizable().scaledToFill().frame(width: 19, height: 19).clipped()
                        Image(nsImage: artworks.count > 3 ? artworks[3] : artworks[0]).resizable().scaledToFill().frame(width: 19, height: 19).clipped()
                    }
                }
                .frame(width: 40, height: 40)
                .cornerRadius(4)
            }
        }
    }

    // MARK: - Actions
    
    private func openSessionDialog() {
        let panel = NSOpenPanel()
        panel.directoryURL = LibraryBrowserManager.shared.setlistsDirectory
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if let sessionType = UTType(filenameExtension: "pbsession") {
            panel.allowedContentTypes = [sessionType, .data, .package]
        } else {
            panel.allowedContentTypes = [.data, .package]
        }
        panel.message = "Choose a Playback Session File (.pbsession)"
        panel.prompt = "Open Session"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try engine.loadSession(from: url)
                onDismiss()
            } catch {
                statusMessage = "Open error: \(error.localizedDescription)"
            }
        }
    }
    
    private func saveSessionQuick(changeDescription: String? = nil) {
        onDismiss()
        engine.saveQuickSession(changeDescription: changeDescription)
    }
    
    private func saveSessionAsNew() {
        let panel = NSSavePanel()
        panel.treatsFilePackagesAsDirectories = false
        if let sessionType = UTType(filenameExtension: "pbsession") {
            panel.allowedContentTypes = [sessionType]
        }
        let defaultName = engine.currentSetlist.name.isEmpty ? "Untitled Session" : engine.currentSetlist.name
        panel.nameFieldStringValue = LibraryBrowserManager.sanitizedPackageFilename(defaultName, ext: "pbsession")
        panel.message = "Save Playback Session File (.pbsession)"
        panel.prompt = "Save Session"
        
        if panel.runModal() == .OK, let url = panel.url {
            let revisionId = UUID()
            engine.clearSaveAndCloudUpdateIndicators(revisionId: revisionId, targetURLs: [url])
            onDismiss()
            Task { @MainActor in
                do {
                    try await engine.saveSessionAsync(to: url, revisionId: revisionId)
                    library.refreshSetlists()
                } catch {
                    print("Save error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func saveSessionToLibrary(cloud: Bool, changeDescription: String? = nil) {
        let baseDir: URL? = cloud ? library.cloudSetlistsDirectory : library.setlistsDirectory
        guard let targetDir = baseDir else {
            statusMessage = "Cloud Library is not connected."
            return
        }
        let defaultName = engine.currentSetlist.name.isEmpty ? "Untitled Session" : engine.currentSetlist.name
        let fileName = LibraryBrowserManager.sanitizedPackageFilename(defaultName, ext: "pbsession")
        let destURL = targetDir.appendingPathComponent(fileName)
        let revisionId = UUID()
        engine.clearSaveAndCloudUpdateIndicators(revisionId: revisionId, targetURLs: [destURL])
        onDismiss()
        Task { @MainActor in
            do {
                try await engine.saveSessionAsync(to: destURL, changeDescription: changeDescription, revisionId: revisionId)
                library.refreshSetlists()
            } catch {
                print("Save error: \(error.localizedDescription)")
            }
        }
    }
    
    private func restoreFromPreviousSave() {
        if let currentURL = engine.currentSessionURL {
            do {
                try engine.loadSession(from: currentURL)
                onDismiss()
            } catch {
                statusMessage = "Restore error: \(error.localizedDescription)"
            }
        } else {
            openSessionDialog()
        }
    }
}
