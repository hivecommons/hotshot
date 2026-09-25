#!/usr/bin/env bash
# Test suite for linux/hotshot-capture.sh.
#
# Hermetic: no display server, no capture tools, and no clipboard are needed.
# The end-to-end tests run the real script against a fake X11 session whose
# external tools (maim, xclip, xdotool) are PATH stubs, and classify_cli is
# exercised against a real /proc process tree spawned by the test.
#
# Usage: bash linux/tests/hotshot-capture.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hotshot-capture.sh"
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

TMP="$(mktemp -d /tmp/hotshot-test.XXXXXX)"
CHILD_PIDS=()
cleanup() {
    local pid
    for pid in "${CHILD_PIDS[@]:-}"; do
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- extract pure functions from the script ----------------------------------
# The script dies early without a graphical session, so unit tests pull the
# function definitions out verbatim instead of sourcing the whole file.
extract_fn() { # $1 = function name
    sed -n "/^$1() {/,/^}$/p" "$SCRIPT"
}
eval "$(extract_fn shell_escape)"
eval "$(extract_fn descendants)"
eval "$(extract_fn classify_cli)"

# ==============================================================================
# shell_escape
# ==============================================================================
assert_eq "shell_escape: plain path unchanged" \
    "/home/u/Pictures/hotshot-1.png" \
    "$(shell_escape '/home/u/Pictures/hotshot-1.png')"

assert_eq "shell_escape: space" 'a\ b' "$(shell_escape 'a b')"
assert_eq "shell_escape: tab" "a\\$(printf '\t')b" "$(shell_escape "a$(printf '\t')b")"
assert_eq "shell_escape: double quote" 'a\"b' "$(shell_escape 'a"b')"
assert_eq "shell_escape: single quote" "a\\'b" "$(shell_escape "a'b")"
assert_eq "shell_escape: backslash" 'a\\b' "$(shell_escape 'a\b')"
assert_eq "shell_escape: dollar and backtick" 'a\$b\`c' "$(shell_escape 'a$b`c')"
assert_eq "shell_escape: full special set" \
    '\!\"\#\$\&\(\)\*\,\;\<\>\?\[\]\^\{\}\|' \
    "$(shell_escape '!"#$&()*,;<>?[]^{}|')"
assert_eq "shell_escape: empty string" "" "$(shell_escape '')"
# Characters the macOS app does NOT escape must pass through untouched.
assert_eq "shell_escape: safe chars untouched" 'a-b_c.d~e/f:g@h=i+j%k' \
    "$(shell_escape 'a-b_c.d~e/f:g@h=i+j%k')"

# ==============================================================================
# descendants / classify_cli against a real /proc tree
# ==============================================================================
# Build fake CLI binaries: copies of sleep whose /proc/<pid>/comm will read
# "claude", "copilot", etc.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
SLEEP_BIN="$(command -v sleep)"
for name in claude copilot aider opencode; do
    cp "$SLEEP_BIN" "$FAKEBIN/$name"
done

spawn_tree() { # $1 = CLI binary to run as a grandchild; echoes root pid
    setsid bash -c "bash -c '\"$FAKEBIN/$1\" 300' & wait" >/dev/null 2>&1 &
    local pid=$!
    CHILD_PIDS+=("$pid")
    sleep 0.3 # let the grandchild exec
    echo "$pid"
}

root="$(spawn_tree claude)"
assert_eq "classify_cli: claude grandchild -> claude" "claude" "$(classify_cli "$root")"

root="$(spawn_tree copilot)"
assert_eq "classify_cli: copilot grandchild -> plain" "plain" "$(classify_cli "$root")"

root="$(spawn_tree aider)"
assert_eq "classify_cli: aider grandchild -> plain" "plain" "$(classify_cli "$root")"

root="$(spawn_tree opencode)"
assert_eq "classify_cli: opencode grandchild -> plain" "plain" "$(classify_cli "$root")"

setsid sleep 300 >/dev/null 2>&1 &
plain_root=$!
CHILD_PIDS+=("$plain_root")
assert_eq "classify_cli: no AI CLI in tree -> unknown" "unknown" "$(classify_cli "$plain_root")"

# node/python-wrapped CLI: comm is the interpreter, cmdline names the script.
# Emulate via a bash process whose cmdline contains .../wrapbin/claude.
mkdir -p "$TMP/wrapbin"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/wrapbin/claude"
chmod +x "$TMP/wrapbin/claude"
setsid bash "$TMP/wrapbin/claude" >/dev/null 2>&1 &
wrapped=$!
CHILD_PIDS+=("$wrapped")
sleep 0.2
assert_eq "classify_cli: interpreter-wrapped claude (cmdline match) -> claude" \
    "claude" "$(classify_cli "$wrapped")"

got="$(descendants "$root" | head -n1)"
assert_eq "descendants: first entry is the root pid" "$root" "$got"
descendants "$root" | grep -qx "$root"
check "descendants: includes root" $?
[ "$(descendants "$root" | wc -l)" -ge 2 ]
check "descendants: walks children (>=2 pids)" $?

# ==============================================================================
# argument parsing (runs before session detection — no display needed)
# ==============================================================================
out="$(bash "$SCRIPT" --bogus 2>&1)"
rc=$?
assert_eq "unknown option: exit code 2" "2" "$rc"
case "$out" in *"unknown option '--bogus'"*) check "unknown option: message names the flag" 0 ;; *) check "unknown option: message names the flag" 1 ;; esac

