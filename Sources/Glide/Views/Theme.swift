import AppKit
import SwiftUI

/// Every color, type style, spacing, radius and motion constant the window
/// uses, from the design guide (`.claude/plans/design-guide.md`, "Version 2:
/// lit by the ball"). Nothing else hard-codes a color: if a view needs one
/// that isn't here, it probably shouldn't have one.
///
/// The rule: the trackball lights the room. The ball, the ring and the buttons
/// are the only light sources; their colors (ball blue, ring pink, buttons
/// amber, and the orb where all three meet) spill onto the stage around them,
/// and green/yellow/red only say how something is. Text is the system's own
/// semantic colors, so light, dark and Increase Contrast all work.
enum Theme {
    // MARK: Part colors

    /// The ball: its data, and the accent for controls.
    static let ball = dynamic(light: 0x0A6CFF, dark: 0x4DA8FF)
    /// The scroll ring's data.
    static let ring = dynamic(light: 0xE0347F, dark: 0xFF5CA8)
    /// The buttons' data and the press highlight.
    static let buttons = dynamic(light: 0xD98200, dark: 0xFFB340)

    // MARK: Status (only for saying how something is)

    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemYellow)
    static let bad = Color(nsColor: .systemRed)
    /// Neither good nor bad: paused, off.
    static let idle = Color(nsColor: .tertiaryLabelColor)

    // MARK: The orb (the trackball's ball, and the light it throws)

    // These four follow the ball color chosen in Settings › Look (`BallTheme`,
    // below): the ball itself (OrbArt), the light it throws into the well, the
    // room's aurora (Atmosphere) and every glow that comes from the orb read
    // them here, so a theme recolors all of it at once. The names are the
    // default Orb's; in another theme they're its light, mid, deep and accent
    // colors. The app icon is a separate choice and never changes with them.
    //
    // The part colors above (ball blue, ring pink, buttons amber) do NOT
    // change with a theme: they carry meaning in charts, gauges, badges and
    // the press highlight, and stay the same so they always read the same.

    static var orbCyan: Color { BallTheme.current.glow[0] }
    static var orbBlue: Color { BallTheme.current.glow[1] }
    static var orbViolet: Color { BallTheme.current.glow[2] }
    static var orbMagenta: Color { BallTheme.current.glow[3] }
    static var orb: [Color] { BallTheme.current.glow }

    // The ball's light where you steer with the ball (the Gestures ring and its editor, the
    // Switcher's lens): it follows the ball color too, since it's the orb's light the ball is
    // throwing there. Ball blue with the Orb. Each is kept readable in light and dark for any
    // color, a custom one included (`BallTheme.light`).

    /// The light itself: the lit chip, the beam, the wave, the hub's dot, the lens.
    static var light: Color { BallTheme.current.light }
    /// Text and symbols on that light (white, or near-black on a light one like yellow).
    static var onLight: Color { BallTheme.current.onLight }
    /// Text and symbols drawn in the light's color on glass or the page (a More's name).
    static var lightInk: Color { BallTheme.current.lightInk }

    // MARK: Surfaces and text

    /// The stage everything sits on (under the atmosphere's light): near-black
    /// with a cool tint in dark mode, a soft cool white in light.
    static let windowBackground = Color(nsColor: NSColor(name: "GlideWindowBackground") { appearance in
        isDark(appearance) ? NSColor(srgbHex: 0x09090D) : NSColor(srgbHex: 0xF1F2F7)
    })
    /// A quiet fill for small things on the stage (chips, wells, unselected choices):
    /// a whisper lighter than the stage in dark mode, a whisper darker in light.
    static let groupFill = Color(nsColor: NSColor(name: "GlideGroupFill") { appearance in
        if isHighContrast(appearance) {
            return isDark(appearance) ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)
        }
        return isDark(appearance) ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0, alpha: 0.035)
    })
    /// A group's 1 px edge.
    static let groupBorder = Color(nsColor: NSColor(name: "GlideGroupBorder") { appearance in
        if isHighContrast(appearance) { return .separatorColor }
        return isDark(appearance) ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.075)
    })

    // MARK: Surfaces with weight (version 2)

    /// A surface's fill at its top and bottom edges: lit from above, so a
    /// shade brighter at the top. Dark: a lifted graphite; light: paper white.
    static let surfaceTop = Color(nsColor: NSColor(name: "GlideSurfaceTop") { appearance in
        if isHighContrast(appearance) {
            return isDark(appearance) ? NSColor(srgbHex: 0x1E1E25) : .white
        }
        return isDark(appearance) ? NSColor(srgbHex: 0x17171D, alpha: 0.92) : NSColor(white: 1, alpha: 0.94)
    })
    static let surfaceBottom = Color(nsColor: NSColor(name: "GlideSurfaceBottom") { appearance in
        if isHighContrast(appearance) {
            return isDark(appearance) ? NSColor(srgbHex: 0x18181E) : NSColor(srgbHex: 0xFAFAFC)
        }
        return isDark(appearance) ? NSColor(srgbHex: 0x111116, alpha: 0.92) : NSColor(srgbHex: 0xFBFBFD, alpha: 0.86)
    })
    /// The 1 px light catching a surface's top edge.
    static let surfaceHighlight = Color(nsColor: NSColor(name: "GlideSurfaceHighlight") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 1, alpha: 1)
    })
    /// A surface's soft shadow onto the stage.
    static let surfaceShadow = Color(nsColor: NSColor(name: "GlideSurfaceShadow") { appearance in
        isDark(appearance) ? NSColor(white: 0, alpha: 0.45) : NSColor(srgbHex: 0x1C2240, alpha: 0.07)
    })
    /// The spotlight that follows the pointer along a surface's edge.
    static let spotlight = Color(nsColor: NSColor(name: "GlideSpotlight") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.55) : NSColor(srgbHex: 0x0A6CFF, alpha: 0.45)
    })
    /// An inset well (the oscilloscope's screen, a slider's track): a little darker than a surface.
    static let well = Color(nsColor: NSColor(name: "GlideWell") { appearance in
        isDark(appearance) ? NSColor(srgbHex: 0x050507, alpha: 0.75) : NSColor(srgbHex: 0xE9EBF2, alpha: 0.9)
    })
    /// Hairlines between rows, and dividers.
    static let hairline = Color(nsColor: .separatorColor)
    /// Hover wash on clickable things that aren't system controls.
    static let hoverFill = Color(nsColor: NSColor(name: "GlideHoverFill") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)
    })
    /// Pressed wash (a little more than hover).
    static let pressedFill = Color(nsColor: NSColor(name: "GlidePressedFill") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.09)
    })
    /// The selected page in the sidebar, as the system's sidebar draws it.
    static let sidebarSelection = Color(nsColor: NSColor(name: "GlideSidebarSelection") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.09)
    })
    /// Faint guide lines in charts.
    static let gridLine = Color(nsColor: NSColor(name: "GlideGridLine") { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)
    })
    /// The dark well the trackball sits in where it isn't on the stage itself (the tour's picture):
    /// dark in both appearances, it's the device's own world.
    static let stage = Color(nsColor: NSColor(name: "GlideStage") { appearance in
        isDark(appearance) ? NSColor(srgbHex: 0x08080C) : NSColor(srgbHex: 0x101016)
    })

    // MARK: Type

    enum Font {
        /// 32 semibold: a page's title.
        static let pageTitle = SwiftUI.Font.system(size: 32, weight: .semibold)
        /// 15: emphasis (a row group's lead line, a banner's title).
        static let emphasis = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// 13: body text and row labels.
        static let body = SwiftUI.Font.system(size: 13)
        /// 15 semibold: a section's title.
        static let sectionTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// 11: hints and captions under things.
        static let hint = SwiftUI.Font.system(size: 11)
        /// A number that changes, in a row (monospaced digits).
        static let value = SwiftUI.Font.system(size: 13, weight: .medium).monospacedDigit()
        /// Big rounded numerals (Today, lifetime): 40–56 for heroes.
        static func numeral(_ size: CGFloat = 30) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }
    }

    // MARK: Spacing and radii

    enum Space {
        static let sidebarWidth: CGFloat = 220
        static let contentMaxWidth: CGFloat = 680
        static let contentSide: CGFloat = 28
        static let contentTop: CGFloat = 4
        /// Full screen hides the (empty) toolbar; this much room stands in for it at the top.
        static let fullScreenTop: CGFloat = 22
        /// Between sections.
        static let section: CGFloat = 24
        /// Between a section's title and its group.
        static let titleToGroup: CGFloat = 8
        static let rowMinHeight: CGFloat = 44
        static let rowHorizontal: CGFloat = 14
        static let rowVertical: CGFloat = 10
        /// Where a row's text starts when it has a leading symbol (hairlines inset to here).
        static let symbolColumn: CGFloat = 22
        static let symbolGap: CGFloat = 10
    }

    enum Radius {
        static let group: CGFloat = 14
        static let stage: CGFloat = 16
        static let control: CGFloat = 7
    }

    // MARK: Motion

    enum Motion {
        /// Layout and selection: no bounce.
        static let spring = Animation.spring(response: 0.30, dampingFraction: 0.86)
        /// Fades.
        static let fade = Animation.easeOut(duration: 0.18)
        /// Tab change: cross-fade plus a 6 pt rise.
        static let tabChange = Animation.easeOut(duration: 0.18)
        static let tabRise: CGFloat = 6
        /// Only for earned moments (a badge landing, the tour's first "it works").
        static let bounce = Animation.spring(response: 0.45, dampingFraction: 0.62)
        /// A button corner filling as it's pressed (under 50 ms), and emptying after.
        static let pressIn = Animation.easeOut(duration: 0.045)
        static let pressOut = Animation.easeOut(duration: 0.25)
        /// Pausing: the ball loses its color.
        static let pause = Animation.easeInOut(duration: 0.3)

        /// `animation`, or a plain fade with Reduce Motion.
        static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation {
            reduceMotion ? fade : animation
        }
    }

    // MARK: Helpers

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                    .aqua, .vibrantLight, .accessibilityHighContrastAqua])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false
    }

    static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark]) != nil
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? NSColor(srgbHex: dark) : NSColor(srgbHex: light) })
    }
}

