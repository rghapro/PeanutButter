import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let initialLargeWindowKey = "PeanutButter_InitialLargeWindowApplied_v1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
        expandMainWindowOnFirstLargeLaunchIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.expandMainWindowOnFirstLargeLaunchIfNeeded()
            MainActor.assumeIsolated {
                AppUpdateManager.shared.promptMoveToApplicationsIfNeeded()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppUpdateManager.shared.performPendingInstallOnQuitIfNeeded()
        }
    }

    private func expandMainWindowOnFirstLargeLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.initialLargeWindowKey) else { return }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else {
            return
        }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            window.setFrame(visible, display: true, animate: false)
        } else {
            window.setContentSize(NSSize(width: 1480, height: 920))
            window.center()
        }
        UserDefaults.standard.set(true, forKey: Self.initialLargeWindowKey)
    }
}

@main
struct PeanutButterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { @MainActor in
                        AppUpdateManager.shared.checkForUpdates(manual: true)
                    }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackUndo"), object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Redo") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackRedo"), object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackNewSession"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("Open Session...") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackOpenSession"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Session") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackSaveSession"), object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Divider()
                
                Button("Export Song Package (.pbsong)...") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackExportSong"), object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                
                Button("Import Song Package (.pbsong)...") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackImportSong"), object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Add / Remove Song Sections...") {
                    NotificationCenter.default.post(name: NSNotification.Name("PlaybackToggleEditSections"), object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
