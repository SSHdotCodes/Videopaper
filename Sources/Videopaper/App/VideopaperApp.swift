import AppKit
import SwiftUI

@main
struct VideopaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WallpaperStore()

    var body: some Scene {
        WindowGroup("Videopaper", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 660)
                .onAppear {
                    store.applySavedWallpaperIfNeeded()
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
