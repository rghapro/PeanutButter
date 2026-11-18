import SwiftUI

/// Shared scrollable preset picker displaying user-classified Custom Directional Cues
/// followed by all included studio directional cues bundled with PeanutButter.
private struct DirectionalCuePresetPickerView: View {
    @Binding var selectedLabel: String
    let customOptions: [String]
    let includedOptions: [String]

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !customOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CUSTOM DIRECTIONAL CUES")
                            .font(.system(size: 8.5, weight: .black))
                            .foregroundColor(Color(red: 0.30, green: 0.88, blue: 0.98))

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(customOptions, id: \.self) { preset in
                                presetChip(preset)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("INCLUDED DIRECTIONAL CUES (\(includedOptions.count))")
                        .font(.system(size: 8.5, weight: .black))
                        .foregroundColor(Color(white: 0.5))

                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(includedOptions, id: \.self) { preset in
                            presetChip(preset)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: 235)
    }

    @ViewBuilder
    private func presetChip(_ preset: String) -> some View {
        let isSelected = (selectedLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == preset.lowercased())
        Button(action: {
            selectedLabel = preset
        }) {
            Text(preset)
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color(red: 0.0, green: 0.65, blue: 0.85) : Color(white: 0.18))
                .foregroundColor(isSelected ? .white : Color(white: 0.82))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

/// Popover for adding a Directional Cue at the playhead
public struct AddDirectionalCuePopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    let targetTime: TimeInterval
    let onDismiss: () -> Void
    
    @State private var cueLabel: String = "Build"
    
    public init(engine: MultitrackAudioEngine, targetTime: TimeInterval, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.targetTime = targetTime
        self.onDismiss = onDismiss
    }

    private func commitAdd() {
        let finalLabel = cueLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalLabel.isEmpty {
            engine.addDirectionalCue(label: finalLabel, at: targetTime)
        }
        onDismiss()
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("ADD DIRECTIONAL CUE")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(Color(red: 0.0, green: 0.90, blue: 1.0))
                
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
            
            // Custom Label Field
            VStack(alignment: .leading, spacing: 4) {
                Text("CUE PHRASE")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                TextField("Type what guide will say...", text: $cueLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(8)
                    .background(Color(white: 0.16))
                    .cornerRadius(5)
                    .onSubmit {
                        commitAdd()
                    }
            }
            
            // Quick Preset Chips (Custom Directional Cues + All Included Directional Cues)
            DirectionalCuePresetPickerView(
                selectedLabel: $cueLabel,
                customOptions: customSamples.userCustomCueOptions(
                    ofKind: .directional,
                    preferredVoice: engine.currentSong.guideVoice
                ),
                includedOptions: CustomSampleLibraryManager.includedDirectionalMenuOptions
            )
            
            Divider()
                .background(Color(white: 0.20))
            
            // Add Button
            Button(action: commitAdd) {
                Text("Add Directional Cue")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.0, green: 0.65, blue: 0.90))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
    }
}

/// Popover for editing or deleting an existing Directional Cue
public struct EditDirectionalCuePopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    let cue: DirectionalCue
    let onDismiss: () -> Void
    
    @State private var labelText: String
    
    public init(engine: MultitrackAudioEngine, cue: DirectionalCue, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.cue = cue
        self.onDismiss = onDismiss
        self._labelText = State(initialValue: cue.label)
    }

    private func commitUpdate() {
        let finalLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalLabel.isEmpty {
            engine.updateDirectionalCue(id: cue.id, label: finalLabel, time: cue.time)
        }
        onDismiss()
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("EDIT DIRECTIONAL CUE")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(Color(red: 0.0, green: 0.90, blue: 1.0))
                
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
            
            // Label Text Field
            VStack(alignment: .leading, spacing: 4) {
                Text("SPOKEN PHRASE")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                TextField("Phrase...", text: $labelText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(8)
                    .background(Color(white: 0.16))
                    .cornerRadius(5)
                    .onSubmit {
                        commitUpdate()
                    }
            }

            // Quick Preset Chips (Custom Directional Cues + All Included Directional Cues)
            DirectionalCuePresetPickerView(
                selectedLabel: $labelText,
                customOptions: customSamples.userCustomCueOptions(
                    ofKind: .directional,
                    preferredVoice: engine.currentSong.guideVoice
                ),
                includedOptions: CustomSampleLibraryManager.includedDirectionalMenuOptions
            )
            
            HStack(spacing: 8) {
                // Delete Button
                Button(action: {
                    engine.removeDirectionalCue(id: cue.id)
                    onDismiss()
                }) {
                    Text("Delete")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.85, green: 0.20, blue: 0.25))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Save Button
                Button(action: commitUpdate) {
                    Text("Update")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.0, green: 0.65, blue: 0.90))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
    }
}
