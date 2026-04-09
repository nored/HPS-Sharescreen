const express = require('express');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const { Server } = require('socket.io');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  maxHttpBufferSize: 10 * 1024 * 1024,
  pingInterval: 10000,
  pingTimeout: 30000,
  transports: ['websocket', 'polling']
});

const PORT = process.env.PORT || 3000;
const BASE_URL = process.env.BASE_URL || 'https://share.hotel-park-soltau.de';

const ROOMS_FILE = path.join(__dirname, 'data', 'rooms.json');
const ROOMS_DEFAULT = (process.env.ROOMS || 'Kiel,Hamburg,Bremen').split(',').map(r => r.trim());

// Load rooms from file, seed from env if file doesn't exist
function loadRooms() {
  try {
    return JSON.parse(fs.readFileSync(ROOMS_FILE, 'utf8'));
  } catch {
    return [...ROOMS_DEFAULT];
  }
}
function saveRooms(rooms) {
  fs.mkdirSync(path.dirname(ROOMS_FILE), { recursive: true });
  fs.writeFileSync(ROOMS_FILE, JSON.stringify(rooms, null, 2));
}
let ROOMS = loadRooms();

// Persistent device-name → room bindings, so a paired Pi auto-rejoins
// its room across reboots without needing to be re-paired by an admin.
const DEVICE_BINDINGS_FILE = path.join(__dirname, 'data', 'device-bindings.json');
function loadDeviceBindings() {
  try {
    return JSON.parse(fs.readFileSync(DEVICE_BINDINGS_FILE, 'utf8'));
  } catch {
    return {};
  }
}
function saveDeviceBindings(bindings) {
  fs.mkdirSync(path.dirname(DEVICE_BINDINGS_FILE), { recursive: true });
  fs.writeFileSync(DEVICE_BINDINGS_FILE, JSON.stringify(bindings, null, 2));
}
let deviceBindings = loadDeviceBindings();

const PIN_SECRET = process.env.PIN_SECRET || 'hps-sharescreen-2024';

// Generate a 4-digit PIN that rotates daily per room
function getRoomPin(room) {
  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const hash = crypto.createHash('sha256').update(`${PIN_SECRET}:${room}:${today}`).digest('hex');
  return String(parseInt(hash.slice(0, 8), 16) % 10000).padStart(4, '0');
}

app.use(express.static(path.join(__dirname, 'public')));

// API: list available rooms
app.get('/api/rooms', (req, res) => {
  res.json(ROOMS);
});

// API: build date (baked in during docker build)
const BUILD_DATE = (() => {
  try { return fs.readFileSync(path.join(__dirname, '.build-date'), 'utf8').trim(); }
  catch { return null; }
})();
app.get('/api/version', (req, res) => {
  res.json({ buildDate: BUILD_DATE });
});

// API: room PIN (for display page only — shown on TV)
app.get('/api/pin/:room', (req, res) => {
  const room = req.params.room;
  if (!ROOMS.includes(room)) return res.status(404).json({ error: 'Room not found' });
  res.json({ pin: getRoomPin(room) });
});

// API: ICE server configuration (STUN only)
app.get('/api/ice-config', (req, res) => {
  res.json({
    iceServers: [
      { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] }
    ]
  });
});

// Idle screen image for C++ receiver — rendered on first request, then cached
const { renderIdleImage } = require('./idle-image');

app.get('/:room/idle.png', async (req, res) => {
  const room = req.params.room;
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');

  const cacheDir = path.join(__dirname, 'public', 'idle');
  const cacheFile = path.join(cacheDir, `${room}.png`);

  // Serve cached file
  if (fs.existsSync(cacheFile)) {
    return res.sendFile(cacheFile);
  }

  // Generate on demand
  try {
    fs.mkdirSync(cacheDir, { recursive: true });
    const png = await renderIdleImage(room);
    fs.writeFileSync(cacheFile, png);
    res.sendFile(cacheFile);
  } catch (err) {
    console.error(`Failed to generate idle image for ${room}:`, err.message);
    res.status(503).send('Idle image generation failed');
  }
});

