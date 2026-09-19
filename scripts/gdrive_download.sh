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

# This script is called through command substitution. Keep stdout exclusively
# for the final downloaded file path; send status and diagnostics to stderr.
log() {
  printf '%s\n' "$*" >&2
}

if [ -z "$GDRIVE_URL" ]; then
  log "[-] ERROR: Google Drive URL is required as argument 1."
  log "Usage: ./gdrive_download.sh <GDRIVE_URL> <OUTPUT_DIR>"
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
    log "[!] WARNING: Folder URL detected. Will download first file in folder."
  fi

  echo "$file_id"
}

FILE_ID=$(extract_gdrive_id "$GDRIVE_URL")

if [ -z "$FILE_ID" ]; then
  log "[-] ERROR: Could not extract a Google Drive file ID from URL:"
  log "    $GDRIVE_URL"
  log ""
  log "    Supported formats:"
  log "      https://drive.google.com/file/d/FILE_ID/view?usp=sharing"
  log "      https://drive.google.com/open?id=FILE_ID"
  log "      https://drive.google.com/uc?id=FILE_ID"
  exit 1
fi

log "==> [GDRIVE] File ID: $FILE_ID"
log "==> [GDRIVE] Output directory: $OUTPUT_DIR"

# ── Method 1: gdown (best - handles large files + confirmation automatically) 
if command -v gdown &>/dev/null; then
  GDOWN_FILE="$OUTPUT_DIR/gdrive_rom_${FILE_ID}"
  rm -f "$GDOWN_FILE"
  log "==> [GDRIVE] Downloading with gdown..."
  # The Ubuntu package can be older than gdown releases that support
  # --fuzzy. A canonical uc?id URL works with both old and new versions.
  gdown --no-cookies "https://drive.google.com/uc?id=${FILE_ID}" -O "$GDOWN_FILE" 2>&1 | tee /tmp/gdown.log >&2 || true

  # Check for quota exceeded
  if grep -q "Too many users have viewed" /tmp/gdown.log 2>/dev/null \
    || grep -q "quota" /tmp/gdown.log 2>/dev/null; then
    log "[-] ERROR: Google Drive download quota exceeded for this file."
    log "    Please use a different sharing method (direct URL, Telegram, etc.)"
    exit 1
  fi

  if [ -s "$GDOWN_FILE" ]; then
    FILETYPE=$(file -b "$GDOWN_FILE" | tr '[:upper:]' '[:lower:]')
    if ! echo "$FILETYPE" | grep -q "html\|ascii\|utf-8"; then
      log "==> [GDRIVE] Downloaded: $(basename "$GDOWN_FILE") ($(du -h "$GDOWN_FILE" | cut -f1))"
      printf '%s\n' "$GDOWN_FILE"
      exit 0
    fi
    log "[!] gdown returned HTML instead of a ROM; trying curl fallback..."
    rm -f "$GDOWN_FILE"
  fi

  log "[!] gdown finished without a valid ROM, trying curl fallback..."
fi

# ── Method 2: curl with confirmation cookie bypass (for large files) ─────────
log "==> [GDRIVE] Downloading with curl + confirmation bypass..."

CONFIRM_URL="https://drive.google.com/uc?export=download&id=${FILE_ID}"
CONFIRM_PAGE="/tmp/gdrive_confirm_${FILE_ID}.html"

# First request - get the virus-scan confirmation form for large files. Drive
# now serves this form from drive.usercontent.google.com and puts confirm/uuid
# in hidden inputs rather than query parameters.
curl -sc /tmp/gdrive_cookies.txt -fsSL "$CONFIRM_URL" -o "$CONFIRM_PAGE" || true
CONFIRM_TOKEN=$(grep -oP 'name="confirm" value="\K[^"]+' "$CONFIRM_PAGE" | head -n1 || true)
CONFIRM_UUID=$(grep -oP 'name="uuid" value="\K[^"]+' "$CONFIRM_PAGE" | head -n1 || true)

if [ -n "$CONFIRM_TOKEN" ]; then
  log "  -> Large file detected; using confirmation token."
  DOWNLOAD_URL="https://drive.usercontent.google.com/download?export=download&id=${FILE_ID}&confirm=${CONFIRM_TOKEN}"
  if [ -n "$CONFIRM_UUID" ]; then
    DOWNLOAD_URL="${DOWNLOAD_URL}&uuid=${CONFIRM_UUID}"
  fi
else
  DOWNLOAD_URL="$CONFIRM_URL"
fi

# Download with cookies (needed for confirmation bypass)
curl -Lb /tmp/gdrive_cookies.txt \
  --location \
  --fail \
  --retry 3 \
  --retry-delay 5 \
  --max-time 3600 \
  -o "$OUTPUT_DIR/gdrive_rom_${FILE_ID}" \
  "$DOWNLOAD_URL"

DOWNLOADED_FILE=$(find "$OUTPUT_DIR" -maxdepth 1 -name "gdrive_rom_${FILE_ID}" -type f | head -n1)

if [ -z "$DOWNLOADED_FILE" ] || [ ! -s "$DOWNLOADED_FILE" ]; then
  log "[-] ERROR: All download methods failed for Google Drive file ID: $FILE_ID"
  log "    Please check:"
  log "      1. The file is shared as 'Anyone with the link'"
  log "      2. The file is not over the download quota"
  log "      3. The URL is correct"
  exit 1
fi

# ── Detect if what we got is HTML (quota/auth error) instead of a ROM ────────
FILETYPE=$(file -b "$DOWNLOADED_FILE" | tr '[:upper:]' '[:lower:]')
if echo "$FILETYPE" | grep -q "html\|ascii\|utf-8"; then
  log "[-] ERROR: Downloaded file appears to be HTML, not a ROM."
  log "    This usually means:"
  log "      - File requires Google account login"
  log "      - Download quota exceeded"
  log "      - File ID is invalid"
  head -n 5 "$DOWNLOADED_FILE" >&2 || true
  rm -f "$DOWNLOADED_FILE"
  exit 1
fi

# ── Try to rename to real filename from Content-Disposition header ────────────
log "==> [GDRIVE] Downloaded: $(basename "$DOWNLOADED_FILE") ($(du -h "$DOWNLOADED_FILE" | cut -f1))"
printf '%s\n' "$DOWNLOADED_FILE"
