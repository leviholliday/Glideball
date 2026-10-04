using System;

namespace Glideball.Core.Scrolling;

/// <summary>
/// Turns the scroller's points into Windows wheel deltas. 120 is one classic
/// notch (3 lines; Chromium scrolls 100 px per 120). Modern apps honour any
/// delta, so the page moves smoothly; apps that only understand whole notches
/// add the deltas up and scroll once they reach 120, so the distance is the same.
///
/// Signs: the scroller's + is "scroll up" on the vertical axis, which is also
/// Windows' + WHEEL; on the horizontal axis the Mac's + means "scroll left"
/// while Windows' + HWHEEL means "scroll right", so it flips.
/// </summary>
public sealed class WheelConverter
{
    public const double DefaultUnitsPerPoint = 1.2;

    public double UnitsPerPoint { get; set; } = DefaultUnitsPerPoint;

    private double remV, remH;

    /// <summary>Vertical delta for <paramref name="points"/> (+ = up). 0 when there's nothing whole to send yet.</summary>
    public int Vertical(double points)
    {
        var f = points * UnitsPerPoint + remV;
        var i = (int)Math.Truncate(f);
        remV = f - i;
        return i;
    }

    /// <summary>HWHEEL delta for <paramref name="points"/> in Mac sign (+ = left).</summary>
    public int Horizontal(double points)
    {
        var f = -points * UnitsPerPoint + remH;
        var i = (int)Math.Truncate(f);
        remH = f - i;
        return i;
    }

    public void Reset() => remV = remH = 0;
}
