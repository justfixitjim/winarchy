// winarchy toggles and reminders (`winarchy toggle ...`, `winarchy remind ...`), compiled into
// winarchy.exe. Stay awake and night light live in winarchy-daemon (they need a running
// process); this only signals it.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class Toggles
{
    static string GlazeCli { get { return Glzr.GlazeCli; } }
    static string ZebarExe { get { return Glzr.ZebarExe; } }

    public static void Run(string what, string dir)
    {
        switch (what)
        {
            case "awake": Daemon(@"Local\winarchy-daemon-awake"); break;
            case "nightlight": Daemon(@"Local\winarchy-daemon-nightlight"); break;
            case "dnd":
                {
                    bool? on = QuietHours.IsOn();
                    if (on == null || !QuietHours.Set(!on.Value))
                        Process.Start(new ProcessStartInfo("ms-settings:notifications") { UseShellExecute = true });
                    break;
                }
            case "bar": Bar(dir); break;
            case "gaps": Gaps(dir); break;
            default: MessageBox.Show("Unknown toggle: " + what + "\nUse awake, nightlight, dnd, bar or gaps.", "winarchy"); break;
        }
    }

    // `winarchy panel <name>`: open one of the bar's panels (clock, audio, bluetooth, network, ...)
    // from a key. Zebar only; if the bar is hidden, this starts it.
    public static void Panel(string name)
    {
        if (!Regex.IsMatch(name, "^[a-z]+$")) return;
        try
        {
            Process.Start(new ProcessStartInfo(ZebarExe, "start-widget-preset --pack winarchy --widget-name " + name + " --preset panel")
            { UseShellExecute = false, CreateNoWindow = true });
        }
        catch { }
    }

    // ── Default agent ─────────────────────────────────────────────────────────
    // Omarchy's Super+Shift+Ctrl+A: the coding agent you picked, in its own Terminal window.
    // { command, name }; the command must be on PATH.
    public static readonly string[][] Agents =
    {
        new[] { "claude", "Claude Code" },
        new[] { "codex", "Codex" },
        new[] { "opencode", "OpenCode" },
        new[] { "gemini", "Gemini CLI" },
        new[] { "copilot", "GitHub Copilot CLI" },
        new[] { "cursor-agent", "Cursor Agent" },
        new[] { "amp", "Amp" },
        new[] { "qwen", "Qwen Code" },
    };

    // File names in every PATH folder, listed once and reused for 30 seconds. Checking each
    // agent × folder × extension one file at a time took about half a second, on every menu open.
    static HashSet<string> pathFiles;
    static DateTime pathFilesAt;

    public static bool Installed(string command)
    {
        if (pathFiles == null || DateTime.UtcNow - pathFilesAt > TimeSpan.FromSeconds(30))
        {
            var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                if (dir.Trim().Length == 0) continue;
                try { foreach (string f in Directory.EnumerateFiles(Environment.ExpandEnvironmentVariables(dir.Trim()))) files.Add(Path.GetFileName(f)); }
                catch { }
            }
            pathFiles = files;
            pathFilesAt = DateTime.UtcNow;
        }
        string exts = Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.CMD;.BAT";
        foreach (string ext in exts.Split(';'))
            if (ext.Length > 0 && pathFiles.Contains(command + ext)) return true;
        return false;
    }

    static string SettingsPath(string dir) { return Path.Combine(dir, "settings.json"); }

    // The picked agent, or the first installed one.
    public static string DefaultAgent(string dir)
    {
        try
        {
            var s = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(SettingsPath(dir), Encoding.UTF8)) as Dictionary<string, object>;
            object v;
            if (s != null && s.TryGetValue("defaultAgent", out v) && v is string && ((string)v).Length > 0) return (string)v;
        }
        catch { }
        foreach (var a in Agents) if (Installed(a[0])) return a[0];
        return "";
    }

    public static void Agent(string[] args, string dir)
    {
        string verb = args.Length > 1 ? args[1].ToLowerInvariant() : "";
        if (verb == "set" && args.Length > 2)
        {
            string name = args[2].ToLowerInvariant();
            var agent = Agents.FirstOrDefault(a => a[0] == name);
            if (agent == null) { MessageBox.Show("Unknown agent: " + name, "winarchy"); return; }
            if (!Installed(name))
            {
                MessageBox.Show(agent[1] + " isn't installed (no `" + name + "` command on PATH). Install it, then pick it again.", "winarchy");
                return;
            }
            // Merge into settings.json, which winarchy-daemon and theme.ps1 also use.
            string path = SettingsPath(dir);
            try { SafeFile.Locked(path, delegate
            {
                var json = new JavaScriptSerializer();
                Dictionary<string, object> s = null;
                try { s = json.DeserializeObject(SafeFile.Read(path) ?? "") as Dictionary<string, object>; } catch { }
                if (s == null) s = new Dictionary<string, object>();
                s["defaultAgent"] = name;
                var sb = new StringBuilder("{\n");
                int i = 0;
                foreach (var kv in s) sb.Append("  " + json.Serialize(kv.Key) + ": " + json.Serialize(kv.Value) + (++i < s.Count ? ",\n" : "\n"));
                SafeFile.Write(path, sb.Append("}\n").ToString());
            }); }
            catch (TimeoutException e) { MessageBox.Show(e.Message + " Try again.", "winarchy"); }
            return;
        }
        string command = DefaultAgent(dir);
        if (command.Length == 0 || !Installed(command))
        {
            MessageBox.Show("No coding agent found. Install Claude Code, Codex or another agent, then pick it in the menu: AI > Default agent.", "winarchy");
            return;
        }
        var label = Agents.FirstOrDefault(a => a[0] == command);
        // cmd /c finds both .exe agents and npm's .cmd shims; the window closes when the agent exits.
        Process.Start(new ProcessStartInfo("wt.exe", "-w new nt -d \"" + Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) +
            "\" --title \"" + (label != null ? label[1] : command) + "\" cmd /c " + command) { UseShellExecute = true });
    }

    static void Daemon(string eventName)
    {
        EventWaitHandle ev;
        if (EventWaitHandle.TryOpenExisting(eventName, out ev)) ev.Set();
        else MessageBox.Show("winarchy-daemon is not running, so this can't be switched. It starts with GlazeWM.", "winarchy");
    }

    // ── Bar ───────────────────────────────────────────────────────────────────
    // Zebar has no "hide" command, so the bar is stopped and started. A Zebar started within about
    // a second of the last one exiting comes up as a grey strip (its local web server isn't free
    // yet), so showing it again waits until the old one is fully gone.
    static void Bar(string dir)
    {
        string stamp = Path.Combine(dir, ".bar-hidden");
        var running = Process.GetProcessesByName("zebar");
        if (running.Length > 0)
        {
            foreach (var p in running) { try { p.Kill(); } catch { } }
            try { File.WriteAllText(stamp, DateTime.UtcNow.Ticks.ToString()); } catch { }
            return;
        }
        long ticks;
        DateTime hidden = DateTime.MinValue;
        try { if (long.TryParse(File.ReadAllText(stamp), out ticks)) hidden = new DateTime(ticks, DateTimeKind.Utc); } catch { }
        for (int i = 0; i < 50 && Process.GetProcessesByName("zebar").Length > 0; i++) Thread.Sleep(100);
        var wait = hidden.AddSeconds(3) - DateTime.UtcNow;
        if (wait > TimeSpan.Zero && wait < TimeSpan.FromSeconds(4)) Thread.Sleep(wait);
        try { File.Delete(stamp); } catch { }
        Process.Start(new ProcessStartInfo(ZebarExe) { UseShellExecute = true });
    }

    // ── Gaps ──────────────────────────────────────────────────────────────────
    // Sets every gap in the GlazeWM config to 0 (saving the old values next to winarchy.exe), or
    // puts the saved values back, then reloads the config.
    static void Gaps(string dir)
    {
        string config = Environment.ExpandEnvironmentVariables(@"%USERPROFILE%\.glzr\glazewm\config.yaml");
        string saved = Path.Combine(dir, ".gaps-before");
        string text = File.ReadAllText(config, Encoding.UTF8);
        var block = Regex.Match(text, @"(?m)^gaps:\r?\n(?:[ \t]+.*\r?\n|\r?\n)*");
        if (!block.Success) { MessageBox.Show("No gaps: section found in the GlazeWM config.", "winarchy"); return; }
        string replacement;
        if (File.Exists(saved))
        {
            replacement = File.ReadAllText(saved, Encoding.UTF8);
            File.Delete(saved);
        }
        else
        {
            File.WriteAllText(saved, block.Value, new UTF8Encoding(false));
            replacement = Regex.Replace(block.Value, @"(?m)^(\s+(?:inner_gap|top|right|bottom|left):\s*)'?[^'\r\n]*'?", "$1'0px'");
        }
        File.WriteAllText(config, text.Substring(0, block.Index) + replacement + text.Substring(block.Index + block.Length), new UTF8Encoding(false));
        try { Process.Start(new ProcessStartInfo(GlazeCli, "command wm-reload-config") { UseShellExecute = false, CreateNoWindow = true }); } catch { }
    }

    // ── Reminders ─────────────────────────────────────────────────────────────
    // reminders.json: [{ "id": 1, "due": <unix ms>, "text": "..." }], fired by winarchy-daemon.
    public static void Remind(string[] args, string dir)
    {
        string verb = args.Length > 1 ? args[1].ToLowerInvariant() : "";
        double minutes = 0;
        bool add = verb == "add" && args.Length > 2 && double.TryParse(args[2], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out minutes) && minutes > 0;
        if (!add && !(verb == "remove" && args.Length > 2) && verb != "clear")
        {
            MessageBox.Show("winarchy remind add <minutes> <text>\nwinarchy remind remove <id>\nwinarchy remind clear", "winarchy");
            return;
        }
        // winarchy-daemon also rewrites this file (it drops reminders once they've popped up).
        string path = Path.Combine(dir, "reminders.json");
        try { SafeFile.Locked(path, delegate { ChangeReminders(path, verb, add, minutes, args); }); }
        catch (TimeoutException e) { MessageBox.Show(e.Message + " Try again.", "winarchy"); }
    }

    static void ChangeReminders(string path, string verb, bool add, double minutes, string[] args)
    {
        var json = new JavaScriptSerializer();
        var list = new List<Dictionary<string, object>>();
        try
        {
            var arr = json.DeserializeObject(SafeFile.Read(path) ?? "[]") as object[];
            if (arr != null) list = arr.OfType<Dictionary<string, object>>().ToList();
        }
        catch { }
        if (add)
        {
            string text = args.Length > 3 ? string.Join(" ", args, 3, args.Length - 3).Trim() : "";
            long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
            long id = list.Count == 0 ? 1 : list.Max(r => Convert.ToInt64(r.ContainsKey("id") ? r["id"] : 0)) + 1;
            list.Add(new Dictionary<string, object> { { "id", id }, { "due", now + (long)(minutes * 60000) }, { "text", text.Length > 0 ? text : "Reminder" } });
        }
        else if (verb == "remove" && args.Length > 2)
            list.RemoveAll(r => Convert.ToString(r.ContainsKey("id") ? r["id"] : "") == args[2]);
        else if (verb == "clear")
            list.Clear();
        Func<Dictionary<string, object>, long> due = r => { try { return Convert.ToInt64(r["due"]); } catch { return 0; } };
        list.Sort((a, b) => due(a).CompareTo(due(b)));
        SafeFile.Write(path, json.Serialize(list));
    }
}
