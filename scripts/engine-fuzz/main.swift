// The engine fuzzer: drives the REAL input engine (Engine.swift, with SmoothScroller,
// Gestures, DisplayTracking and the settings model) through a fake EngineIO — no
// event tap, no IOHIDManager, no real cursor, no pointer-speed writes — with long
// random sequences of trackball, mouse, trackpad and keyboard events, settings
// changes, app switches, pauses, unplugs, sleeps and the tap being switched off by
// macOS. After every single event it checks the hard rules:
//
//   primary     the primary button always reaches apps as a left click (button 0),
//               never remapped, never swallowed (except: drag lock's "a click lets go",
//               a combo you made with it, Quick assign listening)
//   paired      apps never see a button go down twice or come up (or drag) without
//               going down; nothing the engine posts is posted twice
//   released    every key, modifier and button the engine pressed is up again once
//               its trigger is up, and at once after pause, quit, unplug and sleep
//   modes       Precision, Scroll with ball, Drag lock and gestures are all off after
//               pause, quit and unplug; the pointer is frozen exactly while Scroll with
//               ball or a gesture has it, and always freed
//   standin     the stand-in pointer is up exactly while the pointer is held with the tap
//               on (unless it can't be shown or the watchdog took it down), at the hold's
//               anchor; the real pointer is hidden once under it and shown once after; it's
//               down after every way a hold ends; the engine keeps it alive for EngineIO's
//               watchdog; the real pointer is let go where the stand-in was
//   gestures    a gesture hold never includes the primary button (a combo with it never
//               starts one); a direction fires only while held, and only after the ball
//               rolled the hold's distance for each fire (its own, the global one and
//               Steady hands: GestureTuning); chained fires are numbered 1, 2, 3… per
//               hold, at most 20 a second; a "once per hold" direction fires once; a tap
//               only after a hold that stayed within the tap slop and never fired
//   wheel       a Wheel hold never includes the primary button; its ring (overlay) is up only
//               while it's held with the pointer frozen, centred on the hold's anchor, kept
//               alive for EngineIO's watchdog, and down after every way a hold ends (release,
//               pause, quit, unplug, sleep, the tap switched off, the 30 s limit, the watchdog);
//               a slot runs only after the release, at most once per hold, never after Esc or
//               another trackball button; ring steps only while held, at most 20 a second, and
//               ring turns never scroll while a Wheel is held; the tap only after a hold with no
//               ring turn and no slot; the key tap (for Esc) is on only while a Wheel is held
//   switcher    a Switcher hold never includes the primary button; a Wheel, a gesture and a
//               Switcher are never held at once; its panel is up only while it's held with the
//               pointer frozen and its list ready, at the hold's anchor, kept alive for EngineIO's
//               watchdog, its lit app in the list and on screen, and down after every way a hold
//               ends (release, pause, quit, unplug, sleep, the tap switched off, the 30 s limit,
//               the watchdog); it switches apps only after the release, at most once per hold,
//               to an app in that hold's list, never after Esc, another trackball button or the
//               watchdog; ring turns never scroll while it's held; the tap only before its panel
//               shows, with no roll or ring turn; the main thread's list may come late or never
//   others      other mice and the trackpad pass through untouched, and paired, even pressing
//               the same button number as the trackball at overlapping times (either's HID
//               report before or after its event); their press or release never ends or
//               changes what the trackball's press holds (keys, a gesture hold, Scroll with ball)
//   held        buttons held while the engine starts, the tap is off, or the trackball is
//               plugged in: their releases leave apps paired and do nothing mapped
//   scrolling   the flywheel never scrolls after pause, unplug or sleep, never runs
//               away (bounded per frame, stops after the last input), never NaN
//   pointer     pointer speeds only while running, finite, inside the app's limits
//   connected   the status says "Connected" exactly while the trackball is plugged in (late
//               values, a reused address, a missed removal until the next device check)
//   works       a plugged-in trackball's every HID value reaches the engine, however the
//               replug was published (properties, IOHIDManager's list or the registry
//               late, a device check in the gap, an old removal after it, termination
//               notices in any order, recycled object addresses). Both judged from 1.5 s
//               after a replug.
//
// On a failure it prints the seed and a minimized list of events (delta debugging).
//
//   engine-fuzz [--seeds A-B] [--events N] [--seed S] [--random] [--minutes M] [--regressions-only]
//   engine-fuzz --threads [--seconds S]     the engine on its own threads (for -sanitize=thread)
// (scripts/engine-fuzz/run.sh builds and runs it.)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Plumbing

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        s = s &+ 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func double(_ a: Double, _ b: Double) -> Double { a + Double(next() >> 11) / Double(1 << 53) * (b - a) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

var tracing = false

/// Which input an output came from: the fuzzer writes its own event number here.
let srcField = CGEventField(rawValue: 92)!
let phaseField = CGEventField(rawValue: 99)!

final class FakeTimer: EngineTimer {
    var fireAt: Double
    let interval: Double
    let repeats: Bool
    let body: () -> Void
    var valid = true
    let order: Int
    init(fireAt: Double, interval: Double, repeats: Bool, order: Int, body: @escaping () -> Void) {
        self.fireAt = fireAt; self.interval = interval; self.repeats = repeats; self.order = order; self.body = body
    }
    func invalidate() { valid = false }
}

/// The world as the engine sees it, faked: a virtual clock, a pretend cursor, and a
/// record of everything the engine does. Nothing here touches the real Mac.
final class FakeIO: EngineIO {
    var clock = 1000.0
    var cursor = CGPoint(x: 400, y: 300)
    var kbFlags: CGEventFlags = []
    var frozen = false
    var posted: [CGEvent] = []
    var keyWork: [() -> Void] = []
    var mainWork: [() -> Void] = []
    var timers: [FakeTimer] = []
    var timerOrder = 0
    var natural = true
    var direction = 0.0
    var accessibility = true
    var inputMonitoring = true
    var tapEnabled: [ObjectIdentifier: Bool] = [:]
    var tapMask: [ObjectIdentifier: CGEventMask] = [:]
    var mainTap: CFMachPort?
    var moveTap: CFMachPort?
    var onApply: ((PointerTuner.Settings) -> Void)?
    var restoreCalls = 0

    override func now() -> CFTimeInterval { clock }
    override func cursorLocation() -> CGPoint? { cursor }
    override func keyboardFlags() -> CGEventFlags { kbFlags }
    /// Glideball is the app in front. Since beta 17 that changes nothing for the hold: the pointer
    /// is never dissociated, so it moves with the ball in front or behind and only the engine's
    /// own warps put it back (dissociating made macOS report a frozen location, beta 16).
    var foreground = false
    /// Where the pointer must stay while it's frozen (moves with another mouse's movement).
    var anchorExpect: CGPoint?
    var warps = 0
    override func warpPointer(_ point: CGPoint) -> Bool {
        if !frozen { warpedWhileFree = true }
        warps += 1
        cursor = point
        return true
    }
    var warpedWhileFree = false

    /// The stand-in pointer, as the engine asked for it, and the real pointer's hidden state as
    /// EngineIO keeps it (hidden once at a first show, shown once at a take-down).
    var standIn: CGPoint?
    var realHidden = false
    var standInKeptAt = 0.0
    var standInShows = 0, standInMoves = 0
    var standInWorks = true          // false: macOS's background-cursor switch is missing
    var standInDropped = false       // the watchdog took it down this hold (World.apply)
    var standInRefused = false       // it couldn't be shown this hold
    var standInFault: String?        // a rule the engine broke, for World.checkAlways
    /// Where the real pointer was when the hold let it go with the stand-in still up.
    var freedAt: (cursor: CGPoint, standIn: CGPoint, tapOn: Bool)?
    override func freezePointer(_ f: Bool) {
        if f && anchorExpect == nil { anchorExpect = cursor; standInDropped = false; standInRefused = false }
        if !f { anchorExpect = nil; if frozen, let s = standIn { freedAt = (cursor, s, mainTap.map { tapIsEnabled($0) } ?? false) } }
        frozen = f
    }
    override func showStandIn(at point: CGPoint) -> Bool {
        guard standInWorks else { standInRefused = true; return false }
        if !frozen { standInFault = "the stand-in was shown while nothing held the pointer" }
        if standIn == nil {
            if realHidden { standInFault = "the real pointer was hidden twice" }
            realHidden = true
            standInShows += 1
            standInKeptAt = clock
        } else {
            standInMoves += 1
        }
        standIn = point
        return true
    }
    override func hideStandIn() {
        realHidden = false   // EngineIO shows it only if it hid it: never twice
        standIn = nil
    }
    override func keepStandIn() -> Bool {
        guard standIn != nil else { return false }
        standInKeptAt = clock
        return true
    }
    override func standInProblem() -> String? {
        standInWorks ? (standInDropped ? "the engine stopped answering" : nil) : "no background-cursor switch"
    }
    /// The Wheel's overlay, as the engine asked for it.
    var wheel: (model: WheelOverlayModel, at: CGPoint)?
    var wheelKeptAt = 0.0
    var wheelShows = 0
    var wheelWorks = true            // false: nothing to draw it with (render-ui, self-test)
    var wheelDropped = false         // the watchdog took it down this hold (World.apply)
    var wheelFault: String?
    override func showWheel(_ model: WheelOverlayModel, at point: CGPoint) -> Bool {
        guard wheelWorks else { return false }
        if !frozen { wheelFault = "the Wheel was shown while nothing held the pointer" }
        if wheel == nil { wheelShows += 1; wheelKeptAt = clock }
        wheel = (model, point)
        return true
    }
    override func hideWheel() { wheel = nil }
    override func keepWheel() -> Bool {
        guard wheel != nil else { return false }
        wheelKeptAt = clock
        return true
    }
    /// The Switcher's panel, as the engine asked for it, and its lists (built "on the main thread").
    var switcher: (model: SwitcherOverlayModel, at: CGPoint)?
    var switcherKeptAt = 0.0
    var switcherShows = 0
    var switcherWorks = true         // false: the panel can't be drawn
    var switcherLists = true         // false: nothing builds lists (render-ui, self-test): only the tap
    var switcherDropped = false      // the watchdog took it down this hold (World.apply)
    var switcherFault: String?
    var listDelay = 0.0              // how long the main thread takes to build a list (infinity: never)
    var listGrid = SwitcherGrid.fitting(count: 6, maxColumns: 8, maxRows: 3)
    var pendingLists: [(due: Double, session: Int, grid: SwitcherGrid, ready: (SwitcherGrid) -> Void)] = []
    var lists: [Int: SwitcherGrid] = [:]   // this engine's holds' lists, by session (a relaunch starts over)
    var activatedSessions: Set<Int> = []
    var activations: [(session: Int, index: Int)] = []
    override func prepareSwitcher(session: Int, near point: CGPoint, ready: @escaping (SwitcherGrid) -> Void) -> Bool {
        guard switcherLists else { return false }
        if lists[session] != nil { switcherFault = "two lists asked for Switcher hold \(session)" }
        lists[session] = listGrid
        if listDelay.isFinite { pendingLists.append((clock + listDelay, session, listGrid, ready)) }
        return true
    }
    override func showSwitcher(_ model: SwitcherOverlayModel, at point: CGPoint) -> Bool {
        guard switcherWorks else { return false }
        if !frozen { switcherFault = "the Switcher was shown while nothing held the pointer" }
        if lists[model.session] != model.grid { switcherFault = "the panel's grid isn't its list's" }
        if switcher == nil { switcherShows += 1; switcherKeptAt = clock }
        switcher = (model, point)
        return true
    }
    override func hideSwitcher() { switcher = nil }
    override func keepSwitcher() -> Bool {
        guard switcher != nil else { return false }
        switcherKeptAt = clock
        return true
    }
    override func activateSwitcher(session: Int, index: Int) {
        if !activatedSessions.insert(session).inserted { switcherFault = "Switcher hold \(session) switched apps twice" }
        if let g = lists[session] {
            if index < 0 || index >= g.count { switcherFault = "switched to app \(index) of \(g.count)" }
        } else {
            switcherFault = "switched apps for a hold that never had a list"
        }
        if switcher != nil { switcherFault = "switched apps with the panel still up" }
        activations.append((session, index))
    }
    /// The main thread hands over the lists that are due.
    func deliverLists() {
        while let i = pendingLists.firstIndex(where: { $0.due <= clock }) {
            let l = pendingLists.remove(at: i)
            l.ready(l.grid)
        }
    }
    var keyTap: CFMachPort?
    override func post(_ event: CGEvent, tap: CGEventTapLocation) { posted.append(event) }
    var appButtons: () -> Set<Int64> = { [] }
    override func buttonsDown() -> Set<Int64> { appButtons() }
    override func buttonDown(_ button: Int64) -> Bool { appButtons().contains(button) }
    /// The trackball's buttons down by its last report (its HID element values).
    var held: (Int) -> Set<Int64>? = { _ in nil }
    override func heldButtons(_ key: Int, _ device: IOHIDDevice?) -> Set<Int64>? { held(key) }
    override func keys(_ work: @escaping () -> Void) { keyWork.append(work) }
    /// Like the real serial key queue: what's queued already runs first.
    override func keysNow(_ work: () -> Void) {
        while !keyWork.isEmpty { keyWork.removeFirst()() }
        work()
    }
    override func toMain(_ work: @escaping () -> Void) { mainWork.append(work) }
    override func schedule(_ interval: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) -> EngineTimer {
        timerOrder += 1
        let t = FakeTimer(fireAt: clock + interval, interval: interval, repeats: repeats, order: timerOrder, body: body)
        timers.append(t)
        return t
    }
    override var naturalScrolling: Bool { natural }
    override var savedScrollDirection: Double {
        get { direction }
        set { direction = newValue }
    }
    override func openApp(_ bundleID: String) {}
    override func applyPointer(_ settings: PointerTuner.Settings) { onApply?(settings) }
    override func restorePointer() { restoreCalls += 1 }
    override func pointerDevicesChanged() {}
    override func installTap(mask: CGEventMask, engine: Engine, runLoop: CFRunLoop?) -> (CFMachPort, CFRunLoopSource)? {
        guard accessibility else { return nil }
        var ctx = CFMachPortContext()
        guard let port = CFMachPortCreate(nil, { _, _, _, _ in }, &ctx, nil),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        let id = ObjectIdentifier(port)
        tapEnabled[id] = true
        tapMask[id] = mask
        if mask == CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue) { moveTap = port }
        else if mask & (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)) != 0 { keyTap = port }
        else { mainTap = port }
        return (port, source)
    }
    override func removeTap(_ tap: CFMachPort, source: CFRunLoopSource?, runLoop: CFRunLoop?) {
        tapEnabled[ObjectIdentifier(tap)] = nil
        tapMask[ObjectIdentifier(tap)] = nil
        if moveTap === tap { moveTap = nil }
        if mainTap === tap { mainTap = nil }
        if keyTap === tap { keyTap = nil }
        CFMachPortInvalidate(tap)
    }
    override func tapIsEnabled(_ tap: CFMachPort) -> Bool { tapEnabled[ObjectIdentifier(tap)] ?? false }
    override func tapEnable(_ tap: CFMachPort, _ on: Bool) {
        if tapEnabled[ObjectIdentifier(tap)] != nil { tapEnabled[ObjectIdentifier(tap)] = on }
    }
    override func startListening(_ engine: Engine, runLoop: CFRunLoop?) -> Bool { inputMonitoring }
    /// What IOHIDManager would list now. Like the real one, it can still list a device
    /// that's gone: during that device's own removal callback (IOHIDManager takes it out of
    /// its set only after the callback), and for good when it never heard of the removal.
    var live: () -> [Int: DeviceIdentity] = { [:] }
    /// What IOKit really has registered (the World's hardware).
    var alive: (Int) -> Bool = { _ in true }
    override func liveDevices() -> [Int: (identity: DeviceIdentity, transport: String?, device: IOHIDDevice?)]? {
        guard inputMonitoring else { return nil }
        return live().mapValues { ($0, "USB", nil) }
    }
    override func serviceIsAlive(_ key: Int) -> Bool { alive(key) }
    /// A device's properties now (a replug can publish the device before all of them).
    var identityNow: (Int) -> DeviceIdentity? = { _ in nil }
    override func currentIdentity(_ key: Int, _ device: IOHIDDevice?) -> DeviceIdentity? { identityNow(key) }
    override func kensingtonServicesNow() -> [String] { [] }
    /// The fake registry can't say what a device is: the engine must go by timing alone.
    override func echoReason(_ key: Int, trackballs: Set<Int>) -> String? { nil }
    /// Wireless trackballs: a battery level that changes over time (and is sometimes missing).
    override func registryBattery(_ key: Int) -> Int? { [nil, 4, 50, 100][Int(clock) % 4] }

    func sees(_ tap: CFMachPort?, _ type: CGEventType) -> Bool {
        guard let tap, let mask = tapMask[ObjectIdentifier(tap)], tapIsEnabled(tap) else { return false }
        return mask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0
    }
}

// MARK: - What the fuzzer does

enum Op: CustomStringConvertible {
    case kPress(Int, hidFirst: Bool)
    case kRelease(Int, hidFirst: Bool)
    case kBall(Int, Int)
    case kWheel(Int)
    case oPress(Int), oRelease(Int), oWheel(Int), oBall
    case oReleaseCGFirst(Int) // another mouse's release, its HID report after the CG event
    /// The trackball and another mouse or the trackpad on the same button number (World.apply).
    case overlap(Int, Int)
    case replugHeld(Int, Int) // plugged in with a button already held (World.apply)
    case padClick(Int), padScroll
    case padMove              // the trackpad moves the pointer (it never shows up in HID)
    case keyboard(UInt64)
    case wait(Double)
    case config(Int)
    case remote(Int)          // sync applying another Mac's settings (same path as config)
    case front(Int)           // app in front: -1 none, else app setup index
    case pause, resume
    case unplug(Int)          // 0: ups after removal, 1: before, 2: lost, 3: ups before and the removal callback never comes
    case lateValues           // the unplugged trackball's last HID values, delivered after its removal
    case reuse                // another mouse arrives at the unplugged trackball's address (the same key)
    case reconcile            // screen unlocked or the window opened: the engine checks the live devices
    /// Bits: 1-2 properties published late (1 name, 2 product and name, 3 everything), 4 not
    /// listed by IOHIDManager yet, 8 IOKit slow to register it, 16 second interface first,
    /// 32 a device check between the two adds, 64 an old interface's removal comes after.
    case replug(Int)
    case watch(Bool)          // the window or the menu opens (checks, then re-checks a quiet trackball) or closes
    case sleep, wake
    case tapOff(Int)          // this many events go by the switched-off tap
    case setMode(Int, Int)    // mode, wanted (0 off, 1 on, 2 toggle)
    case learn
    case practice(Bool)
    case displays(Int)
    case beta(Bool)
    case quit
    case standIn(Int)         // 0: the stand-in works, 1: macOS has no background-cursor switch, 2: the watchdog takes it down
    case esc                  // Esc pressed and let go (the Wheel's key tap sees it only while one is held)
    case wheelOverlay(Int)    // 0: the overlay can be drawn, 1: nothing to draw it with, 2: the watchdog takes it down
    /// The Switcher: 0 its panel works, 1 can't be drawn, 2 the watchdog takes it down, 3 nothing
    /// builds lists, 4 lists come at once, 5 after 0.4 s, 6 never; 7… the next lists have
    /// [0, 1, 2, 6, 13, 24, 40][n - 7] apps.
    case switcherPanel(Int)

    var description: String {
        switch self {
        case .kPress(let b, let h): "kPress(\(b)\(h ? "" : ", cgFirst"))"
        case .kRelease(let b, let h): "kRelease(\(b)\(h ? "" : ", cgFirst"))"
        case .kBall(let x, let y): "kBall(\(x),\(y))"
        case .kWheel(let t): "kWheel(\(t))"
        case .oPress(let b): "otherMousePress(\(b))"
        case .oRelease(let b): "otherMouseRelease(\(b))"
        case .oReleaseCGFirst(let b): "otherMouseRelease(\(b), cgFirst)"
        case .overlap(let b, let p):
            "sameButton(\(b), \([["kD oD oU kU", "kD oD kU oU", "oD kD oU kU", "oD kD kU oU", "kD kU oD oU", "oD oU kD kU"][(p & 7) % 6]])"
                + (p & 32 != 0 ? " trackpad" : "") + (p & 8 != 0 ? ", kD cgFirst" : "") + (p & 16 != 0 ? ", kU cgFirst" : "")
                + (p & 128 != 0 && p & 32 == 0 ? ", oU cgFirst" : "") + (p & 64 != 0 ? ", 4 ms apart" : "") + ")"
        case .replugHeld(let b, let m): "replugWithButtonHeld(\(b), \(["report before open", "report after add", "unreadable"][m % 3]))"
        case .oWheel(let t): "otherMouseWheel(\(t))"
        case .oBall: "otherMouseMove"
        case .padClick(let b): "trackpadClick(\(b))"
        case .padScroll: "trackpadScroll"
        case .padMove: "trackpadMove"
        case .keyboard(let f): "keyboardModifiers(0x\(String(f, radix: 16)))"
        case .wait(let t): String(format: "wait(%.3f)", t)
        case .config(let i): "settings(\(i))"
        case .remote(let i): "syncAppliesRemote(\(i))"
        case .front(let i): "appInFront(\(i))"
        case .pause: "pause"
        case .resume: "resume"
        case .unplug(let m): "unplug(\(["upsAfter", "upsBefore", "upsLost", "removalMissed"][m]))"
        case .lateValues: "lateValuesFromUnplugged"
        case .reuse: "otherMouseAtSameAddress"
        case .reconcile: "unlockOrWindowOpens"
        case .replug(let v):
            v == 0 ? "replug" : "replug(" + [(3, "properties late"), (4, "not listed yet"), (8, "not registered yet"), (16, "second interface first"),
                                             (32, "check between adds"), (64, "old removal after")]
                .filter { v & $0.0 != 0 }.map { $0.0 == 3 ? "\(["", "name", "product+name", "all"][v & 3]) \($0.1)" : $0.1 }.joined(separator: ", ") + ")"
        case .watch(let on): on ? "windowOpens" : "windowCloses"
        case .sleep: "sleep"
        case .wake: "wake"
        case .tapOff(let n): "tapSwitchedOffByMacOS(\(n) events lost)"
        case .setMode(let m, let w): "setMode(\(["precision", "ballScroll", "dragLock"][m]), \(["off", "on", "toggle"][w]))"
        case .learn: "quickAssignListens"
        case .practice(let on): "gesturePractice(\(on))"
        case .displays(let n): "displays(\(n))"
        case .beta(let on): "otherTrackballs(\(on))"
        case .quit: "quitAndRelaunch"
        case .standIn(let m): ["standInWorks", "standInUnavailable", "standInWatchdogTakesItDown"][m]
        case .esc: "escape"
        case .wheelOverlay(let m): ["wheelOverlayWorks", "wheelOverlayUnavailable", "wheelOverlayWatchdogTakesItDown"][m]
        case .switcherPanel(let m): m < 7 ? ["switcherWorks", "switcherCantDraw", "switcherWatchdogTakesItDown", "switcherNoLists",
                                             "switcherListsAtOnce", "switcherListsSlow", "switcherListsNever"][m]
                                          : "switcherApps(\(World.switcherCounts[m - 7]))"
        }
    }
}

