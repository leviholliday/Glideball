import SwiftUI

/// Automatic backups: whether they're on, a year at a glance, and every
/// backup you can go back to, grouped by week and month.
struct BackupHistorySection: View {
    let model: AppModel
    @Bindable var store: BackupStore
    @State private var expanded: URL?
    @State private var hovered: URL?
    @State private var showOlder = false
    @State private var restoring: BackupStore.Backup?
    @State private var justBackedUp = false
    @State private var backedUpTask: Task<Void, Never>?

    private static let rowDividerInset = ListRowButtonStyle.dividerInset(leading: BackupRow.symbolWidth + 10)

    var body: some View {
        let sections = sections
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "Backups",
                         caption: "Every day of the last two weeks, then one a month for a year. Each backup is about a kilobyte, and only made when something changed.") {
                Button("Show in Finder") { store.revealInFinder() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            RowGroup {
                statusRow
                if let error = store.lastError {
                    SettingRow(title: .verbatim(error), symbol: "exclamationmark.triangle", tint: Theme.warn)
                }
                if store.backups.isEmpty {
                    SettingRow(title: "Your first backup is made the next time your settings change.")
                        .foregroundStyle(.secondary)
                } else {
                    BackupTimeline(backups: store.backups, highlighted: hovered ?? expanded) { backup in
                        withAnimation(Theme.Motion.spring) {
                            expanded = backup.url
                            if let first = sections.first, !first.backups.contains(backup) { showOlder = true }
                        }
                    }
                    ForEach(showOlder ? sections : Array(sections.prefix(1)), id: \.title) { section in
                        BackupListSection(model: model, store: store, title: section.title, monthly: section.monthly,
                                          backups: section.backups, expanded: expanded, dividerInset: Self.rowDividerInset,
                                          toggle: { backup in
                                              withAnimation(Theme.Motion.spring) { expanded = expanded == backup.url ? nil : backup.url }
                                          },
                                          hover: { backup, inside in
                                              hovered = inside ? backup.url : (hovered == backup.url ? nil : hovered)
                                          },
                                          restore: { restoring = $0 })
                    }
                    if sections.count > 1 {
                        olderRow
                    }
                }
            }
        }
        .confirmationDialog("Restore the backup from \(restoring.map(Self.when) ?? "")?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { backup in
            Button("Restore") {
                withAnimation(Theme.Motion.spring) { model.restoreBackup(backup) }
            }
        } message: { backup in
            Text(verbatim: restoreMessage(backup))
        }
        .onDisappear { backedUpTask?.cancel() }
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            RowSymbol(symbol: store.isEnabled ? "clock.arrow.circlepath" : "clock.badge.xmark")
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic backups").font(Theme.Font.body)
                Text(statusText)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: backUp) {
                if justBackedUp {
                    Label("Backed up", systemImage: "checkmark").foregroundStyle(Theme.ok)
                } else {
                    Label("Back Up Now", systemImage: "plus.circle")
                }
            }
            .controlSize(.small)
            .fixedSize()
            Toggle("Automatic backups", isOn: $store.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Back up your settings once a day")
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .animation(Theme.Motion.fade, value: justBackedUp)
    }

