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
//
// Its motion (design guide, "lit by the ball"; the plan is 2026-11-19-gestures-premium): the
// ring is the ball's light. It ignites from the pointer (`WheelRings`' entrance), a beam leans
// from the hub toward the roll and locks onto the lit chip (`WheelBeam`), the release launches
// the chip that ran or drains the light back into the pointer (`WheelExit`), and the band's rim
// turns with the scroll ring (`WheelDial`). All of it is drawing: the engine picks from the
// first frame, and nothing moves unless the hand did.

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

    /// Half the glass band's width, and its inner and outer edges.
    var band: CGFloat { chip.height / 2 + 8 }
    var inner: CGFloat { radius - band }
    var outer: CGFloat { radius + band }

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
        didSet { follow(from: oldValue) }
    }
    /// The ring is in the window (from the moment it's shown until its exit has played).
    var shown = false
    /// Changes with every appearance, so each one plays its entrance afresh.
    private(set) var appearCount = 0
    /// Where the light (the lit chip's blue) is around the ring, in degrees clockwise from up,
    /// unwrapped so it always glides the short way round from where it was.
    private(set) var lightAngle = 0.0
    /// Changes when the light comes on afresh (nothing was lit, or the ring changed): a new light
    /// fades in where it's needed rather than sweeping there.
    private(set) var lightRun = 0
    /// Where the beam points (degrees clockwise from up, unwrapped like the light): toward the
    /// roll while nothing is lit, at the lit place once one is.
    private(set) var beamAngle = 0.0
    /// Changes when the beam comes on afresh, so it appears where the roll is, not sweeping there.
    private(set) var beamRun = 0
    /// How far the rim dial has turned (degrees, one tick per step of the scroll ring).
    private(set) var dialAngle = 0.0
    /// The place that just ran at the release, and a count that changes each time (its chip
    /// flares while the ring goes).
    var ran: Int?
    var ranCount = 0
    /// How the ring is leaving, once it is (nil while it's up).
    var exit: WheelExit?
    /// Pictures (render-ui): the entrance held at one moment, and a flare held at its peak.
    var frozen: WheelEntrance?
    var frozenFlare = 0.0
    var frozenDial = 0.0

    /// How strong this appearance's ring of light is. The wave carries no information, and
    /// something seen five times in ten seconds stops being seen, so it's at its full strength
    /// after a rest and gentler when the ring was up a moment ago. Where and when everything
    /// else moves never changes.
    private(set) var waveStrength = WheelOverlayState.fullWave
    static let fullWave = 0.85
    @ObservationIgnored private var lastShown = -Double.infinity

    /// A new appearance: the entrance plays again and nothing is left of the last exit.
    func appear(now: Double = CACurrentMediaTime()) {
        ran = nil
        exit = nil
        appearCount &+= 1
        // 0.4 right after the last one, rising to the full 0.85 over eight seconds of rest.
        waveStrength = 0.4 + (Self.fullWave - 0.4) * max(0, min(1, (now - lastShown) / 8))
        lastShown = now
        shown = true
    }

    /// The ring went: the rest that brings the wave back to full starts now.
    func left(now: Double = CACurrentMediaTime()) { lastShown = now }

    private func follow(from old: WheelOverlayModel?) {
        followLight(from: old)
        guard let m = model else { return }
        // The beam: at the lit place, or leaning the way the ball has rolled.
        var target: Double?
        if let s = m.selected {
            target = Double(s) * 45
        } else if Self.leans(m) {
            target = atan2(Double(m.dot.x), -Double(m.dot.y)) * 180 / .pi
        }
        if let target {
            if let old, old.sub == m.sub, old.selected != nil || Self.leans(old) {
                beamAngle += Self.shortWay(from: beamAngle, to: target)
            } else {
                beamAngle = target
                beamRun &+= 1
            }
        }
        // The rim dial: one tick for each step the scroll ring made.
        if let r = m.ring, let o = old?.ring, r.steps != o.steps { dialAngle += r.clockwise ? WheelDial.tick : -WheelDial.tick }
    }

    /// The roll is far enough from the middle for the beam to show which way it leans.
    static func leans(_ m: WheelOverlayModel) -> Bool {
        !m.settling && m.dot.x * m.dot.x + m.dot.y * m.dot.y >= WheelBeam.leanFrom * WheelBeam.leanFrom
    }

    /// The nearest way round: from 315° to 0° is +45°, not −315°.
    static func shortWay(from: Double, to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta
    }

    private func followLight(from old: WheelOverlayModel?) {
        guard let s = model?.selected else { return }
        let target = Double(s) * 45
        guard old?.selected != nil, old?.sub == model?.sub else {
            lightAngle = target
            lightRun &+= 1
            return
        }
        lightAngle += Self.shortWay(from: lightAngle, to: target)
    }
}

