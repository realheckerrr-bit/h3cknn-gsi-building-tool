#!/usr/bin/env bash
# ==============================================================================
# port_rom.sh - Master pipeline for OEM ROM -> Treble GSI porting
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
VERSION_FILE="$SCRIPT_DIR/../VERSION"
TOOL_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0.1")"
ROM_URL="${1:-}"
REQUESTED_OUTPUT_NAME="${2:-GSI_Treble_ARM64}"
ROM_TYPE="${3:-generic}"
FS_TYPE="${4:-ext4}"
WORK_DIR="$(pwd)/workspace"

# Workflow names are also used as filesystem names.  Keep the display name in
# GitHub metadata, but never allow slashes, traversal, or shell-hostile
# punctuation to create a path outside workspace/output.
OUTPUT_NAME=$(printf '%s' "$REQUESTED_OUTPUT_NAME" \
  | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[.-]+//; s/[.-]+$//')
[ -n "$OUTPUT_NAME" ] || OUTPUT_NAME="GSI_Treble_ARM64"

if [ -z "$ROM_URL" ]; then
  echo "=========================================================="
  echo "Project Treble GSI Porting Engine"
  echo "=========================================================="
  echo "Usage: ./port_rom.sh <ROM_URL> [OUTPUT_NAME] [ROM_TYPE] [FS_TYPE]"
  echo ""
  echo "Parameters:"
  echo "  ROM_URL     : Direct download link to ROM (zip/bin/tar/img)"
  echo "  OUTPUT_NAME : Name for output GSI image (default: GSI_Treble_ARM64)"
  echo "  ROM_TYPE    : OEM profile (generic, pixel, hyperos, oneui, oxygenos)"
  echo "  FS_TYPE     : Output filesystem (ext4 or erofs)"
  echo "=========================================================="
  exit 1
fi

echo "=========================================================="
echo "Starting Project Treble GSI Porting Pipeline"
echo " Tool Version: $TOOL_VERSION"
echo " ROM URL:     $ROM_URL"
echo " Output Name: $OUTPUT_NAME"
if [ "$REQUESTED_OUTPUT_NAME" != "$OUTPUT_NAME" ]; then
  echo " Requested Name: $REQUESTED_OUTPUT_NAME"
fi
echo " Profile:     $ROM_TYPE"
echo " Filesystem:  $FS_TYPE"
echo "=========================================================="

# 1. Setup dependencies. Workflows install these in a dedicated step first;
# avoid repeating apt/pip work when that step sets SKIP_SETUP_DEPS=1.
if [ "${SKIP_SETUP_DEPS:-0}" = "1" ]; then
  echo "==> [SETUP] Dependencies already installed; skipping duplicate setup."
else
  bash "$SCRIPT_DIR/setup_deps.sh"
fi

# 2. Extract ROM
bash "$SCRIPT_DIR/extract_rom.sh" "$ROM_URL" "$WORK_DIR"

SYSTEM_ROOT="$WORK_DIR/system_root"

# 3. Direct GSI inputs already contain a Treble-compatible system image.
# Rebuilding those images can change sparse layout, filesystem metadata, or
# filesystem features that the original GSI relies on.  Detect the common
# direct-GSI markers and preserve the image byte layout instead.
SOURCE_INPUT=""
if [ -f "$WORK_DIR/source-input.path" ]; then
  SOURCE_INPUT=$(head -n 1 "$WORK_DIR/source-input.path")
fi

BUILD_PROP=""
for candidate in \
  "$SYSTEM_ROOT/system/build.prop" \
  "$SYSTEM_ROOT/system/system/build.prop" \
  "$SYSTEM_ROOT/build.prop"; do
  if [ -f "$candidate" ]; then
    BUILD_PROP="$candidate"
    break
  fi
done

IS_EXISTING_GSI=0
if [ "${FORCE_REPACK_GSI:-0}" != "1" ] && [ -n "$SOURCE_INPUT" ]; then
  SOURCE_BASENAME=$(basename "$SOURCE_INPUT" | tr '[:upper:]' '[:lower:]')
  # Some community GSIs do not carry ro.treble.enabled in the extracted
  # build.prop even though their filename/variant is unambiguous.  Require a
  # direct image input plus either a generic device marker or a recognized GSI
  # variant marker; do not rely on one property alone.  The filename/URL test
  # remains independent of BUILD_PROP: metadata permissions or an unusual
  # system-as-root layout must never force a known GSI through the destructive
  # OEM unpack/repack path.
  if { [ -f "$BUILD_PROP" ] && grep -Eiq '^ro\.product\.(system\.)?device=(generic|mainline|gsi)' "$BUILD_PROP"; } \
    || printf '%s\n%s' "$SOURCE_BASENAME" "$ROM_URL" | grep -Eiq '(^|[-_/?.])(gsi|treble|arm64_[ab][a-z][a-z]?n)([-_.?/]|$)'; then
    IS_EXISTING_GSI=1
  fi
fi

if [ "$IS_EXISTING_GSI" = "1" ]; then
  echo "==> [PORT] Existing Treble GSI detected; preserving source image layout."
  bash "$SCRIPT_DIR/preserve_gsi.sh" "$SOURCE_INPUT" "$OUTPUT_NAME" "$WORK_DIR"
  printf '%s\n' "preserved-existing-gsi" > "$WORK_DIR/image-mode.txt"
  echo "==> GSI Build pipeline completed successfully (passthrough mode)."
  exit 0
fi

# 4. Patch Treble
bash "$SCRIPT_DIR/patch_treble.sh" "$SYSTEM_ROOT" "$ROM_TYPE"

# 5. Repack into GSI
bash "$SCRIPT_DIR/repack_gsi.sh" "$SYSTEM_ROOT" "$OUTPUT_NAME" "$FS_TYPE"
printf '%s\n' "rebuilt-$FS_TYPE" > "$WORK_DIR/image-mode.txt"

echo "==> GSI Build pipeline completed successfully."
