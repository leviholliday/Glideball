import Foundation
import Observation

/// Checks GitHub once a day for a newer Glide release. This and iCloud Drive
/// sync are the only times Glide touches the network.
@Observable
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let page: URL
    }

    private(set) var available: Update?

    static let releasesAPI = URL(string: "https://api.github.com/repos/leviholliday/glide/releases/latest")!
    @ObservationIgnored private var timer: Timer?

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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let newer = Self.isNewer(version, than: self.currentVersion)
            DispatchQueue.main.async {
                self.available = newer ? Update(version: version, page: page) : nil
            }
        }.resume()
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
}
