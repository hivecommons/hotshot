#!/usr/bin/env bash
# hotshot for Linux — capture a screenshot, load the clipboard, and type the
# path into the focused terminal in the format its AI CLI understands.
#
# Behavior contract (parity with the macOS app):
#   1. Capture a region (default) or full-screen screenshot to a PNG file.
#   2. Load the clipboard with the PNG image (and, when a multi-format
#      clipboard helper is available, the plain-text path too).
#   3. Detect which AI CLI is running in the focused terminal by walking its
#      child processes, then type the matching format:
#        claude                     -> "[path] "   (bracketed)
#        copilot / aider / opencode -> escaped bare path + " "
#        unknown                    -> "[path] "   (historical default)
#
# Works on X11 (maim/scrot + xclip + xdotool) and Wayland
# (grim/slurp + wl-copy + wtype/ydotool; window focus via sway/hyprland IPC).
#
# Usage: hotshot-capture.sh [--region|--full] [--no-type] [--dir DIR]
set -u

MODE="region"
DO_TYPE=1
SHOT_DIR="${HOTSHOT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}/hotshot}"

while [ $# -gt 0 ]; do
    case "$1" in
        --region) MODE="region" ;;
        --full) MODE="full" ;;
        --no-type) DO_TYPE=0 ;;
        --dir)
            shift
            SHOT_DIR="${1:?--dir requires a directory argument}"
            ;;
        -h | --help)
            awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
            exit 0
            ;;
        *)
            echo "hotshot: unknown option '$1' (try --help)" >&2
            exit 2
            ;;
    esac
    shift
done

die() {
    echo "hotshot: $*" >&2
    command -v notify-send >/dev/null 2>&1 && notify-send "hotshot" "$*"
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- session type -----------------------------------------------------------
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    SESSION="wayland"
elif [ -n "${DISPLAY:-}" ]; then
    SESSION="x11"
else
    die "no graphical session detected (neither WAYLAND_DISPLAY nor DISPLAY is set)"
fi

# --- 0. remember the focused terminal BEFORE the capture overlay ------------
FOCUS_WIN=""
FOCUS_PID=""
if [ "$SESSION" = "x11" ]; then
    if have xdotool; then
        FOCUS_WIN="$(xdotool getactivewindow 2>/dev/null || true)"
        [ -n "$FOCUS_WIN" ] && FOCUS_PID="$(xdotool getwindowpid "$FOCUS_WIN" 2>/dev/null || true)"
    fi
else
    if [ -n "${SWAYSOCK:-}" ] && have swaymsg && have jq; then
        FOCUS_PID="$(swaymsg -t get_tree 2>/dev/null | jq -r '.. | select(.focused? == true) | .pid' | head -n1)"
    elif [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && have hyprctl && have jq; then
        FOCUS_PID="$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid')"
    fi
    [ "$FOCUS_PID" = "null" ] && FOCUS_PID=""
fi

# --- 1. capture --------------------------------------------------------------
mkdir -p "$SHOT_DIR" || die "cannot create screenshot directory $SHOT_DIR"
SHOT_PATH="$SHOT_DIR/hotshot-$(date +%Y%m%d-%H%M%S).png"

if [ "$SESSION" = "x11" ]; then
    if have maim; then
        if [ "$MODE" = "region" ]; then
            maim -s -u "$SHOT_PATH" || die "capture cancelled or maim failed"
        else
            maim -u "$SHOT_PATH" || die "maim failed"
        fi
    elif have scrot; then
        if [ "$MODE" = "region" ]; then
            scrot -s "$SHOT_PATH" || die "capture cancelled or scrot failed"
        else
            scrot "$SHOT_PATH" || die "scrot failed"
        fi
    else
        die "no capture tool found — install 'maim' (recommended) or 'scrot'"
    fi
else
    have grim || die "no capture tool found — install 'grim' (and 'slurp' for region select)"
    if [ "$MODE" = "region" ]; then
        have slurp || die "region capture on Wayland needs 'slurp' — install it or use --full"
        GEOM="$(slurp)" || die "capture cancelled"
        grim -g "$GEOM" "$SHOT_PATH" || die "grim failed"
    else
        grim "$SHOT_PATH" || die "grim failed"
    fi
fi
[ -s "$SHOT_PATH" ] || die "screenshot file was not created"

# --- 2. clipboard ------------------------------------------------------------
# X11/Wayland clipboards have a single owner, and xclip/wl-copy serve one
# target each. If copyq is running we can mirror macOS exactly (one clipboard
# entry carrying image/png + text path); otherwise the image wins and the
# typed injection delivers the path.
if have copyq && copyq size >/dev/null 2>&1; then
    if ! copyq copy image/png - text/plain "$SHOT_PATH" <"$SHOT_PATH" >/dev/null 2>&1; then
        copyq copy image/png - <"$SHOT_PATH" >/dev/null 2>&1 ||
            echo "hotshot: copyq failed to load the clipboard" >&2
    fi
elif [ "$SESSION" = "x11" ]; then
    if have xclip; then
        xclip -selection clipboard -t image/png -i "$SHOT_PATH" ||
            echo "hotshot: xclip failed to load the clipboard" >&2
    else
        echo "hotshot: install 'xclip' to get the screenshot on the clipboard" >&2
    fi
else
    if have wl-copy; then
        wl-copy --type image/png <"$SHOT_PATH" ||
            echo "hotshot: wl-copy failed to load the clipboard" >&2
    else
        echo "hotshot: install 'wl-clipboard' to get the screenshot on the clipboard" >&2
    fi
fi

# --- 3. CLI detection --------------------------------------------------------
# Walk /proc descendants of the focused terminal's PID and classify the AI
# CLI, mirroring the macOS `ps -t <tty>` inspection.
descendants() { # $1 = root pid
    local queue=("$1") pid kids k
    while [ "${#queue[@]}" -gt 0 ]; do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        echo "$pid"
        kids="$(cat "/proc/$pid/task/"*/children 2>/dev/null || true)"
        for k in $kids; do queue+=("$k"); done
    done
}

classify_cli() { # $1 = root pid; echoes "claude" | "plain" | "unknown"
    local saw_plain=0 pid comm cmd base
    while read -r pid; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        base="${comm##*/}"
        case "$base" in
            claude)
                echo claude
                return
                ;;
            copilot | aider | opencode) saw_plain=1 ;;
        esac
        # node/python-wrapped CLIs: look for the script name in the cmdline
        case " $cmd" in
            *[/\ ]claude | *[/\ ]claude\ *)
                echo claude
                return
                ;;
            *[/\ ]copilot | *[/\ ]copilot\ * | *[/\ ]aider | *[/\ ]aider\ * | *[/\ ]opencode | *[/\ ]opencode\ *)
                saw_plain=1
                ;;
        esac
    done < <(descendants "$1")
    [ "$saw_plain" = 1 ] && echo plain || echo unknown
}