// MARK: - Settings to fuzz with

func randomShortcut(_ r: inout RNG) -> KeyShortcut {
    r.pick([KeyShortcut.wisprFlow, .nextSpace, .missionControl, .copy, .zoomIn, .redo,
            KeyShortcut(keyCode: UInt16(r.int(128)), modifiers: r.pick([0, CGEventFlags.maskCommand.rawValue,
                        CGEventFlags([.maskShift, .maskAlternate]).rawValue]), keyName: "k")])
}

func randomPlainAction(_ r: inout RNG) -> ButtonAction {
    switch r.int(12) {
    case 0: return .system
    case 1: return .leftClick
    case 2: return .rightClick
    case 3: return .middleClick
    case 4: return r.chance(0.5) ? .back : .forward
    case 5: return .shortcut(randomShortcut(&r))
    case 6: return .holdShortcut(randomShortcut(&r))
    case 7: return .modifiedClick(button: r.int(5), modifiers: CGEventFlags.maskControl.rawValue)
    case 8: return .disabled
    case 9: return .media(r.pick(MediaKey.allCases))
    case 10: return .openApp(bundleID: "com.example.app")
    default: return r.chance(0.5) ? .precisionToggle : .dragLock
    }
}

func randomAction(_ r: inout RNG) -> ButtonAction {
    switch r.int(10) {
    case 0, 1, 2, 3: return randomPlainAction(&r)
    case 4: return .precisionHold
    case 5: return .precisionToggle
    case 6: return .ballScrollHold
    case 7: return .dragLock
    case 8:
        return r.chance(0.5) ? .wheel(randomWheel(&r)) : .switcher(randomSwitcher(&r))
    default:
        return .gesture(randomGesture(&r))
    }
}

/// A Switcher: its own click as the tap, or any other tap (hold-type ones too: they must never hold).
func randomSwitcher(_ r: inout RNG) -> AppSwitcher {
    r.chance(0.7) ? .standard : AppSwitcher(tap: randomAction(&r))
}

/// A Wheel: the standard one or slots remixed (hold-type actions too: they must never run),
/// four or eight, any ring job, sometimes its own tap.
func randomWheel(_ r: inout RNG) -> WheelMenu {
    var w = WheelMenu.standard
    w.eight = r.chance(0.4)
    for place in 0..<WheelMenu.places where r.chance(0.35) {
        w[place] = r.chance(0.15) ? nil : r.chance(0.1) ? r.pick([ButtonAction.precisionHold, .ballScrollHold, .dragLock]) : randomPlainAction(&r)
    }
    w.ring = r.pick(RingJob.allCases)
    if w.ring == .custom { w.ringUp = randomPlainAction(&r); w.ringDown = r.chance(0.8) ? randomPlainAction(&r) : nil }
    if r.chance(0.4) { w.tap = r.chance(0.3) ? randomAction(&r) : randomPlainAction(&r) }
    return w
}

/// A gesture: a preset or its directions remixed, each one chained (the default),
/// continuous or "once per hold", with its own distance or the global one.
func randomGesture(_ r: inout RNG) -> ButtonGesture {
    var g = r.pick([ButtonGesture.standard, .media, .tabs, .zoom])
    if r.chance(0.5) { g.tap = r.chance(0.3) ? randomAction(&r) : randomPlainAction(&r) }
    for d in GestureDirection.allCases where r.chance(0.35) {
        if r.chance(0.1) { g[d] = nil; continue }
        let mode = r.pick(GestureStep.Mode.allCases)
        g[d] = GestureStep(randomPlainAction(&r), repeats: mode == .continuous, once: mode == .once)
    }
    if r.chance(0.4) { g.distance = r.pick(GestureDistance.allCases) }
    return g
}

/// A number the way a setting might arrive: usually sensible, sometimes hostile.
func randomNumber(_ r: inout RNG, _ normal: ClosedRange<Double>) -> Double {
    if r.chance(0.9) { return r.double(normal.lowerBound, normal.upperBound) }
    return r.pick([Double.nan, .infinity, -.infinity, 1e308, -1e308, 0, -5, 1e6, .leastNonzeroMagnitude])
}

func randomConfig(_ r: inout RNG) -> GlideConfig {
    var c = GlideConfig()
    for b in 0...4 where r.chance(0.7) { c.buttons[b] = randomAction(&r) }   // button 0 too: it must be ignored
    if r.chance(0.05) { c.buttons[-1] = .rightClick; c.buttons[99] = .leftClick }
    for _ in 0..<r.int(4) {
        var set = Set<Int>()
        for _ in 0..<(2 + r.int(2)) { set.insert(r.int(5)) }
        // Gesture combos often (chained fires and their tuning, the first button up ends them).
        let action = r.chance(0.35) ? ButtonAction.gesture(randomGesture(&r)) : randomAction(&r)
        if set.count >= 2 || r.chance(0.1) { c.chords.append(Chord(buttons: set.sorted(), action: action)) }
    }
    // A combo with the primary button set to a gesture (only a file can say so): never a gesture.
    if r.chance(0.15) {
        let held: ButtonAction = r.chance(0.33) ? .wheel(randomWheel(&r)) : r.chance(0.5) ? .switcher(randomSwitcher(&r)) : .gesture(randomGesture(&r))
        c.chords.append(Chord(buttons: [0, 1 + r.int(4)], action: held))
    }
    if r.chance(0.6) { c = c.withoutPrimaryChords() }
    c.gesturesEnabled = r.chance(0.8)
    c.gestureDistance = r.pick(GestureDistance.allCases)
    c.gestureSteadyHands = r.chance(0.3)
    c.scrollMode = r.pick(ScrollMode.allCases)
    c.trackingSpeed = randomNumber(&r, 0.5...80)
    c.precisionSpeed = randomNumber(&r, 0.25...3)
    c.flyDistance = randomNumber(&r, 1...20)
    c.flyAcceleration = randomNumber(&r, 0...1.5)
    c.flyGlide = randomNumber(&r, 0...1)
    c.flyReach = randomNumber(&r, 0...1)
    c.scrollDistance = randomNumber(&r, 1...40)
    c.scrollSmoothness = randomNumber(&r, 0...1)
    c.scrollAcceleration = randomNumber(&r, 0...1)
    c.throwAmount = randomNumber(&r, 0...1)
    c.throwEnabled = r.chance(0.7)
    c.smoothScrolling = r.chance(0.8)
    c.reverseScroll = r.chance(0.3)
    c.ballScrollSpeed = randomNumber(&r, 0.25...4)
    c.nativeScrollSpeed = randomNumber(&r, 0...5)
    c.globalShortcuts.ballScroll = r.chance(0.5) ? KeyShortcut.make(kVK_ANSI_B, "B", [.maskControl, .maskCommand]) : nil
    c.displaySpeeds.enabled = r.chance(0.5)
    if r.chance(0.7) { c.displaySpeeds.speeds = ["d1": randomNumber(&r, 0.5...80), "d2": randomNumber(&r, 0.5...80)] }
    for i in 0..<r.int(3) {
        var p = AppProfile(bundleID: "app.\(i)", name: "App \(i)")
        if r.chance(0.5) { p.trackingSpeed = randomNumber(&r, 0.5...80) }
        if r.chance(0.5) { var b: [Int: ButtonAction] = [:]; for k in 0...4 where r.chance(0.5) { b[k] = randomAction(&r) }; p.buttons = b }
        if r.chance(0.3) { p.chords = [] }
        if r.chance(0.3) { var s = c.scrollSettings; s.scrollMode = r.pick(ScrollMode.allCases); s.flyGlide = randomNumber(&r, 0...1); p.scroll = s }
        c.appProfiles.append(p)
    }
    return c
}

/// Gestures on most buttons and combos (keeping the rest of `c`).
func gestureHeavy(_ c: GlideConfig, _ r: inout RNG) -> GlideConfig {
    var c = c
    c.gesturesEnabled = r.chance(0.95)
    func holdy() -> ButtonAction {
        r.chance(0.3) ? .wheel(randomWheel(&r)) : r.chance(0.4) ? .switcher(randomSwitcher(&r)) : .gesture(randomGesture(&r))
    }
    for b in 1...4 where r.chance(0.6) { c.buttons[b] = holdy() }
    for i in c.chords.indices where r.chance(0.6) { c.chords[i].action = holdy() }
    return c
}

extension GlideConfig {
    func withoutPrimaryChords() -> GlideConfig {
        var c = self
        c.chords.removeAll { $0.buttons.contains(0) }
        return c
    }
}

// MARK: - The world around the engine, and the rules

struct Failure: Error, CustomStringConvertible {
    let rule: String
    let detail: String
    var description: String { "[\(rule)] \(detail)" }
}

let expert = DeviceIdentity(vendorID: DeviceIdentity.kensingtonVendorID, productID: DeviceIdentity.expertMouseProductID,
                            name: "Kensington Expert Mouse")
let otherMouse = DeviceIdentity(vendorID: 0x046D, productID: 0xC077, name: "USB Optical Mouse")
let kKey = 1, oKey = 2
/// A shadow pointer: a driver's virtual device re-publishing every one of the trackball's
/// movements as a pointer of its own, with no vendor (as Levi's log showed a "vendor ?" device
/// beside the trackball, beta 17). Unsupported, so its movement looks like another mouse's.
let echoKey = 900
let virtualPointer = DeviceIdentity(vendorID: 0, productID: 0, name: "Virtual pointer")
/// Whether the next World has the shadow pointer (half the seeds, and the cases that ask for it).
var echoShadow = false
/// Whether Worlds keep `outLog` (the regression cases; random seeds don't need it).
var keepOutLog = false

enum Source { case kensington, other, trackpad, keyboard }

struct InputInfo {
    var source: Source
    var button: Int
    var type: CGEventType
    var flags: CGEventFlags
    var time: Double
}

final class World {
    let io = FakeIO()
    var engine: Engine
    let configs: [GlideConfig]
    var mainConfig: GlideConfig
    var enabled = true
    var front = -1
    var quitDone = false

    // The hardware.
    var kConnected = true
    var kDown = Set<Int>()
    var oDown = Set<Int>()
    var padDown = Set<Int>()
    var kReportsButtons = false
    var kLastHIDDown: [Int: Double] = [:]
    var stamp: UInt64 = 1
    var nextID = 1
    var inputs: [Int: InputInfo] = [:]
    var bypass = 0
    var learning = false
    var watched = false   // the window or the menu is open (as the engine was told)
    var stale = false    // the trackball left but the engine was never told (a missed removal)
    var reused = false   // another mouse has the trackball's key
    // The trackball's two HID devices (its mouse interface, and a second one like a vendor
    // interface), by registry entry ID. A replug can re-enumerate with new IDs.
    var kKey = 1
    var kAux = 1001
    var nextKey = 3
    /// Gone devices IOHIDManager still lists (a removal it never heard of, or one whose
    /// callback is running right now).
    var ghosts: [Int: DeviceIdentity] = [:]
    var replugs = 0   // every other one comes back over Bluetooth (battery checks)
    // Each device's IOHIDDevice object, by address. A freed object's address is handed to the
    // next one (most recently freed first), as malloc does; its late values still carry it.
    var addrOf: [Int: Int] = [:]
    var lastAddr: [Int: Int] = [:]
    var freeAddrs: [Int] = []
    var nextAddr = 0x10_000
    // The latest replug, as IOKit publishes it: properties, the manager's list and the
    // registry can each lag the add callback for a moment.
    var partial: DeviceIdentity?
    var identityAt = -1e9, listAt = -1e9, aliveAt = -1e9
    var plugGraceUntil = -1e9   // until then "connected" and "works" aren't judged
    var oddReplug = false       // the latest replug was published late in some way (Op.replug bits 1-8)
    var holdDisturbed = false   // the trackball moved during such a replug while the pointer was held
    var holdCheckAt: Double?    // a held pointer moved with nothing after it: back on its anchor by then
    let echo = echoShadow       // the shadow pointer echoes the trackball's every movement
    var lastKMoveAt = -1e9      // the trackball's latest HID movement
    var lastOMoveAt = -1e9      // another mouse's latest HID movement
    var lastFrameAt = -1e9      // the scroll engine's last frame, for the display link's cadence
    /// While such a replug settles, a check can take the trackball out and put it back
    /// mid-press (IOKit not done registering it), so button pairing can't be judged.
    var settling: Bool { oddReplug && io.clock < plugGraceUntil }

    // What apps see.
    var appK: [Int: Int] = [:]          // Kensington-side buttons down (engine-processed and raw)
    var tainted = Set<Int>()            // a raw (tap-off) event touched this button
    var taintedO = Set<Int>()           // ...another device's button (judged apart from the trackball's)
    var passedThrough = Set<Int>()
    var heldThroughRelaunch = Set<Int>()      // down because the trackball's own press of it passed: macOS's state
    var heldReadable = true                   // the engine can read the trackball's held buttons (EngineIO.heldButtons)
    var appO: [Int: Int] = [:]
    var keysDown: [UInt16: Int] = [:]
    var modifierEvents: [UInt16: Int] = [:]
    var outCount: [Int: Int] = [:]
    var lastOut: [Int: (type: CGEventType, button: Int64, flags: CGEventFlags)] = [:]
    var swallowedOther = Set<Int>()     // other-mouse buttons whose press a drag lock took
    var graceUntil = 0.0                // releases may be lost until the failsafe has had its chance
    var pendingPrimary: [(id: Int, deadline: Double)] = []
    var justPressedPrimary: Int?
    var modes = Engine.Modes()
    var scrollMuted = false
    var lastScrollInput = -1e9
    var scrollOut = 0.0
    var violations: [Failure] = []
    var connected = false   // what the engine's status says
    // The gesture hold now (or the last one): see `observe(_:)`.
    var hold: (buttons: [Int], gesture: ButtonGesture?, tuning: GestureTuning?, start: Double,
               l1: Double, x: Double, y: Double, maxL2: Double, fires: Int, byDirection: [GestureDirection: Int])?
    var lastFlashSeq = 0
    var gestureFires = 0, chainedFires = 0, gestureTaps = 0, gestureHolds = 0
    // The Wheel hold now (or the last one): see `observe(_:)`.
    var wheelHold: (buttons: [Int], ringSteps: [Double], picks: Int, dismissed: Bool, ringTurned: Bool)?
    var lastWheelSeq = 0
    var wheelHolds = 0, wheelPicks = 0, wheelRingSteps = 0, wheelTaps = 0, wheelOverlays = 0
    // The Switcher hold now (or the last one): see `observe(_:)`.
    var switcherHold: (buttons: [Int], switched: Int, dismissed: Bool, ringTurned: Bool, rolled: Bool, shown: Bool)?
    var lastSwitcherSeq = 0
    var switcherHolds = 0, switcherSwitches = 0, switcherTaps = 0, switcherPanels = 0
    static let switcherCounts = [0, 1, 2, 6, 13, 24, 40]

    static let modifierCodes: Set<UInt16> = [UInt16(kVK_Control), UInt16(kVK_Option), UInt16(kVK_Shift), UInt16(kVK_Command)]

    init(configs: [GlideConfig]) {
        self.configs = configs
        mainConfig = configs[0]
        engine = Engine(config: configs[0], io: io)
        wire()
        engine.startInline()
        add(kKey, expert, transport: "USB")
        add(kAux, expert, transport: "USB")
        add(oKey, otherMouse, transport: "USB")
        if echo { add(echoKey, virtualPointer, transport: "Virtual") }
        settle()
    }

    /// IOHIDManager matched a device: a new object (at a recycled address if one is free).
    func add(_ k: Int, _ identity: DeviceIdentity, transport: String) {
        let a = freeAddrs.popLast() ?? { nextAddr += 0x40; return nextAddr }()
        addrOf[k] = a
        engine.managerAdded(address: a, key: k, identity: identity, transport: transport)
    }

    /// IOHIDManager's removal callback for device `k`; its object is freed after it.
    func remove(_ k: Int) {
        let a = addrOf[k] ?? lastAddr[k] ?? -k
        engine.managerRemoved(address: a, fresh: k)
        if addrOf.removeValue(forKey: k) != nil { freeAddrs.append(a) }
        lastAddr[k] = a
    }

    /// A device's properties as IOKit has them now.
    func identityOf(_ k: Int) -> DeviceIdentity {
        if k == oKey { return otherMouse }
        if k == echoKey { return virtualPointer }
        if reused && k == kKey && !kConnected { return otherMouse }
        if kConnected, k == kKey || k == kAux, let p = partial, io.clock < identityAt { return p }
        return expert
    }

    func wire() {
        engine.onModes = { [unowned self] m in self.observe(m) }
        engine.onStatus = { [unowned self] s in self.connected = s.deviceConnected }
        io.live = { [unowned self] in
            var d = self.ghosts
            d[oKey] = otherMouse
            if self.echo { d[echoKey] = virtualPointer }
            if self.kConnected {
                if self.io.clock >= self.listAt { d[self.kKey] = self.identityOf(self.kKey); d[self.kAux] = self.identityOf(self.kAux) }
            } else if self.reused { d[self.kKey] = otherMouse }
            return d
        }
        io.alive = { [unowned self] k in
            k == oKey || (self.echo && k == echoKey) || (self.kConnected && (k == self.kKey || k == self.kAux) && self.io.clock >= self.aliveAt) || (self.reused && k == self.kKey)
        }
        io.identityNow = { [unowned self] k in self.identityOf(k) }
        io.appButtons = { [unowned self] in
            Set(self.appK.filter { $0.value > 0 }.keys.map(Int64.init)).union(self.appO.filter { $0.value > 0 }.keys.map(Int64.init))
        }
        io.held = { [unowned self] k in
            guard self.heldReadable, self.kConnected, k == self.kKey || k == self.kAux else { return nil }
            return k == self.kKey ? Set(self.kDown.map(Int64.init)) : []
        }
        engine.scroller.output = { [unowned self] d in
            if self.modes.wheelHeld, d != 0 { self.fail("wheel", "the ring scrolled \(d) points while a Wheel is held") }
            if self.modes.switcherHeld, d != 0 { self.fail("switcher", "the ring scrolled \(d) points while a Switcher is held") }
            self.scrolled(abs(d))
        }
        engine.scroller.ballOutput = { [unowned self] x, y in self.scrolled((x * x + y * y).squareRoot()) }
        io.onApply = { [unowned self] s in
            if !self.enabled { self.fail("pointer", "Glideball's pointer speed was applied while paused") }
            if self.quitDone { self.fail("pointer", "Glideball's pointer speed was applied after quitting") }
            if !s.trackingSpeed.isFinite || s.trackingSpeed < 0.25 || s.trackingSpeed > 80 {
                self.fail("pointer", "tracking speed \(s.trackingSpeed) is outside the app's limits")
            }
            if let sc = s.scrollSpeed, !sc.isFinite || sc < 0 || sc > 5 { self.fail("pointer", "native scroll speed \(sc)") }
        }
    }

    /// The engine can't tell whose a press is: macOS doesn't say which device a click came from,
    /// and until the trackball has reported a button over HID the engine goes by the last active
    /// device. (Another mouse or the trackpad pressing a button number the trackball holds is
    /// judged: the engine matches each press to its device by the HID reports, `Engine.handleButton`.)
    /// Also set while a replug settles and for events lost to a switched-off tap that leave
    /// apps' state unknowable. Until every button is up again, button pairing isn't judged.
    /// Keys still are.
    var ambiguous = false

    func fail(_ rule: String, _ detail: String) {
        if ambiguous && (rule == "paired" || rule == "others" || (rule == "released" && detail.hasPrefix("button"))) { return }
        violations.append(Failure(rule: rule, detail: detail))
    }

    /// Before the trackball's first HID button report, another device's press of the same
    /// button can be taken for the trackball's (the engine goes by the last active device).
    func markAmbiguity(kensington b: Int) {
        if !kReportsButtons && (oDown.contains(b) || (appO[b] ?? 0) > 0) { ambiguous = true }
    }

    func markAmbiguity(other b: Int) {
        if !kReportsButtons || kRawHeld.contains(b) { ambiguous = true }
    }

