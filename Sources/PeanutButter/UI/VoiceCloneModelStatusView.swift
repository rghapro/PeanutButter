import SwiftUI

/// Shared status and download control view for the on-demand local LuxTTS voice cloning model.
struct VoiceCloneModelStatusView: View {
    enum LayoutStyle {
        case guidePopover
        case settingsMenu
    }

    let style: LayoutStyle
    let isFeatureActive: Bool
    let backupVoiceName: String?
    let onTestAction: (() -> Void)?
    let onRefreshAction: (() -> Void)?

    @ObservedObject private var modelManager = VoiceCloneModelManager.shared
    @AppStorage("voiceCloneRightsConfirmed") private var rightsConfirmed: Bool = false

    init(
        style: LayoutStyle,
        isFeatureActive: Bool = true,
        backupVoiceName: String? = nil,
        onTestAction: (() -> Void)? = nil,
        onRefreshAction: (() -> Void)? = nil
    ) {
        self.style = style
        self.isFeatureActive = isFeatureActive
        self.backupVoiceName = backupVoiceName
        self.onTestAction = onTestAction
        self.onRefreshAction = onRefreshAction
    }

    var body: some View {
        if VoiceCloneModelManager.isPlatformSupported {
            content
                .onAppear {
                    modelManager.refreshState()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch modelManager.state {
        case .unsupportedIntel:
            EmptyView()

        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                if style == .guidePopover {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("Model download required (~348 MB)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.orange.opacity(0.95))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let onTestAction {
                            inlineTestButton(action: onTestAction)
                        }
                    }

                    if let backupVoiceName, !backupVoiceName.isEmpty {
                        Text("Using \(backupVoiceName) until downloaded")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(white: 0.62))
                    }
                } else {
                    HStack {
                        Text("AI Voice Model (~348 MB)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(white: 0.78))
                        Spacer()
                        Text("Not Downloaded")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(Color.orange.opacity(0.95))
                    }
                }

                rightsConfirmationCheckbox

                downloadActionButton(title: "Download Model (~348 MB)", systemImage: "arrow.down.circle.fill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(style == .guidePopover ? 8 : 7)
            .background(style == .guidePopover ? Color(red: 0.10, green: 0.11, blue: 0.13) : Color(white: 0.14))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.28), lineWidth: style == .guidePopover ? 1 : 0)
            )

        case .downloading(let progress, let downloadedMB, let totalMB):
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Downloading AI Model...")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int(downloadedMB)) / \(Int(max(1, totalMB))) MB")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundColor(Color(white: 0.65))
                }

                ProgressView(value: min(1.0, max(0.0, progress)))
                    .progressViewStyle(.linear)
                    .tint(.cyan)

                HStack {
                    if style == .guidePopover, let backupVoiceName, !backupVoiceName.isEmpty {
                        Text("Using \(backupVoiceName) meanwhile")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(white: 0.60))
                    }
                    Spacer()
                    Button("Cancel") {
                        modelManager.cancelDownload()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.75))
                    .buttonStyle(.plain)
                }
            }
            .padding(style == .guidePopover ? 8 : 7)
            .background(style == .guidePopover ? Color(red: 0.10, green: 0.11, blue: 0.13) : Color(white: 0.14))
            .cornerRadius(6)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Download failed: \(message)")
                        .font(.system(size: 9.5))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if style == .guidePopover, let onTestAction {
                        inlineTestButton(action: onTestAction)
                    }
                }

                if !rightsConfirmed {
                    rightsConfirmationCheckbox
                }

                downloadActionButton(title: "Retry Download", systemImage: "arrow.clockwise")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(style == .guidePopover ? 8 : 7)
            .background(style == .guidePopover ? Color(red: 0.10, green: 0.11, blue: 0.13) : Color(white: 0.14))
            .cornerRadius(6)

        case .ready(let sizeMB):
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    if isFeatureActive && modelManager.isSynthesizing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 10, height: 10)
                        Text(style == .settingsMenu ? "Active · Generating..." : "Generating cloned cues...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.cyan)
                            .lineLimit(1)
                    } else {
                        Circle()
                            .fill(isFeatureActive ? Color.green : Color(white: 0.45))
                            .frame(width: 6, height: 6)
                        Text(
                            isFeatureActive
                                ? (style == .settingsMenu ? "Active · \(Int(sizeMB)) MB" : "AI Model Ready (\(Int(sizeMB)) MB)")
                                : "Installed (\(Int(sizeMB)) MB) · Off"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isFeatureActive ? Color(white: 0.85) : Color(white: 0.60))
                        .lineLimit(1)
                    }
                }

                Spacer()

                if let onRefreshAction {
                    Button(style == .guidePopover ? "Refresh Cues" : "Clear Cache") {
                        modelManager.clearClonedPhraseCache()
                        onRefreshAction()
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.cyan)
                    .buttonStyle(.plain)
                }

                Button("Delete") {
                    modelManager.deleteModel()
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.red.opacity(0.9))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(white: 0.14))
            .cornerRadius(6)
        }
    }

    private func inlineTestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8.5))
                Text("Test")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(white: 0.18))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(white: 0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Play a sample cue using the active fallback path")
    }

    private var rightsConfirmationCheckbox: some View {
        Button(action: {
            rightsConfirmed.toggle()
        }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: rightsConfirmed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(rightsConfirmed ? .cyan : Color(white: 0.6))
                    .padding(.top, 1)

                Text("I confirm I have the legal right and permission to clone any voice samples I use with this feature.")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(white: 0.78))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func downloadActionButton(title: String, systemImage: String) -> some View {
        Button(action: {
            guard rightsConfirmed else { return }
            modelManager.startDownload()
        }) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.cyan)
            .cornerRadius(5)
            .opacity(rightsConfirmed ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!rightsConfirmed)
    }
}
