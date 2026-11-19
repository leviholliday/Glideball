import CoreGraphics
import Foundation

// The pre-pass of "Set up with AI" (SetupCode.swift has the format and the rules): walks a
// setup code's JSON and builds the shared setup it means. Every value is checked for its
// type; anything that can't be used is left out with a note, and nothing is guessed.
//
// Foundation only, so scripts/import-sim compiles and fuzzes it.

final class SetupCodeReader {
    typealias Note = SetupCode.Note

    /// Where in the code we are: for the person ("Safari · Top left") and for the chatbot (apps[Safari].buttons.2).
    struct Place {
        var label: String
        var path: String
        func at(_ key: String) -> Place { Place(label: label, path: path.isEmpty ? key : path + "." + key) }
    }

    let current: GlideConfig
    let sounds: ShareSounds?
    let lookIsCustom: Bool
    let apps: SetupApps
    private(set) var notes: [Note] = []

    init(current: GlideConfig, sounds: ShareSounds?, lookIsCustom: Bool, apps: SetupApps) {
        self.current = current
        self.sounds = sounds
        self.lookIsCustom = lookIsCustom
        self.apps = apps
    }

    // JSONSerialization hands back NSNumber for true and for 1: tell them apart.
    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// One of an enum's values, by its name (any capitals).
    static func choice<T: RawRepresentable & CaseIterable>(_ v: Any?, _ type: T.Type) -> T? where T.RawValue == String {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return T.allCases.first { $0.rawValue.lowercased() == t }
    }

