# CLAUDE.md

## Project Overview

HPS-ShareScreen is a wireless screen sharing system for Hotel Park Soltau conference rooms. Guests scan a QR code, enter a daily PIN, and share their screen via WebRTC to a Raspberry Pi Zero 2W connected to a TV.

## Architecture

- **Server**: Node.js + Express + Socket.IO on Docker (Debian slim + Chromium for idle image generation)
- **Pi Receiver**: C++17 with GStreamer webrtcbin, hardware H264 decode (v4l2h264dec), KMS output (kmssink)
- **Signaling**: Socket.IO (Engine.IO v4 over WebSocket) — implemented manually in C++ using libsoup
- **ICE**: STUN only (Google public STUN servers) — no TURN needed, WebRTC connects directly

## Key Files

- `server.js` — Express server, Socket.IO signaling, PIN generation/validation, admin API, room management
- `idle-image.js` — Puppeteer-based screenshot of display.html for idle screen PNG
- `public/display.html` — TV display page (QR, PIN, WebRTC video receiver) — served at `/:room/display`, not directly accessible to guests
- `public/share.html` — Guest sharing page (PIN entry, screen/camera/image share)
- `public/admin.html` — Admin panel (room status, reboot, idle refresh, add/remove rooms, Ansible setup config)
- `receiver/src/main.cpp` — C++ receiver entry point
- `receiver/src/pipeline.cpp` — GStreamer pipeline (webrtcbin → h264parse → v4l2h264dec → kmssink)
- `receiver/src/signaling.cpp` — Socket.IO client in C++ (libsoup WebSocket + json-glib)
- `pi-setup/setup.sh` — One-shot Pi provisioning script

## GStreamer Pipeline (Critical)

```
webrtcbin (latency=0) → rtph264depay → h264parse (config-interval=-1) → v4l2h264dec (capture-io-mode=dmabuf) → kmssink (sync=true)
```

- **No v4l2convert** — DRM hardware plane handles scaling and format conversion
- **No force-modesetting** — uses existing display mode, supports any input resolution
- Jitter buffer: latency=0, faststart=1
- sync=true for tear-free display

## Pi Hardware Constraints

- Pi Zero 2W: 416MB RAM, quad-core Cortex-A53
- gpu_mem=128 maximum (256 crashes boot)
- v4l2h264dec max practical resolution: ~1080p
- Browser downscales anything above 1920x1080 before sending
- CPU governor set to `performance` via systemd ExecStartPre

## Important Rules

- **Never disable system services** on the Pi (avahi, NetworkManager, wpa_supplicant) — it's wifi-only, disabling these bricks it
- **Never use Python** on the Pi — too slow, C++ only
- **Never use software rendering** — hardware decode (v4l2h264dec) + KMS output only
- **No Plymouth/fbi** for boot splash — they fight with kmssink for DRM master and break boot
- **Silent boot** achieved via: console=tty3, quiet, loglevel=0 kernel params
- **Keep fsck enabled** — power loss corrupts SD cards, never disable fsck.repair
- Commits should not include Co-Authored-By lines

## Socket.IO Roles

- `display` — Pi receiver (one per room, claims display slot)
- `sharer` — active screen sharer (one per room, claimed on share button click)
- `viewer` — authenticated guest not yet sharing (joins room for status updates)
- `admin` — admin panel (joins `__admin` room)

## SSH Access to Pi

```
ssh pi@kiel-stream.local  # password: raspberry
```

## Deployment

Server: `docker compose up -d --build` (admin deploys)
Pi receiver: rsync source to Pi, build with cmake/make, copy binary to /usr/local/bin/, restart service
Room data: persisted at `/mnt/data/hps-sharescreen/rooms.json` on the host

## Environment Variables

- `ROOMS` — comma-separated room names (seeds rooms.json on first run)
- `BASE_URL` — public URL for QR codes
- `PIN_SECRET` — salt for daily PIN generation
- `ADMIN_PASS` — admin panel password