out="$(bash "$SCRIPT" --help 2>&1)"
rc=$?
assert_eq "--help: exit code 0" "0" "$rc"
case "$out" in *"Usage: hotshot-capture.sh"*) check "--help: prints usage line" 0 ;; *) check "--help: prints usage line" 1 ;; esac

bash "$SCRIPT" --dir 2>/dev/null
rc=$?
[ "$rc" -ne 0 ]
check "--dir without argument: non-zero exit" $?

# no session at all -> die with the expected message
out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u XDG_SESSION_TYPE PATH="$PATH" bash "$SCRIPT" 2>&1)"
rc=$?
assert_eq "no graphical session: exit 1" "1" "$rc"
case "$out" in *"no graphical session detected"*) check "no graphical session: message" 0 ;; *) check "no graphical session: message" 1 ;; esac

# ==============================================================================
# end-to-end on a fake X11 session (stubbed maim/xclip/xdotool)
# ==============================================================================
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
TYPELOG="$TMP/typed.log"
CLIPLOG="$TMP/clip.log"

cat >"$STUBS/maim" <<'EOF'
#!/usr/bin/env bash
# last argument is the output path
for out in "$@"; do :; done
printf 'PNG' >"$out"
EOF

cat >"$STUBS/xclip" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$CLIPLOG"
EOF

cat >"$STUBS/xdotool" <<EOF
#!/usr/bin/env bash
case "\$1" in
    getactivewindow) echo 4242 ;;
    getwindowpid) echo "\${HOTSHOT_TEST_FOCUS_PID:?}" ;;
    windowactivate) : ;;
    type) shift; while [ "\$1" != "--" ]; do shift; done; shift; printf '%s' "\$*" >>"$TYPELOG" ;;
