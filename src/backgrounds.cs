// The current theme's wallpapers for the menu's background picker: the list (in the same order
// as tools\theme.ps1 -NextBackground), setting one without starting PowerShell, and small
// cached previews.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Backgrounds
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);

    static string Dir { get { return Path.GetDirectoryName(Application.ExecutablePath); } }
    static string ThemeJson { get { return Path.Combine(Dir, "theme.json"); } }
    static readonly string[] Styles = { "glow", "bands", "grid" };

    public class Item { public string Path, Name; public bool Made; }

    // Your own pictures (~\.glzr\winarchy\backgrounds\<theme>) by name, then the theme's three
    // generated ones. Generated files that don't exist yet are listed as not made.
    public static List<Item> List(out string themeId, out int current)
    {
        themeId = "tokyo-night"; current = 0;
        try
        {
            string text = File.ReadAllText(ThemeJson);
            var m = Regex.Match(text, "\"id\"\\s*:\\s*\"([^\"]+)\"");
            if (m.Success) themeId = m.Groups[1].Value;
            m = Regex.Match(text, "\"background\"\\s*:\\s*(\\d+)");
            if (m.Success) current = int.Parse(m.Groups[1].Value);
        }
        catch { }
        var list = new List<Item>();
        string own = Path.Combine(Dir, "backgrounds", themeId);
        if (Directory.Exists(own))
            foreach (var f in Directory.GetFiles(own).Where(f => Regex.IsMatch(Path.GetExtension(f), @"^\.(jpe?g|png|bmp)$", RegexOptions.IgnoreCase))
                                                   .OrderBy(f => Path.GetFileName(f), StringComparer.CurrentCultureIgnoreCase))
                list.Add(new Item { Path = f, Name = Path.GetFileNameWithoutExtension(f), Made = true });
        // Same size rule as theme.ps1: the main screen in physical pixels, at least 1280x720.
        var b = Screen.PrimaryScreen.Bounds;
        int w = Math.Max(b.Width, 1280), h = Math.Max(b.Height, 720);
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "winarchy", "backgrounds");
        foreach (var st in Styles)
        {
            string p = Path.Combine(cache, string.Format("{0}-{1}-{2}x{3}.png", themeId, st, w, h));
            list.Add(new Item { Path = p, Name = char.ToUpper(st[0]) + st.Substring(1), Made = File.Exists(p) });
        }
        if (current >= list.Count) current = 0;
        return list;
    }

    // Sets wallpaper number `index`. Returns a status line for the menu.
    public static string Set(int index)
    {
        string theme; int current;
        var list = List(out theme, out current);
        if (list.Count == 0) return "No backgrounds for this theme";
        index = ((index % list.Count) + list.Count) % list.Count;
        var item = list[index];
        string status = string.Format("Background {0} of {1}: {2}", index + 1, list.Count, item.Name);
        // Not drawn yet, or no theme backup to restore from yet: theme.ps1 does those (slower).
        if (!item.Made || !File.Exists(Path.Combine(Dir, "theme-backup.json")))
        {
            string script = Path.Combine(Dir, "tools", "theme.ps1");
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -Background " + index)
            { UseShellExecute = false, CreateNoWindow = true };
            using (Process.Start(psi)) { }
            return status + " (drawing it...)";
        }
        SafeFile.Locked(ThemeJson, () =>
        {
            string text = SafeFile.Read(ThemeJson);
            if (text == null) return;
            string updated = Regex.IsMatch(text, "\"background\"\\s*:\\s*\\d+")
                ? Regex.Replace(text, "(\"background\"\\s*:\\s*)\\d+", "${1}" + index)
                : text;
            if (updated != text) SafeFile.Write(ThemeJson, updated);
        });
        // Fill the screen, like theme.ps1. Windows tells every window about the change, which can
        // take a moment, so that happens off the menu's thread.
        string path = item.Path;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop", true))
                {
                    k.SetValue("WallpaperStyle", "10");
                    k.SetValue("TileWallpaper", "0");
                }
                SystemParametersInfo(0x14, 0, path, 3); // SPI_SETDESKWALLPAPER, save + broadcast
            }
            catch { }
        });
        return status;
    }

    // ── Previews ──────────────────────────────────────────────────────────
    // Kept in memory by the resident menu, and on disk (%LOCALAPPDATA%\winarchy\thumbs) so a
    // restart doesn't have to decode the full-size pictures again.

    static readonly Dictionary<string, Image> thumbs = new Dictionary<string, Image>();
    static readonly HashSet<string> loading = new HashSet<string>();

    // The preview if it's ready; otherwise starts making it and calls `ready` when done.
    public static Image Thumb(string path, Size size, Action ready)
    {
        string key;
        try { key = path + "|" + File.GetLastWriteTimeUtc(path).Ticks + "|" + size.Width + "x" + size.Height; }
        catch { return null; }
        lock (thumbs)
        {
            Image img;
            if (thumbs.TryGetValue(key, out img)) return img;
            if (!loading.Add(key)) return null;
        }
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Image img = null;
            try { img = MakeThumb(path, size, key); } catch { }
            lock (thumbs) { thumbs[key] = img; loading.Remove(key); }
            if (ready != null) try { ready(); } catch { }
        });
        return null;
    }

    static Image MakeThumb(string path, Size size, string key)
    {
        if (!File.Exists(path)) return null;
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "winarchy", "thumbs");
        string file;
        using (var md5 = System.Security.Cryptography.MD5.Create())
            file = Path.Combine(dir, BitConverter.ToString(md5.ComputeHash(System.Text.Encoding.UTF8.GetBytes(key))).Replace("-", "") + ".png");
        if (File.Exists(file))
            using (var ms = new MemoryStream(File.ReadAllBytes(file)))
            using (var cached = Image.FromStream(ms)) return new Bitmap(cached);
        var bmp = new Bitmap(size.Width, size.Height);
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (var src = Image.FromStream(fs, false, false))
        using (var g = Graphics.FromImage(bmp))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            // Cover the box and crop the overflow, as "fill" does on the desktop.
            float scale = Math.Max((float)size.Width / src.Width, (float)size.Height / src.Height);
            float w = src.Width * scale, h = src.Height * scale;
            g.DrawImage(src, (size.Width - w) / 2, (size.Height - h) / 2, w, h);
        }
        try
        {
            Directory.CreateDirectory(dir);
            bmp.Save(file + ".tmp", ImageFormat.Png);
            File.Copy(file + ".tmp", file, true);
            File.Delete(file + ".tmp");
        }
        catch { }
        return bmp;
    }

    // Starts making the current theme's previews so the picker opens with them ready.
    public static void Prewarm(Size size)
    {
        string theme; int current;
        foreach (var item in List(out theme, out current)) if (item.Made) Thumb(item.Path, size, null);
    }
}
