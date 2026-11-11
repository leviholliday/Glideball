import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The current settings as a file you can drag out of the window or share.
struct SettingsDocument: Transferable {
    let model: AppModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: AppModel.settingsType) { doc in
            guard let url = doc.model.exportToTemporaryFile() else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(url)
        }
        .suggestedFileName("Glideball Settings.\(GlideSettingsFile.fileExtension)")
    }
}

/// Sync: where your settings stand (on or off, last synced, which Macs), then
/// what you can do (sync now, export, import), then the automatic backups.
struct BackupView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SyncSection(model: model, sync: model.sync)
            ExportSection(model: model)
            ImportSection(model: model)
            BackupHistorySection(model: model, store: model.backups)
            Text(versionLine)
                .font(Theme.Font.hint)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Glideball \(version) (\(build)) · Settings files end in .\(GlideSettingsFile.fileExtension) and open in Glideball with a double-click.",
                      comment: "Glideball 2.6 (9) · …end in .glide-settings…")
    }
}

/// The part a summary line is about, when it's about one (pointer: the ball, scrolling: the ring, buttons and combos: the buttons).
func summaryPartColor(_ symbol: String) -> Color? {
    switch symbol {
    case "cursorarrow.motionlines": Theme.ball
    case "arrow.up.and.down.circle": Theme.ring
    case "button.programmable", "square.on.square": Theme.buttons
    default: nil
    }
}

// MARK: - Sync

private struct SyncSection: View {
    let model: AppModel
    let sync: SettingsSync

