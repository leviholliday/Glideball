import AppKit
import Observation

// The app's side of "Set up with AI" (the format and the rules are in SetupCode.swift, the
// prompt in AIReference.swift, the sheet in Views/SetupWithAIView.swift).
//
// Glideball has no AI in it and nothing here talks to anything. Copy prompt puts text on the
// clipboard; the person pastes it into whichever chatbot they use, talks, and pastes back the
// setup code it wrote into the paste box (the same box as Paste a Link…, `ImportPaste`). That
// code is read (`SetupCode.read`), shown in the same preview a shared setup gets (inside the
// sheet), and only Apply there changes anything: a "Before AI setup" backup first, then the
// parts still ticked, then Undo.
//
// Nothing about it is in the opt-in stats.

/// Where the sheet is and what's in its box. It lives on the model, not in the sheet, so
/// closing the sheet (the person is off talking to a chatbot for twenty minutes) and opening
/// it again finds everything as it was. Kept for the launch only.
@Observable
final class AISetupFlow {
    static let leaveAppNamesOutKey = "GlideAILeaveAppNamesOut"

    /// The prompt was copied (this launch).
    var copied = false
    /// The paste box.
    var text = ""
    /// The preview, shown in the sheet's place.
    var reviewing: IncomingSetup?
    /// A code was just applied from here; what it left out, for the note.
    var applied = false
    var appliedLeftOut: [SetupCode.Note] = []
    /// "What's in it" is open, and under it the prompt itself.
    var showingContents = false
    var showingPrompt = false
    /// App setups and the apps buttons open stay out of the prompt. Per Mac, never synced.
    var leaveAppNamesOut = UserDefaults.standard.bool(forKey: AISetupFlow.leaveAppNamesOutKey) {
        didSet { UserDefaults.standard.set(leaveAppNamesOut, forKey: Self.leaveAppNamesOutKey) }
    }

    /// The step that's lit: 1 copy, 2 talk, 3 paste.
    var step: Int {
        if applied || !text.isEmpty { return 3 }
        return copied ? 2 : 1
    }

    /// Renders and the self-test: as a fresh launch.
    func reset() {
        copied = false
        text = ""
        reviewing = nil
        applied = false
        appliedLeftOut = []
        showingContents = false
        showingPrompt = false
        leaveAppNamesOut = false
    }
}

extension AppLanguage {
    /// The language's name in English, for the prompt's "Speak German with me".
    var englishName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .brazilianPortuguese: "Brazilian Portuguese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .simplifiedChinese: "Simplified Chinese"
        }
    }

    /// The language Glideball is showing right now.
    static var onScreen: AppLanguage {
        Bundle.main.preferredLocalizations.lazy.compactMap { code -> AppLanguage? in
            AppLanguage(rawValue: code) ?? AppLanguage(rawValue: String(code.prefix { $0 != "-" && $0 != "_" }))
        }.first ?? .english
    }
}

/// The apps on this Mac, for a setup code that names one ("open:Notes", an app setup for
/// "Safari"). An app is only ever one Launch Services knows by its bundle ID: a name that
/// matches nothing installed finds nothing, and nothing is guessed.
enum InstalledApps {
    private struct Entry {
        let bundleID: String
        let names: [String]
    }

    nonisolated(unsafe) private static var cache: (date: Date, entries: [Entry])?
    private static let lock = NSLock()

    /// Renders and the self-test: a fixed list, so nothing on the Mac is looked at.
    static let sandbox = SetupApps.fixed(["Notes": "com.apple.Notes", "Safari": "com.apple.Safari", "Xcode": "com.apple.dt.Xcode",
                                          "Figma": "com.figma.Desktop", "Calculator": "com.apple.calculator", "Mail": "com.apple.mail",
                                          "Terminal": "com.apple.Terminal", "Music": "com.apple.Music"])

    static var setupApps: SetupApps {
        if Sandbox.isActive { return sandbox }
        return SetupApps(find: { find($0) }, name: { ActionCatalog.appName($0) })
    }

    /// The app `text` names: a bundle ID Launch Services has, or an app's name (any capitals,
    /// with or without ".app").
    static func find(_ text: String) -> (bundleID: String, name: String)? {
        var asked = ImportText.clean(text, max: 80)
        if asked.lowercased().hasSuffix(".app") { asked = String(asked.dropLast(4)) }
        guard !asked.isEmpty, !asked.contains("/") else { return nil }
        if asked.contains("."), ImportText.isBundleID(asked), NSWorkspace.shared.urlForApplication(withBundleIdentifier: asked) != nil {
            return (asked, ActionCatalog.appName(asked) ?? asked)
        }
        for e in entries() where e.names.contains(where: { $0.caseInsensitiveCompare(asked) == .orderedSame }) {
            // Only an app Launch Services can open by that bundle ID.
            guard ImportText.isBundleID(e.bundleID), NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleID) != nil else { continue }
            return (e.bundleID, ActionCatalog.appName(e.bundleID) ?? e.names[0])
        }
        return nil
    }

    /// Every app in the Applications folders (and one folder down, for suites), then the apps
    /// that are running. Read at most once a minute, and only when a code names an app.
    private static func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.date) < 60 { return cache.entries }
        let fm = FileManager.default
        var out: [Entry] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard out.count < 4_000, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { return }
            let info = bundle.infoDictionary
            var names = [fm.displayName(atPath: url.path), url.deletingPathExtension().lastPathComponent,
                         info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String]
                .compactMap { $0 }.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }.filter { !$0.isEmpty }
            names = names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            if !names.isEmpty { out.append(Entry(bundleID: id, names: names)) }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        for folder in ["/Applications", home + "/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications"] {
            let root = URL(fileURLWithPath: folder, isDirectory: true)
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if item.pathExtension == "app" {
                    add(item)
                } else if folder.hasSuffix("/Applications"), (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                        ?? [] where inner.pathExtension == "app" { add(inner) }
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { add(url) }
        }
        cache = (Date(), out)
        return out
    }
}

