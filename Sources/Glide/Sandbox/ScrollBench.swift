import AppKit
import Metal
import QuartzCore
import SwiftUI

/// `Glide --scroll-bench [--pages overview,pointer,…|all] [--sizes 980x680,1440x900] [--seconds 3]
///                       [--hz 120] [--appearance dark|light] [--performance smooth|efficient|minimal]
///                       [--no-feed] [--no-hold] [--damage] [--drive wheel|offset] [--json file]`
///
/// How smoothly each page scrolls while the trackball is being used: the same
/// thing the owner does when he spins the scroll ring over Glideball's own window.
/// Usually run through `scripts/scroll-bench.sh`. Nothing is shown and nothing live
/// runs (Sandbox.swift); like `--render-ui`, the window is never ordered front.
///
/// For each page and window size it hosts the real `RootView` (or the real Settings
/// window) at 2x, then for `--seconds` at `--hz`:
///   - scrolls the page fast, down and back up, with the events Glideball's own
///     clip view moved each frame (`--drive offset`, the default), or with `--drive wheel`
///     the events Glideball's own scroll engine posts (continuous pixel deltas with no
///     phases, `SmoothScroller.post`) handed to the page's NSScrollView. Offscreen, AppKit
///     queues those for a display refresh that never comes, so the page doesn't move;
///     the mode still shows whether SwiftUI sees a scroll phase for them;
///   - feeds the model what the engine would while the ring turns: ring notches and
///     scrolled points into the real `Telemetry`, read by the real 20 Hz sampler
///     (`AppModel.sample`), so the light, the trackball, the live graphs, today's
///     numbers and the badges all change as they do in the app (`--no-feed` turns that off);
///   - times each frame: the main thread's work (the scroll, SwiftUI's updates, layout,
///     drawing, the Core Animation commit, timers and timelines that ran before the next
///     frame) and, separately, Core Animation's renderer compositing the window into a
///     Metal texture (glass, blurs, shadows, offscreen passes);
///   - counts how often the heavy views were rebuilt (`PerfProbe`).
///
/// What it can't see: WindowServer's own compositing and the display's timing (the
/// renderer here redraws the whole window every frame, which a real display only does
/// when everything moved, as it does while scrolling); hover (no pointer over an
/// offscreen window); and whether events arrive evenly spaced (here they're perfectly
/// even). So the numbers are for comparing before and after, not frame rates you'd see.
@MainActor
enum ScrollBench {
    enum Target: Equatable {
        case tab(GlideTab)
        case settings(SettingsPane)

        var name: String {
            switch self {
            case .tab(let t):
                switch t {
                case .overview: "overview"
                case .pointer: "pointer"
                case .scroll: "scrolling"
                case .buttons: "buttons"
                case .apps: "apps"
                case .backup: "sync"
                }
            case .settings(let p): "settings-\(p.rawValue)"
            }
        }

        static let all: [Target] = GlideTab.allCases.map { .tab($0) } + [.settings(.general), .settings(.look), .settings(.shortcuts)]
    }

    enum Drive: String { case wheel, offset }

    struct Options {
        var targets: [Target] = Target.all
        var sizes: [NSSize] = [NSSize(width: 980, height: 680), NSSize(width: 1440, height: 900)]
        var seconds = 3.0
        var hz = 120.0
        var dark = true
        var feed = true
        var drive = Drive.offset
        var performance: PerformanceMode?
        var json: URL?
        /// Measure without slowing anything while the page scrolls (`AppModel.holdWhileScrolling`).
        var hold = true
        /// Composite only what changed each frame (as WindowServer does), not the whole window.
        var damageOnly = false
    }

