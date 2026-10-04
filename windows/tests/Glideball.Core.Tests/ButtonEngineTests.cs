using System.Collections.Generic;
using System.Linq;
using Glideball.Core.Buttons;
using Glideball.Core.Settings;
using Xunit;

namespace Glideball.Core.Tests;

/// <summary>Records everything the engine asks the platform to do.</summary>
internal sealed class FakeHost : IButtonHost
{
    public readonly List<string> Log = new();
    public Modes Modes;
    public IReadOnlyCollection<int>? Learned;

    public void Replay(object original) => Log.Add($"replay {original}");
    public void InjectButton(int button, bool down, ulong mods) => Log.Add($"inject {button} {(down ? "down" : "up")}" + (mods != 0 ? $" mods {mods}" : ""));
    public void Click(ButtonAction action) => Log.Add($"click {action.Kind}");
    public void SendShortcut(KeyShortcut s) => Log.Add($"shortcut {s.KeyName}");
    public void ShortcutDown(KeyShortcut s) => Log.Add($"key down {s.KeyName}");
    public void ShortcutUp(KeyShortcut s) => Log.Add($"key up {s.KeyName}");
    public void DragLockButton(bool down) => Log.Add($"drag lock {(down ? "down" : "up")}");
    public void BallScroll(bool on, bool glide) => Log.Add($"ball {(on ? "on" : "off")}");
    public void ModesChanged(Modes m) => Modes = m;
    void IButtonHost.Learned(IReadOnlyCollection<int> buttons) => Learned = buttons;
}

/// <summary>A fake event stream: presses and releases at given times, with timers run in between.</summary>
internal sealed class EventStream
{
    public readonly FakeHost Host = new();
    public readonly ButtonEngine Engine;
    public double Now;
    public readonly List<string> Verdicts = new();

    public EventStream(GlideConfig config) => Engine = new ButtonEngine(Host, config);

    public void AdvanceTo(double t)
    {
        while (Engine.NextDeadline is double d && d <= t)
        {
            Now = d;
            Engine.Tick(d);
        }
        Now = t;
    }

    public Verdict Event(double t, int button, Phase phase, bool trackball = true)
    {
        AdvanceTo(t);
        var label = $"{(phase == Phase.Down ? "D" : "U")}{button}@{t * 1000:0}";
        var v = Engine.Handle(button, phase, trackball, t, label);
        Verdicts.Add($"{label} {v}");
        return v;
    }
}

public class ButtonEngineTests
{
    private static GlideConfig Config(params (int button, ButtonAction action)[] map)
    {
        var c = GlideConfig.WindowsDefaults();
        foreach (var (b, a) in map) c.Buttons[b] = a;
        return c;
    }

    [Fact]
    public void UnmappedButtonsPassUntouched()
    {
        var s = new EventStream(Config());
        Assert.Equal(Verdict.Pass, s.Event(0, 1, Phase.Down));
        Assert.Equal(Verdict.Pass, s.Event(0.05, 1, Phase.Up));
        Assert.Empty(s.Host.Log);
    }

    [Fact]
    public void PrimaryButtonStaysLeftClick()
    {
        var s = new EventStream(Config((0, ButtonAction.Disabled)));
        Assert.Equal(Verdict.Pass, s.Event(0, 0, Phase.Down));
        Assert.Equal(Verdict.Pass, s.Event(0.05, 0, Phase.Up));
    }

    [Fact]
    public void RemapOwnsItsRelease()
    {
        var s = new EventStream(Config((2, ButtonAction.Back)));
        Assert.Equal(Verdict.Swallow, s.Event(0, 2, Phase.Down));
        // The mapping changes while the button is down: the release still follows the press.
        s.Engine.Update(Config());
        Assert.Equal(Verdict.Swallow, s.Event(0.1, 2, Phase.Up));
        Assert.Equal(new[] { "inject 3 down", "inject 3 up" }, s.Host.Log);
    }

    [Fact]
    public void OtherDevicesAreNeverRemapped()
    {
        // The touchpad bug: a press the trackball didn't report passes through.
        var s = new EventStream(Config((1, ButtonAction.Press(KeyShortcut.Copy))));
        Assert.Equal(Verdict.Pass, s.Event(0, 1, Phase.Down, trackball: false));
        Assert.Equal(Verdict.Pass, s.Event(0.05, 1, Phase.Up, trackball: false));
        Assert.Empty(s.Host.Log);
    }

