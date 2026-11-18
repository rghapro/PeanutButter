import SwiftUI

/// Section editor popover modeled on MultiTracks Playback's Cloud Song Sections options
public struct CloudSectionEditorPopover: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let section: SongSection
    let onDismiss: () -> Void
    
    @State private var sectionName: String
    @State private var startMeasure: Int
    @State private var measureCount: Int
    
    public init(engine: MultitrackAudioEngine, section: SongSection, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.section = section
        self.onDismiss = onDismiss
        self._sectionName = State(initialValue: section.name)
        self._startMeasure = State(initialValue: section.startMeasure)
        self._measureCount = State(initialValue: section.measureCount)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Circle()
                    .fill(section.color)
                    .frame(width: 12, height: 12)
                
                Text("CLOUD SONG SECTION")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.5))
                }
                .buttonStyle(.plain)
            }
            
            Divider()
                .background(Color(white: 0.22))
            
            // 1. Quick Section Preset Chips (Count In, Intro, Verse, Chorus, Bridge, etc.)
            VStack(alignment: .leading, spacing: 6) {
                Text("SECTION TYPE")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                    ForEach(PresetSectionName.allCases) { preset in
                        let isSelected = sectionName == preset.rawValue
                        Button(action: {
                            sectionName = preset.rawValue
                            saveChanges()
                        }) {
                            Text(preset.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                                .background(isSelected ? Color.blue : Color(white: 0.16))
                                .foregroundColor(isSelected ? .white : Color(white: 0.8))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Custom Name Text Field
            VStack(alignment: .leading, spacing: 4) {
                Text("CUSTOM LABEL")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                TextField("Section Name...", text: $sectionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveChanges() }
            }
            
            // Measure Grid Controls
            HStack(spacing: 12) {
                // Start Measure
                VStack(alignment: .leading, spacing: 2) {
                    Text("START BAR")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(Color(white: 0.5))
                    
                    Stepper("Bar \(startMeasure)", value: $startMeasure, in: 1...500)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .onChange(of: startMeasure) { _, _ in saveChanges() }
                }
                .padding(6)
                .background(Color(white: 0.12))
                .cornerRadius(4)
                
                // Length in Measures
                VStack(alignment: .leading, spacing: 2) {
                    Text("LENGTH")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(Color(white: 0.5))
                    
                    Stepper("\(measureCount) Bars", value: $measureCount, in: 1...128)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .onChange(of: measureCount) { _, _ in saveChanges() }
                }
                .padding(6)
                .background(Color(white: 0.12))
                .cornerRadius(4)
            }
            
            Divider()
                .background(Color(white: 0.22))
            
            // Actions: Split at Playhead & Delete
            HStack {
                Button(action: {
                    let curBar = engine.transportPosition.bar
                    if curBar > section.startMeasure && curBar < (section.startMeasure + section.measureCount) {
                        engine.splitSection(atMeasure: curBar)
                        onDismiss()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                        Text("Split at Bar \(engine.transportPosition.bar)")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(white: 0.20))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(engine.transportPosition.bar <= section.startMeasure || engine.transportPosition.bar >= (section.startMeasure + section.measureCount))
                
                Spacer()
                
                Button(action: {
                    engine.deleteSection(id: section.id)
                    onDismiss()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(white: 0.10))
        .cornerRadius(8)
        .shadow(radius: 12)
    }
    
    private func saveChanges() {
        engine.updateSection(
            id: section.id,
            newName: sectionName,
            startMeasure: startMeasure,
            measureCount: measureCount
        )
    }
}
