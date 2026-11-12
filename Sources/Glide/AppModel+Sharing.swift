import AppKit
import Foundation

// The app's side of sharing a setup (SharedSetup.swift) and importing from
// KensingtonWorks (KensingtonWorks.swift): what's waiting in the preview sheet,
// what Apply and Cancel do, and what Share… makes.
//
// The rules for anything coming in (a glideball://import link, a shared file,
// KensingtonWorks' settings):
//  - It never changes anything by itself. It opens a preview over Glideball's
//    window that lists every setting that would change, before and after.
//  - Only Apply there changes something: a backup checkpoint first, then the
//    change, then a toast with Undo (which also puts the ball color back).
//  - One preview at a time. While one is open, and for a moment after it
//    closes, anything else that arrives is dropped (a page can't stack sheets).
//  - The primary button never changes, and a share from someone else never
//    brings their global shortcuts, per-display speeds or pause switch.

/// Something waiting in the preview sheet.
struct IncomingSetup: Identifiable {
    enum Source: Equatable {
        case link
        case file(String)
        case kensingtonWorks
    }

    enum Content {
        case shared(SharedSetup)
        case kensingtonWorks(KensingtonWorksImport)
    }

    let id = UUID()
    let source: Source
    let content: Content

    /// The settings `current` would become.
    func applied(to current: GlideConfig) -> GlideConfig {
        switch content {
        case .shared(let s): s.applied(to: current)
        case .kensingtonWorks(let k): k.applied(to: current)
        }
    }

    /// The ball color it brings, if any.
    var look: ShareLook? {
        if case .shared(let s) = content { return s.appliedLook }
        return nil
    }

    /// What has no equivalent in Glideball (KensingtonWorks only).
    var notes: [KensingtonWorksImport.Note] {
        if case .kensingtonWorks(let k) = content { return k.notes }
        return []
    }

    var kind: ShareKind? {
        if case .shared(let s) = content { return s.kind }
        return nil
    }

    /// The headline: "A shared scroll feel", "Settings from KensingtonWorks".
    var title: String {
        switch content {
        case .kensingtonWorks: return String(localized: "Your KensingtonWorks settings", comment: "Import preview title")
        case .shared(let s):
            switch s.kind {
            case .everything: return String(localized: "A whole Glideball setup", comment: "Import preview title for a shared setup with everything in it")
            case .appSetup: return String(localized: "A setup for \(s.appSetup?.name ?? s.name ?? "an app")", comment: "Import preview title; %@ is an app's name")
            case .pointer: return String(localized: "A shared pointer feel", comment: "Import preview title")
            case .scrolling: return String(localized: "A shared scroll feel", comment: "Import preview title")
            case .buttons: return String(localized: "Shared buttons and gestures", comment: "Import preview title")
            case .look: return String(localized: "A shared ball color", comment: "Import preview title")
            }
        }
    }

    /// Where it came from, in words.
    var origin: String {
        switch source {
        case .link: String(localized: "From a link. Nothing has changed yet.", comment: "Import preview: where a shared setup came from")
        case .file(let name): String(localized: "From the file “\(name)”. Nothing has changed yet.", comment: "Import preview: where a shared setup came from")
        case .kensingtonWorks:
            if case .kensingtonWorks(let k) = content {
                String(localized: "Found on this Mac, for your \(k.deviceName). Glideball only reads them; KensingtonWorks’ files stay as they are.",
                       comment: "Import preview: KensingtonWorks settings; %@ is a trackball's name")
            } else { "" }
        }
    }
}

/// Share…: which parts can be chosen, and which is chosen first.
struct ShareRequest: Identifiable {
    let id = UUID()
    var kind: ShareKind
    /// The app setup, when sharing one.
    var appSetup: String?
    /// Whether the person can switch to another part (not when sharing one app's setup).
    var canChoose = true
}

extension ShareKind {
    var title: String {
        switch self {
        case .everything: String(localized: "Everything", comment: "Share: the whole setup")
        case .appSetup: String(localized: "App setup", comment: "Share: one app's setup")
        case .pointer: String(localized: "Pointer feel", comment: "Import preview section")
        case .scrolling: String(localized: "Scroll feel", comment: "Import preview section")
        case .buttons: String(localized: "Buttons and gestures", comment: "Import preview section")
        case .look: String(localized: "Ball color and look", comment: "Import preview section")
        }
    }

