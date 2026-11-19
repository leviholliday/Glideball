import AppKit
import SwiftUI

// A Gestures button's ring on screen: a Liquid Glass ring of chips around the held pointer,
// the lit one in the ball's blue, the ring job's readout in the ring's pink, and a small dot
// in the hub that shows where the ball has "rolled" to. A More opens its own ring in place
// (a little smaller, with a way back); a blind hold shows only the readout. The engine decides
// everything (Wheel.swift, Gestures.swift) and hands this a `WheelOverlayModel` through
// `EngineIO.showWheel`; this only draws it. The stand-in pointer (EngineIO's) stays on top at
// the centre, so the pointer you're used to sits in the hub. (Still "Wheel" in the code: it
// was the Wheel action in betas 24 to 27.)

/// The sizes of the ring, for four and for eight places, and a More's (a little smaller).
struct WheelLayout {
    let radius: CGFloat       // centre to a chip's centre
    let chip: CGSize
    let hub: CGFloat          // the hub's diameter
    static let four = WheelLayout(radius: 98, chip: CGSize(width: 92, height: 60), hub: 46)
    static let eight = WheelLayout(radius: 128, chip: CGSize(width: 78, height: 54), hub: 46)
    static let subFour = WheelLayout(radius: 90, chip: CGSize(width: 84, height: 54), hub: 42)
    static let subEight = WheelLayout(radius: 118, chip: CGSize(width: 72, height: 50), hub: 42)
    static func `for`(_ m: WheelOverlayModel) -> WheelLayout {
        m.sub ? (m.eight ? subEight : subFour) : (m.eight ? eight : four)
    }

    /// The window: room for the ring, its glow and the readout under it, centred on the pointer.
    static let canvas = CGSize(width: 420, height: 470)
    /// Where the pointer sits in the canvas (the ring's centre).
    static let centre = CGPoint(x: 210, y: 210)

    /// A place's offset from the centre (0 up, clockwise every 45°).
    func offset(_ place: Int) -> CGSize {
        let a = Double(place) * .pi / 4
        return CGSize(width: radius * CGFloat(sin(a)), height: -radius * CGFloat(cos(a)))
    }
}

/// What the panel shows, observed by the view (main thread only).
@MainActor
@Observable
final class WheelOverlayState {
    var model: WheelOverlayModel? {
        didSet { followLight(from: oldValue) }
    }
    /// Drives the in and out animation: false while it's leaving.
    var shown = false
    /// Where the light (the lit chip's blue) is around the ring, in degrees clockwise from up,
    /// unwrapped so it always glides the short way round from where it was.
    private(set) var lightAngle = 0.0
    /// Changes when the light comes on afresh (nothing was lit, or the ring changed): a new light
    /// fades in where it's needed rather than sweeping there.
    private(set) var lightRun = 0
    /// The place that just ran at the release, and a count that changes each time (its chip
    /// pulses while the ring fades out).
    var ran: Int?
    var ranCount = 0

    private func followLight(from old: WheelOverlayModel?) {
        guard let s = model?.selected else { return }
        let target = Double(s) * 45
        guard old?.selected != nil, old?.sub == model?.sub else {
            lightAngle = target
            lightRun &+= 1
            return
        }
        // The nearest way round: from 315° to 0° is +45°, not −315°.
        let delta = (target - lightAngle).truncatingRemainder(dividingBy: 360)
        lightAngle += delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta
    }
}

/// The ring's motion (design guide, "lit by the ball"): springy but quick, and only while the ring
/// is up. Reduce Motion: fades only.
enum WheelMotion {
    /// More opening and Back: the More's chips grow out of the More chip, the first ring recedes.
    static let open = Animation.spring(response: 0.24, dampingFraction: 0.8)
    /// The light gliding from chip to chip around the ring.
    static let light = Animation.spring(response: 0.2, dampingFraction: 0.78)
    static let fade = Animation.easeOut(duration: 0.15)
}

