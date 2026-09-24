#!/usr/bin/env bash
# End-to-end smoke test for build_samsung_super.sh using a tiny synthetic super.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-super-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

for command_name in lpmake mke2fs simg2img 7z; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

truncate -s 8M "$TEST_DIR/stock-system.img"
truncate -s 8M "$TEST_DIR/vendor.img"
truncate -s 8M "$TEST_DIR/gsi.img"
mke2fs -t ext4 -F -L system "$TEST_DIR/stock-system.img" >/dev/null
mke2fs -t ext4 -F -L vendor "$TEST_DIR/vendor.img" >/dev/null
mke2fs -t ext4 -F -L system "$TEST_DIR/gsi.img" >/dev/null

# Build a small sparse stock super with two logical partitions.
lpmake \
  --metadata-size 65536 \
  --super-name super \
  --metadata-slots 2 \
  --device super:67108864 \
  --group main:50331648 \
  --partition system:readonly:8388608:main \
  --image system="$TEST_DIR/stock-system.img" \
  --partition vendor:readonly:8388608:main \
  --image vendor="$TEST_DIR/vendor.img" \
  --output "$TEST_DIR/stock-super.img"

mkdir -p "$TEST_DIR/output"
SAMSUNG_DEVICE_MODEL=SM-TEST \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/stock-super.img" \
    "$TEST_DIR/gsi.img" \
    smoke \
    "$TEST_DIR/work" \
    "$TEST_DIR/output"

[ -s "$TEST_DIR/output/super.img" ]
[ -s "$TEST_DIR/output/smoke.tar" ]
tar -tf "$TEST_DIR/output/smoke.tar" | grep -Fx 'super.img' >/dev/null
python3 "$ROOT_DIR/tools/lpunpack.py" \
  --info --format json "$TEST_DIR/output/super.img" \
  | grep -F '"name": "system"' >/dev/null

echo "==> Samsung stock-super packaging test passed."