    [Fact]
    public void ShortcutFiresOnPressAndSwallowsRelease()
    {
        var s = new EventStream(Config((3, ButtonAction.Press(KeyShortcut.Copy))));
        Assert.Equal(Verdict.Swallow, s.Event(0, 3, Phase.Down));
        Assert.Equal(Verdict.Swallow, s.Event(0.08, 3, Phase.Up));
        Assert.Equal(new[] { "shortcut C" }, s.Host.Log);
    }

    [Fact]
    public void HoldShortcutHoldsUntilRelease()
    {
        var s = new EventStream(Config((3, ButtonAction.Hold(KeyShortcut.WisprFlow))));
        s.Event(0, 3, Phase.Down);
        Assert.Equal(new[] { "key down Space" }, s.Host.Log);
        s.Event(2, 3, Phase.Up);
        Assert.Equal(new[] { "key down Space", "key up Space" }, s.Host.Log);
    }

    [Fact]
    public void ModifiedClickHoldsModifiersAroundTheClick()
    {
        var s = new EventStream(Config((1, ButtonAction.Click(0, MacFlags.Command))));
        s.Event(0, 1, Phase.Down);
        s.Event(0.1, 1, Phase.Up);
        Assert.Equal(new[] { $"inject 0 down mods {MacFlags.Command}", $"inject 0 up mods {MacFlags.Command}" }, s.Host.Log);
    }

    // MARK: Combos

    private static GlideConfig ComboConfig()
    {
        var c = Config((2, ButtonAction.Back), (3, ButtonAction.Forward));
        c.Chords.Add(new Chord(new[] { 2, 3 }, ButtonAction.Press(KeyShortcut.NewTab)));
        c.Chords.Add(new Chord(new[] { 0, 2, 3 }, ButtonAction.Hold(KeyShortcut.WisprFlow)));
        return c;
    }

    [Fact]
    public void LoneComboButtonActsAloneAfter70ms()
    {
        var s = new EventStream(ComboConfig());
        Assert.Equal(Verdict.Swallow, s.Event(0, 2, Phase.Down));
        s.AdvanceTo(0.069);
        Assert.Empty(s.Host.Log);
        s.AdvanceTo(0.071);
        Assert.Equal(new[] { "inject 3 down" }, s.Host.Log);
        s.Event(0.2, 2, Phase.Up);
        Assert.Equal(new[] { "inject 3 down", "inject 3 up" }, s.Host.Log);
    }

    [Fact]
    public void QuickReleaseBeforeWindowReplaysPressThenRelease()
    {
        var c = GlideConfig.WindowsDefaults();
        c.Chords.Add(new Chord(new[] { 1, 2 }, ButtonAction.Press(KeyShortcut.Copy)));
        var s = new EventStream(c);
        Assert.Equal(Verdict.Swallow, s.Event(0, 1, Phase.Down));
        // Released 30 ms later: not a combo. The press is replayed first, then the release, in order.
        Assert.Equal(Verdict.Swallow, s.Event(0.03, 1, Phase.Up));
        Assert.Equal(new[] { "replay D1@0", "replay U1@30" }, s.Host.Log);
    }

    [Fact]
    public void TwoButtonComboWithin70msFires()
    {
        var c = GlideConfig.WindowsDefaults();
        c.Chords.Add(new Chord(new[] { 1, 2 }, ButtonAction.Press(KeyShortcut.Copy)));
        var s = new EventStream(c);
        s.Event(0, 1, Phase.Down);
        s.Event(0.05, 2, Phase.Down);
        Assert.Equal(new[] { "shortcut C" }, s.Host.Log);
        // Both releases belong to the combo.
        Assert.Equal(Verdict.Swallow, s.Event(0.2, 1, Phase.Up));
        Assert.Equal(Verdict.Swallow, s.Event(0.21, 2, Phase.Up));
        Assert.Equal(new[] { "shortcut C" }, s.Host.Log);
    }

