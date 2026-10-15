#!/usr/bin/env bash
# Run the pinned MysticGSI upstream porting engine and publish the same
# compressed artifact pair used by this repository's existing workflows.

set -Eeuo pipefail

ROM_SOURCE="${1:-}"
OUTPUT_NAME="${2:-MysticGSI}"
ROM_TYPE="${3:-auto}"
TARGET_MODEL="${4:-generic}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MYSTIC_DIR="$ROOT_DIR/mysticgsi"
OUTPUT_DIR="$ROOT_DIR/workspace/output"

if [ -z "$ROM_SOURCE" ]; then
  echo "Usage: build_mysticgsi.sh <firmware-url-or-path> [output-name] [rom-type] [target-model]" >&2
  exit 2
fi
if [ ! -f "$MYSTIC_DIR/cli.py" ]; then
  echo "[-] MysticGSI submodule is missing. Check out with submodules enabled." >&2
  exit 2
fi
if [[ ! "$OUTPUT_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "[-] Output name must contain only letters, numbers, dot, dash, or underscore (max 64 chars)." >&2
  exit 2
fi

PYTHON_BIN="${MYSTIC_PYTHON:-python3}"
if [ -x "$MYSTIC_DIR/.venv/bin/python" ]; then
  PYTHON_BIN="$MYSTIC_DIR/.venv/bin/python"
fi

mkdir -p "$OUTPUT_DIR"
rm -f -- "$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.img.xz "$OUTPUT_DIR"/*.img.gz \
  "$OUTPUT_DIR"/build-info.txt "$OUTPUT_DIR"/compatibility-report.txt

echo "==> [MYSTICGSI] Building $OUTPUT_NAME with the upstream engine"
(
  cd "$MYSTIC_DIR"
  "$PYTHON_BIN" cli.py build "$OUTPUT_NAME" "$ROM_SOURCE" --type "$ROM_TYPE"
)

MYSTIC_OUTPUT_DIR="$MYSTIC_DIR/out/$OUTPUT_NAME"
if [ ! -d "$MYSTIC_OUTPUT_DIR" ]; then
  echo "[-] MysticGSI did not create $MYSTIC_OUTPUT_DIR" >&2
  exit 1
fi

shopt -s nullglob
IMAGES=("$MYSTIC_OUTPUT_DIR"/*.img)
shopt -u nullglob
if [ "${#IMAGES[@]}" -eq 0 ]; then
  echo "[-] MysticGSI produced no partition image." >&2
  exit 1
fi

for image in "${IMAGES[@]}"; do
  image_name="$(basename "$image")"
  output_image="$OUTPUT_DIR/$image_name"
  cp -- "$image" "$output_image"
  xz -9 -T0 -k -f -- "$output_image"
  gzip -9 -c -- "$output_image" > "$output_image.gz"
done

BUILD_PROP=""
if [ -d "$MYSTIC_DIR/tmp/$OUTPUT_NAME/images/system" ]; then
  BUILD_PROP=$(find "$MYSTIC_DIR/tmp/$OUTPUT_NAME/images/system" -type f \
    -name build.prop -print -quit)
fi
if [ -n "$BUILD_PROP" ]; then
  bash "$ROOT_DIR/scripts/check_gsi_compatibility.sh" \
    "$BUILD_PROP" "$TARGET_MODEL" "$OUTPUT_DIR/compatibility-report.txt" auto
else
  printf '%s\n' \
    'Status: WARN' \
    'MysticGSI did not expose a build.prop tree for the compatibility preflight.' \
    'Inspect the generated image and target vendor manually.' \
    > "$OUTPUT_DIR/compatibility-report.txt"
fi

{
  printf '%s\n' 'MysticGSI build report' '====================='
  printf 'Engine: MysticGSI submodule (%s)\n' "$(git -C "$MYSTIC_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  printf 'Source: %s\n' "$ROM_SOURCE"
  printf 'ROM type: %s\n' "$ROM_TYPE"
  printf 'Target model: %s\n' "$TARGET_MODEL"
  printf 'Image mode: MysticGSI upstream firmware port\n'
  printf 'DSU signing: Community GSI; not signed with a Samsung/Google OEM key\n'
  printf '\nUpstream build details:\n'
  if [ -f "$MYSTIC_OUTPUT_DIR/output.txt" ]; then
    cat "$MYSTIC_OUTPUT_DIR/output.txt"
  fi
  printf '\nCompatibility preflight:\n'
  cat "$OUTPUT_DIR/compatibility-report.txt"
} > "$OUTPUT_DIR/build-info.txt"

echo "==> [MYSTICGSI] Published artifacts in $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