// Receiver source tarball for Pi updates
const { execSync } = require('child_process');
app.get('/api/receiver.tar.gz', (req, res) => {
  try {
    const tarball = execSync('tar czf - -C receiver src CMakeLists.txt', {
      cwd: __dirname,
      maxBuffer: 10 * 1024 * 1024
    });
    res.set('Content-Type', 'application/gzip');
    res.send(tarball);
  } catch (err) {
    res.status(500).send('Failed to create tarball');
  }
});

// Admin page (basic auth)
const ADMIN_PASS = process.env.ADMIN_PASS || 'admin';
app.get('/admin', (req, res) => {
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Basic ' + Buffer.from('admin:' + ADMIN_PASS).toString('base64')) {
    res.set('WWW-Authenticate', 'Basic realm="ShareScreen Admin"');
    return res.status(401).send('Unauthorized');
  }
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// Display page for idle image rendering (Puppeteer only)
app.get('/:room/display', (req, res) => {
  const room = req.params.room;
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');
  res.sendFile(path.join(__dirname, 'public', 'display.html'));
});

// Room URL redirects to share page — display is Pi-only
app.get('/:room', (req, res) => {
  const room = req.params.room;
  if (room === 'share' || room === 'api' || room === 'admin') return res.status(404).send('Not found');
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');
  res.redirect(`/${room}/share`);
});

// Share page (visitor's device)
app.get('/:room/share', (req, res) => {
  const room = req.params.room;
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');
  res.sendFile(path.join(__dirname, 'public', 'share.html'));
});

// Track active sessions per room
const rooms = {};

// Track unclaimed TV devices waiting for room assignment
const devices = {}; // { deviceCode: { socketId, name, connectedAt } }

io.on('connection', (socket) => {
  let currentRoom = null;
  let role = null;

  // Device registration — unclaimed TV waiting for room assignment
  socket.on('register-device', ({ name }) => {
    const deviceName = name || 'TV';
    role = 'device';

    // If this device name has a remembered room binding AND that room
    // still exists, auto-assign without requiring an admin pair.
    const boundRoom = deviceBindings[deviceName];
    if (boundRoom && ROOMS.includes(boundRoom)) {
      socket.emit('assign-room', { room: boundRoom, server: BASE_URL });
      console.log(`Device ${deviceName} auto-assigned to remembered room ${boundRoom}`);
      broadcastAdminStatus();
      return;
    }

    const code = String(Math.floor(1000 + Math.random() * 9000));
    devices[code] = { socketId: socket.id, name: deviceName, connectedAt: new Date() };
    socket.emit('device-registered', { code });
    console.log(`Device registered: ${deviceName} (code: ${code})`);
    broadcastAdminStatus();
  });

  socket.on('join', ({ room, type, pin }) => {
    // Sharers and viewers must provide correct PIN
    if (type === 'sharer' || type === 'viewer') {
      const correctPin = getRoomPin(room);
      if (pin !== correctPin) {
        socket.emit('pin-error', { message: 'Falscher PIN' });
        return;
      }
      // Reject if someone else is already sharing
      if (!rooms[room]) rooms[room] = { display: null, sharer: null };
      if (rooms[room].sharer && rooms[room].sharer !== socket.id) {
        const existingSocket = io.sockets.sockets.get(rooms[room].sharer);
        if (existingSocket) {
          socket.join(room);
          currentRoom = room;
          role = 'waiting';
          socket.emit('sharer-busy');
          return;
        }
      }
    }

    currentRoom = room;
    role = type;
    socket.join(room);

    if (!rooms[room]) rooms[room] = { display: null, sharer: null };

    // Viewers just join the room for status updates — no slot tracking
    if (type === 'viewer') {
      io.to(room).emit('room-status', {
        hasDisplay: !!rooms[room].display,
        hasSharer: !!rooms[room].sharer
      });
      return;
    }

    // Kick stale socket if a new one joins with the same role
    const oldId = rooms[room][type];
    if (oldId && oldId !== socket.id) {
      const oldSocket = io.sockets.sockets.get(oldId);
      if (oldSocket) oldSocket.leave(room);
    }
    rooms[room][type] = socket.id;

    if (type === 'sharer' && rooms[room].display) {
      socket.emit('ready');
    }
    if (type === 'display') {
      if (rooms[room].sharer) {
        io.to(rooms[room].sharer).emit('ready');
      }
    }

    io.to(room).emit('room-status', {
      hasDisplay: !!rooms[room].display,
      hasSharer: !!rooms[room].sharer
    });
    broadcastAdminStatus();
  });

  // WebRTC signaling
  socket.on('offer', ({ room, offer }) => {
    socket.to(room).emit('offer', { offer });
  });

  socket.on('answer', ({ room, answer }) => {
    socket.to(room).emit('answer', { answer });
  });

  socket.on('ice-candidate', ({ room, candidate }) => {
    socket.to(room).emit('ice-candidate', { candidate });
  });

  socket.on('image-share', ({ room, image }) => {
    socket.to(room).emit('image-share', { image });
  });

  socket.on('stop-sharing', () => {
    if (currentRoom) {
      socket.to(currentRoom).emit('sharing-stopped');
      if (rooms[currentRoom]?.sharer === socket.id) {
        rooms[currentRoom].sharer = null;
      }
      io.to(currentRoom).emit('room-status', {
        hasDisplay: !!rooms[currentRoom]?.display,
        hasSharer: !!rooms[currentRoom]?.sharer
      });
      broadcastAdminStatus();
    }
  });

  // Admin commands
  socket.on('admin-reboot', ({ room }) => {
    if (role !== 'admin') return;
    if (rooms[room]?.display) {
      io.to(rooms[room].display).emit('reboot');
      console.log(`Admin: reboot sent to ${room}`);
    }
  });

  socket.on('admin-clear-idle', ({ room }) => {
    if (role !== 'admin') return;
    const cacheFile = path.join(__dirname, 'public', 'idle', `${room}.png`);
    try { fs.unlinkSync(cacheFile); } catch {}
    // Tell Pi to re-fetch idle image
    if (rooms[room]?.display) {
      io.to(rooms[room].display).emit('refresh-idle');
    }
    console.log(`Admin: idle image cleared for ${room}`);
  });

  socket.on('admin-add-room', ({ room }) => {
    if (role !== 'admin') return;
    const name = room?.trim();
    if (!name || ROOMS.includes(name)) return;
    ROOMS.push(name);
    saveRooms(ROOMS);
    console.log(`Admin: added room ${name}`);
    broadcastAdminStatus();
  });

  socket.on('admin-remove-room', ({ room }) => {
    if (role !== 'admin') return;
    const idx = ROOMS.indexOf(room);
    if (idx === -1) return;
    ROOMS.splice(idx, 1);
    saveRooms(ROOMS);
    delete rooms[room];
    // Remove cached idle image
    const cacheFile = path.join(__dirname, 'public', 'idle', `${room}.png`);
    try { fs.unlinkSync(cacheFile); } catch {}
    console.log(`Admin: removed room ${room}`);
    broadcastAdminStatus();
  });

  socket.on('admin-update-pi', ({ room }) => {
    if (role !== 'admin') return;
    if (rooms[room]?.display) {
      io.to(rooms[room].display).emit('update');
      console.log(`Admin: update sent to ${room}`);
    }
  });

  socket.on('admin-assign-device', ({ code, room }) => {
    if (role !== 'admin') return;
    const device = devices[code];
    if (!device) return;
    const deviceSocket = io.sockets.sockets.get(device.socketId);
    if (!deviceSocket) {
      delete devices[code];
      broadcastAdminStatus();
      return;
    }
    // Tell the device which room to join
    deviceSocket.emit('assign-room', { room, server: BASE_URL });
    // Remember this device → room so it auto-rejoins on reboot
    deviceBindings[device.name] = room;
    saveDeviceBindings(deviceBindings);
    delete devices[code];
    console.log(`Admin: assigned device ${device.name} (code ${code}) to room ${room} [persisted]`);
    broadcastAdminStatus();
  });

  socket.on('admin-unbind-device', ({ name }) => {
    if (role !== 'admin') return;
    if (deviceBindings[name]) {
      delete deviceBindings[name];
      saveDeviceBindings(deviceBindings);
      console.log(`Admin: unbound device ${name}`);
      broadcastAdminStatus();
    }
  });

  socket.on('admin-reset-device', ({ room }) => {
    if (role !== 'admin') return;
    if (rooms[room]?.display) {
      io.to(rooms[room].display).emit('reset-device');
      console.log(`Admin: reset device in ${room}`);
    }
  });

  socket.on('disconnect', () => {
    if (currentRoom && rooms[currentRoom]) {
      if (rooms[currentRoom][role] === socket.id) {
        rooms[currentRoom][role] = null;
        if (role === 'sharer') {
          io.to(currentRoom).emit('sharing-stopped');
        }
      }
      io.to(currentRoom).emit('room-status', {
        hasDisplay: !!rooms[currentRoom].display,
        hasSharer: !!rooms[currentRoom].sharer
      });
    }
    // Clean up device registrations
    for (const [code, dev] of Object.entries(devices)) {
      if (dev.socketId === socket.id) {
        delete devices[code];
      }
    }
    broadcastAdminStatus();
  });
});

// Broadcast room status to all admin sockets
function broadcastAdminStatus() {
  const status = {};
  for (const room of ROOMS) {
    status[room] = {
      display: !!rooms[room]?.display,
      sharer: !!rooms[room]?.sharer,
      pin: getRoomPin(room),
    };
  }
  // Include unclaimed devices
  const deviceList = {};
  for (const [code, dev] of Object.entries(devices)) {
    const sock = io.sockets.sockets.get(dev.socketId);
    if (sock) {
      deviceList[code] = { name: dev.name, connectedAt: dev.connectedAt };
    } else {
      delete devices[code];
    }
  }
  io.to('__admin').emit('admin-status', status);
  io.to('__admin').emit('admin-devices', deviceList);
  io.to('__admin').emit('admin-device-bindings', deviceBindings);
}

// At midnight (when getRoomPin rotates), invalidate every cached idle.png
// and tell every paired display to re-fetch its idle image so the new
// daily PIN is rendered.
function refreshAllIdles(reason) {
  for (const room of ROOMS) {
    const cacheFile = path.join(__dirname, 'public', 'idle', `${room}.png`);
    try { fs.unlinkSync(cacheFile); } catch {}
    if (rooms[room]?.display) {
      io.to(rooms[room].display).emit('refresh-idle');
    }
  }
  console.log(`refreshAllIdles: ${reason}`);
}

function scheduleMidnightRefresh() {
  const now = new Date();
  const nextMidnight = new Date(
    now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 5
  );
  const ms = nextMidnight.getTime() - now.getTime();
  setTimeout(() => {
    refreshAllIdles('daily PIN rotation');
    scheduleMidnightRefresh();
  }, ms);
  console.log(`Next idle refresh scheduled in ${(ms / 60000).toFixed(1)} min`);
}
scheduleMidnightRefresh();

// mDNS advertisement for local network discovery
const { Bonjour } = require('bonjour-service');
const bonjour = new Bonjour();

server.listen(PORT, () => {
  console.log(`ShareScreen server running on port ${PORT}`);
  console.log(`Rooms: ${ROOMS.join(', ')}`);
  console.log(`Base URL: ${BASE_URL}`);

  bonjour.publish({
    name: 'ShareScreen',
    type: 'sharescreen',
    port: Number(PORT),
    txt: { url: BASE_URL, version: '1.0' }
  });
  console.log(`mDNS: advertising _sharescreen._tcp on port ${PORT}`);
});
