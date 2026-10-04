using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Glideball.Core.Settings;

namespace Glideball.UI;

/// <summary>Per-app setups, keyed by process name ("chrome.exe"), used while that app is in front.</summary>
internal sealed class AppsPage : PageBase
{
    public AppsPage(AppState state, MainWindow window) : base(state, window) { }

    public override UIElement Build()
    {
        var c = State.Config;
        var cards = new List<UIElement> { AddCard() };
        foreach (var p in c.AppProfiles) cards.Add(ProfileCard(p));
        if (c.AppProfiles.Count == 0)
            cards.Add(Ui.Card(null, Ui.Note("No app setups yet. Every app uses your main setup.")));
        return Ui.Page("Apps", "Different pointer speed, scrolling or buttons while a particular app is in front.", cards.ToArray());
    }

    private Border AddCard()
    {
        var running = Process.GetProcesses()
            .Where(p => { try { return p.MainWindowHandle != IntPtr.Zero; } catch (InvalidOperationException) { return false; } })
            .Select(p => (exe: p.ProcessName + ".exe", title: SafeTitle(p)))
            .Where(t => !t.exe.Equals("Glideball.exe", StringComparison.OrdinalIgnoreCase))
            .GroupBy(t => t.exe.ToLowerInvariant()).Select(g => g.First())
            .Where(t => State.Config.ProfileFor(t.exe) == null)
            .OrderBy(t => t.exe, StringComparer.OrdinalIgnoreCase)
            .ToList();
        var items = running.Select(t => ($"{t.exe}  —  {t.title}", t.exe)).ToList();
        var chosen = items.Count > 0 ? items[0].Item2 : null;
        var combo = Ui.Combo<string?>(items.Select(i => (i.Item1, (string?)i.Item2)), chosen, v => chosen = v, 420);
        var add = Ui.Button("Add app", () =>
        {
            if (chosen == null) return;
            var name = chosen.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? chosen[..^4] : chosen;
            State.Edit(x => x.AppProfiles.Add(new AppProfile { BundleId = chosen, Name = name }));
            Window.Rebuild();
        }, accent: true);
        return Ui.Card("Add an app",
            Ui.Note("Pick an app that's running. Its setup starts as your main one; change only what should differ."),
            Ui.Row("Running apps", combo),
            Ui.Buttons(add));
    }

    private static string SafeTitle(Process p)
    {
        try { return p.MainWindowTitle; } catch (InvalidOperationException) { return ""; }
    }

    private Border ProfileCard(AppProfile p)
    {
        var id = p.BundleId;
        void EditProfile(Action<AppProfile> change) => State.Edit(x =>
        {
            var target = x.AppProfiles.FirstOrDefault(a => a.BundleId == id);
            if (target != null) change(target);
        });

        var speed = Ui.Slider("Pointer speed", 0.5, 40, p.TrackingSpeed ?? State.Config.TrackingSpeed, v => Ui.Num(v),
            v => EditProfile(a => a.TrackingSpeed = v));
        speed.IsEnabled = p.TrackingSpeed != null;
        var speedSwitch = Ui.Switch("Own pointer speed", p.TrackingSpeed != null, on =>
        {
            EditProfile(a => a.TrackingSpeed = on ? State.Config.TrackingSpeed : null);
            Window.Rebuild();
        });

        var scrollSwitch = Ui.Switch("Own scrolling", p.Scroll != null, on =>
        {
            EditProfile(a => a.Scroll = on ? State.Config.Scroll : null);
            Window.Rebuild();
        });
        UIElement scrollMode = new Border();
        if (p.Scroll != null)
        {
            scrollMode = Ui.Row("Scroll mode", Ui.Combo(new (string, ScrollMode)[]
            {
                ("Flywheel", ScrollMode.Flywheel),
                ("Follow", ScrollMode.Follow),
                ("Native", ScrollMode.Native),
            }, p.Scroll.ScrollMode, m => EditProfile(a => a.Scroll = (a.Scroll ?? State.Config.Scroll) with { ScrollMode = m })));
        }

        var buttonsSwitch = Ui.Switch("Own buttons", p.Buttons != null, on =>
        {
            EditProfile(a => a.Buttons = on ? new Dictionary<int, ButtonAction>(State.Config.Buttons) : null);
            Window.Rebuild();
        });
        var buttonRows = new StackPanel();
        if (p.Buttons != null)
        {
            foreach (var b in ButtonsPage.EditableButtons)
            {
                var current = p.Buttons.TryGetValue(b, out var a0) ? a0 : ButtonAction.SystemDefault;
                buttonRows.Children.Add(Ui.Row(Presets.ButtonName(b), ButtonsPage.ActionPicker(Window, current,
                    a => EditProfile(pr => ButtonsPage.SetButton(pr.Buttons ??= new Dictionary<int, ButtonAction>(), b, a)))));
            }
        }

        var remove = Ui.Button("Remove", () =>
        {
            State.Edit(x => x.AppProfiles.RemoveAll(a => a.BundleId == id));
            Window.Rebuild();
        });

        return Ui.Card(p.Name,
            Ui.Note(p.BundleId + (State.ForegroundProcess != null && p.AppliesTo(State.ForegroundProcess) ? " · in front now" : "")),
            new Border { Height = 6 },
            speedSwitch, speed,
            scrollSwitch, scrollMode,
            buttonsSwitch, buttonRows,
            Ui.Buttons(remove));
    }
}
