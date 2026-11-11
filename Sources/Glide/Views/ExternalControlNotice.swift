import AppKit
import SwiftUI

/// Shown the first time per launch that a glideball:// link tries to change
/// something while "Allow Raycast and scripts" is off (ExternalControlApp.swift).
/// It says what happened, that nothing changed, and where the switch is, with
/// a button that opens Settings › General and points at it.
struct ExternalControlNoticeView: View {
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: AppIconChoice.shared.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Something tried to control Glideball")
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("An app, a script or a web page opened a glideball:// link to change something. Glideball ignored it, because “Allow Raycast and scripts” is off.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("If that was you (from Raycast, say), turn it on in Settings › General.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Link(destination: SiteLinks.help) { Text("Learn more").font(Theme.Font.hint) }
                    .tint(Theme.ball)
                Spacer()
                Button("Not Now", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ball)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.windowBackground)
    }
}
