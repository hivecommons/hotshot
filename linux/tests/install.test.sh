#!/usr/bin/env bash
# Test suite for linux/install.sh.
#
# Hermetic: no display server and no real gsettings are needed. Tests run the
# real installer against a temp HOME/prefix with stubbed external tools, and
# exercise both the Wayland and X11 dependency reports plus every branch of
# the GNOME hotkey gsettings list surgery.
#
# Usage: bash linux/tests/install.test.sh
set -u

INSTALLER="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
PASS=0
FAIL=0

check() { # $1 = description, $2 = condition result ($?)
    if [ "$2" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "ok - $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL - $1"
    fi
}

assert_eq() { # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        echo "ok - $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL - $1"
        echo "    expected: $(printf '%q' "$2")"
        echo "    actual:   $(printf '%q' "$3")"
    fi
}

assert_contains() { # $1 = description, $2 = needle, $3 = haystack
    case "$3" in
        *"$2"*) check "$1" 0 ;;
        *)
            check "$1" 1
            echo "    expected to contain: $(printf '%q' "$2")"
            ;;
    esac
}

TMP="$(mktemp -d /tmp/hotshot-install-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME"

# Minimal PATH pieces the installer itself needs (mkdir, install, awk, ...).
BASEPATH="/usr/bin:/bin"

run_installer() { # all args passed through; env can be prepended by callers
    env -i HOME="$FAKEHOME" PATH="$BASEPATH" bash "$INSTALLER" "$@"
}

# ==============================================================================
# argument parsing
# ==============================================================================
out="$(run_installer --bogus 2>&1)"
rc=$?
assert_eq "unknown option: exit code 2" "2" "$rc"
assert_contains "unknown option: message names the flag" "unknown option '--bogus'" "$out"

out="$(run_installer --help 2>&1)"
rc=$?
assert_eq "--help: exit code 0" "0" "$rc"
assert_contains "--help: prints usage line" "Usage: ./install.sh" "$out"

run_installer --prefix 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then check "--prefix without argument: non-zero exit" 0; else check "--prefix without argument: non-zero exit" 1; fi

# ==============================================================================
# install to prefix
# ==============================================================================
PREFIX="$TMP/custom bin"
out="$(run_installer --prefix "$PREFIX" 2>&1)"
rc=$?
assert_eq "install: exit 0" "0" "$rc"
if [ -x "$PREFIX/hotshot-capture" ]; then check "install: hotshot-capture installed executable at --prefix" 0; else check "install: hotshot-capture installed executable at --prefix" 1; fi
cmp -s "$PREFIX/hotshot-capture" "$(dirname "$INSTALLER")/hotshot-capture.sh"
check "install: installed file matches source script" $?
assert_contains "install: reports the destination" "Installed: $PREFIX/hotshot-capture" "$out"
assert_contains "install: warns when prefix not on PATH" "is not on your PATH" "$out"

# Prefix already on PATH -> no warning.
out="$(env -i HOME="$FAKEHOME" PATH="$PREFIX:$BASEPATH" bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
case "$out" in
    *"is not on your PATH"*) check "install: no PATH warning when prefix is on PATH" 1 ;;
    *) check "install: no PATH warning when prefix is on PATH" 0 ;;
esac

# Default prefix is ~/.local/bin.
out="$(run_installer 2>&1)"
rc=$?
assert_eq "install default prefix: exit 0" "0" "$rc"
if [ -x "$FAKEHOME/.local/bin/hotshot-capture" ]; then check "install default prefix: installs to ~/.local/bin" 0; else check "install default prefix: installs to ~/.local/bin" 1; fi

# ==============================================================================
# dependency report — session branches
# ==============================================================================
# X11 (no WAYLAND_DISPLAY): reports maim/xclip/xdotool.
out="$(run_installer --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: X11 session detected without WAYLAND_DISPLAY" "Session: X11" "$out"
assert_contains "dep report: X11 lists maim" "maim" "$out"
assert_contains "dep report: X11 apt hint when no capture tool" "sudo apt install maim xclip xdotool" "$out"

# Wayland via WAYLAND_DISPLAY: reports grim/slurp/wl-copy/wtype.
out="$(env -i HOME="$FAKEHOME" PATH="$BASEPATH" WAYLAND_DISPLAY=wayland-1 \
    bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: Wayland session via WAYLAND_DISPLAY" "Session: Wayland" "$out"
assert_contains "dep report: Wayland lists grim" "grim" "$out"
assert_contains "dep report: Wayland apt hint when grim missing" "sudo apt install grim slurp wl-clipboard wtype" "$out"
assert_contains "dep report: Wayland typed-injection hint" "install 'wtype' (wlroots) or 'ydotool'" "$out"

