using System;
using System.Drawing;
using System.Windows;
using WinForms = System.Windows.Forms;

namespace Glideball;

/// <summary>The notification-area icon: open, pause/resume, quit.</summary>
internal sealed class Tray : IDisposable
{
    private readonly AppState state;
    private readonly WinForms.NotifyIcon icon;
    private readonly WinForms.ToolStripMenuItem pauseItem;

    public Tray(AppState state, Action open, Action quit)
    {
        this.state = state;
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open Glideball", null, (_, _) => open());
        pauseItem = new WinForms.ToolStripMenuItem("Pause Glideball", null, (_, _) => state.TogglePause())
        {
            ShortcutKeyDisplayString = "Ctrl+Alt+Win+G",
        };
        menu.Items.Add(pauseItem);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit Glideball", null, (_, _) => quit());

        icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Glideball",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left) open();
        };
        state.Changed += Refresh;
        Refresh();
    }

    private static Icon LoadIcon()
    {
        try
        {
            var info = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Glideball.ico"));
            if (info != null) return new Icon(info.Stream);
        }
        catch (Exception e) when (e is System.IO.IOException or ArgumentException or InvalidOperationException)
        {
            DiagLog.Write("tray icon: " + e.Message);
        }
        return SystemIcons.Application;
    }

    private void Refresh()
    {
        var paused = !state.Config.Enabled;
        pauseItem.Text = paused ? "Resume Glideball" : "Pause Glideball";
        var device = state.Status.DeviceConnected ? state.Status.DeviceName ?? "Trackball" : "No trackball";
        var text = paused ? "Glideball (paused)" : $"Glideball · {device}";
        icon.Text = text.Length > 63 ? text.Substring(0, 63) : text;
    }

    public void Notify(string title, string text)
    {
        icon.BalloonTipTitle = title;
        icon.BalloonTipText = text;
        icon.ShowBalloonTip(2500);
    }

    public void Dispose()
    {
        state.Changed -= Refresh;
        icon.Visible = false;
        icon.Dispose();
    }
}
