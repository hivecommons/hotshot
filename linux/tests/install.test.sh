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
    env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$BASEPATH" bash "$INSTALLER" "$@"
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
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$PREFIX:$BASEPATH" bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
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
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$BASEPATH" WAYLAND_DISPLAY=wayland-1 \
    bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: Wayland session via WAYLAND_DISPLAY" "Session: Wayland" "$out"
assert_contains "dep report: Wayland lists grim" "grim" "$out"
assert_contains "dep report: Wayland apt hint when grim missing" "sudo apt install grim slurp wl-clipboard wtype" "$out"
assert_contains "dep report: Wayland typed-injection hint" "install 'wtype' (wlroots) or 'ydotool'" "$out"

# Wayland via XDG_SESSION_TYPE only.
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$BASEPATH" XDG_SESSION_TYPE=wayland \
    bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: Wayland session via XDG_SESSION_TYPE" "Session: Wayland" "$out"

# Tools present -> [ok] rows and no apt hint.
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for t in grim slurp wl-copy wtype copyq jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$t"
    chmod +x "$STUBS/$t"
done
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" WAYLAND_DISPLAY=wayland-1 \
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
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$MINBIN" bash "$INSTALLER" --prefix "$PREFIX" 2>&1)"
assert_contains "dep report: copyq optional hint when absent" "[optional] copyq" "$out"
assert_contains "dep report: jq optional hint when absent" "[optional] jq" "$out"

# ==============================================================================
# hotkey help text (no --gnome-hotkey)
# ==============================================================================
out="$(run_installer --prefix "$PREFIX" 2>&1)"
assert_contains "hotkey help: names GNOME option" "--gnome-hotkey" "$out"
assert_contains "hotkey help: sway uses quoted custom prefix" "bindsym Ctrl+Shift+Print exec '$PREFIX/hotshot-capture'" "$out"
assert_contains "hotkey help: hyprland uses quoted custom prefix" "bind = CTRL SHIFT, Print, exec, '$PREFIX/hotshot-capture'" "$out"
assert_contains "hotkey help: sxhkd uses quoted custom prefix" "                '$PREFIX/hotshot-capture'" "$out"
case "$out" in
    *'~/.local/bin'*) check "hotkey help: no hardcoded default prefix" 1 ;;
    *) check "hotkey help: no hardcoded default prefix" 0 ;;
esac

out="$(run_installer 2>&1)"
assert_contains "hotkey help: default prefix expands HOME" "exec '$FAKEHOME/.local/bin/hotshot-capture'" "$out"

out="$(cd "$TMP" && run_installer --prefix relative/bin/ 2>&1)"
assert_contains "hotkey help: relative prefix is absolute without trailing slash" "exec '$TMP/relative/bin/hotshot-capture'" "$out"

# shellcheck disable=SC2088 # literal ~ is the input under test
out="$(run_installer --prefix '~/tools' 2>&1)"
assert_contains "hotkey help: tilde prefix expands HOME" "exec '$FAKEHOME/tools/hotshot-capture'" "$out"

out="$(run_installer --prefix "$TMP/it's/bin" 2>&1)"
assert_contains "hotkey help: apostrophe prefix escapes the quote" "exec '$TMP/it'\\''s/bin/hotshot-capture'" "$out"

# ==============================================================================
# --gnome-hotkey gsettings list surgery
# ==============================================================================
# Stub gsettings: `get` prints $GSETTINGS_EXISTING, `set` logs its arguments.
# Like real gsettings, a `set` value starting with a quote must be exactly one
# GVariant string literal (else exit 1); the PARSED value is what gets logged.
GSLOG="$TMP/gsettings.log"
{
    echo '#!/usr/bin/env bash'
    echo "GSLOG='$GSLOG'"
    cat <<'EOF'
if [ "$1" = "get" ]; then
    printf '%s\n' "${GSETTINGS_EXISTING:-@as []}"
    exit 0
fi
if [ "$1" = "reset-recursively" ]; then
    echo "reset-recursively $2" >>"$GSLOG"
    exit 0
fi
val="$4"
q="${val:0:1}"
if [ "$q" = "'" ] || [ "$q" = '"' ]; then
    parsed=""
    closed=0
    i=1
    while [ "$i" -lt "${#val}" ]; do
        c="${val:i:1}"
        if [ "$closed" = 1 ]; then
            exit 1
        elif [ "$c" = '\' ]; then
            i=$((i + 1))
            c="${val:i:1}"
            case "$c" in
                '\' | '"' | "'") parsed="$parsed$c" ;;
                *) exit 1 ;;
            esac
        elif [ "$c" = "$q" ]; then
            closed=1
        else
            parsed="$parsed$c"
        fi
        i=$((i + 1))
    done
    [ "$closed" = 1 ] || exit 1
    val="$parsed"
fi
echo "$1 $2 $3 $val" >>"$GSLOG"
EOF
} >"$STUBS/gsettings"
chmod +x "$STUBS/gsettings"

KEYPATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/hotshot/"

# The stored command must word-split (POSIX shell rules) to exactly one argv.
assert_hotkey_roundtrip() { # $1 = label, $2 = expected script path
    local label="$1" expected="$2" stored
    stored="$(sed -n 's/^set [^ ]* command //p' "$GSLOG")"
    # shellcheck disable=SC2086,SC2294
    eval "set -- $stored"
    if [ $# -eq 1 ] && [ "$1" = "$expected" ]; then check "$label: stored command round-trips to one argv" 0; else check "$label: stored command round-trips to one argv" 1; fi
}

run_hotkey() { # $1 = existing keybindings value returned by gsettings get
    rm -f "$GSLOG"
    env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" GSETTINGS_EXISTING="$1" \
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
grep -qF "command '$PREFIX/hotshot-capture'" "$GSLOG"
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

# Relative and ~/ prefixes are registered as absolute paths.
WORK="$TMP/work"
mkdir -p "$WORK"
rm -f "$GSLOG"
(cd "$WORK" && env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix rel/bin --gnome-hotkey >/dev/null 2>&1)
if [ -x "$WORK/rel/bin/hotshot-capture" ]; then check "relative prefix: installed under cwd" 0; else check "relative prefix: installed under cwd" 1; fi
grep -qF "command '$WORK/rel/bin/hotshot-capture'" "$GSLOG"
check "relative prefix: hotkey command is absolute" $?

rm -f "$GSLOG"
# shellcheck disable=SC2088 # literal ~ is the input under test
(cd "$WORK" && env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix '~/tools' --gnome-hotkey >/dev/null 2>&1)
if [ -x "$FAKEHOME/tools/hotshot-capture" ]; then check "tilde prefix: installed under HOME" 0; else check "tilde prefix: installed under HOME" 1; fi
grep -qF "command '$FAKEHOME/tools/hotshot-capture'" "$GSLOG"
check "tilde prefix: hotkey command is absolute" $?
if [ -e "$WORK/~" ]; then check "tilde prefix: no literal ~ directory" 1; else check "tilde prefix: no literal ~ directory" 0; fi

# A bare ~ is HOME itself, not a directory named "~".
rm -f "$GSLOG"
# shellcheck disable=SC2088 # literal ~ is the input under test
out="$(cd "$WORK" && env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix '~' --gnome-hotkey 2>&1)"
rc=$?
assert_eq "bare tilde prefix: exit 0" "0" "$rc"
if [ -x "$FAKEHOME/hotshot-capture" ]; then check "bare tilde prefix: installed into HOME" 0; else check "bare tilde prefix: installed into HOME" 1; fi
assert_contains "bare tilde prefix: reports HOME path" "Installed: $FAKEHOME/hotshot-capture" "$out"
grep -qF "command '$FAKEHOME/hotshot-capture'" "$GSLOG"
check "bare tilde prefix: hotkey command is absolute" $?
if [ -e "$WORK/~" ]; then check "bare tilde prefix: no literal ~ directory" 1; else check "bare tilde prefix: no literal ~ directory" 0; fi

# A trailing slash is stripped so the hotkey command has no "//".
rm -f "$GSLOG"
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix "$TMP/slash/" --gnome-hotkey 2>&1)"
rc=$?
assert_eq "trailing-slash prefix: exit 0" "0" "$rc"
assert_contains "trailing-slash prefix: reports path without //" "Installed: $TMP/slash/hotshot-capture" "$out"
case "$out" in
    *"//hotshot-capture"*) check "trailing-slash prefix: no // in reported path" 1 ;;
    *) check "trailing-slash prefix: no // in reported path" 0 ;;
esac
grep -qF "command '$TMP/slash/hotshot-capture'" "$GSLOG"
check "trailing-slash prefix: hotkey command has single slash" $?

# A prefix with a space is quoted so GNOME's shell-style word splitting
# launches the installed script rather than its first path fragment.
rm -f "$GSLOG"
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix "$TMP/my tools/bin" --gnome-hotkey 2>&1)"
rc=$?
assert_eq "space prefix: exit 0" "0" "$rc"
if [ -x "$TMP/my tools/bin/hotshot-capture" ]; then check "space prefix: installed under prefix" 0; else check "space prefix: installed under prefix" 1; fi
grep -qF "command '$TMP/my tools/bin/hotshot-capture'" "$GSLOG"
check "space prefix: stored command is single-quoted" $?
assert_hotkey_roundtrip "space prefix" "$TMP/my tools/bin/hotshot-capture"

# An apostrophe in the prefix survives the quoting ('\'' splice).
rm -f "$GSLOG"
env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix "$TMP/it's/bin" --gnome-hotkey >/dev/null 2>&1
grep -qF "command '$TMP/it'\\''s/bin/hotshot-capture'" "$GSLOG"
check "apostrophe prefix: stored command escapes the quote" $?
assert_hotkey_roundtrip "apostrophe prefix" "$TMP/it's/bin/hotshot-capture"

