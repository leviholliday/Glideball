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

extension AppModel {
    func showWelcomeTour() {
        showingWelcomeTour = true
    }

    /// Closes the tour (finished or skipped) — it won't open by itself again.
    func closeWelcomeTour() {
        suspendButtonMappings(false)
        showingWelcomeTour = false
        UserDefaults.standard.set(true, forKey: WelcomeTour.doneKey)
    }

    /// While the tour asks you to press each button, the buttons do only their
    /// plain macOS clicks — so the top two don't switch Spaces mid-tour. The
    /// saved settings never change; the engine just runs a copy without
    /// remaps or combos, and gets the real settings back afterwards.
    func suspendButtonMappings(_ suspend: Bool) {
        if suspend {
            var plain = config
            plain.buttons = [:]
            plain.chords = []
            engine.update(plain)
        } else {
            engine.update(config)
        }
    }
}
