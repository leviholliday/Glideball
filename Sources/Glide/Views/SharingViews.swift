import AppKit
import CoreImage
import SwiftUI

// The two sheets of sharing a setup: the preview of something coming in (a
// glideball://import link, a shared file, KensingtonWorks' settings), and
// Share… for sending part of your own setup as a link, a file or a picture.
// The logic is in AppModel+Sharing.swift and SharedSetup.swift.

// MARK: - Receiving: the preview

/// Everything that would change, setting by setting, before and after; what has
/// no equivalent (KensingtonWorks); and Apply or Cancel. Nothing changes until Apply.
struct IncomingSetupSheet: View {
    let model: AppModel
    let incoming: IncomingSetup

    var body: some View {
        let changes = model.changes(for: incoming)
        let cautions = changes.filter(\.caution).count
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if changes.isEmpty {
                        RowGroup {
                            SettingRow(title: "Nothing would change",
                                       hint: "This matches what you have already.",
                                       symbol: "checkmark.circle")
                        }
                    }
                    ForEach(ImportChange.Area.allCases.filter { a in changes.contains { $0.area == a } }, id: \.self) { area in
                        ChangeSection(area: area, changes: changes.filter { $0.area == area })
                    }
                    if !incoming.notes.isEmpty {
                        NotesSection(notes: incoming.notes)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.scrollHeight(changes: changes, notes: incoming.notes.count))
            Hairline()
            footer(cautions: cautions, nothing: changes.isEmpty)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 580)
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
    }

    /// Tall enough for a short list without scrolling, never taller than a small window.
    static func scrollHeight(changes: [ImportChange], notes: Int) -> CGFloat {
        let sections = Set(changes.map(\.area)).count + (notes > 0 ? 1 : 0)
        let rows = max(changes.count, 1) + notes
        return min(max(CGFloat(rows) * 48 + CGFloat(sections) * 34 + 16, 120), 420)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: incoming.title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: incoming.origin)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch incoming.content {
        case .kensingtonWorks: "arrow.down.left.arrow.up.right"
        case .shared(let s): s.kind.symbol
        }
    }

    /// The part it's about, in that part's color; the ball's blue otherwise.
    private var tint: Color {
        switch incoming.kind {
        case .scrolling: Theme.ring
        case .buttons: Theme.buttons
        default: Theme.ball
        }
    }

    private func footer(cautions: Int, nothing: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if cautions > 0 {
                    Label {
                        Text("Some of these open apps or press keyboard shortcuts. Check them before you apply.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    }
                } else {
                    Text("Apply saves a backup first, and you can undo right after.")
                }
            }
            .font(Theme.Font.hint)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { model.cancelIncoming() }
                .keyboardShortcut(.cancelAction)
            Button {
                model.applyIncoming()
            } label: {
                Text(incoming.source == .kensingtonWorks ? "Import" : "Apply")
                    .frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ball)
            .keyboardShortcut(.defaultAction)
            .disabled(nothing)
        }
        .controlSize(.large)
    }
}

/// One area's changes: its title, then a row per setting.
private struct ChangeSection: View {
    let area: ImportChange.Area
    let changes: [ImportChange]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            Label {
                Text(verbatim: area.title).font(Theme.Font.body.weight(.semibold))
            } icon: {
                Image(systemName: area.symbol).foregroundStyle(partColor)
            }
            .accessibilityAddTraits(.isHeader)
            RowGroup {
                ForEach(changes) { ChangeRow(change: $0) }
            }
        }
    }

    private var partColor: Color {
        switch area {
        case .pointer: Theme.ball
        case .scrolling: Theme.ring
        case .buttons, .combos: Theme.buttons
        default: .secondary
        }
    }
}

