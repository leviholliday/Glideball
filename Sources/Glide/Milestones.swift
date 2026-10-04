import Foundation

// Milestones, personal records and the "Make it yours" checklist — the logic
// only (no UI), so it can be checked on its own. `DelightCenter` runs it and
// `DelightViews.swift` draws it.
//
// The rules that keep this honest:
// - Everything celebrated is real: it comes from the trackball's own counters.
// - Each milestone fires once, ever. Records fire at most once a day each.
// - Nothing is celebrated during the first two days (records are still
//   settling), and nothing ever nags, counts down or asks you to come back.

/// What Glide counts.
enum Metric: String, CaseIterable, Identifiable, Codable {
    case scroll, ball, clicks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scroll: "Scrolled"
        case .ball: "Ball rolled"
        case .clicks: "Clicks"
        }
    }

    var symbol: String {
        switch self {
        case .scroll: "scroll"
        case .ball: "circle.dotted.circle"
        case .clicks: "cursorarrow.click.2"
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .clicks: Int(v.rounded()).formatted()
        case .scroll, .ball: Tally.distance(v)
        }
    }
}

/// A day's — or a lifetime's — activity in the units people read.
struct Tally: Equatable {
    var clicks = 0
    var ballMeters = 0.0
    var scrollMeters = 0.0

    /// Points scrolled → metres. Matches the Overview tiles.
    static let metersPerScrollPoint = 0.00023
    /// Sensor counts → metres of ball surface (≈400 counts per inch).
    static let metersPerBallCount = 0.0254 / 400

    init(clicks: Int = 0, ballMeters: Double = 0, scrollMeters: Double = 0) {
        self.clicks = clicks
        self.ballMeters = ballMeters
        self.scrollMeters = scrollMeters
    }

    init(clicks: Int, ballCounts: Double, scrollPoints: Double) {
        self.init(clicks: clicks,
                  ballMeters: ballCounts * Self.metersPerBallCount,
                  scrollMeters: scrollPoints * Self.metersPerScrollPoint)
    }

    func value(_ m: Metric) -> Double {
        switch m {
        case .scroll: scrollMeters
        case .ball: ballMeters
        case .clicks: Double(clicks)
        }
    }

    static func + (a: Tally, b: Tally) -> Tally {
        Tally(clicks: a.clicks + b.clicks, ballMeters: a.ballMeters + b.ballMeters,
              scrollMeters: a.scrollMeters + b.scrollMeters)
    }

    var isEmpty: Bool { clicks == 0 && ballMeters < 0.01 && scrollMeters < 0.01 }

    static func distance(_ m: Double) -> String {
        if m < 1 { return String(format: "%.0f cm", m * 100) }
        if m < 100 { return String(format: "%.1f m", m) }
        if m < 1000 { return String(format: "%.0f m", m) }
        if m < 100_000 { return String(format: "%.2f km", m / 1000) }
        return String(format: "%.0f km", m / 1000)
    }

    /// For goals and axis labels: "93 m", "1 km", "42.2 km".
    static func shortDistance(_ m: Double) -> String {
        if m < 1000 { return "\(Int(m.rounded())) m" }
        let km = m / 1000
        return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }
}

// MARK: - Milestones

struct Milestone: Identifiable, Equatable {
    let id: String
    let metric: Metric
    let threshold: Double
    let title: String
    let detail: String
    let symbol: String

