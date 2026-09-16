#!/usr/bin/env bash
# ==============================================================================
# clean_disk.sh - Free up disk space on GitHub Actions Ubuntu Runner
# Frees up 35GB+ of disk space for heavy GSI extraction and builds.
# ==============================================================================

set -eo pipefail

echo "==> [CLEAN DISK] Initial Disk Space:"
df -h /

echo "==> [CLEAN DISK] Removing unused tools and runtimes..."
sudo rm -rf \
  /usr/share/dotnet \
  /usr/local/lib/android \
  /opt/ghc \
  /usr/local/share/boost \
  /usr/share/swift \
  /usr/local/share/powershell \
  /usr/local/share/vcpkg \
  /var/lib/docker \
  /usr/lib/jvm \
  2>/dev/null || true

echo "==> [CLEAN DISK] Cleaning package caches..."
sudo apt-get autoremove -y >/dev/null 2>&1 || true
sudo apt-get clean >/dev/null 2>&1 || true

echo "==> [CLEAN DISK] Final Disk Space:"
df -h /
