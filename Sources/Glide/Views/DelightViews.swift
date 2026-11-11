import Charts
import SwiftUI

// The visible side of milestones and records: confetti, the "Make it yours"
// checklist, and "Your trackball" on Overview. Everything animates only for a
// moment, only while on screen, and holds still with Reduce Motion. Color here
// always means a part: clicks are the buttons' amber, rolling the ball's blue,
// scrolling the ring's pink.

// MARK: - Confetti

/// A short burst of confetti from the bottom-centre of the window (where the
/// toast appears). Lives ~2 s, then the view is removed — no idle timer.
struct ConfettiBurst: View {
    let burst: DelightCenter.Burst
    @State private var start = Date()
    private let particles: [Particle]

    private struct Particle {
        let vx: Double, vy: Double      // initial velocity, pt/s
        let delay: Double
        let spin: Double                // radians/s
        let flutter: Double             // tumble speed
        let hue: Double
        let size: CGSize
        let round: Bool
    }

    static let life = 2.1
    private static let gravity = 900.0
    private static let drag = 2.2

    init(burst: DelightCenter.Burst) {
        self.burst = burst
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: burst.id.hashValue))
        particles = (0..<90).map { _ in
            let angle = -Double.pi / 2 + rng.next(in: -0.62...0.62)
            let speed = rng.next(in: 650...1250)
            return Particle(vx: cos(angle) * speed, vy: sin(angle) * speed,
                            delay: rng.next(in: 0...0.12),
                            spin: rng.next(in: -9...9), flutter: rng.next(in: 6...14),
                            hue: burst.hues.isEmpty ? 0.75 : burst.hues[Int(rng.next(in: 0...Double(burst.hues.count) - 0.001))],
                            size: CGSize(width: rng.next(in: 6...10), height: rng.next(in: 3.5...5.5)),
                            round: rng.next(in: 0...1) < 0.25)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { g, size in
                let origin = CGPoint(x: size.width / 2, y: size.height - 56)
                let k = Self.drag, grav = Self.gravity
                for p in particles {
                    let tt = t - p.delay
                    guard tt > 0, tt < Self.life else { continue }
                    // Linear drag: fast at first, then a gentle drift down.
                    let e = 1 - exp(-k * tt)
                    let x = origin.x + p.vx / k * e
                    let y = origin.y + grav / k * tt + (p.vy - grav / k) * e / k
                    let fade = min(1, (Self.life - tt) / 0.6)
                    var ctx = g
                    ctx.opacity = fade
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(p.spin * tt))
                    // Squash one axis to fake a 3D tumble.
                    let w = p.size.width * max(0.15, abs(cos(p.flutter * tt)))
                    let rect = CGRect(x: -w / 2, y: -p.size.height / 2, width: w, height: p.size.height)
                    let color = Color(hue: p.hue, saturation: p.hue == 0.14 ? 0.55 : 0.7, brightness: 1)
                    ctx.fill(p.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small deterministic RNG so each burst is varied but cheap.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(nextRaw() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

/// The celebration toast's icon: the milestone's symbol, which bounces once as it lands.
struct CelebrationToastIcon: View {
    let symbol: String
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.hoverFill))
            .overlay(Circle().strokeBorder(Theme.groupBorder, lineWidth: 0.5))
            .symbolEffect(.bounce, value: bounce)
            .onAppear { if !reduceMotion { bounce += 1 } }
    }
}

/// "Saved" — floats in at the top of the content after settings settle.
struct SavedPill: View {
    var body: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .help("Your settings are saved and already in effect")
            .accessibilityLabel("Settings saved")
    }
}

// MARK: - Make it yours

/// The setup checklist, while it has steps left: one row per step, each
/// opening the page where it's done.
struct MakeItYoursCard: View {
    let delight: DelightCenter
    /// Opens the tab where a step is done.
    let open: (GlideTab) -> Void

    private var done: Set<ChecklistItem> { delight.ledger.checklist }
    private var allDone: Bool { done.count == ChecklistItem.allCases.count }