esac
EOF
chmod +x "$STUBS"/*

run_e2e() { # $1 = focus pid; remaining args passed to the script
    local focus="$1"
    shift
    rm -f "$TYPELOG" "$CLIPLOG"
    env -i HOME="$HOME" DISPLAY=:99 PATH="$STUBS:/usr/bin:/bin" \
        HOTSHOT_DIR="$TMP/shots" HOTSHOT_TEST_FOCUS_PID="$focus" \
        bash "$SCRIPT" "$@"
}

# Focused terminal runs claude -> bracketed path typed.
root="$(spawn_tree claude)"
shot="$(run_e2e "$root" --full 2>"$TMP/e2e.err")"
rc=$?
assert_eq "e2e claude: exit 0" "0" "$rc"
[ -s "$shot" ]
check "e2e claude: screenshot file created and echoed" $?
assert_eq "e2e claude: typed bracketed path" "[$shot] " "$(cat "$TYPELOG")"
grep -q -- "-t image/png -i $shot" "$CLIPLOG"
check "e2e claude: clipboard loaded via xclip image/png" $?

# Focused terminal runs copilot -> escaped bare path typed.
root="$(spawn_tree copilot)"
mkdir -p "$TMP/spaced dir"
shot="$(run_e2e "$root" --full --dir "$TMP/spaced dir")"
rc=$?
assert_eq "e2e copilot: exit 0" "0" "$rc"
esc="$(shell_escape "$shot")"
assert_eq "e2e copilot: typed escaped bare path (space escaped)" "$esc " "$(cat "$TYPELOG")"
case "$(cat "$TYPELOG")" in *'\ '*) check "e2e copilot: space in dir actually escaped" 0 ;; *) check "e2e copilot: space in dir actually escaped" 1 ;; esac

# Unknown CLI -> bracketed default.
shot="$(run_e2e "$plain_root" --full)"
assert_eq "e2e unknown CLI: typed bracketed default" "[$shot] " "$(cat "$TYPELOG")"

# --no-type suppresses injection but still captures + clipboard.
root="$(spawn_tree claude)"
shot="$(run_e2e "$root" --full --no-type)"
rc=$?
assert_eq "e2e --no-type: exit 0" "0" "$rc"
[ ! -e "$TYPELOG" ]
check "e2e --no-type: nothing typed" $?
[ -s "$shot" ]
check "e2e --no-type: screenshot still created" $?

# Capture failure (maim dies) -> script dies, no typing.
cat >"$STUBS/failmaim" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUBS/failmaim"
mv "$STUBS/maim" "$STUBS/maim.ok" && mv "$STUBS/failmaim" "$STUBS/maim"
run_e2e "$plain_root" --full >/dev/null 2>&1
rc=$?
assert_eq "e2e capture failure: exit 1" "1" "$rc"
[ ! -e "$TYPELOG" ]
check "e2e capture failure: nothing typed" $?
mv "$STUBS/maim.ok" "$STUBS/maim"

# X11 fallback: no maim on PATH -> scrot captures instead.
SCROTSTUBS="$TMP/scrotstubs"
mkdir -p "$SCROTSTUBS"
cp "$STUBS/xclip" "$STUBS/xdotool" "$SCROTSTUBS/"
cat >"$SCROTSTUBS/scrot" <<'EOF'
#!/usr/bin/env bash
for out in "$@"; do :; done
printf 'PNG' >"$out"
EOF
chmod +x "$SCROTSTUBS"/*
root="$(spawn_tree claude)"
rm -f "$TYPELOG" "$CLIPLOG"
shot="$(env -i HOME="$HOME" DISPLAY=:99 PATH="$SCROTSTUBS:/usr/bin:/bin" \
    HOTSHOT_DIR="$TMP/shots" HOTSHOT_TEST_FOCUS_PID="$root" \
    bash "$SCRIPT" --full)"
rc=$?
assert_eq "e2e scrot fallback: exit 0" "0" "$rc"
[ -s "$shot" ]
check "e2e scrot fallback: screenshot created via scrot" $?
assert_eq "e2e scrot fallback: typed bracketed path" "[$shot] " "$(cat "$TYPELOG")"

# ==============================================================================
# end-to-end on a fake Wayland session (stubbed grim/slurp/wl-copy/wtype,
# focus detection via a stubbed sway IPC + real jq)
# ==============================================================================
WSTUBS="$TMP/wstubs"
mkdir -p "$WSTUBS"
GRIMLOG="$TMP/grim.log"

cat >"$WSTUBS/grim" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$GRIMLOG"
for out in "\$@"; do :; done
printf 'PNG' >"\$out"
EOF

cat >"$WSTUBS/slurp" <<'EOF'
#!/usr/bin/env bash
echo "10,20 300x200"
EOF

cat >"$WSTUBS/wl-copy" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo "\$@" >>"$CLIPLOG"
EOF

cat >"$WSTUBS/wtype" <<EOF
#!/usr/bin/env bash
while [ "\$1" != "--" ]; do shift; done
shift
printf '%s' "\$*" >>"$TYPELOG"
EOF

# sway IPC: report the test-chosen pid as the focused window.
cat >"$WSTUBS/swaymsg" <<'EOF'
#!/usr/bin/env bash
printf '{"nodes":[{"focused":true,"pid":%s}]}\n' "${HOTSHOT_TEST_FOCUS_PID:?}"
EOF
chmod +x "$WSTUBS"/*

run_e2e_wayland() { # $1 = focus pid; remaining args passed to the script
    local focus="$1"
    shift
    rm -f "$TYPELOG" "$CLIPLOG" "$GRIMLOG"
    env -i HOME="$HOME" WAYLAND_DISPLAY=wayland-1 SWAYSOCK="$TMP/sway.sock" \
        PATH="$WSTUBS:/usr/bin:/bin" HOTSHOT_DIR="$TMP/wshots" \
        HOTSHOT_TEST_FOCUS_PID="$focus" \
        bash "$SCRIPT" "$@"
}

# Focused sway window runs claude -> bracketed path typed via wtype.
root="$(spawn_tree claude)"
shot="$(run_e2e_wayland "$root" --full 2>"$TMP/we2e.err")"
rc=$?
assert_eq "e2e wayland claude: exit 0" "0" "$rc"
[ -s "$shot" ]
check "e2e wayland claude: screenshot file created and echoed" $?
assert_eq "e2e wayland claude: typed bracketed path" "[$shot] " "$(cat "$TYPELOG")"
grep -q -- "--type image/png" "$CLIPLOG"
check "e2e wayland claude: clipboard loaded via wl-copy image/png" $?

# Focused sway window runs copilot -> escaped bare path typed.
root="$(spawn_tree copilot)"
mkdir -p "$TMP/wayland spaced"
shot="$(run_e2e_wayland "$root" --full --dir "$TMP/wayland spaced")"
rc=$?
assert_eq "e2e wayland copilot: exit 0" "0" "$rc"
esc="$(shell_escape "$shot")"
assert_eq "e2e wayland copilot: typed escaped bare path" "$esc " "$(cat "$TYPELOG")"

# Region capture -> slurp geometry is passed to grim -g.
root="$(spawn_tree claude)"
shot="$(run_e2e_wayland "$root" --region)"
rc=$?
assert_eq "e2e wayland region: exit 0" "0" "$rc"
grep -q -- "-g 10,20 300x200" "$GRIMLOG"
check "e2e wayland region: slurp geometry forwarded to grim -g" $?

# Cancelled slurp (user hit Escape) -> die, nothing typed or captured.
cat >"$WSTUBS/slurp.ok" <<'EOF'
#!/usr/bin/env bash
echo "10,20 300x200"
EOF
chmod +x "$WSTUBS/slurp.ok"
cat >"$WSTUBS/slurp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
run_e2e_wayland "$plain_root" --region >/dev/null 2>&1
rc=$?
assert_eq "e2e wayland cancelled slurp: exit 1" "1" "$rc"
[ ! -e "$TYPELOG" ]
check "e2e wayland cancelled slurp: nothing typed" $?
mv "$WSTUBS/slurp.ok" "$WSTUBS/slurp"

# No grim on PATH -> die with install hint.
NOGRIM="$TMP/nogrim"
mkdir -p "$NOGRIM"
out="$(env -i HOME="$HOME" WAYLAND_DISPLAY=wayland-1 PATH="$NOGRIM:/usr/bin:/bin" \
    HOTSHOT_DIR="$TMP/wshots" bash "$SCRIPT" --full 2>&1)"
rc=$?
assert_eq "e2e wayland no grim: exit 1" "1" "$rc"
case "$out" in *"install 'grim'"*) check "e2e wayland no grim: message names grim" 0 ;; *) check "e2e wayland no grim: message names grim" 1 ;; esac

# wtype missing -> ydotool fallback types the text.
mkdir -p "$TMP/ydostubs"
cp "$WSTUBS/grim" "$WSTUBS/slurp" "$WSTUBS/wl-copy" "$WSTUBS/swaymsg" "$TMP/ydostubs/"
cat >"$TMP/ydostubs/ydotool" <<EOF
#!/usr/bin/env bash
while [ "\$1" != "--" ]; do shift; done
shift
printf '%s' "\$*" >>"$TYPELOG"
EOF
chmod +x "$TMP/ydostubs"/*
root="$(spawn_tree claude)"
rm -f "$TYPELOG" "$CLIPLOG" "$GRIMLOG"
shot="$(env -i HOME="$HOME" WAYLAND_DISPLAY=wayland-1 SWAYSOCK="$TMP/sway.sock" \
    PATH="$TMP/ydostubs:/usr/bin:/bin" HOTSHOT_DIR="$TMP/wshots" \
    HOTSHOT_TEST_FOCUS_PID="$root" bash "$SCRIPT" --full)"
rc=$?
assert_eq "e2e wayland ydotool fallback: exit 0" "0" "$rc"
assert_eq "e2e wayland ydotool fallback: typed bracketed path" "[$shot] " "$(cat "$TYPELOG")"

# Hyprland focus detection: hyprctl activewindow -j supplies the pid.
HYPRSTUBS="$TMP/hyprstubs"
mkdir -p "$HYPRSTUBS"
cp "$WSTUBS/grim" "$WSTUBS/slurp" "$WSTUBS/wl-copy" "$WSTUBS/wtype" "$HYPRSTUBS/"
cat >"$HYPRSTUBS/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '{"pid":%s}\n' "${HOTSHOT_TEST_FOCUS_PID:?}"
EOF
chmod +x "$HYPRSTUBS"/*
root="$(spawn_tree copilot)"
rm -f "$TYPELOG" "$CLIPLOG" "$GRIMLOG"
shot="$(env -i HOME="$HOME" WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=test \
    PATH="$HYPRSTUBS:/usr/bin:/bin" HOTSHOT_DIR="$TMP/wshots" \
    HOTSHOT_TEST_FOCUS_PID="$root" bash "$SCRIPT" --full)"
rc=$?
assert_eq "e2e hyprland copilot: exit 0" "0" "$rc"
assert_eq "e2e hyprland copilot: typed escaped bare path" "$(shell_escape "$shot") " "$(cat "$TYPELOG")"

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
