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
  libncurses6 \
  libncurses-dev \
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
  android-sdk-libsparse-utils \
  android-libbase-dev

echo "==> [SETUP] Installing Python helper packages..."
python3 -m pip install --break-system-packages --upgrade pip setuptools wheel 2>/dev/null \
  || python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install --break-system-packages "protobuf==3.20.*" requests gdown 2>/dev/null \
  || python3 -m pip install "protobuf==3.20.*" requests gdown
echo "  [+] gdown (Google Drive downloader) installed."

BIN_DIR="/usr/local/bin"
TOOLS_DIR="$(dirname "$(realpath "$0")")/../tools"

echo "==> [SETUP] Installing payload-dumper-go..."
if ! command -v payload-dumper-go &>/dev/null; then
  # Fetch latest version tag via GitHub API, fall back to known good version
  PDGO_VERSION=$(curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 60 \
    "https://api.github.com/repos/ssut/payload-dumper-go/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null \
    || echo "2.0.2")
  PDGO_URL="https://github.com/ssut/payload-dumper-go/releases/download/${PDGO_VERSION}/payload-dumper-go_${PDGO_VERSION}_linux_amd64.tar.gz"
  echo "  -> Downloading payload-dumper-go v${PDGO_VERSION}..."
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 180 \
    "$PDGO_URL" -o /tmp/payload-dumper-go.tar.gz
  tar -xzf /tmp/payload-dumper-go.tar.gz -C /tmp/
  sudo mv /tmp/payload-dumper-go "$BIN_DIR/"
  sudo chmod +x "$BIN_DIR/payload-dumper-go"
  rm -f /tmp/payload-dumper-go*
  echo "  [+] payload-dumper-go installed."
else
  echo "  [+] payload-dumper-go already present."
fi

echo "==> [SETUP] Ensuring lpunpack.py is available..."
# BUG FIX: Previous version fetched from ErfanGSIs which is 404.
# Now uses unix3dgforce/lpunpack - a pure-Python super.img unpacker.
if [ ! -f "$TOOLS_DIR/lpunpack.py" ]; then
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 30 --max-time 60 \
    "https://raw.githubusercontent.com/unix3dgforce/lpunpack/master/lpunpack.py" \
    -o "$TOOLS_DIR/lpunpack.py"
  echo "  [+] lpunpack.py downloaded to tools/."
else
  echo "  [+] lpunpack.py already present in tools/."
fi

echo "==> [SETUP] Environment configured successfully."
