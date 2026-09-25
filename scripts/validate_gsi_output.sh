#!/usr/bin/env bash
# ============================================================================
# validate_gsi_output.sh - Validate compressed GSI release assets
# ============================================================================

set -Eeuo pipefail

XZ_PATH="${1:-}"
GZ_PATH="${2:-}"

if [ -z "$XZ_PATH" ] || [ -z "$GZ_PATH" ] || [ ! -f "$XZ_PATH" ] || [ ! -f "$GZ_PATH" ]; then
  echo "[-] ERROR: Expected an existing .img.xz and .img.gz asset." >&2
  echo "Usage: validate_gsi_output.sh <image.img.xz> <image.img.gz>" >&2
  exit 1
fi

echo "==> [VALIDATE-GSI] Testing XZ stream: $(basename "$XZ_PATH")"
xz -t -- "$XZ_PATH"

echo "==> [VALIDATE-GSI] Testing GZIP stream: $(basename "$GZ_PATH")"
gzip -t -- "$GZ_PATH"

VALIDATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gsi-validate.XXXXXX")
RAW_IMAGE="$VALIDATE_DIR/system.raw.img"
trap 'rm -rf "$VALIDATE_DIR"' EXIT

# DSU consumes a raw, unsparsed image.  Materialize only the GZIP asset for
# validation; the XZ asset remains the flashing/passthrough representation.
gzip -dc -- "$GZ_PATH" > "$RAW_IMAGE"
if [ ! -s "$RAW_IMAGE" ]; then
  echo "[-] ERROR: GZIP asset decompressed to an empty image." >&2
  exit 1
fi

SPARSE_MAGIC=$(od -An -tx1 -N4 "$RAW_IMAGE" 2>/dev/null | tr -d '[:space:]')
if [ "$SPARSE_MAGIC" = "3aff26ed" ]; then
  echo "[-] ERROR: DSU GZIP asset is still an Android sparse image; expected raw." >&2
  exit 1
fi

EXT4_MAGIC=$(dd if="$RAW_IMAGE" bs=1 skip=1080 count=2 status=none 2>/dev/null \
  | od -An -tx1 | tr -d '[:space:]')
EROFS_MAGIC=$(dd if="$RAW_IMAGE" bs=1 skip=1024 count=4 status=none 2>/dev/null \
  | od -An -tx1 | tr -d '[:space:]')
IMAGE_TYPE=$(file -b "$RAW_IMAGE" | tr '[:upper:]' '[:lower:]')
IMAGE_KIND=""

if [ "$EXT4_MAGIC" = "53ef" ]; then
  IMAGE_KIND="ext4"
  echo "==> [VALIDATE-GSI] Raw filesystem: ext4"
elif [ "$EROFS_MAGIC" = "e2e1f5e0" ]; then
  IMAGE_KIND="erofs"
  echo "==> [VALIDATE-GSI] Raw filesystem: erofs"
elif printf '%s' "$IMAGE_TYPE" | grep -Eiq 'ext[234] filesystem'; then
  IMAGE_KIND="ext4"
  echo "==> [VALIDATE-GSI] Raw filesystem: $IMAGE_TYPE"
elif printf '%s' "$IMAGE_TYPE" | grep -Eiq 'erofs'; then
  IMAGE_KIND="erofs"
  echo "==> [VALIDATE-GSI] Raw filesystem: $IMAGE_TYPE"
else
  echo "[-] ERROR: GZIP asset is not a recognized raw ext4/EROFS GSI." >&2
  echo "    Detected: $IMAGE_TYPE" >&2
  exit 1
fi

# A filesystem with the right magic is not necessarily bootable.  Verify the
# small system-image contract that is independent of the target device's
# kernel/vendor boot chain: a build.prop, a second-stage init, and a Treble
# marker.  This catches truncated or incorrectly-rooted repacks before they
# are published.  The target still supplies the first-stage ramdisk, vendor
# HALs, kernel, DTB, and AVB chain.
CONTRACT_DIR="$VALIDATE_DIR/contract"
mkdir -p "$CONTRACT_DIR"

