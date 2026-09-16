#!/usr/bin/env bash
# ==============================================================================
# gdrive_download.sh - Google Drive file downloader
#
# Supports all GDrive URL formats:
#   https://drive.google.com/file/d/FILE_ID/view?usp=sharing
#   https://drive.google.com/file/d/FILE_ID/view
#   https://drive.google.com/open?id=FILE_ID
#   https://drive.google.com/uc?id=FILE_ID
#   https://drive.google.com/uc?export=download&id=FILE_ID
#   https://drive.google.com/drive/folders/FOLDER_ID  (first file in folder)
#
# Handles:
#   - Large file virus-scan confirmation bypass
#   - Quota exceeded detection
#   - Fuzzy filename detection after download
#
# Usage: ./gdrive_download.sh <GDRIVE_URL> <OUTPUT_DIR>
# Returns: exits 0 and prints final file path to stdout on success
# ==============================================================================

set -eo pipefail

GDRIVE_URL="${1:-}"
OUTPUT_DIR="${2:-$(pwd)}"

if [ -z "$GDRIVE_URL" ]; then
  echo "[-] ERROR: Google Drive URL is required as argument 1."
  echo "Usage: ./gdrive_download.sh <GDRIVE_URL> <OUTPUT_DIR>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ── Helper: extract FILE_ID from any GDrive URL format ──────────────────────
extract_gdrive_id() {
  local url="$1"
  local file_id=""

  # Format: /file/d/FILE_ID/
  if echo "$url" | grep -qP '/file/d/([a-zA-Z0-9_-]+)'; then
    file_id=$(echo "$url" | grep -oP '/file/d/\K[a-zA-Z0-9_-]+')
  # Format: ?id=FILE_ID or &id=FILE_ID
  elif echo "$url" | grep -qP '[?&]id=([a-zA-Z0-9_-]+)'; then
    file_id=$(echo "$url" | grep -oP '[?&]id=\K[a-zA-Z0-9_-]+')
  # Format: /folders/FOLDER_ID
  elif echo "$url" | grep -qP '/folders/([a-zA-Z0-9_-]+)'; then
    file_id=$(echo "$url" | grep -oP '/folders/\K[a-zA-Z0-9_-]+')
    echo "[!] WARNING: Folder URL detected. Will download first file in folder." >&2
  fi

  echo "$file_id"
}

FILE_ID=$(extract_gdrive_id "$GDRIVE_URL")

if [ -z "$FILE_ID" ]; then
  echo "[-] ERROR: Could not extract a Google Drive file ID from URL:"
  echo "    $GDRIVE_URL"
  echo ""
  echo "    Supported formats:"
  echo "      https://drive.google.com/file/d/FILE_ID/view?usp=sharing"
  echo "      https://drive.google.com/open?id=FILE_ID"
  echo "      https://drive.google.com/uc?id=FILE_ID"
  exit 1
fi

echo "==> [GDRIVE] File ID: $FILE_ID"
echo "==> [GDRIVE] Output directory: $OUTPUT_DIR"

# ── Method 1: gdown (best - handles large files + confirmation automatically) 
if command -v gdown &>/dev/null; then
  echo "==> [GDRIVE] Downloading with gdown..."
  gdown --fuzzy --no-cookies "$GDRIVE_URL" -O "$OUTPUT_DIR/" 2>&1 | tee /tmp/gdown.log || true

  # Check for quota exceeded
  if grep -q "Too many users have viewed" /tmp/gdown.log 2>/dev/null \
    || grep -q "quota" /tmp/gdown.log 2>/dev/null; then
    echo "[-] ERROR: Google Drive download quota exceeded for this file."
    echo "    Please use a different sharing method (direct URL, Telegram, etc.)"
    exit 1
  fi

  DOWNLOADED_FILE=$(find "$OUTPUT_DIR" -maxdepth 1 -type f \
    ! -name "*.aria2" ! -name "*.tmp" ! -name "gdown.log" \
    | sort -t_ -k1 | tail -n 1)

  if [ -n "$DOWNLOADED_FILE" ] && [ -s "$DOWNLOADED_FILE" ]; then
    echo "==> [GDRIVE] Downloaded: $(basename "$DOWNLOADED_FILE") ($(du -h "$DOWNLOADED_FILE" | cut -f1))"
    echo "$DOWNLOADED_FILE"
    exit 0
  fi

  echo "[!] gdown finished but no file found, trying fallback method..."
fi

# ── Method 2: curl with confirmation cookie bypass (for large files) ─────────
echo "==> [GDRIVE] Downloading with curl + confirmation bypass..."

CONFIRM_URL="https://drive.google.com/uc?export=download&id=${FILE_ID}"

# First request - get confirmation token for large files
CONFIRM_TOKEN=$(curl -sc /tmp/gdrive_cookies.txt -fsSL "$CONFIRM_URL" \
  | grep -oP 'confirm=\K[^&"]+' | head -n1 || true)

if [ -n "$CONFIRM_TOKEN" ]; then
  echo "  -> Large file detected, using confirmation token: $CONFIRM_TOKEN"
  DOWNLOAD_URL="${CONFIRM_URL}&confirm=${CONFIRM_TOKEN}"
else
  DOWNLOAD_URL="$CONFIRM_URL"
fi

# Download with cookies (needed for confirmation bypass)
curl -Lb /tmp/gdrive_cookies.txt \
  --location \
  --retry 3 \
  --retry-delay 5 \
  --max-time 3600 \
  -o "$OUTPUT_DIR/gdrive_rom_${FILE_ID}" \
  "$DOWNLOAD_URL"

DOWNLOADED_FILE=$(find "$OUTPUT_DIR" -maxdepth 1 -name "gdrive_rom_${FILE_ID}" -type f | head -n1)

if [ -z "$DOWNLOADED_FILE" ] || [ ! -s "$DOWNLOADED_FILE" ]; then
  echo "[-] ERROR: All download methods failed for Google Drive file ID: $FILE_ID"
  echo "    Please check:"
  echo "      1. The file is shared as 'Anyone with the link'"
  echo "      2. The file is not over the download quota"
  echo "      3. The URL is correct"
  exit 1
fi

# ── Detect if what we got is HTML (quota/auth error) instead of a ROM ────────
FILETYPE=$(file -b "$DOWNLOADED_FILE" | tr '[:upper:]' '[:lower:]')
if echo "$FILETYPE" | grep -q "html\|ascii\|utf-8"; then
  echo "[-] ERROR: Downloaded file appears to be HTML, not a ROM."
  echo "    This usually means:"
  echo "      - File requires Google account login"
  echo "      - Download quota exceeded"
  echo "      - File ID is invalid"
  cat "$DOWNLOADED_FILE" | head -5
  rm -f "$DOWNLOADED_FILE"
  exit 1
fi

# ── Try to rename to real filename from Content-Disposition header ────────────
echo "==> [GDRIVE] Downloaded: $(basename "$DOWNLOADED_FILE") ($(du -h "$DOWNLOADED_FILE" | cut -f1))"
echo "$DOWNLOADED_FILE"
