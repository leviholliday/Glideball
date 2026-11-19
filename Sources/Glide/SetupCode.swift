import Carbon.HIToolbox
import CoreGraphics
import Foundation

// "Set up with AI": the setup code a chatbot writes, and reading one that's pasted back.
//
// Glideball has no AI in it and sends nothing anywhere. It copies a prompt (AIReference.swift)
// that the person pastes into whichever chatbot they use; the chatbot ends with a block of
// plain JSON, a "setup code"; the person pastes that here. A setup code is the share format
// (docs/SHARE-FORMAT.md) with a thinner skin, because the raw format asks for macOS key codes,
// modifier bitmasks and bundle IDs, and a chatbot gets those wrong:
//
//  - an action is short text: "rightClick", "keys:cmd+shift+4", "media:volumeUp", "open:Notes";
//  - an app is given by its name, and found on this Mac (never guessed: an app that isn't
//    here is left out and listed);
//  - only what changes is in it. Partial scroll and sound settings are laid over what the
//    person has now, and so are an app setup's areas and the combos.
//
// Reading one is a pre-pass and nothing more. The text is hostile until proven otherwise (it
// came out of a chatbot, which may have read anything): it's size-capped, depth-checked and
// parsed as plain JSON; each value is checked for its type; everything it can't use is left
// out and written down (`Note`), never guessed at. What's left becomes an ordinary
// `SharedSetup`, which is written out and read back through `SharedSetup.decode(json:)`, the
// decoder that already faces links from strangers. From there it's the same clamping,
// `ImportSafety`, review sheet, backup checkpoint and Undo as any shared setup. So:
//
//  - nothing changes until Apply in Glideball's own window;
//  - the primary button (button 0) is never read, and the share path never sets it;
//  - a code can't carry a sender's name, per-display speeds, a Switcher's hidden apps,
//    Glideball's own keyboard shortcuts or the pause switch;
//  - a code can't run anything: `ButtonAction` has no action that does (`isSettingsOnly`).
//
// It's pasted into the same box as a shared link (`ImportPaste.read(_:codes:codeFirst:)`,
// Views/PasteViews.swift): a Glideball link in the text is still read by the link rules
// there, and only the JSON is read here.
//
// Foundation only, so scripts/import-sim compiles and fuzzes it.

/// Finding apps on this Mac for a setup code (the app looks in Launch Services and the
/// Applications folders; the simulators and renders use a fixed list).
struct SetupApps: Sendable {
    /// The app a name or bundle ID means on this Mac, or nil when there isn't one.
    var find: @Sendable (String) -> (bundleID: String, name: String)?
    /// An installed app's name, for writing "open:Notes".
    var name: @Sendable (String) -> String?

    static let none = SetupApps(find: { _ in nil }, name: { _ in nil })

    /// A fixed list (name → bundle ID), for the simulators, renders and the self-test.
    static func fixed(_ list: [String: String]) -> SetupApps {
        SetupApps(find: { text in
            if let hit = list.first(where: { $0.key.caseInsensitiveCompare(text) == .orderedSame }) { return (hit.value, hit.key) }
            if let hit = list.first(where: { $0.value == text }) { return (hit.value, hit.key) }
            return nil
        }, name: { id in list.first { $0.value == id }?.key })
    }
}

