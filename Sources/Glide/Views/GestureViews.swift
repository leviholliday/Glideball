import SwiftUI

// Gesture buttons on the Buttons page: the editor under a gesture button's row
// (the ring as it shows on screen, to click; the tap in its middle; sets to start
// from and "Try it"), and the overlay that shows a held gesture on any trackball picture.
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
        case .upRight: "arrow.up.right"
        case .downRight: "arrow.down.right"
        case .downLeft: "arrow.down.left"
        case .upLeft: "arrow.up.left"
        }
    }

    var unit: CGVector {
        let v = vector
        return CGVector(dx: v.x, dy: v.y)
    }

    /// "Roll up", for VoiceOver and the live line (a diagonal is named by its place).
    var rollTitle: String {
        switch self {
        case .up: String(localized: "Roll up", comment: "Gesture direction: roll the ball away from you")
        case .down: String(localized: "Roll down", comment: "Gesture direction: roll the ball toward you")
        case .left: String(localized: "Roll left", comment: "Gesture direction")
        case .right: String(localized: "Roll right", comment: "Gesture direction")
        default: placeTitle
        }
    }

    /// "Up", "Up right"…, for VoiceOver and a More's heading.
    var placeTitle: String {
        switch self {
        case .up: String(localized: "Up", comment: "Wheel slot, straight up")
        case .upRight: String(localized: "Up right", comment: "Wheel slot")
        case .right: String(localized: "Right", comment: "Wheel slot")
        case .downRight: String(localized: "Down right", comment: "Wheel slot")
        case .down: String(localized: "Down", comment: "Wheel slot")
        case .downLeft: String(localized: "Down left", comment: "Wheel slot")
        case .left: String(localized: "Left", comment: "Wheel slot")
        case .upLeft: String(localized: "Up left", comment: "Wheel slot")
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

extension GestureStep {
    /// The More chip's symbol, in the editor, the picker and the ring.
    static let moreSymbol = "ellipsis.circle"
}

/// Under a Gestures button's (or combo's) row. In the order you think in: start from a set;
/// the ring, drawn as it shows on screen (the overlay's own views), where you click a place to
/// choose what it does, the tap in the middle and 4 | 8 beside it; then three plain rows: when
/// the ring shows, what the scroll ring does while you hold, and the distance. A More opens its
/// ring in the same place, as it does on screen. Try it lights this ring as you roll.
/// (One layout, on purpose: an earlier editor offered ViewThatFits several whole rings and
/// render-ui ran SwiftUI's graph out of room.)
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
    /// The More being edited (its place), or nil for the first ring.
    @State private var editing: Int?
    /// Where the light is around the ring (degrees, unwrapped, so it glides the short way round).
    @State private var orbit: Double?
    /// A More with actions in it is about to become this instead: asked once.
    @State private var replacing: MoreReplacement?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Renders: draw it in its "Try it" state, with this trail, or with this More open.
    nonisolated(unsafe) static var sandboxTrying = false
    nonisolated(unsafe) static var sandboxTrail: [Engine.GestureFlash]?
    nonisolated(unsafe) static var sandboxEditing: Int?

    struct MoreReplacement: Identifiable {
        let place: Int
        /// What it becomes (nil: nothing).
        let step: GestureStep?
        var id: Int { place }
    }

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
    private var mine: Bool { modes.gestureButtons == buttons }
    private var held: Bool { (modes.gestureHeld || modes.wheelHeld) && mine }
    private var leaning: GestureDirection? { modes.gestureHeld && mine ? modes.gestureDirection : nil }
    private var flash: Engine.GestureFlash? {
        guard let f = clock.current(modes), f.buttons == buttons else { return nil }
        return f
    }
    private var isTrying: Bool { trying || Self.sandboxTrying }
    private var shownTrail: [Engine.GestureFlash] { (Self.sandboxTrail ?? trail).filter { $0.buttons == buttons } }
    /// The More shown: only one that's still More (it may have been changed meanwhile).
    private var level: Int? {
        guard let p = Self.sandboxEditing ?? editing, gesture[GestureDirection(place: p)]?.isMore == true else { return nil }
        return p
    }
    /// The place lit on the ring shown here: the ring's lit place, the way a blind hold leans, or
    /// (for a moment) the way that just fired.
    private var lit: Int? {
        if held {
            if modes.wheelHeld { return modes.wheelLevel == level ? modes.wheelSlot : nil }
            if level == nil, let l = leaning { return l.place }
        }
        return level == nil ? flash?.direction?.place : nil
    }
    private var firstLayout: WheelLayout { gesture.eight ? .eight : .four }
    private var subLayout: WheelLayout { gesture.eight ? .subEight : .subFour }
    private var used: [Int] { gesture.eight ? Array(0..<8) : [0, 2, 4, 6] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: explanation)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if let level { moreHeader(level) } else { startFrom }
                ringBlock
                if isTrying { tryBanner.transition(.opacity.combined(with: .move(edge: .bottom))) }
            }
            .padding(.bottom, 12)
            row { showRow }
            row { scrollRingRow }
            row { distanceRow }
        }
        .padding(.leading, ButtonRow.dividerInset - Theme.Space.rowHorizontal)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.spring), value: isTrying)
        .animation(Theme.Motion.respecting(reduceMotion, WheelMotion.chipsIn), value: gesture.eight)
        .animation(Theme.Motion.respecting(reduceMotion, WheelMotion.open), value: level)
        .animation(Theme.Motion.fade, value: gesture.show)
        .animation(Theme.Motion.fade, value: gesture.ring)
        .onChange(of: modes.gestureFlash) { _, f in
            guard let f, f.buttons == buttons else { return }
            clock.show(f)
            // A new hold starts a new trail; a chain adds to it (the last eight).
            if f.direction == nil || f.chain <= 1 { trail = [f] } else { trail = Array((trail + [f]).suffix(8)) }
        }
        .onChange(of: lit) { old, new in
            // The light glides the short way round from where it was; a new light just appears.
            guard let new else { return orbit = nil }
            let target = Double(new) * 45
            if old != nil, let o = orbit { orbit = o + WheelOverlayState.shortWay(from: o, to: target) } else { orbit = target }
        }
        .onDisappear { if trying { stopTrying() } }
        .confirmationDialog(Text("Remove everything in More?", comment: "Gestures editor: asked once before a More that still has actions in it becomes an ordinary action"),
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            presenting: replacing) { r in
            Button("Remove", role: .destructive) {
                gesture[GestureDirection(place: r.place)] = r.step
                editing = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var explanation: String {
        if level != nil {
            return String(localized: "More opens this ring. Roll back through the middle to go back; letting go in the middle cancels.",
                          comment: "Gestures editor, while a More's ring is being edited")
        }
        return isCombo
            ? String(localized: "Hold these buttons together and roll toward an action. A quick press does the tap.",
                     comment: "Gestures editor, under a combo's row")
            : String(localized: "Hold the button and roll toward an action. A quick press does the tap.",
                     comment: "Gestures editor, under a Gestures button's row")
    }

    /// One of the plain rows under the ring, with a hairline above it (the same group, not a box).
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content()
                .padding(.vertical, 10)
        }
    }

    // MARK: Start from

    private var startFrom: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Start from", comment: "Gestures editor: before the ready-made sets of directions (Spaces, Volume and music…)")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(ButtonGesture.suggestions) { s in
                    let on = s.matches(gesture)
                    Button {
                        withAnimation(Theme.Motion.respecting(reduceMotion, WheelMotion.chipsIn)) { gesture = s.applied(to: gesture) }
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

    // MARK: The ring

    /// Above a More's ring: the way back, and the More's own picker (choose anything else there and
    /// this way is an ordinary action again).
    private func moreHeader(_ level: Int) -> some View {
        let d = GestureDirection(place: level)
        let inside = gesture[d]?.more?.compactMap { $0 }.count ?? 0
        return HStack(spacing: 8) {
            Button {
                withAnimation(Theme.Motion.respecting(reduceMotion, WheelMotion.open)) { editing = nil }
            } label: {
                Image(systemName: "chevron.backward").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(ActionButtonStyle())
            .help("Back to the first ring")
            .accessibilityLabel(Text("Back", comment: "Gestures: in a More's ring, the way back to the first ring"))
            Text(verbatim: d.placeTitle + ":")
                .font(.system(size: 12, weight: .semibold))
            GesturePickerMenu(current: nil, purpose: .gestureDirection) { picked in
                let step: GestureStep? = picked == .disabled ? nil : GestureStep(picked, repeats: picked.repeatsByDefault)
                if inside > 0 {
                    replacing = MoreReplacement(place: level, step: step)
                } else {
                    gesture[d] = step
                    editing = nil
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: GestureStep.moreSymbol).font(.system(size: 11.5, weight: .semibold))
                    Text("More", comment: "Gestures: a direction that opens a second ring of actions")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.lightInk)   // a More's color on the ring
                .fixedSize()
            }
            .help("Choose what this does")
        }
    }

    /// The ring as it shows on screen, with 4 | 8 beside it and Try it under it.
    private var ringBlock: some View {
        let side = firstLayout.outer * 2
        return ZStack {
            ring.frame(width: side, height: side)
        }
        .frame(maxWidth: side + 250)
        .frame(height: side + 20)
        .overlay(alignment: .topTrailing) { if level == nil { countPicker } }
        .overlay(alignment: .bottomTrailing) { tryButton }
        .frame(maxWidth: .infinity)
    }

    private var ring: some View {
        ZStack {
            // Behind a More's ring the first one steps back, as on screen (no glass: it's an echo).
            ringView(layout: firstLayout, level: nil, active: level == nil)
                .scaleEffect(level != nil && !reduceMotion ? 1.16 : 1)
                .opacity(level != nil ? 0.2 : 1)
                .blur(radius: level != nil && !reduceMotion ? 2 : 0)
                .allowsHitTesting(level == nil)
                .accessibilityHidden(level != nil)
            if let level {
                ringView(layout: subLayout, level: level, active: true)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.12, anchor: growAnchor(level)).combined(with: .opacity))
            }
            hub
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(level == nil ? Text("Gestures ring", comment: "Gestures editor: VoiceOver name of the directions around the ball")
                                         : Text("More ring", comment: "Gestures editor: VoiceOver name of a More's ring"))
    }

    /// Where, in the ring's square, the More chip a More's ring grows out of sits.
    private func growAnchor(_ level: Int) -> UnitPoint {
        let o = firstLayout.offset(level)
        let side = firstLayout.outer * 2
        return UnitPoint(x: 0.5 + o.width / side, y: 0.5 + o.height / side)
    }

    /// One ring (the first, or a More's): the band, the light and the beam on the lit place, and
    /// a chip to click for each place.
    private func ringView(layout: WheelLayout, level: Int?, active: Bool) -> some View {
        let track = WheelTrack(inner: layout.inner, outer: layout.outer)
        let hidden = gesture.show == .never && level == nil
        let lit = active ? self.lit : nil
        let angle = orbit ?? Double(lit ?? 0) * 45
        let pulse = flash?.seq ?? 0
        return ZStack {
            if let lit {
                WheelBeam(inner: 30, outer: layout.radius, spread: gesture.eight ? 34 : 46)
                    .frame(width: layout.outer * 2, height: layout.outer * 2)
                    .opacity(0.9)
                    .rotationEffect(.degrees(reduceMotion ? Double(lit) * 45 : angle))
                    .transition(.opacity)
            }
            if active {
                // Never shown on screen: the band is drawn fainter and without its lit edge, so
                // it reads as "hidden" while the chips stay easy to read.
                track
                    .fill(Theme.groupFill)
                    .glassEffect(.regular, in: track)
                    .overlay { track.stroke(Color.white.opacity(hidden ? 0 : scheme == .dark ? 0.16 : 0.6), lineWidth: 0.5) }
                    .shadow(color: Theme.surfaceShadow.opacity(hidden ? 0 : 1), radius: 10, y: 3)
                    .opacity(hidden ? 0.45 : 1)
            } else {
                track.fill(Theme.groupFill)
            }
            if let lit {
                WheelLight(size: layout.chip, pulse: pulse)
                    .modifier(RingOrbit(angle: reduceMotion ? Double(lit) * 45 : angle, radius: layout.radius))
                    .transition(.opacity)
            }
            ForEach(used, id: \.self) { place in
                chip(place, level: level, layout: layout, lit: lit == place, pulse: pulse)
                    .offset(layout.offset(place))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: layout.outer * 2, height: layout.outer * 2)
        .animation(reduceMotion ? WheelMotion.fade : WheelMotion.light, value: orbit)
        .animation(WheelMotion.fade, value: lit != nil)
    }

    @ViewBuilder
    private func chip(_ place: Int, level: Int?, layout: WheelLayout, lit: Bool, pulse: Int) -> some View {
        let d = GestureDirection(place: place)
        if let level {
            if place == (level + 4) % 8 {
                // Opposite the More: the way back to the first ring (nothing to set).
                WheelChip(slot: .back, lit: lit, size: layout.chip, pulse: pulse)
                    .help("Rolling this way goes back to the first ring")
                    .accessibilityElement(children: .combine)
            } else {
                GestureChipButton(
                    direction: d, size: layout.chip, lit: lit, pulse: pulse, ringOnly: true,
                    step: Binding(get: { gesture[GestureDirection(place: level)]?.more?[place] },
                                  set: { new in
                                      guard var sub = gesture[GestureDirection(place: level)]?.more else { return }
                                      sub = GestureStep.normalizedMore(sub)
                                      sub[place] = new
                                      gesture[GestureDirection(place: level)] = .moreRing(sub)
                                  }),
                    moreDots: nil, onMore: nil, openMore: nil)
            }
        } else {
            let sub = gesture[d]?.more
            GestureChipButton(
                direction: d, size: layout.chip, lit: lit, pulse: pulse, ringOnly: gesture.show == .atOnce,
                step: Binding(get: { gesture[d] }, set: { gesture[d] = $0 }),
                // A More's dots: one per place of its ring (not its way back), the filled ones bright.
                moreDots: sub.map { s in (0..<8).map { p in used.contains(p) ? (p != (place + 4) % 8 && s.indices.contains(p) && s[p] != nil) : nil } },
                onMore: {
                    if gesture[d]?.isMore != true { gesture[d] = .moreRing() }
                    withAnimation(Theme.Motion.respecting(reduceMotion, WheelMotion.open)) { editing = place }
                },
                openMore: { withAnimation(Theme.Motion.respecting(reduceMotion, WheelMotion.open)) { editing = place } })
        }
    }

    /// What the tap does as shown: a button's own click by name; a combo has none.
    private var tapShown: ButtonAction {
        guard gesture.tap == .system else { return gesture.tap }
        return isCombo ? .disabled : ButtonAction.normal(for: buttons[0])
    }

    /// The middle. On the first ring it's the tap (a press without rolling): the ball, and what
    /// the tap does, to click. In a More's ring it's the way back to the first ring.
    @ViewBuilder
    private var hub: some View {
        let layout = level == nil ? firstLayout : subLayout
        // Inside the band, and clear of the chips beside it (four's chips are wide).
        let room = min(layout.inner * 2 - 14, (layout.radius - layout.chip.width / 2) * 2 - 6)
        if level != nil {
            Button {
                withAnimation(Theme.Motion.respecting(reduceMotion, WheelMotion.open)) { editing = nil }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "chevron.backward").font(.system(size: 15, weight: .semibold))
                    Text("Back", comment: "Gestures: in a More's ring, the way back to the first ring")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(width: room, height: room)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Back to the first ring")
        } else {
            let tapped = flash != nil && flash?.direction == nil
            GesturePickerMenu(current: tapShown, button: isCombo ? nil : buttons[0], purpose: .gestureTap) { gesture.tap = $0 } label: {
                VStack(spacing: 2) {
                    GestureBall(leaning: leaning, held: held || tapped, fired: flash?.direction, size: gesture.eight ? 66 : 46, arrows: false)
                    Text(String(localized: "Tap: \(tapShown.title)"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tapped ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: room - 8)
                }
                .frame(width: room, height: room)
                .contentShape(Circle())
            }
            .help("Choose what this does")
        }
    }

    /// Four or eight, beside the ring it changes.
    private var countPicker: some View {
        Picker(selection: $gesture.eight) {
            Text("4").tag(false)
            Text("8").tag(true)
        } label: { EmptyView() }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Four slots are the easiest to hit; eight adds the diagonals.")
        .accessibilityLabel(Text("Directions", comment: "Gestures editor: four or eight directions"))
    }

    // MARK: Show the ring, the scroll ring, distance

    private var showRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Text("Show the ring", comment: "Gestures editor: when the ring of actions shows around the pointer")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 150, minHeight: 22, alignment: .leading)
                Picker(selection: $gesture.show) {
                    ForEach(RingShow.allCases) { s in Text(verbatim: s.title).tag(s) }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(verbatim: showHint)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }

    /// Talks about now: what holding the button does with this choice.
    private var showHint: String {
        switch gesture.show {
        case .never: String(localized: "Nothing shows. Roll and it happens, as often as you like in one hold.",
                            comment: "Gestures editor: Show the ring hint, Never")
        case .afterPause: String(localized: "Roll quickly and it happens; wait a moment and the ring shows.",
                                 comment: "Gestures editor: Show the ring hint, After a pause")
        case .atOnce: String(localized: "The ring shows as you press. Let go on an action to run it.",
                             comment: "Gestures editor: Show the ring hint, Right away")
        }
    }

    /// The hardware's scroll ring (in its pink, so it isn't taken for the ring above).
    private var scrollRingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Label {
                    Text("Scroll ring").font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: "circle.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ring)
                }
                .frame(minWidth: 150, minHeight: 22, alignment: .leading)
                HStack(spacing: 12) {
                    Menu {
                        Picker(selection: $gesture.ring) {
                            ForEach(RingJob.allCases) { job in
                                Label(job.title, systemImage: job.symbol).tag(job)
                            }
                        } label: { EmptyView() }
                        .pickerStyle(.inline)
                    } label: {
                        Label(gesture.ring.title, systemImage: gesture.ring.symbol)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .tint(Theme.ring)
                    if gesture.ring != .scroll && gesture.ring != .off {
                        Toggle(isOn: $gesture.reverse) {
                            Text("Reverse", comment: "Gestures editor: turn the ring job the other way round")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.checkbox)
                        .tint(Theme.ring)
                        .help("Swap which way of turning the ring does what")
                    }
                }
                .frame(minHeight: 22)
            }
            if gesture.ring == .custom {
                ringWay("arrow.counterclockwise", help: Text("Turning the ring counterclockwise"), action: gesture.ringDown) { gesture.ringDown = $0 }
                ringWay("arrow.clockwise", help: Text("Turning the ring clockwise"), action: gesture.ringUp) { gesture.ringUp = $0 }
            }
            Text(verbatim: ringHint)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }

    /// One way of your own pair: the arrow and its action.
    private func ringWay(_ arrow: String, help: Text, action: ButtonAction?, set: @escaping (ButtonAction?) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: arrow).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ring)
                .frame(width: 16)
                .help(help)
            ActionPickerButton(action: action ?? .disabled, purpose: .wheelSlot, showsKeys: false) {
                set($0 == .disabled ? nil : $0)
            }
        }
        .padding(.leading, 162)
    }

    /// Talks about now: what turning the ring does with this job.
    private var ringHint: String {
        switch gesture.ring {
        case .volume: String(localized: "Turn it while you hold the button to change the volume. It won’t scroll meanwhile.", comment: "Gestures editor: scroll ring hint")
        case .brightness: String(localized: "Turn it while you hold the button to change the screen’s brightness.", comment: "Gestures editor: scroll ring hint")
        case .zoom: String(localized: "Turn it while you hold the button to zoom in and out (⌘+ and ⌘−).", comment: "Gestures editor: scroll ring hint")
        case .undo: String(localized: "Turn it back to undo, forward to redo.", comment: "Gestures editor: scroll ring hint")
        case .tabs: String(localized: "Turn it while you hold the button to move between tabs.", comment: "Gestures editor: scroll ring hint")
        case .custom: String(localized: "One action for each way you turn the ring, a step per click.", comment: "Wheel editor: ring job hint")
        case .scroll: String(localized: "It scrolls as usual while you hold the button.", comment: "Gestures editor: scroll ring hint, Scrolls as usual")
        case .off: String(localized: "It does nothing while you hold the button.", comment: "Gestures editor: scroll ring hint")
        }
    }

    /// This gesture's own distance, or the one all gestures use (the Gestures settings below the buttons).
    private var distanceRow: some View {
        let general = model?.config.gestureDistance ?? .normal
        return FlowLayout(spacing: 12, lineSpacing: 6) {
            Text("Distance").font(.system(size: 13, weight: .medium))
                .frame(minWidth: 150, minHeight: 22, alignment: .leading)
            Menu {
                Picker(selection: Binding(get: { gesture.distance }, set: { gesture.distance = $0 })) {
                    Text(String(localized: "Like other gestures (\(general.title))", comment: "Gesture distance menu: follow the setting for all gestures; %@ is that setting (Short, Normal, Long)"))
                        .tag(GestureDistance?.none)
                    Divider()
                    ForEach(GestureDistance.allCases) { d in
                        Text(verbatim: d.title).tag(GestureDistance?.some(d))
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: gesture.distance?.title ?? String(localized: "Like other gestures (\(general.title))", comment: "Gesture distance menu: follow the setting for all gestures; %@ is that setting (Short, Normal, Long)"))
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .frame(minHeight: 22)
            .help("How far you roll before a direction fires. Short suits small, quick rolls; Long ignores more by accident.")
        }
    }

    // MARK: Try it

    @ViewBuilder
    private var tryButton: some View {
        if !isTrying, model != nil {
            Button {
                startTrying()
            } label: {
                Label("Try it", systemImage: "hand.raised")
            }
            .controlSize(.small)
            .help("Hold the button and roll. Nothing really runs.")
        }
    }

    /// While trying: one line that talks about now, and the trail of what this hold fired. The
    /// ring above is the preview: its light follows the roll.
    private var tryBanner: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: held ? (leaning?.arrow ?? "hand.point.up.left.fill") : "hand.point.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.buttons)
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: tryLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { stopTrying() }
                    .controlSize(.small)
            }
            if !shownTrail.isEmpty { trailView }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        return String(localized: "Hold the button and roll. Nothing really runs.", comment: "Gestures editor, Try it: what to do, and that it's only practice")
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

/// Something to click that opens the action picker: the editor's chips and hub draw themselves,
/// so this is `ActionPickerButton` with the label left to the caller.
private struct GesturePickerMenu<Label: View>: View {
    let current: ButtonAction?
    var button: Int? = nil
    var purpose: ActionPickerPanel.Purpose
    var onMore: (() -> Void)? = nil
    let pick: (ButtonAction) -> Void
    @ViewBuilder let label: () -> Label

    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            label()
        }
        .buttonStyle(PressableStyle())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ActionPickerPanel(current: current, button: button, purpose: purpose, onMore: onMore) { pick($0) }
        }
    }
}

