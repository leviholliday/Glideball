import AppKit
import SwiftUI

// Copying something to share: Copy Link, a picture's Copy, the Post on buttons
// (they copy the picture first), and the smaller Copy chips (support info, the
// install ID, connection details). One component, `CopyButton`, so they all
// answer the same way.
//
// The copy happens first, on the click, before anything moves; the motion only
// confirms it. Then a small build-and-release (delight research, 19 Nov: quick,
// medium juice, the outcome easy to read):
//
//   0.00–0.06 s  the button presses in to 94%
//   0.00–0.28 s  a ghost of what was copied (the link as a pill, the picture as a
//                thumbnail) lifts off where it is and arcs into the button, slow
//                in and slow out, shrinking, fading over its last fifth
//   0.28 s       it lands: the button pops to 108%, its icon morphs into a check,
//                "Copy" crossfades to "Copied", a soft glow in the ball's own
//                color (the person's theme) blooms behind it
//   0.35–0.85 s  the pop settles (a damped spring) and the glow fades
//   1.78 s       the label crossfades back
//
// The main beat is 0.35 s; nothing runs before a click or after 0.85 s (the
// timeline is paused, so an idle button costs nothing). Reduce Motion: no ghost,
// no scale, no glow; the label and icon crossfade to the check and back.
// A ghost only flies inside a `.copyStage()` (a sheet or panel) from a
// `.copySource(_:)` in it; without one the button still does its own beat.

/// What flies from the thing copied into the button.
enum CopyGhost {
    /// The link, as a pill.
    case link(String)
    /// The picture, as a thumbnail.
    case picture(CGImage)

    /// Its size at a scale of 1.
    var size: CGSize {
        switch self {
        case .link: CGSize(width: 172, height: 24)
        case .picture: CGSize(width: 96, height: 60)
        }
    }
}

/// What a copy did.
enum CopyOutcome {
    case failed
    /// Copied; the ghost to fly, if there's something to show.
    case copied(CopyGhost?)
}

/// The beat's timeline, as one function of the time since the click, so the
/// app's timeline and a render's frozen moment draw the same thing.
enum CopyBeat {
    static let pressIn = 0.06
    static let landing = 0.28
    static let popPeak = 0.35
    static let settled = 0.85
    /// How long "Copied" stays after it lands.
    static let hold = 1.5

    struct Frame: Equatable {
        var scale: CGFloat = 1
        var glow: Double = 0
    }

    /// Renders: every beat (and flight) drawn frozen this long after its click.
    nonisolated(unsafe) static var sandboxTime: Double?
    /// Renders: the buttons (by id) drawn as if just clicked.
    nonisolated(unsafe) static var sandboxClicked: Set<String> = []

    static func frame(at t: Double) -> Frame {
        guard t >= 0, t < settled else { return Frame() }
        var f = Frame()
        if t < pressIn {
            f.scale = 1 - 0.06 * easeOut(t / pressIn)
        } else if t < landing {
            f.scale = 0.94 + 0.06 * easeOut(min(1, (t - pressIn) / 0.12))
        } else if t < popPeak {
            f.scale = 1 + 0.08 * easeOut((t - landing) / (popPeak - landing))
        } else {
            let u = t - popPeak
            f.scale = 1 + 0.08 * exp(-9 * u) * cos(14 * u)
        }
        if t >= landing {
            let rise = min(1, (t - landing) / 0.06)
            let fall = t < landing + 0.06 ? 1 : exp(-5 * (t - landing - 0.06))
            let end = max(0, min(1, (settled - t) / 0.15))   // nothing left at `settled`
            f.glow = easeOut(rise) * fall * end
        }
        return f
    }

