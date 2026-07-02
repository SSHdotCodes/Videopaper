import AppKit
import QuartzCore

/// Ambient scenes animate slowly; 60 fps is visually equivalent to panel
/// refresh while halving compositor work on 120 Hz ProMotion displays.
extension CAAnimation {
    func atWallpaperFrameRate() -> Self {
        preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        return self
    }
}

@MainActor
final class AmbientSceneRenderer {
    private weak var hostLayer: CALayer?
    private weak var dimmingLayer: CALayer?
    private var sceneLayer: CALayer?
    private var currentStyle: AmbientStyle?
    private var currentSize: CGSize = .zero
    private var starEventTask: Task<Void, Never>?
    private var blackHole: BlackHoleRenderer?
    private var isPaused = false

    init(hostLayer: CALayer, dimmingLayer: CALayer) {
        self.hostLayer = hostLayer
        self.dimmingLayer = dimmingLayer
    }

    /// Pause live rendering while the wallpaper is fully occluded. CA-animated
    /// scenes cost nothing in-process (WindowServer culls covered windows), so
    /// only the Metal renderer and the star-event spawner need gating.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        blackHole?.setPaused(paused)
    }

    func show(style: AmbientStyle, bounds: CGRect) {
        guard let hostLayer, let dimmingLayer else {
            return
        }

        if currentStyle == style, currentSize == bounds.size {
            sceneLayer?.frame = bounds
            return
        }

        hide()

        let scene = CALayer()
        scene.frame = bounds
        scene.masksToBounds = true
        scene.backgroundColor = NSColor.black.cgColor
        AmbientSceneFactory.populate(scene, style: style, bounds: bounds)
        hostLayer.insertSublayer(scene, below: dimmingLayer)

        sceneLayer = scene
        currentStyle = style
        currentSize = bounds.size

        if style == .stars {
            startStarEvents(on: scene)
        } else if style == .blackHole {
            let scale = hostLayer.contentsScale > 0 ? hostLayer.contentsScale : 2.0
            if let renderer = BlackHoleRenderer() {
                renderer.setPaused(isPaused)
                renderer.attach(to: scene, bounds: bounds, scale: scale)
                blackHole = renderer
            }
        }
    }

    func layout(bounds: CGRect) {
        guard let currentStyle else {
            return
        }

        if currentSize == bounds.size {
            sceneLayer?.frame = bounds
        } else {
            show(style: currentStyle, bounds: bounds)
        }
    }

    func hide() {
        stopStarEvents()
        blackHole?.stop()
        blackHole = nil
        sceneLayer?.removeAllAnimations()
        sceneLayer?.removeFromSuperlayer()
        sceneLayer = nil
        currentStyle = nil
        currentSize = .zero
    }

    private func startStarEvents(on scene: CALayer) {
        stopStarEvents()

        starEventTask = Task { [weak self, weak scene] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)

                await MainActor.run {
                    guard let self,
                          let scene,
                          !Task.isCancelled,
                          !self.isPaused,
                          self.currentStyle == .stars,
                          self.sceneLayer === scene else {
                        return
                    }

                    if Int.random(in: 1...100) == 1 {
                        StarEventEffects.addPassingGalaxy(to: scene, bounds: scene.bounds)
                    }

                    if Int.random(in: 1...10_000) == 1 {
                        StarEventEffects.addSupernova(to: scene, bounds: scene.bounds)
                    }
                }
            }
        }
    }

    private func stopStarEvents() {
        starEventTask?.cancel()
        starEventTask = nil
    }
}

private enum AmbientSceneFactory {
    static func populate(_ root: CALayer, style: AmbientStyle, bounds: CGRect) {
        switch style {
        case .aurora:
            addAnimatedGradient(to: root, palette: gradientPalette(for: .aurora), bounds: bounds)
        case .stars:
            addStars(to: root, bounds: bounds, seed: 2_041)
        case .sunrise:
            addSky(to: root, scene: .sunrise, bounds: bounds, seed: 4_211)
        case .daylight:
            addSky(to: root, scene: .daylight, bounds: bounds, seed: 5_031)
        case .sunset:
            addSky(to: root, scene: .sunset, bounds: bounds, seed: 6_017)
        case .moonlight:
            addSky(to: root, scene: .moonlight, bounds: bounds, seed: 7_037)
        case .prism:
            addAnimatedGradient(to: root, palette: gradientPalette(for: .prism), bounds: bounds)
        case .ember:
            addAnimatedGradient(to: root, palette: gradientPalette(for: .ember), bounds: bounds)
        case .blackHole:
            break   // rendered live with Metal by AmbientSceneRenderer
        }
    }

    private static func addAnimatedGradient(to root: CALayer, palette: GradientPalette, bounds: CGRect) {
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = palette.startColors
        gradient.locations = [0.0, 0.48, 1.0]
        gradient.startPoint = CGPoint(x: 0.1, y: 0.1)
        gradient.endPoint = CGPoint(x: 0.95, y: 0.9)
        root.addSublayer(gradient)

        let colorAnimation = basicAnimation(
            keyPath: "colors",
            from: palette.startColors,
            to: palette.endColors,
            duration: 8.5
        )
        gradient.add(colorAnimation, forKey: "colors")

        let locationAnimation = basicAnimation(
            keyPath: "locations",
            from: [0.0, 0.42, 1.0],
            to: [0.0, 0.72, 1.0],
            duration: 11.0
        )
        gradient.add(locationAnimation, forKey: "locations")
    }

