import AppKit
import SwiftUI

// The Switcher's panel on screen: a Liquid Glass panel centred on the display the pointer is
// on, the running apps as big icons in a grid (most recent first). The ball lights it: a soft
// glass lens in the ball's light (`Theme.light`: ball blue, or the ball color's) sits under the lit app and glides from icon to icon, its light
// spilling across the glass; the lit icon lifts and grows, its neighbours a little (like the
// Dock), and only the lit app's name shows, crisp, under it. The engine decides everything
// (Switcher.swift, Gestures.swift) and hands this a `SwitcherOverlayModel` through
// `EngineIO.showSwitcher`; this builds the app list when a hold starts, draws it, and switches
// at the release. Another trackball button hides the lit app from this Switcher (the engine
// says which place; this knows which app, and saves its bundle ID in the Switcher's settings).
//
// Privacy: the list (names, icons, window counts) lives only here, on the main thread, only in
// memory, from the start of a hold until its release (or a few seconds after it). The engine
// only ever sees how many apps there are and how they're laid out. Nothing about which apps
// are running is logged, saved, sent or put in diagnostics; a hidden app's bundle ID goes only
// into the settings (never stats). No new permissions: names and icons come from
// NSRunningApplication, window counts from CGWindowList without titles (no Screen Recording,
// no Accessibility).
//
// Motion: the open grows and fades in (a 0.22 s spring), the light glides with the guide's
// selection spring, and a hidden app's row closes up the same way. Between steps the lens and
// its light lean a few points toward where the ball is rolling (`SwitcherHold.lean`: drawing
// only, it falls back when the roll is dropped after a rest), so a roll that hasn't made a
// step yet is still answered. It leaves the way the ring does (`SwitcherExit`): choosing an
// app lifts and brightens its icon while the panel falls away behind it; anything else (Esc,
// a dismissal, the app already in front, a hold that ended for safety) drains the light and
// fades. The switch itself is sent at the release as ever; none of this waits for or delays it.
// Reduce Motion: fades only (the light cross-fades from app to app, nothing scales, slides
// or leans). Everything moves only when the model changes, so nothing animates while it's away.

/// One app in the panel.
struct SwitcherEntry: Identifiable {
    /// Its place in the hold's list (as it came, before anything was hidden).
    let id: Int
    let name: String
    let icon: NSImage
    /// Its windows on screen now (on this desktop, not minimized): shown when it's 2 or more.
    let windows: Int
    /// Hidden (⌘H): drawn a little dimmer.
    let hidden: Bool
    /// The app itself (nil for render-ui's made-up entries).
    let app: NSRunningApplication?
    /// What hiding it from the Switcher saves (nil: it has none, so it can't be kept hidden).
    var bundleID: String? = nil
}

/// The panel's sizes. One cell per app; the grid comes from `SwitcherGrid` (Switcher.swift).
enum SwitcherLayout {
    static let cell = CGSize(width: 112, height: 124)
    static let icon: CGFloat = 76
    static let padding: CGFloat = 22
    static let radius: CGFloat = 30
    /// The hint line under the grid ("Top left: hide app"), when there's a button to do it with.
    static let footer: CGFloat = 26
    /// Never more than this many across (a wider panel stops reading as one glance).
    static let maxColumns = 8
    /// Room around the panel for its shadow and the lit cell's lift and glow.
    static let margin: CGFloat = 40
    /// How much the lit icon grows and lifts, and how fast that falls off with distance (cells).
    static let litScale: CGFloat = 0.16
    static let litLift: CGFloat = 7
    static let falloff: CGFloat = 1.1
    /// The lean: how far the lens, and the light spilling from it, shift toward the next app
    /// when the roll is a whole step's worth along (points). Felt, not watched.
    static let lensLean: CGFloat = 4
    static let lightLean: CGFloat = 10
    /// The chosen app's icon as the panel leaves: how much more it grows and lifts.
    static let flareScale: CGFloat = 0.10
    static let flareLift: CGFloat = 6

    /// The panel itself (without the margin) for `grid`.
    static func panelSize(_ grid: SwitcherGrid, footer: Bool = false) -> CGSize {
        CGSize(width: CGFloat(max(1, min(grid.columns, grid.count))) * cell.width + padding * 2,
               height: CGFloat(min(grid.visibleRows, max(1, grid.rows))) * cell.height + padding * 2 + (footer ? Self.footer : 0))
    }

