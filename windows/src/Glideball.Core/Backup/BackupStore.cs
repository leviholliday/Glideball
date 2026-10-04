using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using Glideball.Core.Settings;

namespace Glideball.Core.Backup;

public enum BackupKind { Daily, BeforeImport, BeforeRestore, Manual }

public sealed record BackupEntry(string Path, DateTime Date, BackupKind Kind, long Size)
{
    public string FileName => System.IO.Path.GetFileName(Path);
}

/// <summary>
/// Automatic, tiny, self-pruning backups — a port of the Mac's <c>BackupStore</c>.
/// Each backup is an ordinary <c>.glide-settings</c> file named
/// "2026-10-04 09.12.30[ before import].glide-settings" (local time), so files
/// move freely between a Mac's and a PC's backup folders.
///
/// When: once a day (the first time Glideball runs that day, before any change),
/// plus a checkpoint before an import or a restore, and on Back Up Now. Nothing is
/// written if the settings match the newest backup.
///
/// How long: every backup from the last 14 days; then the newest of each month;
/// nothing older than a year — except the newest backup, which always stays.
/// </summary>
public sealed class BackupStore
{
    public const int DailyWindowDays = 14;
    public const int KeepDays = 365;
    public const int CheckpointsPerDay = 5;

    private readonly string folder;
    private readonly Func<DateTime> now;
    private readonly string? machineName;
    private DateTime? coveredDay;
    private (string path, string json)? newest;

    public bool Enabled { get; set; } = true;
    public string? LastError { get; private set; }
    public IReadOnlyList<BackupEntry> Backups { get; private set; } = Array.Empty<BackupEntry>();
    public string Folder => folder;

    /// <param name="now">Local time (tests pass a fixed clock).</param>
    public BackupStore(string folder, Func<DateTime>? now = null, string? machineName = null)
    {
        this.folder = folder;
        this.now = now ?? (() => DateTime.Now);
        this.machineName = machineName;
        Backups = Scan();
    }

    public void Reload() => Backups = Scan();

    /// <summary>Call with the settings as they were before a change, so the first edit of a day can't sneak into that day's backup.</summary>
    public void WillChange(GlideConfig old) => SnapshotIfDue(old);

    /// <summary>Today's daily backup, unless today is already covered.</summary>
    public void SnapshotIfDue(GlideConfig config)
    {
        if (!Enabled) return;
        var today = now().Date;
        if (coveredDay == today) return;
        if (Backups.Any(b => b.Kind == BackupKind.Daily && b.Date.Date == today) || !Write(config, BackupKind.Daily))
            Prune();   // a new day ages everything, even when nothing is written
        if (LastError == null) coveredDay = today;
    }

    /// <summary>A checkpoint before something replaces every setting, or on request. Written even with automatic backups off.</summary>
    public bool Checkpoint(GlideConfig config, BackupKind kind) => Write(config, kind, force: kind == BackupKind.Manual);