// MARK: - Ball color

/// One linear-light color for the orb's shading (OrbArt), 0…1 per channel.
struct OrbRGB: Equatable, Hashable, Codable {
    var r, g, b: Double

    /// From display (sRGB) values.
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.3, green: 0.5, blue: 1, alpha: 1)
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    func mix(_ o: OrbRGB, _ t: Double) -> OrbRGB { OrbRGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }

    /// Relative luminance (WCAG), 0 black … 1 white.
    var luminance: Double {
        func lin(_ c: Double) -> Double { let c = max(0, min(1, c)); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    /// WCAG contrast ratio against `o` (1 … 21).
    func contrast(_ o: OrbRGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// Mixed toward `toward` just enough to reach `target` luminance (rising toward white, or
    /// falling toward black); already there: unchanged.
    func luminance(_ target: Double, toward: OrbRGB) -> OrbRGB {
        let rising = toward.luminance > luminance
        if rising ? luminance >= target : luminance <= target { return self }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let t = (lo + hi) / 2, l = mix(toward, t).luminance
            if rising ? l < target : l > target { lo = t } else { hi = t }
        }
        return mix(toward, hi)
    }
    func scaled(_ k: Double) -> OrbRGB { OrbRGB(r * k, g * k, b * k) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var hex: String { String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5)) }
}

