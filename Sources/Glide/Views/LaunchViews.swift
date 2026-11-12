import SwiftUI

// What plays over the window at launch (`LaunchExperience` decides which):
// the first-launch intro, one of two short launch animations, or the quick
// fade. All of them are the same picture: the trackball (`TrackballArt`, the
// sidebar's own drawing) on a near-black stage, and the wordmark under it.
// Everything is drawn from the clock in a TimelineView that only exists while
// it plays, so nothing is left running afterwards.

// MARK: - Overlay

/// Over the whole window while the launch plays. A click (or esc) skips.
struct LaunchOverlay: View {
    private let launch = LaunchExperience.shared

    var body: some View {
        if let show = launch.show {
            TimelineView(.animation(minimumInterval: 1.0 / 120, paused: launch.start == nil)) { tl in
                let t = launch.start.map { max(0, tl.date.timeIntervalSince($0)) } ?? 0
                let reveal = launch.revealStart.map { LaunchMath.clamp(tl.date.timeIntervalSince($0) / launch.revealDuration) } ?? 0
                scene(show, t: t)
                    .modifier(RevealOut(progress: reveal, calm: launch.reduceMotion || show == .fade,
                                        from: show == .intro ? IntroScene.ballAnchor : SplashScene.ballAnchor))
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { launch.skip() }
            .allowsHitTesting(launch.revealStart == nil)
            // Started once the window's first frame is up, so nothing at
            // launch can eat into the animation.
            .onAppear { DispatchQueue.main.async { launch.began() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Glideball is starting")
            .accessibilityHint("Click or press Escape to skip")
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder private func scene(_ show: LaunchExperience.Show, t: Double) -> some View {
        switch show {
        case .intro: IntroScene(t: t, calm: launch.reduceMotion)
        case .splash(let variant): SplashScene(variant: variant, t: t, calm: launch.reduceMotion)
        case .fade: SplashScene(variant: .ringSpin, t: t, calm: true)
        }
    }
}

/// The hand-off. The stage opens from the trackball outward, a soft ring of
/// the orb's light running out across the window at its edge, and the window
/// shows through as it passes. Reduce Motion (and the quick fade): just a fade.
struct RevealOut: ViewModifier {   // internal: --render-ui draws it part-way
    let progress: Double
    let calm: Bool
    /// Where the trackball is (the light opens from there).
    var from = UnitPoint(x: 0.5, y: 0.43)

    func body(content: Content) -> some View {
        if calm || progress <= 0 {
            let p = LaunchMath.easeOut(progress)
            content.opacity(1 - p)
        } else {
            GeometryReader { g in
                let p = LaunchMath.easeInOut(progress)
                let w = Double(g.size.width), h = Double(g.size.height)
                let cx = w * from.x, cy = h * from.y
                // Far enough to clear the farthest corner.
                let far = max(hypot(cx, cy), hypot(w - cx, cy), hypot(cx, h - cy), hypot(w - cx, h - cy)) + 200
                let r = far * p
                let soft = 220.0
                content
                    .scaleEffect(1 + 0.03 * p, anchor: from)
                    .mask {
                        RadialGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: max(0, r - soft) / far),
                                               .init(color: .black, location: max(r, 1) / far),
                                               .init(color: .black, location: 1)],
                                       center: from, startRadius: 0, endRadius: far)
                    }
                    .overlay {
                        // The light at the opening's edge: the orb's colors blooming out over the window.
                        RadialGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: max(0, r - soft * 1.2) / far),
                                               .init(color: Theme.orbCyan.opacity(0.22), location: max(0, r - soft * 0.55) / far),
                                               .init(color: Theme.orbViolet.opacity(0.18), location: max(r, 1) / far),
                                               .init(color: Theme.orbMagenta.opacity(0.06), location: min(1, (r + 90) / far)),
                                               .init(color: .clear, location: min(1, (r + 200) / far))],
                                       center: from, startRadius: 0, endRadius: far)
                            .blendMode(.plusLighter)
                            .opacity(1 - LaunchMath.span(progress, 0.55, 1))
                            .allowsHitTesting(false)
                    }
                    .opacity(1 - LaunchMath.span(progress, 0.8, 1))
            }
        }
    }
}

