// winarchy-daemon.exe: background helper started by GlazeWM.
//
//  * Super key  - stops Windows opening the Start menu when Super is pressed, so
//                 Super+key combos never leave Start open behind them (Omarchy
//                 behaviour: Super alone does nothing; Ctrl+Esc still opens Start).
//  * Taskbar    - auto-hides and hides the Windows taskbar while running, and puts
//                 it back when stopped.
//  * Autotile   - Hyprland "dwindle"-style splits: a tiling window that gains focus
//                 gets a split direction matching its shape, so the next window
//                 halves it along its longer edge.
//
//   winarchy-daemon                    run (single instance)
//   winarchy-daemon --stop             stop the running daemon and restore the taskbar
//   winarchy-daemon --taskbar          toggle the taskbar (also: winarchy taskbar)
//   winarchy-daemon --restore-taskbar  show the taskbar and restore auto-hide (no daemon needed)
//   winarchy-daemon --awake            toggle "stay awake" (no sleep, no screen off)
//   winarchy-daemon --nightlight       toggle night light (a warm 4000 K colour filter)
//
//  * Bar watchdog - restarts Zebar if it runs without its local web server (the grey bar).
//  * Reminders  - pops up reminders.json entries (written by `winarchy remind`) when they're due.
//  * TileGuard  - puts a tiled window back in its tile when the app resizes it (VLC on play).
//  * Drop-down terminal - Super+` shows / hides Windows Terminal's quake window (opened with
//                 the title "winarchy-dropdown", which GlazeWM's window rules ignore).
//
// Options live in settings.json next to the exe:
//   { "hideTaskbar": true, "blockStartMenu": true, "autotile": true, "quakeTerminal": true,
//     "barWatchdog": true, "keepTiles": true, "stayAwake": false, "nightLight": false }
//
// Written for the C# 5 compiler that ships with .NET Framework (no SDK needed).

using System;
using System.Collections.Generic;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Drawing;

static class Daemon
{
    static readonly string Dir = Path.GetDirectoryName(Application.ExecutablePath);
    static readonly string SettingsPath = Path.Combine(Dir, "settings.json");
    static readonly string OriginalAutoHidePath = Path.Combine(Dir, ".taskbar-autohide-before");
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    static Dictionary<string, object> settings;
    static Control ui;

    [STAThread]
    static void Main(string[] args)
    {
        string arg = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        if (arg == "--stop") { Signal(@"Local\winarchy-daemon-stop"); return; }
        if (arg == "--taskbar") { Signal(@"Local\winarchy-daemon-taskbar"); return; }
        if (arg == "--awake") { Signal(@"Local\winarchy-daemon-awake"); return; }
        if (arg == "--nightlight") { Signal(@"Local\winarchy-daemon-nightlight"); return; }
        if (arg == "--restore-taskbar") { Taskbar.Restore(OriginalAutoHidePath); return; }

        bool created;
        using (new Mutex(true, @"Local\winarchy-daemon", out created))
        {
            if (!created) return;
            settings = LoadSettings();

            ui = new Control();
            ui.CreateControl();
            IntPtr force = ui.Handle;

            SuperKey.BlockStart = Flag("blockStartMenu", true);
            SuperKey.Quake = Flag("quakeTerminal", true);
            if (SuperKey.BlockStart || SuperKey.Quake) SuperKey.Install(ui);

            // Toggles (Omarchy's Super+Ctrl+I "stay awake" and its night light), kept in settings.json
            // so the bar can show them and they survive a restart.
            Awake.Set(Flag("stayAwake", false));
            NightLight.Set(Flag("nightLight", false));
            var nightTimer = new System.Windows.Forms.Timer { Interval = 5000 };
            nightTimer.Tick += delegate { NightLight.Reapply(); }; // displays reset their colours on sleep / reconnect
            nightTimer.Start();
            OnEvent(@"Local\winarchy-daemon-awake", delegate { Awake.Set(ToggleSetting("stayAwake", false)); });
            OnEvent(@"Local\winarchy-daemon-nightlight", delegate { NightLight.Set(ToggleSetting("nightLight", false)); });

            Reminders.Start(Dir);
            if (Flag("barWatchdog", true)) BarWatchdog.Start();

            var taskbarTimer = new System.Windows.Forms.Timer { Interval = 1000 };
            taskbarTimer.Tick += delegate { if (Flag("hideTaskbar", true)) Taskbar.Hide(OriginalAutoHidePath); };
            taskbarTimer.Start();
            if (Flag("hideTaskbar", true)) Taskbar.Hide(OriginalAutoHidePath);

            OnEvent(@"Local\winarchy-daemon-stop", delegate
            {
                Taskbar.Restore(OriginalAutoHidePath);
                SuperKey.Remove();
                NightLight.Set(false);
                Awake.Set(false);
                Application.ExitThread();
            });
            OnEvent(@"Local\winarchy-daemon-taskbar", delegate
            {
                if (ToggleSetting("hideTaskbar", true)) Taskbar.Hide(OriginalAutoHidePath); else Taskbar.Restore(OriginalAutoHidePath);
            });

            Autotile.Enabled = Flag("autotile", true);
            Autotile.Tidy = Flag("tidyWorkspaces", true);
            if (Autotile.Enabled || Autotile.Tidy)
            {
                var t = new Thread(Autotile.Loop) { IsBackground = true };
                t.Start();
            }

            if (Flag("keepTiles", true)) TileGuard.Start(); // hook runs on this (UI) thread's message loop

            Application.Run();
        }
    }

