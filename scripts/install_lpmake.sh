#!/usr/bin/env bash
# Install the AOSP dynamic-partition image builder used by the Samsung workflow.

set -Eeuo pipefail

if [ "${FORCE_LPMAKE_REINSTALL:-0}" != "1" ] \
  && command -v lpmake >/dev/null 2>&1 \
  && lpmake --help >/dev/null 2>&1; then
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
PRIMARY_LIBLP_SHA256="af1f83237fed0c284d2c24ed6cf64381cf4e6cbe0e54f02c6299d5bb5dda0ec0"
FALLBACK_LIBLP_SHA256="95221e036a664be40d67e07e0dfd026305f12390fdfa957d4aa3a3296bd519a3"
# Last-resort statically linked fallback. The AOSP endpoints remain first;
# this pinned mirror is used only when both Google sources are unavailable.
STATIC_FALLBACK_COMMIT="da4dd13276e40d524286f343c4d59c7c5dfe8594"
STATIC_FALLBACK_LP_SHA256="ea077cf98e2178828c9376a03d5dec0cc98b59458c2a0b94cda9e59b4218467a"

if [ -n "${LPMake_URL:-}" ]; then
  LPMake_URLS=("$LPMake_URL")
  LPMake_SHAS=("${LPMake_SHA256_OVERRIDE:-}")
else
  LPMake_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$PRIMARY_COMMIT/linux-x86/bin/lpmake?format=TEXT"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+/$FALLBACK_COMMIT/linux-x86/bin/lpmake?format=TEXT"
    "https://raw.githubusercontent.com/whyshhnuv/lpunpack-lpmake-mirror/$STATIC_FALLBACK_COMMIT/binary/lpmake"
  )
  LPMake_SHAS=("$PRIMARY_LP_SHA256" "$FALLBACK_LP_SHA256" "$STATIC_FALLBACK_LP_SHA256")
fi

if [ -n "${LIB_ARCHIVE_URL:-}" ]; then
  LIB_ARCHIVE_URLS=("$LIB_ARCHIVE_URL")
  LIB_LP_SHAS=("${LIBLP_SHA256_OVERRIDE:-}")
else
  LIB_ARCHIVE_URLS=(
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$PRIMARY_COMMIT/linux-x86/lib64.tar.gz"
    "https://android.googlesource.com/kernel/prebuilts/build-tools/+archive/$FALLBACK_COMMIT/linux-x86/lib64.tar.gz"
  )
  # The tar.gz wrapper contains variable archive timestamps. Verify the
  # extracted AOSP liblp.so instead of hashing the non-deterministic wrapper.
  LIB_LP_SHAS=("$PRIMARY_LIBLP_SHA256" "$FALLBACK_LIBLP_SHA256")
fi
TEMP_DIR="$(mktemp -d)"
TEMP_FILE="$TEMP_DIR/lpmake"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "==> [SETUP] Installing verified AOSP lpmake..."
LPMake_READY=0
for i in "${!LPMake_URLS[@]}"; do
  if [ -n "${LPMake_FORCE_SOURCE_INDEX:-}" ] \
    && [ "$i" != "$LPMake_FORCE_SOURCE_INDEX" ]; then
    continue
  fi
  rm -f -- "$TEMP_DIR/lpmake.b64" "$TEMP_FILE"
  echo "  -> Trying pinned AOSP lpmake source $((i + 1))/${#LPMake_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LPMake_URLS[$i]}" -o "$TEMP_DIR/lpmake.b64"; then
    echo "  [!] lpmake source unavailable; trying the next pinned source" >&2
    continue
  fi
  if [[ "${LPMake_URLS[$i]}" == *"format=TEXT"* ]]; then
    if ! base64 --decode "$TEMP_DIR/lpmake.b64" > "$TEMP_FILE"; then
      echo "  [!] lpmake source could not be decoded; trying the next pinned source" >&2
      continue
    fi
  else
    # GitHub's raw fallback is already an ELF binary, not AOSP's base64
    # transport representation.
    cp -- "$TEMP_DIR/lpmake.b64" "$TEMP_FILE"
  fi
  if [ ! -s "$TEMP_FILE" ]; then
    echo "  [!] lpmake source was empty; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LPMake_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LPMake_SHAS[$i]}" "$TEMP_FILE" | sha256sum --check --status; then
    echo "  [!] lpmake checksum mismatch; refusing this source" >&2
    continue
  fi
  LPMake_READY=1
  LPMake_SOURCE_INDEX="$i"
  break
