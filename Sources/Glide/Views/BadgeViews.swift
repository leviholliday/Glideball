import SwiftUI

// Badges on Overview: four groups (clicks, ball, ring, setting up), each a
// grid of tiles. An earned tile is lit in its part's color (the setup ones
// in the orb's); a locked one is a dim outline whose caption says what earns
// it, and the next one in each group shows how far along you are. Clicking a
// tile opens its details (when it was earned, the number behind it) and, for
// an earned one, Share.

extension Milestone {
    /// The color a badge lights in: its part's, or the orb's for a setup badge.
    var color: Color { metric?.color ?? Theme.orbBlue }
}

/// A badge's tile: lit when earned, an outline otherwise (with a progress
/// ring on its edge when it's the next one to earn).
struct BadgeTile: View {
    let milestone: Milestone
    let earned: Bool
    /// The next badge in its group: how far along you are (0…1).
    var progress: Double? = nil
    var size: CGFloat = 44
    var hovering = false

    var body: some View {
        let m = milestone
        let color = m.color
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            if earned {
                // A lit tile: the color glowing from inside, light catching the top edge.
                Group {
                    if m.group == .setup {
                        shape.fill(LinearGradient(colors: [Theme.orbCyan, Theme.orbBlue, Theme.orbViolet, Theme.orbMagenta],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(RadialGradient(colors: [color.mix(with: .white, by: 0.35), color, color.mix(with: .black, by: 0.25)],
                                                  center: UnitPoint(x: 0.35, y: 0.25), startRadius: 1, endRadius: size * 0.9))
                    }
                }
                .shadow(color: color.opacity(0.55), radius: hovering ? size * 0.27 : size * 0.16, y: 2)
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            } else {
                shape.fill(Theme.groupFill)
                shape.strokeBorder(Theme.groupBorder, lineWidth: 1)
                if let progress {
                    shape.inset(by: 1.5)
                        .trim(from: 0, to: max(0.02, min(progress, 1)))
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .shadow(color: color.opacity(0.6), radius: 3)
                }
            }
            Image(systemName: m.symbol)
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(earned ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .shadow(color: earned ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
        }
        .frame(width: size, height: size)
    }
}

/// "Badges": the four groups, with how many are earned.
struct BadgesSection: View {
    let delight: DelightCenter
    /// Renders: open this badge's details as if clicked.
    nonisolated(unsafe) static var sandboxOpen: String?

    var body: some View {
        SectionBlock(title: "Badges", caption: "\(delight.ledger.earned.count) of \(Milestone.all.count) earned. Click one to see what’s behind it.") {
            ForEach(BadgeGroup.allCases) { g in BadgeGroupRow(group: g, delight: delight) }
        }
    }
}

private struct BadgeGroupRow: View {
    let group: BadgeGroup
    let delight: DelightCenter

    var body: some View {
        let list = Milestone.all.filter { $0.group == group }
        let earned = list.filter { delight.ledger.earned[$0.id] != nil }.count
        let next = list.first { delight.ledger.earned[$0.id] == nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if let metric = group.metric {
                    StatusDot(color: metric.color, size: 7)
                } else {
                    Circle().fill(LinearGradient(colors: [Theme.orbCyan, Theme.orbViolet], startPoint: .top, endPoint: .bottom))
                        .frame(width: 7, height: 7)
                }
                Text(verbatim: group.title).font(.system(size: 12.5, weight: .semibold))
                Text("\(Int(earned)) of \(list.count)", comment: "Badges earned in a group, like “4 of 9”")
                    .font(Theme.Font.hint)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let next {
                    Text("Next: \(next.title)", comment: "The next badge to earn in a group; %@ is its name")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 4, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(list) { m in
                    BadgeCell(milestone: m, delight: delight, isNext: m.id == next?.id)
                }
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 14)
    }
}

/// One badge in the grid: its tile, name and a short caption (the date it was
/// earned, how far along, or the goal). Click for its details.
private struct BadgeCell: View {
    let milestone: Milestone
    let delight: DelightCenter
    let isNext: Bool
    @State private var hovering = false
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let m = milestone
        let earned = delight.ledger.earned[m.id]
        let fraction = delight.ledger.progress(m, lifetime: delight.lifetime) / m.threshold
        Button {
            open = true
        } label: {
            VStack(spacing: 5) {
                BadgeTile(milestone: m, earned: earned != nil, progress: isNext ? fraction : nil, hovering: hovering)
                    .overlay(alignment: .topTrailing) {
                        if let earned, Date().timeIntervalSince(earned) < 24 * 3600 {
                            Text("New", comment: "On a badge earned in the last day")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.windowBackground))
                                .pixelBorder(Capsule(), m.color)
                                .foregroundStyle(m.color)
                                .offset(x: 10, y: -4)
                        }
                    }
                    .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
                Text(verbatim: m.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(earned != nil ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 27, alignment: .top)
                Text(verbatim: caption(earned: earned, fraction: fraction))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(earned == nil && !isNext ? 0.8 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Theme.Motion.spring) { hovering = h } }
        .help(earned.map { String(localized: "\(m.detail), earned \($0.formatted(date: .abbreviated, time: .omitted))",
                                  comment: "Badge tooltip: what earns it, then the date") }
              ?? String(localized: "Goal: \(m.hint ?? m.detail)", comment: "Badge tooltip: what earns it"))
        .accessibilityLabel(earned != nil ? String(localized: "\(m.title). \(m.detail). Earned", comment: "Badge name, then what earns it")
                                          : String(localized: "\(m.title). \(m.detail). Not yet earned", comment: "Badge name, then what earns it"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BadgeDetail(milestone: m, delight: delight)
        }
        .onAppear { if BadgesSection.sandboxOpen == m.id { open = true } }
    }

    private func caption(earned: Date?, fraction: Double) -> String {
        if let earned { return earned.formatted(.dateTime.month(.abbreviated).day()) }
        if isNext && fraction > 0 { return min(fraction, 0.99).wholePercent }
        return milestone.shortGoal
    }
}

/// A badge's details: the tile large, what it's for, when it was earned and
/// the number behind it (or how far along you are), and Share for an earned one.
struct BadgeDetail: View {
    let milestone: Milestone
    let delight: DelightCenter
    @State private var sharing = false

    var body: some View {
        if sharing {
            SharePanel(card: .badge(milestone, delight.ledger.earned[milestone.id] ?? Date()), back: { sharing = false })
        } else {
            details
        }
    }

    private var details: some View {
        let m = milestone
        let earned = delight.ledger.earned[m.id]
        let value = delight.ledger.progress(m, lifetime: delight.lifetime)
        return VStack(spacing: 14) {
            BadgeTile(milestone: m, earned: earned != nil, progress: earned == nil ? value / m.threshold : nil, size: 76)
                .padding(.top, 6)
            VStack(spacing: 4) {
                Text(verbatim: m.title).font(.system(size: 17, weight: .semibold))
                Text(verbatim: m.detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                if let earned {
                    Label(String(localized: "Earned \(earned.formatted(date: .long, time: .omitted))", comment: "Badge details; %@ is a date"),
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(m.color)
                } else {
                    ProgressView(value: min(value / m.threshold, 1))
                        .tint(m.color)
                        .frame(width: 180)
                    Text(verbatim: progressLine(value))
                        .font(Theme.Font.hint)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let hint = m.hint {
                        Text(verbatim: hint)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let stat = statLine(value) {
                    Text(verbatim: stat)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if earned != nil {
                Button {
                    withAnimation(Theme.Motion.fade) { sharing = true }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.regular)
            }
        }
        .padding(22)
        .frame(width: 300)
    }

    /// "4.2 km of 8.8 km", "2 of 3 tried", "84,210 of 100,000".
    private func progressLine(_ value: Double) -> String {
        let m = milestone
        switch m.group {
        case .setup:
            return String(localized: "\(Int(value)) of \(Int(m.threshold)) done", comment: "Setup badge progress")
        case .clicks, .ball, .scroll:
            let metric = m.metric ?? .clicks
            return String(localized: "\(metric.format(value)) of \(metric == .clicks ? Int(m.threshold).formatted() : Tally.shortDistance(m.threshold))",
                          comment: "Badge progress: an amount so far, then the goal")
        }
    }

    /// The number behind it: everything counted so far, and a comparison.
    private func statLine(_ value: Double) -> String? {
        guard let metric = milestone.metric else { return nil }
        let total = String(localized: "\(metric.format(value)) so far on this Mac", comment: "Badge details: the lifetime total; %@ is an amount")
        if let compare = Landmarks.compare(value, metric: metric) { return total + " · " + compare }
        return total
    }
}
