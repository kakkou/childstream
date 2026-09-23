using System;

static class ChildSessionSafetyTests
{
    static void Require(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    public static int Main()
    {
        bool enabled;
        int error;
        bool querySucceeded = ChildSessionNative.CompleteChildSessionsEnabledQuery(
            false, false, 5, out enabled, out error);
        Require(!querySucceeded, "WTS query failure must remain distinguishable from disabled state.");
        Require(!enabled && error == 5, "WTS query failure must preserve its Win32 error.");

        querySucceeded = ChildSessionNative.CompleteChildSessionsEnabledQuery(
            false, true, 6, out enabled, out error);
        Require(!querySucceeded && !enabled && error == 6, "WTS query failure must not expose an undefined enabled value.");

        querySucceeded = ChildSessionNative.CompleteChildSessionsEnabledQuery(
            true, true, 5, out enabled, out error);
        Require(querySucceeded && enabled && error == 0, "Successful WTS query must clear the stale Win32 error.");

        DateTime connectedAt = new DateTime(638941248000000000L, DateTimeKind.Utc);
        var retry = new ChildSessionAuthorizationRetry(TimeSpan.FromSeconds(10));
        retry.OnConnected(connectedAt);
        Require(retry.ShouldAttempt(connectedAt), "First connected tick must attempt authorization.");
        Require(retry.ShouldAttempt(connectedAt.AddSeconds(2)), "A failed first attempt must retry on the next tick.");
        retry.MarkIssued();
        Require(!retry.ShouldAttempt(connectedAt.AddSeconds(4)), "A successful authorization must stop retries.");

        retry.OnDisconnected();
        Require(!retry.ShouldAttempt(connectedAt.AddSeconds(6)), "Disconnect must reset and stop authorization attempts.");
        retry.OnConnected(connectedAt.AddSeconds(8));
        Require(retry.ShouldAttempt(connectedAt.AddSeconds(8)), "Reconnect must begin a new retry window.");
        Require(!retry.ShouldAttempt(connectedAt.AddSeconds(19)), "Authorization retries must stop after the retry window.");
        return 0;
    }
}
