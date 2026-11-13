// Throws settings files, shared setups (files and glideball://import links) and
// KensingtonWorks settings at the real import code (ImportSafety.swift,
// SharedSetup.swift, ImportReview.swift, KensingtonWorks.swift): good ones,
// round trips of every kind, and hostile ones. Checks that nothing crashes, that
// everything that comes in is clamped and cleaned, that the primary button never
// changes, that every action that opens an app or presses keys is in the preview,
// and that KensingtonWorks' files are only ever read. Exits 1 on any failure.
// Run: scripts/import-sim/run.sh
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)   // a crash still shows how far it got
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what()) (line \(line))") }
}
func section(_ name: String) { print("▸ \(name)") }

let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/import-sim/fixtures")

/// A setup with a bit of everything, like a real one.
func sampleConfig() -> GlideConfig {
    var c = GlideConfig()
    c.trackingSpeed = 6.5
    c.scrollMode = .follow
    c.buttons = [1: .rightClick, 2: .shortcut(.copy), 3: .gesture(.standard)]
    c.chords = [Chord(buttons: [2, 3], action: .shortcut(.missionControl)), Chord(buttons: [1, 3], action: .openApp(bundleID: "com.apple.Notes"))]
    var safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
    safari.trackingSpeed = 3
    safari.buttons = [2: .back, 3: .forward]
    c.appProfiles = [safari]
    return c
}

/// Whether the settings obey every rule an import must keep.
func isSane(_ c: GlideConfig, _ what: String, primary: ButtonAction? = nil) {
    func inRange(_ v: Double, _ r: ClosedRange<Double>) -> Bool { v.isFinite && r.contains(v) }
    check(inRange(c.trackingSpeed, SettingRanges.trackingSpeed), "\(what): pointer speed \(c.trackingSpeed)")
    check(inRange(c.precisionSpeed, SettingRanges.precisionSpeed), "\(what): precision speed \(c.precisionSpeed)")
    check(inRange(c.flyDistance, SettingRanges.flyDistance) && inRange(c.flyAcceleration, SettingRanges.flyAcceleration)
          && inRange(c.flyGlide, SettingRanges.unit) && inRange(c.flyReach, SettingRanges.unit)
          && inRange(c.scrollDistance, SettingRanges.scrollDistance) && inRange(c.nativeScrollSpeed, SettingRanges.nativeScrollSpeed)
          && inRange(c.scrollSmoothness, SettingRanges.unit) && inRange(c.scrollAcceleration, SettingRanges.unit)
          && inRange(c.throwAmount, SettingRanges.unit) && inRange(c.ballScrollSpeed, SettingRanges.ballScrollSpeed), "\(what): a scroll value out of range")
    check(c.buttons[0] == primary, "\(what): the primary button became \(String(describing: c.buttons[0]))")
    check(c.chords.count <= ImportLimits.maxChords, "\(what): \(c.chords.count) combos")
    check(c.appProfiles.count <= ImportLimits.maxAppSetups, "\(what): \(c.appProfiles.count) app setups")
    for p in c.appProfiles {
        check(ImportText.isBundleID(p.bundleID), "\(what): app setup with bundle ID \(p.bundleID.debugDescription)")
        check(p.name.count <= ImportLimits.maxNameLength && !p.name.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format },
              "\(what): app setup name \(p.name.debugDescription)")
        check(p.buttons?[0] == nil, "\(what): an app setup sets the primary button")
        if let s = p.trackingSpeed { check(inRange(s, SettingRanges.trackingSpeed), "\(what): app setup speed \(s)") }
    }
    func actionOK(_ a: ButtonAction, nested: Bool = false) -> Bool {
        switch a {
        case .shortcut(let s), .holdShortcut(let s):
            return s.keyCode <= 127 && s.modifiers & ~KeyShortcut.allowedModifiers == 0 && s.keyName.count <= ImportLimits.maxKeyNameLength
        case .openApp(let id): return ImportText.isBundleID(id)
        case .modifiedClick(let b, _): return (0...4).contains(b)
        case .gesture(let g):
            return !nested && GestureDirection.allCases.allSatisfy { g[$0].map { actionOK($0.action, nested: true) } ?? true } && actionOK(g.tap, nested: true)
        default: return true
        }
    }
    let all = Array(c.buttons.values) + c.chords.map(\.action) + c.appProfiles.flatMap { Array(($0.buttons ?? [:]).values) + ($0.chords ?? []).map(\.action) }
    check(all.allSatisfy { actionOK($0) }, "\(what): an action that isn't safe")
    for chord in c.chords + c.appProfiles.flatMap({ $0.chords ?? [] }) {
        check((2...4).contains(chord.buttons.count) && chord.buttons.allSatisfy { ImportLimits.chordButtons.contains($0) } && chord.buttons == chord.buttons.sorted(),
              "\(what): combo \(chord.buttons)")
    }
}

