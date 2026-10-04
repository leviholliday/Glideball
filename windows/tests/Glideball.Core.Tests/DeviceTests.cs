using Glideball.Core.Devices;
using Glideball.Core.Keys;
using Glideball.Core.Pointer;
using Glideball.Core.Settings;
using Xunit;

namespace Glideball.Core.Tests;

public class DeviceTests
{
    [Theory]
    [InlineData(@"\\?\HID#VID_047D&PID_1020#7&2a8b1c&0&0000#{378de44c-56ef-11d1-bc8c-00a0c91405dd}", 0x047D, 0x1020)]
    [InlineData(@"\\?\HID#VID_047d&PID_1020&MI_00#7&1&0&0000#{378de44c-56ef-11d1-bc8c-00a0c91405dd}", 0x047D, 0x1020)]
    [InlineData(@"\\?\HID#{00001124-0000-1000-8000-00805f9b34fb}_VID&0002047d_PID&8019&Col01#8&1#{378de44c-56ef-11d1-bc8c-00a0c91405dd}", 0x047D, 0x8019)]
    [InlineData(@"\\?\HID#{00001812-0000-1000-8000-00805f9b34fb}_Dev_VID&02047d_PID&8018_REV&0001_c1a2b3#9&1#{378de44c-56ef-11d1-bc8c-00a0c91405dd}", 0x047D, 0x8018)]
    [InlineData(@"\\?\HID#VID_046D&PID_C52B&MI_02&Col01#8&1#{378de44c-56ef-11d1-bc8c-00a0c91405dd}", 0x046D, 0xC52B)]
    public void ParsesDevicePaths(string path, int vid, int pid)
    {
        var id = DeviceIdentity.FromDevicePath(path);
        Assert.Equal(vid, id.VendorId);
        Assert.Equal(pid, id.ProductId);
    }

    [Fact]
    public void OnlyKensingtonsAreSupportedAndOthersOnlyInBeta()
    {
        var expert = new DeviceIdentity(0x047D, 0x1020, null);
        var slimBlade = new DeviceIdentity(0x047D, 0x2041, "SlimBlade Trackball");
        var expertWireless = new DeviceIdentity(0x047D, 0x8018, "Expert Mouse Wireless Trackball");
        var logitech = new DeviceIdentity(0x046D, 0xC52B, "USB Receiver");
        var touchpad = DeviceIdentity.FromDevicePath(@"\\?\HID#SYNA7DB5&Col01#5&1#{378de44c-56ef-11d1-bc8c-00a0c91405dd}");

        Assert.True(expert.IsSupported(beta: false));
        Assert.Equal(DeviceKind.ExpertMouse, expertWireless.Kind);
        Assert.False(slimBlade.IsSupported(beta: false));
        Assert.True(slimBlade.IsSupported(beta: true));
        Assert.False(logitech.IsSupported(beta: true));
        Assert.False(touchpad.IsSupported(beta: true));
        Assert.Equal("Kensington SlimBlade Trackball", slimBlade.DisplayName);
        Assert.Equal("Kensington Expert Mouse", expert.DisplayName);
    }

    [Fact]
    public void KeyMapTranslatesPresetsAndModifiers()
    {
        Assert.Equal(new WinChord(WinModifiers.Ctrl, 'C'), KeyMap.ToWindows(KeyShortcut.Copy));
        Assert.Equal(new WinChord(WinModifiers.Ctrl | WinModifiers.Win, KeyMap.VK_LEFT), KeyMap.ToWindows(KeyShortcut.PreviousSpace));
        Assert.Equal(new WinChord(WinModifiers.Win, KeyMap.VK_TAB), KeyMap.ToWindows(KeyShortcut.MissionControl));
        Assert.Equal("Ctrl+Alt+Win+G", KeyMap.Display(GlobalShortcuts.DefaultPause));
        Assert.Equal("Ctrl+Win+Left", KeyMap.Display(KeyShortcut.PreviousSpace));
    }

    [Fact]
    public void ShortcutsRecordedOnWindowsRoundTripAndAreNeverMistakenForMacPresets()
    {
        // Win+Left (snap) must stay Win+Left, not become the Mac's "Previous Space".
        var winLeft = KeyMap.FromWindows(KeyMap.VK_LEFT, WinModifiers.Win)!;
        Assert.Equal(KeyShortcut.PreviousSpace.KeyCode, winLeft.KeyCode);
        Assert.Equal(KeyShortcut.PreviousSpace.Modifiers, winLeft.Modifiers);
        Assert.Equal(new WinChord(WinModifiers.Win, KeyMap.VK_LEFT), KeyMap.ToWindows(winLeft));

        var ctrlShiftT = KeyMap.FromWindows('T', WinModifiers.Ctrl | WinModifiers.Shift)!;
        Assert.Equal(17, ctrlShiftT.KeyCode);
        Assert.Equal(MacFlags.Command | MacFlags.Shift, ctrlShiftT.Modifiers);
        Assert.Equal(new WinChord(WinModifiers.Ctrl | WinModifiers.Shift, 'T'), KeyMap.ToWindows(ctrlShiftT));

        Assert.Null(KeyMap.FromWindows(KeyMap.VK_LSHIFT, WinModifiers.Shift));   // a lone modifier isn't a shortcut
    }