    /// The trackball's buttons held whose presses the engine never saw (past a switched-off tap,
    /// across a relaunch, plugged in held). If another device holds the same button too, apps
    /// have it down once for both as far as anyone can ask macOS, so which release is "its"
    /// can't be judged.
    var kRawHeld = Set<Int>()
    var taintedWhileOff = Set<Int>()
    var lastKReleaseAt = -1e9
    /// Other devices' buttons whose presses went by a switched-off tap. macOS counts a button
    /// once however many devices hold it, so with the trackball's side holding it too (its own
    /// press or a button remapped to it), whose release that one is can't be judged per device.
    var oRawHeld = Set<Int>()
    func oRawReleased(_ b: Int, trackpad: Bool = false) {
        // (Or another mouse holds it too: the engine can take this release for that one's.)
        if oRawHeld.remove(trackpad ? b + 1000 : b) != nil, (appK[b] ?? 0) > 0 || kDown.contains(b) || kRawHeld.contains(b)
            || io.clock - lastKReleaseAt < 0.11 || (trackpad && oDown.contains(b)) { ambiguous = true }
    }
    func rawHeld(_ b: Int) {
        kRawHeld.insert(b)
        if oDown.contains(b) || (appO[b] ?? 0) > 0 { ambiguous = true }
    }

    /// Another device's releases the engine holds back (at most `Engine`'s 0.1 s) while it waits
    /// for a HID report to say whose they are: judged when they come out.
    var awaiting: [Int: (deadline: Double, before: (type: CGEventType, button: Int64, flags: CGEventFlags))] = [:]
    /// What apps saw, in order (button presses and releases, keys): for the regression cases.
    var outLog: [String] = []

    var resolved: GlideConfig {
        var c = mainConfig.resolved(for: front >= 0 ? "app.\(front)" : nil)
        c.enabled = enabled
        return c
    }

    func scrolled(_ d: Double) {
        guard d != 0 else { return }
        if tracing { print(String(format: "        scrolled %.0f pt at +%.3f s", d, io.clock - lastScrollInput)) }
        if !d.isFinite { fail("scrolling", "a scroll of \(d) points") }
        // Smooth: at most the flywheel's top speed (72,000 pt/s) for the longest frame (1/30 s).
        // Smooth scrolling off: one tick at the fastest the trackball can report.
        if d > (engine.scroller.config.smoothScrolling ? 2_500 : 4_500) { fail("scrolling", "one frame scrolled \(Int(d)) points (runaway)") }
        if scrollMuted { fail("scrolling", "scrolled \(d) points after a pause, unplug or sleep, with no new input") }
        if d >= 2, io.clock - lastScrollInput > 4 { fail("scrolling", "still scrolling \(String(format: "%.1f", io.clock - lastScrollInput)) s after the last input") }
        scrollOut += d
    }

    // MARK: Events in

    func newID(_ info: InputInfo) -> Int {
        nextID += 1
        inputs[nextID] = info
        return nextID
    }

