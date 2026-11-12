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

/// Badges are grouped by the part they're about (clicks are the buttons, the
/// ball, the ring), plus a few for setting Glideball up and trying things.
enum BadgeGroup: String, CaseIterable, Identifiable {
    case clicks, ball, scroll, setup
    var id: String { rawValue }

    var metric: Metric? {
        switch self {
        case .clicks: .clicks
        case .ball: .ball
        case .scroll: .scroll
        case .setup: nil
        }
    }

    var title: String {
        switch self {
        case .clicks: String(localized: "Clicks", comment: "Badge group")
        case .ball: String(localized: "Ball", comment: "Badge group: the trackball's ball")
        case .scroll: String(localized: "Scroll ring", comment: "Badge group")
        case .setup: String(localized: "Setting up and exploring", comment: "Badge group")
        }
    }
}

/// Things you can try in Glideball that a setup badge counts. Each is a real
/// thing you did, saved once (`DelightLedger.explored`).
enum Exploration: String, Codable, CaseIterable {
    case button, combo, app, scrollFlywheel, scrollFollow, scrollNative, preset, ballColor

    static func scroll(_ mode: ScrollMode) -> Exploration {
        switch mode {
        case .flywheel: .scrollFlywheel
        case .follow: .scrollFollow
        case .native: .scrollNative
        }
    }
}

struct Milestone: Identifiable, Equatable {
    let id: String
    let group: BadgeGroup
    let threshold: Double
    let title: String
    /// What earned it, as a sentence ("Scrolled the height of Everest (8,849 m)").
    let detail: String
    let symbol: String
    /// How to earn it, for setup badges ("Try Flywheel, Follow and Native").
    var hint: String? = nil
    /// The explorations a setup badge counts (it's earned when `threshold` of them are done).
    var counts: [Exploration] = []

    var metric: Metric? { group.metric }

    private static func clicks(_ id: String, _ n: Double, _ title: String, _ detail: String, _ symbol: String) -> Milestone {
        Milestone(id: id, group: .clicks, threshold: n, title: title, detail: detail, symbol: symbol)
    }
    private static func ball(_ id: String, _ m: Double, _ title: String, _ detail: String, _ symbol: String) -> Milestone {
        Milestone(id: id, group: .ball, threshold: m, title: title, detail: detail, symbol: symbol)
    }
    private static func scroll(_ id: String, _ m: Double, _ title: String, _ detail: String, _ symbol: String) -> Milestone {
        Milestone(id: id, group: .scroll, threshold: m, title: title, detail: detail, symbol: symbol)
    }

    /// The badges from before 2.11, which a Mac had a chance to earn as they happened.
    static let originalIDs: Set<String> = [
        "scroll-10", "scroll-93", "scroll-330", "scroll-1k", "scroll-8849", "scroll-42k",
        "ball-10", "ball-100", "ball-400", "ball-1k", "ball-10k", "ball-42k",
        "clicks-100", "clicks-1k", "clicks-10k", "clicks-100k", "clicks-1m",
    ]

