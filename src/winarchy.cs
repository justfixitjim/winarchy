// winarchy.exe: Omarchy-style menus and app launchers for GlazeWM on Windows 11.
//
//   winarchy                         open the main menu (menu.json next to the exe)
//   winarchy <page-id>               open the menu at a page, e.g. "system"
//   winarchy keys                    searchable cheat sheet built from the GlazeWM config
//   winarchy launcher                search apps, open windows, Settings pages and the menu,
//                                    and do quick maths (Super+Space)
//   winarchy launch browser          new window of the default browser
//   winarchy launch browser-private  private window of the default browser
//   winarchy launch editor           VS Code if installed, otherwise Notepad
//   winarchy launch app <Name> [id]  start an app by its Start-menu name; offers a
//                                    winget install (package id) if it is missing
//   winarchy taskbar                 show/hide the Windows taskbar (via winarchy-daemon)
//   winarchy toggle awake            stay awake: no sleep or screen-off (via winarchy-daemon)
//   winarchy toggle nightlight       warm colour filter (via winarchy-daemon)
//   winarchy toggle dnd              Windows' do not disturb
//   winarchy toggle bar              hide / show the top bar (Zebar)
//   winarchy toggle gaps             no gaps between windows / gaps back
//   winarchy remind add <min> <text> pop up <text> in <min> minutes (winarchy-daemon shows it)
//   winarchy remind remove <id>      cancel one reminder; `remind clear` cancels all
//   winarchy panel <name>            open a bar panel: clock, audio, bluetooth, network, ...
//   winarchy agent                   start the default coding agent in a new Terminal window
//   winarchy agent set <name>        pick the default agent (claude, codex, opencode, ...)
//
// Running a menu mode while a menu is open closes it, so hotkeys toggle.
// Written for the C# 5 compiler that ships with .NET Framework (no SDK needed).

using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class Node
{
    public string Id, Label, Hint, Run, Args, Glaze, Terminal, Page, Builtin;
    public string Key;      // usage-history identity (e.g. "app:Spotify")
    public string Provider; // submenu filled in code: "apps" or "settings"
    public bool Hidden;     // only shows up in search results (open windows)
    public bool Confirm;
    public List<Node> Items;
    public Node Parent;
    public bool IsMenu { get { return Items != null; } }
}

class Row
{
    public Node Node;
    public string Text;
    public string Hint;
    public int Score;
    public int Order;
}

static class Native
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(Point pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
}

class MenuForm : Form
{
    // Colours of the current theme (~\.glzr\winarchy\theme.json, written by tools\theme.ps1),
    // falling back to Tokyo Night (Omarchy's default).
    static Color Bg = ThemeColor("background", "#1a1b26");
    static Color InputBg = ThemeColor("surface", "#16161e");
    static Color Fg = ThemeColor("foreground", "#c0caf5");
    static Color Dim = ThemeColor("muted", "#565f89");
    static Color Accent = ThemeColor("accent", "#7aa2f7");
    static Color SelBg = ThemeColor("selection", "#283457");
    static Color Warn = ThemeColor("red", "#f7768e");

    public static void LoadTheme()
    {
        themeColors = null;
        Bg = ThemeColor("background", "#1a1b26"); InputBg = ThemeColor("surface", "#16161e");
        Fg = ThemeColor("foreground", "#c0caf5"); Dim = ThemeColor("muted", "#565f89");
        Accent = ThemeColor("accent", "#7aa2f7"); SelBg = ThemeColor("selection", "#283457");
        Warn = ThemeColor("red", "#f7768e");
    }