/// Every new action that opens an app or presses keys is on the preview list, marked.
func cautionListed(_ old: GlideConfig, _ new: GlideConfig, _ what: String) {
    let changes = ImportReview.changes(from: old, to: new)
    for (b, a) in new.buttons where a.needsCaution && !(old.buttons[b] ?? .system).sameEffect(as: a, on: b) {
        check(changes.contains { $0.caution && $0.title == ImportReview.buttonName(b) && $0.after == ImportReview.describe(a, on: b) },
              "\(what): \(ImportReview.buttonName(b)) → \(ImportReview.describe(a)) isn't listed")
    }
    for c in new.chords where c.action.needsCaution && old.chords.first(where: { $0.buttons == c.buttons })?.action != c.action {
        check(changes.contains { $0.caution && $0.title == ImportReview.comboName(c.buttons) }, "\(what): combo \(c.buttons) isn't listed")
    }
    for p in new.appProfiles {
        for (b, a) in p.buttons ?? [:] where a.needsCaution {
            let before = old.profile(for: p.bundleID)?.buttons?[b] ?? old.buttons[b] ?? .system
            if before.sameEffect(as: a, on: b) { continue }
            check(changes.contains { $0.caution && $0.title == "\(p.name) · \(ImportReview.buttonName(b))" }, "\(what): \(p.name)'s \(b) isn't listed")
        }
    }
}

func link(_ d: String) -> String { "glideball://import?d=" + d }
func packed(_ json: String) -> String { SharedSetup.base64url(SharedSetup.deflate(Data(json.utf8))!) }

// MARK: - Shared setups: every kind, round trip

section("Sharing: every kind, as a file and a link")
let mine = sampleConfig()
var theirs = GlideConfig()
theirs.buttons = [2: .middleClick]
for kind in ShareKind.allCases {
    let look = ShareLook(theme: "sunset", custom: nil)
    guard let share = SharedSetup.make(kind, from: mine, look: look, appSetup: "com.apple.Safari", writtenBy: "2.10") else {
        check(false, "\(kind): couldn't make a share"); continue
    }
    let viaFile = try? SharedSetup.decode(file: share.fileData())
    check(viaFile != nil, "\(kind): the file doesn't read back")
    guard let url = share.link() else { check(false, "\(kind): no link"); continue }
    check(url.absoluteString.count <= SharedSetup.maxLinkLength, "\(kind): link is \(url.absoluteString.count) characters")
    check(url.absoluteString.hasPrefix(SharedSetup.webPrefix), "\(kind): Copy Link isn't the website's link")
    let d = url.fragment ?? ""
    let appD = share.appLink().flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value }
    check(appD == d, "\(kind): the website link and the glideball:// link carry different payloads")
    guard let viaLink = try? SharedSetup.decode(linkPayload: d) else { check(false, "\(kind): the link doesn't read back"); continue }
    for (how, got) in [("file", viaFile), ("link", viaLink)] {
        guard let got else { continue }
        let a = got.applied(to: theirs), b = share.applied(to: theirs)
        check(a == b || (a.chords.map(\.buttons) == b.chords.map(\.buttons) && a.chords.map(\.action) == b.chords.map(\.action)), "\(kind) via \(how): applies differently")
        isSane(a, "\(kind) via \(how)")
        cautionListed(theirs, a, "\(kind) via \(how)")
    }
    switch kind {
    case .pointer:
        check(viaLink.applied(to: theirs).trackingSpeed == 6.5 && viaLink.applied(to: theirs).buttons == theirs.buttons, "pointer: changed more than the pointer")
    case .scrolling:
        check(viaLink.applied(to: theirs).scrollMode == .follow && viaLink.applied(to: theirs).trackingSpeed == theirs.trackingSpeed, "scrolling: changed more than scrolling")
    case .buttons:
        let a = viaLink.applied(to: theirs)
        check(a.buttons[2] == .shortcut(.copy) && a.chords.count == 2 && a.trackingSpeed == theirs.trackingSpeed, "buttons: wrong buttons or more than buttons")
        check(viaLink.version == 2, "buttons with a gesture and Open an app: version \(viaLink.version), not 2")
    case .appSetup:
        let a = viaLink.applied(to: theirs)
        check(a.appProfiles.map(\.bundleID) == ["com.apple.Safari"] && a.buttons == theirs.buttons, "app setup: wrong result")
        check(viaLink.version == 1, "a plain app setup: version \(viaLink.version), not 1")
    case .look:
        check(viaLink.appliedLook == look && viaLink.applied(to: theirs) == theirs, "look: changed settings or lost the color")
    case .everything:
        var withShortcut = theirs
        withShortcut.globalShortcuts.precision = KeyShortcut.make(1, "S", [.maskCommand, .maskAlternate])
        withShortcut.enabled = false
        let a = viaLink.applied(to: withShortcut)
        check(a.globalShortcuts == withShortcut.globalShortcuts && !a.enabled && a.displaySpeeds == withShortcut.displaySpeeds,
              "everything: took over this Mac's shortcuts, pause switch or displays")
        check(a.appProfiles.count == 1 && a.trackingSpeed == 6.5, "everything: lost something")
    }
}
let plain = SharedSetup.make(.pointer, from: GlideConfig(), look: nil)!
check(plain.version == 1, "a plain pointer share is version \(plain.version)")
check(String(data: try! plain.fileData(), encoding: .utf8)!.contains("exportedFrom") == false, "a share names the Mac it came from")

// MARK: - Checklist shares (several parts, a name, leaving parts out)

section("Checklist shares: any mix of parts, each applied on its own")
var rich = sampleConfig()
rich.displaySpeeds.enabled = true
rich.displaySpeeds.speeds = ["1552-41234-0": 8]
rich.displaySpeeds.names = ["1552-41234-0": "LG UltraFine"]
rich.gestureDistance = .short
var notes = AppProfile(bundleID: "com.apple.Notes", name: "Notes")
notes.trackingSpeed = 2
rich.appProfiles.append(notes)
let richSounds = ShareSounds(on: false, volume: 0.4, kinds: ["ticks": false, "milestones": true, "bogus": true])
let allParts: [SharePart] = [.pointer, .displays, .scrolling, .buttons, .combos, .gestures, .app("com.apple.Safari"), .app("com.apple.Notes"), .look, .sounds]
let full = SharedSetup.make(allParts, from: rich, look: ShareLook(theme: "custom", custom: ["ffe070", "2EC99A", "2B3A9E"]),
                            sounds: richSounds, name: "  \u{202E}Levi\u{0007}  ", writtenBy: "2.10-beta.13")!
