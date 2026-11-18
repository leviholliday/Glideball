import CoreGraphics
import Foundation

// The Switcher: ⌘-Tab for the trackball. Hold a button (or a combo) and a panel of the
// running apps appears on the display the pointer is on, most recent first: the app in
// front first, the previous one lit, so a hold and release flips back to the last app the
// way ⌘-Tab does. The ball moves the highlight across the grid, the scroll ring steps it
// one app at a time, and letting go switches to the lit app. A quick press does the tap.
//
// This file is the Switcher's half of the decision (where the highlight goes, when the panel
// shows, what the release does); `GestureMachine` (Gestures.swift) owns the hold itself, so a
// Switcher hold starts, freezes the pointer and ends exactly the way a gesture or a Wheel hold
// does, by every path.
//
// Privacy: the engine never learns which apps are running. It knows how many there are and how
// they're laid out (`SwitcherGrid`), and asks for "app number 3 of hold 12" at the release; the
// list itself lives only on the main thread, only in memory, only while it's needed
// (Views/SwitcherOverlay.swift). Nothing about it is logged, saved or sent.
//
// Foundation and CoreGraphics only, on purpose: scripts/gesture-sim and scripts/engine-fuzz
// compile this file.

/// How the panel lays the apps out: decided on the main thread when the list is built (it
/// depends on the display), handed to the engine so the ball can move in two dimensions.
struct SwitcherGrid: Equatable {
    /// How many apps (0: none, the panel never shows).
    var count: Int
    /// Apps per row (at least 1).
    var columns: Int
    /// How many rows fit on the display; more than that scroll as the highlight moves.
    var visibleRows: Int

    init(count: Int, columns: Int, visibleRows: Int) {
        self.count = max(0, count)
        self.columns = max(1, columns)
        self.visibleRows = max(1, visibleRows)
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    /// The grid for `count` apps when at most `maxColumns` fit across and `maxRows` down:
    /// one row while they fit in one (like ⌘-Tab), otherwise rows as even as they can be
    /// (10 apps with room for 8 across are two rows of 5, not 8 and 2).
    static func fitting(count: Int, maxColumns: Int, maxRows: Int) -> SwitcherGrid {
        let maxColumns = max(1, maxColumns)
        let n = max(0, count)
        guard n > maxColumns else { return SwitcherGrid(count: n, columns: max(1, n), visibleRows: 1) }
        let rows = (n + maxColumns - 1) / maxColumns
        let columns = (n + rows - 1) / rows
        return SwitcherGrid(count: n, columns: columns, visibleRows: min(rows, max(1, maxRows)))
    }

    enum Move { case left, right, up, down }

    /// One step from `index`. Left and right run through the apps in order and wrap at the
    /// ends (the end of a row goes on to the next one); up and down keep the column and wrap
    /// top to bottom. Down into a short last row that has nothing under you lands on its last app.
    func moved(_ index: Int, _ move: Move) -> Int {
        guard count > 0 else { return 0 }
        let i = min(max(0, index), count - 1)
        let column = i % columns
        let row = i / columns
        let lastRow = rows - 1
        switch move {
        case .right: return (i + 1) % count
        case .left: return (i - 1 + count) % count
        case .down:
            if i + columns < count { return i + columns }
            if row < lastRow { return count - 1 }
            return column   // the bottom: round to the top, same column
        case .up:
            if i - columns >= 0 { return i - columns }
            // The top: round to the bottom, same column (the row above it if the last is short).
            let below = lastRow * columns + column
            return below < count ? below : max(0, below - columns)
        }
    }

    /// The first row to show so `index` is visible, moving as little as possible from `first`.
    func firstRow(showing index: Int, from first: Int) -> Int {
        guard count > 0 else { return 0 }
        let row = min(max(0, index), count - 1) / columns
        var f = min(max(0, first), max(0, rows - visibleRows))
        if row < f { f = row }
        if row >= f + visibleRows { f = row - visibleRows + 1 }
        return f
    }
}

/// A Switcher hold's own state, inside `GestureMachine.Hold`.
struct SwitcherHold: Equatable {
    /// Which hold this is: the main thread keeps its list under this number.
    var session: Int
    /// Ball counts per step of the highlight (the Gesture distance's).
    var step: Double
    /// Below this much roll a release (before the panel shows) can still be the tap.
    var tapSlop: Double
    /// Nil until the main thread has built the list.
    var grid: SwitcherGrid?
    /// The lit app, and the first row on screen.
    var index = 0
    var firstRow = 0
    /// Roll not yet turned into steps, each way.
    var ax = 0.0, ay = 0.0
    /// The farthest the ball got from where it started, for the tap.
    var rawX = 0.0, rawY = 0.0
    var travel = 0.0
    /// Ring steps that came before the list did (applied when it arrives).
    var pendingRing = 0
    /// The panel may show (after `revealDelay`, a roll past the slop, or a ring turn).
    var revealed = false
    var ringUsed = false
    /// Esc or another trackball button: nothing switches, and the panel goes away until the release.
    var dismissed = false