    func mouseEvent(_ type: CGEventType, button: Int, id: Int) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: io.cursor,
                        mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)!
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        e.setIntegerValueField(srcField, value: Int64(id))
        e.flags = io.kbFlags
        return e
    }

    static func type(_ button: Int, _ phase: Int) -> CGEventType {   // phase 0 down, 1 up, 2 drag
        switch (button, phase) {
        case (0, 0): .leftMouseDown
        case (0, 1): .leftMouseUp
        case (0, _): .leftMouseDragged
        case (1, 0): .rightMouseDown
        case (1, 1): .rightMouseUp
        case (1, _): .rightMouseDragged
        case (_, 0): .otherMouseDown
        case (_, 1): .otherMouseUp
        default: .otherMouseDragged
        }
    }

    func hid(_ key: Int, page: Int, usage: Int, value: Int) {
        stamp += 1
        let before = engine.supportedValues
        engine.hidInput(address: addrOf[key] ?? lastAddr[key] ?? -key, fresh: key, identity: identityOf(key),
                        page: page, usage: usage, value: value, stamp: stamp)
        // A plugged-in trackball works: once IOKit has published it, every value counts.
        if key == kKey, kConnected, !stale, io.clock >= plugGraceUntil, engine.supportedValues == before {
            fail("works", "the trackball is plugged in, but the engine dropped its value (page \(page), usage \(usage))")
        }
        if key == kKey && page == kHIDPage_Button && value != 0 {
            // As the engine: a press over HID (not just a release) that reached it as the trackball's.
            if engine.supportedValues != before { kReportsButtons = true }
            kLastHIDDown[usage - 1] = io.clock
        }
    }

    /// An event reaching the session: through the engine's tap if it's on and wants it,
    /// otherwise straight to apps (`raw`).
    func deliver(_ e: CGEvent, source: Source) {
        let type = e.type
        if bypass > 0, io.sees(io.mainTap, type) || (type == .mouseMoved && io.moveTap != nil) || ((type == .keyDown || type == .keyUp) && io.keyTap != nil) {
            // The tap was switched off by macOS: this one goes by untouched. Then macOS
            // tells the engine, which switches it back on.
            bypass -= 1
            // The engine misses this one. Apps see it as it is (`emit` counts it), and the engine
            // must cope when the tap comes back: a press it never saw, a release it never saw.
            emit(e, raw: true)
            if bypass == 0 { tapComesBack() }
            return
        }
        let tap = type == .mouseMoved ? io.moveTap : (type == .keyDown || type == .keyUp) ? io.keyTap : io.mainTap
        guard io.sees(tap, type) else { return emit(e, raw: true) }
        let before = (type: e.type, button: e.getIntegerValueField(.mouseEventButtonNumber), flags: e.flags)
        let dragLockedBefore = modes.dragLocked
        let out = engine.handle(type, e)
        if let out { emit(out.takeUnretainedValue(), raw: false) }
        if source == .other || source == .trackpad, let id = Optional(Int(e.getIntegerValueField(srcField))), id != 0 {
            settle()   // it may come out a moment later, behind a release the engine posts first
            checkUntouched(id: id, before: before, out: lastOut[id], dragLockedBefore: dragLockedBefore)
        }
    }

    func tapComesBack() {
        guard let t = io.mainTap else { return }
        settle()   // what the engine decided while it was off (it couldn't see what went by) goes first
        let e = CGEvent(source: nil)!
        io.tapEnable(t, false)
        if let m = io.moveTap { io.tapEnable(m, false) }
        if let k = io.keyTap { io.tapEnable(k, false) }
        _ = engine.handle(.tapDisabledByTimeout, e)
        graceUntil = io.clock + 1.0
        tainted.subtract(taintedWhileOff)   // the engine has asked macOS what's down: judged again
        taintedWhileOff.removeAll()
        // While the tap was off the pointer moved freely (never stuck); a hold that's still
        // on keeps it where it is now, rather than jumping it back.
        if io.frozen { io.anchorExpect = io.cursor }
    }

    /// Other mice and the trackpad: what went in comes out, once, unchanged.
    func checkUntouched(id: Int, before: (type: CGEventType, button: Int64, flags: CGEventFlags),
                        out: (type: CGEventType, button: Int64, flags: CGEventFlags)?, dragLockedBefore: Bool) {
        guard let info = inputs[id] else { return }
        let b = info.button
        // Ambiguous by design: the trackball hasn't reported a button over HID yet, so the
        // engine goes by the last active device. The press that ends a drag lock (and its
        // release) is the lock's.
        let kAmbiguous = !kReportsButtons
        let sb = info.source == .trackpad ? b + 1000 : b   // per device: the mouse's and the trackpad's
        if before.type == .leftMouseDown || before.type == .rightMouseDown || before.type == .otherMouseDown {
            if dragLockedBefore && (b == 0 || before.type == .leftMouseDown) { swallowedOther.insert(sb); return }
        }
        if before.type == .leftMouseUp || before.type == .rightMouseUp || before.type == .otherMouseUp, swallowedOther.contains(sb) {
            swallowedOther.remove(sb); return
        }
        if before.type == .leftMouseDragged || before.type == .rightMouseDragged || before.type == .otherMouseDragged, swallowedOther.contains(sb) { return }
        // A drag lock holds the left button for every mouse: a plain move is its drag.
        if before.type == .mouseMoved, dragLockedBefore, out?.type == .leftMouseDragged { return }
        // A drag of a button the trackball holds too, within 30 ms of the ball moving: whose
        // movement it is can't be told (Engine.echoWindow: a driver's echo looks the same).
        if [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(before.type),
           kDown.contains(b), io.clock - lastKMoveAt < Engine.echoWindow || oRawHeld.contains(b) { return }
        // (Or of a press the engine never saw, while the trackball holds that button too: macOS
        // counts the button once for both, so the engine can't know someone else holds it.)
        if kAmbiguous { tainted.insert(b); taintedO.insert(b); return }
        guard let out else {
            // A release may be held back a moment while the engine waits to see whose it is.
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(before.type) {
                awaiting[id] = (io.clock + 0.11, before)
                return
            }
            return fail("others", "\(info.source) \(before.type.rawValue) of button \(b) was swallowed")
        }
        if out.type != before.type || out.button != before.button || out.flags != before.flags {
            fail("others", "\(info.source) event \(before.type.rawValue)/\(before.button) came out as \(out.type.rawValue)/\(out.button)")
        }
    }

    // MARK: Events out

    func emit(_ e: CGEvent, raw: Bool) {
        if tracing {
            print("        out \(raw ? "raw " : "")type \(e.type.rawValue) button \(e.getIntegerValueField(.mouseEventButtonNumber)) key \(e.getIntegerValueField(.keyboardEventKeycode)) src #\(e.getIntegerValueField(srcField))\(e.getIntegerValueField(.eventSourceUserData) == Engine.syntheticTag ? " (Glideball's)" : "")")
        }
        let id = Int(e.getIntegerValueField(srcField))
        let synthetic = e.getIntegerValueField(.eventSourceUserData) == Engine.syntheticTag
        let info = id != 0 ? inputs[id] : nil
        if id != 0, !raw {
            lastOut[id] = (e.type, e.getIntegerValueField(.mouseEventButtonNumber), e.flags)
            outCount[id, default: 0] += 1
            if outCount[id]! > 1 { fail("paired", "input #\(id) reached apps \(outCount[id]!) times") }
        }
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let b = Int(e.getIntegerValueField(.mouseEventButtonNumber))
            let phase: Int = switch e.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: 0
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: 1
            default: 2
            }
            // The primary button: always button 0, a left click.
            if let info, info.source == .kensington, info.button == 0 {
                if b != 0 || (e.type != .leftMouseDown && e.type != .leftMouseUp && e.type != .leftMouseDragged) {
                    fail("primary", "the primary button came out as button \(b) (type \(e.type.rawValue))")
                }
                if phase == 0 { pendingPrimary.removeAll { $0.id == id } }
            }
            let isOther = info.map { $0.source == .other || $0.source == .trackpad } ?? false
            if phase != 2 && keepOutLog {
                let who = info.map { "\($0.source)" } ?? (synthetic ? "glideball" : "?")
                outLog.append("\(who) \(phase == 0 ? "down" : "up") \(b)\(raw ? " raw" : "")")
            }
            if isOther {
                switch phase {
                case 0:
                    if raw { oRawHeld.insert(info?.source == .trackpad ? b + 1000 : b) }
                    appO[b, default: 0] += 1
                case 1:
                    // Another device's press and release always reach apps as a pair (unless the
                    // release went past a switched-off tap: macOS's doing).
                    if (appO[b] ?? 0) == 0 && raw { taintedO.insert(b) }
                    // Its release past a switched-off tap while the trackball holds the same
                    // button: its HID report afterwards looks like a release still to come.
                    if raw, kDown.contains(b) || (appK[b] ?? 0) > 0 { ambiguous = true }
                    if (appO[b] ?? 0) == 0 && !taintedO.contains(b) { fail("others", "another device's release of button \(b) reached apps without its press") }
                    appO[b] = max(0, (appO[b] ?? 0) - 1)
                    if appO[b] == 0 && !raw && !oDown.contains(b) { taintedO.remove(b) }
                default: break
                }
                return
            }
            let down = appK[b] ?? 0
            switch phase {
            case 0:
                if let info, info.source == .kensington, info.button == b { passedThrough.insert(b) }   // as is, or replayed after a combo wait
                // A press macOS delivered past a switched-off tap: apps see it as it is. Judged
                // like any other, except onto a button they already have down (that's macOS's).
                if raw { if down > 0 { tainted.insert(b) } }
                else if down > 0 && !tainted.contains(b) { fail("paired", "button \(b) went down twice") }
                if raw, info?.source == .kensington { rawHeld(b) }
                // Until the tap is back the engine can't know apps have this one down (a remap
                // onto it meanwhile is a second press it couldn't have avoided).
                if raw, !tainted.contains(b) { tainted.insert(b); taintedWhileOff.insert(b) }
                appK[b] = down + 1
            case 1:
                let ownPassed = passedThrough.remove(b) != nil
                // A release past the switched-off tap whose press apps never saw (Glideball had
                // mapped it): macOS's doing, not the engine's. (Apps may have the button down for
                // something else, a button remapped to it, which this release then lets go of.)
                // (After an unplug, both macOS's release and the engine's letting go of what the
                // press held can reach apps.)
                if raw { if down == 0 || !kConnected || (info?.source == .kensington && !ownPassed && !kRawHeld.contains(b)) { tainted.insert(b) } }
                else if down == 0 && !tainted.contains(b) { fail("paired", "button \(b) came up without going down") }
                // The trackball's release past a switched-off tap while another device holds the
                // same button: its HID report, arriving after the tap is back, looks like a release
                // still to come, and the other device's release can be taken for it.
                if raw, info?.source == .kensington, oDown.contains(b) || (appO[b] ?? 0) > 0 { ambiguous = true }
                // (The trackball's own raw release of a press Glideball had mapped pairs with
                // nothing apps saw: what they have down, a button remapped to this one, stays.)
                let unpaired = raw && info?.source == .kensington && info?.button == b && !ownPassed && !kRawHeld.contains(b) && kConnected
                if !unpaired { appK[b] = max(0, down - 1) }
                // (Not while another device's side of the button is still unknowable: what the
                // engine made of that can still decide whose a later release is.)
                if appK[b] == 0 && !raw && !kDown.contains(b) && !taintedO.contains(b) { tainted.remove(b) }
            default:
                if !raw && down == 0 && (appO[b] ?? 0) == 0 && !tainted.contains(b) {
                    fail("paired", "button \(b) dragged without being down")
                }
            }
        case .keyDown, .keyUp:
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
            if keepOutLog { outLog.append("key \(e.type == .keyDown ? "down" : "up") \(code)") }
            if e.type == .keyDown { keysDown[code, default: 0] += 1 }
            else {
                if (keysDown[code] ?? 0) == 0 { fail("released", "key \(code) came up without going down") }
                keysDown[code] = max(0, (keysDown[code] ?? 0) - 1)
            }
        case .flagsChanged where synthetic:
            break
        default:
            break
        }
        // The primary press that lets go of a drag lock (one that may have started a moment
        // before, from a button waiting for a combo partner): the lock's release is its click.
        if synthetic, e.type == .leftMouseUp, let p = justPressedPrimary { pendingPrimary.removeAll { $0.id == p } }
        switch e.type {
        case .flagsChanged where synthetic:
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
            modifierEvents[code, default: 0] += 1
        default:
            break
        }
    }

    /// Delivers what the engine posted (through its own tap, as macOS does), runs the
    /// key queue, and the main thread's callbacks — until nothing is left.
    func settle() {
        var rounds = 0
        io.deliverLists()
        while !io.posted.isEmpty || !io.keyWork.isEmpty || !io.mainWork.isEmpty {
            rounds += 1
            if rounds > 10_000 { fail("hang", "the engine keeps posting"); break }
            if !io.posted.isEmpty {
                let e = io.posted.removeFirst()
                deliverPosted(e)
            } else if !io.keyWork.isEmpty {
                io.keyWork.removeFirst()()
            } else {
                io.mainWork.removeFirst()()
            }
        }
    }

    func deliverPosted(_ e: CGEvent) {
        let type = e.type
        if io.sees(io.mainTap, type) {
            let out = engine.handle(type, e)
            if let out { emit(out.takeUnretainedValue(), raw: false) }
            else { fail("paired", "the engine swallowed its own posted event (type \(type.rawValue))") }
        } else {
            emit(e, raw: false)
        }
    }

    /// Lets virtual time pass: timers fire and the scroll engine draws its frames.
    func advance(_ dt: Double) {
        settle()   // (an op that returned early may have left posts undelivered)
        let end = io.clock + dt
        while true {
            let nextTimer = io.timers.filter(\.valid).min { ($0.fireAt, $0.order) < ($1.fireAt, $1.order) }
            // The display link ticks every 1/120 s whatever the input does (it used to be counted
            // from each wait's start, so a run of short waits drew no frames at all).
            let nextFrame = engine.scroller.wantsFrames ? max(io.clock, lastFrameAt + 1.0 / 120) : Double.infinity
            let nextList = io.pendingLists.map(\.due).min() ?? .infinity
            let t = min(nextTimer?.fireAt ?? .infinity, nextFrame, nextList)
            guard t <= end else { break }
            io.clock = max(io.clock, t)
            if nextList <= t {
                io.deliverLists()
            } else if let timer = nextTimer, timer.fireAt <= t {
                if timer.repeats { timer.fireAt += max(timer.interval, 0.001) } else { timer.valid = false }
                if tracing { print(String(format: "        (timer #%d, every %.3f s, at +%.3f)", timer.order, timer.interval, io.clock - lastScrollInput)) }
                timer.body()
            } else {
                lastFrameAt = io.clock
                engine.scroller.frame(at: io.clock)
            }
            settle()
            checkTimed()
        }
        io.timers.removeAll { !$0.valid }
        io.clock = end
        checkTimed()
    }

    // MARK: Ops

    func push() {
        engine.update(resolved)
    }

    func apply(_ op: Op) {
        if tracing { print("      \(op)   [modes \(modes.precision ? "P" : "")\(modes.ballScrolling ? "S" : "")\(modes.dragLocked ? "D" : "")\(modes.gestureHeld ? "G" : "") frozen \(io.frozen) kDown \(kDown.sorted())]") }
        guard !quitDone || { if case .quit = op { return false }; return true }() else { return }
        switch op {
        case .kPress(let b, let hidFirst):
            guard kConnected, !kDown.contains(b) else { return }
            markAmbiguity(kensington: b)
            if settling { ambiguous = true }
            kDown.insert(b)
            let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
            if hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 1) }
            let lostBefore = bypass > 0
            if b == 0, enabled, !lostBefore, !learning, !modes.dragLocked,
               !resolved.chords.contains(where: { $0.buttons.contains(0) }), io.mainTap != nil {
                pendingPrimary.append((id, io.clock + 0.2))
                justPressedPrimary = id
            }
            deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .kensington)
            settle()
            justPressedPrimary = nil
            if !hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 1) }
        case .kRelease(let b, let hidFirst):
            guard kConnected, kDown.contains(b) else { return }
            heldThroughRelaunch.remove(b)
            kRawHeld.remove(b)
            lastKReleaseAt = io.clock
            kDown.remove(b)
            let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
            if hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
            deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .kensington)
            if !hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
        case .kBall(let dx, let dy):
            guard kConnected else { return }
            noteScrollInput()   // Scroll with ball, if it's on
            // How macOS delivers this move while the pointer is held. Nothing guarantees the
            // order of IOHIDManager's value callback and the tap's event, nor that the tap sees
            // the move at all (beta 14 on real hardware: the gesture fired, so the HID values
            // arrived, but the pointer moved the whole time). Picked from the move itself, so a
            // minimized replay delivers it the same way:
            //   0: HID, then the pointer moves, then the tap's event (a drag with a button down)
            //   1: the pointer moves and the tap's event comes first, HID after
            //   2: HID, then the pointer moves, and the tap never sees the move
            //   3: HID, the pointer moves, then a plain move instead of the held button's drag
            // Unheld, every move is delivered the first way.
            let delivery = io.frozen ? ((dx &* 31 &+ dy &* 17) % 4 + 4) % 4 : 0
            func sendHID() {
                // The shadow pointer's copy of this movement, just before or just after the
                // trackball's own values (IOHIDManager gives no order between two devices).
                let echoFirst = (dx &+ dy) & 1 == 0
                func sendEcho() {
                    guard echo, kConnected else { return }
                    if dx != 0 { hid(echoKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: dx) }
                    if dy != 0 { hid(echoKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Y, value: dy) }
                }
                if echoFirst { sendEcho() }
                if dx != 0 { gestureTravel(dx, 0); hid(kKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: dx) }
                if dy != 0 { gestureTravel(0, dy); hid(kKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Y, value: dy) }
                if !echoFirst { sendEcho() }
                // Another mouse that moved within 30 ms of the trackball (either way round) moved
                // with it: which of the pointer's movement is whose can't be told, so the engine
                // takes it as the trackball's (put back) and that hold isn't judged.
                if dx != 0 || dy != 0 {
                    if io.frozen, io.clock - lastOMoveAt < Engine.echoWindow { holdDisturbed = true }
                    lastKMoveAt = io.clock
                }
            }
            func movePointer() {
                do { io.cursor.x = min(max(io.cursor.x + CGFloat(dx), 0), 3000); io.cursor.y = min(max(io.cursor.y + CGFloat(dy), 0), 1000) }
            }
            func sendTapEvent(drag: Bool) {
                if drag, let b = kDown.min() {
                    let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 2), flags: io.kbFlags, time: io.clock))
                    deliver(mouseEvent(World.type(b, 2), button: b, id: id), source: .kensington)
                } else if io.moveTap != nil {
                    let id = newID(InputInfo(source: .kensington, button: 0, type: .mouseMoved, flags: io.kbFlags, time: io.clock))
                    deliver(mouseEvent(.mouseMoved, button: 0, id: id), source: .kensington)
                }
            }
            checkTimed()   // an earlier move's deadline that has come is judged before this move lands
            let bypassBefore = bypass
            var checkLater = false
            defer {
                // Held means held, in any app: checked where it counts, the pointer after the
                // tap has had the trackball's move (unless macOS had the tap off for it).
                // (Not while a replug is still being published: properties missing, or IOKit not
                // done registering it, nothing yet says it's the trackball.)
                // A hold such a move went through can't be judged until it ends.
                if !io.frozen { holdDisturbed = false } else if settling { holdDisturbed = true }
                if checkLater {
                    // Nothing came after the move for the engine to act on at once: the pointer
                    // must be back within a few milliseconds (before the next frame shows it).
                    if io.frozen, bypass == bypassBefore, bypass == 0, !holdDisturbed {   // 12 ms from the latest such move
                        holdCheckAt = io.clock + 0.012
                    }
                } else if io.frozen, bypass == bypassBefore, bypass == 0, !holdDisturbed, let a = io.anchorExpect, io.cursor != a {
                    fail("modes", "the pointer moved while held (\(io.foreground ? "Glideball in front" : "another app in front")): \(a) → \(io.cursor)")
                }
            }
            switch delivery {
            case 1: movePointer(); sendTapEvent(drag: true); sendHID()
            case 2: sendHID(); movePointer(); checkLater = true
            case 3: sendHID(); movePointer(); sendTapEvent(drag: false); checkLater = io.moveTap == nil
            default: sendHID(); movePointer(); sendTapEvent(drag: true)
            }
        case .kWheel(let t):
            guard kConnected else { return }
            noteScrollInput()
            hid(kKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: t)
            let id = newID(InputInfo(source: .kensington, button: -1, type: .scrollWheel, flags: io.kbFlags, time: io.clock))
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(t), wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(srcField, value: Int64(id))
            e.flags = io.kbFlags
            deliver(e, source: .kensington)
        case .oPress(let b):
            guard !oDown.contains(b) else { return }
            markAmbiguity(other: b)
            oDown.insert(b)
            othersKeep("another mouse's press of button \(b)", b) {
                hid(oKey, page: kHIDPage_Button, usage: b + 1, value: 1)
                let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .other)
            }
        case .oRelease(let b), .oReleaseCGFirst(let b):
            guard oDown.contains(b) else { return }
            markAmbiguity(other: b)
            oRawReleased(b)
            oDown.remove(b)
            var cgFirst = false
            if case .oReleaseCGFirst = op { cgFirst = true }
            othersKeep("another mouse's release of button \(b)", b) {
                if !cgFirst { hid(oKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
                let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .other)
                if cgFirst { hid(oKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
            }
        case .oWheel(let t):
            hid(oKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: t)
            let id = newID(InputInfo(source: .other, button: -1, type: .scrollWheel, flags: io.kbFlags, time: io.clock))
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(t), wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(srcField, value: Int64(id))
            deliver(e, source: .other)
            if let out = lastOut[id], out.type != .scrollWheel { fail("others", "another mouse's scroll came out as type \(out.type.rawValue)") }
        case .oBall:
            // Another mouse moving within the few milliseconds a trackball move is still being put
            // back: which part of the pointer's offset is whose can't be told, so that hold isn't judged.
            if holdCheckAt != nil { holdDisturbed = true }
            if io.frozen, io.clock - lastKMoveAt < Engine.echoWindow { holdDisturbed = true }
            lastOMoveAt = io.clock
            hid(oKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: 3)
            do {   // another mouse always moves the pointer; the hold follows it
                io.cursor.x = min(io.cursor.x + 3, 3000)
                if io.frozen { io.anchorExpect = io.cursor }
            }
            if let b = oDown.min() {
                let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 2), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 2), button: b, id: id), source: .other)
            } else if io.moveTap != nil {
                let id = newID(InputInfo(source: .other, button: 0, type: .mouseMoved, flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(.mouseMoved, button: 0, id: id), source: .other)
            }
        case .padMove:
            // With the trackball quiet (no report for 0.25 s) a hold follows the trackpad 30 ms later
            // if the ball still hasn't reported (Engine.followOtherMouse), so the stand-in ends up
            // where the real pointer is; with the ball rolling it's put back (the trade-off). Which
            // part of the pointer's offset is whose can't be told, so that hold isn't judged by position.
            guard padDown.isEmpty, io.moveTap != nil || !io.frozen else { return }
            let quiet = io.clock - lastKMoveAt > 0.26
            io.cursor.x = min(io.cursor.x + 5, 3000)
            if io.frozen { holdDisturbed = true }
            let bypassBefore = bypass
            if io.moveTap != nil {
                // With the ball rolling the engine can't tell it from the trackball's own move and
                // swallows it like one (the documented trade-off), so it's judged as one.
                let source: Source = io.frozen && !quiet ? .kensington : .trackpad
                let id = newID(InputInfo(source: source, button: 0, type: .mouseMoved, flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(.mouseMoved, button: 0, id: id), source: source)
            }
            if io.frozen, quiet, bypass == bypassBefore, bypass == 0 { padCheck = (io.clock + Engine.echoWindow + 0.002, lastKMoveAt) }
        case .padClick(let b):
            markAmbiguity(other: b)
            othersKeep("a trackpad click of button \(b)", b) {
                let id = newID(InputInfo(source: .trackpad, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .trackpad)
                oRawReleased(b, trackpad: true)   // (its press may have gone past a switched-off tap)
                let id2 = newID(InputInfo(source: .trackpad, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 1), button: b, id: id2), source: .trackpad)
            }
        case .overlap(let b, let p):
            // The trackball and another mouse (or the trackpad) on the same button number, their
            // presses and releases interleaved one of six ways; the trackball's and the mouse's
            // HID reports before or after their CG events; a few milliseconds between, or none.
            let pad = p & 32 != 0
            let steps: [String] = [["kD", "oD", "oU", "kU"], ["kD", "oD", "kU", "oU"], ["oD", "kD", "oU", "kU"],
                                   ["oD", "kD", "kU", "oU"], ["kD", "kU", "oD", "oU"], ["oD", "oU", "kD", "kU"]][(p & 7) % 6]
            for s in steps {
                switch s {
                case "kD": apply(.kPress(b, hidFirst: p & 8 == 0))
                case "kU": apply(.kRelease(b, hidFirst: p & 16 == 0))
                case "oD": apply(pad ? .padClick(b) : .oPress(b))
                default: if !pad { apply(p & 128 != 0 ? .oReleaseCGFirst(b) : .oRelease(b)) }
                }
                if p & 64 != 0 { apply(.wait(0.004)) }
            }
        case .replugHeld(let b, let mode):
            // Plugged in with a finger already on button `b`: its press reaches macOS before
            // Glideball has the trackball (the tap is off with no trackball). Its HID report came
            // before IOHIDManager had the device open (mode 0), or comes just after the add (1);
            // or (2) the trackball's last report can't be read, so the engine only has macOS's
            // word that some button is down.
            guard !kConnected, !kDown.contains(b) else { return }
            let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
            kDown.insert(b)
            // A missed removal leaves the tap on: the press reaches the engine with no report
            // to say it's the trackball's, so it's taken for another device's (by design). With
            // nothing readable as the trackball arrives, it can't be told otherwise.
            if stale && mode == 2 { ambiguous = true }
            deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .kensington)
            heldReadable = mode != 2
            apply(.replug(0))
            heldReadable = true
            if mode == 1 {
                stamp += 1
                engine.hidInput(address: addrOf[kKey] ?? -kKey, fresh: kKey, identity: identityOf(kKey),
                                page: kHIDPage_Button, usage: b + 1, value: 1, stamp: stamp)
            }
        case .padScroll:
            let id = newID(InputInfo(source: .trackpad, button: -1, type: .scrollWheel, flags: io.kbFlags, time: io.clock))
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(srcField, value: Int64(id))
            e.setIntegerValueField(phaseField, value: 2)
            deliver(e, source: .trackpad)
        case .keyboard(let raw):
            io.kbFlags = CGEventFlags(rawValue: raw)
            let e = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Shift), keyDown: true)!
            e.type = .flagsChanged
            e.flags = io.kbFlags
            deliver(e, source: .keyboard)
        case .wait(let dt):
            advance(dt)
        case .config(let i), .remote(let i):
            mainConfig = configs[i % configs.count]
            push()
        case .front(let i):
            front = i
            io.foreground = stamp % 2 == 0
            push()
        case .pause:
            guard enabled else { return }
            engine.releaseHeldKeys()   // what AppModel does on a pause, in this order
            engine.releaseAll()
            enabled = false            // (releaseAll re-applies Glide's speed; the update hands it back)
            push()
            settle()
            mustBeReleased("pause")
            scrollMuted = true
        case .resume:
            guard !enabled else { return }
            enabled = true
            push()
        case .unplug(let mode):
            guard kConnected else { return }
            let held = kDown.sorted()
            if mode == 1 || mode == 3 { for b in held { apply(.kRelease(b, hidFirst: true)) } }
            kConnected = false
            if mode == 3 {   // no removal callback at all: IOHIDManager keeps listing both, dead
                ghosts[kKey] = expert; ghosts[kAux] = expert
                if stamp % 2 == 0 {   // IOKit's termination notices still come
                    engine.deviceTerminated(key: kKey)
                    engine.deviceTerminated(key: kAux)
                    return
                }
                stale = true
                return   // until a wake, unlock, window or another removal
            }
            // Each interface's removal, in either order, while IOHIDManager still lists it
            // (as the real one does); the second interface's removal is sometimes never heard of.
            // IOKit's termination notice for each comes before its removal, after it, or not at all.
            let auxFate = Int(stamp % 3)   // 0: first, 1: second, 2: missed (listed forever)
            let order = auxFate == 0 ? [kAux, kKey] : auxFate == 1 ? [kKey, kAux] : [kKey]
            if auxFate == 2 {
                ghosts[kAux] = expert
                if stamp % 2 == 1 { engine.deviceTerminated(key: kAux) }
            }
            for (i, k) in order.enumerated() {
                let notice = Int((stamp / 3 + UInt64(i)) % 3)   // 0: before, 1: after, 2: none
                ghosts[k] = expert
                if notice == 0 { engine.deviceTerminated(key: k) }
                remove(k)
                if notice == 1 { engine.deviceTerminated(key: k) }
                ghosts[k] = nil
            }
            if mode == 0 {
                for b in held {
                    kDown.remove(b)
                    let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
                    deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .kensington)
                }
            }
            if mode == 2 {   // macOS's own, lost
                tainted.formUnion(passedThrough.intersection(held))
                taintedWhileOff.subtract(held)
            }
            kDown.removeAll()
            kRawHeld.removeAll()
            settle()
            mustBeReleased("unplug")
            scrollMuted = true
        case .replug(let v):
            guard !kConnected else { return }
            if reused { reused = false; remove(kKey) }
            let oldGhost = ghosts.keys.filter { $0 != oKey }.min()   // a removal IOHIDManager never delivered
            // Re-enumerated: new registry IDs (the old ones may still be listed, dead). IOKit never
            // gives a live device the ID of one IOHIDManager still has.
            if replugs % 3 != 2 || stale || ghosts[kKey] != nil || ghosts[kAux] != nil {
                kKey = nextKey; kAux = nextKey + 1000; nextKey += 1
            }
            kConnected = true
            stale = false
            // How IOKit publishes it this time (see Op.replug).
            partial = [nil, DeviceIdentity(vendorID: expert.vendorID, productID: expert.productID, name: nil),
                       DeviceIdentity(vendorID: expert.vendorID, productID: nil, name: nil),
                       DeviceIdentity(vendorID: nil, productID: nil, name: nil)][v & 3]
            identityAt = io.clock + 0.2
            listAt = v & 4 != 0 ? io.clock + 0.3 : -1e9
            aliveAt = v & 8 != 0 ? io.clock + 0.4 : -1e9
            plugGraceUntil = io.clock + 1.5
            oddReplug = v & (3 | 4 | 8) != 0
            let order = v & 16 != 0 ? [kAux, kKey] : [kKey, kAux]
            for (i, k) in order.enumerated() {
                add(k, identityOf(k), transport: k == kKey && replugs % 2 == 1 ? "Bluetooth Low Energy" : "USB")
                if i == 0 && v & 32 != 0 { engine.reconcileDevices(reason: "fuzz") }
            }
            // The tap is back on with the trackball: the engine has asked macOS what's down.
            if !settling { tainted.subtract(taintedWhileOff); taintedWhileOff.removeAll() }
            if v & 64 != 0, let g = oldGhost {   // the old interface's removal, late, while still listed
                remove(g)
                ghosts[g] = nil
            }
            replugs += 1
        case .watch(let on):
            engine.setWatched(on)
            if on && !watched { stale = false }   // opening checks; already open, nothing new happens
            watched = on
        case .sleep:
            engine.releaseForSleep()
            settle()
            mustBeReleased("sleep", modesToo: false)
            scrollMuted = true
        case .wake:
            engine.reconcileDevices()   // what AppModel does on wake, in this order
            engine.reapplyPointer()
            stale = false
        case .reconcile:
            engine.reconcileDevices()
            stale = false
        case .lateValues:
            guard !kConnected, !stale, !reused else { return }
            for (page, usage, value) in [(kHIDPage_GenericDesktop, kHIDUsage_GD_X, 7), (kHIDPage_Button, 2, 1), (kHIDPage_Button, 2, 0)] {
                stamp += 1
                engine.hidInput(address: addrOf[kKey] ?? lastAddr[kKey] ?? -kKey, fresh: kKey, identity: expert,
                                page: page, usage: usage, value: value, stamp: stamp)
            }
        case .reuse:
            guard !kConnected, !stale, !reused else { return }
            reused = true
            add(kKey, otherMouse, transport: "USB")
        case .tapOff(let n):
            bypass = n
        case .standIn(let m):
            switch m {
            case 0: io.standInWorks = true
            case 1: io.standInWorks = false
            default:
                // EngineIO's watchdog: the engine stopped answering (here: it's told at its next keep),
                // so the real pointer is shown and the stand-in taken down.
                guard io.standIn != nil else { return }
                io.standInDropped = true
                io.hideStandIn()
            }
        case .esc:
            let switcherWasHeld = modes.switcherHeld
            defer {
                if switcherWasHeld, bypass == 0 {
                    if io.switcher != nil { fail("switcher", "Esc didn't take the Switcher's panel down") }
                    switcherHold?.dismissed = true
                }
            }
            let wasHeld = modes.wheelHeld
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Escape), keyDown: down)!
                e.flags = io.kbFlags
                deliver(e, source: .keyboard)
            }
            settle()
            if wasHeld, bypass == 0, io.wheel != nil { fail("wheel", "Esc didn't take the Wheel's ring down") }
            if wasHeld, bypass == 0 { wheelHold?.dismissed = true }
        case .wheelOverlay(let m):
            switch m {
            case 0: io.wheelWorks = true
            case 1: io.wheelWorks = false
            default:
                // EngineIO's watchdog: the engine stopped answering, so the ring is taken down.
                guard io.wheel != nil else { return }
                io.wheelDropped = true
                io.hideWheel()
                wheelHold?.dismissed = true
            }
        case .switcherPanel(let m):
            switch m {
            case 0: io.switcherWorks = true; io.switcherLists = true
            case 1: io.switcherWorks = false
            case 2:
                // EngineIO's watchdog: the engine stopped answering, so the panel is taken down.
                guard io.switcher != nil else { return }
                io.switcherDropped = true
                io.hideSwitcher()
                switcherHold?.dismissed = true
            case 3: io.switcherLists = false
            case 4: io.switcherLists = true; io.listDelay = 0
            case 5: io.switcherLists = true; io.listDelay = 0.4
            case 6: io.listDelay = .infinity
            default: io.listGrid = SwitcherGrid.fitting(count: Self.switcherCounts[m - 7], maxColumns: 2 + (m % 7), maxRows: 1 + (m % 3))
            }
        case .setMode(let m, let w):
            let mode: Engine.ToggleMode = [.precision, .ballScroll, .dragLock][m]
            engine.setMode(mode, on: w == 2 ? nil : w == 1, done: nil)
        case .learn:
            learning = true
            engine.learnNextPress { [unowned self] _ in self.learning = false }
        case .practice(let on):
            engine.setGesturePractice(on)
        case .displays(let n):
            let regions = (0..<n).map { DisplayRegion(key: "d\($0 + 1)", bounds: CGRect(x: Double($0) * 1500, y: 0, width: 1500, height: 1000)) }
            engine.setDisplays(regions)
        case .beta(let on):
            engine.setBetaProgram(on)
        case .quit:
            engine.releaseHeldKeys()   // AppDelegate.applicationWillTerminate, in this order
            engine.releaseAll()
            engine.handBackPointer()
            settle()
            mustBeReleased("quit")
            quitDone = true
            // Relaunch: a fresh engine on the same hardware.
            relaunch()
        }
        settle()
        checkAlways()
    }

    /// Another device's press or release never ends or changes what the trackball holds: its
    /// keys stay down, its gesture hold and Scroll with ball stay on. (A Drag lock is the one
    /// thing any left click ends, by design.)
    func othersKeep(_ what: String, _ b: Int, _ body: () -> Void) {
        settle()   // whatever came before (an op that returned early) is in first
        // Only what the trackball still physically holds (a hold whose button was let go of
        // ends when the engine sees that, which another device's event can be the moment of:
        // keys and Scroll with ball are judged while the trackball holds this very button, and
        // a held button's press the engine saw).
        let held = kDown.contains(b) && kRawHeld.isDisjoint(with: kDown)
        let keys = held ? Set(keysDown.filter { $0.value > 0 }.keys) : []
        let gesture = (modes.gestureHeld || modes.wheelHeld || modes.switcherHeld) && Set(modes.gestureButtons).isSubset(of: kDown), ball = held && modes.ballScrolling
        let wheelUp = io.wheel != nil
        let switcherUp = io.switcher != nil
        let bypassBefore = bypass
        body()
        settle()
        // macOS switched the tap off and on around this event: that ends holds, by design.
        if bypassBefore > 0 { return }
        // The trackball let go of a button just now: the engine may have held its release back
        // to tell it from this device's, and this event is what settled it. That's the
        // trackball's release ending its hold, as it should.
        if io.clock - lastKReleaseAt < 0.11 { return }
        if let k = keys.first(where: { (keysDown[$0] ?? 0) == 0 }) { fail("others", "\(what) let go of key \(k), held by the trackball") }
        if gesture && !modes.gestureHeld && !modes.wheelHeld && !modes.switcherHeld { fail("others", "\(what) ended the trackball's gesture, Wheel or Switcher hold") }
        if wheelUp, modes.wheelHeld, io.wheel == nil, !io.wheelDropped { fail("others", "\(what) took the trackball's Wheel down") }
        if switcherUp, modes.switcherHeld, io.switcher == nil, !io.switcherDropped { fail("others", "\(what) took the trackball's Switcher down") }
        if ball && !modes.ballScrolling { fail("others", "\(what) ended Scroll with ball") }
    }

    func noteScrollInput() {
        lastScrollInput = io.clock
        if enabled && kConnected { scrollMuted = false }
    }

    func relaunch() {
        for t in io.timers { t.valid = false }
        io.timers.removeAll()
        io.mainTap = nil
        io.moveTap = nil
        io.tapEnabled.removeAll()
        io.tapMask.removeAll()
        engine = Engine(config: resolved, io: io)
        watched = false   // a new engine starts with nothing open
        modes = Engine.Modes()
        lastFlashSeq = 0
        lastWheelSeq = 0
        lastSwitcherSeq = 0
        io.pendingLists.removeAll()   // the old process's main thread is gone with it
        io.lists.removeAll()          // and the new one numbers its holds from 1 again
        io.activatedSessions.removeAll()
        io.keyTap = nil
        quitDone = false
        wire()
        engine.startInline()
        // A new process: the same devices, new objects. (Ghosts stay listed, as they would.)
        func relist(_ k: Int, _ identity: DeviceIdentity) {
            if let a = addrOf.removeValue(forKey: k) { freeAddrs.append(a) }
            add(k, identity, transport: "USB")
        }
        if kConnected {
            relist(kKey, identityOf(kKey))
            relist(kAux, identityOf(kAux))
        } else if reused { relist(kKey, otherMouse) }
        stale = false
        relist(oKey, otherMouse)
        learning = false
        kReportsButtons = false   // a new engine hasn't seen a button over HID yet
        pendingPrimary.removeAll()
        // Buttons still held across the relaunch: the new engine never saw their presses, and
        // their releases must leave apps paired (through if apps have the button down, swallowed
        // if not) with nothing mapped. Judged, except a button another device holds too: apps
        // have it down once for both, and which of the two releases is "its" can't be said.
        heldThroughRelaunch = kDown
        for b in kDown { rawHeld(b) }
        oRawHeld.formUnion(oDown)   // another mouse's presses the new engine never saw, too
        settle()
    }

    // MARK: Gestures

    /// The ball moved while a gesture is held (as the engine sees it: the hold is current).
    func gestureTravel(_ dx: Int, _ dy: Int) {
        // A hold the tap's event just started (a move delivered before its HID report) is
        // published on main: see it before counting this report's roll toward it.
        while !io.mainWork.isEmpty { io.mainWork.removeFirst()() }
        guard modes.gestureHeld, var h = hold else { return }
        h.l1 += Double(abs(dx) + abs(dy))
        h.x += Double(dx); h.y += Double(dy)
        h.maxL2 = max(h.maxL2, (h.x * h.x + h.y * h.y).squareRoot())
        hold = h
    }

    /// The gesture a hold on `buttons` is running, from the settings the engine has.
    func heldGesture(_ buttons: [Int]) -> ButtonGesture? {
        let c = resolved
        let action = buttons.count == 1 ? c.buttons[buttons[0]] : c.chords.first { $0.buttons.sorted() == buttons }?.action
        if case .gesture(let g)? = action { return g }
        return nil
    }

    /// Every modes update the engine publishes, in order: the gesture rules.
    func observe(_ m: Engine.Modes) {
        if m.gestureHeld && !modes.gestureHeld {
            if m.gestureButtons.contains(0) { fail("gestures", "a gesture hold on \(m.gestureButtons) includes the primary button") }
            gestureHolds += 1
            let g = heldGesture(m.gestureButtons)
            let c = resolved
            hold = (m.gestureButtons, g, g.map { GestureTuning.for(distance: $0.distance ?? c.gestureDistance, steadyHands: c.gestureSteadyHands) },
                    io.clock, 0, 0, 0, 0, 0, [:])
        }
        if m.gestureHeld && m.gestureButtons.contains(0) { fail("gestures", "gesture held on \(m.gestureButtons), with the primary button") }
        if m.wheelHeld && m.gestureHeld { fail("wheel", "a Wheel and a gesture held at once") }
        if m.wheelHeld && !modes.wheelHeld {
            if m.gestureButtons.contains(0) { fail("wheel", "a Wheel hold on \(m.gestureButtons) includes the primary button") }
            wheelHolds += 1
            wheelHold = (m.gestureButtons, [], 0, false, false)
            io.wheelDropped = false
        }
        if m.wheelHeld && m.gestureButtons.contains(0) { fail("wheel", "Wheel held on \(m.gestureButtons), with the primary button") }
        if m.switcherHeld && (m.gestureHeld || m.wheelHeld) { fail("switcher", "a Switcher held with a gesture or a Wheel") }
        if m.switcherHeld && !modes.switcherHeld {
            if m.gestureButtons.contains(0) { fail("switcher", "a Switcher hold on \(m.gestureButtons) includes the primary button") }
            switcherHolds += 1
            switcherHold = (m.gestureButtons, 0, false, false, false, false)
            io.switcherDropped = false
        }
        if m.switcherHeld && m.gestureButtons.contains(0) { fail("switcher", "Switcher held on \(m.gestureButtons), with the primary button") }
        if let f = m.switcherFlash, f.seq != lastSwitcherSeq {
            if f.seq != lastSwitcherSeq + 1 { fail("switcher", "Switcher flash \(lastSwitcherSeq) jumped to \(f.seq)") }
            lastSwitcherSeq = f.seq
            if var h = switcherHold {
                if f.buttons != h.buttons { fail("switcher", "a Switcher on \(h.buttons) flashed as \(f.buttons)") }
                switch f.kind {
                case .switched:
                    switcherSwitches += 1
                    h.switched += 1
                    if m.switcherHeld { fail("switcher", "switched apps while the Switcher is still held") }
                    if h.switched > 1 { fail("switcher", "\(h.switched) switches in one hold") }
                    if h.dismissed { fail("switcher", "switched apps after it was dismissed (Esc, or the watchdog)") }
                case .tap:
                    switcherTaps += 1
                    if m.switcherHeld { fail("switcher", "a Switcher tap while it's still held") }
                    if h.ringTurned { fail("switcher", "a Switcher tap after the ring was turned") }
                    if h.shown { fail("switcher", "a Switcher tap after its panel showed") }
                    if h.switched > 0 { fail("switcher", "a Switcher tap after it switched") }
                    if h.dismissed { fail("switcher", "a Switcher tap after it was dismissed") }
                }
                switcherHold = h
            } else {
                fail("switcher", "a Switcher did something (\(f.kind)) with no hold")
            }
        }
        if let f = m.wheelFlash, f.seq != lastWheelSeq {
            if f.seq != lastWheelSeq + 1 { fail("wheel", "Wheel flash \(lastWheelSeq) jumped to \(f.seq)") }
            lastWheelSeq = f.seq
            if var h = wheelHold {
                if f.buttons != h.buttons { fail("wheel", "a Wheel on \(h.buttons) flashed as \(f.buttons)") }
                switch f.kind {
                case .slot:
                    wheelPicks += 1
                    h.picks += 1
                    if m.wheelHeld { fail("wheel", "a slot ran while the Wheel is still held") }
                    if h.picks > 1 { fail("wheel", "\(h.picks) slots ran in one hold") }
                    if h.dismissed { fail("wheel", "a slot ran after the Wheel was dismissed (Esc, or the watchdog)") }
                case .ring:
                    wheelRingSteps += 1
                    if !m.wheelHeld { fail("wheel", "a ring step with no Wheel held") }
                    if h.dismissed { fail("wheel", "a ring step after the Wheel was dismissed (Esc, or the watchdog)") }
                    h.ringTurned = true
                    h.ringSteps.append(io.clock)
                    if h.ringSteps.count > 1, io.clock - h.ringSteps[h.ringSteps.count - 2] < 0.05 - 1e-9 {
                        fail("wheel", "two ring steps \(String(format: "%.3f", io.clock - h.ringSteps[h.ringSteps.count - 2])) s apart (faster than 20 a second)")
                    }
                case .tap:
                    wheelTaps += 1
                    if m.wheelHeld { fail("wheel", "a Wheel tap while it's still held") }
                    if h.ringTurned { fail("wheel", "a Wheel tap after the ring was turned") }
                    if h.picks > 0 { fail("wheel", "a Wheel tap after a slot ran") }
                    if h.dismissed { fail("wheel", "a Wheel tap after it was dismissed") }
                }
                wheelHold = h
            } else {
                fail("wheel", "a Wheel did something (\(f.kind)) with no hold")
            }
        }
        if let flash = m.gestureFlash, flash.seq != lastFlashSeq {
            if flash.seq != lastFlashSeq + 1 { fail("gestures", "gesture flash \(lastFlashSeq) jumped to \(flash.seq)") }
            lastFlashSeq = flash.seq
            if var h = hold { checkFlash(flash, held: m.gestureHeld, &h); hold = h }
            else { fail("gestures", "a gesture \(flash.direction.map { "fired \($0)" } ?? "tapped") with no hold") }
        }
        modes = m
    }

    func checkFlash(_ flash: Engine.GestureFlash, held: Bool, _ h: inout (buttons: [Int], gesture: ButtonGesture?, tuning: GestureTuning?, start: Double,
                    l1: Double, x: Double, y: Double, maxL2: Double, fires: Int, byDirection: [GestureDirection: Int])) {
        if flash.buttons != h.buttons { fail("gestures", "a gesture on \(h.buttons) flashed as \(flash.buttons)") }
        guard let d = flash.direction else {
            // A tap: after the hold ended, never after a fire or a roll past the slop.
            gestureTaps += 1
            if held { fail("gestures", "a tap while the gesture is still held") }
            if h.fires > 0 { fail("gestures", "a tap after \(h.fires) fires in the same hold") }
            if let t = h.tuning, h.maxL2 >= t.tapSlop { fail("gestures", "a tap after rolling \(Int(h.maxL2)) (tap slop \(Int(t.tapSlop)))") }
            if flash.chain != 0 { fail("gestures", "a tap numbered \(flash.chain) in its chain") }
            return
        }
        gestureFires += 1
        h.fires += 1
        if h.fires > 1 { chainedFires += 1 }
        h.byDirection[d, default: 0] += 1
        if !held { fail("gestures", "\(d) fired with no gesture held") }
        if flash.chain != h.fires { fail("gestures", "fire \(h.fires) of its hold is numbered \(flash.chain)") }
        // Each fire needs the hold's whole distance of roll (commit, or a continuous step).
        let need = h.tuning.map { min($0.commit, $0.step) } ?? 32
        if Double(h.fires) * need > h.l1 + 0.5 {
            fail("gestures", "\(h.fires) fires after \(Int(h.l1)) counts of roll (each needs \(Int(need)); distance/Steady hands ignored?)")
        }
        // At most 20 a second.
        if Double(h.fires - 1) * 0.05 > io.clock - h.start + 1e-6 {
            fail("gestures", "\(h.fires) fires in \(String(format: "%.3f", io.clock - h.start)) s (faster than 20 a second)")
        }
        if let step = h.gesture?[d] {
            if step.once && h.byDirection[d]! > 1 { fail("gestures", "\"once per hold\" \(d) fired \(h.byDirection[d]!) times in one hold") }
        } else if h.gesture != nil {
            fail("gestures", "\(d) fired but the gesture has nothing there")
        }
    }

    // MARK: The rules

    func mustBeReleased(_ when: String, modesToo: Bool = true) {
        if modesToo, modes.precision || modes.ballScrolling || modes.dragLocked || modes.gestureHeld || modes.wheelHeld || modes.switcherHeld {
            fail("modes", "after \(when) a mode is still on: \(modes)")
        }
        if !modesToo, modes.ballScrolling || modes.dragLocked || modes.gestureHeld {
            fail("modes", "after \(when) Scroll with ball, Drag lock or a gesture is still on: \(modes)")
        }
        if io.frozen { fail("modes", "the pointer is still frozen after \(when)") }
        if io.standIn != nil || io.realHidden { fail("standin", "the stand-in is still up (the real pointer hidden) after \(when)") }
        if io.wheel != nil { fail("wheel", "the Wheel's ring is still on screen after \(when)") }
        if modes.wheelHeld { fail("wheel", "a Wheel is still held after \(when)") }
        if io.switcher != nil { fail("switcher", "the Switcher's panel is still on screen after \(when)") }
        if modes.switcherHeld { fail("switcher", "a Switcher is still held after \(when)") }
        if let k = keysDown.first(where: { $0.value > 0 }) { fail("released", "key \(k.key) still down after \(when)") }
        if let m = modifierEvents.first(where: { $0.value % 2 != 0 }) { fail("released", "modifier key \(m.key) still down after \(when)") }
        for (b, n) in appK where n > 0 && !tainted.contains(b) {
            // A button whose own press passed through is macOS's to release, not Glideball's.
            if passedThrough.contains(b) { continue }
            fail("released", "button \(b) still down for apps after \(when)")
        }
    }

    func checkAlways() {
        if io.warpedWhileFree { io.warpedWhileFree = false; fail("modes", "the pointer was moved by Glideball while nothing held it") }
        // "Connected" is the truth, unless a removal went missing and nothing has checked since.
        if !stale && io.clock >= plugGraceUntil && connected != kConnected { fail("connected", "status says connected = \(connected), the trackball is \(kConnected ? "plugged in" : "unplugged")") }
        checkStandIn()
        if io.frozen != (modes.ballScrolling || modes.gestureHeld || modes.wheelHeld || modes.switcherHeld) {
            fail("modes", "pointer frozen = \(io.frozen) but Scroll with ball = \(modes.ballScrolling), gesture = \(modes.gestureHeld), Wheel = \(modes.wheelHeld), Switcher = \(modes.switcherHeld)")
        }
        checkWheel()
        checkSwitcher()
        if !enabled && (modes.precision || modes.ballScrolling || modes.dragLocked || modes.gestureHeld || modes.wheelHeld || modes.switcherHeld) {
            fail("modes", "a mode is on while paused: \(modes)")
        }
        checkTimed()
    }

    /// The stand-in pointer: up only while the pointer is held (with the tap on), exactly at the
    /// hold's anchor, the real pointer hidden under it once and shown once; up whenever a hold
    /// could have it; kept alive for EngineIO's watchdog; and the real pointer let go exactly
    /// where the stand-in was.
    func checkStandIn() {
        if let f = io.standInFault { io.standInFault = nil; fail("standin", f) }
        if let f = io.freedAt {
            io.freedAt = nil
            if f.tapOn, f.cursor != f.standIn { fail("standin", "the real pointer came back at \(f.cursor), the stand-in was at \(f.standIn)") }
        }
        if io.realHidden != (io.standIn != nil) { fail("standin", "the real pointer is \(io.realHidden ? "hidden" : "shown") with the stand-in \(io.standIn == nil ? "down" : "up")") }
        let tapOn = io.mainTap.map { io.tapIsEnabled($0) } ?? false
        if let s = io.standIn {
            if !io.frozen { fail("standin", "the stand-in is up while nothing holds the pointer") }
            if !tapOn { fail("standin", "the stand-in is up while the tap is off") }
            if s != engine.holdAnchorForChecks { fail("standin", "the stand-in is at \(s), the hold at \(String(describing: engine.holdAnchorForChecks))") }
            if io.clock - io.standInKeptAt > EngineIO.standInLease { fail("standin", "the engine stopped keeping the stand-in (EngineIO's watchdog would take it down)") }
        } else if io.frozen, tapOn, !io.standInRefused, !io.standInDropped, engine.holdAnchorForChecks != nil {
            fail("standin", "the pointer is held but the stand-in isn't up")
        }
        if engine.standInForChecks != nil, io.standIn == nil, !io.standInDropped {
            fail("standin", "the engine thinks the stand-in is up but it isn't")
        }
    }

    /// The Wheel's ring: up only while a Wheel is held with the pointer frozen, at the hold's anchor,
    /// kept alive for EngineIO's watchdog; never left up; the key tap only while a Wheel is held.
    func checkWheel() {
        if let f = io.wheelFault { io.wheelFault = nil; fail("wheel", f) }
        if let w = io.wheel {
            wheelOverlays += 1
            if !modes.wheelHeld { fail("wheel", "the Wheel's ring is up with no Wheel held") }
            if !io.frozen { fail("wheel", "the Wheel's ring is up while nothing holds the pointer") }
            if w.at != engine.holdAnchorForChecks { fail("wheel", "the ring is at \(w.at), the hold at \(String(describing: engine.holdAnchorForChecks))") }
            if io.clock - io.wheelKeptAt > EngineIO.standInLease { fail("wheel", "the engine stopped keeping the Wheel (EngineIO's watchdog would take it down)") }
            if let s = w.model.selected, !w.model.menu.filled.contains(where: { $0.place == s }) { fail("wheel", "slot \(s) is lit but holds nothing that can run") }
            if w.model.selected != modes.wheelSlot, modes.wheelHeld { fail("wheel", "the ring lights \(String(describing: w.model.selected)), the engine says \(String(describing: modes.wheelSlot))") }
        }
        if engine.wheelForChecks != nil, io.wheel == nil, !io.wheelDropped { fail("wheel", "the engine thinks the ring is up but it isn't") }
        if io.keyTap != nil, !modes.wheelHeld, !modes.switcherHeld, engine.keyTapForChecks != nil, !engine.escHeldForChecks {
            fail("wheel", "the key tap is on with no Wheel or Switcher held")
        }
    }

    /// The Switcher's panel: up only while a Switcher is held with the pointer frozen, at the
    /// hold's anchor, kept alive for EngineIO's watchdog, its lit app in the list and on screen;
    /// never left up. (EngineIO's fake checks the switches themselves: once per hold, in the list.)
    func checkSwitcher() {
        if let f = io.switcherFault { io.switcherFault = nil; fail("switcher", f) }
        if let s = io.switcher {
            switcherPanels += 1
            if !modes.switcherHeld { fail("switcher", "the Switcher's panel is up with no Switcher held") }
            if !io.frozen { fail("switcher", "the Switcher's panel is up while nothing holds the pointer") }
            if s.at != engine.holdAnchorForChecks { fail("switcher", "the panel is at \(s.at), the hold at \(String(describing: engine.holdAnchorForChecks))") }
            if io.clock - io.switcherKeptAt > EngineIO.standInLease { fail("switcher", "the engine stopped keeping the Switcher (EngineIO's watchdog would take it down)") }
            let g = s.model.grid
            if g.count == 0 { fail("switcher", "the panel is up with no apps in it") }
            if s.model.selected < 0 || s.model.selected >= g.count { fail("switcher", "app \(s.model.selected) of \(g.count) is lit") }
            let row = s.model.selected / g.columns
            if row < s.model.firstRow || row >= s.model.firstRow + g.visibleRows { fail("switcher", "the lit app's row \(row) is off screen (rows \(s.model.firstRow)… of \(g.visibleRows))") }
            switcherHold?.shown = true
        }
        if engine.switcherForChecks != nil, io.switcher == nil, !io.switcherDropped { fail("switcher", "the engine thinks the panel is up but it isn't") }
        if io.activations.count > switcherSwitches { fail("switcher", "\(io.activations.count) apps switched to, \(switcherSwitches) switches seen") }
    }

    /// A trackpad move during a quiet hold: by then the stand-in must be where the real pointer is.
    var padCheck: (at: Double, kMoveAt: Double)?

    func checkTimed() {
        if let c = padCheck, io.clock >= c.at - 1e-9 {
            padCheck = nil
            if io.frozen, bypass == 0, lastKMoveAt == c.kMoveAt, let s = io.standIn, s != io.cursor {
                fail("standin", "the trackpad moved the real pointer out from under the stand-in: \(s) → \(io.cursor)")
            }
        }
        if let t = holdCheckAt {
            if !io.frozen || bypass != 0 || holdDisturbed {
                holdCheckAt = nil
            } else if io.clock >= t - 1e-9 {   // (the clock is a sum of waits: allow its rounding)
                holdCheckAt = nil
                if let a = io.anchorExpect, io.cursor != a {
                    fail("modes", "the pointer moved while held and stayed moved (\(io.foreground ? "Glideball in front" : "another app in front"), no move event for the tap): \(a) → \(io.cursor)")
                }
            }
        }
        // Another device's release held back: out by now, as it came.
        for (id, a) in awaiting {
            if let out = lastOut[id] {
                awaiting[id] = nil
                if out.type != a.before.type || out.button != a.before.button || out.flags != a.before.flags {
                    fail("others", "a held-back release \(a.before.type.rawValue)/\(a.before.button) came out as \(out.type.rawValue)/\(out.button)")
                }
            } else if io.clock > a.deadline + 1e-9 {
                awaiting[id] = nil
                fail("others", "another device's release of button \(a.before.button) never reached apps")
            }
        }
        for p in pendingPrimary where io.clock > p.deadline {
            fail("primary", "the primary button's press (#\(p.id)) never reached apps as a left click")
        }
        pendingPrimary.removeAll { io.clock > $0.deadline }
        // Quiet: nothing physically held, nothing waiting. Then nothing may be left down.
        // (A drag lock holds the left button across all of it, so it must be over too.)
        if ambiguous && kDown.isEmpty && oDown.isEmpty && bypass == 0 && !modes.dragLocked && io.clock > graceUntil + 1 {
            ambiguous = false   // start judging buttons afresh
            // Counts that are still up can't be judged either (they may be macOS's own, from
            // another mouse): they stay out of it until they come back to zero.
            tainted = Set(appK.filter { $0.value > 0 }.keys).union(appO.filter { $0.value > 0 }.keys)
            taintedO = Set(appO.filter { $0.value > 0 }.keys)
            passedThrough.removeAll(); swallowedOther.removeAll(); awaiting.removeAll()
        }
        // (Another mouse's press can be taken for the trackball's, see `ambiguous`: then it holds too.)
        // (A release can be held back up to 0.1 s while the engine tells whose it is.)
        guard kDown.isEmpty, !ambiguous || oDown.isEmpty, io.clock > graceUntil, bypass == 0,
              io.clock - lastKReleaseAt > 0.11, awaiting.isEmpty else { return }
        if let k = keysDown.first(where: { $0.value > 0 }) { fail("released", "key \(k.key) still down with every button up") }
        if let m = modifierEvents.first(where: { $0.value % 2 != 0 }) { fail("released", "modifier \(m.key) still down with every button up") }
        for (b, n) in appK where n > 0 && !tainted.contains(b) && !(b == 0 && modes.dragLocked) {
            fail("released", "button \(b) still down for apps with every button up")
        }
        // Every other device's press has had its release too.
        if oDown.isEmpty && awaiting.isEmpty && !ambiguous {
            for (b, n) in appO where n > 0 && !taintedO.contains(b) {
                fail("others", "another device's button \(b) still down for apps with its button up")
            }
        }
    }
}

