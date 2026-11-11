import AppKit
import SwiftUI

/// Buttons: what each one does, in one group. There's no picture of the
/// trackball here: the sidebar's is the diagram, and pressing a real button
/// lights up both its corner there and its row here.
struct ButtonsView: View {
    @Bindable var model: AppModel

    private let buttons: [(index: Int, name: String, normally: String)] = (0..<4).map {
        ($0, AppModel.buttonName($0), AppModel.buttonDefault($0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            AssignPanel(model: model)

            SectionBlock(title: "Your buttons", caption: "Press a button on your trackball: its row lights up.",
                         dividerInset: ButtonRow.dividerInset) {
                ForEach(buttons, id: \.index) { b in
                    ButtonRow(index: b.index, name: b.name, normally: b.normally,
                              isPressed: model.pressed.contains(b.index),
                              action: Binding(
                                get: { model.config.buttons[b.index] ?? .system },
                                set: { model.config.buttons[b.index] = $0 }))
                }
            }

            CombosCard(model: model)
            ButtonPresetCard(model: model)
        }
        // While you're on this page with Glideball in front, a real button answers with a soft
        // click down and a lower one up (Sounds on). Not the primary button: that's the one you
        // click this window with, and it would tick at every click.
        .onChange(of: model.pressed) { old, new in
            guard model.windowIsKey else { return }
            let down = new.subtracting(old).subtracting([0]), up = old.subtracting(new).subtracting([0])
            if !down.isEmpty { Sounds.shared.detent(pitch: 1.05, volume: 0.45) }
            else if !up.isEmpty { Sounds.shared.detent(pitch: 0.8, volume: 0.3) }
        }
    }
}

/// One-click button setups. Applying one changes only its own buttons and
/// combo; each can be changed back with the rows and Combos as usual.
struct ButtonPresetCard: View {
    let model: AppModel

    var body: some View {
        let applied = model.config.hasSpacesAndWisprFlow
        SectionBlock(title: "Presets") {
            SettingRow(title: "Spaces + Wispr Flow",
                       hint: "Top buttons switch Spaces; bottom left + both top buttons hold ⌃Space for Wispr Flow.",
                       symbol: "square.on.square.dashed") {
                if applied {
                    Label("Applied", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Button("Apply") {
                        withAnimation(Theme.Motion.spring) { model.applySpacesAndWisprFlow() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// A button's row: which corner it is, what it does normally, and what it does now.
/// Lights up amber while the real button is down (80 ms in, 250 ms out).
struct ButtonRow: View {
    let index: Int
    let name: String
    let normally: String
    let isPressed: Bool
    @Binding var action: ButtonAction

    @State private var recording = false
    @State private var monitor: Any?
    @State private var pulse = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let dividerInset = Theme.Space.rowHorizontal + 26 + Theme.Space.symbolGap

    var body: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            CornerGlyph(index: index, lit: isPressed)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(index == 0 ? String(localized: "Your primary click stays a left click, so Glideball can never lock you out.")
                                : String(localized: "Normally: \(normally)"))
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if index == 0 {
                Label("Left click", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(TrailingIconLabelStyle())
                    .help("Your primary click stays a left click, so Glideball can never lock you out.")
                    .accessibilityLabel("Left click · locked")
            } else if recording {
                Text("Type a shortcut…  esc to cancel")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Theme.buttons, lineWidth: 1))
            } else {
                Menu {
                    ForEach(ButtonAction.presets) { p in
                        Button {
                            action = p.action
                        } label: {
                            Label(p.title, systemImage: p.symbol)
                        }
                    }
                    Divider()
                    Button {
                        startRecording()
                    } label: {
                        Label("Record custom shortcut…", systemImage: "record.circle")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.symbol)
                        Text(action.title)
                        if let d = action.detail, action.title != d {
                            Text(d).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .background {
            ZStack(alignment: .leading) {
                Theme.buttons.opacity(isPressed ? 0.16 : 0)
                // The edge nearest the trackball lights first…
                LinearGradient(colors: [Theme.buttons.opacity(0.9), Theme.buttons.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 3)
                    .opacity(isPressed ? 1 : 0)
                    .shadow(color: Theme.buttons, radius: 6)
                // …and a pulse of light runs across the row from that side.
                GeometryReader { g in
                    LinearGradient(colors: [Theme.buttons.opacity(0), Theme.buttons.opacity(0.35), Theme.buttons.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 140)
                        .offset(x: -140 + (g.size.width + 140) * pulse)
                        .opacity(pulse < 1 && pulse > 0 ? 1 : 0)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(isPressed ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: isPressed)
        .onChange(of: isPressed) { _, down in
            guard down, !reduceMotion else { return }
            pulse = 0.001
            withAnimation(.easeOut(duration: 0.45)) { pulse = 1 }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // esc
                stopRecording()
                return nil
            }
            action = .shortcut(KeyCapture.shortcut(from: event))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Which corner a button is: a little 2×2 of the trackball's pads with that
/// one filled (amber while the real button is down).
struct CornerGlyph: View {
    let index: Int
    var lit = false

    var body: some View {
        // macOS numbers them 0 bottom left, 1 bottom right, 2 top left, 3 top right.
        let order = [2, 3, 0, 1]
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        let b = order[row * 2 + col]
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(b == index ? (lit ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.secondary))
                                             : AnyShapeStyle(Theme.hairline))
                            .frame(width: 9, height: 9)
                            .shadow(color: b == index && lit ? Theme.buttons : .clear, radius: 4)
                            .scaleEffect(b == index && lit ? 0.88 : 1)
                    }
                }
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// Text first, then the icon (for "Left click 🔒").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.system(size: 10))
        }
    }
}
