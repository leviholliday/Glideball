import AppKit
import SwiftUI

// The picker that replaced the long action menus: a glass popover anchored to
// what you clicked, a search field that's ready to type in, the choices in
// groups with an icon and one line each, and the keyboard for everything
// (↑ ↓ to move, ↩ to choose, esc to close). `SearchPickerPanel` is the
// generic part (the Apps tab's "Add App…" uses it too); `ActionPickerPanel`
// fills it with everything a button can do, plus recording a shortcut and
// choosing an app.

// MARK: - The generic panel

/// One choice in a `SearchPickerPanel`.
struct PickerEntry: Identifiable {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let id: String
    let title: String
    var detail: String? = nil
    var icon: Icon = .symbol("circle")
    /// Shown as keycaps on the right.
    var keys: KeyShortcut? = nil
    var isCurrent = false
    /// Opens something else rather than choosing (a "…" entry): no checkmark, a chevron.
    var opensMore = false
    let activate: () -> Void
}

struct PickerSection: Identifiable {
    let id: String
    var title: String? = nil
    let entries: [PickerEntry]
}

/// A search field over a scrolling list of grouped choices, all of it usable
/// from the keyboard. The highlighted row follows the pointer and the arrow
/// keys; Return chooses it; Escape closes (the popover's own behavior).
struct SearchPickerPanel: View {
    let placeholder: String
    /// The sections for a search ("" for everything).
    let sections: (String) -> [PickerSection]
    /// What to say when a search finds nothing.
    let emptyText: (String) -> String
    var width: CGFloat = 400
    var height: CGFloat = 470
    /// Renders: start with this search typed.
    var initialQuery = ""
    /// Takes the keyboard (false while something else, like a shortcut recorder, needs it).
    var keyboardActive = true

    @State private var query = ""
    @State private var highlighted: String?
    /// Set by arrow keys, so only keyboard moves scroll the list.
    @State private var keyboardMove = 0
    @State private var monitor: Any?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = sections(query)
        let flat = list.flatMap(\.entries)
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Hairline()
            if flat.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: emptyText(query))
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(list) { section in
                                if let title = section.title {
                                    Text(verbatim: title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 10)
                                        .padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(section.entries) { entry in
                                    PickerRow(entry: entry, highlighted: highlighted == entry.id)
                                        .id(entry.id)
                                        .onHover { inside in if inside { highlighted = entry.id } }
                                        .onTapGesture { entry.activate() }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: keyboardMove) { _, _ in
                        if let highlighted { proxy.scrollTo(highlighted) }
                    }
                }
            }
            Hairline()
            footer
        }
        .frame(width: width, height: height)
        .onAppear {
            query = initialQuery
            highlighted = sections(initialQuery).first?.entries.first?.id
            searchFocused = true
            startKeys()
        }
        .onDisappear(perform: stopKeys)
        .onChange(of: query) { _, q in
            // A new search highlights its best match.
            highlighted = sections(q).first?.entries.first?.id
        }
        .onChange(of: keyboardActive) { _, active in
            if active { startKeys(); searchFocused = true } else { stopKeys() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(text: $query) { Text(verbatim: placeholder) }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.groupFill)
                .pixelBorder(RoundedRectangle(cornerRadius: 9, style: .continuous), Theme.groupBorder)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint(["↑", "↓"], String(localized: "move", comment: "Picker footer: arrow keys move the highlight"))
            hint(["↩"], String(localized: "choose", comment: "Picker footer: Return chooses"))
            hint(["esc"], String(localized: "close", comment: "Picker footer: Escape closes"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                Text(verbatim: k)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.groupFill))
                    .pixelBorder(RoundedRectangle(cornerRadius: 4, style: .continuous), Theme.groupBorder)
            }
            Text(verbatim: label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: Keyboard

    private func move(_ step: Int) {
        let ids = sections(query).flatMap(\.entries).map(\.id)
        guard !ids.isEmpty else { return }
        let i = highlighted.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        highlighted = ids[min(max(i + step, 0), ids.count - 1)]
        keyboardMove += 1
    }

    private func chooseHighlighted() {
        let entries = sections(query).flatMap(\.entries)
        (entries.first { $0.id == highlighted } ?? entries.first)?.activate()
    }

    private func startKeys() {
        stopKeys()
        guard keyboardActive else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: move(1); return nil                    // ↓
            case 126: move(-1); return nil                   // ↑
            case 36, 76: chooseHighlighted(); return nil     // ↩, enter
            case 53: dismiss(); return nil                   // esc
            default: return event
            }
        }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One row: an icon on a small tile, the name with a line under it, keycaps or
