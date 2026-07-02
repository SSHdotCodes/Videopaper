import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WallpaperStore: ObservableObject {
    @Published private(set) var displays: [DisplayInfo]
    @Published var selection: DisplaySelection? = .all
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Choose a source, select displays, then apply."
    @Published private(set) var videoMetadata: VideoMetadata?

    @Published var settings: WallpaperSettings {
        didSet {
            persistSettings()

            if settings.defaultProfile.sourceMode != oldValue.defaultProfile.sourceMode ||
                settings.defaultProfile.videoPath != oldValue.defaultProfile.videoPath {
                refreshVideoMetadata()
            }

            if isRunning {
                controller.apply(settings: settings, displays: displays)
            }
        }
    }

    private let controller = WallpaperController()
    private let defaultsKey = "Videopaper.Settings.v1"
    private var screenObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var workspaceScreensWakeObserver: NSObjectProtocol?
    private var metadataTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var didProcessLaunchPreference = false

    init() {
        displays = DisplayInfo.current()
        settings = Self.loadSettings(defaultsKey: defaultsKey)
        settings.reconcileDisplayIDs(for: displays, defaultToAll: true)
        persistSettings()
        refreshVideoMetadata()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDisplayRefresh()
            }
        }

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDisplayRefresh(after: [1_000_000_000, 3_000_000_000, 6_000_000_000])
            }
        }

        workspaceScreensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDisplayRefresh(after: [750_000_000, 2_500_000_000, 5_000_000_000])
            }
        }
    }

    deinit {
        metadataTask?.cancel()
        displayRefreshTask?.cancel()

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }

        if let workspaceScreensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceScreensWakeObserver)
        }
    }

    var selectedVideoURL: URL? {
        settings.defaultProfile.selectedVideoURL
    }

    var selectedDisplay: DisplayInfo? {
        guard case let .display(id) = selection else {
            return nil
        }

        return displays.first { $0.id == id }
    }

    func set<Value>(_ value: Value, for keyPath: WritableKeyPath<WallpaperSettings, Value>) {
        var copy = settings
        copy[keyPath: keyPath] = value
        settings = copy
    }

    func updateSettings(_ update: (inout WallpaperSettings) -> Void) {
        var copy = settings
        update(&copy)
        settings = copy
    }

    func defaultProfileBinding<Value>(_ keyPath: WritableKeyPath<WallpaperProfile, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings.defaultProfile[keyPath: keyPath] },
            set: { self.setDefaultProfile($0, for: keyPath) }
        )
    }

    func displayProfileBinding<Value>(_ display: DisplayInfo, _ keyPath: WritableKeyPath<WallpaperProfile, Value>) -> Binding<Value> {
        Binding(
            get: { self.profile(for: display)[keyPath: keyPath] },
            set: { self.setDisplayProfileValue($0, for: display, keyPath) }
        )
    }

    func profile(for display: DisplayInfo) -> WallpaperProfile {
        settings.profile(for: display.id)
    }

    func usesCustomProfile(_ display: DisplayInfo) -> Bool {
        settings.usesCustomProfile(for: display.id)
    }

    func setDefaultProfile<Value>(_ value: Value, for keyPath: WritableKeyPath<WallpaperProfile, Value>) {
        updateSettings { settings in
            settings.defaultProfile[keyPath: keyPath] = value
        }
    }

    func setDisplayProfileValue<Value>(_ value: Value, for display: DisplayInfo, _ keyPath: WritableKeyPath<WallpaperProfile, Value>) {
        updateSettings { settings in
            var profile = settings.profile(for: display.id)
            profile[keyPath: keyPath] = value
            settings.setProfile(profile, for: display.id)
            settings.enabledDisplayIDs.insert(display.id)
        }
    }

    func setUsesCustomProfile(_ display: DisplayInfo, enabled: Bool) {
        updateSettings { settings in
            if enabled {
                settings.setProfile(settings.profile(for: display.id), for: display.id)
                settings.enabledDisplayIDs.insert(display.id)
            } else {
                settings.removeProfile(for: display.id)
            }
        }
    }

    func isDisplayEnabled(_ display: DisplayInfo) -> Bool {
        settings.enabledDisplayIDs.contains(display.id)
    }

    func setDisplay(_ display: DisplayInfo, enabled: Bool) {
        updateSettings { settings in
            if enabled {
                settings.enabledDisplayIDs.insert(display.id)
            } else {
                settings.enabledDisplayIDs.remove(display.id)
            }
        }
    }

    func enableAllDisplays() {
        updateSettings { settings in
            settings.enabledDisplayIDs = Set(displays.map(\.id))
        }
    }

    func disableAllDisplays() {
        updateSettings { settings in
            settings.enabledDisplayIDs.removeAll()
        }
    }

    func chooseVideo(for display: DisplayInfo? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose Video Wallpaper"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .movie,
            .video,
            .mpeg4Movie,
            .quickTimeMovie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]

        if panel.runModal() == .OK, let url = panel.url {
            setVideo(url, for: display)
        }
    }

    func setVideo(_ url: URL, for display: DisplayInfo? = nil) {
        updateSettings { settings in
            if let display {
                var profile = settings.profile(for: display.id)
                profile.sourceMode = .video
                profile.videoPath = url.path
                profile.loopVideo = true
                settings.setProfile(profile, for: display.id)
                settings.enabledDisplayIDs.insert(display.id)
            } else {
                settings.sourceMode = .video
                settings.videoPath = url.path
                settings.loopVideo = true
            }
        }

        if let display {
            statusMessage = "Video selected for \(display.name): \(url.lastPathComponent)"
        } else {
            statusMessage = "Video selected: \(url.lastPathComponent)"
        }
    }

    func selectedVideoURL(for display: DisplayInfo? = nil) -> URL? {
        guard let display else {
            return selectedVideoURL
        }

        return profile(for: display).selectedVideoURL
    }

    func revealVideoInFinder(for display: DisplayInfo? = nil) {
        guard let url = selectedVideoURL(for: display) else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func apply() {
        refreshDisplays()

        let activeDisplayCount = displays.filter { settings.enabledDisplayIDs.contains($0.id) }.count

        guard activeDisplayCount > 0 else {
            statusMessage = "Enable at least one connected display before applying."
            return
        }

        for display in displays where settings.enabledDisplayIDs.contains(display.id) {
            let profile = settings.profile(for: display.id)

            if profile.sourceMode == .video {
                guard let url = profile.selectedVideoURL, FileManager.default.fileExists(atPath: url.path) else {
                    statusMessage = "Choose a video for \(display.name) before applying."
                    return
                }
            }
        }

        controller.apply(settings: settings, displays: displays)
        isRunning = true

        let count = activeDisplayCount
        statusMessage = count == 1 ? "Wallpaper applied to 1 display." : "Wallpaper applied to \(count) displays."
    }

    func stop() {
        controller.stop()
        isRunning = false
        statusMessage = "Wallpaper stopped."
    }

    func applySavedWallpaperIfNeeded() {
        guard !didProcessLaunchPreference else {
            return
        }

        didProcessLaunchPreference = true

        if settings.applyOnLaunch {
            apply()
        }
    }

    private func refreshDisplays() {
        displays = DisplayInfo.current()
        settings.reconcileDisplayIDs(for: displays, defaultToAll: false)

        if case let .display(id) = selection, !displays.contains(where: { $0.id == id }) {
            selection = .all
        }

        if isRunning {
            controller.apply(settings: settings, displays: displays)
        }
    }

    private func scheduleDisplayRefresh(after delays: [UInt64] = [250_000_000, 1_250_000_000]) {
        displayRefreshTask?.cancel()

        displayRefreshTask = Task { [weak self] in
            var elapsed: UInt64 = 0

            for delay in delays {
                let sleepDuration = delay > elapsed ? delay - elapsed : 0
                elapsed = delay

                if sleepDuration > 0 {
                    try? await Task.sleep(nanoseconds: sleepDuration)
                }

                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    self?.refreshDisplays()
                }
            }
        }
    }

    private func refreshVideoMetadata() {
        metadataTask?.cancel()

        guard settings.sourceMode == .video, let selectedVideoURL else {
            videoMetadata = nil
            return
        }

        let url = selectedVideoURL
        metadataTask = Task { [weak self] in
            let metadata = await VideopaperFormatters.metadata(for: url)

            await MainActor.run {
                guard let self, self.selectedVideoURL == url else {
                    return
                }

                self.videoMetadata = metadata
            }
        }
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadSettings(defaultsKey: String) -> WallpaperSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(WallpaperSettings.self, from: data) else {
            return WallpaperSettings()
        }

        return settings
    }
}
