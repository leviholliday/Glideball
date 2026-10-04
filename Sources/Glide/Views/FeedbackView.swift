import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Send Feedback (Help › Send Feedback…, the menu bar icon, and Overview ›
// General): what kind it is, what happened, how much it matters, pictures of
// it, Glide's settings and scroll log if you're happy to share them, and who
// you are if you'd like a reply. The version and the Mac come along by
// themselves. FeedbackClient sends it to the developer.

// MARK: - The draft

@MainActor
@Observable
final class FeedbackDraft {
    static let shared = FeedbackDraft()

    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea, question
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .bug: "ladybug.fill"
            case .idea: "lightbulb.fill"
            case .question: "questionmark.bubble.fill"
            }
        }
        var color: Color {
            switch self {
            case .bug: .pink
            case .idea: .yellow
            case .question: .cyan
            }
        }
        var titlePrompt: String {
            switch self {
            case .bug: "What went wrong? e.g. “Scrolling jumps in Safari”"
            case .idea: "What would make Glide better?"
            case .question: "What would you like to know?"
            }
        }
        var detailsPrompt: String {
            switch self {
            case .bug: "What happened, what you expected, and how to make it happen again (if you know)."
            case .idea: "Tell me more — how would it work, and what would it help with?"
            case .question: "Any details that help me answer."
            }
        }
    }

    enum Priority: String, CaseIterable, Identifiable {
        case low, normal, high, blocking
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
        var hint: String {
            switch self {
            case .low: "A small thing, whenever"
            case .normal: "Worth fixing"
            case .high: "Gets in my way"
            case .blocking: "I can’t use my trackball properly"
            }
        }
        var color: Color {
            switch self {
            case .low: .gray
            case .normal: .blue
            case .high: .orange
            case .blocking: .red
            }
        }
    }

    enum Phase: Equatable {
        case writing
        case sending(Double, String)
        case sent(String)
        case failed(String)

        var isSending: Bool { if case .sending = self { true } else { false } }
    }

    struct UserFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let name: String
        let type: String
        let size: Int
        var thumbnail: NSImage?
        var isVideo: Bool { type.hasPrefix("video/") }
        static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.thumbnail === b.thumbnail }
    }

    /// Two of the six attachment slots are kept for the settings and the log.
    static let maxUserFiles = FeedbackClient.maxAttachments - 2
    static let logLines = 2000

    var kind = Kind.bug
    var title = ""
    var details = ""
    var priority = Priority.normal
    var name = UserDefaults.standard.string(forKey: "GlideFeedbackName") ?? "" {
        didSet { UserDefaults.standard.set(name, forKey: "GlideFeedbackName") }
    }
    var email = UserDefaults.standard.string(forKey: "GlideFeedbackEmail") ?? "" {
        didSet { UserDefaults.standard.set(email, forKey: "GlideFeedbackEmail") }
    }
    var contactOK = UserDefaults.standard.object(forKey: "GlideFeedbackContactOK") as? Bool ?? true {
        didSet { UserDefaults.standard.set(contactOK, forKey: "GlideFeedbackContactOK") }
    }
    var includeSettings = true
    var includeLog = true
    private(set) var files: [UserFile] = []
    var phase = Phase.writing
    /// A short note about a file that couldn't be added.
    var notice: String?
    /// Whether the sheet is up — if not, the result is shown as a toast.
    var isPresented = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noticeDismissal: DispatchWorkItem?

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    var canSend: Bool { !phase.isSending && !trimmedTitle.isEmpty }
    var emailLooksWrong: Bool {
        !trimmedEmail.isEmpty && trimmedEmail.range(of: #"^[^\s@?&#%/]+@[^\s@?&#%/]+\.[^\s@?&#%/]+$"#, options: .regularExpression) == nil
    }

    // MARK: Topics, from the words

    /// Glide areas the title and details mention — sent as autoTags.
    var topics: [String] {
        let text = "\(title) \(details)".lowercased()
        return Self.clues.filter { _, words in words.contains { Self.has(text, $0) } }.map(\.0)
    }

    private static let clues: [(String, [String])] = [
        ("Scrolling", ["scroll", "ring", "wheel", "flywheel", "momentum", "coast", "throw", "inertia", "smooth"]),
        ("Pointer", ["pointer", "cursor", "tracking", "ball", "accelerat", "precise", "precision"]),
        ("Buttons", ["button", "click", "chord", "combo", "shortcut", "remap", "wispr", "middle"]),
        ("Sync", ["sync", "icloud", "import", "export", "backup", "settings file"]),
        ("Permissions", ["permission", "accessibility", "input monitoring", "privacy"]),
        ("Performance", ["slow", "lag", "cpu", "battery", "stutter", "jank", "hang", "freez", "sluggish", "memory"]),
        ("Updates", ["update", "install", "version"]),
    ]

    /// The word at the start of a word ("ring" finds "rings", not "during").
    private static func has(_ text: String, _ word: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter { return true }
            from = r.upperBound
        }
        return false
    }

    // MARK: Files

    static let pickableTypes: [UTType] = [.png, .jpeg, .quickTimeMovie, .mpeg4Movie]

    func add(_ urls: [URL]) {
        var problems: [String] = []
        for url in urls {
            guard !files.contains(where: { $0.url == url }) else { continue }
            guard files.count < Self.maxUserFiles else {
                problems.append("Up to \(Self.maxUserFiles) pictures or videos can go with one report.")
                break
            }
            let ext = url.pathExtension.lowercased()
            guard let type = FeedbackClient.mimeType(forExtension: ext), type.hasPrefix("image/") || type.hasPrefix("video/") else {
                problems.append("“\(url.lastPathComponent)” isn’t a PNG, JPEG, MOV or MP4.")
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let limit = FeedbackClient.sizeLimits[type] ?? 0
            guard size > 0 else { problems.append("“\(url.lastPathComponent)” couldn’t be read."); continue }
            guard size <= limit else {
                problems.append("“\(url.lastPathComponent)” is too big (\(limit / 1_000_000) MB at most).")
                continue
            }
            let file = UserFile(url: url, name: freeName(for: url, ext: ext == "jpeg" ? "jpg" : ext), type: type, size: size,
                                thumbnail: type.hasPrefix("image/") ? NSImage(contentsOf: url) : nil)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { files.append(file) }
            if file.isVideo { makeThumbnail(for: file) }
        }
        if let first = problems.first { say(first) }
    }

    func remove(_ file: UserFile) {
        withAnimation(.easeOut(duration: 0.2)) { files.removeAll { $0.id == file.id } }
    }

    private func freeName(for url: URL, ext: String) -> String {
        let base = FeedbackClient.safeName(url.deletingPathExtension().lastPathComponent, ext: ext)
        let reserved: Set<String> = ["settings.json", "scroll-log.txt"]
        var name = base, n = 2
        while reserved.contains(name) || files.contains(where: { $0.name == name }) {
            name = FeedbackClient.safeName("\(url.deletingPathExtension().lastPathComponent)-\(n)", ext: ext)
            n += 1
        }
        return name
    }

    private func makeThumbnail(for file: UserFile) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 200)
        Task {
            guard let frame = try? await generator.image(at: .zero).image else { return }
            let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            if let i = files.firstIndex(where: { $0.id == file.id }) { files[i].thumbnail = image }
        }
    }

    private func say(_ text: String) {
        withAnimation(.smooth) { notice = text }
        noticeDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.smooth) { self?.notice = nil } }
        noticeDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: About this Mac and Glide

    struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static var appInfo: [String: String] {
        let info = Bundle.main.infoDictionary
        return ["version": info?["CFBundleShortVersionString"] as? String ?? "?",
                "build": info?["CFBundleVersion"] as? String ?? "?"]
    }

    static var systemInfo: [String: String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        let build = sysctl("kern.osversion").map { " (\($0))" } ?? ""
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        return ["macOS": number + build, "model": sysctl("hw.model") ?? "Mac", "arch": arch]
    }

    func context(_ model: AppModel) -> [String: String] {
        let c = model.config
        var out: [String: String] = [
            "kind": kind.rawValue,
            "scrollMode": c.scrollMode.rawValue,
            "expertMouseConnected": model.status.deviceConnected ? "yes" : "no",
            "glideEnabled": c.enabled ? "yes" : "no",
            "permissions": model.permissionsOK ? "granted" : "missing",
            "trackingSpeed": String(format: "%g", c.trackingSpeed),
        ]
        if model.sync.isEnabled { out["iCloudSync"] = "on" }
        if let device = model.status.deviceName { out["device"] = device }
        if model.betaProgram { out["betaProgram"] = "on" }
        return out
    }

    func facts(_ model: AppModel) -> [Fact] {
        let app = Self.appInfo, sys = Self.systemInfo
        let mode = switch model.config.scrollMode {
        case .native: "Native"
        case .flywheel: "Flywheel"
        case .follow: "Follow"
        }
        var out = [
            Fact(label: "Glide", value: "\(app["version"] ?? "?") (build \(app["build"] ?? "?"))"),
            Fact(label: "macOS", value: sys["macOS"] ?? "?"),
            Fact(label: "Mac model", value: sys["model"] ?? "?"),
            Fact(label: "Architecture", value: sys["arch"] ?? "?"),
            Fact(label: "Scroll mode", value: mode),
            Fact(label: "Trackball", value: model.status.deviceName.map { model.status.deviceIsBeta ? "\($0) (beta)" : $0 } ?? "Not connected"),
        ]
        if model.betaProgram { out.append(Fact(label: "Beta program", value: "On")) }
        if !topics.isEmpty { out.append(Fact(label: "Topics", value: topics.joined(separator: ", "))) }
        return out
    }

    /// The facts on one line, for the footer of the disclosure.
    func factsLine(_ model: AppModel) -> String {
        let app = Self.appInfo, sys = Self.systemInfo
        return "Glide \(app["version"] ?? "?") · macOS \((sys["macOS"] ?? "").components(separatedBy: " (").first ?? "") · \(sys["model"] ?? "Mac")"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    // MARK: Opt-in extras

    /// The current setup, as an exported settings file would have it — minus
    /// the Mac's name.
    static func settingsJSON(_ model: AppModel) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(GlideSettingsFile(config: model.config, exportedFrom: nil))
    }

    /// The last ~2000 lines of ~/Library/Logs/Glide/scroll.log (or the previous
    /// launch's, if this one hasn't scrolled yet).
    static func scrollLogTail() -> Data? {
        guard let url = Diagnostics.latestNonEmpty, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var tail = lines.suffix(logLines).joined(separator: "\n") + "\n"
        // Never over the server's limit for text, however long the lines.
        let limit = (FeedbackClient.sizeLimits["text/plain"] ?? 5_000_000) - 1024
        if tail.utf8.count > limit { tail = String(decoding: Data(tail.utf8).suffix(limit), as: UTF8.self) }
        return Data(tail.utf8)
    }

    static var hasScrollLog: Bool {
        Diagnostics.latestNonEmpty != nil
    }

    // MARK: Sending

    func send(_ model: AppModel) {
        guard canSend else { return }
        if emailLooksWrong { phase = .failed("That email address doesn’t look right."); return }
        var attachments = files.map { FeedbackClient.Attachment(name: $0.name, type: $0.type, source: .file($0.url)) }
        if includeSettings, let data = Self.settingsJSON(model) {
            attachments.append(.init(name: "settings.json", type: "application/json", source: .data(data)))
        }
        if includeLog, let data = Self.scrollLogTail() {
            attachments.append(.init(name: "scroll-log.txt", type: "text/plain", source: .data(data)))
        }
        let report = FeedbackClient.Report(
            title: trimmedTitle,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: [kind.name],
            autoTags: topics,
            priority: kind == .bug ? priority.rawValue : Priority.normal.rawValue,
            name: name.trimmingCharacters(in: .whitespaces),
            email: trimmedEmail,
            contactOK: contactOK && !trimmedEmail.isEmpty,
            app: Self.appInfo,
            system: Self.systemInfo,
            context: context(model))

        notice = nil
        withAnimation(.smooth) { phase = .sending(0, "Sending…") }
        task = Task {
            do {
                let id = try await FeedbackClient().send(report, attachments: attachments) { [weak self] f, note in
                    guard let self, self.phase.isSending else { return }
                    self.phase = .sending(f, note)
                }
                finished(id, model)
            } catch is CancellationError {
                withAnimation(.smooth) { phase = .writing }
            } catch {
                let message = (error as? FeedbackClient.FeedbackError)?.message ?? error.localizedDescription
                withAnimation(.smooth) { phase = .failed(message) }
                if !isPresented {
                    model.show(.init(symbol: "exclamationmark.bubble.fill",
                                     text: "Your feedback didn’t send — open Send Feedback to try again.", isError: true))
                }
            }
            task = nil
        }
    }

    func cancelSending() { task?.cancel() }

    private func finished(_ id: String, _ model: AppModel) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            title = ""
            details = ""
            priority = .normal
            files = []
            phase = .sent(id)
        }
        if !isPresented {
            model.show(.init(symbol: "paperplane.fill", text: "Feedback sent — thank you!"))
            phase = .writing
        }
    }

    /// After a send, opening the form starts a fresh report.
    func prepareToShow() {
        if case .sent = phase { phase = .writing }
        if case .failed = phase {} else { notice = nil }
    }
}

