#!/bin/bash
# Launch smoke for Hotshot.app's app delegate (Sources/hotshot/main.swift).
#
# Runs Contents/MacOS/hotshot with hotshotScreenshotDir pointed at a fresh,
# not-yet-existing directory and waits for the delegate's NSLog diagnostics
# (app.launched, watcher.started, clipboard.watch_started) on stderr. Also
# asserts the delegate created the directory. The app is stopped with SIGTERM
# and the previous preference is restored. The captured app log is printed on
# failure.
#
# HOTSHOT_SMOKE_TIMEOUT: seconds to wait for the diagnostics (default 30).
#
# Usage: bash scripts/smoke.sh   (after scripts/bundle.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BIN="$PROJECT_DIR/Hotshot.app/Contents/MacOS/hotshot"
DOMAIN="io.hivecommons.hotshot"
PREF_KEY="hotshotScreenshotDir"
TIMEOUT="${HOTSHOT_SMOKE_TIMEOUT:-30}"

if [ ! -x "$APP_BIN" ]; then
    echo "FAIL: $APP_BIN not found; run scripts/bundle.sh first" >&2
    exit 1
fi
if ! command -v defaults >/dev/null 2>&1; then
    echo "FAIL: 'defaults' not found; the launch smoke needs macOS" >&2
    exit 1
fi

WORK="$(mktemp -d)"
LOG="$WORK/app.log"
SHOT_DIR="$WORK/screenshots"
APP_PID=""

if PREVIOUS="$(defaults read "$DOMAIN" "$PREF_KEY" 2>/dev/null)"; then
    HAD_PREVIOUS=1
else
    HAD_PREVIOUS=0
fi

cleanup() {
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    if [ "$HAD_PREVIOUS" -eq 1 ]; then
        defaults write "$DOMAIN" "$PREF_KEY" "$PREVIOUS"
    else
        defaults delete "$DOMAIN" "$PREF_KEY" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

defaults write "$DOMAIN" "$PREF_KEY" "$SHOT_DIR"

echo "Launching $APP_BIN (screenshot dir: $SHOT_DIR)..."
"$APP_BIN" >/dev/null 2>"$LOG" &
APP_PID=$!

missing=""
check_ready() {
    missing=""
    for event in app.launched watcher.started clipboard.watch_started; do
        grep -qF "$event" "$LOG" || missing="$missing $event"
    done
    [ -d "$SHOT_DIR" ] || missing="$missing screenshot-dir"
}

waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
    check_ready
    [ -z "$missing" ] && break
    waited=$((waited + 1))
    sleep 1
done

if [ -n "$missing" ]; then
    echo "FAIL: not seen within ${TIMEOUT}s:$missing" >&2
    echo "--- app log ---" >&2
    cat "$LOG" >&2
    exit 1
fi

echo "ok: app.launched, watcher.started, clipboard.watch_started logged and screenshot dir created"
