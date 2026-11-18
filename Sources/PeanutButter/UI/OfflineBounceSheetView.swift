import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct OfflineBounceSheetView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let lockMode: Bool
    let targetSong: Song?
    let embeddedInPopover: Bool
    let onDismiss: () -> Void

    public enum BounceMode: String, CaseIterable {
        case sessionReference = "Session Reference Track"
        case practiceTracks = "Song Practice Tracks"
    }

    @State private var mode: BounceMode
    @State private var includeClick: Bool = true
    @State private var includeGuide: Bool = true
    @State private var selectedFormat: BounceAudioFormat = .mp3
    @State private var selectedInstruments: Set<PracticeInstrument> = Set(PracticeInstrument.allCases)

    @State private var isBouncing: Bool = false
    @State private var progressValue: Double = 0.0
    @State private var statusText: String = ""
    @State private var errorText: String? = nil

    public init(
        engine: MultitrackAudioEngine,
        initialMode: BounceMode = .sessionReference,
        lockMode: Bool = false,
        targetSong: Song? = nil,
        embeddedInPopover: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.engine = engine
        self.lockMode = lockMode
        self.targetSong = targetSong
        self.embeddedInPopover = embeddedInPopover
        self.onDismiss = onDismiss
        self._mode = State(initialValue: initialMode)
    }

    private var effectiveSong: Song {
        targetSong ?? engine.currentSong
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: embeddedInPopover ? 12 : 14) {
            // Header
            if embeddedInPopover {
                HStack {
                    Button(action: onDismiss) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 14, weight: .regular))
                        }
                        .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBouncing)
                    
                    Spacer()
                    
                    Text("Export Reference")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text("Back")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.clear)
                }
            } else {
                HStack {
                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
                    Text(lockMode ? mode.rawValue : "Offline Bounce & Rehearsal Mixes")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBouncing)
                }
            }

            if !lockMode {
                Picker("", selection: $mode) {
                    ForEach(BounceMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isBouncing)
            }

            Divider().background(Color.white.opacity(0.12))

            if mode == .sessionReference {
                sessionReferenceSection
            } else {
                practiceTracksSection
            }

            // Common Options
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Include Click Track", isOn: $includeClick)
                    .toggleStyle(.checkbox)
                    .foregroundColor(.white)
                Toggle("Include Guide Track", isOn: $includeGuide)
                    .toggleStyle(.checkbox)
                    .foregroundColor(.white)

                HStack {
                    Text("Export Format:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.75))
                    Picker("", selection: $selectedFormat) {
                        ForEach(BounceAudioFormat.allCases) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
            }
            .font(.system(size: 12.5))
            .disabled(isBouncing)

            if isBouncing || !statusText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressValue, total: 1.0)
                    Text(isBouncing ? "Exporting..." : statusText)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.7))
                }
            }

            if let err = errorText {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.38))
            }

            Spacer()

            // Action Footer
            HStack {
                Button("Close") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isBouncing)

                Spacer()

                if mode == .sessionReference {
                    Button(action: startSessionReferenceBounce) {
                        Label("Bounce Reference Track...", systemImage: "arrow.down.doc")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBouncing || engine.currentSetlist.songs.isEmpty)
                } else {
                    Button(action: startPracticeTracksBounce) {
                        Label("Bounce Practice Tracks...", systemImage: "folder.badge.plus")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBouncing || selectedInstruments.isEmpty || effectiveSong.title.isEmpty)
                }
            }
        }
        .padding(embeddedInPopover ? 16 : (lockMode && mode == .sessionReference ? 14 : 18))
        .frame(
            width: embeddedInPopover ? 325 : (lockMode && mode == .sessionReference ? 340 : 420),
            height: embeddedInPopover ? 460 : (lockMode && mode == .sessionReference ? 285 : 410)
        )
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }

    private var sessionReferenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Continuous Service Reference Mix")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("Renders all \(engine.currentSetlist.songs.count) songs in \"\(engine.currentSetlist.name)\" faster than real-time. Songs set to \"Stay In Song\" or \"Cue Next Song\" automatically insert a 5-second gap before the next song.")
                .font(.system(size: 11.5))
                .foregroundColor(Color(white: 0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.16))
        .cornerRadius(6)
    }

    private var practiceTracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Song: \(effectiveSong.title.isEmpty ? "Untitled" : effectiveSong.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("Key of \(effectiveSong.musicalKey)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(Color(red: 0.28, green: 0.68, blue: 0.98))
            }

            Text("Target part 0 dB • Click/Guide 0 dB • Core instruments -10 dB • Keys/Synth/BG -20 dB")
                .font(.system(size: 10.5))
                .foregroundColor(Color(white: 0.60))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(PracticeInstrument.allCases) { instrument in
                    Toggle(instrument.rawValue, isOn: Binding(
                        get: { selectedInstruments.contains(instrument) },
                        set: { checked in
                            if checked {
                                selectedInstruments.insert(instrument)
                            } else {
                                selectedInstruments.remove(instrument)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                }
            }
            .disabled(isBouncing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.16))
        .cornerRadius(6)
    }

    private func startSessionReferenceBounce() {
        let panel = NSSavePanel()
        let baseName = engine.currentSetlist.name.isEmpty ? "Service" : engine.currentSetlist.name
        panel.nameFieldStringValue = "\(baseName) Reference.\(selectedFormat.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: selectedFormat.fileExtension) ?? .audio]
        panel.message = "Choose destination for Session Reference Track"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        errorText = nil
        isBouncing = true
        progressValue = 0.0
        statusText = "Preparing offline bounce..."
        engine.referenceBounceError = nil
        engine.isBouncingReference = true
        engine.referenceBounceProgress = 0.0
        engine.referenceBounceStatus = "Preparing offline bounce..."

        Task {
            do {
                try await OfflineBounceEngine.bounceSessionReference(
                    engine: engine,
                    includeClick: includeClick,
                    includeGuide: includeGuide,
                    format: selectedFormat,
                    outputURL: url,
                    progress: { p, msg in
                        Task { @MainActor in
                            self.progressValue = p
                            self.statusText = msg
                            engine.referenceBounceProgress = p
                            engine.referenceBounceStatus = msg
                        }
                    }
                )
                isBouncing = false
                engine.isBouncingReference = false
                engine.referenceBounceProgress = 1.0
                engine.referenceBounceStatus = "Reference Export Complete!"
                NSWorkspace.shared.activateFileViewerSelecting([url])
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !engine.isBouncingReference {
                    engine.referenceBounceStatus = ""
                }
            } catch {
                isBouncing = false
                errorText = error.localizedDescription
                engine.isBouncingReference = false
                engine.referenceBounceError = error.localizedDescription
                engine.referenceBounceStatus = "Export failed: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !engine.isBouncingReference {
                    engine.referenceBounceStatus = ""
                    engine.referenceBounceError = nil
                }
            }
        }
    }

    private func startPracticeTracksBounce() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Practice Tracks"
        panel.message = "Choose a folder for the song practice mixes"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let song = effectiveSong
        let trackBuffers = engine.tracksWithBuffersForBounce(song: song)
        let instruments = PracticeInstrument.allCases.filter { selectedInstruments.contains($0) }

        errorText = nil
        isBouncing = true
        progressValue = 0.0
        statusText = "Rendering practice tracks..."

        Task {
            do {
                let urls = try await OfflineBounceEngine.bouncePracticeTracks(
                    song: song,
                    trackBuffers: trackBuffers,
                    instruments: instruments,
                    includeClick: includeClick,
                    includeGuide: includeGuide,
                    format: selectedFormat,
                    outputDirectory: folderURL,
                    progress: { p, msg in
                        Task { @MainActor in
                            self.progressValue = p
                            self.statusText = msg
                        }
                    }
                )
                isBouncing = false
                if let first = urls.first {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
            } catch {
                isBouncing = false
                errorText = error.localizedDescription
            }
        }
    }
}
