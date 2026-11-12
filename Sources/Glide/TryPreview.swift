import AppKit
import Observation
import SwiftUI

/// "Try before you change": a value that applies for ten seconds and then goes
/// back to what it was, unless you click Keep (or press Return). Esc goes back
/// straight away. Hold ⌥ while dragging a tuning slider (or click its Try
/// button first), or ⌥-click a preset or scroll mode card (or "Try for 10 s"
/// in its menu).
///
/// The value applies live exactly as a normal change does; this only remembers
/// what to put back. Only one preview at a time: starting another puts the
/// first one back. Pausing, unplugging the trackball or quitting during a preview puts
/// the old value back (`AppDelegate.applicationWillTerminate` calls `revert`).
///
/// Costs nothing when no preview is running: the timer and the key monitor
/// exist only during one.
@Observable
final class TryPreview {
    static let shared = TryPreview()
    static let seconds: TimeInterval = 10

    struct Session: Equatable {
        /// The row or card strip it belongs to (where its countdown shows).
        let id: String
        /// What's being tried, for the countdown's words ("Turbo", "12.5").
        var what: String
        /// What it goes back to, in the same words ("5.5").
        let was: String
        /// When it goes back; nil while the value's still being chosen (mid-drag).
        var deadline: Date?
    }

    private(set) var session: Session?
    /// Bumped when a preview ends by going back, so its row can play a small "back" moment.
    private(set) var revertCount = 0
    /// The self-test: how the last one ended.
    @ObservationIgnored private(set) var lastEnding: Ending?

    enum Ending: Equatable { case kept, timedOut, cancelled, paused, unplugged, quit, replaced }

    @ObservationIgnored private var restore: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keys: Any?
    @ObservationIgnored private var wasEnabled = true
    @ObservationIgnored private var wasConnected = true
    /// What the self-test watches instead of the real model.
    @ObservationIgnored var conditions: () -> (enabled: Bool, connected: Bool) = {
        (AppModel.shared.config.enabled, AppModel.shared.status.deviceConnected)
    }

    var isActive: Bool { session != nil }
    func isTrying(_ id: String) -> Bool { session?.id == id }

    /// Starts a preview for `id`: `restore` puts the value back. `was` and `what`
    /// are its old and new values in words. With `countdown`, the ten seconds start
    /// now (a card); without, they start at `startCountdown` (a slider, when it's let go).
    /// Another preview that's running goes back first.
    func begin(id: String, was: String, what: String = "", countdown: Bool, restore: @escaping () -> Void) {
        if let s = session {
            if s.id == id {
                // The same row again (dragging once more): keep the original value, wait for the release.
                session?.deadline = countdown ? Date().addingTimeInterval(Self.seconds) : nil
                if !what.isEmpty { session?.what = what }
                return
            }
            // Something else is being tried: that one goes back first, so only one thing is ever on trial.
            end(.replaced, putBack: true)
        }
        let (enabled, connected) = conditions()
        wasEnabled = enabled
        wasConnected = connected
        self.restore = restore
        session = Session(id: id, what: what, was: was, deadline: countdown ? Date().addingTimeInterval(Self.seconds) : nil)
        lastEnding = nil
        startWatching()
    }

    /// The slider was let go: ten seconds from now it goes back.
    func startCountdown(id: String, what: String) {
        guard session?.id == id else { return }
        session?.what = what
        session?.deadline = Date().addingTimeInterval(Self.seconds)
    }

    /// The value changed again mid-drag (the countdown waits for the release).
    func update(id: String, what: String) {
        guard session?.id == id, session?.what != what else { return }
        session?.what = what
    }

    /// Keep: the tried value stays.
    func keep() {
        guard session != nil else { return }
        end(.kept, putBack: false)
        Sounds.shared.detent(pitch: 1.2, volume: 0.4)
    }

    /// Go back now (Esc, the Go back button).
    func cancel() { revert(.cancelled) }

    /// Puts the old value back, if a preview is running. Quit, pause and unplug come here too.
    func revert(_ why: Ending = .cancelled) {
        guard session != nil else { return }
        end(why, putBack: true)
    }

