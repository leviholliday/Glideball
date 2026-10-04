using System;
using System.Collections.Generic;
using System.Linq;
using Glideball.Core.Settings;

namespace Glideball.Core.Buttons;

public enum Phase { Down, Up }

public enum Verdict
{
    /// <summary>Let the original event through untouched.</summary>
    Pass,
    /// <summary>Drop the original event (the engine may have injected something instead).</summary>
    Swallow,
}

/// <summary>Glideball's own button modes that are currently on, for the UI.</summary>
public readonly record struct Modes(bool Precision, bool BallScrolling, bool DragLocked);

/// <summary>What the engine asks the platform to do. Called synchronously from <see cref="ButtonEngine"/>.</summary>
public interface IButtonHost
{
    /// <summary>Re-inject an event the engine held back, untouched (it was a plain press after all).</summary>
    void Replay(object original);
    /// <summary>Press or release <paramref name="button"/> (Mac numbering) with click modifiers (Mac flags) held around it.</summary>
    void InjectButton(int button, bool down, ulong macModifiers);
    /// <summary>A quick press and release of a click action (combos).</summary>
    void Click(ButtonAction action);
    void SendShortcut(KeyShortcut shortcut);
    void ShortcutDown(KeyShortcut shortcut);
    void ShortcutUp(KeyShortcut shortcut);
    /// <summary>The left button goes down (true) or up (false) for Drag lock.</summary>
    void DragLockButton(bool down);
    /// <summary>The ball starts scrolling (cursor frozen) or stops (with an optional glide).</summary>
    void BallScroll(bool on, bool glide);
    void ModesChanged(Modes modes);
    void Learned(IReadOnlyCollection<int> buttons);
}

/// <summary>
/// Buttons, combos and modes: a port of the button half of the Mac's
/// <c>Engine.swift</c> with the platform cut away, so it runs on fake event
/// streams in tests. Single-threaded: the host calls it from its input thread.
///
/// Rules carried over from the Mac:
///  • only presses the trackball itself reported are remapped (<c>fromTrackball</c>);
///  • a press we took over owns its release: releases follow the override, so a
///    button can never get stuck down;
///  • a button in a combo waits <see cref="ComboWindow"/> (70 ms) for its partners,
///    extended to at most <see cref="ComboMaxWait"/> (160 ms) while a bigger combo is still possible;
///  • the primary button (0) always stays a left click.
/// </summary>
public sealed class ButtonEngine
{
    public const double ComboWindow = 0.07;
    public const double ComboMaxWait = 0.16;
    public const double HoldCheckInterval = 0.25;

    private readonly IButtonHost host;
    private GlideConfig config;

    private abstract record Override
    {
        public sealed record Swallow : Override;
        public sealed record Remap(int Target, ulong Modifiers) : Override;
        public sealed record HeldShortcut(KeyShortcut Shortcut) : Override;
        public sealed record Precision : Override;
        public sealed record BallScroll : Override;
        public sealed record DragButton : Override;
    }

    private readonly Dictionary<int, Override> overrides = new();
    private readonly List<(int button, object original)> pending = new();
    private double pendingStart;
    private double? pendingDeadline;

    private bool learning;
    private double clock;
    private readonly HashSet<int> learnHeld = new();
    private readonly HashSet<int> learnMax = new();

    private bool precisionHeld, precisionToggled, precisionManual;
    private bool ballScrolling, ballScrollHeld, ballScrollLatched;
    private bool dragLocked, dragLockManual;
    private Modes modes;

    // Hold failsafe (Mac: checkHolds): ends a held mode if its release is lost.
    private readonly HashSet<int> trackballDown = new();
    private bool trackballButtonSeen;
    private double holdStart;
    private int holdReleasedChecks;
    private double? nextHoldCheck;

    public ButtonEngine(IButtonHost host, GlideConfig config)
    {
        this.host = host;
        this.config = config;
    }

    public GlideConfig Config => config;
    public Modes CurrentModes => modes;
    public bool PrecisionActive => config.Enabled && (precisionHeld || precisionToggled);
    public bool BallScrolling => ballScrolling;
    public bool DragLocked => dragLocked;
    public bool Learning => learning;
    public bool HasPending => pending.Count > 0;

