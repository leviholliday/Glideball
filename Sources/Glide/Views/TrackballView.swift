import QuartzCore
import SwiftUI

/// What the trackball picture shows, besides what the hand is doing.
enum TrackballLook: Equatable {
    /// Full color: the ball, its ring and buttons answer the real ones.
    case connected
    /// Glideball is off: grey glass, a dim ring.
    case paused
    /// Nothing plugged in: an empty socket, a dashed ring.
    case notConnected
    /// Waiting for Accessibility and Input Monitoring: a grey ball in an amber ring.
    case needsPermission

    @MainActor static func of(_ model: AppModel) -> TrackballLook {
        if !model.permissionsOK { return .needsPermission }
        if !model.config.enabled { return .paused }
        return model.status.deviceConnected ? .connected : .notConnected
    }
}

/// The hero: the trackball, drawn the way it sits on the desk. A dark body
/// with four corner pads, a fine machined ring with tick marks around a well,
/// and the ball in the middle: the app icon's orb, lit from the top left.
/// Roll the ball and its inner light turns and leans the way you roll; turn
/// the ring and its ticks travel with it, warming to pink; press a button and
/// its pad fills amber.
///
/// It redraws only while something moves (`LiveFeed.isActive`), and otherwise
/// holds perfectly still — unless Performance is Smoothest, when the idle
/// ball's light drifts very slowly (`driftFPS`). Never with Reduce Motion.
struct TrackballView: View {
    let feed: LiveFeed
    let pressed: Set<Int>
    var look: TrackballLook = .connected
    /// Frames a second for the idle drift; 0 holds it still.
    var driftFPS: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let drift = reduceMotion || look != .connected ? 0 : driftFPS
        let live = feed.isActive && look == .connected
        let interval = live ? feed.interval : 1 / max(drift, 1)
        TimelineView(.animation(minimumInterval: interval, paused: !live && drift == 0)) { context in
            let now = CACurrentMediaTime()
            let t = context.date.timeIntervalSinceReferenceDate
            TrackballArt(pose: TrackballPose(
                look: look, pressed: pressed,
                ballSpeed: live ? feed.ballSpeed : 0,
                roll: live ? CGVector(dx: feed.rollX, dy: feed.rollY) : .zero,
                ringRate: live ? feed.ringVelocity : 0,
                ringAngle: feed.ringAngle(at: now),
                ballPhase: feed.ballPhase(at: now) + (drift > 0 ? t * 0.05 : 0)))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch look {
        case .connected: Text("Your trackball, live")
        case .paused: Text("Glideball is paused")
        case .notConnected: Text("No trackball connected")
        case .needsPermission: Text("Waiting for permissions…")
        }
    }
}

/// Everything one frame of the trackball needs. The live view fills in the
/// first part from the hand; the launch animations also use the second part to
/// put it together piece by piece.
struct TrackballPose {
    var look: TrackballLook = .connected
    var pressed: Set<Int> = []
    /// Inches a second.
    var ballSpeed = 0.0
    /// Which way the ball rolls (+x right, +y toward you).
    var roll = CGVector.zero
    /// Ring notches a second, signed (+ clockwise).
    var ringRate = 0.0
    /// Where the ring has turned to (degrees).
    var ringAngle = 0.0
    /// How far the liquid inside the ball has turned (radians).
    var ballPhase = 0.0

    // For the launch animations.
    var bodyOpacity = 1.0
    var ringOpacity = 1.0
    var ringScale = 1.0
    /// How many of the ring's ticks are drawn, 0…1, going clockwise from the top.
    var tickReveal = 1.0
    var ballOpacity = 1.0
    var ballScale = 1.0
    /// The ball's offset from its seat, as a fraction of the trackball's side.
    var ballOffset = CGSize.zero
    /// A moment of extra light on the ring and the ball, 0…1.
    var flare = 0.0
}

/// One frame of the trackball. Every size is a fraction of the body's side, `s`.
struct TrackballArt: View {
    let pose: TrackballPose
    var reduceMotion = false

