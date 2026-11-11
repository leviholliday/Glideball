// Renders the Glideball app icon.
//
//   swift scripts/make-icon.swift [root]                  classic icon -> <root>/build/AppIcon.iconset (what build.sh uses)
//   swift scripts/make-icon.swift --style orb-b --icns out.icns --png-dir brand/icon-candidates
//   swift scripts/make-icon.swift --sheet brand/icon-candidates/sheet.png
//
// Options
//   --style classic|orb-a|orb-b|orb-c   which icon (default classic)
//   --iconset DIR                        write an .iconset folder (default <root>/build/AppIcon.iconset when no other output is given)
//   --icns FILE                          write a full .icns (via iconutil)
//   --png FILE                           write the 1024 px PNG
//   --png-dir DIR                        write <style>-<size>.png for 16...1024
//   --sheet FILE                         contact sheet: every style large, then 16-256 on dark and light
//
// Styles
//   classic  the original glassy trackball on a violet squircle
//   orb-a    a polished orb on a near-black tile, soft outer glow
//   orb-b    the same orb inside a thin luminous scroll ring
//   orb-c    the orb seated in a shallow socket with a fine bezel
import AppKit

// MARK: - Arguments

var root = URL(fileURLWithPath: ".")
var style = "classic"
var iconsetOut: URL?
var icnsOut: URL?
var pngOut: URL?
var pngDir: URL?
var sheetOut: URL?
do {
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { fatalError("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--style": style = next(a)
        case "--iconset": iconsetOut = URL(fileURLWithPath: next(a))
        case "--icns": icnsOut = URL(fileURLWithPath: next(a))
        case "--png": pngOut = URL(fileURLWithPath: next(a))
        case "--png-dir": pngDir = URL(fileURLWithPath: next(a))
        case "--sheet": sheetOut = URL(fileURLWithPath: next(a))
        default:
            if a.hasPrefix("--") { fatalError("unknown option \(a)") }
            root = URL(fileURLWithPath: a)
        }
    }
    guard ["classic", "orb-a", "orb-b", "orb-c"].contains(style) else { fatalError("unknown style \(style)") }
    if iconsetOut == nil && icnsOut == nil && pngOut == nil && pngDir == nil && sheetOut == nil {
        iconsetOut = root.appendingPathComponent("build/AppIcon.iconset")
    }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

// MARK: - Classic (unchanged drawing)

func drawClassic(_ px: Int, _ ctx: CGContext) {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()

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
}

// MARK: - Orb styles

// Tiny vector maths; everything below is in "design units" (a 1024 canvas, y up, origin at the centre).
struct V3 { var x, y, z: Double }
func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
func * (a: V3, k: Double) -> V3 { V3(x: a.x * k, y: a.y * k, z: a.z * k) }
func * (a: V3, b: V3) -> V3 { V3(x: a.x * b.x, y: a.y * b.y, z: a.z * b.z) }
func dot(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
func norm(_ a: V3) -> V3 { a * (1 / sqrt(dot(a, a))) }
// Colours are written in sRGB and shaded in linear light.
func rgb(_ r: Double, _ g: Double, _ b: Double) -> V3 { V3(x: pow(r, 2.2), y: pow(g, 2.2), z: pow(b, 2.2)) }
func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * t }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
func smooth(_ e0: Double, _ e1: Double, _ v: Double) -> Double { let t = clamp01((v - e0) / (e1 - e0)); return t * t * (3 - 2 * t) }
func gauss(_ dx: Double, _ dy: Double, _ s: Double) -> Double { exp(-(dx * dx + dy * dy) / (s * s)) }

// Palette (from Levi's mock-up): cyan/blue top, magenta/violet bottom.
let cCyan = rgb(0.24, 0.80, 1.00)
let cIce = rgb(0.52, 0.93, 1.00)
let cBlue = rgb(0.20, 0.40, 1.00)
let cDeepBlue = rgb(0.13, 0.22, 0.90)
let cViolet = rgb(0.42, 0.20, 0.92)
let cMagenta = rgb(0.98, 0.32, 0.86)
let cLilac = rgb(0.80, 0.58, 1.00)
let cRimDark = rgb(0.09, 0.05, 0.30)

let light = norm(V3(x: -0.52, y: 0.62, z: 0.59))            // top-left, toward the viewer
let halfway = norm(light + V3(x: 0, y: 0, z: 1))

struct OrbParams {
    var ballR: Double
    var ring = false, ringR = 0.0, ringW = 0.0
    var socket = false, socketR = 0.0, bezelW = 0.0
    var glow = 1.0            // outer glow strength
    var small = false         // 16/32 px drawing
}

func params(_ style: String, _ px: Int) -> OrbParams {
    let small = px <= 40
    switch style {
    case "orb-a":
        return OrbParams(ballR: small ? 300 : 262, glow: 1, small: small)
    case "orb-b":
        if px <= 20 { return OrbParams(ballR: 300, glow: 1, small: true) }
        if small { return OrbParams(ballR: 262, ring: true, ringR: 336, ringW: 30, glow: 0.8, small: true) }
        return OrbParams(ballR: 236, ring: true, ringR: 322, ringW: px <= 72 ? 16 : 11, glow: 0.8, small: false)
    default: // orb-c
        if small { return OrbParams(ballR: 272, socket: true, socketR: 300, bezelW: px <= 20 ? 0 : 30, glow: 0.35, small: true) }
        return OrbParams(ballR: 250, socket: true, socketR: 270, bezelW: px <= 72 ? 20 : 13, glow: 0.35, small: false)
    }
}

// The coloured liquid inside the ball, in ball space (unit disc, y up).
func liquid(_ qx: Double, _ qy: Double) -> V3 {
    let wx = qx + 0.16 * sin(2.6 * qy + 0.8) + 0.05 * sin(5.3 * qy - 1.3)
    let wy = qy + 0.13 * sin(2.3 * qx - 0.5) + 0.045 * cos(4.9 * qx + 0.9)
    let t = smooth(-0.95, 0.9, wy)
    var c = t < 0.5 ? mix(cViolet, cBlue, t / 0.5) : mix(cBlue, cCyan, (t - 0.5) / 0.5)
    c = mix(c, cDeepBlue, 0.45 * gauss(wx + 0.62, wy - 0.02, 0.34))
    c = mix(c, cBlue, 0.55 * gauss(wx - 0.62, wy - 0.42, 0.38))
    c = mix(c, cIce, 0.55 * gauss(wx + 0.08, wy - 0.52, 0.36))
    c = mix(c, cLilac, 0.38 * gauss(wx - 0.52, wy + 0.04, 0.34))
    c = mix(c, cMagenta, 0.88 * gauss(wx + 0.40, wy + 0.52, 0.40))
    return c
}

// Colour of the polished ball at a point of the unit disc.
func ballColor(_ bx: Double, _ by: Double, _ p: OrbParams) -> V3 {
    let r = min(1, sqrt(bx * bx + by * by))
    let z = sqrt(max(0, 1 - r * r))
    let n = V3(x: bx, y: by, z: z)
    // Refraction: the liquid near the rim is pulled inward, like looking into a clear marble,
    // and a deeper layer of the same liquid shows through the middle.
    let k = 0.80 + 0.20 * z
    var c = liquid(bx * k, by * k)
    c = mix(c, liquid(bx * 0.55 - 0.08, by * 0.55 + 0.05), 0.16 * z)
    // Body shading, lit from the top-left; the far side keeps a little inner glow.
    let diff = max(0, dot(n, light))
    c = c * ((0.18 + 0.95 * diff) * (0.85 + 0.30 * z))
    // Shadows turn indigo rather than grey.
    c = c + rgb(0.30, 0.14, 0.70) * (0.22 * (1 - diff))
    // Light focused through the ball gathers inside its lower right.
    c = c + cLilac * (0.14 * gauss(bx - 0.36, by + 0.44, 0.36))
    // Absorption toward the rim, into a saturated deep indigo (never grey).
    let rim = pow(1 - z, 2.0)
    let shadowSide = clamp01(0.5 - 0.5 * (bx * light.x + by * light.y) / max(r, 1e-6) * 1.4)
    c = mix(c, cRimDark, rim * (0.30 + 0.50 * shadowSide))
    // Fresnel: a cool sky reflection on the lit rim, dark room below.
    let env = mix(rgb(0.03, 0.02, 0.08), rgb(0.62, 0.82, 1.0), smooth(0.0, 0.9, 0.75 * n.y - 0.45 * n.x))
    let f = 0.02 + 0.55 * pow(1 - z, 4)
    c = c * (1 - f) + env * f
    // Bounce light from the glow (or socket) along the lower-right rim.
    let br = smooth(0.80, 0.985, r) * clamp01((bx - by) / 1.414 / max(r, 1e-6))
    c = c + (p.socket ? rgb(0.30, 0.20, 0.50) : rgb(0.55, 0.35, 0.95)) * (br * (p.socket ? 0.10 : 0.22))
    if p.socket { c = c * (1 - 0.30 * smooth(0.7, 1.0, r) * clamp01(-by / max(r, 1e-6) + 0.2)) }
    // One soft specular highlight.
    let ndh = max(0, dot(n, halfway))
    let spec = p.small ? 0.80 * pow(ndh, 28) + 0.12 * pow(ndh, 6)
                       : 0.65 * pow(ndh, 220) + 0.30 * pow(ndh, 40) + 0.07 * pow(ndh, 8)
    c = c + rgb(1, 1, 1) * spec
    // A fine cool rim along the lit edge keeps the silhouette crisp against the glow.
    if !p.small {
        let toward = (bx * light.x + by * light.y) / max(r, 1e-6) / sqrt(light.x * light.x + light.y * light.y)
        c = c + rgb(0.62, 0.85, 1.0) * (0.24 * smooth(0.968, 0.994, r) * smooth(-0.1, 0.9, toward))
    }
    return c
}

// Soft shoulder so bright areas roll off instead of clipping.
func tone(_ v: Double) -> Double { pow(max(0, v < 0.8 ? v : 0.8 + 0.2 * (1 - exp(-(v - 0.8) / 0.2))), 1 / 2.2) }

// One sample of the tile at (x, y). `pw` is the pixel width in design units (for edge anti-aliasing).
func orbSample(_ x: Double, _ y: Double, _ p: OrbParams, _ pw: Double) -> V3 {
    let d = sqrt(x * x + y * y)
    let dir = (x: d > 0 ? x / d : 0, y: d > 0 ? y / d : 0)
    let lit = dir.x * light.x + dir.y * light.y          // +1 facing the light (top-left)
    let lxy = sqrt(light.x * light.x + light.y * light.y)
    let towardLight = lit / lxy                           // -1 ... 1
    func cover(_ sd: Double) -> Double { clamp01(0.5 - sd / pw) }

    // Near-black blue-violet tile with a faint vignette, a touch lighter at the top.
    let v = sqrt(x * x + (y + 30) * (y + 30)) / 430
    var c = mix(rgb(0.082, 0.072, 0.150), rgb(0.030, 0.026, 0.064), smooth(0.15, 1.45, v))
    c = c * (1 + 0.10 * y / 412)

    // Outer glow: blue above, violet/magenta below, weighted toward the lower right.
    if p.glow > 0 {
        let gx = x - 8, gy = y + 16
        let gd = sqrt(gx * gx + gy * gy)
        let o = max(0, gd - p.ballR * 0.96)
        let wNear = p.small ? 50.0 : 70.0
        let up = clamp01(0.5 + 0.6 * (gy / max(gd, 1) - 0.35 * gx / max(gd, 1)))
        let amt = (0.30 * exp(-pow(o / wNear, 2)) + 0.05 * exp(-pow(o / 130, 2))) * p.glow * (1 - 0.55 * up)
        let gc = mix(rgb(0.42, 0.14, 0.78), rgb(0.12, 0.36, 0.95), smooth(0.25, 0.95, up))
        c = c + gc * amt
    }

    // B: thin luminous scroll ring.
    if p.ring {
        let rd = d - p.ringR
        let halfW = max(p.ringW / 2, pw * 0.65)
        // Faint light spill around the ring.
        let tint = mix(rgb(0.50, 0.24, 0.95), rgb(0.24, 0.62, 1.0), clamp01(0.5 + 0.5 * (dir.y - 0.3 * dir.x)))
        c = c + tint * (0.10 * exp(-pow(rd / (halfW + 16), 2)))
        let cov = cover(abs(rd) - halfW)
        if cov > 0 {
            let t = max(-1, min(1, rd / halfW))
            let nz = sqrt(max(0, 1 - t * t))
            let n = V3(x: dir.x * t, y: dir.y * t, z: nz)
            let diff = max(0, dot(n, light))
            let spec = pow(max(0, dot(n, halfway)), 30)
            var rc = tint * (0.30 + 0.55 * diff) + rgb(0.85, 0.92, 1.0) * (0.75 * spec)
            rc = rc + rgb(0.06, 0.06, 0.12)
            c = mix(c, rc, cov)
        }
    }

    // C: shallow socket with a fine bezel.
    if p.socket {
        let outer = p.socketR + p.bezelW
        // The raised bezel throws a soft shadow down-right onto the tile.
        let so = d - outer
        if so > -2 { c = c * (1 - 0.45 * exp(-pow(max(0, so) / 22, 2)) * clamp01(0.45 - 0.55 * towardLight)) }
        // Bezel ring.
        if p.bezelW > 0 {
            let mid = p.socketR + p.bezelW / 2
            let halfW = max(p.bezelW / 2, pw * 0.6)
            let cov = cover(abs(d - mid) - halfW)
            if cov > 0 {
                let t = max(-1, min(1, (d - mid) / halfW))
                let n = norm(V3(x: dir.x * t * 0.85, y: dir.y * t * 0.85, z: sqrt(max(0.05, 1 - 0.72 * t * t))))
                let diff = max(0, dot(n, light))
                let spec = pow(max(0, dot(n, halfway)), 60) * smooth(-0.2, 0.9, towardLight)
                var bc = rgb(0.10, 0.09, 0.16) * (0.30 + 0.80 * diff) + rgb(0.80, 0.88, 1.0) * (0.70 * spec)
                // Ball light catching the inner edge.
                bc = bc + mix(rgb(0.45, 0.20, 0.85), rgb(0.20, 0.50, 1.0), clamp01(0.5 + 0.5 * dir.y)) * (0.16 * smooth(0.2, -1, t))
                c = mix(c, bc, cov)
            }
        }
        // Socket floor and inner wall.
        let cov = cover(d - p.socketR)
        if cov > 0 {
            let q = clamp01((d - p.ballR) / (p.socketR - p.ballR))
            var sc = rgb(0.028, 0.024, 0.055)
            // Contact shadow / ambient occlusion right around the ball.
            sc = sc * (0.35 + 0.65 * smooth(0, 1, q))
            // The far (lower-right) wall faces the light; the near wall sits in the lip's shadow.
            sc = sc + rgb(0.10, 0.09, 0.17) * (smooth(0.35, 1, q) * clamp01(-towardLight) * 0.9)
            // Coloured light passing through the ball pools on the floor below it.
            sc = sc + mix(cViolet, cMagenta, 0.4) * (0.22 * exp(-q * 2.2) * clamp01(0.3 - 0.9 * towardLight))
            c = mix(c, sc, cov)
        }
    } else {
        // A/B: a tight contact shadow just outside the ball, down-right.
        let o = d - p.ballR
        if o > -2 { c = c * (1 - 0.40 * exp(-pow(max(0, o) / (p.small ? 16 : 20), 2)) * clamp01(0.35 - 0.65 * towardLight)) }
    }

    // The ball.
    let bcov = cover(d - p.ballR)
    if bcov > 0 {
        c = mix(c, ballColor(x / p.ballR, y / p.ballR, p), bcov)
    }
    return c
}

func drawOrb(_ style: String, _ px: Int, _ ctx: CGContext) {
    let s = CGFloat(px)
    let p = params(style, px)
    let unit = 1024.0 / Double(px)                       // design units per pixel
    let ss = px >= 512 ? 2 : (px >= 128 ? 3 : 4)          // supersampling per axis
    let sub = unit / Double(ss)

    // Per-pixel content, dithered to avoid banding in the dark gradients.
    var bytes = [UInt8](repeating: 255, count: px * px * 4)
    var seed: UInt32 = 0x9E3779B9
    func rnd() -> Double { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Double(seed) / Double(UInt32.max) }
    for j in 0..<px {
        for i in 0..<px {
            var acc = V3(x: 0, y: 0, z: 0)
            for sj in 0..<ss {
                for si in 0..<ss {
                    let x = (Double(i) + (Double(si) + 0.5) / Double(ss)) * unit - 512
                    let y = 512 - (Double(j) + (Double(sj) + 0.5) / Double(ss)) * unit
                    acc = acc + orbSample(x, y, p, sub)
                }
            }
            acc = acc * (1 / Double(ss * ss))
            let o = (j * px + i) * 4
            for (k, v) in [acc.x, acc.y, acc.z].enumerated() {
                bytes[o + k] = UInt8(max(0, min(255, (tone(v) * 255 + rnd() - 0.5).rounded())))
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

    // macOS grid: 824 tile with continuous corners and the system-style shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = continuousRect(body, radius: s * 185.4 / 1024)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024, color: color(0, 0, 0, 0.32))
    ctx.addPath(tile); ctx.setFillColor(color(0.03, 0.026, 0.06)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
    // A whisper of an edge so the dark tile doesn't vanish on a dark Dock; brighter at the top.
    if px >= 32 {
        ctx.addPath(tile)
        ctx.setLineWidth(max(1, s * 4 / 1024) * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0.05), color(1, 1, 1, 0.03)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    }
    ctx.restoreGState()
}

// Apple-style continuous-corner rounded rect (the iOS 7+/Big Sur squircle), y up.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.52866483
    let rad = min(radius, min(r.width, r.height) / 2 / k)
    // One corner in local units: a = along the edge from the corner, b = into the shape.
    // Points listed from the horizontal edge to the vertical edge.
    let pts: [(CGFloat, CGFloat)] = [
        (1.52866483, 0), (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600),
        (0.63149399, 0.07491100), (0.39351046, 0.16135035), (0.16135045, 0.39351057), (0.07491176, 0.63149399),
        (0.06549600, 0.66993427), (0, 0.86840701), (0, 1.08849299), (0, 1.52866483),
    ]
    let path = CGMutablePath()
    // corner origin and directions (sx toward the corner along x, sy toward the corner along y)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: r.maxX, y: r.maxY), 1, 1),   // top right
        (CGPoint(x: r.maxX, y: r.minY), 1, -1),  // bottom right
        (CGPoint(x: r.minX, y: r.minY), -1, -1), // bottom left
        (CGPoint(x: r.minX, y: r.maxY), -1, 1),  // top left
    ]
    for (idx, (o, sx, sy)) in corners.enumerated() {
        // Top-right and bottom-left traverse horizontal-edge first; the others vertical-edge first.
        let horizontalFirst = idx % 2 == 0
        let seq = horizontalFirst ? pts : pts.reversed().map { $0 }
        func pt(_ p: (CGFloat, CGFloat)) -> CGPoint {
            // a: distance from the corner along x; b: along y.
            CGPoint(x: o.x - sx * p.0 * rad, y: o.y - sy * p.1 * rad)
        }
        let mapped = seq.map(pt)
        if idx == 0 { path.move(to: mapped[0]) } else { path.addLine(to: mapped[0]) }
        path.addCurve(to: mapped[3], control1: mapped[1], control2: mapped[2])
        path.addLine(to: mapped[4])
        path.addCurve(to: mapped[7], control1: mapped[5], control2: mapped[6])
        path.addLine(to: mapped[8])
        path.addCurve(to: mapped[11], control1: mapped[9], control2: mapped[10])
    }
    path.closeSubpath()
    return path
}

// MARK: - Rendering

func render(_ style: String, _ px: Int) -> NSBitmapImageRep {
    let rep = makeRep(px, px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    if style == "classic" { drawClassic(px, ctx) } else { drawOrb(style, px, ctx) }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

func writeIconset(_ style: String, to dir: URL) {
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var cache: [Int: Data] = [:]
    func get(_ px: Int) -> Data { if let d = cache[px] { return d }; let d = png(render(style, px)); cache[px] = d; return d }
    for size in [16, 32, 128, 256, 512] {
        try! get(size).write(to: dir.appendingPathComponent("icon_\(size)x\(size).png"))
        try! get(size * 2).write(to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    print("Wrote \(dir.path)")
}

if let dir = iconsetOut { writeIconset(style, to: dir) }

if let icns = icnsOut {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("glideball-\(style)-\(UUID().uuidString).iconset")
    writeIconset(style, to: tmp)
    try? FileManager.default.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", tmp.path, "-o", icns.path]
    try! task.run(); task.waitUntilExit()
    try? FileManager.default.removeItem(at: tmp)
    guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
    print("Wrote \(icns.path)")
}

if let file = pngOut {
    try! png(render(style, 1024)).write(to: file)
    print("Wrote \(file.path)")
}

if let dir = pngDir {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try! png(render(style, size)).write(to: dir.appendingPathComponent("\(style)-\(size).png"))
    }
    print("Wrote \(dir.path)/\(style)-*.png")
}

// Contact sheet: each style large (512), then 16-256 at 1:1 on a dark and a light strip.
if let file = sheetOut {
    let styles = ["classic", "orb-a", "orb-b", "orb-c"]
    let names = ["Classic (today)", "A  Orb", "B  Orb + ring", "C  Seated orb"]
    let smalls = [16, 32, 64, 128, 256]
    let col = 600, margin = 40, labelH = 56, bigH = 540, stripH = 300
    let W = margin * 2 + col * styles.count
    let H = margin + labelH + bigH + stripH * 2 + margin
    let rep = makeRep(W, H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    // y up: lay out from the top.
    let top = CGFloat(H)
    ctx.setFillColor(color(0.16, 0.16, 0.17)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let darkY = CGFloat(margin + stripH)
    let lightY = CGFloat(margin)
    ctx.setFillColor(color(0.115, 0.115, 0.12)); ctx.fill(CGRect(x: 0, y: darkY, width: CGFloat(W), height: CGFloat(stripH)))
    ctx.setFillColor(color(0.94, 0.94, 0.95)); ctx.fill(CGRect(x: 0, y: lightY, width: CGFloat(W), height: CGFloat(stripH)))
    for (si, st) in styles.enumerated() {
        let x0 = CGFloat(margin + si * col)
        let label = NSAttributedString(string: names[si], attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)])
        label.draw(at: CGPoint(x: x0 + 44, y: top - CGFloat(margin) - 34))
        let big = render(st, 512)
        ctx.draw(big.cgImage!, in: CGRect(x: x0 + 44, y: top - CGFloat(margin + labelH) - 512, width: 512, height: 512))
        var x = x0 + 24
        for sz in smalls {
            let img = render(st, sz).cgImage!
            for stripY in [darkY, lightY] {
                let y = (stripY + CGFloat(stripH) / 2 - CGFloat(sz) / 2).rounded()
                ctx.draw(img, in: CGRect(x: x.rounded(), y: y, width: CGFloat(sz), height: CGFloat(sz)))
            }
            x += CGFloat(sz) + 22
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! png(rep).write(to: file)
    print("Wrote \(file.path)")
}
