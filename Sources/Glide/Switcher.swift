import CoreGraphics
import Foundation

// The Switcher: ⌘-Tab for the trackball. Hold a button (or a combo) and a panel of the
// running apps appears on the display the pointer is on, most recent first: the app in
// front first, the previous one lit, so a hold and release flips back to the last app the
// way ⌘-Tab does. The ball moves the highlight across the grid, the scroll ring steps it
// one app at a time, and letting go switches to the lit app. A quick press does the tap.
// While the panel is up, another trackball button (never the primary one) hides the lit
// app from this Switcher; the same press again, before the highlight moves, brings it back.
//
// This file is the Switcher's half of the decision (where the highlight goes, when the panel
// shows, what the release does); `GestureMachine` (Gestures.swift) owns the hold itself, so a
// Switcher hold starts, freezes the pointer and ends exactly the way a gesture or a Wheel hold
// does, by every path.
//
// Privacy: the engine never learns which apps are running. It knows how many there are and how
// they're laid out (`SwitcherGrid`), and asks for "app number 3 of hold 12" at the release; the
// list itself lives only on the main thread, only in memory, only while it's needed
// (Views/SwitcherOverlay.swift). Nothing about it is logged, saved or sent. Hiding an app
// works the same way: the engine says "hide app 3 of hold 12", and the main thread, which
// knows what that is, writes its bundle ID into this Switcher's settings.
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
    /// The app in front is first in the list (it isn't when it's hidden from this Switcher):
    /// then the previous app, second, is lit at the start, so a hold and release flips back.
    var frontFirst: Bool

    init(count: Int, columns: Int, visibleRows: Int, frontFirst: Bool = true) {
        self.count = max(0, count)
        self.columns = max(1, columns)
        self.visibleRows = max(1, visibleRows)
        self.frontFirst = frontFirst
    }

    var rows: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    /// The app lit when the panel first shows: the previous one (⌘-Tab's flip back), or the
    /// first when the app in front isn't in the list or is alone.
    var startIndex: Int { frontFirst && count > 1 ? 1 : 0 }

    /// The grid for `count` apps when at most `maxColumns` fit across and `maxRows` down:
    /// one row while they fit in one (like ⌘-Tab), otherwise rows as even as they can be
    /// (10 apps with room for 8 across are two rows of 5, not 8 and 2).
    static func fitting(count: Int, maxColumns: Int, maxRows: Int, frontFirst: Bool = true) -> SwitcherGrid {
        let maxColumns = max(1, maxColumns)
        let n = max(0, count)
        guard n > maxColumns else { return SwitcherGrid(count: n, columns: max(1, n), visibleRows: 1, frontFirst: frontFirst) }
        let rows = (n + maxColumns - 1) / maxColumns
        let columns = (n + rows - 1) / rows
        return SwitcherGrid(count: n, columns: columns, visibleRows: min(rows, max(1, maxRows)), frontFirst: frontFirst)
    }

    /// This grid with `count` apps left in it (some hidden while it's up): a single row closes
    /// up (one column fewer per app), several rows keep their width and lose rows from the end.
    /// Never wider than it was, so the panel only ever shrinks inside its window.
    func keeping(_ n: Int) -> SwitcherGrid {
        let n = min(max(0, n), count)
        if rows <= 1 { return SwitcherGrid(count: n, columns: max(1, n), visibleRows: 1, frontFirst: frontFirst) }
        return SwitcherGrid(count: n, columns: columns, visibleRows: visibleRows, frontFirst: frontFirst)
    }

    enum Move { case left, right, up, down }

    /// One step of the scroll ring from `index` (a dial: it goes round). Left and right run
    /// through the apps in order and wrap at the ends (the end of a row goes on to the next
    /// one); up and down keep the column and wrap top to bottom. Down into a short last row
    /// that has nothing under you lands on its last app.
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

    /// One step of the ball from `index`: a puck on the grid. It stops at the edges instead of
    /// going round (rolling a little past the last app never throws the light back to the first),
    /// and left and right stay in their row. Down into a short last row that has nothing under
    /// you lands on its last app.
    func stepped(_ index: Int, _ move: Move) -> Int {
        guard count > 0 else { return 0 }
        let i = min(max(0, index), count - 1)
        let column = i % columns
        let row = i / columns
        switch move {
        case .right: return column < columns - 1 && i + 1 < count ? i + 1 : i
        case .left: return column > 0 ? i - 1 : i
        case .down:
            if i + columns < count { return i + columns }
            return row < rows - 1 ? count - 1 : i
        case .up: return i - columns >= 0 ? i - columns : i
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
    /// Nil until the main thread has built the list. The grid of what's showing: the list less
    /// the apps hidden during this hold (`hidden`).
    var grid: SwitcherGrid?
    /// The list's own grid, as it came (every app in it).
    var listGrid: SwitcherGrid?
    /// Places in the list (as it came) of the apps hidden during this hold, in the order hidden.
    var hidden: [Int] = []
    /// The last app hidden, while pressing again brings it back (until the highlight moves).
    var undoable: Int?
    /// The lit app (its place among those showing), and the first row on screen.
    var index = 0
    var firstRow = 0
    /// Roll not yet turned into steps, each way.
    var ax = 0.0, ay = 0.0
    /// Drawing only: how many times leftover roll has been forgotten after a rest. The panel
    /// lets its lean fall back by itself after `restForgets`; this makes the next model differ
    /// from the last one drawn, so a roll that leans just as far again is drawn again.
    var rests = 0
    /// When the ball last moved, and when the highlight last stepped (time since the press).
    var lastMove = 0.0
    var lastStep = -Double.infinity
    /// The farthest the ball got from where it started, for the tap.
    var rawX = 0.0, rawY = 0.0
    var travel = 0.0
    /// Ring steps that came before the list did (applied when it arrives).
    var pendingRing = 0
    /// The panel may show (after `revealDelay`, a roll past the slop, or a ring turn).
    var revealed = false
    var ringUsed = false
    /// Esc or the primary button: nothing switches, and the panel goes away until the release.
    var dismissed = false

    /// The panel appears this long after the press if nothing else brought it up. A release
    /// before then without rolling is the tap; after it, a switch to the lit app.
    static let revealDelay = 0.2

    /// The highlight only moves on a clear roll (Levi, beta 32: "sometimes it jumps around"):
    /// - Roll left over from the last step is forgotten once the ball has rested this long, so
    ///   the jiggle of pressing or letting go of a button never tips the light onto a neighbour.
    static let restForgets = 0.12
    /// - A step needs its axis to lead the other by this much (on a grid of several rows; a
    ///   single row ignores up and down altogether).
    static let dominance = 1.4
    /// - At most one step per report, and never two closer than this (20 a second), so a flick
    ///   moves the light a few places instead of flinging it across the panel.
    static let minStepInterval = 0.05
    /// - Roll beyond this many steps isn't queued: what a flick piles up past it is dropped.
    static let backlogSteps = 2.0

    /// The panel is (or should be) on screen: revealed, not dismissed, with apps to show.
    var shown: Bool { revealed && !dismissed && (grid?.count ?? 0) > 0 }

    /// Rolled-ahead counts never queue more than this many steps before the list arrives.
    private var pendingLimit: Double { step * 3 }

    /// `now` is the hold's own clock (anything that only ever goes forward).
    mutating func ball(dx: Double, dy: Double, now: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        rawX += dx
        rawY += dy
        travel = max(travel, (rawX * rawX + rawY * rawY).squareRoot())
        if travel >= tapSlop { revealed = true }
        guard !dismissed else { return }
        if grid != nil, now - lastMove >= Self.restForgets {
            if ax != 0 || ay != 0 { rests &+= 1 }   // (drawing only)
            ax = 0
            ay = 0
        }
        lastMove = now
        ax += dx
        ay += dy
        let limit = grid == nil ? pendingLimit : step * Self.backlogSteps
        ax = min(max(ax, -limit), limit)
        ay = min(max(ay, -limit), limit)
        applySteps(now: now, catchUp: false)
    }

    /// Turns rolled counts into steps across the grid: one step per call (`catchUp`: as many as
    /// are waiting, for the roll that came before the list), at most every `minStepInterval`,
    /// along an axis that clearly leads. A step one way forgets the other way's leftovers, so a
    /// slow drift never crosses a row by accident while you roll along it.
    mutating func applySteps(now: Double, catchUp: Bool) {
        guard let grid, grid.count > 0, step > 0 else { return }
        if grid.rows <= 1 { ay = 0 }   // one row: up and down mean nothing
        for _ in 0..<(catchUp ? 8 : 1) {
            guard catchUp || now - lastStep >= Self.minStepInterval else { break }
            let move: SwitcherGrid.Move
            if abs(ax) >= step, abs(ax) >= Self.dominance * abs(ay) {
                move = ax > 0 ? .right : .left
                ax -= ax > 0 ? step : -step
                ay = 0
            } else if abs(ay) >= step, abs(ay) >= Self.dominance * abs(ax) {
                move = ay > 0 ? .down : .up   // +y is toward you: down
                ay -= ay > 0 ? step : -step
                ax = 0
            } else {
                break
            }
            lastStep = now
            let next = grid.stepped(index, move)
            if next != index { index = next; undoable = nil }
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
        let next = grid.moved(index, clockwise ? .right : .left)
        if next != index { index = next; undoable = nil }
        ax = 0
        ay = 0
        firstRow = grid.firstRow(showing: index, from: firstRow)
    }

    /// The main thread built the list: the previous app lit (the one in front if it's alone,
    /// or the first if the one in front isn't in it), then whatever was rolled or turned meanwhile.
    mutating func ready(_ g: SwitcherGrid, now: Double) {
        grid = g
        listGrid = g
        hidden = []
        undoable = nil
        index = g.startIndex
        firstRow = 0
        guard !dismissed, g.count > 0 else { return }
        for _ in 0..<abs(pendingRing) { index = g.moved(index, pendingRing > 0 ? .right : .left) }
        pendingRing = 0
        applySteps(now: now, catchUp: true)
        firstRow = g.firstRow(showing: index, from: firstRow)
    }

    /// The places in the list (as it came) of the apps showing, in order.
    var showing: [Int] {
        guard let listGrid else { return [] }
        let gone = Set(hidden)
        return (0..<listGrid.count).filter { !gone.contains($0) }
    }

    /// The lit app's place in the list as it came (what the release switches to).
    var litInList: Int? {
        let s = showing
        return s.indices.contains(index) ? s[index] : nil
    }

    /// What another trackball button did while the panel was up.
    enum HideResult: Equatable {
        /// The lit app (this place in the list as it came) was hidden.
        case hid(Int)
        /// The app just hidden came back (pressed again before the highlight moved).
        case restored(Int)
        /// Nothing (the last app showing can't be hidden).
        case nothing
    }

    /// Another trackball button while the panel is up: hides the lit app, or, straight after a
    /// hide and before the highlight has moved, brings that one back. The rest close up and the
    /// light stays where it was (on the app that took the hidden one's place).
    mutating func hideLit() -> HideResult {
        guard shown, let listGrid, grid != nil else { return .nothing }
        if let back = undoable {
            undoable = nil
            hidden.removeAll { $0 == back }
            let g = listGrid.keeping(listGrid.count - hidden.count)
            grid = g
            index = showing.firstIndex(of: back) ?? min(index, g.count - 1)
            ax = 0
            ay = 0
            firstRow = g.firstRow(showing: index, from: firstRow)
            return .restored(back)
        }
        let s = showing
        guard s.count > 1, s.indices.contains(index) else { return .nothing }
        let gone = s[index]
        hidden.append(gone)
        undoable = gone
        let g = listGrid.keeping(listGrid.count - hidden.count)
        grid = g
        index = min(index, g.count - 1)
        ax = 0
        ay = 0
        firstRow = g.firstRow(showing: index, from: firstRow)
        return .hid(gone)
    }

    /// Drawing only: leftover roll under this share of a step shows no lean (a resting hand).
    static let leanDeadBand = 0.15
    /// Drawing only: the lean is told in this many parts of a step each way.
    static let leanParts = 8

    /// Drawing only: how far the roll left over since the last step has got toward the next
    /// one, each way, in eighths of a step (−8…8; +x right, +y down). Nothing toward an edge
    /// the light can't go past, nothing under the dead band, and when neither way clearly
    /// leads (a diagonal, which never steps) both show at half. It decides nothing: the
    /// stepping above never reads it.
    var lean: (x: Int, y: Int) {
        guard let grid, grid.count > 0, step > 0, !dismissed else { return (0, 0) }
        func part(_ a: Double, _ forward: SwitcherGrid.Move, _ back: SwitcherGrid.Move) -> Double {
            guard a != 0, grid.stepped(index, a > 0 ? forward : back) != index else { return 0 }
            let f = (abs(a) / step - Self.leanDeadBand) / (1 - Self.leanDeadBand)
            return (a > 0 ? 1 : -1) * min(max(f, 0), 1)
        }
        var x = part(ax, .right, .left)
        var y = grid.rows > 1 ? part(ay, .down, .up) : 0
        if abs(ax) >= Self.dominance * abs(ay) { y = 0 }
        else if abs(ay) >= Self.dominance * abs(ax) { x = 0 }
        else { x /= 2; y /= 2 }
        let n = Double(Self.leanParts)
        return (Int((x * n).rounded(.towardZero)), Int((y * n).rounded(.towardZero)))
    }

    /// The panel as it should look now; nil while it's hidden.
    var overlay: SwitcherOverlayModel? {
        guard shown, let grid else { return nil }
        let lean = lean
        return SwitcherOverlayModel(session: session, grid: grid, selected: index, firstRow: firstRow,
                                    hidden: hidden, undoable: undoable != nil,
                                    leanX: lean.x, leanY: lean.y, rests: rests)
    }
}

/// What the Switcher's panel shows (`EngineIO.showSwitcher`): only numbers. The panel looks up
/// the apps themselves in its own list for `session`.
struct SwitcherOverlayModel: Equatable {
    var session: Int
    /// What's showing: the list less the apps hidden during this hold.
    var grid: SwitcherGrid
    /// The lit app among those showing (0 is the one in front, unless it's hidden).
    var selected: Int
    /// The first row on screen (when there are more rows than fit).
    var firstRow: Int
    /// Places in the list (as it came) of the apps hidden during this hold, in the order hidden.
    var hidden: [Int] = []
    /// The last hide can be undone by pressing again (the panel says so).
    var undoable = false
    /// Drawing only: how far the leftover roll leans toward the next app each way, in eighths
    /// of a step (`SwitcherHold.lean`), and how often a rest has dropped it (`SwitcherHold.rests`).
    var leanX = 0, leanY = 0
    var rests = 0
}

/// Builds the app list, draws the panel and switches apps for the Switcher (the app's
/// `SwitcherOverlayPanel`). Main thread only.
protocol SwitcherPresenting: AnyObject {
    /// Builds the list of running apps for a new hold, for the display that has `point`
    /// (global Quartz coordinates) on it, keeps it under `session`, and returns its grid.
    /// `buttons`: the Switcher's button (or combo); `hidden`: the bundle IDs it leaves out.
    func prepareSwitcher(session: Int, near point: CGPoint, buttons: [Int], hidden: [String]) -> SwitcherGrid
    /// Shows the panel, or updates it.
    func showSwitcher(_ model: SwitcherOverlayModel, near point: CGPoint)
    func hideSwitcher()
    /// Switches to app `index` of `session`'s list (once; the list is gone afterwards).
    func activateSwitcher(session: Int, index: Int)
    /// Drawing only: the release is about to switch to app `index` of `session`'s list (sent
    /// before the panel is taken down, so it can leave by lifting that app's icon).
    func switcherChose(session: Int, index: Int)
    /// App `index` of `session`'s list was hidden from its Switcher (`hidden`), or brought back.
    func switcherAppHidden(session: Int, index: Int, hidden: Bool)
}
