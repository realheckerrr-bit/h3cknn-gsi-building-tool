#!/usr/bin/env bash
# ============================================================================
# preserve_gsi.sh - Rewrap an existing GSI without changing its filesystem
# ============================================================================

set -Eeuo pipefail

INPUT_FILE="${1:-}"
REQUESTED_OUTPUT_NAME="${2:-system-treble-arm64}"
WORK_DIR="${3:-$(pwd)/workspace}"
OUTPUT_DIR="$WORK_DIR/output"

OUTPUT_NAME=$(printf '%s' "$REQUESTED_OUTPUT_NAME" \
  | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[.-]+//; s/[.-]+$//')
[ -n "$OUTPUT_NAME" ] || OUTPUT_NAME="system-treble-arm64"

if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
  echo "[-] ERROR: Existing GSI input file was not found: $INPUT_FILE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
TMP_IMG="$OUTPUT_DIR/.${OUTPUT_NAME}.preserve.img"
trap 'rm -f "$TMP_IMG"' EXIT

FILE_TYPE=$(file -b "$INPUT_FILE" | tr '[:upper:]' '[:lower:]')
FILE_EXT="${INPUT_FILE##*.}"
FILE_EXT=$(printf '%s' "$FILE_EXT" | tr '[:upper:]' '[:lower:]')

echo "==> [PRESERVE-GSI] Input: $(basename "$INPUT_FILE")"
echo "==> [PRESERVE-GSI] Keeping the original filesystem/image layout"

case "$FILE_EXT" in
  xz)
    xz -dc "$INPUT_FILE" > "$TMP_IMG"
    ;;
  gz)
    gzip -dc "$INPUT_FILE" > "$TMP_IMG"
    ;;
  img)
    cp -- "$INPUT_FILE" "$TMP_IMG"
    ;;
  *)
    echo "[-] ERROR: Existing GSI must be .img, .img.xz, or .img.gz (detected: $FILE_TYPE)" >&2
    exit 1
    ;;
esac

if [ ! -s "$TMP_IMG" ]; then
  echo "[-] ERROR: Decompressed GSI image is empty." >&2
  exit 1
fi

# Keep an existing XZ byte-for-byte when possible.  For all other inputs,
# recompress only the image stream; no filesystem contents are mounted or
# modified.
if [ "$FILE_EXT" = "xz" ]; then
  cp -- "$INPUT_FILE" "$OUTPUT_DIR/${OUTPUT_NAME}.img.xz"
else
  xz -9 -T0 -c "$TMP_IMG" > "$OUTPUT_DIR/${OUTPUT_NAME}.img.xz"
fi

gzip -9 -c "$TMP_IMG" > "$OUTPUT_DIR/${OUTPUT_NAME}.img.gz"

echo "================================================================="
echo "==> [PRESERVE-GSI] GSI REWRAPPED SUCCESSFULLY!"
echo "  XZ path:   $OUTPUT_DIR/${OUTPUT_NAME}.img.xz"
echo "  GZIP path: $OUTPUT_DIR/${OUTPUT_NAME}.img.gz"
echo "================================================================="
