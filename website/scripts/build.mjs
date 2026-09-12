import { readFile, writeFile, mkdir, rm, cp } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(await readFile(path.join(root, "site.json")));
const release = JSON.parse(await readFile(path.join(root, "release.json")));
const origin = new URL(process.env.SITE_URL || config.url).origin;
if (!origin.startsWith("https://")) throw Error("SITE_URL must use HTTPS.");
const out = path.join(root, "dist");
await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await cp(path.join(root, "src"), out, { recursive: true });
const repo = `https://github.com/${config.repository}`;
const escape = (s) =>
  String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
const faqs = [
  [
    "Is FoFoBooster really free?",
    "Yes. FoFoBooster is free to download and use, with no subscription, account, or advertising. The source is available on GitHub under the Apache 2.0 license.",
  ],
  [
    "Will it work on my Mac?",
    "FoFoBooster requires macOS 14.4 or later. One universal download supports Apple silicon and Intel Macs. Start with a comfortable system volume and test it with your own output device.",
  ],
  [
    "Why does it ask to record system audio?",
    "macOS uses system audio recording permission for apps that capture and process other apps’ sound. FoFoBooster uses that audio locally for boosting, effects, and visualization. It does not save recordings or upload audio.",
  ],
  [
    "Does it work with Bluetooth headphones?",
    "Yes, it can process audio sent to Bluetooth outputs. It also detects low-quality call mode and offers a built-in microphone switch with undo. It cannot override headphone firmware limits or prevent every Bluetooth reconnection.",
  ],
  [
    "Can I use my own plugins?",
    "FoFoBooster hosts compatible AUv2 and AUv3 Audio Unit effects, with up to eight slots per output device. Apple EQ, Dynamics, Peak Limiter, and Time/Pitch options are included as starting points. VST and VST3 plugins are not supported.",
  ],
  [
    "What if the sound isn’t right?",
    "Use the power button or the default Option–Shift–B shortcut to bypass processing and return to original audio. Try a lower boost and disable effects one at a time. Protected media may not be capturable, and actual output or format changes may briefly interrupt playback.",
  ],
  [
    "How do updates work?",
    "The app supports signed updates through Sparkle. Automatic checks can be disabled in Settings. Downloads and release notes are hosted on GitHub; you can also install a newer version manually.",
  ],
];
const bars = (count, multiplier = 1) =>
  Array.from({ length: count }, (_, i) => {
    const center = (count - 1) / 2;
    const envelope = Math.exp(-Math.pow((i - center) / (count * 0.29), 2));
    const height = Math.round(
      (12 +
        envelope * (65 + Math.sin(i * 1.7) * 24 + Math.cos(i * 0.37) * 28)) *
        multiplier,
    );
    return `<i style="--bar:${height};--i:${i}"></i>`;
  }).join("");