/// The entrance, part by part, each 0 (just lit, at the pointer) to 1 (in place). The view
/// drives them with its own springs; a picture can hold them anywhere.
struct WheelEntrance: Equatable {
    var hub = 1.0
    var band = 1.0
    var chips = 1.0
    /// The ring of light rolling outward: 0 at the hub, 1 at the band's outer edge (nil: gone).
    var wave: Double?
    /// Reduce Motion: the whole ring's opacity (everything else stays in place).
    var fade = 1.0

    static let start = WheelEntrance(hub: 0, band: 0, chips: 0, wave: 0)
    static let faded = WheelEntrance(fade: 0)
    static let done = WheelEntrance()
}

/// The way the ring leaves. `launch`: the release ran a place, so its chip flares and lifts
/// outward while the rest falls back into the pointer. `drain`: nothing ran (let go in the
/// middle, Esc, another button, or the hold ended some other way), so the light drains back
/// into the pointer, quietly. The numbers are how far each part has got (1: done); the view
/// animates to them, and a picture can hold them part-way.
struct WheelExit: Equatable {
    enum Kind { case launch, drain }
    var kind: Kind
    /// The band, the other chips, the hub and the beam falling back and fading.
    var fall = 1.0
    /// The chip that ran, moving outward.
    var sent = 1.0
    /// The chip that ran, and its light, fading.
    var gone = 1.0

    /// From the release to the window going, in seconds.
    static func duration(_ kind: Kind, reduceMotion: Bool) -> Double {
        switch kind {
        case .launch: 0.26
        case .drain: reduceMotion ? 0.08 : 0.10
        }
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

    // The entrance: the ring ignites from the pointer. All settled by about 0.28 s.
    /// The hub pops (the one part with a little bounce: it's small and under the pointer).
    static let hubIn = Animation.spring(response: 0.20, dampingFraction: 0.70)
    /// The hub dot's flash dying down.
    static let igniteOut = Animation.easeOut(duration: 0.18).delay(0.04)
    /// The glass band settling (about 1.5% overshoot).
    static let bandIn = Animation.spring(response: 0.26, dampingFraction: 0.80)
    /// The chips travelling out along their own directions, all together, a frame after the band.
    static let chipsIn = Animation.spring(response: 0.28, dampingFraction: 0.74).delay(0.016)
    /// The ring of light rolling outward.
    static let wave = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.24)
    static let waveTime = 0.24
    /// A More's smaller wave, from the More chip.
    static let subWave = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.20)
    static let readoutIn = Animation.spring(response: 0.22, dampingFraction: 0.8)
    static let fadeIn = Animation.easeOut(duration: 0.12)

    /// The beam leaning after the roll (a short spring, so the coarse steps near the middle glide).
    static let lean = Animation.spring(response: 0.16, dampingFraction: 0.86)
    static let beamFade = Animation.easeOut(duration: 0.12)

    /// The rim dial turning one tick.
    static let dial = Animation.spring(response: 0.18, dampingFraction: 0.85)

    // The exits. Launch: 0.26 s in all; drain: 0.10 s.
    static func rest(_ kind: WheelExit.Kind, reduceMotion: Bool) -> Animation {
        switch kind {
        case .launch: reduceMotion ? .easeIn(duration: 0.14).delay(0.1) : .easeOut(duration: 0.14).delay(0.06)
        case .drain: reduceMotion ? .easeIn(duration: 0.07) : .easeOut(duration: 0.10)
        }
    }
    /// The hub goes last on a drain.
    static func hubOut(_ kind: WheelExit.Kind, reduceMotion: Bool) -> Animation {
        kind == .drain && !reduceMotion ? .easeIn(duration: 0.10) : rest(kind, reduceMotion: reduceMotion)
    }
    static func beamOut(_ kind: WheelExit.Kind, reduceMotion: Bool) -> Animation {
        if reduceMotion { return rest(kind, reduceMotion: true) }
        return kind == .launch ? .easeOut(duration: 0.12).delay(0.06) : .easeOut(duration: 0.08)
    }
    /// The chip that ran: out along its direction, then gone.
    static let sent = Animation.spring(response: 0.18, dampingFraction: 0.8).delay(0.06)
    static func gone(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeIn(duration: 0.14).delay(0.1) : .easeOut(duration: 0.14).delay(0.12)
    }
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func unit(_ v: Double) -> Double { max(0, min(1, v)) }

