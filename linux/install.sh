#!/usr/bin/env bash
# hotshot Linux installer — installs hotshot-capture to ~/.local/bin, checks
# dependencies, and (optionally) registers a GNOME custom hotkey.
#
# Usage: ./install.sh [--gnome-hotkey] [--prefix DIR]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local/bin"
GNOME_HOTKEY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --gnome-hotkey) GNOME_HOTKEY=1 ;;
        --prefix)
            shift
            PREFIX="${1:?--prefix requires a directory}"
            ;;
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

have() { command -v "$1" >/dev/null 2>&1; }

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
        gsettings set "$BASE.custom-keybinding:$KEYPATH" name 'hotshot'
        gsettings set "$BASE.custom-keybinding:$KEYPATH" command "$PREFIX/hotshot-capture"
        gsettings set "$BASE.custom-keybinding:$KEYPATH" binding '<Ctrl><Shift>Print'
        echo "GNOME hotkey registered: Ctrl+Shift+PrintScreen -> hotshot-capture"
    else
        echo "gsettings not found — cannot register a GNOME hotkey on this system." >&2
        exit 1
    fi
else
    cat <<'EOF'
Bind a global hotkey to 'hotshot-capture' with your desktop environment:

  GNOME:    rerun with --gnome-hotkey, or Settings > Keyboard > Custom Shortcuts
  KDE:      System Settings > Shortcuts > Custom Shortcuts > New > Command/URL
  sway:     bindsym Ctrl+Shift+Print exec ~/.local/bin/hotshot-capture
  hyprland: bind = CTRL SHIFT, Print, exec, ~/.local/bin/hotshot-capture
  sxhkd:    ctrl + shift + Print
                ~/.local/bin/hotshot-capture

Suggested binding: Ctrl+Shift+PrintScreen (region capture).
EOF
fi