extension AppModel {
    /// Opens Set up with AI (the Import menu, the Buttons page's row, Sync's Import, search),
    /// at the step it was left on. `text`: a setup code that was pasted somewhere else.
    func showAISetup(text: String? = nil) {
        guard pendingIncoming == nil, shareRequest == nil else { return }
        if let text {
            aiSetup.text = text
            aiSetup.applied = false
            aiSetup.reviewing = nil
        }
        if !Sandbox.isActive { (NSApp.delegate as? AppDelegate)?.showWindow() }
        pasteBox = nil
        showingAISetup = true
    }

    /// The trackball the prompt is written for: the Expert Mouse by its model name, another
    /// Kensington by its product name (letters, digits and spaces only, so a name someone gave
    /// their trackball can't carry much), or none.
    var setupDevice: SetupDevice {
        guard let name = status.deviceName else { return .none }
        if name.localizedCaseInsensitiveContains("Expert Mouse") { return .expertMouse }
        let plain = String(ImportText.clean(name, max: 60).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(Character.init))
        return SetupDevice(name: plain.isEmpty ? nil : plain, isExpertMouse: false)
    }

    /// What a pasted setup code is read against: your settings now and the apps on this Mac.
    var setupCodeContext: SetupCode.Context {
        let look = BallThemeStore.shared.look
        return SetupCode.Context(current: config, sounds: .current, lookIsCustom: look.theme == "custom", apps: InstalledApps.setupApps)
    }

    /// What Set up with AI's box makes of its text.
    func aiReading(_ text: String) -> ImportPaste.Reading {
        ImportPaste.read(text, codes: setupCodeContext, codeFirst: true)
    }

    /// Your setup as a setup code: what the prompt shows the chatbot, and what Copy my setup copies.
    func aiSetupCode() -> String {
        SetupCode.write(config, look: BallThemeStore.shared.look, sounds: .current, apps: InstalledApps.setupApps,
                        showApps: !aiSetup.leaveAppNamesOut).lines
    }

    /// Everything Copy prompt copies. Built now, from the settings model and your setup as they are.
    func aiPrompt() -> String {
        AIReference.prompt(setup: aiSetupCode(), device: setupDevice, language: AppLanguage.onScreen.englishName,
                           showApps: !aiSetup.leaveAppNamesOut, version: GlideSettingsFile.appVersion)
    }

    /// The prompt is long enough that a small chatbot may cut it short.
    var aiPromptIsLong: Bool { AIReference.roughTokens(aiPrompt()) > AIReference.comfortableTokens }

    /// Text onto the clipboard. This is all Set up with AI ever does with it: nothing is sent anywhere.
    @discardableResult
    private func copyForAI(_ text: String) -> Bool {
        guard !Sandbox.isActive else { return true }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAIPrompt() -> Bool {
        let ok = copyForAI(aiPrompt())
        if ok { aiSetup.copied = true }
        return ok
    }

    /// "Copy my setup": a short follow-up for a chat that's already going.
    func copyAISetup() -> Bool { copyForAI(AIReference.followUp(setup: aiSetupCode())) }

    /// "Copy note for the AI": what was left out and what to do about it, for the chatbot.
    func copyAINote(_ notes: [SetupCode.Note]) -> Bool { copyForAI(SetupCode.noteForAI(notes)) }

    /// The same for a code that couldn't be read at all.
    func copyAINote(for problem: SetupCode.Problem) -> Bool { copyForAI(problem.forAI) }

    /// The preview a reading would open, if it's something Glideball can review.
    func incoming(for reading: ImportPaste.Reading) -> IncomingSetup? {
        switch reading {
        case .code(let r): IncomingSetup(source: .aiCode, content: .shared(r.share), leftOut: r.notes)
        case .share(let s, .json): IncomingSetup(source: .pasted, content: .shared(s))
        case .share(let s, _): IncomingSetup(source: .link, content: .shared(s))
        default: nil
        }
    }

    /// A good code or link that would change nothing here.
    func readingMatches(_ reading: ImportPaste.Reading) -> Bool {
        guard let incoming = incoming(for: reading) else { return false }
        return changes(for: incoming).isEmpty
    }

    /// Review Changes…: what's in the box, shown in the sheet's place.
    func reviewAICode() {
        let flow = aiSetup
        guard let incoming = incoming(for: aiReading(flow.text)), !changes(for: incoming).isEmpty else { return }
        flow.applied = false
        flow.reviewing = incoming
    }

    /// Cancel in the preview: back to the box, nothing changed.
    func cancelAIReview() {
        aiSetup.reviewing = nil
    }

    /// Apply in the preview: the same as any shared setup (a backup first, Undo after).
    func applyAIReview(parts: Set<SharePart>?) {
        guard let incoming = aiSetup.reviewing else { return }
        aiSetup.reviewing = nil
        if apply(incoming, parts: parts) {
            aiSetup.applied = true
            aiSetup.appliedLeftOut = incoming.leftOut
        }
    }

    /// Undo in the sheet, after applying from it.
    func undoAISetup() {
        undoImport()
        aiSetup.applied = false
    }

    /// Paste a Link…'s Review Changes… with a setup code in it: the preview every shared
    /// setup gets, labelled as a chatbot's, with what it left out.
    func reviewPastedCode(_ r: SetupCode.Reading) {
        present(IncomingSetup(source: .aiCode, content: .shared(r.share), leftOut: r.notes), cooldown: false)
        pasteBox = nil
    }
}
