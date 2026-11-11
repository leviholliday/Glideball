import AppKit
import Observation
import SwiftUI

/// The tabs of Glideball › Settings… (⌘,). The raw value is what's saved, and
/// what `glideball://settings?tab=` uses (Commands.swift).
enum SettingsPane: String, CaseIterable {
    case general, look, updates, privacy, shortcuts

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "Settings tab")
        case .look: String(localized: "Look & Sound", comment: "Settings tab: app icon, animations and sounds")
        case .updates: String(localized: "Updates", comment: "Settings tab")
        case .privacy: String(localized: "Privacy", comment: "Settings tab")
        case .shortcuts: String(localized: "Shortcuts", comment: "Settings tab: keyboard shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .look: "paintpalette"
        case .updates: "arrow.down.circle"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        }
    }
}

/// A row Settings was opened to show (the external-control notice opens
/// General at "Allow Raycast and scripts"): it glows softly for a moment.
@Observable
final class SettingsSpotlight {
    static let shared = SettingsSpotlight()
    private(set) var row: String?
    @ObservationIgnored private var generation = 0

    func show(_ row: String) {
        generation += 1
        let mine = generation
        self.row = row
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.generation == mine { self?.row = nil }
        }
    }
}

/// The Settings window, made like a Mac app's preferences: the tabs as icons in
/// the toolbar, and a window as tall as the tab it shows. Switching tabs empties
/// it, eases it to the new tab's height (its top edge stays put), then fades the
/// new tab in with a small rise. Escape closes it. One instance, kept while
/// Glideball runs; it works with the main window closed and with no Dock icon.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let lastPaneKey = "GlideSettingsPane"
    /// Every tab is this wide; only the height changes.
    static let width: CGFloat = 620

    private(set) var current: SettingsPane
    private var pages: [SettingsPane: NSHostingView<AnyView>] = [:]
    /// Each tab's height as its content last reported it.
    private var heights: [SettingsPane: CGFloat] = [:]
    private let container = FlippedView()
    private var switching = false
    /// Bumped with every switch, so a slower one never finishes over a newer one.
    private var generation = 0

    init() {
        current = UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        let window = SettingsNSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(name: nil) { Theme.isDark($0) ? NSColor(srgbHex: 0x121216) : .windowBackgroundColor }
        // Over a full-screen window rather than off on another Space.
        window.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
        window.contentView = container
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "GlideSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        select(current, animated: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Brings Settings forward (on `pane`, or wherever it was left), activating
    /// Glideball so the window comes to the front even without a Dock icon.
    /// `spotlight` names a row to point out (see `SettingsSpotlight`).
    func show(_ pane: SettingsPane? = nil, spotlight: String? = nil) {
        if let pane, pane != current { select(pane, animated: window?.isVisible == true) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let spotlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { SettingsSpotlight.shared.show(spotlight) }
        }
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { .init($0.rawValue) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { .init($0.rawValue) }
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { .init($0.rawValue) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    @objc private func pick(_ item: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: item.itemIdentifier.rawValue) else { return }
        select(pane, animated: true)
    }

    // MARK: Pages

    /// Each tab is made once and kept, so a half-typed search or a result line stays put.
    private func page(_ pane: SettingsPane) -> NSHostingView<AnyView> {
        if let made = pages[pane] { return made }
        let content = Self.view(for: pane, model: AppModel.shared)
            .frame(width: Self.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                self?.heightChanged(pane, to: height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.windowBackground)
        let view = NSHostingView(rootView: AnyView(content))
        view.sizingOptions = []   // the window's size is ours to animate
        pages[pane] = view
        return view
    }

    /// How tall `pane` wants to be.
    private func height(of pane: SettingsPane) -> CGFloat {
        if let h = heights[pane] { return h }
        let measured = NSHostingController(rootView: Self.view(for: pane, model: AppModel.shared)
            .frame(width: Self.width).fixedSize(horizontal: false, vertical: true))
            .sizeThatFits(in: NSSize(width: Self.width, height: 10_000)).height
        heights[pane] = measured
        return measured
    }

    /// The window's frame for a content height, its top edge where it is now.
    private func frame(forContentHeight h: CGFloat) -> NSRect? {
        guard let w = window else { return nil }
        var frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: max(h, 80)))
        frame.origin.x = w.frame.origin.x
        frame.origin.y = w.frame.maxY - frame.height
        return frame
    }

    /// Shows `pane`. Animated: the old tab goes, the window eases to the new one's
    /// height, then the new tab fades in with a 6 pt rise (a plain fade with Reduce
    /// Motion). Another click part-way through simply takes over.
    func select(_ pane: SettingsPane, animated: Bool) {
        guard let w = window else { return }
        generation += 1
        let mine = generation
        current = pane
        UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey)
        w.title = pane.title
        w.toolbar?.selectedItemIdentifier = .init(pane.rawValue)
        let view = page(pane)
        let h = height(of: pane)
        guard let target = frame(forContentHeight: h) else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 1

        guard animated, w.isVisible else {
            switching = false
            w.setFrame(target, display: true)
            view.frame = container.bounds
            container.addSubview(view)
            return
        }
        switching = true
        let rise: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.tabRise
        let fadeIn = { [weak self] in
            guard let self, self.generation == mine else { return }
            view.frame = self.container.bounds.offsetBy(dx: 0, dy: rise)
            view.alphaValue = 0
            self.container.addSubview(view)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
                view.animator().frame = self.container.bounds
            }, completionHandler: { [weak self] in
                guard let self, self.generation == mine else { return }
                self.switching = false
                // It may have changed height while it was on its way in.
                if let h = self.heights[pane], let target = self.frame(forContentHeight: h),
                   abs(target.height - w.frame.height) > 0.5 {
                    w.animator().setFrame(target, display: true)
                }
            })
        }
        if abs(target.height - w.frame.height) < 0.5 {
            fadeIn()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(target, display: true)
        }, completionHandler: fadeIn)
    }

    /// A tab's content grew or shrank (a result line, the Relaunch button, a
    /// note): the window follows, its top edge staying put.
    private func heightChanged(_ pane: SettingsPane, to h: CGFloat) {
        guard h > 1 else { return }
        let old = heights[pane]
        heights[pane] = h
        guard pane == current, !switching, let w = window, let old, abs(old - h) > 0.5,
              let target = frame(forContentHeight: h) else { return }
        guard w.isVisible else { w.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(target, display: true)
        }
    }

    @MainActor @ViewBuilder
    private static func view(for pane: SettingsPane, model: AppModel) -> some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .look: LookSettingsPane(model: model)
        case .updates: UpdatesSettingsPane(model: model)
        case .privacy: PrivacySettingsPane()
        case .shortcuts: ShortcutsSettingsPane(model: model)
        }
    }
}

/// Top-left origin, so a tab sits at the top while the window eases around it.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Escape closes Settings, as it does other Mac settings windows. A field being
/// typed in lets go of the keyboard first, and a shortcut being recorded takes
/// Escape itself (its key monitor comes first).
private final class SettingsNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if firstResponder is NSText {
            makeFirstResponder(nil)
            return
        }
        performClose(sender)
    }
}
