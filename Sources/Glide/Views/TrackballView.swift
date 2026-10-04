import SwiftUI

/// Live illustration of the Expert Mouse: the scroll ring turns as you spin it,
/// the ball's highlight drifts while it rolls, and buttons glow when pressed.
struct TrackballView: View {
    let pressed: Set<Int>
    let ballSpeed: Double
    let notchRate: Double
    let ringAngle: Double
    let ballPhase: Double

    // Button numbers as macOS sees them: 0 bottom-left, 1 bottom-right, 2 top-left, 3 top-right.
    private let pads: [(Int, Alignment)] = [(2, .topLeading), (3, .topTrailing), (0, .bottomLeading), (1, .bottomTrailing)]

    var body: some View {
        canvas.aspectRatio(1, contentMode: .fit)
    }

    private var canvas: some View {
        return GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Body
                RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                    .fill(.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1))

                // Buttons
                ForEach(pads, id: \.0) { index, alignment in
                    pad(index: index, size: s)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                        .padding(s * 0.05)
                }

                // Scroll ring
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.55)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: s * 0.06, dash: [2, 5])
                    )
                    .frame(width: s * 0.74, height: s * 0.74)
                    .rotationEffect(.degrees(ringAngle))
                    .shadow(color: .cyan.opacity(min(notchRate / 20, 0.9)), radius: 12)

                // Ball
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.75, blue: 1), Color(red: 0.25, green: 0.25, blue: 0.75), Color(red: 0.08, green: 0.06, blue: 0.25)],
                                         center: UnitPoint(x: 0.38 + 0.06 * sin(ballPhase), y: 0.32 + 0.06 * cos(ballPhase * 0.8)),
                                         startRadius: 2, endRadius: s * 0.34))
                    .overlay(
                        Ellipse()
                            .fill(.white.opacity(0.55))
                            .frame(width: s * 0.16, height: s * 0.08)
                            .blur(radius: 3)
                            .offset(x: -s * 0.08, y: -s * 0.13)
                    )
                    .frame(width: s * 0.58, height: s * 0.58)
                    .shadow(color: .purple.opacity(0.5 + min(ballSpeed / 10, 0.4)), radius: 18 + min(ballSpeed * 3, 20))
            }
            .frame(width: s, height: s)
        }
    }

    private func pad(index: Int, size s: CGFloat) -> some View {
        let on = pressed.contains(index)
        return RoundedRectangle(cornerRadius: s * 0.08, style: .continuous)
            .fill(on ? AnyShapeStyle(Color.cyan.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.1)))
            .frame(width: s * 0.26, height: s * 0.26)
            .shadow(color: on ? .cyan : .clear, radius: 14)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}