// MARK: - Generating, running, minimizing

func generate(seed: UInt64, count: Int) -> (configs: [GlideConfig], ops: [Op]) {
    var r = RNG(seed)
    // Every third seed leans on gestures: gesture buttons and combos everywhere, more
    // flicks, fewer pauses and unplugs (which otherwise keep most holds from starting).
    let focus = seed % 3 == 0
    let configs = (0..<6).map { _ in focus ? gestureHeavy(randomConfig(&r), &r) : randomConfig(&r) }
    let rare = focus ? 0.25 : 1.0, flicks = focus ? 18.0 : 6.0
    var ops: [Op] = []
    ops.reserveCapacity(count)
    let weights: [(Double, (inout RNG) -> Op)] = [
        (14, { r in .kPress(r.int(5), hidFirst: r.chance(0.9)) }),
        (14, { r in .kRelease(r.int(5), hidFirst: r.chance(0.9)) }),
        (14, { r in .kBall(r.int(41) - 20, r.chance(0.5) ? r.int(41) - 20 : 0) }),
        (flicks, { r in r.chance(0.5) ? .kBall(r.chance(0.5) ? 90 : -90, r.int(21) - 10) : .kBall(r.int(21) - 10, r.chance(0.5) ? 90 : -90) }),   // a flick: fires (and chains) gestures
        (10, { r in .kWheel(r.chance(0.5) ? 1 : -1) }),
        (18, { r in .wait(r.chance(0.8) ? r.double(0, 0.04) : (r.chance(0.97) ? r.double(0.05, 2) : r.double(10, 35))) }),
        (3, { r in .oPress(r.int(3)) }),
        (3, { r in .oRelease(r.int(3)) }),
        // Another mouse on every button number the trackball has, so its presses overlap the
        // trackball's (held, remapped, swallowed, waiting for a combo, holding a gesture).
        (1.5, { r in .oPress(r.int(5)) }),
        (1, { r in r.chance(0.8) ? .oRelease(r.int(5)) : .oReleaseCGFirst(r.int(5)) }),
        (2.5, { r in .overlap(r.int(5), r.int(256)) }),
        (0.2, { r in .replugHeld(r.int(5), r.int(3)) }),
        (1, { r in .oWheel(r.chance(0.5) ? 1 : -1) }),
        (1, { _ in .oBall }),
        (1.5, { r in .padClick(r.int(2)) }),
        (1, { _ in .padScroll }),
        (0.6, { _ in .padMove }),
        (2.5, { r in .keyboard(r.pick([0, CGEventFlags.maskShift.rawValue, CGEventFlags.maskCommand.rawValue,
                                      CGEventFlags([.maskControl, .maskCommand]).rawValue])) }),
        (1.2, { r in .config(r.int(6)) }),
        (0.4, { r in .remote(r.int(6)) }),
        (1.2, { r in .front(r.int(4) - 1) }),
        (0.7 * rare, { _ in .pause }),
        (0.8, { _ in .resume }),
        (0.35 * rare, { r in .unplug(r.int(4)) }),
        (0.3, { _ in .lateValues }),
        (0.15, { _ in .reuse }),
        (0.2, { _ in .reconcile }),
        (0.45, { r in .replug(r.chance(0.5) ? 0 : r.int(128)) }),
        (0.2, { r in .watch(r.chance(0.6)) }),
        (0.35 * rare, { _ in .sleep }),
        (0.25, { _ in .wake }),
        (0.5, { r in .tapOff(1 + r.int(4)) }),
        (1.5, { r in .setMode(r.int(3), r.int(3)) }),
        (0.25, { _ in .learn }),
        (0.15, { r in .practice(r.chance(0.5)) }),
        (0.25, { r in .displays(1 + r.int(3)) }),
        (0.15, { r in .beta(r.chance(0.5)) }),
        (0.08, { _ in .quit }),
        (0.3, { r in .standIn(r.int(3)) }),
        (1.2, { _ in .esc }),
        (0.25, { r in .wheelOverlay(r.int(3)) }),
        (0.35, { r in .switcherPanel(r.int(14)) }),
    ]
    let total = weights.reduce(0) { $0 + $1.0 }
    for _ in 0..<count {
        var x = r.double(0, total)
        for (w, make) in weights {
            if x < w { ops.append(make(&r)); break }
            x -= w
        }
    }
    return (configs, ops)
}

