import CoreGraphics
import Foundation

// Settings that come from outside this Mac (a settings file, a shared setup's
// file or link, KensingtonWorks) are hostile input until proven otherwise. Every
// one of them goes through `GlideConfig.sanitizedForImport()` before it's shown
// or applied: numbers clamped to what the sliders allow (and never NaN or
// infinite), text cleaned and cut short, counts capped, bundle IDs checked,
// keyboard shortcuts limited to real key codes and the four modifiers, and the
// primary button never anything but a left click.
//
// Foundation only, so scripts/import-sim and scripts/command-sim can check it.

enum ImportLimits {
    /// A settings or share file bigger than this isn't one (a real one is a few KB).
    static let maxFileBytes = 1_000_000
    /// JSON nested deeper than this isn't ours (ours is under 10 deep).
    static let maxDepth = 32
    static let maxChords = 24
    static let maxAppSetups = 64
    static let maxDisplaySpeeds = 16
    /// Button numbers an import may set: 1…7. 0 is the primary button, which never changes.
    static let buttons = 1...7
    static let chordButtons = 0...7
    static let maxNameLength = 80
    static let maxKeyNameLength = 12
}

/// The sliders' ranges: an import can't go past what you could set yourself.
enum SettingRanges {
    static let trackingSpeed = 0.5...80.0
    static let precisionSpeed = 0.25...3.0
    static let nativeScrollSpeed = 0.0...5.0
    static let flyDistance = 1.0...20.0
    static let flyAcceleration = 0.0...1.5
    static let unit = 0.0...1.0
    static let scrollDistance = 1.0...40.0
    static let ballScrollSpeed = 0.25...4.0
}

extension Double {
    /// Clamped to `range`; NaN and infinities become `fallback`.
    func clamped(to range: ClosedRange<Double>, or fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum ImportText {
    /// Text from outside, safe to show: no control characters, no invisible or
    /// direction-changing ones, trimmed, at most `max` characters.
    static func clean(_ s: String, max: Int = ImportLimits.maxNameLength) -> String {
        let scalars = s.unicodeScalars.filter { u in
            if u.properties.generalCategory == .control || u.properties.generalCategory == .format { return false }
            if (0x2028...0x2029).contains(u.value) { return false }   // line and paragraph separators
            return true
        }
        var out = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > max { out = String(out.prefix(max)) }
        return out
    }

    /// A plausible bundle ID: "com.apple.Safari". Letters, digits, dots, hyphens and underscores only.
    static func isBundleID(_ s: String) -> Bool {
        guard (1...155).contains(s.utf8.count), !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy { u in
            u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "." || u == "-" || u == "_")
        }
    }
}

enum ImportJSON {
    /// Whether `data`'s brackets nest no deeper than `limit` (strings skipped).
    /// Checked before decoding, so a file of ten thousand `[` can't exhaust the stack.
    static func depthIsWithin(_ data: Data, limit: Int = ImportLimits.maxDepth) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > limit { return false }
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return true
    }
}

extension KeyShortcut {
    /// The modifiers a shortcut may use: ⇧ ⌃ ⌥ ⌘ and fn.
    static let allowedModifiers: UInt64 = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue

    /// A real key code (0…127), only the modifiers above, and a short printable name.
    func sanitized() -> KeyShortcut? {
        guard keyCode <= 127 else { return nil }
        var name = ImportText.clean(keyName, max: ImportLimits.maxKeyNameLength)
        if name.isEmpty { name = "?" }
        return KeyShortcut(keyCode: keyCode, modifiers: modifiers & Self.allowedModifiers, keyName: name)
    }
}

extension ButtonAction {
    /// This action made safe, or nil when there's nothing safe to keep.
    /// A gesture inside a gesture isn't allowed (its directions and tap are plain actions).
    func sanitized(nested: Bool = false) -> ButtonAction? {
        switch self {
        case .shortcut(let s): return s.sanitized().map { .shortcut($0) }
        case .holdShortcut(let s): return s.sanitized().map { .holdShortcut($0) }
        case .modifiedClick(let button, let modifiers):
            guard (0...4).contains(button) else { return nil }
            return .modifiedClick(button: button, modifiers: modifiers & KeyShortcut.allowedModifiers)
        case .openApp(let id): return ImportText.isBundleID(id) ? self : nil
        case .gesture(let g):
            guard !nested else { return nil }
            var out = ButtonGesture()
            for d in GestureDirection.allCases {
                if let step = g[d], let a = step.action.sanitized(nested: true) { out[d] = GestureStep(a, repeats: step.repeats, once: step.once) }
            }
            out.tap = g.tap.sanitized(nested: true) ?? .system
            out.distance = g.distance
            return .gesture(out)
        case .system, .leftClick, .rightClick, .middleClick, .back, .forward, .disabled,
             .precisionHold, .precisionToggle, .ballScrollHold, .dragLock, .media:
            return self
        }
    }

    /// Opens an app or presses keys: an import lists these one by one.
    var needsCaution: Bool {
        switch self {
        case .openApp, .shortcut, .holdShortcut: true
        case .gesture(let g): GestureDirection.allCases.contains { g[$0]?.action.needsCaution == true } || g.tap.needsCaution
        default: false
        }
    }
}

