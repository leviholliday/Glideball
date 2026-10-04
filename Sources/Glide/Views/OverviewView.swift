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
                    deviceCaption
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 270)

                VStack(spacing: 18) {
                    ActivityChartCard(model: model)
                    HStack(spacing: 18) {
                        StatTile(symbol: "cursorarrow.click.2", title: "Clicks today",
                                 amount: Double(model.totals.clicks), format: { Int($0.rounded()).formatted() },
                                 best: best(.clicks))
                        StatTile(symbol: "circle.dotted.circle", title: "Ball rolled",
                                 amount: model.totals.ballCounts / AppModel.countsPerInch * 0.0254, format: Self.meters,
                                 best: best(.ball))
                        StatTile(symbol: "scroll", title: "Scrolled",
                                 amount: model.totals.scrollPoints * 0.00023, format: Self.meters, best: best(.scroll))
                    }
                    .fixedSize(horizontal: false, vertical: true)   // equal heights with or without a best-day bar
                }
            }

            if model.delight.checklistVisible {
                MakeItYoursCard(delight: model.delight) { model.requestedTab = $0 }
                    .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.96).combined(with: .opacity)))
            }
            YourTrackballCard(delight: model.delight)

            GlassCard(title: "General", symbol: "gearshape") {
                ToggleRow(title: "Open at login", subtitle: "Starts quietly in the background so your trackball is always tuned.",
                          symbol: "power", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Divider().opacity(0.4)
                ToggleRow(title: "Menu bar icon",
                          subtitle: "Quick access to pause, precision and updates. Glide keeps running either way — reopen it from the Dock.",
                          symbol: "menubar.rectangle", isOn: $model.menuBarIcon)
                Divider().opacity(0.4)
                UpdatesRow(updates: model.updates)
                Divider().opacity(0.4)
                ToggleRow(title: "Beta program",
                          subtitle: "Try features before they're finished — like support for other Kensington trackballs and early updates. You may hit bugs.",
                          symbol: "flask", isOn: $model.betaProgram)
                Divider().opacity(0.4)
                ToggleRow(title: "Celebrations",
                          subtitle: "A toast and a little confetti when you reach a milestone or set a personal best. Badges are kept either way.",
                          symbol: "party.popper", isOn: Bindable(model.delight).celebrationsOn)
                ToggleRow(title: "Celebration sounds", subtitle: "A soft chime to go with them.",
                          symbol: "speaker.wave.2", isOn: Bindable(model.delight).soundsOn)
                    .disabled(!model.delight.celebrationsOn)
                    .opacity(model.delight.celebrationsOn ? 1 : 0.5)
                Divider().opacity(0.4)
                ToggleRow(title: "Launch sounds", subtitle: "A soft chime as Glide opens. Never when your Mac is muted.",
                          symbol: "music.note", isOn: Bindable(LaunchExperience.shared).soundsOn)
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

            KeyboardShortcutsCard(model: model)
        }
    }

    /// What's connected, under the trackball picture.
    @ViewBuilder private var deviceCaption: some View {
        let status = model.status
        if !model.permissionsOK {
            caption("Waiting for permissions…")
        } else if status.deviceConnected {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(status.deviceName ?? "Kensington Expert Mouse")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if status.deviceIsBeta { BetaBadge() }
                }
                caption("Roll, spin, or click — it's live.")
            }
        } else if let name = status.unsupportedDeviceName {
            // A Kensington Glide only supports in the Beta program: a gentle nudge, not an error.
            VStack(spacing: 8) {
                caption("Turn on the Beta program to try Glide with your \(name).")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.betaProgram = true
                } label: {
                    Label("Turn On Beta", systemImage: "flask")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        } else {
            caption("Plug in your Expert Mouse.")
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    /// Today against your best earlier day, once there are a few days to compare.
    private func best(_ metric: Metric) -> StatTile.Best? {
        let d = model.delight
        let best = d.pastBest.value(metric)
        guard d.historyDays >= DelightLedger.minHistoryDays, best >= DelightLedger.meaningfulDay(metric) else { return nil }
        return .init(fraction: d.today.value(metric) / best, label: metric.format(best), color: metric.color)
    }

    static func meters(_ m: Double) -> String {
        if m < 1 { return Tally.length(m * 100, .centimeters, digits: 0) }
        if m < 1000 { return Tally.length(m, .meters, digits: 1) }
        return Tally.length(m / 1000, .kilometers, digits: 2)
    }
}

struct StatTile: View {
    let symbol: String
    let title: LocalizedStringKey
    /// The number, and how to show it. It counts up from zero when the tile
    /// appears, and glides to new values after that.
    let amount: Double
    let format: (Double) -> String
    /// Today compared with your best day — progress, never a deadline.
    var best: Best? = nil

    struct Best: Equatable {
        let fraction: Double
        let label: String
        let color: Color
    }

    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let best, best.fraction > 1 {
                    Label("Best day", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            CountingText(value: shown, format: format)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            if let best {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule()
                            .fill(LinearGradient(colors: [best.color.opacity(0.6), best.color],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * min(best.fraction, 1)))
                            .shadow(color: best.fraction > 1 ? best.color : .clear, radius: 4)
                    }
                }
                .frame(height: 4)
                .animation(.smooth(duration: 0.5), value: best.fraction)
                .help("Your best day so far: \(best.label)")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: (best?.fraction ?? 0) > 1)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .staggeredAppear()
        .onAppear {
            if reduceMotion || amount == 0 { shown = amount; return }
            withAnimation(.smooth(duration: 0.9).delay(0.12)) { shown = amount }
        }
        .onChange(of: amount) { _, now in
            withAnimation(.smooth(duration: 0.3)) { shown = now }
        }
    }
}

