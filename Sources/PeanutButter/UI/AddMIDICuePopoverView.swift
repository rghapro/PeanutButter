import SwiftUI

/// Popover matching MultiTracks Playback's "Add MIDI Cue" / "Edit MIDI Cue" menu.
/// Supports selecting among the 8 MIDI Buses (Lyrics, Lights 1, Lights 2, Patches 1, Patches 2, Guitar, Aux 1, Aux 2),
/// the 3 Message types (Note, Control Change, Program Change), and their corresponding dynamic parameters.
/// Allows both typing numerical values directly and selecting from a scrollable menu.
public struct AddMIDICuePopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let atTime: TimeInterval
    let existingCue: MIDICue?
    let onClose: () -> Void
    
    private enum PickerSubpage: Equatable {
        case none
        case midiBus
        case messageType
        case noteValue
        case noteVelocity
        case ccNumber
        case ccValue
        case pcValue
        
        var title: String {
            switch self {
            case .none: return ""
            case .midiBus: return "MIDI Bus"
            case .messageType: return "Message"
            case .noteValue: return "Value"
            case .noteVelocity: return "Velocity"
            case .ccNumber: return "CC#"
            case .ccValue: return "Value"
            case .pcValue: return "Value"
            }
        }
    }
    
    @State private var activeSubpage: PickerSubpage = .none
    @State private var selectedBus: MIDIBus
    @State private var selectedMessageType: MIDIMessageType
    @State private var primaryValue: Int
    @State private var secondaryValue: Int
    @State private var primaryText: String
    @State private var secondaryText: String
    @State private var subpageInputText: String = ""
    @State private var disableLoop: Bool
    @State private var cueDescription: String
    
    public init(
        engine: MultitrackAudioEngine,
        atTime: TimeInterval,
        existingCue: MIDICue? = nil,
        onClose: @escaping () -> Void
    ) {
        self.engine = engine
        self.atTime = atTime
        self.existingCue = existingCue
        self.onClose = onClose
        
        if let cue = existingCue {
            _selectedBus = State(initialValue: cue.bus)
            _selectedMessageType = State(initialValue: cue.messageType)
            _primaryValue = State(initialValue: cue.primaryValue)
            _secondaryValue = State(initialValue: cue.secondaryValue)
            _primaryText = State(initialValue: "\(cue.primaryValue)")
            _secondaryText = State(initialValue: "\(cue.secondaryValue)")
            _disableLoop = State(initialValue: cue.disableLoop)
            _cueDescription = State(initialValue: cue.cueDescription)
        } else {
            let defaultVel = engine.defaultVelocityForNewMIDICue(at: atTime)
            let sorted = engine.currentSong.midiCues.sorted { $0.time < $1.time }
            let prevCue = sorted.last(where: { $0.time <= atTime + 0.005 })
            let defaultBus = prevCue?.bus ?? .lyrics
            let defaultNote = (prevCue?.messageType == .note) ? (prevCue?.primaryValue ?? 19) : 19 // G-1 (19) default
            
            _selectedBus = State(initialValue: defaultBus)
            _selectedMessageType = State(initialValue: .note)
            _primaryValue = State(initialValue: defaultNote)
            _secondaryValue = State(initialValue: defaultVel)
            _primaryText = State(initialValue: "\(defaultNote)")
            _secondaryText = State(initialValue: "\(defaultVel)")
            _disableLoop = State(initialValue: false)
            _cueDescription = State(initialValue: "")
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            
            Divider()
                .background(Color(white: 0.18))
            
            if activeSubpage == .none {
                mainFormContent
            } else {
                subpagePickerContent
            }
        }
        .frame(width: 268)
        .background(Color(red: 0.04, green: 0.04, blue: 0.05))
        .cornerRadius(8)
    }
    
    // MARK: - Top Navigation Bar
    
    private var headerBar: some View {
        HStack {
            if activeSubpage == .none {
                Button(action: onClose) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    applySubpageTypedValueIfValid()
                    withAnimation(.easeInOut(duration: 0.14)) {
                        activeSubpage = .none
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Back")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            Text(activeSubpage == .none ? (existingCue == nil ? "Add MIDI Cue" : "Edit MIDI Cue") : activeSubpage.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            if activeSubpage == .none {
                Button(action: commitCue) {
                    Text(existingCue == nil ? "Add" : "Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                }
                .buttonStyle(.plain)
            } else {
                Text("Back")
                    .font(.system(size: 13))
                    .opacity(0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
    }
    
    // MARK: - Main Form Content
    
    private var mainFormContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. MIDI Bus Row
            formNavigationRow(
                label: "MIDI Bus",
                valueText: selectedBus.rawValue
            ) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    activeSubpage = .midiBus
                }
            }
            
            rowDivider
            
            // 2. Message Type Row
            formNavigationRow(
                label: "Message",
                valueText: selectedMessageType.rawValue
            ) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    activeSubpage = .messageType
                }
            }
            
            rowDivider
            
            // 3. Dynamic Characteristics based on Message Type
            switch selectedMessageType {
            case .note:
                // Note: Value (MIDI Note) and Velocity (supports direct typing AND menu selection)
                formNavigationRow(
                    label: "Value",
                    valueText: MIDICue.noteName(for: primaryValue)
                ) {
                    subpageInputText = "\(primaryValue)"
                    withAnimation(.easeInOut(duration: 0.14)) {
                        activeSubpage = .noteValue
                    }
                }
                
                rowDivider
                
                formNumericInputAndMenuRow(
                    label: "Velocity",
                    text: $secondaryText,
                    minVal: 1,
                    maxVal: 127,
                    onValueCommitted: { val in
                        secondaryValue = val
                    },
                    onOpenMenu: {
                        subpageInputText = "\(max(1, secondaryValue))"
                        withAnimation(.easeInOut(duration: 0.14)) {
                            activeSubpage = .noteVelocity
                        }
                    }
                )
                
            case .controlChange:
                // Control Change: CC# and Value (both support direct typing AND menu selection)
                formNumericInputAndMenuRow(
                    label: "CC#",
                    text: $primaryText,
                    minVal: 0,
                    maxVal: 127,
                    onValueCommitted: { val in
                        primaryValue = val
                    },
                    onOpenMenu: {
                        subpageInputText = "\(primaryValue)"
                        withAnimation(.easeInOut(duration: 0.14)) {
                            activeSubpage = .ccNumber
                        }
                    }
                )
                
                rowDivider
                
                formNumericInputAndMenuRow(
                    label: "Value",
                    text: $secondaryText,
                    minVal: 0,
                    maxVal: 127,
                    onValueCommitted: { val in
                        secondaryValue = val
                    },
                    onOpenMenu: {
                        subpageInputText = "\(secondaryValue)"
                        withAnimation(.easeInOut(duration: 0.14)) {
                            activeSubpage = .ccValue
                        }
                    }
                )
                
            case .programChange:
                // Program Change: Value (supports direct typing AND menu selection)
                formNumericInputAndMenuRow(
                    label: "Value",
                    text: $primaryText,
                    minVal: 0,
                    maxVal: 127,
                    onValueCommitted: { val in
                        primaryValue = val
                    },
                    onOpenMenu: {
                        subpageInputText = "\(primaryValue)"
                        withAnimation(.easeInOut(duration: 0.14)) {
                            activeSubpage = .pcValue
                        }
                    }
                )
            }
            
            rowDivider
            
            // 4. Disable Loop Toggle Row
            HStack {
                Text("Disable Loop")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Toggle("", isOn: $disableLoop)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            
            rowDivider
            
            // 5. Description Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                
                TextField("Enter Description Here", text: $cueDescription)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.vertical, 4)
                    .onSubmit {
                        commitCue()
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, existingCue == nil ? 28 : 14)
            
            // 6. Delete / Test Actions when editing an existing MIDI cue
            if let existing = existingCue {
                rowDivider
                
                HStack(spacing: 12) {
                    Button(action: {
                        syncInlineTypedFields()
                        let previewCue = MIDICue(
                            id: existing.id,
                            time: existing.time,
                            bus: selectedBus,
                            messageType: selectedMessageType,
                            primaryValue: primaryValue,
                            secondaryValue: secondaryValue,
                            disableLoop: disableLoop,
                            cueDescription: cueDescription
                        )
                        MIDICueEngine.shared.fire(cue: previewCue)
                    }) {
                        Text("Test Cue")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                        .frame(height: 18)
                        .background(Color(white: 0.20))
                    
                    Button(action: {
                        engine.removeMIDICue(id: existing.id)
                        onClose()
                    }) {
                        Text("Delete Cue")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.98, green: 0.26, blue: 0.32))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
            }
        }
    }
    
    // MARK: - Subpage Picker Content
    
    @ViewBuilder
    private var subpagePickerContent: some View {
        VStack(spacing: 0) {
            // Direct numeric input bar at top of numeric subpages
            if activeSubpage == .noteVelocity || activeSubpage == .ccNumber || activeSubpage == .ccValue || activeSubpage == .pcValue || activeSubpage == .noteValue {
                HStack(spacing: 8) {
                    Text(activeSubpage == .noteValue ? "Type Note # (0–127):" : "Type Value:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: 0.65))
                    
                    TextField("0–127", text: $subpageInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.14))
                        .cornerRadius(4)
                        .frame(width: 68)
                        .onSubmit {
                            applySubpageTypedValueIfValid()
                            withAnimation(.easeInOut(duration: 0.14)) {
                                activeSubpage = .none
                            }
                        }
                    
                    Button("Apply") {
                        applySubpageTypedValueIfValid()
                        withAnimation(.easeInOut(duration: 0.14)) {
                            activeSubpage = .none
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                    
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.08))
                
                Divider()
                    .background(Color(white: 0.18))
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        switch activeSubpage {
                        case .none:
                            EmptyView()
                            
                        case .midiBus:
                            ForEach(MIDIBus.allCases) { bus in
                                pickerOptionRow(
                                    id: bus.rawValue,
                                    title: bus.rawValue,
                                    subtitle: "Ch \(MIDICueEngine.shared.busChannels[bus] ?? Int(bus.defaultChannel))",
                                    isSelected: selectedBus == bus
                                ) {
                                    selectedBus = bus
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .messageType:
                            ForEach(MIDIMessageType.allCases) { msg in
                                pickerOptionRow(
                                    id: msg.rawValue,
                                    title: msg.rawValue,
                                    subtitle: nil,
                                    isSelected: selectedMessageType == msg
                                ) {
                                    if selectedMessageType != msg {
                                        selectedMessageType = msg
                                        if msg == .note && secondaryValue == 0 {
                                            secondaryValue = 1
                                            secondaryText = "1"
                                        }
                                    }
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .noteValue:
                            ForEach(0...127, id: \.self) { note in
                                pickerOptionRow(
                                    id: note,
                                    title: MIDICue.noteName(for: note),
                                    subtitle: "Note \(note)",
                                    isSelected: primaryValue == note
                                ) {
                                    primaryValue = note
                                    primaryText = "\(note)"
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .noteVelocity:
                            ForEach(1...127, id: \.self) { vel in
                                pickerOptionRow(
                                    id: vel,
                                    title: "\(vel)",
                                    subtitle: nil,
                                    isSelected: secondaryValue == vel
                                ) {
                                    secondaryValue = vel
                                    secondaryText = "\(vel)"
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .ccNumber:
                            ForEach(0...127, id: \.self) { cc in
                                pickerOptionRow(
                                    id: cc,
                                    title: "\(cc)",
                                    subtitle: "CC \(cc)",
                                    isSelected: primaryValue == cc
                                ) {
                                    primaryValue = cc
                                    primaryText = "\(cc)"
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .ccValue:
                            ForEach(0...127, id: \.self) { val in
                                pickerOptionRow(
                                    id: val,
                                    title: "\(val)",
                                    subtitle: nil,
                                    isSelected: secondaryValue == val
                                ) {
                                    secondaryValue = val
                                    secondaryText = "\(val)"
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                            
                        case .pcValue:
                            ForEach(0...127, id: \.self) { pc in
                                pickerOptionRow(
                                    id: pc,
                                    title: "\(pc)",
                                    subtitle: "Program \(pc)",
                                    isSelected: primaryValue == pc
                                ) {
                                    primaryValue = pc
                                    primaryText = "\(pc)"
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        activeSubpage = .none
                                    }
                                }
                                rowDivider
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .onAppear {
                    switch activeSubpage {
                    case .noteValue, .ccNumber, .pcValue:
                        proxy.scrollTo(primaryValue, anchor: .center)
                    case .noteVelocity, .ccValue:
                        proxy.scrollTo(max(1, secondaryValue), anchor: .center)
                    default:
                        break
                    }
                }
            }
        }
    }
    
    // MARK: - Row Helpers
    
    private var rowDivider: some View {
        Rectangle()
            .fill(Color(white: 0.14))
            .frame(height: 1)
            .padding(.leading, 14)
    }
    
    private func formNavigationRow(
        label: String,
        valueText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(valueText)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(Color(white: 0.62))
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.42))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    /// Hybrid row that lets the user type a numerical MIDI value directly OR click the chevron to pick from the list menu
    private func formNumericInputAndMenuRow(
        label: String,
        text: Binding<String>,
        minVal: Int,
        maxVal: Int,
        onValueCommitted: @escaping (Int) -> Void,
        onOpenMenu: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            TextField("\(minVal)–\(maxVal)", text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.78))
                .frame(width: 56)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(white: 0.11))
                .cornerRadius(4)
                .onChange(of: text.wrappedValue) { newText in
                    let digits = newText.filter { $0.isNumber }
                    if let parsed = Int(digits) {
                        let clamped = max(minVal, min(maxVal, parsed))
                        onValueCommitted(clamped)
                    }
                }
                .onSubmit {
                    commitCue()
                }
            
            Button(action: onOpenMenu) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.50))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose \(label) from list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    
    private func pickerOptionRow<ID: Hashable>(
        id: ID,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? Color(red: 0.15, green: 0.58, blue: 1.0) : .white)
                
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(white: 0.45))
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.58, blue: 1.0))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isSelected ? Color(white: 0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
    }
    
    private func applySubpageTypedValueIfValid() {
        let trimmed = subpageInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else { return }
        switch activeSubpage {
        case .noteValue, .ccNumber, .pcValue:
            let clamped = max(0, min(127, parsed))
            primaryValue = clamped
            primaryText = "\(clamped)"
        case .noteVelocity:
            let clamped = max(1, min(127, parsed))
            secondaryValue = clamped
            secondaryText = "\(clamped)"
        case .ccValue:
            let clamped = max(0, min(127, parsed))
            secondaryValue = clamped
            secondaryText = "\(clamped)"
        default:
            break
        }
    }
    
    private func syncInlineTypedFields() {
        if let p = Int(primaryText.filter({ $0.isNumber })) {
            primaryValue = max(0, min(127, p))
        }
        if let s = Int(secondaryText.filter({ $0.isNumber })) {
            let minS = (selectedMessageType == .note) ? 1 : 0
            secondaryValue = max(minS, min(127, s))
        }
    }
    
    private func commitCue() {
        syncInlineTypedFields()
        let finalSecondary: Int
        switch selectedMessageType {
        case .note:
            finalSecondary = max(1, min(127, secondaryValue))
        case .controlChange:
            finalSecondary = max(0, min(127, secondaryValue))
        case .programChange:
            finalSecondary = 0
        }
        
        if let existing = existingCue {
            let updated = MIDICue(
                id: existing.id,
                time: existing.time,
                bus: selectedBus,
                messageType: selectedMessageType,
                primaryValue: primaryValue,
                secondaryValue: finalSecondary,
                disableLoop: disableLoop,
                cueDescription: cueDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            engine.updateMIDICue(updated)
        } else {
            let newCue = MIDICue(
                time: atTime,
                bus: selectedBus,
                messageType: selectedMessageType,
                primaryValue: primaryValue,
                secondaryValue: finalSecondary,
                disableLoop: disableLoop,
                cueDescription: cueDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            engine.addMIDICue(newCue)
        }
        onClose()
    }
}
