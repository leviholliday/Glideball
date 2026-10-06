using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;

namespace Glideball.Core.Settings;

/// <summary>
/// macOS CGEventFlags bits. Settings files store shortcuts the way the Mac
/// does (macOS virtual key code + these modifier bits) so the same file works
/// on both platforms. <see cref="Keys.KeyMap"/> translates for Windows.
/// </summary>
public static class MacFlags
{
    public const ulong Shift = 0x20000;
    public const ulong Control = 0x40000;
    public const ulong Option = 0x80000;
    public const ulong Command = 0x100000;
    public const ulong All = Shift | Control | Option | Command;
}

/// <summary>A keyboard shortcut a button can fire (Mac's <c>KeyShortcut</c>).</summary>
public sealed record KeyShortcut(ushort KeyCode, ulong Modifiers, string KeyName)
{
    public bool SameKeys(KeyShortcut other) => KeyCode == other.KeyCode && Modifiers == other.Modifiers;

    // The Mac's presets, kept so files and defaults line up exactly.
    public static readonly KeyShortcut PreviousSpace = new(123, MacFlags.Control, "←");
    public static readonly KeyShortcut NextSpace = new(124, MacFlags.Control, "→");
    public static readonly KeyShortcut MissionControl = new(126, MacFlags.Control, "↑");
    public static readonly KeyShortcut AppExpose = new(125, MacFlags.Control, "↓");
    public static readonly KeyShortcut BrowserBack = new(33, MacFlags.Command, "[");
    public static readonly KeyShortcut BrowserForward = new(30, MacFlags.Command, "]");
    public static readonly KeyShortcut Copy = new(8, MacFlags.Command, "C");
    public static readonly KeyShortcut Paste = new(9, MacFlags.Command, "V");
    public static readonly KeyShortcut Undo = new(6, MacFlags.Command, "Z");
    public static readonly KeyShortcut NewTab = new(17, MacFlags.Command, "T");
    public static readonly KeyShortcut CloseTab = new(13, MacFlags.Command, "W");
    public static readonly KeyShortcut Spotlight = new(49, MacFlags.Command, "Space");
    public static readonly KeyShortcut WisprFlow = new(49, MacFlags.Control, "Space");
}

/// <summary>Swift enum case names, exactly as they appear in the JSON.</summary>
public enum ActionKind
{
    System,
    LeftClick,
    RightClick,
    MiddleClick,
    Back,
    Forward,
    Shortcut,
    HoldShortcut,
    ModifiedClick,
    Disabled,
    PrecisionHold,
    PrecisionToggle,
    BallScrollHold,
    DragLock,
}

/// <summary>What a physical trackball button does (Mac's <c>ButtonAction</c>).</summary>
public sealed record ButtonAction(ActionKind Kind, KeyShortcut? Shortcut = null, int Button = 0, ulong Modifiers = 0)
{
    public static readonly ButtonAction SystemDefault = new(ActionKind.System);
    public static readonly ButtonAction LeftClick = new(ActionKind.LeftClick);
    public static readonly ButtonAction RightClick = new(ActionKind.RightClick);
    public static readonly ButtonAction MiddleClick = new(ActionKind.MiddleClick);
    public static readonly ButtonAction Back = new(ActionKind.Back);
    public static readonly ButtonAction Forward = new(ActionKind.Forward);
    public static readonly ButtonAction Disabled = new(ActionKind.Disabled);
    public static readonly ButtonAction PrecisionHold = new(ActionKind.PrecisionHold);
    public static readonly ButtonAction PrecisionToggle = new(ActionKind.PrecisionToggle);
    public static readonly ButtonAction BallScrollHold = new(ActionKind.BallScrollHold);
    public static readonly ButtonAction DragLock = new(ActionKind.DragLock);

    public static ButtonAction Press(KeyShortcut s) => new(ActionKind.Shortcut, s);
    public static ButtonAction Hold(KeyShortcut s) => new(ActionKind.HoldShortcut, s);
    public static ButtonAction Click(int button, ulong macModifiers) => new(ActionKind.ModifiedClick, null, button, macModifiers);

    /// <summary>Precision, Scroll with ball and Drag lock keep state across presses.</summary>
    public bool IsMode => Kind is ActionKind.PrecisionHold or ActionKind.PrecisionToggle
        or ActionKind.BallScrollHold or ActionKind.DragLock;
}

/// <summary>Two or three buttons pressed together.</summary>
public sealed class Chord
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public List<int> Buttons { get; set; } = new();
    public ButtonAction Action { get; set; } = ButtonAction.SystemDefault;

    public Chord() { }

    public Chord(IEnumerable<int> buttons, ButtonAction action)
    {
        Buttons = buttons.OrderBy(b => b).ToList();
        Action = action;
    }

    public bool Matches(IReadOnlySet<int> held) => held.SetEquals(Buttons);

    public Chord Clone() => new() { Id = Id, Buttons = Buttons.ToList(), Action = Action };
}