    struct Result {
        var name: String
        var size: NSSize
        var cpu: [Double] = []        // ms per frame, main thread
        var gpu: [Double] = []        // ms per frame, compositing
        var counts: [String: Int] = [:]
        var travel: CGFloat = 0       // points actually scrolled
        var range: CGFloat = 0        // how far the page can scroll
        var phaseSeen = false         // SwiftUI reported a scroll phase (AppModel.pageScrolling)
        var litFrames = 0             // frames with the hand's light awake (the feed is working)
        var note: String?
    }

    static func start() {
        let options = parse()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = RenderUI.Launcher { run(options) }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    // MARK: Arguments

    private static func parse() -> Options {
        var args = Array(CommandLine.arguments.dropFirst())
        args.removeAll { $0 == "--scroll-bench" }
        func fail(_ message: String) -> Never {
            print("error: \(message)")
            print("usage: Glide --scroll-bench [--pages overview,pointer,…|all] [--sizes 980x680,1440x900] [--seconds 3] [--hz 120] [--appearance dark|light] [--performance smooth|efficient|minimal] [--no-feed] [--no-hold] [--damage] [--drive wheel|offset] [--json file]")
            exit(2)
        }
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail("\(flag) needs a value") }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        var o = Options()
        if let pages = value(after: "--pages"), pages != "all" {
            o.targets = pages.split(separator: ",").map { name in
                let n = name.trimmingCharacters(in: .whitespaces)
                if n == "settings" { return Target.all.filter { if case .settings = $0 { true } else { false } } }
                guard let t = Target.all.first(where: { $0.name == n })
                        ?? SettingsPane(rawValue: n.replacingOccurrences(of: "settings-", with: "")).map({ Target.settings($0) })
                else { fail("unknown page \(n) (have: \(Target.all.map(\.name).joined(separator: ", ")))") }
                return [t]
            }.flatMap { $0 }
        }
        if let sizes = value(after: "--sizes") {
            o.sizes = sizes.split(separator: ",").map { s in
                let p = s.split(separator: "x").compactMap { Double($0) }
                guard p.count == 2, p[0] >= 400, p[1] >= 300 else { fail("--sizes is like 980x680,1440x900") }
                return NSSize(width: p[0], height: p[1])
            }
        }
        if let s = value(after: "--seconds") { guard let v = Double(s), v > 0.2 else { fail("--seconds is a number") }; o.seconds = v }
        if let s = value(after: "--hz") { guard let v = Double(s), v >= 30, v <= 240 else { fail("--hz is 30…240") }; o.hz = v }
        if let a = value(after: "--appearance") {
            guard a == "dark" || a == "light" else { fail("--appearance is dark or light") }
            o.dark = a == "dark"
        }
        if let p = value(after: "--performance") {
            guard let m = PerformanceMode(rawValue: p) else { fail("--performance is smooth, efficient or minimal") }
            o.performance = m
        }
        if let d = value(after: "--drive") {
            guard let v = Drive(rawValue: d) else { fail("--drive is wheel or offset") }
            o.drive = v
        }
        if let j = value(after: "--json") { o.json = URL(fileURLWithPath: j) }
        if let i = args.firstIndex(of: "--no-feed") { args.remove(at: i); o.feed = false }
        if let i = args.firstIndex(of: "--no-hold") { args.remove(at: i); o.hold = false }
        if let i = args.firstIndex(of: "--damage") { args.remove(at: i); o.damageOnly = true }
        let unknown = args.filter { $0.hasPrefix("--") }
        if !unknown.isEmpty { fail("unknown option \(unknown[0])") }
        return o
    }

    // MARK: Running