/// The colors the orb is painted with, by their role in the icon's shading
/// (`OrbArt.liquid` and `ball`). The default Orb uses the icon's exact values;
/// other themes derive the supporting ones from four.
struct OrbPalette: Equatable, Hashable {
    var light, ice, mid, deep, low, accent, lilac, rim, shade, backRim, sky: OrbRGB

    /// The icon's own (Theme's Orb).
    static let orb = OrbPalette(light: .init(0.24, 0.80, 1.00), ice: .init(0.52, 0.93, 1.00), mid: .init(0.20, 0.40, 1.00),
                                deep: .init(0.13, 0.22, 0.90), low: .init(0.42, 0.20, 0.92), accent: .init(0.98, 0.32, 0.86),
                                lilac: .init(0.80, 0.58, 1.00), rim: .init(0.09, 0.05, 0.30), shade: .init(0.30, 0.14, 0.70),
                                backRim: .init(0.55, 0.35, 0.95), sky: .init(0.62, 0.82, 1.0))

    /// A palette from four colors: the top of the ball (light), its body (mid),
    /// the bottom (low) and a splash of accent at the bottom left.
    static func from(light: OrbRGB, mid: OrbRGB, low: OrbRGB, accent: OrbRGB) -> OrbPalette {
        let white = OrbRGB(1, 1, 1)
        return OrbPalette(light: light, ice: light.mix(white, 0.4), mid: mid, deep: mid.scaled(0.7).mix(low, 0.3),
                          low: low, accent: accent, lilac: low.mix(white, 0.45), rim: low.scaled(0.28),
                          shade: low.scaled(0.75), backRim: low.mix(white, 0.3), sky: light.mix(white, 0.55))
    }
}

