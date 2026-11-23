# winarchy: features to emulate from Omarchy

Planned features (sections 1, 3, 4 and 5 are built, 2 mostly). The goal for each is to get as close to the Omarchy experience as Windows allows. Wrapping existing open-source tools is preferred to building from scratch.

Omarchy references are to [basecamp/omarchy](https://github.com/basecamp/omarchy) (`quattro` branch, November 2026).

---

## 1. Media utilities in the menu (transcode, convert, capture)

> **Status: built (Nov 2026).**
> - Done: transcode (pictures and videos), screen recording (Super+Alt+R to start and stop, with a red REC timer in the bar that stops it when clicked), text (OCR), read QR, share Wi-Fi as QR, and "Convert with winarchy" on pictures and videos in Explorer's right-click menu (under Show more options on Windows 11). See the README's Media tools section.
> - Still open: screen recording with audio or webcam, and ASCII art.

### What Omarchy does

Small, menu-driven utilities, each a script that pops a picker and runs a CLI tool:

| Omarchy command | What it does |
|---|---|
| `omarchy-transcode` | Pick a picture or video (from ~/Pictures and ~/Videos, or a given path), then a format and size. Pictures go to jpg or png at high, medium or low size; videos go to mp4 or gif at 4k, 1080p or 720p. Built on ffmpeg and ImageMagick. |
| `omarchy-transcode-ascii` | Turns an image into ASCII art. |
| `omarchy-capture-screenshot` / `-region` | Screenshot of the whole screen or a region. |
| `omarchy-capture-screenrecording` (`-with-webcam`) | Screen recording, optionally with a webcam overlay. |
| `omarchy-capture-text` | OCR: grab text from a screen region. |
| `omarchy-capture-qr` | Read a QR code off the screen. |
| `omarchy-network-qr` | Show the Wi-Fi network as a QR code to share. |
| `omarchy-menu-images` | A thumbnail image picker, reused by the background and theme pickers. |

### winarchy plan

Add a **Tools** page to the menu, with matching launcher entries. Each item is a `terminal` or `run` action that calls a small PowerShell script shipped in the repo (`tools/*.ps1`). The installer installs the CLI dependencies with winget.

| Item | Windows approach | Dependency (winget) |
|---|---|---|
| Transcode picture or video | Pick a file, then a format and size, then run ffmpeg or ImageMagick. Output goes next to the input as `name-1080p.mp4`, for example. Also reads HEIC, WebP and AVIF. | `Gyan.FFmpeg`, `ImageMagick.ImageMagick` |
| Convert picture format | jpg, png, webp, avif or ico, at a chosen quality or size. | `ImageMagick.ImageMagick` |
| Video to GIF | Two-pass ffmpeg with a generated palette, for good-looking GIFs. | `Gyan.FFmpeg` |
| Compress video for sharing | H.264 or H.265 at a target file size. | `Gyan.FFmpeg` |
| Extract audio | mp3 or m4a from a video. | `Gyan.FFmpeg` |
| Screen recording | ffmpeg `ddagrab` (GPU capture). Start and stop from the menu or a hotkey, and show a red dot in the bar while recording. | `Gyan.FFmpeg` |
| Screenshot / region | Windows Snipping Tool (`ms-screenclip:`), already in the menu. | (built in) |
| Grab text (OCR) | The built-in Windows OCR API (`Windows.Media.Ocr`) on a region snip, with the result copied to the clipboard. | (built in) |
| Read QR from screen | Region snip, then decode it. | `zbar` or a small .NET QR decoder |
| Share Wi-Fi as QR | `netsh wlan show profile key=clear`, then a QR code shown in a small window. | QR encoder (`qrencode` or bundled) |
| ASCII art | Image to ASCII in the terminal. | `jp2a`-style tool or a small script |

**File picking:** default to Explorer's open dialog, which Windows users expect, or offer an fzf-in-terminal picker over Pictures, Videos and Downloads to match Omarchy's feel. Explorer could also get an optional "Transcode with winarchy" right-click entry.

**Open questions:**
- Explorer's open dialog, fzf, or both?
- Bundle a tiny QR library in `winarchy.exe`, or depend on external tools?

---

## 2. Automatic theming of everything (including third-party apps)

> **Status: mostly built (Nov 2026).**
> - Done: 8 themes (`themes/*.json`), `tools/theme.ps1` (set, next, list, restore), Super+Ctrl+Shift+Space picker and Appearance → Theme / Next theme. Targets: GlazeWM borders, Zebar bar, winarchy menu, Windows dark/light and accent, wallpaper, Windows Terminal, VS Code, Firefox (userChrome.css / userContent.css imports in every used profile, plus the stylesheet pref in user.js). Wallpapers: the user's own per theme (`backgrounds\<id>`), then three generated from the palette (glow, bands, dot grid), cycled with Next background. Previous settings are backed up on first use and restored on uninstall.
> - Left out by choice: Obsidian (vaults keep their own community themes).
> - Still open: Chromium browsers, a live preview in the picker, and following Windows' light/dark schedule.

### What Omarchy does

- Each theme is a folder (`themes/<name>/`). It holds a `colors.toml` palette, a set of wallpapers, and a few app-specific files such as `neovim.lua` and `vscode.json`.
- `omarchy-theme-set <name>` renders the templates in `default/themed/*.tpl` from that palette. There are templates for:
  - Terminals: alacritty, kitty, ghostty and foot.
  - Editors and tools: btop, neovim, helix and VS Code.
  - Desktop: Hyprland borders and the shell and bar.
  - Apps: Chromium, Obsidian CSS, Claude, Qt and GNOME apps, and even keyboard RGB.
- It then reloads everything live. Per-app setters do the parts that need more than a template (`omarchy-theme-set-browser`, `-obsidian`, `-vscode`, `-icons`, `-keyboard`).
- Backgrounds are cycled per theme (`omarchy-theme-bg-next`).

### winarchy plan

- **Theme format:** `themes/<name>/theme.json`, holding the palette (background, foreground, accent, the 16 ANSI colours, border colours and light or dark) plus wallpapers. Start by porting several Omarchy themes: Tokyo Night (the current default), Catppuccin, Gruvbox, Everforest, Rose Pine, Nord and Kanagawa.
- **Commands:**
  - `winarchy theme set <name>` renders templates and applies each target below.
  - Menu → Style → Theme opens a picker with previews.
  - Menu → Style → Next background cycles wallpapers.

| Target | How |
|---|---|
| GlazeWM borders | Rewrite `window_effects` colours in config.yaml, then `wm-reload-config`. |
| Zebar bar | Generate CSS variables in the winarchy pack. Zebar reloads on file change. |
| winarchy menu and launcher | Read the palette from the theme instead of hard-coded Tokyo Night. |
| Windows itself | Dark or light mode (`AppsUseLightTheme` / `SystemUsesLightTheme`), accent colour (`AccentColor` / DWM colorization), and wallpaper (`IDesktopWallpaper`, one per monitor). |
| Windows Terminal | Add or replace a `schemes` entry in settings.json, set it as the default profile's `colorScheme`, then hot-reload. |
| VS Code | Set `workbench.colorTheme` to the theme's matching marketplace theme, installing that extension if needed. |
| Obsidian | Write a CSS snippet into each vault's `.obsidian/snippets` and enable it. |
| Firefox / Chromium | Chromium: the theme colour policy, as Omarchy does. Firefox: generate and install a lightweight theme add-on, or `userChrome.css` as an opt-in. |
| PowerToys, Handy, Discord, Slack, Steam | Mostly follow Windows dark or light mode. Discord and Slack have no supported custom theming; client mods break their terms, so leave them out. |
| Cursor and keyboard RGB | Out of scope at first. Keyboard RGB could come later through OpenRGB. |

**Live reload** matters: Omarchy switches in about a second with no restarts. Each target should hot-reload where the app supports it, and say "takes effect on restart" where it doesn't.

**Open questions:**
- Ship Omarchy's own wallpapers (check their licences), or our own?
- Should the theme follow Windows' light and dark schedule automatically?

---

## 3. AI agent usage panel and account auto-switching

> **Status: built (Nov 2026).** `tools/agents.ps1` (usage, status, add, use, list, remove, mode), the bar readout with a hover summary, the AI panel (a second Zebar widget, `agents.html`: usage bars, reset countdowns, Use per account, auto-switch toggle, Add account; closes when it loses focus), and menu → AI.
> - Claude: usage from `https://api.anthropic.com/api/oauth/usage` with each account's Claude Code sign-in; an expired sign-in is refreshed by running `claude auth status` in that account's folder. Switching "seats" the account's sign-in in `~\.claude` (Omarchy's approach), so running sessions follow.
> - Codex: usage from `codex app-server` (`account/rateLimits/read`; .NET's stdin BOM needs a blank first line). Extra accounts get their own `CODEX_HOME` with sessions, prompts and settings linked to `~\.codex`; switching sets `CODEX_HOME` for new terminals.
> - Auto mode switches new sessions at the threshold to the account with the most headroom; manual mode notifies once.
> - Still open: more providers.

### What Omarchy does

- **An agents panel in the bar.** Hovering an agent shows its usage against the rolling **5-hour** and **weekly** limits.
  - Claude usage is collected from local Claude Code transcripts (`~/.claude/projects`) plus the limits reported by Anthropic's OAuth usage endpoint (`omarchy-agent-usage-claude`).
  - Codex/ChatGPT has a sibling collector, and there are about 20 others (Grok, Copilot, Cursor, OpenRouter, Ollama…).
  - Each collector prints one display-ready JSON record, and the panel only reads that.
- **Several accounts per agent:**
  - `omarchy-agent-account-add/list/use/rename/remove` manage them, each in its own config home.
  - `omarchy-agent-account-mode [claude|codex|grok] [manual|auto] [threshold]` sets what happens near the limit. In **auto**, new sessions switch to the account with the most headroom at the threshold (for example 90%). In **manual**, it notifies you and switches only when you say so.

### winarchy plan

- **Collectors:** `winarchy-agent-usage <provider>` (in C# inside `winarchy.exe`, or PowerShell) prints the same kind of JSON record:
  - plan, 5-hour % used and reset time, weekly % used and reset time, and the active account.
  - Claude: from `%USERPROFILE%\.claude` transcripts plus the usage endpoint the Claude Code CLI itself uses.
  - ChatGPT/Codex: from `%USERPROFILE%\.codex` session logs and its rate-limit headers.
  - Cache results for about 60 seconds.
- **Bar widget:** an icon per configured agent in the Zebar bar, coloured by headroom (green, amber, red).
  - Hover shows a tooltip with 5-hour and weekly bars and reset countdowns.
  - Click opens the agent menu.
- **Accounts:** each account gets its own config directory (`CLAUDE_CONFIG_DIR` for Claude Code, `CODEX_HOME` for Codex).
  - `winarchy agent account add|list|use|remove`.
  - "Use" sets the user environment variable (and broadcasts the change) so new terminals and sessions pick up that account.
  - Menu: AI → Accounts, Usage, Mode (manual / auto at N%).
- **Auto-switch:** `winarchy-daemon` checks usage every few minutes. Past the threshold:
  - **manual** shows a Windows toast: "Claude (work) at 92% of 5h. Switch to personal?"
  - **auto** switches the default account for *new* sessions to the one with the most headroom, then shows a toast. Running sessions are left alone, as in Omarchy.

**Open questions:**
- Which providers first? Proposal: Claude and ChatGPT/Codex.
- Check each provider's terms on running several accounts. The feature should be opt-in and say which account is active.
- Should the panel also cover the Claude desktop app and ChatGPT web usage, or only CLI agents? Omarchy's numbers come from the CLI agents and the account-level usage endpoints.

---

## 4. System tray in the bar (see and close background apps)

> **Status: shipped (Nov 2026).**
> - Built: the collapsible tray (count when collapsed, remembered between restarts), with left, double, right and middle clicks and hover passed to each app. Right-click → the app's Quit closes it, which covers the need.
> - Optional extras, not planned: the hover × / force-close, hidden icons, and tray apps in menu search. Zebar's systray output (3.3.1) gives only `id`, `tooltip` and the icon image, with no owner window or process, so closing from the bar would need the tooltip-matching approach below.

### Why

winarchy hides the taskbar, which also hides the notification area. Apps that live only in the tray (chat clients, sync tools, updaters, Handy itself) become invisible, and the only way to close them is Task Manager. Omarchy's Waybar shows a tray module for the same reason.

### What it should do

- **A collapsible tray in the Zebar bar,** next to the VPN and volume controls.
  - Collapsed (the default): one chevron icon with a count, for example `‹ 7`.
  - Expanded: the tray icons in a row, each with its tooltip on hover. Clicking the chevron again, or clicking elsewhere, collapses it.
  - Remember the expanded or collapsed state between restarts.
- **Per icon:**
  - Left click: the app's own left-click action (usually opens its window).
  - Right click: the app's own tray menu, which usually has Quit or Exit. This is the cleanest way to close an app, because the app shuts itself down properly.
  - Middle click, or a small × shown on hover: **close the app.** First ask it to close (WM_CLOSE to its windows, as Task Manager's "End task" does), then offer to force it after a few seconds if it's still running. Never force-close without that second confirmation.
- **Hidden icons:** a list in settings (by app name) of icons that should never show, such as ones that are always running and never need attention.
- **Search:** the winarchy menu also lists tray apps under Search, with "Close" as an action, so Super+Space → type the name → close works without the mouse.

### How

- **Icons:** Zebar 3.3 already has a `systray` provider. It gives each icon an id, tooltip and image, plus `onLeftClick`, `onRightClick`, `onMiddleClick` and hover handlers that forward to the app. That covers showing the icons and the app's own click actions and menu.
- **Closing:** the provider doesn't close apps, so the bar calls `winarchy.exe tray-close <id>`. That needs the process behind the icon:
  - Zebar knows each icon's owner window internally (`window_handle`). If its output exposes that, or the id is derived from it, `GetWindowThreadProcessId` gives the process.
  - If not, match the icon's tooltip and image against running processes (window titles, file description, product name), and fall back to a small picker when more than one matches.
  - Add `winarchy.exe` to the pack's `shellCommands` with an argsRegex limited to `^tray-close \S+$`.
- **Collapsing:** pure bar state in `bar.html`; no new privileges.

**Open questions:**
- Does Zebar's systray output give the owner window or process? Check the provider's output on this PC before choosing between the two closing approaches above.
- Close the whole app, or only that tray icon's process? Some apps run several processes; the safe default is the process that owns the icon, and its children.
- Should middle click close straight away (with the force step still confirmed), or always show a confirm first?

---

## 5. Toggles, indicators and more bar panels

From the Omarchy manual's Toggles, Top Bar, Reminders and Hotkeys chapters (November 2026).

**Built:**
- Toggles with Omarchy's keys: stay awake (Super+Ctrl+I), do not disturb (Super+Ctrl+Alt+,), night light (menu and bar), hide the bar (Super+Shift+Space), window gaps (Super+Shift+Backspace).
- Indicators next to the clock for the toggles that are on, plus pending reminders; hover to peek at the rest, click to switch.
- Reminders: the clock opens a calendar (ISO weeks) with a reminder list and form; winarchy-daemon pops them up.
- Audio panel (Super+Ctrl+A): default output and input, their volume, per-app volume and mute.
- Bluetooth panel (Super+Ctrl+B): radio switch, paired devices with battery and connection state.
- Now-playing widget: play / pause, next, previous.
- Quake console (Super+`): Windows Terminal's quake window, shown and hidden by winarchy-daemon so GlazeWM doesn't tile it.

**Windows differences:**
- Night light is winarchy's own colour filter (gamma ramps, like f.lux). Windows' night light keeps its state outside the registry on current builds and has no API.
- Do not disturb uses the undocumented settings object the Settings app uses (`CLSID_QuietHoursSettings`).
- Bluetooth can't connect or disconnect devices from the panel (no public API for classic devices); that stays in Settings.

**Open:** world clock, microphone widget, notification history (Win+N covers it), bar position and background style.

## 6. Before v0.1.0 becomes a full release

v0.1.0 is a GitHub pre-release until these are done:

- [ ] **Clean-PC test.** Turn on Windows Sandbox (admin PowerShell: `Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`, then restart). Run `.	ests\sandbox\start.ps1 -Ref v0.1.0` and read `tests\sandbox
esults
eport.txt`. Expect a fix or two on the first run, since the kit has never run.
- [ ] **No-admin install.** Also run `.	ests\sandbox\start.ps1 -User`. The per-user pieces were tested on their own (MSI unpacking, the font, path lookup), but a whole `-User` install hasn't run yet. The sandbox account is an admin, so this checks the per-user layout, not the lack of rights; a real check needs a standard-user account.
- [ ] **Real-key check of the drop-down.** Super+` (the key below Esc, matched by scan code) opens it and Super+W closes it. Keys injected from a script can't test the keyboard hook, so a person has to press them.
- [ ] **Then:** if everything passes, mark v0.1.0 as a full release. Otherwise fix what failed and tag v0.1.1, bumping both the README install URL and the `-Ref` default in install.ps1.

## 7. Window animations (waiting on GlazeWM)

GlazeWM 3.10.1 has no animations for windows moving, resizing or opening; tiled windows jump into place. Only Windows' own minimise, maximise and close animations play.

- Upstream PR [glzr-io/glazewm#1199](https://github.com/glzr-io/glazewm/pull/1199) adds move, resize and open animations. It is open but not merged, and testers report bugs (windows going transparent, the open animation playing on the wrong windows). [glzr-io/glazewm#1392](https://github.com/glzr-io/glazewm/pull/1392) (also workspace-switch slides) was closed.
- winarchy can't add these from outside: GlazeWM positions the windows, and animating them from the daemon would fight it.
- **Plan:** when a GlazeWM release ships animations, turn them on in `config/glazewm.yaml`, choosing short and subtle defaults with an option to switch them off. Forking GlazeWM just for animations isn't worth it (unsigned binary, upkeep); section 10 says when a fork is.

## 8. Today's tasks in the bar, from a Markdown note (planned)

Keep the day's to-dos in view: a line of text in the bar that scrolls sideways through your open tasks, read from an Obsidian note or any Markdown file, with a quick way to add, tick off or change them.

**Source**
- A Markdown file set in settings.json (`tasksFile`), or a daily-note pattern such as `C:\Vault\Daily\{yyyy-MM-dd}.md` so it follows Obsidian's daily note.
- Tasks are standard checklist lines: `- [ ] open`, `- [x] done`. Show only the open ones. Optionally only those under a heading (for example `## Today`) or due today (the Obsidian Tasks plugin's `📅 2026-11-22`).
- Re-read when the file changes (Obsidian, sync or another editor), using a file watcher rather than polling.

**In the bar**
- A ticker next to the clock (or centre): open tasks one after another, separated by a dot, scrolling slowly. It pauses on hover and shows nothing when there are no tasks.
- Hover: the full list. Click a task: tick it off (writes `- [x]` back to the file).
- A toggle to hide it, like the other bar toggles.

**Quick editing, like reminders**
- A key (and a menu item, Trigger → Tasks) opens a small input: type a task and press Enter to add it. The same panel lists today's tasks to tick off, edit or delete.
- From a terminal or script: `winarchy task add "call the bank"`, `winarchy task done 2`, `winarchy task list`.
- Writing to the file must be safe while Obsidian has it open: change only the task lines, keep everything else byte for byte, write atomically (SafeFile), and re-read just before writing so an edit made in Obsidian is never overwritten.

**Open questions**
- Which file: one fixed note, or the daily note with unfinished tasks carried over from yesterday?
- Where new tasks go: the end of the file, or under the `## Today` heading?
- How the ticker moves: a continuous scroll, or one task at a time every few seconds (easier to read, less distracting)?

## 9. Satisfying sounds (planned, optional)

Short, tactile sound effects for things you do, like a good mechanical keyboard. All optional: one switch turns them all off, and each sound can be turned off on its own.

**The tasks idea (section 8)**
- Add a task: a soda can cracking open.
- Tick a task off: an ice cube dropping into a glass.
- Last task of the day done: a longer pour and fizz, as a small reward.

**Other places it would feel good**

| Event | Sound | Default |
|---|---|---|
| Reminder pops up | soft kalimba or bell note | on |
| Screen recording starts / stops | camera record beep up / down | on (useful feedback) |
| Screenshot, text capture (OCR), QR scan | camera shutter | on |
| Theme change | a record needle drop | on |
| Background change | a page flip or slide-projector click | on |
| Stay awake on / off | a coffee pour / a mug set down | on |
| Night light on / off | a match strike / a soft blow-out | on |
| Do not disturb on | a door closing quietly | on |
| VPN connected / disconnected | a lock clicking shut / open | on |
| Other toggles (gaps, bar, taskbar) | a light switch click | on |
| Super+W closes a window | a soft pop | off (frequent) |
| Workspace switch | a quiet tick | off (frequent) |
| Menu opens | a faint paper rustle | off (frequent) |
| Something failed | a gentle low thud | on |

**Rules**
- Short (under about 400 ms) and quiet by default, with one volume setting.
- Things you do dozens of times an hour (switching workspaces, opening the menu, closing windows) start off.
- Silent while Do not disturb is on, and while a fullscreen app or game has focus.
- Played by winarchy itself from WAV files loaded in advance, so there's no delay (no PowerShell, no media player starting).
- Sounds must be free to ship with the repo: CC0 (for example from freesound.org, filtered to CC0) or recorded or made for winarchy. Keep a CREDITS file next to them.
- Settings: `sounds: true|false`, `soundVolume`, and per-event switches in settings.json, plus a toggle in menu → Toggles. A user can swap any sound by dropping a WAV with the same name into `~\.glzr\winarchy\sounds`.
- Default for new installs: off, with a one-line hint in the README and the Toggles menu, so nobody is surprised by noise at work.

## 10. Working with GlazeWM: on top first, a fork as the last resort

winarchy runs on the official, unmodified GlazeWM release. Everything winarchy adds sits on top of it: GlazeWM's config file, the Zebar widget pack, and winarchy's own helpers, which use GlazeWM's command-line tool and event feed. This keeps GlazeWM updates a drop-in and lets winarchy install onto, and uninstall from, a stock GlazeWM.

The cost is that winarchy can't fix a bug inside GlazeWM; it can only work around it. For example, the daemon restarts GlazeWM when [glzr-io/glazewm#1186](https://github.com/glzr-io/glazewm/issues/1186) traps it in a loop of error boxes. When a GlazeWM bug can't be fixed this way, go down this list:

1. **Work around it on top**, as above, if the workaround is reliable and doesn't fight GlazeWM.
2. **Fix it upstream:** a pull request to glzr-io/glazewm (Rust), so everyone gets the fix and there's nothing extra to maintain. Watch the issue and drop the workaround once a release has the fix.
3. **Fork GlazeWM** when a bug still hurts and can't be fixed from outside: there's no reliable workaround and upstream won't take the fix, or won't take it soon enough. The fork fixes the root cause.
   - Keep the fork small: upstream's code plus our fixes, each also sent upstream as a pull request, so the fork can be dropped once they're merged.
   - Merge upstream releases into it regularly, and pin the version winarchy installs, as with the MSI hashes today.
   - Work out signing (an unsigned exe trips SmartScreen and some company policies) and how `install.ps1` and `-User` get the fork instead of the winget package.
   - Keep the GPL-3.0 license and credit glzr.io.

---

## Suggested order

1. ~~**Media utilities.**~~ Built.
2. ~~**System tray in the bar.**~~ Shipped.
3. ~~**Theming.**~~ Mostly built (a few apps left). The core of the Omarchy look. Do GlazeWM, Zebar, the menu, Windows and Windows Terminal first, then the third-party apps.
4. ~~**AI usage panel and switching.**~~ Built. It depends on undocumented usage endpoints, so expect upkeep when they change.
5. ~~**Toggles and bar panels.**~~ Built.
