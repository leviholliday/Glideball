using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using Glideball.Core.Buttons;
using Glideball.Core.Devices;
using Glideball.Core.Keys;
using Glideball.Core.Pointer;
using Glideball.Core.Settings;
using Glideball.Native;

namespace Glideball.Input;

/// <summary>A mouse event as the low-level hook saw it, kept so it can be replayed exactly.</summary>
internal sealed class HookEvent
{
    public int Message { get; init; }
    public int Button { get; init; } = -1;
    public bool IsDown { get; init; }
    public int WheelDelta { get; init; }
    public bool IsWheel => Message is Win32.WM_MOUSEWHEEL or Win32.WM_MOUSEHWHEEL;

    public InputSignal Signal => Message switch
    {
        Win32.WM_MOUSEWHEEL => InputSignal.Wheel(WheelDelta),
        Win32.WM_MOUSEHWHEEL => InputSignal.HWheel(WheelDelta),
        _ => IsDown ? InputSignal.Down(Button) : InputSignal.Up(Button),
    };

    /// <summary>The Mac-numbered button, wheel or null for anything else.</summary>
    public static HookEvent? From(int message, uint mouseData)
    {
        var high = (int)(mouseData >> 16);
        var x = high == Win32.XBUTTON1 ? 3 : high == Win32.XBUTTON2 ? 4 : -1;
        return message switch
        {
            Win32.WM_LBUTTONDOWN => new HookEvent { Message = message, Button = 0, IsDown = true },
            Win32.WM_LBUTTONUP => new HookEvent { Message = message, Button = 0 },
            Win32.WM_RBUTTONDOWN => new HookEvent { Message = message, Button = 1, IsDown = true },
            Win32.WM_RBUTTONUP => new HookEvent { Message = message, Button = 1 },
            Win32.WM_MBUTTONDOWN => new HookEvent { Message = message, Button = 2, IsDown = true },
            Win32.WM_MBUTTONUP => new HookEvent { Message = message, Button = 2 },
            Win32.WM_XBUTTONDOWN when x >= 0 => new HookEvent { Message = message, Button = x, IsDown = true },
            Win32.WM_XBUTTONUP when x >= 0 => new HookEvent { Message = message, Button = x },
            Win32.WM_MOUSEWHEEL or Win32.WM_MOUSEHWHEEL => new HookEvent { Message = message, WheelDelta = (short)(ushort)high },
            _ => null,
        };
    }

    public override string ToString() => IsWheel ? $"wheel {WheelDelta}" : $"button {Button} {(IsDown ? "down" : "up")}";
}

internal readonly record struct EngineStatus(bool HookActive, bool DeviceConnected, string? DeviceName, bool DeviceIsBeta,
    string? UnsupportedDeviceName, bool Paused);

/// <summary>
/// The input engine: one high-priority thread that owns the low-level mouse
/// hook, a message-only window receiving Raw Input from every mouse
/// (RIDEV_INPUTSINK), the device registry, the correlator and the button
/// engine. Nothing here ever opens the trackball exclusively; Windows keeps
/// driving it, and Glideball only rewrites events the trackball itself reported.
/// See windows/README.md for how attribution works and how it fails.
/// </summary>
internal sealed class InputEngine : IButtonHost, IDisposable
{
    // Raised on the input thread; subscribers marshal to the UI.
    public event Action<EngineStatus>? StatusChanged;
    public event Action<Modes>? ModesChanged;
    public event Action<IReadOnlyCollection<int>>? Learned;

    // Dashboard counters (read from any thread).
    public long BallCounts;
    public long Notches;
    public long Clicks;
    public double PointsScrolled => pump.PointsScrolled;

    private readonly Thread thread;
    private readonly ConcurrentQueue<Action> commands = new();
    private readonly ManualResetEventSlim ready = new(false);
    private volatile bool stopping;
    private IntPtr hwnd;
    private volatile IntPtr hook;
    private Win32.LowLevelMouseProc? hookProc;   // kept alive for as long as the hook exists
    private Win32.WndProc? wndProc;
    private IntPtr rawBuffer;
    private const int RawBufferSize = 1024;
    private uint headerSize;

    private readonly DeviceRegistry registry = new();
    private readonly InputCorrelator correlator = new();
    private readonly PointerRouter router = new();
    private readonly ScrollPump pump = new();
    private readonly ButtonEngine buttons;
    private GlideConfig config;
    private bool active;
    private EngineStatus status;

