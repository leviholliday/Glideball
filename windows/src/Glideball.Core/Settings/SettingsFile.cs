using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Glideball.Core.Settings;

public sealed class SettingsFileException : Exception
{
    public SettingsFileException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// The portable <c>.glide-settings</c> file, byte-compatible with the Mac's
/// <c>GlideSettingsFile</c> (Swift <c>JSONEncoder</c>, ISO-8601 dates):
/// <code>{ "version": 1, "config": { … }, "exportedAt": "2026-10-04T09:12:30Z", "exportedFrom": "PC" }</code>
/// Reading follows the Mac's rules: missing keys fall back to defaults, button
/// actions or combos this version doesn't understand are skipped (not fatal),
/// and a cleared global shortcut is an explicit <c>null</c>. Keys this
/// version doesn't know are kept and written back, so nothing is lost on a round trip.
/// </summary>
public sealed class SettingsFile
{
    public const int CurrentVersion = 1;
    public const string Extension = "glide-settings";

    public int Version { get; init; } = CurrentVersion;
    public GlideConfig Config { get; init; } = new();
    public DateTimeOffset? ExportedAt { get; init; }
    public string? ExportedFrom { get; init; }

    public static SettingsFile Create(GlideConfig config, string? exportedFrom, DateTimeOffset now) =>
        new() { Config = config, ExportedAt = now, ExportedFrom = exportedFrom };

    /// <summary>The config, or an error if the file is from an unsupported version.</summary>
    public GlideConfig ValidatedConfig()
    {
        if (Version != CurrentVersion)
            throw new SettingsFileException($"This settings file uses unsupported version {Version}.");
        return Config;
    }

    // MARK: Reading

