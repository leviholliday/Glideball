import AppKit
import Foundation

// The app's side of sharing a setup (SharedSetup.swift) and importing from
// KensingtonWorks (KensingtonWorks.swift): what's waiting in the preview sheet,
// what Apply and Cancel do, and what Share… makes.
//
// The rules for anything coming in (a glideball://import link, a shared file,
// KensingtonWorks' settings):
//  - It never changes anything by itself. It opens a preview over Glideball's
//    window that lists every setting that would change, before and after, part
//    by part; each part can be left out there.
//  - Only Apply there changes something: a backup checkpoint first, then the
//    parts still ticked, then a toast with Undo (which also puts the ball color
//    and sounds back).
//  - One preview at a time. While one is open, and for a moment after it
//    closes, anything else that arrives is dropped (a page can't stack sheets).
//  - The primary button never changes, and a share never brings global
//    shortcuts or the pause switch.

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

    /// The parts a share holds (none for KensingtonWorks, which is all or nothing).
    var parts: [SharePart] {
        if case .shared(let s) = content { return s.parts }
        return []
    }

    var share: SharedSetup? {
        if case .shared(let s) = content { return s }
        return nil
    }

    /// The settings `current` would become with `chosen` parts (nil: all).
    func applied(to current: GlideConfig, parts chosen: Set<SharePart>? = nil) -> GlideConfig {
        switch content {
        case .shared(let s): s.applied(to: current, parts: chosen)
        case .kensingtonWorks(let k): k.applied(to: current)
        }
    }

    /// The ball color it brings, if any (and chosen).
    func look(parts chosen: Set<SharePart>? = nil) -> ShareLook? { share?.appliedLook(parts: chosen) }
    var look: ShareLook? { look() }

    /// The sounds it brings, if any (and chosen).
    func sounds(parts chosen: Set<SharePart>? = nil) -> ShareSounds? { share?.appliedSounds(parts: chosen) }

    /// What has no equivalent in Glideball (KensingtonWorks only).
    var notes: [KensingtonWorksImport.Note] {
        if case .kensingtonWorks(let k) = content { return k.notes }
        return []
    }

    var kind: ShareKind? { share?.kind }

    /// The sender's name as they typed it (never checked), if they sent it.
    var from: String? { share?.from }

    /// The headline: "A shared scroll feel", "Settings from KensingtonWorks".
    var title: String {
        switch content {
        case .kensingtonWorks: return String(localized: "Your KensingtonWorks settings", comment: "Import preview title")
        case .shared(let s):
            switch s.kind {
            case .everything:
                if s.legacyKind == .everything {
                    return String(localized: "A whole Glideball setup", comment: "Import preview title for a shared setup with everything in it")
                }
                if s.parts.allSatisfy({ $0.bundleID != nil }) {
                    return String(localized: "\(s.parts.count) shared app setups", comment: "Import preview title; %lld is how many app setups")
                }
                return String(localized: "A shared Glideball setup", comment: "Import preview title for a shared setup with several parts")
            case .appSetup:
                let name = s.apps?.first.map { ImportText.clean($0.name) } ?? String(localized: "an app")
                return String(localized: "A setup for \(name)", comment: "Import preview title; %@ is an app's name")
            case .pointer: return String(localized: "A shared pointer feel", comment: "Import preview title")
            case .scrolling: return String(localized: "A shared scroll feel", comment: "Import preview title")
            case .buttons: return String(localized: "Shared buttons and gestures", comment: "Import preview title")
            case .look:
                return s.parts == [.sounds] ? String(localized: "Shared sounds", comment: "Import preview title")
                    : String(localized: "A shared ball color", comment: "Import preview title")
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

/// Share…: where it was opened from, which decides what's ticked first.
struct ShareRequest: Identifiable {
    let id = UUID()
    var kind: ShareKind
    /// The app setup, when sharing one.
    var appSetup: String?
    /// Kept for callers that still pass it; the checklist always lets you change what's in it.
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

    /// The ways into Share… that search and the menus list (an app setup is shared from the Apps page).
    static let choosable: [ShareKind] = [.everything, .pointer, .scrolling, .buttons, .look]
}

extension SharePart {
    /// The checklist's and the preview's name for it. App setups use the app's name (`title(in:)`).
    var title: String {
        switch self {
        case .pointer: String(localized: "Pointer feel", comment: "Import preview section")
        case .displays: String(localized: "Per-display speeds", comment: "Import preview: the switch for a pointer speed per display")
        case .scrolling: String(localized: "Scroll feel", comment: "Import preview section")
        case .buttons: String(localized: "Buttons")
        case .combos: String(localized: "Combos")
        case .gestures: String(localized: "Gestures", comment: "Import preview: the switch that turns gesture buttons on")
        case .look: String(localized: "Ball color and look", comment: "Import preview section")
        case .sounds: String(localized: "Sounds")
        case .app(let id): id
        }
    }

    /// The name with an app setup's app name, from `apps` (the share's or yours).
    func title(apps: [AppProfile]) -> String {
        guard let id = bundleID else { return title }
        return apps.first { $0.bundleID == id }.map { ImportText.clean($0.name) } ?? id
    }

    var symbol: String {
        switch self {
        case .pointer: "cursorarrow.motionlines"
        case .displays: "display.2"
        case .scrolling: "arrow.up.and.down.circle"
        case .buttons: "button.programmable"
        case .combos: "square.on.square"
        case .gestures: "dot.arrowtriangles.up.right.down.left.circle"
        case .look: "paintpalette"
        case .sounds: "speaker.wave.2"
        case .app: "square.grid.2x2"
        }
    }

    /// The part's own color, where it's about one part of the trackball.
    var area: ImportChange.Area {
        switch self {
        case .pointer, .displays: .pointer
        case .scrolling: .scrolling
        case .buttons, .gestures: .buttons
        case .combos: .combos
        case .app: .appSetups
        case .look: .look
        case .sounds: .sounds
        }
    }
}

extension ShareSounds {
    /// This Mac's Sounds settings now.
    static var current: ShareSounds {
        var kinds: [String: Bool] = [:]
        for k in SoundKind.allCases { kinds[k.rawValue] = Sounds.shared.isOn(k) }
        return ShareSounds(on: Sounds.shared.enabled, volume: Sounds.shared.volume, kinds: kinds)
    }

    /// Makes these this Mac's Sounds settings.
    func use() {
        Sounds.shared.enabled = on
        Sounds.shared.volume = volume
        for k in SoundKind.allCases { if let v = kinds[k.rawValue] { Sounds.shared.set(k, on: v) } }
    }

    static var kindTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: SoundKind.allCases.map { ($0.rawValue, $0.title) })
    }
}

/// Share…'s last choice, so it opens the way you left it.
enum ShareChoiceMemory {
    static let key = "GlideShareParts"

    static func load(_ d: UserDefaults = .standard) -> [SharePart]? {
        d.stringArray(forKey: key).map { $0.compactMap(SharePart.init(id:)) }
    }

    static func save(_ parts: Set<SharePart>, _ d: UserDefaults = .standard) {
        d.set(parts.sorted().map(\.id), forKey: key)
    }
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

    /// Apply: a backup checkpoint, the change (only `parts`, or all of it), and a toast with Undo.
    func applyIncoming(parts chosen: Set<SharePart>? = nil) {
        guard let incoming = pendingIncoming else { return }
        var updated = incoming.applied(to: config, parts: chosen)
        updated.enabled = config.enabled
        updated.buttons[0] = config.buttons[0]
        let look = incoming.look(parts: chosen)
        let lookChanges = look != nil && look != BallThemeStore.shared.look
        let sounds = incoming.sounds(parts: chosen)
        let before = ShareSounds.current
        let soundsChange = sounds != nil && sounds != before
        pendingIncoming = nil
        lastIncomingClosed = ProcessInfo.processInfo.systemUptime
        guard updated != config || lookChanges || soundsChange else {
            show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Your settings already match")))
            return
        }
        backups.checkpoint(config, kind: .beforeImport)
        configBeforeImport = config
        lookBeforeImport = lookChanges ? BallThemeStore.shared.look : nil
        soundsBeforeImport = soundsChange ? before : nil
        config = updated
        if lookChanges, let look { BallThemeStore.shared.use(look) }
        if soundsChange, let sounds { sounds.use() }
        let text: String = switch incoming.content {
        case .kensingtonWorks: String(localized: "Imported your KensingtonWorks settings", comment: "Toast")
        case .shared: String(localized: "Applied “\(incoming.title)”", comment: "Toast; the name of a button preset")
        }
        show(.init(symbol: "arrow.down.doc.fill", text: text, action: .undoImport))
    }

    /// Every setting the preview would change (all of it).
    func changes(for incoming: IncomingSetup) -> [ImportChange] {
        guard let share = incoming.share else {
            return ImportReview.changes(from: config, to: incoming.applied(to: config))
        }
        return share.parts.flatMap { changes(for: incoming, part: $0) }
    }

    /// What one part of a share would change: its own before → after rows.
    func changes(for incoming: IncomingSetup, part: SharePart) -> [ImportChange] {
        let only: Set<SharePart> = [part]
        switch part {
        case .look:
            let current = BallThemeStore.shared.look
            guard let look = incoming.look(parts: only), look != current else { return [] }
            return ImportReview.changes(from: config, to: config, lookFrom: BallThemeStore.title(of: current), to: BallThemeStore.title(of: look))
        case .sounds:
            guard let sounds = incoming.sounds(parts: only) else { return [] }
            return ImportReview.soundChanges(from: .current, to: sounds, titles: ShareSounds.kindTitles)
        default:
            return ImportReview.changes(from: config, to: incoming.applied(to: config, parts: only))
        }
    }

    // MARK: Sharing

    /// What Share… hands out for these parts, with your name if you chose to put it on links.
    func share(parts: Set<SharePart>) -> SharedSetup? {
        SharedSetup.make(Array(parts), from: config, look: BallThemeStore.shared.look, sounds: .current,
                         name: SharingName.forLinks, writtenBy: GlideSettingsFile.appVersion)
    }

    /// A page's own part (the self-test and renders).
    func share(_ kind: ShareKind, appSetup: String? = nil) -> SharedSetup? {
        share(parts: Set(kind.parts(in: config, appSetup: appSetup)))
    }

    func requestShare(_ kind: ShareKind, appSetup: String? = nil) {
        guard pendingIncoming == nil else { return }
        shareRequest = ShareRequest(kind: kind, appSetup: appSetup)
    }

    /// Every part Share… can offer on this Mac, in checklist order.
    var shareableParts: [SharePart] {
        var out: [SharePart] = [.pointer]
        if !config.displaySpeeds.speeds.isEmpty { out.append(.displays) }
        out += [.scrolling, .buttons, .combos, .gestures]
        out += config.appProfiles.map { .app($0.bundleID) }
        out += [.look, .sounds]
        return out
    }

    /// What's ticked when Share… opens: the part you asked for from a page; from
    /// "Share Everything…" your last choice (everything but per-display speeds the first time).
    func initialShareParts(_ request: ShareRequest) -> Set<SharePart> {
        let available = Set(shareableParts)
        if request.kind == .everything {
            if let saved = ShareChoiceMemory.load() {
                let kept = Set(saved).intersection(available)
                if !kept.isEmpty { return kept }
            }
            return available.subtracting([.displays])
        }
        return Set(request.kind.parts(in: config, appSetup: request.appSetup)).intersection(available)
    }

    /// One line about a part as you have it: "Flywheel, glide 82 ms, 4 pt a slow turn".
    func headline(_ part: SharePart) -> String {
        let c = config
        switch part {
        case .pointer:
            return String(localized: "Speed \(c.trackingSpeed.formatted()), Precision \(c.precisionSpeed.formatted())", comment: "Share: what the pointer feel holds")
        case .displays:
            return String(localized: "Only useful with the same displays, like your other Mac", comment: "Share: per-display speeds")
        case .scrolling:
            return ImportReview.scrollLine(c.scrollSettings)
        case .buttons:
            let n = (1...7).filter { b in let a = c.buttons[b] ?? .system; return !a.isGesture && !a.isNormal(for: b) }.count
            return n == 0 ? String(localized: "All as they come", comment: "Share: no button changed")
                : String(localized: "\(n) buttons changed", comment: "Buttons that do something other than the main setup, in an app setup")
        case .combos:
            return c.chords.isEmpty ? String(localized: "No combos") : String(localized: "\(c.chords.count) combos")
        case .gestures:
            return c.buttons.values.contains(where: \.isGesture)
                ? String(localized: "Gesture buttons and the gesture settings", comment: "Share: what the gestures part holds")
                : String(localized: "The gesture settings (no gesture buttons)", comment: "Share: gestures part without gesture buttons")
        case .app(let id):
            return c.profile(for: id)?.summary(comparedTo: c) ?? ""
        case .look:
            return BallThemeStore.title(of: BallThemeStore.shared.look)
        case .sounds:
            let s = ShareSounds.current
            return s.on ? String(localized: "On, volume \(s.volume.wholePercent)", comment: "Share: the sounds settings; %@ is a percentage")
                : String(localized: "Off", comment: "A switch that's off")
        }
    }

    /// "Pointer feel, scroll feel and 2 app setups": what a choice holds, in words.
    func summary(of parts: Set<SharePart>) -> String {
        let fixed = SharePart.fixed.filter(parts.contains).map(\.title)
        let apps = parts.filter { $0.bundleID != nil }
        var names = fixed
        if apps.count == 1, let id = apps.first?.bundleID {
            names.append(String(localized: "the \(config.profile(for: id)?.name ?? id) setup", comment: "Share summary: one app setup; %@ is the app"))
        } else if apps.count > 1 {
            names.append(String(localized: "\(apps.count) app setups", comment: "Share summary"))
        }
        guard !names.isEmpty else { return String(localized: "Nothing yet. Tick what you want to send.", comment: "Share summary when nothing is ticked") }
        return names.formatted(.list(type: .and))
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