struct WheelOverlayView: View {
    let state: WheelOverlayState

    var body: some View {
        ZStack {
            if let m = state.model, state.shown {
                Group {
                    if m.showsRing {
                        WheelRings(state: state, m: m)
                    } else if let r = m.ring {
                        // A blind hold: only what the ring is doing, just under the pointer.
                        WheelBlindReadout(state: state, readout: r)
                    }
                }
                // A new appearance is a new ring: its entrance plays from the start.
                .id(state.appearCount)
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A blind hold's readout on its own: it rises a few points into place, and fades when the hold ends.
private struct WheelBlindReadout: View {
    let state: WheelOverlayState
    let readout: WheelOverlayModel.RingReadout
    @State private var entered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: WheelOverlayState, readout: WheelOverlayModel.RingReadout) {
        self.state = state
        self.readout = readout
        _entered = State(initialValue: state.frozen != nil)
    }

    var body: some View {
        let out = state.exit != nil
        WheelRingReadout(readout: readout)
            .scaleEffect(entered || reduceMotion ? 1 : 0.9)
            .offset(y: entered || reduceMotion ? 0 : 4)
            .opacity(entered && !out ? 1 : 0)
            .animation(reduceMotion ? WheelMotion.fadeIn : WheelMotion.readoutIn, value: entered)
            .animation(.easeIn(duration: 0.07), value: out)
            .position(x: WheelLayout.centre.x, y: WheelLayout.centre.y + 44)
            .onAppear { entered = true }
    }
}

/// The ring (and a More's ring over it), with its entrance and its exits.
///
/// The entrance: the ring ignites from the pointer. The hub pops and its dot flashes, one ring
/// of light rolls outward, the glass band settles, and the chips travel out along their own
/// directions (the way you'd roll to pick each). It's drawing only: the engine picks from the
/// first frame, whatever this shows. Everything is driven by the model, a count or one flag
/// changing, so nothing moves while the hand is still and nothing runs while the ring is away.
private struct WheelRings: View {
    let state: WheelOverlayState
    let m: WheelOverlayModel
    /// False for the first frame, then true: each part's own spring takes it from there.
    @State private var entered: Bool
    /// The ring of light exists only while it rolls out.
    @State private var waving: Bool
    /// The overlay came up already inside a More (a blind roll into one): no second wave.
    @State private var bornSub: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(state: WheelOverlayState, m: WheelOverlayModel) {
        self.state = state
        self.m = m
        let still = state.frozen != nil
        _entered = State(initialValue: still)
        _waving = State(initialValue: !still)
        _bornSub = State(initialValue: m.sub)
    }

    private var enter: WheelEntrance {
        if let f = state.frozen { return f }
        if entered { return .done }
        return reduceMotion ? .faded : .start
    }

    // How far the exit has got, as each part reads it (nothing while the ring is up).
    private var fall: Double { state.exit?.fall ?? 0 }
    private var restScale: CGFloat {
        guard let x = state.exit, !reduceMotion else { return 1 }
        return 1 - (x.kind == .launch ? 0.06 : 0.08) * CGFloat(x.fall)
    }
    private var sentBy: CGFloat { reduceMotion ? 0 : 6 * CGFloat(state.exit?.sent ?? 0) }
    private var gone: Double { state.exit?.gone ?? 0 }
    private var exitKind: WheelExit.Kind? { state.exit?.kind }
    private var restOut: Animation? { exitKind.map { WheelMotion.rest($0, reduceMotion: reduceMotion) } }

    var body: some View {
        let first: [WheelOverlayModel.Slot?]? = m.sub ? m.behind : m.slots
        let firstLayout = m.eight ? WheelLayout.eight : WheelLayout.four
        let subLayout = m.eight ? WheelLayout.subEight : WheelLayout.subFour
        let layout = m.sub ? subLayout : firstLayout
        let hub = subLayout.hub + (m.sub ? 0 : 4)
        let e = enter
        let wave: Double? = state.frozen != nil ? e.wave : (waving ? (entered ? 1 : 0) : nil)
        ZStack {
            if let first {
                // Behind a More's ring the first one steps back: it widens a little past the More's
                // ring, dims and softens, so its chips are a faint echo around the edge.
                ring(slots: first, layout: firstLayout, hub: hub, active: !m.sub)
                    .scaleEffect(m.sub && !reduceMotion ? 1.16 : 1)
                    .opacity(m.sub ? 0.2 : 1)
                    .blur(radius: m.sub && !reduceMotion ? 2 : 0)
                    .transition(.opacity)
            }
            if m.sub {
                ring(slots: m.slots, layout: subLayout, hub: hub, active: true)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.12, anchor: growAnchor(from: firstLayout))
                        .combined(with: .opacity))
                if !bornSub, !reduceMotion, let level = m.level {
                    // The More ignites: a smaller ring of light from the More chip out to its ring.
                    WheelSubWave(from: firstLayout.offset(level), start: firstLayout.chip.height / 2, end: subLayout.outer)
                        .id(level)
                }
            }
            if !reduceMotion, let wave {
                // Ignition: one ring of light from the hub to the band's outer edge, then it's gone.
                WheelWave(progress: wave, start: hub / 2, end: layout.outer, strength: state.waveStrength)
                    .animation(WheelMotion.wave, value: entered)
            }
            WheelHub(dot: m.dot, size: hub, lit: m.selected != nil, settling: m.settling, ignite: reduceMotion ? 0 : unit(1 - e.hub))
                .animation(reduceMotion ? nil : WheelMotion.igniteOut, value: entered)
                .scaleEffect(reduceMotion ? 1 : mix(0.6, 1, e.hub) * restScale)
                .opacity(1 - fall)
                .animation(reduceMotion ? nil : WheelMotion.hubIn, value: entered)
                .animation(exitKind.map { WheelMotion.hubOut($0, reduceMotion: reduceMotion) }, value: exitKind)
            if let r = m.ring {
                WheelRingReadout(readout: r)
                    .scaleEffect(reduceMotion ? 1 : mix(0.9, 1, e.chips))
                    .opacity(1 - fall)
                    .offset(y: layout.outer + 22 + (reduceMotion ? 0 : mix(6, 0, e.chips)))
                    .animation(reduceMotion ? nil : WheelMotion.readoutIn, value: entered)
                    .animation(restOut, value: exitKind)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.width)
        .position(x: WheelLayout.centre.x, y: WheelLayout.canvas.width / 2)
        .opacity(e.fade)
        .animation(reduceMotion ? WheelMotion.fadeIn : nil, value: entered)
        .animation(reduceMotion ? WheelMotion.fade : WheelMotion.open, value: m.sub)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: m.dot)
        .animation(WheelMotion.fade, value: m.ring?.job)
        .animation(WheelMotion.fade, value: m.settling)
        .animation(.easeOut(duration: 0.06), value: state.ran)
        .onAppear {
            guard state.frozen == nil else { return }
            entered = true
        }
        .task {
            // The wave is only in the tree while it rolls out.
            guard state.frozen == nil else { return }
            try? await Task.sleep(for: .seconds(WheelMotion.waveTime + 0.06))
            waving = false
        }
        .onChange(of: m.sub) { bornSub = false }
    }

    /// Where, in a More's ring's square, the More chip it grew out of sits (the scale's anchor).
    private func growAnchor(from first: WheelLayout) -> UnitPoint {
        guard let level = m.level else { return .center }
        let o = first.offset(level)
        let side = WheelLayout.canvas.width
        return UnitPoint(x: 0.5 + o.width / side, y: 0.5 + o.height / side)
    }

    /// How bright the beam is: nothing in the middle, growing as the roll nears a choice, full on
    /// the lit place (and a little more while a More or Back fills up).
    private func beamOpacity(lit: Int?) -> Double {
        if m.settling { return 0 }
        if lit != nil { return m.opening != nil ? 1 : 0.9 }
        let r = Double((m.dot.x * m.dot.x + m.dot.y * m.dot.y).squareRoot())
        let from = Double(WheelBeam.leanFrom), to = max(Double(m.selectAt), from + 0.05)
        return 0.55 * unit((r - from) / (to - from))
    }

    /// One ring: the beam, its glass band, the rim dial, the light gliding to the lit place, and the chips.
    private func ring(slots: [WheelOverlayModel.Slot?], layout: WheelLayout, hub: CGFloat, active: Bool) -> some View {
        let track = WheelTrack(inner: layout.inner, outer: layout.outer)
        let used = m.eight ? Array(0..<8) : [0, 2, 4, 6]
        let lit = active ? m.selected : nil
        let ran = active ? state.ran : nil
        let e = enter
        let side = WheelLayout.canvas.width
        let launched = exitKind == .launch
        let charging = lit != nil && m.opening != nil
        return ZStack {
            // The beam: the ball's light leaning from the hub toward the roll, under the glass. It
            // brightens as the roll nears a choice, then locks onto the lit chip.
            if active {
                WheelBeam(inner: hub / 2 + 3, outer: layout.radius, spread: m.eight ? 34 : 46)
                    .keyframeAnimator(initialValue: 0.0, trigger: m.pulse) { content, boost in
                        // A repeating place pumps the light each time it runs.
                        content.brightness(boost * 0.25)
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 0.06)
                        LinearKeyframe(0, duration: 0.2)
                    }
                    // A More or Back filling up: the light pours in, a little wider.
                    .scaleEffect(x: charging && !reduceMotion ? 1.15 : 1)
                    .animation(charging ? .linear(duration: WheelHold.confirmDwell) : WheelMotion.beamFade, value: charging)
                    // Leaving: toward the chip that ran, or back into the hub.
                    .scaleEffect(reduceMotion ? 1 : 1 - (launched ? 0.5 : 0.7) * fall,
                                 anchor: launched ? UnitPoint(x: 0.5, y: 0.5 - layout.radius / side) : .center)
                    .opacity(beamOpacity(lit: lit) * (1 - fall))
                    .animation(exitKind.map { WheelMotion.beamOut($0, reduceMotion: reduceMotion) }, value: exitKind)
                    .animation(WheelMotion.beamFade, value: lit != nil)
                    .rotationEffect(.degrees(state.beamAngle))
                    .animation(reduceMotion ? nil : lit != nil ? WheelMotion.light : WheelMotion.lean, value: state.beamAngle)
                    .id(state.beamRun)
                    .transition(.opacity)
            }
            // The ring itself: one band of Liquid Glass the slots sit on.
            track
                .fill(.clear)
                .glassEffect(.regular, in: track)
                .overlay { track.stroke(Color.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 18, y: 6)
                .frame(width: layout.outer * 2, height: layout.outer * 2)
                .scaleEffect(reduceMotion ? 1 : mix(0.84, 1, e.band) * restScale)
                .opacity(unit(reduceMotion ? 1 : Double(mix(0.45, 1, e.band))) * (1 - fall))
                .animation(reduceMotion ? nil : WheelMotion.bandIn, value: entered)
                .animation(restOut, value: exitKind)
            // The rim dial: once the scroll ring has turned, the band's rim turns with it.
            if active, let r = m.ring {
                WheelDial(radius: layout.outer, angle: reduceMotion ? 0 : state.dialAngle, steps: r.steps, dark: scheme == .dark, hold: state.frozenDial)
                    .scaleEffect(restScale)
                    .opacity(1 - fall)
                    .animation(restOut, value: exitKind)
                    .transition(.opacity)
            }
            // The light: one glow that glides around the ring to whatever is lit, rather than
            // each chip snapping on and off (Reduce Motion: it fades between places instead).
            if active, let lit {
                let sent = ran == lit
                WheelLight(size: layout.chip, pulse: m.pulse &+ state.ranCount, bloom: ran != nil, hold: state.frozenFlare)
                    .opacity(sent ? 1 - gone : 1 - fall)
                    .animation(sent ? WheelMotion.gone(reduceMotion: reduceMotion) : restOut, value: exitKind)
                    .modifier(RingOrbit(angle: reduceMotion ? Double(lit) * 45 : state.lightAngle,
                                        radius: sent ? layout.radius + sentBy : layout.radius * restScale))
                    .animation(reduceMotion ? nil : WheelMotion.light, value: state.lightAngle)
                    .animation(sent ? WheelMotion.sent : restOut, value: exitKind)
                    .id(reduceMotion ? "\(state.lightRun)-\(lit)" : "\(state.lightRun)")
                    .transition(.opacity)
            }
            // The chips. Coming up, each travels out from the pointer along its own direction.
            // Just opened (More) or back (Back): they wait, a little dimmed, until the hand has
            // settled (the engine's `armed`). While one is lit the others step back a little; when
            // one runs it lifts outward and the rest fall back, grey.
            ForEach(used, id: \.self) { place in
                let sent = ran == place
                let grey = !sent && (ran != nil || exitKind == .drain)
                let dim = active && m.settling ? 0.5 : ran != nil && !sent ? 0.35 : lit != nil && lit != place ? 0.82 : 1.0
                let reach = reduceMotion ? layout.radius
                    : layout.radius * mix(0.55, 1, e.chips) * (sent ? 1 : restScale) + (sent ? sentBy : 0)
                let a = Double(place) * .pi / 4
                WheelChip(slot: slots.indices.contains(place) ? slots[place] : nil, lit: lit == place, size: layout.chip,
                          opening: active && m.opening == place, pulse: m.pulse &+ state.ranCount,
                          flare: sent ? (reduceMotion ? 0 : 0.14) : 0.12, hold: sent ? state.frozenFlare : 0)
                    .saturation(grey ? 0 : 1)
                    .opacity(dim * (reduceMotion ? 1 : unit(e.chips)) * (sent ? 1 - gone : 1 - fall))
                    .animation(sent ? WheelMotion.gone(reduceMotion: reduceMotion) : restOut, value: exitKind)
                    .scaleEffect(reduceMotion ? 1 : mix(0.8, 1, e.chips))
                    .offset(x: reach * CGFloat(sin(a)), y: -reach * CGFloat(cos(a)))
                    .animation(reduceMotion ? nil : WheelMotion.chipsIn, value: entered)
                    .animation(sent ? WheelMotion.sent : restOut, value: exitKind)
            }
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? WheelMotion.fade : .spring(response: 0.18, dampingFraction: 0.8), value: lit)
    }
}

/// Moves a view around the ring's centre by angle (degrees clockwise from up), so an animation of
/// the angle glides it along the ring rather than across the middle.
struct RingOrbit: GeometryEffect {
    var angle: Double
    var radius: CGFloat
    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(angle, radius) }
        set {
            angle = newValue.first
            radius = newValue.second
        }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let a = angle * .pi / 180
        return ProjectionTransform(CGAffineTransform(translationX: radius * CGFloat(sin(a)), y: -radius * CGFloat(cos(a))))
    }
}

