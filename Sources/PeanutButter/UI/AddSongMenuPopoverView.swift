import SwiftUI
import AppKit

/// Popover menu opened from "+ Add a Song" matching MultiTracks Playback's navigation flow:
/// Root ("Add a Song": Songs, Click & Pad, Build Song From Stems, Import .pbsong)
/// -> SongLibraryBrowserView or the full Click & Pad configurator.
public struct AddSongMenuPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var padManager = PadLibraryManager.shared

    let onImportFromFinder: () -> Void
    let onBuildNewSong: () -> Void
    let onDismiss: () -> Void

    private enum Screen {
        case root
        case songs
        case clickAndPad
        case padPackPicker
        case keyPicker
    }

    private struct TimeSignatureOption: Identifiable, Hashable {
        let label: String
        let numerator: Int
        let denominator: Int
        var id: String { label }
    }

    private enum WheelColumn {
        case tempo
        case timeSig
    }

    private static let minBPM: Double = 20.0
    private static let maxBPM: Double = 300.0
    private static let timeSignatureOptions: [TimeSignatureOption] = [
        TimeSignatureOption(label: "2/4", numerator: 2, denominator: 4),
        TimeSignatureOption(label: "3/4", numerator: 3, denominator: 4),
        TimeSignatureOption(label: "4/4", numerator: 4, denominator: 4),
        TimeSignatureOption(label: "6/4", numerator: 6, denominator: 4),
        TimeSignatureOption(label: "6/8", numerator: 6, denominator: 8),
        TimeSignatureOption(label: "5/4", numerator: 5, denominator: 4),
        TimeSignatureOption(label: "12/8", numerator: 12, denominator: 8)
    ]
    private static let musicalKeys = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    @State private var screen: Screen = .root

    // Click & Pad form state
    @State private var nameText: String = ""
    @State private var selectedBPM: Double = 120.0
    @State private var tempoInputText: String = "120"
    @FocusState private var isTempoFieldFocused: Bool
    @State private var selectedTimeSigIndex: Int = 2 // "4/4"
    @State private var ambientPadEnabled: Bool = true
    @State private var selectedPadPackId: String = PadLibraryManager.shared.activePackId
    @State private var selectedKey: String = "C"
    @State private var infiniteLoop: Bool = true
    @State private var measuresText: String = "300"

    // Scroll-wheel support for the dual Tempo / Time Sig drum wheels
    @State private var hoveredColumn: WheelColumn? = nil
    @State private var scrollWheelMonitor: Any? = nil
    @State private var scrollWheelAccumulator: CGFloat = 0.0

    public init(
        engine: MultitrackAudioEngine,
        onImportFromFinder: @escaping () -> Void,
        onBuildNewSong: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.engine = engine
        self.onImportFromFinder = onImportFromFinder
        self.onBuildNewSong = onBuildNewSong
        self.onDismiss = onDismiss

        let activeKey = engine.currentSong.effectiveKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey: String = {
            guard !activeKey.isEmpty && activeKey != "—" else { return "C" }
            let norm = AudioSampleBank.normalizeKeyForPad(activeKey)
            let sharpToFlat: [String: String] = ["C#": "Db", "D#": "Eb", "F#": "Gb", "G#": "Ab", "A#": "Bb"]
            let candidate = sharpToFlat[norm] ?? norm
            return Self.musicalKeys.contains(candidate) ? candidate : "C"
        }()
        _selectedKey = State(initialValue: normalizedKey)
    }

    private var selectedPadPack: PadSoundPack {
        padManager.availablePacks.first(where: { $0.id == selectedPadPackId }) ?? padManager.activePack
    }

    private var selectedTimeSig: TimeSignatureOption {
        let clamped = max(0, min(Self.timeSignatureOptions.count - 1, selectedTimeSigIndex))
        return Self.timeSignatureOptions[clamped]
    }

    public var body: some View {
        Group {
            switch screen {
            case .root:
                rootMenuBody
            case .songs:
                SongLibraryBrowserView(
                    engine: engine,
                    onImportFromFinder: onImportFromFinder,
                    onBuildNewSong: onBuildNewSong,
                    onDismiss: onDismiss,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .root
                        }
                    }
                )
            case .clickAndPad:
                clickAndPadBody
            case .padPackPicker:
                padPackPickerBody
            case .keyPicker:
                keyPickerBody
            }
        }
        .frame(width: 330, height: 525)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .onChange(of: screen) { _, newScreen in
            if newScreen != .clickAndPad {
                isTempoFieldFocused = false
                removeScrollWheelMonitor()
            }
        }
        .onDisappear {
            isTempoFieldFocused = false
            removeScrollWheelMonitor()
        }
    }

    // MARK: - 1. Root Menu ("Add a Song")

    private var rootMenuBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Add a Song")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                HStack {
                    Button(action: onDismiss) {
                        Text("Cancel")
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    rootMenuRow(title: "Songs") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .songs
                        }
                    }

                    rowDivider

                    rootMenuRow(title: "Click & Pad") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .clickAndPad
                        }
                    }

                    rowDivider

                    rootMenuRow(title: "Build Song From Stems") {
                        onDismiss()
                        onBuildNewSong()
                    }

                    rowDivider

                    rootMenuRow(title: "Import .pbsong") {
                        onDismiss()
                        onImportFromFinder()
                    }
                }
                .background(cardBackground)
                .cornerRadius(10)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
        }
    }

    private func rootMenuRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.42))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2. Click & Pad Configurator

    private var clickAndPadBody: some View {
        VStack(spacing: 0) {
            // Header: < | Click & Pad | Add
            ZStack {
                Text("Click & Pad")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                HStack {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .root
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: handleAddClickAndPad) {
                        Text("Add")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    // Name Row
                    HStack(spacing: 10) {
                        Text("Name")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)

                        TextField("Click & Pad", text: $nameText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(cardBackground)
                    .cornerRadius(10)

                    // CLICK Type + Nudge + Dual Tempo & Time Sig Wheels
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("CLICK")
                        clickSectionCard
                    }

                    // PAD PLAYER Section
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("PAD PLAYER")

                        VStack(spacing: 0) {
                            HStack {
                                Text("Ambient Pad")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white)
                                Spacer()
                                Toggle("", isOn: $ambientPadEnabled)
                                    .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.68, blue: 0.98)))
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            rowDivider

                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    screen = .padPackPicker
                                }
                            }) {
                                HStack(spacing: 10) {
                                    padThumbnailView(for: selectedPadPack)

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(selectedPadPack.name)
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundColor(.white)
                                        Text(selectedPadPack.id == padManager.activePackId ? "Default Ambient Pad" : selectedPadPack.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(white: 0.52))
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(white: 0.42))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!ambientPadEnabled)
                            .opacity(ambientPadEnabled ? 1.0 : 0.42)

                            rowDivider

                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    screen = .keyPicker
                                }
                            }) {
                                HStack {
                                    Text("Key")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundColor(.white)

                                    Spacer()

                                    HStack(spacing: 5) {
                                        Text(selectedKey)
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundColor(Color(white: 0.65))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.42))
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!ambientPadEnabled)
                            .opacity(ambientPadEnabled ? 1.0 : 0.42)
                        }
                        .background(cardBackground)
                        .cornerRadius(10)

                        Text("Link an Ambient Pad to automatically play alongside this Click Track.")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(white: 0.50))
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                    }

                    // DURATION Section
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("DURATION")

                        VStack(spacing: 0) {
                            HStack {
                                Text("Infinite Loop")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white)
                                Spacer()
                                Toggle("", isOn: $infiniteLoop)
                                    .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.68, blue: 0.98)))
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            rowDivider

                            HStack {
                                Text("Measures")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white)
                                Spacer()
                                TextField("300", text: $measuresText)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 64)
                                    .onChange(of: measuresText) { _, newVal in
                                        let digits = newVal.filter { $0.isNumber }
                                        if digits != newVal {
                                            measuresText = digits
                                        }
                                    }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .disabled(infiniteLoop)
                            .opacity(infiniteLoop ? 0.42 : 1.0)
                        }
                        .background(cardBackground)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            installScrollWheelMonitor()
        }
    }

    // MARK: - CLICK Card (Typed BPM + Nudge + Dual Tempo & Time Signature Drum Wheel)

    private var clickSectionCard: some View {
        let clamped = Self.clampBPM(selectedBPM)
        let precision = Song.tempoDecimalPrecision(for: clamped)
        let nudgeButtons: [(Double, String)] = {
            switch precision {
            case 0: return [(-5.0, "-5"), (-1.0, "-1"), (1.0, "+1"), (5.0, "+5")]
            case 1: return [(-1.0, "-1"), (-0.1, "-0.1"), (0.1, "+0.1"), (1.0, "+1")]
            default: return [(-1.0, "-1"), (-0.01, "-0.01"), (0.01, "+0.01"), (1.0, "+1")]
            }
        }()

        return VStack(spacing: 0) {
            // Top Bar: Typeable BPM Field + Fine Nudge Buttons (matching Song Edit Tempo menu)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("120", text: $tempoInputText, onCommit: {
                        commitTypedTempoInput()
                    })
                    .focused($isTempoFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 68)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.21))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isTempoFieldFocused
                                    ? Color(red: 0.25, green: 0.75, blue: 1.0).opacity(0.75)
                                    : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    .onChange(of: isTempoFieldFocused) { _, focused in
                        if !focused {
                            commitTypedTempoInput()
                        }
                    }

                    Text("BPM")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    ForEach(nudgeButtons, id: \.1) { delta, label in
                        Button(action: {
                            isTempoFieldFocused = false
                            stepTempo(by: delta)
                        }) {
                            Text(label)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(Color(white: 0.22))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()
                .background(Color.white.opacity(0.08))

            dualDrumWheelView
        }
        .background(cardBackground)
        .cornerRadius(10)
    }

    private var dualDrumWheelView: some View {
        let clamped = Self.clampBPM(selectedBPM)
        let precision = Song.tempoDecimalPrecision(for: clamped)
        let stopsH = tempoWheelStopsHundredths(for: clamped)
        let selectedStopH = nearestTempoWheelStopHundredths(to: clamped, in: stopsH)

        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(white: 0.24))
                .frame(height: 30)
                .padding(.horizontal, 8)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                // Left Wheel: Scrollable BPM numbers ONLY (label "Tempo" is pinned stationary below)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 62)
                            ForEach(stopsH, id: \.self) { stopH in
                                let val = Double(stopH) / 100.0
                                let isSelected = (stopH == selectedStopH)
                                Button(action: {
                                    if isSelected {
                                        commitTypedTempoInput()
                                        isTempoFieldFocused = true
                                    } else {
                                        isTempoFieldFocused = false
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            selectedBPM = val
                                            tempoInputText = Self.formatBPM(val, minDecimals: precision)
                                        }
                                    }
                                }) {
                                    HStack(spacing: 0) {
                                        Text(Self.formatBPM(val, minDecimals: precision))
                                            .font(.system(size: isSelected ? 14.5 : 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                                            .foregroundColor(isSelected ? .white : Color(white: 0.55))
                                            .frame(width: 82, alignment: .trailing)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(stopH)
                            }
                            Color.clear.frame(height: 62)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onHover { hovering in
                        if hovering {
                            hoveredColumn = .tempo
                        } else if hoveredColumn == .tempo {
                            hoveredColumn = nil
                        }
                    }
                    .onAppear {
                        if let stop = selectedStopH {
                            DispatchQueue.main.async {
                                proxy.scrollTo(stop, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: selectedStopH) { _, newStopH in
                        if let stop = newStopH {
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(stop, anchor: .center)
                                }
                            }
                        }
                    }
                }

                // Right Wheel: Scrollable Time Signature ratios ONLY (label "Time Sig" is pinned stationary below)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 62)
                            ForEach(Array(Self.timeSignatureOptions.enumerated()), id: \.offset) { idx, opt in
                                let isSelected = (idx == selectedTimeSigIndex)
                                Button(action: {
                                    isTempoFieldFocused = false
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        selectedTimeSigIndex = idx
                                    }
                                }) {
                                    HStack(spacing: 0) {
                                        Text(opt.label)
                                            .font(.system(size: isSelected ? 14.5 : 13, weight: isSelected ? .bold : .regular, design: .monospaced))
                                            .foregroundColor(isSelected ? .white : Color(white: 0.55))
                                            .padding(.leading, 4)
                                            .frame(width: 42, alignment: .trailing)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(idx)
                            }
                            Color.clear.frame(height: 62)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onHover { hovering in
                        if hovering {
                            hoveredColumn = .timeSig
                        } else if hoveredColumn == .timeSig {
                            hoveredColumn = nil
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo(selectedTimeSigIndex, anchor: .center)
                        }
                    }
                    .onChange(of: selectedTimeSigIndex) { _, newIdx in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }

            // Stationary center labels pinned above the scrollable columns
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 88)
                    Text("Tempo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    Color.clear.frame(width: 48)
                    Text("Time Sig")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 30)
            .allowsHitTesting(false)
        }
        .frame(height: 154)
        .overlay(
            VStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.19).opacity(0.95), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
                Spacer()
                LinearGradient(colors: [.clear, Color(red: 0.16, green: 0.17, blue: 0.19).opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
            }
            .allowsHitTesting(false)
        )
    }

    // MARK: - 3. Pad Pack Picker Submenu

    private var padPackPickerBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Pad Sound")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                HStack {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .clickAndPad
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Click & Pad")
                                .font(.system(size: 13.5, weight: .regular))
                        }
                        .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(Array(padManager.availablePacks.enumerated()), id: \.element.id) { idx, pack in
                            let isSelected = (selectedPadPackId == pack.id)
                            Button(action: {
                                selectedPadPackId = pack.id
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    screen = .clickAndPad
                                }
                            }) {
                                HStack(spacing: 10) {
                                    padThumbnailView(for: pack)

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(pack.name)
                                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                            .foregroundColor(.white)
                                        Text(pack.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(white: 0.52))
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

                    Button(action: {
                        padManager.promptUploadPadPack { success in
                            if success {
                                selectedPadPackId = padManager.activePackId
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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - 4. Key Picker Submenu

    private var keyPickerBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Key")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                HStack {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            screen = .clickAndPad
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Click & Pad")
                                .font(.system(size: 13.5, weight: .regular))
                        }
                        .foregroundColor(Color(red: 0.25, green: 0.62, blue: 0.98))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            Divider()
                .background(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(Self.musicalKeys.enumerated()), id: \.offset) { idx, keyName in
                        let isSelected = (selectedKey == keyName)
                        Button(action: {
                            selectedKey = keyName
                            withAnimation(.easeInOut(duration: 0.14)) {
                                screen = .clickAndPad
                            }
                        }) {
                            HStack {
                                Text(keyName)
                                    .font(.system(size: 13.5, weight: isSelected ? .bold : .regular))
                                    .foregroundColor(.white)
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

                        if idx < Self.musicalKeys.count - 1 {
                            rowDivider
                        }
                    }
                }
                .background(cardBackground)
                .cornerRadius(10)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Tempo Helpers & Actions

    private static func formatBPM(_ bpm: Double, minDecimals: Int = 0) -> String {
        let rounded = (bpm * 100.0).rounded() / 100.0
        let decimals = max(minDecimals, Song.tempoDecimalPrecision(for: rounded))
        return Song.formatBPM(rounded, decimals: decimals)
    }

    private static func clampBPM(_ bpm: Double) -> Double {
        let rounded = (bpm * 100.0).rounded() / 100.0
        return min(maxBPM, max(minBPM, rounded))
    }

    private static func tempoWheelStepHundredths(for bpm: Double) -> Int {
        switch Song.tempoDecimalPrecision(for: bpm) {
        case 0: return 100
        case 1: return 10
        default: return 1
        }
    }

    private func tempoWheelStopsHundredths(for bpm: Double) -> [Int] {
        let clamped = Self.clampBPM(bpm)
        let precision = Song.tempoDecimalPrecision(for: clamped)
        let centerH = Int((clamped * 100.0).rounded())
        switch precision {
        case 0:
            return Array(stride(from: 2000, through: 30000, by: 100))
        case 1:
            let minH = max(2000, ((centerH - 3000) / 10) * 10)
            let maxH = min(30000, ((centerH + 3000) / 10) * 10)
            guard minH <= maxH else { return [centerH] }
            return Array(stride(from: minH, through: maxH, by: 10))
        default:
            let minH = max(2000, centerH - 500)
            let maxH = min(30000, centerH + 500)
            guard minH <= maxH else { return [centerH] }
            return Array(minH...maxH)
        }
    }

    private func nearestTempoWheelStopHundredths(to bpm: Double, in stops: [Int]) -> Int? {
        let targetH = Int((bpm * 100.0).rounded())
        return stops.min(by: { abs($0 - targetH) < abs($1 - targetH) })
    }

    private func commitTypedTempoInput() {
        let cleaned = tempoInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = Double(cleaned), raw.isFinite {
            let clamped = Self.clampBPM(raw)
            selectedBPM = clamped
            tempoInputText = Self.formatBPM(clamped)
        } else {
            tempoInputText = Self.formatBPM(selectedBPM)
        }
    }

    private func stepTempo(by delta: Double) {
        let next = Self.clampBPM(selectedBPM + delta)
        selectedBPM = next
        tempoInputText = Self.formatBPM(next)
    }

    private func handleAddClickAndPad() {
        commitTypedTempoInput()
        let ts = selectedTimeSig
        let parsedMeasures = max(1, min(999, Int(measuresText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 300))
        engine.addClickAndPadToSetlist(
            name: nameText,
            bpm: selectedBPM,
            timeSignatureNumerator: ts.numerator,
            timeSignatureDenominator: ts.denominator,
            ambientPadEnabled: ambientPadEnabled,
            padPresetId: selectedPadPackId,
            musicalKey: selectedKey,
            infiniteLoop: infiniteLoop,
            measures: parsedMeasures
        )
        onDismiss()
    }

    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard screen == .clickAndPad, let col = hoveredColumn else {
                return event
            }
            let dy = event.scrollingDeltaY
            guard abs(dy) > 0.01 else { return nil }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
            scrollWheelAccumulator += dy
            if abs(scrollWheelAccumulator) >= scale {
                let rawSteps = Int((scrollWheelAccumulator / scale).rounded(.towardZero))
                scrollWheelAccumulator -= CGFloat(rawSteps) * scale
                let directionInt = rawSteps > 0 ? -1 : 1
                switch col {
                case .tempo:
                    isTempoFieldFocused = false
                    let baseStep = Double(Self.tempoWheelStepHundredths(for: selectedBPM)) / 100.0
                    let multiplier: Double = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
                    let direction = Double(directionInt)
                    let steps = min(8, max(1, abs(rawSteps)))
                    stepTempo(by: direction * baseStep * multiplier * Double(steps))
                case .timeSig:
                    let next = selectedTimeSigIndex + (directionInt > 0 ? 1 : -1)
                    selectedTimeSigIndex = max(0, min(Self.timeSignatureOptions.count - 1, next))
                }
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
        hoveredColumn = nil
    }

    // MARK: - UI Styling Helpers

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
            .background(Color.white.opacity(0.08))
            .padding(.leading, 14)
    }

    private func padThumbnailView(for pack: PadSoundPack) -> some View {
        let colors: [Color] = {
            switch pack.id {
            case "soft":
                return [Color(red: 0.48, green: 0.36, blue: 0.72), Color(red: 0.18, green: 0.25, blue: 0.52)]
            case "simple":
                return [Color(red: 0.28, green: 0.58, blue: 0.80), Color(red: 0.42, green: 0.24, blue: 0.58)]
            default:
                return [Color(red: 0.25, green: 0.60, blue: 0.52), Color(red: 0.12, green: 0.24, blue: 0.38)]
            }
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}
