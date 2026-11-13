// Feeds glideball:// URLs — good, malformed and hostile — to the real parser
// and command registry (Commands.swift, ExternalControl.swift) with a fake
// app, checks the status.json writer (StatusFile.swift), and exits 1 on any
// failure. Run: scripts/command-sim/run.sh
import Foundation

// MARK: - A fake app

final class FakeApp: CommandTarget {
    var paused = false
    var modes: [GlideMode: Bool] = [:]
    var mode: ScrollMode = .flywheel
    var speed = 4.0
    var setups = [CommandAppSetup(bundleID: "com.apple.Safari", name: "Safari"),
                  CommandAppSetup(bundleID: "com.example.cafe", name: "Café"),
                  CommandAppSetup(bundleID: "com.apple.dt.Xcode", name: "Xcode")]
    var pinned: String?
    var openedTabs: [String] = []
    var openedSettings: [String] = []
    var updateChecks = 0
    var feedbackOpened = 0
    /// Every change, in order, so a test can say "nothing happened".
    var changes: [String] = []

    var isPaused: Bool { paused }
    func setPaused(_ p: Bool) { if p != paused { paused = p; changes.append(p ? "pause" : "resume") } }

    func isOn(_ m: GlideMode) -> Bool { modes[m] ?? false }
    func setMode(_ m: GlideMode, on: Bool?, done: ((Bool?) -> Void)?) {
        guard !paused else { done?(nil); return }   // like the engine: nothing while paused
        let new = on ?? !isOn(m)
        if new != isOn(m) { modes[m] = new; changes.append("\(m.rawValue) \(new)") }
        done?(new)
    }

    var scrollMode: ScrollMode { mode }
    func setScrollMode(_ m: ScrollMode) { mode = m; changes.append("scroll \(m.rawValue)") }

    var pointerSpeed: Double { speed }
    func setPointerSpeed(_ s: Double) { speed = s; changes.append("speed \(s)") }

    var gestures = true
    var gesturesEnabled: Bool { gestures }
    func setGesturesEnabled(_ on: Bool) { gestures = on; changes.append("gestures \(on)") }
    var perDisplay = false
    var perDisplaySpeed: Bool { perDisplay }
    func setPerDisplaySpeed(_ on: Bool) { perDisplay = on; changes.append("per-display \(on)") }

    var appSetups: [CommandAppSetup] { setups }
    var pinnedAppSetup: String? { pinned }
    var activeAppSetupName: String? { setups.first { $0.bundleID == pinned }?.name }
    func pinAppSetup(_ id: String?) { pinned = id; changes.append("pin \(id ?? "nil")") }

    func openTab(_ tab: CommandWindowTab?) { openedTabs.append(tab?.rawValue ?? "window") }
    func openSettings(_ tab: CommandSettingsTab?) { openedSettings.append(tab?.rawValue ?? "settings") }
    func checkForUpdates() { updateChecks += 1 }
    func sendFeedback() { feedbackOpened += 1 }
}

// MARK: - Checking

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what) (line \(line))") }
}
func section(_ name: String) { print("▸ \(name)") }

/// A fresh fake app, clock, log and controller.
final class Rig {
    let app = FakeApp()
    var clock = 1000.0
    var allowed = true
    var logs: [String] = []
    var explanations = 0
    lazy var control = ExternalControl(target: app, isAllowed: { [unowned self] in self.allowed },
                                       now: { [unowned self] in self.clock },
                                       log: { [unowned self] in self.logs.append($0) },
                                       explain: { [unowned self] in self.explanations += 1 })

    @discardableResult
    func send(_ s: String) -> ExternalControl.Outcome {
        clock += 0.1   // a tenth of a second apart: well under the rate limit
        guard let url = URL(string: s) else { return .ignored(.malformed) }
        return control.handle(url)
    }
}

func url(_ s: String) -> URL { URL(string: s)! }

// MARK: - The registry