    private static func addStars(to root: CALayer, bounds: CGRect, seed: UInt64, includeBackground: Bool = true) {
        if includeBackground {
            let background = CAGradientLayer()
            background.frame = bounds
            background.colors = [
                color(0.005, 0.006, 0.018).cgColor,
                color(0.015, 0.026, 0.075).cgColor,
                color(0.03, 0.018, 0.05).cgColor
            ]
            background.locations = [0.0, 0.58, 1.0]
            background.startPoint = CGPoint(x: 0.1, y: 0.05)
            background.endPoint = CGPoint(x: 0.95, y: 0.95)
            root.addSublayer(background)

            let glow = CAGradientLayer()
            glow.type = .radial
            glow.frame = bounds.insetBy(dx: -bounds.width * 0.15, dy: -bounds.height * 0.15)
            glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
            glow.colors = [
                color(0.16, 0.18, 0.34, 0.055).cgColor,
                color(0.035, 0.04, 0.12, 0.025).cgColor,
                color(0.0, 0.0, 0.0, 0.0).cgColor
            ]
            glow.locations = [0.0, 0.42, 1.0]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1.0, y: 1.0)
            root.addSublayer(glow)

            let nebula = basicAnimation(
                keyPath: "colors",
                from: background.colors ?? [],
                to: [
                    color(0.01, 0.01, 0.03).cgColor,
                    color(0.025, 0.032, 0.075).cgColor,
                    color(0.018, 0.026, 0.060).cgColor
                ],
                duration: 34
            )
            background.add(nebula, forKey: "nebula")

            let depthHaze = CAGradientLayer()
            depthHaze.type = .radial
            depthHaze.frame = bounds.insetBy(dx: -bounds.width * 0.28, dy: -bounds.height * 0.28)
            depthHaze.position = CGPoint(x: bounds.midX, y: bounds.midY)
            depthHaze.colors = [
                color(0.84, 0.90, 1.0, 0.065).cgColor,
                color(0.22, 0.16, 0.42, 0.030).cgColor,
                color(0.0, 0.0, 0.0, 0.0).cgColor
            ]
            depthHaze.locations = [0.0, 0.26, 1.0]
            depthHaze.startPoint = CGPoint(x: 0.5, y: 0.5)
            depthHaze.endPoint = CGPoint(x: 1.0, y: 1.0)
            root.addSublayer(depthHaze)

            addDistantGalaxies(to: root, bounds: bounds, seed: seed + 9_017)
            addAndromedaGalaxy(to: root, bounds: bounds, seed: seed + 4_409)
        }