struct WheelOverlayView: View {
    let state: WheelOverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let m = state.model {
                Group {
                    if m.showsRing {
                        rings(m)
                    } else if let r = m.ring {
                        // A blind hold: only what the ring is doing, just under the pointer.
                        WheelRingReadout(readout: r)
                            .position(x: WheelLayout.centre.x, y: WheelLayout.centre.y + 44)
                    }
                }
                .scaleEffect(state.shown || reduceMotion ? 1 : 0.9)
                .opacity(state.shown ? 1 : 0)
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The first ring, and over it a More's ring when one is open: the More's chips grow out of
    /// the More chip (and shrink back into it on Back) while the first ring recedes behind, dimmed.
    private func rings(_ m: WheelOverlayModel) -> some View {
        let first: [WheelOverlayModel.Slot?]? = m.sub ? m.behind : m.slots
        let firstLayout = m.eight ? WheelLayout.eight : WheelLayout.four
        let subLayout = m.eight ? WheelLayout.subEight : WheelLayout.subFour
        return ZStack {
            if let first {
                // Behind a More's ring the first one steps back: it widens a little past the More's
                // ring, dims and softens, so its chips are a faint echo around the edge.
                ring(slots: first, layout: firstLayout, m: m, active: !m.sub)
                    .scaleEffect(m.sub && !reduceMotion ? 1.16 : 1)
                    .opacity(m.sub ? 0.2 : 1)
                    .blur(radius: m.sub && !reduceMotion ? 2 : 0)
                    .transition(.opacity)
            }
            if m.sub {
                ring(slots: m.slots, layout: subLayout, m: m, active: true)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.12, anchor: growAnchor(m, from: firstLayout, in: subLayout))
                        .combined(with: .opacity))
            }
            WheelHub(dot: m.dot, size: subLayout.hub + (m.sub ? 0 : 4), lit: m.selected != nil, settling: m.settling)
            if let r = m.ring {
                WheelRingReadout(readout: r)
                    .offset(y: (m.sub ? subLayout : firstLayout).radius + (m.sub ? subLayout : firstLayout).chip.height / 2 + 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.width)
        .position(x: WheelLayout.centre.x, y: WheelLayout.canvas.width / 2)
        .animation(reduceMotion ? WheelMotion.fade : WheelMotion.open, value: m.sub)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: m.dot)
        .animation(WheelMotion.fade, value: m.ring?.job)
        .animation(WheelMotion.fade, value: m.settling)
        .animation(WheelMotion.fade, value: state.ran)
    }

    /// Where, in a More's ring's square, the More chip it grew out of sits (the scale's anchor).
    private func growAnchor(_ m: WheelOverlayModel, from first: WheelLayout, in sub: WheelLayout) -> UnitPoint {
        guard let level = m.level else { return .center }
        let o = first.offset(level)
        let side = WheelLayout.canvas.width
        return UnitPoint(x: 0.5 + o.width / side, y: 0.5 + o.height / side)
    }

    /// One ring: its glass band, the light gliding to the lit place, and the chips.
    private func ring(slots: [WheelOverlayModel.Slot?], layout: WheelLayout, m: WheelOverlayModel, active: Bool) -> some View {
        let band = layout.chip.height / 2 + 8
        let track = WheelTrack(inner: layout.radius - band, outer: layout.radius + band)
        let used = m.eight ? Array(0..<8) : [0, 2, 4, 6]
        let lit = active ? m.selected : nil
        let ran = active ? state.ran : nil
        return ZStack {
            // The ring itself: one band of Liquid Glass the slots sit on.
            track
                .fill(.clear)
                .glassEffect(.regular, in: track)
                .overlay { track.stroke(Color.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 18, y: 6)
                .frame(width: (layout.radius + band) * 2, height: (layout.radius + band) * 2)
            // The light: one glow that glides around the ring to whatever is lit, rather than
            // each chip snapping on and off (Reduce Motion: it fades between places instead).
            if active, let lit {
                WheelLight(size: layout.chip, pulse: m.pulse &+ state.ranCount)
                    .modifier(RingOrbit(angle: reduceMotion ? Double(lit) * 45 : state.lightAngle, radius: layout.radius))
                    .animation(reduceMotion ? nil : WheelMotion.light, value: state.lightAngle)
                    .id(reduceMotion ? "\(state.lightRun)-\(lit)" : "\(state.lightRun)")
                    .transition(.opacity)
            }
            // Just opened (More) or back (Back): the chips wait, a little dimmed, until the hand
            // has settled; then they come up to full and the dot appears (the engine's `armed`).
            ForEach(used, id: \.self) { place in
                WheelChip(slot: slots.indices.contains(place) ? slots[place] : nil, lit: lit == place, size: layout.chip,
                          opening: active && m.opening == place, pulse: m.pulse &+ state.ranCount)
                    .opacity(active && m.settling ? 0.5 : ran != nil && ran != place ? 0.35 : 1)
                    .offset(layout.offset(place))
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.width)
        .animation(reduceMotion ? WheelMotion.fade : .spring(response: 0.18, dampingFraction: 0.8), value: lit)
    }
}

/// Moves a view around the ring's centre by angle (degrees clockwise from up), so an animation of
/// the angle glides it along the ring rather than across the middle.
struct RingOrbit: GeometryEffect {
    var angle: Double
    let radius: CGFloat
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let a = angle * .pi / 180
        return ProjectionTransform(CGAffineTransform(translationX: radius * CGFloat(sin(a)), y: -radius * CGFloat(cos(a))))
    }
}

/// The light under the lit chip: the ball's blue, a lit top edge and a soft glow, as if the ball
/// were lighting it. It brightens for a moment each time the lit place runs.
struct WheelLight: View {
    let size: CGSize
    let pulse: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.height / 2.4, 22), style: .continuous)
        shape
            .fill(LinearGradient(colors: [Theme.ball.opacity(0.92), Theme.ball], startPoint: .top, endPoint: .bottom))
            .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
            .frame(width: size.width, height: size.height)
            .keyframeAnimator(initialValue: 0.0, trigger: pulse) { content, glow in
                content
                    .shadow(color: Theme.ball.opacity(0.55 + glow * 0.45), radius: 8 + glow * 10)
                    .scaleEffect(1.06 + glow * 0.08)
            } keyframes: { _ in
                SpringKeyframe(1, duration: 0.07)
                SpringKeyframe(0, duration: 0.2)
            }
    }
}

