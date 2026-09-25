#!/usr/bin/env bash
# End-to-end smoke test for build_samsung_super.sh using a tiny synthetic super.

set -Eeuo pipefail

ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-super-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

for command_name in lpmake mke2fs simg2img img2simg lz4 7z; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] Missing test dependency: $command_name" >&2
    exit 1
  }
done

truncate -s 8M "$TEST_DIR/stock-system.img"
truncate -s 8M "$TEST_DIR/vendor.img"
truncate -s 8M "$TEST_DIR/product.img"
truncate -s 8M "$TEST_DIR/gsi.img"
mke2fs -t ext4 -F -L system "$TEST_DIR/stock-system.img" >/dev/null
mke2fs -t ext4 -F -L vendor "$TEST_DIR/vendor.img" >/dev/null
mke2fs -t ext4 -F -L product "$TEST_DIR/product.img" >/dev/null
mke2fs -t ext4 -F -L system "$TEST_DIR/gsi.img" >/dev/null

# Build a small sparse stock super with three logical partitions.
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
  --partition product:readonly:8388608:main \
  --image product="$TEST_DIR/product.img" \
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
[ -s "$TEST_DIR/output/smoke-super-only.tar" ]
[ -s "$TEST_DIR/output/super.img.lz4" ]
tar -tf "$TEST_DIR/output/smoke-super-only.tar" | grep -Fx 'super.img' >/dev/null
test "$(od -An -tx1 -N5 "$TEST_DIR/output/super.img.lz4" | tr -d '[:space:]')" = 04224d186c
python3 "$ROOT_DIR/tools/lpunpack.py" \
  --info --format json "$TEST_DIR/output/super.img" \
  | grep -F '"name": "system"' >/dev/null

img2simg "$TEST_DIR/stock-super.img" "$TEST_DIR/stock-super.sparse.img"
mkdir -p "$TEST_DIR/output-sparse"
SAMSUNG_DEVICE_MODEL=SM-TEST \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/stock-super.sparse.img" \
    "$TEST_DIR/gsi.img" \
    smoke-sparse \
    "$TEST_DIR/work-sparse" \
    "$TEST_DIR/output-sparse"

[ -s "$TEST_DIR/output-sparse/super.img" ]
[ -s "$TEST_DIR/output-sparse/smoke-sparse-super-only.tar" ]

lz4 -f "$TEST_DIR/stock-super.img" "$TEST_DIR/stock-input"
mkdir -p "$TEST_DIR/output-lz4"
SAMSUNG_DEVICE_MODEL=SM-TEST \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/stock-input" \
    "$TEST_DIR/gsi.img" \
    smoke-lz4 \
    "$TEST_DIR/work-lz4" \
    "$TEST_DIR/output-lz4"

[ -s "$TEST_DIR/output-lz4/super.img" ]
[ -s "$TEST_DIR/output-lz4/smoke-lz4-super-only.tar" ]
[ -s "$TEST_DIR/output-lz4/super.img.lz4" ]

# A real AP must carry matching vbmeta for an Odin package. Exercise the
# guarded path with a minimal valid AVB header and verify flags 0x03 survive
# Samsung-format LZ4 compression.
mkdir -p "$TEST_DIR/ap"
cp "$TEST_DIR/stock-super.img" "$TEST_DIR/ap/super.img"
python3 - "$TEST_DIR/ap/vbmeta.img" <<'PY'
import pathlib
import sys

data = bytearray(256)
data[:4] = b"AVB0"
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
cp "$TEST_DIR/ap/vbmeta.img" "$TEST_DIR/ap/vbmeta_system.img"
cp "$TEST_DIR/ap/vbmeta.img" "$TEST_DIR/ap/vbmeta_vendor.img"
lz4 -f -B6 --content-size "$TEST_DIR/ap/super.img" "$TEST_DIR/ap/super.img.lz4" >/dev/null
lz4 -f -B6 --content-size "$TEST_DIR/ap/vbmeta.img" "$TEST_DIR/ap/vbmeta.img.lz4" >/dev/null
lz4 -f -B6 --content-size "$TEST_DIR/ap/vbmeta_system.img" "$TEST_DIR/ap/vbmeta_system.img.lz4" >/dev/null
lz4 -f -B6 --content-size "$TEST_DIR/ap/vbmeta_vendor.img" "$TEST_DIR/ap/vbmeta_vendor.img.lz4" >/dev/null
python3 - "$TEST_DIR/boot.img" <<'PY'
import pathlib
import sys

data = bytearray(4096)
data[:8] = b"ANDROID!"
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
cp "$TEST_DIR/boot.img" "$TEST_DIR/ap/ap-boot.img"
lz4 -f -B6 --content-size "$TEST_DIR/ap/ap-boot.img" "$TEST_DIR/ap/boot.img.lz4" >/dev/null
tar -cf "$TEST_DIR/ap.tar" -C "$TEST_DIR/ap" \
  super.img.lz4 vbmeta.img.lz4 vbmeta_system.img.lz4 vbmeta_vendor.img.lz4 boot.img.lz4
mkdir -p "$TEST_DIR/output-ap"
SAMSUNG_DEVICE_MODEL=SM-TEST \
SAMSUNG_REMOVE_PRODUCT=1 \
SAMSUNG_BOOT_INPUT="$TEST_DIR/boot.img" \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/ap.tar" \
    "$TEST_DIR/gsi.img" \
    smoke-ap \
    "$TEST_DIR/work-ap" \
    "$TEST_DIR/output-ap"