        let area = bounds.width * bounds.height
        addStarSheet(
            to: root,
            bounds: bounds,
            seed: seed,
            count: Int(max(420, min(1_000, area / 3_900))),
            radiusRange: 0.24...0.72,
            alphaRange: 0.36...0.82,
            opacity: includeBackground ? 0.62 : 0.36,
            scaleFrom: includeBackground ? 0.96 : 0.98,
            scaleTo: includeBackground ? 1.055 : 1.03,
            duration: includeBackground ? 142 : 180,
            phase: 19.0,
            copies: includeBackground ? 2 : 1,
            minimumOpacityRatio: 0.92
        )
        addStarSheet(
            to: root,
            bounds: bounds,
            seed: seed + 113,
            count: Int(max(260, min(620, area / 6_700))),
            radiusRange: 0.42...1.10,
            alphaRange: 0.42...0.92,
            opacity: includeBackground ? 0.78 : 0.46,
            scaleFrom: includeBackground ? 0.90 : 0.96,
            scaleTo: includeBackground ? 1.17 : 1.07,
            duration: includeBackground ? 86 : 128,
            phase: 7.0,
            copies: includeBackground ? 3 : 2,
            minimumOpacityRatio: 0.78
        )
        addStarSheet(
            to: root,
            bounds: bounds,
            seed: seed + 337,
            count: Int(max(130, min(320, area / 13_200))),
            radiusRange: 0.78...1.95,
            alphaRange: 0.52...1.0,
            opacity: includeBackground ? 0.92 : 0.52,
            scaleFrom: includeBackground ? 0.82 : 0.94,
            scaleTo: includeBackground ? 1.34 : 1.10,
            duration: includeBackground ? 48 : 102,
            phase: 15.0,
            copies: includeBackground ? 3 : 2,
            minimumOpacityRatio: 0.70
        )
        addStarSheet(
            to: root,
            bounds: bounds,
            seed: seed + 691,
            count: Int(max(38, min(96, area / 38_000))),
            radiusRange: 1.45...3.05,
            alphaRange: 0.72...1.0,
            opacity: includeBackground ? 0.82 : 0.36,
            scaleFrom: includeBackground ? 0.74 : 0.92,
            scaleTo: includeBackground ? 1.58 : 1.12,
            duration: includeBackground ? 27 : 86,
            phase: 4.0,
            copies: includeBackground ? 3 : 1,
            minimumOpacityRatio: 0.58
        )
    }

    private static func addSky(to root: CALayer, scene: SkyScene, bounds: CGRect, seed: UInt64) {
        let palette = skyPalette(for: scene)
        let sky = CAGradientLayer()
        sky.frame = bounds
        sky.colors = palette.startColors
        sky.locations = palette.locations
        sky.startPoint = CGPoint(x: 0.35, y: 0.0)
        sky.endPoint = CGPoint(x: 0.72, y: 1.0)
        root.addSublayer(sky)

        let skyAnimation = basicAnimation(
            keyPath: "colors",
            from: palette.startColors,
            to: palette.endColors,
            duration: palette.colorDuration
        )
        sky.add(skyAnimation, forKey: "skyColors")

        if scene == .moonlight {
            addStars(to: root, bounds: bounds, seed: seed + 11, includeBackground: false)
            sky.opacity = 0.72
        }

        addCelestialBody(to: root, scene: scene, palette: palette, bounds: bounds)
        addHorizon(to: root, palette: palette, bounds: bounds)
        addClouds(to: root, scene: scene, bounds: bounds, seed: seed)
    }

    private static func addCelestialBody(to root: CALayer, scene: SkyScene, palette: SkyPalette, bounds: CGRect) {
        let bodyDiameter = max(120, min(bounds.width, bounds.height) * palette.bodyScale)
        let center = CGPoint(x: bounds.width * palette.bodyPosition.x, y: bounds.height * palette.bodyPosition.y)

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(
            x: center.x - bodyDiameter * 1.75,
            y: center.y - bodyDiameter * 1.75,
            width: bodyDiameter * 3.5,
            height: bodyDiameter * 3.5
        )
        glow.colors = [
            palette.glowColor.withAlphaComponent(0.42).cgColor,
            palette.glowColor.withAlphaComponent(0.16).cgColor,
            palette.glowColor.withAlphaComponent(0.0).cgColor
        ]
        glow.locations = [0.0, 0.45, 1.0]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 1.0)
        root.addSublayer(glow)

        let body = CALayer()
        body.frame = CGRect(
            x: center.x - bodyDiameter / 2,
            y: center.y - bodyDiameter / 2,
            width: bodyDiameter,
            height: bodyDiameter
        )
        body.cornerRadius = bodyDiameter / 2
        body.backgroundColor = palette.bodyColor.cgColor
        body.shadowColor = palette.glowColor.cgColor
        body.shadowRadius = bodyDiameter * 0.25
        body.shadowOpacity = 0.8
        body.shadowOffset = .zero
        root.addSublayer(body)

        if scene == .moonlight {
            let cutout = CALayer()
            cutout.frame = body.bounds.offsetBy(dx: bodyDiameter * 0.22, dy: bodyDiameter * 0.08)
            cutout.cornerRadius = bodyDiameter / 2
            cutout.backgroundColor = color(0.015, 0.026, 0.075).cgColor
            body.addSublayer(cutout)
        }

        let float = basicAnimation(
            keyPath: "position.y",
            from: center.y - 10,
            to: center.y + 12,
            duration: scene == .daylight ? 34 : 26
        )
        body.add(float, forKey: "bodyFloat")
        glow.add(float.copy() as! CAAnimation, forKey: "glowFloat")
    }

    private static func addHorizon(to root: CALayer, palette: SkyPalette, bounds: CGRect) {
        let haze = CAGradientLayer()
        haze.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.36)
        haze.colors = palette.horizonColors
        haze.locations = [0.0, 0.55, 1.0]
        haze.startPoint = CGPoint(x: 0.5, y: 0.0)
        haze.endPoint = CGPoint(x: 0.5, y: 1.0)
        root.addSublayer(haze)

        let wave = basicAnimation(
            keyPath: "locations",
            from: [0.0, 0.44, 1.0],
            to: [0.0, 0.72, 1.0],
            duration: 42
        )
        haze.add(wave, forKey: "horizonBreath")
    }

    private static func addClouds(to root: CALayer, scene: SkyScene, bounds: CGRect, seed: UInt64) {
        var generator = SeededRandomGenerator(seed: seed)
        let cloudCount = scene == .moonlight ? 3 : 5
        let cloudColor = cloudColor(for: scene)
        let yRange: ClosedRange<CGFloat> = scene == .daylight ? 0.52...0.82 : 0.34...0.66

        for index in 0..<cloudCount {
            let width = random(bounds.width * 0.20...bounds.width * 0.42, using: &generator)
            let height = width * random(0.18...0.34, using: &generator)
            let cloud = makeCloud(width: width, height: height, color: cloudColor.withAlphaComponent(random(0.12...0.30, using: &generator)))
            let y = bounds.height * random(yRange, using: &generator)
            let x = random(-width * 0.2...bounds.width + width * 0.2, using: &generator)
            cloud.position = CGPoint(x: x, y: y)
            cloud.opacity = Float(random(0.45...0.95, using: &generator))
            root.addSublayer(cloud)

            let drift = basicAnimation(
                keyPath: "position.x",
                from: x - bounds.width * random(0.12...0.24, using: &generator),
                to: x + bounds.width * random(0.16...0.30, using: &generator),
                duration: CFTimeInterval(random(28...58, using: &generator)),
                beginOffset: CFTimeInterval(index) * 2.7
            )
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            cloud.add(drift, forKey: "cloudDrift")
        }
    }

    private static func makeCloud(width: CGFloat, height: CGFloat, color: NSColor) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.contents = makeCloudImage(width: width, height: height, color: color)
        layer.contentsGravity = .resize
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        layer.drawsAsynchronously = true
        return layer
    }

    private static func addAndromedaGalaxy(to root: CALayer, bounds: CGRect, seed: UInt64) {
        let width = max(420, min(bounds.width * 0.76, 1_240))
        let size = CGSize(width: width, height: width * 0.46)

        guard let image = makeAndromedaGalaxyImage(size: size, seed: seed, starCount: 1_850, dustStrength: 0.0) else {
            return
        }

        let galaxyContainer = CALayer()
        galaxyContainer.bounds = CGRect(origin: .zero, size: size)
        galaxyContainer.position = CGPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.015)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 650.0
        galaxyContainer.sublayerTransform = perspective
        root.addSublayer(galaxyContainer)

        let galaxy = CALayer()
        galaxy.frame = galaxyContainer.bounds
        galaxy.contents = image
        galaxy.contentsGravity = .resize
        galaxy.minificationFilter = .linear
        galaxy.magnificationFilter = .linear
        galaxy.drawsAsynchronously = true
        galaxyContainer.addSublayer(galaxy)

        let yaw = CABasicAnimation(keyPath: "transform.rotation.y")
        yaw.fromValue = -0.10
        yaw.toValue = 0.48
        yaw.duration = 140
        yaw.autoreverses = true
        yaw.repeatCount = .infinity
        yaw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        galaxy.add(yaw.atWallpaperFrameRate(), forKey: "andromedaYaw")

        let approach = basicAnimation(
            keyPath: "transform.scale",
            from: 0.96,
            to: 1.075,
            duration: 96,
            beginOffset: 3
        )
        galaxyContainer.add(approach, forKey: "andromedaApproach")

        let breathingLight = basicAnimation(
            keyPath: "opacity",
            from: 0.88,
            to: 1.0,
            duration: 18,
            beginOffset: 1.5
        )
        galaxyContainer.opacity = 0.94
        galaxyContainer.add(breathingLight, forKey: "andromedaLight")
    }

    private static func addDistantGalaxies(to root: CALayer, bounds: CGRect, seed: UInt64) {
        var generator = SeededRandomGenerator(seed: seed)
        let count = max(7, min(14, Int((bounds.width * bounds.height) / 165_000)))
        let centerAvoidance = CGSize(width: bounds.width * 0.32, height: bounds.height * 0.22)

        for index in 0..<count {
            let width = random(max(34, bounds.width * 0.030)...max(58, bounds.width * 0.082), using: &generator)
            let size = CGSize(width: width, height: width * random(0.42...0.58, using: &generator))

            guard let image = makeAndromedaGalaxyImage(
                size: size,
                seed: seed + UInt64(index * 313 + 41),
                starCount: Int(random(110...260, using: &generator)),
                dustStrength: random(0.16...0.34, using: &generator)
            ) else {
                continue
            }

            var position = CGPoint(
                x: random(bounds.width * 0.05...bounds.width * 0.95, using: &generator),
                y: random(bounds.height * 0.08...bounds.height * 0.92, using: &generator)
            )

            if abs(position.x - bounds.midX) < centerAvoidance.width,
               abs(position.y - bounds.midY) < centerAvoidance.height {
                position.y = position.y < bounds.midY ? bounds.height * 0.14 : bounds.height * 0.86
            }

            let galaxy = CALayer()
            galaxy.bounds = CGRect(origin: .zero, size: size)
            galaxy.position = position
            galaxy.contents = image
            galaxy.contentsGravity = .resize
            galaxy.opacity = Float(random(0.34...0.72, using: &generator))
            galaxy.minificationFilter = .linear
            galaxy.magnificationFilter = .linear
            galaxy.drawsAsynchronously = true
            root.addSublayer(galaxy)

            let shimmer = basicAnimation(
                keyPath: "opacity",
                from: max(0.22, Double(galaxy.opacity) * 0.82),
                to: min(0.86, Double(galaxy.opacity) * 1.18),
                duration: CFTimeInterval(random(16...31, using: &generator)),
                beginOffset: CFTimeInterval(index) * 1.7
            )
            galaxy.add(shimmer, forKey: "distantGalaxyShimmer")
        }
    }

    private static func addStarSheet(
        to root: CALayer,
        bounds: CGRect,
        seed: UInt64,
        count: Int,
        radiusRange: ClosedRange<CGFloat>,
        alphaRange: ClosedRange<CGFloat>,
        opacity: Float,
        scaleFrom: CGFloat,
        scaleTo: CGFloat,
        duration: CFTimeInterval,
        phase: CFTimeInterval,
        copies: Int,
        minimumOpacityRatio: Float
    ) {
        // Pad the sheet only as far as its own zoom animation can pull edges
        // inward (scale < 1 shrinks the sheet, exposing the margin): the
        // required half-margin is dim*(1/scaleFrom - 1)/2. The old fixed 42%
        // padding over-allocated ~2.4x. Star count is scaled by the area
        // ratio below, so visible star density is unchanged; smaller sheets
        // also downscale less against the bitmap cap, so stars render
        // slightly sharper.
        let neededFraction = scaleFrom < 1 ? (1.0 / scaleFrom - 1.0) / 2 : 0.0
        let padFraction = neededFraction + 0.03
        let oldArea = (bounds.width + 2 * max(bounds.width, bounds.height) * 0.42)
            * (bounds.height + 2 * max(bounds.width, bounds.height) * 0.42)
        let padding = max(bounds.width, bounds.height) * padFraction
        let sheetFrame = bounds.insetBy(dx: -padding, dy: -padding)
        let densityCount = max(
            24,
            Int((CGFloat(count) * sheetFrame.width * sheetFrame.height / oldArea).rounded())
        )
        let copyCount = max(1, copies)
        let perCopyOpacity = min(opacity, opacity * 1.55 / Float(copyCount))
        let minimumOpacity = max(0.035, perCopyOpacity * minimumOpacityRatio)

        for index in 0..<copyCount {
            let copySeed = seed &+ (UInt64(index + 1) &* 0x9E37_79B9)
            let image = makeStarFieldImage(
                size: sheetFrame.size,
                starCount: densityCount,
                seed: copySeed,
                radiusRange: radiusRange,
                alphaRange: alphaRange
            )

            let layer = CALayer()
            layer.frame = sheetFrame
            layer.contents = image
            layer.contentsGravity = .resize
            layer.opacity = 0
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            layer.drawsAsynchronously = true
            root.addSublayer(layer)

            let offsetPhase = (phase + duration * CFTimeInterval(index) / CFTimeInterval(copyCount))
                .truncatingRemainder(dividingBy: duration)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = scaleFrom
            scale.toValue = scaleTo
            scale.duration = duration
            scale.timingFunction = CAMediaTimingFunction(name: .linear)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [
                0.0,
                max(minimumOpacity, perCopyOpacity * 0.82),
                min(perCopyOpacity + 0.055, 1.0),
                perCopyOpacity,
                0.0
            ]
            fade.keyTimes = [0.0, 0.06, 0.44, 0.88, 1.0]
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = duration
            group.repeatCount = .infinity
            group.timeOffset = offsetPhase
            group.isRemovedOnCompletion = false
            layer.add(group.atWallpaperFrameRate(), forKey: "starForwardDrift")
        }
    }

    private static func makeStarFieldImage(
        size: CGSize,
        starCount: Int,
        seed: UInt64,
        radiusRange: ClosedRange<CGFloat>,
        alphaRange: ClosedRange<CGFloat>
    ) -> CGImage? {
        guard let context = bitmapContext(size: size, maxPixelDimension: 2_800) else {
            return nil
        }

        var generator = SeededRandomGenerator(seed: seed)
        let rect = CGRect(origin: .zero, size: size)
        context.clear(rect)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineCap(.round)

        for _ in 0..<starCount {
            let radius = random(radiusRange, using: &generator)
            let alpha = random(alphaRange, using: &generator)
            let point = CGPoint(
                x: random(radius...(size.width - radius), using: &generator),
                y: random(radius...(size.height - radius), using: &generator)
            )

            let tintRoll = random(0...1, using: &generator)
            let starColor: NSColor
            if tintRoll < 0.10 {
                starColor = color(1.0, 0.90, 0.70, alpha)
            } else if tintRoll < 0.24 {
                starColor = color(0.76, 0.86, 1.0, alpha)
            } else {
                starColor = color(0.96, 0.98, 1.0, alpha)
            }

            if radius > 1.05 {
                let glowRadius = radius * random(2.4...3.6, using: &generator)
                context.setFillColor(starColor.withAlphaComponent(alpha * 0.115).cgColor)
                context.fillEllipse(in: CGRect(
                    x: point.x - glowRadius,
                    y: point.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                ))
            }

            context.setFillColor(starColor.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            if radius > 1.65 {
                let coreRadius = radius * 0.34
                context.setFillColor(NSColor.white.withAlphaComponent(alpha * 0.96).cgColor)
                context.fillEllipse(in: CGRect(
                    x: point.x - coreRadius,
                    y: point.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                ))
            }
        }

        return context.makeImage()
    }

    private static func makeAndromedaGalaxyImage(
        size: CGSize,
        seed: UInt64,
        starCount: Int,
        dustStrength: CGFloat
    ) -> CGImage? {
        guard let context = bitmapContext(size: size, maxPixelDimension: 1_700) else {
            return nil
        }

        var generator = SeededRandomGenerator(seed: seed)
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        let radius = size.width * 0.45
        let diskScale = max(0.20, min(0.34, size.height / max(size.width, 1) * 0.74))
        context.clear(rect)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.setBlendMode(.plusLighter)
        drawEllipticalGradient(
            in: context,
            center: center,
            radius: radius * 1.20,
            yScale: 0.50,
            colors: [
                color(0.20, 0.28, 0.62, 0.05).cgColor,
                color(0.18, 0.16, 0.36, 0.12).cgColor,
                color(0.02, 0.03, 0.08, 0.0).cgColor
            ],
            locations: [0.0, 0.42, 1.0]
        )
        drawEllipticalGradient(
            in: context,
            center: center,
            radius: radius,
            yScale: diskScale,
            colors: [
                color(1.0, 0.86, 0.55, 0.78).cgColor,
                color(0.72, 0.82, 1.0, 0.30).cgColor,
                color(0.28, 0.34, 0.78, 0.11).cgColor,
                color(0.0, 0.0, 0.0, 0.0).cgColor
            ],
            locations: [0.0, 0.22, 0.58, 1.0]
        )

        context.setBlendMode(.screen)
        let hazeCount = Int(max(280, min(1_100, size.width * 0.92)))
        for _ in 0..<hazeCount {
            let x = random(-radius...radius, using: &generator)
            let normalized = x / radius
            let laneWave = sin(normalized * CGFloat.pi * 3.6)
            let y = laneWave * size.height * 0.030 + random(-size.height * 0.070...size.height * 0.070, using: &generator)
            let point = CGPoint(x: center.x + x, y: center.y + y)
            let radialFalloff = max(0.0, 1.0 - abs(normalized))
            let width = random(size.width * 0.010...size.width * 0.035, using: &generator) * radialFalloff
            let height = random(size.height * 0.008...size.height * 0.030, using: &generator)
            let alpha = random(0.010...0.045, using: &generator) * radialFalloff

            context.setFillColor(color(0.55, 0.66, 1.0, alpha).cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - width * 0.5,
                y: point.y - height * 0.5,
                width: max(0.8, width),
                height: max(0.6, height)
            ))
        }

        if dustStrength > 0.01 {
            context.setBlendMode(.normal)
            let dustCount = Int(max(18, min(220, size.width * 0.24 * dustStrength)))
            for lane in 0..<3 {
                let laneOffset = (CGFloat(lane) - 1.0) * size.height * 0.035

                for _ in 0..<dustCount {
                    let x = random(-radius * 0.88...radius * 0.88, using: &generator)
                    let normalized = x / radius
                    let falloff = max(0.0, 1.0 - abs(normalized) * 0.62)
                    let y = center.y + laneOffset +
                        sin(normalized * CGFloat.pi * 3.2 + CGFloat(lane) * 0.58) * size.height * 0.015 +
                        random(-size.height * 0.018...size.height * 0.018, using: &generator)
                    let width = random(size.width * 0.008...size.width * 0.028, using: &generator) * falloff
                    let height = random(size.height * 0.008...size.height * 0.024, using: &generator)
                    let alpha = random(0.010...0.040, using: &generator) * dustStrength * falloff

                    context.setFillColor(color(0.12, 0.10, 0.16, alpha).cgColor)
                    context.fillEllipse(in: CGRect(
                        x: center.x + x - width * 0.5,
                        y: y - height * 0.5,
                        width: max(0.6, width),
                        height: max(0.4, height)
                    ))
                }
            }
        }

        context.setBlendMode(.plusLighter)
        for _ in 0..<starCount {
            let distance = CGFloat(pow(Double(random(0...1, using: &generator)), 0.56)) * radius
            let angle = random(0...(CGFloat.pi * 2), using: &generator)
            let armWave = sin(cos(angle) * CGFloat.pi * 4.2 + random(-0.4...0.4, using: &generator))
            let point = CGPoint(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance * diskScale + armWave * size.height * 0.010
            )

            guard rect.insetBy(dx: -2, dy: -2).contains(point) else {
                continue
            }

            let radial = distance / radius
            let starRadius = random(0.28...1.18, using: &generator) * max(0.42, 1.18 - radial * 0.52)
            let alpha = random(0.050...0.34, using: &generator) * max(0.24, 1.0 - radial * 0.45)
            let tint = random(0...1, using: &generator)

            if tint < 0.18 {
                context.setFillColor(color(1.0, 0.82, 0.50, alpha).cgColor)
            } else if tint < 0.56 {
                context.setFillColor(color(0.70, 0.82, 1.0, alpha).cgColor)
            } else {
                context.setFillColor(color(0.92, 0.96, 1.0, alpha).cgColor)
            }

            context.fillEllipse(in: CGRect(
                x: point.x - starRadius,
                y: point.y - starRadius,
                width: starRadius * 2,
                height: starRadius * 2
            ))
        }

        drawEllipticalGradient(
            in: context,
            center: center,
            radius: radius * 0.28,
            yScale: 0.70,
            colors: [
                color(1.0, 0.94, 0.70, 0.96).cgColor,
                color(1.0, 0.74, 0.42, 0.34).cgColor,
                color(0.0, 0.0, 0.0, 0.0).cgColor
            ],
            locations: [0.0, 0.32, 1.0]
        )

        context.setBlendMode(.normal)
        return context.makeImage()
    }

    private static func drawEllipticalGradient(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        yScale: CGFloat,
        colors: [CGColor],
        locations: [CGFloat]
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else {
            return
        }

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1.0, y: yScale)
        context.translateBy(x: -center.x, y: -center.y)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func makeCloudImage(width: CGFloat, height: CGFloat, color: NSColor) -> CGImage? {
        guard let context = bitmapContext(size: CGSize(width: width, height: height), maxPixelDimension: 1_100) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let shadowColor = color.withAlphaComponent(0.08).cgColor
        let lowerColor = color.withAlphaComponent(0.34).cgColor
        let bodyColor = color.withAlphaComponent(0.68).cgColor
        let highlightColor = NSColor.white.withAlphaComponent(0.055).cgColor

        let shadowRect = rect.insetBy(dx: width * 0.03, dy: height * 0.16)
        let baseRect = CGRect(x: width * 0.06, y: height * 0.38, width: width * 0.88, height: height * 0.30)
        let lobeRects = [
            CGRect(x: width * 0.13, y: height * 0.25, width: width * 0.30, height: height * 0.36),
            CGRect(x: width * 0.33, y: height * 0.14, width: width * 0.34, height: height * 0.48),
            CGRect(x: width * 0.58, y: height * 0.28, width: width * 0.28, height: height * 0.32)
        ]

        context.setFillColor(shadowColor)
        context.fillEllipse(in: shadowRect)

        context.setFillColor(lowerColor)
        context.fillEllipse(in: baseRect.offsetBy(dx: 0, dy: height * 0.06))

        context.setFillColor(bodyColor)
        context.fillEllipse(in: baseRect)

        for lobeRect in lobeRects {
            context.fillEllipse(in: lobeRect)
        }

        context.setFillColor(highlightColor)
        context.fillEllipse(in: CGRect(x: width * 0.26, y: height * 0.24, width: width * 0.46, height: height * 0.18))

        return context.makeImage()
    }

    private static func bitmapContext(size: CGSize, maxPixelDimension: CGFloat) -> CGContext? {
        let renderScale = min(1.0, maxPixelDimension / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * renderScale).rounded(.up)))
        let height = max(1, Int((size.height * renderScale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.scaleBy(x: renderScale, y: renderScale)
        return context
    }

    private static func gradientPalette(for style: AmbientStyle) -> GradientPalette {
        switch style {
        case .aurora:
            GradientPalette(
                startColors: [
                    color(0.03, 0.08, 0.15).cgColor,
                    color(0.08, 0.56, 0.44).cgColor,
                    color(0.24, 0.15, 0.52).cgColor
                ],
                endColors: [
                    color(0.02, 0.10, 0.20).cgColor,
                    color(0.18, 0.46, 0.92).cgColor,
                    color(0.05, 0.35, 0.28).cgColor
                ]
            )
        case .prism:
            GradientPalette(
                startColors: [
                    color(0.08, 0.09, 0.11).cgColor,
                    color(0.86, 0.22, 0.36).cgColor,
                    color(0.95, 0.74, 0.20).cgColor
                ],
                endColors: [
                    color(0.05, 0.08, 0.12).cgColor,
                    color(0.25, 0.62, 0.92).cgColor,
                    color(0.84, 0.26, 0.68).cgColor
                ]
            )
        case .ember:
            GradientPalette(
                startColors: [
                    color(0.11, 0.07, 0.05).cgColor,
                    color(0.95, 0.40, 0.16).cgColor,
                    color(0.48, 0.08, 0.14).cgColor
                ],
                endColors: [
                    color(0.07, 0.08, 0.12).cgColor,
                    color(0.98, 0.66, 0.23).cgColor,
                    color(0.26, 0.13, 0.34).cgColor
                ]
            )
        case .stars, .sunrise, .daylight, .sunset, .moonlight, .blackHole:
            GradientPalette(startColors: [], endColors: [])
        }
    }

    private static func skyPalette(for scene: SkyScene) -> SkyPalette {
        switch scene {
        case .sunrise:
            SkyPalette(
                startColors: [
                    color(0.08, 0.09, 0.24).cgColor,
                    color(0.52, 0.28, 0.62).cgColor,
                    color(0.98, 0.55, 0.34).cgColor,
                    color(1.00, 0.82, 0.44).cgColor
                ],
                endColors: [
                    color(0.16, 0.20, 0.42).cgColor,
                    color(0.74, 0.40, 0.68).cgColor,
                    color(1.00, 0.66, 0.40).cgColor,
                    color(0.96, 0.88, 0.58).cgColor
                ],
                locations: [0.0, 0.42, 0.72, 1.0],
                horizonColors: [
                    color(0.18, 0.13, 0.20, 0.60).cgColor,
                    color(0.95, 0.42, 0.25, 0.30).cgColor,
                    color(1.0, 0.74, 0.38, 0.0).cgColor
                ],
                bodyColor: color(1.0, 0.70, 0.32),
                glowColor: color(1.0, 0.48, 0.22),
                bodyPosition: CGPoint(x: 0.73, y: 0.29),
                bodyScale: 0.16,
                colorDuration: 36
            )
        case .daylight:
            SkyPalette(
                startColors: [
                    color(0.11, 0.45, 0.86).cgColor,
                    color(0.32, 0.72, 0.98).cgColor,
                    color(0.74, 0.92, 1.00).cgColor
                ],
                endColors: [
                    color(0.08, 0.40, 0.78).cgColor,
                    color(0.45, 0.78, 0.98).cgColor,
                    color(0.90, 0.98, 1.00).cgColor
                ],
                locations: [0.0, 0.60, 1.0],
                horizonColors: [
                    color(0.08, 0.24, 0.22, 0.44).cgColor,
                    color(0.52, 0.78, 0.66, 0.22).cgColor,
                    color(0.86, 0.96, 1.0, 0.0).cgColor
                ],
                bodyColor: color(1.0, 0.92, 0.42),
                glowColor: color(1.0, 0.86, 0.34),
                bodyPosition: CGPoint(x: 0.80, y: 0.76),
                bodyScale: 0.13,
                colorDuration: 48
            )
        case .sunset:
            SkyPalette(
                startColors: [
                    color(0.10, 0.08, 0.24).cgColor,
                    color(0.58, 0.18, 0.50).cgColor,
                    color(0.94, 0.28, 0.20).cgColor,
                    color(1.00, 0.62, 0.24).cgColor
                ],
                endColors: [
                    color(0.03, 0.04, 0.12).cgColor,
                    color(0.34, 0.16, 0.48).cgColor,
                    color(0.86, 0.26, 0.30).cgColor,
                    color(0.98, 0.48, 0.20).cgColor
                ],
                locations: [0.0, 0.36, 0.70, 1.0],
                horizonColors: [
                    color(0.06, 0.04, 0.08, 0.64).cgColor,
                    color(0.68, 0.12, 0.22, 0.28).cgColor,
                    color(1.0, 0.38, 0.16, 0.0).cgColor
                ],
                bodyColor: color(1.0, 0.48, 0.20),
                glowColor: color(1.0, 0.28, 0.14),
                bodyPosition: CGPoint(x: 0.24, y: 0.30),
                bodyScale: 0.18,
                colorDuration: 34
            )
        case .moonlight:
            SkyPalette(
                startColors: [
                    color(0.01, 0.02, 0.06, 0.68).cgColor,
                    color(0.04, 0.09, 0.20, 0.72).cgColor,
                    color(0.08, 0.14, 0.26, 0.60).cgColor
                ],
                endColors: [
                    color(0.0, 0.01, 0.04, 0.70).cgColor,
                    color(0.02, 0.06, 0.18, 0.76).cgColor,
                    color(0.07, 0.12, 0.24, 0.62).cgColor
                ],
                locations: [0.0, 0.62, 1.0],
                horizonColors: [
                    color(0.0, 0.01, 0.03, 0.72).cgColor,
                    color(0.05, 0.10, 0.19, 0.28).cgColor,
                    color(0.08, 0.14, 0.26, 0.0).cgColor
                ],
                bodyColor: color(0.84, 0.90, 1.0),
                glowColor: color(0.54, 0.68, 1.0),
                bodyPosition: CGPoint(x: 0.24, y: 0.74),
                bodyScale: 0.12,
                colorDuration: 56
            )
        }
    }

    private static func cloudColor(for scene: SkyScene) -> NSColor {
        switch scene {
        case .sunrise:
            color(1.0, 0.72, 0.58)
        case .daylight:
            color(1.0, 1.0, 1.0)
        case .sunset:
            color(0.95, 0.46, 0.64)
        case .moonlight:
            color(0.42, 0.50, 0.66)
        }
    }

    private static func basicAnimation(
        keyPath: String,
        from: Any,
        to: Any,
        duration: CFTimeInterval,
        beginOffset: CFTimeInterval = 0
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + beginOffset
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation.atWallpaperFrameRate()
    }

    private static func random(_ range: ClosedRange<CGFloat>, using generator: inout SeededRandomGenerator) -> CGFloat {
        CGFloat(Double.random(in: Double(range.lowerBound)...Double(range.upperBound), using: &generator))
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private enum SkyScene {
    case sunrise
    case daylight
    case sunset
    case moonlight
}

private struct GradientPalette {
    let startColors: [CGColor]
    let endColors: [CGColor]
}

private struct SkyPalette {
    let startColors: [CGColor]
    let endColors: [CGColor]
    let locations: [NSNumber]
    let horizonColors: [CGColor]
    let bodyColor: NSColor
    let glowColor: NSColor
    let bodyPosition: CGPoint
    let bodyScale: CGFloat
    let colorDuration: CFTimeInterval
}

private struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension CGVector {
    var normalized: CGVector {
        let length = sqrt(dx * dx + dy * dy)

        guard length > 0 else {
            return CGVector(dx: 1, dy: 0)
        }

        return CGVector(dx: dx / length, dy: dy / length)
    }
}