    /// The window: the panel and its margin.
    static func canvas(_ grid: SwitcherGrid, footer: Bool = false) -> CGSize {
        let p = panelSize(grid, footer: footer)
        return CGSize(width: p.width + margin * 2, height: p.height + margin * 2)
    }

    /// The grid that fits on a display whose usable area is `area`: at most 90% of its width
    /// and 80% of its height, so it never runs off screen.
    static func grid(count: Int, in area: CGSize, frontFirst: Bool = true) -> SwitcherGrid {
        let across = Int(((area.width * 0.9) - padding * 2 - margin * 2) / cell.width)
        let down = Int(((area.height * 0.8) - padding * 2 - footer - margin * 2) / cell.height)
        return SwitcherGrid.fitting(count: count, maxColumns: min(maxColumns, max(1, across)), maxRows: max(1, down), frontFirst: frontFirst)
    }

    /// The Dock's magnification: 1 at a distance, `1 + litScale` on the lit app.
    static func closeness(_ distance: CGFloat) -> CGFloat { exp(-(distance * distance) / falloff) }
}

/// What the panel shows, observed by the view (main thread only).
@MainActor
@Observable
final class SwitcherOverlayState {
    /// Every app in the hold's list, as it came (the model says which are hidden).
    var entries: [SwitcherEntry] = []
    var model: SwitcherOverlayModel?
    /// Drives the in and out animation: false while it's leaving.
    var shown = false
    /// The button named in the hint ("Top left"), or nil when there's none to hide an app with.
    var hideButton: String?
    /// The ball has rested since the lean was last drawn: it has fallen back (the engine drops
    /// that leftover roll at the next movement; `SwitcherOverlayPanel.show` keeps this).
    var leanRested = false
    /// How the panel is leaving, once it is (nil while it's up).
    var exit: SwitcherExit?
    /// Renders: hold the exit part-way, so a picture shows it (there's no clock in a picture).
    var frozenExit = false
}

/// How the panel leaves. `launch`: an app was chosen (its place among those showing): its icon
/// lifts and brightens as the panel falls away. `drain`: nothing was (Esc, dismissed, the app
/// already in front, or a hold that ended for safety): the light goes out and the panel fades.
struct SwitcherExit: Equatable {
    enum Kind { case launch, drain }
    var kind: Kind
    var chosen: Int?

    /// From the take-down to the window going. The drain is what closing always took.
    static func duration(_ kind: Kind) -> Double { kind == .launch ? 0.24 : 0.11 }
    /// The panel itself falling away.
    static func fall(_ kind: Kind) -> Animation { .easeIn(duration: kind == .launch ? 0.12 : 0.1) }
}