    var body: some View {
        SectionBlock(title: "iCloud Drive",
                     caption: "Your settings live in iCloud Drive › Glide, so every Mac signed in to your Apple Account stays in step — no extra account. The pause switch stays per-Mac.") {
            statusRow
            if sync.isEnabled {
                ForEach(sync.devices) { device in
                    SettingRow(title: .verbatim(device.name),
                               symbol: device.isThisMac ? "desktopcomputer" : "laptopcomputer") {
                        HStack(spacing: 8) {
                            if device.isThisMac { QuietChip(text: String(localized: "This Mac")) }
                            Text(device.lastSeen, format: .relative(presentation: .named))
                                .font(Theme.Font.hint)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SyncNowRow(model: model, sync: sync)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            Group {
                if sync.status == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 15))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: Theme.Space.symbolColumn)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync with iCloud Drive").font(Theme.Font.body)
                Text(statusText)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Sync with iCloud Drive", isOn: Binding(get: { sync.isEnabled },
                                                           set: { sync.setEnabled($0, current: model.config) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!sync.iCloudDriveAvailable && !sync.isEnabled)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .animation(Theme.Motion.fade, value: statusText)
    }

    private var statusText: String {
        switch sync.status {
        case .off: String(localized: "Off — settings stay on this Mac")
        case .unavailable(let why): why
        case .syncing: String(localized: "Syncing…")
        case .upToDate(let date): String(localized: "Up to date · \(date.formatted(.relative(presentation: .named)))",
                                         comment: "%@ is a relative time like “5 minutes ago”")
        case .error(let message): message
        }
    }

    private var statusSymbol: String {
        switch sync.status {
        case .off: "icloud.slash"
        case .unavailable: "exclamationmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .error: "exclamationmark.icloud"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .upToDate: Theme.ok
        case .syncing, .off: Color.secondary
        case .error, .unavailable: Theme.warn
        }
    }
}

/// "Sync now": while it runs the button gives way to a spinner, and when it's
/// done a checkmark says so for a moment, right where you pressed it.
private struct SyncNowRow: View {
    let model: AppModel
    let sync: SettingsSync
    @State private var justFinished = false
    @State private var finishedTask: Task<Void, Never>?

    var body: some View {
        SettingRow(title: "Sync now",
                   hint: "Checks iCloud Drive for changes from your other Macs and sends this Mac’s.",
                   symbol: "arrow.triangle.2.circlepath") {
            Group {
                if sync.status == .syncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else if justFinished {
                    Label("Up to date", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ok)
                } else {
                    Button("Sync Now") { sync.syncNow(current: model.config) }
                        .controlSize(.small)
                }
            }
            .transition(.opacity)
        }
        .animation(Theme.Motion.fade, value: sync.status == .syncing)
        .animation(Theme.Motion.fade, value: justFinished)
        .onChange(of: sync.status) { old, new in
            guard old == .syncing, case .upToDate = new else { return }
            justFinished = true
            finishedTask?.cancel()
            finishedTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { justFinished = false }
            }
        }
        .onDisappear { finishedTask?.cancel() }
    }
}

// MARK: - Export

private struct ExportSection: View {
    let model: AppModel
    @State private var lifted = false

    var body: some View {
        SectionBlock(title: "Export") {
            HStack(spacing: Theme.Space.symbolGap + 2) {
                SettingsFileChip(lifted: lifted)
                    .draggable(SettingsDocument(model: model)) {
                        SettingsFileChip(lifted: true)
                    }
                    .onHover { lifted = $0 }
                    .help("Drag to Finder, Messages, Mail…")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your settings as a file").font(Theme.Font.body)
                    Text("Drag the file anywhere, or save or share it.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: model.exportSettings) {
                        Label("Save to File…", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("e", modifiers: .command)
                    ShareLink(item: SettingsDocument(model: model),
                              preview: SharePreview("Glideball Settings", image: Image(nsImage: NSApp.applicationIconImage))) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, Theme.Space.rowVertical)
            .frame(minHeight: Theme.Space.rowMinHeight)

            VStack(alignment: .leading, spacing: 8) {
                Text("What’s in the file")
                    .font(Theme.Font.hint.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(model.config.summary) { row in
                    SummaryLine(row: row)
                }
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small document with Glideball's icon on it: the thing you drag.
private struct SettingsFileChip: View {
    var lifted: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5,
                                           bottomTrailingRadius: 5, topTrailingRadius: 10, style: .continuous)
        ZStack {
            shape.fill(Theme.groupFill)
                .pixelBorder(shape, Theme.hairline)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        }
        .frame(width: 30, height: 38)
        .scaleEffect(lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.12), value: lifted)
        .accessibilityHidden(true)
    }
}

private struct SummaryLine: View {
    let row: SettingsSummaryRow
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 12))
                .foregroundStyle(summaryPartColor(row.symbol).map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .frame(width: 18)
            Text(row.title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(row.value).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Import

private struct ImportSection: View {
    @Bindable var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "Import")
            if let pending = model.pendingImport {
                ImportPreview(model: model, pending: pending)
                    .transition(.opacity)
            } else {
                dropTarget
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fade, value: model.pendingImport?.id)
    }

    /// One row that takes a dropped file (the group's edge turns blue while one's over it) or opens the file chooser.
    private var dropTarget: some View {
        RowGroup {
            SettingRow(title: targeted ? "Drop to preview" : "Drop a settings file here",
                       hint: "You’ll see exactly what changes before anything is replaced.",
                       symbol: targeted ? "arrow.down.doc.fill" : "arrow.down.doc",
                       tint: targeted ? Theme.ball : nil) {
                Button("Choose File…", action: model.importSettings)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .strokeBorder(Theme.ball, lineWidth: 1.5)
                .opacity(targeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.previewImport(url)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// What you have now against what the file holds, and what replacing does.
private struct ImportPreview: View {
    let model: AppModel
    let pending: AppModel.PendingImport

    var body: some View {
        let current = model.config.summary
        let incoming = pending.file.config.summary
        RowGroup {
            HStack(spacing: Theme.Space.symbolGap) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.fileName).font(Theme.Font.body.weight(.medium)).lineLimit(1)
                    Text(origin).font(Theme.Font.hint).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, Theme.Space.rowVertical)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ForEach(Array(zip(current, incoming)), id: \.0.id) { now, new in
                    HStack(spacing: 8) {
                        Image(systemName: now.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(summaryPartColor(now.symbol).map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                            .frame(width: 18)
                        Text(now.title).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if now.value == new.value {
                            Text(new.value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(now.value).font(.system(size: 12)).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            Text(new.value).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 12) {
                Text("This replaces your current settings with the ones in this file. Glideball saves a backup first, and you can undo right after.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.pendingImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action: model.confirmImport) {
                    Label("Replace My Settings", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, Theme.Space.rowVertical)
        }
    }

    private var origin: String {
        let date = pending.file.exportedAt?.formatted(date: .abbreviated, time: .shortened)
        switch (date, pending.file.exportedFrom) {
        case let (date?, from?): return String(localized: "Exported \(date) from \(from)", comment: "Date, then the Mac's name")
        case let (date?, nil): return String(localized: "Exported \(date)")
        case let (nil, from?): return String(localized: "Exported from \(from)", comment: "The Mac's name")
        case (nil, nil): return String(localized: "Glideball settings file")
        }
    }
}

// MARK: - Toast

/// A small glass notice at the bottom of the window, with an optional action.
struct ToastView: View {
    let toast: AppModel.Toast
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if toast.celebration {
                CelebrationToastIcon(symbol: toast.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let detail = toast.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Image(systemName: toast.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(toast.isError ? Theme.warn : Theme.ok)
                Text(toast.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            if let action = toast.action {
                Hairline(vertical: true).frame(height: 16)
                switch action {
                case .undoImport:
                    Button("Undo") { model.undoImport() }
                        .buttonStyle(HoverButtonStyle(radius: 6)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ball)
                case .reveal(let url):
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        model.toast = nil
                    }
                    .buttonStyle(HoverButtonStyle(radius: 6)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ball)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, toast.celebration ? 8 : 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