    static Dictionary<string, object> themeColors;
    static Color ThemeColor(string name, string fallback)
    {
        if (themeColors == null)
        {
            themeColors = new Dictionary<string, object>();
            try
            {
                string p = Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "theme.json");
                var t = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(p));
                var c = t["colors"] as Dictionary<string, object>;
                if (c != null) themeColors = c;
            }
            catch { }
        }
        object v;
        try { if (themeColors.TryGetValue(name, out v) && v is string) return ColorTranslator.FromHtml((string)v); }
        catch { }
        return ColorTranslator.FromHtml(fallback);
    }

    readonly Node root;
    Node current;
    readonly bool keysMode;
    readonly float s;
    readonly TextBox input;
    readonly ListBox list;
    readonly Label crumb;
    readonly Label status;
    readonly Font rowFont, hintFont;
    List<Row> rows = new List<Row>();
    Node pendingConfirm;
    bool armed;

    public MenuForm(Node root, Node start, bool keysMode, float scale)
    {
        this.root = root;
        this.current = start;
        this.keysMode = keysMode;
        s = scale;

        string family = PickFont("JetBrainsMono Nerd Font", "CaskaydiaMono Nerd Font", "Cascadia Mono", "Consolas");
        rowFont = new Font(family, 15 * s, GraphicsUnit.Pixel);
        hintFont = new Font(family, 13 * s, GraphicsUnit.Pixel);

        Text = "winarchy";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        BackColor = Accent; // 2px accent border shows around the inner panel
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        int w = (int)(Math.Round((keysMode ? 760 : 620) * s));
        int h = (int)(Math.Round(530 * s));
        Size = new Size(w, h);
        int b = Math.Max(2, (int)(2 * s));
        Padding = new Padding(b);

        var panel = new Panel { Dock = DockStyle.Fill, BackColor = Bg, Padding = new Padding((int)(14 * s)) };
        Controls.Add(panel);

        crumb = new Label { Dock = DockStyle.Top, Height = (int)(24 * s), ForeColor = Accent, Font = hintFont, TextAlign = ContentAlignment.MiddleLeft };
        var inputWrap = new Panel { Dock = DockStyle.Top, Height = (int)(40 * s), BackColor = InputBg, Padding = new Padding((int)(10 * s), (int)(9 * s), (int)(10 * s), 0) };
        input = new TextBox { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, BackColor = InputBg, ForeColor = Fg, Font = rowFont };
        inputWrap.Controls.Add(input);
        var gap = new Panel { Dock = DockStyle.Top, Height = (int)(8 * s), BackColor = Bg };
        status = new Label { Dock = DockStyle.Bottom, Height = (int)(22 * s), ForeColor = Dim, Font = hintFont, TextAlign = ContentAlignment.MiddleLeft };
        list = new ListBox
        {
            Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, BackColor = Bg, ForeColor = Fg,
            DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = (int)(32 * s), IntegralHeight = false, Font = rowFont
        };
        panel.Controls.Add(list);
        panel.Controls.Add(status);
        panel.Controls.Add(gap);
        panel.Controls.Add(inputWrap);
        panel.Controls.Add(crumb);

        list.HandleCreated += delegate { Native.SetWindowTheme(list.Handle, "DarkMode_Explorer", null); };
        list.DrawItem += DrawRow;
        list.MouseDoubleClick += delegate { Activate(SelectedNode()); };
        list.MouseDown += delegate { input.Focus(); };
        input.TextChanged += delegate { pendingConfirm = null; Refill(); };
        KeyDown += OnKey;
        Deactivate += delegate { if (armed) Close(); };
        Activated += delegate { armed = true; input.Focus(); };
        Shown += delegate { ForceForeground(); };

        Refill();
    }

    static string PickFont(params string[] names)
    {
        // Asking for each font is much faster than listing every installed font:
        // GDI+ substitutes a different family when one is missing.
        foreach (var n in names)
            using (var f = new Font(n, 10f))
                if (string.Equals(f.Name, n, StringComparison.OrdinalIgnoreCase)) return n;
        return "Consolas";
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int dark = 1, square = 1; // DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWCP_DONOTROUND
        Native.DwmSetWindowAttribute(Handle, 20, ref dark, 4);
        Native.DwmSetWindowAttribute(Handle, 33, ref square, 4);
    }

    void ForceForeground()
    {
        IntPtr fg = Native.GetForegroundWindow();
        uint fgThread = Native.GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint me = Native.GetCurrentThreadId();
        if (fgThread != me) Native.AttachThreadInput(fgThread, me, true);
        Native.SetForegroundWindow(Handle);
        if (fgThread != me) Native.AttachThreadInput(fgThread, me, false);
        if (Native.GetForegroundWindow() != Handle)
        {
            // Synthesised input makes this process the last input receiver,
            // which Windows requires before it allows a focus change.
            Native.keybd_event(0x12, 0, 0, UIntPtr.Zero);
            Native.keybd_event(0x12, 0, 2, UIntPtr.Zero);
            Native.SetForegroundWindow(Handle);
        }
        BringToFront();
        base.Activate();
        input.Focus();
    }

    // ── Rows ────────────────────────────────────────────────────────────

    // Open windows arrive just after the menu opens; only a search shows them.
    public void Refilter() { if (input.Text.Length > 0) Refill(); }

    void Refill()
    {
        string q = input.Text.Trim();
        var result = new List<Row>();
        int order = 0;
        if (Program.IsLauncher && current == root)
        {
            result = LauncherRows(q);
        }
        else if (q.Length == 0)
        {
            foreach (var n in current.Items)
                result.Add(new Row { Node = n, Text = n.Label, Hint = HintFor(n), Order = order++ });
        }
        else
        {
            foreach (var pair in Flatten(current, ""))
            {
                int sc = Score(q, pair.Value.Label, pair.Key, pair.Value.Hint);
                if (sc > 0) result.Add(new Row { Node = pair.Value, Text = pair.Key, Hint = HintFor(pair.Value), Score = sc, Order = order++ });
            }
            result = result.OrderByDescending(r => r.Score).ThenBy(r => r.Order).ToList();
        }
        rows = result;
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var r in rows) list.Items.Add(r);
        list.EndUpdate();
        if (rows.Count > 0) list.SelectedIndex = 0;

        var path = new List<string>();
        for (var n = current; n != null; n = n.Parent) path.Insert(0, n.Label);
        crumb.Text = string.Join("  ›  ", path);
        status.ForeColor = Dim;
        status.Text = keysMode
            ? rows.Count + " keybindings   type to filter   Esc close"
            : Program.IsLauncher && current == root
                ? "type to search everything   =2+2 maths   Enter select   Esc close"
                : "↑↓ move   Enter select   " + (current != root ? "Backspace back   " : "") + "Esc close";
    }

    // Launcher view: frequent things first when empty; otherwise everything scored,
    // nudged by how often you've opened it, with a calculator row for maths.
    List<Row> LauncherRows(string q)
    {
        var result = new List<Row>();
        int order = 0;
        var history = Program.History;
        if (q.Length == 0)
        {
            foreach (var n in root.Items.Where(n => !n.Hidden))
                result.Add(new Row { Node = n, Text = n.Label, Hint = HintFor(n), Order = order++ });
            return result;
        }

        string math = Program.Calculate(q);
        if (math != null)
            result.Add(new Row
            {
                Node = new Node { Label = "= " + math, Hint = "Enter copies", Builtin = "copy:" + math, Parent = root },
                Text = "= " + math, Hint = "Enter copies", Score = int.MaxValue, Order = order++
            });

        foreach (var pair in Flatten(current, ""))
        {
            var n = pair.Value;
            int sc = Score(q, n.Label, pair.Key, n.Hint);
            if (sc <= 0) continue;
            int uses;
            if (n.Key != null && history.TryGetValue(n.Key, out uses)) sc += Math.Min(uses, 20) * 15;
            // Apps, settings pages and windows read best by name alone; menu items keep their path.
            bool byName = n.Hidden || (n.Parent != null && n.Parent.Provider != null);
            result.Add(new Row { Node = n, Text = byName ? n.Label : pair.Key, Hint = HintFor(n), Score = sc, Order = order++ });
        }
        return result.OrderByDescending(r => r.Score).ThenBy(r => r.Order).Take(200).ToList();
    }

    static string HintFor(Node n)
    {
        if (n.Hint != null) return n.Hint;
        return n.IsMenu ? "›" : "";
    }

    static IEnumerable<KeyValuePair<string, Node>> Flatten(Node n, string prefix)
    {
        foreach (var c in n.Items)
        {
            string label = prefix.Length > 0 ? prefix + "  ›  " + c.Label : c.Label;
            yield return new KeyValuePair<string, Node>(label, c);
            if (c.IsMenu)
                foreach (var d in Flatten(c, label)) yield return d;
        }
    }

    // Prefix > word-start > substring > in-order letters; hints count a little.
    static int Score(string q, string label, string path, string hint)
    {
        string l = label.ToLowerInvariant(), p = path.ToLowerInvariant(), ql = q.ToLowerInvariant();
        if (l.StartsWith(ql)) return 1000 - l.Length;
        if (Regex.IsMatch(l, @"(^|[\s\-/(])" + Regex.Escape(ql))) return 800 - l.Length;
        if (l.Contains(ql)) return 600 - l.Length;
        if (p.Contains(ql)) return 400 - p.Length;
        if (hint != null && hint.ToLowerInvariant().Contains(ql)) return 300;
        int i = 0;
        foreach (char ch in l) if (i < ql.Length && ch == ql[i]) i++;
        if (i == ql.Length && !ql.Contains(" ")) return 100 - l.Length / 4;
        return 0;
    }

    void DrawRow(object sender, DrawItemEventArgs e)
    {
        if (e.Index < 0 || e.Index >= rows.Count) return;
        var r = rows[e.Index];
        bool sel = (e.State & DrawItemState.Selected) != 0;
        var g = e.Graphics;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        using (var bgBrush = new SolidBrush(sel ? SelBg : Bg)) g.FillRectangle(bgBrush, e.Bounds);
        if (sel)
            using (var bar = new SolidBrush(Accent)) g.FillRectangle(bar, e.Bounds.X, e.Bounds.Y, Math.Max(3, (int)(3 * s)), e.Bounds.Height);

        int pad = (int)(12 * s);
        string hint = r.Hint ?? "";
        if (pendingConfirm != null && r.Node == pendingConfirm) hint = "Enter again to confirm";
        Size hintSize = TextRenderer.MeasureText(g, hint, hintFont);
        var hintRect = new Rectangle(e.Bounds.Right - hintSize.Width - pad, e.Bounds.Y, hintSize.Width + pad, e.Bounds.Height);
        var textRect = new Rectangle(e.Bounds.X + pad, e.Bounds.Y, e.Bounds.Width - hintRect.Width - pad * 2, e.Bounds.Height);
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(g, r.Text, rowFont, textRect, sel ? Color.White : Fg, flags);
        Color hc = (pendingConfirm != null && r.Node == pendingConfirm) ? Warn : (sel ? Accent : Dim);
        TextRenderer.DrawText(g, hint, hintFont, hintRect, hc, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPrefix);
    }

    Node SelectedNode()
    {
        int i = list.SelectedIndex;
        return (i >= 0 && i < rows.Count) ? rows[i].Node : null;
    }

    void MoveSel(int delta)
    {
        if (rows.Count == 0) return;
        int i = list.SelectedIndex + delta;
        if (delta == 1 || delta == -1) i = (i + rows.Count) % rows.Count;
        else i = Math.Max(0, Math.Min(rows.Count - 1, i));
        list.SelectedIndex = i;
    }

    void GoTo(Node n)
    {
        current = n;
        input.Text = "";
        Refill();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        int page = Math.Max(1, list.ClientSize.Height / list.ItemHeight - 1);
        bool handled = true;
        switch (e.KeyCode)
        {
            case Keys.Down: MoveSel(1); break;
            case Keys.Up: MoveSel(-1); break;
            case Keys.PageDown: MoveSel(page); break;
            case Keys.PageUp: MoveSel(-page); break;
            case Keys.Tab: MoveSel(e.Shift ? -1 : 1); break;
            case Keys.N: if (e.Control) MoveSel(1); else handled = false; break;
            case Keys.P: if (e.Control) MoveSel(-1); else handled = false; break;
            case Keys.J: if (e.Control) MoveSel(1); else handled = false; break;
            case Keys.K: if (e.Control) MoveSel(-1); else handled = false; break;
            case Keys.Enter: Activate(SelectedNode()); break;
            case Keys.Right:
                if (input.SelectionStart == input.Text.Length && SelectedNode() != null && SelectedNode().IsMenu) GoTo(SelectedNode());
                else handled = false;
                break;
            case Keys.Left:
            case Keys.Back:
                if (input.Text.Length == 0 && current.Parent != null) GoTo(current.Parent);
                else handled = false;
                break;
            case Keys.Escape:
                if (input.Text.Length > 0) input.Text = "";
                else Close();
                break;
            default: handled = false; break;
        }
        if (handled) { e.Handled = true; e.SuppressKeyPress = true; }
    }

    // ── Actions ─────────────────────────────────────────────────────────

    void Activate(Node n)
    {
        if (n == null) return;
        if (n.IsMenu) { GoTo(n); return; }
        if (n.Page != null)
        {
            if (n.Page == "keys") { Program.NextMode = "keys"; Close(); return; }
            if (n.Page == "launcher") { GoTo(root); return; }
            var target = Program.FindById(root, n.Page);
            if (target != null) GoTo(target);
            return;
        }
        if (n.Confirm && pendingConfirm != n)
        {
            pendingConfirm = n;
            list.Invalidate();
            return;
        }
        if (keysMode && n.Run == null && n.Glaze == null) return;
        try
        {
            Hide();
            if (Program.IsLauncher) Program.RecordUse(n);
            Program.Execute(n);
            Close();
        }
        catch (Exception ex)
        {
            Show();
            status.ForeColor = Warn;
            status.Text = "Failed: " + ex.Message;
        }
    }
}

