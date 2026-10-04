// Renders Resources/AppIcon.icns — a glassy trackball on a deep violet squircle.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let cs = CGColorSpaceCreateDeviceRGB()

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

    // macOS icon grid: 824/1024 body with a drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.45))
    ctx.addPath(squircle); ctx.setFillColor(color(0.1, 0.06, 0.25)); ctx.fillPath()
    ctx.restoreGState()

    // Background: violet → indigo → teal.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0.42, 0.16, 0.78), color(0.16, 0.12, 0.52), color(0.04, 0.34, 0.52)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft glow blobs for a glassy, layered feel.
    for (x, y, r, c) in [(0.25, 0.78, 0.45, color(1, 0.45, 0.85, 0.45)), (0.82, 0.22, 0.5, color(0.2, 0.9, 1, 0.35))] as [(CGFloat, CGFloat, CGFloat, CGColor)] {
        let center = CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
        let g = CGGradient(colorsSpace: cs, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: body.width * r, options: [])
    }

    let c = CGPoint(x: body.midX, y: body.midY)

    // Frosted glass ring (the scroll ring).
    let ringR = body.width * 0.36
    let ringW = body.width * 0.075
    ctx.saveGState()
    ctx.setLineWidth(ringW)
    ctx.setStrokeColor(color(1, 1, 1, 0.22))
    ctx.addArc(center: c, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    // Ring ridges
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.setStrokeColor(color(1, 1, 1, 0.35))
    for i in 0..<36 {
        let a = CGFloat(i) / 36 * .pi * 2
        ctx.move(to: CGPoint(x: c.x + cos(a) * (ringR - ringW * 0.35), y: c.y + sin(a) * (ringR - ringW * 0.35)))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * (ringR + ringW * 0.35), y: c.y + sin(a) * (ringR + ringW * 0.35)))
    }
    ctx.strokePath()
    // Ring highlight edge
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.setStrokeColor(color(1, 1, 1, 0.6))
    ctx.addArc(center: c, radius: ringR + ringW / 2, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // The ball.
    let ballR = body.width * 0.265
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.05, color: color(0.05, 0, 0.2, 0.7))
    ctx.addArc(center: c, radius: ballR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(color(0.2, 0.2, 0.6)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addArc(center: c, radius: ballR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    let ballG = CGGradient(colorsSpace: cs, colors: [color(0.62, 0.86, 1), color(0.36, 0.42, 0.95), color(0.18, 0.1, 0.5), color(0.06, 0.03, 0.2)] as CFArray,
                           locations: [0, 0.35, 0.75, 1])!
    let hl = CGPoint(x: c.x - ballR * 0.35, y: c.y + ballR * 0.4)
    ctx.drawRadialGradient(ballG, startCenter: hl, startRadius: 0, endCenter: c, endRadius: ballR * 1.05, options: [.drawsAfterEndLocation])
    // Specular highlight
    let spec = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.9), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    let sp = CGPoint(x: c.x - ballR * 0.32, y: c.y + ballR * 0.48)
    ctx.drawRadialGradient(spec, startCenter: sp, startRadius: 0, endCenter: sp, endRadius: ballR * 0.42, options: [])
    // Rim light
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.setStrokeColor(color(0.6, 0.95, 1, 0.55))
    ctx.addArc(center: c, radius: ballR - s * 0.003, startAngle: -.pi * 0.45, endAngle: .pi * 0.05, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Glass sheen across the top of the icon.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY + body.height * 0.1), options: [])
    ctx.restoreGState()

    // Hairline border
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(1, 1, 1, 0.25))
    ctx.setLineWidth(max(1, s * 0.003))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(iconset.path)")
