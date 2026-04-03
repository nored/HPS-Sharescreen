#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup — C++ WebRTC Receiver
# =============================================================================
#
# For Raspberry Pi OS Lite (no desktop). Builds the C++ GStreamer WebRTC
# receiver with hardware H.264 decode (v4l2h264dec) and KMS display output.
#
# USAGE:
#   sudo bash setup.sh <ROOM_NAME> [SERVER_URL]
#
# EXAMPLE:
#   sudo bash setup.sh Kiel https://share.hotel-park-soltau.de
#
# =============================================================================

set -e

ROOM="${1:?Usage: sudo bash setup.sh <ROOM_NAME> (e.g. Kiel, Hamburg)}"
SERVER="${2:-https://share.hotel-park-soltau.de}"
PI_USER="${SUDO_USER:-pi}"
PI_HOME="/home/${PI_USER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECEIVER_DIR="${SCRIPT_DIR}/../receiver"

echo ""
echo "========================================="
echo "  ShareScreen Setup — Raum ${ROOM}"
echo "  C++ WebRTC Receiver (hardware decode)"
echo "========================================="
echo ""

# --- Install dependencies ---
echo "[1/6] Installing GStreamer and build dependencies..."
apt-get update -qq
apt-get install -y -qq \
  build-essential cmake pkg-config \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-bad1.0-dev \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-nice \
  libsoup-3.0-dev \
  libjson-glib-dev \
  curl

# --- Boot config — GPU memory + HDMI ---
echo "[2/6] Configuring boot (gpu_mem=128, silent boot)..."
CONFIG="/boot/firmware/config.txt"
[ ! -f "$CONFIG" ] && CONFIG="/boot/config.txt"

if grep -q "^gpu_mem=" "$CONFIG"; then
  sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG"
else
  echo "gpu_mem=128" >> "$CONFIG"
fi

if ! grep -q "^# ShareScreen" "$CONFIG"; then
  cat >> "$CONFIG" <<BOOT

# ShareScreen
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
BOOT
fi

# Silent boot: redirect console to tty3, suppress all output on screen
CMDLINE="/boot/firmware/cmdline.txt"
[ ! -f "$CMDLINE" ] && CMDLINE="/boot/cmdline.txt"
sed -i 's|console=tty1|console=tty3|' "$CMDLINE"
if ! grep -q "quiet" "$CMDLINE"; then
  sed -i 's|rootwait|rootwait quiet loglevel=0 logo.nologo vt.global_cursor_default=0 consoleblank=0|' "$CMDLINE"
fi
# Keep fsck enabled (fsck.repair=yes) — power loss can corrupt the SD card
# fsck output goes to tty3 with the rest of the console, so it stays silent on tty1

# Disable login prompt on screen
systemctl disable getty@tty1 2>/dev/null || true

# --- Kernel tuning (non-destructive) ---
echo "[3/6] Tuning kernel parameters..."
cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL

# --- Build C++ receiver ---
echo "[4/6] Building C++ receiver..."
if [ -d "${RECEIVER_DIR}" ]; then
  cd "${RECEIVER_DIR}"
else
  echo "ERROR: receiver/ directory not found at ${RECEIVER_DIR}"
  echo "Clone the repo first: git clone <repo> && cd HPS-ShareScreen && sudo bash pi-setup/setup.sh ${ROOM}"
  exit 1
fi

mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
cp sharescreen-receiver /usr/local/bin/
cp "${SCRIPT_DIR}/sharescreen-update.sh" /usr/local/bin/
chmod +x /usr/local/bin/sharescreen-update.sh
echo "Installed: /usr/local/bin/sharescreen-receiver"
echo "Installed: /usr/local/bin/sharescreen-update.sh"

# --- Room config ---
echo "[5/6] Configuring room..."
echo "${ROOM}" > "${PI_HOME}/.sharescreen-room"
chown "${PI_USER}:${PI_USER}" "${PI_HOME}/.sharescreen-room"

# --- systemd service ---
echo "[6/6] Creating systemd service..."
cat > /etc/systemd/system/sharescreen.service <<SERVICE
[Unit]
Description=ShareScreen WebRTC Receiver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=${PI_HOME}
Environment=SHARESCREEN_SERVER=${SERVER}
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/bin/sh -c 'echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true'
ExecStart=/usr/bin/stdbuf -oL /usr/local/bin/sharescreen-receiver ${ROOM}
Nice=-20
Restart=always
RestartSec=5
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable sharescreen.service

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Room:     ${ROOM}"
echo "  Server:   ${SERVER}"
echo "========================================="
echo ""
echo "  Hardware pipeline:"
echo "    webrtcbin → rtph264depay → h264parse → v4l2h264dec → kmssink"
echo ""
echo "  Commands:"
echo "    sudo systemctl status sharescreen"
echo "    sudo systemctl restart sharescreen"
echo "    sudo journalctl -u sharescreen -f"
echo ""
echo "  Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
reboot
