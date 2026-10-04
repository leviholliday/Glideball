using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Glideball.Core.Keys;
using Glideball.Native;

namespace Glideball.Input;

/// <summary>
/// Everything Glideball injects goes through here. Every event carries
/// <see cref="Marker"/> in dwExtraInfo so the hook never processes it again,
/// and every key or button we press down is remembered until we let it go,
/// so <see cref="ReleaseAll"/> can always leave the keyboard and mouse clean
/// (pause, quit, crash). Thread-safe.
/// </summary>
internal static class Injector
{
    /// <summary>"GLID", like the Mac's synthetic tag.</summary>
    public static readonly UIntPtr Marker = new(0x474C4944u);

    private static readonly object Gate = new();
    private static readonly HashSet<ushort> heldKeys = new();
    private static readonly HashSet<int> heldButtons = new();
    private static readonly int InputSize = Marshal.SizeOf<Win32.INPUT>();

    /// <summary>Raised (on the injecting thread) after anything is injected.</summary>
    [ThreadStatic] public static int InjectedCount;

    private static void Send(params Win32.INPUT[] inputs)
    {
        if (inputs.Length == 0) return;
        Win32.SendInput((uint)inputs.Length, inputs, InputSize);
        InjectedCount++;
    }

    private static Win32.INPUT Mouse(uint flags, uint data = 0, int dx = 0, int dy = 0) => new()
    {
        type = Win32.INPUT_MOUSE,
        U = new Win32.InputUnion
        {
            mi = new Win32.MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags, dwExtraInfo = Marker },
        },
    };

    private static Win32.INPUT Key(ushort vk, bool down)
    {
        var flags = down ? 0u : Win32.KEYEVENTF_KEYUP;
        if (KeyMap.IsExtended(vk)) flags |= Win32.KEYEVENTF_EXTENDEDKEY;
        return new Win32.INPUT
        {
            type = Win32.INPUT_KEYBOARD,
            U = new Win32.InputUnion
            {
                ki = new Win32.KEYBDINPUT
                {
                    wVk = vk,
                    wScan = (ushort)Win32.MapVirtualKey(vk, 0),
                    dwFlags = flags,
                    dwExtraInfo = Marker,
                },
            },
        };
    }

    // MARK: Buttons (Mac numbering: 0 left, 1 right, 2 middle, 3 back/X1, 4 forward/X2)

    public static void Button(int button, bool down)
    {
        uint flags, data = 0;
        switch (button)
        {
            case 0: flags = down ? Win32.MOUSEEVENTF_LEFTDOWN : Win32.MOUSEEVENTF_LEFTUP; break;
            case 1: flags = down ? Win32.MOUSEEVENTF_RIGHTDOWN : Win32.MOUSEEVENTF_RIGHTUP; break;
            case 2: flags = down ? Win32.MOUSEEVENTF_MIDDLEDOWN : Win32.MOUSEEVENTF_MIDDLEUP; break;
            case 3: flags = down ? Win32.MOUSEEVENTF_XDOWN : Win32.MOUSEEVENTF_XUP; data = Win32.XBUTTON1; break;
            case 4: flags = down ? Win32.MOUSEEVENTF_XDOWN : Win32.MOUSEEVENTF_XUP; data = Win32.XBUTTON2; break;
            default: return;
        }
        lock (Gate)
        {
            if (down) heldButtons.Add(button); else heldButtons.Remove(button);
            Send(Mouse(flags, data));
        }
    }

    /// <summary>A button with modifier keys held around it (a modified click).</summary>
    public static void ModifiedButton(int button, bool down, WinModifiers modifiers)
    {
        if (down)
        {
            Modifiers(modifiers, true);
            Button(button, true);
        }
        else
        {
            Button(button, false);
            Modifiers(modifiers, false);
        }
    }

    public static void Wheel(int delta, bool horizontal)
    {
        if (delta == 0) return;
        lock (Gate) Send(Mouse(horizontal ? Win32.MOUSEEVENTF_HWHEEL : Win32.MOUSEEVENTF_WHEEL, unchecked((uint)delta)));
    }

    // MARK: Keys

    private static readonly (WinModifiers flag, ushort vk)[] ModifierKeys =
    {
        (WinModifiers.Ctrl, KeyMap.VK_LCONTROL),
        (WinModifiers.Alt, KeyMap.VK_LMENU),
        (WinModifiers.Shift, KeyMap.VK_LSHIFT),
        (WinModifiers.Win, KeyMap.VK_LWIN),
    };

    private static void Modifiers(WinModifiers m, bool down)
    {
        var list = new List<Win32.INPUT>();
        lock (Gate)
        {
            if (down)
            {
                foreach (var (flag, vk) in ModifierKeys)
                    if (m.HasFlag(flag)) { list.Add(Key(vk, true)); heldKeys.Add(vk); }
            }
            else
            {
                for (var i = ModifierKeys.Length - 1; i >= 0; i--)
                {
                    var (flag, vk) = ModifierKeys[i];
                    if (m.HasFlag(flag)) { list.Add(Key(vk, false)); heldKeys.Remove(vk); }
                }
            }
            Send(list.ToArray());
        }
    }

    public static void ChordDown(WinChord c)
    {
        Modifiers(c.Modifiers, true);
        if (c.VirtualKey == 0) return;
        lock (Gate)
        {
            heldKeys.Add(c.VirtualKey);
            Send(Key(c.VirtualKey, true));
        }
    }

    public static void ChordUp(WinChord c)
    {
        if (c.VirtualKey != 0)
        {
            lock (Gate)
            {
                heldKeys.Remove(c.VirtualKey);
                Send(Key(c.VirtualKey, false));
            }
        }
        Modifiers(c.Modifiers, false);
    }

    public static void Chord(WinChord c)
    {
        ChordDown(c);
        ChordUp(c);
    }

    // MARK: Replaying hook events

    /// <summary>Re-injects a mouse event the hook held back, as it was.</summary>
    public static void Replay(HookEvent e)
    {
        switch (e.Message)
        {
            case Win32.WM_MOUSEWHEEL:
                Wheel(e.WheelDelta, false);
                break;
            case Win32.WM_MOUSEHWHEEL:
                Wheel(e.WheelDelta, true);
                break;
            default:
                if (e.Button is int b)
                {
                    // A replayed press/release is the user's own: don't track it as ours.
                    lock (Gate)
                    {
                        var down = e.IsDown;
                        uint flags, data = 0;
                        switch (b)
                        {
                            case 0: flags = down ? Win32.MOUSEEVENTF_LEFTDOWN : Win32.MOUSEEVENTF_LEFTUP; break;
                            case 1: flags = down ? Win32.MOUSEEVENTF_RIGHTDOWN : Win32.MOUSEEVENTF_RIGHTUP; break;
                            case 2: flags = down ? Win32.MOUSEEVENTF_MIDDLEDOWN : Win32.MOUSEEVENTF_MIDDLEUP; break;
                            case 3: flags = down ? Win32.MOUSEEVENTF_XDOWN : Win32.MOUSEEVENTF_XUP; data = Win32.XBUTTON1; break;
                            default: flags = down ? Win32.MOUSEEVENTF_XDOWN : Win32.MOUSEEVENTF_XUP; data = Win32.XBUTTON2; break;
                        }
                        Send(Mouse(flags, data));
                    }
                }
                break;
        }
    }

    /// <summary>Lets go of every key and button Glideball is holding down. Safe to call from any thread, repeatedly.</summary>
    public static void ReleaseAll()
    {
        int[] buttons;
        ushort[] keys;
        lock (Gate)
        {
            buttons = new int[heldButtons.Count];
            heldButtons.CopyTo(buttons);
            keys = new ushort[heldKeys.Count];
            heldKeys.CopyTo(keys);
        }
        foreach (var b in buttons) Button(b, false);
        lock (Gate)
        {
            var list = new List<Win32.INPUT>();
            foreach (var k in keys) list.Add(Key(k, false));
            heldKeys.Clear();
            Send(list.ToArray());
        }
    }

    public static bool HoldingAnything
    {
        get { lock (Gate) return heldKeys.Count > 0 || heldButtons.Count > 0; }
    }
}
