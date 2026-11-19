import AppKit
import Observation
import SwiftUI

/// "Hold to try on": press and hold a preset card and the trackball wears that preset
/// for as long as the card is held, so you can feel it with the real buttons. Let go and
/// your own setup is back, exactly. A plain click does what it always did.
///
/// How it can't go wrong:
///
/// - **Nothing of yours is touched.** The tried-on setup is never written into
///   `AppModel.config`. It only exists as a change `AppModel.pushToEngine` lays over the
///   setup it hands the engine (`applied(to:)`). So it's never saved, synced or backed up,
///   Undo has nothing to undo, and a crash or a force-quit mid-hold leaves nothing behind:
///   the next launch reads your own settings, because those are the only ones on disk.
///   "Putting yours back" is dropping the change and pushing again.
/// - **Every way a hold can end drops it** (`Ending`): the button coming up, the pointer's
///   button being up when no mouse-up ever arrived (looked at 10 times a second while a
///   card is down, both macOS's word and the trackball's own HID report), pausing, the
///   trackball unplugged, Glideball no longer in front, the window closing or losing
///   focus, leaving the page, sleep or the screen locking, quitting, Quick Assign or the
///   tour starting, and 30 seconds at most.
/// - **The press that holds the card is safe.** The card is held with the primary button,
///   and the engine never remaps that one whatever the settings say (`Engine.press`), so
///   its release always reaches the window. A combo that includes the primary button can't
///   form while it's already down, so a preset's own combos never swallow it either.
///
/// Costs nothing when no card is down: the one timer exists only between a press and its end.
@Observable
final class TryOn {
    /// What's being tried: a card's id ("preset:spaces"), and its name for the words on screen.
    struct Session: Equatable {
        let id: String
        let name: String
    }

    enum Ending: String, Equatable {
        case released, lostRelease, timedOut, paused, unplugged, deactivated, windowLeft, pageLeft, slept, quit, busy, replaced
    }

    /// What the watchdog looks at (the self-test hands it made-up ones).
    struct Conditions: Equatable {
        /// Glideball is on, with a trackball to try things on.
        var enabled = true
        var connected = true
        /// Glideball is the app in front and its window has the keys.
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
    /// Never longer than this, whatever else happens.
    static let limit = 30.0
    static let watchInterval = 0.1

    /// The card being tried on right now (nil: your own setup is in effect).
    private(set) var session: Session?
    /// The card that's down and building up to it (nil once it's tried on, or let go).
    private(set) var pressing: String?
    /// Bumped each time a try ends, so the page can play its "back" moment once.
    private(set) var endCount = 0
    /// How the last one ended (the self-test, and the log).
    @ObservationIgnored private(set) var lastEnding: Ending?

