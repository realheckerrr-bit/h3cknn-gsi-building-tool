#!/usr/bin/env bash
# ============================================================================
# build_samsung_super.sh - Safely replace only system in a stock Samsung super
#
# This is deliberately opt-in and requires a matching stock super/AP image.
# It never invents or modifies boot, vendor, odm, vbmeta, recovery, or kernel.
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOOLS_DIR="$SCRIPT_DIR/../tools"
STOCK_INPUT="${1:-}"
GSI_INPUT="${2:-}"
REQUESTED_OUTPUT_NAME="${3:-samsung-gsi-super}"
WORK_DIR="${4:-$(pwd)/workspace/samsung-super}"
OUTPUT_DIR="${5:-$(pwd)/workspace/output}"

OUTPUT_NAME=$(printf '%s' "$REQUESTED_OUTPUT_NAME" \
  | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^[.-]+//; s/[.-]+$//')
[ -n "$OUTPUT_NAME" ] || OUTPUT_NAME="samsung-gsi-super"
DEVICE_MODEL="${SAMSUNG_DEVICE_MODEL:-unknown}"

if [ -z "$STOCK_INPUT" ] || [ -z "$GSI_INPUT" ]; then
  echo "Usage: build_samsung_super.sh <stock-super|AP.tar.md5> <gsi.img|img.xz|img.gz> [output_name] [work_dir] [output_dir]" >&2
  exit 2
fi

for command_name in file lz4 simg2img tar python3 stat od sed; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "[-] ERROR: Required command is missing: $command_name" >&2
    exit 1
  fi
done
for command_name in lpmake 7z; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "[-] ERROR: Required Samsung super command is missing: $command_name" >&2
    exit 1
  fi
done

if [ ! -f "$STOCK_INPUT" ] || [ ! -f "$GSI_INPUT" ]; then
  echo "[-] ERROR: Stock super/AP and GSI inputs must be existing files." >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
TEMP_DIR="$WORK_DIR/.${OUTPUT_NAME}.tmp.$$"
mkdir -p "$TEMP_DIR"
cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

echo "==> [SAMSUNG-SUPER] Stock input: $(basename "$STOCK_INPUT")"
echo "==> [SAMSUNG-SUPER] GSI input: $(basename "$GSI_INPUT")"

# Accept either a standalone super image or a stock AP tar containing
# super.img.lz4.  The AP is only used as the source of stock logical partitions.
STOCK_SOURCE="$STOCK_INPUT"
STOCK_TYPE=$(file -b "$STOCK_SOURCE" | tr '[:upper:]' '[:lower:]')
if printf '%s' "$STOCK_TYPE" | grep -Eiq 'tar archive' \
  || printf '%s' "$STOCK_INPUT" | grep -Eiq '\.tar(\.md5)?$'; then
  AP_DIR="$TEMP_DIR/ap"
  mkdir -p "$AP_DIR"
  7z x -y "$STOCK_INPUT" -o"$AP_DIR" >/dev/null
  STOCK_SOURCE=$(find "$AP_DIR" -type f \( -name 'super.img.lz4' -o -name 'super.img' \) -print -quit)
  if [ -z "$STOCK_SOURCE" ]; then
    echo "[-] ERROR: AP archive does not contain super.img or super.img.lz4." >&2
    exit 1
  fi
fi

STOCK_IMAGE="$TEMP_DIR/stock.super.img"
STOCK_EXT="${STOCK_SOURCE##*.}"
STOCK_EXT=$(printf '%s' "$STOCK_EXT" | tr '[:upper:]' '[:lower:]')
if [ "$STOCK_EXT" = "lz4" ]; then
  lz4 -dc -- "$STOCK_SOURCE" > "$STOCK_IMAGE"
else
  cp -- "$STOCK_SOURCE" "$STOCK_IMAGE"
fi

STOCK_MAGIC=$(od -An -tx1 -N4 "$STOCK_IMAGE" 2>/dev/null | tr -d '[:space:]')
if [ "$STOCK_MAGIC" = "3aff26ed" ]; then
  simg2img "$STOCK_IMAGE" "$TEMP_DIR/stock.super.raw.img"
  STOCK_IMAGE="$TEMP_DIR/stock.super.raw.img"
fi

if [ ! -s "$STOCK_IMAGE" ]; then
  echo "[-] ERROR: Stock super image is empty." >&2
  exit 1
fi

# Decompress the GSI without changing its filesystem contents.
GSI_IMAGE="$TEMP_DIR/gsi.img"
GSI_EXT="${GSI_INPUT##*.}"
GSI_EXT=$(printf '%s' "$GSI_EXT" | tr '[:upper:]' '[:lower:]')
case "$GSI_EXT" in
  xz) xz -dc -- "$GSI_INPUT" > "$GSI_IMAGE" ;;
  gz) gzip -dc -- "$GSI_INPUT" > "$GSI_IMAGE" ;;
  img) cp -- "$GSI_INPUT" "$GSI_IMAGE" ;;
  *)
    echo "[-] ERROR: GSI must be .img, .img.xz, or .img.gz." >&2
    exit 1
    ;;
