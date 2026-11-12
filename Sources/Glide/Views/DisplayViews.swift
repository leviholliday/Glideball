import SwiftUI

// Per-display pointer speed on the Pointer page: a switch, then a row for each
// connected display with a tiny picture of the arrangement (that display lit),
// its own speed slider, where the pointer is now, and "Use main speed".

struct DisplaySpeedsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let displays = model.displays
        let enabled = model.config.displaySpeeds.enabled
        SectionBlock(title: "Speed for each display",
                     caption: "A big display far away and a laptop screen up close can each have their own speed. An app setup with its own speed still wins.") {
            ToggleRow(title: "A speed for each display", subtitle: .verbatim(hint(displays: displays, enabled: enabled)),
                      symbol: "display.2", isOn: $model.config.displaySpeeds.enabled)
            if displays.count < 2 {
                HStack(spacing: Theme.Space.symbolGap) {
                    DisplayArrangement(displays: displays, highlight: nil, pointer: nil)
                        .frame(width: Theme.Space.symbolColumn, height: 16)
                    Text("Connect another display to set a speed for each.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.rowHorizontal)
                .padding(.vertical, Theme.Space.rowVertical)
                .frame(minHeight: Theme.Space.rowMinHeight)
            } else if enabled {
                ForEach(displays) { display in
                    DisplaySpeedRow(model: model, display: display, displays: displays)
                }
            }
        }
        .animation(Theme.Motion.spring, value: enabled)
    }

    private func hint(displays: [DisplayInfo], enabled: Bool) -> String {
        guard enabled else {
            return String(localized: "Off: every display uses your main tracking speed.", comment: "Hint under the per-display speed switch")
        }
        if displays.count < 2 {
            return String(localized: "On, but there’s only one display right now, so it uses your main speed.", comment: "Hint under the per-display speed switch")
        }
        let own = displays.filter { model.config.displaySpeeds.speeds[$0.key] != nil }.count
        if own == 0 {
            return String(localized: "On. Move a slider below to give that display its own speed.", comment: "Hint under the per-display speed switch")
        }
        return String(localized: "The speed changes as the pointer moves from one display to the next.", comment: "Hint under the per-display speed switch")
    }
}

/// One display: the arrangement with it lit, its name, whether the pointer's on
/// it, its speed (the same instrument slider), and "Use main speed".
private struct DisplaySpeedRow: View {
    let model: AppModel
    let display: DisplayInfo
    let displays: [DisplayInfo]
    @State private var dragging = false