extension GestureStep.Mode {
    var title: String {
        switch self {
        case .chain: String(localized: "Each roll", comment: "Gesture direction: fires every time you roll that way, many times in one hold")
        case .continuous: String(localized: "Keeps going", comment: "Gesture direction: fires again and again for as long as you keep rolling")
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

    // On a ring that shows (Right away, or inside a More) a place that doesn't repeat runs
    // once, when you let go on it: chaining is a blind thing, so it isn't "each roll".
    func title(onRing: Bool) -> String {
        onRing && self == .chain
            ? String(localized: "When you let go", comment: "Gestures, on a ring that shows: this place runs once, when you let go on it")
            : title
    }

    func symbol(onRing: Bool) -> String { onRing && self == .chain ? "1.circle" : symbol }

    func help(onRing: Bool) -> String {
        onRing && self == .chain
            ? String(localized: "Runs once, when you let go with this place lit.", comment: "Gestures, on a ring that shows: help for “When you let go”")
            : help
    }
}

/// One place on the editor's ring: the chip the overlay draws, to click. It opens the action
/// picker (or, for a More, its ring). How it runs is a small badge on its corner: there when
/// it repeats or runs once per hold, or while the pointer is over the chip.
private struct GestureChipButton: View {
    let direction: GestureDirection
    let size: CGSize
    let lit: Bool
    /// Changes with every fire, so the lit chip pulses.
    let pulse: Int
    /// Only ever picked on a showing ring (Right away, or inside a More): it runs once at the
    /// release either way, so only "Keeps going" is a choice worth showing.
    var ringOnly = false
    @Binding var step: GestureStep?
    /// A More's places, clockwise from up: filled or not (nil inside: not in use; nil: not a More).
    let moreDots: [Bool?]?
    /// The first ring: More can be chosen here (it makes it and opens it), and opened.
    let onMore: (() -> Void)?
    let openMore: (() -> Void)?

    @State private var open = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isMore: Bool { step?.isMore == true }
    private var slot: WheelOverlayModel.Slot? {
        guard let step else { return nil }
        if step.isMore { return .more }
        return step.action == .disabled ? nil : .action(step.action)
    }
    /// The ways this place can run, when there's a choice to make.
    private var modes: [GestureStep.Mode] {
        guard let s = step, !s.isMore, !(ringOnly && !s.action.repeatsWell) else { return [] }
        return ringOnly ? [.chain, .continuous] : s.action.repeatsWell ? [.chain, .continuous, .once] : [.chain, .once]
    }

    private var spoken: String {
        guard let step else { return direction.rollTitle + ": " + ButtonAction.disabled.title }
        if step.isMore {
            return direction.rollTitle + ": " + String(localized: "More, opens its ring", comment: "Gestures editor, VoiceOver: a direction that is More")
        }
        let how = modes.isEmpty ? "" : ", " + step.mode.title(onRing: ringOnly)
        return direction.rollTitle + ": " + step.action.title + how
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(size.height / 2.4, 22), style: .continuous)
        Button {
            if isMore, let openMore { openMore() } else { open = true }
        } label: {
            WheelChip(slot: slot, lit: lit, size: size, pulse: pulse, emptySymbol: "plus", moreDots: moreDots)
                .background {
                    shape.fill(hovering && !lit ? Theme.hoverFill : .clear)
                        .pixelBorder(shape, hovering && !lit ? Theme.light.opacity(0.45) : .clear)
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ActionPickerPanel(current: step?.action ?? .disabled, purpose: .gestureDirection, onMore: onMore) { picked in
                if picked == .disabled {
                    step = nil
                } else if picked != step?.action {
                    step = GestureStep(picked, repeats: picked.repeatsByDefault)
                }
            }
        }
        .overlay(alignment: .topTrailing) { badge }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isMore ? Text("Open this ring to choose what’s in it") : Text("Choose what this does"))
        .accessibilityLabel(Text(verbatim: spoken))
        .contextMenu { if !modes.isEmpty { modePicker } }
    }

    private var modePicker: some View {
        Picker(selection: Binding(get: { step?.mode ?? .chain }, set: { step?.mode = $0 })) {
            ForEach(modes, id: \.self) { m in
                Label(m.title(onRing: ringOnly), systemImage: m.symbol(onRing: ringOnly)).tag(m)
            }
        } label: { EmptyView() }
        .pickerStyle(.inline)
    }

    /// How this place runs: amber when it repeats, quiet for once per hold; a plain place shows
    /// it only under the pointer. It's the menu that changes it.
    @ViewBuilder
    private var badge: some View {
        if let s = step, !modes.isEmpty, s.mode != .chain || hovering {
            Menu {
                modePicker
            } label: {
                Image(systemName: s.mode == .chain ? "chevron.down" : s.mode.symbol(onRing: ringOnly))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(s.mode == .continuous ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .background { Circle().fill(.background).pixelBorder(Circle(), s.mode == .continuous ? Theme.buttons.opacity(0.7) : Theme.groupBorder) }
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .offset(x: 3, y: -3)
            .help(s.mode.help(onRing: ringOnly))
            .accessibilityLabel(Text(verbatim: s.mode.title(onRing: ringOnly)))
            .transition(.opacity)
        }
    }
}

/// The ball at the compass's center: the orb, lit toward the way it's rolling,
/// with four small arrows around it. Held, its ring takes the buttons' amber.
struct GestureBall: View {
    let leaning: GestureDirection?
    let held: Bool
    let fired: GestureDirection?
    var size: CGFloat = 74
    /// The four small arrows around it (off in the editor's hub: the ring's chips show the ways).
    var arrows = true

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
            ForEach(arrows ? GestureDirection.straight : [], id: \.self) { d in
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
                if modes.wheelHeld {
                    // A Wheel: the same armed ring (the pointer is held), pulsing with each ring step.
                    GestureArmedRing(size: s, pulse: modes.wheelFlash?.seq ?? 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                if modes.switcherHeld {
                    // A Switcher: the same armed ring (the pointer is held).
                    GestureArmedRing(size: s, pulse: 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                if modes.gestureHeld {
                    GestureArmedRing(size: s, pulse: flash?.seq ?? 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    ForEach(GestureDirection.straight, id: \.self) { d in
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
            .animation(Theme.Motion.fade, value: modes.wheelHeld)
            .animation(Theme.Motion.fade, value: modes.switcherHeld)
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
        let held = model.modes.gestureHeld || model.modes.wheelHeld || model.modes.switcherHeld
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