    var symbol: String {
        switch self {
        case .everything: "square.stack.3d.up"
        case .appSetup: "square.grid.2x2"
        case .pointer: "cursorarrow.motionlines"
        case .scrolling: "arrow.up.and.down.circle"
        case .buttons: "button.programmable"
        case .look: "paintpalette"
        }
    }

    /// The parts a person picks from in Share… (an app setup is shared from the Apps page).
    static let choosable: [ShareKind] = [.everything, .pointer, .scrolling, .buttons, .look]
}

extension AppModel {
    /// How long after a preview closes before another may open.
    static let incomingCooldown = 1.5

    // MARK: Receiving

    /// A shared setup arrived (a link or a file): show what it would change.
    /// Dropped while another preview is open or just closed.
    func receiveShare(_ share: SharedSetup, from source: IncomingSetup.Source) {
        present(IncomingSetup(source: source, content: .shared(share)))
    }

    /// Reads KensingtonWorks' settings (read-only) and previews importing them.
    func previewKensingtonWorks() {
        guard let imp = KensingtonWorksSource.load() else {
            show(.init(symbol: "exclamationmark.triangle.fill",
                       text: String(localized: "Couldn’t read KensingtonWorks’ settings."), isError: true))
            return
        }
        present(IncomingSetup(source: .kensingtonWorks, content: .kensingtonWorks(imp)), cooldown: false)
    }

    private func present(_ incoming: IncomingSetup, cooldown: Bool = true) {
        guard pendingIncoming == nil, queuedIncoming == nil, pendingImport == nil, shareRequest == nil else { return }   // one at a time
        if cooldown, ProcessInfo.processInfo.systemUptime - lastIncomingClosed < Self.incomingCooldown { return }
        if !Sandbox.isActive { (NSApp.delegate as? AppDelegate)?.showWindow() }
        // The person asked for it, so it shows straight away, unless the launch
        // animation, the tour, a sheet or another card is up: then it waits its turn.
        if incomingMustWait {
            queuedIncoming = incoming
        } else {
            pendingIncoming = incoming
        }
    }

    /// Cancel (or Escape): nothing changes.
    func cancelIncoming() {
        pendingIncoming = nil
        lastIncomingClosed = ProcessInfo.processInfo.systemUptime
    }

    /// Apply: a backup checkpoint, the change, and a toast with Undo.
    func applyIncoming() {
        guard let incoming = pendingIncoming else { return }
        var updated = incoming.applied(to: config)
        updated.enabled = config.enabled
        updated.buttons[0] = config.buttons[0]
        let look = incoming.look
        let lookChanges = look != nil && look != BallThemeStore.shared.look
        pendingIncoming = nil
        lastIncomingClosed = ProcessInfo.processInfo.systemUptime
        guard updated != config || lookChanges else {
            show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Your settings already match")))
            return
        }
        backups.checkpoint(config, kind: .beforeImport)
        configBeforeImport = config
        lookBeforeImport = lookChanges ? BallThemeStore.shared.look : nil
        config = updated
        if lookChanges, let look { BallThemeStore.shared.use(look) }
        let text: String = switch incoming.content {
        case .kensingtonWorks: String(localized: "Imported your KensingtonWorks settings", comment: "Toast")
        case .shared: String(localized: "Applied “\(incoming.title)”", comment: "Toast; the name of a button preset")
        }
        show(.init(symbol: "arrow.down.doc.fill", text: text, action: .undoImport))
    }

    /// Every setting the preview would change.
    func changes(for incoming: IncomingSetup) -> [ImportChange] {
        let current = BallThemeStore.shared.look
        let look = incoming.look.flatMap { $0 == current ? nil : $0 }
        return ImportReview.changes(from: config, to: incoming.applied(to: config),
                                    lookFrom: look.map { _ in BallThemeStore.title(of: current) },
                                    to: look.map(BallThemeStore.title(of:)))
    }

    // MARK: Sharing

    /// What Share… hands out for one part (or one app's setup).
    func share(_ kind: ShareKind, appSetup: String? = nil) -> SharedSetup? {
        SharedSetup.make(kind, from: config, look: BallThemeStore.shared.look, appSetup: appSetup,
                         writtenBy: GlideSettingsFile.appVersion)
    }

    func requestShare(_ kind: ShareKind, appSetup: String? = nil) {
        guard pendingIncoming == nil else { return }
        shareRequest = ShareRequest(kind: kind, appSetup: appSetup, canChoose: kind != .appSetup)
    }

