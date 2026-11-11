import Charts
import SwiftUI

// The visible side of milestones and records: confetti, the "Make it yours"
// checklist, and "Your trackball" on Overview. Everything animates only for a
// moment, only while on screen, and holds still with Reduce Motion. Color here
// always means a part: clicks are the buttons' amber, rolling the ball's blue,
// scrolling the ring's pink.

// MARK: - Confetti

/// A short burst of confetti from the bottom-centre of the window (where the
/// toast appears), in the three part colors: mostly the celebrated part's,
/// some of the other two. Once, about 1.4 s, then the view is removed (no
/// idle timer). Never with Reduce Motion.
struct ConfettiBurst: View {
    let burst: DelightCenter.Burst
    @State private var start = Date()
    private let particles: [Particle]

    private struct Particle {
        let vx: Double, vy: Double      // initial velocity, pt/s
        let delay: Double
        let spin: Double                // radians/s
        let flutter: Double             // tumble speed
        let part: Metric
        let size: CGSize
        let round: Bool
    }

    static let life = 1.4
    private static let gravity = 1100.0
    private static let drag = 2.4

    init(burst: DelightCenter.Burst) {
        self.burst = burst
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: burst.id.hashValue))
        let parts: [Metric] = [.ball, .scroll, .clicks]
        particles = (0..<64).map { _ in
            let angle = -Double.pi / 2 + rng.next(in: -0.6...0.6)
            let speed = rng.next(in: 620...1150)
            let pick = rng.next(in: 0...1)
            let part = burst.lead.map { lead in pick < 0.55 ? lead : parts[Int(pick * 30) % 3] }
                ?? parts[Int(pick * 2.999)]
            return Particle(vx: cos(angle) * speed, vy: sin(angle) * speed,
                            delay: rng.next(in: 0...0.08),
                            spin: rng.next(in: -9...9), flutter: rng.next(in: 6...14),
                            part: part,
                            size: CGSize(width: rng.next(in: 6...9), height: rng.next(in: 3.5...5)),
                            round: rng.next(in: 0...1) < 0.25)
        }
    }

    var body: some View {
        // The part colors, resolved once for this appearance.
        let colors: [Metric: Color] = [.ball: Theme.ball, .scroll: Theme.ring, .clicks: Theme.buttons]
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
                    let fade = min(1, (Self.life - tt) / 0.45)
                    var ctx = g
                    ctx.opacity = fade
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(p.spin * tt))
                    // Squash one axis to fake a 3D tumble.
                    let w = p.size.width * max(0.15, abs(cos(p.flutter * tt)))
                    let rect = CGRect(x: -w / 2, y: -p.size.height / 2, width: w, height: p.size.height)
                    ctx.fill(p.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.2),
                             with: .color(colors[p.part] ?? Theme.ball))
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

/// Which part a celebration toast is about (set by `RootView` from `Toast.part`).
private struct CelebrationPartKey: EnvironmentKey { static let defaultValue: Metric? = nil }

extension EnvironmentValues {
    var celebrationPart: Metric? {
        get { self[CelebrationPartKey.self] }
        set { self[CelebrationPartKey.self] = newValue }
    }
}

