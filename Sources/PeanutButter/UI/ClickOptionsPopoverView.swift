import SwiftUI

/// Popover for configuring Click track source and subdivisions (Accents, 1/4, 1/8, 1/16)
public struct ClickOptionsPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    let onDismiss: () -> Void
    
    public init(engine: MultitrackAudioEngine, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.onDismiss = onDismiss
    }
    
    private var hasUploadedClick: Bool {
        engine.uploadedClickBuffers[engine.currentSong.id] != nil
    }
    
    private var isUploaded: Bool {
        engine.currentSong.clickSource == .uploaded
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("CLICK SETTINGS")
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
            
            // 1. Source Selection (Always shown; Uploaded is greyed out/disabled if no uploaded file exists)
            VStack(alignment: .leading, spacing: 6) {
                Text("AUDIO SOURCE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(white: 0.5))
                
                HStack(spacing: 4) {
                    Button(action: {
                        engine.setClickSource(.generated)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 10))
                            Text("Generated")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(engine.currentSong.clickSource == .generated ? Color(white: 0.30) : Color(white: 0.16))
                        .foregroundColor(.white)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        if hasUploadedClick {
                            engine.setClickSource(.uploaded)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 10))
                            Text("Uploaded")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(hasUploadedClick && engine.currentSong.clickSource == .uploaded ? Color(white: 0.30) : Color(white: 0.14))
                        .foregroundColor(hasUploadedClick ? .white : Color(white: 0.40))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasUploadedClick)
                    .opacity(hasUploadedClick ? 1.0 : 0.45)
                    .help(hasUploadedClick ? "Play uploaded click stem" : "No uploaded click file available for this song")
                }
            }
            
            Divider()
                .background(Color(white: 0.18))
            
            // 2. Click Sound Selection
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CLICK SOUND")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    if customSamples.defaultClickSound == engine.currentSong.clickSound {
                        Text("DEFAULT ✓")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color.cyan)
                    } else {
                        Button("Set as Default") {
                            engine.setDefaultClickSound(engine.currentSong.clickSound, syncDefaultSongs: true)
                            engine.useDefaultClickForCurrentSong()
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.cyan)
                        .buttonStyle(.plain)
                    }
                }
                
                Picker("", selection: Binding(
                    get: { engine.currentSong.clickSound },
                    set: { engine.setClickSound($0) }
                )) {
                    if AudioSampleBank.shared.hasSampledClicks || (engine.currentSong.clickSound.isSampled && !engine.currentSong.clickSound.isCustom) {
                        Section("Recorded Clicks") {
                            ForEach(ClickSoundType.sampledClicks, id: \.self) { sound in
                                Text(sound.rawValue).tag(sound)
                            }
                        }
                    }
                    if !customSamples.customClickPacks.isEmpty {
                        Section("Custom Click Samples") {
                            ForEach(customSamples.customClickPacks) { pack in
                                Text(pack.name).tag(pack.clickSoundType)
                            }
                        }
                    }
                    Section("Included Clicks") {
                        ForEach(ClickSoundType.synthClicks, id: \.self) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                HStack {
                    Button(action: {
                        onDismiss()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                            engine.isShowingCustomGuideSampleManager = false
                            engine.isShowingCustomClickSampleManager = true
                        }
                    }) {
                        Label("Upload / Manage Click Samples...", systemImage: "folder.badge.plus")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color.cyan)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !engine.currentSong.usesDefaultClickSound && customSamples.defaultClickSound != engine.currentSong.clickSound {
                        Button("Reset to Default") {
                            engine.useDefaultClickForCurrentSong()
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.62))
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(isUploaded)
            .opacity(isUploaded ? 0.38 : 1.0)
            
            Divider()
                .background(Color(white: 0.18))
            
            // 3. Click Subdivisions & Accents
            VStack(alignment: .leading, spacing: 8) {
                Text("SUBDIVISIONS & ACCENTS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(white: 0.5))
                
                VStack(spacing: 6) {
                    subdivisionToggleRow(
                        title: "Downbeat Accent",
                        subtitle: "Emphasize beat 1 of each bar",
                        isOn: Binding(
                            get: { engine.currentSong.clickAccentEnabled },
                            set: { engine.setClickSubdivisions(accent: $0, quarter: engine.currentSong.clickQuarterEnabled, eighth: engine.currentSong.clickEighthEnabled, sixteenth: engine.currentSong.clickSixteenthEnabled) }
                        )
                    )
                    
                    subdivisionToggleRow(
                        title: "Quarter Notes (1/4)",
                        subtitle: "Main metronome beat pulse",
                        isOn: Binding(
                            get: { engine.currentSong.clickQuarterEnabled },
                            set: { engine.setClickSubdivisions(accent: engine.currentSong.clickAccentEnabled, quarter: $0, eighth: engine.currentSong.clickEighthEnabled, sixteenth: engine.currentSong.clickSixteenthEnabled) }
                        )
                    )
                    
                    subdivisionToggleRow(
                        title: "Eighth Notes (1/8)",
                        subtitle: "Subdivide half-beats ('&')",
                        isOn: Binding(
                            get: { engine.currentSong.clickEighthEnabled },
                            set: { engine.setClickSubdivisions(accent: engine.currentSong.clickAccentEnabled, quarter: engine.currentSong.clickQuarterEnabled, eighth: $0, sixteenth: engine.currentSong.clickSixteenthEnabled) }
                        )
                    )
                    
                    subdivisionToggleRow(
                        title: "Sixteenth Notes (1/16)",
                        subtitle: "Subdivide quarter-beats ('e', 'a')",
                        isOn: Binding(
                            get: { engine.currentSong.clickSixteenthEnabled },
                            set: { engine.setClickSubdivisions(accent: engine.currentSong.clickAccentEnabled, quarter: engine.currentSong.clickQuarterEnabled, eighth: engine.currentSong.clickEighthEnabled, sixteenth: $0) }
                        )
                    )
                }
                .padding(8)
                .background(Color(white: 0.14))
                .cornerRadius(6)
            }
            .disabled(isUploaded)
            .opacity(isUploaded ? 0.38 : 1.0)
        }
        .padding(14)
        .frame(width: 290)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
    }
    
    private func subdivisionToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundColor(Color(white: 0.55))
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: Color.blue))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
