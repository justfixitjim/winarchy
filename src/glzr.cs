// Where GlazeWM and Zebar live: install.ps1 -User puts them in %LOCALAPPDATA%\Programs\glzr.io
// (no admin needed); a normal install puts them in Program Files. The per-user copy wins.
using System;
using System.IO;

static class Glzr
{
    static string Find(string relative)
    {
        string user = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\glzr.io", relative);
        if (File.Exists(user)) return user;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "glzr.io", relative);
    }

    public static string GlazeExe { get { return Find(@"GlazeWM\glazewm.exe"); } }
    public static string GlazeCli { get { return Find(@"GlazeWM\cli\glazewm.exe"); } }
    public static string ZebarExe { get { return Find(@"Zebar\zebar.exe"); } }
}
