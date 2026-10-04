using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Glideball.Core.Settings;
using Xunit;

namespace Glideball.Core.Tests;

public class SettingsFileTests
{
    private static string MacSample() =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Data", "mac-sample.glide-settings"));

    [Fact]
    public void ReadsAFileExportedByTheMac()
    {
        var file = SettingsFile.Parse(MacSample());
        var c = file.ValidatedConfig();
        Assert.Equal(1, file.Version);
        Assert.Equal("Levi's MacBook Pro", file.ExportedFrom);
        Assert.NotNull(file.ExportedAt);
        Assert.Equal(6.5, c.TrackingSpeed);
        Assert.Equal(ScrollMode.Flywheel, c.ScrollMode);
        Assert.Equal(0.35, c.FlyGlide);
        Assert.Equal(ButtonAction.Click(0, MacFlags.Control), c.Buttons[1]);
        Assert.Equal(ButtonAction.Press(KeyShortcut.PreviousSpace), c.Buttons[2]);
        Assert.Equal(ButtonAction.Hold(KeyShortcut.WisprFlow), c.Buttons[4]);
        Assert.Equal(ButtonAction.PrecisionHold, c.Buttons[5]);
        Assert.Equal(2, c.Chords.Count);
        Assert.Equal(new[] { 0, 2, 3 }, c.Chords[0].Buttons);
        Assert.Equal("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", c.Chords[1].Id);
        Assert.Equal(ButtonAction.DragLock, c.Chords[1].Action);
        var safari = Assert.Single(c.AppProfiles);
        Assert.Equal("com.apple.Safari", safari.BundleId);
        Assert.Equal(3.0, safari.TrackingSpeed);
        Assert.Null(safari.Scroll);
        Assert.Null(safari.Chords);
        Assert.Equal(ButtonAction.Back, safari.Buttons![2]);
        Assert.Equal(GlobalShortcuts.DefaultPause, c.GlobalShortcuts.Pause);
        Assert.Equal(new KeyShortcut(35, MacFlags.Control | MacFlags.Option | MacFlags.Command, "P"), c.GlobalShortcuts.Precision);
        Assert.Null(c.GlobalShortcuts.BallScroll);
        Assert.Null(c.Extra);
    }

    [Fact]
    public void RoundTripIsLossless()
    {
        var original = JsonNode.Parse(MacSample())!;
        var written = SettingsFile.Parse(MacSample()).ToJson();
        // Same JSON tree as the Mac wrote (key order and whitespace aside).
        Assert.True(JsonNode.DeepEquals(original, JsonNode.Parse(written)), written);
    }

    [Fact]
    public void WritesTheMacsShapes()
    {
        var c = GlideConfig.WindowsDefaults();
        c.Buttons[2] = ButtonAction.Press(KeyShortcut.Copy);
        c.Buttons[3] = ButtonAction.Click(1, MacFlags.Shift);
        c.Buttons[4] = ButtonAction.Back;
        c.GlobalShortcuts.Pause = null;
        var json = SettingsFile.Create(c, "PC", new DateTimeOffset(2026, 10, 4, 9, 12, 30, 250, TimeSpan.FromHours(2))).ToJson();
        var o = JsonNode.Parse(json)!.AsObject();
        Assert.Equal("2026-10-04T07:12:30Z", (string?)o["exportedAt"]);
        var buttons = o["config"]!["buttons"]!.AsObject();
        Assert.Equal(8, (int)buttons["2"]!["shortcut"]!["_0"]!["keyCode"]!);
        Assert.Equal((ulong)MacFlags.Command, (ulong)buttons["2"]!["shortcut"]!["_0"]!["modifiers"]!);
        Assert.Equal(1, (int)buttons["3"]!["modifiedClick"]!["button"]!);
        Assert.Empty(buttons["4"]!["back"]!.AsObject());
        // A cleared shortcut is written as null so it stays cleared.
        var gs = o["config"]!["globalShortcuts"]!.AsObject();
        Assert.True(gs.ContainsKey("pause"));
        Assert.Null(gs["pause"]);
        Assert.Equal("flywheel", (string?)o["config"]!["scrollMode"]);
        // Integral doubles are written like Swift writes them ("4", not "4.0").
        Assert.Matches("\"trackingSpeed\": 4\\s", json);
    }

