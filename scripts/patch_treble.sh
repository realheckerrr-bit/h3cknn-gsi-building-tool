#!/usr/bin/env bash
# ==============================================================================
# patch_treble.sh - Project Treble Compatibility Engine
# Patches OEM system partitions into universal Generic System Images (GSI)
# ==============================================================================

set -Eeuo pipefail

# GitHub-hosted runners run as a normal user with passwordless sudo, while
# local/CI callers may already be root.  Use sudo only when it is needed.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  echo "[-] ERROR: This script must run as root or have sudo available." >&2
  exit 1
fi

on_error() {
  local status=$?
  echo "[-] ERROR: Treble patching failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$status"
}
trap on_error ERR

SYSTEM_ROOT="${1:-}"
ROM_TYPE="${2:-generic}"
CONFIG_DIR="$(dirname "$(realpath "$0")")/../configs"

if [ -z "$SYSTEM_ROOT" ] || [ ! -d "$SYSTEM_ROOT" ]; then
  echo "[-] ERROR: Valid SYSTEM_ROOT directory path is required."
  echo "Usage: ./patch_treble.sh <SYSTEM_ROOT> [ROM_TYPE]"
  exit 1
fi

echo "==> [TREBLE-PATCH] Target Root: $SYSTEM_ROOT"
echo "==> [TREBLE-PATCH] OEM Profile: $ROM_TYPE"

# 1. Locate build.prop.  Extracted images can be either a normal system
# partition (build.prop at the root) or a system-as-root tree (system/build.prop
# or system/system/build.prop).
BUILD_PROP=""
for candidate in \
  "$SYSTEM_ROOT/system/build.prop" \
  "$SYSTEM_ROOT/system/system/build.prop" \
  "$SYSTEM_ROOT/build.prop"; do
  if [ -f "$candidate" ]; then
    BUILD_PROP="$candidate"
    break
  fi
done

if [ -z "$BUILD_PROP" ]; then
  BUILD_PROP=$(find "$SYSTEM_ROOT" -maxdepth 4 -type f -name build.prop -print -quit 2>/dev/null || true)
fi

if [ -z "$BUILD_PROP" ]; then
  echo "[-] ERROR: build.prop could not be found!"
  exit 1
fi

# Extractors can expose the system partition directly at SYSTEM_ROOT or below
# a system/ (occasionally system/system/) directory. Resolve the root from
# the build.prop we actually found so optional edits do not silently target
# paths that do not exist.
case "$BUILD_PROP" in
  "$SYSTEM_ROOT/system/system/"*) SYSTEM_PARTITION_ROOT="$SYSTEM_ROOT/system/system" ;;
  "$SYSTEM_ROOT/system/"*) SYSTEM_PARTITION_ROOT="$SYSTEM_ROOT/system" ;;
  *) SYSTEM_PARTITION_ROOT="$SYSTEM_ROOT" ;;
esac

echo "==> [TREBLE-PATCH] Patching properties in: $BUILD_PROP"

# Ensure write permissions
"${SUDO[@]}" chmod 644 "$BUILD_PROP"

# Escape characters that have replacement-string meaning in sed.  Build
# descriptions and fingerprints can legally contain '&' and other punctuation;
# inserting them unescaped can corrupt build.prop and cause an early bootloop.
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# Helper function to set or replace property
set_prop() {
  local key="$1"
  local val="$2"
  local escaped_val
  escaped_val=$(escape_sed_replacement "$val")
  if grep -q "^${key}=" "$BUILD_PROP"; then
    "${SUDO[@]}" sed -i "s|^${key}=.*|${key}=${escaped_val}|" "$BUILD_PROP"
  else
    printf '%s\n' "${key}=${val}" | "${SUDO[@]}" tee -a "$BUILD_PROP" > /dev/null
  fi
}

# Apply default universal Treble props from config file
if [ -f "$CONFIG_DIR/default_props.txt" ]; then
  echo "==> [TREBLE-PATCH] Injecting universal Treble properties..."
  while IFS='=' read -r key val || [ -n "$key" ]; do
    # Skip comments and blank lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs)
    [ -z "$key" ] && continue
    set_prop "$key" "$val"
  done < "$CONFIG_DIR/default_props.txt"
fi

