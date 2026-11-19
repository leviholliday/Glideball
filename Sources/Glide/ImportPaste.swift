import Foundation

// Pasting a shared setup into Glideball: the paste box (Paste a Link…), ⌘V on
// the main window, File › Import Setup from Clipboard. Whatever was pasted is
// only ever turned into a `SharedSetup` by the decoder glideball://import uses
// (`SharedSetup.decode(linkPayload:)`, or `ExternalControl.parseImport` itself
// for a pasted glideball:// link), then handed to `AppModel.receiveShare`: the
// same preview, clamping, backup checkpoint and Undo as a link. Nothing here
// changes a setting, opens anything or reaches the network.
//
// The rule (docs/SHARE-FORMAT.md, "Pasting a link"):
//  - At most 16,384 bytes of text; more is refused whole, unread.
//  - Invisible format characters (Unicode Cf, which chat apps put inside long
//    links to let them wrap) are removed. Nothing else is normalized: no case
//    folding beyond ASCII, no NFKC, so a fullwidth or Cyrillic look-alike stays
//    what it is and never matches.
//  - The text is cut into words at whitespace and at characters a link can't
//    hold here: " ' ` < > ( ) [ ] { } | * and curly quotes and « », then . , ; : ! ? are taken off a
//    word's end. So a link inside a message, quotes, Markdown or <angle
//    brackets> is found.
//  - A word is a link Glideball takes only when it is exactly one of:
//      https://glideball.netlify.app/s/#<d>   (scheme and host in any ASCII case,
//                                              then exactly "/s/#"; nothing else
//                                              before the #: no port, user, query,
//                                              other path, or trailing dot)
//      glideball://import?d=<d>               (read by ExternalControl.parseImport,
//                                              exactly as the URL handler reads it)
//    Any other link is refused, even when what follows its # would decode:
//    http://, glideball.netlify.app.evil.com, evil.com/glideball.netlify.app/s/#,
//    glideball.netlify.app@evil.com, :443, xn-- look-alikes. A glideball:// link
//    that isn't import (glideball://pause) is refused too: pasting never runs a
//    command.
//  - Without a link, the whole text (trimmed) may be a bare payload: only
//    A–Z a–z 0–9 - _, 24 to 2,048 characters.
//  - Two different setups in one paste are refused (the same one twice, or its
//    web and app links side by side, is one).
//
// Foundation only, so scripts/import-sim can throw hostile text at it.
//
// Set up with AI (SetupCode.swift) plugs in here: `read(_:codes:codeFirst:)` also
// takes a setup code, the plain JSON a chatbot writes. The links above are still
// found by exactly the rules above; the JSON goes to `SetupCode.read`, which turns
// it into an ordinary `SharedSetup` (and its "Left out" notes) through the share
// decoder. A link that isn't one of the two above never becomes a code's way in:
// the code is read from its JSON or not at all.

enum ImportPaste {
    /// More than this is refused without being read.
    static let maxTextBytes = 16_384
    /// A bare payload is at least this long (a real one is over 80): shorter is just a word.
    static let minBarePayload = 24
    static let webPrefix = "https://glideball.netlify.app/s/#"
    static let appScheme = "glideball://"

    /// How the setup arrived in the text.
    enum Carrier: Equatable {
        case web, app, bare
        /// A share's own JSON (a .glide-settings file's text), pasted.
        case json
    }

    /// Why a paste was refused (shown in the box, or a toast).
    enum Refusal: String, Error, Equatable {
        case tooLong = "too long"
        case noLink = "no link"
        case notGlideball = "not a Glideball share link"
        case notAShare = "a glideball:// link that isn't a shared setup"
        case severalLinks = "more than one setup"
        case damaged = "damaged or cut off"
        case newerVersion = "from a newer Glideball"
    }

    enum Reading {
        /// Nothing pasted yet (only whitespace).
        case empty
        case share(SharedSetup, Carrier)
        case refused(Refusal)
        /// A setup code (Set up with AI): the share it means, and what was left out of it.
        case code(SetupCode.Reading)
        /// Text read as a setup code that can't be used, and why.
        case codeRefused(SetupCode.Problem)

        var share: SharedSetup? {
            switch self {
            case .share(let s, _): s
            case .code(let r): r.share
            default: nil
            }
        }

        var refusal: Refusal? {
            if case .refused(let r) = self { return r }
            return nil
        }
    }

    /// The same, for a box that also takes a setup code (`codes`: what a code is read
    /// against). A Glideball link in the text is read first, by the rules above, unless
    /// the text is marked as a setup code. Text with a `{` in it is read as a code. Text
    /// with neither: with `codeFirst` (Set up with AI's box) it's "not a setup code";
    /// otherwise (Paste a Link…) whatever the link rules say.
    static func read(_ text: String, codes: SetupCode.Context?, codeFirst: Bool = false) -> Reading {
        guard let codes else { return read(text) }
        let link = read(text)
        if case .empty = link { return .empty }
        let marked = text.utf8.count <= SetupCode.maxPasteBytes && text.contains(SetupCode.formatMarker)
        if case .share = link, !marked { return link }
        let brace = text.utf8.count <= SetupCode.maxPasteBytes && text.unicodeScalars.contains("{")
        // A link Glideball won't open says so, unless there's JSON to read instead.
        let quietLink = link.refusal == .noLink || link.refusal == .tooLong
        guard brace || (codeFirst && quietLink) else { return link }
        switch SetupCode.read(text, codes) {
        case .success(.code(let r)): return .code(r)
        case .success(.share(let s)): return .share(s, .json)
        case .failure(let p):
            if (p == .notJSON || p == .notASetup), !quietLink { return link }
            if !codeFirst, !marked, p == .notJSON || p == .notASetup, quietLink { return link }
            return .codeRefused(p)
        }
    }

