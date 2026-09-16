#!/usr/bin/env bash
# ==============================================================================
# build_source.sh - Compile Treble GSI from Android Source Tree
# Target: treble_arm64_bvN (A/B, Vanilla, Non-root) or treble_arm64_bgN (GApps)
# ==============================================================================

set -eo pipefail

WORK_DIR="${1:-$(pwd)/source_tree}"
TARGET_VARIANT="${2:-treble_arm64_bvN}"
BUILD_TYPE="${3:-userdebug}"
OUT_DIR="$WORK_DIR/out_gsi"

if [ ! -d "$WORK_DIR" ]; then
  echo "[-] ERROR: Source directory $WORK_DIR not found."
  exit 1
fi

cd "$WORK_DIR"
mkdir -p "$OUT_DIR"

echo "==> [SOURCE-BUILD] Setting up Android build environment..."
source build/envsetup.sh

LUNCH_TARGET="${TARGET_VARIANT}-${BUILD_TYPE}"
echo "==> [SOURCE-BUILD] Selecting lunch target: $LUNCH_TARGET"
lunch "$LUNCH_TARGET"

echo "==> [SOURCE-BUILD] Configuring compiler cache (ccache)..."
export USE_CCACHE=1
export CCACHE_DIR="$WORK_DIR/.ccache"
export CCACHE_EXEC=$(command -v ccache)
ccache -M 30G 2>/dev/null || true

echo "==> [SOURCE-BUILD] Starting compilation of systemimage..."
# Only build systemimage rather than full bacon zip to conserve time and disk
mka systemimage -j"$(nproc --all)"

echo "==> [SOURCE-BUILD] Compilation completed. Locating output..."
SYSTEM_IMG=$(find out/target/product -name "system.img" | head -n 1)

if [ -z "$SYSTEM_IMG" ] || [ ! -f "$SYSTEM_IMG" ]; then
  echo "[-] ERROR: system.img was not generated."
  exit 1
fi

OUTPUT_BASENAME="${TARGET_VARIANT}-$(date +%Y%m%d)"
FINAL_IMG="$OUT_DIR/${OUTPUT_BASENAME}.img"
cp "$SYSTEM_IMG" "$FINAL_IMG"

echo "==> [SOURCE-BUILD] Compressing output with XZ..."
xz -9 -T0 -k "$FINAL_IMG"

echo "================================================================="
echo "==> [SOURCE-BUILD] BUILD SUCCEEDED!"
echo "  Raw Image:        $FINAL_IMG"
echo "  Compressed Image: ${FINAL_IMG}.xz"
echo "  Size:             $(du -h "${FINAL_IMG}.xz" | cut -f1)"
echo "================================================================="
