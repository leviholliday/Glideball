using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Glideball.Core.Devices;
using Glideball.Native;

namespace Glideball.Input;

/// <summary>
/// Raw Input device handles → who they are. Pointing devices are identified by
/// the VID/PID in their device interface path; Kensington devices also get
/// their HID product name (for the Expert Mouse Wireless and the UI).
/// Input thread only.
/// </summary>
internal sealed class DeviceRegistry
{
    public sealed record Device(IntPtr Handle, string Path, DeviceIdentity Identity);

    private readonly Dictionary<IntPtr, Device> devices = new();
    public bool BetaProgram { get; set; }

    public IEnumerable<Device> All => devices.Values;

    public bool IsSupported(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return false;
        return Lookup(handle)?.Identity.IsSupported(BetaProgram) ?? false;
    }

    public Device? Lookup(IntPtr handle)
    {
        if (devices.TryGetValue(handle, out var d)) return d;
        var path = DeviceName(handle);
        if (path == null) return null;
        var id = DeviceIdentity.FromDevicePath(path);
        if (id.VendorId == DeviceIdentity.KensingtonVendorId) id = id with { Name = ProductName(path) };
        d = new Device(handle, path, id);
        devices[handle] = d;
        return d;
    }

    public void Removed(IntPtr handle) => devices.Remove(handle);

    /// <summary>Re-reads the list of connected mice (start, and after arrivals/removals).</summary>
    public void Refresh()
    {
        devices.Clear();
        uint count = 0;
        var size = (uint)Marshal.SizeOf<Win32.RAWINPUTDEVICELIST>();
        if (Win32.GetRawInputDeviceList(null, ref count, size) != 0 || count == 0) return;
        var list = new Win32.RAWINPUTDEVICELIST[count];
        var got = Win32.GetRawInputDeviceList(list, ref count, size);
        if (got == uint.MaxValue) return;
        for (var i = 0; i < got && i < list.Length; i++)
            if (list[i].dwType == Win32.RIM_TYPEMOUSE) Lookup(list[i].hDevice);
    }

    /// <summary>The connected device Glideball works with, preferring the Expert Mouse.</summary>
    public Device? ActiveTrackball()
    {
        Device? best = null;
        foreach (var d in devices.Values)
        {
            if (!d.Identity.IsSupported(BetaProgram)) continue;
            if (best == null || d.Identity.Kind == DeviceKind.ExpertMouse) best = d;
        }
        return best;
    }

    /// <summary>A Kensington that would work in the Beta program, for the UI's hint.</summary>
    public Device? UnsupportedKensington()
    {
        foreach (var d in devices.Values)
            if (d.Identity.Kind == DeviceKind.OtherKensington && !BetaProgram) return d;
        return null;
    }

    private static string? DeviceName(IntPtr handle)
    {
        uint chars = 0;
        Win32.GetRawInputDeviceInfo(handle, Win32.RIDI_DEVICENAME, IntPtr.Zero, ref chars);
        if (chars == 0 || chars > 4096) return null;
        var buffer = Marshal.AllocHGlobal((int)chars * 2 + 2);
        try
        {
            var r = Win32.GetRawInputDeviceInfo(handle, Win32.RIDI_DEVICENAME, buffer, ref chars);
            if (r == uint.MaxValue || r == 0) return null;
            return Marshal.PtrToStringUni(buffer);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    /// <summary>The HID product string, opened without any access rights (so it never interferes with the device).</summary>
    private static string? ProductName(string path)
    {
        var h = Win32.CreateFile(path, 0, Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE, IntPtr.Zero, Win32.OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == Win32.INVALID_HANDLE_VALUE || h == IntPtr.Zero) return null;
        try
        {
            var buffer = new byte[256];
            if (!Win32.HidD_GetProductString(h, buffer, (uint)buffer.Length)) return null;
            var s = Encoding.Unicode.GetString(buffer);
            var end = s.IndexOf('\0');
            return (end >= 0 ? s.Substring(0, end) : s).Trim();
        }
        finally
        {
            Win32.CloseHandle(h);
        }
    }
}
