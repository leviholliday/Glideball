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
    private var appButtons = Set<Int64>()
    private var leftDown: Bool { appButtons.contains(0) }   // Precision keeps drags drags
    // Held modes end if their button's release is ever lost (see `checkHolds`).
    private var hidButtonsDown = Set<Int>()    // Kensington buttons physically down, per HID
    private var hidButtonDownAt: [Int: CFTimeInterval] = [:]   // when each last went down
    private var kensingtonReportsButtons = false   // its buttons reach us over HID at all
    private var hidButtonSeen = false          // HID has shown a press since the hold began
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
            self.deviceSupported = self.devices.mapValues { $0.isSupported(beta: on) }
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
        appButtons = io.buttonsDown()   // a button held while Glideball (re)launches
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
        publish()
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

    static func key(_ device: IOHIDDevice) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
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
        deviceAdded(key: Self.key(device), identity: Self.identity(of: device),
                    transport: DeviceBattery.transport(device), device: device)
    }

    /// A pointing device appeared. `device` is nil in scripts/engine-fuzz.
    func deviceAdded(key k: Int, identity: DeviceIdentity, transport: String?, device: IOHIDDevice?) {
        devices[k] = nil
        deviceSupported[k] = nil
        hidBattery[k] = nil
        registryBattery[k] = nil
        transports[k] = transport
        if identity.vendorID == DeviceIdentity.kensingtonVendorID {
            batteryDevices.insert(k)   // only Kensington's, for the battery check
            io.rememberDevice(k, device)
        }
        if isSupported(key: k, identity: { identity }) {
            io.pointerDevicesChanged()
            // The HID service appears slightly after the device; apply twice to be sure.
            for delay in [0.3, 1.5] {
                _ = io.schedule(delay, repeats: false) { [unowned self] in
                    self.applyPointer()
                    if delay > 1 { self.refreshBatteries() }   // registry properties can arrive late too
                }
            }
        }
        syncTap()
        publish()
    }

    /// IOHIDManager's callback (input thread): that device, then a check of the rest
    /// against what IOHIDManager has (a removal can go missing, say across a USB hub reset).
    func deviceRemoved(_ device: IOHIDDevice) { deviceRemovedByManager(key: Self.key(device)) }

    /// What the removal callback does (scripts/engine-fuzz calls this directly).
    func deviceRemovedByManager(key k: Int) {
        deviceRemoved(key: k)
        reconcileNow()
    }

    /// Wake, screen unlock, the window opening: make the devices Glideball knows match
    /// the ones IOHIDManager has now. A removal callback that never came would
    /// otherwise leave "Connected" showing (and the tap on) until a relaunch. Cheap: one
    /// IOHIDManagerCopyDevices, no timer.
    func reconcileDevices() { perform { self.reconcileNow() } }

    private func reconcileNow() {
        guard let live = io.liveDevices() else { return }   // not listening: nothing to compare with
        var changed = false
        for k in Array(devices.keys) where live[k] == nil || live[k]?.identity != devices[k] {
            diagnostics.record("device check: a device left without a removal")
            deviceRemoved(key: k)   // its releases, exactly as an unplug
            changed = true
        }
        for (k, d) in live.sorted(by: { $0.key < $1.key }) where devices[k] == nil {
            diagnostics.record("device check: a device arrived without an add")
            deviceAdded(key: k, identity: d.identity, transport: d.transport, device: d.device)
            changed = true
        }
        if changed { publish() }
    }

    func deviceRemoved(key k: Int) {
        if deviceSupported[k] == true {
            // Unplugged mid-hold: its button releases will never come.
            hidButtonsDown.removeAll()
            releaseModes(.unplug)
            letGoOfHeld()   // keys a held button had down, and buttons it was remapped to
            // Presses still waiting to see if they're a combo: never replay them now, their
            // releases will never come. Found by scripts/engine-fuzz.
            pendingTimer?.invalidate()
            pendingTimer = nil
            for p in pending { overrides[p.button] = .swallow }
            pending = []
        }
        devices[k] = nil
        deviceSupported[k] = nil
        batteryDevices.remove(k)
        io.forgetDevice(k)
        transports[k] = nil
        hidBattery[k] = nil
        registryBattery[k] = nil
        // No trackball left: its presses' overrides would otherwise outlive it and catch
        // another mouse's release of the same button (swallowed: stuck down). Found by
        // scripts/engine-fuzz. Whatever they held was let go of above.
        if !deviceSupported.values.contains(true) { overrides.removeAll() }
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
        hidInput(key: Self.key(device), identity: Self.identity(of: device),
                 page: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)),
                 value: IOHIDValueGetIntegerValue(value), stamp: IOHIDValueGetTimeStamp(value),
                 logicalMin: IOHIDElementGetLogicalMin(element), logicalMax: IOHIDElementGetLogicalMax(element))
    }

    /// One HID value from device `k` (scripts/engine-fuzz calls this directly).
    func hidInput(key k: Int, identity: @autoclosure () -> DeviceIdentity, page: Int, usage: Int, value v: Int,
                  stamp: UInt64, logicalMin: Int = 0, logicalMax: Int = 100) {
        // Only devices that arrived (deviceAdded) count. A value delivered after its
        // device's removal used to re-add it here as supported, so "Connected" stayed
        // on after an unplug until a relaunch.
        guard devices[k] != nil else { return }
        let isK = isSupported(key: k, identity: identity)
        lastActiveIsKensington = isK
        guard isK else { return }

        // The same hardware report can reach us twice (one device, two
        // matches). Each report has one hardware timestamp, so skip repeats.
        let usageKey = page << 16 | usage
        if lastValueStamp[usageKey] == stamp { return }
        lastValueStamp[usageKey] = stamp

        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X):
            telemetry.addBall(dx: v, dy: 0)
            let now = io.now()
            // A held gesture takes the ball (even over Scroll with ball): see GestureRoute.
            if gestures.isHeld { applyGesture(gestures.ball(dx: Double(v), dy: 0, now: now)); publishModes() }
            else if ballScrolling { scroller.addBallDelta(dx: Double(v) * ballSign, dy: 0) }
            watchDisplay(now: now)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            telemetry.addBall(dx: 0, dy: v)
            let now = io.now()
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
                hidButtonsDown.insert(b)
                hidButtonDownAt[b] = io.now()
                kensingtonReportsButtons = true
                hidButtonSeen = true
            } else {
                hidButtonsDown.remove(b)
            }
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
        if wanted { appButtons = io.buttonsDown() }
    }

    /// The device that produced the most recent raw input. Without Input
    /// Monitoring we can't tell devices apart, so we leave everything alone.
    private var fromKensington: Bool { hid && lastActiveIsKensington }

    /// Did this click come from the Kensington? "Last active device" isn't enough
    /// for buttons: a built-in trackpad's clicks never reach IOHIDManager, so a
    /// trackpad right-click right after using the trackball would look like the
    /// trackball's. A press only counts when the trackball itself reported that
    /// button going down (HID usage n+1 = CG button n), just now.
    private func isKensingtonPress(_ button: Int64) -> Bool {
        guard hid else { return false }
        let b = Int(button) + 1
        if hidButtonsDown.contains(b) { return true }
        if let t = hidButtonDownAt[b], io.now() - t < 0.3 { return true }
        if lastActiveIsKensington && kensingtonReportsButtons {
            diagnostics.record("press of button \(button) not reported by the trackball: passed through")
        }
        // A device whose buttons never arrive over HID: fall back to the last active device.
        return !kensingtonReportsButtons && lastActiveIsKensington
    }

    /// The event tap's callback (scripts/engine-fuzz calls it directly).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let out = route(type, event)
        if let e = out?.takeUnretainedValue() { noteOut(e) }
        return out
    }

    /// Keeps `appButtons` up to date with a button event on its way to apps: one the tap
    /// passes, or one posted from the input thread (noted at once, so a decision made before
    /// it comes back through the tap already knows). Input thread.
    private func noteOut(_ e: CGEvent) {
        switch e.type {
        case .leftMouseDown: appButtons.insert(0)
        case .leftMouseUp: appButtons.remove(0)
        case .rightMouseDown, .otherMouseDown: appButtons.insert(e.getIntegerValueField(.mouseEventButtonNumber))
        case .rightMouseUp, .otherMouseUp: appButtons.remove(e.getIntegerValueField(.mouseEventButtonNumber))
        default: break
        }
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A gesture's release may have gone by while the tap was off: free the pointer now.
            cancelGesture(.tapDisabled)
            appButtons = io.buttonsDown()   // what went by while it was off
            syncTap()
            if let moveTap { io.tapEnable(moveTap, true) }
            // So may the release of a button holding a key or remapped to another button:
            // the failsafe lets go of them once the trackball says the button is up.
            if heldByButton { startHoldFailsafe() }
            return pass
        case _ where event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag:
            return pass   // our own events
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
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return handleButton(event, .drag)
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

    private func handleButton(_ event: CGEvent, _ phase: Phase) -> Unmanaged<CGEvent>? {
        // A press of a button that is still waiting for a combo partner, or still has an
        // override: its release was lost, or another mouse pressed the same button number.
        // The old press goes through (or lets go of what it holds) first, so this one can
        // never leave a key or a button stuck; this press is then posted behind that, so
        // apps see them in order. Found by scripts/engine-fuzz.
        if phase == .down {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            var posted = false
            if pending.contains(where: { $0.button == button }) { flushPending(); posted = true }
            if overrides[button] != nil, releaseOverride(button) { posted = true }
            if posted {
                postInOrder(routeButton(event, phase))
                return nil
            }
        }
        return routeButton(event, phase)
    }

    private func routeButton(_ event: CGEvent, _ phase: Phase) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        // Any other press during a gesture hold means the release isn't a tap.
        if phase == .down, gestures.isHeld { gestures.otherPress(Int(button)) }

        // Drag lock: any click (from any mouse) lets go — and that's all it does.
        // (A press that may be the start of a Drag lock combo waits for the
        // combo; if it turns out to be a lone click, `press` lets go instead.)
        if dragLocked, phase == .down, isLeftPress(event, button), !inDragLockCombo(button) {
            endDragLock()
            overrides[button] = .swallow
            return nil
        }

        if let handler = learnHandler, (phase == .down && isKensingtonPress(button)) || learnHeld.contains(Int(button)) {
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
        if phase != .down, pending.contains(where: { $0.button == button }) {
            flushPending()
            postInOrder(handleButton(event, phase))
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
        if phase == .up, button != 0, overrides.values.contains(where: { if case .remap(let t, _) = $0 { t == button } else { false } }) {
            // A release whose press this engine never saw (held through a relaunch, or while
            // the tap was off) of a button another button is remapped to and holding: passing
            // it would let go of that hold. Found by scripts/engine-fuzz.
            return nil
        }
        guard phase == .down else { return pass }
        // Another mouse's press, or Glideball paused: untouched (though a trackball button
        // remapped to the same button lets go first, so apps never see it go down twice).
        guard config.enabled, isKensingtonPress(button) else { return passReal(event, button: button) }

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
        noteOut(e)
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
            noteOut(e)
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
    private func syncFreeze() {
        io.freezePointer(ballScrolling || gestureFrozen)
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
        installMoveTap()
    }

    private func endDragLock() {
        guard dragLocked else { return }
        dragLocked = false
        dragLockManual = false
        removeMoveTap()
        postButton(0, down: false)
        for (b, o) in overrides {
            if case .dragButton = o { overrides[b] = .swallow }
        }
        publishModes()
    }

    /// Would this press reach apps as a left click?
    private func isLeftPress(_ event: CGEvent, _ button: Int64) -> Bool {
        if event.type == .leftMouseDown || button == 0 { return true }
        guard config.enabled, isKensingtonPress(button) else { return false }
        switch config.buttons[Int(button)] {
        case .leftClick?: return true
        case .modifiedClick(let b, _)?: return b == 0
        default: return false
        }
    }

    private func inDragLockCombo(_ button: Int64) -> Bool {
        config.enabled && isKensingtonPress(button)
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
        noteOut(e)
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
        io.freezePointer(false)
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
    /// it's skipped. Input thread.
    private func fireLater(_ action: ButtonAction) {
        if let b = action.clickButton, appButtons.contains(b) {
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
