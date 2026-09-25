#!/usr/bin/env bash
# ============================================================================
# check_gsi_compatibility.sh - preflight checks for a published GSI
#
# A GSI is the system partition. The target device still supplies matching
# vendor HALs, kernel modules, DTB, boot ramdisk, vbmeta, and recovery. This
# script rejects metadata that is definitely incompatible and records the
# remaining device-specific requirements in the release.
# ============================================================================

set -Eeuo pipefail

BUILD_PROP="${1:-}"
TARGET_MODEL="${2:-generic}"
REPORT_PATH="${3:-compatibility-report.txt}"

if [ -z "$BUILD_PROP" ] || [ ! -f "$BUILD_PROP" ]; then
  echo "[-] ERROR: build.prop was not found: ${BUILD_PROP:-<empty>}" >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT_PATH")"

prop() {
  local key="$1"
  # Ignore commented properties and only use the first active assignment.
  awk -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, wanted "=") == 1) {
        sub(/^[^=]*=/, "", line)
        sub(/[[:space:]].*$/, "", line)
        print line
        exit
      }
    }
  ' "$BUILD_PROP"
}

ABI_LIST="$(prop 'ro.product.system.cpu.abilist' || true)"
[ -n "$ABI_LIST" ] || ABI_LIST="$(prop 'ro.product.cpu.abilist' || true)"
ABI="$(prop 'ro.product.system.cpu.abi' || true)"
[ -n "$ABI" ] || ABI="$(prop 'ro.product.cpu.abi' || true)"
TREBLE="$(prop 'ro.treble.enabled' || true)"
VNDK="$(prop 'ro.vndk.version' || true)"
SDK="$(prop 'ro.build.version.sdk' || true)"
ANDROID="$(prop 'ro.build.version.release' || true)"
DEVICE="$(prop 'ro.product.system.device' || true)"
[ -n "$DEVICE" ] || DEVICE="$(prop 'ro.product.device' || true)"
MODEL="$(prop 'ro.product.system.model' || true)"
[ -n "$MODEL" ] || MODEL="$(prop 'ro.product.model' || true)"

STATUS="PASS"
FAILURES=()
WARNINGS=()

fail() {
  STATUS="FAIL"
  FAILURES+=("$1")
}

warn() {
  [ "$STATUS" = "FAIL" ] || STATUS="WARN"
  WARNINGS+=("$1")
}

if [ -n "$ABI_LIST" ]; then
  case ",$ABI_LIST," in
    *,arm64-v8a,*|*,arm64,*) ;;
    *) fail "The GSI does not advertise an ARM64 ABI (abilist: $ABI_LIST)." ;;
  esac
elif [ -n "$ABI" ]; then
  case "$ABI" in
    arm64-v8a|arm64) ;;
    *) fail "The GSI advertises '$ABI', not an ARM64 ABI." ;;
  esac
else
  warn "CPU ABI properties are missing; ARM64 compatibility could not be proven."
fi

case "$TREBLE" in
  true|1) ;;
  false|0) fail "ro.treble.enabled is disabled; this is not a usable Treble GSI." ;;
  *) warn "ro.treble.enabled is missing; vendor/system compatibility could not be proven." ;;
esac

if [ -z "$VNDK" ]; then
  warn "ro.vndk.version is missing; the target vendor VNDK must be checked manually."
fi

if [ -n "$SDK" ] && [ "$SDK" -lt 29 ] 2>/dev/null; then
  fail "Android SDK $SDK predates the Android 10 Treble baseline."
fi

case "$TARGET_MODEL" in
  generic|""|unknown) ;;
  SM-M127*|SM-F127*|SM-A127*)
    warn "Galaxy M12/A12 Exynos 850 requires the exact matching vendor, boot/kernel, DTB, vbmeta, recovery, and device-specific multidisabler procedure."
    ANDROID_MAJOR="${ANDROID%%.*}"
    if [[ "$ANDROID_MAJOR" =~ ^[0-9]+$ ]] && [ "$ANDROID_MAJOR" -ge 14 ]; then
      warn "Android $ANDROID on Exynos 850 commonly needs an exact-device GSI-compatible kernel/boot image; supply boot_url in the Samsung workflow instead of assuming stock boot will work."
    fi
    ;;
  *)
    warn "Target model '$TARGET_MODEL' is device-specific; use only its matching vendor, boot/kernel, DTB, vbmeta, and recovery."
    ;;
esac

# This warning is intentional, including for PASS: it is the common reason a
# syntactically valid GSI does not boot on Samsung devices.
warn "No universal kernel or hardware driver is embedded. The target supplies vendor HALs, kernel modules, DTB, boot ramdisk, vbmeta, and recovery."

{
  printf '%s\n' 'GSI compatibility preflight'
  printf '%s\n' '==========================='
  printf 'Status: %s\n' "$STATUS"
  printf 'Target model: %s\n' "$TARGET_MODEL"
  printf 'Source build.prop: %s\n' "$(basename "$BUILD_PROP")"
  printf 'GSI device marker: %s\n' "${DEVICE:-unknown}"
  printf 'GSI model marker: %s\n' "${MODEL:-unknown}"
  printf 'Android version: %s (SDK %s)\n' "${ANDROID:-unknown}" "${SDK:-unknown}"
  printf 'CPU ABI: %s\n' "${ABI_LIST:-${ABI:-unknown}}"
  printf 'Treble: %s\n' "${TREBLE:-unknown}"
  printf 'VNDK: %s\n' "${VNDK:-unknown}"
  printf '\nHard failures:\n'
  if [ "${#FAILURES[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
  else
    printf -- '- %s\n' "${FAILURES[@]}"
  fi
  printf '\nWarnings:\n'
  if [ "${#WARNINGS[@]}" -eq 0 ]; then
    printf '%s\n' 'none'
  else
    printf -- '- %s\n' "${WARNINGS[@]}"
  fi
} | tee "$REPORT_PATH"

if [ "$STATUS" = "FAIL" ]; then
  echo "[-] GSI compatibility preflight failed; no release should be published." >&2
  exit 1
fi

echo "==> GSI compatibility preflight passed with status: $STATUS"
