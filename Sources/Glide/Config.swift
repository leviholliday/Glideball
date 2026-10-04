import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A keyboard shortcut a button can fire.
struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyName: String

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + keyName
    }

    static func make(_ key: Int, _ name: String, _ flags: CGEventFlags) -> KeyShortcut {
        KeyShortcut(keyCode: UInt16(key), modifiers: flags.rawValue, keyName: name)
    }

    static let previousSpace  = make(kVK_LeftArrow, "←", .maskControl)
    static let nextSpace      = make(kVK_RightArrow, "→", .maskControl)
    static let missionControl = make(kVK_UpArrow, "↑", .maskControl)
    static let appExpose      = make(kVK_DownArrow, "↓", .maskControl)
    static let browserBack    = make(kVK_ANSI_LeftBracket, "[", .maskCommand)
    static let browserForward = make(kVK_ANSI_RightBracket, "]", .maskCommand)
    static let copy           = make(kVK_ANSI_C, "C", .maskCommand)
    static let paste          = make(kVK_ANSI_V, "V", .maskCommand)
    static let undo           = make(kVK_ANSI_Z, "Z", .maskCommand)
    static let newTab         = make(kVK_ANSI_T, "T", .maskCommand)
    static let closeTab       = make(kVK_ANSI_W, "W", .maskCommand)
    static let spotlight      = make(kVK_Space, "Space", .maskCommand)
    /// Wispr Flow's configured push-to-talk shortcut. It remains held while speaking.
    static let wisprFlow      = make(kVK_Space, "Space", .maskControl)
}

/// What a physical trackball button does.
enum ButtonAction: Codable, Hashable {
    case system
    case leftClick
    case rightClick
    case middleClick
    case back
    case forward
    case shortcut(KeyShortcut)
    case holdShortcut(KeyShortcut)
    case modifiedClick(button: Int, modifiers: UInt64)   // e.g. ⌃-click
    case disabled

    struct Preset: Identifiable {
        let title: String
        let symbol: String
        let action: ButtonAction
        var id: String { title }
    }

    static let presets: [Preset] = [
        .init(title: "Default", symbol: "arrow.uturn.backward", action: .system),
        .init(title: "Left click", symbol: "cursorarrow.click", action: .leftClick),
        .init(title: "Right click", symbol: "contextualmenu.and.cursorarrow", action: .rightClick),
        .init(title: "Middle click", symbol: "circle.circle", action: .middleClick),
        .init(title: "Control-click", symbol: "control", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue)),
        .init(title: "Control-right-click", symbol: "control", action: .modifiedClick(button: 1, modifiers: CGEventFlags.maskControl.rawValue)),
        .init(title: "Command-click", symbol: "command", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskCommand.rawValue)),
        .init(title: "Shift-click", symbol: "shift", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskShift.rawValue)),
        .init(title: "Option-click", symbol: "option", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskAlternate.rawValue)),
        .init(title: "Back", symbol: "chevron.backward", action: .back),
        .init(title: "Forward", symbol: "chevron.forward", action: .forward),
        .init(title: "Previous Space", symbol: "rectangle.lefthalf.inset.filled.arrow.left", action: .shortcut(.previousSpace)),
        .init(title: "Next Space", symbol: "rectangle.righthalf.inset.filled.arrow.right", action: .shortcut(.nextSpace)),
        .init(title: "Mission Control", symbol: "rectangle.3.group", action: .shortcut(.missionControl)),
        .init(title: "App Exposé", symbol: "macwindow.on.rectangle", action: .shortcut(.appExpose)),
        .init(title: "Browser Back", symbol: "arrow.backward.circle", action: .shortcut(.browserBack)),
        .init(title: "Browser Forward", symbol: "arrow.forward.circle", action: .shortcut(.browserForward)),
        .init(title: "Spotlight", symbol: "magnifyingglass", action: .shortcut(.spotlight)),
        .init(title: "Wispr Flow", symbol: "waveform", action: .holdShortcut(.wisprFlow)),
        .init(title: "Copy", symbol: "doc.on.doc", action: .shortcut(.copy)),
        .init(title: "Paste", symbol: "doc.on.clipboard", action: .shortcut(.paste)),
        .init(title: "Undo", symbol: "arrow.uturn.backward.circle", action: .shortcut(.undo)),
        .init(title: "New Tab", symbol: "plus.square.on.square", action: .shortcut(.newTab)),
        .init(title: "Close Tab", symbol: "xmark.square", action: .shortcut(.closeTab)),
        .init(title: "Do nothing", symbol: "nosign", action: .disabled),
    ]

    var title: String {
        if let p = Self.presets.first(where: { $0.action == self }) { return p.title }
        switch self {
        case .shortcut(let s), .holdShortcut(let s): return s.display
        default: break
        }
        return "Custom"
    }

    var symbol: String {
        Self.presets.first(where: { $0.action == self })?.symbol ?? "keyboard"
    }

    var detail: String? {
        switch self {
        case .shortcut(let s), .holdShortcut(let s): return s.display
        default: break
        }
        return nil
    }
}

/// Two or more buttons pressed together.
struct Chord: Codable, Hashable, Identifiable {
    var id = UUID()
    var buttons: [Int]        // sorted button numbers
    var action: ButtonAction
}

/// How the scroll ring is turned into scrolling.
enum ScrollMode: String, Codable, CaseIterable, Identifiable {
    case native     // macOS's own wheel scrolling (what Kensington's driver relied on)
    case flywheel   // each tick pushes, speed fades — Kensington's measured feel, at 120 Hz
    case follow     // page follows the ring precisely; throws only on a real flick
    var id: String { rawValue }
}