    /// Back Up Now, and a checkmark in its place for a moment when it worked (a failure shows as a row below).
    private func backUp() {
        model.backUpNow()
        guard store.lastError == nil else { return }
        justBackedUp = true
        backedUpTask?.cancel()
        backedUpTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { justBackedUp = false }
        }
    }

    private var statusText: String {
        guard let newest = store.backups.first else {
            return store.isEnabled
                ? String(localized: "On — nothing backed up yet", comment: "Automatic backups status")
                : String(localized: "Off", comment: "Automatic backups status")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file)
        let count = String(localized: "\(store.backups.count) backups")
        guard store.isEnabled else {
            return String(localized: "Off · \(count) · \(size)", comment: "Automatic backups status: count, total size")
        }
        let latest = BackupDates.label(newest.date, style: .recent)
        return String(localized: "\(count) · \(size) · Latest: \(latest)",
                      comment: "Automatic backups status: count, total size, date of the newest backup")
    }

    // MARK: Older backups

    private var olderRow: some View {
        Button {
            withAnimation(Theme.Motion.spring) { showOlder.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showOlder ? 180 : 0))
                    .frame(width: BackupRow.symbolWidth)
                    .accessibilityHidden(true)
                Text(showOlder ? "Hide older backups" : "Show older backups")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ListRowButtonStyle())
    }

    private struct Section {
        let title: String
        let monthly: Bool
        let backups: [BackupStore.Backup]
    }

    private var sections: [Section] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func age(_ b: BackupStore.Backup) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: b.date), to: today).day ?? 0
        }
        let thisWeek = store.backups.filter { age($0) < 7 }
        let lastWeek = store.backups.filter { (7..<BackupStore.dailyWindowDays).contains(age($0)) }
        let monthly = store.backups.filter { age($0) >= BackupStore.dailyWindowDays }
        return [
            Section(title: String(localized: "This week", comment: "Backups list section"), monthly: false, backups: thisWeek),
            Section(title: String(localized: "The week before", comment: "Backups list section"), monthly: false, backups: lastWeek),
            Section(title: String(localized: "Monthly", comment: "Backups list section"), monthly: true, backups: monthly),
        ].filter { !$0.backups.isEmpty }
    }

    // MARK: Restoring

    /// "Nov 5, 1:22 AM".
    private static func when(_ backup: BackupStore.Backup) -> String {
        backup.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Exactly what restoring changes (from now to the backup), and that it can be undone.
    private func restoreMessage(_ backup: BackupStore.Backup) -> String {
        let footer = String(localized: "Glideball saves your current settings first, and you can undo right after.")
        guard let saved = store.load(backup) else { return String(localized: "That backup couldn’t be read.") }
        let changes = BackupRow.changes(from: model.config, to: saved)
        if changes.isEmpty {
            let intro = String(localized: "This replaces your current settings with that backup. Only fine-tuning values inside a mode or app setup differ.")
            return intro + "\n\n" + footer
        }
        let intro = String(localized: "This replaces your current settings with that backup. Each line goes from what you have now to what the backup holds:")
        let lines = changes.map { "\($0.title): \($0.now) → \($0.then)" }.joined(separator: "\n")
        return intro + "\n\n" + lines + "\n\n" + footer
    }
}

// MARK: - A group of rows

