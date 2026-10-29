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
| Gemini CLI | `@` + backslash-escaped path + space |
| unknown | bracketed (historical default) |

claude + copilot/aider/opencode in the same terminal process tree (e.g. gnome-terminal / kitty / Windows Terminal tabs) -> escaped bare path, because the focused tab cannot be told apart and every supported CLI accepts the escaped path. Gemini CLI gets its `@path` form only when it is the only known CLI in the tree.

This is the same clipboard/typing contract as the macOS app.

## Install

First choose helpers for your desktop environment (DE: GNOME, KDE, sway, etc.)
and display system. X11 and Wayland are two systems Linux uses to display
windows. In a terminal, `echo "$XDG_SESSION_TYPE"` and
`echo "$XDG_CURRENT_DESKTOP"` can help identify your session.
The Wayland example below is for wlroots-based desktops such as sway and
hyprland, not every Wayland desktop.

Before installing, read [focus tracking](#parity-notes): X11, sway and hyprland
can identify the target window's process ID (PID). Other Wayland compositors
cannot query focus here and use the bracketed default, typing into whichever
window receives focus. Start with `--no-type` if that is unsuitable.

### Dependencies

Install Git for the clone route and the helpers for **one** matching session type.

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

### Install the script

```bash
git clone https://github.com/hivecommons/hotshot.git
cd hotshot/linux
./install.sh                 # ordinary install: ~/.local/bin/hotshot-capture
```

Choose **one** installer variant. Instead of the last command, GNOME users
can run `./install.sh --gnome-hotkey` to also bind Ctrl+Shift+PrintScreen.
For a custom destination, use `./install.sh --prefix DIR` instead.
The installer reports missing helpers for your session type.
Uninstall from this checkout with `./install.sh --uninstall`.

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
- `--dir DIR`: save screenshots to DIR (a relative path or leading `~` is resolved to an absolute path)

For a first capture, focus the terminal with your signed-in AI CLI, press the
bound hotkey, and select a harmless region. Confirm a PNG in the configured
folder and a path in the terminal input; press Enter when ready. With
`--no-type`, expect only the file and clipboard image. If capture fails, check
the installer's missing-helper report and the dependencies for your session;
if only typing fails, read [focus tracking](#parity-notes) and [Logging](#logging).

## Parity notes

- **Clipboard**: MIME identifies a clipboard data format, such as `image/png`.
  X11/Wayland clipboards have a single owner and `xclip` /
  `wl-copy` serve one MIME target per invocation, so by default the clipboard
  carries the **image only** (paste with Ctrl-V in Claude Code or GUI apps);
  the typed injection delivers the path. If [CopyQ](https://hluk.github.io/CopyQ/)
  is running, hotshot puts `image/png`, the `text/plain` path, and a percent-encoded
  `text/uri-list` file URL on a single clipboard entry, matching macOS.
- **Focus tracking**: instead of a menu-bar app that remembers your last
  terminal, the Linux port captures the focused window at hotkey press time —
  press the hotkey while your terminal is focused, then select the region.
  On X11, if that window cannot be brought back to the front afterwards,
  nothing is typed (`injection.focus_lost`); the screenshot is still saved
  and on the clipboard. On Wayland, focused-window PID detection is implemented for sway and
  hyprland, and the same check applies there: if a different window has
  focus once the capture finishes, nothing is typed (`injection.focus_lost`).
  On other compositors there is no focus query, so CLI detection falls back
  to the bracketed default (Claude-compatible) and the path is typed into
  the window the compositor returns focus to.
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
