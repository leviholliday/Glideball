import Charts
import SwiftUI

struct PointerView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                GlassCard(title: "Feel", symbol: "slider.horizontal.3") {
                    TuningSlider(title: "Tracking speed", symbol: "gauge.with.dots.needle.67percent",
                                 value: $model.config.trackingSpeed, range: 0.5...80, step: 0.5,
                                 format: { String(format: "%.2g", $0) },
                                 lowLabel: "Slow", highLabel: "Ludicrous")
                    Text("System Settings tops out at 3. Glide lets the Expert Mouse go far past it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                GlassCard(title: "Presets", symbol: "wand.and.stars") {
                    PointerPresetRow(speed: $model.config.trackingSpeed)
                }
                GlassCard(title: "Precision mode", symbol: "scope") {
                    TuningSlider(title: "Precision speed", symbol: "tortoise",
                                 value: $model.config.precisionSpeed, range: 0.25...3, step: 0.05,
                                 format: { String(format: "%.2g", $0) },
                                 lowLabel: "Pixel-exact", highLabel: "macOS default")
                    Text("Set a button to Precision in Buttons. Hold it (or toggle it on) and the cursor slows to this speed for fine work, then snaps back.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Applies only to the Expert Mouse — your other mice and trackpad keep their own settings. macOS still moves the cursor itself, so there's zero added lag.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            .frame(width: 340)

            ResponseCurveCard(model: model)
        }
    }
}

/// Shape of the speed curve (an approximation of macOS's acceleration),
/// with a dot that follows the ball as you roll it.
struct ResponseCurveCard: View {
    let model: AppModel

    private struct P: Identifiable { let id: Int; let x: Double; let y: Double; let series: String }

    /// Rough shape of macOS's curve: higher tracking speed = more gain,
    /// growing with how fast the ball moves.
    static func cursorSpeed(ball v: Double, tracking t: Double) -> Double {
        v * (1 + t * 0.55 * pow(v, 0.8))
    }

    var body: some View {
        let speed = model.config.trackingSpeed
        let xs = stride(from: 0.0, through: 6.0, by: 0.1).map { $0 }
        let curve = xs.enumerated().map { P(id: $0, x: $1, y: Self.cursorSpeed(ball: $1, tracking: speed), series: "Glide") }
        let linear = xs.enumerated().map { P(id: 1000 + $0, x: $1, y: Self.cursorSpeed(ball: $1, tracking: 0), series: "1:1") }
        let liveX = min(model.liveBallSpeed, 6)
        let liveY = Self.cursorSpeed(ball: liveX, tracking: speed)
        // Fixed scale so a faster setting visibly bends the curve higher.
        let yMax = Self.cursorSpeed(ball: 6, tracking: 6)

        return GlassCard(title: "Response curve", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
            Chart {
                ForEach(linear) { p in
                    LineMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
                ForEach(curve) { p in
                    AreaMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                        .foregroundStyle(LinearGradient(colors: [.purple.opacity(0.45), .cyan.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Ball", p.x), y: .value("Cursor", p.y), series: .value("Series", p.series))
                        .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if model.liveBallSpeed > 0.02 {
                    PointMark(x: .value("Ball", liveX), y: .value("Cursor", liveY))
                        .symbolSize(180)
                        .foregroundStyle(.white)
                        .shadow(color: .cyan, radius: 8)
                }
            }
            .chartXScale(domain: 0...6)
            .chartYScale(domain: 0...yMax)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("How fast you roll the ball")
            .chartYAxisLabel("How fast the cursor moves")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)) } }
            .frame(height: 330)
            .animation(.smooth(duration: 0.25), value: speed)

            HStack(spacing: 14) {
                legend(color: .cyan, text: "Your curve")
                legend(color: .white.opacity(0.5), text: "No acceleration")
                Spacer()
                Text("Roll the ball to see where you are")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}
