import AppKit
import SwiftUI

// The Switcher's panel on screen: a Liquid Glass panel centred on the display the pointer is
// on, the running apps as big icons in a grid (most recent first), the lit one lifted on a
// glass highlight in the ball's blue. The engine decides everything (Switcher.swift,
// Gestures.swift) and hands this a `SwitcherOverlayModel` through `EngineIO.showSwitcher`;
// this builds the app list when a hold starts, draws it, and switches at the release.
//
// Privacy: the list (names, icons, window counts) lives only here, on the main thread, only in
// memory, from the start of a hold until its release (or a few seconds after it). The engine
// only ever sees how many apps there are and how they're laid out. Nothing about which apps
// are running is logged, saved, sent or put in diagnostics. No new permissions: names and
// icons come from NSRunningApplication, window counts from CGWindowList without titles (no
// Screen Recording, no Accessibility).

/// One app in the panel.
struct SwitcherEntry: Identifiable {
    let id: Int
    let name: String
    let icon: NSImage
    /// Its windows on screen now (on this desktop, not minimized): shown when it's 2 or more.
    let windows: Int
    /// Hidden (⌘H): drawn a little dimmer.
    let hidden: Bool
    /// The app itself (nil for render-ui's made-up entries).
    let app: NSRunningApplication?
}

/// The panel's sizes. One cell per app; the grid comes from `SwitcherGrid` (Switcher.swift).
enum SwitcherLayout {
    static let cell = CGSize(width: 112, height: 128)
    static let icon: CGFloat = 76
    static let padding: CGFloat = 22
    static let radius: CGFloat = 30
    /// Never more than this many across (a wider panel stops reading as one glance).
    static let maxColumns = 8
    /// Room around the panel for its shadow and the lit cell's lift and glow.
    static let margin: CGFloat = 40

    /// The panel itself (without the margin) for `grid`.
    static func panelSize(_ grid: SwitcherGrid) -> CGSize {
        CGSize(width: CGFloat(max(1, min(grid.columns, grid.count))) * cell.width + padding * 2,
               height: CGFloat(min(grid.visibleRows, max(1, grid.rows))) * cell.height + padding * 2)
    }

    /// The window: the panel and its margin.
    static func canvas(_ grid: SwitcherGrid) -> CGSize {
        let p = panelSize(grid)
        return CGSize(width: p.width + margin * 2, height: p.height + margin * 2)
    }

    /// The grid that fits on a display whose usable area is `area`: at most 90% of its width
    /// and 80% of its height, so it never runs off screen.
    static func grid(count: Int, in area: CGSize) -> SwitcherGrid {
        let across = Int(((area.width * 0.9) - padding * 2 - margin * 2) / cell.width)
        let down = Int(((area.height * 0.8) - padding * 2 - margin * 2) / cell.height)
        return SwitcherGrid.fitting(count: count, maxColumns: min(maxColumns, max(1, across)), maxRows: max(1, down))
    }
}

/// What the panel shows, observed by the view (main thread only).
@MainActor
@Observable
final class SwitcherOverlayState {
    var entries: [SwitcherEntry] = []
    var model: SwitcherOverlayModel?
    /// Drives the in and out animation: false while it's leaving.
    var shown = false
}

