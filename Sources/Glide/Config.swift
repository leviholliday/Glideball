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
    static let cut            = make(kVK_ANSI_X, "X", .maskCommand)
    static let redo           = make(kVK_ANSI_Z, "Z", [.maskCommand, .maskShift])
    static let selectAll      = make(kVK_ANSI_A, "A", .maskCommand)
    static let save           = make(kVK_ANSI_S, "S", .maskCommand)
    static let find           = make(kVK_ANSI_F, "F", .maskCommand)
    static let reopenTab      = make(kVK_ANSI_T, "T", [.maskCommand, .maskShift])
    static let nextTab        = make(kVK_Tab, "⇥", .maskControl)
    static let previousTab    = make(kVK_Tab, "⇥", [.maskControl, .maskShift])
    static let reload         = make(kVK_ANSI_R, "R", .maskCommand)
    static let zoomIn         = make(kVK_ANSI_Equal, "=", .maskCommand)
    static let zoomOut        = make(kVK_ANSI_Minus, "-", .maskCommand)
    static let minimize       = make(kVK_ANSI_M, "M", .maskCommand)
    static let fullScreen     = make(kVK_ANSI_F, "F", [.maskControl, .maskCommand])
    static let lastApp        = make(kVK_Tab, "⇥", .maskCommand)
    static let screenshot     = make(kVK_ANSI_4, "4", [.maskCommand, .maskShift])
    static let screenshotTools = make(kVK_ANSI_5, "5", [.maskCommand, .maskShift])
    static let emoji          = make(kVK_Space, "Space", [.maskControl, .maskCommand])
    static let lockScreen     = make(kVK_ANSI_Q, "Q", [.maskControl, .maskCommand])
    /// Wispr Flow's configured push-to-talk shortcut. It remains held while speaking.
    static let wisprFlow      = make(kVK_Space, "Space", .maskControl)
}

/// The keyboard's media keys (macOS's NX_KEYTYPE_* numbers).
enum MediaKey: Int, Codable, Hashable, CaseIterable {
    case volumeUp = 0
    case volumeDown = 1
    case mute = 7
    case playPause = 16
    case next = 17
    case previous = 18
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
    case media(MediaKey)   // play/pause, next track, volume… (the keyboard's media keys)
    case openApp(bundleID: String)   // opens (or brings forward) an app
    /// Hold the button and roll the ball: each direction does something, a plain
    /// tap does `tap`. The pointer stays put while it's held. Never on the primary button.
    indirect case gesture(ButtonGesture)

    struct Preset: Identifiable {
        /// Shown in menus (localized).
        let title: String
        let symbol: String
        let action: ButtonAction
        var id: String { title }
    }

