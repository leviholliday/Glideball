using System;
using System.Collections.Generic;
using Glideball.Core.Settings;

namespace Glideball.Core.Scrolling;

/// <summary>
/// A line-by-line port of the Mac's <c>SmoothScroller.swift</c>: turns
/// scroll-ring ticks into scrolling that follows your hand. See the Swift file
/// for the full reasoning; the short version:
///
/// Follow — each tick is worth distance × gain(rate); the page is a critically
/// damped spring chasing a predicted target; only a real flick throws, with
/// macOS's v(t) = v0·(1 − t/T)³ shape.
///
/// Flywheel (default) — each tick pushes the page, exponential friction
/// (τ ≈ 82 ms, measured from Kensington's driver) slows it.
///
/// Output is whole points (Mac points ≈ Windows logical pixels); the Windows
/// host converts them to sub-120 wheel deltas. Not thread-safe: the host
/// serialises calls with a lock.
/// </summary>
public sealed class SmoothScroller
{
    public GlideConfig Config { get; set; } = new();

    /// <summary>Seconds, monotonic. Injectable for tests.</summary>
    public Func<double> Clock { get; set; } = () => 0;
    /// <summary>Whole points along the active axis.</summary>
    public Action<double, bool>? Output { get; set; }
    /// <summary>Whole points (dx, dy) from "Scroll with ball".</summary>
    public Action<double, double>? BallOutput { get; set; }
    /// <summary>Raised when the frame loop should start (true) or may stop (false).</summary>
    public Action<bool>? RunningChanged { get; set; }

    public bool IsRunning => running;

    private bool running;
    private double lastFrame;

    private enum Mode { Idle, Tracking, Coasting, Flying }
    private Mode mode = Mode.Idle;

    private double position, speed, target, emitted, direction;
    private bool horizontal;

    private readonly List<double> window = new();
    private readonly List<double> intervals = new();
    private double lastTick = -1_000_000;
    private double tickDistance;
    private double rate;
    private int ticksInMovement;

    private double throwStart, throwFrom, throwSpeed, throwDuration;

    // MARK: Tuning

    private static double Smoothstep(double u)
    {
        var x = Math.Min(Math.Max(u, 0), 1);
        return x * x * (3 - 2 * x);
    }

    public static double AccelerationMultiplier(double rate, double amount)
    {
        var gMax = 1 + amount * 8;
        return 1 + (gMax - 1) * Smoothstep((rate - 8) / 32);
    }

    public static double FollowOmega(double smoothness) => 80 - 55 * Math.Min(Math.Max(smoothness, 0), 1);
    public static double TimeConstant(double smoothness) => 1 / FollowOmega(smoothness);
    public static double ThrowCoefficient(double throwAmount) => 0.035 + Math.Min(Math.Max(throwAmount, 0), 1) * 0.075;
    public static double ThrowDurationFor(double v0, double throwAmount) => ThrowCoefficient(throwAmount) * Math.Pow(Math.Abs(v0), 1.0 / 3);
    public static double ThrowDistance(double v0, double throwAmount) => Math.Abs(v0) * ThrowDurationFor(v0, throwAmount) / 4;

    public const double ThrowMinSpeed = 800.0;
    public const int ThrowMinTicks = 6;
    public const double ThrowMaxSpeed = 12_000.0;
    public const int UnboostedTicks = 3;

    // Swift's rounding: .rounded() is half away from zero, .towardZero truncates.
    private static double Round(double x) => Math.Round(x, MidpointRounding.AwayFromZero);

    // MARK: Input