    /// <summary>The earliest time <see cref="Tick"/> must be called, if any.</summary>
    public double? NextDeadline
    {
        get
        {
            if (pendingDeadline is double p && nextHoldCheck is double h) return Math.Min(p, h);
            return pendingDeadline ?? nextHoldCheck;
        }
    }

    /// <summary>
    /// Would a press of <paramref name="button"/> be handled differently if it
    /// came from the trackball? The host only asks Raw Input about those.
    /// </summary>
    public bool CaresAbout(int button)
    {
        if (!config.Enabled) return false;
        if (learning) return true;
        if (config.Chords.Any(c => c.Buttons.Contains(button))) return true;
        if (button == 0) return false;
        return config.ActionFor(button).Kind != ActionKind.System;
    }

    public void Update(GlideConfig newConfig)
    {
        var wasEnabled = config.Enabled;
        config = newConfig;
        if (wasEnabled && !config.Enabled) ReleaseModes();
        else DropOrphanedModes();
    }

    /// <summary>The next trackball press (or presses held together) is captured instead of
    /// acting, and reported through <see cref="IButtonHost.Learned"/>.</summary>
    public void LearnNextPress(bool on)
    {
        learning = on;
        learnHeld.Clear();
        learnMax.Clear();
    }

    /// <summary>Physical trackball button state from Raw Input (for the hold failsafe).</summary>
    public void TrackballButton(int button, bool down)
    {
        if (down)
        {
            trackballDown.Add(button);
            trackballButtonSeen = true;
        }
        else
        {
            trackballDown.Remove(button);
        }
    }

    // MARK: Events

    /// <summary>
    /// A mouse button event from any device. <paramref name="original"/> is the
    /// host's handle for replaying it.
    /// </summary>
    public Verdict Handle(int button, Phase phase, bool fromTrackball, double now, object original)
    {
        clock = now;
        // Drag lock: any left click (from any mouse) lets go — and that's all it does.
        if (dragLocked && phase == Phase.Down && IsLeftPress(button, fromTrackball) && !InDragLockCombo(button, fromTrackball))
        {
            EndDragLock();
            overrides[button] = new Override.Swallow();
            return Verdict.Swallow;
        }

        if (learning && ((phase == Phase.Down && fromTrackball) || learnHeld.Contains(button)))
        {
            if (phase == Phase.Down)
            {
                learnHeld.Add(button);
                learnMax.UnionWith(learnHeld);
            }
            else
            {
                learnHeld.Remove(button);
                if (learnHeld.Count == 0)
                {
                    var result = learnMax.OrderBy(b => b).ToList();
                    learning = false;
                    host.Learned(result);
                }
            }
            return Verdict.Swallow;
        }

        // A combo member still waiting: anything else it does means "not a combo".
        // Replay the held press first, then this event after it.
        if (phase != Phase.Down && pending.Any(p => p.button == button))
        {
            FlushPending();
            if (Handle(button, phase, fromTrackball, now, original) == Verdict.Pass) host.Replay(original);
            return Verdict.Swallow;
        }

        // A press we took over: its release follows it, always.
        if (phase == Phase.Up && overrides.TryGetValue(button, out var o))
        {
            overrides.Remove(button);
            switch (o)
            {
                case Override.Swallow _:
                    return Verdict.Swallow;
                case Override.Remap r:
                    host.InjectButton(r.Target, false, r.Modifiers);
                    return Verdict.Swallow;
                case Override.HeldShortcut h:
                    // First button of the hold to lift releases the key — once.
                    host.ShortcutUp(h.Shortcut);
                    foreach (var b in overrides.Keys.ToList())
                        if (overrides[b] is Override.HeldShortcut) overrides[b] = new Override.Swallow();
                    return Verdict.Swallow;
                case Override.Precision _:
                    EndPrecisionHold();
                    return Verdict.Swallow;
                case Override.BallScroll _:
                    EndBallScroll(latched: false, glide: true);
                    return Verdict.Swallow;
                case Override.DragButton _:
                    return Verdict.Swallow;
            }
        }

        if (phase != Phase.Down || !config.Enabled || !fromTrackball) return Verdict.Pass;

        if (!config.ComboButtons().Contains(button))
        {
            if (pending.Count == 0) return Press(button, original);
            FlushPending();
            if (Press(button, original) == Verdict.Pass) host.Replay(original);
            return Verdict.Swallow;
        }

        // Hold this press briefly to see if it becomes a combo.
        pending.Add((button, original));
        var held = pending.Select(p => p.button).ToHashSet();
        var exact = config.Chords.FirstOrDefault(c => c.Matches(held));
        var biggerPossible = config.Chords.Any(c => c.Buttons.ToHashSet().IsProperSupersetOf(held));
        if (exact != null && !biggerPossible)
        {
            FireCombo(exact);
        }
        else if (pending.Count == 1)
        {
            pendingStart = now;
            pendingDeadline = now + ComboWindow;
        }
        else if (biggerPossible)
        {
            // A partner arrived and a bigger combo is still possible: give the next
            // finger a moment too, but never hold the first press longer than ComboMaxWait.
            var left = ComboMaxWait - (now - pendingStart);
            pendingDeadline = now + Math.Max(0.01, Math.Min(ComboWindow, left));
        }
        return Verdict.Swallow;
    }

