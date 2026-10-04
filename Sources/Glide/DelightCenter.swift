import AppKit
import Observation

/// Runs milestones, personal records and the "Make it yours" checklist, and
/// stages their celebrations: a glass toast, a short confetti burst, and —
/// only if you turn it on — a soft sound.
///
/// It does no work of its own between ticks: `AppModel` calls `tick` about
/// once a second while the window is on screen, and not at all when it's
/// closed. Peaks are kept by `Telemetry` meanwhile, so nothing is missed.
@Observable
final class DelightCenter {
    // MARK: Settings (per Mac)

    static let celebrationsKey = "GlideCelebrations"
    static let soundsKey = "GlideCelebrationSounds"
    static let ledgerKey = "GlideDelightLedger"

    /// Toasts and confetti for milestones and records. On by default.
    var celebrationsOn: Bool {
        didSet { defaults.set(celebrationsOn, forKey: Self.celebrationsKey) }
    }
    /// A soft chime with celebrations. Off by default.
    var soundsOn: Bool {
        didSet {
            defaults.set(soundsOn, forKey: Self.soundsKey)
            if soundsOn && !oldValue { play(.step) }   // a preview of how quiet it is
        }
    }

    // MARK: What the UI reads

    private(set) var ledger: DelightLedger
    /// Everything counted on this Mac, today included.
    private(set) var lifetime = Tally()
    private(set) var today = Tally()
    /// The best earlier day for each metric, and when it was.
    private(set) var pastBest = Tally()
    private(set) var pastBestDay: [Metric: Date] = [:]
    /// Days before today with any activity.
    private(set) var historyDays = 0
    private(set) var firstDay: Date?
    /// The last seven days, oldest first; the last one is today.
    private(set) var week: [DayPoint] = []
    /// A confetti burst on screen right now.
    private(set) var burst: Burst?
    /// Shows "Saved" briefly after settings stop changing.
    private(set) var showSaved = false

    struct DayPoint: Identifiable, Equatable {
        let id: String      // day key
        let date: Date
        var tally: Tally
        let isToday: Bool
    }

    struct Burst: Identifiable, Equatable {
        let id = UUID()
        let hues: [Double]
    }

    // MARK: Plumbing

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var past: [String: Tally] = [:]
    @ObservationIgnored private var pastSum = Tally()
    @ObservationIgnored private var dayKey = DelightCenter.key(for: Date())
    @ObservationIgnored private var savedWork: DispatchWorkItem?
    @ObservationIgnored private var lastCelebration = Date.distantPast
    /// Where toasts go. Set by AppModel.
    @ObservationIgnored var present: ((AppModel.Toast) -> Void)?
    /// Whether a moment is a good time to celebrate (not mid-tour).
    @ObservationIgnored var canCelebrate: () -> Bool = { true }

    static let totalsPrefix = "GlideTotals-"

    /// Same format AppModel uses for its daily totals keys.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { totalsPrefix + dayFormatter.string(from: date) }

    static func date(forKey key: String) -> Date? {
        dayFormatter.date(from: String(key.dropFirst(totalsPrefix.count)))
    }

    init(defaults: UserDefaults = .standard, config: GlideConfig) {
        self.defaults = defaults
        celebrationsOn = defaults.object(forKey: Self.celebrationsKey) as? Bool ?? true
        soundsOn = defaults.bool(forKey: Self.soundsKey)
        if let data = defaults.data(forKey: Self.ledgerKey),
           let saved = try? JSONDecoder().decode(DelightLedger.self, from: data) {
            ledger = saved
        } else {
            var fresh = DelightLedger()
            fresh.seedChecklist(from: config)
            ledger = fresh
        }
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }

    // MARK: History

    /// Re-reads the saved daily totals. `currentKey` is the day being counted
    /// live, which is left out so it isn't counted twice.
    func reloadHistory(currentKey: String) {
        dayKey = currentKey
        var days: [String: Tally] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.totalsPrefix) && key != currentKey {
            guard let d = value as? [String: Any] else { continue }
            let t = Tally(clicks: d["clicks"] as? Int ?? 0,
                          ballCounts: d["ball"] as? Double ?? 0,
                          scrollPoints: d["scroll"] as? Double ?? 0)
            if !t.isEmpty { days[key] = t }
        }
        past = days
        pastSum = days.values.reduce(Tally(), +)
        historyDays = days.count
        firstDay = days.keys.min().flatMap(Self.date(forKey:))

