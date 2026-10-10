# Runbook: screenshot is captured but nothing lands in the terminal

User impact: the screenshot is taken, but its path (or image paste) never appears in the terminal session. All diagnostics are local; nothing is sent anywhere, so triage starts on the affected machine.

## 1. Turn on verbose diagnostics

Diagnostics are stable event names and severities. Set `HOTSHOT_VERBOSE_LOGGING=1` before launching to include redacted values.

- macOS: quit hotshot, run `HOTSHOT_VERBOSE_LOGGING=1 .build/release/hotshot` from a terminal (or watch Console.app, filter on `Hotshot`).
- Linux / Windows: set the variable before running `hotshot-capture.sh` / `hotshot-capture.ps1`; events go to `stderr`.

## 2. Match the last event to a cause

| Event | Meaning | Action |
|---|---|---|
| `watcher.open_failed` (error) | macOS could not open the screenshot directory, so nothing is watched. | Check the screenshot location exists and is readable (`defaults read com.apple.screencapture location`); restart hotshot. |
| `watcher.started` but no `watcher.new_screenshot` | Watching, but no new file matched. | Confirm the screenshot is saved to the watched directory, not the clipboard (clipboard mode uses `pasteboard.*` events). |
| `pasteboard.read_failed`, `pasteboard.png_conversion_failed`, `pasteboard.write_failed`, `clipboard.save_failed` | Clipboard image could not be read, converted, saved or written back to the pasteboard. hotshot refuses to auto-paste an image it could not save. | Retake the screenshot; check free disk space and write access to the screenshot folder. |
| `applescript.unavailable`, `applescript.error` (error) | macOS could not run the injection script. Most often Accessibility or Automation permission is missing or was revoked. | System Settings > Privacy & Security > Accessibility (and Automation): remove and re-add hotshot, then relaunch. |
| `watcher.quarantined_skipped` (warn) | The new file carries `com.apple.quarantine` — it was downloaded or received (browser, Mail, Messages, AirDrop), not captured — so watch mode refused to inject it. | Not a fault. Use "Inject last screenshot" if you really want that file. Do not bypass the check. |
| `injection.control_chars_refused`, `injection.shell_metachars_refused` (warn) | The filename was refused on purpose, to avoid typing something unsafe into a shell. | Not a fault. Fix the screenshot naming template so names contain no control characters or shell metacharacters. Do not bypass the check. |
| `clipboard.untrusted_refused` (warn) | macOS could not save the clipboard image, so auto-paste (or manual Ctrl-V inject) was skipped rather than pasting an image of unknown origin. | Check free disk space and write access to the screenshot folder, then copy the image again. Do not bypass the check. |
| `clipboard.no_terminal` (warn) | A clipboard image was detected but no terminal has been tracked. | Focus the target terminal once, then copy the image again. |
| `injection.focus_lost` (warn) | The terminal could not be brought back to the front after the capture (X11 and Windows), so nothing was typed. The screenshot is saved and on the clipboard. | Paste manually. Keep the terminal focused and avoid switching windows while selecting the region. |
| `injection.no_foreground_terminal` (warn, Windows) | No terminal window was focused when the hotkey was pressed. | Press the hotkey while the target terminal is focused. |
| `injection.sendkeys_failed` (warn, Windows) | SendKeys threw while typing the path. | Check the logged detail (for example access denied when the terminal runs elevated); run hotshot at the same privilege level as the terminal. |
| `injection.ydotool_failed` (warn, Wayland) | `ydotool` could not type the path. | Start the `ydotoold` daemon and confirm the user can access its socket. |
| `injection.tool_missing`, `clipboard.tool_missing` (warn, Linux) | The typing or clipboard helper named in the detail is not installed. | Install the tool named in the message (`xdotool`, `wtype` or `ydotool`; `xclip` or `wl-clipboard`). |
| `injection.xdotool_failed`, `injection.wtype_failed` (Linux) | Typed injection tool failed. | Verify `xdotool` (X11) or `wtype` (wlroots) is installed and matches the session type (`echo $XDG_SESSION_TYPE`). |
| `clipboard.xclip_failed`, `clipboard.wl_copy_failed`, `clipboard.copyq_failed` (Linux) | Clipboard tool failed. | Verify `xclip` (X11) / `wl-clipboard` (Wayland) / CopyQ is installed and a display is reachable. |
| Log line `no terminal tracked` | No terminal has been focused since hotshot started, so there is nowhere to inject. | Focus the target terminal once, then take the screenshot again. |
| `cannot determine tty ... defaulting to bracketed format` | CLI detection failed; the path is typed in the bracketed default form. | Informational. If the wrong format is typed, see the platform README for the supported CLIs. |

If no event is logged at all, hotshot is probably not running: relaunch it and look for `app.launched`.

## 3. Verify recovery

1. Take a fresh screenshot while the target terminal is focused.
2. Confirm the matching `watcher.new_screenshot` (or `pasteboard.loaded`) event appears, with no error following it.
3. Confirm the path or image appears in the terminal.

## 4. Escalate

If a regression follows a new build, follow [release-rollback.md](release-rollback.md) for that build and open an issue with the event names seen (not screenshot paths or clipboard contents). Review verbose logs before attaching them, as they may contain local paths.
