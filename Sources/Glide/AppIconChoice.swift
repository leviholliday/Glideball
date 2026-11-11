import AppKit
import Observation
import SwiftUI

/// The two icons Glideball ships: the Orb (the app bundle's own icon since 2.10)
/// and the classic one (`AppIconClassic.icns`, next to it in Resources).
enum AppIconStyle: String, CaseIterable, Identifiable {
    case orb, classic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .orb: String(localized: "Orb", comment: "App icon choice: the new icon")
        case .classic: String(localized: "Classic", comment: "App icon choice: the icon Glideball had before")
        }
    }

    fileprivate var resource: String {
        switch self {
        case .orb: "AppIcon"
        case .classic: "AppIconClassic"
        }
    }
}

/// Which icon shows in the Dock and the app switcher while Glideball runs
/// (Settings › Look & Sound › App icon), per Mac. Only `NSApp.applicationIconImage`
/// changes: the bundle on disk never does (that would break its signature), so
/// Finder, Launchpad and a Dock that isn't running Glideball show the Orb either way.
///
/// A new Mac gets the Orb. A Mac that used a Glideball with the classic icon
/// keeps the classic one, so nothing changes without asking, until it answers
/// "Glideball has a new look" (`IconChoicePrompt`, which takes its turn
/// in `AppModel.showNextPrompt()`, after What's New) or picks one in Settings.
@Observable
final class AppIconChoice {
    static let shared = AppIconChoice()
    static let styleKey = "GlideAppIcon"
    static let promptKey = "GlideAppIconPromptDue"

    private(set) var style: AppIconStyle
    /// "Glideball has a new look" hasn't been answered yet.
    private(set) var promptDue: Bool

    @ObservationIgnored private var images: [AppIconStyle: NSImage] = [:]

    private init() {
        let d = UserDefaults.standard
        style = d.string(forKey: Self.styleKey).flatMap(AppIconStyle.init(rawValue:)) ?? .orb
        promptDue = d.bool(forKey: Self.promptKey)
    }

    /// At launch, before the window opens. The first launch of a version with
    /// this setting decides: the Orb on a new Mac (`firstLaunch`), the classic
    /// icon (and the question) on one that used Glideball before.
    func setUp(firstLaunch: Bool) {
        let d = UserDefaults.standard
        if d.string(forKey: Self.styleKey) == nil {
            style = firstLaunch ? .orb : .classic
            promptDue = !firstLaunch
            d.set(style.rawValue, forKey: Self.styleKey)
            d.set(promptDue, forKey: Self.promptKey)
        }
        apply()
    }

    /// Settings, or an answer to the question. Either way it's been asked.
    func choose(_ new: AppIconStyle) {
        style = new
        promptDue = false
        UserDefaults.standard.set(new.rawValue, forKey: Self.styleKey)
        UserDefaults.standard.set(false, forKey: Self.promptKey)
        apply()
    }

    /// The icon in use, for views that draw the app's own icon (About, Feedback…).
    var image: NSImage { image(for: style) }

    func image(for style: AppIconStyle) -> NSImage {
        if let cached = images[style] { return cached }
        let loaded = Bundle.main.url(forResource: style.resource, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)   // a bare `swift run`
        images[style] = loaded
        return loaded
    }

    private func apply() {
        // nil puts back the bundle's own icon (the Orb).
        NSApp.applicationIconImage = style == .orb ? nil : image(for: .classic)
    }
}

// MARK: - "Glideball has a new look"

/// Asked once, after updating from a version with the classic icon, when
/// nothing else is over the window. Until it's answered, the classic icon stays.
struct IconChoicePrompt: View {
    @Bindable var model: AppModel
    private let icons = AppIconChoice.shared

    var body: some View {
        OverlayCard(width: 460) {
            VStack(spacing: 18) {
                Text("Glideball has a new look")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 36) {
                    icon(.orb, label: "New")
                    icon(.classic, label: "Classic")
                }
                Text("Pick the one you’d like in your Dock. You can change it any time in Settings › Look & Sound.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Keep the classic one") { answer(.classic) }
                        .keyboardShortcut(.cancelAction)
                    Button("Use the new icon") { answer(.orb) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ball)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func icon(_ style: AppIconStyle, label: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: icons.image(for: style))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func answer(_ style: AppIconStyle) {
        AppIconChoice.shared.choose(style)
        model.showingIconChoice = false
    }
}

/// Settings › Look & Sound: the two icons as small pictures; click one to use it.
struct AppIconPicker: View {
    private let icons = AppIconChoice.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppIconStyle.allCases) { style in
                let selected = icons.style == style
                Button {
                    withAnimation(Theme.Motion.spring) { icons.choose(style) }
                } label: {
                    VStack(spacing: 4) {
                        Image(nsImage: icons.image(for: style))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 44, height: 44)
                        Text(verbatim: style.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(.secondary))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Theme.ball.opacity(0.10) : .clear)
                            .strokeBorder(selected ? Theme.ball.opacity(0.6) : .clear, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(radius: 10))
                .accessibilityLabel(Text(verbatim: style.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