/// Runs `ops`; returns the first failure and the index of the op that caused it.
var lastWorld: World?

func run(_ configs: [GlideConfig], _ ops: [Op]) -> (Failure, Int)? {
    let w = World(configs: configs)
    lastWorld = w
    if let f = w.violations.first { return (f, -1) }
    for (i, op) in ops.enumerated() {
        w.apply(op)
        if let f = w.violations.first { return (f, i) }
    }
    // Let everything settle, let go of everything, and check again.
    if w.bypass > 0 { w.bypass = 0; w.tapComesBack() }
    for b in w.kDown.sorted() { w.apply(.kRelease(b, hidFirst: true)) }
    for b in w.oDown.sorted() { w.apply(.oRelease(b)) }
    w.apply(.wait(5))
    if let f = w.violations.first { return (f, ops.count) }
    statFires += w.gestureFires; statChained += w.chainedFires; statTaps += w.gestureTaps; statHolds += w.gestureHolds
    statWheelHolds += w.wheelHolds; statWheelPicks += w.wheelPicks; statWheelRing += w.wheelRingSteps; statWheelTaps += w.wheelTaps
    statSwitcherHolds += w.switcherHolds; statSwitches += w.switcherSwitches; statSwitcherTaps += w.switcherTaps; statSwitcherPanels += w.io.switcherShows
    return nil
}
var statFires = 0, statChained = 0, statTaps = 0, statHolds = 0
var statWheelHolds = 0, statWheelPicks = 0, statWheelRing = 0, statWheelTaps = 0
var statSwitcherHolds = 0, statSwitches = 0, statSwitcherTaps = 0, statSwitcherPanels = 0

/// Delta debugging: the smallest list of ops (that we can find quickly) that still
/// breaks the same rule.
func minimize(_ configs: [GlideConfig], _ ops: [Op], rule: String) -> [Op] {
    var current = ops
    var n = 2
    var attempts = 0
    while current.count >= 2 && attempts < 4000 {
        let chunk = max(1, current.count / n)
        var reduced = false
        var start = 0
        while start < current.count {
            attempts += 1
            var candidate = current
            candidate.removeSubrange(start..<min(start + chunk, current.count))
            if let (f, i) = run(configs, candidate), f.rule == rule {
                current = Array(candidate.prefix(max(i + 1, 0) == 0 ? candidate.count : min(candidate.count, i + 1)))
                reduced = true
            } else {
                start += chunk
            }
        }
        if !reduced {
            if chunk == 1 { break }
            n = min(current.count, n * 2)
        } else {
            n = max(n - 1, 2)
        }
    }
    return current
}

func describe(_ c: GlideConfig) -> String {
    let buttons = c.buttons.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.short)" }.joined(separator: ", ")
    let chords = c.chords.map { "\($0.buttons) → \($0.action.short)" }.joined(separator: ", ")
    return "buttons [\(buttons)] combos [\(chords)] gestures \(c.gesturesEnabled ? "on" : "off") scroll \(c.scrollMode.rawValue)"
        + (c.appProfiles.isEmpty ? "" : " appSetups \(c.appProfiles.count)")
}

extension ButtonAction {
    var short: String {
        switch self {
        case .gesture(let g): "gesture(tap: \(g.tap.short))"
        case .wheel(let w): "wheel(\(w.filled.count) slots, ring \(w.ring.rawValue), tap: \(w.tap.short))"
        case .switcher(let a): "switcher(tap: \(a.tap.short))"
        case .shortcut(let s): "shortcut(\(s.keyCode))"
        case .holdShortcut(let s): "holdShortcut(\(s.keyCode))"
        default: "\(self)"
        }
    }
}

// MARK: - Regression cases (one per bug the fuzzer found; see docs/DIAGNOSIS-2026-11.md)