# 2. Patch essential Treble flags
set_prop "ro.treble.enabled" "true"
set_prop "ro.apex.updatable" "false"
# Do not force ro.debuggable. Debug/user builds require matching boot ramdisk
# and SELinux policy; changing this property cannot provide universal drivers
# and can cause boot failures.

# 2b. Stamp h3cknnGSI_tool branding into the Android build number
# Result in Settings > About Phone > Build Number:
#   "<original_build_number> via h3cknnGSI_tool"
echo "==> [TREBLE-PATCH] Stamping h3cknnGSI_tool branding into build number..."

# A ported GSI is not an OEM or ROM-project official release.  Replace only a
# standalone "official" word so existing "unofficial" labels are untouched.
# This affects Settings strings such as ro.build.display.id and ROM version
# properties before they are copied into the final GSI image.
echo "==> [TREBLE-PATCH] Marking ported build as UNOFFICIAL..."
"${SUDO[@]}" sed -i -E \
  's/(^|[^[:alnum:]_])[Oo][Ff][Ff][Ii][Cc][Ii][Aa][Ll]([^[:alnum:]_]|$)/\1UNOFFICIAL\2/g' \
  "$BUILD_PROP"

# Read current ro.build.display.id (shown as "Build number" in Settings)
ORIG_BUILD_ID=$(grep -m1 "^ro\.build\.display\.id=" "$BUILD_PROP" \
  | cut -d'=' -f2- | xargs 2>/dev/null || true)

# If property doesn't exist, fall back to ro.build.id
if [ -z "$ORIG_BUILD_ID" ]; then
  ORIG_BUILD_ID=$(grep -m1 "^ro\.build\.id=" "$BUILD_PROP" \
    | cut -d'=' -f2- | xargs 2>/dev/null || true)
fi

# If still empty use a generic placeholder
[ -z "$ORIG_BUILD_ID" ] && ORIG_BUILD_ID="unknown"

BRANDED_BUILD_ID="${ORIG_BUILD_ID} via h3cknnGSI_tool"
set_prop "ro.build.display.id" "$BRANDED_BUILD_ID"
echo "  [+] ro.build.display.id = $BRANDED_BUILD_ID"

# Also stamp ro.build.description (visible in bug reports / adb)
ORIG_DESC=$(grep -m1 "^ro\.build\.description=" "$BUILD_PROP" \
  | cut -d'=' -f2- | xargs 2>/dev/null || true)
if [ -n "$ORIG_DESC" ]; then
  set_prop "ro.build.description" "${ORIG_DESC} via h3cknnGSI_tool"
  echo "  [+] ro.build.description stamped."
fi

# Custom identifier prop (queryable via adb shell getprop ro.h3cknn.gsi)
set_prop "ro.h3cknn.gsi.builder" "h3cknnGSI_tool"
set_prop "ro.h3cknn.gsi.version"  "$(date +%Y%m%d)"
set_prop "ro.h3cknn.gsi.profile"  "$ROM_TYPE"
set_prop "ro.h3cknn.gsi.release_type" "unofficial"
set_prop "ro.h3cknn.gsi.official" "false"
echo "  [+] ro.h3cknn.gsi.* properties set."


# 3. Clean up OEM-specific crashing hardware services
echo "==> [TREBLE-PATCH] Sanitizing init scripts and services..."

INIT_DIRS=("$SYSTEM_PARTITION_ROOT/etc/init" "$SYSTEM_PARTITION_ROOT/system/etc/init")
for IDIR in "${INIT_DIRS[@]}"; do
  if [ -d "$IDIR" ]; then
    # Disable OEM-specific proprietary daemons that crash without stock vendor
    "${SUDO[@]}" find "$IDIR" -type f \( \
      -name "*vaultkeeper*.rc" -o \
      -name "*knox*.rc" -o \
      -name "*sem_*.rc" -o \
      -name "*miui_daemon*.rc" -o \
      -name "*faceunlock*.rc" -o \
      -name "*iris*.rc" \
    \) -exec mv {} {}.disabled \; 2>/dev/null || true
  fi
done

# 4. Remove OEM bloatware only when explicitly requested. These packages are
# not universal drivers; deleting similarly named apps from an arbitrary OEM
# image can remove telephony, setup, or device-specific functionality.
if [ "${REMOVE_OEM_BLOAT:-0}" != "1" ]; then
  echo "  [!] Preserving OEM applications (set REMOVE_OEM_BLOAT=1 to opt in)"
