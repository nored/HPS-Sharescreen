# HPS-ShareScreen

Drahtlose Bildschirmfreigabe für Konferenzräume im Hotel Park Soltau. Gäste scannen einen QR-Code und teilen ihren Bildschirm direkt auf das Raumdisplay — ohne App, ohne Kabel.

## Funktionsweise

1. Ein **Raspberry Pi Zero W** in jedem Konferenzraum zeigt auf dem angeschlossenen Bildschirm einen QR-Code und eine Anleitung.
2. Der Gast **scannt den QR-Code** mit dem Smartphone oder Laptop.
3. Der Browser fragt nach der **Bildschirmfreigabe** (`getDisplayMedia`).
4. Der freigegebene Bildschirm wird per **WebRTC** live auf das Display übertragen.
5. Nach Beendigung der Freigabe kehrt das Display automatisch zum QR-Code zurück.

**Auf Mobilgeräten** (iPhone/Android) wird statt Bildschirmfreigabe die Kamera oder ein Bild-Upload angeboten.

## Architektur

```
Gast (Laptop/Handy)              Raspberry Pi + Display
┌────────────────┐               ┌─────────────────┐
│  /Kiel/share   │ ◄── WebRTC ──► │  /Kiel           │
│  Screen Share  │               │  Fullscreen      │
└───────┬────────┘               └────────┬─────────┘
        │                                 │
        └──── Socket.IO (Signaling) ──────┘
                       │
                ┌──────────────┐
                │    Server    │
                │   (Docker)   │
                └──────────────┘
```

- **Server**: Node.js + Express + Socket.IO (WebRTC-Signaling)
- **Display-Seite** (`/<Raum>`): QR-Code, Wartebildschirm, Videoempfang
- **Share-Seite** (`/<Raum>/share`): Bildschirmfreigabe, Kamera, Bild-Upload
- **Debug**: `?debug` an jede URL anhängen für Live-Diagnose

## Server einrichten

### Docker

```bash
docker compose up -d --build
```

Der Container lauscht auf Port `3000`. Ein Reverse-Proxy (nginx/Traefik) leitet `share.hotel-park-soltau.de` auf diesen Port weiter.

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

### Konfiguration

Räume werden über Umgebungsvariablen konfiguriert:

```yaml
# docker-compose.yml
environment:
  - ROOMS=Kiel,Hamburg,Bremen,Heide,Lübeck
  - BASE_URL=https://share.hotel-park-soltau.de
  - TURN_HOST=share.hotel-park-soltau.de
  - TURN_PORT=3478
  - TURN_USER=sharescreen
  - TURN_PASS=hotelparkshare2024
```

Ein **coturn** TURN-Server läuft als zweiter Container für Fälle, in denen direkte Peer-to-Peer-Verbindungen nicht möglich sind.

## Raspberry Pi einrichten

Jeder Konferenzraum bekommt einen Raspberry Pi Zero W mit Display.

### Voraussetzungen

- Raspberry Pi Zero W (oder besser)
- Raspberry Pi OS Lite (kein Desktop)
- HDMI-Display
- WLAN-Verbindung zum internen Netz

### Setup

1. **Raspberry Pi OS Lite** mit dem Raspberry Pi Imager flashen. Im Imager WLAN, SSH und Benutzername konfigurieren.

2. Pi booten, per SSH verbinden und einrichten — ein Befehl:
   ```bash
   curl -sL https://raw.githubusercontent.com/nored/HPS-Sharescreen/main/pi-setup/setup.sh -o /tmp/setup.sh && sudo bash /tmp/setup.sh Kiel
   ```
   Ersetze `Kiel` durch den jeweiligen Raumnamen.

   **Alternativ** manuell:
   ```bash
   # Vom eigenen Rechner:
   scp -r pi-setup/ pi@<pi-ip>:/home/pi/

   # Auf dem Pi:
   sudo bash /home/pi/pi-setup/setup.sh Kiel
   ```

4. Der Pi startet automatisch neu und zeigt den ShareScreen.

### Was passiert beim Setup

- Installiert **cage** (minimaler Wayland-Kiosk-Compositor) + **Chromium** — sonst nichts
- Erstellt einen **systemd-Service** (`sharescreen.service`), der beim Booten startet
- Konfiguriert GPU-Speicher (128 MB), mildes Overclocking, HDMI-Hotplug
- Deaktiviert Bluetooth, Avahi und andere unnötige Dienste
- Setzt den Hostnamen auf `sharescreen-<raum>`

### Verwaltung

```bash
sudo systemctl status sharescreen      # Status
sudo systemctl restart sharescreen     # Neustart
sudo journalctl -u sharescreen -f      # Live-Logs
```

### Chromium-Flags

Der wichtigste Flag für die Konnektivität:
```
--force-webrtc-ip-handling-policy=default_public_interface_only
```
Deaktiviert die mDNS-Verschleierung der IP-Adresse. Der Pi sendet seine echte LAN-IP als ICE-Kandidat, sodass jeder Gast-Browser direkt verbinden kann.

## Debug

An jede URL `?debug` anhängen für ein Live-Diagnose-Panel:

- `https://share.hotel-park-soltau.de/Kiel?debug`
- `https://share.hotel-park-soltau.de/Kiel/share?debug`

Zeigt Socket.IO-Verbindung, ICE-Kandidaten (Typ, Protokoll), WebRTC-Status, Bitrate, FPS, Auflösung und Codec in Echtzeit.

## Projektstruktur

```
├── Dockerfile
├── docker-compose.yml
├── turnserver.conf           # coturn TURN-Server Konfiguration
├── server.js                 # Express + Socket.IO Signaling-Server
├── public/
│   ├── display.html          # Raspberry Pi Anzeige (QR-Code + Videoempfang)
│   ├── share.html            # Gast-Seite (Screen Share / Kamera / Bild-Upload)
│   ├── debug.js              # Debug-Panel (aktiviert mit ?debug)
│   ├── logo.svg              # Hotel Park Soltau Logo
│   └── qrious.min.js         # QR-Code Generator
└── pi-setup/
    └── setup.sh              # Raspberry Pi Einrichtung (einmalig)
```

## Voraussetzungen

- **HTTPS** ist erforderlich — `getDisplayMedia` funktioniert nur in einem sicheren Kontext
- Das System ist nur im **internen Netzwerk** erreichbar
- **Ausgehend UDP** zu `stun.l.google.com:19302` muss möglich sein (für STUN)
- Moderne Browser: Chrome, Edge, Firefox, Safari

## Ohne App, ohne Installation

Gäste benötigen keine App und keine Installation. Ein moderner Browser genügt.