CLI="unknown"
[ -n "$FOCUS_PID" ] && CLI="$(classify_cli "$FOCUS_PID")"

# Backslash-escape the same special characters the macOS app escapes.
shell_escape() {
    local s="$1" out="" ch i
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:$i:1}"
        case "$ch" in
            ' ' | $'\t' | '!' | '"' | '#' | '$' | '&' | "'" | '(' | ')' | '*' | ',' | ';' | '<' | '>' | '?' | '[' | ']' | '\' | '^' | '`' | '{' | '}' | '|')
                out+='\'
                ;;
        esac
        out+="$ch"
    done
    printf '%s' "$out"
}

case "$CLI" in
    plain) TEXT="$(shell_escape "$SHOT_PATH") " ;;
    *) TEXT="[$SHOT_PATH] " ;;
esac

# --- 4. typed injection ------------------------------------------------------
if [ "$DO_TYPE" = 1 ]; then
    if [ "$SESSION" = "x11" ]; then
        if have xdotool; then
            [ -n "$FOCUS_WIN" ] && xdotool windowactivate --sync "$FOCUS_WIN" 2>/dev/null
            xdotool type --delay 15 -- "$TEXT" ||
                echo "hotshot: xdotool failed to type into the terminal" >&2
        else
            echo "hotshot: install 'xdotool' for typed injection; path is $SHOT_PATH" >&2
        fi
    else
        # The compositor returns focus to the previously focused window when
        # the slurp overlay closes, so type into whatever is focused now.
        if have wtype; then
            wtype -d 15 -- "$TEXT" ||
                echo "hotshot: wtype failed to type into the terminal" >&2
        elif have ydotool; then
            ydotool type --key-delay 15 -- "$TEXT" ||
                echo "hotshot: ydotool failed (is ydotoold running?)" >&2
        else
            echo "hotshot: install 'wtype' (or 'ydotool') for typed injection; path is $SHOT_PATH" >&2
        fi
    fi
fi

have notify-send && notify-send "hotshot" "Screenshot captured (CLI: $CLI)"
echo "$SHOT_PATH"
