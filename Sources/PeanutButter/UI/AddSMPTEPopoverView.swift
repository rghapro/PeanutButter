import SwiftUI

/// Popover for adding or editing a SMPTE cue, matching MultiTracks Playback SMPTE Popout Menu
public struct AddSMPTEPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let targetTime: TimeInterval
    var editingCue: SMPTECue? = nil
    let onDismiss: () -> Void
    
    @State private var currentTime: TimeInterval
    @State private var timelineText: String
    @State private var frameText: String
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var isEditingTimeStart: Bool = false
    @FocusState private var focusedField: FocusedField?
    
    private enum FocusedField: Hashable {
        case timeline
        case frame
    }
    
    public init(
        engine: MultitrackAudioEngine,
        targetTime: TimeInterval,
        editingCue: SMPTECue? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.engine = engine
        self.targetTime = targetTime
        self.editingCue = editingCue
        self.onDismiss = onDismiss
        
        let initialTime = max(0.0, editingCue?.time ?? targetTime)
        let defaultTime = engine.nextDefaultSMPTETimeStart()
        let initialH = editingCue?.timeStartHours ?? defaultTime.hours
        let initialM = editingCue?.timeStartMinutes ?? defaultTime.minutes
        let initialS = editingCue?.timeStartSeconds ?? 0
        
        self._currentTime = State(initialValue: initialTime)
        self._hours = State(initialValue: initialH)
        self._minutes = State(initialValue: initialM)
        self._seconds = State(initialValue: initialS)
        
        // Initial timeline and frame text
        let fps = engine.smpteFrameRate.framesPerSecond
        let initialFrames = Int(round(initialTime * fps))
        
        let totalMs = Int(round(initialTime * 1000.0))
        let mins = totalMs / 60000
        let secs = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        let initialTimeline = String(format: "%02d:%02d:%03d", mins, secs, ms)
        
        self._timelineText = State(initialValue: initialTimeline)
        self._frameText = State(initialValue: "\(initialFrames)")
    }
    
    private func formatTimeline(from time: TimeInterval) -> String {
        let totalMs = Int(round(max(0.0, time) * 1000.0))
        let mins = totalMs / 60000
        let secs = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%03d", mins, secs, ms)
    }
    
    private func parseTimeline(from text: String) -> TimeInterval? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        
        let parts = clean.split(separator: ":")
        if parts.count == 3 {
            guard let p0 = Double(parts[0]),
                  let p1 = Double(parts[1]),
                  let p2 = Double(parts[2]) else { return nil }
            let ms: Double
            if parts[2].count <= 3 {
                ms = p2 / 1000.0
            } else {
                ms = p2 / pow(10.0, Double(parts[2].count))
            }
            return max(0.0, p0 * 60.0 + p1 + ms)
        } else if parts.count == 2 {
            guard let p0 = Double(parts[0]),
                  let p1 = Double(parts[1]) else { return nil }
            return max(0.0, p0 * 60.0 + p1)
        } else if parts.count == 1 {
            if let sec = Double(clean) {
                return max(0.0, sec)
            }
        }
        return nil
    }
    
    private func formatFrames(from time: TimeInterval) -> String {
        let fps = engine.smpteFrameRate.framesPerSecond
        let frames = Int(round(max(0.0, time) * fps))
        return "\(frames)"
    }
    
    private func parseFrames(from text: String) -> TimeInterval? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let frames = Double(clean) else { return nil }
        let fps = engine.smpteFrameRate.framesPerSecond
        guard fps > 0 else { return nil }
        return max(0.0, frames / fps)
    }
    
    private var timeStartDisplay: String {
        return String(format: "%02dh %02dm", hours, minutes)
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
                
                Text("SMPTE")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(editingCue != nil ? "Update" : "Add") {
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
            
            VStack(alignment: .leading, spacing: 14) {
                // 1. Timeline Location Row (Editable)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Timeline Location")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        TextField("00:00:000", text: $timelineText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90, height: 22)
                            .padding(.horizontal, 6)
                            .background(Color(white: 0.16))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(focusedField == .timeline ? Color(red: 0.20, green: 0.65, blue: 0.95) : Color(white: 0.28), lineWidth: 1)
                            )
                            .focused($focusedField, equals: .timeline)
                            .onChange(of: timelineText) { newText in
                                if focusedField == .timeline {
                                    if let parsedTime = parseTimeline(from: newText) {
                                        currentTime = parsedTime
                                        frameText = formatFrames(from: parsedTime)
                                    }
                                }
                            }
                            .onSubmit {
                                if let parsedTime = parseTimeline(from: timelineText) {
                                    currentTime = parsedTime
                                    frameText = formatFrames(from: parsedTime)
                                }
                                timelineText = formatTimeline(from: currentTime)
                                focusedField = nil
                            }
                    }
                    Text("Timeline Location indicates where in the selected song SMPTE will begin being transmitted.")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.48))
                        .lineSpacing(2)
                }
                .padding(.top, 10)
                
                Divider()
                    .background(Color(white: 0.18))
                
                // 2. Frame Location Row (Editable)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Frame Location")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        TextField("0", text: $frameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72, height: 22)
                            .padding(.horizontal, 6)
                            .background(Color(white: 0.16))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(focusedField == .frame ? Color(red: 0.20, green: 0.65, blue: 0.95) : Color(white: 0.28), lineWidth: 1)
                            )
                            .focused($focusedField, equals: .frame)
                            .onChange(of: frameText) { newText in
                                if focusedField == .frame {
                                    if let parsedTime = parseFrames(from: newText) {
                                        currentTime = parsedTime
                                        timelineText = formatTimeline(from: parsedTime)
                                    }
                                }
                            }
                            .onSubmit {
                                if let parsedTime = parseFrames(from: frameText) {
                                    currentTime = parsedTime
                                    timelineText = formatTimeline(from: parsedTime)
                                }
                                frameText = formatFrames(from: currentTime)
                                focusedField = nil
                            }
                    }
                    Text("Frame Location indicates the specific frame number within the song in which SMPTE will begin being transmitted.")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.48))
                        .lineSpacing(2)
                }
                
                Divider()
                    .background(Color(white: 0.18))
                
                // 3. SMPTE Time Start Row
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isEditingTimeStart.toggle()
                        }
                    }) {
                        HStack {
                            Text("SMPTE Time Start")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            HStack(spacing: 4) {
                                Text(timeStartDisplay)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(Color(white: 0.70))
                                Image(systemName: isEditingTimeStart ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(white: 0.45))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Text("SMPTE Time Start indicates where in the SMPTE audio file your Timeline Location will begin from.")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.48))
                        .lineSpacing(2)
                    
                    if isEditingTimeStart {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                // Hours stepper
                                VStack(alignment: .center, spacing: 2) {
                                    Text("HOURS")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color(white: 0.50))
                                    HStack(spacing: 4) {
                                        Button(action: { hours = max(0, hours - 1) }) {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(white: 0.60))
                                        }
                                        .buttonStyle(.plain)
                                        Text(String(format: "%02dh", hours))
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 32)
                                        Button(action: { hours = min(23, hours + 1) }) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(white: 0.60))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(6)
                                .background(Color(white: 0.12))
                                .cornerRadius(4)
                                
                                // Minutes stepper
                                VStack(alignment: .center, spacing: 2) {
                                    Text("MINUTES")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color(white: 0.50))
                                    HStack(spacing: 4) {
                                        Button(action: { minutes = max(0, minutes - 1) }) {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(white: 0.60))
                                        }
                                        .buttonStyle(.plain)
                                        Text(String(format: "%02dm", minutes))
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 34)
                                        Button(action: { minutes = min(59, minutes + 1) }) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(white: 0.60))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(6)
                                .background(Color(white: 0.12))
                                .cornerRadius(4)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                
                // 4. Delete Cue option (when editing an existing placed cue)
                if editingCue != nil {
                    Divider()
                        .background(Color(white: 0.18))
                    
                    Button(action: {
                        engine.removeSMPTECue()
                        onDismiss()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text("Delete Cue")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundColor(Color(red: 0.95, green: 0.28, blue: 0.32))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 290)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.60), lineWidth: 1)
        )
        .onChange(of: focusedField) { newFocus in
            if newFocus == nil {
                timelineText = formatTimeline(from: currentTime)
                frameText = formatFrames(from: currentTime)
            }
        }
    }
    
    private func saveAndDismiss() {
        if focusedField == .timeline, let t = parseTimeline(from: timelineText) {
            currentTime = t
        } else if focusedField == .frame, let t = parseFrames(from: frameText) {
            currentTime = t
        }
        
        if editingCue != nil {
            engine.moveSMPTECue(to: currentTime, snapToGrid: false)
            engine.updateSMPTECue(hours: hours, minutes: minutes, seconds: seconds, frames: 0)
        } else {
            _ = engine.addSMPTECue(at: currentTime, snapToGrid: false)
            engine.updateSMPTECue(hours: hours, minutes: minutes, seconds: seconds, frames: 0)
        }
        onDismiss()
    }
}
