#!/usr/bin/env bash
# Collect evidence for a GSI install/boot failure from an attached Android
# device. This does not modify partitions or change device state.

set -Eeuo pipefail

SERIAL="${1:-}"
OUTPUT_DIR="${2:-boot-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)}"

if ! command -v adb >/dev/null 2>&1; then
  echo "[-] ERROR: adb is required. Install Android platform-tools first." >&2
  exit 2
fi

ADB_ARGS=()
if [ -n "$SERIAL" ]; then
  ADB_ARGS=(-s "$SERIAL")
fi

adb_cmd() {
  adb "${ADB_ARGS[@]}" "$@"
}

mkdir -p "$OUTPUT_DIR"
if ! adb_cmd get-state >/dev/null 2>&1; then
  echo "[-] ERROR: No usable Android device is connected or USB debugging is not authorized." >&2
  echo "    Usage: $0 [serial] [output-directory]" >&2
  exit 1
fi

echo "==> Collecting boot diagnostics into: $OUTPUT_DIR"

adb_cmd get-state > "$OUTPUT_DIR/adb-state.txt" 2>&1
adb_cmd shell getprop > "$OUTPUT_DIR/getprop.txt" 2>&1 || true
adb_cmd shell 'cat /proc/cmdline' > "$OUTPUT_DIR/proc-cmdline.txt" 2>&1 || true
adb_cmd shell 'cat /proc/mounts' > "$OUTPUT_DIR/proc-mounts.txt" 2>&1 || true
adb_cmd shell 'df -h' > "$OUTPUT_DIR/df.txt" 2>&1 || true
adb_cmd shell 'getenforce' > "$OUTPUT_DIR/selinux-mode.txt" 2>&1 || true
adb_cmd shell 'id' > "$OUTPUT_DIR/identity.txt" 2>&1 || true
adb_cmd shell 'dmesg' > "$OUTPUT_DIR/dmesg.txt" 2>&1 || true
adb_cmd shell 'cat /sys/fs/pstore/console-ramoops*' > "$OUTPUT_DIR/pstore.txt" 2>&1 || true
adb_cmd shell 'ls -la /dev/block/by-name /vendor /system /product' \
  > "$OUTPUT_DIR/partitions-and-mounts.txt" 2>&1 || true
adb_cmd shell 'cmd overlay list' > "$OUTPUT_DIR/overlays.txt" 2>&1 || true
adb_cmd logcat -b all -d -v threadtime > "$OUTPUT_DIR/logcat-all.txt" 2>&1 || true

# bugreport may require elevated device permissions and can fail on restricted
# builds; keep all other evidence if it is unavailable.
adb_cmd bugreport "$OUTPUT_DIR/bugreport.zip" > "$OUTPUT_DIR/bugreport-command.txt" 2>&1 || true

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUTPUT_DIR"/* > "$OUTPUT_DIR/SHA256SUMS.txt" 2>/dev/null || true
fi

echo "==> Boot diagnostics collected: $OUTPUT_DIR"
