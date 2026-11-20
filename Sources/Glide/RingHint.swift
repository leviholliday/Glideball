import Foundation
import Observation

/// "You don't need the ring for this": the one mastery hint (idea 8 in
/// 2026-11-19-delight-research).
///
/// Someone whose ring is set to show right away, and who keeps choosing before it has
/// finished appearing, already knows where everything is. Blind picks are several times
/// faster, and After a pause gives them that without taking the ring away: a quick roll just
/// happens, and the ring still comes if they wait. Most people won't find that switch alone,
/// so Glideball says it once, in place: on the Buttons page, under that button's "Show the
/// ring", with one button that makes the change. It's never a notification, and once it's
/// been acted on or dismissed it never shows again on this Mac.
///
/// What it keeps: the last `window` picks on right-away rings, each only as "early or not",
/// in memory (gone when Glideball quits), and one flag in this Mac's UserDefaults saying the
/// hint is done. Neither is in the settings, so neither is in a settings file, a backup,
/// sync, a share or a setup code; the opt-in stats and crash reports never read them; nothing
/// is logged. Main thread only, like `AppModel`.
@Observable
final class RingHint {
    /// The hint has been acted on or dismissed: never again on this Mac.
    static let doneKey = "GlideRingHintDone"
    /// "Keeps choosing": this many of the last `window` picks were early.
    static let window = 12
    static let needed = 9

    /// The buttons (sorted) of the hold that tipped it: the hint shows under that gesture's
    /// "Show the ring" while it's still set to Right away.
    private(set) var offeredFor: [Int]?
    private(set) var done: Bool
    @ObservationIgnored private var recent: [Bool] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        done = defaults.bool(forKey: Self.doneKey)
    }

    /// A place on a right-away ring ran at the release. `early`: before the ring had finished
    /// appearing (`Engine.WheelFlash.early`).
    func saw(early: Bool, buttons: [Int]) {
        guard !done, offeredFor == nil else { return }
        recent.append(early)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        guard recent.count == Self.window, recent.filter({ $0 }).count >= Self.needed else { return }
        offeredFor = buttons.sorted()
        recent = []
    }

    /// Whether to say it under this gesture's "Show the ring".
    func shows(for buttons: [Int], gesture: ButtonGesture) -> Bool {
        !done && gesture.show == .atOnce && offeredFor == buttons.sorted()
    }

    /// Acted on (the button, or the choice changed by hand) or dismissed: that was the once.
    func finish() {
        guard !done else { return }
        done = true
        offeredFor = nil
        recent = []
        defaults.set(true, forKey: Self.doneKey)
    }

    /// How many picks it's holding (the self-test checks they go nowhere).
    var held: Int { recent.count }
}
