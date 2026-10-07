// Render panorama.html and slice it into App Store screenshots.
// Usage: node render.cjs <out dir>   (needs playwright; uses the preinstalled Chromium)
const { chromium } = require("playwright");
const { readFileSync } = require("node:fs");
const { join, resolve } = require("node:path");

(async () => {

const out = resolve(process.argv[2]);
const { width, height, count } = JSON.parse(readFileSync(join(out, "slides.json"), "utf8"));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: width * count, height }, deviceScaleFactor: 1 });
await page.goto("file://" + join(out, "panorama.html"));
await page.evaluate(() => document.fonts.ready);
await page.screenshot({ path: join(out, "panorama.png"), fullPage: false });
for (let i = 0; i < count; i++) {
  await page.screenshot({
    path: join(out, `${String(i + 1).padStart(2, "0")}.png`),
    clip: { x: i * width, y: 0, width, height },
  });
}
await browser.close();
console.log("rendered", count, "slides");
})();