/// The keys and modifiers a shortcut is written with. One table, used both ways: reading
/// "cmd+shift+4" and writing a shortcut the person already has.
enum SetupKeys {
    /// Keys that mean the same on every keyboard. The first name for a key code is the one written.
    static let fixed: [(name: String, code: Int)] = [
        ("space", kVK_Space), ("tab", kVK_Tab), ("return", kVK_Return), ("escape", kVK_Escape),
        ("delete", kVK_Delete), ("forwardDelete", kVK_ForwardDelete),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow), ("down", kVK_DownArrow),
        ("home", kVK_Home), ("end", kVK_End), ("pageUp", kVK_PageUp), ("pageDown", kVK_PageDown),
        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5), ("f6", kVK_F6),
        ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18),
        ("f19", kVK_F19), ("f20", kVK_F20),
    ]

    /// Other things people call the same keys (lowercased).
    static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "spacebar": "space",
        "pgup": "pageup", "pgdn": "pagedown", "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    ]

    /// Punctuation by name, for when the character itself is awkward to write ("+" joins a shortcut).
    static let punctuation: [String: String] = [
        "plus": "+", "minus": "-", "equals": "=", "equal": "=", "comma": ",", "period": ".", "dot": ".", "slash": "/",
        "backslash": "\\", "semicolon": ";", "quote": "'", "apostrophe": "'", "backtick": "`", "grave": "`",
        "leftbracket": "[", "rightbracket": "]",
    ]

    /// The modifiers, in the order they're written. The first name is the one written.
    static let modifiers: [(names: [String], flag: CGEventFlags)] = [
        (["ctrl", "control", "⌃"], .maskControl),
        (["opt", "option", "alt", "⌥"], .maskAlternate),
        (["cmd", "command", "⌘"], .maskCommand),
        (["shift", "⇧"], .maskShift),
        (["fn", "globe"], .maskSecondaryFn),
    ]

    static func modifier(_ token: String) -> CGEventFlags? {
        let t = token.lowercased()
        return modifiers.first { $0.names.contains(t) }?.flag
    }

    /// The key a token means: a fixed key, "key50" (a key code, for keys with no simple name),
    /// or the key that types that character on this Mac's keyboard (a US keyboard's when it
    /// can't be found). Nil for anything else, including a modifier on its own.
    static func code(_ token: String, command: Bool) -> Int? {
        var t = token.lowercased()
        if let a = aliases[t] { t = a }
        if let hit = fixed.first(where: { $0.name.lowercased() == t }) { return hit.code }
        if t.hasPrefix("key"), let n = Int(t.dropFirst(3)), (0...127).contains(n), t == "key\(n)" { return n }
        if let p = punctuation[t] { t = p }
        guard (1...3).contains(t.count), modifier(t) == nil else { return nil }
        // "+" where no key types it on its own (a US keyboard): the = key, as Glideball's own Zoom In is.
        return KeyNames.code(typing: t, command: command) ?? (t == "+" ? KeyNames.code(typing: "=", command: command) : nil)
    }

    /// How a key is written. `us`: by what a US keyboard prints on it, whatever this Mac's
    /// layout (the reference's own examples); otherwise by this Mac's layout, so what the
    /// chatbot is shown is what the button presses here.
    static func token(_ keyCode: UInt16, command: Bool, us: Bool = false) -> String {
        let code = Int(keyCode)
        if let hit = fixed.first(where: { $0.code == code }) { return hit.name }
        guard let usName = KeyNames.us[code] else { return "key\(code)" }
        var name = (us ? usName : KeyNames.name(keyCode, command: command)).lowercased()
        if name == "+" { name = "plus" } else if name == "\\" { name = "backslash" }
        // Only a name that reads back as this same key; anything else goes by its key code.
        let typed = punctuation[name] ?? name
        let back = us ? KeyNames.us.filter { $0.value.lowercased() == typed }.keys.min() : self.code(name, command: command)
        return back == code && !name.contains("\"") ? name : "key\(code)"
    }

    /// "ctrl+cmd+shift+" for these modifiers, in the order people usually write them.
    static func prefix(_ flags: CGEventFlags) -> String {
        modifiers.filter { flags.contains($0.flag) }.map { $0.names[0] + "+" }.joined()
    }

    /// "cmd+shift+4" → the modifiers and the last token. Nil when a piece is empty or a
    /// modifier isn't one. "cmd++" is ⌘ with the + key.
    static func split(_ text: String) -> (flags: CGEventFlags, last: String)? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.last, !last.isEmpty, parts.count <= 6 else { return nil }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            guard let f = modifier(m) else { return nil }
            flags.insert(f)
        }
        return (flags, last)
    }

    /// A shortcut from its text. It needs a real key: modifiers alone aren't one.
    static func shortcut(_ text: String) -> KeyShortcut? {
        guard let (flags, last) = split(text), let code = code(last, command: flags.contains(.maskCommand)) else { return nil }
        return KeyShortcut(keyCode: UInt16(code), modifiers: flags.rawValue)
    }

    static func text(_ s: KeyShortcut, us: Bool = false) -> String {
        prefix(s.flags.intersection(CGEventFlags(rawValue: KeyShortcut.allowedModifiers)))
            + token(s.keyCode, command: s.flags.contains(.maskCommand), us: us)
    }

    /// The buttons a click with modifiers can press.
    static let clickButtons = ["left", "right", "middle", "button4", "button5"]

    static let media: [(name: String, key: MediaKey)] = MediaKey.allCases.map { (name($0), $0) }

    static func name(_ key: MediaKey) -> String {
        switch key {
        case .volumeUp: "volumeUp"
        case .volumeDown: "volumeDown"
        case .brightnessUp: "brightnessUp"
        case .brightnessDown: "brightnessDown"
        case .mute: "mute"
        case .playPause: "playPause"
        case .next: "next"
        case .previous: "previous"
        }
    }
}

/// The scroll settings a code can set: one table, read by the pre-pass and written into the
/// reference (AIReference.swift), so the two can't disagree. import-sim checks it against
/// `ScrollSettings` itself and `SettingRanges`.
enum SetupFields {
    struct Number {
        let key: String
        let path: WritableKeyPath<ScrollSettings, Double>
        let range: ClosedRange<Double>
        /// The scroll mode it belongs to (nil: every mode).
        let mode: ScrollMode?
        /// What it is, for the chatbot (English).
        let about: String
    }

    struct Flag {
        let key: String
        let path: WritableKeyPath<ScrollSettings, Bool>
        let mode: ScrollMode?
        let about: String
    }

