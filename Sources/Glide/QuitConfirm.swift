import AppKit
import SwiftUI

/// ⌘Q asks first, the way Arc and Dia do: a small glass card in the middle of
/// the screen, "Quit Glideball?", with keycaps for the answer. ⌘Q again quits,
/// Esc (or clicking anywhere else) stays.
///
/// Only Glideball's own Quit asks (the menu, ⌘Q, the menu-bar icon's Quit).
/// Logging out, restarting, the Dock's Quit, `killall` and the updater's
/// relaunch never come through here (`AppDelegate` tells them apart), so they
/// never wait on it. It can never trap anyone: a second ⌘Q always quits, and
/// if anything else is holding the screen (an alert, a save panel) it quits
/// without asking. "Don't ask again" turns it off (`AppModel.confirmQuit`;
/// Settings › General turns it back on).
@MainActor
enum QuitConfirm {
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    /// "Don't ask again" ticked on the card that's showing.
    private static let state = CardState()

    enum Decision: Equatable { case ask, quit }

    /// What ⌘Q does: ask, or quit now (asking is off, the card is already up, or something modal is up).
    static func decide(confirm: Bool, showing: Bool, modal: Bool) -> Decision {
        confirm && !showing && !modal ? .ask : .quit
    }

    static var isShowing: Bool { panel != nil }

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
        state.dontAsk = false
        let size = NSSize(width: 460 + 80, height: 172 + 80)
        let p = CardPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .modalPanel
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: QuitCardArrival(state: state) {
            QuitCard(state: state, quit: { quit() }, stay: { close() })
        })
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.06))
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        panel = p
        DispatchQueue.main.async { state.shown = true }

        // Esc stays. (⌘Q again comes through `ask`, which quits.)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard panel != nil else { return e }
            if e.keyCode == 53 { close(); return nil }   // esc
            return e
        }
        // Switching to another app (or clicking the desktop) is "stay".
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    /// Quits for real, from a run-loop turn (never from inside an animation's or a
    /// main-queue block: quitting from there can deadlock).
    private static func quit() {
        if state.dontAsk { AppModel.shared.confirmQuit = false }
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
    static func preview(dontAsk: Bool = false) -> some View {
        let s = CardState()
        s.dontAsk = dontAsk
        s.shown = true
        return QuitCard(state: s, quit: {}, stay: {})
    }
}

@MainActor @Observable
final class QuitCardState {
    var shown = false
    var dontAsk = false
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

/// "Quit Glideball?" on glass, lit faintly from the top by the orb's light.
struct QuitCard: View {
    @Bindable var state: QuitCardState
    let quit: () -> Void
    let stay: () -> Void
    @Environment(\.colorScheme) private var scheme

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
                Toggle("Don’t ask again", isOn: $state.dontAsk)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("⌘Q quits straight away. Turn asking back on in Settings › General.")
                Spacer(minLength: 8)
                answer("Stay", keys: ["esc"], prominent: false, action: stay)
                answer("Quit", keys: ["⌘", "Q"], prominent: true, action: quit)
            }
        }
        .padding(20)
        .frame(width: 460, height: 172, alignment: .topLeading)
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

    private func answer(_ title: LocalizedStringKey, keys: [String], prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 2) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(label: $0.element) }
                }
                .scaleEffect(0.9)
                .accessibilityHidden(true)
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                let s = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if prominent {
                    s.fill(LinearGradient(colors: [Theme.ball, Theme.ball.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                } else {
                    s.fill(Theme.groupFill).overlay(s.strokeBorder(Theme.groupBorder, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
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
