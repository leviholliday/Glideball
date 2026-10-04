import SwiftUI

/// Automatic backups: a year at a glance, and every backup you can go back to.
struct BackupHistoryCard: View {
    let model: AppModel
    @Bindable var store: BackupStore
    @State private var expanded: URL?
    @State private var hovered: URL?

    var body: some View {
        GlassCard(title: "Backups", symbol: "clock.arrow.circlepath") {
            header
            BackupTimeline(backups: store.backups, highlighted: hovered ?? expanded) { backup in
                withAnimation(.smooth(duration: 0.25)) { expanded = backup.url }
            }
            if store.backups.isEmpty {
                Text("Your first backup is made the next time your settings change.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                list
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Every day of the last two weeks, then one a month for a year. Each backup is about a kilobyte, and only made when something changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Show in Finder") { store.revealInFinder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.08)).frame(width: 52, height: 52)
                Image(systemName: store.isEnabled ? "clock.arrow.circlepath" : "clock.badge.xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(store.isEnabled ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic backups").font(.system(size: 15, weight: .semibold))
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = store.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            Button(action: model.backUpNow) {
                Label("Back Up Now", systemImage: "plus.circle")
            }
            .buttonStyle(.glass)
            Toggle("", isOn: $store.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Back up your settings once a day")
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

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.top, section.title == sections.first?.title ? 0 : 8)
                        .padding(.leading, 4)
                    ForEach(section.backups) { backup in
                        BackupRow(model: model, store: store, backup: backup,
                                  monthly: section.monthly,
                                  isExpanded: expanded == backup.url) {
                            withAnimation(.smooth(duration: 0.25)) {
                                expanded = expanded == backup.url ? nil : backup.url
                            }
                        }
                        .onHover { hovered = $0 ? backup.url : (hovered == backup.url ? nil : hovered) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 260)
        .mask {   // fade the edge where rows scroll out of view
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            }
        }
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
}

// MARK: - Row

private struct BackupRow: View {
    let model: AppModel
    let store: BackupStore
    let backup: BackupStore.Backup
    let monthly: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let saved = store.load(backup)
        let changes = saved.map { Self.changes(from: model.config, to: $0) }
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(tint.opacity(0.15)))
                    Text(BackupDates.label(backup.date, style: monthly ? .month : .recent))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let kindLabel {
                        Text(kindLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .glassEffect(.regular.tint(tint.opacity(0.25)), in: .capsule)
                    }
                    Spacer(minLength: 8)
                    differenceLabel(saved: saved, changes: changes)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let saved, let changes {
                detail(saved: saved, changes: changes)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(isExpanded ? 0.07 : 0)))
    }

    @ViewBuilder
    private func differenceLabel(saved: GlideConfig?, changes: [Change]?) -> some View {
        if saved == nil {
            Label("Unreadable", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange)
        } else if saved == current {
            Label("Same as now", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        } else if let changes, !changes.isEmpty {
            Text("\(changes.count) differences")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Text("Small differences")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var current: GlideConfig {
        var c = model.config
        c.enabled = true
        return c
    }

    @ViewBuilder
    private func detail(saved: GlideConfig, changes: [Change]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if changes.isEmpty {
                Text(saved == current
                     ? "This backup matches your settings right now."
                     : "Only fine-tuning differs (a value inside a mode or app setup).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(changes) { change in
                        HStack(spacing: 8) {
                            Image(systemName: change.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                            Text(change.title).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(change.now).font(.system(size: 12, design: .rounded)).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.cyan)
                            Text(change.then).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            }
            HStack {
                Button("Show in Finder") { store.revealInFinder(backup) }
                    .buttonStyle(.glass)
                Spacer()
                Button {
                    model.restoreBackup(backup)
                } label: {
                    Label("Restore", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.glassProminent)
                .disabled(saved == current)
            }
            .controlSize(.regular)
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

    private var tint: Color {
        switch backup.kind {
        case .daily: .cyan
        case .beforeImport, .beforeRestore: .orange
        case .manual: .purple
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
/// the left half is the months before. Each dot is a backup.
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
                    Capsule().fill(.white.opacity(0.07)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: [.purple.opacity(0.35), .cyan.opacity(0.55)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: w - split, height: 6)
                        .offset(x: split)
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14).offset(x: split)
                    ForEach(backups) { backup in
                        let isHot = backup.url == highlighted
                        Circle()
                            .fill(color(backup))
                            .frame(width: isHot ? 13 : 9, height: isHot ? 13 : 9)
                            .overlay(Circle().strokeBorder(.white.opacity(isHot ? 0.9 : 0.4), lineWidth: 1))
                            .shadow(color: color(backup).opacity(0.7), radius: isHot ? 6 : 2)
                            .position(x: x(for: backup.date, width: w), y: geo.size.height / 2)
                            .onTapGesture { select(backup) }
                            .help(BackupDates.label(backup.date, style: .recent))
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHot)
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
        .padding(.horizontal, 6)
    }

    private func color(_ b: BackupStore.Backup) -> Color {
        switch b.kind {
        case .daily: .cyan
        case .beforeImport, .beforeRestore: .orange
        case .manual: .purple
        }
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
