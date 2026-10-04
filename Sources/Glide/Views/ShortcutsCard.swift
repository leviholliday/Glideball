import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Overview › Keyboard shortcuts: Glide's system-wide shortcuts, recorded in place.
struct KeyboardShortcutsCard: View {
    @Bindable var model: AppModel
    @State private var recording: GlobalShortcuts.Action?
    @State private var refusal: (action: GlobalShortcuts.Action, text: String)?
    @State private var monitor: Any?
    @State private var recordingID = UUID()

    private var shortcuts: GlobalShortcuts { model.config.globalShortcuts }

    var body: some View {
        GlassCard(title: "Keyboard shortcuts", symbol: "command") {
            ForEach(GlobalShortcuts.Action.allCases) { action in
                if action != GlobalShortcuts.Action.allCases.first { Divider().opacity(0.4) }
                row(action)
            }
            Text("They work in every app, even with this window closed. Click a shortcut to record a new one; Esc cancels.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private func row(_ action: GlobalShortcuts.Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.system(size: 14, weight: .medium))
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if action == .pause, shortcuts.pause?.sameKeys(as: GlobalShortcuts.defaultPause) != true, recording != action {
                    Button {
                        set(action, GlobalShortcuts.defaultPause)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass)
                    .help("Go back to \(GlobalShortcuts.defaultPause.display)")
                }
                recorder(action)
                if shortcuts[action] != nil, recording != action {
                    Button {
                        set(action, nil)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .help("Remove this shortcut")
                }
            }
            if let note = note(for: action) {
                Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(note.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            }
        }
    }

    @ViewBuilder private func recorder(_ action: GlobalShortcuts.Action) -> some View {
        let isRecording = recording == action
        let button = Button {
            if isRecording { stopRecording() } else { startRecording(action) }
        } label: {
            Group {
                if isRecording {
                    Text("Type shortcut…")
                } else if let s = shortcuts[action] {
                    Text(s.display).font(.system(size: 13, weight: .semibold, design: .rounded))
                } else {
                    Text("Record Shortcut").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 112)
        }
        .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click, then press a new shortcut")
        if isRecording {
            button.buttonStyle(.glassProminent).tint(.cyan.opacity(0.7))
        } else {
            button.buttonStyle(.glass)
        }
    }

    private struct Note {
        let text: String
        var warning = true
    }

    private func note(for action: GlobalShortcuts.Action) -> Note? {
        if let refusal, refusal.action == action { return Note(text: refusal.text) }
        guard recording != action else { return nil }
        guard let s = shortcuts[action] else {
            return action == .pause
                ? Note(text: "No pause shortcut. You can still pause Glide from its menu-bar icon or the switch at the top of this window.")
                : nil
        }
        if GlobalHotKeys.shared.failed.contains(action) {
            return Note(text: "Couldn't turn on \(s.display) — another app already uses it. Choose a different shortcut.")
        }
        if GlobalHotKeys.systemUses(s) {
            return Note(text: "macOS uses \(s.display) for one of its own shortcuts (System Settings › Keyboard › Keyboard Shortcuts), so it may never reach Glide.")
        }
        if s.flags.intersection([.maskControl, .maskAlternate]).isEmpty {
            return Note(text: "Apps use ⌘ shortcuts like \(s.display) too — while it's set, Glide takes it from every app.", warning: false)
        }
        return nil
    }

    private func set(_ action: GlobalShortcuts.Action, _ shortcut: KeyShortcut?) {
        refusal = nil
        model.config.globalShortcuts[action] = shortcut
    }

    private func startRecording(_ action: GlobalShortcuts.Action) {
        stopRecording()
        refusal = nil
        recording = action
        // Otherwise pressing a shortcut Glide already has would fire it instead of recording it.
        GlobalHotKeys.shared.suspend()
        let id = UUID()
        recordingID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if recordingID == id { stopRecording() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape), mods.isEmpty {
                stopRecording()
                return nil
            }
            let shortcut = KeyCapture.shortcut(from: event)
            if let problem = shortcuts.refusal(for: shortcut, as: action) {
                refusal = (action, problem)   // keep listening for a better one
                return nil
            }
            set(action, shortcut)
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