section("registry")
do {
    let ids = Commands.all.map(\.id)
    check(Set(ids).count == ids.count, "command ids are unique")
    check(Commands.all.allSatisfy { !$0.title.isEmpty }, "every command has a title")
    for id in ["pause", "resume", "toggle", "precision", "ball-scroll", "drag-lock", "scroll-mode", "pointer-speed",
               "app-setup", "open", "settings", "check-for-updates", "feedback", "gestures", "per-display-speed"] {
        check(Commands.command(id) != nil, "registry has \(id)")
    }
    let fromURLs = Set(Commands.all.filter { $0.reach != .appOnly }.map(\.id))
    check(fromURLs == ["pause", "resume", "toggle", "precision", "scroll-mode", "pointer-speed", "app-setup",
                       "open", "settings", "check-for-updates", "per-display-speed"], "exactly the agreed commands are reachable by URL: \(fromURLs.sorted())")
    let navigation = Set(Commands.all.filter { $0.reach == .urlNavigation }.map(\.id))
    check(navigation == ["open", "settings"], "only open and settings work without the switch")

    let app = FakeApp()
    check(Commands.command("toggle")!.state(app) == "running", "pause state reads running")
    Commands.run("pause", on: app)
    check(app.paused && Commands.command("toggle")!.state(app) == "paused", "pause from the app pauses")
    Commands.run("resume", on: app)
    var reported: Bool?? = nil
    Commands.run("precision", .toggle, on: app) { reported = $0 }
    check(app.isOn(.precision) && reported == .some(true), "precision toggle reports the new state")
    check(Commands.command("precision")!.state(app) == "on", "precision state reads on")
    Commands.run("ball-scroll", .toggle, on: app)
    check(app.isOn(.ballScroll), "ball-scroll works from inside the app (hot keys)")
    check(Commands.run("feedback", on: app) && app.feedbackOpened == 1, "feedback works from inside the app (menu)")
    check(!Commands.run("no-such-command", on: app), "an unknown id does nothing")
    check(Commands.command("pointer-speed")!.state(app) == "4", "speed state reads 4")
    check(Commands.command("app-setup")!.state(app) == "automatic", "app-setup state reads automatic")
    // Gestures: app only (it changes what buttons do); off twice stays off.
    check(Commands.command("gestures")!.reach == .appOnly, "gestures can't be switched from a URL")
    check(Commands.command("gestures")!.state(app) == "on", "gestures state reads on")
    Commands.run("gestures", .off, on: app)
    check(!app.gesturesEnabled && Commands.command("gestures")!.state(app) == "off", "gestures off")
    let n = app.changes.count
    Commands.run("gestures", .off, on: app)
    check(app.changes.count == n, "gestures off twice changes nothing")
    Commands.run("gestures", .toggle, on: app)
    check(app.gesturesEnabled, "gestures toggle turns them back on")
    Commands.run("per-display-speed", .on, on: app)
    check(app.perDisplaySpeed && Commands.command("per-display-speed")!.state(app) == "on", "per-display speed on")
}

// MARK: - Good URLs, switch on

