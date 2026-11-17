import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import IOKit.hid

/// The input engine. Runs on its own high-priority thread so the UI can never
/// stall the mouse. It never takes the trackball away from macOS: the cursor is
/// moved natively, and Glide only rewrites button and scroll events that came
/// from the Kensington. If Glide is missing a permission it simply passes
/// everything through untouched.
final class Engine {
    static let syntheticTag: Int64 = 0x474C_4944   // "GLID" — marks events we post

    struct Status: Equatable {
        var deviceConnected = false
        var tapActive = false
        var listening = false
        /// The supported device in use (the Expert Mouse if several), e.g. "Kensington Expert Mouse".
        var deviceName: String?
        /// That device is a Kensington Glide only supports when "Other Kensington trackballs" is on.
        var deviceIsBeta = false
        /// A connected Kensington pointing device Glide leaves alone unless "Other Kensington trackballs" is on.
        var unsupportedDeviceName: String?
        /// Every Kensington pointing device connected, supported or not, by name and
        /// product ID. Only for the opt-in settings stats (see `ShareData`).
        var kensingtonModels: [Model] = []
        /// How the device in use is connected: USB cable, Bluetooth, or a 2.4 GHz receiver.
        /// nil when it can't be told (or no trackball is connected).
        var connection: DeviceConnection?
        /// The device in use's battery, 0…100. nil when unknown, wired, or "Other
        /// Kensington trackballs" is off (wireless models are only read with it on).
        var batteryPercent: Int?
        /// The key (`DisplayKey`) of the display the pointer was last seen on, while
        /// per-display speeds are on; nil otherwise.
        var pointerDisplay: String?

        struct Model: Hashable, Comparable {
            var name: String
            var productID: Int
            static func < (a: Model, b: Model) -> Bool { (a.name, a.productID) < (b.name, b.productID) }
        }
    }

    /// Glide's own button modes that are currently on, for the UI.
    struct Modes: Equatable {
        var precision = false
        var ballScrolling = false
        var dragLocked = false
        /// A gesture button is held (the pointer is frozen until it lifts).
        var gestureHeld = false
        /// The held gesture's buttons, and which way it's being rolled (for the UI's
        /// compass: the leaning direction, or the one that fired).
        var gestureButtons: [Int] = []
        var gestureDirection: GestureDirection?
        /// The last thing a gesture did, numbered so the UI can flash each one.
        var gestureFlash: GestureFlash?
        /// "Try it" on the Buttons page: gestures are shown, not performed.
        var gesturePractice = false
    }

    /// One thing a gesture did: a direction fired (nil direction: the tap).
    struct GestureFlash: Equatable {
        var seq: Int
        var direction: GestureDirection?
        var buttons: [Int]
        /// Which fire of its hold this was (1 for the first; 0 for a tap), so the UI
        /// can show a chain of them and start afresh with each hold.
        var chain = 0
    }

    let telemetry = Telemetry()
    var onStatus: ((Status) -> Void)?          // delivered on main
    var onModes: ((Modes) -> Void)?            // delivered on main

    /// Everything the engine does to the world outside (EngineIO.swift): the real
    /// Mac in the app, a recording fake in scripts/engine-fuzz.
    let io: EngineIO
    private var config: GlideConfig
    private var runLoop: CFRunLoop!
    private var foundationRunLoop: RunLoop!
    /// scripts/engine-fuzz: no input thread; every call runs at once, on the caller's thread.
    private var inline = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hid = false                    // listening to HID devices (Input Monitoring)
    private var devices: [Int: DeviceIdentity] = [:]   // connected pointing devices
    private var deviceSupported: [Int: Bool] = [:]     // …that Glide works with (see DeviceIdentity)
    private var betaProgram = OtherTrackballs.isEnabled
    private var lastActiveIsKensington = false
    private var lastValueStamp: [Int: UInt64] = [:]
    private var status = Status()

    private enum Override {
        case swallow, remap(Int64, CGEventFlags), heldShortcut(KeyShortcut)
        case precision    // a Precision (hold) button: slow until it lifts
        case ballScroll   // a Scroll-with-ball button: the ball scrolls until it lifts
        case dragButton   // the press that started a drag lock
        case gesture      // a gesture hold: drags and the release belong to `gestures`
    }
    private enum Phase { case down, up, drag }
    private var overrides: [Int64: Override] = [:]

    let scroller = SmoothScroller()
    let diagnostics = Diagnostics()

    // Scroll input comes straight from the ring's raw HID ticks once we've seen
    // one; the driver's own scroll events are then only used to learn direction.
    private var hidWheelSeen = false
    private var lastHIDWheel: (value: Int, time: CFTimeInterval) = (0, 0)
    // HID wheel reports carry no keyboard modifiers. Keep the physical keyboard
    // state from the event tap so Shift can reliably redirect the raw ring.
    private var modifierFlags: CGEventFlags
    /// Raw HID wheel sign → macOS scroll sign (accounts for natural scrolling).
    private var directionFactor: Double
    private var directionVotes = 0

    // Precision, Scroll with ball, and Drag lock. Input thread only.
    private var modes = Modes()
    private var precisionHeld = false
    private var precisionToggled = false
    private var precisionManual = false        // toggled on from the keyboard or menu bar
    private var ballScrolling = false          // the ball scrolls: held, latched, or both
    private var ballScrollHeld = false         // a Scroll-with-ball button is down
    private var ballScrollLatched = false      // switched on from the keyboard, until switched off
    private var ballSign: Double = 1           // raw ball counts → macOS scroll sign
    private var dragLocked = false
    private var handedBack = false             // quitting: the pointer is macOS's again
    private var dragLockManual = false         // grabbed from the keyboard
    private var modifierWait: EngineTimer?           // a keyboard Drag lock waiting for its keys to lift
    private var modifierWaitDone: ((Bool?) -> Void)?
    private var moveTap: CFMachPort?           // only while a drag lock is on
    private var moveTapSource: CFRunLoopSource?
    /// Buttons apps currently see down: presses that passed the tap (or that Glideball
    /// posted, which pass it too) without their release yet.
    /// Counted, since two devices can hold the same button: one's release mustn't make the
    /// engine think the other's is up too.
    private var appButtons = HeldButtons()
    private var leftDown: Bool { appButtons.contains(0) }   // Precision keeps drags drags
    struct HeldButtons {
        private var count: [Int64: Int] = [:]
        func contains(_ b: Int64) -> Bool { (count[b] ?? 0) > 0 }
        mutating func insert(_ b: Int64) { count[b, default: 0] += 1 }
        mutating func remove(_ b: Int64) { count[b] = max(0, (count[b] ?? 0) - 1) }
        /// What macOS says is down now (one each: it can't say how many hold it); counts
        /// already known stay as they are (nothing went by unseen).
        mutating func refresh(_ down: Set<Int64>) {
            var next: [Int64: Int] = [:]
            for b in down { next[b] = max(1, count[b] ?? 0) }
            count = next
        }
        mutating func set(_ counts: [Int64: Int]) { count = counts }
    }
    // Held modes end if their button's release is ever lost (see `checkHolds`).
    private var hidButtonsDown = Set<Int>()    // Kensington buttons physically down, per HID
    private var hidButtonsByDevice: [Int: Set<Int>] = [:]   // ...by trackball, so one leaving doesn't forget another's
    private var kensingtonReportsButtons = false   // its buttons reach us over HID at all
    private var hidButtonSeen = false          // HID has shown a press since the hold began
    // Who pressed what (see `handleButton`). macOS doesn't say which device a click came from, so
    // each CG press is given an owner when it arrives (the trackball's HID report of that button
    // going down, claimed once), and each release is matched to an open press of the same owner,
    // by the HID reports of the button going up. Input thread only. CG button numbers.
    private var kOpen = Set<Int64>()           // the trackball's presses the engine saw, not yet released
    private var kUnseen = Set<Int64>()         // the trackball's buttons held whose presses went by unseen
    private var kTokens: [Int64: CFTimeInterval] = [:]   // its HID downs no CG press has claimed yet
    private var kUpAt: [Int64: CFTimeInterval] = [:]     // its HID ups no CG release has claimed yet
    private var kClaimedEarly: [Int64: CFTimeInterval] = [:]   // its presses taken without a HID report yet
    private var kReleasedSince = Set<Int64>()  // open presses it has reported letting go of (release to come, or gone by)
    private var postedForStale = Set<Int64>()  // a stale press's end was posted: the next press goes behind it
    // Which release report came last (the trackball's or another device's), per button.
    private var reportSeq = 0
    private var kUpSeq: [Int64: Int] = [:]
    private var oUpSeq: [Int64: Int] = [:]
    // Releases matched before their own HID report came (its CG event first): that report,
    // when it comes, is theirs, not news of another release. Trackball's and other devices'.
    private var kMatchedEarly: [Int64: CFTimeInterval] = [:]
    private var oMatchedEarly: [Int64: (at: CFTimeInterval, device: Int?)] = [:]   // nil: whichever device
    /// Another device's press: which device reported it over HID (nil: none did, the trackpad),
    /// and whether it ended a Drag lock (then it and its release never reach apps).
    private struct OtherPress {
        var device: Int?
        var at: CFTimeInterval
        var swallowed: Bool
        var hidReleased = false   // its device has reported letting go; its CG release is to come
        var reported: Bool { device != nil }
    }
    private var otherPresses: [Int64: [OtherPress]] = [:]   // other devices' presses, not yet released
    private var oTokens: [Int64: (at: CFTimeInterval, device: Int)] = [:]   // other devices' HID downs, unclaimed
    private var oUpAt: [Int64: CFTimeInterval] = [:]     // other devices' HID ups, unclaimed
    private var oUpDevice: [Int64: Int] = [:]            // ...and whose
    private var lastMoverIsTrackball = true    // the latest HID movement was the trackball's
    private var deferredUps: [(button: Int64, event: CGEvent)] = []   // whose release it is isn't known yet
    private var deferTimer: EngineTimer?
    /// A HID report and its CG event are this close (either way round), as the old press check had it.
    private static let ownerWindow: CFTimeInterval = 0.3
    /// A press with no HID report of its own, this close before the trackball's report of that
    /// button, was the trackball's (its CG event came first).
    private static let lateReportWindow: CFTimeInterval = 0.05
    /// Longest a release is held back while it isn't known whose it is.
    private static let deferLimit: TimeInterval = 0.1
    private var holdStart: CFTimeInterval = 0
    private var holdReleasedChecks = 0
    private var holdFailsafe: EngineTimer?
    // Gesture buttons (Gestures.swift). Input thread only.
    private let gestures = GestureMachine()
    private var gestureFrozen = false          // a gesture hold has the pointer frozen
    private var gestureFlash: GestureFlash?    // the last fire or tap, for the UI
    private var gesturePracticeUntil: CFTimeInterval = 0   // "Try it": show, don't perform, until then
    // Per-display pointer speed (DisplayTracking.swift). Input thread only.
    private var displayTracker = DisplayTracker()
    // Wireless models: connection type and battery, per HID device (DeviceBattery.swift).
    private var batteryDevices = Set<Int>()   // Kensington devices whose battery the registry may have (EngineIO reads it)
    private var transports: [Int: String] = [:]
    private var registryBattery: [Int: Int] = [:]
    private var hidBattery: [Int: Int] = [:]
    private var maintainTicks = 0

    init(config: GlideConfig, io: EngineIO = EngineIO()) {
        self.io = io
        let config = config.clamped()   // the engine only ever runs values the app's controls allow
        self.config = config
        modifierFlags = io.keyboardFlags()
        let saved = io.savedScrollDirection
        directionFactor = saved != 0 ? saved : (io.naturalScrolling ? -1 : 1)
        scroller.config = config
        scroller.clock = io.now
        scroller.telemetry = telemetry
        scroller.diagnostics = diagnostics
    }

    /// scripts/engine-fuzz only: runs the engine without an input thread, an event tap
    /// or HID (all of that goes through `io`), with every call handled at once.
    func startInline() {
        inline = true
        setUp()
    }

