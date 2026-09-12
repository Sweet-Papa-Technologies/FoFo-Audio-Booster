import { readFile, writeFile } from "node:fs/promises";
const site = JSON.parse(
  await readFile(new URL("../site.json", import.meta.url)),
);
const headers = {
  Accept: "application/vnd.github+json",
  "X-GitHub-Api-Version": "2022-11-28",
};
if (process.env.GH_TOKEN)
  headers.Authorization = `Bearer ${process.env.GH_TOKEN}`;
const response = await fetch(
  `https://api.github.com/repos/${site.repository}/releases/latest`,
  { headers },
);
if (!response.ok)
  throw Error(
    `Public release lookup failed (${response.status}); keeping existing metadata.`,
  );
const release = await response.json();
if (
  release.draft ||
  release.prerelease ||
  !/^v\d+\.\d+\.\d+$/.test(release.tag_name)
)
  throw Error("Expected a published versioned release.");
const version = release.tag_name.slice(1),
  prefix = `https://github.com/${site.repository}/releases/download/${release.tag_name}/`;
function asset(name) {
  const a = release.assets.find(
    (a) => a.name === name && a.state === "uploaded",
  );
  if (!a || a.browser_download_url !== prefix + name)
    throw Error(`Missing or unexpected ${name} asset`);
  return a.browser_download_url;
}
asset("appcast.xml");
const data = {
  version,
  tag: release.tag_name,
  releaseUrl: release.html_url,
  dmg: asset(`FoFoBooster-${version}.dmg`),
  pkg: asset(`FoFoBooster-${version}.pkg`),
  checksums: asset("SHA256SUMS"),
};
await writeFile(
  new URL("../release.json", import.meta.url),
  JSON.stringify(data, null, 2) + "\n",
);
console.log(`Using verified public release ${release.tag_name}.`);
