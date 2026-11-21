// winarchy-audio: what Zebar's audio provider can't do, for the bar's audio panel.
//
//   winarchy-audio.exe apps                    JSON: every app playing through the default output,
//                                              with its own volume and mute
//   winarchy-audio.exe volume <pids> <0-100>   set an app's volume (pids: comma-separated)
//   winarchy-audio.exe mute <pids> on|off      mute or unmute an app
//   winarchy-audio.exe default <device id>     make a device the default (output or input), for
//                                              every role, like picking it in Quick Settings
//
// Device ids are the ones Zebar's audio provider reports ({0.0.0.00000000}.{guid}).
// Written for the C# 5 compiler that ships with .NET Framework (no SDK needed).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice
{
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2
{
    int GetAudioSessionControl(IntPtr groupingParam, int flags, out IntPtr control);
    int GetSimpleAudioVolume(IntPtr groupingParam, int flags, out IntPtr volume);
    int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator
{
    int GetCount(out int count);
    int GetSession(int index, out IAudioSessionControl2 session);
}

[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2
{
    // IAudioSessionControl
    int GetState(out int state);
    int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid context);
    int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
    int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid context);
    int GetGroupingParam(out Guid param);
    int SetGroupingParam(ref Guid param, ref Guid context);
    int RegisterAudioSessionNotification(IntPtr client);
    int UnregisterAudioSessionNotification(IntPtr client);
    // IAudioSessionControl2
    int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetProcessId(out int pid);
    [PreserveSig] int IsSystemSoundsSession();
    int SetDuckingPreference(bool optOut);
}

[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume
{
    int SetMasterVolume(float level, ref Guid context);
    int GetMasterVolume(out float level);
    int SetMute(bool mute, ref Guid context);
    int GetMute(out bool mute);
}

// Undocumented, but what every "switch audio device" tool uses (Windows has no public API for it).
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClient { }

[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig
{
    int GetMixFormat(string id, IntPtr format);
    int GetDeviceFormat(string id, bool defaultFormat, IntPtr format);
    int ResetDeviceFormat(string id);
    int SetDeviceFormat(string id, IntPtr endpointFormat, IntPtr mixFormat);
    int GetProcessingPeriod(string id, bool defaultPeriod, IntPtr defaultP, IntPtr minP);
    int SetProcessingPeriod(string id, IntPtr period);
    int GetShareMode(string id, IntPtr mode);
    int SetShareMode(string id, IntPtr mode);
    int GetPropertyValue(string id, IntPtr key, IntPtr value);
    int SetPropertyValue(string id, IntPtr key, IntPtr value);
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    int SetEndpointVisibility(string id, bool visible);
}

static class Audio
{
    static Guid NoContext = Guid.Empty;

    static void Str(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s ?? "")
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c);
            else sb.Append(c);
        }
        sb.Append('"');
    }

    class Session { public int Pid; public string Name; public ISimpleAudioVolume Volume; public bool System; public bool Active; }

    static List<Session> Sessions()
    {
        var result = new List<Session>();
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice device;
        if (enumerator.GetDefaultAudioEndpoint(0 /* render */, 1 /* multimedia */, out device) != 0) return result;
        Guid iid = typeof(IAudioSessionManager2).GUID;
        object o;
        device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o);
        var manager = (IAudioSessionManager2)o;
        IAudioSessionEnumerator sessions;
        manager.GetSessionEnumerator(out sessions);
        int count;
        sessions.GetCount(out count);
        for (int i = 0; i < count; i++)
        {
            IAudioSessionControl2 s;
            if (sessions.GetSession(i, out s) != 0 || s == null) continue;
            int state, pid;
            s.GetState(out state);
            if (state == 2) continue; // expired
            s.GetProcessId(out pid);
            bool system = s.IsSystemSoundsSession() == 0;
            string name = null;
            if (system) name = "System sounds";
            else
            {
                try { s.GetDisplayName(out name); } catch { }
                if (string.IsNullOrEmpty(name) || name.StartsWith("@"))
                {
                    try
                    {
                        using (var p = Process.GetProcessById(pid))
                        {
                            name = p.ProcessName;
                            try { string d = p.MainModule.FileVersionInfo.FileDescription; if (!string.IsNullOrWhiteSpace(d)) name = d.Trim(); } catch { }
                        }
                    }
                    catch { continue; } // the app has gone
                }
            }
            result.Add(new Session { Pid = pid, Name = name, Volume = (ISimpleAudioVolume)s, System = system, Active = state == 1 });
        }
        return result;
    }

    static int Main(string[] args)
    {
        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        string cmd = args.Length > 0 ? args[0] : "apps";
        try
        {
            if (cmd == "apps")
            {
                // One row per session; the panel merges apps that open several (Discord, browsers).
                var sb = new StringBuilder("{\"apps\":[");
                bool first = true;
                foreach (var s in Sessions())
                {
                    float level; bool muted;
                    s.Volume.GetMasterVolume(out level);
                    s.Volume.GetMute(out muted);
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append("{\"pid\":").Append(s.Pid).Append(",\"name\":");
                    Str(sb, s.Name);
                    sb.Append(",\"volume\":").Append(Math.Round(level * 100).ToString(CultureInfo.InvariantCulture))
                      .Append(",\"muted\":").Append(muted ? "true" : "false")
                      .Append(",\"active\":").Append(s.Active ? "true" : "false")
                      .Append(",\"system\":").Append(s.System ? "true" : "false").Append('}');
                }
                sb.Append("]}");
                stdout.WriteLine(sb.ToString());
                return 0;
            }
            if ((cmd == "volume" || cmd == "mute") && args.Length > 2)
            {
                var pids = new HashSet<int>();
                foreach (string p in args[1].Split(',')) pids.Add(int.Parse(p));
                int changed = 0;
                foreach (var s in Sessions())
                {
                    if (!pids.Contains(s.Pid)) continue;
                    if (cmd == "volume") s.Volume.SetMasterVolume(Math.Max(0, Math.Min(100, float.Parse(args[2], CultureInfo.InvariantCulture))) / 100f, ref NoContext);
                    else s.Volume.SetMute(args[2] == "on", ref NoContext);
                    changed++;
                }
                stdout.WriteLine("{\"ok\":" + (changed > 0 ? "true" : "false") + "}");
                return changed > 0 ? 0 : 1;
            }
            if (cmd == "default" && args.Length > 1)
            {
                var policy = (IPolicyConfig)new PolicyConfigClient();
                for (int role = 0; role < 3; role++) policy.SetDefaultEndpoint(args[1], role); // console, multimedia, communications
                stdout.WriteLine("{\"ok\":true}");
                return 0;
            }
            stdout.WriteLine("{\"error\":\"usage: apps | volume <pid> <0-100> | mute <pid> on|off | default <device id>\"}");
            return 2;
        }
        catch (Exception ex)
        {
            var sb = new StringBuilder("{\"error\":");
            Str(sb, ex.Message);
            stdout.WriteLine(sb.Append('}').ToString());
            return 1;
        }
    }
}