    private static func run(_ o: Options) {
        Offscreen.layoutScale = 2
        NSApp.appearance = NSAppearance(named: o.dark ? .darkAqua : .aqua)
        DemoData.seed()
        let model = AppModel.shared
        DemoData.prime(model)
        if let p = o.performance { model.performance = p }
        AppModel.holdWhileScrolling = o.hold
        // A live feed with a real clock (renders freeze it).
        model.live.lightClockFrozen = false
        model.live.reset()
        if o.feed {
            // As the window's delegate says when it's in front: starts the real sampler.
            model.windowStateChanged(visible: true, key: true)
        }
        print("scroll-bench: \(o.targets.count) page(s) × \(o.sizes.count) size(s), \(o.seconds) s at \(Int(o.hz)) Hz, 2x, \(o.dark ? "dark" : "light"), "
              + "performance \(model.performance.rawValue), feed \(o.feed ? "on" : "off"), drive \(o.drive.rawValue), hold \(o.hold ? "on" : "off")")

        var results: [Result] = []
        for target in o.targets {
            for size in o.sizes {
                let r = bench(target, size: size, options: o, model: model)
                results.append(r)
                print(String(format: "  %@ %dx%d: main p95 %.2f ms, composite p95 %.2f ms", r.name, Int(size.width), Int(size.height),
                             percentile(r.cpu, 0.95), percentile(r.gpu, 0.95)))
            }
        }
        report(results, options: o)
        exit(0)
    }

    /// One page at one size.
    private static func bench(_ target: Target, size: NSSize, options o: Options, model: AppModel) -> Result {
        var result = Result(name: target.name, size: size)
        let appearance = NSAppearance(named: o.dark ? .darkAqua : .aqua)
        var window: NSWindow
        let content: NSView
        var settingsController: SettingsWindowController?
        switch target {
        case .tab(let tab):
            UserDefaults.standard.set(tab.rawValue, forKey: "GlideInitialTab")
            // Animations stay on (unlike a render): they're part of what a scroll costs.
            let hosting = NSHostingView(rootView: RootView(model: model))
            hosting.sizingOptions = []
            window = Offscreen.makeWindow(size: size, chrome: .mainWindow, appearance: appearance)
            window.contentView = hosting
            window.setContentSize(size)
            content = hosting
            UserDefaults.standard.removeObject(forKey: "GlideInitialTab")
        case .settings(let pane):
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsWindowController.lastPaneKey)
            SettingsWindowController.sandboxScreenHeight = size.height
            let controller = SettingsWindowController()
            settingsController = controller
            guard let w = controller.window, let c = w.contentView else {
                result.note = "no Settings window"
                return result
            }
            w.appearance = appearance
            w.animationBehavior = .none
            Offscreen.lookActive(w)
            window = w
            content = c
        }
        defer {
            if case .tab = target { window.contentView = nil }
            window.close()
            SettingsWindowController.sandboxScreenHeight = nil
            withExtendedLifetime(settingsController) {}
        }
        Offscreen.settleDown(content, seconds: 0.8)
        Offscreen.settleDown(content, seconds: 0.2)