    // Hook callback bookkeeping (input thread only).
    private int depth;
    private bool draining;
    private InputCorrelator.Held? current;
    private Verdict? currentVerdict;
    private int callbackInjectBase;
    private double lastHookAt;
    private int rawSinceHook;
    private double nextHealthCheck;
    private double? dragLockWaitUntil;

    // Elevated windows can't receive our injected input (UIPI), so input over them is left alone.
    private readonly Dictionary<uint, (bool elevated, double checkedAt)> elevation = new();
    private readonly bool selfElevated = Environment.IsPrivilegedProcess;

    // Fallback precision without per-device speed: Windows' global speed, restored afterwards.
    private static int savedMouseSpeed;
    private static volatile bool mouseSpeedChanged;
    private bool clipped;

    public InputEngine(GlideConfig initial)
    {
        config = initial;
        active = initial.Enabled;
        buttons = new ButtonEngine(this, initial);
        pump.SetConfig(initial);
        thread = new Thread(Run) { IsBackground = true, Name = "Glideball input", Priority = ThreadPriority.Highest };
    }

    public void Start()
    {
        thread.Start();
        ready.Wait(3000);
    }

    // MARK: Commands (any thread)

    private void Post(Action a)
    {
        commands.Enqueue(a);
        if (hwnd != IntPtr.Zero) Win32.PostMessage(hwnd, Win32.WM_APP, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>When the input thread last ran its loop (seconds), for the pause watchdog.</summary>
    public double Heartbeat { get; private set; }

    /// <summary>The setup for the app in front (already resolved for per-app profiles).</summary>
    public void Update(GlideConfig resolved) => Post(() => Apply(resolved));

    public void SetPreferences(bool betaProgram, bool perDeviceSpeed, double wheelUnitsPerPoint) => Post(() =>
    {
        pump.UnitsPerPoint = wheelUnitsPerPoint;
        router.Enabled = perDeviceSpeed;
        if (!perDeviceSpeed) router.Reset();
        if (registry.BetaProgram != betaProgram)
        {
            registry.BetaProgram = betaProgram;
            registry.Refresh();
        }
        ApplyPrecisionFallback();
        Publish();
    });

    public void Learn(bool on) => Post(() => buttons.LearnNextPress(on));
    public void TogglePrecision() => Post(() => { buttons.TogglePrecision(); });
    public void ToggleBallScroll() => Post(() => { buttons.ToggleBallScroll(); });

    /// <summary>Drag lock from the keyboard grabs once the shortcut's keys are up, so it isn't a Ctrl-drag.</summary>
    public void ToggleDragLock() => Post(() =>
    {
        if (buttons.DragLocked) buttons.ToggleDragLock();
        else dragLockWaitUntil = Clock.Now + 2;
    });

    /// <summary>
    /// The escape hatch, callable from any thread even if the input thread is
    /// stuck: removes the hook and lets go of everything Glideball holds.
    /// </summary>
    public void EmergencyStop()
    {
        var h = hook;
        hook = IntPtr.Zero;
        if (h != IntPtr.Zero) Win32.UnhookWindowsHookEx(h);
        SafetyNet.ReleaseEverything();
    }

    // MARK: Thread

    private void Run()
    {
        Win32.timeBeginPeriod(1);
        try
        {
            CreateWindow();
            headerSize = (uint)Marshal.SizeOf<Win32.RAWINPUTHEADER>();
            rawBuffer = Marshal.AllocHGlobal(RawBufferSize);
            RegisterRawInput();
            registry.Refresh();
            InstallHook();
            Publish();
        }
        catch (Exception e)
        {
            DiagLog.Write("input engine failed to start: " + e);
        }
        finally
        {
            ready.Set();
        }

        while (!stopping)
        {
            var now = Clock.Now;
            Heartbeat = now;
            var timeout = Timeout(now);
            Win32.MsgWaitForMultipleObjectsEx(0, null, timeout, Win32.QS_ALLINPUT, Win32.MWMO_INPUTAVAILABLE);
            try
            {
                while (Win32.PeekMessage(out var msg, IntPtr.Zero, 0, 0, Win32.PM_REMOVE))
                {
                    if (msg.message == Win32.WM_QUIT) { stopping = true; break; }
                    if (msg.message == Win32.WM_INPUT && msg.hwnd == hwnd)
                    {
                        HandleRawInput(msg.lParam, Clock.Now);
                        Win32.DefWindowProc(msg.hwnd, msg.message, msg.wParam, msg.lParam);
                        continue;
                    }
                    Win32.DispatchMessage(ref msg);
                }
                while (commands.TryDequeue(out var command)) command();
                RunTimers(Clock.Now);
            }
            catch (Exception e)
            {
                // Never let one bad event take the mouse down with it.
                DiagLog.Write("input loop: " + e);
                ReleaseEverything();
            }
        }

        ReleaseEverything();
        var h = hook;
        hook = IntPtr.Zero;
        if (h != IntPtr.Zero) Win32.UnhookWindowsHookEx(h);
        if (hwnd != IntPtr.Zero) Win32.DestroyWindow(hwnd);
        if (rawBuffer != IntPtr.Zero) Marshal.FreeHGlobal(rawBuffer);
        Win32.timeEndPeriod(1);
    }

    private uint Timeout(double now)
    {
        var next = nextHealthCheck;
        if (buttons.NextDeadline is double b) next = Math.Min(next, b);
        if (correlator.NextDeadline is double c) next = Math.Min(next, c);
        if (dragLockWaitUntil != null) next = Math.Min(next, now + 0.02);
        var ms = Math.Ceiling((next - now) * 1000);
        return (uint)Math.Clamp(ms, 0, 1000);
    }

    private void RunTimers(double now)
    {
        Process(correlator.Expire(now), now);
        buttons.Tick(now);

        if (dragLockWaitUntil is double until)
        {
            if (!ModifiersDown() || now > until)
            {
                dragLockWaitUntil = null;
                if (!buttons.DragLocked) buttons.ToggleDragLock();
            }
        }

        if (now >= nextHealthCheck)
        {
            nextHealthCheck = now + 1;
            // Windows silently removes a low-level hook that once took longer than
            // LowLevelHooksTimeout. Raw Input keeps flowing, so a hook that has gone
            // quiet while the mice haven't has been dropped: put it back.
            if (hook != IntPtr.Zero && rawSinceHook > 40 && now - lastHookAt > 2)
            {
                DiagLog.Write("hook went silent; reinstalling");
                var old = hook;
                hook = IntPtr.Zero;
                Win32.UnhookWindowsHookEx(old);
                InstallHook();
                rawSinceHook = 0;
                Publish();
            }
        }
    }

    private void CreateWindow()
    {
        wndProc = WindowProc;
        var cls = new Win32.WNDCLASSEX
        {
            cbSize = (uint)Marshal.SizeOf<Win32.WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc),
            hInstance = Win32.GetModuleHandle(null),
            lpszClassName = "GlideballInput",
        };
        Win32.RegisterClassEx(ref cls);
        hwnd = Win32.CreateWindowEx(0, "GlideballInput", "Glideball input", 0, 0, 0, 0, 0,
            Win32.HWND_MESSAGE, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx failed: " + Marshal.GetLastWin32Error());
    }

    private void RegisterRawInput()
    {
        var devices = new[]
        {
            new Win32.RAWINPUTDEVICE
            {
                usUsagePage = Win32.HID_USAGE_PAGE_GENERIC,
                usUsage = Win32.HID_USAGE_GENERIC_MOUSE,
                dwFlags = Win32.RIDEV_INPUTSINK | Win32.RIDEV_DEVNOTIFY,
                hwndTarget = hwnd,
            },
        };
        if (!Win32.RegisterRawInputDevices(devices, 1, (uint)Marshal.SizeOf<Win32.RAWINPUTDEVICE>()))
            DiagLog.Write("RegisterRawInputDevices failed: " + Marshal.GetLastWin32Error());
    }

    private void InstallHook()
    {
        hookProc ??= HookProc;
        var h = Win32.SetWindowsHookEx(Win32.WH_MOUSE_LL, hookProc, Win32.GetModuleHandle(null), 0);
        if (h == IntPtr.Zero) DiagLog.Write("SetWindowsHookEx failed: " + Marshal.GetLastWin32Error());
        hook = h;
        lastHookAt = Clock.Now;
    }

    private IntPtr WindowProc(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            switch (msg)
            {
                case Win32.WM_INPUT:
                    HandleRawInput(lParam, Clock.Now);
                    break;
                case Win32.WM_INPUT_DEVICE_CHANGE:
                    if ((int)wParam == Win32.GIDC_REMOVAL) registry.Removed(lParam);
                    registry.Refresh();
                    if (registry.ActiveTrackball() == null) buttons.ReleaseAll();
                    Publish();
                    return IntPtr.Zero;
            }
        }
        catch (Exception e)
        {
            DiagLog.Write("window proc: " + e);
        }
        return Win32.DefWindowProc(h, msg, wParam, lParam);
    }

    // MARK: The hook

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        var h = hook;
        if (nCode < 0) return Win32.CallNextHookEx(h, nCode, wParam, lParam);
        try
        {
            var now = Clock.Now;
            lastHookAt = now;
            rawSinceHook = 0;
            var info = Marshal.PtrToStructure<Win32.MSLLHOOKSTRUCT>(lParam);
            if (Swallow((int)wParam, info, now)) return new IntPtr(1);
        }
        catch (Exception e)
        {
            DiagLog.Write("hook: " + e.Message);
        }
        return Win32.CallNextHookEx(h, nCode, wParam, lParam);
    }