    /// The panel appears this long after the press if nothing else brought it up. A release
    /// before then without rolling is the tap; after it, a switch to the lit app.
    static let revealDelay = 0.2

    /// The panel is (or should be) on screen: revealed, not dismissed, with apps to show.
    var shown: Bool { revealed && !dismissed && (grid?.count ?? 0) > 0 }

    /// Rolled-ahead counts never queue more than this many steps before the list arrives.
    private var pendingLimit: Double { step * 3 }

    mutating func ball(dx: Double, dy: Double) {
        rawX += dx
        rawY += dy
        travel = max(travel, (rawX * rawX + rawY * rawY).squareRoot())
        if travel >= tapSlop { revealed = true }
        guard !dismissed else { return }
        ax += dx
        ay += dy
        if grid == nil {
            ax = min(max(ax, -pendingLimit), pendingLimit)
            ay = min(max(ay, -pendingLimit), pendingLimit)
        }
        applySteps()
    }

    /// Turns rolled counts into steps across the grid. The larger way goes first, and a step
    /// one way forgets the other way's leftovers, so a slow drift never crosses a row by
    /// accident while you roll along it.
    mutating func applySteps() {
        guard let grid, grid.count > 0, step > 0 else { return }
        for _ in 0..<64 {
            if abs(ax) >= abs(ay), abs(ax) >= step {
                index = grid.moved(index, ax > 0 ? .right : .left)
                ax -= ax > 0 ? step : -step
                ay = 0
            } else if abs(ay) >= step {
                index = grid.moved(index, ay > 0 ? .down : .up)   // +y is toward you: down
                ay -= ay > 0 ? step : -step
                ax = 0
            } else {
                break
            }
        }
        firstRow = grid.firstRow(showing: index, from: firstRow)
    }

    /// One report from the scroll ring: one app forward (clockwise) or back. Never scrolls.
    mutating func ring(clockwise: Bool) {
        ringUsed = true
        revealed = true
        guard !dismissed else { return }
        guard let grid, grid.count > 0 else {
            pendingRing = min(max(pendingRing + (clockwise ? 1 : -1), -24), 24)
            return
        }
        index = grid.moved(index, clockwise ? .right : .left)
        firstRow = grid.firstRow(showing: index, from: firstRow)
    }

    /// The main thread built the list: the previous app lit (the one in front if it's alone),
    /// then whatever was rolled or turned meanwhile.
    mutating func ready(_ g: SwitcherGrid) {
        grid = g
        index = g.count > 1 ? 1 : 0
        firstRow = 0
        guard !dismissed, g.count > 0 else { return }
        for _ in 0..<abs(pendingRing) { index = g.moved(index, pendingRing > 0 ? .right : .left) }
        pendingRing = 0
        applySteps()
        firstRow = g.firstRow(showing: index, from: firstRow)
    }

    /// The panel as it should look now; nil while it's hidden.
    var overlay: SwitcherOverlayModel? {
        guard shown, let grid else { return nil }
        return SwitcherOverlayModel(session: session, grid: grid, selected: index, firstRow: firstRow)
    }
}

/// What the Switcher's panel shows (`EngineIO.showSwitcher`): only numbers. The panel looks up
/// the apps themselves in its own list for `session`.
struct SwitcherOverlayModel: Equatable {
    var session: Int
    var grid: SwitcherGrid
    /// The lit app (0 is the one in front).
    var selected: Int
    /// The first row on screen (when there are more rows than fit).
    var firstRow: Int
}

/// Builds the app list, draws the panel and switches apps for the Switcher (the app's
/// `SwitcherOverlayPanel`). Main thread only.
protocol SwitcherPresenting: AnyObject {
    /// Builds the list of running apps for a new hold, for the display that has `point`
    /// (global Quartz coordinates) on it, keeps it under `session`, and returns its grid.
    func prepareSwitcher(session: Int, near point: CGPoint) -> SwitcherGrid
    /// Shows the panel, or updates it.
    func showSwitcher(_ model: SwitcherOverlayModel, near point: CGPoint)
    func hideSwitcher()
    /// Switches to app `index` of `session`'s list (once; the list is gone afterwards).
    func activateSwitcher(session: Int, index: Int)
}
