import Charts
import SwiftUI

// The visible side of milestones and records: confetti, the "Make it yours"
// checklist, and the "Your trackball" card on Overview. Everything animates
// only for a moment, only while on screen, and holds still with Reduce Motion.

extension Metric {
    var color: Color {
        switch self {
        case .scroll: .pink
        case .ball: .cyan
        case .clicks: .purple
        }
    }

    var gradient: LinearGradient {
        let second: Color = switch self {
        case .scroll: .orange
        case .ball: .blue
        case .clicks: .indigo
        }
        return LinearGradient(colors: [color, second], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

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

/// The toast's icon for celebrations: a gradient coin that bounces in.
struct CelebrationToastIcon: View {
    let symbol: String
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(LinearGradient(colors: [.purple, .pink, .orange],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: .pink.opacity(0.6), radius: 8)
            .symbolEffect(.bounce, value: bounce)
            .onAppear { if !reduceMotion { bounce += 1 } }
    }
}

/// "✓ Saved" — pops in next to the status pill after settings settle.
struct SavedPill: View {
    @State private var pop = 0

    var body: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.green)
            .symbolEffect(.bounce, value: pop)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .onAppear { pop += 1 }
            .help("Your settings are saved and already in effect")
            .accessibilityLabel("Settings saved")
    }
}

// MARK: - Progress ring

struct ProgressRing<Label: View>: View {
    let progress: Double
    var lineWidth: CGFloat = 9
    var colors: [Color] = [.cyan, .purple, .pink, .cyan]
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(AngularGradient(colors: colors, center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .purple.opacity(progress >= 1 ? 0.7 : 0.3), radius: progress >= 1 ? 10 : 4)
            label
        }
    }
}

// MARK: - Make it yours

struct MakeItYoursCard: View {
    let delight: DelightCenter
    /// Opens the tab where a step is done.
    let open: (GlideTab) -> Void
    @State private var hovered: ChecklistItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Set<ChecklistItem> { delight.ledger.checklist }
    private var allDone: Bool { done.count == ChecklistItem.allCases.count }

