import Compression
import Foundation

// Sharing a setup with someone else: whichever parts the person ticks in
// Share… (pointer feel, per-display speeds, scroll feel, buttons, combos,
// gestures, each app setup, ball color, sounds). The format is written once, in
// docs/SHARE-FORMAT.md; the website's /s/ page reads the same thing
// (website/s/share-decode.js), and both are checked against the same fixtures.
//
// Three carriers, the same JSON inside:
//  - a file: the usual .glide-settings type, with a `format`, `kind: "parts"`,
//    `parts` and only those parts' fields;
//  - a link to the website, https://glideball.netlify.app/s/#<d>, which shows
//    what's in it and offers Import to Glideball (the payload is after the #,
//    so it never reaches a server);
//  - glideball://import?d=<d>, what that page's button opens.
// <d> is base64url (no padding) of raw-deflated JSON. A link is offered only
// when it fits in 2,000 characters (otherwise it's file only).
//
// Receiving is the dangerous side: any web page can open a glideball:// link.
// So nothing here changes anything. A share is decoded (size-capped, depth-
// checked, strictly validated), turned into the settings it would give
// (`applied(to:parts:)`, through the same sanitizing as file import) and shown
// as a preview, part by part; only Apply in Glideball's own window changes
// something, and only the parts still ticked there. The primary button never
// changes, and a share never carries or changes global shortcuts or the pause switch.
//
// Beta 12's shares (one `kind` each) are still read: they're turned into the
// same parts on the way in (`init(from:)`).
//
// Foundation only, so the simulators can check it.

/// What Share… started from (a page's share menu, an app setup's row). Also the
/// kind a beta 12 share said it was.
enum ShareKind: String, Codable, CaseIterable, Identifiable {
    case everything
    case appSetup = "app-setup"
    case pointer
    case scrolling
    case buttons
    case look
    var id: String { rawValue }
}

/// One thing a share can carry: a row of Share…'s checklist, and of the preview's.
enum SharePart: Hashable, Identifiable, Comparable {
    case pointer, displays, scrolling, buttons, combos, gestures, look, sounds
    /// One app setup, by bundle ID.
    case app(String)

    /// The parts that aren't app setups, in checklist order.
    static let fixed: [SharePart] = [.pointer, .displays, .scrolling, .buttons, .combos, .gestures, .look, .sounds]

    /// "pointer", "app:com.apple.Safari" (docs/SHARE-FORMAT.md).
    var id: String {
        switch self {
        case .pointer: "pointer"
        case .displays: "displays"
        case .scrolling: "scrolling"
        case .buttons: "buttons"
        case .combos: "combos"
        case .gestures: "gestures"
        case .look: "look"
        case .sounds: "sounds"
        case .app(let id): "app:" + id
        }
    }

    init?(id: String) {
        if id.hasPrefix("app:") {
            let bundle = String(id.dropFirst(4))
            guard ImportText.isBundleID(bundle) else { return nil }
            self = .app(bundle)
            return
        }
        guard let p = Self.fixed.first(where: { $0.id == id }) else { return nil }
        self = p
    }

    /// Checklist order: the feel, the buttons, app setups, then look and sound.
    var rank: Int {
        switch self {
        case .pointer: 0
        case .displays: 1
        case .scrolling: 2
        case .buttons: 3
        case .combos: 4
        case .gestures: 5
        case .app: 6
        case .look: 7
        case .sounds: 8
        }
    }

    static func < (a: SharePart, b: SharePart) -> Bool { a.rank < b.rank }

    var bundleID: String? { if case .app(let id) = self { id } else { nil } }
}

/// A ball color: one of Glideball's own (by id), or "custom" with three hex colors.
struct ShareLook: Codable, Equatable {
    static let themeIDs = ["orb", "ember", "sunset", "ocean", "forest", "graphite", "classic", "custom"]
    var theme: String
    var custom: [String]?

