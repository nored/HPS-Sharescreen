# HPS-ShareScreen

Drahtlose Bildschirmfreigabe für Konferenzräume im Hotel Park Soltau. Gäste scannen einen QR-Code und teilen ihren Bildschirm direkt auf das Raumdisplay — ohne App, ohne Kabel.

## Funktionsweise

1. Ein **Raspberry Pi Zero W** in jedem Konferenzraum zeigt auf dem angeschlossenen Bildschirm einen QR-Code und eine Anleitung.
2. Der Gast **scannt den QR-Code** mit dem Smartphone oder Laptop.
3. Der Browser fragt nach der **Bildschirmfreigabe** (`getDisplayMedia`).
4. Der freigegebene Bildschirm wird per **WebRTC** live auf das Display übertragen.
5. Nach Beendigung der Freigabe kehrt das Display automatisch zum QR-Code zurück.

## Architektur

```
Gast (Laptop/Handy)          Raspberry Pi + Display
       ┌──────┐                   ┌──────────┐
       │ /Kiel/share │  ◄─WebRTC─►  │  /Kiel     │
       │ getDisplayMedia │           │  Fullscreen  │
       └──────┘                   └──────────┘
                  ▲       ▲
                  └──Socket.IO──┘
                     Signaling
                        │
                  ┌─────────┐
                  │  Server  │
                  │ (Docker) │
                  └─────────┘
```

- **Server**: Node.js + Express + Socket.IO (WebRTC-Signaling)
- **Display-Seite** (`/<Raum>`): QR-Code, Wartebildschirm, Videoempfang
- **Share-Seite** (`/<Raum>/share`): Bildschirmfreigabe und Vorschau

## Schnellstart

### Docker

```bash
docker compose up -d --build
```

Der Container lauscht auf Port `3000`. Ein Reverse-Proxy (nginx/Traefik) sollte `share.hotel-park-soltau.de` auf diesen Port weiterleiten.

### Konfiguration

Räume werden über die Umgebungsvariable `ROOMS` konfiguriert (kommagetrennt):

```yaml
# docker-compose.yml
environment:
  - ROOMS=Kiel,Hamburg,Bremen,Heide,Lübeck
  - BASE_URL=https://share.hotel-park-soltau.de
```

### Raspberry Pi einrichten

Auf jedem Raspberry Pi Chromium im Kiosk-Modus starten:

```bash
chromium-browser --kiosk --noerrdialogs --disable-infobars \
  https://share.hotel-park-soltau.de/Kiel
```

Ersetze `Kiel` durch den jeweiligen Raumnamen.

## Projektstruktur

```
├── Dockerfile
├── docker-compose.yml
├── server.js                # Express + Socket.IO Signaling-Server
└── public/
    ├── display.html          # Raspberry Pi Anzeige (QR-Code + Videoempfang)
    ├── share.html            # Gast-Seite (Bildschirmfreigabe)
    ├── logo.svg              # Hotel Park Soltau Logo
    └── qrious.min.js         # QR-Code Generator (QRious v4.0.2)
```

## Voraussetzungen

- **HTTPS** ist erforderlich — `getDisplayMedia` funktioniert nur in einem sicheren Kontext.
- Das System ist nur im internen Netzwerk erreichbar.
- Moderne Browser (Chrome, Edge, Safari, Firefox) unterstützen die Bildschirmfreigabe.

## Ohne App, ohne Installation

Gäste benötigen keine App und keine Installation. Ein moderner Browser genügt.
