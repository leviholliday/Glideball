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
    }

    let telemetry = Telemetry()
    var onStatus: ((Status) -> Void)?          // delivered on main

    private var config: GlideConfig
    private var runLoop: CFRunLoop!
    private var foundationRunLoop: RunLoop!
    private var tap: CFMachPort?
    private var hid: IOHIDManager?
    private var deviceIsKensington: [Int: Bool] = [:]
    private var lastActiveIsKensington = false
    private var lastValueStamp: [Int: UInt64] = [:]
    private var status = Status()

    private enum Override { case swallow, remap(Int64, CGEventFlags), heldShortcut(KeyShortcut) }
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
        thread.name = "Glide input"
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
            let pointerChanged = config.trackingSpeed != self.config.trackingSpeed
                || config.scrollMode != self.config.scrollMode
                || config.nativeScrollSpeed != self.config.nativeScrollSpeed
            self.config = config
            self.scroller.config = config
            if pointerChanged { self.applyPointer() }
        }
    }

    func reapplyPointer() { perform { self.applyPointer() } }

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
        pointer.apply(.init(trackingSpeed: config.trackingSpeed,
                            scrollSpeed: config.scrollMode == .native ? config.nativeScrollSpeed : nil))
    }

    private func publish() {
        var s = Status()
        s.deviceConnected = deviceIsKensington.values.contains(true)
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

    private static func isKensington(_ device: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) == PointerTuner.vendorID
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let isK = Self.isKensington(device)
        deviceIsKensington[Self.key(device)] = isK
        if isK {
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
        deviceIsKensington[Self.key(device)] = nil
        publish()
    }

    private func hidValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let k = Self.key(device)
        let isK: Bool
        if let known = deviceIsKensington[k] { isK = known } else {
            isK = Self.isKensington(device)
            deviceIsKensington[k] = isK
        }
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
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X): telemetry.addBall(dx: v, dy: 0)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y): telemetry.addBall(dx: 0, dy: v)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel) where v != 0:
            telemetry.addNotch()
            hidWheel(v)
        case (kHIDPage_Button, let b) where b >= 1: telemetry.button(b - 1, down: v != 0)
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
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case _ where event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag:
            return pass   // our own events
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
            pendingTimer?.invalidate()
            let t = Timer(timeInterval: Self.comboWindow, repeats: false) { [unowned self] _ in self.comboWindowEnded() }
            RunLoop.current.add(t, forMode: .common)
            pendingTimer = t
        }
        return nil
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
        // Keep the primary click available even if a stale preference says
        // otherwise, so Glide can never make the mouse unusable.
        if button == 0 { return pass }
        let target: Int64
        switch config.buttons[Int(button)] ?? .system {
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
        }
        if target == button { return pass }
        overrides[button] = .remap(target, [])
        Self.retarget(event, to: target, .down)
        return pass
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
