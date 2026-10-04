using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Glideball.Core.Settings;

namespace Glideball.UI;

internal sealed class ButtonsPage : PageBase
{
    private readonly TextBlock learnStatus = Ui.Note("", 6);
    private Button? learnButton;

    public ButtonsPage(AppState state, MainWindow window) : base(state, window) { }

    /// <summary>Which buttons this page edits; null edits the main setup. AppsPage reuses the editors.</summary>
    public static readonly int[] EditableButtons = { 1, 2, 3, 4 };

    public override UIElement Build()
    {
        var c = State.Config;
        learnButton = Ui.Button("Quick assign…", StartLearning, accent: true);
        var quick = Ui.Card("Quick assign",
            Ui.Note("Press a trackball button — or two or three together for a combo — then press the keyboard shortcut it should send."),
            Ui.Buttons(learnButton),
            learnStatus);

        var rows = new List<UIElement>
        {
            Ui.Row(Presets.ButtonName(0), Ui.Label("Left click (always)", 13.5), "Locked so a mapping can never leave you without a click."),
        };
        foreach (var b in EditableButtons)
            rows.Add(Ui.Row(Presets.ButtonName(b), ActionPicker(Window, c.ActionFor(b), a => State.Edit(x => SetButton(x.Buttons, b, a)))));
        var buttons = Ui.Card("Buttons", rows.ToArray());

        return Ui.Page("Buttons", "Clicks, shortcuts and modes for each button, and combos of two or three.",
            quick, buttons, CombosCard(State, Window, () => State.Config.Chords, (x, list) => x.Chords = list));
    }

    internal static void SetButton(Dictionary<int, ButtonAction> map, int button, ButtonAction action)
    {
        if (action.Kind == ActionKind.System) map.Remove(button);
        else map[button] = action;
    }

    // MARK: Action picker

    private sealed record Choice(string Title, ButtonAction? Action, bool RecordShortcut = false, bool Hold = false);

