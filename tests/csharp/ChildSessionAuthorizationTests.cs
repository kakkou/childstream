using System;
using System.IO;

static class ChildSessionAuthorizationTests
{
    public static int Main()
    {
        string dir = Path.Combine(Path.GetTempPath(), "ChildStreamTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "active-child-session.json");
        DateTime started = new DateTime(638941248000000000L, DateTimeKind.Utc);
        DateTime issued = started.AddSeconds(10);
        ChildSessionAuthorizationStore.Write(path, 42, 1234, started, issued);
        string json = File.ReadAllText(path);
        if (!json.Contains("\"schemaVersion\":1") || !json.Contains("\"childSessionId\":42") ||
            !json.Contains("\"launcherProcessId\":1234") || Directory.GetFiles(dir, "*.tmp").Length != 0) return 1;
        ChildSessionAuthorizationStore.Write(path, 43, 1234, started, issued);
        if (!File.ReadAllText(path).Contains("\"childSessionId\":43")) return 1;
        ChildSessionAuthorizationStore.Delete(path);
        ChildSessionAuthorizationStore.Delete(path);
        if (File.Exists(path)) return 1;
        Directory.Delete(dir, true);
        return 0;
    }
}