struct SwitcherOverlayView: View {
    let state: SwitcherOverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let m = state.model, !state.entries.isEmpty {
                SwitcherPanel(model: m, entries: state.entries, hideButton: state.hideButton,
                              leans: !state.leanRested, shown: state.shown, exit: state.exit, frozenExit: state.frozenExit)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The panel: glass, the light, the apps, and the hint.
struct SwitcherPanel: View {
    let model: SwitcherOverlayModel
    let entries: [SwitcherEntry]
    let hideButton: String?
    /// The lean is drawn (false once the ball has rested: it has fallen back).
    var leans = true
    /// False while it's leaving.
    var shown = true
    var exit: SwitcherExit?
    var frozenExit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = model
        // How it leaves: the light goes out at once either way; a chosen app's icon is drawn
        // again above the panel (`flare`), so it can outlast the glass it was sitting on.
        let launch = exit?.kind == .launch ? exit?.chosen : nil
        let lightOn: Double = exit == nil ? 1 : 0
        let away: Double = shown ? 0 : frozenExit ? 0.6 : 1
        // The lean, in points: toward the next app, by how far the roll has got.
        let parts = CGFloat(SwitcherHold.leanParts)
        let lean = leans && !reduceMotion && exit == nil
            ? CGSize(width: CGFloat(m.leanX) / parts, height: CGFloat(m.leanY) / parts) : .zero
        let leanMotion = Animation.spring(response: 0.16, dampingFraction: 0.9)
        let g = m.grid
        let gone = Set(m.hidden)
        let showing = entries.filter { !gone.contains($0.id) }
        let size = SwitcherLayout.panelSize(g, footer: hideButton != nil)
        let gridHeight = size.height - (hideButton != nil ? SwitcherLayout.footer : 0)
        let shape = RoundedRectangle(cornerRadius: SwitcherLayout.radius, style: .continuous)
        let cell = SwitcherLayout.cell
        let columns = max(1, g.columns)
        let selected = min(max(0, m.selected), max(0, showing.count - 1))
        let litCol = CGFloat(selected % columns), litRow = CGFloat(selected / columns)
        let scrolls = g.rows > g.visibleRows
        let shift = -CGFloat(m.firstRow) * cell.height
        let litCentre = CGPoint(x: SwitcherLayout.padding + (litCol + 0.5) * cell.width,
                                y: SwitcherLayout.padding + (litRow + 0.5) * cell.height + shift)
        let dark = scheme == .dark
        let motion: Animation = reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.26, dampingFraction: 0.86)
        let core = ZStack(alignment: .topLeading) {
            // The ball's light, spilling across the glass from the lit app (it glides with it,
            // and leans ahead of it toward where the ball is rolling).
            RadialGradient(colors: [Theme.light.opacity(dark ? 0.30 : 0.22), Theme.light.opacity(dark ? 0.08 : 0.05), .clear],
                           center: .center, startRadius: 0, endRadius: cell.width * 1.7)
                .frame(width: cell.width * 3.4, height: cell.width * 3.4)
                .offset(x: lean.width * SwitcherLayout.lightLean, y: lean.height * SwitcherLayout.lightLean)
                .opacity(lightOn)
                .animation(leanMotion, value: lean)
                .animation(.easeOut(duration: 0.07), value: exit)
                .position(litCentre)
                .blendMode(dark ? .plusLighter : .normal)
            // Everything that scrolls: the lens under the lit app, then the apps.
            ZStack(alignment: .topLeading) {
                if !reduceMotion {
                    SwitcherLens()
                        .frame(width: cell.width - 10, height: cell.height - 8)
                        .offset(x: lean.width * SwitcherLayout.lensLean, y: lean.height * SwitcherLayout.lensLean)
                        .opacity(lightOn)
                        .animation(leanMotion, value: lean)
                        .animation(.easeOut(duration: 0.07), value: exit)
                        .offset(x: litCol * cell.width + 5, y: litRow * cell.height + 4)
                }
                ForEach(Array(showing.enumerated()), id: \.element.id) { i, entry in
                    let col = CGFloat(i % columns), row = CGFloat(i / columns)
                    let distance = ((col - litCol) * (col - litCol) + (row - litRow) * (row - litRow) * 1.4).squareRoot()
                    // Draining: the lit app settles back among the others as its light goes.
                    let near = exit?.kind == .drain ? 0 : SwitcherLayout.closeness(distance)
                    SwitcherCell(entry: entry, lit: i == selected && exit?.kind != .drain,
                                 closeness: reduceMotion ? (i == selected && exit?.kind != .drain ? 1 : 0) : near)
                        .opacity(launch == i ? 0 : 1)   // drawn above the panel instead (`flare`)
                        .transaction { if launch == i { $0.animation = nil } }
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: col * cell.width, y: row * cell.height)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .offset(y: shift)
            .padding(SwitcherLayout.padding)
            .frame(width: size.width, height: gridHeight, alignment: .topLeading)
            // Scrolled rows fade out into the padding instead of peeking in at the edge.
            .mask {
                let edge = SwitcherLayout.padding / gridHeight
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
                .frame(width: size.width, height: gridHeight)
            }
            if let hideButton {
                SwitcherHint(button: hideButton, undoable: m.undoable, hiddenCount: m.hidden.count)
                    .frame(width: size.width, height: SwitcherLayout.footer + 8)
                    .offset(y: size.height - SwitcherLayout.footer - 16)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay {
            // A lit top edge, like light falling on glass.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.30 : 0.75), .white.opacity(dark ? 0.04 : 0.15)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 26, y: 12)
        .animation(motion, value: m.selected)
        .animation(motion, value: m.hidden)
        .animation(reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.28, dampingFraction: 0.88), value: m.firstRow)
        return ZStack(alignment: .topLeading) {
            // The panel falls away (a little further back when an app was chosen).
            core
                .scaleEffect(reduceMotion ? 1 : 1 - (launch != nil ? 0.05 : 0.03) * away)
                .opacity(1 - away)
            // The chosen app's icon, exactly where its cell drew it, lifting as the panel goes.
            if let place = launch, showing.indices.contains(place) {
                SwitcherFlare(entry: showing[place], frozen: frozenExit)
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: SwitcherLayout.padding + CGFloat(place % columns) * cell.width,
                            y: SwitcherLayout.padding + CGFloat(place / columns) * cell.height + shift)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The chosen app's icon as the panel leaves: drawn where its cell had it (lit, lifted), then it
/// grows and lifts a little more with a bloom of the ball's light behind it, and fades. One
/// short spring and one fade, started as it appears; gone with the window 0.24 s after the
/// release. Reduce Motion: it only fades, a moment after the panel.
struct SwitcherFlare: View {
    let entry: SwitcherEntry
    /// Renders: held at its brightest.
    var frozen = false
    @State private var up = false
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let risen = (up || frozen) && !reduceMotion
        SwitcherCell(entry: entry, lit: true, closeness: reduceMotion ? 0 : 1, solo: true,
                     extraScale: risen ? SwitcherLayout.flareScale : 0, extraLift: risen ? SwitcherLayout.flareLift : 0,
                     bloom: up || frozen ? 1 : 0.35)
            .opacity(faded && !frozen ? 0 : 1)
            .onAppear {
                guard !frozen else { return }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) { up = true }
                withAnimation(.easeIn(duration: 0.12).delay(0.10)) { faded = true }
            }
    }
}

/// The lens under the lit app: a piece of glass tinted the ball's light (`Theme.light`: ball blue, or the ball color's), lit from the top, with
/// a soft bloom under it. One for the whole panel, so it glides from app to app.
struct SwitcherLens: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(LinearGradient(colors: [Theme.light.opacity(dark ? 0.34 : 0.17), Theme.light.opacity(dark ? 0.16 : 0.09)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                // Light falling on its top edge, and a fine rim in the ball's light (`Theme.light`: ball blue, or the ball color's).
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.55 : 1), .white.opacity(0.0)],
                                                  startPoint: .top, endPoint: .center), lineWidth: dark ? 1 : 1.5)
            }
            .overlay { shape.strokeBorder(Theme.light.opacity(dark ? 0.55 : 0.32), lineWidth: 0.75) }
            .background {
                // The bloom: the ball's light under the glass.
                shape.fill(Theme.light.opacity(dark ? 0.55 : 0.32))
                    .blur(radius: 16)
                    .padding(6)
            }
    }
}

