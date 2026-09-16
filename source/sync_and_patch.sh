#!/usr/bin/env bash
# ==============================================================================
# sync_and_patch.sh - Sync ROM source tree & apply Project Treble patches
# Optimized for shallow clones (--depth=1) to fit within GitHub Actions runner disk
# ==============================================================================

set -eo pipefail

MANIFEST_URL="${1:-https://github.com/LineageOS/android.git}"
MANIFEST_BRANCH="${2:-lineage-21.0}"
TREBLE_BRANCH="${3:-android-14.0}"
WORK_DIR="${4:-$(pwd)/source_tree}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> [SOURCE-SYNC] Configuring Git credentials..."
git config --global user.name "GSI Builder Bot"
git config --global user.email "bot@treble.build"

echo "==> [SOURCE-SYNC] Initializing repo with $MANIFEST_URL (branch: $MANIFEST_BRANCH)..."
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 --git-lfs 2>/dev/null || repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1

echo "==> [SOURCE-SYNC] Injecting Treble local manifests..."
mkdir -p .repo/local_manifests
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
cp "$SCRIPT_DIR/manifests/treble_manifest.xml" .repo/local_manifests/

# Update revision if branch parameter is specified
if [ -n "$TREBLE_BRANCH" ]; then
  sed -i "s/revision=\"android-14.0\"/revision=\"$TREBLE_BRANCH\"/g" .repo/local_manifests/treble_manifest.xml || true
fi

echo "==> [SOURCE-SYNC] Syncing repositories (shallow sync)..."
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync -j"$(nproc --all)"

echo "==> [SOURCE-SYNC] Applying Project Treble patches..."
if [ -f "device/phh/treble/patches.sh" ]; then
  echo "  -> Executing TrebleDroid patch set..."
  bash device/phh/treble/patches.sh . || true
elif [ -d "device/phh/treble/patches" ]; then
  echo "  -> Applying patch series..."
  for patch_file in $(find device/phh/treble/patches -name "*.patch" | sort); do
    echo "    Applying: $patch_file"
    git apply --check "$patch_file" 2>/dev/null && git apply "$patch_file" || true
  done
fi

echo "==> [SOURCE-SYNC] Source tree prepared and patched successfully."
