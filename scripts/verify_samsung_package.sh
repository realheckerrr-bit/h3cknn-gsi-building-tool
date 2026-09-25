#!/usr/bin/env bash
# ============================================================================
# verify_samsung_package.sh - verify the final Samsung package artifacts
#
# This validates the container and metadata that Odin will receive. It cannot
# prove that a kernel/vendor combination will boot on an unknown phone, but it
# rejects corrupt, incomplete, or internally inconsistent packages.
#
# Usage: verify_samsung_package.sh <output-dir> [output-name]
# ============================================================================

set -Eeuo pipefail

OUTPUT_DIR="${1:-}"
OUTPUT_NAME="${2:-}"
ROOT_DIR="$(dirname "$(dirname "$(realpath "$0")")")"

if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
  echo "[-] ERROR: Output directory was not found: ${OUTPUT_DIR:-<empty>}" >&2
  exit 2
fi

for command_name in file lz4 od tar md5sum stat python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[-] ERROR: Required verifier command is missing: $command_name" >&2
    exit 1
  }
done

SUPER_LZ4="$OUTPUT_DIR/super.img.lz4"
SUPER_RAW="$OUTPUT_DIR/super.img"
if [ ! -s "$SUPER_LZ4" ] || [ ! -s "$SUPER_RAW" ]; then
  echo "[-] ERROR: Final Samsung super.img and super.img.lz4 are required." >&2
  exit 1
fi

LZ4_MAGIC=$(od -An -tx1 -N5 "$SUPER_LZ4" | tr -d '[:space:]')
if [ "$LZ4_MAGIC" != "04224d186c" ]; then
  echo "[-] ERROR: super.img.lz4 is not a Samsung content-size LZ4 frame." >&2
  exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/samsung-verify.XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT

lz4 -dc -- "$SUPER_LZ4" > "$TEMP_DIR/super.img"
mkdir -p "$TEMP_DIR/super-unpacked"
python3 "$ROOT_DIR/tools/lpunpack.py" \
  "$TEMP_DIR/super.img" "$TEMP_DIR/super-unpacked" >/dev/null

SYSTEM_IMAGE="$TEMP_DIR/super-unpacked/system.img"
if [ ! -s "$SYSTEM_IMAGE" ]; then
  echo "[-] ERROR: Final super image has no logical system.img." >&2
  exit 1
fi

SYSTEM_EXT4_MAGIC=$(dd if="$SYSTEM_IMAGE" bs=1 skip=1080 count=2 status=none 2>/dev/null \
  | od -An -tx1 | tr -d '[:space:]')
SYSTEM_EROFS_MAGIC=$(dd if="$SYSTEM_IMAGE" bs=1 skip=1024 count=4 status=none 2>/dev/null \
  | od -An -tx1 | tr -d '[:space:]')
SYSTEM_TYPE=$(file -b "$SYSTEM_IMAGE" | tr '[:upper:]' '[:lower:]')
if [ "$SYSTEM_EXT4_MAGIC" != "53ef" ] \
  && [ "$SYSTEM_EROFS_MAGIC" != "e2e1f5e0" ] \
  && ! printf '%s' "$SYSTEM_TYPE" | grep -Eq 'ext[234] filesystem|erofs'; then
  echo "[-] ERROR: Final logical system.img is not ext4/EROFS: $SYSTEM_TYPE" >&2
  exit 1
fi

check_vbmeta() {
  local path="$1"
  local name
  name=$(basename "$path")
  lz4 -dc -- "$path" > "$TEMP_DIR/$name.raw"
  python3 - "$TEMP_DIR/$name.raw" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if len(data) < 124 or data[:4] != b"AVB0":
    raise SystemExit(f"{path.name}: invalid AVB0 header")
flags = struct.unpack_from(">I", data, 120)[0]
if (flags & 0x03) != 0x03:
    raise SystemExit(f"{path.name}: AVB flags do not include 0x03 (got 0x{flags:08x})")
PY
}

