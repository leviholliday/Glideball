import AppKit
import SwiftUI

// The weekly recap (WeeklyRecap.swift): a card over the window, once a week
// after a week of real use, or any time from Overview's "Last week". Plain
// numbers against the week before: more is lit in the part's color, less is
// just said quietly, with no arrows or red. Then the busiest day, a
// real-world comparison, new badges, and Share….

/// The recap over the window. Return or Esc closes it.
struct RecapCard: View {
    let recap: WeeklyRecap
    let model: AppModel
    @State private var reveal = 0.0
    @State private var sharing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Renders: draw the numbers fully counted up (there's no clock in a picture).
    nonisolated(unsafe) static var sandboxStill = false

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
                .onTapGesture { close() }
            GeometryReader { g in
                card
                    .frame(maxHeight: max(320, g.size.height - 48))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            if reduceMotion || Self.sandboxStill { reveal = 1; return }
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) { reveal = 1 }
            if RecapCenter.shared.cameByItself { Sounds.shared.play(.milestone) }
        }
    }

    private func close() { RecapCenter.shared.close() }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            stats
            Hairline()
            ViewThatFits(in: .vertical) {
                details
                ScrollView { details }.scrollIndicators(.automatic)
            }
            footer
        }
        .padding(28)
        .frame(width: 580)
        .background { LitCardBackground(radius: 20) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your week with Glideball", comment: "Weekly recap title")
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: dates)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            WeekDots(recap: recap)
        }
    }

    /// "Nov 3 – 9", in the reader's own date format.
    private var dates: String {
        (recap.start..<recap.end.addingTimeInterval(3600)).formatted(.interval.month(.abbreviated).day())
    }

    // MARK: The three numbers

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(Metric.lifetimeOrder.enumerated()), id: \.element) { i, m in
                if i > 0 { Hairline(vertical: true).padding(.horizontal, 18) }
                stat(m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ m: Metric) -> some View {
        let value = recap.total.value(m)
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: m.format(value * reveal))
                .font(Theme.Font.numeral(34))
                .contentTransition(.numericText(value: value * reveal))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                Circle().fill(m.color).frame(width: 7, height: 7)
                    .shadow(color: m.color.opacity(0.7), radius: 3)
                Text(verbatim: label(m))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            changeLine(m)
                .font(Theme.Font.hint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ m: Metric) -> String {
        switch m {
        case .clicks: String(localized: "clicks", comment: "Share picture: under the number of clicks")
        case .ball: String(localized: "rolled", comment: "Share picture: under the distance the ball rolled")
        case .scroll: String(localized: "scrolled", comment: "Share picture: under the distance scrolled")
        }
    }

    @ViewBuilder private func changeLine(_ m: Metric) -> some View {
        switch recap.change(m) {
        case .up(let more):
            Label {
                Text("\(more.wholePercent) more than the week before", comment: "Weekly recap: this week was higher; %@ is a percentage")
            } icon: {
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(m.color)
        case .same:
            Text("About the same as the week before", comment: "Weekly recap")
                .foregroundStyle(.secondary)
        case .down:
            // Plainly, with no arrow and no color: a quieter week is just a quieter week.
            Text("The week before: \(m.format(recap.before.value(m)))", comment: "Weekly recap: the week before's number, said plainly; %@ is a number or distance")
                .foregroundStyle(.secondary)
        case .noBefore:
            Text("Your first week to compare", comment: "Weekly recap: nothing the week before")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Busiest day, a comparison, badges

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let busiest = recap.busiestDay {
                detailRow(symbol: "flame", tint: Theme.buttons,
                          title: String(localized: "Your busiest day was \(busiest.date.formatted(.dateTime.weekday(.wide)))",
                                        comment: "Weekly recap; %@ is a weekday, like Wednesday"),
                          detail: String(localized: "\(Metric.clicks.format(Double(busiest.tally.clicks))) clicks, \(Tally.distance(busiest.tally.scrollMeters)) scrolled",
                                         comment: "Weekly recap, under the busiest day: the first %@ is a number of clicks, the second a distance"))
            }
            if let compare = recap.comparison {
                detailRow(symbol: compare.metric == .scroll ? "building.2" : "figure.walk", tint: compare.metric.color,
                          title: compare.text,
                          detail: compare.metric == .scroll
                            ? String(localized: "How far you scrolled, stacked up", comment: "Weekly recap: what the comparison above is about")
                            : String(localized: "How far the ball rolled, laid end to end", comment: "Weekly recap: what the comparison above is about"))
            }
            if !recap.newBadges.isEmpty {
                badges
            }
        }
    }

    private func detailRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.15))
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: detail).font(Theme.Font.hint).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var badges: some View {
        let list = recap.newBadges.compactMap { id in Milestone.all.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
            Text(list.count == 1 ? String(localized: "A new badge", comment: "Weekly recap: one badge earned")
                                 : String(localized: "\(list.count) new badges", comment: "Weekly recap: badges earned that week"))
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 14) {
                ForEach(list.prefix(5)) { m in
                    VStack(spacing: 5) {
                        BadgeTile(milestone: m, earned: true, size: 46)
                        Text(verbatim: m.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.center)
                            .frame(width: 92)
                    }
                    .scaleEffect(reduceMotion ? 1 : 0.85 + 0.15 * reveal)
                    .opacity(0.3 + 0.7 * reveal)
                }
                if list.count > 5 {
                    Text("and \(list.count - 5) more", comment: "Weekly recap: more badges than shown")
                        .font(Theme.Font.hint).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                RecapCenter.shared.enabled = false
                close()
            } label: {
                Text("Turn Off Weekly Recaps", comment: "Weekly recap: a quiet link-like button")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("You can turn them back on in Settings › Look. Last week stays on Overview either way")
            .opacity(RecapCenter.shared.cameByItself ? 1 : 0)
            .disabled(!RecapCenter.shared.cameByItself)
            Spacer()
            Button {
                sharing = true
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .popover(isPresented: $sharing, arrowEdge: .bottom) {
                SharePanel(card: .recap(recap))
            }
            Button("Done") { close() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .keyboardShortcut(.defaultAction)
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .controlSize(.large)
    }
}

/// The seven days as small bars of clicks (the buttons' amber), the busiest one lit.
private struct WeekDots: View {
    let recap: WeeklyRecap

    var body: some View {
        let top = max(recap.days.map(\.clicks).max() ?? 0, 1)
        let busiest = recap.busiestDay?.date
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(recap.days.enumerated()), id: \.offset) { i, day in
                let date = Calendar.current.date(byAdding: .day, value: i, to: recap.start) ?? recap.start
                let lit = busiest.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
                VStack(spacing: 4) {
                    Capsule()
                        .fill(lit ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.9), Theme.buttons], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Theme.buttons.opacity(day.clicks > 0 ? 0.45 : 0.15)))
                        .frame(width: 7, height: max(3, 34 * CGFloat(day.clicks) / CGFloat(top)))
                        .shadow(color: lit ? Theme.buttons.opacity(0.7) : .clear, radius: 5)
                    Text(verbatim: String(date.formatted(.dateTime.weekday(.narrow))))
                        .font(.system(size: 9, weight: lit ? .bold : .medium))
                        .foregroundStyle(lit ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .frame(height: 50, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Overview's "Last week": the recap, any time there's something in it.
struct LastWeekButton: View {
    let delight: DelightCenter

    var body: some View {
        if RecapCenter.shared.recap(for: .lastWeek, delight) != nil {
            Button {
                AppModel.shared.showRecap()
            } label: {
                Label("Last week", systemImage: "calendar")
            }
            .controlSize(.small)
            .help("Your recap of last week")
        }
    }
}

// MARK: - The share picture

/// The recap as a share picture (`ShareCardView` draws the stage around it).
struct RecapShareContent<Trackball: View>: View {
    let recap: WeeklyRecap
    /// The name you chose to put on pictures, or nil.
    var name: String? = nil
    @ViewBuilder var trackball: Trackball

    var body: some View {
        HStack(spacing: 30) {
            trackball
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if let name {
                            Text("\(name)’s week with Glideball", comment: "Share picture heading for the weekly recap, with the person's name; %@ is the name they typed")
                        } else {
                            Text("My week with Glideball", comment: "Share picture heading for the weekly recap")
                        }
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(verbatim: (recap.start..<recap.end.addingTimeInterval(3600)).formatted(.interval.month(.abbreviated).day()))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ForEach(Metric.lifetimeOrder) { m in
                    let v = recap.total.value(m)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: m.format(v))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        HStack(spacing: 6) {
                            Circle().fill(m.color).frame(width: 7, height: 7)
                            Text(verbatim: label(m))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                    }
                }
                if let busiest = recap.busiestDay {
                    Text("Busiest day: \(busiest.date.formatted(.dateTime.weekday(.wide)))", comment: "Share picture, weekly recap; %@ is a weekday")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 34)
        .padding(.trailing, 26)
        .padding(.bottom, 34)
    }

    private func label(_ m: Metric) -> String {
        switch m {
        case .clicks: String(localized: "clicks", comment: "Share picture: under the number of clicks")
        case .ball: String(localized: "rolled", comment: "Share picture: under the distance the ball rolled")
        case .scroll: String(localized: "scrolled", comment: "Share picture: under the distance scrolled")
        }
    }
}