static class Program
{
    static string Dir { get { return Path.GetDirectoryName(Application.ExecutablePath); } }

    static readonly bool Tracing = Environment.GetEnvironmentVariable("WINARCHY_TRACE") == "1";
    public static void Trace(string what)
    {
        if (!Tracing) return;
        double ms = (DateTime.Now - Process.GetCurrentProcess().StartTime).TotalMilliseconds;
        try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "winarchy-trace.log"), string.Format("{0,7:0} ms  {1}\r\n", ms, what)); } catch { }
    }

    static string GlazeCli { get { return Environment.ExpandEnvironmentVariables(@"%ProgramFiles%\glzr.io\GlazeWM\cli\glazewm.exe"); } }

    [STAThread]
    static void Main(string[] args)
    {
        Trace("main");
        string first = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        if (first == "taskbar")
        {
            EventWaitHandle ev;
            if (EventWaitHandle.TryOpenExisting(@"Local\winarchy-daemon-taskbar", out ev)) ev.Set();
            else MessageBox.Show("winarchy-daemon is not running, so the taskbar is not being managed.", "winarchy");
            return;
        }
        if (first == "toggle") { Toggles.Run(args.Length > 1 ? args[1].ToLowerInvariant() : "", Dir); return; }
        if (first == "remind") { Toggles.Remind(args, Dir); return; }
        if (first == "panel") { Toggles.Panel(args.Length > 1 ? args[1].ToLowerInvariant() : ""); return; }
        if (first == "agent") { Toggles.Agent(args, Dir); return; }
        if (first == "launch")
        {
            Prepared = Launcher.Run(args);
            if (Prepared == null) return;  // launched fine; otherwise show the install offer
            args = new[] { "prepared" };
        }

        if (first == "--resident") { RunResident(); return; }
        string request = args.Length > 0 ? args[0] : "";
        if (request != "prepared" && SendToResident(request)) { Trace("handed to resident"); return; }
        if (request != "prepared") StartResident();

        bool created;
        using (var mutex = new Mutex(true, @"Local\winarchy-menu", out created))
        {
            var closeEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\winarchy-menu-close");
            if (!created)
            {
                closeEvent.Set(); // hotkey pressed while open: close it
                return;
            }

            try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            var waiter = new Thread(() =>
            {
                while (true)
                {
                    closeEvent.WaitOne();
                    var f = openForm;
                    if (f != null) try { f.BeginInvoke((MethodInvoker)f.Close); } catch { }
                }
            });
            waiter.IsBackground = true;
            waiter.Start();

            NextMode = args.Length > 0 ? args[0] : "";
            while (NextMode != null)
            {
                string mode = NextMode;
                NextMode = null;
                if (!ShowOnce(mode)) return;
            }
        }
    }

    static volatile Form openForm;

    // Set by the form to switch view (e.g. Learn > Keybindings) without a new process.
    public static string NextMode;

    // A menu built in code (e.g. "Spotify isn't installed") instead of menu.json.
    static Node Prepared;

    static bool ShowOnce(string mode)
    {
        var form = BuildForm(mode);
        if (form == null) return false;
        Application.Run(form);
        openForm = null;
        return true;
    }

    static Form BuildForm(string mode)
    {
        MenuForm.LoadTheme();
        Node root, start;
        bool keys = mode == "keys";
        IsLauncher = !keys && mode != "prepared";
        try
        {
            if (IsLauncher)
            {
                root = BuildLauncher();
                start = (mode.Length > 0 && mode != "launcher" ? FindById(root, mode) : null) ?? root;
            }
            else if (keys)
            {
                root = LoadKeys();
                start = root;
            }
            else if (mode == "prepared")
            {
                root = Prepared;
                start = root;
            }
            else
            {
                root = LoadMenu();
                start = (mode.Length > 0 ? FindById(root, mode) : null) ?? root;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "winarchy", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return null;
        }

        Point cursor = Cursor.Position;
        uint dx = 96, dy = 96;
        try { Native.GetDpiForMonitor(Native.MonitorFromPoint(cursor, 2), 0, out dx, out dy); } catch { }
        Trace("menu built");
        var form = new MenuForm(root, start, keys, dx / 96f);
        Trace("form created");
        Rectangle wa = Screen.FromPoint(cursor).WorkingArea;
        form.Location = new Point(wa.X + (wa.Width - form.Width) / 2, wa.Y + (int)((wa.Height - form.Height) * 0.38));
        openForm = form;
        form.Shown += delegate { Trace("shown"); };
        if (IsLauncher) form.Shown += delegate { Launcher.RefreshCacheInBackground(); AddOpenWindows(root); };
        return form;
    }

    // ── Resident menu ───────────────────────────────────────────────────
    // A copy of winarchy stays running (hidden, already loaded), so Super+Space only has to
    // show a window instead of starting .NET and reading everything from scratch.

    const string PipeName = "winarchy-menu";

    static bool SendToResident(string mode)
    {
        Mutex m;
        if (!Mutex.TryOpenExisting(@"Local\winarchy-resident", out m)) return false;
        m.Dispose();
        try
        {
            Native.AllowSetForegroundWindow(-1); // let the resident copy take focus
            using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
            {
                pipe.Connect(300);
                var bytes = Encoding.UTF8.GetBytes(mode + "\n");
                pipe.Write(bytes, 0, bytes.Length);
                pipe.Flush();
            }
            return true;
        }
        catch { return false; }
    }

    static void StartResident()
    {
        Mutex m;
        if (Mutex.TryOpenExisting(@"Local\winarchy-resident", out m)) { m.Dispose(); return; }
        try { Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--resident") { UseShellExecute = false }); } catch { }
    }

    static Control residentUi;

    static void RunResident()
    {
        bool created;
        var mutex = new Mutex(true, @"Local\winarchy-resident", out created);
        if (!created) return;
        try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        residentUi = new Control();
        residentUi.CreateControl();
        var handle = residentUi.Handle;

        var listener = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using (var pipe = new NamedPipeServerStream(PipeName, PipeDirection.In, 1))
                    {
                        pipe.WaitForConnection();
                        string mode = new StreamReader(pipe, Encoding.UTF8).ReadLine() ?? "";
                        residentUi.BeginInvoke((MethodInvoker)delegate { OnResidentRequest(mode); });
                    }
                }
                catch { Thread.Sleep(200); }
            }
        });
        listener.IsBackground = true;
        listener.Start();

        // Warm up once (loads and compiles the code paths) so even the first Super+Space is quick.
        residentUi.BeginInvoke((MethodInvoker)delegate
        {
            try { using (var f = BuildForm("")) { } openForm = null; } catch { }
        });
        Application.Run();
        GC.KeepAlive(mutex);
    }

    static void OnResidentRequest(string mode)
    {
        var open = openForm;
        if (open != null) { open.Close(); return; } // hotkey pressed while open: close it
        ShowResident(mode);
    }

    static void ShowResident(string mode)
    {
        var form = BuildForm(mode);
        if (form == null) return;
        form.FormClosed += delegate
        {
            if (openForm == form) openForm = null;
            form.Dispose();
            if (NextMode != null) { string next = NextMode; NextMode = null; ShowResident(next); }
        };
        form.Show();
    }

    public static Node FindById(Node n, string id)
    {
        if (n.Id == id) return n;
        if (n.Items == null) return null;
        foreach (var c in n.Items)
        {
            var hit = FindById(c, id);
            if (hit != null) return hit;
        }
        return null;
    }

    public static void Execute(Node n)
    {
        if (n.Builtin == "none") return;
        if (n.Builtin != null && n.Builtin.StartsWith("copy:"))
        {
            Clipboard.SetText(n.Builtin.Substring(5));
            return;
        }
        if (n.Builtin != null && n.Builtin.StartsWith("focus:"))
        {
            var psi = new ProcessStartInfo(GlazeCli, "command focus --container-id " + n.Builtin.Substring(6)) { CreateNoWindow = true, UseShellExecute = false };
            using (var p = Process.Start(psi)) p.WaitForExit(3000);
            return;
        }
        if (n.Builtin == "sleep")
        {
            Application.SetSuspendState(PowerState.Suspend, false, false);
            return;
        }
        if (n.Glaze != null)
        {
            foreach (var cmd in n.Glaze.Split(new[] { " && " }, StringSplitOptions.RemoveEmptyEntries))
            {
                var psi = new ProcessStartInfo(GlazeCli, "command " + cmd) { CreateNoWindow = true, UseShellExecute = false };
                using (var p = Process.Start(psi)) p.WaitForExit(3000);
            }
        }
        if (n.Terminal != null)
        {
            // -EncodedCommand sidesteps quoting and wt's own ';' parsing.
            string b64 = Convert.ToBase64String(Encoding.Unicode.GetBytes(n.Terminal));
            string ps = "powershell -NoLogo -NoExit -EncodedCommand " + b64;
            bool hasWt = File.Exists(Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"));
            var psi = hasWt
                ? new ProcessStartInfo("wt.exe", ps) { UseShellExecute = true }
                : new ProcessStartInfo("powershell.exe", ps.Substring("powershell ".Length)) { UseShellExecute = true };
            Process.Start(psi);
        }
        if (n.Run != null)
        {
            var psi = new ProcessStartInfo(Expand(n.Run)) { UseShellExecute = true, WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
            if (n.Args != null) psi.Arguments = Expand(n.Args);
            string exe = Path.GetFileName(psi.FileName).ToLowerInvariant();
            if (exe == "cmd.exe" || exe == "powershell.exe" || exe == "shutdown.exe" || exe == "rundll32.exe")
                psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
        }
    }

    // ── Launcher (Super+Space) ──────────────────────────────────────────

    public static bool IsLauncher;

    static Dictionary<string, int> history;
    static string HistoryPath { get { return Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\winarchy\history.json"); } }

    public static Dictionary<string, int> History
    {
        get
        {
            if (history != null) return history;
            history = new Dictionary<string, int>();
            try
            {
                var raw = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(HistoryPath, Encoding.UTF8)) as Dictionary<string, object>;
                if (raw != null) foreach (var kv in raw) history[kv.Key] = Convert.ToInt32(kv.Value);
            }
            catch { }
            return history;
        }
    }

    public static void RecordUse(Node n)
    {
        if (n.Key == null) return;
        int c;
        History.TryGetValue(n.Key, out c);
        History[n.Key] = c + 1;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(HistoryPath));
            File.WriteAllText(HistoryPath, new JavaScriptSerializer().Serialize(History), Encoding.UTF8);
        }
        catch { }
    }

    // "2+2", "=15% * 80", "(3.5*4)/2" -> result text, or null if it isn't maths.
    public static string Calculate(string q)
    {
        string e = q.StartsWith("=") ? q.Substring(1) : q;
        e = e.Replace(",", "").Replace(" ", "");
        if (e.Length == 0 || !Regex.IsMatch(e, @"^[-+*/%().\d]+$")) return null;
        if (!q.StartsWith("=") && !Regex.IsMatch(e, @"\d[-+*/%]")) return null; // a plain number isn't maths
        e = Regex.Replace(e, @"(\d+(?:\.\d+)?)%", "($1/100)");                    // 15% -> 0.15
        try
        {
            object v = new DataTable().Compute(e, "");
            double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
            if (double.IsNaN(d) || double.IsInfinity(d)) return null;
            return d.ToString("G15", CultureInfo.InvariantCulture);
        }
        catch { return null; }
    }

    // The menu (Omarchy's layout, from menu.json) with its provider submenus filled in,
    // plus open windows that only appear when you search.
    static Node BuildLauncher()
    {
        Node root;
        try { root = LoadMenu(); }
        catch { root = new Node { Label = "winarchy", Items = new List<Node>() }; }
        Trace("menu.json loaded");

        var uris = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        CollectRuns(root, uris);
        FillProviders(root, uris);
        Trace("apps and settings added");

        windowsQuery = System.Threading.Tasks.Task.Run(() => QueryWindows());
        return root;
    }

    static System.Threading.Tasks.Task<List<string[]>> windowsQuery;

    static List<string[]> QueryWindows()
    {
        var found = new List<string[]>();
        try
        {
            var psi = new ProcessStartInfo(GlazeCli, "query windows")
            {
                CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, StandardOutputEncoding = Encoding.UTF8
            };
            using (var p = Process.Start(psi))
            {
                string json = p.StandardOutput.ReadToEnd();
                p.WaitForExit(2000);
                var top = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(json) as Dictionary<string, object>;
                var data = top["data"] as Dictionary<string, object>;
                foreach (var o in (object[])data["windows"])
                {
                    var w = (Dictionary<string, object>)o;
                    string title = w["title"] as string, proc = w["processName"] as string;
                    if (string.IsNullOrEmpty(title) || proc == "winarchy") continue;
                    found.Add(new[] { title, proc, Convert.ToString(w["id"]) });
                }
            }
        }
        catch { }
        return found;
    }

    static void AddOpenWindows(Node root)
    {
        var q = windowsQuery;
        var form = openForm;
        if (q == null || form == null) return;
        q.ContinueWith(t =>
        {
            try
            {
                form.BeginInvoke((MethodInvoker)delegate
                {
                    foreach (var w in t.Result)
                        root.Items.Add(new Node { Label = w[0], Hint = "Window \u00b7 " + w[1], Builtin = "focus:" + w[2], Key = "win:" + w[1], Hidden = true, Parent = root });
                    var mf = form as MenuForm;
                    if (mf != null) mf.Refilter();
                });
            }
            catch { }
        });
    }

    static void CollectRuns(Node n, HashSet<string> uris)
    {
        if (n.Run != null && n.Args == null) uris.Add(n.Run);
        if (n.Items != null) foreach (var c in n.Items) CollectRuns(c, uris);
    }

    static void FillProviders(Node n, HashSet<string> uris)
    {
        if (n.Items == null) return;
        if (n.Provider == "apps")
        {
            foreach (var kv in Launcher.Apps().OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase))
            {
                if (kv.Value.StartsWith("http", StringComparison.OrdinalIgnoreCase)) continue;
                if (kv.Key.StartsWith("Uninstall", StringComparison.OrdinalIgnoreCase)) continue;
                n.Items.Add(new Node { Label = kv.Key, Hint = "App", Run = "explorer.exe", Args = "shell:AppsFolder\\" + kv.Value, Key = "app:" + kv.Key, Parent = n });
            }
        }
        else if (n.Provider == "themes")
        {
            string themes = Path.Combine(Dir, "themes"), current = "";
            try
            {
                var cur = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Dir, "theme.json")));
                current = cur["id"] as string ?? "";
            }
            catch { current = "tokyo-night"; }
            string script = Path.Combine(Dir, "tools", "theme.ps1");
            if (Directory.Exists(themes))
                foreach (var f in Directory.GetFiles(themes, "*.json").OrderBy(f => f))
                {
                    string id = Path.GetFileNameWithoutExtension(f), name = id, mode = "";
                    try
                    {
                        var t = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                        name = t["name"] as string ?? id;
                        mode = t.ContainsKey("mode") ? t["mode"] as string : "";
                    }
                    catch { }
                    n.Items.Add(new Node
                    {
                        Label = name, Hint = id == current ? "current" : mode, Key = "theme:" + id, Parent = n,
                        Run = "powershell.exe",
                        Args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" " + id
                    });
                }
        }
        else if (n.Provider == "agents")
        {
            // Coding agents for the default-agent key (Super+Shift+Ctrl+A); the installed ones first.
            string current = Toggles.DefaultAgent(Dir);
            foreach (var a in Toggles.Agents.OrderBy(a => Toggles.Installed(a[0]) ? 0 : 1))
            {
                bool installed = Toggles.Installed(a[0]);
                n.Items.Add(new Node
                {
                    Label = a[1], Key = "agent:" + a[0], Parent = n,
                    Hint = a[0] == current ? "default" : installed ? a[0] : "not installed",
                    Run = Application.ExecutablePath, Args = "agent set " + a[0]
                });
            }
        }
        else if (n.Provider == "settings")
        {
            foreach (var st in SettingsPages)
            {
                if (st.Length == 2 && uris.Contains(st[1])) continue; // already elsewhere in the menu
                n.Items.Add(new Node { Label = st[0], Hint = "Setting", Run = st[1], Args = st.Length > 2 ? st[2] : null, Key = "set:" + st[0], Parent = n });
            }
        }
        foreach (var c in n.Items.ToList()) FillProviders(c, uris);
    }

    static readonly string[][] SettingsPages =
    {
        new[] { "Display", "ms-settings:display" }, new[] { "Sound", "ms-settings:sound" },
        new[] { "Bluetooth & devices", "ms-settings:bluetooth" }, new[] { "Wi-Fi", "ms-settings:network-wifi" },
        new[] { "Network status", "ms-settings:network-status" }, new[] { "Ethernet", "ms-settings:network-ethernet" },
        new[] { "VPN", "ms-settings:network-vpn" }, new[] { "Power & battery", "ms-settings:powersleep" },
        new[] { "Storage", "ms-settings:storagesense" }, new[] { "Notifications", "ms-settings:notifications" },
        new[] { "Night light", "ms-settings:nightlight" }, new[] { "Colors / dark mode", "ms-settings:colors" },
        new[] { "Background / wallpaper", "ms-settings:personalization-background" }, new[] { "Themes", "ms-settings:themes" },
        new[] { "Lock screen", "ms-settings:lockscreen" }, new[] { "Taskbar", "ms-settings:taskbar" },
        new[] { "Fonts", "ms-settings:fonts" }, new[] { "Installed apps", "ms-settings:appsfeatures" },
        new[] { "Default apps", "ms-settings:defaultapps" }, new[] { "Startup apps", "ms-settings:startupapps" },
        new[] { "Your account", "ms-settings:yourinfo" }, new[] { "Sign-in options", "ms-settings:signinoptions" },
        new[] { "Date & time", "ms-settings:dateandtime" }, new[] { "Language & region", "ms-settings:regionlanguage" },
        new[] { "Keyboard", "ms-settings:keyboard" }, new[] { "Mouse", "ms-settings:mousetouchpad" },
        new[] { "Printers & scanners", "ms-settings:printers" }, new[] { "Game Mode", "ms-settings:gaming-gamemode" },
        new[] { "Privacy & security", "ms-settings:privacy" }, new[] { "Microphone access", "ms-settings:privacy-microphone" },
        new[] { "Camera access", "ms-settings:privacy-webcam" }, new[] { "Windows Update", "ms-settings:windowsupdate" },
        new[] { "Windows Security", "windowsdefender:" }, new[] { "Recovery", "ms-settings:recovery" },
        new[] { "About this PC", "ms-settings:about" }, new[] { "Multitasking / Snap", "ms-settings:multitasking" },
        new[] { "Clipboard", "ms-settings:clipboard" }, new[] { "Graphics", "ms-settings:display-advancedgraphics" },
        new[] { "Remote Desktop", "ms-settings:remotedesktop" }, new[] { "Optional features", "ms-settings:optionalfeatures" },
        new[] { "Animation effects", "ms-settings:easeofaccess-visualeffects" },
        new[] { "Control Panel", "control.exe" }, new[] { "Device Manager", "devmgmt.msc" },
        new[] { "Disk Management", "diskmgmt.msc" }, new[] { "Services", "services.msc" },
        new[] { "Event Viewer", "eventvwr.msc" }, new[] { "Sound control panel", "mmsys.cpl" },
        new[] { "Environment variables", "rundll32.exe", "sysdm.cpl,EditEnvironmentVariables" },
    };

    static string Expand(string v)
    {
        return Environment.ExpandEnvironmentVariables(v.Replace("{menu}", Path.Combine(Dir, "menu.json")).Replace("{dir}", Dir));
    }

    // ── menu.json ───────────────────────────────────────────────────────

    static Node LoadMenu()
    {
        string path = Path.Combine(Dir, "menu.json");
        var json = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
        if (json == null || !json.ContainsKey("root")) throw new Exception("menu.json needs a \"root\" object.");
        return ToNode((Dictionary<string, object>)json["root"], null);
    }

    static Node ToNode(Dictionary<string, object> d, Node parent)
    {
        Func<string, string> str = k => d.ContainsKey(k) && d[k] != null ? d[k].ToString() : null;
        var n = new Node
        {
            Id = str("id"), Label = str("label") ?? "?", Hint = str("hint"), Run = str("run"), Args = str("args"),
            Glaze = str("glaze"), Terminal = str("terminal"), Page = str("page"), Builtin = str("builtin"),
            Confirm = d.ContainsKey("confirm") && d["confirm"] is bool && (bool)d["confirm"], Parent = parent
        };
        n.Provider = str("provider");
        if (d.ContainsKey("items") || n.Provider != null)
        {
            n.Items = new List<Node>();
            if (d.ContainsKey("items"))
                foreach (var o in (object[])d["items"]) n.Items.Add(ToNode((Dictionary<string, object>)o, n));
        }
        return n;
    }

    // ── keys mode: parse the GlazeWM config ─────────────────────────────

    static Node LoadKeys()
    {
        var root = new Node { Label = "Keybindings", Items = new List<Node>() };
        string cfg = Environment.ExpandEnvironmentVariables(@"%USERPROFILE%\.glzr\glazewm\config.yaml");
        string section = null, desc = null;
        bool inKeys = false;
        string pendingCmd = null;
        foreach (var raw in File.ReadAllLines(cfg))
        {
            string line = raw.TrimEnd();
            if (line.Length > 0 && !char.IsWhiteSpace(line[0]) && !line.StartsWith("#"))
            {
                inKeys = line.StartsWith("keybindings:");
                continue;
            }
            if (!inKeys) continue;
            var t = line.Trim();
            if (t.StartsWith("#"))
            {
                var c = t.TrimStart('#').Trim();
                var sec = Regex.Match(c, @"^─+\s*(.+?)\s*─*$");
                if (sec.Success) { section = sec.Groups[1].Value; desc = null; }
                else desc = c;
                continue;
            }
            var cm = Regex.Match(t, @"^-\s*commands:\s*\[(.*)\]");
            if (cm.Success) { pendingCmd = cm.Groups[1].Value; continue; }
            var bm = Regex.Match(t, @"^bindings:\s*\[(.*)\]");
            if (bm.Success)
            {
                var keys = Regex.Matches(bm.Groups[1].Value, "'([^']*)'|\"([^\"]*)\"").Cast<Match>()
                    .Select(m => Pretty(m.Groups[1].Success && m.Groups[1].Length > 0 ? m.Groups[1].Value : m.Groups[2].Value));
                string label = desc ?? (pendingCmd ?? "").Trim('\'', '"', ' ');
                if (section != null) label = section + "  ›  " + label;
                root.Items.Add(new Node { Label = label, Hint = string.Join("  or  ", keys), Parent = root });
                desc = null; pendingCmd = null;
            }
        }

        // Shortcuts that belong to Windows or PowerToys rather than GlazeWM.
        string[,] extra =
        {
            { "Dictation (Handy): hold to talk, release to paste", "Right Ctrl" },
            { "Start menu", "Ctrl + Esc" },
            { "Lock screen", "Super + L" },
            { "Clipboard history", "Super + V" },
            { "Screenshot (region)", "Super + Shift + S" },
            { "Screenshot (Snipping Tool)", "PrtScn" },
            { "Emoji picker", "Super + ." },
            { "Settings", "Super + I" },
            { "Notifications", "Super + N" },
            { "Quick settings (Wi-Fi, sound, Bluetooth)", "Super + A" },
            { "Always on top (PowerToys)", "Super + Ctrl + T" },
            { "Advanced paste (PowerToys)", "Super + Shift + V" },
            { "Peek file preview (PowerToys)", "Ctrl + Space" },
        };
        for (int i = 0; i < extra.GetLength(0); i++)
            root.Items.Add(new Node { Label = "Windows  ›  " + extra[i, 0], Hint = extra[i, 1], Parent = root });
        return root;
    }

    static string Pretty(string binding)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "lwin", "Super" }, { "rwin", "Super" }, { "shift", "Shift" }, { "alt", "Alt" }, { "ctrl", "Ctrl" },
            { "control", "Ctrl" }, { "enter", "Enter" }, { "escape", "Esc" }, { "space", "Space" }, { "tab", "Tab" },
            { "left", "←" }, { "right", "→" }, { "up", "↑" }, { "down", "↓" },
            { "oem_minus", "-" }, { "oem_plus", "=" }, { "oem_comma", "," }, { "oem_period", "." },
            { "oem_question", "/" }, { "oem_semicolon", ";" }, { "oem_quotes", "'" }, { "oem_tilde", "`" },
            { "oem_open_brackets", "[" }, { "oem_close_brackets", "]" }, { "oem_pipe", "\\" }, { "back", "Backspace" },
        };
        return string.Join(" + ", binding.Split('+').Select(k =>
        {
            string v;
            if (map.TryGetValue(k.Trim(), out v)) return v;
            return k.Trim().Length == 1 ? k.Trim().ToUpperInvariant() : char.ToUpperInvariant(k.Trim()[0]) + k.Trim().Substring(1);
        }));
    }
}

