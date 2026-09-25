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

# Keep the source workflow on the variants that TrebleDroid actually exposes.
# A typo here otherwise reaches `lunch`, fails much later, and can leave a
# misleading partial image in out_gsi.  Device-specific kernels and vendor
# drivers are intentionally not part of this generic system-image build.
case "$TARGET_VARIANT" in
  treble_arm64_bvN|treble_arm64_bgN|treble_arm64_bvS|treble_arm64_bgS) ;;
  *)
    echo "[-] ERROR: Unsupported Treble variant: $TARGET_VARIANT" >&2
    echo "    Supported variants: treble_arm64_bvN, treble_arm64_bgN, treble_arm64_bvS, treble_arm64_bgS" >&2
    exit 2
    ;;
esac
case "$BUILD_TYPE" in
  user|userdebug) ;;
  *)
    echo "[-] ERROR: Build type must be user or userdebug (got: $BUILD_TYPE)." >&2
    exit 2
    ;;
esac

if [ ! -d "$WORK_DIR" ]; then
  echo "[-] ERROR: Source directory $WORK_DIR not found."
  exit 1
fi

cd "$WORK_DIR"
mkdir -p "$OUT_DIR"
# Do not let a rerun accidentally publish stale artifacts from an earlier
# variant or failed build.
rm -f -- "$OUT_DIR"/*.img "$OUT_DIR"/*.img.xz "$OUT_DIR"/*.img.gz \
  "$OUT_DIR"/SHA256SUMS.txt "$OUT_DIR"/build-info.txt \
  "$OUT_DIR"/compatibility-report.txt

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
PRODUCT_OUT=""
if declare -F get_build_var >/dev/null 2>&1; then
  PRODUCT_OUT=$(get_build_var PRODUCT_OUT 2>/dev/null || true)
fi
if [ -n "$PRODUCT_OUT" ] && [ -f "$PRODUCT_OUT/system.img" ]; then
  SYSTEM_IMG="$PRODUCT_OUT/system.img"
else
  SYSTEM_IMG=$(find out/target/product -type f -name "system.img" -print -quit)
fi

if [ -z "$SYSTEM_IMG" ] || [ ! -f "$SYSTEM_IMG" ]; then
  echo "[-] ERROR: system.img was not generated."
  exit 1
fi

IMAGE_TYPE=$(file -b "$SYSTEM_IMG" | tr '[:upper:]' '[:lower:]')
IMAGE_MAGIC=$(od -An -tx1 -N4 "$SYSTEM_IMG" 2>/dev/null | tr -d '[:space:]')
if [ "$IMAGE_MAGIC" != "3aff26ed" ] && ! printf '%s' "$IMAGE_TYPE" \
  | grep -Eiq 'ext[234] filesystem|erofs'; then
  echo "[-] ERROR: generated system.img is not a recognized raw/sparse ext4 or EROFS image." >&2
  echo "    Detected: $IMAGE_TYPE" >&2
  exit 1
fi
echo "  -> Image type: $IMAGE_TYPE"

OUTPUT_BASENAME="${TARGET_VARIANT}-$(date +%Y%m%d)"
FINAL_IMG="$OUT_DIR/${OUTPUT_BASENAME}.img"
cp "$SYSTEM_IMG" "$FINAL_IMG"

echo "==> [SOURCE-BUILD] Compressing output with XZ..."
xz -9 -T0 -k "$FINAL_IMG"
echo "==> [SOURCE-BUILD] Compressing output with GZIP for DSU Sideloader..."
# Android build outputs are commonly sparse. Keep that layout in the XZ
# flashing asset, but provide DSU with a raw, unsparsed filesystem image.
DSU_SOURCE="$FINAL_IMG"
DSU_RAW_IMG="$OUT_DIR/.${OUTPUT_BASENAME}.dsu.raw.img"
IMAGE_MAGIC=$(od -An -tx1 -N4 "$FINAL_IMG" 2>/dev/null | tr -d '[:space:]')
if [ "$IMAGE_MAGIC" = "3aff26ed" ]; then
  if ! command -v simg2img >/dev/null 2>&1; then
    echo "[-] ERROR: Sparse source image detected, but simg2img is unavailable for DSU output." >&2
    exit 1
  fi
  echo "==> [SOURCE-BUILD] Expanding sparse image for the DSU GZIP asset..."
  simg2img "$FINAL_IMG" "$DSU_RAW_IMG"
  DSU_SOURCE="$DSU_RAW_IMG"
fi
gzip -9 -c "$DSU_SOURCE" > "${FINAL_IMG}.gz"
rm -f -- "$DSU_RAW_IMG"

echo "================================================================="
echo "==> [SOURCE-BUILD] BUILD SUCCEEDED!"
echo "  Raw Image:        $FINAL_IMG"
echo "  Compressed Image: ${FINAL_IMG}.xz"
echo "  DSU Image:        ${FINAL_IMG}.gz"
echo "  Size:             $(du -h "${FINAL_IMG}.xz" | cut -f1)"
echo "================================================================="