struct SwitcherOverlayView: View {
    let state: SwitcherOverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let m = state.model, !state.entries.isEmpty {
                panel(m)
                    .scaleEffect(state.shown || reduceMotion ? 1 : 0.94)
                    .opacity(state.shown ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func panel(_ m: SwitcherOverlayModel) -> some View {
        let g = m.grid
        let size = SwitcherLayout.panelSize(g)
        let shape = RoundedRectangle(cornerRadius: SwitcherLayout.radius, style: .continuous)
        let cell = SwitcherLayout.cell
        let columns = max(1, g.columns)
        let selected = min(max(0, m.selected), state.entries.count - 1)
        let col = selected % columns, row = selected / columns
        let scrolls = g.rows > g.visibleRows
        return ZStack(alignment: .topLeading) {
            // Everything that scrolls: the highlight under the icons, then the icons.
            ZStack(alignment: .topLeading) {
                SwitcherHighlight()
                    .frame(width: cell.width - 8, height: cell.height - 8)
                    .offset(x: CGFloat(col) * cell.width + 4, y: CGFloat(row) * cell.height + 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<g.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(r * columns..<min(state.entries.count, (r + 1) * columns), id: \.self) { i in
                                SwitcherCell(entry: state.entries[i], lit: i == selected)
                                    .frame(width: cell.width, height: cell.height)
                            }
                        }
                    }
                }
            }
            .offset(y: -CGFloat(m.firstRow) * cell.height)
            .padding(SwitcherLayout.padding)
            // Rows that scroll away end at the panel's own edge (the padding stays room for the glow).
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(shape)
            // Scrolled rows fade out into the padding instead of peeking in at the edge.
            .mask {
                let edge = SwitcherLayout.padding / size.height
                LinearGradient(stops: scrolls
                                   ? [.init(color: .clear, location: 0), .init(color: .black, location: edge),
                                      .init(color: .black, location: 1 - edge), .init(color: .clear, location: 1)]
                                   : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            if scrolls {
                // More rows than fit: quiet chevrons say there's more above or below.
                VStack {
                    Image(systemName: "chevron.compact.up").opacity(m.firstRow > 0 ? 1 : 0)
                    Spacer()
                    Image(systemName: "chevron.compact.down").opacity(m.firstRow + g.visibleRows < g.rows ? 1 : 0)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .glassEffect(.regular, in: shape)
        .overlay {
            // A lit top edge, like light falling on glass.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.28 : 0.7), .white.opacity(scheme == .dark ? 0.04 : 0.15)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 24, y: 10)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.84), value: m.selected)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88), value: m.firstRow)
    }
}

/// The lit cell's glass, in the ball's blue, with a soft glow: the ball lighting it.
struct SwitcherHighlight: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Theme.ball.opacity(0.78), Theme.ball.opacity(0.95)], startPoint: .top, endPoint: .bottom))
            .glassEffect(.regular.tint(Theme.ball.opacity(0.35)), in: shape)
            .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
            .shadow(color: Theme.ball.opacity(0.6), radius: 12)
            .offset(y: -3)
    }
}

/// One app: its icon, big, the window count when there are several, and its name.
struct SwitcherCell: View {
    let entry: SwitcherEntry
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: SwitcherLayout.icon, height: SwitcherLayout.icon)
                .shadow(color: .black.opacity(lit ? 0.3 : 0.18), radius: lit ? 8 : 4, y: lit ? 5 : 2)
                .opacity(entry.hidden && !lit ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if entry.windows >= 2 {
                        Text(entry.windows, format: .number)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(lit ? Color.black.opacity(0.45) : Color.black.opacity(0.55)))
                            .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                            .offset(x: 6, y: -4)
                    }
                }
            Text(verbatim: entry.name)
                .font(.system(size: lit ? 12 : 11, weight: lit ? .semibold : .medium))
                .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .shadow(color: lit ? .black.opacity(0.25) : .clear, radius: 1, y: 0.5)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
        }
        .scaleEffect(lit && !reduceMotion ? 1.06 : 1)
        .offset(y: lit && !reduceMotion ? -3 : 0)
    }
}

// MARK: - The app list

/// The apps in the order you last used them, kept in memory while Glideball runs (never saved):
/// what ⌘-Tab's order is made of. Main thread only.
@MainActor
final class SwitcherRecents {
    static let shared = SwitcherRecents()
    private(set) var order: [pid_t] = []
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication { order = [front.processIdentifier] }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                var o = SwitcherRecents.shared.order
                o.removeAll { $0 == pid }
                o.insert(pid, at: 0)
                SwitcherRecents.shared.order = Array(o.prefix(64))
            }
        }
    }

    /// The running apps with a Dock icon (regular activation policy), ⌘-Tab's order: the one
    /// in front first, then the most recently used, then the rest by their windows' stacking
    /// order, then by launch. With each one's windows on screen.
    func apps() -> [SwitcherEntry] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let (windows, stacking) = Self.windowsByApp()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var rank: [pid_t: Int] = [:]
        var next = 0
        func put(_ pid: pid_t) { if rank[pid] == nil { rank[pid] = next; next += 1 } }
        if let front { put(front) }
        order.forEach(put)
        stacking.forEach(put)
        let sorted = running.enumerated().sorted { a, b in
            let ra = rank[a.element.processIdentifier] ?? Int.max, rb = rank[b.element.processIdentifier] ?? Int.max
            if ra != rb { return ra < rb }
            let la = a.element.launchDate ?? .distantPast, lb = b.element.launchDate ?? .distantPast
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
        return sorted.prefix(96).enumerated().map { i, app in
            let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
            return SwitcherEntry(id: i, name: app.localizedName ?? app.bundleIdentifier ?? "?", icon: icon,
                                 windows: windows[app.processIdentifier] ?? 0, hidden: app.isHidden, app: app)
        }
    }

    /// Each app's normal windows on screen now, and the apps in their windows' front-to-back
    /// order. Only owner, layer, size and alpha are read: no titles, so no Screen Recording.
    static func windowsByApp() -> (counts: [pid_t: Int], stacking: [pid_t]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return ([:], []) }
        var counts: [pid_t: Int] = [:]
        var stacking: [pid_t] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width >= 60, rect.height >= 40
            else { continue }
            counts[pid, default: 0] += 1
            if !stacking.contains(pid) { stacking.append(pid) }
        }
        return (counts, stacking)
    }
}

// MARK: - The window

/// The Switcher's window: borderless, click-through, never key or main, above everything on
/// every Space, just under the stand-in pointer. It never takes focus, so the app in front
/// keeps its selection until you let go.
private final class SwitcherWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {}
}

