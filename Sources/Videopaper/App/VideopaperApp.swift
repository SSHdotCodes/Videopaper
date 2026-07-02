import AppKit
import SwiftUI

@main
struct VideopaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WallpaperStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Videopaper", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 660)
                .onAppear {
                    store.applySavedWallpaperIfNeeded()
                    AppDelegate.openMainWindow = { openWindow(id: "main") }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandMenu("Wallpaper") {
                Button("Choose Video...") {
                    store.chooseVideo()
                }
                .keyboardShortcut("o")

                Divider()

                Button(store.isRunning ? "Refresh Wallpaper" : "Apply Wallpaper") {
                    store.apply()
                }
                .keyboardShortcut("r")

                Button("Stop Wallpaper") {
                    store.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.isRunning)
            }
        }

        MenuBarExtra("Videopaper", systemImage: "play.rectangle.on.rectangle") {
            Label(store.isRunning ? "Wallpaper Running" : "Wallpaper Stopped",
                  systemImage: store.isRunning ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(store.isRunning ? .green : .secondary)

            Divider()

            Button(store.isRunning ? "Refresh Wallpaper" : "Apply Wallpaper") {
                store.apply()
            }

            Button("Stop Wallpaper") {
                store.stop()
            }
            .disabled(!store.isRunning)

            Button("Choose Video...") {
                store.chooseVideo()
            }

            Divider()

            Button("Quit Videopaper") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the SwiftUI scene; opens (or focuses) the "main" WindowGroup window.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click / re-launch. The desktop wallpaper windows (and the menu
    /// bar item's window) always count as "visible windows", so AppKit passes
    /// hasVisibleWindows=true and never recreates the main window after the
    /// user closes it. Decide from the *real* UI windows instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let uiWindows = sender.windows.filter {
            !($0 is DesktopWallpaperWindow) && $0.canBecomeKey && $0.level == .normal
        }
        if let window = uiWindows.first(where: { $0.isVisible })
            ?? uiWindows.first(where: { $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            AppDelegate.openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}