    // Titles are display text only — what's saved is the action itself. The picker
    // (ActionCatalog.swift) adds a category, a line about each and search words.
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
        .init(title: String(localized: "Browser Back"), symbol: "arrow.backward.circle", action: .shortcut(.browserBack)),
        .init(title: String(localized: "Browser Forward"), symbol: "arrow.forward.circle", action: .shortcut(.browserForward)),
        .init(title: String(localized: "New Tab"), symbol: "plus.square.on.square", action: .shortcut(.newTab)),
        .init(title: String(localized: "Close Tab"), symbol: "xmark.square", action: .shortcut(.closeTab)),
        .init(title: String(localized: "Reopen Closed Tab"), symbol: "arrow.uturn.backward.square", action: .shortcut(.reopenTab)),
        .init(title: String(localized: "Next Tab"), symbol: "arrow.right.square", action: .shortcut(.nextTab)),
        .init(title: String(localized: "Previous Tab"), symbol: "arrow.left.square", action: .shortcut(.previousTab)),
        .init(title: String(localized: "Reload"), symbol: "arrow.clockwise", action: .shortcut(.reload)),
        .init(title: String(localized: "Zoom In"), symbol: "plus.magnifyingglass", action: .shortcut(.zoomIn)),
        .init(title: String(localized: "Zoom Out"), symbol: "minus.magnifyingglass", action: .shortcut(.zoomOut)),
        .init(title: String(localized: "Previous Space", comment: "Mission Control: switch to the Space on the left"), symbol: "rectangle.lefthalf.inset.filled.arrow.left", action: .shortcut(.previousSpace)),
        .init(title: String(localized: "Next Space", comment: "Mission Control: switch to the Space on the right"), symbol: "rectangle.righthalf.inset.filled.arrow.right", action: .shortcut(.nextSpace)),
        .init(title: String(localized: "Mission Control"), symbol: "rectangle.3.group", action: .shortcut(.missionControl)),
        .init(title: String(localized: "App Exposé"), symbol: "macwindow.on.rectangle", action: .shortcut(.appExpose)),
        .init(title: String(localized: "Last Used App", comment: "Button action: switch back to the app used before this one (⌘⇥)"), symbol: "arrow.left.arrow.right.square", action: .shortcut(.lastApp)),
        .init(title: String(localized: "Minimize Window"), symbol: "minus.rectangle", action: .shortcut(.minimize)),
        .init(title: String(localized: "Full Screen"), symbol: "arrow.up.left.and.arrow.down.right", action: .shortcut(.fullScreen)),
        .init(title: String(localized: "Spotlight"), symbol: "magnifyingglass", action: .shortcut(.spotlight)),
        .init(title: String(localized: "Lock Screen"), symbol: "lock", action: .shortcut(.lockScreen)),
        .init(title: "Wispr Flow", symbol: "waveform", action: .holdShortcut(.wisprFlow)),
        .init(title: String(localized: "Copy"), symbol: "doc.on.doc", action: .shortcut(.copy)),
        .init(title: String(localized: "Paste"), symbol: "doc.on.clipboard", action: .shortcut(.paste)),
        .init(title: String(localized: "Cut"), symbol: "scissors", action: .shortcut(.cut)),
        .init(title: String(localized: "Undo"), symbol: "arrow.uturn.backward.circle", action: .shortcut(.undo)),
        .init(title: String(localized: "Redo"), symbol: "arrow.uturn.forward.circle", action: .shortcut(.redo)),
        .init(title: String(localized: "Select All"), symbol: "selection.pin.in.out", action: .shortcut(.selectAll)),
        .init(title: String(localized: "Save"), symbol: "square.and.arrow.down", action: .shortcut(.save)),
        .init(title: String(localized: "Find"), symbol: "text.magnifyingglass", action: .shortcut(.find)),
        .init(title: String(localized: "Screenshot"), symbol: "camera.viewfinder", action: .shortcut(.screenshot)),
        .init(title: String(localized: "Screenshot and Recording"), symbol: "record.circle", action: .shortcut(.screenshotTools)),
        .init(title: String(localized: "Emoji & Symbols"), symbol: "face.smiling", action: .shortcut(.emoji)),
        .init(title: String(localized: "Play or Pause"), symbol: "playpause", action: .media(.playPause)),
        .init(title: String(localized: "Next Track"), symbol: "forward", action: .media(.next)),
        .init(title: String(localized: "Previous Track"), symbol: "backward", action: .media(.previous)),
        .init(title: String(localized: "Volume Up"), symbol: "speaker.wave.3", action: .media(.volumeUp)),
        .init(title: String(localized: "Volume Down"), symbol: "speaker.wave.1", action: .media(.volumeDown)),
        .init(title: String(localized: "Mute"), symbol: "speaker.slash", action: .media(.mute)),
        .init(title: String(localized: "Precision (hold)"), symbol: "scope", action: .precisionHold),
        .init(title: String(localized: "Precision (toggle)"), symbol: "dot.circle.viewfinder", action: .precisionToggle),
        .init(title: String(localized: "Scroll with ball (hold)"), symbol: "arrow.up.and.down.and.arrow.left.and.right", action: .ballScrollHold),
        .init(title: String(localized: "Drag lock"), symbol: "hand.draw", action: .dragLock),
        .init(title: String(localized: "Gesture", comment: "Button action: hold the button and roll the ball up, down, left or right"),
              symbol: "dot.arrowtriangles.up.right.down.left.circle", action: .gesture(.standard)),
        .init(title: String(localized: "Do nothing"), symbol: "nosign", action: .disabled),
    ]

    /// Display names of apps chosen for "Open an app", by bundle ID (set by the app
    /// at launch: Config.swift is also built on its own by the simulators).
    nonisolated(unsafe) static var appName: (String) -> String? = { _ in nil }

    var title: String {
        if let p = Self.presets.first(where: { $0.action == self }) { return p.title }
        switch self {
        case .shortcut(let s), .holdShortcut(let s): return s.display
        case .openApp(let id):
            let name = Self.appName(id) ?? id
            return String(localized: "Open \(name)", comment: "Button action: opens an app; %@ is the app’s name")
        case .gesture: return String(localized: "Gesture", comment: "Button action: hold the button and roll the ball up, down, left or right")
        default: break
        }
        return String(localized: "Custom", comment: "Button action that isn't one of the presets")
    }

    var symbol: String {
        if case .openApp = self { return "app" }
        if case .gesture = self { return "dot.arrowtriangles.up.right.down.left.circle" }
        return Self.presets.first(where: { $0.action == self })?.symbol ?? "keyboard"
    }

    var detail: String? {
        switch self {
        case .shortcut(let s), .holdShortcut(let s): return s.display
        default: break
        }
        return nil
    }
}

extension ButtonAction {
    /// What a button does without Glideball: 0 left click, 1 right click, 2 middle click, 3 back.
    static func normal(for button: Int) -> ButtonAction {
        switch button {
        case 0: .leftClick
        case 1: .rightClick
        case 2: .middleClick
        case 3: .back
        default: .system
        }
    }