    static let all: [Milestone] = [
        .init(id: "scroll-10", metric: .scroll, threshold: 10, title: "First ten metres",
              detail: "Scrolled 10 m", symbol: "arrow.down.to.line"),
        .init(id: "scroll-93", metric: .scroll, threshold: 93, title: "Lady Liberty",
              detail: "Scrolled the height of the Statue of Liberty (93 m)", symbol: "building.columns"),
        .init(id: "scroll-330", metric: .scroll, threshold: 330, title: "Eiffel Tower",
              detail: "Scrolled the height of the Eiffel Tower (330 m)", symbol: "building.2"),
        .init(id: "scroll-1k", metric: .scroll, threshold: 1_000, title: "First kilometre",
              detail: "Scrolled 1 km", symbol: "flag"),
        .init(id: "scroll-8849", metric: .scroll, threshold: 8_849, title: "Summit",
              detail: "Scrolled the height of Everest (8,849 m)", symbol: "mountain.2"),
        .init(id: "scroll-42k", metric: .scroll, threshold: 42_195, title: "Scroll marathon",
              detail: "Scrolled a marathon (42.2 km)", symbol: "medal"),

        .init(id: "ball-10", metric: .ball, threshold: 10, title: "Rolling",
              detail: "Rolled the ball 10 m", symbol: "circle.circle"),
        .init(id: "ball-100", metric: .ball, threshold: 100, title: "Pitch length",
              detail: "Rolled the length of a football pitch (100 m)", symbol: "sportscourt"),
        .init(id: "ball-400", metric: .ball, threshold: 400, title: "One lap",
              detail: "Rolled one lap of a running track (400 m)", symbol: "figure.run"),
        .init(id: "ball-1k", metric: .ball, threshold: 1_000, title: "Kilometre roller",
              detail: "Rolled the ball 1 km", symbol: "flag.checkered"),
        .init(id: "ball-10k", metric: .ball, threshold: 10_000, title: "10K",
              detail: "Rolled the ball 10 km", symbol: "medal"),
        .init(id: "ball-42k", metric: .ball, threshold: 42_195, title: "Ball marathon",
              detail: "Rolled a marathon (42.2 km)", symbol: "trophy"),

        .init(id: "clicks-100", metric: .clicks, threshold: 100, title: "Warmed up",
              detail: "100 clicks", symbol: "hand.tap"),
        .init(id: "clicks-1k", metric: .clicks, threshold: 1_000, title: "A thousand clicks",
              detail: "1,000 clicks", symbol: "cursorarrow.click"),
        .init(id: "clicks-10k", metric: .clicks, threshold: 10_000, title: "Ten thousand",
              detail: "10,000 clicks", symbol: "cursorarrow.click.2"),
        .init(id: "clicks-100k", metric: .clicks, threshold: 100_000, title: "Click legend",
              detail: "100,000 clicks", symbol: "star.circle"),
        .init(id: "clicks-1m", metric: .clicks, threshold: 1_000_000, title: "One million",
              detail: "1,000,000 clicks", symbol: "crown"),
    ]
}

// MARK: - Real-world comparisons

enum Landmarks {
    private struct Landmark { let name: String; let meters: Double }

    private static let heights: [Landmark] = [
        .init(name: "the Statue of Liberty", meters: 93),
        .init(name: "the Eiffel Tower", meters: 330),
        .init(name: "the Empire State Building", meters: 443),
        .init(name: "the Burj Khalifa", meters: 828),
        .init(name: "Mount Everest", meters: 8_849),
    ]
    private static let lengths: [Landmark] = [
        .init(name: "a football pitch", meters: 105),
        .init(name: "a running-track lap", meters: 400),
        .init(name: "the Golden Gate Bridge", meters: 2_737),
        .init(name: "a marathon", meters: 42_195),
    ]

    /// "≈ 3.2 × the Eiffel Tower", "40% of the way up the Statue of Liberty"…
    static func compare(_ meters: Double, metric: Metric) -> String? {
        let list: [Landmark]
        switch metric {
        case .scroll: list = heights
        case .ball: list = lengths
        case .clicks: return nil
        }
        guard meters >= 1, let smallest = list.first else { return nil }
        if meters < smallest.meters {
            let pct = Int((meters / smallest.meters * 100).rounded(.down))
            return metric == .scroll ? "\(pct)% of the way up \(smallest.name)" : "\(pct)% of \(smallest.name)"
        }
        let mark = list.last { $0.meters <= meters } ?? smallest
        let ratio = meters / mark.meters
        if ratio < 1.1 { return metric == .scroll ? "The height of \(mark.name)" : "The length of \(mark.name)" }
        let times = ratio < 10 ? String(format: "%.1f", ratio) : Int(ratio).formatted()
        return "≈ \(times) × \(mark.name)"
    }
}

// MARK: - Personal records