/// a checkmark on the right. Highlighted: a ball-blue wash and a lit tile.
private struct PickerRow: View {
    let entry: PickerEntry
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(Theme.groupFill))
                    .pixelBorder(RoundedRectangle(cornerRadius: 7, style: .continuous), highlighted ? .clear : Theme.groupBorder)
                switch entry.icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                case .image(let image):
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 20, height: 20)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let keys = entry.keys {
                KeyCaps(shortcut: keys).scaleEffect(0.85).fixedSize()
            }
            if entry.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ball)
                    .accessibilityLabel("Current")
            } else if entry.opensMore {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? Theme.ball.opacity(0.14) : .clear)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(entry.isCurrent ? .isSelected : [])
    }
}

// MARK: - Actions

/// Everything a button or a combo can do, grouped and searchable, with
/// "Record a shortcut…" and "Choose an app…" at the end.
struct ActionPickerPanel: View {
    /// What it does now (nil: nothing chosen yet, as in Quick assign).
    let current: ButtonAction?
    /// The button this is for (its suggestions, and what "Default" means); nil for a combo.
    var button: Int? = nil
    /// What it's choosing: a button's action, one direction of a gesture, or a gesture's tap.
    var purpose: Purpose = .button
    let pick: (ButtonAction) -> Void

    enum Purpose {
        case button, gestureDirection, gestureTap
    }

    @State private var recording = false
    @State private var holdKeys = false
    @State private var captured: KeyShortcut?
    @State private var monitor: Any?
    @Environment(\.dismiss) private var dismiss

    /// Renders: start with this search typed, or in the recorder.
    nonisolated(unsafe) static var sandboxQuery: String?
    nonisolated(unsafe) static var sandboxRecording = false

    var body: some View {
        ZStack {
            SearchPickerPanel(placeholder: String(localized: "Search actions", comment: "Action picker search field"),
                              sections: sections, emptyText: { q in
                                  String(localized: "Nothing called “\(q)”. Try another word, or record it as a keyboard shortcut.",
                                         comment: "Action picker: a search found nothing; %@ is what was typed")
                              },
                              initialQuery: Self.sandboxQuery ?? "",
                              keyboardActive: !recording)
            if recording { recorder }
        }
        .onAppear { if Self.sandboxRecording { recording = true } }
        .onDisappear(perform: stopRecording)
    }

    private func choose(_ action: ButtonAction) {
        if !action.isGesture { ActionCatalog.remember(action) }
        pick(action)
        dismiss()
    }

    private func entry(_ item: ActionCatalog.Item, section: String) -> PickerEntry {
        var detail = item.detail
        if item.action == .system, let button {
            detail = String(localized: "Normally: \(AppModel.buttonDefault(button))")
        }
        let keys: KeyShortcut? = switch item.action {
        case .shortcut(let s), .holdShortcut(let s): s
        default: nil
        }
        var icon = PickerEntry.Icon.symbol(item.symbol)
        if case .openApp(let id) = item.action, let image = ActionCatalog.appIcon(id) { icon = .image(image) }
        return PickerEntry(id: section + ":" + item.id, title: item.title, detail: detail, icon: icon, keys: keys,
                           isCurrent: item.action == current, activate: { choose(item.action) })
    }

    private func sections(_ query: String) -> [PickerSection] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var catalog = ActionCatalog.all.filter { allowed($0.action) }
        if button == nil { catalog.removeAll { $0.action == .system } }   // a combo has no "normal"
        var out: [PickerSection] = []
        let gesture = gestureEntry(q)