has_file() {
  local path="$1"
  case "$IMAGE_KIND" in
    ext4)
      debugfs -R "stat $path" "$RAW_IMAGE" 2>/dev/null \
        | grep -q '^Inode:'
      ;;
    erofs)
      [ -e "$CONTRACT_DIR/${path#/}" ]
      ;;
    *)
      return 1
      ;;
  esac
}

dump_file() {
  local path="$1"
  local destination="$2"
  case "$IMAGE_KIND" in
    ext4)
      debugfs -R "dump -p $path $destination" "$RAW_IMAGE" \
        >/dev/null 2>&1
      ;;
    erofs)
      cp -- "$CONTRACT_DIR/${path#/}" "$destination"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ "$IMAGE_KIND" = "ext4" ]; then
  BUILD_PROP_PATH=""
  for candidate in /build.prop /system/build.prop /system/system/build.prop; do
    if has_file "$candidate"; then
      BUILD_PROP_PATH="$candidate"
      break
    fi
  done
  if [ -z "$BUILD_PROP_PATH" ]; then
    echo "[-] ERROR: GSI does not contain build.prop at a supported system path." >&2
    exit 1
  fi
  dump_file "$BUILD_PROP_PATH" "$CONTRACT_DIR/build.prop"
elif [ "$IMAGE_KIND" = "erofs" ]; then
  if ! command -v fsck.erofs >/dev/null 2>&1; then
    echo "[-] ERROR: fsck.erofs is required to inspect an EROFS GSI contract." >&2
    exit 1
  fi
  fsck.erofs --extract="$CONTRACT_DIR" "$RAW_IMAGE" >/dev/null
  BUILD_PROP_PATH=""
  for candidate in build.prop system/build.prop system/system/build.prop; do
    if [ -f "$CONTRACT_DIR/$candidate" ]; then
      BUILD_PROP_PATH="$candidate"
      break
    fi
  done
  if [ -z "$BUILD_PROP_PATH" ]; then
    echo "[-] ERROR: EROFS GSI does not contain build.prop at a supported system path." >&2
    exit 1
  fi
  cp -- "$CONTRACT_DIR/$BUILD_PROP_PATH" "$CONTRACT_DIR/build.prop"
fi

if ! grep -Eq '^[[:space:]]*ro\.treble\.enabled=(true|1)[[:space:]]*$' \
  "$CONTRACT_DIR/build.prop"; then
  echo "[-] ERROR: GSI build.prop does not enable Project Treble." >&2
  exit 1
fi

SDK_VALUE=$(awk -F= '$1 == "ro.build.version.sdk" { print $2; exit }' \
  "$CONTRACT_DIR/build.prop" | tr -d '[:space:]')
if ! [[ "$SDK_VALUE" =~ ^[0-9]+$ ]] || [ "$SDK_VALUE" -lt 29 ]; then
  echo "[-] ERROR: GSI build.prop has no supported Android SDK (found: ${SDK_VALUE:-missing})." >&2
  exit 1
fi

INIT_FOUND=0
for candidate in /init /bin/init /system/bin/init /system/system/bin/init; do
  if has_file "$candidate"; then
    INIT_FOUND=1
    break
  fi
done
if [ "$INIT_FOUND" != "1" ]; then
  echo "[-] ERROR: GSI does not contain a second-stage init binary." >&2
  exit 1
fi

SELINUX_FOUND=0
for candidate in /etc/selinux /system/etc/selinux /system/system/etc/selinux; do
  if has_file "$candidate"; then
    SELINUX_FOUND=1
    break
  fi
done
if [ "$SELINUX_FOUND" != "1" ]; then
  echo "[!] WARNING: GSI has no system SELinux directory; vendor/system policy compatibility must be checked manually." >&2
fi

echo "==> [VALIDATE-GSI] Android boot contract: build.prop, Treble, SDK, and init verified."

echo "==> [VALIDATE-GSI] Release image validation passed."
