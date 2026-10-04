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
        case .scroll: String(localized: "Scrolled", comment: "Distance scrolled with the ring")
        case .ball: String(localized: "Ball rolled", comment: "Distance the ball has rolled")
        case .clicks: String(localized: "Clicks")
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
        if m < 1 { return length(m * 100, .centimeters, digits: 0) }
        if m < 100 { return length(m, .meters, digits: 1) }
        if m < 1000 { return length(m, .meters, digits: 0) }
        if m < 100_000 { return length(m / 1000, .kilometers, digits: 2) }
        return length(m / 1000, .kilometers, digits: 0)
    }

    /// For goals and axis labels: "93 m", "1 km", "42.2 km".
    static func shortDistance(_ m: Double) -> String {
        if m < 1000 { return length(m.rounded(), .meters, digits: 0) }
        let km = m / 1000
        return length(km, .kilometers, digits: km == km.rounded() ? 0 : 1)
    }

    /// "12.3 m", in the reader's own number format and unit names.
    static func length(_ value: Double, _ unit: UnitLength, digits: Int) -> String {
        Measurement(value: value, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided,
                         numberFormatStyle: .number.precision(.fractionLength(digits))))
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
        .init(id: "scroll-10", metric: .scroll, threshold: 10, title: String(localized: "First ten metres", comment: "Badge name"),
              detail: String(localized: "Scrolled 10 m", comment: "What earns the badge"), symbol: "arrow.down.to.line"),
        .init(id: "scroll-93", metric: .scroll, threshold: 93, title: String(localized: "Lady Liberty", comment: "Badge name"),
              detail: String(localized: "Scrolled the height of the Statue of Liberty (93 m)", comment: "What earns the badge"), symbol: "building.columns"),
        .init(id: "scroll-330", metric: .scroll, threshold: 330, title: String(localized: "Eiffel Tower", comment: "Badge name"),
              detail: String(localized: "Scrolled the height of the Eiffel Tower (330 m)", comment: "What earns the badge"), symbol: "building.2"),
        .init(id: "scroll-1k", metric: .scroll, threshold: 1_000, title: String(localized: "First kilometre", comment: "Badge name"),
              detail: String(localized: "Scrolled 1 km", comment: "What earns the badge"), symbol: "flag"),
        .init(id: "scroll-8849", metric: .scroll, threshold: 8_849, title: String(localized: "Summit", comment: "Badge name"),
              detail: String(localized: "Scrolled the height of Everest (8,849 m)", comment: "What earns the badge"), symbol: "mountain.2"),
        .init(id: "scroll-42k", metric: .scroll, threshold: 42_195, title: String(localized: "Scroll marathon", comment: "Badge name"),
              detail: String(localized: "Scrolled a marathon (42.2 km)", comment: "What earns the badge"), symbol: "medal"),

        .init(id: "ball-10", metric: .ball, threshold: 10, title: String(localized: "Rolling", comment: "Badge name"),
              detail: String(localized: "Rolled the ball 10 m", comment: "What earns the badge"), symbol: "circle.circle"),
        .init(id: "ball-100", metric: .ball, threshold: 100, title: String(localized: "Pitch length", comment: "Badge name"),
              detail: String(localized: "Rolled the length of a football pitch (100 m)", comment: "What earns the badge"), symbol: "sportscourt"),
        .init(id: "ball-400", metric: .ball, threshold: 400, title: String(localized: "One lap", comment: "Badge name"),
              detail: String(localized: "Rolled one lap of a running track (400 m)", comment: "What earns the badge"), symbol: "figure.run"),
        .init(id: "ball-1k", metric: .ball, threshold: 1_000, title: String(localized: "Kilometre roller", comment: "Badge name"),
              detail: String(localized: "Rolled the ball 1 km", comment: "What earns the badge"), symbol: "flag.checkered"),
        .init(id: "ball-10k", metric: .ball, threshold: 10_000, title: String(localized: "10K", comment: "Badge name"),
              detail: String(localized: "Rolled the ball 10 km", comment: "What earns the badge"), symbol: "medal"),
        .init(id: "ball-42k", metric: .ball, threshold: 42_195, title: String(localized: "Ball marathon", comment: "Badge name"),
              detail: String(localized: "Rolled a marathon (42.2 km)", comment: "What earns the badge"), symbol: "trophy"),

        .init(id: "clicks-100", metric: .clicks, threshold: 100, title: String(localized: "Warmed up", comment: "Badge name"),
              detail: String(localized: "100 clicks", comment: "What earns the badge"), symbol: "hand.tap"),
        .init(id: "clicks-1k", metric: .clicks, threshold: 1_000, title: String(localized: "A thousand clicks", comment: "Badge name"),
              detail: String(localized: "1,000 clicks", comment: "What earns the badge"), symbol: "cursorarrow.click"),
        .init(id: "clicks-10k", metric: .clicks, threshold: 10_000, title: String(localized: "Ten thousand", comment: "Badge name"),
              detail: String(localized: "10,000 clicks", comment: "What earns the badge"), symbol: "cursorarrow.click.2"),
        .init(id: "clicks-100k", metric: .clicks, threshold: 100_000, title: String(localized: "Click legend", comment: "Badge name"),
              detail: String(localized: "100,000 clicks", comment: "What earns the badge"), symbol: "star.circle"),
        .init(id: "clicks-1m", metric: .clicks, threshold: 1_000_000, title: String(localized: "One million", comment: "Badge name"),
              detail: String(localized: "1,000,000 clicks", comment: "What earns the badge"), symbol: "crown"),
    ]
}