/// The ring of light that rolls outward as the ring comes up: a thin band whose radius grows from
/// `start` to `end` while it thins and fades. White at its core over the ball's blue.
struct WheelWave: View {
    /// 0 (at the hub) to 1 (at the band's outer edge).
    var progress: Double
    let start: CGFloat
    let end: CGFloat
    /// Where it starts from, off the centre (a More's wave starts at the More chip and ends centred).
    var from: CGSize = .zero
    var strength = 0.85

    var body: some View {
        ZStack {
            WheelWaveBand(progress: progress, start: start, end: end, from: from, thick: 5, thin: 0.75)
                .fill(Theme.ball)
            WheelWaveBand(progress: progress, start: start, end: end, from: from, thick: 2, thin: 0.3)
                .fill(Color.white.opacity(0.9))
        }
        .opacity(strength * (1 - progress))
        .allowsHitTesting(false)
    }
}

/// The wave's band at one moment (its radius and thickness both animate, so it's a shape).
private struct WheelWaveBand: Shape {
    var progress: Double
    let start: CGFloat
    let end: CGFloat
    let from: CGSize
    let thick: CGFloat
    let thin: CGFloat
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let t = CGFloat(progress)
        let c = CGPoint(x: rect.midX + from.width * (1 - t), y: rect.midY + from.height * (1 - t))
        let r = start + (end - start) * t
        let w = thick + (thin - thick) * t
        let inner = max(0, r - w / 2)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - r - w / 2, y: c.y - r - w / 2, width: (r + w / 2) * 2, height: (r + w / 2) * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p.normalized(eoFill: true)
    }
}