    static void Signal(string name)
    {
        EventWaitHandle ev;
        if (EventWaitHandle.TryOpenExisting(name, out ev)) ev.Set();
    }

    // Runs `action` on the UI thread each time the named event is set.
    static void OnEvent(string name, MethodInvoker action)
    {
        var ev = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        var t = new Thread(() =>
        {
            while (true)
            {
                ev.WaitOne();
                try { ui.BeginInvoke(action); } catch { }
            }
        }) { IsBackground = true };
        t.Start();
    }

    static bool Flag(string key, bool fallback)
    {
        object v;
        return settings != null && settings.TryGetValue(key, out v) && v is bool ? (bool)v : fallback;
    }

    static Dictionary<string, object> LoadSettings()
    {
        try
        {
            var d = Json.DeserializeObject(SafeFile.Read(SettingsPath) ?? "") as Dictionary<string, object>;
            if (d != null) return d;
        }
        catch { }
        return new Dictionary<string, object>();
    }

    // Flips a true/false setting and returns its new value. Others (winarchy.exe, the installer)
    // write settings.json too, so it's re-read and saved under the shared file lock.
    static bool ToggleSetting(string key, bool fallback)
    {
        bool on = !fallback;
        try
        {
            SafeFile.Locked(SettingsPath, delegate
            {
                settings = LoadSettings();
                on = !Flag(key, fallback);
                settings[key] = on;
                var sb = new StringBuilder("{\n");
                int i = 0;
                foreach (var kv in settings)
                {
                    sb.Append("  " + Json.Serialize(kv.Key) + ": " + Json.Serialize(kv.Value));
                    sb.Append(++i < settings.Count ? ",\n" : "\n");
                }
                SafeFile.Write(SettingsPath, sb.Append("}\n").ToString());
            });
        }
        catch { }
        return on;
    }
}

// Windows opens Start when the Super key is released without any other key
// having gone through. GlazeWM swallows the keys of its Super+key bindings,
// so Windows thinks Super was tapped alone. Injecting an unassigned key
// (0xE8, the same "menu mask" key AutoHotkey uses) as soon as Super goes down
// tells Windows the press was used, so Start never opens from the Super key.
static class SuperKey
{
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    const int WH_KEYBOARD_LL = 13;
    const int VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_MASK = 0xE8;

    static readonly HookProc Proc = Callback; // kept alive for the GC
    static IntPtr hook;
    static bool superDown;
    static Control Target;   // the main UI thread (drop-down terminal)
    static Control hookUi;   // the hook's own thread (mask key)
    static Thread thread;

    static void SendMask()
    {
        keybd_event(VK_MASK, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MASK, 0, 2, UIntPtr.Zero);
    }

    // The hook runs on a thread that does nothing else. Windows quietly removes a low-level hook
    // whose thread is too slow to answer, and the main thread talks to Explorer, sets gamma ramps
    // and reads files: one stall there (Explorer hanging, say) would bring Start back on Super.
    public static void Install(Control uiThread)
    {
        Target = uiThread;
        if (thread != null) return;
        var ready = new ManualResetEvent(false);
        thread = new Thread(() =>
        {
            hookUi = new Control();
            hookUi.CreateControl();
            IntPtr force = hookUi.Handle;
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, Proc, GetModuleHandle(null), 0);
            ready.Set();
            Application.Run();
        }) { IsBackground = true, Name = "keyboard hook" };
        thread.Start();
        ready.WaitOne(3000);
    }

    public static void Remove()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    public static bool BlockStart = true, Quake = true;
    const int VK_OEM_3 = 0xC0; // stands for "the key below Esc" in Callback, whatever the layout

    static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            int vk = Marshal.ReadInt32(lParam); // KBDLLHOOKSTRUCT.vkCode
            // The key below Esc (` on US keyboards, ^ on German, ² on French, ¬ on UK) by its
            // position, which is the same on every layout; its key code is not.
            if (Marshal.ReadInt32(lParam, 4) == 0x29 && (Marshal.ReadInt32(lParam, 8) & 1) == 0) vk = VK_OEM_3;
            else if (vk == VK_OEM_3) vk = 0;
            int msg = wParam.ToInt32();
            bool down = msg == 0x100 || msg == 0x104; // WM_KEYDOWN, WM_SYSKEYDOWN
            if (vk == VK_LWIN || vk == VK_RWIN)
            {
                if (down && !superDown)
                {
                    superDown = true;
                    // Inject after this callback returns, so Windows sees Super down
                    // first and the mask key second. Injecting from inside the
                    // callback lands too early and does nothing.
                    if (BlockStart && hookUi != null) hookUi.BeginInvoke((MethodInvoker)SendMask);
                }
                else if (!down) superDown = false;
            }
            // Super+`: the drop-down terminal (Omarchy's Quake console). Handled here rather than by
            // Windows Terminal's own shortcut, so GlazeWM never tiles it (see Dropdown).
            else if (vk == VK_OEM_3 && superDown && Quake)
            {
                if (down && !graveDown && Target != null) Target.BeginInvoke((MethodInvoker)Dropdown.Toggle);
                graveDown = down;
                return new IntPtr(1);
            }
            if (vk == VK_OEM_3 && !down) graveDown = false;

            // Super+W on the drop-down terminal closes it. GlazeWM ignores that window, so its own
            // Super+W would close the tiled window behind it instead; this key never reaches it.
            if (vk == VK_W && Quake)
            {
                if (down && superDown && (wSwallowed || Dropdown.InFront()))
                {
                    if (!wSwallowed) Dropdown.Close();
                    wSwallowed = true;
                    return new IntPtr(1);
                }
                if (!down && wSwallowed) { wSwallowed = false; return new IntPtr(1); }
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    const int VK_W = 0x57;
    static bool graveDown; // ignore key repeat
    static bool wSwallowed;
}

