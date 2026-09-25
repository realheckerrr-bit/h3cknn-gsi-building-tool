#!/usr/bin/env bash
# Extract only build.prop from a direct GSI for compatibility reporting.
#
# Returns 0 when an ext4 GSI property file was extracted, and 1 when the image
# is not an ext4 GSI or does not contain a known build.prop path. Callers can
# then fall back to the normal full extractor (for example for EROFS).

set -Eeuo pipefail

INPUT_FILE="${1:-}"
OUTPUT_ROOT="${2:-}"
WORK_DIR="${3:-$(pwd)}"

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_ROOT" ] || [ ! -f "$INPUT_FILE" ]; then
  echo "Usage: extract_direct_gsi_prop.sh <gsi.img|img.xz|img.gz> <output-root> [work-dir]" >&2
  exit 2
fi

RAW_IMAGE="$WORK_DIR/.direct-gsi.raw.img"
UNSPARSE_IMAGE="$WORK_DIR/.direct-gsi.unsparse.img"
cleanup() {
  rm -f -- "$RAW_IMAGE" "$UNSPARSE_IMAGE"
}
trap cleanup EXIT

FILE_TYPE=$(file -b "$INPUT_FILE" | tr '[:upper:]' '[:lower:]')
FILE_EXT="${INPUT_FILE##*.}"
FILE_EXT=$(printf '%s' "$FILE_EXT" | tr '[:upper:]' '[:lower:]')
FILE_MAGIC=$(od -An -tx1 -N6 "$INPUT_FILE" 2>/dev/null | tr -d '[:space:]')

case "$FILE_EXT" in
  xz) xz -dc -- "$INPUT_FILE" > "$RAW_IMAGE" ;;
  gz) gzip -dc -- "$INPUT_FILE" > "$RAW_IMAGE" ;;
  *)
    if printf '%s' "$FILE_TYPE" | grep -q 'xz compressed' || [ "${FILE_MAGIC:0:12}" = "fd377a585a00" ]; then
      xz -dc -- "$INPUT_FILE" > "$RAW_IMAGE"
    elif printf '%s' "$FILE_TYPE" | grep -q 'gzip compressed' || [ "${FILE_MAGIC:0:4}" = "1f8b" ]; then
      gzip -dc -- "$INPUT_FILE" > "$RAW_IMAGE"
    else
      cp -- "$INPUT_FILE" "$RAW_IMAGE"
    fi
    ;;
esac

if [ ! -s "$RAW_IMAGE" ]; then
  exit 1
fi

IMAGE_MAGIC=$(od -An -tx1 -N4 "$RAW_IMAGE" 2>/dev/null | tr -d '[:space:]')
if [ "$IMAGE_MAGIC" = "3aff26ed" ]; then
  command -v simg2img >/dev/null 2>&1 || exit 1
  simg2img "$RAW_IMAGE" "$UNSPARSE_IMAGE"
  DEBUGFS_IMAGE="$UNSPARSE_IMAGE"
else
  DEBUGFS_IMAGE="$RAW_IMAGE"
fi

RAW_TYPE=$(file -b "$DEBUGFS_IMAGE" | tr '[:upper:]' '[:lower:]')
printf '%s' "$RAW_TYPE" | grep -Eiq 'ext[234] filesystem' || exit 1

for PROP_PATH in /build.prop /system/build.prop /system/system/build.prop; do
  PROP_REL="${PROP_PATH#/}"
  PROP_FILE="$OUTPUT_ROOT/$PROP_REL"
  mkdir -p "$(dirname "$PROP_FILE")"
  if debugfs -R "dump -p $PROP_PATH $PROP_FILE" "$DEBUGFS_IMAGE" \
    >/dev/null 2>&1 && [ -s "$PROP_FILE" ]; then
    chmod 644 "$PROP_FILE"
    echo "==> [EXTRACT] Direct GSI preflight: extracted $PROP_PATH only"
    exit 0
  fi
  rm -f -- "$PROP_FILE"
done

exit 1
