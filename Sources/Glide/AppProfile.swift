import Foundation

/// A setup Glide switches to while one particular app is in front.
/// Each area is optional: nil means "use the main setup" for that area.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var trackingSpeed: Double?
    var scroll: ScrollSettings?
    var buttons: [Int: ButtonAction]?
    var chords: [Chord]?

    var id: String { bundleID }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// "Speed 6 · Flywheel scrolling · 2 buttons", for the app list.
    var summary: String {
        var parts: [String] = []
        if let trackingSpeed { parts.append(String(format: "Speed %g", trackingSpeed)) }
        if let scroll { parts.append("\(scroll.scrollMode.title) scrolling") }
        if let buttons {
            let n = buttons.filter { $0.key != 0 && $0.value != .system }.count
            parts.append(n == 0 ? "Default buttons" : "\(n) button\(n == 1 ? "" : "s")")
        }
        if let chords { parts.append(chords.isEmpty ? "No combos" : "\(chords.count) combo\(chords.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Uses your main setup" : parts.joined(separator: " · ")
    }
}

/// Everything on the Scrolling tab, so an app setup can take it over as a whole.
struct ScrollSettings: Codable, Equatable {
    var scrollMode: ScrollMode
    var nativeScrollSpeed: Double
    var flyDistance: Double
    var flyAcceleration: Double
    var flyGlide: Double
    var smoothScrolling: Bool
    var scrollDistance: Double
    var scrollSmoothness: Double
    var scrollAcceleration: Double
    var throwEnabled: Bool
    var throwAmount: Double
    var reverseScroll: Bool
    var shiftScrollsHorizontally: Bool
}

extension ScrollSettings {
    // Missing keys fall back to defaults, like GlideConfig.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlideConfig().scrollSettings
        scrollMode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? d.scrollMode
        nativeScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .nativeScrollSpeed) ?? d.nativeScrollSpeed
        flyDistance = try c.decodeIfPresent(Double.self, forKey: .flyDistance) ?? d.flyDistance
        flyAcceleration = try c.decodeIfPresent(Double.self, forKey: .flyAcceleration) ?? d.flyAcceleration
        flyGlide = try c.decodeIfPresent(Double.self, forKey: .flyGlide) ?? d.flyGlide
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? d.smoothScrolling
        scrollDistance = try c.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? d.scrollDistance
        scrollSmoothness = try c.decodeIfPresent(Double.self, forKey: .scrollSmoothness) ?? d.scrollSmoothness
        scrollAcceleration = try c.decodeIfPresent(Double.self, forKey: .scrollAcceleration) ?? d.scrollAcceleration
        throwEnabled = try c.decodeIfPresent(Bool.self, forKey: .throwEnabled) ?? d.throwEnabled
        throwAmount = try c.decodeIfPresent(Double.self, forKey: .throwAmount) ?? d.throwAmount
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? d.reverseScroll
        shiftScrollsHorizontally = try c.decodeIfPresent(Bool.self, forKey: .shiftScrollsHorizontally) ?? d.shiftScrollsHorizontally
    }
}

extension ScrollMode {
    var title: String {
        switch self {
        case .native: "Native"
        case .flywheel: "Flywheel"
        case .follow: "Follow"
        }
    }
}

extension GlideConfig {
    var scrollSettings: ScrollSettings {
        get {
            ScrollSettings(scrollMode: scrollMode, nativeScrollSpeed: nativeScrollSpeed,
                           flyDistance: flyDistance, flyAcceleration: flyAcceleration, flyGlide: flyGlide,
                           smoothScrolling: smoothScrolling, scrollDistance: scrollDistance,
                           scrollSmoothness: scrollSmoothness, scrollAcceleration: scrollAcceleration,
                           throwEnabled: throwEnabled, throwAmount: throwAmount,
                           reverseScroll: reverseScroll, shiftScrollsHorizontally: shiftScrollsHorizontally)
        }
        set {
            scrollMode = newValue.scrollMode
            nativeScrollSpeed = newValue.nativeScrollSpeed
            flyDistance = newValue.flyDistance
            flyAcceleration = newValue.flyAcceleration
            flyGlide = newValue.flyGlide
            smoothScrolling = newValue.smoothScrolling
            scrollDistance = newValue.scrollDistance
            scrollSmoothness = newValue.scrollSmoothness
            scrollAcceleration = newValue.scrollAcceleration
            throwEnabled = newValue.throwEnabled
            throwAmount = newValue.throwAmount
            reverseScroll = newValue.reverseScroll
            shiftScrollsHorizontally = newValue.shiftScrollsHorizontally
        }
    }

    func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return appProfiles.first { $0.bundleID == bundleID }
    }

    /// This setup with the app's customized areas laid over it — what the
    /// engine should run while that app is in front.
    func resolved(for bundleID: String?) -> GlideConfig {
        guard let p = profile(for: bundleID) else { return self }
        var c = self
        if let speed = p.trackingSpeed { c.trackingSpeed = speed }
        if let scroll = p.scroll { c.scrollSettings = scroll }
        if var map = p.buttons {
            map[0] = buttons[0]   // the primary button is never per-app: it stays a left click
            c.buttons = map
        }
        if let chords = p.chords { c.chords = chords }
        return c
    }

    var appProfilesSummary: String {
        switch appProfiles.count {
        case 0: "None"
        case 1...2: appProfiles.map(\.name).joined(separator: ", ")
        default: "\(appProfiles.count) apps"
        }
    }
}
