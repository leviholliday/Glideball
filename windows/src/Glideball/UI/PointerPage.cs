using System.Windows;
using Glideball.Core.Pointer;

namespace Glideball.UI;

internal sealed class PointerPage : PageBase
{
    private readonly CurveGraph curve = new();

    public PointerPage(AppState state, MainWindow window) : base(state, window) { }

    public override UIElement Build()
    {
        var c = State.Config;
        UpdateCurve(c.TrackingSpeed);
        var perDevice = State.Prefs.PerDeviceSpeed;

        var speedCard = Ui.Card("Trackball speed",
            Ui.Switch("Per-device speed (experimental)", perDevice, on =>
            {
                State.EditPreferences(p => p.PerDeviceSpeed = on);
                Window.Rebuild();
            }, "Glideball moves the cursor itself for the trackball only. Other mice keep Windows' speed."),
            Ui.Note(perDevice
                ? "On: the trackball's motion is scaled by Glideball alone, past Windows' limit. Your other mice and touchpad are untouched. " +
                  "If anything feels off, turn this off: Windows takes over again instantly."
                : "Off: the trackball uses Windows' own pointer speed (Settings › Bluetooth & devices › Mouse), which is shared by every mouse. " +
                  "Turn this on to give the trackball its own speed.", 4),
            Ui.Slider("Tracking speed", 0.5, 40, c.TrackingSpeed, v => Ui.Num(v), v =>
            {
                State.Edit(x => x.TrackingSpeed = v);
                UpdateCurve(v);
            }, "4 is the Mac app's default"),
            Ui.Buttons(
                Preset("Precise", 2),
                Preset("Default", 4),
                Preset("Fast", 8),
                Preset("Turbo", 16)),
            curve);
        speedCard.IsEnabled = true;

        var precisionCard = Ui.Card("Precision",
            Ui.Note("Assign Precision (hold or toggle) to a button or a shortcut to slow the pointer for fine work."),
            Ui.Slider("Precision speed", 0.25, 8, c.PrecisionSpeed, v => Ui.Num(v, 2), v => State.Edit(x => x.PrecisionSpeed = v)),
            Ui.Note(perDevice ? "" : "With per-device speed off, Precision lowers Windows' pointer speed while it's on and restores it afterwards.", 2));

        return Ui.Page("Pointer", "How fast the cursor follows the ball.", speedCard, precisionCard);
    }

    private UIElement Preset(string name, double speed) => Ui.Button(name, () =>
    {
        State.Edit(x => x.TrackingSpeed = speed);
        Window.Rebuild();
    });

    private void UpdateCurve(double speed) =>
        curve.Set(counts => counts * PointerRouter.Curve(counts, speed), 30, "counts per report", "pixels", 6);
}
