import AppKit
import CoreGraphics
import QuartzCore

/// Turns scroll-ring ticks into scrolling that follows your hand.
///
/// The model has three parts:
///
/// **Gain** — each tick is worth `distance × G(rate)`. Slow turns are 1:1 for
/// precision; quick spins ramp smoothly up to `Gmax` (a smoothstep between 8
/// and 40 ticks/s). The first few ticks of any movement are never boosted, so
/// small nudges stay small.
///
/// **Follow** — the page is a critically damped spring chasing a *predicted*
/// target: the ring's position plus where the next tick should land given the
/// current spin rate (at most one tick ahead). A steady spin therefore has no
/// lag and no stop-start between ticks, and a single slow tick becomes a short
/// glide that starts on the very next frame.
///
/// **Throw** — only a real flick (fast, at least 4 ticks, not slowing down
/// when you let go) launches momentum, using macOS's own deceleration shape:
/// v(t) = v0·(1 − t/T)³ with T = c·v0^(1/3). It lands at a definite moment —
/// no long creeping tail. Turning the ring against a throw stops it dead;
/// turning it the same way takes over at the current speed.
///
/// Output is plain continuous (pixel) scroll events with no gesture phases, so
/// apps never add momentum of their own. Frames are evaluated at the display's
/// target timestamp. Everything runs on the engine's input thread.
final class SmoothScroller: NSObject {
    var config = GlideConfig()
    var telemetry: Telemetry?
    var diagnostics: Diagnostics?

    /// Clock and output are injectable so `scripts/scroll-sim` can drive this
    /// exact code with synthetic tick patterns.
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var output: ((_ delta: Double) -> Void)?
    var ballOutput: ((_ dx: Double, _ dy: Double) -> Void)?

    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private var running = false
    private var lastFrame: CFTimeInterval = 0

    private enum Mode { case idle, tracking, coasting, flying }
    private var mode = Mode.idle

    // Page state (points, along the active axis)
    private var position = 0.0           // where the page is
    private var speed = 0.0              // page velocity, points / second
    private var target = 0.0             // where the ring says the page belongs
    private var emitted = 0.0            // whole points already posted
    private var direction = 0.0          // +1 / −1
    private var horizontal = false
    private var flags: CGEventFlags = []

    // Ring rhythm
    private var window: [CFTimeInterval] = []   // same-direction tick times, last 120 ms
    private var intervals: [Double] = []        // recent tick intervals (for "braking")
    private var lastTick: CFTimeInterval = -1_000_000
    private var tickDistance = 0.0       // distance of the latest tick (points, unsigned)
    private var rate = 0.0               // ticks / second (smoothed)
    private var ticksInMovement = 0

    // Throw
    private var throwStart: CFTimeInterval = 0
    private var throwFrom = 0.0
    private var throwSpeed = 0.0
    private var throwDuration = 0.0

    func attach(_ link: CADisplayLink?) {
        self.link = link
        link?.isPaused = true
    }

    // MARK: Tuning (shared with the UI and the simulator)

    private static func smoothstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Gain for spin rate (ticks / second): 1 when slow, up to Gmax when fast.
    /// `amount` 0…1 maps to Gmax 1…9 (0.5 → 5, the research default).
    static func accelerationMultiplier(rate: Double, amount: Double) -> Double {
        let gMax = 1 + amount * 8
        return 1 + (gMax - 1) * smoothstep((rate - 8) / 32)
    }

    /// Spring stiffness ω (1/s). "Follow" 0 → 80 (locked to the ring), 1 → 25 (soft).
    static func followOmega(smoothness: Double) -> Double { 80 - 55 * min(max(smoothness, 0), 1) }

    /// For the settings label: the follow time constant you'll feel.
    static func timeConstant(smoothness: Double) -> Double { 1 / followOmega(smoothness: smoothness) }

    /// Momentum shape coefficient c in T = c·v0^(1/3). macOS uses ≈ 0.063.
    /// `throwAmount` 0 → 0.035 (short), 1 → 0.11 (long); 0.4 ≈ macOS.
    static func throwCoefficient(throwAmount: Double) -> Double { 0.035 + min(max(throwAmount, 0), 1) * 0.075 }

    static func throwDuration(speed v0: Double, throwAmount: Double) -> Double {
        throwCoefficient(throwAmount: throwAmount) * pow(abs(v0), 1.0 / 3)
    }

