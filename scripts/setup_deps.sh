#!/usr/bin/env bash
# ==============================================================================
# setup_deps.sh - Install dependencies for GSI Porting & Source Building
# ==============================================================================

set -eo pipefail

echo "==> [SETUP] Updating package indices..."
sudo apt-get update -qq

echo "==> [SETUP] Installing required system utilities & build packages..."
sudo apt-get install -y -qq --no-install-recommends \
  aria2 \
  bc \
  bison \
  brotli \
  build-essential \
  ccache \
  curl \
  e2fsprogs \
  e2tools \
  erofs-utils \
  flex \
  g++-multilib \
  gcc-multilib \
  git \
  gnupg \
  gperf \
  imagemagick \
  lib32readline-dev \
  lib32z1-dev \
  liblz4-tool \
  libncurses5 \
  libncurses5-dev \
  libssl-dev \
  libxml2 \
  libxml2-utils \
  lzop \
  openjdk-11-jdk \
  p7zip-full \
  p7zip-rar \
  python3 \
  python3-pip \
  rsync \
  schedtool \
  squashfs-tools \
  tar \
  unzip \
  wget \
  xsltproc \
  zip \
  zlib1g-dev \
  zstd \
  android-sdk-libsparse-utils || true

echo "==> [SETUP] Installing Python helper packages..."
python3 -m pip install --break-system-packages --upgrade pip setuptools wheel 2>/dev/null || python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install --break-system-packages protobuf==3.20.* requests 2>/dev/null || python3 -m pip install protobuf==3.20.* requests

BIN_DIR="/usr/local/bin"

echo "==> [SETUP] Installing payload-dumper-go..."
if ! command -v payload-dumper-go &>/dev/null; then
  curl -sL https://github.com/ssut/payload-dumper-go/releases/latest/download/payload-dumper-go_$(curl -sL https://api.github.com/repos/ssut/payload-dumper-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//')_linux_amd64.tar.gz -o /tmp/payload-dumper-go.tar.gz || true
  if [ -f /tmp/payload-dumper-go.tar.gz ]; then
    tar -xzf /tmp/payload-dumper-go.tar.gz -C /tmp/
    sudo mv /tmp/payload-dumper-go "$BIN_DIR/"
    sudo chmod +x "$BIN_DIR/payload-dumper-go"
    rm -f /tmp/payload-dumper-go*
  fi
fi

echo "==> [SETUP] Installing lpunpack & imjtool / ext4 utilities..."
# Download precompiled Android OTAs / lpunpack / simg2img binaries if needed
if ! command -v lpunpack &>/dev/null; then
  # Build or fetch lpunpack helper
  sudo curl -sL https://raw.githubusercontent.com/erfanoabdi/ErfanGSIs/master/bin/lpunpack -o "$BIN_DIR/lpunpack" || true
  sudo chmod +x "$BIN_DIR/lpunpack" || true
fi

echo "==> [SETUP] Environment configured successfully."
