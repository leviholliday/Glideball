import AppKit
import SwiftUI

/// `Glide --render-ui <dir> [--appearance light|dark|both] [--only a,b*,…] [--scale 1|2] [--lang de]`
///
/// SwiftUI can't draw every screen in one process (AttributeGraph runs out of
/// table space after ~180 scenes), so `scripts/render-ui.sh` splits a big run:
/// `--list` prints the selected screen names and exits; `--slice <from>,<count>`
/// draws only that part of the selection and writes `.render-ui-part-<from>.json`
/// instead of the contact sheet; `--assemble` (no drawing) joins the parts into
/// `index.html` and `manifest.json` and deletes them.
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
        var list = false
        var slice: Range<Int>?
        var assemble = false
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
        if options.assemble { assemble(options) }
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
            print("usage: Glide --render-ui <dir> [--appearance light|dark|both] [--only name,name*,…] [--scale 1|2] [--lang <code>] [--list | --slice <from>,<count> | --assemble]")
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
        if let i = args.firstIndex(of: "--list") { o.list = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--assemble") { o.assemble = true; args.remove(at: i) }
        if let s = value(after: "--slice") {
            let parts = s.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2, parts[0] >= 0, parts[1] > 0 else { fail("--slice is <from>,<count>") }
            o.slice = parts[0]..<(parts[0] + parts[1])
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
        setvbuf(stdout, nil, _IOLBF, 0)   // piped output is block-buffered by default; a kill would lose it (scripts/render-ui.sh reads it to name a stuck scene)
        do {
            try FileManager.default.createDirectory(at: o.dir, withIntermediateDirectories: true)
        } catch {
            print("error: can't create \(o.dir.path): \(error.localizedDescription)")
            exit(2)
        }
        Offscreen.layoutScale = o.scale
        DemoData.seed()
        let model = AppModel.shared
        if o.list {   // names only: nothing drawn, so none of the settling below
            let names = all(model).map(\.name).filter { n in o.only.isEmpty || o.only.contains { matches(n, $0) } }
            if names.isEmpty { print("error: --only matched nothing"); exit(2) }
            names.forEach { print($0) }
            exit(0)
        }
        DemoData.prime(model)
        settleSync(model)
        stub(.releases(newer: false))
        model.updates.checkNow()   // so Settings › Updates says when it last looked
        waitUntil(3) { model.updates.manualCheck == .upToDate }

        let screens = all(model)
        var selected = screens.filter { s in o.only.isEmpty || o.only.contains { matches(s.name, $0) } }
        if selected.isEmpty {
            print("error: --only matched nothing. Screens: \(screens.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        if let slice = o.slice {
            let total = selected.count
            selected = Array(selected[min(slice.lowerBound, total)..<min(slice.upperBound, total)])
            if selected.isEmpty { print("error: --slice \(slice.lowerBound) is past the \(total) screens selected"); exit(2) }
            print("render-ui: screens \(slice.lowerBound + 1)–\(slice.lowerBound + selected.count) of \(total)")
        }
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        print("render-ui: \(selected.count) screens × \(o.appearances.count) appearance(s) at \(Int(o.scale))x, language \(lang) → \(o.dir.path)")

        var written: [(screen: Screen, file: String, dark: Bool, size: NSSize)] = []
        var problems: [String] = []
        for screen in selected {
            print("  ▸ \(screen.name)")   // render-ui.sh names this scene if the run stalls or crashes
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
        let pictures = written.map { Picture(name: $0.screen.name, group: $0.screen.group, title: $0.screen.title,
                                             file: $0.file, dark: $0.dark, width: Int($0.size.width), height: Int($0.size.height)) }
        if let slice = o.slice {
            let part = Part(lang: lang, scale: Int(o.scale), from: slice.lowerBound, pictures: pictures)
            do {
                try JSONEncoder().encode(part).write(to: o.dir.appendingPathComponent(".render-ui-part-\(slice.lowerBound).json"), options: .atomic)
            } catch {
                problems.append("part file: \(error.localizedDescription)")
            }
        } else {
            writeIndex(o, lang: lang, written: pictures)
        }
        let elapsed = Date().timeIntervalSince(started)
        if problems.isEmpty {
            print("render-ui: wrote \(written.count) pictures\(o.slice == nil ? " and index.html" : "") in \(String(format: "%.1f", elapsed)) s")
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

    static let windowSize = AppDelegate.mainWindowSize

    private static func appearance(_ dark: Bool) -> NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }

    /// The main window on `tab`, as it opens, with `overlay` on top (the tour, say).
    static func mainWindow<O: View>(_ model: AppModel, tab: GlideTab, dark: Bool, scale: CGFloat,
                                    size: NSSize? = nil, fullScreen: Bool = false,
                                    @ViewBuilder overlay: () -> O) -> NSBitmapImageRep? {
        UserDefaults.standard.set(tab.rawValue, forKey: "GlideInitialTab")
        defer { UserDefaults.standard.removeObject(forKey: "GlideInitialTab") }
        model.fullScreen = fullScreen
        defer { model.fullScreen = false }
        let view = ZStack {
            RootView(model: model)
            overlay()
        }
        return Offscreen.render(view, size: size ?? windowSize, chrome: fullScreen ? .mainWindowFullScreen : .mainWindow,
                                appearance: appearance(dark), scale: scale)
    }

    static func mainWindow(_ model: AppModel, tab: GlideTab, dark: Bool, scale: CGFloat,
                           size: NSSize? = nil) -> NSBitmapImageRep? {
        mainWindow(model, tab: tab, dark: dark, scale: scale, size: size) { EmptyView() }
    }

    /// A whole tab, top to bottom (what scrolling would show), without the sidebar: the content column at its full width.
    /// `detail`: the window's detail area this wide instead (a wide window's columns, PageLayout.swift).
    static func fullPage<V: View>(_ page: V, dark: Bool, scale: CGFloat, detail: CGFloat? = nil) -> NSBitmapImageRep? {
        if let detail {
            let view = page
                .pageFrame(PageGrid.width(forDetail: detail))
                .padding(.vertical, 24)
                .background(GlideBackground())
            return Offscreen.renderTall(view, width: detail, appearance: appearance(dark), scale: scale)
        }
        let view = page
            .frame(width: Theme.Space.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Theme.Space.contentSide)
            .padding(.vertical, 24)
            .background(GlideBackground())
        return Offscreen.renderTall(view, width: Theme.Space.contentMaxWidth + Theme.Space.contentSide * 2,
                                    appearance: appearance(dark), scale: scale)
    }

    /// A sheet's content at its own size, as macOS shows it over the window.
    static func sheet<V: View>(_ view: V, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        Offscreen.render(view, size: nil, chrome: .plain, appearance: appearance(dark), scale: scale)
    }

    /// A card on its own, on the window's background.
    static func card<V: View>(_ view: V, width: CGFloat, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let v = view.padding(Theme.Space.contentSide).background(GlideBackground())
        return Offscreen.renderTall(v, width: width, appearance: appearance(dark), scale: scale)
    }

    /// The Wheel's ring as it shows over a desktop: the real `WheelOverlayView` on a stand-in
    /// wallpaper (`busy`: a bright, many-colored one, to judge contrast), with the pointer at
    /// its centre as the stand-in pointer draws it.
    static func wheelOverlay(_ m: WheelOverlayModel, busy: Bool, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let state = WheelOverlayState()
        state.model = m
        state.shown = true
        let size = WheelLayout.canvas
        let wallpaper: [Color] = busy
            ? [Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 0.95, green: 0.35, blue: 0.45), Color(red: 0.25, green: 0.65, blue: 0.95), .white]
            : dark ? [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.2, green: 0.12, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.25)]
                   : [Color(red: 0.75, green: 0.86, blue: 0.97), Color(red: 0.96, green: 0.9, blue: 0.86), Color(red: 0.86, green: 0.93, blue: 0.88)]
        let view = ZStack(alignment: .topLeading) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            // Something to read through the glass: a window's edge and a few lines of text.
            RoundedRectangle(cornerRadius: 12).fill(dark ? Color(white: 0.16) : .white).frame(width: 250, height: 300).offset(x: -40, y: 60)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<9, id: \.self) { i in
                    Text(verbatim: ["Quarterly notes", "Draft the release post", "Ship the beta tonight", "Test on the Expert Mouse",
                                    "Ring job: volume", "Lunch at noon", "Glideball", "Reply to Sam", "Backups on"][i])
                        .font(.system(size: 13, weight: i == 0 ? .bold : .regular))
                        .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8))
                }
            }
            .offset(x: -16, y: 80)
            WheelOverlayView(state: state)
            Image(nsImage: NSCursor.arrow.image)
                .position(x: WheelLayout.centre.x + NSCursor.arrow.image.size.width / 2 - NSCursor.arrow.hotSpot.x,
                          y: WheelLayout.centre.y + NSCursor.arrow.image.size.height / 2 - NSCursor.arrow.hotSpot.y)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        return Offscreen.render(view, size: size, chrome: .plain, appearance: appearance(dark), scale: scale)
    }

    /// Made-up apps for the Switcher's pictures: generated icons (a rounded square in two
    /// colors with an SF Symbol), so a picture never depends on what's running on this Mac.
    static func fakeSwitcherEntries(_ n: Int) -> [SwitcherEntry] {
        let kinds: [(String, String, NSColor, NSColor)] = [
            ("Compass", "safari", .systemTeal, .systemBlue), ("Letters", "envelope.fill", .systemBlue, .systemIndigo),
            ("Notebook", "note.text", .systemYellow, .systemOrange), ("Terminal", "terminal.fill", .darkGray, .black),
            ("Studio", "paintbrush.pointed.fill", .systemPink, .systemPurple), ("Tunes", "music.note", .systemRed, .systemPink),
            ("Calendar", "calendar", .systemRed, .systemOrange), ("Photos", "camera.macro", .systemOrange, .systemPink),
            ("Files", "folder.fill", .systemCyan, .systemBlue), ("Chat", "bubble.left.and.bubble.right.fill", .systemGreen, .systemTeal),
            ("Maps", "map.fill", .systemGreen, .systemMint), ("Sheets", "tablecells.fill", .systemGreen, .systemTeal),
            ("Slides", "rectangle.on.rectangle.angled.fill", .systemOrange, .systemYellow), ("Code", "chevron.left.forwardslash.chevron.right", .systemIndigo, .systemPurple),
            ("Weather", "cloud.sun.fill", .systemBlue, .systemCyan), ("Reminders", "checklist", .systemOrange, .systemRed),
            ("Books", "book.fill", .systemOrange, .systemBrown), ("Podcasts", "mic.fill", .systemPurple, .systemIndigo),
            ("Settings", "gearshape.fill", .systemGray, .darkGray), ("Preview", "doc.richtext.fill", .systemBlue, .systemTeal),
            ("Clock", "clock.fill", .black, .darkGray), ("Contacts", "person.crop.circle.fill", .systemBrown, .systemOrange),
            ("Stocks", "chart.line.uptrend.xyaxis", .darkGray, .black), ("Voice Memos", "waveform", .systemRed, .systemPink),
        ]
        return (0..<n).map { i in
            let k = kinds[i % kinds.count]
            let name = i < kinds.count ? k.0 : "\(k.0) \(i / kinds.count + 1)"
            return SwitcherEntry(id: i, name: name, icon: fakeAppIcon(k.1, k.2, k.3), windows: [1, 3, 0, 2, 1, 1, 5, 0][i % 8],
                                 hidden: i % 11 == 7, app: nil)
        }
    }

    static func fakeAppIcon(_ symbol: String, _ top: NSColor, _ bottom: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
            let body = r.insetBy(dx: 12, dy: 12)
            let path = NSBezierPath(roundedRect: body, xRadius: 23, yRadius: 23)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 46, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let s = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                s.draw(in: NSRect(x: r.midX - s.size.width / 2, y: r.midY - s.size.height / 2, width: s.size.width, height: s.size.height))
            }
            return true
        }
    }

    /// The Switcher's panel as it shows on a display: the real `SwitcherOverlayView` on a stand-in
    /// wallpaper (`busy`: a bright, many-colored one, to judge contrast), with the stand-in pointer
    /// where the hold left it.
    static func switcherOverlay(apps: Int, selected: Int, firstRow: Int = 0, maxRows: Int = 3, busy: Bool,
                                dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let entries = fakeSwitcherEntries(apps)
        let grid = SwitcherGrid.fitting(count: apps, maxColumns: SwitcherLayout.maxColumns, maxRows: maxRows)
        let state = SwitcherOverlayState()
        state.entries = entries
        state.model = SwitcherOverlayModel(session: 1, grid: grid, selected: selected, firstRow: firstRow)
        state.shown = true
        let canvas = SwitcherLayout.canvas(grid)
        let size = CGSize(width: max(canvas.width + 120, 720), height: canvas.height + 120)
        let wallpaper: [Color] = busy
            ? [Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 0.95, green: 0.35, blue: 0.45), Color(red: 0.25, green: 0.65, blue: 0.95), .white]
            : dark ? [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.2, green: 0.12, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.25)]
                   : [Color(red: 0.75, green: 0.86, blue: 0.97), Color(red: 0.96, green: 0.9, blue: 0.86), Color(red: 0.86, green: 0.93, blue: 0.88)]
        let view = ZStack(alignment: .topLeading) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            // Something to read through the glass: a window and a few lines of text.
            RoundedRectangle(cornerRadius: 12).fill(dark ? Color(white: 0.16) : .white)
                .frame(width: size.width * 0.55, height: size.height * 0.7).offset(x: 40, y: 40)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<14, id: \.self) { i in
                    Text(verbatim: ["Quarterly notes", "Draft the release post", "Ship the beta tonight", "Test on the Expert Mouse",
                                    "Roll to pick an app", "Lunch at noon", "Glideball", "Reply to Sam", "Backups on",
                                    "Order more coffee", "Fix the ring direction", "Read chapter 4", "Call home", "Gym at 6"][i])
                        .font(.system(size: 13, weight: i == 0 ? .bold : .regular))
                        .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8))
                }
            }
            .offset(x: 64, y: 60)
            if busy {
                ForEach(0..<6, id: \.self) { i in
                    Circle().fill([Color.red, .green, .orange, .purple, .cyan, .yellow][i].opacity(0.85))
                        .frame(width: 90, height: 90)
                        .offset(x: CGFloat(i) * size.width / 6, y: CGFloat(i % 3) * size.height / 3)
                }
            }
            SwitcherOverlayView(state: state)
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: (size.width - canvas.width) / 2, y: (size.height - canvas.height) / 2)
            // The stand-in pointer, still where the hold left it (off to one side).
            Image(nsImage: NSCursor.arrow.image)
                .position(x: size.width * 0.18 + NSCursor.arrow.image.size.width / 2,
                          y: size.height * 0.2 + NSCursor.arrow.image.size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        return Offscreen.render(view, size: size, chrome: .plain, appearance: appearance(dark), scale: scale)
    }

    /// Glideball › Settings…, through the real `SettingsWindowController` (toolbar tabs and all).
    static func settings(_ pane: SettingsPane, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        UserDefaults.standard.set(pane.rawValue, forKey: SettingsWindowController.lastPaneKey)
        let controller = SettingsWindowController()
        guard let window = controller.window, let content = window.contentView else { return nil }
        window.appearance = appearance(dark)
        window.animationBehavior = .none
        Offscreen.lookActive(window)
        // The tab reports its height once it has laid out; the window follows.
        Offscreen.settleDown(content, seconds: 0.3)
        Offscreen.settleDown(content, seconds: 0.1)
        defer { window.close() }
        return Offscreen.draw(window, content: content, chrome: .titled, scale: scale)
    }

    /// A small titled panel (the external-control notice), built the way the app builds it.
    static func panel<V: View>(_ view: V, dark: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        let controller = NSHostingController(rootView: Offscreen.withoutAnimations(view))
        controller.sizingOptions = [.preferredContentSize]
        let w = Offscreen.ActiveLookingWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = appearance(dark)
        guard let content = w.contentView else { return nil }
        Offscreen.settleDown(content, seconds: 0.2)
        w.setContentSize(controller.view.fittingSize)
        Offscreen.settleDown(content, seconds: 0.05)
        defer { w.close() }
        return Offscreen.draw(w, content: content, chrome: .titled, scale: scale)
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

    struct Picture: Codable {
        let name, group, title, file: String
        let dark: Bool
        let width, height: Int
    }

    /// What one `--slice` run drew, for `--assemble`.
    struct Part: Codable {
        let lang: String
        let scale: Int
        let from: Int
        let pictures: [Picture]
    }

    /// `--assemble`: joins the `--slice` runs' part files, in order, into one contact sheet.
    private static func assemble(_ o: Options) -> Never {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: o.dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".render-ui-part-") && $0.pathExtension == "json" }
        var parts: [Part] = []
        for f in files {
            guard let data = try? Data(contentsOf: f), let part = try? JSONDecoder().decode(Part.self, from: data) else {
                print("error: can't read \(f.path)")
                exit(1)
            }
            parts.append(part)
        }
        parts.sort { $0.from < $1.from }
        guard let first = parts.first else {
            print("error: no part files in \(o.dir.path)")
            exit(1)
        }
        var opts = o
        opts.scale = CGFloat(first.scale)
        let pictures = parts.flatMap(\.pictures)
        writeIndex(opts, lang: first.lang, written: pictures)
        files.forEach { try? fm.removeItem(at: $0) }
        print("render-ui: joined \(parts.count) parts, \(pictures.count) pictures, into index.html")
        exit(0)
    }

    private static func writeIndex(_ o: Options, lang: String, written: [Picture]) {
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
                <figure><a href="\(esc(w.file))"><img src="\(esc(w.file))" alt="\(esc(w.title)), \(w.dark ? "dark" : "light")" loading="lazy" width="\(w.width)" height="\(w.height)"></a>
                <figcaption><span>\(esc(w.title)) · \(w.dark ? "dark" : "light")</span><code>\(esc(w.file))</code></figcaption></figure>

                """
            }
            html += "</div>\n"
        }
        html += "</body></html>\n"
        try? Data(html.utf8).write(to: o.dir.appendingPathComponent("index.html"), options: .atomic)

        let manifest: [[String: Any]] = written.map {
            ["screen": $0.name, "group": $0.group, "title": $0.title, "file": $0.file,
             "appearance": $0.dark ? "dark" : "light", "width": $0.width, "height": $0.height]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["language": lang, "scale": Int(o.scale), "version": version,
                                                                   "pictures": manifest],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: o.dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
}
