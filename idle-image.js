const puppeteer = require('puppeteer');
const path = require('path');
const fs = require('fs');

const PORT = process.env.PORT || '3000';
const BASE_URL = process.env.IDLE_BASE_URL || `http://localhost:${PORT}`;
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
    await page.goto(`${BASE_URL}/${room}`, { waitUntil: 'networkidle0', timeout: 15000 });

    await page.evaluate(() => {
      document.querySelector('.status-bar')?.remove();
      document.getElementById('video-screen')?.remove();
      document.getElementById('image-screen')?.remove();
      document.querySelectorAll('script').forEach(s => s.remove());
    });

    await new Promise(r => setTimeout(r, 300));
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