    /// The flight's progress (0 at the click, 1 landed), nil once it's in.
    static func flight(at t: Double) -> Double? {
        guard t >= 0, t <= landing else { return nil }
        return t / landing
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { x * x * x }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

// MARK: - The stage the ghosts fly over

/// The ghosts in the air over one sheet or panel.
@MainActor @Observable
final class CopyStage {
    struct Flight: Identifiable {
        let id = UUID()
        let source: String
        let target: String
        let ghost: CopyGhost
        let start: Date
    }

    private(set) var flights: [Flight] = []

    func launch(from source: String, to target: String, ghost: CopyGhost, start: Date) {
        flights.removeAll { $0.target == target }
        let flight = Flight(source: source, target: target, ghost: ghost, start: start)
        flights.append(flight)
        guard CopyBeat.sandboxTime == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + CopyBeat.landing + 0.05) { [weak self] in
            self?.flights.removeAll { $0.id == flight.id }
        }
    }
}

private struct CopyAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Where ghosts copied from here start: they lift off covering this view.
    func copySource(_ id: String) -> some View {
        anchorPreference(key: CopyAnchorKey.self, value: .bounds) { ["src:" + id: $0] }
    }

    /// The sheet or panel the ghosts fly over (they're drawn above everything in it).
    func copyStage() -> some View { modifier(CopyStageModifier()) }
}

private struct CopyStageModifier: ViewModifier {
    @State private var stage = CopyStage()