const schema = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": `${origin}/#organization`,
      name: "Sweet Papa Technologies",
      url: origin,
      logo: `${origin}/assets/icon.svg`,
      sameAs: ["https://github.com/Sweet-Papa-Technologies"],
    },
    {
      "@type": "WebSite",
      "@id": `${origin}/#website`,
      name: "FoFoBooster",
      url: origin,
      publisher: { "@id": `${origin}/#organization` },
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${origin}/#app`,
      name: "FoFoBooster",
      applicationCategory: "MultimediaApplication",
      operatingSystem: "macOS 14.4 or later",
      softwareVersion: release.version,
      description:
        "A free, open-source Mac volume booster with per-app controls, device profiles, Audio Unit effects, and peak protection.",
      url: origin,
      downloadUrl: release.dmg,
      image: `${origin}/assets/social.png`,
      isAccessibleForFree: true,
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      author: { "@id": `${origin}/#organization` },
      license: `${repo}/blob/main/LICENSE`,
      sameAs: repo,
    },
    {
      "@type": "FAQPage",
      "@id": `${origin}/#faq`,
      mainEntity: faqs.map(([name, text]) => ({
        "@type": "Question",
        name,
        acceptedAnswer: { "@type": "Answer", text },
      })),
    },
  ],
};
const values = {
  SITE_URL: origin,
  VERSION: escape(release.version),
  DOWNLOAD_DMG: escape(release.dmg),
  DOWNLOAD_PKG: escape(release.pkg),
  CHECKSUMS: escape(release.checksums),
  RELEASE_URL: escape(release.releaseUrl),
  STRUCTURED_DATA: JSON.stringify(schema).replaceAll("<", "\\u003c"),
  WAVE_BARS: bars(55),
  LIMITER_BARS: bars(25),
  VISUALIZER_BARS: bars(64),
  PARTICLES: Array.from(
    { length: 28 },
    (_, i) =>
      `<i style="--x:${(i * 37 + 13) % 97};--y:${(i * 19 + 11) % 75};--size:${3 + (i % 5)}"></i>`,
  ).join(""),
  FAQ_ITEMS: faqs
    .map(
      ([q, a]) =>
        `<details><summary>${escape(q)}</summary><p>${escape(a)}</p></details>`,
    )
    .join("\n"),
};
let html = await readFile(path.join(out, "index.html"), "utf8");
html = html.replace(/__([A-Z_]+)__/g, (_, key) => {
  if (!(key in values)) throw Error(`Unknown placeholder ${key}`);
  return values[key];
});
await writeFile(path.join(out, "index.html"), html);
const nav = `<header class="site-header wrap"><a class="brand" href="/"><img src="/assets/icon.svg" width="36" height="36" alt=""><span>FoFo<span class="brand-light">Booster</span></span></a><a class="button button-small button-dark" href="${escape(release.dmg)}">Download for Mac ↗</a></header>`;
const footer = `<footer class="wrap site-footer"><div><a class="brand" href="/">FoFoBooster</a><p>Made by Sweet Papa Technologies.</p></div><nav aria-label="Footer navigation"><a href="/guide/">Guide</a><a href="/privacy/">Privacy</a><a href="${repo}">GitHub ↗</a><a href="/llms.txt">llms.txt</a></nav></footer>`;
async function documentPage(
  slug,
  title,
  description,
  content,
  noindex = false,
) {
  const url = origin + (slug === "404" ? "/404.html" : `/${slug}/`);
  const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escape(title)} — FoFoBooster</title><meta name="description" content="${escape(description)}"><meta name="robots" content="${noindex ? "noindex,follow" : "index,follow"}"><link rel="canonical" href="${url}"><meta property="og:title" content="${escape(title)} — FoFoBooster"><meta property="og:description" content="${escape(description)}"><meta property="og:type" content="website"><meta property="og:url" content="${url}"><meta property="og:image" content="${origin}/assets/social.png"><meta name="twitter:card" content="summary_large_image"><link rel="icon" href="/assets/icon.svg" type="image/svg+xml"><link rel="stylesheet" href="/assets/site.css"></head><body><a class="skip-link" href="#main">Skip to content</a>${nav}<main id="main" class="document wrap${noindex ? " not-found" : ""}"><p class="eyebrow">FOFOBOOSTER / ${escape(title.toUpperCase())}</p><h1>${escape(title)}</h1><p class="intro">${escape(description)}</p>${content}</main>${footer}</body></html>`;
  const dir = noindex ? out : path.join(out, slug);
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, noindex ? "404.html" : "index.html"), page);
}
await documentPage(
  "guide",
  "A little help getting started.",
  "From download to your first boost, without the guesswork.",
  `
