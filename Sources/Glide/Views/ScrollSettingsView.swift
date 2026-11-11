import Charts
import SwiftUI

/// Scrolling: one clear choice of mode at the top, then that mode's controls, its
/// charts, a place to try it, and the settings every mode shares. Everything about
/// the ring is ring pink (slider fills, chart traces); scrolling with the ball is
/// about the ball, so that one slider is ball blue.
struct ScrollSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let defaults = GlideConfig()

    var body: some View {
        let controls = ScrollControls(config: $model.config)
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            PlainSection(title: "Scroll mode") {
                ModePicker(mode: $model.config.scrollMode)
            }

            switch model.config.scrollMode {
            case .native:
                controls.nativeSection
            case .flywheel:
                controls.flywheelSection
                LiveTimeline(feed: model.live, maxFPS: 20) { feed, _ in
                    FlywheelCurve(config: model.config, liveRate: feed.notchRate)
                }
            case .follow:
                controls.presetsSection
                controls.feelSection
                LiveTimeline(feed: model.live, maxFPS: 20) { feed, _ in
                    SpinCurve(config: model.config, liveRate: feed.notchRate)
                }
                controls.throwSection
                ThrowCurve(config: model.config)
            }

            if model.config.scrollMode != .native { controls.directionSection }

            TryItArea()

            SectionBlock(title: "Scroll with the ball",
                         caption: "Set a button to “Scroll with ball” in Buttons. While you hold it, rolling the ball scrolls in any direction and the cursor stays put. Let go mid-roll and the page glides briefly.") {
                TuningSlider(title: "Ball scroll speed", symbol: "gauge.with.dots.needle.50percent",
                             value: $model.config.ballScrollSpeed, range: 0.25...4, step: 0.05,
                             format: { "\($0.twoDigits)×" }, lowLabel: "Fine", highLabel: "Fast",
                             hint: .verbatim(ScrollHints.ballScroll(model.config.ballScrollSpeed)),
                             tint: Theme.ball, defaultValue: Self.defaults.ballScrollSpeed)
            }
        }
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.spring), value: model.config.scrollMode)
    }
}

// MARK: - The hints

/// The one line under each Scrolling slider: what its value does right now, worked
/// out from the same functions the engine runs (`SmoothScroller`), never a claim
/// the code doesn't keep.
enum ScrollHints {
    /// System Settings' own scroll-speed slider stops here.
    static let systemMaximum = 1.7

    static func nativeSpeed(_ speed: Double) -> String {
        let ratio = speed / systemMaximum
        if abs(ratio - 1) < 0.02 { return String(localized: "The same as System Settings’ fastest scroll speed.", comment: "Hint under the Native scroll speed slider") }
        if ratio < 1 { return String(localized: "\(ratio.wholePercent) of System Settings’ fastest scroll speed.", comment: "Hint under the Native scroll speed slider; %@ is a percentage, like 50%") }
        return String(localized: "\(ratio.decimals(1))× System Settings’ fastest scroll speed.", comment: "Hint under the Native scroll speed slider; %@ is a multiple, like 2.5")
    }

    // Flywheel

    static func flyDistance(_ distance: Double) -> String {
        String(localized: "A slow tick moves the page \(Int(distance)) pt, so ten ticks move it \(Int(distance * 10)) pt.",
               comment: "Hint under the Flywheel slow-turn distance slider; the numbers are points on screen")
    }

    /// At a hard spin of 40 ticks a second, one tick's push.
    static func flyPower(_ config: GlideConfig) -> String {
        let push = SmoothScroller.flyTickDistance(rate: 40, distance: config.flyDistance, acceleration: config.flyAcceleration)
        if config.flyAcceleration < 0.01 {
            return String(localized: "Fast spins push no harder than slow ones: \(Int(push.rounded())) pt a tick.",
                          comment: "Hint under the Flywheel spin power slider when it's at zero; the number is points on screen")
        }
        return String(localized: "At 40 ticks a second, each tick pushes the page about \(Int((push / 10).rounded() * 10)) pt.",
                      comment: "Hint under the Flywheel spin power slider; the number is points on screen")
    }

