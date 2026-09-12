import { chromium } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { serve } from "./server.mjs";
const server = await serve();
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 630 },
    deviceScaleFactor: 1,
    reducedMotion: "reduce",
  });
  await page.goto(server.url + "/social.html");
  await page
    .locator(".social-card")
    .screenshot({ path: "src/assets/social.png" });
  await page.setViewportSize({ width: 180, height: 180 });
  await page.goto(server.url + "/assets/icon.svg");
  await page.screenshot({
    path: "src/assets/apple-touch-icon.png",
    omitBackground: true,
  });
  await mkdir("test-results", { recursive: true });
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(server.url);
  await page.screenshot({ path: "test-results/desktop.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "test-results/mobile.png", fullPage: true });
} finally {
  await browser.close();
  await server.close();
}
