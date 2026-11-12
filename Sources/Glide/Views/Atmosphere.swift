import SwiftUI

// The stage the window is built on (design guide, version 2: "the trackball
// lights the room"). Near-black (or a soft cool white) with a soft aurora in the
// orb's colors behind the sidebar's trackball, a faint texture made from the
// scroll ring's own circles and ticks, and fine grain. All of that is drawn once
// and then holds perfectly still.
//
// On top sits the only part that ever changes: the light the hand makes. Roll
// the ball and the aurora warms blue, turn the ring and pink runs through it,
// click and a soft amber swells, each breathing back out over about a second
// (`LightField`). It's driven by the same live samples as the trackball, which
// only change while something moves and never while the window is hidden, so an
// idle trackball costs nothing. Minimal performance mode leaves it all static.

/// Where the light comes from: the sidebar trackball's center, in window points.
enum LightSource {
    static let sidebar = CGPoint(x: 118, y: 150)
}

/// The whole-window stage: static atmosphere plus the light that answers the hand.
struct Atmosphere: View {
    let model: AppModel
    /// The page on show: the aurora leans a little toward its part's color.
    var tab: GlideTab = .overview
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfProbe.count("Atmosphere")
        let dark = scheme == .dark
        ZStack {
            StaticAtmosphere(dark: dark, contrast: Theme.isHighContrastNow)
                .equatable()
            PageTint(tab: tab, dark: dark)
                .animation(reduceMotion ? Theme.Motion.fade : .easeInOut(duration: 0.5), value: tab)
            if model.performance != .minimal {
                HandLight(feed: model.live, pressed: model.pressed, dark: dark)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The part that never moves: base, aurora, ring texture, grain.
struct StaticAtmosphere: View, Equatable {
    let dark: Bool
    var contrast = false
    /// Where the aurora's heart is (the sidebar trackball by default).
    var center: CGPoint = LightSource.sidebar
    /// Or a point relative to the stage's size (a sheet's top, the tour's trackball).
    var anchor: UnitPoint? = nil
    /// How strong the light is (sheets and Settings use a gentler one).
    var strength = 1.0

    var body: some View {
        // Increase Contrast: the light steps back so text stays crisp.
        let k = contrast ? 0.5 : 1.0
        GeometryReader { geo in
            let c = anchor.map { CGPoint(x: geo.size.width * $0.x, y: geo.size.height * $0.y) } ?? center
            ZStack(alignment: .topLeading) {
                Theme.windowBackground
                // The aurora: the orb's colors, centered on the trackball, bleeding up and across the top.
                glow(Theme.orbBlue, dark ? 0.50 : 0.26, at: c, size: CGSize(width: 760, height: 660))
                glow(Theme.orbCyan, dark ? 0.16 : 0.16, at: CGPoint(x: c.x - 40, y: c.y - 70), size: CGSize(width: 420, height: 360))
                glow(Theme.orbViolet, dark ? 0.24 : 0.13, at: CGPoint(x: c.x + 330, y: c.y - 170), size: CGSize(width: 1100, height: 520))
                glow(Theme.orbMagenta, dark ? 0.11 : 0.07, at: CGPoint(x: c.x + 120, y: c.y + 330), size: CGSize(width: 620, height: 520))
                // A wide window (full screen on a big display): the light carries on across
                // the top, softer, so the far side is still the same room.
                if anchor == nil, geo.size.width > 1500 {
                    glow(Theme.orbViolet, dark ? 0.15 : 0.08, at: CGPoint(x: geo.size.width * 0.66, y: -60),
                         size: CGSize(width: geo.size.width * 0.75, height: 560))
                    glow(Theme.orbBlue, dark ? 0.09 : 0.05, at: CGPoint(x: geo.size.width - 140, y: geo.size.height * 0.55),
                         size: CGSize(width: 900, height: 900))
                }
                RingTexture(center: c, dark: dark)
                    .opacity(strength)
                Grain(dark: dark)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .overlay { if contrast { Theme.windowBackground.opacity(1 - k) } }
            // One flat bitmap, drawn when the window's size or look changes and never
            // otherwise: four big gradients, the ring texture and the grain's blend
            // used to be composited again under every frame of a scroll.
            .drawingGroup()
        }
    }

    private func glow(_ color: Color, _ amount: Double, at p: CGPoint, size: CGSize) -> some View {
        let strength = amount * self.strength
        return Rectangle()
            .fill(EllipticalGradient(colors: [color.opacity(strength), color.opacity(strength * 0.45), color.opacity(0)],
                                 center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: size.width, height: size.height)
            .position(p)
    }
}

/// Concentric circles like the scroll ring's, with its tick marks on every
/// fourth one, fading out away from the trackball: 2–4% at most.
private struct RingTexture: View {
    let center: CGPoint
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            let pixel = 1 / max(ctx.environment.displayScale, 1)
            let ink = dark ? Color.white : Color(red: 0.12, green: 0.14, blue: 0.3)
            let reach = 1150.0
            var r = 96.0, i = 0
            while r < reach {
                let fade = pow(1 - r / reach, 1.6)
                let a = (dark ? 0.045 : 0.06) * fade
                let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.stroke(circle, with: .color(ink.opacity(a)), lineWidth: pixel)
                if i % 4 == 1 {
                    // The ring's ticks: every 3°, every fifth one longer.
                    var ticks = Path()
                    for t in 0..<120 {
                        let ang = Double(t) * .pi / 60
                        let long = t % 5 == 0
                        let r0 = r - (long ? 7 : 4)
                        ticks.move(to: CGPoint(x: center.x + cos(ang) * r0, y: center.y + sin(ang) * r0))
                        ticks.addLine(to: CGPoint(x: center.x + cos(ang) * r, y: center.y + sin(ang) * r))
                    }
                    ctx.stroke(ticks, with: .color(ink.opacity(a * 0.9)), lineWidth: pixel)
                }
                r += 38 + Double(i) * 1.5
                i += 1
            }
        }
    }
}

/// Fine film grain over the stage (a fixed noise tile).
private struct Grain: View {
    let dark: Bool

    var body: some View {
        Image(decorative: Self.tile, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(dark ? 0.05 : 0.035)
            .blendMode(dark ? .plusLighter : .multiply)
    }

    /// 192×192 px of grey noise, made once.
    static let tile: CGImage = {
        let n = 192
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(n * n) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let v = UInt8(truncatingIfNeeded: s >> 24)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx!.makeImage()!
    }()
}

/// A wash in the page's part color across the top right of the content
/// (Pointer blue, Scrolling pink, Buttons amber; the orb's violet elsewhere).
private struct PageTint: View {
    let tab: GlideTab
    let dark: Bool

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(EllipticalGradient(colors: [tab.lightColor.opacity(dark ? 0.16 : 0.12), tab.lightColor.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: 840, height: 520)
                .position(x: geo.size.width - 120, y: -40)
        }
    }
}

extension GlideTab {
    /// The light a page leans toward: its part's color, or the orb's violet for the pages about everything.
    var lightColor: Color {
        switch self {
        case .pointer: Theme.orbBlue
        case .scroll: Theme.ring
        case .buttons: Theme.buttons
        case .overview, .apps, .backup: Theme.orbViolet
        }
    }
}

/// The light the hand makes, over the whole window: a bloom at the trackball
/// plus a fainter echo across the top of the content, so the whole room warms.
private struct HandLight: View {
    let feed: LiveFeed
    let pressed: Set<Int>
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            LightBloom(feed: feed, pressed: pressed, dark: dark, size: 820)
                .position(LightSource.sidebar)
            GeometryReader { geo in
                LiveLight(feed: feed) { l in
                    Rectangle()
                        .fill(EllipticalGradient(colors: [Theme.ball.opacity(l.ball * 0.16 + l.ring * 0.02),
                                                      Theme.ring.opacity(l.ring * 0.11), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                        .frame(width: 1040, height: 460)
                        .position(x: geo.size.width * 0.62, y: -30)
                        .blendMode(dark ? .plusLighter : .normal)
                }
            }
        }
    }
}

/// Redraws `content` with the hand's light levels, on a timeline that runs only
/// while the light is awake (`LiveFeed.lightAwake`); at rest it's paused.
struct LiveLight<Content: View>: View {
    let feed: LiveFeed
    @ViewBuilder var content: (LightField.Levels) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !feed.lightAwake)) { _ in
            content(feed.lightLevels())
        }
    }
}

/// The hand's light as a bloom centered in a square of side `size`: blue for
/// rolling (leaning the way the ball rolls), pink for the ring, amber for a
/// click, each decaying on its own (`LightField`). A held button keeps its amber lit.
struct LightBloom: View {
    let feed: LiveFeed
    let pressed: Set<Int>
    let dark: Bool
    var size: CGFloat = 820
    /// How strong, relative to the room's own bloom.
    var strength = 1.0

    var body: some View {
        LiveLight(feed: feed) { l in
            let amber = max(l.amber, pressed.isEmpty ? 0 : 0.5 * feed.lightIntensity / AppModel.defaultLightIntensity)
            let lean = CGSize(width: l.roll.dx * size * 0.08 * l.ball, height: l.roll.dy * size * 0.06 * l.ball)
            ZStack {
                light(Theme.ball, l.ball * (dark ? 0.55 : 0.30), offset: lean)
                light(Theme.ring, l.ring * (dark ? 0.55 : 0.30), offset: .zero, scale: 0.93)
                light(Theme.buttons, amber * (dark ? 0.62 : 0.34), offset: .zero, scale: 0.9)
            }
            .frame(width: size, height: size)
            .blendMode(dark ? .plusLighter : .normal)
        }
        .animation(.easeOut(duration: pressed.isEmpty ? 0.6 : 0.12), value: pressed.isEmpty)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func light(_ color: Color, _ amount: Double, offset: CGSize, scale: CGFloat = 1) -> some View {
        Rectangle()
            .fill(EllipticalGradient(colors: [color.opacity(1), color.opacity(0.35), color.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: size * scale, height: size * scale * 0.86)
            .offset(offset)
            .opacity(amount * strength)
    }
}

extension Theme {
    /// Increase Contrast is on (read where there's no NSAppearance at hand).
    static var isHighContrastNow: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}