// Starts apps in a machine-independent way, so the same GlazeWM config works on any PC.
static class Launcher
{
    // Returns null when something was launched, or a menu offering to install the app.
    public static Node Run(string[] args)
    {
        string what = args.Length > 1 ? args[1].ToLowerInvariant() : "";
        if (what == "browser" || what == "browser-private")
        {
            Browser(what == "browser-private");
            return null;
        }
        if (what == "editor")
        {
            string code = VsCode();
            if (code != null) Start(code, null);
            else if (!App("Visual Studio Code")) Start("notepad.exe", null);
            return null;
        }
        if (what == "edit" && args.Length > 2)
        {
            // Open a file or folder: VS Code if installed, else Notepad / Explorer.
            string path = Environment.ExpandEnvironmentVariables(args[2]);
            string code = VsCode();
            if (code != null) Start(code, "\"" + path + "\"");
            else if (Directory.Exists(path)) Start("explorer.exe", "\"" + path + "\"");
            else Start("notepad.exe", "\"" + path + "\"");
            return null;
        }
        if (what == "app" && args.Length > 2)
        {
            string name = args[2];
            string wingetId = args.Length > 3 ? args[3] : null;
            return App(name) ? null : InstallOffer(name, wingetId);
        }
        MessageBox.Show("Usage: winarchy launch browser | browser-private | editor | edit <path> | app <Name> [winget-id]", "winarchy");
        return null;
    }

