using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Glideball.Core.Backup;

namespace Glideball.UI;

internal sealed class BackupPage : PageBase
{
    public BackupPage(AppState state, MainWindow window) : base(state, window) { }

    public override UIElement Build()
    {
        var transfer = Ui.Card("Export and import",
            Ui.Note("A .glide-settings file holds your whole setup. It's the same format as Glideball for Mac, " +
                    "so files move freely between your Mac and your PC. You can also drop a file on this window."),
            Ui.Buttons(
                Ui.Button("Export…", Window.ExportToDialog, accent: true),
                Ui.Button("Import…", Window.ImportFromDialog)));

        State.Backups.Reload();
        var list = new StackPanel();
        if (State.Backups.Backups.Count == 0) list.Children.Add(Ui.Note("No backups yet."));
        foreach (var b in State.Backups.Backups)
        {
            var when = b.Date.ToString("f", CultureInfo.CurrentCulture);
            var kind = b.Kind == BackupKind.Daily ? "Daily" : BackupStore.KindName(b.Kind);
            var entry = b;
            var restore = Ui.Button("Restore", () =>
            {
                var config = BackupStore.Load(entry);
                if (config == null)
                {
                    MessageBox.Show(Window, "This backup can't be read.", "Restore", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                if (MessageBox.Show(Window, $"Replace your settings with the backup from {when}?\n\nYour current settings are backed up first.",
                        "Restore backup", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
                State.ReplaceAll(config, BackupKind.BeforeRestore);
                Window.Rebuild();
            });
            list.Children.Add(Ui.Row(when, restore, $"{kind} · {b.Size / 1024.0:0.0} KB"));
        }

        var backups = Ui.Card("Automatic backups",
            Ui.Note("Glideball saves a snapshot of your settings once a day (only when something changed), and before every import or restore. " +
                    "It keeps every backup from the last two weeks, then one per month for a year. The newest is always kept."),
            Ui.Switch("Back up automatically", State.Prefs.AutoBackups, on => State.EditPreferences(p => p.AutoBackups = on)),
            Ui.Buttons(
                Ui.Button("Back up now", () =>
                {
                    State.Backups.Checkpoint(State.Config, BackupKind.Manual);
                    Window.Rebuild();
                }),
                Ui.Button("Open backups folder", () =>
                {
                    Directory.CreateDirectory(State.Backups.Folder);
                    Process.Start(new ProcessStartInfo("explorer.exe", $"\"{State.Backups.Folder}\"") { UseShellExecute = true });
                })),
            new Border { Height = 10 },
            list);

        if (State.Backups.LastError is string error)
            backups = Ui.Card("Automatic backups", Ui.Note("The last backup failed: " + error), backups);

        return Ui.Page("Backup", "Your settings, safe and portable.", transfer, backups);
    }
}
