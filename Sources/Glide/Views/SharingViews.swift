import AppKit
import CoreImage
import SwiftUI

// The two sheets of sharing a setup: the preview of something coming in (a
// glideball://import link, a shared file, KensingtonWorks' settings), and
// Share… for sending a checklist of parts of your own setup as a link, a file
// or a picture. The logic is in AppModel+Sharing.swift and SharedSetup.swift.

// MARK: - Receiving: the preview

/// Everything that would change, part by part, before and after, with a switch
/// on each part to leave it out; what has no equivalent (KensingtonWorks); and
/// Apply or Cancel. Nothing changes until Apply, and only the parts still ticked.
struct IncomingSetupSheet: View {
    let model: AppModel
    let incoming: IncomingSetup
    @State private var chosen: Set<SharePart>

    init(model: AppModel, incoming: IncomingSetup, chosen: Set<SharePart>? = nil) {
        self.model = model
        self.incoming = incoming
        _chosen = State(initialValue: chosen ?? Set(incoming.parts))
    }

    private var isShare: Bool { incoming.share != nil }

    var body: some View {
        let sections: [(part: SharePart, changes: [ImportChange])] = incoming.parts.map { ($0, model.changes(for: incoming, part: $0)) }
        let all = isShare ? sections.flatMap(\.changes) : model.changes(for: incoming)
        let picked = isShare ? sections.filter { chosen.contains($0.part) }.flatMap(\.changes) : all
        let cautions = picked.filter(\.caution).count
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if all.isEmpty {
                        RowGroup {
                            SettingRow(title: "Nothing would change",
                                       hint: "This matches what you have already.",
                                       symbol: "checkmark.circle")
                        }
                    }
                    if isShare {
                        ForEach(sections.filter { !$0.changes.isEmpty }, id: \.part) { s in
                            PartChangeSection(part: s.part, title: s.part.title(apps: incoming.share?.apps ?? []),
                                              changes: s.changes, isOn: binding(s.part))
                        }
                        let same = sections.filter { $0.changes.isEmpty }.map { $0.part.title(apps: incoming.share?.apps ?? []) }
                        if !same.isEmpty && !all.isEmpty {
                            Text("Also in it, already the same as yours: \(same.formatted(.list(type: .and)))",
                                 comment: "Import preview: parts of a share that wouldn't change anything; %@ is a list of them")
                                .font(Theme.Font.hint)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(ImportChange.Area.allCases.filter { a in all.contains { $0.area == a } }, id: \.self) { area in
                            ChangeSection(area: area, changes: all.filter { $0.area == area })
                        }
                    }
                    if !incoming.notes.isEmpty {
                        NotesSection(notes: incoming.notes)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.scrollHeight(changes: all, notes: incoming.notes.count))
            Hairline()
            footer(cautions: cautions, nothing: picked.isEmpty)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 580)
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
    }

    private func binding(_ part: SharePart) -> Binding<Bool> {
        Binding(get: { chosen.contains(part) },
                set: { on in withAnimation(Theme.Motion.fade) { if on { chosen.insert(part) } else { chosen.remove(part) } } })
    }