// MARK: - The sheet

struct FeedbackView: View {
    @Bindable var model: AppModel
    @Bindable var draft = FeedbackDraft.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var showFacts = false
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            GlideBackground()
            VStack(spacing: 0) {
                header
                if case .sent(let id) = draft.phase {
                    SentView(draft: draft, id: id) { dismiss() }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            messageCard
                            attachmentsCard
                            aboutYouCard
                            factsDisclosure
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 6)
                        .disabled(draft.phase.isSending)
                    }
                    .scrollIndicators(.never)
                    footer
                }
            }
        }
        .frame(width: 640, height: 640)
        .animation(.smooth(duration: 0.3), value: draft.phase)
        .onAppear {
            draft.isPresented = true
            draft.prepareToShow()
            if draft.title.isEmpty { titleFocused = true }
        }
        .onDisappear { draft.isPresented = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Send Feedback").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Bugs, ideas, questions — it goes straight to the developer.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(draft.phase.isSending ? "Hide — it keeps sending in the background" : "Close")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: What's up

    private var messageCard: some View {
        GlassCard {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(FeedbackDraft.Kind.allCases) { kind in kindButton(kind) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(draft.kind.titlePrompt, text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($titleFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(FieldBackground())

                ZStack(alignment: .topLeading) {
                    if draft.details.isEmpty {
                        Text(draft.kind.detailsPrompt)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.details)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                }
                .frame(height: 110)
                .background(FieldBackground())
            }

            if draft.kind == .bug {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ForEach(FeedbackDraft.Priority.allCases) { p in priorityButton(p) }
                    }
                    Text(draft.priority.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.25), value: draft.kind)
    }

    private func kindButton(_ kind: FeedbackDraft.Kind) -> some View {
        let on = draft.kind == kind
        return Button {
            draft.kind = kind
        } label: {
            Label(kind.name, systemImage: kind.symbol)
                .font(.system(size: 13, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(kind.color.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
    }

    private func priorityButton(_ p: FeedbackDraft.Priority) -> some View {
        let on = draft.priority == p
        return Button {
            draft.priority = p
        } label: {
            HStack(spacing: 6) {
                Circle().fill(p.color).frame(width: 7, height: 7)
                    .shadow(color: p.color.opacity(on ? 0.8 : 0), radius: 3)
                Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                Capsule().fill(on ? p.color.opacity(0.22) : .white.opacity(0.05))
                    .overlay(Capsule().strokeBorder(on ? p.color.opacity(0.7) : .white.opacity(0.14), lineWidth: on ? 1.3 : 1))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Attachments

    private var attachmentsCard: some View {
        GlassCard(title: "Attachments", symbol: "paperclip") {
            dropZone

            if let notice = draft.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                ToggleRow(title: "Include my Glide settings",
                          subtitle: "Your pointer, scrolling and button setup (settings.json) so I can reproduce it. Nothing personal is in it.",
                          symbol: "slider.horizontal.3", isOn: $draft.includeSettings)
                ToggleRow(title: "Include the scroll log",
                          subtitle: FeedbackDraft.hasScrollLog
                              ? "The last \(FeedbackDraft.logLines.formatted()) lines of timings from the scroll ring (scroll-log.txt) — no keystrokes or window contents."
                              : "There’s no scroll log yet — scroll with the ring and it will have something to send.",
                          symbol: "waveform.path.ecg.text", isOn: $draft.includeLog)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            if draft.files.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: dropTargeted ? "photo.badge.plus.fill" : "photo.badge.plus")
                        .font(.system(size: 26, weight: .light))
                        .symbolEffect(.bounce, value: dropTargeted)
                        .foregroundStyle(dropTargeted ? .cyan : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dropTargeted ? "Drop to attach" : "Drop screenshots or screen recordings here")
                            .font(.system(size: 13, weight: .semibold))
                        Text("PNG, JPEG, MOV or MP4 · ⇧⌘5 records the screen")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    addButton
                }
                .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(draft.files) { file in
                            AttachmentThumb(file: file) { draft.remove(file) }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        if draft.files.count < FeedbackDraft.maxUserFiles {
                            addButton.padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.top, 6)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(dropTargeted ? Color.cyan : Color.white.opacity(0.25))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(dropTargeted ? Color.cyan.opacity(0.12) : Color.clear))
        }
        .scaleEffect(dropTargeted ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            draft.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var addButton: some View {
        Button(action: pickFiles) {
            Label("Add Screenshot…", systemImage: "plus")
        }
        .buttonStyle(.glass)
        .disabled(draft.files.count >= FeedbackDraft.maxUserFiles)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Screenshots or Recordings"
        panel.message = "Pictures or short videos that show what you mean (up to \(FeedbackDraft.maxUserFiles))."
        panel.prompt = "Attach"
        panel.allowedContentTypes = FeedbackDraft.pickableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK { draft.add(panel.urls) }
    }

    // MARK: About you

    private var aboutYouCard: some View {
        GlassCard(title: "About you — optional", symbol: "person.crop.circle") {
            HStack(spacing: 12) {
                labeled("Name") {
                    TextField("Your name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(FieldBackground())
                }
                labeled(draft.emailLooksWrong ? "Email — that doesn’t look right" : "Email, if you’d like a reply") {
                    TextField("you@example.com", text: $draft.email)
                        .textFieldStyle(.plain)
                        .textContentType(.emailAddress)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(FieldBackground(warning: draft.emailLooksWrong))
                }
            }
            Toggle(isOn: $draft.contactOK) {
                Text("OK to contact me about this").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .disabled(draft.trimmedEmail.isEmpty)
            Text("Remembered on this Mac for next time. Only used to reply to you.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sent along

    private var factsDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { showFacts.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showFacts ? 90 : 0))
                    Text("Also sent: \(draft.factsLine(model))")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFacts {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.facts(model)) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(fact.value).font(.system(size: 12, weight: .medium, design: .rounded))
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                    Text("So I know where it happened. Nothing else about your Mac is sent.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch draft.phase {
            case .sending(let fraction, let note):
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.cyan)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { draft.cancelSending() }
                    .buttonStyle(.glass)
            case .failed(let message):
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                closeButton
                sendButton(title: "Try Again", symbol: "arrow.clockwise")
            default:
                Text(sendSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                closeButton
                sendButton(title: "Send", symbol: "paperplane.fill")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 6)
    }

    private var closeButton: some View {
        Button("Close") { dismiss() }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
    }

    private func sendButton(title: String, symbol: String) -> some View {
        Button { draft.send(model) } label: {
            Label(title, systemImage: symbol).padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(.cyan)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!draft.canSend)
        .help(draft.canSend ? "Send (⌘↩)" : "Give it a title first")
    }

    private var sendSummary: String {
        var parts: [String] = []
        if !draft.files.isEmpty { parts.append(draft.files.count == 1 ? "1 file" : "\(draft.files.count) files") }
        if draft.includeSettings { parts.append("settings") }
        if draft.includeLog && FeedbackDraft.hasScrollLog { parts.append("scroll log") }
        return parts.isEmpty ? "Just your message." : "With " + ListFormatter.localizedString(byJoining: parts) + "."
    }
}

// MARK: - Pieces

private struct FieldBackground: View {
    var warning = false
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(warning ? Color.orange.opacity(0.8) : Color.white.opacity(0.16), lineWidth: 1))
    }
}

private struct AttachmentThumb: View {
    let file: FeedbackDraft.UserFile
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let image = file.thumbnail {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.08)
                                Image(systemName: file.isVideo ? "film" : "photo")
                                    .font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 104, height: 68)
                    .clipped()
                    if file.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .padding(5)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .onTapGesture { NSWorkspace.shared.open(file.url) }
                .help("Click to open")

                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove")
            }
            Text(file.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104, alignment: .leading)
        }
    }
}

private struct SentView: View {
    let draft: FeedbackDraft
    let id: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            SentCheck(color: .green)
            Text(thanks)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 10) {
                Button("Send Another") { withAnimation(.smooth) { draft.phase = .writing } }
                    .buttonStyle(.glass)
                Button("Done", action: done)
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
            Text("Reference \(id)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var thanks: String {
        let first = draft.name.split(separator: " ").first.map(String.init)
        return "Thanks\(first.map { ", \($0)" } ?? "") — it went straight to the developer."
    }

    private var detail: String {
        if draft.contactOK && !draft.trimmedEmail.isEmpty {
            return "If there’s a question, the reply goes to \(draft.trimmedEmail)."
        }
        return "Every report is read. Add an email next time if you’d like a reply."
    }
}

/// A check that draws itself in a ring.
private struct SentCheck: View {
    let color: Color
    @State private var t: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.12))
            Circle().trim(from: 0, to: t)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { p in
                p.move(to: CGPoint(x: 27, y: 45))
                p.addLine(to: CGPoint(x: 39, y: 57))
                p.addLine(to: CGPoint(x: 62, y: 32))
            }
            .trim(from: 0, to: max(0, (t - 0.5) * 2))
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 88, height: 88)
        .shadow(color: color.opacity(0.5), radius: 14)
        .onAppear { withAnimation(.easeInOut(duration: 0.9)) { t = 1 } }
    }
}
