import Charts
import SwiftUI

/// Overview is the showpiece: an instrument cluster (the live trackball inside
/// three gauges, today against your best), the live signal as an oscilloscope,
/// "Make it yours" as progress you can see, and the trackball's history.
struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section + 8) {
            TodayCluster(model: model)
            LiveActivity(feed: model.live)
            if model.delight.checklistVisible {
                MakeItYoursCard(delight: model.delight, trackballFound: model.status.deviceConnected) { model.requestedTab = $0 }
                    .transition(.opacity)
            }
            YourTrackballCard(delight: model.delight)
            SettingsHint()
        }
        .animation(Theme.Motion.spring, value: model.delight.checklistVisible)
    }

    static func meters(_ m: Double) -> String {
        if m < 1 { return Tally.length(m * 100, .centimeters, digits: 0) }
        if m < 1000 { return Tally.length(m, .meters, digits: 1) }
        return Tally.length(m / 1000, .kilometers, digits: 2)
    }
}

// MARK: - Shell state

/// What the window's shell needs to know from a page: whether Overview's big
/// trackball is on screen (the sidebar's then steps down to a small status light).
@Observable
final class ShellState {
    var heroOnScreen = false
}

// MARK: - Today: the instrument cluster

/// The live trackball at the center of three gauges, one per part (buttons
/// amber outside, ring pink, ball blue inside, as the trackball itself is
/// built), each filling toward that part's best day, with the big numbers beside.
struct TodayCluster: View {
    let model: AppModel
    @Environment(ShellState.self) private var shell: ShellState?
    @Environment(\.colorScheme) private var scheme

    /// Renders: draw this part's record moment part-way through (there's no clock in a picture).
    nonisolated(unsafe) static var sandboxRecordMoment: Metric?

    static let order: [Metric] = [.clicks, .scroll, .ball]

    var body: some View {
        let dial: CGFloat = 368
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                gauge(dial)
                stats
            }
            HStack(alignment: .center, spacing: 18) {
                gauge(dial * 0.86)
                stats
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onScrollVisibilityChange(threshold: 0.35) { visible in shell?.heroOnScreen = visible }
        .onDisappear { shell?.heroOnScreen = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today")
    }

    private func gauge(_ d: CGFloat) -> some View {
        let look = TrackballLook.of(model)
        return ZStack {
            // The trackball's own light on the stage around it.
            Circle()
                .fill(RadialGradient(colors: [Theme.orbBlue.opacity(scheme == .dark ? 0.34 : 0.20),
                                              Theme.orbViolet.opacity(scheme == .dark ? 0.14 : 0.08), .clear],
                                     center: .center, startRadius: d * 0.1, endRadius: d * 0.62))
                .frame(width: d * 1.3, height: d * 1.3)
                .opacity(look == .connected ? 1 : 0.35)
                .allowsHitTesting(false)
            if model.performance != .minimal, look == .connected {
                LightBloom(feed: model.live, pressed: model.pressed, dark: scheme == .dark, size: d * 1.15, strength: 0.7)
            }
            DialTicks()
                .frame(width: d, height: d)
            ForEach(Array(Self.order.enumerated()), id: \.element) { i, m in
                GaugeArc(metric: m, fraction: fraction(m), lane: i, dial: d,
                         moment: Self.sandboxRecordMoment == m)
            }
            TrackballView(feed: model.live, pressed: model.pressed, look: look,
                          driftFPS: model.windowVisible
                            ? model.performance.idleDriftFPS(windowIsKey: model.windowIsKey, deviceConnected: model.status.deviceConnected)
                            : 0)
                .frame(width: d * 0.55, height: d * 0.55)
            // In the dial's open bottom, what it measures.
            VStack(spacing: 1) {
                Text("Today")
                    .font(.system(size: 13, weight: .semibold))
                Text("against your best day")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: d * 0.42)
            .offset(y: d * 0.43)
            .accessibilityHidden(true)
        }
        .frame(width: d, height: d)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.order) { m in
                ClusterStat(metric: m, value: value(m), best: best(m), fraction: fraction(m),
                            moment: Self.sandboxRecordMoment == m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ m: Metric) -> String {
        switch m {
        case .clicks: Int(model.totals.clicks).formatted()
        case .ball: OverviewView.meters(model.totals.ballCounts / AppModel.countsPerInch * 0.0254)
        case .scroll: OverviewView.meters(model.totals.scrollPoints * 0.00023)
        }
    }

    /// Your best earlier day, once there are a few days to compare.
    private func best(_ m: Metric) -> Double? {
        let d = model.delight
        let best = d.pastBest.value(m)
        guard d.historyDays >= DelightLedger.minHistoryDays, best >= DelightLedger.meaningfulDay(m) else { return nil }
        return best
    }

    /// How far today has come: toward your best day, or toward a meaningful first day until there is one.
    private func fraction(_ m: Metric) -> Double {
        let target = best(m) ?? DelightLedger.meaningfulDay(m) * 10
        return target > 0 ? model.delight.today.value(m) / target : 0
    }
}

/// The scroll ring's ticks around the dial: 120 of them on the 270° the gauges use.
private struct DialTicks: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink: Color = scheme == .dark ? .white : .black
        return Canvas { ctx, size in Self.draw(&ctx, size: size, ink: ink) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static func draw(_ ctx: inout GraphicsContext, size: CGSize, ink: Color) {
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        let r = Double(min(size.width, size.height)) / 2
        var minor = Path(), major = Path()
        for i in 0...90 {
            let a: Double = (135 + Double(i) * 3) * Double.pi / 180
            let long = i % 5 == 0
            let r0: Double = r - (long ? 7 : 4)
            let r1: Double = r - 1
            let p0 = CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0)
            let p1 = CGPoint(x: cx + cos(a) * r1, y: cy + sin(a) * r1)
            if long { major.move(to: p0); major.addLine(to: p1) } else { minor.move(to: p0); minor.addLine(to: p1) }
        }
        ctx.stroke(minor, with: .color(ink.opacity(0.14)), lineWidth: 1)
        ctx.stroke(major, with: .color(ink.opacity(0.28)), lineWidth: 1.2)
    }
}

/// One part's gauge: a 270° arc (open at the bottom, like a dial) that fills
/// toward your best day. Draws itself in the first time it appears. When today
/// passes the best, it closes with a sweep of light, once.
private struct GaugeArc: View {
    let metric: Metric
    let fraction: Double
    /// 0 outermost.
    let lane: Int
    let dial: CGFloat
    var moment = false
    @State private var shown = 0.0
    @State private var sweep = 0.0
    @State private var sweeping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    static let span = 0.75   // of a full turn

