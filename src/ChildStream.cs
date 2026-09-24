using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[ComImport, Guid("302D8188-0052-4807-806A-362B628F9AC5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMsRdpExtendedSettings
{
    void put_Property([MarshalAs(UnmanagedType.BStr)] string name, ref object value);
    void get_Property([MarshalAs(UnmanagedType.BStr)] string name, out object value);
}

public class RdpBox : AxHost
{
    // Microsoft RDP Client Control (MsTscAx)
    public RdpBox() : base("8B918B82-7985-4C24-89DF-C33AD2BBFBCD") { }
    public object Ocx { get { return GetOcx(); } }
}

static class Program
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSEnableChildSessions(bool enable);

    static string baseDir = AppDomain.CurrentDomain.BaseDirectory;
    static string logPath = Path.Combine(baseDir, "launcher.log");
    static string credPath = Path.Combine(baseDir, "cred.bin");

    static void Log(string msg)
    {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg + Environment.NewLine); } catch { }
    }

    static string LoadPassword()
    {
        try
        {
            if (File.Exists(credPath))
                return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(credPath), null, DataProtectionScope.CurrentUser));
        }
        catch (Exception ex) { Log("cred load failed: " + ex.Message); }
        return null;
    }

    static void SavePassword(string pw)
    {
        try { File.WriteAllBytes(credPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(pw), null, DataProtectionScope.CurrentUser)); }
        catch (Exception ex) { Log("cred save failed: " + ex.Message); }
    }

    static string PromptPassword(string account)
    {
        var d = new Form { Text = "Child Session - one-time setup", Width = 440, Height = 190, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterScreen, MaximizeBox = false, MinimizeBox = false };
        var lbl = new Label { Text = "Enter the Windows password for " + account + "\n(stored DPAPI-encrypted, used to auto-login the child session):", Left = 12, Top = 12, Width = 400, Height = 36 };
        var tb = new TextBox { Left = 12, Top = 56, Width = 398, UseSystemPasswordChar = true };
        var ok = new Button { Text = "Save", Left = 246, Top = 92, Width = 80, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", Left = 332, Top = 92, Width = 80, DialogResult = DialogResult.Cancel };
        d.Controls.AddRange(new Control[] { lbl, tb, ok, cancel });
        d.AcceptButton = ok; d.CancelButton = cancel;
        return d.ShowDialog() == DialogResult.OK && tb.Text.Length > 0 ? tb.Text : null;
    }

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "-enable")
        {
            bool ok = WTSEnableChildSessions(true);
            int err = Marshal.GetLastWin32Error();
            bool en1;
            int queryError;
            if (!ChildSessionNative.TryIsChildSessionsEnabled(out en1, out queryError))
            {
                Log("WTSEnableChildSessions(true) => " + ok + " (gle=" + err + "), status query failed (gle=" + queryError + ")");
                return 1;
            }
            Log("WTSEnableChildSessions(true) => " + ok + " (gle=" + err + "), enabled now = " + en1);
            return en1 ? 0 : 1;
        }
        if (args.Length > 0 && args[0] == "-disable")
        {
            bool ok = WTSEnableChildSessions(false);
            int err = Marshal.GetLastWin32Error();
            bool en0;
            int queryError;
            if (!ChildSessionNative.TryIsChildSessionsEnabled(out en0, out queryError))
            {
                Log("WTSEnableChildSessions(false) => " + ok + " (gle=" + err + "), status query failed (gle=" + queryError + ")");
                return 1;
            }
            Log("WTSEnableChildSessions(false) => " + ok + " (gle=" + err + "), enabled now = " + en0);
            return en0 ? 1 : 0;
        }
        if (args.Length > 0 && args[0] == "-check")
        {
            bool en2;
            int queryError;
            if (!ChildSessionNative.TryIsChildSessionsEnabled(out en2, out queryError))
            {
                Log("child sessions status query failed: Win32 error " + queryError);
                return 2;
            }
            Log("child sessions enabled = " + en2);
            return en2 ? 0 : 1;
        }
        if (args.Length > 0 && args[0] == "-resetpass") { try { File.Delete(credPath); } catch { } return 0; }

        bool en;
        int startupQueryError;
        if (!ChildSessionNative.TryIsChildSessionsEnabled(out en, out startupQueryError))
        {
            string message = "Could not query whether child sessions are enabled. Win32 error " + startupQueryError + ": " + new Win32Exception(startupQueryError).Message;
            Log(message);
            MessageBox.Show(message, "ChildStream", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        Log("startup: child sessions enabled = " + en);
        if (!en)
        {
            MessageBox.Show("Child sessions are not enabled.\nRun once from an elevated prompt:  ChildStream.exe -enable", "ChildStream");
            return 1;
        }

        Application.EnableVisualStyles();

        string authorizationPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChildStream", "active-child-session.json");
        var authorizationRetry = new ChildSessionAuthorizationRetry(TimeSpan.FromSeconds(10));
        Process launcherProcess = Process.GetCurrentProcess();
        int launcherProcessId = launcherProcess.Id;
        DateTime launcherStartTimeUtc = launcherProcess.StartTime.ToUniversalTime();
        launcherProcess.Dispose();
        Application.ApplicationExit += (s, e) => { authorizationRetry.OnDisconnected(); ChildSessionAuthorizationStore.Delete(authorizationPath); };

        DisplayConfig displayConfig;
        try
        {
            displayConfig = DisplayConfig.Load(Path.Combine(baseDir, "display.cfg"));
        }
        catch (FormatException ex)
        {
            MessageBox.Show(ex.Message, "ChildStream", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string account = Environment.MachineName + @"\" + Environment.UserName;
        string pw = LoadPassword();
        if (pw == null)
        {
            pw = PromptPassword(account);
            if (pw == null) return 1;
            SavePassword(pw);
        }

        bool[] endRequested = { false };
        var f = new Form { Text = "Child Session", Width = 1360, Height = 820 };
        Icon appIcon = SystemIcons.Application;
        try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        f.Icon = appIcon;
        var tray = new NotifyIcon { Icon = appIcon, Visible = true, Text = "Child Session" };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Show", null, (s, e) => { f.Show(); f.WindowState = FormWindowState.Normal; f.Activate(); });
        ToolStripMenuItem reconnectItem = new ToolStripMenuItem("Reconnect now");
        menu.Items.Add(reconnectItem);
        menu.Items.Add("Forget saved password", null, (s, e) => { try { File.Delete(credPath); } catch { } tray.ShowBalloonTip(2000, "Child Session", "Password cleared. Restart the app.", ToolTipIcon.Info); });
        menu.Items.Add("End session (sign out, closes games)", null, (s, e) =>
        {
            if (MessageBox.Show("Sign out the child session? All apps running in it will close.", "Child Session", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            endRequested[0] = true;
            authorizationRetry.OnDisconnected();
            ChildSessionAuthorizationStore.Delete(authorizationPath);
            uint childSessionId;
            int error;
            if (!ChildSessionNative.TryLogoffChildSession(out childSessionId, out error))
            {
                string message = "Could not sign out the child session. Win32 error " + error + ": " + new Win32Exception(error).Message;
                Log("signout: " + message);
                MessageBox.Show(message, "Child Session", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            else Log("signed out child session " + childSessionId);
            var quitTimer = new Timer { Interval = 3000 };
            quitTimer.Tick += delegate { tray.Visible = false; Application.Exit(); };
            quitTimer.Start();
        });
        menu.Items.Add("Exit", null, (s, e) => { tray.Visible = false; Application.Exit(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (s, e) => { f.Show(); f.WindowState = FormWindowState.Normal; f.Activate(); };

        f.Resize += (s, e) => { if (f.WindowState == FormWindowState.Minimized) { f.Hide(); tray.ShowBalloonTip(1500, "Child Session", "Still running - session stays alive. Double-click to restore.", ToolTipIcon.Info); } };
        f.Show();

        var rdp = new RdpBox { Dock = DockStyle.Fill };
        f.Controls.Add(rdp);
        rdp.CreateControl();
        dynamic ocx = rdp.Ocx;

        bool wantReconnect = true;
        Action connect = () =>
        {
            try
            {
                ocx.Server = "localhost";
                ocx.UserName = account;
                ocx.AdvancedSettings2.ClearTextPassword = pw;
                int dw = displayConfig.Width, dh = displayConfig.Height, scale = displayConfig.Scale;
                ocx.DesktopWidth = dw;
                ocx.DesktopHeight = dh;
                try { ocx.AdvancedSettings2.SmartSizing = true; } catch { }
                if (scale > 0)
                {
                    try
                    {
                        object ds = (uint)scale;
                        var extS = (IMsRdpExtendedSettings)rdp.Ocx;
                        extS.put_Property("DesktopScaleFactor", ref ds);
                        object dev = (uint)180;
                        extS.put_Property("DeviceScaleFactor", ref dev);
                        Log("scale " + scale + "% applied");
                    }
                    catch (Exception ex) { Log("scale: " + ex.Message); }
                }
                try { ocx.ColorDepth = 32; } catch { }
                try { ocx.AdvancedSettings7.EnableCredSspSupport = true; } catch { }
                object v = true;
                var ext = (IMsRdpExtendedSettings)rdp.Ocx;
                ext.put_Property("ConnectToChildSession", ref v);
                Log("connecting as " + account + "...");
                ocx.Connect();
            }
            catch (Exception ex) { Log("connect failed: " + ex.Message); }
        };

        reconnectItem.Click += (s, e) => { try { if ((int)ocx.Connected != 0) ocx.Disconnect(); } catch { } };

        int last = -1;
        DateTime lastAttempt = DateTime.MinValue;
        var timer = new Timer { Interval = 2000 };
        timer.Tick += delegate
        {
            try
            {
                int state = (int)ocx.Connected;
                DateTime nowUtc = DateTime.UtcNow;
                if (state != last)
                {
                    last = state;
                    Log("state -> " + state);
                    f.Text = state == 1 ? "Child Session - connected" : "Child Session - state " + state;
                    if (state == 1)
                        authorizationRetry.OnConnected(nowUtc);
                    else if (state == 0)
                    {
                        authorizationRetry.OnDisconnected();
                        ChildSessionAuthorizationStore.Delete(authorizationPath);
                    }
                }
                if (state == 1 && !endRequested[0] && authorizationRetry.ShouldAttempt(nowUtc))
                {
                    uint childSessionId;
                    int error;
                    if (ChildSessionNative.TryGetChildSessionId(out childSessionId, out error))
                    {
                        ChildSessionAuthorizationStore.Write(authorizationPath, childSessionId, launcherProcessId, launcherStartTimeUtc, nowUtc);
                        authorizationRetry.MarkIssued();
                        Log("authorized child session " + childSessionId);
                    }
                    else Log("child session identification failed: Win32 error " + error);
                }
                if (state == 0 && wantReconnect && !endRequested[0] && (DateTime.Now - lastAttempt).TotalSeconds > 5)
                {
                    lastAttempt = DateTime.Now;
                    Log("auto-reconnect");
                    connect();
                }
            }
            catch (Exception ex) { Log("poll: " + ex.Message); }
        };
        timer.Start();

        f.FormClosing += (s, e) => { wantReconnect = false; authorizationRetry.OnDisconnected(); ChildSessionAuthorizationStore.Delete(authorizationPath); tray.Visible = false; };
        connect();
        Application.Run(f);
        return 0;
    }
}