/// One app: its icon (lifted and grown by how close it is to the lit app), the window count
/// when there are several, and, for the lit app only, its name.
struct SwitcherCell: View {
    let entry: SwitcherEntry
    let lit: Bool
    /// 1 on the lit app, falling to 0 a couple of apps away (the Dock's magnification).
    let closeness: CGFloat
    /// The chosen app's icon alone, above the leaving panel (`SwitcherFlare`): no name, no
    /// lens, a little more size and lift, and the ball's light blooming behind it.
    var solo = false
    var extraScale: CGFloat = 0
    var extraLift: CGFloat = 0
    var bloom: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let scale = reduceMotion ? 1 : 1 + SwitcherLayout.litScale * closeness + extraScale
        let lift = reduceMotion ? 0 : -SwitcherLayout.litLift * closeness - extraLift
        VStack(spacing: 0) {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: SwitcherLayout.icon, height: SwitcherLayout.icon)
                .brightness(solo ? 0.06 * bloom : 0)
                .background {
                    if solo {
                        Circle().fill(Theme.light.opacity(0.55 * bloom))
                            .blur(radius: 18)
                            .padding(-6)
                    }
                }
                .opacity(entry.hidden && !lit ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if entry.windows >= 2 {
                        Text(entry.windows, format: .number)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .overlay { Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                            .offset(x: 5, y: -3)
                    }
                }
                // Lifted things cast a longer, softer shadow.
                .shadow(color: .black.opacity(0.16 + 0.16 * closeness), radius: 3 + 7 * closeness, y: 2 + 5 * closeness)
                .scaleEffect(scale, anchor: .bottom)
                .offset(y: lift)
                .frame(height: SwitcherLayout.icon + 22, alignment: .bottom)
            Spacer(minLength: 0)
            // Only the lit app's name, at its real size (never scaled, so it stays crisp).
            Text(verbatim: entry.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .opacity(lit && !solo ? 1 : 0)
                .padding(.bottom, 12)
        }
        .background {
            // Reduce Motion: no gliding lens, so each app has its own, cross-fading.
            if reduceMotion && !solo {
                SwitcherLens().padding(.horizontal, 5).padding(.vertical, 4).opacity(lit ? 1 : 0)
            }
        }
    }
}

