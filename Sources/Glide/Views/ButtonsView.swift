import AppKit
import SwiftUI

struct ButtonsView: View {
    @Bindable var model: AppModel

    private let buttons: [(index: Int, name: String, normally: String)] = (0..<4).map {
        ($0, AppModel.buttonName($0), AppModel.buttonDefault($0))
    }

    var body: some View {
        VStack(spacing: 18) {
        AssignPanel(model: model)
        HStack(alignment: .top, spacing: 18) {
            GlassCard {
                TrackballView(pressed: model.pressed, ballSpeed: model.liveBallSpeed,
                              notchRate: model.liveNotchRate, ringAngle: model.ringAngle,
                              ballPhase: model.ballPhase)
                Text("Press a button on your trackball — its row lights up.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 270)

            VStack(spacing: 12) {
                ForEach(buttons, id: \.index) { b in
                    ButtonRow(index: b.index, name: b.name, normally: b.normally,
                              isPressed: model.pressed.contains(b.index),
                              action: Binding(
                                get: { model.config.buttons[b.index] ?? .system },
                                set: { model.config.buttons[b.index] = $0 }))
                }
                CombosCard(model: model)
            }
        }
        }
    }
}

struct ButtonRow: View {
    let index: Int
    let name: String
    let normally: String
    let isPressed: Bool
    @Binding var action: ButtonAction

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isPressed ? Color.cyan : Color.white.opacity(0.12))
                    .shadow(color: isPressed ? .cyan : .clear, radius: 10)
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(isPressed ? .black : .primary)
            }
            .frame(width: 34, height: 34)
            .animation(.easeOut(duration: 0.12), value: isPressed)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15, weight: .semibold))
                Text("Normally: \(normally)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()

            if index == 0 {
                Label("Left click · locked", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .help("Your primary click stays a left click, so Glideball can never lock you out.")
            } else if recording {
                Text("Type a shortcut…  esc to cancel")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(.orange.opacity(0.35)), in: .capsule)
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
                    HStack(spacing: 8) {
                        Image(systemName: action.symbol)
                        Text(action.title).font(.system(size: 13, weight: .medium))
                        if let d = action.detail, action.title != d {
                            Text(d).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
        }
        .padding(16)
        .glassEffect(isPressed ? .regular.tint(.cyan.opacity(0.25)) : .regular, in: .rect(cornerRadius: 22))
        .animation(.easeOut(duration: 0.12), value: isPressed)
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