    static let scrollNumbers: [Number] = [
        Number(key: "nativeScrollSpeed", path: \.nativeScrollSpeed, range: SettingRanges.nativeScrollSpeed, mode: .native,
               about: "macOS's own wheel speed; System Settings stops at 1.7"),
        Number(key: "flyDistance", path: \.flyDistance, range: SettingRanges.flyDistance, mode: .flywheel,
               about: "points the page moves for one slow tick"),
        Number(key: "flyAcceleration", path: \.flyAcceleration, range: SettingRanges.flyAcceleration, mode: .flywheel,
               about: "how much harder fast spins push"),
        Number(key: "flyGlide", path: \.flyGlide, range: SettingRanges.unit, mode: .flywheel,
               about: "how long the page coasts, short to long"),
        Number(key: "flyReach", path: \.flyReach, range: SettingRanges.unit, mode: .flywheel,
               about: "how far the very fastest spins go"),
        Number(key: "scrollDistance", path: \.scrollDistance, range: SettingRanges.scrollDistance, mode: .follow,
               about: "points per tick"),
        Number(key: "scrollSmoothness", path: \.scrollSmoothness, range: SettingRanges.unit, mode: .follow,
               about: "locked to the ring, to soft"),
        Number(key: "scrollAcceleration", path: \.scrollAcceleration, range: SettingRanges.unit, mode: .follow,
               about: "none, to a lot"),
        Number(key: "throwAmount", path: \.throwAmount, range: SettingRanges.unit, mode: .follow,
               about: "how far a throw goes"),
    ]

    static let scrollFlags: [Flag] = [
        Flag(key: "throwEnabled", path: \.throwEnabled, mode: .follow, about: "a fast flick throws the page and it coasts"),
        Flag(key: "smoothScrolling", path: \.smoothScrolling, mode: nil, about: "smooth scrolling"),
        Flag(key: "reverseScroll", path: \.reverseScroll, mode: nil, about: "scroll the other way"),
        Flag(key: "shiftScrollsHorizontally", path: \.shiftScrollsHorizontally, mode: nil, about: "holding Shift scrolls sideways"),
    ]

    /// Every key a code's "scroll" may hold.
    static var scrollKeys: [String] { ["scrollMode"] + scrollNumbers.map(\.key) + scrollFlags.map(\.key) }

    /// A gesture's own keys, besides its eight directions.
    static let gestureKeys = ["tap", "eight", "show", "ring", "ringUp", "ringDown", "reverse", "distance"]

    /// The top-level keys of a code that do something.
    static let topKeys = ["trackingSpeed", "precisionSpeed", "scroll", "ballScrollSpeed", "buttons", "combos",
                          "gesturesEnabled", "gestureDistance", "gestureSteadyHands", "apps", "look", "sounds"]
    /// Read as the same thing ("chords" is the share format's own word for combos).
    static let topAliases = ["chords": "combos"]
    /// Skipped without a word: a code's own labels, and what a chatbot likes to add.
    static let ignoredTopKeys: Set<String> = ["format", "version", "kind", "parts", "from", "writtenBy", "comment", "comments",
                                              "note", "notes", "summary", "description", "name", "title"]
    /// Things a code can never change. Listed as left out, so nobody thinks they applied.
    static let forbiddenTopKeys: Set<String> = ["displaySpeeds", "globalShortcuts", "enabled", "paused", "config", "appProfiles", "hidden"]
}

/// A small ordered JSON value, so a code is written with its keys in a sensible order.
indirect enum SetupJSON {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SetupJSON])
    case object([(String, SetupJSON)])

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F || (0x2028...0x2029).contains(u.value) {
                    out += "\\u" + String(repeating: "0", count: 4 - String(u.value, radix: 16).count) + String(u.value, radix: 16)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// 4, 0.35, 14: no more digits than a slider has.
    static func show(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let r = (v * 10_000).rounded() / 10_000
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        return String(r)
    }

    /// On one line.
    var compact: String {
        switch self {
        case .string(let s): Self.quote(s)
        case .number(let n): Self.show(n)
        case .bool(let b): b ? "true" : "false"
        case .array(let a): "[" + a.map(\.compact).joined(separator: ", ") + "]"
        case .object(let o): "{" + o.map { Self.quote($0.0) + ": " + $0.1.compact }.joined(separator: ", ") + "}"
        }
    }

    /// An object with one key per line (and the lists inside "buttons" and "apps" one per line too).
    var lines: String {
        guard case .object(let o) = self else { return compact }
        func row(_ key: String, _ v: SetupJSON) -> String {
            if case .object(let inner) = v, key == "buttons", inner.count > 1 {
                return " " + Self.quote(key) + ": {\n" + inner.map { "  " + Self.quote($0.0) + ": " + $0.1.compact }.joined(separator: ",\n") + "\n }"
            }
            if case .array(let inner) = v, key == "apps" || key == "combos", inner.count > 1 {
                return " " + Self.quote(key) + ": [\n" + inner.map { "  " + $0.compact }.joined(separator: ",\n") + "\n ]"
            }
            return " " + Self.quote(key) + ": " + v.compact
        }
        return "{\n" + o.map { row($0.0, $0.1) }.joined(separator: ",\n") + "\n}"
    }
}

enum SetupCode {
    static let formatMarker = "glideball-ai-setup"
    static let version = 1
    /// The most text the paste box looks at (a chatbot's whole answer can come along with the code).
    static let maxPasteBytes = 256 * 1024
    /// The most JSON a code may be (a full one is 2 or 3 KB).
    static let maxBytes = 64 * 1024
    /// An action's text: nothing real is longer than "holdKeys:ctrl+opt+shift+cmd+forwardDelete".
    static let maxTextLength = 120
    static let maxNotes = 40
    /// How an Open is written when the person left app names out of the prompt.
    static let hiddenApp = "(hidden)"

    // MARK: Settings only

