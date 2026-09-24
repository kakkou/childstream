using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

static class ChildSessionNative
{
    const int ErrorInvalidParameter = 87;

    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSGetChildSessionId(out uint sessionId);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSLogoffSession(IntPtr server, uint sessionId, bool wait);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSIsChildSessionsEnabled(out bool enabled);

    public static bool TryIsChildSessionsEnabled(out bool enabled, out int error)
    {
        bool reportedEnabled;
        bool succeeded = WTSIsChildSessionsEnabled(out reportedEnabled);
        int lastError = succeeded ? 0 : Marshal.GetLastWin32Error();
        return CompleteChildSessionsEnabledQuery(succeeded, reportedEnabled, lastError, out enabled, out error);
    }

    internal static bool CompleteChildSessionsEnabledQuery(
        bool succeeded, bool reportedEnabled, int lastError, out bool enabled, out int error)
    {
        enabled = succeeded && reportedEnabled;
        error = succeeded ? 0 : lastError;
        return succeeded;
    }

    public static bool TryGetChildSessionId(out uint id, out int error)
    {
        id = UInt32.MaxValue;
        if (!WTSGetChildSessionId(out id))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }

        if (id == UInt32.MaxValue || id == (uint)Process.GetCurrentProcess().SessionId)
        {
            error = ErrorInvalidParameter;
            return false;
        }

        error = 0;
        return true;
    }

    public static bool TryLogoffChildSession(out uint id, out int error)
    {
        if (!TryGetChildSessionId(out id, out error)) return false;
        if (!WTSLogoffSession(IntPtr.Zero, id, false))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }

        error = 0;
        return true;
    }
}
