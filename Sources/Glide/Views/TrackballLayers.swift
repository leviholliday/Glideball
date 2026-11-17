import AppKit
import QuartzCore
import simd
import SwiftUI

// The live trackball's moving parts, drawn with Core Animation layers that a
// display link moves directly, outside SwiftUI.
//
// The trackball used to be redrawn by SwiftUI on a TimelineView: every frame
// rebuilt TrackballArt (a few dozen shapes, three Canvases, blurs) and drew it
// again on the main thread, about 2 to 3 ms a frame. That was too much to keep
// it running while a page scrolls, so it held still then, which felt like a
// glitch. Now SwiftUI draws only what never moves (the body, the pads, the well,
// the ring's machined edge) and four layer "slots" sit between those parts in
// the same order, holding what does move:
//
//   ticks      the ring's tick marks (vector shapes, turned by a transform; pink ones on top)
//   ringLight  the ring's pink glow and edge (pictures, faded) and the sweep (redrawn while it shows)
//   ballLight  the light the ball throws into the well and its afterglow (pictures, faded and moved)
//   ball       the ball: its turning surface (redrawn only when it turns) under the glass pictures
//
// One `TrackballMotion` per trackball computes the pose exactly as before
// (`TrackballView.pose`) and sets those layers' opacity, transform, position and
// contents. A tick of the ring no longer invalidates any SwiftUI view: SwiftUI
// only hears about the trackball when something it draws changes (a button down,
// the look, the feed starting or stopping). Its clock (`LayerClock`) runs only
// while the ball or ring is moving, or for Smoothest's idle drift, and never while
// the window is hidden (the feed goes quiet then), so idle still costs nothing.

/// What a layered trackball needs from SwiftUI: the motion that drives it, the feed, and
/// how it should run. Changes only when the feed starts or stops, or a setting changes.
struct TrackballLive: Equatable {
    let motion: TrackballMotion
    let feed: LiveFeed
    var config: TrackballMotion.Config

    static func == (a: TrackballLive, b: TrackballLive) -> Bool {
        a.motion === b.motion && a.feed === b.feed && a.config == b.config
    }
}

/// Drives one trackball's layers: computes each frame's pose and hands it to its slots.
@MainActor
final class TrackballMotion {
    struct Config: Equatable {
        /// Something is moving (`LiveFeed.isActive`, connected).
        var live = false
        /// Frames a second for the idle drift; 0 holds it still.
        var drift = 0.0
        var reduceMotion = false

        /// The trackball turns smoothly (30 frames a second) while it's moving, the drift at its own rate.
        var framesPerSecond: Float { live ? 30 : Float(max(drift, 1)) }
        var runs: Bool { live || drift > 0 }
    }

    private(set) var feed: LiveFeed?
    private(set) var config = Config()
    private var slots: [WeakSlot] = []
    private struct WeakSlot { weak var view: TrackballSlotView? }
    private(set) lazy var clock = LayerClock { [weak self] in self?.frame() }

    func configure(feed: LiveFeed, config: Config) {
        guard feed !== self.feed || config != self.config else { return }
        self.feed = feed
        self.config = config
        clock.framesPerSecond = config.framesPerSecond
        clock.running = config.runs
        // The frame for the new settings (the last one when the motion stops).
        frame()
    }

    func register(_ view: TrackballSlotView) {
        slots.removeAll { $0.view == nil || $0.view === view }
        slots.append(WeakSlot(view: view))
        slots.sort { ($0.view?.part.rawValue ?? 0) < ($1.view?.part.rawValue ?? 0) }
        clock.host(slots.first { $0.view?.window != nil }?.view ?? view)
    }

    func unregister(_ view: TrackballSlotView) {
        slots.removeAll { $0.view == nil || $0.view === view }
        clock.host(slots.first { $0.view?.window != nil }?.view)
    }

    /// The trackball now.
    func pose(at now: CFTimeInterval = CACurrentMediaTime()) -> TrackballPose? {
        guard let feed else { return nil }
        return TrackballView.pose(feed: feed, look: .connected, pressed: [], live: config.live,
                                  drift: config.drift, reduceMotion: config.reduceMotion, at: now)
    }

    /// One frame: every slot's layers to the pose of this moment.
    func frame() {
        guard let pose = pose() else { return }
        PerfProbe.count("Trackball frame")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in slots { slot.view?.apply(pose) }
        CATransaction.commit()
    }
}