/// A ball color: the orb's palette, and the four colors its light throws
/// (`Theme.orbCyan`… for the aurora and glows).
struct BallTheme: Identifiable, Equatable {
    let id: String
    let title: String
    let palette: OrbPalette

    /// The light it throws: light, mid, low, accent.
    var glow: [Color] {
        if id == "orb" { return [Color(hex: 0x35D6FF), Color(hex: 0x3D6BFF), Color(hex: 0x8A5CFF), Color(hex: 0xF056D8)] }
        let p = palette
        return [p.light.color, p.mid.color, p.low.mix(p.mid, 0.25).color, p.accent.color]
    }

    /// The fine colored line at the trackball ring's outer edge, top to bottom.
    var ringLine: [Color] {
        if id == "orb" {
            return [Color(red: 0.36, green: 0.68, blue: 1.0), Color(red: 0.42, green: 0.45, blue: 1.0), Color(red: 0.58, green: 0.33, blue: 0.97)]
        }
        let p = palette, white = OrbRGB(1, 1, 1)
        return [p.light.mix(white, 0.15).color, p.mid.mix(white, 0.15).color, p.low.mix(white, 0.3).color]
    }

    private static func make(_ id: String, _ title: String, _ light: UInt32, _ mid: UInt32, _ low: UInt32, _ accent: UInt32) -> BallTheme {
        BallTheme(id: id, title: title, palette: .from(light: OrbRGB(hex: light), mid: OrbRGB(hex: mid),
                                                        low: OrbRGB(hex: low), accent: OrbRGB(hex: accent)))
    }

    static let orb = BallTheme(id: "orb", title: String(localized: "Orb", comment: "Ball color: the default, like the app icon"), palette: .orb)

    /// The curated themes, in the order Settings shows them.
    static let curated: [BallTheme] = [
        orb,
        make("ember", String(localized: "Ember", comment: "Ball color"), 0xFFC24D, 0xFF6A1F, 0xB0141E, 0xFF3D73),
        make("sunset", String(localized: "Sunset", comment: "Ball color"), 0xFFC873, 0xFF6B66, 0x7A2FA6, 0xFF5FB4),
        make("ocean", String(localized: "Ocean", comment: "Ball color"), 0x4DF2E6, 0x0D8CD9, 0x142E99, 0x66FFB3),
        make("forest", String(localized: "Forest", comment: "Ball color"), 0xB8F26B, 0x26A659, 0x0D4D40, 0xF2CC4D),
        make("graphite", String(localized: "Graphite", comment: "Ball color: greys"), 0xDDE0E6, 0x80858F, 0x383A42, 0xB3B8C2),
        make("classic", String(localized: "Classic red", comment: "Ball color: like the red ball the Expert Mouse comes with"),
             0xFF6B57, 0xD9141A, 0x73050D, 0xFF4033),
    ]

    /// A theme from three colors picked in Settings: top, middle, bottom.
    static func custom(_ colors: [OrbRGB]) -> BallTheme {
        let c = colors.count >= 3 ? colors : [OrbRGB(hex: 0xFFE070), OrbRGB(hex: 0x2EC99A), OrbRGB(hex: 0x2B3A9E)]
        return BallTheme(id: "custom", title: String(localized: "Custom", comment: "Ball color: your own colors"),
                         palette: .from(light: c[0], mid: c[1], low: c[2], accent: c[1].mix(c[0], 0.5).mix(OrbRGB(1, 1, 1), 0.2)))
    }

    /// The theme in use (`BallThemeStore`).
    static var current: BallTheme { BallThemeStore.shared.theme }

    // MARK: Its light where you steer with the ball (`Theme.light`)

    /// The light (`Theme.light`): the ball's body color, the Orb's ball blue. With any other
    /// color it's kept able to glow: in dark mode at least luminance 0.16 (a very dark color is
    /// lifted toward white, so it still shows on dark glass), in light mode at most 0.42 (a
    /// very light one, yellow or near-white, is deepened, so it still shows on pale glass).
    var light: Color { lightColors.light }
    /// Text and symbols on the light (`Theme.onLight`): white, unless white would read worse
    /// than near-black there (under 2.4:1, about what white on the Orb's dark-mode blue has).
    var onLight: Color { lightColors.on }
    /// The light's color as text on glass or the page (`Theme.lightInk`): at least 0.30
    /// luminance in dark mode, at most 0.18 in light, so a More's name reads (4.5:1 or so).
    var lightInk: Color { lightColors.ink }

