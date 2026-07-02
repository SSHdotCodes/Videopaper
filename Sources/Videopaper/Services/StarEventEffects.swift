import AppKit
import QuartzCore

enum StarEventEffects {
    @MainActor
    static func addPassingGalaxy(to root: CALayer, bounds: CGRect) {
        let diameter = galaxyDiameter(for: bounds)
        let imageSize = CGSize(width: diameter, height: diameter)

        guard let image = makeSpiralGalaxyImage(size: imageSize, seed: UInt64.random(in: 1...UInt64.max)) else {
            return
        }

        let startsLeft = Bool.random()
        let y = CGFloat.random(in: bounds.height * 0.18...bounds.height * 0.78)
        let startX = startsLeft ? -diameter * 0.65 : bounds.width + diameter * 0.65
        let endX = startsLeft ? bounds.width + diameter * 0.65 : -diameter * 0.65
        let endY = y + CGFloat.random(in: -bounds.height * 0.16...bounds.height * 0.16)
        let duration = CFTimeInterval.random(in: 20...28)

        let galaxy = CALayer()
        galaxy.bounds = CGRect(origin: .zero, size: imageSize)
        galaxy.contents = image
        galaxy.contentsGravity = .resize
        galaxy.minificationFilter = .linear
        galaxy.magnificationFilter = .linear
        galaxy.opacity = 0
        galaxy.position = CGPoint(x: startX, y: y)
        root.addSublayer(galaxy)

        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: CGPoint(x: startX, y: y))
        travel.toValue = NSValue(point: CGPoint(x: endX, y: endY))
        travel.duration = duration
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.82, 0.72, 0.0]
        fade.keyTimes = [0.0, 0.18, 0.80, 1.0]
        fade.duration = duration

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = CGFloat.random(in: -0.5...0.5)
        rotation.toValue = CGFloat.random(in: 0.8...1.8) * (startsLeft ? 1 : -1)
        rotation.duration = duration

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = CGFloat.random(in: 0.68...0.86)
        scale.toValue = CGFloat.random(in: 1.04...1.26)
        scale.duration = duration

        let group = CAAnimationGroup()
        group.animations = [travel, fade, rotation, scale]
        group.duration = duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        galaxy.add(group.atWallpaperFrameRate(), forKey: "passingGalaxy")

        remove(galaxy, after: duration + 0.3)
    }

    @MainActor
    static func addSupernova(to root: CALayer, bounds: CGRect) {
        let diameter = max(140, min(bounds.width, bounds.height) * CGFloat.random(in: 0.16...0.28))
        let point = CGPoint(
            x: CGFloat.random(in: bounds.width * 0.14...bounds.width * 0.86),
            y: CGFloat.random(in: bounds.height * 0.18...bounds.height * 0.84)
        )
        let duration: CFTimeInterval = 4.8

        let burst = CAGradientLayer()
        burst.type = .radial
        burst.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        burst.position = point
        burst.colors = [
            color(1.0, 1.0, 0.92, 1.0).cgColor,
            color(0.70, 0.86, 1.0, 0.50).cgColor,
            color(0.32, 0.42, 0.96, 0.18).cgColor,
            color(0.0, 0.0, 0.0, 0.0).cgColor
        ]
        burst.locations = [0.0, 0.16, 0.42, 1.0]
        burst.startPoint = CGPoint(x: 0.5, y: 0.5)
        burst.endPoint = CGPoint(x: 1.0, y: 1.0)
        burst.opacity = 0
        root.addSublayer(burst)

        let ring = CAShapeLayer()
        ring.bounds = burst.bounds
        ring.position = point
        ring.path = CGPath(ellipseIn: burst.bounds.insetBy(dx: diameter * 0.16, dy: diameter * 0.16), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = color(0.86, 0.92, 1.0, 0.55).cgColor
        ring.lineWidth = max(2, diameter * 0.018)
        ring.opacity = 0
        root.addSublayer(ring)

        let burstGroup = animationGroup(
            animations: [
                basicAnimation("transform.scale", from: 0.06, to: 1.45, duration: duration),
                keyframeAnimation("opacity", values: [0.0, 1.0, 0.48, 0.0], keyTimes: [0.0, 0.10, 0.42, 1.0], duration: duration)
            ],
            duration: duration
        )
        burst.add(burstGroup, forKey: "supernovaBurst")

        let ringGroup = animationGroup(
            animations: [
                basicAnimation("transform.scale", from: 0.10, to: 2.8, duration: duration),
                keyframeAnimation("opacity", values: [0.0, 0.85, 0.16, 0.0], keyTimes: [0.0, 0.16, 0.70, 1.0], duration: duration)
            ],
            duration: duration
        )
        ring.add(ringGroup, forKey: "supernovaRing")

        remove(burst, after: duration + 0.2)
        remove(ring, after: duration + 0.2)
    }

    private static func makeSpiralGalaxyImage(size: CGSize, seed: UInt64) -> CGImage? {
        guard let context = bitmapContext(size: size, maxPixelDimension: 520) else {
            return nil
        }

        var generator = SeededRandomGenerator(seed: seed)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.45
        let rect = CGRect(origin: .zero, size: size)
        context.clear(rect)
        context.setBlendMode(.plusLighter)

        let colors = [
            color(1.0, 0.92, 0.72, 0.92).cgColor,
            color(0.54, 0.66, 1.0, 0.22).cgColor,
            color(0.0, 0.0, 0.0, 0.0).cgColor
        ] as CFArray

        if let coreGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.28, 1.0]) {
            context.drawRadialGradient(coreGradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        for arm in 0..<2 {
            let armOffset = CGFloat(arm) * CGFloat.pi

            for step in 0..<220 {
                let progress = CGFloat(step) / 219
                let angle = progress * CGFloat.pi * 4.2 + armOffset
                let spiralRadius = radius * progress
                let noise = random(-radius * 0.035...radius * 0.035, using: &generator)
                let point = CGPoint(
                    x: center.x + cos(angle) * (spiralRadius + noise),
                    y: center.y + sin(angle) * (spiralRadius * 0.42 + noise)
                )
                let dotRadius = max(0.7, (1 - progress) * 3.2 + random(0.0...1.2, using: &generator))
                let alpha = max(0.02, (1 - progress) * random(0.10...0.26, using: &generator))
                let dotRect = CGRect(x: point.x - dotRadius, y: point.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

                context.setFillColor(color(0.72, 0.80, 1.0, alpha).cgColor)
                context.fillEllipse(in: dotRect)
            }
        }

        context.setBlendMode(.normal)
        context.setFillColor(color(1.0, 0.96, 0.74, 0.80).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius * 0.08, y: center.y - radius * 0.08, width: radius * 0.16, height: radius * 0.16))

        return context.makeImage()
    }

    private static func animationGroup(animations: [CAAnimation], duration: CFTimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        return group.atWallpaperFrameRate()
    }

    private static func basicAnimation(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        return animation
    }

    private static func keyframeAnimation(_ keyPath: String, values: [Any], keyTimes: [Double], duration: CFTimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes.map(NSNumber.init(value:))
        animation.duration = duration
        return animation
    }

    private static func galaxyDiameter(for bounds: CGRect) -> CGFloat {
        let base = min(bounds.width, bounds.height)
        return max(90, min(220, base * CGFloat.random(in: 0.12...0.20)))
    }

    private static func remove(_ layer: CALayer, after seconds: CFTimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            layer.removeFromSuperlayer()
        }
    }

    private static func bitmapContext(size: CGSize, maxPixelDimension: CGFloat) -> CGContext? {
        let renderScale = min(1.0, maxPixelDimension / max(size.width, size.height, 1))
        let width = max(1, Int((size.width * renderScale).rounded(.up)))
        let height = max(1, Int((size.height * renderScale).rounded(.up)))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.scaleBy(x: renderScale, y: renderScale)
        return context
    }

    private static func random(_ range: ClosedRange<CGFloat>, using generator: inout SeededRandomGenerator) -> CGFloat {
        CGFloat(Double.random(in: Double(range.lowerBound)...Double(range.upperBound), using: &generator))
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
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