    var body: some View {
        SectionBlock(title: "Make it yours",
                     caption: allDone ? nil : "\(done.count) of \(ChecklistItem.allCases.count)",
                     dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
            if !allDone {
                Button {
                    withAnimation(Theme.Motion.spring) { delight.dismissChecklist() }
                } label: {
                    Text("Hide").font(Theme.Font.hint.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(HoverButtonStyle(radius: 5))
                .foregroundStyle(.secondary)
                .help("Hide this checklist — it won’t come back")
                .accessibilityLabel("Hide checklist")
            }
        } content: {
            if allDone {
                SettingRow(title: "You’ve made Glideball yours.",
                           hint: "Speed, scrolling, buttons, a combo and an app setup — all tuned to you. Change anything, any time.",
                           symbol: "checkmark.circle.fill", tint: Theme.ok) {
                    Button("Hide This Card") { withAnimation(Theme.Motion.spring) { delight.dismissChecklist() } }
                        .controlSize(.small)
                }
            } else {
                ForEach(ChecklistItem.allCases) { item in row(item) }
            }
        }
    }

    private func row(_ item: ChecklistItem) -> some View {
        let isDone = done.contains(item)
        return Button {
            open(tab(for: item))
        } label: {
            HStack(spacing: Theme.Space.symbolGap) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isDone ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Theme.Space.symbolColumn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.Font.body)
                        .foregroundStyle(isDone ? .secondary : .primary)
                    Text(item.hint)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, Theme.Space.rowVertical - 2)
            .frame(minHeight: Theme.Space.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 0))
        .help(isDone ? String(localized: "Done — open to change it")
                     : String(localized: "Open the \(tab(for: item).title) tab", comment: "%@ is a tab name"))
    }

    private func tab(for item: ChecklistItem) -> GlideTab {
        switch item {
        case .speed: .pointer
        case .scroll: .scroll
        case .button, .combo: .buttons
        case .app: .apps
        }
    }
}

// MARK: - Your trackball

/// Lifetime numbers, this week, personal bests and badges.
struct YourTrackballCard: View {
    let delight: DelightCenter
    @State private var metric: Metric = .scroll

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Your trackball", caption: .verbatim(footnote))
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(Metric.lifetimeOrder.enumerated()), id: \.element) { i, m in
                        if i > 0 { Hairline(vertical: true).padding(.horizontal, 20) }
                        LifetimeStat(metric: m, delight: delight)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            WeekChart(delight: delight, metric: $metric)
            PersonalBests(delight: delight)

            SectionBlock(title: "Badges", caption: "\(delight.ledger.earned.count) of \(Milestone.all.count)") {
                ForEach(Metric.lifetimeOrder) { m in BadgeRow(metric: m, delight: delight) }
            }
        }
    }

    private var footnote: String {
        guard let first = delight.firstDay ?? delight.ledger.started else { return String(localized: "Counted on this Mac only") }
        return String(localized: "Since \(first.formatted(.dateTime.month(.abbreviated).day().year())) · on this Mac only",
                      comment: "%@ is a date")
    }
}

extension Metric {
    /// The order the parts are shown in: buttons, ball, ring (as Today reads).
    static let lifetimeOrder: [Metric] = [.clicks, .ball, .scroll]
}

private struct LifetimeStat: View {
    let metric: Metric
    let delight: DelightCenter

    var body: some View {
        let value = delight.lifetime.value(metric)
        InlineStat(value: metric.format(value), label: .verbatim(title), color: metric.color, size: 22, detail: comparison)
            .animation(.smooth(duration: 0.4), value: value)
    }

    private var title: String {
        switch metric {
        case .clicks: String(localized: "Lifetime clicks")
        case .scroll: String(localized: "Lifetime · scrolled")
        case .ball: String(localized: "Lifetime · ball rolled")
        }
    }

    private var comparison: String {
        let value = delight.lifetime.value(metric)
        if metric == .clicks {
            let days = max(1, delight.historyDays + 1)
            return days > 1 ? String(localized: "About \(Int(value / Double(days)).formatted()) a day", comment: "Clicks per day; %@ is a number")
                            : String(localized: "Counting from today")
        }
        return Landmarks.compare(value, metric: metric) ?? String(localized: "Give it a spin")
    }
}

private struct WeekChart: View {
    let delight: DelightCenter
    @Binding var metric: Metric
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let points = delight.week
        let values = points.map { $0.tally.value(metric) }
        let active = values.filter { $0 > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "This week") {
                Picker("Show", selection: $metric) {
                    ForEach(Metric.lifetimeOrder) { m in Text(m == .clicks ? "Clicks" : m == .ball ? "Rolled" : "Scrolled").tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Chart {
                ForEach(points) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value(metric.title, grown ? day.tally.value(metric) : 0),
                            width: .ratio(0.5))
                        .foregroundStyle(metric.color.opacity(day.isToday ? 1 : 0.45))
                        .cornerRadius(3)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("avg \(metric.format(average))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.gridLine)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(metric == .clicks ? Int(d).formatted() : Tally.shortDistance(d)).font(.system(size: 9)).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 140)
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: metric)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: grown)
            .accessibilityLabel(accessibilityTitle)
        }
        .onAppear {
            // Bars grow in once each time Overview opens.
            if reduceMotion { grown = true } else { DispatchQueue.main.async { grown = true } }
        }
    }

