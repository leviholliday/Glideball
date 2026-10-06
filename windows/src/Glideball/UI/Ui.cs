using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Glideball.UI;

/// <summary>Small builders so pages read like the layout they produce.</summary>
internal static class Ui
{
    public static T Res<T>(string key) where T : class => (T)Application.Current.Resources[key];
    public static Brush Brush(string key) => Res<Brush>(key);

    public static StackPanel Page(string title, string subtitle, params UIElement[] children)
    {
        var p = new StackPanel { MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left };
        p.Children.Add(new TextBlock { Text = title, Style = Res<Style>("PageTitle") });
        p.Children.Add(new TextBlock { Text = subtitle, Style = Res<Style>("Note"), FontSize = 13.5, Margin = new Thickness(0, 0, 0, 18) });
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    public static Border Card(string? title, params UIElement[] children)
    {
        var stack = new StackPanel();
        if (title != null) stack.Children.Add(new TextBlock { Text = title, Style = Res<Style>("CardTitle") });
        foreach (var c in children) stack.Children.Add(c);
        return new Border { Style = Res<Style>("Card"), Child = stack };
    }

    public static TextBlock Note(string text, double top = 0) =>
        new() { Text = text, Style = Res<Style>("Note"), Margin = new Thickness(0, top, 0, 0) };

    public static TextBlock Label(string text, double size = 14) => new() { Text = text, FontSize = size, VerticalAlignment = VerticalAlignment.Center };

    /// <summary>"Label ……… control" on one line.</summary>
    public static Grid Row(string label, UIElement control, string? note = null)
    {
        var g = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Label(label));
        if (note != null) left.Children.Add(Note(note, 2));
        g.Children.Add(left);
        Grid.SetColumn(control, 1);
        if (control is FrameworkElement fe) { fe.VerticalAlignment = VerticalAlignment.Center; fe.Margin = new Thickness(16, 0, 0, 0); }
        g.Children.Add(control);
        return g;
    }

    public static CheckBox Switch(string text, bool isOn, Action<bool> changed, string? tip = null)
    {
        var c = new CheckBox { Content = text, IsChecked = isOn, Style = Res<Style>("Switch") };
        if (tip != null) c.ToolTip = tip;
        c.Click += (_, _) => changed(c.IsChecked == true);
        return c;
    }

    public static Button Button(string text, Action click, bool accent = false)
    {
        var b = new Button { Content = text };
        if (accent) b.Style = Res<Style>("AccentButton");
        b.Click += (_, _) => click();
        return b;
    }

    public static WrapPanel Buttons(params UIElement[] buttons)
    {
        var w = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var b in buttons) w.Children.Add(b);
        return w;
    }

    /// <summary>A labelled slider with its value shown, reporting changes as they happen.</summary>
    public static FrameworkElement Slider(string label, double min, double max, double value, Func<double, string> format,
        Action<double> changed, string? note = null, double step = 0, string? lowLabel = null, string? highLabel = null)
    {
        var g = new Grid { Margin = new Thickness(0, 6, 0, 8) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Label(label));
        if (note != null) left.Children.Add(Note(note, 2));
        g.Children.Add(left);
        var s = new Slider { Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max), VerticalAlignment = VerticalAlignment.Center };
        if (step > 0) { s.TickFrequency = step; s.IsSnapToTickEnabled = true; }
        FrameworkElement track = s;
        if (lowLabel != null || highLabel != null)
        {
            // The ends of the range, named under the slider ("Short" … "Far").
            var ends = new Grid();
            ends.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            ends.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var lo = Note(lowLabel ?? "");
            var hi = Note(highLabel ?? "");
            hi.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(hi, 1);
            ends.Children.Add(lo);
            ends.Children.Add(hi);
            var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            stack.Children.Add(s);
            stack.Children.Add(ends);
            track = stack;
        }
        Grid.SetColumn(track, 1);
        g.Children.Add(track);
        var v = new TextBlock { Text = format(value), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brush("SubText") };
        Grid.SetColumn(v, 2);
        g.Children.Add(v);
        s.ValueChanged += (_, e) =>
        {
            v.Text = format(e.NewValue);
            changed(e.NewValue);
        };
        return g;
    }

    public static ComboBox Combo<T>(IEnumerable<(string title, T value)> items, T selected, Action<T> changed, double width = 260)
    {
        var c = new ComboBox { Width = width };
        var index = 0;
        foreach (var (title, value) in items)
        {
            c.Items.Add(new ComboBoxItem { Content = title, Tag = value });
            if (EqualityComparer<T>.Default.Equals(value, selected)) c.SelectedIndex = index;
            index++;
        }
        c.SelectionChanged += (_, _) =>
        {
            if (c.SelectedItem is ComboBoxItem item && item.Tag is T value) changed(value);
        };
        return c;
    }

    public static string Num(double v, int digits = 1) => v.ToString("F" + digits, CultureInfo.CurrentCulture);
    public static string Percent(double v) => ((int)(v * 100)).ToString(CultureInfo.CurrentCulture) + "%";
}
