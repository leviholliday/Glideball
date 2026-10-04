using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Glideball.Core.Settings;

namespace Glideball;

public partial class App : Application
{
    private const string InstanceName = "Local\\Glideball.SingleInstance";
    private const string ShowEventName = "Local\\Glideball.Show";

    private Mutex? instance;
    private EventWaitHandle? showEvent;
    private AppState? state;
    private Tray? tray;
    private Hotkeys? hotkeys;
    private MainWindow? window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // One Glideball at a time: a second launch just brings the first one forward.
        instance = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            try
            {
                using var signal = EventWaitHandle.OpenExisting(ShowEventName);
                signal.Set();
            }
            catch (WaitHandleCannotBeOpenedException) { }
            Shutdown();
            return;
        }
        showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        var waiter = new Thread(() =>
        {
            while (showEvent.WaitOne())
                Dispatcher.InvokeAsync(ShowWindow);
        }) { IsBackground = true, Name = "Glideball show" };
        waiter.Start();

        DispatcherUnhandledException += OnDispatcherException;

        state = new AppState(Dispatcher);
        hotkeys = new Hotkeys(OnHotkey);
        hotkeys.Apply(state.Config.GlobalShortcuts);
        var applied = ShortcutsKey(state.Config.GlobalShortcuts);
        state.Changed += () =>
        {
            var key = ShortcutsKey(state.Config.GlobalShortcuts);
            if (key == applied) return;
            applied = key;
            hotkeys.Apply(state.Config.GlobalShortcuts);
        };
        tray = new Tray(state, ShowWindow, Quit);

        var background = e.Args.Contains("--background");
        var file = e.Args.FirstOrDefault(a => a.EndsWith("." + SettingsFile.Extension, StringComparison.OrdinalIgnoreCase));
        if (!background || file != null) ShowWindow();
        if (file != null && File.Exists(file)) window?.ImportFile(file);
    }

    private static string ShortcutsKey(GlobalShortcuts g) =>
        string.Join("|", new[] { g.Pause, g.Precision, g.BallScroll, g.DragLock }.Select(s => s == null ? "-" : $"{s.KeyCode}:{s.Modifiers}:{s.KeyName}"));

    private void OnHotkey(Hotkeys.Action action)
    {
        if (state == null) return;
        switch (action)
        {
            case Hotkeys.Action.Pause:
                state.TogglePause();
                tray?.Notify(state.Config.Enabled ? "Glideball resumed" : "Glideball paused",
                    state.Config.Enabled ? "Your trackball settings are back." : "The trackball works as plain Windows mouse until you resume.");
                break;
            case Hotkeys.Action.Precision: state.Engine.TogglePrecision(); break;
            case Hotkeys.Action.BallScroll: state.Engine.ToggleBallScroll(); break;
            case Hotkeys.Action.DragLock: state.Engine.ToggleDragLock(); break;
        }
    }

    public void ShowWindow()
    {
        if (state == null) return;
        if (window == null)
        {
            window = new MainWindow(state);
            window.Closed += (_, _) => window = null;
        }
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public void Quit()
    {
        window?.Close();
        tray?.Dispose();
        hotkeys?.Dispose();
        state?.Shutdown();
        Shutdown();
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        // A UI bug must never cost the user their mouse: log it, let go of everything, carry on.
        DiagLog.Write("UI exception: " + e.Exception);
        SafetyNet.ReleaseEverything();
        e.Handled = true;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SafetyNet.ReleaseEverything();
        instance?.Dispose();
        base.OnExit(e);
    }
}