    /// <summary>Runs timers: the combo window and the hold failsafe.</summary>
    public void Tick(double now)
    {
        clock = now;
        if (pendingDeadline is double d && now >= d)
        {
            pendingDeadline = null;
            var held = pending.Select(p => p.button).ToHashSet();
            var chord = held.Count > 1 ? config.Chords.FirstOrDefault(c => c.Matches(held)) : null;
            if (chord != null) FireCombo(chord); else FlushPending();
        }
        if (nextHoldCheck is double h && now >= h) CheckHolds(now);
    }

    private void FireCombo(Chord chord)
    {
        pendingDeadline = null;
        var pressed = pending.Select(p => p.button).ToList();
        pending.Clear();
        var action = chord.Action;
        if (BeginMode(action, pressed)) return;
        if (action.Kind == ActionKind.HoldShortcut && action.Shortcut != null)
        {
            foreach (var b in pressed) overrides[b] = new Override.HeldShortcut(action.Shortcut);
            host.ShortcutDown(action.Shortcut);
        }
        else
        {
            foreach (var b in pressed) overrides[b] = new Override.Swallow();   // their releases are ours too
            Perform(action);
        }
    }

    /// <summary>Not a combo after all: replay the held presses as normal presses.</summary>
    private void FlushPending()
    {
        pendingDeadline = null;
        var presses = pending.ToList();
        pending.Clear();
        foreach (var p in presses)
            if (Press(p.button, p.original) == Verdict.Pass) host.Replay(p.original);
    }

    /// <summary>Applies a single button's mapping to its press.</summary>
    private Verdict Press(int button, object original)
    {
        if (dragLocked && IsLeftPress(button, true))
        {
            EndDragLock();
            overrides[button] = new Override.Swallow();
            return Verdict.Swallow;
        }
        // Keep the primary click available even if a stale preference says otherwise.
        if (button == 0) return Verdict.Pass;
        var action = config.ActionFor(button);
        if (BeginMode(action, new List<int> { button })) return Verdict.Swallow;
        int target;
        switch (action.Kind)
        {
            case ActionKind.System: return Verdict.Pass;
            case ActionKind.LeftClick: target = 0; break;
            case ActionKind.RightClick: target = 1; break;
            case ActionKind.MiddleClick: target = 2; break;
            case ActionKind.Back: target = 3; break;
            case ActionKind.Forward: target = 4; break;
            case ActionKind.Disabled:
                overrides[button] = new Override.Swallow();
                return Verdict.Swallow;
            case ActionKind.Shortcut:
                overrides[button] = new Override.Swallow();
                if (action.Shortcut != null) host.SendShortcut(action.Shortcut);
                return Verdict.Swallow;
            case ActionKind.HoldShortcut:
                if (action.Shortcut == null) return Verdict.Pass;
                overrides[button] = new Override.HeldShortcut(action.Shortcut);
                host.ShortcutDown(action.Shortcut);
                return Verdict.Swallow;
            case ActionKind.ModifiedClick:
                overrides[button] = new Override.Remap(action.Button, action.Modifiers);
                host.InjectButton(action.Button, true, action.Modifiers);
                return Verdict.Swallow;
            default:
                return Verdict.Swallow;   // modes: handled by BeginMode
        }
        if (target == button) return Verdict.Pass;
        overrides[button] = new Override.Remap(target, 0);
        host.InjectButton(target, true, 0);
        return Verdict.Swallow;
    }

