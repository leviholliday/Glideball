import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings › Shortcuts: Glideball's system-wide shortcuts, recorded in place,
/// each with a way back to its default; Restore Defaults; a search; a note when
/// a shortcut clashes with another one (Glideball's own, macOS's or another
/// app's); and the window's own shortcuts, for reference.
struct ShortcutsSettingsPane: View {
    @Bindable var model: AppModel
    @State private var search = ShortcutsSettingsPane.sandboxSearch
    @State private var recording: GlobalShortcuts.Action?
    /// What the last recording did that's worth saying ("⌃⌥⌘P was the shortcut for Precision…").
    @State private var note: Note? = ShortcutsSettingsPane.sandboxNote
    /// `--render-ui`: a search already typed, a note already showing.
    static var sandboxSearch = ""
    static var sandboxNote: Note?
    @State private var monitor: Any?
    @State private var recordingID = UUID()

    struct Note: Equatable {
        let text: String
        var warning = true
    }

    private var shortcuts: GlobalShortcuts { model.config.globalShortcuts }

    /// The window's own shortcuts (not changeable here), for the list and the search.
    private struct Fixed: Identifiable {
        let keys: [String]
        let title: String
        var detail: String? = nil
        var id: String { keys.joined() }
        /// What a recorded shortcut looks like when it's the same keys.
        var displays: [String] {
            keys.count == 2 && keys[1].contains("–")
                ? (1...GlideTab.allCases.count).map { "⌘\($0)" }
                : [keys.joined()]
        }
    }

    private var fixed: [Fixed] {
        [
            Fixed(keys: ["⌘", "1–\(GlideTab.allCases.count)"], title: String(localized: "Switch pages"),
                  detail: ListFormatter.localizedString(byJoining: GlideTab.allCases.map(\.title))),
            Fixed(keys: ["⌘", ","], title: String(localized: "Settings")),
            Fixed(keys: ["⌘", "E"], title: String(localized: "Export Settings…")),
            Fixed(keys: ["⌘", "O"], title: String(localized: "Import Settings…")),
            Fixed(keys: ["⌘", "W"], title: String(localized: "Close the window (Glideball keeps running)")),
            Fixed(keys: ["⌘", "Q"], title: String(localized: "Quit Glideball")),
        ]
    }

