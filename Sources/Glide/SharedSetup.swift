import Compression
import Foundation

// Sharing a setup with someone else: everything, one app setup, or one part
// (pointer feel, scroll feel, buttons and gestures, ball color and look).
//
// Two carriers, the same JSON inside:
//  - a file: the usual .glide-settings type, with a `format` and `kind` and
//    only the chosen parts ("everything" also carries `config`, so an older
//    Glideball can still import it as a plain settings file);
//  - a link: glideball://import?d=<base64url of raw-deflated JSON>, when the
//    whole URL fits in 2,000 characters (otherwise it's file only).
//
// Receiving is the dangerous side: any web page can open a glideball:// link.
// So nothing here changes anything. A share is decoded (size-capped, depth-
// checked, strictly validated), turned into the settings it would give
// (`applied(to:)`, through the same `sanitizedForImport()` as file import) and
// shown as a preview; only Apply in Glideball's own window changes something.
// The primary button never changes, and "everything" from someone else keeps
// this Mac's own global shortcuts, per-display speeds and pause switch.
//
// Foundation only, so the simulators can check it.

enum ShareKind: String, Codable, CaseIterable, Identifiable {
    case everything
    case appSetup = "app-setup"
    case pointer
    case scrolling
    case buttons
    case look
    var id: String { rawValue }
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
        let colors = (custom ?? []).filter { $0.count == 6 && UInt32($0, radix: 16) != nil }.map { $0.uppercased() }
        guard colors.count == 3 else { return nil }
        return ShareLook(theme: theme, custom: colors)
    }
}

struct SharedSetup: Codable {
    static let formatMarker = "glideball-share"
    /// Links longer than this are file only (some apps cut longer links short).
    static let maxLinkLength = 2_000
    /// What a receiver accepts in `d` (a little over what a sender makes).
    static let maxPayloadLength = 2_048
    /// The most JSON a link's payload may inflate to.
    static let maxInflatedBytes = 64 * 1024

    var format = SharedSetup.formatMarker
    var version: Int
    var kind: ShareKind
    /// The app setup's name, or nothing.
    var name: String?
    /// everything
    var config: GlideConfig?
    /// pointer
    var trackingSpeed: Double?
    var precisionSpeed: Double?
    /// scrolling
    var scroll: ScrollSettings?
    var ballScrollSpeed: Double?
    /// buttons
    var buttons: [Int: ButtonAction]?
    var chords: [Chord]?
    var gesturesEnabled: Bool?
    /// app-setup
    var appSetup: AppProfile?
    /// look (and everything)
    var look: ShareLook?
    /// The Glideball that wrote it. No Mac name: shares go to other people.
    var writtenBy: String?

    enum Problem: Error, Equatable {
        case tooBig, notBase64, notDeflate, tooDeep, notJSON, notAShare, unsupportedVersion, missingPart
    }

    // MARK: Making one

    /// A share of `kind` from these settings and look. `appSetup` picks the app setup for `.appSetup`.
    static func make(_ kind: ShareKind, from config: GlideConfig, look: ShareLook?, appSetup bundleID: String? = nil,
                     writtenBy: String? = nil) -> SharedSetup? {
        var s = SharedSetup(version: 1, kind: kind)
        s.writtenBy = writtenBy
        switch kind {
        case .everything:
            var c = config
            c.enabled = true
            c.displaySpeeds = DisplaySpeeds()   // someone else's displays mean nothing here
            s.config = c
            s.look = look
        case .appSetup:
            guard let p = config.profile(for: bundleID) else { return nil }
            s.appSetup = p
            s.name = p.name
        case .pointer:
            s.trackingSpeed = config.trackingSpeed
            s.precisionSpeed = config.precisionSpeed
        case .scrolling:
            s.scroll = config.scrollSettings
            s.ballScrollSpeed = config.ballScrollSpeed
        case .buttons:
            s.buttons = config.buttons.filter { $0.key != 0 }
            s.chords = config.chords
            s.gesturesEnabled = config.gesturesEnabled
        case .look:
            guard let look else { return nil }
            s.look = look
        }
        s.version = s.requiredVersion
        return s
    }

    init(version: Int, kind: ShareKind) {
        self.version = version
        self.kind = kind
    }

    /// 2 when what's inside uses something a Glideball before 2.10 would drop (the
    /// settings file's own rule, `GlideConfig.requiredFileVersion`); otherwise 1.
    var requiredVersion: Int {
        var probe = GlideConfig()
        if let config { probe = config }
        probe.buttons.merge(buttons ?? [:]) { $1 }
        probe.chords += chords ?? []
        if let appSetup { probe.appProfiles.append(appSetup) }
        return probe.requiredFileVersion
    }

    // MARK: File and link

