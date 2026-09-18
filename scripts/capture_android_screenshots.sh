#!/usr/bin/env bash
# Capture Android build-information and home-screen screenshots from a running
# emulator. Intended for GitHub Actions and local adb testing.

set -euo pipefail

OUTPUT_DIR="${1:-android-screenshots}"
mkdir -p "$OUTPUT_DIR"

ADB_BIN="${ADB_BIN:-adb}"

echo "==> Waiting for Android emulator..."
"$ADB_BIN" wait-for-device

for attempt in $(seq 1 60); do
  BOOT_COMPLETED=$("$ADB_BIN" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [ "$BOOT_COMPLETED" = "1" ]; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "[-] ERROR: Android emulator did not finish booting." >&2
    exit 1
  fi
  sleep 2
done

"$ADB_BIN" shell input keyevent KEYCODE_WAKEUP || true
"$ADB_BIN" shell wm dismiss-keyguard || true
"$ADB_BIN" shell am start -a android.settings.DEVICE_INFO_SETTINGS >/dev/null
sleep 3
"$ADB_BIN" exec-out screencap -p > "$OUTPUT_DIR/build-info.png"
"$ADB_BIN" shell getprop > "$OUTPUT_DIR/build-properties.txt"

"$ADB_BIN" shell input keyevent KEYCODE_HOME
sleep 2
"$ADB_BIN" exec-out screencap -p > "$OUTPUT_DIR/home-screen.png"

echo "==> Screenshots captured in $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/build-info.png "$OUTPUT_DIR"/home-screen.png