enum RecordKind: String, CaseIterable, Identifiable, Codable {
    case spin, flick, roll
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spin: "Fastest ring spin"
        case .flick: "Longest single scroll"
        case .roll: "Fastest roll"
        }
    }

    var symbol: String {
        switch self {
        case .spin: "arrow.trianglehead.2.clockwise.rotate.90"
        case .flick: "arrow.down.forward.and.arrow.up.backward"
        case .roll: "hare"
        }
    }

    /// Records below this aren't worth a fanfare when beaten.
    var meaningful: Double {
        switch self {
        case .spin: 10      // notches / s
        case .flick: 0.5    // m
        case .roll: 5       // in / s
        }
    }

    /// Converts telemetry peaks to the record's unit.
    static func value(_ kind: RecordKind, peaks: Telemetry.Peaks) -> Double {
        switch kind {
        case .spin: peaks.spinRate
        case .flick: peaks.flickPoints * Tally.metersPerScrollPoint
        case .roll: peaks.rollRate / 400   // counts/s → inches/s
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .spin: String(format: "%.0f notches/s", v)
        case .flick: Tally.distance(v)
        case .roll: String(format: "%.0f in/s", v)
        }
    }
}

// MARK: - Make it yours

enum ChecklistItem: String, CaseIterable, Identifiable, Codable {
    case speed, scroll, button, combo, app
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: "Set your pointer speed"
        case .scroll: "Pick how scrolling feels"
        case .button: "Map a button"
        case .combo: "Make a combo"
        case .app: "Add an app setup"
        }
    }

    var hint: String {
        switch self {
        case .speed: "Pointer tab — try a preset"
        case .scroll: "Scrolling tab — Flywheel, Follow or Native"
        case .button: "Buttons tab — Quick assign takes two presses"
        case .combo: "Buttons tab — press two buttons together"
        case .app: "Apps tab — a different feel per app"
        }
    }

    var symbol: String {
        switch self {
        case .speed: "cursorarrow.motionlines"
        case .scroll: "arrow.up.and.down.circle"
        case .button: "button.programmable"
        case .combo: "square.on.square"
        case .app: "square.grid.2x2"
        }
    }

    /// Steps a settings change completed (old → new).
    static func completed(from old: GlideConfig, to new: GlideConfig) -> Set<ChecklistItem> {
        var done = Set<ChecklistItem>()
        if old.trackingSpeed != new.trackingSpeed || old.precisionSpeed != new.precisionSpeed { done.insert(.speed) }
        if scrollSignature(old) != scrollSignature(new) { done.insert(.scroll) }
        if old.buttons != new.buttons { done.insert(.button) }
        // Compare what combos do, not their ids (every fresh config gets new ones).
        let combos = { (c: GlideConfig) in c.chords.map { "\($0.buttons)\($0.action)" } }
        if combos(old) != combos(new) && !new.chords.isEmpty { done.insert(.combo) }
        if new.appProfiles.count > old.appProfiles.count { done.insert(.app) }
        return done
    }

    /// For people who set Glide up before the checklist existed: anything
    /// that already differs from a fresh install counts as done.
    static func completed(comparedToDefaults c: GlideConfig) -> Set<ChecklistItem> {
        var done = completed(from: GlideConfig(), to: c)
        if !c.appProfiles.isEmpty { done.insert(.app) }
        return done
    }

    private static func scrollSignature(_ c: GlideConfig) -> [Double] {
        [Double(ScrollMode.allCases.firstIndex(of: c.scrollMode) ?? 0), c.nativeScrollSpeed,
         c.flyDistance, c.flyAcceleration, c.flyGlide, c.smoothScrolling ? 1 : 0, c.scrollDistance,
         c.scrollSmoothness, c.scrollAcceleration, c.throwEnabled ? 1 : 0, c.throwAmount,
         c.reverseScroll ? 1 : 0, c.ballScrollSpeed]
    }
}

// MARK: - The ledger

/// Something worth a moment of celebration.
enum DelightEvent: Equatable {
    case milestone(Milestone)
    case dayRecord(Metric, Double)
    case record(RecordKind, Double)
    case checklistStep(ChecklistItem)
    case checklistDone
    /// The first run with records: badges already earned before this existed.
    case welcome(Int)

    /// Higher shows first when several happen at once.
    var priority: Int {
        switch self {
        case .checklistDone: 6
        case .milestone(let m): 4 + (m.threshold >= 1_000 ? 1 : 0)
        case .dayRecord: 3
        case .record: 2
        case .welcome: 1
        case .checklistStep: 0
        }
    }

    /// Big moments get confetti; small ones just a toast.
    var isBig: Bool {
        switch self {
        case .milestone, .checklistDone, .dayRecord, .record: true
        case .checklistStep, .welcome: false
        }
    }
}

