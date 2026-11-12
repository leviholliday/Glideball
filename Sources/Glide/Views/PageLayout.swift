import SwiftUI

// Wide windows. Up to `PageGrid.doubleFrom` points of room for the page, every page is
// the one column it has always been (680 pt at most, on the left). With more room the
// page's sections arrange into two columns (three where a page has a row of three),
// up to `PageGrid.maxWidth` in all, centered in the window, so lines never get long
// and the stage behind keeps filling the whole window.
//
// The window's shell measures one thing, once per change of class: how many columns
// fit (`RootView` reads its own width with `onGeometryChange`, which only calls back
// when the class changes, never while scrolling). Pages read it from the environment
// and lay out with `ColumnGrid`, a plain `Layout`: no page or card measures itself.

/// How many columns a page has room for.
enum PageWidth: Int, Comparable, Sendable {
    /// One column, as the window opens (980 wide).
    case single
    /// Two columns of about 430 pt or more.
    case double
    /// Two columns with room for a big picture on one side (a 1440-wide window and up).
    case roomy
    /// Room for three blocks side by side.
    case triple

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var isWide: Bool { self != .single }
}

enum PageGrid {
    /// Room for the page (inside its side margins) from which it goes to two columns.
    static let doubleFrom: CGFloat = 900
    /// …and from which a row of three blocks sits side by side.
    static let roomyFrom: CGFloat = 1080
    static let tripleFrom: CGFloat = 1240
    /// The most a wide page spreads to; wider windows center it.
    static let maxWidth: CGFloat = 1360
    /// Between columns.
    static let gutter: CGFloat = 36
    /// How far below the top of the visible page a sticky column rests.
    static let stickyGap: CGFloat = 14

    static func width(forRoom room: CGFloat) -> PageWidth {
        room >= tripleFrom ? .triple : room >= roomyFrom ? .roomy : room >= doubleFrom ? .double : .single
    }

    /// The class for a window's detail area this wide (the side margins taken off).
    static func width(forDetail detail: CGFloat) -> PageWidth {
        width(forRoom: detail - Theme.Space.contentSide * 2)
    }

    static func maxWidth(for w: PageWidth) -> CGFloat {
        w.isWide ? maxWidth : Theme.Space.contentMaxWidth
    }

    /// The self-test: the class the main window's shell last measured.
    nonisolated(unsafe) static var measured: PageWidth?
}

private struct PageWidthKey: EnvironmentKey { static let defaultValue = PageWidth.single }

extension EnvironmentValues {
    var pageWidth: PageWidth {
        get { self[PageWidthKey.self] }
        set { self[PageWidthKey.self] = newValue }
    }
}

extension View {
    /// The page's column inside the window: its margins, its widest, and where it sits
    /// (on the left as one column, centered once wide).
    func pageFrame(_ width: PageWidth) -> some View {
        frame(maxWidth: PageGrid.maxWidth(for: width), alignment: .leading)
            .padding(.horizontal, Theme.Space.contentSide)
            .frame(maxWidth: .infinity, alignment: width.isWide ? .center : .leading)
            .environment(\.pageWidth, width)
    }
}

// MARK: - The layout

/// Blocks in `columns` columns, row by row, each row as tall as its tallest block,
/// every block top-left in its cell. One column is a leading-aligned VStack. `shares`
/// splits the width unevenly (one per column; equal when left out).
struct ColumnGrid: Layout {
    var columns = 1
    var shares: [CGFloat]? = nil
    var hSpacing: CGFloat = PageGrid.gutter
    var vSpacing: CGFloat = Theme.Space.section

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let n = max(1, min(columns, count))
        let room = max(0, total - hSpacing * CGFloat(n - 1))
        let s = (shares?.count == n ? shares! : Array(repeating: 1, count: n))
        let sum = max(s.reduce(0, +), 0.0001)
        return s.map { room * $0 / sum }
    }

    private func rows(_ count: Int) -> [Range<Int>] {
        let n = max(1, columns)
        return stride(from: 0, to: count, by: n).map { $0..<min($0 + n, count) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let visible = subviews.indices
        guard !visible.isEmpty else { return .zero }
        let total = proposal.width ?? Theme.Space.contentMaxWidth
        let w = widths(total, count: subviews.count)
        var height: CGFloat = 0
        for (r, row) in rows(subviews.count).enumerated() {
            if r > 0 { height += vSpacing }
            height += row.enumerated().map { c, i in
                subviews[i].sizeThatFits(ProposedViewSize(width: w[c], height: nil)).height
            }.max() ?? 0
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width, count: subviews.count)
        var y = bounds.minY
        for row in rows(subviews.count) {
            var x = bounds.minX, tallest: CGFloat = 0
            for (c, i) in row.enumerated() {
                let p = ProposedViewSize(width: w[c], height: nil)
                tallest = max(tallest, subviews[i].sizeThatFits(p).height)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: p)
                x += w[c] + hSpacing
            }
            y += tallest + vSpacing
        }
    }
}