section("good URLs (switch on)")
do {
    let r = Rig()
    let app = r.app
    check(r.send("glideball://pause") == .performed("pause") && app.paused, "pause")
    check(r.send("glideball://pause") == .performed("pause") && app.paused, "pause twice stays paused")
    check(r.send("glideball://resume") == .performed("resume") && !app.paused, "resume")
    r.send("glideball://toggle"); check(app.paused, "toggle pauses")
    r.send("glideball://toggle"); check(!app.paused, "toggle resumes")
    r.send("glideball://PAUSE"); check(app.paused, "the command ignores case")
    r.send("glideball://resume/"); check(!app.paused, "a trailing slash is fine")
    r.send("glideball://pause?source=raycast"); check(app.paused, "unknown parameters are ignored")
    r.send("glideball://resume")

    r.send("glideball://precision?state=on"); check(app.isOn(.precision), "precision on")
    let before = app.changes.count
    r.send("glideball://precision?state=on"); check(app.isOn(.precision) && app.changes.count == before, "precision on twice: still on, nothing changed")
    r.send("glideball://precision?state=off"); check(!app.isOn(.precision), "precision off")
    r.send("glideball://precision?state=off"); check(!app.isOn(.precision), "precision off twice stays off")
    r.send("glideball://precision?state=toggle"); check(app.isOn(.precision), "precision toggle")
    r.send("glideball://precision"); check(!app.isOn(.precision), "precision with no state toggles")
    r.send("glideball://precision?state=ON"); check(app.isOn(.precision), "state ignores case")

    for m in ["native", "follow", "flywheel"] {
        r.send("glideball://scroll-mode?mode=\(m)"); check(app.mode.rawValue == m, "scroll-mode \(m)")
    }
    r.send("glideball://scroll-mode?mode=Follow"); check(app.mode == .follow, "mode ignores case")
    r.send("glideball://scroll-mode?mode=fl%79wheel"); check(app.mode == .flywheel, "a percent-encoded value is decoded like any other")

    r.send("glideball://pointer-speed?value=7"); check(app.speed == 7, "pointer-speed 7")
    r.send("glideball://pointer-speed?value=4.5"); check(app.speed == 4.5, "pointer-speed 4.5")
    r.send("glideball://pointer-speed?value=4.26"); check(app.speed == 4.5, "pointer-speed rounds to the slider's 0.5 steps (4.26 → 4.5)")
    r.send("glideball://pointer-speed?value=4.24"); check(app.speed == 4, "pointer-speed 4.24 → 4")
    r.send("glideball://pointer-speed?value=1000"); check(app.speed == 80, "pointer-speed clamps to 80")
    r.send("glideball://pointer-speed?value=0"); check(app.speed == 0.5, "pointer-speed clamps to 0.5")
    r.send("glideball://pointer-speed?value=.5"); check(app.speed == 0.5, "pointer-speed .5")
    r.send("glideball://pointer-speed?value=4%2E5"); check(app.speed == 4.5, "pointer-speed 4%2E5 decodes to 4.5")

    check(r.send("glideball://app-setup?name=Safari") == .performed("app-setup") && app.pinned == "com.apple.Safari", "app-setup by name")
    r.send("glideball://app-setup?name=automatic"); check(app.pinned == nil, "app-setup automatic")
    r.send("glideball://app-setup?name=xcode"); check(app.pinned == "com.apple.dt.Xcode", "app-setup ignores case")
    r.send("glideball://app-setup?name=com.apple.Safari"); check(app.pinned == "com.apple.Safari", "app-setup by bundle ID")
    r.send("glideball://app-setup?name=caf%C3%A9"); check(app.pinned == "com.example.cafe", "app-setup with a non-ASCII name")
    r.send("glideball://app-setup?name=Automatic"); check(app.pinned == nil, "automatic ignores case")
    r.send("glideball://app-setup?name=%20Safari%20"); check(app.pinned == "com.apple.Safari", "spaces around a name are trimmed")
    r.send("glideball://app-setup?name=automatic")

    r.send("glideball://open"); r.send("glideball://open?tab=apps"); r.send("glideball://open?tab=sync")
    check(app.openedTabs == ["window", "apps", "sync"], "open, open?tab=apps, open?tab=sync: \(app.openedTabs)")
    r.send("glideball://settings"); r.send("glideball://settings?tab=shortcuts")
    check(app.openedSettings == ["settings", "shortcuts"], "settings and settings?tab=shortcuts")
    r.send("glideball://check-for-updates"); check(app.updateChecks == 1, "check-for-updates")
    check(r.explanations == 0, "no explanation while the switch is on")
    check(r.logs.contains("url: precision on") && r.logs.contains("url: pointer-speed 4.5"), "performed commands are logged")
}

// MARK: - Switch off

section("switch off")
do {
    let r = Rig()
    r.allowed = false
    let app = r.app
    check(r.send("glideball://pause") == .needsSwitch(explained: true), "the first blocked URL explains")
    check(r.send("glideball://precision?state=on") == .needsSwitch(explained: false), "the second doesn't")
    for _ in 0..<50 { r.clock += 1; r.send("glideball://toggle") }
    check(r.explanations == 1, "one explanation per launch, however many URLs (\(r.explanations))")
    check(app.changes.isEmpty && !app.paused, "nothing changed with the switch off: \(app.changes)")
    r.send("glideball://open?tab=pointer"); r.send("glideball://settings?tab=general")
    check(app.openedTabs == ["pointer"] && app.openedSettings == ["general"], "open and settings work with the switch off")
    r.send("glideball://check-for-updates")
    check(app.updateChecks == 0, "check-for-updates needs the switch")
    check(r.send("glideball://bogus") == .ignored(.unknownCommand), "an unknown command is ignored, not explained")
    check(r.explanations == 1, "still one explanation")
    r.allowed = true
    r.send("glideball://pause")
    check(app.paused, "turning the switch on lets it through")
}

