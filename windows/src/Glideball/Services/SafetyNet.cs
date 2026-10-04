using System;
using System.Collections.Generic;
using System.IO;
using Glideball.Input;
using Glideball.Native;

namespace Glideball;

/// <summary>
/// Glideball must never leave you without a working mouse. Whatever happens —
/// pause, quit, an unhandled exception on any thread — this lets go of every
/// key and button Glideball pressed, unfreezes the cursor and restores
/// Windows' pointer speed. Every step is idempotent and safe from any thread.
/// </summary>
internal static class SafetyNet
{
    private static InputEngine? engine;

    public static void Install(InputEngine e)
    {
        engine = e;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            DiagLog.Write("crash: " + args.ExceptionObject);
            engine?.EmergencyStop();
            ReleaseEverything();
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => ReleaseEverything();
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            DiagLog.Write("unobserved task: " + args.Exception);
            args.SetObserved();
        };
    }

    public static void ReleaseEverything()
    {
        try { Injector.ReleaseAll(); } catch (Exception) { }
        try { Win32.ClipCursorNone(IntPtr.Zero); } catch (Exception) { }
        try { InputEngine.RestoreMouseSpeed(); } catch (Exception) { }
    }
}

/// <summary>A small in-memory log (and %APPDATA%\Glideball\glideball.log) for diagnosing problems.</summary>
internal static class DiagLog
{
    private static readonly object Gate = new();
    private static readonly LinkedList<string> Lines = new();
    public static string? FilePath { get; set; }

    public static void Write(string line)
    {
        var stamped = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + line;
        lock (Gate)
        {
            Lines.AddLast(stamped);
            while (Lines.Count > 500) Lines.RemoveFirst();
            if (FilePath == null) return;
            try
            {
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 512 * 1024) File.Delete(FilePath);
                File.AppendAllText(FilePath, stamped + Environment.NewLine);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    public static string Snapshot()
    {
        lock (Gate) return string.Join(Environment.NewLine, Lines);
    }
}