    /// <summary><paramref name="ticks"/> is signed: + scrolls up (wheel forward).</summary>
    public void AddTicks(double ticks, bool wantHorizontal = false, bool shift = false)
    {
        if (ticks == 0) return;
        var isHorizontal = wantHorizontal;
        if (Config.ShiftScrollsHorizontally && shift) isHorizontal = true;
        var t = Config.ReverseScroll ? -ticks : ticks;
        double dir = t > 0 ? 1 : -1;
        var count = Math.Max((int)Round(Math.Abs(t)), 1);
        var now = Clock();
        var turned = dir != direction || isHorizontal != horizontal;

        if (Config.ScrollMode == ScrollMode.Flywheel)
        {
            FlywheelTick(dir, count, isHorizontal, turned, now);
            return;
        }

        if (mode == Mode.Coasting)
        {
            if (turned)
            {
                // Turning against a throw catches it — and that's all this tick does.
                Halt();
                lastTick = now;
                return;
            }
            mode = Mode.Tracking;
            target = position;
            window.Clear(); intervals.Clear();
            ticksInMovement = UnboostedTicks;
        }
        if (turned) Halt();
        direction = dir;
        horizontal = isHorizontal;

        if (now - lastTick > 0.12)
        {
            window.Clear(); intervals.Clear();
            if (mode != Mode.Tracking) ticksInMovement = 0;
        }
        else
        {
            intervals.Add(now - lastTick);
            if (intervals.Count > 4) intervals.RemoveAt(0);
        }
        lastTick = now;
        for (var i = 0; i < count; i++) window.Add(now);
        window.RemoveAll(w => now - w > 0.12);
        if (window.Count > 8) window.RemoveRange(0, window.Count - 8);
        var measured = window.Count >= 2
            ? (window.Count - 1) / Math.Max(now - window[0], 0.002 * (window.Count - 1))
            : 0;
        rate = rate == 0 || measured == 0 ? measured : rate + (measured - rate) * 0.4;
        ticksInMovement += count;

        var ramp = Math.Min(1, Math.Max(ticksInMovement - UnboostedTicks, 0) / 4.0);
        var gain = 1 + (AccelerationMultiplier(rate, Config.ScrollAcceleration) - 1) * ramp;
        tickDistance = Config.ScrollDistance * gain;
        var distance = count * tickDistance;

        if (!Config.SmoothScrolling)
        {
            position += dir * distance;
            target = position;
            Flush();
            return;
        }

        target += dir * distance;
        var w = PredictionWeight;
        speed += dir * (1 - w) * FollowOmega(Config.ScrollSmoothness) * distance;
        mode = Mode.Tracking;
        Start();
    }

    // MARK: Flywheel

    public static double FlyTau(double glide) => 0.04 + Math.Min(Math.Max(glide, 0), 1) * 0.12;

    public static double FlyTickDistance(double rate, double distance, double acceleration) =>
        distance + 5.4 * acceleration * Math.Pow(Math.Max(rate - 6, 0), 1.3);

    private readonly List<double> flyTicks = new();

    private void FlywheelTick(double dir, int count, bool isHorizontal, bool turned, double now)
    {
        if (turned || mode != Mode.Flying)
        {
            if (turned) speed = 0;
            flyTicks.Clear();
        }
        direction = dir;
        horizontal = isHorizontal;
        for (var i = 0; i < count; i++) flyTicks.Add(now);
        flyTicks.RemoveAll(x => now - x > 0.15);
        var measured = flyTicks.Count >= 2 ? (flyTicks.Count - 1) / Math.Max(now - flyTicks[0], 0.004) : 0;
        var distance = count * FlyTickDistance(measured, Config.FlyDistance, Config.FlyAcceleration);
        if (!Config.SmoothScrolling)
        {
            position += dir * distance;
            Flush();
            return;
        }
        speed += dir * distance / FlyTau(Config.FlyGlide);
        speed = Math.Max(Math.Min(speed, ThrowMaxSpeed), -ThrowMaxSpeed);
        mode = Mode.Flying;
        Start();
    }

    private void Fly(double dt)
    {
        var tau = FlyTau(Config.FlyGlide);
        var fade = Math.Exp(-dt / tau);
        position += speed * tau * (1 - fade);
        speed *= fade;
        if (Math.Abs(speed) < 15)
        {
            position += speed * tau;
            speed = 0;
            mode = Mode.Idle;
        }
    }

    private double PredictionWeight =>
        Smoothstep((rate - 5) / 10) * Math.Min(1, Math.Max(ticksInMovement - 1, 0) / 3.0);

    private void Halt()
    {
        speed = 0;
        target = position;
        window.Clear(); intervals.Clear();
        ticksInMovement = 0;
        mode = Mode.Idle;
    }

    /// <summary>Stops everything immediately and forgets all motion (pause, quit).</summary>
    public void Reset()
    {
        Halt();
        flyTicks.Clear();
        emitted = position;
        ballMode = BallMode.Idle;
        ballVel = (0, 0);
        ballRecent.Clear();
        Stop();
    }