    /// Does what the button does anyway ("Default", or the same click spelled out).
    func isNormal(for button: Int) -> Bool { self == .system || self == Self.normal(for: button) }

    /// Does the same thing on this button as `other`.
    func sameEffect(as other: ButtonAction, on button: Int) -> Bool {
        self == other || (isNormal(for: button) && other.isNormal(for: button))
    }
}

/// Two or more buttons pressed together.
struct Chord: Codable, Hashable, Identifiable {
    var id = UUID()
    var buttons: [Int]        // sorted button numbers
    var action: ButtonAction
}

extension Chord {
    private enum Keys: String, CodingKey { case id, buttons, action }

    // A shared setup's link leaves the id out (it's made fresh on import anyway).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        buttons = try c.decode([Int].self, forKey: .buttons)
        action = try c.decode(ButtonAction.self, forKey: .action)
    }
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
            return String(localized: "Include ⌘, ⌃, or ⌥. \(shortcut.display) on its own would stop working everywhere else.")
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
    var flyReach: Double = 0.5              // how much farther the very fastest spins go (0 = the old 12,000 pt/s limit)
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
    // Out of the box every button does its normal click and there are no
    // combos; "Spaces + Wispr Flow" (below) is the setup that used to be the default.
    var buttons: [Int: ButtonAction] = [:]
    var chords: [Chord] = []

    // Per-app setups: used instead of the above while that app is in front.
    var appProfiles: [AppProfile] = []

    /// System-wide keyboard shortcuts (pause, and switching Glide's modes).
    var globalShortcuts = GlobalShortcuts()

    /// Gesture buttons are on. Off: each one just does its tap action.
    var gesturesEnabled = true
    /// How far a gesture rolls before a direction fires (a gesture can have its own).
    var gestureDistance: GestureDistance = .normal
    /// "Steady hands": a wider dead zone, so a wobble never counts as a roll.
    var gestureSteadyHands = false
    /// An optional pointer speed for each display (see `DisplaySpeeds` for the precedence).
    var displaySpeeds = DisplaySpeeds()

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
        flyReach = try c.decodeIfPresent(Double.self, forKey: .flyReach) ?? d.flyReach
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
        // Newer fields: anything unreadable means the default, never a lost settings file.
        gesturesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .gesturesEnabled)) ?? d.gesturesEnabled
        gestureDistance = (try? c.decodeIfPresent(GestureDistance.self, forKey: .gestureDistance)) ?? d.gestureDistance
        gestureSteadyHands = (try? c.decodeIfPresent(Bool.self, forKey: .gestureSteadyHands)) ?? d.gestureSteadyHands
        displaySpeeds = (try? c.decodeIfPresent(DisplaySpeeds.self, forKey: .displaySpeeds)) ?? d.displaySpeeds
    }

    private static let key = "GlideConfig"
    /// Set on the first launch of a version whose defaults are stock buttons.
    private static let stockDefaultsKey = "GlideStockButtonDefaults"

    static func load() -> GlideConfig {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: key)
        if !defaults.bool(forKey: stockDefaultsKey) {
            defaults.set(true, forKey: stockDefaultsKey)
            // Settings are saved only once something changes, so someone who used
            // an earlier Glideball without changing anything has nothing saved and
            // ran on the old defaults. Keep those buttons and combo for them, once.
            if data == nil && usedBefore(defaults) {
                var old = GlideConfig()
                old.applySpacesAndWisprFlow()
                old.save()
                return old
            }
        }
        guard let data, let saved = try? JSONDecoder().decode(GlideConfig.self, from: data) else { return GlideConfig() }
        return saved
    }

    /// An earlier Glideball ran here: the Welcome Tour was finished or skipped
    /// ("GlideOnboardingDone", see WelcomeTour), or daily totals were saved
    /// (at every quit and window close).
    private static func usedBefore(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "GlideOnboardingDone")
            || defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("GlideTotals-") }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Button presets

extension GlideConfig {
    /// "Spaces + Wispr Flow" (the defaults before 2.10): the top buttons switch
    /// Spaces, and bottom left + both top buttons hold ⌃Space, Wispr Flow's
    /// push-to-talk. The primary button alone stays a left click.
    static let spacesAndWisprFlowButtons: [Int: ButtonAction] = [
        2: .shortcut(.previousSpace),
        3: .shortcut(.nextSpace),
    ]
    static let spacesAndWisprFlowChord = Chord(buttons: [0, 2, 3], action: .holdShortcut(.wisprFlow))

    /// Sets the preset's buttons and combo, leaving every other one as it is.
    mutating func applySpacesAndWisprFlow() {
        for (b, action) in Self.spacesAndWisprFlowButtons { buttons[b] = action }
        let chord = Self.spacesAndWisprFlowChord
        if let i = chords.firstIndex(where: { $0.buttons == chord.buttons }) {
            chords[i].action = chord.action
        } else {
            chords.append(Chord(buttons: chord.buttons, action: chord.action))   // a fresh id
        }
    }

