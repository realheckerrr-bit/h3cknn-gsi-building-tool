#!/usr/bin/env bash
# Install the AOSP dynamic-partition image builder used by the Samsung workflow.

set -Eeuo pipefail

if command -v lpmake >/dev/null 2>&1 && lpmake --help >/dev/null 2>&1; then
  echo "  [+] lpmake already present: $(command -v lpmake)"
  exit 0
fi

# Ubuntu's android-sdk-libsparse-utils package contains simg2img, but not
# lpmake. These are pinned AOSP prebuilts; every candidate is verified before
# installation. The second revision is an independent fallback for transient
# android.googlesource.com 5xx outages.
PRIMARY_COMMIT="39a8ce1951d13b0f31996ae153865729e831d0f9"
FALLBACK_COMMIT="978920d8481c684fc798f9bac23e1a7605e4ab26"
PRIMARY_LP_SHA256="276c0c8a046a69e6a2780e08835077119ad7129ddc59cbd12920ecba193d2d31"
FALLBACK_LP_SHA256="5413f722b60f2971bad343a28fb4c7f83984af8e3e13b5224b9ce99840527fde"
PRIMARY_LIB_SHA256="987544dbf33f7d008aca404725acfa94c8a6bf97f0d0dd0175330c725926cb20"
FALLBACK_LIB_SHA256="8b54952fcf5596d7ea61c0cfe57c32077e823448997a6f703940152691e2084a"

if [ -n "${LPMake_URL:-}" ]; then
  LPMake_URLS=("$LPMake_URL")
  LPMake_SHAS=("${LPMake_SHA256_OVERRIDE:-}")
else
  LPMake_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$PRIMARY_COMMIT/linux-x86/bin/lpmake?format=TEXT"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$FALLBACK_COMMIT/linux-x86/bin/lpmake?format=TEXT"
  )
  LPMake_SHAS=("$PRIMARY_LP_SHA256" "$FALLBACK_LP_SHA256")
fi

if [ -n "${LIB_ARCHIVE_URL:-}" ]; then
  LIB_ARCHIVE_URLS=("$LIB_ARCHIVE_URL")
  LIB_ARCHIVE_SHAS=("${LIB_ARCHIVE_SHA256_OVERRIDE:-}")
else
  LIB_ARCHIVE_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$PRIMARY_COMMIT/linux-x86/lib64.tar.gz"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$FALLBACK_COMMIT/linux-x86/lib64.tar.gz"
  )
  LIB_ARCHIVE_SHAS=("$PRIMARY_LIB_SHA256" "$FALLBACK_LIB_SHA256")
fi
TEMP_DIR="$(mktemp -d)"
TEMP_FILE="$TEMP_DIR/lpmake"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "==> [SETUP] Installing verified AOSP lpmake..."
LPMake_READY=0
for i in "${!LPMake_URLS[@]}"; do
  rm -f -- "$TEMP_DIR/lpmake.b64" "$TEMP_FILE"
  echo "  -> Trying pinned AOSP lpmake source $((i + 1))/${#LPMake_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LPMake_URLS[$i]}" -o "$TEMP_DIR/lpmake.b64"; then
    echo "  [!] lpmake source unavailable; trying the next pinned source" >&2
    continue
  fi
  if ! base64 --decode "$TEMP_DIR/lpmake.b64" > "$TEMP_FILE" || [ ! -s "$TEMP_FILE" ]; then
    echo "  [!] lpmake source could not be decoded; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LPMake_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LPMake_SHAS[$i]}" "$TEMP_FILE" | sha256sum --check --status; then
    echo "  [!] lpmake checksum mismatch; refusing this source" >&2
    continue
  fi
  LPMake_READY=1
  break
done
if [ "$LPMake_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake source could be downloaded." >&2
  exit 1
fi
ANDROID_LIB_DIR="$(dirname "$(find -L /usr/lib -type f -path '*/android/libbase.so' -print -quit)")"
if [ -z "$ANDROID_LIB_DIR" ] || [ "$ANDROID_LIB_DIR" = "." ]; then
  echo "[-] ERROR: Ubuntu Android library directory was not found." >&2
  exit 1
fi
echo "==> [SETUP] Installing matching AOSP lpmake libraries..."
LIB_READY=0
for i in "${!LIB_ARCHIVE_URLS[@]}"; do
  rm -f -- "$TEMP_DIR/lib64.tar.gz"
  echo "  -> Trying matching AOSP library source $((i + 1))/${#LIB_ARCHIVE_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LIB_ARCHIVE_URLS[$i]}" -o "$TEMP_DIR/lib64.tar.gz"; then
    echo "  [!] AOSP library source unavailable; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LIB_ARCHIVE_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LIB_ARCHIVE_SHAS[$i]}" "$TEMP_DIR/lib64.tar.gz" | sha256sum --check --status; then
    echo "  [!] AOSP library checksum mismatch; refusing this source" >&2
    continue
  fi
  LIB_READY=1
  break
done
if [ "$LIB_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake library archive could be downloaded." >&2
  exit 1
fi
mkdir -p "$TEMP_DIR/lib64"
tar -xzf "$TEMP_DIR/lib64.tar.gz" -C "$TEMP_DIR/lib64"
if [ ! -f "$TEMP_DIR/lib64/liblp.so" ]; then
  echo "[-] ERROR: AOSP lpmake library archive did not contain liblp.so." >&2
  exit 1
fi
AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
sudo install -m 0755 "$TEMP_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
sudo install -m 0755 "$TEMP_FILE" "$AOSP_LIB_DIR/lpmake.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/lpmake_wrapper.sh" /usr/local/bin/lpmake
echo "  [+] lpmake installed at /usr/local/bin/lpmake"
