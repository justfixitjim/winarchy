# winarchy

Omarchy-style, keyboard-driven tiling for Windows 11. Super+key for everything, windows that tile themselves, and a single Super+Space launcher you search and arrow through.

It's a thin layer over good existing tools:

| Omarchy | winarchy |
|---|---|
| Hyprland tiling | [GlazeWM](https://github.com/glzr-io/glazewm), with a helper that adds Hyprland-style automatic splits |
| Waybar | [Zebar](https://github.com/glzr-io/zebar) bar at the top (workspaces, clock, stats, weather in °F); the Windows taskbar is hidden |
| Walker (Super+Space) | PowerToys [Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview) |
| Omarchy menu (Super+Alt+Space) | `winarchy` menu: a searchable, arrow-key menu for system, setup, install and power actions |
| Super+K keybindings | `winarchy keys`: a searchable cheat sheet read live from your config |
| Superwhisper dictation on Right Alt | [Superwhisper](https://superwhisper.com/windows) for Windows with local Whisper models: hold Right Alt to talk |

## Install

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/justfixitjim/winarchy/main/install.ps1 | iex
```

Or clone the repo and run `.\install.ps1`. What the installer does:

1. Installs GlazeWM, Zebar, PowerToys, Windows Terminal and Superwhisper with winget, skipping any already installed.
2. Builds `winarchy.exe` and `winarchy-daemon.exe` from `src\` using the C# compiler that ships with Windows. No prebuilt binaries are downloaded.
3. Writes `~\.glzr\glazewm\config.yaml` and `~\.glzr\winarchy\menu.json`, backing up anything it replaces. Workspaces are laid out for your monitors: the primary screen gets 1-5 and the others share 6-9.
4. Installs the winarchy top bar as a Zebar widget pack (`~\.glzr\zebar\winarchy`).
5. Starts GlazeWM now and at every sign-in.

Re-run it any time to upgrade. Options:

- `-KeepConfig` keeps your existing config and menu.
- `-KeepTaskbar` leaves the taskbar visible.
- `-KeepStartMenu` lets a lone Super tap open Start.
- `-SkipApps` skips winget.
- `-Celsius` shows the bar's temperature in Celsius (the default is Fahrenheit).
- `-NoDictation` skips Superwhisper.

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

## Dictation

Like Omarchy, winarchy uses Superwhisper for dictation, running a local speech model on your PC. The installer installs it, but its first-run setup is yours to do once:

1. Open **superwhisper** from Super+Space and go through its setup. Pick a local model: the free tier includes every Whisper model, up to Large v3 Turbo (fastest on a GPU). Superwhisper's docs list Parakeet and Cohere Transcribe as Pro models.
2. Re-run `install.ps1`. It closes Superwhisper, sets **Push to talk** to **Right Alt** and turns on **Launch on login**, then reopens it. It only does this while push-to-talk is still on Superwhisper's default (Ctrl+Space), so a key you picked yourself is kept. You can also set both in Superwhisper → Configuration.

Then hold Right Alt, speak, and let go: the text is pasted where your cursor is. A quick tap of its toggle key starts and stops a longer recording. Esc cancels. Super+Alt+Space → Setup → Dictation reopens its settings.

## Customise

- **Bindings and look:** `~\.glzr\glazewm\config.yaml`, then Super+Ctrl+R to reload. The comment line above each binding is what Super+K shows.
- **Menu:** `~\.glzr\winarchy\menu.json`. Each item has a `label` and one action:
  - `run` (with optional `args`) for a program, URL or `ms-settings:` page.
  - `glaze` for a GlazeWM command.
  - `terminal` for PowerShell run in Windows Terminal.
  - `page` to jump to another page, or `items` for a submenu.
- **Background helper:** `~\.glzr\winarchy\settings.json` holds `hideTaskbar`, `blockStartMenu` and `autotile`. Changes take effect when GlazeWM restarts.
- **Taskbar:** Super+Alt+Space → Toggle → Taskbar shows or hides it on the fly.
- **Top bar:** `~\.glzr\zebar\winarchyar.html` (`TEMP_UNIT` at the top switches between °F and °C).

## Uninstall

```powershell
.\uninstall.ps1            # keeps GlazeWM/Zebar installed
.\uninstall.ps1 -RemoveApps
```

This restores the taskbar, the Zebar bar and the GlazeWM config winarchy replaced, and removes the sign-in shortcut. Superwhisper stays installed.

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

MIT, except `config/zebar/bar.html` and `styles.css`, which are adapted from Zebar's starter widget and stay under GPL-3.0 (see `config/zebar/NOTICE.md`).
