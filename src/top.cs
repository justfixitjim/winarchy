// winarchy-top: CPU, memory and video memory (VRAM) per process, for the bar and its process panel.
//
//   winarchy-top.exe watch [ms]      a JSON line every [ms] (default 1500): totals and every process
//   winarchy-top.exe summary [ms]    a JSON line every [ms] (default 5000) for the bar: VRAM totals,
//                                    and the toggles (stay awake, night light, do not disturb,
//                                    reminders) for its indicators
//   winarchy-top.exe kill <pid>...   end those processes; prints which ended and which didn't
//
// Process times and memory come from one NtQuerySystemInformation call (what Task Manager uses),
// so protected processes are included and nothing is opened per process. VRAM per process comes
// from the "GPU Process Memory" performance counters. watch / summary stop when the program that
// started them exits or stops reading.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

static class Top
{
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buffer, int length, out int needed);

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

    struct Proc { public int Pid, Parent; public string Name; public long Time, CreateTime, PrivateWs; }

    static IntPtr buf = IntPtr.Zero;
    static int bufLen = 1 << 20;

    // SYSTEM_PROCESS_INFORMATION (x64 layout).
    static Dictionary<int, Proc> Snapshot(out long idleTime)
    {
        idleTime = 0;
        while (true)
        {
            if (buf == IntPtr.Zero) buf = Marshal.AllocHGlobal(bufLen);
            int needed;
            int status = NtQuerySystemInformation(5, buf, bufLen, out needed);
            if (status == unchecked((int)0xC0000004)) // STATUS_INFO_LENGTH_MISMATCH
            {
                Marshal.FreeHGlobal(buf); buf = IntPtr.Zero;
                bufLen = Math.Max(bufLen * 2, needed + (1 << 16));
                continue;
            }
            if (status != 0) throw new Exception("NtQuerySystemInformation failed: 0x" + status.ToString("X"));
            break;
        }
        var result = new Dictionary<int, Proc>();
        long offset = 0;
        while (true)
        {
            IntPtr p = new IntPtr(buf.ToInt64() + offset);
            int next = Marshal.ReadInt32(p, 0);
            long privateWs = Marshal.ReadInt64(p, 8);
            long create = Marshal.ReadInt64(p, 32);
            long user = Marshal.ReadInt64(p, 40);
            long kernel = Marshal.ReadInt64(p, 48);
            ushort nameLen = (ushort)Marshal.ReadInt16(p, 56);
            IntPtr nameBuf = Marshal.ReadIntPtr(p, 64);
            int pid = (int)Marshal.ReadInt64(p, 80);
            int parent = (int)Marshal.ReadInt64(p, 88);
            if (pid == 0) idleTime = kernel;
            else
            {
                string name = nameBuf == IntPtr.Zero ? "System" : Marshal.PtrToStringUni(nameBuf, nameLen / 2);
                result[pid] = new Proc { Pid = pid, Parent = parent, Name = name, Time = user + kernel, CreateTime = create, PrivateWs = privateWs };
            }
            if (next == 0) break;
            offset += next;
        }
        return result;
    }

    // ── VRAM ──────────────────────────────────────────────────────────────────
    static PerformanceCounterCategory gpuProc, gpuAdapter;

    static Dictionary<int, long> VramByPid()
    {
        var map = new Dictionary<int, long>();
        try
        {
            if (gpuProc == null) gpuProc = new PerformanceCounterCategory("GPU Process Memory");
            var data = gpuProc.ReadCategory();
            var col = data["dedicated usage"];
            if (col == null) return map;
            foreach (InstanceData inst in col.Values)
            {
                // Instance names look like pid_1234_luid_0x..._phys_0
                string n = inst.InstanceName;
                if (!n.StartsWith("pid_")) continue;
                int end = n.IndexOf('_', 4);
                int pid;
                if (end < 0 || !int.TryParse(n.Substring(4, end - 4), out pid)) continue;
                long v;
                map.TryGetValue(pid, out v);
                map[pid] = v + inst.RawValue;
            }
        }
        catch { }
        return map;
    }

    static long VramUsed()
    {
        long sum = 0;
        try
        {
            if (gpuAdapter == null) gpuAdapter = new PerformanceCounterCategory("GPU Adapter Memory");
            var col = gpuAdapter.ReadCategory()["dedicated usage"];
            if (col != null) foreach (InstanceData inst in col.Values) sum += inst.RawValue;
        }
        catch { }
        return sum;
    }

    // Dedicated memory of the biggest graphics card, from its driver's registry entry.
    static long vramTotal = -1;
    static long VramTotal()
    {
        if (vramTotal >= 0) return vramTotal;
        vramTotal = 0;
        try
        {
            using (var cls = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"))
            {
                if (cls != null)
                    foreach (string sub in cls.GetSubKeyNames())
                    {
                        if (sub.Length != 4) continue;
                        try
                        {
                            using (var k = cls.OpenSubKey(sub))
                            {
                                if (k == null) continue;
                                object q = k.GetValue("HardwareInformation.qwMemorySize");
                                object d = k.GetValue("HardwareInformation.MemorySize");
                                long size = 0;
                                if (q is long) size = (long)q;
                                else if (q is byte[] && ((byte[])q).Length >= 8) size = BitConverter.ToInt64((byte[])q, 0);
                                else if (d is int) size = (uint)(int)d;
                                else if (d is byte[] && ((byte[])d).Length >= 4) size = BitConverter.ToUInt32((byte[])d, 0);
                                if (size > vramTotal) vramTotal = size;
                            }
                        }
                        catch { }
                    }
            }
        }
        catch { }
        return vramTotal;
    }

    // ── Output ────────────────────────────────────────────────────────────────
    static void Str(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c);
            else sb.Append(c);
        }
        sb.Append('"');
    }

    static int parentPid;
    static long parentCreate;

    static bool ParentAlive(Dictionary<int, Proc> snap)
    {
        Proc p;
        return snap.TryGetValue(parentPid, out p) && p.CreateTime == parentCreate;
    }

    static void RememberParent(Dictionary<int, Proc> snap)
    {
        Proc me, parent;
        if (snap.TryGetValue(Process.GetCurrentProcess().Id, out me) && snap.TryGetValue(me.Parent, out parent))
        { parentPid = parent.Pid; parentCreate = parent.CreateTime; }
        else parentPid = -1;
    }

    static int Main(string[] args)
    {
        string mode = args.Length > 0 ? args[0] : "watch";
        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        try
        {
            if (mode == "kill") return Kill(args, stdout);
            int interval = args.Length > 1 ? Math.Max(250, int.Parse(args[1])) : (mode == "summary" ? 5000 : 1500);
            return mode == "summary" ? Summary(interval, stdout) : Watch(interval, stdout);
        }
        catch (IOException) { return 0; } // the reader went away
    }

    static int Summary(int interval, StreamWriter stdout)
    {
        long idle;
        RememberParent(Snapshot(out idle));
        string dir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        while (true)
        {
            var sb = new StringBuilder();
            sb.Append("{\"vramUsed\":").Append(VramUsed()).Append(",\"vramTotal\":").Append(VramTotal());
            // Toggles for the bar's indicators: stay awake and night light (winarchy-daemon's
            // settings.json), do not disturb (Windows), and pending reminders (reminders.json).
            string daemon = ReadText(Path.Combine(dir, "settings.json"));
            bool? dnd = QuietHours.IsOn();
            sb.Append(",\"awake\":").Append(Flag(daemon, "stayAwake") ? "true" : "false")
              .Append(",\"nightLight\":").Append(Flag(daemon, "nightLight") ? "true" : "false")
              .Append(",\"dnd\":").Append(dnd == null ? "null" : dnd.Value ? "true" : "false");
            string reminders = ReadText(Path.Combine(dir, "reminders.json")).Trim();
            sb.Append(",\"reminders\":").Append(reminders.StartsWith("[") && reminders.EndsWith("]") ? reminders : "[]");
            sb.Append('}');
            stdout.WriteLine(sb.ToString());
            Thread.Sleep(interval);
            if (parentPid > 0 && !ParentAlive(Snapshot(out idle))) return 0;
        }
    }

    static string ReadText(string path)
    {
        try { using (var r = new StreamReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete), Encoding.UTF8)) return r.ReadToEnd(); }
        catch { return ""; }
    }

    static bool Flag(string json, string key)
    {
        return System.Text.RegularExpressions.Regex.IsMatch(json, "\"" + key + "\"\\s*:\\s*true");
    }

    static int Watch(int interval, StreamWriter stdout)
    {
        int cores = Environment.ProcessorCount;
        long prevIdle;
        var prev = Snapshot(out prevIdle);
        RememberParent(prev);
        var clock = Stopwatch.StartNew();
        long prevTicks = 0;
        Thread.Sleep(Math.Min(interval, 700)); // first numbers quickly
        while (true)
        {
            long idle;
            var snap = Snapshot(out idle);
            if (parentPid > 0 && !ParentAlive(snap)) return 0;
            long ticks = clock.Elapsed.Ticks;                 // 100 ns units, like process times
            double span = Math.Max(1, ticks - prevTicks) * (double)cores;
            var vram = VramByPid();
            var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) };
            GlobalMemoryStatusEx(ref mem);
            double cpuTotal = Math.Max(0, Math.Min(100, 100 - (idle - prevIdle) / span * 100));

            var sb = new StringBuilder(32768);
            sb.Append("{\"cores\":").Append(cores)
              .Append(",\"cpu\":").Append(cpuTotal.ToString("0.0", CultureInfo.InvariantCulture))
              .Append(",\"memUsed\":").Append(mem.ullTotalPhys - mem.ullAvailPhys)
              .Append(",\"memTotal\":").Append(mem.ullTotalPhys)
              .Append(",\"vramUsed\":").Append(VramUsed())
              .Append(",\"vramTotal\":").Append(VramTotal())
              .Append(",\"procs\":[");
            bool first = true;
            foreach (var p in snap.Values)
            {
                Proc old;
                double cpu = 0;
                if (prev.TryGetValue(p.Pid, out old) && old.CreateTime == p.CreateTime)
                    cpu = Math.Max(0, (p.Time - old.Time) / span * 100);
                long v; vram.TryGetValue(p.Pid, out v);
                if (!first) sb.Append(',');
                first = false;
                sb.Append("[").Append(p.Pid).Append(',');
                Str(sb, p.Name);
                sb.Append(',').Append(cpu.ToString("0.0", CultureInfo.InvariantCulture))
                  .Append(',').Append(p.PrivateWs).Append(',').Append(v).Append(']');
            }
            sb.Append("]}");
            stdout.WriteLine(sb.ToString());
            prev = snap; prevIdle = idle; prevTicks = ticks;
            Thread.Sleep(interval);
        }
    }

    static int Kill(string[] args, StreamWriter stdout)
    {
        var ok = new List<int>();
        var failed = new List<string>();
        for (int i = 1; i < args.Length; i++)
        {
            int pid;
            if (!int.TryParse(args[i], out pid) || pid <= 4) continue; // never the idle or System process
            try
            {
                using (var p = Process.GetProcessById(pid)) { p.Kill(); p.WaitForExit(3000); }
                ok.Add(pid);
            }
            catch (ArgumentException) { ok.Add(pid); } // already gone
            catch (Exception ex)
            {
                var sb = new StringBuilder();
                sb.Append("{\"pid\":").Append(pid).Append(",\"error\":");
                Str(sb, ex is System.ComponentModel.Win32Exception && ((System.ComponentModel.Win32Exception)ex).NativeErrorCode == 5
                    ? "access denied (it runs as administrator or is protected)" : ex.Message);
                sb.Append('}');
                failed.Add(sb.ToString());
            }
        }
        stdout.WriteLine("{\"killed\":[" + string.Join(",", ok) + "],\"failed\":[" + string.Join(",", failed) + "]}");
        return failed.Count == 0 ? 0 : 1;
    }
}