// MARK: - Shared drawing

enum LaunchMath {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func span(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func easeOut(_ x: Double) -> Double { let c = clamp(x); return 1 - pow(1 - c, 3) }
    static func easeIn(_ x: Double) -> Double { let c = clamp(x); return c * c * c }
    static func easeInOut(_ x: Double) -> Double {
        let c = clamp(x)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
    /// 0 → 1 → 0 across a…b.
    static func bump(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let s = span(t, a, b)
        return s > 0 && s < 1 ? sin(.pi * s) : 0
    }
    /// How much of the way a spring still has to go `x` seconds after letting go
    /// (1 → 0, overshooting a little below 0 when `damping` < 1). `omega` is its stiffness.
    static func springLeft(_ x: Double, omega: Double, damping: Double) -> Double {
        guard x > 0 else { return 1 }
        let wd = omega * (1 - damping * damping).squareRoot()
        return exp(-damping * omega * x) * (cos(wd * x) + damping * omega / wd * sin(wd * x))
    }
    /// A word or a ball landing with weight: big, then a little under, then still (1 at rest).
    static func landing(_ x: Double, from: Double, tau: Double = 0.09, wobble: Double = 18) -> Double {
        guard x > 0 else { return from }
        return 1 + (from - 1) * exp(-x / tau) * cos(x * wobble)
    }
}

/// The near-black stage everything launches on: the window's own lit stage
/// (always the dark one), its aurora centered on the trackball and coming up
/// as the trackball arrives (`light`, 0…1), so the launch hands over to the
/// window without a change of world. `gather` pulls the light in tight round
/// the trackball (0…1); `bloom` throws it wide.
struct LaunchStage: View {
    var light = 1.0
    var gather = 0.0
    var bloom = 0.0
    var anchor = UnitPoint(x: 0.5, y: 0.42)

    var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.027, blue: 0.04)
            StaticAtmosphere(dark: true, anchor: anchor, strength: 1 + 0.35 * bloom)
                .environment(\.colorScheme, .dark)
                .opacity(light * (1 - 0.75 * gather))
            if gather > 0.01 {
                // The light drawn in: a tight, bright core round the trackball.
                GeometryReader { g in
                    Circle()
                        .fill(RadialGradient(colors: [Theme.orbCyan.opacity(0.5), Theme.orbBlue.opacity(0.35), .clear],
                                             center: .center, startRadius: 0, endRadius: 200 - 70 * gather))
                        .frame(width: 400, height: 400)
                        .position(x: g.size.width * anchor.x, y: g.size.height * anchor.y)
                        .opacity(gather * light)
                        .blendMode(.plusLighter)
                }
            }
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 260, endRadius: 760)
        }
    }
}

/// "Glideball", in SF Pro Rounded.
struct Wordmark: View {
    var size: CGFloat = 34

