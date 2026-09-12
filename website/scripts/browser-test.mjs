import { chromium, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { serve } from "./server.mjs";
const server = process.env.BASE_URL ? null : await serve();
const base = process.env.BASE_URL || server.url;
const browser = await chromium.launch();
const errors = [];
try {
  await mkdir("test-results", { recursive: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text());
  });
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const route of ["/", "/guide/", "/privacy/"]) {
      await page.goto(base + route);
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth > innerWidth,
      );
      assert.equal(
        overflow,
        false,
        `Horizontal overflow: ${route} at ${width}px`,
      );
      const result = await new AxeBuilder({ page })
        .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
        .analyze();
      assert.deepEqual(
        result.violations.map((v) => ({
          id: v.id,
          nodes: v.nodes.map((n) => ({
            target: n.target,
            summary: n.failureSummary,
          })),
        })),
        [],
        `${route} at ${width}px`,
      );
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(base);
  const slider = page.locator("#preview-boost");
  await slider.focus();
  await page.keyboard.press("ArrowRight");
  assert.match(await page.locator("#boost-value").textContent(), /\+7/);
  for (const preset of ["halo", "tide", "grid", "drift", "ember"]) {
    await page.locator(`button[data-preset="${preset}"]`).click();
    assert.equal(
      await page.locator(".visualizer-demo").getAttribute("data-preset"),
      preset,
    );
    assert.equal(
      await page
        .locator(`button[data-preset="${preset}"]`)
        .getAttribute("aria-pressed"),
      "true",
    );
  }
  await page.locator("#motion-toggle").click();
  assert.equal(
    await page.locator(".visualizer-demo").getAttribute("data-motion"),
    "paused",
  );
  await page.locator("summary").first().focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator("details").first().getAttribute("open"), "");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(page.locator("#motion-toggle")).toBeDisabled();
  assert.equal(
    await page.locator(".visualizer-demo").getAttribute("data-motion"),
    "paused",
  );
  await page.screenshot({ path: "test-results/desktop.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: "test-results/mobile.png", fullPage: true });
  assert.deepEqual(errors, []);
  const noJS = await browser.newContext({ javaScriptEnabled: false });
  const staticPage = await noJS.newPage();
  await staticPage.goto(base);
  assert.ok(await staticPage.locator("h1").isVisible());
  assert.ok((await staticPage.locator('a[href*=".dmg"]').count()) >= 2);
  assert.ok((await staticPage.locator("details p").count()) >= 5);
  await noJS.close();
  console.log(
    "Desktop/mobile, WCAG AA, keyboard, motion preference, and no-JavaScript checks passed.",
  );
} finally {
  await browser.close();
  await server?.close();
}