else
  echo "==> [TREBLE-PATCH] Removing vendor-locked bloatware (opt-in)..."
REMOVE_TARGETS=(
  "priv-app/Velvet"
  "priv-app/GoogleFeedback"
  "app/Stk"
  "priv-app/SamsungPass"
  "priv-app/SamsungBilling"
  "priv-app/KnoxCore"
  "priv-app/MIUIFaceUnlock"
)

for TARGET in "${REMOVE_TARGETS[@]}"; do
  if [ -d "$SYSTEM_PARTITION_ROOT/$TARGET" ]; then
    echo "  -> Removing $TARGET"
    "${SUDO[@]}" rm -rf "$SYSTEM_PARTITION_ROOT/$TARGET"
  fi
done
fi

# 5. Inject Treble Overlays
# BUG FIX: treble-overlay.apk and TrebleApp.apk have NO GitHub Releases page.
# The prebuilt APKs are bundled inside the GSI images built from source.
# For OEM porting, we download them from phhusson's CI artifacts instead.
echo "==> [TREBLE-PATCH] Injecting Phh Treble overlay (CI artifact)..."

OVERLAY_DIR="$SYSTEM_PARTITION_ROOT/overlay"
if [ -d "$SYSTEM_PARTITION_ROOT/system/overlay" ]; then
  OVERLAY_DIR="$SYSTEM_PARTITION_ROOT/system/overlay"
fi
"${SUDO[@]}" mkdir -p "$OVERLAY_DIR"

# An overlay URL must be supplied by the caller because the old v402 release
# endpoint no longer exists. Never create an empty APK on a failed download.
OVERLAY_URL="${TREBLE_OVERLAY_URL:-}"
if [ -n "$OVERLAY_URL" ] && "${SUDO[@]}" curl -fsSL --max-time 60 "$OVERLAY_URL" -o "$OVERLAY_DIR/treble-overlay.apk" 2>/dev/null; then
  "${SUDO[@]}" chmod 644 "$OVERLAY_DIR/treble-overlay.apk"
  echo "  [+] Injected treble-overlay.apk"
else
  echo "  [!] Treble overlay URL not configured; skipping optional overlay"
fi

# Download TrebleApp from phhusson CI artifacts
APP_DIR="$SYSTEM_PARTITION_ROOT/priv-app/TrebleApp"
"${SUDO[@]}" mkdir -p "$APP_DIR"
TREBLEAPP_URL="${TREBLE_APP_URL:-}"
if [ -n "$TREBLEAPP_URL" ] && "${SUDO[@]}" curl -fsSL --max-time 60 "$TREBLEAPP_URL" -o "$APP_DIR/TrebleApp.apk" 2>/dev/null; then
  "${SUDO[@]}" chmod 644 "$APP_DIR/TrebleApp.apk"
  echo "  [+] Injected TrebleApp hardware manager"
else
  echo "  [!] TrebleApp URL not configured; skipping optional app"
fi

# 6. Adjust fstab entries only when explicitly requested.
#
# The system image does not own Samsung's vendor fstab, AVB chain, or
# encryption policy.  Editing every fstab found under /system can also remove
# required mount flags and create a bootloop.  Keep the safe default intact;
# callers who knowingly have a test image may opt in for debugging.
if [ "${DISABLE_FSTAB_ENCRYPTION:-0}" = "1" ]; then
  echo "==> [TREBLE-PATCH] Explicit fstab encryption override enabled"
  while IFS= read -r FSTAB; do
    [ -z "$FSTAB" ] && continue
    echo "==> [TREBLE-PATCH] Patching fstab: $FSTAB"
    "${SUDO[@]}" sed -i 's/fileencryption=[^,]*//g' "$FSTAB"
    "${SUDO[@]}" sed -i 's/forceencrypt=[^,]*//g' "$FSTAB"
    "${SUDO[@]}" sed -i 's/,verify//g' "$FSTAB"
    "${SUDO[@]}" sed -i 's/,avb[^,]*//g' "$FSTAB"
  done < <(find "$SYSTEM_PARTITION_ROOT" -name "*fstab*" -type f -print 2>/dev/null || true)
else
  echo "  [!] Leaving fstab, AVB, and encryption flags unchanged"
fi

echo "==> [TREBLE-PATCH] Project Treble modifications applied successfully!"
