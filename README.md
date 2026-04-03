# HPS-ShareScreen

Drahtlose Bildschirmfreigabe für Konferenzräume im Hotel Park Soltau. Gäste scannen einen QR-Code, geben einen Raum-PIN ein und teilen ihren Bildschirm direkt auf das Raumdisplay — ohne App, ohne Kabel.

## Funktionsweise

1. Ein **Raspberry Pi Zero 2W** in jedem Konferenzraum zeigt auf dem Bildschirm einen QR-Code, PIN und Anleitung.
2. Der Gast **scannt den QR-Code** mit dem Smartphone oder Laptop.
3. Der Gast gibt den **4-stelligen Raum-PIN** ein (wird auf dem Display angezeigt, wechselt täglich).
4. Der Browser fragt nach der **Bildschirmfreigabe** (`getDisplayMedia`).
5. Der freigegebene Bildschirm wird per **WebRTC** live auf das Display übertragen.
6. Nach Beendigung der Freigabe kehrt das Display automatisch zum QR-Code zurück.

**Auf Mobilgeräten/Tablets** wird zusätzlich Kamera-Freigabe und Bild-Upload angeboten. Android-Geräte mit `getDisplayMedia`-Support können auch den Bildschirm teilen.

## Architektur

```
Gast (Laptop/Handy/Tablet)          Raspberry Pi Zero 2W + Display
┌────────────────────────┐           ┌──────────────────────────┐
│  /<Raum>/share         │           │  C++ GStreamer Receiver   │
│  PIN → Screen Share    │ ◄─WebRTC─►│  v4l2h264dec → kmssink   │
│  H264 Encode           │           │  Hardware Decode → HDMI  │
└──────────┬─────────────┘           └────────────┬─────────────┘
           │                                      │
           └──── Socket.IO (Signaling) ───────────┘
                          │
                   ┌──────────────┐
                   │  Node.js     │
                   │  (Docker)    │
                   │  Port 3000   │
                   └──────┬───────┘
                          │
                   ┌──────────────┐
                   │ coturn TURN  │
                   │  Port 3478   │
                   └──────────────┘
```

## Komponenten

| Komponente | Technologie | Aufgabe |
|---|---|---|
| **Server** | Node.js, Express, Socket.IO | WebRTC-Signaling, PIN-Validierung, Idle-Image-Generierung |
| **Gast-Seite** | Browser WebRTC API | Bildschirmaufnahme, H264-Encoding, Downscaling |
| **Pi Receiver** | C++17, GStreamer, webrtcbin | WebRTC-Empfang, Hardware-H264-Decode, KMS-Ausgabe |
| **TURN-Server** | coturn | NAT-Traversal-Fallback |
| **Admin-Seite** | Socket.IO | Raumstatus, Pi-Reboot, Idle-Image-Refresh |

## Server einrichten

### Docker

```bash
docker compose up -d --build
```

Der Container lauscht auf Port `3000`. Ein Reverse-Proxy (nginx/Traefik) leitet `share.hotel-park-soltau.de` auf diesen Port weiter.

### Umgebungsvariablen

```yaml
# docker-compose.yml
environment:
  - ROOMS=Kiel,Hamburg,Bremen,Heide,Lübeck
  - BASE_URL=https://share.hotel-park-soltau.de
  - TURN_HOST=share.hotel-park-soltau.de
  - TURN_PORT=3478
  - TURN_USER=sharescreen
  - TURN_PASS=hotelparkshare2024
  - PIN_SECRET=mein-geheimes-salt    # Für PIN-Generierung
  - ADMIN_PASS=mein-admin-passwort   # Für /admin
```

### nginx-Konfiguration

WebSocket-Support und Timeout sind wichtig:

