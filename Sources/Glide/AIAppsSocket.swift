import Darwin
import Foundation
import Security

// The socket between `Glideball --mcp` (AIAppsHelper.swift) and the running Glideball
// (AIApps.swift answers). A Unix socket file, never a network port: nothing off this Mac
// can reach it, and neither can a web page.
//
//  - The file is ~/Library/Application Support/Glide/mcp.sock. It exists only while "Allow
//    AI apps" is on; turning that off, the 15 minutes ending and quitting all delete it.
//  - Its mode is 0600 before anything can connect (bind, chmod, check, and only then
//    listen), in a folder only this person can write to. A file that's already at that path
//    and isn't a socket of this person's is left alone, and the switch says it couldn't start.
//  - Every connection: the other end must run as this person (`getpeereid`), and, when this
//    Glideball is signed, must be this same Glideball (its audit token checked against this
//    binary's own designated requirement). That second check is best effort: anything running
//    as this person could also start `Glideball --mcp` itself, or edit Glideball's saved
//    settings directly. The gates that matter are the switch, the review and Undo.
//  - One request, one answer, then the connection closes. A request is 4 bytes of length
//    (big-endian) and that many bytes of JSON, at most 64 KB; a longer one is refused by its
//    length alone, unread. A connection has 2 seconds in all to send its request, and at
//    most 8 are served at once; more are closed.
//
// Foundation, Darwin and Security only, so scripts/mcp-sim runs the real thing in a temp folder.

/// A clock that keeps going while the Mac sleeps, so 15 minutes are 15 minutes of the wall's time.
enum AIAppsClock {
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }
}

/// Who is on the other end of a connection.
enum AIAppsPeer {
    /// It runs as this person.
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// What a process must satisfy to count as this Glideball: this binary's own designated
    /// requirement. Nil when this binary isn't signed (a bare development build).
    static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    /// It's this same Glideball (the app and its `--mcp` helper are one binary). True when
    /// this binary isn't signed, since there's then nothing to compare with.
    static func sameApp(_ fd: Int32) -> Bool {
        guard let requirement = ownRequirement else { return true }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              Int(size) == MemoryLayout<audit_token_t>.size else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// Length-prefixed frames on a connected socket.
enum AIAppsFrame {
    /// Reads exactly `count` bytes before `deadline` (on `AIAppsClock`), or nil.
    static func read(_ fd: Int32, count: Int, deadline: Double) -> Data? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            guard AIAppsClock.now() < deadline else { return nil }
            let n = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n > 0 {
                got += n
            } else if n == 0 {
                return nil   // closed early
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                return nil
            }
        }
        return Data(out)
    }

    /// One frame: its length, then its bytes, when the length is 1...max. `tooLong` is set
    /// when the length alone ruled it out (nothing of the body was read).
    static func readFrame(_ fd: Int32, max: Int, deadline: Double, tooLong: inout Bool) -> Data? {
        guard let head = read(fd, count: 4, deadline: deadline) else { return nil }
        let length = head.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= max else {
            tooLong = true
            return nil
        }
        return read(fd, count: length, deadline: deadline)
    }

    @discardableResult
    static func write(_ fd: Int32, _ body: Data) -> Bool {
        let n = UInt32(body.count)
        var bytes: [UInt8] = [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        bytes.append(contentsOf: body)
        var sent = 0
        while sent < bytes.count {
            let w = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if w > 0 {
                sent += w
            } else if w < 0 && errno == EINTR {
                continue
            } else {
                return false   // gone, or the send timed out
            }
        }
        return true
    }

    /// Blocking, with a timeout on each read and write, and no SIGPIPE when the other end has gone.
    static func prepare(_ fd: Int32, timeout: Double) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The address of a socket file, or nil when the path is too long for one (104 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: addr.sun_path), !bytes.contains(0) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }
}

/// Glideball's end: the socket file, while "Allow AI apps" is on.
final class AIAppsListener {
    enum Failure: Error { case path, folder, inTheWay, socket, mode }

    static let maxConnections = 8
    /// A connection has this long to send its request.
    static let requestTime = 2.0