    static let ballRadius = 0.262
    /// The fine colored line at the ring's outer edge.
    static let ringRadius = 0.378
    /// The dark well the ring and ball sit in.
    static let wellRadius = 0.403
    static let tickCount = 60

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                TrackballBody(size: s, look: pose.look)
                    .opacity(pose.bodyOpacity)
                ForEach(Corner.allCases, id: \.self) { corner in
                    CornerPad(corner: corner, size: s, look: pose.look,
                              down: pose.look != .notConnected && pose.pressed.contains(corner.button))
                }
                .opacity(pose.bodyOpacity)
                well(s)
                    .opacity(pose.bodyOpacity)
                ring(s)
                    .opacity(pose.ringOpacity)
                    .scaleEffect(pose.ringScale)
                ballOrSocket(s)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The trackball lives in its own dark world in both appearances, so its part colors are the dark ones.
        .environment(\.colorScheme, .dark)
    }

    private var look: TrackballLook { pose.look }
    private var lit: Bool { look == .connected }
    private var speed: Double { min(pose.ballSpeed / 4, 1) }
    private var spin: Double { min(abs(pose.ringRate) / 14, 1) }

    // MARK: Well

    /// The round hollow the ring and ball sit in: darker than the body, with a faint lip.
    private func well(_ s: CGFloat) -> some View {
        let d = s * Self.wellRadius * 2
        return Circle()
            .fill(RadialGradient(colors: [Color(white: 0.035), Color(white: 0.012)],
                                 center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: d * 0.55))
            .overlay(
                Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.9), .white.opacity(0.07)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(0.75, s * 0.006))
            )
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.5), radius: s * 0.012, y: s * 0.004)
    }

    // MARK: Ring

    @ViewBuilder private func ring(_ s: CGFloat) -> some View {
        let d = s * Self.ringRadius * 2
        let w = max(1.1, s * 0.0085)
        ZStack {
            switch look {
            case .notConnected:
                Circle()
                    .stroke(Color.white.opacity(0.24),
                            style: StrokeStyle(lineWidth: max(0.8, w * 0.8), dash: [max(2, s * 0.014), max(3, s * 0.02)]))
                    .frame(width: d, height: d)
            case .needsPermission:
                ticks(s, color: .white, opacity: 0.16)
                Circle().stroke(Theme.warn.opacity(0.28), lineWidth: w * 4).blur(radius: w * 2.2)
                    .frame(width: d, height: d)
                Circle().stroke(Theme.warn, lineWidth: w)
                    .frame(width: d, height: d)
            case .connected, .paused:
                ticks(s, color: lit ? Color(red: 0.86, green: 0.9, blue: 1) : .white,
                      opacity: lit ? 0.4 + 0.4 * spin + 0.3 * pose.flare : 0.22)
                if lit {
                    // Pink warming the ticks the faster the ring turns.
                    ticks(s, color: Theme.ring, opacity: spin * 0.85)
                        .blendMode(.plusLighter)
                    // The ring's light spilling into the well (the trackball may glow).
                    Circle()
                        .stroke(ringGradient, lineWidth: w * 4.5)
                        .blur(radius: w * 3)
                        .opacity(0.38 + 0.4 * pose.flare)
                        .frame(width: d, height: d)
                }
                // The machined edge: blue at the top, violet below; grey when paused.
                Circle()
                    .stroke(ringGradient, lineWidth: w)
                    .saturation(lit ? 1 : 0)
                    .opacity(lit ? 1 : 0.5)
                    .frame(width: d, height: d)
                // Light catching the top-left of the edge.
                Circle()
                    .trim(from: 0.55, to: 0.75)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(lit ? 0.7 : 0.3), .clear],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: w * 0.7, lineCap: .round))
                    .rotationEffect(.degrees(-6))
                    .frame(width: d, height: d)
                if lit {
                    // Turning: the edge warms to pink and glows, more the faster it goes.
                    Circle()
                        .stroke(Theme.ring, lineWidth: w * (4 + 3 * spin))
                        .blur(radius: w * (2.5 + 3 * spin))
                        .opacity(spin * 0.6)
                        .frame(width: d, height: d)
                    Circle()
                        .stroke(Theme.ring, lineWidth: w * 1.1)
                        .opacity(spin * 0.85)
                        .frame(width: d, height: d)
                    if !reduceMotion && spin > 0.01 { sweep(d, w) }
                }
            }
        }
        .frame(width: s, height: s)
        .animation(Theme.Motion.pause, value: look)
    }

    private var ringGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.36, green: 0.68, blue: 1.0), Color(red: 0.42, green: 0.45, blue: 1.0),
                                Color(red: 0.58, green: 0.33, blue: 0.97)],
                       startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1))
    }

    /// The ring's tick marks: 60 of them, every fifth a little longer, turning with the ring.
    private func ticks(_ s: CGFloat, color: Color, opacity: Double) -> some View {
        let angle = pose.ringAngle
        let reveal = pose.tickReveal
        return Canvas { ctx, size in
            Self.drawTicks(&ctx, size: size, angle: angle, reveal: reveal, color: color, opacity: opacity)
        }
        .frame(width: s, height: s)
        .allowsHitTesting(false)
    }

    private static func drawTicks(_ ctx: inout GraphicsContext, size: CGSize, angle: Double, reveal: Double,
                                  color: Color, opacity: Double) {
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        let side = Double(min(size.width, size.height))
        var minor = Path(), major = Path()
        let shown = Int((Double(tickCount) * min(1, max(0, reveal))).rounded())
        for i in 0..<shown {
            let degrees: Double = Double(i) / Double(tickCount) * 360 + angle - 90
            let a: Double = degrees * Double.pi / 180
            let isMajor = i % 5 == 0
            let r0: Double = side * (isMajor ? 0.320 : 0.327)
            let r1: Double = side * (isMajor ? 0.362 : 0.357)
            let from = CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0)
            let to = CGPoint(x: cx + cos(a) * r1, y: cy + sin(a) * r1)
            if isMajor {
                major.move(to: from); major.addLine(to: to)
            } else {
                minor.move(to: from); minor.addLine(to: to)
            }
        }
        let hair = CGFloat(max(0.6, side * 0.0042))
        ctx.stroke(minor, with: .color(color.opacity(opacity * 0.8)), style: StrokeStyle(lineWidth: hair, lineCap: .round))
        ctx.stroke(major, with: .color(color.opacity(min(1, opacity * 1.25))), style: StrokeStyle(lineWidth: hair * 1.35, lineCap: .round))
        // The inner edge of the tick band.
        let inner: Double = side * 0.311
        let edge = Path(ellipseIn: CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2))
        ctx.stroke(edge, with: .color(.white.opacity(0.06 * min(1, reveal * 3))), lineWidth: CGFloat(max(0.5, side * 0.003)))
    }

    /// A bright arc running round the edge the way it turns, longer and brighter the faster.
    private func sweep(_ d: CGFloat, _ w: CGFloat) -> some View {
        let length = 0.06 + 0.16 * spin
        let clockwise = pose.ringRate >= 0
        return Circle()
            .trim(from: 0, to: length)
            .stroke(AngularGradient(colors: [Theme.ring.opacity(0), Theme.ring.opacity(0.9), .white],
                                    center: .center, startAngle: .zero, endAngle: .degrees(length * 360)),
                    style: StrokeStyle(lineWidth: w * 1.6, lineCap: .round))
            .scaleEffect(x: clockwise ? 1 : -1)
            .rotationEffect(.degrees(pose.ringAngle * (clockwise ? 1 : -1) - 90))
            .opacity(spin)
            .frame(width: d, height: d)
    }

    // MARK: Ball

    @ViewBuilder private func ballOrSocket(_ s: CGFloat) -> some View {
        let d = s * Self.ballRadius * 2
        if look == .notConnected {
            // An empty socket: the outline of where the ball sits.
            Circle()
                .fill(Color.black.opacity(0.4))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18),
                                               style: StrokeStyle(lineWidth: max(0.8, s * 0.006), dash: [max(2, s * 0.012), max(2.5, s * 0.016)])))
                .frame(width: d, height: d)
        } else {
            ZStack {
                // The light the ball throws into the well: blue, a little more as it rolls.
                Circle()
                    .fill(RadialGradient(colors: [Theme.orbBlue.opacity(0.45), Theme.orbViolet.opacity(0.14), .clear],
                                         center: .center, startRadius: d * 0.45, endRadius: d * (0.78 + 0.08 * speed)))
                    .frame(width: d * 1.7, height: d * 1.7)
                    .opacity(lit ? 0.75 + 0.25 * speed + 0.4 * pose.flare : 0)
                // Contact shadow, down and to the right, away from the light.
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: d, height: d)
                    .offset(x: s * 0.008, y: s * 0.016)
                    .blur(radius: s * 0.016)
                OrbBall(diameter: d, phase: pose.ballPhase, roll: rollOffset, reduceMotion: reduceMotion)
                    .saturation(lit ? 1 : 0)
                    .brightness(lit ? 0.06 * pose.flare : (look == .paused ? -0.08 : -0.03))
                    .contrast(lit ? 1 : 0.9)
            }
            .scaleEffect(pose.ballScale)
            .offset(x: pose.ballOffset.width * s, y: pose.ballOffset.height * s)
            .opacity(pose.ballOpacity)
            .animation(Theme.Motion.pause, value: look)
        }
    }

    /// How far the inner light leans the way the ball rolls (a unit-ish vector, scaled by speed).
    private var rollOffset: CGVector {
        let r = pose.roll
        let len = (r.dx * r.dx + r.dy * r.dy).squareRoot()
        guard len > 0.01, !reduceMotion else { return .zero }
        let k = min(len / 3, 1) / len
        return CGVector(dx: r.dx * k, dy: r.dy * k)
    }
}

