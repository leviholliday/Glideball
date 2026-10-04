using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Glideball.Core.Scrolling;
using Glideball.Core.Settings;
using Xunit;
using Xunit.Abstractions;

namespace Glideball.Core.Tests;

/// <summary>
/// Drives the C# SmoothScroller with the scroll-sim scenarios
/// (scripts/scroll-sim/main.swift) and compares every frame with the output of
/// the real Swift SmoothScroller, recorded by windows/tools/golden/run.sh.
/// </summary>
public class ScrollGoldenTests
{
    private readonly ITestOutputHelper log;

    public ScrollGoldenTests(ITestOutputHelper log) => this.log = log;

    public sealed class Scenario
    {
        public string name { get; set; } = "";
        public string mode { get; set; } = "";
        public double scrollDistance { get; set; }
        public double scrollSmoothness { get; set; }
        public double scrollAcceleration { get; set; }
        public double throwAmount { get; set; }
        public double[] ticks { get; set; } = Array.Empty<double>();
        public double[]? directions { get; set; }
        public double until { get; set; }
        public double[] frames { get; set; } = Array.Empty<double>();
        public override string ToString() => name;
    }

    private static List<Scenario> Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Data", "scroll-golden.json");
        return JsonSerializer.Deserialize<List<Scenario>>(File.ReadAllText(path))!;
    }

    public static IEnumerable<object[]> Names() => Load().Select(s => new object[] { s.name });

    /// <summary>The scroll-sim harness, step for step.</summary>
    public static List<double> Simulate(GlideConfig config, double[] ticks, double until, double[]? directions)
    {
        var s = new SmoothScroller { Config = config };
        var now = 0.0;
        s.Clock = () => now;
        var acc = 0.0;
        s.Output = (d, _) => acc += d;
        var frames = new List<double>();
        var next = 0;
        var t = 0.0;
        while (t <= until)
        {
            while (next < ticks.Length && ticks[next] <= t)
            {
                now = ticks[next];
                s.AddTicks(directions?[next] ?? 1);
                next++;
            }
            now = t;
            acc = 0;
            s.Frame(t);
            frames.Add(acc);
            t += 1.0 / 120;
        }
        return frames;
    }

    private static GlideConfig ConfigFor(Scenario sc)
    {
        var c = new GlideConfig
        {
            ScrollMode = sc.mode == "follow" ? ScrollMode.Follow : ScrollMode.Flywheel,
            ScrollDistance = sc.scrollDistance,
            ScrollSmoothness = sc.scrollSmoothness,
            ScrollAcceleration = sc.scrollAcceleration,
            ThrowAmount = sc.throwAmount,
        };
        return c;
    }

    [Theory]
    [MemberData(nameof(Names))]
    public void MatchesSwift(string name)
    {
        var sc = Load().Single(s => s.name == name);
        var frames = Simulate(ConfigFor(sc), sc.ticks, sc.until, sc.directions);

        Assert.Equal(sc.frames.Length, frames.Count);
        var diffs = Enumerable.Range(0, frames.Count).Where(i => frames[i] != sc.frames[i]).ToList();
        foreach (var i in diffs) log.WriteLine($"frame {i}: C# {frames[i]} vs Swift {sc.frames[i]}");

        // The math is identical; only libm's last-bit rounding of exp/pow may
        // differ between macOS and Windows, which can move a single point by one frame.
        Assert.True(diffs.Count <= 2, $"{diffs.Count} frames differ from Swift");
        Assert.All(diffs, i => Assert.True(Math.Abs(frames[i] - sc.frames[i]) <= 1));
        Assert.InRange(frames.Sum() - sc.frames.Sum(), -1.0, 1.0);
    }

    [Fact]
    public void GoldenCoversEveryScenario()
    {
        var names = Load().Select(s => s.name).ToList();
        Assert.Equal(23, names.Count);
        Assert.Contains("flywheel: One tick", names);
        Assert.Contains("follow: Flick then catch", names);
    }

    /// <summary>Flywheel's constants are Kensington's measured behaviour: a slow tick ≈ 4 pt.</summary>
    [Fact]
    public void FlywheelSingleTickTravelsFourPoints()
    {
        var frames = Simulate(new GlideConfig(), new[] { 0.05 }, 0.6, null);
        // Frames after the tick (the tick-time frame is outside the sampled frames, as in scroll-sim).
        var s = new SmoothScroller { Config = new GlideConfig() };
        var now = 0.05;
        s.Clock = () => now;
        var total = 0.0;
        s.Output = (d, _) => total += d;
        s.AddTicks(1);
        for (var t = 0.05 + 1.0 / 120; t < 1; t += 1.0 / 120) { now = t; s.Frame(t); }
        Assert.Equal(4, total);
        Assert.False(s.IsRunning);
        Assert.True(frames.Sum() <= 4);
    }

    [Fact]
    public void FlywheelTauIsKensingtons82ms()
    {
        Assert.Equal(0.082, SmoothScroller.FlyTau(0.35), 3);
    }

    [Fact]
    public void ReverseFlipsDirection()
    {
        var c = new GlideConfig { ReverseScroll = true };
        var s = new SmoothScroller { Config = c };
        var now = 0.0;
        s.Clock = () => now;
        var total = 0.0;
        s.Output = (d, _) => total += d;
        s.AddTicks(1);
        for (var t = 1.0 / 120; t < 1; t += 1.0 / 120) { now = t; s.Frame(t); }
        Assert.Equal(-4, total);
    }

    [Fact]
    public void ShiftScrollsHorizontally()
    {
        var s = new SmoothScroller { Config = new GlideConfig() };
        var now = 0.0;
        s.Clock = () => now;
        var horizontal = new List<bool>();
        s.Output = (_, h) => horizontal.Add(h);
        s.AddTicks(1, shift: true);
        for (var t = 1.0 / 120; t < 1; t += 1.0 / 120) { now = t; s.Frame(t); }
        Assert.NotEmpty(horizontal);
        Assert.All(horizontal, h => Assert.True(h));
    }

    [Fact]
    public void WheelConverterKeepsFractions()
    {
        var w = new WheelConverter { UnitsPerPoint = 1.5 };
        var sum = 0;
        for (var i = 0; i < 80; i++) sum += w.Vertical(1);
        Assert.Equal(120, sum);
        Assert.Equal(-15, w.Horizontal(10));
    }
}