    private bool Swallow(int message, Win32.MSLLHOOKSTRUCT info, double now)
    {
        if (info.dwExtraInfo == Injector.Marker) return false;          // our own input
        if (!active) return false;                                       // paused: hands off
        if ((info.flags & (Win32.LLMHF_INJECTED | Win32.LLMHF_LOWER_IL_INJECTED)) != 0) return false;   // other software's

        if (message == Win32.WM_MOUSEMOVE) return SwallowMove(now);

        var ev = HookEvent.From(message, info.mouseData);
        if (ev == null) return false;

        // Presses and wheel ticks over an elevated window are left alone: Windows
        // wouldn't let us inject anything back into it. Releases always go through
        // the engine, so a press it took over still gets its release.
        if ((ev.IsDown || ev.IsWheel) && correlator.HeldCount == 0 && OverElevatedWindow(info.pt)) return false;

        var trackball = registry.ActiveTrackball() != null;
        var needsSource = trackball && (ev.IsWheel ? WheelMatters() : ev.IsDown && buttons.CaresAbout(ev.Button));
        if (!needsSource && correlator.HeldCount == 0 && !buttons.HasPending && ev.IsWheel) return false;

        depth++;
        var outerCurrent = current;
        var outerVerdict = currentVerdict;
        var outerBase = callbackInjectBase;
        currentVerdict = null;
        callbackInjectBase = Injector.InjectedCount;
        try
        {
            var released = correlator.AddHook(ev.Signal, needsSource, now, ev, out var entry);
            current = entry;
            Process(released, now);
            // Usually the matching WM_INPUT is already queued: read it now and decide
            // synchronously, so nothing needs to be held at all.
            if (entry.Source == null && !draining) DrainRawInput(now);
            return currentVerdict != Verdict.Pass;
        }
        finally
        {
            current = outerCurrent;
            currentVerdict = outerVerdict;
            callbackInjectBase = outerBase;
            depth--;
        }
    }

