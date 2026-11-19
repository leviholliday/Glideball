import AppKit
import SwiftUI

// Paste a Link…: a box a shared link goes into, as well as the website's
// Import to Glideball button and the .glide-settings file. What's pasted is read
// by `ImportPaste` (the rule is there and in docs/SHARE-FORMAT.md) and goes on to
// the same preview as glideball://import (`AppModel.reviewPasted`).
//
// The clipboard is read only when the person asks: the box's Paste button, ⌘V
// in the box or on the main window, File › Import Setup from Clipboard. Never
// when the box opens, never in the background. Nothing is sent anywhere.
//
// `PasteBox` is the box on its own, so Set up with AI's third step ("Paste the
// code it gives you") can use it as it is, with its own words around it.

/// The paste box, as a sheet over the window.
struct PasteBoxRequest: Identifiable {
    let id = UUID()
    /// What was already pasted (a link Glideball won't open, from the clipboard), to say why.
    var text = ""
}

extension ImportPaste.Refusal {
    /// What the box (or a toast) says.
    var message: String {
        switch self {
        case .tooLong:
            String(localized: "That’s a lot of text for a link. Paste just the link.", comment: "Paste box: more than 16 KB was pasted")
        case .noLink:
            String(localized: "There’s no Glideball link in that. Shared links start with glideball.netlify.app/s/#.", comment: "Paste box: nothing that looks like a link")
        case .notGlideball:
            String(localized: "That isn’t a Glideball share link, so it won’t be opened. They start with https://glideball.netlify.app/s/#.",
                   comment: "Paste box: a link to another site, http instead of https, or a look-alike address")
        case .notAShare:
            String(localized: "That’s a Glideball command link, not a shared setup. Pasting only opens shared setups.",
                   comment: "Paste box: a glideball:// link like glideball://pause")
        case .severalLinks:
            String(localized: "There’s more than one setup in that. Paste one link at a time.", comment: "Paste box: two different shared links")
        case .damaged:
            String(localized: "That link is damaged or cut off. Ask for it again, or for the file.", comment: "Paste box: the link's data doesn't read")
        case .newerVersion:
            String(localized: "That was shared from a newer Glideball. Update Glideball, then paste it again.", comment: "Paste box")
        }
    }
}

/// The box itself: where the text goes, a Paste button, and one line that says
/// what Glideball made of it, as it changes.
struct PasteBox: View {
    @Binding var text: String
    let reading: ImportPaste.Reading
    var placeholder = "https://glideball.netlify.app/s/#…"
    var emptyHint: LocalizedStringKey = "Paste with ⌘V, or click Paste. Glideball only reads the clipboard when you do."
    /// One line about a good reading.
    var describe: (SharedSetup) -> String = PasteBox.describe
    /// One line about a setup code (Set up with AI), and whether it's one to review.
    var describeCode: (SetupCode.Reading) -> (text: String, good: Bool) = { (PasteBox.describe(code: $0), true) }
    /// Put the cursor in the box when it appears.
    var autofocus = true
    var height: CGFloat = PasteBox.height
    @FocusState private var focused: Bool

    /// Renders and the self-test: draw it focused or not without a key window.
    static let height: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .accessibilityLabel(Text("Shared link", comment: "Paste box: accessibility label of the text box"))
                if text.isEmpty {
                    Text(verbatim: placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(border, lineWidth: reading.isEmptyReading ? 0.5 : 1.5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    // The one place the box reads the clipboard: this click.
                    text = AppModel.readClipboard() ?? ""
                    focused = true
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(ChipButtonStyle())
                .help("Paste what’s on the clipboard into the box")
            }
        }
        .animation(Theme.Motion.fade, value: reading.stateID)
        .onAppear { if autofocus { focused = true } }
    }

    private var border: Color {
        switch reading {
        case .empty: Theme.groupBorder
        case .share: Theme.ball
        case .code(let r): describeCode(r).good ? Theme.ball : Theme.groupBorder
        case .refused, .codeRefused: Theme.warn
        }
    }

