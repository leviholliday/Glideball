using System;
using System.Collections.Generic;
using System.Linq;
using Glideball.Core.Settings;

namespace Glideball.Core.Keys;

[Flags]
public enum WinModifiers
{
    None = 0,
    Ctrl = 1,
    Alt = 2,
    Shift = 4,
    Win = 8,
}

/// <summary>A shortcut in Windows terms: modifiers plus an optional virtual key.</summary>
public sealed record WinChord(WinModifiers Modifiers, ushort VirtualKey)
{
    public string Display
    {
        get
        {
            var parts = new List<string>();
            if (Modifiers.HasFlag(WinModifiers.Ctrl)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(WinModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(WinModifiers.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(WinModifiers.Win)) parts.Add("Win");
            if (VirtualKey != 0) parts.Add(KeyMap.WindowsKeyName(VirtualKey));
            return string.Join("+", parts);
        }
    }
}

/// <summary>
/// Translates between the Mac's stored shortcuts (macOS virtual key codes and
/// CGEventFlags) and Windows virtual keys.
///
/// Modifiers: ⌘ Command ↔ Ctrl, ⌃ Control ↔ Win, ⌥ Option ↔ Alt, ⇧ ↔ Shift —
/// so ⌘C (copy) is Ctrl+C, and every shortcut recorded on Windows survives a
/// trip through a Mac and back. A few Mac presets have a better Windows
/// equivalent and are translated specially (matched on key, modifiers and the
/// Mac's key name, so a shortcut recorded on Windows is never mistaken for one):
/// Spaces → virtual desktops, Mission Control / App Exposé → Task view,
/// Spotlight → Search.
/// </summary>
public static class KeyMap
{
    // Windows virtual-key codes used here.
    public const ushort VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SHIFT = 0x10, VK_CONTROL = 0x11,
        VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_SPACE = 0x20, VK_PRIOR = 0x21, VK_NEXT = 0x22, VK_END = 0x23,
        VK_HOME = 0x24, VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_INSERT = 0x2D,
        VK_DELETE = 0x2E, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_F1 = 0x70,
        VK_OEM_1 = 0xBA, VK_OEM_PLUS = 0xBB, VK_OEM_COMMA = 0xBC, VK_OEM_MINUS = 0xBD, VK_OEM_PERIOD = 0xBE,
        VK_OEM_2 = 0xBF, VK_OEM_3 = 0xC0, VK_OEM_4 = 0xDB, VK_OEM_5 = 0xDC, VK_OEM_6 = 0xDD, VK_OEM_7 = 0xDE,
        VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1;

    /// <summary>macOS kVK_* → Windows VK.</summary>
    private static readonly Dictionary<ushort, ushort> MacToWin = new()
    {
        [0] = 'A', [11] = 'B', [8] = 'C', [2] = 'D', [14] = 'E', [3] = 'F', [5] = 'G', [4] = 'H', [34] = 'I',
        [38] = 'J', [40] = 'K', [37] = 'L', [46] = 'M', [45] = 'N', [31] = 'O', [35] = 'P', [12] = 'Q', [15] = 'R',
        [1] = 'S', [17] = 'T', [32] = 'U', [9] = 'V', [13] = 'W', [7] = 'X', [16] = 'Y', [6] = 'Z',
        [29] = '0', [18] = '1', [19] = '2', [20] = '3', [21] = '4', [23] = '5', [22] = '6', [26] = '7', [28] = '8', [25] = '9',
        [36] = VK_RETURN, [48] = VK_TAB, [49] = VK_SPACE, [51] = VK_BACK, [53] = VK_ESCAPE, [117] = VK_DELETE,
        [115] = VK_HOME, [119] = VK_END, [116] = VK_PRIOR, [121] = VK_NEXT, [114] = VK_INSERT,
        [123] = VK_LEFT, [124] = VK_RIGHT, [125] = VK_DOWN, [126] = VK_UP,
        [24] = VK_OEM_PLUS, [27] = VK_OEM_MINUS, [33] = VK_OEM_4, [30] = VK_OEM_6, [41] = VK_OEM_1, [39] = VK_OEM_7,
        [43] = VK_OEM_COMMA, [47] = VK_OEM_PERIOD, [44] = VK_OEM_2, [42] = VK_OEM_5, [50] = VK_OEM_3,
        [122] = VK_F1, [120] = VK_F1 + 1, [99] = VK_F1 + 2, [118] = VK_F1 + 3, [96] = VK_F1 + 4, [97] = VK_F1 + 5,
        [98] = VK_F1 + 6, [100] = VK_F1 + 7, [101] = VK_F1 + 8, [109] = VK_F1 + 9, [103] = VK_F1 + 10, [111] = VK_F1 + 11,
        [105] = VK_F1 + 12, [107] = VK_F1 + 13, [113] = VK_F1 + 14, [106] = VK_F1 + 15, [64] = VK_F1 + 16,
        [79] = VK_F1 + 17, [80] = VK_F1 + 18, [90] = VK_F1 + 19,
    };

    private static readonly Dictionary<ushort, ushort> WinToMac = MacToWin.ToDictionary(kv => kv.Value, kv => kv.Key);

    /// <summary>Mac presets with a better Windows meaning than the literal translation.</summary>
    private static readonly (KeyShortcut mac, WinChord win)[] Special =
    {
        (KeyShortcut.PreviousSpace, new WinChord(WinModifiers.Ctrl | WinModifiers.Win, VK_LEFT)),
        (KeyShortcut.NextSpace, new WinChord(WinModifiers.Ctrl | WinModifiers.Win, VK_RIGHT)),
        (KeyShortcut.MissionControl, new WinChord(WinModifiers.Win, VK_TAB)),
        (KeyShortcut.AppExpose, new WinChord(WinModifiers.Win, VK_TAB)),
        (KeyShortcut.Spotlight, new WinChord(WinModifiers.Win, 'S')),
    };

    public static WinModifiers ModifiersToWindows(ulong mac)
    {
        var m = WinModifiers.None;
        if ((mac & MacFlags.Command) != 0) m |= WinModifiers.Ctrl;
        if ((mac & MacFlags.Control) != 0) m |= WinModifiers.Win;
        if ((mac & MacFlags.Option) != 0) m |= WinModifiers.Alt;
        if ((mac & MacFlags.Shift) != 0) m |= WinModifiers.Shift;
        return m;
    }

    public static ulong ModifiersToMac(WinModifiers m)
    {
        ulong mac = 0;
        if (m.HasFlag(WinModifiers.Ctrl)) mac |= MacFlags.Command;
        if (m.HasFlag(WinModifiers.Win)) mac |= MacFlags.Control;
        if (m.HasFlag(WinModifiers.Alt)) mac |= MacFlags.Option;
        if (m.HasFlag(WinModifiers.Shift)) mac |= MacFlags.Shift;
        return mac;
    }

    /// <summary>
    /// Modifiers for a modified click. These follow what the click means rather
    /// than the keyboard rule: ⌘-click and ⌃-click are both Ctrl-click on Windows.
    /// </summary>
    public static WinModifiers ClickModifiersToWindows(ulong mac)
    {
        var m = WinModifiers.None;
        if ((mac & (MacFlags.Command | MacFlags.Control)) != 0) m |= WinModifiers.Ctrl;
        if ((mac & MacFlags.Option) != 0) m |= WinModifiers.Alt;
        if ((mac & MacFlags.Shift) != 0) m |= WinModifiers.Shift;
        return m;
    }

    /// <summary>The Windows shortcut a stored shortcut fires, or null if its key has no Windows equivalent.</summary>
    public static WinChord? ToWindows(KeyShortcut s)
    {
        foreach (var (mac, win) in Special)
            if (mac.SameKeys(s) && mac.KeyName == s.KeyName) return win;
        if (!MacToWin.TryGetValue(s.KeyCode, out var vk)) return null;
        return new WinChord(ModifiersToWindows(s.Modifiers), vk);
    }

    /// <summary>Stores a shortcut recorded on Windows in the Mac's terms. Null if the key has no Mac equivalent.</summary>
    public static KeyShortcut? FromWindows(ushort vk, WinModifiers modifiers)
    {
        vk = vk switch
        {
            VK_LSHIFT or VK_RSHIFT or VK_SHIFT or VK_LCONTROL or VK_RCONTROL or VK_CONTROL
                or VK_LMENU or VK_RMENU or VK_MENU or VK_LWIN or VK_RWIN => (ushort)0,
            _ => vk,
        };
        if (vk == 0 || !WinToMac.TryGetValue(vk, out var mac)) return null;
        return new KeyShortcut(mac, ModifiersToMac(modifiers), WindowsKeyName(vk));
    }

    /// <summary>Names used for keys recorded on Windows. Deliberately not the Mac's arrow glyphs.</summary>
    public static string WindowsKeyName(ushort vk) => vk switch
    {
        >= 'A' and <= 'Z' => ((char)vk).ToString(),
        >= '0' and <= '9' => ((char)vk).ToString(),
        >= VK_F1 and <= VK_F1 + 23 => "F" + (vk - VK_F1 + 1),
        VK_RETURN => "Enter",
        VK_TAB => "Tab",
        VK_SPACE => "Spacebar",
        VK_BACK => "Backspace",
        VK_ESCAPE => "Esc",
        VK_DELETE => "Delete",
        VK_INSERT => "Insert",
        VK_HOME => "Home",
        VK_END => "End",
        VK_PRIOR => "PageUp",
        VK_NEXT => "PageDown",
        VK_LEFT => "Left",
        VK_RIGHT => "Right",
        VK_UP => "Up",
        VK_DOWN => "Down",
        VK_OEM_PLUS => "=",
        VK_OEM_MINUS => "-",
        VK_OEM_4 => "[",
        VK_OEM_6 => "]",
        VK_OEM_1 => ";",
        VK_OEM_7 => "'",
        VK_OEM_COMMA => ",",
        VK_OEM_PERIOD => ".",
        VK_OEM_2 => "/",
        VK_OEM_5 => "\\",
        VK_OEM_3 => "`",
        _ => "0x" + vk.ToString("X2"),
    };

    /// <summary>How a stored shortcut reads on Windows: "Ctrl+Win+Left".</summary>
    public static string Display(KeyShortcut s) => ToWindows(s)?.Display ?? s.KeyName;

    /// <summary>Arrow and navigation keys need KEYEVENTF_EXTENDEDKEY when injected.</summary>
    public static bool IsExtended(ushort vk) => vk is VK_LEFT or VK_RIGHT or VK_UP or VK_DOWN or VK_HOME or VK_END
        or VK_PRIOR or VK_NEXT or VK_INSERT or VK_DELETE or VK_LWIN or VK_RWIN or VK_RCONTROL or VK_RMENU;
}