done
if [ "$LPMake_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake source could be downloaded." >&2
  exit 1
fi

# The pinned mirror binary is statically linked, so it does not need the
# matching AOSP liblp/libbase archive. Install the same wrapper path so callers
# do not need to know which source supplied the binary.
if [ "${LPMake_SOURCE_INDEX:-0}" = "2" ]; then
  AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
  sudo install -d -m 0755 "$AOSP_LIB_DIR"
  sudo install -m 0755 "$TEMP_FILE" "$AOSP_LIB_DIR/lpmake.bin"
  sudo install -m 0755 "$(dirname "$(realpath "$0")")/lpmake_wrapper.sh" /usr/local/bin/lpmake
  echo "  [+] static fallback lpmake installed at /usr/local/bin/lpmake"
  exit 0
fi

ANDROID_LIB_DIR="$(dirname "$(find -L /usr/lib -type f -path '*/android/libbase.so' -print -quit)")"
if [ -z "$ANDROID_LIB_DIR" ] || [ "$ANDROID_LIB_DIR" = "." ]; then
  echo "[-] ERROR: Ubuntu Android library directory was not found." >&2
  exit 1
fi
echo "==> [SETUP] Installing matching AOSP lpmake libraries..."
LIB_READY=0
if [ "${#LIB_ARCHIVE_URLS[@]}" -eq 1 ]; then
  LIB_INDICES=(0)
elif [ "${LPMake_SOURCE_INDEX:-0}" = "1" ]; then
  LIB_INDICES=(1 0)
else
  LIB_INDICES=(0 1)
fi
for i in "${LIB_INDICES[@]}"; do
  rm -f -- "$TEMP_DIR/lib64.tar.gz"
  rm -rf -- "$TEMP_DIR/lib64"
  echo "  -> Trying matching AOSP library source $((i + 1))/${#LIB_ARCHIVE_URLS[@]}..."
  if ! curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "${LIB_ARCHIVE_URLS[$i]}" -o "$TEMP_DIR/lib64.tar.gz"; then
    echo "  [!] AOSP library source unavailable; trying the next pinned source" >&2
    continue
  fi
  mkdir -p "$TEMP_DIR/lib64"
  if ! tar -xzf "$TEMP_DIR/lib64.tar.gz" -C "$TEMP_DIR/lib64" \
    || [ ! -f "$TEMP_DIR/lib64/liblp.so" ]; then
    echo "  [!] AOSP library archive is invalid; trying the next pinned source" >&2
    continue
  fi
  if [ -n "${LIB_LP_SHAS[$i]}" ] \
    && ! printf '%s  %s\n' "${LIB_LP_SHAS[$i]}" "$TEMP_DIR/lib64/liblp.so" | sha256sum --check --status; then
    echo "  [!] liblp.so checksum mismatch; refusing this source" >&2
    continue
  fi
  LIB_READY=1
  break
done
if [ "$LIB_READY" != "1" ]; then
  echo "[-] ERROR: No verified AOSP lpmake library archive could be downloaded." >&2
  exit 1
fi
AOSP_LIB_DIR="/usr/local/lib/h3cknn-gsi/aosp-lib64"
sudo install -d -m 0755 "$AOSP_LIB_DIR"
sudo install -m 0755 "$TEMP_DIR/lib64/"*.so "$AOSP_LIB_DIR/"
sudo install -m 0755 "$TEMP_FILE" "$AOSP_LIB_DIR/lpmake.bin"
sudo install -m 0755 "$(dirname "$(realpath "$0")")/lpmake_wrapper.sh" /usr/local/bin/lpmake
echo "  [+] lpmake installed at /usr/local/bin/lpmake"