// Drop-down terminal: Windows Terminal's quake window, opened with a fixed tab title that
// GlazeWM's window rules ignore (so it drops down from the top instead of tiling). Super+`
// shows it, hides it when it's in front, or brings it forward when it's behind.
static class Dropdown
{
    public const string Title = "winarchy-dropdown";

    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    static IntPtr hwnd;
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    static bool IsDropdown(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        var cls = new StringBuilder(64);
        GetClassName(h, cls, 64);
        if (cls.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return false;
        var title = new StringBuilder(256);
        GetWindowText(h, title, 256);
        return title.ToString() == Title;
    }

    // Called from the keyboard hook: only cheap window calls, nothing that waits.
    public static bool InFront() { return IsDropdown(GetForegroundWindow()); }

    public static void Close()
    {
        IntPtr h = GetForegroundWindow();
        if (IsDropdown(h)) PostMessage(h, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
    }

    static IntPtr Find()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            var cls = new StringBuilder(64);
            GetClassName(h, cls, 64);
            if (cls.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;
            var title = new StringBuilder(256);
            GetWindowText(h, title, 256);
            if (title.ToString() == Title) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void Toggle()
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) hwnd = Find();
        if (hwnd == IntPtr.Zero)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("wt.exe",
                    "-w _quake nt --title " + Title + " --suppressApplicationTitle") { UseShellExecute = true });
            }
            catch { }
            return;
        }
        if (IsWindowVisible(hwnd) && GetForegroundWindow() == hwnd)
        {
            ShowWindow(hwnd, 0); // SW_HIDE
            return;
        }
        // Terminal hides the quake window itself when it loses focus, minimised; restore it then.
        ShowWindow(hwnd, IsIconic(hwnd) ? 9 : 5);  // SW_RESTORE : SW_SHOW
        // Windows only lets the program with the latest input take the foreground; a tap of Alt
        // counts (the same trick AutoHotkey uses).
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(hwnd);
    }
}

