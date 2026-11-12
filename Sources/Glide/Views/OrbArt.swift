import CoreGraphics
import Foundation

/// The app icon's orb (`scripts/make-icon.swift`, style orb-b), as layers the
/// live trackball can move: the liquid color inside, the polished glass over
/// it, and the one specular highlight.
///
/// The icon is shaded per pixel, which is far too slow to redo every frame. So
/// the shading is split once (about 40 ms, the first time a trackball is drawn)
/// into images that, stacked, give back the icon's ball exactly while it's at
/// rest: the liquid on its own, a "glass" layer laid over it (the body
/// shading, refraction, rim and Fresnel), whatever light that can't reach
/// added on top, and the highlight. Rolling the ball then only moves the
/// liquid underneath and nudges the highlight: a few cheap image transforms.
///
/// The colors come from the ball color in use (`BallTheme`, Theme.swift): the
/// default Orb paints exactly the icon's ball; another theme the same shading
/// in its own colors. Each palette's layers are made once and kept.
enum OrbArt {
    struct Layers {
        /// The liquid, covering `liquidSpan` × the ball's diameter so it can turn and shift under the glass.
        let liquid: CGImage
        /// The glass over the liquid (normal blending).
        let glass: CGImage
        /// Light the glass can't add by covering (plus-lighter blending).
        let glow: CGImage
        /// The specular highlight (normal blending).
        let highlight: CGImage
    }

    /// How much wider than the ball the liquid image is.
    static let liquidSpan = 1.5
    /// Pixels across the ball. Enough for a 230 pt trackball on a 2x screen.
    static let size = 320

    /// The layers for the ball color in use.
    static var layers: Layers { layers(for: BallTheme.current.palette) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Layers] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// A palette's layers at `pixels` across (made once, then kept; the last few are kept).
    static func layers(for palette: OrbPalette, pixels: Int = size) -> Layers {
        let key = "\(palette.hashValue)-\(pixels)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = make(pixels, Colors(palette))
        lock.lock()
        cache[key] = made
        order.append(key)
        if order.count > 24 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return made
    }

    // MARK: Shading (a straight port of make-icon.swift, orb-b at large sizes)

