import SwiftUI

/// Popover for adding a Directional Cue at the playhead
public struct AddDirectionalCuePopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let targetTime: TimeInterval
    let onDismiss: () -> Void
    
    @State private var cueLabel: String = "Build"
    
    public init(engine: MultitrackAudioEngine, targetTime: TimeInterval, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.targetTime = targetTime
        self.onDismiss = onDismiss
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
            }
            
            // Quick Preset Chips
            VStack(alignment: .leading, spacing: 6) {
                Text(isRitaSelected ? "RITA DYNAMIC CUE PRESETS" : "COMMON PRESETS")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                    ForEach(directionalPresets, id: \.self) { preset in
                        let isSelected = (cueLabel.lowercased() == preset.lowercased())
                        Button(action: {
                            cueLabel = preset
                        }) {
                            Text(preset)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                                .background(isSelected ? Color(red: 0.0, green: 0.65, blue: 0.85) : Color(white: 0.18))
                                .foregroundColor(isSelected ? .white : Color(white: 0.80))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Divider()
                .background(Color(white: 0.20))
            
            // Add Button
            Button(action: {
                let finalLabel = cueLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalLabel.isEmpty {
                    engine.addDirectionalCue(label: finalLabel, at: targetTime)
                }
                onDismiss()
            }) {
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
        .frame(width: 320)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
    }
    
    private var isRitaSelected: Bool {
        engine.currentSong.guideVoice == .rita || engine.currentSong.guideVoice.rawValue.lowercased() == "rita"
    }
    
    private var directionalPresets: [String] {
        if isRitaSelected {
            return [
                "Ad Lib", "All In", "Bass", "Big Ending", "Break", "Build",
                "Drums In", "Drums", "Hits", "Hold", "Key Change Down", "Key Change Up",
                "Keys", "Last Time", "Slowly Build", "Softly", "Swell", "Worship Freely"
            ]
        } else {
            return [
                "Build", "Breakdown", "Wash", "Drums In", "Softly",
                "Big", "All In", "Band Out", "Hits", "Hold", "A Cappella"
            ]
        }
    }
}

/// Popover for editing or deleting an existing Directional Cue
public struct EditDirectionalCuePopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let cue: DirectionalCue
    let onDismiss: () -> Void
    
    @State private var labelText: String
    
    public init(engine: MultitrackAudioEngine, cue: DirectionalCue, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.cue = cue
        self.onDismiss = onDismiss
        self._labelText = State(initialValue: cue.label)
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
            }
            
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
                Button(action: {
                    let finalLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalLabel.isEmpty {
                        engine.updateDirectionalCue(id: cue.id, label: finalLabel, time: cue.time)
                    }
                    onDismiss()
                }) {
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
        .frame(width: 250)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
    }
}
