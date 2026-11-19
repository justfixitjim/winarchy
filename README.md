# winarchy

Omarchy-style, keyboard-driven tiling for Windows 11. Super+key for everything, windows that tile themselves, and a single Super+Space launcher you search and arrow through.

It's a thin layer over good existing tools:

| Omarchy | winarchy |
|---|---|
| Hyprland tiling | [GlazeWM](https://github.com/glzr-io/glazewm), with a helper that adds Hyprland-style automatic splits |
| Waybar | [Zebar](https://github.com/glzr-io/zebar) at the top of the screen; the Windows taskbar is hidden |
| Walker (Super+Space) | PowerToys [Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview) |
| Omarchy menu (Super+Alt+Space) | `winarchy` menu: a searchable, arrow-key menu for system, setup, install and power actions |
| Super+K keybindings | `winarchy keys`: a searchable cheat sheet read live from your config |

## Install

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/justfixitjim/winarchy/main/install.ps1 | iex
```

Or clone the repo and run `.\install.ps1`. What the installer does:

1. Installs GlazeWM, Zebar, PowerToys and Windows Terminal with winget, skipping any already installed.
2. Builds `winarchy.exe` and `winarchy-daemon.exe` from `src\` using the C# compiler that ships with Windows. No prebuilt binaries are downloaded.
3. Writes `~\.glzr\glazewm\config.yaml` and `~\.glzr\winarchy\menu.json`, backing up anything it replaces. Workspaces are laid out for your monitors: the primary screen gets 1-5 and the others share 6-9.
4. Starts GlazeWM now and at every sign-in.

Re-run it any time to upgrade. Options:

- `-KeepConfig` keeps your existing config and menu.
- `-KeepTaskbar` leaves the taskbar visible.
- `-KeepStartMenu` lets a lone Super tap open Start.
- `-SkipApps` skips winget.

## Keys

| Keys | Action |
|---|---|
| Super+Space | Launcher (apps, files, settings, winget, window switcher, calculator) |
| Super+Alt+Space | winarchy menu |
| Super+K | Every keybinding, searchable |
| Super+Escape | Lock / sleep / sign out / restart / shut down |
| Super+Enter | Terminal |
| Super+Shift+B / Super+Shift+Alt+B | Default browser / private window |
| Super+Shift+F | Explorer |
| Super+Shift+N | VS Code (falls back to Notepad) |
| Super+Shift+O / M / D / G | Obsidian / Spotify / Discord / Steam (offers a winget install if missing) |
| Super+Shift+T | Task Manager |
| Super+W | Close window |
| Super+F / Super+T / Super+J | Fullscreen / float / flip split direction |
| Super+Arrows / Super+Shift+Arrows | Move focus / move window |
| Super+- / Super+= (with Shift for height) | Resize |
| Super+1-9 / Super+Shift+1-9 | Go to workspace / send window there |
| Super+Tab / Super+Shift+Tab | Next / previous workspace |
| Super+Alt+Arrows | Move workspace to another monitor |
| Super+Shift+P | Pause tiling and all bindings |
| Super+Ctrl+R | Reload config |

Windows keeps Win+L (lock), Win+V (clipboard), Win+Shift+S (screenshot), Win+E, Win+R, Win+I and Win+N. Like Omarchy, tapping Super on its own does nothing; Ctrl+Esc still opens Start.

## Customise

- **Bindings and look:** `~\.glzr\glazewm\config.yaml`, then Super+Ctrl+R to reload. The comment line above each binding is what Super+K shows.
- **Menu:** `~\.glzr\winarchy\menu.json`. Each item has a `label` and one action:
  - `run` (with optional `args`) for a program, URL or `ms-settings:` page.
  - `glaze` for a GlazeWM command.
  - `terminal` for PowerShell run in Windows Terminal.
  - `page` to jump to another page, or `items` for a submenu.
- **Background helper:** `~\.glzr\winarchy\settings.json` holds `hideTaskbar`, `blockStartMenu` and `autotile`. Changes take effect when GlazeWM restarts.
- **Taskbar:** Super+Alt+Space → Toggle → Taskbar shows or hides it on the fly.

## Uninstall

```powershell
.\uninstall.ps1            # keeps GlazeWM/Zebar installed
.\uninstall.ps1 -RemoveApps
```

This restores the taskbar and the GlazeWM config winarchy replaced, and removes the sign-in shortcut.

## How it works

- **`winarchy.exe`** is a small WinForms app. It provides the menu, the cheat sheet, and launchers that find your default browser and installed apps through the Start menu's app list, so one config works on any PC.
- **`winarchy-daemon.exe`** is started by GlazeWM and does three things:
  - **Start menu blocking.** GlazeWM swallows Super+key combos, which makes Windows think Super was tapped alone and open Start. The daemon injects an unassigned "mask" key (0xE8) when Super goes down, so that never happens.
  - **Taskbar hiding.** It auto-hides the taskbar, then hides it outright.
  - **Automatic splits.** It listens on GlazeWM's IPC socket and sets each focused window's split direction from its shape, giving Hyprland-style dwindle tiling.

## Notes

- GlazeWM 3.10.1 can't parse quoted program paths in `shell-exec`, so the config writes paths unquoted. Spaces in them are fine.
- GlazeWM only tiles windows running as administrator if it runs as administrator too.
- With the taskbar hidden, tray icons aren't visible. Use the Taskbar toggle to reach them, or open those apps from the launcher.

## License

MIT
