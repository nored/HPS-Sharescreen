import { chromium } from "playwright";

const PORT = process.env.PORT || "3000";
const BASE_URL = process.env.BASE_URL || `http://localhost:${PORT}`;
const ROOMS = (process.env.ROOMS || "Kiel,Hamburg,Bremen").split(",").map((r) => r.trim());
const OUTPUT_DIR = process.env.OUTPUT_DIR || "public/idle";
const WIDTH = 1920;
const HEIGHT = 1080;

await Bun.write(`${OUTPUT_DIR}/.gitkeep`, "");

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: WIDTH, height: HEIGHT },
  deviceScaleFactor: 1,
});

for (const room of ROOMS) {
  const page = await context.newPage();
  const url = `${BASE_URL}/${room}`;
  console.log(`Rendering ${room}...`);

  await page.goto(url, { waitUntil: "networkidle" });

  // Hide status bar and video/image screens, show only idle
  await page.evaluate(() => {
    document.querySelector(".status-bar")?.remove();
    document.getElementById("video-screen")?.remove();
    document.getElementById("image-screen")?.remove();
    // Remove all script tags (socket.io, etc)
    document.querySelectorAll("script").forEach((s) => s.remove());
  });

  // Wait for QR code to render
  await page.waitForTimeout(500);

  const path = `${OUTPUT_DIR}/${room}.png`;
  await page.screenshot({ path, type: "png" });
  console.log(`  -> ${path} (${WIDTH}x${HEIGHT})`);
  await page.close();
}

await browser.close();
console.log("Done.");