    static func names<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> String where T.RawValue == String {
        T.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private func leave(_ p: Place, _ raw: Any?, _ why: Note.Why, _ hint: String) {
        guard notes.count < SetupCode.maxNotes else { return }
        notes.append(Note(id: notes.count, place: ImportText.clean(p.label, max: 80), path: ImportText.clean(p.path, max: 120),
                          text: SetupCode.quote(raw), why: why, hint: hint))
    }

    /// A value that isn't the kind its setting takes: quoted as `key: value`. A null says
    /// where null does work instead.
    private func wrong(_ p: Place, _ key: String, _ raw: Any?, _ hint: String) {
        leave(p.at(key), "\(key): \(SetupCode.quote(raw))", .wrongValue, raw is NSNull ? Self.nullHint : hint)
    }

    /// Where null works (the reference says the same): in an app setup, for its
    /// "trackingSpeed", "scroll", "buttons", "combos" or one of its buttons (back to the main
    /// setup's); as a combo's "action" (the combo goes); inside a gesture or a More (that
    /// place is empty, as if it were left out). Anywhere else it's left out with this.
    static let nullHint = "null only works in an app setup (back to the main setup's), as a combo's \"action\" (removes it) or inside a gesture (empty); leave the key out to keep what I have"

    private func range(_ r: ClosedRange<Double>) -> String {
        "a number from \(SetupJSON.show(r.lowerBound)) to \(SetupJSON.show(r.upperBound))"
    }

    private func noted(under p: Place) -> Bool { notes.contains { $0.path.hasPrefix(p.path) } }

    /// The bundle IDs already in the person's own setup (their app setups and the apps their
    /// buttons and combos open). Your setup in the prompt names an app that isn't installed
    /// any more by its bundle ID, so that comes back as the same app, not as "not on this Mac".
    private lazy var ownBundleIDs: [String: String] = {
        var out: [String: String] = [:]
        func walk(_ a: ButtonAction) {
            switch a {
            case .openApp(let id): out[id] = out[id] ?? id
            case .gesture(let g):
                for d in GestureDirection.allCases {
                    guard let step = g[d] else { continue }
                    walk(step.action)
                    for inner in step.more ?? [] { if let inner { walk(inner.action) } }
                }
                walk(g.tap)
                if let a = g.ringUp { walk(a) }
                if let a = g.ringDown { walk(a) }
            case .switcher(let s): walk(s.tap)
            default: break
            }
        }
        for p in current.appProfiles {
            out[p.bundleID] = p.name
            for a in (p.buttons ?? [:]).values { walk(a) }
            for c in p.chords ?? [] { walk(c.action) }
        }
        for a in current.buttons.values { walk(a) }
        for c in current.chords { walk(c.action) }
        return out
    }()

    /// The app a code names: on this Mac, or (by its exact bundle ID) one already in your setup.
    private func find(_ asked: String) -> (bundleID: String, name: String)? {
        if let found = apps.find(asked) { return found }
        guard ImportText.isBundleID(asked), let name = ownBundleIDs[asked] else { return nil }
        return (asked, name)
    }

    // MARK: The whole code

    /// The shared setup `o` means, or nil when nothing in it could be used.
    func setup(_ o: [String: Any]) -> SharedSetup? {
        // null on the main setup's own settings means nothing here: said, and left out.
        var o = o
        for key in o.keys.sorted() where o[key] is NSNull {
            if SetupFields.topKeys.contains(key) || SetupFields.topAliases[key] != nil {
                leave(Place(label: SetupCode.quote(key), path: key), "\(key): null", .wrongValue, Self.nullHint)
                o[key] = nil
            }
        }
        var s = SharedSetup(version: 1, parts: [])
        var parts: [SharePart] = []
        let pointer = Place(label: ImportChange.Area.pointer.title, path: "")
        let scrolling = Place(label: ImportChange.Area.scrolling.title, path: "")
        let buttons = Place(label: ImportChange.Area.buttons.title, path: "")

        for key in o.keys.sorted() where !SetupFields.topKeys.contains(key) && SetupFields.topAliases[key] == nil
            && !SetupFields.ignoredTopKeys.contains(key) {
            let shown = SetupCode.quote(key)
            if SetupFields.forbiddenTopKeys.contains(key) {
                leave(Place(label: shown, path: shown), nil, .notFromACode, "a setup code can't change this; leave it out")
            } else {
                leave(Place(label: shown, path: shown), nil, .unknownSetting, "Glideball has no setting with this name; use only what the reference lists")
            }
        }
        func field(_ key: String) -> Any? {
            o[key] ?? SetupFields.topAliases.first { $0.value == key }.flatMap { o[$0.key] }
        }

        // Pointer
        if let raw = field("trackingSpeed") {
            if let v = Self.number(raw) { s.trackingSpeed = v.clamped(to: SettingRanges.trackingSpeed, or: current.trackingSpeed) }
            else { wrong(pointer, "trackingSpeed", raw, range(SettingRanges.trackingSpeed)) }
        }
        if let raw = field("precisionSpeed") {
            if let v = Self.number(raw) { s.precisionSpeed = v.clamped(to: SettingRanges.precisionSpeed, or: current.precisionSpeed) }
            else { wrong(pointer, "precisionSpeed", raw, range(SettingRanges.precisionSpeed)) }
        }
        if s.trackingSpeed != nil || s.precisionSpeed != nil { parts.append(.pointer) }

        // Scrolling: only the keys given change; the rest stay as the person has them.
        if let raw = field("scroll") {
            let read = scroll(raw, over: current.scrollSettings, at: scrolling.at("scroll"), main: true)
            s.scroll = read.settings
            s.ballScrollSpeed = read.ballSpeed
        }
        if let raw = field("ballScrollSpeed") {
            if let v = Self.number(raw) { s.ballScrollSpeed = v.clamped(to: SettingRanges.ballScrollSpeed, or: current.ballScrollSpeed) }
            else { wrong(scrolling, "ballScrollSpeed", raw, range(SettingRanges.ballScrollSpeed)) }
        }
        if s.scroll != nil || s.ballScrollSpeed != nil { parts.append(.scrolling) }

        // Buttons and gestures
        if let raw = field("buttons"), let map = self.buttons(raw, was: current.buttons, at: Place(label: "", path: "buttons"), prefix: ""), !map.isEmpty {
            s.buttons = map
        }
        if let raw = field("gesturesEnabled") {
            if let b = Self.bool(raw) { s.gesturesEnabled = b } else { wrong(buttons, "gesturesEnabled", raw, "true or false") }
        }
        if let raw = field("gestureDistance") {
            if let d = Self.choice(raw, GestureDistance.self) { s.gestureDistance = d }
            else { wrong(buttons, "gestureDistance", raw, "one of: " + Self.names(GestureDistance.self)) }
        }
        if let raw = field("gestureSteadyHands") {
            if let b = Self.bool(raw) { s.gestureSteadyHands = b } else { wrong(buttons, "gestureSteadyHands", raw, "true or false") }
        }
        if s.buttons?.values.contains(where: { !$0.isGesture }) == true { parts.append(.buttons) }
        if s.buttons?.values.contains(where: \.isGesture) == true || s.gesturesEnabled != nil || s.gestureDistance != nil || s.gestureSteadyHands != nil {
            parts.append(.gestures)
        }

        // Combos: laid over the ones the person has.
        if let raw = field("combos"), let list = combos(raw, over: current.chords, at: Place(label: "", path: "combos"), prefix: "") {
            s.chords = list
            parts.append(.combos)
        }

        // App setups
        if let raw = field("apps") {
            let at = Place(label: ImportChange.Area.appSetups.title, path: "apps")
            if let list = raw as? [Any] {
                var out: [AppProfile] = []
                for (i, item) in list.enumerated() {
                    guard i < ImportLimits.maxAppSetups else {
                        leave(at, nil, .tooMany, "at most \(ImportLimits.maxAppSetups) app setups in one code")
                        break
                    }
                    guard let p = app(item, index: i), !out.contains(where: { $0.bundleID == p.bundleID }) else { continue }
                    out.append(p)
                }
                if !out.isEmpty {
                    s.apps = out
                    parts += out.map { .app($0.bundleID) }
                }
            } else {
                leave(at, raw, .wrongValue, "\"apps\" is a list: [{\"app\": \"Safari\", …}]")
            }
        }

        // Look and sound
        if let raw = field("look"), let l = look(raw) {
            s.look = l
            parts.append(.look)
        }
        if let raw = field("sounds"), let so = sound(raw) {
            s.sounds = so
            parts.append(.sounds)
        }

        guard !parts.isEmpty else { return nil }
        s.parts = parts
        return s
    }

    // MARK: Scrolling

    /// `raw`'s keys laid over `base`. Nil settings when none of them could be used.
    private func scroll(_ raw: Any, over base: ScrollSettings, at p: Place, main: Bool) -> (settings: ScrollSettings?, ballSpeed: Double?) {
        guard let d = raw as? [String: Any] else {
            leave(p, raw, .wrongValue, "\"scroll\" is an object with only the keys you change, like {\"scrollMode\": \"follow\"}")
            return (nil, nil)
        }
        var out = base, used = false
        var ball: Double?
        for key in d.keys.sorted() {
            let v = d[key]!
            if key == "scrollMode" {
                if let m = Self.choice(v, ScrollMode.self) { out.scrollMode = m; used = true }
                else { wrong(p, key, v, "one of: " + Self.names(ScrollMode.self)) }
            } else if v is NSNull {
                wrong(p, key, v, Self.nullHint)
            } else if let f = SetupFields.scrollNumbers.first(where: { $0.key == key }) {
                if let n = Self.number(v) { out[keyPath: f.path] = n.clamped(to: f.range, or: base[keyPath: f.path]); used = true }
                else { wrong(p, key, v, range(f.range)) }
            } else if let f = SetupFields.scrollFlags.first(where: { $0.key == key }) {
                if let b = Self.bool(v) { out[keyPath: f.path] = b; used = true } else { wrong(p, key, v, "true or false") }
            } else if key == "ballScrollSpeed", main {
                if let n = Self.number(v) { ball = n.clamped(to: SettingRanges.ballScrollSpeed, or: current.ballScrollSpeed) }
                else { wrong(p, key, v, range(SettingRanges.ballScrollSpeed)) }
            } else {
                leave(p.at(SetupCode.quote(key)), nil, .unknownSetting, "\"scroll\" has no setting with this name; use only what the reference lists")
            }
        }
        return (used ? ImportSanitize.scroll(out) : nil, ball)
    }

    // MARK: Buttons and combos

    /// The buttons a code lists ("1" to "7"; never 0). `was`: what those buttons do now.
    /// `inApp`: an app setup's, where a button's null means "as in the main setup".
    private func buttons(_ raw: Any, was: [Int: ButtonAction], at p: Place, prefix: String, inApp: Bool = false) -> [Int: ButtonAction]? {
        let area = Place(label: prefix + ImportChange.Area.buttons.title, path: p.path)
        guard let d = raw as? [String: Any] else {
            leave(area, raw, .wrongValue, "\"buttons\" is an object: {\"1\": action, \"2\": action, \"3\": action}")
            return nil
        }
        var out: [Int: ButtonAction] = [:]
        for key in d.keys.sorted() {
            guard let b = Int(key), String(b) == key, (0...31).contains(b) else {
                leave(area.at(SetupCode.quote(key)), nil, .unknownSetting, "buttons are numbered \"1\", \"2\", \"3\"")
                continue
            }
            let place = Place(label: prefix + ImportReview.buttonName(b), path: p.path + "." + key)
            guard b != 0 else {
                leave(place, nil, .primaryButton, "button 0 is always a left click; never include it")
                continue
            }
            guard ImportLimits.buttons.contains(b) else {
                leave(place, nil, .wrongValue, "there's no button with this number")
                continue
            }
            if d[key] is NSNull {
                if inApp { out[b] = current.buttons[b] ?? .system } else { leave(place, "null", .wrongValue, Self.nullHint) }
                continue
            }
            if let a = action(d[key], at: place, was: was[b], nested: false) { out[b] = a }
        }
        return out
    }

    /// A code's combos laid over `base`: one for the same buttons replaces it, `"remove": true`
    /// takes it away, the rest stay. Nil when nothing in the list could be used.
    private func combos(_ raw: Any, over base: [Chord], at p: Place, prefix: String) -> [Chord]? {
        let area = Place(label: prefix + ImportChange.Area.combos.title, path: p.path)
        guard let list = raw as? [Any] else {
            leave(area, raw, .wrongValue, "\"combos\" is a list: [{\"buttons\": [2, 3], \"action\": action}]")
            return nil
        }
        var out = base, used = false
        for (i, item) in list.enumerated() {
            guard i < ConfigLimits.maxChords else {
                leave(area, nil, .tooMany, "at most \(ImportLimits.maxChords) combos")
                break
            }
            guard let d = item as? [String: Any], let rawButtons = d["buttons"] as? [Any] else {
                leave(area, item, .wrongValue, "a combo is {\"buttons\": [2, 3], \"action\": action}")
                continue
            }
            let nums = rawButtons.compactMap { Self.number($0) }
                .filter { $0 == $0.rounded() && $0 >= 0 && $0 <= 31 && ImportLimits.chordButtons.contains(Int($0)) }.map { Int($0) }
            guard nums.count == rawButtons.count, Set(nums).count == nums.count, (2...4).contains(nums.count) else {
                leave(area, rawButtons, .wrongValue, "a combo's buttons are two to four different button numbers, like [2, 3]")
                continue
            }
            let set = nums.sorted()
            let place = Place(label: prefix + ImportReview.comboName(set), path: p.path + "[" + set.map(String.init).joined(separator: "+") + "]")
            let existing = out.firstIndex { $0.buttons == set }
            if Self.bool(d["remove"]) == true || d["action"] is NSNull {
                if let existing { out.remove(at: existing); used = true }
                continue
            }
            // A combo that can't be read leaves the one the person has alone.
            guard let a = action(d["action"], at: place.at("action"), was: existing.map { out[$0].action }, nested: false,
                                 withPrimary: set.contains(0)) else { continue }
            if let existing { out[existing].action = a } else { out.append(Chord(buttons: set, action: a)) }
            used = true
        }
        if out.count > ImportLimits.maxChords {
            leave(area, nil, .tooMany, "at most \(ImportLimits.maxChords) combos")
            out = Array(out.prefix(ImportLimits.maxChords))
        }
        return used ? out : nil
    }

    // MARK: App setups

    /// One app's entry, laid over the setup that app already has. The app is found on this
    /// Mac by its name or bundle ID; one that isn't here is left out.
    private func app(_ raw: Any, index: Int) -> AppProfile? {
        let area = Place(label: ImportChange.Area.appSetups.title, path: "apps[\(index)]")
        guard let d = raw as? [String: Any] else {
            leave(area, raw, .wrongValue, "an app setup is {\"app\": \"Safari\", …}")
            return nil
        }
        let asked = ImportText.clean((d["app"] as? String) ?? (d["name"] as? String) ?? (d["bundleID"] as? String) ?? "", max: 80)
        guard !asked.isEmpty else {
            leave(area, nil, .wrongValue, "an app setup needs \"app\": the app's name")
            return nil
        }
        guard let found = find(asked), ImportText.isBundleID(found.bundleID) else {
            leave(Place(label: asked, path: "apps[\(asked)]"), asked, .unknownApp, "no app with this name on this Mac; ask me for the app's exact name")
            return nil
        }
        let existing = current.profile(for: found.bundleID)
        var name = ImportText.clean(found.name)
        if name.isEmpty { name = found.bundleID }
        var p = existing ?? AppProfile(bundleID: found.bundleID, name: name)
        let place = Place(label: p.name, path: "apps[\(asked)]")
        let prefix = p.name + " · "
        var used = false
        for key in d.keys.sorted() {
            let v = d[key]!
            switch SetupFields.topAliases[key] ?? key {
            case "app", "name", "bundleID": break
            case "trackingSpeed":
                if v is NSNull {
                    used = used || p.trackingSpeed != nil
                    p.trackingSpeed = nil
                } else if let n = Self.number(v) {
                    p.trackingSpeed = n.clamped(to: SettingRanges.trackingSpeed, or: current.trackingSpeed)
                    used = true
                } else {
                    wrong(place, key, v, range(SettingRanges.trackingSpeed) + ", or null to use the main setup's")
                }
            case "scroll":
                if v is NSNull {
                    used = used || p.scroll != nil
                    p.scroll = nil
                } else if let s = scroll(v, over: p.scroll ?? current.scrollSettings, at: place.at("scroll"), main: false).settings {
                    p.scroll = s
                    used = true
                }
            case "buttons":
                if v is NSNull {
                    used = used || p.buttons != nil
                    p.buttons = nil
                    break
                }
                // Buttons it doesn't list keep doing what they do in this app now.
                let base = (p.buttons ?? current.buttons).filter { ImportLimits.buttons.contains($0.key) }
                guard let map = buttons(v, was: base, at: place.at("buttons"), prefix: prefix, inApp: true), !map.isEmpty else { break }
                p.buttons = base.merging(map) { $1 }.filter { $0.value != .system }
                used = true
            case "combos":
                if v is NSNull {
                    used = used || p.chords != nil
                    p.chords = nil
                } else if let list = combos(v, over: p.chords ?? current.chords, at: place.at("combos"), prefix: prefix) {
                    p.chords = list
                    used = true
                }
            default:
                leave(place.at(SetupCode.quote(key)), nil, .unknownSetting, "an app setup has \"app\", \"trackingSpeed\", \"scroll\", \"buttons\" and \"combos\"")
            }
        }
        guard used else {
            if existing == nil, !noted(under: place) {
                leave(place, nil, .wrongValue, "an app setup needs at least one of \"trackingSpeed\", \"scroll\", \"buttons\", \"combos\"")
            }
            return nil
        }
        return p
    }

    // MARK: Look and sound

    private func look(_ raw: Any) -> ShareLook? {
        let p = Place(label: ImportChange.Area.look.title, path: "look")
        let hint = "\"look\" is {\"theme\": one of \(ShareLook.themeIDs.joined(separator: ", "))}; custom also needs \"custom\": three six-digit hex colors"
        var theme: String?, custom: [Any]?
        if let s = raw as? String {
            theme = s
        } else if let d = raw as? [String: Any] {
            theme = d["theme"] as? String
            custom = d["custom"] as? [Any]
        }
        guard let id = theme?.trimmingCharacters(in: .whitespaces).lowercased(), ShareLook.themeIDs.contains(id) else {
            leave(p, raw, .wrongValue, hint)
            return nil
        }
        guard id == "custom" else { return ShareLook(theme: id, custom: nil) }
        // Their own colors aren't in the prompt, so "custom" coming back without any means "as it is".
        if custom == nil, lookIsCustom { return nil }
        let colors = (custom ?? []).compactMap { $0 as? String }.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        guard let l = ShareLook(theme: id, custom: colors).sanitized else {
            leave(p, raw, .wrongValue, hint)
            return nil
        }
        return l
    }

    private func sound(_ raw: Any) -> ShareSounds? {
        let p = Place(label: ImportChange.Area.sounds.title, path: "sounds")
        var out = sounds ?? ShareSounds(on: true, volume: 1, kinds: [:])
        if let on = Self.bool(raw) {
            out.on = on
            return out.sanitized
        }
        guard let d = raw as? [String: Any] else {
            leave(p, raw, .wrongValue, "\"sounds\" is an object like {\"on\": true, \"volume\": 0.8}")
            return nil
        }
        var used = false
        for key in d.keys.sorted() {
            let v = d[key]!
            switch key {
            case "on":
                if let b = Self.bool(v) { out.on = b; used = true } else { wrong(p, key, v, "true or false") }
            case "volume":
                if let n = Self.number(v) { out.volume = n.clamped(to: 0...1, or: out.volume); used = true }
                else { wrong(p, key, v, "a number from 0 to 1") }
            case "kinds":
                guard let kinds = v as? [String: Any] else {
                    wrong(p, key, v, "an object of true and false")
                    break
                }
                for k in kinds.keys.sorted() {
                    guard ShareSounds.kindIDs.contains(k) else {
                        leave(p.at("kinds." + SetupCode.quote(k)), nil, .unknownSetting, "the kinds are: " + ShareSounds.kindIDs.joined(separator: ", "))
                        continue
                    }
                    if let b = Self.bool(kinds[k]) { out.kinds[k] = b; used = true } else { wrong(p.at("kinds"), k, kinds[k], "true or false") }
                }
            default:
                leave(p.at(SetupCode.quote(key)), nil, .unknownSetting, "\"sounds\" has \"on\", \"volume\" and \"kinds\"")
            }
        }
        return used ? out.sanitized : nil
    }

    // MARK: Actions

    /// One action: its short text, or `{"gesture": {…}}` / `{"switcher": {…}}`. Nil (with a
    /// note) for anything else. `was`: what's there now, which is what "open:(hidden)" keeps.
    /// `nested`: inside Gestures or a Switcher, where neither can go. `withPrimary`: on a combo
    /// that includes the primary button, where neither can go either.
    func action(_ raw: Any?, at p: Place, was: ButtonAction?, nested: Bool, withPrimary: Bool = false) -> ButtonAction? {
        let holdHint = nested ? "Gestures and the Switcher can't go inside each other"
            : "Gestures and the Switcher can't be on a combo that includes button 0"
        if let text = raw as? String {
            let a = actionText(text, at: p, was: was)
            if let a, a.holdsTheBall, nested || withPrimary {
                leave(p, text, .notHere, holdHint)
                return nil
            }
            return a
        }
        if let d = raw as? [String: Any], d.count == 1, let (kind, body) = d.first, kind == "gesture" || kind == "switcher" {
            guard !nested, !withPrimary else {
                leave(p, kind, .notHere, holdHint)
                return nil
            }
            if kind == "switcher" {
                var s = AppSwitcher()
                if let inner = body as? [String: Any] {
                    if let tap = inner["tap"], !(tap is NSNull) {
                        var oldTap: ButtonAction?
                        if case .switcher(let old) = was { oldTap = old.tap }
                        s.tap = action(tap, at: p.at("switcher.tap"), was: oldTap, nested: true) ?? .system
                    }
                    for key in inner.keys.sorted() where key != "tap" {
                        // "hidden" (the apps a Switcher leaves out) is the person's own, on this Mac.
                        leave(p.at("switcher." + SetupCode.quote(key)), nil, key == "hidden" ? .notFromACode : .unknownSetting,
                              "a Switcher only has \"tap\"")
                    }
                } else if !(body is NSNull) {
                    leave(p, raw, .wrongValue, "write the Switcher as \"switcher\" or {\"switcher\": {\"tap\": action}}")
                    return nil
                }
                // The apps the person hid from this Switcher stay hidden.
                if case .switcher(let old) = was { s.hidden = old.hidden }
                return .switcher(s)
            }
            var old: ButtonGesture?
            if case .gesture(let g) = was { old = g }
            return gesture(body, at: p.at("gesture"), was: old).map { .gesture($0) }
        }
        if raw is [String: Any] {
            leave(p, raw, .unknownAction, "write an action as its short text, like \"keys:cmd+c\", or as {\"gesture\": {…}} or {\"switcher\": {…}}")
        } else if raw is NSNull {
            leave(p, raw, .wrongValue, Self.nullHint)
        } else {
            leave(p, raw, .wrongValue, "an action is text, like \"rightClick\" or \"keys:cmd+c\"")
        }
        return nil
    }

    private func actionText(_ text: String, at p: Place, was: ButtonAction?) -> ButtonAction? {
        let unknown = "Glideball has no action called this; use only the actions the reference lists"
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf8.count <= SetupCode.maxTextLength, !t.isEmpty else {
            leave(p, text, .unknownAction, unknown)
            return nil
        }
        let lower = t.lowercased()
        if let hit = SetupCode.simple.first(where: { $0.text.lowercased() == lower }) { return hit.action }
        if let hit = SetupCode.simpleAliases[lower] { return hit }
        if lower == "switcher" {
            if case .switcher(let old) = was { return .switcher(AppSwitcher(tap: .system, hidden: old.hidden)) }
            return .switcher(AppSwitcher())
        }
        guard let colon = t.firstIndex(of: ":") else {
            leave(p, text, .unknownAction, lower == "gesture" || lower == "gestures" ? "write Gestures as {\"gesture\": {\"up\": action, …}}" : unknown)
            return nil
        }
        let rest = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        switch t[..<colon].lowercased() {
        case "keys", "holdkeys":
            guard let s = SetupKeys.shortcut(rest)?.sanitized() else {
                leave(p, text, .unknownKeys, "write a shortcut as modifiers and one key joined with +, like keys:cmd+shift+4; the modifiers are cmd, ctrl, opt, shift, fn")
                return nil
            }
            return lower.hasPrefix("hold") ? .holdShortcut(s) : .shortcut(s)
        case "click":
            guard let (flags, last) = SetupKeys.split(rest), let button = SetupKeys.clickButtons.firstIndex(of: last.lowercased()) else {
                leave(p, text, .unknownKeys, "write a click with modifiers like click:ctrl+left; it ends in left, right or middle")
                return nil
            }
            if flags.isEmpty, button < 3 { return [.leftClick, .rightClick, .middleClick][button] }
            return .modifiedClick(button: button, modifiers: flags.rawValue & KeyShortcut.allowedModifiers)
        case "media":
            guard let key = SetupKeys.media.first(where: { $0.name.lowercased() == rest.lowercased() })?.key else {
                leave(p, text, .unknownAction, "the media keys are: " + AIReferenceLists.mediaNames.joined(separator: ", "))
                return nil
            }
            return .media(key)
        case "open":
            let asked = ImportText.clean(rest, max: 80)
            if asked == SetupCode.hiddenApp {
                // App names were left out of the prompt: this keeps the Open that's there.
                if case .openApp = was { return was }
                leave(p, text, .unknownApp, "app names were left out of my setup, so this can only stay where it was; ask me for the app's name to put it somewhere else")
                return nil
            }
            guard !asked.isEmpty, let found = find(asked), ImportText.isBundleID(found.bundleID) else {
                leave(p, text, .unknownApp, "no app with this name on this Mac; ask me for the app's exact name")
                return nil
            }
            return .openApp(bundleID: found.bundleID)
        default:
            leave(p, text, .unknownAction, unknown)
            return nil
        }
    }

    // MARK: Gestures

    /// A Gestures button, whole: the directions, tap and ring a code gives; anything it
    /// doesn't give is empty. Nil when nothing in it does anything.
    private func gesture(_ raw: Any, at p: Place, was: ButtonGesture?) -> ButtonGesture? {
        var body = raw
        if let d = raw as? [String: Any], d.count == 1, let inner = d["_0"] { body = inner }
        guard let whole = body as? [String: Any] else {
            leave(p, raw, .wrongValue, "write Gestures as {\"gesture\": {\"up\": action, \"down\": action, \"tap\": action}}")
            return nil
        }
        // Inside a gesture, null is the same as leaving the key out: that place is empty, a
        // setting is the usual one.
        let d = whole.filter { !($0.value is NSNull) }
        var g = ButtonGesture()
        var diagonal = false
        for dir in GestureDirection.allCases {
            guard let v = d[dir.rawValue], !(v is NSNull) else { continue }
            guard let step = step(v, at: p.at(dir.rawValue), was: was?[dir], direction: dir) else { continue }
            g[dir] = step
            if dir.isDiagonal || step.more?.enumerated().contains(where: { $0.offset % 2 == 1 && $0.element != nil }) == true { diagonal = true }
        }
        if let v = d["tap"], !(v is NSNull) { g.tap = action(v, at: p.at("tap"), was: was?.tap, nested: true) ?? .system }
        if let v = d["eight"] {
            if let b = Self.bool(v) {
                g.eight = b || diagonal
            } else {
                wrong(p, "eight", v, "true or false")
                g.eight = diagonal
            }
        } else {
            g.eight = diagonal   // a diagonal in it means eight directions
        }
        if let v = d["show"] {
            if let s = Self.choice(v, RingShow.self) { g.show = s } else { wrong(p, "show", v, "one of: " + Self.names(RingShow.self)) }
        }
        if let v = d["distance"], !(v is NSNull) {
            if let s = Self.choice(v, GestureDistance.self) { g.distance = s } else { wrong(p, "distance", v, "one of: " + Self.names(GestureDistance.self)) }
        }
        if let v = d["reverse"] {
            if let b = Self.bool(v) { g.reverse = b } else { wrong(p, "reverse", v, "true or false") }
        }
        let pair: [(String, WritableKeyPath<ButtonGesture, ButtonAction?>)] = [("ringUp", \.ringUp), ("ringDown", \.ringDown)]
        for (key, path) in pair {
            guard let v = d[key], !(v is NSNull) else { continue }
            guard let a = action(v, at: p.at(key), was: was?[keyPath: path], nested: true) else { continue }
            guard WheelMenu.oneShot(a) != nil else {
                leave(p.at(key), v, .notHere, "a ring step can't hold something down; use keys, media, open, a click, back or forward")
                continue
            }
            g[keyPath: path] = a
        }
        if let v = d["ring"], let r = Self.choice(v, RingJob.self) {
            g.ring = r
        } else {
            if let v = d["ring"] { wrong(p, "ring", v, "one of: " + Self.names(RingJob.self)) }
            if g.ringUp != nil || g.ringDown != nil { g.ring = .custom }   // its own pair given: that's the ring job
        }
        // A pair the ring job doesn't use would sit there unseen: it isn't kept.
        if g.ring != .custom {
            g.ringUp = nil
            g.ringDown = nil
        }
        for key in d.keys.sorted() where GestureDirection(rawValue: key) == nil && !SetupFields.gestureKeys.contains(key) {
            leave(p.at(SetupCode.quote(key)), nil, .unknownSetting,
                  "a gesture has the directions, \"tap\", \"eight\", \"show\", \"ring\", \"ringUp\", \"ringDown\", \"reverse\" and \"distance\"")
        }
        // Nothing left that rolls or turns: leaving the button as it is beats a gesture that does nothing.
        guard g.usedDirections.contains(where: { g[$0]?.isUsable == true }) || (g.ring != .scroll && g.ring != .off) else {
            if !noted(under: p) { leave(p, nil, .wrongValue, "a gesture needs at least one direction that does something") }
            return nil
        }
        return g
    }

    /// What one direction does: an action, `{"do": action, "mode": …}`, or `{"more": {…}}`.
    private func step(_ raw: Any, at p: Place, was: GestureStep?, direction: GestureDirection?) -> GestureStep? {
        let oldAction = was?.more == nil ? was?.action : nil
        guard let d = raw as? [String: Any], d["gesture"] == nil, d["switcher"] == nil else {
            return fired(raw, at: p, was: oldAction).map { a in
                var s = GestureStep(a)
                s.mode = SetupCode.defaultMode(a)
                return s
            }
        }
        if d["more"] is NSNull || (d["more"] == nil && (d["do"] ?? d["action"]) is NSNull) { return nil }   // null inside a gesture: empty
        if let more = d["more"] {
            guard let direction else {
                leave(p, "more", .notHere, "a More can't be inside a More")
                return nil
            }
            var places = [GestureStep?](repeating: nil, count: 8)
            let back = (direction.place + 4) % 8
            func put(_ i: Int, _ v: Any) {
                guard !(v is NSNull) else { return }
                let at = p.at("more." + GestureDirection(place: i).rawValue)
                guard i != back else {
                    leave(at, v, .notHere, "this place is the way back out of More; leave it empty")
                    return
                }
                places[i] = step(v, at: at, was: was?.more.flatMap { $0.indices.contains(i) ? $0[i] : nil }, direction: nil)
            }
            if let named = more as? [String: Any] {
                for key in named.keys.sorted() {
                    guard let dir = GestureDirection(rawValue: key) else {
                        leave(p.at("more." + SetupCode.quote(key)), nil, .unknownSetting, "the places in a More are: " + Self.names(GestureDirection.self))
                        continue
                    }
                    put(dir.place, named[key]!)
                }
            } else if let list = more as? [Any] {
                for (i, v) in list.prefix(8).enumerated() { put(i, v) }
            } else {
                leave(p, more, .wrongValue, "write a More as {\"more\": {\"up\": action, \"right\": action}}")
                return nil
            }
            guard places.contains(where: { $0 != nil }) else {
                if !noted(under: p) { leave(p, nil, .wrongValue, "a More needs at least one place that does something") }
                return nil
            }
            return .moreRing(places)
        }
        guard let inner = d["do"] ?? d["action"] else {
            leave(p, raw, .wrongValue, "a direction is an action, {\"do\": action, \"mode\": \"continuous\"} or {\"more\": {…}}")
            return nil
        }
        guard let a = fired(inner, at: p, was: oldAction) else { return nil }
        var s = GestureStep(a)
        s.mode = SetupCode.defaultMode(a)
        if let m = d["mode"], !(m is NSNull) {
            if let t = m as? String, let mode = GestureStep.Mode(rawValue: t.trimmingCharacters(in: .whitespaces).lowercased()) {
                s.mode = mode
            } else {
                wrong(p, "mode", m, "one of: chain, continuous, once")
            }
        } else if Self.bool(d["repeats"]) == true {
            s.mode = .continuous
        } else if Self.bool(d["once"]) == true {
            s.mode = .once
        }
        return s
    }

    /// An action a direction can fire: a quick press, never something held. "system" and
    /// "disabled" there just mean the direction is empty.
    private func fired(_ raw: Any, at p: Place, was: ButtonAction?) -> ButtonAction? {
        guard let a = action(raw, at: p, was: was, nested: true) else { return nil }
        if a == .system || a == .disabled { return nil }
        guard GestureStep(a).firable != nil else {
            leave(p, raw, .notHere, "a direction can't hold something down; use keys, media, open, a click, back, forward or precisionToggle")
            return nil
        }
        return a
    }
}

/// The lists the reference prints, shared with the reader's hints.
enum AIReferenceLists {
    /// The media keys a button can press (brightness is only a ring job, as in the app).
    static let mediaKeys: [MediaKey] = [.playPause, .next, .previous, .volumeUp, .volumeDown, .mute]
    static var mediaNames: [String] { mediaKeys.map(SetupKeys.name) }
}