<h2>1. Install the app</h2><p>Download FoFoBooster ${escape(release.version)} for macOS 14.4 or later. Open the DMG and drag the app into Applications. If you already have an older copy running, quit it before opening the new version.</p><p><a href="${escape(release.pkg)}">A signed PKG installer</a> is also available. Both downloads support Apple silicon and Intel. The app and installers are Developer ID signed and notarized by Apple.</p>
<h2>2. Allow system audio access</h2><p>Launch FoFoBooster from Applications and follow its onboarding. When macOS asks for system audio recording access, allow it so the app can process other apps’ sound. The setting’s wording varies with macOS; look for system audio recording under System Settings → Privacy &amp; Security.</p><p>This permission enables live processing and visualization. FoFoBooster does not write audio recordings or upload sound. If you previously denied access, enable it in System Settings and reopen the app.</p>
<h2>3. Find a comfortable level</h2><p>Open the menu-bar panel and choose your output. Start at a comfortable system volume, then increase Master boost a little at a time. You can boost an individual app, mute it, or solo it. The default boost cap is +12 dB; extended boost up to +24 dB requires acknowledgement in Settings.</p><p>Peak protection limits digital peaks; it does not measure headphone loudness or guarantee a safe listening level. Boost cannot restore detail lost to distortion or a low-quality Bluetooth call profile.</p>
<h2>4. Make it yours</h2><p>Your levels, balance, mono setting, and plugin chain are saved by output device. Add compatible Audio Units in Plugins, or choose an Apple effect to start. Effects run in a separate host with one shared buffer of added latency. Try the Visualizer for five Metal-powered styles.</p>
<h2>Return to original audio, instantly</h2><p>Use the power button or the default <kbd>⌥</kbd><kbd>⇧</kbd><kbd>B</kbd> shortcut to bypass. This tears down processing and returns sound to the normal system route. Keyboard shortcuts are customizable in Settings.</p>
<h2>If something sounds wrong</h2><ul><li>Lower the boost, then bypass effects one at a time.</li><li>If Bluetooth audio sounds muffled, check Fix issues for call-mode detection and the built-in microphone option. You can undo that microphone change.</li><li>Protected or DRM media may return silent audio to a tap. Bypass processing for content that cannot be captured.</li><li>Unrelated background app changes should preserve your plugin chain in version 0.1.1 and later. Actual device, format, or controlled-app routing changes can still require reconfiguration.</li><li>Use Settings → Uninstall if you want to remove the app and its saved settings.</li></ul>
<h2>Updates and download verification</h2><p>The app supports Sparkle updates signed with its update key. You can disable automatic checks in Settings. The website links to public GitHub releases produced by the signing pipeline.</p><p>To verify a downloaded DMG, run <code>shasum -a 256 FoFoBooster-${escape(release.version)}.dmg</code> in the download directory and compare it with <a href="${escape(release.checksums)}">SHA256SUMS</a>.</p><p><a href="${repo}/issues">Report a problem on GitHub</a> with your macOS version, output device, and steps to reproduce it. Avoid including private audio or sensitive logs.</p><a class="button button-orange" href="${escape(release.dmg)}">Download for Mac ↓</a>`,
);
await documentPage(
  "privacy",
  "Your sound stays yours.",
  "A straightforward privacy policy for FoFoBooster and this website.",
  `