/// Builds the list, draws the panel and switches apps for the engine (`EngineIO.switcherPresenter`).
/// Main thread only.
@MainActor
final class SwitcherOverlayPanel: SwitcherPresenting {
    static let shared = SwitcherOverlayPanel()

    private let state = SwitcherOverlayState()
    private var window: NSPanel?
    private var leaving: DispatchWorkItem?
    private var lastSelected: Int?
    /// The hold's list and the display it's for. Only the latest hold's, only until it's used.
    private var list: (session: Int, entries: [SwitcherEntry], grid: SwitcherGrid, area: CGRect)?
    private var forget: DispatchWorkItem?

    /// Hooks it up to the engine and starts keeping the order apps were used in. Once, at launch.
    static func install() {
        EngineIO.switcherPresenter = shared
        SwitcherRecents.shared.start()
    }

    nonisolated func prepareSwitcher(session: Int, near point: CGPoint) -> SwitcherGrid {
        MainActor.assumeIsolated { prepare(session: session, near: point) }
    }

    nonisolated func showSwitcher(_ model: SwitcherOverlayModel, near point: CGPoint) {
        MainActor.assumeIsolated { show(model) }
    }

    nonisolated func hideSwitcher() {
        MainActor.assumeIsolated { hide() }
    }

    nonisolated func activateSwitcher(session: Int, index: Int) {
        MainActor.assumeIsolated { activate(session: session, index: index) }
    }

    private func prepare(session: Int, near point: CGPoint) -> SwitcherGrid {
        let entries = SwitcherRecents.shared.apps()
        // The display the pointer is on (Quartz's top-left point to AppKit's bottom-left).
        let primary = CGDisplayBounds(CGMainDisplayID()).height
        let cocoa = NSPoint(x: point.x, y: primary - point.y)
        let screen = NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = SwitcherLayout.grid(count: entries.count, in: area.size)
        list = (session, entries, grid, area)
        forgetLater(after: 40)   // a hold never lasts longer than 30 s
        return grid
    }

    private func show(_ model: SwitcherOverlayModel) {
        guard let list, list.session == model.session else { return }
        let window = self.window ?? make()
        leaving?.cancel()
        leaving = nil
        if model.selected != lastSelected, lastSelected != nil {
            Sounds.shared.detent(pitch: 1.0 + Double(model.selected % 8) * 0.03, volume: 0.3, kind: .buttons)
        }
        if model.selected != lastSelected, NSWorkspace.shared.isVoiceOverEnabled, list.entries.indices.contains(model.selected) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: list.entries[model.selected].name, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        lastSelected = model.selected
        let appearing = !window.isVisible || !state.shown
        if appearing {
            let size = SwitcherLayout.canvas(model.grid)
            let a = list.area
            let origin = NSPoint(x: (a.midX - size.width / 2).rounded(), y: (a.midY - size.height / 2).rounded())
            window.setFrame(NSRect(origin: origin, size: size), display: false)
            state.entries = list.entries
        }
        state.model = model
        if appearing {
            window.orderFrontRegardless()
            state.shown = false
            withAnimation(.easeOut(duration: 0.12)) { state.shown = true }
        }
    }

    private func hide() {
        lastSelected = nil
        guard let window, window.isVisible, leaving == nil else { return }
        withAnimation(.easeIn(duration: 0.07)) { state.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            state.model = nil
            state.entries = []   // nothing about the apps stays drawn
            leaving = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        forgetLater(after: 3)   // the release's switch, if any, comes right after this
    }

    /// The release: switch to the lit app the way ⌘-Tab does (its windows forward), un-hiding it
    /// if it's hidden, and like a Dock click (it opens a window) if it has none on screen.
    private func activate(session: Int, index: Int) {
        guard let list, list.session == session, list.entries.indices.contains(index) else { return }
        self.list = nil
        let entry = list.entries[index]
        guard let app = entry.app, !app.isTerminated else { return }
        if app.isHidden { app.unhide() }
        let reopen = {
            guard let url = app.bundleURL else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        // No windows on this desktop (none open, all minimized, or on another Space): as the Dock does.
        if entry.windows == 0 { return reopen() }
        if !app.activate(options: [.activateAllWindows]) { return reopen() }
        // macOS may decline an activation from an app that isn't in front: then ask the way the Dock does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !app.isTerminated, NSWorkspace.shared.frontmostApplication != app { reopen() }
        }
    }

    /// Drops the list (names and icons) once it can't be needed any more.
    private func forgetLater(after seconds: Double) {
        forget?.cancel()
        let session = list?.session
        let work = DispatchWorkItem { [weak self] in
            guard let self, list?.session == session else { return }
            list = nil
        }
        forget = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func make() -> NSPanel {
        let w = SwitcherWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.cursorWindow)))   // the stand-in pointer is one above
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: SwitcherOverlayView(state: state))
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        window = w
        return w
    }
}
