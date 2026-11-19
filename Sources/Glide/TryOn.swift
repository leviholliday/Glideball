import AppKit
import Observation
import SwiftUI

/// "Hold to try on": press and hold a preset card and, once it has charged (0.4 s), the
/// trackball wears that preset for `trial` seconds. You can let go of the card at once and
/// try it with both hands, here or in any other app. Keep makes it yours (as Apply does, with
/// Undo); Put mine back, Esc, the time running out and everything below put yours back. A
/// plain click does what it always did.
///
/// How it can't go wrong:
///
/// - **Nothing of yours is touched.** The tried-on setup is never written into
///   `AppModel.config`. It only exists as a change `AppModel.pushToEngine` lays over the
///   setup it hands the engine (`applied(to:)`). So it's never saved, synced or backed up,
///   and a crash or a force-quit mid-try leaves nothing behind: the next launch reads your
///   own settings, because those are the only ones on disk. "Putting yours back" is
///   dropping the change and pushing again. Only Keep writes anything, and it writes the
///   preset the way Apply does.
/// - **Every way a try can end drops it** (`Ending`): Keep, Put mine back (or Esc in
///   Glideball's windows), `trial` seconds, pausing, the trackball unplugged, sleep, the
///   screens sleeping or locking, the user switched, quitting, the window closing, leaving
///   the page, Quick Assign or the tour, and another card pressed. Switching to another app
///   doesn't: that's where you'd try it. While Glideball's window isn't the one with the
///   keys, a small floating panel (`TryOnHUD`) shows the time left with Keep and Put mine
///   back, and goes with the try whichever way it ends.
/// - **The press that charges the card is safe.** The card is held with the primary button,
///   and the engine never remaps that one whatever the settings say (`Engine.press`), so
///   its release always reaches the window. While the card charges, the watchdog looks 10
///   times a second for a mouse-up that never came (macOS's word and the trackball's own
///   HID report) and calls the press off.
///
/// Costs nothing when nothing is tried: the one timer exists only from a press to the end
/// of its try.
@Observable
final class TryOn {
    /// What's being tried: a card's id ("preset:spaces"), its name for the words on screen,
    /// and when it goes back by itself.
    struct Session: Equatable {
        let id: String
        let name: String
        var endsAt: Date
    }

    enum Ending: String, Equatable {
        case kept, putBack, timedOut, paused, unplugged, slept, quit, windowClosed, pageLeft, busy, replaced
    }

    /// What the watchdog looks at (the self-test hands it made-up ones).
    struct Conditions: Equatable {
        /// Glideball is on, with a trackball to try things on.
        var enabled = true
        var connected = true
        /// Glideball is the app in front and its window has the keys (a card can only be
        /// pressed then; otherwise the floating panel shows the try).
        var active = true
        var windowKey = true
        /// macOS says the left button is down (any mouse).
        var leftDown = true
        /// The trackball's own report says its primary button is down.
        var trackballPrimaryDown = false
        /// Any of the trackball's buttons is down.
        var trackballButtonsDown = false
        /// Quick Assign or the Welcome Tour has the buttons.
        var busy = false
    }

    /// How long a card is held before it's tried on, and when the build-up on the card
    /// starts (a plain click is over before then, so it never shows).
    static let engageDelay = 0.40
    static let chargeDelay = 0.12
    /// How long a try lasts. Long enough to press each button a couple of times, try a
    /// combo and a gesture, and switch to another app and try it there (10 to 15 s, done
    /// slowly); short enough that a try you forgot about is over before it gets in the way.
    /// (Try before you change gives a value 10 s: one roll tells you about a speed.)
    static let trial = 20.0
    static let watchInterval = 0.1

    /// `--render-ui`: draw the countdown with this many seconds left (a picture has no clock).
    nonisolated(unsafe) static var sandboxRemaining: Double?

