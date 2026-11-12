import AppKit
import SwiftUI

/// Every keyboard shortcut on one sheet, read-only: ? in the main window, or
/// Help › Keyboard Shortcuts (⌘/). "Change in Settings…" goes to Settings ›
/// Shortcuts, where the system-wide ones are recorded. Esc closes.
struct ShortcutsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let title: String
        var detail: String? = nil
        /// Keycaps, or nil for "no shortcut yet".
        let keys: [String]?
        var id: String { title }
    }

    private var anywhere: [Item] {
        let g = model.config.globalShortcuts
        return GlobalShortcuts.Action.allCases.map { a in
            Item(title: a.title, keys: g[a].map(KeyCaps.parts))
        }
    }

    private var inWindow: [Item] {
        [
            Item(title: String(localized: "Switch pages"),
                 detail: ListFormatter.localizedString(byJoining: GlideTab.allCases.map(\.title)),
                 keys: ["⌘", "1–\(GlideTab.allCases.count)"]),
            Item(title: String(localized: "Settings"), keys: ["⌘", ","]),
            Item(title: String(localized: "Export Settings…"), keys: ["⌘", "E"]),
            Item(title: String(localized: "Import Settings…"), keys: ["⌘", "O"]),
            Item(title: String(localized: "Keyboard shortcuts (this list)"), keys: ["?"]),
            Item(title: String(localized: "Close the window (Glideball keeps running)"), keys: ["⌘", "W"]),
            Item(title: String(localized: "Quit Glideball"),
                 detail: model.confirmQuit ? String(localized: "Asks first: press ⌘Q again to quit.") : nil,
                 keys: ["⌘", "Q"]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard shortcuts")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Glideball’s shortcuts, all in one place.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 20) {
                SectionBlock(title: "Anywhere on your Mac",
                             caption: "They work in every app, even with the window closed.") {
                    ForEach(anywhere) { row($0) }
                }
                SectionBlock(title: "In Glideball’s window") {
                    ForEach(inWindow) { row($0) }
                }
            }

            Spacer(minLength: 18)
            HStack {
                Button("Change in Settings…") {
                    dismiss()
                    DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.showSettings(.shortcuts) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(GlideBackground(anchor: UnitPoint(x: 0.5, y: -0.05), strength: 0.7))
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title).font(Theme.Font.body)
                if let detail = item.detail {
                    Text(verbatim: detail).font(Theme.Font.hint).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let keys = item.keys {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(label: $0.element) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: keys.joined()))
            } else {
                Text("No shortcut").font(Theme.Font.hint).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
