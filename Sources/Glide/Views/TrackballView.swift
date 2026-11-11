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

/// The hero: the app icon come alive. A polished ball with liquid color
/// inside, seated in a dark body, a fine ring around it, four soft corner pads.
/// Roll the ball and its inner light turns and leans the way you roll; spin
/// the ring and it sweeps, glowing pink; press a button and its corner fills amber.
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
            TrackballArt(look: look, pressed: pressed,
                         ballSpeed: live ? feed.ballSpeed : 0,
                         roll: live ? CGVector(dx: feed.rollX, dy: feed.rollY) : .zero,
                         ringRate: live ? feed.ringVelocity : 0,
                         ringAngle: feed.ringAngle(at: now),
                         ballPhase: feed.ballPhase(at: now) + (drift > 0 ? t * 0.05 : 0),
                         reduceMotion: reduceMotion)
        }
        .aspectRatio(1, contentMode: .fit)
        // The trackball lives in its own dark world in both appearances, so its part colors are the dark ones.
        .environment(\.colorScheme, .dark)
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

/// One frame of the trackball. Sizes are fractions of the body's side, `s`,
/// taken from the icon (ball radius 236 and ring radius 322 on its 824 tile).
private struct TrackballArt: View {
    let look: TrackballLook
    let pressed: Set<Int>
    let ballSpeed: Double
    let roll: CGVector
    let ringRate: Double
    let ringAngle: Double
    let ballPhase: Double
    let reduceMotion: Bool

    static let ballRadius = 0.2864
    static let ringRadius = 0.3908

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                TrackballBody(size: s)
                ForEach(Corner.allCases, id: \.self) { corner in
                    CornerPad(corner: corner, size: s, down: look != .notConnected && pressed.contains(corner.button))
                }
                ballGlow(s)
                ring(s)
                ballOrSocket(s)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var lit: Bool { look == .connected }
    private var speed: Double { min(ballSpeed / 4, 1) }
    private var spin: Double { min(abs(ringRate) / 14, 1) }

    // MARK: Ball

    @ViewBuilder private func ballOrSocket(_ s: CGFloat) -> some View {
        let d = s * Self.ballRadius * 2
        if look == .notConnected {
            // An empty socket: the outline of where the ball sits.
            Circle()
                .fill(Color.black.opacity(0.35))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: max(1, s * 0.006)))
                .frame(width: d, height: d)
        } else {
            ZStack {
                // Contact shadow, down and to the right like the icon's.
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: d, height: d)
                    .offset(x: s * 0.008, y: s * 0.014)
                    .blur(radius: s * 0.018)
                OrbBall(diameter: d, phase: ballPhase, roll: rollOffset, reduceMotion: reduceMotion)
                    .saturation(lit ? 1 : 0)
                    .brightness(lit ? 0 : (look == .paused ? -0.06 : -0.02))
                    .contrast(lit ? 1 : 0.92)
            }
            .animation(Theme.Motion.pause, value: look)
        }
    }

    /// How far the inner light leans the way the ball rolls (a unit-ish vector, scaled by speed).
    private var rollOffset: CGVector {
        let len = (roll.dx * roll.dx + roll.dy * roll.dy).squareRoot()
        guard len > 0.01, !reduceMotion else { return .zero }
        let k = min(len / 3, 1) / len
        return CGVector(dx: roll.dx * k, dy: roll.dy * k)
    }

    /// The soft halo the ball throws on the body: blue above, violet below. Grows a little with speed.
    @ViewBuilder private func ballGlow(_ s: CGFloat) -> some View {
        let r = s * Self.ballRadius
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.orbViolet.opacity(0.55), Theme.orbViolet.opacity(0.18), .clear],
                                     center: .center, startRadius: r * 0.9, endRadius: r * (1.55 + 0.15 * speed)))
                .offset(x: s * 0.008, y: s * 0.03)
            Circle()
                .fill(RadialGradient(colors: [Theme.orbBlue.opacity(0.35), .clear],
                                     center: .center, startRadius: r * 0.9, endRadius: r * 1.45))
                .offset(y: -s * 0.03)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
        }
        .frame(width: r * 3.4, height: r * 3.4)
        .opacity(lit ? 0.85 + 0.15 * speed : 0)
        .animation(Theme.Motion.pause, value: look)
        .allowsHitTesting(false)
    }

    // MARK: Ring

    @ViewBuilder private func ring(_ s: CGFloat) -> some View {
        let d = s * Self.ringRadius * 2
        let w = max(1.4, s * 0.0135)
        ZStack {
            switch look {
            case .notConnected:
                Circle()
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: max(1, w * 0.75), dash: [max(2, s * 0.012), max(3, s * 0.022)]))
            case .needsPermission:
                Circle().stroke(Theme.warn.opacity(0.22), lineWidth: w * 4).blur(radius: w * 2.5)
                Circle().stroke(Theme.warn, lineWidth: w)
            case .connected, .paused:
                // Light spilling off the ring onto the body.
                Circle()
                    .stroke(ringGradient, lineWidth: w * 5)
                    .blur(radius: w * 3)
                    .opacity(lit ? 0.32 : 0)
                // The ring: blue at the top, violet below, catching the light at the top left.
                Circle()
                    .stroke(ringGradient, lineWidth: w)
                    .overlay(
                        Circle()
                            .trim(from: 0.52, to: 0.78)
                            .stroke(LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                                   startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: w * 0.6, lineCap: .round))
                            .rotationEffect(.degrees(-8))
                    )
                    .saturation(lit ? 1 : 0)
                    .opacity(lit ? 1 : 0.45)
                // Spinning: the ring warms to pink and glows, more the faster it turns.
                Circle()
                    .stroke(Theme.ring, lineWidth: w * (4 + 3 * spin))
                    .blur(radius: w * (2.5 + 3 * spin))
                    .opacity(lit ? spin * 0.55 : 0)
                Circle()
                    .stroke(Theme.ring, lineWidth: w)
                    .opacity(lit ? spin * 0.75 : 0)
                if lit && !reduceMotion { sweep(w) }
            }
        }
        .frame(width: d, height: d)
        .animation(Theme.Motion.pause, value: look)
    }

    private var ringGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.36, green: 0.66, blue: 1.0), Color(red: 0.42, green: 0.42, blue: 0.98),
                                Color(red: 0.56, green: 0.30, blue: 0.95)],
                       startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1))
    }

    /// A bright arc running round the ring the way it turns, longer and brighter the faster.
    private func sweep(_ w: CGFloat) -> some View {
        let length = 0.08 + 0.17 * spin
        let clockwise = ringRate >= 0
        return Circle()
            .trim(from: 0, to: length)
            .stroke(AngularGradient(colors: [Theme.ring.opacity(0), Theme.ring.opacity(0.85), .white],
                                    center: .center, startAngle: .zero, endAngle: .degrees(length * 360)),
                    style: StrokeStyle(lineWidth: w * 1.5, lineCap: .round))
            .scaleEffect(x: clockwise ? 1 : -1)
            .rotationEffect(.degrees(ringAngle * 1.4 - 90))
            .opacity(spin)
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

/// The dark body the ball is seated in: the icon's tile, with a whisper of an edge.
private struct TrackballBody: View {
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        shape
            .fill(Color.black)
            .shadow(color: .black.opacity(0.6), radius: size * 0.05, y: size * 0.025)
            .overlay(shape.fill(RadialGradient(colors: [Color(red: 0.085, green: 0.075, blue: 0.16), Color(red: 0.035, green: 0.03, blue: 0.07)],
                                 center: UnitPoint(x: 0.5, y: 0.47), startRadius: 0, endRadius: size * 0.72)))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05), .white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, size * 0.005))
            )
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