// MARK: - Real-world comparisons

enum Landmarks {
    /// Each comparison is a whole sentence, so every language can phrase it
    /// its own way.
    private struct Landmark {
        let meters: Double
        /// "40% of the way up the Statue of Liberty" (only for the smallest).
        var part: (Int) -> String = { _ in "" }
        /// "The height of the Eiffel Tower"
        let whole: String
        /// "≈ 3.2 × the Eiffel Tower"
        let times: (String) -> String
    }

    private static let heights: [Landmark] = [
        .init(meters: 93,
              part: { pct in String(localized: "\(pct)% of the way up the Statue of Liberty") },
              whole: String(localized: "The height of the Statue of Liberty"),
              times: { times in String(localized: "≈ \(times) × the Statue of Liberty") }),
        .init(meters: 330,
              whole: String(localized: "The height of the Eiffel Tower"),
              times: { times in String(localized: "≈ \(times) × the Eiffel Tower") }),
        .init(meters: 443,
              whole: String(localized: "The height of the Empire State Building"),
              times: { times in String(localized: "≈ \(times) × the Empire State Building") }),
        .init(meters: 828,
              whole: String(localized: "The height of the Burj Khalifa"),
              times: { times in String(localized: "≈ \(times) × the Burj Khalifa") }),
        .init(meters: 8_849,
              whole: String(localized: "The height of Mount Everest"),
              times: { times in String(localized: "≈ \(times) × Mount Everest") }),
    ]
    private static let lengths: [Landmark] = [
        .init(meters: 105,
              part: { pct in String(localized: "\(pct)% of a football pitch") },
              whole: String(localized: "The length of a football pitch"),
              times: { times in String(localized: "≈ \(times) × a football pitch") }),
        .init(meters: 400,
              whole: String(localized: "The length of a running-track lap"),
              times: { times in String(localized: "≈ \(times) × a running-track lap") }),
        .init(meters: 2_737,
              whole: String(localized: "The length of the Golden Gate Bridge"),
              times: { times in String(localized: "≈ \(times) × the Golden Gate Bridge") }),
        .init(meters: 42_195,
              whole: String(localized: "The length of a marathon"),
              times: { times in String(localized: "≈ \(times) × a marathon") }),
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
            return smallest.part(Int((meters / smallest.meters * 100).rounded(.down)))
        }
        let mark = list.last { $0.meters <= meters } ?? smallest
        let ratio = meters / mark.meters
        if ratio < 1.1 { return mark.whole }
        return mark.times(ratio < 10 ? ratio.formatted(.number.precision(.fractionLength(1))) : Int(ratio).formatted())
    }
}

// MARK: - Personal records

enum RecordKind: String, CaseIterable, Identifiable, Codable {
    case spin, flick, roll
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spin: String(localized: "Fastest ring spin")
        case .flick: String(localized: "Longest single scroll")
        case .roll: String(localized: "Fastest roll", comment: "Fastest the ball has been rolled")
        }
    }

    /// "New record: fastest ring spin"
    var newRecordTitle: String {
        switch self {
        case .spin: String(localized: "New record: fastest ring spin")
        case .flick: String(localized: "New record: longest single scroll")
        case .roll: String(localized: "New record: fastest roll")
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
        case .spin: String(localized: "\(v.formatted(.number.precision(.fractionLength(0)))) notches/s",
                           comment: "Scroll ring speed: ring notches (ticks) per second")
        case .flick: Tally.distance(v)
        case .roll: String(localized: "\(v.formatted(.number.precision(.fractionLength(0)))) in/s",
                           comment: "Ball speed in inches per second")
        }
    }
}

// MARK: - Make it yours

enum ChecklistItem: String, CaseIterable, Identifiable, Codable {
    case speed, scroll, button, combo, app
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: String(localized: "Set your pointer speed")
        case .scroll: String(localized: "Pick how scrolling feels")
        case .button: String(localized: "Map a button")
        case .combo: String(localized: "Make a combo")
        case .app: String(localized: "Add an app setup")
        }
    }

    /// "Done: set your pointer speed" — the toast when a step is ticked off.
    var doneTitle: String {
        switch self {
        case .speed: String(localized: "Done: set your pointer speed")
        case .scroll: String(localized: "Done: pick how scrolling feels")
        case .button: String(localized: "Done: map a button")
        case .combo: String(localized: "Done: make a combo")
        case .app: String(localized: "Done: add an app setup")
        }
    }

    var hint: String {
        switch self {
        case .speed: String(localized: "Pointer tab — try a preset")
        case .scroll: String(localized: "Scrolling tab — Flywheel, Follow or Native")
        case .button: String(localized: "Buttons tab — Quick assign takes two presses")
        case .combo: String(localized: "Buttons tab — press two buttons together")
        case .app: String(localized: "Apps tab — a different feel per app")
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