    var body: some View {
        SettingsPage {
            HStack(spacing: 10) {
                SearchField(text: $search)
                Spacer(minLength: 0)
                Button("Restore Defaults") { restoreDefaults() }
                    .disabled(shortcuts == GlobalShortcuts())
                    .help("Pause goes back to \(GlobalShortcuts.defaultPause.display); the others to no shortcut")
            }

            noteLine

            // Searching never shrinks the window: the full list keeps its place, hidden.
            ZStack(alignment: .top) {
                lists(query: "").hidden().accessibilityHidden(true)
                lists(query: search)
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        // Closing Settings only hides its window, so this view never disappears: stop there too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if recording != nil { stopRecording() }
        }
    }

    /// One line under the search: how recording works, or what just happened.
    private var noteLine: some View {
        let text = note?.text ?? String(localized: "These work in every app, even with Glideball’s window closed. Click one, then press the new keys. Delete clears it; Esc keeps it.")
        return Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: note?.warning == true ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(note?.warning == true ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.tertiary))
        }
        .font(Theme.Font.hint)
        .foregroundStyle(.secondary)
        .id(text)
        .transition(.opacity)
        .animation(Theme.Motion.fade, value: note)
        .padding(.top, -10)
    }

    @ViewBuilder private func lists(query: String) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let actions = GlobalShortcuts.Action.allCases.filter { matches(q, [$0.title, $0.subtitle, shortcuts[$0]?.display ?? ""]) }
        let fixedShown = fixed.filter { matches(q, [$0.title, $0.detail ?? ""] + $0.displays) }
        VStack(alignment: .leading, spacing: 22) {
            if !actions.isEmpty {
                SectionBlock(title: "Anywhere on your Mac", dividerInset: SettingsLayout.symbolInset) {
                    ForEach(actions) { row($0) }
                }
            }
            if !fixedShown.isEmpty {
                SectionBlock(title: "In Glideball’s window") {
                    ForEach(fixedShown) { f in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: f.title).font(Theme.Font.body)
                                if let detail = f.detail {
                                    Text(verbatim: detail).font(Theme.Font.hint).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                ForEach(f.keys, id: \.self) { KeyCap(label: $0) }
                            }
                        }
                        .padding(.horizontal, Theme.Space.rowHorizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
            if actions.isEmpty && fixedShown.isEmpty {
                VStack(spacing: 8) {
                    Text("No shortcuts match “\(q)”.").font(Theme.Font.body).foregroundStyle(.secondary)
                    Button("Clear Search") { search = "" }.controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
    }

    private func matches(_ q: String, _ fields: [String]) -> Bool {
        q.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    // MARK: A row

    private func row(_ action: GlobalShortcuts.Action) -> some View {
        let current = shortcuts[action]
        let isDefault = current == GlobalShortcuts()[action]
        return SettingsRow(title: .verbatim(action.title), hint: hint(for: action), symbol: action.symbol) {
            HStack(spacing: 6) {
                if !isDefault && recording != action {
                    let back = GlobalShortcuts()[action]
                    Button {
                        withAnimation(Theme.Motion.spring) { set(action, back) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(HoverButtonStyle(shape: .circle))
                    .foregroundStyle(.secondary)
                    .help(back.map { String(localized: "Back to \($0.display)", comment: "%@ is a shortcut like ⌃⌥⌘G") }
                          ?? String(localized: "Back to no shortcut"))
                    .accessibilityLabel(back.map { String(localized: "Back to \($0.display)", comment: "%@ is a shortcut like ⌃⌥⌘G") }
                                        ?? String(localized: "Back to no shortcut"))
                    .transition(.opacity)
                }
                recorder(action, current)
            }
        }
    }

    private func recorder(_ action: GlobalShortcuts.Action, _ current: KeyShortcut?) -> some View {
        let isRecording = recording == action
        return Button {
            if isRecording { stopRecording() } else { startRecording(action) }
        } label: {
            Group {
                if isRecording {
                    Text("Press keys…").foregroundStyle(Theme.ball)
                } else if let current {
                    KeyCaps(shortcut: current)
                } else {
                    Text("None").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 96, minHeight: 26, alignment: .trailing)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isRecording ? Theme.ball : .clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 7))
        .help(isRecording ? "Press the new shortcut. Delete clears it; Esc keeps the old one." : "Click, then press a new shortcut")
        .accessibilityLabel(Text(verbatim: action.title))
        .accessibilityValue(current.map { Text(verbatim: $0.display) } ?? Text("None"))
    }

    /// Under a row: its own explanation, or why it may not work right now.
    private func hint(for action: GlobalShortcuts.Action) -> String {
        if recording == action { return String(localized: "Press the new keys now. Include ⌘, ⌃ or ⌥.") }
        guard let s = shortcuts[action] else {
            return action == .pause
                ? String(localized: "No pause shortcut. You can still pause Glideball from its menu-bar icon or the switch in the sidebar.")
                : action.subtitle
        }
        if GlobalHotKeys.shared.failed.contains(action) {
            return String(localized: "Couldn’t turn on \(s.display): another app already uses it. Choose a different one.")
        }
        if GlobalHotKeys.systemUses(s) {
            return String(localized: "macOS uses \(s.display) for one of its own shortcuts (System Settings › Keyboard › Keyboard Shortcuts), so it may never reach Glideball.",
                          comment: "Use the names System Settings shows in this language")
        }
        if let f = fixed.first(where: { $0.displays.contains(s.display) }) {
            return String(localized: "\(s.display) is also “\(f.title)” in Glideball’s window. While it’s set here, it does this instead.",
                          comment: "First %@ is a shortcut like ⌘1; second is what it does there, like Switch pages")
        }
        return action.subtitle
    }

    // MARK: Changing

    private func set(_ action: GlobalShortcuts.Action, _ shortcut: KeyShortcut?) {
        model.config.globalShortcuts[action] = shortcut
    }

    private func restoreDefaults() {
        stopRecording()
        withAnimation(Theme.Motion.spring) { model.config.globalShortcuts = GlobalShortcuts() }
        note = Note(text: String(localized: "Back to the defaults: \(GlobalShortcuts.defaultPause.display) pauses Glideball, and the modes have no shortcut."),
                    warning: false)
    }

    private func startRecording(_ action: GlobalShortcuts.Action) {
        stopRecording()
        note = nil
        recording = action
        // Otherwise pressing a shortcut Glideball already has would fire it instead of recording it.
        GlobalHotKeys.shared.suspend()
        let id = UUID()
        recordingID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if recordingID == id { stopRecording() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat, let action = recording else { return nil }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape), mods.isEmpty {
                stopRecording()
                return nil
            }
            if [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode), mods.isEmpty {
                withAnimation(Theme.Motion.spring) { set(action, nil) }
                stopRecording()
                return nil
            }
            let shortcut = KeyCapture.shortcut(from: event)
            // Taken by another of Glideball's: it moves here, and the note says so.
            if let other = GlobalShortcuts.Action.allCases.first(where: { $0 != action && shortcuts[$0]?.sameKeys(as: shortcut) == true }) {
                var updated = shortcuts
                updated[other] = nil
                updated[action] = shortcut
                withAnimation(Theme.Motion.spring) { model.config.globalShortcuts = updated }
                note = Note(text: String(localized: "\(shortcut.display) was the shortcut for \(other.title). That one has no shortcut now.",
                                         comment: "First %@ is a shortcut like ⌃⌥⌘P; the second is what it did, like Precision"))
                stopRecording()
                return nil
            }
            if let problem = shortcuts.refusal(for: shortcut, as: action) {
                note = Note(text: problem)   // keep listening for a better one
                return nil
            }
            withAnimation(Theme.Motion.spring) { set(action, shortcut) }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { recording = nil }
        recordingID = UUID()
        GlobalHotKeys.shared.resume()
    }
}

/// The search field at the top of Shortcuts (the system's own, with its clear button).
private struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search shortcuts")
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
