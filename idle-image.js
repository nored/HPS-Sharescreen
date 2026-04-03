const puppeteer = require('puppeteer-core');
const path = require('path');
const fs = require('fs');

const PORT = process.env.PORT || '3000';
const RENDER_URL = process.env.IDLE_BASE_URL || `http://localhost:${PORT}`;
const PUBLIC_URL = process.env.BASE_URL || 'https://share.hotel-park-soltau.de';
const EXEC_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium-browser';

let browser = null;

async function getBrowser() {
  if (!browser) {
    browser = await puppeteer.launch({
      executablePath: EXEC_PATH,
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu', '--disable-dev-shm-usage'],
      headless: 'new',
    });
  }
  return browser;
}

async function renderIdleImage(room) {
  const b = await getBrowser();
  const page = await b.newPage();
  await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });

  try {
    await page.goto(`${RENDER_URL}/${room}/display`, { waitUntil: 'networkidle0', timeout: 15000 });

    // Wait for QR code canvas to render
    await page.waitForSelector('#qr-canvas', { timeout: 5000 });
    await page.waitForFunction(() => {
      const canvas = document.getElementById('qr-canvas');
      return canvas && canvas.width > 0;
    }, { timeout: 5000 });

    // Fix URLs to show real public URL instead of localhost
    await page.evaluate((publicUrl, roomName) => {
      const shareUrl = `${publicUrl}/${roomName}/share`;
      const host = publicUrl.replace(/^https?:\/\//, '');
      document.getElementById('share-url').textContent = `${host}/${roomName}`;
      // Re-render QR code with correct URL (full URL for QR)
      if (typeof QRious !== 'undefined') {
        new QRious({
          element: document.getElementById('qr-canvas'),
          value: shareUrl,
          size: 200,
          level: 'M',
          foreground: '#2a2a29',
          background: '#ffffff'
        });
      }
      document.querySelector('.status-bar')?.remove();
      document.getElementById('video-screen')?.remove();
      document.getElementById('image-screen')?.remove();
      document.querySelectorAll('script').forEach(s => s.remove());
    }, PUBLIC_URL, room);

    await new Promise(r => setTimeout(r, 500));
    return await page.screenshot({ type: 'png' });
  } finally {
    await page.close();
  }
}

// CLI mode
if (require.main === module) {
  const rooms = process.argv.slice(2);
  if (rooms.length === 0) {
    console.error('Usage: node idle-image.js <room1> [room2] ...');
    process.exit(1);
  }

  const dir = path.join(__dirname, 'public', 'idle');
  fs.mkdirSync(dir, { recursive: true });

  (async () => {
    for (const room of rooms) {
      console.log(`Rendering ${room}...`);
      const png = await renderIdleImage(room);
      fs.writeFileSync(path.join(dir, `${room}.png`), png);
      console.log(`  -> public/idle/${room}.png (1920x1080)`);
    }
    await browser?.close();
    console.log('Done.');
  })();
}

module.exports = { renderIdleImage };