    private struct V3 { var x, y, z: Double }
    private static func add(_ a: V3, _ b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    private static func sub(_ a: V3, _ b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    private static func mul(_ a: V3, _ k: Double) -> V3 { V3(x: a.x * k, y: a.y * k, z: a.z * k) }
    private static func dot(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func norm(_ a: V3) -> V3 { mul(a, 1 / dot(a, a).squareRoot()) }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> V3 { V3(x: pow(r, 2.2), y: pow(g, 2.2), z: pow(b, 2.2)) }
    private static func rgb(_ c: OrbRGB) -> V3 { rgb(c.r, c.g, c.b) }
    private static func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { add(a, mul(sub(b, a), t)) }
    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    private static func smooth(_ e0: Double, _ e1: Double, _ v: Double) -> Double {
        let t = clamp01((v - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
    }
    private static func gauss(_ dx: Double, _ dy: Double, _ s: Double) -> Double { exp(-(dx * dx + dy * dy) / (s * s)) }
    /// Linear light to display values, with the icon's soft shoulder.
    private static func tone(_ v: Double) -> Double {
        pow(max(0, v < 0.8 ? v : 0.8 + 0.2 * (1 - exp(-(v - 0.8) / 0.2))), 1 / 2.2)
    }

    /// A palette in linear light, by the names the icon's shading uses.
    private struct Colors {
        let cyan, ice, blue, deepBlue, violet, magenta, lilac, rimDark, shade, backRim, sky: V3
        init(_ p: OrbPalette) {
            cyan = rgb(p.light); ice = rgb(p.ice); blue = rgb(p.mid); deepBlue = rgb(p.deep)
            violet = rgb(p.low); magenta = rgb(p.accent); lilac = rgb(p.lilac); rimDark = rgb(p.rim)
            shade = rgb(p.shade); backRim = rgb(p.backRim); sky = rgb(p.sky)
        }
    }

    private static let light = norm(V3(x: -0.52, y: 0.62, z: 0.59))
    private static let halfway = norm(add(light, V3(x: 0, y: 0, z: 1)))

    /// The colored liquid inside the ball, in ball space (unit disc, y up).
    private static func liquid(_ qx: Double, _ qy: Double, _ k: Colors) -> V3 {
        let wx = qx + 0.16 * sin(2.6 * qy + 0.8) + 0.05 * sin(5.3 * qy - 1.3)
        let wy = qy + 0.13 * sin(2.3 * qx - 0.5) + 0.045 * cos(4.9 * qx + 0.9)
        let t = smooth(-0.95, 0.9, wy)
        var c = t < 0.5 ? mix(k.violet, k.blue, t / 0.5) : mix(k.blue, k.cyan, (t - 0.5) / 0.5)
        c = mix(c, k.deepBlue, 0.45 * gauss(wx + 0.62, wy - 0.02, 0.34))
        c = mix(c, k.blue, 0.55 * gauss(wx - 0.62, wy - 0.42, 0.38))
        c = mix(c, k.ice, 0.55 * gauss(wx + 0.08, wy - 0.52, 0.36))
        c = mix(c, k.lilac, 0.38 * gauss(wx - 0.52, wy + 0.04, 0.34))
        c = mix(c, k.magenta, 0.88 * gauss(wx + 0.40, wy + 0.52, 0.40))
        return c
    }

    /// The icon's ball color at a point (without the highlight), and how much
    /// of the liquid the shading lets through there.
    private static func ball(_ bx: Double, _ by: Double, _ k: Colors) -> (color: V3, through: Double) {
        let r = min(1, (bx * bx + by * by).squareRoot())
        let z = max(0, 1 - r * r).squareRoot()
        let n = V3(x: bx, y: by, z: z)
        let kz = 0.80 + 0.20 * z
        var c = liquid(bx * kz, by * kz, k)
        c = mix(c, liquid(bx * 0.55 - 0.08, by * 0.55 + 0.05, k), 0.16 * z)
        let diff = max(0, dot(n, light))
        var through = (0.18 + 0.95 * diff) * (0.85 + 0.30 * z)
        c = mul(c, through)
        c = add(c, mul(k.shade, 0.22 * (1 - diff)))
        c = add(c, mul(k.lilac, 0.14 * gauss(bx - 0.36, by + 0.44, 0.36)))
        let rim = pow(1 - z, 2.0)
        let shadowSide = clamp01(0.5 - 0.5 * (bx * light.x + by * light.y) / max(r, 1e-6) * 1.4)
        let rimMix = rim * (0.30 + 0.50 * shadowSide)
        c = mix(c, k.rimDark, rimMix)
        through *= 1 - rimMix
        let env = mix(rgb(0.03, 0.02, 0.08), k.sky, smooth(0.0, 0.9, 0.75 * n.y - 0.45 * n.x))
        let f = 0.02 + 0.55 * pow(1 - z, 4)
        c = add(mul(c, 1 - f), mul(env, f))
        through *= 1 - f
        let br = smooth(0.80, 0.985, r) * clamp01((bx - by) / 1.414 / max(r, 1e-6))
        c = add(c, mul(k.backRim, br * 0.22))
        let toward = (bx * light.x + by * light.y) / max(r, 1e-6) / (light.x * light.x + light.y * light.y).squareRoot()
        c = add(c, mul(k.sky, 0.24 * smooth(0.968, 0.994, r) * smooth(-0.1, 0.9, toward)))
        return (c, through)
    }

    private static func specular(_ bx: Double, _ by: Double) -> Double {
        let r2 = bx * bx + by * by
        let n = V3(x: bx, y: by, z: max(0, 1 - r2).squareRoot())
        let ndh = max(0, dot(n, halfway))
        return 0.65 * pow(ndh, 220) + 0.30 * pow(ndh, 40) + 0.07 * pow(ndh, 8)
    }

    // MARK: Splitting it into layers

    private static func make(_ n: Int, _ k: Colors) -> Layers {
        let m = Int((Double(n) * liquidSpan).rounded())
        var liquidPx = [UInt8](repeating: 255, count: m * m * 4)
        var glassPx = [UInt8](repeating: 0, count: n * n * 4)
        var glowPx = [UInt8](repeating: 0, count: n * n * 4)
        var highlightPx = [UInt8](repeating: 0, count: n * n * 4)

        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

        // The liquid: flat (no refraction), as it would look with nothing over it.
        for j in 0..<m {
            let qy = liquidSpan * (1 - (Double(j) + 0.5) / Double(m) * 2)
            for i in 0..<m {
                let qx = liquidSpan * ((Double(i) + 0.5) / Double(m) * 2 - 1)
                let c = liquid(qx, qy, k)
                let o = (j * m + i) * 4
                liquidPx[o] = byte(tone(c.x)); liquidPx[o + 1] = byte(tone(c.y)); liquidPx[o + 2] = byte(tone(c.z))
            }
        }

        // Glass and glow: chosen per pixel so liquid + glass + glow is the icon's ball.
        for j in 0..<n {
            let by = 1 - (Double(j) + 0.5) / Double(n) * 2
            for i in 0..<n {
                let bx = (Double(i) + 0.5) / Double(n) * 2 - 1
                let o = (j * n + i) * 4
                let rr = (bx * bx + by * by).squareRoot()
                // A little past the edge too, so the circular mask's soft edge has color under it.
                let s = rr > 1 ? 1 / rr : 1
                let x = bx * s * 0.999, y = by * s * 0.999
                let (c, through) = ball(x, y, k)
                let target = [tone(c.x), tone(c.y), tone(c.z)]
                let flat = liquid(x, y, k)
                let under = [tone(flat.x), tone(flat.y), tone(flat.z)]
                // How much the glass covers: the shading's, or more where the icon is darker than the bare liquid.
                var alpha = 1 - min(1, pow(max(through, 0), 1 / 2.2))
                for ch in 0..<3 where under[ch] > 0.001 {
                    alpha = max(alpha, 1 - target[ch] / under[ch])
                }
                alpha = min(1, max(0, alpha))
                var glassColor = [0.0, 0.0, 0.0], extra = [0.0, 0.0, 0.0]
                for ch in 0..<3 {
                    let wanted = alpha > 0.001 ? (target[ch] - (1 - alpha) * under[ch]) / alpha : 0
                    glassColor[ch] = min(1, max(0, wanted))
                    extra[ch] = max(0, target[ch] - (alpha * glassColor[ch] + (1 - alpha) * under[ch]))
                }
                // Premultiplied.
                glassPx[o] = byte(glassColor[0] * alpha); glassPx[o + 1] = byte(glassColor[1] * alpha)
                glassPx[o + 2] = byte(glassColor[2] * alpha); glassPx[o + 3] = byte(alpha)
                let ea = max(extra[0], extra[1], extra[2])
                glowPx[o] = byte(extra[0]); glowPx[o + 1] = byte(extra[1]); glowPx[o + 2] = byte(extra[2]); glowPx[o + 3] = byte(ea)
                let h = min(1, pow(specular(x, y), 1 / 1.6))
                highlightPx[o] = byte(h); highlightPx[o + 1] = byte(h); highlightPx[o + 2] = byte(h); highlightPx[o + 3] = byte(h)
            }
        }
        return Layers(liquid: image(liquidPx, m, alpha: false), glass: image(glassPx, n, alpha: true),
                      glow: image(glowPx, n, alpha: true), highlight: image(highlightPx, n, alpha: true))
    }

    private static func image(_ bytes: [UInt8], _ n: Int, alpha: Bool) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