    /// Every action a button can have only changes what Glideball does with the trackball:
    /// a click, keys, a media key, opening an app, a mode, Gestures, the Switcher, nothing.
    /// None runs a command, a script or a file, so a setup code can't either.
    ///
    /// The switch has no `default` on purpose. Adding a `ButtonAction` case stops the build
    /// here until someone decides: if the new action runs anything, return false, and refuse
    /// it in `SetupCodeReader.action` and in `ButtonAction.sanitized()` (ImportSafety.swift).
    static func isSettingsOnly(_ action: ButtonAction) -> Bool {
        switch action {
        case .system, .leftClick, .rightClick, .middleClick, .back, .forward, .disabled: true
        case .shortcut, .holdShortcut, .modifiedClick, .media: true
        case .precisionHold, .precisionToggle, .ballScrollHold, .dragLock: true
        case .openApp: true   // opens an app that's installed, by its bundle ID; marked in the review
        case .gesture(let g):
            GestureDirection.allCases.allSatisfy { d in
                guard let step = g[d] else { return true }
                return isSettingsOnly(step.action) && (step.more ?? []).allSatisfy { $0.map { isSettingsOnly($0.action) } ?? true }
            } && isSettingsOnly(g.tap) && (g.ringUp.map(isSettingsOnly) ?? true) && (g.ringDown.map(isSettingsOnly) ?? true)
        case .wheel(let w): isSettingsOnly(.gesture(ButtonGesture(wheel: w)))
        case .switcher(let a): isSettingsOnly(a.tap)
        }
    }

    // MARK: Actions as text

    /// The actions with no parameters, by their text.
    static let simple: [(text: String, action: ButtonAction)] = [
        ("system", .system), ("leftClick", .leftClick), ("rightClick", .rightClick), ("middleClick", .middleClick),
        ("back", .back), ("forward", .forward), ("disabled", .disabled),
        ("precisionHold", .precisionHold), ("precisionToggle", .precisionToggle),
        ("ballScrollHold", .ballScrollHold), ("dragLock", .dragLock),
    ]
    /// Other spellings read as the same thing (lowercased).
    static let simpleAliases: [String: ButtonAction] = ["default": .system, "donothing": .disabled, "none": .disabled]

    /// An action as a code writes it: text, or an object for Gestures and a Switcher with its
    /// own tap. Nil for what a code can't hold (a click on a button macOS doesn't have).
    /// `us`: shortcuts by a US keyboard's names (the reference's examples); `showApps` false
    /// writes every Open as "open:(hidden)".
    static func write(_ action: ButtonAction, apps: SetupApps = .none, showApps: Bool = true, us: Bool = false) -> SetupJSON? {
        switch action {
        case .system, .leftClick, .rightClick, .middleClick, .back, .forward, .disabled,
             .precisionHold, .precisionToggle, .ballScrollHold, .dragLock:
            return simple.first { $0.action == action }.map { .string($0.text) }
        case .shortcut(let s): return .string("keys:" + SetupKeys.text(s, us: us))
        case .holdShortcut(let s): return .string("holdKeys:" + SetupKeys.text(s, us: us))
        case .modifiedClick(let button, let modifiers):
            guard SetupKeys.clickButtons.indices.contains(button) else { return nil }
            let flags = CGEventFlags(rawValue: modifiers & KeyShortcut.allowedModifiers)
            return .string("click:" + SetupKeys.prefix(flags) + SetupKeys.clickButtons[button])
        case .media(let key): return .string("media:" + SetupKeys.name(key))
        case .openApp(let id):
            guard showApps else { return .string("open:" + hiddenApp) }
            return appName(id, apps: apps).map { .string("open:" + $0) }
        case .gesture(let g): return .object([("gesture", write(g, apps: apps, showApps: showApps, us: us))])
        case .wheel(let w): return write(.gesture(ButtonGesture(wheel: w)), apps: apps, showApps: showApps, us: us)
        case .switcher(let a):
            guard a.tap != .system, let tap = write(a.tap, apps: apps, showApps: showApps, us: us) else { return .string("switcher") }
            return .object([("switcher", .object([("tap", tap)]))])
        }
    }

    /// How an app is named in the prompt: its own name on this Mac (never one typed into a
    /// setup), cleaned and at most 40 characters, and only if that name finds the same app
    /// again and has nothing in it that could be taken for markup or the end of a string.
    /// Otherwise its bundle ID.
    static func appName(_ bundleID: String, apps: SetupApps) -> String? {
        if let name = apps.name(bundleID).map({ ImportText.clean($0, max: 40) }), !name.isEmpty, name != hiddenApp,
           !name.contains(where: { "<>\"\\{}".contains($0) }), apps.find(name)?.bundleID == bundleID {
            return name
        }
        return ImportText.isBundleID(bundleID) ? bundleID : nil
    }

    /// How a direction fires when a code doesn't say: volume and zoom keep going as you
    /// roll (as when you pick them in the app); everything else fires each time you roll.
    static func defaultMode(_ action: ButtonAction) -> GestureStep.Mode { action.repeatsByDefault ? .continuous : .chain }

