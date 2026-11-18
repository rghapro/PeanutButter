import SwiftUI

/// Popover for adding or editing an Automation point, matching MultiTracks Playback Photo 1
public struct AddAutomationPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let targetTime: TimeInterval
    var editingPoint: AutomationPoint? = nil
    let onDismiss: () -> Void
    
    @State private var name: String
    @State private var transitionBeats: Int
    @State private var descriptionText: String
    
    public init(
        engine: MultitrackAudioEngine,
        targetTime: TimeInterval,
        editingPoint: AutomationPoint? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.engine = engine
        self.targetTime = targetTime
        self.editingPoint = editingPoint
        self.onDismiss = onDismiss
        
        let initialName = editingPoint?.name ?? "Automation \(engine.currentSong.automationPoints.count + 1)"
        let initialBeats = editingPoint?.transitionBeats ?? 0
        let initialDesc = editingPoint?.descriptionText ?? ""
        
        self._name = State(initialValue: initialName)
        self._transitionBeats = State(initialValue: initialBeats)
        self._descriptionText = State(initialValue: initialDesc)
    }
    
    private var maxBeats: Int {
        let num = max(1, engine.currentSong.timeSignatureNumerator)
        return 4 * num
    }
    
    private func labelForBeats(_ beats: Int) -> String {
        if beats == 0 {
            return "Instant"
        } else if beats == 1 {
            return "1 Beat"
        } else {
            let num = max(1, engine.currentSong.timeSignatureNumerator)
            if beats % num == 0 {
                let bars = beats / num
                return "\(beats) Beats (\(bars) Bar\(bars > 1 ? "s" : ""))"
            } else {
                return "\(beats) Beats"
            }
        }
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(red: 0.20, green: 0.65, blue: 0.95))
                
                Spacer()
                
                Text(editingPoint != nil ? "Edit Automation" : "Add Automation")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(editingPoint != nil ? "Done" : "Add") {
                    saveAndDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.20, green: 0.65, blue: 0.95))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            
            Divider()
                .background(Color(white: 0.22))
            
            // Name Row
            HStack {
                Text("Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer()
                
                TextField("Automation Name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(white: 0.85))
                    .frame(maxWidth: 160)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            Divider()
                .background(Color(white: 0.22))
            
            // Transition Length Row
            HStack {
                Text("Transition Length")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer()
                
                Menu {
                    Button("Instant") {
                        transitionBeats = 0
                    }
                    Divider()
                    ForEach(1...maxBeats, id: \.self) { b in
                        Button(labelForBeats(b)) {
                            transitionBeats = b
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(labelForBeats(transitionBeats))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Color(white: 0.70))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(white: 0.50))
                    }
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            Divider()
                .background(Color(white: 0.22))
            
            // Description Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                
                ZStack(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text("Enter Description Here")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color(white: 0.35))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }
                    
                    TextEditor(text: $descriptionText)
                        .font(.system(size: 11.5, weight: .regular))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(4)
                }
                .frame(height: 70)
                .background(Color(white: 0.10))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(white: 0.20), lineWidth: 0.8)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            // Delete Cue Option (visible once a cue has been placed / when editing an existing cue)
            if let ep = editingPoint {
                Divider()
                    .background(Color(white: 0.22))
                
                Button(action: {
                    engine.removeAutomationPoint(id: ep.id)
                    onDismiss()
                }) {
                    HStack {
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Delete Cue")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(Color(red: 0.98, green: 0.25, blue: 0.30))
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            Divider()
                .background(Color(white: 0.22))
            
            // Footer Link
            Button(action: {
                // Informational link or action
            }) {
                Text("Learn more about Automations.")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundColor(Color(red: 0.20, green: 0.65, blue: 0.95))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 290)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    
    private func saveAndDismiss() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Automation 1" : cleanName
        
        if let ep = editingPoint {
            engine.updateAutomationPoint(
                id: ep.id,
                name: finalName,
                transitionBeats: transitionBeats,
                descriptionText: descriptionText
            )
        } else {
            let _ = engine.addAutomationPoint(
                name: finalName,
                time: targetTime,
                transitionBeats: transitionBeats,
                descriptionText: descriptionText
            )
        }
        onDismiss()
    }
}
