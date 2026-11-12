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

/// The buttons in a combo, as small amber-edged chips joined by "+".
struct ButtonChips: View {
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
                    SettingRow(title: "Press a trackball button, or hold two or three together for a combo, then press the keyboard shortcut it should send.",
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
                            Button("Cancel") { model.cancelAssign() }
                                .controlSize(.small)
                        }
                        HStack(spacing: 8) {
                            Text("Or choose an action:")
                                .font(Theme.Font.hint)
                                .foregroundStyle(.secondary)
                            ActionPickerButton(action: nil, button: buttons.count == 1 ? buttons.first : nil) {
                                model.finishAssign($0)
                            }
                            Spacer(minLength: 0)
                            Text("Esc cancels.")
                                .font(Theme.Font.hint)
                                .foregroundStyle(.tertiary)
                        }
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
        .onAppear {
            if case .waitingForAction = model.assignStep { startKeyCapture() }
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
            // The picker, if it's open, has the keyboard (its search field and arrows).
            if NSApp.keyWindow?.className.contains("Popover") == true { return event }
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

/// Saved multi-button combos, each with the same picker as a button, and a
/// clear way to make a new one.
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
                     caption: "Press two or three buttons together to do something else. Buttons in a combo wait a split second (up to 0.16 s for three) to see if their partners join; buttons not in any combo respond instantly.") {
            if chords.isEmpty {
                SettingRow(title: "No combos yet.", hint: "Add one below, or use Quick assign and hold the buttons together.",
                           symbol: "square.on.square")
            }
            ForEach(chords) { chord in
                HStack(spacing: 10) {
                    ButtonChips(buttons: chord.buttons)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ActionPickerButton(action: chord.action) { action in
                        if let i = chords.firstIndex(where: { $0.id == chord.id }) {
                            chords[i].action = action
                        }
                    }
                    Spacer(minLength: 8)
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

/// "Add a combo": a row that opens into two steps: tap the pads of a little
/// trackball to pick the buttons (two or three), then choose what they do.
struct NewComboRow: View {
    @Binding var chords: [Chord]
    @State private var open = false
    @State private var picked: Set<Int> = []
    @State private var action: ButtonAction = .shortcut(.missionControl)

    /// Renders: draw it open with these picked.
    nonisolated(unsafe) static var sandboxPicked: Set<Int>?

    private var sorted: [Int] { picked.sorted() }
    private var duplicate: Bool { chords.contains { $0.buttons == sorted } }
    private var canAdd: Bool { picked.count >= 2 && !duplicate }

    var body: some View {
        Group {
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 16) {
                        PadPicker(picked: $picked)
                        VStack(alignment: .leading, spacing: 10) {
                            step(1, String(localized: "Tap the buttons that go together", comment: "New combo, step 1"),
                                 done: picked.count >= 2)
                            HStack(spacing: 6) {
                                if picked.isEmpty {
                                    Text("Two or three of them.").font(Theme.Font.hint).foregroundStyle(.secondary)
                                } else {
                                    ButtonChips(buttons: sorted)
                                }
                            }
                            .frame(minHeight: 22)
                            step(2, String(localized: "Choose what they do", comment: "New combo, step 2"), done: false)
                            ActionPickerButton(action: action) { action = $0 }
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        if duplicate {
                            Label {
                                Text("That combo already exists")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                            }
                            .font(Theme.Font.hint)
                        } else if picked.count == 1 {
                            Text("Pick at least two").font(Theme.Font.hint).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { close() }.controlSize(.small)
                        Button {
                            withAnimation(Theme.Motion.spring) {
                                chords.append(Chord(buttons: sorted, action: action))
                                close()
                            }
                        } label: {
                            Label("Add Combo", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ball)
                        .controlSize(.small)
                        .disabled(!canAdd)
                    }
                }
                .padding(.horizontal, Theme.Space.rowHorizontal)
                .padding(.vertical, 12)
                .background(Theme.buttons.opacity(0.05))
                .transition(.opacity)
            } else {
                Button {
                    withAnimation(Theme.Motion.spring) { open = true }
                } label: {
                    HStack(spacing: Theme.Space.symbolGap) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.ball)
                            .frame(width: Theme.Space.symbolColumn)
                        Text("Add a combo").font(Theme.Font.body)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Space.rowHorizontal)
                    .frame(minHeight: Theme.Space.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowHoverStyle())
            }
        }
        .onAppear {
            if let p = Self.sandboxPicked { open = true; picked = p }
        }
    }

    private func close() {
        withAnimation(Theme.Motion.spring) {
            open = false
            picked = []
        }
    }

    private func step(_ n: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(Theme.groupFill))
                    .pixelBorder(Circle(), done ? .clear : Theme.groupBorder)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(verbatim: text).font(.system(size: 12.5, weight: .semibold))
        }
    }
}

/// Four big pads in the trackball's layout, to tap on and off.
private struct PadPicker: View {
    @Binding var picked: Set<Int>

    var body: some View {
        let order = [2, 3, 0, 1]
        let size: CGFloat = 112
        let gap: CGFloat = 6
        let pad = (size - gap * 3) / 2
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .pixelBorder(RoundedRectangle(cornerRadius: 26, style: .continuous), Color.white.opacity(0.12))
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { c in
                            let b = order[r * 2 + c]
                            let on = picked.contains(b)
                            Button {
                                withAnimation(Theme.Motion.spring) {
                                    if on { picked.remove(b) } else if picked.count < 3 { picked.insert(b) }
                                }
                                Sounds.shared.detent(pitch: on ? 0.85 : 1.15, volume: 0.4)
                            } label: {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.45), Theme.buttons],
                                                                            startPoint: .top, endPoint: .bottom))
                                             : AnyShapeStyle(Color.white.opacity(0.10)))
                                    .overlay {
                                        Image(systemName: on ? "checkmark" : "plus")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(on ? Color.black.opacity(0.7) : Color.white.opacity(0.45))
                                    }
                                    .shadow(color: on ? Theme.buttons.opacity(0.6) : .clear, radius: 6)
                                    .frame(width: pad, height: pad)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .help(AppModel.buttonName(b))
                            .accessibilityLabel(Text(verbatim: AppModel.buttonName(b)))
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            Circle()
                .fill(RadialGradient(colors: [Theme.orbCyan, Theme.orbBlue, Theme.orbViolet], center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 0, endRadius: 18))
                .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 3))
                .frame(width: 34, height: 34)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .dark)
    }
}
