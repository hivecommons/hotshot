# hotshot for Windows

Take a screenshot, and it lands in your terminal — the Windows port of
hotshot. A dependency-light PowerShell script driven by a global hotkey:
press the hotkey while your terminal is focused, snip a region with the
built-in Snipping Tool overlay, and hotshot:

1. Saves the PNG to `%USERPROFILE%\Pictures\hotshot\hotshot-YYYYMMDD-HHMMSS.png`
   (override with the `HOTSHOT_DIR` environment variable or `-Dir`)
2. Rewrites the clipboard with one multi-format entry: the **image**, the
   **plain-text path**, and a **file drop list** (the Explorer-copy
   equivalent of macOS' file URL) — so Ctrl-V works in Claude Code, GUI
   apps, and CLIs that paste text
3. Detects which AI CLI is running in the terminal that was focused before
   the overlay (by walking its child processes — Windows Terminal, conhost,
   etc.), brings the terminal back to the front, and types the format that
   CLI understands:

| CLI in focused terminal | Typed injection |
|---|---|
| Claude Code (`claude`) | `[C:\path\to\shot.png] ` (bracketed) |
| GitHub Copilot CLI / aider / OpenCode | bare path (double-quoted if it contains spaces) + space |
| unknown | bracketed (historical default) |

This is the same clipboard/typing contract as the macOS app.

## Install

Everything uses built-in Windows components (PowerShell 5.1+, Snipping Tool).

```powershell
git clone https://github.com/hivecommons/hotshot.git
cd hotshot\windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer copies the scripts to `%LOCALAPPDATA%\Hotshot` and creates a
Start Menu shortcut with the global hotkey **Ctrl+Alt+H** (shortcut hotkeys
are limited to Ctrl+Alt/Ctrl+Shift combos — pick another with
`-Hotkey 'Ctrl+Shift+F12'` etc.). Uninstall with `install.ps1 -Uninstall`.

### Optional: AutoHotkey v2 for an instant hotkey

Start Menu shortcut hotkeys can take a second to launch. If you have
[AutoHotkey v2](https://www.autohotkey.com) installed, run
`%LOCALAPPDATA%\Hotshot\hotshot.ahk` (or put a shortcut to it in
`shell:startup`) and press **Ctrl+Shift+PrintScreen** instead.

## Usage

1. Focus the terminal running your AI CLI.
2. Press the hotkey.
3. Snip a region with the Snipping Tool overlay.
4. hotshot saves the PNG, loads the clipboard, refocuses your terminal, and
   types the path in the right format. Press Enter.

Manual invocation:

```powershell
powershell -ExecutionPolicy Bypass -File hotshot-capture.ps1 [-NoType] [-Dir C:\shots]
```

## Parity notes

- **Capture UI**: uses the native `ms-screenclip:` Snipping Tool overlay
  (Windows 10 1809+) instead of custom capture code — same
  select-a-region experience as macOS ⌘⇧4.
- **Focus tracking**: the foreground window at hotkey press time is treated
  as the target terminal (the macOS app tracks the last-clicked terminal).
  Press the hotkey while the terminal is focused.
- **Typed path format**: Windows shells don't use POSIX backslash escaping,
  so the "bare escaped path" becomes a double-quoted path when it contains
  spaces — the Windows drag-and-drop equivalent.
- **No file watcher**: the hotkey performs capture + inject in one step.
  Win+Shift+S and other native shortcuts are unaffected.

## Logging

Diagnostics are written as stable event names and severities and normally
omit the screenshot directory, filenames, and other local values — matching
the macOS app. Set the `HOTSHOT_VERBOSE_LOGGING=1` environment variable
before running `hotshot-capture.ps1` to include the redacted values for
local debugging. This stays local only; no telemetry is sent anywhere.
