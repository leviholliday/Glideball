using System;
using System.Collections.Generic;

namespace Glideball.Core.Devices;

/// <summary>What one input event did. Wheel kinds carry the direction (+1 / −1).</summary>
public readonly record struct InputSignal(SignalKind Kind, int Button = 0, int Sign = 0)
{
    public static InputSignal Down(int button) => new(SignalKind.ButtonDown, button);
    public static InputSignal Up(int button) => new(SignalKind.ButtonUp, button);
    public static InputSignal Wheel(int sign) => new(SignalKind.Wheel, 0, Math.Sign(sign));
    public static InputSignal HWheel(int sign) => new(SignalKind.HWheel, 0, Math.Sign(sign));
}

public enum SignalKind { ButtonDown, ButtonUp, Wheel, HWheel }

public enum Source
{
    /// <summary>A supported Kensington reported this exact event.</summary>
    Trackball,
    /// <summary>Another device reported it, or nobody did in time: leave it alone.</summary>
    Other,
}

/// <summary>
/// Pairs low-level hook events (which carry no device) with Raw Input events
/// (which do), so a button press or wheel tick is treated as the trackball's
/// only when the trackball itself reported that very event. Pure logic; the
/// Windows host feeds it and acts on what it releases.
///
/// For one physical event Windows usually calls the LL hook first and delivers
/// WM_INPUT just after, but the order isn't guaranteed. So:
///  • a raw event that arrives first waits (briefly) in <c>unmatched</c> for its hook event;
///  • a hook event that needs a device and has no raw partner yet is held in
///    <c>held</c> (the host swallows it) until its raw partner arrives, or until
///    <see cref="HoldTimeout"/>, when it fails open as <see cref="Source.Other"/>
///    and is replayed untouched.
/// Held events are released strictly in arrival order, so a press can never
/// overtake its own release.
/// </summary>
public sealed class InputCorrelator
{
    public sealed class Held
    {
        public InputSignal Signal { get; init; }
        public double Time { get; init; }
        public bool NeedsSource { get; init; }
        public Source? Source { get; internal set; }
        /// <summary>The host's payload (the original hook event, to replay or handle).</summary>
        public object? Tag { get; init; }
    }

    public readonly record struct Released(Held Event, Source Source);

    /// <summary>How long an unclaimed raw event can still be matched.</summary>
    public double RawLifetime { get; set; } = 0.06;
    /// <summary>The longest a hook event is held waiting for its raw partner.</summary>
    public double HoldTimeout { get; set; } = 0.04;

    private readonly List<(InputSignal signal, Source source, double time)> unmatched = new();
    private readonly List<Held> held = new();

    public int HeldCount => held.Count;

    /// <summary>The time at which <see cref="Expire"/> has work to do, if any.</summary>
    public double? NextDeadline => held.Count == 0 ? null : held[0].Time + HoldTimeout;

    /// <summary>A Raw Input event. Returns hook events it lets go of, in order.</summary>
    public List<Released> AddRaw(InputSignal signal, Source source, double now)
    {
        Prune(now);
        foreach (var h in held)
        {
            if (h.Source == null && h.NeedsSource && h.Signal == signal)
            {
                h.Source = source;
                return Drain();
            }
        }
        unmatched.Add((signal, source, now));
        return new List<Released>();
    }

    /// <summary>
    /// A hook event. <paramref name="needsSource"/> is false when the answer can't
    /// change what happens (no trackball connected, or a button nobody remapped):
    /// those only queue up behind held events to keep the order.
    /// Returns the events released by this call (possibly including this one).
    /// </summary>
    public List<Released> AddHook(InputSignal signal, bool needsSource, double now, object? tag, out Held entry)
    {
        Prune(now);
        entry = new Held { Signal = signal, Time = now, NeedsSource = needsSource, Tag = tag };
        if (!needsSource)
        {
            entry.Source = Source.Other;
        }
        else
        {
            for (var i = 0; i < unmatched.Count; i++)
            {
                if (unmatched[i].signal != signal) continue;
                entry.Source = unmatched[i].source;
                unmatched.RemoveAt(i);
                break;
            }
        }
        held.Add(entry);
        return Drain();
    }

    /// <summary>Fails open: anything held past its deadline is treated as another device's.</summary>
    public List<Released> Expire(double now)
    {
        Prune(now);
        var any = false;
        foreach (var h in held)
        {
            if (h.Source == null && now - h.Time >= HoldTimeout)
            {
                h.Source = Source.Other;
                any = true;
            }
        }
        return any ? Drain() : new List<Released>();
    }

    /// <summary>Releases everything (pause, quit): all held events go back untouched.</summary>
    public List<Released> Flush()
    {
        foreach (var h in held) h.Source ??= Source.Other;
        unmatched.Clear();
        return Drain();
    }

    private List<Released> Drain()
    {
        var output = new List<Released>();
        while (held.Count > 0 && held[0].Source is Source s)
        {
            output.Add(new Released(held[0], s));
            held.RemoveAt(0);
        }
        return output;
    }

    private void Prune(double now) => unmatched.RemoveAll(u => now - u.time > RawLifetime);
}