    var body: some View {
        let own = model.config.displaySpeeds.speeds[display.key]
        let main = model.config.trackingSpeed
        let speed = own ?? main
        let here = model.status.pointerDisplay == display.key
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
                DisplayArrangement(displays: displays, highlight: display.key, pointer: model.status.pointerDisplay)
                    .frame(width: 46, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: display.name)
                            .font(Theme.Font.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if display.isMain {
                            Text("Main display")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.groupFill))
                                .pixelBorder(Capsule(), Theme.groupBorder)
                                .fixedSize()
                        }
                    }
                    if here {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.ball).frame(width: 6, height: 6)
                                .shadow(color: Theme.ball, radius: 3)
                            Text("The pointer is here now")
                        }
                        .font(Theme.Font.hint)
                        .foregroundStyle(Theme.ball)
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: speed.twoDigits)
                    .font(Theme.Font.value)
                    .foregroundStyle(dragging ? AnyShapeStyle(Theme.ball) : own == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText(value: speed))
                    .animation(.snappy(duration: 0.18), value: speed)
                if own != nil {
                    Button("Use Main Speed") {
                        withAnimation(Theme.Motion.spring) { model.clearDisplaySpeed(for: display) }
                    }
                    .controlSize(.small)
                    .help("This display goes back to your main tracking speed")
                }
            }
            InstrumentSlider(value: Binding(get: { speed }, set: { model.setDisplaySpeed(Self.snap($0), for: display) }),
                             range: 0.5...80, step: 0.5, tint: Theme.ball, defaultValue: main,
                             label: Text(verbatim: display.name), valueText: speed.twoDigits,
                             defaultText: main.twoDigits, dragging: $dragging)
                .opacity(own == nil && !dragging ? 0.7 : 1)
                .padding(.leading, 46 + Theme.Space.symbolGap)
            Text(verbatim: hint(own: own, main: main, here: here))
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 46 + Theme.Space.symbolGap)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 12)
        .background(Theme.ball.opacity(here ? 0.05 : 0))
        .animation(Theme.Motion.fade, value: here)
    }

    private static func snap(_ v: Double) -> Double { min(max((v / 0.5).rounded() * 0.5, 0.5), 80) }

    /// Talks about now: what this display's speed means next to the main one.
    private func hint(own: Double?, main: Double, here: Bool) -> String {
        guard let own else {
            return String(localized: "Uses your main speed. Drag to give this display its own.", comment: "Hint under a display's speed slider")
        }
        let ratio = own / main
        if abs(ratio - 1) < 0.02 {
            return String(localized: "The same as your main speed.", comment: "Hint under a display's speed slider")
        }
        if ratio > 1 {
            return here
                ? String(localized: "\(ratio.decimals(1))× your main speed, right now.", comment: "Hint under a display's speed slider; %@ is a multiple, like 1.5")
                : String(localized: "\(ratio.decimals(1))× your main speed while the pointer is on it.", comment: "Hint under a display's speed slider; %@ is a multiple, like 1.5")
        }
        return here
            ? String(localized: "\(ratio.wholePercent) of your main speed, right now.", comment: "Hint under a display's speed slider; %@ is a percentage")
            : String(localized: "\(ratio.wholePercent) of your main speed while the pointer is on it.", comment: "Hint under a display's speed slider; %@ is a percentage")
    }
}

/// The display arrangement, tiny and to scale: every display as a rounded
/// rectangle where it really sits, the highlighted one filled in ball blue, and a
/// dot on the one the pointer's on.
struct DisplayArrangement: View {
    let displays: [DisplayInfo]
    let highlight: String?
    let pointer: String?

    var body: some View {
        Canvas { ctx, size in
            let frames = displays.map(\.frame).filter { !$0.isEmpty }
            guard !frames.isEmpty else {
                // Nothing known about where it is: one display.
                let r = CGRect(x: size.width * 0.12, y: size.height * 0.15, width: size.width * 0.76, height: size.height * 0.62)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 2.5), with: .color(Color.secondary.opacity(0.55)), lineWidth: 1)
                return
            }
            let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            let pad: CGFloat = 1.5
            let k = min((size.width - pad * 2) / union.width, (size.height - pad * 2) / union.height)
            let ox = (size.width - union.width * k) / 2, oy = (size.height - union.height * k) / 2
            for d in displays where !d.frame.isEmpty {
                let r = CGRect(x: ox + (d.frame.minX - union.minX) * k, y: oy + (d.frame.minY - union.minY) * k,
                               width: d.frame.width * k, height: d.frame.height * k).insetBy(dx: 0.75, dy: 0.75)
                let path = Path(roundedRect: r, cornerRadius: min(2.5, r.height * 0.15))
                if d.key == highlight {
                    ctx.fill(path, with: .color(Theme.ball.opacity(0.9)))
                } else {
                    ctx.fill(path, with: .color(Theme.groupFill))
                    ctx.stroke(path, with: .color(Color.secondary.opacity(0.55)), lineWidth: 1)
                }
                if d.key == pointer {
                    let dot = CGRect(x: r.midX - 2.5, y: r.midY - 2.5, width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white.opacity(d.key == highlight ? 0.9 : 0)))
                    ctx.fill(Path(ellipseIn: dot), with: .color(d.key == highlight ? Theme.ball : Theme.ball.opacity(0.9)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
