#!/usr/bin/env bash
# Check that every diagnostic event named in the runbooks is still emitted.
#
# The runbooks (runbooks/*.md) describe log events as backticked
# `category.event` names. Each one must appear as an event literal somewhere
# in the platform sources, otherwise an operator following the runbook greps
# for a line the binaries never write. Renaming an event in
# Sources/HotshotCore/Diagnostics.swift, linux/hotshot-capture.sh or
# windows/hotshot-capture.ps1 without touching the runbook is the drift this
# guard catches.
#
# Prints one `ok`/`MISSING` line per event and exits 1 if any are missing.
#
# Usage: bash scripts/runbook-events.sh [RUNBOOK_DIR SOURCE_DIR...]
#   (defaults: runbooks Sources linux windows, relative to the repo root)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -ge 2 ]; then
    RUNBOOK_DIR="$1"
    shift
    SOURCE_DIRS=("$@")
else
    RUNBOOK_DIR="$ROOT/runbooks"
    SOURCE_DIRS=("$ROOT/Sources" "$ROOT/linux" "$ROOT/windows")
fi

# Event names are `<category>.<event>` in lowercase snake_case; other
# backticked dotted tokens in the runbooks (domains, file names) contain
# characters outside that alphabet and are skipped.
events="$(grep -ohE '`[a-z_]+\.[a-z_]+`' "$RUNBOOK_DIR"/*.md 2>/dev/null | tr -d '`' | sort -u)"

if [ -z "$events" ]; then
    echo "FAIL: no event names found in $RUNBOOK_DIR/*.md" >&2
    exit 1
fi

# Swift and PowerShell quote the literal ("app.launched" / 'app.launched');
# the bash script passes it bare as log_event's second argument. Test
# directories are excluded so a fixture naming an event does not count as
# the binary emitting it.
quoted_literals() {
    grep -rhoE "[\"'][a-z_]+\.[a-z_]+[\"']" "$@" --include='*.swift' --include='*.ps1' --include='*.psm1' --exclude-dir=Tests --exclude-dir=tests 2>/dev/null | tr -d "\"'"
}
bash_log_events() {
    grep -rhoE 'log_event +[A-Z]+ +[a-z_]+\.[a-z_]+' "$@" --include='*.sh' --exclude-dir=Tests --exclude-dir=tests 2>/dev/null | awk '{print $3}'
}
emitted="$({ quoted_literals "${SOURCE_DIRS[@]}"; bash_log_events "${SOURCE_DIRS[@]}"; } | sort -u)"

status=0
while IFS= read -r event; do
    if grep -qxF "$event" <<<"$emitted"; then
        echo "ok      $event"
    else
        echo "MISSING $event (named in runbooks, emitted by no source)"
        status=1
    fi
done <<<"$events"

exit "$status"