```nginx
location / {
    proxy_pass http://localhost:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

## Raspberry Pi einrichten

### Voraussetzungen

- Raspberry Pi Zero 2W (oder besser)
- Raspberry Pi OS Lite (Debian Trixie, kein Desktop)
- HDMI-Display
- WLAN-Verbindung zum internen Netz

### Setup

1. **Raspberry Pi OS Lite** mit dem Raspberry Pi Imager flashen. Im Imager WLAN, SSH und Benutzername (`pi`) konfigurieren.

2. Pi booten, per SSH verbinden. Repo auf den Pi kopieren und Setup ausführen:
   ```bash
   # Vom eigenen Rechner:
   rsync -avz --exclude='.git' --exclude='node_modules' . pi@<pi-ip>:/home/pi/HPS-ShareScreen/

   # Auf dem Pi:
   sudo bash /home/pi/HPS-ShareScreen/pi-setup/setup.sh Kiel
   ```
   Ersetze `Kiel` durch den jeweiligen Raumnamen.

3. Der Pi startet automatisch neu und zeigt den ShareScreen.

### Was passiert beim Setup

- Installiert **GStreamer** mit webrtcbin, v4l2h264dec, kmssink (Hardware-Decode)
- Installiert **libsoup, json-glib** (Socket.IO-Signaling in C++)
- Kompiliert den **C++ WebRTC Receiver** (`receiver/`)
- Konfiguriert **GPU-Speicher** (128 MB), HDMI-Hotplug
- **Stiller Boot**: Console auf tty3 umgeleitet, kein Login-Prompt, kein fsck
- Erstellt **systemd-Service** mit Performance-CPU-Governor
- Lädt **Idle-Image** (QR-Code + PIN) vom Server beim Start

### Verwaltung

```bash
sudo systemctl status sharescreen      # Status
sudo systemctl restart sharescreen     # Neustart
sudo journalctl -u sharescreen -f      # Live-Logs
```

## Video-Pipeline

### Pi Receiver (C++)

```
webrtcbin (latency=0) → rtph264depay → h264parse → v4l2h264dec (DMABuf) → kmssink (sync=true)
```

- **Kein v4l2convert** — DRM-Hardware-Plane übernimmt Skalierung und Format
- **Kein force-modesetting** — nutzt vorhandenen Display-Modus, unterstützt jede Eingangsauflösung
- **Jitter Buffer**: 0ms, faststart=1
- **CPU Governor**: Performance (kein Frequency-Scaling)
- **sync=true**: VSync für tearing-freie Darstellung

### Browser (Sender)

- Bevorzugt **H264** Codec (Hardware-Decode auf Pi)
- **Downscaling**: Auflösungen über 1920px Breite oder 1080px Höhe werden herunterskaliert
- Erkennung: Touch-Geräte bekommen Mobile-UI, Desktop bekommt Screen-Share-UI

## Raum-PIN

- **4-stelliger PIN** pro Raum, wechselt täglich um Mitternacht
- Generiert aus `sha256(PIN_SECRET + Raum + Datum)` — deterministisch, überlebt Neustarts
- Angezeigt auf dem Display (Idle-Screen) und im Admin-Panel
- Muss im Browser eingegeben werden bevor Bildschirmfreigabe möglich ist

## Admin-Panel

Erreichbar unter `https://share.hotel-park-soltau.de/admin` (Basic Auth: `admin` / `ADMIN_PASS`).

- **Raumstatus**: Display verbunden, Sharer verbunden
- **PIN**: Aktueller PIN pro Raum
- **Reboot Pi**: Sendet Reboot-Befehl via Socket.IO
- **Idle neu**: Löscht gecachtes Idle-Image, wird beim nächsten Abruf neu generiert

## Idle-Screen

Das Idle-Bild (QR-Code, PIN, Anleitung) wird serverseitig mit **Puppeteer** (Chromium) als Screenshot von `display.html` generiert:

- Endpunkt: `/<Raum>/idle.png`
- Wird beim ersten Abruf generiert und gecacht
- Pi lädt das Bild beim Start automatisch
- Anzeige über GStreamer: `pngdec → imagefreeze → videoconvert → kmssink`

## Debug

An jede URL `?debug` anhängen für ein Live-Diagnose-Panel:

- `https://share.hotel-park-soltau.de/Kiel?debug`
- `https://share.hotel-park-soltau.de/Kiel/share?debug`

Zeigt Socket.IO-Verbindung, ICE-Kandidaten, WebRTC-Status, Bitrate, FPS, Auflösung und Codec.

## Projektstruktur

```
├── Dockerfile                    # Node.js + Chromium (Debian slim)
├── docker-compose.yml            # sharescreen + coturn Services
├── turnserver.conf               # coturn TURN-Server Konfiguration
├── server.js                     # Express + Socket.IO + PIN + Admin
├── idle-image.js                 # Puppeteer Screenshot-Generator
├── public/
│   ├── display.html              # Display-Seite (QR + PIN + Video)
│   ├── share.html                # Gast-Seite (PIN → Share/Kamera/Upload)
│   ├── admin.html                # Admin-Panel
│   ├── debug.js                  # Debug-Panel (?debug)
│   ├── logo.svg                  # Hotel Park Soltau Logo
│   └── qrious.min.js            # QR-Code Generator
├── receiver/                     # C++ WebRTC Receiver
│   ├── CMakeLists.txt
│   ├── build.sh
│   └── src/
│       ├── main.cpp              # Einstieg, Signal-Handler, Idle-Image
│       ├── signaling.cpp/h       # Socket.IO Client (Engine.IO v4)
│       └── pipeline.cpp/h        # GStreamer WebRTC + Video Pipeline
└── pi-setup/
    ├── setup.sh                  # Pi-Einrichtung (einmalig)
    ├── display.sh                # (Legacy) Shell-basierter Display-Loop
    └── recover.sh                # SD-Karten Recovery
```

## Voraussetzungen

- **HTTPS** erforderlich — `getDisplayMedia` benötigt sicheren Kontext
- **Ausgehend UDP** zu `stun.l.google.com:19302` (STUN)
- Moderne Browser: Chrome, Edge, Firefox, Safari
- Keine App, keine Installation für Gäste
