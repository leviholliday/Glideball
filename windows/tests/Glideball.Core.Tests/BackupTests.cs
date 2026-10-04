using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Glideball.Core.Backup;
using Glideball.Core.Settings;
using Xunit;

namespace Glideball.Core.Tests;

public class BackupTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "glideball-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static BackupEntry Entry(DateTime date, BackupKind kind = BackupKind.Daily) =>
        new(BackupStore.FileName(date, kind), date, kind, 1000);

    [Fact]
    public void KeepsEverythingFromTheLastTwoWeeks()
    {
        var now = new DateTime(2026, 10, 4, 12, 0, 0);
        var backups = Enumerable.Range(0, 14).Select(d => Entry(now.AddDays(-d))).ToList();
        Assert.Empty(BackupStore.Expired(backups, now));
    }

    [Fact]
    public void ThenTheNewestOfEachMonthForAYear()
    {
        var now = new DateTime(2026, 10, 4, 12, 0, 0);
        // A daily backup every day for two years.
        var backups = Enumerable.Range(0, 730).Select(d => Entry(now.AddDays(-d))).ToList();
        var expired = BackupStore.Expired(backups, now).Select(b => b.Path).ToHashSet();
        var kept = backups.Where(b => !expired.Contains(b.Path)).OrderByDescending(b => b.Date).ToList();

        // 14 dailies…
        Assert.All(kept.Take(14), b => Assert.True((now.Date - b.Date.Date).TotalDays < 14));
        var older = kept.Skip(14).ToList();
        // …then one per month, the newest of each, nothing past a year.
        Assert.Equal(older.Count, older.Select(b => (b.Date.Year, b.Date.Month)).Distinct().Count());
        Assert.All(older, b => Assert.True((now.Date - b.Date.Date).TotalDays <= 365));
        // September 2026 (still partly inside the 14-day window) keeps its newest day outside the window.
        Assert.Contains(older, b => b.Date.Date == new DateTime(2026, 9, 20));
        Assert.True(kept.Count is >= 25 and <= 28, $"kept {kept.Count}");
    }

    [Fact]
    public void TheNewestIsAlwaysKept()
    {
        var now = new DateTime(2026, 10, 4);
        var ancient = new List<BackupEntry> { Entry(new DateTime(2023, 1, 1)), Entry(new DateTime(2022, 6, 1)) };
        var expired = BackupStore.Expired(ancient, now);
        Assert.Single(expired);
        Assert.Equal(new DateTime(2022, 6, 1), expired[0].Date);
    }

    [Fact]
    public void AtMostFiveCheckpointsPerDay()
    {
        var now = new DateTime(2026, 10, 4, 20, 0, 0);
        var backups = Enumerable.Range(0, 8).Select(i => Entry(now.AddMinutes(-i), BackupKind.BeforeImport)).ToList();
        backups.Add(Entry(now.AddHours(-10)));   // the daily
        var expired = BackupStore.Expired(backups, now);
        Assert.Equal(3, expired.Count);
        Assert.All(expired, b => Assert.Equal(BackupKind.BeforeImport, b.Kind));
        Assert.DoesNotContain(expired, b => b.Kind == BackupKind.Daily);
    }

    [Fact]
    public void FileNamesMatchTheMac()
    {
        var d = new DateTime(2026, 10, 4, 9, 12, 30);
        Assert.Equal("2026-10-04 09.12.30.glide-settings", BackupStore.FileName(d, BackupKind.Daily));
        Assert.Equal("2026-10-04 09.12.30 before import.glide-settings", BackupStore.FileName(d, BackupKind.BeforeImport));
        Assert.Equal((d, BackupKind.BeforeRestore), BackupStore.Parse("2026-10-04 09.12.30 before restore"));
        Assert.Equal((d, BackupKind.Manual), BackupStore.Parse("2026-10-04 09.12.30 saved by you"));
        Assert.Null(BackupStore.Parse("settings"));
        Assert.Null(BackupStore.Parse("2026-10-04 09.12.30 something else"));
    }

    [Fact]
    public void DailySnapshotIsWrittenOncePerDayAndOnlyWhenChanged()
    {
        var now = new DateTime(2026, 10, 4, 9, 0, 0);
        var store = new BackupStore(folder, () => now, "PC");
        var c = GlideConfig.WindowsDefaults();
        store.SnapshotIfDue(c);
        Assert.Single(store.Backups);
        store.SnapshotIfDue(c);                 // same day: nothing
        Assert.Single(store.Backups);

        now = now.AddDays(1);
        store.SnapshotIfDue(c);                 // new day, unchanged settings: nothing
        Assert.Single(store.Backups);

        now = now.AddDays(1);
        c.TrackingSpeed = 7;
        store.SnapshotIfDue(c);                 // changed: a new daily
        Assert.Equal(2, store.Backups.Count);

        // Back Up Now always writes; the pause switch isn't part of a backup.
        c.Enabled = false;
        Assert.True(store.Checkpoint(c, BackupKind.Manual));
        Assert.Equal(3, store.Backups.Count);
        var restored = BackupStore.Load(store.Backups[0])!;
        Assert.True(restored.Enabled);
        Assert.Equal(7, restored.TrackingSpeed);
    }

    [Fact]
    public void BackupFilesAreValidSettingsFiles()
    {
        var store = new BackupStore(folder, () => new DateTime(2026, 10, 4, 9, 0, 0), "PC");
        store.Checkpoint(new GlideConfig(), BackupKind.BeforeImport);
        var file = SettingsFile.Parse(File.ReadAllText(store.Backups[0].Path));
        Assert.Equal(1, file.Version);
        Assert.Equal("PC", file.ExportedFrom);
    }
}
