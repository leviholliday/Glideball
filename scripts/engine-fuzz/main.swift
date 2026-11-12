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
//   others      other mice and the trackpad pass through untouched
//   scrolling   the flywheel never scrolls after pause, unplug or sleep, never runs
//               away (bounded per frame, stops after the last input), never NaN
//   pointer     pointer speeds only while running, finite, inside the app's limits
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
    override func freezePointer(_ f: Bool) { frozen = f }
    override func post(_ event: CGEvent, tap: CGEventTapLocation) { posted.append(event) }
    var appButtons: () -> Set<Int64> = { [] }
    override func buttonsDown() -> Set<Int64> { appButtons() }
    override func keys(_ work: @escaping () -> Void) { keyWork.append(work) }
    override func keysNow(_ work: () -> Void) { work() }
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
        if mask == CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue) { moveTap = port } else { mainTap = port }
        return (port, source)
    }
    override func removeTap(_ tap: CFMachPort, source: CFRunLoopSource?, runLoop: CFRunLoop?) {
        tapEnabled[ObjectIdentifier(tap)] = nil
        tapMask[ObjectIdentifier(tap)] = nil
        if moveTap === tap { moveTap = nil }
        if mainTap === tap { mainTap = nil }
        CFMachPortInvalidate(tap)
    }
    override func tapIsEnabled(_ tap: CFMachPort) -> Bool { tapEnabled[ObjectIdentifier(tap)] ?? false }
    override func tapEnable(_ tap: CFMachPort, _ on: Bool) {
        if tapEnabled[ObjectIdentifier(tap)] != nil { tapEnabled[ObjectIdentifier(tap)] = on }
    }
    override func startListening(_ engine: Engine, runLoop: CFRunLoop?) -> Bool { inputMonitoring }

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
    case padClick(Int), padScroll
    case keyboard(UInt64)
    case wait(Double)
    case config(Int)
    case remote(Int)          // sync applying another Mac's settings (same path as config)
    case front(Int)           // app in front: -1 none, else app setup index
    case pause, resume
    case unplug(Int)          // 0: ups after removal, 1: before, 2: lost
    case replug
    case sleep, wake
    case tapOff(Int)          // this many events go by the switched-off tap
    case setMode(Int, Int)    // mode, wanted (0 off, 1 on, 2 toggle)
    case learn
    case practice(Bool)
    case displays(Int)
    case beta(Bool)
    case quit

    var description: String {
        switch self {
        case .kPress(let b, let h): "kPress(\(b)\(h ? "" : ", cgFirst"))"
        case .kRelease(let b, let h): "kRelease(\(b)\(h ? "" : ", cgFirst"))"
        case .kBall(let x, let y): "kBall(\(x),\(y))"
        case .kWheel(let t): "kWheel(\(t))"
        case .oPress(let b): "otherMousePress(\(b))"
        case .oRelease(let b): "otherMouseRelease(\(b))"
        case .oWheel(let t): "otherMouseWheel(\(t))"
        case .oBall: "otherMouseMove"
        case .padClick(let b): "trackpadClick(\(b))"
        case .padScroll: "trackpadScroll"
        case .keyboard(let f): "keyboardModifiers(0x\(String(f, radix: 16)))"
        case .wait(let t): String(format: "wait(%.3f)", t)
        case .config(let i): "settings(\(i))"
        case .remote(let i): "syncAppliesRemote(\(i))"
        case .front(let i): "appInFront(\(i))"
        case .pause: "pause"
        case .resume: "resume"
        case .unplug(let m): "unplug(\(["upsAfter", "upsBefore", "upsLost"][m]))"
        case .replug: "replug"
        case .sleep: "sleep"
        case .wake: "wake"
        case .tapOff(let n): "tapSwitchedOffByMacOS(\(n) events lost)"
        case .setMode(let m, let w): "setMode(\(["precision", "ballScroll", "dragLock"][m]), \(["off", "on", "toggle"][w]))"
        case .learn: "quickAssignListens"
        case .practice(let on): "gesturePractice(\(on))"
        case .displays(let n): "displays(\(n))"
        case .beta(let on): "otherTrackballs(\(on))"
        case .quit: "quitAndRelaunch"
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
    default:
        var g = r.pick([ButtonGesture.standard, .media, .tabs, .zoom])
        if r.chance(0.5) { g.tap = r.chance(0.3) ? randomAction(&r) : randomPlainAction(&r) }
        if r.chance(0.3) { g.up = GestureStep(randomPlainAction(&r), repeats: r.chance(0.5)) }
        return .gesture(g)
    }
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
        if set.count >= 2 || r.chance(0.1) { c.chords.append(Chord(buttons: set.sorted(), action: randomAction(&r))) }
    }
    if r.chance(0.6) { c = c.withoutPrimaryChords() }
    c.gesturesEnabled = r.chance(0.8)
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

    // What apps see.
    var appK: [Int: Int] = [:]          // Kensington-side buttons down (engine-processed and raw)
    var tainted = Set<Int>()            // a raw (tap-off) event touched this button
    var passedThrough = Set<Int>()
    var heldThroughRelaunch = Set<Int>()      // down because the trackball's own press of it passed: macOS's state
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

    static let modifierCodes: Set<UInt16> = [UInt16(kVK_Control), UInt16(kVK_Option), UInt16(kVK_Shift), UInt16(kVK_Command)]

    init(configs: [GlideConfig]) {
        self.configs = configs
        mainConfig = configs[0]
        engine = Engine(config: configs[0], io: io)
        wire()
        engine.startInline()
        engine.deviceAdded(key: kKey, identity: expert, transport: "USB", device: nil)
        engine.deviceAdded(key: oKey, identity: otherMouse, transport: "USB", device: nil)
        settle()
    }

    func wire() {
        engine.onModes = { [unowned self] m in self.modes = m }
        io.appButtons = { [unowned self] in
            Set(self.appK.filter { $0.value > 0 }.keys.map(Int64.init)).union(self.appO.filter { $0.value > 0 }.keys.map(Int64.init))
        }
        engine.scroller.output = { [unowned self] d in self.scrolled(abs(d)) }
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

    /// Another mouse (or the trackpad) pressed a button number the trackball is holding, or
    /// the other way round. macOS doesn't say which device a click came from, so the engine
    /// can't tell those presses apart (see docs/DIAGNOSIS-2026-11.md, "not fixed"): until
    /// every button is up again, button pairing isn't judged. Keys still are.
    var ambiguous = false

    func fail(_ rule: String, _ detail: String) {
        if ambiguous && (rule == "paired" || rule == "others" || (rule == "released" && detail.hasPrefix("button"))) { return }
        violations.append(Failure(rule: rule, detail: detail))
    }

    func markAmbiguity(kensington b: Int) {
        if oDown.contains(b) || (appO[b] ?? 0) > 0 { ambiguous = true }
    }

    func markAmbiguity(other b: Int) {
        if kDown.contains(b) || (appK[b] ?? 0) > 0 || (kLastHIDDown[b].map { io.clock - $0 < 0.31 } ?? false) || learning {
            ambiguous = true
        }
    }

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
        engine.hidInput(key: key, identity: key == kKey ? expert : otherMouse, page: page, usage: usage, value: value, stamp: stamp)
        if key == kKey && page == kHIDPage_Button && value != 0 {
            kReportsButtons = true   // as the engine: a press over HID, not just a release
            kLastHIDDown[usage - 1] = io.clock
        }
    }

    /// An event reaching the session: through the engine's tap if it's on and wants it,
    /// otherwise straight to apps (`raw`).
    func deliver(_ e: CGEvent, source: Source) {
        let type = e.type
        if bypass > 0, io.sees(io.mainTap, type) || (type == .mouseMoved && io.moveTap != nil) {
            // The tap was switched off by macOS: this one goes by untouched. Then macOS
            // tells the engine, which switches it back on.
            bypass -= 1
            // The engine misses this one; until everything's up again, buttons can't be judged.
            if type != .scrollWheel && type != .flagsChanged { ambiguous = true }
            emit(e, raw: true)
            if bypass == 0 { tapComesBack() }
            return
        }
        let tap = type == .mouseMoved ? io.moveTap : io.mainTap
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
        let e = CGEvent(source: nil)!
        io.tapEnable(t, false)
        if let m = io.moveTap { io.tapEnable(m, false) }
        _ = engine.handle(.tapDisabledByTimeout, e)
        graceUntil = io.clock + 1.0
    }

    /// Other mice and the trackpad: what went in comes out, once, unchanged.
    func checkUntouched(id: Int, before: (type: CGEventType, button: Int64, flags: CGEventFlags),
                        out: (type: CGEventType, button: Int64, flags: CGEventFlags)?, dragLockedBefore: Bool) {
        guard let info = inputs[id] else { return }
        let b = info.button
        // Ambiguous by design: the trackball holds (or just pressed) the same button, so
        // the engine can't tell whose press this is; Quick assign listening; the press
        // that ends a drag lock (and its release) is the lock's.
        let kAmbiguous = kDown.contains(b) || (kLastHIDDown[b].map { io.clock - $0 < 0.31 } ?? false)
            || (!kReportsButtons) || learning
        if before.type == .leftMouseDown || before.type == .rightMouseDown || before.type == .otherMouseDown {
            if dragLockedBefore && (b == 0 || before.type == .leftMouseDown) { swallowedOther.insert(b); return }
        }
        if before.type == .leftMouseUp || before.type == .rightMouseUp || before.type == .otherMouseUp, swallowedOther.contains(b) {
            swallowedOther.remove(b); return
        }
        if before.type == .leftMouseDragged || before.type == .rightMouseDragged || before.type == .otherMouseDragged, swallowedOther.contains(b) { return }
        if kAmbiguous { tainted.insert(b); return }
        guard let out else { return fail("others", "\(info.source) \(before.type.rawValue) of button \(b) was swallowed") }
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
            if isOther {
                switch phase {
                case 0: appO[b, default: 0] += 1
                case 1: appO[b] = max(0, (appO[b] ?? 0) - 1)
                default: break
                }
                return
            }
            let down = appK[b] ?? 0
            switch phase {
            case 0:
                if let info, info.source == .kensington, info.button == b { passedThrough.insert(b) }   // as is, or replayed after a combo wait
                if raw { tainted.insert(b) }
                else if down > 0 && !tainted.contains(b) { fail("paired", "button \(b) went down twice") }
                appK[b] = down + 1
            case 1:
                passedThrough.remove(b)
                if raw { tainted.insert(b) }
                else if down == 0 && !tainted.contains(b) { fail("paired", "button \(b) came up without going down") }
                appK[b] = max(0, down - 1)
                if appK[b] == 0 && !raw && !kDown.contains(b) { tainted.remove(b) }
            default:
                if !raw && down == 0 && (appO[b] ?? 0) == 0 && !tainted.contains(b) {
                    fail("paired", "button \(b) dragged without being down")
                }
            }
        case .keyDown, .keyUp:
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
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
        let end = io.clock + dt
        while true {
            let nextTimer = io.timers.filter(\.valid).min { ($0.fireAt, $0.order) < ($1.fireAt, $1.order) }
            let nextFrame = engine.scroller.wantsFrames ? io.clock + 1.0 / 120 : Double.infinity
            let t = min(nextTimer?.fireAt ?? .infinity, nextFrame)
            guard t <= end else { break }
            io.clock = max(io.clock, t)
            if let timer = nextTimer, timer.fireAt <= t {
                if timer.repeats { timer.fireAt += max(timer.interval, 0.001) } else { timer.valid = false }
                if tracing { print(String(format: "        (timer #%d, every %.3f s, at +%.3f)", timer.order, timer.interval, io.clock - lastScrollInput)) }
                timer.body()
            } else {
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
            if heldThroughRelaunch.remove(b) != nil { ambiguous = true }
            kDown.remove(b)
            let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
            if hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
            deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .kensington)
            if !hidFirst { hid(kKey, page: kHIDPage_Button, usage: b + 1, value: 0) }
        case .kBall(let dx, let dy):
            guard kConnected else { return }
            noteScrollInput()   // Scroll with ball, if it's on
            if dx != 0 { hid(kKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: dx) }
            if dy != 0 { hid(kKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Y, value: dy) }
            if !io.frozen { io.cursor.x = min(max(io.cursor.x + CGFloat(dx), 0), 3000); io.cursor.y = min(max(io.cursor.y + CGFloat(dy), 0), 1000) }
            if let b = kDown.min() {
                let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 2), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 2), button: b, id: id), source: .kensington)
            } else if io.moveTap != nil {
                let id = newID(InputInfo(source: .kensington, button: 0, type: .mouseMoved, flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(.mouseMoved, button: 0, id: id), source: .kensington)
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
            hid(oKey, page: kHIDPage_Button, usage: b + 1, value: 1)
            let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
            deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .other)
        case .oRelease(let b):
            guard oDown.contains(b) else { return }
            markAmbiguity(other: b)
            oDown.remove(b)
            hid(oKey, page: kHIDPage_Button, usage: b + 1, value: 0)
            let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
            deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .other)
        case .oWheel(let t):
            hid(oKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Wheel, value: t)
            let id = newID(InputInfo(source: .other, button: -1, type: .scrollWheel, flags: io.kbFlags, time: io.clock))
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(t), wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(srcField, value: Int64(id))
            deliver(e, source: .other)
            if let out = lastOut[id], out.type != .scrollWheel { fail("others", "another mouse's scroll came out as type \(out.type.rawValue)") }
        case .oBall:
            hid(oKey, page: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_X, value: 3)
            if let b = oDown.min() {
                let id = newID(InputInfo(source: .other, button: b, type: World.type(b, 2), flags: io.kbFlags, time: io.clock))
                deliver(mouseEvent(World.type(b, 2), button: b, id: id), source: .other)
            }
        case .padClick(let b):
            markAmbiguity(other: b)
            let id = newID(InputInfo(source: .trackpad, button: b, type: World.type(b, 0), flags: io.kbFlags, time: io.clock))
            deliver(mouseEvent(World.type(b, 0), button: b, id: id), source: .trackpad)
            let id2 = newID(InputInfo(source: .trackpad, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
            deliver(mouseEvent(World.type(b, 1), button: b, id: id2), source: .trackpad)
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
            if mode == 1 { for b in held { apply(.kRelease(b, hidFirst: true)) } }
            kConnected = false
            engine.deviceRemoved(key: kKey)
            if mode == 0 {
                for b in held {
                    kDown.remove(b)
                    let id = newID(InputInfo(source: .kensington, button: b, type: World.type(b, 1), flags: io.kbFlags, time: io.clock))
                    deliver(mouseEvent(World.type(b, 1), button: b, id: id), source: .kensington)
                }
            }
            if mode == 2 { tainted.formUnion(passedThrough.intersection(held)) }   // macOS's own, lost
            kDown.removeAll()
            settle()
            mustBeReleased("unplug")
            scrollMuted = true
        case .replug:
            guard !kConnected else { return }
            kConnected = true
            engine.deviceAdded(key: kKey, identity: expert, transport: "USB", device: nil)
        case .sleep:
            engine.releaseForSleep()
            settle()
            mustBeReleased("sleep", modesToo: false)
            scrollMuted = true
        case .wake:
            engine.reapplyPointer()
        case .tapOff(let n):
            bypass = n
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
        modes = Engine.Modes()
        quitDone = false
        wire()
        engine.startInline()
        if kConnected { engine.deviceAdded(key: kKey, identity: expert, transport: "USB", device: nil) }
        engine.deviceAdded(key: oKey, identity: otherMouse, transport: "USB", device: nil)
        learning = false
        kReportsButtons = false   // a new engine hasn't seen a button over HID yet
        pendingPrimary.removeAll()
        // Buttons still held across the relaunch: their releases reach apps as macOS's own,
        // and a release whose press the new engine never saw can't be judged.
        tainted.formUnion(kDown)
        heldThroughRelaunch = kDown
        settle()
    }

    // MARK: The rules

    func mustBeReleased(_ when: String, modesToo: Bool = true) {
        if modesToo, modes.precision || modes.ballScrolling || modes.dragLocked || modes.gestureHeld {
            fail("modes", "after \(when) a mode is still on: \(modes)")
        }
        if !modesToo, modes.ballScrolling || modes.dragLocked || modes.gestureHeld {
            fail("modes", "after \(when) Scroll with ball, Drag lock or a gesture is still on: \(modes)")
        }
        if io.frozen { fail("modes", "the pointer is still frozen after \(when)") }
        if let k = keysDown.first(where: { $0.value > 0 }) { fail("released", "key \(k.key) still down after \(when)") }
        if let m = modifierEvents.first(where: { $0.value % 2 != 0 }) { fail("released", "modifier key \(m.key) still down after \(when)") }
        for (b, n) in appK where n > 0 && !tainted.contains(b) {
            // A button whose own press passed through is macOS's to release, not Glideball's.
            if passedThrough.contains(b) { continue }
            fail("released", "button \(b) still down for apps after \(when)")
        }
    }

    func checkAlways() {
        if io.frozen != (modes.ballScrolling || modes.gestureHeld) {
            fail("modes", "pointer frozen = \(io.frozen) but Scroll with ball = \(modes.ballScrolling), gesture = \(modes.gestureHeld)")
        }
        if !enabled && (modes.precision || modes.ballScrolling || modes.dragLocked || modes.gestureHeld) {
            fail("modes", "a mode is on while paused: \(modes)")
        }
        checkTimed()
    }

    func checkTimed() {
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
            passedThrough.removeAll(); swallowedOther.removeAll()
        }
        // (Another mouse's press can be taken for the trackball's, see `ambiguous`: then it holds too.)
        guard kDown.isEmpty, !ambiguous || oDown.isEmpty, io.clock > graceUntil, bypass == 0 else { return }
        if let k = keysDown.first(where: { $0.value > 0 }) { fail("released", "key \(k.key) still down with every button up") }
        if let m = modifierEvents.first(where: { $0.value % 2 != 0 }) { fail("released", "modifier \(m.key) still down with every button up") }
        for (b, n) in appK where n > 0 && !tainted.contains(b) && !(b == 0 && modes.dragLocked) {
            fail("released", "button \(b) still down for apps with every button up")
        }
    }
}