    static func read(_ text: String) -> Reading {
        guard text.utf8.count <= maxTextBytes else { return .refused(.tooLong) }
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Each word that is one of Glideball's links, as the payload it carries.
        // (A glideball:// link parseImport refused is kept as `failed`: it can only ever be refused.)
        var found: [(d: String?, carrier: Carrier, share: SharedSetup?, failed: Bool)] = []
        var refusedApp = false, linkLike = false
        for word in words(trimmed) {
            if let d = webPayload(word) {
                found.append((d, .web, nil, false))
            } else if hasPrefix(word, appScheme) {
                guard let url = URL(string: word), let result = ExternalControl.parseImport(url) else {
                    refusedApp = true   // glideball://pause and friends: never a command from a paste
                    continue
                }
                switch result {
                case .success(let share): found.append((appPayload(word), .app, share, false))
                case .failure: found.append((appPayload(word), .app, nil, true))
                }
            } else if looksLikeALink(word) {
                linkLike = true
            }
        }

        if found.isEmpty {
            if refusedApp { return .refused(.notAShare) }
            if linkLike { return .refused(.notGlideball) }
            guard isBarePayload(trimmed) else { return .refused(.noLink) }
            return decode(trimmed, .bare)
        }
        // One setup, maybe written twice (a message with the page's link and the app's).
        let payloads = Set(found.map { $0.d ?? "" })
        guard payloads.count == 1, let first = found.first else { return .refused(.severalLinks) }
        if let bad = found.first(where: \.failed) {
            // Refused by the URL handler's own rules, so the paste is too; the decoder
            // only picks the words for why.
            let why = bad.d.flatMap { decode($0, .app).refusal }
            return .refused(why == .newerVersion ? .newerVersion : .damaged)
        }
        if let share = first.share { return .share(share, .app) }
        guard let d = first.d else { return .refused(.damaged) }
        return decode(d, first.carrier)
    }

    // MARK: Pieces

    private static func decode(_ d: String, _ carrier: Carrier) -> Reading {
        guard !d.isEmpty, d.unicodeScalars.allSatisfy(isPayloadScalar) else { return .refused(.damaged) }
        do {
            return .share(try SharedSetup.decode(linkPayload: d), carrier)
        } catch SharedSetup.Problem.unsupportedVersion {
            return .refused(.newerVersion)
        } catch {
            return .refused(.damaged)
        }
    }

    /// The words of the text, as a link would be cut out of a message.
    static func words(_ text: String) -> [String] {
        let breaks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>()[]{}|*“”‘’«»"))
        let tail = CharacterSet(charactersIn: ".,;:!?")
        return text.unicodeScalars.split { breaks.contains($0) }.compactMap { piece in
            var scalars = Array(piece)
            while let last = scalars.last, tail.contains(last) { scalars.removeLast() }
            return scalars.isEmpty ? nil : String(String.UnicodeScalarView(scalars))
        }
    }

    /// `d` from https://glideball.netlify.app/s/#<d>, when the word starts exactly so.
    /// What follows the # is returned whatever it is (a bad one is "damaged", not "not ours").
    static func webPayload(_ word: String) -> String? {
        let head = "https://glideball.netlify.app"
        guard hasPrefix(word, head) else { return nil }
        let rest = word.unicodeScalars.dropFirst(head.unicodeScalars.count)
        guard rest.starts(with: "/s/#".unicodeScalars) else { return nil }   // path is case-sensitive
        return String(String.UnicodeScalarView(rest.dropFirst(4)))
    }

    /// The `d` text of a glideball://import link already read by parseImport (to tell two setups apart).
    private static func appPayload(_ word: String) -> String? {
        URLComponents(string: word)?.queryItems?.first { $0.name == "d" }?.value
    }

    /// ASCII-only, case-insensitive prefix: "İ".lowercased() never sneaks in an "i".
    static func hasPrefix(_ word: String, _ prefix: String) -> Bool {
        let w = Array(word.utf8), p = Array(prefix.utf8)
        guard w.count >= p.count else { return false }
        for (a, b) in zip(w, p) {
            guard a < 0x80, asciiLower(a) == b else { return false }
        }
        return true
    }

    private static func asciiLower(_ c: UInt8) -> UInt8 { (0x41...0x5A).contains(c) ? c + 0x20 : c }

    /// Anything that's a link of some kind, or names Glideball: it gets "not a Glideball
    /// share link", not "no link".
    private static func looksLikeALink(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.contains("://") || lower.hasPrefix("www.") || lower.contains("glideball") || lower.contains("netlify")
            || lower.contains("/s/#")
    }

    private static func isBarePayload(_ text: String) -> Bool {
        (minBarePayload...SharedSetup.maxPayloadLength).contains(text.utf8.count) && text.unicodeScalars.allSatisfy(isPayloadScalar)
    }

    private static func isPayloadScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: true
        default: false
        }
    }
}