    /// Known theme, and for "custom" exactly three six-digit hex colors.
    var sanitized: ShareLook? {
        guard Self.themeIDs.contains(theme) else { return nil }
        guard theme == "custom" else { return ShareLook(theme: theme, custom: nil) }
        let colors = (custom ?? []).filter { s in
            s.count == 6 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
        }.map { $0.uppercased() }
        guard colors.count == 3 else { return nil }
        return ShareLook(theme: theme, custom: colors)
    }
}

/// The Sounds settings (Settings › Sound): the one switch, the volume and each kind's switch.
struct ShareSounds: Codable, Equatable {
    /// SoundKind's raw values (Sounds.swift), the only keys read.
    static let kindIDs = ["pauseResume", "modes", "ticks", "milestones", "buttons"]
    var on: Bool
    var volume: Double
    var kinds: [String: Bool]

    var sanitized: ShareSounds {
        ShareSounds(on: on, volume: volume.clamped(to: 0...1, or: 1),
                    kinds: kinds.filter { Self.kindIDs.contains($0.key) })
    }

    init(on: Bool, volume: Double, kinds: [String: Bool]) {
        self.on = on
        self.volume = volume
        self.kinds = kinds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decode(Bool.self, forKey: .on)
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
        kinds = ((try? c.decodeIfPresent([String: Bool].self, forKey: .kinds)) ?? nil) ?? [:]
    }
}

struct SharedSetup {
    static let formatMarker = "glideball-share"
    /// The page that shows a share and offers Import to Glideball.
    static let webPrefix = "https://glideball.netlify.app/s/#"
    static let appPrefix = "glideball://import?d="
    /// Links longer than this are file only (some apps cut longer links short).
    static let maxLinkLength = 2_000
    /// What a receiver accepts in `d` (a little over what a sender makes).
    static let maxPayloadLength = 2_048
    /// The most JSON a link's payload may inflate to (output that fills it is refused).
    static let maxInflatedBytes = 64 * 1024
    /// The sender's name: at most this many characters.
    static let maxFromLength = 40

    var format = SharedSetup.formatMarker
    var version: Int
    /// What's in it, in checklist order.
    var parts: [SharePart]
    /// What a beta 12 share said it was (nil for a checklist share).
    var legacyKind: ShareKind?
    /// The sender's name, as they typed it (never checked). Only when they chose to send it.
    var from: String?
    /// The Glideball that wrote it. No Mac name: shares go to other people.
    var writtenBy: String?

    // pointer
    var trackingSpeed: Double?
    var precisionSpeed: Double?
    // displays
    var displaySpeeds: DisplaySpeeds?
    // scrolling
    var scroll: ScrollSettings?
    var ballScrollSpeed: Double?
    // buttons (entries that aren't gestures) and gestures (entries that are)
    var buttons: [Int: ButtonAction]?
    // combos
    var chords: [Chord]?
    // gestures
    var gesturesEnabled: Bool?
    var gestureDistance: GestureDistance?
    var gestureSteadyHands: Bool?
    // app:<id>
    var apps: [AppProfile]?
    // look
    var look: ShareLook?
    // sounds
    var sounds: ShareSounds?

    enum Problem: Error, Equatable {
        case tooBig, notBase64, notDeflate, tooDeep, notJSON, notAShare, unsupportedVersion, missingPart
    }

    init(version: Int, parts: [SharePart]) {
        self.version = version
        self.parts = parts
    }

    /// What the share is, for the preview's title and symbol: what a beta 12 share
    /// said, the one part a checklist share holds, or "everything" for several.
    var kind: ShareKind {
        if let legacyKind { return legacyKind }
        guard parts.count == 1 else {
            // Only app setups: still "an app setup" when there's one.
            return .everything
        }
        switch parts[0] {
        case .pointer, .displays: return .pointer
        case .scrolling: return .scrolling
        case .buttons, .combos, .gestures: return .buttons
        case .look, .sounds: return .look
        case .app: return .appSetup
        }
    }

    // MARK: Making one

