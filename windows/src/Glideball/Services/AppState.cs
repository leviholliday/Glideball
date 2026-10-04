using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows.Threading;
using Glideball.Core.Backup;
using Glideball.Core.Buttons;
using Glideball.Core.Settings;
using Glideball.Input;
using Glideball.Native;
using Microsoft.Win32;

namespace Glideball;

/// <summary>
/// The app's model, on the UI thread: the settings, this PC's preferences,
/// backups, and the bridge to the input engine (per-app profiles, pause).
/// </summary>
internal sealed class AppState
{
    public static AppState Current { get; private set; } = null!;

    public SettingsStore Store { get; } = new();
    public GlideConfig Config { get; private set; }
    public Preferences Prefs { get; }
    public BackupStore Backups { get; }
    public InputEngine Engine { get; }
    public EngineStatus Status { get; private set; }
    public Modes Modes { get; private set; }
    public string? ForegroundProcess { get; private set; }

    /// <summary>Raised on the UI thread after settings, status or modes change.</summary>
    public event Action? Changed;
    public event Action<IReadOnlyCollection<int>>? Learned;

    private readonly Dispatcher dispatcher;
    private readonly DispatcherTimer saveTimer;
    private readonly DispatcherTimer foregroundTimer;
    private readonly DispatcherTimer backupTimer;

    public AppState(Dispatcher dispatcher)
    {
        Current = this;
        this.dispatcher = dispatcher;
        Directory.CreateDirectory(SettingsStore.Folder);
        DiagLog.FilePath = Path.Combine(SettingsStore.Folder, "glideball.log");
        Config = Store.Load();
        Prefs = Store.LoadPreferences();
        Backups = Store.CreateBackups();
        Backups.Enabled = Prefs.AutoBackups;
        Backups.SnapshotIfDue(Config);

        Engine = new InputEngine(Config);
        Engine.StatusChanged += s => dispatcher.InvokeAsync(() => { Status = s; Changed?.Invoke(); });
        Engine.ModesChanged += m => dispatcher.InvokeAsync(() => { Modes = m; Changed?.Invoke(); });
        Engine.Learned += b => dispatcher.InvokeAsync(() => Learned?.Invoke(b));
        SafetyNet.Install(Engine);
        Engine.Start();
        PushPreferences();

        saveTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(400) };
        saveTimer.Tick += (_, _) => { saveTimer.Stop(); Store.Save(Config); };

        // Per-app setups: follow the app in front.
        foregroundTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
        foregroundTimer.Tick += (_, _) => CheckForeground();
        foregroundTimer.Start();

        // A PC that's never restarted still gets one backup a day.
        backupTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMinutes(30) };
        backupTimer.Tick += (_, _) => Backups.SnapshotIfDue(Config);
        backupTimer.Start();
    }

    // MARK: Settings

    /// <summary>Changes the settings: backs up the day's first state, saves, and applies.</summary>
    public void Edit(Action<GlideConfig> change)
    {
        var old = Config;
        Backups.WillChange(old);
        var next = old.Clone();
        change(next);
        Config = next;
        saveTimer.Stop();
        saveTimer.Start();
        PushConfig();
        Changed?.Invoke();
    }

    /// <summary>Replaces every setting (import, restore), with a checkpoint first so it can be undone.</summary>
    public void ReplaceAll(GlideConfig config, BackupKind checkpoint)
    {
        Backups.Checkpoint(Config, checkpoint);
        var enabled = Config.Enabled;
        Config = config.Clone();
        Config.Enabled = enabled;   // importing never pauses or resumes
        Store.Save(Config);
        PushConfig();
        Changed?.Invoke();
    }

    public void EditPreferences(Action<Preferences> change)
    {
        change(Prefs);
        Backups.Enabled = Prefs.AutoBackups;
        Store.SavePreferences(Prefs);
        PushPreferences();
        Changed?.Invoke();
    }

    public void SetPaused(bool paused)
    {
        if (Config.Enabled == !paused) return;
        var postedAt = Clock.Now;
        Edit(c => c.Enabled = !paused);
        if (paused)
        {
            // The escape hatch must work even if the input thread is wedged.
            var watchdog = new DispatcherTimer(DispatcherPriority.Send, dispatcher) { Interval = TimeSpan.FromMilliseconds(400) };
            watchdog.Tick += (_, _) =>
            {
                watchdog.Stop();
                if (Engine.Heartbeat < postedAt) Engine.EmergencyStop();
            };
            watchdog.Start();
        }
    }

    public void TogglePause() => SetPaused(Config.Enabled);

    public void SaveNow()
    {
        saveTimer.Stop();
        Store.Save(Config);
    }

    private void PushConfig() => Engine.Update(Config.ResolvedFor(ForegroundProcess));

    private void PushPreferences() => Engine.SetPreferences(Prefs.BetaProgram, Prefs.PerDeviceSpeed, Prefs.WheelUnitsPerPoint);

    private uint lastPid;

    private void CheckForeground()
    {
        var w = Win32.GetForegroundWindow();
        if (w == IntPtr.Zero) return;
        Win32.GetWindowThreadProcessId(w, out var pid);
        if (pid == lastPid) return;
        lastPid = pid;
        string? name = null;
        try
        {
            using var p = Process.GetProcessById((int)pid);
            name = p.ProcessName + ".exe";
        }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
        if (string.Equals(name, ForegroundProcess, StringComparison.OrdinalIgnoreCase)) return;
        var before = Config.ProfileFor(ForegroundProcess);
        ForegroundProcess = name;
        // Only re-apply when the profile in effect actually changes.
        if (before != Config.ProfileFor(name)) PushConfig();
    }

    // MARK: Import / export

    public string ExportJson() => SettingsFile.Create(Config, Environment.MachineName, DateTimeOffset.Now).ToJson();

    // MARK: Start with Windows

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool StartsWithWindows
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Glideball") is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value && Environment.ProcessPath is string exe) key.SetValue("Glideball", $"\"{exe}\" --background");
            else key.DeleteValue("Glideball", throwOnMissingValue: false);
        }
    }

    public void Shutdown()
    {
        foregroundTimer.Stop();
        backupTimer.Stop();
        SaveNow();
        Engine.Dispose();
        SafetyNet.ReleaseEverything();
    }
}