        if q.isEmpty {
            // What it does now, then what was chosen lately (or a few good first picks), then everything.
            if let current, !current.isGesture {
                out.append(PickerSection(id: "now", title: String(localized: "Now", comment: "Action picker group: what the button does now"),
                                         entries: [entry(ActionCatalog.item(for: current), section: "now")]))
            }
            // A gesture is a different kind of choice: right at the top, under what it does now.
            if let gesture {
                out.append(PickerSection(id: "gesture", title: String(localized: "Hold and roll", comment: "Action picker group: gesture buttons"),
                                         entries: [gesture]))
            }
            let recent = ActionCatalog.recents.filter { $0 != current && (button != nil || $0 != .system) && allowed($0) }
            let top = recent.isEmpty ? ActionCatalog.suggestions(forButton: purpose == .button ? button : nil)
                .filter { $0 != current && allowed($0) } : recent
            if !top.isEmpty {
                out.append(PickerSection(id: "top", title: recent.isEmpty ? String(localized: "Suggested", comment: "Action picker group")
                                                                          : String(localized: "Recent", comment: "Action picker group"),
                                         entries: top.prefix(4).map { entry(ActionCatalog.item(for: $0), section: "top") }))
            }
            for category in ActionCatalog.Category.allCases {
                let items = catalog.filter { $0.category == category }
                guard !items.isEmpty else { continue }
                out.append(PickerSection(id: category.rawValue, title: category.title,
                                         entries: items.map { entry($0, section: category.rawValue) }))
            }
        } else {
            // A search: one list, best match first.
            let found = catalog.map { ($0, $0.score(q)) }.filter { $0.1 > 0 }
                .enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map(\.element.0)
            var entries = found.map { entry($0, section: "found") }
            if let gesture { entries.insert(gesture, at: 0) }
            if !entries.isEmpty {
                out.append(PickerSection(id: "found", entries: entries))
            }
        }

