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
    case precisionHold     // cursor slows to `precisionSpeed` while held
    case precisionToggle   // press: precision on, press again: off
    case ballScrollHold    // while held, rolling the ball scrolls and the cursor stays put
    case dragLock          // press: left button goes down and stays; press again (or click) lets go

    struct Preset: Identifiable {
        /// Shown in menus (localized).
        let title: String
        let symbol: String
        let action: ButtonAction
        var id: String { title }
    }

    // Titles are display text only — what's saved is the action itself.
    static let presets: [Preset] = [
        .init(title: String(localized: "Default", comment: "Button action: what the button normally does"), symbol: "arrow.uturn.backward", action: .system),
        .init(title: String(localized: "Left click"), symbol: "cursorarrow.click", action: .leftClick),
        .init(title: String(localized: "Right click"), symbol: "contextualmenu.and.cursorarrow", action: .rightClick),
        .init(title: String(localized: "Middle click"), symbol: "circle.circle", action: .middleClick),
        .init(title: String(localized: "Control-click"), symbol: "control", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue)),
        .init(title: String(localized: "Control-right-click"), symbol: "control", action: .modifiedClick(button: 1, modifiers: CGEventFlags.maskControl.rawValue)),
        .init(title: String(localized: "Command-click"), symbol: "command", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskCommand.rawValue)),
        .init(title: String(localized: "Shift-click"), symbol: "shift", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskShift.rawValue)),
        .init(title: String(localized: "Option-click"), symbol: "option", action: .modifiedClick(button: 0, modifiers: CGEventFlags.maskAlternate.rawValue)),
        .init(title: String(localized: "Back", comment: "Browser back: what the top-right button does by default"), symbol: "chevron.backward", action: .back),
        .init(title: String(localized: "Forward", comment: "Browser forward"), symbol: "chevron.forward", action: .forward),
        .init(title: String(localized: "Previous Space", comment: "Mission Control: switch to the Space on the left"), symbol: "rectangle.lefthalf.inset.filled.arrow.left", action: .shortcut(.previousSpace)),
        .init(title: String(localized: "Next Space", comment: "Mission Control: switch to the Space on the right"), symbol: "rectangle.righthalf.inset.filled.arrow.right", action: .shortcut(.nextSpace)),
        .init(title: String(localized: "Mission Control"), symbol: "rectangle.3.group", action: .shortcut(.missionControl)),
        .init(title: String(localized: "App Exposé"), symbol: "macwindow.on.rectangle", action: .shortcut(.appExpose)),
        .init(title: String(localized: "Browser Back"), symbol: "arrow.backward.circle", action: .shortcut(.browserBack)),
        .init(title: String(localized: "Browser Forward"), symbol: "arrow.forward.circle", action: .shortcut(.browserForward)),
        .init(title: String(localized: "Spotlight"), symbol: "magnifyingglass", action: .shortcut(.spotlight)),
        .init(title: "Wispr Flow", symbol: "waveform", action: .holdShortcut(.wisprFlow)),
        .init(title: String(localized: "Copy"), symbol: "doc.on.doc", action: .shortcut(.copy)),
        .init(title: String(localized: "Paste"), symbol: "doc.on.clipboard", action: .shortcut(.paste)),
        .init(title: String(localized: "Undo"), symbol: "arrow.uturn.backward.circle", action: .shortcut(.undo)),
        .init(title: String(localized: "New Tab"), symbol: "plus.square.on.square", action: .shortcut(.newTab)),
        .init(title: String(localized: "Close Tab"), symbol: "xmark.square", action: .shortcut(.closeTab)),
        .init(title: String(localized: "Precision (hold)"), symbol: "scope", action: .precisionHold),
        .init(title: String(localized: "Precision (toggle)"), symbol: "dot.circle.viewfinder", action: .precisionToggle),
        .init(title: String(localized: "Scroll with ball (hold)"), symbol: "arrow.up.and.down.and.arrow.left.and.right", action: .ballScrollHold),
        .init(title: String(localized: "Drag lock"), symbol: "hand.draw", action: .dragLock),
        .init(title: String(localized: "Do nothing"), symbol: "nosign", action: .disabled),
    ]

    var title: String {
        if let p = Self.presets.first(where: { $0.action == self }) { return p.title }
        switch self {
        case .shortcut(let s), .holdShortcut(let s): return s.display
        default: break
        }
        return String(localized: "Custom", comment: "Button action that isn't one of the presets")
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

// Settings written by a newer Glide can contain actions this version doesn't
// know. Skip just those buttons and combos instead of failing to read — and so
// losing — the whole settings file.
private struct LenientAction: Decodable {
    let action: ButtonAction?
    init(from decoder: Decoder) { action = try? ButtonAction(from: decoder) }
}

private struct LenientChord: Decodable {
    let chord: Chord?
    init(from decoder: Decoder) { chord = try? Chord(from: decoder) }
}

extension KeyedDecodingContainer {
    func decodeLenientActions(forKey key: Key) throws -> [Int: ButtonAction]? {
        try decodeIfPresent([Int: LenientAction].self, forKey: key)?.compactMapValues(\.action)
    }

    func decodeLenientChords(forKey key: Key) throws -> [Chord]? {
        try decodeIfPresent([LenientChord].self, forKey: key)?.compactMap(\.chord)
    }
}

/// Glide's own system-wide keyboard shortcuts. Each is optional; only Pause
/// has one out of the box (⌃⌥⌘G, the escape hatch).
struct GlobalShortcuts: Codable, Equatable {
    enum Action: Int, CaseIterable, Identifiable {
        // Raw values are the Carbon hot key IDs (Pause was always 1).
        case pause = 1, precision, ballScroll, dragLock
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .pause: String(localized: "Pause / resume Glideball")
            case .precision: String(localized: "Precision", comment: "Mode that slows the pointer for fine work")
            case .ballScroll: String(localized: "Scroll with ball", comment: "Mode: rolling the ball scrolls instead of moving the pointer")
            case .dragLock: String(localized: "Drag lock", comment: "Mode: the left button stays held down so you can drag without holding it")
            }
        }

        var subtitle: String {
            switch self {
            case .pause: String(localized: "Your escape hatch: Glideball steps aside until you press it again.")
            case .precision: String(localized: "Slows the pointer for fine work until you press it again.")
            case .ballScroll: String(localized: "Rolling the ball scrolls and the pointer stays put, until you press it again.")
            case .dragLock: String(localized: "Grabs what's under the pointer once you let go of the keys. Press again, or click, to drop.")
            }
        }

        var symbol: String {
            switch self {
            case .pause: "pause.circle"
            case .precision: "scope"
            case .ballScroll: "arrow.up.and.down.and.arrow.left.and.right"
            case .dragLock: "hand.draw"
            }
        }
    }

    static let defaultPause = KeyShortcut.make(kVK_ANSI_G, "G", [.maskControl, .maskAlternate, .maskCommand])

    var pause: KeyShortcut? = GlobalShortcuts.defaultPause
    var precision: KeyShortcut?
    var ballScroll: KeyShortcut?
    var dragLock: KeyShortcut?

    subscript(action: Action) -> KeyShortcut? {
        get {
            switch action {
            case .pause: pause
            case .precision: precision
            case .ballScroll: ballScroll
            case .dragLock: dragLock
            }
        }
        set {
            switch action {
            case .pause: pause = newValue
            case .precision: precision = newValue
            case .ballScroll: ballScroll = newValue
            case .dragLock: dragLock = newValue
            }
        }
    }

    /// Why `shortcut` can't be used for `action`, or nil if it can.
    func refusal(for shortcut: KeyShortcut, as action: Action) -> String? {
        if shortcut.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            return String(localized: "Include ⌘, ⌃, or ⌥ — \(shortcut.display) on its own would stop working everywhere else.")
        }
        if let other = Action.allCases.first(where: { $0 != action && self[$0]?.sameKeys(as: shortcut) == true }) {
            return String(localized: "\(shortcut.display) is already the shortcut for \(other.title).",
                          comment: "First %@ is a keyboard shortcut like ⌃⌥⌘G; second is a mode name like “Precision”")
        }
        return nil
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case pause, precision, ballScroll, dragLock }

    // A cleared shortcut is written as null so it stays cleared; a missing (or
    // unreadable) one means the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ fallback: KeyShortcut?) -> KeyShortcut? {
            guard c.contains(key) else { return fallback }
            if (try? c.decodeNil(forKey: key)) == true { return nil }
            return (try? c.decode(KeyShortcut.self, forKey: key)) ?? fallback
        }
        let d = GlobalShortcuts()
        pause = read(.pause, d.pause)
        precision = read(.precision, d.precision)
        ballScroll = read(.ballScroll, d.ballScroll)
        dragLock = read(.dragLock, d.dragLock)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pause, forKey: .pause)
        try c.encode(precision, forKey: .precision)
        try c.encode(ballScroll, forKey: .ballScroll)
        try c.encode(dragLock, forKey: .dragLock)
    }
}