    /// The card being tried on right now (nil: your own setup is in effect).
    private(set) var session: Session?
    /// The card that's down and building up to it (nil once it's tried on, or let go).
    private(set) var pressing: String?
    /// Bumped each time a try ends, so the page can play its "back" moment once.
    private(set) var endCount = 0
    /// How the last one ended (the self-test, and the log).
    @ObservationIgnored private(set) var lastEnding: Ending?
    /// The floating panel is wanted (a try runs and Glideball's window doesn't have the keys).
    @ObservationIgnored private(set) var hudUp = false

    @ObservationIgnored private var change: ((inout GlideConfig) -> Void)?
    @ObservationIgnored private var keepIt: (() -> Void)?
    @ObservationIgnored private var pendingName = ""
    @ObservationIgnored private var pendingChange: ((inout GlideConfig) -> Void)?
    @ObservationIgnored private var pendingKeep: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pressedAt = Date.distantPast
    /// This press tried something on: its release isn't a click.
    @ObservationIgnored private var spent = false
    /// The trackball's own primary button was seen down while the card charged: its coming
    /// up calls the press off even if the window never hears of a mouse-up.
    @ObservationIgnored private var sawTrackballPrimary = false
    @ObservationIgnored private var upTicks = 0
    @ObservationIgnored private var trackballUpTicks = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var keys: Any?
    @ObservationIgnored private var sandboxPinned = false

    /// Sends the engine the setup that's in effect now (`AppModel.pushToEngine`).
    @ObservationIgnored var push: () -> Void = {}
    @ObservationIgnored var conditions: () -> Conditions = { Conditions() }
    /// Shows or hides the floating panel (`TryOnHUD`; nothing in `--render-ui` or `--self-test`).
    @ObservationIgnored var showHUD: (Bool) -> Void = { _ in }

    var isTrying: Bool { session != nil }
    func isTrying(_ id: String) -> Bool { session?.id == id }
    /// A press of a real button shouldn't open its picker: a card is being tried, or was a
    /// moment ago and the buttons pressed during it haven't all come up yet (`buttonsSettled`).
    private(set) var settling = false

    /// Seconds left in the try (`trial` while nothing runs).
    func remaining(at now: Date = Date()) -> Double {
        if let r = Self.sandboxRemaining { return r }
        guard let s = session else { return Self.trial }
        return max(0, s.endsAt.timeIntervalSince(now))
    }

    /// `AppModel.pushToEngine`: lays what's being tried over the setup about to go to the
    /// engine. Never while paused. This is the only place a tried-on setup ever exists.
    func applied(to resolved: inout GlideConfig) {
        guard session != nil, resolved.enabled, let change else { return }
        change(&resolved)
    }

    /// `--render-ui` only: a card drawn as held and winding up (`pressing`), or tried on.
    func sandboxShow(pressing: String? = nil, trying: Session? = nil, change: ((inout GlideConfig) -> Void)? = nil) {
        guard Sandbox.isActive else { return }
        sandboxPinned = trying != nil || pressing != nil
        self.pressing = pressing
        self.change = change
        session = trying
        push()
    }

    // MARK: A card's press

    /// The card went down. False if nothing can be tried right now (paused, no trackball,
    /// Quick Assign): the card is then just a button. A try that's running ends first,
    /// whichever card it was: this press is a click or a try of its own.
    /// `keep`: makes the preset yours (Keep), as Apply does.
    @discardableResult
    func press(id: String, name: String, now: Date = Date(), change: @escaping (inout GlideConfig) -> Void,
               keep: @escaping () -> Void = {}) -> Bool {
        if session != nil { end(.replaced) }
        cancelPress()
        spent = false
        let c = conditions()
        guard c.enabled, c.connected, c.active, c.windowKey, !c.busy else { return false }
        pressing = id
        pendingName = name
        pendingChange = change
        pendingKeep = keep
        pressedAt = now
        upTicks = 0
        trackballUpTicks = 0
        sawTrackballPrimary = c.trackballPrimaryDown
        startWatching()
        return true
    }

