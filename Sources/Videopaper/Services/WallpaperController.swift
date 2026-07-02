import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class WallpaperController {
    private var windows: [String: DesktopWallpaperWindow] = [:]

    func apply(settings: WallpaperSettings, displays: [DisplayInfo]) {
        let enabledDisplays = displays.filter { settings.enabledDisplayIDs.contains($0.id) }
        let enabledIDs = Set(enabledDisplays.map(\.id))

        let staleWindowIDs = windows.keys.filter { !enabledIDs.contains($0) }

        for id in staleWindowIDs {
            windows[id]?.close()
            windows.removeValue(forKey: id)
        }

        for display in enabledDisplays {
            let profile = settings.profile(for: display.id)

            if let window = windows[display.id] {
                window.update(display: display, profile: profile)
                window.show()
            } else {
                let window = DesktopWallpaperWindow(display: display, profile: profile)
                windows[display.id] = window
                window.show()
            }
        }
    }

    func stop() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }
}

@MainActor
final class DesktopWallpaperWindow: NSWindow {
    private let wallpaperView = DesktopWallpaperView()
    private var occlusionObserver: NSObjectProtocol?

    init(display: DisplayInfo, profile: WallpaperProfile) {
        super.init(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        configureForDesktop()

        contentView = wallpaperView
        update(display: display, profile: profile)

        // Suspend all live work (Metal renderer, video decode) whenever the
        // wallpaper is fully covered — fullscreen apps, screen lock, sleep.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wallpaperView.setVisible(self.occlusionState.contains(.visible))
            }
        }
    }

    override func close() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        super.close()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        configureForDesktop()
        orderFrontRegardless()
    }

    func update(display: DisplayInfo, profile: WallpaperProfile) {
        configureForDesktop()
        setFrame(display.frame, display: true)
        wallpaperView.configure(profile: profile)
    }

    private func configureForDesktop() {
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none

        let desktopIconLevel = CGWindowLevelForKey(.desktopIconWindow)
        level = NSWindow.Level(rawValue: Int(desktopIconLevel) - 1)
    }
}

@MainActor
final class DesktopWallpaperView: NSView {
    private struct VideoRenderKey: Equatable {
        let url: URL
        let loop: Bool
        let renderLimit: RenderLimit
    }

    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var playerEndObserver: NSObjectProtocol?
    private var currentVideoKey: VideoRenderKey?
    private var currentPlaybackRate: Float = 1.0
    private let dimmingLayer = CALayer()
    private var ambientRenderer: AmbientSceneRenderer?
    private var isVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        dimmingLayer.frame = bounds
        dimmingLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(dimmingLayer)

        if let layer {
            ambientRenderer = AmbientSceneRenderer(hostLayer: layer, dimmingLayer: dimmingLayer)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        dimmingLayer.frame = bounds
        ambientRenderer?.layout(bounds: bounds)
    }

    /// Called from the window's occlusion observer. Pauses video decode and
    /// live Metal rendering while fully covered; resumes identically (same
    /// playback rate, same animation clock) when the desktop reappears.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        ambientRenderer?.setPaused(!visible)
        if visible {
            player?.playImmediately(atRate: currentPlaybackRate)
        } else {
            player?.pause()
        }
    }

    func configure(profile: WallpaperProfile) {
        dimmingLayer.opacity = Float(profile.dimming)
        // A fully transparent dimming layer still costs a full-screen blend
        // pass per frame in the compositor; drop it from the layer tree
        // entirely when dimming is off.
        dimmingLayer.isHidden = profile.dimming <= 0.001

        switch profile.sourceMode {
        case .ambient:
            showAmbient(style: profile.ambientStyle)
        case .video:
            guard let path = profile.videoPath else {
                showAmbient(style: profile.ambientStyle)
                return
            }

            showVideo(url: URL(fileURLWithPath: path), profile: profile)
        }
    }

    private func showAmbient(style: AmbientStyle) {
        clearPlayer()
        currentVideoKey = nil
        ambientRenderer?.show(style: style, bounds: bounds)
    }

    private func showVideo(url: URL, profile: WallpaperProfile) {
        ambientRenderer?.hide()
        currentPlaybackRate = Float(profile.playbackRate)

        let key = VideoRenderKey(url: url, loop: profile.loopVideo, renderLimit: profile.renderLimit)

        if currentVideoKey != key {
            clearPlayer()

            let item = AVPlayerItem(url: url)
            if let preferredMaximumResolution = profile.renderLimit.preferredMaximumResolution {
                item.preferredMaximumResolution = preferredMaximumResolution
            }

            let videoPlayer = AVPlayer(playerItem: item)

            let newPlayerLayer = AVPlayerLayer(player: videoPlayer)
            newPlayerLayer.frame = bounds
            newPlayerLayer.backgroundColor = NSColor.black.cgColor
            layer?.insertSublayer(newPlayerLayer, below: dimmingLayer)

            if profile.loopVideo {
                installEndObserver(for: item, player: videoPlayer, key: key)
            }

            player = videoPlayer
            playerLayer = newPlayerLayer
            currentVideoKey = key
        }

        playerLayer?.videoGravity = profile.fitMode.videoGravity
        player?.isMuted = profile.muted
        player?.volume = Float(profile.volume)
        if isVisible {
            player?.playImmediately(atRate: Float(profile.playbackRate))
        }
    }

    private func clearPlayer() {
        player?.pause()
        if let playerEndObserver {
            NotificationCenter.default.removeObserver(playerEndObserver)
            self.playerEndObserver = nil
        }
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    private func installEndObserver(for item: AVPlayerItem, player: AVPlayer, key: VideoRenderKey) {
        player.actionAtItemEnd = .pause

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.currentVideoKey == key else {
                    return
                }

                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.isVisible {
                    player.playImmediately(atRate: self.currentPlaybackRate)
                }
            }
        }
    }

}

private extension VideoFitMode {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill:
            .resizeAspectFill
        case .fit:
            .resizeAspect
        case .stretch:
            .resize
        }
    }
}
