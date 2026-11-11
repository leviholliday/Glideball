import AppKit
import SwiftUI

/// `Glide --render-ui <dir> [--appearance light|dark|both] [--only a,b*,…] [--scale 1|2] [--lang de]`
///
/// Draws every screen of Glideball to `<dir>/<screen>.<light|dark>.png`, offscreen,
/// with demo data (DemoData.swift), plus `index.html` (a contact sheet) and
/// `manifest.json`. Nothing is shown, nothing live runs (Sandbox.swift). Exits 0
/// when every picture was drawn and none came out blank; 1 otherwise; 2 on bad
/// arguments. Usually run through `scripts/render-ui.sh`, which builds and
/// stages a copy of the app with its own bundle ID.
@MainActor
enum RenderUI {
    struct Options {
        var dir: URL
        var appearances: [Bool] = [false, true]   // dark?
        var only: [String] = []
        var scale: CGFloat = 2
        var lang: String?
    }

    struct Screen {
        let name: String
        let group: String
        let title: String
        /// Puts the model (and the fake network) in this screen's state.
        var prepare: () -> Void = {}
        /// Draws it once, in one appearance.
        let draw: (_ dark: Bool, _ scale: CGFloat) -> NSBitmapImageRep?
        /// Puts things back for the next screen.
        var cleanup: () -> Void = {}
    }