    /// The pointer left the card before it was tried on (or anything else that makes this
    /// press an ordinary one): nothing will be tried.
    func cancelPress() {
        guard pressing != nil else { return }
        pressing = nil
        pendingChange = nil
        pendingKeep = nil
        if session == nil { stopWatching() }
    }

    /// The card's button came up. True if this press tried the card on (so it isn't a
    /// click). The try goes on: letting go is how you get both hands back.
    @discardableResult
    func release(id: String) -> Bool {
        if pressing == id { cancelPress() }
        defer { spent = false }
        return spent
    }

    /// Held long enough: the trackball wears it for `trial` seconds from now.
    private func engage(now: Date) {
        guard let id = pressing, let pendingChange else { return }
        let c = conditions()
        guard c.enabled, c.connected, c.active, c.windowKey, !c.busy, c.leftDown else { return cancelPress() }
        pressing = nil
        change = pendingChange
        keepIt = pendingKeep
        self.pendingChange = nil
        pendingKeep = nil
        spent = true
        settling = true
        lastEnding = nil
        FeatureUse.mark(.tryBeforeChange)
        withAnimation(Theme.Motion.spring) { session = Session(id: id, name: pendingName, endsAt: now.addingTimeInterval(Self.trial)) }
        push()
        listenForKeys()
        syncHUD(c)
        Sounds.shared.detent(pitch: 1.25, volume: 0.4)
    }

    /// Keep: the preset becomes yours (written as Apply writes it, with Undo), then the try is over.
    func keep() {
        guard session != nil, !sandboxPinned else { return }
        let k = keepIt
        k?()   // first, so the engine goes straight from the tried preset to the same one, saved
        end(.kept)
    }

    /// Put mine back (the button, or Esc): yours again, now.
    func putBack() { end(.putBack) }

    /// Puts your own setup back, if a card is being tried. Every exit comes here; calling it
    /// when nothing is being tried does nothing.
    func end(_ why: Ending) {
        guard !sandboxPinned else { return }   // a picture of it: the last scene's page going away isn't an ending
        if pressing != nil { cancelPress() }
        guard session != nil else { return }
        change = nil
        keepIt = nil
        lastEnding = why
        withAnimation(Theme.Motion.spring) { session = nil }
        endCount &+= 1
        stopWatching()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        syncHUD()
        if !conditions().trackballButtonsDown { settling = false }
        push()
        switch why {
        case .quit: break
        case .kept: Sounds.shared.detent(pitch: 1.2, volume: 0.4)
        default: Sounds.shared.detent(pitch: 0.85, volume: 0.35)
        }
    }

    /// Every trackball button is up again after a try: real presses open pickers once more.
    func buttonsSettled() {
        if session == nil, settling { settling = false }
    }

    /// The floating panel is up exactly while a try runs and Glideball's window doesn't
    /// have the keys (another app in front, Glideball hidden, the window minimized, the
    /// Settings window in front). Called on every change of those and at every tick.
    func syncHUD(_ given: Conditions? = nil) {
        let want: Bool
        if session == nil || sandboxPinned {
            want = false
        } else {
            let c = given ?? conditions()
            want = !(c.active && c.windowKey)
        }
        guard want != hudUp else { return }
        hudUp = want
        showHUD(want)
    }

    // MARK: While a card is down, and while it's tried

    private func startWatching() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The moment it's due, not the next tenth of a second.
        let due = DispatchWorkItem { [weak self] in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.engageDelay, execute: due)
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Ten times a second from a card's press to the end of its try (and once when the
    /// hold is due): tries it on when it's been held long enough, calls off a press whose
    /// mouse-up never came, and ends a try for anything the app's notices didn't say.
    func tick(now: Date = Date()) {
        guard pressing != nil || session != nil else { return stopWatching() }
        let c = conditions()
        guard let s = session else {
            // The button is up but no mouse-up came (two looks in a row, so one odd answer isn't enough).
            upTicks = c.leftDown ? 0 : upTicks + 1
            if c.trackballPrimaryDown { sawTrackballPrimary = true; trackballUpTicks = 0 }
            else if sawTrackballPrimary { trackballUpTicks += 1 }
            if upTicks >= 2 || trackballUpTicks >= 2 { return cancelPress() }
            if !c.enabled || !c.connected || !c.active || !c.windowKey || c.busy { return cancelPress() }
            if now.timeIntervalSince(pressedAt) >= Self.engageDelay - 0.01 { engage(now: now) }
            return
        }
        if !c.enabled { return end(.paused) }
        if !c.connected { return end(.unplugged) }
        if c.busy { return end(.busy) }
        if now >= s.endsAt { return end(.timedOut) }
        syncHUD(c)
    }

