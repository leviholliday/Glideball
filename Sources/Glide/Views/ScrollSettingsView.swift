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
        // Wide: the mode and its controls on the left, "Try it here" and the mode's charts on the right.
        PageColumns {
            PlainSection(title: "Scroll mode",
                         caption: TryHint.due ? "⌥-click a mode to try it for 10 seconds first." : nil) {
                ModePicker(mode: $model.config.scrollMode)
            }
            .findable(.scrollMode)

            // The mode's own controls glide in under the cards (a rise and a fade) as the old ones fade.
            Group {
                switch model.config.scrollMode {
                case .native:
                    controls.nativeSection
                case .flywheel:
                    controls.flywheelSection
                case .follow:
                    controls.presetsSection
                    controls.feelSection
                }
            }
            .transition(reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))

            // One "Try it here" for every mode: it stays put while the mode changes.
            TryItArea(feed: model.live)
                .findable(.tryItHere)
                .pageColumn(.trailing)

            Group {
                switch model.config.scrollMode {
                case .native:
                    EmptyView()
                case .flywheel:
                    LiveTimeline(feed: model.live, maxFPS: 20) { feed, _ in
                        FlywheelCurve(config: model.config, liveRate: feed.notchRate)
                    }
                case .follow:
                    LiveTimeline(feed: model.live, maxFPS: 20) { feed, _ in
                        SpinCurve(config: model.config, liveRate: feed.notchRate)
                    }
                    controls.throwSection
                    ThrowCurve(config: model.config)
                }
            }
            .transition(reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            .pageColumn(.trailing)

            if model.config.scrollMode != .native {
                controls.directionSection
                    .pageColumn(.trailing)
            }

            SectionBlock(title: "Scroll with the ball",
                         caption: "Set a button to “Scroll with ball” in Buttons. While you hold it, rolling the ball scrolls in any direction and the cursor stays put. Let go mid-roll and the page glides briefly.") {
                TuningSlider(title: "Ball scroll speed", symbol: "gauge.with.dots.needle.50percent",
                             value: $model.config.ballScrollSpeed, range: 0.25...4, step: 0.05,
                             format: { "\($0.twoDigits)×" }, lowLabel: "Fine", highLabel: "Fast",
                             hint: .verbatim(ScrollHints.ballScroll(model.config.ballScrollSpeed)),
                             tint: Theme.ball, defaultValue: Self.defaults.ballScrollSpeed)
                    .findable(.ballScrollSpeed)
            }
            .pageColumn(.trailing)
        }
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.spring), value: model.config.scrollMode)
    }

    static let findables: [Findable] = [
        .scrollMode, .nativeScrollSpeed, .flyDistance, .flyPower, .flyReach, .flyGlide, .smoothScrolling, .kensingtonFeel,
        .followPresets, .followDistance, .followSoftness, .followAcceleration, .throwToCoast, .throwDistance,
        .flipDirection, .shiftSideways, .tryItHere, .ballScrollSpeed,
    ]
}

// What search finds on Scrolling (each next to its row).
extension Findable {
    private static func scroll(_ id: String, _ title: String, _ detail: String, _ keywords: String, _ symbol: String,
                               _ modes: [ScrollMode] = [], part: Metric = .scroll, boost: Int = 0) -> Findable {
        Findable(id: id, title: title, detail: detail, keywords: keywords, symbol: symbol, place: .tab(.scroll),
                 part: part, modes: modes, boost: boost)
    }