/// A More's own, smaller wave: from the More chip out to its ring. It plays once as it appears
/// and ends at nothing.
private struct WheelSubWave: View {
    let from: CGSize
    let start: CGFloat
    let end: CGFloat
    @State private var rolled = false

    var body: some View {
        WheelWave(progress: rolled ? 1 : 0, start: start, end: end, from: from, strength: 0.6)
            .animation(WheelMotion.subWave, value: rolled)
            .onAppear { rolled = true }
    }
}

/// The beam: the ball's light from the hub toward a choice, drawn once pointing up (soft at its
/// sides, brightest a little way out) and turned by the ring. Not glass: one flat layer.
struct WheelBeam: View {
    let inner: CGFloat
    let outer: CGFloat
    /// How wide, in degrees.
    let spread: Double

    /// The beam shows once the roll is this far from the middle (of the ring's reach).
    static let leanFrom: CGFloat = 0.08

    var body: some View {
        let half = spread / 720
        ZStack {
            WheelBeamShape(inner: inner, outer: outer, spread: spread)
                .fill(AngularGradient(stops: [.init(color: Theme.ball.opacity(0), location: 0.75 - half),
                                              .init(color: Theme.ball, location: 0.75),
                                              .init(color: Theme.ball.opacity(0), location: 0.75 + half)], center: .center))
            // A paler core, so it reads as light and not as a blue wedge.
            WheelBeamShape(inner: inner, outer: outer, spread: spread * 0.45)
                .fill(AngularGradient(stops: [.init(color: .white.opacity(0), location: 0.75 - half * 0.45),
                                              .init(color: .white.opacity(0.5), location: 0.75),
                                              .init(color: .white.opacity(0), location: 0.75 + half * 0.45)], center: .center))
        }
            .mask {
                RadialGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.3),
                                       .init(color: .white.opacity(0.8), location: 1)],
                               center: .center, startRadius: inner, endRadius: outer)
            }
            .drawingGroup()
            .allowsHitTesting(false)
    }
}