    @ViewBuilder private var status: some View {
        switch reading {
        case .empty:
            Text(emptyHint)
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .share(let share, _):
            Label {
                Text(verbatim: describe(share))
                    .font(Theme.Font.hint.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            }
        case .refused(let why):
            warning(why.message)
        case .code(let r):
            let line = describeCode(r)
            Label {
                Text(verbatim: line.text)
                    .font(Theme.Font.hint.weight(line.good ? .medium : .regular))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: line.good ? "checkmark.circle.fill" : "equal.circle")
                    .foregroundStyle(line.good ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.secondary))
            }
        case .codeRefused(let problem):
            warning(problem.message)
        }
    }

    private func warning(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
                .font(Theme.Font.hint)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        }
    }

    /// "A setup from a chatbot: Pointer feel and Buttons. 2 things were left out; the review lists them."
    static func describe(code r: SetupCode.Reading) -> String {
        let parts = r.share.parts.map { $0.title(apps: r.share.apps ?? []) }
        let list = parts.count <= 3 ? parts.formatted(.list(type: .and))
            : String(localized: "\(parts[0]) and \(parts.count - 1) more", comment: "Paste box: the first part of a shared setup, then how many others; e.g. “Pointer feel and 3 more”")
        let head = String(localized: "A setup from a chatbot: \(list).", comment: "Set up with AI's box: what a pasted setup code changes; %@ is its parts, like “Pointer feel and Buttons”")
        guard !r.notes.isEmpty else { return head }
        let left = r.notes.count == 1
            ? String(localized: "One thing in it was left out; the review says what.", comment: "Set up with AI's box: one thing in a setup code Glideball couldn't use")
            : String(localized: "\(r.notes.count) things in it were left out; the review lists them.",
                     comment: "Set up with AI's box: how many things (2 or more) in a setup code Glideball couldn't use")
        return head + " " + left
    }

    /// "A shared scroll feel: Scroll feel and Sounds".
    static func describe(_ share: SharedSetup) -> String {
        let title = IncomingSetup(source: .link, content: .shared(share)).title
        let parts = share.parts.map { $0.title(apps: share.apps ?? []) }
        guard parts.count > 1 else { return title }
        let list = parts.count <= 3 ? parts.formatted(.list(type: .and))
            : String(localized: "\(parts[0]) and \(parts.count - 1) more", comment: "Paste box: the first part of a shared setup, then how many others; e.g. “Pointer feel and 3 more”")
        return String(localized: "\(title): \(list)", comment: "Paste box: what a pasted link holds; the first %@ is its title (“A shared Glideball setup”), the second its parts")
    }
}

private extension ImportPaste.Reading {
    var isEmptyReading: Bool { if case .empty = self { true } else { false } }
    /// Changes when the box's look changes (not on every keystroke).
    var stateID: String {
        switch self {
        case .empty: "empty"
        case .share(let s, _): "share \(s.parts.map(\.id))"
        case .refused(let r): r.rawValue
        case .code(let r): "code \(r.share.parts.map(\.id)) \(r.notes.count)"
        case .codeRefused(let p): "code refused \(p.forAI)"
        }
    }
}

/// Paste a Link…: the box, what it holds, and Review Changes….
struct PasteLinkSheet: View {
    let model: AppModel
    @State private var text: String

    init(model: AppModel, request: PasteBoxRequest) {
        self.model = model
        _text = State(initialValue: request.text)
    }

    var body: some View {
        // A setup code from Set up with AI is read here too (it goes to the same preview,
        // labelled as a chatbot's); without a { in it, the text is read as a link.
        let reading = ImportPaste.read(text, codes: text.contains("{") ? model.setupCodeContext : nil)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste a shared link")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Paste a Glideball link someone sent you. You’ll see exactly what it would change before anything does, the same as opening it from the website.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PasteBox(text: $text, reading: reading)
            HStack(spacing: 12) {
                Label("Nothing is sent anywhere. Glideball reads the link right here on your Mac.", systemImage: "lock")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.pasteBox = nil }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if case .code(let r) = reading {
                        model.reviewPastedCode(r)
                    } else if let share = reading.share {
                        model.reviewPasted(share)
                    }
                } label: {
                    Text("Review Changes…").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .keyboardShortcut(.defaultAction)
                .disabled(reading.share == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .background(GlideBackground(anchor: UnitPoint(x: 0.2, y: -0.1), strength: 0.7))
    }
}

/// "Import" beside a page's Share: paste a link, or choose a file.
struct PageImportMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Paste a Link…") { model.openPasteBox() }
            Button("Import a File…") { model.importSettings() }
            Divider()
            Button("Set Up with AI…") { model.showAISetup() }
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Open a setup someone shared with you: paste its link, or choose its file")
    }
}