    private bool SwallowMove(double now)
    {
        if (!router.Enabled) return false;
        if (!draining) DrainRawInput(now);
        return router.SwallowUnattributedMove;
    }

    private bool WheelMatters() => config.Enabled && (config.ScrollMode != ScrollMode.Native || config.ReverseScroll);

    private void DrainRawInput(double now)
    {
        draining = true;
        try
        {
            while (Win32.PeekMessage(out var msg, hwnd, Win32.WM_INPUT, Win32.WM_INPUT, Win32.PM_REMOVE))
            {
                HandleRawInput(msg.lParam, now);
                Win32.DefWindowProc(msg.hwnd, msg.message, msg.wParam, msg.lParam);
            }
        }
        finally
        {
            draining = false;
        }
    }

    /// <summary>Acts on hook events the correlator let go of, in order.</summary>
    private void Process(List<InputCorrelator.Released> released, double now)
    {
        foreach (var r in released)
        {
            if (r.Event.Tag is not HookEvent ev) continue;
            var before = Injector.InjectedCount;
            var verdict = Decide(ev, r.Source == Source.Trackball, now);
            if (ReferenceEquals(r.Event, current) && before == callbackInjectBase && Injector.InjectedCount == before)
                currentVerdict = verdict;          // decided inside its own callback: just return it
            else if (verdict == Verdict.Pass)
                Injector.Replay(ev);               // decided later, or behind injected events: replay it
        }
    }