    static func start() {
        let options = parse()
        if let lang = options.lang { relaunchIn(lang) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // no Dock icon, never in front
        let delegate = Launcher { run(options) }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Runs `body` once AppKit has finished launching.
    final class Launcher: NSObject, NSApplicationDelegate {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        func applicationDidFinishLaunching(_ notification: Notification) {
            // A run-loop turn, not a main-queue block: the work spins the run loop
            // itself, and main-queue blocks (URLSession and sync results, onAppear
            // follow-ups) can only run while no other main-queue block is running.
            RunLoop.main.perform { MainActor.assumeIsolated { self.body() } }
        }
    }

    // MARK: Arguments

    private static func parse() -> Options {
        var args = Array(CommandLine.arguments.dropFirst())
        func fail(_ message: String) -> Never {
            print("error: \(message)")
            print("usage: Glide --render-ui <dir> [--appearance light|dark|both] [--only name,name*,…] [--scale 1|2] [--lang <code>]")
            exit(2)
        }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("\(flag) needs a value") }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        guard let dirArg = value(after: "--render-ui") else { fail("--render-ui needs an output folder") }
        var o = Options(dir: URL(fileURLWithPath: dirArg, isDirectory: true).standardizedFileURL)
        if let a = value(after: "--appearance") {
            switch a {
            case "light": o.appearances = [false]
            case "dark": o.appearances = [true]
            case "both": o.appearances = [false, true]
            default: fail("--appearance is light, dark or both")
            }
        }
        if let only = value(after: "--only") {
            o.only = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let s = value(after: "--scale") {
            guard let n = Double(s), n == 1 || n == 2 else { fail("--scale is 1 or 2") }
            o.scale = n
        }
        if let lang = value(after: "--lang") {
            guard Bundle.main.localizations.contains(lang) || lang == "en" else {
                fail("no \(lang) translation in this build (have: \(Set(Bundle.main.localizations).sorted().joined(separator: ", ")))")
            }
            o.lang = lang
        }
        // AppKit's own arguments (-AppleLanguages, set by relaunchIn) are left alone.
        let unknown = args.filter { $0.hasPrefix("--") }
        if !unknown.isEmpty { fail("unknown option \(unknown[0])") }
        return o
    }

    /// The UI language is fixed when the process starts, so `--lang` re-runs
    /// this same binary with `-AppleLanguages (<code>)` (once).
    private static func relaunchIn(_ lang: String) {
        let args = CommandLine.arguments
        if args.contains("-AppleLanguages") { return }
        let full = args + ["-AppleLanguages", "(\(lang))", "-AppleLocale", lang.replacingOccurrences(of: "-", with: "_")]
        var cArgs = full.map { strdup($0) } + [nil]
        let path = Bundle.main.executablePath ?? args[0]
        try? FileManager.default.removeItem(at: Sandbox.folder)   // exec skips atexit; the new run makes its own
        execv(path, &cArgs)
        print("error: couldn't restart in \(lang): \(String(cString: strerror(errno)))")
        exit(2)
    }

    // MARK: Running

    private static func run(_ o: Options) {
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: o.dir, withIntermediateDirectories: true)
        } catch {
            print("error: can't create \(o.dir.path): \(error.localizedDescription)")
            exit(2)
        }
        DemoData.seed()
        let model = AppModel.shared
        DemoData.prime(model)
        settleSync(model)
        stub(.releases(newer: false))
        model.updates.checkNow()   // so Settings › Updates says when it last looked
        waitUntil(3) { model.updates.manualCheck == .upToDate }

        let screens = all(model)
        let selected = screens.filter { s in o.only.isEmpty || o.only.contains { matches(s.name, $0) } }
        if selected.isEmpty {
            print("error: --only matched nothing. Screens: \(screens.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        print("render-ui: \(selected.count) screens × \(o.appearances.count) appearance(s) at \(Int(o.scale))x, language \(lang) → \(o.dir.path)")

        var written: [(screen: Screen, file: String, dark: Bool, size: NSSize)] = []
        var problems: [String] = []
        for screen in selected {
            screen.prepare()
            for dark in o.appearances {
                let file = "\(screen.name).\(dark ? "dark" : "light").png"
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                guard let rep = screen.draw(dark, o.scale) else {
                    problems.append("\(file): nothing was drawn")
                    print("  ✗ \(file): nothing was drawn")
                    continue
                }
                if Offscreen.isBlank(rep) {
                    problems.append("\(file): blank")
                    print("  ✗ \(file): blank")
                }
                guard let data = Offscreen.png(rep) else {
                    problems.append("\(file): couldn't encode PNG")
                    continue
                }
                do {
                    try data.write(to: o.dir.appendingPathComponent(file), options: .atomic)
                    written.append((screen, file, dark, rep.size))
                    print("  ✓ \(file)  \(Int(rep.size.width))×\(Int(rep.size.height))")
                } catch {
                    problems.append("\(file): \(error.localizedDescription)")
                }
            }
            screen.cleanup()
        }
        writeIndex(o, lang: lang, written: written.map { ($0.screen.name, $0.screen.group, $0.screen.title, $0.file, $0.dark, $0.size) })
        let elapsed = Date().timeIntervalSince(started)
        if problems.isEmpty {
            print("render-ui: wrote \(written.count) pictures and index.html in \(String(format: "%.1f", elapsed)) s")
            exit(0)
        }
        print("render-ui: \(problems.count) problem(s):")
        problems.forEach { print("  \($0)") }
        exit(1)
    }

    /// "settings-*" style matching for --only; a plain name also matches its variants ("overview" → "overview-paused").
    static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern.contains("*") { return fnmatch(pattern, name, 0) == 0 }
        return name == pattern || name.hasPrefix(pattern + "-")
    }

    static func waitUntil(_ seconds: Double, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { Sandbox.spin(0.02) }
    }

    /// Sync on, up to date, with this Mac and two others listed.
    private static func settleSync(_ model: AppModel) {
        model.sync.syncNow(current: model.config)
        waitUntil(5) {
            if case .upToDate = model.sync.status { return model.sync.devices.count >= 3 }
            return false
        }
    }

    // MARK: Pieces

    static let windowSize = NSSize(width: 1040, height: 700)

    private static func appearance(_ dark: Bool) -> NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }

