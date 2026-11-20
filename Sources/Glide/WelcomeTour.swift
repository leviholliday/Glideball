import Foundation

/// The first-launch walkthrough (the view is `WelcomeTourView`). It opens by
/// itself once, on a Mac that has never run Glide, and any time from
/// Help › Show Welcome Tour….
enum WelcomeTour {
    static let doneKey = "GlideOnboardingDone"

    /// Whether to open the tour at launch. Call before `AppModel` loads: once
    /// it has, synced settings may already have been saved on this Mac.
    /// People who used Glide before the tour existed are marked done instead.
    static func shouldShowAtLaunch(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: doneKey) { return false }
        // "GlideConfig" is where GlideConfig.save() keeps settings; daily totals
        // are saved whenever the window closes, so they mark a past user too.
        let existingUser = defaults.data(forKey: "GlideConfig") != nil
            || defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("GlideTotals-") }
        if existingUser {
            defaults.set(true, forKey: doneKey)
            return false
        }
        return true
    }
}

/// The strike: the tour ends with the product's own best move. Hold the top-right button, roll
/// the ball any way, let go, and that one gesture turns Glideball on, lights the sidebar's orb,
/// plays the hello chord and closes the tour (idea 6 in 2026-11-19-delight-research).
///
/// It can never block. The button under it ("Start Using Glideball", Return) does exactly the
/// same thing, Skip Tour and esc still close the tour, and the gesture is only offered when
/// there's a trackball Glideball can read: with none connected, permissions missing or
/// Glideball paused, the page just has its button.
///
/// The gesture is the real one, run by the engine: while the last step is on screen in the
/// active window, the setup handed to the engine (never the saved one) has a Gestures hold on
/// the button, every direction the same, with "Try it" practice on so nothing is ever sent.
/// It comes off with every way out of the step: the gesture itself, the button, Skip, Back,
/// another app in front, the window closing, a pause, an unplug, a quit.
enum Strike {
    /// What the page can ask for.
    enum Offer: Equatable {
        /// No trackball to do it with: the button only.
        case none
        /// An Expert Mouse: its top-right button.
        case topRight
        /// Another Kensington, whose buttons sit differently: any button but the left click.
        case anyButton
    }

    static func offer(permissionsOK: Bool, enabled: Bool, status: Engine.Status) -> Offer {
        guard permissionsOK, enabled, status.deviceConnected else { return .none }
        return status.deviceIsBeta ? .anyButton : .topRight
    }

    /// The buttons that carry the gesture. Never the bottom-left one: it's always a left click.
    static func buttons(_ offer: Offer) -> [Int] {
        switch offer {
        case .none: []
        case .topRight: [3]
        case .anyButton: [1, 2, 3, 4]
        }
    }

    /// Every way is the same: it opens Glideball. The ring comes up right away, the shortest
    /// roll counts, and under practice nothing is sent at all (if practice ever lapsed, opening
    /// the app that's already in front is all it could do).
    static var gesture: ButtonGesture {
        let step = GestureStep(.openApp(bundleID: Bundle.main.bundleIdentifier ?? "com.leviholliday.glide"))
        var g = ButtonGesture(up: step, down: step, left: step, right: step, distance: .short)
        g.show = .atOnce
        return g
    }
}

extension AppModel {
    func showWelcomeTour() {
        showingWelcomeTour = true
    }

    // MARK: The strike

    var strikeOffer: Strike.Offer {
        Strike.offer(permissionsOK: permissionsOK, enabled: config.enabled, status: status)
    }

    /// The tour's last step came up in the active window (or stopped being that).
    func armStrike(_ on: Bool) {
        guard strikeWanted != on else { return }
        strikeWanted = on
        if on { tryOn.end(.busy) }
        pushToEngine()
    }

    /// `pushToEngine`'s part: puts the gesture on the buttons that can carry it right now, in the
    /// setup going to the engine, and keeps practice on for exactly as long as it's there.
    func strikeLay(over resolved: inout GlideConfig) {
        let buttons = strikeWanted ? Strike.buttons(strikeOffer) : []
        if buttons != strikeButtons {
            strikeButtons = buttons
            strikeRolled = false
            setGesturePractice(!buttons.isEmpty)
            strikePractice?.cancel()
            strikePractice = nil
            if !buttons.isEmpty {
                // The engine ends practice by itself after two minutes: asked for again before that.
                strikePractice = Task { @MainActor [weak self] in
                    while true {
                        try? await Task.sleep(for: .seconds(100))
                        guard !Task.isCancelled, let self, !self.strikeButtons.isEmpty else { return }
                        self.setGesturePractice(true)
                    }
                }
            }
        }
        guard !buttons.isEmpty else { return }
        resolved.buttons = Dictionary(uniqueKeysWithValues: buttons.map { ($0, ButtonAction.gesture(Strike.gesture)) })
        resolved.chords = []
        resolved.gesturesEnabled = true
    }

    /// What the engine just said (`Engine.onModes`): a hold on the strike's button that rolled
    /// any way is the strike, once the button is up. One let go without a roll is only counted.
    func strikeSaw(_ m: Engine.Modes, was: Engine.Modes) {
        guard !strikeButtons.isEmpty else { return }
        var tapped = false
        if let f = m.wheelFlash, f != was.wheelFlash, f.buttons.contains(where: strikeButtons.contains) {
            switch f.kind {
            case .slot, .repeated: strikeRolled = true
            case .tap: tapped = true
            case .ring: break
            }
        }
        if let f = m.gestureFlash, f != was.gestureFlash, f.buttons.contains(where: strikeButtons.contains) {
            if f.direction != nil { strikeRolled = true } else { tapped = true }
        }
        if strikeRolled {
            if !m.gestureHeld && !m.wheelHeld { strike() }
        } else if tapped {
            strikeFumbles &+= 1
        }
    }

    /// The tour's ending, by the gesture, the button or Return, all the same: Glideball is on,
    /// the sidebar's orb lights, the hello chord plays (if Sounds is on) and the tour closes.
    func strike() {
        armStrike(false)
        if !config.enabled { config.enabled = true }
        struck &+= 1
        Sounds.shared.play(.hello)
        closeWelcomeTour()
    }

    /// Closes the tour (finished or skipped) — it won't open by itself again.
    func closeWelcomeTour() {
        armStrike(false)
        suspendButtonMappings(false)
        showingWelcomeTour = false
        UserDefaults.standard.set(true, forKey: WelcomeTour.doneKey)
        showNextPrompt(after: 1.2)   // the small favor, after the tour and never on top of it
    }

    /// While the tour asks you to press each button, the buttons do only their
    /// plain macOS clicks — so the top two don't switch Spaces mid-tour. The
    /// saved settings never change; the engine just runs a copy without
    /// remaps or combos, and gets the real settings back afterwards.
    func suspendButtonMappings(_ suspend: Bool) {
        guard mappingsSuspended != suspend else { return }
        mappingsSuspended = suspend
        pushToEngine()   // same path as everything else, so app setups come back too
    }
}