    // MARK: Frame loop

    private void Start()
    {
        if (running) return;
        running = true;
        lastFrame = 0;
        RunningChanged?.Invoke(true);
        Frame();   // respond on the same frame the tick arrived
    }

    private void Stop()
    {
        if (!running) return;
        running = false;
        RunningChanged?.Invoke(false);
    }

    public void Frame(double? time = null)
    {
        var now = time ?? Clock();
        var dt = lastFrame == 0 ? 1.0 / 120 : Math.Min(Math.Max(now - lastFrame, 1.0 / 240), 1.0 / 30);
        lastFrame = now;

        switch (mode)
        {
            case Mode.Idle: break;
            case Mode.Tracking: Track(now, dt); break;
            case Mode.Coasting: Coast(now); break;
            case Mode.Flying: Fly(dt); break;
        }
        BallFrame(dt);
        Flush();
    }

    private void Track(double now, double dt)
    {
        var since = Math.Max(now - lastTick, 0);
        var releaseAfter = rate > 0 ? Math.Min(Math.Max(1.5 / rate, 0.025), 0.08) : 0.08;
        var flick = Config.ThrowEnabled && QualifiesForThrow();

        var w = PredictionWeight;
        var cap = flick ? 2.0 : 1.0;
        var progress = Math.Min(rate * since, cap);
        var predicted = target + direction * w * tickDistance * (progress - 0.5);
        var predictedSpeed = rate * since < cap ? direction * w * tickDistance * rate : 0;

        var omega = FollowOmega(Config.ScrollSmoothness);
        const int steps = 4;
        var h = dt / steps;
        for (var i = 0; i < steps; i++)
        {
            var accel = omega * omega * (predicted - position) + 2 * omega * (predictedSpeed - speed);
            speed += accel * h;
            if (speed * direction < 0) speed = 0;
            position += speed * h;
        }

        if (since > releaseAfter && flick)
        {
            var ringSpeed = tickDistance * rate;
            var v0 = Math.Min(Math.Max(Math.Abs(speed), ringSpeed), ThrowMaxSpeed);
            throwFrom = position;
            throwSpeed = direction * v0;
            throwDuration = ThrowDurationFor(v0, Config.ThrowAmount);
            throwStart = now;
            mode = Mode.Coasting;
            return;
        }

        if (since > releaseAfter && Math.Abs(predicted - position) < 0.5 && Math.Abs(speed) < 5)
        {
            target = position;
            speed = 0;
            mode = Mode.Idle;
        }
    }

    private bool QualifiesForThrow()
    {
        if (ticksInMovement < ThrowMinTicks || window.Count < 4 || tickDistance * rate < ThrowMinSpeed) return false;
        if (intervals.Count >= 4)
        {
            var last = intervals[intervals.Count - 1];
            // Summed left to right like Swift's reduce, so results match bit for bit.
            var mean = (intervals[intervals.Count - 4] + intervals[intervals.Count - 3] + intervals[intervals.Count - 2]) / 3;
            if (last > mean * 1.3) return false;   // braking: you're aiming
        }
        return true;
    }

    private void Coast(double now)
    {
        var t = now - throwStart;
        if (t >= throwDuration)
        {
            position = throwFrom + throwSpeed * throwDuration / 4;
            Halt();
            return;
        }
        var left = 1 - t / throwDuration;
        position = throwFrom + throwSpeed * throwDuration / 4 * (1 - Math.Pow(left, 4));
        speed = throwSpeed * Math.Pow(left, 3);
    }

    // MARK: Output

    private void Flush()
    {
        var pending = position - emitted;
        var whole = mode == Mode.Idle ? Round(pending) : Math.Truncate(pending);
        if (whole != 0)
        {
            emitted += whole;
            Output?.Invoke(whole, horizontal);
        }
        if (mode == Mode.Idle && (ballMode == BallMode.Idle || BallResting)) Stop();
    }

    // MARK: Scrolling with the ball

    public const double BallPointsPerCount = 1.0;
    public const double BallSmoothing = 0.016;
    public const double BallGlideWindow = 0.06;

    private enum BallMode { Idle, Rolling, Gliding }
    private BallMode ballMode = BallMode.Idle;
    private (double x, double y) ballTarget, ballPos, ballEmitted, ballVel;
    private readonly List<(double t, double x, double y)> ballRecent = new();

