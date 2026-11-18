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
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var library = CustomSampleLibraryManager.shared
    let onClose: () -> Void
    
    @State private var selectedPackId: String?
    @State private var newPackName: String = ""
    @State private var editingPackName: String = ""
    @State private var cueSearchText: String = ""
    @State private var customPhraseText: String = ""
    
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
        var set: Set<String> = []
        for cat in CustomSampleLibraryManager.standardGuideCueCategories {
            for p in cat.phrases {
                set.insert(AudioSampleBank.shared.normalizePhraseKey(p))
            }
        }
        return set
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Guide Voice Samples")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("Import a folder or files named by cue (1.wav, Chorus 1.wav, All In.wav) or upload cues individually. Missing cues use Fallback Voice.")
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
                    Button(action: {
                        library.promptImportCustomGuidePack { imported in
                            if let pack = imported {
                                DispatchQueue.main.async {
                                    selectedPackId = pack.id
                                    editingPackName = pack.name
                                }
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
                                library.promptImportGuideFiles(intoPackId: pack.id) { count in
                                    if count > 0 {
                                        DispatchQueue.main.async {
                                            engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                                        }
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
                            TextField("Add custom cue phrase (e.g. Bridge Tag)...", text: $customPhraseText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("Upload Custom Cue...") {
                                let phrase = customPhraseText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !phrase.isEmpty else { return }
                                library.promptAssignGuidePhrase(packId: pack.id, phrase: phrase) { ok in
                                    if ok {
                                        DispatchQueue.main.async {
                                            customPhraseText = ""
                                            engine.refreshCurrentTracksAfterCustomSampleEdit(guidePackId: pack.id)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(customPhraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        
                        Divider().background(Color(white: 0.20))
                        
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                // Any user-added custom phrases not in the standard list
                                let extraKeys = pack.phraseFiles.keys
                                    .filter { !standardNormalizedKeys.contains($0) }
                                    .sorted()
                                    .filter { cueSearchText.isEmpty || $0.localizedCaseInsensitiveContains(cueSearchText) }
                                
                                if !extraKeys.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("CUSTOM PHRASES")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Color(white: 0.55))
                                        ForEach(extraKeys, id: \.self) { key in
                                            guideCueRow(pack: pack, label: key.capitalized, phraseKey: key)
                                        }
                                    }
                                }
                                
                                ForEach(CustomSampleLibraryManager.standardGuideCueCategories) { category in
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
                                                guideCueRow(pack: pack, label: phrase, phraseKey: norm)
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
        .frame(width: 640, height: 450)
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
    private func guideCueRow(pack: CustomGuidePack, label: String, phraseKey: String) -> some View {
        let assignedFile = pack.phraseFiles[phraseKey]
        let fileURL = pack.fileURL(forNormalizedPhrase: phraseKey)
        
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 130, alignment: .leading)
            
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
