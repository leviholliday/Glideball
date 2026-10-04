using System;

namespace Glideball.Core.Pointer;

/// <summary>
/// Pointer speed for the trackball alone (Windows' own pointer speed is global).
///
/// While "per-device speed" is on, Glideball takes over the trackball's motion:
/// the hook swallows the trackball's moves and Glideball moves the cursor itself
/// from the trackball's raw counts, scaled by <see cref="Curve"/>. Any other
/// device moving hands control straight back to Windows, so other mice are
/// never scaled. See windows/README.md for the failure modes.
/// </summary>
public sealed class PointerRouter
{
    /// <summary>After another device moves, the trackball waits this long before taking over again.</summary>
    public double OtherQuietTime { get; set; } = 0.1;

    public bool Enabled { get; set; }
    public bool TakingOver => Enabled && takeover;

    private bool takeover;
    private double lastOther = double.NegativeInfinity;
    private double remX, remY;

    /// <summary>
    /// Pixels per count for a report of <paramref name="counts"/> counts at
    /// <paramref name="trackingSpeed"/> (the Mac's slider value; 4 is the default).
    /// Linear at 1/4 px per count per unit of speed for slow, careful moves, and
    /// up to 2.5× that for fast spins, eased with a smoothstep so it never lurches.
    /// </summary>
    public static double Curve(double counts, double trackingSpeed)
    {
        var baseGain = Math.Max(trackingSpeed, 0.1) / 4.0;
        var u = Math.Min(Math.Max((Math.Abs(counts) - 1) / 11.0, 0), 1);
        var boost = 1 + 1.5 * u * u * (3 - 2 * u);
        return baseGain * boost;
    }

    /// <summary>
    /// The trackball reported a move. Returns the whole pixels to move the cursor
    /// by, or null to let Windows move it (not taking over).
    /// </summary>
    public (int dx, int dy)? TrackballMove(int dx, int dy, double now, double trackingSpeed)
    {
        if (!Enabled)
        {
            takeover = false;
            return null;
        }
        if (!takeover)
        {
            if (now - lastOther < OtherQuietTime) return null;
            // This report already moved the cursor natively (or will): take over from the next one.
            takeover = true;
            remX = remY = 0;
            return null;
        }
        var counts = Math.Sqrt((double)dx * dx + (double)dy * dy);
        var g = Curve(counts, trackingSpeed);
        var fx = dx * g + remX;
        var fy = dy * g + remY;
        var ix = (int)Math.Truncate(fx);
        var iy = (int)Math.Truncate(fy);
        remX = fx - ix;
        remY = fy - iy;
        return (ix, iy);
    }

    /// <summary>Another device moved: Windows owns the cursor again.</summary>
    public void OtherMove(double now)
    {
        lastOther = now;
        takeover = false;
    }

    /// <summary>Should the hook swallow a (non-injected) move it can't attribute?</summary>
    public bool SwallowUnattributedMove => TakingOver;

    public void Reset()
    {
        takeover = false;
        remX = remY = 0;
    }
}
