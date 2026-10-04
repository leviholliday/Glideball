using System;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Glideball.Core.Keys;
using Glideball.Core.Settings;

namespace Glideball.UI;

/// <summary>A page of the main window. Built on navigation; told when the app's state changes.</summary>
internal abstract class PageBase
{
    protected readonly AppState State;
    protected readonly MainWindow Window;

    protected PageBase(AppState state, MainWindow window)
    {
        State = state;
        Window = window;
    }

    public abstract UIElement Build();
    public virtual void StateChanged() { }
    public virtual void Leave() { }
}

internal sealed class OverviewPage : PageBase
{
    private readonly DispatcherTimer timer;
    private readonly LiveGraph ballGraph = new(Color.FromRgb(0x7A, 0xA7, 0xFF), "in/s");
    private readonly LiveGraph ringGraph = new(Color.FromRgb(0xA8, 0x8B, 0xFF), "notches/s");
    private readonly TextBlock device = new() { FontSize = 18, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock deviceNote = Ui.Note("");
    private readonly TextBlock clicks = Stat();
    private readonly TextBlock rolled = Stat();
    private readonly TextBlock scrolled = Stat();
    private readonly TextBlock modes = Ui.Note("", 8);
    private long lastBall, lastNotches;
    private double lastTime;

    // The Expert Mouse reports 400 counts per inch.
    private const double CountsPerInch = 400;

    public OverviewPage(AppState state, MainWindow window) : base(state, window)
    {
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) => Sample();
        lastBall = Interlocked.Read(ref state.Engine.BallCounts);
        lastNotches = Interlocked.Read(ref state.Engine.Notches);
        lastTime = Input.Clock.Now;
        timer.Start();
    }

    private static TextBlock Stat() => new() { FontSize = 22, FontWeight = FontWeights.SemiBold };

    public override UIElement Build()
    {
        var graphs = new Grid();
        graphs.ColumnDefinitions.Add(new ColumnDefinition());
        graphs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        graphs.ColumnDefinitions.Add(new ColumnDefinition());
        var ball = Ui.Card("Ball speed", ballGraph);
        var ring = Ui.Card("Scroll ring", ringGraph);
        Grid.SetColumn(ring, 2);
        graphs.Children.Add(ball);
        graphs.Children.Add(ring);

        var stats = new UniformGrid3(
            Labeled(clicks, "clicks this session"),
            Labeled(rolled, "rolled"),
            Labeled(scrolled, "scrolled"));

        StateChanged();
        Sample();
        return Ui.Page("Overview", "Your Kensington, tuned. Every other mouse and touchpad stays exactly as Windows has it.",
            Ui.Card(null, device, deviceNote, modes),
            graphs,
            Ui.Card("Today", stats),
            Shortcuts(),
            General());
    }

    private static StackPanel Labeled(TextBlock value, string label)
    {
        var s = new StackPanel();
        s.Children.Add(value);
        s.Children.Add(Ui.Note(label));
        return s;
    }

    private Border Shortcuts()
    {
        var g = State.Config.GlobalShortcuts;
        return Ui.Card("Keyboard shortcuts",
            Ui.Note("Work from any app. Pause is your escape hatch: it needs no hook, so it works even if a mapping goes wrong."),
            ShortcutRow("Pause / resume Glideball", g.Pause, s => State.Edit(c => c.GlobalShortcuts.Pause = s)),
            ShortcutRow("Precision", g.Precision, s => State.Edit(c => c.GlobalShortcuts.Precision = s)),
            ShortcutRow("Scroll with ball", g.BallScroll, s => State.Edit(c => c.GlobalShortcuts.BallScroll = s)),
            ShortcutRow("Drag lock", g.DragLock, s => State.Edit(c => c.GlobalShortcuts.DragLock = s)));
    }