/// A slice of a ring, centred on straight up.
private struct WheelBeamShape: Shape {
    let inner: CGFloat
    let outer: CGFloat
    let spread: Double
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a = Angle.degrees(-90 - spread / 2), b = Angle.degrees(-90 + spread / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a, endAngle: b, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: b, endAngle: a, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The rim dial: tick marks round the band's outer edge that turn with the scroll ring, one tick
/// per step, and the ones passing the top glow in the ring's pink for a moment. The ticks are
/// drawn once; only their rotation and the pink's opacity change, and only when the ring steps.
struct WheelDial: View {
    /// The band's outer edge.
    let radius: CGFloat
    let angle: Double
    /// Changes with every step.
    let steps: Int
    let dark: Bool
    /// Pictures: the pink held at this much (0…1).
    var hold = 0.0

    static let count = 48
    /// Degrees between ticks: one step of the scroll ring.
    static let tick = 360.0 / Double(count)

    var body: some View {
        ZStack {
            WheelTicks(radius: radius, color: dark ? .white.opacity(0.26) : .black.opacity(0.22))
                .rotationEffect(.degrees(angle))
            WheelTicks(radius: radius, color: Theme.ring, weight: 1.5)
                .rotationEffect(.degrees(angle))
                .mask {
                    // About 60° at the top of the ring, soft at its ends.
                    Circle().fill(AngularGradient(stops: [.init(color: .clear, location: 0.75 - 0.105), .init(color: .white, location: 0.75 - 0.05),
                                                          .init(color: .white, location: 0.75 + 0.05), .init(color: .clear, location: 0.75 + 0.105)],
                                                  center: .center))
                }
                .shadow(color: Theme.ring.opacity(0.8), radius: 3)
                .keyframeAnimator(initialValue: 0.0, trigger: steps) { content, glow in
                    content.opacity(max(glow, hold))
                } keyframes: { _ in
                    LinearKeyframe(1, duration: 0.03)
                    CubicKeyframe(0, duration: 0.4)
                }
        }
        .frame(width: radius * 2 + 8, height: radius * 2 + 8)
        .animation(WheelMotion.dial, value: angle)
        .allowsHitTesting(false)
    }
}

/// The dial's ticks, drawn once and kept as a picture (every fourth a little longer, so a turn
/// reads even between steps).
private struct WheelTicks: View {
    let radius: CGFloat
    let color: Color
    var weight: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var p = Path()
            for i in 0..<WheelDial.count {
                let a = Double(i) * 2 * .pi / Double(WheelDial.count)
                let from = radius - (i % 4 == 0 ? 7 : 4.5), to = radius - 1.5
                p.move(to: CGPoint(x: c.x + from * CGFloat(sin(a)), y: c.y - from * CGFloat(cos(a))))
                p.addLine(to: CGPoint(x: c.x + to * CGFloat(sin(a)), y: c.y - to * CGFloat(cos(a))))
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: weight, lineCap: .round))
        }
        .drawingGroup()
    }
}

