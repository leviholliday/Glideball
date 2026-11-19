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
            hiddenApps
                .findable(.switcherHiddenApps)
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

    /// The apps this Switcher leaves out (hidden from its panel), each with Show to bring it back;
    /// with none, how to hide one.
    @ViewBuilder private var hiddenApps: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Hidden from the Switcher").font(.system(size: 12, weight: .semibold))
            if switcher.hidden.isEmpty {
                if let buttonName = SwitcherOverlayPanel.hideButton(besides: buttons) {
                    Text("None. To leave an app out, press \(buttonName) while it’s lit in the Switcher.",
                         comment: "Switcher editor, no hidden apps; %@ is a trackball button's name, like “Top left”")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(switcher.hidden, id: \.self) { id in
                        SwitcherHiddenAppRow(bundleID: id) {
                            withAnimation(Theme.Motion.spring) { switcher.hidden.removeAll { $0 == id } }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .animation(Theme.Motion.spring, value: switcher.hidden)
    }

    /// What the tap does as shown: a button's own click by name; a combo has none.
    private var tapShown: ButtonAction {
        guard switcher.tap == .system else { return switcher.tap }
        return isCombo ? .disabled : ButtonAction.normal(for: buttons[0])
    }
}

/// One app a Switcher hides: its icon and name (looked up from its bundle ID on this Mac; the
/// bundle ID itself if it isn't installed), and Show to put it back in the Switcher.
struct SwitcherHiddenAppRow: View {
    let bundleID: String
    let show: () -> Void

    var body: some View {
        let app = Self.lookUp(bundleID)
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(verbatim: app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Show", action: show)
                .controlSize(.small)
                .help(Text("Show \(app.name) in the Switcher again", comment: "Switcher editor: the Show button beside a hidden app; %@ is the app's name"))
                .accessibilityLabel(Text("Show \(app.name) in the Switcher again", comment: "Switcher editor: the Show button beside a hidden app; %@ is the app's name"))
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// The app's name and icon on this Mac, or its bundle ID and a plain app icon.
    static func lookUp(_ bundleID: String) -> (name: String, icon: NSImage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (bundleID, NSWorkspace.shared.icon(for: .application))
    }
}

extension Findable {
    /// Under each Switcher's editor on the Buttons page (only while there's a Switcher).
    static let switcherHiddenApps = Findable(
        id: "switcher-hidden-apps", title: String(localized: "Hidden from the Switcher"),
        detail: String(localized: "Apps a Switcher leaves out. Show one again here, or hide one right from the Switcher with another button.",
                       comment: "Search palette: a Switcher's hidden apps"),
        keywords: String(localized: "hide app, hidden apps, exclude, leave out, remove app, show again, switcher",
                         comment: "Search words for a Switcher's hidden apps (comma-separated)"),
        symbol: "eye.slash", place: .tab(.buttons), part: .clicks, sometimes: true)
}