    /// The main window on `tab`, as it opens, with `overlay` on top (the tour, say).
    static func mainWindow<O: View>(_ model: AppModel, tab: GlideTab, dark: Bool, scale: CGFloat,
                                    @ViewBuilder overlay: () -> O) -> NSBitmapImageRep? {
        UserDefaults.standard.set(tab.rawValue, forKey: "GlideInitialTab")
        defer { UserDefaults.standard.removeObject(forKey: "GlideInitialTab") }
        let view = ZStack {
            RootView(model: model)
            overlay()
        }
        return Offscreen.render(view, size: windowSize, chrome: .window, appearance: appearance(dark), scale: scale)
    }

    static func mainWindow(_ model: AppModel, tab: GlideTab, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        mainWindow(model, tab: tab, dark: dark, scale: scale) { EmptyView() }
    }

    /// A whole tab, top to bottom (what scrolling would show), without the window's header.
    static func fullPage<V: View>(_ page: V, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let view = page
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .background(GlideBackground())
        return Offscreen.renderTall(view, width: windowSize.width, appearance: appearance(dark), scale: scale)
    }

    /// A sheet's content at its own size, as macOS shows it over the window.
    static func sheet<V: View>(_ view: V, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        Offscreen.render(view, size: nil, chrome: .plain, appearance: appearance(dark), scale: scale)
    }

    /// A card on its own, on the window's background.
    static func card<V: View>(_ view: V, width: CGFloat, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let v = view.padding(26).background(GlideBackground())
        return Offscreen.renderTall(v, width: width, appearance: appearance(dark), scale: scale)
    }

    /// Glideball › Settings…, through the real `SettingsWindowController` (toolbar tabs and all).
    static func settings(_ pane: SettingsPane, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        UserDefaults.standard.set(pane.rawValue, forKey: "GlideSettingsPane")
        let controller = SettingsWindowController()
        guard let window = controller.window, let content = window.contentView else { return nil }
        window.appearance = appearance(dark)
        window.animationBehavior = .none
        Offscreen.lookActive(window)
        Offscreen.settleDown(content, seconds: 0.3)
        if let tabs = window.contentViewController as? NSTabViewController {
            // The window fits the chosen tab's content once it has laid out.
            tabs.tabView(tabs.tabView, didSelect: tabs.tabView.selectedTabViewItem)
        }
        Offscreen.settleDown(content, seconds: 0.1)
        defer { window.close() }
        return Offscreen.draw(window, content: content, chrome: .titled, scale: scale)
    }

    /// The Software Update window, built the way AppDelegate builds it.
    static func updatePanel(_ model: AppModel, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let controller = NSHostingController(rootView: Offscreen.withoutAnimations(UpdatePanelView(updates: model.updates) {}))
        controller.sizingOptions = [.preferredContentSize]
        let w = Offscreen.ActiveLookingWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = appearance(dark)
        guard let content = w.contentView else { return nil }
        Offscreen.settleDown(content, seconds: 0.3)
        w.setContentSize(controller.view.fittingSize)
        Offscreen.settleDown(content, seconds: 0.05)
        defer { w.close() }
        return Offscreen.draw(w, content: content, chrome: .titled, scale: scale)
    }


    // MARK: The fake network (update checks)

    enum Stub {
        case releases(newer: Bool)
        case serverError
        case never
        case download
    }

    static let newVersion = "2.11"
    static let notes = """
    **Smoother Flywheel on 120 Hz displays.** Fast spins now coast the way the Kensington driver does, \
    without the little hitch at the end.

    - App setups switch the moment an app comes to the front
    - Backups list shows what changed in each one
    - Fixes Drag lock letting go when a menu opens
    """

