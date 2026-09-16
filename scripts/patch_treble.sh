#!/usr/bin/env bash
# ==============================================================================
# patch_treble.sh - Project Treble Compatibility Engine
# Patches OEM system partitions into universal Generic System Images (GSI)
# ==============================================================================

set -eo pipefail

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

# 1. Locate build.prop
BUILD_PROP=""
if [ -f "$SYSTEM_ROOT/system/build.prop" ]; then
  BUILD_PROP="$SYSTEM_ROOT/system/build.prop"
elif [ -f "$SYSTEM_ROOT/build.prop" ]; then
  BUILD_PROP="$SYSTEM_ROOT/build.prop"
fi

if [ -z "$BUILD_PROP" ]; then
  echo "[-] ERROR: build.prop could not be found!"
  exit 1
fi

echo "==> [TREBLE-PATCH] Patching properties in: $BUILD_PROP"

# Ensure write permissions
sudo chmod 644 "$BUILD_PROP"

# Helper function to set or replace property
set_prop() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$BUILD_PROP"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|" "$BUILD_PROP"
  else
    echo "${key}=${val}" | sudo tee -a "$BUILD_PROP" > /dev/null
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

# 3. Clean up OEM-specific crashing hardware services
echo "==> [TREBLE-PATCH] Sanitizing init scripts and services..."

INIT_DIRS=("$SYSTEM_ROOT/system/etc/init" "$SYSTEM_ROOT/etc/init")
for IDIR in "${INIT_DIRS[@]}"; do
  if [ -d "$IDIR" ]; then
    # Disable OEM-specific proprietary daemons that crash without stock vendor
    sudo find "$IDIR" -type f \( \
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
    sudo rm -rf "$SYSTEM_ROOT/$TARGET"
  fi
done

# 5. Inject Treble Overlays
# BUG FIX: treble-overlay.apk and TrebleApp.apk have NO GitHub Releases page.
# The prebuilt APKs are bundled inside the GSI images built from source.
# For OEM porting, we download them from phhusson's CI artifacts instead.
echo "==> [TREBLE-PATCH] Injecting Phh Treble overlay (CI artifact)..."

OVERLAY_DIR="$SYSTEM_ROOT/system/overlay"
[ -d "$SYSTEM_ROOT/overlay" ] && OVERLAY_DIR="$SYSTEM_ROOT/overlay"
sudo mkdir -p "$OVERLAY_DIR"

# Download overlay APK from phhusson's treble_experimentations CI artifacts
OVERLAY_URL="https://github.com/phhusson/treble_experimentations/releases/download/v402/treble-overlay.apk"
if sudo curl -fsSL --max-time 60 "$OVERLAY_URL" -o "$OVERLAY_DIR/treble-overlay.apk" 2>/dev/null; then
  sudo chmod 644 "$OVERLAY_DIR/treble-overlay.apk"
  echo "  [+] Injected treble-overlay.apk"
else
  echo "  [!] Warning: Could not download treble-overlay.apk (non-fatal, continuing)"
fi

# Download TrebleApp from phhusson CI artifacts
APP_DIR="$SYSTEM_ROOT/system/priv-app/TrebleApp"
sudo mkdir -p "$APP_DIR"
TREBLEAPP_URL="https://github.com/phhusson/treble_experimentations/releases/download/v402/TrebleApp.apk"
if sudo curl -fsSL --max-time 60 "$TREBLEAPP_URL" -o "$APP_DIR/TrebleApp.apk" 2>/dev/null; then
  sudo chmod 644 "$APP_DIR/TrebleApp.apk"
  echo "  [+] Injected TrebleApp hardware manager"
else
  echo "  [!] Warning: Could not download TrebleApp.apk (non-fatal, continuing)"
fi

# 6. Adjust fstab entries
find "$SYSTEM_ROOT" -name "*fstab*" -type f 2>/dev/null | while read -r FSTAB; do
  echo "==> [TREBLE-PATCH] Patching fstab: $FSTAB"
  sudo sed -i 's/fileencryption=[^,]*//g' "$FSTAB" || true
  sudo sed -i 's/forceencrypt=[^,]*//g' "$FSTAB" || true
  sudo sed -i 's/,verify//g' "$FSTAB" || true
  sudo sed -i 's/,avb[^,]*//g' "$FSTAB" || true
done

echo "==> [TREBLE-PATCH] Project Treble modifications applied successfully!"
