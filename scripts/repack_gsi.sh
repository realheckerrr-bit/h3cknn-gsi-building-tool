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

case "$FS_TYPE" in
  ext4|erofs) ;;
  *)
    echo "[-] ERROR: Filesystem must be exactly ext4 or erofs (got: $FS_TYPE)." >&2
    exit 2
    ;;
esac

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
  # Ubuntu/Debian erofs-utils versions expose either lz4hc or only lz4.
  # Retry with the portable compressor instead of leaving a partial image
  # behind when a runner has an older userspace tool.
  rm -f -- "$SPARSE_IMG"
  if ! mkfs.erofs -z lz4hc "$SPARSE_IMG" "$SYSTEM_ROOT"; then
    echo "  [!] lz4hc is unavailable; retrying EROFS build with lz4"
    rm -f -- "$SPARSE_IMG"
    mkfs.erofs -z lz4 "$SPARSE_IMG" "$SYSTEM_ROOT"
  fi
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

  # e2fsdroid is the Android image-population tool used by AOSP.  It writes
  # ownership, modes, symlinks, capabilities, and (when a text file_contexts
  # file is available) SELinux labels directly into the filesystem.  A plain
  # mounted `cp -a` can silently lose those details and produce an image that
  # passes a filesystem check but bootloops at init/zygote.
  if command -v e2fsdroid >/dev/null 2>&1; then
    echo "==> [REPACK] Populating ext4 with Android e2fsdroid metadata..."
    FILE_CONTEXTS=""
    while IFS= read -r candidate; do
      if file -b "$candidate" 2>/dev/null | grep -Eiq 'text|ascii'; then
        FILE_CONTEXTS="$candidate"
        break
      fi
    done < <(find "$SYSTEM_ROOT" -type f \( \
      -name 'file_contexts' -o \
      -name 'plat_file_contexts' -o \
      -name 'vendor_file_contexts' \
    \) -print 2>/dev/null | sort)

    E2FSDROID_ARGS=(-e -f "$SYSTEM_ROOT" -a /system)
    if [ -n "$FILE_CONTEXTS" ]; then
      echo "  -> SELinux file contexts: $FILE_CONTEXTS"
      E2FSDROID_ARGS+=(-S "$FILE_CONTEXTS")
    else
      echo "  [!] No text file_contexts found; preserving source metadata without relabeling"
    fi
    e2fsdroid "${E2FSDROID_ARGS[@]}" "$RAW_IMG"
  else
    echo "  [!] e2fsdroid unavailable; using mounted cp fallback"
    MNT_POINT="$WORK_DIR/mnt_repack"
    sudo mkdir -p "$MNT_POINT"
    cleanup_mount() {
      if mountpoint -q "$MNT_POINT" 2>/dev/null; then
        sudo umount "$MNT_POINT"
      fi
    }
    trap cleanup_mount EXIT
    echo "==> [REPACK] Copying files to new filesystem..."
    sudo mount -o loop "$RAW_IMG" "$MNT_POINT"
    # Use trailing /. to copy directory contents, not the directory itself.
    sudo cp -a "$SYSTEM_ROOT"/. "$MNT_POINT/"
    cleanup_mount
    trap - EXIT
  fi

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
# Keep the sparse image for the XZ flashing asset.  DSU consumes a raw,
# unsparsed filesystem image, so expand only the separate GZIP asset.
DSU_SOURCE="$SPARSE_IMG"
DSU_RAW_IMG="$OUTPUT_DIR/.${OUTPUT_NAME}.dsu.raw.img"
cleanup_dsu_raw() {
  rm -f -- "$DSU_RAW_IMG"
}
trap cleanup_dsu_raw EXIT

IMAGE_MAGIC=$(od -An -tx1 -N4 "$SPARSE_IMG" 2>/dev/null | tr -d '[:space:]')
if [ "$IMAGE_MAGIC" = "3aff26ed" ]; then
  if ! command -v simg2img >/dev/null 2>&1; then
    echo "[-] ERROR: Sparse GSI created, but simg2img is unavailable for the DSU asset." >&2
    exit 1
  fi
  echo "==> [REPACK] Expanding sparse image for the DSU GZIP asset..."
  simg2img "$SPARSE_IMG" "$DSU_RAW_IMG"
  DSU_SOURCE="$DSU_RAW_IMG"
fi

gzip -9 -c "$DSU_SOURCE" > "$DSU_IMG"
xz -9 -T0 -f "$SPARSE_IMG"
# After xz without -k, the source .img is replaced by .img.xz.
COMPRESSED_IMG="${SPARSE_IMG}.xz"

echo "================================================================="
echo "==> [REPACK] GSI BUILT SUCCESSFULLY!"
echo "  Compressed path: $COMPRESSED_IMG"
echo "  DSU path:        $DSU_IMG"
echo "  Final Size:      $(du -h "$COMPRESSED_IMG" | cut -f1)"
echo "================================================================="
