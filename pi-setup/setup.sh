#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup
# =============================================================================
#
# For Raspberry Pi OS Lite. Installs cog (WPE WebKit kiosk browser).
#
# USAGE:
#   curl -sL https://raw.githubusercontent.com/nored/HPS-Sharescreen/main/pi-setup/setup.sh -o /tmp/setup.sh && sudo bash /tmp/setup.sh Kiel
#
# =============================================================================

set -e

ROOM="${1:?Usage: sudo bash setup.sh <ROOM_NAME> (e.g. Kiel, Hamburg)}"
PI_USER="${SUDO_USER:-pi}"
PI_HOME="/home/${PI_USER}"

echo ""
echo "========================================="
echo "  ShareScreen Setup — Raum ${ROOM}"
echo "========================================="
echo ""

# --- Install cog (WPE WebKit kiosk browser) ---
echo "[1/5] Installing cog..."
apt-get update -qq
apt-get install -y cog libegl-mesa0 libgles2

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

# --- Disable unnecessary services (keep networking!) ---
echo "[3/5] Disabling unnecessary services..."
systemctl disable bluetooth hciuart triggerhappy 2>/dev/null || true

cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL

# --- systemd service ---
echo "[4/5] Creating systemd service..."
cat > /etc/systemd/system/sharescreen.service <<SERVICE
[Unit]
Description=ShareScreen Kiosk
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Environment=WPE_BCMRPI_TOUCH=1
Environment=COG_PLATFORM_DRM_RENDERER=gles2
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

ExecStart=/usr/bin/cog -P drm --enable-mediasource=true https://share.hotel-park-soltau.de/${ROOM}

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable sharescreen.service

# NEVER disable getty — always keep console + SSH accessible
# getty@tty1 stays enabled as a fallback

# --- Set hostname ---
echo "[5/5] Setting hostname..."
HOSTNAME="sharescreen-$(echo ${ROOM} | tr '[:upper:]' '[:lower:]')"
hostnamectl set-hostname "${HOSTNAME}" 2>/dev/null || echo "${HOSTNAME}" > /etc/hostname

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Hostname: ${HOSTNAME}"
echo "  Room:     ${ROOM}"
echo "========================================="
echo ""
echo "  sudo systemctl status sharescreen"
echo "  sudo systemctl restart sharescreen"
echo "  sudo journalctl -u sharescreen -f"
echo ""
echo "  Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
reboot