// MARK: - Malformed and hostile URLs

section("malformed and hostile URLs")
do {
    let r = Rig()
    let app = r.app
    let marker = "EVILMARKER"
    let hostile: [(String, ExternalControl.Rejection)] = [
        ("glideball://", .malformed),
        ("glideball:pause", .malformed),
        ("glideball:///pause", .malformed),
        ("glideball://user:pw@pause", .malformed),
        ("glideball://pause:8080", .malformed),
        ("glideball://pause/now", .malformed),
        ("glideball://open/../../etc/passwd", .malformed),
        ("glideball://open/%2E%2E/%2E%2E/etc/passwd", .malformed),
        ("https://pause", .notGlideball),
        ("file:///etc/passwd", .notGlideball),
        ("glideball://pa%75se", .unknownCommand),
        ("glideball://pause%00", .unknownCommand),
        ("glideball://pause.evil", .unknownCommand),
        ("glideball://delete", .unknownCommand),
        ("glideball://import?file=/etc/passwd", .badParameter),
        ("glideball://export", .unknownCommand),
        ("glideball://run?cmd=rm%20-rf%20~", .unknownCommand),
        ("glideball://\(marker)", .unknownCommand),
        ("glideball://\(String(repeating: "a", count: 40))", .unknownCommand),
        ("glideball://feedback", .appOnly),
        ("glideball://ball-scroll?state=on", .appOnly),
        ("glideball://drag-lock?state=on", .appOnly),
        ("glideball://precision?state=maybe", .badParameter),
        ("glideball://precision?state=", .badParameter),
        ("glideball://precision?state", .badParameter),
        ("glideball://precision?state=on&state=off", .badParameter),
        ("glideball://precision?state=on%00", .badParameter),
        ("glideball://precision?state=o%0An", .badParameter),
        ("glideball://scroll-mode", .badParameter),
        ("glideball://scroll-mode?mode=\(marker)", .badParameter),
        ("glideball://scroll-mode?mode=%E2%80%AEfollow", .badParameter),
        ("glideball://scroll-mode?mode=follow%20", .badParameter),
        ("glideball://scroll-mode?mode=%25s%25n", .badParameter),
        ("glideball://pointer-speed", .badParameter),
        ("glideball://pointer-speed?value=", .badParameter),
        ("glideball://pointer-speed?value=nan", .badParameter),
        ("glideball://pointer-speed?value=inf", .badParameter),
        ("glideball://pointer-speed?value=1e3", .badParameter),
        ("glideball://pointer-speed?value=0x10", .badParameter),
        ("glideball://pointer-speed?value=-3", .badParameter),
        ("glideball://pointer-speed?value=4,5", .badParameter),
        ("glideball://pointer-speed?value=%204", .badParameter),
        ("glideball://pointer-speed?value=1.2.3", .badParameter),
        ("glideball://pointer-speed?value=99999999999999999999", .badParameter),
        ("glideball://pointer-speed?value=%D9%A4", .badParameter),   // Arabic-Indic four
        ("glideball://app-setup", .badParameter),
        ("glideball://app-setup?name=", .badParameter),
        ("glideball://app-setup?name=%20%20", .badParameter),
        ("glideball://app-setup?name=Safari%0A", .badParameter),
        ("glideball://app-setup?name=\(String(repeating: "x", count: 150))", .badParameter),
        ("glideball://app-setup?name=../../../etc/passwd", .noSuchSetup),
        ("glideball://app-setup?name=%2E%2E%2F%2E%2E%2Fetc%2Fpasswd", .noSuchSetup),
        ("glideball://app-setup?name=%25s%25s%25n%25x", .noSuchSetup),
        ("glideball://app-setup?name=$(touch%20/tmp/\(marker))", .noSuchSetup),
        ("glideball://app-setup?name=\(marker)", .noSuchSetup),
        ("glideball://open?tab=../../etc", .badParameter),
        ("glideball://open?tab=\(marker)", .badParameter),
        ("glideball://settings?tab=advanced", .badParameter),
        ("glideball://pause?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8&i=9", .badParameter),
        ("glideball://pause?x=" + String(repeating: "A", count: 100_000), .tooLong),
        ("glideball://app-setup?name=" + String(repeating: "%41", count: 400), .tooLong),
    ]
    for (s, why) in hostile {
        r.clock += 1
        guard let u = URL(string: s) else { check(false, "test URL didn't parse: \(s.prefix(60))"); continue }
        let outcome = r.control.handle(u)
        check(outcome == .ignored(why), "\(s.prefix(70)) → \(why.rawValue), got \(outcome)")
    }
    check(app.changes.isEmpty && !app.paused && app.openedTabs.isEmpty && app.openedSettings.isEmpty
          && app.updateChecks == 0 && app.feedbackOpened == 0, "no hostile URL changed anything: \(app.changes)")
    check(r.explanations == 0, "no hostile URL brought up the explanation")
    check(!r.logs.contains { $0.contains(marker) || $0.contains("passwd") || $0.contains("%") }, "the log never repeats URL text")
    check(r.logs.allSatisfy { $0.allSatisfy(\.isASCII) && $0.count < 120 }, "log lines are short and plain ASCII")
    check(!FileManager.default.fileExists(atPath: "/tmp/\(marker)"), "nothing was run")
}

