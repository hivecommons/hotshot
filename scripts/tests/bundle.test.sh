#!/usr/bin/env bash
# Test suite for scripts/bundle.sh.
#
# Hermetic: no Xcode/swift toolchain and no writable /Applications are needed.
# Each test copies bundle.sh into a temp project skeleton and runs it with
# stubbed external tools (swift, pgrep, kill, open, sleep) on PATH. cp and rm
# are wrapped so the --install branch's writes to /Applications are captured
# in a log instead of touching the real system.
#
# Usage: bash scripts/tests/bundle.test.sh
set -u

BUNDLER="$(cd "$(dirname "$0")/.." && pwd)/bundle.sh"
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

TMP="$(mktemp -d /tmp/hotshot-bundle-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"
LOG="$TMP/calls.log"
mkdir -p "$STUBS"

REAL_CP="$(command -v cp)"
REAL_RM="$(command -v rm)"

# swift stub: `swift build -c release` produces .build/release/hotshot in cwd.
cat >"$STUBS/swift" <<EOF
#!/usr/bin/env bash
echo "swift \$*" >>"$LOG"
if [ "\${SWIFT_FAIL:-0}" = 1 ]; then
    echo "error: stubbed build failure" >&2
    exit 1
fi
mkdir -p .build/release
printf 'BINARY' >.build/release/hotshot
chmod +x .build/release/hotshot
EOF

# cp/rm wrappers: divert anything touching /Applications into the log,
# delegate everything else to the real tools so the bundle gets built.
cat >"$STUBS/cp" <<EOF
#!/usr/bin/env bash
case "\$*" in
    */Applications*)
        echo "cp \$*" >>"$LOG"
        exit 0
        ;;
esac
exec "$REAL_CP" "\$@"
EOF

cat >"$STUBS/rm" <<EOF
#!/usr/bin/env bash
case "\$*" in
    */Applications*)
        echo "rm \$*" >>"$LOG"
        exit 0
        ;;
esac
exec "$REAL_RM" "\$@"
EOF

# pgrep stub: PGREP_PID simulates a running hotshot instance.
cat >"$STUBS/pgrep" <<EOF
#!/usr/bin/env bash
echo "pgrep \$*" >>"$LOG"
if [ -n "\${PGREP_PID:-}" ]; then
    echo "\$PGREP_PID"
    exit 0
fi
exit 1
EOF

for t in kill open sleep; do
    cat >"$STUBS/$t" <<EOF
#!/usr/bin/env bash
echo "$t \$*" >>"$LOG"
exit 0
EOF
done
chmod +x "$STUBS"/*

# kill is a bash builtin and would bypass the PATH stub (and signal a real
# pid); BASH_ENV disables the builtin in the non-interactive shell running
# bundle.sh so the stub is used instead.
BASHENV="$TMP/bashenv"
echo 'enable -n kill' >"$BASHENV"

make_project() { # $1 = dir; builds a minimal project skeleton around bundle.sh
    mkdir -p "$1/scripts" "$1/resources"
    "$REAL_CP" "$BUNDLER" "$1/scripts/bundle.sh"
    printf 'ICONDATA' >"$1/resources/AppIcon.icns"
}

run_bundle() { # $1 = project dir; remaining args passed to bundle.sh
    local proj="$1"
    shift
    (cd "$proj" && env -i HOME="$TMP" PATH="$STUBS:/usr/bin:/bin" \
        BASH_ENV="$BASHENV" \
        PGREP_PID="${PGREP_PID:-}" SWIFT_FAIL="${SWIFT_FAIL:-0}" \
        bash scripts/bundle.sh "$@")
}

# ==============================================================================
# default (no --install): bundle layout and Info.plist
# ==============================================================================
PROJ="$TMP/proj"
make_project "$PROJ"
: >"$LOG"
out="$(run_bundle "$PROJ" 2>&1)"
rc=$?
assert_eq "bundle: exit 0" "0" "$rc"

APP="$PROJ/Hotshot.app"
if [ -x "$APP/Contents/MacOS/hotshot" ]; then check "bundle: executable installed at Contents/MacOS/hotshot" 0; else check "bundle: executable installed at Contents/MacOS/hotshot" 1; fi
assert_eq "bundle: binary content copied from build output" "BINARY" "$(cat "$APP/Contents/MacOS/hotshot")"
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then check "bundle: AppIcon.icns copied into Resources" 0; else check "bundle: AppIcon.icns copied into Resources" 1; fi

PLIST="$(cat "$APP/Contents/Info.plist")"
assert_contains "plist: bundle identifier" "<string>io.hivecommons.hotshot</string>" "$PLIST"
assert_contains "plist: executable name matches copied binary" "<string>hotshot</string>" "$PLIST"
assert_contains "plist: menu-bar app (LSUIElement)" "<key>LSUIElement</key>" "$PLIST"
assert_contains "plist: Apple Events usage description present" "NSAppleEventsUsageDescription" "$PLIST"
assert_contains "plist: icon file key" "<string>AppIcon</string>" "$PLIST"
assert_contains "plist: package type APPL" "<string>APPL</string>" "$PLIST"
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APP/Contents/Info.plist"
    check "plist: well-formed XML (xmllint)" $?
fi

grep -q "swift build -c release" "$LOG"
check "bundle: release build invoked" $?
assert_contains "bundle: prints install hint when not installing" "--install" "$out"
if grep -q "^open " "$LOG"; then check "bundle: does not launch app without --install" 1; else check "bundle: does not launch app without --install" 0; fi
if grep -q "^cp -r .*/Applications" "$LOG"; then check "bundle: does not copy to /Applications without --install" 1; else check "bundle: does not copy to /Applications without --install" 0; fi