    static let all: [Milestone] = [
        clicks("clicks-100", 100, String(localized: "Warmed up", comment: "Badge name"),
               String(localized: "100 clicks", comment: "What earns the badge"), "hand.tap"),
        clicks("clicks-1k", 1_000, String(localized: "A thousand clicks", comment: "Badge name"),
               String(localized: "1,000 clicks", comment: "What earns the badge"), "cursorarrow.click"),
        clicks("clicks-10k", 10_000, String(localized: "Ten thousand", comment: "Badge name"),
               String(localized: "10,000 clicks", comment: "What earns the badge"), "cursorarrow.click.2"),
        clicks("clicks-12k", 12_000, String(localized: "Woodpecker", comment: "Badge name"),
               String(localized: "12,000 clicks, about as many pecks as a woodpecker makes in a day", comment: "What earns the badge"), "bird"),
        clicks("clicks-86k", 86_400, String(localized: "A day of seconds", comment: "Badge name"),
               String(localized: "86,400 clicks, one for every second in a day", comment: "What earns the badge"), "clock"),
        clicks("clicks-100k", 100_000, String(localized: "Click legend", comment: "Badge name"),
               String(localized: "100,000 clicks", comment: "What earns the badge"), "star.circle"),
        clicks("clicks-250k", 250_000, String(localized: "Quarter million", comment: "Badge name"),
               String(localized: "250,000 clicks", comment: "What earns the badge"), "star.leadinghalf.filled"),
        clicks("clicks-525k", 525_600, String(localized: "A year of minutes", comment: "Badge name"),
               String(localized: "525,600 clicks, one for every minute in a year", comment: "What earns the badge"), "calendar"),
        clicks("clicks-1m", 1_000_000, String(localized: "One million", comment: "Badge name"),
               String(localized: "1,000,000 clicks", comment: "What earns the badge"), "crown"),

        ball("ball-10", 10, String(localized: "Rolling", comment: "Badge name"),
             String(localized: "Rolled the ball 10 m", comment: "What earns the badge"), "circle.circle"),
        ball("ball-100", 100, String(localized: "Pitch length", comment: "Badge name"),
             String(localized: "Rolled the length of a football pitch (100 m)", comment: "What earns the badge"), "sportscourt"),
        ball("ball-400", 400, String(localized: "One lap", comment: "Badge name"),
             String(localized: "Rolled one lap of a running track (400 m)", comment: "What earns the badge"), "figure.run"),
        ball("ball-1k", 1_000, String(localized: "Kilometre roller", comment: "Badge name"),
             String(localized: "Rolled the ball 1 km", comment: "What earns the badge"), "flag.checkered"),
        ball("ball-1609", 1_609, String(localized: "A mile", comment: "Badge name"),
             String(localized: "Rolled a mile (1.6 km)", comment: "What earns the badge"), "road.lanes"),
        ball("ball-2737", 2_737, String(localized: "Golden Gate", comment: "Badge name"),
             String(localized: "Rolled the length of the Golden Gate Bridge (2.7 km)", comment: "What earns the badge"), "water.waves"),
        ball("ball-5k", 5_000, String(localized: "5K", comment: "Badge name: a 5 km run"),
             String(localized: "Rolled a 5K (5 km)", comment: "What earns the badge"), "shoeprints.fill"),
        ball("ball-10k", 10_000, String(localized: "10K", comment: "Badge name"),
             String(localized: "Rolled the ball 10 km", comment: "What earns the badge"), "medal"),
        ball("ball-21k", 21_097, String(localized: "Half marathon", comment: "Badge name"),
             String(localized: "Rolled a half marathon (21.1 km)", comment: "What earns the badge"), "figure.run.circle"),
        ball("ball-42k", 42_195, String(localized: "Ball marathon", comment: "Badge name"),
             String(localized: "Rolled a marathon (42.2 km)", comment: "What earns the badge"), "trophy"),
        ball("ball-100k", 100_000, String(localized: "Ultra", comment: "Badge name: an ultramarathon"),
             String(localized: "Rolled an ultramarathon (100 km)", comment: "What earns the badge"), "flame"),

        scroll("scroll-10", 10, String(localized: "First ten metres", comment: "Badge name"),
               String(localized: "Scrolled 10 m", comment: "What earns the badge"), "arrow.down.to.line"),
        scroll("scroll-93", 93, String(localized: "Lady Liberty", comment: "Badge name"),
               String(localized: "Scrolled the height of the Statue of Liberty (93 m)", comment: "What earns the badge"), "building.columns"),
        scroll("scroll-330", 330, String(localized: "Eiffel Tower", comment: "Badge name"),
               String(localized: "Scrolled the height of the Eiffel Tower (330 m)", comment: "What earns the badge"), "building.2"),
        scroll("scroll-443", 443, String(localized: "Empire State", comment: "Badge name"),
               String(localized: "Scrolled the height of the Empire State Building (443 m)", comment: "What earns the badge"), "building"),
        scroll("scroll-828", 828, String(localized: "Burj Khalifa", comment: "Badge name"),
               String(localized: "Scrolled the height of the Burj Khalifa (828 m)", comment: "What earns the badge"), "arrow.up.to.line"),
        scroll("scroll-1k", 1_000, String(localized: "First kilometre", comment: "Badge name"),
               String(localized: "Scrolled 1 km", comment: "What earns the badge"), "flag"),
        scroll("scroll-3776", 3_776, String(localized: "Mount Fuji", comment: "Badge name"),
               String(localized: "Scrolled the height of Mount Fuji (3,776 m)", comment: "What earns the badge"), "snowflake"),
        scroll("scroll-8849", 8_849, String(localized: "Summit", comment: "Badge name"),
               String(localized: "Scrolled the height of Everest (8,849 m)", comment: "What earns the badge"), "mountain.2"),
        scroll("scroll-10935", 10_935, String(localized: "Deep sea", comment: "Badge name"),
               String(localized: "Scrolled as deep as the Mariana Trench (10,935 m)", comment: "What earns the badge"), "water.waves.and.arrow.down"),
        scroll("scroll-42k", 42_195, String(localized: "Scroll marathon", comment: "Badge name"),
               String(localized: "Scrolled a marathon (42.2 km)", comment: "What earns the badge"), "medal"),
        scroll("scroll-100k", 100_000, String(localized: "Edge of space", comment: "Badge name"),
               String(localized: "Scrolled up to the edge of space (100 km)", comment: "What earns the badge"), "moon.stars"),

        Milestone(id: "setup-button", group: .setup, threshold: 1, title: String(localized: "New job", comment: "Badge name: gave a button a new job"),
                  detail: String(localized: "Gave a button something new to do", comment: "What earns the badge"), symbol: "button.programmable",
                  hint: String(localized: "Choose an action for a button on the Buttons tab.", comment: "How to earn a badge"), counts: [.button]),
        Milestone(id: "setup-combo", group: .setup, threshold: 1, title: String(localized: "Combo maker", comment: "Badge name"),
                  detail: String(localized: "Made your first combo", comment: "What earns the badge"), symbol: "square.on.square",
                  hint: String(localized: "Add a combo on the Buttons tab.", comment: "How to earn a badge"), counts: [.combo]),
        Milestone(id: "setup-app", group: .setup, threshold: 1, title: String(localized: "Made to measure", comment: "Badge name: an app setup"),
                  detail: String(localized: "Gave an app its own setup", comment: "What earns the badge"), symbol: "square.grid.2x2",
                  hint: String(localized: "Add an app on the Apps tab.", comment: "How to earn a badge"), counts: [.app]),
        Milestone(id: "setup-scroll-modes", group: .setup, threshold: 3, title: String(localized: "Scroll sampler", comment: "Badge name"),
                  detail: String(localized: "Tried all three ways to scroll", comment: "What earns the badge"), symbol: "arrow.up.and.down.circle",
                  hint: String(localized: "Try Flywheel, Follow and Native on the Scrolling tab.", comment: "How to earn a badge"),
                  counts: [.scrollFlywheel, .scrollFollow, .scrollNative]),
        Milestone(id: "setup-preset", group: .setup, threshold: 1, title: String(localized: "Ready-made", comment: "Badge name: used a button preset"),
                  detail: String(localized: "Tried a button preset", comment: "What earns the badge"), symbol: "wand.and.stars",
                  hint: String(localized: "Apply a preset on the Buttons tab.", comment: "How to earn a badge"), counts: [.preset]),
        Milestone(id: "setup-color", group: .setup, threshold: 1, title: String(localized: "True colors", comment: "Badge name: picked a ball color"),
                  detail: String(localized: "Gave the ball a color of your own", comment: "What earns the badge"), symbol: "paintpalette",
                  hint: String(localized: "Pick a ball color in Settings › Look.", comment: "How to earn a badge"), counts: [.ballColor]),
    ]