/// The line under the apps: how to hide one, and, straight after a hide, how to bring it back.
/// It fades in a moment after the panel opens, so a quick flip never has to read it.
struct SwitcherHint: View {
    /// The button that does it ("Top left").
    let button: String
    let undoable: Bool
    let hiddenCount: Int
    @State private var visible = false

    var body: some View {
        HStack(spacing: 6) {
            if undoable {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Hidden", comment: "Switcher panel, just after an app was hidden from it (then: “· [button] Undo”)")
                Text(verbatim: "·").foregroundStyle(.tertiary)
                chip
                Text("Undo", comment: "Switcher panel: press the named button again to bring back the app just hidden")
            } else {
                chip
                Text("Hide app", comment: "Switcher panel hint: pressing the named trackball button hides the lit app from the Switcher")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .opacity(visible || undoable || hiddenCount > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: undoable)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.7)) { visible = true }
        }
    }

    /// The button's name in a small keycap, with an amber dot (buttons are amber).
    private var chip: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.buttons).frame(width: 5, height: 5)
            Text(verbatim: button)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.primary.opacity(0.8))
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(.primary.opacity(0.07)))
        .overlay { Capsule().strokeBorder(.primary.opacity(0.14), lineWidth: 0.5) }
    }
}

// MARK: - The app list

