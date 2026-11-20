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
        case pointer, scrolling, buttons, combos, appSetups, look, sounds, shortcuts
        static func < (a: Area, b: Area) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .pointer: String(localized: "Pointer feel", comment: "Import preview section")
            case .scrolling: String(localized: "Scroll feel", comment: "Import preview section")
            case .buttons: String(localized: "Buttons and gestures", comment: "Import preview section")
            case .combos: String(localized: "Combos")
            case .appSetups: String(localized: "App setups")
            case .look: String(localized: "Ball color and look", comment: "Import preview section")
            case .sounds: String(localized: "Sounds")
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
            case .sounds: "speaker.wave.2"
            case .shortcuts: "command"
            }
        }
    }

    /// A shortcut that's hard to take back, at one exact place in a change: the row's own
    /// action, or one place inside a gesture or a More (`ImportChange.Detail`).
    struct Risk: Equatable, Identifiable {
        /// The change's id, "#", the place's key: what a tick in the review is remembered by.
        let id: String
        let tier: ShortcutRisk
        /// Why, in plain words ("Empties the Trash without asking.").
        let why: String
    }

    /// One place inside a gesture, a More or a Switcher that the change sets: "↘ More › ↖".
    struct Detail: Equatable, Identifiable {
        /// The place's key in the action ("downRight.more.upLeft", "tap"); unique in the row.
        let id: String
        let label: String
        /// What's there now; nil when it's the same as `after` (an unchanged place), or there was nothing.
        let before: String?
        /// nil: that place becomes empty.
        let after: String?
        /// False for a place that stays as it is (shown dim, so the whole gesture can be read).
        let changed: Bool
        var risk: Risk?
    }

    /// Where a button's or combo's change sits, so a place left out can be put back.
    enum Location: Equatable {
        case button(app: String?, Int)
        case combo(app: String?, [Int])
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
    /// The row's own action is a shortcut on the list (`RiskyShortcuts`).
    var risk: Risk?
    /// Every place inside a gesture, More or Switcher, with flags on the exact place.
    var details: [Detail] = []
    /// A word of warning that isn't about keys: a big jump in pointer speed, say.
    var note: String?
    var location: Location?

    /// Every flag in the row: its own and its places'.
    var risks: [Risk] { (risk.map { [$0] } ?? []) + details.compactMap(\.risk) }
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
    static func describe(_ action: ButtonAction, on button: Int? = nil, directions: Bool = true) -> String {
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
            // Clockwise from up, as the ring lays them out; a More lists what's in it.
            // Everything about it that can differ is in the words (how a direction fires, the
            // ring, eight ways, its own distance): two gestures that read the same are the same,
            // so a preview never calls a change "nothing".
            // With `directions: false` (the review, which lists each place on its own line)
            // only what's about the whole gesture is in the words.
            var parts = !directions ? [] : g.usedDirections.compactMap { d -> String? in
                guard let step = g[d] else { return nil }
                if let sub = step.more {
                    let inside = sub.indices.compactMap { p in sub[p].map { "\(arrows[p]) \(fires($0))" } }
                    return "\(arrows[d.place]) \(moreWord)" + (inside.isEmpty ? "" : " (" + inside.joined(separator: ", ") + ")")
                }
                return "\(arrows[d.place]) \(fires(step))"
            }
            if g.eight { parts.append(String(localized: "8 directions", comment: "Buttons page, a folded Gestures editor's summary")) }
            if g.ring == .custom, g.ringUp != nil || g.ringDown != nil {
                if !directions {
                    parts.append(String(localized: "ring: \(g.ring.title)", comment: "Wheel summary: the ring job, like “ring: Volume”"))
                } else {
                let cw = g.ringActions.clockwise.map { describe($0) } ?? "–"
                let ccw = g.ringActions.counterclockwise.map { describe($0) } ?? "–"
                parts.append(String(localized: "ring: \(ccw) / \(cw)", comment: "Wheel summary: what turning the scroll ring does each way"))
                }
            } else if g.ring != .scroll {
                var job = g.ring.title
                if g.reverse { job += " · " + String(localized: "Reverse", comment: "Gestures editor: turn the ring job the other way round") }
                parts.append(String(localized: "ring: \(job)", comment: "Wheel summary: the ring job, like “ring: Volume”"))
            }
            switch g.show {
            case .never: break
            case .afterPause: parts.append(String(localized: "Ring after a pause", comment: "Buttons page, a folded Gestures editor's summary: Show the ring is After a pause"))
            case .atOnce: parts.append(String(localized: "Ring right away", comment: "Buttons page, a folded Gestures editor's summary: Show the ring is Right away"))
            }
            if let d = g.distance { parts.append(String(localized: "Distance") + ": " + d.title) }
            if g.tap != .system, directions { parts.append(String(localized: "tap: \(describe(g.tap))", comment: "Gesture summary: what a plain tap does")) }
            let title = ButtonAction.gesture(g).title
            return parts.isEmpty ? title : "\(title): " + parts.joined(separator: ", ")
        case .wheel(let w):
            return describe(.gesture(ButtonGesture(wheel: w)), on: button, directions: directions)
        case .switcher(let a):
            let title = String(localized: "Switcher", comment: "Button action: hold the button, roll the ball to pick a running app, let go to switch to it (like ⌘-Tab)")
            guard a.tap != .system, directions else { return title }
            return "\(title): " + String(localized: "tap: \(describe(a.tap))", comment: "Gesture summary: what a plain tap does")
        default:
            return action.title
        }
    }

    static let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    static var moreWord: String { String(localized: "More", comment: "Gestures: a direction that opens a second ring of actions") }

    /// A direction's action, and how it fires when that isn't the usual way.
    static func fires(_ step: GestureStep) -> String {
        switch step.mode {
        case .chain: describe(step.action)
        case .continuous: describe(step.action) + " · " + String(localized: "Keeps going", comment: "Gesture direction: fires again and again for as long as you keep rolling")
        case .once: describe(step.action) + " · " + String(localized: "Once per hold", comment: "Gesture direction: fires once")
        }
    }

    // MARK: Places inside an action

    /// One place in an action that does something on its own: the action itself (key ""), a
    /// gesture's direction, a place in a More, a tap, the ring's own pair, a Switcher's tap.
    struct Place: Equatable {
        let key: String
        let label: String
        let text: String
        let action: ButtonAction
    }

    /// Every place in `action` that does something, clockwise from up, then the tap and the ring.
    /// Every direction a gesture holds is here, even one a four-way gesture doesn't use yet.
    static func places(_ action: ButtonAction) -> [Place] {
        switch action {
        case .wheel(let w):
            return places(.gesture(ButtonGesture(wheel: w)))
        case .gesture(let g):
            var out: [Place] = []
            for p in 0..<8 {
                let d = GestureDirection(place: p)
                guard let step = g[d] else { continue }
                if let sub = step.more {
                    for (i, inner) in sub.enumerated() where i < 8 {
                        guard let inner else { continue }
                        out.append(Place(key: "\(d.rawValue).more.\(GestureDirection(place: i).rawValue)",
                                         label: "\(arrows[p]) \(moreWord) › \(arrows[i])", text: fires(inner), action: inner.action))
                    }
                } else {
                    out.append(Place(key: d.rawValue, label: arrows[p], text: fires(step), action: step.action))
                }
            }
            if g.tap != .system {
                out.append(Place(key: "tap", label: String(localized: "Tap", comment: "Import review: what a quick press of a Gestures or Switcher button does"),
                                 text: describe(g.tap), action: g.tap))
            }
            if g.ring == .custom {
                if let a = g.ringUp { out.append(Place(key: "ringUp", label: String(localized: "Ring ↻", comment: "Import review: turning the scroll ring clockwise while a Gestures button is held"), text: describe(a), action: a)) }
                if let a = g.ringDown { out.append(Place(key: "ringDown", label: String(localized: "Ring ↺", comment: "Import review: turning the scroll ring counterclockwise while a Gestures button is held"), text: describe(a), action: a)) }
            }
            return out
        case .switcher(let s):
            guard s.tap != .system else { return [] }
            return [Place(key: "tap", label: String(localized: "Tap", comment: "Import review: what a quick press of a Gestures or Switcher button does"),
                          text: describe(s.tap), action: s.tap)]
        default:
            return [Place(key: "", label: "", text: describe(action), action: action)]
        }
    }

    /// Whether an action is made of places (a gesture or a Switcher) rather than being one.
    static func hasPlaces(_ action: ButtonAction) -> Bool {
        switch action {
        case .gesture, .wheel, .switcher: true
        default: false
        }
    }

    static func risk(_ action: ButtonAction, id: String) -> ImportChange.Risk? {
        guard let s = action.pressedShortcut, let kind = RiskyShortcuts.kind(s) else { return nil }
        return ImportChange.Risk(id: id, tier: RiskyShortcuts.risk(kind), why: RiskyShortcuts.why(kind))
    }

    /// The row for one button or combo going from `x` to `y`: a plain action's own flag, or a
    /// gesture's places one by one (each new or changed one flagged where it sits). A place
    /// that was already there doing the same is the person's own, and never flagged.
    static func row(id: String, area: ImportChange.Area, title: String, from x: ButtonAction?, to y: ButtonAction?, on button: Int?,
                    location: ImportChange.Location) -> ImportChange {
        let compact = y.map(hasPlaces) == true
        var c = ImportChange(id: id, area: area, title: title,
                             before: x.map { describe($0, on: button, directions: !(compact && hasPlaces($0))) },
                             after: y.map { describe($0, on: button, directions: !compact) },
                             caution: y?.needsCaution ?? false)
        c.location = location
        guard let y else { return c }
        if !compact {
            c.risk = risk(y, id: id + "#")   // a row is only made for something that changes
            return c
        }
        let old = x.map(places) ?? [], new = places(y)
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newKeys = Set(new.map(\.key))
        for p in new {
            let was = oldByKey[p.key]
            let changed = was?.action != p.action || was?.text != p.text
            var d = ImportChange.Detail(id: p.key, label: p.label, before: changed ? was?.text : nil, after: p.text, changed: changed)
            if was?.action != p.action { d.risk = risk(p.action, id: id + "#" + p.key) }
            c.details.append(d)
        }
        // Places that go empty, when the old one was a gesture too.
        for p in old where !p.key.isEmpty && !newKeys.contains(p.key) {
            c.details.append(ImportChange.Detail(id: p.key, label: p.label, before: p.text, after: nil, changed: true))
        }
        return c
    }

    // MARK: Leaving flagged places out

    /// `action` without the place `key` ("" is the whole action: nil). Inside a gesture a
    /// place left out is empty, a tap left out is the button's own click.
    static func without(_ key: String, in action: ButtonAction) -> ButtonAction? {
        guard !key.isEmpty else { return nil }
        switch action {
        case .wheel(let w):
            return without(key, in: .gesture(ButtonGesture(wheel: w)))
        case .gesture(var g):
            let parts = key.components(separatedBy: ".")
            switch parts.first {
            case "tap": g.tap = .system
            case "ringUp": g.ringUp = nil
            case "ringDown": g.ringDown = nil
            case let name?:
                guard let d = GestureDirection(rawValue: name) else { return action }
                if parts.count == 3, parts[1] == "more", let inner = GestureDirection(rawValue: parts[2]), var sub = g[d]?.more,
                   sub.indices.contains(inner.place) {
                    sub[inner.place] = nil
                    g[d] = sub.contains { $0 != nil } ? .moreRing(sub) : nil
                } else if parts.count == 1 {
                    g[d] = nil
                }
            case nil: break
            }
            return .gesture(g)
        case .switcher(var s):
            if key == "tap" { s.tap = .system }
            return .switcher(s)
        default:
            return action
        }
    }

    /// The red flags in going from `old` to `new` (only the destructive ones need a tick).
    static func destructiveRisks(from old: GlideConfig, to new: GlideConfig) -> [ImportChange.Risk] {
        changes(from: old, to: new).flatMap(\.risks).filter { $0.tier == .destructive }
    }

    /// `new` with every red-flagged place not in `confirmed` left out: a button or combo
    /// goes back to what it was, a place inside a gesture is left empty. Apply runs this on
    /// whatever any import would give, so nothing destructive gets in without its tick.
    static func leavingOut(from old: GlideConfig, in new: GlideConfig, confirmed: Set<String>) -> GlideConfig {
        var out = new
        /// Where the app's setup is in `out`. A whole settings file can take an app setup away,
        /// and the app would then follow the main setup (flagged, when that's a shortcut on the
        /// list): left out, the app setup stays as it was, and there's nothing more to fix (nil).
        func profileIndex(_ app: String) -> Int? {
            if let i = out.appProfiles.firstIndex(where: { $0.bundleID == app }) { return i }
            if let was = old.profile(for: app) { out.appProfiles.append(was) }
            return nil
        }
        for change in changes(from: old, to: new) {
            let flagged = change.risks.filter { $0.tier == .destructive && !confirmed.contains($0.id) }
            guard !flagged.isEmpty, let location = change.location else { continue }
            let keys = flagged.map { String($0.id[$0.id.index(after: $0.id.lastIndex(of: "#")!)...]) }
            switch location {
            case .button(let app, let b):
                let was: ButtonAction? = app.map { id in old.profile(for: id)?.buttons.map { $0[b] ?? .system } ?? old.buttons[b] } ?? old.buttons[b]
                func fix(_ a: ButtonAction?) -> ButtonAction? {
                    guard var a else { return nil }
                    for key in keys {
                        guard let left = without(key, in: a) else { return was }
                        a = left
                    }
                    return a
                }
                if let app {
                    guard let i = profileIndex(app) else { continue }
                    if out.appProfiles[i].buttons == nil {
                        // It would follow the main setup now: it keeps its own buttons instead.
                        out.appProfiles[i].buttons = old.profile(for: app)?.buttons
                        continue
                    }
                    let fixed = fix(out.appProfiles[i].buttons?[b])
                    out.appProfiles[i].buttons?[b] = fixed == .system ? nil : fixed
                } else {
                    let fixed = fix(out.buttons[b])
                    out.buttons[b] = fixed == .system ? nil : fixed
                }
            case .combo(let app, let set):
                let oldChords = app.flatMap { old.profile(for: $0)?.chords } ?? old.chords
                let was = oldChords.first { $0.buttons == set }?.action
                func fix(_ list: [Chord]) -> [Chord] {
                    var list = list
                    guard let i = list.firstIndex(where: { $0.buttons == set }) else { return list }
                    var a = list[i].action
                    for key in keys {
                        guard let left = without(key, in: a) else {
                            if let was { list[i].action = was } else { list.remove(at: i) }
                            return list
                        }
                        a = left
                    }
                    list[i].action = a
                    return list
                }
                if let app {
                    guard let i = profileIndex(app) else { continue }
                    guard let list = out.appProfiles[i].chords else {
                        out.appProfiles[i].chords = old.profile(for: app)?.chords   // keeps its own, as above
                        continue
                    }
                    out.appProfiles[i].chords = fix(list)
                } else {
                    out.chords = fix(out.chords)
                }
            }
        }
        return out
    }

    // MARK: A whole settings file (Import Settings…)

    /// What a settings file would make of `current`, before anything flagged is left out: the
    /// file's settings checked and cleaned, with this Mac's own pause switch. nil: a file
    /// from a newer Glideball.
    static func settingsFile(_ file: GlideSettingsFile, onto current: GlideConfig) -> GlideConfig? {
        guard var incoming = try? file.validatedConfig() else { return nil }
        incoming = incoming.sanitizedForImport()
        incoming.enabled = current.enabled
        return incoming
    }

    /// The rows of going from `old` to `new` that hold a flagged shortcut (red or amber), each
    /// with only its flagged places: what the Replace preview of a whole settings file shows,
    /// since it replaces everything and doesn't list every setting.
    static func flagged(from old: GlideConfig, to new: GlideConfig) -> [ImportChange] {
        changes(from: old, to: new).compactMap { change in
            guard !change.risks.isEmpty else { return nil }
            var c = change
            c.details = change.details.filter { $0.risk != nil }
            return c
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
        func add(_ area: ImportChange.Area, _ key: String, _ title: String, _ before: String?, _ after: String?, caution: Bool = false,
                 note: String? = nil) {
            guard before != after else { return }
            var c = ImportChange(id: "\(area.rawValue)/\(key)", area: area, title: title, before: before, after: after, caution: caution)
            c.note = note
            out.append(c)
        }
        func addRow(_ c: ImportChange) { out.append(c) }

        // Pointer
        add(.pointer, "speed", String(localized: "Pointer speed"), old.trackingSpeed.formatted(), new.trackingSpeed.formatted(),
            note: bigJump(old.trackingSpeed, new.trackingSpeed))
        let notSlower = new.precisionSpeed >= new.trackingSpeed
            ? String(localized: "That’s no slower than your pointer speed, so Precision won’t slow the pointer down.",
                     comment: "Import review: a note when the Precision speed is at or above the pointer speed")
            : nil
        add(.pointer, "precision", String(localized: "Precision speed", comment: "Import preview: the pointer speed while Precision is on"),
            old.precisionSpeed.formatted(), new.precisionSpeed.formatted(), note: notSlower)
        add(.pointer, "per-display", String(localized: "Per-display speeds", comment: "Import preview: the switch for a pointer speed per display"),
            onOff(old.displaySpeeds.enabled), onOff(new.displaySpeeds.enabled))
        let mainSpeed = String(localized: "Main speed", comment: "Import preview: a display that uses the main pointer speed")
        for key in Set(old.displaySpeeds.speeds.keys).union(new.displaySpeeds.speeds.keys).sorted() {
            let name = new.displaySpeeds.names[key] ?? old.displaySpeeds.names[key]
                ?? String(localized: "A display", comment: "Import preview: a display whose name isn't known")
            add(.pointer, "display/\(key)",
                String(localized: "\(name): pointer speed", comment: "Import preview: one display's own pointer speed; %@ is the display's name"),
                old.displaySpeeds.speeds[key].map { $0.formatted() } ?? mainSpeed,
                new.displaySpeeds.speeds[key].map { $0.formatted() } ?? mainSpeed)
        }

        // Scrolling
        scrollChanges(old.scrollSettings, new.scrollSettings, prefix: "", area: .scrolling) { add($0, $1, $2, $3, $4, caution: $5) }
        add(.scrolling, "ball", String(localized: "Scroll with ball speed", comment: "Import preview"),
            "×\(old.ballScrollSpeed.twoDigits)", "×\(new.ballScrollSpeed.twoDigits)")

        // Buttons
        buttonChanges(old.buttons, new.buttons, prefix: "", app: nil, area: .buttons, add: addRow)
        add(.buttons, "gestures", String(localized: "Gestures", comment: "Import preview: the switch that turns gesture buttons on"),
            onOff(old.gesturesEnabled), onOff(new.gesturesEnabled))
        chordChanges(old.chords, new.chords, prefix: "", app: nil, area: .combos, add: addRow)

        // App setups
        let ids = (old.appProfiles.map(\.bundleID) + new.appProfiles.map(\.bundleID)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for id in ids {
            let a = old.profile(for: id), b = new.profile(for: id)
            let name = b?.name ?? a?.name ?? id
            switch (a, b) {
            case (nil, let b?):
                add(.appSetups, "\(id)/new", name, nil, b.summary(comparedTo: new), note: b.trackingSpeed.flatMap { bigJump(old.trackingSpeed, $0) })
            case (_?, nil):
                add(.appSetups, "\(id)/gone", name, a?.summary(comparedTo: old), nil)
            case (let a?, let b?):
                if a.name != b.name { add(.appSetups, "\(id)/name", String(localized: "\(name): name", comment: "Import preview: an app setup's name"), a.name, b.name) }
                add(.appSetups, "\(id)/speed", String(localized: "\(name): pointer speed", comment: "Import preview: an app setup's pointer speed"),
                    a.trackingSpeed.map { $0.formatted() } ?? String(localized: "Main setup"), b.trackingSpeed.map { $0.formatted() } ?? String(localized: "Main setup"),
                    note: b.trackingSpeed.flatMap { bigJump(a.trackingSpeed ?? old.trackingSpeed, $0) })
                add(.appSetups, "\(id)/scroll", String(localized: "\(name): scrolling", comment: "Import preview: an app setup's scroll feel"),
                    a.scroll.map(scrollLine) ?? String(localized: "Main setup"), b.scroll.map(scrollLine) ?? String(localized: "Main setup"))
            default: break
            }
            // Every button and combo an app setup would get is listed, like the main setup's.
            let oldButtons = a?.buttons ?? old.buttons, newButtons = b?.buttons ?? new.buttons
            if b?.buttons != nil || a?.buttons != nil {
                buttonChanges(a == nil ? old.buttons : oldButtons, newButtons, prefix: "\(name) · ", app: id, area: .appSetups, add: addRow)
            }
            if b?.chords != nil || a?.chords != nil {
                chordChanges(a?.chords ?? old.chords, b?.chords ?? new.chords, prefix: "\(name) · ", app: id, area: .appSetups, add: addRow)
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

    /// A pointer speed at least twice or at most half what it was: worth trying before keeping.
    /// (Glideball takes it, within the slider's range; the note is so it's no surprise.)
    static func bigJump(_ from: Double, _ to: Double) -> String? {
        guard from > 0, to >= from * 2 || to <= from / 2 else { return nil }
        return to > from
            ? String(localized: "A big jump from \(from.formatted()): much faster than you have it. Try it before you keep it.", comment: "Import review: a note on a pointer speed far above the current one; %@ is the current speed")
            : String(localized: "A big jump from \(from.formatted()): much slower than you have it. Try it before you keep it.", comment: "Import review: a note on a pointer speed far below the current one; %@ is the current speed")
    }

    /// The Sounds settings that would change (Settings › Sound). `titles` names each kind (SoundKind's titles).
    static func soundChanges(from a: ShareSounds, to b: ShareSounds, titles: [String: String]) -> [ImportChange] {
        var out: [ImportChange] = []
        func add(_ key: String, _ title: String, _ x: String, _ y: String) {
            guard x != y else { return }
            out.append(ImportChange(id: "\(ImportChange.Area.sounds.rawValue)/\(key)", area: .sounds, title: title, before: x, after: y))
        }
        add("on", String(localized: "Sounds"), onOff(a.on), onOff(b.on))
        add("volume", String(localized: "Volume"), a.volume.wholePercent, b.volume.wholePercent)
        for id in ShareSounds.kindIDs {
            add(id, titles[id] ?? id, onOff(a.kinds[id] ?? true), onOff(b.kinds[id] ?? a.kinds[id] ?? true))
        }
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

    private static func buttonChanges(_ a: [Int: ButtonAction], _ b: [Int: ButtonAction], prefix: String, app: String?,
                                      area: ImportChange.Area, add: (ImportChange) -> Void) {
        let keys = Set(a.keys).union(b.keys).union(1...3).filter { $0 != 0 }.sorted()
        let keyPrefix = app.map { "\($0)/" } ?? ""
        for k in keys {
            let x = a[k] ?? .system, y = b[k] ?? .system
            guard !x.sameEffect(as: y, on: k) else { continue }
            add(row(id: "\(area.rawValue)/\(keyPrefix)button\(k)", area: area, title: prefix + buttonName(k), from: x, to: y, on: k,
                    location: .button(app: app, k)))
        }
    }

    private static func chordChanges(_ a: [Chord], _ b: [Chord], prefix: String, app: String?,
                                     area: ImportChange.Area, add: (ImportChange) -> Void) {
        let sets = (a.map(\.buttons) + b.map(\.buttons)).reduce(into: [[Int]]()) { if !$0.contains($1) { $0.append($1) } }
        let keyPrefix = app.map { "\($0)/" } ?? ""
        for set in sets {
            let x = a.first { $0.buttons == set }?.action, y = b.first { $0.buttons == set }?.action
            guard x != y else { continue }
            add(row(id: "\(area.rawValue)/\(keyPrefix)combo\(set)", area: area, title: prefix + comboName(set), from: x, to: y, on: nil,
                    location: .combo(app: app, set)))
        }
    }
}
