import Carbon.HIToolbox
import Foundation

// Importing from KensingtonWorks, Kensington's own driver app.
//
// KensingtonWorks 2.x on macOS keeps its settings in one JSON file,
// ~/Library/Preferences/TbwSettings.json, which stays behind when it's
// uninstalled. What's known about it, and what's inferred, is in
// docs/KENSINGTONWORKS-IMPORT.md. In short:
//
//   { "devices": [ [<USB product ID>, { "<profile key>": { "name": …, "config": {…} } } ] ],
//     "versionMajor": 2, "versionMinor": 0, … }
//
// The profile "*" is the main setup; the others are per app, keyed
// "<bundle ID>-<app name>". A config's "commands" is a list of
// [<button bitmask>, { "command": …, "params": … }]: bit 0 is the bottom-left
// (primary) button, bit 1 bottom right, bit 2 top left, bit 3 top right, the
// same numbering macOS and Glideball use, and two bits together are a chord.
//
// Strictly read-only: the file is opened for reading and nothing of
// KensingtonWorks' is ever written, moved or deleted. It's treated as hostile
// input: size-capped, depth-checked, every value type-checked, every string
// cleaned, every count capped, and the result goes through the same
// `sanitizedForImport()` checks as any settings file.
//
// Foundation only, so scripts/import-sim can check it against fixtures.

struct KWCommand: Equatable {
    let mask: UInt64
    let name: String
    var keyCode: Int?
    var modifiers: String?
    var label: String?
}

struct KWConfig: Equatable {
    var speed: Double?
    var acceleration: Bool?
    var accelerationRate: Double?
    var commands: [KWCommand] = []
    var scrollInvert: Bool?
    var inertialScroll: Bool?
    var scrollLines: Double?
    var snippetsInUse = 0
    var slowModifiers = ""
    var snapModifiers = ""
    var lockedAxisModifiers = ""
}

struct KWProfile: Equatable {
    let key: String
    let name: String
    let config: KWConfig
    var isMain: Bool { key == "*" }

    /// "com.apple.Safari-Safari" → "com.apple.Safari" (the key minus "-<name>"), if that's a bundle ID.
    var bundleID: String? {
        guard !isMain else { return nil }
        var id = key
        let suffix = "-" + name
        if id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
        return ImportText.isBundleID(id) ? id : nil
    }
}

struct KWDevice: Equatable {
    let productID: Int
    let profiles: [KWProfile]
}

struct KWSettings: Equatable {
    var versionMajor: Int?
    var devices: [KWDevice]
}

enum KensingtonWorks {
    enum Problem: Error, Equatable { case missing, notAFile, tooBig, unreadable, tooDeep, notJSON, wrongShape, noDevices }

    static let maxDevices = 16
    static let maxProfiles = 100
    static let maxCommands = 64
    static let maxBytes = 2_000_000