        let record = PickerEntry(id: "record", title: String(localized: "Record a shortcut…", comment: "Action picker"),
                                 detail: String(localized: "Press any keys and this button sends them.", comment: "Action picker: Record a shortcut…"),
                                 icon: .symbol("record.circle"), opensMore: true,
                                 activate: { startRecording() })
        let app = PickerEntry(id: "app", title: String(localized: "Choose an app…", comment: "Action picker"),
                              detail: String(localized: "Opens an app, or brings it to the front.", comment: "Action picker: Choose an app…"),
                              icon: .symbol("app.badge"), opensMore: true,
                              activate: { chooseApp() })
        let recordWords = record.title + " " + String(localized: "keyboard shortcut keys", comment: "Action picker: extra search words for Record a shortcut")
        let appWords = app.title + " " + String(localized: "open launch application", comment: "Action picker: extra search words for Choose an app")
        let matchesRecord = q.isEmpty || recordWords.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        let matchesApp = q.isEmpty || appWords.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        if matchesRecord {
            out.append(PickerSection(id: "keys", title: String(localized: "Keyboard shortcut", comment: "Action picker group"), entries: [record]))
        }
        if matchesApp {
            out.append(PickerSection(id: "apps", title: String(localized: "Open an app", comment: "Action picker group"), entries: [app]))
        }
        return out
    }

    /// Whether this choice can be made here: a gesture's direction fires a quick
    /// press (no modes, no held keys), and a gesture's tap can't be held or be another gesture.
    private func allowed(_ action: ButtonAction) -> Bool {
        switch purpose {
        case .button: true
        case .gestureDirection: action == .disabled || GestureStep(action).firable != nil
        case .gestureTap: !action.isGesture && action != .precisionHold && action != .ballScrollHold
        }
    }

    /// "Gesture": offered for the three free buttons (never the primary one, never a combo),
    /// and only when choosing what a button does. Search finds it by its own words.
    private func gestureEntry(_ q: String) -> PickerEntry? {
        guard purpose == .button, let button, button != 0 else { return nil }
        let title = String(localized: "Gesture", comment: "Action picker: hold the button and roll the ball")
        let detail = String(localized: "Hold the button and roll the ball: a different action each way.", comment: "Action picker: Gesture")
        let words = title + " " + detail + " " + String(localized: "hold roll swipe direction", comment: "Action picker: extra search words for Gesture")
        if !q.isEmpty, !q.split(separator: " ").allSatisfy({ words.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            return nil
        }
        let isGesture = current?.isGesture ?? false
        return PickerEntry(id: "gesture", title: title, detail: detail,
                           icon: .symbol("dot.arrowtriangles.up.right.down.left.circle"), isCurrent: isGesture,
                           activate: { choose(.gesture(ButtonGesture.keeping(current ?? .system))) })
    }

    // MARK: Choosing an app

    private func chooseApp() {
        dismiss()
        let pick = self.pick
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = String(localized: "Choose an App")
            panel.message = String(localized: "Choose the app this button should open.")
            panel.prompt = String(localized: "Choose", comment: "Open panel button")
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            let action = ButtonAction.openApp(bundleID: id)
            ActionCatalog.remember(action)
            pick(action)
        }
    }

    // MARK: Recording a shortcut

    private var recorder: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Theme.buttons.opacity(0.16)).frame(width: 64, height: 64)
                Image(systemName: "keyboard")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.buttons)
            }
            VStack(spacing: 4) {
                Text("Press the keys")
                    .font(Theme.Font.emphasis)
                Text("Hold the modifiers (⌘ ⌥ ⌃ ⇧), then press the key. Esc cancels.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let captured {
                    KeyCaps(shortcut: captured).scaleEffect(1.3)
                } else {
                    Text(verbatim: "…").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 34)
            Toggle(isOn: $holdKeys) {
                Text("Hold the keys down while the button is held")
            }
            .toggleStyle(.checkbox)
            .font(Theme.Font.hint)
            HStack(spacing: 10) {
                Button("Cancel") { stopRecording() }
                    .controlSize(.regular)
                Button("Use This Shortcut") {
                    guard let captured else { return }
                    choose(holdKeys ? .holdShortcut(captured) : .shortcut(captured))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .disabled(captured == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear(perform: startMonitor)
    }

    private func startRecording() {
        captured = nil
        withAnimation(Theme.Motion.fade) { recording = true }
    }

    private func startMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // esc
                stopRecording()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               let captured {
                choose(holdKeys ? .holdShortcut(captured) : .shortcut(captured))   // ↩ on its own confirms
                return nil
            }
            captured = KeyCapture.shortcut(from: event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        withAnimation(Theme.Motion.fade) { recording = false }
    }
}

// MARK: - The button that opens it

/// What a button or combo does, as a compact pop-up-style button: the action's
/// icon and name (and keys), and a chevron. Clicking it opens the picker in a
/// popover anchored here.
struct ActionPickerButton: View {
    /// Nil: nothing chosen yet ("Choose an action").
    let action: ButtonAction?
    var button: Int? = nil
    /// Lets the page open it (the trackball map, a real button press). Optional.
    var isPresented: Binding<Bool>? = nil
    var purpose: ActionPickerPanel.Purpose = .button
    /// The keys a shortcut sends, beside its name (off where space is tight).
    var showsKeys = true
    let onPick: (ButtonAction) -> Void

    @State private var open = false

    var body: some View {
        let shown = isPresented ?? $open
        Button {
            shown.wrappedValue = true
        } label: {
            if let action {
                ActionLabel(action: action, showsKeys: showsKeys)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11.5, weight: .medium))
                    Text("Choose an Action").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .buttonStyle(ActionButtonStyle())
        .help("Choose what this does")
        .accessibilityLabel(Text("\(action?.title ?? String(localized: "Nothing chosen")), choose what this does",
                                 comment: "Spoken: a button’s current action, then what clicking does"))
        .popover(isPresented: shown, arrowEdge: .bottom) {
            ActionPickerPanel(current: action, button: button, purpose: purpose) { new in onPick(new) }
        }
    }
}

/// An action's icon, name and keys on one line.
struct ActionLabel: View {
    let action: ButtonAction
    var chevron = true
    var showsKeys = true

    var body: some View {
        HStack(spacing: 6) {
            if case .openApp(let id) = action, let icon = ActionCatalog.appIcon(id) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: action.symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 15)
            }
            Text(verbatim: action.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if showsKeys, let d = action.detail, action.title != d {
                Text(verbatim: d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// A quiet rounded well that lifts on hover, like a pop-up button.
struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            configuration.label
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    shape.fill(configuration.isPressed ? Theme.pressedFill : hovering && enabled ? Theme.hoverFill : Theme.groupFill)
                        .pixelBorder(shape, hovering ? Theme.ball.opacity(0.45) : Theme.groupBorder)
                }
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .focusEffectDisabled(false)
        }
    }
}