extension KeyShortcut {
    /// Same key and modifiers (the display name doesn't matter).
    func sameKeys(as other: KeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
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
    /// Tracking speed while a Precision button is held or toggled on.
    var precisionSpeed: Double = 1.0

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
    /// Gain for "Scroll with ball": points scrolled per ball count, × 1.
    var ballScrollSpeed: Double = 1.0

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

    /// System-wide keyboard shortcuts (pause, and switching Glide's modes).
    var globalShortcuts = GlobalShortcuts()

    init() {}

    // Missing keys fall back to defaults so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlideConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        trackingSpeed = try c.decodeIfPresent(Double.self, forKey: .trackingSpeed) ?? d.trackingSpeed
        precisionSpeed = try c.decodeIfPresent(Double.self, forKey: .precisionSpeed) ?? d.precisionSpeed
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
        ballScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .ballScrollSpeed) ?? d.ballScrollSpeed
        buttons = try c.decodeLenientActions(forKey: .buttons) ?? d.buttons
        chords = try c.decodeLenientChords(forKey: .chords) ?? d.chords
        appProfiles = try c.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? d.appProfiles
        globalShortcuts = try c.decodeIfPresent(GlobalShortcuts.self, forKey: .globalShortcuts) ?? d.globalShortcuts
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
            String(localized: "This settings file uses unsupported version \(version).")
        }
    }
}

