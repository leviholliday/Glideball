import Charts
import SwiftUI

struct ScrollSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ModePicker(mode: $model.config.scrollMode)
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    ScrollControls(config: $model.config)
                    ballScrollCard
                }
                .frame(width: 340)

                VStack(spacing: 18) {
                    switch model.config.scrollMode {
                    case .native:
                        EmptyView()
                    case .flywheel:
                        FlywheelCurveCard(config: model.config, liveRate: model.liveNotchRate)
                    case .follow:
                        ThrowCard(config: model.config)
                        SpinCurveCard(config: model.config, liveRate: model.liveNotchRate)
                    }
                    TryItCard()
                }
            }
        }
    }

    private var ballScrollCard: some View {
        GlassCard(title: "Scroll with the ball", symbol: "arrow.up.and.down.and.arrow.left.and.right") {
            TuningSlider(title: "Ball scroll speed", symbol: "gauge.with.dots.needle.50percent",
                         value: $model.config.ballScrollSpeed, range: 0.25...4, step: 0.05,
                         format: { String(format: "%.2g×", $0) }, lowLabel: "Fine", highLabel: "Fast")
            Text("Set a button to “Scroll with ball” in Buttons. While you hold it, rolling the ball scrolls in any direction and the cursor stays put. Let go mid-roll and the page glides briefly.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The tuning cards for the chosen scroll mode. Shared by the Scrolling tab
/// and app setups; only the scrolling fields of `config` are touched.
struct ScrollControls: View {
    @Binding var config: GlideConfig

    private struct Preset: Identifiable {
        let name: String, symbol: String
        let distance: Double, smooth: Double, accel: Double, throwOn: Bool, throwAmount: Double
        var id: String { name }
    }
    private let presets: [Preset] = [
        .init(name: "Precise", symbol: "scope", distance: 10, smooth: 0.25, accel: 0.25, throwOn: false, throwAmount: 0.3),
        .init(name: "Control", symbol: "hand.raised.fingers.spread", distance: 14, smooth: 0.4, accel: 0.5, throwOn: true, throwAmount: 0.4),
        .init(name: "Fling", symbol: "wind", distance: 18, smooth: 0.5, accel: 0.7, throwOn: true, throwAmount: 0.75),
    ]

    var body: some View {
        VStack(spacing: 18) {
            switch config.scrollMode {
            case .native: nativeCards
            case .flywheel: flywheelCards
            case .follow: followCards
            }
            if config.scrollMode != .native { directionCard }
        }
    }

    @ViewBuilder private var nativeCards: some View {
        GlassCard(title: "macOS scrolling", symbol: "applelogo") {
            Text("Glide steps aside and lets macOS scroll the ring itself — the same system Kensington's driver handed its ticks to. Only the speed is adjustable.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TuningSlider(title: "Scroll speed", symbol: "gauge.with.dots.needle.50percent",
                         value: $config.nativeScrollSpeed, range: 0...5, step: 0.05,
                         format: { String(format: "%.2f", $0) }, lowLabel: "Slow", highLabel: "Fast")
            Text("System Settings' scroll-speed slider goes up to 1.7. This only affects the Expert Mouse.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var flywheelCards: some View {
        GlassCard(title: "Flywheel", symbol: "fanblades") {
            Text("Every tick gives the page a push; friction slows it down. Gentle turns barely coast, hard spins fly — one rule, no mode switching. Tuned from Kensington's own scrolling, at twice its frame rate.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TuningSlider(title: "Slow-turn distance", symbol: "arrow.up.and.down",
                         value: $config.flyDistance, range: 1...20, step: 1,
                         format: { "\(Int($0)) pt" }, lowLabel: "Precise", highLabel: "Far")
            TuningSlider(title: "Spin power", symbol: "tornado",
                         value: $config.flyAcceleration, range: 0...1.5,
                         format: { "\(Int($0 * 100))%" }, lowLabel: "Gentle", highLabel: "Wild")
            TuningSlider(title: "Glide", symbol: "wind",
                         value: $config.flyGlide, range: 0...1,
                         format: { "\(Int(SmoothScroller.flyTau(glide: $0) * 1000)) ms" },
                         lowLabel: "Grippy", highLabel: "Slippery")
            ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                      symbol: "water.waves", isOn: $config.smoothScrolling)
            Button("Kensington feel") {
                withAnimation(.smooth) {
                    config.flyDistance = 4; config.flyAcceleration = 0.5; config.flyGlide = 0.35
                    config.smoothScrolling = true
                }
            }
            .buttonStyle(.glass)
        }
    }

    @ViewBuilder private var followCards: some View {
                GlassCard(title: "Presets", symbol: "wand.and.stars") {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(presets) { p in
                                Button {
                                    withAnimation(.smooth) {
                                        config.scrollDistance = p.distance
                                        config.scrollSmoothness = p.smooth
                                        config.scrollAcceleration = p.accel
                                        config.throwEnabled = p.throwOn
                                        config.throwAmount = p.throwAmount
                                        config.smoothScrolling = true
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: p.symbol).font(.system(size: 18))
                                        Text(p.name).font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    Text("Control is the recommended starting point: the page follows the ring and stops when you stop.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GlassCard(title: "Feel", symbol: "slider.horizontal.3") {
                    ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                              symbol: "water.waves", isOn: $config.smoothScrolling)
                    TuningSlider(title: "Distance per notch", symbol: "arrow.up.and.down",
                                 value: $config.scrollDistance, range: 1...40, step: 1,
                                 format: { "\(Int($0)) pt" }, lowLabel: "Fine", highLabel: "Far")
                    TuningSlider(title: "Follow", symbol: "hand.point.up.left",
                                 value: $config.scrollSmoothness, range: 0...1,
                                 format: { "\(Int(SmoothScroller.timeConstant(smoothness: $0) * 1000)) ms" },
                                 lowLabel: "Locked to ring", highLabel: "Softer")
                        .disabled(!config.smoothScrolling)
                    TuningSlider(title: "Spin acceleration", symbol: "tornado",
                                 value: $config.scrollAcceleration, range: 0...1,
                                 format: { $0 < 0.01 ? "Off" : "\(Int($0 * 100))%" },
                                 lowLabel: "Constant", highLabel: "Spin to fly")
                }
                GlassCard(title: "Throw", symbol: "paperplane") {
                    ToggleRow(title: "Throw to coast", subtitle: "Spin fast and let go — the page glides and lands",
                              symbol: "paperplane.fill", isOn: $config.throwEnabled)
                    TuningSlider(title: "Throw distance", symbol: "ruler",
                                 value: $config.throwAmount, range: 0...1,
                                 format: { String(format: "%.1f s", SmoothScroller.throwDuration(speed: ThrowCard.typicalSpeed(config), throwAmount: $0)) },
                                 lowLabel: "Short", highLabel: "Long")
                        .disabled(!config.throwEnabled)
                }
    }

    private var directionCard: some View {
                GlassCard(title: "Direction", symbol: "arrow.left.arrow.right") {
                    ToggleRow(title: "Flip direction", subtitle: "Only if it scrolls the wrong way with your scroll reverser",
                              symbol: "arrow.up.arrow.down", isOn: $config.reverseScroll)
                    ToggleRow(title: "Shift scrolls sideways", subtitle: "Hold ⇧ while spinning the ring",
                              symbol: "shift", isOn: $config.shiftScrollsHorizontally)
                }
    }
}

struct ModePicker: View {
    @Binding var mode: ScrollMode
    @Namespace private var ns

    private func info(_ m: ScrollMode) -> (String, String, String) {
        switch m {
        case .native: ("Native", "applelogo", "macOS does the scrolling")
        case .flywheel: ("Flywheel", "fanblades", "Push and glide — Kensington's feel")
        case .follow: ("Follow", "hand.point.up.left", "Page tracks the ring exactly")
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ScrollMode.allCases) { m in
                    let (title, symbol, subtitle) = info(m)
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { mode = m }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol).font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title).font(.system(size: 14, weight: .semibold))
                                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background {
                            if mode == m {
                                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}

/// Distance one tick adds at each spin speed, in Flywheel mode.
struct FlywheelCurveCard: View {
    let config: GlideConfig
    let liveRate: Double
    private struct P: Identifiable { let id: Int; let rate: Double; let pt: Double }

    var body: some View {
        let pts = stride(from: 0.0, through: 70, by: 1).enumerated().map {
            P(id: $0, rate: $1, pt: SmoothScroller.flyTickDistance(rate: $1, distance: config.flyDistance, acceleration: config.flyAcceleration))
        }
        let live = min(liveRate, 70)
        return GlassCard(title: "Push per tick", symbol: "fanblades") {
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Spin", p.rate), y: .value("pt", p.pt))
                        .foregroundStyle(LinearGradient(colors: [.cyan.opacity(0.4), .cyan.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Spin", p.rate), y: .value("pt", p.pt))
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if liveRate > 0.2 {
                    PointMark(x: .value("Spin", live),
                              y: .value("pt", SmoothScroller.flyTickDistance(rate: live, distance: config.flyDistance, acceleration: config.flyAcceleration)))
                        .symbolSize(160).foregroundStyle(.white)
                }
            }
            .chartXScale(domain: 0...70)
            .chartXAxisLabel("Ring ticks per second")
            .chartYAxisLabel("Points per tick")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .frame(height: 220)
            .animation(.smooth(duration: 0.25), value: config.flyAcceleration)
            Text(String(format: "Each push coasts for about %.1f s before it fades out. Turn the ring the other way to stop it.",
                        SmoothScroller.flyTau(glide: config.flyGlide) * 6))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// What a typical flick does after you let go — the same math the engine uses
/// (macOS's own deceleration shape: it lands at a definite moment).
struct ThrowCard: View {
    let config: GlideConfig
    private struct P: Identifiable { let id: Int; let ms: Double; let speed: Double }

    /// Release speed of a typical Expert Mouse flick (45 ticks/s).
    static func typicalSpeed(_ config: GlideConfig) -> Double {
        let rate = 45.0
        return config.scrollDistance * rate * SmoothScroller.accelerationMultiplier(rate: rate, amount: config.scrollAcceleration)
    }

    var body: some View {
        let v0 = min(Self.typicalSpeed(config), SmoothScroller.throwMaxSpeed)
        let duration = SmoothScroller.throwDuration(speed: v0, throwAmount: config.throwAmount)
        let distance = SmoothScroller.throwDistance(speed: v0, throwAmount: config.throwAmount)
        let pts = stride(from: 0.0, through: 1600, by: 10).enumerated().map { i, ms -> P in
            let t = ms / 1000
            let v = config.throwEnabled && t < duration ? v0 * pow(1 - t / duration, 3) : 0
            return P(id: i, ms: ms, speed: v)
        }
        return GlassCard(title: "After a flick", symbol: "paperplane") {
            Chart(pts) { p in
                AreaMark(x: .value("ms", p.ms), y: .value("Speed", p.speed))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [.pink.opacity(0.5), .purple.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("ms", p.ms), y: .value("Speed", p.speed))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .chartXScale(domain: 0...1600)
            .chartYScale(domain: 0...max(v0, 1))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [0, 400, 800, 1200, 1600]) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0) ms") }
                }
            }
            .frame(height: 110)
            .animation(.smooth(duration: 0.25), value: config.throwAmount)
            Text(config.throwEnabled
                 ? "A typical flick coasts about \(Int(distance)) pt and lands after \(Int(duration * 1000)) ms — then stops dead. Slow down before letting go and it doesn't coast at all. Turn the ring back to catch it."
                 : "Throw is off — the page stops the moment the ring stops.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Distance multiplier vs how fast the ring spins, with a live dot.
struct SpinCurveCard: View {
    let config: GlideConfig
    let liveRate: Double

    private struct P: Identifiable { let id: Int; let rate: Double; let mult: Double }

    var body: some View {
        let pts = stride(from: 0.0, through: 70.0, by: 0.5).enumerated().map {
            P(id: $0, rate: $1, mult: SmoothScroller.accelerationMultiplier(rate: $1, amount: config.scrollAcceleration))
        }
        let live = min(liveRate, 70)
        let yMax = max(pts.last?.mult ?? 2, 2) * 1.05

        return GlassCard(title: "Spin acceleration", symbol: "tornado") {
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Spin", p.rate), y: .value("×", p.mult))
                        .foregroundStyle(LinearGradient(colors: [.cyan.opacity(0.4), .cyan.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Spin", p.rate), y: .value("×", p.mult))
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if liveRate > 0.2 {
                    PointMark(x: .value("Spin", live),
                              y: .value("×", SmoothScroller.accelerationMultiplier(rate: live, amount: config.scrollAcceleration)))
                        .symbolSize(160)
                        .foregroundStyle(.white)
                }
            }
            .chartXScale(domain: 0...70)
            .chartYScale(domain: 0...yMax)
            .chartXAxisLabel("Ring ticks per second")
            .chartYAxisLabel("Distance ×")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .frame(height: 130)
            .animation(.smooth(duration: 0.25), value: config.scrollAcceleration)
        }
    }
}

struct TryItCard: View {
    var body: some View {
        GlassCard(title: "Try it here", symbol: "hand.point.up.left") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(1...300, id: \.self) { i in
                        HStack {
                            Circle()
                                .fill(Color(hue: Double(i % 30) / 30, saturation: 0.55, brightness: 0.95))
                                .frame(width: 10, height: 10)
                            Text("Row \(i)").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Capsule().fill(.white.opacity(0.12)).frame(width: CGFloat(30 + (i * 37) % 120), height: 6)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 150)
        }
    }
}