/// A display link for layers that move outside SwiftUI. It runs only while asked to
/// and only while its view is in a window, at the rate asked for. `--scroll-bench`
/// has no display, so there it follows the bench's ticks instead (`LiveFeed.benchTick`).
@MainActor
final class LayerClock: NSObject {
    var running = false { didSet { if running != oldValue { update() } } }
    var framesPerSecond: Float = 30 {
        didSet { if framesPerSecond != oldValue { link?.preferredFrameRateRange = Self.range(framesPerSecond) } }
    }
    private let tick: () -> Void
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var benchToken: NSObjectProtocol?
    private var occlusionToken: NSObjectProtocol?
    private weak var watchedWindow: NSWindow?

    init(tick: @escaping () -> Void) { self.tick = tick }

    /// The view whose display paces the clock (any of the slots in a window).
    func host(_ view: NSView?) {
        if view !== self.view {
            self.view = view
            link?.invalidate()
            link = nil
        }
        update()
    }

    func update() {
        if Sandbox.mode != .scrollBench { watchOcclusion(of: running ? view?.window : nil) }
        // Never for a window nobody can see (hidden, minimized, covered, a closed panel).
        let want = running && view?.window != nil
            && (Sandbox.mode == .scrollBench || view?.window?.occlusionState.contains(.visible) == true)
        if Sandbox.mode == .scrollBench {
            if want, benchToken == nil {
                benchToken = NotificationCenter.default.addObserver(forName: LiveFeed.benchTickNotification, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            } else if !want, let token = benchToken {
                NotificationCenter.default.removeObserver(token)
                benchToken = nil
            }
            return
        }
        if want, link == nil, let view {
            let l = view.displayLink(target: self, selector: #selector(step))
            l.preferredFrameRateRange = Self.range(framesPerSecond)
            l.add(to: .main, forMode: .common)
            link = l
        } else if !want, let l = link {
            l.invalidate()
            link = nil
        }
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    private func watchOcclusion(of window: NSWindow?) {
        guard window !== watchedWindow else { return }
        if let token = occlusionToken { NotificationCenter.default.removeObserver(token) }
        occlusionToken = nil
        watchedWindow = window
        guard let window else { return }
        occlusionToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
                if self?.link != nil { self?.tick() }
            }
        }
    }

    private static func range(_ fps: Float) -> CAFrameRateRange {
        CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    }
}

/// One slot of a layered trackball, between the parts SwiftUI draws (see the top of this file).
struct TrackballLayerSlot: NSViewRepresentable {
    enum Part: Int { case ticks, ringLight, ballLight, ball }
    let part: Part
    let live: TrackballLive
    let theme: BallTheme

    func makeNSView(context: Context) -> TrackballSlotView { TrackballSlotView(part: part) }

    func updateNSView(_ view: TrackballSlotView, context: Context) {
        view.attach(live.motion, theme: theme, environment: context.environment)
        live.motion.configure(feed: live.feed, config: live.config)
    }

    static func dismantleNSView(_ view: TrackballSlotView, coordinator: ()) { view.detach() }
}

/// The layers of one slot. Sizes follow TrackballArt (fractions of the trackball's side).
final class TrackballSlotView: NSView {
    let part: TrackballLayerSlot.Part
    private weak var motion: TrackballMotion?
    private var theme: BallTheme = .orb
    private var environment = EnvironmentValues()
    /// Everything this slot draws, in top-left coordinates.
    private let root = CALayer()
    /// The size, scale and colors the layers were built for.
    private var builtFor: String?
    private var side: CGFloat = 0

    // ticks
    private let whiteTicks = TickLayers(), pinkTicks = TickLayers()
    // ringLight
    private var pinkGlows: [CALayer] = []
    private let pinkEdge = CAShapeLayer()
    private let sweep = CALayer()
    private var sweepDrawn: (length: Double, clockwise: Bool)?
    // ballLight
    private var ballGlows: [CALayer] = []
    private var afterglow = CALayer()
    // ball
    private let ballClip = CALayer()
    private let surface = CALayer()
    private let glass = CALayer(), glassGlow = CALayer(), highlight = CALayer()
    private var surfaceDrawn: BallSpin.Quaternion?
    private var surfacePainter: BallSurfacePainter?

