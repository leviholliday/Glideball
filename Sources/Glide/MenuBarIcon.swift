import AppKit

/// Glideball's menu-bar icon, drawn in code: the Expert Mouse seen from above,
/// cut down to what makes it one. A ball, the scroll ring round it, and the
/// four buttons as pads in the corners. 18 × 18 pt, drawn fresh at whatever
/// scale the menu bar has (1x, 2x, 3x), with straight edges and stroke widths
/// snapped to whole pixels so it's as crisp as Apple's own glyphs beside it.
///
/// Each state changes one thing, so it reads at a glance:
///
/// | State | What changes |
/// |---|---|
/// | On | the plain glyph |
/// | Paused | a slash through it, like `bell.slash` |
/// | Precision on | the ball becomes a crosshair's dot |
/// | A mode held (drag lock, scroll with ball, a gesture) | the ball grows to fill the ring (a solid disc) |
/// | Not connected | an empty socket: the ball is an outline, the ring dashed |
/// | Update available | a dot in place of the top-right pad (with any of the above) |
///
/// Mono (the default) is a template image, so macOS tints it for light and
/// dark menu bars and for the highlighted state. Color paints the ball in the
/// person's ball color (Settings › Look) and the rest in the menu bar's text color.
enum MenuBarIcon {
    enum State: String, CaseIterable {
        case on, paused, precision, held, notConnected
    }

