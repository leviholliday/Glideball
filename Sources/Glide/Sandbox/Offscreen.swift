import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Draws SwiftUI views to bitmaps without putting anything on screen.
///
/// Each view is hosted in an `NSHostingView` inside a window that's never
/// ordered front (so it's never on screen, in the Dock, or in Mission Control),
/// given a moment to settle, and then its layer tree is drawn by Core
/// Animation's own renderer (`CARenderer`) into a Metal texture. That's the
/// same renderer that draws windows on screen, so Liquid Glass, materials,
/// vibrancy and shadows come out the way they look in the app — which
/// `cacheDisplay(in:to:)` (AppKit's drawing, which leaves glass empty and
/// text black) and `ImageRenderer` (no AppKit controls, no scroll views) can't.
///
/// Animations are switched off (every transaction's animation is removed), so
/// what's drawn is where each animation would end. The window reports itself
/// as key, so controls and traffic lights draw in their active colors.
/// What still isn't faithful is listed in docs/DEVELOPING.md.
///
/// `GLIDE_RENDER_ENGINE=appkit` uses `cacheDisplay` instead (for comparison).
@MainActor
enum Offscreen {
    enum Chrome {
        /// A window with its title bar and traffic lights over the content.
        case window
        /// Glideball's main window, styled as AppDelegate styles it (the sidebar runs under the traffic lights).
        case mainWindow
        /// A titled window whose title bar (and toolbar) is drawn too.
        case titled
        /// Just the content (sheets, cards).
        case plain
    }

