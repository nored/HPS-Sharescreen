#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup
# =============================================================================
#
# For Raspberry Pi OS Lite. No browser needed — uses mpv for video
# and fbi for the QR code display on the framebuffer directly.
#
# USAGE:
#   curl -sL https://raw.githubusercontent.com/nored/HPS-Sharescreen/main/pi-setup/setup.sh -o /tmp/setup.sh && sudo bash /tmp/setup.sh Kiel
#
# =============================================================================

set -e

ROOM="${1:?Usage: sudo bash setup.sh <ROOM_NAME> (e.g. Kiel, Hamburg)}"
PI_USER="${SUDO_USER:-pi}"
PI_HOME="/home/${PI_USER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "========================================="
echo "  ShareScreen Setup — Raum ${ROOM}"
echo "========================================="
echo ""

# --- Install dependencies ---
echo "[1/5] Installing mpv, qrencode, fbi..."
apt-get update -qq
apt-get install -y mpv qrencode fbi curl

# --- Boot config ---
echo "[2/5] Configuring boot..."
CONFIG="/boot/firmware/config.txt"
[ ! -f "$CONFIG" ] && CONFIG="/boot/config.txt"

if grep -q "^gpu_mem=" "$CONFIG"; then
  sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG"
else
  echo "gpu_mem=128" >> "$CONFIG"
fi

if ! grep -q "^arm_freq=" "$CONFIG"; then
  cat >> "$CONFIG" <<BOOT

# ShareScreen
arm_freq=1050
over_voltage=2
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
BOOT
fi

# --- Disable unnecessary services ---
echo "[3/5] Disabling unnecessary services..."
systemctl disable bluetooth hciuart triggerhappy 2>/dev/null || true

cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL

# --- Install display script ---
echo "[4/5] Installing display script..."

# Download display.sh if running from curl (no local copy)
if [ -f "${SCRIPT_DIR}/display.sh" ]; then
  cp "${SCRIPT_DIR}/display.sh" "${PI_HOME}/display.sh"
else
  curl -sL https://raw.githubusercontent.com/nored/HPS-Sharescreen/main/pi-setup/display.sh -o "${PI_HOME}/display.sh"
fi
chmod +x "${PI_HOME}/display.sh"

echo "${ROOM}" > "${PI_HOME}/.sharescreen-room"
chown "${PI_USER}:${PI_USER}" "${PI_HOME}/display.sh" "${PI_HOME}/.sharescreen-room"

# Pre-generate QR code
sudo -u "${PI_USER}" qrencode -o /tmp/sharescreen-qr.png -s 10 -m 2 \
  --foreground=2a2a29 "https://share.hotel-park-soltau.de/${ROOM}/share"

# --- systemd service ---
echo "[5/5] Creating systemd service..."
cat > /etc/systemd/system/sharescreen.service <<SERVICE
[Unit]
Description=ShareScreen Display
After=network.target

[Service]
Type=simple
User=${PI_USER}
Environment=HOME=${PI_HOME}
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

ExecStart=${PI_HOME}/display.sh

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable sharescreen.service

# --- Set hostname ---
HOSTNAME="sharescreen-$(echo ${ROOM} | tr '[:upper:]' '[:lower:]')"
hostnamectl set-hostname "${HOSTNAME}" 2>/dev/null || echo "${HOSTNAME}" > /etc/hostname

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Hostname: ${HOSTNAME}"
echo "  Room:     ${ROOM}"
echo "========================================="
echo ""
echo "  Packages: mpv, qrencode, fbi (no browser!)"
echo ""
echo "  sudo systemctl status sharescreen"
echo "  sudo systemctl restart sharescreen"
echo "  sudo journalctl -u sharescreen -f"
echo ""
echo "  Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
reboot