    /// <summary>A menu of presets, plus "Keyboard shortcut…" and "Hold keyboard shortcut…" that record one.</summary>
    internal static ComboBox ActionPicker(Window owner, ButtonAction current, Action<ButtonAction> changed, double width = 280)
    {
        var choices = Presets.All.Select(p => new Choice(p.Title, p.Action)).ToList();
        if (!Presets.All.Any(p => p.Action == current))
            choices.Insert(0, new Choice(Presets.Title(current), current));
        choices.Add(new Choice("Keyboard shortcut…", null, RecordShortcut: true));
        choices.Add(new Choice("Hold keyboard shortcut…", null, RecordShortcut: true, Hold: true));

        var combo = new ComboBox { Width = width };
        foreach (var ch in choices) combo.Items.Add(new ComboBoxItem { Content = ch.Title, Tag = ch });
        var selected = choices.FindIndex(ch => ch.Action == current);
        combo.SelectedIndex = selected;
        var last = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is not ComboBoxItem { Tag: Choice ch }) return;
            if (ch.RecordShortcut)
            {
                var s = ShortcutRecorder.Record(owner, ch.Hold
                    ? "Press the shortcut to hold down while the button is held."
                    : "Press the shortcut this button should send.");
                if (s == null)
                {
                    combo.SelectedIndex = last;   // cancelled: back to what it was
                    return;
                }
                var action = ch.Hold ? ButtonAction.Hold(s) : ButtonAction.Press(s);
                var item = new ComboBoxItem { Content = Presets.Title(action), Tag = new Choice(Presets.Title(action), action) };
                combo.Items.Insert(0, item);
                last = 0;
                combo.SelectedIndex = 0;
                changed(action);
                return;
            }
            last = combo.SelectedIndex;
            if (ch.Action != null) changed(ch.Action);
        };
        return combo;
    }

    // MARK: Combos

    internal static Border CombosCard(AppState state, MainWindow window, Func<List<Chord>> read, Action<GlideConfig, List<Chord>> write)
    {
        var list = new StackPanel();
        void Render()
        {
            list.Children.Clear();
            var chords = read();
            if (chords.Count == 0) list.Children.Add(Ui.Note("No combos yet."));
            foreach (var chord in chords)
            {
                var id = chord.Id;
                var names = string.Join(" + ", chord.Buttons.OrderBy(b => b).Select(Presets.ButtonName));
                var remove = Ui.Button("Remove", () =>
                {
                    state.Edit(x => write(x, read().Where(ch => ch.Id != id).Select(ch => ch.Clone()).ToList()));
                    Render();
                });
                list.Children.Add(Ui.Row(names, new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Children =
                    {
                        new TextBlock { Text = Presets.Title(chord.Action), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), Foreground = Ui.Brush("SubText") },
                        remove,
                    },
                }));
            }
        }
        Render();

        // Adding a combo: pick 2–3 buttons and an action.
        var picks = Enumerable.Range(0, 5).Select(b => new CheckBox
        {
            Content = Presets.ButtonName(b),
            Style = Ui.Res<Style>("Switch"),
            Margin = new Thickness(0, 2, 18, 2),
        }).ToList();
        var pickPanel = new WrapPanel();
        foreach (var p in picks) pickPanel.Children.Add(p);
        ButtonAction pending = ButtonAction.Press(KeyShortcut.NewTab);
        var picker = ActionPicker(window, pending, a => pending = a);
        var error = Ui.Note("", 4);
        var add = Ui.Button("Add combo", () =>
        {
            var chosen = picks.Select((p, i) => (p, i)).Where(t => t.p.IsChecked == true).Select(t => t.i).ToList();
            if (chosen.Count is < 2 or > 3)
            {
                error.Text = "Choose two or three buttons.";
                return;
            }
            if (read().Any(ch => ch.Buttons.OrderBy(b => b).SequenceEqual(chosen)))
            {
                error.Text = "Those buttons already have a combo.";
                return;
            }
            error.Text = "";
            var chord = new Chord(chosen, pending);
            state.Edit(x => write(x, read().Select(ch => ch.Clone()).Append(chord).ToList()));
            foreach (var p in picks) p.IsChecked = false;
            Render();
        }, accent: true);

        return Ui.Card("Combos",
            Ui.Note("Hold buttons together for a separate action. A button that belongs to a combo waits 70 ms for its partners " +
                    "(up to 160 ms while a three-button combo is still possible); buttons in no combo respond instantly."),
            new Border { Height = 8 },
            list,
            new Border { Height = 12 },
            Ui.Label("New combo", 13.5),
            pickPanel,
            Ui.Row("Action", picker),
            Ui.Buttons(add),
            error);
    }

    // MARK: Quick assign

    private void StartLearning()
    {
        learnStatus.Text = "Press a trackball button, or two or three together…";
        if (learnButton != null) learnButton.IsEnabled = false;
        State.Learned += OnLearned;
        State.Engine.Learn(true);
    }

    private void OnLearned(IReadOnlyCollection<int> pressed)
    {
        State.Learned -= OnLearned;
        if (learnButton != null) learnButton.IsEnabled = true;
        var buttons = pressed.OrderBy(b => b).ToList();
        if (buttons.Count == 1 && buttons[0] == 0)
        {
            learnStatus.Text = "The bottom-left button always stays a left click.";
            return;
        }
        if (buttons.Count > 3)
        {
            learnStatus.Text = "Combos use two or three buttons.";
            return;
        }
        var what = string.Join(" + ", buttons.Select(Presets.ButtonName));
        var s = ShortcutRecorder.Record(Window, $"Press the shortcut for {what}.");
        if (s == null)
        {
            learnStatus.Text = "";
            return;
        }
        var action = ButtonAction.Press(s);
        if (buttons.Count == 1)
        {
            State.Edit(x => SetButton(x.Buttons, buttons[0], action));
        }
        else
        {
            State.Edit(x =>
            {
                x.Chords.RemoveAll(ch => ch.Buttons.OrderBy(b => b).SequenceEqual(buttons));
                x.Chords.Add(new Chord(buttons, action));
            });
        }
        learnStatus.Text = $"{what} now sends {Presets.Title(action)}.";
        Window.Rebuild();
    }

    public override void Leave()
    {
        State.Learned -= OnLearned;
        State.Engine.Learn(false);
    }
}
