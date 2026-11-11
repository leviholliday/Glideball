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
                    .modifier(RevealOut(progress: reveal, calm: launch.reduceMotion))
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

/// The hand-off: the stage fades away while the trackball eases a touch
/// closer, and the window shows through. Reduce Motion: just the fade.
private struct RevealOut: ViewModifier {
    let progress: Double
    let calm: Bool

    func body(content: Content) -> some View {
        let p = LaunchMath.easeOut(progress)
        content
            .scaleEffect(calm ? 1 : 1 + 0.035 * p)
            .opacity(1 - p)
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
}

/// The near-black stage everything launches on: the window's own lit stage
/// (always the dark one), its aurora centered on the trackball and coming up
/// as the trackball arrives (`light`, 0…1), so the launch hands over to the
/// window without a change of world.
struct LaunchStage: View {
    var light = 1.0

    var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.027, blue: 0.04)
            StaticAtmosphere(dark: true, anchor: UnitPoint(x: 0.5, y: 0.42))
                .environment(\.colorScheme, .dark)
                .opacity(light)
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

// MARK: - The first-launch intro

/// About six and a half seconds, timed to IntroMusic.m4a
/// (scripts/make-intro-music.py): the ball rolls in out of the dark
/// (0.5–2.15 s), the ring's ticks come in around it and spin up as the bells
/// climb (1.9–3.9), and at 3.9 the rest of the trackball arrives, it lifts,
/// and "Glideball" writes in under it. At 6.4 the window takes over.
struct IntroScene: View {   // internal: drawn by --render-ui and --self-test too
    let t: Double
    let calm: Bool

    static let hit = 3.9
    static let markSide: CGFloat = 230