    private Verdict Decide(HookEvent ev, bool fromTrackball, double now)
    {
        if (ev.IsWheel) return DecideWheel(ev, fromTrackball);
        if (fromTrackball && ev.IsDown) Interlocked.Increment(ref Clicks);
        return buttons.Handle(ev.Button, ev.IsDown ? Phase.Down : Phase.Up, fromTrackball, now, ev);
    }

    private Verdict DecideWheel(HookEvent ev, bool fromTrackball)
    {
        if (!fromTrackball || !config.Enabled) return Verdict.Pass;
        Interlocked.Increment(ref Notches);
        var horizontal = ev.Message == Win32.WM_MOUSEHWHEEL;
        var modifiers = KeyDown(KeyMap.VK_CONTROL) || KeyDown(KeyMap.VK_MENU) || KeyDown(KeyMap.VK_LWIN) || KeyDown(KeyMap.VK_RWIN);
        if (config.ScrollMode == ScrollMode.Native || modifiers)
        {
            // Native scrolling (and Ctrl/Alt/Win + scroll, e.g. zoom) stays Windows' own; only direction is ours.
            if (!config.ReverseScroll) return Verdict.Pass;
            Injector.Wheel(-ev.WheelDelta, horizontal);
            return Verdict.Swallow;
        }
        // + ticks scroll up (vertical) or left (horizontal), the scroller's convention.
        var ticks = ev.WheelDelta / (double)Win32.WHEEL_DELTA;
        if (horizontal) ticks = -ticks;
        lock (pump.Gate) pump.Scroller.AddTicks(ticks, horizontal, KeyDown(KeyMap.VK_SHIFT));
        return Verdict.Swallow;
    }

    // MARK: Raw Input

    private static readonly (ushort down, ushort up, int button)[] RawButtons =
    {
        (Win32.RI_MOUSE_LEFT_BUTTON_DOWN, Win32.RI_MOUSE_LEFT_BUTTON_UP, 0),
        (Win32.RI_MOUSE_RIGHT_BUTTON_DOWN, Win32.RI_MOUSE_RIGHT_BUTTON_UP, 1),
        (Win32.RI_MOUSE_MIDDLE_BUTTON_DOWN, Win32.RI_MOUSE_MIDDLE_BUTTON_UP, 2),
        (Win32.RI_MOUSE_BUTTON_4_DOWN, Win32.RI_MOUSE_BUTTON_4_UP, 3),
        (Win32.RI_MOUSE_BUTTON_5_DOWN, Win32.RI_MOUSE_BUTTON_5_UP, 4),
    };

    private void HandleRawInput(IntPtr hRawInput, double now)
    {
        if (rawBuffer == IntPtr.Zero) return;
        rawSinceHook++;
        uint size = RawBufferSize;
        var got = Win32.GetRawInputData(hRawInput, Win32.RID_INPUT, rawBuffer, ref size, headerSize);
        if (got == uint.MaxValue || got < headerSize + 24) return;
        if ((uint)Marshal.ReadInt32(rawBuffer, 0) != Win32.RIM_TYPEMOUSE) return;
        var device = Marshal.ReadIntPtr(rawBuffer, 8);
        if (device == IntPtr.Zero) return;   // injected input (ours or anyone's) has no device

        var o = (int)headerSize;
        var moveFlags = (ushort)Marshal.ReadInt16(rawBuffer, o);
        var buttonFlags = (ushort)Marshal.ReadInt16(rawBuffer, o + 4);
        var buttonData = Marshal.ReadInt16(rawBuffer, o + 6);
        var dx = Marshal.ReadInt32(rawBuffer, o + 12);
        var dy = Marshal.ReadInt32(rawBuffer, o + 16);

        var isTrackball = registry.IsSupported(device);
        var source = isTrackball ? Source.Trackball : Source.Other;

        if (buttonFlags != 0)
        {
            foreach (var (down, up, button) in RawButtons)
            {
                if ((buttonFlags & down) != 0)
                {
                    if (isTrackball) buttons.TrackballButton(button, true);
                    Process(correlator.AddRaw(InputSignal.Down(button), source, now), now);
                }
                if ((buttonFlags & up) != 0)
                {
                    if (isTrackball) buttons.TrackballButton(button, false);
                    Process(correlator.AddRaw(InputSignal.Up(button), source, now), now);
                }
            }
            if ((buttonFlags & Win32.RI_MOUSE_WHEEL) != 0 && buttonData != 0)
                Process(correlator.AddRaw(InputSignal.Wheel(buttonData), source, now), now);
            if ((buttonFlags & Win32.RI_MOUSE_HWHEEL) != 0 && buttonData != 0)
                Process(correlator.AddRaw(InputSignal.HWheel(buttonData), source, now), now);
        }

        if ((moveFlags & Win32.MOUSE_MOVE_ABSOLUTE) == 0 && (dx != 0 || dy != 0))
        {
            if (!isTrackball)
            {
                router.OtherMove(now);
                return;
            }
            Interlocked.Add(ref BallCounts, Math.Abs(dx) + Math.Abs(dy));
            if (!active) return;
            if (buttons.BallScrolling)
            {
                Freeze();
                // Rolling the ball down scrolls down, like a wheel; right scrolls right.
                lock (pump.Gate) pump.Scroller.AddBallDelta(-dx, -dy);
                return;
            }
            var speed = buttons.PrecisionActive ? config.PrecisionSpeed : config.TrackingSpeed;
            var move = router.TrackballMove(dx, dy, now, speed);
            if (move is { } m && (m.dx != 0 || m.dy != 0))
            {
                if (Win32.GetCursorPos(out var p)) Win32.SetCursorPos(p.X + m.dx, p.Y + m.dy);
            }
        }
    }

