// Debug panel for ShareScreen — activate with ?debug in the URL
(function () {
  if (!new URLSearchParams(window.location.search).has('debug')) {
    // Expose no-op so calling code doesn't need guards
    window.dbg = () => {};
    return;
  }

  // --- Create panel ---
  const panel = document.createElement('div');
  panel.id = 'debug-panel';
  panel.innerHTML = `
    <div id="dbg-header">
      <span>DEBUG</span>
      <span id="dbg-toggle">_</span>
    </div>
    <div id="dbg-stats"></div>
    <div id="dbg-log"></div>
  `;
  document.body.appendChild(panel);

  const style = document.createElement('style');
  style.textContent = `
    #debug-panel {
      position: fixed;
      bottom: 0;
      left: 0;
      width: 100%;
      max-height: 45vh;
      background: rgba(0,0,0,0.92);
      color: #0f0;
      font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
      font-size: 11px;
      line-height: 1.5;
      z-index: 99999;
      display: flex;
      flex-direction: column;
      border-top: 2px solid #95a321;
    }
    #debug-panel.minimized #dbg-log,
    #debug-panel.minimized #dbg-stats { display: none; }
    #debug-panel.minimized { max-height: none; }
    #dbg-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 4px 10px;
      background: #95a321;
      color: #000;
      font-weight: 700;
      font-size: 11px;
      cursor: pointer;
      user-select: none;
      flex-shrink: 0;
    }
    #dbg-toggle { cursor: pointer; font-size: 14px; }
    #dbg-stats {
      padding: 6px 10px;
      border-bottom: 1px solid #333;
      display: flex;
      flex-wrap: wrap;
      gap: 6px 18px;
      flex-shrink: 0;
    }
    .dbg-stat {
      display: flex;
      gap: 4px;
    }
    .dbg-stat-label { color: #888; }
    .dbg-stat-value { color: #fff; font-weight: 600; }
    .dbg-stat-value.good { color: #4caf50; }
    .dbg-stat-value.warn { color: #ff9800; }
    .dbg-stat-value.bad { color: #f44336; }
    #dbg-log {
      overflow-y: auto;
      padding: 6px 10px;
      flex: 1;
      min-height: 0;
    }
    .dbg-line {
      white-space: pre-wrap;
      word-break: break-all;
      border-bottom: 1px solid #1a1a1a;
      padding: 1px 0;
    }
    .dbg-line .ts { color: #666; }
    .dbg-line.signal { color: #64b5f6; }
    .dbg-line.ice { color: #ce93d8; }
    .dbg-line.webrtc { color: #4caf50; }
    .dbg-line.error { color: #f44336; font-weight: 600; }
    .dbg-line.warn { color: #ff9800; }
    .dbg-line.info { color: #0f0; }
  `;
  document.head.appendChild(style);

  // Toggle minimize
  const header = document.getElementById('dbg-header');
  header.addEventListener('click', () => {
    panel.classList.toggle('minimized');
    document.getElementById('dbg-toggle').textContent = panel.classList.contains('minimized') ? '+' : '_';
  });

  const logEl = document.getElementById('dbg-log');
  const statsEl = document.getElementById('dbg-stats');
  let lineCount = 0;
  const MAX_LINES = 200;

  function ts() {
    const d = new Date();
    return d.toLocaleTimeString('de-DE', { hour12: false }) + '.' + String(d.getMilliseconds()).padStart(3, '0');
  }

  // Public logging function
  window.dbg = function (msg, category = 'info') {
    const line = document.createElement('div');
    line.className = `dbg-line ${category}`;
    line.innerHTML = `<span class="ts">${ts()}</span> ${escapeHtml(msg)}`;
    logEl.appendChild(line);
    lineCount++;

    // Trim old lines
    if (lineCount > MAX_LINES) {
      logEl.removeChild(logEl.firstChild);
      lineCount--;
    }

    // Auto-scroll
    logEl.scrollTop = logEl.scrollHeight;
  };

  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // --- Stats display ---
  const stats = {};
  window.dbgStat = function (key, value, status) {
    stats[key] = { value, status: status || 'neutral' };
    renderStats();
  };

  function renderStats() {
    statsEl.innerHTML = Object.entries(stats).map(([k, v]) => {
      const cls = v.status === 'good' ? 'good' : v.status === 'bad' ? 'bad' : v.status === 'warn' ? 'warn' : '';
      return `<div class="dbg-stat"><span class="dbg-stat-label">${escapeHtml(k)}:</span><span class="dbg-stat-value ${cls}">${escapeHtml(v.value)}</span></div>`;
    }).join('');
  }

  // --- Intercept console.warn/error ---
  const origWarn = console.warn;
  const origError = console.error;
  console.warn = function (...args) {
    origWarn.apply(console, args);
    dbg(args.map(String).join(' '), 'warn');
  };
  console.error = function (...args) {
    origError.apply(console, args);
    dbg(args.map(String).join(' '), 'error');
  };

  // --- WebRTC stats polling ---
  window.dbgWatchPc = function (pc, label) {
    if (!pc) return;

    dbgStat('PC', 'created', 'good');
    dbgStat('ICE', pc.iceConnectionState);
    dbgStat('Signal', pc.signalingState);

    pc.addEventListener('iceconnectionstatechange', () => {
      const s = pc.iceConnectionState;
      const status = s === 'connected' || s === 'completed' ? 'good' : s === 'checking' || s === 'new' ? 'warn' : 'bad';
      dbgStat('ICE', s, status);
      dbg(`[${label}] ICE connection: ${s}`, 'webrtc');
    });

    pc.addEventListener('icegatheringstatechange', () => {
      const s = pc.iceGatheringState;
      dbgStat('ICE Gather', s, s === 'complete' ? 'good' : 'warn');
      dbg(`[${label}] ICE gathering: ${s}`, 'ice');
    });

    pc.addEventListener('connectionstatechange', () => {
      const s = pc.connectionState;
      const status = s === 'connected' ? 'good' : s === 'connecting' || s === 'new' ? 'warn' : 'bad';
      dbgStat('Connection', s, status);
      dbg(`[${label}] Connection: ${s}`, 'webrtc');
    });

    pc.addEventListener('signalingstatechange', () => {
      dbgStat('Signal', pc.signalingState);
      dbg(`[${label}] Signaling: ${pc.signalingState}`, 'signal');
    });

    pc.addEventListener('icecandidate', (e) => {
      if (e.candidate && e.candidate.candidate) {
        const c = e.candidate;
        const type = c.candidate.match(/typ (\w+)/)?.[1] || '?';
        const proto = c.candidate.match(/udp|tcp/i)?.[0] || '?';
        dbg(`[${label}] Local ICE: ${type} ${proto} ${c.candidate.substring(0, 80)}...`, 'ice');
      } else {
        dbg(`[${label}] ICE gathering done (null candidate)`, 'ice');
      }
    });

    pc.addEventListener('track', (e) => {
      dbg(`[${label}] Track received: ${e.track.kind} (${e.track.id.substring(0, 8)})`, 'webrtc');
    });

    // Poll for bitrate stats every 2 seconds
    let prevBytesReceived = 0;
    let prevBytesSent = 0;
    const statsInterval = setInterval(async () => {
      if (!pc || pc.connectionState === 'closed') {
        clearInterval(statsInterval);
        return;
      }
      try {
        const report = await pc.getStats();
        let bytesReceived = 0, bytesSent = 0, fps = 0, width = 0, height = 0, codec = '';
        report.forEach(s => {
          if (s.type === 'inbound-rtp' && s.kind === 'video') {
            bytesReceived = s.bytesReceived || 0;
            fps = s.framesPerSecond || 0;
            width = s.frameWidth || 0;
            height = s.frameHeight || 0;
          }
          if (s.type === 'outbound-rtp' && s.kind === 'video') {
            bytesSent = s.bytesSent || 0;
            fps = s.framesPerSecond || fps;
            width = s.frameWidth || width;
            height = s.frameHeight || height;
          }
          if (s.type === 'codec' && s.mimeType && s.mimeType.startsWith('video/')) {
            codec = s.mimeType;
          }
        });

        if (bytesReceived > 0) {
          const kbps = Math.round((bytesReceived - prevBytesReceived) * 8 / 2000);
          prevBytesReceived = bytesReceived;
          dbgStat('Recv', `${kbps} kbps`, kbps > 100 ? 'good' : kbps > 0 ? 'warn' : 'bad');
        }
        if (bytesSent > 0) {
          const kbps = Math.round((bytesSent - prevBytesSent) * 8 / 2000);
          prevBytesSent = bytesSent;
          dbgStat('Send', `${kbps} kbps`, kbps > 100 ? 'good' : kbps > 0 ? 'warn' : 'bad');
        }
        if (fps) dbgStat('FPS', fps, fps >= 15 ? 'good' : fps > 0 ? 'warn' : 'bad');
        if (width && height) dbgStat('Resolution', `${width}x${height}`);
        if (codec) dbgStat('Codec', codec.replace('video/', ''));
      } catch (e) { /* ignore */ }
    }, 2000);
  };

  // --- Socket.IO debug ---
  window.dbgWatchSocket = function (socket) {
    dbgStat('Socket', 'connecting', 'warn');

    socket.on('connect', () => {
      dbgStat('Socket', `connected (${socket.id})`, 'good');
      dbg(`Socket connected: ${socket.id}`, 'signal');
    });

    socket.on('disconnect', (reason) => {
      dbgStat('Socket', `disconnected: ${reason}`, 'bad');
      dbg(`Socket disconnected: ${reason}`, 'error');
    });

    socket.on('connect_error', (err) => {
      dbgStat('Socket', 'error', 'bad');
      dbg(`Socket error: ${err.message}`, 'error');
    });

    // Intercept emit to log outgoing events
    const origEmit = socket.emit.bind(socket);
    socket.emit = function (event, ...args) {
      if (event !== 'ice-candidate') {
        dbg(`SEND ${event} ${args[0] ? JSON.stringify(args[0]).substring(0, 100) : ''}`, 'signal');
      } else {
        const c = args[0]?.candidate;
        if (c) {
          const type = c.candidate?.match(/typ (\w+)/)?.[1] || '?';
          dbg(`SEND ice-candidate (${type})`, 'ice');
        }
      }
      return origEmit(event, ...args);
    };

    // Log incoming signaling events
    const signalEvents = ['offer', 'answer', 'ready', 'room-status', 'sharing-stopped', 'image-share'];
    for (const event of signalEvents) {
      socket.on(event, (data) => {
        if (event === 'offer' || event === 'answer') {
          dbg(`RECV ${event} (sdp ${data?.[event]?.sdp?.length || '?'} bytes)`, 'signal');
        } else {
          dbg(`RECV ${event} ${data ? JSON.stringify(data).substring(0, 100) : ''}`, 'signal');
        }
      });
    }

    // ICE candidates logged separately
    socket.on('ice-candidate', (data) => {
      const c = data?.candidate;
      if (c && c.candidate) {
        const type = c.candidate.match(/typ (\w+)/)?.[1] || '?';
        dbg(`RECV ice-candidate (${type}) ${c.candidate.substring(0, 60)}`, 'ice');
      } else {
        dbg(`RECV ice-candidate (empty/null — filtered)`, 'ice');
      }
    });
  };

  // Log browser info
  dbg(`Browser: ${navigator.userAgent}`, 'info');
  dbg(`Page: ${window.location.href}`, 'info');
  dbgStat('Browser', /Firefox/.test(navigator.userAgent) ? 'Firefox' : /Chrome/.test(navigator.userAgent) ? 'Chrome' : /Safari/.test(navigator.userAgent) ? 'Safari' : 'Other');
  dbgStat('Role', window.location.pathname.includes('/share') ? 'Sharer' : 'Display');
})();