    public static SettingsFile Parse(string json)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true });
        }
        catch (JsonException e)
        {
            throw new SettingsFileException("This isn't a Glideball settings file (it isn't valid JSON).", e);
        }
        if (root is not JsonObject o) throw new SettingsFileException("This isn't a Glideball settings file.");
        if (!TryInt(o["version"], out var version)) throw new SettingsFileException("This isn't a Glideball settings file (no version).");
        if (o["config"] is not JsonObject configNode) throw new SettingsFileException("This isn't a Glideball settings file (no settings).");
        return new SettingsFile
        {
            Version = version,
            Config = ReadConfig(configNode),
            ExportedAt = ReadDate(o["exportedAt"]),
            ExportedFrom = Str(o["exportedFrom"]),
        };
    }

    private static readonly string[] ConfigKeys =
    {
        "enabled", "trackingSpeed", "precisionSpeed", "scrollMode", "nativeScrollSpeed", "flyDistance",
        "flyAcceleration", "flyGlide", "flyReach", "smoothScrolling", "scrollDistance", "scrollSmoothness",
        "scrollAcceleration", "throwEnabled", "throwAmount", "reverseScroll", "shiftScrollsHorizontally",
        "ballScrollSpeed", "buttons", "chords", "appProfiles", "globalShortcuts",
    };

    public static GlideConfig ReadConfig(JsonObject c)
    {
        var d = new GlideConfig();
        var cfg = new GlideConfig
        {
            Enabled = Bool(c["enabled"]) ?? d.Enabled,
            TrackingSpeed = Num(c["trackingSpeed"]) ?? d.TrackingSpeed,
            PrecisionSpeed = Num(c["precisionSpeed"]) ?? d.PrecisionSpeed,
            BallScrollSpeed = Num(c["ballScrollSpeed"]) ?? d.BallScrollSpeed,
            Buttons = ReadActions(c["buttons"]) ?? d.Buttons,
            Chords = ReadChords(c["chords"]) ?? d.Chords,
            AppProfiles = (c["appProfiles"] as JsonArray)?.Select(ReadProfile).Where(p => p != null).Select(p => p!).ToList() ?? d.AppProfiles,
            GlobalShortcuts = c["globalShortcuts"] is JsonObject g ? ReadGlobalShortcuts(g) : d.GlobalShortcuts,
            Extra = Leftovers(c, ConfigKeys),
        };
        cfg.Scroll = ReadScroll(c);
        return cfg;
    }

    private static ScrollSettings ReadScroll(JsonObject c)
    {
        var d = new ScrollSettings();
        return new ScrollSettings
        {
            ScrollMode = ReadMode(c["scrollMode"]) ?? d.ScrollMode,
            NativeScrollSpeed = Num(c["nativeScrollSpeed"]) ?? d.NativeScrollSpeed,
            FlyDistance = Num(c["flyDistance"]) ?? d.FlyDistance,
            FlyAcceleration = Num(c["flyAcceleration"]) ?? d.FlyAcceleration,
            FlyGlide = Num(c["flyGlide"]) ?? d.FlyGlide,
            FlyReach = Num(c["flyReach"]) ?? d.FlyReach,
            SmoothScrolling = Bool(c["smoothScrolling"]) ?? d.SmoothScrolling,
            ScrollDistance = Num(c["scrollDistance"]) ?? d.ScrollDistance,
            ScrollSmoothness = Num(c["scrollSmoothness"]) ?? d.ScrollSmoothness,
            ScrollAcceleration = Num(c["scrollAcceleration"]) ?? d.ScrollAcceleration,
            ThrowEnabled = Bool(c["throwEnabled"]) ?? d.ThrowEnabled,
            ThrowAmount = Num(c["throwAmount"]) ?? d.ThrowAmount,
            ReverseScroll = Bool(c["reverseScroll"]) ?? d.ReverseScroll,
            ShiftScrollsHorizontally = Bool(c["shiftScrollsHorizontally"]) ?? d.ShiftScrollsHorizontally,
        };
    }

    private static readonly string[] ProfileKeys = { "bundleID", "name", "trackingSpeed", "scroll", "buttons", "chords" };

    private static AppProfile? ReadProfile(JsonNode? n)
    {
        if (n is not JsonObject o || Str(o["bundleID"]) is not string id) return null;
        return new AppProfile
        {
            BundleId = id,
            Name = Str(o["name"]) ?? id,
            TrackingSpeed = Num(o["trackingSpeed"]),
            Scroll = o["scroll"] is JsonObject s ? ReadScroll(s) : null,
            Buttons = ReadActions(o["buttons"]),
            Chords = ReadChords(o["chords"]),
            Extra = Leftovers(o, ProfileKeys),
        };
    }

    private static GlobalShortcuts ReadGlobalShortcuts(JsonObject g)
    {
        var d = new GlobalShortcuts();
        // Missing (or unreadable) means the default; an explicit null means cleared.
        KeyShortcut? Read(string key, KeyShortcut? fallback)
        {
            if (!g.TryGetPropertyValue(key, out var node)) return fallback;
            if (node == null) return null;
            return ReadShortcut(node) ?? fallback;
        }
        return new GlobalShortcuts
        {
            Pause = Read("pause", d.Pause),
            Precision = Read("precision", d.Precision),
            BallScroll = Read("ballScroll", d.BallScroll),
            DragLock = Read("dragLock", d.DragLock),
        };
    }

    private static Dictionary<int, ButtonAction>? ReadActions(JsonNode? n)
    {
        if (n is not JsonObject o) return null;
        var map = new Dictionary<int, ButtonAction>();
        foreach (var (key, value) in o)
        {
            if (!int.TryParse(key, NumberStyles.Integer, CultureInfo.InvariantCulture, out var button)) continue;
            if (ReadAction(value) is ButtonAction a) map[button] = a;   // unknown actions are skipped
        }
        return map;
    }

    private static List<Chord>? ReadChords(JsonNode? n)
    {
        if (n is not JsonArray arr) return null;
        var list = new List<Chord>();
        foreach (var item in arr)
        {
            if (item is not JsonObject o) continue;
            if (ReadAction(o["action"]) is not ButtonAction action) continue;
            if (o["buttons"] is not JsonArray b) continue;
            var buttons = new List<int>();
            var ok = true;
            foreach (var x in b)
            {
                if (TryInt(x, out var v)) buttons.Add(v); else ok = false;
            }
            if (!ok) continue;
            var id = Str(o["id"]);
            list.Add(new Chord
            {
                Id = id != null && Guid.TryParse(id, out _) ? id : Guid.NewGuid().ToString().ToUpperInvariant(),
                Buttons = buttons,
                Action = action,
            });
        }
        return list;
    }

    /// <summary>Swift's synthesized enum coding: <c>{"case": {payload}}</c>; unnamed payloads use <c>"_0"</c>.</summary>
    public static ButtonAction? ReadAction(JsonNode? n)
    {
        if (n is not JsonObject o || o.Count != 1) return null;
        var (name, payload) = o.First();
        var p = payload as JsonObject;
        switch (name)
        {
            case "system": return ButtonAction.SystemDefault;
            case "leftClick": return ButtonAction.LeftClick;
            case "rightClick": return ButtonAction.RightClick;
            case "middleClick": return ButtonAction.MiddleClick;
            case "back": return ButtonAction.Back;
            case "forward": return ButtonAction.Forward;
            case "disabled": return ButtonAction.Disabled;
            case "precisionHold": return ButtonAction.PrecisionHold;
            case "precisionToggle": return ButtonAction.PrecisionToggle;
            case "ballScrollHold": return ButtonAction.BallScrollHold;
            case "dragLock": return ButtonAction.DragLock;
            case "shortcut":
            case "holdShortcut":
                if (ReadShortcut(p?["_0"]) is not KeyShortcut s) return null;
                return name == "shortcut" ? ButtonAction.Press(s) : ButtonAction.Hold(s);
            case "modifiedClick":
                if (p == null || !TryInt(p["button"], out var button) || !TryULong(p["modifiers"], out var mods)) return null;
                return ButtonAction.Click(button, mods);
            default:
                return null;
        }
    }

    private static KeyShortcut? ReadShortcut(JsonNode? n)
    {
        if (n is not JsonObject o) return null;
        if (!TryInt(o["keyCode"], out var code) || code < 0 || code > ushort.MaxValue) return null;
        if (!TryULong(o["modifiers"], out var mods)) return null;
        if (Str(o["keyName"]) is not string name) return null;
        return new KeyShortcut((ushort)code, mods, name);
    }

    private static ScrollMode? ReadMode(JsonNode? n) => Str(n) switch
    {
        "native" => ScrollMode.Native,
        "flywheel" => ScrollMode.Flywheel,
        "follow" => ScrollMode.Follow,
        _ => null,
    };

    private static JsonObject? Leftovers(JsonObject o, string[] known)
    {
        JsonObject? extra = null;
        foreach (var (key, value) in o)
        {
            if (Array.IndexOf(known, key) >= 0) continue;
            extra ??= new JsonObject();
            extra[key] = value?.DeepClone();
        }
        return extra;
    }

    // MARK: Writing

    /// <summary>Pretty, sorted JSON like the Mac's export.</summary>
    public string ToJson(bool indented = true)
    {
        var root = new JsonObject
        {
            ["config"] = WriteConfig(Config),
            ["exportedAt"] = ExportedAt is DateTimeOffset at ? JsonValue.Create(FormatDate(at)) : null,
            ["exportedFrom"] = ExportedFrom is string from ? JsonValue.Create(from) : null,
            ["version"] = Version,
        };
        // Swift omits nil optionals in this struct; do the same.
        if (ExportedAt == null) root.Remove("exportedAt");
        if (ExportedFrom == null) root.Remove("exportedFrom");
        return Sorted(root)!.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = indented,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
    }

    public static JsonObject WriteConfig(GlideConfig c)
    {
        var o = new JsonObject
        {
            ["enabled"] = c.Enabled,
            ["trackingSpeed"] = c.TrackingSpeed,
            ["precisionSpeed"] = c.PrecisionSpeed,
            ["ballScrollSpeed"] = c.BallScrollSpeed,
            ["buttons"] = WriteActions(c.Buttons),
            ["chords"] = WriteChords(c.Chords),
            ["appProfiles"] = new JsonArray(c.AppProfiles.Select(p => (JsonNode)WriteProfile(p)).ToArray()),
            ["globalShortcuts"] = new JsonObject
            {
                ["pause"] = WriteShortcut(c.GlobalShortcuts.Pause),
                ["precision"] = WriteShortcut(c.GlobalShortcuts.Precision),
                ["ballScroll"] = WriteShortcut(c.GlobalShortcuts.BallScroll),
                ["dragLock"] = WriteShortcut(c.GlobalShortcuts.DragLock),
            },
        };
        WriteScroll(o, c.Scroll);
        AddExtra(o, c.Extra);
        return o;
    }

    private static void WriteScroll(JsonObject o, ScrollSettings s)
    {
        o["scrollMode"] = s.ScrollMode switch
        {
            ScrollMode.Native => "native",
            ScrollMode.Follow => "follow",
            _ => "flywheel",
        };
        o["nativeScrollSpeed"] = s.NativeScrollSpeed;
        o["flyDistance"] = s.FlyDistance;
        o["flyAcceleration"] = s.FlyAcceleration;
        o["flyGlide"] = s.FlyGlide;
        o["flyReach"] = s.FlyReach;
        o["smoothScrolling"] = s.SmoothScrolling;
        o["scrollDistance"] = s.ScrollDistance;
        o["scrollSmoothness"] = s.ScrollSmoothness;
        o["scrollAcceleration"] = s.ScrollAcceleration;
        o["throwEnabled"] = s.ThrowEnabled;
        o["throwAmount"] = s.ThrowAmount;
        o["reverseScroll"] = s.ReverseScroll;
        o["shiftScrollsHorizontally"] = s.ShiftScrollsHorizontally;
    }

    private static JsonObject WriteProfile(AppProfile p)
    {
        var o = new JsonObject { ["bundleID"] = p.BundleId, ["name"] = p.Name };
        // Swift's synthesized encoder omits nil optionals.
        if (p.TrackingSpeed is double speed) o["trackingSpeed"] = speed;
        if (p.Scroll != null)
        {
            var s = new JsonObject();
            WriteScroll(s, p.Scroll);
            o["scroll"] = s;
        }
        if (p.Buttons != null) o["buttons"] = WriteActions(p.Buttons);
        if (p.Chords != null) o["chords"] = WriteChords(p.Chords);
        AddExtra(o, p.Extra);
        return o;
    }

    private static JsonObject WriteActions(Dictionary<int, ButtonAction> map)
    {
        var o = new JsonObject();
        foreach (var (button, action) in map.OrderBy(kv => kv.Key))
            o[button.ToString(CultureInfo.InvariantCulture)] = WriteAction(action);
        return o;
    }

    private static JsonArray WriteChords(List<Chord> chords) => new(chords.Select(ch => (JsonNode)new JsonObject
    {
        ["action"] = WriteAction(ch.Action),
        ["buttons"] = new JsonArray(ch.Buttons.Select(b => (JsonNode)JsonValue.Create(b)).ToArray()),
        ["id"] = ch.Id,
    }).ToArray());

    public static JsonObject WriteAction(ButtonAction a)
    {
        JsonObject payload = new();
        switch (a.Kind)
        {
            case ActionKind.Shortcut:
            case ActionKind.HoldShortcut:
                payload["_0"] = WriteShortcut(a.Shortcut);
                break;
            case ActionKind.ModifiedClick:
                payload["button"] = a.Button;
                payload["modifiers"] = a.Modifiers;
                break;
        }
        return new JsonObject { [CaseName(a.Kind)] = payload };
    }

    public static string CaseName(ActionKind k) => k switch
    {
        ActionKind.System => "system",
        ActionKind.LeftClick => "leftClick",
        ActionKind.RightClick => "rightClick",
        ActionKind.MiddleClick => "middleClick",
        ActionKind.Back => "back",
        ActionKind.Forward => "forward",
        ActionKind.Shortcut => "shortcut",
        ActionKind.HoldShortcut => "holdShortcut",
        ActionKind.ModifiedClick => "modifiedClick",
        ActionKind.Disabled => "disabled",
        ActionKind.PrecisionHold => "precisionHold",
        ActionKind.PrecisionToggle => "precisionToggle",
        ActionKind.BallScrollHold => "ballScrollHold",
        ActionKind.DragLock => "dragLock",
        _ => "system",
    };

    private static JsonNode? WriteShortcut(KeyShortcut? s) => s == null ? null : new JsonObject
    {
        ["keyCode"] = (int)s.KeyCode,
        ["keyName"] = s.KeyName,
        ["modifiers"] = s.Modifiers,
    };

    private static void AddExtra(JsonObject o, JsonObject? extra)
    {
        if (extra == null) return;
        foreach (var (key, value) in extra)
            if (!o.ContainsKey(key)) o[key] = value?.DeepClone();
    }

    /// <summary>Recursively sorts object keys (Swift's <c>.sortedKeys</c>, ordinal like Foundation).</summary>
    private static JsonNode? Sorted(JsonNode? n)
    {
        switch (n)
        {
            case JsonObject o:
                var sorted = new JsonObject();
                foreach (var key in o.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToList())
                {
                    var child = o[key];
                    o.Remove(key);   // a node can only have one parent
                    sorted[key] = Sorted(child);
                }
                return sorted;
            case JsonArray a:
                var items = a.ToList();
                a.Clear();
                return new JsonArray(items.Select(Sorted).ToArray());
            default:
                return n;
        }
    }

    // MARK: Values

    /// <summary>Swift's <c>.iso8601</c>: whole seconds, UTC, "Z" (fractions would make the Mac reject the file).</summary>
    public static string FormatDate(DateTimeOffset d) =>
        d.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);

    private static DateTimeOffset? ReadDate(JsonNode? n) =>
        Str(n) is string s && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;

    private static string? Str(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static bool? Bool(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    private static double? Num(JsonNode? n)
    {
        if (n is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<long>(out var l)) return l;
        return null;
    }

    private static bool TryInt(JsonNode? n, out int value)
    {
        value = 0;
        if (Num(n) is not double d || d != Math.Floor(d) || d < int.MinValue || d > int.MaxValue) return false;
        value = (int)d;
        return true;
    }

    private static bool TryULong(JsonNode? n, out ulong value)
    {
        value = 0;
        if (n is not JsonValue v) return false;
        if (v.TryGetValue<ulong>(out value)) return true;
        if (Num(n) is double d && d >= 0 && d == Math.Floor(d) && d <= 1e18) { value = (ulong)d; return true; }
        return false;
    }
}