# Wayland via XDG_SESSION_TYPE only.
out="$(env -i HOME="$FAKEHOME" PATH="$BASEPATH" XDG_SESSION_TYPE=wayland \
    bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: Wayland session via XDG_SESSION_TYPE" "Session: Wayland" "$out"

# Tools present -> [ok] rows and no apt hint.
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for t in grim slurp wl-copy wtype copyq jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$t"
    chmod +x "$STUBS/$t"
done
out="$(env -i HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" WAYLAND_DISPLAY=wayland-1 \
    bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: grim present marked ok" "[ok]      grim" "$out"
assert_contains "dep report: copyq present marked ok" "[ok]      copyq" "$out"
case "$out" in
    *"sudo apt install grim"*) check "dep report: no apt hint when grim present" 1 ;;
    *) check "dep report: no apt hint when grim present" 0 ;;
esac
case "$out" in
    *"[optional] jq"*) check "dep report: no jq hint when jq present" 1 ;;
    *) check "dep report: no jq hint when jq present" 0 ;;
esac

# Tools absent -> optional hints shown. The host may have jq/copyq installed,
# so run against a minimal PATH holding only the tools the installer needs.
MINBIN="$TMP/minbin"
mkdir -p "$MINBIN"
for t in bash dirname mkdir install awk cat cmp grep; do
    ln -sf "$(command -v "$t")" "$MINBIN/$t"
done
out="$(env -i HOME="$FAKEHOME" PATH="$MINBIN" bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: copyq optional hint when absent" "[optional] copyq" "$out"
assert_contains "dep report: jq optional hint when absent" "[optional] jq" "$out"

# ==============================================================================
# hotkey help text (no --gnome-hotkey)
# ==============================================================================
out="$(run_installer --prefix "$PREFIX" 2>&1)"
assert_contains "hotkey help: names GNOME option" "--gnome-hotkey" "$out"
assert_contains "hotkey help: sway binding hint" "bindsym Ctrl+Shift+Print" "$out"

# ==============================================================================
# --gnome-hotkey gsettings list surgery
# ==============================================================================
# Stub gsettings: `get` prints $GSETTINGS_EXISTING, `set` logs its arguments.
GSLOG="$TMP/gsettings.log"
cat >"$STUBS/gsettings" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "get" ]; then
    printf '%s\n' "\${GSETTINGS_EXISTING:-@as []}"
else
    echo "\$@" >>"$GSLOG"
fi
EOF
chmod +x "$STUBS/gsettings"

KEYPATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hotshot/"

run_hotkey() { # $1 = existing keybindings value returned by gsettings get
    rm -f "$GSLOG"
    env -i HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" GSETTINGS_EXISTING="$1" \
        bash "$INSTALLER" --prefix "$PREFIX" --gnome-hotkey
}

# Empty list -> a fresh singleton list is written.
out="$(run_hotkey "@as []" 2>&1)"
rc=$?
assert_eq "gnome hotkey (empty list): exit 0" "0" "$rc"
grep -qF "custom-keybindings ['$KEYPATH']" "$GSLOG"
check "gnome hotkey (empty list): writes singleton keybinding list" $?
grep -qF "name hotshot" "$GSLOG"
check "gnome hotkey: sets binding name" $?
grep -qF "command $PREFIX/hotshot-capture" "$GSLOG"
check "gnome hotkey: command points at installed script" $?
grep -qF "binding <Ctrl><Shift>Print" "$GSLOG"
check "gnome hotkey: binding is Ctrl+Shift+Print" $?
assert_contains "gnome hotkey: confirms registration" "GNOME hotkey registered" "$out"

# Existing entries -> hotshot path appended, existing entries preserved.
run_hotkey "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']" >/dev/null 2>&1
rc=$?
assert_eq "gnome hotkey (append): exit 0" "0" "$rc"
grep -qF "custom-keybindings ['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', '$KEYPATH']" "$GSLOG"
check "gnome hotkey (append): appends to existing list, keeping custom0" $?

# Already registered -> list is NOT rewritten, per-key settings still applied.
run_hotkey "['$KEYPATH']" >/dev/null 2>&1
rc=$?
assert_eq "gnome hotkey (already registered): exit 0" "0" "$rc"
if grep -q "custom-keybindings \[" "$GSLOG"; then check "gnome hotkey (already registered): keybinding list untouched" 1; else check "gnome hotkey (already registered): keybinding list untouched" 0; fi
grep -qF "binding <Ctrl><Shift>Print" "$GSLOG"
check "gnome hotkey (already registered): binding still refreshed" $?

# gsettings missing -> exit 1 with a clear message.
out="$(env -i HOME="$FAKEHOME" PATH="$MINBIN" \
    bash "$INSTALLER" --prefix "$PREFIX" --gnome-hotkey 2>&1)"
rc=$?
assert_eq "gnome hotkey without gsettings: exit 1" "1" "$rc"
assert_contains "gnome hotkey without gsettings: message" "gsettings not found" "$out"

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