    private func end(_ why: Ending, putBack: Bool) {
        let undo = restore
        restore = nil
        timer?.invalidate()
        timer = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        session = nil
        lastEnding = why
        if putBack {
            withAnimation(Theme.Motion.spring) { undo?() }
            revertCount &+= 1
            if why != .quit { Sounds.shared.detent(pitch: 0.85, volume: 0.35) }
        }
    }

    // MARK: While one runs

    private func startWatching() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        guard !Sandbox.isActive else { return }
        // Return keeps, Esc goes back: in Glideball's own windows, while the ten seconds run
        // (not while something's being typed, or the search palette has the keys).
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.session?.deadline != nil, !CommandPalette.shared.isOpen,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return e }
            switch Self.key(e.keyCode) {
            case .keep?: self.keep(); return nil
            case .cancel?: self.cancel(); return nil
            case nil: return e
            }
        }
    }

    enum Key { case keep, cancel }

    /// Return and Enter keep, Esc goes back; nothing else answers.
    nonisolated static func key(_ code: UInt16) -> Key? {
        switch code {
        case 36, 76: .keep
        case 53: .cancel
        default: nil
        }
    }

    /// Pause, unplug, or the time's up.
    func check(now: Date = Date()) {
        guard let s = session else { return }
        let (enabled, connected) = conditions()
        if wasEnabled && !enabled { return revert(.paused) }
        if wasConnected && !connected { return revert(.unplugged) }
        wasEnabled = enabled
        wasConnected = connected
        if let deadline = s.deadline, now >= deadline { revert(.timedOut) }
    }
}

// MARK: - The hint

/// "Hold ⌥ while dragging to try a value for 10 seconds": shown under a slider
/// while it's dragged, the first few times only, then never again.
enum TryHint {
    static let countKey = "GlideTryHintShown"
    static let times = 4

    static var due: Bool { UserDefaults.standard.integer(forKey: countKey) < times }
    static func shown() { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: countKey) + 1, forKey: countKey) }
    static func done() { UserDefaults.standard.set(times, forKey: countKey) }
}

// MARK: - The countdown

/// Under a row while its preview runs: a ring running down the ten seconds,
/// what's being tried and what it goes back to, Go back and Keep.
struct TryBar: View {
    let session: TryPreview.Session
    var tint: Color = Theme.ball
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Renders: draw the ring this far through (there's no clock in a picture).
    nonisolated(unsafe) static var sandboxRemaining: Double?

    var body: some View {
        HStack(spacing: 10) {
            CountdownRing(deadline: session.deadline, tint: tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.what.isEmpty ? String(localized: "Trying it", comment: "Try for 10 s: the countdown's title, no value known")
                                          : String(localized: "Trying \(session.what)", comment: "Try for 10 s: the countdown's title; %@ is a value or a preset's name"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(session.deadline == nil
                     ? String(localized: "Let go to start the 10 seconds.", comment: "Try for 10 s, while the slider is still held")
                     : String(localized: "Goes back to \(session.was) unless you keep it.", comment: "Try for 10 s; %@ is the old value"))
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Go Back") { TryPreview.shared.cancel() }
                .controlSize(.small)
                .help("Put the old value back now (Esc)")
            Button("Keep") { TryPreview.shared.keep() }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.small)
                .help("Keep this value (Return)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
        .accessibilityElement(children: .contain)
    }
}

/// The ten seconds as a ring that empties, with the seconds left in the middle.
private struct CountdownRing: View {
    let deadline: Date?
    let tint: Color

    var body: some View {
        if let deadline, TryBar.sandboxRemaining == nil {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                ring(remaining: max(0, deadline.timeIntervalSince(context.date)))
            }
        } else {
            ring(remaining: TryBar.sandboxRemaining ?? TryPreview.seconds)
        }
    }

    private func ring(remaining: Double) -> some View {
        let f = remaining / TryPreview.seconds
        return ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: f)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.6), radius: 3)
            Text(verbatim: "\(Int(remaining.rounded(.up)))")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Int(remaining.rounded(.up))) seconds left", comment: "Try for 10 s: VoiceOver reads the countdown"))
    }
}