    var hasSpacesAndWisprFlow: Bool {
        Self.spacesAndWisprFlowButtons.allSatisfy { buttons[$0.key] == $0.value }
            && chords.contains { $0.buttons == Self.spacesAndWisprFlowChord.buttons && $0.action == Self.spacesAndWisprFlowChord.action }
    }
}

/// A ready-made set for the Buttons page: what the three free buttons do, and
/// its combos. Choosing one sets all of it at once (the bottom-left button always
/// stays a left click); Undo and the backup history put back what was there.
struct ButtonPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    /// Buttons 1–3; any left out do their normal click.
    let buttons: [Int: ButtonAction]
    let chords: [Chord]

    static let all: [ButtonPreset] = [
        .init(id: "stock", title: String(localized: "Stock", comment: "Button preset: what the trackball does out of the box"),
              detail: String(localized: "What the trackball does out of the box: right click, middle click and Back. No combos.",
                             comment: "Button preset description"),
              symbol: "shippingbox", buttons: [:], chords: []),
        .init(id: "spaces", title: String(localized: "Spaces", comment: "Button preset name (macOS Spaces)"),
              detail: String(localized: "Top buttons switch Spaces. Both together open Mission Control; bottom right with top right shows the app’s windows.",
                             comment: "Button preset description"),
              symbol: "rectangle.split.3x1",
              buttons: [2: .shortcut(.previousSpace), 3: .shortcut(.nextSpace)],
              chords: [Chord(buttons: [2, 3], action: .shortcut(.missionControl)),
                       Chord(buttons: [1, 3], action: .shortcut(.appExpose))]),
        .init(id: "browser", title: String(localized: "Browser", comment: "Button preset name"),
              detail: String(localized: "Top left goes back, top right goes forward. Combos open, close and reopen tabs.",
                             comment: "Button preset description"),
              symbol: "safari",
              buttons: [2: .back, 3: .forward],
              chords: [Chord(buttons: [2, 3], action: .shortcut(.newTab)),
                       Chord(buttons: [1, 3], action: .shortcut(.closeTab)),
                       Chord(buttons: [1, 2], action: .shortcut(.reopenTab))]),
        .init(id: "editing", title: String(localized: "Editing", comment: "Button preset name"),
              detail: String(localized: "Top left copies, top right pastes. Both together undo; bottom right with top right redoes.",
                             comment: "Button preset description"),
              symbol: "doc.on.clipboard",
              buttons: [2: .shortcut(.copy), 3: .shortcut(.paste)],
              chords: [Chord(buttons: [2, 3], action: .shortcut(.undo)),
                       Chord(buttons: [1, 3], action: .shortcut(.redo))]),
        .init(id: "media", title: String(localized: "Media", comment: "Button preset name: music and video controls"),
              detail: String(localized: "Top left plays or pauses, top right skips ahead. Both together go back a track; bottom right with top right mutes.",
                             comment: "Button preset description"),
              symbol: "music.note",
              buttons: [2: .media(.playPause), 3: .media(.next)],
              chords: [Chord(buttons: [2, 3], action: .media(.previous)),
                       Chord(buttons: [1, 3], action: .media(.mute))]),
        .init(id: "gestures", title: String(localized: "Gestures", comment: "Button preset name: hold a button and roll the ball"),
              detail: String(localized: "Hold top right and roll: sideways switches Spaces, up opens Mission Control, down shows the app’s windows. Hold top left and roll for volume and tracks. A quick press still does what it did.",
                             comment: "Button preset description"),
              symbol: "dot.arrowtriangles.up.right.down.left.circle",
              buttons: [2: .gesture(ButtonGesture(up: GestureStep(.media(.volumeUp), repeats: true),
                                                  down: GestureStep(.media(.volumeDown), repeats: true),
                                                  left: GestureStep(.media(.previous)),
                                                  right: GestureStep(.media(.next)))),
                        3: .gesture(.standard)],
              chords: []),
        .init(id: "wispr", title: "Spaces + Wispr Flow",
              detail: String(localized: "Top buttons switch Spaces; bottom left + both top buttons hold ⌃Space for Wispr Flow."),
              symbol: "waveform",
              buttons: GlideConfig.spacesAndWisprFlowButtons, chords: [GlideConfig.spacesAndWisprFlowChord]),
    ]

    /// Whether a button would do something different with this preset.
    func changes(_ button: Int, from current: ButtonAction) -> Bool {
        !action(for: button).sameEffect(as: current, on: button)
    }

    /// What each button does with this preset (0…3).
    func action(for button: Int) -> ButtonAction { button == 0 ? .system : buttons[button] ?? .system }
}

extension GlideConfig {
    /// Sets every button and combo to the preset's.
    mutating func apply(_ preset: ButtonPreset) {
        buttons = preset.buttons
        chords = preset.chords.map { Chord(buttons: $0.buttons, action: $0.action) }   // fresh ids
    }