    /// One line about what a share holds: "Flywheel, glide 82 ms, 4 pt a slow turn".
    func headline(_ kind: ShareKind, appSetup: String? = nil) -> String {
        switch kind {
        case .everything:
            return [String(localized: "Pointer \(config.trackingSpeed.formatted())", comment: "Pointer speed in an app setup"),
                    config.scrollMode.scrollingTitle, config.appProfilesSummary].joined(separator: " · ")
        case .appSetup:
            guard let p = config.profile(for: appSetup) else { return "" }
            return p.summary(comparedTo: config)
        case .pointer:
            return String(localized: "Speed \(config.trackingSpeed.formatted()), Precision \(config.precisionSpeed.formatted())", comment: "Share: what the pointer feel holds")
        case .scrolling:
            return ImportReview.scrollLine(config.scrollSettings)
        case .buttons:
            let n = config.buttons.filter { $0.key != 0 && !$0.value.isNormal(for: $0.key) }.count
            return [String(localized: "\(n) buttons changed", comment: "Buttons that do something other than the main setup, in an app setup"),
                    config.chords.isEmpty ? String(localized: "No combos") : String(localized: "\(config.chords.count) combos")].joined(separator: " · ")
        case .look:
            return BallThemeStore.title(of: BallThemeStore.shared.look)
        }
    }

    /// A temporary file of a share, for dragging, the share sheet or saving.
    func shareFile(_ share: SharedSetup, name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = (Sandbox.isActive ? Sandbox.folder : FileManager.default.temporaryDirectory)
            .appendingPathComponent(safe).appendingPathExtension(GlideSettingsFile.fileExtension)
        do {
            try share.fileData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Where KensingtonWorks' settings come from: the real file, read-only, or (in
/// `--render-ui` and `--self-test`) a sample, so a render never reads the real one.
enum KensingtonWorksSource {
    /// Renders and the self-test: what to pretend is on this Mac.
    nonisolated(unsafe) static var sandboxSettings: KWSettings?
    nonisolated(unsafe) private static var cached: (date: Date, found: Bool)?

    static func load() -> KensingtonWorksImport? {
        let settings: KWSettings?
        if Sandbox.isActive {
            settings = sandboxSettings
        } else if case .success(let s) = KensingtonWorks.read() {
            settings = s
        } else {
            settings = nil
        }
        return settings.flatMap(KensingtonWorksImport.make(from:))
    }

    /// Whether there are KensingtonWorks settings to import (checked at most once a minute).
    static var found: Bool {
        if Sandbox.isActive { return sandboxSettings != nil }
        if let cached, Date().timeIntervalSince(cached.date) < 60 { return cached.found }
        let found = load() != nil
        cached = (Date(), found)
        return found
    }

    /// The sample (the shape of a real KensingtonWorks 2 file, with a made-up app).
    static let sample = """
    {"devices":[[4128,{"*":{"name":"*","config":{"acceleration":true,"accelerationRate":0,"speed":100,"scrollLines":19,
      "inertialScroll":true,"scrollInvert":false,"slowModifiers":"","snapModifiers":"","lockedAxisModifiers":"",
      "commands":[[1,{"command":"mouse_leftClick","params":null}],[2,{"command":"missionControl_missionControl","params":{}}],
        [4,{"command":"mouse_middleClick","params":null}],[8,{"command":"keyboard_shortcut","params":{"keyCode":8,"label":"Copy","modifiers":"cmd"}}],
        [5,{"command":"keyboard_shortcut","params":{"keyCode":9,"label":"Paste","modifiers":"cmd"}}],
        [12,{"command":"launch_application","params":{"label":"Calculator"}}],[3,{"command":"disable","params":{}}],
        [16,{"command":"mouse_button5Click","params":null}]],
      "snippets":[{"content":"","label":""}]}},
     "com.apple.dt.Xcode-Xcode":{"name":"Xcode","config":{"inertialScroll":true,"scrollInvert":false,
      "commands":[[1,{"command":"mouse_leftClick","params":null}],[4,{"command":"keyboard_shortcut","params":{"keyCode":15,"label":"Run","modifiers":"cmd"}}],
        [8,{"command":"keyboard_shortcut","params":{"keyCode":40,"label":"Jump","modifiers":"ctrl+cmd"}}]]}}}]],
     "versionMajor":2,"versionMinor":0}
    """
}