    /// How much farther a very hard spin (70 ticks a second, the top of the chart) coasts
    /// than the same spin would with no extra reach. Each tick adds a push that fades
    /// with friction, so a steady spin settles at about rate × push; past 12,000 pt/s it
    /// is `reach` that decides how much of that is let through.
    static func flyReach(_ config: GlideConfig) -> String {
        if config.flyReach < 0.01 {
            return String(localized: "Reach is off: every spin stops speeding up at Kensington’s top speed.",
                          comment: "Hint under the Flywheel fast-spin reach slider when it's at zero")
        }
        let factor = hardSpinFactor(config)
        if factor < 1.15 {
            return String(localized: "At your spin power even a very hard spin goes no farther than with reach turned off.",
                          comment: "Hint under the Flywheel fast-spin reach slider when reach makes no difference")
        }
        return String(localized: "A very hard spin (70 ticks a second) coasts about \(factor.decimals(1))× farther than with reach turned off.",
                      comment: "Hint under the Flywheel fast-spin reach slider; %@ is a multiple, like 3.5")
    }

    static func hardSpinFactor(_ config: GlideConfig) -> Double {
        let rate = 70.0
        let steady = rate * SmoothScroller.flyTickDistance(rate: rate, distance: config.flyDistance, acceleration: config.flyAcceleration)
        let withReach = coastDistance(raw: min(steady, SmoothScroller.flyRawLimit(reach: config.flyReach)), reach: config.flyReach, glide: config.flyGlide)
        let without = coastDistance(raw: min(steady, SmoothScroller.flyRawLimit(reach: 0)), reach: 0, glide: config.flyGlide)
        return withReach / without
    }

    /// Points a Flywheel push of `raw` travels after you stop turning: the same
    /// per-frame step as `SmoothScroller.fly(dt:)`, at 120 frames a second.
    static func coastDistance(raw start: Double, reach: Double, glide: Double) -> Double {
        var raw = start
        var speed = SmoothScroller.flySpeed(raw: raw, reach: reach)
        var position = 0.0
        let dt = 1.0 / 120
        for _ in 0..<4000 {
            let tau = SmoothScroller.flyTau(glide: glide) * SmoothScroller.flyCoastStretch(speed: speed, reach: reach)
            let fade = exp(-dt / tau)
            let before = speed
            raw *= fade
            speed = SmoothScroller.flySpeed(raw: raw, reach: reach)
            if abs(before) <= SmoothScroller.flyKnee {
                position += before * tau * (1 - fade)
            } else {
                position += (before + speed) / 2 * dt
            }
            if abs(speed) < 15 {
                position += speed * tau
                break
            }
        }
        return position
    }

    static func flyGlide(_ glide: Double) -> String {
        String(localized: "Each push coasts for about \((SmoothScroller.flyTau(glide: glide) * 6).decimals(1)) s before it fades out.",
               comment: "Hint under the Flywheel glide slider; %@ is a number of seconds")
    }

    // Follow

    static func followDistance(_ distance: Double) -> String {
        String(localized: "A slow notch moves the page \(Int(distance)) pt.",
               comment: "Hint under the Follow distance-per-notch slider; the number is points on screen")
    }

    /// The page chases the ring like a critically damped spring: ~95% of the way in 4.74 / ω.
    static func followSoftness(_ config: GlideConfig) -> String {
        guard config.smoothScrolling else {
            return String(localized: "Smooth scrolling is off, so the page moves in plain steps.",
                          comment: "Hint under the Follow softness slider when smooth scrolling is off")
        }
        let ms = 4.74 * SmoothScroller.timeConstant(smoothness: config.scrollSmoothness) * 1000
        return String(localized: "The page catches up with the ring in about \(Int(ms.rounded())) ms.",
                      comment: "Hint under the Follow softness slider; the number is milliseconds")
    }

    static func followAcceleration(_ config: GlideConfig) -> String {
        if config.scrollAcceleration < 0.01 {
            return String(localized: "Every notch moves the page the same distance, however fast you spin.",
                          comment: "Hint under the Follow spin acceleration slider when it's off")
        }
        let gain = SmoothScroller.accelerationMultiplier(rate: 40, amount: config.scrollAcceleration)
        return String(localized: "A hard spin moves each notch \(gain.decimals(1))× as far: about \(Int((config.scrollDistance * gain).rounded())) pt.",
                      comment: "Hint under the Follow spin acceleration slider; %@ is a multiple, the second number is points on screen")
    }

