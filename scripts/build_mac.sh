#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESET_STATE=0

for arg in "$@"; do
    case "$arg" in
        --reset-state)
            RESET_STATE=1
            ;;
        -h|--help)
            echo "Usage: $0 [--reset-state]"
            echo ""
            echo "  --reset-state  After building, remove stale local privacy/defaults state"
            echo "                 and re-register the rebuilt app."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--reset-state]" >&2
            exit 1
            ;;
    esac
done

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

# Where SwiftPM keeps its build artifacts and build.db. Overridable because on some
# setups a checkout under ~/Documents makes SwiftPM's SQLite build database fail with
# "accessing build database ...: disk I/O error" — the compile succeeds but the exit
# status is non-zero, so `set -e` aborts before the second architecture is built.
# Point this somewhere outside the synced/managed tree to work around it, e.g.
#   SCRATCH_PATH=/tmp/sidescreen-build ./scripts/build_mac.sh
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT_DIR/MacHost/.build}"

# Clean old build
echo "Cleaning old build..."
rm -rf "$SCRATCH_PATH"

# Build fresh (Universal Binary: arm64 + x86_64)
echo "Building macOS Host (arm64)..."
swift build -c release --arch arm64 --scratch-path "$SCRATCH_PATH"

echo "Building macOS Host (x86_64)..."
swift build -c release --arch x86_64 --scratch-path "$SCRATCH_PATH"

echo "Creating Universal Binary..."
mkdir -p "$SCRATCH_PATH/release-universal"
lipo -create \
  "$SCRATCH_PATH/arm64-apple-macosx/release/SideScreen" \
  "$SCRATCH_PATH/x86_64-apple-macosx/release/SideScreen" \
  -output "$SCRATCH_PATH/release-universal/SideScreen"

# Create .app bundle
APP_NAME="SideScreen"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary
cp "$SCRATCH_PATH/release-universal/SideScreen" "$APP_DIR/Contents/MacOS/"

# No LaunchAgent plist needed for SMAppService.mainApp

# Copy app icon if exists
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
EOF

# Ad-hoc code sign to prevent Gatekeeper "damaged" error
echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR"
echo "  ✓ App signed"

echo ""
echo "Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
DMG_DIR=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
DMG_PATH="$ROOT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
hdiutil create -volname "Side Screen" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_DIR"
echo "DMG: $DMG_PATH"

if [ "$RESET_STATE" -eq 1 ]; then
    echo ""
    echo "Resetting local app/privacy state for rebuilt app..."
    APP_PATH="$APP_DIR" "$SCRIPT_DIR/reset_settings.sh"
fi
