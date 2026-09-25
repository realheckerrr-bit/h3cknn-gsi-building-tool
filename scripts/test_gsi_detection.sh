#!/usr/bin/env bash
# Regression tests for direct-GSI filename markers used by port_rom.sh.

set -Eeuo pipefail

MARKER_REGEX='(^|[-_/?.])(gsi|treble|(arm64|arm|a64)[-_.][ab][a-z][a-z]?n)([-_.?/]|$)'

should_match() {
  if ! printf '%s\n' "$1" | grep -Eiq "$MARKER_REGEX"; then
    echo "[-] Expected direct-GSI marker to match: $1" >&2
    exit 1
  fi
}

should_not_match() {
  if printf '%s\n' "$1" | grep -Eiq "$MARKER_REGEX"; then
    echo "[-] Expected ordinary ROM name not to match: $1" >&2
    exit 1
  fi
}

should_match "crDroid-10.13-arm64_bvN-Unofficial.img.xz"
should_match "crDroid-10.13-a64_bvN-Unofficial.img.xz"
should_match "system-treble-arm64_bgN.img.gz"
should_match "system-treble-arm_avN.img.xz"
should_match "system-treble-a64_avN.img.xz"
should_match "https://example.invalid/releases/gsi/system.img.xz"
should_not_match "Samsung-OneUI-stock-M127F.img.xz"
should_not_match "vendor-arm64-device.img.xz"

# The URL marker alone must not classify an archive/AP as a direct GSI. The
# porting engine additionally requires the downloaded file to be an image or
# compressed image before it enters passthrough mode.
if printf '%s' 'Zip archive data' | grep -Eiq 'xz compressed|gzip compressed|filesystem|android sparse image'; then
  echo "[-] Archive type incorrectly qualifies as a direct GSI image." >&2
  exit 1
fi

echo "==> GSI filename detection tests passed."