    /// The light's sRGB values in dark and light mode (the self-test and the pictures check them).
    var lightValues: (dark: OrbRGB, light: OrbRGB) {
        let base = palette.mid
        return (base.luminance(Self.darkLightFloor, toward: OrbRGB(1, 1, 1)), base.luminance(Self.lightLightCeiling, toward: OrbRGB(0, 0, 0)))
    }
    static let darkLightFloor = 0.16, lightLightCeiling = 0.42
    /// What's written on a light of this color.
    static func label(on fill: OrbRGB) -> OrbRGB {
        let white = OrbRGB(1, 1, 1), ink = OrbRGB(hex: 0x14161C)
        return fill.contrast(white) >= 2.4 || fill.contrast(white) >= fill.contrast(ink) ? white : ink
    }

    private var lightColors: (light: Color, on: Color, ink: Color) {
        if id == "orb" { return (Theme.ball, .white, Theme.ball) }
        if let c = Self.lightCache[palette] { return c }
        let v = lightValues, base = palette.mid
        func dynamic(_ dark: OrbRGB, _ light: OrbRGB) -> Color {
            let d = dark.nsColor, l = light.nsColor
            return Color(nsColor: NSColor(name: nil) { Theme.isDark($0) ? d : l })
        }
        let c = (dynamic(v.dark, v.light), dynamic(Self.label(on: v.dark), Self.label(on: v.light)),
                 dynamic(base.luminance(0.30, toward: OrbRGB(1, 1, 1)), base.luminance(0.18, toward: OrbRGB(0, 0, 0))))
        Self.lightCache[palette] = c
        return c
    }
    nonisolated(unsafe) private static var lightCache: [OrbPalette: (light: Color, on: Color, ink: Color)] = [:]
}

/// Which ball color this Mac uses (Settings › Look › Ball color), and the
/// three colors of a custom one. Per Mac, like the app icon.
@Observable
final class BallThemeStore {
    static let shared = BallThemeStore()
    static let themeKey = "GlideBallTheme"
    static let customKey = "GlideBallThemeCustom"

    private(set) var theme: BallTheme
    private(set) var custom: [OrbRGB]

    private init() {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: Self.customKey) ?? []).compactMap { UInt32($0, radix: 16).map(OrbRGB.init(hex:)) }
        let colors = saved.count == 3 ? saved : [OrbRGB(hex: 0xFFE070), OrbRGB(hex: 0x2EC99A), OrbRGB(hex: 0x2B3A9E)]
        custom = colors
        let id = d.string(forKey: Self.themeKey) ?? "orb"
        theme = id == "custom" ? BallTheme.custom(colors) : BallTheme.curated.first { $0.id == id } ?? .orb
    }

    func choose(_ id: String) {
        theme = id == "custom" ? BallTheme.custom(custom) : BallTheme.curated.first { $0.id == id } ?? .orb
        UserDefaults.standard.set(theme.id, forKey: Self.themeKey)
        if theme.id != "orb" { AppModel.shared.delight.explored(.ballColor) }
    }

    /// The ball color in use, as a shared setup carries it.
    var look: ShareLook {
        ShareLook(theme: theme.id, custom: theme.id == "custom" ? custom.map(\.hex) : nil)
    }

    /// Uses a ball color from a shared setup (or puts back the one from before it).
    func use(_ look: ShareLook) {
        guard let look = look.sanitized else { return }
        if let colors = look.custom?.compactMap({ UInt32($0, radix: 16).map(OrbRGB.init(hex:)) }), colors.count == 3 {
            custom = colors
            UserDefaults.standard.set(custom.map(\.hex), forKey: Self.customKey)
        }
        choose(look.theme)
    }

    /// A theme's name by id ("Sunset", "Custom"), for previews.
    static func title(of look: ShareLook) -> String {
        look.theme == "custom" ? BallTheme.custom([]).title : BallTheme.curated.first { $0.id == look.theme }?.title ?? look.theme
    }

    /// Changes one of the custom colors (0 top, 1 middle, 2 bottom) and uses the custom theme.
    func setCustom(_ index: Int, to color: OrbRGB) {
        guard custom.indices.contains(index), custom[index] != color else { return }
        custom[index] = color
        UserDefaults.standard.set(custom.map(\.hex), forKey: Self.customKey)
        choose("custom")
    }
}

extension Metric {
    /// The part each count is about: clicks are buttons, rolling is the ball, scrolling is the ring.
    var color: Color {
        switch self {
        case .scroll: Theme.ring
        case .ball: Theme.ball
        case .clicks: Theme.buttons
        }
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