    /// A share of `parts` from these settings, ball color and sounds. Parts with
    /// nothing in them (no per-display speeds, an app setup that's gone) are left
    /// out; nil if nothing is left.
    static func make(_ parts: [SharePart], from config: GlideConfig, look: ShareLook?, sounds: ShareSounds?,
                     name: String? = nil, writtenBy: String? = nil) -> SharedSetup? {
        var s = SharedSetup(version: 1, parts: [])
        s.writtenBy = writtenBy
        s.from = name.map { ImportText.clean($0, max: maxFromLength) }.flatMap { $0.isEmpty ? nil : $0 }
        var kept: [SharePart] = []
        var map: [Int: ButtonAction] = [:]
        var unique: [SharePart] = []
        for p in parts where !unique.contains(p) { unique.append(p) }
        // Checklist order; app setups in the order given.
        let ordered = unique.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
        for part in ordered {
            switch part {
            case .pointer:
                s.trackingSpeed = config.trackingSpeed
                s.precisionSpeed = config.precisionSpeed
            case .displays:
                guard !config.displaySpeeds.speeds.isEmpty else { continue }
                s.displaySpeeds = config.displaySpeeds
            case .scrolling:
                s.scroll = config.scrollSettings
                s.ballScrollSpeed = config.ballScrollSpeed
            case .buttons:
                // Every button 1–7 that isn't a gesture, Default spelled out, so the
                // receiver's own are replaced (a gesture button is the Gestures part's).
                for b in ImportLimits.buttons {
                    let a = config.buttons[b] ?? .system
                    if !a.isGesture { map[b] = a }
                }
            case .combos:
                s.chords = config.chords
            case .gestures:
                for b in ImportLimits.buttons {
                    if let a = config.buttons[b], a.isGesture { map[b] = a }
                }
                s.gesturesEnabled = config.gesturesEnabled
                s.gestureDistance = config.gestureDistance
                s.gestureSteadyHands = config.gestureSteadyHands
            case .app(let id):
                guard let p = config.profile(for: id) else { continue }
                s.apps = (s.apps ?? []) + [p]
            case .look:
                guard let look else { continue }
                s.look = look
            case .sounds:
                guard let sounds else { continue }
                s.sounds = sounds
            }
            kept.append(part)
        }
        guard !kept.isEmpty else { return nil }
        if !map.isEmpty { s.buttons = map }
        s.parts = kept
        s.version = s.requiredVersion
        return s
    }

    /// Share… from a page's menu: that page's part (or one app setup, or everything).
    static func make(_ kind: ShareKind, from config: GlideConfig, look: ShareLook?, appSetup bundleID: String? = nil,
                     sounds: ShareSounds? = nil, name: String? = nil, writtenBy: String? = nil) -> SharedSetup? {
        make(kind.parts(in: config, appSetup: bundleID), from: config, look: look, sounds: sounds, name: name, writtenBy: writtenBy)
    }

    /// 2 when what's inside uses something a Glideball before 2.10 would drop (the
    /// settings file's own rule, `GlideConfig.requiredFileVersion`); otherwise 1.
    var requiredVersion: Int {
        var probe = GlideConfig()
        probe.buttons.merge(buttons ?? [:]) { $1 }
        probe.chords += chords ?? []
        probe.appProfiles += apps ?? []
        if let displaySpeeds { probe.displaySpeeds = displaySpeeds }
        return probe.requiredFileVersion
    }

    // MARK: File and link