    [Fact]
    public void PartnerAfterWindowIsTwoSeparatePresses()
    {
        var c = GlideConfig.WindowsDefaults();
        c.Chords.Add(new Chord(new[] { 1, 2 }, ButtonAction.Press(KeyShortcut.Copy)));
        var s = new EventStream(c);
        s.Event(0, 1, Phase.Down);
        s.Event(0.09, 2, Phase.Down);   // 90 ms: too late
        Assert.Equal(new[] { "replay D1@0" }, s.Host.Log);
        s.AdvanceTo(0.2);
        Assert.Equal(new[] { "replay D1@0", "replay D2@90" }, s.Host.Log);
    }

    [Fact]
    public void ThreeButtonComboGetsExtendedWindow()
    {
        var s = new EventStream(ComboConfig());
        s.Event(0, 2, Phase.Down);
        s.Event(0.06, 3, Phase.Down);    // {2,3} is a combo, but {0,2,3} is still possible: wait
        Assert.Empty(s.Host.Log);
        s.Event(0.12, 0, Phase.Down);    // third finger at 120 ms (< 160 ms max wait)
        Assert.Equal(new[] { "key down Space" }, s.Host.Log);
        s.Event(0.5, 3, Phase.Up);
        Assert.Equal(new[] { "key down Space", "key up Space" }, s.Host.Log);
        // The other buttons finish silently; the key is released only once.
        Assert.Equal(Verdict.Swallow, s.Event(0.51, 2, Phase.Up));
        Assert.Equal(Verdict.Swallow, s.Event(0.52, 0, Phase.Up));
        Assert.Equal(2, s.Host.Log.Count);
    }

    [Fact]
    public void TwoOfThreeFiresTheTwoButtonComboWhenTheThirdNeverComes()
    {
        var s = new EventStream(ComboConfig());
        s.Event(0, 2, Phase.Down);
        s.Event(0.06, 3, Phase.Down);
        // Extended wait ends at min(70 ms after the partner, 160 ms after the first press) = 130 ms.
        s.AdvanceTo(0.129);
        Assert.Empty(s.Host.Log);
        s.AdvanceTo(0.131);
        Assert.Equal(new[] { "shortcut T" }, s.Host.Log);
    }

    [Fact]
    public void PartnerAfterFirstWindowIsTooLate()
    {
        var s = new EventStream(ComboConfig());
        s.Event(0, 2, Phase.Down);
        s.Event(0.12, 3, Phase.Down);
        // 120 ms > 70 ms: the first press already went alone at 70 ms.
        Assert.Equal("inject 3 down", s.Host.Log[0]);
    }

    [Fact]
    public void ExtendedWaitIsCappedAt160msFromFirstPress()
    {
        var s = new EventStream(ComboConfig());
        s.Event(0, 2, Phase.Down);
        s.Event(0.065, 3, Phase.Down);
        // min(70 ms, 160 − 65 = 95 ms) → 135 ms.
        s.AdvanceTo(0.134);
        Assert.Empty(s.Host.Log);
        s.AdvanceTo(0.136);
        Assert.Single(s.Host.Log);
    }

    [Fact]
    public void NonComboPressFlushesWaitingPressFirst()
    {
        var c = ComboConfig();
        c.Buttons[1] = ButtonAction.MiddleClick;
        var s = new EventStream(c);
        s.Event(0, 2, Phase.Down);
        Assert.Equal(Verdict.Swallow, s.Event(0.01, 1, Phase.Down));
        Assert.Equal(new[] { "inject 3 down", "inject 2 down" }, s.Host.Log);
    }

    [Fact]
    public void LeftClickInComboIsDelayedButNeverLost()
    {
        var s = new EventStream(ComboConfig());
        Assert.Equal(Verdict.Swallow, s.Event(0, 0, Phase.Down));
        s.AdvanceTo(0.1);
        Assert.Equal(new[] { "replay D0@0" }, s.Host.Log);
        Assert.Equal(Verdict.Pass, s.Event(0.15, 0, Phase.Up));
    }

    // MARK: Modes

    [Fact]
    public void PrecisionHoldOnlyWhileHeld()
    {
        var s = new EventStream(Config((3, ButtonAction.PrecisionHold)));
        s.Engine.TrackballButton(3, true);
        s.Event(0, 3, Phase.Down);
        Assert.True(s.Host.Modes.Precision);
        s.Engine.TrackballButton(3, false);
        s.Event(0.5, 3, Phase.Up);
        Assert.False(s.Host.Modes.Precision);
    }