/// The apps in the order you last used them, kept in memory while Glideball runs (never saved):
/// what ⌘-Tab's order is made of. Every running app has a place in it from the moment Glideball
/// starts (the windows' front-to-back order then, then newest first), and only ever moves when
/// you use it: so the apps you haven't touched stay where they were from one hold to the next,
/// instead of reshuffling by whatever windows happen to be on screen. Main thread only.
@MainActor
final class SwitcherRecents {
    static let shared = SwitcherRecents()
    private(set) var order: [pid_t] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        order = Self.seed()
        let center = NSWorkspace.shared.notificationCenter
        func app(_ note: Notification) -> pid_t? {
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = app(note) else { return }
            MainActor.assumeIsolated { SwitcherRecents.shared.used(pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = app(note) else { return }
            MainActor.assumeIsolated { SwitcherRecents.shared.launched(pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = app(note) else { return }
            MainActor.assumeIsolated { SwitcherRecents.shared.order.removeAll { $0 == pid } }
        })
    }

    /// Used (it came to the front): first.
    private func used(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
        if order.count > 128 { order.removeLast(order.count - 128) }
    }

    /// Just opened (it usually comes to the front too, which moves it up): second, behind the app
    /// in front, as ⌘-Tab puts it.
    private func launched(_ pid: pid_t) {
        guard !order.contains(pid) else { return }
        order.insert(pid, at: min(1, order.count))
    }

    /// The order at start: the app in front, then the rest by their windows' stacking, then by launch.
    private static func seed() -> [pid_t] {
        var out: [pid_t] = []
        func put(_ pid: pid_t) { if !out.contains(pid) { out.append(pid) } }
        if let front = NSWorkspace.shared.frontmostApplication { put(front.processIdentifier) }
        windowsByApp().stacking.forEach(put)
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .forEach { put($0.processIdentifier) }
        return out
    }

    /// The running apps with a Dock icon (regular activation policy) in ⌘-Tab's order: the one in
    /// front first, then the rest as they were last used (`order`), any it somehow missed last,
    /// newest first. Leaves out `hiding` (bundle IDs). With each one's windows on screen.
    func apps(hiding: Set<String> = []) -> [SwitcherEntry] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !hiding.contains($0.bundleIdentifier ?? "")
        }
        let windows = Self.windowsByApp().counts
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var rank: [pid_t: Int] = [:]
        var next = 0
        func put(_ pid: pid_t) { if rank[pid] == nil { rank[pid] = next; next += 1 } }
        if let front { put(front) }
        order.forEach(put)
        let sorted = running.enumerated().sorted { a, b in
            let ra = rank[a.element.processIdentifier] ?? Int.max, rb = rank[b.element.processIdentifier] ?? Int.max
            if ra != rb { return ra < rb }
            let la = a.element.launchDate ?? .distantPast, lb = b.element.launchDate ?? .distantPast
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
        return sorted.prefix(96).enumerated().map { i, app in
            let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
            return SwitcherEntry(id: i, name: app.localizedName ?? app.bundleIdentifier ?? "?", icon: icon,
                                 windows: windows[app.processIdentifier] ?? 0, hidden: app.isHidden, app: app,
                                 bundleID: app.bundleIdentifier)
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

    /// Saves a hide (or a show again) in the Switcher's settings: the app's bundle ID, whether
    /// it's hidden, and the Switcher's button (or combo). Set by the app (`AppModel`).
    static var onHiddenChange: ((_ bundleID: String, _ hidden: Bool, _ buttons: [Int]) -> Void)?

    private let state = SwitcherOverlayState()
    private var window: NSPanel?
    private var leaving: DispatchWorkItem?
    private var lastSelected: Int?
    /// The lean falls back by itself once the ball has rested (one shot, only after a lean was drawn).
    private var leanFall: DispatchWorkItem?
    /// The release's choice (its place in the list as it came), told just before the take-down.
    private var chose: (session: Int, index: Int, at: CFTimeInterval)?
    /// The hold's list and the display it's for. Only the latest hold's, only until it's used.
    private var list: (session: Int, entries: [SwitcherEntry], grid: SwitcherGrid, area: CGRect, buttons: [Int], hideButton: String?)?
    private var forget: DispatchWorkItem?

    /// Hooks it up to the engine and starts keeping the order apps were used in. Once, at launch.
    static func install() {
        EngineIO.switcherPresenter = shared
        SwitcherRecents.shared.start()
    }

    /// The button the hint names for hiding an app: another of the trackball's buttons that isn't
    /// the primary one and isn't the Switcher's own (top left first, then bottom right, then top right).
    static func hideButton(besides buttons: [Int]) -> String? {
        [2, 1, 3].first { !buttons.contains($0) }.map(AppModel.buttonName)
    }

    nonisolated func prepareSwitcher(session: Int, near point: CGPoint, buttons: [Int], hidden: [String]) -> SwitcherGrid {
        MainActor.assumeIsolated { prepare(session: session, near: point, buttons: buttons, hidden: hidden) }
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

    nonisolated func switcherAppHidden(session: Int, index: Int, hidden: Bool) {
        MainActor.assumeIsolated { appHidden(session: session, index: index, hidden: hidden) }
    }

    nonisolated func switcherChose(session: Int, index: Int) {
        MainActor.assumeIsolated { chose = (session, index, CACurrentMediaTime()) }
    }

    private func prepare(session: Int, near point: CGPoint, buttons: [Int], hidden: [String]) -> SwitcherGrid {
        let began = PressTiming.now()
        defer { PressTiming.shared.add(.switcherList, from: began) }
        // The press readies what the panel will need: its window is built now, during the 0.2 s
        // before it can show, not inside the first show of a launch.
        if window == nil { _ = make() }
        let entries = SwitcherRecents.shared.apps(hiding: Set(hidden))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontFirst = front != nil && entries.first?.app?.processIdentifier == front
        // The display the pointer is on (Quartz's top-left point to AppKit's bottom-left).
        let primary = CGDisplayBounds(CGMainDisplayID()).height
        let cocoa = NSPoint(x: point.x, y: primary - point.y)
        let screen = NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let grid = SwitcherLayout.grid(count: entries.count, in: area.size, frontFirst: frontFirst)
        list = (session, entries, grid, area, buttons, Self.hideButton(besides: buttons))
        forgetLater(after: 40)   // a hold never lasts longer than 30 s
        return grid
    }

    private func show(_ model: SwitcherOverlayModel) {
        guard let list, list.session == model.session else { return }
        let window = self.window ?? make()
        leaving?.cancel()
        leaving = nil
        let gone = Set(model.hidden)
        let showing = list.entries.filter { !gone.contains($0.id) }
        if model.selected != lastSelected, lastSelected != nil {
            Sounds.shared.detent(pitch: 1.0 + Double(model.selected % 8) * 0.03, volume: 0.3, kind: .buttons)
        }
        if model.selected != lastSelected || model.hidden != state.model?.hidden,
           NSWorkspace.shared.isVoiceOverEnabled, showing.indices.contains(model.selected) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: showing[model.selected].name, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        lastSelected = model.selected
        // The lean: drawn as it comes, and let fall once the ball has rested as long as the
        // engine takes to drop that roll (a little longer, so a slow steady roll never flickers).
        leanFall?.cancel()
        leanFall = nil
        if state.leanRested { state.leanRested = false }
        if model.leanX != 0 || model.leanY != 0 {
            let fall = DispatchWorkItem { [weak self] in
                guard let self else { return }
                leanFall = nil
                withAnimation(.easeOut(duration: 0.2)) { self.state.leanRested = true }
            }
            leanFall = fall
            DispatchQueue.main.asyncAfter(deadline: .now() + SwitcherHold.restForgets + 0.03, execute: fall)
        }
        let appearing = !window.isVisible || !state.shown
        if appearing {
            state.exit = nil
            // Sized once for the whole list as it came: hiding an app only ever shrinks the panel
            // inside it, so nothing re-centres or jumps while it's up.
            let size = SwitcherLayout.canvas(list.grid, footer: list.hideButton != nil)
            let a = list.area
            let origin = NSPoint(x: (a.midX - size.width / 2).rounded(), y: (a.midY - size.height / 2).rounded())
            window.setFrame(NSRect(origin: origin, size: size), display: false)
            state.entries = list.entries
            state.hideButton = list.hideButton
            window.orderFrontRegardless()
            // It grows and fades in (the panel's own transition; Reduce Motion: a fade).
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                state.model = model
                state.shown = true
            }
            // Measurement only: the window is in, and this is when its first frame is committed.
            PressTiming.afterThisCommit { PressTiming.shared.shown(.switcher) }
        } else {
            state.model = model
        }
    }

    private func hide() {
        lastSelected = nil
        leanFall?.cancel()
        leanFall = nil
        guard let window, window.isVisible, leaving == nil else { return }
        // An app was chosen (told a moment ago, for this hold, and it's the one lit): its icon
        // lifts as the panel goes. Anything else drains: Esc, a dismissal, a hold that ended
        // for safety, and choosing the app that's already in front (nothing will change).
        var kind = SwitcherExit.Kind.drain
        var place: Int?
        if let chose, CACurrentMediaTime() - chose.at < 0.1, let list, list.session == chose.session, let m = state.model {
            let gone = Set(m.hidden)
            let showing = list.entries.filter { !gone.contains($0.id) }
            if let i = showing.firstIndex(where: { $0.id == chose.index }),
               showing[i].app == nil || showing[i].app?.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                kind = .launch
                place = i
            }
        }
        chose = nil
        state.exit = SwitcherExit(kind: kind, chosen: place)
        withAnimation(SwitcherExit.fall(kind)) { state.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            state.model = nil
            state.entries = []   // nothing about the apps stays drawn
            state.exit = nil
            state.leanRested = false
            leaving = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SwitcherExit.duration(kind), execute: work)
        forgetLater(after: 3)   // the release's switch, if any, comes right after this
    }

    /// The engine hid (or brought back) app `index` of the list: saved in the Switcher's settings.
    private func appHidden(session: Int, index: Int, hidden: Bool) {
        guard let list, list.session == session, list.entries.indices.contains(index),
              let id = list.entries[index].bundleID else { return }
        Self.onHiddenChange?(id, hidden, list.buttons)
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