    /// The preset these buttons and combos match exactly, if any.
    var matchingPreset: ButtonPreset? {
        let mine = buttons.filter { $0.key != 0 && !$0.value.isNormal(for: $0.key) }
        let myChords = Set(chords.map { "\($0.buttons)\($0.action)" })
        return ButtonPreset.all.first { p in
            p.buttons == mine && Set(p.chords.map { "\($0.buttons)\($0.action)" }) == myChords
        }
    }
}

/// Portable, versioned settings file used by Glide's import and export controls,
/// the backups and sync.
///
/// `version` is also the guard against older Glideballs. Every Glideball since 2.0
/// refuses a file whose version isn't the one it knows (1): it won't import it,
/// and sync neither adopts it nor writes over it ("saved by a newer version").
/// So a file is written as version 2 only when its settings use something an
/// older Glideball would drop on the way back (`GlideConfig.requiredFileVersion`);
/// everything else stays version 1, and older Macs keep syncing as before.
struct GlideSettingsFile: Codable {
    /// The newest version this Glideball reads (and writes, when it has to).
    static let currentVersion = 2
    static let fileExtension = "glide-settings"
    let version: Int
    var config: GlideConfig
    /// When and where the file was made — shown in the import preview.
    /// Optional so files from before these fields existed still open.
    var exportedAt: Date?
    var exportedFrom: String?
    /// The Glideball that wrote it ("2.10"). Glideballs before this one don't
    /// write it, so a file without it came from one of them (see `keepingNewerFeatures`).
    var writtenBy: String?

    init(config: GlideConfig, exportedFrom: String? = Host.current().localizedName) {
        version = config.requiredFileVersion
        self.config = config
        exportedAt = Date()
        self.exportedFrom = exportedFrom
        writtenBy = Self.appVersion
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.10"
    }

    func validatedConfig() throws -> GlideConfig {
        guard (1...Self.currentVersion).contains(version) else {
            throw GlideSettingsFileError.unsupportedVersion(version)
        }
        return config
    }
}

extension ButtonAction {
    /// Added after 2.9: a Glideball before this one drops it when reading settings.
    var isNewerFeature: Bool {
        switch self {
        case .gesture, .media, .openApp: true
        default: false
        }
    }

    var isGesture: Bool { if case .gesture = self { true } else { false } }

    /// As a gesture direction, whether "keep going as you roll" makes sense for it
    /// (volume, zoom, tabs, undo), rather than once per hold (Mission Control).
    var repeatsWell: Bool {
        switch self {
        case .media(let k): k != .playPause && k != .mute
        case .back, .forward: true
        case .shortcut(let s):
            [KeyShortcut.zoomIn, .zoomOut, .nextTab, .previousTab, .undo, .redo, .browserBack, .browserForward,
             .nextSpace, .previousSpace].contains { $0.sameKeys(as: s) }
                || !ButtonAction.presets.contains { $0.action == self }   // your own shortcut: your call
        default: false
        }
    }

    /// Chosen for a direction, it starts out continuous (volume and zoom do; the rest fire once).
    var repeatsByDefault: Bool {
        switch self {
        case .media(.volumeUp), .media(.volumeDown): true
        case .shortcut(let s): s.sameKeys(as: .zoomIn) || s.sameKeys(as: .zoomOut)
        default: false
        }
    }
}

extension GlideConfig {
    /// 2 when these settings use something an older Glideball would drop if it read
    /// them and wrote them back (gesture buttons, per-display speeds, media keys,
    /// "Open an app"): the file then says so, and older Glideballs leave it alone.
    var requiredFileVersion: Int { usesNewerFeatures ? 2 : 1 }

    var usesNewerFeatures: Bool {
        anyAction(\.isNewerFeature) || displaySpeeds.enabled || !displaySpeeds.speeds.isEmpty
    }

    /// Whether any button or combo, in the main setup or an app setup, does `test`.
    func anyAction(_ test: (ButtonAction) -> Bool) -> Bool {
        func any(_ buttons: [Int: ButtonAction]?, _ chords: [Chord]?) -> Bool {
            (buttons ?? [:]).values.contains(where: test) || (chords ?? []).contains { test($0.action) }
        }
        return any(buttons, chords) || appProfiles.contains { any($0.buttons, $0.chords) }
    }