    private void Perform(ButtonAction action)
    {
        switch (action.Kind)
        {
            case ActionKind.Shortcut:
            case ActionKind.HoldShortcut:
                if (action.Shortcut != null) host.SendShortcut(action.Shortcut);
                break;
            case ActionKind.LeftClick:
            case ActionKind.RightClick:
            case ActionKind.MiddleClick:
            case ActionKind.Back:
            case ActionKind.Forward:
            case ActionKind.ModifiedClick:
                host.Click(action);
                break;
        }
    }

    // MARK: Precision, Scroll with ball, Drag lock

    private bool BeginMode(ButtonAction action, List<int> buttons)
    {
        switch (action.Kind)
        {
            case ActionKind.PrecisionHold:
                foreach (var b in buttons) overrides[b] = new Override.Precision();
                precisionHeld = true;
                StartHoldFailsafe();
                break;
            case ActionKind.PrecisionToggle:
                foreach (var b in buttons) overrides[b] = new Override.Swallow();
                precisionToggled = !precisionToggled;
                precisionManual = false;
                break;
            case ActionKind.BallScrollHold:
                foreach (var b in buttons) overrides[b] = new Override.BallScroll();
                BeginBallScroll(latched: false);
                break;
            case ActionKind.DragLock:
                if (dragLocked)
                {
                    foreach (var b in buttons) overrides[b] = new Override.Swallow();
                    EndDragLock();
                }
                else
                {
                    foreach (var b in buttons) overrides[b] = new Override.DragButton();
                    BeginDragLock(manual: false);
                }
                break;
            default:
                return false;
        }
        PublishModes();
        return true;
    }

    private void EndPrecisionHold()
    {
        precisionHeld = false;
        foreach (var b in overrides.Keys.ToList())
            if (overrides[b] is Override.Precision) overrides[b] = new Override.Swallow();
        PublishModes();
    }

    private void BeginBallScroll(bool latched)
    {
        if (latched) ballScrollLatched = true;
        else
        {
            ballScrollHeld = true;
            StartHoldFailsafe();
        }
        if (ballScrolling) return;
        ballScrolling = true;
        host.BallScroll(true, false);
    }

    private void EndBallScroll(bool latched, bool glide)
    {
        if (latched) ballScrollLatched = false;
        else
        {
            ballScrollHeld = false;
            foreach (var b in overrides.Keys.ToList())
                if (overrides[b] is Override.BallScroll) overrides[b] = new Override.Swallow();
        }
        if (ballScrollHeld || ballScrollLatched) return;
        if (!ballScrolling) return;
        ballScrolling = false;
        host.BallScroll(false, glide);
        PublishModes();
    }

    private void BeginDragLock(bool manual)
    {
        dragLocked = true;
        dragLockManual = manual;
        host.DragLockButton(true);
    }

    private void EndDragLock()
    {
        if (!dragLocked) return;
        dragLocked = false;
        dragLockManual = false;
        host.DragLockButton(false);
        foreach (var b in overrides.Keys.ToList())
            if (overrides[b] is Override.DragButton) overrides[b] = new Override.Swallow();
        PublishModes();
    }

    /// <summary>Would this press reach apps as a left click?</summary>
    private bool IsLeftPress(int button, bool fromTrackball)
    {
        if (button == 0) return true;
        if (!config.Enabled || !fromTrackball) return false;
        var a = config.ActionFor(button);
        return a.Kind == ActionKind.LeftClick || (a.Kind == ActionKind.ModifiedClick && a.Button == 0);
    }