    func fileData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// The payload: base64url of the raw-deflated, compact JSON.
    var payload: String? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let json = try? e.encode(self), let packed = Self.deflate(json) else { return nil }
        return Self.base64url(packed)
    }

    /// How long the website link would be (it's offered only up to `maxLinkLength`).
    var linkLength: Int { Self.webPrefix.count + (payload?.count ?? Int.max / 2) }

    /// https://glideball.netlify.app/s/#…, or nil when it would be longer than `maxLinkLength`.
    func link() -> URL? {
        guard let d = payload, Self.webPrefix.count + d.count <= Self.maxLinkLength else { return nil }
        return URL(string: Self.webPrefix + d)
    }

    /// glideball://import?d=…, the same payload (what the website's Import button opens).
    func appLink() -> URL? {
        guard let d = payload, Self.webPrefix.count + d.count <= Self.maxLinkLength else { return nil }
        return URL(string: Self.appPrefix + d)
    }

    /// Decodes a file's bytes. Throws for anything that isn't a share.
    static func decode(file data: Data) throws -> SharedSetup {
        guard data.count <= ImportLimits.maxFileBytes else { throw Problem.tooBig }
        return try decode(json: data)
    }

    /// Decodes a link's `d` value.
    static func decode(linkPayload d: String) throws -> SharedSetup {
        guard d.utf8.count <= maxPayloadLength else { throw Problem.tooBig }
        guard let packed = unbase64url(d) else { throw Problem.notBase64 }
        guard let json = inflate(packed, limit: maxInflatedBytes) else { throw Problem.notDeflate }
        return try decode(json: json)
    }

    static func decode(json: Data) throws -> SharedSetup {
        guard ImportJSON.depthIsWithin(json) else { throw Problem.tooDeep }
        let share: SharedSetup
        do {
            share = try JSONDecoder().decode(SharedSetup.self, from: json)
        } catch let p as Problem {
            throw p
        } catch {
            throw Problem.notJSON
        }
        guard share.format == formatMarker else { throw Problem.notAShare }
        guard (1...GlideSettingsFile.currentVersion).contains(share.version) else { throw Problem.unsupportedVersion }
        guard !share.parts.isEmpty else { throw Problem.missingPart }
        return share
    }

    // MARK: What it would do

    /// The settings `current` would become with `chosen` of this share's parts
    /// (nil: all of them): only those change, after the same clamping and checks
    /// as a settings file.
    func applied(to current: GlideConfig, parts chosen: Set<SharePart>? = nil) -> GlideConfig {
        let use = { (p: SharePart) in self.parts.contains(p) && (chosen?.contains(p) ?? true) }
        var c = current
        if use(.pointer) {
            if let v = trackingSpeed { c.trackingSpeed = v.clamped(to: SettingRanges.trackingSpeed, or: current.trackingSpeed) }
            if let v = precisionSpeed { c.precisionSpeed = v.clamped(to: SettingRanges.precisionSpeed, or: current.precisionSpeed) }
        }
        if use(.displays), let ds = displaySpeeds {
            var probe = GlideConfig()
            probe.displaySpeeds = ds
            c.displaySpeeds = probe.sanitizedForImport().displaySpeeds
        }
        if use(.scrolling) {
            if let s = scroll { c.scrollSettings = ImportSanitize.scroll(s) }
            if let v = ballScrollSpeed { c.ballScrollSpeed = v.clamped(to: SettingRanges.ballScrollSpeed, or: current.ballScrollSpeed) }
        }
        // Each button the share sets, for the part it belongs to. One that can't be made
        // safe (a shortcut with a key code that doesn't exist) becomes Default: the sender
        // changed that button, and Default is the one safe thing to change it to.
        for (b, raw) in buttons ?? [:] where ImportLimits.buttons.contains(b) && use(raw.isGesture ? .gestures : .buttons) {
            let a = raw.sanitized() ?? .system
            c.buttons[b] = a == .system ? nil : a
        }
        if use(.gestures) {
            if let g = gesturesEnabled { c.gesturesEnabled = g }
            if let d = gestureDistance { c.gestureDistance = d }
            if let s = gestureSteadyHands { c.gestureSteadyHands = s }
        }
        if use(.combos), let ch = chords { c.chords = ImportSanitize.chords(ch) }
        for p in apps ?? [] where use(.app(p.bundleID)) {
            guard let safe = ImportSanitize.appSetup(p) else { continue }
            if let i = c.appProfiles.firstIndex(where: { $0.bundleID == safe.bundleID }) {
                c.appProfiles[i] = safe
            } else if c.appProfiles.count < ImportLimits.maxAppSetups {
                c.appProfiles.append(safe)
            }
        }
        c = c.clamped()   // the same limits as every settings file (ConfigLimits)
        c.buttons[0] = current.buttons[0]   // the primary button never changes
        c.enabled = current.enabled         // nor does the pause switch
        c.globalShortcuts = current.globalShortcuts
        return c
    }

    /// The ball color it brings, if that part is chosen (checked).
    func appliedLook(parts chosen: Set<SharePart>? = nil) -> ShareLook? {
        guard parts.contains(.look), chosen?.contains(.look) ?? true else { return nil }
        return look?.sanitized
    }

    var appliedLook: ShareLook? { appliedLook() }

    /// The sounds it brings, if that part is chosen (checked).
    func appliedSounds(parts chosen: Set<SharePart>? = nil) -> ShareSounds? {
        guard parts.contains(.sounds), chosen?.contains(.sounds) ?? true else { return nil }
        return sounds?.sanitized
    }

    /// An app setup it carries.
    func app(_ id: String) -> AppProfile? { apps?.first { $0.bundleID == id } }

    // MARK: base64url and deflate

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ s: String) -> Data? {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ u in
            u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "-" || u == "_")
        }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// Raw deflate (zlib's format without a header), as Compression's COMPRESSION_ZLIB writes it.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return out.prefix(n)
    }

    /// Inflates into a buffer of `limit` bytes; anything that would fill it is refused
    /// (it may have been cut off, and a real share is a few KB).
    static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: limit)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, limit,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < limit else { return nil }
        return out.prefix(n)
    }
}

