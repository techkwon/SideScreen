#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
STREAM_PORT="${STREAM_PORT:-54321}"
HEALTH_PORT="${HEALTH_PORT:-$((STREAM_PORT + 1))}"
CAMERA_PORT="${CAMERA_PORT:-54323}"

echo "📱 Installing Android app..."

# Check if APK exists
if [ ! -f "$APK_PATH" ]; then
    echo "❌ APK not found. Building first..."
    "$SCRIPT_DIR/build_android.sh"
fi

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi

# Install APK
adb install -r "$APK_PATH"

echo ""
echo "✅ App installed successfully!"
echo ""
echo "📲 Setting up USB port forwarding..."
adb reverse --remove "tcp:$STREAM_PORT" 2>/dev/null || true
adb reverse --remove "tcp:$HEALTH_PORT" 2>/dev/null || true
adb reverse --remove "tcp:$CAMERA_PORT" 2>/dev/null || true
adb reverse "tcp:$STREAM_PORT" "tcp:$STREAM_PORT"
adb reverse "tcp:$HEALTH_PORT" "tcp:$HEALTH_PORT"
adb reverse "tcp:$CAMERA_PORT" "tcp:$CAMERA_PORT"

echo "✅ Ports $STREAM_PORT, $HEALTH_PORT and $CAMERA_PORT forwarded"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready! Open 'Side Screen' on your Android device"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
