#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup
# =============================================================================
#
# For Raspberry Pi OS Lite. Installs cage (minimal Wayland kiosk
# compositor) + Chromium. Nothing else. Boots straight into fullscreen.
#
# USAGE:
#   1. Flash Raspberry Pi OS Lite (use Raspberry Pi Imager —
#      configure WiFi, SSH, and username in the imager settings)
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

# --- Install cage + Chromium (that's it) ---
echo "[1/5] Installing cage + chromium..."
apt-get update -qq
apt-get install -y -qq cage chromium > /dev/null

# --- Boot config ---
echo "[2/5] Configuring boot..."
CONFIG="/boot/firmware/config.txt"
[ ! -f "$CONFIG" ] && CONFIG="/boot/config.txt"

# GPU memory for hardware video decoding
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
systemctl disable bluetooth hciuart triggerhappy avahi-daemon ModemManager 2>/dev/null || true

# System tuning
cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL

# --- systemd service ---
echo "[4/5] Creating systemd service..."
cat > /etc/systemd/system/sharescreen.service <<SERVICE
[Unit]
Description=ShareScreen Kiosk
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PI_USER}
Environment=HOME=${PI_HOME}
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u ${PI_USER})
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=3

ExecStartPre=/bin/mkdir -p /run/user/$(id -u ${PI_USER})
ExecStartPre=/bin/chown ${PI_USER}:${PI_USER} /run/user/$(id -u ${PI_USER})
ExecStart=/usr/bin/cage -s -- /usr/bin/chromium \\
  --kiosk \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-translate \\
  --no-first-run \\
  --ozone-platform=wayland \\
  --autoplay-policy=no-user-gesture-required \\
  --force-webrtc-ip-handling-policy=default_public_interface_only \\
  --enable-gpu-rasterization \\
  --enable-zero-copy \\
  --ignore-gpu-blocklist \\
  --enable-accelerated-video-decode \\
  --disable-background-timer-throttling \\
  --disable-backgrounding-occluded-windows \\
  --disable-renderer-backgrounding \\
  --memory-pressure-off \\
  --disable-features=TranslateUI \\
  --disk-cache-size=50000000 \\
  https://share.hotel-park-soltau.de/${ROOM}

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable sharescreen.service
systemctl disable getty@tty1.service 2>/dev/null || true

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