    [Fact]
    public void ClickModifiersFollowMeaning()
    {
        Assert.Equal(WinModifiers.Ctrl, KeyMap.ClickModifiersToWindows(MacFlags.Command));
        Assert.Equal(WinModifiers.Shift | WinModifiers.Alt, KeyMap.ClickModifiersToWindows(MacFlags.Shift | MacFlags.Option));
    }

    // MARK: Correlation

    [Fact]
    public void RawBeforeHookAttributesImmediately()
    {
        var c = new InputCorrelator();
        Assert.Empty(c.AddRaw(InputSignal.Down(1), Source.Trackball, 0.000));
        var released = c.AddHook(InputSignal.Down(1), true, 0.001, "hook", out _);
        Assert.Equal(Source.Trackball, Assert.Single(released).Source);
    }

    [Fact]
    public void HookBeforeRawIsHeldThenReleased()
    {
        var c = new InputCorrelator();
        Assert.Empty(c.AddHook(InputSignal.Down(1), true, 0.000, "hook", out _));
        Assert.Equal(1, c.HeldCount);
        var released = c.AddRaw(InputSignal.Down(1), Source.Trackball, 0.0005);
        Assert.Equal(Source.Trackball, Assert.Single(released).Source);
        Assert.Equal(0, c.HeldCount);
    }

    [Fact]
    public void TouchpadClickRightAfterTrackballUseIsNotTheTrackballs()
    {
        // The Mac bug: "last active device" would say trackball. Here only the
        // raw event for this very press counts.
        var c = new InputCorrelator();
        c.AddRaw(InputSignal.Down(0), Source.Trackball, 0.000);
        c.AddHook(InputSignal.Down(0), true, 0.001, "ball", out _);
        c.AddRaw(InputSignal.Up(0), Source.Trackball, 0.050);
        c.AddHook(InputSignal.Up(0), true, 0.051, "ball", out _);
        c.AddHook(InputSignal.Down(1), true, 0.100, "pad", out _);
        var released = c.AddRaw(InputSignal.Down(1), Source.Other, 0.1005);
        Assert.Equal(Source.Other, Assert.Single(released).Source);
    }

    [Fact]
    public void UnclaimedHookFailsOpenAfterTimeout()
    {
        var c = new InputCorrelator();
        c.AddHook(InputSignal.Down(2), true, 0.0, "hook", out _);
        Assert.Empty(c.Expire(0.03));
        var released = c.Expire(0.05);
        Assert.Equal(Source.Other, Assert.Single(released).Source);
    }

    [Fact]
    public void HeldEventsReleaseInOrder()
    {
        var c = new InputCorrelator();
        c.AddHook(InputSignal.Down(2), true, 0.0, "down", out _);
        // Its release arrives before the raw down: it must wait behind the press.
        Assert.Empty(c.AddHook(InputSignal.Up(2), false, 0.01, "up", out _));
        var released = c.AddRaw(InputSignal.Down(2), Source.Trackball, 0.011);
        Assert.Equal(new object?[] { "down", "up" }, released.ConvertAll(r => r.Event.Tag).ToArray());
        Assert.Equal(Source.Trackball, released[0].Source);
    }

    [Fact]
    public void StaleRawEventsAreForgotten()
    {
        var c = new InputCorrelator();
        c.AddRaw(InputSignal.Wheel(1), Source.Trackball, 0.0);
        // 200 ms later a wheel tick from another mouse must not match the old raw event.
        Assert.Empty(c.AddHook(InputSignal.Wheel(120), true, 0.2, "wheel", out _));
        var released = c.AddRaw(InputSignal.Wheel(1), Source.Other, 0.2001);
        Assert.Equal(Source.Other, Assert.Single(released).Source);
    }

    // MARK: Pointer

    [Fact]
    public void PointerTakesOverOnlyWhileOtherDevicesAreQuiet()
    {
        var r = new PointerRouter { Enabled = true };
        Assert.Null(r.TrackballMove(3, 0, 0.000, 4));      // first report: Windows already moved it
        Assert.True(r.TakingOver);
        Assert.NotNull(r.TrackballMove(3, 0, 0.008, 4));
        r.OtherMove(0.010);
        Assert.False(r.TakingOver);
        Assert.Null(r.TrackballMove(3, 0, 0.050, 4));      // other device moved 40 ms ago
        Assert.Null(r.TrackballMove(3, 0, 0.200, 4));      // quiet again: takes over from the next one
        Assert.NotNull(r.TrackballMove(3, 0, 0.208, 4));
    }

    [Fact]
    public void PointerCurveIsMonotonicAndKeepsFractions()
    {
        double previous = 0;
        for (var counts = 1; counts < 30; counts++)
        {
            var px = counts * PointerRouter.Curve(counts, 4);
            Assert.True(px > previous);
            previous = px;
        }
        var r = new PointerRouter { Enabled = true };
        r.TrackballMove(1, 0, 0, 2);   // take over
        var total = 0;
        for (var i = 0; i < 10; i++) total += r.TrackballMove(1, 0, 0.01 * (i + 1), 2)!.Value.dx;
        Assert.Equal(5, total);         // 10 counts × 0.5 px
    }
}