    /// How far along a badge is, in its own unit (metres, clicks, or things tried).
    func progress(lifetime: Tally, explored: Set<Exploration>) -> Double {
        if let metric { return lifetime.value(metric) }
        return Double(counts.filter(explored.contains).count)
    }

    /// The goal in short, for a locked badge's caption ("8.8 km", "100k").
    var shortGoal: String {
        switch group {
        case .clicks: Int(threshold).formatted(.number.notation(.compactName))
        case .ball, .scroll: Tally.shortDistance(threshold)
        case .setup: threshold > 1 ? String(localized: "\(Int(threshold)) to try", comment: "Badge caption: how many things to try")
                                   : String(localized: "Try it", comment: "Badge caption: a setup badge not yet earned")
        }
    }
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
        case .speed: String(localized: "Pointer tab: try a preset")
        case .scroll: String(localized: "Scrolling tab: Flywheel, Follow or Native")
        case .button: String(localized: "Buttons tab: Quick assign takes two presses")
        case .combo: String(localized: "Buttons tab: press two buttons together")
        case .app: String(localized: "Apps tab: a different feel per app")
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
    /// New badges arrived with an update, and this many were already earned.
    case catchUp(Int)

    /// Higher shows first when several happen at once.
    var priority: Int {
        switch self {
        case .checklistDone: 6
        case .milestone(let m): 4 + (m.group != .setup && m.threshold >= 1_000 ? 1 : 0)
        case .dayRecord: 3
        case .record: 2
        case .welcome, .catchUp: 1
        case .checklistStep: 0
        }
    }

