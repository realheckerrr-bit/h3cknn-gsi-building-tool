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
  echo "$1" | grep -qiP '(drive\.google\.com|docs\.google\.com/.*drive)'
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
  aria2c -x16 -s16 -j4 --continue=true --check-certificate=false "$ROM_URL" \
    || wget --no-check-certificate "$ROM_URL"
  # BUG FIX: exclude aria2 temp files reliably
  ROM_FILE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \
    ! -name "*.aria2" ! -name "*.tmp" | sort | head -n 1)
  if [ -z "$ROM_FILE" ]; then
    echo "[-] ERROR: Download failed. No file found in $DOWNLOAD_DIR"
    exit 1
  fi
fi

echo "==> [EXTRACT] Downloaded file: $(basename "$ROM_FILE") ($(du -h "$ROM_FILE" | cut -f1))"

cd "$EXTRACT_DIR"
echo "==> [EXTRACT] Unpacking archive container..."

# BUG FIX: Use `file` command for reliable format detection instead of just extension
# (URLs can have query params or mismatched extensions)
FILE_TYPE=$(file -b "$ROM_FILE" | tr '[:upper:]' '[:lower:]')
FILE_EXT="${ROM_FILE##*.}"
FILE_EXT=$(echo "$FILE_EXT" | cut -d'?' -f1 | tr '[:upper:]' '[:lower:]')

if echo "$FILE_TYPE" | grep -q "zip archive"; then
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR"
elif echo "$FILE_TYPE" | grep -q "gzip\|tar"; then
  tar -xf "$ROM_FILE" -C "$EXTRACT_DIR"
elif echo "$FILE_TYPE" | grep -q "7-zip\|7z"; then
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR"
elif [ "$FILE_EXT" = "bin" ] || echo "$FILE_TYPE" | grep -q "data"; then
  # Could be payload.bin
  cp "$ROM_FILE" "$EXTRACT_DIR/payload.bin"
elif [ "$FILE_EXT" = "img" ]; then
  cp "$ROM_FILE" "$EXTRACT_DIR/input.img"
else
  # Fallback: try 7z, then treat as single image
  7z x -y "$ROM_FILE" -o"$EXTRACT_DIR" 2>/dev/null || cp "$ROM_FILE" "$EXTRACT_DIR/"
fi

# 1. Check for payload.bin (any depth)
PAYLOAD_PATH=$(find "$EXTRACT_DIR" -name "payload.bin" 2>/dev/null | head -n 1)
if [ -n "$PAYLOAD_PATH" ]; then
  echo "==> [EXTRACT] Detected payload.bin at $PAYLOAD_PATH. Dumping partitions..."
  payload-dumper-go -o "$EXTRACT_DIR/payload_out" "$PAYLOAD_PATH"
  find "$EXTRACT_DIR/payload_out" -name "*.img" -exec mv {} "$EXTRACT_DIR/" \;
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

echo "==> [EXTRACT] Successfully extracted system partition to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR" | head -n 20
