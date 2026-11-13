import AppKit

/// `--render-ui`'s `menubar-icons`: every state of the menu-bar icon on a light
/// and a dark menu bar, Mono and Color, drawn at 1x and 2x and blown up with
/// no smoothing so each pixel shows, next to Apple's own glyphs (and the old
/// icon) at their menu-bar size. Then the same strips at their real size.
extension RenderUI {
    static func menuBarIconSheet(dark: Bool) -> NSBitmapImageRep? {
        let states: [(MenuBarIcon.State, Bool)] = MenuBarIcon.State.allCases.map { ($0, false) } + MenuBarIcon.State.allCases.map { ($0, true) }
        let symbols = ["wifi", "battery.75percent", "speaker.wave.2.fill", "magnifyingglass", "cursorarrow.click"]
        let itemW: CGFloat = 26, barH: CGFloat = 24
        let stripW = CGFloat(symbols.count + states.count) * itemW + 16 + 12
        let labelW: CGFloat = 170
        let rowH = barH * 4 + 14
        let combos: [(Bool, MenuBarIcon.Style)] = [(false, .mono), (true, .mono), (false, .color), (true, .color)]
        let sheetW = labelW + stripW * 4 + 40
        let header: CGFloat = 70
        let realH: CGFloat = 4 * (barH + 10) + 40
        let sheetH = header + CGFloat(combos.count * 2) * rowH + realH + 30
        let px = 2.0   // the sheet itself is drawn at 2x

        guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sheetW * px), pixelsHigh: Int(sheetH * px),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        sheet.size = NSSize(width: sheetW, height: sheetH)
        let saved = NSGraphicsContext.current
        defer { NSGraphicsContext.current = saved }
        guard let base = NSGraphicsContext(bitmapImageRep: sheet) else { return nil }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: sheetH)
        cg.scaleBy(x: 1, y: -1)
        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = ctx

        let text = dark ? NSColor.white : NSColor.black
        (dark ? NSColor(srgbHex: 0x121216) : NSColor(srgbHex: 0xF4F4F7)).setFill()
        NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()
        func label(_ s: String, _ p: NSPoint, size: CGFloat = 12, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: text.withAlphaComponent(alpha)])
                .draw(with: NSRect(x: p.x, y: p.y, width: 900, height: size * 1.4), options: [.usesLineFragmentOrigin], context: nil)
        }
        func flippedDraw(_ rep: NSBitmapImageRep, in r: NSRect, smooth: Bool) {
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            rep.draw(in: r, from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: smooth ? 3 : 0)])
        }

        label("Menu bar icon", NSPoint(x: 20, y: 16), size: 20, weight: .semibold)
        label("Apple’s wifi, battery, sound and search, the old icon, | on, paused, Precision, a mode held, not connected; then the same with an update. Blown up: 1x ×4, 2x ×2.",
              NSPoint(x: 20, y: 44), size: 12, alpha: 0.6)

        var y = header
        for (barDark, style) in combos {
            for scale in [1.0, 2.0] {
                let name = "\(barDark ? "Dark" : "Light") bar · \(style.title) · \(Int(scale))x"
                label(name, NSPoint(x: 20, y: y + rowH / 2 - 10), size: 13, weight: .medium)
                if let strip = menuBarStrip(states: states, symbols: symbols, dark: barDark, style: style, scale: scale,
                                            itemW: itemW, barH: barH, width: stripW) {
                    // Both blown up to the same size: a 1x pixel is 4 points here, a 2x pixel 2.
                    flippedDraw(strip, in: NSRect(x: labelW, y: y, width: stripW * 4, height: barH * 4), smooth: false)
                }
                y += rowH
            }
        }
        label("Real size (2x)", NSPoint(x: 20, y: y + 6), size: 13, weight: .medium)
        y += 30
        for (barDark, style) in combos {
            if let strip = menuBarStrip(states: states, symbols: symbols, dark: barDark, style: style, scale: 2,
                                        itemW: itemW, barH: barH, width: stripW) {
                flippedDraw(strip, in: NSRect(x: labelW, y: y, width: stripW, height: barH), smooth: true)
            }
            label("\(barDark ? "Dark" : "Light") · \(style.title)", NSPoint(x: 20, y: y + 4), size: 12, alpha: 0.7)
            y += barH + 10
        }
        ctx.flushGraphics()
        return sheet
    }

    /// One menu bar: Apple's glyphs, then each state, drawn at `scale` the way the menu bar
    /// draws a status item (template images in the bar's text color).
    private static func menuBarStrip(states: [(MenuBarIcon.State, Bool)], symbols: [String], dark: Bool, style: MenuBarIcon.Style,
                                     scale: CGFloat, itemW: CGFloat, barH: CGFloat, width: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(barH * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: barH)
        let saved = NSGraphicsContext.current
        defer { NSGraphicsContext.current = saved }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            // macOS 26's menu bar: a light or dark wash over the wallpaper.
            (dark ? NSColor(srgbHex: 0x26262C) : NSColor(srgbHex: 0xE9E9EE)).setFill()
            NSRect(x: 0, y: 0, width: width, height: barH).fill()
            let ink = dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.85)
            var x: CGFloat = 8
            func place(_ image: NSImage) {
                let s = image.size
                // Whole points, as the status bar button centres it.
                let r = NSRect(x: (x + (itemW - s.width) / 2).rounded(), y: ((barH - s.height) / 2).rounded(), width: s.width, height: s.height)
                if image.isTemplate {
                    let tinted = NSImage(size: s, flipped: false) { b in
                        image.draw(in: b)
                        ink.set()
                        b.fill(using: .sourceIn)
                        return true
                    }
                    tinted.draw(in: r)
                } else {
                    image.draw(in: r)
                }
                x += itemW
            }
            for name in symbols {
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                    img.isTemplate = true
                    place(img)
                }
            }
            ink.withAlphaComponent(0.25).setFill()
            NSRect(x: x + 5, y: 5, width: 1, height: barH - 10).fill()
            x += 12
            for (state, update) in states {
                place(MenuBarIcon.image(state, update: update, style: style, theme: BallTheme.current))
            }
        }
        ctx.flushGraphics()
        return rep
    }
}
