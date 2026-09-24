#!/usr/bin/env bash
# Install the AOSP dynamic-partition image builder used by the Samsung workflow.

set -Eeuo pipefail

if command -v lpmake >/dev/null 2>&1; then
  echo "  [+] lpmake already present: $(command -v lpmake)"
  exit 0
fi

# Ubuntu's android-sdk-libsparse-utils package contains simg2img, but not
# lpmake. This is a pinned AOSP prebuilt; verify it before installing it.
LPMake_URL="${LPMake_URL:-https://android.googlesource.com/kernel/prebuilts/build-tools/+/refs/heads/androidx-draganddrop-release/linux-x86/bin/lpmake?format=TEXT}"
LPMake_SHA256="276c0c8a046a69e6a2780e08835077119ad7129ddc59cbd12920ecba193d2d31"
TEMP_FILE="$(mktemp)"
trap 'rm -f -- "$TEMP_FILE"' EXIT

echo "==> [SETUP] Installing verified AOSP lpmake..."
curl -fsSL "$LPMake_URL" | base64 --decode > "$TEMP_FILE"
printf '%s  %s\n' "$LPMake_SHA256" "$TEMP_FILE" | sha256sum --check --status
sudo install -m 0755 "$TEMP_FILE" /usr/local/bin/lpmake
echo "  [+] lpmake installed at /usr/local/bin/lpmake"