/// A page's sections in two columns once it's wide, each section on the side it's
/// marked for (`.pageColumn(.trailing)`; leading by default), stacked in its own
/// column in the order written. On a narrow page they're one column in that same
/// order, exactly as before. With nothing on one side, the other takes the width.
struct SplitColumns: Layout {
    var wide: Bool
    /// The leading column's part of the width.
    var share: CGFloat = 0.5
    var gutter: CGFloat = PageGrid.gutter
    var spacing: CGFloat = Theme.Space.section

    private func frames(_ total: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let sides = subviews.map { $0[PageSideKey.self] }
        let split = wide && sides.contains(.leading) && sides.contains(.trailing)
        let room = max(0, total - (split ? gutter : 0))
        let leadW = split ? (room * share).rounded() : total
        let trailW = split ? room - leadW : total
        var y: [PageSide: CGFloat] = [.leading: 0, .trailing: 0]
        var started: Set<PageSide> = []
        var out: [CGRect] = []
        for (i, s) in subviews.enumerated() {
            let side: PageSide = split ? sides[i] : .leading
            let w = side == .leading ? leadW : trailW
            if started.contains(side) { y[side]! += spacing }
            started.insert(side)
            let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            out.append(CGRect(x: side == .leading ? 0 : leadW + gutter, y: y[side]!, width: w, height: h))
            y[side]! += h
        }
        return (out, max(y[.leading]!, y[.trailing]!))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? Theme.Space.contentMaxWidth
        return CGSize(width: total, height: frames(total, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, f) in zip(subviews, frames(bounds.width, subviews).frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: f.width, height: nil))
        }
    }
}

enum PageSide: Hashable, Sendable { case leading, trailing }

private struct PageSideKey: LayoutValueKey {
    static let defaultValue = PageSide.leading
}

extension View {
    /// Which column of a `PageColumns` this section goes in once the page is wide.
    func pageColumn(_ side: PageSide) -> some View {
        layoutValue(key: PageSideKey.self, value: side)
    }

    /// Stays at the top of the visible page while a longer column beside it scrolls
    /// (only on a wide page; a narrow one scrolls as one).
    /// `from`: the same as its `PageColumns`' (it only sticks while there are two columns).
    func pageSticky(from: PageWidth = .double) -> some View {
        modifier(StickySection(from: from))
    }
}

/// `SplitColumns` for the page's width class.
struct PageColumns<Content: View>: View {
    var share: CGFloat = 0.5
    var spacing: CGFloat = Theme.Space.section
    /// The narrowest class that splits (a page with a big picture on one side waits for `.roomy`).
    var from: PageWidth = .double
    @ViewBuilder var content: Content
    @Environment(\.pageWidth) private var width

    var body: some View {
        SplitColumns(wide: width >= from, share: share, spacing: spacing) { content }
    }
}

/// Holds a section at the top of the visible page while the page scrolls past it.
/// A visual effect on the scroll view's own geometry: no state, nothing re-laid out,
/// nothing measured into the page.
private struct StickySection: ViewModifier {
    let from: PageWidth
    @Environment(\.pageWidth) private var width

    func body(content: Content) -> some View {
        if width >= from {
            content.visualEffect { view, proxy in
                let top = proxy.frame(in: .scrollView).minY
                return view.offset(y: max(0, PageGrid.stickyGap - top))
            }
        } else {
            content
        }
    }
}