// Omarchy has no taskbar: set it to auto-hide (so windows get the full screen)
// and hide its windows outright (so it never slides back in).
static class Taskbar
{
    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public int left, top, right, bottom;
        public IntPtr lParam;
    }

    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);

    const uint ABM_GETSTATE = 4, ABM_SETSTATE = 10;
    const int ABS_AUTOHIDE = 1, ABS_ALWAYSONTOP = 2;

    static List<IntPtr> Windows()
    {
        var list = new List<IntPtr>();
        EnumWindows((h, l) =>
        {
            var sb = new StringBuilder(64);
            GetClassName(h, sb, sb.Capacity);
            string c = sb.ToString();
            if (c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    static bool AutoHide
    {
        get
        {
            var d = new APPBARDATA { cbSize = Marshal.SizeOf(typeof(APPBARDATA)) };
            return ((ulong)SHAppBarMessage(ABM_GETSTATE, ref d) & ABS_AUTOHIDE) != 0;
        }
        set
        {
            var d = new APPBARDATA
            {
                cbSize = Marshal.SizeOf(typeof(APPBARDATA)),
                hWnd = FindWindow("Shell_TrayWnd", null),
                lParam = new IntPtr(value ? ABS_AUTOHIDE : ABS_ALWAYSONTOP)
            };
            SHAppBarMessage(ABM_SETSTATE, ref d);
        }
    }

    // Called every second. Asking Explorer for the auto-hide state is a round trip to its process,
    // so that happens when the taskbar is new (Explorer restarted) and every 30 seconds after.
    static IntPtr lastTray;
    static int sinceCheck;

    public static void Hide(string originalPath)
    {
        IntPtr tray = FindWindow("Shell_TrayWnd", null);
        if (tray == IntPtr.Zero) return; // Explorer not up yet
        if (tray != lastTray || ++sinceCheck >= 30)
        {
            if (!AutoHide)
            {
                if (!File.Exists(originalPath)) File.WriteAllText(originalPath, "0");
                AutoHide = true;
            }
            else if (!File.Exists(originalPath)) File.WriteAllText(originalPath, "1");
            lastTray = tray;
            sinceCheck = 0;
        }
        foreach (var h in Windows())
            if (IsWindowVisible(h)) ShowWindow(h, 0); // SW_HIDE
    }

    public static void Restore(string originalPath)
    {
        lastTray = IntPtr.Zero;
        foreach (var h in Windows()) ShowWindow(h, 8); // SW_SHOWNA
        if (File.Exists(originalPath))
        {
            bool before = File.ReadAllText(originalPath).Trim() == "1";
            if (AutoHide != before) AutoHide = before;
            File.Delete(originalPath);
        }
    }
}

// Listens on GlazeWM's IPC socket and sets the split direction on focus.
static class Autotile
{
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    public static void Loop()
    {
        while (true)
        {
            try { Run().Wait(); } catch { }
            Thread.Sleep(2000); // GlazeWM not running yet, or restarted
        }
    }

    static async Task Run()
    {
        using (var ws = new ClientWebSocket())
        {
            await ws.ConnectAsync(new Uri("ws://127.0.0.1:6123"), CancellationToken.None);
            // Not monitor_updated: that also fires when an app bar (Zebar) docks, and tidying then
            // would undo workspaces moved on purpose (Super+Alt+Arrows).
            await Send(ws, "sub -e focus_changed monitor_added monitor_removed");
            if (Tidy) WorkspaceTidy.Soon(5000); // GlazeWM just started (or the daemon did)
            var buf = new byte[16384];
            while (ws.State == WebSocketState.Open)
            {
                var ms = new MemoryStream();
                WebSocketReceiveResult r;
                do
                {
                    r = await ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
                    if (r.MessageType == WebSocketMessageType.Close) return;
                    ms.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);

                string dir = null;
                try { dir = Decide(Encoding.UTF8.GetString(ms.ToArray())); } catch { } // an odd message shouldn't drop the connection
                if (dir != null) await Send(ws, "command set-tiling-direction " + dir);
            }
        }
    }

    public static bool Enabled = true, Tidy = true;

    static string Decide(string message)
    {
        var msg = Json.DeserializeObject(message) as Dictionary<string, object>;
        var data = Get(msg, "data");
        if (data == null) return null;
        string type = Str(data, "eventType") ?? "";
        // Monitors come and go (sleep, unplug): once they've settled, put workspaces back.
        if (type.StartsWith("monitor_")) { if (Tidy) WorkspaceTidy.Soon(8000); return null; }
        if (!Enabled || type != "focus_changed") return null;
        var win = Get(data, "focusedContainer");
        if (win == null || Str(win, "type") != "window") return null;
        var state = Get(win, "state");
        if (state == null || Str(state, "type") != "tiling") return null;
        double w = Convert.ToDouble(win["width"]), h = Convert.ToDouble(win["height"]);
        return w >= h ? "horizontal" : "vertical";
    }

    static Dictionary<string, object> Get(Dictionary<string, object> d, string key)
    {
        object v;
        return d != null && d.TryGetValue(key, out v) ? v as Dictionary<string, object> : null;
    }

    static string Str(Dictionary<string, object> d, string key)
    {
        object v;
        return d.TryGetValue(key, out v) && v != null ? v.ToString() : null;
    }

    static Task Send(ClientWebSocket ws, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        return ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
    }
}

// GlazeWM binds workspaces to monitors by number (bind_to_monitor: 1). While a monitor is asleep
// or unplugged the numbers shift, workspaces move to whichever monitor now has their number, and
// they stay there when it comes back (workspace 1 ending up on a side monitor). Once monitors
// have settled, this moves each workspace back to its own monitor, then puts focus back.
static class WorkspaceTidy
{
    static readonly string Cli = Glzr.GlazeCli;
    static readonly string Config = Environment.ExpandEnvironmentVariables(@"%USERPROFILE%\.glzr\glazewm\config.yaml");
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    static readonly object gate = new object();
    static System.Threading.Timer timer;
    static int busy;

    // Runs after `ms` of quiet; each new call restarts the wait.
    public static void Soon(int ms)
    {
        lock (gate)
        {
            if (timer == null) timer = new System.Threading.Timer(Run, null, ms, Timeout.Infinite);
            else timer.Change(ms, Timeout.Infinite);
        }
    }

    class Mon { public double X, Y; public List<string> Workspaces = new List<string>(); }

    static Dictionary<string, int> Bindings()
    {
        var map = new Dictionary<string, int>();
        string text = SafeFile.Read(Config) ?? "";
        foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(text,
            @"-\s*name:\s*['""]?([^'""\r\n]+?)['""]?\s*\r?\n\s*bind_to_monitor:\s*(\d+)"))
            map[m.Groups[1].Value] = int.Parse(m.Groups[2].Value);
        return map;
    }

    internal static string Glaze(string args)
    {
        var psi = new System.Diagnostics.ProcessStartInfo(Cli, args)
        {
            CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, StandardOutputEncoding = Encoding.UTF8
        };
        using (var p = System.Diagnostics.Process.Start(psi))
        {
            string output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return output;
        }
    }

    // Monitors in GlazeWM's order (the numbers bind_to_monitor uses), with their workspaces.
    static List<Mon> Monitors(out string focused)
    {
        focused = null;
        var list = new List<Mon>();
        var top = Json.DeserializeObject(Glaze("query monitors")) as Dictionary<string, object>;
        var data = top["data"] as Dictionary<string, object>;
        foreach (var o in (object[])data["monitors"])
        {
            var m = (Dictionary<string, object>)o;
            var mon = new Mon
            {
                X = Convert.ToDouble(m["x"]) + Convert.ToDouble(m["width"]) / 2,
                Y = Convert.ToDouble(m["y"]) + Convert.ToDouble(m["height"]) / 2
            };
            foreach (var c in (object[])m["children"])
            {
                var w = (Dictionary<string, object>)c;
                string name = Convert.ToString(w["name"]);
                mon.Workspaces.Add(name);
                if (w.ContainsKey("hasFocus") && w["hasFocus"] is bool && (bool)w["hasFocus"]) focused = name;
            }
            list.Add(mon);
        }
        return list;
    }

    static void Run(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) == 1) return;
        try
        {
            var bind = Bindings();
            if (bind.Count == 0 || !File.Exists(Cli)) return;
            string focus = null;
            bool moved = false;
            // One move per pass, then look again: a move can take a step through a middle monitor.
            for (int pass = 0; pass < 8; pass++)
            {
                string focusedNow;
                var mons = Monitors(out focusedNow);
                if (focus == null) focus = focusedNow;
                string name = null, dir = null;
                for (int i = 0; i < mons.Count && name == null; i++)
                    foreach (string ws in mons[i].Workspaces)
                    {
                        int want;
                        if (!bind.TryGetValue(ws, out want) || want == i || want >= mons.Count) continue;
                        double dx = mons[want].X - mons[i].X, dy = mons[want].Y - mons[i].Y;
                        dir = Math.Abs(dx) >= Math.Abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up");
                        name = ws;
                        break;
                    }
                if (name == null) break;
                Glaze("command focus --workspace " + name);
                Glaze("command move-workspace --direction " + dir);
                moved = true;
            }
            if (moved && focus != null) Glaze("command focus --workspace " + focus);
        }
        catch { }
        finally { Interlocked.Exchange(ref busy, 0); }
    }
}

