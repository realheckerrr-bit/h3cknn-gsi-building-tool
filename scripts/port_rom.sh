#!/usr/bin/env bash
# ==============================================================================
# port_rom.sh - Master pipeline for OEM ROM -> Treble GSI porting
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROM_URL="${1:-}"
OUTPUT_NAME="${2:-GSI_Treble_ARM64}"
ROM_TYPE="${3:-generic}"
FS_TYPE="${4:-ext4}"
WORK_DIR="$(pwd)/workspace"

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
echo " ROM URL:     $ROM_URL"
echo " Output Name: $OUTPUT_NAME"
echo " Profile:     $ROM_TYPE"
echo " Filesystem:  $FS_TYPE"
echo "=========================================================="

# 1. Setup dependencies
bash "$SCRIPT_DIR/setup_deps.sh"

# 2. Extract ROM
bash "$SCRIPT_DIR/extract_rom.sh" "$ROM_URL" "$WORK_DIR"

SYSTEM_ROOT="$WORK_DIR/system_root"

# 3. Patch Treble
bash "$SCRIPT_DIR/patch_treble.sh" "$SYSTEM_ROOT" "$ROM_TYPE"

# 4. Repack into GSI
bash "$SCRIPT_DIR/repack_gsi.sh" "$SYSTEM_ROOT" "$OUTPUT_NAME" "$FS_TYPE"

echo "==> GSI Build pipeline completed successfully."
