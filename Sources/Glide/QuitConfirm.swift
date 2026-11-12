import AppKit
import SwiftUI

/// ⌘Q asks first, the way Arc and Dia do: a small glass card in the middle of
/// the screen, "Quit Glideball?", and three big answers. Return (or ⌘Q again)
/// quits, Esc (or clicking anywhere else) cancels, and "Always quit", which only
/// a click can reach, quits and stops asking.
///
/// Only Glideball's own Quit asks (the menu, ⌘Q, the menu-bar icon's Quit).
/// Logging out, restarting, the Dock's Quit, `killall` and the updater's
/// relaunch never come through here (`AppDelegate` tells them apart), so they
/// never wait on it. It can never trap anyone: a second ⌘Q always quits, and
/// if anything else is holding the screen (an alert, a save panel) it quits
/// without asking. "Always quit" turns asking off (`AppModel.confirmQuit`;
/// Settings › General turns it back on).
@MainActor
enum QuitConfirm {
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static let state = CardState()

    enum Decision: Equatable { case ask, quit }

    /// What ⌘Q does: ask, or quit now (asking is off, the card is already up, or something modal is up).
    static func decide(confirm: Bool, showing: Bool, modal: Bool) -> Decision {
        confirm && !showing && !modal ? .ask : .quit
    }

    /// What a key does while the card is up: Return and Enter quit, Esc cancels,
    /// anything else (Space included) does nothing. Nothing reaches "Always quit".
    enum KeyAnswer: Equatable { case quit, cancel, none }
    static func answer(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyAnswer {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case 36, 76: return mods.isEmpty ? .quit : .none   // return, keypad enter
        case 53: return .cancel                             // esc
        default: return .none
        }
    }

    static var isShowing: Bool { panel != nil }

    static let cardSize = NSSize(width: 480, height: 168)

    /// ⌘Q (or Quit in a menu).
    static func ask() {
        switch decide(confirm: AppModel.shared.confirmQuit, showing: isShowing, modal: NSApp.modalWindow != nil) {
        case .quit: quit()
        case .ask: show()
        }
    }

    private static func show() {
        // `--self-test` checks the decision and draws the card, but never puts a window on screen.
        guard !Sandbox.isActive else { return }
        state.shown = false
        let size = NSSize(width: cardSize.width + 80, height: cardSize.height + 80)
        let p = CardPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .modalPanel
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: QuitCardArrival(state: state) {
            QuitCard(quit: { quit() }, alwaysQuit: { alwaysQuit() }, cancel: { close() })
        })
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.06))
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        // Nothing on the card holds the keyboard, so Return and Space can't press a button by accident.
        p.makeFirstResponder(nil)
        panel = p
        DispatchQueue.main.async { state.shown = true }

        // Return quits, Esc cancels. (⌘Q again comes through `ask`, which quits.)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard panel != nil else { return e }
            switch answer(keyCode: e.keyCode, modifiers: e.modifierFlags) {
            case .quit: quit(); return nil
            case .cancel: close(); return nil
            case .none:
                // ⌘Q goes on to `ask`; other keys stop here so nothing behind the card reacts.
                return e.modifierFlags.contains(.command) ? e : nil
            }
        }
        // Switching to another app (or clicking the desktop) is "cancel".
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    /// "Always quit": asking goes off for good (Settings › General turns it back on), then quit.
    private static func alwaysQuit() {
        AppModel.shared.confirmQuit = false
        quit()
    }

    /// Quits for real, from a run-loop turn (never from inside an animation's or a
    /// main-queue block: quitting from there can deadlock).
    private static func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.quitNow()
                // Still here (something cancelled it): the card mustn't stay up.
                close()
            }
        }
    }

    static func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let p = panel else { return }
        panel = nil
        state.shown = false
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.14
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    /// For --render-ui and --self-test.
    static func preview() -> some View {
        QuitCard(quit: {}, alwaysQuit: {}, cancel: {})
    }
}

@MainActor @Observable
final class QuitCardState {
    var shown = false
}
private typealias CardState = QuitCardState

/// A borderless panel that still takes the keyboard.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The card drops in a few points and is solid in about 0.14 s. Reduce Motion: just the fade.
private struct QuitCardArrival<Content: View>: View {
    let state: QuitCardState
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .scaleEffect(state.shown || reduceMotion ? 1 : 0.96)
            .offset(y: state.shown || reduceMotion ? 0 : -10)
            .animation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.32), value: state.shown)
            .opacity(state.shown ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: state.shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Quit Glideball?" on glass, lit faintly from the top by the orb's light, with
/// three big answers: Always quit on its own at the left, Cancel and Quit at the right.
struct QuitCard: View {
    let quit: () -> Void
    let alwaysQuit: () -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    private enum Look { case quiet, cancel, quit }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: AppIconChoice.shared.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quit Glideball?")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your trackball goes back to plain macOS. Closing the window keeps Glideball running.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                answer(Text("Always quit"), keys: [], look: .quiet, action: alwaysQuit)
                    .help("Quits now and stops asking. Turn asking back on in Settings › General.")
                Spacer(minLength: 8)
                answer(Text("Cancel"), keys: ["esc"], look: .cancel, action: cancel)
                answer(Text("Quit"), keys: ["↵"], look: .quit, action: quit)
            }
        }
        .padding(20)
        .frame(width: QuitConfirm.cardSize.width, height: QuitConfirm.cardSize.height, alignment: .topLeading)
        .background {
            ZStack {
                CardGlass()
                Theme.raised.opacity(0.72)
                Rectangle()
                    .fill(EllipticalGradient(colors: [Theme.orbBlue.opacity(scheme == .dark ? 0.32 : 0.14),
                                                      Theme.orbViolet.opacity(scheme == .dark ? 0.12 : 0.05), .clear],
                                             center: UnitPoint(x: 0.15, y: 0), startRadiusFraction: 0, endRadiusFraction: 0.7))
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.surfaceHighlight, Theme.groupBorder],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 26, y: 12)
        .accessibilityElement(children: .contain)
    }

    /// A big answer: 36 pt tall, its keycap (if it has one) in the button's own ink.
    /// None of them takes keyboard focus: Return and Esc are handled by the card itself,
    /// so "Always quit" can only ever be clicked.
    private func answer(_ title: Text, keys: [String], look: Look, action: @escaping () -> Void) -> some View {
        let filled = look == .quit
        return Button(action: action) {
            HStack(spacing: 8) {
                title.font(.system(size: 13, weight: .semibold))
                if !keys.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                            Text(verbatim: key)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .frame(minWidth: 20, minHeight: 20)
                                .padding(.horizontal, key.count > 1 ? 4 : 0)
                                .background {
                                    let k = RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    k.fill(filled ? Color.white.opacity(0.2) : Theme.raised)
                                        .overlay(k.strokeBorder(filled ? Color.white.opacity(0.3) : Theme.groupBorder, lineWidth: 1))
                                }
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, keys.isEmpty ? 16 : 9)
            .frame(height: 36)
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                let s = RoundedRectangle(cornerRadius: 11, style: .continuous)
                if filled {
                    s.fill(LinearGradient(colors: [Theme.bad, Theme.bad.mix(with: .black, by: 0.12)], startPoint: .top, endPoint: .bottom))
                        .overlay(s.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                } else {
                    s.fill(Theme.groupFill).overlay(s.strokeBorder(Theme.groupBorder, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .focusable(false)
    }
}

/// The frosted glass behind the card (the desktop shows through, blurred).
private struct CardGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
