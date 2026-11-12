import Foundation

// What an import would change, setting by setting: "Pointer speed 4 → 6.5",
// "Top left: Middle click → Copy (⌘C)". The preview sheet shows exactly this
// list, so it's computed from the settings you have and the settings you'd get
// (`SharedSetup.applied(to:)`, `KensingtonWorksImport.applied(to:)`): whatever
// would change is on it, and nothing else is.
//
// Foundation only, so the simulators can check that every action that opens an
// app or presses keys is listed.

struct ImportChange: Identifiable, Equatable {
    enum Area: Int, CaseIterable, Comparable {
        case pointer, scrolling, buttons, combos, appSetups, look, shortcuts
        static func < (a: Area, b: Area) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .pointer: String(localized: "Pointer feel", comment: "Import preview section")
            case .scrolling: String(localized: "Scroll feel", comment: "Import preview section")
            case .buttons: String(localized: "Buttons and gestures", comment: "Import preview section")
            case .combos: String(localized: "Combos")
            case .appSetups: String(localized: "App setups")
            case .look: String(localized: "Ball color and look", comment: "Import preview section")
            case .shortcuts: String(localized: "Keyboard shortcuts", comment: "Import preview section: Glideball's own system-wide shortcuts")
            }
        }

        var symbol: String {
            switch self {
            case .pointer: "cursorarrow.motionlines"
            case .scrolling: "arrow.up.and.down.circle"
            case .buttons: "button.programmable"
            case .combos: "square.on.square"
            case .appSetups: "square.grid.2x2"
            case .look: "paintpalette"
            case .shortcuts: "command"
            }
        }
    }

    let id: String
    let area: Area
    /// What it is: "Pointer speed", "Top left", "Xcode · Top left".
    let title: String
    /// nil: wasn't there (a new combo or app setup).
    let before: String?
    /// nil: goes away.
    let after: String?
    /// The new value opens an app or presses keys.
    var caution = false
}

enum ImportReview {
    /// Button names, as on the Buttons page.
    static func buttonName(_ b: Int) -> String {
        switch b {
        case 0: String(localized: "Bottom left", comment: "Trackball button position")
        case 1: String(localized: "Bottom right", comment: "Trackball button position")
        case 2: String(localized: "Top left", comment: "Trackball button position")
        case 3: String(localized: "Top right", comment: "Trackball button position")
        default: String(localized: "Button \(b + 1)")
        }
    }

    static func comboName(_ buttons: [Int]) -> String {
        buttons.map(buttonName).joined(separator: " + ")
    }