bash "$ROOT_DIR/scripts/verify_samsung_package.sh" \
  "$TEST_DIR/output-ap" smoke-ap >/dev/null
[ -s "$TEST_DIR/output-ap/smoke-ap-odin.tar" ]
tar -tf "$TEST_DIR/output-ap/smoke-ap-odin.tar" | grep -Fx 'super.img.lz4' >/dev/null
tar -tf "$TEST_DIR/output-ap/smoke-ap-odin.tar" | grep -Fx 'vbmeta.img.lz4' >/dev/null
tar -tf "$TEST_DIR/output-ap/smoke-ap-odin.tar" | grep -Fx 'vbmeta_system.img.lz4' >/dev/null
tar -tf "$TEST_DIR/output-ap/smoke-ap-odin.tar" | grep -Fx 'vbmeta_vendor.img.lz4' >/dev/null
tar -tf "$TEST_DIR/output-ap/smoke-ap-odin.tar" | grep -Fx 'boot.img.lz4' >/dev/null
tar -xf "$TEST_DIR/output-ap/smoke-ap-odin.tar" -C "$TEST_DIR/output-ap"
lz4 -dc "$TEST_DIR/output-ap/vbmeta.img.lz4" > "$TEST_DIR/output-ap/vbmeta.img"
lz4 -dc "$TEST_DIR/output-ap/vbmeta_system.img.lz4" > "$TEST_DIR/output-ap/vbmeta_system.img"
lz4 -dc "$TEST_DIR/output-ap/vbmeta_vendor.img.lz4" > "$TEST_DIR/output-ap/vbmeta_vendor.img"
lz4 -dc "$TEST_DIR/output-ap/boot.img.lz4" > "$TEST_DIR/output-ap/boot.img"
test "$(od -An -tc -N8 "$TEST_DIR/output-ap/boot.img" | tr -d '[:space:]')" = ANDROID!
python3 - "$TEST_DIR/output-ap" <<'PY'
import pathlib
import struct
import sys

for name in ("vbmeta.img", "vbmeta_system.img", "vbmeta_vendor.img"):
    data = pathlib.Path(sys.argv[1], name).read_bytes()
    assert struct.unpack_from(">I", data, 120)[0] == 3, name
PY
mkdir -p "$TEST_DIR/output-ap/unpacked"
python3 "$ROOT_DIR/tools/lpunpack.py" \
  "$TEST_DIR/output-ap/super.img" \
  "$TEST_DIR/output-ap/unpacked" >/dev/null
if [ -e "$TEST_DIR/output-ap/unpacked/product.img" ]; then
  echo "[-] Product logical partition was not removed." >&2
  exit 1
fi
grep -F 'Removed logical partitions: product' \
  "$TEST_DIR/output-ap/smoke-ap.build-info.txt" >/dev/null

# With no boot_url, the exact stock AP boot image is carried automatically.
mkdir -p "$TEST_DIR/output-ap-auto"
SAMSUNG_DEVICE_MODEL=SM-M127F \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/ap.tar" \
    "$TEST_DIR/gsi.img" \
    smoke-ap-auto \
    "$TEST_DIR/work-ap-auto" \
    "$TEST_DIR/output-ap-auto"
bash "$ROOT_DIR/scripts/verify_samsung_package.sh" \
  "$TEST_DIR/output-ap-auto" smoke-ap-auto >/dev/null
tar -tf "$TEST_DIR/output-ap-auto/smoke-ap-auto-odin.tar" \
  | grep -Fx 'boot.img.lz4' >/dev/null
grep -F 'Removed logical partitions: product' \
  "$TEST_DIR/output-ap-auto/smoke-ap-auto.build-info.txt" >/dev/null

# A Galaxy M12 AP without root vbmeta or boot must not produce a misleading
# Odin package. Standalone super inputs remain supported above for TWRP users.
mkdir -p "$TEST_DIR/ap-incomplete"
cp "$TEST_DIR/ap/super.img.lz4" "$TEST_DIR/ap-incomplete/super.img.lz4"
cp "$TEST_DIR/ap/vbmeta_system.img.lz4" "$TEST_DIR/ap-incomplete/vbmeta_system.img.lz4"
tar -cf "$TEST_DIR/ap-incomplete.tar" -C "$TEST_DIR/ap-incomplete" \
  super.img.lz4 vbmeta_system.img.lz4
if SAMSUNG_DEVICE_MODEL=SM-M127F \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/ap-incomplete.tar" \
    "$TEST_DIR/gsi.img" \
    should-fail-m12-ap \
    "$TEST_DIR/work-incomplete-ap" \
    "$TEST_DIR/output-incomplete-ap"; then
  echo "[-] Incomplete M12 AP incorrectly produced a package." >&2
  exit 1
fi

printf 'not a filesystem image\n' > "$TEST_DIR/invalid.img"
if SAMSUNG_DEVICE_MODEL=SM-TEST \
  bash "$ROOT_DIR/scripts/build_samsung_super.sh" \
    "$TEST_DIR/stock-super.img" \
    "$TEST_DIR/invalid.img" \
    should-fail \
    "$TEST_DIR/work-invalid" \
    "$TEST_DIR/output-invalid"; then
  echo "[-] Invalid GSI input was incorrectly accepted." >&2
  exit 1
fi

echo "==> Samsung stock-super packaging test passed."
