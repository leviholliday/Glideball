import SwiftUI

// Gesture buttons on the Buttons page: the editor under a gesture button's row
// (a compass of four directions around the ball, the tap, ready-made sets and
// "Try it"), and the overlay that shows a held gesture on any trackball picture.
// The decisions all live in Gestures.swift; this only shows them.

// MARK: - What a held gesture is doing

extension AppModel {
    /// The setup's buttons as the engine runs them right now (an app setup's own, if it has them).
    var buttonsInEffect: [Int: ButtonAction] { activeProfile?.buttons ?? config.buttons }

    /// The gesture a held (or just-released) set of buttons runs.
    func gesture(for buttons: [Int]) -> ButtonGesture? {
        if buttons.count == 1, case .gesture(let g)? = buttonsInEffect[buttons[0]] { return g }
        let chords = activeProfile?.chords ?? config.chords
        if let c = chords.first(where: { $0.buttons == buttons }), case .gesture(let g) = c.action { return g }
        return nil
    }

    /// What a gesture's flash did: a direction's action, or the tap's.
    func action(for flash: Engine.GestureFlash) -> ButtonAction? {
        guard let g = gesture(for: flash.buttons) else { return nil }
        if let d = flash.direction { return g[d]?.action }
        return g.tap == .system && flash.buttons.count == 1 ? ButtonAction.normal(for: flash.buttons[0]) : g.tap
    }
}

extension GestureDirection {
    var arrow: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }

    var unit: CGVector {
        switch self {
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
    }

    /// "Roll up", for VoiceOver and the live line.
    var rollTitle: String {
        switch self {
        case .up: String(localized: "Roll up", comment: "Gesture direction: roll the ball away from you")
        case .down: String(localized: "Roll down", comment: "Gesture direction: roll the ball toward you")
        case .left: String(localized: "Roll left", comment: "Gesture direction")
        case .right: String(localized: "Roll right", comment: "Gesture direction")
        }
    }
}

/// Keeps the last thing a gesture did on screen for a moment (a flash), then lets it go.
@MainActor
@Observable
final class GestureFlashClock {
    private(set) var shown: Engine.GestureFlash?
    @ObservationIgnored private var clear: Task<Void, Never>?

    /// Renders: keep whatever flash the model has, lit (there's no clock in a picture).
    nonisolated(unsafe) static var sandboxHold = false

    func show(_ flash: Engine.GestureFlash?) {
        guard let flash else { return }
        shown = flash
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            self?.shown = nil
        }
    }

    func current(_ modes: Engine.Modes) -> Engine.GestureFlash? {
        Self.sandboxHold ? modes.gestureFlash : shown
    }
}

// MARK: - The editor

/// Under a gesture button's row: what each way does, the tap, sets, and Try it.
struct GestureEditor: View {
    let model: AppModel?
    let button: Int
    @Binding var gesture: ButtonGesture

    @State private var trying = false
    @State private var clock = GestureFlashClock()
    @State private var tryEnd: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Renders: draw it in its "Try it" state.
    nonisolated(unsafe) static var sandboxTrying = false

