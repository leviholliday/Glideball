import Charts
import SwiftUI

/// Overview is not a dashboard: today as three numbers, one live chart, what's
/// left to set up, and the trackball's history. Type and spacing, no tiles.
struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section + 4) {
            TodayStats(model: model)
            LiveActivity(feed: model.live)
            if model.delight.checklistVisible {
                MakeItYoursCard(delight: model.delight) { model.requestedTab = $0 }
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

// MARK: - Today

/// Three numbers in a row, divided by hairlines: big rounded numerals, a small
/// label with the part's dot, and a thin line toward your best day once there's one.
private struct TodayStats: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Today")
            HStack(alignment: .top, spacing: 0) {
                stat(.clicks, value: Int(model.totals.clicks).formatted(), label: "Clicks today")
                Hairline(vertical: true).padding(.horizontal, 20)
                stat(.ball, value: OverviewView.meters(model.totals.ballCounts / AppModel.countsPerInch * 0.0254), label: "Ball rolled")
                Hairline(vertical: true).padding(.horizontal, 20)
                stat(.scroll, value: OverviewView.meters(model.totals.scrollPoints * 0.00023), label: "Scrolled")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ metric: Metric, value: String, label: LocalizedStringKey) -> some View {
        let best = best(metric)
        return VStack(alignment: .leading, spacing: 8) {
            InlineStat(value: value, label: label, color: metric.color)
            if let best {
                BestDayLine(fraction: best.fraction, color: metric.color)
                    .help("Your best day so far: \(best.label)")
                Text(best.fraction > 1 ? String(localized: "Best day") : String(localized: "Best \(best.label)", comment: "Under a number on Overview: your best day's amount; %@ is the amount"))
                    .font(Theme.Font.hint)
                    .foregroundStyle(best.fraction > 1 ? AnyShapeStyle(metric.color) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Today against your best earlier day, once there are a few days to compare.
    private func best(_ metric: Metric) -> (fraction: Double, label: String)? {
        let d = model.delight
        let best = d.pastBest.value(metric)
        guard d.historyDays >= DelightLedger.minHistoryDays, best >= DelightLedger.meaningfulDay(metric) else { return nil }
        return (d.today.value(metric) / best, metric.format(best))
    }
}

/// A 2 pt line: how far today has come toward your best day.
private struct BestDayLine: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.gridLine)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(fraction, 1)))
            }
        }
        .frame(height: 2)
        .animation(Theme.Motion.spring, value: fraction)
    }
}

// MARK: - Live activity

/// One chart, two traces (ball blue, ring pink), no chrome. Redrawn on its own
/// timeline while something moves; the page around it never is.
private struct LiveActivity: View {
    let feed: LiveFeed

    var body: some View {
        LiveTimeline(feed: feed, maxFPS: 30) { feed, _ in
            VStack(alignment: .leading, spacing: 10) {
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
                LiveChart(ball: feed.ballHistory, ring: feed.notchHistory)
                    .frame(height: 120)
                    .overlay {
                        if !feed.isActive {
                            Text("Roll or spin to see it move")
                                .font(Theme.Font.hint)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .background(Theme.windowBackground)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Live activity")
                    .accessibilityValue("\(feed.ballSpeed.formatted(.number.precision(.fractionLength(1)))) in/s")
            }
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

/// Both traces over one baseline, each on its own scale (the y-axis never
/// shrinks below a floor, so a quiet trackball reads as quiet). Drawn straight
/// into a Canvas: far cheaper than Swift Charts for data that changes 30 times a second.
struct LiveChart: View {
    let ball: [Double]
    let ring: [Double]

    var body: some View {
        Canvas { context, size in
            // Faint guides at a third and two thirds, and the baseline, one pixel thick.
            let pixel = 1 / max(context.environment.displayScale, 1)
            for f in [1.0 / 3, 2.0 / 3] {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: size.height * f))
                guide.addLine(to: CGPoint(x: size.width, y: size.height * f))
                context.stroke(guide, with: .color(Theme.gridLine), lineWidth: pixel)
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - pixel * 1.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - pixel * 1.5))
            context.stroke(base, with: .color(Theme.hairline), lineWidth: pixel)

            trace(ring, floor: 10, color: Theme.ring, in: context, size: size)
            trace(ball, floor: 4, color: Theme.ball, in: context, size: size)
        }
    }

    private func trace(_ values: [Double], floor: Double, color: Color, in context: GraphicsContext, size: CGSize) {
        // Nothing to show (no trackball, or a quiet stretch): just the baseline.
        guard values.count > 1, values.contains(where: { $0 > 0 }) else { return }
        let top = max(floor, (values.max() ?? 0) * 1.15)
        let step = size.width / CGFloat(values.count - 1)
        let h = size.height - 1.5
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * step, y: 1 + h * (1 - CGFloat(values[i] / top)))
        }
        // Smooth curve through the samples (midpoint quadratic curves).
        var line = Path()
        line.move(to: point(0))
        for i in 1..<values.count {
            let p0 = point(i - 1), p1 = point(i)
            line.addQuadCurve(to: CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), control: p0)
        }
        line.addLine(to: point(values.count - 1))

        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.18), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Settings pointer

/// Where the General card used to be: the settings live in Glideball ›
/// Settings… (⌘,), so point people there.
private struct SettingsHint: View {
    var body: some View {
        RowGroup {
            SettingRow(title: "Looking for Open at login, Language, Updates or Keyboard shortcuts? They've moved to Settings. Press ⌘, any time Glideball is in front.",
                       hint: "Closing this window keeps Glideball running. Click Glideball in the Dock to bring it back, or press ⌘Q to quit — your trackball then goes back to normal.",
                       symbol: "gearshape") {
                Button("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings() }
                    .controlSize(.small)
            }
        }
    }
}
