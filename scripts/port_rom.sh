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

# 3. Patch Treble
bash "$SCRIPT_DIR/patch_treble.sh" "$SYSTEM_ROOT" "$ROM_TYPE"

# 4. Repack into GSI
bash "$SCRIPT_DIR/repack_gsi.sh" "$SYSTEM_ROOT" "$OUTPUT_NAME" "$FS_TYPE"

echo "==> GSI Build pipeline completed successfully."
