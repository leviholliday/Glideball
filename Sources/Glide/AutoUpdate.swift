import Foundation

// "Install updates automatically": the decisions, with nothing live in them, so
// scripts/update-fuzz can check every one. UpdateChecker.swift does the work
// (the same download and the same checks as an update you click), and the app
// fills in `SafeMoment` from the engine and its windows.
//
// The rules, in one place:
// - Off unless the person turned it on. Betas only with Early updates, as ever
//   (it installs what the check offers, and nothing else).
// - A newer version is downloaded and checked in the background and kept staged.
// - Glideball restarts into it only at a safe moment (`SafeMoment.verdict`).
// - Anything that fails is dropped quietly and tried again a day later, three
//   times at most for one version (`AutoUpdateLedger`). After that it's the
//   update button's job, as before.
// - Never a version that isn't newer than the one running.
//
// Foundation only.

/// The per-Mac "Install updates automatically" switch. Off until the person turns
/// it on; never synced, like Early updates.
enum AutoUpdateSetting {
    static let defaultsKey = "GlideAutoInstallUpdates"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// What Glideball looks at before it restarts itself into a staged update.
/// Glideball runs the person's pointer, so the restart has to go unnoticed:
/// nothing held, nothing in flight, nobody at the trackball, nothing of
/// Glideball's on screen being used.
struct SafeMoment: Equatable {
    /// A trackball button is physically down.
    var buttonDown = false
    /// A Gestures, ring or Switcher hold is going on.
    var holdInFlight = false
    /// Precision, Drag lock, Scroll with ball or Try it is on: a restart would switch it off.
    var modeOn = false
    /// Seconds since the ball, the ring, a button or Glideball's own scrolling last did anything.
    var trackballIdle: TimeInterval = 0
    /// Seconds since any keyboard or pointer input on this Mac.
    var macIdle: TimeInterval = 0
    /// The screen is locked or the display is asleep.
    var screenAway = false
    /// Glideball's main window is open (it comes back after the restart, which only goes unseen with the screen away).
    var windowOpen = false
    /// Something of Glideball's is in use: Settings or another window open, a sheet or
    /// preview up, the tour, a value on trial, the launch animation, an update being
    /// installed by hand, an app setup pinned by a script.
    var busy = false

    /// How long the trackball must have been still, and the Mac untouched.
    static let trackballQuiet: TimeInterval = 180
    static let macQuiet: TimeInterval = 120
    /// With the screen locked or asleep nobody's watching, so a short wait is enough
    /// (it still isn't "at once": someone may be typing their password).
    static let awayQuiet: TimeInterval = 20

    enum Reason: String, Equatable {
        case buttonDown, holdInFlight, modeOn, busy, windowOpen, trackballInUse, macInUse
    }

    enum Verdict: Equatable {
        case go
        case wait(Reason)
    }

    /// Go, or the first thing in the way. What's held comes first and nothing after
    /// it can outvote it: however long the idle time claims to be, a button that's
    /// down, a hold or a mode means wait.
    var verdict: Verdict {
        if buttonDown { return .wait(.buttonDown) }
        if holdInFlight { return .wait(.holdInFlight) }
        if modeOn { return .wait(.modeOn) }
        if busy { return .wait(.busy) }
        if windowOpen && !screenAway { return .wait(.windowOpen) }
        let trackballNeeds = screenAway ? Self.awayQuiet : Self.trackballQuiet
        let macNeeds = screenAway ? Self.awayQuiet : Self.macQuiet
        // `!(x >= y)` rather than `x < y`: a NaN is never long enough.
        if !(trackballIdle >= trackballNeeds) { return .wait(.trackballInUse) }
        if !(macIdle >= macNeeds) { return .wait(.macInUse) }
        return .go
    }

    var isSafe: Bool { verdict == .go }
}

/// What automatic updates remember between launches (UserDefaults, this Mac only):
/// what failed and when, the restart in progress, and the note to show after one.
/// No version is ever tried in a loop: a failure waits most of a day, and the
/// third one for the same version is the last.
struct AutoUpdateLedger: Codable, Equatable {
    struct Failure: Codable, Equatable {
        var version: String
        var count: Int
        var last: Date
    }