// MARK: - Bursts

section("1,000 in a burst")
do {
    let r = Rig()
    var outcomes: [ExternalControl.Outcome] = []
    for _ in 0..<1000 { outcomes.append(r.control.handle(url("glideball://toggle"))) }   // same instant
    let performed = outcomes.filter { $0 == .performed("toggle") }.count
    let limited = outcomes.filter { $0 == .rateLimited }.count
    check(performed == 20 && limited == 980, "20 run, 980 dropped (got \(performed), \(limited))")
    check(r.app.changes.count == 20, "20 changes")
    check(r.logs.filter { $0.contains("dropping") }.count == 1, "one 'dropping' line, not 980")
    r.clock += 0.5
    var more = 0
    for _ in 0..<100 { if r.control.handle(url("glideball://toggle")) == .performed("toggle") { more += 1 } }
    check(more == 10, "half a second later, 10 more (got \(more))")
    check(r.logs.contains("url: dropped 980"), "the drop count is logged once it recovers")

    // A steady 15 a second, for a minute, all get through.
    let s = Rig()
    var ok = 0
    for _ in 0..<(15 * 60) { s.clock += 1.0 / 15; if s.control.handle(url("glideball://toggle")) == .performed("toggle") { ok += 1 } }
    check(ok == 900, "a steady 15/s all run (\(ok) of 900)")

    // Junk at full speed: limited the same way, and the log stays small.
    let j = Rig()
    for i in 0..<1000 { j.control.handle(url("glideball://junk\(i % 7 == 0 ? "" : "x")")) }
    check(j.logs.count <= 22, "1,000 junk URLs, \(j.logs.count) log lines")
    check(j.app.changes.isEmpty, "junk changed nothing")

    // With the switch off, a burst still explains once.
    let o = Rig()
    o.allowed = false
    for _ in 0..<1000 { o.control.handle(url("glideball://pause")) }
    check(o.explanations == 1 && !o.app.paused, "a burst with the switch off: one explanation, nothing changed")
}

// MARK: - Shared setups (glideball://import)