/// A ring-shaped band (even-odd), for the glass track.
struct WheelTrack: Shape {
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p.normalized(eoFill: true)
    }
}

/// One place: a glass chip with the action's symbol and a short name (or More, or the way
/// back). The light under it (`WheelLight`) is drawn by the ring, so it can glide between chips;
/// lit, the chip's text turns white and it lifts a little, and pulses each time it runs. A More or
/// Back that's lit fills with a ring of light while it waits to open (`WheelHold.confirmDwell`).
struct WheelChip: View {
    let slot: WheelOverlayModel.Slot?
    let lit: Bool
    let size: CGSize
    var opening = false
    var pulse = 0

    private var symbol: String {
        switch slot {
        case .action(let a): a.symbol
        case .more: GestureStep.moreSymbol
        case .back: "arrow.uturn.backward"
        case nil: "circle.dashed"
        }
    }

    private var title: String? {
        switch slot {
        case .action(let a): a.title
        case .more: String(localized: "More", comment: "Gestures: a direction that opens a second ring of actions")
        case .back: String(localized: "Back", comment: "Gestures: in a More's ring, the way back to the first ring")
        case nil: nil
        }
    }

    private var tint: AnyShapeStyle {
        if lit { return AnyShapeStyle(.white) }
        switch slot {
        case nil: return AnyShapeStyle(.tertiary)
        case .back: return AnyShapeStyle(.secondary)
        case .more: return AnyShapeStyle(Theme.ball)
        case .action: return AnyShapeStyle(.primary)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.height / 2.4, 22), style: .continuous)
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: size.height * 0.3, weight: lit ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(height: size.height * 0.36)
            if let title {
                Text(verbatim: title)
                    .font(.system(size: size.height < 58 ? 10 : 10.5, weight: lit ? .semibold : .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(width: size.width, height: size.height)
        .overlay {
            if opening { WheelCharge(shape: shape).transition(.opacity) }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, s in
            content.scaleEffect(lit ? s : 1)
        } keyframes: { _ in
            SpringKeyframe(1.12, duration: 0.07)
            SpringKeyframe(1.0, duration: 0.2)
        }
        .scaleEffect(lit ? 1.06 : 1)
        .opacity(slot == nil ? 0.55 : 1)
    }
}

/// A lit More or Back filling with light while it waits to open: a bright edge drawn round the
/// chip over `WheelHold.confirmDwell` (Reduce Motion: it fades in instead). It only exists while
/// the chip waits, so nothing runs when it isn't shown.
struct WheelCharge: View {
    let shape: RoundedRectangle
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .trim(from: 0, to: reduceMotion ? 1 : progress)
            .stroke(Color.white.opacity(reduceMotion ? 0.4 + progress * 0.5 : 0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: Theme.ball.opacity(0.8), radius: 4)
            .onAppear {
                withAnimation(.linear(duration: WheelHold.confirmDwell)) { progress = 1 }
            }
    }
}

/// The centre: a small glass hub, and a dot where the ball has rolled to (the pointer sits on top).
struct WheelHub: View {
    let dot: CGPoint
    let size: CGFloat
    let lit: Bool
    /// The ring is settling: no dot yet, just the hub.
    var settling = false

    var body: some View {
        let travel = size / 2 - 6
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular, in: Circle())
                .frame(width: size, height: size)
            Circle()
                .fill(Theme.ball)
                .frame(width: 9, height: 9)
                .shadow(color: Theme.ball.opacity(lit ? 0.9 : 0.5), radius: lit ? 6 : 3)
                .offset(x: dot.x * travel, y: dot.y * travel)
                .opacity(settling ? 0 : 1)
        }
    }
}