public enum ScrollMode { Native, Flywheel, Follow }

/// <summary>Glide's own system-wide keyboard shortcuts. Only Pause has one by default.</summary>
public sealed class GlobalShortcuts
{
    /// <summary>⌃⌥⌘G on the Mac; Ctrl+Alt+Win+G on Windows.</summary>
    public static readonly KeyShortcut DefaultPause = new(5, MacFlags.Control | MacFlags.Option | MacFlags.Command, "G");

    public KeyShortcut? Pause { get; set; } = DefaultPause;
    public KeyShortcut? Precision { get; set; }
    public KeyShortcut? BallScroll { get; set; }
    public KeyShortcut? DragLock { get; set; }

    public GlobalShortcuts Clone() => new() { Pause = Pause, Precision = Precision, BallScroll = BallScroll, DragLock = DragLock };
}

/// <summary>Everything on the Scrolling tab, so an app setup can take it over as a whole.</summary>
public sealed record ScrollSettings
{
    public ScrollMode ScrollMode { get; init; } = ScrollMode.Flywheel;
    public double NativeScrollSpeed { get; init; } = 0.5;
    public double FlyDistance { get; init; } = 4;
    public double FlyAcceleration { get; init; } = 0.5;
    public double FlyGlide { get; init; } = 0.35;
    public double FlyReach { get; init; } = 0.5;
    public bool SmoothScrolling { get; init; } = true;
    public double ScrollDistance { get; init; } = 14;
    public double ScrollSmoothness { get; init; } = 0.4;
    public double ScrollAcceleration { get; init; } = 0.5;
    public bool ThrowEnabled { get; init; } = true;
    public double ThrowAmount { get; init; } = 0.4;
    public bool ReverseScroll { get; init; }
    public bool ShiftScrollsHorizontally { get; init; } = true;
}

/// <summary>
/// A setup used while one app is in front. On the Mac <see cref="BundleId"/> is a
/// bundle identifier; on Windows it holds the process name ("chrome.exe").
/// Each area is optional: null means "use the main setup".
/// </summary>
public sealed class AppProfile
{
    public string BundleId { get; set; } = "";
    public string Name { get; set; } = "";
    public double? TrackingSpeed { get; set; }
    public ScrollSettings? Scroll { get; set; }
    public Dictionary<int, ButtonAction>? Buttons { get; set; }
    public List<Chord>? Chords { get; set; }
    /// <summary>Keys this version doesn't know, kept so a round trip loses nothing.</summary>
    public JsonObject? Extra { get; set; }

    public bool AppliesTo(string? processName) =>
        processName != null && string.Equals(BundleId, processName, StringComparison.OrdinalIgnoreCase);

    public AppProfile Clone() => new()
    {
        BundleId = BundleId,
        Name = Name,
        TrackingSpeed = TrackingSpeed,
        Scroll = Scroll,
        Buttons = Buttons == null ? null : new Dictionary<int, ButtonAction>(Buttons),
        Chords = Chords?.Select(c => c.Clone()).ToList(),
        Extra = Extra == null ? null : (JsonObject)Extra.DeepClone(),
    };
}

/// <summary>The settings model (Mac's <c>GlideConfig</c>). Defaults match the Mac's.</summary>
public sealed class GlideConfig
{
    public bool Enabled { get; set; } = true;

    public double TrackingSpeed { get; set; } = 4.0;
    public double PrecisionSpeed { get; set; } = 1.0;

    public ScrollMode ScrollMode { get; set; } = ScrollMode.Flywheel;
    public double NativeScrollSpeed { get; set; } = 0.5;
    public double FlyDistance { get; set; } = 4;
    public double FlyAcceleration { get; set; } = 0.5;
    public double FlyGlide { get; set; } = 0.35;
    /// <summary>How much farther the very fastest spins go (0 = the old 12,000 pt/s limit).</summary>
    public double FlyReach { get; set; } = 0.5;
    public bool SmoothScrolling { get; set; } = true;
    public double ScrollDistance { get; set; } = 14;
    public double ScrollSmoothness { get; set; } = 0.4;
    public double ScrollAcceleration { get; set; } = 0.5;
    public bool ThrowEnabled { get; set; } = true;
    public double ThrowAmount { get; set; } = 0.4;
    public bool ReverseScroll { get; set; }
    public bool ShiftScrollsHorizontally { get; set; } = true;
    public double BallScrollSpeed { get; set; } = 1.0;