// Some apps resize their own window after GlazeWM has tiled it: VLC grows to the video's size when
// a file starts playing. GlazeWM doesn't notice, so the window spills behind its neighbours and the
// video looks cut off. This watches windows move and, when a tiled window no longer fits its tile,
// asks GlazeWM to redraw, which puts it back.
static class TileGuard
{
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    struct RECT { public int L, T, R, B; }
    const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B, WINEVENT_SKIPOWNPROCESS = 2, GA_ROOT = 2;
    const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, Slack = 4;

    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    static readonly WinEventProc proc = OnMove; // a field, so the delegate outlives the hook
    static readonly object gate = new object();
    static readonly HashSet<IntPtr> moved = new HashSet<IntPtr>();
    // Per window: when we last redrew for it, and for which tile and size. A window that can't
    // shrink to its tile (a big minimum size) stays off; don't keep redrawing for it.
    static readonly Dictionary<long, List<DateTime>> recent = new Dictionary<long, List<DateTime>>();
    static readonly Dictionary<long, string> lastFix = new Dictionary<long, string>();
    static System.Threading.Timer timer;
    static int busy;

    public static void Start()
    {
        timer = new System.Threading.Timer(Check, null, Timeout.Infinite, Timeout.Infinite);
        SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero, proc, 0, 0, WINEVENT_SKIPOWNPROCESS);
    }

    static void OnMove(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        // Fires for every move of anything (carets, scroll bars...): keep this cheap.
        if (idObject != 0 || idChild != 0 || hwnd == IntPtr.Zero) return;
        if (GetAncestor(hwnd, GA_ROOT) != hwnd || !IsWindowVisible(hwnd)) return;
        lock (gate) moved.Add(hwnd);
        timer.Change(500, Timeout.Infinite); // after things settle
    }

    static void Check(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) == 1) { timer.Change(500, Timeout.Infinite); return; }
        try
        {
            // A mouse button down means a drag or resize in progress; GlazeWM handles those itself.
            if (GetAsyncKeyState(0x01) < 0 || GetAsyncKeyState(0x02) < 0) { timer.Change(500, Timeout.Infinite); return; }
            var handles = new HashSet<long>();
            lock (gate) { foreach (var h in moved) handles.Add(h.ToInt64()); moved.Clear(); }
            if (handles.Count == 0) return;

            var top = Json.DeserializeObject(WorkspaceTidy.Glaze("query windows")) as Dictionary<string, object>;
            var data = top == null ? null : top["data"] as Dictionary<string, object>;
            if (data == null) return;
            bool redraw = false;
            foreach (var o in (object[])data["windows"])
            {
                var w = (Dictionary<string, object>)o;
                long handle = Convert.ToInt64(w["handle"]);
                var st = w["state"] as Dictionary<string, object>;
                if (!handles.Contains(handle) || st == null || Convert.ToString(st["type"]) != "tiling") continue;
                int x = Convert.ToInt32(w["x"]), y = Convert.ToInt32(w["y"]);
                int width = Convert.ToInt32(w["width"]), height = Convert.ToInt32(w["height"]);
                RECT r;
                if (DwmGetWindowAttribute(new IntPtr(handle), DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0) continue;
                if (Math.Abs(r.L - x) <= Slack && Math.Abs(r.T - y) <= Slack &&
                    Math.Abs(r.R - r.L - width) <= Slack && Math.Abs(r.B - r.T - height) <= Slack) continue;
                if (Allowed(handle, string.Join(",", x, y, width, height, r.L, r.T, r.R, r.B))) redraw = true;
            }
            if (redraw) WorkspaceTidy.Glaze("command wm-redraw");
        }
        catch { }
        finally { Interlocked.Exchange(ref busy, 0); }
    }

    // At most 3 redraws a minute per window, and not twice within 10 s for the exact same mismatch.
    static bool Allowed(long handle, string key)
    {
        var now = DateTime.UtcNow;
        List<DateTime> times;
        if (!recent.TryGetValue(handle, out times)) recent[handle] = times = new List<DateTime>();
        times.RemoveAll(t => (now - t).TotalSeconds > 60);
        string last;
        if (times.Count >= 3 || (times.Count > 0 && lastFix.TryGetValue(handle, out last) && last == key && (now - times[times.Count - 1]).TotalSeconds < 10))
            return false;
        times.Add(now);
        lastFix[handle] = key;
        if (recent.Count > 200) // closed windows
            foreach (var k in new List<long>(recent.Keys))
                if (recent[k].TrueForAll(t => (now - t).TotalSeconds > 60)) { recent.Remove(k); lastFix.Remove(k); }
        return true;
    }
}

