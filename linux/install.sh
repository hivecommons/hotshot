#!/usr/bin/env bash
# hotshot Linux installer — installs hotshot-capture to ~/.local/bin, checks
# dependencies, and (optionally) registers a GNOME custom hotkey.
#
# Usage: ./install.sh [--gnome-hotkey] [--prefix DIR] [--uninstall]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local/bin"
GNOME_HOTKEY=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --gnome-hotkey) GNOME_HOTKEY=1 ;;
        --prefix)
            shift
            PREFIX="${1:?--prefix requires a directory}"
            ;;
        --uninstall) UNINSTALL=1 ;;
        -h | --help)
            awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
            exit 0
            ;;
        *)
            echo "install.sh: unknown option '$1'" >&2
            exit 2
            ;;
    esac
    shift
done

# Anchor the prefix to an absolute path (same rules as hotshot-capture's
# normalize_shot_dir) so the hotkey command and PATH check are launchable.
case "$PREFIX" in
    "~") PREFIX="$HOME" ;;
    \~/*) PREFIX="$HOME/${PREFIX#\~/}" ;;
    /*) : ;;
    *) PREFIX="$PWD/$PREFIX" ;;
esac
PREFIX="${PREFIX%/}"
[ -n "$PREFIX" ] || PREFIX="/"

have() { command -v "$1" >/dev/null 2>&1; }

# --- uninstall (parity with windows/install.ps1 -Uninstall) -------------------
if [ "$UNINSTALL" = 1 ]; then
    if [ -e "$PREFIX/hotshot-capture" ]; then
        rm -f "$PREFIX/hotshot-capture"
        echo "Removed: $PREFIX/hotshot-capture"
    else
        echo "Not installed: $PREFIX/hotshot-capture"
    fi

    if have gsettings; then
        BASE="org.gnome.settings-daemon.plugins.media-keys"
        KEYPATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hotshot/"
        EXISTING="$(gsettings get "$BASE" custom-keybindings 2>/dev/null || echo "@as []")"
        case "$EXISTING" in
            *"'$KEYPATH'"*)
                # Drop our entry wherever it sits in the GVariant list: as a
                # later element (", 'path'"), the first of several ("'path', ")
                # or the only one; an emptied list must be typed ("@as []").
                ENTRY="'$KEYPATH'"
                NEWLIST="${EXISTING//, "$ENTRY"/}"
                NEWLIST="${NEWLIST//"$ENTRY", /}"
                NEWLIST="${NEWLIST//"$ENTRY"/}"
                [ "$NEWLIST" = "[]" ] && NEWLIST="@as []"
                gsettings set "$BASE" custom-keybindings "$NEWLIST"
                gsettings reset-recursively "$BASE.custom-keybinding:$KEYPATH" 2>/dev/null || true
                echo "GNOME hotkey removed"
                ;;
        esac
    fi
    echo "hotshot uninstalled."
    exit 0
fi

mkdir -p "$PREFIX"
install -m 755 "$SCRIPT_DIR/hotshot-capture.sh" "$PREFIX/hotshot-capture"
echo "Installed: $PREFIX/hotshot-capture"

case ":$PATH:" in
    *":$PREFIX:"*) : ;;
    *) echo "NOTE: $PREFIX is not on your PATH — add it to your shell profile." ;;
esac

# --- dependency report --------------------------------------------------------
echo
echo "Dependency check:"
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    echo "  Session: Wayland"
    for t in grim slurp wl-copy wtype; do
        if have "$t"; then echo "  [ok]      $t"; else echo "  [MISSING] $t"; fi
    done
    have wtype || have ydotool || echo "  -> install 'wtype' (wlroots) or 'ydotool' for typed injection"
    have grim || echo "  -> e.g.: sudo apt install grim slurp wl-clipboard wtype   (Debian/Ubuntu)"
else
    echo "  Session: X11"
    for t in maim xclip xdotool; do
        if have "$t"; then echo "  [ok]      $t"; else echo "  [MISSING] $t"; fi
    done
    have maim || have scrot || echo "  -> e.g.: sudo apt install maim xclip xdotool   (Debian/Ubuntu)"
fi
have copyq && echo "  [ok]      copyq (multi-format clipboard: image + text path, like macOS)" ||
    echo "  [optional] copyq — enables macOS-style multi-format clipboard (image + text path)"
have jq || echo "  [optional] jq — needed for CLI detection on sway/hyprland (Wayland)"

# --- hotkey -------------------------------------------------------------------
echo
if [ "$GNOME_HOTKEY" = 1 ]; then
    if have gsettings; then
        BASE="org.gnome.settings-daemon.plugins.media-keys"
        KEYPATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hotshot/"
        EXISTING="$(gsettings get "$BASE" custom-keybindings 2>/dev/null || echo "@as []")"
        case "$EXISTING" in
            *"$KEYPATH"*) : ;;
            *"[]"*) gsettings set "$BASE" custom-keybindings "['$KEYPATH']" ;;
            *) gsettings set "$BASE" custom-keybindings "${EXISTING%]*}, '$KEYPATH']" ;;
        esac
        # Two quoting layers: GNOME splits the command with shell word rules
        # (POSIX single quotes), and gsettings parses its argument as a
        # GVariant literal, so the shell-quoted word goes inside "...".
        CMD="$PREFIX/hotshot-capture"
        QUOTED="'${CMD//\'/\'\\\'\'}'"
        QUOTED="${QUOTED//\\/\\\\}"
        QUOTED="${QUOTED//\"/\\\"}"
        gsettings set "$BASE.custom-keybinding:$KEYPATH" name 'hotshot'
        gsettings set "$BASE.custom-keybinding:$KEYPATH" command "\"$QUOTED\""
        gsettings set "$BASE.custom-keybinding:$KEYPATH" binding '<Ctrl><Shift>Print'
        echo "GNOME hotkey registered: Ctrl+Shift+PrintScreen -> hotshot-capture"
    else
        echo "gsettings not found — cannot register a GNOME hotkey on this system." >&2
        exit 1
    fi
else
    # Keep the installed path a single shell word, including spaces/apostrophes.
    CMD="$PREFIX/hotshot-capture"
    CMD="'${CMD//\'/\'\\\'\'}'"
    cat <<EOF
Bind a global hotkey to 'hotshot-capture' with your desktop environment:

  GNOME:    rerun with --gnome-hotkey, or Settings > Keyboard > Custom Shortcuts
  KDE:      System Settings > Shortcuts > Custom Shortcuts > New > Command/URL
  sway:     bindsym Ctrl+Shift+Print exec $CMD
  hyprland: bind = CTRL SHIFT, Print, exec, $CMD
  sxhkd:    ctrl + shift + Print
                $CMD

Suggested binding: Ctrl+Shift+PrintScreen (region capture).
EOF
fi