func regressionCases() -> [(String, [GlideConfig], [Op])] {
    var hold = GlideConfig()
    hold.buttons[3] = .holdShortcut(.wisprFlow)
    var remap = GlideConfig()
    remap.buttons[1] = .middleClick
    var fly = GlideConfig()
    fly.scrollMode = .flywheel
    var drag = GlideConfig()
    drag.buttons[2] = .dragLock
    var hostile = GlideConfig()
    hostile.flyDistance = .infinity
    hostile.flyAcceleration = 1e308
    hostile.trackingSpeed = .nan
    hostile.buttons[1] = .modifiedClick(button: -7, modifiers: 0)
    var g = GlideConfig()
    g.buttons[3] = .gesture(.standard)
    let flick: [Op] = (0..<12).flatMap { _ in [Op.kWheel(1), .wait(0.008)] }
    var twoHolds = GlideConfig()
    twoHolds.buttons[1] = .holdShortcut(.copy)
    twoHolds.buttons[3] = .holdShortcut(.wisprFlow)
    var sameHolds = GlideConfig()
    sameHolds.buttons[1] = .holdShortcut(.wisprFlow)
    sameHolds.buttons[3] = .holdShortcut(.wisprFlow)
    var toLeft = GlideConfig()
    toLeft.buttons[2] = .leftClick
    var comboDrag = GlideConfig()
    comboDrag.buttons[2] = .dragLock
    comboDrag.chords = [Chord(buttons: [2, 3], action: .shortcut(.missionControl))]
    var comboRemap = GlideConfig()
    comboRemap.buttons[1] = .middleClick
    comboRemap.chords = [Chord(buttons: [1, 3], action: .shortcut(.missionControl))]
    var primaryCombo = GlideConfig()
    primaryCombo.chords = [Chord(buttons: [0, 1], action: .shortcut(.missionControl))]
    var jumpy = GlideConfig()
    jumpy.smoothScrolling = false
    jumpy.flyAcceleration = 1.5
    jumpy.flyDistance = 20
    var selfMod = GlideConfig()
    selfMod.buttons[1] = .middleClick
    selfMod.buttons[2] = .modifiedClick(button: 2, modifiers: CGEventFlags.maskControl.rawValue)
    // Gestures on combos, chained fires and their tuning (merged with gestures-round2).
    var chain = GlideConfig()
    chain.buttons[3] = .gesture(ButtonGesture(up: GestureStep(.shortcut(.copy)), down: GestureStep(.shortcut(.redo)),
                                              left: GestureStep(.back, once: true), right: GestureStep(.forward)))
    var comboG = GlideConfig()
    comboG.chords = [Chord(buttons: [1, 3], action: .gesture(.tabs))]
    var primaryG = GlideConfig()
    primaryG.chords = [Chord(buttons: [0, 2], action: .gesture(.standard))]
    var steady = chain
    steady.gestureSteadyHands = true
    steady.gestureDistance = .short
    var longG = chain
    longG.buttons[3] = .gesture(ButtonGesture(left: GestureStep(.back), right: GestureStep(.forward), distance: .long))
    func roll(_ dx: Int, _ dy: Int, _ n: Int) -> [Op] { (0..<n).flatMap { _ in [Op.kBall(dx, dy), .wait(0.01)] } }
    func down(_ bs: Int...) -> [Op] { bs.map { Op.kPress($0, hidFirst: true) } }
    func up(_ bs: Int...) -> [Op] { bs.map { Op.kRelease($0, hidFirst: true) } }
    let pause: [Op] = [.wait(0.2)], settle: [Op] = [.wait(1)]
    var gestureCases: [(String, [GlideConfig], [Op])] = []
    var ops: [Op] = down(3) + roll(-20, 0, 4) + pause + roll(0, -20, 4)
    ops += pause + roll(-20, 0, 4) + pause + up(3) + settle
    gestureCases.append(("chained gesture: left, up, left in one hold fires twice left only if not once", [chain], ops))
    ops = down(3) + roll(20, 0, 4) + pause + roll(20, 0, 4) + pause + roll(20, 0, 4) + up(3) + settle
    gestureCases.append(("chained gesture: right three times, numbered 1, 2, 3", [chain], ops))
    ops = down(1, 3) + pause + roll(20, 0, 4) + up(3) + [.kBall(30, 0)] + up(1) + settle
    gestureCases.append(("gesture combo: holds, fires, ends with the first button up", [comboG], ops))
    ops = down(2, 0) + pause + roll(20, 0, 4) + up(0, 2) + settle
    gestureCases.append(("gesture combo with the primary button: never a gesture", [primaryG], ops))
    ops = down(3) + roll(10, 0, 4) + up(3) + [.wait(0.5)] + down(3) + roll(20, 0, 3) + up(3) + settle
    gestureCases.append(("Steady hands: a short roll doesn't fire, a long one does", [steady], ops))
    ops = down(3) + roll(20, 0, 3) + up(3) + settle
    gestureCases.append(("a gesture's own Long distance: 60 counts don't fire", [longG], ops))
    ops = down(1, 3) + pause + [.kBall(30, 0), .pause, .resume] + up(1, 3) + down(1, 3) + pause + [.sleep, .wake] + up(1, 3)
    ops += down(1, 3) + pause + [.quit] + up(1, 3) + settle
    gestureCases.append(("gesture combo held through pause, sleep and quit: nothing held", [comboG], ops))
    // "Connected" after an unplug (Levi, Nov 2026): every event checks the status against the hardware.
    var holdKey = GlideConfig()
    holdKey.buttons[3] = .holdShortcut(.wisprFlow)
    gestureCases.append(("unplugged, then late values from it: not connected", [GlideConfig()], [.unplug(0), .lateValues, .wait(1)]))
    gestureCases.append(("unplugged, another mouse at the same address: not connected", [GlideConfig()],
                         [.unplug(2), .reuse, .reconcile, .wait(1), .replug(0), .wait(1), .unplug(0), .lateValues, .wait(1)]))
    gestureCases.append(("removal missed, then wake: not connected, released once", [holdKey],
                         down(3) + [.setMode(0, 1), .unplug(3), .wait(1), .sleep, .wake, .wait(1)] + up(3) + settle))
    gestureCases.append(("removal missed, then the window opens: not connected", [GlideConfig()], [.unplug(3), .reconcile, .lateValues, .wait(1)]))
    // Beta 13 (Levi, Nov 13): IOHIDManager still lists the trackball while its removal callback
    // runs, and the check inside the callback added it straight back. Every unplug now models
    // that; these pin the interface orders (aux first, aux second, aux never removed).
    gestureCases.append(("still listed during its own removal callback: not connected", [GlideConfig()],
                         [.unplug(0), .wait(1), .replug(0), .kBall(3, 0), .unplug(0), .wait(1), .replug(0), .kBall(3, 0), .kBall(2, 1), .unplug(2), .reconcile, .wait(1)]))
    // The pointer held in any app (beta 13): it stays put, in front and behind; with the tap
    // switched off it moves freely, and a hold still on keeps it where it went.
    var scrollHold = GlideConfig()
    scrollHold.buttons[4] = .ballScrollHold
    gestureCases.append(("Scroll with ball, another app in front: the pointer stays put", [scrollHold],
                         [.front(1), .kPress(4, hidFirst: true), .kBall(30, 5), .kBall(-12, 9), .kRelease(4, hidFirst: true), .kBall(5, 0)]))
    gestureCases.append(("Scroll with ball, the tap switched off mid-roll: no jump back after", [scrollHold],
                         [.kPress(4, hidFirst: true), .tapOff(1), .kBall(1, 0), .wait(1.2), .kBall(0, 0), .kBall(4, 0)] + up(4)))
    // Beta 23: the stand-in pointer (Mac Mouse Fix's puppet cursor). Beta 22 held slow rolls
    // dead still but fast ones escaped between macOS moving the pointer and the put-back
    // ("1375 warps … furthest 175 pt"), so the real pointer is hidden under a picture of it.
    // Every way a hold ends must take the picture down and show the real pointer.
    let fast: [Op] = (0..<10).flatMap { _ in [Op.kBall(90, 7), .wait(0.004)] }
    gestureCases.append(("stand-in: a fast roll in another app, up at the hold, down on release", [g],
                         [.front(1)] + down(3) + fast + [.wait(0.1)] + up(3) + settle))
    gestureCases.append(("stand-in: Scroll with ball, paused mid-hold", [scrollHold], down(4) + fast + [.pause, .resume] + up(4) + settle))
    gestureCases.append(("stand-in: a gesture hold, unplugged mid-hold", [g], down(3) + fast + [.unplug(0), .wait(1), .replug(0)] + settle))
    gestureCases.append(("stand-in: Scroll with ball, the Mac sleeps mid-hold", [scrollHold], down(4) + fast + [.sleep, .wake] + up(4) + settle))
    gestureCases.append(("stand-in: a gesture hold through quit", [g], down(3) + fast + [.quit] + up(3) + settle))
    gestureCases.append(("stand-in: a gesture hold, the tap switched off", [g], down(3) + fast + [.tapOff(1), .kBall(5, 0)] + up(3) + settle))
    gestureCases.append(("stand-in: a gesture hold past its 30 s limit", [g], down(3) + fast + [.wait(31)] + up(3) + settle))
    gestureCases.append(("stand-in: Scroll with ball, another mouse moves the hold", [scrollHold],
                         down(4) + fast + [.wait(0.1), .oBall, .wait(0.1)] + fast + up(4) + settle))
    gestureCases.append(("stand-in: Scroll with ball from the keyboard, the trackpad moves the pointer: the stand-in goes with it", [scrollHold],
                         [.setMode(1, 1)] + fast + [.wait(0.5), .padMove, .wait(0.1), .padMove, .wait(0.1), .setMode(1, 0)] + settle))
    gestureCases.append(("stand-in unavailable: the hold works as before", [g], [.standIn(1)] + down(3) + fast + up(3) + settle))
    gestureCases.append(("stand-in taken down by the watchdog: the hold goes on without it", [g],
                         down(3) + fast + [.standIn(2), .wait(0.5)] + fast + up(3) + down(3) + fast + up(3) + settle))
    gestureCases.append(("replugged with new IDs, old ones still listed dead: connected, then not", [holdKey],
                         [.unplug(3), .replug(0), .reconcile, .wait(1)] + down(3) + [.unplug(1), .reconcile, .wait(1)] + settle))
    // Beta 14 (Levi, Nov 13): unplugged and plugged back in, the trackball no longer worked in
    // Glideball until a relaunch. A device check's "left" verdict was permanent (a tombstone
    // only IOHIDManager's add could clear, and its add had already come). Each replug here
    // is published the way IOKit can, with a check landing in the gap; after it the
    // trackball must be connected and every value from it must count ("works").
    let use: [Op] = [.wait(2), .kBall(3, 0), .kPress(1, hidFirst: true), .kRelease(1, hidFirst: true), .kWheel(1), .wait(1)]
    gestureCases.append(("replugged, its name published late, then the window opens: works", [GlideConfig()],
                         [.unplug(0), .wait(1), .replug(1), .wait(0.5), .watch(true)] + use))
    gestureCases.append(("replugged before IOHIDManager lists it, a check in between: works", [GlideConfig()],
                         [.unplug(0), .wait(1), .replug(4 | 32)] + use))
    gestureCases.append(("replugged before IOKit finished registering it, a check in between: works", [GlideConfig()],
                         [.unplug(0), .wait(1), .replug(8 | 32)] + use))
    gestureCases.append(("replugged with no properties yet: works", [GlideConfig()],
                         [.unplug(0), .wait(1), .replug(3)] + use))
    gestureCases.append(("an old interface's removal arrives after the replug: works", [GlideConfig()],
                         [.unplug(3), .wait(1), .replug(4 | 64)] + use))
    gestureCases.append(("late values, then a replug at the recycled address: works", [GlideConfig()],
                         [.unplug(0), .lateValues, .replug(4 | 16 | 32), .kBall(2, 0)] + use))
    gestureCases.append(("termination notices before, after and instead of removals, replugged each time: works", [GlideConfig()],
                         [.unplug(0), .replug(0), .kBall(1, 0), .unplug(1), .replug(0), .kBall(1, 0), .unplug(2), .replug(0),
                          .kBall(1, 0), .unplug(3), .wait(1), .replug(1 | 32), .watch(true), .wait(3), .unplug(0), .replug(0)] + use))
    gestureCases.append(("replugged, taken out by a check while registering, Precision on, unplugged: Precision ends", [GlideConfig()],
                         [.unplug(2), .replug(3 | 8 | 32 | 64), .kBall(-90, 10), .setMode(0, 1), .unplug(2), .wait(1)]))
    // Beta 14 (Levi, Nov 16, an Expert Mouse with KensingtonWorks' driver): holding the gesture
    // button and rolling fired the gesture (so HID values arrived) but the pointer moved the whole
    // time. The hold was only put back when a look found the pointer already moved: at a HID report
    // (usually before WindowServer has moved it) or at the move's tap event (which needn't come).
    // How a kBall is delivered while held follows from its numbers (see `delivery` in World.apply): (10, 0) has no
    // tap event at all, (5, 0) a plain move instead of the drag, (3, 0) the tap's event before HID.
    var volume = GlideConfig()
    volume.buttons[1] = .gesture(ButtonGesture(up: GestureStep(.media(.volumeUp)), down: GestureStep(.media(.volumeDown))))
    let roll10: [Op] = (0..<6).flatMap { _ in [Op.kBall(10, 0), .wait(0.008)] }
    gestureCases.append(("gesture held in another app, the tap never sees the ball's moves: the pointer stays put", [volume],
                         [.front(1)] + down(1) + roll10 + [.wait(0.05)] + up(1) + settle))
    gestureCases.append(("gesture held in another app, plain moves instead of drags: the pointer stays put", [volume],
                         [.front(1)] + down(1) + (0..<6).flatMap { _ in [Op.kBall(5, 0), .wait(0.008)] } + up(1) + settle))
    gestureCases.append(("gesture held in another app, each move's tap event before its HID report: the pointer stays put", [volume],
                         [.front(1)] + down(1) + (0..<6).flatMap { _ in [Op.kBall(3, 0), .wait(0.008)] } + up(1) + settle))
    // Betas 16 and 17 (Levi): every hold logged "0 warps … furthest 0 pt" while the pointer moved.
    // One way that happens: a second, vendorless pointing device (a driver's virtual pointer)
    // reporting the trackball's every movement as its own. The hold took each copy for another
    // mouse and followed it, so it never put the pointer back. Each move here is delivered a
    // different way (see `delivery`), its copy before or after it, after a pause long enough that
    // nothing before it counts.
    let echoRoll: [Op] = [.wait(0.5)] + [4, 3, 5, 2, 6, 7, 8, 9, 11, 10].flatMap { [Op.kBall($0, 0), .wait(0.008)] }
    gestureCases.append(("a driver's shadow pointer echoes every move, gesture held in another app: the pointer stays put", [volume],
                         [.front(1)] + down(1) + echoRoll + [.wait(0.05)] + up(1) + settle))
    gestureCases.append(("a driver's shadow pointer echoes every move, gesture held, another app setup in front: the pointer stays put", [volume],
                         [.front(0)] + down(1) + echoRoll + [.wait(0.05)] + up(1) + settle))
    gestureCases.append(("a driver's shadow pointer echoes every move, Scroll with ball from the keyboard: the pointer stays put", [GlideConfig()],
                         [.front(1), .setMode(1, 1)] + echoRoll + [.wait(0.05), .setMode(1, 0)] + settle))
    gestureCases.append(("a driver's shadow pointer, then another mouse moves alone mid-hold: the hold follows it", [volume],
                         [.front(1)] + down(1) + echoRoll + [.wait(0.1), .oBall, .wait(0.1)] + echoRoll + up(1) + settle))
    gestureCases.append(("Scroll with ball from the keyboard in another app, no tap events: the pointer stays put", [GlideConfig()],
                         [.front(1), .setMode(1, 1)] + roll10 + [.wait(0.05), .setMode(1, 0)] + settle))
    // The ball turning a few counts under the hand while a gesture combo's buttons go down used
    // to end the combo wait: the first button acted alone and the gesture never started.
    gestureCases.append(("gesture combo pressed with the ball jiggling: still the combo's gesture", [comboG],
                         down(1) + [.kBall(2, 1), .kBall(-3, 2)] + down(3) + roll(20, 0, 4) + up(3, 1) + settle))
    // A gesture firing a click of a button that is held and waiting for a combo partner: the
    // waiting press reached apps at the next drag, then the queued click pressed it again.
    var backWait = GlideConfig()
    backWait.buttons[4] = .gesture(ButtonGesture(left: GestureStep(.back)))
    backWait.chords = [Chord(buttons: [2, 3], action: .dragLock)]
    gestureCases.append(("a gesture fires Back while Back's button waits for a combo: never a double press", [backWait],
                         down(4) + [.kBall(12, -12)] + down(3) + [.kBall(-90, -2)] + up(3, 4) + settle))
    var leftWait = GlideConfig()
    leftWait.buttons[3] = .gesture(ButtonGesture(up: GestureStep(.leftClick)))
    leftWait.chords = [Chord(buttons: [0, 4], action: .gesture(.standard))]
    gestureCases.append(("a gesture fires a left click while the primary waits for a combo: never a double press", [leftWait],
                         down(3) + [.kBall(11, 8)] + down(0) + [.kBall(10, -90)] + up(0, 3) + settle))
    // Scroll with ball: reports that piled up (the input thread held up) went out in one frame.
    var fastBall = GlideConfig()
    fastBall.ballScrollSpeed = 4
    var fastBallDirect = fastBall
    fastBallDirect.smoothScrolling = false
    let pile: [Op] = [.setMode(1, 1), .kWheel(1), .wait(0.001)] + (0..<20).map { Op.kBall(90, $0 % 2 == 0 ? 9 : -9) } + [.wait(1), .setMode(1, 0)]
    gestureCases.append(("Scroll with ball, 20 reports at once: spread over frames, no runaway", [fastBall], pile))
    gestureCases.append(("Scroll with ball, smooth scrolling off, 20 reports at once: no runaway", [fastBallDirect], pile))
    // Two devices on one button number (Nov 2026): each press is the device's whose HID report
    // it claimed, and its release is matched to it by the HID reports of that button going up.
    // Another device's press and release always reach apps as they came; what the trackball's
    // press holds ends only with the trackball's own release. (Before, a release went to
    // whichever press of that number came first: see docs/DIAGNOSIS-2026-11.md.)
    var disabled = GlideConfig()
    disabled.buttons[1] = .disabled
    let both: [(String, [GlideConfig], [Op])] = [
        ("same button: another mouse presses and lets go while the trackball's remap holds", [remap],
         down(1) + [.oPress(1), .oRelease(1), .wait(0.05)] + up(1) + settle),
        ("same button: another mouse holds it while the trackball presses and lets go", [remap],
         [.oPress(1)] + down(1) + up(1) + [.oRelease(1)] + settle),
        ("same button: a held shortcut stays down through another mouse's click", [hold],
         down(3) + [.oPress(3), .oRelease(3), .wait(0.2)] + up(3) + settle),
        ("same button: a trackpad click while the trackball's press is swallowed", [disabled],
         down(1) + [.padClick(1), .wait(0.2)] + up(1) + settle),
        ("same button: the trackball's release before its report, another mouse holding", [remap],
         [.oPress(1)] + down(1) + [.kRelease(1, hidFirst: false), .wait(0.2), .oRelease(1)] + settle),
        ("same button: another mouse's release before its report, the trackball holding", [remap],
         down(1) + [.oPress(1), .oReleaseCGFirst(1), .wait(0.2)] + up(1) + settle),
        ("same button: the trackball's press before its report, another mouse holding", [remap],
         [.oPress(1), .kPress(1, hidFirst: false), .wait(0.1)] + up(1) + [.oRelease(1)] + settle),
        ("same button: another mouse right after the trackball's click (was within 0.3 s)", [remap],
         down(1) + up(1) + [.oPress(1), .oRelease(1)] + settle),
        ("same button: both let go before their reports, a gesture held", [g],
         down(3) + [.oPress(3), .kBall(20, 0), .kRelease(3, hidFirst: false), .oReleaseCGFirst(3), .wait(0.2)] + settle),
    ]
    // Buttons held while the engine starts, the tap is off, or the trackball arrives: their
    // releases do nothing mapped and leave apps paired.
    let held: [(String, [GlideConfig], [Op])] = [
        ("held through a relaunch, remapped: its release is swallowed", [remap], down(1) + [.quit] + up(1) + settle),
        ("held through a relaunch, its own click: its release goes through", [GlideConfig()], down(2) + [.quit] + up(2) + settle),
        ("held through a pause and resume, remapped: released at the pause, its release swallowed", [remap],
         down(1) + [.pause, .resume] + up(1) + settle),
        ("pressed while paused, released after resuming: a plain click", [remap], [.pause] + down(1) + [.resume] + up(1) + settle),
        ("pressed while the tap was off, released after: its release goes through", [remap],
         [.tapOff(1)] + down(1) + [.wait(0.1)] + up(1) + settle),
        ("plugged in held, its report before Glideball had it open: release goes through, no remap", [remap],
         [.unplug(0), .wait(1), .replugHeld(1, 0), .wait(2)] + up(1) + settle),
        ("plugged in held, its report after the add: release goes through, no remap", [remap],
         [.unplug(0), .wait(1), .replugHeld(1, 1), .wait(2)] + up(1) + settle),
        ("plugged in held, nothing readable: release goes through, no remap", [remap],
         [.unplug(0), .wait(1), .replugHeld(1, 2), .wait(2)] + up(1) + settle),
        ("held through a relaunch while another mouse holds the same button: both let go", [remap],
         [.oPress(1)] + down(1) + [.quit] + up(1) + [.oRelease(1)] + settle),
    ]
    gestureCases += both + held
    // The Wheel (Nov 18): a ring of slots around the pointer, the ball picks, the release runs it;
    // the ring is a dial while held. Every way a hold ends takes the ring down and runs nothing.
    var wheelC = GlideConfig()
    wheelC.buttons[3] = .wheel(.standard)
    var wheelZoom = GlideConfig()
    var zoomMenu = WheelMenu.standard
    zoomMenu.ring = .zoom
    wheelZoom.buttons[3] = .wheel(zoomMenu)
    wheelZoom.scrollMode = .flywheel
    var wheelCombo = GlideConfig()
    wheelCombo.chords = [Chord(buttons: [1, 3], action: .wheel(.standard))]
    var wheelPrimary = GlideConfig()
    wheelPrimary.chords = [Chord(buttons: [0, 2], action: .wheel(.standard))]
    wheelPrimary.buttons[0] = .wheel(.standard)
    let right = roll(5, 0, 12), slow = [Op.wait(0.3)]
    let wheels: [(String, [GlideConfig], [Op])] = [
        ("wheel: roll right and let go runs the right slot, once, after the release", [wheelC], down(3) + slow + right + up(3) + settle),
        ("wheel: a still press is the tap", [wheelC], down(3) + [.wait(0.1)] + up(3) + settle),
        ("wheel: a flick and release before the ring draws still runs that way", [wheelC],
         down(3) + [.kBall(0, -30), .wait(0.004), .kBall(0, -30)] + up(3) + settle),
        ("wheel: rolled out and back to the centre runs nothing", [wheelC], down(3) + slow + right + roll(-5, 0, 12) + up(3) + settle),
        ("wheel: ring turns zoom while held, never scroll, and the release runs nothing", [wheelZoom],
         flick + down(3) + (0..<6).flatMap { _ in [Op.kWheel(-1), .wait(0.06)] } + up(3) + settle),
        ("wheel: Esc dismisses it", [wheelC], down(3) + slow + right + [.esc] + right + up(3) + settle),
        ("wheel: another trackball button dismisses it", [wheelC], down(3) + slow + right + down(1) + up(1) + up(3) + settle),
        ("wheel: another mouse clicks meanwhile: the Wheel stays", [wheelC],
         down(3) + slow + right + [.oPress(1), .oRelease(1), .wait(0.2)] + up(3) + settle),
        ("wheel: on a combo, the first button up runs the slot", [wheelCombo], down(1, 3) + slow + right + up(3) + [.kBall(30, 0)] + up(1) + settle),
        ("wheel: never on the primary button, alone or in a combo", [wheelPrimary],
         down(0) + slow + right + up(0) + down(2, 0) + slow + right + up(0, 2) + settle),
        ("wheel: paused mid-hold: down, nothing runs", [wheelC], down(3) + slow + right + [.pause, .resume] + up(3) + settle),
        ("wheel: the Mac sleeps mid-hold: down, nothing runs", [wheelC], down(3) + slow + right + [.sleep, .wake] + up(3) + settle),
        ("wheel: quit mid-hold: down, nothing runs", [wheelC], down(3) + slow + right + [.quit] + up(3) + settle),
        ("wheel: unplugged mid-hold: down, nothing runs", [wheelC], down(3) + slow + right + [.unplug(0), .wait(1), .replug(0)] + settle),
        ("wheel: the tap switched off mid-hold: down, nothing runs", [wheelC], down(3) + slow + right + [.tapOff(1), .kBall(5, 0)] + up(3) + settle),
        ("wheel: past the 30 s limit: down, nothing runs", [wheelC], down(3) + slow + right + [.wait(31)] + up(3) + settle),
        ("wheel: the watchdog takes the ring down: nothing runs", [wheelC], down(3) + slow + right + [.wheelOverlay(2), .wait(0.5)] + up(3) + settle),
        // Seed 146703711: the watchdog took the ring down and the release came before the engine's
        // keeper had asked again (a held-up input thread's first event): the slot ran unseen.
        ("wheel: the watchdog takes the ring down, released at once: nothing runs", [wheelCombo],
         down(1, 3) + [.kBall(-3, 90), .wheelOverlay(2)] + up(1) + up(3) + settle),
        ("wheel: the watchdog takes the ring down, the ring turned at once: no step", [wheelZoom],
         down(3) + slow + right + [.wheelOverlay(2), .kWheel(-1)] + up(3) + settle),
        // Seeds 129 and 336: after the watchdog, the next roll changed what the ring showed and the
        // engine drew it again, as if nothing had happened, and the slot ran at the release.
        ("wheel: the watchdog takes the ring down, then a roll: not drawn again, nothing runs", [wheelC],
         down(3) + [.kBall(6, 90), .wheelOverlay(2), .kBall(-8, 90), .kBall(90, 0)] + up(3) + settle),
        ("wheel: nothing to draw it with: nothing runs, the pointer still freed", [wheelC], [.wheelOverlay(1)] + down(3) + slow + right + up(3) + settle),
        ("wheel: the watchdog takes the ring down right before the release: nothing runs", [wheelC],
         down(3) + slow + right + [.wheelOverlay(2)] + up(3) + settle),
        ("wheel: another mouse moves the hold: the ring follows the anchor", [wheelC],
         down(3) + slow + right + [.wait(0.3), .oBall, .wait(0.1)] + up(3) + settle),
    ]
    gestureCases += wheels
    // The Switcher (Nov 18): ⌘-Tab for the trackball. The list comes from the main thread (late,
    // or never, in some cases); the release switches once; every way a hold ends switches nothing.
    var swC = GlideConfig()
    swC.buttons[3] = .switcher(.standard)
    var swFly = swC
    swFly.scrollMode = .flywheel
    var swCombo = GlideConfig()
    swCombo.chords = [Chord(buttons: [1, 3], action: .switcher(.standard))]
    var swPrimary = GlideConfig()
    swPrimary.chords = [Chord(buttons: [0, 2], action: .switcher(.standard))]
    swPrimary.buttons[0] = .switcher(.standard)
    var swMix = GlideConfig()
    swMix.buttons[3] = .switcher(.standard)
    swMix.buttons[2] = .wheel(.standard)
    swMix.buttons[1] = .gesture(.standard)
    let switchers: [(String, [GlideConfig], [Op])] = [
        ("switcher: held still and let go flips to the previous app", [swC], down(3) + slow + up(3) + settle),
        ("switcher: roll right and let go switches to the next one, once, after the release", [swC], down(3) + slow + right + up(3) + settle),
        ("switcher: a quick still press is the tap", [swC], down(3) + [.wait(0.1)] + up(3) + settle),
        ("switcher: a flick and release before the panel's delay still switches", [swC],
         down(3) + [.kBall(30, 0), .wait(0.004), .kBall(30, 0)] + up(3) + settle),
        ("switcher: ring turns step the highlight, never scroll, and the release switches", [swFly],
         flick + down(3) + (0..<3).flatMap { _ in [Op.kWheel(-1), .wait(0.03)] } + up(3) + settle),
        ("switcher: Esc dismisses it", [swC], down(3) + slow + right + [.esc] + right + up(3) + settle),
        ("switcher: another trackball button dismisses it", [swC], down(3) + slow + right + down(1) + up(1) + up(3) + settle),
        ("switcher: another mouse clicks meanwhile: the Switcher stays", [swC],
         down(3) + slow + right + [.oPress(1), .oRelease(1), .wait(0.2)] + up(3) + settle),
        ("switcher: on a combo, the first button up switches", [swCombo], down(1, 3) + slow + right + up(3) + [.kBall(30, 0)] + up(1) + settle),
        ("switcher: never on the primary button, alone or in a combo", [swPrimary],
         down(0) + slow + right + up(0) + down(2, 0) + slow + right + up(0, 2) + settle),
        ("switcher: never held with a Wheel or a gesture", [swMix],
         down(3) + slow + down(2) + right + down(1) + up(2) + up(1) + up(3) + settle),
        ("switcher: paused mid-hold: down, nothing switches", [swC], down(3) + slow + right + [.pause, .resume] + up(3) + settle),
        ("switcher: the Mac sleeps mid-hold: down, nothing switches", [swC], down(3) + slow + right + [.sleep, .wake] + up(3) + settle),
        ("switcher: quit mid-hold: down, nothing switches", [swC], down(3) + slow + right + [.quit] + up(3) + settle),
        ("switcher: unplugged mid-hold: down, nothing switches", [swC], down(3) + slow + right + [.unplug(0), .wait(1), .replug(0)] + settle),
        ("switcher: the tap switched off mid-hold: down, nothing switches", [swC], down(3) + slow + right + [.tapOff(1), .kBall(5, 0)] + up(3) + settle),
        ("switcher: past the 30 s limit: down, nothing switches", [swC], down(3) + slow + right + [.wait(31)] + up(3) + settle),
        ("switcher: the watchdog takes the panel down: nothing switches", [swC],
         down(3) + slow + right + [.switcherPanel(2), .wait(0.5)] + up(3) + settle),
        ("switcher: the watchdog takes the panel down right before the release: nothing switches", [swC],
         down(3) + slow + right + [.switcherPanel(2)] + up(3) + settle),
        ("switcher: the panel can't be drawn: nothing switches, the pointer still freed", [swC],
         [.switcherPanel(1)] + down(3) + slow + right + up(3) + settle),
        ("switcher: nothing builds lists: a quick press is still the tap, a hold does nothing", [swC],
         [.switcherPanel(3)] + down(3) + [.wait(0.1)] + up(3) + down(3) + slow + right + up(3) + settle),
        ("switcher: the list comes late: the roll before it still counts", [swC],
         [.switcherPanel(5)] + down(3) + right + [.wait(0.5)] + up(3) + settle),
        ("switcher: the list never comes: nothing switches", [swC], [.switcherPanel(6)] + down(3) + slow + right + up(3) + settle),
        ("switcher: 40 apps, rolled far down: the lit row stays on screen", [swC],
         [.switcherPanel(13)] + down(3) + slow + roll(0, 6, 60) + up(3) + settle),
        ("switcher: another mouse moves the hold: the panel follows the anchor", [swC],
         down(3) + slow + right + [.wait(0.3), .oBall, .wait(0.1)] + up(3) + settle),
    ]
    gestureCases += switchers
    let older: [(String, [GlideConfig], [Op])] = [
        ("held shortcut, unplugged while held: the key comes up",
         [hold], [.kPress(3, hidFirst: true), .unplug(2), .wait(1)]),
        ("held shortcut, its release lost while the tap was off: the key comes up",
         [hold], [.kPress(3, hidFirst: true), .tapOff(1), .kRelease(3, hidFirst: true), .wait(1)]),
        ("remapped button, its release lost while the tap was off: the button comes up",
         [remap], [.kPress(1, hidFirst: true), .tapOff(1), .kRelease(1, hidFirst: true), .wait(1)]),
        ("remapped button held through quit: released",
         [remap], [.kPress(1, hidFirst: true), .quit, .kRelease(1, hidFirst: true)]),
        ("held shortcut held through sleep: released",
         [hold], [.kPress(3, hidFirst: true), .sleep, .kRelease(3, hidFirst: true)]),
        ("flywheel coasting at pause: stops", [fly], flick + [.pause, .wait(2)]),
        ("flywheel coasting at unplug: stops", [fly], flick + [.unplug(0), .wait(2)]),
        ("drag lock held through sleep: let go", [drag], [.kPress(2, hidFirst: true), .kRelease(2, hidFirst: true), .sleep, .wait(0.5)]),
        ("hostile numbers and a negative button: clamped, no crash",
         [hostile], flick + [.kPress(1, hidFirst: true), .kRelease(1, hidFirst: true), .kBall(5, 5), .wait(2)]),
        ("gesture held, unplugged: pointer freed", [g], [.kPress(3, hidFirst: true), .kBall(30, 0), .unplug(2), .wait(1)]),
        ("two buttons holding different shortcuts: letting go of one keeps the other's keys",
         [twoHolds], [.kPress(1, hidFirst: true), .kPress(3, hidFirst: true), .kRelease(1, hidFirst: true), .wait(0.1),
                      .kRelease(3, hidFirst: true), .wait(1)]),
        ("two buttons holding the same shortcut: one key down, one key up",
         [sameHolds], [.kPress(1, hidFirst: true), .kPress(3, hidFirst: true), .kRelease(1, hidFirst: true), .kRelease(3, hidFirst: true), .wait(1)]),
        ("a button remapped to left click held, then the primary: never a double press",
         [toLeft], [.kPress(2, hidFirst: true), .kPress(0, hidFirst: true), .kRelease(0, hidFirst: true), .kRelease(2, hidFirst: true), .wait(1)]),
        ("the primary pressed with the trackball's report late, while a remap holds left",
         [toLeft], [.kPress(2, hidFirst: true), .kPress(0, hidFirst: false), .kRelease(0, hidFirst: true), .kRelease(2, hidFirst: true), .wait(1)]),
        ("keyboard drag lock while the left button is held: doesn't start",
         [GlideConfig()], [.kPress(0, hidFirst: true), .setMode(2, 1), .kRelease(0, hidFirst: true), .wait(1)]),
        ("a combo button waiting at a pause: never starts a drag lock while paused",
         [comboDrag], [.kPress(2, hidFirst: true), .pause, .kRelease(2, hidFirst: true), .wait(1)]),
        ("a combo button waiting at an unplug: never replayed",
         [comboRemap], [.kPress(1, hidFirst: true), .unplug(2), .wait(1)]),
        ("a combo button whose release went by while the tap was off: a whole click, nothing stuck",
         [comboRemap], [.kPress(1, hidFirst: true), .tapOff(1), .kRelease(1, hidFirst: true), .wait(1)]),
        ("Quick assign restarted while a button is held: its release is still swallowed",
         [GlideConfig()], [.learn, .kPress(1, hidFirst: true), .learn, .kRelease(1, hidFirst: true), .wait(1)]),
        ("trackball unplugged: another mouse's release of the same button isn't swallowed",
         [primaryCombo], [.kPress(1, hidFirst: true), .kPress(0, hidFirst: true), .wait(1), .unplug(2), .oPress(0), .replug(0),
                          .oRelease(0), .wait(1)]),
        ("ring ticks handled back to back with smooth scrolling off: bounded", [jumpy], Array(repeating: .kWheel(-1), count: 8) + [.wait(1)]),
        ("its own button with a modifier, after a button remapped to it", [selfMod],
         [.kPress(1, hidFirst: true), .kPress(2, hidFirst: true), .kRelease(2, hidFirst: true), .kRelease(1, hidFirst: true), .wait(1)]),
    ]
    return gestureCases + older
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let eventsPerSeed = Int(value("--events") ?? "") ?? 20_000
var seeds: [UInt64] = []
if let range = value("--seeds") {
    let parts = range.split(separator: "-").compactMap { UInt64($0) }
    if parts.count == 2 { seeds = Array(parts[0]...parts[1]) }
}
if let s = value("--seed").flatMap(UInt64.init) { seeds.append(s) }
if args.contains("--random") {
    var g = SystemRandomNumberGenerator()
    let s = g.next() % 1_000_000_000
    print("random seed: \(s) (replay: scripts/engine-fuzz/run.sh --seed \(s) --events \(eventsPerSeed))")
    seeds.append(s)
}
let minutes = Double(value("--minutes") ?? "") ?? 0

// The diagnostics log goes to a temp folder, never ~/Library/Logs/Glide.
Diagnostics.folder = FileManager.default.temporaryDirectory.appendingPathComponent("glide-engine-fuzz-\(getpid())")
defer { try? FileManager.default.removeItem(at: Diagnostics.folder) }

// MARK: - Threads (for the thread sanitizer)

/// The engine as the app runs it: its own input thread and run loop, the key queue, real
/// timers and main-thread callbacks, while "the UI" (this main thread) changes settings,
/// pauses, toggles modes and samples the telemetry, and events arrive on the input thread
/// the way the tap and IOHIDManager deliver them. Nothing reaches the real Mac: every
/// effect goes to this fake, and scrolling to a counter. Built with -sanitize=thread
/// (run.sh --tsan --threads), it shows any data race between those threads.
final class ThreadedIO: EngineIO {
    private let lock = NSLock()
    private var counts = (posted: 0, frozen: false, applied: 0)
    private var enabled: [ObjectIdentifier: Bool] = [:]
    override func cursorLocation() -> CGPoint? { CGPoint(x: 300, y: 300) }
    override func keyboardFlags() -> CGEventFlags { [] }
    override func freezePointer(_ frozen: Bool) { lock.withLock { counts.frozen = frozen } }
    override func showStandIn(at point: CGPoint) -> Bool { lock.withLock { standIns += 1 }; return true }   // never a real window
    override func hideStandIn() { lock.withLock { standIns = 0 } }
    override func keepStandIn() -> Bool { lock.withLock { standIns > 0 } }
    override func standInProblem() -> String? { nil }
    private var standIns = 0
    override func showWheel(_ model: WheelOverlayModel, at point: CGPoint) -> Bool { lock.withLock { wheels += 1 }; return true }   // never a real window
    override func hideWheel() { lock.withLock { wheels = 0 } }
    override func keepWheel() -> Bool { lock.withLock { wheels > 0 } }
    private var wheels = 0
    override func post(_ event: CGEvent, tap: CGEventTapLocation) { lock.withLock { counts.posted += 1 } }
    override func buttonsDown() -> Set<Int64> { [] }
    override var naturalScrolling: Bool { true }
    override var savedScrollDirection: Double { get { 0 } set {} }
    override func openApp(_ bundleID: String) {}
    override func applyPointer(_ settings: PointerTuner.Settings) { lock.withLock { counts.applied += 1 } }
    override func restorePointer() {}
    override func pointerDevicesChanged() {}
    override func installTap(mask: CGEventMask, engine: Engine, runLoop: CFRunLoop?) -> (CFMachPort, CFRunLoopSource)? {
        var ctx = CFMachPortContext()
        guard let port = CFMachPortCreate(nil, { _, _, _, _ in }, &ctx, nil),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        lock.withLock { enabled[ObjectIdentifier(port)] = true }
        return (port, source)
    }
    override func removeTap(_ tap: CFMachPort, source: CFRunLoopSource?, runLoop: CFRunLoop?) {
        lock.withLock { enabled[ObjectIdentifier(tap)] = nil }
        CFMachPortInvalidate(tap)
    }
    override func tapIsEnabled(_ tap: CFMachPort) -> Bool { lock.withLock { enabled[ObjectIdentifier(tap)] ?? false } }
    override func tapEnable(_ tap: CFMachPort, _ on: Bool) { lock.withLock { enabled[ObjectIdentifier(tap)] = on } }
    override func startListening(_ engine: Engine, runLoop: CFRunLoop?) -> Bool { true }
    override func echoReason(_ key: Int, trackballs: Set<Int>) -> String? { nil }   // never the real registry
    var posted: Int { lock.withLock { counts.posted } }
}

func runThreads(seconds: Double, seed: UInt64) -> Bool {
    var r = RNG(seed)
    let configs = (0..<6).map { _ in randomConfig(&r) }
    let io = ThreadedIO()
    let engine = Engine(config: configs[0], io: io)
    let scrolled = OSAllocatedUnfairLockBox()
    engine.scroller.output = { d in scrolled.add(abs(d)) }            // never a real scroll event
    engine.scroller.ballOutput = { x, y in scrolled.add(abs(x) + abs(y)) }
    var modes = Engine.Modes()
    var statusUpdates = 0
    engine.onModes = { modes = $0 }
    engine.onStatus = { _ in statusUpdates += 1 }
    engine.start()
    keepAlive = engine   // the input thread runs until exit, as in the app (where the engine lives forever)
    engine.perform { engine.deviceAdded(key: kKey, identity: expert, transport: "USB", device: nil) }
    var stamp: UInt64 = 1
    var held = Set<Int>()
    let end = Date().addingTimeInterval(seconds)
    var steps = 0
    var enabled = true
    while Date() < end {
        steps += 1
        switch r.int(20) {
        case 0...7:
            // A button, from the trackball: HID first, then the tap, both on the input thread.
            let b = r.int(5)
            let down = !held.contains(b)
            if down { held.insert(b) } else { held.remove(b) }
            stamp += 1
            let s = stamp
            engine.perform {
                engine.hidInput(key: kKey, identity: expert, page: kHIDPage_Button, usage: b + 1, value: down ? 1 : 0, stamp: s)
                let e = CGEvent(mouseEventSource: nil, mouseType: World.type(b, down ? 0 : 1), mouseCursorPosition: .zero,
                                mouseButton: CGMouseButton(rawValue: UInt32(b)) ?? .center)!
                e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b))
                _ = engine.handle(e.type, e)
            }
        case 8...10:
            stamp += 1
            let s = stamp, dx = r.int(41) - 20, wheel = r.chance(0.3)
            engine.perform {
                if wheel {
                    engine.hidInput(key: kKey, identity: expert, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: dx > 0 ? 1 : -1, stamp: s)
                } else {
                    engine.hidInput(key: kKey, identity: expert, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: dx, stamp: s)
                }
            }
        case 11:
            var c = configs[r.int(configs.count)]
            c.enabled = enabled
            engine.update(c)
        case 12:
            enabled.toggle()
            if !enabled { engine.releaseHeldKeys(); engine.releaseAll() }
            var c = configs[0]
            c.enabled = enabled
            engine.update(c)
        case 13: engine.setMode([.precision, .ballScroll, .dragLock][r.int(3)], on: r.chance(0.5) ? nil : r.chance(0.5)) { _ in }
        case 14: _ = engine.telemetry.sample(); _ = engine.telemetry.takePeaks(); _ = engine.telemetry.totals
        case 15: engine.releaseForSleep(); engine.reapplyPointer()
        case 16: engine.setDisplays([DisplayRegion(key: "d1", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                                     DisplayRegion(key: "d2", bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800))])
        case 17: engine.learnNextPress(r.chance(0.5) ? { _ in } : nil); engine.note("fuzz")
        case 18: engine.setBetaProgram(r.chance(0.5)); engine.setGesturePractice(r.chance(0.5))
        default:
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))   // main-thread callbacks
        }
    }
    engine.releaseHeldKeys()
    engine.releaseAll()
    engine.handBackPointer()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print(String(format: "threads: %d steps in %.0f s; %d events posted, %d status and %@ updates on main, %.0f pt scrolled",
                 steps, seconds, io.posted, statusUpdates, modes.dragLocked ? "mode (drag lock on)" : "mode", scrolled.value))
    return true
}