    func body(content: Content) -> some View {
        content
            .environment(stage)
            .overlayPreferenceValue(CopyAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if !stage.flights.isEmpty {
                        TimelineView(.animation(paused: CopyBeat.sandboxTime != nil)) { context in
                            ZStack(alignment: .topLeading) {
                                ForEach(stage.flights) { flight in
                                    if let s = anchors["src:" + flight.source], let t = anchors["dst:" + flight.target],
                                       let p = CopyBeat.flight(at: CopyBeat.sandboxTime ?? context.date.timeIntervalSince(flight.start)) {
                                        GhostInFlight(ghost: flight.ghost, from: proxy[s], to: proxy[t], progress: p)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// A ghost somewhere along its arc.
private struct GhostInFlight: View {
    let ghost: CopyGhost
    let from: CGRect
    let to: CGRect
    let progress: Double

    var body: some View {
        let p = CopyBeat.easeInOut(progress)
        let size = ghost.size
        // Where it starts: covering its source (the picture), or growing out of a small one (a row's icon).
        let fit = min(from.width / size.width, from.height / size.height)
        let start = fit
        let peak = fit >= 1 ? fit * 1.04 : max(fit, 1)
        let end = min(0.45, to.height * 0.75 / size.height, to.width * 0.7 / size.width)
        // A big source (the picture) lifts a hair and then shrinks at once, so it never
        // covers the panel for long; a small one (a row's icon) grows into the pill first.
        let big = fit >= 1
        let turn = big ? 0.12 : 0.35
        let scale = progress < turn
            ? start + (peak - start) * CopyBeat.easeOut(progress / turn)
            : peak + (end - peak) * (big ? CopyBeat.easeOut((progress - turn) / (1 - turn)) : CopyBeat.easeIn((progress - turn) / (1 - turn)))
        // A quadratic arc that rises off the source first, then drops into the button.
        // A small source: the ghost's leading edge starts at it, so it grows inward, never past the sheet's edge.
        let a = CGPoint(x: big ? from.midX : from.minX + size.width * peak / 2, y: from.midY)
        let b = CGPoint(x: to.midX, y: to.midY)
        let distance = hypot(b.x - a.x, b.y - a.y)
        let control = CGPoint(x: a.x + (b.x - a.x) * 0.35, y: min(a.y, b.y) - (26 + distance * 0.15))
        let q = CGFloat(p)
        let x = (1 - q) * (1 - q) * a.x + 2 * (1 - q) * q * control.x + q * q * b.x
        let y = (1 - q) * (1 - q) * a.y + 2 * (1 - q) * q * control.y + q * q * b.y
        let lift = sin(Double.pi * min(1, progress * 1.4))
        GhostView(ghost: ghost)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.28 * lift), radius: 2 + 10 * lift, y: 3 + 5 * lift)
            .scaleEffect(scale)
            .opacity(progress < 0.78 ? 1 : max(0, 1 - (progress - 0.78) / 0.22))
            .position(x: x, y: y)
    }
}

/// The ghost itself.
struct GhostView: View {
    let ghost: CopyGhost

    var body: some View {
        switch ghost {
        case .link(let link):
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.orbBlue)
                Text(verbatim: link.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 9)
            .frame(width: ghost.size.width, height: ghost.size.height)
            .background(Capsule().fill(Theme.windowBackground))
            .background(Capsule().fill(Theme.groupFill))
            .overlay(Capsule().strokeBorder(Theme.orbBlue.opacity(0.55), lineWidth: 1))
        case .picture(let image):
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.high)
                .frame(width: ghost.size.width, height: ghost.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

// MARK: - The button

/// A Copy button that copies on the click, then says so (above). Use the button
/// style around it as usual (bordered, `ChipButtonStyle`…).
struct CopyButton: View {
    /// Unique within its stage.
    let id: String
    /// The `.copySource` its ghost flies from, if any.
    var source: String? = nil
    var title: Text = Text("Copy")
    var copiedTitle: Text = Text("Copied")
    /// The icon beside the title, which morphs into the check; nil for words only.
    var symbol: String? = "doc.on.doc"
    var help: Text? = nil
    let copy: () -> CopyOutcome

    @Environment(CopyStage.self) private var stage: CopyStage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var copied = false
    @State private var beat = 0

    var body: some View {
        TimelineView(.animation(paused: start == nil || CopyBeat.sandboxTime != nil)) { context in
            let t = CopyBeat.sandboxTime ?? start.map { context.date.timeIntervalSince($0) } ?? -1
            let f = start == nil ? CopyBeat.Frame() : CopyBeat.frame(at: t)
            Button(action: run) { label }
                .scaleEffect(f.scale)
                .background {
                    if f.glow > 0 {
                        Capsule()
                            .fill(Theme.orbBlue.opacity(0.5 * f.glow))
                            .padding(-5)
                            .blur(radius: 7)
                            .allowsHitTesting(false)
                    }
                }
        }
        .anchorPreference(key: CopyAnchorKey.self, value: .bounds) { ["dst:" + id: $0] }
        .modifier(HelpIfAny(text: help))
        .accessibilityLabel(copied ? copiedTitle : title)
        .onAppear(perform: sandboxClick)
    }

    @ViewBuilder private var label: some View {
        if let symbol {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : symbol)
                    .foregroundStyle(copied ? AnyShapeStyle(Theme.orbBlue) : AnyShapeStyle(.primary))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace)))
                titles
            }
        } else {
            titles
        }
    }

    /// Both titles always laid out, so the button never changes width; one shows.
    private var titles: some View {
        ZStack {
            title.opacity(copied ? 0 : 1)
            HStack(spacing: 4) {
                if symbol == nil {
                    Image(systemName: "checkmark").foregroundStyle(Theme.orbBlue)
                }
                copiedTitle
            }
            .opacity(copied ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private func run() {
        guard case .copied(let ghost) = copy() else { return }   // the copy itself, first
        beat &+= 1
        let token = beat
        let now = Date()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { copied = true }
        } else {
            start = now
            if let source, let ghost, let stage { stage.launch(from: source, to: id, ghost: ghost, start: now) }
            after(CopyBeat.landing, token) { withAnimation(.easeOut(duration: 0.16)) { copied = true } }
            after(CopyBeat.settled, token) { start = nil }
        }
        after(CopyBeat.landing + CopyBeat.hold, token) { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
    }

    private func after(_ delay: Double, _ token: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if beat == token { work() } }
    }

    /// Renders: drawn as if clicked `CopyBeat.sandboxTime` ago (nothing is copied).
    private func sandboxClick() {
        guard Sandbox.isActive, let t = CopyBeat.sandboxTime, CopyBeat.sandboxClicked.contains(id) else { return }
        start = Date()
        copied = reduceMotion || t >= CopyBeat.landing
        if let source, let stage, let ghost = sandboxGhost?() { stage.launch(from: source, to: id, ghost: ghost, start: Date()) }
    }

    /// Renders: the ghost a click would make, without copying.
    var sandboxGhost: (() -> CopyGhost?)? = nil
}

private struct HelpIfAny: ViewModifier {
    let text: Text?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