/// "Top left    Copy (⌘C)" with what it was under it, struck through.
private struct ChangeRow: View {
    let change: ImportChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 5) {
                if change.caution {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warn)
                        .help("Opens an app or presses keys")
                }
                Text(verbatim: change.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 176, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let after = change.after {
                    Text(verbatim: after)
                        .font(.system(size: 12.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Removed", comment: "Import preview: a combo or app setup that would go away")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if let before = change.before {
                    Text(verbatim: before)
                        .font(.system(size: 11))
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("New", comment: "Import preview: a combo or app setup you don't have yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// KensingtonWorks settings Glideball has nothing for, each with why.
private struct NotesSection: View {
    let notes: [KensingtonWorksImport.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "No equivalent in Glideball",
                         caption: "These stay in KensingtonWorks’ file and aren’t imported.")
            RowGroup {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.title).font(.system(size: 12, weight: .medium))
                        Text(verbatim: note.detail)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.rowHorizontal)
                    .padding(.vertical, 9)
                }
            }
        }
    }
}

// MARK: - Sending: Share…

/// Pick a part (or it's one app's setup), then copy a link, save or share a file,
/// or make a picture with a QR code of the link.
struct ShareSetupSheet: View {
    let model: AppModel
    let request: ShareRequest
    @State private var kind: ShareKind
    @State private var done: String?
    @State private var anchor = AnchorHolder()
    @Environment(\.dismiss) private var dismiss

    /// Renders: the picture, drawn beforehand (nil: drawn when shown).
    nonisolated(unsafe) static var sandboxDone: String?

    init(model: AppModel, request: ShareRequest) {
        self.model = model
        self.request = request
        _kind = State(initialValue: request.kind)
    }

    private var share: SharedSetup? { model.share(kind, appSetup: request.appSetup) }
    private var link: URL? { share?.link() }
    private var name: String {
        kind == .appSetup ? (model.config.profile(for: request.appSetup)?.name ?? kind.title) : kind.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.canChoose ? "Share your setup" : "Share this app’s setup")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Whoever opens it sees exactly what would change and decides. Nothing else about you or your Mac goes with it.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.canChoose {
                SectionBlock(title: "What to share", dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
                    ForEach(ShareKind.choosable) { k in
                        KindRow(kind: k, headline: model.headline(k), selected: k == kind) {
                            withAnimation(Theme.Motion.fade) { kind = k; done = nil }
                        }
                    }
                }
            } else {
                RowGroup {
                    HStack(spacing: Theme.Space.symbolGap) {
                        AppIcon(bundleID: request.appSetup ?? "", size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: name).font(Theme.Font.body.weight(.medium))
                            Text(verbatim: model.headline(.appSetup, appSetup: request.appSetup))
                                .font(Theme.Font.hint).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.rowHorizontal)
                    .padding(.vertical, Theme.Space.rowVertical)
                }
            }
            SectionBlock(title: "Send it", dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
                SettingRow(title: "Link",
                           hint: link == nil ? "Too much for a link. Send the file instead." : "Paste it in a message. It opens in Glideball.",
                           symbol: "link") {
                    Button("Copy Link") { copyLink() }
                        .disabled(link == nil)
                }
                SettingRow(title: "Settings file", hint: "Small enough for any message. Double-click it to open it in Glideball.", symbol: "doc") {
                    HStack(spacing: 8) {
                        Button("Share…") { shareFile() }
                            .background(ShareAnchorView(holder: anchor))
                        Button("Save…") { saveFile() }
                    }
                }
                SettingRow(title: "Picture",
                           hint: link == nil ? "A picture of the key settings." : "A picture of the key settings, with a QR code of the link.",
                           symbol: "photo") {
                    HStack(spacing: 8) {
                        Button("Copy") { copyPicture() }
                        Button("Save…") { savePicture() }
                    }
                }
            }
            .controlSize(.small)
            HStack(spacing: 12) {
                Group {
                    if let done {
                        Label(done, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                            .transition(.opacity)
                    }
                }
                .font(Theme.Font.hint)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
        .onAppear { if let d = Self.sandboxDone { done = d } }
        .onExitCommand { close() }
    }

    private func close() {
        model.shareRequest = nil
        dismiss()
    }

    private func say(_ text: String) { withAnimation(Theme.Motion.fade) { done = text } }

    private func copyLink() {
        guard let link else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link.absoluteString, forType: .string)
        say(String(localized: "Link copied. Paste it anywhere."))
    }

