import SwiftUI

// What plays over the window at launch (`LaunchExperience` decides which):
// the first-launch intro, or one of six short launch animations. Everything
// is drawn from the clock in a TimelineView that only exists while it plays,
// so there's nothing left running afterwards.

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
                    .modifier(RevealOut(progress: reveal, calm: launch.reduceMotion, iris: show == .intro))
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
        }
    }
}

/// The hand-off: a soft-edged hole opens from the middle with a ring of light
/// at its edge, and the window's glass shows through. Reduce Motion: a fade.
private struct RevealOut: ViewModifier {
    let progress: Double
    let calm: Bool
    /// The intro's wider, slower iris, with a brighter rim.
    let iris: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let p = LaunchMath.easeInOut(progress)
        if calm {
            content.opacity(1 - p)
        } else {
            GeometryReader { g in
                let reach = hypot(g.size.width, g.size.height) * 0.62
                let r = reach * p
                content
                    .mask {
                        Rectangle()
                            .overlay {
                                Circle()
                                    .frame(width: r * 2, height: r * 2)
                                    .blur(radius: 46 * min(1, p * 4))
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .scaleEffect(1 + 0.05 * p)
                    .opacity(1 - LaunchMath.span(progress, 0.6, 1))
                    .overlay {
                        // The light at the edge of the opening.
                        Circle()
                            .stroke(LaunchPalette.cyan.opacity((iris ? 0.7 : 0.5) * (1 - p)), lineWidth: 3 + 10 * (1 - p))
                            .frame(width: r * 2, height: r * 2)
                            .blur(radius: 7)
                            .blendMode(.plusLighter)
                            .opacity(progress > 0 ? 1 : 0)
                    }
                    .frame(width: g.size.width, height: g.size.height)
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
    static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
    /// A damped spring from 0 that overshoots and settles at 1.
    static func spring(_ t: Double, stiffness: Double = 13, damping: Double = 5.5) -> Double {
        t <= 0 ? 0 : 1 - exp(-damping * t) * cos(stiffness * t)
    }
    /// A stable pseudo-random 0…1 for particle `i`, property `k`.
    static func hash(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return v - floor(v)
    }
}

enum LaunchPalette {
    static let cyan = Color(red: 0.55, green: 0.92, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.46, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.52, blue: 0.86)
    static let ice = Color(red: 0.86, green: 0.95, blue: 1.0)
    static let sparks: [Color] = [cyan, violet, pink, ice]
    /// Behind everything before the mesh blooms.
    static let night = Color(red: 0.012, green: 0.014, blue: 0.045)
}

/// How the trackball mark looks at one moment.
struct MarkState {
    var ringOpacity = 1.0
    var ringScale = 1.0
    /// Where ridge 0 is (radians; the ring turns with it).
    var ringAngle = -Double.pi / 2
    /// The comet-like trail behind a spinning ring, 0…1.
    var trail = 0.0
    /// How brightly each of the 36 ridges glows (empty: none do).
    var ridgeGlow: [Double] = []
    var ballOpacity = 1.0
    var ballScale = 1.0
    /// How far the ball has rolled, in radians.
    var roll = 0.0
    /// A star-glint on the ball's highlight, 0…1.
    var shine = 0.0
    /// A violet halo behind the whole mark, 0…1.
    var glow = 0.0

    static let ridges = 36
    static func glow(_ v: Double) -> [Double] { Array(repeating: v, count: ridges) }
    /// Fully formed and still.
    static let settled = MarkState(ridgeGlow: glow(0.18), glow: 0.35)
}

/// The app icon's trackball, drawn live so its parts can move: a glossy
/// blue-violet speckled ball inside a frosted, ridged scroll ring. Same
/// proportions and colours as scripts/make-icon.swift. `size` is the ring's
/// outer diameter; the view is half as big again so glows have room.
struct GlideMark: View {
    let size: CGFloat
    var state: MarkState

    /// Speckles on the ball's surface (a Fibonacci sphere), so it can be seen to roll.
    private static let speckles: [SIMD3<Double>] = (0..<44).map { i in
        let y = 1 - (Double(i) + 0.5) / 44 * 2
        let r = (1 - y * y).squareRoot()
        let a = Double(i) * 2.399963
        return SIMD3(cos(a) * r, y, sin(a) * r)
    }

    var body: some View {
        Canvas { ctx, sz in draw(&ctx, sz) }
            .frame(width: size * 1.5, height: size * 1.5)
            .allowsHitTesting(false)
    }

    /// The mark's measurements for one frame, in Doubles (keeps the drawing
    /// code free of CGFloat/Double mixing).
    private struct Geo {
        let cx: Double, cy: Double
        let ringR: Double, ringW: Double, ballR: Double, hair: Double

        var center: CGPoint { CGPoint(x: cx, y: cy) }
        func point(_ dx: Double, _ dy: Double) -> CGPoint { CGPoint(x: cx + dx, y: cy + dy) }
        func polar(_ angle: Double, _ r: Double) -> CGPoint { CGPoint(x: cx + cos(angle) * r, y: cy + sin(angle) * r) }
        func circle(_ r: Double, at dx: Double = 0, _ dy: Double = 0) -> Path {
            Path(ellipseIn: CGRect(x: cx + dx - r, y: cy + dy - r, width: r * 2, height: r * 2))
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        let s = state
        let u = Double(size) / 0.795                       // the icon's body width
        let geo = Geo(cx: Double(sz.width) / 2, cy: Double(sz.height) / 2,
                      ringR: 0.36 * u * s.ringScale, ringW: 0.075 * u * s.ringScale,
                      ballR: 0.265 * u * s.ballScale, hair: max(1, u * 0.0055))
        if s.glow > 0.001 { drawHalo(&ctx, geo) }
        if s.ringOpacity > 0.001 {
            ctx.drawLayer { l in drawRing(&l, geo) }
        }
        if s.ballOpacity > 0.001 {
            ctx.drawLayer { l in drawBall(&l, geo) }
            if s.shine > 0.01 {
                ctx.drawLayer { l in drawGlint(&l, geo) }
            }
        }
    }

    private func drawHalo(_ ctx: inout GraphicsContext, _ geo: Geo) {
        let r = geo.ringR * 1.9
        let gradient = Gradient(colors: [LaunchPalette.violet.opacity(0.42 * state.glow),
                                         LaunchPalette.violet.opacity(0.12 * state.glow), .clear])
        ctx.fill(geo.circle(r), with: .radialGradient(gradient, center: geo.center, startRadius: 0, endRadius: CGFloat(r)))
    }

    private func drawRing(_ l: inout GraphicsContext, _ geo: Geo) {
        let s = state
        l.opacity = min(1, s.ringOpacity)
        if s.trail > 0.01 {
            l.drawLayer { g in drawTrail(&g, geo) }
        }
        l.stroke(geo.circle(geo.ringR), with: .color(.white.opacity(0.17)), lineWidth: CGFloat(geo.ringW))
        for edge in [geo.ringR - geo.ringW / 2, geo.ringR + geo.ringW / 2] {
            l.stroke(geo.circle(edge), with: .color(.white.opacity(0.26)), lineWidth: 0.75)
        }
        let inner = geo.ringR - geo.ringW * 0.35, outer = geo.ringR + geo.ringW * 0.35
        var ridges = Path()
        for i in 0..<MarkState.ridges {
            let a = ridgeAngle(i)
            ridges.move(to: geo.polar(a, inner))
            ridges.addLine(to: geo.polar(a, outer))
        }
        l.stroke(ridges, with: .color(.white.opacity(0.34)), lineWidth: CGFloat(geo.hair))
        if s.ridgeGlow.contains(where: { $0 > 0.02 }) {
            l.drawLayer { g in drawLitRidges(&g, geo) }
        }
        // The light catching the ring's top edge (it stays with the light, not the ring).
        var edge = Path()
        edge.addRelativeArc(center: geo.center, radius: CGFloat(geo.ringR + geo.ringW / 2),
                            startAngle: .radians(-0.85 * .pi), delta: .radians(0.7 * .pi))
        l.stroke(edge, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: CGFloat(geo.hair * 1.1), lineCap: .round))
    }

    private func ridgeAngle(_ i: Int) -> Double {
        state.ringAngle + Double(i) / Double(MarkState.ridges) * 2 * .pi
    }

    /// A comet of light behind the spinning ring.
    private func drawTrail(_ g: inout GraphicsContext, _ geo: Geo) {
        let s = state
        g.addFilter(.blur(radius: CGFloat(geo.ringW * 0.4)))
        g.blendMode = .plusLighter
        let segments = 30
        let length = 1.6 * Double.pi * min(1, s.trail)
        let step = length / Double(segments)
        for k in 0..<segments {
            let f = Double(k) / Double(segments)
            var arc = Path()
            arc.addRelativeArc(center: geo.center, radius: CGFloat(geo.ringR),
                               startAngle: .radians(s.ringAngle - step * Double(k + 1)), delta: .radians(step * 1.05))
            let alpha = (1 - f) * (1 - f) * 0.85 * s.trail
            g.stroke(arc, with: .color(LaunchPalette.cyan.opacity(alpha)), lineWidth: CGFloat(geo.ringW * (1.1 - 0.6 * f)))
        }
    }

    private func drawLitRidges(_ g: inout GraphicsContext, _ geo: Geo) {
        g.blendMode = .plusLighter
        g.addFilter(.shadow(color: LaunchPalette.cyan, radius: CGFloat(geo.ringW * 0.45)))
        let inner = geo.ringR - geo.ringW * 0.42, outer = geo.ringR + geo.ringW * 0.42
        let style = StrokeStyle(lineWidth: CGFloat(geo.hair * 2.2), lineCap: .round)
        for (i, v) in state.ridgeGlow.enumerated() where v > 0.02 {
            var p = Path()
            p.move(to: geo.polar(ridgeAngle(i), inner))
            p.addLine(to: geo.polar(ridgeAngle(i), outer))
            g.stroke(p, with: .color(LaunchPalette.ice.opacity(min(1, v))), style: style)
        }
    }

    private static let ballGradient = Gradient(stops: [
        .init(color: Color(red: 0.62, green: 0.86, blue: 1.0), location: 0),
        .init(color: Color(red: 0.36, green: 0.42, blue: 0.95), location: 0.3),
        .init(color: Color(red: 0.18, green: 0.10, blue: 0.50), location: 0.68),
        .init(color: Color(red: 0.06, green: 0.03, blue: 0.20), location: 1),
    ])

    private func drawBall(_ l: inout GraphicsContext, _ geo: Geo) {
        let s = state
        let r = geo.ballR
        l.opacity = min(1, s.ballOpacity)
        l.drawLayer { g in
            g.addFilter(.blur(radius: CGFloat(r * 0.16)))
            g.fill(geo.circle(r, at: 0, r * 0.1), with: .color(Color(red: 0.05, green: 0, blue: 0.2).opacity(0.75)))
        }
        let ball = geo.circle(r)
        l.fill(ball, with: .radialGradient(Self.ballGradient, center: geo.point(-r * 0.35, -r * 0.4),
                                           startRadius: 0, endRadius: CGFloat(r * 1.45)))
        l.clip(to: ball)
        // Speckles, turned by the roll and tipped towards you a little.
        let tilt = 0.45
        let cr = cos(s.roll), sr = sin(s.roll), ct = cos(tilt), st = sin(tilt)
        for (i, p) in Self.speckles.enumerated() {
            let x1 = p.x * cr + p.z * sr
            let z1 = -p.x * sr + p.z * cr
            let y2 = p.y * ct - z1 * st
            let z2 = p.y * st + z1 * ct
            guard z2 > 0.02 else { continue }
            let dot = r * 0.05 * (0.3 + 0.7 * z2.squareRoot())
            let color = i % 3 == 0 ? Color.white.opacity(0.32 * z2) : Color(red: 0.04, green: 0.02, blue: 0.2).opacity(0.5 * z2)
            l.fill(geo.circle(dot, at: x1 * r * 0.97, y2 * r * 0.97), with: .color(color))
        }
        let specR = r * 0.42 * (1 + 0.25 * s.shine)
        let spec = specular(geo)
        let shine = Gradient(colors: [.white.opacity(min(1, 0.9 + 0.1 * s.shine)), .white.opacity(0)])
        l.fill(geo.circle(specR, at: -r * 0.32, -r * 0.48),
               with: .radialGradient(shine, center: spec, startRadius: 0, endRadius: CGFloat(specR)))
        var rim = Path()
        rim.addRelativeArc(center: geo.center, radius: CGFloat(r - geo.hair), startAngle: .radians(-0.05 * .pi), delta: .radians(0.5 * .pi))
        l.stroke(rim, with: .color(Color(red: 0.6, green: 0.95, blue: 1).opacity(0.55)), lineWidth: CGFloat(geo.hair * 1.1))
    }

    private func specular(_ geo: Geo) -> CGPoint { geo.point(-geo.ballR * 0.32, -geo.ballR * 0.48) }

    /// A four-point star where the light catches the ball.
    private func drawGlint(_ g: inout GraphicsContext, _ geo: Geo) {
        let s = state
        g.blendMode = .plusLighter
        g.opacity = min(1, s.shine) * min(1, s.ballOpacity)
        let spec = specular(geo)
        let long = geo.ballR * 1.25 * s.shine, thin = geo.ballR * 0.05
        let sx = Double(spec.x), sy = Double(spec.y)
        let star = Gradient(colors: [.white, .white.opacity(0)])
        for rect in [CGRect(x: sx - long, y: sy - thin, width: long * 2, height: thin * 2),
                     CGRect(x: sx - thin, y: sy - long * 0.7, width: thin * 2, height: long * 1.4)] {
            g.fill(Path(ellipseIn: rect), with: .radialGradient(star, center: spec, startRadius: 0, endRadius: CGFloat(long)))
        }
        let soft = geo.ballR * 0.38
        g.fill(geo.circle(soft, at: -geo.ballR * 0.32, -geo.ballR * 0.48),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0)]),
                                     center: spec, startRadius: 0, endRadius: CGFloat(soft)))
    }
}

