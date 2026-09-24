#!/usr/bin/env bash
# ==============================================================================
# repack_gsi.sh - Pack patched system directory back into a flashable GSI image
# Supports EXT4 and EROFS output formats with sparse image conversion & compression
# ==============================================================================

set -eo pipefail

SYSTEM_ROOT="${1:-}"
REQUESTED_OUTPUT_NAME="${2:-system-treble-arm64}"
FS_TYPE="${3:-ext4}"
WORK_DIR="$(pwd)/workspace"
OUTPUT_DIR="$WORK_DIR/output"

OUTPUT_NAME=$(printf '%s' "$REQUESTED_OUTPUT_NAME" \
  | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[.-]+//; s/[.-]+$//')
[ -n "$OUTPUT_NAME" ] || OUTPUT_NAME="system-treble-arm64"

mkdir -p "$OUTPUT_DIR"

if [ -z "$SYSTEM_ROOT" ] || [ ! -d "$SYSTEM_ROOT" ]; then
  echo "[-] ERROR: Valid SYSTEM_ROOT directory path is required."
  echo "Usage: ./repack_gsi.sh <SYSTEM_ROOT> [OUTPUT_NAME] [FS_TYPE: ext4|erofs]"
  exit 1
fi

RAW_IMG="$OUTPUT_DIR/${OUTPUT_NAME}.raw.img"
SPARSE_IMG="$OUTPUT_DIR/${OUTPUT_NAME}.img"
COMPRESSED_IMG="$OUTPUT_DIR/${OUTPUT_NAME}.img.xz"
DSU_IMG="$OUTPUT_DIR/${OUTPUT_NAME}.img.gz"

echo "==> [REPACK] Source directory: $SYSTEM_ROOT"
echo "==> [REPACK] Target format: $FS_TYPE"

if [ "$FS_TYPE" = "erofs" ]; then
  echo "==> [REPACK] Building EROFS image with mkfs.erofs..."
  mkfs.erofs -z lz4hc "$SPARSE_IMG" "$SYSTEM_ROOT"
  # No sparse conversion needed for EROFS
else
  echo "==> [REPACK] Calculating partition size..."
  DIR_SIZE_BYTES=$(sudo du -sb "$SYSTEM_ROOT" | cut -f1)
  # Add 128MB buffer (increased from 75MB for safety with larger GSIs)
  BUFFER_BYTES=$((128 * 1024 * 1024))
  TOTAL_SIZE_BYTES=$((DIR_SIZE_BYTES + BUFFER_BYTES))
  # Align to 4K block size
  TOTAL_SIZE_BYTES=$(( ((TOTAL_SIZE_BYTES + 4095) / 4096) * 4096 ))

  echo "  -> System size: $((DIR_SIZE_BYTES / 1024 / 1024)) MB"
  echo "  -> Target image size with buffer: $((TOTAL_SIZE_BYTES / 1024 / 1024)) MB"

  echo "==> [REPACK] Creating raw blank image..."
  rm -f "$RAW_IMG"
  truncate -s "$TOTAL_SIZE_BYTES" "$RAW_IMG"

  echo "==> [REPACK] Formatting ext4 filesystem..."
  # BUG FIX: -O ^has_journal,^dir_index should use separate -O flags for clarity
  mke2fs -t ext4 -b 4096 -F \
    -O ^has_journal \
    -O ^dir_index \
    -L "system" "$RAW_IMG"

  MNT_POINT="$WORK_DIR/mnt_repack"
  sudo mkdir -p "$MNT_POINT"

  echo "==> [REPACK] Copying files to new filesystem..."
  sudo mount -o loop "$RAW_IMG" "$MNT_POINT"
  # BUG FIX: use trailing /. to copy directory contents, not the directory itself
  sudo cp -a "$SYSTEM_ROOT"/. "$MNT_POINT/" || { sudo umount "$MNT_POINT"; false; }
  sudo umount "$MNT_POINT"

  # Shrink image to minimum size to save space
  echo "==> [REPACK] Optimizing filesystem size..."
  e2fsck -fy "$RAW_IMG" || true
  resize2fs -M "$RAW_IMG" || true

  echo "==> [REPACK] Converting to Android Sparse Image (img2simg)..."
  if command -v img2simg &>/dev/null; then
    img2simg "$RAW_IMG" "$SPARSE_IMG"
    rm -f "$RAW_IMG"
  else
    mv "$RAW_IMG" "$SPARSE_IMG"
  fi
fi

echo "==> [REPACK] Compressing final GSI with XZ (high compression)..."
# Keep the sparse image long enough to create both release formats.  DSU
# Sideloader accepts XZ, but GZIP is also supported by Android's DSU path and
# is more compatible with older Samsung gsid implementations.
gzip -9 -c "$SPARSE_IMG" > "$DSU_IMG"
xz -9 -T0 -f "$SPARSE_IMG"
# After xz without -k, the source .img is replaced by .img.xz.
COMPRESSED_IMG="${SPARSE_IMG}.xz"

echo "================================================================="
echo "==> [REPACK] GSI BUILT SUCCESSFULLY!"
echo "  Compressed path: $COMPRESSED_IMG"
echo "  DSU path:        $DSU_IMG"
echo "  Final Size:      $(du -h "$COMPRESSED_IMG" | cut -f1)"
echo "================================================================="