ODIN_TAR=""
if [ -n "$OUTPUT_NAME" ] && [ -f "$OUTPUT_DIR/${OUTPUT_NAME}-odin.tar" ]; then
  ODIN_TAR="$OUTPUT_DIR/${OUTPUT_NAME}-odin.tar"
else
  ODIN_TAR=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*-odin.tar' -print -quit)
fi

if [ -n "$ODIN_TAR" ]; then
  mapfile -t MEMBERS < <(tar -tf "$ODIN_TAR")
  has_member() {
    local wanted="$1"
    printf '%s\n' "${MEMBERS[@]}" | grep -Fxq "$wanted"
  }

  for required in super.img.lz4 vbmeta.img.lz4 boot.img.lz4; do
    if ! has_member "$required"; then
      echo "[-] ERROR: Odin tar is missing required member: $required" >&2
      exit 1
    fi
  done

  for member in vbmeta.img.lz4 vbmeta_system.img.lz4 vbmeta_vendor.img.lz4; do
    if has_member "$member"; then
      tar -xOf "$ODIN_TAR" "$member" > "$TEMP_DIR/$member"
      check_vbmeta "$TEMP_DIR/$member"
    fi
  done

  tar -xOf "$ODIN_TAR" boot.img.lz4 > "$TEMP_DIR/boot.img.lz4"
  lz4 -dc -- "$TEMP_DIR/boot.img.lz4" > "$TEMP_DIR/boot.img"
  BOOT_MAGIC=$(od -An -tc -N8 "$TEMP_DIR/boot.img" | tr -d '[:space:]')
  if [ "$BOOT_MAGIC" != "ANDROID!" ]; then
    echo "[-] ERROR: Odin boot.img.lz4 does not contain an Android boot image." >&2
    exit 1
  fi

  # Preserve-and-verify the remaining AP boot-chain members. They are opaque
  # to this tool, but their Samsung LZ4 frames must be intact before Odin sees
  # the package.
  for member in dtbo.img.lz4 vendor_boot.img.lz4 init_boot.img.lz4 recovery.img.lz4; do
    if has_member "$member"; then
      tar -xOf "$ODIN_TAR" "$member" > "$TEMP_DIR/$member"
      AUX_MAGIC=$(od -An -tx1 -N5 "$TEMP_DIR/$member" | tr -d '[:space:]')
      if [ "$AUX_MAGIC" != "04224d186c" ]; then
        echo "[-] ERROR: Odin auxiliary member is not a Samsung content-size LZ4 frame: $member" >&2
        exit 1
      fi
      lz4 -t -- "$TEMP_DIR/$member" >/dev/null
    fi
  done
  ODIN_MD5_TAR="${ODIN_TAR}.md5"
  if [ ! -s "$ODIN_MD5_TAR" ]; then
    echo "[-] ERROR: Odin tar is missing its .tar.md5 companion." >&2
    exit 1
  fi
  MD5_SIZE=$(stat -c '%s' "$ODIN_MD5_TAR")
  if [ "$MD5_SIZE" -le 32 ]; then
    echo "[-] ERROR: Odin .tar.md5 file is too small." >&2
    exit 1
  fi
  PAYLOAD_SIZE=$((MD5_SIZE - 32))
  dd if="$ODIN_MD5_TAR" of="$TEMP_DIR/odin-md5.payload" \
    bs=1 count="$PAYLOAD_SIZE" status=none
  EXPECTED_MD5=$(tail -c 32 "$ODIN_MD5_TAR")
  ACTUAL_MD5=$(md5sum "$TEMP_DIR/odin-md5.payload" | cut -d' ' -f1)
  if [ "$EXPECTED_MD5" != "$ACTUAL_MD5" ]; then
    echo "[-] ERROR: Odin .tar.md5 digest mismatch." >&2
    exit 1
  fi
  echo "==> Samsung Odin tar verified: $(basename "$ODIN_TAR")"
else
  echo "==> No Odin tar present; verified standalone super artifacts only."
fi

echo "==> Samsung package verification passed: system filesystem and containers are valid."