    // MARK: Lifecycle

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            self.foundationRunLoop = RunLoop.current
            ready.signal()
            self.setUp()
            CFRunLoopRun()
        }
        thread.name = "Glideball input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        // Display-synced frames for smooth scrolling, delivered on the input thread.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let link = screen?.displayLink(target: scroller, selector: #selector(SmoothScroller.step(_:)))
        link?.isPaused = true
        link?.add(to: foundationRunLoop, forMode: .common)
        perform { self.scroller.attach(link) }
    }

    func update(_ config: GlideConfig) {
        let config = config.clamped()
        perform {
            let wasEnabled = self.config.enabled
            let pointerChanged = config.trackingSpeed != self.config.trackingSpeed
                || config.enabled != self.config.enabled   // paused: macOS's speed; resumed: Glide's
                || config.precisionSpeed != self.config.precisionSpeed
                || config.scrollMode != self.config.scrollMode
                || config.nativeScrollSpeed != self.config.nativeScrollSpeed
                || config.displaySpeeds != self.config.displaySpeeds
            let watchingBefore = self.watchingDisplays
            self.config = config
            self.scroller.config = config
            if wasEnabled && !config.enabled {
                self.releaseModes()
                // Presses waiting for a combo partner go through now, as plain presses (a
                // paused Glideball changes nothing). They used to be replayed later with their
                // mapping, which could start a Drag lock while paused. Found by scripts/engine-fuzz.
                if !self.pending.isEmpty { self.flushPending() }
            } else {
                self.dropOrphanedModes()
            }
            if self.watchingDisplays && !watchingBefore {
                // Just switched on: find the display the pointer is on now, not at its next move.
                self.displayTracker.setRegions(self.displayTracker.regions, pointer: self.io.cursorLocation())
            }
            if pointerChanged { self.applyPointer() }
            self.publish()
        }
    }

    func reapplyPointer() { perform { self.applyPointer() } }

    /// The connected displays changed (one appeared, went away or moved). Main thread → input thread.
    func setDisplays(_ regions: [DisplayRegion]) {
        perform {
            guard regions != self.displayTracker.regions else { return }
            if self.displayTracker.setRegions(regions, pointer: self.io.cursorLocation()) {
                self.applyPointer()
            }
            self.publish()
        }
    }

    /// Per-display speeds are on and there's a display to tell apart from another.
    private var watchingDisplays: Bool {
        config.enabled && config.displaySpeeds.isActive && displayTracker.needsWatching
    }

    /// Called from the trackball's own movement reports: at most every 50 ms,
    /// one location read and a rectangle test; a full lookup (and a new speed)
    /// only when the pointer has crossed onto another display.
    private func watchDisplay(now: CFTimeInterval) {
        guard watchingDisplays, displayTracker.due(now: now),
              let point = io.cursorLocation() else { return }
        if displayTracker.update(point: point) {
            diagnostics.record("pointer moved to another display")
            applyPointer()
            publish()
        }
    }

    /// "Other Kensington trackballs" adds Kensington's other pointing devices. Takes effect
    /// immediately: devices are re-sorted and pointer speeds re-applied.
    func setBetaProgram(_ on: Bool) {
        perform {
            guard on != self.betaProgram else { return }
            self.betaProgram = on
            let before = self.deviceSupported
            self.deviceSupported = self.devices.mapValues { $0.isSupported(beta: on) }
            // A trackball no longer supported won't have its releases handled: let go now.
            if before.contains(where: { $0.value && self.deviceSupported[$0.key] != true }) { self.letGoOfTrackball() }
            self.lastActiveIsKensington = false   // re-learned from the next raw input
            self.syncTap()
            self.io.pointerDevicesChanged()
            self.applyPointer()
            self.refreshBatteries()
            self.publish()
        }
    }

    /// Lets go of any shortcut a button is holding down, and of any other button a
    /// held one was turned into (pause, quit), so a key or a click can never stay stuck.
    func releaseHeldKeys() {
        guard isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        perform {
            self.resolveDeferredUps()   // a release waiting to be told apart goes out now (quit)
            self.letGoOfHeld()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// Input thread. Every key a held shortcut has down goes up, and every button a press
    /// was remapped to is released; their triggers' releases, when they come, do nothing.
    private func letGoOfHeld() {
        for b in Array(overrides.keys) {
            switch overrides[b] {   // as it is now: a chord's buttons share one held key
            case .heldShortcut(let s)?:
                io.keysNow { self.sendUp(s) }
                silenceHeld(s)   // the chord's other buttons: already let go
            case .remap(let target, let flags)?:
                postButton(target, down: false, flags: flags)
                overrides[b] = .swallow
            default:
                break
            }
        }
    }

    /// Ends Precision, Scroll with ball, and Drag lock (pause, ⌃⌥⌘G, quit), so
    /// Glide can never leave the cursor slowed, frozen, or the left button down.
    func releaseAll() {
        guard isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        perform {
            self.releaseModes()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
        // Even if the input thread were stuck, never leave the cursor frozen.
        io.freezePointer(false)
    }

    /// Quit: gives the trackball macOS's own pointer and scroll speed back.
    /// Call after `releaseAll`, which re-applies Glide's speed; from then on
    /// nothing (the 2 s upkeep, a replug) writes Glide's speed again.
    func handBackPointer() {
        guard isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        perform {
            self.handedBack = true
            self.io.restorePointer()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// Glide's modes a keyboard shortcut (or the menu bar) can switch.
    enum ToggleMode: String { case precision, ballScroll, dragLock }

    /// Switches a mode on or off from the keyboard or menu bar, like the
    /// matching button action. Unlike a held button, a keyboard Scroll with
    /// ball stays on until it's switched off (or Glide pauses, quits, or the
    /// trackball is unplugged). `done` gets the new state on main, or nil if
    /// nothing changed: Glide is paused, the mode can't work right now, or a
    /// Drag lock gave up waiting for the shortcut's keys to lift.
    func toggleMode(_ mode: ToggleMode, done: ((Bool?) -> Void)? = nil) {
        setMode(mode, on: nil, done: done)
    }

    /// Like `toggleMode`, but `on` says which way: a mode that's already
    /// there is left alone (and `done` gets its state), so "on" twice stays on.
    /// nil toggles. Used by `Commands` (the glideball:// URLs, the menu, hot keys).
    func setMode(_ mode: ToggleMode, on wanted: Bool?, done: ((Bool?) -> Void)? = nil) {
        let report: (Bool?) -> Void = { on in
            if let done { self.io.toMain { done(on) } }
        }
        perform {
            guard self.config.enabled else { return report(nil) }
            if let wanted {
                let current: Bool
                switch mode {
                case .precision: current = self.precisionToggled
                case .ballScroll: current = self.ballScrollLatched
                case .dragLock: current = self.dragLocked
                }
                if current == wanted { return report(current) }
            }
            switch mode {
            case .precision:
                self.precisionToggled.toggle()
                self.precisionManual = self.precisionToggled
                self.applyPointer()
                report(self.precisionToggled)
            case .ballScroll:
                if self.ballScrollLatched {
                    self.endBallScroll(latched: true, glide: true)
                } else {
                    // Freezing the cursor only makes sense if the trackball can scroll.
                    guard self.tap != nil, self.canReadBall else { return report(nil) }
                    self.beginBallScroll(latched: true)
                }
                report(self.ballScrollLatched)
            case .dragLock:
                guard self.tap != nil else { return report(nil) }
                self.whenModifiersLift(report) {
                    if self.dragLocked {
                        self.endDragLock()
                    } else {
                        self.beginDragLock(manual: true)
                    }
                    return self.dragLocked
                }
                return
            }
            self.diagnostics.record("mode \(mode.rawValue) toggled from keyboard")
            self.publishModes()
        }
    }

    /// Adds a line to the diagnostics log from any thread (the log itself
    /// belongs to the input thread). Plain ASCII facts only, never text from outside.
    func note(_ message: String) {
        perform { self.diagnostics.record(message) }
    }

    /// Sleep, the screens sleeping or locking: the cursor is never left frozen, and no
    /// key, click or drag is left held, while nobody's looking. A button still held when
    /// the Mac wakes does nothing when it lifts. Precision switched on stays on.
    func releaseForSleep() {
        perform {
            self.resolveDeferredUps()   // first: what it sets off is ended below like everything else
            self.cancelModifierWait(silently: true)
            self.cancelGesture(.sleep)   // a held gesture freezes the cursor too
            if self.ballScrolling { self.scroller.cancelBall() }
            self.ballScrollLatched = false
            if self.ballScrollHeld { self.endBallScroll(latched: false, glide: false) }
            self.ballScrolling = false
            self.syncFreeze()
            self.scroller.stopAll()
            self.endDragLock()
            if self.precisionHeld { self.endPrecisionHold() }
            self.letGoOfHeld()
            self.publishModes()
        }
    }

    /// A supported trackball is connected and Glide can read its ball.
    private var canReadBall: Bool { hid && deviceSupported.values.contains(true) }

    /// Runs `body` once ⌘⌃⌥⇧ are all up, so the grab (or drop) is a plain
    /// click — never a ⌃-click or an ⌥-copy. Pressing the shortcut again
    /// while waiting cancels; after 3 s it gives up. Input thread.
    private func whenModifiersLift(_ report: @escaping (Bool?) -> Void, _ body: @escaping () -> Bool) {
        if modifierWait != nil {
            cancelModifierWait(silently: true)
            return report(nil)
        }
        let keys: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        func keysUp() -> Bool { io.keyboardFlags().intersection(keys).isEmpty }
        let run = { [unowned self] in
            let on = body()
            self.diagnostics.record("drag lock \(on ? "on" : "off") from keyboard")
            self.publishModes()
            report(on)
        }
        if keysUp() { return run() }
        let deadline = io.now() + 3
        modifierWaitDone = report
        modifierWait = io.schedule(0.015, repeats: true) { [unowned self] in
            if keysUp() {
                self.cancelModifierWait(silently: true)
                run()
            } else if self.io.now() > deadline {
                self.cancelModifierWait(silently: false)
            }
        }
    }

    /// Stops waiting; unless `silently`, tells the waiting caller nothing happened.
    private func cancelModifierWait(silently: Bool) {
        modifierWait?.invalidate()
        modifierWait = nil
        let done = modifierWaitDone
        modifierWaitDone = nil
        if !silently { done?(nil) }
    }

    /// Whether `start()` has run: the input thread exists. Never, in `--render-ui` and `--self-test`.
    var isRunning: Bool { runLoop != nil || inline }

    /// Runs `block` on the input thread (scripts/engine-fuzz --threads uses it to feed events
    /// the way the tap and IOHIDManager callbacks do).
    func perform(_ block: @escaping () -> Void) {
        if inline { return block() }
        guard let runLoop else { return }   // never started: there's nothing to change
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func setUp() {
        noteButtonsAlreadyDown("start", clearTokens: true)   // a button held while Glideball (re)launches
        startListening()
        installTap()
        applyPointer()
        _ = io.schedule(2, repeats: true) { [unowned self] in self.maintain() }
        publish()
    }

    /// Self-healing: retries anything that failed (e.g. a permission granted later)
    /// and re-enables the tap if macOS ever switched it off.
    private func maintain() {
        if !hid { startListening() }
        if tap == nil { installTap() }
        syncTap()   // also re-enables it if macOS ever switched it off while a trackball is connected
        applyPointer()
        diagnostics.flush()
        // Wireless models' battery: once a minute, and only for one that's battery powered.
        maintainTicks += 1
        if maintainTicks % 30 == 0 { refreshBatteries() }
        healIfQuiet()
        forgetReleasedOtherPresses()
        publish()
    }

    /// Another device's press that went through to apps, of a button macOS says is up: its
    /// release went by unseen (the tap was off) and nothing reported it. Forgotten, so it's
    /// never matched to a later release.
    private func forgetReleasedOtherPresses() {
        for (b, list) in otherPresses where list.contains(where: { !$0.swallowed }) && !io.buttonDown(b)
            && !deferredUps.contains(where: { $0.button == b }) {
            let kept = list.filter(\.swallowed)
            otherPresses[b] = kept.isEmpty ? nil : kept
            diagnostics.record("another device's press of button \(b) is up by macOS: forgotten")
        }
    }

    /// The tracking speed right now (precedence: `PointerSpeed.effective`).
    private var effectiveTrackingSpeed: Double {
        PointerSpeed.effective(config, display: displayTracker.current, precision: precisionActive)
    }

    private func applyPointer() {
        guard !handedBack else { return }
        // Paused: the trackball gets macOS's own speeds back (cheap once done).
        guard config.enabled else { return io.restorePointer() }
        io.applyPointer(.init(trackingSpeed: effectiveTrackingSpeed,
                            scrollSpeed: config.scrollMode == .native ? config.nativeScrollSpeed : nil,
                            betaProgram: betaProgram))
    }

    private func publish() {
        var s = Status()
        s.deviceConnected = deviceSupported.values.contains(true)
        let supported = devices.filter { deviceSupported[$0.key] == true }.values
            .sorted { ($0.kind == .expertMouse ? 0 : 1, $0.displayName) < ($1.kind == .expertMouse ? 0 : 1, $1.displayName) }
        s.deviceName = supported.first?.displayName
        s.deviceIsBeta = supported.first.map { $0.kind != .expertMouse } ?? false
        s.unsupportedDeviceName = devices.filter { $0.value.kind == .otherKensington && deviceSupported[$0.key] != true }
            .values.map(\.displayName).sorted().first
        s.kensingtonModels = Set(devices.values.filter { $0.vendorID == DeviceIdentity.kensingtonVendorID }
            .map { Status.Model(name: $0.displayName, productID: $0.productID ?? 0) }).sorted()
        s.tapActive = tap.map { io.tapIsEnabled($0) } ?? false
        s.listening = hid
        if let (k, identity) = devices.filter({ deviceSupported[$0.key] == true })
            .min(by: { ($0.value.kind == .expertMouse ? 0 : 1, $0.value.displayName) < ($1.value.kind == .expertMouse ? 0 : 1, $1.value.displayName) }) {
            s.connection = DeviceConnection.classify(transport: transports[k], name: identity.name, productID: identity.productID)
            // Wireless models are only read with "Other Kensington trackballs" on (untested hardware).
            if betaProgram, s.connection?.isWireless == true {
                s.batteryPercent = hidBattery[k] ?? registryBattery[k]
            }
        }
        s.pointerDisplay = config.displaySpeeds.enabled ? displayTracker.current : nil
        guard s != status else { return }
        status = s
        io.toMain { self.onStatus?(s) }
    }

    // MARK: Device listening (read-only — never seizes)

    private func startListening() {
        // Read-only: the manager is never opened with kIOHIDOptionsTypeSeizeDevice (EngineIO).
        hid = io.startListening(self, runLoop: runLoop)
    }

    /// A device's key: its HID service's I/O Registry entry ID, which IOKit never reuses
    /// (a replug or a hub re-enumerating gets a new one). Until beta 13 this was the
    /// IOHIDDevice's address, which a freed device could hand to the next one.
    static func key(_ device: IOHIDDevice) -> Int {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id > 0, id < 1 << 62 {
            return Int(id)
        }
        return -abs(Int(bitPattern: Unmanaged.passUnretained(device).toOpaque()))   // never looks like an ID
    }

    static func identity(of device: IOHIDDevice) -> DeviceIdentity {
        DeviceIdentity(vendorID: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                       productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
                       name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
    }

    /// Whether Glide works with this device: the Expert Mouse always, other
    /// Kensington pointing devices in the Beta program. Cached per device.
    private func isSupported(key k: Int, identity: () -> DeviceIdentity) -> Bool {
        if let known = deviceSupported[k] { return known }
        let identity = devices[k] ?? identity()
        let supported = identity.isSupported(beta: betaProgram)
        devices[k] = identity
        deviceSupported[k] = supported
        return supported
    }

    /// IOHIDManager's callback (input thread).
    func deviceAdded(_ device: IOHIDDevice) {
        managerAdded(address: Self.address(device), key: Self.key(device), identity: Self.identity(of: device),
                     transport: DeviceBattery.transport(device), device: device)
    }

    /// IOHIDManager's add, by the device object's address (scripts/engine-fuzz calls this directly).
    func managerAdded(address a: Int, key k: Int, identity: DeviceIdentity, transport: String?, device: IOHIDDevice? = nil) {
        keyByAddress[a] = k
        deviceAdded(key: k, identity: identity, transport: transport, device: device)
    }

    /// Each device's key by its object's address, so a HID value (hundreds a second) doesn't
    /// ask the kernel for its registry ID every time. Refreshed whenever a device is added,
    /// and read again from the device whenever the cached key isn't a device the engine has
    /// (a freed device's address can be handed to the next one).
    private var keyByAddress: [Int: Int] = [:]
    private static func address(_ device: IOHIDDevice) -> Int { Int(bitPattern: Unmanaged.passUnretained(device).toOpaque()) }

    private func resolveKey(address a: Int, fresh: () -> Int) -> Int {
        if let k = keyByAddress[a], devices[k] != nil { return k }
        let k = fresh()
        keyByAddress[a] = k
        return k
    }

    /// A pointing device appeared: IOHIDManager matched it, or a device check found it.
    /// `device` is nil in scripts/engine-fuzz.
    func deviceAdded(key k: Int, identity: DeviceIdentity, transport: String?, device: IOHIDDevice?, fromCheck: Bool = false) {
        if !fromCheck {   // IOHIDManager matched it: it's here, whatever an earlier check thought
            gone.remove(k)
            addedByManager.insert(k)
        }
        checkRemovedTrackball.remove(k)
        devices[k] = nil
        deviceSupported[k] = nil
        hidBattery[k] = nil
        registryBattery[k] = nil
        transports[k] = transport
        deviceObjects[k] = device
        if identity.vendorID == DeviceIdentity.kensingtonVendorID {
            batteryDevices.insert(k)   // only Kensington's, for the battery check
            io.rememberDevice(k, device)
        }
        let supported = isSupported(key: k, identity: { identity })
        deviceEvent("device add (\(fromCheck ? "check" : "manager")): key \(Self.describe(k)) \(Self.describe(identity)) "
                    + "supported \(supported ? "yes" : "no") transport \(transport ?? "?")")
        // IOKit can publish a device before all of its properties: read them again shortly.
        if !Self.isComplete(identity) {
            incomplete.insert(k)
            for delay in [0.3, 1.0, 3.0] {
                _ = io.schedule(delay, repeats: false) { [unowned self] in self.refreshIdentity(k) }
            }
        } else {
            incomplete.remove(k)
        }
        if supported {
            // A button already held as it arrives (plugged in, or the engine starting, with a
            // finger on it): its press went by unseen, so its release does nothing mapped.
            noteButtonsAlreadyDown("trackball added", clearTokens: false)
            io.watchTermination(k, device, engine: self, runLoop: runLoop)
            io.pointerDevicesChanged()
            // The HID service appears slightly after the device; apply twice to be sure.
            for delay in [0.3, 1.5] {
                _ = io.schedule(delay, repeats: false) { [unowned self] in
                    self.applyPointer()
                    if delay > 1 { self.refreshBatteries() }   // registry properties can arrive late too
                    self.checkOpen(k, always: delay < 1)
                }
            }
        }
        classifyEchoes()
        syncTap()
        publish()
    }

    /// Unsupported devices that are really the trackball (its driver re-publishing its
    /// movement as a pointer of its own): their movement is the trackball's, never "another
    /// mouse". Asked again whenever a device comes, since either may arrive first.
    private var echoDevices = Set<Int>()
    private func classifyEchoes() {
        let trackballs = Set(deviceSupported.filter { $0.value }.keys)
        for (k, supported) in deviceSupported where !supported && !echoDevices.contains(k) {
            if let why = io.echoReason(k, trackballs: trackballs) {
                echoDevices.insert(k)
                deviceEvent("device echo: key \(Self.describe(k)) is the trackball's own driver (\(why)); its movement counts as the trackball's")
            }
        }
    }

    /// IOHIDManager opens each device it matches, and doesn't try again if that fails (say
    /// while a driver has the device to itself for a moment). An unopened device sends no
    /// values, so Glideball would see a trackball that never moves. Logged; opened again,
    /// read-only (never seized), when EngineIO can tell. The first look is always logged,
    /// the second only when the device isn't simply open.
    private func checkOpen(_ k: Int, always: Bool) {
        guard deviceSupported[k] == true, let note = io.ensureOpen(k, deviceObjects[k] ?? nil) else { return }
        if always || note != "open" { deviceEvent("device open: key \(Self.describe(k)) \(note)") }
    }

    private static func isComplete(_ d: DeviceIdentity) -> Bool { d.vendorID != nil && d.productID != nil && d.name != nil }

    /// Reads an incomplete device's properties again (timers after its add, its own values,
    /// a device check). A different identity updates the device; it never removes it.
    private func refreshIdentity(_ k: Int) {
        refreshIdentity(k) { io.currentIdentity(k, deviceObjects[k] ?? nil) }
    }

    private func refreshIdentity(_ k: Int, _ read: () -> DeviceIdentity?) {
        guard devices[k] != nil, incomplete.contains(k) else { return }
        guard let now = read() else { return }
        updateIdentity(k, now, reason: "properties filled in")
    }

    /// The identity a device has now (`reason` for the log). Same support: just stored.
    /// Support changed: taken out and put back as that, with the usual releases.
    private func updateIdentity(_ k: Int, _ identity: DeviceIdentity, reason: String) {
        guard let old = devices[k], old != identity else { return }
        if Self.isComplete(identity) { incomplete.remove(k) }
        let was = deviceSupported[k] == true
        let now = identity.isSupported(beta: betaProgram)
        deviceEvent("device check: key \(Self.describe(k)) identity changed (\(reason)): \(Self.describe(old)) -> \(Self.describe(identity))")
        if was == now {
            devices[k] = identity
            if identity.vendorID == DeviceIdentity.kensingtonVendorID, !batteryDevices.contains(k) {
                batteryDevices.insert(k)
                io.rememberDevice(k, deviceObjects[k] ?? nil)
            }
            publish()
            return
        }
        let transport = transports[k], device = deviceObjects[k] ?? nil, byManager = addedByManager.contains(k)
        incomplete.remove(k)   // not "maybe the trackball" while it's swapped (deviceAdded marks it again)
        deviceRemoved(key: k)
        deviceAdded(key: k, identity: identity, transport: transport, device: device, fromCheck: true)
        if byManager { addedByManager.insert(k) }
    }

    /// IOHIDManager's callback (input thread): that device, then a check of the rest
    /// against what IOKit has (a removal can go missing, say across a USB hub reset).
    func deviceRemoved(_ device: IOHIDDevice) {
        managerRemoved(address: Self.address(device), fresh: Self.key(device))
    }

    /// IOHIDManager's removal, by the device object's address (scripts/engine-fuzz calls this
    /// directly). The device's own registry ID wins over the cached one: an address can have
    /// been reused, and removing the wrong key would drop a working device.
    func managerRemoved(address a: Int, fresh: Int) {
        let cached = keyByAddress.removeValue(forKey: a)
        let k = fresh > 0 ? fresh : (cached ?? fresh)
        if let cached, cached != k { deviceEvent("device removal: address cached key \(Self.describe(cached)), device says \(Self.describe(k))") }
        deviceRemovedByManager(key: k)
    }

    /// What the removal callback does (scripts/engine-fuzz calls this directly).
    ///
    /// The "Connected after an unplug" bug (betas 12 and 13): IOHIDManager calls this
    /// *before* it takes the device out of its own set, so the check that followed found
    /// the trackball still listed, logged "a device arrived without an add" and added it
    /// right back. Now a removed key is never re-added by a check (`gone`), and a check only
    /// believes devices whose service IOKit still has registered (`io.serviceIsAlive`).
    func deviceRemovedByManager(key k: Int) {
        deviceEvent("device removal (manager): key \(Self.describe(k))\(devices[k] == nil ? " (not known)" : "")")
        gone.insert(k)
        addedByManager.remove(k)
        deviceRemoved(key: k)
        // A trackball a check had taken out (say while IOKit was still registering it) is
        // really gone now: modes switched on in the meantime end, as at any unplug.
        if checkRemovedTrackball.remove(k) != nil, !deviceSupported.values.contains(true) { letGoOfTrackball() }
        reconcileNow(reason: "after a removal")
    }

    /// IOKit's termination notice for a device's service (EngineIO.watchTermination): the
    /// same as its removal, whichever of the two comes first. The second does nothing.
    func deviceTerminated(key k: Int) {
        guard !gone.contains(k) else { return deviceEvent("device terminated: key \(Self.describe(k)) (already removed)") }
        deviceEvent("device terminated: key \(Self.describe(k))")
        deviceRemovedByManager(key: k)
    }

    /// Wake, screen unlock, the window or the menu opening: make the devices Glideball knows
    /// match the ones IOKit has now. A removal callback that never came would otherwise
    /// leave "Connected" showing (and the tap on) until a relaunch. Cheap: one
    /// IOHIDManagerCopyDevices and a registry lookup per device, no timer.
    func reconcileDevices(reason: String = "asked") { perform { self.reconcileNow(reason: reason) } }

    /// Keys whose real removal came (IOHIDManager's removal callback or IOKit's termination
    /// notice) since IOHIDManager last added them. Registry IDs are never reused, so a check
    /// never adds one back; only IOHIDManager's own matching callback can.
    private var gone = Set<Int>()
    /// Keys IOHIDManager added and hasn't removed. A check takes one of these out only when
    /// IOKit no longer has its service (whether IOHIDManager lists it yet or not), and never
    /// for good: a later check puts it back if IOKit has it.
    private var addedByManager = Set<Int>()
    /// Devices whose properties were missing something when they arrived (see `refreshIdentity`).
    private var incomplete = Set<Int>()
    private var deviceObjects: [Int: IOHIDDevice?] = [:]
    private var lastValueCheck: CFTimeInterval = -1e9
    private var lastIdentityRead: [Int: CFTimeInterval] = [:]
    private var recheckTimers: [EngineTimer] = []
    /// Trackballs (or maybe-trackballs) a check took out that IOHIDManager hasn't removed.
    private var checkRemovedTrackball = Set<Int>()

    /// One verdict per device that changes, each logged. A device check never makes a
    /// "gone" verdict permanent: only a real removal does (`gone`).
    private func reconcileNow(reason: String) {
        guard let listed = io.liveDevices() else { return }   // not listening: nothing to compare with
        var changed = false, doubtful = false
        // A key that isn't a registry ID (negative: its ID couldn't be read) can't be checked
        // against IOKit, so a check leaves it to IOHIDManager's own callbacks.
        for k in Array(devices.keys).sorted() where k > 0 {
            let entry = listed[k]
            let byManager = addedByManager.contains(k)
            // IOHIDManager can still list a device that's gone (see deviceRemovedByManager), so
            // a device only stays while IOKit still has its service. One the manager added stays
            // even before the manager lists it; one a check added, only while it's listed.
            let alive = io.serviceIsAlive(k)
            if !alive || (!byManager && entry == nil) {
                deviceEvent("device check (\(reason)): key \(Self.describe(k)) left without a removal: "
                            + "\(alive ? "" : "not alive, ")\(entry == nil ? "not listed" : "listed")\(byManager ? ", added by the manager" : "")")
                let trackball = deviceSupported[k] == true || (incomplete.contains(k) && (devices[k]?.vendorID ?? DeviceIdentity.kensingtonVendorID) == DeviceIdentity.kensingtonVendorID)
                if trackball && byManager { checkRemovedTrackball.insert(k) }
                deviceRemoved(key: k)   // its releases, exactly as an unplug; not `gone`: a later check can bring it back
                if byManager || entry != nil { doubtful = true }
                changed = true
            } else if let entry, entry.identity != devices[k] {
                updateIdentity(k, entry.identity, reason: "listed differently")
                changed = true
            }
        }
        for (k, d) in listed.sorted(by: { $0.key < $1.key }) where k > 0 && devices[k] == nil && !gone.contains(k) {
            guard io.serviceIsAlive(k) else { continue }
            deviceEvent("device check (\(reason)): key \(Self.describe(k)) arrived without an add")
            if let device = d.device { keyByAddress[Self.address(device)] = k }
            deviceAdded(key: k, identity: d.identity, transport: d.transport, device: d.device, fromCheck: true)
            changed = true
        }
        lastCheck = io.now()
        // A device taken out that IOHIDManager still has: look again a little later, in case
        // IOKit was only slow to finish registering it.
        if doubtful { scheduleRechecks() }
        if changed { publish() }
    }

    private func scheduleRechecks() {
        for t in recheckTimers { t.invalidate() }
        recheckTimers = [0.5, 2, 6].map { delay in
            io.schedule(delay, repeats: false) { [unowned self] in self.reconcileNow(reason: "recheck") }
        }
    }

    /// A value from a device the engine doesn't have, and whose removal never came: it is
    /// plugged in, so check now (at most once a second) rather than drop its input for good.
    private func valueFromUnknown(_ k: Int) {
        let now = io.now()
        guard k > 0, !gone.contains(k), now - lastValueCheck >= 1 else { return }
        lastValueCheck = now
        deviceEvent("device check: values from key \(Self.describe(k)), which the engine doesn't have")
        reconcileNow(reason: "values")
    }

    /// Device lifecycle facts (adds, removals, termination notices, check verdicts): the log,
    /// and the last 30 for Help › Copy Connection Details. Keys, vendor and product IDs only.
    private var deviceLines: [String] = []
    private func deviceEvent(_ line: String) {
        diagnostics.record(line)
        deviceLines.append(String(format: "%.1f s  ", io.now() - startedAt) + line)
        if deviceLines.count > 30 { deviceLines.removeFirst(deviceLines.count - 30) }
    }
    private lazy var startedAt: CFTimeInterval = io.now()

    // Self-heal: while the window or the menu is open, a "connected" trackball that has sent
    // nothing for a few seconds is checked again (`maintain`). Nothing runs while hidden.
    private var watched = false
    private var lastSupportedValue: CFTimeInterval = 0
    private var lastCheck: CFTimeInterval = 0
    /// HID values taken from a supported trackball (scripts/engine-fuzz: a plugged-in trackball works).
    private(set) var supportedValues = 0

    /// The window or the menu-bar panel is open (main thread → input thread). Opening
    /// checks the devices at once.
    func setWatched(_ on: Bool) {
        perform {
            guard on != self.watched else { return }
            self.watched = on
            if on { self.reconcileNow(reason: "window open") }
        }
    }

    /// Run every 2 s by `maintain`: only while watched and the trackball has been quiet.
    private func healIfQuiet() {
        guard watched, hid, deviceSupported.values.contains(true) else { return }
        let now = io.now()
        guard now - lastSupportedValue > 2, now - lastCheck > 1.5 else { return }
        reconcileNow(reason: "quiet")
    }

    /// "Copy connection details" (Help menu, support info): what the engine believes and
    /// what IOKit says right now. Plain facts only: names, IDs, product numbers.
    func connectionDetails(_ done: @escaping (String) -> Void) {
        guard isRunning else { return done("Engine not running.") }
        perform {
            var lines: [String] = []
            let now = self.io.now()
            lines.append("Glideball believes: \(self.status.deviceConnected ? "connected" : "not connected")"
                         + (self.status.deviceName.map { " (\($0))" } ?? ""))
            lines.append("Listening (Input Monitoring): \(self.hid ? "yes" : "no"); tap: \(self.status.tapActive ? "on" : "off")")
            for (k, d) in self.devices.sorted(by: { $0.key < $1.key }) {
                let pid = d.productID.map { String(format: "0x%04X", $0) } ?? "?"
                let vid = d.vendorID.map { String(format: "0x%04X", $0) } ?? "?"
                lines.append("  engine: key \(Self.describe(k)) vendor \(vid) product \(pid) "
                             + "supported \(self.deviceSupported[k] == true ? "yes" : "no") transport \(self.transports[k] ?? "?")")
            }
            if self.lastSupportedValue > 0 {
                lines.append(String(format: "Last value from the trackball: %.1f s ago", now - self.lastSupportedValue))
            }
            if let listed = self.io.liveDevices() {
                lines.append("IOHIDManager lists \(listed.count) pointing device(s):")
                for (k, d) in listed.sorted(by: { $0.key < $1.key }) {
                    let pid = d.identity.productID.map { String(format: "0x%04X", $0) } ?? "?"
                    let vid = d.identity.vendorID.map { String(format: "0x%04X", $0) } ?? "?"
                    lines.append("  manager: key \(Self.describe(k)) vendor \(vid) product \(pid) "
                                 + "alive \(self.io.serviceIsAlive(k) ? "yes" : "no")\(self.gone.contains(k) ? " (removed)" : "")")
                }
            } else {
                lines.append("IOHIDManager: not open")
            }
            let services = self.io.kensingtonServicesNow()
            lines.append("IOKit has \(services.count) Kensington HID device(s) registered now:")
            lines += services.map { "  " + $0 }
            lines.append("Recent device events (seconds since launch, newest last):")
            lines += self.deviceLines.isEmpty ? ["  none"] : self.deviceLines.map { "  " + $0 }
            let text = lines.joined(separator: "\n")
            self.io.toMain { done(text) }
        }
    }

    private static func describe(_ k: Int) -> String { k > 0 ? "0x" + String(k, radix: 16) : "ptr" }

    /// Vendor and product IDs, and whether a name is there (never the name itself: a
    /// Bluetooth device can carry its owner's).
    private static func describe(_ d: DeviceIdentity) -> String {
        let vid = d.vendorID.map { String(format: "0x%04X", $0) } ?? "?"
        let pid = d.productID.map { String(format: "0x%04X", $0) } ?? "?"
        return "vendor \(vid) product \(pid) name \(d.name == nil ? "missing" : "yes")"
    }

    /// A trackball went away (unplugged, or no longer one Glideball works with): its button
    /// releases will never come, so everything it held lets go, as at an unplug. `k`: which one
    /// (nil: any of them); another trackball still plugged in keeps what its own reports say.
    private func letGoOfTrackball(_ k: Int? = nil) {
        resolveDeferredUps()   // by what the reports have said so far
        if let k { hidButtonsByDevice[k] = nil } else { hidButtonsByDevice.removeAll() }
        hidButtonsDown = hidButtonsByDevice.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        // Quick assign holding presses whose releases will never come: what it has, now.
        if !learnHeld.isEmpty {
            learnHeld.removeAll()
            if let handler = learnHandler, !learnMax.isEmpty {
                let result = learnMax
                learnHandler = nil
                io.toMain { handler(result) }
            }
        }
        kUnseen.removeAll()   // their releases, if they come, are nobody's (`unseenRelease`)
        kTokens.removeAll()
        releaseModes(.unplug)
        letGoOfHeld()   // keys a held button had down, and buttons it was remapped to
        // Presses still waiting to see if they're a combo: never replay them now, their
        // releases will never come. Found by scripts/engine-fuzz.
        pendingTimer?.invalidate()
        pendingTimer = nil
        for p in pending { overrides[p.button] = .swallow }
        pending = []
    }

    func deviceRemoved(key k: Int) {
        // A device whose properties never all arrived may have been the trackball: let go as for one.
        let maybeTrackball = incomplete.contains(k) && (devices[k]?.vendorID ?? DeviceIdentity.kensingtonVendorID) == DeviceIdentity.kensingtonVendorID
        if deviceSupported[k] == true || maybeTrackball { letGoOfTrackball(k) }
        hidButtonsByDevice[k] = nil
        devices[k] = nil
        deviceSupported[k] = nil
        echoDevices.remove(k)
        batteryDevices.remove(k)
        io.forgetDevice(k)
        io.unwatchTermination(k)
        transports[k] = nil
        hidBattery[k] = nil
        registryBattery[k] = nil
        deviceObjects[k] = nil
        incomplete.remove(k)
        lastIdentityRead[k] = nil
        // No trackball left: its presses' overrides would otherwise outlive it and catch
        // another mouse's release of the same button (swallowed: stuck down). Found by
        // scripts/engine-fuzz. Whatever they held was let go of above.
        if !deviceSupported.values.contains(true) {
            overrides.removeAll()
            kOpen.removeAll()
            kUpAt.removeAll()
            kReleasedSince.removeAll()
        }
        syncTap()
        publish()
    }

    /// Reads `BatteryPercent` from the registry for supported wireless Kensingtons,
    /// only with "Other Kensington trackballs" on. Read-only; never touches the device.
    private func refreshBatteries() {
        guard betaProgram else { return }
        for k in batteryDevices where deviceSupported[k] == true {
            guard let identity = devices[k] else { continue }
            guard DeviceConnection.classify(transport: transports[k], name: identity.name,
                                            productID: identity.productID)?.isWireless == true else { continue }
            registryBattery[k] = io.registryBattery(k)
        }
    }

    /// IOHIDManager's callback (input thread).
    func hidValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        hidInput(address: Self.address(device), fresh: Self.key(device), identity: Self.identity(of: device),
                 page: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)),
                 value: IOHIDValueGetIntegerValue(value), stamp: IOHIDValueGetTimeStamp(value),
                 logicalMin: IOHIDElementGetLogicalMin(element), logicalMax: IOHIDElementGetLogicalMax(element))
    }

    /// One HID value from the device object at `address` (scripts/engine-fuzz calls this
    /// directly). `fresh` reads the device's registry ID, only when the cached key won't do.
    func hidInput(address a: Int, fresh: @autoclosure () -> Int, identity: @autoclosure () -> DeviceIdentity,
                  page: Int, usage: Int, value v: Int, stamp: UInt64, logicalMin: Int = 0, logicalMax: Int = 100) {
        hidInput(key: resolveKey(address: a, fresh: fresh), identity: identity(), page: page, usage: usage, value: v,
                 stamp: stamp, logicalMin: logicalMin, logicalMax: logicalMax)
    }

    /// One HID value from device `k` (scripts/engine-fuzz calls this directly).
    func hidInput(key k: Int, identity: @autoclosure () -> DeviceIdentity, page: Int, usage: Int, value v: Int,
                  stamp: UInt64, logicalMin: Int = 0, logicalMax: Int = 100) {
        // Only devices that arrived (deviceAdded) count. A value delivered after its
        // device's removal used to re-add it here as supported, so "Connected" stayed
        // on after an unplug until a relaunch. A device whose removal never came is
        // plugged in, though: a check (at most once a second) brings it back.
        if devices[k] == nil {
            valueFromUnknown(k)
            guard devices[k] != nil else { return }
        }
        if incomplete.contains(k) {   // its properties were missing something when it arrived
            let now = io.now()
            if now - (lastIdentityRead[k] ?? -1e9) >= 0.25 {
                lastIdentityRead[k] = now
                refreshIdentity(k) { identity() }
            }
        }
        let isK = isSupported(key: k, identity: identity)
        lastActiveIsKensington = isK
        if !isK, page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y, v != 0 {
            otherDeviceMoved(k)
            // (Movement this close to the trackball's is its echo: `echoWindow`.)
            if !echoDevices.contains(k), io.now() - lastKMotion >= Self.echoWindow { lastMoverIsTrackball = false }
        }
        if !isK, page == kHIDPage_Button, usage >= 1, usage <= 32, !echoDevices.contains(k) {
            otherDeviceButton(k, Int64(usage - 1), down: v != 0)
        }
        guard isK else { return }
        lastSupportedValue = io.now()
        supportedValues &+= 1

        // The same hardware report can reach us twice (one device, two
        // matches). Each report has one hardware timestamp, so skip repeats.
        let usageKey = page << 16 | usage
        if lastValueStamp[usageKey] == stamp { return }
        lastValueStamp[usageKey] = stamp

        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X):
            telemetry.addBall(dx: v, dy: 0)
            let now = io.now()
            if v != 0 { trackballMoved(now); lastMoverIsTrackball = true; pendingTravel = min(pendingTravel + Int(min(v.magnitude, 1_000)), 1 << 30); holdForBallReport() }
            // A held gesture takes the ball (even over Scroll with ball): see GestureRoute.
            if gestures.isHeld { applyGesture(gestures.ball(dx: Double(v), dy: 0, now: now)); publishModes() }
            else if ballScrolling { scroller.addBallDelta(dx: Double(v) * ballSign, dy: 0) }
            watchDisplay(now: now)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            telemetry.addBall(dx: 0, dy: v)
            let now = io.now()
            if v != 0 { trackballMoved(now); lastMoverIsTrackball = true; pendingTravel = min(pendingTravel + Int(min(v.magnitude, 1_000)), 1 << 30); holdForBallReport() }
            if gestures.isHeld { applyGesture(gestures.ball(dx: 0, dy: Double(v), now: now)); publishModes() }
            else if ballScrolling { scroller.addBallDelta(dx: 0, dy: Double(v) * ballSign) }
            watchDisplay(now: now)
        case let (p, u) where DeviceBattery.isBatteryUsage(page: p, usage: u):
            let level = DeviceBattery.percent(value: v, logicalMin: logicalMin, logicalMax: logicalMax)
            if let level, hidBattery[k] != level {
                hidBattery[k] = level
                publish()
            }
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel) where v != 0:
            telemetry.addNotch(direction: v)
            hidWheel(v)
        case (kHIDPage_Button, let b) where b >= 1:
            telemetry.button(b - 1, down: v != 0)
            if v != 0 {
                hidButtonsByDevice[k, default: []].insert(b)
                kensingtonReportsButtons = true
                hidButtonSeen = true
            } else {
                hidButtonsByDevice[k]?.remove(b)
            }
            hidButtonsDown = hidButtonsByDevice.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
            if b <= 32 { trackballButton(Int64(b - 1), down: v != 0) }
        default: break
        }
    }

    private static let nativeScrollModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    /// One raw report from the scroll ring: `ticks` detents (usually ±1).
    private func hidWheel(_ ticks: Int) {
        let now = io.now()
        hidWheelSeen = true
        lastHIDWheel = (ticks, now)
        let flags = modifierFlags.union(io.keyboardFlags())
        diagnostics.record("HID wheel \(ticks)")
        // ⌘/⌃/⌥ + scroll keep their native meaning (zoom etc.): the driver's event passes.
        // In Native mode macOS does all the scrolling.
        guard config.enabled, config.scrollMode != .native,
              flags.intersection(Self.nativeScrollModifiers).isEmpty else { return }
        scroller.addTicks(Double(ticks) * directionFactor, flags: flags)
    }

    // MARK: Event tap

    private func installTap() {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .flagsChanged,
            .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        // Needs Accessibility; without it there's no tap and everything passes untouched.
        guard let (tap, source) = io.installTap(mask: mask, engine: self, runLoop: runLoop) else { return }
        self.tap = tap
        tapSource = source
        syncTap()
    }

    /// The tap only matters while a supported trackball is plugged in. Without one it
    /// would just inspect every click and scroll of the other mice and the trackpad for
    /// nothing, so it's switched off (and back on the moment a trackball appears).
    private func syncTap() {
        guard let tap else { return }
        let wanted = deviceSupported.values.contains(true)
        guard io.tapIsEnabled(tap) != wanted else { return }
        io.tapEnable(tap, wanted)
        // While it was off, presses and releases went by unseen: ask macOS what's down now.
        if wanted { noteButtonsAlreadyDown("tap on", clearTokens: true) }
    }

    /// The device that produced the most recent raw input. Without Input
    /// Monitoring we can't tell devices apart, so we leave everything alone.
    private var fromKensington: Bool { hid && lastActiveIsKensington }

    // MARK: Who pressed what

    /// Whose is this press: the trackball's, or another device's (another mouse, the trackpad)?
    /// "Last active device" isn't enough: a built-in trackpad's clicks never reach IOHIDManager,
    /// and two devices can press the same button number at once. A press is the trackball's
    /// when the trackball itself just reported that button going down (HID usage n+1 = CG
    /// button n) and no earlier press has claimed that report. Each report is claimed once, so
    /// another mouse pressing a button the trackball already holds is another mouse's.
    /// `device`: the other device whose HID report of that button this press claimed (nil: none,
    /// so not a HID mouse; the trackpad's clicks never reach HID).
    private func attributePress(_ button: Int64) -> (isK: Bool, device: Int?) {
        guard hid else { return (false, nil) }
        let now = io.now()
        if let t = kTokens.removeValue(forKey: button), now - t < Self.ownerWindow || hidButtonsDown.contains(Int(button) + 1) {
            return (true, nil)
        }
        // A device whose buttons never arrive over HID: fall back to the last active device.
        // (Its report may yet come, a moment later: it belongs to this press.)
        if !kensingtonReportsButtons && lastActiveIsKensington {
            kClaimedEarly[button] = now
            return (true, nil)
        }
        if lastActiveIsKensington && kensingtonReportsButtons {
            diagnostics.record("press of button \(button) not reported by the trackball: passed through")
        }
        guard let t = oTokens.removeValue(forKey: button), now - t.at < Self.ownerWindow else { return (false, nil) }
        return (false, t.device)
    }

    /// The trackball's HID report of button `b` (CG number) going down or up.
    private func trackballButton(_ b: Int64, down: Bool) {
        let now = io.now()
        guard down else {
            kUnseen.remove(b)
            if let t = kMatchedEarly.removeValue(forKey: b), now - t < Self.lateReportWindow { return }
            kUpAt[b] = now
            reportSeq &+= 1
            kUpSeq[b] = reportSeq
            if kOpen.contains(b) { kReleasedSince.insert(b) }
            if deferredUps.contains(where: { $0.button == b }) {
                if (otherPresses[b]?.isEmpty ?? true) && !othersHold(b) {
                    settleDeferredUp(b, .evidence)   // nobody else holds it: the waiting release was the trackball's
                } else {
                    // Another device holds it too: the waiting release is the trackball's if no
                    // other release of that button comes in the next moment (the trackball's own,
                    // behind its report). If one does, the waiting one was the other device's.
                    scheduleDeferTimer(Self.lateReportWindow)
                }
            }
            return
        }
        // Pressed again while its last release still waits to be told apart: that release was
        // the trackball's (it reported letting go in between). It goes out ahead of this press's
        // event (`handleButton`), or when its wait ends.
        if kUpFresh(b), deferredUps.contains(where: { $0.button == b }) { deferredIsTrackball.insert(b) }
        // Its earlier press of this button is still open, though it reported letting go of it
        // since: that release went by unseen (the tap was off). That press is over now, as if
        // its release had come (`handleButton`'s lost release, which this press's own event may
        // not get to do: it can arrive first and be taken for another device's).
        else { closeStaleTrackballPress(b) }
        kUpAt[b] = nil
        // Already known to be held (its last report said so as it arrived): the same press, whose
        // CG event went by unseen, not a new one. (Value callbacks only come on a change.)
        if kUnseen.contains(b) { return }
        // A press already taken for the trackball's without a report (`attributePress`'s fallback):
        // this is its report, not a new press another device's CG press could claim.
        if let t = kClaimedEarly.removeValue(forKey: b), now - t < Self.lateReportWindow, kOpen.contains(b) { return }
        // Its CG press came first, with no report to go on, and was taken for another device's:
        // it was this one. It went through as it was (as such presses always have); its release
        // is the trackball's. (Only when nothing of the trackball's holds that button already.)
        if !kOpen.contains(b), overrides[b] == nil, !pending.contains(where: { $0.button == b }),
           var list = otherPresses[b],
           let i = list.lastIndex(where: { !$0.reported && now - $0.at < Self.lateReportWindow }) {
            // (One that let go of a Drag lock did only that, as the trackball's press would have:
            // its release does nothing either.)
            if list.remove(at: i).swallowed { overrides[b] = .swallow }
            otherPresses[b] = list.isEmpty ? nil : list
            kOpen.insert(b)
            diagnostics.record("press of button \(b) came before the trackball's report: the trackball's, passed through")
            return
        }
        kTokens[b] = now
    }

    /// The trackball's open press of `b` that it has reported letting go of, whose release
    /// hasn't come and isn't waiting: that release went by unseen (the tap was off), or it
    /// would have come with the report. Something new on that button (the trackball pressing it
    /// again, another device pressing it) ends that press, as its release would have, so the
    /// stale report is never taken for a later release.
    private func closeStaleTrackballPress(_ b: Int64) {
        guard kOpen.contains(b), kReleasedSince.contains(b), !deferredUps.contains(where: { $0.button == b }) else { return }
        kOpen.remove(b)
        kReleasedSince.remove(b)
        kUpAt[b] = nil
        diagnostics.record("release of button \(b) never came after the trackball let go of it: that press is over")
        if pending.contains(where: { $0.button == b }) { flushPending(); postedForStale.insert(b) }
        if overrides[b] != nil, releaseOverride(b) { postedForStale.insert(b) }
        if learnHeld.remove(Int(b)) != nil, learnHeld.isEmpty, let handler = learnHandler {   // as its release would have
            let result = learnMax
            learnHandler = nil
            io.toMain { handler(result) }
        }
    }

    /// Device `k`'s HID report of button `b` going down or up.
    private func otherDeviceButton(_ k: Int, _ b: Int64, down: Bool) {
        if down {
            // A press of that device's that's still open had its release go by unseen.
            if var list = otherPresses[b], list.contains(where: { $0.device == k }) {
                list.removeAll { $0.device == k }
                otherPresses[b] = list.isEmpty ? nil : list
            }
            oTokens[b] = (io.now(), k)
            oUpAt[b] = nil
        } else {
            if let m = oMatchedEarly[b], io.now() - m.at < Self.lateReportWindow, m.device == nil || m.device == k {
                oMatchedEarly[b] = nil
                return
            }
            if var list = otherPresses[b], let i = list.firstIndex(where: { $0.device == k && !$0.hidReleased }) {
                list[i].hidReleased = true
                otherPresses[b] = list
            }
            oUpAt[b] = io.now()
            oUpDevice[b] = k
            reportSeq &+= 1
            oUpSeq[b] = reportSeq
            guard deferredUps.contains(where: { $0.button == b }) else { return }
            // A release waiting for this is that device's, unless the trackpad (whose releases
            // never report) could own it: then that device's own release may yet follow its
            // report, which would make the waiting one the trackpad's.
            let list = otherPresses[b] ?? []
            if list.contains(where: { $0.device == k }), list.contains(where: { !$0.reported }) {
                scheduleDeferTimer(Self.lateReportWindow)
            } else {
                settleDeferredUp(b, .final)
            }
        }
    }

    /// Another device holds `b`: a press the engine saw, or one it didn't (past a switched-off
    /// tap, counted when the tap came back) while apps have the button down and the trackball's
    /// press didn't put it there.
    private func othersHold(_ b: Int64) -> Bool {
        (otherPresses[b] ?? []).contains { !$0.hidReleased }
            || ((overrides[b] != nil || pending.contains { $0.button == b }) && appButtons.contains(b))
    }

    /// The trackball's press of `b` is still open but its release went by unseen (the tap was
    /// off): the trackball reported letting go of it a while ago.
    private func kStale(_ b: Int64) -> Bool {
        kReleasedSince.contains(b) && !kUpFresh(b)
    }
    private func kUpFresh(_ b: Int64) -> Bool { kUpAt[b].map { io.now() - $0 < Self.ownerWindow } ?? false }
    private func oUpFresh(_ b: Int64) -> Bool { oUpAt[b].map { io.now() - $0 < Self.ownerWindow } ?? false }

    private enum UpOwner { case trackball, trackballUnseen, other, nobody, wait }

    /// Whose is this release of `b`? Matched to an open press by the HID reports of that button
    /// going up. `wait`: the trackball's press is open and it still says the button is down, so
    /// this is another device's release (the trackpad, whose buttons never reach HID, or a press
    /// that went by unseen) or the trackball's own, arriving just before its report.
    private func ownerOfUp(_ b: Int64) -> UpOwner {
        let kLive = kOpen.contains(b) && !kStale(b)
        let k = kLive || kUnseen.contains(b) || kUpFresh(b)
        let o = !(otherPresses[b]?.isEmpty ?? true)
        guard k else { return o ? .other : .nobody }
        let kOwner: UpOwner = kLive ? .trackball : .trackballUnseen
        let kDown = kUnseen.contains(b) || (kensingtonReportsButtons && hidButtonsDown.contains(Int(b) + 1))
        let kReleased = !kDown && kUpFresh(b)
        let oReleased = oUpFresh(b)   // another device reported that button going up (even one whose press went by unseen)
        if kReleased && (!oReleased || kUpAt[b]! <= oUpAt[b]!) { return kOwner }
        if oReleased { return o ? .other : .nobody }
        if !kDown { return kOwner }   // nothing to go on (its buttons don't come over HID): as before
        return .wait
    }

    /// The release of `b`, as its owner has it.
    /// `reportCame`: the trackball's report of this release has come already. `keepReports`:
    /// the reports so far are another release's (`settleDeferredUp`), not this one's.
    private func finishUp(_ event: CGEvent, _ b: Int64, _ owner: UpOwner, reportCame: Bool = false,
                          keepReports: Bool = false) -> Unmanaged<CGEvent>? {
        let now = io.now()
        switch owner {
        case .trackball, .trackballUnseen:
            // Its report is still to come (the trackball says the button is down still).
            if !kUpFresh(b) && !reportCame && (hidButtonsDown.contains(Int(b) + 1) || kUnseen.contains(b)) { kMatchedEarly[b] = now }
            kUpAt[b] = nil
            kReleasedSince.remove(b)
            kClaimedEarly[b] = nil
            if owner == .trackballUnseen {
                kUnseen.remove(b)
                kTokens[b] = nil   // a report of its press no press claimed is over too
                return unseenRelease(event, b)
            }
            kOpen.remove(b)
            return routeButton(event, .up)
        case .other, .nobody, .wait:
            if owner != .other, !kOpen.contains(b) { kTokens[b] = nil }   // as above
            let device = !keepReports && oUpFresh(b) ? oUpDevice[b] : nil
            if device != nil { oUpAt[b] = nil }   // the report it went with
            guard owner == .other else {
                // Nobody's press: a report from whichever device in the next moment is its own.
                if device == nil, !(keepReports && oUpFresh(b)) {
                    oMatchedEarly[b] = (now, nil)
                    if !kUpFresh(b), !kOpen.contains(b), !kUnseen.contains(b), hidButtonsDown.contains(Int(b) + 1) { kMatchedEarly[b] = now }
                }
                return unseenRelease(event, b)
            }
            let (out, popped) = otherRelease(event, b, device: device)
            if device == nil, !(keepReports && oUpFresh(b)), let popped { oMatchedEarly[b] = (now, popped) }   // its report is still to come
            return out
        }
    }

    /// Another device's press: untouched (though a trackball button remapped to the same button
    /// lets go first, so apps never see it go down twice), except that a left click lets go of a
    /// Drag lock, and that's all it does. Nothing the trackball holds ends or changes.
    private func otherPress(_ event: CGEvent, _ button: Int64, device: Int?) -> Unmanaged<CGEvent>? {
        closeStaleTrackballPress(button)
        let posted = postedForStale.remove(button) != nil   // then this press goes behind what was posted
        if gestures.isHeld { gestures.otherPress(Int(button)) }   // the hold's release isn't a tap
        let swallow = dragLocked && (event.type == .leftMouseDown || button == 0)
        otherPresses[button, default: []].append(OtherPress(device: device, at: io.now(), swallowed: swallow))
        if swallow {
            endDragLock()
            return nil
        }
        guard posted else { return passReal(event, button: button) }
        postInOrder(passReal(event, button: button))
        return nil
    }

    /// Another device's release: always as it came (unless its press ended a Drag lock).
    /// `device`: the device that reported it going up (nil: none did, so the trackpad's).
    /// Returns the event (or nil) and the device whose press it matched.
    private func otherRelease(_ event: CGEvent, _ button: Int64, device: Int?) -> (Unmanaged<CGEvent>?, Int?) {
        var list = otherPresses[button] ?? []
        let i = (device.flatMap { d in list.firstIndex { $0.device == d } })
            ?? list.firstIndex { $0.reported == (device != nil) } ?? list.indices.first
        var press: OtherPress?
        if let i { press = list.remove(at: i) }
        otherPresses[button] = list.isEmpty ? nil : list
        return (press?.swallowed == true ? nil : Unmanaged.passUnretained(event), press?.device)
    }

    /// A release whose press this engine never saw (held while it started, while the tap was
    /// off, or as the trackball arrived): nothing mapped happens. It goes through if apps have
    /// that button down, so they get its release; otherwise it's swallowed, so they never see
    /// a release without a press.
    private func unseenRelease(_ event: CGEvent, _ button: Int64) -> Unmanaged<CGEvent>? {
        if button != 0, overrides.values.contains(where: { if case .remap(let t, _) = $0 { t == button } else { false } }) {
            // Another button is remapped to this one and holding it: passing this would let go
            // of that hold. Found by scripts/engine-fuzz.
            return nil
        }
        // Down by the engine's count or by macOS's own word (two devices can hold a button
        // macOS counts once; when in doubt it goes through: a stray release is harmless, a
        // button left down is not).
        if appButtons.contains(button) || io.buttonDown(button) { return Unmanaged.passUnretained(event) }
        diagnostics.record("release of button \(button) whose press was never seen, not down for apps: swallowed")
        return nil
    }

    /// How a release that waited is settled: by the reports so far, keeping it if they still
    /// don't say (`evidence`); by the reports, and if they don't say, not the trackball's
    /// (`final`: time's up, quit, sleep, the other device's report); or not the trackball's
    /// (`notTrackball`: another release of that button came, the trackball's own behind its
    /// report, so the waiting one was the other device's). Whatever the way, one the trackball
    /// has since reported letting go of and pressing again is the trackball's (`deferredIsTrackball`).
    private enum Settle { case evidence, final, notTrackball }
    private var deferredIsTrackball = Set<Int64>()

    /// Releases of `b` that waited to be told apart, in the order they arrived.
    private func settleDeferredUp(_ b: Int64, _ how: Settle) {
        guard deferredUps.contains(where: { $0.button == b }) else { return }
        var kept: [(button: Int64, event: CGEvent)] = []
        let waiting = deferredUps
        deferredUps = []
        for d in waiting {
            guard d.button == b else { kept.append(d); continue }
            let pressedAgain = deferredIsTrackball.remove(b) != nil
            var keepReports = false
            var owner: UpOwner
            if pressedAgain {
                owner = kOpen.contains(b) ? .trackball : .trackballUnseen
            } else if how == .notTrackball {
                // Another release of the button came: this waiting one is the other side's.
                // - Another device's report is the newest: the new release is that device's
                //   (a report and its event come together), so this one is the trackball's if it
                //   has reported letting go too, otherwise the trackpad's (no reports) or nobody's.
                // - The trackball's report is the newest, and every other press of the button is
                //   a HID mouse's (which would have reported its own release by now): this one was
                //   the trackball's (its event before its report), the new one the mouse's.
                // - Otherwise (the trackpad among them, or no report): not the trackball's.
                let list = otherPresses[b] ?? []
                let kSeq = kUpFresh(b) ? kUpSeq[b] ?? 0 : 0, oSeq = oUpFresh(b) ? oUpSeq[b] ?? 0 : 0
                let kReleasedNow = kUpFresh(b) && !hidButtonsDown.contains(Int(b) + 1) && (kOpen.contains(b) || kUnseen.contains(b))
                let kOwner: UpOwner = kOpen.contains(b) ? .trackball : .trackballUnseen
                if kReleasedNow, oSeq > kSeq || (!list.isEmpty && list.allSatisfy(\.reported)) {
                    owner = kOwner
                } else {
                    owner = list.isEmpty ? .nobody : .other
                    keepReports = oSeq > kSeq   // that report is the new release's
                }
            } else {
                owner = ownerOfUp(b)
            }
            if owner == .wait {
                guard how != .evidence else { kept.append(d); continue }
                owner = (otherPresses[b]?.isEmpty ?? true) ? .nobody : .other
            }
            diagnostics.record("release of button \(b) held back, then \(owner)")
            postInOrder(finishUp(d.event, b, owner, reportCame: pressedAgain, keepReports: keepReports))
        }
        deferredUps = kept + deferredUps
        if deferredUps.isEmpty {
            deferTimer?.invalidate()
            deferTimer = nil
        }
    }

    /// Every release still waiting goes out (time's up, quit, sleep), as the reports say.
    private func resolveDeferredUps() {
        for b in Set(deferredUps.map(\.button)) { settleDeferredUp(b, .final) }
    }

    /// Settles what's waiting in `seconds` (sooner than already planned only).
    private func scheduleDeferTimer(_ seconds: TimeInterval) {
        let at = io.now() + seconds
        if deferTimer != nil, deferTimerAt <= at { return }
        deferTimer?.invalidate()
        deferTimerAt = at
        deferTimer = io.schedule(seconds, repeats: false) { [unowned self] in
            self.deferTimer = nil
            self.resolveDeferredUps()
        }
    }
    private var deferTimerAt: CFTimeInterval = 0

    /// Buttons already down whose presses went by unseen (the engine starting, the tap back on,
    /// a trackball arriving): what apps have down now, and which of the trackball's buttons are
    /// held (by its HID reports and, read-only, its last report's button values). Their releases
    /// do nothing mapped (`unseenRelease`). `clearTokens`: presses reported meanwhile went by too.
    private func noteButtonsAlreadyDown(_ why: String, clearTokens: Bool) {
        let down = io.buttonsDown()
        guard clearTokens else {
            appButtons.refresh(down)   // nothing went by unseen: the counts stand
            return noteTrackballHeld(why)
        }
        // Presses released meanwhile (not one that ended a Drag lock: apps never had it, so
        // macOS's answer can't speak for it; that device's next press clears it). A press whose
        // device reported letting go had its release go by too.
        for (b, list) in otherPresses {
            let kept = list.filter { !$0.hidReleased && ($0.swallowed || down.contains(b)) }
            otherPresses[b] = kept.isEmpty ? nil : kept
        }
        // Counted again. macOS counts a button once however many hold it, so where it says
        // down: the presses known to hold it (the trackball's own passing as itself, a remap
        // onto it, a Drag lock's, other devices'), or one if none of those explains it, unless a
        // release the engine just posted (not back through the tap yet) does. Where it says up:
        // only presses the engine just posted that aren't back yet.
        let now = io.now()
        notedAtPost = notedAtPost.compactMapValues { list in
            let fresh = list.filter { now - $0 < 0.25 }   // older ones never came back (the tap was off)
            return fresh.isEmpty ? nil : fresh
        }
        let remapTargets = overrides.values.compactMap { if case .remap(let t, _) = $0 { t } else { nil } }
        var counts: [Int64: Int] = [:]
        for b in down.union(otherPresses.keys).union(kOpen).union(remapTargets).union(dragLocked ? [0] : []) {
            var n = (otherPresses[b] ?? []).filter { !$0.swallowed }.count
            // (Not a press the trackball has reported letting go of: its release went by.)
            if kOpen.contains(b), !kReleasedSince.contains(b), overrides[b] == nil, !pending.contains(where: { $0.button == b }) { n += 1 }
            n += remapTargets.filter { $0 == b }.count
            if dragLocked && b == 0 { n += 1 }
            let leaving = !(notedAtPost[b << 1 | 1]?.isEmpty ?? true)
            if n == 0, down.contains(b), !leaving { n = 1 }
            if !down.contains(b) { n = notedAtPost[b << 1]?.count ?? 0 }
            if n > 0 { counts[b] = n }
        }
        appButtons.set(counts)
        // Releases waiting to be told apart go out now, by the reports so far (and after the
        // count, so whatever they set off knows what's down), before the reports are forgotten.
        resolveDeferredUps()
        kTokens.removeAll()
        oTokens.removeAll()
        // Reports of releases whose events went by: no longer news of anything coming.
        kUpAt.removeAll(); oUpAt.removeAll(); kMatchedEarly.removeAll(); oMatchedEarly.removeAll()
        noteTrackballHeld(why)
    }

    /// The trackball's buttons held whose presses went by unseen (`noteButtonsAlreadyDown`).
    private func noteTrackballHeld(_ why: String) {
        var held = Set(hidButtonsDown.map { Int64($0 - 1) })
        for (k, supported) in deviceSupported where supported {
            if let h = io.heldButtons(k, deviceObjects[k] ?? nil) { held.formUnion(h) }
        }
        let unseen = held.subtracting(kOpen).subtracting(pending.map(\.button)).subtracting(kTokens.keys)
        if !unseen.isSubset(of: kUnseen) {
            diagnostics.record("trackball buttons already down (\(why)): \(unseen.sorted()); their releases do nothing mapped")
        }
        kUnseen.formUnion(unseen)
        // A press with no report of its own just before, of a button the trackball turns out to
        // hold, was the trackball's (its report came before Glideball had the device open).
        let now = io.now()
        for b in unseen {
            guard var list = otherPresses[b], let i = list.lastIndex(where: { !$0.reported && now - $0.at < Self.ownerWindow })
            else { continue }
            list.remove(at: i)
            otherPresses[b] = list.isEmpty ? nil : list
        }
    }

    /// The event tap's callback (scripts/engine-fuzz calls it directly).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let out = route(type, event)
        if let e = out?.takeUnretainedValue() {
            // One posted from the input thread was noted as it was posted: not twice.
            // (One posted over 0.25 s ago never came back: posted while the tap was off.)
            if e.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag, let k = Self.buttonKey(e),
               let list = notedAtPost[k]?.filter({ io.now() - $0 < 0.25 }), !list.isEmpty {
                notedAtPost[k] = Array(list.dropFirst())
            } else {
                noteOut(e)
            }
        }
        return out
    }

    /// Keeps `appButtons` up to date with a button event on its way to apps: one the tap
    /// passes, or one posted from the input thread (noted at once, so a decision made before
    /// it comes back through the tap already knows: `noteAtPost`). Input thread.
    private func noteOut(_ e: CGEvent) {
        switch e.type {
        case .leftMouseDown: appButtons.insert(0)
        case .leftMouseUp: appButtons.remove(0)
        case .rightMouseDown, .otherMouseDown: appButtons.insert(e.getIntegerValueField(.mouseEventButtonNumber))
        case .rightMouseUp, .otherMouseUp: appButtons.remove(e.getIntegerValueField(.mouseEventButtonNumber))
        default: break
        }
    }

    /// Notes an event the input thread is about to post (`appButtons` counts each press once:
    /// when it comes back through the tap it isn't noted again). Clicks posted from the key
    /// queue aren't noted here; the tap notes them.
    private func noteAtPost(_ e: CGEvent) {
        noteOut(e)
        if let k = Self.buttonKey(e) { notedAtPost[k, default: []].append(io.now()) }
    }
    /// Posted button events not back through the tap yet, by `buttonKey`, with when.
    private var notedAtPost: [Int64: [CFTimeInterval]] = [:]
    /// A button event's key for `notedAtPost`: its button doubled, plus one for a release.
    private static func buttonKey(_ e: CGEvent) -> Int64? {
        let b = e.getIntegerValueField(.mouseEventButtonNumber)
        switch e.type {
        case .leftMouseDown: return 0 << 1
        case .leftMouseUp: return 0 << 1 | 1
        case .rightMouseDown, .otherMouseDown: return b << 1
        case .rightMouseUp, .otherMouseUp: return b << 1 | 1
        default: return nil
        }
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A gesture's release may have gone by while the tap was off: free the pointer now.
            cancelGesture(.tapDisabled)
            // The pointer moved freely while the tap was off; a hold still on (a keyboard
            // Scroll with ball) keeps it where it is now instead of pulling it back.
            if anchor != nil, let p = io.cursorLocation() {
                anchor = p   // here and now: the trackball's next move may already be on its way
                otherMovedSinceAnchor = false
                anchorBeforeFollow = nil
            }
            noteButtonsAlreadyDown("tap back on", clearTokens: true)   // what went by while it was off
            syncTap()
            if let moveTap { io.tapEnable(moveTap, true) }
            // So may the release of a button holding a key or remapped to another button:
            // the failsafe lets go of them once the trackball says the button is up.
            if heldByButton { startHoldFailsafe() }
            return pass
        case _ where event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag:
            return pass   // our own events
        case .mouseMoved where anchor != nil && trackballMoving:
            // The pointer is held: the trackball's moves never reach apps, in any app.
            holdStats.tapMoves += 1
            holdPointer(seen: event.location)
            // Another mouse moved with the ball just now: this move may be its, so it goes
            // through (the pointer is put back all the same). A known echo device's never does.
            return io.now() - sharedMotionAt < Self.echoWindow ? pass : nil
        case .mouseMoved where anchor != nil:
            followOtherMouse(at: event.location)   // another mouse's move: the hold moves with it
            return pass
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if anchor != nil {
                if trackballMoving { holdStats.tapDrags += 1; holdPointer(seen: event.location) } else { followOtherMouse(at: event.location) }
            }
            return handleButton(event, .drag)
        case .mouseMoved where dragLocked:
            // macOS may not count our synthetic press as a held button, so it
            // reports plain moves: make them the drag the lock promised.
            Self.retarget(event, to: 0, .drag)
            event.setDoubleValueField(.mouseEventPressure, value: 1)
            return pass
        case .scrollWheel:
            return handleScroll(event)
        case .flagsChanged:
            modifierFlags = event.flags
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return handleButton(event, .down)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleButton(event, .up)
        default:
            return pass
        }
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Kensington's wheel event can arrive without the Shift flag even while
        // Shift is physically held. `flagsChanged` above is the authoritative
        // source for the keyboard state; do not overwrite it here.
        // The Kensington's ring arrives as normal wheel clicks with Apple's
        // driver, but as "continuous" pixel events (no gesture phase) with
        // Kensington's driver. Either way each event is one detent. Real
        // trackpad gestures always carry a phase, so those pass through.
        let phase = event.getIntegerValueField(CGEventField(rawValue: 99)!)
        let momentum = event.getIntegerValueField(CGEventField(rawValue: 123)!)
        guard config.enabled, config.scrollMode != .native, fromKensington, phase == 0, momentum == 0 else { return pass }

        let cgDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        if hidWheelSeen {
            learnDirection(cgDelta: cgDelta)
            diagnostics.record(String(format: "CG in  cont=%lld pt=%lld fp=%.2f -> %@",
                                      event.getIntegerValueField(.scrollWheelEventIsContinuous),
                                      event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), cgDelta,
                                      event.flags.intersection(Self.nativeScrollModifiers).isEmpty ? "swallowed" : "native"))
            if !event.flags.intersection(Self.nativeScrollModifiers).isEmpty {
                if config.reverseScroll { Self.invert(event) }
                return pass
            }
            return nil   // the raw HID ticks already drove the scroller
        }

        // ⌘ / ⌃ / ⌥ + scroll keep their native meaning (zoom, etc).
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            if config.reverseScroll { Self.invert(event) }
            return pass
        }
        var dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if dy == 0 { dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) }
        if dx == 0 { dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) }
        let v: Double = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        let h: Double = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        guard v != 0 || h != 0 else { return pass }
        diagnostics.record("CG fallback tick \(v) \(h)")
        scroller.addTicks(v != 0 ? v : h, horizontal: v == 0, flags: event.flags)
        return nil
    }

    /// Compares the driver's scroll sign with the raw tick that caused it, so
    /// Glide scrolls the same way macOS would (natural scrolling and all).
    private func learnDirection(cgDelta: Double) {
        let age = io.now() - lastHIDWheel.time
        guard cgDelta != 0, lastHIDWheel.value != 0, age < 0.08 else { return }
        let observed: Double = (cgDelta > 0) == (lastHIDWheel.value > 0) ? 1 : -1
        if observed == directionFactor {
            directionVotes = 0
        } else {
            directionVotes += 1
            if directionVotes >= 3 {
                directionFactor = observed
                directionVotes = 0
                io.savedScrollDirection = observed
                diagnostics.record("direction learned: \(observed)")
            }
        }
    }

    private static func invert(_ e: CGEvent) {
        for f: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
            e.setIntegerValueField(f, value: -e.getIntegerValueField(f))
        }
        for f: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            e.setDoubleValueField(f, value: -e.getDoubleValueField(f))
        }
    }

    // MARK: Buttons, combos, and learning

    /// How long a combo button waits for its partners before acting alone.
    private static let comboWindow: TimeInterval = 0.07
    /// Longest a combo button's press is ever held back while more fingers land.
    private static let comboMaxWait: TimeInterval = 0.16
    private var pendingStart: CFTimeInterval = 0
    /// The trackball's roll (HID counts, |x| + |y|) since the first waiting press.
    private var pendingTravel = 0
    /// Less roll than this while a combo button waits is the hand settling, not a drag
    /// (under the gestures' tap slop, about 0.75 mm).
    private static let comboMoveSlop = 12

    private var pending: [(button: Int64, event: CGEvent)] = []
    private var pendingTimer: EngineTimer?
    private var learnHandler: ((Set<Int>) -> Void)?
    private var learnHeld = Set<Int>()
    private var learnMax = Set<Int>()

    /// The next Kensington press (or presses held together) is captured and
    /// delivered on main instead of doing anything.
    func learnNextPress(_ handler: ((Set<Int>) -> Void)?) {
        perform {
            self.learnHandler = handler
            self.learnHeld = []
            self.learnMax = []
        }
    }

    /// Some button is holding `s` down already (a second press would be a second key down,
    /// and the first release would let go of both). Found by scripts/engine-fuzz.
    private func holding(_ s: KeyShortcut) -> Bool {
        overrides.values.contains { if case .heldShortcut(let held) = $0 { held == s } else { false } }
    }

    /// The key `s` just went up: the other buttons holding it (a chord's) finish silently.
    /// Only those: a different button holding a different shortcut keeps its key down until
    /// its own release. (Every held shortcut used to be silenced here, so letting go of one
    /// button left another button's keys, ⌘ and ⌥ included, stuck down. Found by
    /// scripts/engine-fuzz.)
    private func silenceHeld(_ s: KeyShortcut) {
        for (b, o) in overrides {
            if case .heldShortcut(let held) = o, held == s { overrides[b] = .swallow }
        }
    }

    /// Ends whatever `button`'s earlier press is holding, as its release would have, and
    /// forgets the override. Returns true if it posted a button release (so what comes
    /// next must be posted behind it). Input thread.
    @discardableResult
    private func releaseOverride(_ button: Int64) -> Bool {
        guard let o = overrides[button] else { return false }
        overrides[button] = nil
        switch o {
        case .swallow, .dragButton:
            break   // nothing held (a drag lock is a latch: a click ends it)
        case .remap(let target, let flags):
            postButton(target, down: false, flags: flags, tap: .cgSessionEventTap)
            return true
        case .heldShortcut(let s):
            io.keys { self.sendUp(s) }
            silenceHeld(s)   // a chord's other buttons finish silently
        case .precision:
            overrides[button] = .precision
            endPrecisionHold()
            overrides[button] = nil
        case .ballScroll:
            overrides[button] = .ballScroll
            endBallScroll(latched: false, glide: false)
            overrides[button] = nil
        case .gesture:
            cancelGesture(.lostRelease)
            overrides[button] = nil
        }
        return false
    }

    /// Every button event: first whose it is (`attributePress`, `ownerOfUp`), then the
    /// trackball's go to `routeButton` and everything else passes untouched. What a trackball
    /// press holds is ended by the trackball's own release (or, once the trackball has reported
    /// letting go and that release went by unseen, by the next press of that button:
    /// `closeStaleTrackballPress`), never by another device's press or release.
    private func handleButton(_ event: CGEvent, _ phase: Phase) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        // A release of this button still waiting to be told apart goes first, and this event
        // is posted behind it, so apps see them in order.
        if deferredUps.contains(where: { $0.button == button }) {
            settleDeferredUp(button, phase == .up ? .notTrackball : .final)
            postInOrder(ownedButton(event, phase, button))
            return nil
        }
        return ownedButton(event, phase, button)
    }

    private func ownedButton(_ event: CGEvent, _ phase: Phase, _ button: Int64) -> Unmanaged<CGEvent>? {
        switch phase {
        case .down:
            let (isK, device) = attributePress(button)
            guard isK else { return otherPress(event, button, device: device) }
            kUnseen.remove(button)
            // The trackball's press of a button that is still waiting for a combo partner, or still
            // has an override: its release was lost. The old press goes through (or lets go of
            // what it holds) first, so this one can never leave a key or a button stuck; this
            // press is then posted behind that, so apps see them in order. Found by scripts/engine-fuzz.
            var posted = postedForStale.remove(button) != nil   // (`closeStaleTrackballPress` posted its end)
            if pending.contains(where: { $0.button == button }) { flushPending(); posted = true }
            if overrides[button] != nil, releaseOverride(button) { posted = true }
            kOpen.insert(button)
            kReleasedSince.remove(button)
            if posted {
                postInOrder(routeButton(event, phase))
                return nil
            }
            return routeButton(event, phase)
        case .up:
            let owner = ownerOfUp(button)
            guard owner == .wait else { return finishUp(event, button, owner) }
            // Held back for a moment (at most `deferLimit`): the trackball's report says which.
            guard let copy = event.copy() else { return finishUp(event, button, .nobody) }
            deferredUps.append((button, copy))
            scheduleDeferTimer(Self.deferLimit)
            return nil
        case .drag:
            // Both hold this button: the drag is the device that moved last.
            // (Not a press the trackball has reported letting go of: its release went by.)
            let k = (kOpen.contains(button) && !kReleasedSince.contains(button)) || kUnseen.contains(button)
            let list = otherPresses[button] ?? []
            let others = othersHold(button) || (!k && kOpen.contains(button) && appButtons.contains(button))
            if others, !k || !lastMoverIsTrackball {
                return !list.isEmpty && list.allSatisfy(\.swallowed) ? nil : Unmanaged.passUnretained(event)
            }
            // A button whose press went by unseen and that apps don't have down (it was mapped
            // before a relaunch, say): its drags are plain moves to apps, as Precision makes them.
            if !kOpen.contains(button), overrides[button] == nil, !pending.contains(where: { $0.button == button }),
               !appButtons.contains(button), !io.buttonDown(button) {
                if leftDown {
                    Self.retarget(event, to: 0, .drag)
                } else {
                    event.type = .mouseMoved
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                }
                return Unmanaged.passUnretained(event)
            }
            return routeButton(event, phase)
        }
    }

    /// The trackball's button events (`handleButton` has decided whose each one is).
    private func routeButton(_ event: CGEvent, _ phase: Phase) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        // Any other press during a gesture hold means the release isn't a tap.
        if phase == .down, gestures.isHeld { gestures.otherPress(Int(button)) }

        // Drag lock: any click (from any mouse: see `otherPress`) lets go — and that's all it does.
        // (A press that may be the start of a Drag lock combo waits for the
        // combo; if it turns out to be a lone click, `press` lets go instead.)
        if dragLocked, phase == .down, isLeftPress(event, button), !inDragLockCombo(button) {
            endDragLock()
            overrides[button] = .swallow
            return nil
        }

        if let handler = learnHandler, phase == .down || learnHeld.contains(Int(button)) {
            if phase == .down {
                learnHeld.insert(Int(button))
                learnMax.formUnion(learnHeld)
                // Its release is swallowed too, even if Quick assign restarts (or is
                // cancelled) meanwhile. Found by scripts/engine-fuzz.
                overrides[button] = .swallow
            } else if phase == .up {
                learnHeld.remove(Int(button))
                overrides[button] = nil
                if learnHeld.isEmpty {
                    let result = learnMax
                    learnHandler = nil
                    io.toMain { handler(result) }
                }
            }
            return nil
        }

        // A combo member still waiting: anything else it does means "not a combo".
        // Replay the held press first, then post this event after it, so macOS
        // always sees press → drag → release in order (never a stuck button).
        // Except the ball barely turning under the hand pressing the buttons (a few counts,
        // by the trackball's own HID reports): that drag is nobody's yet, so it's dropped and
        // the wait goes on. It used to end the wait, so a combo (a gesture on two buttons
        // most of all, pressed with the hand on the ball) often never formed.
        if phase == .drag, hid, pendingTravel < Self.comboMoveSlop, pending.contains(where: { $0.button == button }) {
            return nil
        }
        if phase != .down, pending.contains(where: { $0.button == button }) {
            flushPending()
            postInOrder(routeButton(event, phase))
            return nil
        }

        // A press we took over: its drag and release follow it, always,
        // so a button can never get stuck down.
        if phase != .down, let o = overrides[button] {
            if phase == .up { overrides[button] = nil }
            switch o {
            case .swallow: return nil
            case .remap(let target, let flags):
                Self.retarget(event, to: target, phase)
                if !flags.isEmpty { event.flags = event.flags.union(flags) }
                return pass
            case .heldShortcut(let shortcut):
                if phase == .up {
                    // First button of the hold to lift releases the key — once.
                    // The chord's other buttons just finish silently.
                    io.keys { self.sendUp(shortcut) }
                    silenceHeld(shortcut)
                }
                return nil
            case .precision:
                if phase == .up {
                    endPrecisionHold()
                    return nil
                }
                // Moving while holding: still a plain move (or a drag) to apps.
                if leftDown {
                    Self.retarget(event, to: 0, .drag)
                } else {
                    event.type = .mouseMoved
                    event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                }
                return pass
            case .ballScroll:
                if phase == .up { endBallScroll(latched: false, glide: true) }
                return nil
            case .dragButton:
                // Rolling before letting go of the lock button already drags.
                guard phase == .drag, dragLocked else { return nil }
                Self.retarget(event, to: 0, .drag)
                return pass
            case .gesture:
                if phase == .up {
                    let effects = gestures.release(button: Int(button), now: io.now())
                    // A combo gesture ends with its first button up; the others finish silently.
                    for (b, other) in overrides {
                        if case .gesture = other { overrides[b] = .swallow }
                    }
                    applyGesture(effects)
                }
                return nil   // drags never reach apps: the pointer is frozen and the ball is the gesture's
            }
        }
        // (A release whose press this engine never saw never gets here: `unseenRelease`.)
        guard phase == .down else { return pass }
        // Glideball paused: untouched (though a trackball button remapped to the same button
        // lets go first, so apps never see it go down twice).
        guard config.enabled else { return passReal(event, button: button) }

        let comboButtons = Set(config.chords.flatMap(\.buttons))
        guard comboButtons.contains(Int(button)) else {
            guard !pending.isEmpty else { return press(event, button: button) }
            flushPending()
            postInOrder(press(event, button: button))
            return nil
        }

        // Hold this press briefly to see if it becomes a combo.
        guard let copy = event.copy() else { return press(event, button: button) }
        pending.append((button, copy))
        let held = Set(pending.map { Int($0.button) })
        let exact = config.chords.first { Set($0.buttons) == held }
        let biggerPossible = config.chords.contains { Set($0.buttons).isStrictSuperset(of: held) }
        if let exact, !biggerPossible {
            fireCombo(exact)
        } else if pending.count == 1 {
            pendingStart = io.now()
            pendingTravel = 0
            scheduleComboWindow(Self.comboWindow)
        } else if biggerPossible {
            // A partner arrived and a bigger combo is still possible: give the
            // next finger a moment too (three fingers rarely land within 70 ms),
            // but never hold the first press longer than `comboMaxWait`.
            let left = Self.comboMaxWait - (io.now() - pendingStart)
            scheduleComboWindow(max(0.01, min(Self.comboWindow, left)))
        }
        return nil
    }

    private func scheduleComboWindow(_ seconds: TimeInterval) {
        pendingTimer?.invalidate()
        pendingTimer = io.schedule(seconds, repeats: false) { [unowned self] in self.comboWindowEnded() }
    }

    private func comboWindowEnded() {
        let held = Set(pending.map { Int($0.button) })
        // A waiting press whose button the trackball already says is up: its release went
        // by while the tap was off. Replayed on its own it would stay down for good (found by
        // scripts/engine-fuzz), so it gets its release too: a whole click. A late release
        // through the tap then does nothing.
        let released = kensingtonReportsButtons
            ? pending.map(\.button).filter { !hidButtonsDown.contains(Int($0) + 1) } : []
        if held.count > 1, let chord = config.chords.first(where: { Set($0.buttons) == held }) {
            fireCombo(chord)
        } else {
            flushPending()
        }
        for b in released {
            if overrides[b] == nil {
                if appButtons.contains(b) { postButton(b, down: false, tap: .cgSessionEventTap) }   // it passed as itself
            } else {
                releaseOverride(b)
            }
            overrides[b] = .swallow
        }
    }

    private func fireCombo(_ chord: Chord) {
        pendingTimer?.invalidate()
        pendingTimer = nil
        let pressedButtons = pending
        pending = []
        var action = chord.action
        if case .gesture(let g) = action {
            let buttons = pressedButtons.map(\.button)
            switch gestureRoute(action, buttons: buttons) {
            case .begin:
                beginGesture(g, buttons: buttons)
                return
            case .tapInstead(let tap):
                action = tap   // a combo with the primary button, or gestures can't work: the tap, now
            case .ignore, .notGesture:
                for b in buttons where !(gestures.hold?.buttons.contains(Int(b)) ?? false) { overrides[b] = .swallow }
                return
            }
        }
        if beginMode(action, buttons: pressedButtons.map(\.button)) { return }
        if case .holdShortcut(let shortcut) = action {
            // Keep Flow's shortcut down until a button in the chord is released.
            let alreadyHeld = holding(shortcut)
            for p in pressedButtons { overrides[p.button] = .heldShortcut(shortcut) }
            if !alreadyHeld { io.keys { self.sendDown(shortcut) } }
        } else {
            for p in pressedButtons { overrides[p.button] = .swallow }   // their releases are ours too
            fireLater(action)
        }
    }

    /// Posts an event we decided to pass, behind events we've already posted.
    private func postInOrder(_ result: Unmanaged<CGEvent>?) {
        guard let e = result?.takeUnretainedValue().copy() else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        noteAtPost(e)
        io.post(e, tap: .cgSessionEventTap)
    }

    /// Not a combo after all: replay the held presses as normal presses.
    private func flushPending() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        let presses = pending
        pending = []
        for p in presses {
            guard let out = press(p.event, button: p.button) else { continue }
            let e = out.takeUnretainedValue()
            if let loc = io.cursorLocation() { e.location = loc }
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            noteAtPost(e)
            io.post(e, tap: .cgSessionEventTap)
        }
    }

    /// Applies a single button's mapping to its press.
    private func press(_ event: CGEvent, button: Int64) -> Unmanaged<CGEvent>? {
        // Paused (a press replayed after a combo wait): just the press itself.
        guard config.enabled else { return passReal(event, button: button) }
        if dragLocked, isLeftPress(event, button) {
            endDragLock()
            overrides[button] = .swallow
            return nil
        }
        // Keep the primary click available even if a stale preference says
        // otherwise, so Glide can never make the mouse unusable.
        if button == 0 { return passReal(event, button: 0) }
        return pressAction(config.buttons[Int(button)] ?? .system, event, button: button)
    }

    /// A press that reaches apps as itself. If another trackball button is remapped to this
    /// one and held, apps already see it down: that remap lets go first (its release then does
    /// nothing), so apps never see one button go down twice. The primary button always gets
    /// through this way. Found by scripts/engine-fuzz.
    private func passReal(_ event: CGEvent, button: Int64) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard appButtons.contains(button) else { return pass }
        var yielded = false
        for (other, o) in overrides where other != button {
            if case .remap(let target, let flags) = o, target == button {
                if !yielded { postButton(button, down: false, flags: flags, tap: .cgSessionEventTap) }
                yielded = true
                overrides[other] = .swallow
            }
        }
        guard yielded else { return pass }   // held by another mouse: that's macOS's to sort out
        postInOrder(pass)                    // behind the release just posted
        return nil
    }

    /// Does `action` for a press of `button` (never the primary button).
    private func pressAction(_ action: ButtonAction, _ event: CGEvent, button: Int64) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let target: Int64
        if beginMode(action, buttons: [button]) { return nil }
        switch action {
        case .system: return passReal(event, button: button)
        case .leftClick: target = 0
        case .rightClick: target = 1
        case .middleClick: target = 2
        case .back: target = 3
        case .forward: target = 4
        case .disabled:
            overrides[button] = .swallow
            return nil
        case .shortcut(let shortcut):
            overrides[button] = .swallow
            io.keys { self.send(shortcut) }
            return nil
        case .holdShortcut(let shortcut):
            let alreadyHeld = holding(shortcut)
            overrides[button] = .heldShortcut(shortcut)
            if !alreadyHeld { io.keys { self.sendDown(shortcut) } }   // another button holds it: this one joins
            return nil
        case .media, .openApp:
            overrides[button] = .swallow
            fireLater(action)
            return nil
        case .modifiedClick(let b, let mods):
            let flags = CGEventFlags(rawValue: mods)
            if Int64(b) != button, appButtons.contains(Int64(b)) {   // already down for apps
                overrides[button] = .swallow
                return nil
            }
            overrides[button] = .remap(Int64(b), flags)
            Self.retarget(event, to: Int64(b), .down)
            event.flags = event.flags.union(flags)
            // Its own button with a modifier: like a plain press, another button remapped to
            // it lets go first.
            return Int64(b) == button ? passReal(event, button: button) : pass
        case .precisionHold, .precisionToggle, .ballScrollHold, .dragLock:
            return nil   // handled by `beginMode`
        case .gesture(let g):
            switch gestureRoute(action, buttons: [button]) {
            case .begin:
                beginGesture(g, buttons: [button])
                return nil
            case .tapInstead(let tap):
                return pressAction(tap, event, button: button)   // `tapAction` is never a gesture
            case .ignore:
                // Another gesture is held. A repeat press of the held button itself (its
                // release was lost) keeps the hold's override, so its next release still ends it.
                if !(gestures.hold?.buttons.contains(Int(button)) ?? false) { overrides[button] = .swallow }
                return nil
            case .notGesture:
                return passReal(event, button: button)
            }
        }
        if target == button { return passReal(event, button: button) }
        if appButtons.contains(target) {
            // Apps already see that button down (another button or mouse holds it): a second
            // press would be a double press. This press and its release do nothing.
            overrides[button] = .swallow
            return nil
        }
        overrides[button] = .remap(target, [])
        Self.retarget(event, to: target, .down)
        return pass
    }

    // MARK: Precision, Scroll with ball, Drag lock

    private var precisionActive: Bool { config.enabled && (precisionHeld || precisionToggled) }

    /// Starts one of Glide's stateful actions for a press of `buttons` (one
    /// button, or a combo). Returns false for every other action.
    private func beginMode(_ action: ButtonAction, buttons: [Int64]) -> Bool {
        switch action {
        case .precisionHold:
            for b in buttons { overrides[b] = .precision }
            precisionHeld = true
            applyPointer()   // now, on this thread: the very next movement is slow
            startHoldFailsafe()
        case .precisionToggle:
            for b in buttons { overrides[b] = .swallow }
            precisionToggled.toggle()
            precisionManual = false
            applyPointer()
        case .ballScrollHold:
            for b in buttons { overrides[b] = .ballScroll }
            beginBallScroll(latched: false)
        case .dragLock:
            if dragLocked {
                for b in buttons { overrides[b] = .swallow }
                endDragLock()
            } else {
                for b in buttons { overrides[b] = .dragButton }
                beginDragLock(manual: false)
            }
        default:
            return false
        }
        diagnostics.record("mode \(action) on \(buttons)")   // not `title`: the log stays in English
        publishModes()
        return true
    }

    private func endPrecisionHold() {
        precisionHeld = false
        for (b, o) in overrides {
            if case .precision = o { overrides[b] = .swallow }   // a combo's other buttons
        }
        applyPointer()
        publishModes()
    }

    /// Starts a hold (button down) or a latch (keyboard). The ball scrolls
    /// while either is on; only the hold is watched by the failsafe.
    private func beginBallScroll(latched: Bool) {
        if latched {
            ballScrollLatched = true
        } else {
            ballScrollHeld = true
            startHoldFailsafe()
        }
        guard !ballScrolling else { return }
        ballScrolling = true
        // Ball forward counts as "wheel up"; with natural scrolling the page follows the ball.
        ballSign = io.naturalScrolling ? 1 : -1
        syncFreeze()   // the cursor stays put
        scroller.beginBall()
    }

    /// The cursor is frozen while Scroll with ball or a gesture hold has it, and only then.
    ///
    /// Swallowing the held button's drags at the tap never stopped the cursor: WindowServer has
    /// moved it before a session tap sees the event. Dissociating the pointer from the mouse
    /// (`CGAssociateMouseAndMouseCursorPosition`) only held it with Glideball in front (beta 13),
    /// and made macOS report the frozen spot as the pointer's location, so the put-back below
    /// never acted (beta 16). The pointer is held at its `anchor` only by putting it back
    /// (`holdPointer`), in any app: whenever the trackball's own movement moved it, and again
    /// every `holdRenewInterval` while the ball keeps reporting, since macOS ignores the mice's
    /// movement for a moment after each put-back (`EngineIO.freezePointer`), which is what keeps
    /// it dead still. Ends with the freeze, so it can never outlive the hold.
    private func syncFreeze() {
        let frozen = ballScrolling || gestureFrozen
        if frozen, anchor == nil {
            anchor = io.cursorLocation()
            otherMovedSinceAnchor = false
            anchorBeforeFollow = nil
            holdStats = HoldStats()
            lastHoldWarp = -1
        } else if !frozen {
            if anchor != nil { logHoldStats() }
            anchor = nil
            holdRecheck?.invalidate()
            holdRecheck = nil
        }
        let began = frozen && lastHoldWarp < 0
        io.freezePointer(frozen)
        syncMoveTap()
        if began { holdPointer(renew: true) }   // macOS starts ignoring the ball before it first moves
    }

    // The system-wide hold. Input thread only.
    private var anchor: CGPoint?                     // where the pointer stays while frozen
    private var otherMovedSinceAnchor = false        // another mouse moved the pointer while it's held
    private var lastKMotion: CFTimeInterval = -1     // the trackball's ball moved (HID)
    private var lastMotionWasTrackball = false       // the latest HID movement was the trackball's, not
                                                     // another mouse's (the trackpad never shows up here)
    private var otherMoveAt: CFTimeInterval = -1     // another device's movement that counted as another mouse's
    private var otherMoveKey = 0                     // ...and which device it was
    private var anchorBeforeFollow: CGPoint?         // where the hold was before it last followed another mouse
    private var followAt: CFTimeInterval = -1        // ...and when it followed
    private var sharedMotionAt: CFTimeInterval = -1  // another device moved with the trackball (counted as its)
    private var holdRecheck: EngineTimer?            // looks again just after the trackball's reports
    private var lastHoldWarp: CFTimeInterval = -1    // the pointer was last put on its anchor (this hold)

    /// Movement from another device this close to one of the trackball's reports (before or
    /// after) is the trackball's: a driver re-publishing the ball's movement as a pointer of its
    /// own, say. Only a different device moving while the trackball hasn't reported for this long
    /// is "another mouse" that the hold follows. (Levi, betas 16 and 17: every hold logged
    /// "0 warps … furthest 0 pt" while the pointer moved with the ball.)
    static let echoWindow = 0.03

    /// What one hold saw, for the log (the hold can't be watched on real hardware any other way).
    private struct HoldStats {
        var hidMoves = 0, tapMoves = 0, tapDrags = 0, warps = 0, failedWarps = 0, rechecks = 0
        /// Put on its anchor again while already there, to keep macOS ignoring the ball.
        var renewals = 0
        var maxOffset = 0.0
        /// Times the hold moved to follow another mouse, by device key; and how many of those
        /// the trackball reported within `echoWindow` of, so they were put back.
        var follows: [Int: Int] = [:], followsUndone = 0
        /// Other devices' movement counted as the trackball's (`echoWindow`, or a known echo device), by key.
        var echoes: [Int: Int] = [:]
        /// A trackball move event said the pointer had moved while macOS's location said it hadn't,
        /// and times macOS gave no location at all.
        var queryLagged = 0, noLocation = 0
    }
    private var holdStats = HoldStats()

    private func logHoldStats() {
        let s = holdStats
        guard s.hidMoves > 0 || s.tapMoves > 0 || s.tapDrags > 0 || !s.follows.isEmpty else { return }
        func byKey(_ d: [Int: Int]) -> String {
            d.isEmpty ? "" : " (" + d.sorted { $0.key < $1.key }.map { "\(Self.describe($0.key)) ×\($0.value)" }.joined(separator: ", ") + ")"
        }
        diagnostics.record(String(format: "pointer hold: %d ball reports, tap saw %d moves %d drags, %d warps (%d failed, %d on a recheck), kept still %d times, furthest %.0f pt",
                                  s.hidMoves, s.tapMoves, s.tapDrags, s.warps, s.failedWarps, s.rechecks, s.renewals, s.maxOffset)
                           + "; followed another mouse \(s.follows.values.reduce(0, +)) times\(byKey(s.follows))"
                           + (s.followsUndone > 0 ? ", \(s.followsUndone) put back (the trackball reported with it)" : "")
                           + "; other devices' movement counted as the trackball's \(s.echoes.values.reduce(0, +)) times\(byKey(s.echoes))"
                           + "; macOS's location behind the move event \(s.queryLagged) times, missing \(s.noLocation) times")
    }

    /// The latest movement came from the trackball (its HID report, just now), not another mouse.
    private var trackballMoving: Bool {
        hid && lastMotionWasTrackball && io.now() - lastKMotion < 0.25
    }

    /// The trackball's ball moved (HID). Another device's movement just before it was this
    /// movement too (an echo that arrived first): it no longer counts as another mouse's, and
    /// if the hold already followed it, the hold goes back to where it was.
    private func trackballMoved(_ now: CFTimeInterval) {
        if now - otherMoveAt < Self.echoWindow {
            if otherMovedSinceAnchor {
                otherMovedSinceAnchor = false
                if anchor != nil { holdStats.echoes[otherMoveKey, default: 0] += 1 }
            }
            if !echoDevices.contains(otherMoveKey) { sharedMotionAt = otherMoveAt }
            if let before = anchorBeforeFollow, anchor != nil, now - followAt < Self.echoWindow {
                anchor = before
                holdStats.followsUndone += 1
            }
            otherMoveAt = -1
        }
        anchorBeforeFollow = nil
        lastKMotion = now
        lastMotionWasTrackball = true
    }

    /// Another device's X or Y moved (HID). It's another mouse only if it isn't the trackball's own
    /// driver and the trackball hasn't reported within `echoWindow`; a report from the trackball
    /// within `echoWindow` after it takes it back (`trackballMoved`).
    private func otherDeviceMoved(_ k: Int) {
        let now = io.now()
        if echoDevices.contains(k) || now - lastKMotion < Self.echoWindow {
            if anchor != nil { holdStats.echoes[k, default: 0] += 1 }
            if !echoDevices.contains(k) { sharedMotionAt = now }
            return
        }
        lastMotionWasTrackball = false
        otherMoveAt = now
        otherMoveKey = k
        if anchor != nil { otherMovedSinceAnchor = true }
    }

    /// The hold moves to where another mouse put the pointer.
    private func follow(to p: CGPoint) {
        let now = io.now()
        if anchorBeforeFollow == nil || now - followAt >= Self.echoWindow { anchorBeforeFollow = anchor }
        followAt = now
        anchor = p
        otherMovedSinceAnchor = false
        holdStats.follows[otherMoveKey, default: 0] += 1
    }

    /// Puts the pointer back on its anchor if the trackball moved it. Another mouse moving
    /// in the meantime moves the anchor with it (its movement is the person's, not the ball's).
    /// `seen` is the location on the trackball's move event, when there is one: where WindowServer
    /// put the pointer for that move. The pointer is put back if either it or macOS's answer for the
    /// pointer's location is off the anchor, so the hold doesn't hang on one of them being current.
    /// `renew`: the ball just reported (or the hold just began), so the pointer is put on its
    /// anchor even if it's there already, once the last put-back is `holdRenewInterval` old:
    /// macOS then goes on ignoring the ball, and the pointer never leaves the anchor at all.
    /// True if the pointer was off its anchor.
    @discardableResult
    private func holdPointer(seen: CGPoint? = nil, renew: Bool = false) -> Bool {
        guard let a = anchor, let tap, io.tapIsEnabled(tap) else { return false }   // no tap: never fight the pointer
        let asked = io.cursorLocation()
        if asked == nil { holdStats.noLocation += 1 }
        if otherMovedSinceAnchor {
            if let p = seen ?? asked { follow(to: p) }
            return false
        }
        func off(_ p: CGPoint?) -> Double { p.map { Double(max(abs($0.x - a.x), abs($0.y - a.y))) } ?? 0 }
        let bySeen = off(seen), byAsked = off(asked)
        if bySeen > 0.5, byAsked <= 0.5 { holdStats.queryLagged += 1 }
        let offset = max(bySeen, byAsked)
        let now = io.now()
        guard offset > 0.5 || (renew && now - lastHoldWarp >= Self.holdRenewInterval) else { return false }
        lastHoldWarp = now
        if offset > 0.5 {
            holdStats.maxOffset = max(holdStats.maxOffset, offset)
            holdStats.warps += 1
        } else {
            holdStats.renewals += 1
        }
        if !io.warpPointer(a) { holdStats.failedWarps += 1 }
        return offset > 0.5
    }
    /// Well inside `EngineIO.holdSuppression`, so a late report never finds it run out.
    static let holdRenewInterval = 0.03

    /// Another mouse's move reached the tap (its HID report was the latest): the pointer is where
    /// that mouse put it, so the hold stays there. Done here, as the move lands, rather than at
    /// the trackball's next report, which may already have moved the pointer too.
    private func followOtherMouse(at seen: CGPoint?) {
        guard anchor != nil, otherMovedSinceAnchor, !lastMotionWasTrackball, let p = seen ?? io.cursorLocation() else { return }
        follow(to: p)
    }

    /// The trackball's own HID report while the pointer is held. That report usually reaches
    /// the engine before WindowServer has moved the pointer for it, so a look right now finds
    /// nothing to put back, and the move's tap event can't be counted on to follow (a held
    /// button whose press apps never saw can make macOS send it as a plain move or not at all;
    /// Kensington's own driver may deliver it later still). So the engine also looks again a
    /// few milliseconds after each report, every 4 ms until the ball has been still for 16 ms:
    /// the hold no longer depends on seeing a single move event. (Levi, beta 14 on an Expert
    /// Mouse with KensingtonWorks' driver: the gesture fired but the pointer moved the whole time.)
    private func holdForBallReport() {
        guard anchor != nil else { return }
        holdStats.hidMoves += 1
        holdPointer(renew: true)
        guard holdRecheck == nil else { return }
        holdRecheck = io.schedule(Self.holdRecheckInterval, repeats: true) { [unowned self] in
            guard self.anchor != nil, self.io.now() - self.lastKMotion < 0.016 else {
                self.holdRecheck?.invalidate()
                self.holdRecheck = nil
                return
            }
            if self.holdPointer() { self.holdStats.rechecks += 1 }
        }
    }
    static let holdRecheckInterval = 0.004

    /// The plain-move tap is on while a Drag lock needs its moves turned into drags, or while
    /// the pointer is held (a keyboard Scroll with ball has no button down, so no drags).
    private func syncMoveTap() {
        if dragLocked || anchor != nil { installMoveTap() } else { removeMoveTap() }
    }

    /// Ends the hold (or the latch). The ball stops scrolling once neither is left.
    private func endBallScroll(latched: Bool, glide: Bool) {
        if latched {
            ballScrollLatched = false
        } else {
            ballScrollHeld = false
            for (b, o) in overrides {
                if case .ballScroll = o { overrides[b] = .swallow }   // a combo's other buttons
            }
        }
        guard !ballScrollHeld, !ballScrollLatched else { return }
        let wasScrolling = ballScrolling
        ballScrolling = false
        syncFreeze()   // free, unless a gesture hold still has it
        guard wasScrolling else { return }
        scroller.endBall(glide: glide)
        publishModes()
    }

    private func beginDragLock(manual: Bool) {
        // The left button is already down (held on this or another mouse): a second press
        // would reach apps as a double press, and its release would leave the lock holding
        // nothing. Found by scripts/engine-fuzz. The lock just doesn't start.
        guard !leftDown else {
            diagnostics.record("drag lock not started: the left button is already down")
            return
        }
        dragLocked = true
        dragLockManual = manual
        postButton(0, down: true)
        syncMoveTap()
    }

    private func endDragLock() {
        guard dragLocked else { return }
        dragLocked = false
        dragLockManual = false
        syncMoveTap()
        postButton(0, down: false)
        for (b, o) in overrides {
            if case .dragButton = o { overrides[b] = .swallow }
        }
        publishModes()
    }

    /// Would this press of the trackball's reach apps as a left click?
    private func isLeftPress(_ event: CGEvent, _ button: Int64) -> Bool {
        if event.type == .leftMouseDown || button == 0 { return true }
        guard config.enabled else { return false }
        switch config.buttons[Int(button)] {
        case .leftClick?: return true
        case .modifiedClick(let b, _)?: return b == 0
        default: return false
        }
    }

    private func inDragLockCombo(_ button: Int64) -> Bool {
        config.enabled
            && config.chords.contains { $0.action == .dragLock && $0.buttons.contains(Int(button)) }
    }

    /// Presses or releases `button` at the cursor, marked as Glide's own: a drag lock's
    /// left button, or letting go of a button a held press was remapped to.
    private func postButton(_ button: Int64, down: Bool, flags: CGEventFlags = [],
                            tap: CGEventTapLocation = .cghidEventTap) {
        let loc = io.cursorLocation() ?? .zero
        let type: CGEventType = switch button {
        case 0: down ? .leftMouseDown : .leftMouseUp
        case 1: down ? .rightMouseDown : .rightMouseUp
        default: down ? .otherMouseDown : .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: Self.keySource, mouseType: type, mouseCursorPosition: loc,
                              mouseButton: CGMouseButton(rawValue: UInt32(clamping: button)) ?? .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        if !flags.isEmpty { e.flags = flags }
        noteAtPost(e)
        io.post(e, tap: tap)
    }

    /// A second tap for plain mouse moves, only while a drag lock is on, so
    /// ordinary pointer movement never passes through Glide.
    private func installMoveTap() {
        guard moveTap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)
        guard let (t, source) = io.installTap(mask: mask, engine: self, runLoop: runLoop) else { return }
        moveTap = t
        moveTapSource = source
    }

    private func removeMoveTap() {
        if let moveTap { io.removeTap(moveTap, source: moveTapSource, runLoop: runLoop) }
        moveTap = nil
        moveTapSource = nil
    }

    /// Held modes normally end on their button's release. If that release is
    /// lost (e.g. the tap was briefly off), HID button state ends them: no
    /// Kensington button down for two checks in a row. Without any HID button
    /// reports to go on, a hold ends after 10 s.
    private func startHoldFailsafe() {
        holdStart = io.now()
        holdReleasedChecks = 0
        hidButtonSeen = !hidButtonsDown.isEmpty
        guard holdFailsafe == nil else { return }
        holdFailsafe = io.schedule(0.25, repeats: true) { [unowned self] in self.checkHolds() }
    }

    /// A button is holding a key down, or holds the button its press was remapped to.
    private var heldByButton: Bool {
        overrides.values.contains { o in
            switch o {
            case .heldShortcut, .remap: true
            default: false
            }
        }
    }
    private var heldReleasedChecks: [Int64: Int] = [:]

    /// The failsafe for a key or remapped button whose trigger's release was lost (the
    /// tap was off when it lifted): once the trackball itself has said that button is up
    /// for two checks, let go. Only for trackballs that report their buttons over HID;
    /// otherwise there's nothing to go on, and a long hold (push-to-talk) must keep working.
    private func checkHeldByButton() {
        guard kensingtonReportsButtons else { return }
        for (b, o) in overrides {
            switch o {
            case .heldShortcut, .remap: break
            default: heldReleasedChecks[b] = nil; continue
            }
            if hidButtonsDown.contains(Int(b) + 1) {
                heldReleasedChecks[b] = 0
                continue
            }
            let n = (heldReleasedChecks[b] ?? 0) + 1
            heldReleasedChecks[b] = n
            guard n >= 2, let current = overrides[b] else { continue }
            heldReleasedChecks[b] = nil
            diagnostics.record("held button failsafe: release of button \(b) never arrived")
            switch current {
            case .heldShortcut(let s):
                io.keys { self.sendUp(s) }
                silenceHeld(s)   // a chord's other buttons finish silently
            case .remap(let target, let flags):
                postButton(target, down: false, flags: flags)
                overrides[b] = .swallow
            default: break
            }
        }
    }

    private func checkHolds() {
        checkHeldByButton()
        guard precisionHeld || ballScrollHeld || gestures.isHeld else {   // a keyboard latch is never a lost hold
            guard !(kensingtonReportsButtons && heldByButton) else { return }
            holdFailsafe?.invalidate()
            holdFailsafe = nil
            return
        }
        // A gesture hold never outlasts `GestureTuning.maxHold`, whatever HID says.
        if let h = gestures.hold, io.now() - h.start >= gestures.tuning.maxHold {
            cancelGesture(.timeout)
        }
        let lost: Bool
        if hidButtonSeen {
            holdReleasedChecks = hidButtonsDown.isEmpty ? holdReleasedChecks + 1 : 0
            lost = holdReleasedChecks >= 2
        } else {
            lost = io.now() - holdStart > 10
        }
        guard lost else { return }
        diagnostics.record("hold failsafe: button release never arrived")
        if ballScrollHeld { endBallScroll(latched: false, glide: false) }
        if precisionHeld { endPrecisionHold() }
        cancelGesture(.lostRelease)
    }

    // MARK: Gestures (Gestures.swift decides; this carries it out)

    private func gestureRoute(_ action: ButtonAction, buttons: [Int64]) -> GestureRoute {
        GestureRoute.decide(action: action, buttons: buttons.map { Int($0) }, enabled: config.gesturesEnabled,
                            canReadBall: tap != nil && canReadBall, gestureHeld: gestures.isHeld)
    }

    private func beginGesture(_ gesture: ButtonGesture, buttons: [Int64]) {
        let tuning = GestureTuning.for(distance: gesture.distance ?? config.gestureDistance, steadyHands: config.gestureSteadyHands)
        let effects = gestures.begin(buttons: buttons.map { Int($0) }, gesture: gesture, now: io.now(), tuning: tuning)
        guard !effects.isEmpty else {
            for b in buttons { overrides[b] = .swallow }   // refused: the press and its release do nothing
            return
        }
        for b in buttons { overrides[b] = .gesture }
        diagnostics.record("gesture hold on \(buttons)")
        applyGesture(effects)
        startHoldFailsafe()
    }

    /// Ends a gesture hold that won't get its release (or shouldn't wait for it).
    /// The buttons' releases, when they come, do nothing.
    private func cancelGesture(_ reason: GestureCancel) {
        let effects = gestures.cancel(reason)
        for (b, o) in overrides {
            if case .gesture = o { overrides[b] = .swallow }
        }
        guard !effects.isEmpty else { return }
        diagnostics.record("gesture ended: \(reason.rawValue)")
        applyGesture(effects)
    }

    private func applyGesture(_ effects: [GestureEffect]) {
        for effect in effects {
            switch effect {
            case .freeze(let on):
                gestureFrozen = on
                syncFreeze()
                publishModes()
            case .fire(let action, let direction):
                diagnostics.record("gesture \(direction.rawValue)")
                flashGesture(direction, buttons: gestures.hold?.buttons ?? [], chain: gestures.hold?.fired ?? 1)
                if !practicing { fireLater(action) }
            case .tap(let action, let buttons):
                flashGesture(nil, buttons: buttons)
                if !practicing { performTap(action, buttons: buttons) }
            }
        }
    }

    /// "Try it" is on: a gesture shows what it would do and does nothing else.
    /// It switches itself off after two minutes, so it can never be left on.
    private var practicing: Bool { io.now() < gesturePracticeUntil }

    private func flashGesture(_ direction: GestureDirection?, buttons: [Int], chain: Int = 0) {
        gestureFlash = GestureFlash(seq: (gestureFlash?.seq ?? 0) + 1, direction: direction, buttons: buttons, chain: chain)
        publishModes()
    }

    /// "Try it" on the Buttons page: while on (two minutes at most), gestures show
    /// on screen what they'd do without doing it. Off: they work as usual.
    func setGesturePractice(_ on: Bool) {
        perform {
            self.gesturePracticeUntil = on ? self.io.now() + 120 : 0
            self.publishModes()
        }
    }

    /// A gesture button's tap, after its release.
    private func performTap(_ action: ButtonAction, buttons: [Int]) {
        switch action {
        case .system:
            // The button's own click (a combo has none). Never the primary button.
            guard buttons.count == 1, let b = buttons.first, b != 0 else { return }
            guard !appButtons.contains(Int64(b)) else { return }   // already down for apps: a click would be a second press
            io.keys { self.click(button: Int64(b)) }
        case .precisionToggle:
            precisionToggled.toggle()
            precisionManual = false
            applyPointer()
            publishModes()
        case .dragLock:
            // Like the keyboard's: a click (or another tap) drops it.
            if dragLocked { endDragLock() } else { beginDragLock(manual: true) }
            publishModes()
        case .disabled, .precisionHold, .ballScrollHold, .gesture:
            return
        default:
            fireLater(action)
        }
    }

    /// Ends everything at once (pause, ⌃⌥⌘G, quit, unplug). Input thread.
    private func releaseModes(_ reason: GestureCancel = .pause) {
        cancelModifierWait(silently: true)
        cancelGesture(reason)
        if ballScrolling { scroller.cancelBall() }
        ballScrolling = false
        ballScrollHeld = false
        ballScrollLatched = false
        syncFreeze()   // frees the pointer: nothing holds it now
        scroller.stopAll()   // a flywheel still coasting stops here: nothing scrolls after a pause or unplug
        endDragLock()
        precisionHeld = false
        precisionToggled = false
        precisionManual = false
        for (b, o) in overrides {
            switch o {
            case .precision, .ballScroll, .dragButton: overrides[b] = .swallow   // their releases stay ours
            default: break
            }
        }
        applyPointer()
        publishModes()
    }

    /// A toggled mode whose action is no longer assigned anywhere could never
    /// be switched off again, so end it. Modes switched on from the keyboard
    /// can always be switched off from the menu bar (Precision) or with a
    /// click (Drag lock) — but a keyboard Scroll with ball freezes the cursor,
    /// so it ends as soon as its shortcut is gone.
    private func dropOrphanedModes() {
        guard precisionToggled || dragLocked || ballScrollLatched else { return }
        let assigned = Set(config.buttons.values).union(config.chords.map(\.action))
        if precisionToggled && !precisionManual && !assigned.contains(.precisionToggle) {
            precisionToggled = false
            applyPointer()
        }
        if dragLocked && !dragLockManual && !assigned.contains(.dragLock) { endDragLock() }
        if ballScrollLatched && config.globalShortcuts.ballScroll == nil {
            endBallScroll(latched: true, glide: false)
        }
        publishModes()
    }

    private func publishModes() {
        let m = Modes(precision: precisionActive, ballScrolling: ballScrolling, dragLocked: dragLocked,
                      gestureHeld: gestures.isHeld, gestureButtons: gestures.hold?.buttons ?? [],
                      gestureDirection: gestures.leaning, gestureFlash: gestureFlash,
                      gesturePractice: practicing)
        guard m != modes else { return }
        modes = m
        io.toMain { self.onModes?(m) }
    }


    private static func retarget(_ e: CGEvent, to button: Int64, _ phase: Phase) {
        switch (button, phase) {
        case (0, .down): e.type = .leftMouseDown
        case (0, .up): e.type = .leftMouseUp
        case (0, .drag): e.type = .leftMouseDragged
        case (1, .down): e.type = .rightMouseDown
        case (1, .up): e.type = .rightMouseUp
        case (1, .drag): e.type = .rightMouseDragged
        case (_, .down): e.type = .otherMouseDown
        case (_, .up): e.type = .otherMouseUp
        case (_, .drag): e.type = .otherMouseDragged
        }
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
    }

    /// Fires `action` on the key queue. A click on a button apps already see down would be
    /// a second press of a held button (and its release would let go of the held one), so
    /// it's skipped. So is one on a trackball button that is held and waiting for a combo
    /// partner: its press reaches apps when the wait ends (often at the very next drag), and
    /// this click, still on the key queue, would land after it as a second press. Found by
    /// scripts/engine-fuzz (a gesture firing Back, or a left click, while that button waited).
    /// Input thread.
    private func fireLater(_ action: ButtonAction) {
        if let b = action.clickButton, appButtons.contains(b) || pending.contains(where: { $0.button == b }) {
            diagnostics.record("click on button \(b) skipped: it's already down")
            return
        }
        io.keys { self.fire(action) }
    }

    /// Fires an action that isn't tied to a held button (combos): clicks are a
    /// quick press-and-release at the cursor.
    func fire(_ action: ButtonAction) {
        let button: Int64
        var flags = CGEventFlags()
        switch action {
        case .system, .disabled: return
        case .precisionHold, .precisionToggle, .ballScrollHold, .dragLock: return   // stateful: `beginMode`
        case .gesture: return                                                       // stateful: `beginGesture`
        case .shortcut(let s), .holdShortcut(let s): send(s); return
        case .media(let key): sendMedia(key); return
        case .openApp(let id): io.openApp(id); return
        case .modifiedClick(let b, let mods): button = Int64(b); flags = CGEventFlags(rawValue: mods)
        case .leftClick: button = 0
        case .rightClick: button = 1
        case .middleClick: button = 2
        case .back: button = 3
        case .forward: button = 4
        }
        click(button: button, flags: flags)
    }

    /// A quick press and release of `button` at the cursor, marked as Glide's own.
    func click(button: Int64, flags: CGEventFlags = []) {
        let loc = io.cursorLocation() ?? .zero
        let cgButton = CGMouseButton(rawValue: UInt32(clamping: button)) ?? .center
        for down in [true, false] {
            let type: CGEventType = switch button {
            case 0: down ? .leftMouseDown : .leftMouseUp
            case 1: down ? .rightMouseDown : .rightMouseUp
            default: down ? .otherMouseDown : .otherMouseUp
            }
            guard let e = CGEvent(mouseEventSource: Self.keySource, mouseType: type, mouseCursorPosition: loc, mouseButton: cgButton) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            e.flags = flags
            io.post(e, tap: .cghidEventTap)
        }
    }

    private static let keySource = CGEventSource(stateID: .hidSystemState)
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    func send(_ s: KeyShortcut) {
        sendDown(s)
        sendUp(s)
    }

    /// A media key press and release, as the keyboard's own media keys send them
    /// (a system-defined event, subtype 8, with the key and its state in data1).
    func sendMedia(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let data1 = (key.rawValue << 16) | (state << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 subtype: 8, data1: data1, data2: -1),
                  let cg = event.cgEvent else { continue }
            cg.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            io.post(cg, tap: .cghidEventTap)
        }
    }

    func sendDown(_ s: KeyShortcut) {
        postModifiers(for: s.flags, down: true)
        postKey(s, down: true)
    }

    func sendUp(_ s: KeyShortcut) {
        postKey(s, down: false)
        postModifiers(for: s.flags, down: false)
    }

    /// Some global-hotkey apps (including Flow) require a real modifier-key
    /// event, rather than merely seeing the modifier bit on the Space event.
    private static let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
        (.maskControl, CGKeyCode(kVK_Control)),
        (.maskAlternate, CGKeyCode(kVK_Option)),
        (.maskShift, CGKeyCode(kVK_Shift)),
        (.maskCommand, CGKeyCode(kVK_Command)),
    ]

    private func postModifiers(for flags: CGEventFlags, down: Bool) {
        let keys = down ? Self.modifierKeys : Array(Self.modifierKeys.reversed())
        for modifier in keys where flags.contains(modifier.flag) {
            guard let e = CGEvent(keyboardEventSource: Self.keySource, virtualKey: modifier.key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            io.post(e, tap: .cghidEventTap)
        }
    }

    private func postKey(_ s: KeyShortcut, down: Bool) {
        var flags = s.flags
        // Real arrow-key presses carry these flags; Spaces switching expects them.
        if Self.arrowKeys.contains(s.keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        guard let e = CGEvent(keyboardEventSource: Self.keySource, virtualKey: s.keyCode, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        io.post(e, tap: .cghidEventTap)
    }
}

/// The event tap's callback: hands each event to the engine it was made for.
func glideTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

extension ButtonAction {
    /// The button a click action presses, if it's a click.
    var clickButton: Int64? {
        switch self {
        case .leftClick: 0
        case .rightClick: 1
        case .middleClick: 2
        case .back: 3
        case .forward: 4
        case .modifiedClick(let b, _): Int64(b)
        default: nil
        }
    }
}