    var body: some View {
        let width: CGFloat = dial * 0.022
        let r = dial / 2 - dial * 0.045 - CGFloat(lane) * (width + dial * 0.016)
        let fill = min(max(shown, 0), 1) * Self.span
        let color = metric.color
        let record = fraction >= 1
        ZStack {
            // The track.
            Circle()
                .trim(from: 0, to: Self.span)
                .stroke(color.opacity(scheme == .dark ? 0.13 : 0.15), style: StrokeStyle(lineWidth: width, lineCap: .round))
            // Its light on the dial.
            Circle()
                .trim(from: 0, to: max(fill, 0.001))
                .stroke(color.opacity(record ? 0.7 : 0.45), style: StrokeStyle(lineWidth: width * 3.2, lineCap: .round))
                .blur(radius: width * 1.6)
                .opacity(scheme == .dark ? 0.8 : 0.45)
            // The fill: brighter toward its head.
            Circle()
                .trim(from: 0, to: max(fill, 0.001))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color, record ? .white.opacity(0.95) : color],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(fill, 0.01))),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
            // The head: a bright point where today is.
            if fill > 0.004 {
                Circle()
                    .fill(.white)
                    .frame(width: width * 0.62, height: width * 0.62)
                    .shadow(color: color, radius: width * 0.8)
                    .offset(x: r)
                    .rotationEffect(.degrees(360 * fill))
            }
            // A record: a band of light runs the whole way round, once.
            if sweeping || moment {
                let p = moment ? 0.55 : sweep
                Circle()
                    .trim(from: max(0, p * Self.span - 0.12), to: min(Self.span, p * Self.span))
                    .stroke(LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: width * 1.15, lineCap: .round))
                    .shadow(color: color, radius: width * 1.5)
                    .blendMode(.plusLighter)
                    .opacity(p < 1 ? 1 : 0)
            }
        }
        .frame(width: r * 2, height: r * 2)
        .rotationEffect(.degrees(135))
        .onAppear {
            // Draws in once each time Overview opens.
            if reduceMotion { shown = fraction } else {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.9).delay(0.05 * Double(lane))) { shown = fraction }
            }
        }
        .onChange(of: fraction) { old, new in
            withAnimation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.5, dampingFraction: 0.86)) { shown = new }
            // Passing your best, while you watch: the ring closes with a sweep.
            if old < 1, new >= 1, !reduceMotion {
                sweeping = true
                sweep = 0
                withAnimation(.easeInOut(duration: 0.75).delay(0.06)) { sweep = 1 } completion: { sweeping = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A part's numbers beside the dial: the label with the part's dot, the big
/// rolling numeral, and how far toward your best day. Passing the best pops the
/// number once (the one bounce) and throws a few sparks in the part's color.
private struct ClusterStat: View {
    let metric: Metric
    let value: String
    let best: Double?
    let fraction: Double
    var moment = false
    @State private var pop = false
    @State private var sparks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusDot(color: metric.color, size: 7)
                    .shadow(color: metric.color.opacity(0.8), radius: 3)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(Theme.Font.numeral(44))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .scaleEffect(pop || moment ? 1.1 : 1, anchor: .leading)
                .overlay {
                    if sparks > 0 || moment {
                        SparkBurst(color: metric.color, frozenAt: moment ? 0.28 : nil)
                            .id(sparks)
                            .frame(width: 200, height: 130)
                    }
                }
            Text(detail)
                .font(Theme.Font.hint)
                .foregroundStyle(fraction >= 1 && best != nil ? AnyShapeStyle(metric.color) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .onChange(of: fraction >= 1) { was, now in
            guard now, !was, best != nil, !reduceMotion else { return }
            // A short hold, then the pop and the sparks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(Theme.Motion.bounce) { pop = true }
                sparks += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(Theme.Motion.spring) { pop = false } }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch metric {
        case .clicks: String(localized: "Clicks today")
        case .ball: String(localized: "Ball rolled")
        case .scroll: String(localized: "Scrolled")
        }
    }

    private var detail: String {
        guard let best else { return String(localized: "Your best day shows here after a few days") }
        if fraction >= 1 { return String(localized: "Your best day yet") }
        return String(localized: "\(fraction.wholePercent) of your best, \(metric.format(best))",
                      comment: "Under a number on Overview: how far today is toward your best day; first %@ is a percentage, second the best day's amount")
    }
}

/// About sixteen sparks in a part's color, thrown out once (0.7 s) and gone.
struct SparkBurst: View {
    let color: Color
    /// Renders: the moment to draw (seconds in).
    var frozenAt: Double? = nil
    @State private var start = Date()
    static let life = 0.7

    var body: some View {
        TimelineView(.animation(paused: frozenAt != nil)) { tl in
            let t = frozenAt ?? tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard t < Self.life else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let k = t / Self.life
                for i in 0..<16 {
                    let a = Double(i) / 16 * 2 * .pi + Double(i % 3) * 0.21
                    let speed = 58 + Double((i * 7) % 5) * 10
                    let d = speed * (1 - pow(1 - k, 3))
                    let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.8)
                    let s = 3.2 * (1 - k) + 0.6
                    ctx.opacity = 1 - k * k
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                             with: .color(i % 4 == 0 ? .white : color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Live activity: the oscilloscope

/// The live signal on a little oscilloscope: two traces (ball blue, ring pink)
/// that glow, with an afterglow fading toward the past. Draws itself in the
/// first time it appears; flat and still when nothing moves. Redrawn on its own
/// timeline while something moves; the page around it never is.
private struct LiveActivity: View {
    let feed: LiveFeed
    @State private var reveal = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveTimeline(feed: feed, maxFPS: 30) { feed, _ in
                SectionTitle(title: "Live activity") {
                    HStack(spacing: 14) {
                        legend("Ball speed", color: Theme.ball,
                               value: String(localized: "\(feed.ballSpeed.formatted(.number.precision(.fractionLength(1)))) in/s",
                                             comment: "Ball speed in inches per second"))
                        legend("Scroll ring", color: Theme.ring,
                               value: String(localized: "\(feed.notchRate.formatted(.number.precision(.fractionLength(0)))) notches/s",
                                             comment: "Scroll ring speed: ring notches (ticks) per second"))
                    }
                }
            }
            ZStack {
                ScopeGrid()
                LiveTimeline(feed: feed, maxFPS: 30) { feed, _ in
                    LiveChart(ball: feed.ballHistory, ring: feed.notchHistory)
                        .mask(alignment: .leading) {
                            GeometryReader { g in Rectangle().frame(width: g.size.width * reveal) }
                        }
                        .overlay {
                            if !feed.isActive {
                                Text("Roll or spin to see it move")
                                    .font(Theme.Font.hint)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.well))
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Live activity")
                        .accessibilityValue("\(feed.ballSpeed.formatted(.number.precision(.fractionLength(1)))) in/s")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(height: 150)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                shape.fill(Theme.well)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.35), Theme.surfaceHighlight.opacity(0.5)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
        }
        .onAppear {
            if reduceMotion { reveal = 1 } else { withAnimation(.easeOut(duration: 0.7)) { reveal = 1 } }
        }
    }

    private func legend(_ name: LocalizedStringKey, color: Color, value: String) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 7)
            Text(name).font(Theme.Font.hint.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(Theme.Font.hint.weight(.medium)).monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The scope's screen: a faint grid, one division a second, drawn once.
private struct ScopeGrid: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let ink: Color = scheme == .dark ? .white : .black
            let cols = Int(LiveFeed.historySeconds)
            for i in 1..<cols {
                let x = (size.width * CGFloat(i) / CGFloat(cols)).rounded()
                var p = Path(); p.move(to: CGPoint(x: x + 0.5, y: 0)); p.addLine(to: CGPoint(x: x + 0.5, y: size.height))
                ctx.stroke(p, with: .color(ink.opacity(0.05)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }
            for j in 1..<4 {
                let y = (size.height * CGFloat(j) / 4).rounded()
                var p = Path(); p.move(to: CGPoint(x: 0, y: y + 0.5)); p.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                ctx.stroke(p, with: .color(ink.opacity(0.05)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Both traces over one baseline, each on its own scale (the y-axis never
/// shrinks below a floor, so a quiet trackball reads as quiet). Drawn straight
/// into a Canvas: far cheaper than Swift Charts for data that changes 30 times a
/// second. Each trace glows (three strokes, no blur) and fades toward the past,
/// with a bright point at "now".
struct LiveChart: View {
    let ball: [Double]
    let ring: [Double]

    var body: some View {
        Canvas { context, size in
            trace(ring, floor: 10, color: Theme.ring, in: context, size: size)
            trace(ball, floor: 4, color: Theme.ball, in: context, size: size)
        }
    }

    private func trace(_ values: [Double], floor: Double, color: Color, in context: GraphicsContext, size: CGSize) {
        guard values.count > 1 else { return }
        let top = max(floor, (values.max() ?? 0) * 1.15)
        let step = size.width / CGFloat(values.count - 1)
        let h = size.height - 3
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * step, y: 1.5 + h * (1 - CGFloat(values[i] / top)))
        }
        // Smooth curve through the samples (midpoint quadratic curves).
        var line = Path()
        line.move(to: point(0))
        for i in 1..<values.count {
            let p0 = point(i - 1), p1 = point(i)
            line.addQuadCurve(to: CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), control: p0)
        }
        line.addLine(to: point(values.count - 1))

        // Afterglow: the past fades out to the left.
        func fading(_ a: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: [color.opacity(a * 0.15), color.opacity(a * 0.55), color.opacity(a)]),
                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
        }
        let quiet = !values.contains { $0 > 0 }
        if !quiet {
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.16), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: fading(0.10), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            context.stroke(line, with: fading(0.22), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        context.stroke(line, with: fading(quiet ? 0.45 : 1), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        // "Now": a bright point at the right-hand end.
        let now = point(values.count - 1)
        if !quiet {
            context.fill(Path(ellipseIn: CGRect(x: now.x - 7, y: now.y - 7, width: 14, height: 14)), with: .color(color.opacity(0.25)))
            context.fill(Path(ellipseIn: CGRect(x: now.x - 2.5, y: now.y - 2.5, width: 5, height: 5)), with: .color(.white))
        }
    }
}

// MARK: - Settings pointer

/// Where the General card used to be: the settings live in Glideball ›
/// Settings… (⌘,), so point people there.
private struct SettingsHint: View {
    var body: some View {
        RowGroup {
            SettingRow(title: "Looking for Open at login, Language, Updates or Keyboard shortcuts? They've moved to Settings. Press ⌘, any time Glideball is in front.",
                       hint: "Closing this window keeps Glideball running. Click Glideball in the Dock to bring it back, or press ⌘Q to quit. Your trackball then goes back to normal.",
                       symbol: "gearshape") {
                Button("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings() }
                    .controlSize(.small)
            }
        }
    }
}