/// Everything Glide remembers about your milestones and records, on this Mac.
struct DelightLedger: Codable, Equatable {
    /// Milestone id → when it was earned.
    var earned: [String: Date] = [:]
    var records: [String: Double] = [:]
    var recordDates: [String: Date] = [:]
    /// Record / metric → the day ("yyyy-MM-dd") it was last celebrated.
    var celebratedOn: [String: String] = [:]
    /// When Glide started keeping records here. Nil until the first evaluation.
    var started: Date?
    var checklist: Set<ChecklistItem> = []
    var checklistDismissed = false
    var checklistCelebrated = false

    /// Records settle for this long before beating one is celebrated.
    static let settleTime: TimeInterval = 2 * 24 * 3600
    /// A record must improve by at least this much to be celebrated.
    static let recordMargin = 1.05
    /// Day records need this many earlier days to compare against.
    static let minHistoryDays = 3
    /// Day records need the old best to be at least this much.
    static func meaningfulDay(_ m: Metric) -> Double {
        switch m {
        case .clicks: 100
        case .scroll: 5
        case .ball: 5
        }
    }

    func record(_ k: RecordKind) -> Double { records[k.rawValue] ?? 0 }

    /// Folds in the latest activity and returns what's worth celebrating, best first.
    /// - Parameters:
    ///   - lifetime: everything counted on this Mac, today included.
    ///   - today: today so far.
    ///   - pastBest: the best earlier day for each metric.
    ///   - historyDays: how many earlier days have any activity.
    mutating func evaluate(lifetime: Tally, today: Tally, pastBest: Tally, historyDays: Int,
                           peaks: Telemetry.Peaks, dayKey: String, now: Date) -> [DelightEvent] {
        // First run: what's already been done is earned quietly, then acknowledged once.
        guard let started else {
            self.started = now
            var count = 0
            for m in Milestone.all where lifetime.value(m.metric) >= m.threshold {
                earned[m.id] = now
                count += 1
            }
            for k in RecordKind.allCases {
                let v = RecordKind.value(k, peaks: peaks)
                if v > 0 { records[k.rawValue] = v; recordDates[k.rawValue] = now }
            }
            // A day that's already a record when this starts isn't news a second later.
            for m in Metric.allCases where today.value(m) > pastBest.value(m) {
                celebratedOn["day-" + m.rawValue] = dayKey
            }
            return count > 0 ? [.welcome(count)] : []
        }

        var events: [DelightEvent] = []
        for m in Milestone.all where earned[m.id] == nil && lifetime.value(m.metric) >= m.threshold {
            earned[m.id] = now
            events.append(.milestone(m))
        }

        let settled = now.timeIntervalSince(started) >= Self.settleTime
        for k in RecordKind.allCases {
            let new = RecordKind.value(k, peaks: peaks)
            let old = record(k)
            guard new > old else { continue }
            records[k.rawValue] = new
            recordDates[k.rawValue] = now
            if settled, old >= k.meaningful, new >= old * Self.recordMargin,
               celebratedOn[k.rawValue] != dayKey {
                celebratedOn[k.rawValue] = dayKey
                events.append(.record(k, new))
            }
        }

        if historyDays >= Self.minHistoryDays {
            for m in Metric.allCases {
                let best = pastBest.value(m)
                let key = "day-" + m.rawValue
                if best >= Self.meaningfulDay(m), today.value(m) > best, celebratedOn[key] != dayKey {
                    celebratedOn[key] = dayKey
                    events.append(.dayRecord(m, today.value(m)))
                }
            }
        }
        return events.sorted { $0.priority > $1.priority }
    }

    /// Marks checklist steps done; returns the events for the ones that are new.
    mutating func complete(_ items: Set<ChecklistItem>) -> [DelightEvent] {
        let fresh = items.subtracting(checklist)
        guard !fresh.isEmpty else { return [] }
        checklist.formUnion(fresh)
        if checklist.count == ChecklistItem.allCases.count, !checklistCelebrated {
            checklistCelebrated = true
            return checklistDismissed ? [] : [.checklistDone]
        }
        if checklistDismissed { return [] }
        return ChecklistItem.allCases.filter(fresh.contains).map { .checklistStep($0) }
    }

    /// Seeds the checklist for someone who used Glide before it existed.
    /// If they've already done everything, the card never appears.
    mutating func seedChecklist(from config: GlideConfig) {
        checklist = ChecklistItem.completed(comparedToDefaults: config)
        if checklist.count == ChecklistItem.allCases.count {
            checklistCelebrated = true
            checklistDismissed = true
        }
    }
}