check(full.parts == allParts, "parts: \(full.parts.map(\.id))")
check(full.from == "Levi", "the name wasn't cleaned: \(String(describing: full.from))")
check(full.version == 2, "gestures and displays: version \(full.version)")
check(full.buttons?[3]?.isGesture == true && full.buttons?[1] == .rightClick && full.buttons?[7] == .system, "buttons: \(String(describing: full.buttons))")
if let d = full.payload, let back = try? SharedSetup.decode(linkPayload: d) {
    check(back.parts == full.parts && back.from == "Levi" && back.sounds == full.sounds && back.look?.custom == ["FFE070", "2EC99A", "2B3A9E"],
          "the link doesn't read back the same")
    check(full.link()?.absoluteString.hasPrefix(SharedSetup.webPrefix) == true, "the link isn't the website's")
    check(full.appLink()?.absoluteString == SharedSetup.appPrefix + d, "the glideball:// link has another payload")
    check(back.appliedSounds()?.kinds["bogus"] == nil, "an unknown sound kind got through")
    // Each part alone changes only its own settings.
    for part in back.parts {
        let a = back.applied(to: theirs, parts: [part])
        isSane(a, "only \(part.id)")
        var expect = theirs
        switch part {
        case .pointer: expect.trackingSpeed = rich.trackingSpeed; expect.precisionSpeed = rich.precisionSpeed
        case .displays: expect.displaySpeeds = rich.displaySpeeds
        case .scrolling: expect.scrollSettings = rich.scrollSettings; expect.ballScrollSpeed = rich.ballScrollSpeed
        case .buttons:
            expect.buttons = [1: .rightClick, 2: .shortcut(.copy)]   // button 3 is a gesture: not this part
        case .combos: expect.chords = rich.chords
        case .gestures:
            expect.buttons[3] = rich.buttons[3]
            expect.gesturesEnabled = rich.gesturesEnabled; expect.gestureDistance = .short; expect.gestureSteadyHands = rich.gestureSteadyHands
        case .app(let id): expect.appProfiles = [rich.profile(for: id)!]
        case .look, .sounds: break
        }
        check(a.trackingSpeed == expect.trackingSpeed && a.scrollSettings == expect.scrollSettings && a.buttons == expect.buttons
              && a.chords.map(\.buttons) == expect.chords.map(\.buttons) && a.appProfiles.map(\.bundleID) == expect.appProfiles.map(\.bundleID)
              && a.displaySpeeds == expect.displaySpeeds && a.gestureDistance == expect.gestureDistance,
              "only \(part.id) changed something else")
        cautionListed(theirs, a, "only \(part.id)")
        check(back.appliedLook(parts: [part]) == (part == .look ? back.look : nil), "only \(part.id): the look")
        check(back.appliedSounds(parts: [part]) == (part == .sounds ? richSounds.sanitized : nil), "only \(part.id): the sounds")
    }
    check(back.applied(to: theirs, parts: []) == theirs.clamped(), "no parts ticked still changed something")
    // Another Mac's app setups stay when one comes in.
    var mine2 = theirs
    mine2.appProfiles = [AppProfile(bundleID: "com.example.mine", name: "Mine")]
    check(back.applied(to: mine2, parts: [.app("com.apple.Notes")]).appProfiles.map(\.bundleID) == ["com.example.mine", "com.apple.Notes"],
          "an incoming app setup replaced the others")
} else {
    check(false, "the full checklist share doesn't read back")
}
check(SharedSetup.make([.displays], from: GlideConfig(), look: nil, sounds: nil) == nil, "a share of nothing (no displays) was made")
check(SharedSetup.make([.look], from: rich, look: nil, sounds: nil) == nil, "a look share without a look was made")
let quiet = SharedSetup.make([.pointer], from: rich, look: nil, sounds: nil, name: "   ")!
check(quiet.from == nil && !String(data: try! quiet.fileData(), encoding: .utf8)!.contains("\"from\""), "an empty name went into the share")
// Too long for a link: file only, and it says by how much.
var huge = rich
huge.appProfiles = (0..<40).map { i in
    var p = AppProfile(bundleID: "com.example.\(UUID().uuidString)", name: "App \(UUID().uuidString)")
    p.trackingSpeed = Double(i) + 0.5; p.scroll = rich.scrollSettings; p.buttons = [2: .shortcut(.copy), 3: .openApp(bundleID: "com.example.other\(i)")]
    return p
}
let tooBig = SharedSetup.make([.pointer] + huge.appProfiles.map { .app($0.bundleID) }, from: huge, look: nil, sounds: nil)!
check(tooBig.link() == nil && tooBig.appLink() == nil && tooBig.linkLength > SharedSetup.maxLinkLength, "a share too long for a link got one")
check((try? SharedSetup.decode(file: tooBig.fileData()))?.parts.count == 41, "a big share doesn't read back from its file")

// MARK: - The format, both ways: fixtures shared with the website (docs/SHARE-FORMAT.md)

section("Shared fixtures: what the website reads, the app reads the same way")
let shareFixtures = URL(fileURLWithPath: "website/tests/fixtures/share")