    public bool BallActive => ballMode != BallMode.Idle;

    private bool BallResting =>
        ballMode == BallMode.Rolling && Math.Abs(ballTarget.x - ballPos.x) < 0.01 && Math.Abs(ballTarget.y - ballPos.y) < 0.01;

    public void BeginBall()
    {
        ballMode = BallMode.Rolling;
        ballTarget = (0, 0); ballPos = (0, 0); ballEmitted = (0, 0); ballVel = (0, 0);
        ballRecent.Clear();
    }

    /// <summary>Raw ball counts, already signed so + scrolls up / left.</summary>
    public void AddBallDelta(double dx, double dy)
    {
        if (ballMode != BallMode.Rolling || (dx == 0 && dy == 0)) return;
        var gain = BallPointsPerCount * Math.Max(Config.BallScrollSpeed, 0) * (Config.ReverseScroll ? -1 : 1);
        double x = dx * gain, y = dy * gain;
        var now = Clock();
        ballTarget.x += x;
        ballTarget.y += y;
        ballRecent.Add((now, x, y));
        ballRecent.RemoveAll(r => now - r.t > BallGlideWindow);
        Start();
    }

    public void EndBall(bool glide = true)
    {
        if (ballMode != BallMode.Rolling) return;
        var now = Clock();
        ballRecent.RemoveAll(r => now - r.t > BallGlideWindow);
        if (glide && Config.SmoothScrolling && ballRecent.Count > 0)
        {
            var w = BallGlideWindow;
            double sx = 0, sy = 0;
            foreach (var r in ballRecent) { sx += r.x; sy += r.y; }
            ballVel.x = sx / w;
            ballVel.y = sy / w;
            var v = Math.Sqrt(ballVel.x * ballVel.x + ballVel.y * ballVel.y);
            if (v > ThrowMaxSpeed)
            {
                ballVel.x *= ThrowMaxSpeed / v;
                ballVel.y *= ThrowMaxSpeed / v;
            }
        }
        ballRecent.Clear();
        ballMode = BallMode.Gliding;
        Start();
    }

    public void CancelBall()
    {
        ballMode = BallMode.Idle;
        ballVel = (0, 0);
        ballRecent.Clear();
        if (mode == Mode.Idle) Stop();
    }

    private void BallFrame(double dt)
    {
        if (ballMode == BallMode.Idle) return;
        if (ballMode == BallMode.Gliding && (ballVel.x != 0 || ballVel.y != 0))
        {
            var tau = FlyTau(Config.FlyGlide);
            var fade = Math.Exp(-dt / tau);
            ballTarget.x += ballVel.x * tau * (1 - fade);
            ballTarget.y += ballVel.y * tau * (1 - fade);
            ballVel.x *= fade;
            ballVel.y *= fade;
            if (Math.Sqrt(ballVel.x * ballVel.x + ballVel.y * ballVel.y) < 15)
            {
                ballTarget.x += ballVel.x * tau;
                ballTarget.y += ballVel.y * tau;
                ballVel = (0, 0);
            }
        }
        var a = Config.SmoothScrolling ? 1 - Math.Exp(-dt / BallSmoothing) : 1;
        ballPos.x += (ballTarget.x - ballPos.x) * a;
        ballPos.y += (ballTarget.y - ballPos.y) * a;
        if (BallResting) ballPos = ballTarget;
        if (ballMode == BallMode.Gliding && ballVel.x == 0 && ballVel.y == 0
            && Math.Abs(ballTarget.x - ballPos.x) < 0.5 && Math.Abs(ballTarget.y - ballPos.y) < 0.5)
        {
            ballPos = ballTarget;
            ballMode = BallMode.Idle;
        }
        double px = ballPos.x - ballEmitted.x, py = ballPos.y - ballEmitted.y;
        var wx = ballMode == BallMode.Idle ? Round(px) : Math.Truncate(px);
        var wy = ballMode == BallMode.Idle ? Round(py) : Math.Truncate(py);
        if (wx != 0 || wy != 0)
        {
            ballEmitted.x += wx;
            ballEmitted.y += wy;
            BallOutput?.Invoke(wx, wy);
        }
    }
}
