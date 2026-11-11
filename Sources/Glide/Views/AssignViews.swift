import AppKit
import SwiftUI

enum KeyCapture {
    static func shortcut(from e: NSEvent) -> KeyShortcut {
        var f = CGEventFlags()
        if e.modifierFlags.contains(.control) { f.insert(.maskControl) }
        if e.modifierFlags.contains(.option) { f.insert(.maskAlternate) }
        if e.modifierFlags.contains(.shift) { f.insert(.maskShift) }
        if e.modifierFlags.contains(.command) { f.insert(.maskCommand) }
        return KeyShortcut(keyCode: e.keyCode, modifiers: f.rawValue, keyName: keyName(e))
    }

    static func keyName(_ e: NSEvent) -> String {
        let special: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
            115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let s = special[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Menu of every preset action.
struct ActionMenu: View {
    let action: ButtonAction
    let onPick: (ButtonAction) -> Void

    var body: some View {
        Menu {
            ForEach(ButtonAction.presets) { p in
                Button { onPick(p.action) } label: { Label(p.title, systemImage: p.symbol) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: action.symbol)
                Text(action.title)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// The buttons in a combo, as small amber-edged chips joined by "+".
private struct ButtonChips: View {
    let buttons: [Int]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                if i > 0 { Text(verbatim: "+").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary) }
                HStack(spacing: 5) {
                    CornerGlyph(index: b).scaleEffect(0.62).frame(width: 16, height: 16)
                    Text(AppModel.buttonName(b))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.buttons.opacity(0.12)))
                .pixelBorder(Capsule(), Theme.buttons.opacity(0.35))
                .fixedSize()
            }
        }
    }
}

/// "Press a trackball button, then press a shortcut."
struct AssignPanel: View {
    @Bindable var model: AppModel
    /// Assign into this app setup instead of the main one.
    var profileID: String? = nil
    @State private var monitor: Any?

    var body: some View {
        SectionBlock(title: "Quick assign") {
            Group {
                switch model.assignStep {
                case .idle:
                    SettingRow(title: "Press a trackball button — or hold two or three together for a combo — then press the keyboard shortcut it should send.",
                               symbol: "hand.point.up.left") {
                        Button("Assign") { model.beginAssign(for: profileID) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }

                case .waitingForButtons:
                    HStack(spacing: Theme.Space.symbolGap) {
                        StatusDot(color: Theme.buttons, size: 9)
                            .frame(width: Theme.Space.symbolColumn)
                        Text("Press a button on your trackball… (hold several together for a combo)")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Cancel") { model.cancelAssign() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, Theme.Space.rowHorizontal)
                    .padding(.vertical, Theme.Space.rowVertical)
                    .frame(minHeight: Theme.Space.rowMinHeight)

                case .waitingForAction(let buttons):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ButtonChips(buttons: buttons.sorted())
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("Now press a keyboard shortcut")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 8)
                            ActionMenu(action: .system) { model.finishAssign($0) }
                            Button("Cancel") { model.cancelAssign() }
                                .controlSize(.small)
                        }
                        Text("Or choose an action from the menu. Esc cancels.")
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.Space.rowHorizontal)
                    .padding(.vertical, Theme.Space.rowVertical + 2)
                }
            }
            .background(Theme.buttons.opacity(model.assignStep == .idle ? 0 : 0.08))
        }
        .animation(Theme.Motion.spring, value: model.assignStep)
        .onChange(of: model.assignStep) { _, step in
            if case .waitingForAction = step { startKeyCapture() } else { stopKeyCapture() }
        }
        .onDisappear {
            stopKeyCapture()
            if model.assignStep != .idle { model.cancelAssign() }
        }
        .onKeyPress(.escape) {
            guard model.assignStep != .idle else { return .ignored }
            model.cancelAssign()
            return .handled
        }
    }

    private func startKeyCapture() {
        stopKeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { model.cancelAssign(); return nil }
            model.finishAssign(.shortcut(KeyCapture.shortcut(from: event)))
            return nil
        }
    }

    private func stopKeyCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Saved multi-button combos, and a row for making a new one.
struct CombosCard: View {
    @Binding var chords: [Chord]
    /// Nil where the page already titles it (an app setup's Combos area).
    var title: LocalizedStringKey? = "Combos"

    init(chords: Binding<[Chord]>, title: LocalizedStringKey? = "Combos") {
        _chords = chords
        self.title = title
    }

    init(model: AppModel) {
        _chords = Binding(get: { model.config.chords }, set: { model.config.chords = $0 })
    }

    var body: some View {
        SectionBlock(title: title,
                     caption: "Buttons in a combo wait a split second (up to 0.16 s for three) to see if their partners join. Buttons not in any combo respond instantly.") {
            if chords.isEmpty {
                SettingRow(title: "No combos yet. Use Quick assign and hold two or three buttons together.")
                    .foregroundStyle(.secondary)
            }
            ForEach(chords) { chord in
                HStack(spacing: 10) {
                    ButtonChips(buttons: chord.buttons)
                    Spacer(minLength: 8)
                    ActionMenu(action: chord.action) { action in
                        if let i = chords.firstIndex(where: { $0.id == chord.id }) {
                            chords[i].action = action
                        }
                    }
                    IconButton(symbol: "trash", help: "Delete combo", size: 24) {
                        withAnimation(Theme.Motion.spring) { chords.removeAll { $0.id == chord.id } }
                    }
                }
                .padding(.horizontal, Theme.Space.rowHorizontal)
                .padding(.vertical, 8)
                .frame(minHeight: Theme.Space.rowMinHeight)
            }
            NewComboRow(chords: $chords)
        }
    }
}

/// Build a combo by ticking buttons — no need to press them all at once.
private struct NewComboRow: View {
    @Binding var chords: [Chord]
    @State private var picked: Set<Int> = []
    @State private var action: ButtonAction = .shortcut(.missionControl)

    private var sorted: [Int] { picked.sorted() }
    private var duplicate: Bool { chords.contains { $0.buttons == sorted } }
    private var canAdd: Bool { picked.count >= 2 && !duplicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New combo").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { b in
                    let on = picked.contains(b)
                    Toggle(isOn: Binding(get: { on }, set: { new in
                        withAnimation(Theme.Motion.spring) { if new { picked.insert(b) } else { picked.remove(b) } }
                    })) {
                        Text(AppModel.buttonName(b))
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    if b < 3 { Spacer(minLength: 4) }
                }
            }
            HStack(spacing: 10) {
                ActionMenu(action: action) { action = $0 }
                Spacer()
                if duplicate {
                    Text("That combo already exists").font(Theme.Font.hint).foregroundStyle(Theme.warn)
                } else if picked.count == 1 {
                    Text("Pick at least two").font(Theme.Font.hint).foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(Theme.Motion.spring) {
                        chords.append(Chord(buttons: sorted, action: action))
                        picked = []
                    }
                } label: {
                    Label("Add Combo", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(!canAdd)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 12)
    }
}