    /// Big moments get confetti; small ones just a toast.
    var isBig: Bool {
        switch self {
        case .milestone(let m): m.group != .setup
        case .checklistDone, .dayRecord, .record: true
        case .checklistStep, .welcome, .catchUp: false
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
    /// Things tried that setup badges count (2.11).
    var explored: Set<Exploration> = []
    /// The badges this Mac has known about (2.11): one that arrives with an update
    /// and is already earned is earned quietly, then mentioned once. Nil before 2.11.
    var knownBadges: Set<String>?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case earned, records, recordDates, celebratedOn, started, checklist, checklistDismissed, checklistCelebrated,
             explored, knownBadges
    }

    // Missing keys (a ledger from an older Glideball) fall back to empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        earned = try c.decodeIfPresent([String: Date].self, forKey: .earned) ?? [:]
        records = try c.decodeIfPresent([String: Double].self, forKey: .records) ?? [:]
        recordDates = try c.decodeIfPresent([String: Date].self, forKey: .recordDates) ?? [:]
        celebratedOn = try c.decodeIfPresent([String: String].self, forKey: .celebratedOn) ?? [:]
        started = try c.decodeIfPresent(Date.self, forKey: .started)
        checklist = try c.decodeIfPresent(Set<ChecklistItem>.self, forKey: .checklist) ?? []
        checklistDismissed = try c.decodeIfPresent(Bool.self, forKey: .checklistDismissed) ?? false
        checklistCelebrated = try c.decodeIfPresent(Bool.self, forKey: .checklistCelebrated) ?? false
        // An exploration this version doesn't know (from a newer one) is skipped, not fatal.
        explored = Set((try? c.decodeIfPresent([String].self, forKey: .explored))??.compactMap(Exploration.init(rawValue:)) ?? [])
        knownBadges = try c.decodeIfPresent(Set<String>.self, forKey: .knownBadges)
    }

    func progress(_ m: Milestone, lifetime: Tally) -> Double { m.progress(lifetime: lifetime, explored: explored) }

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
            knownBadges = Set(Milestone.all.map(\.id))
            var count = 0
            for m in Milestone.all where progress(m, lifetime: lifetime) >= m.threshold {
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
        // Badges that came with an update: any already earned are earned quietly, and mentioned once.
        let known = knownBadges ?? Milestone.originalIDs
        if known.count != Milestone.all.count || !Milestone.all.allSatisfy({ known.contains($0.id) }) {
            var caught = 0
            for m in Milestone.all where !known.contains(m.id) && earned[m.id] == nil && progress(m, lifetime: lifetime) >= m.threshold {
                earned[m.id] = now
                caught += 1
            }
            knownBadges = Set(Milestone.all.map(\.id))
            if caught > 0 { events.append(.catchUp(caught)) }
        }
        for m in Milestone.all where earned[m.id] == nil && progress(m, lifetime: lifetime) >= m.threshold {
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

    /// Records things tried; returns the setup badges that just became earned.
    /// (Before the first evaluation, nothing is celebrated: that run earns them quietly.)
    mutating func explore(_ items: Set<Exploration>, lifetime: Tally, now: Date) -> [DelightEvent] {
        let fresh = items.subtracting(explored)
        guard !fresh.isEmpty else { return [] }
        explored.formUnion(fresh)
        guard started != nil, knownBadges != nil else { return [] }
        var events: [DelightEvent] = []
        for m in Milestone.all where m.group == .setup && earned[m.id] == nil && progress(m, lifetime: lifetime) >= m.threshold {
            earned[m.id] = now
            events.append(.milestone(m))
        }
        return events
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