    private var fileName: String { String(localized: "Glideball setup – \(name)", comment: "Share picture file name; %@ is what's shared, like “Scroll feel”") }

    private func shareFile() {
        guard let share, let url = model.shareFile(share, name: fileName), let view = anchor.view, view.window != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func saveFile() {
        guard let share, let data = try? share.fileData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AppModel.settingsType]
        panel.nameFieldStringValue = ShareImage.safeName(fileName) + "." + GlideSettingsFile.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            say(String(localized: "Saved “\(url.deletingPathExtension().lastPathComponent)”"))
        } catch {
            say(String(localized: "Couldn’t save it: \(error.localizedDescription)"))
        }
    }

    private var card: ShareCard {
        .setup(model.setupCard(kind, appSetup: request.appSetup, link: link?.absoluteString))
    }

    private func copyPicture() {
        guard let image = ShareImage.render(card, delight: model.delight), ShareImage.copy(image) else { return }
        say(String(localized: "Copied. Paste it anywhere."))
    }

    private func savePicture() {
        guard let image = ShareImage.render(card, delight: model.delight), let data = ShareImage.png(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = card.fileName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            say(String(localized: "Saved “\(url.deletingPathExtension().lastPathComponent)”"))
        } catch {
            say(String(localized: "Couldn’t save it: \(error.localizedDescription)"))
        }
    }
}

/// A part to share: its symbol, name, what it holds now, and a check when chosen.
private struct KindRow: View {
    let kind: ShareKind
    let headline: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Theme.Space.symbolGap) {
                RowSymbol(symbol: kind.symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: kind.title).font(Theme.Font.body)
                    Text(verbatim: headline)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var tint: Color? {
        switch kind {
        case .pointer: Theme.ball
        case .scrolling: Theme.ring
        case .buttons: Theme.buttons
        default: nil
        }
    }
}

private struct ShareAnchorView: NSViewRepresentable {
    let holder: AnchorHolder
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}

// MARK: - Share this… (page headers)

/// The share menu in a page's header: this page's part, and everything.
struct PageShareMenu: View {
    let tab: GlideTab
    let model: AppModel

    static func kinds(for tab: GlideTab) -> [ShareKind] {
        switch tab {
        case .pointer: [.pointer, .everything]
        case .scroll: [.scrolling, .everything]
        case .buttons: [.buttons, .everything]
        case .apps: [.appSetup, .everything]
        case .overview: [.everything, .look]
        case .backup: [.everything]
        }
    }

    static func menuTitle(_ kind: ShareKind) -> String {
        switch kind {
        case .everything: String(localized: "Share Everything…", comment: "Share menu")
        case .appSetup: String(localized: "Share This App’s Setup…", comment: "Share menu")
        case .pointer: String(localized: "Share Pointer Feel…", comment: "Share menu")
        case .scrolling: String(localized: "Share Scroll Feel…", comment: "Share menu")
        case .buttons: String(localized: "Share Buttons and Gestures…", comment: "Share menu")
        case .look: String(localized: "Share Ball Color…", comment: "Share menu")
        }
    }

