#!/bin/bash
# Build rayhunter-daemon fork for ARMv7 musl (RC400L target)
# Run from inside WSL Ubuntu: bash /mnt/c/.../rc400l/rh_build.sh
# Source dir is auto-detected from script location — no hardcoded paths.
set -e
LOG=/tmp/rh_build.log
exec > >(tee -a "$LOG") 2>&1

# Resolve project root relative to this script (works inside WSL)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/Firmware_Backups/rayhunter-OLD"
OUT="${SCRIPT_DIR}/rayhunter-daemon-fork"

echo "=== [$(date)] Step 1: Install rustup ==="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source "$HOME/.cargo/env"
rustup target add armv7-unknown-linux-musleabihf
echo "Rust ARM target ready"

echo "=== [$(date)] Step 2: Install nvm + Node 20 ==="
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
source "$NVM_DIR/nvm.sh"
nvm install 20
nvm use 20
node --version && npm --version

echo "=== [$(date)] Step 3: Copy source to Linux FS ==="
rm -rf /tmp/rayhunter-src
cp -r "$SRC" /tmp/rayhunter-src
echo "Source copied ($(du -sh /tmp/rayhunter-src | cut -f1))"

echo "=== [$(date)] Step 4: Build web frontend ==="
cd /tmp/rayhunter-src/daemon/web
npm install
npm run build
echo "Web build done — $(ls build/)"

echo "=== [$(date)] Step 5: Build Rust daemon ==="
cd /tmp/rayhunter-src
source "$HOME/.cargo/env"
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
cargo build -p rayhunter-daemon --bin rayhunter-daemon \
    --target armv7-unknown-linux-musleabihf --profile firmware-devel

echo "=== [$(date)] BUILD COMPLETE ==="
ls -lh target/armv7-unknown-linux-musleabihf/firmware-devel/rayhunter-daemon
cp target/armv7-unknown-linux-musleabihf/firmware-devel/rayhunter-daemon "$OUT"
echo "Binary copied to: $OUT"
