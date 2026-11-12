import Charts
import SwiftUI

/// Pointer: how fast the cursor moves for a roll of the ball. Everything here
/// is about the ball, so every slider fill and the chart's line are ball blue.
struct PointerView: View {
    @Bindable var model: AppModel
    private static let defaults = GlideConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SectionBlock(title: "Feel",
                         caption: "Applies only to the Expert Mouse; your other mice and trackpad keep their own settings. macOS still moves the cursor itself, so there's no added lag.") {
                TuningSlider(title: "Tracking speed", symbol: "gauge.with.dots.needle.67percent",
                             value: $model.config.trackingSpeed, range: 0.5...80, step: 0.5,
                             format: { $0.twoDigits },
                             lowLabel: "Slow", highLabel: "Ludicrous",
                             hint: .verbatim(PointerHints.tracking(model.config.trackingSpeed)),
                             tint: Theme.ball, defaultValue: Self.defaults.trackingSpeed)
            }

            PlainSection(title: "Presets") {
                PointerPresetRow(speed: $model.config.trackingSpeed)
            }

            ResponseCurve(model: model)

            SectionBlock(title: "Precision mode",
                         caption: "Set a button to Precision in Buttons. Hold it (or toggle it on) and the cursor slows to this speed for fine work, then snaps back.") {
                TuningSlider(title: "Precision speed", symbol: "tortoise",
                             value: $model.config.precisionSpeed, range: 0.25...3, step: 0.05,
                             format: { $0.twoDigits },
                             lowLabel: "Pixel-exact", highLabel: "macOS default",
                             hint: .verbatim(PointerHints.precision(model.config.precisionSpeed, tracking: model.config.trackingSpeed)),
                             tint: Theme.ball, defaultValue: Self.defaults.precisionSpeed)
            }

            // Minimal hooks for the engine features; the proper design comes later.
            SectionBlock(title: "Per display",
                         caption: "A speed for each display, used while the pointer is on it. An app setup with its own speed still wins.") {
                ToggleRow(title: "Speed for each display", subtitle: nil, symbol: "display.2",
                          isOn: $model.config.displaySpeeds.enabled)
                if model.config.displaySpeeds.enabled {
                    ForEach(model.displays) { display in
                        TuningSlider(title: "\(display.name)", symbol: display.isMain ? "display" : "rectangle.on.rectangle",
                                     value: Binding(get: { model.displaySpeed(for: display) },
                                                    set: { model.setDisplaySpeed($0, for: display) }),
                                     range: 0.5...80, step: 0.5, format: { $0.twoDigits },
                                     tint: Theme.ball, defaultValue: model.config.trackingSpeed)
                    }
                }
            }

            if model.status.connection?.isWireless == true {
                SectionBlock(title: "Battery") {
                    ToggleRow(title: "Low battery alerts", subtitle: "Get a notification when the battery is low, and again when it’s nearly empty.",
                              symbol: "battery.25percent", isOn: $model.lowBatteryAlerts)
                }
            }
        }
    }
}

/// The one line under each Pointer slider: what its value does right now, from
/// the same numbers the engine writes (`PointerTuner` sets the tracking value as is).
enum PointerHints {
    /// System Settings' own pointer-speed slider stops here.
    static let systemMaximum = 3.0

    static func tracking(_ speed: Double) -> String {
        let ratio = speed / systemMaximum
        if abs(ratio - 1) < 0.02 { return String(localized: "The same as System Settings’ fastest speed.", comment: "Hint under the tracking speed slider") }
        if ratio < 1 { return String(localized: "\(ratio.wholePercent) of System Settings’ fastest speed.", comment: "Hint under the tracking speed slider; %@ is a percentage, like 50%") }
        return String(localized: "\(ratio.decimals(1))× System Settings’ fastest speed.", comment: "Hint under the tracking speed slider; %@ is a multiple, like 1.7")
    }

    /// While Precision is on the engine uses this value in place of the tracking speed.
    static func precision(_ precision: Double, tracking: Double) -> String {
        guard precision < tracking else {
            return String(localized: "As fast as your normal speed right now, so Precision won’t slow the cursor down.", comment: "Hint under the precision speed slider")
        }
        return String(localized: "While Precision is on, tracking drops to \((precision / tracking).wholePercent) of your normal speed.", comment: "Hint under the precision speed slider; %@ is a percentage, like 25%")
    }
}

