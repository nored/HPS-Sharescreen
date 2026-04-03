#!/bin/bash
# ShareScreen receiver OTA update — triggered via admin panel
set -e

SERVER="${SHARESCREEN_SERVER:-https://share.hotel-park-soltau.de}"
SRC_DIR="/home/pi/receiver"
LOG="/tmp/sharescreen-update.log"

exec > "$LOG" 2>&1
echo "$(date): Starting update from ${SERVER}"

# Download latest source
mkdir -p "${SRC_DIR}"
curl -sf "${SERVER}/api/receiver.tar.gz" | tar xzf - -C "${SRC_DIR}"

# Build
cd "${SRC_DIR}"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Install and restart
cp sharescreen-receiver /usr/local/bin/sharescreen-receiver.new
mv /usr/local/bin/sharescreen-receiver.new /usr/local/bin/sharescreen-receiver

echo "$(date): Build complete, restarting service"
systemctl restart sharescreen
