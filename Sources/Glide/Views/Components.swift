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

/// A mode that's on right now (Precision, Drag lock…), shown in the header.
struct ModePill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(tint.opacity(0.35)), in: .capsule)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

// MARK: - Beta badge

/// A small "BETA" capsule for devices supported through the Beta program.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)))
            .help("Supported through the Beta program — you may hit bugs")
    }
}

// MARK: - Pointer speed presets

/// Precise / macOS / Fast / Turbo — used on the Pointer tab and in the Welcome Tour.
struct PointerPresetRow: View {
    @Binding var speed: Double

    private struct Preset: Identifiable {
        let name: String
        let symbol: String
        let speed: Double
        var id: String { name }
    }

    private let presets: [Preset] = [
        .init(name: "Precise", symbol: "scope", speed: 1.5),
        .init(name: "macOS", symbol: "applelogo", speed: 3),
        .init(name: "Fast", symbol: "hare", speed: 5),
        .init(name: "Turbo", symbol: "bolt", speed: 7.5),
    ]

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(presets) { p in
                    let selected = abs(speed - p.speed) < 0.01
                    let button = Button {
                        withAnimation(.smooth) { speed = p.speed }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: p.symbol).font(.system(size: 18))
                            Text(p.name).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if selected {
                        button.buttonStyle(.glassProminent).tint(.cyan.opacity(0.7))
                    } else {
                        button.buttonStyle(.glass)
                    }
                }
            }
        }
    }
}
