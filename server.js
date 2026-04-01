const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;
const BASE_URL = process.env.BASE_URL || 'https://share.hotel-park-soltau.de';

// Rooms configured via environment variable (comma-separated)
const ROOMS = (process.env.ROOMS || 'Kiel,Hamburg,Bremen').split(',').map(r => r.trim());

app.use(express.static(path.join(__dirname, 'public')));

// API: list available rooms
app.get('/api/rooms', (req, res) => {
  res.json(ROOMS);
});

// Display page (Raspberry Pi) - serves for any configured room
app.get('/:room', (req, res) => {
  const room = req.params.room;
  if (room === 'share') return res.status(404).send('Not found');
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
    role = type; // 'display' or 'sharer'
    socket.join(room);

    if (!rooms[room]) rooms[room] = { display: null, sharer: null };
    rooms[room][type] = socket.id;

    // Notify display that a sharer connected (or vice versa)
    if (type === 'sharer' && rooms[room].display) {
      socket.emit('ready');
    }
    if (type === 'display') {
      // If a sharer is already waiting, tell them to start
      if (rooms[room].sharer) {
        io.to(rooms[room].sharer).emit('ready');
      }
    }

    // Notify display about connection status
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
      if (role === 'sharer') {
        io.to(currentRoom).emit('sharing-stopped');
      }
    }
  });
});

server.listen(PORT, () => {
  console.log(`ShareScreen server running on port ${PORT}`);
  console.log(`Rooms: ${ROOMS.join(', ')}`);
  console.log(`Base URL: ${BASE_URL}`);
});
