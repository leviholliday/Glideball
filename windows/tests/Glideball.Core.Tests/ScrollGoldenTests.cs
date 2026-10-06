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
        /// <summary>Missing in the legacy goldens (recorded before Fast-spin reach existed).</summary>
        public double flyReach { get; set; } = 0.5;
        public double[] ticks { get; set; } = Array.Empty<double>();
        public double[]? directions { get; set; }
        public double until { get; set; }
        public double[] frames { get; set; } = Array.Empty<double>();
        public override string ToString() => name;
    }

    private static List<Scenario> Load(string file = "scroll-golden.json")
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Data", file);
        return JsonSerializer.Deserialize<List<Scenario>>(File.ReadAllText(path))!;
    }

    public static IEnumerable<object[]> Names() => Load().Select(s => new object[] { s.name });

    /// <summary>
    /// The scenarios as the Mac recorded them before Fast-spin reach, when Flywheel had a hard
    /// speed limit. Frozen: <c>run.sh</c> never rewrites this file.
    /// </summary>
    public static IEnumerable<object[]> LegacyNames() => Load("scroll-golden-legacy.json").Select(s => new object[] { s.name });

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
            FlyReach = sc.flyReach,
        };
        return c;
    }

    [Theory]
    [MemberData(nameof(Names))]
    public void MatchesSwift(string name)
    {
        var sc = Load().Single(s => s.name == name);
        AssertMatchesRecording(sc, ConfigFor(sc));
    }

    /// <summary>
    /// Reach 0 is the old hard speed limit, exactly: every scenario recorded before the
    /// feature existed still comes out the same frame for frame.
    /// </summary>
    [Theory]
    [MemberData(nameof(LegacyNames))]
    public void ReachZeroIsTheOldHardLimit(string name)
    {
        var sc = Load("scroll-golden-legacy.json").Single(s => s.name == name);
        var config = ConfigFor(sc);
        config.FlyReach = 0;
        AssertMatchesRecording(sc, config);
    }

    private void AssertMatchesRecording(Scenario sc, GlideConfig config)
    {
        var frames = Simulate(config, sc.ticks, sc.until, sc.directions);

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
        Assert.Equal(33, names.Count);
        Assert.Contains("flywheel: One tick", names);
        Assert.Contains("follow: Flick then catch", names);
        Assert.Contains("flywheel reach 0: 20 ticks @ 100 t/s", names);
        Assert.Contains("flywheel reach 0.5: 30 ticks @ 130 t/s", names);
        Assert.Equal(23, Load("scroll-golden-legacy.json").Count);
    }

    /// <summary>Ticks at a steady rate, snapped to the trackball's 8 ms USB polling (scroll-sim's <c>spin</c>).</summary>
    private static double[] Spin(double rate, int count, double start = 0.05)
    {
        var ticks = new double[count];
        var t = start;
        for (var i = 0; i < count; i++)
        {
            ticks[i] = Math.Round(t / 0.008, MidpointRounding.AwayFromZero) * 0.008;
            t += 1 / rate;
        }
        return ticks;
    }

    private static double Travel(double reach, double rate, int count)
    {
        var config = new GlideConfig { FlyReach = reach };
        return Simulate(config, Spin(rate, count), 3.0, null).Sum();
    }

    /// <summary>The reason for the feature: a harder spin used to go no farther.</summary>
    [Fact]
    public void AtReachHalfAHarderSpinGoesFarther()
    {
        var gentle = Travel(0.5, 45, 20);
        var hard = Travel(0.5, 100, 20);
        Assert.True(hard > gentle * 1.5, $"100 t/s went {hard} pt, 45 t/s went {gentle} pt");
        Assert.True(Travel(0.5, 130, 30) > hard);
    }

    [Fact]
    public void AtReachZeroAHarderSpinGoesNoFarther()
    {
        // The old behaviour that made hard spins feel dead.
        Assert.True(Travel(0, 100, 20) <= Travel(0, 45, 20));
    }

    [Fact]
    public void ReachNeverChangesASpinThatStaysUnderTheKnee()
    {
        // A medium turn never gets near 12,000 pt/s, so the setting can't matter.
        Assert.Equal(Travel(0, 16, 12), Travel(1, 16, 12));
        Assert.Equal(Travel(0, 16, 12), Travel(0.5, 16, 12));
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(0.25)]
    [InlineData(0.5)]
    [InlineData(1.0)]
    public void FlySpeedIsContinuousAtTheKnee(double reach)
    {
        var knee = SmoothScroller.FlyKnee;
        Assert.Equal(knee, SmoothScroller.FlySpeed(knee, reach));
        Assert.Equal(-knee, SmoothScroller.FlySpeed(-knee, reach));
        // Just either side of the knee the speed is (almost) the same.
        Assert.Equal(knee - 1e-6, SmoothScroller.FlySpeed(knee - 1e-6, reach), 9);
        Assert.InRange(SmoothScroller.FlySpeed(knee + 1e-6, reach), knee, knee + 2e-6);
        Assert.InRange(SmoothScroller.FlySpeed(-knee - 1e-6, reach), -knee - 2e-6, -knee);
        // Below the knee it is the identity.
        Assert.Equal(7_345.5, SmoothScroller.FlySpeed(7_345.5, reach));
        Assert.Equal(-100.0, SmoothScroller.FlySpeed(-100.0, reach));
    }

    [Fact]
    public void FlySpeedGrowsPastTheKneeTowardTheCeilingSetByReach()
    {
        var knee = SmoothScroller.FlyKnee;
        // Reach 0 is a hard limit; reach 1 leaves 60,000 pt/s of headroom.
        Assert.Equal(knee, SmoothScroller.FlySpeed(1e9, 0));
        Assert.Equal(-knee, SmoothScroller.FlySpeed(-1e9, 0));
        Assert.Equal(knee + SmoothScroller.FlyHeadroom * 0.5, SmoothScroller.FlySpeed(1e9, 0.5), 6);
        Assert.Equal(knee + SmoothScroller.FlyHeadroom, SmoothScroller.FlySpeed(1e9, 1), 6);
        // Out-of-range reach is clamped, not extrapolated.
        Assert.Equal(SmoothScroller.FlySpeed(40_000, 1), SmoothScroller.FlySpeed(40_000, 7));
        Assert.Equal(knee, SmoothScroller.FlySpeed(40_000, -3));
        // Strictly increasing, odd-symmetric.
        var previous = knee;
        for (var raw = knee + 1000; raw < 200_000; raw += 1000)
        {
            var v = SmoothScroller.FlySpeed(raw, 0.5);
            Assert.True(v > previous);
            Assert.Equal(-v, SmoothScroller.FlySpeed(-raw, 0.5));
            previous = v;
        }
    }

    [Fact]
    public void CoastStretchStartsAtTheKneeAndTopsOutAtOnePointEight()
    {
        var knee = SmoothScroller.FlyKnee;
        Assert.Equal(1.0, SmoothScroller.FlyCoastStretch(0, 1));
        Assert.Equal(1.0, SmoothScroller.FlyCoastStretch(knee, 1));
        Assert.Equal(1.0, SmoothScroller.FlyCoastStretch(80_000, 0));
        Assert.Equal(1.8, SmoothScroller.FlyCoastStretch(knee + SmoothScroller.FlyHeadroom, 1), 12);
        Assert.Equal(1.8, SmoothScroller.FlyCoastStretch(-500_000, 1), 12);
        Assert.Equal(1.4, SmoothScroller.FlyCoastStretch(knee + SmoothScroller.FlyHeadroom * 0.5, 0.5), 12);
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