// Stay awake: no sleep and no screen-off while on (like Omarchy's Super+Ctrl+I).
static class Awake
{
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;

    // Must be called on the UI thread: the request lasts as long as that thread does.
    public static void Set(bool on)
    {
        SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED : ES_CONTINUOUS);
    }
}

// Night light: a warm colour filter, like Omarchy's hyprsunset toggle (4000 K). Windows' own
// night light can't be switched from code on current builds, so this sets each display's gamma
// ramp instead (what f.lux does). Displays drop the ramp on sleep or reconnect, so the daemon
// puts it back every few seconds while it's on.
static class NightLight
{
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateDC(string driver, string device, string output, IntPtr init);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool SetDeviceGammaRamp(IntPtr dc, ushort[] ramp);
    [DllImport("gdi32.dll")] static extern bool GetDeviceGammaRamp(IntPtr dc, ushort[] ramp);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, int index, ref DISPLAY_DEVICE dd, int flags);

    static bool on;
    // 4000 K as RGB multipliers. Some systems refuse ramps that far from neutral, so milder
    // ones follow as fallbacks.
    static readonly double[][] Warm = { new[] { 1.0, 0.808, 0.651 }, new[] { 1.0, 0.859, 0.729 }, new[] { 1.0, 0.9, 0.8 } };

    static ushort[] Ramp(double r, double g, double b)
    {
        var ramp = new ushort[768];
        for (int i = 0; i < 256; i++)
        {
            ramp[i] = (ushort)Math.Min(65535, i * 257 * r);
            ramp[256 + i] = (ushort)Math.Min(65535, i * 257 * g);
            ramp[512 + i] = (ushort)Math.Min(65535, i * 257 * b);
        }
        return ramp;
    }

    static List<string> Displays()
    {
        var list = new List<string>();
        var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE)) };
        for (int i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++)
        {
            if ((dd.StateFlags & 1) != 0) list.Add(dd.DeviceName); // attached to the desktop
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return list;
    }

    // Returns how many displays have the wanted ramp.
    public static int Apply(bool warm)
    {
        int done = 0;
        foreach (string name in Displays())
        {
            IntPtr dc = CreateDC(null, name, null, IntPtr.Zero);
            if (dc == IntPtr.Zero) continue;
            try
            {
                if (!warm) { if (SetDeviceGammaRamp(dc, Ramp(1, 1, 1))) done++; continue; }
                var have = new ushort[768];
                bool got = GetDeviceGammaRamp(dc, have);
                foreach (var m in Warm)
                {
                    var want = Ramp(m[0], m[1], m[2]);
                    if (got && have[767] == want[767] && have[511] == want[511]) { done++; break; } // already set
                    if (SetDeviceGammaRamp(dc, want)) { done++; break; }
                }
            }
            finally { DeleteDC(dc); }
        }
        return done;
    }

    public static void Set(bool value)
    {
        bool was = on;
        on = value;
        if (on) Apply(true);
        else if (was) Apply(false);
    }

    public static void Reapply() { if (on) Apply(true); }
}

