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
        /// That device is a Kensington Glide only supports in the Beta program.
        var deviceIsBeta = false
        /// A connected Kensington pointing device Glide leaves alone unless the Beta program is on.
        var unsupportedDeviceName: String?
    }

    /// Glide's own button modes that are currently on, for the UI.
    struct Modes: Equatable {
        var precision = false
        var ballScrolling = false
        var dragLocked = false
    }

    let telemetry = Telemetry()
    var onStatus: ((Status) -> Void)?          // delivered on main
    var onModes: ((Modes) -> Void)?            // delivered on main

    private var config: GlideConfig
    private var runLoop: CFRunLoop!
    private var foundationRunLoop: RunLoop!
    private var tap: CFMachPort?
    private var hid: IOHIDManager?
    private var devices: [Int: DeviceIdentity] = [:]   // connected pointing devices
    private var deviceSupported: [Int: Bool] = [:]     // …that Glide works with (see DeviceIdentity)
    private var betaProgram = BetaProgram.isEnabled
    private var lastActiveIsKensington = false
    private var lastValueStamp: [Int: UInt64] = [:]
    private var status = Status()

    private enum Override {
        case swallow, remap(Int64, CGEventFlags), heldShortcut(KeyShortcut)
        case precision    // a Precision (hold) button: slow until it lifts
        case ballScroll   // a Scroll-with-ball button: the ball scrolls until it lifts
        case dragButton   // the press that started a drag lock
    }
    private enum Phase { case down, up, drag }
    private var overrides: [Int64: Override] = [:]

    private let scroller = SmoothScroller()
    let diagnostics = Diagnostics()

    // Scroll input comes straight from the ring's raw HID ticks once we've seen
    // one; the driver's own scroll events are then only used to learn direction.
    private var hidWheelSeen = false
    private var lastHIDWheel: (value: Int, time: CFTimeInterval) = (0, 0)
    // HID wheel reports carry no keyboard modifiers. Keep the physical keyboard
    // state from the event tap so Shift can reliably redirect the raw ring.
    private var modifierFlags = CGEventSource.flagsState(.hidSystemState)
    /// Raw HID wheel sign → macOS scroll sign (accounts for natural scrolling).
    private var directionFactor: Double = {
        let saved = UserDefaults.standard.double(forKey: "GlideScrollDirection")
        return saved != 0 ? saved : (Engine.naturalScrolling ? -1 : 1)
    }()
    private var directionVotes = 0

    private static var naturalScrolling: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }
    private let pointer = PointerTuner()
    private let keyQueue = DispatchQueue(label: "glide.keys", qos: .userInteractive)

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
    private var dragLockManual = false         // grabbed from the keyboard
    private var modifierWait: Timer?           // a keyboard Drag lock waiting for its keys to lift
    private var modifierWaitDone: ((Bool?) -> Void)?
    private var moveTap: CFMachPort?           // only while a drag lock is on
    private var moveTapSource: CFRunLoopSource?
    private var leftDown = false               // a left press has passed the tap without its release
    // Held modes end if their button's release is ever lost (see `checkHolds`).
    private var hidButtonsDown = Set<Int>()    // Kensington buttons physically down, per HID
    private var hidButtonSeen = false          // HID has shown a press since the hold began
    private var holdStart: CFTimeInterval = 0
    private var holdReleasedChecks = 0
    private var holdFailsafe: Timer?

    init(config: GlideConfig) {
        self.config = config
        scroller.config = config
        scroller.telemetry = telemetry
        scroller.diagnostics = diagnostics
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
        perform {
            let wasEnabled = self.config.enabled
            let pointerChanged = config.trackingSpeed != self.config.trackingSpeed
                || config.precisionSpeed != self.config.precisionSpeed
                || config.scrollMode != self.config.scrollMode
                || config.nativeScrollSpeed != self.config.nativeScrollSpeed
            self.config = config
            self.scroller.config = config
            if wasEnabled && !config.enabled {
                self.releaseModes()
            } else {
                self.dropOrphanedModes()
            }
            if pointerChanged { self.applyPointer() }
        }
    }

    func reapplyPointer() { perform { self.applyPointer() } }

    /// The Beta program adds Kensington's other pointing devices. Takes effect
    /// immediately: devices are re-sorted and pointer speeds re-applied.
    func setBetaProgram(_ on: Bool) {
        perform {
            guard on != self.betaProgram else { return }
            self.betaProgram = on
            self.deviceSupported = self.devices.mapValues { $0.isSupported(beta: on) }
            self.lastActiveIsKensington = false   // re-learned from the next raw input
            self.pointer.devicesChanged()
            self.applyPointer()
            self.publish()
        }
    }

    /// Lets go of any shortcut a button is holding down (pause, quit), so a
    /// key can never stay stuck.
    func releaseHeldKeys() {
        let done = DispatchSemaphore(value: 0)
        perform {
            for (b, o) in self.overrides {
                if case .heldShortcut(let s) = o {
                    self.keyQueue.sync { Self.sendUp(s) }
                    self.overrides[b] = .swallow
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// Ends Precision, Scroll with ball, and Drag lock (pause, ⌃⌥⌘G, quit), so
    /// Glide can never leave the cursor slowed, frozen, or the left button down.
    func releaseAll() {
        let done = DispatchSemaphore(value: 0)
        perform {
            self.releaseModes()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
        // Even if the input thread were stuck, never leave the cursor frozen.
        _ = CGAssociateMouseAndMouseCursorPosition(1)
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
        let report: (Bool?) -> Void = { on in
            if let done { DispatchQueue.main.async { done(on) } }
        }
        perform {
            guard self.config.enabled else { return report(nil) }
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

    /// Ends a keyboard Scroll with ball (sleep, screen lock) so the cursor is
    /// never left frozen while nobody's looking.
    func endBallScrollLatch() {
        perform {
            if self.ballScrollLatched { self.endBallScroll(latched: true, glide: false) }
        }
    }

    /// A supported trackball is connected and Glide can read its ball.
    private var canReadBall: Bool { hid != nil && deviceSupported.values.contains(true) }

    /// Runs `body` once ⌘⌃⌥⇧ are all up, so the grab (or drop) is a plain
    /// click — never a ⌃-click or an ⌥-copy. Pressing the shortcut again
    /// while waiting cancels; after 3 s it gives up. Input thread.
    private func whenModifiersLift(_ report: @escaping (Bool?) -> Void, _ body: @escaping () -> Bool) {
        if modifierWait != nil {
            cancelModifierWait(silently: true)
            return report(nil)
        }
        let keys: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        func keysUp() -> Bool { CGEventSource.flagsState(.hidSystemState).intersection(keys).isEmpty }
        let run = { [unowned self] in
            let on = body()
            self.diagnostics.record("drag lock \(on ? "on" : "off") from keyboard")
            self.publishModes()
            report(on)
        }
        if keysUp() { return run() }
        let deadline = CACurrentMediaTime() + 3
        modifierWaitDone = report
        let t = Timer(timeInterval: 0.015, repeats: true) { [unowned self] _ in
            if keysUp() {
                self.cancelModifierWait(silently: true)
                run()
            } else if CACurrentMediaTime() > deadline {
                self.cancelModifierWait(silently: false)
            }
        }
        RunLoop.current.add(t, forMode: .common)
        modifierWait = t
    }

    /// Stops waiting; unless `silently`, tells the waiting caller nothing happened.
    private func cancelModifierWait(silently: Bool) {
        modifierWait?.invalidate()
        modifierWait = nil
        let done = modifierWaitDone
        modifierWaitDone = nil
        if !silently { done?(nil) }
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func setUp() {
        startListening()
        installTap()
        applyPointer()
        let timer = Timer(timeInterval: 2, repeats: true) { [unowned self] _ in self.maintain() }
        RunLoop.current.add(timer, forMode: .common)
        publish()
    }

    /// Self-healing: retries anything that failed (e.g. a permission granted later)
    /// and re-enables the tap if macOS ever switched it off.
    private func maintain() {
        if hid == nil { startListening() }
        if tap == nil { installTap() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        applyPointer()
        diagnostics.flush()
        publish()
    }

    private func applyPointer() {
        pointer.apply(.init(trackingSpeed: precisionActive ? config.precisionSpeed : config.trackingSpeed,
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
        s.tapActive = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        s.listening = hid != nil
        guard s != status else { return }
        status = s
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: Device listening (read-only — never seizes)

    private func startListening() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Every pointing device, so we always know which one is active. Devices
        // that advertise both usages (the Expert Mouse does) deliver reports
        // twice; `hidValue` drops the repeats by hardware timestamp.
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().hidValue(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            return
        }
        hid = manager
    }

    private static func key(_ device: IOHIDDevice) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static func identity(of device: IOHIDDevice) -> DeviceIdentity {
        DeviceIdentity(vendorID: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                       productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
                       name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
    }

    /// Whether Glide works with this device: the Expert Mouse always, other
    /// Kensington pointing devices in the Beta program. Cached per device.
    private func isSupported(_ device: IOHIDDevice) -> Bool {
        let k = Self.key(device)
        if let known = deviceSupported[k] { return known }
        let identity = devices[k] ?? Self.identity(of: device)
        let supported = identity.isSupported(beta: betaProgram)
        devices[k] = identity
        deviceSupported[k] = supported
        return supported
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let k = Self.key(device)
        devices[k] = nil
        deviceSupported[k] = nil
        if isSupported(device) {
            pointer.devicesChanged()
            // The HID service appears slightly after the device; apply twice to be sure.
            for delay in [0.3, 1.5] {
                let t = Timer(timeInterval: delay, repeats: false) { [unowned self] _ in self.applyPointer() }
                RunLoop.current.add(t, forMode: .common)
            }
        }
        publish()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if deviceSupported[Self.key(device)] == true {
            // Unplugged mid-hold: its button releases will never come.
            hidButtonsDown.removeAll()
            releaseModes()
        }
        devices[Self.key(device)] = nil
        deviceSupported[Self.key(device)] = nil
        publish()
    }

    private func hidValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let isK = isSupported(device)
        lastActiveIsKensington = isK
        guard isK else { return }

        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let v = IOHIDValueGetIntegerValue(value)

        // The same hardware report can reach us twice (one device, two
        // matches). Each report has one hardware timestamp, so skip repeats.
        let stamp = IOHIDValueGetTimeStamp(value)
        let usageKey = page << 16 | usage
        if lastValueStamp[usageKey] == stamp { return }
        lastValueStamp[usageKey] = stamp

        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X):
            telemetry.addBall(dx: v, dy: 0)
            if ballScrolling { scroller.addBallDelta(dx: Double(v) * ballSign, dy: 0) }
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            telemetry.addBall(dx: 0, dy: v)
            if ballScrolling { scroller.addBallDelta(dx: 0, dy: Double(v) * ballSign) }
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel) where v != 0:
            telemetry.addNotch()
            hidWheel(v)
        case (kHIDPage_Button, let b) where b >= 1:
            telemetry.button(b - 1, down: v != 0)
            if v != 0 {
                hidButtonsDown.insert(b)
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
        let now = CACurrentMediaTime()
        hidWheelSeen = true
        lastHIDWheel = (ticks, now)
        let flags = modifierFlags.union(CGEventSource.flagsState(.hidSystemState))
        diagnostics.record("HID wheel \(ticks)")
        // ⌘/⌃/⌥ + scroll keep their native meaning (zoom etc.): the driver's event passes.
        // In Native mode macOS does all the scrolling.
        guard config.enabled, config.scrollMode != .native,
              flags.intersection(Self.nativeScrollModifiers).isEmpty else { return }
        scroller.addTicks(Double(ticks) * directionFactor, flags: flags)
    }

    // MARK: Event tap

    private func installTap() {
        guard AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .flagsChanged,
            .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: glideTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    /// The device that produced the most recent raw input. Without Input
    /// Monitoring we can't tell devices apart, so we leave everything alone.
    private var fromKensington: Bool { hid != nil && lastActiveIsKensington }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let out = route(type, event)
        // Whether apps currently see the left button down (Precision keeps drags drags).
        switch out?.takeUnretainedValue().type {
        case .leftMouseDown?: leftDown = true
        case .leftMouseUp?: leftDown = false
        default: break
        }
        return out
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let moveTap { CGEvent.tapEnable(tap: moveTap, enable: true) }
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
        let age = CACurrentMediaTime() - lastHIDWheel.time
        guard cgDelta != 0, lastHIDWheel.value != 0, age < 0.08 else { return }
        let observed: Double = (cgDelta > 0) == (lastHIDWheel.value > 0) ? 1 : -1
        if observed == directionFactor {
            directionVotes = 0
        } else {
            directionVotes += 1
            if directionVotes >= 3 {
                directionFactor = observed
                directionVotes = 0
                UserDefaults.standard.set(observed, forKey: "GlideScrollDirection")
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
    private var pendingTimer: Timer?
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

    private func handleButton(_ event: CGEvent, _ phase: Phase) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        // Drag lock: any click (from any mouse) lets go — and that's all it does.
        // (A press that may be the start of a Drag lock combo waits for the
        // combo; if it turns out to be a lone click, `press` lets go instead.)
        if dragLocked, phase == .down, isLeftPress(event, button), !inDragLockCombo(button) {
            endDragLock()
            overrides[button] = .swallow
            return nil
        }

        if let handler = learnHandler, fromKensington || learnHeld.contains(Int(button)) {
            if phase == .down {
                learnHeld.insert(Int(button))
                learnMax.formUnion(learnHeld)
            } else if phase == .up {
                learnHeld.remove(Int(button))
                if learnHeld.isEmpty {
                    let result = learnMax
                    learnHandler = nil
                    DispatchQueue.main.async { handler(result) }
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
                    keyQueue.async { Self.sendUp(shortcut) }
                    for (b, other) in overrides {
                        if case .heldShortcut = other { overrides[b] = .swallow }
                    }
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
            }
        }
        guard phase == .down, config.enabled, fromKensington else { return pass }

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
            pendingStart = CACurrentMediaTime()
            scheduleComboWindow(Self.comboWindow)
        } else if biggerPossible {
            // A partner arrived and a bigger combo is still possible: give the
            // next finger a moment too (three fingers rarely land within 70 ms),
            // but never hold the first press longer than `comboMaxWait`.
            let left = Self.comboMaxWait - (CACurrentMediaTime() - pendingStart)
            scheduleComboWindow(max(0.01, min(Self.comboWindow, left)))
        }
        return nil
    }

    private func scheduleComboWindow(_ seconds: TimeInterval) {
        pendingTimer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [unowned self] _ in self.comboWindowEnded() }
        RunLoop.current.add(t, forMode: .common)
        pendingTimer = t
    }

    private func comboWindowEnded() {
        let held = Set(pending.map { Int($0.button) })
        if held.count > 1, let chord = config.chords.first(where: { Set($0.buttons) == held }) {
            fireCombo(chord)
        } else {
            flushPending()
        }
    }

    private func fireCombo(_ chord: Chord) {
        pendingTimer?.invalidate()
        pendingTimer = nil
        let pressedButtons = pending
        pending = []
        let action = chord.action
        if beginMode(action, buttons: pressedButtons.map(\.button)) { return }
        if case .holdShortcut(let shortcut) = action {
            // Keep Flow's shortcut down until a button in the chord is released.
            for p in pressedButtons { overrides[p.button] = .heldShortcut(shortcut) }
            keyQueue.async { Self.sendDown(shortcut) }
        } else {
            for p in pressedButtons { overrides[p.button] = .swallow }   // their releases are ours too
            keyQueue.async { Self.perform(action) }
        }
    }

    /// Posts an event we decided to pass, behind events we've already posted.
    private func postInOrder(_ result: Unmanaged<CGEvent>?) {
        guard let e = result?.takeUnretainedValue().copy() else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        e.post(tap: .cgSessionEventTap)
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
            if let loc = CGEvent(source: nil)?.location { e.location = loc }
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// Applies a single button's mapping to its press.
    private func press(_ event: CGEvent, button: Int64) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if dragLocked, isLeftPress(event, button) {
            endDragLock()
            overrides[button] = .swallow
            return nil
        }
        // Keep the primary click available even if a stale preference says
        // otherwise, so Glide can never make the mouse unusable.
        if button == 0 { return pass }
        let target: Int64
        let action = config.buttons[Int(button)] ?? .system
        if beginMode(action, buttons: [button]) { return nil }
        switch action {
        case .system: return pass
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
            keyQueue.async { Self.send(shortcut) }
            return nil
        case .holdShortcut(let shortcut):
            overrides[button] = .heldShortcut(shortcut)
            keyQueue.async { Self.sendDown(shortcut) }
            return nil
        case .modifiedClick(let b, let mods):
            let flags = CGEventFlags(rawValue: mods)
            overrides[button] = .remap(Int64(b), flags)
            Self.retarget(event, to: Int64(b), .down)
            event.flags = event.flags.union(flags)
            return pass
        case .precisionHold, .precisionToggle, .ballScrollHold, .dragLock:
            return nil   // handled by `beginMode`
        }
        if target == button { return pass }
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
        ballSign = Self.naturalScrolling ? 1 : -1
        _ = CGAssociateMouseAndMouseCursorPosition(0)   // the cursor stays put
        scroller.beginBall()
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
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        guard ballScrolling else { return }
        ballScrolling = false
        scroller.endBall(glide: glide)
        publishModes()
    }

    private func beginDragLock(manual: Bool) {
        dragLocked = true
        dragLockManual = manual
        Self.postLeft(down: true)
        installMoveTap()
    }

    private func endDragLock() {
        guard dragLocked else { return }
        dragLocked = false
        dragLockManual = false
        removeMoveTap()
        Self.postLeft(down: false)
        for (b, o) in overrides {
            if case .dragButton = o { overrides[b] = .swallow }
        }
        publishModes()
    }

    /// Would this press reach apps as a left click?
    private func isLeftPress(_ event: CGEvent, _ button: Int64) -> Bool {
        if event.type == .leftMouseDown || button == 0 { return true }
        guard config.enabled, fromKensington else { return false }
        switch config.buttons[Int(button)] {
        case .leftClick?: return true
        case .modifiedClick(let b, _)?: return b == 0
        default: return false
        }
    }

    private func inDragLockCombo(_ button: Int64) -> Bool {
        config.enabled && fromKensington
            && config.chords.contains { $0.action == .dragLock && $0.buttons.contains(Int(button)) }
    }

    private static func postLeft(down: Bool) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let e = CGEvent(mouseEventSource: keySource, mouseType: down ? .leftMouseDown : .leftMouseUp,
                              mouseCursorPosition: loc, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }

    /// A second tap for plain mouse moves, only while a drag lock is on, so
    /// ordinary pointer movement never passes through Glide.
    private func installMoveTap() {
        guard moveTap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: glideTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        moveTap = t
        moveTapSource = source
    }

    private func removeMoveTap() {
        if let moveTap {
            CGEvent.tapEnable(tap: moveTap, enable: false)
            CFMachPortInvalidate(moveTap)
        }
        if let moveTapSource { CFRunLoopRemoveSource(runLoop, moveTapSource, .commonModes) }
        moveTap = nil
        moveTapSource = nil
    }

    /// Held modes normally end on their button's release. If that release is
    /// lost (e.g. the tap was briefly off), HID button state ends them: no
    /// Kensington button down for two checks in a row. Without any HID button
    /// reports to go on, a hold ends after 10 s.
    private func startHoldFailsafe() {
        holdStart = CACurrentMediaTime()
        holdReleasedChecks = 0
        hidButtonSeen = !hidButtonsDown.isEmpty
        guard holdFailsafe == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [unowned self] _ in self.checkHolds() }
        RunLoop.current.add(t, forMode: .common)
        holdFailsafe = t
    }

    private func checkHolds() {
        guard precisionHeld || ballScrollHeld else {   // a keyboard latch is never a lost hold
            holdFailsafe?.invalidate()
            holdFailsafe = nil
            return
        }
        let lost: Bool
        if hidButtonSeen {
            holdReleasedChecks = hidButtonsDown.isEmpty ? holdReleasedChecks + 1 : 0
            lost = holdReleasedChecks >= 2
        } else {
            lost = CACurrentMediaTime() - holdStart > 10
        }
        guard lost else { return }
        diagnostics.record("hold failsafe: button release never arrived")
        if ballScrollHeld { endBallScroll(latched: false, glide: false) }
        if precisionHeld { endPrecisionHold() }
    }

    /// Ends everything at once (pause, ⌃⌥⌘G, quit, unplug). Input thread.
    private func releaseModes() {
        cancelModifierWait(silently: true)
        if ballScrolling { scroller.cancelBall() }
        ballScrolling = false
        ballScrollHeld = false
        ballScrollLatched = false
        _ = CGAssociateMouseAndMouseCursorPosition(1)
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
        let m = Modes(precision: precisionActive, ballScrolling: ballScrolling, dragLocked: dragLocked)
        guard m != modes else { return }
        modes = m
        DispatchQueue.main.async { self.onModes?(m) }
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

    /// Fires an action that isn't tied to a held button (combos): clicks are a
    /// quick press-and-release at the cursor.
    static func perform(_ action: ButtonAction) {
        let button: Int64
        var flags = CGEventFlags()
        switch action {
        case .system, .disabled: return
        case .precisionHold, .precisionToggle, .ballScrollHold, .dragLock: return   // stateful: `beginMode`
        case .shortcut(let s), .holdShortcut(let s): send(s); return
        case .modifiedClick(let b, let mods): button = Int64(b); flags = CGEventFlags(rawValue: mods)
        case .leftClick: button = 0
        case .rightClick: button = 1
        case .middleClick: button = 2
        case .back: button = 3
        case .forward: button = 4
        }
        let loc = CGEvent(source: nil)?.location ?? .zero
        let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        for down in [true, false] {
            let type: CGEventType = switch button {
            case 0: down ? .leftMouseDown : .leftMouseUp
            case 1: down ? .rightMouseDown : .rightMouseUp
            default: down ? .otherMouseDown : .otherMouseUp
            }
            guard let e = CGEvent(mouseEventSource: keySource, mouseType: type, mouseCursorPosition: loc, mouseButton: cgButton) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static let keySource = CGEventSource(stateID: .hidSystemState)
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    static func send(_ s: KeyShortcut) {
        sendDown(s)
        sendUp(s)
    }

    static func sendDown(_ s: KeyShortcut) {
        postModifiers(for: s.flags, down: true)
        postKey(s, down: true)
    }

    static func sendUp(_ s: KeyShortcut) {
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

    private static func postModifiers(for flags: CGEventFlags, down: Bool) {
        let keys = down ? modifierKeys : Array(modifierKeys.reversed())
        for modifier in keys where flags.contains(modifier.flag) {
            guard let e = CGEvent(keyboardEventSource: keySource, virtualKey: modifier.key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            e.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ s: KeyShortcut, down: Bool) {
        var flags = s.flags
        // Real arrow-key presses carry these flags; Spaces switching expects them.
        if arrowKeys.contains(s.keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        guard let e = CGEvent(keyboardEventSource: keySource, virtualKey: s.keyCode, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }
}

private func glideTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