        guard let scroll = pageScrollView(in: content, target: target), let doc = scroll.documentView else {
            result.note = "no scroll view found"
            return result
        }
        let clip = scroll.contentView
        let range = max(doc.frame.height - clip.bounds.height, 0)
        result.range = range
        guard range > 20 else {
            result.note = "fits without scrolling at this size"
            return result
        }
        clip.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? 0 : range))
        scroll.reflectScrolledClipView(clip)
        Offscreen.settleDown(content, seconds: 0.2)

        guard let renderer = LentRenderer(view: content, scale: 2) else {
            result.note = "no Metal renderer"
            return result
        }
        defer { renderer.restore() }
        renderer.damageOnly = o.damageOnly
        let busy = BusyMeter()
        _ = renderer.render()   // the first frame builds every texture; not a scroll frame
        // As if the page had been open a moment (right after a page change, a move isn't a scroll).
        model.pageStopped()
        Sandbox.spin(0.5)
        _ = PerfProbe.take()

        // Down the page and back up, again and again: a smooth curve whose top speed is
        // about 2,500 pt/s (a fast spin of the ring in Flywheel), never past either end.
        let topSpeed = 2_500.0
        let period = min(max(.pi * Double(range) / topSpeed, 0.5), 3.0)
        func goal(_ t: Double) -> Double { Double(range) / 2 * (1 - cos(2 * .pi * t / period)) }
        let frames = Int(o.seconds * o.hz)
        let dt = 1 / o.hz
        var notchDebt = 0.0
        let telemetry = model.engine.telemetry
        var position = 0.0
        func offset() -> Double {
            let y = Double(clip.bounds.origin.y)
            return doc.isFlipped ? y : Double(range) - y
        }
        let start = CACurrentMediaTime()
        for i in 0..<frames {
            let deadline = start + Double(i + 1) * dt
            let want = goal(Double(i + 1) * dt)
            let before = offset()
            // Whole points, as SmoothScroller posts them.
            let delta = (want - before).rounded(.towardZero)

            let t0 = CACurrentMediaTime()
            if delta != 0 {
                switch o.drive {
                case .wheel: wheel(scroll, by: delta)
                case .offset:
                    let y = doc.isFlipped ? before + delta : Double(range) - (before + delta)
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                    scroll.reflectScrolledClipView(clip)
                }
                if o.feed {
                    // What the engine records for this much scrolling: about one ring notch per 80 pt.
                    telemetry.addScroll(points: abs(delta))
                    notchDebt += abs(delta) / 80
                    while notchDebt >= 1 { notchDebt -= 1; telemetry.addNotch(direction: delta > 0 ? -1 : 1) }
                }
            }
            // The live views' timelines (30 a second), which an offscreen window never ticks.
            if o.feed, i % max(Int(o.hz / 30), 1) == 0 { model.live.benchTick() }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            CATransaction.flush()
            let t1 = CACurrentMediaTime()
            let gpu = renderer.render()
            // Until the next frame: timers (the sampler), timelines, SwiftUI's own updates.
            let idle = busy.spin(until: deadline)
            result.cpu.append((t1 - t0) * 1000 + idle)
            result.gpu.append(gpu)
            let after = offset()
            result.travel += CGFloat(abs(after - before))
            position = after
            if model.pageScrolling { result.phaseSeen = true }
            if model.live.lightAwake { result.litFrames += 1 }
        }
        _ = position
        if o.damageOnly { print(String(format: "  (%@ %dx%d: median update region %.0f%% of the window)", target.name, Int(size.width), Int(size.height), 100 * percentile(renderer.damage, 0.5))) }
        if renderer.retaken > 0 || content.layer !== renderer.lentLayer {
            print("  (\(target.name) \(Int(size.width))x\(Int(size.height)): AppKit took the window's layer back \(renderer.retaken)× and it was lent again"
                  + (content.layer !== renderer.lentLayer ? "; the view has a new layer, so the composite times are of an old one" : "") + ")")
        }
        result.counts = PerfProbe.take()
        // Let the light and the trace settle before the next page, so each starts the same way.
        model.pageStopped()
        Sandbox.spin(1.2)
        model.live.reset()
        _ = PerfProbe.take()
        return result
    }

    /// The page's own scroll view: the biggest one under `view` (the sidebar doesn't
    /// scroll; Scrolling's "Try it here" is a small scroll view inside the page).
    private static func pageScrollView(in view: NSView, target: Target) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// One scroll event like `SmoothScroller.post`: continuous, whole pixels, no phase.
    /// `delta` + = further down the page.
    private static func wheel(_ scroll: NSScrollView, by delta: Double) {
        let d = Int32(max(min(-delta, 100_000), -100_000))
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: d, wheel2: 0, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let w = scroll.window {
            let p = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            let screen = w.convertPoint(toScreen: p)
            e.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        }
        guard let event = NSEvent(cgEvent: e) else { return }
        scroll.scrollWheel(with: event)
    }

    // MARK: Measuring

    /// Runs the main run loop until `deadline` and returns how long (ms) it was busy
    /// rather than waiting: timers, sources, SwiftUI's and Core Animation's observers.
    final class BusyMeter {
        private var since: CFTimeInterval?
        private var total = 0.0
        private var observer: CFRunLoopObserver?

        init() {
            let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .afterWaiting]).rawValue, true,
                                                       CFIndex.max) { [weak self] _, activity in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .beforeWaiting {
                    if let s = self.since { self.total += now - s }
                    self.since = nil
                } else {
                    self.since = now
                }
            }
            observer = o
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        }

        deinit { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }

        func spin(until deadline: CFTimeInterval) -> Double {
            total = 0
            since = CACurrentMediaTime()
            // At least one pass even when this frame is already late, so timers (the sampler) still fire.
            RunLoop.main.run(mode: .default, before: Date())
            while CACurrentMediaTime() < deadline {
                let left = deadline - CACurrentMediaTime()
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: max(left, 0)))
            }
            if let s = since { total += CACurrentMediaTime() - s }
            since = nil
            return total * 1000
        }
    }

    /// A view's layer tree lent to Core Animation's renderer for the whole run (as
    /// `Offscreen.image` does for one picture), so each frame can be composited and timed.
    final class LentRenderer {
        private let layer: CALayer
        var lentLayer: CALayer { layer }
        private let holder: CALayer
        private let parent: CALayer?
        private let index: UInt32?
        private let frame: CGRect
        private let renderer: CARenderer
        private let queue: MTLCommandQueue

        init?(view: NSView, scale: CGFloat) {
            let bounds = view.bounds
            let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
            guard w > 0, h > 0, let layer = view.layer, let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: desc) else { return nil }
            renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 kCARendererMetalCommandQueue: queue])
            self.queue = queue
            self.layer = layer
            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: w, height: h)
            holder = CALayer()
            holder.anchorPoint = .zero
            holder.bounds = CGRect(origin: .zero, size: bounds.size)
            holder.position = .zero
            holder.transform = CATransform3DMakeScale(scale, scale, 1)
            root.addSublayer(holder)
            parent = layer.superlayer
            index = parent?.sublayers?.firstIndex(of: layer).map(UInt32.init)
            frame = layer.frame
            layer.removeFromSuperlayer()
            holder.addSublayer(layer)
            layer.frame = CGRect(origin: .zero, size: bounds.size)
            renderer.layer = root
            renderer.bounds = root.frame
            CATransaction.flush()
        }

        /// Times AppKit took the layer back into the window mid-run.
        private(set) var retaken = 0
        var damageOnly = false
        /// Each frame's update region, as a share of the window.
        var damage: [Double] = []

        /// Composites one frame of the whole window and waits for the GPU; ms.
        func render() -> Double {
            // AppKit sometimes puts the view's layer back into the window's own tree (a
            // page's layout changing under the sidebar did it on Overview); the renderer
            // then had nothing to draw and frames "took" 0.05 ms. Lend it again.
            if layer.superlayer !== holder {
                retaken += 1
                layer.removeFromSuperlayer()
                holder.addSublayer(layer)
                layer.frame = CGRect(origin: .zero, size: holder.bounds.size)
                CATransaction.flush()
            }
            let t0 = CACurrentMediaTime()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            if !damageOnly { renderer.addUpdate(renderer.bounds) }
            let ub = renderer.updateBounds()
            damage.append(ub.isNull ? 0 : Double(ub.width * ub.height / (renderer.bounds.width * renderer.bounds.height)))
            renderer.render()
            renderer.endFrame()
            let fence = queue.makeCommandBuffer()
            fence?.commit()
            fence?.waitUntilCompleted()
            return (CACurrentMediaTime() - t0) * 1000
        }

        func restore() {
            layer.removeFromSuperlayer()
            if let parent { parent.insertSublayer(layer, at: index ?? 0) }
            layer.frame = frame
        }
    }

    // MARK: Report

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    private static func report(_ results: [Result], options o: Options) {
        let budget = 1000 / o.hz
        print("")
        print(String(format: "Per frame, ms (budget %.2f ms at %d Hz). main = main-thread work; comp = compositing (CARenderer, GPU wait).", budget, Int(o.hz)))
        print("page               size        frames  main med   p95    max | comp med   p95    max | over  travel  held   lit")
        for r in results {
            let name = r.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            let size = "\(Int(r.size.width))x\(Int(r.size.height))".padding(toLength: 10, withPad: " ", startingAt: 0)
            if let note = r.note {
                print("\(name) \(size)  – \(note)")
                continue
            }
            let over = zip(r.cpu, r.gpu).filter { $0 + $1 > budget }.count
            print(String(format: "%@ %@ %6d  %7.2f %6.2f %6.2f | %7.2f %6.2f %6.2f | %4d  %6.0f  %-5@  %3.0f%%",
                         name, size, r.cpu.count,
                         percentile(r.cpu, 0.5), percentile(r.cpu, 0.95), r.cpu.max() ?? 0,
                         percentile(r.gpu, 0.5), percentile(r.gpu, 0.95), r.gpu.max() ?? 0,
                         over, Double(r.travel), r.phaseSeen ? "yes" : "no", 100 * Double(r.litFrames) / Double(max(r.cpu.count, 1)))
                  // A page with little to scroll still composites every frame, but it hardly moves:
                  // its numbers say more about the window than about scrolling.
                  + (r.range < 200 ? String(format: "  (scrolls only %.0f pt)", Double(r.range)) : ""))
        }
        print("")
        print("over: frames whose main + comp went past the budget. held: the page reported scrolling (AppModel.pageScrolling).")
        print("lit: frames with the hand's light awake (the feed reached the model).")
        print("")
        print("Slowest frames (main + comp, ms @ frame number):")
        for r in results where r.note == nil {
            let worst = zip(r.cpu, r.gpu).enumerated().map { ($0.offset, $0.element.0 + $0.element.1) }
                .sorted { $0.1 > $1.1 }.prefix(5)
            print("  \(r.name) \(Int(r.size.width))x\(Int(r.size.height)): " + worst.map { String(format: "%.0f@%d", $0.1, $0.0) }.joined(separator: ", "))
        }
        print("")
        print("Rebuilds per second while scrolling (PerfProbe):")
        let keys = Set(results.flatMap { $0.counts.keys }).sorted()
        for r in results where r.note == nil {
            let line = keys.compactMap { k -> String? in
                guard let n = r.counts[k], n > 0 else { return nil }
                return "\(k) \(String(format: "%.1f", Double(n) / o.seconds))"
            }.joined(separator: ", ")
            print("  \(r.name) \(Int(r.size.width))x\(Int(r.size.height)): \(line.isEmpty ? "nothing" : line)")
        }
        guard let url = o.json else { return }
        let rows: [[String: Any]] = results.map { r in
            var row: [String: Any] = ["page": r.name, "width": Int(r.size.width), "height": Int(r.size.height),
                                      "frames": r.cpu.count, "travel": Double(r.travel), "range": Double(r.range),
                                      "phaseSeen": r.phaseSeen, "litFrames": r.litFrames, "counts": r.counts]
            if let note = r.note { row["note"] = note }
            if !r.cpu.isEmpty {
                row["main"] = ["median": percentile(r.cpu, 0.5), "p95": percentile(r.cpu, 0.95), "max": r.cpu.max() ?? 0]
                row["composite"] = ["median": percentile(r.gpu, 0.5), "p95": percentile(r.gpu, 0.95), "max": r.gpu.max() ?? 0]
                row["overBudget"] = zip(r.cpu, r.gpu).filter { $0 + $1 > budget }.count
            }
            return row
        }
        let doc: [String: Any] = ["hz": o.hz, "seconds": o.seconds, "feed": o.feed, "drive": o.drive.rawValue,
                                  "dark": o.dark, "results": rows]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            print("\nJSON: \(url.path)")
        }
    }
}
