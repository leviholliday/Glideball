import Foundation

/// Sends feedback to glide-trackball.netlify.app's /api/feedback (the same
/// protocol as CedarLogic's): the report as JSON first, then each attachment
/// in pieces, then "that's all" — which is when the developer hears of it.
///
///   POST /api/feedback                              report → {id, uploadToken, chunkSize}
///   PUT  /api/feedback/upload?id&file&index&total   one piece of one attachment
///   POST /api/feedback/complete?id                  every piece is in (only with attachments)
///
/// Foundation only, so it can be compiled on its own against a mock server.
struct FeedbackClient {
    static let productionServer = URL(string: "https://glide-trackball.netlify.app")!
    /// Not a secret (it ships in the app); it keeps out what just wanders by.
    static let appKey = "TKsnHSb_TNX9SlHJtd9s59z3"
    /// Development: `defaults write com.leviholliday.glide GlideFeedbackServer http://127.0.0.1:8765`
    /// points the app at a local server. Unset, it's the production site.
    static let serverOverrideKey = "GlideFeedbackServer"

    static var server: URL {
        if let s = UserDefaults.standard.string(forKey: serverOverrideKey),
           let url = URL(string: s), url.scheme == "http" || url.scheme == "https", url.host != nil {
            return url
        }
        return productionServer
    }

    // MARK: What can be sent

    static let maxAttachments = 6
    /// Allowed types and the largest each may be, in bytes (the server's limits).
    static let sizeLimits: [String: Int] = [
        "image/png": 12_000_000,
        "image/jpeg": 12_000_000,
        "video/mp4": 60_000_000,
        "video/quicktime": 60_000_000,
        "text/plain": 5_000_000,
        "application/json": 2_000_000,
    ]

