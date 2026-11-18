import AppKit
import SwiftUI

// The Wheel's ring on screen: a Liquid Glass ring of slots around the held pointer,
// the lit slot in the ball's blue, the ring job's readout in the ring's pink, and a
// small dot in the hub that shows where the ball has "rolled" to. The engine decides
// everything (Wheel.swift, Gestures.swift) and hands this a `WheelOverlayModel` through
// `EngineIO.showWheel`; this only draws it. The stand-in pointer (EngineIO's) stays on
// top at the centre, so the pointer you're used to sits in the hub.

/// The sizes of the ring, for four and for eight slots.
struct WheelLayout {
    let radius: CGFloat       // centre to a chip's centre
    let chip: CGSize
    let hub: CGFloat          // the hub's diameter
    static let four = WheelLayout(radius: 98, chip: CGSize(width: 92, height: 60), hub: 46)
    static let eight = WheelLayout(radius: 128, chip: CGSize(width: 78, height: 54), hub: 46)
    static func `for`(_ menu: WheelMenu) -> WheelLayout { menu.eight ? eight : four }

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
    var model: WheelOverlayModel?
    /// Drives the in and out animation: false while it's leaving.
    var shown = false
}

struct WheelOverlayView: View {
    let state: WheelOverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let m = state.model {
                ring(m)
                    .scaleEffect(state.shown || reduceMotion ? 1 : 0.9)
                    .opacity(state.shown ? 1 : 0)
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(_ m: WheelOverlayModel) -> some View {
        let layout = WheelLayout.for(m.menu)
        let filled = Set(m.menu.filled.map(\.place))
        let band = layout.chip.height / 2 + 8
        let track = WheelTrack(inner: layout.radius - band, outer: layout.radius + band)
        return ZStack {
            // The ring itself: one band of Liquid Glass the slots sit on.
            track
                .fill(.clear)
                .glassEffect(.regular, in: track)
                .overlay { track.stroke(Color.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 18, y: 6)
                .frame(width: (layout.radius + band) * 2, height: (layout.radius + band) * 2)
            ForEach(m.menu.usedPlaces, id: \.self) { place in
                WheelChip(action: filled.contains(place) ? m.menu[place] : nil,
                          lit: m.selected == place, size: layout.chip)
                    .offset(layout.offset(place))
            }
            WheelHub(dot: m.dot, size: layout.hub, lit: m.selected != nil)
            if let r = m.ring {
                WheelRingReadout(readout: r)
                    .offset(y: layout.radius + layout.chip.height / 2 + 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .position(WheelLayout.centre)
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.82), value: m.selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: m.dot)
        .animation(.easeOut(duration: 0.12), value: m.ring?.job)
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

/// One slot: a glass chip with the action's symbol and a short name; lit in the ball's blue.
struct WheelChip: View {
    let action: ButtonAction?
    let lit: Bool
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.height / 2.4, 22), style: .continuous)
        VStack(spacing: 3) {
            Image(systemName: action?.symbol ?? "circle.dashed")
                .font(.system(size: size.height * 0.3, weight: lit ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(height: size.height * 0.36)
            if let action {
                Text(verbatim: action.title)
                    .font(.system(size: size.height < 58 ? 10 : 10.5, weight: lit ? .semibold : .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(lit ? AnyShapeStyle(.white) : action == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 6)
        .frame(width: size.width, height: size.height)
        .background {
            // Lit: the ball's blue, with a lit top edge and a soft glow, like the ball lighting it.
            shape
                .fill(LinearGradient(colors: [Theme.ball.opacity(0.92), Theme.ball], startPoint: .top, endPoint: .bottom))
                .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
                .shadow(color: Theme.ball.opacity(0.55), radius: 8)
                .opacity(lit ? 1 : 0)
        }
        .scaleEffect(lit ? 1.06 : 1)
        .opacity(action == nil ? 0.55 : 1)
    }
}

/// The centre: a small glass hub, and a dot where the ball has rolled to (the pointer sits on top).
struct WheelHub: View {
    let dot: CGPoint
    let size: CGFloat
    let lit: Bool

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

/// Draws the Wheel for the engine (`EngineIO.wheelPresenter`). Main thread only.
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
        withAnimation(.easeIn(duration: 0.07)) { state.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            state.model = nil
            leaving = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
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
