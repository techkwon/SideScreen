#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_ID="${APP_ID:-com.sidescreen.app}"
APP_PATH="${APP_PATH:-$ROOT_DIR/SideScreen.app}"
APK_PATH="${APK_PATH:-$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk}"
STREAM_PORT="${STREAM_PORT:-54321}"
CAMERA_PORT="${CAMERA_PORT:-54323}"
if [ "$STREAM_PORT" -lt 65535 ]; then
    HEALTH_PORT="${HEALTH_PORT:-$((STREAM_PORT + 1))}"
else
    HEALTH_PORT="${HEALTH_PORT:-$((STREAM_PORT - 1))}"
fi
BACKUP_DIR="${BACKUP_DIR:-/tmp/sidescreen-reset-$(date +%Y%m%d-%H%M%S)}"

echo "Resetting SideScreen local app state..."
mkdir -p "$BACKUP_DIR"

osascript -e 'tell application "SideScreen" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x SideScreen >/dev/null 2>&1 || true

defaults export "$APP_ID" "$BACKUP_DIR/$APP_ID.defaults.plist" >/dev/null 2>&1 || true
defaults delete "$APP_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Saved Application State/$APP_ID.savedState"

echo "Resetting macOS privacy records for $APP_ID..."
tccutil reset ScreenCapture "$APP_ID" || true
tccutil reset Accessibility "$APP_ID" || true
tccutil reset ListenEvent "$APP_ID" || true

if [ -d "$APP_PATH" ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -u "$APP_PATH" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

if command -v adb >/dev/null 2>&1 && adb devices | grep -q "device$"; then
    echo "Resetting Android app data..."
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    adb shell pm clear "$APP_ID" || true

    if [ -f "$APK_PATH" ]; then
        adb install -r "$APK_PATH"
    else
        echo "APK not found, skipping install: $APK_PATH"
    fi

    echo "Configuring USB reverse ports $STREAM_PORT, $HEALTH_PORT and $CAMERA_PORT..."
    adb reverse --remove-all || true
    adb reverse "tcp:$STREAM_PORT" "tcp:$STREAM_PORT"
    adb reverse "tcp:$HEALTH_PORT" "tcp:$HEALTH_PORT"
    adb reverse "tcp:$CAMERA_PORT" "tcp:$CAMERA_PORT"
    adb reverse --list
else
    echo "ADB device not detected; skipped Android reset and USB reverse."
fi

if [ -d "$APP_PATH" ]; then
    open "$APP_PATH"
fi
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' || true

echo ""
echo "Done."
echo "Backup: $BACKUP_DIR"
echo "Enable SideScreen in System Settings > Privacy & Security > Screen & System Audio Recording."
