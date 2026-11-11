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

    // MARK: The orb (icon, trackball art and the website hero only)

    static let orbCyan = Color(hex: 0x35D6FF)
    static let orbBlue = Color(hex: 0x3D6BFF)
    static let orbViolet = Color(hex: 0x8A5CFF)
    static let orbMagenta = Color(hex: 0xF056D8)
    static let orb: [Color] = [orbCyan, orbBlue, orbViolet, orbMagenta]

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