    /// Tall enough for a short list without scrolling, never taller than a small window.
    static func scrollHeight(changes: [ImportChange], notes: Int) -> CGFloat {
        let sections = Set(changes.map(\.area)).count + (notes > 0 ? 1 : 0)
        let rows = max(changes.count, 1) + notes
        return min(max(CGFloat(rows) * 48 + CGFloat(sections) * 40 + 16, 120), 420)
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
                if let from = incoming.from {
                    // What they typed, shown as plain text and said to be just that.
                    Text("From \(Text(verbatim: from).fontWeight(.semibold).foregroundColor(.primary)) · the name they typed, not checked by Glideball",
                         comment: "Import preview: %@ is the name the sender typed, which nobody verifies")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                }
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
                } else if isShare && nothing && !chosen.isEmpty {
                    Text("Nothing ticked would change anything.", comment: "Import preview footer when the ticked parts match what you have")
                } else if isShare && chosen.isEmpty {
                    Text("Tick at least one part to apply.", comment: "Import preview footer when every part is unticked")
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
                model.applyIncoming(parts: isShare ? chosen : nil)
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

/// One part of a share: a switch to keep it or leave it out, then its rows.
private struct PartChangeSection: View {
    let part: SharePart
    let title: String
    let changes: [ImportChange]
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            Toggle(isOn: $isOn) {
                Label {
                    HStack(spacing: 6) {
                        Text(verbatim: title).font(Theme.Font.body.weight(.semibold))
                        if !isOn {
                            Text("Left out", comment: "Import preview: a part the person unticked")
                                .font(Theme.Font.hint)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: part.symbol).foregroundStyle(partColor)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityAddTraits(.isHeader)
            RowGroup {
                ForEach(changes) { ChangeRow(change: $0) }
            }
            .opacity(isOn ? 1 : 0.4)
        }
    }

    private var partColor: Color {
        switch part.area {
        case .pointer: Theme.ball
        case .scrolling: Theme.ring
        case .buttons, .combos: Theme.buttons
        default: .secondary
        }
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

/// Tick what to share (several at once), then copy a link, save or share a file,
/// or make a picture with a QR code of the link.
struct ShareSetupSheet: View {
    let model: AppModel
    let request: ShareRequest
    @State private var chosen: Set<SharePart>
    @State private var done: String?
    @State private var anchor = AnchorHolder()
    @Environment(\.dismiss) private var dismiss

    /// Renders: the note after an action, drawn beforehand.
    nonisolated(unsafe) static var sandboxDone: String?

    init(model: AppModel, request: ShareRequest, chosen: Set<SharePart>? = nil) {
        self.model = model
        self.request = request
        _chosen = State(initialValue: chosen ?? model.initialShareParts(request))
    }

    private var share: SharedSetup? { chosen.isEmpty ? nil : model.share(parts: chosen) }
    private var link: URL? { share?.link() }
    private var name: String { model.setupCard(parts: chosen, link: nil).title }

    var body: some View {
        let available = model.shareableParts
        let apps = available.filter { $0.bundleID != nil }
        let inset = Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share your setup")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Tick what to send. Whoever opens it sees exactly what would change and picks what to keep. Nothing else about you or your Mac goes with it.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: model.summary(of: chosen))
                    .font(Theme.Font.body.weight(.medium))
                    .foregroundStyle(chosen.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                Button("Everything") { set(Set(available)) }
                    .disabled(chosen == Set(available))
                Button("None") { set([]) }
                    .disabled(chosen.isEmpty)
            }
            .controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionBlock(title: "How it moves", dividerInset: inset) {
                        ForEach(available.filter { [.pointer, .displays, .scrolling].contains($0) }) { row($0) }
                    }
                    SectionBlock(title: "Buttons", dividerInset: inset) {
                        ForEach(available.filter { [.buttons, .combos, .gestures].contains($0) }) { row($0) }
                    }
                    if !apps.isEmpty {
                        SectionBlock(title: "App setups", dividerInset: inset) {
                            ForEach(apps) { row($0) }
                        }
                    }
                    SectionBlock(title: "Look and sound", dividerInset: inset) {
                        ForEach(available.filter { [.look, .sounds].contains($0) }) { row($0) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: Self.listHeight(rows: available.count, sections: apps.isEmpty ? 3 : 4))
            SectionBlock(title: "Send it", dividerInset: inset) {
                SettingRow(title: "Link", hint: LocalizedStringKey(linkHint), symbol: "link") {
                    Button("Copy Link") { copyLink() }
                        .disabled(link == nil)
                }
                SettingRow(title: "Settings file", hint: "Small enough for any message. Double-click it to open it in Glideball.", symbol: "doc") {
                    HStack(spacing: 8) {
                        Button("Share…") { shareFile() }
                            .background(ShareAnchorView(holder: anchor))
                        Button("Save…") { saveFile() }
                    }
                    .disabled(share == nil)
                }
                SettingRow(title: "Picture",
                           hint: link == nil ? "A picture of the key settings." : "A picture of the key settings, with a QR code of the link.",
                           symbol: "photo") {
                    HStack(spacing: 8) {
                        Button("Copy") { copyPicture() }
                        Button("Save…") { savePicture() }
                    }
                    .disabled(share == nil)
                }
            }
            .controlSize(.small)
            HStack(spacing: 12) {
                Group {
                    if let done {
                        Label(done, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                            .transition(.opacity)
                    } else {
                        Text(verbatim: nameNote)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.hint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
        .onAppear { if let d = Self.sandboxDone { done = d } }
        .onExitCommand { close() }
    }

    /// Short enough to leave room for Send it on a small screen; tall enough for most lists.
    static func listHeight(rows: Int, sections: Int) -> CGFloat {
        min(CGFloat(rows) * 45 + CGFloat(sections) * 42, 380)
    }

    private func row(_ part: SharePart) -> some View {
        PartRow(part: part, title: part.title(apps: model.config.appProfiles), headline: model.headline(part),
                selected: chosen.contains(part)) {
            var next = chosen
            if next.contains(part) { next.remove(part) } else { next.insert(part) }
            set(next)
        }
    }

    private func set(_ parts: Set<SharePart>) {
        withAnimation(Theme.Motion.fade) {
            chosen = parts
            done = nil
        }
        if !Sandbox.isActive { ShareChoiceMemory.save(parts) }
    }

    private var linkHint: String {
        guard share != nil else { return String(localized: "Tick something to share first.", comment: "Share: link hint with nothing ticked") }
        guard link == nil, let share else {
            return String(localized: "Opens a page that shows what’s in it, with a button to import it into Glideball.", comment: "Share: link hint")
        }
        let n = share.linkLength - SharedSetup.maxLinkLength
        return String(localized: "Too much for a link, by about \(n) characters (some apps cut long links short). Untick a part or two, or send the file instead.",
                      comment: "Share: link hint when the link would be too long; %lld is how many characters too many")
    }

    private var nameNote: String {
        if let name = SharingName.forLinks {
            return String(localized: "Your name, “\(name)”, goes with the link and file. You can change that in Settings › General.",
                          comment: "Share: the sender's name; %@ is the name")
        }
        return String(localized: "No name goes with it. You can add one in Settings › General.", comment: "Share: no name is sent")
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
        .setup(model.setupCard(parts: chosen, link: link?.absoluteString))
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

/// A part to share: its symbol (or app icon), name, what it holds now, and a tick.
private struct PartRow: View {
    let part: SharePart
    let title: String
    let headline: String
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Space.symbolGap) {
                if let id = part.bundleID {
                    AppIcon(bundleID: id, size: 20)
                        .frame(width: Theme.Space.symbolColumn)
                } else {
                    RowSymbol(symbol: part.symbol, tint: tint)
                        .frame(width: Theme.Space.symbolColumn)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(Theme.Font.body)
                    Text(verbatim: headline)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text("Includes or leaves out this part", comment: "Share: accessibility hint on a checklist row"))
    }

    private var tint: Color? {
        switch part.area {
        case .pointer: Theme.ball
        case .scrolling: Theme.ring
        case .buttons, .combos: Theme.buttons
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
    /// The picture's words for a share of `parts`: what it is and its key settings.
    func setupCard(parts: Set<SharePart>, link: String?) -> SetupCard {
        let c = config
        var lines: [SetupCard.Line] = []
        func line(_ t: String, _ v: String) { lines.append(.init(title: t, value: v)) }
        let sorted = parts.sorted()
        for part in sorted {
            switch part {
            case .pointer:
                line(String(localized: "Pointer speed"), c.trackingSpeed.formatted())
            case .displays:
                line(part.title, headline(part))
            case .scrolling:
                line(ImportChange.Area.scrolling.title, ImportReview.scrollLine(c.scrollSettings))
            case .buttons:
                for b in 2...3 { line(ImportReview.buttonName(b), ImportReview.describe(c.buttons[b] ?? .system, on: b)) }
            case .combos:
                line(String(localized: "Combos"), c.chords.isEmpty ? String(localized: "None", comment: "No combos / no app setups") : c.chords.count.formatted())
            case .gestures:
                line(part.title, headline(part))
            case .app(let id):
                if let p = c.profile(for: id) { line(p.name, p.summary(comparedTo: c)) }
            case .look:
                line(String(localized: "Ball color", comment: "Import preview"), BallThemeStore.title(of: BallThemeStore.shared.look))
            case .sounds:
                line(part.title, headline(part))
            }
        }
        let titles = sorted.map { $0.title(apps: c.appProfiles) }
        let title: String
        let symbol: String
        if sorted.count == 1, let only = sorted.first {
            title = titles[0]
            symbol = only.symbol
        } else if Set(sorted) == Set(shareableParts) {
            title = ShareKind.everything.title
            symbol = ShareKind.everything.symbol
        } else if titles.count <= 3 {
            title = titles.formatted(.list(type: .and))
            symbol = ShareKind.everything.symbol
        } else {
            let more = titles.count - 1
            title = String(localized: "\(titles[0]) and \(more) more", comment: "Share picture title: the first part, then how many others; e.g. “Pointer feel and 3 more”")
            symbol = ShareKind.everything.symbol
        }
        return SetupCard(title: title, symbol: symbol, lines: lines, link: link)
    }

    /// The picture's words for a page's own part (the self-test and renders).
    func setupCard(_ kind: ShareKind, appSetup: String? = nil, link: String?) -> SetupCard {
        setupCard(parts: Set(kind.parts(in: config, appSetup: appSetup)).intersection(shareableParts), link: link)
    }
}