    /// Esc puts yours back and Return keeps, in Glideball's own windows while a try runs
    /// (not while something's being typed or the search palette has the keys).
    private func listenForKeys() {
        guard keys == nil, !Sandbox.isActive else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.session != nil, !CommandPalette.shared.isOpen,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return e }
            switch TryPreview.key(e.keyCode) {
            case .keep?: self.keep(); return nil
            case .cancel?: self.putBack(); return nil
            case nil: return e
            }
        }
    }

    // MARK: Things that end it at once

    /// The notices that mean "not now": sleep, the screens sleeping or locking, the user
    /// switching, quitting. (Pause, unplug, the window and the page tell it themselves:
    /// `AppModel`, `AppDelegate`, `ButtonsView`.) Glideball going to the back or hiding
    /// doesn't end it; it brings up the floating panel. Not in `--render-ui` or `--self-test`.
    func watchTheApp() {
        guard observers.isEmpty else { return }
        let app = NotificationCenter.default, work = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ why: Ending?) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let why { self?.end(why) } else { self?.syncHUD() }
                }
            }))
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            on(app, name, nil)
        }
        on(app, NSApplication.willTerminateNotification, .quit)
        on(work, NSWorkspace.willSleepNotification, .slept)
        on(work, NSWorkspace.screensDidSleepNotification, .slept)
        on(work, NSWorkspace.sessionDidResignActiveNotification, .slept)
        on(distributed, Self.screenLocked, .slept)
    }

    /// The screen locking (macOS's own distributed notice; the app isn't told otherwise).
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
}

// MARK: - The press

/// Catches the mouse over a card so it can tell a click from a hold: AppKit sends the
/// drags and the release to the view that got the press, wherever the pointer has gone
/// since, so a hold that's charging survives the pointer leaving the card. The card's
/// own Button stays underneath for the keyboard and VoiceOver.
struct PressCatcher: NSViewRepresentable {
    var help: String = ""
    /// The button went down on the card.
    let onDown: () -> Void
    /// Dragged out of the card, or back in, while down.
    let onInside: (Bool) -> Void
    /// It came up; `inside`: over the card.
    let onUp: (_ inside: Bool) -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onDown = onDown
        view.onInside = onInside
        view.onUp = onUp
        view.onHover = onHover
        view.toolTip = help.isEmpty ? nil : help
    }

    final class CatcherView: NSView {
        var onDown: () -> Void = {}
        var onInside: (Bool) -> Void = { _ in }
        var onUp: (Bool) -> Void = { _ in }
        var onHover: (Bool) -> Void = { _ in }
        private var down = false
        private var inside = false
        private var tracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func isAccessibilityElement() -> Bool { false }

        override func mouseDown(with event: NSEvent) {
            down = true
            inside = true
            onDown()
        }

        override func mouseDragged(with event: NSEvent) {
            guard down else { return }
            let now = bounds.contains(convert(event.locationInWindow, from: nil))
            if now != inside { inside = now; onInside(now) }
        }

        override func mouseUp(with event: NSEvent) {
            guard down else { return }
            down = false
            onUp(bounds.contains(convert(event.locationInWindow, from: nil)))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        /// Gone from the window with the button down (the page changed under it): that's a release.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if down { down = false; onUp(false) }
                onHover(false)
            }
        }
    }
}
