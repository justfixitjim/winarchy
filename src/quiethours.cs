// Windows' do not disturb, through the same (undocumented) settings object the Settings app
// uses. Compiled into winarchy.exe (to switch it) and winarchy-top.exe (to show it in the bar).

using System;
using System.Runtime.InteropServices;

[ComImport, Guid("6bff4732-81ec-4ffb-ae67-b6c1bc29631f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IQuietHoursSettings
{
    [PreserveSig] int get_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] out string profileId);
    [PreserveSig] int put_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] string profileId);
}

static class QuietHours
{
    const string Off = "Microsoft.QuietHoursProfile.Unrestricted";
    const string On = "Microsoft.QuietHoursProfile.PriorityOnly";

    static IQuietHoursSettings Settings()
    {
        var type = Type.GetTypeFromCLSID(new Guid("f53321fa-34f8-4b7f-b9a3-361877cb94cf")); // CLSID_QuietHoursSettings
        return (IQuietHoursSettings)Activator.CreateInstance(type);
    }

    // null when Windows doesn't offer it.
    public static bool? IsOn()
    {
        try
        {
            string id;
            if (Settings().get_UserSelectedProfile(out id) != 0 || id == null) return null;
            return id != Off;
        }
        catch { return null; }
    }

    public static bool Set(bool on)
    {
        try { return Settings().put_UserSelectedProfile(on ? On : Off) == 0; }
        catch { return false; }
    }
}
