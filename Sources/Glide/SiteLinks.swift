import Foundation

/// Where the app's links go: Glideball's own website. (Reporting a problem and
/// the source code stay on GitHub.)
enum SiteLinks {
    static let base = "https://glideball.netlify.app"

    static let help = URL(string: base + "/help/")!
    static let troubleshooting = URL(string: base + "/help/troubleshooting/")!
    static let permissions = URL(string: base + "/help/permissions/")!
    static let changelog = URL(string: base + "/changelog/")!

    /// What's new in one version: the changelog, scrolled to that release
    /// (the page gives each release the id of its tag, like "v2.10-beta.5").
    /// Without a readable version it's the whole changelog.
    static func whatsNew(in version: String) -> URL {
        let tag = version.hasPrefix("v") ? version : "v" + version
        guard !version.isEmpty,
              tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
              let url = URL(string: base + "/changelog/#" + tag) else { return changelog }
        return url
    }
}