    /// How far a throw at `v0` points/s travels before landing.
    static func throwDistance(speed v0: Double, throwAmount: Double) -> Double {
        abs(v0) * throwDuration(speed: v0, throwAmount: throwAmount) / 4
    }

    static let throwMinSpeed = 800.0     // points / second at release
    static let throwMinTicks = 6         // ticks in the movement (and ≥ 4 in the last 120 ms)
    static let throwMaxSpeed = 12_000.0
    static let unboostedTicks = 3        // first ticks of a movement are never boosted

    // MARK: Input

    /// `ticks` is signed in macOS scroll direction.
    func addTicks(_ ticks: Double, horizontal wantHorizontal: Bool = false, flags: CGEventFlags) {
        guard ticks != 0 else { return }
        var flags = flags
        var isHorizontal = wantHorizontal
        if config.shiftScrollsHorizontally && flags.contains(.maskShift) { isHorizontal = true }
        if isHorizontal { flags.remove(.maskShift) }
        let t = config.reverseScroll ? -ticks : ticks
        let dir: Double = t > 0 ? 1 : -1
        let count = max(Int(abs(t).rounded()), 1)
        self.flags = flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate])
        let now = clock()
        let turned = dir != direction || isHorizontal != horizontal

        if config.scrollMode == .flywheel {
            flywheelTick(dir: dir, count: count, horizontal: isHorizontal, turned: turned, now: now)
            return
        }

        if mode == .coasting {
            if turned {
                // Turning against a throw catches it — and that's all this tick does.
                diagnostics?.record("caught throw")
                halt()
                lastTick = now
                return
            }
            // Same way: the ring takes over at the current speed.
            mode = .tracking
            target = position
            window.removeAll(); intervals.removeAll()
            ticksInMovement = Self.unboostedTicks
        }
        if turned {
            // Reversal or axis change: stop dead and start a fresh movement.
            halt()
        }
        direction = dir
        horizontal = isHorizontal

        // A pause starts a new movement: no boost for its first few ticks.
        if now - lastTick > 0.12 {
            window.removeAll(); intervals.removeAll()
            if mode != .tracking { ticksInMovement = 0 }
        } else {
            intervals.append(now - lastTick)
            if intervals.count > 4 { intervals.removeFirst() }
        }
        lastTick = now
        for _ in 0..<count { window.append(now) }
        window.removeAll { now - $0 > 0.12 }
        if window.count > 8 { window.removeFirst(window.count - 8) }
        let measured = window.count >= 2
            ? Double(window.count - 1) / max(now - window[0], 0.002 * Double(window.count - 1))
            : 0
        // Smooth the rate so jittery tick timing doesn't make the speed wobble.
        rate = rate == 0 || measured == 0 ? measured : rate + (measured - rate) * 0.4
        ticksInMovement += count

        // The boost phases in over a few ticks after the first unboosted ones,
        // so speeding up never lurches and small nudges stay small.
        let ramp = min(1, Double(max(ticksInMovement - Self.unboostedTicks, 0)) / 4)
        let gain = 1 + (Self.accelerationMultiplier(rate: rate, amount: config.scrollAcceleration) - 1) * ramp
        tickDistance = config.scrollDistance * gain
        let distance = Double(count) * tickDistance

        if !config.smoothScrolling {
            position += dir * distance
            target = position
            flush()
            return
        }

        target += dir * distance
        // Slow ticks get a velocity kick so they glide off on the next frame
        // instead of easing in; fast spins rely on the prediction instead.
        let w = predictionWeight
        speed += dir * (1 - w) * Self.followOmega(smoothness: config.scrollSmoothness) * distance
        mode = .tracking

        diagnostics?.record(String(format: "tick %+d  rate=%.0f/s gain=%.1f  target=%.0f page=%.0f",
                                   Int(dir) * count, rate, gain, target, position))
        start()
    }

    // MARK: Flywheel mode

    /// Flywheel friction time constant. `glide` 0 → 40 ms, 1 → 160 ms;
    /// 0.35 ≈ 82 ms, what Kensington's scrolling measured.
    static func flyTau(glide: Double) -> Double { 0.04 + min(max(glide, 0), 1) * 0.12 }

    /// Total distance one tick adds at a given spin rate. Shaped on Kensington's
    /// measured output: a few points when slow, hundreds when spun hard.
    static func flyTickDistance(rate: Double, distance: Double, acceleration: Double) -> Double {
        distance + 5.4 * acceleration * pow(max(rate - 6, 0), 1.3)
    }

    private var flyTicks: [CFTimeInterval] = []

    private func flywheelTick(dir: Double, count: Int, horizontal isHorizontal: Bool, turned: Bool, now: CFTimeInterval) {
        if turned || mode != .flying {
            // A reversal stops the page dead; a new push starts from rest.
            if turned { speed = 0 }
            flyTicks.removeAll()
        }
        direction = dir
        horizontal = isHorizontal
        for _ in 0..<count { flyTicks.append(now) }
        flyTicks.removeAll { now - $0 > 0.15 }
        let measured = flyTicks.count >= 2 ? Double(flyTicks.count - 1) / max(now - flyTicks[0], 0.004) : 0
        let distance = Double(count) * Self.flyTickDistance(rate: measured, distance: config.flyDistance,
                                                            acceleration: config.flyAcceleration)
        if !config.smoothScrolling {
            position += dir * distance
            flush()
            return
        }
        // A push: the speed that, fading with friction τ, travels exactly `distance`.
        speed += dir * distance / Self.flyTau(glide: config.flyGlide)
        speed = max(min(speed, Self.throwMaxSpeed), -Self.throwMaxSpeed)
        mode = .flying
        diagnostics?.record(String(format: "fly tick %+d rate=%.0f/s +%.0f pt  speed=%.0f", Int(dir) * count, measured, distance, speed))
        start()
    }

    private func fly(dt: Double) {
        let tau = Self.flyTau(glide: config.flyGlide)
        let fade = exp(-dt / tau)
        position += speed * tau * (1 - fade)       // exact distance under exponential friction
        speed *= fade
        if abs(speed) < 15 {                        // under ~1 pt left: land on it now
            position += speed * tau
            speed = 0
            mode = .idle
        }
    }

    /// How much to lead the ring: none for slow turns or the first ticks of a
    /// movement (they glide straight to their tick), full for a steady spin.
    private var predictionWeight: Double {
        Self.smoothstep((rate - 5) / 10) * min(1, Double(max(ticksInMovement - 1, 0)) / 3)
    }

    /// Stop all motion where the page is now.
    private func halt() {
        speed = 0
        target = position
        window.removeAll(); intervals.removeAll()
        ticksInMovement = 0
        mode = .idle
    }

    // MARK: Frame loop

    private func start() {
        guard !running else { return }
        running = true
        lastFrame = 0
        if let link {
            link.isPaused = false
        } else {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.frame() }
            RunLoop.current.add(t, forMode: .common)
            fallbackTimer = t
        }
        frame()   // respond on the same frame the tick arrived
    }

    private func stop() {
        running = false
        link?.isPaused = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// Display-synced: evaluate motion for the moment this frame hits the screen.
    @objc func step(_ link: CADisplayLink) { frame(at: link.targetTimestamp) }

    func frame(at time: CFTimeInterval? = nil) {
        let now = time ?? clock()
        let dt = lastFrame == 0 ? 1.0 / 120 : min(max(now - lastFrame, 1.0 / 240), 1.0 / 30)
        lastFrame = now

        switch mode {
        case .idle:
            break   // `flush` stops the loop once the ball is idle too
        case .tracking:
            track(now: now, dt: dt)
        case .coasting:
            coast(now: now)
        case .flying:
            fly(dt: dt)
        }
        ballFrame(dt: dt)
        flush()
    }

    private func track(now: CFTimeInterval, dt: Double) {
        let since = max(now - lastTick, 0)
        let releaseAfter = rate > 0 ? min(max(1.5 / rate, 0.025), 0.08) : 0.08
        let flick = config.throwEnabled && qualifiesForThrow()

        // Predict the ring: between ticks it moves at `rate`. The lead is
        // centred on the ring (half a tick behind just after a tick, half a
        // tick ahead just before the next), so a steady spin has no lag and
        // stopping overshoots by at most half a tick. During a flick the lead
        // stretches until the throw takes over, so the speed never dips.
        let w = predictionWeight
        let cap = flick ? 2.0 : 1.0      // a flick keeps its speed right up to the throw
        let progress = min(rate * since, cap)
        let predicted = target + direction * w * tickDistance * (progress - 0.5)
        let predictedSpeed = rate * since < cap ? direction * w * tickDistance * rate : 0

        // Critically damped spring toward the prediction (sub-stepped for accuracy).
        let omega = Self.followOmega(smoothness: config.scrollSmoothness)
        let steps = 4
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let accel = omega * omega * (predicted - position) + 2 * omega * (predictedSpeed - speed)
            speed += accel * h
            if speed * direction < 0 { speed = 0 }          // the page never runs backward
            position += speed * h
        }

        if since > releaseAfter && flick {
            let ringSpeed = tickDistance * rate
            let v0 = min(max(abs(speed), ringSpeed), Self.throwMaxSpeed)
            throwFrom = position
            throwSpeed = direction * v0
            throwDuration = Self.throwDuration(speed: v0, throwAmount: config.throwAmount)
            throwStart = now
            mode = .coasting
            diagnostics?.record(String(format: "throw at %.0f pt/s → lands in %.0f ms, %.0f pt",
                                       v0, throwDuration * 1000, v0 * throwDuration / 4))
            return
        }

        // Settled: the page has caught up with the ring.
        if since > releaseAfter && abs(predicted - position) < 0.5 && abs(speed) < 5 {
            target = position
            speed = 0
            mode = .idle
        }
    }

    /// A flick: fast enough, enough ticks, and not slowing down at the end.
    private func qualifiesForThrow() -> Bool {
        guard ticksInMovement >= Self.throwMinTicks, window.count >= 4,
              tickDistance * rate >= Self.throwMinSpeed else { return false }
        if intervals.count >= 4 {
            let last = intervals[intervals.count - 1]
            let previous = intervals[(intervals.count - 4)..<(intervals.count - 1)]
            let mean = previous.reduce(0, +) / Double(previous.count)
            if last > mean * 1.3 { return false }          // you were braking: you're aiming
        }
        return true
    }

    private func coast(now: CFTimeInterval) {
        let t = now - throwStart
        if t >= throwDuration {
            position = throwFrom + throwSpeed * throwDuration / 4
            halt()
            return
        }
        let left = 1 - t / throwDuration
        position = throwFrom + throwSpeed * throwDuration / 4 * (1 - pow(left, 4))
        speed = throwSpeed * pow(left, 3)
    }

    // MARK: Output

    /// Posts the whole points the page has moved since the last post.
    private func flush() {
        let pending = position - emitted
        // While moving, hold back fractions; once at rest, land on the nearest point.
        let whole = mode == .idle ? pending.rounded() : pending.rounded(.towardZero)
        if whole != 0 {
            emitted += whole
            post(whole)
        }
        if mode == .idle && ballMode == .idle { stop() }
    }

    // MARK: Scrolling with the ball

    /// Points scrolled per ball count at `ballScrollSpeed` 1 (~400 pt per inch of ball).
    static let ballPointsPerCount = 1.0
    /// Light smoothing so the ball's 125 Hz reports land evenly on 120 Hz frames.
    static let ballSmoothing = 0.016
    /// Only movement this recent counts toward the glide when the button is let go.
    static let ballGlideWindow = 0.06

    private enum BallMode { case idle, rolling, gliding }
    private var ballMode = BallMode.idle
    private var ballTarget = (x: 0.0, y: 0.0)    // where the ball says the page belongs
    private var ballPos = (x: 0.0, y: 0.0)       // smoothed
    private var ballEmitted = (x: 0.0, y: 0.0)   // whole points posted
    private var ballVel = (x: 0.0, y: 0.0)       // glide velocity, points / second
    private var ballRecent: [(t: CFTimeInterval, x: Double, y: Double)] = []

    var ballActive: Bool { ballMode != .idle }

    /// The ball-scroll button went down: the ball now scrolls.
    func beginBall() {
        ballMode = .rolling
        ballTarget = (0, 0); ballPos = (0, 0); ballEmitted = (0, 0); ballVel = (0, 0)
        ballRecent.removeAll()
    }

    /// Raw ball counts, already signed in macOS scroll direction.
    func addBallDelta(dx: Double, dy: Double) {
        guard ballMode == .rolling, dx != 0 || dy != 0 else { return }
        let gain = Self.ballPointsPerCount * max(config.ballScrollSpeed, 0) * (config.reverseScroll ? -1 : 1)
        let x = dx * gain, y = dy * gain
        let now = clock()
        ballTarget.x += x
        ballTarget.y += y
        ballRecent.append((now, x, y))
        ballRecent.removeAll { now - $0.t > Self.ballGlideWindow }
        start()
    }

    /// The button came up. With `glide`, a ball still rolling coasts briefly
    /// (Flywheel friction); otherwise the page just finishes where the ball put it.
    func endBall(glide: Bool = true) {
        guard ballMode == .rolling else { return }
        let now = clock()
        ballRecent.removeAll { now - $0.t > Self.ballGlideWindow }
        if glide && config.smoothScrolling && !ballRecent.isEmpty {
            let w = Self.ballGlideWindow
            ballVel.x = ballRecent.reduce(0) { $0 + $1.x } / w
            ballVel.y = ballRecent.reduce(0) { $0 + $1.y } / w
            let v = (ballVel.x * ballVel.x + ballVel.y * ballVel.y).squareRoot()
            if v > Self.throwMaxSpeed {
                ballVel.x *= Self.throwMaxSpeed / v
                ballVel.y *= Self.throwMaxSpeed / v
            }
        }
        ballRecent.removeAll()
        ballMode = .gliding
        diagnostics?.record(String(format: "ball scroll end, glide %.0f,%.0f pt/s", ballVel.x, ballVel.y))
        start()
    }

    /// Stops ball scrolling immediately, posting nothing more.
    func cancelBall() {
        ballMode = .idle
        ballVel = (0, 0)
        ballRecent.removeAll()
        if mode == .idle { stop() }
    }

    private func ballFrame(dt: Double) {
        guard ballMode != .idle else { return }
        if ballMode == .gliding, ballVel.x != 0 || ballVel.y != 0 {
            let tau = Self.flyTau(glide: config.flyGlide)
            let fade = exp(-dt / tau)
            ballTarget.x += ballVel.x * tau * (1 - fade)
            ballTarget.y += ballVel.y * tau * (1 - fade)
            ballVel.x *= fade
            ballVel.y *= fade
            if (ballVel.x * ballVel.x + ballVel.y * ballVel.y).squareRoot() < 15 {   // under ~1 pt left
                ballTarget.x += ballVel.x * tau
                ballTarget.y += ballVel.y * tau
                ballVel = (0, 0)
            }
        }
        let a = config.smoothScrolling ? 1 - exp(-dt / Self.ballSmoothing) : 1
        ballPos.x += (ballTarget.x - ballPos.x) * a
        ballPos.y += (ballTarget.y - ballPos.y) * a
        if ballMode == .gliding, ballVel.x == 0, ballVel.y == 0,
           abs(ballTarget.x - ballPos.x) < 0.5, abs(ballTarget.y - ballPos.y) < 0.5 {
            ballPos = ballTarget
            ballMode = .idle
        }
        // While moving, hold back fractions; once done, land on the nearest point.
        let px = ballPos.x - ballEmitted.x, py = ballPos.y - ballEmitted.y
        let wx = ballMode == .idle ? px.rounded() : px.rounded(.towardZero)
        let wy = ballMode == .idle ? py.rounded() : py.rounded(.towardZero)
        if wx != 0 || wy != 0 {
            ballEmitted.x += wx
            ballEmitted.y += wy
            postBall(dx: wx, dy: wy)
        }
    }

    private func postBall(dx: Double, dy: Double) {
        let x = Int32(dx), y = Int32(dy)
        guard x != 0 || y != 0 else { return }
        if let ballOutput { ballOutput(Double(x), Double(y)); return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: y, wheel2: x, wheel3: 0) else { return }
        if let loc = CGEvent(source: nil)?.location { e.location = loc }
        e.flags = []
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: Engine.syntheticTag)
        e.post(tap: .cgSessionEventTap)
        telemetry?.addScroll(points: (dx * dx + dy * dy).squareRoot())
    }

    private func post(_ delta: Double) {
        let d = Int32(delta)
        guard d != 0 else { return }
        if let output { output(Double(d)); return }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: horizontal ? 0 : d, wheel2: horizontal ? d : 0, wheel3: 0) else { return }
        if let loc = CGEvent(source: nil)?.location { e.location = loc }
        e.flags = flags
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: Engine.syntheticTag)
        e.post(tap: .cgSessionEventTap)
        telemetry?.addScroll(points: abs(Double(d)))
    }
}
