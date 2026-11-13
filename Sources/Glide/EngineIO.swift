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

    /// The pointing devices IOHIDManager lists right now, by `Engine.key`; nil when it isn't open.
    /// Not proof that they're plugged in: IOHIDManager calls its removal callback *before*
    /// it takes the device out of this set (IOKitUser, IOHIDManager.c,
    /// `__IOHIDManagerDeviceRemoved`), and a removal it never heard of leaves one here for
    /// good. `Engine.reconcileNow` checks each against `serviceIsAlive`.
    func liveDevices() -> [Int: (identity: DeviceIdentity, transport: String?, device: IOHIDDevice?)]? {
        guard let manager, let set = IOHIDManagerCopyDevices(manager) as NSSet? else { return manager == nil ? nil : [:] }
        var out: [Int: (identity: DeviceIdentity, transport: String?, device: IOHIDDevice?)] = [:]
        for obj in set {
            let device = unsafeBitCast(obj as AnyObject, to: IOHIDDevice.self)
            out[Engine.key(device)] = (Engine.identity(of: device), DeviceBattery.transport(device), device)
        }
        return out
    }

    /// A fresh question to IOKit: is the HID service with this registry entry ID still
    /// registered? A terminated (unplugged) service is never found by matching, whatever
    /// IOHIDManager still lists. Keys that aren't registry IDs (0, or a pointer from an old
    /// fallback, which is negative) count as alive, so nothing is ever dropped on a guess.
    func serviceIsAlive(_ key: Int) -> Bool {
        guard key > 0, let matching = IORegistryEntryIDMatching(UInt64(key)) else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)   // consumes `matching`
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    // MARK: Termination notices (a second signal beside IOHIDManager's removal callback)

    /// What a termination notice's refcon points at (kept alive in `terminationNotices`).
    private final class Notice {
        unowned let engine: Engine
        let key: Int
        var object: io_object_t = 0
        init(engine: Engine, key: Int) { self.engine = engine; self.key = key }
    }

    private var notifyPort: IONotificationPortRef?
    private var terminationNotices: [Int: Notice] = [:]

    /// Asks IOKit to tell the engine the moment this device's service is terminated
    /// (kIOMessageServiceIsTerminated), on the input thread's run loop. Only for the devices
    /// the engine works with. No-op in scripts/engine-fuzz (device is nil).
    func watchTermination(_ key: Int, _ device: IOHIDDevice?, engine: Engine, runLoop: CFRunLoop?) {
        guard let device, terminationNotices[key] == nil, let runLoop else { return }
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return }
        if notifyPort == nil {
            notifyPort = IONotificationPortCreate(kIOMainPortDefault)
            if let port = notifyPort, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
        }
        guard let notifyPort else { return }
        let notice = Notice(engine: engine, key: key)
        let ok = IOServiceAddInterestNotification(notifyPort, service, kIOGeneralInterest, { refcon, _, message, _ in
            // kIOMessageServiceIsTerminated: iokit_common_msg(0x010)
            guard message == 0xE000_0010, let refcon else { return }
            let notice = Unmanaged<Notice>.fromOpaque(refcon).takeUnretainedValue()
            notice.engine.deviceTerminated(key: notice.key)
        }, Unmanaged.passUnretained(notice).toOpaque(), &notice.object)
        if ok == KERN_SUCCESS { terminationNotices[key] = notice }
    }

    func unwatchTermination(_ key: Int) {
        if let n = terminationNotices.removeValue(forKey: key), n.object != 0 { IOObjectRelease(n.object) }
    }

    /// Every Kensington HID device IOKit has registered right now, from a fresh matching
    /// query (not IOHIDManager): for "Copy connection details".
    func kensingtonServicesNow() -> [String] {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return [] }
        matching[kIOHIDVendorIDKey] = DeviceIdentity.kensingtonVendorID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            let pid = (prop(kIOHIDProductIDKey) as? Int).map { String(format: "0x%04X", $0) } ?? "?"
            let usage = "\(prop(kIOHIDPrimaryUsagePageKey) as? Int ?? 0)/\(prop(kIOHIDPrimaryUsageKey) as? Int ?? 0)"
            let transport = prop(kIOHIDTransportKey) as? String ?? "?"
            let location = (prop(kIOHIDLocationIDKey) as? Int).map { String(format: "0x%08X", $0) } ?? "?"
            out.append("id 0x\(String(id, radix: 16)) product \(pid) usage \(usage) \(transport) location \(location)")
            IOObjectRelease(service)
        }
        return out
    }

    /// `BatteryPercent` from the registry for device `key`, if it has one (DeviceBattery).
    func registryBattery(_ key: Int) -> Int? { batteryDevices[key].flatMap(DeviceBattery.registryPercent) }
}
