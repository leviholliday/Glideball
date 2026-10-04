using System.Windows;
using Glideball.Core.Scrolling;
using Glideball.Core.Settings;

namespace Glideball.UI;

internal sealed class ScrollingPage : PageBase
{
    private readonly CurveGraph curve = new();

    public ScrollingPage(AppState state, MainWindow window) : base(state, window) { }

    public override UIElement Build()
    {
        var c = State.Config;
        var mode = Ui.Combo(new (string, ScrollMode)[]
        {
            ("Flywheel (recommended)", ScrollMode.Flywheel),
            ("Follow", ScrollMode.Follow),
            ("Native (Windows' own)", ScrollMode.Native),
        }, c.ScrollMode, m =>
        {
            State.Edit(x => x.ScrollMode = m);
            Window.Rebuild();
        });

        var modeCard = Ui.Card("Scroll ring", Ui.Row("Mode", mode), Ui.Note(c.ScrollMode switch
        {
            ScrollMode.Flywheel => "Each tick pushes the page and friction slows it: gentle turns barely coast, hard spins fly. " +
                                   "Modelled on measurements of Kensington's own driver (82 ms friction), at your display's refresh rate.",
            ScrollMode.Follow => "The page tracks the ring exactly and stops when you stop. A real flick throws it, and turning back catches it.",
            _ => "Windows scrolls the ring itself, by your wheel setting (Settings › Bluetooth & devices › Mouse).",
        }, 4));

        UIElement tuning;
        if (c.ScrollMode == ScrollMode.Flywheel)
        {
            UpdateFlyCurve();
            tuning = Ui.Card("Flywheel",
                Ui.Slider("Slow-turn distance", 1, 20, c.FlyDistance, v => Ui.Num(v, 0) + " pt", v => { State.Edit(x => x.FlyDistance = v); UpdateFlyCurve(); }, null, 1),
                Ui.Slider("Spin power", 0, 1, c.FlyAcceleration, Ui.Percent, v => { State.Edit(x => x.FlyAcceleration = v); UpdateFlyCurve(); }),
                Ui.Slider("Glide", 0, 1, c.FlyGlide, v => Ui.Num(SmoothScroller.FlyTau(v) * 1000, 0) + " ms", v => State.Edit(x => x.FlyGlide = v)),
                Ui.Buttons(Ui.Button("Kensington feel", () =>
                {
                    var d = new GlideConfig();
                    State.Edit(x => { x.FlyDistance = d.FlyDistance; x.FlyAcceleration = d.FlyAcceleration; x.FlyGlide = d.FlyGlide; });
                    Window.Rebuild();
                })),
                curve);
        }
        else if (c.ScrollMode == ScrollMode.Follow)
        {
            tuning = Ui.Card("Follow",
                Ui.Slider("Distance per tick", 2, 40, c.ScrollDistance, v => Ui.Num(v, 0) + " pt", v => State.Edit(x => x.ScrollDistance = v), null, 1),
                Ui.Slider("Softness", 0, 1, c.ScrollSmoothness, v => Ui.Num(SmoothScroller.TimeConstant(v) * 1000, 0) + " ms", v => State.Edit(x => x.ScrollSmoothness = v)),
                Ui.Slider("Spin acceleration", 0, 1, c.ScrollAcceleration, Ui.Percent, v => State.Edit(x => x.ScrollAcceleration = v)),
                Ui.Switch("Throw to coast", c.ThrowEnabled, on => State.Edit(x => x.ThrowEnabled = on)),
                Ui.Slider("Throw length", 0, 1, c.ThrowAmount, Ui.Percent, v => State.Edit(x => x.ThrowAmount = v)));
        }
        else
        {
            tuning = Ui.Card("Native",
                Ui.Note("Glideball leaves the ring's scrolling to Windows. Reverse direction below still applies."));
        }

        var common = Ui.Card("Everywhere",
            Ui.Switch("Smooth scrolling", c.SmoothScrolling, on => State.Edit(x => x.SmoothScrolling = on),
                "Off: plain steps, no glide."),
            Ui.Switch("Reverse direction", c.ReverseScroll, on => State.Edit(x => x.ReverseScroll = on)),
            Ui.Switch("Shift + ring scrolls sideways", c.ShiftScrollsHorizontally, on => State.Edit(x => x.ShiftScrollsHorizontally = on)),
            Ui.Note("Ctrl, Alt or Win + scroll keep their usual meaning (zoom, for example).", 2),
            Ui.Slider("Scroll with ball speed", 0.25, 4, c.BallScrollSpeed, v => Ui.Num(v, 2) + "×", v => State.Edit(x => x.BallScrollSpeed = v)),
            Ui.Slider("Wheel scale (this PC)", 0.5, 3, State.Prefs.WheelUnitsPerPoint, v => Ui.Num(v, 2),
                v => State.EditPreferences(p => p.WheelUnitsPerPoint = v),
                "Wheel units per point. 1.2 matches Chrome and Edge at 100% (120 units ≈ 100 px)."));

        return Ui.Page("Scrolling", "Choose how the scroll ring feels.", modeCard, tuning, common);
    }

    private void UpdateFlyCurve()
    {
        var c = State.Config;
        curve.Set(rate => SmoothScroller.FlyTickDistance(rate, c.FlyDistance, c.FlyAcceleration), 60,
            "spin rate (ticks/s)", "points per tick");
    }
}