    var body: some View {
        GlassCard(title: "Make it yours", symbol: "wand.and.stars") {
            HStack(alignment: .center, spacing: 24) {
                ProgressRing(progress: Double(done.count) / Double(ChecklistItem.allCases.count)) {
                    VStack(spacing: 0) {
                        if allDone {
                            Image(systemName: "sparkles")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(LinearGradient(colors: [.cyan, .pink], startPoint: .top, endPoint: .bottom))
                                .symbolEffect(.bounce, value: allDone)
                        } else {
                            Text(verbatim: "\(done.count)")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .contentTransition(.numericText(value: Double(done.count)))
                            Text("of \(ChecklistItem.allCases.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 86, height: 86)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7), value: done.count)

                if allDone {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You’ve made Glide yours.")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("Speed, scrolling, buttons, a combo and an app setup — all tuned to you. Change anything, any time.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Hide This Card") { withAnimation(.smooth) { delight.dismissChecklist() } }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                              alignment: .leading, spacing: 8) {
                        ForEach(ChecklistItem.allCases) { item in row(item) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 24)   // clear of the close button
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !allDone {
                Button {
                    withAnimation(.smooth) { delight.dismissChecklist() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(14)
                .help("Hide this checklist — it won’t come back")
                .accessibilityLabel("Hide checklist")
            }
        }
    }

    private func row(_ item: ChecklistItem) -> some View {
        let isDone = done.contains(item)
        return Button {
            open(tab(for: item))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isDone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .strikethrough(isDone, color: .secondary)
                        .foregroundStyle(isDone ? .secondary : .primary)
                    Text(item.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovered == item ? 1 : 0)
                    .offset(x: hovered == item ? 0 : -4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hovered == item ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.snappy(duration: 0.18)) { hovered = inside ? item : (hovered == item ? nil : hovered) }
        }
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

struct YourTrackballCard: View {
    let delight: DelightCenter
    @State private var metric: Metric = .scroll

    var body: some View {
        GlassCard(title: "Your trackball", symbol: "trophy") {
            HStack(spacing: 12) {
                ForEach(Metric.allCases) { m in LifetimeTile(metric: m, delight: delight) }
            }

            HStack(alignment: .top, spacing: 18) {
                WeekChart(delight: delight, metric: $metric)
                    .frame(maxWidth: .infinity)
                PersonalBests(delight: delight)
                    .frame(width: 300)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Badges").font(.system(size: 13, weight: .semibold))
                    Text("\(delight.ledger.earned.count) of \(Milestone.all.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(delight.ledger.earned.count)))
                    Spacer()
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Metric.allCases) { m in BadgeRow(metric: m, delight: delight) }
            }
        }
    }

    private var footnote: String {
        guard let first = delight.firstDay ?? delight.ledger.started else { return String(localized: "Counted on this Mac only") }
        return String(localized: "Since \(first.formatted(.dateTime.month(.abbreviated).day().year())) · on this Mac only",
                      comment: "%@ is a date")
    }
}

private struct LifetimeTile: View {
    let metric: Metric
    let delight: DelightCenter

    var body: some View {
        let value = delight.lifetime.value(metric)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(metric.gradient)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(metric.format(value))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .animation(.smooth(duration: 0.4), value: value)
            Text(comparison)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
            HStack {
                Text("This week").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Show", selection: $metric) {
                    ForEach(Metric.allCases) { m in Text(m == .clicks ? "Clicks" : m == .ball ? "Rolled" : "Scrolled").tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Chart {
                ForEach(points) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value(metric.title, grown ? day.tally.value(metric) : 0))
                        .foregroundStyle(day.isToday ? AnyShapeStyle(metric.gradient) : AnyShapeStyle(metric.color.opacity(0.4)))
                        .cornerRadius(6)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
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
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(metric == .clicks ? Int(d).formatted() : Tally.shortDistance(d)).font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 150)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8), value: metric)
            .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.75), value: grown)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal bests").font(.system(size: 13, weight: .semibold))
            ForEach(Metric.allCases) { m in
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
                row(symbol: k.symbol, color: .orange, title: k.title,
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
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let date {
                Text(date)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(date == Self.today ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
    }
}

private struct BadgeRow: View {
    let metric: Metric
    let delight: DelightCenter

    var body: some View {
        let list = Milestone.all.filter { $0.metric == metric }
        let next = list.first { delight.ledger.earned[$0.id] == nil }
        HStack(spacing: 0) {
            ForEach(list) { m in
                BadgeView(milestone: m, earned: delight.ledger.earned[m.id],
                          progress: m.id == next?.id ? delight.lifetime.value(metric) / m.threshold : nil)
                    .frame(maxWidth: .infinity)
            }
            // Keep the columns lined up between rows of different lengths.
            ForEach(list.count..<Self.columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
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
        VStack(spacing: 5) {
            ZStack {
                if earned != nil {
                    Circle().fill(m.metric.gradient)
                        .shadow(color: m.metric.color.opacity(hovering ? 0.8 : 0.45), radius: hovering ? 12 : 6)
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                } else {
                    Circle().fill(.white.opacity(0.05))
                    Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, min(progress, 1)))
                            .stroke(m.metric.color.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                    }
                }
                Image(systemName: m.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(earned != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .symbolEffect(.bounce, value: earned != nil)
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topTrailing) {
                if let earned, Date().timeIntervalSince(earned) < 24 * 3600 {
                    Text("NEW")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(.orange))
                        .foregroundStyle(.white)
                        .offset(x: 8, y: -3)
                }
            }
            .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)

            Text(m.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(earned != nil ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .opacity(earned == nil && progress == nil ? 0.6 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hovering = h } }
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
