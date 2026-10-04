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
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                Text(action.title).font(.system(size: 13, weight: .medium))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }
}

private struct ButtonChips: View {
    let buttons: [Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                if i > 0 { Text("+").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary) }
                Text(AppModel.buttonName(b))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular.tint(.cyan.opacity(0.3)), in: .capsule)
            }
        }
    }
}

/// "Press a trackball button, then press a shortcut."
struct AssignPanel: View {
    @Bindable var model: AppModel
    @State private var monitor: Any?
    @State private var pulse = false

    var body: some View {
        GlassCard(title: "Quick assign", symbol: "wand.and.rays",
                  tint: model.assignStep == .idle ? nil : .cyan.opacity(0.18)) {
            switch model.assignStep {
            case .idle:
                HStack {
                    Text("Press a trackball button — or hold two or three together for a combo — then press the keyboard shortcut it should send.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button { model.beginAssign() } label: {
                        Label("Assign", systemImage: "hand.point.up.left.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }

            case .waitingForButtons:
                HStack(spacing: 12) {
                    Circle().fill(.cyan).frame(width: 10, height: 10)
                        .scaleEffect(pulse ? 1.4 : 0.8).opacity(pulse ? 1 : 0.5)
                        .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                    Text("Press a button on your trackball… (hold several together for a combo)")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Cancel") { model.cancelAssign() }.buttonStyle(.glass)
                }

            case .waitingForAction(let buttons):
                HStack(spacing: 12) {
                    ButtonChips(buttons: buttons.sorted())
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("Now press a keyboard shortcut")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    ActionMenu(action: .system) { model.finishAssign($0) }
                    Button("Cancel") { model.cancelAssign() }.buttonStyle(.glass)
                }
                Text("Or choose an action from the menu. Esc cancels.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
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

/// Saved multi-button combos.
struct CombosCard: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassCard(title: "Combos", symbol: "square.on.square") {
            if model.config.chords.isEmpty {
                Text("No combos yet. Use Quick assign and hold two or three buttons together.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.config.chords) { chord in
                HStack(spacing: 12) {
                    ButtonChips(buttons: chord.buttons)
                    Spacer()
                    ActionMenu(action: chord.action) { action in
                        if let i = model.config.chords.firstIndex(where: { $0.id == chord.id }) {
                            model.config.chords[i].action = action
                        }
                    }
                    Button {
                        model.config.chords.removeAll { $0.id == chord.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                    .help("Delete combo")
                }
            }
            Text("Buttons in a combo wait 70 ms to see if their partners join. Buttons not in any combo respond instantly.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
