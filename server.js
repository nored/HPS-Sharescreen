const express = require('express');
const http = require('http');
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
const TURN_HOST = process.env.TURN_HOST || 'share.hotel-park-soltau.de';
const TURN_PORT = process.env.TURN_PORT || '3478';
const TURN_USER = process.env.TURN_USER || 'sharescreen';
const TURN_PASS = process.env.TURN_PASS || 'hotelparkshare2024';

const ROOMS = (process.env.ROOMS || 'Kiel,Hamburg,Bremen').split(',').map(r => r.trim());

app.use(express.static(path.join(__dirname, 'public')));

// API: list available rooms
app.get('/api/rooms', (req, res) => {
  res.json(ROOMS);
});

// API: ICE server configuration (STUN + TURN)
app.get('/api/ice-config', (req, res) => {
  res.json({
    iceServers: [
      { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
      { urls: `stun:${TURN_HOST}:${TURN_PORT}` },
      {
        urls: [
          `turn:${TURN_HOST}:${TURN_PORT}?transport=udp`,
          `turn:${TURN_HOST}:${TURN_PORT}?transport=tcp`
        ],
        username: TURN_USER,
        credential: TURN_PASS
      }
    ]
  });
});

// Display page (browser-based display, still works)
app.get('/:room', (req, res) => {
  const room = req.params.room;
  if (room === 'share' || room === 'api') return res.status(404).send('Not found');
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');
  res.sendFile(path.join(__dirname, 'public', 'display.html'));
});

// Share page (visitor's device)
app.get('/:room/share', (req, res) => {
  const room = req.params.room;
  if (!ROOMS.includes(room)) return res.status(404).send('Room not found');
  res.sendFile(path.join(__dirname, 'public', 'share.html'));
});

// Track active sessions per room
const rooms = {};

io.on('connection', (socket) => {
  let currentRoom = null;
  let role = null;

  socket.on('join', ({ room, type }) => {
    currentRoom = room;
    role = type;
    socket.join(room);

    if (!rooms[room]) rooms[room] = { display: null, sharer: null };

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
    }
  });

  socket.on('disconnect', () => {
    if (currentRoom && rooms[currentRoom]) {
      if (rooms[currentRoom][role] === socket.id) {
        rooms[currentRoom][role] = null;
      }
      io.to(currentRoom).emit('room-status', {
        hasDisplay: !!rooms[currentRoom].display,
        hasSharer: !!rooms[currentRoom].sharer
      });
    }
  });
});

server.listen(PORT, () => {
  console.log(`ShareScreen server running on port ${PORT}`);
  console.log(`Rooms: ${ROOMS.join(', ')}`);
  console.log(`Base URL: ${BASE_URL}`);
});
