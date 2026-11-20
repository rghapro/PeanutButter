import SwiftUI
import AppKit

/// In-window pop-out menu for uploading, mapping, previewing, and managing user custom Click sample packs.
public struct CustomClickSampleManagerSheet: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var library = CustomSampleLibraryManager.shared
    let onClose: () -> Void
    
    @State private var selectedPackId: String?
    @State private var newPackName: String = ""
    @State private var editingPackName: String = ""
    
    public init(engine: MultitrackAudioEngine, initialPackId: String? = nil, onClose: @escaping () -> Void = {}) {
        self.engine = engine
        self.onClose = onClose
        _selectedPackId = State(initialValue: initialPackId ?? engine.currentSong.clickSound.customPackId ?? CustomSampleLibraryManager.shared.customClickPacks.first?.id)
    }
    
    private var selectedPack: CustomClickPack? {
        if let id = selectedPackId, let match = library.customClickPacks.first(where: { $0.id == id }) {
            return match
        }
        return library.customClickPacks.first
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Click Samples")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("Upload 1–4 audio files (.wav, .m4a, .mp3, .aiff) per click pack. Unassigned subdivisions fall back automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.65))
                }
                Spacer()
                Button("Done") {
                    library.stopPreview()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.70, blue: 0.85))
            }
            .padding(16)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
            
            Divider().background(Color(white: 0.22))
            
            HStack(spacing: 0) {
                // Left Pack List
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Button(action: {
                            library.promptImportCustomClickPack { imported in
                                if let pack = imported {
                                    DispatchQueue.main.async {
                                        selectedPackId = pack.id
                                        editingPackName = pack.name
                                    }
                                }
                            }
                        }) {
                            Label("Import Files / Folder", systemImage: "folder.badge.plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.0, green: 0.70, blue: 0.85))
                    }
                    
                    HStack(spacing: 6) {
                        TextField("New empty pack...", text: $newPackName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("+") {
                            let created = library.createCustomClickPack(name: newPackName)
                            newPackName = ""
                            selectedPackId = created.id
                            editingPackName = created.name
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            if library.customClickPacks.isEmpty {
                                Text("No custom click packs yet.\nImport a folder or WAV files to start.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.50))
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 24)
                            } else {
                                ForEach(library.customClickPacks) { pack in
                                    let isSelected = selectedPack?.id == pack.id
                                    Button(action: {
                                        selectedPackId = pack.id
                                        editingPackName = pack.name
                                    }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(pack.name)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                Text("\(pack.assignedSubdivisionCount)/4 samples")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color(white: 0.58))
                                            }
                                            Spacer()
                                            if library.defaultClickSound.customPackId == pack.id {
                                                Text("DEF")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(Color(red: 0.0, green: 0.75, blue: 0.90))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color(red: 0.0, green: 0.75, blue: 0.90).opacity(0.16))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? Color(red: 0.0, green: 0.70, blue: 0.85).opacity(0.22) : Color.clear)
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 225)
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                
                Divider().background(Color(white: 0.22))
                
                // Right Pack Editor
                VStack(alignment: .leading, spacing: 14) {
                    if let pack = selectedPack {
                        HStack(spacing: 8) {
                            TextField("Pack Name", text: $editingPackName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, weight: .semibold))
                                .onAppear { editingPackName = pack.name }
                                .onChange(of: pack.id) { _ in editingPackName = pack.name }
                            
                            Button("Rename") {
                                library.renameClickPack(id: pack.id, newName: editingPackName)
                            }
                            .disabled(editingPackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingPackName == pack.name)
                            
                            Spacer()
                            
                            Button(role: .destructive, action: {
                                let deletedId = pack.id
                                library.deleteClickPack(id: deletedId)
                                engine.refreshCurrentTracksAfterCustomSampleEdit(clickPackId: deletedId)
                                selectedPackId = library.customClickPacks.first?.id
                            }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help("Delete this custom click pack")
                        }
                        
                        HStack(spacing: 8) {
                            Button(action: {
                                engine.setClickSound(pack.clickSoundType)
                            }) {
                                Label(
                                    engine.currentSong.clickSound == pack.clickSoundType ? "Active on Song" : "Use on Current Song",
                                    systemImage: engine.currentSong.clickSound == pack.clickSoundType ? "checkmark.circle.fill" : "waveform"
                                )
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .disabled(!pack.hasAnyAudio)
                            
                            Button(action: {
                                engine.setDefaultClickSound(pack.clickSoundType, syncDefaultSongs: true)
                            }) {
                                Label(
                                    library.defaultClickSound == pack.clickSoundType ? "Default Click ✓" : "Set as Default Click",
                                    systemImage: "star"
                                )
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .disabled(!pack.hasAnyAudio)
                            
                            Spacer()
                        }
                        
                        Divider().background(Color(white: 0.20))
                        
                        Text("SUBDIVISION SAMPLES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(white: 0.55))
                        
                        VStack(spacing: 8) {
                            subdivisionRow(pack: pack, subdivision: .accent, subtitle: "Beat 1 Downbeat Accent")
                            subdivisionRow(pack: pack, subdivision: .quarter, subtitle: "Main Quarter-Note Pulse")
                            subdivisionRow(pack: pack, subdivision: .eighth, subtitle: "Eighth-Note (&) Subdivision")
                            subdivisionRow(pack: pack, subdivision: .sixteenth, subtitle: "Sixteenth-Note (e / a) Subdivision")
                        }
                        
                        Spacer()
                    } else {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "metronome")
                                    .font(.system(size: 28))
                                    .foregroundColor(Color(white: 0.45))
                                Text("Select or import a custom click pack to map samples.")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(white: 0.60))
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.12, green: 0.13, blue: 0.16))
            }
        }
        .frame(width: 580, height: 390)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 20, x: 0, y: 10)
        .onDisappear {
            library.stopPreview()
        }
    }
    
    @ViewBuilder
    private func subdivisionRow(pack: CustomClickPack, subdivision: ClickSubdivision, subtitle: String) -> some View {
        let assigned = pack.assignedFile(for: subdivision)
        let resolvedURL = pack.resolvedURL(for: subdivision)
        
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subdivision.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.55))
            }
            .frame(width: 155, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 1) {
                if let file = assigned {
                    Text(file)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.35, green: 0.90, blue: 0.65))
                        .lineLimit(1)
                } else if let fb = resolvedURL {
                    Text("Fallback: \(fb.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.60))
                        .lineLimit(1)
                } else {
                    Text("Unassigned (Synth fallback)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if let previewURL = resolvedURL {
                Button(action: {
                    library.previewAudioFile(at: previewURL)
                }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .help("Preview \(subdivision.rawValue)")
            }
            
            Button(assigned == nil ? "Upload..." : "Replace...") {
                library.promptAssignClickSubdivision(packId: pack.id, subdivision: subdivision) { ok in
                    if ok {
                        DispatchQueue.main.async {
                            engine.refreshCurrentTracksAfterCustomSampleEdit(clickPackId: pack.id)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
            
            if assigned != nil {
                Button(action: {
                    if library.setClickSubdivisionFile(packId: pack.id, subdivision: subdivision, sourceURL: nil) {
                        engine.refreshCurrentTracksAfterCustomSampleEdit(clickPackId: pack.id)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .help("Remove sample from \(subdivision.rawValue)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(7)
    }
}

/// In-window pop-out menu for uploading, auto-mapping, previewing, and managing user custom Guide Voice sample packs.
public struct CustomGuideSampleManagerSheet: View {
    private enum GuideImportFilter: String, CaseIterable {
        case all = "All"
        case custom = "Custom"
        case songSection = "Section"
        case directional = "Directional"
        case countIn = "Count-In"
    }

    private struct PendingGuideImportSession {
        var targetPackId: String?
        var targetPackDisplayName: String?
        var packName: String
        var items: [PendingGuideImportItem]
    }

    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var library = CustomSampleLibraryManager.shared
    let onClose: () -> Void
    
    @State private var selectedPackId: String?
    @State private var newPackName: String = ""
    @State private var editingPackName: String = ""
    @State private var cueSearchText: String = ""
    @State private var customPhraseText: String = ""
    @State private var customPhraseCueKind: CustomGuideCueKind = .directional
    @State private var didManuallyChooseCueKind: Bool = false
    @State private var pendingImport: PendingGuideImportSession?
    @State private var importFilter: GuideImportFilter = .all
    
    public init(engine: MultitrackAudioEngine, initialPackId: String? = nil, onClose: @escaping () -> Void = {}) {
        self.engine = engine
        self.onClose = onClose
        _selectedPackId = State(initialValue: initialPackId ?? engine.currentSong.guideVoice.customPackId ?? CustomSampleLibraryManager.shared.userCustomGuidePacks.first?.id)
    }
    
    private var selectedPack: CustomGuidePack? {
        if let id = selectedPackId, let match = library.userCustomGuidePacks.first(where: { $0.id == id }) {
            return match
        }
        return library.userCustomGuidePacks.first
    }
    
    private var standardNormalizedKeys: Set<String> {
        CustomSampleLibraryManager.standardNormalizedKeys
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pendingImport == nil ? "Custom Guide Voice Samples" : "Review & Label Guide Cues")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(pendingImport == nil
                         ? "Import a folder or files named by cue (1.wav, Chorus 1.wav, All In.wav) or upload cues individually. Missing cues use Fallback Voice."
                         : "Auto-assigned from filenames. Adjust any cue between Song Section and Directional Cue before importing.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.65))
                }
                Spacer()
                Button("Done") {
                    library.stopPreview()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.70, blue: 0.85))
            }
            .padding(16)
            .background(Color(red: 0.09, green: 0.10, blue: 0.12))
            
            Divider().background(Color(white: 0.22))

            if let session = pendingImport {
                reviewImportView(session: session)
            } else {
                HStack(spacing: 0) {
                    // Left Pack List
                    VStack(spacing: 10) {
                        Button(action: {
                            library.promptSelectGuideImportURLs(
                                title: "Import Custom Guide Voice Samples",
                                message: "Select a folder or audio files named by cue (e.g. 1.wav, Intro.wav, Chorus.wav, All In.wav)."
                            ) { urls in
                                guard !urls.isEmpty else { return }
                                let prepared = library.prepareGuideImportItems(from: urls)
                                guard !prepared.items.isEmpty else { return }
                                DispatchQueue.main.async {
                                    importFilter = .all
                                    pendingImport = PendingGuideImportSession(
                                        targetPackId: nil,
                                        targetPackDisplayName: nil,
                                        packName: prepared.derivedPackName,
                                        items: prepared.items
                                    )
                                }
                            }
                        }) {
                            Label("Import Folder / Files", systemImage: "folder.badge.plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.0, green: 0.70, blue: 0.85))
                        
                        HStack(spacing: 6) {
                            TextField("New voice pack...", text: $newPackName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("+") {
                                let created = library.createCustomGuidePack(name: newPackName)
                                newPackName = ""
                                selectedPackId = created.id
                                editingPackName = created.name
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                if library.userCustomGuidePacks.isEmpty {
                                    Text("No custom guide packs yet.\nImport a folder of recorded cues to begin.")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.50))
                                        .multilineTextAlignment(.center)
                                        .padding(.top, 24)
                                } else {
                                    ForEach(library.userCustomGuidePacks) { pack in
                                        let isSelected = selectedPack?.id == pack.id
                                        Button(action: {
                                            selectedPackId = pack.id
                                            editingPackName = pack.name
                                        }) {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(pack.name)
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundColor(.white)
                                                        .lineLimit(1)
                                                    Text("\(pack.phraseCount) cues mapped")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(Color(white: 0.58))
                                                }
                                                Spacer()
                                                if library.defaultGuideVoice.customPackId == pack.id {
                                                    Text("DEF")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(Color(red: 0.0, green: 0.75, blue: 0.90))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(Color(red: 0.0, green: 0.75, blue: 0.90).opacity(0.16))
                                                        .cornerRadius(4)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(isSelected ? Color(red: 0.0, green: 0.70, blue: 0.85).opacity(0.22) : Color.clear)
                                            .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 225)
                    .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                    
                    Divider().background(Color(white: 0.22))
                    
                    // Right Pack Editor
                    VStack(alignment: .leading, spacing: 12) {
                        if let pack = selectedPack {
                            HStack(spacing: 8) {
                                TextField("Voice Pack Name", text: $editingPackName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13, weight: .semibold))
                                    .onAppear { editingPackName = pack.name }
                                    .onChange(of: pack.id) { _ in editingPackName = pack.name }
                                
                                Button("Rename") {
                                    library.renameGuidePack(id: pack.id, newName: editingPackName)
                                }
                                .disabled(editingPackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingPackName == pack.name)
                                
                                Button("Batch Import...") {
                                    library.promptSelectGuideImportURLs(
                                        title: "Import Guide Voice Samples",
                                        message: "Select audio files or folders named by cue phrase (e.g. 1.wav, Verse 1.wav, Chorus.wav)."
                                    ) { urls in
                                        guard !urls.isEmpty else { return }
                                        let prepared = library.prepareGuideImportItems(from: urls)
                                        guard !prepared.items.isEmpty else { return }
                                        DispatchQueue.main.async {
                                            importFilter = .all
                                            pendingImport = PendingGuideImportSession(
                                                targetPackId: pack.id,
                                                targetPackDisplayName: pack.name,
                                                packName: pack.name,
                                                items: prepared.items
                                            )
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                
                                Button(role: .destructive, action: {
                                    let deletedId = pack.id
                                    library.deleteGuidePack(id: deletedId)
                                    engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: deletedId)
                                    selectedPackId = library.userCustomGuidePacks.first?.id
                                }) {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            HStack(spacing: 8) {
                                Button(action: {
                                    engine.setGuideVoice(pack.guideVoice)
                                }) {
                                    Label(
                                        engine.currentSong.guideVoice == pack.guideVoice ? "Active on Song" : "Use on Current Song",
                                        systemImage: engine.currentSong.guideVoice == pack.guideVoice ? "checkmark.circle.fill" : "waveform"
                                    )
                                    .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                
                                Button(action: {
                                    engine.setDefaultGuideVoice(pack.guideVoice, syncDefaultSongs: true)
                                }) {
                                    Label(
                                        library.defaultGuideVoice == pack.guideVoice ? "Default Guide ✓" : "Set as Default Guide",
                                        systemImage: "star"
                                    )
                                    .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                
                                Spacer()
                                
                                TextField("Search cues...", text: $cueSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 155)
                            }
                            
                            // Add custom phrase row
                            HStack(spacing: 6) {
                                TextField("Add custom cue phrase (e.g. Horns In, Altar Call)...", text: $customPhraseText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .onChange(of: customPhraseText) { _, newValue in
                                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if trimmed.isEmpty {
                                            didManuallyChooseCueKind = false
                                            customPhraseCueKind = .directional
                                        } else if !didManuallyChooseCueKind {
                                            let norm = AudioSampleBank.shared.normalizePhraseKey(trimmed)
                                            customPhraseCueKind = CustomSampleLibraryManager.defaultCueKind(forNormalizedPhrase: norm)
                                        }
                                    }

                                let trimmedDraft = customPhraseText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmedDraft.isEmpty {
                                    if let autoCategory = CustomSampleLibraryManager.recognizedStandardCategoryTitle(forPhrase: trimmedDraft) {
                                        Text("Auto: \(autoCategory)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Color(red: 0.35, green: 0.90, blue: 0.65))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color(red: 0.35, green: 0.90, blue: 0.65).opacity(0.14))
                                            .cornerRadius(4)
                                    } else {
                                        cueKindSelectorPill(selectedKind: customPhraseCueKind) { chosen in
                                            customPhraseCueKind = chosen
                                            didManuallyChooseCueKind = true
                                        }
                                    }
                                }

                                Button("Upload Custom Cue...") {
                                    guard !trimmedDraft.isEmpty else { return }
                                    let chosenKind = customPhraseCueKind
                                    library.promptAssignGuidePhrase(packId: pack.id, phrase: trimmedDraft, cueKind: chosenKind) { ok in
                                        if ok {
                                            DispatchQueue.main.async {
                                                customPhraseText = ""
                                                didManuallyChooseCueKind = false
                                                engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(trimmedDraft.isEmpty)
                            }
                            
                            Divider().background(Color(white: 0.20))
                            
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    // Unrecognized user-uploaded cues (user chooses Directional vs. Song Section)
                                    let extraKeys = pack.phraseFiles.keys
                                        .filter { !standardNormalizedKeys.contains($0) }
                                        .sorted()
                                        .filter {
                                            cueSearchText.isEmpty ||
                                            $0.localizedCaseInsensitiveContains(cueSearchText) ||
                                            pack.displayLabel(forNormalizedPhrase: $0).localizedCaseInsensitiveContains(cueSearchText)
                                        }
                                    
                                    if !extraKeys.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("CUSTOM CUES")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(Color(white: 0.55))
                                                Text("Not automatically recognized — choose Directional Cue or Song Section:")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color(white: 0.45))
                                            }
                                            ForEach(extraKeys, id: \.self) { key in
                                                customGuideCueRow(pack: pack, phraseKey: key)
                                            }
                                        }
                                    }
                                    
                                    ForEach(CustomSampleLibraryManager.standardGuideCueCategories) { category in
                                        let isCountInCategory = (category.id == "countin")
                                        let matchingPhrases = category.phrases.filter {
                                            cueSearchText.isEmpty || $0.localizedCaseInsensitiveContains(cueSearchText)
                                        }
                                        if !matchingPhrases.isEmpty {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(category.title.uppercased())
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(Color(white: 0.55))
                                                ForEach(matchingPhrases, id: \.self) { phrase in
                                                    let norm = AudioSampleBank.shared.normalizePhraseKey(phrase)
                                                    guideCueRow(pack: pack, label: phrase, phraseKey: norm, isCountIn: isCountInCategory)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.trailing, 4)
                            }
                        } else {
                            Spacer()
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "mic.circle")
                                        .font(.system(size: 28))
                                        .foregroundColor(Color(white: 0.45))
                                    Text("Select or import a custom guide voice pack to map cue samples.")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.60))
                                }
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.16))
                }
            }
        }
        .frame(width: 780, height: 520)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 20, x: 0, y: 10)
        .onDisappear {
            library.stopPreview()
        }
    }

    @ViewBuilder
    private func reviewImportView(session: PendingGuideImportSession) -> some View {
        let items = session.items
        let customItems = items.filter { !$0.isStandardMatch && !$0.isCountIn }
        let sectionItems = items.filter { !$0.isCountIn && $0.cueKind == .songSection }
        let directionalItems = items.filter { !$0.isCountIn && $0.cueKind == .directional }
        let countInItems = items.filter { $0.isCountIn }

        let visibleIndices = items.indices.filter { idx in
            let item = items[idx]
            switch importFilter {
            case .all: return true
            case .custom: return !item.isStandardMatch && !item.isCountIn
            case .songSection: return !item.isCountIn && item.cueKind == .songSection
            case .directional: return !item.isCountIn && item.cueKind == .directional
            case .countIn: return item.isCountIn
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if session.targetPackId == nil {
                    Text("Pack Name:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.72))
                    TextField(
                        "Voice Pack Name",
                        text: Binding(
                            get: { pendingImport?.packName ?? session.packName },
                            set: { val in pendingImport?.packName = val }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: 260)
                } else {
                    Text("Importing Into:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.72))
                    Text(session.targetPackDisplayName ?? session.packName)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(Color(red: 0.0, green: 0.85, blue: 0.95))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.0, green: 0.75, blue: 0.90).opacity(0.16))
                        .cornerRadius(6)
                }

                Spacer()

                if !customItems.isEmpty {
                    Button("Custom -> Section") {
                        setCustomImportItemsKind(.songSection)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))

                    Button("Custom -> Directional") {
                        setCustomImportItemsKind(.directional)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }
            }

            HStack(spacing: 6) {
                reviewFilterButton(.all, count: items.count)
                if !customItems.isEmpty {
                    reviewFilterButton(.custom, count: customItems.count)
                }
                reviewFilterButton(.songSection, count: sectionItems.count)
                reviewFilterButton(.directional, count: directionalItems.count)
                if !countInItems.isEmpty {
                    reviewFilterButton(.countIn, count: countInItems.count)
                }
                Spacer()
            }

            Divider().background(Color(white: 0.22))

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visibleIndices, id: \.self) { idx in
                        let item = items[idx]
                        HStack(spacing: 10) {
                            Button(action: { library.previewAudioFile(at: item.sourceURL) }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.displayLabel)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(item.isStandardMatch ? "Auto" : "Custom")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(item.isStandardMatch ? Color(red: 0.35, green: 0.90, blue: 0.65) : Color(red: 0.98, green: 0.78, blue: 0.28))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background((item.isStandardMatch ? Color(red: 0.35, green: 0.90, blue: 0.65) : Color(red: 0.98, green: 0.78, blue: 0.28)).opacity(0.16))
                                        .cornerRadius(4)
                                }
                                Text(item.filename)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.52))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if item.isCountIn {
                                Text("Count-In")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(white: 0.70))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(5)
                            } else {
                                cueKindSelectorPill(selectedKind: item.cueKind) { chosenKind in
                                    pendingImport?.items[idx].cueKind = chosenKind
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                    }
                }
                .padding(.trailing, 4)
            }

            Divider().background(Color(white: 0.22))

            HStack {
                Button("Cancel") {
                    library.stopPreview()
                    pendingImport = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Import \(items.count) \(items.count == 1 ? "Cue" : "Cues")") {
                    library.stopPreview()
                    commitPendingImport()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.70, blue: 0.85))
                .disabled(items.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.13, blue: 0.16))
    }

    @ViewBuilder
    private func reviewFilterButton(_ filter: GuideImportFilter, count: Int) -> some View {
        let isSelected = (importFilter == filter)
        Button(action: { importFilter = filter }) {
            Text("\(filter.rawValue) (\(count))")
                .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .black : Color(white: 0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color(red: 0.0, green: 0.80, blue: 0.92) : Color.white.opacity(0.07))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func setCustomImportItemsKind(_ kind: CustomGuideCueKind) {
        guard var session = pendingImport else { return }
        for i in session.items.indices where !session.items[i].isStandardMatch && !session.items[i].isCountIn {
            session.items[i].cueKind = kind
        }
        pendingImport = session
    }

    private func commitPendingImport() {
        guard let session = pendingImport else { return }
        if let targetId = session.targetPackId {
            let count = library.importGuideFiles(session.items, intoPackId: targetId)
            if count > 0 {
                engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: targetId)
            }
        } else {
            let cleanName = session.packName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = cleanName.isEmpty ? "Custom Guide" : cleanName
            if let created = library.importCustomGuidePack(name: finalName, items: session.items) {
                selectedPackId = created.id
                editingPackName = created.name
                engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: created.id)
            }
        }
        pendingImport = nil
    }
    
    @ViewBuilder
    private func cueKindSelectorPill(
        selectedKind: CustomGuideCueKind,
        onSelect: @escaping (CustomGuideCueKind) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(CustomGuideCueKind.allCases, id: \.self) { kind in
                let isSelected = selectedKind == kind
                let activeColor = (kind == .directional)
                    ? Color(red: 0.0, green: 0.68, blue: 0.88)
                    : Color(red: 0.36, green: 0.50, blue: 0.96)
                Button(action: { onSelect(kind) }) {
                    Text(kind == .directional ? "Directional" : "Song Section")
                        .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .white : Color(white: 0.62))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(isSelected ? activeColor : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06))
        .cornerRadius(5)
    }

    @ViewBuilder
    private func customGuideCueRow(pack: CustomGuidePack, phraseKey: String) -> some View {
        let label = pack.displayLabel(forNormalizedPhrase: phraseKey)
        let currentKind = pack.cueKind(forNormalizedPhrase: phraseKey)
        let assignedFile = pack.phraseFiles[phraseKey]
        let fileURL = pack.fileURL(forNormalizedPhrase: phraseKey)

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let file = assignedFile {
                    Text(file)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.35, green: 0.90, blue: 0.65))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cueKindSelectorPill(selectedKind: currentKind) { newKind in
                guard newKind != currentKind else { return }
                library.setCustomGuideCueKind(packId: pack.id, phraseKey: phraseKey, kind: newKind)
                engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
            }

            if let url = fileURL {
                Button(action: { library.previewAudioFile(at: url) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
            }

            Button(assignedFile == nil ? "Upload..." : "Replace...") {
                library.promptAssignGuidePhrase(packId: pack.id, phrase: label, cueKind: currentKind) { ok in
                    if ok {
                        DispatchQueue.main.async {
                            engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))

            if assignedFile != nil {
                Button(action: {
                    if library.setGuidePhraseFile(packId: pack.id, phrase: phraseKey, sourceURL: nil) {
                        engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func guideCueRow(pack: CustomGuidePack, label: String, phraseKey: String, isCountIn: Bool) -> some View {
        let assignedFile = pack.phraseFiles[phraseKey]
        let fileURL = pack.fileURL(forNormalizedPhrase: phraseKey)
        let currentKind = pack.cueKind(forNormalizedPhrase: phraseKey)
        
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 120, alignment: .leading)
            
            if let file = assignedFile {
                Text(file)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.35, green: 0.90, blue: 0.65))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Uses Fallback Voice")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if assignedFile != nil && !isCountIn {
                cueKindSelectorPill(selectedKind: currentKind) { newKind in
                    guard newKind != currentKind else { return }
                    library.setCustomGuideCueKind(packId: pack.id, phraseKey: phraseKey, kind: newKind)
                    engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                }
            }
            
            if let url = fileURL {
                Button(action: { library.previewAudioFile(at: url) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
            }
            
            Button(assignedFile == nil ? "Upload..." : "Replace...") {
                library.promptAssignGuidePhrase(packId: pack.id, phrase: label) { ok in
                    if ok {
                        DispatchQueue.main.async {
                            engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
            
            if assignedFile != nil {
                Button(action: {
                    if library.setGuidePhraseFile(packId: pack.id, phrase: phraseKey, sourceURL: nil) {
                        engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }
}