/// The celebration toast's icon: the milestone's symbol on a disc in its
/// part's color, like the badge it earned. It bounces once as it lands.
struct CelebrationToastIcon: View {
    let symbol: String
    @State private var bounce = 0
    @Environment(\.celebrationPart) private var part
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(part == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .frame(width: 28, height: 28)
            .background(Circle().fill(part?.color ?? Theme.hoverFill))
            .pixelBorder(Circle(), part == nil ? Theme.groupBorder : .clear)
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

/// The setup checklist, while it has steps left: progress you can see (a ring
/// and a bar that fill), then one row per step, each opening the page where
/// it's done. "Trackball found" comes first, already ticked when Glideball
/// really is talking to one (it's true, so it's a head start and not a trick).
struct MakeItYoursCard: View {
    let delight: DelightCenter
    /// Glideball has found a trackball (the first step, done for you).
    var trackballFound = true
    /// Opens the tab where a step is done.
    let open: (GlideTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Set<ChecklistItem> { delight.ledger.checklist }
    private var allDone: Bool { done.count == ChecklistItem.allCases.count }
    private var stepsDone: Int { done.count + (trackballFound ? 1 : 0) }
    private var steps: Int { ChecklistItem.allCases.count + 1 }

    var body: some View {
        SectionBlock(title: "Make it yours",
                     caption: allDone ? nil : "\(stepsDone) of \(steps) done. Each one takes a few seconds.",
                     dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
            if !allDone {
                Button {
                    withAnimation(Theme.Motion.spring) { delight.dismissChecklist() }
                } label: {
                    Text("Hide").font(Theme.Font.hint.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(HoverButtonStyle(radius: 5))
                .foregroundStyle(.secondary)
                .help("Hide this checklist. It won’t come back")
                .accessibilityLabel("Hide checklist")
            }
        } content: {
            if allDone {
                SettingRow(title: "You’ve made Glideball yours.",
                           hint: "Speed, scrolling, buttons, a combo and an app setup are all done. Change anything, any time.",
                           symbol: "checkmark.circle.fill", tint: Theme.ok) {
                    Button("Hide This Card") { withAnimation(Theme.Motion.spring) { delight.dismissChecklist() } }
                        .controlSize(.small)
                }
            } else {
                ProgressHeader(done: stepsDone, total: steps)
                foundRow
                ForEach(ChecklistItem.allCases) { item in row(item) }
            }
        }
    }

    /// Step one: a trackball found (done by Glideball, not a button).
    private var foundRow: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            CheckMark(done: trackballFound)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trackball found")
                    .font(Theme.Font.body)
                    .foregroundStyle(trackballFound ? .secondary : .primary)
                Text(trackballFound ? "Glideball is talking to your trackball." : "Plug in your trackball and this ticks itself.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical - 2)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: ChecklistItem) -> some View {
        let isDone = done.contains(item)
        return Button {
            open(tab(for: item))
        } label: {
            HStack(spacing: Theme.Space.symbolGap) {
                CheckMark(done: isDone)
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
        .help(isDone ? String(localized: "Done: open to change it")
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

/// A step's tick: an empty circle, or a green check that lands with a small
/// bounce (and a ring of light that fades) the moment the step is done.
private struct CheckMark: View {
    let done: Bool
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(done ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: done)
            .overlay {
                if flash {
                    Circle().stroke(Theme.ok.opacity(0.7), lineWidth: 1.5)
                        .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 2.2).combined(with: .opacity)))
                }
            }
            .frame(width: Theme.Space.symbolColumn)
            .onChange(of: done) { _, now in
                guard now, !reduceMotion else { return }
                flash = true
                withAnimation(.easeOut(duration: 0.5)) { flash = false }
            }
    }
}

/// The checklist's progress as something you can see fill: a small ring like
/// the scroll ring and a bar, in the ball's blue, with the count.
private struct ProgressHeader: View {
    let done: Int
    let total: Int
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let f = total > 0 ? Double(done) / Double(total) : 0
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.ball.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(LinearGradient(colors: [Theme.orbCyan, Theme.ball], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.ball.opacity(0.6), radius: 4)
                Text("\(done)")
                    .font(Theme.Font.numeral(15))
                    .contentTransition(.numericText(value: Double(done)))
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(done >= total - 1 ? "One step to go" : "\(total - done) steps to go")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ball.opacity(0.13))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.orbCyan, Theme.ball], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * shown))
                            .shadow(color: Theme.ball.opacity(0.55), radius: 4)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(done) of \(total) steps done", comment: "Make it yours progress, spoken"))
        .onAppear {
            if reduceMotion { shown = f } else { withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { shown = f } }
        }
        .onChange(of: f) { _, new in
            withAnimation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.5, dampingFraction: 0.8)) { shown = new }
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
        InlineStat(value: metric.format(value), label: .verbatim(title), color: metric.color, size: 30, detail: comparison)
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
                        .foregroundStyle(LinearGradient(colors: day.isToday ? [.white.opacity(0.9), metric.color, metric.color.opacity(0.8)]
                                                                            : [metric.color.opacity(0.6), metric.color.opacity(0.28)],
                                                        startPoint: .top, endPoint: .bottom))
                        .cornerRadius(4)
                        .shadow(color: day.isToday ? metric.color.opacity(0.7) : .clear, radius: 8)
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
                    // A lit tile: the part's color glowing from inside, light catching the top edge.
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    shape.fill(RadialGradient(colors: [color.mix(with: .white, by: 0.35), color, color.mix(with: .black, by: 0.25)],
                                              center: UnitPoint(x: 0.35, y: 0.25), startRadius: 1, endRadius: 40))
                        .shadow(color: color.opacity(0.55), radius: hovering ? 12 : 7, y: 2)
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                } else {
                    // Locked: a dim, empty tile; the next one shows how far along you are.
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    shape.fill(Theme.groupFill)
                    shape.strokeBorder(Theme.groupBorder, lineWidth: 1)
                    if let progress {
                        shape.inset(by: 1.5)
                            .trim(from: 0, to: max(0.02, min(progress, 1)))
                            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .shadow(color: color.opacity(0.6), radius: 3)
                    }
                }
                Image(systemName: m.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(earned != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .shadow(color: earned != nil ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
                    .symbolEffect(.bounce, value: earned != nil)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if let earned, Date().timeIntervalSince(earned) < 24 * 3600 {
                    Text("New", comment: "On a badge earned in the last day")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.windowBackground))
                        .pixelBorder(Capsule(), color)
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
        .help(earned.map { String(localized: "\(m.detail), earned \($0.formatted(date: .abbreviated, time: .omitted))",
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