/// What a fixture's `expect` compares (see website/tests/share-page.test.mjs).
func expectation(_ s: SharedSetup) -> [String: Any] {
    var e: [String: Any] = ["parts": s.parts.map(\.id), "from": s.from ?? NSNull()]
    if s.parts.contains(.pointer), let v = s.trackingSpeed { e["trackingSpeed"] = v.clamped(to: SettingRanges.trackingSpeed, or: 4) }
    if s.parts.contains(.scrolling), let m = s.scroll?.scrollMode { e["scrollMode"] = m.rawValue }
    if s.parts.contains(.look), let t = s.look?.theme { e["theme"] = t }
    let apps = s.parts.compactMap(\.bundleID)
    if !apps.isEmpty { e["apps"] = apps }
    if s.parts.contains(.buttons) || s.parts.contains(.gestures) {
        var kinds: [String: String] = [:]
        for (b, raw) in s.buttons ?? [:] where s.parts.contains(raw.isGesture ? .gestures : .buttons) {
            guard let a = raw.sanitized(), let data = try? JSONEncoder().encode(a),
                  let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.first else { continue }
            kinds[String(b)] = key
        }
        e["buttons"] = kinds
    }
    return e
}

func same(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let x as NSNull, _): return b == nil || b is NSNull || x == (b as? NSNull)
    case (_, let y as NSNull): return a == nil || y == (a as? NSNull)
    case (let x as NSNumber, let y as NSNumber): return x.doubleValue == y.doubleValue
    case (let x as String, let y as String): return x == y
    case (let x as [Any], let y as [Any]): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
    case (let x as [String: Any], let y as [String: Any]): return Set(x.keys) == Set(y.keys) && x.allSatisfy { same($0.value, y[$0.key]) }
    default: return false
    }
}