    static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "txt", "log": "text/plain"
        case "json": "application/json"
        default: nil
        }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$`, and never "..".
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$"#, options: .regularExpression) != nil && !name.contains("..")
    }

    /// A file name the server accepts, as close to the original as it can be:
    /// "Screenshot 2026-10-04 at 10.15.03 AM.png" → "Screenshot-2026-10-04-at-10.15.03-AM.png".
    static func safeName(_ original: String, ext: String) -> String {
        var stem = ""
        for ch in original.unicodeScalars {
            let ok = ch.isASCII && (CharacterSet.alphanumerics.contains(ch) || ch == "-" || ch == "_" || ch == ".")
            let c: Character = ok ? Character(ch) : "-"
            if c == "-" && stem.last == "-" { continue }
            if c == "." && stem.last == "." { continue }
            stem.append(c)
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let suffix = "." + ext.lowercased()
        stem = String(stem.prefix(80 - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if stem.isEmpty { stem = "attachment" }
        return stem + suffix
    }

    // MARK: The report

    struct Report: Encodable {
        var title: String
        var details: String
        var tags: [String]
        var autoTags: [String]
        var priority: String            // low | normal | high | blocking
        var name: String
        var email: String
        var contactOK: Bool
        var platform = "macos"
        var app: [String: String]       // version, build
        var system: [String: String]    // macOS, model, arch
        var context: [String: String]   // a few small facts about Glide right now
        var attachments: [Meta] = []    // filled in by send()

        struct Meta: Encodable {
            let name: String
            let type: String
            let size: Int
        }
    }

    struct Attachment {
        enum Source {
            case data(Data)
            case file(URL)
        }
        let name: String
        let type: String
        let source: Source

        var size: Int {
            switch source {
            case .data(let d): d.count
            case .file(let url): (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }

        func load() throws -> Data {
            switch source {
            case .data(let d): return d
            case .file(let url):
                do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
                    throw FeedbackError(String(localized: "“\(url.lastPathComponent)” couldn’t be read. Remove it and add it again."))
                }
            }
        }
    }

    struct FeedbackError: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Created: Decodable {
        let id: String
        let uploadToken: String
        let chunkSize: Int
    }

    let server: URL
    let session: URLSession
    /// How many times one request is tried before giving up.
    var tries = 3

    init(server: URL = FeedbackClient.server, session: URLSession = FeedbackClient.defaultSession) {
        self.server = server
        self.session = session
    }

    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "Glide-Feedback"]
        return URLSession(configuration: c)
    }()

    /// Checks everything the server would refuse, before anything is sent.
    static func validate(_ report: Report, _ attachments: [Attachment]) throws {
        if report.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FeedbackError(String(localized: "It needs a title.")) }
        if attachments.count > maxAttachments { throw FeedbackError(String(localized: "That’s too many attachments (at most \(maxAttachments)).")) }
        var names = Set<String>()
        for a in attachments {
            guard isValidName(a.name) else { throw FeedbackError(String(localized: "“\(a.name)” can’t be sent with that name.")) }
            guard names.insert(a.name).inserted else { throw FeedbackError(String(localized: "Two attachments are called “\(a.name)”.")) }
            guard let limit = sizeLimits[a.type] else { throw FeedbackError(String(localized: "“\(a.name)” isn’t a kind of file that can be sent.")) }
            let size = a.size
            guard size > 0 else { throw FeedbackError(String(localized: "“\(a.name)” is empty or missing.")) }
            guard size <= limit else {
                throw FeedbackError(String(localized: "“\(a.name)” is too big to send (the limit is \(limit / 1_000_000) MB)."))
            }
        }
    }

    /// Sends the report and its attachments. `progress` is called on the main
    /// thread with 0…1 and a short note. Returns the report's id.
    @discardableResult
    func send(_ report: Report, attachments: [Attachment],
              progress: @escaping @MainActor (Double, String) -> Void) async throws -> String {
        try Self.validate(report, attachments)
        var report = report
        let sizes = attachments.map(\.size)
        report.attachments = zip(attachments, sizes).map { Report.Meta(name: $0.name, type: $0.type, size: $1) }
        let body = try JSONEncoder().encode(report)

        let total = sizes.reduce(0, +)
        // The report itself counts as a sliver; the bytes are the rest.
        let head = total == 0 ? 1.0 : 0.04
        await progress(0, String(localized: "Sending…"))
        let created: Created
        do {
            let data = try await perform(request("/api/feedback", method: "POST", body: body, type: "application/json"))
            created = try JSONDecoder().decode(Created.self, from: data)
        } catch let e as FeedbackError {
            throw e
        } catch is DecodingError {
            throw FeedbackError(String(localized: "The feedback server sent back something unexpected. Try again in a little while."))
        }
        guard created.chunkSize > 0 else { throw FeedbackError(String(localized: "The feedback server sent back something unexpected.")) }
        await progress(head, total == 0 ? String(localized: "Sent", comment: "Feedback progress") : String(localized: "Sending…"))
        guard !attachments.isEmpty else { return created.id }

        var done = 0
        let mb = { (n: Int) in (Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(1))) }
        for (a, size) in zip(attachments, sizes) {
            let data = try a.load()
            guard data.count == size else { throw FeedbackError(String(localized: "“\(a.name)” changed while it was being sent. Try again.")) }
            let pieces = max(1, (data.count + created.chunkSize - 1) / created.chunkSize)
            for i in 0..<pieces {
                try Task.checkCancellation()
                let range = (i * created.chunkSize)..<min(data.count, (i + 1) * created.chunkSize)
                var q = URLComponents()
                q.queryItems = [.init(name: "id", value: created.id), .init(name: "file", value: a.name),
                                .init(name: "index", value: String(i)), .init(name: "total", value: String(pieces))]
                let base = done
                let note = { (sent: Int) in
                    String(localized: "Sending \(a.name)… \(mb(sent)) of \(mb(total)) MB", comment: "File name, then megabytes sent so far and in all")
                }
                let reporter = PieceProgress { sent in
                    let f = head + (1 - head) * Double(base + Int(sent)) / Double(max(total, 1))
                    progress(min(f, 1), note(base + Int(sent)))
                }
                _ = try await perform(request("/api/feedback/upload", query: q.queryItems, method: "PUT",
                                              token: created.uploadToken, body: data.subdata(in: range),
                                              type: "application/octet-stream"), delegate: reporter)
                done += range.count
                await progress(head + (1 - head) * Double(done) / Double(max(total, 1)),
                               note(done))
            }
        }
        _ = try await perform(request("/api/feedback/complete", query: [.init(name: "id", value: created.id)],
                                      method: "POST", token: created.uploadToken, body: nil, type: "application/json"))
        await progress(1, String(localized: "Sent", comment: "Feedback progress"))
        return created.id
    }

    // MARK: Requests

    private func request(_ path: String, query: [URLQueryItem]? = nil, method: String, token: String? = nil,
                         body: Data?, type: String) -> URLRequest {
        var c = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        c.queryItems = query
        var r = URLRequest(url: c.url ?? server)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue(Self.appKey, forHTTPHeaderField: "x-glide-key")
        if let token { r.setValue(token, forHTTPHeaderField: "x-upload-token") }
        return r
    }

    /// Tried again (with a growing pause) on a flaky connection, a timeout or
    /// a 5xx — a bad moment shouldn't lose a report. A 4xx is the server
    /// saying no, so its own words are passed on right away.
    private func perform(_ r: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> Data {
        var last = FeedbackError(String(localized: "The feedback couldn’t be sent."))
        for attempt in 0..<max(1, tries) {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(0.8 * pow(2, Double(attempt - 1)) * 1_000_000_000))
            }
            try Task.checkCancellation()
            do {
                let (data, response): (Data, URLResponse)
                if let body = r.httpBody {
                    var upload = r
                    upload.httpBody = nil
                    (data, response) = try await session.upload(for: upload, from: body, delegate: delegate)
                } else {
                    (data, response) = try await session.data(for: r, delegate: delegate)
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return data }
                let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                if code >= 500 {
                    last = FeedbackError(said.map { String(localized: "The feedback server had a problem: \($0)") }
                        ?? String(localized: "The feedback server had a problem (error \(code)). Try again in a minute."))
                    continue
                }
                // The server's own words, as it sent them.
                throw FeedbackError(said ?? String(localized: "The feedback server turned it down (error \(code))."))
            } catch let e as FeedbackError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                last = FeedbackError(e.code == .timedOut
                    ? String(localized: "The feedback server took too long to answer. Check your connection and try again.")
                    : String(localized: "Couldn’t reach the feedback server. Check your internet connection and try again."))
            } catch {
                last = FeedbackError(String(localized: "Couldn’t reach the feedback server: \(error.localizedDescription)"))
            }
        }
        throw last
    }
}

/// Bytes of one piece on their way out, passed to the main thread in order.
private final class PieceProgress: NSObject, URLSessionTaskDelegate {
    private let report: @MainActor (Int64) -> Void

    init(_ report: @escaping @MainActor (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let report = report
        DispatchQueue.main.async { MainActor.assumeIsolated { report(totalBytesSent) } }
    }
}