// MARK: - Generating, running, minimizing

func generate(seed: UInt64, count: Int) -> (configs: [GlideConfig], ops: [Op]) {
    var r = RNG(seed)
    let configs = (0..<6).map { _ in randomConfig(&r) }
    var ops: [Op] = []
    ops.reserveCapacity(count)
    let weights: [(Double, (inout RNG) -> Op)] = [
        (14, { r in .kPress(r.int(5), hidFirst: r.chance(0.9)) }),
        (14, { r in .kRelease(r.int(5), hidFirst: r.chance(0.9)) }),
        (14, { r in .kBall(r.int(41) - 20, r.chance(0.5) ? r.int(41) - 20 : 0) }),
        (10, { r in .kWheel(r.chance(0.5) ? 1 : -1) }),
        (18, { r in .wait(r.chance(0.8) ? r.double(0, 0.04) : (r.chance(0.97) ? r.double(0.05, 2) : r.double(10, 35))) }),
        (3, { r in .oPress(r.int(3)) }),
        (3, { r in .oRelease(r.int(3)) }),
        (1, { r in .oWheel(r.chance(0.5) ? 1 : -1) }),
        (1, { _ in .oBall }),
        (1.5, { r in .padClick(r.int(2)) }),
        (1, { _ in .padScroll }),
        (2.5, { r in .keyboard(r.pick([0, CGEventFlags.maskShift.rawValue, CGEventFlags.maskCommand.rawValue,
                                      CGEventFlags([.maskControl, .maskCommand]).rawValue])) }),
        (1.2, { r in .config(r.int(6)) }),
        (0.4, { r in .remote(r.int(6)) }),
        (1.2, { r in .front(r.int(4) - 1) }),
        (0.7, { _ in .pause }),
        (0.8, { _ in .resume }),
        (0.35, { r in .unplug(r.int(3)) }),
        (0.45, { _ in .replug }),
        (0.35, { _ in .sleep }),
        (0.25, { _ in .wake }),
        (0.5, { r in .tapOff(1 + r.int(4)) }),
        (1.5, { r in .setMode(r.int(3), r.int(3)) }),
        (0.25, { _ in .learn }),
        (0.15, { r in .practice(r.chance(0.5)) }),
        (0.25, { r in .displays(1 + r.int(3)) }),
        (0.15, { r in .beta(r.chance(0.5)) }),
        (0.08, { _ in .quit }),
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
    return nil
}

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
    return [
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
         [primaryCombo], [.kPress(1, hidFirst: true), .kPress(0, hidFirst: true), .wait(1), .unplug(2), .oPress(0), .replug,
                          .oRelease(0), .wait(1)]),
        ("ring ticks handled back to back with smooth scrolling off: bounded", [jumpy], Array(repeating: .kWheel(-1), count: 8) + [.wait(1)]),
        ("its own button with a modifier, after a button remapped to it", [selfMod],
         [.kPress(1, hidFirst: true), .kPress(2, hidFirst: true), .kRelease(2, hidFirst: true), .kRelease(1, hidFirst: true), .wait(1)]),
    ]
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
print("▸ regression cases")
for (name, configs, ops) in regressionCases() {
    if let (f, i) = run(configs, ops) {
        failed += 1
        print("  ✗ \(name): \(f) at op \(i)")
    } else {
        print("  ✓ \(name)")
    }
}
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
print(String(format: "%d seeds, %d events in %.1f s (%.0f events/s): %@", seedIndex, totalEvents, secs,
             Double(totalEvents) / max(secs, 0.001), failed == 0 ? "all rules held" : "\(failed) FAILED"))
exit(failed == 0 ? 0 : 1)
