import SwiftUI
import UniformTypeIdentifiers

/// Submenu for building and editing a song, its stems, key, tempo, and song sections
public struct SongBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject var libraryManager = LibraryBrowserManager.shared
    let isCreatingNewSong: Bool
    let previousSongIndex: Int?
    
    // Local editable song state
    @State private var songTitle: String
    @State private var artist: String
    @State private var bpm: Double
    @State private var musicalKey: String
    @State private var timeSigNum: Int
    @State private var timeSigDen: Int
    @State private var sections: [SongSection]
    @State private var artworkData: Data?
    @State private var librarySaveFeedback: String? = nil
    
    // Tap tempo helper
    @State private var tapTimes: [Date] = []
    
    // Audio file picker
    @State private var isAudioPickerPresented: Bool = false
    
    // Section editor selection
    @State private var selectedPreset: PresetSectionName = .intro
    @State private var customSectionName: String = ""
    @State private var newSectionMeasures: Int = 8
    
    private let availableKeys = [
        "C", "C#", "Db", "D", "Eb", "E", "F", "F#", "Gb", "G", "Ab", "A", "Bb", "B",
        "Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "Abm", "Am", "Bbm", "Bm"
    ]
    
    public init(engine: MultitrackAudioEngine, isCreatingNewSong: Bool = false, previousSongIndex: Int? = nil) {
        self.engine = engine
        self.isCreatingNewSong = isCreatingNewSong
        self.previousSongIndex = previousSongIndex
        let s = engine.currentSong
        self._songTitle = State(initialValue: s.title)
        self._artist = State(initialValue: s.artist)
        self._bpm = State(initialValue: s.bpm)
        self._musicalKey = State(initialValue: s.musicalKey == "—" ? "C" : s.musicalKey)
        self._timeSigNum = State(initialValue: s.timeSignatureNumerator)
        self._timeSigDen = State(initialValue: s.timeSignatureDenominator)
        self._sections = State(initialValue: s.sections)
        self._artworkData = State(initialValue: s.artworkData)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerBarView
            
            Divider()
                .background(Color(white: 0.2))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataCardView
                    sectionsCardView
                    stemsCardView
                }
                .padding(16)
            }
            .background(Color(white: 0.08))
        }
        .frame(width: 680, height: 600)
        .background(Color(white: 0.08))
        .fileImporter(
            isPresented: $isAudioPickerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            do {
                let urls = try result.get()
                if songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let firstURL = urls.first {
                    let folderName = firstURL.deletingLastPathComponent().lastPathComponent
                    let genericNames: Set<String> = ["stems", "multitracks", "audio", "tracks", "files", "downloads", "desktop", "documents"]
                    if !folderName.isEmpty && !genericNames.contains(folderName.lowercased()) {
                        songTitle = folderName
                    }
                }
                engine.addTracksConcurrently(from: urls)
                engine.ensureClickAndGuideTracksExist()
                engine.autoSortTracks()
                engine.recalculateAggregateWaveform(samplesCount: 4000)
                engine.updateMatrix()
            } catch {
                print("Failed to import audio: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerBarView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCreatingNewSong ? "BUILD NEW SONG" : "EDIT SONG")
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(.white)
                Text(isCreatingNewSong ? "Import audio stems and configure tempo, key, and sections for your new song" : "Configure stems, sections, tempo, and musical key")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 5) {
                if let feedback = librarySaveFeedback {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(feedback)
                            .foregroundColor(.green)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.14))
                    .cornerRadius(6)
                }

                if isCreatingNewSong {
                    Button(action: cancelNewSong) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 175)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.20))
                            .foregroundColor(Color(white: 0.85))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: saveToLocalLibraryFromBuilder) {
                    HStack(spacing: 5) {
                        Image(systemName: "internaldrive.fill")
                        Text("Save to Local Library")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .frame(width: 175)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.16, green: 0.28, blue: 0.20))
                    .foregroundColor(Color(red: 0.45, green: 0.92, blue: 0.62))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Save standalone .pbsong directly into your Local Song Library (~/Music/PeanutButter/Songs)")

                if libraryManager.isCloudConnected {
                    Button(action: saveToCloudLibraryFromBuilder) {
                        HStack(spacing: 5) {
                            Image(systemName: "icloud.and.arrow.up.fill")
                            Text("Save to Cloud")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .frame(width: 175)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.14, green: 0.24, blue: 0.34))
                        .foregroundColor(Color(red: 0.45, green: 0.82, blue: 1.0))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Save standalone .pbsong directly into your connected Cloud Song Library")
                }
                
                Button(action: saveAndDismiss) {
                    Text("Done")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 175)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
    }
    
    private var metadataCardView: some View {
        GroupBox(label: sectionHeader("SONG METADATA & KEYS")) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Artwork Thumbnail / Picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COVER PHOTO")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        
                        Button(action: {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.image, .png, .jpeg]
                            panel.message = "Choose Song Cover Photo"
                            panel.prompt = "Choose"
                            if panel.runModal() == .OK, let url = panel.url {
                                artworkData = try? Data(contentsOf: url)
                            }
                        }) {
                            ZStack {
                                if let data = artworkData, let img = NSImage(data: data) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipped()
                                        .cornerRadius(4)
                                } else {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(white: 0.16))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "photo.badge.plus").foregroundColor(Color(white: 0.55)))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Upload Song Artwork / Cover Photo")
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SONG TITLE")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        TextField("Song Title", text: $songTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARTIST")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        TextField("Artist", text: $artist)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KEY")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        
                        Picker("", selection: $musicalKey) {
                            ForEach(availableKeys, id: \.self) { key in
                                Text(key).tag(key)
                            }
                        }
                        .frame(width: 90)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("TEMPO (BPM)")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(Color(white: 0.5))
                            Spacer()
                            Text(String(format: "%.2f BPM", bpm))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                        
                        HStack(spacing: 6) {
                            TextField("BPM", value: $bpm, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                            
                            Button("-0.1") {
                                bpm = max(30.0, round((bpm - 0.1) * 100) / 100.0)
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 9, weight: .bold))
                            
                            Button("+0.1") {
                                bpm = min(300.0, round((bpm + 0.1) * 100) / 100.0)
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 9, weight: .bold))
                            
                            Button("TAP") {
                                handleTapTempo()
                            }
                            .font(.system(size: 10, weight: .black))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(white: 0.25))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                            .buttonStyle(.plain)
                            
                            Button(engine.isAnalyzingClickTempo ? "ANALYZING..." : "AUTO (CLICK)") {
                                engine.currentSong.timeSignatureNumerator = timeSigNum
                                engine.currentSong.timeSignatureDenominator = timeSigDen
                                engine.autoDetectTempoFromClick { success, _ in
                                    Task { @MainActor in
                                        if success {
                                            bpm = engine.currentSong.bpm
                                            sections = engine.currentSong.sections
                                        }
                                    }
                                }
                            }
                            .disabled(engine.isAnalyzingClickTempo || engine.tracks.isEmpty)
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.14, green: 0.48, blue: 0.68))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                            .buttonStyle(.plain)
                            .help("Analyze Click / Metronome stem to auto-set BPM and generate a dynamic beat grid (including ritardandos)")
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TIME SIG")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        
                        HStack(spacing: 4) {
                            HStack(spacing: 2) {
                                TextField("4", text: Binding(
                                    get: { "\(timeSigNum)" },
                                    set: { val in
                                        let digits = val.filter { $0.isNumber }
                                        if let num = Int(digits) {
                                            timeSigNum = max(1, min(16, num))
                                        }
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .frame(width: 24)
                                .padding(.vertical, 3)

                                Menu {
                                    ForEach([2, 3, 4, 6], id: \.self) { num in
                                        Button("\(num)") {
                                            timeSigNum = num
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(Color(white: 0.7))
                                        .frame(width: 16, height: 18)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .padding(.horizontal, 4)
                            .background(Color(white: 0.18))
                            .cornerRadius(5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(white: 0.28), lineWidth: 1)
                            )
                            
                            Text("/")
                                .foregroundColor(.gray)
                            
                            Picker("", selection: $timeSigDen) {
                                Text("4").tag(4)
                                Text("8").tag(8)
                            }
                            .frame(width: 50)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
    
    private var stemsCardView: some View {
        GroupBox(label: sectionHeader("STEMS & ROUTING (\(engine.tracks.count))")) {
            VStack(spacing: 8) {
                if engine.tracks.isEmpty {
                    Text("No stems loaded in this song.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                        .padding(.vertical, 8)
                } else {
                    ForEach(engine.tracks, id: \.id) { track in
                        HStack(spacing: 8) {
                            Image(systemName: track.role.iconName)
                                .foregroundColor(track.role.accentColor)
                                .frame(width: 20)
                            
                            Text(track.name)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 140, alignment: .leading)
                            
                            Picker("Routing", selection: Binding(
                                get: { track.routing },
                                set: { track.routing = $0 }
                            )) {
                                ForEach(OutputRoutingOption.allCases) { opt in
                                    Text(opt.rawValue).tag(opt)
                                }
                            }
                            .frame(width: 140)
                            
                            Toggle(isOn: Binding(
                                get: { track.includeInWaveform },
                                set: {
                                    track.includeInWaveform = $0
                                    engine.recalculateAggregateWaveform()
                                }
                            )) {
                                HStack(spacing: 3) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 9))
                                    Text("Waveform")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(track.includeInWaveform ? .cyan : Color(white: 0.4))
                            }
                            .toggleStyle(.checkbox)
                            .help("Include in aggregate waveform (exclude Click/Guide)")
                            
                            Spacer()
                            
                            Button(action: {
                                engine.removeTrack(id: track.id)
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.12))
                        .cornerRadius(4)
                    }
                }
                
                HStack {
                    Button(action: { isAudioPickerPresented = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Import Audio Stems (.wav, .m4a, .mp3)...")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    
                    Spacer()
                }
            }
            .padding(8)
        }
    }
    
    private var sectionsCardView: some View {
        GroupBox(label: sectionHeader("SONG MAP SECTIONS (\(sections.count))")) {
            VStack(spacing: 10) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, sec in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sec.color)
                            .frame(width: 10, height: 10)
                        
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                        
                        Text(sec.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 120, alignment: .leading)
                        
                        Text("\(sec.measureCount) measures")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        
                        Spacer()
                        
                        if index > 0 {
                            Button(action: { moveSection(from: index, to: index - 1) }) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if index < sections.count - 1 {
                            Button(action: { moveSection(from: index, to: index + 1) }) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button(action: {
                            sections.remove(at: index)
                            recalculateSectionTimes()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.12))
                    .cornerRadius(4)
                }
                
                Divider()
                    .background(Color(white: 0.2))
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ADD SECTION")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(white: 0.5))
                        
                        Spacer()
                        
                        Button(action: {
                            engine.autoLabelSectionsFromGuide { count, _ in
                                Task { @MainActor in
                                    if count > 0 {
                                        sections = engine.currentSong.sections
                                    }
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform.badge.mic")
                                Text(engine.isAutoLabelingSections ? "LISTENING TO GUIDE..." : "AUTO-LABEL FROM GUIDE")
                            }
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.14, green: 0.48, blue: 0.68))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.isAutoLabelingSections || engine.tracks.isEmpty)
                        .help("Listen to uploaded guide track to automatically detect and label song sections")
                    }
                    
                    HStack(spacing: 8) {
                        Picker("Preset", selection: $selectedPreset) {
                            ForEach(PresetSectionName.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .frame(width: 140)
                        
                        TextField("Or custom label...", text: $customSectionName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        
                        Stepper("\(newSectionMeasures) m", value: $newSectionMeasures, in: 1...64)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 100)
                        
                        Button(action: addSection) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
    }
    
    // MARK: - Actions
    
    private func addSection() {
        let name = customSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedPreset.rawValue
            : customSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let sec = SongSection(
            name: name,
            startTime: 0,
            duration: 0,
            measureCount: newSectionMeasures
        )
        sections.append(sec)
        customSectionName = ""
        recalculateSectionTimes()
    }
    
    private func moveSection(from: Int, to: Int) {
        let sec = sections.remove(at: from)
        sections.insert(sec, at: to)
        recalculateSectionTimes()
    }
    
    private func recalculateSectionTimes() {
        let srcGrid = engine.currentSong.sourceBeatGrid()
        let hasDynamicGrid = !srcGrid.isEmpty
        let gridDownbeats = hasDynamicGrid ? srcGrid.filter { $0.isDownbeat } : []
        let secPerBeat = (60.0 / max(20.0, bpm)) * (4.0 / Double(max(1, timeSigDen)))
        let secPerMeasure = secPerBeat * Double(timeSigNum)
        var currentTime: TimeInterval = 0.0
        var currentMeasure = 1
        
        var updated: [SongSection] = []
        for sec in sections {
            let dur: TimeInterval
            if !gridDownbeats.isEmpty && currentMeasure - 1 < gridDownbeats.count {
                let startDbIdx = currentMeasure - 1
                let endDbIdx = startDbIdx + sec.measureCount
                if endDbIdx < gridDownbeats.count {
                    dur = max(secPerBeat, gridDownbeats[endDbIdx].time - gridDownbeats[startDbIdx].time)
                } else {
                    let tailBPM = gridDownbeats[startDbIdx].instantaneousBPM > 20.0 ? gridDownbeats[startDbIdx].instantaneousBPM : max(20.0, bpm)
                    let tailBarDur = (60.0 / tailBPM) * (4.0 / Double(max(1, timeSigDen))) * Double(max(1, timeSigNum))
                    dur = Double(sec.measureCount) * tailBarDur
                }
            } else {
                dur = Double(sec.measureCount) * secPerMeasure
            }
            var newSec = sec
            newSec.startTime = currentTime
            newSec.duration = dur
            newSec.startMeasure = currentMeasure
            updated.append(newSec)
            currentTime += dur
            currentMeasure += sec.measureCount
        }
        self.sections = updated
    }
    
    private func handleTapTempo() {
        let now = Date()
        tapTimes.append(now)
        if tapTimes.count > 4 { tapTimes.removeFirst() }
        if tapTimes.count >= 2 {
            var diffs: [TimeInterval] = []
            for i in 1..<tapTimes.count {
                diffs.append(tapTimes[i].timeIntervalSince(tapTimes[i - 1]))
            }
            let avgDiff = diffs.reduce(0, +) / Double(diffs.count)
            if avgDiff > 0.2 && avgDiff < 2.0 {
                bpm = (60.0 / avgDiff).rounded()
                recalculateSectionTimes()
            }
        }
    }
    
    private func syncBuilderChangesToCurrentSong() -> String {
        recalculateSectionTimes()
        let finalTitle = songTitle.isEmpty ? "Untitled Song" : songTitle
        engine.currentSong.artworkData = artworkData
        engine.currentSong.timeSignatureNumerator = timeSigNum
        engine.currentSong.timeSignatureDenominator = timeSigDen
        engine.updateCurrentSong(
            title: finalTitle,
            artist: artist,
            bpm: bpm,
            key: musicalKey,
            sections: sections
        )
        return finalTitle
    }

    private func showLibraryFeedback(_ text: String) {
        withAnimation { librarySaveFeedback = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                if librarySaveFeedback == text {
                    librarySaveFeedback = nil
                }
            }
        }
    }

    private func saveToLocalLibraryFromBuilder() {
        _ = syncBuilderChangesToCurrentSong()
        do {
            _ = try libraryManager.saveSongToLocalLibrary(engine: engine, songIndex: engine.currentSongIndex)
            showLibraryFeedback("Saved to Local Library")
        } catch {
            showLibraryFeedback("Save failed")
        }
    }

    private func saveToCloudLibraryFromBuilder() {
        _ = syncBuilderChangesToCurrentSong()
        do {
            _ = try libraryManager.saveSongToCloudLibrary(engine: engine, songIndex: engine.currentSongIndex)
            showLibraryFeedback("Saved to Cloud Library")
        } catch {
            showLibraryFeedback("Cloud save failed")
        }
    }

    private func cancelNewSong() {
        if isCreatingNewSong && engine.currentSongIndex >= 0 && engine.currentSongIndex < engine.currentSetlist.songs.count {
            engine.removeSongFromSetlist(at: engine.currentSongIndex)
            if let prev = previousSongIndex, prev >= 0 && prev < engine.currentSetlist.songs.count {
                engine.selectSongInSetlist(at: prev)
            }
        }
        dismiss()
    }
    
    private func saveAndDismiss() {
        recalculateSectionTimes()
        let finalTitle = songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Song" : songTitle
        engine.currentSong.timeSignatureNumerator = timeSigNum
        engine.currentSong.timeSignatureDenominator = timeSigDen
        engine.currentSong.artworkData = artworkData
        
        if engine.currentSetlist.songs.isEmpty {
            let newSong = Song(
                title: finalTitle,
                artist: artist,
                bpm: bpm,
                timeSignatureNumerator: timeSigNum,
                timeSignatureDenominator: timeSigDen,
                musicalKey: musicalKey,
                sections: sections,
                timeSignatureChanges: engine.currentSong.timeSignatureChanges,
                beatGrid: engine.currentSong.beatGrid,
                startPadWithSong: engine.isGlobalStartPadWithSongEnabled,
                padPresetId: PadLibraryManager.shared.activePackId,
                artworkData: artworkData,
                clickSource: (engine.defaultClickSourcePreference == .uploaded && engine.uploadedClickBuffers[engine.currentSong.id] != nil) ? .uploaded : .generated,
                guideSource: (engine.defaultGuideSourcePreference == .uploaded && engine.uploadedGuideBuffers[engine.currentSong.id] != nil) ? .uploaded : .generated
            )
            engine.currentSetlist.songs.append(newSong)
            engine.currentSong = newSong
            engine.currentSongIndex = 0
            engine.markSessionChanged()
        } else {
            engine.updateCurrentSong(
                title: finalTitle,
                artist: artist,
                bpm: bpm,
                key: musicalKey,
                sections: sections
            )
            if engine.currentSongIndex >= 0 && engine.currentSongIndex < engine.currentSetlist.songs.count {
                engine.currentSetlist.songs[engine.currentSongIndex].artworkData = artworkData
            }
        }
        engine.ensureClickAndGuideTracksExist()
        if !isCreatingNewSong {
            _ = try? libraryManager.saveSongChangesToExistingLibraries(engine: engine, songIndex: engine.currentSongIndex)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.isEditDrawerOpen = true
                engine.isEditDrawerCollapsed = false
                engine.selectEditDrawerItem(.songSections)
            }
        }
        dismiss()
    }
    
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black))
            .foregroundColor(Color(white: 0.6))
    }
}
