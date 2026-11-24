import SwiftUI
import AppKit

/// Popover for configuring Guide track source, voices (all downloaded & system voices), and count-ins
public struct GuideOptionsPopoverView: View {
    @ObservedObject var engine: MultitrackAudioEngine
    @ObservedObject private var customSamples = CustomSampleLibraryManager.shared
    @ObservedObject private var modelManager = VoiceCloneModelManager.shared
    let onDismiss: () -> Void
    
    @State private var voiceFilter: String = ""
    @State private var installedVoices: [InstalledVoiceInfo] = []
    @State private var previewPhase: GuideFallbackPreviewPhase = .idle
    
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
    
    private var effectiveGuideVoice: GuideVoice {
        engine.guideAudioGenerator.effectivePrimaryVoice(for: engine.currentSong.guideVoice)
    }

    private var currentVoiceIdentifier: String {
        engine.guideAudioGenerator.resolveSystemVoice(for: effectiveGuideVoice)?.identifier ?? effectiveGuideVoice.rawValue
    }
    
    private var currentVoiceDisplayName: String {
        engine.guideAudioGenerator.displayName(for: effectiveGuideVoice)
    }
    
    private var siriUSVoices: [InstalledVoiceInfo] {
        installedVoices.filter { $0.isSiri && ($0.language == "en-US" || $0.localizedLanguage.contains("American")) }
    }
    
    private var siriIntlVoices: [InstalledVoiceInfo] {
        installedVoices.filter { $0.isSiri && !($0.language == "en-US" || $0.localizedLanguage.contains("American")) }
    }
    
    private var isRitaSelected: Bool {
        effectiveGuideVoice == .rita || effectiveGuideVoice.rawValue.lowercased() == "rita"
    }
    
