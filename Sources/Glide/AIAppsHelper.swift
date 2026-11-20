import Darwin
import Foundation

// `Glideball --mcp`: what an AI app on this Mac starts to talk to Glideball. It's the
// app's own binary (nothing else to build or sign), and main.swift comes here before
// anything of AppKit starts, so it never shows in the Dock, never counts as a second
// Glideball and never touches the trackball or the settings.
//
// It speaks MCP (JSON-RPC 2.0, one message a line) on stdin and stdout, and that's all it
// does by itself: answer the handshake and the tool list. A tool call is passed, as it is,
// to the running Glideball over the socket file (AIAppsSocket.swift), and Glideball's answer
// is passed back. So the helper knows no settings, reads no file of the person's and
// decides nothing: with "Allow AI apps" off, or Glideball not open, there's no socket file
// and every tool call gets the same answer (`AIAppsText.off`).
//
// What it never does: start Glideball or anything else (there's no `Process` here), open a
// file or a path the AI names, reach the network, or write anywhere but stdout. What comes
// in on stdin is hostile: a line is at most 128 KB (a longer one is thrown away up to its
// newline and answered with an error), JSON nested at most 32 deep, and only the four
// methods below do anything.
//
// Foundation and Darwin only, so scripts/mcp-sim drives it without the app.

/// Cuts stdin into lines, with a cap. Bytes past the cap are dropped until the newline.
struct AIAppsLineReader {
    enum Event: Equatable {
        case line(Data)
        /// A line longer than `AIAppsLimits.maxLineBytes` ended here; none of it was kept.
        case tooLong
    }

    private var buffer: [UInt8] = []
    private var discarding = false

    mutating func feed<S: Sequence>(_ bytes: S) -> [Event] where S.Element == UInt8 {
        var out: [Event] = []
        for b in bytes {
            if b == 0x0A {
                if discarding {
                    out.append(.tooLong)
                    discarding = false
                } else {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    if !buffer.isEmpty { out.append(.line(Data(buffer))) }
                }
                buffer.removeAll(keepingCapacity: true)
            } else if discarding {
                continue
            } else if buffer.count >= AIAppsLimits.maxLineBytes {
                discarding = true
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(b)
            }
        }
        return out
    }
}

/// MCP on one side, Glideball's socket on the other. One message in, at most one out.
final class AIAppsStdio {
    /// The MCP versions this answers to; the first is offered when the AI app asks for another.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let instructions = "Glideball is a Mac app for Kensington trackballs. These tools read its setup and suggest changes to its settings, nothing else. They only work while the person has turned on Allow AI apps in Glideball's Settings (15 minutes at a time), and nothing changes until the person clicks Apply in Glideball."

    private let version: String
    private let send: (Data) -> Result<Data, AIAppsClient.Failure>
    /// The name the AI app gave for itself. Shown in the review as what it said, never trusted.
    private var client = ""

    /// `send` hands a request to the running Glideball (`AIAppsClient.send`).
    init(version: String, send: @escaping (Data) -> Result<Data, AIAppsClient.Failure>) {
        self.version = version
        self.send = send
    }

    /// The answer to a line that was too long to read.
    static let tooLongReply = reply(id: NSNull(), error: -32600, "Request too large")