    private var accessibilityTitle: String {
        switch metric {
        case .clicks: String(localized: "Last seven days of clicks")
        case .scroll: String(localized: "Last seven days of scrolling")
        case .ball: String(localized: "Last seven days of ball rolling")
        }
    }
}

private struct PersonalBests: View {
    let delight: DelightCenter

    var body: some View {
        SectionBlock(title: "Personal bests",
                     dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
            ForEach(Metric.lifetimeOrder) { m in
                let best = max(delight.pastBest.value(m), delight.today.value(m))
                let isToday = delight.today.value(m) > delight.pastBest.value(m) && delight.historyDays > 0
                row(symbol: m.symbol, color: m.color,
                    title: m == .clicks ? String(localized: "Most clicks in a day")
                        : m == .scroll ? String(localized: "Most scrolled in a day") : String(localized: "Most rolled in a day"),
                    value: best > 0 ? m.format(best) : "—",
                    date: isToday ? Self.today : delight.pastBestDay[m].map(short))
            }
            ForEach(RecordKind.allCases) { k in
                let v = delight.ledger.record(k)
                row(symbol: k.symbol, color: k == .roll ? Theme.ball : Theme.ring, title: k.title,
                    value: v > 0 ? k.format(v) : "—",
                    date: delight.ledger.recordDates[k.rawValue].map(short))
            }
        }
    }

    private static let today = String(localized: "today", comment: "When a personal best was set; short (about 6 letters fit)")

    private func short(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Self.today : d.formatted(.dateTime.month(.abbreviated).day())
    }

    private func row(symbol: String, color: Color, title: String, value: String, date: String?) -> some View {
        HStack(spacing: Theme.Space.symbolGap) {
            RowSymbol(symbol: symbol, tint: color)
            Text(title).font(Theme.Font.body).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.Font.value)
                .contentTransition(.numericText())
            Text(date ?? "")
                .font(Theme.Font.hint)
                .foregroundStyle(date == Self.today ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

private struct BadgeRow: View {
    let metric: Metric
    let delight: DelightCenter

    var body: some View {
        let list = Milestone.all.filter { $0.metric == metric }
        let next = list.first { delight.ledger.earned[$0.id] == nil }
        HStack(alignment: .top, spacing: 0) {
            ForEach(list) { m in
                BadgeView(milestone: m, earned: delight.ledger.earned[m.id],
                          progress: m.id == next?.id ? delight.lifetime.value(metric) / m.threshold : nil)
                    .frame(maxWidth: .infinity)
            }
            // Keep the columns lined up between rows of different lengths.
            ForEach(list.count..<Self.columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 14)
    }

    static let columns = Metric.allCases.map { m in Milestone.all.filter { $0.metric == m }.count }.max() ?? 6
}

private struct BadgeView: View {
    let milestone: Milestone
    let earned: Date?
    /// Set for the next badge to earn in its row: how far along you are.
    let progress: Double?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let m = milestone
        let color = m.metric.color
        VStack(spacing: 5) {
            ZStack {
                if earned != nil {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(Theme.hairline, lineWidth: 1)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, min(progress, 1)))
                            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.25)
                    }
                }
                Image(systemName: m.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(earned != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .symbolEffect(.bounce, value: earned != nil)
            }
            .frame(width: 40, height: 40)
            .overlay(alignment: .topTrailing) {
                if let earned, Date().timeIntervalSince(earned) < 24 * 3600 {
                    Text("New", comment: "On a badge earned in the last day")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.windowBackground))
                        .overlay(Capsule().strokeBorder(color, lineWidth: 0.5))
                        .foregroundStyle(color)
                        .offset(x: 10, y: -4)
                }
            }
            .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)

            Text(m.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(earned != nil ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .opacity(earned == nil && progress == nil ? 0.55 : 1)
        .onHover { h in withAnimation(Theme.Motion.spring) { hovering = h } }
        .help(earned.map { String(localized: "\(m.detail) — earned \($0.formatted(date: .abbreviated, time: .omitted))",
                                  comment: "Badge tooltip: what earns it, then the date") }
              ?? String(localized: "Goal: \(m.detail)", comment: "Badge tooltip: what earns it"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(earned != nil ? String(localized: "\(m.title). \(m.detail). Earned", comment: "Badge name, then what earns it")
                                          : String(localized: "\(m.title). \(m.detail). Not yet earned", comment: "Badge name, then what earns it"))
    }

    private var caption: String {
        if let earned { return earned.formatted(.dateTime.month(.abbreviated).day()) }
        if let progress { return min(progress, 0.99).wholePercent }
        return m.metric == .clicks ? Int(m.threshold).formatted() : Tally.shortDistance(m.threshold)
    }

    private var m: Milestone { milestone }
}