    static func write(_ step: GestureStep, apps: SetupApps, showApps: Bool, us: Bool) -> SetupJSON? {
        if let more = step.more {
            var places: [(String, SetupJSON)] = []
            for (i, inner) in more.enumerated().prefix(8) {
                guard let inner, inner.more == nil, let j = write(inner, apps: apps, showApps: showApps, us: us) else { continue }
                places.append((GestureDirection(place: i).rawValue, j))
            }
            return .object([("more", .object(places))])
        }
        guard let action = write(step.action, apps: apps, showApps: showApps, us: us) else { return nil }
        if step.mode == defaultMode(step.action) { return action }
        return .object([("do", action), ("mode", .string(step.mode.rawValue))])
    }

    static func write(_ g: ButtonGesture, apps: SetupApps, showApps: Bool, us: Bool) -> SetupJSON {
        var o: [(String, SetupJSON)] = []
        for d in g.usedDirections {
            if let step = g[d], let j = write(step, apps: apps, showApps: showApps, us: us) { o.append((d.rawValue, j)) }
        }
        if let tap = write(g.tap, apps: apps, showApps: showApps, us: us) { o.append(("tap", tap)) }
        if g.eight { o.append(("eight", .bool(true))) }
        o.append(("show", .string(g.show.rawValue)))
        o.append(("ring", .string(g.ring.rawValue)))
        if g.ring == .custom {
            if let a = g.ringUp.flatMap({ write($0, apps: apps, showApps: showApps, us: us) }) { o.append(("ringUp", a)) }
            if let a = g.ringDown.flatMap({ write($0, apps: apps, showApps: showApps, us: us) }) { o.append(("ringDown", a)) }
        }
        if g.reverse { o.append(("reverse", .bool(true))) }
        if let d = g.distance { o.append(("distance", .string(d.rawValue))) }
        return .object(o)
    }

    // MARK: The person's setup, as a code

    static func write(_ s: ScrollSettings) -> SetupJSON {
        var o: [(String, SetupJSON)] = [("scrollMode", .string(s.scrollMode.rawValue))]
        for f in SetupFields.scrollNumbers { o.append((f.key, .number(s[keyPath: f.path]))) }
        for f in SetupFields.scrollFlags { o.append((f.key, .bool(s[keyPath: f.path]))) }
        return .object(o)
    }

    private static func write(buttons: [Int: ButtonAction], always: ClosedRange<Int>?, apps: SetupApps, showApps: Bool) -> SetupJSON {
        var o: [(String, SetupJSON)] = []
        for b in ImportLimits.buttons {
            let a = buttons[b]
            guard a != nil || (always?.contains(b) ?? false) else { continue }
            if let j = write(a ?? .system, apps: apps, showApps: showApps) { o.append((String(b), j)) }
        }
        return .object(o)
    }

    private static func write(combos: [Chord], apps: SetupApps, showApps: Bool) -> SetupJSON {
        .array(combos.compactMap { c in
            write(c.action, apps: apps, showApps: showApps).map {
                .object([("buttons", .array(c.buttons.map { .number(Double($0)) })), ("action", $0)])
            }
        })
    }

    /// The person's setup as a setup code: what the prompt shows the chatbot, written by the
    /// same code that reads one back, so it's something Glideball reads by definition.
    ///
    /// In it: pointer and scroll settings, what each button, combo and gesture does, the
    /// gesture settings, app setups and the apps buttons open (by name; none of it with
    /// `showApps` off), the ball color's name and the sound switches. Never in it: a sharing
    /// name, the Mac's or a display's name, per-display speeds, custom ball colors, a
    /// Switcher's hidden apps, Glideball's own keyboard shortcuts, the pause switch, or any path.
    static func write(_ c: GlideConfig, look: ShareLook?, sounds: ShareSounds?, apps: SetupApps, showApps: Bool = true) -> SetupJSON {
        var o: [(String, SetupJSON)] = [("format", .string(formatMarker)), ("version", .number(Double(version)))]
        o.append(("trackingSpeed", .number(c.trackingSpeed)))
        o.append(("precisionSpeed", .number(c.precisionSpeed)))
        o.append(("scroll", write(c.scrollSettings)))
        o.append(("ballScrollSpeed", .number(c.ballScrollSpeed)))
        o.append(("buttons", write(buttons: c.buttons, always: 1...3, apps: apps, showApps: showApps)))
        o.append(("combos", write(combos: c.chords, apps: apps, showApps: showApps)))
        o.append(("gesturesEnabled", .bool(c.gesturesEnabled)))
        o.append(("gestureDistance", .string(c.gestureDistance.rawValue)))
        o.append(("gestureSteadyHands", .bool(c.gestureSteadyHands)))
        if showApps, !c.appProfiles.isEmpty {
            o.append(("apps", .array(c.appProfiles.prefix(ImportLimits.maxAppSetups).compactMap { p -> SetupJSON? in
                guard ImportText.isBundleID(p.bundleID) else { return nil }
                guard let name = appName(p.bundleID, apps: apps) else { return nil }
                var a: [(String, SetupJSON)] = [("app", .string(name))]
                if let v = p.trackingSpeed { a.append(("trackingSpeed", .number(v))) }
                if let s = p.scroll { a.append(("scroll", write(s))) }
                if let b = p.buttons { a.append(("buttons", write(buttons: b, always: 1...3, apps: apps, showApps: showApps))) }
                if let ch = p.chords { a.append(("combos", write(combos: ch, apps: apps, showApps: showApps))) }
                return .object(a)
            })))
        }
        if let look, ShareLook.themeIDs.contains(look.theme) { o.append(("look", .object([("theme", .string(look.theme))]))) }
        if let sounds {
            let kinds = ShareSounds.kindIDs.compactMap { id in sounds.kinds[id].map { (id, SetupJSON.bool($0)) } }
            o.append(("sounds", .object([("on", .bool(sounds.on)), ("volume", .number(sounds.volume)), ("kinds", .object(kinds))])))
        }
        return .object(o)
    }