    static string VsCode()
    {
        foreach (var p in new[] { @"%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe", @"%ProgramFiles%\Microsoft VS Code\Code.exe" })
        {
            string full = Environment.ExpandEnvironmentVariables(p);
            if (File.Exists(full)) return full;
        }
        return null;
    }

    static void Start(string file, string arguments)
    {
        var psi = new ProcessStartInfo(file) { UseShellExecute = true, WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
        if (arguments != null) psi.Arguments = arguments;
        Process.Start(psi);
    }

    // ── Default browser, new window ──────────────────────────────────────

    static void Browser(bool priv)
    {
        string exe = DefaultBrowserExe();
        if (exe == null)
        {
            Start("msedge.exe", priv ? "--inprivate" : "--new-window");
            return;
        }
        string n = Path.GetFileNameWithoutExtension(exe).ToLowerInvariant();
        string flag;
        if (n == "firefox" || n == "librewolf" || n == "waterfox" || n == "zen" || n == "floorp")
            flag = priv ? "-private-window" : "-new-window";
        else if (n == "msedge")
            flag = priv ? "--inprivate" : "--new-window";
        else
            flag = priv ? "--incognito" : "--new-window"; // Chrome, Brave, Vivaldi, Opera, Arc...
        Start(exe, flag);
    }

    static string DefaultBrowserExe()
    {
        try
        {
            string progId = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "ProgId", null) as string;
            if (progId == null) return null;
            using (var key = Registry.ClassesRoot.OpenSubKey(progId + @"\shell\open\command"))
            {
                string cmd = key == null ? null : key.GetValue("") as string;
                if (string.IsNullOrEmpty(cmd)) return null;
                string exe;
                if (cmd.StartsWith("\"")) exe = cmd.Substring(1, cmd.IndexOf('"', 1) - 1);
                else
                {
                    int i = cmd.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                    exe = i < 0 ? null : cmd.Substring(0, i + 4);
                }
                return exe != null && File.Exists(exe) ? exe : null;
            }
        }
        catch { return null; }
    }