enum ImportSanitize {
    static func buttons(_ map: [Int: ButtonAction]?) -> [Int: ButtonAction] {
        var out: [Int: ButtonAction] = [:]
        for (b, a) in map ?? [:] where ImportLimits.buttons.contains(b) {
            if let safe = a.sanitized() { out[b] = safe }
        }
        return out
    }

    static func chords(_ list: [Chord]?) -> [Chord] {
        var out: [Chord] = []
        for c in list ?? [] {
            let set = Set(c.buttons.filter { ImportLimits.chordButtons.contains($0) })
            guard (2...4).contains(set.count), set.count == c.buttons.count else { continue }
            let sorted = set.sorted()
            guard !out.contains(where: { $0.buttons == sorted }), let action = c.action.sanitized() else { continue }
            out.append(Chord(buttons: sorted, action: action))   // a fresh id
            if out.count == ImportLimits.maxChords { break }
        }
        return out
    }

    static func scroll(_ s: ScrollSettings) -> ScrollSettings {
        let d = GlideConfig().scrollSettings
        var o = s
        o.nativeScrollSpeed = s.nativeScrollSpeed.clamped(to: SettingRanges.nativeScrollSpeed, or: d.nativeScrollSpeed)
        o.flyDistance = s.flyDistance.clamped(to: SettingRanges.flyDistance, or: d.flyDistance)
        o.flyAcceleration = s.flyAcceleration.clamped(to: SettingRanges.flyAcceleration, or: d.flyAcceleration)
        o.flyGlide = s.flyGlide.clamped(to: SettingRanges.unit, or: d.flyGlide)
        o.flyReach = s.flyReach.clamped(to: SettingRanges.unit, or: d.flyReach)
        o.scrollDistance = s.scrollDistance.clamped(to: SettingRanges.scrollDistance, or: d.scrollDistance)
        o.scrollSmoothness = s.scrollSmoothness.clamped(to: SettingRanges.unit, or: d.scrollSmoothness)
        o.scrollAcceleration = s.scrollAcceleration.clamped(to: SettingRanges.unit, or: d.scrollAcceleration)
        o.throwAmount = s.throwAmount.clamped(to: SettingRanges.unit, or: d.throwAmount)
        return o
    }

    static func appSetup(_ p: AppProfile) -> AppProfile? {
        guard ImportText.isBundleID(p.bundleID) else { return nil }
        var name = ImportText.clean(p.name)
        if name.isEmpty { name = p.bundleID }
        var out = AppProfile(bundleID: p.bundleID, name: name)
        out.trackingSpeed = p.trackingSpeed.map { $0.clamped(to: SettingRanges.trackingSpeed, or: GlideConfig().trackingSpeed) }
        out.scroll = p.scroll.map(scroll)
        out.buttons = p.buttons.map { buttons($0) }
        out.chords = p.chords.map { chords($0) }
        return out
    }

    static func shortcut(_ s: KeyShortcut?, fallback: KeyShortcut?) -> KeyShortcut? {
        guard let s else { return nil }
        guard let safe = s.sanitized(), !safe.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return fallback }
        return safe
    }
}

extension GlideConfig {
    /// These settings with everything clamped, cleaned and capped. The same for
    /// every way settings come in: a settings file, a shared setup (file or link)
    /// and KensingtonWorks.
    func sanitizedForImport() -> GlideConfig {
        let d = GlideConfig()
        var c = self
        c.trackingSpeed = trackingSpeed.clamped(to: SettingRanges.trackingSpeed, or: d.trackingSpeed)
        c.precisionSpeed = precisionSpeed.clamped(to: SettingRanges.precisionSpeed, or: d.precisionSpeed)
        c.scrollSettings = ImportSanitize.scroll(scrollSettings)
        c.ballScrollSpeed = ballScrollSpeed.clamped(to: SettingRanges.ballScrollSpeed, or: d.ballScrollSpeed)
        c.buttons = ImportSanitize.buttons(buttons)   // never the primary button
        c.chords = ImportSanitize.chords(chords)
        var seen = Set<String>()
        c.appProfiles = appProfiles.compactMap(ImportSanitize.appSetup).filter { seen.insert($0.bundleID).inserted }
        if c.appProfiles.count > ImportLimits.maxAppSetups { c.appProfiles = Array(c.appProfiles.prefix(ImportLimits.maxAppSetups)) }
        var g = GlobalShortcuts()
        g.pause = ImportSanitize.shortcut(globalShortcuts.pause, fallback: GlobalShortcuts.defaultPause)
        g.precision = ImportSanitize.shortcut(globalShortcuts.precision, fallback: nil)
        g.ballScroll = ImportSanitize.shortcut(globalShortcuts.ballScroll, fallback: nil)
        g.dragLock = ImportSanitize.shortcut(globalShortcuts.dragLock, fallback: nil)
        c.globalShortcuts = g
        var ds = DisplaySpeeds()
        ds.enabled = displaySpeeds.enabled
        for (key, speed) in displaySpeeds.speeds.sorted(by: { $0.key < $1.key }).prefix(ImportLimits.maxDisplaySpeeds)
        where key.count <= 120 && speed.isFinite {
            ds.speeds[key] = speed.clamped(to: SettingRanges.trackingSpeed, or: d.trackingSpeed)
            if let name = displaySpeeds.names[key] { ds.names[key] = ImportText.clean(name) }
        }
        c.displaySpeeds = ds
        return c
    }
}