// Numbers on screen, in the reader's own number format.
extension Double {
    /// Like "%.2g": "4.5", "12", "0.25".
    var twoDigits: String { formatted(.number.precision(.significantDigits(1...2))) }
    /// 0.5 → "50%" ("50 %" in French and German), truncated like `Int(x * 100)`.
    var wholePercent: String { formatted(.percent.precision(.fractionLength(0)).rounded(rule: .towardZero)) }
    /// 1.25 → "1.3"
    func decimals(_ digits: Int) -> String { formatted(.number.precision(.fractionLength(digits))) }
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
        case .native: String(localized: "Native · speed \(nativeScrollSpeed.twoDigits)")
        case .flywheel: String(localized: "Flywheel · \(Int(flyDistance)) pt, \(flyAcceleration.wholePercent) power")
        case .follow: String(localized: "Follow · \(Int(scrollDistance)) pt per tick")
        }
        return [
            .init(symbol: "cursorarrow.motionlines", title: String(localized: "Pointer speed"), value: trackingSpeed.formatted()),
            .init(symbol: "arrow.up.and.down.circle", title: String(localized: "Scrolling"), value: scroll),
            .init(symbol: "button.programmable", title: String(localized: "Buttons"),
                  value: remapped == 0 ? String(localized: "Default", comment: "Button action: what the button normally does")
                                       : String(localized: "\(remapped) remapped", comment: "Number of buttons that do something other than normal")),
            .init(symbol: "square.on.square", title: String(localized: "Combos"),
                  value: chords.isEmpty ? String(localized: "None", comment: "No combos / no app setups") : chords.count.formatted()),
            .init(symbol: "square.grid.2x2", title: String(localized: "App setups"), value: appProfilesSummary),
        ]
    }
}
