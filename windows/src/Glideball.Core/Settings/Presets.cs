using System.Collections.Generic;
using System.Linq;
using Glideball.Core.Keys;

namespace Glideball.Core.Settings;

public sealed record ActionPreset(string Title, ButtonAction Action);

/// <summary>Menu entries for button actions, with Windows names. What's saved is the action itself.</summary>
public static class Presets
{
    public static readonly IReadOnlyList<ActionPreset> All = new List<ActionPreset>
    {
        new("Default", ButtonAction.SystemDefault),
        new("Left click", ButtonAction.LeftClick),
        new("Right click", ButtonAction.RightClick),
        new("Middle click", ButtonAction.MiddleClick),
        new("Back", ButtonAction.Back),
        new("Forward", ButtonAction.Forward),
        new("Ctrl-click", ButtonAction.Click(0, MacFlags.Command)),
        new("Shift-click", ButtonAction.Click(0, MacFlags.Shift)),
        new("Alt-click", ButtonAction.Click(0, MacFlags.Option)),
        new("Previous desktop", ButtonAction.Press(KeyShortcut.PreviousSpace)),
        new("Next desktop", ButtonAction.Press(KeyShortcut.NextSpace)),
        new("Task view", ButtonAction.Press(KeyShortcut.MissionControl)),
        new("Search", ButtonAction.Press(KeyShortcut.Spotlight)),
        new("Copy", ButtonAction.Press(KeyShortcut.Copy)),
        new("Paste", ButtonAction.Press(KeyShortcut.Paste)),
        new("Undo", ButtonAction.Press(KeyShortcut.Undo)),
        new("New tab", ButtonAction.Press(KeyShortcut.NewTab)),
        new("Close tab", ButtonAction.Press(KeyShortcut.CloseTab)),
        new("Precision (hold)", ButtonAction.PrecisionHold),
        new("Precision (toggle)", ButtonAction.PrecisionToggle),
        new("Scroll with ball (hold)", ButtonAction.BallScrollHold),
        new("Drag lock", ButtonAction.DragLock),
        new("Do nothing", ButtonAction.Disabled),
    };

    public static string Title(ButtonAction a)
    {
        var p = All.FirstOrDefault(x => x.Action == a);
        if (p != null) return p.Title;
        return a.Kind switch
        {
            ActionKind.Shortcut when a.Shortcut != null => KeyMap.Display(a.Shortcut),
            ActionKind.HoldShortcut when a.Shortcut != null => "Hold " + KeyMap.Display(a.Shortcut),
            ActionKind.ModifiedClick => ClickTitle(a),
            _ => "Custom",
        };
    }

    private static string ClickTitle(ButtonAction a)
    {
        var mods = KeyMap.ClickModifiersToWindows(a.Modifiers);
        var button = a.Button switch { 0 => "click", 1 => "right-click", 2 => "middle-click", _ => "button " + (a.Button + 1) };
        var prefix = new WinChord(mods, 0).Display;
        // The Mac's Control-click (its context-menu click) is a right click on Windows.
        if (a.Button == 0 && a.Modifiers == MacFlags.Control) return "Right click (Mac Control-click)";
        return prefix.Length == 0 ? button : prefix + "-" + button;
    }

    /// <summary>"Bottom left", … — the Expert Mouse's buttons by Mac number.</summary>
    public static string ButtonName(int button) => button switch
    {
        0 => "Bottom left (primary)",
        1 => "Bottom right",
        2 => "Top left",
        3 => "Top right",
        4 => "Button 5",
        _ => "Button " + (button + 1),
    };

    /// <summary>One line per area, for import previews (Mac's <c>summary</c>).</summary>
    public static List<(string Title, string Value)> Summary(GlideConfig c)
    {
        var remapped = c.Buttons.Values.Count(a => a.Kind != ActionKind.System);
        var scroll = c.ScrollMode switch
        {
            ScrollMode.Native => "Native",
            ScrollMode.Flywheel => $"Flywheel · {(int)c.FlyDistance} pt, {(int)(c.FlyAcceleration * 100)}% power",
            _ => $"Follow · {(int)c.ScrollDistance} pt per tick",
        };
        return new List<(string, string)>
        {
            ("Pointer speed", c.TrackingSpeed.ToString("0.##", System.Globalization.CultureInfo.CurrentCulture)),
            ("Scrolling", scroll),
            ("Buttons", remapped == 0 ? "Default" : $"{remapped} remapped"),
            ("Combos", c.Chords.Count == 0 ? "None" : c.Chords.Count.ToString(System.Globalization.CultureInfo.CurrentCulture)),
            ("App setups", c.AppProfiles.Count switch
            {
                0 => "None",
                1 or 2 => string.Join(", ", c.AppProfiles.Select(p => p.Name)),
                _ => $"{c.AppProfiles.Count} apps",
            }),
        };
    }
}
