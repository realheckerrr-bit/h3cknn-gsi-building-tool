#!/usr/bin/env bash
# ==============================================================================
# extract_rom.sh - High-speed multi-format ROM and partition unpacker
# Handles: payload.bin, super.img (dynamic partitions), .dat.br, EROFS, EXT4
# ==============================================================================

set -eo pipefail

ROM_URL="${1:-}"
WORK_DIR="${2:-$(pwd)/workspace}"
DOWNLOAD_DIR="$WORK_DIR/download"
EXTRACT_DIR="$WORK_DIR/extracted"
OUTPUT_DIR="$WORK_DIR/system_root"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TOOLS_DIR="$SCRIPT_DIR/../tools"

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$OUTPUT_DIR"

if [ -z "$ROM_URL" ]; then
  echo "[-] ERROR: ROM_URL is required as argument 1."
  echo "Usage: ./extract_rom.sh <ROM_URL> [WORK_DIR]"
  exit 1
fi

echo "==> [EXTRACT] Starting download from: $ROM_URL"
cd "$DOWNLOAD_DIR"

# ── Google Drive URL detection ───────────────────────────────────────────────
# Supports all GDrive sharing link formats including /file/d/, /open?id=, /uc?id=
is_gdrive_url() {
  [[ "$1" == *drive.google.com* || "$1" == *docs.google.com/*drive* ]]
}

if is_gdrive_url "$ROM_URL"; then
  echo "==> [EXTRACT] Detected Google Drive URL — using gdrive_download.sh..."
  ROM_FILE=$(bash "$SCRIPT_DIR/gdrive_download.sh" "$ROM_URL" "$DOWNLOAD_DIR")
  if [ -z "$ROM_FILE" ] || [ ! -f "$ROM_FILE" ]; then
    echo "[-] ERROR: Google Drive download failed."
    exit 1
  fi
else
  # Normal download with aria2c (multi-connection), fall back to wget
  aria2c -x16 -s16 -j4 --continue=true --check-certificate=false \
    --connect-timeout=30 --timeout=60 --max-tries=3 --retry-wait=5 \
    --file-allocation=none "$ROM_URL" \
    || wget --no-check-certificate --timeout=60 --tries=3 "$ROM_URL"
  # Ignore aria2 bookkeeping/partial files and choose the largest completed
  # candidate. This prevents a failed first download from being mistaken for
  # the ROM when wget creates a second file.
  ROM_FILE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \
    ! -name "*.aria2" ! -name "*.tmp" ! -name "*.part" -size +0c \
    -printf '%s\t%p\n' | sort -nr | head -n 1 | cut -f2-)
  if [ -z "$ROM_FILE" ]; then
    echo "[-] ERROR: Download failed. No file found in $DOWNLOAD_DIR"
    exit 1
  fi
fi

echo "==> [EXTRACT] Downloaded file: $(basename "$ROM_FILE") ($(du -h "$ROM_FILE" | cut -f1))"

# Direct ROM links often return an HTML login/404 page with HTTP 200. Catch it
# here so the later image parser reports the real download problem instead of
# producing a misleading payload/system.img failure.
DOWNLOADED_TYPE=$(file -b "$ROM_FILE" | tr '[:upper:]' '[:lower:]')
if echo "$DOWNLOADED_TYPE" | grep -Eiq 'html document|html,|empty$'; then
  echo "[-] ERROR: Downloaded input is not a ROM/image ($DOWNLOADED_TYPE)." >&2
  exit 1
fi

# Always retain an absolute source path. The master pipeline may be called from
# a relative work directory, while later preservation must still find the
# downloaded file after this script changes directory.
ROM_FILE="$(realpath "$ROM_FILE")"

# Keep the resolved local input path available to the master pipeline.  Direct
# GSI inputs can be passed through without mounting and rebuilding them, which
# preserves sparse-image layout and other boot-sensitive metadata.
printf '%s\n' "$ROM_FILE" > "$WORK_DIR/source-input.path"

cd "$EXTRACT_DIR"
echo "==> [EXTRACT] Unpacking archive container..."

# BUG FIX: Use `file` command for reliable format detection instead of just extension
# (URLs can have query params or mismatched extensions)
FILE_TYPE=$(file -b "$ROM_FILE" | tr '[:upper:]' '[:lower:]')
FILE_EXT="${ROM_FILE##*.}"
FILE_EXT=$(echo "$FILE_EXT" | cut -d'?' -f1 | tr '[:upper:]' '[:lower:]')
FILE_MAGIC=$(od -An -tx1 -N4 "$ROM_FILE" 2>/dev/null | tr -d '[:space:]' || true)

# A recognized compressed/raw GSI does not need to be mounted and copied: the
# porting stage intentionally preserves it byte-for-byte. Extract only
# build.prop so compatibility reporting still works, then let port_rom.sh take
# its normal preservation path. If the image is EROFS or the marker is
# ambiguous, fall through to the full extractor below.
DIRECT_GSI_HINT=0
if printf '%s\n%s' "$(basename "$ROM_FILE")" "$ROM_URL" \
  | grep -Eiq '(^|[-_/?.])(gsi|treble|arm64|a64[-_.][ab][a-z][a-z]?n)([-_.?/]|$)'; then
  DIRECT_GSI_HINT=1
fi
DIRECT_IMAGE_TYPE=$(file -b "$ROM_FILE" | tr '[:upper:]' '[:lower:]')
if [ "$DIRECT_GSI_HINT" = "1" ] \
  && { printf '%s' "$DIRECT_IMAGE_TYPE" | grep -Eiq \
       'xz compressed|gzip compressed|filesystem|android sparse image' \
       || [ "$FILE_EXT" = "xz" ] || [ "$FILE_EXT" = "gz" ]; }; then
  if bash "$SCRIPT_DIR/extract_direct_gsi_prop.sh" \
    "$ROM_FILE" "$OUTPUT_DIR" "$WORK_DIR"; then
    exit 0
  fi
fi

# Google Drive downloads are deliberately saved without the original extension.
# Detect ZIP containers from their magic bytes so an OTA ZIP is not mistaken for
# a raw payload.bin merely because `file` reports generic Android/data content.
if [ "$FILE_MAGIC" = "504b0304" ] || echo "$FILE_TYPE" | grep -q "zip archive"; then
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR"
elif echo "$FILE_TYPE" | grep -q "xz compressed" || [ "$FILE_EXT" = "xz" ]; then
  # Accept a direct compressed GSI image as an input source.  This is useful
  # for rebuilding a known-good community GSI with our metadata/DSU outputs.
  xz -dc "$ROM_FILE" > "$EXTRACT_DIR/system.img"
elif echo "$FILE_TYPE" | grep -q "gzip compressed" || [ "$FILE_EXT" = "gz" ]; then
  gzip -dc "$ROM_FILE" > "$EXTRACT_DIR/system.img"
elif echo "$FILE_TYPE" | grep -q "gzip\|tar"; then
  tar -xf "$ROM_FILE" -C "$EXTRACT_DIR"
elif echo "$FILE_TYPE" | grep -q "7-zip\|7z"; then
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR"
elif echo "$FILE_TYPE" | grep -Eq "filesystem|android sparse"; then
  # `file` describes raw ext4/EROFS images as filesystem *data*.  Check for
  # filesystem signatures before the generic `data` fallback, otherwise a
  # direct GSI .img (or an extensionless Drive download) is renamed to
  # payload.bin and never reaches the preservation path.
  cp "$ROM_FILE" "$EXTRACT_DIR/system.img"
elif [ "$FILE_EXT" = "bin" ] || echo "$FILE_TYPE" | grep -q "data"; then
  # Could be payload.bin
  cp "$ROM_FILE" "$EXTRACT_DIR/payload.bin"
elif [ "$FILE_EXT" = "img" ]; then
  # A direct uncompressed GSI is already the system partition.  Normalize its
  # name so the common system-image discovery path can process it below.
  cp "$ROM_FILE" "$EXTRACT_DIR/system.img"
else
  # Fallback: try 7z, then treat as single image
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR" 2>/dev/null || cp "$ROM_FILE" "$EXTRACT_DIR/"
fi

# 1. Check for a real Android OTA payload (any depth).
# Some recovery ROM ZIPs contain an unrelated file named payload.bin.  Passing
# that file to payload-dumper-go makes the whole pipeline exit with code 1,
# even though the ZIP may also contain usable system/super images.
PAYLOAD_PATH=""
while IFS= read -r candidate; do
  PAYLOAD_MAGIC=$(od -An -tx1 -N4 "$candidate" 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$PAYLOAD_MAGIC" = "43724155" ]; then
    PAYLOAD_PATH="$candidate"
    break
  elif [ "$PAYLOAD_MAGIC" = "504b0304" ]; then
    # A few recovery ROMs ship an OTA ZIP with the misleading filename
    # payload.bin.  Unpack it so system.new.dat.br/system.img can be found.
    PAYLOAD_ZIP_DIR="$EXTRACT_DIR/payload_zip"
    mkdir -p "$PAYLOAD_ZIP_DIR"
    echo "  [!] payload.bin is a ZIP container; extracting its partition files."
    7z x -y "$candidate" -o"$PAYLOAD_ZIP_DIR" >/dev/null
  fi
  if [ "$PAYLOAD_MAGIC" != "504b0304" ]; then
    echo "  [!] Ignoring non-OTA payload file: $candidate"
  fi
done < <(find "$EXTRACT_DIR" -type f -name "payload.bin" -print 2>/dev/null)

if [ -n "$PAYLOAD_PATH" ]; then
  echo "==> [EXTRACT] Detected Android OTA payload at $PAYLOAD_PATH. Dumping partitions..."
  PAYLOAD_OUT="$EXTRACT_DIR/payload_out"
  mkdir -p "$PAYLOAD_OUT"
  if payload-dumper-go -o "$PAYLOAD_OUT" "$PAYLOAD_PATH"; then
    find "$PAYLOAD_OUT" -type f -name "*.img" -exec mv -f {} "$EXTRACT_DIR/" \;
  else
    echo "[-] WARNING: payload-dumper-go could not unpack the OTA payload; checking for images already in the ROM."
  fi
else
  echo "==> [EXTRACT] No valid Android OTA payload found; checking extracted ROM contents."
fi

# 2. Check for super.img (Dynamic Partitions)
SUPER_IMG=$(find "$EXTRACT_DIR" -maxdepth 2 -name "super.img" 2>/dev/null | head -n 1)
if [ -n "$SUPER_IMG" ]; then
  echo "==> [EXTRACT] Detected Dynamic Partition super.img: $SUPER_IMG"
  # Convert sparse -> raw if needed
  if simg2img "$SUPER_IMG" "$EXTRACT_DIR/super.raw.img" 2>/dev/null; then
    mv "$EXTRACT_DIR/super.raw.img" "$SUPER_IMG"
  fi
  mkdir -p "$EXTRACT_DIR/super_unpacked"
  # BUG FIX: Use Python lpunpack.py (binary lpunpack from ErfanGSIs was 404)
  python3 "$TOOLS_DIR/lpunpack.py" "$SUPER_IMG" "$EXTRACT_DIR/super_unpacked" 2>/dev/null || true
  find "$EXTRACT_DIR/super_unpacked" -name "*.img" -exec mv {} "$EXTRACT_DIR/" \;
fi

# 3. Check for Brotli-compressed sparse data (system.new.dat.br)
DAT_BR=$(find "$EXTRACT_DIR" -name "system.new.dat.br" 2>/dev/null | head -n 1)
if [ -n "$DAT_BR" ]; then
  DAT_DIR=$(dirname "$DAT_BR")
  echo "==> [EXTRACT] Decompressing system.new.dat.br..."
  brotli -d "$DAT_BR" -o "$DAT_DIR/system.new.dat"
  TRANSFER_LIST="$DAT_DIR/system.transfer.list"
  if [ -f "$TRANSFER_LIST" ]; then
    python3 "$TOOLS_DIR/sdat2img.py" "$TRANSFER_LIST" "$DAT_DIR/system.new.dat" "$EXTRACT_DIR/system.img"
  else
    echo "[-] WARNING: system.transfer.list not found next to system.new.dat.br, skipping sdat2img."
  fi
fi

# 4. Locate system.img
# BUG FIX: Previous 'find' -o expression may not work as expected with -name flags
SYSTEM_IMG=$(find "$EXTRACT_DIR" \( -name "system.img" -o -name "system_a.img" \) 2>/dev/null | head -n 1)
if [ -z "$SYSTEM_IMG" ]; then
  echo "[-] ERROR: system.img could not be located in extracted contents."
  echo "    Files found:"
  ls -la "$EXTRACT_DIR"
  exit 1
fi

echo "==> [EXTRACT] Processing system image: $SYSTEM_IMG"

# Convert from Android sparse image if needed
if simg2img "$SYSTEM_IMG" "$EXTRACT_DIR/system.raw.img" 2>/dev/null; then
  echo "==> [EXTRACT] Converted sparse image to raw."
  mv "$EXTRACT_DIR/system.raw.img" "$SYSTEM_IMG"
fi

# 5. Extract filesystem contents (EROFS or EXT4)
FS_TYPE=$(blkid -o value -s TYPE "$SYSTEM_IMG" 2>/dev/null || true)
echo "==> [EXTRACT] Filesystem type detected: ${FS_TYPE:-unknown}"

MOUNT_DIR="$WORK_DIR/mnt_system"
sudo mkdir -p "$MOUNT_DIR"

if [ "$FS_TYPE" = "erofs" ]; then
  echo "==> [EXTRACT] Extracting EROFS filesystem..."
  # Try mount first, fall back to fsck.erofs --extract
  if ! sudo mount -o loop,ro "$SYSTEM_IMG" "$MOUNT_DIR" 2>/dev/null; then
    fsck.erofs --extract="$OUTPUT_DIR" "$SYSTEM_IMG"
  else
    sudo cp -a "$MOUNT_DIR"/. "$OUTPUT_DIR/"
    sudo umount "$MOUNT_DIR"
  fi
else
  echo "==> [EXTRACT] Mounting EXT4 / Generic filesystem..."
  sudo mount -o loop,ro "$SYSTEM_IMG" "$MOUNT_DIR"
  sudo cp -a "$MOUNT_DIR"/. "$OUTPUT_DIR/"
  sudo umount "$MOUNT_DIR"
fi

# Android images commonly keep build.prop root-readable only.  The porting
# pipeline needs it for detection and release metadata, but changing every
# extracted file's mode would damage permissions if an OEM image is rebuilt.
# Make only build.prop files readable; the source image itself is untouched.
if [ "$(id -u)" -eq 0 ]; then
  find "$OUTPUT_DIR" -type f -name build.prop -exec chmod 644 {} + 2>/dev/null || true
else
  sudo find "$OUTPUT_DIR" -type f -name build.prop -exec sudo chmod 644 {} + 2>/dev/null || true
fi

echo "==> [EXTRACT] Successfully extracted system partition to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR" | head -n 20
