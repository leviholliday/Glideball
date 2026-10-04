using System;
using System.Diagnostics;
using System.Threading;
using Glideball.Core.Scrolling;
using Glideball.Core.Settings;
using Glideball.Native;

namespace Glideball.Input;

/// <summary>Seconds on a monotonic clock shared by everything in the input path.</summary>
internal static class Clock
{
    private static readonly double Tick = 1.0 / Stopwatch.Frequency;
    public static double Now => Stopwatch.GetTimestamp() * Tick;
}

/// <summary>
/// Runs the SmoothScroller at display rate on its own thread and turns its
/// output into high-resolution wheel input (sub-120 deltas). Frames are paced
/// by DwmFlush (one per composition, i.e. per display refresh), with a
/// sleep-based 120 Hz fallback if the compositor returns immediately. The
/// scroller is only touched under <see cref="Gate"/>.
/// </summary>
internal sealed class ScrollPump : IDisposable
{
    public readonly object Gate = new();
    public readonly SmoothScroller Scroller = new();
    private readonly WheelConverter wheel = new();
    private readonly AutoResetEvent wake = new(false);
    private readonly Thread thread;
    private volatile bool stopping;

    /// <summary>Points scrolled, for the dashboard (approximate; read from any thread).</summary>
    public double PointsScrolled;

    public ScrollPump()
    {
        Scroller.Clock = () => Clock.Now;
        Scroller.Output = (points, horizontal) =>
        {
            PointsScrolled += Math.Abs(points);
            if (horizontal) Injector.Wheel(wheel.Horizontal(points), true);
            else Injector.Wheel(wheel.Vertical(points), false);
        };
        Scroller.BallOutput = (dx, dy) =>
        {
            PointsScrolled += Math.Sqrt(dx * dx + dy * dy);
            Injector.Wheel(wheel.Vertical(dy), false);
            Injector.Wheel(wheel.Horizontal(dx), true);
        };
        Scroller.RunningChanged = running => { if (running) wake.Set(); };
        thread = new Thread(Run) { IsBackground = true, Name = "Glideball scroll", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    public double UnitsPerPoint
    {
        get => wheel.UnitsPerPoint;
        set { lock (Gate) wheel.UnitsPerPoint = value; }
    }

    public void SetConfig(GlideConfig config)
    {
        lock (Gate) Scroller.Config = config;
    }

    /// <summary>Stops all scrolling now (pause, quit).</summary>
    public void Reset()
    {
        lock (Gate)
        {
            Scroller.Reset();
            wheel.Reset();
        }
    }

    private void Run()
    {
        var last = Clock.Now;
        while (!stopping)
        {
            bool running;
            lock (Gate) running = Scroller.IsRunning;
            if (!running)
            {
                wake.WaitOne(500);
                last = Clock.Now;
                continue;
            }
            // Wait for the next composition; fall back to a timer if DWM doesn't block.
            var hr = Win32.DwmFlush();
            var now = Clock.Now;
            if (hr != 0 || now - last < 0.002)
            {
                Thread.Sleep(Math.Max(1, (int)((1.0 / 120 - (now - last)) * 1000)));
                now = Clock.Now;
            }
            last = now;
            try
            {
                lock (Gate) Scroller.Frame(now);
            }
            catch (Exception e)
            {
                DiagLog.Write("scroll frame failed: " + e.Message);
                lock (Gate) Scroller.Reset();
            }
        }
    }

    public void Dispose()
    {
        stopping = true;
        wake.Set();
        thread.Join(500);
    }
}