    enum Style: String, CaseIterable, Identifiable {
        case mono, color
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mono: String(localized: "Mono", comment: "Menu bar icon style: one color, like Apple's icons")
            case .color: String(localized: "Color", comment: "Menu bar icon style: the ball in your ball color")
            }
        }

        static let defaultsKey = "GlideMenuBarIconStyle"
        static var saved: Style {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(Style.init(rawValue:)) ?? .mono
        }
    }

    static let size = NSSize(width: 18, height: 18)

    /// What the icon should show for the model as it is now.
    static func state(of model: AppModel) -> State {
        if !model.config.enabled { return .paused }
        if !model.status.deviceConnected { return .notConnected }
        let m = model.modes
        if m.dragLocked || m.ballScrolling || m.gestureHeld { return .held }
        if m.precision { return .precision }
        return .on
    }

    /// VoiceOver's name for the icon in each state.
    static func description(_ state: State, update: Bool) -> String {
        let base: String
        switch state {
        case .on: base = String(localized: "Glideball", comment: "Menu bar icon, VoiceOver: on")
        case .paused: base = String(localized: "Glideball, paused", comment: "Menu bar icon, VoiceOver")
        case .precision: base = String(localized: "Glideball, Precision on", comment: "Menu bar icon, VoiceOver")
        case .held: base = String(localized: "Glideball, a mode is on", comment: "Menu bar icon, VoiceOver: drag lock, scroll with ball or a gesture is held")
        case .notConnected: base = String(localized: "Glideball, no trackball connected", comment: "Menu bar icon, VoiceOver")
        }
        return update ? String(localized: "\(base), update available", comment: "Menu bar icon, VoiceOver; %@ is the icon's state") : base
    }

    /// The icon. `theme` colors the ball in the Color style.
    static func image(_ state: State, update: Bool = false, style: Style = .mono, theme: BallTheme = .orb) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = max(1, ctx.userSpaceToDeviceSpaceTransform.a.magnitude.rounded())
            let ink: NSColor = style == .mono ? .black : .labelColor
            draw(state, update: update, in: ctx, rect: rect, scale: scale, ink: ink.cgColor,
                 ball: style == .color ? theme : nil)
            return true
        }
        image.isTemplate = style == .mono
        image.accessibilityDescription = description(state, update: update)
        return image
    }

    // MARK: Drawing

    /// The geometry, in points, for an 18 pt square (centre 9, 9).
    private enum G {
        static let ringRadius: CGFloat = 5.5    // centre of the ring's stroke
        static let ringWidth: CGFloat = 1.5
        static let ballRadius: CGFloat = 3
        static let padInner: CGFloat = 7.5      // pads start this far out (a clear gap past the ring)
        static let padInset: CGFloat = 1.5      // the pads' square: 1.5…16.5
        static let padCorner: CGFloat = 3.5
        static let padGap: CGFloat = 3.25       // half the gap between two pads, along each edge's middle
    }

    private static func draw(_ state: State, update: Bool, in ctx: CGContext, rect: CGRect, scale: CGFloat,
                             ink: CGColor, ball theme: BallTheme?) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Snaps a length to whole device pixels (never under one).
        func px(_ v: CGFloat) -> CGFloat { max(1, (v * scale).rounded()) / scale }
        // A radius whose stroke of width `w` has both edges on pixel boundaries (the centre is on one).
        func strokeRadius(_ r: CGFloat, _ w: CGFloat) -> CGFloat {
            let wp = (w * scale).rounded()
            let odd = Int(wp) % 2 == 1
            let rp = odd ? (r * scale - 0.5).rounded() + 0.5 : (r * scale).rounded()
            return rp / scale
        }
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let ringW = px(G.ringWidth)
        let ringR = strokeRadius(G.ringRadius, ringW)

        // The four pads: the rounded square's corners, outside a circle clear of the ring,
        // with the middle of each edge cut away.
        let square = rect.insetBy(dx: G.padInset, dy: G.padInset)
        let gap = px(G.padGap * 2) / 2
        let quadrants: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]   // TL, TR, BL, BR (flipped)
        for (i, q) in quadrants.enumerated() {
            if update && i == 1 { continue }   // the update dot takes the top-right corner
            let quarter = CGRect(x: q.0 < 0 ? square.minX : c.x + gap, y: q.1 < 0 ? square.minY : c.y + gap,
                                 width: square.width / 2 - gap, height: square.height / 2 - gap)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: square, cornerWidth: G.padCorner, cornerHeight: G.padCorner, transform: nil))
            ctx.clip()
            ctx.clip(to: quarter)
            // Everything outside the inner circle: the even-odd rule with the quarter and the circle.
            let p = CGMutablePath()
            p.addRect(quarter)
            p.addEllipse(in: circle(G.padInner))
            ctx.addPath(p)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        // The ring.
        ctx.setLineWidth(ringW)
        if state == .notConnected {
            // Dashed: an empty socket. Eight dashes, evenly round.
            let circumference = 2 * .pi * ringR
            let unit = circumference / 8
            ctx.setLineDash(phase: unit * 0.25, lengths: [unit * 0.55, unit * 0.45])
            ctx.strokeEllipse(in: circle(ringR))
            ctx.setLineDash(phase: 0, lengths: [])
        } else if state != .held {
            ctx.strokeEllipse(in: circle(ringR))
        }

        // The ball.
        switch state {
        case .on, .paused:
            fillBall(ctx, circle(G.ballRadius), theme: theme, dim: state == .paused)
        case .precision:
            // A crosshair: a small dot and four ticks in the gap.
            let dot = G.ballRadius * 0.42
            fillBall(ctx, circle(dot), theme: theme, dim: false)
            let w = px(1.25)
            let inner = dot + 1.1, outer = ringR - ringW / 2 - 0.9
            ctx.setLineWidth(w)
            ctx.setLineCap(.butt)
            // Ticks on the pixel grid: their centre line through the centre, which is on a pixel boundary,
            // so an odd width sits half a pixel off it.
            let shift = Int((w * scale).rounded()) % 2 == 1 ? 0.5 / scale : 0
            for (dx, dy) in [(0.0, -1.0), (0, 1), (-1, 0), (1, 0)] {
                let a = CGPoint(x: c.x + dx * inner + (dx == 0 ? shift : 0), y: c.y + dy * inner + (dy == 0 ? shift : 0))
                let b = CGPoint(x: c.x + dx * outer + (dx == 0 ? shift : 0), y: c.y + dy * outer + (dy == 0 ? shift : 0))
                ctx.move(to: a); ctx.addLine(to: b)
            }
            ctx.strokePath()
        case .held:
            // The ball grabbed: it fills the ring, one solid disc.
            // (A little inside the ring's outer edge, so the pads keep a clear gap at 1x.)
            let disc = (ringR * scale).rounded() / scale
            fillBall(ctx, circle(disc), theme: theme, dim: false)
            if theme != nil {
                // In color the disc is the ball, so a line in the ink goes round it.
                ctx.setLineWidth(px(1))
                ctx.strokeEllipse(in: circle(disc - px(1) / 2))
            }
        case .notConnected:
            let w = px(1.25)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: circle(strokeRadius(G.ballRadius - w / 2, w)))
        }

        // Paused: a slash from top left to bottom right, with a clear gap either side of it.
        if state == .paused {
            let a = CGPoint(x: rect.minX + 2.5, y: rect.minY + 2.5)
            let b = CGPoint(x: rect.maxX - 2.5, y: rect.maxY - 2.5)
            let w = px(1.5)
            ctx.setLineCap(.round)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(w + 2 * px(1.25))
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(w)
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.strokePath()
        }

        // Update available: a dot in the top-right corner, with a clear ring round it.
        if update {
            let r: CGFloat = 2.5
            let dc = CGPoint(x: rect.maxX - r - 0.5, y: rect.minY + r + 0.5)
            let dot = CGRect(x: dc.x - r, y: dc.y - r, width: 2 * r, height: 2 * r)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.25, dy: -1.25))
            ctx.setBlendMode(.normal)
            if theme != nil {
                ctx.setFillColor(NSColor.systemBlue.cgColor)
            }
            ctx.fillEllipse(in: dot)
        }
        ctx.endTransparencyLayer()
    }

    /// The ball: in the ink (mono), or the ball color's gradient (color).
    private static func fillBall(_ ctx: CGContext, _ r: CGRect, theme: BallTheme?, dim: Bool) {
        guard let theme else { ctx.fillEllipse(in: r); return }
        ctx.saveGState()
        ctx.addEllipse(in: r)
        ctx.clip()
        let p = theme.palette
        var stops = [p.light, p.mid, p.low]
        if dim {
            // Paused: grey glass, as the trackball goes.
            stops = stops.map { c in let y = 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; return OrbRGB(y, y, y) }
        }
        let colors = stops.map(\.nsColor.cgColor) as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) {
            // Lit from the top left (flipped: minY is the top).
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        }
        ctx.restoreGState()
    }
}