    init(part: TrackballLayerSlot.Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(root)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func attach(_ motion: TrackballMotion, theme: BallTheme, environment: EnvironmentValues) {
        self.environment = environment
        if self.theme != theme { self.theme = theme; builtFor = nil; needsLayout = true }
        if self.motion !== motion {
            self.motion?.unregister(self)
            self.motion = motion
            motion.register(self)
        }
    }

    func detach() {
        motion?.unregister(self)
        motion = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let motion { motion.register(self) }
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // AppKit can call this often (every frame of a scroll, offscreen); rebuild only for a new scale.
        if laidOut?.1 != scale { needsLayout = true }
    }

    /// The bounds and scale last laid out for: SwiftUI asks for layout on every frame of a
    /// page scroll, which must cost nothing.
    private var laidOut: (CGSize, CGFloat)?

    override func layout() {
        super.layout()
        if let l = laidOut, l.0 == bounds.size, l.1 == scale, builtFor != nil { return }
        laidOut = (bounds.size, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        build()
        if let pose = motion?.pose() { apply(pose) }
        CATransaction.commit()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Building

    private func build() {
        guard let host = layer else { return }
        if root.frame != host.bounds { root.frame = host.bounds }
        // Top-left coordinates, like SwiftUI's, whatever the layers above do.
        let flip = !(host.contentsAreFlipped())
        if root.isGeometryFlipped != flip { root.isGeometryFlipped = flip }
        let s = min(bounds.width, bounds.height)
        let key = "\(s)@\(scale)|\(theme.palette.hashValue)"
        guard s > 1, key != builtFor else { return }
        builtFor = key
        side = s
        root.sublayers = nil
        switch part {
        case .ticks: buildTicks(s)
        case .ringLight: buildRingLight(s)
        case .ballLight: buildBallLight(s)
        case .ball: buildBall(s)
        }
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// A layer showing `image` (made at `size` points), centered.
    private func picture(_ image: CGImage?, size: CGSize, blend: String? = nil) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.bounds = CGRect(origin: .zero, size: size)
        l.position = center
        l.compositingFilter = blend
        l.opacity = 0
        return l
    }

    private func color(_ c: Color) -> CGColor { c.resolve(in: environment).cgColor }

    private func buildTicks(_ s: CGFloat) {
        let hair = max(0.6, s * 0.0042)
        let white = color(Color(red: 0.86, green: 0.9, blue: 1)), pink = color(Theme.ring)
        whiteTicks.build(side: s, hair: hair, color: white, scale: scale)
        pinkTicks.build(side: s, hair: hair, color: pink, scale: scale)
        // Pink warming the ticks: added on top, as the drawing's plus-lighter blend did.
        pinkTicks.rotor.compositingFilter = "plusL"
        for t in [whiteTicks, pinkTicks] {
            t.rotor.position = center
            root.addSublayer(t.rotor)
        }
    }

    private func buildRingLight(_ s: CGFloat) {
        let d = s * TrackballArt.ringRadius * 2
        let w = max(1.1, s * 0.0085)
        let size = CGSize(width: s, height: s)
        // The ring's glow at three speeds, faded between as it turns (blurred once, not every frame).
        pinkGlows = [0, 0.5, 1].map { k in
            picture(LayerArt.image("pink-glow-\(k)", size: size, scale: scale) {
                Circle()
                    .stroke(Theme.ring, lineWidth: w * (4 + 3 * k))
                    .blur(radius: w * (2.5 + 3 * k))
                    .frame(width: d, height: d)
            }, size: size)
        }
        pinkGlows.forEach(root.addSublayer)
        pinkEdge.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        pinkEdge.fillColor = nil
        pinkEdge.strokeColor = color(Theme.ring)
        pinkEdge.lineWidth = w * 1.1
        pinkEdge.position = center
        pinkEdge.contentsScale = scale
        pinkEdge.opacity = 0
        root.addSublayer(pinkEdge)
        sweep.bounds = CGRect(origin: .zero, size: size)
        sweep.position = center
        sweep.contentsScale = scale
        sweep.isHidden = true
        sweepDrawn = nil
        root.addSublayer(sweep)
    }

    private func buildBallLight(_ s: CGFloat) {
        let d = s * TrackballArt.ballRadius * 2
        let glow = theme.glow
        let side = d * 1.7
        // The light the ball throws into the well, at rest and at full speed, faded between.
        ballGlows = [0.0, 1.0].map { speed in
            picture(LayerArt.image("ball-glow-\(speed)-\(theme.palette.hashValue)", size: CGSize(width: side, height: side), scale: scale) {
                Circle()
                    .fill(RadialGradient(colors: [glow[1].opacity(0.45), glow[2].opacity(0.14), .clear],
                                         center: .center, startRadius: d * 0.45, endRadius: d * (0.78 + 0.08 * speed)))
            }, size: CGSize(width: side, height: side))
        }
        ballGlows.forEach(root.addSublayer)
        let a = d * 1.3
        let after = picture(LayerArt.image("afterglow-\(theme.palette.hashValue)", size: CGSize(width: a, height: a), scale: scale) {
            Circle()
                .fill(RadialGradient(colors: [glow[0].opacity(0.7), glow[1].opacity(0.3), .clear],
                                     center: .center, startRadius: 0, endRadius: d * 0.62))
        }, size: CGSize(width: a, height: a), blend: "plusL")
        after.isHidden = true
        afterglow = after
        root.addSublayer(after)
    }

    /// This slot is framed to the ball itself, so its side is the ball's diameter.
    private func buildBall(_ d: CGFloat) {
        ballClip.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        ballClip.position = center
        ballClip.cornerRadius = d / 2
        ballClip.masksToBounds = true
        let layers = OrbArt.layers(for: theme.palette)
        surface.frame = ballClip.bounds
        surface.contentsScale = scale
        surfaceDrawn = nil
        surfacePainter = BallSurfacePainter(theme: theme, diameter: d, scale: scale)
        // The glass, scaled once to the ball's pixels with high-quality resampling (as SwiftUI's
        // `.interpolation(.high)` drew it), so its fine rim stays crisp.
        let px = Int((d * scale).rounded())
        for (l, image, blend) in [(glass, layers.glass, nil), (glassGlow, layers.glow, "plusL"), (highlight, layers.highlight, nil)] as [(CALayer, CGImage, String?)] {
            l.contents = Self.resampled(image, to: px) ?? image
            l.frame = ballClip.bounds
            l.contentsScale = scale
            l.compositingFilter = blend
        }
        ballClip.sublayers = [surface, glass, glassGlow, highlight]
        root.addSublayer(ballClip)
    }

    private static func resampled(_ image: CGImage, to px: Int) -> CGImage? {
        guard px > 0, px != image.width, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage()
    }

    // MARK: Each frame

    func apply(_ pose: TrackballPose) {
        guard builtFor != nil else { return }
        let s = side
        let spin = min(abs(pose.ringRate) / 14, 1)
        switch part {
        case .ticks:
            let angle = CATransform3DMakeRotation(pose.ringAngle * .pi / 180, 0, 0, 1)
            whiteTicks.set(opacity: 0.4 + 0.4 * spin, transform: angle)
            pinkTicks.set(opacity: spin * 0.85, transform: angle)

        case .ringLight:
            // Spin 0…1 fades through the glows made at 0, 0.5 and 1.
            let k = spin * 2
            let weights = [max(0, 1 - k), k <= 1 ? k : max(0, 2 - k), max(0, k - 1)]
            for (l, w) in zip(pinkGlows, weights) { l.opacity = Float(w * spin * 0.6) }
            pinkEdge.opacity = Float(spin * 0.85)
            let energy = max(spin, pose.comet * 0.9)
            if max(spin, pose.comet) > 0.01 {
                // Drawn at the top, then turned with the ring by a transform; redrawn only when its
                // length (in steps of 1/200 of a turn) or direction changes, not on every frame.
                let length = ((0.06 + 0.2 * energy) * 200).rounded() / 200
                let clockwise = abs(pose.ringRate) > 0.05 ? pose.ringRate >= 0 : pose.cometSign >= 0
                if sweepDrawn.map({ $0.length != length || $0.clockwise != clockwise }) ?? true {
                    sweep.contents = SweepPainter.image(side: s, scale: scale, length: length,
                                                        clockwise: clockwise, ring: color(Theme.ring))
                    sweepDrawn = (length, clockwise)
                }
                let sign = clockwise ? 1.0 : -1.0
                sweep.transform = CATransform3DMakeRotation(pose.ringAngle * sign * .pi / 180, 0, 0, 1)
                sweep.opacity = Float(energy)
                sweep.isHidden = false
            } else {
                sweep.isHidden = true
            }

        case .ballLight:
            let d = s * TrackballArt.ballRadius * 2
            let speed = min(pose.ballSpeed / 4, 1)
            let glow = 0.75 + 0.25 * speed
            if ballGlows.count == 2 {
                ballGlows[0].opacity = Float((1 - speed) * glow)
                ballGlows[1].opacity = Float(speed * glow)
            }
            if pose.afterglow > 0.01 {
                afterglow.position = CGPoint(x: center.x + pose.afterglowDirection.dx * d * 0.2 * pose.afterglow,
                                             y: center.y + pose.afterglowDirection.dy * d * 0.2 * pose.afterglow)
                afterglow.opacity = Float(pose.afterglow * 0.85)
                afterglow.isHidden = false
            } else {
                afterglow.isHidden = true
            }

        case .ball:
            // Redrawn only when it has turned.
            let q = pose.orientation
            if surfaceDrawn.map({ simd_length($0.vector - q.vector) > 1e-7 }) ?? true {
                surface.contents = surfacePainter?.image(orientation: q)
                surfaceDrawn = q
            }
        }
    }
}

/// The ring's tick marks as two vector shapes (every fifth tick a little longer and
/// brighter) and the band's faint inner edge, all on a layer the ring's angle turns.
fileprivate final class TickLayers {
    let rotor = CALayer()
    private let minor = CAShapeLayer(), major = CAShapeLayer(), edge = CAShapeLayer()

    func build(side s: CGFloat, hair: CGFloat, color: CGColor, scale: CGFloat) {
        rotor.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        let c = s / 2
        let minorPath = CGMutablePath(), majorPath = CGMutablePath()
        for i in 0..<TrackballArt.tickCount {
            let a = (Double(i) / Double(TrackballArt.tickCount) * 360 - 90) * .pi / 180
            let isMajor = i % 5 == 0
            let r0 = s * (isMajor ? 0.320 : 0.327), r1 = s * (isMajor ? 0.362 : 0.357)
            let path = isMajor ? majorPath : minorPath
            path.move(to: CGPoint(x: c + cos(a) * r0, y: c + sin(a) * r0))
            path.addLine(to: CGPoint(x: c + cos(a) * r1, y: c + sin(a) * r1))
        }
        for (l, path, width) in [(minor, minorPath, hair), (major, majorPath, hair * 1.35)] {
            l.path = path
            l.strokeColor = color
            l.lineWidth = width
            l.lineCap = .round
            l.fillColor = nil
            l.frame = rotor.bounds
            l.contentsScale = scale
        }
        let inner = s * 0.311
        edge.path = CGPath(ellipseIn: CGRect(x: c - inner, y: c - inner, width: inner * 2, height: inner * 2), transform: nil)
        edge.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
        edge.fillColor = nil
        edge.lineWidth = max(0.5, s * 0.003)
        edge.frame = rotor.bounds
        edge.contentsScale = scale
        rotor.sublayers = [minor, major, edge]
    }

    /// As the drawing did: minor ticks at 0.8 of `opacity`, major ones at 1.25 (at most 1).
    func set(opacity: Double, transform: CATransform3D) {
        minor.opacity = Float(opacity * 0.8)
        major.opacity = Float(min(1, opacity * 1.25))
        rotor.transform = transform
    }
}

/// Pictures of SwiftUI drawings that only ever fade or move (blurs, gradients), made
/// once per size and kept (the last few dozen).
@MainActor
enum LayerArt {
    private static var cache: [String: CGImage] = [:]
    private static var order: [String] = []

    static func image(_ key: String, size: CGSize, scale: CGFloat, @ViewBuilder content: () -> some View) -> CGImage? {
        let k = "\(key)|\(size.width)x\(size.height)@\(scale)"
        if let hit = cache[k] { return hit }
        let renderer = ImageRenderer(content: ZStack { content() }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        cache[k] = image
        order.append(k)
        if order.count > 48 { cache[order.removeFirst()] = nil }
        return image
    }
}

/// Draws a frame of the ring's sweep: a bright arc round the edge the way it turns,
/// pink fading in to a white head (TrackballArt's `sweep`, in Core Graphics).
enum SweepPainter {
    /// The sweep starting at the top (the ring's angle is the layer's turn).
    static func image(side s: CGFloat, scale: CGFloat, length: Double, clockwise: Bool, ring: CGColor) -> CGImage? {
        let px = Int((s * scale).rounded(.up))
        guard px > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left points, as SwiftUI draws.
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: scale, y: -scale)
        let d = s * TrackballArt.ringRadius * 2
        let w = max(1.1, s * 0.0085)
        let sign: CGFloat = clockwise ? 1 : -1
        ctx.translateBy(x: s / 2, y: s / 2)
        ctx.rotate(by: -.pi / 2)
        ctx.scaleBy(x: sign, y: 1)
        ctx.addArc(center: .zero, radius: d / 2, startAngle: 0, endAngle: CGFloat(length * 2 * .pi), clockwise: false)
        ctx.setLineWidth(w * 1.6)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        // The angular gradient: clear pink → pink → white along the arc; past its end the gap
        // is white then clear, split halfway (as SwiftUI fills an angular gradient's gap).
        let c0 = ring.copy(alpha: 0) ?? ring, c1 = ring.copy(alpha: 0.9) ?? ring
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let gap = length + (1 - length) / 2
        guard let gradient = CGGradient(colorsSpace: space, colors: [c0, c1, white, white, c0, c0] as CFArray,
                                        locations: [0, length / 2, length, gap, gap, 1]) else { return nil }
        CGContextDrawConicGradient(ctx, gradient, .zero, 0)
        return ctx.makeImage()
    }
}

/// The ball's surface (BallSurface, in Core Graphics): soft pools and bright flecks
/// round a sphere, turned by a quaternion, drawn back to front. The spots' colors and
/// gradients are worked out once; each frame only places them.
final class BallSurfacePainter {
    private struct Spot {
        let at: SIMD3<Double>
        let radius: Double
        let strength: Double
        let gradient: CGGradient
    }

    private let spots: [Spot]
    private let base: CGGradient
    private let diameter: CGFloat
    private let scale: CGFloat
    private let context: CGContext?

    @MainActor init(theme: BallTheme, diameter: CGFloat, scale: CGFloat) {
        self.diameter = diameter
        self.scale = scale
        let env = EnvironmentValues()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func cg(_ c: Color) -> CGColor { c.resolve(in: env).cgColor }
        func gradient(_ stops: [(Color, CGFloat)]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: stops.map { cg($0.0) } as CFArray, locations: stops.map(\.1))!
        }
        let blue = theme.glow[1], violet = theme.glow[2]
        base = gradient([(blue, 0), (blue.mix(with: violet, by: 0.45), 1)])
        spots = BallSurface.spots(theme).map { spot in
            let stops: [(Color, CGFloat)] = spot.fleck
                ? [(spot.color, 0), (spot.color.opacity(0.6), 0.4), (spot.color.opacity(0), 1)]
                : [(spot.color, 0), (spot.color.opacity(0.88), 0.42), (spot.color.opacity(0), 1)]
            return Spot(at: spot.at, radius: spot.radius, strength: spot.strength, gradient: gradient(stops))
        }
        let px = Int((diameter * scale).rounded(.up))
        context = px > 0 ? CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) : nil
    }

    func image(orientation q: BallSpin.Quaternion) -> CGImage? {
        guard let ctx = context else { return nil }
        let px = CGFloat(ctx.width)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
        // Top-left points, as SwiftUI's Canvas draws.
        ctx.translateBy(x: 0, y: px)
        ctx.scaleBy(x: scale, y: -scale)
        let rad = Double(diameter) / 2
        let c = CGPoint(x: rad, y: rad)
        let disc = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        // The ball's own deep blue under everything.
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.drawRadialGradient(base, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        let placed = spots.map { (spot: $0, p: q.act($0.at)) }.sorted { $0.p.z < $1.p.z }
        for (spot, p) in placed {
            let s = sin(spot.radius)
            // Fades out as it goes round the edge; skipped once it's behind.
            let edge = (p.z + s * 0.7) / (0.22 + s * 0.7)
            guard edge > 0 else { continue }
            let fade = min(1, edge * edge * (3 - 2 * min(edge, 1)))
            let center = CGPoint(x: c.x + p.x * rad * cos(spot.radius * 0.35), y: c.y - p.y * rad * cos(spot.radius * 0.35))
            let r = rad * s
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: atan2(-p.y, p.x))
            ctx.scaleBy(x: max(p.z, 0.12), y: 1)      // foreshortened toward the edge
            ctx.setAlpha(spot.strength * fade)
            ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
            ctx.clip()
            ctx.drawRadialGradient(spot.gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
