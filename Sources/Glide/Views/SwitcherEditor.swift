import SwiftUI

// A Switcher button on the Buttons page: a short editor under its row (or its combo's row).
// What it does, in a line, and the tap. The engine decides everything (Switcher.swift).

struct SwitcherEditor: View {
    let model: AppModel?
    /// The button, or the combo's buttons (sorted).
    let buttons: [Int]
    @Binding var switcher: AppSwitcher

    init(model: AppModel?, buttons: [Int], switcher: Binding<AppSwitcher>) {
        self.model = model
        self.buttons = buttons.sorted()
        _switcher = switcher
    }

    private var isCombo: Bool { buttons.count > 1 }
    private var held: Bool {
        guard let m = model?.modes else { return false }
        return m.switcherHeld && m.gestureButtons == buttons
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AppSwitcher.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ball.opacity(held ? 1 : 0.7))
                    .shadow(color: Theme.ball.opacity(held ? 0.7 : 0), radius: 6)
                Text(verbatim: explanation)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Tap").font(.system(size: 12, weight: .semibold))
                ActionPickerButton(action: tapShown, button: isCombo ? nil : buttons[0], purpose: .gestureTap) { switcher.tap = $0 }
                Text("A quick press, before the apps show.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, ButtonRow.dividerInset - Theme.Space.rowHorizontal)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .animation(Theme.Motion.fade, value: held)
    }

    private var explanation: String {
        isCombo
            ? String(localized: "Hold these buttons together and your open apps appear, the last one you used already picked. Roll the ball or turn the ring to choose another, and let go to switch. Esc cancels.",
                     comment: "Switcher editor, under a combo's row")
            : String(localized: "Hold this button and your open apps appear, the last one you used already picked. Roll the ball or turn the ring to choose another, and let go to switch. Esc cancels.",
                     comment: "Switcher editor, under a Switcher button's row")
    }

    /// What the tap does as shown: a button's own click by name; a combo has none.
    private var tapShown: ButtonAction {
        guard switcher.tap == .system else { return switcher.tap }
        return isCombo ? .disabled : ButtonAction.normal(for: buttons[0])
    }
}