# Double quote, backslash and $ must survive both layers unchanged.
for odd in 'q"d' 'b\s' 'd$HOME'; do
    rm -f "$GSLOG"
    env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" bash "$INSTALLER" --prefix "$TMP/$odd/bin" --gnome-hotkey >/dev/null 2>&1
    check "odd prefix ($odd): installer exit 0" $?
    assert_hotkey_roundtrip "odd prefix ($odd)" "$TMP/$odd/bin/hotshot-capture"
done

# gsettings missing -> exit 1 with a clear message.
out="$(env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$MINBIN" \
    bash "$INSTALLER" --prefix "$PREFIX" --gnome-hotkey 2>&1)"
rc=$?
assert_eq "gnome hotkey without gsettings: exit 1" "1" "$rc"
assert_contains "gnome hotkey without gsettings: message" "gsettings not found" "$out"

# ==============================================================================
# --uninstall
# ==============================================================================
PREFIX_UNINSTALL="$TMP/uninstall_test"
out="$(run_installer --prefix "$PREFIX_UNINSTALL" 2>&1)"
if [ -x "$PREFIX_UNINSTALL/hotshot-capture" ]; then check "uninstall (setup): installed" 0; else check "uninstall (setup): installed" 1; fi

run_uninstall() { # $1 = existing keybindings value returned by gsettings get
    rm -f "$GSLOG"
    env -i BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" HOME="$FAKEHOME" PATH="$STUBS:$BASEPATH" GSETTINGS_EXISTING="$1" \
        bash "$INSTALLER" --prefix "$PREFIX_UNINSTALL" --uninstall
}

CUSTOM0="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
CUSTOM1="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"

# Installed, hotkey never registered -> file removed, gsettings untouched.
out="$(run_uninstall "['$CUSTOM0']" 2>&1)"
rc=$?
assert_eq "uninstall: exit 0" "0" "$rc"
assert_contains "uninstall: removed message" "Removed: $PREFIX_UNINSTALL/hotshot-capture" "$out"
assert_contains "uninstall: uninstalled message" "hotshot uninstalled." "$out"
if [ ! -e "$PREFIX_UNINSTALL/hotshot-capture" ]; then check "uninstall: file removed" 0; else check "uninstall: file removed" 1; fi
if [ ! -e "$GSLOG" ]; then check "uninstall (not registered): gsettings not written" 0; else check "uninstall (not registered): gsettings not written" 1; fi
case "$out" in
    *"GNOME hotkey removed"*) check "uninstall (not registered): no hotkey message" 1 ;;
    *) check "uninstall (not registered): no hotkey message" 0 ;;
esac

# Nothing installed -> still exit 0, says so.
out="$(run_uninstall "@as []" 2>&1)"
rc=$?
assert_eq "uninstall (not installed): exit 0" "0" "$rc"
assert_contains "uninstall (not installed): message" "Not installed: $PREFIX_UNINSTALL/hotshot-capture" "$out"

# Hotkey is the only keybinding -> list emptied with the typed literal.
out="$(run_uninstall "['$KEYPATH']" 2>&1)"
rc=$?
assert_eq "uninstall gnome (singleton): exit 0" "0" "$rc"
assert_contains "uninstall gnome (singleton): hotkey removed message" "GNOME hotkey removed" "$out"
grep -qF "set org.gnome.settings-daemon.plugins.media-keys custom-keybindings @as []" "$GSLOG"
check "uninstall gnome (singleton): writes empty typed list" $?
grep -qF "reset-recursively org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYPATH" "$GSLOG"
check "uninstall gnome (singleton): resets the keybinding keys" $?

# Hotkey in the middle of other keybindings -> only our entry is dropped.
out="$(run_uninstall "['$CUSTOM0', '$KEYPATH', '$CUSTOM1']" 2>&1)"
rc=$?
assert_eq "uninstall gnome (middle): exit 0" "0" "$rc"
grep -qF "set org.gnome.settings-daemon.plugins.media-keys custom-keybindings ['$CUSTOM0', '$CUSTOM1']" "$GSLOG"
check "uninstall gnome (middle): keeps the other keybindings" $?

# Hotkey first in the list.
out="$(run_uninstall "['$KEYPATH', '$CUSTOM0']" 2>&1)"
rc=$?
assert_eq "uninstall gnome (first): exit 0" "0" "$rc"
grep -qF "set org.gnome.settings-daemon.plugins.media-keys custom-keybindings ['$CUSTOM0']" "$GSLOG"
check "uninstall gnome (first): keeps the other keybinding" $?

# Hotkey last in the list.
out="$(run_uninstall "['$CUSTOM0', '$KEYPATH']" 2>&1)"
rc=$?
assert_eq "uninstall gnome (last): exit 0" "0" "$rc"
grep -qF "set org.gnome.settings-daemon.plugins.media-keys custom-keybindings ['$CUSTOM0']" "$GSLOG"
check "uninstall gnome (last): keeps the other keybinding" $?

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