    private Grid ShortcutRow(string title, KeyShortcut? current, Action<KeyShortcut?> set)
    {
        var label = new TextBlock
        {
            Text = current == null ? "None" : KeyMap.Display(current),
            Foreground = Ui.Brush("SubText"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 12, 0),
        };
        var record = Ui.Button("Record…", () =>
        {
            var s = ShortcutRecorder.Record(Window, $"Press the shortcut for “{title}”. Include Ctrl, Alt or Win.", requireModifier: true);
            if (s == null) return;
            set(s);
            label.Text = KeyMap.Display(s);
        });
        var clear = Ui.Button("Clear", () =>
        {
            set(null);
            label.Text = "None";
        });
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(label);
        panel.Children.Add(record);
        panel.Children.Add(clear);
        return Ui.Row(title, panel);
    }

    private Border General()
    {
        return Ui.Card("General",
            Ui.Switch("Start with Windows", AppState.StartsWithWindows, on => AppState.StartsWithWindows = on,
                "Starts quietly in the notification area when you sign in."),
            Ui.Switch("Beta program: other Kensington trackballs", State.Prefs.BetaProgram,
                on => State.EditPreferences(p => p.BetaProgram = on),
                "Adds the SlimBlade, Orbit, Expert Mouse Wireless and others. They haven't been tuned yet."),
            Ui.Note("The Beta switch belongs to this PC and never travels in a settings file.", 4),
            Ui.Buttons(
                Ui.Button("Open settings folder", () => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{SettingsStore.Folder}\"") { UseShellExecute = true })),
                Ui.Button("Copy diagnostics", () => Clipboard.SetText(DiagLog.Snapshot())),
                Ui.Button("Quit Glideball", () => ((App)Application.Current).Quit())));
    }

    public override void StateChanged()
    {
        var s = State.Status;
        if (s.DeviceConnected)
        {
            device.Text = s.DeviceName ?? "Kensington trackball";
            deviceNote.Text = s.DeviceIsBeta ? "Connected · Beta program device" : "Connected";
        }
        else
        {
            device.Text = "No trackball connected";
            deviceNote.Text = s.UnsupportedDeviceName != null
                ? $"{s.UnsupportedDeviceName} is connected. Turn on the Beta program below to use it."
                : "Plug in your Kensington Expert Mouse. If KensingtonWorks is installed, uninstall it first.";
        }
        if (!s.HookActive) deviceNote.Text += "\nThe input hook isn't running; Glideball can't change anything right now.";
        var m = State.Modes;
        var on = new System.Collections.Generic.List<string>();
        if (!State.Config.Enabled) on.Add("Paused");
        if (m.Precision) on.Add("Precision on");
        if (m.BallScrolling) on.Add("Scrolling with the ball");
        if (m.DragLocked) on.Add("Drag lock on");
        modes.Text = string.Join(" · ", on);
    }

    private void Sample()
    {
        var now = Input.Clock.Now;
        var ball = Interlocked.Read(ref State.Engine.BallCounts);
        var notches = Interlocked.Read(ref State.Engine.Notches);
        var dt = Math.Max(now - lastTime, 0.001);
        ballGraph.Push((ball - lastBall) / CountsPerInch / dt);
        ringGraph.Push((notches - lastNotches) / dt);
        lastBall = ball;
        lastNotches = notches;
        lastTime = now;

        var c = CultureInfo.CurrentCulture;
        clicks.Text = Interlocked.Read(ref State.Engine.Clicks).ToString("N0", c);
        rolled.Text = (ball / CountsPerInch * 0.0254).ToString("0.0", c) + " m";
        scrolled.Text = (State.Engine.PointsScrolled / 96 * 0.0254).ToString("0.0", c) + " m";
    }

    public override void Leave() => timer.Stop();
}

/// <summary>Three equal columns.</summary>
internal sealed class UniformGrid3 : Grid
{
    public UniformGrid3(params UIElement[] children)
    {
        for (var i = 0; i < children.Length; i++)
        {
            ColumnDefinitions.Add(new ColumnDefinition());
            SetColumn(children[i], i);
            Children.Add(children[i]);
        }
    }
}
