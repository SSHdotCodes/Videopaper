import AppKit
import CoreGraphics
import Foundation

enum WallpaperSourceMode: String, Codable, CaseIterable, Identifiable {
    case ambient
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ambient: "Ambient Motion"
        case .video: "Video File"
        }
    }
}

enum AmbientStyle: String, Codable, CaseIterable, Identifiable {
    case aurora
    case stars
    case sunrise
    case daylight
    case sunset
    case moonlight
    case prism
    case ember
    case blackHole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .stars: "Stars"
        case .sunrise: "Sunrise"
        case .daylight: "Day"
        case .sunset: "Sunset"
        case .moonlight: "Moonlight"
        case .prism: "Prism"
        case .ember: "Ember"
        case .blackHole: "Black Hole"
        }
    }

    var subtitle: String {
        switch self {
        case .aurora: "Slow polar light waves"
        case .stars: "Deep-space drift and twinkle"
        case .sunrise: "Soft horizon glow"
        case .daylight: "Clear sky and drifting clouds"
        case .sunset: "Warm cinematic dusk"
        case .moonlight: "Quiet blue night sky"
        case .prism: "Color-shifting spectrum"
        case .ember: "Low molten warmth"
        case .blackHole: "Ray-traced gravitational lensing"
        }
    }

    var systemImage: String {
        switch self {
        case .aurora: "sparkles"
        case .stars: "star.fill"
        case .sunrise: "sunrise.fill"
        case .daylight: "sun.max.fill"
        case .sunset: "sunset.fill"
        case .moonlight: "moon.stars.fill"
        case .prism: "camera.filters"
        case .ember: "flame.fill"
        case .blackHole: "circle.circle.fill"
        }
    }

    /// Styles rendered live with Metal rather than Core Animation layers.
    var usesMetal: Bool { self == .blackHole }
}

enum VideoFitMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }
}

enum RenderLimit: String, Codable, CaseIterable, Identifiable {
    case p720
    case p1080
    case p1440
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .source: "Source"
        }
    }

    var preferredMaximumResolution: CGSize? {
        switch self {
        case .p720:
            CGSize(width: 1280, height: 720)
        case .p1080:
            CGSize(width: 1920, height: 1080)
        case .p1440:
            CGSize(width: 2560, height: 1440)
        case .source:
            nil
        }
    }
}

struct WallpaperProfile: Codable, Equatable {
    var sourceMode: WallpaperSourceMode = .ambient
    var ambientStyle: AmbientStyle = .aurora
    var videoPath: String?
    var loopVideo = true
    var muted = true
    var volume = 0.0
    var playbackRate = 1.0
    var fitMode: VideoFitMode = .fill
    var renderLimit: RenderLimit = .p1440
    var dimming = 0.12

    var selectedVideoURL: URL? {
        guard let videoPath, !videoPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: videoPath)
    }

    var summary: String {
        switch sourceMode {
        case .ambient:
            ambientStyle.title
        case .video:
            selectedVideoURL?.lastPathComponent ?? "No video selected"
        }
    }
}

struct WallpaperSettings: Codable, Equatable {
    var defaultProfile = WallpaperProfile()
    var displayProfiles: [String: WallpaperProfile] = [:]
    var enabledDisplayIDs: Set<String> = []
    var applyOnLaunch = false

    var sourceMode: WallpaperSourceMode {
        get { defaultProfile.sourceMode }
        set { defaultProfile.sourceMode = newValue }
    }

    var ambientStyle: AmbientStyle {
        get { defaultProfile.ambientStyle }
        set { defaultProfile.ambientStyle = newValue }
    }

    var videoPath: String? {
        get { defaultProfile.videoPath }
        set { defaultProfile.videoPath = newValue }
    }

    var loopVideo: Bool {
        get { defaultProfile.loopVideo }
        set { defaultProfile.loopVideo = newValue }
    }

    var muted: Bool {
        get { defaultProfile.muted }
        set { defaultProfile.muted = newValue }
    }

    var volume: Double {
        get { defaultProfile.volume }
        set { defaultProfile.volume = newValue }
    }

    var playbackRate: Double {
        get { defaultProfile.playbackRate }
        set { defaultProfile.playbackRate = newValue }
    }

    var fitMode: VideoFitMode {
        get { defaultProfile.fitMode }
        set { defaultProfile.fitMode = newValue }
    }

    var renderLimit: RenderLimit {
        get { defaultProfile.renderLimit }
        set { defaultProfile.renderLimit = newValue }
    }

    var dimming: Double {
        get { defaultProfile.dimming }
        set { defaultProfile.dimming = newValue }
    }

    init(
        defaultProfile: WallpaperProfile = WallpaperProfile(),
        displayProfiles: [String: WallpaperProfile] = [:],
        enabledDisplayIDs: Set<String> = [],
        applyOnLaunch: Bool = false
    ) {
        self.defaultProfile = defaultProfile
        self.displayProfiles = displayProfiles
        self.enabledDisplayIDs = enabledDisplayIDs
        self.applyOnLaunch = applyOnLaunch
    }

    func profile(for displayID: String) -> WallpaperProfile {
        displayProfiles[displayID] ?? defaultProfile
    }

    func usesCustomProfile(for displayID: String) -> Bool {
        displayProfiles[displayID] != nil
    }

    mutating func setProfile(_ profile: WallpaperProfile, for displayID: String) {
        displayProfiles[displayID] = profile
    }

