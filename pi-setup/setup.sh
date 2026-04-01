#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup
# =============================================================================
#
# For Raspberry Pi OS Lite (no desktop). Installs minimal X11 + Chromium
# and a systemd service that boots straight into the kiosk.
#
# USAGE:
#   1. Flash Raspberry Pi OS Lite to SD card (use Raspberry Pi Imager,
#      configure WiFi + SSH + username in the imager settings)
#   2. Boot the Pi, SSH in
#   3. Copy this folder to the Pi:
#        scp -r pi-setup/ pi@<pi-ip>:/home/pi/
#   4. Run:
#        sudo bash /home/pi/pi-setup/setup.sh Kiel
#   5. Pi reboots into ShareScreen automatically
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

# --- Install minimal X11 + Chromium ---
echo "[1/6] Installing packages..."
apt-get update -qq
apt-get install -y -qq \
  xserver-xorg \
  x11-xserver-utils \
  xinit \
  chromium-browser \
  unclutter \
  fonts-noto \
  > /dev/null

# --- GPU / boot config ---
echo "[2/6] Configuring GPU and boot..."
CONFIG="/boot/firmware/config.txt"
[ ! -f "$CONFIG" ] && CONFIG="/boot/config.txt"

if grep -q "^gpu_mem=" "$CONFIG"; then
  sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG"
else
  echo "gpu_mem=128" >> "$CONFIG"
fi

if ! grep -q "^arm_freq=" "$CONFIG"; then
  cat >> "$CONFIG" <<BOOT

# ShareScreen performance
arm_freq=1050
over_voltage=2

# Force HDMI output even if no display detected at boot
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
BOOT
fi

# --- Disable unnecessary services ---
echo "[3/6] Disabling unnecessary services..."
systemctl disable bluetooth 2>/dev/null || true
systemctl disable hciuart 2>/dev/null || true
systemctl disable triggerhappy 2>/dev/null || true
systemctl disable avahi-daemon 2>/dev/null || true
systemctl disable ModemManager 2>/dev/null || true

# --- System tuning ---
echo "[4/6] System tuning..."
cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL
sysctl -p /etc/sysctl.d/99-sharescreen.conf > /dev/null 2>&1

# --- Install kiosk script ---
echo "[5/6] Installing kiosk..."
cp "$(dirname "$0")/kiosk.sh" "${PI_HOME}/kiosk.sh"
chmod +x "${PI_HOME}/kiosk.sh"

echo "${ROOM}" > "${PI_HOME}/.sharescreen-room"
chown "${PI_USER}:${PI_USER}" "${PI_HOME}/.sharescreen-room" "${PI_HOME}/kiosk.sh"

# --- systemd service ---
echo "[6/6] Creating systemd service..."
cat > /etc/systemd/system/sharescreen.service <<SERVICE
[Unit]
Description=ShareScreen Kiosk
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PI_USER}
Environment=HOME=${PI_HOME}
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=3

ExecStart=/usr/bin/xinit ${PI_HOME}/kiosk.sh ${ROOM} -- /usr/bin/X :0 vt1 -nocursor -nolisten tcp

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable sharescreen.service

# Disable default getty on tty1 (we use it for X)
systemctl disable getty@tty1.service 2>/dev/null || true

# --- Set hostname ---
HOSTNAME="sharescreen-$(echo ${ROOM} | tr '[:upper:]' '[:lower:]')"
hostnamectl set-hostname "${HOSTNAME}" 2>/dev/null || \
  echo "${HOSTNAME}" > /etc/hostname

chown -R "${PI_USER}:${PI_USER}" "${PI_HOME}"

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Hostname: ${HOSTNAME}"
echo "  Room:     ${ROOM}"
echo "  Service:  sharescreen.service"
echo "========================================="
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status sharescreen"
echo "    sudo systemctl restart sharescreen"
echo "    sudo journalctl -u sharescreen -f"
echo ""
echo "  Rebooting in 5 seconds..."
echo "  (Ctrl+C to cancel)"
echo ""
sleep 5
reboot