    func fileData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// glideball://import?d=…, or nil when it would be longer than `maxLinkLength`.
    func link() -> URL? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // Chord ids are made fresh on import anyway; leave them out of the link.
        guard let json = try? e.encode(LinkForm(self)), let packed = Self.deflate(json) else { return nil }
        let text = "glideball://import?d=" + Self.base64url(packed)
        guard text.count <= Self.maxLinkLength else { return nil }
        return URL(string: text)
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
        guard share.hasItsPart else { throw Problem.missingPart }
        return share
    }

    /// The part its kind promises is there.
    private var hasItsPart: Bool {
        switch kind {
        case .everything: config != nil
        case .appSetup: appSetup.map { ImportText.isBundleID($0.bundleID) } ?? false
        case .pointer: trackingSpeed != nil || precisionSpeed != nil
        case .scrolling: scroll != nil
        case .buttons: buttons != nil || chords != nil
        case .look: look?.sanitized != nil
        }
    }

    // MARK: What it would do

    /// The settings `current` would become: only this share's part changes, after
    /// the same clamping and checks as a settings file.
    func applied(to current: GlideConfig) -> GlideConfig {
        var c = current
        switch kind {
        case .everything:
            guard let config else { return current }
            c = config.sanitizedForImport()
            c.enabled = current.enabled                  // the pause switch belongs to this Mac
            c.globalShortcuts = current.globalShortcuts  // so do its keyboard shortcuts…
            c.displaySpeeds = current.displaySpeeds      // …and its displays
        case .appSetup:
            guard let p = appSetup.flatMap(ImportSanitize.appSetup) else { return current }
            if let i = c.appProfiles.firstIndex(where: { $0.bundleID == p.bundleID }) {
                c.appProfiles[i] = p
            } else if c.appProfiles.count < ImportLimits.maxAppSetups {
                c.appProfiles.append(p)
            }
        case .pointer:
            if let v = trackingSpeed { c.trackingSpeed = v.clamped(to: SettingRanges.trackingSpeed, or: current.trackingSpeed) }
            if let v = precisionSpeed { c.precisionSpeed = v.clamped(to: SettingRanges.precisionSpeed, or: current.precisionSpeed) }
        case .scrolling:
            if let s = scroll { c.scrollSettings = ImportSanitize.scroll(s) }
            if let v = ballScrollSpeed { c.ballScrollSpeed = v.clamped(to: SettingRanges.ballScrollSpeed, or: current.ballScrollSpeed) }
        case .buttons:
            if let b = buttons { c.buttons = ImportSanitize.buttons(b) }
            if let ch = chords { c.chords = ImportSanitize.chords(ch) }
            if let g = gesturesEnabled { c.gesturesEnabled = g }
        case .look:
            break
        }
        c = c.clamped()   // the same limits as every settings file (ConfigLimits)
        c.buttons[0] = current.buttons[0]   // the primary button never changes
        return c
    }

    /// The ball color it brings, if any (checked).
    var appliedLook: ShareLook? { look?.sanitized }

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

/// A share as a link carries it: chords without their ids (each is 36 characters).
private struct LinkForm: Encodable {
    let share: SharedSetup
    init(_ s: SharedSetup) { share = s }

    private struct ChordForm: Encodable {
        let buttons: [Int]
        let action: ButtonAction
    }

    private struct ProfileForm: Encodable {
        let p: AppProfile
        private enum Keys: String, CodingKey { case bundleID, name, trackingSpeed, scroll, buttons, chords }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(p.bundleID, forKey: .bundleID)
            try c.encode(p.name, forKey: .name)
            try c.encodeIfPresent(p.trackingSpeed, forKey: .trackingSpeed)
            try c.encodeIfPresent(p.scroll, forKey: .scroll)
            try c.encodeIfPresent(p.buttons, forKey: .buttons)
            try c.encodeIfPresent(p.chords?.map { ChordForm(buttons: $0.buttons, action: $0.action) }, forKey: .chords)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SharedSetup.CodingKeys.self)
        let s = share
        try c.encode(s.format, forKey: .format)
        try c.encode(s.version, forKey: .version)
        try c.encode(s.kind, forKey: .kind)
        try c.encodeIfPresent(s.name, forKey: .name)
        try c.encodeIfPresent(s.config, forKey: .config)
        try c.encodeIfPresent(s.trackingSpeed, forKey: .trackingSpeed)
        try c.encodeIfPresent(s.precisionSpeed, forKey: .precisionSpeed)
        try c.encodeIfPresent(s.scroll, forKey: .scroll)
        try c.encodeIfPresent(s.ballScrollSpeed, forKey: .ballScrollSpeed)
        try c.encodeIfPresent(s.buttons, forKey: .buttons)
        try c.encodeIfPresent(s.chords?.map { ChordForm(buttons: $0.buttons, action: $0.action) }, forKey: .chords)
        try c.encodeIfPresent(s.gesturesEnabled, forKey: .gesturesEnabled)
        try c.encodeIfPresent(s.appSetup.map { ProfileForm(p: $0) }, forKey: .appSetup)
        try c.encodeIfPresent(s.look, forKey: .look)
        try c.encodeIfPresent(s.writtenBy, forKey: .writtenBy)
    }
}

extension SharedSetup {
    enum CodingKeys: String, CodingKey {
        case format, version, kind, name, config, trackingSpeed, precisionSpeed, scroll, ballScrollSpeed
        case buttons, chords, gesturesEnabled, appSetup, look, writtenBy
    }

    // Unknown fields are ignored (Codable's way); a kind this version doesn't know is refused.
    // Parts are read leniently like settings files: an unreadable button or combo is skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        guard let k = ShareKind(rawValue: try c.decode(String.self, forKey: .kind)) else { throw Problem.notAShare }
        kind = k
        name = try c.decodeIfPresent(String.self, forKey: .name).map { ImportText.clean($0) }
        config = try c.decodeIfPresent(GlideConfig.self, forKey: .config)
        trackingSpeed = try c.decodeIfPresent(Double.self, forKey: .trackingSpeed)
        precisionSpeed = try c.decodeIfPresent(Double.self, forKey: .precisionSpeed)
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll)
        ballScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .ballScrollSpeed)
        buttons = try c.decodeLenientActions(forKey: .buttons)
        chords = try c.decodeLenientChords(forKey: .chords)
        gesturesEnabled = try c.decodeIfPresent(Bool.self, forKey: .gesturesEnabled)
        appSetup = try c.decodeIfPresent(AppProfile.self, forKey: .appSetup)
        look = try c.decodeIfPresent(ShareLook.self, forKey: .look)
        writtenBy = try c.decodeIfPresent(String.self, forKey: .writtenBy).map { ImportText.clean($0, max: 24) }
    }
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