    private var modes: Engine.Modes { model?.modes ?? Engine.Modes() }
    private var held: Bool { modes.gestureHeld && modes.gestureButtons == [button] }
    private var leaning: GestureDirection? { held ? modes.gestureDirection : nil }
    private var flash: Engine.GestureFlash? {
        guard let f = clock.current(modes), f.buttons == [button] else { return nil }
        return f
    }
    private var isTrying: Bool { trying || Self.sandboxTrying }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: explanation)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    compass
                    side.frame(maxWidth: 250, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    compass.frame(maxWidth: .infinity)
                    HStack(alignment: .top, spacing: 28) {
                        tapBlock
                        VStack(alignment: .leading, spacing: 12) { setsBlock; tryButton }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    compass.frame(maxWidth: .infinity)
                    side
                }
            }

            if isTrying { tryBanner.transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
        .padding(.leading, ButtonRow.dividerInset - Theme.Space.rowHorizontal)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .animation(Theme.Motion.spring, value: isTrying)
        .animation(reduceMotion ? nil : Theme.Motion.pressIn, value: leaning)
        .onChange(of: modes.gestureFlash) { _, f in
            if f?.buttons == [button] { clock.show(f) }
        }
        .onDisappear { if trying { stopTrying() } }
    }

    private var explanation: String {
        String(localized: "Hold this button and roll the ball. Each way does something the moment you roll a few millimeters; a quick press does the tap.",
               comment: "Gesture editor, under a gesture button's row")
    }

    // MARK: Compass

    private var compass: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                cell(.up)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                cell(.left)
                GestureBall(leaning: leaning, held: held, fired: flash?.direction, size: 74)
                cell(.right)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                cell(.down)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
        .fixedSize()
    }

    private func cell(_ d: GestureDirection) -> some View {
        GestureDirectionCell(
            direction: d,
            step: Binding(get: { gesture[d] }, set: { gesture[d] = $0 }),
            lit: leaning == d,
            fired: flash != nil && flash?.direction == d)
    }

    // MARK: Tap, sets, Try it

    private var side: some View {
        VStack(alignment: .leading, spacing: 14) {
            tapBlock
            setsBlock
            tryButton
        }
    }

    private var tapBlock: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tap").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    ActionPickerButton(action: gesture.tap == .system ? ButtonAction.normal(for: button) : gesture.tap,
                                       button: button, purpose: .gestureTap) { gesture.tap = $0 }
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .strokeBorder(Theme.buttons, lineWidth: 1.5)
                                .shadow(color: Theme.buttons.opacity(0.6), radius: 6)
                                .opacity(flash != nil && flash?.direction == nil ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                }
                Text("A press without rolling.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
            }
    }

    private var setsBlock: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready-made sets").font(.system(size: 12, weight: .semibold))
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(ButtonGesture.suggestions) { s in
                        let on = s.matches(gesture)
                        Button {
                            withAnimation(Theme.Motion.spring) { gesture = s.applied(to: gesture) }
                            Sounds.shared.detent(pitch: 1.1, volume: 0.45, kind: .buttons)
                        } label: {
                            Label(s.title, systemImage: on ? "checkmark" : s.symbol)
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background {
                                    Capsule().fill(on ? Theme.buttons.opacity(0.16) : Theme.groupFill)
                                        .pixelBorder(Capsule(), on ? Theme.buttons.opacity(0.7) : Theme.groupBorder)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .help(String(localized: "Use the “\(s.title)” set", comment: "Tooltip on a gesture set; %@ is its name"))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
    }

    @ViewBuilder
    private var tryButton: some View {
            if !isTrying, model != nil {
                Button {
                    startTrying()
                } label: {
                    Label("Try It", systemImage: "hand.raised")
                }
                .controlSize(.small)
                .help("Practice without anything happening: the compass shows what each roll would do")
            }
    }

    private var tryBanner: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: held ? (leaning?.arrow ?? "hand.point.up.left.fill") : "hand.point.up.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.buttons)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tryLine)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                Text("Nothing really happens while you try, so roll as much as you like.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { stopTrying() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            shape.fill(Theme.buttons.opacity(0.10))
                .pixelBorder(shape, Theme.buttons.opacity(0.45))
        }
    }

    /// Talks about now: what to do, which way you're rolling, what just fired.
    private var tryLine: String {
        if let f = flash, let action = model?.action(for: f) {
            if let d = f.direction {
                return d.rollTitle + ": " + action.title   // both already localized
            }
            return String(localized: "Tap: \(action.title)", comment: "Try it: what a quick press does")
        }
        if held, let d = leaning { return d.rollTitle + "…" }
        if held { return String(localized: "Now roll the ball, or let go for the tap.") }
        return String(localized: "Hold this button on your trackball and roll.", comment: "Try it, waiting for a hold")
    }

    private func startTrying() {
        trying = true
        model?.setGesturePractice(true)
        // The engine ends it after two minutes; end it here a little before, so the two agree.
        tryEnd?.cancel()
        tryEnd = Task {
            try? await Task.sleep(for: .seconds(110))
            guard !Task.isCancelled else { return }
            stopTrying()
        }
    }

    private func stopTrying() {
        tryEnd?.cancel()
        trying = false
        model?.setGesturePractice(false)
    }
}

/// One direction: an arrow, what it does (a picker), and whether it repeats as you roll.
private struct GestureDirectionCell: View {
    let direction: GestureDirection
    @Binding var step: GestureStep?
    let lit: Bool
    let fired: Bool

