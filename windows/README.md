# hotshot for Windows

Take a screenshot, and it lands in your terminal — the Windows port of
hotshot. A dependency-light PowerShell script driven by a global hotkey:
press the hotkey while your terminal is focused, snip a region with the
built-in Snipping Tool overlay, and hotshot:

1. Saves the PNG to `%USERPROFILE%\Pictures\hotshot\hotshot-YYYYMMDD-HHMMSS-mmm.png`
   (milliseconds, plus a `-N` suffix if the name is already taken; override
   the folder with the `HOTSHOT_DIR` environment variable or `-Dir`; relative paths and a leading `~` are resolved to an absolute path)
2. Rewrites the clipboard with one multi-format entry: the **image**, the
   **plain-text path**, and a **file drop list** (the Explorer-copy
   equivalent of macOS' file URL) — so Ctrl-V works in Claude Code, GUI
   apps, and CLIs that paste text
3. Detects which AI CLI is running in the terminal that was focused before
   the overlay (by walking its child processes — Windows Terminal, conhost,
   etc.), brings the terminal back to the front, and — only if it really is
   in the foreground again — types the format that
   CLI understands:

<details>
<summary>Advanced reference: CLI process detection and Windows path formats</summary>

| CLI in focused terminal | Typed injection |
|---|---|
| Claude Code (`claude`) | `[C:\path\to\shot.png] ` (bracketed) |
| GitHub Copilot CLI / aider / OpenCode | bare path (double-quoted if it contains spaces or shell metacharacters; refused if it contains `"`, `$` or `` ` ``) + space |
| Gemini CLI (`gemini`) | `@"C:\path\to\shot.png" ` (`@` plus the always double-quoted raw path; refused if it contains `"`) |
| unknown | bracketed (historical default) |

Two or more of claude / copilot / aider / opencode / gemini in the same terminal process tree (e.g. gnome-terminal / kitty / Windows Terminal tabs) -> bare path, because the focused tab cannot be told apart and every supported CLI accepts the escaped path.

This is the same clipboard/typing contract as the macOS app.

</details>

## Install

Capture uses built-in Windows components (PowerShell 5.1+, Snipping Tool on
Windows 10 1809+). The clone route also requires Git. Have a supported coding
assistant installed and signed in before your first capture.
Run the following commands in **PowerShell**. `-ExecutionPolicy Bypass` applies
to that PowerShell process only; it does not permanently change your policy.
Review the downloaded scripts before allowing them to run, and respect any
organization-enforced policy.

```powershell
git clone https://github.com/hivecommons/hotshot.git
cd hotshot\windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer copies the scripts (including the required `HotshotCapture.psm1` module) to `%LOCALAPPDATA%\Hotshot` and creates a
Start Menu shortcut with the global hotkey **Ctrl+Alt+H** (shortcut hotkeys
are limited to Ctrl+Alt/Ctrl+Shift combos — pick another with
`-Hotkey 'Ctrl+Shift+F12'` etc.). Uninstall with `install.ps1 -Uninstall`.

### Optional: AutoHotkey v2 for an instant hotkey

Start Menu shortcut hotkeys can take a second to launch. If you have
[AutoHotkey v2](https://www.autohotkey.com) installed, press Win+R and enter
`%LOCALAPPDATA%\Hotshot\hotshot.ahk`. To launch it at sign-in, enter
`shell:startup` in Win+R and put a shortcut to that file in the folder that
opens. Press **Ctrl+Shift+PrintScreen** instead.

## Usage

1. Focus the terminal running your AI CLI.
2. Press the hotkey.
3. Snip a region with the Snipping Tool overlay.
4. hotshot saves the PNG, loads the clipboard, refocuses your terminal, and
   types the path in the right format. Press Enter.

Confirm the PNG exists in your Pictures `hotshot` folder and the terminal input
contains the path before submitting. If it does not, confirm you focused the
terminal before capture and check [Logging](#logging); a focus failure can leave
the file and clipboard intact without typing anything.

Manual invocation from the **installed folder**, not the checkout:

```powershell
cd "$env:LOCALAPPDATA\Hotshot"
powershell -ExecutionPolicy Bypass -File .\hotshot-capture.ps1
```

Optionally append `-NoType` to save and copy without typing, or `-Dir C:\shots`
to choose a destination folder.

## Parity notes

- **Capture UI**: uses the native `ms-screenclip:` Snipping Tool overlay
  (Windows 10 1809+) instead of custom capture code — same
  select-a-region experience as macOS ⌘⇧4.
- **Focus tracking**: the foreground window at hotkey press time is treated
  as the target terminal (the macOS app tracks the last-clicked terminal).
  Press the hotkey while the terminal is focused.
- **Typed path format**: Windows shells don't use POSIX backslash escaping,
  so the "bare escaped path" becomes a double-quoted path when it contains
  spaces or shell metacharacters — the Windows drag-and-drop equivalent. A
  path containing `"`, `$` or `` ` `` is not typed at all (the screenshot is
  still saved and on the clipboard), because double quotes cannot protect a
  literal quote and PowerShell interpolates `$(...)` and backtick escapes
  inside them.
- **No file watcher**: the hotkey performs capture + inject in one step.
  Win+Shift+S and other native shortcuts are unaffected.

## Logging

Diagnostics are written as stable event names and severities and normally
omit the screenshot directory, filenames, and other local values — matching
the macOS app. Set the `HOTSHOT_VERBOSE_LOGGING=1` environment variable
before running `hotshot-capture.ps1` to include the redacted values for
local debugging. This stays local only; no telemetry is sent anywhere.