    /// Draws its controls as the front window's do, without ever being in front.
    final class ActiveLookingWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        // AppKit asks these (not isKeyWindow) when choosing active or inactive
        // colors for controls and the traffic lights.
        @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
        @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc(_hasActiveControls) func hasActiveControls() -> Bool { true }
        @objc(_hasKeyAppearance) func hasKeyAppearancePrivate() -> Bool { true }
        @objc(hasKeyAppearance) func hasKeyAppearancePublic() -> Bool { true }
        @objc(_isActiveAndOnScreen:) func isActiveAndOnScreen(_ x: Any?) -> Bool { true }
    }

    /// Gives a window AppKit made (Settings, say) the same active look.
    static func lookActive(_ window: NSWindow) {
        if type(of: window) == NSWindow.self { object_setClass(window, ActiveLookingWindow.self) }
        // Controls made before the swap ask again.
        let refresh = NSSelectorFromString("_sendForcedWindowChangedKeyState")
        if window.responds(to: refresh) { window.perform(refresh) }
    }

    static var useAppKit: Bool { ProcessInfo.processInfo.environment["GLIDE_RENDER_ENGINE"] == "appkit" }

    /// A window that's never ordered front.
    static func makeWindow(size: NSSize, chrome: Chrome, appearance: NSAppearance?) -> NSWindow {
        let style: NSWindow.StyleMask = switch chrome {
        case .window, .mainWindow: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        case .titled: [.titled, .closable, .fullSizeContentView]
        case .plain: [.borderless]
        }
        let w = ActiveLookingWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                                    backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = appearance
        if chrome == .mainWindow {
            AppDelegate.styleMainWindow(w)
        } else if chrome != .plain {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }
        return w
    }

    /// Lays out `view` in a fresh offscreen window and returns the window (for
    /// drawing, or for the self-test to inspect). `size` nil = the view's own size.
    static func host<V: View>(_ view: V, size: NSSize?, chrome: Chrome, appearance: NSAppearance?,
                              settle: Double = 0.3) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: withoutAnimations(view))
        hosting.appearance = appearance
        let window = makeWindow(size: size ?? NSSize(width: 600, height: 400), chrome: chrome, appearance: appearance)
        if size != nil { hosting.sizingOptions = [] }
        window.contentView = hosting
        if let size {
            window.setContentSize(size)
        } else {
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(fit(hosting))
        }
        settleDown(hosting, seconds: settle)
        if size == nil {   // onAppear may have changed the content's size
            let fit = fit(hosting)
            if abs(fit.height - hosting.frame.height) > 0.5 || abs(fit.width - hosting.frame.width) > 0.5 {
                window.setContentSize(fit)
                settleDown(hosting, seconds: 0.1)
            }
        }
        return (window, hosting)
    }

    private static func fit(_ view: NSView) -> NSSize {
        let s = view.fittingSize
        return NSSize(width: max(s.width.rounded(.up), 1), height: max(s.height.rounded(.up), 1))
    }

    static func withoutAnimations<V: View>(_ view: V) -> some View {
        view
            .transaction { t in
                t.animation = nil
                t.disablesAnimations = true
            }
    }

    /// Lets onAppear, state changes and async work run, then lays out and draws.
    static func settleDown(_ view: NSView, seconds: Double) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        Sandbox.spin(seconds)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        Sandbox.spin(0.05)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    // MARK: Drawing

    /// Draws the window's content (and, for `.window`/`.titled`, its title bar) at `scale`.
    static func draw(_ window: NSWindow, content: NSView, chrome: Chrome, scale: CGFloat) -> NSBitmapImageRep? {
        if useAppKit { return drawWithAppKit(window, content: content, chrome: chrome, scale: scale) }
        let frameView = window.contentView?.superview
        guard chrome != .plain, let frameView else { return image(of: content, scale: scale) }
        // The window's own frame view doesn't draw through CARenderer, so the
        // content and the title bar are drawn separately and put together.
        let size = frameView.bounds.size
        var parts: [(NSView, NSRect)] = [(content, content.convert(content.bounds, to: frameView))]
        if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
            parts.append((titlebar, titlebar.convert(titlebar.bounds, to: frameView)))
        }
        return compose(size: size, scale: scale) { ctx in
            for (view, rect) in parts {
                guard let rep = image(of: view, scale: scale), let cg = rep.cgImage else { continue }
                // Frame-view coordinates are y-up (NSThemeFrame isn't flipped); so is the context.
                let r = frameView.isFlipped ? NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) : rect
                ctx.draw(cg, in: r)
            }
        }
    }

    /// One view's layer tree, through Core Animation's renderer.
    static func image(of view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0, let layer = view.layer, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // Our own queue, so we can tell when the frame has really been drawn.
        guard let queue = device.makeCommandQueue() else { return nil }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: sRGB, kCARendererMetalCommandQueue: queue])

        // The view's layer, lent to a root of our own for the length of one frame.
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: w, height: h)
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = CGRect(origin: .zero, size: bounds.size)
        holder.position = .zero
        holder.transform = CATransform3DMakeScale(scale, scale, 1)
        root.addSublayer(holder)
        let parent = layer.superlayer
        let index = parent?.sublayers?.firstIndex(of: layer).map(UInt32.init)
        let frame = layer.frame
        layer.removeFromSuperlayer()
        holder.addSublayer(layer)
        layer.frame = CGRect(origin: .zero, size: bounds.size)
        renderer.layer = root
        renderer.bounds = root.frame
        CATransaction.flush()   // after `renderer.layer`: this is what hands the tree to the renderer
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let fence = queue.makeCommandBuffer()
        fence?.commit()
        fence?.waitUntilCompleted()   // after everything CARenderer queued

        layer.removeFromSuperlayer()
        if let parent { parent.insertSublayer(layer, at: index ?? 0) }
        layer.frame = frame

        let rowBytes = w * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * h)
        texture.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // The texture's first row is the picture's bottom.
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        raw.withUnsafeBytes { src in
            bytes.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    memcpy(dst.baseAddress! + row * rowBytes, src.baseAddress! + (h - 1 - row) * rowBytes, rowBytes)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: sRGB,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                        | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = bounds.size
        return rep
    }

    /// A transparent `size`-point canvas at `scale`, drawn in y-up points.
    static func compose(size: NSSize, scale: CGFloat, _ body: (CGContext) -> Void) -> NSBitmapImageRep? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        body(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return rep
    }

    /// AppKit's drawing (`cacheDisplay`): no glass, and text in glass comes out dark.
    static func drawWithAppKit(_ window: NSWindow, content: NSView, chrome: Chrome, scale: CGFloat) -> NSBitmapImageRep? {
        let target: NSView = chrome == .plain ? content : (window.contentView?.superview ?? content)
        target.layoutSubtreeIfNeeded()
        let bounds = target.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((bounds.width * scale).rounded()),
                                         pixelsHigh: Int((bounds.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        target.cacheDisplay(in: bounds, to: rep)
        let out = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        out.size = bounds.size
        return out
    }

    /// Hosts, settles and draws in one go.
    static func render<V: View>(_ view: V, size: NSSize?, chrome: Chrome, appearance: NSAppearance?,
                                scale: CGFloat, settle: Double = 0.3) -> NSBitmapImageRep? {
        let (window, content) = host(view, size: size, chrome: chrome, appearance: appearance, settle: settle)
        defer { window.contentView = nil; window.close() }
        return draw(window, content: content, chrome: chrome, scale: scale)
    }

    /// Something taller than a screen: Core Animation only draws the part of
    /// a window a screen could show, so it's drawn a slice at a time (the same
    /// full-height layout each time, moved up) and the slices are stacked.
    static func renderTall<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance?, scale: CGFloat,
                                    slice: CGFloat = 600) -> NSBitmapImageRep? {
        let measure = NSHostingView(rootView: withoutAnimations(view.frame(width: width)))
        measure.appearance = appearance
        let probe = makeWindow(size: NSSize(width: width, height: slice), chrome: .plain, appearance: appearance)
        probe.contentView = measure
        settleDown(measure, seconds: 0.2)
        let height = fit(measure).height
        probe.contentView = nil
        probe.close()
        if useAppKit || height <= slice {
            return render(view.frame(width: width), size: nil, chrome: .plain, appearance: appearance, scale: scale)
        }
        let full = NSSize(width: width, height: height)
        var slices: [(NSBitmapImageRep, CGFloat)] = []
        var top: CGFloat = 0
        while top < height {
            let h = min(slice, height - top)
            let piece = view
                .frame(width: width, height: height)
                .offset(y: -top)
                .frame(width: width, height: h, alignment: .top)
                .clipped()
            guard let rep = render(piece, size: NSSize(width: width, height: h), chrome: .plain,
                                   appearance: appearance, scale: scale, settle: 0.2) else { return nil }
            slices.append((rep, top))
            top += h
        }
        return compose(size: full, scale: scale) { ctx in
            for (rep, top) in slices {
                guard let cg = rep.cgImage else { continue }
                ctx.draw(cg, in: CGRect(x: 0, y: height - top - rep.size.height, width: width, height: rep.size.height))
            }
        }
    }

    /// True when every pixel is the same colour (or fully transparent): nothing was drawn.
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return true }
        var first: NSColor?
        // A grid of samples is plenty to tell a drawn screen from an empty one.
        let steps = 48
        for yi in 0..<steps {
            for xi in 0..<steps {
                guard let c = rep.colorAt(x: xi * (w - 1) / (steps - 1), y: yi * (h - 1) / (steps - 1)) else { continue }
                if let f = first {
                    if abs(f.redComponent - c.redComponent) + abs(f.greenComponent - c.greenComponent)
                        + abs(f.blueComponent - c.blueComponent) + abs(f.alphaComponent - c.alphaComponent) > 0.02 {
                        return false
                    }
                } else {
                    first = c
                }
            }
        }
        return true
    }

    static func png(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }
}