func checkFixtures(_ name: String) -> Int {
    guard let data = try? Data(contentsOf: shareFixtures.appendingPathComponent(name)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cases = root["cases"] as? [[String: Any]] else {
        check(false, "\(name): missing or unreadable"); return 0
    }
    for c in cases {
        let what = "\(name): \(c["name"] as? String ?? "?")"
        let d = c["d"] as? String ?? ""
        let got = try? SharedSetup.decode(linkPayload: d)
        if c["refuse"] as? Bool == true {
            check(got == nil, "\(what): accepted, but the website refuses it")
            continue
        }
        guard let got else { check(false, "\(what): refused, but the website reads it"); continue }
        let mine = expectation(got)
        for (key, want) in (c["expect"] as? [String: Any]) ?? [:] {
            check(same(mine[key], want), "\(what): \(key) is \(String(describing: mine[key])), the website says \(want)")
        }
        isSane(got.applied(to: theirs), what)
    }
    return cases.count
}

if let i = CommandLine.arguments.firstIndex(of: "--write-fixtures") {
    // Payloads made by the app's own code, for the website's tests to read.
    let out = i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : shareFixtures.appendingPathComponent("swift-made.json")
    var cases: [[String: Any]] = []
    func add(_ name: String, _ s: SharedSetup?) {
        guard let s, let d = s.payload else { check(false, "fixture \(name): couldn't make it"); return }
        let back = try! SharedSetup.decode(linkPayload: d)
        cases.append(["name": name, "d": d, "expect": expectation(back)])
    }
    func legacy(_ name: String, _ json: String) {
        let d = packed(json)
        guard let back = try? SharedSetup.decode(linkPayload: d) else { check(false, "fixture \(name): doesn't read"); return }
        cases.append(["name": name, "d": d, "expect": expectation(back)])
    }
    add("everything, named, custom color", full)
    add("pointer only", SharedSetup.make([.pointer], from: rich, look: nil, sounds: nil))
    add("scroll feel, follow", SharedSetup.make([.scrolling], from: rich, look: nil, sounds: nil))
    add("buttons without gestures", SharedSetup.make([.buttons], from: rich, look: nil, sounds: nil))
    add("gestures only", SharedSetup.make([.gestures], from: rich, look: nil, sounds: nil))
    add("combos", SharedSetup.make([.combos], from: rich, look: nil, sounds: nil))
    add("two app setups", SharedSetup.make([.app("com.apple.Notes"), .app("com.apple.Safari")], from: rich, look: nil, sounds: nil))
    add("ball color, sunset", SharedSetup.make([.look], from: rich, look: ShareLook(theme: "sunset", custom: nil), sounds: nil))
    add("sounds", SharedSetup.make([.sounds], from: rich, look: nil, sounds: richSounds))
    add("per-display speeds", SharedSetup.make([.displays], from: rich, look: nil, sounds: nil))
    add("a name with an emoji", SharedSetup.make([.pointer, .look], from: rich, look: ShareLook(theme: "ocean", custom: nil), sounds: nil, name: "Zoë 🎱"))
    add("a name with markup", SharedSetup.make([.pointer], from: rich, look: nil, sounds: nil, name: "<img src=x onerror=alert(1)>"))
    legacy("beta 12: scroll feel", #"{"format":"glideball-share","version":1,"kind":"scrolling","scroll":{"scrollMode":"follow","scrollDistance":22},"ballScrollSpeed":1,"writtenBy":"2.10-beta.12"}"#)
    legacy("beta 12: buttons", #"{"format":"glideball-share","version":2,"kind":"buttons","buttons":{"2":{"shortcut":{"_0":{"keyCode":8,"modifiers":1048576,"keyName":"C"}}},"3":{"gesture":{"_0":{"up":{"action":{"media":{"_0":0}},"repeats":true},"tap":{"system":{}}}}}},"chords":[{"buttons":[2,3],"action":{"openApp":{"bundleID":"com.apple.Notes"}}}],"gesturesEnabled":true}"#)
    legacy("beta 12: app setup", #"{"format":"glideball-share","version":1,"kind":"app-setup","name":"Xcode","appSetup":{"bundleID":"com.apple.dt.Xcode","name":"Xcode","trackingSpeed":3.5}}"#)
    if let old = SharedSetup.make(.everything, from: rich, look: nil), let config = try? JSONEncoder().encode(rich) {
        _ = old
        legacy("beta 12: everything", #"{"format":"glideball-share","version":2,"kind":"everything","look":{"theme":"classic"},"config":"#
               + String(decoding: config, as: UTF8.self) + "}")
    }
    let note = "Made by scripts/import-sim/run.sh --write-fixtures (docs/SHARE-FORMAT.md). Do not edit by hand."
    let json = try! JSONSerialization.data(withJSONObject: ["note": note, "cases": cases], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! (json + Data("\n".utf8)).write(to: out)
    print("  wrote \(cases.count) cases to \(out.path)")
}
var fixtureCount = 0
for name in ["js-made.json", "hostile.json", "swift-made.json"] { fixtureCount += checkFixtures(name) }
print("  \(fixtureCount) shared fixtures read the same as on the website")

// MARK: - Hostile links

section("Hostile links: nothing gets through unchecked")
let bomb = SharedSetup.base64url(SharedSetup.deflate(Data(repeating: 0x20, count: 2_000_000))!)
var hostile: [(String, String)] = [
    ("empty", ""),
    ("not base64", "!!!!"),
    ("spaces", "abc def"),
    ("percent tricks", "%41%42"),
    ("padding", "AAAA===="),
    ("too long", String(repeating: "A", count: 5000)),
    ("not deflate", SharedSetup.base64url(Data("hello".utf8))),
    ("deflate bomb (2 MB of spaces)", bomb),
    ("JSON but not a share", packed("{\"hello\":1}")),
    ("a plain settings file", packed("{\"version\":1,\"config\":{}}")),
    ("wrong marker", packed("{\"format\":\"evil\",\"version\":1,\"kind\":\"pointer\",\"trackingSpeed\":5}")),
    ("version 99", packed("{\"format\":\"glideball-share\",\"version\":99,\"kind\":\"pointer\",\"trackingSpeed\":5}")),
    ("version 0", packed("{\"format\":\"glideball-share\",\"version\":0,\"kind\":\"pointer\",\"trackingSpeed\":5}")),
    ("unknown kind", packed("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"delete-everything\"}")),
    ("kind without its part", packed("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"scrolling\"}")),
    ("app setup with a bad bundle ID", packed("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"app-setup\",\"appSetup\":{\"bundleID\":\"../../evil\",\"name\":\"x\"}}")),
    ("look with an unknown color", packed("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"look\",\"look\":{\"theme\":\"; rm -rf ~\"}}")),
    ("deep nesting", packed(String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000))),
    ("deep gesture nesting", packed("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"buttons\",\"buttons\":{\"2\":"
                                    + String(repeating: "{\"gesture\":{\"_0\":{\"tap\":", count: 300) + "{\"leftClick\":{}}"
                                    + String(repeating: "}}}", count: 300) + "}}")),
    ("NUL bytes", packed("{\"format\":\"glideball-share\u{0}\",\"version\":1}")),
]
for (what, d) in hostile {
    check((try? SharedSetup.decode(linkPayload: d)) == nil, "\(what): accepted")
}

// Values that parse, but must be clamped, cleaned or dropped.
let nasty = """
{"format":"glideball-share","version":1,"kind":"everything","unknownField":{"a":[1,2,3]},
 "config":{"trackingSpeed":1e308,"precisionSpeed":-5,"flyDistance":-1e30,"flyGlide":42,"scrollDistance":0,"nativeScrollSpeed":9e9,
  "ballScrollSpeed":-0.0,"enabled":false,
  "buttons":{"0":{"rightClick":{}},"1":{"openApp":{"bundleID":"../../../bin/sh"}},"2":{"shortcut":{"_0":{"keyCode":60000,"modifiers":18446744073709551615,"keyName":"x"}}},
             "3":{"shortcut":{"_0":{"keyCode":12,"modifiers":18446744073709551615,"keyName":"\\u202Eevil\\u0007name-that-is-long"}}},"99":{"leftClick":{}},"-1":{"leftClick":{}}},
  "chords":[{"id":"00000000-0000-0000-0000-000000000000","buttons":[0,1,2,3,4,5,6,7,8],"action":{"leftClick":{}}},
            {"id":"00000000-0000-0000-0000-000000000000","buttons":[1,1],"action":{"leftClick":{}}},
            {"id":"00000000-0000-0000-0000-000000000000","buttons":[2,3],"action":{"openApp":{"bundleID":"com.evil.app"}}},
            {"id":"00000000-0000-0000-0000-000000000000","buttons":[3,2],"action":{"rightClick":{}}}],
  "appProfiles":[{"bundleID":"com.apple.Safari","name":"\\u202Esafari\\u0000\\n\\u200Bname","trackingSpeed":-3,"buttons":{"0":{"disabled":{}}}},
                 {"bundleID":"com.apple.Safari","name":"duplicate"},{"bundleID":"","name":"x"},{"bundleID":"a b","name":"x"}],
  "globalShortcuts":{"pause":{"keyCode":1,"modifiers":0,"keyName":"S"}}}}
"""
if let s = try? SharedSetup.decode(json: Data(nasty.utf8)) {
    let a = s.applied(to: theirs)
    isSane(a, "hostile everything")
    check(a.buttons[1] == nil || a.buttons[1] == .system, "an Open with a path got through: \(String(describing: a.buttons[1]))")
    check(a.buttons[2] == nil, "a shortcut with key code 60000 got through")
    if case .shortcut(let sc)? = a.buttons[3] {
        check(sc.modifiers == KeyShortcut.allowedModifiers && !sc.keyName.contains("\u{202E}"), "shortcut modifiers or name not cleaned: \(sc)")
    } else { check(false, "a fixable shortcut was dropped") }
    check(a.chords.map(\.buttons) == [[2, 3]], "combos: \(a.chords.map(\.buttons)) (a bad one got in, or a duplicate)")
    check(a.appProfiles.count == 1 && a.appProfiles[0].name == "safariname", "app setups: \(a.appProfiles.map { $0.name.debugDescription })")
    check(a.enabled == theirs.enabled && a.globalShortcuts == theirs.globalShortcuts, "the pause switch or shortcuts came from a share")
    cautionListed(theirs, a, "hostile everything")
    let changes = ImportReview.changes(from: theirs, to: a)
    check(changes.contains { $0.caution && $0.title == ImportReview.comboName([2, 3]) && $0.after?.contains("com.evil.app") == true },
          "the combo that opens an app doesn't name the app's bundle ID")
} else {
    check(false, "a share with fixable values was refused outright")
}

// Unknown fields and a button from a newer version are skipped, not fatal.
let newer = """
{"format":"glideball-share","version":2,"kind":"buttons","futureThing":true,"buttons":{"2":{"teleport":{}},"3":{"middleClick":{}}},"chords":[{"buttons":[2,3],"action":{"teleport":{}}}]}
"""
if let s = try? SharedSetup.decode(json: Data(newer.utf8)) {
    let a = s.applied(to: theirs)
    check(a.buttons[3] == .middleClick && a.buttons[2] == nil && a.chords.isEmpty, "newer actions: \(a.buttons) \(a.chords)")
} else { check(false, "a newer share with one unknown action was refused") }

// Primary button: never, from any kind.
for kind in [ShareKind.buttons, .everything, .appSetup] {
    var evil = GlideConfig()
    evil.buttons = [0: .disabled, 2: .middleClick]
    var p = AppProfile(bundleID: "com.example.x", name: "X")
    p.buttons = [0: .disabled]
    evil.appProfiles = [p]
    var share = SharedSetup.make(kind, from: evil, look: nil, appSetup: "com.example.x")!
    share.buttons?[0] = .disabled
    let a = share.applied(to: theirs)
    check(a.buttons[0] == nil && a.appProfiles.allSatisfy { $0.buttons?[0] == nil }, "\(kind): the primary button changed")
}

// MARK: - Settings files (the plain import)

section("Settings files: the same checks")
if let file = try? JSONDecoder().decode(GlideSettingsFile.self, from: Data(nasty.utf8).dropFirst(0)) {
    _ = file   // a share isn't a settings file…
}
let plainFile = String(nasty.drop(while: { $0 != "\"" }))   // …but its config is a hostile settings file's
if let range = nasty.range(of: "\"config\":") {
    var body = String(nasty[range.upperBound...])
    body.removeLast(1)   // the share's closing brace
    let json = "{\"version\":1,\"config\":" + body + "}"
    if let file = try? JSONDecoder().decode(GlideSettingsFile.self, from: Data(json.utf8)), let c = try? file.validatedConfig() {
        isSane(c.sanitizedForImport(), "hostile settings file")
        check(c.sanitizedForImport().globalShortcuts.pause == GlobalShortcuts.defaultPause, "a pause shortcut with no modifier got through")
    } else {
        check(false, "the hostile settings file didn't parse at all (the test is wrong)")
    }
}
_ = plainFile
check(!ImportJSON.depthIsWithin(Data((String(repeating: "[", count: 40) + String(repeating: "]", count: 40)).utf8)), "depth 40 passed")
check(ImportJSON.depthIsWithin(Data("{\"a\":\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"}".utf8)), "brackets inside a string counted")
check(ImportJSON.depthIsWithin(Data("{\"a\":\"\\\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"}".utf8)), "an escaped quote confused the depth check")

// MARK: - KensingtonWorks

section("KensingtonWorks: the real file's shape")
func kw(_ name: String) -> KWSettings? {
    if case .success(let s) = KensingtonWorks.read(fixtures.appendingPathComponent(name)) { return s }
    return nil
}
if let s = kw("TbwSettings-expert-mouse.json"), let imp = KensingtonWorksImport.make(from: s) {
    check(imp.deviceName == "Kensington Expert Mouse", "device: \(imp.deviceName)")
    check(imp.main.buttons[1] == .shortcut(.missionControl), "bottom right: \(String(describing: imp.main.buttons[1]))")
    check(imp.main.buttons[3] == .disabled, "top right: \(String(describing: imp.main.buttons[3]))")
    check(imp.main.buttons[2] == .leftClick, "top left: \(String(describing: imp.main.buttons[2]))")
    check(imp.main.chords.contains { $0.buttons == [0, 2] } && imp.main.chords.contains { $0.buttons == [1, 3] }, "chords: \(imp.main.chords.map(\.buttons))")
    check(!imp.main.chords.contains { $0.buttons == [0, 1] || $0.buttons == [2, 3] }, "a disabled chord became a combo")
    check(imp.main.inertial == true && imp.main.reverse == false, "scrolling: \(String(describing: imp.main.inertial)) \(String(describing: imp.main.reverse))")
    check(imp.apps.map(\.bundleID) == ["com.example.editor"] && imp.apps.first?.name == "Editor", "apps: \(imp.apps.map(\.bundleID))")
    check(imp.notes.contains { $0.title.contains("Pointer speed") }, "no note about pointer speed")
    let a = imp.applied(to: theirs)
    isSane(a, "KensingtonWorks import")
    check(a.scrollMode == .flywheel && a.flyGlide == 0.35, "inertial scrolling didn't become Flywheel with Kensington feel")
    check(a.trackingSpeed == theirs.trackingSpeed, "pointer speed changed (it has no equivalent)")
    let editor = a.profile(for: "com.example.editor")
    check(editor?.buttons?[3] == .rightClick && editor?.buttons?[1] == .rightClick, "Editor's buttons: \(String(describing: editor?.buttons))")
    if case .shortcut(let sc)? = editor?.buttons?[2] {
        check(sc.keyCode == 15 && sc.modifiers == CGEventFlags.maskCommand.rawValue && sc.keyName == "R", "Editor's top left: \(sc.display)")
    } else { check(false, "Editor's top left isn't ⌘R") }
    cautionListed(theirs, a, "KensingtonWorks import")
    check(imp.applied(to: a) == a || imp.applied(to: a).appProfiles.count == a.appProfiles.count, "importing twice adds app setups twice")
} else {
    check(false, "the Expert Mouse fixture didn't import")
}

section("KensingtonWorks: two devices, odd keys, things with no equivalent")
if let s = kw("TbwSettings-two-devices.json"), let imp = KensingtonWorksImport.make(from: s) {
    check(imp.deviceName == "Kensington Expert Mouse", "picked \(imp.deviceName), not the Expert Mouse")
    check(imp.apps.isEmpty, "apps with odd keys got in: \(imp.apps.map(\.bundleID))")
    check(imp.main.buttons[2] == .middleClick && imp.main.buttons[3] == .back, "stock buttons: \(imp.main.buttons)")
    check(imp.main.inertial == false && imp.main.reverse == true, "scrolling not read")
    check(imp.notes.contains { $0.detail.contains("Calculator") }, "launching an app isn't explained")
    check(imp.notes.contains { $0.title == ImportReview.comboName([2, 3]) }, "the unknown combo's note doesn't say which combo")
    check(!imp.notes.contains { $0.title.contains("secret") || $0.detail.contains("secret") }, "a snippet's text is shown")
    check(imp.notes.contains { $0.detail.contains("another device") }, "the other device isn't mentioned")
    let a = imp.applied(to: theirs)
    isSane(a, "two devices")
    check(a.scrollMode == .native && a.reverseScroll, "non-inertial scrolling didn't become Native + reversed")
} else {
    check(false, "the two-device fixture didn't import")
}

section("KensingtonWorks: hostile files")
let hostileKW: [(String, String)] = [
    ("empty", ""),
    ("not JSON", "hello"),
    ("array root", "[1,2,3]"),
    ("no devices", "{\"devices\":[]}"),
    ("devices not a list", "{\"devices\":{\"a\":1}}"),
    ("device not a pair", "{\"devices\":[[4128]]}"),
    ("product ID a string", "{\"devices\":[[\"4128\",{\"*\":{\"config\":{}}}]]}"),
    ("product ID huge", "{\"devices\":[[1e300,{\"*\":{\"config\":{}}}]]}"),
    ("a number JSON can't hold", "{\"devices\":[[4128,{\"*\":{\"config\":{\"speed\":1e400}}}]]}"),
    ("product ID a bool", "{\"devices\":[[true,{\"*\":{\"config\":{}}}]]}"),
    ("deep", "{\"devices\":" + String(repeating: "[", count: 3000) + String(repeating: "]", count: 3000) + "}"),
]
for (what, text) in hostileKW {
    if case .success = KensingtonWorks.parse(Data(text.utf8)) { check(false, "\(what): accepted") }
}
// Parses, but every value is wrong: nothing unsafe comes out.
let weird = """
{"devices":[[4128,{"*":{"name":"\\u202E*","config":{"speed":"fast","acceleration":"yes","scrollInvert":1,"inertialScroll":"true","scrollLines":1e300,
  "commands":[[0,{"command":"mouse_rightClick"}],[-1,{"command":"mouse_rightClick"}],[1e300,{"command":"mouse_rightClick"}],[true,{"command":"mouse_rightClick"}],
    [1,{"command":"keyboard_shortcut","params":{"keyCode":8,"modifiers":"cmd"}}],
    [2,{"command":"keyboard_shortcut","params":{"keyCode":99999,"modifiers":"cmd"}}],
    [2,{"command":"mouse_middleClick"}],
    [4,{"command":"keyboard_shortcut","params":{"keyCode":8,"modifiers":"cmd; rm -rf ~"}}],
    [8,{"command":"../../../etc/passwd\\u0000"}],
    [3,{"command":42}],[16,{"command":"mouse_leftClick"}],[32,{"command":"mouse_leftClick"}],[1073741824,{"command":"launch"}],
    [6,{"command":"keyboard_shortcut","params":{"keyCode":-4,"modifiers":"shift"}}]],
  "snippets":"not a list","slowModifiers":12}},
 "com.ok.app-App":{"name":"App","config":{"commands":[[2,{"command":"keyboard_shortcut","params":{"keyCode":9,"modifiers":"ctrl+shift","label":"\\u0007Paste"}}]]}},
 "noconfig":{"name":"x"},"com.ok.two-":{"name":"","config":{}}}]]}
"""
switch KensingtonWorks.parse(Data(weird.utf8)) {
case .failure(let p): check(false, "a weird but readable file was refused: \(p)")
case .success(let s):
    guard let imp = KensingtonWorksImport.make(from: s) else { check(false, "no import from the weird file"); break }
    check(imp.main.buttons[0] == nil, "the primary button got an action")
    check(imp.main.buttons[1] == .middleClick || imp.main.buttons[1] == nil, "bottom right: \(String(describing: imp.main.buttons[1]))")
    check(imp.main.buttons[2] == nil, "a shortcut with odd modifiers got in: \(String(describing: imp.main.buttons[2]))")
    check(imp.main.inertial == nil && imp.main.reverse == nil, "a string or number was read as a switch")
    check(imp.notes.contains { $0.title == ImportReview.buttonName(0) }, "no note that the primary button stays a left click")
    check(imp.apps.map(\.bundleID).sorted() == ["com.ok.app", "com.ok.two"], "apps: \(imp.apps.map(\.bundleID))")
    if case .shortcut(let sc)? = imp.apps.first(where: { $0.bundleID == "com.ok.app" })?.part.buttons[1] {
        check(sc.modifiers == (CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue) && sc.keyName == "V", "⌃⇧V read as \(sc.display)")
    } else { check(false, "the app's ⌃⇧V wasn't read") }
    let a = imp.applied(to: theirs)
    isSane(a, "weird KensingtonWorks file")
    cautionListed(theirs, a, "weird KensingtonWorks file")
    for n in imp.notes {
        check(!n.title.unicodeScalars.contains { $0.properties.generalCategory == .control } && !n.detail.contains("\u{0}"), "a note carries a control character")
    }
}

section("Fuzz: 3,000 mangled shares and KensingtonWorks files")
struct SplitMix { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
var rng = SplitMix(s: 42)
let seeds: [Data] = [try! SharedSetup.make(.everything, from: mine, look: nil)!.fileData(), try! SharedSetup.make(.buttons, from: mine, look: nil)!.fileData(),
                     (try? Data(contentsOf: fixtures.appendingPathComponent("TbwSettings-expert-mouse.json"))) ?? Data()]
let alphabet = Array("{}[]\":,0123456789-.e truefalsnul\\u202E".utf8)
var survived = 0
for i in 0..<3000 {
    var d = seeds[i % seeds.count]
    for _ in 0..<(1 + Int(rng.next() % 6)) where !d.isEmpty {
        let at = Int(rng.next() % UInt64(d.count))
        switch rng.next() % 3 {
        case 0: d[at] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
        case 1: d.remove(at: at)
        default: d.insert(alphabet[Int(rng.next() % UInt64(alphabet.count))], at: at)
        }
    }
    if let s = try? SharedSetup.decode(file: d) { isSane(s.applied(to: theirs), "fuzzed share \(i)"); survived += 1 }
    if case .success(let k) = KensingtonWorks.parse(d), let imp = KensingtonWorksImport.make(from: k) {
        isSane(imp.applied(to: theirs), "fuzzed KensingtonWorks file \(i)"); survived += 1
    }
    if let link = SharedSetup.make(.buttons, from: mine, look: nil)?.link()?.absoluteString, i % 10 == 0 {
        var chars = Array(link.dropFirst("glideball://import?d=".count))
        if !chars.isEmpty { chars[Int(rng.next() % UInt64(chars.count))] = Character(UnicodeScalar(UInt8(65 + rng.next() % 58))) }
        if let s = try? SharedSetup.decode(linkPayload: String(chars)) { isSane(s.applied(to: theirs), "fuzzed link \(i)") }
    }
}
print("  \(survived) of the mangled inputs still parsed, and all of those came out safe")

section("KensingtonWorks: reading the file, never writing it")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("glide-import-sim-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let copy = tmp.appendingPathComponent("TbwSettings.json")
try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("TbwSettings-expert-mouse.json"), to: copy)
try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)   // read-only, like a file we may not touch
let before = try? Data(contentsOf: copy)
let modified = (try? FileManager.default.attributesOfItem(atPath: copy.path))?[.modificationDate] as? Date
if case .success = KensingtonWorks.read(copy) {} else { check(false, "a read-only file couldn't be read") }
check((try? Data(contentsOf: copy)) == before, "the file changed")
check(((try? FileManager.default.attributesOfItem(atPath: copy.path))?[.modificationDate] as? Date) == modified, "the file was touched")
if case .failure(.missing) = KensingtonWorks.read(tmp.appendingPathComponent("nope.json")) {} else { check(false, "a missing file wasn't .missing") }
if case .failure(.notAFile) = KensingtonWorks.read(tmp) {} else { check(false, "a folder wasn't refused") }
let big = tmp.appendingPathComponent("big.json")
FileManager.default.createFile(atPath: big.path, contents: Data(repeating: 0x20, count: KensingtonWorks.maxBytes + 10))
if case .failure(.tooBig) = KensingtonWorks.read(big) {} else { check(false, "a 2 MB file wasn't refused") }

print(failures == 0 ? "PASS import-sim: \(checks) checks" : "FAIL import-sim: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
