#!/bin/bash
# =============================================================================
# ShareScreen Pi Display — no browser needed
#
# Shows QR code on framebuffer when idle.
# When a stream starts, switches to mpv playing the MJPEG stream.
# When the stream stops, switches back to QR code.
# =============================================================================

ROOM=$(cat ~/.sharescreen-room 2>/dev/null || echo "Kiel")
SERVER="https://share.hotel-park-soltau.de"
STREAM_URL="${SERVER}/${ROOM}/stream"
STATUS_URL="${SERVER}/api/status/${ROOM}"
QR_IMAGE="/tmp/sharescreen-qr.png"

# Generate QR code image if not exists
if [ ! -f "$QR_IMAGE" ]; then
  if command -v qrencode > /dev/null; then
    qrencode -o "$QR_IMAGE" -s 10 -m 2 --foreground=2a2a29 "${SERVER}/${ROOM}/share"
  else
    # Fallback: download from server (QR API)
    echo "qrencode not found, install with: sudo apt-get install qrencode"
  fi
fi

cleanup() {
  # Kill all child processes
  kill $(jobs -p) 2>/dev/null
  # Clear framebuffer
  dd if=/dev/zero of=/dev/fb0 bs=1M count=10 2>/dev/null
  exit 0
}
trap cleanup EXIT INT TERM

MPV_PID=""
FBI_PID=""

show_qr() {
  # Kill mpv if running
  if [ -n "$MPV_PID" ] && kill -0 "$MPV_PID" 2>/dev/null; then
    kill "$MPV_PID" 2>/dev/null
    wait "$MPV_PID" 2>/dev/null
    MPV_PID=""
  fi
  # Show QR code on framebuffer
  if [ -f "$QR_IMAGE" ]; then
    if [ -n "$FBI_PID" ] && kill -0 "$FBI_PID" 2>/dev/null; then
      return # Already showing
    fi
    fbi -T 1 -d /dev/fb0 --noverbose -a "$QR_IMAGE" 2>/dev/null &
    FBI_PID=$!
  fi
}

show_stream() {
  # Kill fbi if running
  if [ -n "$FBI_PID" ] && kill -0 "$FBI_PID" 2>/dev/null; then
    kill "$FBI_PID" 2>/dev/null
    wait "$FBI_PID" 2>/dev/null
    FBI_PID=""
  fi
  # Start mpv if not already running
  if [ -n "$MPV_PID" ] && kill -0 "$MPV_PID" 2>/dev/null; then
    return # Already playing
  fi
  mpv \
    --no-audio \
    --vo=drm \
    --hwdec=auto \
    --really-quiet \
    --no-terminal \
    --demuxer-lavf-o=timeout=5000000 \
    --network-timeout=10 \
    --cache=no \
    "$STREAM_URL" &
  MPV_PID=$!
}

# --- Main loop ---
echo "ShareScreen display for room: ${ROOM}"
echo "Stream URL: ${STREAM_URL}"
echo "Status URL: ${STATUS_URL}"

show_qr

while true; do
  # Poll server for stream status
  STATUS=$(curl -sf --connect-timeout 3 "$STATUS_URL" 2>/dev/null)
  STREAMING=$(echo "$STATUS" | grep -o '"streaming":true')

  if [ -n "$STREAMING" ]; then
    show_stream
  else
    # Check if mpv died (stream ended)
    if [ -n "$MPV_PID" ] && ! kill -0 "$MPV_PID" 2>/dev/null; then
      MPV_PID=""
      show_qr
    fi
    # If we were streaming but status says no, go back to QR
    if [ -z "$MPV_PID" ] || ! kill -0 "$MPV_PID" 2>/dev/null; then
      show_qr
    fi
  fi

  sleep 2
done
