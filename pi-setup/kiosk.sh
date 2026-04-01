#!/bin/bash
# ShareScreen kiosk — runs inside X (started via .xinitrc)

ROOM="${1:-Kiel}"
URL="https://share.hotel-park-soltau.de/${ROOM}"

# Disable screen blanking / power saving
xset s off
xset -dpms
xset s noblank

# Hide mouse cursor
unclutter -idle 0.1 -root &

# Clean up Chromium crash flags
PREFS="$HOME/.config/chromium/Default/Preferences"
if [ -f "$PREFS" ]; then
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$PREFS"
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS"
fi

# Restart Chromium if it crashes
while true; do
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

  # If Chromium exits (crash), wait 2s and restart
  sleep 2
done
