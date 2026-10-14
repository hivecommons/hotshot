#!/usr/bin/env bash
# Test suite for scripts/smoke.sh.
#
# Hermetic: no macOS, no Hotshot.app build. Each test copies smoke.sh into a
# temp project skeleton with a stub app binary at Hotshot.app/Contents/MacOS/
# hotshot and a stub `defaults` (file-backed store) and `sleep` on PATH.
# The stub app reads the screenshot dir through the stub `defaults`, creates
# it, and prints the diagnostics named in STUB_EVENTS to stderr.
#
# Usage: bash scripts/tests/smoke.test.sh
set -u

SMOKE="$(cd "$(dirname "$0")/.." && pwd)/smoke.sh"
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

TMP="$(mktemp -d /tmp/hotshot-smoke-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"
NODEFAULTS="$TMP/nodefaults"
LOG="$TMP/calls.log"
STORE="$TMP/defaults.store"
mkdir -p "$STUBS" "$NODEFAULTS"

REAL_CP="$(command -v cp)"

# defaults stub: one-key store in $STORE; logs every call.
cat >"$STUBS/defaults" <<EOF
#!/usr/bin/env bash
echo "defaults \$*" >>"$LOG"
case "\$1" in
    read)
        [ -f "$STORE" ] || exit 1
        cat "$STORE"
        ;;
    write) printf '%s' "\$4" >"$STORE" ;;
    delete) rm -f "$STORE" ;;
esac
EOF

# sleep stub: the wait loop must not slow the suite down.
cat >"$STUBS/sleep" <<EOF
#!/usr/bin/env bash
echo "sleep \$*" >>"$LOG"
exit 0
EOF
chmod +x "$STUBS"/*

make_project() { # $1 = dir; $2 = "noapp" to leave the app binary out
    mkdir -p "$1/scripts"
    "$REAL_CP" "$SMOKE" "$1/scripts/smoke.sh"
    [ "${2:-}" = "noapp" ] && return 0
    mkdir -p "$1/Hotshot.app/Contents/MacOS"
    cat >"$1/Hotshot.app/Contents/MacOS/hotshot" <<EOF
#!/usr/bin/env bash
dir="\$(defaults read io.hivecommons.hotshot hotshotScreenshotDir)"
[ "\${STUB_NO_DIR:-0}" = 1 ] || mkdir -p "\$dir"
for ev in \${STUB_EVENTS:-app.launched watcher.started clipboard.watch_started}; do
    echo "Hotshot [info] \$ev" >&2
done
EOF
    chmod +x "$1/Hotshot.app/Contents/MacOS/hotshot"
}

run_smoke() { # $1 = project dir; $2 = PATH prefix
    (cd "$1" && env -i HOME="$TMP" PATH="$2:/usr/bin:/bin" \
        BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" \
        STUB_EVENTS="${STUB_EVENTS:-app.launched watcher.started clipboard.watch_started}" \
        STUB_NO_DIR="${STUB_NO_DIR:-0}" \
        HOTSHOT_SMOKE_TIMEOUT="${HOTSHOT_SMOKE_TIMEOUT:-3}" \
        bash scripts/smoke.sh)
}

# ==============================================================================
# healthy launch, no previous preference
# ==============================================================================
PROJ="$TMP/proj"
make_project "$PROJ"
: >"$LOG"
rm -f "$STORE"
out="$(run_smoke "$PROJ" "$STUBS" 2>&1)"
rc=$?
assert_eq "healthy: exit 0" "0" "$rc"
assert_contains "healthy: reports ok" "ok: app.launched" "$out"
grep -q "^defaults write io.hivecommons.hotshot hotshotScreenshotDir /" "$LOG"
check "healthy: points hotshotScreenshotDir at a temp dir" $?
grep -q "^defaults delete io.hivecommons.hotshot hotshotScreenshotDir" "$LOG"
check "healthy: deletes the preference when none existed" $?
if [ -f "$STORE" ]; then check "healthy: preference not left behind" 1; else check "healthy: preference not left behind" 0; fi

# ==============================================================================
# healthy launch restores an existing preference
# ==============================================================================
: >"$LOG"
printf '/previous/dir' >"$STORE"
out="$(run_smoke "$PROJ" "$STUBS" 2>&1)"
rc=$?
assert_eq "restore: exit 0" "0" "$rc"
assert_eq "restore: previous preference written back" "/previous/dir" "$(cat "$STORE")"

# ==============================================================================
# a missing diagnostic fails and prints the app log
# ==============================================================================
: >"$LOG"
rm -f "$STORE"
out="$(STUB_EVENTS="app.launched watcher.started" run_smoke "$PROJ" "$STUBS" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then check "missing event: non-zero exit" 0; else check "missing event: non-zero exit" 1; fi
assert_contains "missing event: names the absent diagnostic" "clipboard.watch_started" "$out"
assert_contains "missing event: prints the captured app log" "Hotshot [info] watcher.started" "$out"
grep -q "^defaults delete" "$LOG"
check "missing event: preference still restored" $?

# ==============================================================================
# the delegate not creating the screenshot dir fails
# ==============================================================================
: >"$LOG"
out="$(STUB_NO_DIR=1 run_smoke "$PROJ" "$STUBS" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then check "no dir: non-zero exit" 0; else check "no dir: non-zero exit" 1; fi
assert_contains "no dir: names the missing directory" "screenshot-dir" "$out"

# ==============================================================================
# preconditions fail clearly
# ==============================================================================
PROJ2="$TMP/proj-noapp"
make_project "$PROJ2" noapp
out="$(run_smoke "$PROJ2" "$STUBS" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then check "no bundle: non-zero exit" 0; else check "no bundle: non-zero exit" 1; fi
assert_contains "no bundle: points at bundle.sh" "scripts/bundle.sh" "$out"

# Only meaningful where no real `defaults` exists (Linux).
if ! PATH="/usr/bin:/bin" command -v defaults >/dev/null 2>&1; then
    out="$(run_smoke "$PROJ" "$NODEFAULTS" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then check "no defaults: non-zero exit" 0; else check "no defaults: non-zero exit" 1; fi
    assert_contains "no defaults: explains macOS requirement" "needs macOS" "$out"
fi

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
