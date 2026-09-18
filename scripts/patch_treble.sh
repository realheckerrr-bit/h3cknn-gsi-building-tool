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

echo "==> [TREBLE-PATCH] Patching properties in: $BUILD_PROP"

# Ensure write permissions
"${SUDO[@]}" chmod 644 "$BUILD_PROP"

# Helper function to set or replace property
set_prop() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$BUILD_PROP"; then
    "${SUDO[@]}" sed -i "s|^${key}=.*|${key}=${val}|" "$BUILD_PROP"
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
set_prop "ro.adb.secure" "0"
set_prop "ro.secure" "0"
set_prop "ro.debuggable" "1"

# 2b. Stamp h3cknnGSI_tool branding into the Android build number
# Result in Settings > About Phone > Build Number:
#   "<original_build_number> via h3cknnGSI_tool"
echo "==> [TREBLE-PATCH] Stamping h3cknnGSI_tool branding into build number..."

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
echo "  [+] ro.h3cknn.gsi.* properties set."


# 3. Clean up OEM-specific crashing hardware services
echo "==> [TREBLE-PATCH] Sanitizing init scripts and services..."

INIT_DIRS=("$SYSTEM_ROOT/system/etc/init" "$SYSTEM_ROOT/etc/init")
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

# 4. Remove OEM bloatware that hinders GSI booting
echo "==> [TREBLE-PATCH] Removing vendor-locked bloatware..."
REMOVE_TARGETS=(
  "system/priv-app/Velvet"
  "system/priv-app/SetupWizard"
  "system/priv-app/GoogleFeedback"
  "system/app/Stk"
  "system/priv-app/SamsungPass"
  "system/priv-app/SamsungBilling"
  "system/priv-app/KnoxCore"
  "system/priv-app/MIUIFaceUnlock"
)

for TARGET in "${REMOVE_TARGETS[@]}"; do
  if [ -d "$SYSTEM_ROOT/$TARGET" ]; then
    echo "  -> Removing $TARGET"
    "${SUDO[@]}" rm -rf "$SYSTEM_ROOT/$TARGET"
  fi
done

# 5. Inject Treble Overlays
# BUG FIX: treble-overlay.apk and TrebleApp.apk have NO GitHub Releases page.
# The prebuilt APKs are bundled inside the GSI images built from source.
# For OEM porting, we download them from phhusson's CI artifacts instead.
echo "==> [TREBLE-PATCH] Injecting Phh Treble overlay (CI artifact)..."

OVERLAY_DIR="$SYSTEM_ROOT/system/overlay"
[ -d "$SYSTEM_ROOT/overlay" ] && OVERLAY_DIR="$SYSTEM_ROOT/overlay"
"${SUDO[@]}" mkdir -p "$OVERLAY_DIR"

# Download overlay APK from phhusson's treble_experimentations CI artifacts
OVERLAY_URL="https://github.com/phhusson/treble_experimentations/releases/download/v402/treble-overlay.apk"
if "${SUDO[@]}" curl -fsSL --max-time 60 "$OVERLAY_URL" -o "$OVERLAY_DIR/treble-overlay.apk" 2>/dev/null; then
  "${SUDO[@]}" chmod 644 "$OVERLAY_DIR/treble-overlay.apk"
  echo "  [+] Injected treble-overlay.apk"
else
  echo "  [!] Warning: Could not download treble-overlay.apk (non-fatal, continuing)"
fi

# Download TrebleApp from phhusson CI artifacts
APP_DIR="$SYSTEM_ROOT/system/priv-app/TrebleApp"
"${SUDO[@]}" mkdir -p "$APP_DIR"
TREBLEAPP_URL="https://github.com/phhusson/treble_experimentations/releases/download/v402/TrebleApp.apk"
if "${SUDO[@]}" curl -fsSL --max-time 60 "$TREBLEAPP_URL" -o "$APP_DIR/TrebleApp.apk" 2>/dev/null; then
  "${SUDO[@]}" chmod 644 "$APP_DIR/TrebleApp.apk"
  echo "  [+] Injected TrebleApp hardware manager"
else
  echo "  [!] Warning: Could not download TrebleApp.apk (non-fatal, continuing)"
fi

# 6. Adjust fstab entries
# Keep an empty fstab search from tripping errexit/ERR when the extracted
# system image has no fstab files.
while IFS= read -r FSTAB; do
  [ -z "$FSTAB" ] && continue
  echo "==> [TREBLE-PATCH] Patching fstab: $FSTAB"
  "${SUDO[@]}" sed -i 's/fileencryption=[^,]*//g' "$FSTAB" || true
  "${SUDO[@]}" sed -i 's/forceencrypt=[^,]*//g' "$FSTAB" || true
  "${SUDO[@]}" sed -i 's/,verify//g' "$FSTAB" || true
  "${SUDO[@]}" sed -i 's/,avb[^,]*//g' "$FSTAB" || true
done < <(find "$SYSTEM_ROOT" -name "*fstab*" -type f -print 2>/dev/null || true)

echo "==> [TREBLE-PATCH] Project Treble modifications applied successfully!"