    /// An action in words, with everything that matters spelled out: the keys of a
    /// shortcut, the app (and its bundle ID) an "Open" opens, each way a gesture goes.
    static func describe(_ action: ButtonAction, on button: Int? = nil) -> String {
        if let button, action == .system { return ButtonAction.normal(for: button).title }
        switch action {
        case .shortcut(let s), .holdShortcut(let s):
            let preset = ButtonAction.presets.first { $0.action == action }
            if let preset, preset.title != s.display { return "\(preset.title) (\(s.display))" }
            return action == .holdShortcut(s)
                ? String(localized: "Hold \(s.display)", comment: "Button action: holds a keyboard shortcut down while the button is held")
                : s.display
        case .openApp(let id):
            let name = ButtonAction.appName(id)
            return name == nil || name == id
                ? String(localized: "Open \(id)", comment: "Button action: opens an app; %@ is the app’s name")
                : "\(action.title) (\(id))"
        case .modifiedClick:
            return action.title
        case .gesture(let g):
            let arrows: [(GestureDirection, String)] = [(.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→")]
            var parts = arrows.compactMap { d, arrow in g[d].map { "\(arrow) \(describe($0.action))" } }
            if g.tap != .system { parts.append(String(localized: "tap: \(describe(g.tap))", comment: "Gesture summary: what a plain tap does")) }
            let title = String(localized: "Gesture", comment: "Button action: hold the button and roll the ball up, down, left or right")
            return parts.isEmpty ? title : "\(title): " + parts.joined(separator: ", ")
        default:
            return action.title
        }
    }

    private static func onOff(_ b: Bool) -> String {
        b ? String(localized: "On", comment: "A switch that's on") : String(localized: "Off", comment: "A switch that's off")
    }

    /// Glide in milliseconds, as the Glide slider shows it (SmoothScroller.flyTau).
    static func glideMs(_ glide: Double) -> Int { Int((0.04 + min(max(glide, 0), 1) * 0.12) * 1000) }

    /// "Flywheel, glide 82 ms, 4 pt a slow turn" — one line about a scroll feel.
    static func scrollLine(_ s: ScrollSettings) -> String {
        switch s.scrollMode {
        case .native: String(localized: "Native, speed \(s.nativeScrollSpeed.decimals(2))", comment: "Scroll feel summary")
        case .flywheel: String(localized: "Flywheel, glide \(Int(glideMs(s.flyGlide))) ms, \(Int(s.flyDistance)) pt a slow turn", comment: "Scroll feel summary")
        case .follow: String(localized: "Follow, \(Int(s.scrollDistance)) pt a tick", comment: "Scroll feel summary")
        }
    }

    // MARK: The list

    /// Every setting that differs between `old` and `new` (and the look, when given).
    static func changes(from old: GlideConfig, to new: GlideConfig,
                        lookFrom oldLook: String? = nil, to newLook: String? = nil) -> [ImportChange] {
        var out: [ImportChange] = []
        func add(_ area: ImportChange.Area, _ key: String, _ title: String, _ before: String?, _ after: String?, caution: Bool = false) {
            guard before != after else { return }
            out.append(ImportChange(id: "\(area.rawValue)/\(key)", area: area, title: title, before: before, after: after, caution: caution))
        }

        // Pointer
        add(.pointer, "speed", String(localized: "Pointer speed"), old.trackingSpeed.formatted(), new.trackingSpeed.formatted())
        add(.pointer, "precision", String(localized: "Precision speed", comment: "Import preview: the pointer speed while Precision is on"),
            old.precisionSpeed.formatted(), new.precisionSpeed.formatted())
        add(.pointer, "per-display", String(localized: "Per-display speeds", comment: "Import preview: the switch for a pointer speed per display"),
            onOff(old.displaySpeeds.enabled), onOff(new.displaySpeeds.enabled))

        // Scrolling
        scrollChanges(old.scrollSettings, new.scrollSettings, prefix: "", area: .scrolling, add: add)
        add(.scrolling, "ball", String(localized: "Scroll with ball speed", comment: "Import preview"),
            "×\(old.ballScrollSpeed.twoDigits)", "×\(new.ballScrollSpeed.twoDigits)")

        // Buttons
        buttonChanges(old.buttons, new.buttons, prefix: "", keyPrefix: "", area: .buttons, add: add)
        add(.buttons, "gestures", String(localized: "Gestures", comment: "Import preview: the switch that turns gesture buttons on"),
            onOff(old.gesturesEnabled), onOff(new.gesturesEnabled))
        chordChanges(old.chords, new.chords, prefix: "", keyPrefix: "", area: .combos, add: add)

        // App setups
        let ids = (old.appProfiles.map(\.bundleID) + new.appProfiles.map(\.bundleID)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for id in ids {
            let a = old.profile(for: id), b = new.profile(for: id)
            let name = b?.name ?? a?.name ?? id
            switch (a, b) {
            case (nil, let b?):
                add(.appSetups, "\(id)/new", name, nil, b.summary(comparedTo: new))
            case (_?, nil):
                add(.appSetups, "\(id)/gone", name, a?.summary(comparedTo: old), nil)
            case (let a?, let b?):
                if a.name != b.name { add(.appSetups, "\(id)/name", String(localized: "\(name): name", comment: "Import preview: an app setup's name"), a.name, b.name) }
                add(.appSetups, "\(id)/speed", String(localized: "\(name): pointer speed", comment: "Import preview: an app setup's pointer speed"),
                    a.trackingSpeed.map { $0.formatted() } ?? String(localized: "Main setup"), b.trackingSpeed.map { $0.formatted() } ?? String(localized: "Main setup"))
                add(.appSetups, "\(id)/scroll", String(localized: "\(name): scrolling", comment: "Import preview: an app setup's scroll feel"),
                    a.scroll.map(scrollLine) ?? String(localized: "Main setup"), b.scroll.map(scrollLine) ?? String(localized: "Main setup"))
            default: break
            }
            // Every button and combo an app setup would get is listed, like the main setup's.
            let oldButtons = a?.buttons ?? old.buttons, newButtons = b?.buttons ?? new.buttons
            if b?.buttons != nil || a?.buttons != nil {
                buttonChanges(a == nil ? old.buttons : oldButtons, newButtons, prefix: "\(name) · ", keyPrefix: "\(id)/", area: .appSetups, add: add)
            }
            if b?.chords != nil || a?.chords != nil {
                chordChanges(a?.chords ?? old.chords, b?.chords ?? new.chords, prefix: "\(name) · ", keyPrefix: "\(id)/", area: .appSetups, add: add)
            }
        }

        // Glideball's own keyboard shortcuts (only a settings file of your own carries them)
        for action in GlobalShortcuts.Action.allCases {
            add(.shortcuts, "\(action.rawValue)", action.title,
                old.globalShortcuts[action]?.display ?? String(localized: "None", comment: "No combos / no app setups"),
                new.globalShortcuts[action]?.display ?? String(localized: "None", comment: "No combos / no app setups"))
        }

        if let newLook { add(.look, "theme", String(localized: "Ball color", comment: "Import preview"), oldLook, newLook) }
        return out
    }

    private static func scrollChanges(_ a: ScrollSettings, _ b: ScrollSettings, prefix: String, area: ImportChange.Area,
                                      add: (ImportChange.Area, String, String, String?, String?, Bool) -> Void) {
        func row(_ key: String, _ title: String, _ x: String, _ y: String) { add(area, prefix + key, title, x, y, false) }
        row("mode", String(localized: "Scroll mode", comment: "Import preview"), a.scrollMode.title, b.scrollMode.title)
        let pt = { (v: Double) in String(localized: "\(Int(v)) pt", comment: "Points: a distance on screen") }
        row("native", String(localized: "Native speed", comment: "Import preview: the Native scroll mode's speed"), a.nativeScrollSpeed.decimals(2), b.nativeScrollSpeed.decimals(2))
        row("flyDistance", String(localized: "Slow-turn distance"), pt(a.flyDistance), pt(b.flyDistance))
        row("flyPower", String(localized: "Spin power"), a.flyAcceleration.wholePercent, b.flyAcceleration.wholePercent)
        row("flyReach", String(localized: "Fast-spin reach"), a.flyReach.wholePercent, b.flyReach.wholePercent)
        row("glide", String(localized: "Glide"), String(localized: "\(Int(glideMs(a.flyGlide))) ms", comment: "Milliseconds"),
            String(localized: "\(Int(glideMs(b.flyGlide))) ms", comment: "Milliseconds"))
        row("smooth", String(localized: "Smooth scrolling"), onOff(a.smoothScrolling), onOff(b.smoothScrolling))
        row("distance", String(localized: "Distance per tick", comment: "Import preview: Follow mode's distance"), pt(a.scrollDistance), pt(b.scrollDistance))
        row("smoothness", String(localized: "Smoothness", comment: "Import preview: Follow mode's smoothness"), a.scrollSmoothness.wholePercent, b.scrollSmoothness.wholePercent)
        row("accel", String(localized: "Acceleration", comment: "Import preview: Follow mode's acceleration"), a.scrollAcceleration.wholePercent, b.scrollAcceleration.wholePercent)
        row("throw", String(localized: "Throw", comment: "Import preview: Follow mode's throw switch"), onOff(a.throwEnabled), onOff(b.throwEnabled))
        row("throwAmount", String(localized: "Throw distance", comment: "Import preview"), a.throwAmount.wholePercent, b.throwAmount.wholePercent)
        row("reverse", String(localized: "Reverse direction", comment: "Import preview: scrolling the other way"), onOff(a.reverseScroll), onOff(b.reverseScroll))
        row("shift", String(localized: "⇧ scrolls sideways", comment: "Import preview"), onOff(a.shiftScrollsHorizontally), onOff(b.shiftScrollsHorizontally))
    }

    private static func buttonChanges(_ a: [Int: ButtonAction], _ b: [Int: ButtonAction], prefix: String, keyPrefix: String,
                                      area: ImportChange.Area, add: (ImportChange.Area, String, String, String?, String?, Bool) -> Void) {
        let keys = Set(a.keys).union(b.keys).union(1...3).filter { $0 != 0 }.sorted()
        for k in keys {
            let x = a[k] ?? .system, y = b[k] ?? .system
            guard !x.sameEffect(as: y, on: k) else { continue }
            add(area, "\(keyPrefix)button\(k)", prefix + buttonName(k), describe(x, on: k), describe(y, on: k), y.needsCaution)
        }
    }

    private static func chordChanges(_ a: [Chord], _ b: [Chord], prefix: String, keyPrefix: String,
                                     area: ImportChange.Area, add: (ImportChange.Area, String, String, String?, String?, Bool) -> Void) {
        let sets = (a.map(\.buttons) + b.map(\.buttons)).reduce(into: [[Int]]()) { if !$0.contains($1) { $0.append($1) } }
        for set in sets {
            let x = a.first { $0.buttons == set }?.action, y = b.first { $0.buttons == set }?.action
            guard x != y else { continue }
            add(area, "\(keyPrefix)combo\(set)", prefix + comboName(set), x.map { describe($0) }, y.map { describe($0) }, y?.needsCaution ?? false)
        }
    }
}