    [Fact]
    public void ClearedShortcutStaysClearedAndMissingMeansDefault()
    {
        var c = GlideConfig.WindowsDefaults();
        c.GlobalShortcuts.Pause = null;
        var back = SettingsFile.Parse(SettingsFile.Create(c, null, DateTimeOffset.UtcNow).ToJson()).Config;
        Assert.Null(back.GlobalShortcuts.Pause);

        var missing = SettingsFile.Parse("{\"version\":1,\"config\":{\"globalShortcuts\":{}}}").Config;
        Assert.Equal(GlobalShortcuts.DefaultPause, missing.GlobalShortcuts.Pause);
    }

    [Fact]
    public void MissingKeysFallBackToDefaults()
    {
        var c = SettingsFile.Parse("{\"version\":1,\"config\":{\"trackingSpeed\":9}}").ValidatedConfig();
        Assert.Equal(9.0, c.TrackingSpeed);
        Assert.Equal(ScrollMode.Flywheel, c.ScrollMode);
        Assert.Equal(4.0, c.FlyDistance);
        Assert.True(c.Enabled);
        // The Mac's defaults, so a file means the same thing on both platforms.
        Assert.Equal(ButtonAction.Press(KeyShortcut.PreviousSpace), c.Buttons[2]);
    }

    [Fact]
    public void UnknownFieldsAndActionsAreTolerated()
    {
        const string json = """
        {
          "version": 1,
          "futureTopLevel": true,
          "config": {
            "trackingSpeed": 5,
            "hapticsLevel": 3,
            "newThing": { "a": [1, 2] },
            "buttons": {
              "2": { "teleport": { "where": "moon" } },
              "3": { "back": {} }
            },
            "chords": [
              { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "buttons": [1, 2], "action": { "summonCat": {} } },
              { "id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "buttons": [2, 3], "action": { "dragLock": {} } }
            ],
            "appProfiles": [ { "bundleID": "chrome.exe", "futureProfileKey": 1 } ]
          }
        }
        """;
        var c = SettingsFile.Parse(json).ValidatedConfig();
        Assert.Equal(5, c.TrackingSpeed);
        Assert.False(c.Buttons.ContainsKey(2));          // unknown action skipped, not fatal
        Assert.Equal(ButtonAction.Back, c.Buttons[3]);
        Assert.Single(c.Chords);                          // unknown combo skipped
        Assert.Equal("chrome.exe", c.AppProfiles[0].Name); // name defaults to the id
        // Unknown keys survive a round trip.
        var again = JsonNode.Parse(SettingsFile.Create(c, null, DateTimeOffset.UtcNow).ToJson())!;
        Assert.Equal(3, (int)again["config"]!["hapticsLevel"]!);
        Assert.Equal(2, (int)again["config"]!["newThing"]!["a"]![1]!);
        Assert.Equal(1, (int)again["config"]!["appProfiles"]![0]!["futureProfileKey"]!);
    }

    [Fact]
    public void RejectsOtherVersionsAndJunk()
    {
        Assert.Throws<SettingsFileException>(() => SettingsFile.Parse("{\"version\":2,\"config\":{}}").ValidatedConfig());
        Assert.Throws<SettingsFileException>(() => SettingsFile.Parse("not json"));
        Assert.Throws<SettingsFileException>(() => SettingsFile.Parse("[1,2]"));
    }

    [Fact]
    public void ProfilesResolveByProcessAndKeepThePrimaryButton()
    {
        var c = GlideConfig.WindowsDefaults();
        c.Buttons[0] = ButtonAction.SystemDefault;
        c.AppProfiles.Add(new AppProfile
        {
            BundleId = "Code.exe",
            Name = "VS Code",
            TrackingSpeed = 8,
            Buttons = new() { [0] = ButtonAction.Disabled, [2] = ButtonAction.Forward },
        });
        var r = c.ResolvedFor("code.exe");
        Assert.Equal(8.0, r.TrackingSpeed);
        Assert.Equal(ButtonAction.Forward, r.Buttons[2]);
        Assert.Equal(ButtonAction.SystemDefault, r.Buttons[0]);
        Assert.Same(c, c.ResolvedFor("notepad.exe"));
    }

    [Fact]
    public void CloneIsDeep()
    {
        var c = new GlideConfig();
        var d = c.Clone();
        d.Buttons[1] = ButtonAction.Disabled;
        d.Chords[0].Buttons.Add(4);
        Assert.False(c.Buttons.ContainsKey(1));
        Assert.Equal(3, c.Chords[0].Buttons.Count);
    }
}
