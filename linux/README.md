# hotshot for Linux

Take a screenshot, and it lands in your terminal — the Linux port of hotshot.
One dependency-light shell script; no daemon. You bind it to a hotkey with
your desktop environment, press the hotkey, select a region, and hotshot:

1. Saves the PNG to `~/Pictures/hotshot/hotshot-YYYYMMDD-HHMMSS-mmm.png`
   (milliseconds, plus a `-N` suffix if the name is already taken; override
   the folder with `HOTSHOT_DIR` or `--dir`; `~/Pictures` is resolved with
   `xdg-user-dir PICTURES` when available, or an exported `XDG_PICTURES_DIR`)
2. Loads the clipboard with the image (and the text path too when CopyQ is
   running — see [Parity notes](#parity-notes))
3. Detects which AI CLI is running in the terminal that was focused when you
   pressed the hotkey (by walking its child processes under `/proc`) and
   types the format that CLI understands:

| CLI in focused terminal | Typed injection |
|---|---|
| Claude Code (`claude`) | `[/path/to/shot.png] ` (bracketed) |
| GitHub Copilot CLI / aider / OpenCode | bare backslash-escaped path + space |
| unknown | bracketed (historical default) |

This is the same clipboard/typing contract as the macOS app.

## Install

```bash
git clone https://github.com/hivecommons/hotshot.git
cd hotshot/linux
./install.sh                 # installs to ~/.local/bin/hotshot-capture
./install.sh --gnome-hotkey  # also binds Ctrl+Shift+PrintScreen on GNOME
```

The installer reports which dependencies are missing for your session type.

### Dependencies

| | X11 | Wayland |
|---|---|---|
| Capture | `maim` (or `scrot`) | `grim` + `slurp` |
| Clipboard | `xclip` | `wl-clipboard` (`wl-copy`) |
| Typed injection | `xdotool` | `wtype` (wlroots) or `ydotool` |
| Focused-window PID | `xdotool` | `swaymsg`/`hyprctl` + `jq` |
| Multi-format clipboard (optional) | CopyQ | CopyQ |

Debian/Ubuntu one-liners:

```bash
# X11
sudo apt install maim xclip xdotool
# Wayland (wlroots: sway, hyprland, ...)
sudo apt install grim slurp wl-clipboard wtype jq
```

## Hotkey binding

`install.sh` prints per-DE instructions. Examples:

- **GNOME**: `./install.sh --gnome-hotkey` (binds Ctrl+Shift+PrintScreen), or
  Settings > Keyboard > Custom Shortcuts
- **KDE**: System Settings > Shortcuts > Custom Shortcuts
- **sway**: `bindsym Ctrl+Shift+Print exec ~/.local/bin/hotshot-capture`
- **hyprland**: `bind = CTRL SHIFT, Print, exec, ~/.local/bin/hotshot-capture`
- **sxhkd**:

  ```
  ctrl + shift + Print
      ~/.local/bin/hotshot-capture
  ```

## Usage

```
hotshot-capture [--region|--full] [--no-type] [--dir DIR]
```

- `--region` (default): drag-select a region
- `--full`: capture the whole screen
- `--no-type`: skip the typed injection (clipboard + file only)
- `--dir DIR`: save screenshots to DIR

## Parity notes

- **Clipboard**: X11/Wayland clipboards have a single owner and `xclip` /
  `wl-copy` serve one MIME target per invocation, so by default the clipboard
  carries the **image only** (paste with Ctrl-V in Claude Code or GUI apps);
  the typed injection delivers the path. If [CopyQ](https://hluk.github.io/CopyQ/)
  is running, hotshot puts **both** `image/png` and the text path on the
  clipboard, matching macOS exactly.
- **Focus tracking**: instead of a menu-bar app that remembers your last
  terminal, the Linux port captures the focused window at hotkey press time —
  press the hotkey while your terminal is focused, then select the region.
  On X11, if that window cannot be brought back to the front afterwards,
  nothing is typed (`injection.focus_lost`); the screenshot is still saved
  and on the clipboard. On Wayland, focused-window PID detection is implemented for sway and
  hyprland; on other compositors CLI detection falls back to the bracketed
  default (Claude-compatible).
- **No file watcher**: the hotkey performs capture + inject in one step, so
  there is nothing to watch. Your DE's native screenshot shortcuts are
  unaffected.

## Logging

Diagnostics go to `stderr` as stable event names and severities (e.g.
`hotshot [WARN] injection.control_chars_refused`) and normally omit the
screenshot directory, filenames, and other local values — matching the macOS
app. Set `HOTSHOT_VERBOSE_LOGGING=1` before running `hotshot-capture.sh` to
include the redacted values for local debugging. This stays local only; no
telemetry is sent anywhere.