/// A week's or a month's backups under a small title, with hairlines between them.
private struct BackupListSection: View {
    let model: AppModel
    let store: BackupStore
    let title: String
    let monthly: Bool
    let backups: [BackupStore.Backup]
    let expanded: URL?
    let dividerInset: CGFloat
    let toggle: (BackupStore.Backup) -> Void
    let hover: (BackupStore.Backup, Bool) -> Void
    let restore: (BackupStore.Backup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(Theme.Font.hint.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.rowHorizontal)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(backups.enumerated()), id: \.element.id) { i, backup in
                if i > 0 { Hairline().padding(.leading, dividerInset) }
                BackupRow(model: model, store: store, backup: backup, monthly: monthly,
                          isExpanded: expanded == backup.url, toggle: { toggle(backup) }, restore: { restore(backup) })
                    .onHover { hover(backup, $0) }
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Row

private struct BackupRow: View {
    let model: AppModel
    let store: BackupStore
    let backup: BackupStore.Backup
    let monthly: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let restore: () -> Void

    static let symbolWidth: CGFloat = 22

    var body: some View {
        let saved = store.load(backup)
        let changes = saved.map { Self.changes(from: model.config, to: $0) }
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.symbolWidth)
                        .accessibilityHidden(true)
                    Text(BackupDates.label(backup.date, style: monthly ? .month : .recent))
                        .font(Theme.Font.body)
                        .lineLimit(1)
                    if let kindLabel { QuietChip(text: kindLabel) }
                    Spacer(minLength: 8)
                    differenceLabel(saved: saved, changes: changes)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(ListRowButtonStyle())
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            .accessibilityHint(isExpanded ? "" : String(localized: "Shows what this backup would change"))

            if isExpanded, let saved, let changes {
                detail(saved: saved, changes: changes)
                    .padding(.leading, ListRowButtonStyle.dividerInset(leading: Self.symbolWidth + 10))
                    .padding(.trailing, Theme.Space.rowHorizontal)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func differenceLabel(saved: GlideConfig?, changes: [Change]?) -> some View {
        if saved == nil {
            Label("Unreadable", systemImage: "exclamationmark.triangle")
                .font(Theme.Font.hint).foregroundStyle(.secondary)
        } else if saved == current {
            Label("Same as now", systemImage: "checkmark")
                .font(Theme.Font.hint.weight(.medium)).foregroundStyle(Theme.ok)
        } else if let changes, !changes.isEmpty {
            Text("\(changes.count) differences")
                .font(Theme.Font.hint).foregroundStyle(.secondary)
        } else {
            Text("Small differences")
                .font(Theme.Font.hint).foregroundStyle(.secondary)
        }
    }

    private var current: GlideConfig {
        var c = model.config
        c.enabled = true
        return c
    }

    @ViewBuilder
    private func detail(saved: GlideConfig, changes: [Change]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if changes.isEmpty {
                Text(saved == current
                     ? "This backup matches your settings right now."
                     : "Only fine-tuning differs (a value inside a mode or app setup).")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(changes) { change in
                        HStack(spacing: 8) {
                            Image(systemName: change.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(summaryPartColor(change.symbol).map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                                .frame(width: 18)
                            Text(change.title).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(change.now).font(.system(size: 12)).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            Text(change.then).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { store.revealInFinder(backup) }
                Spacer()
                Button("Restore…", action: restore)
                    .buttonStyle(.borderedProminent)
                    .disabled(saved == current)
            }
            .controlSize(.small)
        }
    }

    struct Change: Identifiable {
        let symbol: String
        let title: String
        let now: String
        let then: String
        var id: String { title }
    }

    static func changes(from now: GlideConfig, to then: GlideConfig) -> [Change] {
        zip(now.summary, then.summary).compactMap { a, b in
            a.value == b.value ? nil : Change(symbol: a.symbol, title: a.title, now: a.value, then: b.value)
        }
    }

    private var symbol: String {
        switch backup.kind {
        case .daily: "sun.horizon"
        case .beforeImport: "square.and.arrow.down"
        case .beforeRestore: "arrow.uturn.backward"
        case .manual: "hand.tap"
        }
    }

    private var kindLabel: String? {
        switch backup.kind {
        case .daily: nil
        case .beforeImport: String(localized: "Before import", comment: "Kind of backup")
        case .beforeRestore: String(localized: "Before restore", comment: "Kind of backup")
        case .manual: String(localized: "Saved by you", comment: "Kind of backup")
        }
    }
}

// MARK: - Timeline

/// The last year on one line: the right half is the last two weeks, day by day;
/// the left half is the months before. Each dot is a backup: filled for the
/// daily ones, an open ring for the ones taken before an import or restore or
/// by you. (The list below is the accessible version of it.)
private struct BackupTimeline: View {
    let backups: [BackupStore.Backup]
    let highlighted: URL?
    let select: (BackupStore.Backup) -> Void

    /// Share of the width given to the two-week daily window.
    private let dailyShare = 0.55

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let split = w * (1 - dailyShare)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hoverFill).frame(height: 4)
                    Capsule().fill(Theme.pressedFill).frame(width: w - split, height: 4).offset(x: split)
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 12).offset(x: split)
                    ForEach(backups) { backup in
                        let isHot = backup.url == highlighted
                        let size: CGFloat = isHot ? 11 : 8
                        let filled = backup.kind == .daily
                        Circle()
                            .fill(filled ? (isHot ? Color.primary : Color.secondary) : Theme.windowBackground)
                            .overlay(Circle().strokeBorder(isHot ? Color.primary : Color.secondary, lineWidth: filled ? 0 : 1.25))
                            .frame(width: size, height: size)
                            .contentShape(Circle().inset(by: -5))
                            .position(x: x(for: backup.date, width: w), y: geo.size.height / 2)
                            .onTapGesture { select(backup) }
                            .help(BackupDates.label(backup.date, style: .recent))
                            .animation(.easeOut(duration: 0.12), value: isHot)
                    }
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 18)
            GeometryReader { geo in
                let split = geo.size.width * (1 - dailyShare)
                ZStack(alignment: .topLeading) {
                    Text("A year ago").offset(x: 0)
                    Text("2 weeks ago").fixedSize().position(x: split, y: 6)
                    Text("Today").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .frame(height: 12)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal + 6)
        .padding(.vertical, 12)
        .accessibilityHidden(true)
    }

    /// Piecewise-linear: days 0–14 fill the right share, days 14–365 the left.
    private func x(for date: Date, width: Double) -> Double {
        let days = max(Date().timeIntervalSince(date) / 86_400, 0)
        let window = Double(BackupStore.dailyWindowDays)
        let inset = 6.0
        let usable = width - inset * 2
        let fraction: Double
        if days <= window {
            fraction = 1 - (days / window) * dailyShare
        } else {
            let older = min((days - window) / (Double(BackupStore.keepDays) - window), 1)
            fraction = (1 - dailyShare) * (1 - older)
        }
        return inset + usable * fraction
    }
}

// MARK: - Dates

enum BackupDates {
    enum Style { case recent, month }

    /// "Today, 9:02 AM", "Yesterday, 8:40 AM", "Saturday, Sep 27" or "September 2026".
    static func label(_ date: Date, style: Style) -> String {
        let calendar = Calendar.current
        if style == .month {
            return date.formatted(.dateTime.month(.wide).year())
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
