# winarchy: features to emulate from Omarchy

Planned features, not built yet. The goal for each is to get as close to the Omarchy experience as Windows allows. Wrapping existing open-source tools is preferred to building from scratch.

Omarchy references are to [basecamp/omarchy](https://github.com/basecamp/omarchy) (`quattro` branch, November 2026).

---

## 1. Media utilities in the menu (transcode, convert, capture)

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

## Suggested order

1. **Media utilities.** Mostly ffmpeg and ImageMagick wrappers, so quick wins.
2. **Theming.** The core of the Omarchy look. Do GlazeWM, Zebar, the menu, Windows and Windows Terminal first, then the third-party apps.
3. **AI usage panel and switching.** It depends on undocumented usage endpoints, so expect upkeep when they change.