// Reminders (Omarchy's Super+Ctrl+R): `winarchy remind` writes reminders.json, the bar's clock
// panel lists them, and this pops each one up in the theme's colours when it's due.
static class Reminders
{
    static string path, themePath;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static int shown;

    public static void Start(string dir)
    {
        path = Path.Combine(dir, "reminders.json");
        themePath = Path.Combine(dir, "theme.json");
        var timer = new System.Windows.Forms.Timer { Interval = 1000 };
        timer.Tick += delegate { Check(); };
        timer.Start();
    }

    // The file is only read again when it changes or the next reminder is due.
    static DateTime lastStamp;
    static long nextDue = long.MaxValue;

    static void Check()
    {
        try
        {
            if (!File.Exists(path)) return;
            long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            if (File.GetLastWriteTimeUtc(path) == lastStamp && now < nextDue) return;
            var due = new List<string>();
            // `winarchy remind` writes this file too; the shared lock keeps a reminder added just
            // now from being lost when the fired ones are taken out.
            SafeFile.Locked(path, delegate
            {
                var list = Json.DeserializeObject(SafeFile.Read(path) ?? "[]") as object[] ?? new object[0];
                var keep = new List<object>();
                long next = long.MaxValue;
                foreach (var o in list)
                {
                    var r = o as Dictionary<string, object>;
                    if (r == null) continue;
                    long when = 0;
                    try { when = Convert.ToInt64(r.ContainsKey("due") ? r["due"] : 0); } catch { }
                    if (when <= now) due.Add(r.ContainsKey("text") ? Convert.ToString(r["text"]) : "Reminder");
                    else { keep.Add(r); next = Math.Min(next, when); }
                }
                if (due.Count > 0) SafeFile.Write(path, Json.Serialize(keep));
                nextDue = next;
                lastStamp = File.GetLastWriteTimeUtc(path);
            });
            foreach (string text in due) Show(text);
        }
        catch { }
    }

    static Color ThemeColor(Dictionary<string, object> theme, string name, string fallback)
    {
        object v;
        try { if (theme != null && theme.TryGetValue(name, out v) && v is string) return ColorTranslator.FromHtml((string)v); } catch { }
        return ColorTranslator.FromHtml(fallback);
    }

    public static void Show(string text)
    {
        Dictionary<string, object> theme = null;
        try
        {
            var all = Json.DeserializeObject(File.ReadAllText(themePath, Encoding.UTF8)) as Dictionary<string, object>;
            if (all != null) theme = (all.ContainsKey("colors") ? all["colors"] : all) as Dictionary<string, object>;
        }
        catch { }
        Color bg = ThemeColor(theme, "background", "#1a1b26"), fg = ThemeColor(theme, "foreground", "#c0caf5");
        Color accent = ThemeColor(theme, "accent", "#7aa2f7"), muted = ThemeColor(theme, "muted", "#565f89");

        var area = Screen.PrimaryScreen.WorkingArea;
        float scale;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96f;
        int w = (int)(340 * scale), h = (int)(86 * scale), pad = (int)(14 * scale);
        var form = new Form
        {
            FormBorderStyle = FormBorderStyle.None,
            ShowInTaskbar = false,
            TopMost = true,
            StartPosition = FormStartPosition.Manual,
            BackColor = accent,
            Padding = new Padding(1),
            Size = new Size(w, h),
            Location = new Point(area.Right - w - (int)(12 * scale), area.Top + (int)(12 * scale) + shown * (h + (int)(8 * scale))),
            Text = "winarchy reminder",
        };
        var inner = new Panel { Dock = DockStyle.Fill, BackColor = bg, Padding = new Padding(pad, (int)(10 * scale), pad, (int)(8 * scale)) };
        var font = new Font("JetBrainsMono NFM", 10f);
        if (font.Name != "JetBrainsMono NFM") font = new Font("Consolas", 10f);
        var title = new Label { Dock = DockStyle.Top, AutoSize = false, Height = (int)(20 * scale), ForeColor = accent, Font = font, Text = "Reminder  " + DateTime.Now.ToString("t") };
        var body = new Label { Dock = DockStyle.Fill, ForeColor = fg, Font = font, Text = text, AutoEllipsis = true };
        var hint = new Label { Dock = DockStyle.Bottom, AutoSize = false, Height = (int)(16 * scale), ForeColor = muted, Font = new Font(font.FontFamily, 8f), Text = "click to dismiss" };
        inner.Controls.Add(body);
        inner.Controls.Add(title);
        inner.Controls.Add(hint);
        form.Controls.Add(inner);
        EventHandler close = delegate { form.Close(); };
        foreach (Control c in new Control[] { form, inner, title, body, hint }) c.Click += close;
        form.FormClosed += delegate { if (shown > 0) shown--; };
        shown++;
        form.Show();
        System.Media.SystemSounds.Exclamation.Play();
    }
}