    var body: some View {
        Menu {
            ForEach(Self.kinds(for: tab)) { kind in
                if kind == .appSetup {
                    if let id = model.selectedProfileID, model.config.profile(for: id) != nil {
                        Button(Self.menuTitle(kind)) { model.requestShare(.appSetup, appSetup: id) }
                    }
                } else {
                    Button(Self.menuTitle(kind)) { model.requestShare(kind) }
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Share this page’s settings as a link, a file or a picture")
    }
}

// MARK: - KensingtonWorks found

/// "Found your KensingtonWorks settings" with Preview Import. Shown on the Sync
/// page and in the Welcome Tour when they're on this Mac.
struct KensingtonWorksFoundRow: View {
    let model: AppModel
    var beforePreview: (() -> Void)? = nil

    var body: some View {
        SettingRow(title: "Found your KensingtonWorks settings",
                   hint: "See how your buttons and scrolling map to Glideball before anything changes.",
                   symbol: "arrow.down.left.arrow.up.right", tint: Theme.ball) {
            Button("Preview Import") {
                if let beforePreview {
                    beforePreview()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { model.previewKensingtonWorks() }
                } else {
                    model.previewKensingtonWorks()
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - QR codes

/// A QR code made on this Mac by Core Image (no network, no dependencies).
enum QRCode {
    /// Black on white, one pixel per module (scale it up with `.interpolation(.none)`).
    static func image(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent)
    }
}

extension AppModel {
    /// The picture's words for a share: what it is and its key settings.
    func setupCard(_ kind: ShareKind, appSetup: String? = nil, link: String?) -> SetupCard {
        let c = config
        var lines: [SetupCard.Line] = []
        func line(_ t: String, _ v: String) { lines.append(.init(title: t, value: v)) }
        let buttons = { (map: [Int: ButtonAction]) in
            for b in 1...3 { line(ImportReview.buttonName(b), ImportReview.describe(map[b] ?? .system, on: b)) }
        }
        var title = kind.title
        switch kind {
        case .everything:
            line(String(localized: "Pointer speed"), c.trackingSpeed.formatted())
            line(ImportChange.Area.scrolling.title, ImportReview.scrollLine(c.scrollSettings))
            line(String(localized: "Buttons"), headline(.buttons))
            line(String(localized: "App setups"), c.appProfilesSummary)
        case .appSetup:
            if let p = c.profile(for: appSetup) {
                title = p.name
                line(String(localized: "Pointer speed"), (p.trackingSpeed ?? c.trackingSpeed).formatted())
                line(ImportChange.Area.scrolling.title, ImportReview.scrollLine(p.scroll ?? c.scrollSettings))
                for b in 1...2 { line(ImportReview.buttonName(b), ImportReview.describe((p.buttons ?? c.buttons)[b] ?? .system, on: b)) }
            }
        case .pointer:
            line(String(localized: "Pointer speed"), c.trackingSpeed.formatted())
            line(String(localized: "Precision speed", comment: "Import preview: the pointer speed while Precision is on"), c.precisionSpeed.formatted())
        case .scrolling:
            let s = c.scrollSettings
            line(String(localized: "Scroll mode", comment: "Import preview"), s.scrollMode.title)
            switch s.scrollMode {
            case .native: line(String(localized: "Native speed", comment: "Import preview: the Native scroll mode's speed"), s.nativeScrollSpeed.decimals(2))
            case .flywheel:
                line(String(localized: "Glide"), String(localized: "\(Int(ImportReview.glideMs(s.flyGlide))) ms", comment: "Milliseconds"))
                line(String(localized: "Slow-turn distance"), String(localized: "\(Int(s.flyDistance)) pt", comment: "Points: a distance on screen"))
                line(String(localized: "Spin power"), s.flyAcceleration.wholePercent)
            case .follow:
                line(String(localized: "Distance per tick", comment: "Import preview: Follow mode's distance"), String(localized: "\(Int(s.scrollDistance)) pt", comment: "Points: a distance on screen"))
                line(String(localized: "Throw", comment: "Import preview: Follow mode's throw switch"), s.throwEnabled ? s.throwAmount.wholePercent : String(localized: "Off", comment: "A switch that's off"))
            }
        case .buttons:
            buttons(c.buttons)
            line(String(localized: "Combos"), c.chords.isEmpty ? String(localized: "None", comment: "No combos / no app setups") : c.chords.count.formatted())
        case .look:
            line(String(localized: "Ball color", comment: "Import preview"), BallThemeStore.title(of: BallThemeStore.shared.look))
        }
        return SetupCard(title: title, symbol: kind.symbol, lines: lines, link: link)
    }
}