    var body: some View {
        VStack(spacing: 4) {
            ActionPickerButton(action: step?.action ?? .disabled, purpose: .gestureDirection, showsKeys: false) { picked in
                if picked == .disabled {
                    step = nil
                } else if picked != step?.action {
                    step = GestureStep(picked, repeats: picked.repeatsByDefault)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.buttons.opacity(fired ? 1 : lit ? 0.75 : 0), lineWidth: 1.5)
                    .shadow(color: Theme.buttons.opacity(fired ? 0.8 : lit ? 0.4 : 0), radius: fired ? 10 : 5)
                    .allowsHitTesting(false)
            }
            .scaleEffect(fired ? 1.06 : 1)
            .animation(fired ? Theme.Motion.bounce : Theme.Motion.pressOut, value: fired)

            if let s = step, s.action.repeatsWell {
                Button {
                    step?.repeats.toggle()
                } label: {
                    Label(s.repeats ? String(localized: "Repeats as you roll", comment: "Gesture direction: fires again for each stretch of rolling")
                                    : String(localized: "Once per hold", comment: "Gesture direction: fires once"),
                          systemImage: s.repeats ? "repeat" : "1.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(s.repeats ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(radius: 6))
                .help(s.repeats ? String(localized: "Keeps going for as long as you keep rolling. Click to fire once per hold instead.")
                                : String(localized: "Fires once per hold. Click to keep going for as long as you roll."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: direction.rollTitle))
    }
}

/// The ball at the compass's center: the orb, lit toward the way it's rolling,
/// with four small arrows around it. Held, its ring takes the buttons' amber.
struct GestureBall: View {
    let leaning: GestureDirection?
    let held: Bool
    let fired: GestureDirection?
    var size: CGFloat = 74

    var body: some View {
        let lean = leaning?.unit ?? .zero
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.orbBlue.opacity(held ? 0.45 : 0.22), .clear], center: .center,
                                     startRadius: size * 0.2, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
                .allowsHitTesting(false)
            Circle()
                .fill(RadialGradient(colors: [Theme.orbCyan, Theme.orbBlue, Theme.orbViolet],
                                     center: UnitPoint(x: 0.36 + lean.dx * 0.18, y: 0.32 + lean.dy * 0.18),
                                     startRadius: 0, endRadius: size * 0.42))
                .overlay {
                    Ellipse()
                        .fill(.white.opacity(0.55))
                        .frame(width: size * 0.2, height: size * 0.12)
                        .blur(radius: 2)
                        .offset(x: -size * 0.12 + lean.dx * size * 0.08, y: -size * 0.15 + lean.dy * size * 0.08)
                }
                .overlay(Circle().strokeBorder(held ? Theme.buttons : Color.black.opacity(0.55), lineWidth: held ? 2 : 1.5))
                .shadow(color: held ? Theme.buttons.opacity(0.55) : .clear, radius: 8)
                .frame(width: size * 0.56, height: size * 0.56)
            ForEach(GestureDirection.allCases, id: \.self) { d in
                let on = leaning == d || fired == d
                Image(systemName: "chevron.\(d.rawValue)")
                    .font(.system(size: size * 0.11, weight: .heavy))
                    .foregroundStyle(on ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.tertiary))
                    .shadow(color: on ? Theme.buttons.opacity(0.8) : .clear, radius: 4)
                    .offset(x: d.unit.dx * size * 0.4, y: d.unit.dy * size * 0.4)
                    .scaleEffect(on ? 1.25 : 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - On any trackball picture

/// Laid over a trackball picture while a gesture is held: four chevrons around
/// the ball (the way you're rolling lit amber) and, for a moment after one
/// fires, what it did on a small glass label.
struct GestureHeldOverlay: View {
    let model: AppModel
    @State private var clock = GestureFlashClock()

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let modes = model.modes
            let flash = clock.current(modes)
            ZStack {
                if modes.gestureHeld {
                    ForEach(GestureDirection.allCases, id: \.self) { d in
                        let on = modes.gestureDirection == d || flash?.direction == d
                        Image(systemName: "chevron.\(d.rawValue)")
                            .font(.system(size: s * 0.085, weight: .heavy))
                            .foregroundStyle(on ? Theme.buttons : Color.white.opacity(0.45))
                            .shadow(color: on ? Theme.buttons : .black.opacity(0.4), radius: on ? 6 : 2)
                            .scaleEffect(on ? 1.3 : 1)
                            .offset(x: d.unit.dx * s * 0.455, y: d.unit.dy * s * 0.455)
                    }
                    .transition(.opacity)
                }
                if let flash, let action = model.action(for: flash) {
                    HStack(spacing: 4) {
                        Image(systemName: flash.direction?.arrow ?? "hand.tap")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(verbatim: action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.buttons.opacity(0.85)))
                    .shadow(color: Theme.buttons.opacity(0.6), radius: 6)
                    .frame(maxWidth: g.size.width * 1.2)
                    .offset(y: s * 0.56)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(flash.seq)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .animation(Theme.Motion.pressIn, value: modes.gestureDirection)
            .animation(Theme.Motion.fade, value: modes.gestureHeld)
            .animation(Theme.Motion.spring, value: flash?.seq)
        }
        .allowsHitTesting(false)
        .onChange(of: model.modes.gestureFlash) { _, f in clock.show(f) }
        .accessibilityHidden(true)
    }
}

/// On the Buttons page's map: a small four-way mark on each gesture pad.
struct GesturePadMark: View {
    var size: CGFloat = 18
    var lit = false

    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: size * 0.6, weight: .bold))
            .foregroundStyle(lit ? Color.black.opacity(0.75) : Theme.buttons)
            .frame(width: size, height: size)
            .background(Circle().fill(lit ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(Color.black.opacity(0.55))))
            .overlay(Circle().strokeBorder(Theme.buttons.opacity(0.7), lineWidth: 1))
            .shadow(color: Theme.buttons.opacity(lit ? 0.7 : 0.3), radius: 4)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}
