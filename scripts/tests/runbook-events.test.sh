#!/usr/bin/env bash
# Test suite for scripts/runbook-events.sh.
#
# Hermetic: builds a throwaway runbook directory and source tree per case and
# points the guard at them with positional arguments. The final case runs the
# guard against the real repository so a stale runbook fails this suite.
#
# Usage: bash scripts/tests/runbook-events.test.sh
set -u

GUARD="$(cd "$(dirname "$0")/.." && pwd)/runbook-events.sh"
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

assert_not_contains() { # $1 = description, $2 = needle, $3 = haystack
    case "$3" in
        *"$2"*)
            check "$1" 1
            echo "    expected not to contain: $(printf '%q' "$2")"
            ;;
        *) check "$1" 0 ;;
    esac
}

TMP="$(mktemp -d /tmp/hotshot-runbook-events-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Runs the guard; BASH_ENV lets scripts/shell-coverage.sh trace its lines.
run_guard() {
    BASH_ENV="${HOTSHOT_COVERAGE_RC:-}" bash "$GUARD" "$@" 2>&1
}

# fixture NAME: fresh runbook dir + source tree under $TMP/NAME.
# Sets RB (runbooks) and SRC (sources) for the caller.
fixture() {
    RB="$TMP/$1/runbooks"
    SRC="$TMP/$1/src"
    mkdir -p "$RB" "$SRC/Sources" "$SRC/linux" "$SRC/windows" "$SRC/Tests" "$SRC/windows/tests"
}

# ==============================================================================
# 1. Every runbook event emitted by some source: exit 0, one ok line each

fixture all-emitted
cat >"$RB/a.md" <<'EOF'
| `app.launched` (info) | started | — |
| `injection.ydotool_failed` (warn, Linux) | ydotool failed | — |
See `injection.sendkeys_failed` (Windows) and the domain `io.hivecommons.hotshot`.
EOF
cat >"$SRC/Sources/Diagnostics.swift" <<'EOF'
    case appLaunched = "app.launched"
EOF
cat >"$SRC/linux/capture.sh" <<'EOF'
log_event WARN injection.ydotool_failed "is ydotoold running?"
EOF
cat >"$SRC/windows/Capture.psm1" <<'EOF'
Format-HotshotDiagnostic -Severity WARN -Event 'injection.sendkeys_failed' -Detail "$_"
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "all emitted: exit 0" 0 "$rc"
assert_contains "all emitted: swift literal accepted" "ok      app.launched" "$out"
assert_contains "all emitted: bash log_event argument accepted" "ok      injection.ydotool_failed" "$out"
assert_contains "all emitted: single-quoted PowerShell literal accepted" "ok      injection.sendkeys_failed" "$out"
assert_not_contains "all emitted: dotted domain is not treated as an event" "io.hivecommons" "$out"
assert_eq "all emitted: exactly three events reported" 3 "$(grep -c '^ok ' <<<"$out")"

# ==============================================================================
# 2. Event named in a runbook but emitted nowhere: exit 1 and MISSING line

fixture orphan
cat >"$RB/a.md" <<'EOF'
`app.launched` and `watcher.renamed_event` are logged.
EOF
cat >"$SRC/Sources/Diagnostics.swift" <<'EOF'
    case appLaunched = "app.launched"
    case watcherNewName = "watcher.new_name"
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "orphan: exit 1" 1 "$rc"
assert_contains "orphan: names the missing event" "MISSING watcher.renamed_event" "$out"
assert_contains "orphan: still reports the emitted one" "ok      app.launched" "$out"

# ==============================================================================
# 3. An event mentioned only in tests does not count as emitted

fixture tests-only
cat >"$RB/a.md" <<'EOF'
`injection.focus_lost` is logged.
EOF
cat >"$SRC/Tests/InjectorTests.swift" <<'EOF'
    XCTAssertEqual(event, "injection.focus_lost")
EOF
cat >"$SRC/windows/tests/capture.tests.ps1" <<'EOF'
    It 'warns injection.focus_lost' { 'injection.focus_lost' }
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "tests-only: exit 1" 1 "$rc"
assert_contains "tests-only: reported MISSING" "MISSING injection.focus_lost" "$out"

# ==============================================================================
# 4. An unquoted identifier in Swift (e.g. a method call) is not an emission

fixture unquoted
cat >"$RB/a.md" <<'EOF'
`watcher.stopped` is logged.
EOF
cat >"$SRC/Sources/Watcher.swift" <<'EOF'
    watcher.stopped()
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "unquoted: exit 1" 1 "$rc"
assert_contains "unquoted: reported MISSING" "MISSING watcher.stopped" "$out"

# ==============================================================================
# 5. Runbook directory with no event names fails loudly rather than vacuously

fixture empty
echo "No events here." >"$RB/a.md"
cat >"$SRC/Sources/Diagnostics.swift" <<'EOF'
    case appLaunched = "app.launched"
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "empty runbooks: exit 1" 1 "$rc"
assert_contains "empty runbooks: explains the failure" "no event names found" "$out"

# ==============================================================================
# 6. Multiple runbook files are all scanned; duplicates reported once

fixture multi
echo '`app.launched`' >"$RB/a.md"
printf '`app.launched` `watcher.started`\n' >"$RB/b.md"
cat >"$SRC/Sources/Diagnostics.swift" <<'EOF'
    case appLaunched = "app.launched"
    case watcherStarted = "watcher.started"
EOF

out="$(run_guard "$RB" "$SRC")"
rc=$?
assert_eq "multi: exit 0" 0 "$rc"
assert_eq "multi: each event listed once" 2 "$(grep -c '^ok ' <<<"$out")"

# ==============================================================================
# 7. The real repository: every event in runbooks/*.md is emitted

out="$(run_guard)"
rc=$?
assert_eq "repo: runbooks name only emitted events (exit 0)" 0 "$rc"
if [ "$rc" -ne 0 ]; then
    grep '^MISSING' <<<"$out" | sed 's/^/    /'
fi
check "repo: at least one event found in runbooks" "$([ "$(grep -c '^ok ' <<<"$out")" -gt 0 ]; echo $?)"

# ==============================================================================
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
