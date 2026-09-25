#!/usr/bin/env bash
# Regression test for the direct-GSI property-only fast path.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/direct-gsi-preflight-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

for command_name in debugfs mke2fs truncate xz; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

truncate -s 8M "$TEST_DIR/source.img"
mke2fs -t ext4 -F -L system "$TEST_DIR/source.img" >/dev/null
cat > "$TEST_DIR/build.prop" <<'EOF'
ro.treble.enabled=true
ro.product.cpu.abilist64=arm64-v8a
ro.build.version.sdk=34
ro.product.system.model=Direct GSI Test Model
EOF
debugfs -w -R "write $TEST_DIR/build.prop /build.prop" \
  "$TEST_DIR/source.img" >/dev/null 2>&1
xz -c "$TEST_DIR/source.img" > "$TEST_DIR/source.img.xz"

mkdir -p "$TEST_DIR/output" "$TEST_DIR/work"
bash "$ROOT_DIR/scripts/extract_direct_gsi_prop.sh" \
  "$TEST_DIR/source.img.xz" "$TEST_DIR/output" "$TEST_DIR/work" >/dev/null

grep -Fx 'ro.treble.enabled=true' "$TEST_DIR/output/build.prop" >/dev/null
grep -Fx 'ro.product.system.model=Direct GSI Test Model' \
  "$TEST_DIR/output/build.prop" >/dev/null

echo "==> Direct GSI property fast-path test passed."
