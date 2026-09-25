#!/usr/bin/env bash
# Regression tests for the GSI compatibility preflight.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gsi-compat-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

cat > "$TEST_DIR/arm64.prop" <<'EOF'
# ro.treble.enabled=false must not be parsed from a comment.
ro.treble.enabled=true
ro.product.cpu.abilist=arm64-v8a,armeabi-v7a,armeabi
ro.build.version.sdk=35
ro.build.version.release=15
ro.vndk.version=35
ro.product.device=generic
EOF

bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
  "$TEST_DIR/arm64.prop" SM-M127F "$TEST_DIR/arm64-report.txt" arm64 >/dev/null
grep -Fx 'Status: WARN' "$TEST_DIR/arm64-report.txt" >/dev/null
grep -F 'No universal kernel or hardware driver is embedded.' "$TEST_DIR/arm64-report.txt" >/dev/null
grep -F 'If the target vendor requires VNDKLite, use a known VNDKLite GSI' \
  "$TEST_DIR/arm64-report.txt" >/dev/null
grep -F 'Android 15 on Exynos 850 commonly needs an exact-device GSI-compatible kernel/boot image' \
  "$TEST_DIR/arm64-report.txt" >/dev/null

cat > "$TEST_DIR/abilist64.prop" <<'EOF'
ro.treble.enabled=true
ro.product.cpu.abilist64=arm64-v8a
ro.build.version.sdk=35
ro.product.system.model=Galaxy M12 Test Model
EOF

bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
  "$TEST_DIR/abilist64.prop" generic "$TEST_DIR/abilist64-report.txt" auto >/dev/null
grep -F 'CPU ABI: arm64-v8a' "$TEST_DIR/abilist64-report.txt" >/dev/null
grep -F 'GSI model marker: Galaxy M12 Test Model' "$TEST_DIR/abilist64-report.txt" >/dev/null

cat > "$TEST_DIR/arm32.prop" <<'EOF'
ro.treble.enabled=true
ro.product.cpu.abi=armeabi-v7a
ro.build.version.sdk=35
EOF

if bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
  "$TEST_DIR/arm32.prop" generic "$TEST_DIR/arm32-report.txt" arm64 >/dev/null 2>&1; then
  echo "[-] 32-bit GSI incorrectly passed ARM64 preflight." >&2
  exit 1
fi
grep -F "does not advertise an ARM64 ABI" "$TEST_DIR/arm32-report.txt" >/dev/null

bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
  "$TEST_DIR/arm32.prop" generic "$TEST_DIR/arm32-arm-report.txt" arm >/dev/null
grep -F 'Detected ABI profile: arm32' "$TEST_DIR/arm32-arm-report.txt" >/dev/null

bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
  "$TEST_DIR/arm32.prop" generic "$TEST_DIR/arm32-a64-report.txt" a64 >/dev/null
grep -F 'Requested ABI profile: a64' "$TEST_DIR/arm32-a64-report.txt" >/dev/null

echo "==> GSI compatibility preflight test passed."