    static func stub(_ s: Stub) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.10"
        func release(_ v: String, _ body: String) -> [String: Any] {
            ["tag_name": "v\(v)", "html_url": "https://github.com/leviholliday/glideball/releases/tag/v\(v)",
             "draft": false, "prerelease": false, "body": body,
             "assets": [["name": "Glideball.zip",
                         "browser_download_url": "https://github.com/leviholliday/glideball/releases/download/v\(v)/Glideball.zip"]]]
        }
        SandboxURLProtocol.responder = { request in
            let isDownload = request.url?.lastPathComponent == "Glideball.zip"
            switch s {
            case .never:
                return .init(delay: 3_600)
            case .serverError:
                return .init(status: 502)
            case .releases(let newer):
                guard !isDownload else { return nil }
                var list = [release("2.9", "Earlier release")]
                if newer { list.insert(release(newVersion, notes), at: 0) }
                else if GlideVersion(current).map({ !$0.isPrerelease }) == true { list.insert(release(current, "This version"), at: 0) }
                return .init(body: (try? JSONSerialization.data(withJSONObject: list)) ?? Data())
            case .download:
                guard isDownload else { return nil }
                return .init(body: Data(count: 9_000_000), stallAfter: 3_870_000)
            }
        }
    }

    // MARK: Contact sheet

    private static func writeIndex(_ o: Options, lang: String,
                                   written: [(name: String, group: String, title: String, file: String, dark: Bool, size: NSSize)]) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var groups: [String] = []
        for w in written where !groups.contains(w.group) { groups.append(w.group) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        var html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Glideball screens</title>
        <style>
        :root { color-scheme: light dark; --bg: #f4f5f7; --fg: #1d1d1f; --muted: #6e6e73; --card: #fff; --line: #d9d9de; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f5f5f7; --muted: #a1a1a6; --card: #232326; --line: #3a3a3e; } }
        body { margin: 0; padding: 24px 16px 64px; background: var(--bg); color: var(--fg); font: 14px/1.4 -apple-system, system-ui, sans-serif; }
        header { max-width: 1400px; margin: 0 auto 8px; }
        h1 { font-size: 22px; margin: 0 0 4px; }
        h2 { font-size: 15px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 32px auto 12px; max-width: 1400px; }
        p.meta { color: var(--muted); margin: 0; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 420px), 1fr)); gap: 16px; max-width: 1400px; margin: 0 auto; }
        figure { margin: 0; background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
        figure a { display: block; background: repeating-conic-gradient(#8881 0% 25%, transparent 0% 50%) 0 0 / 16px 16px; }
        figure img { display: block; width: 100%; height: auto; }
        figcaption { padding: 8px 12px; display: flex; justify-content: space-between; gap: 8px; }
        figcaption code { color: var(--muted); font-size: 12px; }
        </style></head><body>
        <header><h1>Glideball screens</h1>
        <p class="meta">Glideball \(esc(version)) · language \(esc(lang)) · \(Int(o.scale))x · rendered \(esc(stamp)) with <code>--render-ui</code>. Demo data; drawn offscreen (see docs/DEVELOPING.md for what can't be drawn faithfully).</p>
        </header>

        """
        for g in groups {
            html += "<h2>\(esc(g))</h2>\n<div class=\"grid\">\n"
            for w in written where w.group == g {
                html += """
                <figure><a href="\(esc(w.file))"><img src="\(esc(w.file))" alt="\(esc(w.title)), \(w.dark ? "dark" : "light")" loading="lazy" width="\(Int(w.size.width))" height="\(Int(w.size.height))"></a>
                <figcaption><span>\(esc(w.title)) · \(w.dark ? "dark" : "light")</span><code>\(esc(w.file))</code></figcaption></figure>

                """
            }
            html += "</div>\n"
        }
        html += "</body></html>\n"
        try? Data(html.utf8).write(to: o.dir.appendingPathComponent("index.html"), options: .atomic)

        let manifest: [[String: Any]] = written.map {
            ["screen": $0.name, "group": $0.group, "title": $0.title, "file": $0.file,
             "appearance": $0.dark ? "dark" : "light", "width": Int($0.size.width), "height": Int($0.size.height)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["language": lang, "scale": Int(o.scale), "version": version,
                                                                   "pictures": manifest],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: o.dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}