// Bar watchdog: now and then Zebar starts without its local web server (127.0.0.1:6124), and the
// bar shows only a grey "can't connect" page. Every 5 seconds, if Zebar has been running for a
// while but nothing listens on that port, stop it and start it again (with a pause, so the old
// one is fully gone). If the bar is hidden on purpose (no Zebar running), nothing happens.
static class BarWatchdog
{
    const int Port = 6124;
    static System.Threading.Timer timer;
    static int busy;
    static readonly List<DateTime> restarts = new List<DateTime>();
    static readonly string ZebarExe = Glzr.ZebarExe;

    public static void Start()
    {
        timer = new System.Threading.Timer(Check, null, 20000, 5000);
        spaceTimer = new System.Threading.Timer(KeepSpace, null, 10000, 2000);
    }

    // When monitors sleep and wake (or are unplugged and plugged back in), Windows can forget the
    // strip the bar reserves at the top of the screen while the bar itself stays put. GlazeWM then
    // tiles windows over the bar. Every 2 seconds: if the bar is showing at the top of the main
    // screen but the screen's work area no longer leaves room for it, ask Windows to reserve it
    // again. GlazeWM moves the windows down by itself once the work area changes.
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct APPBARDATA { public int cb; public IntPtr hWnd; public uint msg; public uint edge; public RECT rc; public IntPtr lParam; }
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref RECT r, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    const uint ABM_SETPOS = 3, ABE_TOP = 1, SPI_GETWORKAREA = 0x30;
    static System.Threading.Timer spaceTimer;
    static int spaceBusy;
    static DateTime lastFix = DateTime.MinValue;

    static void KeepSpace(object state)
    {
        if (Interlocked.Exchange(ref spaceBusy, 1) == 1) return;
        IntPtr oldDpi = IntPtr.Zero;
        try
        {
            oldDpi = SetThreadDpiAwarenessContext(new IntPtr(-4)); // physical pixels, like the bar's rect
            IntPtr bar = FindWindow(null, "Zebar - winarchy / bar");
            if (bar == IntPtr.Zero || !IsWindowVisible(bar) || IsIconic(bar)) return; // bar hidden on purpose
            RECT r, work = new RECT();
            if (!GetWindowRect(bar, out r) || !SystemParametersInfo(SPI_GETWORKAREA, 0, ref work, 0)) return;
            int height = r.B - r.T;
            // Only a bar docked along the top of the main screen (which starts at 0,0).
            if (r.T != 0 || r.L > 0 || height <= 0 || height > 200) return;
            if (work.T >= r.B) return; // room is still kept: the usual case
            if (DateTime.Now - lastFix < TimeSpan.FromSeconds(30)) return; // didn't help last time
            lastFix = DateTime.Now;
            var d = new APPBARDATA { hWnd = bar, edge = ABE_TOP, rc = r };
            d.cb = Marshal.SizeOf(d);
            SHAppBarMessage(ABM_SETPOS, ref d);
        }
        catch { }
        finally
        {
            if (oldDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(oldDpi);
            Interlocked.Exchange(ref spaceBusy, 0);
        }
    }

    static bool Listening()
    {
        try
        {
            foreach (var ep in System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners())
                if (ep.Port == Port) return true;
        }
        catch { return true; } // can't tell: leave it alone
        return false;
    }

    static void Check(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) == 1) return;
        System.Diagnostics.Process[] zebar = null;
        try
        {
            if (Listening()) return; // the usual case, and cheaper to ask than listing processes
            zebar = System.Diagnostics.Process.GetProcessesByName("zebar");
            if (zebar.Length == 0) return;
            // Give a freshly started Zebar time to open its server.
            foreach (var p in zebar)
                try { if (DateTime.Now - p.StartTime < TimeSpan.FromSeconds(15)) return; } catch { }
            // At most 3 restarts in 10 minutes, in case something else is wrong.
            restarts.RemoveAll(t => DateTime.Now - t > TimeSpan.FromMinutes(10));
            if (restarts.Count >= 3) return;
            restarts.Add(DateTime.Now);

            foreach (var p in zebar) { try { p.Kill(); } catch { } }
            foreach (var p in zebar) { try { p.WaitForExit(5000); } catch { } }
            Thread.Sleep(4000); // its WebView2 processes and port must be gone first
            var again = System.Diagnostics.Process.GetProcessesByName("zebar");
            foreach (var p in again) p.Dispose();
            if (again.Length == 0)
                using (System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(ZebarExe) { UseShellExecute = true })) { }
        }
        catch { }
        finally
        {
            if (zebar != null) foreach (var p in zebar) p.Dispose();
            Interlocked.Exchange(ref busy, 0);
        }
    }
}
