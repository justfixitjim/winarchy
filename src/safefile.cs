// Compiled into winarchy.exe and winarchy-daemon.exe. Both write settings.json and reminders.json,
// so changes happen under a named lock (two writers never lose each other's change) and the new
// text replaces the old file in one step (a reader, or a crash, never leaves half a file).

using System;
using System.IO;
using System.Text;
using System.Threading;

static class SafeFile
{
    // Runs `change` while holding a lock named after the file, shared by every winarchy program.
    // Throws TimeoutException, without running it, if another program keeps the lock.
    public static void Locked(string path, Action change)
    {
        using (var m = new Mutex(false, @"Local\winarchy-file-" + Path.GetFileName(path).ToLowerInvariant()))
        {
            bool have;
            try { have = m.WaitOne(3000); }
            catch (AbandonedMutexException) { have = true; } // the last holder crashed; the file is still whole
            if (!have) throw new TimeoutException(Path.GetFileName(path) + " is being changed by another winarchy program.");
            try { change(); }
            finally { m.ReleaseMutex(); }
        }
    }

    public static string Read(string path)
    {
        try
        {
            using (var r = new StreamReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete), Encoding.UTF8))
                return r.ReadToEnd();
        }
        catch { return null; }
    }

    // Writes a temporary file next to `path`, then swaps it in. If a reader holds the file open
    // without allowing that, try a few times, then write in place.
    public static void Write(string path, string text)
    {
        string tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp"; // never shared with another writer
        try
        {
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    if (File.Exists(path)) File.Replace(tmp, path, null, true);
                    else File.Move(tmp, path);
                    return;
                }
                catch (IOException) { Thread.Sleep(40); }
                catch (UnauthorizedAccessException) { Thread.Sleep(40); }
            }
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }
        finally { try { File.Delete(tmp); } catch { } }
    }
}