/// The ball itself: liquid under polished glass (`OrbArt`), masked to a circle.
private struct OrbBall: View {
    let diameter: CGFloat
    /// Turns the liquid as the ball rolls (radians).
    let phase: Double
    /// Leans the liquid and nudges the highlight the way the ball rolls.
    let roll: CGVector
    let reduceMotion: Bool

    var body: some View {
        let layers = OrbArt.layers
        let d = diameter
        ZStack {
            Image(decorative: layers.liquid, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: d * OrbArt.liquidSpan, height: d * OrbArt.liquidSpan)
                .rotationEffect(.radians(reduceMotion ? 0 : phase))
                .offset(x: roll.dx * d * 0.16, y: roll.dy * d * 0.16)
            Image(decorative: layers.glass, scale: 1)
                .resizable()
                .interpolation(.high)
            Image(decorative: layers.glow, scale: 1)
                .resizable()
                .interpolation(.high)
                .blendMode(.plusLighter)
            Image(decorative: layers.highlight, scale: 1)
                .resizable()
                .interpolation(.high)
                .offset(x: roll.dx * d * 0.03, y: roll.dy * d * 0.03)
        }
        .frame(width: d, height: d)
        .compositingGroup()
        .clipShape(Circle())
    }
}

// MARK: - Body and pads