    @ObservationIgnored private var change: ((inout GlideConfig) -> Void)?
    @ObservationIgnored private var pendingName = ""
    @ObservationIgnored private var pendingChange: ((inout GlideConfig) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pressedAt = Date.distantPast
    @ObservationIgnored private var engagedAt = Date.distantPast
    /// This press tried something on: its release isn't a click, even if the try already ended.
    @ObservationIgnored private var spent = false
    /// The trackball's own primary button was seen down during this try: its coming up ends
    /// it even if the window never hears of a mouse-up.
    @ObservationIgnored private var sawTrackballPrimary = false
    @ObservationIgnored private var upTicks = 0
    @ObservationIgnored private var trackballUpTicks = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sandboxPinned = false

    /// Sends the engine the setup that's in effect now (`AppModel.pushToEngine`).
    @ObservationIgnored var push: () -> Void = {}
    @ObservationIgnored var conditions: () -> Conditions = { Conditions() }

    var isTrying: Bool { session != nil }
    func isTrying(_ id: String) -> Bool { session?.id == id }
    /// A press of a real button shouldn't open its picker: a card is being tried, or was a
    /// moment ago and the buttons pressed during it haven't all come up yet (`buttonsSettled`).
    private(set) var settling = false

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
    /// Quick Assign): the card is then just a button.
    @discardableResult
    func press(id: String, name: String, now: Date = Date(), change: @escaping (inout GlideConfig) -> Void) -> Bool {
        if session != nil { end(.replaced) }
        cancelPress()
        spent = false
        let c = conditions()
        guard c.enabled, c.connected, c.active, c.windowKey, !c.busy else { return false }
        pressing = id
        pendingName = name
        pendingChange = change
        pressedAt = now
        upTicks = 0
        trackballUpTicks = 0
        sawTrackballPrimary = false
        startWatching()
        return true
    }

    /// The pointer left the card before it was tried on (or anything else that makes this
    /// press an ordinary one): nothing will be tried.
    func cancelPress() {
        guard pressing != nil else { return }
        pressing = nil
        pendingChange = nil
        if session == nil { stopWatching() }
    }

    /// The card's button came up. True if this press tried the card on (so it isn't a click).
    @discardableResult
    func release(id: String) -> Bool {
        if session?.id == id { end(.released) }
        if pressing == id { cancelPress() }
        defer { spent = false }
        return spent
    }

    /// Held long enough: the trackball wears it from now until the hold ends.
    private func engage(now: Date) {
        guard let id = pressing, let pendingChange else { return }
        let c = conditions()
        guard c.enabled, c.connected, c.active, c.windowKey, !c.busy, c.leftDown else { return cancelPress() }
        pressing = nil
        change = pendingChange
        self.pendingChange = nil
        engagedAt = now
        spent = true
        settling = true
        sawTrackballPrimary = c.trackballPrimaryDown
        lastEnding = nil
        FeatureUse.mark(.tryBeforeChange)
        withAnimation(Theme.Motion.spring) { session = Session(id: id, name: pendingName) }
        push()
        Sounds.shared.detent(pitch: 1.25, volume: 0.4)
    }

    /// Puts your own setup back, if a card is being tried. Every exit comes here; calling it
    /// when nothing is being tried does nothing.
    func end(_ why: Ending) {
        guard !sandboxPinned else { return }   // a picture of it: the last scene's page going away isn't an ending
        if pressing != nil { cancelPress() }
        guard session != nil else { return }
        change = nil
        lastEnding = why
        withAnimation(Theme.Motion.spring) { session = nil }
        endCount &+= 1
        stopWatching()
        if !conditions().trackballButtonsDown { settling = false }
        push()
        if why != .quit { Sounds.shared.detent(pitch: 0.85, volume: 0.35) }
    }

    /// Every trackball button is up again after a try: real presses open pickers once more.
    func buttonsSettled() {
        if session == nil, settling { settling = false }
    }

    // MARK: While a card is down

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

    /// Ten times a second while a card is down (and once when the hold is due): tries it on
    /// when it's been held long enough, and ends it for anything that means the hold is over
    /// without the window having been told.
    func tick(now: Date = Date()) {
        guard pressing != nil || session != nil else { return stopWatching() }
        let c = conditions()
        // The button is up but no mouse-up came (two looks in a row, so one odd answer isn't enough).
        upTicks = c.leftDown ? 0 : upTicks + 1
        if c.trackballPrimaryDown { sawTrackballPrimary = true; trackballUpTicks = 0 }
        else if sawTrackballPrimary { trackballUpTicks += 1 }
        if upTicks >= 2 || trackballUpTicks >= 2 { return session != nil ? end(.lostRelease) : cancelPress() }
        guard session != nil else {
            if !c.enabled || !c.connected || !c.active || !c.windowKey || c.busy { return cancelPress() }
            if now.timeIntervalSince(pressedAt) >= Self.engageDelay - 0.01 { engage(now: now) }
            return
        }
        if !c.enabled { return end(.paused) }
        if !c.connected { return end(.unplugged) }
        if !c.active { return end(.deactivated) }
        if !c.windowKey { return end(.windowLeft) }
        if c.busy { return end(.busy) }
        if now.timeIntervalSince(engagedAt) >= Self.limit { return end(.timedOut) }
    }

    // MARK: Things that end it at once

    /// The app's own notices that mean "not now": losing the front, sleep, the screen
    /// locking or the user switching, quitting. (Pause, unplug, the window and the page tell
    /// it themselves: `AppModel`, `ButtonsView`.) Not in `--render-ui` or `--self-test`.
    func watchTheApp() {
        guard observers.isEmpty else { return }
        let app = NotificationCenter.default, work = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ why: Ending) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(why) }
            })
        }
        on(app, NSApplication.didResignActiveNotification, .deactivated)
        on(app, NSApplication.didHideNotification, .deactivated)
        on(app, NSApplication.willTerminateNotification, .quit)
        on(work, NSWorkspace.willSleepNotification, .slept)
        on(work, NSWorkspace.screensDidSleepNotification, .slept)
        on(work, NSWorkspace.sessionDidResignActiveNotification, .slept)
    }
}

// MARK: - The press

/// Catches the mouse over a card so it can tell a click from a hold: AppKit sends the
/// drags and the release to the view that got the press, wherever the pointer has gone
/// since, so a hold that's being tried survives the pointer leaving the card. The card's
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