    /// Settings written by an older Glideball (`self`), merged with this Mac's
    /// (`local`): what the older one couldn't carry is put back from `local`.
    /// Newer buttons it dropped come back where it left the button unset, combos it
    /// dropped come back, and per-display speeds and the gestures switch, which it
    /// never knew, stay this Mac's. Anything it set explicitly wins. Returns the
    /// merged settings and whether a gesture (or another newer button) had to be kept.
    func keepingNewerFeatures(from local: GlideConfig) -> (config: GlideConfig, kept: Bool) {
        var out = self
        var kept = false
        func merge(_ incoming: inout [Int: ButtonAction], _ mine: [Int: ButtonAction]) {
            for (b, a) in mine where a.isNewerFeature && incoming[b] == nil {
                incoming[b] = a
                kept = true
            }
        }
        func merge(_ incoming: inout [Chord], _ mine: [Chord]) {
            for c in mine where c.action.isNewerFeature && !incoming.contains(where: { $0.id == c.id || $0.buttons == c.buttons }) {
                incoming.append(c)
                kept = true
            }
        }
        merge(&out.buttons, local.buttons)
        merge(&out.chords, local.chords)
        for i in out.appProfiles.indices {
            guard let mine = local.appProfiles.first(where: { $0.bundleID == out.appProfiles[i].bundleID }) else { continue }
            if let mb = mine.buttons, out.appProfiles[i].buttons != nil {
                var b = out.appProfiles[i].buttons ?? [:]
                merge(&b, mb)
                out.appProfiles[i].buttons = b
            }
            if let mc = mine.chords, out.appProfiles[i].chords != nil {
                var c = out.appProfiles[i].chords ?? []
                merge(&c, mc)
                out.appProfiles[i].chords = c
            }
        }
        if local.displaySpeeds.enabled || !local.displaySpeeds.speeds.isEmpty { kept = kept || out.displaySpeeds != local.displaySpeeds }
        out.displaySpeeds = local.displaySpeeds
        out.gesturesEnabled = local.gesturesEnabled
        // Gestures it dropped came back whole from `local`; any it kept lack the newer fields too.
        let tuned = out.keepingGestureTuning(from: local)
        return (tuned.config, kept || tuned.kept)
    }

    /// Settings written by a Glideball that knew gestures but not chained gestures,
    /// gesture distance and Steady hands (2.10 betas before `GlideSettingsFile.gestureTuningSince`),
    /// merged with this Mac's (`local`). It read and wrote back the gestures without
    /// those fields, so it could never have set them: the global distance and Steady
    /// hands stay this Mac's; a gesture on the same button (or combo) gets this Mac's
    /// distance back, and each direction this Mac had as "Once per hold" gets that back
    /// when the older one left its action alone. Returns whether anything came back.
    func keepingGestureTuning(from local: GlideConfig) -> (config: GlideConfig, kept: Bool) {
        var out = self
        var kept = false
        func restore(_ incoming: ButtonAction, _ mine: ButtonAction?) -> ButtonAction {
            guard case .gesture(var g) = incoming, case .gesture(let m)? = mine else { return incoming }
            let before = g
            if g.distance == nil { g.distance = m.distance }
            for d in GestureDirection.allCases {
                if let s = g[d], let ms = m[d], s.action == ms.action, !s.repeats, !s.once, ms.once { g[d]?.once = true }
            }
            if g != before { kept = true }
            return .gesture(g)
        }
        func merge(_ buttons: inout [Int: ButtonAction], _ mine: [Int: ButtonAction]) {
            for (b, a) in buttons { buttons[b] = restore(a, mine[b]) }
        }
        func merge(_ chords: inout [Chord], _ mine: [Chord]) {
            for i in chords.indices {
                let m = mine.first { $0.id == chords[i].id } ?? mine.first { $0.buttons == chords[i].buttons }
                chords[i].action = restore(chords[i].action, m?.action)
            }
        }
        merge(&out.buttons, local.buttons)
        merge(&out.chords, local.chords)
        for i in out.appProfiles.indices {
            guard let mine = local.appProfiles.first(where: { $0.bundleID == out.appProfiles[i].bundleID }) else { continue }
            if var b = out.appProfiles[i].buttons, let mb = mine.buttons {
                merge(&b, mb)
                out.appProfiles[i].buttons = b
            }
            if var c = out.appProfiles[i].chords, let mc = mine.chords {
                merge(&c, mc)
                out.appProfiles[i].chords = c
            }
        }
        if out.gestureDistance != local.gestureDistance || out.gestureSteadyHands != local.gestureSteadyHands {
            kept = kept || local.anyAction(\.isGesture)
        }
        out.gestureDistance = local.gestureDistance
        out.gestureSteadyHands = local.gestureSteadyHands
        return (out, kept)
    }
}

extension GlideSettingsFile {
    /// The first Glideball that writes chained gestures' field ("Once per hold"),
    /// a gesture's own distance, and the gesture distance and Steady hands settings.
    static let gestureTuningSince = "2.10-beta.12"

    /// Written by a Glideball that would have dropped those fields (no `writtenBy`
    /// at all is older still, before 2.10: see `keepingNewerFeatures`).
    static func predatesGestureTuning(_ writtenBy: String?) -> Bool {
        guard let writtenBy else { return true }
        guard let v = SettingsVersion(writtenBy), let since = SettingsVersion(gestureTuningSince) else { return false }
        return v < since
    }
}

