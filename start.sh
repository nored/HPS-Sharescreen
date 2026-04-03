#!/bin/sh
set -e

# Start server in background
node server.js &
SERVER_PID=$!
sleep 2

# Generate idle screen images if not already present
ROOMS="${ROOMS:-Kiel,Hamburg,Bremen}"
FIRST_ROOM=$(echo "$ROOMS" | cut -d, -f1 | tr -d ' ')
if [ ! -f "public/idle/${FIRST_ROOM}.png" ]; then
  echo "Generating idle screen images..."
  export PATH="/root/.bun/bin:$PATH"
  bun idle-image.ts || echo "Warning: idle image generation failed"
fi

# Wait for server
wait $SERVER_PID
