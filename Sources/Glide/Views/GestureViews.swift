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

/// Under a gesture button's (or combo's) row: what each way does, the tap, sets,
/// distance, and Try it.
struct GestureEditor: View {
    let model: AppModel?
    /// The button, or the combo's buttons (sorted).
    let buttons: [Int]
    @Binding var gesture: ButtonGesture

    @State private var trying = false
    @State private var clock = GestureFlashClock()
    @State private var tryEnd: Task<Void, Never>?
    /// What this hold has fired so far, in order (Try it shows it as a trail).
    @State private var trail: [Engine.GestureFlash] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Renders: draw it in its "Try it" state, with this trail.
    nonisolated(unsafe) static var sandboxTrying = false
    nonisolated(unsafe) static var sandboxTrail: [Engine.GestureFlash]?

    init(model: AppModel?, button: Int, gesture: Binding<ButtonGesture>) {
        self.init(model: model, buttons: [button], gesture: gesture)
    }

    init(model: AppModel?, buttons: [Int], gesture: Binding<ButtonGesture>) {
        self.model = model
        self.buttons = buttons.sorted()
        _gesture = gesture
    }

    private var isCombo: Bool { buttons.count > 1 }
    private var modes: Engine.Modes { model?.modes ?? Engine.Modes() }
    private var held: Bool { modes.gestureHeld && modes.gestureButtons == buttons }
    private var leaning: GestureDirection? { held ? modes.gestureDirection : nil }
    private var flash: Engine.GestureFlash? {
        guard let f = clock.current(modes), f.buttons == buttons else { return nil }
        return f
    }
    private var isTrying: Bool { trying || Self.sandboxTrying }
    private var shownTrail: [Engine.GestureFlash] { (Self.sandboxTrail ?? trail).filter { $0.buttons == buttons } }

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
                        VStack(alignment: .leading, spacing: 12) { tapBlock; distanceBlock }
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
            guard let f, f.buttons == buttons else { return }
            clock.show(f)
            // A new hold starts a new trail; a chain adds to it (the last eight).
            if f.direction == nil || f.chain <= 1 { trail = [f] } else { trail = Array((trail + [f]).suffix(8)) }
        }
        .onDisappear { if trying { stopTrying() } }
    }

    private var explanation: String {
        isCombo
            ? String(localized: "Hold these buttons together and roll the ball. Each way does something the moment you roll a few millimeters, as many times as you like in one hold; a quick press does the tap.",
                     comment: "Gesture editor, under a combo's row")
            : String(localized: "Hold this button and roll the ball. Each way does something the moment you roll a few millimeters, as many times as you like in one hold; a quick press does the tap.",
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
            fired: flash != nil && flash?.direction == d,
            fireSeq: flash?.direction == d ? flash?.seq ?? 0 : 0)
    }

    // MARK: Tap, sets, distance, Try it

    private var side: some View {
        VStack(alignment: .leading, spacing: 14) {
            tapBlock
            setsBlock
            distanceBlock
            tryButton
        }
    }

    /// What the tap does as shown: a button's own click by name; a combo has none.
    private var tapShown: ButtonAction {
        guard gesture.tap == .system else { return gesture.tap }
        return isCombo ? .disabled : ButtonAction.normal(for: buttons[0])
    }

    private var tapBlock: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tap").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    ActionPickerButton(action: tapShown, button: isCombo ? nil : buttons[0], purpose: .gestureTap) { gesture.tap = $0 }
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

    /// This gesture's own distance, or the one all gestures use (the Gestures settings below the buttons).
    private var distanceBlock: some View {
        let general = model?.config.gestureDistance ?? .normal
        return HStack(spacing: 6) {
            Text("Distance").font(.system(size: 12, weight: .semibold))
            Menu {
                Picker(selection: Binding(get: { gesture.distance }, set: { gesture.distance = $0 })) {
                    Text(String(localized: "Like Other Gestures (\(general.title))", comment: "Gesture distance menu: follow the setting for all gestures; %@ is that setting (Short, Normal, Long)"))
                        .tag(GestureDistance?.none)
                    Divider()
                    ForEach(GestureDistance.allCases) { d in
                        Text(verbatim: d.title).tag(GestureDistance?.some(d))
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: gesture.distance?.title ?? String(localized: "Like Other Gestures", comment: "Gesture distance: follows the setting for all gestures"))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("How far you roll before a direction fires. Short suits small, quick rolls; Long ignores more by accident.")
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
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
            if !shownTrail.isEmpty { trailView }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            shape.fill(Theme.buttons.opacity(0.10))
                .pixelBorder(shape, Theme.buttons.opacity(0.45))
        }
    }

    /// What this hold fired, in order: a chip per command, the newest lit.
    private var trailView: some View {
        let items = shownTrail
        return FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.seq) { i, f in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(height: 20)
                }
                let newest = i == items.count - 1
                HStack(spacing: 4) {
                    Image(systemName: f.direction?.arrow ?? "hand.tap")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(verbatim: (f.direction == nil ? model.flatMap { $0.action(for: f) }?.title
                                                       : gesture[f.direction!]?.action.title) ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(newest ? AnyShapeStyle(Color.black.opacity(0.78)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(newest ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(Theme.groupFill))
                        .pixelBorder(Capsule(), newest ? .clear : Theme.groupBorder)
                }
                .shadow(color: newest ? Theme.buttons.opacity(0.5) : .clear, radius: 5)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.bounce, value: items.last?.seq)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("What fired in this hold", comment: "Try it: the chain of commands one hold fired"))
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
        return isCombo
            ? String(localized: "Hold these buttons together on your trackball and roll.", comment: "Try it, waiting for a combo's hold")
            : String(localized: "Hold this button on your trackball and roll.", comment: "Try it, waiting for a hold")
    }

    private func startTrying() {
        trying = true
        trail = []
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
        trail = []
        model?.setGesturePractice(false)
    }
}

extension GestureStep.Mode {
    var title: String {
        switch self {
        case .chain: String(localized: "Each time you roll", comment: "Gesture direction: fires every time you roll that way, many times in one hold")
        case .continuous: String(localized: "Repeats as you roll", comment: "Gesture direction: fires again for each stretch of rolling")
        case .once: String(localized: "Once per hold", comment: "Gesture direction: fires once")
        }
    }

    var symbol: String {
        switch self {
        case .chain: "link"
        case .continuous: "repeat"
        case .once: "1.circle"
        }
    }

    var help: String {
        switch self {
        case .chain: String(localized: "Fires each time you roll this way, even several times in one hold, mixed with the other directions.")
        case .continuous: String(localized: "Keeps going for as long as you keep rolling.")
        case .once: String(localized: "Fires once per hold, however far you roll.")
        }
    }
}

/// One direction: an arrow, what it does (a picker), and how it fires.
private struct GestureDirectionCell: View {
    let direction: GestureDirection
    @Binding var step: GestureStep?
    let lit: Bool
    let fired: Bool
    /// Changes with every fire of this direction, so each one in a chain flashes.
    let fireSeq: Int

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
            .keyframeAnimator(initialValue: 1.0, trigger: fireSeq) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.08, duration: 0.1)
                SpringKeyframe(1.0, duration: 0.3)
            }

            if let s = step {
                let modes: [GestureStep.Mode] = s.action.repeatsWell ? [.chain, .continuous, .once] : [.chain, .once]
                Menu {
                    Picker(selection: Binding(get: { s.mode }, set: { step?.mode = $0 })) {
                        ForEach(modes, id: \.self) { m in
                            Label(m.title, systemImage: m.symbol).tag(m)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                } label: {
                    Label(s.mode.title, systemImage: s.mode.symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(s.mode == .once ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.buttons))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(s.mode.help)
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

/// Laid over a trackball picture while a gesture is held: a soft amber ring
/// around the ball (armed: the pointer is held still and the ball is the
/// gesture's), four chevrons (the way you're rolling lit amber) and, for a moment
/// after one fires, what it did on a small label.
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
                    GestureArmedRing(size: s, pulse: flash?.seq ?? 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
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

/// The "armed" ring: soft amber light around the ball while a gesture is held,
/// brightening for a beat each time a direction fires.
struct GestureArmedRing: View {
    let size: CGFloat
    /// Changes with every fire.
    var pulse: Int = 0

    var body: some View {
        Circle()
            .strokeBorder(
                AngularGradient(colors: [Theme.buttons.opacity(0.9), Theme.buttons.opacity(0.35), Theme.buttons.opacity(0.9),
                                         Theme.buttons.opacity(0.35), Theme.buttons.opacity(0.9)], center: .center),
                lineWidth: max(1.5, size * 0.012))
            .shadow(color: Theme.buttons.opacity(0.7), radius: size * 0.05)
            .shadow(color: Theme.buttons.opacity(0.35), radius: size * 0.12)
            .frame(width: size * 0.86, height: size * 0.86)   // just outside the scroll ring, inside the pads
            .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, glow in
                content.brightness((glow - 1) * 2).scaleEffect(glow)
            } keyframes: { _ in
                SpringKeyframe(1.035, duration: 0.08)
                SpringKeyframe(1.0, duration: 0.35)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Around the page while a gesture is held: a soft amber edge, so it's clear at a
/// glance why the pointer stands still.
struct GestureArmedEdge: View {
    let model: AppModel

    var body: some View {
        let held = model.modes.gestureHeld
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.buttons.opacity(0.55), lineWidth: 1.5)
            .shadow(color: Theme.buttons.opacity(0.6), radius: 10)
            .blur(radius: 0.5)
            .padding(3)
            .opacity(held ? 1 : 0)
            .animation(held ? Theme.Motion.pressIn : Theme.Motion.fade, value: held)
            .allowsHitTesting(false)
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