section("glideball://import: a preview, never a change")
do {
    var mine = GlideConfig()
    mine.trackingSpeed = 9
    mine.buttons = [2: .shortcut(.copy)]
    let good = SharedSetup.make(.pointer, from: mine, look: nil)!.appLink()!.absoluteString
    let buttons = SharedSetup.make(.buttons, from: mine, look: nil)!.appLink()!.absoluteString
    let payload = String(good.dropFirst("glideball://import?d=".count))

    // With the switch off: handed over for a preview, and nothing else.
    let r = Rig()
    r.allowed = false
    var received: [SharedSetup] = []
    r.control.onImport = { received.append($0) }
    check(r.send(good) == .performed("import"), "a good link is handed over with the switch off")
    check(received.count == 1 && received[0].kind == .pointer && received[0].trackingSpeed == 9, "the share arrives intact")
    check(r.app.changes.isEmpty && r.explanations == 0, "a link changed something or asked for the switch: \(r.app.changes)")
    check(r.send("glideball://IMPORT?d=" + payload) == .performed("import"), "the command ignores case like the others")
    check(r.send("glideball://import/?d=" + payload + "&utm_source=x") == .performed("import"), "a trailing slash and unknown parameters are fine")
    check(r.send(buttons) == .performed("import"), "a buttons link is handed over too (the preview lists them)")
    check(!r.logs.contains { $0.contains(payload.prefix(12)) }, "the log repeats the payload")

    // Hostile links: ignored before anything sees them.
    let h = Rig()
    var leaked = 0
    h.control.onImport = { _ in leaked += 1 }
    let marker = "EVILMARKER"
    let bomb = SharedSetup.base64url(SharedSetup.deflate(Data(repeating: 0x7B, count: 3_000_000))!)
    let hostile: [(String, ExternalControl.Rejection)] = [
        ("glideball://import", .badParameter),
        ("glideball://import?d=", .badParameter),
        ("glideball://import?d=\(payload)&d=\(payload)", .badParameter),
        ("glideball://import?D=\(payload)", .badParameter),
        ("glideball://import?d=\(marker)", .badShare),
        ("glideball://import?d=%00%01%02", .badShare),
        ("glideball://import?d=" + bomb, bomb.count + 21 > ExternalControl.maxImportURLLength ? .tooLong : .badShare),
        ("glideball://import?d=" + String(repeating: "A", count: 2_060), .badShare),   // the URL fits, the payload doesn't
        ("glideball://import?d=" + String(repeating: "A", count: 2_100), .tooLong),
        ("glideball://import?d=" + String(repeating: "A", count: 100_000), .tooLong),
        ("glideball://import/../../etc/passwd?d=\(payload)", .malformed),
        ("glideball://user:pw@import?d=\(payload)", .malformed),
        ("glideball://import:99?d=\(payload)", .malformed),
        ("glideball://import?a=1&b=2&c=3&d=\(payload)&e=5&f=6&g=7&h=8&i=9", .badParameter),
        ("glideball://import?d=" + SharedSetup.base64url(SharedSetup.deflate(Data("{\"format\":\"glideball-share\",\"version\":7,\"kind\":\"pointer\",\"trackingSpeed\":5}".utf8))!), .badShare),
        ("glideball://import?d=" + SharedSetup.base64url(SharedSetup.deflate(Data("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"rm\"}".utf8))!), .badShare),
    ]
    for (s, why) in hostile {
        h.clock += 1
        guard let u = URL(string: s) else { check(false, "test URL didn't parse: \(s.prefix(60))"); continue }
        let outcome = h.control.handle(u)
        check(outcome == .ignored(why), "\(s.prefix(60)) → \(why.rawValue), got \(outcome)")
    }
    check(leaked == 0 && h.app.changes.isEmpty, "a hostile import link got through")
    check(!h.logs.contains { $0.contains(marker) || $0.contains("passwd") }, "the log repeats URL text")
    check(h.logs.allSatisfy { $0.count < 120 }, "a log line is long")
    // A share that's fine but asks for the impossible: clamped when it's applied (SharedSetup), still only a preview here.
    let wild = SharedSetup.base64url(SharedSetup.deflate(Data("{\"format\":\"glideball-share\",\"version\":1,\"kind\":\"pointer\",\"trackingSpeed\":1e300}".utf8))!)
    h.clock += 1
    check(h.control.handle(url("glideball://import?d=" + wild)) == .performed("import") && leaked == 1, "a share with a wild value isn't previewed")

    // A page firing links in a loop: the rate limit holds (and the app shows one preview at a time).
    let b = Rig()
    var previews = 0
    b.control.onImport = { _ in previews += 1 }
    for _ in 0..<1000 { b.control.handle(url(good)) }
    check(previews == 20, "1,000 import links at once: \(previews) handed over, not 20")
    check(b.app.changes.isEmpty, "a burst of links changed something")
}

