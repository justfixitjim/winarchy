# winarchy

Omarchy-style, keyboard-driven tiling for Windows 11. Super+key for everything, windows that tile themselves, and a single Super+Space launcher you search and arrow through.

It's a thin layer over good existing tools:

| Omarchy | winarchy |
|---|---|
| Hyprland tiling | [GlazeWM](https://github.com/glzr-io/glazewm), with a helper that adds Hyprland-style automatic splits |
| Waybar | [Zebar](https://github.com/glzr-io/zebar) bar at the top (workspaces, clock, volume, stats, weather in °F); the Windows taskbar is hidden |
| Walker (Super+Space) and the Omarchy menu | The `winarchy` menu: Omarchy's sections (Apps, Appearance, Trigger, Setup, Install, Remove, Update, Learn, System), searchable across apps, open windows and Settings pages, plus quick maths |
| Super+K keybindings | `winarchy keys`: a searchable cheat sheet read live from your config |
| Dictation on Right Alt (Superwhisper) | [Handy](https://github.com/cjpais/Handy): free, open-source dictation with local Whisper/Parakeet models. Hold **Right Ctrl** to talk |

## Install

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/justfixitjim/winarchy/main/install.ps1 | iex
```

Or clone the repo and run `.\install.ps1`. What the installer does:

1. Installs GlazeWM, Zebar, Windows Terminal, Handy, ffmpeg and ImageMagick with winget, skipping any already installed.
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
- `-NoDictation` skips Handy.
- `-WithPowerToys` also installs PowerToys. winarchy doesn't need it, but its other tools (Peek, Always on top, ZoomIt) are handy.

## Keys

| Keys | Action |
|---|---|
| Super+Space or Super+Alt+Space | The menu: browse it, or type to search apps, windows, Settings pages and menu items; `=2+2` for maths |
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

## Menu and search

Super+Space (or Super+Alt+Space) opens the winarchy menu, laid out like Omarchy's:

| Section | What's in it |
|---|---|
| **Apps** | Every installed app. Ones you open often rank higher in search. |
| **Appearance** | Theme and accent colour, background, font, the bar, window borders and gaps, animations |
| **Trigger** | Toggles (pause tiling, taskbar, night light, do not disturb), capture, speed test |
| **Setup** | Defaults, audio, network, Bluetooth, displays, power, keyboard, region, config files, and every Windows Settings page |
| **Install** | Search winget, plus curated picks: AI, browsers, editors, terminals, gaming, dev tools, media, utilities |
| **Remove** | Uninstall with winget or Windows' Installed apps |
| **Update** | winarchy itself, all apps, Windows, Store apps, restart GlazeWM, the bar or dictation |
| **Learn** | Keybindings, plus docs for winarchy, Omarchy, GlazeWM and Zebar |
| **System** | About, lock, sleep, sign out, restart, shut down |

Arrow keys and Enter browse the menu. Start typing anywhere and it searches everything at once:

- every app
- every open window (pick one to jump to it, switching workspace if needed)
- every Settings page
- every menu item

Type maths such as `=12*7` or `15%*80` and Enter copies the result. File search isn't included; Explorer (Super+Shift+F) does that.

## Media tools

Omarchy's little utilities, built on ffmpeg, ImageMagick, ZXing.Net and Windows' own OCR. Everything runs on your PC.

| Menu item | What it does |
|---|---|
| **Trigger › Transcode** | Pick a picture or video, then a format and size; the result is saved next to the original and shown in Explorer. Pictures can become jpg, png, webp or avif at original, 2560, 1920 or 1280 px (it also reads HEIC). Videos can become mp4 at original, 4K, 1080p or 720p, a gif at 720, 480 or 360 px wide, or mp3 audio. |
| **Trigger › Capture › Screen recording** | Starts recording the monitor under the mouse; pick it again to stop. Saves an mp4 to Videos\Screen recordings, using the GPU encoder when there is one. There's no audio yet. |
| **Trigger › Capture › Text (OCR)** | Snip a region and its text is copied to the clipboard. |
| **Trigger › Capture › QR code** | Snip a QR code and its contents are copied to the clipboard. |
| **Setup › Network › Share Wi-Fi as QR code** | Shows the current Wi-Fi network as a QR code that phones scan to join. |

The installer adds ffmpeg and ImageMagick with winget (`-NoMediaTools` skips them). It downloads ZXing.Net 0.16.9 (Apache-2.0) from NuGet and checks it against a pinned hash. The scripts live in `~\.glzr\winarchy\tools`.

## Top bar

- **Windows logo** (top left) opens the winarchy menu, like Omarchy's logo.
- **Workspace numbers** switch workspaces when clicked.
- **Volume:**
  - Scroll over it to change the volume.
  - Hover to reveal a slider.
  - Click the speaker to mute or unmute.
  - Right-click for Windows sound settings.

## Dictation

winarchy uses [Handy](https://github.com/cjpais/Handy) for dictation. It's free and open source, and the speech model runs on your PC, so nothing you say leaves it. The installer installs Handy, but its first-run setup is yours to do once:

1. Open **Handy** from Super+Space and go through its setup: pick a speech model and allow the microphone.
2. Re-run `install.ps1`. It closes Handy, puts push-to-talk on **Right Ctrl**, sets Handy to start hidden at sign-in, and reopens it. If you already changed Handy's shortcut from its default (Ctrl+Space), your key is kept.

Then hold Right Ctrl, speak, and let go: the text is pasted where your cursor is. Esc cancels. Super+Space → Setup → Defaults → Dictation opens Handy.

Why not Right Alt like Omarchy? On Windows a held Right Alt also reaches the focused app and opens its menus. Right Ctrl does nothing on its own in apps.

## Customise

- **Bindings and look:** `~\.glzr\glazewm\config.yaml`, then Super+Ctrl+R to reload. The comment line above each binding is what Super+K shows.
- **Menu:** `~\.glzr\winarchy\menu.json`. Each item has a `label` and one action:
  - `run` (with optional `args`) for a program, URL or `ms-settings:` page.
  - `glaze` for a GlazeWM command.
  - `terminal` for PowerShell run in Windows Terminal.
  - `page` to jump to another page, or `items` for a submenu.
- **Background helper:** `~\.glzr\winarchy\settings.json` holds `hideTaskbar`, `blockStartMenu` and `autotile`. Changes take effect when GlazeWM restarts.
- **Taskbar:** Super+Space → Trigger → Toggle → Windows taskbar shows or hides it on the fly.
- **Top bar:** `~\.glzr\zebar\winarchyar.html` (`TEMP_UNIT` at the top switches between °F and °C).

## Uninstall

```powershell
.\uninstall.ps1            # keeps GlazeWM/Zebar installed
.\uninstall.ps1 -RemoveApps
```

This restores the taskbar, the Zebar bar and the GlazeWM config winarchy replaced, and removes the sign-in shortcut. Handy stays installed.

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

## Roadmap

Planned Omarchy features (automatic theming, an AI usage panel) are specced in [docs/SPEC.md](docs/SPEC.md).

## License

MIT, except `config/zebar/bar.html` and `styles.css`, which are adapted from Zebar's starter widget and stay under GPL-3.0 (see `config/zebar/NOTICE.md`).