# Rebuild replaces a stale bundle rather than layering onto it.
STALE="$APP/Contents/MacOS/stale-file"
mkdir -p "$APP/Contents/MacOS"
printf 'stale' >"$STALE"
run_bundle "$PROJ" >/dev/null 2>&1
rc=$?
assert_eq "rebuild: exit 0" "0" "$rc"
if [ -e "$STALE" ]; then check "rebuild: stale bundle contents removed" 1; else check "rebuild: stale bundle contents removed" 0; fi

# ==============================================================================
# failed build aborts before bundling (set -e)
# ==============================================================================
PROJ2="$TMP/proj-fail"
make_project "$PROJ2"
out="$(SWIFT_FAIL=1 run_bundle "$PROJ2" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then check "build failure: non-zero exit" 0; else check "build failure: non-zero exit" 1; fi
if [ -e "$PROJ2/Hotshot.app" ]; then check "build failure: no bundle created" 1; else check "build failure: no bundle created" 0; fi

# ==============================================================================
# --install: no running instance
# ==============================================================================
PROJ3="$TMP/proj-install"
make_project "$PROJ3"
: >"$LOG"
out="$(run_bundle "$PROJ3" --install 2>&1)"
rc=$?
assert_eq "--install: exit 0" "0" "$rc"
grep -q "^rm -rf /Applications/Hotshot.app" "$LOG"
check "--install: removes previous /Applications bundle" $?
grep -q "^cp -r $PROJ3/Hotshot.app /Applications/" "$LOG"
check "--install: copies fresh bundle to /Applications" $?
grep -q "^open /Applications/Hotshot.app" "$LOG"
check "--install: relaunches installed app" $?
if grep -q "^kill " "$LOG"; then check "--install: no kill when nothing is running" 1; else check "--install: no kill when nothing is running" 0; fi
assert_contains "--install: reports success" "Installed and relaunched" "$out"

# ==============================================================================
# --install: running instance is stopped first
# ==============================================================================
: >"$LOG"
out="$(PGREP_PID=99999242 run_bundle "$PROJ3" --install 2>&1)"
rc=$?
assert_eq "--install (running): exit 0" "0" "$rc"
grep -q "^kill 99999242" "$LOG"
check "--install (running): kills the running instance by pid" $?
assert_contains "--install (running): reports the stop" "Stopping running hotshot (pid 99999242)" "$out"
grep -q "^open /Applications/Hotshot.app" "$LOG"
check "--install (running): still relaunches after kill" $?

# kill ordering: the app must be stopped before the new bundle is copied in.
kill_line="$(grep -n "^kill " "$LOG" | cut -d: -f1 | head -1)"
cp_line="$(grep -n "^cp -r .*/Applications/" "$LOG" | cut -d: -f1 | head -1)"
if [ -n "$kill_line" ] && [ -n "$cp_line" ] && [ "$kill_line" -lt "$cp_line" ]; then
    check "--install (running): kill happens before install copy" 0
else
    check "--install (running): kill happens before install copy" 1
fi

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