    static let scrollMode = scroll("scroll-mode", String(localized: "Scroll mode"),
        String(localized: "Native, Flywheel or Follow: how the page moves when you turn the ring.", comment: "Search palette: Scroll mode"),
        String(localized: "scrolling, ring, wheel, flywheel, follow, native, inertia, momentum", comment: "Search words for Scroll mode (comma-separated)"),
        "arrow.up.and.down.circle", boost: 8)
    static let nativeScrollSpeed = scroll("native-scroll-speed", String(localized: "Scroll speed"),
        String(localized: "How far macOS scrolls for each click of the ring, in Native mode.", comment: "Search palette: Native scroll speed"),
        String(localized: "scroll speed, wheel speed, native, lines", comment: "Search words for Native scroll speed (comma-separated)"),
        "gauge.with.dots.needle.50percent", [.native], boost: 3)
    static let flyDistance = scroll("fly-distance", String(localized: "Slow-turn distance"),
        String(localized: "How far one slow tick moves the page, in Flywheel mode.", comment: "Search palette: Flywheel slow-turn distance"),
        String(localized: "distance, tick, step, scroll speed, flywheel", comment: "Search words for slow-turn distance (comma-separated)"),
        "arrow.up.and.down", [.flywheel])
    static let flyPower = scroll("fly-power", String(localized: "Spin power"),
        String(localized: "How much harder fast spins push the page, in Flywheel mode.", comment: "Search palette: Flywheel spin power"),
        String(localized: "acceleration, power, fast spin, flywheel", comment: "Search words for spin power (comma-separated)"),
        "tornado", [.flywheel])
    static let flyReach = scroll("fly-reach", String(localized: "Fast-spin reach"),
        String(localized: "How far a very hard spin can carry the page, in Flywheel mode.", comment: "Search palette: Flywheel fast-spin reach"),
        String(localized: "reach, top speed, limit, flywheel", comment: "Search words for fast-spin reach (comma-separated)"),
        "bolt.horizontal", [.flywheel])
    static let flyGlide = scroll("fly-glide", String(localized: "Glide"),
        String(localized: "How long the page coasts after a push, in Flywheel mode.", comment: "Search palette: Flywheel glide"),
        String(localized: "friction, coast, momentum, inertia, slippery, flywheel", comment: "Search words for glide (comma-separated)"),
        "wind", [.flywheel])
    static let smoothScrolling = scroll("smooth-scrolling", String(localized: "Smooth scrolling"),
        String(localized: "Smooth movement, or plain steps like a basic mouse.", comment: "Search palette: Smooth scrolling"),
        String(localized: "smooth, steps, jumpy, lines", comment: "Search words for smooth scrolling (comma-separated)"),
        "water.waves", [.flywheel, .follow])
    static let kensingtonFeel = scroll("kensington-feel", String(localized: "Kensington feel"),
        String(localized: "Flywheel set to what Kensington’s own driver measured.", comment: "Search palette: Kensington feel"),
        String(localized: "kensingtonworks, default, reset, original, driver", comment: "Search words for Kensington feel (comma-separated)"),
        "arrow.counterclockwise", [.flywheel])
    static let followPresets = scroll("follow-presets", String(localized: "Follow presets"),
        String(localized: "Precise, Control or Fling, in Follow mode.", comment: "Search palette: Follow presets"),
        String(localized: "preset, precise, control, fling, follow", comment: "Search words for Follow presets (comma-separated)"),
        "square.grid.2x2", [.follow])
    static let followDistance = scroll("follow-distance", String(localized: "Distance per notch"),
        String(localized: "How far one slow notch moves the page, in Follow mode.", comment: "Search palette: Follow distance per notch"),
        String(localized: "distance, notch, step, scroll speed, follow", comment: "Search words for distance per notch (comma-separated)"),
        "arrow.up.and.down", [.follow])
    static let followSoftness = scroll("follow-softness", String(localized: "Follow"),
        String(localized: "How closely the page sticks to the ring, in Follow mode.", comment: "Search palette: Follow softness"),
        String(localized: "softness, smoothing, lag, latency, follow", comment: "Search words for the Follow slider (comma-separated)"),
        "hand.point.up.left", [.follow])
    static let followAcceleration = scroll("follow-acceleration", String(localized: "Spin acceleration"),
        String(localized: "How much farther each notch goes when you spin fast, in Follow mode.", comment: "Search palette: Follow spin acceleration"),
        String(localized: "acceleration, fast spin, follow", comment: "Search words for spin acceleration (comma-separated)"),
        "tornado", [.follow])
    static let throwToCoast = scroll("throw-to-coast", String(localized: "Throw to coast"),
        String(localized: "Spin fast and let go, and the page glides on, in Follow mode.", comment: "Search palette: Throw to coast"),
        String(localized: "throw, fling, momentum, inertia, coast", comment: "Search words for throw to coast (comma-separated)"),
        "paperplane.fill", [.follow])
    static let throwDistance = scroll("throw-distance", String(localized: "Throw distance"),
        String(localized: "How far a flick carries the page, in Follow mode.", comment: "Search palette: Throw distance"),
        String(localized: "throw, fling, coast, distance", comment: "Search words for throw distance (comma-separated)"),
        "ruler", [.follow])
    static let flipDirection = scroll("flip-direction", String(localized: "Flip direction"),
        String(localized: "Scroll the other way, if a scroll reverser gets it wrong.", comment: "Search palette: Flip direction"),
        String(localized: "reverse, invert, natural scrolling, direction, backwards", comment: "Search words for flip direction (comma-separated)"),
        "arrow.up.arrow.down", [.flywheel, .follow])
    static let shiftSideways = scroll("shift-sideways", String(localized: "Shift scrolls sideways"),
        String(localized: "Hold ⇧ while you spin the ring to scroll left and right.", comment: "Search palette: Shift scrolls sideways"),
        String(localized: "horizontal, sideways, shift, left, right", comment: "Search words for shift scrolls sideways (comma-separated)"),
        "shift", [.flywheel, .follow])
    static let tryItHere = scroll("try-it-here", String(localized: "Try it here"),
        String(localized: "A list to scroll with the ring, to feel your settings.", comment: "Search palette: Try it here"),
        String(localized: "test, practice, sandbox, feel", comment: "Search words for Try it here (comma-separated)"),
        "scroll")
    static let ballScrollSpeed = scroll("ball-scroll-speed", String(localized: "Ball scroll speed"),
        String(localized: "How fast rolling the ball scrolls while Scroll with ball is held.", comment: "Search palette: Ball scroll speed"),
        String(localized: "scroll with ball, ball scroll, speed", comment: "Search words for ball scroll speed (comma-separated)"),
        "gauge.with.dots.needle.50percent", part: .ball)
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
            return String(localized: "Throw is off. The page stops the moment the ring stops.")
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
                .findable(.nativeScrollSpeed)
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
                .findable(.flyDistance)
            TuningSlider(title: "Spin power", symbol: "tornado",
                         value: $config.flyAcceleration, range: 0...1.5,
                         format: { $0.wholePercent }, lowLabel: "Gentle", highLabel: "Wild",
                         hint: .verbatim(ScrollHints.flyPower(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyAcceleration)
                .findable(.flyPower)
            TuningSlider(title: "Fast-spin reach", symbol: "bolt.horizontal",
                         value: $config.flyReach, range: 0...1,
                         format: { $0.wholePercent }, lowLabel: "Short", highLabel: "Far",
                         hint: .verbatim(ScrollHints.flyReach(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyReach)
                .findable(.flyReach)
            TuningSlider(title: "Glide", symbol: "wind",
                         value: $config.flyGlide, range: 0...1,
                         format: { String(localized: "\(Int(SmoothScroller.flyTau(glide: $0) * 1000)) ms", comment: "Milliseconds") },
                         lowLabel: "Grippy", highLabel: "Slippery",
                         hint: .verbatim(ScrollHints.flyGlide(config.flyGlide)),
                         tint: Theme.ring, defaultValue: Self.defaults.flyGlide)
                .findable(.flyGlide)
            ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                      symbol: "water.waves", isOn: $config.smoothScrolling)
                .findable(.smoothScrolling)
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
            .findable(.kensingtonFeel)
        }
    }

    // MARK: Follow

    var presetsSection: some View {
        PlainSection(title: "Presets",
                     caption: "Control is the recommended starting point: the page follows the ring and stops when you stop.") {
            ChoiceStrip(
                choices: Self.presets.map { .init(value: $0.symbol, title: $0.name, symbol: $0.symbol, demo: .follow(reach: $0.accel, coast: $0.throwOn)) },
                isSelected: { symbol in Self.presets.first { $0.symbol == symbol }?.matches(config) ?? false },
                tint: Theme.ring,
                trial: followTrial
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
        .findable(.followPresets)
    }

    /// Try a Follow preset for 10 s: everything a preset sets goes back.
    private var followTrial: ChoiceStrip<String>.Trial {
        let binding = $config
        return .init(id: "follow-presets", name: { symbol in
            switch symbol {
            case "scope": String(localized: "Precise")
            case "hand.raised.fingers.spread": String(localized: "Control")
            case "wind": String(localized: "Fling")
            default: ""
            }
        }, snapshot: {
            let c = binding.wrappedValue
            let was = Self.presets.first { $0.matches(c) }.map { p -> String in
                switch p.symbol {
                case "scope": String(localized: "Precise")
                case "hand.raised.fingers.spread": String(localized: "Control")
                default: String(localized: "Fling")
                }
            } ?? String(localized: "your settings", comment: "Try for 10 s: goes back to “your settings” (when they aren't a preset)")
            return (was, {
                binding.wrappedValue.scrollDistance = c.scrollDistance
                binding.wrappedValue.scrollSmoothness = c.scrollSmoothness
                binding.wrappedValue.scrollAcceleration = c.scrollAcceleration
                binding.wrappedValue.throwEnabled = c.throwEnabled
                binding.wrappedValue.throwAmount = c.throwAmount
                binding.wrappedValue.smoothScrolling = c.smoothScrolling
            })
        })
    }

    var feelSection: some View {
        SectionBlock(title: "Feel") {
            ToggleRow(title: "Smooth scrolling", subtitle: "Off = plain steps, exactly like a basic mouse",
                      symbol: "water.waves", isOn: $config.smoothScrolling)
                .findable(.smoothScrolling)
            TuningSlider(title: "Distance per notch", symbol: "arrow.up.and.down",
                         value: $config.scrollDistance, range: 1...40, step: 1,
                         format: { String(localized: "\(Int($0)) pt", comment: "Points: a distance on screen") },
                         lowLabel: "Fine", highLabel: "Far",
                         hint: .verbatim(ScrollHints.followDistance(config.scrollDistance)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollDistance)
                .findable(.followDistance)
            TuningSlider(title: "Follow", symbol: "hand.point.up.left",
                         value: $config.scrollSmoothness, range: 0...1,
                         format: { String(localized: "\(Int(SmoothScroller.timeConstant(smoothness: $0) * 1000)) ms", comment: "Milliseconds") },
                         lowLabel: "Locked to ring", highLabel: "Softer",
                         hint: .verbatim(ScrollHints.followSoftness(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollSmoothness)
                .disabled(!config.smoothScrolling)
                .findable(.followSoftness)
            TuningSlider(title: "Spin acceleration", symbol: "tornado",
                         value: $config.scrollAcceleration, range: 0...1,
                         format: { $0 < 0.01 ? String(localized: "Off", comment: "Slider value: spin acceleration is off") : $0.wholePercent },
                         lowLabel: "Constant", highLabel: "Spin to fly",
                         hint: .verbatim(ScrollHints.followAcceleration(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.scrollAcceleration)
                .findable(.followAcceleration)
        }
    }

    var throwSection: some View {
        SectionBlock(title: "Throw") {
            ToggleRow(title: "Throw to coast", subtitle: "Spin fast and let go. The page glides and lands",
                      symbol: "paperplane.fill", isOn: $config.throwEnabled)
                .findable(.throwToCoast)
            TuningSlider(title: "Throw distance", symbol: "ruler",
                         value: $config.throwAmount, range: 0...1,
                         format: { ScrollControls.seconds(SmoothScroller.throwDuration(speed: ThrowCurve.typicalSpeed(config), throwAmount: $0)) },
                         lowLabel: "Short", highLabel: "Long",
                         hint: .verbatim(ScrollHints.throwReach(config)),
                         tint: Theme.ring, defaultValue: Self.defaults.throwAmount)
                .disabled(!config.throwEnabled)
                .findable(.throwDistance)
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
                .findable(.flipDirection)
            ToggleRow(title: "Shift scrolls sideways", subtitle: "Hold ⇧ while spinning the ring",
                      symbol: "shift", isOn: $config.shiftScrollsHorizontally)
                .findable(.shiftSideways)
        }
    }
}

// MARK: - The mode choice

/// Native, Flywheel or Follow as one clear choice, with a line about the chosen one.
struct ModePicker: View {
    @Binding var mode: ScrollMode

    static func symbol(_ m: ScrollMode) -> String {
        switch m {
        case .native: "applelogo"
        case .flywheel: "fanblades"
        case .follow: "hand.point.up.left"
        }
    }

    static func about(_ m: ScrollMode) -> String {
        switch m {
        case .native: String(localized: "Glideball steps aside and macOS scrolls the ring itself. Only the speed is adjustable.")
        case .flywheel: String(localized: "Every tick pushes the page and friction slows it down: gentle turns barely coast, hard spins fly.")
        case .follow: String(localized: "The page follows the ring exactly and stops when you stop. A hard flick can still throw it.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let binding = $mode
            ChoiceStrip(
                choices: ScrollMode.allCases.map { .init(value: $0, title: .verbatim($0.title), symbol: Self.symbol($0), demo: .scroll($0)) },
                isSelected: { $0 == mode },
                tint: Theme.ring,
                trial: .init(id: "scroll-mode", name: { $0.title }, snapshot: {
                    let old = binding.wrappedValue
                    return (old.title, { binding.wrappedValue = old })
                })
            ) { mode = $0 }
            // The line about the mode cross-fades with a small rise.
            ZStack(alignment: .topLeading) {
                Text(Self.about(mode))
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(mode)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The live feed: the lane lights pink and draws the ring's speed while you spin.
    var feed: LiveFeed? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "Try it here", caption: "Click the list, then spin the ring.")
            lane
        }
    }

    private var lane: some View {
        list
            .overlay(alignment: .trailing) {
                if let feed {
                    // The ring's speed, drawn down the lane's right edge as you spin (newest at the bottom).
                    LiveTimeline(feed: feed, maxFPS: 30) { feed, _ in
                        LaneTrace(values: feed.notchHistory)
                    }
                    .frame(width: 46)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if let feed {
                    // The lane's edge lights up pink with the ring, and fades after.
                    LiveLight(feed: feed) { l in
                        RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                            .strokeBorder(Theme.ring, lineWidth: 1.5)
                            .shadow(color: Theme.ring, radius: 8)
                            .opacity(min(1, l.ring * 1.2))
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    private var list: some View {
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
            // Scrolling down the page never gets caught in here: it takes the ring only after a click or a rest.
            .scrollCaptureGuard()
    }
}

/// The ring's recent speed as a pink trace running down the lane's edge: the
/// oldest at the top, now at the bottom, fading toward the past.
private struct LaneTrace: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            let recent = Array(values.suffix(max(values.count / 3, 2)))
            guard recent.count > 1, recent.contains(where: { $0 > 0 }) else { return }
            let top = max(20, recent.max() ?? 0)
            var line = Path()
            for (i, v) in recent.enumerated() {
                let y = size.height * CGFloat(i) / CGFloat(recent.count - 1)
                let x = size.width - 6 - (size.width - 12) * CGFloat(min(v / top, 1))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            let fade = GraphicsContext.Shading.linearGradient(Gradient(colors: [Theme.ring.opacity(0), Theme.ring]),
                                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            ctx.opacity = 0.2
            ctx.stroke(line, with: fade, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            ctx.opacity = 0.45
            ctx.stroke(line, with: fade, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            ctx.opacity = 1
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [Theme.ring.opacity(0), .white]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