    static func throwReach(_ config: GlideConfig) -> String {
        guard config.throwEnabled else {
            return String(localized: "Throw is off — the page stops the moment the ring stops.")
        }
        let v0 = min(ThrowCurve.typicalSpeed(config), SmoothScroller.throwMaxSpeed)
        let duration = SmoothScroller.throwDuration(speed: v0, throwAmount: config.throwAmount)
        let distance = SmoothScroller.throwDistance(speed: v0, throwAmount: config.throwAmount)
        return String(localized: "A typical flick coasts about \(Int(distance)) pt and lands after \(Int(duration * 1000)) ms.",
                      comment: "Hint under the Follow throw distance slider; points on screen, then milliseconds")
    }

    // The ball

    static func ballScroll(_ speed: Double) -> String {
        String(localized: "Rolling the ball one inch scrolls the page about \(Int(AppModel.countsPerInch * SmoothScroller.ballPointsPerCount * max(speed, 0))) pt.",
               comment: "Hint under the ball scroll speed slider; the number is points on screen")
    }
}

// MARK: - The tuning sections for the chosen mode

/// The tuning sections for the chosen scroll mode. Shared by the Scrolling tab
/// and app setups; only the scrolling fields of `config` are touched. The
/// Scrolling tab lays the sections out itself, with a chart after each one.
struct ScrollControls: View {
    @Binding var config: GlideConfig
    private static let defaults = GlideConfig()

    private struct Preset: Identifiable {
        let name: LocalizedStringKey, symbol: String
        let distance: Double, smooth: Double, accel: Double, throwOn: Bool, throwAmount: Double
        var id: String { symbol }

