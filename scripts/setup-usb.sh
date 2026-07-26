#!/bin/bash
set -e

STREAM_PORT="${STREAM_PORT:-54321}"
HEALTH_PORT="${HEALTH_PORT:-$((STREAM_PORT + 1))}"
CAMERA_PORT="${CAMERA_PORT:-54323}"

echo "🔧 Setting up USB port forwarding..."

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Connect device via USB cable"
    echo "  2. Enable Developer Options on device"
    echo "  3. Enable USB Debugging in Developer Options"
    echo "  4. Accept the USB debugging prompt on device"
    echo "  5. Run this script again"
    exit 1
fi

echo "  ✓ Device connected"

# Remove existing reverse
echo "  Clearing existing port forwards..."
adb reverse --remove-all 2>/dev/null || true
sleep 0.5

# Setup new reverse
echo "  Setting up ports $STREAM_PORT, $HEALTH_PORT and $CAMERA_PORT..."
adb reverse "tcp:$STREAM_PORT" "tcp:$STREAM_PORT"
adb reverse "tcp:$HEALTH_PORT" "tcp:$HEALTH_PORT"
adb reverse "tcp:$CAMERA_PORT" "tcp:$CAMERA_PORT"

# Verify
if adb reverse --list | grep -q "tcp:$STREAM_PORT" && adb reverse --list | grep -q "tcp:$HEALTH_PORT" && adb reverse --list | grep -q "tcp:$CAMERA_PORT"; then
    echo ""
    echo "✅ USB port forwarding active!"
    echo ""
    adb reverse --list
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ready to connect. Make sure Mac app is running."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "❌ Port forwarding failed"
    exit 1
fi