    private bool InDragLockCombo(int button, bool fromTrackball) =>
        config.Enabled && fromTrackball
        && config.Chords.Any(c => c.Action.Kind == ActionKind.DragLock && c.Buttons.Contains(button));

    // MARK: Keyboard toggles (global shortcuts, tray)

    public void TogglePrecision()
    {
        precisionToggled = !precisionToggled;
        precisionManual = precisionToggled;
        PublishModes();
    }

    public void ToggleBallScroll()
    {
        if (ballScrollLatched) EndBallScroll(latched: true, glide: true);
        else BeginBallScroll(latched: true);
        PublishModes();
    }

    public void ToggleDragLock()
    {
        if (dragLocked) EndDragLock();
        else BeginDragLock(manual: true);
        PublishModes();
    }

    // MARK: Failsafes

    private void StartHoldFailsafe()
    {
        holdStart = clock;
        holdReleasedChecks = 0;
        trackballButtonSeen = trackballDown.Count > 0;
        nextHoldCheck ??= clock + HoldCheckInterval;
    }

    private void CheckHolds(double now)
    {
        if (!precisionHeld && !ballScrollHeld)
        {
            nextHoldCheck = null;
            return;
        }
        nextHoldCheck = now + HoldCheckInterval;
        bool lost;
        if (trackballButtonSeen)
        {
            holdReleasedChecks = trackballDown.Count == 0 ? holdReleasedChecks + 1 : 0;
            lost = holdReleasedChecks >= 2;
        }
        else
        {
            lost = now - holdStart > 10;
        }
        if (!lost) return;
        if (ballScrollHeld) EndBallScroll(latched: false, glide: false);
        if (precisionHeld) EndPrecisionHold();
    }

    /// <summary>
    /// Ends everything at once (pause, quit, unplug): modes end, held shortcuts
    /// are released, and presses waiting for a combo go through untouched.
    /// </summary>
    public void ReleaseAll()
    {
        // Waiting presses go back as they were.
        pendingDeadline = null;
        var presses = pending.ToList();
        pending.Clear();
        foreach (var p in presses) host.Replay(p.original);

        ReleaseModes();
        var released = new HashSet<KeyShortcut>();
        foreach (var b in overrides.Keys.ToList())
        {
            switch (overrides[b])
            {
                case Override.HeldShortcut h:
                    // A combo holds one shortcut on several buttons: release it once.
                    if (released.Add(h.Shortcut)) host.ShortcutUp(h.Shortcut);
                    overrides[b] = new Override.Swallow();
                    break;
                case Override.Remap r:
                    host.InjectButton(r.Target, false, r.Modifiers);
                    overrides[b] = new Override.Swallow();
                    break;
            }
        }
        learning = false;
    }

    private void ReleaseModes()
    {
        if (ballScrolling)
        {
            ballScrolling = false;
            host.BallScroll(false, false);
        }
        ballScrollHeld = false;
        ballScrollLatched = false;
        EndDragLock();
        precisionHeld = false;
        precisionToggled = false;
        precisionManual = false;
        foreach (var b in overrides.Keys.ToList())
            if (overrides[b] is Override.Precision or Override.BallScroll or Override.DragButton)
                overrides[b] = new Override.Swallow();
        PublishModes();
    }

    private void DropOrphanedModes()
    {
        if (!precisionToggled && !dragLocked && !ballScrollLatched) return;
        var assigned = config.Buttons.Values.Select(a => a.Kind).Concat(config.Chords.Select(c => c.Action.Kind)).ToHashSet();
        if (precisionToggled && !precisionManual && !assigned.Contains(ActionKind.PrecisionToggle)) precisionToggled = false;
        if (dragLocked && !dragLockManual && !assigned.Contains(ActionKind.DragLock)) EndDragLock();
        if (ballScrollLatched && config.GlobalShortcuts.BallScroll == null) EndBallScroll(latched: true, glide: false);
        PublishModes();
    }

    private void PublishModes()
    {
        var m = new Modes(PrecisionActive, ballScrolling, dragLocked);
        if (m == modes) return;
        modes = m;
        host.ModesChanged(m);
    }
}