    // MARK: Applying settings

    private void Apply(GlideConfig resolved)
    {
        var wasActive = active;
        config = resolved;
        active = resolved.Enabled;
        buttons.Update(resolved);
        pump.SetConfig(resolved);
        if (wasActive && !active) ReleaseEverything();
        ApplyPrecisionFallback();
        Publish();
    }

    /// <summary>Pause, quit, unplug, errors: nothing held, nothing frozen, nothing slowed.</summary>
    private void ReleaseEverything()
    {
        try
        {
            buttons.ReleaseAll();
            Process(correlator.Flush(), Clock.Now);   // held events go back untouched
        }
        catch (Exception e)
        {
            DiagLog.Write("release: " + e.Message);
        }
        pump.Reset();
        router.Reset();
        dragLockWaitUntil = null;
        Unfreeze();
        SafetyNet.ReleaseEverything();
    }

    private void Freeze()
    {
        if (!Win32.GetCursorPos(out var p)) return;
        var r = new Win32.RECT { Left = p.X, Top = p.Y, Right = p.X + 1, Bottom = p.Y + 1 };
        Win32.ClipCursor(ref r);   // re-applied on every move: Windows resets clipping on focus changes
        clipped = true;
    }

    private void Unfreeze()
    {
        if (!clipped) return;
        Win32.ClipCursorNone(IntPtr.Zero);
        clipped = false;
    }

    /// <summary>
    /// Precision without per-device speed: Windows' (global) pointer speed is
    /// lowered while Precision is on — not saved to the registry, and restored
    /// on exit and crash.
    /// </summary>
    private void ApplyPrecisionFallback()
    {
        var want = buttons.PrecisionActive && !router.Enabled;
        if (want && !mouseSpeedChanged)
        {
            var speedNow = 10;
            if (!Win32.SystemParametersInfoGet(Win32.SPI_GETMOUSESPEED, 0, ref speedNow, 0)) return;
            savedMouseSpeed = speedNow;
            var ratio = config.PrecisionSpeed / Math.Max(config.TrackingSpeed, 0.1);
            var slow = Math.Clamp((int)Math.Round(speedNow * ratio), 1, 20);
            Win32.SystemParametersInfoSet(Win32.SPI_SETMOUSESPEED, 0, new IntPtr(slow), 0);
            mouseSpeedChanged = true;
        }
        else if (!want)
        {
            RestoreMouseSpeed();
        }
    }

    public static void RestoreMouseSpeed()
    {
        if (!mouseSpeedChanged) return;
        Win32.SystemParametersInfoSet(Win32.SPI_SETMOUSESPEED, 0, new IntPtr(savedMouseSpeed), 0);
        mouseSpeedChanged = false;
    }

    private void Publish()
    {
        var t = registry.ActiveTrackball();
        var s = new EngineStatus(
            HookActive: hook != IntPtr.Zero,
            DeviceConnected: t != null,
            DeviceName: t?.Identity.DisplayName,
            DeviceIsBeta: t != null && t.Identity.Kind != DeviceKind.ExpertMouse,
            UnsupportedDeviceName: registry.UnsupportedKensington()?.Identity.DisplayName,
            Paused: !config.Enabled);
        if (s == status) return;
        status = s;
        StatusChanged?.Invoke(s);
    }