        func matches(_ c: GlideConfig) -> Bool {
            abs(c.scrollDistance - distance) < 0.01 && abs(c.scrollSmoothness - smooth) < 0.01
                && abs(c.scrollAcceleration - accel) < 0.01 && c.throwEnabled == throwOn
                && abs(c.throwAmount - throwAmount) < 0.01 && c.smoothScrolling
        }
    }
    private static let presets: [Preset] = [
        .init(name: LocalizedStringKey("Precise"), symbol: "scope", distance: 10, smooth: 0.25, accel: 0.25, throwOn: false, throwAmount: 0.3),
        .init(name: LocalizedStringKey("Control"), symbol: "hand.raised.fingers.spread", distance: 14, smooth: 0.4, accel: 0.5, throwOn: true, throwAmount: 0.4),
        .init(name: LocalizedStringKey("Fling"), symbol: "wind", distance: 18, smooth: 0.5, accel: 0.7, throwOn: true, throwAmount: 0.75),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            switch config.scrollMode {
            case .native:
                nativeSection
            case .flywheel:
                flywheelSection
            case .follow:
                presetsSection
                feelSection
                throwSection
            }
            if config.scrollMode != .native { directionSection }
        }
    }

    // MARK: Native

    var nativeSection: some View {
        SectionBlock(title: "macOS scrolling",
                     caption: "System Settings' scroll-speed slider goes up to 1.7. This only affects the Expert Mouse.") {
            TuningSlider(title: "Scroll speed", symbol: "gauge.with.dots.needle.50percent",
                         value: $config.nativeScrollSpeed, range: 0...5, step: 0.05,
                         format: { $0.decimals(2) }, lowLabel: "Slow", highLabel: "Fast",
                         hint: .verbatim(ScrollHints.nativeSpeed(config.nativeScrollSpeed)),
                         tint: Theme.ring, defaultValue: Self.defaults.nativeScrollSpeed)
        }
    }

    // MARK: Flywheel

    /// Whether the settings are the ones the Kensington feel button sets.
    private var hasKensingtonFeel: Bool {
        abs(config.flyDistance - 4) < 0.001 && abs(config.flyAcceleration - 0.5) < 0.001
            && abs(config.flyGlide - 0.35) < 0.001 && config.smoothScrolling
    }

    var flywheelSection: some View {
        SectionBlock(title: "Flywheel") {
            TuningSlider(title: "Slow-turn distance", symbol: "arrow.up.and.down",
                         value: $config.flyDistance, range: 1...20, step: 1,
                         format: { String(localized: "\(Int($0)) pt", comment: "Points: a distance on screen") },
                         lowLabel: "Precise", highLabel: "Far",
                         hint: .verbatim(ScrollHints.flyDistance(config.flyDistance)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyDistance)
            TuningSlider(title: "Spin power", symbol: "tornado",
                         value: $config.flyAcceleration, range: 0...1.5,
                         format: { $0.wholePercent }, lowLabel: "Gentle", highLabel: "Wild",
                         hint: .verbatim(ScrollHints.flyPower(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyAcceleration)
            TuningSlider(title: "Fast-spin reach", symbol: "bolt.horizontal",
                         value: $config.flyReach, range: 0...1,
                         format: { $0.wholePercent }, lowLabel: "Short", highLabel: "Far",
                         hint: .verbatim(ScrollHints.flyReach(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyReach)
            TuningSlider(title: "Glide", symbol: "wind",
                         value: $config.flyGlide, range: 0...1,
                         format: { String(localized: "\(Int(SmoothScroller.flyTau(glide: $0) * 1000)) ms", comment: "Milliseconds") },
                         lowLabel: "Grippy", highLabel: "Slippery",
                         hint: .verbatim(ScrollHints.flyGlide(config.flyGlide)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyGlide)
            ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                      symbol: "water.waves", isOn: $config.smoothScrolling)
            SettingRow(title: "Kensington feel",
                       hint: "Sets distance, power and glide to what Kensington’s own driver measured.",
                       symbol: "arrow.counterclockwise") {
                if hasKensingtonFeel {
                    Label("Applied", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Button("Apply") {
                        withAnimation(Theme.Motion.spring) {
                            config.flyDistance = 4; config.flyAcceleration = 0.5; config.flyGlide = 0.35
                            config.smoothScrolling = true
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Follow

    var presetsSection: some View {
        PlainSection(title: "Presets",
                     caption: "Control is the recommended starting point: the page follows the ring and stops when you stop.") {
            ChoiceStrip(
                choices: Self.presets.map { .init(value: $0.symbol, title: $0.name, symbol: $0.symbol) },
                isSelected: { symbol in Self.presets.first { $0.symbol == symbol }?.matches(config) ?? false },
                tint: Theme.ring
            ) { symbol in
                guard let p = Self.presets.first(where: { $0.symbol == symbol }) else { return }
                config.scrollDistance = p.distance
                config.scrollSmoothness = p.smooth
                config.scrollAcceleration = p.accel
                config.throwEnabled = p.throwOn
                config.throwAmount = p.throwAmount
                config.smoothScrolling = true
            }
        }
    }

    var feelSection: some View {
        SectionBlock(title: "Feel") {
            ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                      symbol: "water.waves", isOn: $config.smoothScrolling)
            TuningSlider(title: "Distance per notch", symbol: "arrow.up.and.down",
                         value: $config.scrollDistance, range: 1...40, step: 1,
                         format: { String(localized: "\(Int($0)) pt", comment: "Points: a distance on screen") },
                         lowLabel: "Fine", highLabel: "Far",
                         hint: .verbatim(ScrollHints.followDistance(config.scrollDistance)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollDistance)
            TuningSlider(title: "Follow", symbol: "hand.point.up.left",
                         value: $config.scrollSmoothness, range: 0...1,
                         format: { String(localized: "\(Int(SmoothScroller.timeConstant(smoothness: $0) * 1000)) ms", comment: "Milliseconds") },
                         lowLabel: "Locked to ring", highLabel: "Softer",
                         hint: .verbatim(ScrollHints.followSoftness(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollSmoothness)
                .disabled(!config.smoothScrolling)
            TuningSlider(title: "Spin acceleration", symbol: "tornado",
                         value: $config.scrollAcceleration, range: 0...1,
                         format: { $0 < 0.01 ? String(localized: "Off", comment: "Slider value: spin acceleration is off") : $0.wholePercent },
                         lowLabel: "Constant", highLabel: "Spin to fly",
                         hint: .verbatim(ScrollHints.followAcceleration(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollAcceleration)
        }
    }

    var throwSection: some View {
        SectionBlock(title: "Throw") {
            ToggleRow(title: "Throw to coast", subtitle: "Spin fast and let go — the page glides and lands",
                      symbol: "paperplane.fill", isOn: $config.throwEnabled)
            TuningSlider(title: "Throw distance", symbol: "ruler",
                         value: $config.throwAmount, range: 0...1,
                         format: { ScrollControls.seconds(SmoothScroller.throwDuration(speed: ThrowCurve.typicalSpeed(config), throwAmount: $0)) },
                         lowLabel: "Short", highLabel: "Long",
                         hint: .verbatim(ScrollHints.throwReach(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.throwAmount)
                .disabled(!config.throwEnabled)
        }
    }

    /// "1.5 s"
    static func seconds(_ s: Double) -> String {
        String(localized: "\(s.decimals(1)) s", comment: "Seconds, e.g. “1.5 s”")
    }

    // MARK: Every mode but Native

    var directionSection: some View {
        SectionBlock(title: "Direction") {
            ToggleRow(title: "Flip direction", subtitle: "Only if it scrolls the wrong way with your scroll reverser",
                      symbol: "arrow.up.arrow.down", isOn: $config.reverseScroll)
            ToggleRow(title: "Shift scrolls sideways", subtitle: "Hold ⇧ while spinning the ring",
                      symbol: "shift", isOn: $config.shiftScrollsHorizontally)
        }
    }
}

// MARK: - The mode choice

/// Native, Flywheel or Follow as one clear choice, with a line about the chosen one.
struct ModePicker: View {
    @Binding var mode: ScrollMode

    private static func symbol(_ m: ScrollMode) -> String {
        switch m {
        case .native: "applelogo"
        case .flywheel: "fanblades"
        case .follow: "hand.point.up.left"
        }
    }

    private static func about(_ m: ScrollMode) -> String {
        switch m {
        case .native: String(localized: "Glideball steps aside and macOS scrolls the ring itself. Only the speed is adjustable.")
        case .flywheel: String(localized: "Every tick pushes the page and friction slows it down: gentle turns barely coast, hard spins fly.")
        case .follow: String(localized: "The page follows the ring exactly and stops when you stop. A hard flick can still throw it.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChoiceStrip(
                choices: ScrollMode.allCases.map { .init(value: $0, title: .verbatim($0.title), symbol: Self.symbol($0)) },
                isSelected: { $0 == mode },
                tint: Theme.ring
            ) { mode = $0 }
            Text(Self.about(mode))
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }
}

// MARK: - Charts

/// Distance one tick adds at each spin speed, in Flywheel mode: no chrome, one
/// trace in the ring's pink, hairline guides, plain-word axes and a dot for where the ring is now.
struct FlywheelCurve: View {
    let config: GlideConfig
    let liveRate: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct P: Identifiable { let id: Int; let rate: Double; let pt: Double }

    var body: some View {
        let pts = stride(from: 0.0, through: 70, by: 1).enumerated().map {
            P(id: $0, rate: $1, pt: SmoothScroller.flyTickDistance(rate: $1, distance: config.flyDistance, acceleration: config.flyAcceleration))
        }
        let live = min(liveRate, 70)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Push per tick")
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Spin", p.rate), y: .value("pt", p.pt))
                        .foregroundStyle(LinearGradient(colors: [Theme.ring.opacity(0.16), Theme.ring.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Spin", p.rate), y: .value("pt", p.pt))
                        .foregroundStyle(Theme.ring)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if liveRate > 0.2 {
                    PointMark(x: .value("Spin", live),
                              y: .value("pt", SmoothScroller.flyTickDistance(rate: live, distance: config.flyDistance, acceleration: config.flyAcceleration)))
                        .symbol { LiveDot(color: Theme.ring) }
                }
            }
            .chartXScale(domain: 0...70)
            .chartXAxisLabel(position: .bottom, alignment: .leading) {
                Text("Ring ticks per second").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
            }
            .chartYAxisLabel(position: .top, alignment: .leading) {
                Text("Points per tick").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
            }
            .chartXAxis { ChartScale.marks(values: [0, 20, 40, 60]) }
            .chartYAxis { ChartScale.marks(desiredCount: 4) }
            .frame(height: 190)
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: config.flyAcceleration)
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: config.flyDistance)

            Text("Turn the ring the other way to stop it.")
                .font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
        }
    }
}

/// What a typical flick does after you let go: the same math the engine uses
/// (macOS's own deceleration shape: it lands at a definite moment).
struct ThrowCurve: View {
    let config: GlideConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct P: Identifiable { let id: Int; let ms: Double; let speed: Double }

    /// Release speed of a typical Expert Mouse flick (45 ticks/s).
    static func typicalSpeed(_ config: GlideConfig) -> Double {
        let rate = 45.0
        return config.scrollDistance * rate * SmoothScroller.accelerationMultiplier(rate: rate, amount: config.scrollAcceleration)
    }

    var body: some View {
        let v0 = min(Self.typicalSpeed(config), SmoothScroller.throwMaxSpeed)
        let duration = SmoothScroller.throwDuration(speed: v0, throwAmount: config.throwAmount)
        let pts = stride(from: 0.0, through: 1600, by: 10).enumerated().map { i, ms -> P in
            let t = ms / 1000
            let v = config.throwEnabled && t < duration ? v0 * pow(1 - t / duration, 3) : 0
            return P(id: i, ms: ms, speed: v)
        }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "After a flick")
            Chart(pts) { p in
                AreaMark(x: .value("ms", p.ms), y: .value("Speed", p.speed))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.ring.opacity(0.16), Theme.ring.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("ms", p.ms), y: .value("Speed", p.speed))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.ring)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartXScale(domain: 0...1600)
            .chartYScale(domain: 0...max(v0, 1))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [0, 400, 800, 1200, 1600]) { v in
                    ChartGrid.line
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0) ms").font(Theme.Font.hint).foregroundStyle(ChartGrid.text) }
                }
            }
            .frame(height: 100)
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: config.throwAmount)

            if config.throwEnabled {
                Text("Slow down before letting go and it doesn't coast at all. Turn the ring back to catch it.")
                    .font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Distance multiplier vs how fast the ring spins, with a live dot.
struct SpinCurve: View {
    let config: GlideConfig
    let liveRate: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct P: Identifiable { let id: Int; let rate: Double; let mult: Double }

    var body: some View {
        let pts = stride(from: 0.0, through: 70.0, by: 0.5).enumerated().map {
            P(id: $0, rate: $1, mult: SmoothScroller.accelerationMultiplier(rate: $1, amount: config.scrollAcceleration))
        }
        let live = min(liveRate, 70)
        let yMax = max(pts.last?.mult ?? 2, 2) * 1.05

        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Spin acceleration")
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Spin", p.rate), y: .value("×", p.mult))
                        .foregroundStyle(LinearGradient(colors: [Theme.ring.opacity(0.16), Theme.ring.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Spin", p.rate), y: .value("×", p.mult))
                        .foregroundStyle(Theme.ring)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if liveRate > 0.2 {
                    PointMark(x: .value("Spin", live),
                              y: .value("×", SmoothScroller.accelerationMultiplier(rate: live, amount: config.scrollAcceleration)))
                        .symbol { LiveDot(color: Theme.ring) }
                }
            }
            .chartXScale(domain: 0...70)
            .chartYScale(domain: 0...yMax)
            .chartXAxisLabel(position: .bottom, alignment: .leading) {
                Text("Ring ticks per second").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
            }
            .chartYAxisLabel(position: .top, alignment: .leading) {
                Text("Distance ×").font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
            }
            .chartXAxis { ChartScale.marks(values: [0, 20, 40, 60]) }
            .chartYAxis { ChartScale.marks(desiredCount: 3) }
            .frame(height: 140)
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: config.scrollAcceleration)
        }
    }
}

/// Axis marks for the charts: a hairline guide and a quiet number.
enum ChartScale {
    @AxisContentBuilder
    static func marks(values: [Double]) -> some AxisContent {
        AxisMarks(values: values) { value in
            ChartGrid.line
            label(value)
        }
    }

    @AxisContentBuilder
    static func marks(desiredCount: Int) -> some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: desiredCount)) { value in
            ChartGrid.line
            label(value)
        }
    }

    @AxisMarkBuilder
    private static func label(_ value: AxisValue) -> some AxisMark {
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(v.formatted()).font(Theme.Font.hint).foregroundStyle(ChartGrid.text)
            }
        }
    }
}

// MARK: - Try it

/// A list to scroll with the ring, to feel the settings: plain rows with hairlines
/// between them (they move when the page does, so you can judge smoothness by eye).
struct TryItArea: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "Try it here", caption: "Put the pointer over the list and spin the ring.")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(1...300, id: \.self) { i in
                        if i > 1 { Hairline() }
                        HStack(spacing: Theme.Space.symbolGap) {
                            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                            Text("Row \(i)").font(Theme.Font.body)
                            Spacer()
                            Capsule().fill(Theme.hairline).frame(width: CGFloat(30 + (i * 37) % 120), height: 5)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, Theme.Space.rowHorizontal)
                    }
                }
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
            .groupBackground()
        }
    }
}
