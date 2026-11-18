import SwiftUI

/// Popout menu for editing a song section, matching MultiTracks Playback's Edit Song Section UI
public struct EditSongSectionPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let section: SongSection
    let onDismiss: () -> Void
    let onEnterTrimMode: () -> Void
    
    @State private var sectionName: String
    @State private var abbreviation: String
    @State private var playSectionGuideCue: Bool
    @State private var playSectionCountIn: Bool
    @State private var includeNumberInGuide: Bool
    @State private var isSelectingSectionType: Bool = false
    @State private var customSectionName: String = ""
    
    // Click Section configuration state (4.2)
    @State private var clickIsMirrored: Bool
    @State private var clickMeasures: Int
    @State private var clickSourceSectionId: UUID?
    
    private var availableSourceSections: [SongSection] {
        let base = !engine.currentSong.defaultSections.isEmpty ? engine.currentSong.defaultSections : engine.currentSong.sections
        return base.filter { !$0.effectiveIsClickSection && $0.id != section.id }
    }
    
    public init(
        engine: MultitrackAudioEngine,
        section: SongSection,
        onDismiss: @escaping () -> Void,
        onEnterTrimMode: @escaping () -> Void
    ) {
        self.engine = engine
        self.section = section
        self.onDismiss = onDismiss
        self.onEnterTrimMode = onEnterTrimMode
        self._sectionName = State(initialValue: section.name)
        self._abbreviation = State(initialValue: section.abbreviation)
        self._playSectionGuideCue = State(initialValue: section.playSectionGuideCue)
        self._playSectionCountIn = State(initialValue: section.playSectionCountIn)
        self._includeNumberInGuide = State(initialValue: section.includeNumberInGuide)
        self._customSectionName = State(initialValue: section.name)
        let isDefaultClick = section.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "click section"
        self._clickIsMirrored = State(initialValue: section.effectiveIsClickSection && !isDefaultClick)
        self._clickMeasures = State(initialValue: max(1, section.measureCount))
        let base = !engine.currentSong.defaultSections.isEmpty ? engine.currentSong.defaultSections : engine.currentSong.sections
        let nonClick = base.filter { !$0.effectiveIsClickSection && $0.id != section.id }
        let matched = nonClick.first(where: { section.name.lowercased().hasPrefix($0.name.lowercased()) })
        self._clickSourceSectionId = State(initialValue: matched?.id ?? nonClick.first?.id)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if isSelectingSectionType {
                sectionTypeSelectionView
            } else {
                mainEditView
            }
        }
        .frame(width: 310)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        .cornerRadius(12)
    }
    
    // MARK: - Main Edit View (Matching Image 1)
    
    private var mainEditView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Nav Header
            HStack {
                Button(action: onDismiss) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text(section.effectiveIsClickSection ? "Click Section" : "Edit Song Section")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: saveAndDismiss) {
                    Text("Update")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            
            // Group 1: Song Section Name (or Click Section Config) & Toggles
            VStack(spacing: 0) {
                if section.effectiveIsClickSection {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Click Section Mode")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.65))
                        
                        Picker("", selection: $clickIsMirrored) {
                            Text("Default Click").tag(false)
                            Text("Based on Section").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        
                        if !clickIsMirrored {
                            HStack {
                                Text("Length")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                                Button(action: { clickMeasures = max(1, clickMeasures - 1) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(Color(white: 0.65))
                                }
                                .buttonStyle(.plain)
                                Text("\(clickMeasures) \(clickMeasures == 1 ? "Bar" : "Bars")")
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(minWidth: 62)
                                Button(action: { clickMeasures = min(64, clickMeasures + 1) }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                                }
                                .buttonStyle(.plain)
                            }
                            
                            HStack(spacing: 5) {
                                ForEach([2, 4, 8, 16, 32], id: \.self) { bars in
                                    Button(action: { clickMeasures = bars }) {
                                        Text("\(bars)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(clickMeasures == bars ? .white : Color(white: 0.7))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                            .background(clickMeasures == bars ? Color(red: 0.25, green: 0.60, blue: 1.0) : Color(white: 0.14))
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            if availableSourceSections.isEmpty {
                                Text("No other song sections available to mirror.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            } else {
                                HStack {
                                    Text("Mirror Section")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Picker("", selection: $clickSourceSectionId) {
                                        ForEach(availableSourceSections) { src in
                                            Text("\(src.name) (\(src.measureCount) bars)").tag(Optional(src.id))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 165)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else {
                    // Section Picker Row
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSelectingSectionType = true
                        }
                    }) {
                        HStack {
                            Text("Song Section")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Text("\(sectionName)")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(Color(white: 0.65))
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                
                Divider()
                    .background(Color(white: 0.22))
                    .padding(.leading, 14)
                
                // Play Section Guide Cue Toggle
                HStack {
                    Text("Play Section Guide Cue")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Toggle("", isOn: $playSectionGuideCue)
                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.18, green: 0.55, blue: 1.0)))
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                
                Divider()
                    .background(Color(white: 0.22))
                    .padding(.leading, 14)
                
                // Play Section Count In Toggle
                HStack {
                    Text("Play Section Count In")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Toggle("", isOn: $playSectionCountIn)
                        .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.18, green: 0.55, blue: 1.0)))
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if !section.effectiveIsClickSection {
                    Divider()
                        .background(Color(white: 0.22))
                        .padding(.leading, 14)

                    // Include Number in Guide Toggle (e.g., "Verse 2" vs "Verse")
                    HStack {
                        Text("Include Number in Guide")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white)

                        Spacer()

                        Toggle("", isOn: $includeNumberInGuide)
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.18, green: 0.55, blue: 1.0)))
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(red: 0.18, green: 0.19, blue: 0.22))
            .cornerRadius(10)
            .padding(.horizontal, 14)
            
            // Subtitle text for Count In
            Text("For sections following a Count Off, the 'Play Section Count In' option will only apply when looping.")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color(white: 0.50))
                .lineSpacing(2)
                .padding(.horizontal, 18)
            
            // Section Header: TRIM
            Text("TRIM")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(white: 0.50))
                .padding(.horizontal, 18)
                .padding(.top, 4)
            
            // Group 2: Trim Section Button
            VStack(spacing: 0) {
                Button(action: {
                    onDismiss()
                    onEnterTrimMode()
                }) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trim Section")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            
                            Text("Trim measures from the song section to shorten it.")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(Color(white: 0.50))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color(red: 0.18, green: 0.19, blue: 0.22))
            .cornerRadius(10)
            .padding(.horizontal, 14)
            
            // Action Buttons: Remove Section Label / Reset Section / Reset All Sections
            VStack(spacing: 12) {
                if engine.currentSong.sections.first?.id != section.id {
                    Button(action: {
                        engine.removeSectionLabel(id: section.id)
                        onDismiss()
                    }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove Section Label")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.40))
                            Text("Merges this section into the section before it.")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(Color(white: 0.50))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: {
                    engine.resetSectionToDefault(sectionId: section.id)
                    onDismiss()
                }) {
                    Text("Reset Section to Default")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    engine.resetAllSectionsToDefault()
                    onDismiss()
                }) {
                    Text("Reset All Sections to Default")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }
    
    // MARK: - Subpage: Section Type Picker View
    
    private var sectionTypeSelectionView: some View {
        VStack(spacing: 10) {
            // Header with Back button
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSelectingSectionType = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("Back")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.60, blue: 1.0))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Song Section")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Invisible balancer
                Text("Back")
                    .font(.system(size: 13))
                    .opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            
            // Custom Name Field
            HStack {
                TextField("Custom Label...", text: $customSectionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Color(white: 0.18))
                    .cornerRadius(6)
                    .onSubmit {
                        if !customSectionName.trimmingCharacters(in: .whitespaces).isEmpty {
                            selectName(customSectionName)
                        }
                    }
                
                if !customSectionName.isEmpty && customSectionName != sectionName {
                    Button("Use") {
                        selectName(customSectionName)
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .cornerRadius(4)
                }
            }
            .padding(.horizontal, 14)
            
            // Preset Sections List
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(standardSectionNames, id: \.0) { item in
                        let name = item.0
                        let abbr = item.1
                        let isSelected = (sectionName.lowercased() == name.lowercased())
                        
                        Button(action: {
                            selectName(name, abbr: abbr)
                        }) {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(SongSection(name: name, startTime: 0, duration: 1).color)
                                        .frame(width: 22, height: 22)
                                    Text(abbr)
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundColor(.white)
                                }
                                
                                Text(name)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Color.blue)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 280)
        }
    }
    
    private func selectName(_ name: String, abbr: String? = nil) {
        sectionName = name
        abbreviation = abbr ?? SongSection.abbreviation(for: name)
        withAnimation(.easeInOut(duration: 0.18)) {
            isSelectingSectionType = false
        }
    }
    
    private func saveAndDismiss() {
        if section.effectiveIsClickSection {
            let basedOn = availableSourceSections.first(where: { $0.id == clickSourceSectionId })
            engine.updateClickSection(
                id: section.id,
                isMirrored: clickIsMirrored,
                measures: clickMeasures,
                basedOnSection: basedOn,
                playSectionGuideCue: playSectionGuideCue,
                playSectionCountIn: playSectionCountIn
            )
        } else {
            engine.updateSectionDetails(
                id: section.id,
                name: sectionName,
                abbreviation: abbreviation,
                playGuideCue: playSectionGuideCue,
                playCountIn: playSectionCountIn,
                includeNumberInGuide: includeNumberInGuide
            )
        }
        onDismiss()
    }
    
    private let standardSectionNames: [(String, String)] = [
        ("Count In", "Co"),
        ("Intro", "I"),
        ("Verse", "V"),
        ("Verse 1", "V1"),
        ("Verse 2", "V2"),
        ("Verse 3", "V3"),
        ("Verse 4", "V4"),
        ("Verse 5", "V5"),
        ("Verse 6", "V6"),
        ("Pre-Chorus", "Pr"),
        ("Pre-Chorus 1", "Pr1"),
        ("Pre-Chorus 2", "Pr2"),
        ("Pre-Chorus 3", "Pr3"),
        ("Pre-Chorus 4", "Pr4"),
        ("Chorus", "C"),
        ("Chorus 1", "C1"),
        ("Chorus 2", "C2"),
        ("Chorus 3", "C3"),
        ("Chorus 4", "C4"),
        ("Post-Chorus", "Po"),
        ("Bridge", "B"),
        ("Bridge 1", "B1"),
        ("Bridge 2", "B2"),
        ("Bridge 3", "B3"),
        ("Bridge 4", "B4"),
        ("Bridge 5", "B5"),
        ("Turnaround", "Ta"),
        ("Instrumental", "Ins"),
        ("Interlude", "Int"),
        ("Passage", "Pa"),
        ("Solo", "So"),
        ("Vamp", "Vp"),
        ("Tag", "Tg"),
        ("Breakdown", "Bd"),
        ("Refrain", "Rf"),
        ("Acapella", "Ac"),
        ("Rap", "Rp"),
        ("Exhortation", "Ex"),
        ("Outro", "O"),
        ("Ending", "E")
    ]
}
