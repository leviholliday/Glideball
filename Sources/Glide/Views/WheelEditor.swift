import SwiftUI

// A Wheel button on the Buttons page: the editor under its row (or its combo's row).
// The slots are laid out as the Wheel itself (eight places around the ball, the four
// straight ones always, the diagonals with eight slots), each one the usual action
// picker; beside it the tap, what the scroll ring does while held, and four or eight.
// The engine decides everything (Wheel.swift); this only edits the settings and shows
// what a held Wheel is doing.

struct WheelEditor: View {
    let model: AppModel?
    /// The button, or the combo's buttons (sorted).
    let buttons: [Int]
    @Binding var menu: WheelMenu

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel?, buttons: [Int], menu: Binding<WheelMenu>) {
        self.model = model
        self.buttons = buttons.sorted()
        _menu = menu
    }

    private var isCombo: Bool { buttons.count > 1 }
    private var modes: Engine.Modes { model?.modes ?? Engine.Modes() }
    private var held: Bool { modes.wheelHeld && modes.gestureButtons == buttons }
    private var lit: Int? { held ? modes.wheelSlot : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: explanation)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    wheel
                    side.frame(maxWidth: 250, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    wheel.frame(maxWidth: .infinity)
                    HStack(alignment: .top, spacing: 28) {
                        tapBlock.frame(maxWidth: 170, alignment: .leading)
                        ringBlock.frame(maxWidth: 230, alignment: .leading)
                        countBlock.frame(maxWidth: 170, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    wheel.frame(maxWidth: .infinity)
                    side
                }
            }
        }
        .padding(.leading, ButtonRow.dividerInset - Theme.Space.rowHorizontal)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .animation(reduceMotion ? nil : Theme.Motion.spring, value: menu.eight)
        .animation(reduceMotion ? nil : Theme.Motion.pressIn, value: lit)
    }

    private var explanation: String {
        isCombo
            ? String(localized: "Hold these buttons together and a ring of actions appears around the pointer. Roll toward one and let go to run it, or roll back to the middle to cancel. A quick press does the tap.",
                     comment: "Wheel editor, under a combo's row")
            : String(localized: "Hold this button and a ring of actions appears around the pointer. Roll toward one and let go to run it, or roll back to the middle to cancel. A quick press does the tap.",
                     comment: "Wheel editor, under a Wheel button's row")
    }

    // MARK: The wheel

    /// The eight places on a 3 × 3 grid around the ball, on a faint ring like the real one.
    private var wheel: some View {
        let grid: [[Int?]] = [[7, 0, 1], [6, nil, 2], [5, 4, 3]]
        return Grid(horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        if let place = grid[row][col] {
                            if menu.usedPlaces.contains(place) {
                                slot(place)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        } else {
                            GestureBall(leaning: nil, held: held, fired: nil, size: 70)
                        }
                    }
                }
            }
        }
        .fixedSize()
        .background {
            Circle()
                .strokeBorder(Theme.ball.opacity(held ? 0.5 : 0.18), style: StrokeStyle(lineWidth: held ? 2 : 1.5, dash: held ? [] : [3, 5]))
                .padding(menu.eight ? 26 : 8)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Wheel slots", comment: "Wheel editor: VoiceOver name of the slots around the ball"))
    }

    private func slot(_ place: Int) -> some View {
        let on = lit == place
        return ActionPickerButton(action: menu[place] ?? .disabled, purpose: .wheelSlot, showsKeys: false) { picked in
            menu[place] = picked == .disabled ? nil : picked
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.ball.opacity(on ? 1 : 0), lineWidth: 1.5)
                .shadow(color: Theme.ball.opacity(on ? 0.7 : 0), radius: 8)
                .allowsHitTesting(false)
        }
        .scaleEffect(on && !reduceMotion ? 1.05 : 1)
        .accessibilityLabel(Text(verbatim: Self.placeTitle(place)))
    }

    /// "Up", "Up right"…, for VoiceOver.
    static func placeTitle(_ place: Int) -> String {
        switch place {
        case 0: String(localized: "Up", comment: "Wheel slot, straight up")
        case 1: String(localized: "Up right", comment: "Wheel slot")
        case 2: String(localized: "Right", comment: "Wheel slot")
        case 3: String(localized: "Down right", comment: "Wheel slot")
        case 4: String(localized: "Down", comment: "Wheel slot")
        case 5: String(localized: "Down left", comment: "Wheel slot")
        case 6: String(localized: "Left", comment: "Wheel slot")
        default: String(localized: "Up left", comment: "Wheel slot")
        }
    }

    // MARK: Tap, ring, slots

    private var side: some View {
        VStack(alignment: .leading, spacing: 14) {
            tapBlock
            ringBlock
            countBlock
        }
    }

    /// What the tap does as shown: a button's own click by name; a combo has none.
    private var tapShown: ButtonAction {
        guard menu.tap == .system else { return menu.tap }
        return isCombo ? .disabled : ButtonAction.normal(for: buttons[0])
    }

    private var tapBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tap").font(.system(size: 12, weight: .semibold))
            ActionPickerButton(action: tapShown, button: isCombo ? nil : buttons[0], purpose: .gestureTap) { menu.tap = $0 }
            Text("A press without rolling.")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
        }
    }

    private var ringBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Scroll ring while held").font(.system(size: 12, weight: .semibold))
            Menu {
                Picker(selection: $menu.ring) {
                    ForEach(RingJob.allCases) { job in
                        Label(job.title, systemImage: job.symbol).tag(job)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Label(menu.ring.title, systemImage: menu.ring.symbol)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .tint(Theme.ring)
            if menu.ring == .custom {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ring)
                        .help("Turning the ring counterclockwise")
                    ActionPickerButton(action: menu.ringDown ?? .disabled, purpose: .wheelSlot, showsKeys: false) {
                        menu.ringDown = $0 == .disabled ? nil : $0
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ring)
                        .help("Turning the ring clockwise")
                    ActionPickerButton(action: menu.ringUp ?? .disabled, purpose: .wheelSlot, showsKeys: false) {
                        menu.ringUp = $0 == .disabled ? nil : $0
                    }
                }
            }
            Text(verbatim: ringHint)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Talks about now: what turning the ring does with this job.
    private var ringHint: String {
        switch menu.ring {
        case .volume: String(localized: "Turn the ring while you hold it to change the volume. It doesn’t scroll meanwhile.", comment: "Wheel editor: ring job hint")
        case .brightness: String(localized: "Turn the ring while you hold it to change the screen’s brightness.", comment: "Wheel editor: ring job hint")
        case .zoom: String(localized: "Turn the ring while you hold it to zoom in and out (⌘+ and ⌘−).", comment: "Wheel editor: ring job hint")
        case .undo: String(localized: "Turn the ring back to undo, forward to redo.", comment: "Wheel editor: ring job hint")
        case .tabs: String(localized: "Turn the ring while you hold it to move between tabs.", comment: "Wheel editor: ring job hint")
        case .custom: String(localized: "One action for each way you turn the ring, a step per click.", comment: "Wheel editor: ring job hint")
        case .off: String(localized: "The ring does nothing while you hold it.", comment: "Wheel editor: ring job hint")
        }
    }

    private var countBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Slots").font(.system(size: 12, weight: .semibold))
            Picker(selection: $menu.eight) {
                Text("4").tag(false)
                Text("8").tag(true)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Four slots are the easiest to hit; eight adds the diagonals.")
            Text(menu.eight ? String(localized: "Eight: the diagonals too.", comment: "Wheel editor: slot count hint")
                            : String(localized: "Four: up, right, down and left. Empty ones are skipped, so the rest get wider.", comment: "Wheel editor: slot count hint"))
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
