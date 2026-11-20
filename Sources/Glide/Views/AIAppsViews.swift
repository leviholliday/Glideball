import AppKit
import SwiftUI

// What you see of "Allow AI apps" (AIAppsCenter.swift): the switch and its countdown in
// Settings › General, the countdown with Stop in the sidebar and the menu-bar panel, and
// Connect an AI app…, which only ever shows text to copy. Glideball never edits another
// app's settings itself.

/// Settings › General › Other apps: the switch with its countdown.
struct AllowAIAppsRow: View {
    private let center = AIAppsCenter.shared

    var body: some View {
        SettingsRow(title: "Allow AI apps", hint: hint, symbol: "text.bubble") {
            HStack(spacing: 8) {
                if center.isOn {
                    Text(verbatim: center.countdown)
                        .font(Theme.Font.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: true))
                        .help(Text("Turns itself off in \(center.countdown)", comment: "Tooltip on the Allow AI apps countdown; %@ is minutes and seconds like 14:32"))
                        .accessibilityLabel(Text("Turns itself off in \(center.countdown)", comment: "Tooltip on the Allow AI apps countdown; %@ is minutes and seconds like 14:32"))
                }
                Toggle(isOn: Binding(get: { center.isOn }, set: { $0 ? center.turnOn() : center.turnOff() })) { Text("Allow AI apps") }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
        .findable(.allowAIApps)
    }

    private var hint: String {
        if center.couldNotStart {
            return String(localized: "Glideball couldn’t open its connection for AI apps, so this stayed off. Try again.",
                          comment: "Settings › General hint: Allow AI apps failed to turn on")
        }
        return center.isOn
            ? String(localized: "AI apps on this Mac can read your setup and suggest changes until this turns itself off. You approve each change here, and what they read goes to that app’s AI service.",
                     comment: "Settings › General hint: Allow AI apps is on")
            : String(localized: "Lets an AI app on this Mac read your Glideball setup and suggest changes. You approve each one in Glideball, and it turns itself off after 15 minutes.",
                     comment: "Settings › General hint: Allow AI apps is off")
    }
}

/// Settings › General › Other apps: what to copy into an AI app so it can find Glideball.
struct ConnectAIAppRow: View {
    @State private var connecting = false

    var body: some View {
        SettingsRow(title: "Connect an AI app", hint: String(localized: "What to copy into Claude or another AI app so it can find Glideball.",
                                                              comment: "Settings › General hint: Connect an AI app"),
                    symbol: "cable.connector.horizontal") {
            Button("Show How…") { connecting = true }
                .controlSize(.small)
        }
        .findable(.connectAIApp)
        .sheet(isPresented: $connecting) { ConnectAIAppSheet { connecting = false } }
    }
}

/// "AI apps allowed 14:32 Stop": in the sidebar and the menu-bar panel while the switch is on.
struct AIAppsCountdown: View {
    private let center = AIAppsCenter.shared

    var body: some View {
        if center.isOn {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("AI apps allowed", comment: "Sidebar and menu-bar panel: Allow AI apps is on; a countdown follows")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: center.countdown)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                Spacer(minLength: 2)
                Button { center.turnOff() } label: {
                    Text("Stop", comment: "Button beside the Allow AI apps countdown: turns it off now")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.link)
                .tint(Theme.ball)
                .help(Text("Turn off Allow AI apps now", comment: "Tooltip on Stop beside the Allow AI apps countdown"))
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The text an AI app needs to find Glideball. Always this Glideball, where it is now.
enum AIAppsConnect {
    /// Renders and the self-test show where Glideball usually lives, not the sandbox copy.
    static var helperPath: String {
        Sandbox.isActive ? "/Applications/Glideball.app/Contents/MacOS/Glideball" : (Bundle.main.executablePath ?? "")
    }

    /// For a terminal: `claude mcp add glideball -- '/Applications/Glideball.app/…/Glideball' --mcp`.
    static func commandLine(_ path: String = helperPath) -> String {
        "claude mcp add glideball -- " + shellQuoted(path) + " --mcp"
    }

    /// The `mcpServers` entry most apps take.
    static func json(_ path: String = helperPath) -> String {
        // The path as a JSON string (a folder with a quote or a backslash in its name stays valid JSON).
        let quoted = (try? JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return """
        {
          "mcpServers": {
            "glideball": {
              "command": \(quoted),
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    /// One shell word, whatever is in the path (a folder someone named with a quote or a space).
    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        guard !Sandbox.isActive else { return true }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Connect an AI app…: two things to copy, and what they mean.
struct ConnectAIAppSheet: View {
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect an AI app")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Some AI apps can use tools on your Mac (it’s called MCP). Add Glideball to one and it can read your setup and suggest changes while Allow AI apps is on. You still approve every change in Glideball.",
                     comment: "Connect an AI app: what this is")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            snippet(title: Text(verbatim: "Claude Code"),
                    about: Text("Run this in Terminal:", comment: "Connect an AI app: above a command line to copy"),
                    text: AIAppsConnect.commandLine(), id: "ai-apps-command")
            snippet(title: Text("Claude’s desktop app and other apps", comment: "Connect an AI app: heading above the settings to copy"),
                    about: Text("Add this to the app’s MCP settings, then quit and reopen it. For Claude’s desktop app that’s the file claude_desktop_config.json in ~/Library/Application Support/Claude.",
                                comment: "Connect an AI app: above the JSON to copy; the file name and path stay as they are"),
                    text: AIAppsConnect.json(), id: "ai-apps-json")
            Hairline()
            HStack(alignment: .center, spacing: 12) {
                Label {
                    Text("Both point at where Glideball is now, so copy them again if you move or rename it. Glideball never changes another app’s settings itself. This is new and hasn’t been tried with every AI app yet.",
                         comment: "Connect an AI app: footer")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 620)
        .background(Theme.windowBackground)
        .copyStage()
    }

    private func snippet(title: Text, about: Text, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title.font(Theme.Font.body.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    about.font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(id: id, source: id, copy: { AIAppsConnect.copy(text) ? .copied(nil) : .failed })
                    .controlSize(.small)
            }
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copySource(id)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.groupFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.groupBorder, lineWidth: 0.5))
        }
    }
}

extension Findable {
    static let allowAIApps = Findable(
        id: "allow-ai-apps", title: String(localized: "Allow AI apps"),
        detail: String(localized: "Let an AI app on this Mac read your setup and suggest changes for 15 minutes.", comment: "Search palette: Allow AI apps"),
        keywords: String(localized: "ai, mcp, claude, assistant, agent, chatbot, model context protocol, local, suggest", comment: "Search words for Allow AI apps (comma-separated)"),
        symbol: "text.bubble", place: .settings(.general))
    static let connectAIApp = Findable(
        id: "connect-ai-app", title: String(localized: "Connect an AI app"),
        detail: String(localized: "What to copy into Claude or another AI app so it can find Glideball.", comment: "Search palette: Connect an AI app"),
        keywords: String(localized: "mcp, claude, claude code, cursor, server, config, json, command, terminal", comment: "Search words for Connect an AI app (comma-separated)"),
        symbol: "cable.connector.horizontal", place: .settings(.general))
}