    // ── Apps by Start-menu name ──────────────────────────────────────────

    static string CachePath
    {
        get { return Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\winarchy\apps.json"); }
    }

    static bool App(string name)
    {
        var cached = LoadCache();
        string id = Match(cached, name);
        if (id == null)
        {
            var fresh = ScanApps();
            SaveCache(fresh);
            id = Match(fresh, name);
        }
        if (id == null) return false;
        Start("explorer.exe", "shell:AppsFolder\\" + id);
        return true;
    }

    static string Match(Dictionary<string, string> apps, string name)
    {
        string v;
        if (apps.TryGetValue(name, out v)) return v;
        foreach (var kv in apps)
            if (kv.Key.StartsWith(name + " ", StringComparison.OrdinalIgnoreCase)) return kv.Value;
        return null;
    }

    // Everything in the Start menu's "All apps" list: Win32 and Store apps alike.
    public static Dictionary<string, string> ScanApps()
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application"));
            dynamic folder = shell.NameSpace("shell:AppsFolder");
            foreach (dynamic item in folder.Items())
            {
                string n = item.Name;
                string p = item.Path;
                if (!string.IsNullOrEmpty(n) && !string.IsNullOrEmpty(p) && !map.ContainsKey(n)) map[n] = p;
            }
        }
        catch { }
        return map;
    }

    public static Dictionary<string, string> LoadCache()
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var raw = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(CachePath, Encoding.UTF8)) as Dictionary<string, object>;
            if (raw != null) foreach (var kv in raw) map[kv.Key] = kv.Value as string;
        }
        catch { }
        return map;
    }

    public static void SaveCache(Dictionary<string, string> map)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CachePath));
            File.WriteAllText(CachePath, new JavaScriptSerializer().Serialize(map), Encoding.UTF8);
        }
        catch { }
    }

    // Cached app list (instant); scans the Start menu only if there's no cache yet.
    public static Dictionary<string, string> Apps()
    {
        var apps = LoadCache();
        if (apps.Count == 0) { apps = ScanApps(); SaveCache(apps); }
        return apps;
    }

    // Rescans the Start menu after the launcher opens, so new apps show up next time.
    public static void RefreshCacheInBackground()
    {
        // At most every 10 minutes: scanning the Start menu costs CPU every time the menu opens.
        try { if (File.Exists(CachePath) && DateTime.Now - File.GetLastWriteTime(CachePath) < TimeSpan.FromMinutes(10)) return; }
        catch { }
        var t = new Thread(() => { var fresh = ScanApps(); if (fresh.Count > 0) SaveCache(fresh); }) { IsBackground = true };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
    }

    static Node InstallOffer(string name, string wingetId)
    {
        var root = new Node { Label = name + " isn't installed", Items = new List<Node>() };
        if (wingetId != null)
            root.Items.Add(new Node { Label = "Install " + name, Hint = "winget " + wingetId, Parent = root,
                Terminal = "winget install --id " + wingetId + " -e" });
        root.Items.Add(new Node { Label = "Search winget for " + name, Hint = "winget", Parent = root,
            Terminal = "winget search \"" + name.Replace("\"", "") + "\"" });
        root.Items.Add(new Node { Label = "Cancel", Builtin = "none", Parent = root });
        return root;
    }
}