/// "2.10", "2.10.1", "2.10-beta.12", in order (a beta before its release). Just
/// enough for `predatesGestureTuning`; anything unreadable is nil (and so never older).
struct SettingsVersion: Comparable {
    let numbers: [Int]
    let beta: Int?

    init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        numbers = nums.map { $0! }
        if parts.count == 2 {
            let label = parts[1].lowercased()
            guard label.hasPrefix("beta"), let n = Int(label.dropFirst(4).drop { $0 == "." || $0 == " " }) else { return nil }
            beta = n
        } else {
            beta = nil
        }
    }

    static func < (a: SettingsVersion, b: SettingsVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        default: return false
        }
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

// MARK: - Media keys, gestures and per-display speed

/// Which way the ball rolled while a gesture button was held. "Up" is rolling
/// the top of the ball away from you: the way the pointer would have gone up.
enum GestureDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

/// What one direction of a gesture does, fired one of three ways (`mode`): each
/// time you roll that way (the default: chained, as many as you like in one hold),
/// continuously as you roll (`repeats`), or once per hold (`once`).
struct GestureStep: Codable, Hashable {
    var action: ButtonAction
    /// Continuous: fires again for every further stretch of rolling (volume, say),
    /// and rolling back fires the opposite direction (if that one repeats too).
    var repeats = false
    /// At most once per hold (how every one-shot direction worked before chained
    /// gestures). Written only when on, so a Glideball that doesn't know it reads
    /// the same step and fires it once per hold anyway.
    var once = false

    enum Mode: String, CaseIterable {
        case chain, continuous, once
    }

    var mode: Mode {
        get { repeats ? .continuous : once ? .once : .chain }
        set {
            repeats = newValue == .continuous
            once = newValue == .once
        }
    }

    init(_ action: ButtonAction, repeats: Bool = false, once: Bool = false) {
        self.action = action
        self.repeats = repeats
        self.once = once && !repeats
    }

    private enum CodingKeys: String, CodingKey { case action, repeats, once }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(ButtonAction.self, forKey: .action)   // unknown: the whole step is skipped
        repeats = (try? c.decodeIfPresent(Bool.self, forKey: .repeats)) ?? false
        once = !repeats && ((try? c.decodeIfPresent(Bool.self, forKey: .once)) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(repeats, forKey: .repeats)
        if once { try c.encode(true, forKey: .once) }
    }

    /// The action as a gesture fires it, or nil if it can't be fired mid-gesture.
    /// Everything fires as a quick press and release: a gesture never holds a key,
    /// a mode or a button down, so letting go (or a pause, unplug or quit) has
    /// nothing to undo.
    var firable: ButtonAction? {
        switch action {
        case .holdShortcut(let s): .shortcut(s)
        case .shortcut, .media, .openApp, .leftClick, .rightClick, .middleClick, .back, .forward, .modifiedClick: action
        case .system, .disabled, .precisionHold, .precisionToggle, .ballScrollHold, .dragLock, .gesture: nil
        }
    }
}

/// A gesture button: hold it and roll the ball one of four ways, or tap it.
struct ButtonGesture: Codable, Hashable {
    var up: GestureStep?
    var down: GestureStep?
    var left: GestureStep?
    var right: GestureStep?
    /// A press and release without rolling past the threshold. `.system` is the button's own click.
    var tap: ButtonAction = .system
    /// This gesture's own distance; nil follows `GlideConfig.gestureDistance`.
    var distance: GestureDistance?

