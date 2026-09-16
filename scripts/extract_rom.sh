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

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$OUTPUT_DIR"

if [ -z "$ROM_URL" ]; then
  echo "[-] ERROR: ROM_URL is required as argument 1."
  echo "Usage: ./extract_rom.sh <ROM_URL> [WORK_DIR]"
  exit 1
fi

echo "==> [EXTRACT] Starting download from: $ROM_URL"
cd "$DOWNLOAD_DIR"

# Download with aria2c for multi-connection speed
aria2c -x16 -s16 -j4 --continue=true --check-certificate=false "$ROM_URL" || wget --no-check-certificate "$ROM_URL"

ROM_FILE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f ! -name "*.aria2" | head -n 1)
if [ -z "$ROM_FILE" ]; then
  echo "[-] ERROR: Download failed. No file found in $DOWNLOAD_DIR"
  exit 1
fi

echo "==> [EXTRACT] Downloaded file: $(basename "$ROM_FILE") ($(du -h "$ROM_FILE" | cut -f1))"

cd "$EXTRACT_DIR"
echo "==> [EXTRACT] Unpacking archive container..."

FILE_EXT="${ROM_FILE##*.}"
case "$FILE_EXT" in
  zip|ZIP)
    7z x -y "$ROM_FILE" -o"$EXTRACT_DIR"
    ;;
  tgz|tar|gz)
    tar -xf "$ROM_FILE" -C "$EXTRACT_DIR"
    ;;
  bin)
    cp "$ROM_FILE" "$EXTRACT_DIR/payload.bin"
    ;;
  img)
    cp "$ROM_FILE" "$EXTRACT_DIR/input.img"
    ;;
  *)
    # Try 7z fallback for unknown container
    7z x -y "$ROM_FILE" -o"$EXTRACT_DIR" || cp "$ROM_FILE" "$EXTRACT_DIR/"
    ;;
esac

# 1. Check for payload.bin
if [ -f "$EXTRACT_DIR/payload.bin" ] || [ -f "$EXTRACT_DIR"/*/payload.bin ]; then
  PAYLOAD_PATH=$(find "$EXTRACT_DIR" -name "payload.bin" | head -n 1)
  echo "==> [EXTRACT] Detected payload.bin at $PAYLOAD_PATH. Dumping partitions..."
  payload-dumper-go -o "$EXTRACT_DIR/payload_out" "$PAYLOAD_PATH"
  find "$EXTRACT_DIR/payload_out" -name "*.img" -exec mv {} "$EXTRACT_DIR/" \;
fi

# 2. Check for super.img (Dynamic Partitions)
SUPER_IMG=$(find "$EXTRACT_DIR" -maxdepth 2 -name "super.img" | head -n 1)
if [ -n "$SUPER_IMG" ]; then
  echo "==> [EXTRACT] Detected Dynamic Partition super.img: $SUPER_IMG"
  # Check if sparse
  if simg2img "$SUPER_IMG" "$EXTRACT_DIR/super.raw.img" 2>/dev/null; then
    mv "$EXTRACT_DIR/super.raw.img" "$SUPER_IMG"
  fi
  mkdir -p "$EXTRACT_DIR/super_unpacked"
  lpunpack "$SUPER_IMG" "$EXTRACT_DIR/super_unpacked" || true
  find "$EXTRACT_DIR/super_unpacked" -name "*.img" -exec mv {} "$EXTRACT_DIR/" \;
fi

# 3. Check for Brotli-compressed sparse data (system.new.dat.br)
DAT_BR=$(find "$EXTRACT_DIR" -name "system.new.dat.br" | head -n 1)
if [ -n "$DAT_BR" ]; then
  DAT_DIR=$(dirname "$DAT_BR")
  echo "==> [EXTRACT] Decompressing system.new.dat.br..."
  brotli -d "$DAT_BR" -o "$DAT_DIR/system.new.dat"
  SCRIPT_PATH=$(dirname "$(realpath "$0")")
  python3 "$SCRIPT_PATH/../tools/sdat2img.py" "$DAT_DIR/system.transfer.list" "$DAT_DIR/system.new.dat" "$EXTRACT_DIR/system.img"
fi

# 4. Locate system.img
SYSTEM_IMG=$(find "$EXTRACT_DIR" -name "system.img" -o -name "system_a.img" | head -n 1)
if [ -z "$SYSTEM_IMG" ]; then
  echo "[-] ERROR: system.img could not be located in extracted contents."
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
FS_TYPE=$(blkid -o value -s TYPE "$SYSTEM_IMG" || true)
echo "==> [EXTRACT] Filesystem type detected: ${FS_TYPE:-unknown}"

MOUNT_DIR="$WORK_DIR/mnt_system"
sudo mkdir -p "$MOUNT_DIR"

if [ "$FS_TYPE" == "erofs" ]; then
  echo "==> [EXTRACT] Extracting EROFS filesystem..."
  sudo mount -o loop,ro "$SYSTEM_IMG" "$MOUNT_DIR" 2>/dev/null || fsck.erofs --extract="$OUTPUT_DIR" "$SYSTEM_IMG"
  if mountpoint -q "$MOUNT_DIR"; then
    sudo cp -a "$MOUNT_DIR"/* "$OUTPUT_DIR/"
    sudo umount "$MOUNT_DIR"
  fi
else
  echo "==> [EXTRACT] Mounting EXT4 / Generic filesystem..."
  sudo mount -o loop,ro "$SYSTEM_IMG" "$MOUNT_DIR"
  sudo cp -a "$MOUNT_DIR"/* "$OUTPUT_DIR/"
  sudo umount "$MOUNT_DIR"
fi

echo "==> [EXTRACT] Successfully extracted system partition to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR" | head -n 20
