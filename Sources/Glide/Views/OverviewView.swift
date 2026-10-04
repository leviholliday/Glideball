import Charts
import SwiftUI

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                GlassCard {
                    TrackballView(pressed: model.pressed, ballSpeed: model.liveBallSpeed,
                                  notchRate: model.liveNotchRate, ringAngle: model.ringAngle,
                                  ballPhase: model.ballPhase)
                        .frame(maxWidth: .infinity)
                        .animation(.linear(duration: 1 / AppModel.sampleRate), value: model.ringAngle)
                    Text(!model.permissionsOK ? "Waiting for permissions…"
                         : model.status.deviceConnected ? "Roll, spin, or click — it's live." : "Plug in your Expert Mouse.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 270)

                VStack(spacing: 18) {
                    ActivityChartCard(model: model)
                    HStack(spacing: 18) {
                        StatTile(symbol: "cursorarrow.click.2", title: "Clicks today",
                                 value: model.totals.clicks.formatted())
                        StatTile(symbol: "circle.dotted.circle", title: "Ball rolled",
                                 value: Self.meters(model.totals.ballCounts / AppModel.countsPerInch * 0.0254))
                        StatTile(symbol: "scroll", title: "Scrolled",
                                 value: Self.meters(model.totals.scrollPoints * 0.00023))
                    }
                }
            }

            GlassCard(title: "General", symbol: "gearshape") {
                ToggleRow(title: "Open at login", subtitle: "Starts quietly in the background so your trackball is always tuned.",
                          symbol: "power", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Divider().opacity(0.4)
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Feedback").font(.system(size: 14, weight: .medium))
                        Text("Found a bug or have an idea? It goes straight to the developer.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.showingFeedback = true
                    } label: {
                        Label("Send Feedback…", systemImage: "paperplane")
                    }
                    .buttonStyle(.glass)
                }
                Divider().opacity(0.4)
                Text("Closing this window keeps Glide running. Click Glide in the Dock to bring it back, or press ⌘Q to quit — your trackball then goes back to normal.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func meters(_ m: Double) -> String {
        if m < 1 { return String(format: "%.0f cm", m * 100) }
        if m < 1000 { return String(format: "%.1f m", m) }
        return String(format: "%.2f km", m / 1000)
    }
}

struct StatTile: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct ActivityChartCard: View {
    let model: AppModel

    var body: some View {
        GlassCard(title: "Live activity", symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 4) {
                legend("Ball speed", color: .cyan, value: String(format: "%.1f in/s", model.liveBallSpeed))
                Sparkline(values: model.activity.map(\.ballSpeed), floor: 4, color: .cyan)
                    .frame(height: 90)

                legend("Scroll ring", color: .pink, value: String(format: "%.0f notches/s", model.liveNotchRate))
                    .padding(.top, 8)
                Sparkline(values: model.activity.map(\.notchRate), floor: 10, color: .pink)
                    .frame(height: 70)
            }
        }
    }

    private func legend(_ name: String, color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A live area + line graph drawn straight into a Canvas. Far cheaper than
/// Swift Charts for data that changes 30 times a second.
struct Sparkline: View {
    let values: [Double]
    /// The y-axis never shrinks below this, so a quiet trackball reads as quiet.
    let floor: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(floor, (values.max() ?? 0) * 1.2)
            let step = size.width / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(values[i] / top)))
            }

            // Faint guide lines at a third and two thirds.
            for f in [1.0 / 3, 2.0 / 3] {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: size.height * f))
                guide.addLine(to: CGPoint(x: size.width, y: size.height * f))
                context.stroke(guide, with: .color(.white.opacity(0.08)), lineWidth: 1)
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
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.55), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
