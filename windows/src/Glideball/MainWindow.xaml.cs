using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Glideball.Core.Backup;
using Glideball.Core.Settings;
using Glideball.Native;
using Glideball.UI;
using Microsoft.Win32;

namespace Glideball;

public partial class MainWindow : Window
{
    private readonly AppState state;
    private PageBase? page;

    internal MainWindow(AppState state)
    {
        this.state = state;
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyGlass(this);
        state.Changed += Refresh;
        Closed += (_, _) =>
        {
            state.Changed -= Refresh;
            page?.Leave();
        };
        AllowDrop = true;
        Drop += OnDrop;
        Nav.SelectedIndex = 0;
        Refresh();
    }

    /// <summary>
    /// Dark title bar, and Mica behind the whole window on Windows 11 22H2+
    /// (the WPF content is transparent so the backdrop shows through).
    /// Older Windows keeps the solid dark background.
    /// </summary>
    internal static void ApplyGlass(Window w)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = 1;
        Win32.DwmSetWindowAttribute(hwnd, Win32.DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        if (Environment.OSVersion.Version.Build < 22621) return;
        var backdrop = Win32.DWMSBT_MAINWINDOW;
        if (Win32.DwmSetWindowAttribute(hwnd, Win32.DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int)) != 0) return;
        var margins = new Win32.MARGINS { cxLeftWidth = -1, cxRightWidth = -1, cyTopHeight = -1, cyBottomHeight = -1 };
        Win32.DwmExtendFrameIntoClientArea(hwnd, ref margins);
        if (HwndSource.FromHwnd(hwnd) is HwndSource source && source.CompositionTarget != null)
            source.CompositionTarget.BackgroundColor = Colors.Transparent;
        // A faint tint keeps text readable over bright wallpapers.
        w.Background = new SolidColorBrush(Color.FromArgb(0x55, 0x10, 0x12, 0x18));
    }

    private void Refresh()
    {
        EnabledSwitch.IsChecked = state.Config.Enabled;
        var s = state.Status;
        string text;
        Brush dot;
        if (!state.Config.Enabled) { text = "Paused"; dot = Ui.Brush("Warn"); }
        else if (!s.HookActive) { text = "Input hook unavailable"; dot = Ui.Brush("Warn"); }
        else if (s.DeviceConnected) { text = s.DeviceName ?? "Trackball connected"; dot = Ui.Brush("Good"); }
        else { text = "No trackball connected"; dot = Ui.Brush("Faint"); }
        StatusText.Text = text;
        StatusDot.Fill = dot;
        var pause = state.Config.GlobalShortcuts.Pause;
        PauseHint.Text = pause == null
            ? "No pause shortcut set. Use this switch or the tray icon."
            : $"{Glideball.Core.Keys.KeyMap.Display(pause)} pauses or resumes from anywhere.";
        page?.StateChanged();
    }

    private void EnabledSwitch_Click(object sender, RoutedEventArgs e) => state.SetPaused(EnabledSwitch.IsChecked != true);

    private void Nav_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e) => ShowPage(Nav.SelectedIndex);

    internal void ShowPage(int index)
    {
        page?.Leave();
        page = index switch
        {
            1 => (PageBase)new PointerPage(state, this),
            2 => new ScrollingPage(state, this),
            3 => new ButtonsPage(state, this),
            4 => new AppsPage(state, this),
            5 => new BackupPage(state, this),
            _ => new OverviewPage(state, this),
        };
        PageHost.Content = page.Build();
        PageScroller.ScrollToTop();
    }

    /// <summary>Rebuilds the current page (after an import or restore replaced everything).</summary>
    internal void Rebuild() => ShowPage(Nav.SelectedIndex);

    // MARK: Import

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.FirstOrDefault() is string f) ImportFile(f);
    }

    internal void ImportFromDialog()
    {
        var dialog = new OpenFileDialog
        {
            Title = "Import Glideball settings",
            Filter = $"Glideball settings (*.{SettingsFile.Extension})|*.{SettingsFile.Extension}|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog(this) == true) ImportFile(dialog.FileName);
    }

    /// <summary>Previews what an import changes, then replaces everything (with a checkpoint to undo it).</summary>
    internal void ImportFile(string path)
    {
        GlideConfig incoming;
        SettingsFile file;
        try
        {
            file = SettingsFile.Parse(File.ReadAllText(path));
            incoming = file.ValidatedConfig();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SettingsFileException)
        {
            MessageBox.Show(this, e.Message, "Can't import these settings", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        var now = Presets.Summary(state.Config);
        var next = Presets.Summary(incoming);
        var lines = now.Zip(next, (a, b) => a.Value == b.Value ? $"{a.Title}: {a.Value}" : $"{a.Title}: {a.Value}  →  {b.Value}");
        var origin = file.ExportedFrom != null ? $"From {file.ExportedFrom}" : "From another computer";
        if (file.ExportedAt is DateTimeOffset at) origin += $", {at.LocalDateTime:g}";
        var message = $"{origin}\n\n{string.Join("\n", lines)}\n\nYour current settings are backed up first, so you can restore them from the Backup page.";
        if (MessageBox.Show(this, message, "Replace your settings?", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;
        state.ReplaceAll(incoming, BackupKind.BeforeImport);
        Rebuild();
    }

    internal void ExportToDialog()
    {
        var dialog = new SaveFileDialog
        {
            Title = "Export Glideball settings",
            FileName = $"Glideball Settings – {DateTime.Now:MMM d, yyyy}.{SettingsFile.Extension}",
            Filter = $"Glideball settings (*.{SettingsFile.Extension})|*.{SettingsFile.Extension}",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            File.WriteAllText(dialog.FileName, state.ExportJson());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, e.Message, "Couldn't export", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