extension ShareKind {
    /// The parts Share… starts with when it's opened from here.
    func parts(in config: GlideConfig, appSetup: String? = nil) -> [SharePart] {
        switch self {
        case .everything:
            [.pointer, .scrolling, .buttons, .combos, .gestures] + config.appProfiles.map { .app($0.bundleID) } + [.look, .sounds]
        case .appSetup: appSetup.map { [.app($0)] } ?? []
        case .pointer: [.pointer]
        case .scrolling: [.scrolling]
        case .buttons: [.buttons, .combos, .gestures]
        case .look: [.look]
        }
    }
}

// MARK: - JSON

extension SharedSetup: Codable {
    enum CodingKeys: String, CodingKey {
        case format, version, kind, parts, from, writtenBy
        case trackingSpeed, precisionSpeed, displaySpeeds, scroll, ballScrollSpeed
        case buttons, chords, gesturesEnabled, gestureDistance, gestureSteadyHands, apps, look, sounds
        // beta 12
        case name, config, appSetup
    }

    private struct ChordForm: Encodable {
        let buttons: [Int]
        let action: ButtonAction
    }

    /// An app setup as a share carries it: no chord ids (made fresh on import anyway).
    private struct AppForm: Encodable {
        let p: AppProfile
        private enum Keys: String, CodingKey { case bundleID, name, trackingSpeed, scroll, buttons, chords }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(p.bundleID, forKey: .bundleID)
            try c.encode(p.name, forKey: .name)
            try c.encodeIfPresent(p.trackingSpeed, forKey: .trackingSpeed)
            try c.encodeIfPresent(p.scroll, forKey: .scroll)
            try c.encodeIfPresent(p.buttons?.filter { $0.key != 0 }, forKey: .buttons)
            try c.encodeIfPresent(p.chords?.map { ChordForm(buttons: $0.buttons, action: $0.action) }, forKey: .chords)
        }
    }

    /// Always the checklist form (a beta 12 share read in is written out as its parts).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode("parts", forKey: .kind)
        try c.encode(parts.map(\.id), forKey: .parts)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(writtenBy, forKey: .writtenBy)
        try c.encodeIfPresent(trackingSpeed, forKey: .trackingSpeed)
        try c.encodeIfPresent(precisionSpeed, forKey: .precisionSpeed)
        try c.encodeIfPresent(displaySpeeds, forKey: .displaySpeeds)
        try c.encodeIfPresent(scroll, forKey: .scroll)
        try c.encodeIfPresent(ballScrollSpeed, forKey: .ballScrollSpeed)
        try c.encodeIfPresent(buttons?.filter { $0.key != 0 }, forKey: .buttons)
        try c.encodeIfPresent(chords?.map { ChordForm(buttons: $0.buttons, action: $0.action) }, forKey: .chords)
        try c.encodeIfPresent(gesturesEnabled, forKey: .gesturesEnabled)
        try c.encodeIfPresent(gestureDistance, forKey: .gestureDistance)
        try c.encodeIfPresent(gestureSteadyHands, forKey: .gestureSteadyHands)
        try c.encodeIfPresent(apps?.map { AppForm(p: $0) }, forKey: .apps)
        try c.encodeIfPresent(look, forKey: .look)
        try c.encodeIfPresent(sounds, forKey: .sounds)
    }

    // Unknown fields are ignored (Codable's way); a kind this version doesn't know is refused.
    // Each field is read leniently: one that can't be read counts as not given (as on the
    // website), and an unreadable button or combo is skipped. A part whose fields aren't
    // there is dropped; `decode(json:)` refuses a share with no parts left.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        let kindText = try c.decode(String.self, forKey: .kind)
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        writtenBy = opt(String.self, .writtenBy).map { ImportText.clean($0, max: 24) }.flatMap { $0.isEmpty ? nil : $0 }
        parts = []

        func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        trackingSpeed = finite(opt(Double.self, .trackingSpeed))
        precisionSpeed = finite(opt(Double.self, .precisionSpeed))
        displaySpeeds = opt(DisplaySpeeds.self, .displaySpeeds)
        scroll = opt(ScrollSettings.self, .scroll)
        ballScrollSpeed = finite(opt(Double.self, .ballScrollSpeed))
        buttons = ((try? c.decodeLenientActions(forKey: .buttons)) ?? nil)?.filter { ImportLimits.buttons.contains($0.key) }
        chords = (try? c.decodeLenientChords(forKey: .chords)) ?? nil
        gesturesEnabled = opt(Bool.self, .gesturesEnabled)
        gestureDistance = opt(GestureDistance.self, .gestureDistance)
        gestureSteadyHands = opt(Bool.self, .gestureSteadyHands)
        apps = opt([LenientApp].self, .apps)?.compactMap(\.app)
        look = opt(ShareLook.self, .look)?.sanitized
        sounds = opt(ShareSounds.self, .sounds)

        var wanted: [SharePart]
        if kindText == "parts" {
            guard let ids = opt([LenientString].self, .parts) else { throw Problem.notAShare }
            wanted = ids.compactMap(\.value).compactMap(SharePart.init(id:))
            from = opt(String.self, .from).map { ImportText.clean($0, max: Self.maxFromLength) }.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            guard let k = ShareKind(rawValue: kindText) else { throw Problem.notAShare }
            legacyKind = k
            wanted = try readLegacy(k, c)
        }

        // Each part needs its fields; repeats count once; checklist order.
        let plain = (buttons ?? [:]).filter { !$0.value.isGesture }
        let gestures = (buttons ?? [:]).filter { $0.value.isGesture }
        var kept: [SharePart] = []
        for p in wanted where !kept.contains(p) {
            let has: Bool = switch p {
            case .pointer: trackingSpeed != nil || precisionSpeed != nil
            case .displays: displaySpeeds != nil
            case .scrolling: scroll != nil || ballScrollSpeed != nil
            case .buttons: !plain.isEmpty
            case .combos: chords != nil
            case .gestures: !gestures.isEmpty || gesturesEnabled != nil || gestureDistance != nil || gestureSteadyHands != nil
            case .app(let id): apps?.contains { $0.bundleID == id && ImportText.isBundleID(id) } ?? false
            case .look: look != nil
            case .sounds: sounds != nil
            }
            if has { kept.append(p) }
        }
        // Checklist order; app setups keep the order they came in.
        parts = kept.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    /// Beta 12's kinds, read as checklist parts (docs/SHARE-FORMAT.md, "Beta 12 shares").
    private mutating func readLegacy(_ kind: ShareKind, _ c: KeyedDecodingContainer<CodingKeys>) throws -> [SharePart] {
        /// Buttons 1–7, a missing one as Default: beta 12 replaced the whole map.
        func filled(_ map: [Int: ButtonAction]?) -> [Int: ButtonAction] {
            var out: [Int: ButtonAction] = [:]
            for b in ImportLimits.buttons { out[b] = map?[b] ?? .system }
            return out
        }
        switch kind {
        case .pointer: return [.pointer]
        case .scrolling: return [.scrolling]
        case .look: return [.look]
        case .buttons:
            var out: [SharePart] = []
            if buttons != nil {
                buttons = filled(buttons)
                out += [.buttons, .gestures]
            } else if gesturesEnabled != nil {
                out.append(.gestures)
            }
            if chords != nil { out.append(.combos) }
            return out
        case .appSetup:
            guard let p = (try? c.decodeIfPresent(AppProfile.self, forKey: .appSetup)) ?? nil, ImportText.isBundleID(p.bundleID) else { return [] }
            apps = [p]
            return [.app(p.bundleID)]
        case .everything:
            guard let config = try? c.decode(GlideConfig.self, forKey: .config) else { return [] }
            trackingSpeed = config.trackingSpeed
            precisionSpeed = config.precisionSpeed
            scroll = config.scrollSettings
            ballScrollSpeed = config.ballScrollSpeed
            buttons = filled(config.buttons.filter { ImportLimits.buttons.contains($0.key) })
            chords = config.chords
            gesturesEnabled = config.gesturesEnabled
            gestureDistance = config.gestureDistance
            gestureSteadyHands = config.gestureSteadyHands
            displaySpeeds = nil   // never the per-display speeds it also carried
            sounds = nil
            var seen = Set<String>()
            apps = config.appProfiles.filter { ImportText.isBundleID($0.bundleID) && seen.insert($0.bundleID).inserted }
            return [.pointer, .scrolling, .buttons, .combos, .gestures] + (apps ?? []).map { .app($0.bundleID) } + (look != nil ? [.look] : [])
        }
    }
}

