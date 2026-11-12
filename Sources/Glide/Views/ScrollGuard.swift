import AppKit
import SwiftUI

// A scroll area inside the scrolling page ("Try it here" on Scrolling) used to
// grab the page's scroll the moment it slid under the pointer: you'd be
// scrolling down the page, hit the list, and be stuck scrolling the list to
// its end before the page would move again.
//
// Now a nested area only takes the scroll once you mean it: after a click in
// it, or once the pointer has rested in it for 0.6 s without scrolling. Until
// then every scroll goes on to the page, and a quiet "Click to try it" sits
// over it. Moving the pointer out lets it go again.

extension View {
    /// Keeps this scroll area from capturing a scroll that started outside it (see above).
    /// "Click to try it" shows over it until it's taking the scroll.
    func scrollCaptureGuard() -> some View {
        modifier(ScrollCaptureGuard())
    }
}

/// `--render-ui`: draw guarded areas as if they'd been clicked.
enum ScrollCaptureSandbox {
    nonisolated(unsafe) static var active = false
}

private struct ScrollCaptureGuard: ViewModifier {
    @State private var active = ScrollCaptureSandbox.active

    func body(content: Content) -> some View {
        content
            .overlay { ScrollCatcher(active: $active) }
            .overlay(alignment: .bottom) {
                if !active {
                    Label("Click to try it", systemImage: "cursorarrow.click")
                        .font(Theme.Font.hint.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Theme.groupBorder, lineWidth: 1))
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.fade, value: active)
    }
}

/// A transparent view over the area. While the area isn't active it takes the
/// scroll wheel and clicks: scrolls go on to the page, a click (or a rest)
/// activates. While active it lets everything through and only watches for
/// the pointer leaving.
private struct ScrollCatcher: NSViewRepresentable {
    @Binding var active: Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onChange = { active = $0 }
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onChange = { active = $0 }
        if v.active != active { v.active = active }
    }

    final class CatcherView: NSView {
        var active = false
        var onChange: ((Bool) -> Void)?
        private var rest: Timer?
        static let restTime = 0.6

        override func hitTest(_ point: NSPoint) -> NSView? {
            active ? nil : super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            // Scrolling isn't resting: start the wait over, and let the page have it.
            restartRest()
            if let page = enclosingScrollView { page.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }

        override func mouseDown(with event: NSEvent) { set(true) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { restartRest() }
        override func mouseMoved(with event: NSEvent) { if !active { restartRest() } }
        override func mouseExited(with event: NSEvent) {
            rest?.invalidate()
            set(false)
        }

        private func restartRest() {
            rest?.invalidate()
            guard !active else { return }
            let t = Timer(timeInterval: Self.restTime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.restEnded() }
            }
            RunLoop.main.add(t, forMode: .common)
            rest = t
        }

        /// Activates only if the pointer is still over the area.
        private func restEnded() {
            guard let window, window.isKeyWindow else { return }
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p) { set(true) }
        }

        private func set(_ on: Bool) {
            guard on != active else { return }
            active = on
            onChange?(on)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { rest?.invalidate() }
        }
    }
}
