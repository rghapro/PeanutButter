import SwiftUI
import AppKit

/// Popover for configuring Guide track source, voices (all downloaded & system voices), and count-ins
public struct GuideOptionsPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    let onDismiss: () -> Void
    
    @State private var voiceFilter: String = ""
    @State private var installedVoices: [InstalledVoiceInfo] = []
    
    public init(engine: MultitrackAudioEngine, onDismiss: @escaping () -> Void) {
        self.engine = engine
        self.onDismiss = onDismiss
    }
    
    private var hasUploadedGuide: Bool {
        engine.uploadedGuideBuffers[engine.currentSong.id] != nil
    }
    
    private var isUploaded: Bool {
        engine.currentSong.guideSource == .uploaded
    }
    
    private func reloadVoices() {
        installedVoices = engine.guideAudioGenerator.installedVoiceList()
    }
    
    private var currentVoiceIdentifier: String {
        engine.guideAudioGenerator.resolveSystemVoice(for: engine.currentSong.guideVoice)?.identifier ?? engine.currentSong.guideVoice.rawValue
    }
    
    private var currentVoiceDisplayName: String {
        engine.guideAudioGenerator.displayName(for: engine.currentSong.guideVoice)
    }
    
    private var siriUSVoices: [InstalledVoiceInfo] {
        installedVoices.filter { $0.isSiri && ($0.language == "en-US" || $0.localizedLanguage.contains("American")) }
    }
    
    private var siriIntlVoices: [InstalledVoiceInfo] {
        installedVoices.filter { $0.isSiri && !($0.language == "en-US" || $0.localizedLanguage.contains("American")) }
    }
    
    private var isRitaSelected: Bool {
        engine.currentSong.guideVoice == .rita || engine.currentSong.guideVoice.rawValue.lowercased() == "rita"
    }
    
    private var isCustomGuideSelected: Bool {
        engine.currentSong.guideVoice.isCustom
    }
    
    private func isCurrentVoice(_ v: InstalledVoiceInfo) -> Bool {
        if isRitaSelected || isCustomGuideSelected { return false }
        let cur = currentVoiceIdentifier.lowercased()
        let vid = v.id.lowercased()
        if cur == vid { return true }
        if cur.contains("nicky") && vid.contains("nicky") { return true }
        if cur.contains("aaron") && vid.contains("aaron") { return true }
        if cur.contains("martha") && vid.contains("martha") { return true }
        if cur.contains("arthur") && vid.contains("arthur") { return true }
        if cur.contains("catherine") && vid.contains("catherine") { return true }
        if cur.contains("gordon") && vid.contains("gordon") { return true }
        if cur.contains("samantha") && vid.contains("samantha") { return true }
        if cur.contains("daniel") && vid.contains("daniel") { return true }
        if cur.contains("zoe") && vid.contains("zoe") { return true }
        return false
    }
    
    private func isFallbackVoice(_ v: InstalledVoiceInfo) -> Bool {
        let cur = (engine.guideAudioGenerator.resolveSystemVoice(for: engine.currentSong.guideFallbackVoice)?.identifier ?? engine.currentSong.guideFallbackVoice.rawValue).lowercased()
        let vid = v.id.lowercased()
        if cur == vid { return true }
        if cur.contains("nicky") && vid.contains("nicky") { return true }
        if cur.contains("aaron") && vid.contains("aaron") { return true }
        if cur.contains("martha") && vid.contains("martha") { return true }
        if cur.contains("arthur") && vid.contains("arthur") { return true }
        if cur.contains("catherine") && vid.contains("catherine") { return true }
        if cur.contains("gordon") && vid.contains("gordon") { return true }
        if cur.contains("samantha") && vid.contains("samantha") { return true }
        if cur.contains("daniel") && vid.contains("daniel") { return true }
        if cur.contains("zoe") && vid.contains("zoe") { return true }
        return false
    }
    
    private var englishVoices: [InstalledVoiceInfo] {
        installedVoices.filter { !$0.isSiri && !$0.isNovelty && $0.language.hasPrefix("en") }
            .sorted { (v1, v2) -> Bool in
                if v1.qualityRaw != v2.qualityRaw { return v1.qualityRaw > v2.qualityRaw }
                return v1.name < v2.name
            }
    }
    

    private var classicVoices: [InstalledVoiceInfo] {
        installedVoices.filter { $0.isNovelty }
            .sorted { $0.name < $1.name }
    }
    
    private var filteredVoices: [InstalledVoiceInfo] {
        guard !voiceFilter.isEmpty else { return [] }
        let q = voiceFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return installedVoices.filter {
            $0.name.lowercased().contains(q) ||
            $0.localizedLanguage.lowercased().contains(q) ||
            $0.language.lowercased().contains(q) ||
            ($0.isSiri && "siri".contains(q))
        }
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("GUIDE SETTINGS")
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
                        engine.setGuideSource(.generated)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 10))
                            Text("Generated")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(engine.currentSong.guideSource == .generated ? Color(white: 0.30) : Color(white: 0.16))
                        .foregroundColor(.white)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        if hasUploadedGuide {
                            engine.setGuideSource(.uploaded)
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
                        .background(hasUploadedGuide && engine.currentSong.guideSource == .uploaded ? Color(white: 0.30) : Color(white: 0.14))
                        .foregroundColor(hasUploadedGuide ? .white : Color(white: 0.40))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasUploadedGuide)
                    .opacity(hasUploadedGuide ? 1.0 : 0.45)
                    .help(hasUploadedGuide ? "Play uploaded guide stem" : "No uploaded guide file available for this song")
                }
            }
            
            Divider()
                .background(Color(white: 0.18))
            
            // 2. Guide Voice Selection (All Downloaded & System Voices)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VOICE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(white: 0.5))
                    
                    Spacer()
                    
                    if customSamples.defaultGuideVoice == engine.currentSong.guideVoice {
                        Text("DEFAULT ✓")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color.cyan)
                    } else {
                        Button("Set as Default") {
                            engine.setDefaultGuideVoice(engine.currentSong.guideVoice, syncDefaultSongs: true)
                            engine.useDefaultGuideForCurrentSong()
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color.cyan)
                        .buttonStyle(.plain)
                    }
                    
                    Text("· \(installedVoices.count) Sys")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(white: 0.4))
                }
                
                // Voice Selector Menu
                Menu {
                    // Included Voices (Bundled guide packs)
                    if !customSamples.includedGuidePacks.isEmpty {
                        Section("Included Voices") {
                            ForEach(customSamples.includedGuidePacks) { pack in
                                let gVoice = pack.guideVoice
                                Button(action: {
                                    engine.setGuideVoice(gVoice)
                                }) {
                                    if engine.currentSong.guideVoice == gVoice {
                                        Label(pack.name, systemImage: "checkmark")
                                    } else {
                                        Text(pack.name)
                                    }
                                }
                            }
                        }
                    }

                    // User Custom Guide Sample Packs
                    if !customSamples.userCustomGuidePacks.isEmpty {
                        Section("Custom Voices") {
                            ForEach(customSamples.userCustomGuidePacks) { pack in
                                let gVoice = pack.guideVoice
                                Button(action: {
                                    engine.setGuideVoice(gVoice)
                                }) {
                                    if engine.currentSong.guideVoice == gVoice {
                                        Label(pack.name, systemImage: "checkmark")
                                    } else {
                                        Text(pack.name)
                                    }
                                }
                            }
                        }
                    }

                    // Studio Recorded Voices (Pre-recorded human stems, only shown when present)
                    if AudioSampleBank.shared.hasSampledGuides || isRitaSelected {
                        Section("Studio Recorded Voices") {
                            Button(action: {
                                engine.setGuideVoice(.rita)
                            }) {
                                if isRitaSelected {
                                    Label("Rita (Studio Recorded)", systemImage: "checkmark")
                                } else {
                                    Text("Rita (Studio Recorded)")
                                }
                            }
                        }
                    }
                    
                    // United States Siri Voices Section (Voice 1, Voice 2, Voice 3, Voice 4, Voice 5)
                    if !siriUSVoices.isEmpty {
                        Section("United States Siri Voices") {
                            ForEach(siriUSVoices) { v in
                                Button(action: {
                                    engine.setGuideVoice(GuideVoice(rawValue: v.id))
                                }) {
                                    if isCurrentVoice(v) {
                                        Label(v.name, systemImage: "checkmark")
                                    } else {
                                        Text(v.name)
                                    }
                                }
                            }
                        }
                    }
                    
                    // International Siri Voices Submenu
                    if !siriIntlVoices.isEmpty {
                        Menu("International Siri Voices (\(siriIntlVoices.count))") {
                            ForEach(siriIntlVoices) { v in
                                Button(action: {
                                    engine.setGuideVoice(GuideVoice(rawValue: v.id))
                                }) {
                                    if isCurrentVoice(v) {
                                        Label(v.name, systemImage: "checkmark")
                                    } else {
                                        Text(v.name)
                                    }
                                }
                            }
                        }
                    }
                    
                    // English / Downloaded Natural Section
                    if !englishVoices.isEmpty {
                        Section("Natural & English Voices (\(englishVoices.count))") {
                            ForEach(englishVoices) { v in
                                Button(action: {
                                    engine.setGuideVoice(GuideVoice(rawValue: v.id))
                                }) {
                                    if isCurrentVoice(v) {
                                        Label(v.name, systemImage: "checkmark")
                                    } else {
                                        Text(v.name)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Classic / Novelty Submenu
                    if !classicVoices.isEmpty {
                        Menu("Classic & Novelty (\(classicVoices.count))") {
                            ForEach(classicVoices) { v in
                                Button(action: {
                                    engine.setGuideVoice(GuideVoice(rawValue: v.id))
                                }) {
                                    if isCurrentVoice(v) {
                                        Label(v.name, systemImage: "checkmark")
                                    } else {
                                        Text(v.name)
                                    }
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button(action: {
                        onDismiss()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                            engine.isShowingCustomClickSampleManager = false
                            engine.isShowingCustomGuideSampleManager = true
                        }
                    }) {
                        Label("Upload / Manage Guide Samples...", systemImage: "folder.badge.plus")
                    }
                    
                    Button(action: {
                        reloadVoices()
                    }) {
                        Label("Refresh Voice List", systemImage: "arrow.clockwise")
                    }
                    
                    Button(action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.speech") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("Manage Voices in macOS...", systemImage: "gear")
                    }
                } label: {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundColor(Color.cyan)
                        
                        Text(currentVoiceDisplayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.16))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(white: 0.24), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                
                // Search filter bar to quickly find any downloaded voice
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.45))
                    
                    TextField("Search all downloaded voices...", text: $voiceFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    
                    if !voiceFilter.isEmpty {
                        Button(action: { voiceFilter = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Color(white: 0.13))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(white: 0.20), lineWidth: 1)
                )
                
                // Filtered search results if searching
                if !voiceFilter.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if filteredVoices.isEmpty {
                                Text("No voices matching '\(voiceFilter)'")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.45))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 4)
                            } else {
                                ForEach(filteredVoices) { v in
                                    Button(action: {
                                        engine.setGuideVoice(GuideVoice(rawValue: v.id))
                                        voiceFilter = ""
                                    }) {
                                        HStack {
                                            Text(v.displayName)
                                                .font(.system(size: 11))
                                                .foregroundColor(v.id == currentVoiceIdentifier ? Color.cyan : .white)
                                                .lineLimit(1)
                                            Spacer()
                                            if v.id == currentVoiceIdentifier {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(Color.cyan)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(v.id == currentVoiceIdentifier ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    .padding(4)
                    .background(Color(white: 0.10))
                    .cornerRadius(6)
                }
                
                HStack {
                    Button(action: {
                        onDismiss()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                            engine.isShowingCustomClickSampleManager = false
                            engine.isShowingCustomGuideSampleManager = true
                        }
                    }) {
                        Label("Upload / Manage Guide Samples...", systemImage: "folder.badge.plus")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color.cyan)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !engine.currentSong.usesDefaultGuideVoice && customSamples.defaultGuideVoice != engine.currentSong.guideVoice {
                        Button("Reset to Default") {
                            engine.useDefaultGuideForCurrentSong()
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.62))
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(isUploaded)
            .opacity(isUploaded ? 0.38 : 1.0)
            
            // 2b. Fallback Voice (Shown when Rita, a Custom Guide, or Uploaded Guide is selected)
            if isRitaSelected || isCustomGuideSelected || isUploaded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(isUploaded ? "DIRECTIONAL CUES VOICE" : "FALLBACK SYNTHESIS VOICE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(white: 0.5))
                        
                        Spacer()
                    }
                    
                    Text(isUploaded ? "Voice used for speaking directional cues over uploaded guide stem." : "Used when a custom section or cue doesn't have a studio recording.")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(white: 0.55))
                    
                    Menu {
                        // United States Siri Voices
                        if !siriUSVoices.isEmpty {
                            Section("United States Siri Voices") {
                                ForEach(siriUSVoices) { v in
                                    Button(action: {
                                        engine.setGuideFallbackVoice(GuideVoice(rawValue: v.id))
                                    }) {
                                        if isFallbackVoice(v) {
                                            Label(v.name, systemImage: "checkmark")
                                        } else {
                                            Text(v.name)
                                        }
                                    }
                                }
                            }
                        }
                        
                        // International Siri Voices
                        if !siriIntlVoices.isEmpty {
                            Menu("International Siri Voices (\(siriIntlVoices.count))") {
                                ForEach(siriIntlVoices) { v in
                                    Button(action: {
                                        engine.setGuideFallbackVoice(GuideVoice(rawValue: v.id))
                                    }) {
                                        if isFallbackVoice(v) {
                                            Label(v.name, systemImage: "checkmark")
                                        } else {
                                            Text(v.name)
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Natural & English Voices
                        if !englishVoices.isEmpty {
                            Section("Natural & English Voices (\(englishVoices.count))") {
                                ForEach(englishVoices) { v in
                                    Button(action: {
                                        engine.setGuideFallbackVoice(GuideVoice(rawValue: v.id))
                                    }) {
                                        if isFallbackVoice(v) {
                                            Label(v.name, systemImage: "checkmark")
                                        } else {
                                            Text(v.name)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.wave.2.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color.cyan)
                            
                            Text(engine.guideAudioGenerator.displayName(for: engine.currentSong.guideFallbackVoice))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Spacer()
                            
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(white: 0.5))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(white: 0.16))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.24), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            
            Divider()
                .background(Color(white: 0.18))
            
            // 3. Count In Toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spoken Count In")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Speak '2, 3, 4' after section cues")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Color(white: 0.55))
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { engine.currentSong.guideCountInEnabled },
                    set: { engine.setGuideCountIn(enabled: $0) }
                ))
                .toggleStyle(SwitchToggleStyle(tint: Color.blue))
                .labelsHidden()
            }
            .padding(8)
            .background(Color(white: 0.14))
            .cornerRadius(6)
            .disabled(isUploaded)
            .opacity(isUploaded ? 0.38 : 1.0)
            
            // 4. Directional Cues Spoken Overlay on Uploaded Guide Stem
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directional Cues on Uploaded Guide")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Speak cues even with uploaded guide")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Color(white: 0.55))
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { engine.currentSong.speakDirectionalCuesOnUploadedGuide },
                    set: { engine.setSpeakDirectionalCuesOnUploadedGuide($0) }
                ))
                .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
                .labelsHidden()
            }
            .padding(8)
            .background(Color(white: 0.14))
            .cornerRadius(6)
        }
        .padding(14)
        .frame(width: 330)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .cornerRadius(10)
        .onAppear {
            reloadVoices()
        }
    }
}
