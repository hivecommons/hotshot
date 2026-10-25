#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Hotshot"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Releases are v-prefixed semver tags; fall back to 0.0.0 outside a git checkout.
VERSION="$(git -C "$PROJECT_DIR" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')"
[ -n "$VERSION" ] || VERSION="0.0.0"
SHORT_VERSION="${VERSION%%-*}"
case "$SHORT_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) SHORT_VERSION="0.0.0" ;;
esac

echo "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp .build/release/hotshot "$MACOS/hotshot"
cp "$PROJECT_DIR/resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Hotshot</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Hotshot pastes screenshots into your terminal by sending it Apple Events. Without this permission, injection silently fails.</string>
    <key>CFBundleDisplayName</key>
    <string>Hotshot</string>
    <key>CFBundleIdentifier</key>
    <string>io.hivecommons.hotshot</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>hotshot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Done: $APP_BUNDLE"
echo ""

if [ "${1:-}" = "--install" ]; then
    echo "Installing to /Applications..."
    # Kill any running instance so the new build takes effect immediately.
    RUNNING_PID="$(pgrep -x hotshot || true)"
    if [ -n "$RUNNING_PID" ]; then
        echo "Stopping running hotshot (pid $RUNNING_PID)..."
        kill $RUNNING_PID || true
        sleep 1
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -r "$APP_BUNDLE" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed and relaunched /Applications/$APP_NAME.app"
else
    echo "To install (kills + relaunches any running instance):"
    echo "  $0 --install"
    echo ""
    echo "Or manually:"
    echo "  cp -r $APP_BUNDLE /Applications/"
    echo ""
    echo "To run:"
    echo "  open /Applications/Hotshot.app"
fi