var keepAlive: Engine?

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0.0
    func add(_ v: Double) { lock.withLock { total += v } }
    var value: Double { lock.withLock { total } }
}

var failed = 0
if args.contains("--threads") {
    Diagnostics.folder = FileManager.default.temporaryDirectory.appendingPathComponent("glide-engine-threads-\(getpid())")
    let ok = runThreads(seconds: Double(value("--seconds") ?? "") ?? 10, seed: UInt64(value("--seed") ?? "") ?? 1)
    try? FileManager.default.removeItem(at: Diagnostics.folder)
    exit(ok ? 0 : 1)
}
/// What a regression case must also have done (beyond every rule holding).
let expectations: [String: (World) -> String?] = [
    "chained gesture: left, up, left in one hold fires twice left only if not once": { w in
        w.hold?.byDirection == [.left: 1, .up: 1] ? nil : "fired \(w.hold?.byDirection ?? [:]), expected left once (once per hold) and up once" },
    "chained gesture: right three times, numbered 1, 2, 3": { w in
        w.hold?.byDirection == [.right: 3] && w.modes.gestureFlash?.chain == 3 ? nil : "fired \(w.hold?.byDirection ?? [:])" },
    "gesture combo: holds, fires, ends with the first button up": { w in
        w.hold?.buttons == [1, 3] && w.hold?.byDirection == [.right: 1] ? nil : "hold \(String(describing: w.hold?.buttons)) fired \(w.hold?.byDirection ?? [:])" },
    "gesture combo with the primary button: never a gesture": { w in w.hold == nil ? nil : "a gesture hold started" },
    "gesture combo pressed with the ball jiggling: still the combo's gesture": { w in
        w.hold?.buttons == [1, 3] && w.hold?.byDirection == [.right: 1] ? nil : "hold \(String(describing: w.hold?.buttons)) fired \(w.hold?.byDirection ?? [:])" },
    "Steady hands: a short roll doesn't fire, a long one does": { w in
        w.gestureFires == 1 ? nil : "\(w.gestureFires) fires, expected 1 (the 60-count roll only)" },
    "a gesture's own Long distance: 60 counts don't fire": { w in w.gestureFires == 0 ? nil : "\(w.gestureFires) fires" },
    // The stand-in: shown for each hold (the rules check it came down), or never when it can't be.
    "stand-in: a fast roll in another app, up at the hold, down on release": { w in standInShown(w, 1) },
    "stand-in: Scroll with ball, paused mid-hold": { w in standInShown(w, 1) },
    "stand-in: a gesture hold, unplugged mid-hold": { w in standInShown(w, 1) },
    "stand-in: Scroll with ball, the Mac sleeps mid-hold": { w in standInShown(w, 1) },
    "stand-in: a gesture hold through quit": { w in standInShown(w, 1) },
    "stand-in: a gesture hold, the tap switched off": { w in w.io.standInShows >= 1 ? nil : "never shown" },
    "stand-in: a gesture hold past its 30 s limit": { w in standInShown(w, 1) },
    "stand-in: Scroll with ball, another mouse moves the hold": { w in standInShown(w, 1) },
    "stand-in: Scroll with ball from the keyboard, the trackpad moves the pointer: the stand-in goes with it": { w in
        w.io.standInMoves == 2 ? standInShown(w, 1) : "the stand-in moved \(w.io.standInMoves) times, expected 2" },
    "stand-in unavailable: the hold works as before": { w in
        w.io.standInShows == 0 && w.io.warps > 0 ? nil : "shown \(w.io.standInShows) times, \(w.io.warps) put-backs" },
    "stand-in taken down by the watchdog: the hold goes on without it": { w in standInShown(w, 2) },
    // Two devices on one button: exactly what apps saw (`remap` is button 1 → middle, 2).
    "same button: another mouse presses and lets go while the trackball's remap holds": { w in
        expectLog(w, ["kensington down 2", "other down 1", "other up 1", "kensington up 2"]) },
    "same button: another mouse holds it while the trackball presses and lets go": { w in
        expectLog(w, ["other down 1", "kensington down 2", "kensington up 2", "other up 1"]) },
    "same button: a held shortcut stays down through another mouse's click": { w in
        let keys = w.outLog.filter { $0.hasPrefix("key") }, others = w.outLog.filter { $0.hasPrefix("other") }
        guard others == ["other down 3", "other up 3"] else { return "other mouse: \(others)" }
        guard let otherUp = w.outLog.firstIndex(of: "other up 3"), let keyUp = w.outLog.lastIndex(where: { $0.hasPrefix("key up") }),
              keyUp > otherUp, keys.count == 2 else { return "keys \(keys) around the other mouse's click: \(w.outLog)" }
        return nil
    },
    "same button: a trackpad click while the trackball's press is swallowed": { w in
        expectLog(w, ["trackpad down 1", "trackpad up 1"]) },
    "same button: the trackball's release before its report, another mouse holding": { w in
        expectLog(w, ["other down 1", "kensington down 2", "kensington up 2", "other up 1"]) },
    "same button: another mouse's release before its report, the trackball holding": { w in
        expectLog(w, ["kensington down 2", "other down 1", "other up 1", "kensington up 2"]) },
    "same button: the trackball's press before its report, another mouse holding": { w in
        // (Its event came first, with nothing to say whose it was: it passes as it is, as such
        // presses always have, and its release is the trackball's.)
        expectLog(w, ["other down 1", "kensington down 1", "kensington up 1", "other up 1"]) },
    "same button: another mouse right after the trackball's click (was within 0.3 s)": { w in
        expectLog(w, ["kensington down 2", "kensington up 2", "other down 1", "other up 1"]) },
    "held through a relaunch, remapped: its release is swallowed": { w in
        expectLog(w, ["kensington down 2", "glideball up 2"]) },
    "held through a relaunch, its own click: its release goes through": { w in
        expectLog(w, ["kensington down 2", "kensington up 2"]) },
    "pressed while paused, released after resuming: a plain click": { w in
        expectLog(w, ["kensington down 1", "kensington up 1"]) },
    "pressed while the tap was off, released after: its release goes through": { w in
        expectLog(w, ["kensington down 1 raw", "kensington up 1"]) },
    "plugged in held, its report before Glideball had it open: release goes through, no remap": { w in
        expectLog(w, ["kensington down 1 raw", "kensington up 1"]) },
    "plugged in held, its report after the add: release goes through, no remap": { w in
        expectLog(w, ["kensington down 1 raw", "kensington up 1"]) },
    "plugged in held, nothing readable: release goes through, no remap": { w in
        expectLog(w, ["kensington down 1 raw", "kensington up 1"]) },
    "wheel: roll right and let go runs the right slot, once, after the release": { w in
        wheelDid(w, holds: 1, picks: 1, shows: 1) ?? (w.modes.wheelFlash?.kind == .slot(2) ? nil : "ran \(String(describing: w.modes.wheelFlash))") },
    "wheel: a still press is the tap": { w in wheelDid(w, holds: 1, picks: 0, taps: 1) },
    "wheel: a flick and release before the ring draws still runs that way": { w in
        wheelDid(w, holds: 1, picks: 1) ?? (w.modes.wheelFlash?.kind == .slot(0) ? nil : "ran \(String(describing: w.modes.wheelFlash))") },
    "wheel: rolled out and back to the centre runs nothing": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: ring turns zoom while held, never scroll, and the release runs nothing": { w in
        let keys = w.outLog.filter { $0.hasPrefix("key down") }.count
        return wheelDid(w, holds: 1, picks: 0, ring: 6, shows: 1) ?? (keys >= 6 ? nil : "\(keys) key presses for 6 zoom steps") },
    "wheel: Esc dismisses it": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: another trackball button dismisses it": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: another mouse clicks meanwhile: the Wheel stays": { w in wheelDid(w, holds: 1, picks: 1, shows: 1) },
    "wheel: on a combo, the first button up runs the slot": { w in wheelDid(w, holds: 1, picks: 1, shows: 1) },
    "wheel: never on the primary button, alone or in a combo": { w in wheelDid(w, holds: 0, picks: 0, shows: 0) },
    "wheel: paused mid-hold: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: the Mac sleeps mid-hold: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: quit mid-hold: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: unplugged mid-hold: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: the tap switched off mid-hold: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: past the 30 s limit: down, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: the watchdog takes the ring down: nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: the watchdog takes the ring down, released at once: nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: the watchdog takes the ring down, the ring turned at once: no step": { w in wheelDid(w, holds: 1, picks: 0, ring: 0, shows: 1) },
    "wheel: the watchdog takes the ring down, then a roll: not drawn again, nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "wheel: nothing to draw it with: nothing runs, the pointer still freed": { w in wheelDid(w, holds: 1, picks: 0, shows: 0) },
    "wheel: the watchdog takes the ring down right before the release: nothing runs": { w in wheelDid(w, holds: 1, picks: 0, shows: 1) },
    "switcher: the watchdog takes the panel down right before the release: nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "wheel: another mouse moves the hold: the ring follows the anchor": { w in wheelDid(w, holds: 1, picks: 1, shows: 1) },
    "switcher: held still and let go flips to the previous app": { w in switcherDid(w, holds: 1, to: [1], shows: 1) },
    "switcher: roll right and let go switches to the next one, once, after the release": { w in switcherDid(w, holds: 1, to: [2], shows: 1) },
    "switcher: a quick still press is the tap": { w in
        switcherDid(w, holds: 1, to: [], taps: 1, shows: 0) },
    "switcher: a flick and release before the panel's delay still switches": { w in switcherDid(w, holds: 1, to: [2]) },
    "switcher: ring turns step the highlight, never scroll, and the release switches": { w in switcherDid(w, holds: 1, to: [4], shows: 1) },
    "switcher: Esc dismisses it": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: another trackball button dismisses it": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: another mouse clicks meanwhile: the Switcher stays": { w in switcherDid(w, holds: 1, to: [2], shows: 1) },
    "switcher: on a combo, the first button up switches": { w in switcherDid(w, holds: 1, to: [2], shows: 1) },
    "switcher: never on the primary button, alone or in a combo": { w in switcherDid(w, holds: 0, to: [], shows: 0) },
    "switcher: never held with a Wheel or a gesture": { w in
        switcherDid(w, holds: 1, to: [], shows: 1) ?? (w.wheelHolds == 0 && w.gestureHolds == 0 ? nil : "a Wheel or gesture started during the Switcher hold") },
    "switcher: paused mid-hold: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: the Mac sleeps mid-hold: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: quit mid-hold: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: unplugged mid-hold: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: the tap switched off mid-hold: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: past the 30 s limit: down, nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: the watchdog takes the panel down: nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 1) },
    "switcher: the panel can't be drawn: nothing switches, the pointer still freed": { w in switcherDid(w, holds: 1, to: [], shows: 0) },
    "switcher: nothing builds lists: a quick press is still the tap, a hold does nothing": { w in switcherDid(w, holds: 2, to: [], taps: 1, shows: 0) },
    "switcher: the list comes late: the roll before it still counts": { w in switcherDid(w, holds: 1, to: [2], shows: 1) },
    "switcher: the list never comes: nothing switches": { w in switcherDid(w, holds: 1, to: [], shows: 0) },
    "switcher: 40 apps, rolled far down: the lit row stays on screen": { w in
        switcherDid(w, holds: 1, to: nil, shows: 1) ?? (w.io.activations.count == 1 ? nil : "\(w.io.activations.count) switches") },
    "switcher: another mouse moves the hold: the panel follows the anchor": { w in switcherDid(w, holds: 1, to: [2], shows: 1) },
]

/// What the Switcher did over a case: holds, the apps switched to (nil: don't judge which), taps,
/// times its panel went up.
func switcherDid(_ w: World, holds: Int, to: [Int]?, taps: Int = 0, shows: Int? = nil) -> String? {
    if w.switcherHolds != holds { return "\(w.switcherHolds) Switcher holds, expected \(holds)" }
    let went = w.io.activations.map(\.index)
    if let to, went != to { return "switched to \(went), expected \(to)" }
    if w.switcherTaps != taps { return "\(w.switcherTaps) Switcher taps, expected \(taps)" }
    if let shows, w.io.switcherShows != shows { return "the panel went up \(w.io.switcherShows) times, expected \(shows)" }
    if w.io.switcher != nil { return "the panel is still up at the end" }
    return nil
}

/// What the Wheel did over a case: holds, slots run, ring steps, taps, times its ring went up.
func wheelDid(_ w: World, holds: Int, picks: Int, ring: Int = 0, taps: Int = 0, shows: Int? = nil) -> String? {
    let did = (w.wheelHolds, w.wheelPicks, w.wheelRingSteps, w.wheelTaps)
    if did != (holds, picks, ring, taps) { return "Wheel holds/slots/ring steps/taps \(did), expected \((holds, picks, ring, taps))" }
    if let shows, w.io.wheelShows != shows { return "the ring went up \(w.io.wheelShows) times, expected \(shows)" }
    if w.io.wheel != nil { return "the ring is still up at the end" }
    return nil
}

/// The stand-in went up `n` times (once per hold) and is down now.
func standInShown(_ w: World, _ n: Int) -> String? {
    w.io.standInShows == n && w.io.standIn == nil && !w.io.realHidden ? nil
        : "stand-in shown \(w.io.standInShows) times (expected \(n)), \(w.io.standIn == nil ? "down" : "still up") at the end"
}

/// The button events and keys apps saw, exactly.
func expectLog(_ w: World, _ want: [String]) -> String? {
    w.outLog == want ? nil : "apps saw \(w.outLog), expected \(want)"
}
print("▸ regression cases")
keepOutLog = true
for (name, configs, ops) in regressionCases() {
    echoShadow = name.contains("shadow pointer")
    if let (f, i) = run(configs, ops) {
        failed += 1
        print("  ✗ \(name): \(f) at op \(i)")
    } else if let w = lastWorld, let problem = expectations[name]?(w) {
        failed += 1
        print("  ✗ \(name): \(problem)")
    } else {
        print("  ✓ \(name)")
    }
}
keepOutLog = false
if args.contains("--regressions-only") { exit(failed == 0 ? 0 : 1) }

print("▸ random sequences (\(eventsPerSeed) events per seed)")
let started = Date()
var totalEvents = 0
var seedIndex = 0
var nextSeed: UInt64 = 1_000_000
while true {
    let seed: UInt64
    if seedIndex < seeds.count { seed = seeds[seedIndex] }
    else if minutes > 0 && Date().timeIntervalSince(started) < minutes * 60 { seed = nextSeed; nextSeed += 1 }
    else { break }
    seedIndex += 1
    let (configs, ops) = generate(seed: seed, count: eventsPerSeed)
    echoShadow = seed % 2 == 1   // half the seeds have a driver's shadow pointer beside the trackball
    totalEvents += ops.count
    if let (f, i) = run(configs, ops) {
        failed += 1
        print("  ✗ seed \(seed): \(f) (at event \(i) of \(ops.count))")
        let small = minimize(configs, Array(ops.prefix(i + 1)), rule: f.rule)
        if ProcessInfo.processInfo.environment["FUZZ_TRACE"] != nil {
            tracing = true
            print("    trace of the minimized events:")
            _ = run(configs, small)
            tracing = false
            if let w = lastWorld {
                w.engine.diagnostics.flush()
                print("    the engine's own log:")
                for line in ((try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(40) {
                    print("      | \(line)")
                }
            }
        }
        let (f2, _) = run(configs, small) ?? (f, 0)
        print("    minimized to \(small.count) events: \(f2)")
        for (k, c) in configs.enumerated() { print("    settings(\(k)): \(describe(c.clamped()))") }
        for op in small { print("      \(op)") }
        if failed >= 5 { break }
    }
    if seedIndex % 50 == 0 {
        print(String(format: "  … %d seeds, %d events, %.0f s", seedIndex, totalEvents, Date().timeIntervalSince(started)))
    }
}
let secs = Date().timeIntervalSince(started)
print("  gestures: \(statHolds) holds, \(statFires) fires (\(statChained) chained), \(statTaps) taps")
print("  wheels: \(statWheelHolds) holds, \(statWheelPicks) slots run, \(statWheelRing) ring steps, \(statWheelTaps) taps")
print("  switchers: \(statSwitcherHolds) holds, \(statSwitcherPanels) panels shown, \(statSwitches) switches, \(statSwitcherTaps) taps")
print(String(format: "%d seeds, %d events in %.1f s (%.0f events/s): %@", seedIndex, totalEvents, secs,
             Double(totalEvents) / max(secs, 0.001), failed == 0 ? "all rules held" : "\(failed) FAILED"))
exit(failed == 0 ? 0 : 1)
