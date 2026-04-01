#!/bin/bash
# Kiosk script for Raspberry Pi Zero W — ShareScreen display
# Place in /home/pi/kiosk.sh and chmod +x

ROOM="${1:-Kiel}"
URL="https://share.hotel-park-soltau.de/${ROOM}"

# Disable screen blanking / power saving
xset s off
xset -dpms
xset s noblank

# Hide mouse cursor after 3 seconds of inactivity
unclutter -idle 3 -root &

# Clean up any crash flags from previous sessions
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' \
  /home/pi/.config/chromium/Default/Preferences 2>/dev/null
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' \
  /home/pi/.config/chromium/Default/Preferences 2>/dev/null

chromium-browser \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-translate \
  --no-first-run \
  --start-fullscreen \
  --autoplay-policy=no-user-gesture-required \
  \
  --force-webrtc-ip-handling-policy=default_public_interface_only \
  \
  --enable-features=WebRTCPipeWireCapturer \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  --ignore-gpu-blocklist \
  --disable-software-rasterizer \
  --enable-accelerated-video-decode \
  \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  \
  --memory-pressure-off \
  --disable-features=TranslateUI \
  --disk-cache-size=50000000 \
  "${URL}"