/// The shape of the speed curve (an approximation of macOS's acceleration), with
/// a dot that follows the ball as you roll it. No card: a title, one trace in the
/// ball's blue over hairline guides, and plain-word axes.
struct ResponseCurve: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct P: Identifiable { let id: Int; let x: Double; let y: Double; let series: String }

    /// Rough shape of macOS's curve: higher tracking speed = more gain,
    /// growing with how fast the ball moves.
    static func cursorSpeed(ball v: Double, tracking t: Double) -> Double {
        v * (1 + t * 0.55 * pow(v, 0.8))
    }

    var body: some View {
        // The live dot follows the ball on its own timeline; nothing else on the page is redrawn for it.
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Response curve")
            LiveTimeline(feed: model.live, maxFPS: 20) { feed, _ in
                chart(liveBall: feed.ballSpeed)
            }
            HStack(spacing: 14) {
                legend(color: Theme.ball, text: "Your curve")
                legend(color: Color.secondary.opacity(0.7), text: "No acceleration", dashed: true)
                Spacer(minLength: 8)
                Text("Roll the ball to see where you are")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private func chart(liveBall: Double) -> some View {
        let speed = model.config.trackingSpeed
        let xs = stride(from: 0.0, through: 6.0, by: 0.1).map { $0 }
        let curve = xs.enumerated().map { P(id: $0, x: $1, y: Self.cursorSpeed(ball: $1, tracking: speed), series: "Glideball") }
        let linear = xs.enumerated().map { P(id: 1000 + $0, x: $1, y: Self.cursorSpeed(ball: $1, tracking: 0), series: "1:1") }
        let liveX = min(liveBall, 6)
        let liveY = Self.cursorSpeed(ball: liveX, tracking: speed)
        // Fixed scale so a faster setting visibly bends the curve higher.
        let yMax = Self.cursorSpeed(ball: 6, tracking: 6)

        return Chart {
            ForEach(linear) { p in
                LineMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(curve) { p in
                AreaMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                    .foregroundStyle(LinearGradient(colors: [Theme.ball.opacity(0.22), Theme.ball.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            // The curve glows: a wide soft stroke under the crisp one.
            ForEach(curve) { p in
                LineMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", "glow"))
                    .foregroundStyle(Theme.ball.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 9, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(curve) { p in
                LineMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                    .foregroundStyle(LinearGradient(colors: [Theme.ball.opacity(0.6), Theme.ball, Theme.orbCyan],
                                                    startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if liveBall > 0.02 {
                // Where you are right now: the dot rides the curve, with a line down to how fast you're rolling.
                RuleMark(x: .value("Ball", liveX), yStart: .value("Cursor", 0), yEnd: .value("Cursor", liveY))
                    .foregroundStyle(LinearGradient(colors: [Theme.ball.opacity(0), Theme.ball.opacity(0.7)], startPoint: .bottom, endPoint: .top))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                PointMark(x: .value("Ball", liveX), y: .value("Cursor", liveY))
                    .symbol { LiveDot(color: Theme.ball, glow: true) }
            }
        }
        .chartXScale(domain: 0...6)
        .chartYScale(domain: 0...yMax)
        .chartPlotStyle { $0.clipped() }
        .chartXAxisLabel(position: .bottom, alignment: .leading) {
            Text("How fast you roll the ball").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text("How fast the cursor moves").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in ChartGrid.line } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in ChartGrid.line } }
        .frame(height: 230)
        .animation(reduceMotion ? nil : Theme.Motion.spring, value: speed)
    }

    private func legend(color: Color, text: LocalizedStringKey, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Group {
                if dashed {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 1))
                        p.addLine(to: CGPoint(x: 16, y: 1))
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3.5, 2.5]))
                    .frame(height: 2)
                } else {
                    Capsule().fill(color).frame(height: 2)
                }
            }
            .frame(width: 16)
            Text(text).font(Theme.Font.hint.weight(.medium)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

// MARK: - Chart pieces

/// Hairline guides for a chart: faint, half a point.
enum ChartGrid {
    /// Axis titles and numbers: the system's secondary text color (a chart's own `.secondary` comes out too faint).
    static let text = Color(nsColor: .secondaryLabelColor)

    static var line: some AxisMark {
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.gridLine)
    }
}

/// Where you are right now on a chart: a dot in the part's color with a thin
/// ring of the stage's color so it reads over the trace. It's the ball's (or
/// the ring's) own light, so it may glow.
struct LiveDot: View {
    let color: Color
    var glow = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .background {
                if glow {
                    Circle().fill(RadialGradient(colors: [color.opacity(0.6), color.opacity(0)], center: .center,
                                                 startRadius: 3, endRadius: 16))
                        .frame(width: 32, height: 32)
                }
            }
    }
}
