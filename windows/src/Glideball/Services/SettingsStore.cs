using System;
using System.IO;
using System.Text.Json;
using Glideball.Core.Backup;
using Glideball.Core.Scrolling;
using Glideball.Core.Settings;

namespace Glideball;

/// <summary>
/// Settings that belong to this PC and never travel in a settings file
/// (like the Mac's per-Mac Beta program switch).
/// </summary>
internal sealed class Preferences
{
    public bool BetaProgram { get; set; }
    /// <summary>Experimental: scale the trackball's motion alone (see README).</summary>
    public bool PerDeviceSpeed { get; set; }
    public double WheelUnitsPerPoint { get; set; } = WheelConverter.DefaultUnitsPerPoint;
    public bool AutoBackups { get; set; } = true;
    public bool WelcomeShown { get; set; }
}

/// <summary>
/// %APPDATA%\Glideball\settings.glide-settings (the Mac's GlideSettingsFile
/// format), preferences.json, and Backups\.
/// </summary>
internal sealed class SettingsStore
{
    public static readonly string Folder =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Glideball");

    public string SettingsPath => Path.Combine(Folder, "settings." + SettingsFile.Extension);
    public string PreferencesPath => Path.Combine(Folder, "preferences.json");
    public string BackupFolder => Path.Combine(Folder, "Backups");

    public GlideConfig Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return GlideConfig.WindowsDefaults();
            return SettingsFile.Parse(File.ReadAllText(SettingsPath)).ValidatedConfig();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SettingsFileException)
        {
            // Keep the unreadable file for inspection and start fresh rather than fail.
            DiagLog.Write("settings unreadable: " + e.Message);
            try
            {
                File.Copy(SettingsPath, Path.Combine(Folder, $"settings.unreadable-{DateTime.Now:yyyyMMdd-HHmmss}.{SettingsFile.Extension}"), true);
            }
            catch (Exception copy) when (copy is IOException or UnauthorizedAccessException) { }
            return GlideConfig.WindowsDefaults();
        }
    }

    public void Save(GlideConfig config)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var json = SettingsFile.Create(config, Environment.MachineName, DateTimeOffset.Now).ToJson();
            var tmp = SettingsPath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, SettingsPath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            DiagLog.Write("save failed: " + e.Message);
        }
    }

    public Preferences LoadPreferences()
    {
        try
        {
            if (File.Exists(PreferencesPath))
                return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(PreferencesPath)) ?? new Preferences();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            DiagLog.Write("preferences unreadable: " + e.Message);
        }
        return new Preferences();
    }

    public void SavePreferences(Preferences p)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(PreferencesPath, JsonSerializer.Serialize(p, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            DiagLog.Write("preferences save failed: " + e.Message);
        }
    }

    public BackupStore CreateBackups() => new(BackupFolder, null, Environment.MachineName);
}