    init(up: GestureStep? = nil, down: GestureStep? = nil, left: GestureStep? = nil, right: GestureStep? = nil,
         tap: ButtonAction = .system, distance: GestureDistance? = nil) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
        self.tap = tap
        self.distance = distance
    }

    /// Spaces left and right, Mission Control up, App Exposé down; a tap is the button's own click.
    static let standard = ButtonGesture(up: GestureStep(.shortcut(.missionControl)),
                                        down: GestureStep(.shortcut(.appExpose)),
                                        left: GestureStep(.shortcut(.previousSpace)),
                                        right: GestureStep(.shortcut(.nextSpace)))

    /// Volume up and down as you roll, Previous / Next Track left and right; a tap plays or pauses.
    static let media = ButtonGesture(up: GestureStep(.media(.volumeUp), repeats: true),
                                     down: GestureStep(.media(.volumeDown), repeats: true),
                                     left: GestureStep(.media(.previous)),
                                     right: GestureStep(.media(.next)),
                                     tap: .media(.playPause))

    /// Tabs: left and right move between them (a tab each time you roll), up opens one, down closes one.
    static let tabs = ButtonGesture(up: GestureStep(.shortcut(.newTab)),
                                    down: GestureStep(.shortcut(.closeTab)),
                                    left: GestureStep(.shortcut(.previousTab)),
                                    right: GestureStep(.shortcut(.nextTab)))

    /// Zoom in and out as you roll up and down; left and right go back and forward.
    static let zoom = ButtonGesture(up: GestureStep(.shortcut(.zoomIn), repeats: true),
                                    down: GestureStep(.shortcut(.zoomOut), repeats: true),
                                    left: GestureStep(.back),
                                    right: GestureStep(.forward))

    /// A ready-made set of four directions, for the gesture editor.
    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let gesture: ButtonGesture
        /// The set comes with its own tap (Volume: play or pause); otherwise the tap stays.
        var ownTap = false

        func applied(to current: ButtonGesture) -> ButtonGesture {
            var g = gesture
            if !ownTap { g.tap = current.tap }
            g.distance = current.distance
            return g
        }

        func matches(_ g: ButtonGesture) -> Bool {
            GestureDirection.allCases.allSatisfy { g[$0] == gesture[$0] } && (!ownTap || g.tap == gesture.tap)
        }
    }

    static var suggestions: [Suggestion] {
        [
            .init(id: "spaces", title: String(localized: "Spaces", comment: "Gesture set: switch Spaces, Mission Control, App Exposé"),
                  symbol: "rectangle.split.3x1", gesture: .standard),
            .init(id: "media", title: String(localized: "Volume and music", comment: "Gesture set: volume up/down, previous/next track, tap plays"),
                  symbol: "speaker.wave.2", gesture: .media, ownTap: true),
            .init(id: "tabs", title: String(localized: "Tabs", comment: "Gesture set: previous/next tab, new tab, close tab"),
                  symbol: "square.on.square", gesture: .tabs),
            .init(id: "zoom", title: String(localized: "Zoom and history", comment: "Gesture set: zoom in/out, back/forward"),
                  symbol: "plus.magnifyingglass", gesture: .zoom),
        ]
    }

    /// Turning a button into a gesture keeps what it did as the tap.
    static func keeping(_ previous: ButtonAction) -> ButtonGesture {
        if case .gesture(let old) = previous { return old }
        var g = ButtonGesture.standard
        g.tap = previous
        return g
    }

    subscript(direction: GestureDirection) -> GestureStep? {
        get {
            switch direction {
            case .up: up
            case .down: down
            case .left: left
            case .right: right
            }
        }
        set {
            switch direction {
            case .up: up = newValue
            case .down: down = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    /// The tap as it's performed: a held action can't be held after the release,
    /// so a held shortcut is a quick press, and held modes (or another gesture) do nothing.
    var tapAction: ButtonAction {
        switch tap {
        case .holdShortcut(let s): .shortcut(s)
        case .precisionHold, .ballScrollHold, .gesture: .disabled
        default: tap
        }
    }

    // A newer Glideball may write actions or fields this one doesn't know: skip
    // just that direction (or use the plain click for the tap), never the whole button.
    private enum CodingKeys: String, CodingKey { case up, down, left, right, tap, distance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func step(_ key: CodingKeys) -> GestureStep? { (try? c.decodeIfPresent(GestureStep.self, forKey: key)) ?? nil }
        up = step(.up)
        down = step(.down)
        left = step(.left)
        right = step(.right)
        tap = (try? c.decodeIfPresent(ButtonAction.self, forKey: .tap)) ?? .system
        distance = (try? c.decodeIfPresent(GestureDistance.self, forKey: .distance)) ?? nil
    }
}

/// How far the ball rolls before a gesture's direction fires (`GestureTuning.for`).
enum GestureDistance: String, Codable, CaseIterable, Identifiable {
    case short, normal, long
    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: String(localized: "Short", comment: "Gesture distance: a short roll fires a direction")
        case .normal: String(localized: "Normal", comment: "Gesture distance")
        case .long: String(localized: "Long", comment: "Gesture distance: a longer roll fires a direction")
        }
    }
}

/// An optional pointer speed for each display, used while the pointer is on it.
///
/// Precedence, highest first: Precision (while on), an app setup's own pointer
/// speed, this display's speed (when `enabled` and it has one), the main speed.
/// `GlideConfig.resolved(for:)` switches this off when the app setup in front has
/// its own speed, so the engine only has to look here.
struct DisplaySpeeds: Codable, Equatable {
    var enabled = false
    /// Display key (`DisplayKey`) → tracking speed.
    var speeds: [String: Double] = [:]
    /// Display key → its name when last seen, so a display that isn't connected can still be named.
    var names: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        speeds = ((try? c.decodeIfPresent([String: Double].self, forKey: .speeds)) ?? [:]).filter { $0.value.isFinite && $0.value > 0 }
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? [:]
    }

    /// The speed for the display the pointer is on, or nil to use the main speed.
    func speed(for display: String?) -> Double? {
        guard enabled, let display else { return nil }
        return speeds[display]
    }

    /// Worth watching which display the pointer is on at all.
    var isActive: Bool { enabled && !speeds.isEmpty }
}