        var best = Tally()
        var bestDay: [Metric: Date] = [:]
        for (key, t) in days {
            for m in Metric.allCases where t.value(m) > best.value(m) {
                switch m {
                case .clicks: best.clicks = t.clicks
                case .ball: best.ballMeters = t.ballMeters
                case .scroll: best.scrollMeters = t.scrollMeters
                }
                bestDay[m] = Self.date(forKey: key)
            }
        }
        pastBest = best
        pastBestDay = bestDay
        rebuildWeek()
    }

    private func rebuildWeek() {
        let cal = Calendar.current
        let now = Date()
        week = (0..<7).reversed().compactMap { back -> DayPoint? in
            guard let date = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now)) else { return nil }
            let key = Self.key(for: date)
            let isToday = back == 0
            return DayPoint(id: key, date: date, tally: isToday ? today : (past[key] ?? Tally()), isToday: isToday)
        }
    }

    // MARK: Ticks

    /// Folds in the latest counters. Called about once a second while the window is visible.
    func tick(totals: Telemetry.Totals, peaks: Telemetry.Peaks, now: Date = Date()) {
        let t = Tally(clicks: totals.clicks, ballCounts: totals.ballCounts, scrollPoints: totals.scrollPoints)
        if t != today {
            today = t
            if let last = week.indices.last, week[last].isToday { week[last].tally = t }
        }
        let life = pastSum + t
        if life != lifetime { lifetime = life }

        let before = ledger
        let events = ledger.evaluate(lifetime: life, today: t, pastBest: pastBest, historyDays: historyDays,
                                     peaks: peaks, dayKey: dayKey, now: now)
        if ledger != before { saveLedger() }
        celebrate(events)
    }

    // MARK: Settings changes

    /// Called with every local settings change.
    func configChanged(from old: GlideConfig, to new: GlideConfig) {
        let events = ledger.complete(ChecklistItem.completed(from: old, to: new))
        if !events.isEmpty {
            saveLedger()
            // Let the change itself land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.celebrate(events) }
        }

        // "Saved" once things settle — not for the pause switch, which shows itself.
        var a = old, b = new
        a.enabled = true; b.enabled = true
        guard a != b else { return }
        savedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.showSaved = false }
        }
        savedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func dismissChecklist() {
        ledger.checklistDismissed = true
        saveLedger()
    }

    var checklistVisible: Bool { !ledger.checklistDismissed }

    // MARK: Celebrating

    private func celebrate(_ events: [DelightEvent]) {
        guard let top = events.max(by: { $0.priority < $1.priority }) else { return }
        guard celebrationsOn, canCelebrate() else { return }
        let more = events.count - 1

        var toast = AppModel.Toast(symbol: symbol(for: top), text: title(for: top), celebration: true)
        var detail = self.detail(for: top)
        if more > 0 {
            detail = [detail, String(localized: "+\(more) more on Overview", comment: "More celebrations to see on the Overview tab")]
                .compactMap { $0 }.joined(separator: " · ")
        }
        toast.detail = detail
        present?(toast)

        let now = Date()
        // Never stack bursts: one every few seconds at most.
        if top.isBig, now.timeIntervalSince(lastCelebration) > 4 {
            lastCelebration = now
            let b = Burst(hues: hues(for: top))
            burst = b
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                if self?.burst?.id == b.id { self?.burst = nil }
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        play(top.isBig ? .big : .step)
    }

    private enum Chime { case big, step }

    private func play(_ chime: Chime) {
        guard soundsOn else { return }
        let sound = NSSound(named: chime == .big ? "Glass" : "Pop")
        sound?.volume = chime == .big ? 0.35 : 0.25
        sound?.play()
    }

    private func title(for e: DelightEvent) -> String {
        switch e {
        case .milestone(let m): String(localized: "Milestone: \(m.title)", comment: "%@ is a badge name")
        case .dayRecord(let m, _):
            switch m {
            case .scroll: String(localized: "Your biggest scrolling day yet")
            case .ball: String(localized: "Your most-rolled day yet")
            case .clicks: String(localized: "Your clickiest day yet")
            }
        case .record(let k, _): k.newRecordTitle
        case .checklistStep(let item): item.doneTitle
        case .checklistDone: String(localized: "Glide is all yours")
        case .welcome(let n): String(localized: "Glide now keeps your records — \(n) badges already earned")
        }
    }

    private func detail(for e: DelightEvent) -> String? {
        switch e {
        case .milestone(let m): m.detail
        case .dayRecord(let m, let v): String(localized: "\(m.format(v)) today", comment: "%@ is an amount: 1,234 or 12.3 m")
        case .record(let k, let v): k.format(v)
        case .checklistStep:
            String(localized: "\(ledger.checklist.count) of \(ChecklistItem.allCases.count) on Make it yours",
                   comment: "“Make it yours” is the setup checklist on Overview")
        case .checklistDone: String(localized: "Every part of your trackball, set up your way.")
        case .welcome: String(localized: "See them on Overview")
        }
    }

    private func symbol(for e: DelightEvent) -> String {
        switch e {
        case .milestone(let m): m.symbol
        case .dayRecord: "chart.line.uptrend.xyaxis"
        case .record(let k, _): k.symbol
        case .checklistStep: "checkmark.circle.fill"
        case .checklistDone: "sparkles"
        case .welcome: "trophy.fill"
        }
    }

    /// Confetti colors, roughly matching what was celebrated.
    private func hues(for e: DelightEvent) -> [Double] {
        switch e {
        case .milestone(let m): Self.hues(for: m.metric)
        case .dayRecord(let m, _): Self.hues(for: m)
        default: [0.52, 0.78, 0.9, 0.14]
        }
    }

    static func hues(for m: Metric) -> [Double] {
        switch m {
        case .scroll: [0.92, 0.85, 0.78, 0.14]
        case .ball: [0.52, 0.58, 0.72, 0.14]
        case .clicks: [0.5, 0.42, 0.78, 0.14]
        }
    }
}