/// An app setup that can't be read is skipped, not the whole share.
private struct LenientApp: Decodable {
    let app: AppProfile?
    init(from decoder: Decoder) { app = try? AppProfile(from: decoder) }
}

private struct LenientString: Decodable {
    let value: String?
    init(from decoder: Decoder) { value = try? String(from: decoder) }
}

// MARK: - A file chosen or double-clicked to import

/// What a .glide-settings file chosen to import (Import…, a double-click, a shared
/// file) turned out to be. Both kinds are read the same hardened way: only a
/// regular file (a link someone chose is followed; a pipe or device never is),
/// never over `ImportLimits.maxFileBytes`, depth-checked, and a settings file's
/// config clamped and checked (`sanitizedForImport()`) before it's shown, so the
/// preview is what Apply would do. scripts/file-fuzz and scripts/import-sim throw
/// hostile files at it.
enum ImportFile {
    case share(SharedSetup)
    case settings(GlideSettingsFile)

    static func read(_ url: URL) throws -> ImportFile {
        try parse(SafeRead.data(url, limit: ImportLimits.maxFileBytes, followSymlinks: true))
    }

    static func parse(_ data: Data) throws -> ImportFile {
        guard data.count <= ImportLimits.maxFileBytes else { throw SharedSetup.Problem.tooBig }
        guard ImportJSON.depthIsWithin(data) else { throw SharedSetup.Problem.tooDeep }
        // A shared setup (one part, or everything from someone else) gets the share preview.
        if let share = try? SharedSetup.decode(file: data) { return .share(share) }
        var file = try GlideSettingsFile.decode(data)
        _ = try file.validatedConfig()
        file.config = file.config.sanitizedForImport()
        file.exportedFrom = file.exportedFrom.map { ImportText.clean($0) }
        return .settings(file)
    }
}