    mutating func removeProfile(for displayID: String) {
        displayProfiles.removeValue(forKey: displayID)
    }

    mutating func reconcileDisplayIDs(for displays: [DisplayInfo], defaultToAll: Bool) {
        migrateLegacyDisplayIDs(for: displays)

        let currentIDs = Set(displays.map(\.id))

        guard defaultToAll, !currentIDs.isEmpty else {
            return
        }

        if enabledDisplayIDs.isEmpty {
            enabledDisplayIDs = currentIDs
        } else if enabledDisplayIDs.isDisjoint(with: currentIDs) {
            enabledDisplayIDs.formUnion(currentIDs)
        }
    }

    private mutating func migrateLegacyDisplayIDs(for displays: [DisplayInfo]) {
        for display in displays where display.legacyID != display.id {
            if let profile = displayProfiles.removeValue(forKey: display.legacyID),
               displayProfiles[display.id] == nil {
                displayProfiles[display.id] = profile
            }

            if enabledDisplayIDs.remove(display.legacyID) != nil {
                enabledDisplayIDs.insert(display.id)
            }
        }
    }
}

extension WallpaperSettings {
    private enum CodingKeys: String, CodingKey {
        case defaultProfile
        case displayProfiles
        case enabledDisplayIDs
        case applyOnLaunch
        case sourceMode
        case ambientStyle
        case videoPath
        case loopVideo
        case muted
        case volume
        case playbackRate
        case fitMode
        case renderLimit
        case dimming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let defaultProfile = try container.decodeIfPresent(WallpaperProfile.self, forKey: .defaultProfile) {
            self.defaultProfile = defaultProfile
        } else {
            defaultProfile = WallpaperProfile(
                sourceMode: try container.decodeIfPresent(WallpaperSourceMode.self, forKey: .sourceMode) ?? .ambient,
                ambientStyle: try container.decodeIfPresent(AmbientStyle.self, forKey: .ambientStyle) ?? .aurora,
                videoPath: try container.decodeIfPresent(String.self, forKey: .videoPath),
                loopVideo: try container.decodeIfPresent(Bool.self, forKey: .loopVideo) ?? true,
                muted: try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true,
                volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.0,
                playbackRate: try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1.0,
                fitMode: try container.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .fill,
                renderLimit: try container.decodeIfPresent(RenderLimit.self, forKey: .renderLimit) ?? .p1440,
                dimming: try container.decodeIfPresent(Double.self, forKey: .dimming) ?? 0.12
            )
        }

        displayProfiles = try container.decodeIfPresent([String: WallpaperProfile].self, forKey: .displayProfiles) ?? [:]
        enabledDisplayIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledDisplayIDs) ?? []
        applyOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .applyOnLaunch) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultProfile, forKey: .defaultProfile)
        try container.encode(displayProfiles, forKey: .displayProfiles)
        try container.encode(enabledDisplayIDs, forKey: .enabledDisplayIDs)
        try container.encode(applyOnLaunch, forKey: .applyOnLaunch)

        try container.encode(defaultProfile.sourceMode, forKey: .sourceMode)
        try container.encode(defaultProfile.ambientStyle, forKey: .ambientStyle)
        try container.encodeIfPresent(defaultProfile.videoPath, forKey: .videoPath)
        try container.encode(defaultProfile.loopVideo, forKey: .loopVideo)
        try container.encode(defaultProfile.muted, forKey: .muted)
        try container.encode(defaultProfile.volume, forKey: .volume)
        try container.encode(defaultProfile.playbackRate, forKey: .playbackRate)
        try container.encode(defaultProfile.fitMode, forKey: .fitMode)
        try container.encode(defaultProfile.renderLimit, forKey: .renderLimit)
        try container.encode(defaultProfile.dimming, forKey: .dimming)
    }
}

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let legacyID: String
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let pixelSize: CGSize
    let scale: CGFloat
    let isMain: Bool

    var resolutionLabel: String {
        "\(Int(pixelSize.width)) x \(Int(pixelSize.height))"
    }

    var frameLabel: String {
        "\(Int(frame.width)) x \(Int(frame.height)) pt @ \(String(format: "%.1fx", scale))"
    }

    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.videopaperDisplayID else {
                return nil
            }

            let legacyID = String(displayID)

            return DisplayInfo(
                id: stableIdentifier(for: displayID),
                legacyID: legacyID,
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                pixelSize: CGSize(
                    width: CGFloat(CGDisplayPixelsWide(displayID)),
                    height: CGFloat(CGDisplayPixelsHigh(displayID))
                ),
                scale: screen.backingScaleFactor,
                isMain: screen == NSScreen.main
            )
        }
    }

    private static func stableIdentifier(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let screenSize = CGDisplayScreenSize(displayID)
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)

        guard vendor != 0 || model != 0 || serial != 0 else {
            return "display:legacy:\(displayID)"
        }

        let millimeterWidth = Int(screenSize.width.rounded())
        let millimeterHeight = Int(screenSize.height.rounded())
        return "display:v\(vendor):m\(model):s\(serial):px\(width)x\(height):mm\(millimeterWidth)x\(millimeterHeight)"
    }
}

enum DisplaySelection: Hashable {
    case all
    case display(String)
}

struct VideoMetadata: Equatable {
    let fileName: String
    let durationLabel: String
    let resolutionLabel: String
    let fileSizeLabel: String
}

extension NSScreen {
    var videopaperDisplayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }
}