    /// <summary>Keyed by Mac button number (0 = primary, 1 = secondary, 2 = middle, 3 = back, 4 = forward).</summary>
    public Dictionary<int, ButtonAction> Buttons { get; set; } = new()
    {
        [2] = ButtonAction.Press(KeyShortcut.PreviousSpace),
        [3] = ButtonAction.Press(KeyShortcut.NextSpace),
    };

    public List<Chord> Chords { get; set; } = new()
    {
        new Chord(new[] { 0, 2, 3 }, ButtonAction.Hold(KeyShortcut.WisprFlow)),
    };

    public List<AppProfile> AppProfiles { get; set; } = new();
    public GlobalShortcuts GlobalShortcuts { get; set; } = new();

    /// <summary>Keys this version doesn't know (from a newer Mac or Windows build), written back unchanged.</summary>
    public JsonObject? Extra { get; set; }

    /// <summary>
    /// What a fresh Windows install starts with: the Mac's model, but without
    /// the Mac-specific button defaults (Spaces and Wispr Flow's ⌃Space), so the
    /// top buttons keep doing what Windows does with them (middle click, back).
    /// </summary>
    public static GlideConfig WindowsDefaults()
    {
        var c = new GlideConfig();
        c.Buttons.Clear();
        c.Chords.Clear();
        return c;
    }

    public ScrollSettings Scroll
    {
        get => new()
        {
            ScrollMode = ScrollMode,
            NativeScrollSpeed = NativeScrollSpeed,
            FlyDistance = FlyDistance,
            FlyAcceleration = FlyAcceleration,
            FlyGlide = FlyGlide,
            FlyReach = FlyReach,
            SmoothScrolling = SmoothScrolling,
            ScrollDistance = ScrollDistance,
            ScrollSmoothness = ScrollSmoothness,
            ScrollAcceleration = ScrollAcceleration,
            ThrowEnabled = ThrowEnabled,
            ThrowAmount = ThrowAmount,
            ReverseScroll = ReverseScroll,
            ShiftScrollsHorizontally = ShiftScrollsHorizontally,
        };
        set
        {
            ScrollMode = value.ScrollMode;
            NativeScrollSpeed = value.NativeScrollSpeed;
            FlyDistance = value.FlyDistance;
            FlyAcceleration = value.FlyAcceleration;
            FlyGlide = value.FlyGlide;
            FlyReach = value.FlyReach;
            SmoothScrolling = value.SmoothScrolling;
            ScrollDistance = value.ScrollDistance;
            ScrollSmoothness = value.ScrollSmoothness;
            ScrollAcceleration = value.ScrollAcceleration;
            ThrowEnabled = value.ThrowEnabled;
            ThrowAmount = value.ThrowAmount;
            ReverseScroll = value.ReverseScroll;
            ShiftScrollsHorizontally = value.ShiftScrollsHorizontally;
        }
    }

    public GlideConfig Clone()
    {
        var c = (GlideConfig)MemberwiseClone();
        c.Buttons = new Dictionary<int, ButtonAction>(Buttons);
        c.Chords = Chords.Select(x => x.Clone()).ToList();
        c.AppProfiles = AppProfiles.Select(p => p.Clone()).ToList();
        c.GlobalShortcuts = GlobalShortcuts.Clone();
        c.Extra = Extra == null ? null : (JsonObject)Extra.DeepClone();
        return c;
    }

    public AppProfile? ProfileFor(string? processName) => AppProfiles.FirstOrDefault(p => p.AppliesTo(processName));

    /// <summary>This setup with the app's customized areas laid over it (Mac's <c>resolved(for:)</c>).</summary>
    public GlideConfig ResolvedFor(string? processName)
    {
        var p = ProfileFor(processName);
        if (p == null) return this;
        var c = Clone();
        if (p.TrackingSpeed is double speed) c.TrackingSpeed = speed;
        if (p.Scroll != null) c.Scroll = p.Scroll;
        if (p.Buttons != null)
        {
            var map = new Dictionary<int, ButtonAction>(p.Buttons);
            // The primary button is never per-app: it stays a left click.
            map.Remove(0);
            if (Buttons.TryGetValue(0, out var primary)) map[0] = primary;
            c.Buttons = map;
        }
        if (p.Chords != null) c.Chords = p.Chords.Select(x => x.Clone()).ToList();
        return c;
    }

    /// <summary>Every button that belongs to some combo.</summary>
    public HashSet<int> ComboButtons() => Chords.SelectMany(c => c.Buttons).ToHashSet();

    public ButtonAction ActionFor(int button) => Buttons.TryGetValue(button, out var a) ? a : ButtonAction.SystemDefault;
}
