import SwiftUI
import AppKit

/// Popover containing song and session settings, matching MultiTracks Playback Settings Menu
public struct SettingsMenuPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var remoteServer: RemoteControlServer
    @ObservedObject private var library = LibraryBrowserManager.shared
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    @ObservedObject private var padLibrary = PadLibraryManager.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @Binding var isPresented: Bool
    let onOpenBusses: () -> Void
    let onAddTracks: () -> Void
    let onOpenOfflineBounce: () -> Void
    let onStatus: (String) -> Void
    
    @State private var isZoomExpanded: Bool = false
    @State private var isCustomPreRoll: Bool = false
    @State private var customPreRollText: String = ""
    @State private var installedVoices: [InstalledVoiceInfo] = GuideAudioGenerator.shared.installedVoiceList().filter { !$0.isNovelty }
    @FocusState private var isRemotePasswordFocused: Bool
    
    public init(
        engine: MultitrackAudioEngine,
        isPresented: Binding<Bool>,
        onOpenBusses: @escaping () -> Void,
        onAddTracks: @escaping () -> Void,
        onOpenOfflineBounce: @escaping () -> Void = {},
        onStatus: @escaping (String) -> Void
    ) {
        self.engine = engine
        self._remoteServer = ObservedObject(wrappedValue: engine.remoteServer)
        self._isPresented = isPresented
        self.onOpenBusses = onOpenBusses
        self.onAddTracks = onAddTracks
        self.onOpenOfflineBounce = onOpenOfflineBounce
        self.onStatus = onStatus
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(Color(white: 0.60))
                Spacer()
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
                .background(Color(white: 0.20))
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    // 1. Waveform Zoom Submenu
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isZoomExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.70))
                                .frame(width: 20)
                            Text("Waveform Zoom (\(Int(engine.waveformZoomScale * 100))%)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Image(systemName: isZoomExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(white: 0.50))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if isZoomExpanded {
                        VStack(spacing: 6) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                                let scales: [(String, CGFloat)] = [
                                    ("50%", 0.5), ("75%", 0.75), ("100%", 1.0), ("125%", 1.25),
                                    ("150%", 1.5), ("200%", 2.0), ("250%", 2.5), ("300%", 3.0)
                                ]
                                ForEach(scales, id: \.0) { item in
                                    let isCur = abs(engine.waveformZoomScale - item.1) < 0.05
                                    Button(action: {
                                        engine.waveformZoomScale = item.1
                                        onStatus("Zoom: \(item.0)")
                                    }) {
                                        Text(item.0)
                                            .font(.system(size: 10, weight: isCur ? .bold : .medium))
                                            .foregroundColor(isCur ? .black : .white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                            .background(isCur ? Color.cyan : Color(white: 0.18))
                                            .cornerRadius(3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            
                            HStack(spacing: 8) {
                                Button("Zoom In (Cmd +)") {
                                    engine.waveformZoomScale = min(4.0, engine.waveformZoomScale + 0.25)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(white: 0.18))
                                .cornerRadius(3)
                                
                                Button("Zoom Out (Cmd -)") {
                                    engine.waveformZoomScale = max(0.4, engine.waveformZoomScale - 0.25)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(white: 0.18))
                                .cornerRadius(3)
                                
                                Spacer()
                                
                                Button("Reset (100%)") {
                                    engine.waveformZoomScale = 1.0
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(white: 0.18))
                                .cornerRadius(3)
                            }
                            .padding(.horizontal, 12)
                        }
                        .padding(.vertical, 6)
                        .background(Color(red: 0.08, green: 0.09, blue: 0.10))
                        .cornerRadius(4)
                        .padding(.horizontal, 8)
                    }
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 2. Auto-Sort & Stems
                    menuRow(icon: "arrow.up.arrow.down", title: "Auto-Sort Stems (MultiTracks Order)") {
                        isPresented = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            engine.autoSortTracks()
                            onStatus("Auto-sorted stems")
                        }
                    }
                    
                    menuRow(icon: "waveform.badge.magnifyingglass", title: engine.isAutoLabelingSections ? "Listening to Guide Track..." : "Auto-Label Song Sections (From Guide)") {
                        isPresented = false
                        if !engine.isAutoLabelingSections {
                            engine.autoLabelSectionsFromGuide { _, message in
                                Task { @MainActor in
                                    onStatus(message)
                                }
                            }
                        }
                    }
                    
                    menuRow(icon: "plus.circle", title: "Add Tracks to Song (Stem Audio Files)...") {
                        isPresented = false
                        onAddTracks()
                    }
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3. Audio & Routing
                    menuRow(icon: "slider.vertical.3", title: "Configure Buses, Routing, & MIDI...") {
                        isPresented = false
                        onOpenBusses()
                    }
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3B. Redundancy (Persistent 1kHz Sine Wave Pilot Tone)
                    let canUseRedundancy = engine.canEnableRedundancy
                    let redundancyChannels = engine.availableMonoChannelsForRedundancy()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isRedundancyEnabled ? Color(red: 0.20, green: 0.85, blue: 0.40) : Color(white: canUseRedundancy ? 0.70 : 0.35))
                                .frame(width: 20)
                            Text("Redundancy")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(canUseRedundancy ? .white : Color(white: 0.45))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isRedundancyEnabled },
                                set: { val in
                                    let ok = engine.setRedundancyEnabled(val)
                                    if val && !ok {
                                        onStatus("All interface outputs are already assigned")
                                    } else {
                                        onStatus(val ? "Redundancy 1kHz Tone: Enabled (\(engine.redundancyOutputChannel))" : "Redundancy Tone: Disabled")
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.85, blue: 0.40)))
                            .disabled(!canUseRedundancy)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                        if !canUseRedundancy {
                            Text("No free output available (all outputs assigned)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.50))
                                .padding(.leading, 44)
                                .padding(.trailing, 12)
                        }
                        
                        // Output Channel selector below toggle (grayed out when disabled)
                        HStack {
                            Text("Output Channel")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(engine.isRedundancyEnabled ? Color(white: 0.85) : Color(white: 0.45))
                                .padding(.leading, 32)
                            Spacer()
                            
                            let channels = redundancyChannels.isEmpty ? [engine.redundancyOutputChannel] : redundancyChannels
                            
                            Picker("", selection: Binding(
                                get: { engine.redundancyOutputChannel },
                                set: { val in
                                    engine.redundancyOutputChannel = val
                                    engine.updateRedundancyState()
                                    onStatus("Redundancy Output: \(val)")
                                }
                            )) {
                                ForEach(channels, id: \.self) { ch in
                                    Text(ch).tag(ch)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .disabled(!engine.isRedundancyEnabled || redundancyChannels.isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .opacity(engine.isRedundancyEnabled ? 1.0 : 0.35)
                    }
                    .background(engine.isRedundancyEnabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3C. SMPTE Timecode Output
                    let canUseSMPTE = engine.canEnableSMPTE
                    let smpteChannels = engine.availableMonoChannelsForSMPTE()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isSMPTEEnabled ? Color(red: 0.25, green: 0.88, blue: 0.45) : Color(white: canUseSMPTE ? 0.70 : 0.35))
                                .frame(width: 20)
                            Text("SMPTE")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(canUseSMPTE ? .white : Color(white: 0.45))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isSMPTEEnabled },
                                set: { val in
                                    let ok = engine.setSMPTEEnabled(val)
                                    if val && !ok {
                                        onStatus("All interface outputs are already assigned")
                                    } else {
                                        onStatus(val ? "SMPTE Output: Enabled (\(engine.smpteOutputChannel))" : "SMPTE Output: Disabled")
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.88, blue: 0.45)))
                            .disabled(!canUseSMPTE)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                        if !canUseSMPTE {
                            Text("No free output available (all outputs assigned)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.50))
                                .padding(.leading, 44)
                                .padding(.trailing, 12)
                        }
                        
                        // Frame Rate options below toggle
                        HStack {
                            Text("Frame Rate")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(engine.isSMPTEEnabled ? Color(white: 0.85) : Color(white: 0.45))
                                .padding(.leading, 32)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { engine.smpteFrameRate },
                                set: { val in
                                    engine.smpteFrameRate = val
                                    engine.updateSMPTEState()
                                    onStatus("SMPTE Frame Rate: \(val.rawValue)")
                                }
                            )) {
                                ForEach(SMPTEFrameRate.allCases) { rate in
                                    Text(rate.rawValue).tag(rate)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                            .disabled(!engine.isSMPTEEnabled)
                        }
                        .padding(.horizontal, 12)
                        .opacity(engine.isSMPTEEnabled ? 1.0 : 0.35)
                        
                        // Output Channel below frame rate
                        HStack {
                            Text("Output Channel")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(engine.isSMPTEEnabled ? Color(white: 0.85) : Color(white: 0.45))
                                .padding(.leading, 32)
                            Spacer()
                            
                            let channels = smpteChannels.isEmpty ? [engine.smpteOutputChannel] : smpteChannels
                            
                            Picker("", selection: Binding(
                                get: { engine.smpteOutputChannel },
                                set: { val in
                                    engine.smpteOutputChannel = val
                                    engine.updateSMPTEState()
                                    onStatus("SMPTE Output: \(val)")
                                }
                            )) {
                                ForEach(channels, id: \.self) { ch in
                                    Text(ch).tag(ch)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .disabled(!engine.isSMPTEEnabled || smpteChannels.isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .opacity(engine.isSMPTEEnabled ? 1.0 : 0.35)
                    }
                    .background(engine.isSMPTEEnabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3D. Song Section Pre-Roll
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "forward.frame")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isSongSectionPreRollEnabled ? Color(red: 0.20, green: 0.65, blue: 0.95) : Color(white: 0.70))
                                .frame(width: 20)
                            Text("Song Section Pre-Roll")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isSongSectionPreRollEnabled },
                                set: { val in
                                    engine.isSongSectionPreRollEnabled = val
                                    engine.updatePreRollSettings()
                                    onStatus(val ? "Song Section Pre-Roll: Enabled" : "Song Section Pre-Roll: Disabled")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.65, blue: 0.95)))
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        
                        // Section Pre-Roll Length options below toggle (1, 2, 4, 8, Custom)
                        HStack {
                            Text("Section Pre-Roll Length")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(engine.isSongSectionPreRollEnabled ? Color(white: 0.85) : Color(white: 0.45))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { isCustomPreRoll ? -1 : engine.sectionPreRollLengthBars },
                                set: { val in
                                    if val == -1 {
                                        isCustomPreRoll = true
                                    } else {
                                        isCustomPreRoll = false
                                        engine.sectionPreRollLengthBars = val
                                        engine.updatePreRollSettings()
                                        customPreRollText = "\(val)"
                                        onStatus("Pre-Roll Length: \(val) \(val == 1 ? "Measure" : "Measures")")
                                    }
                                }
                            )) {
                                Text("1 Measure").tag(1)
                                Text("2 Measures").tag(2)
                                Text("4 Measures").tag(4)
                                Text("8 Measures").tag(8)
                                Text("Custom").tag(-1)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .disabled(!engine.isSongSectionPreRollEnabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, isCustomPreRoll ? 2 : 6)
                        .opacity(engine.isSongSectionPreRollEnabled ? 1.0 : 0.35)
                        
                        // Custom Length input field
                        if isCustomPreRoll && engine.isSongSectionPreRollEnabled {
                            HStack {
                                Text("Measures")
                                    .font(.system(size: 10.5, weight: .regular))
                                    .foregroundColor(Color(white: 0.70))
                                    .padding(.leading, 32)
                                Spacer()
                                TextField("Bars", text: $customPreRollText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 55, height: 20)
                                    .padding(.horizontal, 6)
                                    .background(Color(white: 0.16))
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color(red: 0.20, green: 0.65, blue: 0.95).opacity(0.8), lineWidth: 1)
                                    )
                                    .onChange(of: customPreRollText) { val in
                                        let clean = val.filter { "0123456789".contains($0) }
                                        if let num = Int(clean), num > 0 {
                                            engine.sectionPreRollLengthBars = num
                                            engine.updatePreRollSettings()
                                        }
                                    }
                                Text("measures")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(white: 0.50))
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                        }
                    }
                    .background(engine.isSongSectionPreRollEnabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3E. Pad Player Defaults
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "pianokeys")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isGlobalStartPadWithSongEnabled ? Color(red: 0.25, green: 0.90, blue: 0.45) : Color(white: 0.70))
                                .frame(width: 20)
                            Text("Start Pad Player With Song")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isGlobalStartPadWithSongEnabled },
                                set: { val in
                                    engine.setGlobalStartPadWithSong(val)
                                    onStatus(val ? "Start Pad With Song: Enabled" : "Start Pad With Song: Disabled")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.90, blue: 0.45)))
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        
                        // Default Ambient Pad option below toggle
                        HStack {
                            Text("Default Ambient Pad")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.85))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { padLibrary.activePackId },
                                set: { val in
                                    padLibrary.activePackId = val
                                    UserDefaults.standard.set(val, forKey: "Playback_DefaultAmbientPadId")
                                    onStatus("Default Pad: \(padLibrary.activePack.name)")
                                }
                            )) {
                                ForEach(padLibrary.availablePacks) { pack in
                                    Text(pack.name).tag(pack.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                    .background(engine.isGlobalStartPadWithSongEnabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3E2. Click & Guide Section
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "metronome.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.70))
                                .frame(width: 20)
                            Text("Click & Guide")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        HStack {
                            Text("Default Click Source")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.85))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { engine.defaultClickSourcePreference },
                                set: { src in
                                    engine.setDefaultClickSourcePreference(src)
                                    onStatus("Default Click Source: \(src.rawValue)")
                                }
                            )) {
                                Text("Uploaded").tag(ClickSource.uploaded)
                                Text("Generated").tag(ClickSource.generated)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 12)
                        
                        HStack {
                            Text("Default Guide Source")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.85))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { engine.defaultGuideSourcePreference },
                                set: { src in
                                    engine.setDefaultGuideSourcePreference(src)
                                    onStatus("Default Guide Source: \(src.rawValue)")
                                }
                            )) {
                                Text("Uploaded").tag(GuideSource.uploaded)
                                Text("Generated").tag(GuideSource.generated)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 12)
                        
                        HStack {
                            Text("Default Click")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.85))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { customSamples.defaultClickSound },
                                set: { sound in
                                    engine.setDefaultClickSound(sound, syncDefaultSongs: true)
                                    onStatus("Default Click: \(sound.displayName)")
                                }
                            )) {
                                if AudioSampleBank.shared.hasSampledClicks || (customSamples.defaultClickSound.isSampled && !customSamples.defaultClickSound.isCustom) {
                                    Section("Recorded Clicks") {
                                        ForEach(ClickSoundType.sampledClicks, id: \.self) { sound in
                                            Text(sound.displayName).tag(sound)
                                        }
                                    }
                                }
                                if !customSamples.customClickPacks.isEmpty {
                                    Section("Custom Clicks") {
                                        ForEach(customSamples.customClickPacks) { pack in
                                            Text(pack.name).tag(pack.clickSoundType)
                                        }
                                    }
                                }
                                Section("Included Clicks") {
                                    ForEach(ClickSoundType.synthClicks, id: \.self) { sound in
                                        Text(sound.displayName).tag(sound)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 12)
                        
                        HStack {
                            Text("Default Guide")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.85))
                                .padding(.leading, 32)
                            Spacer()
                            
                            Picker("", selection: Binding<String>(
                                get: { resolvedDefaultGuidePickerTag() },
                                set: { tag in
                                    let chosen = GuideVoice(rawValue: tag)
                                    engine.setDefaultGuideVoice(chosen, syncDefaultSongs: true)
                                    onStatus("Default Guide: \(engine.guideAudioGenerator.displayName(for: chosen))")
                                }
                            )) {
                                if !customSamples.includedGuidePacks.isEmpty {
                                    Section("Included Voices") {
                                        ForEach(customSamples.includedGuidePacks) { pack in
                                            Text(pack.name).tag(pack.guideVoice.rawValue)
                                        }
                                    }
                                }
                                if !customSamples.userCustomGuidePacks.isEmpty {
                                    Section("Custom Voices") {
                                        ForEach(customSamples.userCustomGuidePacks) { pack in
                                            Text(pack.name).tag(pack.guideVoice.rawValue)
                                        }
                                    }
                                }
                                if AudioSampleBank.shared.hasSampledGuides || customSamples.defaultGuideVoice == .rita {
                                    Section("Studio Voice") {
                                        Text("Rita").tag(GuideVoice.rita.rawValue)
                                    }
                                }
                                if !installedVoices.isEmpty {
                                    Section("Siri & System Voices") {
                                        ForEach(installedVoices) { voiceInfo in
                                            Text(voiceInfo.displayName).tag(voiceInfo.id)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                        if VoiceCloneModelManager.isPlatformSupported {
                            let isDefaultClone = customSamples.defaultGuideFallbackVoice.isVoiceClone
                            let totalSongs = max(1, engine.currentSetlist.songs.count)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("AI Voice Clone by Default")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text("Applies to default songs (\(engine.defaultFallbackSyncedSongCount) of \(totalSongs))")
                                            .font(.system(size: 9.5))
                                            .foregroundColor(Color(white: 0.56))
                                    }

                                    Spacer(minLength: 4)

                                    Toggle("", isOn: Binding(
                                        get: { customSamples.defaultGuideFallbackVoice.isVoiceClone },
                                        set: { enabled in
                                            if enabled {
                                                let chosen = resolvedPreferredCloneVoice()
                                                engine.setDefaultGuideFallbackVoice(chosen, syncDefaultSongs: true)
                                                onStatus("AI Voice Clone enabled for default songs (\(engine.defaultFallbackSyncedSongCount) of \(totalSongs))")
                                            } else {
                                                let sys = customSamples.defaultSystemFallbackVoice
                                                engine.setDefaultGuideFallbackVoice(sys, syncDefaultSongs: true)
                                                onStatus("Default Fallback: \(engine.guideAudioGenerator.displayName(for: sys))")
                                            }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
                                }

                                if isDefaultClone {
                                    HStack {
                                        Text("Clone Source")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(Color(white: 0.72))
                                        Spacer()

                                        Picker("", selection: Binding<String>(
                                            get: { resolvedDefaultCloneSourceTag() },
                                            set: { tag in
                                                let chosen = GuideVoice(rawValue: tag)
                                                engine.setDefaultGuideFallbackVoice(chosen, syncDefaultSongs: true)
                                                onStatus("Default Clone Source: \(engine.guideAudioGenerator.displayName(for: chosen))")
                                            }
                                        )) {
                                            Text("Match Guide Voice").tag(GuideVoice.cloneActive.rawValue)
                                            if AudioSampleBank.shared.hasSampledGuides {
                                                Text("Studio Voice").tag(GuideVoice.clonePack("rita").rawValue)
                                            }
                                            ForEach(customSamples.includedGuidePacks) { pack in
                                                Text(pack.name).tag(GuideVoice.clonePack(pack.id).rawValue)
                                            }
                                            ForEach(customSamples.userCustomGuidePacks) { pack in
                                                Text(pack.name).tag(GuideVoice.clonePack(pack.id).rawValue)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 126)
                                    }
                                }

                                HStack {
                                    Text(isDefaultClone ? "System Backup" : "Default Fallback")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(Color(white: 0.72))
                                    Spacer()

                                    Picker("", selection: Binding<String>(
                                        get: { resolvedDefaultSystemFallbackTag() },
                                        set: { tag in
                                            let chosen = GuideVoice(rawValue: tag)
                                            engine.setDefaultSystemFallbackVoice(chosen)
                                            onStatus("\(isDefaultClone ? "System Backup" : "Default Fallback"): \(engine.guideAudioGenerator.displayName(for: chosen))")
                                        }
                                    )) {
                                        if !installedVoices.isEmpty {
                                            ForEach(installedVoices) { voiceInfo in
                                                Text(voiceInfo.displayName).tag(voiceInfo.id)
                                            }
                                        } else {
                                            Text("Zoe (Premium)").tag(GuideVoice.zoe.rawValue)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 126)
                                }

                                if engine.overriddenFallbackSongCount > 0 {
                                    let overridden = engine.overriddenFallbackSongCount
                                    Divider()
                                        .background(Color.white.opacity(0.08))
                                    HStack {
                                        Text("\(overridden) \(overridden == 1 ? "song" : "songs") overridden")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(Color.orange.opacity(0.95))
                                        Spacer()
                                        Button("Apply to All") {
                                            engine.applyDefaultGuideFallbackToAllSongs()
                                            onStatus("Applied fallback settings to all \(totalSongs) songs")
                                        }
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.cyan)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color(white: 0.14))
                            .cornerRadius(6)
                            .padding(.leading, 18)
                            .padding(.trailing, 12)
                            .padding(.bottom, 2)

                            VoiceCloneModelStatusView(
                                style: .settingsMenu,
                                isFeatureActive: isDefaultClone || engine.currentSong.guideFallbackVoice.isVoiceClone
                            ) {
                                engine.handleVoiceCloneModelOrPhraseUpdated()
                                onStatus("Cleared AI voice clone phrase cache")
                            }
                            .padding(.leading, 18)
                            .padding(.trailing, 12)
                            .padding(.vertical, 2)
                        } else {
                            HStack {
                                Text("Default Fallback")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(white: 0.85))
                                    .padding(.leading, 32)
                                Spacer()

                                Picker("", selection: Binding<String>(
                                    get: { resolvedDefaultSystemFallbackTag() },
                                    set: { tag in
                                        let chosen = GuideVoice(rawValue: tag)
                                        engine.setDefaultSystemFallbackVoice(chosen)
                                        onStatus("Default Fallback: \(engine.guideAudioGenerator.displayName(for: chosen))")
                                    }
                                )) {
                                    if !installedVoices.isEmpty {
                                        ForEach(installedVoices) { voiceInfo in
                                            Text(voiceInfo.displayName).tag(voiceInfo.id)
                                        }
                                    } else {
                                        Text("Zoe (Premium)").tag(GuideVoice.zoe.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        }

                        Button(action: {
                            isPresented = false
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                                engine.isShowingCustomGuideSampleManager = false
                                engine.isShowingCustomClickSampleManager = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                    .frame(width: 16)
                                Text("Upload / Manage Click Samples...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.cyan)
                                Spacer()
                                if !customSamples.customClickPacks.isEmpty {
                                    Text("\(customSamples.customClickPacks.count)")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.cyan.opacity(0.16))
                                        .cornerRadius(4)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color(white: 0.45))
                            }
                            .padding(.leading, 32)
                            .padding(.trailing, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            isPresented = false
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                                engine.isShowingCustomClickSampleManager = false
                                engine.isShowingCustomGuideSampleManager = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                    .frame(width: 16)
                                Text("Upload / Manage Guide Samples...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.cyan)
                                Spacer()
                                if !customSamples.userCustomGuidePacks.isEmpty {
                                    Text("\(customSamples.userCustomGuidePacks.count)")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.cyan.opacity(0.16))
                                        .cornerRadius(4)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color(white: 0.45))
                            }
                            .padding(.leading, 32)
                            .padding(.trailing, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Include Numbers in Guide Section Names
                        HStack {
                            Text("Include Numbers in Guide")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isGlobalIncludeGuideSectionNumbersEnabled },
                                set: { val in
                                    engine.setGlobalIncludeGuideSectionNumbers(val)
                                    onStatus(val ? "Guide: Section numbers included (e.g. \"Verse 2\")" : "Guide: Section numbers omitted (e.g. \"Verse\")")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.65, blue: 0.95)))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)
                    
                    // 3F. Channel Faders Default Level (Mixer Window Only)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "slider.vertical.3")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isFadersDefault100Enabled ? Color(red: 0.20, green: 0.65, blue: 0.95) : Color(white: 0.70))
                                .frame(width: 20)
                            Text("Faders Default Level 100%")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isFadersDefault100Enabled },
                                set: { val in
                                    engine.setFadersDefault100(val)
                                    onStatus(val ? "Mixer Channel Faders: 100%" : "Mixer Channel Faders: Unity (0 dB)")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.65, blue: 0.95)))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .background(engine.isFadersDefault100Enabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)
                    
                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)

                    // 3G. PeanutButter Remote (Local Network Control)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "wifi")
                                .font(.system(size: 12))
                                .foregroundColor(engine.isRemoteControlEnabled ? Color(red: 0.25, green: 0.90, blue: 0.45) : Color(white: 0.70))
                                .frame(width: 20)
                            Text("PeanutButter Remote")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.isRemoteControlEnabled },
                                set: { val in
                                    engine.setRemoteControlEnabled(val)
                                    onStatus(val ? "Remote Server Enabled" : "Remote Server Stopped")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.25, green: 0.90, blue: 0.45)))
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                        if engine.isRemoteControlEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                if let err = remoteServer.lastError, !err.isEmpty {
                                    Text("Error: \(err)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Color(red: 0.98, green: 0.35, blue: 0.38))
                                } else {
                                    HStack(spacing: 6) {
                                        Text(remoteServer.localURLString.isEmpty ? "Starting server..." : remoteServer.localURLString)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundColor(Color(red: 0.28, green: 0.75, blue: 0.98))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if !remoteServer.localURLString.isEmpty {
                                            Button("Copy") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(remoteServer.localURLString, forType: .string)
                                                onStatus("Copied Remote URL")
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(white: 0.22))
                                            .cornerRadius(4)
                                        }
                                    }
                                    Text("\(remoteServer.connectedClientCount) connected • Bonjour _peanutbutter._tcp")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.58))
                                }

                                Toggle("Require Password", isOn: $remoteServer.isPasswordRequired)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.85))
                                    .padding(.top, 2)

                                if remoteServer.isPasswordRequired {
                                    HStack(spacing: 6) {
                                        SecureField(
                                            remoteServer.hasConfiguredPassword && remoteServer.remotePassword.isEmpty
                                                ? "Password saved (type new to change)..."
                                                : "Remote Password...",
                                            text: $remoteServer.remotePassword
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                        .focused($isRemotePasswordFocused)
                                        .onSubmit {
                                            remoteServer.commitPendingPassword()
                                        }
                                        .onChange(of: isRemotePasswordFocused) { focused in
                                            if !focused {
                                                remoteServer.commitPendingPassword()
                                            }
                                        }

                                        if remoteServer.hasConfiguredPassword {
                                            Button("Clear") {
                                                isRemotePasswordFocused = false
                                                remoteServer.clearPassword()
                                                onStatus("Cleared Remote Password")
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Color(red: 0.98, green: 0.45, blue: 0.48))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color(white: 0.22))
                                            .cornerRadius(4)
                                        }
                                    }

                                    if !remoteServer.hasConfiguredPassword {
                                        Text("Enter a password to allow remote connections")
                                            .font(.system(size: 9.5, weight: .medium))
                                            .foregroundColor(Color(red: 0.98, green: 0.72, blue: 0.30))
                                    }
                                }
                            }
                            .padding(.leading, 32)
                            .padding(.trailing, 12)
                            .padding(.bottom, 6)
                        }
                    }
                    .background(engine.isRemoteControlEnabled ? Color(red: 0.15, green: 0.17, blue: 0.20) : Color.clear)
                    .cornerRadius(4)
                    .padding(.horizontal, 4)

                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)

                    // 3.5 Cloud Library Sync (BYOC)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: library.isCloudConnected ? "icloud.fill" : "icloud")
                                .font(.system(size: 12))
                                .foregroundColor(library.isCloudConnected ? Color(red: 0.35, green: 0.72, blue: 1.0) : Color(white: 0.55))
                            Text("Cloud Library Sync")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(white: 0.92))
                            Spacer()
                            Text(library.isCloudConnected ? "Connected" : "Local Only")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(library.isCloudConnected ? Color(red: 0.35, green: 0.78, blue: 1.0) : Color(white: 0.55))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(library.isCloudConnected ? Color(red: 0.12, green: 0.24, blue: 0.34) : Color(white: 0.18))
                                .cornerRadius(4)
                        }

                        if let cloudURL = library.cloudRootURL {
                            Text(cloudURL.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(white: 0.58))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } else {
                            Text("Pick an iCloud Drive, Dropbox, Google Drive, or OneDrive folder to sync Songs, Setlists, Stems & Pads.")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(white: 0.52))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 6) {
                            Button(action: {
                                let panel = NSOpenPanel()
                                panel.title = "Choose Cloud Library Folder"
                                panel.message = "Select a folder in iCloud Drive, Dropbox, Google Drive, or OneDrive."
                                panel.prompt = "Use Folder"
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    library.setCloudLibraryFolder(url)
                                    PadLibraryManager.shared.reloadPacks()
                                }
                            }) {
                                Text(library.isCloudConnected ? "Change Folder..." : "Choose Cloud Folder...")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(red: 0.18, green: 0.42, blue: 0.68))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)

                            if library.isCloudConnected {
                                Button(action: {
                                    library.refreshSongs()
                                    library.refreshSetlists()
                                    PadLibraryManager.shared.reloadPacks()
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(white: 0.85))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color(white: 0.2))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .help("Refresh Cloud Library")

                                Button(action: {
                                    library.disconnectCloudLibrary()
                                    PadLibraryManager.shared.reloadPacks()
                                }) {
                                    Text("Disconnect")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color(white: 0.18))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)

                    // 3.5 Software Updates
                    Button(action: {
                        isPresented = false
                        updateManager.checkForUpdates(manual: true)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: updateManager.isReadyToInstall ? "checkmark.circle.fill" : "arrow.down.app")
                                .font(.system(size: 12))
                                .foregroundColor(updateManager.isReadyToInstall ? Color(red: 0.25, green: 0.88, blue: 0.45) : (updateManager.availableRelease != nil ? .cyan : Color(white: 0.70)))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Check for Updates…")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("PeanutButter v\(updateManager.currentVersion)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(white: 0.55))
                            }
                            Spacer()
                            if updateManager.isReadyToInstall {
                                Text("Ready")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.25, green: 0.88, blue: 0.45))
                                    .cornerRadius(4)
                            } else if let rel = updateManager.availableRelease {
                                Text("v\(rel.displayVersion)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.cyan)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .background(Color(white: 0.18))
                        .padding(.vertical, 4)

                    // 4. Clear Tracks (Destructive)
                    Button(action: {
                        isPresented = false
                        engine.clearAllTracks()
                        onStatus("Cleared tracks")
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 0.98, green: 0.28, blue: 0.32))
                                .frame(width: 20)
                            Text("Clear Current Stems")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(Color(red: 0.98, green: 0.28, blue: 0.32))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 285)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        .onAppear {
            isCustomPreRoll = ![1, 2, 4, 8].contains(engine.sectionPreRollLengthBars)
            customPreRollText = "\(engine.sectionPreRollLengthBars)"
            installedVoices = GuideAudioGenerator.shared.installedVoiceList().filter { !$0.isNovelty }
        }
        .onDisappear {
            remoteServer.commitPendingPassword()
        }
    }
    
    private func resolvedDefaultGuidePickerTag() -> String {
        let current = customSamples.defaultGuideVoice
        if current == .rita || current.rawValue.caseInsensitiveCompare("rita") == .orderedSame {
            if AudioSampleBank.shared.hasSampledGuides {
                return GuideVoice.rita.rawValue
            }
            return customSamples.includedGuidePacks.first?.guideVoice.rawValue ?? installedVoices.first?.id ?? GuideVoice.rita.rawValue
        }
        if current.isCustom {
            return current.rawValue
        }
        let sysId = engine.guideAudioGenerator.systemVoiceIdentifier(for: current)
        if installedVoices.contains(where: { $0.id == sysId }) {
            return sysId
        }
        return installedVoices.first?.id ?? GuideVoice.rita.rawValue
    }

    private func resolvedPreferredCloneVoice() -> GuideVoice {
        let preferred = customSamples.preferredDefaultVoiceCloneVoice
        if preferred.isCloneActive {
            return .cloneActive
        }
        if let clonedId = preferred.clonedPackId,
           customSamples.guidePack(forId: clonedId) != nil ||
           (clonedId.caseInsensitiveCompare("rita") == .orderedSame && AudioSampleBank.shared.hasSampledGuides) {
            return preferred
        }
        return .cloneActive
    }

    private func resolvedDefaultCloneSourceTag() -> String {
        let current = customSamples.defaultGuideFallbackVoice
        if current.isCloneActive {
            return current.rawValue
        }
        if let clonedId = current.clonedPackId {
            if customSamples.guidePack(forId: clonedId) != nil ||
               (clonedId.caseInsensitiveCompare("rita") == .orderedSame && AudioSampleBank.shared.hasSampledGuides) {
                return current.rawValue
            }
        }
        return GuideVoice.cloneActive.rawValue
    }

    private func resolvedDefaultSystemFallbackTag() -> String {
        let sysVoice = customSamples.defaultSystemFallbackVoice
        let sysId = engine.guideAudioGenerator.systemVoiceIdentifier(for: sysVoice)
        if installedVoices.contains(where: { $0.id == sysId }) {
            return sysId
        }
        return installedVoices.first?.id ?? GuideVoice.zoe.rawValue
    }
    
    private func menuRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.70))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(white: 0.90))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
