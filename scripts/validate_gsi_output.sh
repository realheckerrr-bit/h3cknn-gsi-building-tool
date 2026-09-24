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

if [ "$EXT4_MAGIC" = "53ef" ]; then
  echo "==> [VALIDATE-GSI] Raw filesystem: ext4"
elif [ "$EROFS_MAGIC" = "e2e1f5e0" ]; then
  echo "==> [VALIDATE-GSI] Raw filesystem: erofs"
elif printf '%s' "$IMAGE_TYPE" | grep -Eq 'ext[234] filesystem|erofs'; then
  echo "==> [VALIDATE-GSI] Raw filesystem: $IMAGE_TYPE"
else
  echo "[-] ERROR: GZIP asset is not a recognized raw ext4/EROFS GSI." >&2
  echo "    Detected: $IMAGE_TYPE" >&2
  exit 1
fi

echo "==> [VALIDATE-GSI] Release image validation passed."