esac

GSI_MAGIC=$(od -An -tx1 -N4 "$GSI_IMAGE" 2>/dev/null | tr -d '[:space:]')
if [ "$GSI_MAGIC" = "3aff26ed" ]; then
  simg2img "$GSI_IMAGE" "$TEMP_DIR/gsi.raw.img"
  GSI_IMAGE="$TEMP_DIR/gsi.raw.img"
fi

if [ ! -s "$GSI_IMAGE" ]; then
  echo "[-] ERROR: GSI image is empty." >&2
  exit 1
fi

PARTITION_DIR="$TEMP_DIR/partitions"
mkdir -p "$PARTITION_DIR"
if ! python3 "$TOOLS_DIR/lpunpack.py" "$STOCK_IMAGE" "$PARTITION_DIR" >/dev/null; then
  echo "[-] ERROR: Could not unpack logical partitions from stock super." >&2
  exit 1
fi

META_JSON="$TEMP_DIR/metadata.json"
if ! python3 "$TOOLS_DIR/lpunpack.py" --info --format json "$STOCK_IMAGE" > "$META_JSON"; then
  echo "[-] ERROR: Could not read usable logical-partition metadata from stock super:" >&2
  cat "$META_JSON" >&2
  exit 1
fi

# Convert the metadata to a small, shell-safe TSV description.  Group limits
# and partition names come from the user's stock image, never from assumptions
# about a particular M12 regional firmware.
META_TSV="$TEMP_DIR/metadata.tsv"
if ! python3 - "$META_JSON" > "$META_TSV" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

device = data.get("block_devices", [{}])[0]
print("DEVICE\t{}\t{}".format(device.get("name", "super"), int(device.get("size", 0))))
print("META\t{}\t{}".format(
    int(data.get("metadata_max_size", 65536)),
    int(data.get("metadata_slot_count", 2)),
))
for group in data.get("group_table", []):
    print("GROUP\t{}\t{}".format(group["name"], int(group.get("maximum_size", 0))))
for partition in data.get("partition_table", []):
    print("PART\t{}\t{}".format(partition["name"], partition["group_name"]))
PY
then
  echo "[-] ERROR: Stock super metadata was not valid JSON:" >&2
  cat "$META_JSON" >&2
  exit 1
fi

declare -A GROUP_MAX GROUP_BYTES GROUP_PARTITION_SEEN
DEVICE_NAME=""
DEVICE_SIZE=0
METADATA_SIZE=65536
METADATA_SLOTS=2
PARTITIONS=()

while IFS=$'\t' read -r kind first second; do
  case "$kind" in
    DEVICE) DEVICE_NAME="$first"; DEVICE_SIZE="$second" ;;
    META) METADATA_SIZE="$first"; METADATA_SLOTS="$second" ;;
    GROUP) GROUP_MAX["$first"]="$second" ;;
    PART) PARTITIONS+=("$first"$'\t'"$second") ;;
  esac
done < "$META_TSV"

