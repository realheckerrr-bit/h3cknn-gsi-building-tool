#!/usr/bin/env bash
# Install the AOSP dynamic-partition image builder used by the Samsung workflow.

set -Eeuo pipefail

if command -v lpmake >/dev/null 2>&1 && lpmake --help >/dev/null 2>&1; then
  echo "  [+] lpmake already present: $(command -v lpmake)"
  exit 0
fi

if ! command -v patchelf >/dev/null 2>&1; then
  echo "[-] ERROR: patchelf is required to make the AOSP lpmake binary find Ubuntu's Android libraries." >&2
  exit 1
fi

# Ubuntu's android-sdk-libsparse-utils package contains simg2img, but not
# lpmake. This is a pinned AOSP prebuilt; verify it before installing it.
LPMake_URL="${LPMake_URL:-https://android.googlesource.com/kernel/prebuilts/build-tools/+/refs/heads/androidx-draganddrop-release/linux-x86/bin/lpmake?format=TEXT}"
LPMake_SHA256="276c0c8a046a69e6a2780e08835077119ad7129ddc59cbd12920ecba193d2d31"
LIB_ARCHIVE_URL="${LIB_ARCHIVE_URL:-https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/refs/heads/androidx-draganddrop-release/linux-x86/lib64.tar.gz}"
TEMP_DIR="$(mktemp -d)"
TEMP_FILE="$TEMP_DIR/lpmake"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "==> [SETUP] Installing verified AOSP lpmake..."
curl -fsSL "$LPMake_URL" | base64 --decode > "$TEMP_FILE"
printf '%s  %s\n' "$LPMake_SHA256" "$TEMP_FILE" | sha256sum --check --status
ANDROID_LIB_DIR="$(dirname "$(find -L /usr/lib -type f -path '*/android/libbase.so' -print -quit)")"
if [ -z "$ANDROID_LIB_DIR" ] || [ "$ANDROID_LIB_DIR" = "." ]; then
  echo "[-] ERROR: Ubuntu Android library directory was not found." >&2
  exit 1
fi
echo "==> [SETUP] Installing matching AOSP lpmake libraries..."
curl -fsSL "$LIB_ARCHIVE_URL" -o "$TEMP_DIR/lib64.tar.gz"
mkdir -p "$TEMP_DIR/lib64"
tar -xzf "$TEMP_DIR/lib64.tar.gz" -C "$TEMP_DIR/lib64"
if [ ! -f "$TEMP_DIR/lib64/liblp.so" ]; then
  echo "[-] ERROR: AOSP lpmake library archive did not contain liblp.so." >&2
  exit 1
fi
AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
sudo install -m 0755 "$TEMP_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
patchelf --set-rpath "$AOSP_LIB_DIR:$ANDROID_LIB_DIR" "$TEMP_FILE"
sudo install -m 0755 "$TEMP_FILE" /usr/local/bin/lpmake
echo "  [+] lpmake installed at /usr/local/bin/lpmake"
