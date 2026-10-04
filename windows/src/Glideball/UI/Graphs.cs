using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Glideball.UI;

/// <summary>A live line graph with a soft gradient fill (ball speed, ring speed).</summary>
internal sealed class LiveGraph : FrameworkElement
{
    private readonly double[] values;
    private int head;
    private readonly Color color;
    private readonly string unit;

    public LiveGraph(Color color, string unit, int samples = 120)
    {
        values = new double[samples];
        this.color = color;
        this.unit = unit;
        Height = 110;
    }

    public void Push(double v)
    {
        values[head] = v;
        head = (head + 1) % values.Length;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        double max = 1;
        foreach (var v in values) max = Math.Max(max, v);
        max *= 1.15;

        var grid = new Pen(new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)), 1);
        for (var i = 1; i < 4; i++) dc.DrawLine(grid, new Point(0, h * i / 4), new Point(w, h * i / 4));

        var line = new StreamGeometry();
        var fill = new StreamGeometry();
        using (var l = line.Open())
        using (var f = fill.Open())
        {
            f.BeginFigure(new Point(0, h), true, true);
            for (var i = 0; i < values.Length; i++)
            {
                var v = values[(head + i) % values.Length];
                var p = new Point(w * i / (values.Length - 1), h - h * v / max);
                if (i == 0) l.BeginFigure(p, false, false); else l.LineTo(p, true, true);
                f.LineTo(p, false, true);
            }
            f.LineTo(new Point(w, h), false, true);
        }
        line.Freeze();
        fill.Freeze();
        var gradient = new LinearGradientBrush(Color.FromArgb(0x66, color.R, color.G, color.B), Color.FromArgb(0x00, color.R, color.G, color.B), 90);
        dc.DrawGeometry(gradient, null, fill);
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(color), 2) { LineJoin = PenLineJoin.Round }, line);

        var latest = values[(head + values.Length - 1) % values.Length];
        var text = new FormattedText(latest.ToString("0.0", CultureInfo.CurrentCulture) + " " + unit, CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, new SolidColorBrush(Color.FromRgb(0xA3, 0xAC, 0xBC)),
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        dc.DrawText(text, new Point(w - text.Width - 4, 2));
    }
}

/// <summary>A static curve y = f(x) with an optional marker, e.g. the pointer response or Flywheel push.</summary>
internal sealed class CurveGraph : FrameworkElement
{
    private Func<double, double> f = x => x;
    private double xMax = 1;
    private double? marker;
    private string xLabel = "";
    private string yLabel = "";

    public CurveGraph()
    {
        Height = 150;
    }

    public void Set(Func<double, double> function, double xMaximum, string xAxis, string yAxis, double? markerX = null)
    {
        f = function;
        xMax = xMaximum;
        xLabel = xAxis;
        yLabel = yAxis;
        marker = markerX;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight - 16;
        if (w <= 0 || h <= 0) return;
        const int n = 80;
        double yMax = 1e-9;
        for (var i = 0; i <= n; i++) yMax = Math.Max(yMax, f(xMax * i / n));
        yMax *= 1.1;

        var axis = new Pen(new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)), 1);
        dc.DrawLine(axis, new Point(0, h), new Point(w, h));

        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            for (var i = 0; i <= n; i++)
            {
                var x = xMax * i / n;
                var p = new Point(w * i / n, h - h * f(x) / yMax);
                if (i == 0) g.BeginFigure(p, false, false); else g.LineTo(p, true, true);
            }
        }
        geometry.Freeze();
        var accent = new LinearGradientBrush(Color.FromRgb(0x7A, 0xA7, 0xFF), Color.FromRgb(0xA8, 0x8B, 0xFF), 0);
        dc.DrawGeometry(null, new Pen(accent, 2.5) { LineJoin = PenLineJoin.Round }, geometry);

        if (marker is double mx && mx >= 0 && mx <= xMax)
        {
            var p = new Point(w * mx / xMax, h - h * f(mx) / yMax);
            dc.DrawEllipse(Brushes.White, null, p, 4.5, 4.5);
        }

        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var sub = new SolidColorBrush(Color.FromRgb(0x6B, 0x73, 0x85));
        var xl = new FormattedText(xLabel, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, sub, dpi);
        dc.DrawText(xl, new Point(w - xl.Width, h + 2));
        var yl = new FormattedText(yLabel, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, sub, dpi);
        dc.DrawText(yl, new Point(0, 0));
    }
}