if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_SIZE" -le 0 ] || [ "${#PARTITIONS[@]}" -eq 0 ]; then
  echo "[-] ERROR: Could not read usable logical-partition metadata from stock super." >&2
  exit 1
fi

SYSTEM_FOUND=0
LPM_ARGS=(
  --metadata-size "$METADATA_SIZE"
  --super-name super
  --metadata-slots "$METADATA_SLOTS"
  --device "${DEVICE_NAME}:${DEVICE_SIZE}"
)

# Add every original group. A zero maximum is legal in some metadata versions;
# derive a conservative limit from the physical device in that case.
for group in "${!GROUP_MAX[@]}"; do
  group_limit="${GROUP_MAX[$group]}"
  if [ "$group_limit" -le 0 ]; then
    group_limit=$((DEVICE_SIZE - 4 * 1024 * 1024))
  fi
  LPM_ARGS+=(--group "${group}:${group_limit}")
done

for partition_entry in "${PARTITIONS[@]}"; do
  IFS=$'\t' read -r partition_name group_name <<< "$partition_entry"
  if [ "$partition_name" = "system_a" ] || [ "$partition_name" = "system_b" ]; then
    echo "[-] ERROR: Stock super uses slot-suffixed system partitions; refusing an unsafe replacement." >&2
    exit 1
  fi

  if [ "$partition_name" = "system" ]; then
    IMAGE_PATH="$GSI_IMAGE"
    SYSTEM_FOUND=1
  else
    IMAGE_PATH="$PARTITION_DIR/${partition_name}.img"
    if [ ! -f "$IMAGE_PATH" ]; then
      echo "[-] ERROR: Stock partition image is missing after unpack: $partition_name" >&2
      exit 1
    fi
  fi

  IMAGE_BYTES=$(stat -c '%s' "$IMAGE_PATH")
  IMAGE_BYTES=$(( ((IMAGE_BYTES + 4095) / 4096) * 4096 ))
  GROUP_BYTES["$group_name"]=$(( ${GROUP_BYTES[$group_name]:-0} + IMAGE_BYTES ))
  GROUP_PARTITION_SEEN["$group_name"]=1
  LPM_ARGS+=(--partition "${partition_name}:readonly:${IMAGE_BYTES}:${group_name}" --image "${partition_name}=${IMAGE_PATH}")
done

if [ "$SYSTEM_FOUND" -ne 1 ]; then
  echo "[-] ERROR: Stock super has no unsuffixed system partition; refusing to guess." >&2
  exit 1
fi

for group in "${!GROUP_BYTES[@]}"; do
  group_limit="${GROUP_MAX[$group]:-0}"
  if [ "$group_limit" -le 0 ]; then
    group_limit=$((DEVICE_SIZE - 4 * 1024 * 1024))
  fi
  if [ "${GROUP_BYTES[$group]}" -gt "$group_limit" ]; then
    echo "[-] ERROR: Rebuilt ${group} group needs ${GROUP_BYTES[$group]} bytes, limit is ${group_limit}." >&2
    echo "    The GSI is too large for this stock super image." >&2
    exit 1
  fi
done

SUPER_OUT="$OUTPUT_DIR/super.img"
TAR_OUT="$OUTPUT_DIR/${OUTPUT_NAME}.tar"
rm -f -- "$SUPER_OUT" "$TAR_OUT"

echo "==> [SAMSUNG-SUPER] Rebuilding stock logical-partition metadata..."
lpmake "${LPM_ARGS[@]}" --sparse --output "$SUPER_OUT"

if [ ! -s "$SUPER_OUT" ]; then
  echo "[-] ERROR: lpmake produced an empty super image." >&2
  exit 1
fi

CHECK_DIR="$TEMP_DIR/check"
mkdir -p "$CHECK_DIR"
python3 "$TOOLS_DIR/lpunpack.py" "$SUPER_OUT" "$CHECK_DIR" >/dev/null
if [ ! -s "$CHECK_DIR/system.img" ]; then
  echo "[-] ERROR: Rebuilt super image does not contain system.img." >&2
  exit 1
fi

tar -cf "$TAR_OUT" -C "$OUTPUT_DIR" "$(basename "$SUPER_OUT")"
cat > "$OUTPUT_DIR/${OUTPUT_NAME}.build-info.txt" <<EOF
Samsung super GSI package
=========================
Device model: $DEVICE_MODEL
Stock source: $(basename "$STOCK_INPUT")
GSI source: $(basename "$GSI_INPUT")
Image mode: stock-super-system-replacement
Preserved: stock vendor, product, odm, system_ext, boot, recovery, vbmeta, and kernel files
Replaced: system logical partition only
Warning: Odin flashing still requires the exact matching AP/firmware and device-specific multidisabler/kernel procedure.
EOF

echo "==> [SAMSUNG-SUPER] Package created: $TAR_OUT"
echo "==> [SAMSUNG-SUPER] Super image:    $SUPER_OUT"
echo "==> [SAMSUNG-SUPER] Validation passed: system partition present"
