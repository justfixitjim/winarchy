// winarchy.exe: Omarchy-style menus and app launchers for GlazeWM on Windows 11.
//
//   winarchy                         open the main menu (menu.json next to the exe)
//   winarchy <page-id>               open the menu at a page, e.g. "system"
//   winarchy keys                    searchable cheat sheet built from the GlazeWM config
//   winarchy launch browser          new window of the default browser
//   winarchy launch browser-private  private window of the default browser
//   winarchy launch editor           VS Code if installed, otherwise Notepad
//   winarchy launch app <Name> [id]  start an app by its Start-menu name; offers a
//                                    winget install (package id) if it is missing
//   winarchy taskbar                 show/hide the Windows taskbar (via winarchy-daemon)
//
// Running a menu mode while a menu is open closes it, so hotkeys toggle.
// Written for the C# 5 compiler that ships with .NET Framework (no SDK needed).

using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using System.IO;
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
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(Point pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
}

class MenuForm : Form
{
    // Tokyo Night palette (Omarchy's default theme).
    static readonly Color Bg = ColorTranslator.FromHtml("#1a1b26");
    static readonly Color InputBg = ColorTranslator.FromHtml("#16161e");
    static readonly Color Fg = ColorTranslator.FromHtml("#c0caf5");
    static readonly Color Dim = ColorTranslator.FromHtml("#565f89");
    static readonly Color Accent = ColorTranslator.FromHtml("#7aa2f7");
    static readonly Color SelBg = ColorTranslator.FromHtml("#283457");
    static readonly Color Warn = ColorTranslator.FromHtml("#f7768e");

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
        using (var fonts = new InstalledFontCollection())
        {
            var have = new HashSet<string>(fonts.Families.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            foreach (var n in names) if (have.Contains(n)) return n;
        }
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

    void Refill()
    {
        string q = input.Text.Trim();
        var result = new List<Row>();
        int order = 0;
        if (q.Length == 0)
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
            : "↑↓ move   Enter select   " + (current != root ? "Backspace back   " : "") + "Esc close";
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
    static string GlazeCli { get { return Environment.ExpandEnvironmentVariables(@"%ProgramFiles%\glzr.io\GlazeWM\cli\glazewm.exe"); } }

    [STAThread]
    static void Main(string[] args)
    {
        string first = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        if (first == "taskbar")
        {
            EventWaitHandle ev;
            if (EventWaitHandle.TryOpenExisting(@"Local\winarchy-daemon-taskbar", out ev)) ev.Set();
            else MessageBox.Show("winarchy-daemon is not running, so the taskbar is not being managed.", "winarchy");
            return;
        }
        if (first == "launch")
        {
            Prepared = Launcher.Run(args);
            if (Prepared == null) return;  // launched fine; otherwise show the install offer
            args = new[] { "prepared" };
        }

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
        Node root, start;
        bool keys = mode == "keys";
        try
        {
            if (keys)
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
            return false;
        }

        Point cursor = Cursor.Position;
        uint dx = 96, dy = 96;
        try { Native.GetDpiForMonitor(Native.MonitorFromPoint(cursor, 2), 0, out dx, out dy); } catch { }
        var form = new MenuForm(root, start, keys, dx / 96f);
        Rectangle wa = Screen.FromPoint(cursor).WorkingArea;
        form.Location = new Point(wa.X + (wa.Width - form.Width) / 2, wa.Y + (int)((wa.Height - form.Height) * 0.38));
        openForm = form;
        Application.Run(form);
        openForm = null;
        return true;
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
        if (d.ContainsKey("items"))
        {
            n.Items = new List<Node>();
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
    static Dictionary<string, string> ScanApps()
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

    static Dictionary<string, string> LoadCache()
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

    static void SaveCache(Dictionary<string, string> map)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CachePath));
            File.WriteAllText(CachePath, new JavaScriptSerializer().Serialize(map), Encoding.UTF8);
        }
        catch { }
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
