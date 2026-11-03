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

# First segments that mark a reverse-DNS identifier (`com.apple.quarantine`),
# which fits the event alphabet but is not an event. Add a TLD here when a
# runbook starts naming identifiers under it. Never add an emitted event
# category (`app` is one): the check below fails if the list could hide one.
REVERSE_DNS_TLDS="com org net io dev co uk de"
tld_alternation="${REVERSE_DNS_TLDS// /|}"

# Event names are `<category>.<event>...` in lowercase snake_case; each segment
# starts with a letter and may contain digits and underscores
# (e.g. `iterm2`, `injection.iterm2.script`). Version strings like `v0.1.0` are
# skipped because segments starting with digits are excluded. Reverse-DNS
# identifiers (`io.hivecommons.hotshot`, `com.apple.quarantine`) fit the
# alphabet, so tokens whose first segment is in REVERSE_DNS_TLDS are dropped.
# Other backticked dotted tokens in the runbooks (file names) contain
# characters outside that alphabet and are skipped.
tokens="$(grep -ohE '`[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+`' "$RUNBOOK_DIR"/*.md 2>/dev/null | tr -d '`' | sort -u)"
events="$(grep -vE "^(${tld_alternation})\\." <<<"$tokens")"
excluded="$(grep -E "^(${tld_alternation})\\." <<<"$tokens")"

if [ -z "$events" ]; then
    echo "FAIL: no event names found in $RUNBOOK_DIR/*.md" >&2
    exit 1
fi

# Swift and PowerShell quote the literal ("app.launched" / 'app.launched');
# the bash script passes it bare as log_event's second argument. Test
# directories are excluded so a fixture naming an event does not count as
# the binary emitting it.
quoted_literals() {
    grep -rhoE "[\"'][a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+[\"']" "$@" --include='*.swift' --include='*.ps1' --include='*.psm1' --exclude-dir=Tests --exclude-dir=tests 2>/dev/null | tr -d "\"'"
}
bash_log_events() {
    grep -rhoE 'log_event +[A-Z]+ +[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+'  "$@" --include='*.sh' --exclude-dir=Tests --exclude-dir=tests 2>/dev/null | awk '{print $3}'
}
emitted="$({ quoted_literals "${SOURCE_DIRS[@]}"; bash_log_events "${SOURCE_DIRS[@]}"; } | sort -u)"

# A runbook token dropped as reverse-DNS that a source also emits as a literal
# would be an event silently hidden from the guard, so refuse to run rather
# than skip it. Sources also quote real reverse-DNS strings
# (`com.apple.quarantine`), so only two-segment `category.event` tokens count.
status=0
while IFS= read -r token; do
    grep -qE '^[a-z0-9_]+\.[a-z0-9_]+$' <<<"$token" || continue
    if grep -qxF "$token" <<<"$emitted"; then
        echo "FAIL: '$token' is emitted by a source but excluded as reverse-DNS (its prefix is in REVERSE_DNS_TLDS); remove the prefix from the list" >&2
        status=1
    fi
done <<<"$excluded"
[ "$status" -eq 0 ] || exit 1

while IFS= read -r event; do
    if grep -qxF "$event" <<<"$emitted"; then
        echo "ok      $event"
    else
        echo "MISSING $event (named in runbooks, emitted by no source)"
        status=1
    fi
done <<<"$events"

exit "$status"