struct GlideConfig: Codable, Equatable {
    var enabled = true

    // Pointer: macOS tracking speed for the trackball only.
    // System Settings stops at 3; macOS accepts more.
    var trackingSpeed: Double = 4.0

    // Scroll ring
    var scrollMode: ScrollMode = .flywheel
    var nativeScrollSpeed: Double = 0.5     // macOS wheel acceleration (System Settings: 0…1.7)
    var flyDistance: Double = 4             // points per slow tick
    var flyAcceleration: Double = 0.5       // how hard fast spins push
    var flyGlide: Double = 0.35             // 0 short … 1 long coast (0.35 ≈ Kensington, 82 ms)
    var smoothScrolling = true
    var scrollDistance: Double = 14         // points per ring tick
    var scrollSmoothness: Double = 0.4      // follow softness: 0 locked … 1 soft
    var scrollAcceleration: Double = 0.5    // 0 none … 1 lots
    var throwEnabled = true                 // fast spin + let go = page coasts
    var throwAmount: Double = 0.4           // 0 short … 1 long
    var reverseScroll = false
    var shiftScrollsHorizontally = true

    // Buttons, keyed by macOS button number (0 = primary/bottom-left).
    var buttons: [Int: ButtonAction] = [
        2: .shortcut(.previousSpace),
        3: .shortcut(.nextSpace),
    ]
    var chords: [Chord] = [
        Chord(buttons: [0, 2, 3], action: .holdShortcut(.wisprFlow)),
    ]

    // Per-app setups: used instead of the above while that app is in front.
    var appProfiles: [AppProfile] = []

    init() {}

    // Missing keys fall back to defaults so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlideConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        trackingSpeed = try c.decodeIfPresent(Double.self, forKey: .trackingSpeed) ?? d.trackingSpeed
        scrollMode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? d.scrollMode
        nativeScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .nativeScrollSpeed) ?? d.nativeScrollSpeed
        flyDistance = try c.decodeIfPresent(Double.self, forKey: .flyDistance) ?? d.flyDistance
        flyAcceleration = try c.decodeIfPresent(Double.self, forKey: .flyAcceleration) ?? d.flyAcceleration
        flyGlide = try c.decodeIfPresent(Double.self, forKey: .flyGlide) ?? d.flyGlide
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? d.smoothScrolling
        scrollDistance = try c.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? d.scrollDistance
        scrollSmoothness = try c.decodeIfPresent(Double.self, forKey: .scrollSmoothness) ?? d.scrollSmoothness
        scrollAcceleration = try c.decodeIfPresent(Double.self, forKey: .scrollAcceleration) ?? d.scrollAcceleration
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? d.reverseScroll
        throwEnabled = try c.decodeIfPresent(Bool.self, forKey: .throwEnabled) ?? d.throwEnabled
        throwAmount = try c.decodeIfPresent(Double.self, forKey: .throwAmount) ?? d.throwAmount
        shiftScrollsHorizontally = try c.decodeIfPresent(Bool.self, forKey: .shiftScrollsHorizontally) ?? d.shiftScrollsHorizontally
        buttons = try c.decodeIfPresent([Int: ButtonAction].self, forKey: .buttons) ?? d.buttons
        chords = try c.decodeIfPresent([Chord].self, forKey: .chords) ?? d.chords
        appProfiles = try c.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? d.appProfiles
    }

    private static let key = "GlideConfig"

    static func load() -> GlideConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(GlideConfig.self, from: data) else { return GlideConfig() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Portable, versioned settings file used by Glide's import and export controls.
struct GlideSettingsFile: Codable {
    static let currentVersion = 1
    static let fileExtension = "glide-settings"
    let version: Int
    let config: GlideConfig
    /// When and where the file was made — shown in the import preview.
    /// Optional so files from before these fields existed still open.
    var exportedAt: Date?
    var exportedFrom: String?

    init(config: GlideConfig, exportedFrom: String? = Host.current().localizedName) {
        version = Self.currentVersion
        self.config = config
        exportedAt = Date()
        self.exportedFrom = exportedFrom
    }

    func validatedConfig() throws -> GlideConfig {
        guard version == Self.currentVersion else {
            throw GlideSettingsFileError.unsupportedVersion(version)
        }
        return config
    }
}

enum GlideSettingsFileError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This settings file uses unsupported version \(version)."
        }
    }
}

/// A one-line-per-area description of a setup, for export and import previews.
struct SettingsSummaryRow: Identifiable, Equatable {
    let symbol: String
    let title: String
    let value: String
    var id: String { title }
}

extension GlideConfig {
    var summary: [SettingsSummaryRow] {
        let remapped = buttons.values.filter { $0 != .system }.count
        let scroll: String = switch scrollMode {
        case .native: String(format: "Native · speed %.2g", nativeScrollSpeed)
        case .flywheel: "Flywheel · \(Int(flyDistance)) pt, \(Int(flyAcceleration * 100))% power"
        case .follow: "Follow · \(Int(scrollDistance)) pt per tick"
        }
        return [
            .init(symbol: "cursorarrow.motionlines", title: "Pointer speed", value: String(format: "%g", trackingSpeed)),
            .init(symbol: "arrow.up.and.down.circle", title: "Scrolling", value: scroll),
            .init(symbol: "button.programmable", title: "Buttons", value: remapped == 0 ? "Default" : "\(remapped) remapped"),
            .init(symbol: "square.on.square", title: "Combos", value: chords.isEmpty ? "None" : "\(chords.count)"),
            .init(symbol: "square.grid.2x2", title: "App setups", value: appProfilesSummary),
        ]
    }
}
