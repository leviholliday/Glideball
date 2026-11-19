import AppKit
import SwiftUI

// MARK: - The time left

/// A try's time left as a fraction (1 just tried on, 0 at the end) and as "0:14", redrawn
/// while a try runs (30 times a second for the ring, so it drains smoothly; with Reduce
/// Motion once a second) and never otherwise.
struct TryOnClock<Content: View>: View {
    let tryOn: TryOn
    @ViewBuilder let content: (_ fraction: Double, _ text: String) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if TryOn.sandboxRemaining != nil || tryOn.session == nil {
            frame(Date())
        } else {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1.0 / 30)) { context in frame(context.date) }
        }
    }

    private func frame(_ date: Date) -> Content {
        let left = tryOn.remaining(at: date)
        return content(left / TryOn.trial, Self.text(left))
    }

    /// "0:14": whole seconds, rounded up (it says 0:01 until it's over).
    static func text(_ left: Double) -> String {
        let s = Int(left.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The time left as a ring of the buttons' amber that drains clockwise.
struct TryOnRing: View {
    let fraction: Double
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Theme.buttons.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Theme.buttons, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.buttons.opacity(0.6), radius: 3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - The pill

/// "Trying Media · 0:14   Put mine back   Keep": over the window's title bar while a
/// preset is tried with Glideball in front, and the same in the floating panel
/// (`TryOnHUD`) while you try it in another app.
struct TryOnPill: View {
    let tryOn: TryOn
    /// In the floating panel over other apps (Esc and Return don't reach it there).
    var floating = false

    var body: some View {
        if let s = tryOn.session {
            TryOnClock(tryOn: tryOn) { fraction, time in
                HStack(spacing: 10) {
                    TryOnRing(fraction: fraction)
                    HStack(spacing: 0) {
                        Text("Trying \(s.name)", comment: "Try for 10 s: the countdown's title; %@ is a value or a preset's name")
                            .font(.system(size: 12, weight: .semibold))
                        Text(verbatim: " · " + time)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    Button("Put mine back") { tryOn.putBack() }
                        .controlSize(.small)
                        .help(floating ? String(localized: "Put your own buttons back now")
                                       : String(localized: "Put your own buttons back now (Esc)"))
                    Button("Keep") { tryOn.keep() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.buttons)
                        .controlSize(.small)
                        .help(floating ? String(localized: "Make this preset yours. You can undo it.")
                                       : String(localized: "Make this preset yours. You can undo it. (Return)"))
                }
                .padding(.leading, 10)
                .padding(.trailing, 7)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.buttons.opacity(0.45), lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Trying \(s.name)", comment: "Try for 10 s: the countdown's title; %@ is a value or a preset's name"))
                .accessibilityValue(Text(verbatim: time))
            }
        }
    }
}

// MARK: - The floating panel

/// While a preset is tried and Glideball's window doesn't have the keys (you went to another
/// app to try it), a small panel at the top of the screen shows the time left with Keep and
/// Put mine back. It never takes the keys or brings Glideball forward (a non-activating
/// panel that can't become key), sits on every Space and over full-screen apps, can't be
/// hidden with Glideball, and is only as big as the pill, so it never catches a click that
/// isn't on it. It's taken down the moment the try ends, whichever way (`TryOn.syncHUD`).
/// Never in `--render-ui` or `--self-test`.
@MainActor
enum TryOnHUD {
    private static var panel: NSPanel?

    static var isShowing: Bool { panel != nil }

    static func show(_ on: Bool, _ tryOn: TryOn) {
        guard !Sandbox.isActive else { return }
        if on { present(tryOn) } else { dismiss() }
    }

    /// The panel as it's made (the self-test checks these without putting it on screen).
    static func make(_ tryOn: TryOn) -> NSPanel {
        let host = FirstClickHost(rootView: TryOnPill(tryOn: tryOn, floating: true).fixedSize())
        let size = host.fittingSize
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.canHide = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.worksWhenModal = true
        p.contentView = host
        return p
    }

    private static func present(_ tryOn: TryOn) {
        guard panel == nil else { return }
        let p = make(tryOn)
        // At the top of the screen the pointer is on, just under the menu bar.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame, size = p.frame.size
        p.setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: (f.maxY - size.height - 10).rounded()))
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { c in
            c.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.16
            p.animator().alphaValue = 1
        }
    }

    /// Gone at once: whatever ended the try, nothing of it stays on screen.
    static func dismiss() {
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
        p.contentView = nil
    }
}

/// Never the key window: typing stays with the app you're in.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Its buttons work on the first click, without Glideball coming forward.
private final class FirstClickHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