    let path: String
    private let peerOK: (Int32) -> Bool
    private let answer: (Data) -> Data
    private var source: DispatchSourceRead?
    private var identity: (dev: dev_t, ino: ino_t)?
    private let accepting = DispatchQueue(label: "com.leviholliday.glide.ai-apps.accept", qos: .utility)
    private let serving = DispatchQueue(label: "com.leviholliday.glide.ai-apps.serve", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = 0
    /// Connections closed without an answer (too many at once, or not this person's or this app's).
    private(set) var turnedAway = 0

    /// `answer` takes one request and gives its answer (`AIAppsService.handle`, on the thread
    /// the service lives on). `peerOK` is asked about every connection after the same-user check.
    init(path: String, peerOK: @escaping (Int32) -> Bool = AIAppsPeer.sameApp, answer: @escaping (Data) -> Data) {
        self.path = path
        self.peerOK = peerOK
        self.answer = answer
    }

    var isListening: Bool { source != nil }

    func start() throws {
        guard source == nil else { return }
        guard var addr = AIAppsFrame.address(path) else { throw Failure.path }

        // The folder: this person's, and nobody else can put files in it.
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(folder, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o002 == 0 else {
            throw Failure.folder
        }
        // Something already there: only ever a socket of this person's (one a crash left) is replaced.
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw Failure.inTheWay }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure.socket
        }
        // Nothing can connect until listen(), and by then the file is 0600 and checked.
        guard chmod(path, 0o600) == 0, lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(),
              st.st_mode & 0o777 == 0o600 else {
            close(fd)
            unlink(path)
            throw Failure.mode
        }
        identity = (st.st_dev, st.st_ino)
        guard listen(fd, 8) == 0 else {
            close(fd)
            removeFile()
            throw Failure.socket
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: accepting)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// The file goes first, so nothing new can connect; then the socket is closed.
    func stop() {
        removeFile()
        source?.cancel()
        source = nil
    }

    /// Deletes the socket file if it's still the one this listener made.
    private func removeFile() {
        guard let identity else { return }
        var st = stat()
        if lstat(path, &st) == 0, st.st_dev == identity.dev, st.st_ino == identity.ino { unlink(path) }
        self.identity = nil
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            let room = lock.withLock { () -> Bool in
                guard inFlight < Self.maxConnections else { return false }
                inFlight += 1
                return true
            }
            guard room, AIAppsPeer.sameUser(c) else {
                close(c)
                lock.withLock {
                    turnedAway += 1
                    if room { inFlight -= 1 }
                }
                continue
            }
            AIAppsFrame.prepare(c, timeout: 0.5)
            serving.async { [weak self] in
                self?.serve(c)
                close(c)
                self?.lock.withLock { self?.inFlight -= 1 }
            }
        }
    }

    private func serve(_ c: Int32) {
        guard peerOK(c) else {
            lock.withLock { turnedAway += 1 }
            return
        }
        var tooLong = false
        let deadline = AIAppsClock.now() + Self.requestTime
        guard let request = AIAppsFrame.readFrame(c, max: AIAppsLimits.maxRequestBytes, deadline: deadline, tooLong: &tooLong) else {
            // Too long by its own length: refused unread. Anything else (cut off, too slow): just closed.
            if tooLong { AIAppsFrame.write(c, AIAppsReply(ok: false, text: AIAppsText.unreadable).frame) }
            return
        }
        AIAppsFrame.write(c, answer(request))
    }
}

/// The helper's end: one request to the running Glideball, one answer back.
enum AIAppsClient {
    enum Failure: Error {
        /// No socket file: Glideball isn't open, or "Allow AI apps" is off.
        case notThere
        /// A file is there that isn't this person's private socket, or the other end isn't Glideball.
        case notOurs
        /// It didn't answer (in time, or with something readable).
        case failed
    }

    static func send(_ request: Data, to path: String, peerOK: (Int32) -> Bool = AIAppsPeer.sameApp,
                     timeout: Double = 10) -> Result<Data, Failure> {
        guard request.count <= AIAppsLimits.maxRequestBytes, var addr = AIAppsFrame.address(path) else { return .failure(.failed) }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(.notThere) }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return .failure(.notOurs) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed) }
        defer { close(fd) }
        AIAppsFrame.prepare(fd, timeout: 0.5)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(errno == ENOENT || errno == ECONNREFUSED ? .notThere : .failed) }
        guard AIAppsPeer.sameUser(fd), peerOK(fd) else { return .failure(.notOurs) }
        guard AIAppsFrame.write(fd, request) else { return .failure(.failed) }
        var tooLong = false
        guard let reply = AIAppsFrame.readFrame(fd, max: AIAppsLimits.maxReplyBytes, deadline: AIAppsClock.now() + timeout, tooLong: &tooLong) else {
            return .failure(.failed)
        }
        return .success(reply)
    }
}
