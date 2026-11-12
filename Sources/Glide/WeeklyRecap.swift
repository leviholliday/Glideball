import Foundation
import Observation

/// A look back at one week (Monday to Sunday): its clicks, ball and scroll
/// distance against the week before, the busiest day, badges earned in it, and
/// a real-world comparison. Made from the daily totals Glideball already keeps
/// on this Mac (`GlideTotals-yyyy-MM-dd`, kept forever) and the badges' dates;
/// nothing new is stored but which week was last shown.
struct WeeklyRecap: Equatable {
    /// Monday, at the start of the day.
    let start: Date
    /// Monday to Sunday.
    let days: [Tally]
    let total: Tally
    /// The week before it.
    let before: Tally
    /// Badges earned during the week, in the order they were earned.
    let newBadges: [String]

    var end: Date { Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start }

    /// The day with the most going on: clicks, plus the distances weighed so
    /// that a typical day's worth of each counts about the same.
    var busiestDay: (date: Date, tally: Tally)? {
        let scored = days.enumerated().map { i, t in (i, t, Double(t.clicks) / 2_000 + t.ballMeters / 40 + t.scrollMeters / 60) }
        guard let best = scored.max(by: { $0.2 < $1.2 }), best.2 > 0 else { return nil }
        return (Calendar.current.date(byAdding: .day, value: best.0, to: start) ?? start, best.1)
    }

    /// Days with something worth counting (the same bar as day records use).
    var activeDays: Int { days.filter(WeeklyRecap.realDay).count }

    /// "Real use": at least two days with a meaningful amount done.
    var hadRealUse: Bool { activeDays >= 2 }

    static func realDay(_ t: Tally) -> Bool {
        Metric.allCases.contains { t.value($0) >= DelightLedger.meaningfulDay($0) }
    }

    /// How this week compares for one part: up, about the same, down, or nothing to compare with.
    enum Change: Equatable {
        case up(Double), same, down, noBefore
    }

    func change(_ m: Metric) -> Change {
        let now = total.value(m), was = before.value(m)
        guard was >= DelightLedger.meaningfulDay(m) else { return .noBefore }
        let ratio = now / was
        if ratio >= 1.05 { return .up(ratio - 1) }
        if ratio > 0.95 { return .same }
        return .down
    }

    /// The more fun of the two distance comparisons ("≈ 1.4 × the Eiffel Tower").
    var comparison: (metric: Metric, text: String)? {
        let options: [Metric] = total.scrollMeters >= total.ballMeters ? [.scroll, .ball] : [.ball, .scroll]
        for m in options {
            if let text = Landmarks.compare(total.value(m), metric: m) { return (m, text) }
        }
        return nil
    }

    // MARK: Making one

    /// Weeks start on Monday here, whatever the region says, so "on or after Monday" means one thing.
    static var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    static func weekStart(containing date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The recap of the week starting `start`, from each day's totals and the badges' dates.
    static func make(start: Date, tally: (Date) -> Tally, earned: [String: Date]) -> WeeklyRecap {
        let cal = calendar
        let days = (0..<7).map { tally(cal.date(byAdding: .day, value: $0, to: start) ?? start) }
        let beforeStart = cal.date(byAdding: .day, value: -7, to: start) ?? start
        let before = (0..<7).map { tally(cal.date(byAdding: .day, value: $0, to: beforeStart) ?? start) }.reduce(Tally(), +)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        let badges = earned.filter { $0.value >= start && $0.value < end }
            .sorted { $0.value < $1.value }
            .map(\.key)
            .filter { id in Milestone.all.contains { $0.id == id } }
        return WeeklyRecap(start: start, days: days, total: days.reduce(Tally(), +), before: before, newBadges: badges)
    }
}

/// When the recap shows, and the switch for it (Settings › Look › Weekly recap).
///
/// The rule: once a week, the first time the window opens on or after Monday,
/// only if the week before was really used (two days or more with a real
/// amount done), never as a notification, and only when nothing else is over
/// the window (`AppModel.nextPrompt`: What's New, then the new icon, then
/// this, then the small favor). It's never stacked and never repeated: missing
/// a week just skips it. Overview's "Last week" opens it any time.
@Observable
final class RecapCenter {
    static let shared = RecapCenter()
    static let enabledKey = "GlideWeeklyRecap"
    static let seenKey = "GlideRecapSeenWeek"

    /// On by default.
    var enabled: Bool = UserDefaults.standard.object(forKey: RecapCenter.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// The recap over the window, when one is.
    var showing: WeeklyRecap?
    /// It came by itself (once a week) rather than from "Last week": the small payoff sound plays.
    @ObservationIgnored private(set) var cameByItself = false

    enum Week { case lastWeek, thisWeek }

    /// The recap of last week (or this one so far), or nil when there's nothing at all to show.
    func recap(for week: Week, _ delight: DelightCenter, now: Date = Date()) -> WeeklyRecap? {
        let thisWeek = WeeklyRecap.weekStart(containing: now)
        let start = week == .thisWeek ? thisWeek : WeeklyRecap.calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
        let recap = WeeklyRecap.make(start: start, tally: delight.tally(on:), earned: delight.ledger.earned)
        return recap.total.isEmpty ? nil : recap
    }

    static func weekKey(_ start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    /// The pure rule (the self-test checks it).
    nonisolated static func isDue(enabled: Bool, seenWeek: String?, lastWeek: String, hadRealUse: Bool) -> Bool {
        enabled && hadRealUse && seenWeek != lastWeek
    }

    /// Last week's recap, if it's its turn.
    func due(_ delight: DelightCenter, now: Date = Date()) -> WeeklyRecap? {
        guard enabled, let recap = recap(for: .lastWeek, delight, now: now) else { return nil }
        let due = Self.isDue(enabled: enabled, seenWeek: UserDefaults.standard.string(forKey: Self.seenKey),
                             lastWeek: Self.weekKey(recap.start), hadRealUse: recap.hadRealUse)
        return due ? recap : nil
    }

    /// Shows it: by itself (its turn) or asked for.
    func show(_ recap: WeeklyRecap, byItself: Bool) {
        UserDefaults.standard.set(Self.weekKey(recap.start), forKey: Self.seenKey)
        cameByItself = byItself
        showing = recap
    }

    func close() { showing = nil }
}

extension AppModel {
    /// Overview's "Last week", or the search palette: the recap, whenever it's asked for.
    func showRecap() {
        let center = RecapCenter.shared
        guard let recap = center.recap(for: .lastWeek, delight) ?? center.recap(for: .thisWeek, delight) else { return }
        // Asked for by hand: a card already up steps aside and comes back another time.
        showingSmallFavor = false
        showingIconChoice = false
        showingWhatsNew = false
        center.show(recap, byItself: false)
    }
}