    var body: some View {
        Text(verbatim: "Glideball")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

/// The ring's ticks, thrown outward once from the ring at the intro's hit:
/// a circle of tick marks growing across the window and fading (`progress` 0…1).
private struct TickRipple: View {
    let progress: Double
    let from: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard progress > 0, progress < 1 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = Double(max(size.width, size.height)) * 0.75
            let r = Double(from) + (reach - Double(from)) * LaunchMath.easeOut(progress)
            let len = 9 * (1 - progress) + 3
            var ticks = Path()
            for i in 0..<120 {
                let a = Double(i) / 120 * 2 * .pi
                let l = i % 5 == 0 ? len * 1.6 : len
                ticks.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                ticks.addLine(to: CGPoint(x: c.x + cos(a) * (r + l), y: c.y + sin(a) * (r + l)))
            }
            let fade = pow(1 - progress, 1.6)
            ctx.stroke(ticks, with: .color(Theme.ring.opacity(0.75 * fade)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            ctx.stroke(ticks, with: .color(Theme.orbCyan.opacity(0.35 * fade)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - The first-launch intro

/// About six and a half seconds, timed to IntroMusic.m4a
/// (scripts/make-intro-music.py, whose hit is at 3.9 s):
///
/// - 0.5–2.3 the ball rolls in out of the dark, turning as it rolls, and
///   settles into its seat with a small overshoot;
/// - 1.9–3.9 the ring's ticks come in around it and the ring speeds up with
///   the bells, faster and pinker, its ticks streaking;
/// - 2.9–3.6 the room's light draws in tight round the trackball, and then for
///   a held beat (3.62–3.88) almost everything goes dark;
/// - 3.9, the hit: the light blooms out across the window, the rest of the
///   trackball arrives, a ring of ticks ripples outward once, and "Glideball"
///   lands under it with weight. At 6.4 the window takes over.
struct IntroScene: View {   // internal: drawn by --render-ui and --self-test too
    let t: Double
    let calm: Bool

    static let hit = 3.9
    static let markSide: CGFloat = 230
    /// Where the settled trackball is, for the hand-off's light.
    static let ballAnchor = UnitPoint(x: 0.5, y: 0.41)

    var body: some View {
        GeometryReader { g in
            let hit = Self.hit
            let lift = calm ? 1 : LaunchMath.easeOut(LaunchMath.span(t, hit, hit + 0.5))
            ZStack {
                LaunchStage(light: calm ? 1 : stageLight, gather: calm ? 0 : gather,
                            bloom: calm ? 0 : LaunchMath.bump(t, hit - 0.02, hit + 1.4))

                // The hit's flash: a quick swell of the orb's light at the trackball, breathing out.
                if !calm && t > hit - 0.05 {
                    RadialGradient(colors: [Color.white.opacity(0.55), Theme.orbCyan.opacity(0.35), Theme.orbViolet.opacity(0.12), .clear],
                                   center: .center, startRadius: 0, endRadius: 420 + 260 * LaunchMath.easeOut(LaunchMath.span(t, hit, hit + 0.8)))
                        .opacity(flash)
                        .blendMode(.plusLighter)
                        .offset(y: -58 * lift)
                        .allowsHitTesting(false)
                }

                if !calm {
                    TickRipple(progress: LaunchMath.span(t, hit + 0.02, hit + 1.15), from: Self.markSide * 0.38)
                        .offset(y: -58 * lift)
                }

                TrackballArt(pose: pose(width: g.size.width))
                    .frame(width: Self.markSide, height: Self.markSide)
                    .scaleEffect(1 - 0.12 * lift)
                    .offset(y: -58 * lift)

                VStack(spacing: 10) {
                    // Lands just as the trackball has lifted out of its way.
                    let x = t - hit - 0.18
                    let word = calm ? LaunchMath.span(t, 0.5, 1.0) : LaunchMath.span(x, 0, 0.09)
                    Wordmark(size: 54)
                        .scaleEffect(calm ? 1 : LaunchMath.landing(x, from: 1.24), anchor: .center)
                        .blur(radius: calm ? 0 : 6 * (1 - word))
                        .shadow(color: Theme.orbBlue.opacity(calm ? 0 : 0.6 * LaunchMath.bump(x, 0, 0.9)), radius: 18)
                        .opacity(word)
                        .offset(y: calm ? 0 : -8 * (1 - LaunchMath.span(x, 0, 0.12)))
                    let line = calm ? LaunchMath.span(t, 0.9, 1.4) : LaunchMath.easeOut(LaunchMath.span(t, 4.8, 5.4))
                    Text("For your Kensington trackball")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .opacity(line)
                        .offset(y: calm ? 0 : 6 * (1 - line))
                }
                .offset(y: 128)

                Text("Click to skip")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .opacity(LaunchMath.span(t, 1.2, 1.8) * (1 - 0.8 * held))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
    }

    /// The held beat before the hit (0…1): the room nearly dark.
    private var held: Double {
        LaunchMath.easeOut(LaunchMath.span(t, 3.6, 3.78)) * (1 - LaunchMath.span(t, Self.hit - 0.03, Self.hit + 0.04))
    }

    /// The light drawing in round the trackball before the hit, let go at the hit.
    private var gather: Double {
        LaunchMath.easeIn(LaunchMath.span(t, 2.9, 3.62)) * (1 - LaunchMath.easeOut(LaunchMath.span(t, Self.hit - 0.02, Self.hit + 0.5)))
    }

    private var stageLight: Double {
        let rise = 0.75 * LaunchMath.easeInOut(LaunchMath.span(t, 0.8, 2.6))
        let after = LaunchMath.span(t, Self.hit - 0.02, Self.hit + 0.08)
        return max(0.06, (rise * (1 - after) + after) * (1 - 0.92 * held))
    }

    private var flash: Double {
        let x = t - Self.hit
        guard x > -0.03 else { return 0 }
        return LaunchMath.span(x, -0.03, 0.04) * exp(-max(x, 0) / 0.3)
    }

    /// The ring's turn (degrees): faster and faster up to the hit, then coasting to rest.
    private func ringAngle(_ t: Double) -> Double {
        let a = 1.95, hit = Self.hit, total = 720.0
        if t <= hit { return total * pow(LaunchMath.span(t, a, hit), 3) }
        let vHit = 3 * total / (hit - a), tau = 0.32
        return total + vHit * tau * (1 - exp(-(t - hit) / tau))
    }

    /// The ball's offset from its seat (fraction of the trackball's side): in from off the
    /// left edge on a spring that settles with a small overshoot.
    private func ballX(_ t: Double, width: CGFloat) -> Double {
        let from = -(Double(width) / 2 + Double(Self.markSide)) / Double(Self.markSide)
        return from * LaunchMath.springLeft(t - 0.5, omega: 4.4, damping: 0.74)
    }

    private func pose(width: CGFloat) -> TrackballPose {
        var p = TrackballPose()
        if calm {
            let f = LaunchMath.span(t, 0.1, 0.7)
            p.bodyOpacity = f
            p.ringOpacity = f
            p.ballOpacity = f
            return p
        }
        let hit = Self.hit
        // The ball, rolling in: turned exactly as far as it has rolled.
        let x = ballX(t, width: width)
        let v = (x - ballX(t - 0.03, width: width)) / 0.03          // sides a second
        p.ballOffset = CGSize(width: x, height: 0)
        p.ballOpacity = LaunchMath.span(t, 0.5, 0.95)
        p.orientation = BallSpin.rolled(x / TrackballArt.ballRadius)
        p.roll = CGVector(dx: min(3, v * 2.2), dy: 0)
        p.ballSpeed = min(4, abs(v) * 3)
        // The ring: ticks arrive clockwise, then speed up with the bells, warming pink and streaking.
        p.tickReveal = LaunchMath.easeOut(LaunchMath.span(t, 1.9, 2.6))
        p.ringOpacity = LaunchMath.span(t, 1.9, 2.3)
        p.ringScale = 1.05 - 0.05 * LaunchMath.easeOut(LaunchMath.span(t, 1.9, 2.7))
        p.ringAngle = ringAngle(t)
        let degrees = (ringAngle(t) - ringAngle(t - 0.02)) / 0.02
        p.ringRate = degrees / 9 * 0.13
        p.tickStreak = min(42, degrees * 0.035)
        // The moment: the body and its four pads arrive, and the ring and ball catch the light.
        p.bodyOpacity = LaunchMath.easeOut(LaunchMath.span(t, hit - 0.06, hit + 0.3))
        p.flare = LaunchMath.bump(t, hit - 0.05, hit + 1.0)
        p.comet = LaunchMath.span(t, hit - 0.4, hit) * (1 - LaunchMath.span(t, hit, hit + 0.9))
        p.dim = held * 0.85
        return p
    }
}

// MARK: - The short launch animations

/// About 0.85 s, then the reveal (0.4 s): 1.25 s in all. The ring spins up,
/// its ticks streaking pink, while the ball rolls in with real momentum and
/// settles into its seat with a small overshoot; then the light opens out from
/// it across the window (`RevealOut`) and Overview's numbers count up under it.
/// The two variants differ in where the ball comes from (the left, or the top
/// right), so it isn't the same every time. `calm` (Reduce Motion, and "Quick
/// fade") just fades it in.
struct SplashScene: View {   // internal: drawn by --render-ui and --self-test too
    let variant: SplashVariant
    let t: Double
    let calm: Bool

    static let markSide: CGFloat = 170
    /// Where the trackball sits in the window, for the hand-off's light.
    static let ballAnchor = UnitPoint(x: 0.5, y: 0.44)

    var body: some View {
        GeometryReader { g in
            ZStack {
                LaunchStage(light: calm ? 1 : 0.55 + 0.45 * LaunchMath.easeOut(LaunchMath.span(t, 0.2, 0.7)),
                            bloom: calm ? 0 : LaunchMath.bump(t, 0.35, 1.2))
                VStack(spacing: 22) {
                    TrackballArt(pose: pose(width: g.size.width))
                        .frame(width: Self.markSide, height: Self.markSide)
                    let x = t - 0.4
                    Wordmark(size: 30)
                        .scaleEffect(calm ? 1 : LaunchMath.landing(x, from: 1.14, tau: 0.08, wobble: 20))
                        .opacity(wordmark)
                        .offset(y: calm ? 0 : 5 * (1 - wordmark))
                }
                .offset(y: -12)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
    }

    private var wordmark: Double {
        if calm { return LaunchMath.span(t, 0.05, 0.3) }
        return LaunchMath.easeOut(LaunchMath.span(t, 0.4, 0.55))
    }

    /// Which way the ball comes in from (unit vector, +x right, +y down).
    private var entry: CGVector {
        variant == .rollIn ? CGVector(dx: -1, dy: 0) : CGVector(dx: 0.62, dy: -0.78)
    }

    /// The ring's turn: it spins up fast and comes to rest (degrees).
    private func ringAngle(_ t: Double) -> Double {
        let dir = variant == .rollIn ? 1.0 : -1.0
        return dir * 330 * LaunchMath.easeInOut(LaunchMath.span(t, 0, 0.8))
    }

    private func pose(width: CGFloat) -> TrackballPose {
        var p = TrackballPose()
        if calm {
            let f = LaunchMath.span(t, 0, 0.25)
            p.bodyOpacity = f; p.ringOpacity = f; p.ballOpacity = f
            return p
        }
        let fade = LaunchMath.easeOut(LaunchMath.span(t, 0, 0.22))
        p.bodyOpacity = fade
        p.ringOpacity = fade
        p.tickReveal = LaunchMath.easeOut(LaunchMath.span(t, 0.02, 0.32))
        // The ring spins up and settles, warming pink and streaking while it's fast.
        p.ringAngle = ringAngle(t)
        let degrees = (ringAngle(t) - ringAngle(t - 0.02)) / 0.02
        p.ringRate = degrees / 9 * 0.13
        p.tickStreak = min(40, abs(degrees) * 0.03)
        // The ball rolls in on a spring (a small overshoot), turned exactly as far as it rolled.
        func at(_ t: Double) -> CGSize {
            let k = 1.5 * LaunchMath.springLeft(t - 0.03, omega: 11, damping: 0.62)
            return CGSize(width: entry.dx * k, height: entry.dy * k)
        }
        let o = at(t), before = at(t - 0.02)
        p.ballOffset = o
        p.ballOpacity = LaunchMath.span(t, 0, 0.1)
        let r = TrackballArt.ballRadius
        p.orientation = BallSpin.rolled(1, direction: CGVector(dx: o.width / r, dy: o.height / r))
        let v = hypot(o.width - before.width, o.height - before.height) / 0.02
        p.roll = CGVector(dx: (o.width - before.width) / 0.02, dy: (o.height - before.height) / 0.02)
        p.ballSpeed = min(4, v * 1.5)
        p.flare = 0.6 * LaunchMath.bump(t, 0.3, 0.85)
        return p
    }
}