// MARK: - status.json

section("status.json")
do {
    var s = GlideStatus()
    s.appVersion = "2.10-beta.8"
    s.pid = 123
    s.paused = false
    s.trackballConnected = true
    s.trackballs = ["Kensington Expert Mouse"]
    s.scrollMode = "flywheel"
    s.pointerSpeed = 4.5
    s.modes.precision = true
    s.activeAppSetup = .init(name: "Safari", pinned: false)
    s.today = .init(clicks: 1234, ballMeters: 41.25, scrollMeters: 63.5)
    s.updatedAt = GlideStatus.timestamp(Date(timeIntervalSince1970: 0))
    let data = try! s.encoded()
    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    check(Set(json.keys) == ["schemaVersion", "appVersion", "pid", "paused", "trackballConnected", "trackballs", "scrollMode",
                             "pointerSpeed", "modes", "activeAppSetup", "today", "updatedAt"], "top-level keys: \(json.keys.sorted())")
    check(json["schemaVersion"] as? Int == 1, "schemaVersion 1")
    check(Set((json["modes"] as! [String: Any]).keys) == ["precision", "ballScroll", "dragLock"], "modes keys")
    check(Set((json["today"] as! [String: Any]).keys) == ["clicks", "ballMeters", "scrollMeters"], "today keys")
    check(Set((json["activeAppSetup"] as! [String: Any]).keys) == ["name", "pinned"], "activeAppSetup keys")
    check(json["updatedAt"] as? String == "1970-01-01T00:00:00Z", "updatedAt is ISO 8601 UTC")
    var none = s
    none.activeAppSetup = nil
    let noneJSON = try! JSONSerialization.jsonObject(with: none.encoded()) as! [String: Any]
    check(noneJSON["activeAppSetup"] == nil || noneJSON["activeAppSetup"] is NSNull, "no setup: activeAppSetup is absent or null")
    var later = s
    later.updatedAt = "2030-01-01T00:00:00Z"
    check(s.sameState(as: later), "only updatedAt differs: same state")
    later.today.clicks += 1
    check(!s.sameState(as: later), "a click is a new state")
    check(GlideStatus.rounded(1.23456) == 1.23, "distances are rounded to centimeters")

    // The writer: writes when something changed, at most once a second, and deletes on stop.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-command-sim-\(getpid())")
    let file = dir.appendingPathComponent("Glide/status.json")
    var current = s
    var clock = 0.0
    let w = StatusFileWriter(url: file, now: { clock }, snapshot: { current })
    check(w.writeIfChanged(), "the first write happens")
    check(!w.writeIfChanged(), "nothing changed: no write")
    current.paused = true
    clock += 0.2
    check(w.writeIfChanged(), "a change is written")
    w.stopAndRemove(wait: false)
    w.stopAndRemove(wait: true)   // waits for the queue: the earlier writes and the removal are done
    check(!FileManager.default.fileExists(atPath: file.path), "stop removes status.json")
    check(!w.writeIfChanged(), "a stopped writer never writes again")

    // Debounce: many changes in a burst become about one write a second.
    let w2 = StatusFileWriter(url: file, now: { Date().timeIntervalSinceReferenceDate }, snapshot: { current })
    w2.minInterval = 0.2
    for i in 0..<200 {
        current.today.clicks = i
        w2.setNeedsWrite()
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(w2.writes >= 2 && w2.writes <= 7, "200 changes over ~0.8 s at a 0.2 s minimum: \(w2.writes) writes")
    let onDisk = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    check((onDisk?["today"] as? [String: Any])?["clicks"] as? Int == 199, "the last change reaches the file")
    w2.stopAndRemove(wait: true)
    check(!FileManager.default.fileExists(atPath: file.path), "and it's removed again")
    try? FileManager.default.removeItem(at: dir)
}

print("")
if failures > 0 {
    print("command-sim: \(failures) of \(checks) checks FAILED")
    exit(1)
}
print("command-sim: all \(checks) checks passed")
