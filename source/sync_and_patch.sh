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

# The value is inserted into an XML manifest. Keep the workflow input to a
# branch/tag/ref rather than allowing malformed XML or shell-hostile text.
case "$TREBLE_BRANCH" in
  ''|*[!A-Za-z0-9._/-]*)
    echo "[-] ERROR: TREBLE_BRANCH contains unsupported characters: $TREBLE_BRANCH" >&2
    exit 2
    ;;
esac

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
  TREBLE_BRANCH_ESCAPED=$(printf '%s' "$TREBLE_BRANCH" | sed 's/[&|\\]/\\&/g')
  sed -i "s|revision=\"android-14.0\"|revision=\"$TREBLE_BRANCH_ESCAPED\"|g" .repo/local_manifests/treble_manifest.xml
fi

echo "==> [SOURCE-SYNC] Syncing repositories (shallow sync)..."
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync -j"$(nproc --all)"

echo "==> [SOURCE-SYNC] Applying Project Treble patches..."
if [ -f "device/phh/treble/patches.sh" ]; then
  echo "  -> Executing TrebleDroid patch set..."
  bash device/phh/treble/patches.sh .
elif [ -d "device/phh/treble/patches" ]; then
  echo "  -> Applying patch series..."
  while IFS= read -r -d '' patch_file; do
    echo "    Applying: $patch_file"
    git apply --check "$patch_file"
    git apply "$patch_file"
  done < <(find device/phh/treble/patches -type f -name "*.patch" -print0 | sort -z)
fi

echo "==> [SOURCE-SYNC] Source tree prepared and patched successfully."
