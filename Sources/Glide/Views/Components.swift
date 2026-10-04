import SwiftUI

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: .rect(cornerRadius: 26))
    }
}

// MARK: - Slider row

struct TuningSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var lowLabel: String? = nil
    var highLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)
            }
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .controlSize(.large)
            if lowLabel != nil || highLabel != nil {
                HStack {
                    Text(lowLabel ?? "")
                    Spacer()
                    Text(highLabel ?? "")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Background

struct GlideBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let colors: [Color] = dark ? [
            Color(red: 0.06, green: 0.07, blue: 0.20), Color(red: 0.18, green: 0.10, blue: 0.42), Color(red: 0.05, green: 0.16, blue: 0.30),
            Color(red: 0.10, green: 0.30, blue: 0.55), Color(red: 0.38, green: 0.18, blue: 0.62), Color(red: 0.05, green: 0.38, blue: 0.48),
            Color(red: 0.08, green: 0.10, blue: 0.24), Color(red: 0.55, green: 0.20, blue: 0.48), Color(red: 0.06, green: 0.14, blue: 0.28),
        ] : [
            Color(red: 0.80, green: 0.86, blue: 1.00), Color(red: 0.90, green: 0.82, blue: 1.00), Color(red: 0.78, green: 0.95, blue: 0.98),
            Color(red: 0.70, green: 0.82, blue: 1.00), Color(red: 0.95, green: 0.80, blue: 0.95), Color(red: 0.72, green: 0.94, blue: 0.90),
            Color(red: 0.88, green: 0.90, blue: 1.00), Color(red: 1.00, green: 0.86, blue: 0.86), Color(red: 0.84, green: 0.92, blue: 1.00),
        ]
        // The centre point drifts slowly. 20 fps is indistinguishable for motion
        // this slow and keeps the glass on top from re-rendering 120 times a second.
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * .pi / 9) + 1) / 2          // 0…1 and back every 18 s
            let x = Float(0.38 + 0.24 * phase), y = Float(0.6 - 0.18 * phase)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [x, y], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: colors
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}
