// Render a 1280x720 PNG showing a QR code that opens a mailto: link
// pre-filled with the device id, plus the device id and a status word.
// Uses the same puppeteer instance as idle-image.

const puppeteer = require('puppeteer-core');

const PORT = process.env.PORT || '3000';
const RENDER_URL = process.env.IDLE_BASE_URL || `http://localhost:${PORT}`;
const REGISTRATION_EMAIL = process.env.REGISTRATION_EMAIL || 'mail@klausschwarz.net';
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

const STATUS_LABELS = {
  checking:     'Contacting license server…',
  not_licensed: 'Not licensed yet — scan the QR to request access.',
  license_ok:   'License OK — looking for sharescreen server…',
  connecting:   'Connecting to sharescreen server…',
  default:      'Waiting…',
};

async function renderRegistrationImage(deviceId, status) {
  const b = await getBrowser();
  const page = await b.newPage();
  await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 1 });

  const statusText = STATUS_LABELS[status] || STATUS_LABELS.default;
  const url = `${RENDER_URL}/screens/registration?id=${encodeURIComponent(deviceId)}&status=${encodeURIComponent(statusText)}`;

  try {
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 10000 });
    await page.waitForSelector('#qr-canvas', { timeout: 5000 });
    await new Promise(r => setTimeout(r, 200));
    return await page.screenshot({ type: 'png' });
  } finally {
    await page.close();
  }
}

module.exports = { renderRegistrationImage, REGISTRATION_EMAIL };
