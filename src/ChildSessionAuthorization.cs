using System;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;

[DataContract]
sealed class ChildSessionAuthorization
{
    [DataMember(Order = 1)] public int schemaVersion = 1;
    [DataMember(Order = 2)] public uint childSessionId;
    [DataMember(Order = 3)] public int launcherProcessId;
    [DataMember(Order = 4)] public string launcherStartTimeUtc;
    [DataMember(Order = 5)] public string issuedAtUtc;
}

static class ChildSessionAuthorizationStore
{
    public static void Write(string path, uint sessionId, int processId, DateTime processStartUtc, DateTime issuedUtc)
    {
        string directory = Path.GetDirectoryName(path);
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            var authorization = new ChildSessionAuthorization
            {
                childSessionId = sessionId,
                launcherProcessId = processId,
                launcherStartTimeUtc = processStartUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                issuedAtUtc = issuedUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture)
            };
            var serializer = new DataContractJsonSerializer(typeof(ChildSessionAuthorization));
            using (FileStream stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                serializer.WriteObject(stream, authorization);
                stream.Flush();
            }

            if (File.Exists(path)) File.Replace(temporaryPath, path, null);
            else File.Move(temporaryPath, path);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    public static void Delete(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }
}

sealed class ChildSessionAuthorizationRetry
{
    readonly TimeSpan retryWindow;
    bool connected;
    bool issued;
    DateTime retryUntilUtc;

    public ChildSessionAuthorizationRetry(TimeSpan retryWindow)
    {
        this.retryWindow = retryWindow;
    }

    public void OnConnected(DateTime nowUtc)
    {
        connected = true;
        issued = false;
        retryUntilUtc = nowUtc.Add(retryWindow);
    }

    public bool ShouldAttempt(DateTime nowUtc)
    {
        return connected && !issued && nowUtc <= retryUntilUtc;
    }

    public void MarkIssued()
    {
        issued = true;
    }

    public void OnDisconnected()
    {
        connected = false;
        issued = false;
        retryUntilUtc = DateTime.MinValue;
    }
}
