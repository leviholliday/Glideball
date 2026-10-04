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
        .suggestedFileName("Glide Settings.\(GlideSettingsFile.fileExtension)")
    }
}

struct BackupView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                ExportCard(model: model)
                ImportCard(model: model)
            }
            SyncCard(model: model, sync: model.sync)
            BackupHistoryCard(model: model, store: model.backups)
            Text(versionLine)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Glide \(version) (\(build)) · Settings files end in .\(GlideSettingsFile.fileExtension) and open in Glide with a double-click."
    }
}

// MARK: - Export

private struct ExportCard: View {
    let model: AppModel
    @State private var lifted = false

    var body: some View {
        GlassCard(title: "Export", symbol: "square.and.arrow.up") {
            HStack(alignment: .center, spacing: 18) {
                SettingsFileTile(lifted: lifted)
                    .draggable(SettingsDocument(model: model)) {
                        SettingsFileTile(lifted: true).frame(width: 90)
                    }
                    .onHover { lifted = $0 }
                    .help("Drag to Finder, Messages, Mail…")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.config.summary) { row in
                        SummaryLine(row: row)
                    }
                }
            }
            Text("Drag the file anywhere, or:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: model.exportSettings) {
                        Label("Save to File…", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("e", modifiers: .command)
                    ShareLink(item: SettingsDocument(model: model),
                              preview: SharePreview("Glide Settings", image: Image(nsImage: NSApp.applicationIconImage))) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
    }
}

/// A little document with Glide's icon on it — the thing you drag.
private struct SettingsFileTile: View {
    var lifted: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                   bottomTrailingRadius: 10, topTrailingRadius: 24)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                           bottomTrailingRadius: 10, topTrailingRadius: 24)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .shadow(color: .purple.opacity(0.6), radius: 10)
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
        }
        .frame(width: 96, height: 124)
        .rotationEffect(.degrees(lifted ? -4 : 0))
        .scaleEffect(lifted ? 1.05 : 1)
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.15), radius: lifted ? 16 : 6, y: lifted ? 10 : 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
    }
}

private struct SummaryLine: View {
    let row: SettingsSummaryRow
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(row.title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(row.value).font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
    }
}

// MARK: - Import

private struct ImportCard: View {
    @Bindable var model: AppModel
    @State private var targeted = false

    var body: some View {
        GlassCard(title: "Import", symbol: "square.and.arrow.down") {
            if let pending = model.pendingImport {
                ImportPreview(model: model, pending: pending)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                dropZone
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.pendingImport?.id)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .symbolEffect(.bounce, value: targeted)
            Text(targeted ? "Drop to preview" : "Drop a settings file here")
                .font(.system(size: 14, weight: .semibold))
            Text("You’ll see exactly what changes before anything is replaced.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose File…", action: model.importSettings)
                .buttonStyle(.glass)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 196)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(targeted ? Color.cyan : Color.white.opacity(0.25))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(targeted ? Color.cyan.opacity(0.12) : Color.clear))
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.previewImport(url)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// Side-by-side: what you have now vs. what the file contains.
private struct ImportPreview: View {
    let model: AppModel
    let pending: AppModel.PendingImport

    var body: some View {
        let current = model.config.summary
        let incoming = pending.file.config.summary
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pending.fileName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(origin).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            VStack(spacing: 7) {
                ForEach(Array(zip(current, incoming)), id: \.0.id) { now, new in
                    HStack(spacing: 8) {
                        Image(systemName: now.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                        Text(now.title).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if now.value == new.value {
                            Text(new.value).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(now.value).font(.system(size: 12, design: .rounded)).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.cyan)
                            Text(new.value).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
            HStack {
                Button("Cancel") { model.pendingImport = nil }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: model.confirmImport) {
                    Label("Replace My Settings", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private var origin: String {
        var parts: [String] = []
        if let date = pending.file.exportedAt {
            parts.append("Exported " + date.formatted(date: .abbreviated, time: .shortened))
        }
        if let from = pending.file.exportedFrom { parts.append("from \(from)") }
        return parts.isEmpty ? "Glide settings file" : parts.joined(separator: " ")
    }
}

// MARK: - Sync

private struct SyncCard: View {
    let model: AppModel
    let sync: SettingsSync

    var body: some View {
        GlassCard(title: "Sync", symbol: "icloud") {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().fill(.white.opacity(0.08)).frame(width: 52, height: 52)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: sync.status == .syncing)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync with iCloud Drive").font(.system(size: 15, weight: .semibold))
                    Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if sync.isEnabled {
                    Button {
                        sync.syncNow(current: model.config)
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.glass)
                    .disabled(sync.status == .syncing)
                }
                Toggle("", isOn: Binding(get: { sync.isEnabled },
                                         set: { sync.setEnabled($0, current: model.config) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!sync.iCloudDriveAvailable && !sync.isEnabled)
            }

            if sync.isEnabled && !sync.devices.isEmpty {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sync.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.isThisMac ? "desktopcomputer" : "laptopcomputer")
                                .foregroundStyle(device.isThisMac ? .cyan : .secondary)
                                .frame(width: 20)
                            Text(device.name).font(.system(size: 13, weight: device.isThisMac ? .semibold : .regular))
                            if device.isThisMac {
                                Text("This Mac").font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .glassEffect(.regular.tint(.cyan.opacity(0.3)), in: .capsule)
                            }
                            Spacer()
                            Text(device.lastSeen, format: .relative(presentation: .named))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text("Your settings live in iCloud Drive › Glide, so every Mac signed in to your Apple Account stays in step — no extra account. The pause switch stays per-Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: "Off — settings stay on this Mac"
        case .unavailable(let why): why
        case .syncing: "Syncing…"
        case .upToDate(let date): "Up to date · " + date.formatted(.relative(presentation: .named))
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
        case .upToDate: .green
        case .syncing: .cyan
        case .error, .unavailable: .orange
        case .off: .secondary
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
                    .foregroundStyle(toast.isError ? .orange : .green)
                Text(toast.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            if let action = toast.action {
                Divider().frame(height: 16).opacity(0.4)
                switch action {
                case .undoImport:
                    Button("Undo") { model.undoImport() }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan)
                case .reveal(let url):
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        model.toast = nil
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.cyan)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, toast.celebration ? 8 : 10)
        .glassEffect(toast.celebration ? .regular.tint(.purple.opacity(0.18)) : .regular, in: .capsule)
        .shadow(color: toast.celebration ? .purple.opacity(0.35) : .black.opacity(0.25), radius: 18, y: 8)
    }
}
