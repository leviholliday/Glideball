using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Glideball.Core.Keys;
using Glideball.Core.Settings;

namespace Glideball.UI;

/// <summary>A small dialog that records one keyboard shortcut.</summary>
internal sealed class ShortcutRecorder : Window
{
    public KeyShortcut? Result { get; private set; }
    private readonly TextBlock display;
    private readonly bool requireModifier;

    private ShortcutRecorder(string prompt, bool requireModifier)
    {
        this.requireModifier = requireModifier;
        Title = "Record shortcut";
        Width = 420;
        Height = 230;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Ui.Brush("WindowFallback");
        Foreground = Ui.Brush("Text");
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        ShowInTaskbar = false;

        display = new TextBlock
        {
            Text = "Press keys…",
            FontSize = 24,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 18, 0, 18),
        };
        var cancel = Ui.Button("Cancel", Close);
        var stack = new StackPanel { Margin = new Thickness(22) };
        stack.Children.Add(Ui.Note(prompt));
        stack.Children.Add(display);
        stack.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel } });
        Content = stack;
        PreviewKeyDown += OnKey;
        SourceInitialized += (_, _) => MainWindow.ApplyGlass(this);
    }

    /// <summary>Shows the recorder; null if cancelled.</summary>
    public static KeyShortcut? Record(Window owner, string prompt, bool requireModifier = false)
    {
        var r = new ShortcutRecorder(prompt, requireModifier) { Owner = owner };
        r.ShowDialog();
        return r.Result;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None)
        {
            Close();
            return;
        }
        var mods = WinModifiers.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= WinModifiers.Ctrl;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= WinModifiers.Alt;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= WinModifiers.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows) || Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin))
            mods |= WinModifiers.Win;
        var vk = (ushort)KeyInterop.VirtualKeyFromKey(key);
        var shortcut = KeyMap.FromWindows(vk, mods);
        if (shortcut == null)
        {
            display.Text = new WinChord(mods, 0).Display + (mods == WinModifiers.None ? "Press keys…" : "+…");
            return;
        }
        if (requireModifier && (mods & (WinModifiers.Ctrl | WinModifiers.Alt | WinModifiers.Win)) == 0)
        {
            display.Text = "Include Ctrl, Alt or Win";
            return;
        }
        Result = shortcut;
        Close();
    }
}
