#!/bin/bash
# =============================================================================
# ShareScreen Raspberry Pi Setup
# =============================================================================
#
# For Raspberry Pi OS Lite (no desktop). Installs minimal X11 + Chromium
# kiosk. After setup, the Pi boots directly into fullscreen ShareScreen.
#
# USAGE:
#   1. Flash Raspberry Pi OS Lite to SD card
#   2. On the boot partition, configure WiFi and enable SSH:
#      - Create "ssh" file (empty)
#      - Create "wpa_supplicant.conf" with your WiFi credentials
#   3. Boot the Pi, SSH in
#   4. Copy this folder to the Pi:
#        scp -r pi-setup/ pi@<pi-ip>:/home/pi/
#   5. Run:
#        sudo bash /home/pi/pi-setup/setup.sh Kiel
#   6. The Pi reboots and starts the ShareScreen display
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

# --- Install minimal X11 + Chromium (no full desktop) ---
echo "[1/7] Installing packages..."
apt-get update -qq
apt-get install -y -qq \
  xserver-xorg \
  x11-xserver-utils \
  xinit \
  chromium-browser \
  unclutter \
  fonts-noto \
  > /dev/null

# --- GPU memory: 128MB for hardware video decoding ---
echo "[2/7] Configuring GPU..."
CONFIG="/boot/firmware/config.txt"
# Fallback for older Raspbian where config is at /boot/config.txt
[ ! -f "$CONFIG" ] && CONFIG="/boot/config.txt"

if grep -q "^gpu_mem=" "$CONFIG"; then
  sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG"
else
  echo "gpu_mem=128" >> "$CONFIG"
fi

# Safe overclock for Pi Zero W
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
echo "[3/7] Disabling unnecessary services..."
systemctl disable bluetooth 2>/dev/null || true
systemctl disable hciuart 2>/dev/null || true
systemctl disable triggerhappy 2>/dev/null || true
systemctl disable avahi-daemon 2>/dev/null || true
systemctl disable ModemManager 2>/dev/null || true

# --- System tuning ---
echo "[4/7] System tuning..."
cat > /etc/sysctl.d/99-sharescreen.conf <<SYSCTL
vm.swappiness=10
net.core.rmem_max=2500000
SYSCTL
sysctl -p /etc/sysctl.d/99-sharescreen.conf > /dev/null 2>&1

# --- Install kiosk script ---
echo "[5/7] Installing kiosk..."
cp "$(dirname "$0")/kiosk.sh" "${PI_HOME}/kiosk.sh"
chmod +x "${PI_HOME}/kiosk.sh"

# Write the room name to a file so kiosk.sh picks it up
echo "${ROOM}" > "${PI_HOME}/.sharescreen-room"
chown "${PI_USER}:${PI_USER}" "${PI_HOME}/.sharescreen-room"

# --- Create xinitrc (starts X with just Chromium, no desktop) ---
cat > "${PI_HOME}/.xinitrc" <<'XINITRC'
#!/bin/bash
ROOM=$(cat ~/.sharescreen-room 2>/dev/null || echo "Kiel")
exec bash ~/kiosk.sh "$ROOM"
XINITRC
chown "${PI_USER}:${PI_USER}" "${PI_HOME}/.xinitrc"
chmod +x "${PI_HOME}/.xinitrc"

# --- Auto-login + auto-startx via systemd ---
echo "[6/7] Configuring auto-login..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${PI_USER} --noclear %I \$TERM
AUTOLOGIN

# Start X automatically on login
PROFILE="${PI_HOME}/.bash_profile"
if ! grep -q "startx" "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" <<'BASHPROFILE'

# Auto-start ShareScreen kiosk
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx -- -nocursor 2>/dev/null
fi
BASHPROFILE
  chown "${PI_USER}:${PI_USER}" "$PROFILE"
fi

# --- Set hostname ---
echo "[7/7] Setting hostname..."
HOSTNAME="sharescreen-$(echo ${ROOM} | tr '[:upper:]' '[:lower:]')"
hostnamectl set-hostname "${HOSTNAME}" 2>/dev/null || \
  echo "${HOSTNAME}" > /etc/hostname

chown -R "${PI_USER}:${PI_USER}" "${PI_HOME}"

echo ""
echo "========================================="
echo "  Setup complete!"
echo "  Hostname: ${HOSTNAME}"
echo "  Room:     ${ROOM}"
echo "========================================="
echo ""
echo "  Rebooting in 5 seconds..."
echo "  (Ctrl+C to cancel)"
echo ""
sleep 5
reboot