/// The body: a dark rounded square, a shade lighter than the stage, lit from above.
private struct TrackballBody: View {
    let size: CGFloat
    let look: TrackballLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(red: 0.082, green: 0.082, blue: 0.098), Color(red: 0.05, green: 0.05, blue: 0.062)],
                                 startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.55), radius: size * 0.04, y: size * 0.02)
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, size * 0.004))
            )
            .opacity(look == .notConnected ? 0.75 : 1)
    }
}

/// The four buttons, as macOS numbers them: 0 bottom left, 1 bottom right, 2 top left, 3 top right.
private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var button: Int {
        switch self {
        case .bottomLeft: 0
        case .bottomRight: 1
        case .topLeft: 2
        case .topRight: 3
        }
    }
}

/// A corner pad: a quiet raised key in its corner of the body, less the well.
/// Fills amber while its button is down (80 ms in, 250 ms out).
private struct CornerPad: View {
    let corner: Corner
    let size: CGFloat
    let look: TrackballLook
    let down: Bool

    var body: some View {
        let shape = PadShape(corner: corner)
        let hair = max(0.5, size * 0.004)
        ZStack {
            if look == .notConnected {
                shape.stroke(Color.white.opacity(0.09), lineWidth: hair)
            } else {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.115), Color.white.opacity(0.065)],
                                          startPoint: .top, endPoint: .bottom))
                shape.stroke(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: hair)
                // Pressed: amber, lit from above, with a soft glow (the trackball may glow).
                shape.fill(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.45), Theme.buttons],
                                          startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.buttons.opacity(0.65), radius: size * 0.035)
                    .opacity(down ? 1 : 0)
                    .animation(down ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: down)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PadShape: Shape {
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let inset = s * 0.038, gap = s * 0.038
        let half = s / 2
        // The quarter of the body this pad sits in.
        let w = half - inset - gap / 2
        let x = corner == .topLeft || corner == .bottomLeft ? rect.minX + inset : rect.midX + gap / 2
        let y = corner == .topLeft || corner == .topRight ? rect.minY + inset : rect.midY + gap / 2
        let quarter = CGRect(x: x, y: y, width: w, height: w)
        // Rounded like the body at the outside corner; gently elsewhere.
        let outer = s * 0.18, inner = s * 0.045
        let radii: RectangleCornerRadii = switch corner {
        case .topLeft: .init(topLeading: outer, bottomLeading: inner, bottomTrailing: inner, topTrailing: inner)
        case .topRight: .init(topLeading: inner, bottomLeading: inner, bottomTrailing: inner, topTrailing: outer)
        case .bottomLeft: .init(topLeading: inner, bottomLeading: outer, bottomTrailing: inner, topTrailing: inner)
        case .bottomRight: .init(topLeading: inner, bottomLeading: inner, bottomTrailing: outer, topTrailing: inner)
        }
        let pad = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: quarter)
        let well = s * (TrackballArt.wellRadius + 0.024)
        let hole = Path(ellipseIn: CGRect(x: rect.midX - well, y: rect.midY - well, width: well * 2, height: well * 2))
        return pad.subtracting(hole)
    }
}