/// Under the ring once it's turned: what the ring is doing, in the ring's pink.
struct WheelRingReadout: View {
    let readout: WheelOverlayModel.RingReadout

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: readout.job.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: readout.job.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Image(systemName: readout.clockwise ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: 10.5, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Theme.ring.opacity(0.85)), in: Capsule())
        .shadow(color: Theme.ring.opacity(0.6), radius: 10)
        .keyframeAnimator(initialValue: 1.0, trigger: readout.steps) { content, s in
            content.scaleEffect(s)
        } keyframes: { _ in
            SpringKeyframe(1.06, duration: 0.06)
            SpringKeyframe(1.0, duration: 0.2)
        }
        .fixedSize()
    }
}

// MARK: - The window

/// The Wheel's window: borderless, click-through, never key or main, above everything on
/// every Space, just under the stand-in pointer. It never takes focus, so the app in front
/// keeps its selection.
private final class WheelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {}
}

/// Draws the ring for the engine (`EngineIO.wheelPresenter`). Main thread only.
@MainActor
final class WheelOverlayPanel: WheelPresenting {
    static let shared = WheelOverlayPanel()

    private let state = WheelOverlayState()
    private var window: NSPanel?
    private var leaving: DispatchWorkItem?
    private var lastSelected: Int?

    /// Hooks it up to the engine. Called once at launch.
    static func install() { EngineIO.wheelPresenter = shared }

    nonisolated func showWheel(_ model: WheelOverlayModel, at point: CGPoint) {
        MainActor.assumeIsolated { show(model, at: point) }
    }

    nonisolated func hideWheel() {
        MainActor.assumeIsolated { hide() }
    }

    nonisolated func wheelRan(place: Int) {
        MainActor.assumeIsolated { ran(place) }
    }

    /// The release ran `place`: its chip pulses and the rest dim as the ring goes (the hide comes
    /// just after this, and gives the pulse a moment before the ring fades).
    private func ran(_ place: Int) {
        guard let window, window.isVisible, state.model != nil else { return }
        state.ran = place
        state.ranCount &+= 1
        ranAt = CACurrentMediaTime()
    }
    private var ranAt = -Double.infinity

    private func show(_ model: WheelOverlayModel, at point: CGPoint) {
        let window = self.window ?? make()
        leaving?.cancel()
        leaving = nil
        // One soft tick when the light moves to another slot (none when it goes out).
        if let s = model.selected, s != lastSelected {
            Sounds.shared.detent(pitch: 1.0 + Double(s) * 0.04, volume: 0.35, kind: .buttons)
        }
        lastSelected = model.selected
        let size = WheelLayout.canvas
        window.setFrame(NSRect(origin: EngineIO.cocoaOrigin(of: point, hotSpot: WheelLayout.centre, height: size.height), size: size), display: false)
        let appearing = !window.isVisible || !state.shown
        if appearing { state.ran = nil }
        state.model = model
        if appearing {
            window.orderFrontRegardless()
            state.shown = false
            withAnimation(.easeOut(duration: 0.12)) { state.shown = true }
        }
    }

    private func hide() {
        lastSelected = nil
        guard let window, window.isVisible, leaving == nil else { return }
        // Just ran something: a beat for its pulse, then a quick fade (0.26 s in all; it's
        // click-through and the hold is already over). Otherwise gone in 0.08 s, as before.
        let pulsing = CACurrentMediaTime() - ranAt < 0.1 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(pulsing ? .easeIn(duration: 0.14).delay(0.1) : .easeIn(duration: 0.07)) { state.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            state.model = nil
            state.ran = nil
            leaving = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (pulsing ? 0.26 : 0.08), execute: work)
    }

    private func make() -> NSPanel {
        let w = WheelWindow(contentRect: NSRect(origin: .zero, size: WheelLayout.canvas), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)))   // the stand-in pointer is one above
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: WheelOverlayView(state: state))
        host.frame = NSRect(origin: .zero, size: WheelLayout.canvas)
        w.contentView = host
        window = w
        return w
    }
}