    private var isCustomGuideSelected: Bool {
        effectiveGuideVoice.isCustom
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
    
    private var effectiveSystemFallbackVoice: GuideVoice {
        let fb = engine.currentSong.guideFallbackVoice
        let isRitaFb = fb == .rita || fb.rawValue.caseInsensitiveCompare("rita") == .orderedSame
        if fb.isVoiceClone || fb.isCustom || isRitaFb {
            return customSamples.defaultSystemFallbackVoice
        }
        return fb
    }

    private func isFallbackVoice(_ v: InstalledVoiceInfo) -> Bool {
        let sysVoice = effectiveSystemFallbackVoice
        let cur = (engine.guideAudioGenerator.resolveSystemVoice(for: sysVoice)?.identifier ?? sysVoice.rawValue).lowercased()
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

    private var activePrimaryPackDisplayName: String {
        if isCustomGuideSelected {
            return currentVoiceDisplayName
        }
        if isRitaSelected && AudioSampleBank.shared.hasSampledGuides {
            return "Studio Voice"
        }
        return engine.guideAudioGenerator.displayName(for: customSamples.defaultGuideVoice)
    }

    private var resolvedCloneTargetPackId: String? {
        let primaryForResolve = isUploaded
            ? engine.effectiveUploadedOverlayVoice(for: engine.currentSong)
            : engine.currentSong.guideVoice
        return engine.guideAudioGenerator.resolveCloneTargetPackId(
            primaryVoice: primaryForResolve,
            fallbackVoice: engine.currentSong.guideFallbackVoice
        )
    }

    private var resolvedCloneTargetPackName: String {
        guard let packId = resolvedCloneTargetPackId else {
            return activePrimaryPackDisplayName
        }
        if let pack = customSamples.guidePack(forId: packId) {
            return pack.name
        }
        if packId.caseInsensitiveCompare("rita") == .orderedSame {
            return "Studio Voice"
        }
        return "Selected Voice"
    }

    private var backupSystemVoiceDisplayName: String {
        engine.guideAudioGenerator.displayName(for: customSamples.defaultSystemFallbackVoice)
    }

    private var isAICloneEnabledForSong: Bool {
        VoiceCloneModelManager.isPlatformSupported && engine.currentSong.guideFallbackVoice.isVoiceClone
    }

    private func preferredCloneVoiceForCurrentSource() -> GuideVoice {
        if isUploaded {
            if let existingPackId = engine.currentSong.guideFallbackVoice.clonedPackId,
               customSamples.guidePack(forId: existingPackId) != nil {
                return .clonePack(existingPackId)
            }
            if let prefPackId = customSamples.preferredDefaultVoiceCloneVoice.clonedPackId,
               customSamples.guidePack(forId: prefPackId) != nil {
                return .clonePack(prefPackId)
            }
            if let primaryPackId = engine.currentSong.guideVoice.customPackId ?? customSamples.defaultGuideVoice.customPackId {
                return .clonePack(primaryPackId)
            }
            if let firstPackId = customSamples.includedGuidePacks.first?.id ?? customSamples.userCustomGuidePacks.first?.id {
                return .clonePack(firstPackId)
            }
            return .cloneActive
        } else {
            return customSamples.preferredDefaultVoiceCloneVoice
        }
    }

    private func triggerFallbackPreview(_ phrase: String? = nil) {
        let chosenPhrase: String
        if let explicit = phrase {
            chosenPhrase = explicit
        } else {
            let primaryForCheck = isUploaded
                ? engine.effectiveUploadedOverlayVoice(for: engine.currentSong)
                : effectiveGuideVoice
            let candidates = ["Drop to Piano", "Keys Only", "Acoustic Guitar Only", "Swell to Chorus"]
            chosenPhrase = candidates.first(where: {
                !engine.guideAudioGenerator.hasRecordedPhraseSample(
                    $0,
                    for: primaryForCheck,
                    fallbackVoice: engine.currentSong.guideFallbackVoice
                )
            }) ?? "Drop to Piano"
        }
        engine.previewGuideFallbackPhrase(chosenPhrase) { phase in
            previewPhase = phase
        }
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
                    
                    if customSamples.defaultGuideVoice == effectiveGuideVoice {
                        Text("DEFAULT ✓")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color.cyan)
                    } else {
                        Button("Set as Default") {
                            engine.setDefaultGuideVoice(effectiveGuideVoice, syncDefaultSongs: true)
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
                                    if effectiveGuideVoice == gVoice {
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
                                    if effectiveGuideVoice == gVoice {
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
                    if !engine.currentSong.usesDefaultGuideVoice && customSamples.defaultGuideVoice != effectiveGuideVoice {
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
            
            // 2b. Missing & Custom Cues / Directional Cues Fallback
            if !isUploaded && !isRitaSelected && !isCustomGuideSelected {
                Text("Using \(currentVoiceDisplayName) directly. System voices speak every cue natively, so no fallback or cloning is needed.")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.14))
                    .cornerRadius(6)
            } else {
                let missingPhrases = engine.currentSongFallbackPhrases()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(isUploaded ? "DIRECTIONAL CUES VOICE" : "MISSING & CUSTOM CUES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(white: 0.5))

                        Spacer()

                        if engine.currentSong.usesDefaultGuideFallback {
                            Text("DEFAULT ✓")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Color.cyan)
                        } else {
                            HStack(spacing: 6) {
                                Text("Song Override")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color.orange.opacity(0.95))
                                Button("Reset") {
                                    engine.useDefaultGuideFallbackForCurrentSong()
                                }
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color.cyan)
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if VoiceCloneModelManager.isPlatformSupported {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AI Voice Clone")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(isUploaded ? "Speak directional cues in cloned voice" : "Clone active voice for custom cues")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(Color(white: 0.56))
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { isAICloneEnabledForSong },
                                    set: { enabled in
                                        if enabled {
                                            engine.setGuideFallbackVoice(preferredCloneVoiceForCurrentSource())
                                        } else {
                                            engine.setGuideFallbackVoice(customSamples.defaultSystemFallbackVoice)
                                        }
                                    }
                                ))
                                .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
                                .labelsHidden()
                            }
                        }

                        if isAICloneEnabledForSong {
                            aiCloneStatusBanner(missingPhrases: missingPhrases)

                            previewBannerView

                            cloneSourcePickerRow

                            if !modelManager.isModelReady {
                                systemVoicePickerRow(
                                    label: "System Backup",
                                    onSelectSystemVoice: { chosen in
                                        engine.setDefaultSystemFallbackVoice(chosen)
                                    },
                                    includeTestButton: false
                                )
                            }

                            cueCoverageFooter(phrases: missingPhrases, isAIClone: true)
                        } else {
                            systemVoicePickerRow(
                                label: VoiceCloneModelManager.isPlatformSupported ? "System Voice" : (isUploaded ? "Cues Voice" : "System Fallback"),
                                onSelectSystemVoice: { chosen in
                                    engine.setGuideFallbackVoice(chosen)
                                },
                                includeTestButton: true
                            )

                            if !VoiceCloneModelManager.isPlatformSupported && engine.currentSong.guideFallbackVoice.isVoiceClone {
                                Text("AI Voice Clone requires Apple Silicon.")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(Color(white: 0.55))
                            }

                            previewBannerView

                            cueCoverageFooter(phrases: missingPhrases, isAIClone: false)
                        }
                    }
                    .padding(9)
                    .background(Color(white: 0.14))
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
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
        .onDisappear {
            CustomSampleLibraryManager.shared.stopPreview()
        }
    }

    @ViewBuilder
    private func aiCloneStatusBanner(missingPhrases: [String]) -> some View {
        switch modelManager.state {
        case .ready:
            let isGenerating = modelManager.isSynthesizing || (engine.isGeneratingGuide && !missingPhrases.isEmpty)
            if isGenerating {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text(
                            missingPhrases.isEmpty
                                ? "Generating cloned phrases..."
                                : "Generating \(missingPhrases.count) custom \(missingPhrases.count == 1 ? "cue" : "cues")..."
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        testFallbackButton(highlightCyan: false)
                    }
                    Text("Cloning \(resolvedCloneTargetPackName) · using \(backupSystemVoiceDisplayName) until ready")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color(white: 0.60))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cyan.opacity(0.30), lineWidth: 1)
                )
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Active: Cloning \(resolvedCloneTargetPackName)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    testFallbackButton(highlightCyan: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green.opacity(0.32), lineWidth: 1)
                )
            }

        case .notInstalled, .downloading, .failed:
            VoiceCloneModelStatusView(
                style: .guidePopover,
                backupVoiceName: backupSystemVoiceDisplayName,
                onTestAction: {
                    triggerFallbackPreview()
                },
                onRefreshAction: {
                    engine.handleVoiceCloneModelOrPhraseUpdated()
                }
            )

        case .unsupportedIntel:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cloneSourcePickerRow: some View {
        HStack(spacing: 8) {
            Text(isUploaded ? "Voice to Clone" : "Cloning")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: 0.65))

            Spacer()

            Menu {
                if !isUploaded {
                    Button(action: {
                        engine.setGuideFallbackVoice(.cloneActive)
                    }) {
                        if engine.currentSong.guideFallbackVoice.isCloneActive {
                            Label("Match Guide Voice (\(activePrimaryPackDisplayName))", systemImage: "checkmark")
                        } else {
                            Text("Match Guide Voice (\(activePrimaryPackDisplayName))")
                        }
                    }
                    Divider()
                }

                if AudioSampleBank.shared.hasSampledGuides {
                    Button(action: {
                        engine.setGuideFallbackVoice(.clonePack("rita"))
                    }) {
                        let isSelected = engine.currentSong.guideFallbackVoice.clonedPackId?.caseInsensitiveCompare("rita") == .orderedSame
                        if isSelected {
                            Label("Studio Voice", systemImage: "checkmark")
                        } else {
                            Text("Studio Voice")
                        }
                    }
                }

                ForEach(customSamples.includedGuidePacks) { pack in
                    Button(action: {
                        engine.setGuideFallbackVoice(.clonePack(pack.id))
                    }) {
                        if engine.currentSong.guideFallbackVoice.clonedPackId == pack.id {
                            Label(pack.name, systemImage: "checkmark")
                        } else {
                            Text(pack.name)
                        }
                    }
                }

                ForEach(customSamples.userCustomGuidePacks) { pack in
                    Button(action: {
                        engine.setGuideFallbackVoice(.clonePack(pack.id))
                    }) {
                        if engine.currentSong.guideFallbackVoice.clonedPackId == pack.id {
                            Label(pack.name, systemImage: "checkmark")
                        } else {
                            Text(pack.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(cloneSourceMenuTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 192)
                .background(Color(white: 0.16))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(white: 0.24), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var cloneSourceMenuTitle: String {
        if !isUploaded && engine.currentSong.guideFallbackVoice.isCloneActive {
            return "Match Guide Voice (\(activePrimaryPackDisplayName))"
        }
        return resolvedCloneTargetPackName
    }

    private func systemVoicePickerRow(
        label: String,
        onSelectSystemVoice: @escaping (GuideVoice) -> Void,
        includeTestButton: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: 0.68))

            Spacer(minLength: 4)

            Menu {
                if !siriUSVoices.isEmpty {
                    Section("United States Siri Voices") {
                        ForEach(siriUSVoices) { v in
                            Button(action: {
                                onSelectSystemVoice(GuideVoice(rawValue: v.id))
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

                if !siriIntlVoices.isEmpty {
                    Menu("International Siri Voices (\(siriIntlVoices.count))") {
                        ForEach(siriIntlVoices) { v in
                            Button(action: {
                                onSelectSystemVoice(GuideVoice(rawValue: v.id))
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

                if !englishVoices.isEmpty {
                    Section("Natural & English Voices (\(englishVoices.count))") {
                        ForEach(englishVoices) { v in
                            Button(action: {
                                onSelectSystemVoice(GuideVoice(rawValue: v.id))
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
                HStack(spacing: 6) {
                    Text(engine.guideAudioGenerator.displayName(for: effectiveSystemFallbackVoice))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: includeTestButton ? 136 : 178)
                .background(Color(white: 0.16))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(white: 0.24), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)

            if includeTestButton {
                testFallbackButton(highlightCyan: false)
            }
        }
    }

    private func testFallbackButton(highlightCyan: Bool) -> some View {
        Button(action: {
            triggerFallbackPreview()
        }) {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8.5))
                Text("Test")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(highlightCyan ? .cyan : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(white: 0.16))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(white: 0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Play a sample phrase using the active fallback path")
    }

    @ViewBuilder
    private var previewBannerView: some View {
        switch previewPhase {
        case .idle:
            EmptyView()
        case .preparing(let phrase, let isAI):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.50)
                    .frame(width: 11, height: 11)
                Text("Preparing \(isAI ? "AI Clone" : "System") preview: \"\(phrase)\"...")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(isAI ? .cyan : Color(white: 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isAI ? Color.cyan.opacity(0.12) : Color.white.opacity(0.08))
            .cornerRadius(5)

        case .playing(let phrase, let isAI, let voiceName):
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9.5))
                Text("\(isAI ? "Playing AI Clone" : "Playing") (\(voiceName)): \"\(phrase)\"")
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .foregroundColor(isAI ? .cyan : Color(white: 0.90))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isAI ? Color.cyan.opacity(0.14) : Color.white.opacity(0.09))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isAI ? Color.cyan.opacity(0.32) : Color.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func cueCoverageFooter(phrases: [String], isAIClone: Bool) -> some View {
        if phrases.isEmpty {
            Text("All cues in this song use studio recordings. Click Test to audition.")
                .font(.system(size: 9.5))
                .foregroundColor(Color(white: 0.54))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(isAIClone ? "Cloning" : "Fallback used for") \(phrases.count) custom \(phrases.count == 1 ? "cue" : "cues") in this song:")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(white: 0.60))

                HStack(spacing: 4) {
                    ForEach(Array(phrases.prefix(3)), id: \.self) { cue in
                        Button(action: {
                            triggerFallbackPreview(cue)
                        }) {
                            Text(cue)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(Color(white: 0.88))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.09))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Click to audition \"\(cue)\"")
                    }

                    if phrases.count > 3 {
                        Text("+\(phrases.count - 3) more")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(white: 0.55))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
