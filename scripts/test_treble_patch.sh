#!/usr/bin/env bash
# Regression test for safe Treble property patching.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/treble-patch-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/system/etc/init" "$TEST_DIR/system/priv-app"
cat > "$TEST_DIR/system/build.prop" <<'EOF'
ro.build.display.id=Official Test Build
ro.build.description=test-device-user 14 UP1A release-keys
ro.debuggable=0
EOF

TREBLE_OVERLAY_URL= TREBLE_APP_URL= \
  bash "$ROOT_DIR/scripts/patch_treble.sh" "$TEST_DIR" generic >/dev/null

grep -Fx 'ro.treble.enabled=true' "$TEST_DIR/system/build.prop" >/dev/null
grep -Fx 'ro.debuggable=0' "$TEST_DIR/system/build.prop" >/dev/null
grep -F 'UNOFFICIAL' "$TEST_DIR/system/build.prop" >/dev/null
grep -F 'via h3cknnGSI_tool' "$TEST_DIR/system/build.prop" >/dev/null
if grep -Eq '^persist\.sys\.usb\.config=|^persist\.sys\.phh\.no_stock_apps=' "$TEST_DIR/system/build.prop"; then
  echo "[-] Unsafe universal USB/PHH property was injected." >&2
  exit 1
fi

echo "==> Treble patch safety test passed."