/// Sparks orbiting the mark on tilted ellipses, with short trails. Drawn in
/// two passes (`front` false, then true) so they pass behind and in front.
private struct OrbitSparks: View {
    let t: Double
    let alpha: Double
    /// Pushes them outward and speeds them up (the big moment), 0…1.
    let burst: Double
    let radius: CGFloat
    let front: Bool
    static let count = 72

    var body: some View {
        Canvas { ctx, sz in
            guard alpha > 0.005 else { return }
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            ctx.blendMode = .plusLighter
            for i in 0..<Self.count {
                let h = { (k: Int) in LaunchMath.hash(i, k) }
                let r = Double(radius) * (1.05 + 1.1 * h(1)) * (1 + 0.9 * burst * (0.4 + h(7)))
                let ratio = 0.22 + 0.42 * h(2)
                let plane = (h(3) - 0.5) * 1.3
                let speed = (0.55 + 1.25 * h(4)) * (h(5) < 0.85 ? 1 : -1)
                let phase = h(6) * 2 * .pi + burst * 1.6 * speed
                let color = LaunchPalette.sparks[i % LaunchPalette.sparks.count]
                let base = 1.0 + 2.2 * h(8)
                for k in 0..<5 {
                    let a = phase + speed * (t - Double(k) * 0.045)
                    let z = sin(a)
                    if (z >= 0) != front { continue }
                    let x = r * cos(a), y = r * ratio * z
                    let px = c.x + x * cos(plane) - y * sin(plane), py = c.y + x * sin(plane) + y * cos(plane)
                    let fade = 1 - Double(k) / 5
                    let depth = 0.55 + 0.45 * (z + 1) / 2
                    let s = base * depth * (k == 0 ? 1 : 0.8 * fade)
                    let o = alpha * fade * depth
                    ctx.fill(Path(ellipseIn: CGRect(x: px - s, y: py - s, width: s * 2, height: s * 2)), with: .color(color.opacity(o)))
                    if k == 0 {
                        let g = s * 3.2
                        ctx.fill(Path(ellipseIn: CGRect(x: px - g, y: py - g, width: g * 2, height: g * 2)), with: .color(color.opacity(o * 0.16)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Sparks spiralling in from all around and condensing onto the ring by 0.75 s.
private struct SwirlSparks: View {
    let t: Double
    let ringRadius: CGFloat
    static let count = 96
    static let converge = 0.75

    var body: some View {
        Canvas { ctx, sz in
            let alpha = LaunchMath.span(t, 0, 0.15) * (1 - LaunchMath.span(t, 0.68, 0.95))
            guard alpha > 0.005 else { return }
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let far = Double(max(sz.width, sz.height)) * 0.55
            ctx.blendMode = .plusLighter
            for i in 0..<Self.count {
                let h = { (k: Int) in LaunchMath.hash(i, k) }
                let start = far * (0.45 + 0.6 * h(1))
                let color = LaunchPalette.sparks[i % LaunchPalette.sparks.count]
                let base = 1.0 + 2.0 * h(5)
                for k in 0..<6 {
                    let tk = t - Double(k) * 0.016
                    let p = LaunchMath.easeIn(LaunchMath.span(tk, 0, Self.converge) * 0.75 + 0.25 * LaunchMath.span(tk, 0, Self.converge))
                    let r = Double(ringRadius) * (0.9 + 0.2 * h(4)) + (start - Double(ringRadius)) * pow(1 - p, 1.3)
                    let a = h(2) * 2 * .pi + (1.5 + 1.5 * h(3)) * tk + 5 * p
                    let fade = 1 - Double(k) / 6
                    let s = base * (k == 0 ? 1 : 0.75 * fade)
                    let px = c.x + r * cos(a), py = c.y + r * sin(a)
                    ctx.fill(Path(ellipseIn: CGRect(x: px - s, y: py - s, width: s * 2, height: s * 2)),
                             with: .color(color.opacity(alpha * fade)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// "Glideball", a letter at a time, then a band of light across it.
private struct ShimmerTitle: View {
    let t: Double
    let start: Double
    let calm: Bool
    var fontSize: CGFloat = 78

    private var font: Font { .system(size: fontSize, weight: .bold, design: .rounded) }
    private var letters: [Character] { Array("Glideball") }

    var body: some View {
        let shimmer = LaunchMath.span(t, start + 0.6, start + 1.45)
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { i, ch in
                let p = calm ? LaunchMath.span(t, start, start + 0.5)
                    : LaunchMath.easeOut(LaunchMath.span(t, start + Double(i) * 0.075, start + 0.5 + Double(i) * 0.075))
                Text(String(ch))
                    .font(font)
                    .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.8, green: 0.84, blue: 1.0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .opacity(p)
                    .offset(y: calm ? 0 : 16 * (1 - p))
                    .scaleEffect(calm ? 1 : 0.9 + 0.1 * p)
                    .blur(radius: calm ? 0 : 8 * (1 - p))
            }
        }
        .shadow(color: LaunchPalette.violet.opacity(0.55), radius: 18)
        .overlay {
            if !calm && shimmer > 0 && shimmer < 1 {
                GeometryReader { g in
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), LaunchPalette.cyan.opacity(0.6), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 90)
                        .rotationEffect(.degrees(16))
                        .offset(x: -120 + (g.size.width + 240) * shimmer)
                        .frame(height: g.size.height)
                }
                .mask {
                    HStack(spacing: 0) {
                        ForEach(Array(letters.enumerated()), id: \.offset) { _, ch in Text(String(ch)).font(font) }
                    }
                }
                .blendMode(.plusLighter)
            }
        }
    }
}

/// The dark mesh blooming out from the middle (the same colours as the
/// window's own background in dark mode).
private struct BloomingMesh: View {
    let t: Double
    let calm: Bool

    var body: some View {
        let colors = GlideBackground.darkColors.enumerated().map { i, color -> Color in
            let dist = hypot(Double(i % 3 - 1), Double(i / 3 - 1))     // 0 middle, 1 edges, 1.4 corners
            let f = calm ? LaunchMath.span(t, 0, 0.6)
                : LaunchMath.easeOut(LaunchMath.span(t, 0.05 + dist * 0.3, 1.1 + dist * 0.45))
            return LaunchPalette.night.mix(with: color, by: f)
        }
        let swirl = Float(calm ? 0 : 0.07 * sin(t * 0.9))
        let drift = Float(calm ? 0 : 0.05 * cos(t * 0.7))
        ZStack {
            LaunchPalette.night
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + swirl, 0], [1, 0],
                [0, 0.5 - drift], [0.5 + drift, 0.5 + swirl], [1, 0.5 + drift],
                [0, 1], [0.5 - swirl, 1], [1, 1],
            ], colors: colors)
            // The first light, before the colour arrives.
            RadialGradient(colors: [LaunchPalette.violet.opacity(0.5), LaunchPalette.violet.opacity(0)],
                           center: .center, startRadius: 0, endRadius: 140 + 420 * LaunchMath.easeOut(LaunchMath.span(t, 0, 1.6)))
                .opacity(calm ? 0 : LaunchMath.bump(t, 0, 2.2))
                .blendMode(.plusLighter)
            // Vignette.
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 200, endRadius: 760)
        }
    }
}

// MARK: - The first-launch intro

/// About seven seconds, timed to IntroMusic.m4a (scripts/make-intro-music.py):
/// the mesh blooms (0–1.4 s), the ball rolls in and catches the light
/// (0.45–2.8), the ring spins up with its ridges lighting in turn and sparks
/// gathering into orbit (1.95–3.9), then the big moment at 3.9 s: a flash,
/// "Glideball" writes in with a shimmer, the tagline (4.8), and at 6.4 the glass
/// opens onto the window.
private struct IntroScene: View {
    let t: Double
    let calm: Bool

    static let hit = 3.9
    static let markSize: CGFloat = 200

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let hit = Self.hit
            let lift = calm ? 1 : LaunchMath.easeInOut(LaunchMath.span(t, hit - 0.15, hit + 0.6))
            let markY = -72 * lift
            let markScale = 1 - 0.2 * lift
            let sparkAlpha = calm ? 0 : LaunchMath.span(t, 2.5, 3.3) * (1 - LaunchMath.span(t, 5.4, 6.6))
            let burst = t > hit ? exp(-(t - hit) * 2.2) * LaunchMath.easeOut(LaunchMath.span(t, hit, hit + 0.25)) : 0

            ZStack {
                BloomingMesh(t: t, calm: calm)

                if !calm {
                    OrbitSparks(t: t, alpha: sparkAlpha, burst: burst, radius: 118 * markScale, front: false)
                        .offset(y: markY)
                    ballTrail(width: w)
                }

                ZStack {
                    GlideMark(size: Self.markSize, state: ringState)
                    GlideMark(size: Self.markSize, state: ballState(width: w))
                        .offset(x: ballX(t, width: w))
                }
                .scaleEffect(markScale)
                .offset(y: markY)

                if !calm {
                    OrbitSparks(t: t, alpha: sparkAlpha, burst: burst, radius: 118 * markScale, front: true)
                        .offset(y: markY)
                    impact
                        .offset(y: markY)
                }

                VStack(spacing: 14) {
                    ShimmerTitle(t: t, start: calm ? 0.8 : hit + 0.05, calm: calm)
                    Text("Make your Expert Mouse feel amazing")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .tracking(calm ? 1.2 : 1.2 + 4 * (1 - LaunchMath.easeOut(LaunchMath.span(t, 4.8, 5.6))))
                        .foregroundStyle(.white.opacity(0.78))
                        .opacity(calm ? LaunchMath.span(t, 1.1, 1.6) : LaunchMath.span(t, 4.8, 5.4))
                        .offset(y: calm ? 0 : 6 * (1 - LaunchMath.easeOut(LaunchMath.span(t, 4.8, 5.5))))
                }
                .offset(y: 118)

                Text("Click to skip")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .opacity(LaunchMath.span(t, 1.2, 1.8))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }

    // MARK: Timing

    /// The ball's offset from the middle: it rolls in from off the left edge
    /// and slows to a stop at 2.15 s.
    private func ballX(_ t: Double, width: CGFloat) -> CGFloat {
        if calm { return 0 }
        let from = -(Double(width) / 2 + 160)
        return CGFloat(from * (1 - LaunchMath.easeOut(LaunchMath.span(t, 0.45, 2.15))))
    }

    private var ballR: Double { 0.265 * Double(Self.markSize) / 0.795 }

    private func ballState(width: CGFloat) -> MarkState {
        let hit = Self.hit
        var s = MarkState()
        s.ringOpacity = 0
        s.ballOpacity = calm ? LaunchMath.span(t, 0.2, 0.9) : LaunchMath.span(t, 0.45, 0.9)
        s.roll = Double(ballX(t, width: width)) / ballR   // rolls exactly as far as it travels
        s.shine = calm ? 0 : LaunchMath.bump(t, 2.0, 2.9) + 0.85 * LaunchMath.bump(t, hit - 0.05, hit + 0.75)
        return s
    }

    private var ringState: MarkState {
        let hit = Self.hit
        var s = MarkState()
        s.ballOpacity = 0
        if calm {
            s.ringOpacity = LaunchMath.span(t, 0.2, 0.9)
            s.ridgeGlow = MarkState.glow(0.22)
            s.glow = 0.5 * LaunchMath.span(t, 0.2, 1.0)
            return s
        }
        let spin = { (t: Double) in -Double.pi / 2 + 6 * .pi * LaunchMath.easeInOut(LaunchMath.span(t, 1.95, hit + 0.05)) }
        let ringIn = LaunchMath.easeOut(LaunchMath.span(t, 1.95, 2.55))
        s.ringOpacity = ringIn
        s.ringScale = 1.35 - 0.35 * ringIn
        s.ringAngle = spin(t)
        s.trail = min(1, (spin(t) - spin(t - 0.03)) / 0.03 / 26)
        // A light chases round the ridges as it spins up; at the big moment
        // they all flare, then settle to a soft glow.
        let head = (t - 2.25) * 44
        let chase = LaunchMath.span(t, 2.25, 2.5) * (1 - LaunchMath.span(t, hit - 0.1, hit + 0.1))
        let flare = t < hit - 0.05 ? 0 : exp(-(t - hit) * 2.4) * 0.9 + 0.22 * LaunchMath.span(t, hit, hit + 0.4)
        s.ridgeGlow = (0..<MarkState.ridges).map { i in
            let behind = (head - Double(i)).truncatingRemainder(dividingBy: Double(MarkState.ridges))
            let lit = head >= Double(i) ? exp(-(behind < 0 ? behind + 36 : behind) / 4.5) : 0
            return max(lit * chase, flare)
        }
        s.glow = 0.55 * LaunchMath.span(t, 0.9, 2.6) + 0.8 * LaunchMath.bump(t, hit - 0.1, hit + 1.4)
        return s
    }

    // MARK: Pieces

    /// A streak of light behind the rolling ball, as long as it's fast.
    private func ballTrail(width: CGFloat) -> some View {
        let x = ballX(t, width: width), before = ballX(t - 0.05, width: width)
        let speed = Double(x - before) / 0.05
        let length = min(360, max(0, speed * 0.32))
        let r = ballR
        return Capsule()
            .fill(LinearGradient(colors: [LaunchPalette.cyan.opacity(0), LaunchPalette.cyan.opacity(0.45), LaunchPalette.violet.opacity(0.6)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: length + r, height: r * 1.5)
            .blur(radius: 14)
            .offset(x: x - CGFloat(length) / 2)
            .opacity(length > 4 ? 1 : 0)
            .blendMode(.plusLighter)
    }

    /// The flash and the shockwave at the big moment.
    @ViewBuilder private var impact: some View {
        let hit = Self.hit
        if t > hit - 0.1 && t < hit + 1.3 {
            let flash = t < hit ? LaunchMath.span(t, hit - 0.08, hit) : exp(-(t - hit) * 5)
            let wave = LaunchMath.easeOut(LaunchMath.span(t, hit, hit + 1.1))
            ZStack {
                RadialGradient(colors: [.white.opacity(0.55 * flash), LaunchPalette.violet.opacity(0.3 * flash), .clear],
                               center: .center, startRadius: 0, endRadius: 360)
                    .blendMode(.plusLighter)
                Circle()
                    .stroke(LaunchPalette.ice.opacity(0.55 * (1 - wave)), lineWidth: 2 + 9 * (1 - wave))
                    .frame(width: 180 + 1100 * wave, height: 180 + 1100 * wave)
                    .blur(radius: 3 + 6 * wave)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - The short launch animations

/// About 1.1 s of animation, then the reveal (0.5 s). Each variant ends on
/// the same settled mark in the middle, so the hand-off always looks alike.
private struct SplashScene: View {
    let variant: SplashVariant
    let t: Double
    let calm: Bool

    static let markSize: CGFloat = 150
    private var u: Double { Double(Self.markSize) / 0.795 }
    private var ringR: Double { 0.36 * u }
    private var ballR: Double { 0.265 * u }

    var body: some View {
        GeometryReader { g in
            ZStack {
                GlideBackground()
                    .environment(\.colorScheme, .dark)
                RadialGradient(colors: [.clear, .black.opacity(0.4)], center: .center, startRadius: 140, endRadius: 720)
                if calm {
                    GlideMark(size: Self.markSize, state: .settled)
                        .opacity(LaunchMath.span(t, 0, 0.35))
                } else {
                    animated(g.size)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }

    @ViewBuilder private func animated(_ size: CGSize) -> some View {
        switch variant {
        case .ringIgnition: ringIgnition
        case .ballRoll: ballRoll(size)
        case .particleSwirl: particleSwirl
        case .ripple: ripple
        case .tabWave: tabWave
        case .flick: flick(size)
        }
    }

    // MARK: Ring ignition

    private var ringIgnition: some View {
        var s = MarkState()
        let ringIn = LaunchMath.easeOut(LaunchMath.span(t, 0, 0.45))
        s.ringOpacity = LaunchMath.easeOut(LaunchMath.span(t, 0, 0.2))
        s.ringScale = 1.15 - 0.15 * ringIn
        s.ringAngle = -.pi / 2 + 2.2 * .pi * LaunchMath.easeOut(LaunchMath.span(t, 0, 1.0))
        s.trail = (1 - LaunchMath.span(t, 0.1, 0.9)) * s.ringOpacity * 0.9
        let head = LaunchMath.span(t, 0.05, 0.7) * Double(MarkState.ridges)
        let pulse = 0.65 * LaunchMath.bump(t, 0.7, 1.15)
        s.ridgeGlow = (0..<MarkState.ridges).map { i in
            let d = head - Double(i)
            return d < 0 ? pulse : max(0.22, exp(-d / 5)) + pulse
        }
        s.ballOpacity = LaunchMath.span(t, 0.3, 0.65)
        s.ballScale = 0.7 + 0.3 * LaunchMath.easeOut(LaunchMath.span(t, 0.3, 0.8))
        s.shine = LaunchMath.bump(t, 0.65, 1.15)
        s.glow = 0.5 * LaunchMath.span(t, 0.2, 0.8)
        return GlideMark(size: Self.markSize, state: s)
    }

    // MARK: Ball roll

    private func ballRoll(_ size: CGSize) -> some View {
        let from = -(Double(size.width) / 2 + 90)
        let x = from * (1 - LaunchMath.easeOut(LaunchMath.span(t, 0, 0.8)))
        let before = from * (1 - LaunchMath.easeOut(LaunchMath.span(t - 0.04, 0, 0.8)))
        let speed = (x - before) / 0.04
        var ball = MarkState()
        ball.ringOpacity = 0
        ball.roll = x / ballR
        ball.shine = LaunchMath.bump(t, 0.72, 1.15)
        var ring = MarkState()
        ring.ballOpacity = 0
        let ringIn = LaunchMath.easeOut(LaunchMath.span(t, 0.58, 0.92))
        ring.ringOpacity = ringIn
        ring.ringScale = 1.4 - 0.4 * ringIn
        ring.ringAngle = -.pi / 2 + 1.2 * .pi * LaunchMath.easeOut(LaunchMath.span(t, 0.58, 1.25))
        ring.ridgeGlow = MarkState.glow(0.2 + 0.55 * LaunchMath.bump(t, 0.8, 1.2))
        ring.glow = 0.45 * ringIn
        let trail = min(300, max(0, speed * 0.22))
        let floorY = CGFloat(ringR + 0.075 * u / 2 + 10)

        let marks = ZStack {
            Capsule()
                .fill(LinearGradient(colors: [LaunchPalette.cyan.opacity(0), LaunchPalette.cyan.opacity(0.5)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: trail + ballR, height: ballR * 1.4)
                .blur(radius: 12)
                .offset(x: x - trail / 2)
                .opacity(trail > 4 ? 1 : 0)
                .blendMode(.plusLighter)
            GlideMark(size: Self.markSize, state: ring)
            GlideMark(size: Self.markSize, state: ball).offset(x: x)
        }
        return ZStack {
            // The glass floor, its reflection fading away beneath.
            marks
                .scaleEffect(x: 1, y: -1)
                .offset(y: floorY * 2)
                .opacity(0.28)
                .mask {
                    LinearGradient(colors: [.white, .clear], startPoint: .center, endPoint: .bottom)
                        .offset(y: floorY)
                }
            Capsule()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 460, height: 1)
                .offset(y: floorY)
                .opacity(LaunchMath.span(t, 0, 0.3))
            marks
        }
    }

    // MARK: Particle swirl

    private var particleSwirl: some View {
        let form = LaunchMath.easeOut(LaunchMath.span(t, 0.62, 0.88))
        var s = MarkState()
        s.ringOpacity = form
        s.ballOpacity = form
        s.ringScale = 1.12 - 0.12 * form
        s.ballScale = 0.85 + 0.15 * form
        s.ringAngle = -.pi / 2 + 0.8 * .pi * LaunchMath.easeOut(LaunchMath.span(t, 0.6, 1.3))
        s.ridgeGlow = MarkState.glow(0.22 + 0.75 * (1 - LaunchMath.span(t, 0.75, 1.25)) * form)
        s.shine = 0.8 * LaunchMath.bump(t, 0.75, 1.2)
        s.glow = 0.4 + 0.5 * LaunchMath.bump(t, 0.6, 1.2)
        return ZStack {
            SwirlSparks(t: t, ringRadius: CGFloat(ringR))
            RadialGradient(colors: [.white.opacity(0.5), LaunchPalette.violet.opacity(0.25), .clear],
                           center: .center, startRadius: 0, endRadius: 220)
                .opacity(LaunchMath.bump(t, 0.66, 1.05))
                .blendMode(.plusLighter)
            GlideMark(size: Self.markSize, state: s)
        }
    }

    // MARK: Ripple

    private var ripple: some View {
        let spring = LaunchMath.spring(t)
        var s = MarkState()
        s.ringOpacity = LaunchMath.span(t, 0, 0.2)
        s.ballOpacity = s.ringOpacity
        s.ridgeGlow = MarkState.glow(0.2 + 0.6 * LaunchMath.bump(t, 0.25, 0.95))
        s.shine = 0.7 * LaunchMath.bump(t, 0.55, 1.1)
        s.glow = 0.45 * LaunchMath.span(t, 0, 0.5)
        return ZStack {
            ForEach(0..<3, id: \.self) { k in
                let p = LaunchMath.span(t, Double(k) * 0.14, Double(k) * 0.14 + 0.95)
                let d = 40 + 900 * LaunchMath.easeOut(p)
                ZStack {
                    // A glassy ripple: a bright crest with a darker trough inside it.
                    Circle().stroke(Color.white.opacity(0.5 * (1 - p)), lineWidth: 2 + 8 * (1 - p))
                    Circle().stroke(Color.black.opacity(0.22 * (1 - p)), lineWidth: 3 + 6 * (1 - p))
                        .padding(8 + 6 * (1 - p))
                }
                .frame(width: d, height: d)
                .blur(radius: 1.5 + 3 * p)
                .opacity(p > 0 && p < 1 ? 1 : 0)
            }
            // A liquid-glass lens that wobbles into place with the mark.
            Circle()
                .fill(.clear)
                .frame(width: 250, height: 250)
                .glassEffect(.clear, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                .scaleEffect(max(0.01, spring))
                .opacity(LaunchMath.span(t, 0, 0.12))
            GlideMark(size: Self.markSize, state: s)
                .scaleEffect(max(0.01, LaunchMath.spring(t - 0.04)))
        }
    }

    // MARK: Tab wave

    private var tabWave: some View {
        let tabs = GlideTab.allCases
        let gather = LaunchMath.easeInOut(LaunchMath.span(t, 0.55, 0.9))
        let markIn = LaunchMath.span(t, 0.68, 0.92)
        var s = MarkState()
        s.ringOpacity = markIn
        s.ballOpacity = markIn
        s.ringScale = 0.7 + 0.3 * LaunchMath.spring(t - 0.68, stiffness: 15, damping: 7)
        s.ballScale = s.ringScale
        s.ringAngle = -.pi / 2 + 0.9 * .pi * LaunchMath.easeOut(LaunchMath.span(t, 0.68, 1.3))
        s.ridgeGlow = MarkState.glow(0.2 + 0.5 * LaunchMath.bump(t, 0.8, 1.2))
        s.shine = 0.8 * LaunchMath.bump(t, 0.82, 1.2)
        s.glow = 0.45 * markIn
        return ZStack {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                let x = (Double(i) - Double(tabs.count - 1) / 2) * 76
                let y = -30 * LaunchMath.bump(t, 0.04 + Double(i) * 0.06, 0.42 + Double(i) * 0.06)
                let o = LaunchMath.span(t, Double(i) * 0.05, Double(i) * 0.05 + 0.16) * (1 - LaunchMath.span(t, 0.72, 0.9))
                ZStack {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.tint(LaunchPalette.violet.opacity(0.25)), in: .circle)
                    Circle()
                        .fill(.white.opacity(0.06))
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                    Image(systemName: tab.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .scaleEffect(1 - 0.6 * gather)
                .offset(x: x * (1 - gather), y: y * (1 - gather))
                .opacity(o)
            }
            GlideMark(size: Self.markSize, state: s)
        }
    }

    // MARK: Flick

    private func flick(_ size: CGSize) -> some View {
        // Arrives from below on momentum, like content after a flick of the ring.
        let v = exp(-5.5 * t)                    // 1 → 0: how fast it's still moving
        let y = 240 * v
        var s = MarkState()
        s.ringOpacity = LaunchMath.span(t, 0, 0.12)
        s.ballOpacity = s.ringOpacity
        s.ringAngle = -.pi / 2 + 3.4 * .pi * (1 - exp(-4 * t))
        s.trail = exp(-3 * t) * s.ringOpacity
        s.roll = 4 * (1 - exp(-4 * t))
        s.ridgeGlow = MarkState.glow(0.2 + 0.5 * LaunchMath.bump(t, 0.55, 1.1))
        s.shine = 0.8 * LaunchMath.bump(t, 0.6, 1.1)
        s.glow = 0.45 * LaunchMath.span(t, 0.2, 0.7)
        return ZStack {
            ForEach(0..<14, id: \.self) { k in
                let h = { (n: Int) in LaunchMath.hash(k + 300, n) }
                let start = h(1) * 0.42
                let p = LaunchMath.span(t, start, start + 0.42)
                let length = 70 + 220 * h(3)
                Capsule()
                    .fill(LinearGradient(colors: [LaunchPalette.sparks[k % 4].opacity(0), LaunchPalette.sparks[k % 4].opacity(0.85)],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: 2 + 3 * h(4), height: length)
                    .offset(x: (h(2) - 0.5) * size.width * 0.9,
                            y: size.height * 0.65 - p * size.height * 1.3)
                    .opacity(LaunchMath.bump(p, 0, 1) * 0.8)
                    .blendMode(.plusLighter)
            }
            GlideMark(size: Self.markSize, state: s)
                .scaleEffect(x: 1 - 0.08 * v, y: 1 + 0.32 * v)
                .blur(radius: 7 * v)
                .offset(y: y)
        }
    }
}