    /// Written just before Glideball quits to be swapped, read by whichever app starts next.
    struct Handoff: Codable, Equatable {
        var from: String
        var to: String
        var at: Date
        /// The main window was open (only with the screen away): it's put back, without coming to the front.
        var windowOpen = false
    }

    var failure: Failure?
    var handoff: Handoff?
    /// The version Glideball updated itself to, until the person has been told.
    var note: String?

    static let defaultsKey = "GlideAutoUpdateLedger"
    /// A little under the daily check, so the next day's check may try again.
    static let retryAfter: TimeInterval = 20 * 3600
    static let maxTries = 3
    /// A restart that takes longer than this wasn't the quiet kind: the launch is an ordinary one.
    static let handoffFresh: TimeInterval = 600

    /// Whether `version` may be downloaded or installed now: not after three failures,
    /// and not within most of a day of the last one. A clock that went backwards waits too.
    func mayTry(_ version: String, now: Date) -> Bool {
        guard let failure, failure.version == version else { return true }
        if failure.count >= Self.maxTries { return false }
        return abs(now.timeIntervalSince(failure.last)) >= Self.retryAfter
    }

    /// A download, a check or the swap for `version` didn't work.
    mutating func failed(_ version: String, now: Date) {
        if let f = failure, f.version == version {
            failure = Failure(version: version, count: min(f.count + 1, Self.maxTries), last: now)
        } else {
            failure = Failure(version: version, count: 1, last: now)
        }
    }

    enum Launch: Equatable {
        /// An ordinary launch.
        case plain
        /// Glideball restarted itself into `to` a moment ago: start quietly.
        case updated(to: String, quiet: Bool, windowOpen: Bool)
        /// The swap didn't happen and the old version is back: start quietly, count the failure.
        case swapFailed(quiet: Bool, windowOpen: Bool)
    }

    /// At launch: was this start the other half of an automatic update? Clears the
    /// handoff either way, so it's answered once. `running` is this app's version.
    mutating func launched(running: String, now: Date) -> Launch {
        guard let h = handoff else { return .plain }
        handoff = nil
        let age = now.timeIntervalSince(h.at)
        let quiet = age >= 0 && age <= Self.handoffFresh
        if running == h.to {
            failure = nil
            note = h.to
            return .updated(to: h.to, quiet: quiet, windowOpen: quiet && h.windowOpen)
        }
        failed(h.to, now: now)
        return .swapFailed(quiet: quiet, windowOpen: quiet && h.windowOpen)
    }

    static func load(from defaults: UserDefaults = .standard) -> AutoUpdateLedger {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= 4096,
              let ledger = try? JSONDecoder().decode(AutoUpdateLedger.self, from: data) else { return AutoUpdateLedger() }
        return ledger
    }

    func save(to defaults: UserDefaults = .standard) {
        if self == AutoUpdateLedger() {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// What to do about the staged copy after a check, given what the check offers.
struct AutoUpdatePlan: Equatable {
    /// Throw away the staged copy (and stop a background download).
    var discard = false
    /// Download and check this version in the background.
    var fetch: String?

    /// - `offered`: the newest version the check found for this person's channel, if it's newer than `running`.
    /// - `staged`: the version downloaded, checked and waiting; `fetching`: one being downloaded now.
    static func next(enabled: Bool, offered: String?, hasDownload: Bool, running: String,
                     staged: String?, fetching: String?, ledger: AutoUpdateLedger, now: Date) -> AutoUpdatePlan {
        let have = staged ?? fetching
        // Off, nothing offered any more (a release pulled, Early updates switched off),
        // or what's offered isn't newer than what's running: nothing is kept.
        guard enabled, let offered, UpdateChecker.isNewer(offered, than: running) else {
            return AutoUpdatePlan(discard: have != nil)
        }
        if have == offered { return AutoUpdatePlan() }
        // Something else is offered now (usually a newer one): the old copy goes, and
        // the offered one is fetched if it may be.
        let wanted = hasDownload && ledger.mayTry(offered, now: now)
        return AutoUpdatePlan(discard: have != nil, fetch: wanted ? offered : nil)
    }

    /// Whether a staged `version` may still be installed over `running`: only ever a newer one.
    static func mayInstall(staged version: String, running: String, ledger: AutoUpdateLedger, now: Date) -> Bool {
        UpdateChecker.isNewer(version, than: running) && GlideVersion(running) != nil && ledger.mayTry(version, now: now)
    }
}
