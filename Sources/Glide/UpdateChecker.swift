import AppKit
import Foundation
import Observation
import Security

/// Checks GitHub once a day for a newer Glide release and installs it in place.
/// This and iCloud Drive sync are the only times Glide touches the network.
///
/// Installing: download the release zip, unpack it, and only accept it if it's
/// signed with the same certificate and bundle identifier as the running app
/// (so a tampered download is refused — and macOS keeps the Accessibility and
/// Input Monitoring grants, which are tied to that signature). Then a tiny
/// helper waits for Glide to quit, swaps the app, and relaunches it.
@Observable
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let page: URL
        let download: URL?
        let notes: String
    }

    enum InstallState: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var available: Update?
    private(set) var installState: InstallState = .idle

    static let releasesAPI = URL(string: "https://api.github.com/repos/leviholliday/glide/releases/latest")!
    static let assetName = "Glide.zip"
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let update = Self.parse(data) else { return }
            let newer = Self.isNewer(update.version, than: self.currentVersion)
            DispatchQueue.main.async {
                self.available = newer ? update : nil
            }
        }.resume()
    }

    static func parse(_ data: Data) -> Update? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { $0["name"] as? String == assetName }?["browser_download_url"] as? String
        return Update(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                      page: page,
                      download: zip.flatMap(URL.init(string:)),
                      notes: json["body"] as? String ?? "")
    }

    /// Compares dotted version numbers: "1.10" > "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    func install() {
        guard let update = available, let download = update.download else {
            if let page = available?.page { NSWorkspace.shared.open(page) }
            return
        }
        installState = .downloading(0)
        let task = URLSession.shared.downloadTask(with: download) { [weak self] file, response, error in
            guard let self else { return }
            let result: Result<URL, Error>
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                result = Result { try Self.prepare(zip: file, expectedVersion: update.version) }
            } else {
                result = .failure(UpdateError("The download didn’t finish\(error.map { ": \($0.localizedDescription)" } ?? ".")"))
            }
            DispatchQueue.main.async {
                self.progressObservation = nil
                switch result {
                case .success(let newApp): self.relaunch(into: newApp)
                case .failure(let error): self.installState = .failed(error.localizedDescription)
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.installState { self?.installState = .downloading(progress.fractionCompleted) }
            }
        }
        task.resume()
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Unpacks the downloaded zip and returns the new Glide.app — only if it's
    /// genuinely ours and genuinely the advertised version.
    static func prepare(zip: URL, expectedVersion: String) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError("Couldn’t unpack the update.") }

        let app = work.appendingPathComponent("Glide.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("The download isn’t the expected Glide \(expectedVersion).")
        }
        try verifySignature(of: app)
        return app
    }

    /// The new app must satisfy the running app's own designated requirement:
    /// same signing certificate, same identifier.
    static func verifySignature(of app: URL) throws {
        var me: SecCode?
        var requirement: SecRequirement?
        var staticMe: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("Couldn’t read Glide’s own signature to compare against.")
        }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw UpdateError("The update isn’t signed by Glide’s developer, so it wasn’t installed.")
        }
    }

    /// Hands off to a tiny shell helper that swaps the app once Glide has quit.
    private func relaunch(into newApp: URL) {
        installState = .installing
        let current = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current).old"
        mv "\(current)" "\(current).old" && mv "\(newApp.path)" "\(current)" && rm -rf "\(current).old" \
          || { rm -rf "\(current)"; mv "\(current).old" "\(current)"; }
        xattr -dr com.apple.quarantine "\(current)" 2>/dev/null
        open "\(current)"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
        } catch {
            installState = .failed("Couldn’t start the installer: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