/// A number drawn from an animatable value, so it counts as it animates.
private struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(format(value)) }
}

struct ActivityChartCard: View {
    let model: AppModel

    var body: some View {
        GlassCard(title: "Live activity", symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 4) {
                legend("Ball speed", color: .cyan,
                       value: String(localized: "\(model.liveBallSpeed.formatted(.number.precision(.fractionLength(1)))) in/s",
                                     comment: "Ball speed in inches per second"))
                Sparkline(values: model.activity.map(\.ballSpeed), floor: 4, color: .cyan)
                    .frame(height: 90)

                legend("Scroll ring", color: .pink,
                       value: String(localized: "\(model.liveNotchRate.formatted(.number.precision(.fractionLength(0)))) notches/s",
                                     comment: "Scroll ring speed: ring notches (ticks) per second"))
                    .padding(.top, 8)
                Sparkline(values: model.activity.map(\.notchRate), floor: 10, color: .pink)
                    .frame(height: 70)
            }
        }
    }

    private func legend(_ name: LocalizedStringKey, color: Color, value: String) -> some View {
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

/// "Glide 2.6 — up to date" with a Check for Updates button.
struct UpdatesRow: View {
    let updates: UpdateChecker

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Updates").font(.system(size: 14, weight: .medium))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if let update = updates.available {
                Button("Install \(GlideVersion(update.version)?.display ?? update.version)") { updates.install() }
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
            } else {
                Button {
                    updates.checkNow()
                } label: {
                    if updates.manualCheck == .checking {
                        ProgressView().controlSize(.small).frame(width: 110)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .buttonStyle(.glass)
                .disabled(updates.manualCheck == .checking)
            }
        }
        .animation(.smooth, value: updates.manualCheck)
    }

    private var status: String {
        let current = "Glide \(GlideVersion(updates.currentVersion)?.display ?? updates.currentVersion)"
        if let update = updates.available {
            let new = GlideVersion(update.version)?.display ?? update.version
            return String(localized: "\(current) · \(new) is ready to install", comment: "Glide 2.6 · 2.7 is ready to install")
        }
        switch updates.manualCheck {
        case .upToDate: return String(localized: "\(current) · You’re up to date ✓", comment: "%@ is “Glide 2.6”")
        case .failed: return String(localized: "\(current) · Couldn’t reach GitHub — try again later", comment: "%@ is “Glide 2.6”")
        case .checking: return String(localized: "\(current) · Checking…", comment: "%@ is “Glide 2.6”")
        case .idle: return String(localized: "\(current) · Checks automatically once a day", comment: "%@ is “Glide 2.6”")
        }
    }
}
