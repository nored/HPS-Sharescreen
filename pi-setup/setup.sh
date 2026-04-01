#!/bin/bash
# One-time setup script for Raspberry Pi Zero W as ShareScreen display
# Run as root: sudo bash setup.sh

set -e

ROOM="${1:-Kiel}"
echo "Setting up ShareScreen display for room: ${ROOM}"

# --- System updates ---
apt-get update
apt-get install -y chromium-browser unclutter xdotool

# --- GPU memory split: give GPU more RAM for video decoding ---
if ! grep -q "^gpu_mem=" /boot/config.txt; then
  echo "gpu_mem=128" >> /boot/config.txt
else
  sed -i 's/^gpu_mem=.*/gpu_mem=128/' /boot/config.txt
fi

# --- Overclock (safe values for Pi Zero W) ---
if ! grep -q "^arm_freq=" /boot/config.txt; then
  cat >> /boot/config.txt <<BOOT

# ShareScreen performance tuning
arm_freq=1050
over_voltage=2
BOOT
fi

# --- Disable unnecessary services ---
systemctl disable bluetooth 2>/dev/null || true
systemctl disable hciuart 2>/dev/null || true
systemctl disable triggerhappy 2>/dev/null || true
systemctl disable avahi-daemon 2>/dev/null || true

# --- Reduce swap aggressiveness ---
echo "vm.swappiness=10" > /etc/sysctl.d/99-sharescreen.conf
sysctl -p /etc/sysctl.d/99-sharescreen.conf

# --- Install kiosk script ---
cp kiosk.sh /home/pi/kiosk.sh
chmod +x /home/pi/kiosk.sh

# --- Autostart on boot via LXDE autostart ---
mkdir -p /home/pi/.config/lxsession/LXDE-pi
cat > /home/pi/.config/lxsession/LXDE-pi/autostart <<AUTOSTART
@lxpanel --profile LXDE-pi
@pcmanfm --desktop --profile LXDE-pi
@bash /home/pi/kiosk.sh ${ROOM}
AUTOSTART

chown -R pi:pi /home/pi/.config

# --- Set hostname ---
HOSTNAME="sharescreen-$(echo ${ROOM} | tr '[:upper:]' '[:lower:]')"
hostnamectl set-hostname "${HOSTNAME}"

echo ""
echo "Setup complete! Hostname: ${HOSTNAME}"
echo "Reboot to start: sudo reboot"