    var body: some View {
        GeometryReader { g in
            let hit = Self.hit
            let lift = calm ? 1 : LaunchMath.easeInOut(LaunchMath.span(t, hit, hit + 0.7))
            ZStack {
                // The room lights up as the ball arrives and the ring spins up.
                LaunchStage(light: calm ? 1 : LaunchMath.easeInOut(LaunchMath.span(t, 0.8, hit + 0.5)))

                TrackballArt(pose: pose(width: g.size.width))
                    .frame(width: Self.markSide, height: Self.markSide)
                    .scaleEffect(1 - 0.12 * lift)
                    .offset(y: -58 * lift)

                VStack(spacing: 10) {
                    let word = calm ? LaunchMath.span(t, 0.5, 1.0) : LaunchMath.easeOut(LaunchMath.span(t, hit + 0.1, hit + 0.75))
                    Wordmark(size: 54)
                        .opacity(word)
                        .offset(y: calm ? 0 : 12 * (1 - word))
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
                    .opacity(LaunchMath.span(t, 1.2, 1.8))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
    }

    /// The ring's turn (degrees): it spins up as the ticks arrive and comes to rest on the moment.
    private func ringAngle(_ t: Double) -> Double {
        600 * LaunchMath.easeInOut(LaunchMath.span(t, 1.95, Self.hit + 0.05))
    }

    /// The ball's offset from its seat (fraction of the trackball's side): in from off the left edge, slowing to a stop.
    private func ballX(_ t: Double, width: CGFloat) -> Double {
        let from = -(Double(width) / 2 + Double(Self.markSide)) / Double(Self.markSide)
        return from * (1 - LaunchMath.easeOut(LaunchMath.span(t, 0.5, 2.15)))
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
        // The ball, rolling in: its light turns as far as it travels and leans the way it goes.
        let x = ballX(t, width: width)
        let v = (x - ballX(t - 0.03, width: width)) / 0.03          // sides a second
        p.ballOffset = CGSize(width: x, height: 0)
        p.ballOpacity = LaunchMath.span(t, 0.5, 0.95)
        p.ballPhase = x / TrackballArt.ballRadius * 0.5
        p.roll = CGVector(dx: min(3, v * 2.2), dy: 0)
        p.ballSpeed = min(4, abs(v) * 3)
        // The ring: ticks arrive clockwise, then spin up and settle, warming pink while they're fast.
        p.tickReveal = LaunchMath.easeOut(LaunchMath.span(t, 1.9, 2.6))
        p.ringOpacity = LaunchMath.span(t, 1.9, 2.3)
        p.ringScale = 1.05 - 0.05 * LaunchMath.easeOut(LaunchMath.span(t, 1.9, 2.7))
        p.ringAngle = ringAngle(t)
        p.ringRate = (ringAngle(t) - ringAngle(t - 0.03)) / 0.03 / 9 * 0.55
        // The moment: the body and its four pads arrive, and the ring and ball catch the light.
        p.bodyOpacity = LaunchMath.easeOut(LaunchMath.span(t, hit - 0.1, hit + 0.35))
        p.flare = LaunchMath.bump(t, hit - 0.1, hit + 1.0)
        return p
    }
}

// MARK: - The short launch animations

/// About 0.8 s, then the reveal (0.35 s): 1.15 s in all. Both variants end
/// on the same settled trackball and wordmark, so the hand-off always looks
/// alike. `calm` (Reduce Motion, and "Quick fade") just fades it in.
struct SplashScene: View {   // internal: drawn by --render-ui and --self-test too
    let variant: SplashVariant
    let t: Double
    let calm: Bool

    static let markSide: CGFloat = 170

    var body: some View {
        GeometryReader { g in
            ZStack {
                LaunchStage()
                VStack(spacing: 22) {
                    TrackballArt(pose: pose(width: g.size.width))
                        .frame(width: Self.markSide, height: Self.markSide)
                    Wordmark(size: 30)
                        .opacity(wordmark)
                        .offset(y: calm ? 0 : 6 * (1 - wordmark))
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
        switch variant {
        case .ringSpin: return LaunchMath.easeOut(LaunchMath.span(t, 0.22, 0.55))
        case .rollIn: return LaunchMath.easeOut(LaunchMath.span(t, 0.35, 0.65))
        }
    }

    private func pose(width: CGFloat) -> TrackballPose {
        var p = TrackballPose()
        if calm {
            let f = LaunchMath.span(t, 0, 0.25)
            p.bodyOpacity = f; p.ringOpacity = f; p.ballOpacity = f
            return p
        }
        switch variant {
        case .ringSpin:
            // Like a flick of the ring: it's turning fast as it appears, and coasts to a stop.
            let fade = LaunchMath.easeOut(LaunchMath.span(t, 0, 0.25))
            p.bodyOpacity = fade
            p.ringOpacity = fade
            p.ballOpacity = LaunchMath.span(t, 0.05, 0.3)
            p.ballScale = 0.94 + 0.06 * LaunchMath.easeOut(LaunchMath.span(t, 0.05, 0.45))
            p.ringAngle = 210 * (1 - exp(-4.5 * t))
            p.ringRate = 210 * 4.5 * exp(-4.5 * t) / 9 * 0.6
            p.flare = 0.5 * LaunchMath.bump(t, 0.35, 0.85)
        case .rollIn:
            // The ball rolls into its seat and the ring settles round it.
            let x = -0.9 * (1 - LaunchMath.easeOut(LaunchMath.span(t, 0, 0.62)))
            let before = -0.9 * (1 - LaunchMath.easeOut(LaunchMath.span(t - 0.03, 0, 0.62)))
            let v = (x - before) / 0.03
            p.bodyOpacity = LaunchMath.easeOut(LaunchMath.span(t, 0, 0.3))
            p.ringOpacity = p.bodyOpacity
            p.ballOpacity = LaunchMath.span(t, 0, 0.18)
            p.ballOffset = CGSize(width: x, height: 0)
            p.ballPhase = x / TrackballArt.ballRadius * 0.5
            p.roll = CGVector(dx: min(3, v * 1.2), dy: 0)
            p.ballSpeed = min(4, abs(v) * 2)
            p.ringAngle = 40 * LaunchMath.easeOut(LaunchMath.span(t, 0.3, 0.8))
            p.flare = 0.5 * LaunchMath.bump(t, 0.45, 0.9)
        }
        return p
    }
}
