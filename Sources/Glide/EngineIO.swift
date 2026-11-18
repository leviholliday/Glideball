import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import QuartzCore

/// The stand-in pointer's window: never key or main, never clicked (`EngineIO.showStandIn`),
/// and never nudged back onto a screen, so its hot spot can sit at any edge.
private final class StandInWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {}
}

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

    /// The pointer is held (true) or free (false). Holding is done only by putting it back
    /// (`warpPointer`), never by dissociating it from the mouse: while dissociated, macOS keeps
    /// reporting the frozen spot as the pointer's location to Glideball even when another app is
    /// in front and the pointer is visibly moving, so the hold never saw it move and never put it
    /// back (Levi, beta 16 log: "114 ball reports … 0 warps, furthest 0 pt").
    ///
    /// After a warp macOS ignores the mice's movement for its "suppression interval", so warps
    /// that keep coming hold the pointer dead still in any app, which is how Mac Mouse Fix
    /// freezes the pointer for its drags (PointerFreeze.m). That interval is 0.25 s by default,
    /// which would leave the pointer stuck for a moment after the hold, so it's `holdSuppression`
    /// while holding (Mac Mouse Fix found 0.05 s the least that holds) and what it was before
    /// once free. Nothing is taken from macOS: if Glideball hangs or dies mid-hold, the pointer
    /// is free again that long after the last warp.
    /// Freeing always re-associates: that ends a suppression still running, and undoes an older
    /// build's dissociation.
    func freezePointer(_ frozen: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if !checkedSuppression {
            // A Glideball that died mid-hold left its own interval behind (it lasts the login session).
            checkedSuppression = true
            if let source, abs(source.localEventsSuppressionInterval - Self.holdSuppression) < 0.001 {
                source.localEventsSuppressionInterval = Self.defaultSuppression
            }
        }
        if frozen {
            guard !holding else { return }
            holding = true
            suppressionBefore = source?.localEventsSuppressionInterval ?? Self.defaultSuppression
            source?.localEventsSuppressionInterval = Self.holdSuppression
        } else {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            guard holding else { return }
            holding = false
            source?.localEventsSuppressionInterval = suppressionBefore
        }
    }
    private var holding = false
    private var checkedSuppression = false
    private var suppressionBefore = EngineIO.defaultSuppression
    static let holdSuppression: CFTimeInterval = 0.07
    static let defaultSuppression: CFTimeInterval = 0.25

    /// Puts the pointer back at `point` while it's held (any app in front), and starts macOS
    /// ignoring the mice's movement for `holdSuppression` (`freezePointer`). Not followed by a
    /// re-associate, which would end that at once (betas 17 to 21 did, so the pointer crept a
    /// few points between the ball's report and the warp).
    /// False if macOS refused the warp (logged per hold, so a real-hardware report says so).
    func warpPointer(_ point: CGPoint) -> Bool {
        CGWarpMouseCursorPosition(point) == .success
    }

    func post(_ event: CGEvent, tap: CGEventTapLocation) { event.post(tap: tap) }

    /// Posts a plain move (`Engine.resyncPointer`) through the HID event stream, so the stream's next
    /// movement starts where the pointer was just put rather than where the stream had got to.
    func postResync(_ event: CGEvent) { event.post(tap: .cghidEventTap) }

    // MARK: The stand-in pointer

    /// Shows a picture of the pointer at `point` (a global Quartz point: top-left origin) and
    /// hides the real one, or moves the picture there if it's already up. The real pointer goes on
    /// being put back underneath (`warpPointer`); the picture is what makes the hold look dead still,
    /// since the real pointer can't be stopped from leaving for a moment on a fast roll.
    /// This is Mac Mouse Fix's "puppet cursor" (PointerFreeze.m), our own code.
    ///
    /// The picture goes up first and the real pointer is hidden after it (on the main thread, in
    /// that order), so there's never a moment with neither. Hiding works with another app in
    /// front only after a private WindowServer switch ("SetsCursorInBackground"); without it this
    /// returns false and the hold works as before, without a stand-in (`standInProblem` says why).
    /// The engine must call `keepStandIn` at least every `standInLease`, or the main thread takes
    /// the stand-in down and shows the real pointer: a stuck input thread can't leave it hidden.
    /// Callable from any thread.
    func showStandIn(at point: CGPoint) -> Bool {
        guard let problem = Self.backgroundCursorProblem else {
            standIn.lock.lock()
            let firstGen = standIn.wanted == nil ? standIn.gen : nil
            if firstGen != nil { standIn.problem = nil }   // a new hold
            standIn.wanted = point
            standIn.keptAt = now()
            standIn.lock.unlock()
            DispatchQueue.main.async { [self] in placeStandIn(firstShowOf: firstGen) }
            return true
        }
        standIn.lock.withLock { standIn.problem = problem }
        return false
    }

    /// Shows the real pointer (at once, on the calling thread) and takes the stand-in down (on the
    /// main thread). Safe to call any number of times, from any thread: the real pointer is only
    /// shown if this put it out of sight, so hiding and showing always pair up.
    func hideStandIn() {
        standIn.lock.lock()
        dropStandIn()
        standIn.lock.unlock()
        if Thread.isMainThread { removeStandInIfUnwanted() } else { DispatchQueue.main.async { [self] in removeStandInIfUnwanted() } }
    }

    /// The engine is alive and the hold still wants its stand-in. False if it's gone (the watchdog
    /// took it down, or showing it failed): the hold goes on without one.
    func keepStandIn() -> Bool {
        standIn.lock.withLock {
            guard standIn.wanted != nil else { return false }
            standIn.keptAt = now()
            return true
        }
    }

    /// Why the stand-in couldn't be shown, or was taken down early, if it was (for the hold's log line).
    func standInProblem() -> String? { standIn.lock.withLock { standIn.problem } }

    static let standInLease: CFTimeInterval = 0.75

    /// Thread-shared stand-in state, under `lock`. The window itself is main-thread only.
    private final class StandInState {
        let lock = NSLock()
        var gen = 0                  // bumped by every take-down: a show queued before it does nothing
        var wanted: CGPoint?         // where the stand-in should be (nil: not wanted)
        var cursorHidden = false     // this hid the real pointer and hasn't shown it again
        var keptAt: CFTimeInterval = 0
        var problem: String?
        // Main thread only:
        var window: NSWindow?
        var view: NSImageView?
        var hotSpot = CGPoint.zero
        var watchdog: Timer?
    }
    private let standIn = StandInState()

    /// Under `standIn.lock`: not wanted any more, and the real pointer shown if this hid it.
    private func dropStandIn() {
        standIn.gen &+= 1
        standIn.wanted = nil
        if standIn.cursorHidden {
            standIn.cursorHidden = false
            if CGDisplayShowCursor(CGMainDisplayID()) != .success { standIn.problem = "showing the pointer again failed" }
        }
    }

    /// Main thread: the stand-in drawn where it's wanted, then the real pointer hidden.
    private func placeStandIn(firstShowOf gen: Int?) {
        standIn.lock.lock()
        guard let p = standIn.wanted, gen.map({ $0 == standIn.gen }) ?? true else { standIn.lock.unlock(); return }
        standIn.lock.unlock()
        if gen != nil || standIn.window == nil { prepareStandIn() }   // the pointer's look, fresh each hold
        guard let window = standIn.window else { return }
        window.setFrameOrigin(Self.cocoaOrigin(of: p, hotSpot: standIn.hotSpot, height: window.frame.height))
        if !window.isVisible { window.orderFrontRegardless() }
        guard gen != nil else { return }
        standIn.lock.lock()
        if gen == standIn.gen, standIn.wanted != nil, !standIn.cursorHidden {   // not taken down meanwhile
            if CGDisplayHideCursor(CGMainDisplayID()) == .success {
                standIn.cursorHidden = true
            } else {
                standIn.problem = "hiding the pointer failed"
                dropStandIn()
            }
        }
        standIn.lock.unlock()
        removeStandInIfUnwanted()
        guard standIn.watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            standIn.lock.lock()
            if standIn.wanted != nil, now() - standIn.keptAt > Self.standInLease {
                standIn.problem = "the engine stopped answering, so the real pointer came back"
                dropStandIn()
            }
            standIn.lock.unlock()
            removeStandInIfUnwanted()
        }
        RunLoop.main.add(timer, forMode: .common)
        standIn.watchdog = timer
    }

    /// Main thread: the window gone once nothing wants it.
    private func removeStandInIfUnwanted() {
        guard standIn.lock.withLock({ standIn.wanted == nil }) else { return }
        standIn.window?.orderOut(nil)
        standIn.watchdog?.invalidate()
        standIn.watchdog = nil
    }

    /// Main thread: the window, and the pointer's current look (an I-beam over text, say) at its
    /// size; the arrow if macOS won't say. AppKit draws it sharp on whichever display it's on.
    private func prepareStandIn() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image.size.width > 0 ? cursor.image : NSCursor.arrow.image
        standIn.hotSpot = cursor.image.size.width > 0 ? cursor.hotSpot : NSCursor.arrow.hotSpot
        let size = image.size
        if standIn.window == nil {
            let w = StandInWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)) + 1)   // above everything
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.animationBehavior = .none
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            let v = NSImageView(frame: NSRect(origin: .zero, size: size))
            v.imageScaling = .scaleNone
            w.contentView = v
            standIn.window = w
            standIn.view = v
        }
        standIn.view?.image = image
        standIn.view?.frame = NSRect(origin: .zero, size: size)
        standIn.window?.setContentSize(size)
    }

    /// Where a window of `height` goes (AppKit's bottom-left coordinates) so the pointer image's
    /// hot spot sits on Quartz point `p`.
    static func cocoaOrigin(of p: CGPoint, hotSpot: CGPoint, height: CGFloat) -> NSPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: p.x - hotSpot.x, y: primaryHeight - (p.y - hotSpot.y) - height)
    }

    /// Lets this app hide the pointer while another app is in front (`CGDisplayHideCursor` only
    /// works for the front app otherwise). A private WindowServer call, looked up at run time so
    /// a macOS without it just means no stand-in. Nil once done; why not, otherwise. Done once.
    private static let backgroundCursorProblem: String? = {
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT: every loaded image
        guard let c = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
              let s = dlsym(handle, "CGSSetConnectionProperty") else { return "macOS has no background-cursor switch" }
        let connection = unsafeBitCast(c, to: ConnectionFn.self)()
        let result = unsafeBitCast(s, to: SetPropertyFn.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        return result == 0 ? nil : "the background-cursor switch failed (\(result))"
    }()

    // MARK: The Wheel's and the Switcher's panels

    /// Draws the Wheel's ring on screen (the app's SwiftUI view, `WheelOverlayPanel`). Main
    /// thread only. Set once at launch; nil (render-ui, self-test) means no overlay, and a
    /// Wheel that can't be shown runs nothing.
    nonisolated(unsafe) static var wheelPresenter: WheelPresenting?

    /// Shows the Wheel's ring centred on `point` (a global Quartz point), or updates it. The
    /// engine must call `keepWheel` at least every `standInLease`, or the main thread takes it
    /// down: a stuck input thread can't leave it on screen. False if there's nothing to draw
    /// it with. Callable from any thread; drawn on the main thread, newest state wins.
    func showWheel(_ model: WheelOverlayModel, at point: CGPoint) -> Bool {
        guard Self.wheelPresenter != nil else { return false }
        wheel.show(model, at: point)
        return true
    }

    /// Takes the Wheel's ring down. Safe to call any number of times, from any thread.
    func hideWheel() { wheel.hide() }

    /// The engine is alive and still wants the ring up. False if the watchdog took it down.
    func keepWheel() -> Bool { wheel.keep() }

    private let wheel = HeldOverlay<WheelOverlayModel>(
        draw: { EngineIO.wheelPresenter?.showWheel($0, at: $1) },
        remove: { EngineIO.wheelPresenter?.hideWheel() })

    /// Builds the Switcher's app list, draws its panel and switches apps (the app's
    /// `SwitcherOverlayPanel`). Main thread only. Set once at launch; nil (render-ui,
    /// self-test) means no panel: a Switcher then only ever does its tap.
    nonisolated(unsafe) static var switcherPresenter: SwitcherPresenting?

    /// Asks the main thread to build the app list for Switcher hold `session` (on the display
    /// that has `point`) and calls `ready` with its grid, on the main thread. False (and no
    /// call) if there's nothing to build it with. The list never leaves the main thread.
    func prepareSwitcher(session: Int, near point: CGPoint, ready: @escaping (SwitcherGrid) -> Void) -> Bool {
        guard Self.switcherPresenter != nil else { return false }
        DispatchQueue.main.async {
            guard let presenter = Self.switcherPresenter else { return }
            ready(presenter.prepareSwitcher(session: session, near: point))
        }
        return true
    }

    /// Shows the Switcher's panel (on the display it was prepared for), or updates it. The
    /// same lease as the Wheel's: `keepSwitcher` at least every `standInLease`, or the main
    /// thread takes it down. False if there's nothing to draw it with.
    func showSwitcher(_ model: SwitcherOverlayModel, at point: CGPoint) -> Bool {
        guard Self.switcherPresenter != nil else { return false }
        switcher.show(model, at: point)
        return true
    }

    /// Takes the Switcher's panel down. Safe to call any number of times, from any thread.
    func hideSwitcher() { switcher.hide() }

    /// The engine is alive and still wants the panel up. False if the watchdog took it down.
    func keepSwitcher() -> Bool { switcher.keep() }

    /// Switches to app `index` of Switcher hold `session` (the release). On the main thread.
    func activateSwitcher(session: Int, index: Int) {
        DispatchQueue.main.async { Self.switcherPresenter?.activateSwitcher(session: session, index: index) }
    }

    private let switcher = HeldOverlay<SwitcherOverlayModel>(
        draw: { EngineIO.switcherPresenter?.showSwitcher($0, near: $1) },
        remove: { EngineIO.switcherPresenter?.hideSwitcher() })

    /// Something drawn on screen while a button is held (the Wheel's ring, the Switcher's
    /// panel): shown and hidden from any thread, drawn on the main thread with the newest
    /// state winning, and taken down by a main-thread watchdog if the engine stops renewing
    /// its lease (a stuck input thread can't leave it on screen). Times are CACurrentMediaTime,
    /// as `now()` is in the app (scripts/engine-fuzz overrides the methods that use this).
    private final class HeldOverlay<Model> {
        private let lock = NSLock()
        private var gen = 0
        private var wanted: (model: Model, at: CGPoint)?
        private var keptAt: CFTimeInterval = 0
        // Main thread only:
        private var watchdog: Timer?
        private var up = false
        private let draw: (Model, CGPoint) -> Void
        private let remove: () -> Void

        init(draw: @escaping (Model, CGPoint) -> Void, remove: @escaping () -> Void) {
            self.draw = draw
            self.remove = remove
        }

        func show(_ model: Model, at point: CGPoint) {
            let gen: Int = lock.withLock {
                wanted = (model, point)
                keptAt = CACurrentMediaTime()
                return self.gen
            }
            DispatchQueue.main.async { [self] in place(gen: gen) }
        }

        func hide() {
            lock.withLock {
                gen &+= 1
                wanted = nil
            }
            if Thread.isMainThread { removeIfUnwanted() } else { DispatchQueue.main.async { [self] in removeIfUnwanted() } }
        }

        func keep() -> Bool {
            lock.withLock {
                guard wanted != nil else { return false }
                keptAt = CACurrentMediaTime()
                return true
            }
        }

        /// Main thread: the newest wanted state drawn (a show queued before a take-down does nothing).
        private func place(gen: Int) {
            let w: (model: Model, at: CGPoint)? = lock.withLock { gen == self.gen ? wanted : nil }
            guard let w else { return }
            draw(w.model, w.at)
            up = true
            guard watchdog == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let t = CACurrentMediaTime()
                lock.withLock {
                    guard self.wanted != nil, t - self.keptAt > EngineIO.standInLease else { return }
                    self.gen &+= 1
                    self.wanted = nil
                }
                removeIfUnwanted()
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }

        /// Main thread: gone once nothing wants it.
        private func removeIfUnwanted() {
            guard lock.withLock({ wanted == nil }) else { return }
            if up { remove() }
            up = false
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    /// The mouse buttons macOS currently has down (any mouse), for when the tap was off.
    func buttonsDown() -> Set<Int64> {
        Set((0...31).filter { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
            .map { Int64($0) })
    }

    /// Whether macOS has this one button down right now (any mouse).
    func buttonDown(_ button: Int64) -> Bool {
        guard let b = CGMouseButton(rawValue: UInt32(clamping: button)) else { return false }
        return CGEventSource.buttonState(.combinedSessionState, button: b)
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

    /// Whether the (unsupported) device with this registry entry ID is the trackball's own
    /// driver re-publishing its movement as a pointer of its own: a HID device published by
    /// Kensington's driver (its user server, class or bundle says Kensington or `tbw`), or one
    /// sitting under a supported trackball in the registry. Read-only. Nil when it can't be
    /// told (no such entry, or a key that isn't a registry ID); the engine then goes by timing.
    /// (Levi's Mac, 2026-11-16: KensingtonWorks' `tbwDKDriver` is an event service on the
    /// trackball's own interface and publishes no second device, but other drivers might.)
    func echoReason(_ key: Int, trackballs: Set<Int>) -> String? {
        guard key > 0, let matching = IORegistryEntryIDMatching(UInt64(key)) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)   // consumes `matching`
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func text(_ entry: io_registry_entry_t, _ name: String) -> String? {
            IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        for name in ["IOUserServerName", "IOUserClass", "CFBundleIdentifier", "IOClass"] {
            if let v = text(service, name)?.lowercased(), v.contains("kensington") || v.contains("tbw") {
                return "\(name) \(v)"
            }
        }
        var entry = service
        IOObjectRetain(entry)
        for _ in 0..<10 {
            var parent: io_registry_entry_t = 0
            let got = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard got == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, trackballs.contains(Int(id)) {
                IOObjectRelease(entry)
                return String(format: "under the trackball 0x%llx", id)
            }
        }
        IOObjectRelease(entry)
        return nil
    }

    /// A device's properties as IOKit has them now (they can arrive after the device does).
    func currentIdentity(_ key: Int, _ device: IOHIDDevice?) -> DeviceIdentity? { device.map(Engine.identity(of:)) }

    /// Whether IOHIDManager managed to open this device. It opens each device it matches
    /// and never tries again if that fails, and an unopened device sends no values. Asks for
    /// one input element's last value, which reads the device's own memory, not the device
    /// (`kIOReturnNotOpen` when it isn't open); if it isn't, opens it read-only, never seized,
    /// exactly as the manager does. Returns "open", what the probe said instead, or nil when
    /// there's nothing to ask (no device, as in scripts/engine-fuzz, or no input element).
    func ensureOpen(_ key: Int, _ device: IOHIDDevice?) -> String? {
        guard let device,
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
              let element = elements.first(where: {
                  let t = IOHIDElementGetType($0)
                  return t == kIOHIDElementTypeInput_Button || t == kIOHIDElementTypeInput_Misc || t == kIOHIDElementTypeInput_Axis
              }) else { return nil }
        let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var value = Unmanaged<IOHIDValue>.passUnretained(placeholder)
        let probe = withExtendedLifetime(placeholder) { IOHIDDeviceGetValue(device, element, &value) }
        if probe == kIOReturnSuccess { return "open" }
        guard probe == kIOReturnNotOpen else { return String(format: "probe said 0x%08X (left alone)", UInt32(bitPattern: probe)) }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        return "was not open; opened again (read-only): " + (opened == kIOReturnSuccess ? "ok" : String(format: "failed 0x%08X", UInt32(bitPattern: opened)))
    }

    /// The trackball's buttons that are down right now by its own last report (CG numbers: HID
    /// usage − 1), for buttons already held when the engine starts, the tap comes back or the
    /// trackball arrives. Read-only and never blocking: each button is an input element, read
    /// with `kIOHIDDeviceGetValueWithoutUpdate` (the value the device last reported, from the
    /// device's own memory; no report is requested from the device, which is never seized).
    /// Nil when it can't be told (no device, as in scripts/engine-fuzz, or not open).
    func heldButtons(_ key: Int, _ device: IOHIDDevice?) -> Set<Int64>? {
        guard let device else { return nil }
        let match = [kIOHIDElementUsagePageKey: kHIDPage_Button] as CFDictionary
        guard let elements = IOHIDDeviceCopyMatchingElements(device, match, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return nil }
        var held = Set<Int64>()
        for element in elements where IOHIDElementGetType(element) == kIOHIDElementTypeInput_Button {
            let usage = Int(IOHIDElementGetUsage(element))
            guard (1...32).contains(usage) else { continue }
            let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
            var value = Unmanaged<IOHIDValue>.passUnretained(placeholder)
            let result = withExtendedLifetime(placeholder) {
                IOHIDDeviceGetValueWithOptions(device, element, &value, IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
            }
            guard result == kIOReturnSuccess else { return nil }   // not open: nothing to go on
            if IOHIDValueGetIntegerValue(value.takeUnretainedValue()) != 0 { held.insert(Int64(usage - 1)) }
        }
        return held
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

    /// Released notices are kept a while: a termination message already queued on the port
    /// still arrives with its refcon after the notification is released, and a freed refcon
    /// would hand the engine whatever key the memory held next.
    private var retiredNotices: [Notice] = []

    func unwatchTermination(_ key: Int) {
        guard let n = terminationNotices.removeValue(forKey: key) else { return }
        if n.object != 0 { IOObjectRelease(n.object) }
        retiredNotices.append(n)
        if retiredNotices.count > 64 { retiredNotices.removeFirst(retiredNotices.count - 64) }
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
