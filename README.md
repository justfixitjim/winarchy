# winarchy

Omarchy-style, keyboard-driven tiling for Windows 11. Super+key for everything, windows that tile themselves, and a single Super+Space launcher you search and arrow through.

It's a thin layer over good existing tools:

| Omarchy | winarchy |
|---|---|
| Hyprland tiling | [GlazeWM](https://github.com/glzr-io/glazewm), with a helper that adds Hyprland-style automatic splits |
| Waybar | [Zebar](https://github.com/glzr-io/zebar) bar at the top (workspaces, clock, AI usage, tray, VPN, volume, network, CPU / RAM / VRAM, weather in °F); the Windows taskbar is hidden |
| Walker (Super+Space) and the Omarchy menu | The `winarchy` menu: Omarchy's sections (Apps, Appearance, Trigger, Setup, Install, Remove, Update, Learn, System), searchable across apps, open windows and Settings pages, plus quick maths |
| Super+K keybindings | `winarchy keys`: a searchable cheat sheet read live from your config |
| Themes (Super+Ctrl+Shift+Space) | Eight themes that recolour borders, bar, menu, Windows, wallpaper, Terminal, VS Code and Firefox |
| Agents panel | Claude Code and Codex usage in the bar; optionally several accounts with auto-switching near the limit (off until you turn it on) |
| Audio, Bluetooth, network and clock panels | Click the bar (or Super+Ctrl+A / B / N, Super+Ctrl+Alt+R): pick outputs and set each app's volume, Bluetooth devices with battery, adapters and IPs, a calendar with reminders |
| Toggles and indicators | Stay awake (Super+Ctrl+I), do not disturb (Super+Ctrl+Alt+,), night light, hide the bar (Super+Shift+Space), no gaps (Super+Shift+Backspace), shown in the bar while on |
| Quake console (Super + the key below Esc) | Windows Terminal drops down from the top and hides again |
| Foot terminal | Windows Terminal made bare like foot: no tabs or title bar, JetBrainsMono Nerd Font, padding, theme colours |
| herdr (agent workspaces) | [herdr](https://github.com/herdrdev/herdr) on Super+Shift+Enter: AI coding agents side by side, with each one's state in a sidebar |
| Dictation on Right Alt (Superwhisper) | [Handy](https://github.com/cjpais/Handy): free, open-source dictation with local Whisper/Parakeet models. Hold **Right Ctrl** to talk |

## Install

winarchy is a young personal project (v0.1), so far run on one PC. Read [what it changes](#what-it-changes-and-how-to-undo-it) first; `.\uninstall.ps1` puts everything back.

**Needs:** Windows 11, [winget](https://learn.microsoft.com/windows/package-manager/winget/) (App Installer), and a normal (non-admin) PowerShell. Any keyboard layout and any number of monitors. Some of the apps' installers (GlazeWM, Zebar, ImageMagick, the font) ask for admin approval; if you can't give it, add `-User` and nothing will.

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/justfixitjim/winarchy/v0.1.0/install.ps1 | iex
```

That installs release v0.1.0. To pass options that way, run it as a script block:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/justfixitjim/winarchy/v0.1.0/install.ps1))) -KeepTerminal -NoHerdr
```

Or clone the repo and run `.\install.ps1`. What the installer does:

1. Installs GlazeWM, Zebar, Windows Terminal, JetBrainsMono Nerd Font, Handy, ffmpeg and ImageMagick with winget, skipping any already installed, and [herdr](https://github.com/herdrdev/herdr) with its official installer (per-user, no admin; it isn't in winget). With `-User`, GlazeWM and Zebar are instead unpacked from their official releases into `%LOCALAPPDATA%\Programs\glzr.io` (checked against pinned hashes), the font is installed for your account only, and ImageMagick is skipped.
2. Builds `winarchy.exe`, `winarchy-daemon.exe`, `winarchy-top.exe` and `winarchy-audio.exe` from `src\` using the C# compiler that ships with Windows. No prebuilt binaries are downloaded.
3. Writes `~\.glzr\glazewm\config.yaml` and `~\.glzr\winarchy\menu.json`, backing up anything it replaces. Workspaces are laid out for your monitors: the primary screen gets 1-5 and the others share 6-9.
4. Installs the winarchy top bar as a Zebar widget pack (`~\.glzr\zebar\winarchy`).
5. Gives Windows Terminal the foot-like look (see [Terminal](#terminal-and-agent-workspaces)), saving your old settings first.
6. Starts GlazeWM now and at every sign-in.

Re-run it any time to upgrade. Options:

- `-KeepConfig` keeps your existing config and menu.
- `-KeepTaskbar` leaves the taskbar visible.
- `-KeepStartMenu` lets a lone Super tap open Start.
- `-SkipApps` skips winget.
- `-Celsius` shows the bar's temperature in Celsius (the default is Fahrenheit).
- `-NoDictation` skips Handy.
- `-KeepTerminal` leaves Windows Terminal's look and colours alone (and skips the Nerd Font).
- `-NoHerdr` skips herdr.
- `-VpnName <name>` picks which Windows VPN connection the bar's VPN button controls (default: the first one found; `none` hides it).
- `-WithPowerToys` also installs PowerToys. winarchy doesn't need it, but its other tools (Peek, Always on top, ZoomIt) are handy.
- `-NoMediaTools` skips ffmpeg, ImageMagick and Explorer's "Convert with winarchy" entry.
- `-User` installs without admin: everything goes into your user profile (see step 1). Picture conversion needs ImageMagick, so it won't work unless an admin installs that.
- `-Ref main` (with `irm ... | iex`) installs the latest, untested changes instead of the release.

### What it changes, and how to undo it

winarchy's own changes are all per-user and need no admin. `.\uninstall.ps1` undoes all of it (`-RemoveApps` also removes GlazeWM and Zebar, wherever they were installed; the other apps stay).

| Change | Undo on its own |
|---|---|
| Hides the Windows taskbar (and sets it to auto-hide) | menu → Trigger → Toggle → Windows taskbar, or install with `-KeepTaskbar` |
| A lone Super tap no longer opens Start (Ctrl+Esc still does) | install with `-KeepStartMenu`, or `"blockStartMenu": false` in `~\.glzr\winarchy\settings.json` |
| GlazeWM tiles your windows; Zebar replaces the taskbar with a bar at the top | `glazewm command wm-exit`, or remove the GlazeWM shortcut from `shell:startup` |
| A background helper (`winarchy-daemon`) with a keyboard hook (see [antivirus](#antivirus)) | `winarchy-daemon --stop` |
| Windows Terminal's look and colours, VS Code and Firefox theme colours (old settings backed up first) | install with `-KeepTerminal`, or run `~\.glzr\winarchy\tools\theme.ps1 -Restore` |
| Your GlazeWM config and Zebar settings (backed up as `*.bak-<date>`) | install with `-KeepConfig` |
| Starts at sign-in: GlazeWM (which starts Zebar, the daemon and the menu) and Handy | remove them from `shell:startup` / Task Manager → Startup apps |
| Explorer's right-click "Convert with winarchy" on pictures and videos | install with `-NoMediaTools` |

It never touches your Claude Code or Codex sign-ins unless you turn on [account switching](#ai-usage-and-accounts); with it off it only reads them to show usage.

## Keys

| Keys | Action |
|---|---|
| Super+Space or Super+Alt+Space | The menu: browse it, or type to search apps, windows, Settings pages and menu items; `=2+2` for maths |
| Super+K | Every keybinding, searchable |
| Super+Escape | Lock / sleep / sign out / restart / shut down |
| Super+Ctrl+Shift+Space | Pick a colour theme |
| Super+Ctrl+Alt+Space | Pick a background (the theme's wallpapers, with previews) |
| Super+Alt+R | Start / stop screen recording |
| Super+` (the key below Esc, on any layout) | Drop-down terminal: show / hide; Super+W closes it |
| Super+Ctrl+I | Stay awake (no sleep or screen-off) on / off |
| Super+Ctrl+Alt+, | Do not disturb on / off |
| Super+Shift+Space / Super+Shift+Backspace | Hide / show the top bar; window gaps off / on |
| Super+Ctrl+A / B / N | Audio / Bluetooth / network panel |
| Super+Ctrl+Alt+R | Calendar and reminders |
| Super+Enter | Terminal |
| Super+Shift+Enter | Agent workspace (herdr) |
| Super+Shift+Ctrl+A | Your default coding agent (Claude Code, Codex, ...) in its own window |
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
| **Explorer › right-click › Convert with winarchy** | The same converter for the file you right-clicked, skipping the file picker. On Windows 11 it's under **Show more options** (or Shift+right-click). Pictures and videos only, one file at a time; `-NoMediaTools` leaves it out. |
| **Trigger › Capture › Screen recording** (Super+Alt+R) | Starts recording the monitor under the mouse; press it again, or click the red REC timer in the bar, to stop. Saves an mp4 to Videos\Screen recordings, using the GPU encoder when there is one. There's no audio yet. |
| **Trigger › Capture › Text (OCR)** | Snip a region and its text is copied to the clipboard. |
| **Trigger › Capture › QR code** | Snip a QR code and its contents are copied to the clipboard. |
| **Setup › Network › Share Wi-Fi as QR code** | Shows the current Wi-Fi network as a QR code that phones scan to join. |

The installer adds ffmpeg and ImageMagick with winget (`-NoMediaTools` skips them). It downloads ZXing.Net 0.16.9 (Apache-2.0) from NuGet and checks it against a pinned hash. The scripts live in `~\.glzr\winarchy\tools`.

## Top bar

The bar sits on the main monitor only (each extra bar costs over 100 MB of memory) and reserves its strip there, so windows tile below it. It always shows workspaces 1-5 (dim when empty), plus any workspace with windows on another monitor (dotted underline). To show it on every monitor, set `"monitorSelection": { "type": "all" }` in `~\.glzr\zebar\winarchy\zpack.json` and raise GlazeWM's top `outer_gap`.

- **Windows logo** (top left) opens the winarchy menu, like Omarchy's logo.
- **AI usage** (Claude Code, Codex): see [AI usage and accounts](#ai-usage-and-accounts).
- **Workspace numbers** switch workspaces when clicked, on whichever monitor they're on.
- **Clock** (centre): click for the calendar panel: the month with ISO week numbers (scroll or the arrows change month) and **reminders**. Type what to remind you of, pick 5, 10, 25 or 60 minutes (or type any number) and Add; when it's due a small themed card pops up top right with a chime, until you click it. From a terminal: `winarchy remind add 10 Tea`.
- **Indicators** (next to the clock): icons for whatever is on: a pending reminder (with its countdown), stay awake, do not disturb, night light. Hover the spot to see the ones that are off too; click any to switch it.
  - **Stay awake** keeps the PC from sleeping or turning the screen off, until you switch it off again (it survives a restart of GlazeWM).
  - **Do not disturb** is Windows' own, the same switch as in Settings > System > Notifications.
  - **Night light** warms the screen to about 4000 K, like Omarchy's. Windows' own night light can't be switched from code on current builds, so winarchy tints the displays itself (screenshots and recordings aren't tinted). Windows' version is still under Trigger > Toggle.
- **Now playing** (centre, when something plays in Windows' media controls: Spotify, a browser tab, ...): click to play / pause, middle-click for the next track, scroll for next / previous.
- **System tray** (replaces the hidden taskbar's tray): a `‹ 20`-style count; click it to show the tray icons.
  - Left-click or double-click an icon as you would on the taskbar.
  - Right-click opens the app's own menu; use its Quit or Exit to close a background app.
- **VPN** (shown if the PC has a Windows VPN connection in Settings > Network > VPN):
  - Green **VPN on** / grey **VPN off**.
  - Click to disconnect.
  - Click to connect: it uses Windows' own dialer and your saved sign-in. If the connection is set to prompt, Windows' sign-in window opens with your details filled in, and Enter connects.
  - To connect with no window at all, untick "Prompt for name and password" in that window's Properties > Options.
- **Network** (Wi-Fi signal or wired icon, with the Wi-Fi name): hover for your IP address; click for the network panel:
  - Each Wi-Fi and wired adapter with its state and an on / off switch, and for the connected ones: signal, band and channel (Wi-Fi), speed, IPv4 and IPv6 addresses, gateway, DNS and MAC address. Click an address to copy it.
  - The Wi-Fi switch works like the Quick Settings tile. Turning a wired adapter off or on needs an administrator, so Windows asks each time (UAC).
  - On Wi-Fi, **Password**: click *show* for the network's saved password, then click it to copy (no admin needed).
  - Public IP and country, fetched from Cloudflare (`1.1.1.1/cdn-cgi/trace`) when the panel opens, and live download and upload rates.
  - Network settings opens Windows' network page.
- **CPU, RAM and VRAM** (grouped, amber past 60%, red past 85%): hover for the totals; click for the process panel, a slim task manager:
  - Live CPU, memory and video-memory meters, then every program grouped like Task Manager's apps (`firefox 12`), sortable by CPU, RAM or VRAM. Type to filter by name or PID.
  - Click a program to see its individual processes. The × on a row ends it: click once to arm (**End?**), again to confirm. A program's × ends all its processes.
  - Programs running as administrator, and protected ones, can't be ended from here (the panel says so); Task Manager opens from the top corner.
  - Numbers come from `winarchy-top.exe`, a small helper built from `src\top.cs` that reads them the way Task Manager does. It runs only while the panel is open (plus a light one for the bar's VRAM figure).
- **Weather** (icon and temperature): click for a short forecast: now (feels-like, today's high and low, wind, humidity, chance of rain, UV, sunrise and sunset), the next 15 hours in 3-hour steps, and 5 days with each day's range on a shared scale. It comes from Open-Meteo, the same source as the bar's temperature, for the location Zebar estimates from your IP address, and shows the last forecast instantly while refreshing (at most every 10 minutes). `-Celsius` switches it to °C and km/h.
- **Volume:** scroll over it to change the volume, hover for a slider, right-click to mute. Click the speaker for the audio panel:
  - Every output and input; click one to make it the default (for all apps, like Quick Settings). The one in use has its volume slider and mute.
  - Each app playing sound with its own volume slider and mute (apps with several audio streams, like Discord or a browser, are one row).
  - The default-device switch and per-app volume come from `winarchy-audio.exe` (`src\audio.cs`); Windows has no public way to change the default device, so it uses the same interface as every audio-switcher tool.
- **Bluetooth** (shown when the PC has Bluetooth; a count when more than one device is connected): hover for connected devices and their battery; click for the Bluetooth panel: an on / off switch (like Quick Settings) and every paired device with its battery and whether it's connected. Pairing, connecting and removing devices are in Bluetooth settings, linked from the panel.

## Terminal and agent workspaces

Omarchy's terminal is foot: just text, no window chrome. winarchy keeps Windows Terminal (already fast, GPU-rendered and the terminal herdr supports on Windows) and strips it down the same way:

- **Focus mode:** no tab row or title bar. GlazeWM tiles the windows and herdr splits panes, so neither is needed. Ctrl+Shift+T still opens tabs and Ctrl+Tab switches them; Ctrl+Shift+P opens the command palette.
- **JetBrainsMono Nerd Font** (the NFM variant, so icons stay one cell wide) at 11 pt, 14 px padding, block cursor, no scrollbar, no bell.
- **Theme colours** for the text and Terminal's own menus, following the theme picker.

**Super+Shift+Enter** opens [herdr](https://herdr.dev) in a new Terminal window (also menu → AI → Agent workspace). It's a workspace manager for coding agents: run Claude Code, Codex and others in tiled panes, grouped into workspaces, with a sidebar showing which agents are working, blocked on a question, or idle. Sessions keep running when you close the window; run `herdr` again to reattach.

**Super+Shift+Ctrl+A** starts your default coding agent in its own Terminal window, in your home folder (like Omarchy's). Pick it in menu → AI → Default agent: Claude Code, Codex, OpenCode, Gemini CLI, GitHub Copilot CLI and a few others, whichever are installed. Until you pick one, it's the first installed. Right-clicking the AI usage in the bar does the same.

- `ctrl+b` then `?` lists its keys. Its config is `%APPDATA%\herdr\config.toml`.
- For more reliable agent status, herdr offers integrations: `herdr integration install claude` (or `codex`). They add hooks to that agent's own settings, so winarchy leaves that choice to you.
- Update with `herdr update`.

## AI usage and accounts

Like Omarchy's agents panel: the top bar shows how much of its 5-hour and weekly limits each AI agent's active account has used, for Claude Code and Codex (`Claude 42%  Codex 7%`, green, amber, then red near the limit). Hover for a quick summary; click for the AI panel: a usage bar per limit with its reset countdown and your switching threshold marked, a **Use** button on each other account, a star for your preferred account, the auto-switch toggle, and Add account. It shows the last numbers instantly and only re-checks when they're a few minutes old.

- **Account switching is off until you turn it on** (menu → AI → Account switching → Turn on, or the button in the AI panel), because it moves Claude Code and Codex sign-in files around. Usage shows either way.
- **Several accounts:** menu → AI → Claude Code (or Codex) → **Add account** opens a sign-in window. Sign in with the other account; the bar then shows both.
- **Switch account** moves the next account in. For Claude Code, winarchy swaps which sign-in `~\.claude` holds, so new and running `claude` sessions follow. For Codex, new terminals get that account (through `CODEX_HOME`); history, prompts and settings are shared between accounts.
- **Auto-switch at 90%:** when the active account passes 90% of a limit, new sessions move to the account with the most headroom, with a notification. **Alert only** (the default) just notifies.
- **Preferred account** (the star in the AI panel): the account you want to be on. Starring an account switches to it if it has room. When auto-switch moves you off it near a limit, it moves you back as soon as that account's limits reset.
- Usage is checked every few minutes, the way Claude Code's `/usage` and Codex itself read it. Sign-ins stay in their own folders and never leave the PC.
- The Claude **desktop app** keeps its own sign-in and isn't switched, but its usage still shows, because limits belong to the account.
- From a terminal: `~\.glzr\winarchy\tools\agents.ps1 status` (also `add`, `use`, `list`, `remove`, `mode`, `switching on|off`).

## Themes

Super+Ctrl+Shift+Space (or menu → Appearance → Theme) switches every colour at once, like Omarchy's themes: Tokyo Night (the default), Catppuccin Mocha and Latte, Gruvbox, Everforest, Rosé Pine, Nord and Kanagawa. Appearance → Next theme cycles through them.

A theme changes:
- **GlazeWM** window borders, the **top bar** and the **winarchy menu**.
- **Windows:** dark or light mode and the accent colour.
- **Wallpaper:** your own pictures from `~\.glzr\winarchy\backgrounds\<theme id>` (for example `backgrounds\gruvbox`), then three drawn from the theme's colours. Super+Ctrl+Alt+Space (or Appearance → Pick background) lists them with small previews: Enter sets one and the menu stays open, so you can arrow down and press Enter again. Appearance → Next background also stays open; keep pressing Enter to cycle.
- **Windows Terminal:** a `winarchy` colour scheme, set as the default, plus a matching Terminal theme for its menus.
- **VS Code:** the matching colour theme, installing its extension if needed.
- **Firefox:** toolbars, tabs, menus and the new tab page (through `userChrome.css`, which winarchy switches on). Shows the next time Firefox starts. Your own `userChrome.css` is kept; winarchy only adds one import line.

To leave some out, add them to `~\.glzr\winarchy\settings.json`, for example `"themeSkip": ["vscode", "wallpaper"]`. The first theme you pick saves your previous Windows colours, wallpaper, Terminal and VS Code settings (and Firefox's changes are removed), and uninstalling puts them back (`tools\theme.ps1 -Restore` does it by hand). Themes are JSON files in `~\.glzr\winarchy\themes`; copy one to make your own.

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
- **Background helper:** `~\.glzr\winarchy\settings.json` holds `hideTaskbar`, `blockStartMenu`, `autotile` and `quakeTerminal` (Super+`), `barWatchdog`, `tidyWorkspaces`, `keepTiles`, plus the `stayAwake` and `nightLight` toggles and `defaultAgent`. Changes take effect when GlazeWM restarts.
- **Taskbar:** Super+Space → Trigger → Toggle → Windows taskbar shows or hides it on the fly.
- **Top bar:** `~\.glzr\zebar\winarchy\bar.html` (`TEMP_UNIT` at the top switches between °F and °C).

## Uninstall

```powershell
.\uninstall.ps1            # keeps GlazeWM/Zebar installed
.\uninstall.ps1 -RemoveApps
```

This restores the taskbar, the Zebar bar, the GlazeWM config and the Windows Terminal settings winarchy replaced, and removes the sign-in shortcut. Handy, the Nerd Font and herdr stay installed (herdr lives in `%USERPROFILE%\.herdr` and `%LOCALAPPDATA%\Programs\Herdr`).

## How it works

- **`winarchy.exe`** is a small WinForms app. It provides the menu, the cheat sheet, and launchers that find your default browser and installed apps through the Start menu's app list, so one config works on any PC. GlazeWM starts a resident copy at sign-in (`winarchy.exe --resident`), so Super+Space only has to show a window that's already loaded; if it isn't running, the menu opens the normal way and starts it.
- **`tools\*.ps1`** are the media tools, the theme switcher (`theme.ps1`) and the AI accounts tool (`agents.ps1`). The bar runs `agents.ps1 usage`, which answers from a cache and only re-checks usage every few minutes.
- **The bar and its panels** (`config\zebar`) are plain JavaScript pages with htm templates, so nothing is compiled when they open. Their libraries (React, htm, Zebar's client) and the Nerd Fonts icon font are bundled in `config\zebar\vendor`, so the bar works without internet. `vendor\build.ps1` rebuilds that bundle from the pinned versions in `vendor\package.json` (needs Node.js; only for updating them).
- **`winarchy-top.exe`** reads CPU, memory and video memory per process for the bar and the process panel, and every 5 seconds tells the bar which toggles are on.
- **`winarchy-audio.exe`** sets each app's volume and the default audio device for the audio panel.
- **`winarchy toggle awake|dnd|nightlight|bar|gaps`**, **`winarchy remind ...`** and **`winarchy panel <name>`** are what the keys, menu items and bar buttons run. Do not disturb goes through the same settings object Windows' Settings app uses; hiding the bar stops Zebar and starts it again (waiting long enough that it doesn't come up grey); gaps rewrites the `gaps:` block of the GlazeWM config and reloads it, keeping your values to put back.
- **`winarchy-daemon.exe`** is started by GlazeWM and does these things:
  - **Start menu blocking.** GlazeWM swallows Super+key combos, which makes Windows think Super was tapped alone and open Start. The daemon injects an unassigned "mask" key (0xE8) when Super goes down, so that never happens.
  - **Taskbar hiding.** It auto-hides the taskbar, then hides it outright.
  - **Automatic splits.** It listens on GlazeWM's IPC socket and sets each focused window's split direction from its shape, giving Hyprland-style dwindle tiling.
  - **Stay awake and night light.** It holds Windows' "keep the system and display on" request, and sets each display's colour ramp (re-applying it after sleep or a display change).
  - **Bar watchdog.** Once in a while Zebar starts without its local web server and the bar is just a grey strip. Every 5 seconds the daemon checks; if Zebar is running but its server isn't, it restarts Zebar (at most 3 times in 10 minutes). It also keeps the bar's strip reserved: when monitors wake from sleep or are plugged back in, Windows sometimes forgets that strip and windows get tiled over the bar, so the daemon reserves it again within a couple of seconds. Turn both off with `"barWatchdog": false`.
  - **Reminders.** It watches `reminders.json` and pops each one up when it's due.
  - **Drop-down terminal.** On Super+` it opens Windows Terminal's quake window with the tab title `winarchy-dropdown` (which GlazeWM's window rules ignore, so it isn't tiled), and shows or hides it after that. Terminal also hides it by itself when you click elsewhere. Super+W closes it (GlazeWM's own Super+W can't see it, so the daemon handles that key while it's in front).
  - **Workspaces back in place.** GlazeWM ties workspaces to monitors by number, and the numbers shift while a monitor sleeps or is unplugged, so workspace 1 could end up on a side screen and stay there. When monitors are added or removed (and when GlazeWM starts), the daemon moves each workspace back to its own monitor. Workspaces you move yourself with Super+Alt+Arrows stay put until then. Turn it off with `"tidyWorkspaces": false`.
  - **Windows kept in their tiles.** Some apps resize their own window after GlazeWM has tiled it. VLC, for example, grows to the video's size when a file starts playing, so part of the video ends up hidden behind the neighbouring windows. When a tiled window stops matching its tile, the daemon asks GlazeWM to redraw, which puts it back within about a second. Turn it off with `"keepTiles": false`.

## Antivirus

The helpers are built on your PC from the source in `src\`, so they're unsigned, and `winarchy-daemon` installs a keyboard hook and sends one key press of its own. That is what stops a lone Super tap from opening Start (and runs Super+` and Super+W on the drop-down terminal). It acts only on Super, the key below Esc and W, and never records, stores or sends any key presses. Some antivirus tools flag that pattern; if yours does, the code is in `src\daemon.cs` (`SuperKey`), or install with `-KeepStartMenu` to run without blocking Start.

## Known limits

- Some workplaces only allow programs from Program Files (AppLocker or similar). winarchy builds its helpers in your profile, so it won't run there, with or without `-User`.
- Now and then Zebar starts without its local web server and the bar is a grey strip; the daemon notices and restarts it within about 20 seconds.
- Night light is a colour filter on the displays, so it doesn't show in screenshots or recordings, and it can briefly drop after sleep (it's put back within 5 seconds).
- The bar is on the main monitor only (see [Top bar](#top-bar)).
- Windows running as administrator are only tiled if GlazeWM runs as administrator too.
- Tested on Windows 11 at 125% scaling with three monitors and a US keyboard. If something looks wrong on yours, please [open an issue](https://github.com/justfixitjim/winarchy/issues/new/choose).

## Notes

- **Trying a change on a clean PC:** `.\tests\sandbox\start.ps1` installs winarchy in Windows Sandbox, checks it, uninstalls it and checks again, writing `tests\sandbox\results\report.txt`. Add `-Ref v0.1.0` to test a release the way users get it.

- GlazeWM 3.10.1 can't parse quoted program paths in `shell-exec`, so the config writes paths unquoted. Spaces in them are fine.
- Tray icons live in the bar's collapsible tray (click the `‹ count`); right-click one for the app's own menu. Icons left behind by apps that crashed or were killed disappear within 30 seconds.

## Roadmap

What's built and what's still open (Chromium theming, a live theme preview, recording with audio) is tracked in [docs/SPEC.md](docs/SPEC.md).

## License

MIT, except `config/zebar/bar.html` and `styles.css`, which are adapted from Zebar's starter widget and stay under GPL-3.0 (see `config/zebar/NOTICE.md`).