    /// One line from the AI app; its answer as one line, or nil when it gets none (a notification).
    func handle(_ line: Data) -> Data? {
        guard line.count <= AIAppsLimits.maxLineBytes, ImportJSON.depthIsWithin(line),
              let any = try? JSONSerialization.jsonObject(with: line) else {
            return Self.reply(id: NSNull(), error: -32700, "Parse error")
        }
        // (An array is a batch, which MCP no longer has.)
        guard let o = any as? [String: Any] else { return Self.reply(id: NSNull(), error: -32600, "Invalid Request") }
        let hasID = o["id"] != nil
        let id = Self.requestID(o["id"])
        guard o["jsonrpc"] as? String == "2.0", let method = o["method"] as? String else {
            // An answer to something this never asked: nothing to say.
            if o["method"] == nil, o["result"] != nil || o["error"] != nil { return nil }
            return Self.reply(id: id ?? NSNull(), error: -32600, "Invalid Request")
        }
        guard hasID else { return nil }   // a notification ("notifications/initialized", "notifications/cancelled")
        guard let id else { return Self.reply(id: NSNull(), error: -32600, "Invalid Request") }

        let params: [String: Any]
        switch o["params"] {
        case nil, is NSNull: params = [:]
        case let p as [String: Any]: params = p
        default: return Self.reply(id: id, error: -32602, "Invalid params")
        }

        switch method {
        case "initialize":
            client = AIAppsRequest.cleanClient((params["clientInfo"] as? [String: Any])?["name"])
            let asked = params["protocolVersion"] as? String
            let speaks = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.reply(id: id, result: [
                "protocolVersion": speaks,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "glideball", "title": "Glideball", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.reply(id: id, result: [String: Any]())
        case "tools/list":
            return Self.reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, AIAppsTool(rawValue: name) != nil else {
                return Self.reply(id: id, error: -32602, "Unknown tool")
            }
            let arguments: [String: Any]
            switch params["arguments"] {
            case nil, is NSNull: arguments = [:]
            case let a as [String: Any]: arguments = a
            default: return Self.reply(id: id, error: -32602, "Invalid params")
            }
            return Self.reply(id: id, result: Self.toolResult(call(name, arguments)))
        default:
            return Self.reply(id: id, error: -32601, "Method not found")
        }
    }

    /// Passes a tool call to Glideball and brings back what it said.
    private func call(_ tool: String, _ arguments: [String: Any]) -> AIAppsReply {
        guard let frame = AIAppsRequest.frame(tool: tool, client: client, arguments: arguments) else {
            return AIAppsReply(ok: false, text: AIAppsText.tooBig)
        }
        // Whatever went wrong on the way (no socket, not Glideball's, no answer), the AI
        // hears the same thing: ask the person to turn it on.
        guard case .success(let data) = send(frame), let reply = AIAppsReply(frame: data) else {
            return AIAppsReply(ok: false, text: AIAppsText.off)
        }
        return reply
    }

    // MARK: MCP's shapes

    /// The tool list an AI app is given: `AIAppsTool`'s cases, nothing more.
    static var tools: [[String: Any]] {
        AIAppsTool.allCases.map { tool in
            let readOnly = tool != .proposeChanges
            return ["name": tool.rawValue, "description": tool.about, "inputSchema": tool.inputSchema,
                    "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": readOnly, "openWorldHint": false]]
        }
    }

    static func toolResult(_ reply: AIAppsReply) -> [String: Any] {
        ["content": [["type": "text", "text": reply.text]], "isError": !reply.ok]
    }

    /// A request's id as it may be sent back: a number, or a string of at most 128 bytes.
    static func requestID(_ raw: Any?) -> Any? {
        switch raw {
        case let s as String: s.utf8.count <= 128 ? s : nil
        case let n as NSNumber: CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite ? n : nil
        default: nil
        }
    }

    static func reply(id: Any, result: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func reply(id: Any, error code: Int, _ message: String) -> Data {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One line of JSON (JSONSerialization writes a newline inside a string as \n).
    private static func line(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

enum AIAppsHelper {
    /// main.swift: this run is the helper, not the app. Only as the first argument, so a
    /// file or a link named "--mcp" opened with Glideball is never taken for it.
    static var isAsked: Bool { CommandLine.arguments.dropFirst().first == "--mcp" }

    /// ~/Library/Application Support/Glide/mcp.sock (the data folder keeps the old name).
    /// Always this path: nothing the AI app says, and no argument or environment variable, moves it.
    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glide/mcp.sock").path
    }

    /// Reads stdin until the AI app closes it, then exits. Never returns.
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let path = socketPath
        let stdio = AIAppsStdio(version: version) { AIAppsClient.send($0, to: path) }
        var reader = AIAppsLineReader()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(STDIN_FILENO, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { exit(0) }   // the AI app closed the pipe, or went away
            for event in reader.feed(chunk[0..<n]) {
                let answer: Data? = switch event {
                case .line(let line): stdio.handle(line)
                case .tooLong: AIAppsStdio.tooLongReply
                }
                guard let answer else { continue }
                guard writeAll(answer + [0x0A]) else { exit(0) }
            }
        }
    }

    private static func writeAll(_ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw in
            while sent < raw.count {
                let w = write(STDOUT_FILENO, raw.baseAddress! + sent, raw.count - sent)
                if w > 0 { sent += w } else if w < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}
