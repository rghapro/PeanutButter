import SwiftUI
import CoreAudio

/// Busses & Physical Audio Routing Manager modeled directly on MultiTracks Playback
public struct BussesDrawerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var deviceManager = AudioDeviceManager.shared
    @ObservedObject private var midiEngine = MIDICueEngine.shared
    
    @State private var selectedTab: Int = 0 // 0: Busses & Outputs, 1: Stem Assignments, 2: MIDI Buses & Output Routing
    
    public init(engine: MultitrackAudioEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BUSSES & AUDIO ROUTING")
                            .font(.system(size: 15, weight: .black))
                            .foregroundColor(.white)
                        Text("Assign stems to sub-mix busses and route busses to physical audio interface outputs")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.6))
                    }
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.15, green: 0.55, blue: 0.95))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color(white: 0.12))
            
            Divider()
                .background(Color(white: 0.20))
            
            // Audio Interface Hardware Selection Bar
            HStack(spacing: 12) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.yellow)
                
                Text("AUDIO INTERFACE:")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(Color(white: 0.55))
                
                Picker("", selection: Binding(
                    get: { deviceManager.selectedDevice?.id ?? 0 },
                    set: { newID in
                        if let dev = deviceManager.availableDevices.first(where: { $0.id == newID }) {
                            engine.setOutputDevice(dev)
                        }
                    }
                )) {
                    ForEach(deviceManager.availableDevices) { dev in
                        Text("\(dev.name) (\(dev.outputChannelCount) Out)").tag(dev.id)
                    }
                }
                .frame(minWidth: 260)
                
                Button(action: { deviceManager.refreshDevices() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: 0.6))
                }
                .buttonStyle(.plain)
                .help("Rescan connected audio devices")
                
                Spacer()
                
                if let dev = deviceManager.selectedDevice {
                    Text("\(dev.outputChannelCount) OUTPUT CHANNELS DETECTED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.09))
            
            // MIDI Output Device Hardware Selection Bar
            HStack(spacing: 12) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.98, green: 0.56, blue: 0.14))
                
                Text("MIDI OUTPUT DEVICE:")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(Color(white: 0.55))
                
                Picker("", selection: $midiEngine.selectedDestinationID) {
                    ForEach(midiEngine.availableDestinations) { dest in
                        Text(dest.name).tag(dest.id)
                    }
                }
                .frame(minWidth: 260)
                
                Button(action: { midiEngine.refreshDestinations() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: 0.6))
                }
                .buttonStyle(.plain)
                .help("Rescan connected MIDI output devices")
                
                Spacer()
                
                let externalCount = midiEngine.availableDestinations.filter { !$0.isVirtual }.count
                Text("\(externalCount) CONNECTED MIDI \(externalCount == 1 ? "DEVICE" : "DEVICES")")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.98, green: 0.65, blue: 0.20))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.98, green: 0.56, blue: 0.14).opacity(0.14))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.08))
            
            // Segmented Picker for Views
            Picker("", selection: $selectedTab) {
                Text("Sub-Mix Busses (\(engine.busses.count))").tag(0)
                Text("Stem Track Routing (\(engine.tracks.count))").tag(1)
                Text("MIDI Buses (\(MIDIBus.allCases.count))").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(white: 0.11))
            
            Divider()
                .background(Color(white: 0.18))
            
            // Main Content Area
            ScrollView {
                if selectedTab == 0 {
                    bussesListView
                } else if selectedTab == 1 {
                    stemRoutingListView
                } else {
                    midiBusesListView
                }
            }
            .background(Color(white: 0.07))
        }
        .frame(minWidth: 720, minHeight: 520)
    }
    
    // MARK: - Sub-Mix Busses List View
    
    private var bussesListView: some View {
        VStack(spacing: 12) {
            ForEach(engine.busses) { bus in
                HStack(spacing: 12) {
                    // Color bar indicator
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bus.color)
                        .frame(width: 8, height: 42)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bus.name.uppercased())
                            .font(.system(size: 12, weight: .black))
                            .foregroundColor(.white)
                        
                        let assignedTracks = engine.tracks.filter { $0.assignedBusName == bus.name }
                        Text("\(assignedTracks.count) Stems Assigned: \(assignedTracks.map { $0.name }.joined(separator: ", "))")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(1)
                    }
                    .frame(width: 220, alignment: .leading)
                    
                    Spacer()
                    
                    // Solo / Mute Buttons
                    HStack(spacing: 4) {
                        Button(action: {
                            bus.isSoloed.toggle()
                            engine.updateMatrix()
                            engine.markSessionChanged()
                        }) {
                            Text("S")
                                .font(.system(size: 10, weight: .black))
                                .frame(width: 26, height: 26)
                                .background(bus.isSoloed ? Color.yellow : Color(white: 0.20))
                                .foregroundColor(bus.isSoloed ? .black : Color(white: 0.7))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            bus.isMuted.toggle()
                            engine.updateBusParameters(bus: bus)
                        }) {
                            Text("M")
                                .font(.system(size: 10, weight: .black))
                                .frame(width: 26, height: 26)
                                .background(bus.isMuted ? Color.red : Color(white: 0.20))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Bus Volume Slider
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { bus.volume },
                            set: {
                                bus.volume = $0
                                engine.updateBusParameters(bus: bus)
                            }
                        ), in: 0.0...1.0)
                            .accentColor(bus.color)
                            .frame(width: 110)
                        
                        Text(String(format: "%.0f%%", bus.volume * 100))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                            .frame(width: 34, alignment: .trailing)
                    }
                    
                    // Mono / Stereo Bus Mode Button
                    Button(action: {
                        let nextIsMono = !bus.isMono
                        let (stereo, mono) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
                        if nextIsMono {
                            if let freeMono = mono.first(where: { engine.reservedOutputLabel(for: $0, isMono: true) == nil }) {
                                bus.isMono = true
                                bus.physicalOutputChannel = freeMono
                            }
                        } else {
                            if let freeStereo = stereo.first(where: { engine.reservedOutputLabel(for: $0, isMono: false) == nil }) {
                                bus.isMono = false
                                bus.physicalOutputChannel = freeStereo
                            }
                        }
                        engine.updateMatrix()
                        engine.markSessionChanged()
                    }) {
                        Text(bus.isMono ? "MONO" : "STEREO")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(bus.isMono ? .cyan : Color(white: 0.70))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(bus.isMono ? Color.cyan.opacity(0.18) : Color(white: 0.18))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Bus Mode between Mono and Stereo")
                    
                    // Physical Hardware Output Assignment Menu (Matched dynamically to hardware outputs)
                    Menu {
                        let (stereoOuts, monoOuts) = deviceManager.availableOutputs(for: deviceManager.selectedDevice)
                        Section("Stereo Pairs") {
                            ForEach(stereoOuts, id: \.self) { outChan in
                                let reserved = engine.reservedOutputLabel(for: outChan, isMono: false)
                                Button(action: {
                                    bus.physicalOutputChannel = outChan
                                    bus.isMono = false
                                    engine.updateMatrix()
                                    engine.markSessionChanged()
                                }) {
                                    HStack {
                                        Text(reserved != nil ? "\(outChan) (\(reserved!))" : outChan)
                                        if bus.physicalOutputChannel == outChan && !bus.isMono {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .disabled(reserved != nil)
                            }
                        }
                        
                        Section("Mono Outputs") {
                            ForEach(monoOuts, id: \.self) { outChan in
                                let reserved = engine.reservedOutputLabel(for: outChan, isMono: true)
                                Button(action: {
                                    bus.physicalOutputChannel = outChan
                                    bus.isMono = true
                                    engine.updateMatrix()
                                    engine.markSessionChanged()
                                }) {
                                    HStack {
                                        Text(reserved != nil ? "\(outChan) (\(reserved!))" : outChan)
                                        if bus.physicalOutputChannel == outChan && bus.isMono {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .disabled(reserved != nil)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                            Text(bus.physicalOutputChannel)
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.18))
                        .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 120)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(6)
            }
        }
        .padding(16)
    }
    
    // MARK: - Stem Track Routing List View
    
    private var stemRoutingListView: some View {
        VStack(spacing: 8) {
            // Auto-assign helper button
            HStack {
                Text("ASSIGN STEMS TO SUB-MIX BUSSES")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(Color(white: 0.5))
                
                Spacer()
                
                Button(action: autoAssignStemsToBusses) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Auto-Route Stems by Name")
                    }
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.15))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            ForEach(engine.tracks, id: \.id) { track in
                HStack(spacing: 12) {
                    Image(systemName: track.role.iconName)
                        .font(.system(size: 12))
                        .foregroundColor(track.role.accentColor)
                        .frame(width: 20)
                    
                    Text(track.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 140, alignment: .leading)
                    
                    // Waveform inclusion indicator
                    Toggle(isOn: Binding(
                        get: { track.includeInWaveform },
                        set: {
                            track.includeInWaveform = $0
                            engine.recalculateAggregateWaveform()
                        }
                    )) {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                            Text("Waveform")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(track.includeInWaveform ? .cyan : Color(white: 0.4))
                    }
                    .toggleStyle(.checkbox)
                    .frame(width: 110)
                    
                    Spacer()
                    
                    // Assigned Bus Picker
                    Picker("Assigned Bus", selection: Binding(
                        get: { track.assignedBusName },
                        set: { newBus in
                            track.assignedBusName = newBus
                            engine.updateMatrix()
                            engine.markSessionChanged()
                            engine.objectWillChange.send()
                        }
                    )) {
                        ForEach(engine.busses) { bus in
                            HStack {
                                Circle().fill(bus.color).frame(width: 6, height: 6)
                                Text(bus.name)
                            }
                            .tag(bus.name)
                        }
                    }
                    .frame(width: 180)
                    
                    // Physical output preview for this stem
                    let bus = engine.busses.first(where: { $0.name == track.assignedBusName })
                    Text(bus?.physicalOutputChannel ?? "Out 1/2")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(white: 0.16))
                        .cornerRadius(3)
                        .frame(width: 70)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(white: 0.11))
                .cornerRadius(4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    
    // MARK: - MIDI Buses Routing List View
    
    private var midiBusesListView: some View {
        VStack(spacing: 12) {
            midiClockSectionView
            
            ForEach(MIDIBus.allCases) { bus in
                let isEnabled = midiEngine.isBusEnabled(bus)
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { midiEngine.isBusEnabled(bus) },
                        set: { midiEngine.setBusEnabled(bus, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bus.color.opacity(isEnabled ? 1.0 : 0.35))
                        .frame(width: 8, height: 38)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bus.rawValue.uppercased())
                            .font(.system(size: 12, weight: .black))
                            .foregroundColor(isEnabled ? .white : Color(white: 0.45))
                        Text(isEnabled ? "Virtual Port: PeanutButter - \(bus.rawValue)" : "Disabled (cues hidden & muted)")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .frame(width: 190, alignment: .leading)
                    
                    Spacer()
                    
                    // MIDI Channel Picker (1..16)
                    HStack(spacing: 6) {
                        Text("CHANNEL:")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(white: 0.55))
                        
                        Picker("", selection: Binding(
                            get: { midiEngine.busChannels[bus] ?? Int(bus.defaultChannel) },
                            set: { midiEngine.busChannels[bus] = $0 }
                        )) {
                            ForEach(1...16, id: \.self) { ch in
                                Text("Ch \(ch)").tag(ch)
                            }
                        }
                        .frame(width: 82)
                    }
                    
                    // Per-Bus Destination Override Picker
                    Picker("", selection: Binding(
                        get: { midiEngine.busDestinationOverrides[bus] ?? midiEngine.selectedDestinationID },
                        set: { newDest in
                            if newDest == midiEngine.selectedDestinationID {
                                midiEngine.busDestinationOverrides.removeValue(forKey: bus)
                            } else {
                                midiEngine.busDestinationOverrides[bus] = newDest
                            }
                        }
                    )) {
                        ForEach(midiEngine.availableDestinations) { dest in
                            Text(dest.name).tag(dest.id)
                        }
                    }
                    .frame(width: 220)
                    
                    Button("Test") {
                        let testCue = MIDICue(
                            time: 0,
                            bus: bus,
                            messageType: .note,
                            primaryValue: 19,
                            secondaryValue: 1,
                            disableLoop: false,
                            cueDescription: "Test \(bus.rawValue)"
                        )
                        midiEngine.fire(cue: testCue)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.16))
                    .cornerRadius(4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(6)
            }
        }
        .padding(16)
    }
    
    private var midiClockSectionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(midiEngine.isMIDIClockEnabled ? Color(red: 0.20, green: 0.75, blue: 0.95) : Color(white: 0.35))
                    .frame(width: 8, height: 38)
                
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(midiEngine.isMIDIClockEnabled ? Color(red: 0.20, green: 0.75, blue: 0.95) : Color(white: 0.5))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("MIDI CLOCK OUT")
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                let bpmDecimals = Song.tempoDecimalPrecision(for: engine.currentSong.bpm)
                Text("\(Song.formatBPM(engine.currentSong.bpm, decimals: bpmDecimals)) BPM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.14))
                    .cornerRadius(4)
                
                Toggle("", isOn: $midiEngine.isMIDIClockEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            
            Divider()
                .background(Color(white: 0.20))
            
            HStack(spacing: 10) {
                Text("CLOCK TARGET DEVICES (\(midiEngine.midiClockDestinationIDs.count) SELECTED)")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(Color(white: 0.55))
                
                Spacer()
                
                Button("Select All") {
                    midiEngine.selectAllMIDIClockDestinations()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(red: 0.20, green: 0.75, blue: 0.95))
                
                Button("Clear") {
                    midiEngine.clearMIDIClockDestinations()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                
                Button(action: { midiEngine.refreshDestinations() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: 0.6))
                }
                .buttonStyle(.plain)
                .help("Rescan connected MIDI output devices")
            }
            
            let selectable = midiEngine.clockSelectableDestinations
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                ForEach(selectable) { dest in
                    let isSelected = midiEngine.midiClockDestinationIDs.contains(dest.id)
                    Button(action: {
                        midiEngine.toggleMIDIClockDestination(dest.id)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isSelected ? Color(red: 0.20, green: 0.75, blue: 0.95) : Color(white: 0.45))
                            
                            Text(dest.name)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : Color(white: 0.75))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Spacer()
                            
                            Text(dest.isVirtual ? "VIRTUAL" : "MIDI")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(dest.isVirtual ? Color(red: 0.98, green: 0.65, blue: 0.20) : Color(white: 0.55))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(white: 0.18))
                                .cornerRadius(3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.14) : Color(white: 0.09))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color(red: 0.20, green: 0.75, blue: 0.95).opacity(0.45) : Color(white: 0.18), lineWidth: 1)
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(midiEngine.isMIDIClockEnabled ? 1.0 : 0.65)
            
            if midiEngine.isMIDIClockEnabled && midiEngine.midiClockDestinationIDs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Select one or more MIDI devices above to transmit MIDI Clock.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                }
            } else if selectable.filter({ !$0.isVirtual }).isEmpty {
                Text("No external MIDI interfaces detected (Virtual Out is still available).")
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.48))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(white: 0.12))
        .cornerRadius(6)
    }
    
    // MARK: - Auto-Assign Helper
    
    private func autoAssignStemsToBusses() {
        for track in engine.tracks {
            track.assignedBusName = StemTrack.autoAssignBus(for: track.name)
            let lower = track.name.lowercased()
            let isNonMusical = lower.contains("click") || lower.contains("guide") || lower.contains("cue") || lower.contains("tick") || lower.contains("metronome") || lower.contains("count")
            track.includeInWaveform = !isNonMusical
        }
        engine.recalculateAggregateWaveform()
        engine.updateMatrix()
    }
}
