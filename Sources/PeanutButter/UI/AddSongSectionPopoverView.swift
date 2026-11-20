import SwiftUI

/// Popover matching MultiTracks Playback's "Add Song Section" popover menu.
/// Supports choosing from standard section presets or entering a custom section name.
/// Accurately anchors to either the playhead '+' button or per-section '+' buttons.
public struct AddSongSectionPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    let insertAfterIndex: Int?
    let atTime: TimeInterval?
    let onClose: () -> Void
    
    @State private var hoveredSectionId: String?
    @State private var customSectionName: String = ""
    @State private var isChoosingTimeSignature: Bool = false
    @State private var selectedNumerator: Int = 4
    @State private var selectedDenominator: Int = 4
    @State private var isChoosingTempo: Bool = false
    @State private var tempoIsRamp: Bool = false
    @State private var tempoTargetBPMText: String = "120"
    @State private var tempoTargetBPM: Double = 120.0
    @State private var rampSpanMode: TempoRampSpanMode = .barsBeats
    @State private var rampBars: Int = 2
    @State private var rampBeats: Double = 8.0
    @State private var rampUseBeatsUnit: Bool = false
    @State private var rampAudioSeconds: Double = 4.0
    @State private var rampLockBeatCount: Bool = true
    @State private var rampCurve: TempoCurveType = .easeIn
    @State private var activeSourceStartBPM: Double = 120.0
    
    public init(
        engine: MultitrackAudioEngine,
        insertAfterIndex: Int? = nil,
        atTime: TimeInterval? = nil,
        onClose: @escaping () -> Void
    ) {
        self.engine = engine
        self.insertAfterIndex = insertAfterIndex
        self.atTime = atTime
        self.onClose = onClose
    }
    
    private struct SectionPresetItem: Identifiable {
        let id: String
        let name: String
        let abbreviation: String
        let color: Color
        let sourceSection: SongSection?
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar with Cancel & Centered Title
            HStack {
                Button(action: onClose) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Add Song Section")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("Cancel")
                    .font(.system(size: 13))
                    .opacity(0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.11, green: 0.12, blue: 0.13))
            
            Divider()
                .background(Color(white: 0.22))
            
            if isChoosingTimeSignature {
                timeSignaturePickerView
            } else if isChoosingTempo {
                tempoPickerView
            } else {
                let isSongSectionsMode = insertAfterIndex == nil && !(engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .setlistSongMap)
                if isSongSectionsMode {
                    // Custom Section Name Input Field (Section Labeling mode only)
                    HStack(spacing: 6) {
                        TextField("Search or custom section...", text: $customSectionName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(white: 0.16))
                            .cornerRadius(4)
                            .onSubmit {
                                submitCustomSection()
                            }
                        
                        if !customSectionName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button(action: submitCustomSection) {
                                Text("Add")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.blue)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.09, green: 0.10, blue: 0.11))
                    
                    Divider()
                        .background(Color(white: 0.18))
                    
                    Button(action: {
                        let targetTime = atTime ?? engine.playbackOffsetSeconds
                        let srcTime = engine.audioTime(forArrangementTime: targetTime)
                        let curTS = engine.currentSong.timeSignature(atSourceTime: srcTime)
                        selectedNumerator = curTS.numerator
                        selectedDenominator = curTS.denominator
                        isChoosingTimeSignature = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "metronome")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))
                                .frame(width: 22)
                            Text("Change Time Signature...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                        .background(Color(white: 0.18))

                    Button(action: {
                        let targetTime = atTime ?? engine.playbackOffsetSeconds
                        let srcTime = engine.audioTime(forArrangementTime: targetTime)
                        let curTS = engine.currentSong.timeSignature(atSourceTime: srcTime)
                        let curBPM = engine.currentSong.evaluateBPM(atSourceTime: srcTime)
                        activeSourceStartBPM = curBPM
                        tempoTargetBPM = curBPM
                        tempoTargetBPMText = Song.formatBPM(curBPM, decimals: Song.tempoDecimalPrecision(for: curBPM))
                        rampBars = 2
                        rampBeats = Double(max(1, curTS.numerator) * 2)
                        isChoosingTempo = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 0.98, green: 0.68, blue: 0.18))
                                .frame(width: 22)
                            Text("Change Tempo...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.98, green: 0.68, blue: 0.18))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .background(Color(white: 0.18))
                }
                
                // Preset and Master Song Sections List
                ScrollView {
                    VStack(spacing: 1) {
                        let items = buildPresetItems()
                        ForEach(items) { item in
                            let isHovered = hoveredSectionId == item.id
                            
                            Button(action: {
                                applySelection(item: item)
                            }) {
                                HStack(spacing: 12) {
                                    // Section Abbreviation Circle Badge
                                    ZStack {
                                        Circle()
                                            .stroke(item.color, lineWidth: 1.4)
                                            .frame(width: 22, height: 22)
                                        
                                        Text(item.abbreviation)
                                            .font(.system(size: 8, weight: .black))
                                            .foregroundColor(.white)
                                    }
                                    
                                    // Section Full Name
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(isHovered ? Color(white: 0.18) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHover in
                                if isHover {
                                    hoveredSectionId = item.id
                                } else if hoveredSectionId == item.id {
                                    hoveredSectionId = nil
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
            
            Divider()
                .background(Color(white: 0.22))
            
            // Bottom Action: Reset to Default Song Map
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    engine.resetToDefaultSongMap()
                }
                onClose()
            }) {
                Text("Reset to Default Song Map")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.11, green: 0.12, blue: 0.13))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 266, height: 420)
        .background(Color(red: 0.11, green: 0.12, blue: 0.13))
        .cornerRadius(8)
    }
    
    private func buildPresetItems() -> [SectionPresetItem] {
        var results: [SectionPresetItem] = []
        var seenNames = Set<String>()
        
        let isSongMapAddRemove = (insertAfterIndex != nil) || (engine.isEditDrawerOpen && engine.selectedEditDrawerItem == .setlistSongMap)
        if isSongMapAddRemove {
            // Very first option in Setlist / Song Map: Click Section (right above Count In / song sections)
            let clickDummy = SongSection(name: "Click Section", abbreviation: "CLK", startTime: 0, duration: 8, isClickSection: true)
            results.append(SectionPresetItem(
                id: "std_Click Section",
                name: "Click Section",
                abbreviation: "CLK",
                color: clickDummy.color,
                sourceSection: nil
            ))

            // Sections actually in the song (excluding Click Sections)
            let sourceSections = !engine.currentSong.defaultSections.isEmpty
                ? engine.currentSong.defaultSections
                : engine.currentSong.sections

            for sec in sourceSections where !sec.effectiveIsClickSection {
                results.append(SectionPresetItem(
                    id: "song_\(sec.id)",
                    name: sec.name,
                    abbreviation: sec.abbreviation,
                    color: sec.color,
                    sourceSection: sec
                ))
            }
            return results
        }
        
        // 2b. Song Section Labeling menu: Canonical order first (never bunched by existing song order)
        let standardNames = [
            "Count Off", "Intro",
            "Verse", "Verse 1", "Verse 2", "Verse 3", "Verse 4", "Verse 5", "Verse 6",
            "Pre-Chorus", "Pre-Chorus 1", "Pre-Chorus 2", "Pre-Chorus 3", "Pre-Chorus 4",
            "Chorus", "Chorus 1", "Chorus 2", "Chorus 3", "Chorus 4",
            "Post-Chorus",
            "Bridge", "Bridge 1", "Bridge 2", "Bridge 3", "Bridge 4", "Bridge 5",
            "Turnaround", "Instrumental", "Interlude", "Passage", "Solo",
            "Vamp", "Tag", "Breakdown", "Refrain", "Acapella", "Rap", "Exhortation",
            "Outro", "Ending"
        ]
        
        for name in standardNames {
            let key = name.lowercased()
            if !seenNames.contains(key) {
                let abbrev = SongSection.abbreviation(for: name)
                let dummy = SongSection(name: name, abbreviation: abbrev, startTime: 0, duration: 8)
                results.append(SectionPresetItem(
                    id: "std_\(name)",
                    name: name,
                    abbreviation: abbrev,
                    color: dummy.color,
                    sourceSection: nil
                ))
                seenNames.insert(key)
            }
        }

        // Include user-uploaded custom guide cues marked as Song Section cues
        for name in customSamples.userCustomCueOptions(ofKind: .songSection, preferredVoice: engine.currentSong.guideVoice) {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty && !seenNames.contains(key) {
                let abbrev = SongSection.abbreviation(for: name)
                let dummy = SongSection(name: name, abbreviation: abbrev, startTime: 0, duration: 8)
                results.append(SectionPresetItem(
                    id: "guide_sec_\(name)",
                    name: name,
                    abbreviation: abbrev,
                    color: dummy.color,
                    sourceSection: nil
                ))
                seenNames.insert(key)
            }
        }

        // Append any custom section labels used in this song that aren't in the standard list
        let sourceSections = !engine.currentSong.defaultSections.isEmpty
            ? engine.currentSong.defaultSections
            : engine.currentSong.sections
        for sec in sourceSections where !sec.effectiveIsClickSection {
            let key = sec.name.trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty && !seenNames.contains(key) {
                results.append(SectionPresetItem(
                    id: "custom_\(sec.id)",
                    name: sec.name,
                    abbreviation: sec.abbreviation,
                    color: sec.color,
                    sourceSection: nil
                ))
                seenNames.insert(key)
            }
        }

        let query = customSectionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            return results.filter {
                $0.name.lowercased().contains(query) || $0.abbreviation.lowercased().contains(query)
            }
        }
        return results
    }
    
    private var timeSignaturePickerView: some View {
        let presets: [(Int, Int)] = [(2, 4), (3, 4), (4, 4), (5, 4), (6, 8), (7, 8), (9, 8), (12, 8)]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: { isChoosingTimeSignature = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Time Signature")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("Back")
                    .font(.system(size: 12))
                    .opacity(0)
            }
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets, id: \.0) { num, den in
                    let isSelected = selectedNumerator == num && selectedDenominator == den
                    Button(action: {
                        selectedNumerator = num
                        selectedDenominator = den
                    }) {
                        Text("\(num)/\(den)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color(red: 0.30, green: 0.88, blue: 0.98) : Color(white: 0.18))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Beats / Bar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                    Stepper("\(selectedNumerator)", value: $selectedNumerator, in: 1...16)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Beat Value")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                    Picker("", selection: $selectedDenominator) {
                        ForEach([2, 4, 8, 16], id: \.self) { d in
                            Text("\(d)").tag(d)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 68)
                }
            }
            
            Button(action: {
                let targetTime = atTime ?? engine.playbackOffsetSeconds
                engine.addTimeSignatureChange(atDisplayTime: targetTime, numerator: selectedNumerator, denominator: selectedDenominator)
                onClose()
            }) {
                Text("Apply \(selectedNumerator)/\(selectedDenominator)")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.30, green: 0.88, blue: 0.98))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var tempoPickerView: some View {
        let amber = Color(red: 0.98, green: 0.68, blue: 0.18)
        let targetTime = atTime ?? engine.playbackOffsetSeconds
        let srcTime = engine.audioTime(forArrangementTime: targetTime)
        let curTS = engine.currentSong.timeSignature(atSourceTime: srcTime)

        return ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Button(action: { isChoosingTempo = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Tempo")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("Back")
                    .font(.system(size: 12))
                    .opacity(0)
            }

            // Instant vs Ramp switcher
            HStack(spacing: 6) {
                Button(action: { tempoIsRamp = false }) {
                    Text("Instant")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(!tempoIsRamp ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(!tempoIsRamp ? amber : Color(white: 0.18))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button(action: { tempoIsRamp = true }) {
                    Text("Ramp (Rit / Acc)")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(tempoIsRamp ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(tempoIsRamp ? amber : Color(white: 0.18))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }

            // Active BPM -> Target BPM row
            HStack(spacing: 6) {
                if tempoIsRamp {
                    Text("From \(Song.formatBPM(activeSourceStartBPM, decimals: 1)) →")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                } else {
                    Text("Target BPM")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: 0.70))
                }
                Spacer()
                TextField("BPM", text: $tempoTargetBPMText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(amber)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.18))
                    .cornerRadius(4)
                    .onChange(of: tempoTargetBPMText) { newVal in
                        if let parsed = Double(newVal), parsed >= 20.0, parsed <= 300.0 {
                            tempoTargetBPM = parsed
                        }
                    }
                Stepper("", value: Binding(
                    get: { tempoTargetBPM },
                    set: { val in
                        let c = max(20.0, min(300.0, val))
                        tempoTargetBPM = c
                        tempoTargetBPMText = Song.formatBPM(c, decimals: Song.tempoDecimalPrecision(for: c))
                    }
                ), in: 20...300, step: 1)
                .labelsHidden()
            }

            if !tempoIsRamp {
                HStack(spacing: 6) {
                    Button("Half-Time (1/2x)") {
                        let next = max(20.0, (tempoTargetBPM * 0.5 * 10.0).rounded() / 10.0)
                        tempoTargetBPM = next
                        tempoTargetBPMText = Song.formatBPM(next, decimals: Song.tempoDecimalPrecision(for: next))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Double (2x)") {
                        let next = min(300.0, (tempoTargetBPM * 2.0 * 10.0).rounded() / 10.0)
                        tempoTargetBPM = next
                        tempoTargetBPMText = Song.formatBPM(next, decimals: Song.tempoDecimalPrecision(for: next))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                // Ramp span mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("Span")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))

                    HStack(spacing: 6) {
                        Button(action: {
                            rampSpanMode = .barsBeats
                            if rampCurve == .custom { rampCurve = .easeIn }
                        }) {
                            Text("Bars / Beats")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor((rampSpanMode == .barsBeats && rampCurve != .custom) ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background((rampSpanMode == .barsBeats && rampCurve != .custom) ? amber : Color(white: 0.18))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)

                        Button(action: { rampSpanMode = .audioAnchor }) {
                            Text("Audio End")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor((rampSpanMode == .audioAnchor || rampCurve == .custom) ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background((rampSpanMode == .audioAnchor || rampCurve == .custom) ? amber : Color(white: 0.18))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }

                    if rampSpanMode == .barsBeats && rampCurve != .custom {
                        HStack {
                            Button(rampUseBeatsUnit ? "Beats" : "Bars") {
                                rampUseBeatsUnit.toggle()
                                if rampUseBeatsUnit {
                                    rampBeats = Double(rampBars * max(1, curTS.numerator))
                                } else {
                                    rampBars = max(1, Int((rampBeats / Double(max(1, curTS.numerator))).rounded()))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()

                            if rampUseBeatsUnit {
                                Stepper("\(Int(rampBeats.rounded())) beats", value: $rampBeats, in: 1...64, step: 1)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            } else {
                                Stepper("\(rampBars) bar\(rampBars == 1 ? "" : "s")", value: $rampBars, in: 1...16, step: 1)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                        }
                    } else {
                        HStack {
                            Text(String(format: "Span %.1fs", rampAudioSeconds))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Spacer()
                            Stepper("", value: $rampAudioSeconds, in: 0.5...30.0, step: 0.5)
                                .labelsHidden()
                        }
                        if rampCurve != .custom {
                            Toggle("Lock Beats to Audio End", isOn: $rampLockBeatCount)
                                .toggleStyle(SwitchToggleStyle(tint: amber))
                                .font(.system(size: 10.5, weight: .medium))
                            if rampLockBeatCount {
                                HStack {
                                    Text("Beats")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    Spacer()
                                    Stepper("\(Int(rampBeats.rounded())) beats", value: $rampBeats, in: 1...64, step: 1)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                }
                            }
                        }
                    }
                }

                // Curve picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Curve")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            tempoCurveOptionButton(.linear, amber: amber)
                            tempoCurveOptionButton(.easeIn, amber: amber)
                            tempoCurveOptionButton(.easeOut, amber: amber)
                        }
                        HStack(spacing: 5) {
                            tempoCurveOptionButton(.sCurve, amber: amber)
                            tempoCurveOptionButton(.custom, amber: amber)
                        }
                    }
                }
            }

            Button(action: {
                let resolvedTarget = max(20.0, min(300.0, Double(tempoTargetBPMText) ?? tempoTargetBPM))
                if !tempoIsRamp {
                    engine.addInstantTempoChange(atDisplayTime: targetTime, bpm: resolvedTarget)
                } else {
                    let finalBeats = rampUseBeatsUnit ? rampBeats : Double(rampBars * max(1, curTS.numerator))
                    let effectiveMode: TempoRampSpanMode = (rampCurve == .custom) ? .audioAnchor : rampSpanMode
                    let endDisp: TimeInterval? = (effectiveMode == .audioAnchor) ? (targetTime + rampAudioSeconds) : nil
                    engine.addTempoRamp(
                        atDisplayTime: targetTime,
                        targetBPM: resolvedTarget,
                        spanMode: effectiveMode,
                        rampBeats: finalBeats,
                        endDisplayTime: endDisp,
                        lockBeatCount: rampLockBeatCount,
                        curve: rampCurve
                    )
                    if rampCurve == .custom {
                        engine.openTempoCurveEditor()
                    }
                }
                onClose()
            }) {
                let label = tempoIsRamp
                    ? "Apply \(Song.formatBPM(activeSourceStartBPM, decimals: 1)) → \(Song.formatBPM(tempoTargetBPM, decimals: 1)) BPM"
                    : "Apply \(Song.formatBPM(tempoTargetBPM, decimals: 1)) BPM"
                Text(label)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(amber)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color(white: 0.22))

            Button(action: {
                engine.openTempoCurveEditor()
                onClose()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11, weight: .bold))
                    Text("Draw Tempo Curve on Waveform")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .foregroundColor(amber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(amber.opacity(0.14))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tempoCurveOptionButton(_ curveOption: TempoCurveType, amber: Color) -> some View {
        let selected = rampCurve == curveOption
        return Button(action: {
            rampCurve = curveOption
            if curveOption == .custom {
                rampSpanMode = .audioAnchor
                rampLockBeatCount = false
            }
        }) {
            Text(curveOption.rawValue)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? amber : Color(white: 0.18))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func submitCustomSection() {
        let trimmed = customSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if let time = atTime {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.addSectionAt(time: time, name: trimmed)
            }
        } else if let idx = insertAfterIndex {
            let abbrev = SongSection.abbreviation(for: trimmed)
            let dummy = SongSection(name: trimmed, abbreviation: abbrev, startTime: 0, duration: 8)
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.insertSection(from: dummy, afterIndex: idx)
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.addSectionAtPlayhead(name: trimmed)
            }
        }
        onClose()
    }
    
    private func applySelection(item: SectionPresetItem) {
        if let time = atTime {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.addSectionAt(time: time, name: item.name)
            }
        } else if let idx = insertAfterIndex {
            if let src = item.sourceSection {
                withAnimation(.easeInOut(duration: 0.2)) {
                    engine.insertSection(from: src, afterIndex: idx)
                }
            } else if item.name.lowercased() == "click section" {
                withAnimation(.easeInOut(duration: 0.2)) {
                    engine.insertBlankClickSection(measures: 4, afterIndex: idx)
                }
            } else {
                let dummy = SongSection(name: item.name, abbreviation: item.abbreviation, startTime: 0, duration: 8)
                withAnimation(.easeInOut(duration: 0.2)) {
                    engine.insertSection(from: dummy, afterIndex: idx)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                engine.addSectionAtPlayhead(name: item.name)
            }
        }
        onClose()
    }
}
