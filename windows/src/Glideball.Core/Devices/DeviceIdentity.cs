using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Glideball.Core.Devices;

public enum DeviceKind
{
    /// <summary>Kensington Expert Mouse: always supported.</summary>
    ExpertMouse,
    /// <summary>Kensington's other pointing devices: supported in the Beta program.</summary>
    OtherKensington,
    /// <summary>Everything else: never touched.</summary>
    Other,
}

/// <summary>Which pointing devices Glideball works with (Mac's <c>DeviceIdentity</c>).</summary>
public sealed record DeviceIdentity(int? VendorId, int? ProductId, string? Name)
{
    public const int KensingtonVendorId = 0x047D;
    public const int ExpertMouseProductId = 0x1020;

    public DeviceKind Kind
    {
        get
        {
            if (VendorId != KensingtonVendorId) return DeviceKind.Other;
            if (ProductId == ExpertMouseProductId
                || (Name?.Contains("Expert Mouse", StringComparison.OrdinalIgnoreCase) ?? false))
                return DeviceKind.ExpertMouse;
            return DeviceKind.OtherKensington;
        }
    }

    public bool IsSupported(bool beta) => Kind switch
    {
        DeviceKind.ExpertMouse => true,
        DeviceKind.OtherKensington => beta,
        _ => false,
    };

    public string DisplayName
    {
        get
        {
            var trimmed = Name?.Trim() ?? "";
            if (trimmed.Length > 0)
                return VendorId == KensingtonVendorId && !trimmed.Contains("Kensington", StringComparison.OrdinalIgnoreCase)
                    ? "Kensington " + trimmed : trimmed;
            return Kind == DeviceKind.ExpertMouse ? "Kensington Expert Mouse" : "Kensington trackball";
        }
    }

    // USB:            \\?\HID#VID_047D&PID_1020&MI_00#7&2a8b...#{378de44c-56ef-11d1-bc8c-00a0c91405dd}
    // Bluetooth:      \\?\HID#{00001124-0000-1000-8000-00805f9b34fb}_VID&0002047d_PID&8019#...
    // Bluetooth LE:   \\?\HID#{00001812-0000-1000-8000-00805f9b34fb}_Dev_VID&02047d_PID&8019_REV&0001_...
    // The Bluetooth forms prefix the vendor ID with its ID source (0002 / 02), so
    // the vendor is the last four hex digits of the run.
    private static readonly Regex VidRegex = new(@"VID[_&]([0-9A-F]{4,8})", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex PidRegex = new(@"PID[_&]([0-9A-F]{4})", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Vendor and product IDs from a raw-input / HID device interface path.</summary>
    public static DeviceIdentity FromDevicePath(string? path, string? productName = null)
    {
        if (string.IsNullOrEmpty(path)) return new DeviceIdentity(null, null, productName);
        int? vid = null, pid = null;
        var v = VidRegex.Match(path);
        if (v.Success)
        {
            var hex = v.Groups[1].Value;
            vid = int.Parse(hex.Substring(hex.Length - 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }
        var p = PidRegex.Match(path);
        if (p.Success) pid = int.Parse(p.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return new DeviceIdentity(vid, pid, productName);
    }
}
