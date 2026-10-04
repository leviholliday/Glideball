using System;
using System.Collections.Generic;
using System.Windows.Interop;
using Glideball.Core.Keys;
using Glideball.Core.Settings;
using Glideball.Native;

namespace Glideball;

/// <summary>
/// Glideball's system-wide shortcuts (Ctrl+Alt+Win+G pauses by default), as
/// thread hotkeys on the UI thread. They need no hook, so Pause works even if
/// a mapping or the input engine misbehaves.
/// </summary>
internal sealed class Hotkeys : IDisposable
{
    public enum Action { Pause = 1, Precision = 2, BallScroll = 3, DragLock = 4 }

    private readonly Dictionary<int, Action> registered = new();
    private readonly System.Action<Action> handler;

    /// <summary>Shortcuts Windows refused (already taken by another app), for the UI.</summary>
    public List<Action> Failed { get; } = new();

    public Hotkeys(System.Action<Action> handler)
    {
        this.handler = handler;
        ComponentDispatcher.ThreadFilterMessage += Filter;
    }

    public void Apply(GlobalShortcuts shortcuts)
    {
        foreach (var id in registered.Keys) Win32.UnregisterHotKey(IntPtr.Zero, id);
        registered.Clear();
        Failed.Clear();
        Register(Action.Pause, shortcuts.Pause);
        Register(Action.Precision, shortcuts.Precision);
        Register(Action.BallScroll, shortcuts.BallScroll);
        Register(Action.DragLock, shortcuts.DragLock);
    }

    private void Register(Action action, KeyShortcut? shortcut)
    {
        if (shortcut == null || KeyMap.ToWindows(shortcut) is not WinChord chord || chord.VirtualKey == 0) return;
        uint mods = Win32.MOD_NOREPEAT;
        if (chord.Modifiers.HasFlag(WinModifiers.Ctrl)) mods |= Win32.MOD_CONTROL;
        if (chord.Modifiers.HasFlag(WinModifiers.Alt)) mods |= Win32.MOD_ALT;
        if (chord.Modifiers.HasFlag(WinModifiers.Shift)) mods |= Win32.MOD_SHIFT;
        if (chord.Modifiers.HasFlag(WinModifiers.Win)) mods |= Win32.MOD_WIN;
        var id = (int)action;
        if (Win32.RegisterHotKey(IntPtr.Zero, id, mods, chord.VirtualKey)) registered[id] = action;
        else Failed.Add(action);
    }

    private void Filter(ref MSG msg, ref bool handled)
    {
        if (msg.message != Win32.WM_HOTKEY || msg.hwnd != IntPtr.Zero) return;
        if (registered.TryGetValue((int)msg.wParam, out var action))
        {
            handled = true;
            handler(action);
        }
    }

    public void Dispose()
    {
        ComponentDispatcher.ThreadFilterMessage -= Filter;
        foreach (var id in registered.Keys) Win32.UnregisterHotKey(IntPtr.Zero, id);
        registered.Clear();
    }
}