/// A soft corner pad: the corner of the body, less the ring's well and a
/// narrow gap between neighbours. Fills amber while its button is down.
private struct CornerPad: View {
    let corner: Corner
    let size: CGFloat
    let down: Bool

    var body: some View {
        let shape = PadShape(corner: corner)
        ZStack {
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.045), Color.white.opacity(0.02)],
                                      startPoint: .top, endPoint: .bottom))
            shape.stroke(Color.white.opacity(0.055), lineWidth: max(0.5, size * 0.004))
            // Pressed: an amber fill with a soft glow (the trackball may glow).
            shape.fill(Theme.buttons.opacity(0.9))
                .shadow(color: Theme.buttons.opacity(0.7), radius: size * 0.04)
                .opacity(down ? 1 : 0)
                .animation(down ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: down)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PadShape: Shape {
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let inset = s * 0.045, gap = s * 0.05
        let half = s / 2
        // The quarter of the body this pad sits in.
        let w = half - inset - gap / 2
        let x = corner == .topLeft || corner == .bottomLeft ? rect.minX + inset : rect.midX + gap / 2
        let y = corner == .topLeft || corner == .topRight ? rect.minY + inset : rect.midY + gap / 2
        let quarter = CGRect(x: x, y: y, width: w, height: w)
        // Rounded like the body at the outside corner; gently elsewhere.
        let outer = s * 0.185, inner = s * 0.03
        let radii: RectangleCornerRadii = switch corner {
        case .topLeft: .init(topLeading: outer, bottomLeading: inner, bottomTrailing: inner, topTrailing: inner)
        case .topRight: .init(topLeading: inner, bottomLeading: inner, bottomTrailing: inner, topTrailing: outer)
        case .bottomLeft: .init(topLeading: inner, bottomLeading: outer, bottomTrailing: inner, topTrailing: inner)
        case .bottomRight: .init(topLeading: inner, bottomLeading: inner, bottomTrailing: outer, topTrailing: inner)
        }
        let pad = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: quarter)
        let well = s * (TrackballArt.ringRadius + 0.07)
        let hole = Path(ellipseIn: CGRect(x: rect.midX - well, y: rect.midY - well, width: well * 2, height: well * 2))
        return pad.subtracting(hole)
    }
}
