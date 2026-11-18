import SwiftUI
import AppKit

/// Sleek non-intrusive pill displayed at the top of the console when an update is available, downloading, or staged.
public struct AppUpdateTopBannerView: View {
    @ObservedObject var updateManager: AppUpdateManager

    public init(updateManager: AppUpdateManager) {
        self.updateManager = updateManager
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                updateManager.isUpdateSheetPresented = true
            }) {
                HStack(spacing: 8) {
                    bannerIcon
                    bannerText
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: {
                updateManager.remindMeLater()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(white: 0.65))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss for this session")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(Color(red: 0.08, green: 0.12, blue: 0.15).opacity(0.96))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
    }

    private var borderColor: Color {
        updateManager.isReadyToInstall
            ? Color(red: 0.25, green: 0.88, blue: 0.45).opacity(0.55)
            : Color.cyan.opacity(0.45)
    }

    @ViewBuilder
    private var bannerIcon: some View {
        switch updateManager.phase {
        case .readyToInstall:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
        case .downloading:
            ProgressView()
                .controlSize(.small)
        default:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.cyan)
        }
    }

    @ViewBuilder
    private var bannerText: some View {
        switch updateManager.phase {
        case .readyToInstall(let release, _, _):
            Text("Update Ready: v\(release.displayVersion) — Closes & updates automatically, or click to relaunch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .downloading(let release, let progress, _, _):
            let pct = Int((progress * 100).rounded())
            Text("Downloading PeanutButter v\(release.displayVersion) (\(pct)%)…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .available(let release):
            Text("Update Available: PeanutButter v\(release.displayVersion)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        default:
            EmptyView()
        }
    }
}

/// Centered dark console sheet for checking, downloading, and installing PeanutButter updates in place.
public struct AppUpdateModalView: View {
    @ObservedObject var updateManager: AppUpdateManager

    public init(updateManager: AppUpdateManager) {
        self.updateManager = updateManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(headerColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("Installed Version: v\(updateManager.currentVersion)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(white: 0.58))
                }
                Spacer()
                Button(action: {
                    updateManager.isUpdateSheetPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.48))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .background(Color(white: 0.22))

            phaseBodyView
                .padding(18)
        }
        .frame(width: 460)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 24, x: 0, y: 10)
    }

    private var headerIcon: String {
        switch updateManager.phase {
        case .readyToInstall: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .upToDate: return "checkmark.circle.fill"
        default: return "arrow.down.app.fill"
        }
    }

    private var headerColor: Color {
        switch updateManager.phase {
        case .readyToInstall, .upToDate: return Color(red: 0.25, green: 0.88, blue: 0.45)
        case .error: return Color(red: 0.96, green: 0.65, blue: 0.14)
        default: return .cyan
        }
    }

    private var headerTitle: String {
        switch updateManager.phase {
        case .checking: return "Checking for Updates…"
        case .upToDate: return "PeanutButter Is Up to Date"
        case .available: return "Software Update Available"
        case .downloading: return "Downloading Update…"
        case .readyToInstall: return "Update Ready to Install"
        case .installing: return "Installing Update…"
        case .error: return "Software Update"
        case .idle: return "Software Update"
        }
    }

    @ViewBuilder
    private var phaseBodyView: some View {
        switch updateManager.phase {
        case .idle, .checking:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Checking GitHub Releases (`\(AppUpdateManager.repoOwner)/\(AppUpdateManager.repoName)`)...")
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(white: 0.80))
                Spacer()
            }
            .padding(.vertical, 12)

        case .upToDate:
            VStack(alignment: .leading, spacing: 14) {
                Text("You're running the latest release of PeanutButter (v\(updateManager.currentVersion)).")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.86))

                HStack {
                    Button("Check Again") {
                        updateManager.checkForUpdates(manual: true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.20))
                    .cornerRadius(6)

                    Spacer()

                    Button("Done") {
                        updateManager.isUpdateSheetPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.cyan)
                    .cornerRadius(6)
                }
            }

        case .available(let release):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("v\(updateManager.currentVersion)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(white: 0.72))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(white: 0.20))
                        .cornerRadius(4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: 0.55))
                    Text("v\(release.displayVersion)")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.cyan)
                        .cornerRadius(4)
                    Spacer()
                }

                releaseNotesBox(release.releaseNotes)

                HStack(spacing: 8) {
                    Button("Skip This Version") {
                        updateManager.skipVersion(release)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.62))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Spacer()

                    Button("Remind Me Later") {
                        updateManager.remindMeLater()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.20))
                    .cornerRadius(6)

                    if release.zipAssetURL != nil {
                        Button("Download & Update") {
                            updateManager.downloadUpdate()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.cyan)
                        .cornerRadius(6)
                    } else {
                        Button("Open Release Page") {
                            updateManager.openReleasePageInBrowser()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.cyan)
                        .cornerRadius(6)
                    }
                }
            }

        case .downloading(let release, let progress, let receivedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 14) {
                Text("Downloading PeanutButter v\(release.displayVersion) in the background…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(white: 0.88))

                ProgressView(value: totalBytes > 0 ? progress : nil)
                    .progressViewStyle(.linear)
                    .tint(.cyan)

                HStack {
                    Text(formatByteProgress(received: receivedBytes, total: totalBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.62))
                    Spacer()
                    if totalBytes > 0 {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }

                HStack {
                    Text("Verifies code signature automatically after download.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.55))
                    Spacer()
                    Button("Cancel") {
                        updateManager.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.20))
                    .cornerRadius(6)
                }
            }

        case .readyToInstall(let release, _, _):
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.45))
                    Text("PeanutButter v\(release.displayVersion) is downloaded and verified. Closing the app will automatically install the new version in place — or click below to relaunch right now.")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color(red: 0.12, green: 0.22, blue: 0.16).opacity(0.55))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(red: 0.25, green: 0.88, blue: 0.45).opacity(0.35), lineWidth: 1)
                )

                if !release.releaseNotes.isEmpty {
                    releaseNotesBox(release.releaseNotes)
                }

                HStack(spacing: 8) {
                    Spacer()

                    Button("Finish Later (Update on Close)") {
                        updateManager.isUpdateSheetPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.20))
                    .cornerRadius(6)

                    Button("Install & Relaunch Now") {
                        updateManager.installAndRelaunchNow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.25, green: 0.88, blue: 0.45))
                    .cornerRadius(6)
                }
            }

        case .installing:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Installing update and relaunching PeanutButter…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 12)

        case .error(let message):
            VStack(alignment: .leading, spacing: 14) {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(white: 0.86))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Open GitHub Releases") {
                        updateManager.openReleasePageInBrowser()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.18))
                    .cornerRadius(6)

                    Spacer()

                    Button("Close") {
                        updateManager.isUpdateSheetPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.20))
                    .cornerRadius(6)

                    Button("Try Again") {
                        updateManager.checkForUpdates(manual: true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.cyan)
                    .cornerRadius(6)
                }
            }
        }
    }

    @ViewBuilder
    private func releaseNotesBox(_ notes: String) -> some View {
        let displayNotes = notes.isEmpty ? "No release notes provided." : notes
        ScrollView {
            Text(displayNotes)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.84))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .background(Color(red: 0.08, green: 0.09, blue: 0.10))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func formatByteProgress(received: Int64, total: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let recStr = fmt.string(fromByteCount: received)
        if total > 0 {
            let totStr = fmt.string(fromByteCount: total)
            return "\(recStr) / \(totStr)"
        }
        return recStr
    }
}