<p>Updated September 12, 2026. FoFoBooster is made by Sweet Papa Technologies.</p><h2>Audio processing</h2><p>FoFoBooster captures audio locally using macOS system audio APIs to provide volume adjustment, effects, and visualization. The app does not save audio recordings or upload audio to us. System audio permission is required for processing other apps’ sound.</p><h2>Settings and plugins</h2><p>Device profiles, app levels, plugin state, and preferences are stored locally on your Mac. The widget shares a small amount of local state with the app. Third-party Audio Units are independent software; their own data practices apply. Use plugins you trust.</p><h2>Update checks and downloads</h2><p>The app can contact GitHub-hosted release endpoints through Sparkle to check for and download signed updates. Automatic checks can be disabled in Settings. Those network requests expose standard connection information, such as your IP address, to the hosting provider. <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub’s privacy statement</a> explains its practices.</p><h2>This website</h2><p>We do not add analytics, advertising pixels, tracking cookies, contact forms, or account registration to this site. Fonts, artwork, styles, and scripts are served from the site itself. The previews do not access your microphone, system audio, or files, and they do not play sound.</p><p>The website is hosted on Google Firebase Hosting, which processes connection data to serve and secure requests. <a href="https://policies.google.com/privacy">Google’s privacy policy</a> covers its services. Download and source links take you to GitHub.</p><h2>Support</h2><p>If you open an issue on GitHub, what you submit may be public. Please don’t include private recordings, credentials, or sensitive logs. For questions about this policy, <a href="${repo}/issues">contact us through the project’s issue tracker</a>.</p>`,
);
await documentPage(
  "404",
  "A little off track.",
  "That page isn’t here. Let’s get you back to the good stuff.",
  `<a class="button button-orange" href="/">Back to FoFoBooster ↗</a>`,
  true,
);
const summary = `# FoFoBooster\n\n> FoFoBooster is a free, open-source native macOS volume booster from Sweet Papa Technologies. It requires macOS 14.4 or later and supports Apple silicon and Intel.\n\n## Product\n- [Overview](${origin}/): Per-app and master boost, mute/solo, device profiles, peak protection, up to eight Audio Unit effects, and five visualizers.\n- [Getting started](${origin}/guide/): Installation, system audio permission, bypass, and troubleshooting.\n- [Privacy](${origin}/privacy/): Local audio processing, preferences, update checks, and hosting privacy.\n- [Plain-text overview](${origin}/index.md): Human-readable Markdown product facts.\n\n## Downloads and source\n- [Download ${release.version} for Mac](${release.dmg}): Signed and notarized universal DMG.\n- [PKG installer](${release.pkg}): Alternative signed and notarized installer.\n- [Release notes](${release.releaseUrl}): Public release built by GitHub Actions.\n- [SHA256 checksums](${release.checksums}): Download verification.\n- [Source and issues](${repo}): Apache 2.0 source code and support.\n\n## Compatibility and limits\nThis is a direct-download macOS app, not an App Store listing. It hosts AUv2/AUv3 effects, not VST/VST3. Audio remains local and is not recorded or uploaded by FoFoBooster. Third-party plugins have their own privacy practices. DRM/protected audio may not be capturable. Digital peak protection does not guarantee a safe acoustic listening level. Hardware and plugin compatibility vary. Website visualizations are illustrative, silent previews.\n`;
await writeFile(path.join(out, "llms.txt"), summary);
await writeFile(path.join(out, "llm.txt"), summary);
await writeFile(path.join(out, "LLM.txt"), summary);
const faqMarkdown = faqs.map(([q, a]) => `## ${q}\n\n${a}`).join("\n\n");
await writeFile(
  path.join(out, "index.md"),
  summary + "\n" + faqMarkdown + "\n",
);
await writeFile(
  path.join(out, "llms-full.txt"),
  summary + "\n" + faqMarkdown + "\n",
);
await writeFile(
  path.join(out, "robots.txt"),
  `User-agent: *\nAllow: /\n\nSitemap: ${origin}/sitemap.xml\n`,
);
await writeFile(
  path.join(out, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${["/", "/guide/", "/privacy/"].map((p) => `<url><loc>${origin}${p}</loc></url>`).join("")}</urlset>`,
);
await writeFile(
  path.join(out, "site.webmanifest"),
  JSON.stringify(
    {
      name: "FoFoBooster",
      short_name: "FoFoBooster",
      description: "Free Mac audio boost and per-app control.",
      start_url: "/",
      display: "browser",
      background_color: "#f6f3ec",
      theme_color: "#f6f3ec",
      icons: [
        {
          src: "/assets/icon.svg",
          sizes: "any",
          type: "image/svg+xml",
          purpose: "any",
        },
      ],
    },
    null,
    2,
  ),
);
await writeFile(
  path.join(out, "humans.txt"),
  "Made by Sweet Papa Technologies.\nNative app: Swift, C++, Core Audio, and Metal.\nWebsite: semantic HTML, CSS, and a little JavaScript.\nNo tracking scripts.\n",
);
await writeFile(
  path.join(out, "release.json"),
  JSON.stringify(release, null, 2),
);
const hash = createHash("sha256")
  .update(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])
  .digest("base64");
const hosting = {
  hosting: {
    site: config.hostingSite,
    public: "website/dist",
    ignore: ["firebase.json", "**/.*", "**/node_modules/**"],
    cleanUrls: true,
    trailingSlash: true,
    redirects: [
      { source: "/LLM.txt", destination: "/llms.txt", type: 301 },
      { source: "/llm.txt", destination: "/llms.txt", type: 301 },
    ],
    headers: [
      {
        source: "**",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
          {
            key: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=()",
          },
          {
            key: "Content-Security-Policy",
            value: `default-src 'self'; script-src 'self' 'sha256-${hash}'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'`,
          },
          {
            key: "Cache-Control",
            value: "public, max-age=300, must-revalidate",
          },
        ],
      },
      {
        source: "/assets/**",
        headers: [{ key: "Cache-Control", value: "public, max-age=86400" }],
      },
      {
        source: "**/*.txt",
        headers: [{ key: "Content-Type", value: "text/plain; charset=utf-8" }],
      },
      {
        source: "**/*.md",
        headers: [
          { key: "Content-Type", value: "text/markdown; charset=utf-8" },
        ],
      },
      {
        source: "/site.webmanifest",
        headers: [{ key: "Content-Type", value: "application/manifest+json" }],
      },
    ],
  },
};
await writeFile(
  path.resolve(root, "../firebase.json"),
  JSON.stringify(hosting, null, 2) + "\n",
);
console.log(`Built FoFoBooster ${release.version} website for ${origin}.`);
