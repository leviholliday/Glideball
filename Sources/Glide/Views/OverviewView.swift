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
                Chart(model.activity) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Ball", p.ballSpeed))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.cyan.opacity(0.55), .cyan.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Ball", p.ballSpeed))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXScale(domain: -AppModel.historySeconds...0)
                .chartYScale(domain: 0...max(4, (model.activity.map(\.ballSpeed).max() ?? 0) * 1.2))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)) } }
                .frame(height: 90)

                legend("Scroll ring", color: .pink, value: String(format: "%.0f notches/s", model.liveNotchRate))
                    .padding(.top, 8)
                Chart(model.activity) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Notches", p.notchRate))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.pink.opacity(0.55), .pink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Notches", p.notchRate))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXScale(domain: -AppModel.historySeconds...0)
                .chartYScale(domain: 0...max(10, (model.activity.map(\.notchRate).max() ?? 0) * 1.2))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)) } }
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
