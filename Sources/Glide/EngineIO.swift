import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import QuartzCore

/// Something the engine scheduled that can be called off.
protocol EngineTimer: AnyObject {
    func invalidate()
}

extension Timer: EngineTimer {}

/// Everything `Engine` does to the world outside its own state: the clock, the
/// cursor, posting events, the event taps, IOHIDManager, battery lookups, pointer speeds, timers,
/// the key queue and main-thread callbacks. This class is the real Mac, and
/// exactly what the engine did before it went through here.
///
/// scripts/engine-fuzz subclasses it with a fake that records every effect, keeps
/// a virtual clock and never touches the real cursor, devices or settings, so the
/// engine's own decision code (buttons, combos, gestures, modes, pause, unplug,
/// sleep, scrolling) can be driven with millions of synthetic events.
class EngineIO {
    init() {}

    func now() -> CFTimeInterval { CACurrentMediaTime() }

    func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }

    /// The physical keyboard's modifier state.
    func keyboardFlags() -> CGEventFlags { CGEventSource.flagsState(.hidSystemState) }

    /// Freezes (true) or frees (false) the pointer; the ball keeps reporting movement.
    func freezePointer(_ frozen: Bool) { _ = CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1) }

    func post(_ event: CGEvent, tap: CGEventTapLocation) { event.post(tap: tap) }

    /// The mouse buttons macOS currently has down (any mouse), for when the tap was off.
    func buttonsDown() -> Set<Int64> {
        Set((0...31).filter { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
            .map { Int64($0) })
    }

    // MARK: Threads and timers

    private let keyQueue = DispatchQueue(label: "glide.keys", qos: .userInteractive)

    /// Key and click posting happens off the input thread, in order.
    func keys(_ work: @escaping () -> Void) { keyQueue.async(execute: work) }
    /// …and waits for it (pause, quit).
    func keysNow(_ work: () -> Void) { keyQueue.sync(execute: work) }

    func toMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    /// A timer on the current (input) thread's run loop, in common modes.
    func schedule(_ interval: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) -> EngineTimer {
        let t = Timer(timeInterval: interval, repeats: repeats) { _ in body() }
        RunLoop.current.add(t, forMode: .common)
        return t
    }

    // MARK: Settings the engine reads

    var naturalScrolling: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }

    /// The scroll direction the engine learned (0: not learned yet).
    var savedScrollDirection: Double {
        get { UserDefaults.standard.double(forKey: "GlideScrollDirection") }
        set { UserDefaults.standard.set(newValue, forKey: "GlideScrollDirection") }
    }

    func openApp(_ bundleID: String) {
        DispatchQueue.main.async {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Pointer speed (PointerTuner)

    /// Made on first use, on the input thread — so an engine that's never started
    /// (`--render-ui`, `--self-test`) never opens an HID event-system client.
    private lazy var tuner = PointerTuner()

    func applyPointer(_ settings: PointerTuner.Settings) { tuner.apply(settings) }
    func restorePointer() { tuner.restoreAll() }
    func pointerDevicesChanged() { tuner.devicesChanged() }

    // MARK: Event taps

    /// A session event tap for `mask`, on `runLoop`, enabled. Nil without Accessibility.
    func installTap(mask: CGEventMask, engine: Engine, runLoop: CFRunLoop?) -> (CFMachPort, CFRunLoopSource)? {
        guard AXIsProcessTrusted(),
              let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: glideTapCallback,
                                          userInfo: Unmanaged.passUnretained(engine).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return nil }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, source)
    }

    func removeTap(_ tap: CFMachPort, source: CFRunLoopSource?, runLoop: CFRunLoop?) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
    }

    func tapIsEnabled(_ tap: CFMachPort) -> Bool { CGEvent.tapIsEnabled(tap: tap) }
    func tapEnable(_ tap: CFMachPort, _ on: Bool) { CGEvent.tapEnable(tap: tap, enable: on) }

    // MARK: Devices (read-only — never seizes)

    private var manager: IOHIDManager?

    /// Listens to every pointing device without seizing it. False without Input Monitoring.
    func startListening(_ engine: Engine, runLoop: CFRunLoop?) -> Bool {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return false }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Every pointing device, so we always know which one is active. Devices
        // that advertise both usages (the Expert Mouse does) deliver reports
        // twice; `hidInput` drops the repeats by hardware timestamp.
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(engine).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().hidValue(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop!, CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop!, CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        self.manager = manager
        return true
    }

    // MARK: Battery (read-only registry lookups, never the device itself)

    private var batteryDevices: [Int: IOHIDDevice] = [:]

    /// A Kensington device the engine may ask about later (nil: none to read, as in scripts/engine-fuzz).
    func rememberDevice(_ key: Int, _ device: IOHIDDevice?) { batteryDevices[key] = device }
    func forgetDevice(_ key: Int) { batteryDevices[key] = nil }

    /// `BatteryPercent` from the registry for device `key`, if it has one (DeviceBattery).
    func registryBattery(_ key: Int) -> Int? { batteryDevices[key].flatMap(DeviceBattery.registryPercent) }
}