/// The light under the lit chip: the ball's blue, a lit top edge and a soft glow, as if the ball
/// were lighting it. It brightens for a moment each time the lit place runs, and blooms when the
/// release runs it.
struct WheelLight: View {
    let size: CGSize
    let pulse: Int
    /// The release ran it: a bigger bloom than a repeat's.
    var bloom = false
    /// Pictures: a glow held at this much (0…1).
    var hold = 0.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.height / 2.4, 22), style: .continuous)
        shape
            .fill(LinearGradient(colors: [Theme.ball.opacity(0.92), Theme.ball], startPoint: .top, endPoint: .bottom))
            .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
            .frame(width: size.width, height: size.height)
            .keyframeAnimator(initialValue: 0.0, trigger: pulse) { content, glow in
                let g = max(glow, hold)
                content
                    .shadow(color: Theme.ball.opacity(0.55 + g * 0.45), radius: 8 + g * (bloom ? 18 : 10))
                    .scaleEffect(1.06 + g * 0.08)
            } keyframes: { _ in
                SpringKeyframe(1, duration: bloom ? 0.06 : 0.07)
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
/// The Gestures editor draws its ring with the same chips.
struct WheelChip: View {
    let slot: WheelOverlayModel.Slot?
    let lit: Bool
    let size: CGSize
    var opening = false
    var pulse = 0
    /// How much it grows for a beat each time it runs (a little more when the release runs it).
    var flare = 0.12
    /// Pictures: the flare held at this much (0…1).
    var hold = 0.0
    /// The editor: what an empty place shows (a faint plus to click), and a More's filled places
    /// drawn as a ring of dots round its symbol.
    var emptySymbol = "circle.dashed"
    var moreDots: [Bool?]? = nil

    private var symbol: String {
        switch slot {
        case .action(let a): a.symbol
        case .more: GestureStep.moreSymbol
        case .back: "arrow.uturn.backward"
        case nil: emptySymbol
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
            if case .more = slot, let moreDots {
                WheelMoreDots(filled: moreDots, lit: lit, size: size.height * 0.36)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size.height * 0.3, weight: lit ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: size.height * 0.36)
            }
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
        .keyframeAnimator(initialValue: 0.0, trigger: pulse) { content, s in
            content.scaleEffect(lit ? 1 + max(s, hold) * flare : 1)
        } keyframes: { _ in
            SpringKeyframe(1, duration: 0.07)
            SpringKeyframe(0, duration: 0.2)
        }
        .scaleEffect(lit ? 1.06 : 1)
        .opacity(slot == nil ? 0.55 : 1)
    }
}

/// A More in the editor: its symbol's circle drawn as dots, one per place of its ring, the
/// filled ones bright. So the chip shows what's inside without a number to explain.
struct WheelMoreDots: View {
    /// By place, clockwise from up: filled or not (nil: a place that isn't in use).
    let filled: [Bool?]
    let lit: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.42, weight: .bold))
            ForEach(filled.indices, id: \.self) { i in
                if let on = filled[i] {
                    let a = Double(i) * 2 * .pi / Double(filled.count)
                    Circle()
                        .opacity(on ? 1 : 0.3)
                        .frame(width: on ? 3.6 : 2.6, height: on ? 3.6 : 2.6)
                        .offset(x: size * 0.62 * CGFloat(sin(a)), y: -size * 0.62 * CGFloat(cos(a)))
                }
            }
        }
        .frame(width: size, height: size)
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
    /// The ring just came up: the dot flashes (1) and dies down to its usual glow (0).
    var ignite = 0.0

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
                .shadow(color: Theme.ball.opacity(min(1, (lit ? 0.9 : 0.5) + ignite * 0.5)), radius: (lit ? 6 : 3) + ignite * 11)
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

    /// The release ran `place`: its chip flares and the rest dim as the ring goes (the hide comes
    /// just after this, and plays the launch).
    private func ran(_ place: Int) {
        guard let window, window.isVisible, state.model != nil, state.exit == nil else { return }
        state.ran = place
        state.ranCount &+= 1
        ranAt = CACurrentMediaTime()
    }
    private var ranAt = -Double.infinity

    private func show(_ model: WheelOverlayModel, at point: CGPoint) {
        let window = self.window ?? make()
        // Shown again while it was leaving: it comes up afresh.
        let appearing = !window.isVisible || !state.shown || leaving != nil
        leaving?.cancel()
        leaving = nil
        // One soft tick when the light moves to another slot (none when it goes out).
        if let s = model.selected, s != lastSelected {
            Sounds.shared.detent(pitch: 1.0 + Double(s) * 0.04, volume: 0.35, kind: .buttons)
        }
        lastSelected = model.selected
        let size = WheelLayout.canvas
        window.setFrame(NSRect(origin: EngineIO.cocoaOrigin(of: point, hotSpot: WheelLayout.centre, height: size.height), size: size), display: false)
        state.model = model
        if appearing {
            // The entrance is the view's own (`WheelRings`): the ring is up from this frame.
            state.appear()
            window.orderFrontRegardless()
        }
    }

    private func hide() {
        lastSelected = nil
        guard let window, window.isVisible, leaving == nil else { return }
        // Just ran something: the launch (its chip flares and lifts outward, the rest falls back
        // into the pointer; 0.26 s in all, as before). Otherwise the light drains back into the
        // pointer, 0.10 s. The window is click-through and the hold is already over, so nothing
        // waits on either.
        let launched = state.ran != nil && CACurrentMediaTime() - ranAt < 0.1
        let kind: WheelExit.Kind = launched ? .launch : .drain
        state.exit = WheelExit(kind: kind)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            state.left()
            state.model = nil
            state.shown = false
            state.ran = nil
            state.exit = nil
            leaving = nil
        }
        leaving = work
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.asyncAfter(deadline: .now() + WheelExit.duration(kind, reduceMotion: reduceMotion), execute: work)
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