    // MARK: Finding the code in what was pasted

    enum Problem: Error, Equatable {
        /// Nothing was pasted.
        case empty
        case tooBig
        case tooDeep
        /// It starts like a code and never ends: the copy was cut short.
        case cutOff
        /// No JSON object in it, or one that can't be read even after tidying.
        case notJSON
        /// JSON, but not a setup code (nor a shared setup, a link or a settings file).
        case notASetup
        /// A code for a Glideball newer than this one.
        case newerVersion
        /// A setup code, and everything in it was left out (with what and why).
        case nothingUsable([Note])

        /// What to tell the chatbot (English: it's the chatbot that reads it).
        var forAI: String {
            switch self {
            case .empty: "Please give me the setup code again."
            case .tooBig, .tooDeep: "That was too long for Glideball to read. Please give me the setup code again, as one JSON object in one code block, with only what changes."
            case .cutOff: "Glideball couldn't read your last setup code: it was cut off before the last }. Please give me the whole code again in one code block."
            case .notJSON: "Glideball couldn't read your last setup code: it isn't valid JSON. Please give me the code again as one JSON object in one code block, with straight double quotes, no comments and nothing else in the block."
            case .notASetup: "That wasn't a Glideball setup code. Please give me the setup code: one JSON object that starts with \"format\": \"\(formatMarker)\" and \"version\": \(version)."
            case .newerVersion: "Glideball only reads setup codes with \"version\": \(version). Please give me the code again in that form."
            case .nothingUsable(let notes):
                notes.isEmpty ? "Glideball couldn't use anything in your last setup code. Please give me a new one that uses only what the reference lists."
                    : SetupCode.noteForAI(notes, nothingElse: true)
            }
        }
    }

    /// Curly quotes a chat page (or macOS) put where straight ones were.
    private static let curly: [Character: Character] = ["“": "\"", "”": "\"", "„": "\"", "‟": "\"", "«": "\"", "»": "\"",
                                                        "‘": "'", "’": "'", "‚": "'", "‛": "'"]