    /// ~/Library/Preferences/TbwSettings.json, where KensingtonWorks 2 keeps everything.
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/TbwSettings.json")
    }

    /// Reads and parses the file at `url`, read-only.
    static func read(_ url: URL = settingsURL) -> Result<KWSettings, Problem> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return .failure(.missing) }
        guard !isDir.boolValue, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return .failure(.notAFile) }
        guard (values.fileSize ?? .max) <= maxBytes else { return .failure(.tooBig) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return .failure(.unreadable) }
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result<KWSettings, Problem> {
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        guard ImportJSON.depthIsWithin(data, limit: 24) else { return .failure(.tooDeep) }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let dict = root as? [String: Any], let list = dict["devices"] as? [Any] else { return .failure(.wrongShape) }
        var devices: [KWDevice] = []
        for entry in list.prefix(maxDevices) {
            guard let pair = entry as? [Any], pair.count == 2, let pid = int(pair[0]), (0...0xFFFF).contains(pid),
                  let profiles = pair[1] as? [String: Any] else { continue }
            var parsed: [KWProfile] = []
            // "*" first, then the apps in a stable order.
            for key in profiles.keys.sorted(by: { ($0 == "*" ? "" : $0) < ($1 == "*" ? "" : $1) }).prefix(maxProfiles) {
                guard key.count <= 300, let p = profiles[key] as? [String: Any], let config = p["config"] as? [String: Any] else { continue }
                let name = ImportText.clean((p["name"] as? String) ?? "")
                parsed.append(KWProfile(key: key, name: name, config: parseConfig(config)))
            }
            if !parsed.isEmpty { devices.append(KWDevice(productID: pid, profiles: parsed)) }
        }
        guard !devices.isEmpty else { return .failure(.noDevices) }
        return .success(KWSettings(versionMajor: int(dict["versionMajor"] as Any), devices: devices))
    }

    private static func parseConfig(_ c: [String: Any]) -> KWConfig {
        var k = KWConfig()
        k.speed = number(c["speed"])
        k.acceleration = bool(c["acceleration"])
        k.accelerationRate = number(c["accelerationRate"])
        k.scrollInvert = bool(c["scrollInvert"])
        k.inertialScroll = bool(c["inertialScroll"])
        k.scrollLines = number(c["scrollLines"])
        k.slowModifiers = ImportText.clean((c["slowModifiers"] as? String) ?? "", max: 40)
        k.snapModifiers = ImportText.clean((c["snapModifiers"] as? String) ?? "", max: 40)
        k.lockedAxisModifiers = ImportText.clean((c["lockedAxisModifiers"] as? String) ?? "", max: 40)
        if let snippets = c["snippets"] as? [Any] {
            k.snippetsInUse = snippets.prefix(64).filter { (($0 as? [String: Any])?["content"] as? String)?.isEmpty == false }.count
        }
        for entry in (c["commands"] as? [Any] ?? []).prefix(maxCommands) {
            guard let pair = entry as? [Any], pair.count == 2, let mask = uint64(pair[0]), mask > 0,
                  let cmd = pair[1] as? [String: Any], let rawName = cmd["command"] as? String else { continue }
            let name = String(rawName.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }.prefix(48)
                .map(Character.init))
            guard !name.isEmpty else { continue }
            var command = KWCommand(mask: mask, name: name)
            if let params = cmd["params"] as? [String: Any] {
                command.keyCode = int(params["keyCode"] as Any)
                command.modifiers = (params["modifiers"] as? String).map { ImportText.clean($0, max: 40) }
                command.label = (params["label"] as? String).map { ImportText.clean($0, max: 40) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            // One command per button (or chord): the first one wins.
            if !k.commands.contains(where: { $0.mask == mask }) { k.commands.append(command) }
        }
        return k
    }

    /// A real JSON true or false (a 1 or "true" isn't one).
    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    // JSON numbers come as NSNumber; a Bool is one too, so it's refused where a number is wanted.
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func int(_ v: Any) -> Int? {
        guard let d = number(v), d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    private static func uint64(_ v: Any) -> UInt64? {
        guard let d = number(v), d == d.rounded(), d >= 1, d <= 18_446_744_073_709_549_568 else { return nil }
        return UInt64(d)
    }
}

/// What importing KensingtonWorks' settings would do: the buttons, combos and
/// scrolling it maps to, an app setup per KensingtonWorks app profile, and,
/// in plain words, everything that has no equivalent in Glideball.
struct KensingtonWorksImport {
    struct Note: Equatable, Identifiable {
        let title: String
        let detail: String
        var id: String { title + "|" + detail }
    }

    struct Part: Equatable {
        var buttons: [Int: ButtonAction] = [:]
        var chords: [Chord] = []
        /// Inertial scrolling → Flywheel (Kensington feel); off → Native.
        var inertial: Bool?
        var reverse: Bool?
    }

    let deviceName: String
    let main: Part
    let apps: [(bundleID: String, name: String, part: Part)]
    let notes: [Note]

    static let scrollLeftMask: UInt64 = 1 << 30
    static let scrollRightMask: UInt64 = 1 << 31

    static func make(from settings: KWSettings) -> KensingtonWorksImport? {
        guard let device = settings.devices.first(where: { $0.productID == DeviceIdentity.expertMouseProductID }) ?? settings.devices.first,
              let mainProfile = device.profiles.first(where: \.isMain) ?? device.profiles.first else { return nil }
        var notes: [Note] = []
        func note(_ n: Note) { if !notes.contains(n) { notes.append(n) } }

        let main = map(mainProfile.config, isMain: true, note: note)
        var apps: [(bundleID: String, name: String, part: Part)] = []
        for p in device.profiles where !p.isMain {
            guard let id = p.bundleID else {
                note(Note(title: p.name.isEmpty ? String(localized: "An app profile", comment: "KensingtonWorks import: a per-app profile with no name") : p.name,
                          detail: String(localized: "Glideball couldn’t tell which app this profile is for, so it’s left out.", comment: "KensingtonWorks import note")))
                continue
            }
            guard apps.count < ImportLimits.maxAppSetups else { break }
            apps.append((bundleID: id, name: p.name.isEmpty ? id : p.name, part: map(p.config, isMain: false, note: note)))
        }

        let c = mainProfile.config
        if c.speed != nil || c.acceleration != nil || c.accelerationRate != nil {
            note(Note(title: String(localized: "Pointer speed and acceleration", comment: "KensingtonWorks import note title"),
                      detail: String(localized: "KensingtonWorks measures speed on its own scale, so your Glideball pointer speed stays as it is. Set it on the Pointer page.",
                                     comment: "KensingtonWorks import note")))
        }
        if let lines = c.scrollLines, (0...1000).contains(lines) {
            note(Note(title: String(localized: "Scroll speed (\(Int(lines)) lines)", comment: "KensingtonWorks import note title; %lld is KensingtonWorks' scroll speed"),
                      detail: String(localized: "Glideball scrolls in points rather than lines. Flywheel’s slow-turn distance on the Scrolling page is the nearest thing.",
                                     comment: "KensingtonWorks import note")))
        }
        if device.profiles.contains(where: { $0.config.snippetsInUse > 0 }) {
            note(Note(title: String(localized: "Text snippets", comment: "KensingtonWorks import note title"),
                      detail: String(localized: "Glideball can’t type text for you, so snippets aren’t imported.", comment: "KensingtonWorks import note")))
        }
        if !c.slowModifiers.isEmpty {
            note(Note(title: String(localized: "Slow pointer while holding a key", comment: "KensingtonWorks import note title"),
                      detail: String(localized: "Glideball’s Precision does this from a button or a keyboard shortcut instead. Set one on the Buttons page or in Settings.",
                                     comment: "KensingtonWorks import note")))
        }
        if !c.snapModifiers.isEmpty || !c.lockedAxisModifiers.isEmpty {
            note(Note(title: String(localized: "Straight-line pointer and locked scrolling", comment: "KensingtonWorks import note title"),
                      detail: String(localized: "Glideball doesn’t have these yet.", comment: "KensingtonWorks import note")))
        }
        let others = settings.devices.filter { $0 != device }
        if !others.isEmpty {
            note(Note(title: String(localized: "Other trackballs", comment: "KensingtonWorks import note title"),
                      detail: String(localized: "KensingtonWorks also has settings for another device. Only the \(deviceName(device.productID))’s are imported.",
                                     comment: "KensingtonWorks import note; %@ is a trackball's name")))
        }
        return KensingtonWorksImport(deviceName: deviceName(device.productID), main: main, apps: apps, notes: notes)
    }

    static func deviceName(_ productID: Int) -> String {
        productID == DeviceIdentity.expertMouseProductID ? "Kensington Expert Mouse"
            : String(localized: "Kensington trackball", comment: "A Kensington trackball whose model isn't known")
    }

    private static func map(_ c: KWConfig, isMain: Bool, note: (Note) -> Void) -> Part {
        var part = Part()
        part.inertial = c.inertialScroll
        part.reverse = c.scrollInvert
        for command in c.commands {
            let bits = (0..<64).filter { command.mask & (1 << UInt64($0)) != 0 }
            if command.mask == scrollLeftMask || command.mask == scrollRightMask {
                let isDefault = command.name == (command.mask == scrollLeftMask ? "navigation_scrollLeft" : "navigation_scrollRight")
                if !isDefault {
                    note(Note(title: String(localized: "Scroll left and right", comment: "KensingtonWorks import note title"),
                              detail: String(localized: "What scrolling sideways does isn’t something Glideball changes. In Glideball, hold ⇧ and turn the ring.",
                                             comment: "KensingtonWorks import note")))
                }
                continue
            }
            guard bits.allSatisfy({ $0 < 5 }) else {
                note(unknown(String(localized: "A control Glideball doesn’t know", comment: "KensingtonWorks import: a button or control with an unknown number"), command))
                continue
            }
            if bits.count == 1, let b = bits.first {
                let where_ = ImportReview.buttonName(b)
                if b == 4 {
                    if command.name != "mouse_button5Click" {
                        note(Note(title: where_, detail: String(localized: "The Expert Mouse has four buttons, so this one is left out.", comment: "KensingtonWorks import note")))
                    }
                    continue
                }
                let action = self.action(command, chord: false)
                if b == 0 {
                    if action != .leftClick {
                        note(Note(title: where_, detail: String(localized: "The bottom-left button always stays a left click in Glideball, so it can never lock you out.",
                                                               comment: "KensingtonWorks import note")))
                    }
                    continue
                }
                if let action {
                    part.buttons[b] = action
                } else {
                    note(unknown(where_, command))
                }
            } else if (2...4).contains(bits.count), bits.allSatisfy({ $0 < 4 }) {
                if command.name == "disable" { continue }   // no combo
                let title = ImportReview.comboName(bits)
                if let action = self.action(command, chord: true) {
                    part.chords.append(Chord(buttons: bits, action: action))
                } else {
                    note(unknown(title, command))
                }
            }
        }
        part.buttons = ImportSanitize.buttons(part.buttons)
        part.chords = ImportSanitize.chords(part.chords)
        return part
    }

    private static func unknown(_ title: String, _ command: KWCommand) -> Note {
        let what = command.label ?? command.name
        return Note(title: title, detail: String(localized: "“\(what)” has no equivalent in Glideball yet, so this one keeps its Glideball setting.",
                                                 comment: "KensingtonWorks import note; %@ is the KensingtonWorks action's name"))
    }

    /// The Glideball action for a KensingtonWorks command, or nil if there isn't one.
    static func action(_ c: KWCommand, chord: Bool) -> ButtonAction? {
        switch c.name {
        case "mouse_leftClick": return .leftClick
        case "mouse_rightClick": return .rightClick
        case "mouse_middleClick": return .middleClick
        case "mouse_button4Click": return .back
        case "mouse_button5Click": return .forward
        case "disable": return chord ? nil : .disabled
        case "missionControl_missionControl": return .shortcut(.missionControl)
        case "keyboard_shortcut":
            guard let code = c.keyCode, (0...127).contains(code), let mods = modifiers(c.modifiers ?? "") else { return nil }
            return KeyShortcut(keyCode: UInt16(code), modifiers: mods, keyName: keyName(code)).sanitized().map { .shortcut($0) }
        default: return nil
        }
    }

    /// "cmd", "ctrl+shift"… → CGEventFlags bits; nil if any part isn't a modifier.
    static func modifiers(_ s: String) -> UInt64? {
        var flags: CGEventFlags = []
        for word in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
            switch word {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        return flags.rawValue
    }

    /// The printed name of a Mac key code (US layout), for showing a shortcut.
    static func keyName(_ code: Int) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
            kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
            kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
            kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Quote: "'",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
            kVK_ANSI_Grave: "`", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[code] ?? "#\(code)"
    }

    /// The settings `current` would become.
    func applied(to current: GlideConfig) -> GlideConfig {
        var c = current
        func lay(_ part: Part, buttons: inout [Int: ButtonAction], chords: inout [Chord]) {
            for (b, a) in part.buttons where b != 0 { buttons[b] = a }
            for chord in part.chords {
                if let i = chords.firstIndex(where: { $0.buttons == chord.buttons }) {
                    chords[i].action = chord.action
                } else if chords.count < ImportLimits.maxChords {
                    chords.append(Chord(buttons: chord.buttons, action: chord.action))
                }
            }
        }
        func scroll(_ part: Part, into s: inout ScrollSettings) {
            if let inertial = part.inertial {
                if inertial {
                    s.scrollMode = .flywheel
                    s.flyDistance = 4; s.flyAcceleration = 0.5; s.flyGlide = 0.35; s.smoothScrolling = true   // Kensington feel
                } else {
                    s.scrollMode = .native
                }
            }
            if let reverse = part.reverse { s.reverseScroll = reverse }
        }
        lay(main, buttons: &c.buttons, chords: &c.chords)
        var s = c.scrollSettings
        scroll(main, into: &s)
        c.scrollSettings = s

        for app in apps {
            var p = c.profile(for: app.bundleID) ?? AppProfile(bundleID: app.bundleID, name: app.name)
            // An app profile in KensingtonWorks is a whole setup: buttons and combos are
            // the main ones with the app's laid over them.
            var buttons = c.buttons, chords = c.chords
            lay(app.part, buttons: &buttons, chords: &chords)
            p.buttons = buttons == c.buttons ? nil : buttons
            p.chords = chords == c.chords ? nil : chords
            if app.part.inertial != main.inertial || app.part.reverse != main.reverse {
                var appScroll = c.scrollSettings
                scroll(app.part, into: &appScroll)
                p.scroll = appScroll == c.scrollSettings ? nil : appScroll
            }
            guard let safe = ImportSanitize.appSetup(p) else { continue }
            if let i = c.appProfiles.firstIndex(where: { $0.bundleID == app.bundleID }) {
                c.appProfiles[i] = safe
            } else if c.appProfiles.count < ImportLimits.maxAppSetups {
                c.appProfiles.append(safe)
            }
        }
        c.buttons[0] = current.buttons[0]   // the primary button never changes
        return c
    }
}
