import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
const read = (file) =>
  readFile(new URL("../dist/" + file, import.meta.url), "utf8");
test("published HTML has complete metadata, structured facts, and working local assets", async () => {
  for (const file of [
    "index.html",
    "guide/index.html",
    "privacy/index.html",
    "404.html",
  ]) {
    const html = await read(file);
    assert.doesNotMatch(html, /__[A-Z_]+__/);
    assert.equal((html.match(/<h1[ >]/g) || []).length, 1);
    assert.match(html, /<meta\s+name="description"/);
    assert.match(html, /<link rel="canonical" href="https:\/\//);
    for (const [, url] of html.matchAll(/(?:src|href)="(\/[^"#]*)"/g)) {
      const filePath = url.endsWith("/") ? url + "index.html" : url;
      assert.ok(
        (await stat(new URL("../dist" + filePath, import.meta.url))).isFile(),
        url,
      );
    }
  }
  const html = await read("index.html");
  const schema = JSON.parse(
    html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1],
  );
  const app = schema["@graph"].find(
    (x) => x["@type"] === "SoftwareApplication",
  );
  const release = JSON.parse(await read("release.json"));
  assert.equal(app.softwareVersion, release.version);
  assert.equal(app.downloadUrl, release.dmg);
  assert.equal(app.offers.price, "0");
  for (const url of [
    release.dmg,
    release.pkg,
    release.checksums,
    release.releaseUrl,
  ])
    assert.ok(html.includes(url));
  assert.match(
    release.dmg,
    /^https:\/\/github.com\/Sweet-Papa-Technologies\/FoFo-Audio-Booster\/releases\/download\/v[\d.]+\/FoFoBooster-[\d.]+\.dmg$/,
  );
});
test("crawler documents agree on the canonical site and avoid indexing missing pages", async () => {
  const html = await read("index.html");
  const canonical = html.match(/rel="canonical" href="([^"]+)"/)[1];
  const origin = new URL(canonical).origin;
  for (const file of [
    "robots.txt",
    "sitemap.xml",
    "llms.txt",
    "index.md",
    "llms-full.txt",
  ])
    assert.ok((await read(file)).includes(origin), file);
  assert.equal(await read("LLM.txt"), await read("llms.txt"));
  assert.match(await read("404.html"), /noindex,follow/);
  assert.doesNotMatch(await read("sitemap.xml"), /404|social/);
});