    private bool Write(GlideConfig config, BackupKind kind, bool force = false)
    {
        var c = config.Clone();
        c.Enabled = true;   // the pause switch isn't worth restoring
        var configJson = SettingsFile.WriteConfig(c).ToJsonString();
        if (!force && Backups.Count > 0)
        {
            var newestBackup = Backups[0];
            var saved = newest?.path == newestBackup.Path ? newest?.json : LoadConfigJson(newestBackup);
            if (saved == configJson) return false;
        }
        try
        {
            Directory.CreateDirectory(folder);
            var stamp = now();
            var path = System.IO.Path.Combine(folder, FileName(stamp, kind));
            if (File.Exists(path)) path = System.IO.Path.Combine(folder, FileName(stamp.AddSeconds(1), kind));
            var file = SettingsFile.Create(c, machineName, new DateTimeOffset(stamp));
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, file.ToJson(indented: false));
            File.Move(tmp, path, overwrite: true);
            newest = (path, configJson);
            LastError = null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            LastError = e.Message;
            return false;
        }
        Prune();
        return true;
    }

    private static string? LoadConfigJson(BackupEntry b)
    {
        var c = Load(b);
        return c == null ? null : SettingsFile.WriteConfig(c).ToJsonString();
    }

    public static GlideConfig? Load(BackupEntry b)
    {
        try
        {
            var c = SettingsFile.Parse(File.ReadAllText(b.Path)).ValidatedConfig();
            c.Enabled = true;
            return c;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SettingsFileException)
        {
            return null;
        }
    }

    private List<BackupEntry> Scan()
    {
        if (!Directory.Exists(folder)) return new List<BackupEntry>();
        var list = new List<BackupEntry>();
        foreach (var path in Directory.EnumerateFiles(folder, "*." + SettingsFile.Extension))
        {
            var name = System.IO.Path.GetFileNameWithoutExtension(path);
            var parsed = Parse(name);
            if (parsed == null) continue;
            var (date, kind) = parsed.Value;
            long size = 0;
            try { size = new FileInfo(path).Length; } catch (IOException) { }
            list.Add(new BackupEntry(path, date, kind, size));
        }
        return list.OrderByDescending(b => b.Date).ToList();
    }

    /// <summary>Applies the retention rules and refreshes <see cref="Backups"/>.</summary>
    public void Prune()
    {
        foreach (var b in Expired(Scan(), now()))
        {
            try { File.Delete(b.Path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        Backups = Scan();
    }

    /// <summary>The backups the retention rules no longer keep. Pure, for testing.</summary>
    public static List<BackupEntry> Expired(IEnumerable<BackupEntry> backups, DateTime now)
    {
        var sorted = backups.OrderByDescending(b => b.Date).ToList();
        if (sorted.Count == 0) return new List<BackupEntry>();
        var today = now.Date;
        var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { sorted[0].Path };
        var checkpointsByDay = new Dictionary<DateTime, int>();
        var monthsSeen = new HashSet<(int, int)>();

        foreach (var b in sorted)   // newest first, so "first seen" = newest of its group
        {
            var day = b.Date.Date;
            var age = Math.Max((int)Math.Round((today - day).TotalDays), 0);
            if (age < DailyWindowDays)
            {
                if (b.Kind == BackupKind.Daily)
                {
                    keep.Add(b.Path);
                }
                else
                {
                    checkpointsByDay.TryGetValue(day, out var n);
                    if (n < CheckpointsPerDay) keep.Add(b.Path);
                    checkpointsByDay[day] = n + 1;
                }
            }
            else if (age <= KeepDays)
            {
                if (monthsSeen.Add((b.Date.Year, b.Date.Month))) keep.Add(b.Path);
            }
        }
        return sorted.Where(b => !keep.Contains(b.Path)).ToList();
    }

    // MARK: Names

    private const string StampFormat = "yyyy-MM-dd HH.mm.ss";

    public static string KindName(BackupKind k) => k switch
    {
        BackupKind.BeforeImport => "before import",
        BackupKind.BeforeRestore => "before restore",
        BackupKind.Manual => "saved by you",
        _ => "",
    };

    public static string FileName(DateTime date, BackupKind kind)
    {
        var stamp = date.ToString(StampFormat, CultureInfo.InvariantCulture);
        var name = kind == BackupKind.Daily ? stamp : stamp + " " + KindName(kind);
        return name + "." + SettingsFile.Extension;
    }

    public static (DateTime, BackupKind)? Parse(string name)
    {
        if (name.Length < 19) return null;
        if (!DateTime.TryParseExact(name.Substring(0, 19), StampFormat, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal, out var date)) return null;
        var rest = name.Substring(19).Trim();
        if (rest.Length == 0) return (date, BackupKind.Daily);
        foreach (var k in new[] { BackupKind.BeforeImport, BackupKind.BeforeRestore, BackupKind.Manual })
            if (rest == KindName(k)) return (date, k);
        return null;
    }
}