    // MARK: Helpers

    private static bool KeyDown(int vk) => (Win32.GetAsyncKeyState(vk) & 0x8000) != 0;

    private static bool ModifiersDown() =>
        KeyDown(KeyMap.VK_CONTROL) || KeyDown(KeyMap.VK_MENU) || KeyDown(KeyMap.VK_SHIFT)
        || KeyDown(KeyMap.VK_LWIN) || KeyDown(KeyMap.VK_RWIN);

    private bool OverElevatedWindow(Win32.POINT pt)
    {
        if (selfElevated) return false;
        var w = Win32.WindowFromPoint(pt);
        if (w == IntPtr.Zero) return false;
        Win32.GetWindowThreadProcessId(w, out var pid);
        if (pid == 0) return false;
        var now = Clock.Now;
        if (elevation.TryGetValue(pid, out var e) && now - e.checkedAt < 10) return e.elevated;
        var elevated = IsElevated(pid);
        if (elevation.Count > 256) elevation.Clear();
        elevation[pid] = (elevated, now);
        return elevated;
    }

    private static bool IsElevated(uint pid)
    {
        var process = Win32.OpenProcess(Win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return true;   // can't even look: treat as off-limits
        try
        {
            if (!Win32.OpenProcessToken(process, Win32.TOKEN_QUERY, out var token)) return true;
            try
            {
                return Win32.GetTokenInformation(token, Win32.TokenElevation, out var elevated, sizeof(int), out _) && elevated != 0;
            }
            finally
            {
                Win32.CloseHandle(token);
            }
        }
        finally
        {
            Win32.CloseHandle(process);
        }
    }

    // MARK: IButtonHost (input thread)

    void IButtonHost.Replay(object original)
    {
        if (original is HookEvent e) Injector.Replay(e);
    }

    void IButtonHost.InjectButton(int button, bool down, ulong macModifiers)
    {
        // The Mac's Control-click is its context-menu click: a right click here.
        if (button == 0 && macModifiers == MacFlags.Control)
        {
            Injector.Button(1, down);
            return;
        }
        Injector.ModifiedButton(button, down, KeyMap.ClickModifiersToWindows(macModifiers));
    }

    void IButtonHost.Click(ButtonAction action)
    {
        IButtonHost host = this;
        var (button, mods) = action.Kind switch
        {
            ActionKind.LeftClick => (0, 0ul),
            ActionKind.RightClick => (1, 0ul),
            ActionKind.MiddleClick => (2, 0ul),
            ActionKind.Back => (3, 0ul),
            ActionKind.Forward => (4, 0ul),
            ActionKind.ModifiedClick => (action.Button, action.Modifiers),
            _ => (-1, 0ul),
        };
        if (button < 0) return;
        host.InjectButton(button, true, mods);
        host.InjectButton(button, false, mods);
    }

    void IButtonHost.SendShortcut(KeyShortcut s)
    {
        if (KeyMap.ToWindows(s) is WinChord c) Injector.Chord(c);
    }

    void IButtonHost.ShortcutDown(KeyShortcut s)
    {
        if (KeyMap.ToWindows(s) is WinChord c) Injector.ChordDown(c);
    }

    void IButtonHost.ShortcutUp(KeyShortcut s)
    {
        if (KeyMap.ToWindows(s) is WinChord c) Injector.ChordUp(c);
    }

    void IButtonHost.DragLockButton(bool down) => Injector.Button(0, down);

    void IButtonHost.BallScroll(bool on, bool glide)
    {
        lock (pump.Gate)
        {
            if (on) pump.Scroller.BeginBall();
            else if (glide) pump.Scroller.EndBall(true);
            else pump.Scroller.CancelBall();
        }
        if (on) Freeze(); else Unfreeze();
    }

    void IButtonHost.ModesChanged(Modes modes)
    {
        ApplyPrecisionFallback();
        ModesChanged?.Invoke(modes);
    }

    void IButtonHost.Learned(IReadOnlyCollection<int> pressed) => Learned?.Invoke(pressed);

    public void Dispose()
    {
        stopping = true;
        if (hwnd != IntPtr.Zero) Win32.PostMessage(hwnd, Win32.WM_APP, IntPtr.Zero, IntPtr.Zero);
        thread.Join(1000);
        pump.Dispose();
    }
}
