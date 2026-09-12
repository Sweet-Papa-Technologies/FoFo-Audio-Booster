# FoFoBooster website

Static HTML/CSS with small, silent JavaScript previews. No framework runtime, external fonts, analytics, audio capture, cookies, or backend. Public site: **https://fofo-booster.web.app**. Firebase project: `fofoapps-934be` (FoFoApps); Hosting site: **`fofo-booster`**.

## Develop and check

Use Node 24 and run from `website/`:

```sh
npm ci
npm run build
npm test
npx playwright install chromium
npm run test:browser
```

The browser suite checks the home, guide, and privacy pages at 1440, 768, 390, and 320 pixels, WCAG AA rules with axe, keyboard controls, reduced motion, and usable content without JavaScript. Screenshots go to ignored `test-results/`. Browser checks start their own ephemeral local server. To check the live site, set `BASE_URL=https://fofo-booster.web.app`.

Edit `src/` for the landing page, styles, and illustration. `scripts/build.mjs` owns shared facts, FAQ, supporting pages, metadata, crawler documents, and Firebase headers. `npm run build` regenerates `dist/` and the root `firebase.json`. Commit the generated Firebase config when its source changes. `node scripts/render.mjs` regenerates the social PNG and touch icon from the native HTML/SVG artwork after a build; rebuild afterward to copy the new images.

## Downloads

Every download is a versioned public GitHub release asset. Raw Actions artifacts are intentionally not linked: they require login and expire. `release.json` is the checked-in fallback for local and PR builds. `npm run sync-release` resolves the latest published stable-channel release through GitHub's API, validates its required uploaded assets, and updates that file. This runs at build time; visitors do not depend on a GitHub API call. Failure stops deployment instead of producing broken buttons.

The signed macOS workflow publishes new version tags, or a manual run with `publish=true`, only after its build and notarization jobs pass. Existing versions cannot be replaced. `scripts/publish-release.py` checks hashes, accepted notary receipts, and update-feed metadata before uploading to a draft and publishing it. See `docs/RELEASING.md` for signing. Completion of the signed workflow triggers website checks against reviewed `main`, refreshing the downloads. A manually edited/published release can be followed by **Actions → Website → Run workflow → main**.

## Deploy locally

From the repository root, after building and checking:

```sh
firebase deploy --only hosting --project fofoapps-934be
```

The root config contains only Hosting site `fofo-booster`. It does not include the project's other sites, Firestore, Storage, or Functions. Firebase's console can roll this site's live channel back to an earlier release.

## GitHub deployment identity

Website PRs run read-only checks. Production deployment uses the `website` environment, restricted to branch `main`. Actions are pinned to commits; the Firebase CLI is pinned to 15.30.0. The deploy job consumes the exact checked artifact and verifies its sole Hosting target before authentication.

Prepared keyless identity:

- Service account: `fofo-booster-hosting@fofoapps-934be.iam.gserviceaccount.com`
- Provider: `projects/851869525836/locations/global/workloadIdentityPools/fofo-booster-github/providers/github-main`
- Provider conditions require repository ID `1358727785`, `refs/heads/main`, and `.github/workflows/website.yml@refs/heads/main` in this repository.
- Only that repository identity can impersonate this service account. No service-account key is generated or stored in GitHub.

**Activation pending:** automatic approval review rejected granting project-wide `roles/firebasehosting.admin`, because it covers all Hosting sites in FoFoApps. The identity currently has no project Hosting role. Automatic deploys remain gated by the repository variable `FIREBASE_HOSTING_ENABLED`; leave it unset until that scope is explicitly approved. The website can still be deployed with the existing local Firebase login.

[Firebase documents predefined Hosting roles](https://firebase.google.com/docs/projects/iam/permissions#hosting) and does not currently support custom roles for Hosting. Hosting is not listed among [services supporting resource-name IAM conditions](https://docs.cloud.google.com/iam/docs/conditions-resource-attributes). The config's site restriction is an operational guard, not an IAM boundary.

If the project-wide scope is approved, grant the dedicated account Hosting Admin and the CLI's documented API Keys Viewer role in **FoFoApps only**, enable IAM Credentials API if needed, then set `FIREBASE_HOSTING_ENABLED=true`, dispatch Website on main, and verify the first keyless deployment. This has not yet been validated end to end. Do not substitute the existing broad Firebase admin private key.

## Switch to booster.fofo.dev

1. In [FoFoApps Hosting](https://console.firebase.google.com/project/fofoapps-934be/hosting), open site **fofo-booster** and add `booster.fofo.dev` as a custom domain. Apply Firebase's exact DNS records at the domain's DNS provider.
2. Wait until Firebase reports Connected and HTTPS works on the new domain.
3. Change `site.json`'s `url` to `https://booster.fofo.dev`, or set repository variable `WEBSITE_URL` to that origin, and rebuild/redeploy. For local deploys with the variable approach, use `SITE_URL=https://booster.fofo.dev npm run build` from `website/`.
4. Check canonical links, sitemap, Open Graph URLs, and `llms.txt` on the new domain. All are derived from the same origin. Submit the sitemap in Search Console if desired. Keep the temporary Firebase domain available; canonicals will identify the preferred domain.

Until the custom domain is connected, canonical metadata points at the functioning `web.app` address. No DNS settings have been changed.

## Discovery and privacy

The site renders all primary content without JavaScript. It includes descriptive titles, canonical URLs, SoftwareApplication/Organization/WebSite/FAQ JSON-LD, Open Graph and Twitter sharing metadata, a 1200×630 social image, favicon/touch icon, web manifest, robots.txt, and an XML sitemap. `/llms.txt`, `/llms-full.txt`, and `/index.md` offer readable product facts; `/LLM.txt` and `/llm.txt` redirect to `/llms.txt`. These aid discovery but do not guarantee indexing or rankings. No service worker is installed, so downloads are not intercepted or cached by app code.

Security headers restrict scripts to this site and the exact JSON-LD hash, disable framing and microphone/camera access, and prevent content-type sniffing. Asset caching is one day; HTML and metadata revalidate after five minutes. The generated privacy policy describes local app audio processing, third-party plugins, update checks, and standard hosting connection metadata.