    [Fact]
    public void HoldFailsafeEndsAHoldWhoseReleaseWasLost()
    {
        var s = new EventStream(Config((3, ButtonAction.BallScrollHold)));
        s.Engine.TrackballButton(3, true);
        s.Event(0, 3, Phase.Down);
        Assert.True(s.Host.Modes.BallScrolling);
        s.Engine.TrackballButton(3, false);   // Raw Input saw the release; the hook never did
        s.AdvanceTo(0.3);
        Assert.True(s.Host.Modes.BallScrolling);
        s.AdvanceTo(0.6);
        Assert.False(s.Host.Modes.BallScrolling);
        Assert.Contains("ball off", s.Host.Log);
    }

    [Fact]
    public void PrecisionToggleFlips()
    {
        var s = new EventStream(Config((2, ButtonAction.PrecisionToggle)));
        s.Event(0, 2, Phase.Down); s.Event(0.1, 2, Phase.Up);
        Assert.True(s.Engine.PrecisionActive);
        s.Event(1, 2, Phase.Down); s.Event(1.1, 2, Phase.Up);
        Assert.False(s.Engine.PrecisionActive);
    }

    [Fact]
    public void DragLockGrabsAndAnyLeftClickDrops()
    {
        var s = new EventStream(Config((3, ButtonAction.DragLock)));
        s.Event(0, 3, Phase.Down);
        s.Event(0.1, 3, Phase.Up);
        Assert.True(s.Engine.DragLocked);
        // A left click from another mouse lets go — and that's all it does.
        Assert.Equal(Verdict.Swallow, s.Event(1, 0, Phase.Down, trackball: false));
        Assert.Equal(Verdict.Swallow, s.Event(1.1, 0, Phase.Up, trackball: false));
        Assert.False(s.Engine.DragLocked);
        Assert.Equal(new[] { "drag lock down", "drag lock up" }, s.Host.Log);
    }

    [Fact]
    public void ReleaseAllLetsGoOfEverything()
    {
        var c = Config((3, ButtonAction.Hold(KeyShortcut.WisprFlow)), (2, ButtonAction.DragLock), (1, ButtonAction.MiddleClick));
        var s = new EventStream(c);
        s.Event(0, 3, Phase.Down);
        s.Event(0, 2, Phase.Down);
        s.Event(0, 1, Phase.Down);
        s.Engine.ReleaseAll();
        Assert.Contains("key up Space", s.Host.Log);
        Assert.Contains("drag lock up", s.Host.Log);
        Assert.Contains("inject 2 up", s.Host.Log);
        Assert.False(s.Engine.DragLocked);
        // Late releases are still swallowed (never a stray up).
        Assert.Equal(Verdict.Swallow, s.Event(1, 3, Phase.Up));
        Assert.Equal(Verdict.Swallow, s.Event(1, 1, Phase.Up));
    }

    [Fact]
    public void PauseDisablesRemapping()
    {
        var c = Config((2, ButtonAction.Back));
        var s = new EventStream(c);
        var paused = c.Clone();
        paused.Enabled = false;
        s.Engine.Update(paused);
        Assert.Equal(Verdict.Pass, s.Event(0, 2, Phase.Down));
        Assert.Equal(Verdict.Pass, s.Event(0.1, 2, Phase.Up));
    }

    [Fact]
    public void LearnCapturesHeldButtons()
    {
        var s = new EventStream(Config());
        s.Engine.LearnNextPress(true);
        s.Event(0, 2, Phase.Down);
        s.Event(0.02, 3, Phase.Down);
        s.Event(0.2, 2, Phase.Up);
        Assert.Null(s.Host.Learned);
        s.Event(0.25, 3, Phase.Up);
        Assert.Equal(new[] { 2, 3 }, s.Host.Learned!.ToArray());
        Assert.False(s.Engine.Learning);
    }

    [Fact]
    public void CaresAboutOnlyMappedOrComboButtons()
    {
        var c = ComboConfig();
        var e = new ButtonEngine(new FakeHost(), c);
        Assert.True(e.CaresAbout(0));    // in a combo
        Assert.False(e.CaresAbout(1));   // default
        Assert.True(e.CaresAbout(2));
        var plain = GlideConfig.WindowsDefaults();
        Assert.False(new ButtonEngine(new FakeHost(), plain).CaresAbout(0));
    }
}