    /// The top-level `{…}` blocks in `text`, strings skipped. `open`: one started and never closed.
    static func objects(in text: [UInt8]) -> (found: [Range<Int>], open: Bool) {
        var found: [Range<Int>] = []
        var depth = 0, start = 0, inString = false, escaped = false
        for (i, byte) in text.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: if depth > 0 { inString = true }
            case 0x7B:
                if depth == 0 { start = i }
                depth += 1
            case 0x7D:
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 { found.append(start..<(i + 1)) }
            default: break
            }
        }
        return (found, depth > 0)
    }

    /// The same JSON without what JSON doesn't allow but chatbots write anyway: comments,
    /// a comma before a closing bracket, odd spaces. Strings are left exactly as they are.
    static func tidied(_ json: String) -> String {
        var out = String.UnicodeScalarView()
        let s = Array(json.unicodeScalars)
        var i = 0, inString = false, escaped = false
        while i < s.count {
            let u = s[i]
            if inString {
                out.append(u)
                if escaped { escaped = false } else if u == "\\" { escaped = true } else if u == "\"" { inString = false }
                i += 1
                continue
            }
            if u == "\"" {
                inString = true
                out.append(u)
            } else if u == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            } else if u == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                continue
            } else if u == "," {
                // A comma with nothing after it but space and a closing bracket.
                var j = i + 1
                while j < s.count, s[j].properties.isWhitespace || s[j].properties.generalCategory == .format { j += 1 }
                if j < s.count, s[j] == "}" || s[j] == "]" { i += 1; continue }
                out.append(u)
            } else if u.properties.generalCategory == .format || u.value == 0xFEFF {
                // zero-width and direction marks between the pieces
            } else if u.properties.isWhitespace {
                out.append(" ")
            } else {
                out.append(u)
            }
            i += 1
        }
        return String(out)
    }

    /// The JSON object a paste holds: the code block out of whatever is around it (prose,
    /// code fences), read as it is if it can be, and tidied (curly quotes straightened,
    /// comments and trailing commas dropped) only if it can't.
    static func object(in text: String) throws -> [String: Any] {
        guard text.utf8.count <= maxPasteBytes else { throw Problem.tooBig }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.empty }
        var cut = false
        var failure: Problem?
        let straight = String(text.map { curly[$0] ?? $0 })
        var candidates = straight == text ? [text] : [text, straight]
        // A code that went through a web page's HTML on the way (&quot; for every "): read
        // unescaped, but only after it couldn't be read as it is (a real code never needs it).
        if let unescaped = htmlUnescaped(straight) { candidates.append(unescaped) }
        for candidate in candidates {
            let bytes = Array(candidate.utf8)
            for range in blocks(in: bytes, cut: &cut) {
                guard range.count <= maxBytes else { failure = failure ?? .tooBig; continue }
                guard let json = String(bytes: bytes[range], encoding: .utf8) else { continue }
                for form in [json, tidied(json)] {
                    let data = Data(form.utf8)
                    guard data.count <= maxBytes else { failure = failure ?? .tooBig; continue }
                    guard ImportJSON.depthIsWithin(data) else { failure = failure ?? .tooDeep; continue }
                    if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return o }
                }
            }
        }
        if let failure { throw failure }
        throw cut ? Problem.cutOff : Problem.notJSON
    }

    /// The entities a chat page's HTML puts in place of JSON's characters.
    static let htmlEntities: [(String, String)] = [("&quot;", "\""), ("&#34;", "\""), ("&#x22;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
                                                   ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]

    /// `text` with HTML's escapes undone, only when it's clearly a code that was escaped:
    /// "&quot;" is there and quotes the code's own words (`{&quot;` or `&quot;format&quot;`),
    /// and there's no plain `"` before the first `{&quot;` that would make it real JSON. Nil
    /// otherwise. `&amp;` goes last, so `&amp;quot;` comes back as the text `&quot;`.
    static func htmlUnescaped(_ text: String) -> String? {
        guard text.contains("&quot;") || text.contains("&#34;") || text.contains("&#x22;") else { return nil }
        let quote = ["&quot;", "&#34;", "&#x22;"].first { text.contains($0) }!
        let marked = text.contains("\(quote)format\(quote)") || text.contains(quote + formatMarker + quote)
        let opens = text.range(of: "{" + quote) ?? text.range(of: "{ " + quote) ?? text.range(of: "{\n" + quote)
        guard marked || opens != nil else { return nil }
        // JSON with real quotes around its keys isn't an escaped code, whatever its strings say.
        if text.contains("{\"") || text.contains("\":") { return nil }
        var out = text
        for (entity, plain) in htmlEntities { out = out.replacingOccurrences(of: entity, with: plain, options: .caseInsensitive) }
        return out == text ? nil : out
    }

    /// From a `{` at `start`, the index just past the `}` that closes it (strings skipped); nil if it never closes.
    static func end(of bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for i in start..<bytes.count {
            let byte = bytes[i]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { return i + 1 }
            default: break
            }
        }
        return nil
    }

    /// Where the code might be, best guess first (at most 15 places): the `{…}` around each
    /// "glideball-ai-setup", the last one first (a chatbot often repeats an earlier code above
    /// its final answer); then, for a code that forgot its first line, the biggest `{…}` blocks.
    /// `cut`: the last code in it starts and never ends.
    static func blocks(in bytes: [UInt8], cut: inout Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let marker = Array(formatMarker.utf8)
        var hits: [Int] = []
        if bytes.count >= marker.count {
            var i = bytes.count - marker.count
            while i >= 0, hits.count < 4 {
                if bytes[i] == marker[0], bytes[i..<(i + marker.count)].elementsEqual(marker) {
                    hits.append(i)
                    i -= marker.count
                } else {
                    i -= 1
                }
            }
        }
        for (n, hit) in hits.enumerated() {
            // The nearest { before it that closes after it. (A { in the words before a code is
            // tried first if it's nearer, and doesn't parse; the next one out is the code.)
            var from = hit, found = 0, looked = 0, unclosed = false
            while found < 3, looked < 64, let open = bytes[..<from].lastIndex(of: 0x7B) {
                from = open
                looked += 1
                guard let e = end(of: bytes, from: open) else { unclosed = true; continue }
                guard e > hit else { continue }
                found += 1
                if !out.contains(open..<e) { out.append(open..<e) }
            }
            if n == 0, found == 0, unclosed { cut = true }
        }
        let (ranges, open) = objects(in: bytes)
        if hits.isEmpty, ranges.isEmpty, open { cut = true }
        for r in ranges.sorted(by: { $0.count > $1.count }).prefix(3) where !out.contains(r) { out.append(r) }
        return out
    }

    // MARK: Reading

    /// Something a code asked for that Glideball left out, and why. Never applied, always shown.
    struct Note: Identifiable, Equatable {
        enum Why: Equatable {
            case unknownAction, unknownKeys, unknownApp, notHere, primaryButton, unknownSetting, wrongValue, notFromACode, tooMany

            /// For the person, in the review's "Left out" list.
            var shown: String {
                switch self {
                case .unknownAction: String(localized: "Glideball has no action like that.", comment: "Set up with AI: why something in a setup code was left out")
                case .unknownKeys: String(localized: "Glideball doesn’t know that key.", comment: "Set up with AI: why a keyboard shortcut in a setup code was left out")
                case .unknownApp: String(localized: "There’s no app with that name on this Mac.", comment: "Set up with AI: why something in a setup code was left out")
                case .notHere: String(localized: "That can’t go there.", comment: "Set up with AI: why something in a setup code was left out (an action that doesn't work in that place)")
                case .primaryButton: String(localized: "The bottom-left button always stays a left click.", comment: "Set up with AI: why something in a setup code was left out")
                case .unknownSetting: String(localized: "Glideball has no setting called that.", comment: "Set up with AI: why something in a setup code was left out")
                case .wrongValue: String(localized: "That value doesn’t fit this setting.", comment: "Set up with AI: why something in a setup code was left out")
                case .notFromACode: String(localized: "A setup code can’t change that.", comment: "Set up with AI: why something in a setup code was left out")
                case .tooMany: String(localized: "There were too many, so the rest were left out.", comment: "Set up with AI: why something in a setup code was left out")
                }
            }
        }

        let id: Int
        /// Where it was, for the person: "Top left", "Safari · Top right", "macros".
        let place: String
        /// Where it was, for the chatbot: buttons.2, apps[Safari].buttons.3.gesture.up
        let path: String
        /// What the code said there, cleaned and cut short ("" when there's nothing to quote).
        let text: String
        let why: Why
        /// What to do about it, for the chatbot (English, from fixed text only).
        let hint: String
    }

    /// A code that was read: an ordinary shared setup (already through the share decoder),
    /// and what was left out of it.
    struct Reading {
        let share: SharedSetup
        let notes: [Note]
    }

    /// What a paste turned out to be. (Links are found before this, by `ImportPaste`.)
    enum Pasted {
        case code(Reading)
        /// A shared setup's own JSON (a share file's text), read by the share decoder as it is.
        case share(SharedSetup)
    }

    /// What a code is read against: the person's settings now (partial ones lie over
    /// them), their Sounds, whether their ball color is their own, and the apps on this Mac.
    struct Context {
        var current: GlideConfig
        var sounds: ShareSounds?
        var lookIsCustom = false
        var apps: SetupApps
    }

    static func read(_ text: String, _ c: Context) -> Result<Pasted, Problem> {
        read(text, current: c.current, sounds: c.sounds, lookIsCustom: c.lookIsCustom, apps: c.apps)
    }

    /// Whatever could be quoted of a value, safe to show: cleaned, on one line, at most 80 characters.
    static func quote(_ raw: Any?) -> String {
        let text: String
        switch raw {
        case nil: return ""
        case let s as String: text = s
        case let n as NSNumber: text = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : SetupJSON.show(n.doubleValue)
        case is NSNull: text = "null"
        case let other?:
            text = (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .fragmentsAllowed]))
                .flatMap { String(data: $0.prefix(400), encoding: .utf8) ?? String(decoding: $0.prefix(400), as: UTF8.self) } ?? ""
        }
        let clean = ImportText.clean(String(text.prefix(400)), max: 81)
        return clean.count > 80 ? String(clean.prefix(79)) + "…" : clean
    }

    /// Reads a paste. `current` is what the person has (partial settings lie over it), `sounds`
    /// their Sounds settings, `lookIsCustom` whether their ball color is their own.
    static func read(_ text: String, current: GlideConfig, sounds: ShareSounds?, lookIsCustom: Bool = false,
                     apps: SetupApps) -> Result<Pasted, Problem> {
        guard text.utf8.count <= maxPasteBytes else { return .failure(.tooBig) }
        let object: [String: Any]
        do { object = try self.object(in: text) } catch let p as Problem { return .failure(p) } catch { return .failure(.notJSON) }

        let format = object["format"] as? String
        if format == SharedSetup.formatMarker {
            // A share's own text: the decoder every shared file goes through, as it is.
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let share = try? SharedSetup.decode(json: data) else { return .failure(.notASetup) }
            return .success(.share(share))
        }
        // A whole settings file (or anything else with "config") is Import Settings' job, not a code's.
        guard format == formatMarker || object["config"] == nil else { return .failure(.notASetup) }
        // A setup code: its marker, or (a chatbot forgot the first line) at least one of its settings.
        let known = Set(SetupFields.topKeys).union(SetupFields.topAliases.keys)
        guard format == formatMarker || !known.isDisjoint(with: object.keys) else { return .failure(.notASetup) }
        if let v = object["version"] {
            guard let n = SetupCodeReader.number(v), n == n.rounded(), n >= 1 else { return .failure(.notASetup) }
            guard Int(n) == version else { return .failure(.newerVersion) }
        }

        let reader = SetupCodeReader(current: current, sounds: sounds, lookIsCustom: lookIsCustom, apps: apps)
        guard var share = reader.setup(object) else { return .failure(.nothingUsable(reader.notes)) }
        // Out as a share file and back in through the decoder every link and file goes through.
        share.version = share.requiredVersion
        guard let data = try? share.fileData(), let checked = try? SharedSetup.decode(json: data) else {
            return .failure(.nothingUsable(reader.notes))
        }
        return .success(.code(Reading(share: checked, notes: reader.notes)))
    }

    // MARK: The note for the chatbot

    /// What "Copy note for the AI" copies: what was left out and what to do about each, in
    /// English (it's the chatbot that reads it). Fixed text, plus the code's own words
    /// cleaned and cut short.
    static func noteForAI(_ notes: [Note], nothingElse: Bool = false) -> String {
        guard !notes.isEmpty else { return "" }
        var lines = ["Glideball left these out of your last setup code:"]
        for n in notes {
            var line = "- " + n.path
            if !n.text.isEmpty { line += ": " + SetupJSON.quote(n.text) }
            lines.append(line + " (" + n.hint + ")")
        }
        lines.append(nothingElse ? "That was everything in the code, so nothing could be used. Please fix them and give me a new setup code."
                     : "Please fix them and give me a new setup code. Everything else in the code was fine.")
        return lines.joined(separator: "\n")
    }
}
