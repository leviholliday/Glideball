import AppKit

/// The languages Glide is translated into, and the per-app language choice
/// (Overview › General › Language). The choice is the same setting as System
/// Settings › General › Language & Region › Applications: "AppleLanguages" in
/// Glide's own defaults. macOS reads it at launch, so a change needs a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    // Raw values are the .lproj names (and what goes in AppleLanguages).
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case brazilianPortuguese = "pt-BR"
    case japanese = "ja"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language in its own words, so anyone can find theirs.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .brazilianPortuguese: "Português (Brasil)"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .simplifiedChinese: "简体中文"
        }
    }

    private static let defaultsKey = "AppleLanguages"

    /// The language picked for Glide, or nil to follow the Mac ("System Default").
    static var chosen: AppLanguage? {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
            guard let first = (domain?[defaultsKey] as? [String])?.first else { return nil }
            return match(first)
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue.rawValue], forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// What was chosen when Glide started — what's on screen now.
    static let atLaunch = chosen

    /// "pt-BR", "pt_BR", "zh-Hans-CN", "de-DE"… → the closest translation.
    private static func match(_ code: String) -> AppLanguage? {
        let code = code.replacingOccurrences(of: "_", with: "-")
        if let exact = AppLanguage(rawValue: code) { return exact }
        if code.hasPrefix("pt") { return .brazilianPortuguese }
        if code.hasPrefix("zh-Hans") || code == "zh-CN" { return .simplifiedChinese }
        return AppLanguage(rawValue: String(code.prefix { $0 != "-" }))
    }

    /// Quits and opens Glide again, so a new language takes effect.
    static func relaunch() {
        // A tiny helper waits for this process to end, then reopens the app.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
        } catch {
            NSSound.beep()
            return
        }
        // Glide refuses ordinary quits (see AppDelegate); this one is asked for.
        if let app = NSApp.delegate as? AppDelegate { app.quitNow() } else { NSApp.terminate(nil) }
    }
}
