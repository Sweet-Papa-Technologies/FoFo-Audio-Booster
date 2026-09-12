# Signing and release builds

SPT's identities are confirmed against the existing FoFoPedalVST signing setup:

- Team: `6Y5SZ2K5XY`
- Application: `Developer ID Application: Forrester Terry (6Y5SZ2K5XY)`
- Installer: `Developer ID Installer: Forrester Terry (6Y5SZ2K5XY)`
- App: `com.sweetpapatechnologies.FoFoBooster`
- Widget: `com.sweetpapatechnologies.FoFoBooster.widget`
- Shared group: `6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster`

The team-prefixed macOS group follows [Apple's app-group container guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers). It needs no provisioning profile. Both targets carry the group entitlement; only the widget is sandboxed. The main app permits third-party Audio Units through disabled library validation. All components use hardened runtime and timestamped Developer ID signatures. Do not add a standalone team-identifier entitlement: Developer ID authenticates the team through the signature, and that extra restricted entitlement requires a profile.

## Local setup

On the existing SPT development Mac:

```sh
python3 scripts/setup-signing.py
scripts/build.sh
scripts/release.sh
```

Setup reads the existing `spt-notary` generic Keychain item without displaying its password, validates and stores the `FoFoBooster-notary` notarytool profile, and creates/retains a dedicated Sparkle Ed25519 key in Keychain under the app bundle ID. `Config/SparklePublicKey.txt` is intentionally public. Setup also installs the GitHub environment credentials described below; it requires authenticated `gh` access to the repository. It exports only the two named identities into encrypted PKCS#12 data and removes temporary private material.

The normal build produces `build/FoFoBooster.app` with the confirmed SPT signature. The release command builds both architectures, signs nested components explicitly, verifies signatures, notarizes and staples the app, then creates separately signed/notarized/stapled DMG and PKG installers. It generates an EdDSA-signed Sparkle appcast, actual-SHA256 Homebrew cask, app ZIP, and checksums under `build/release`. `--output build/release-VERSION` keeps an already-running build intact in a different directory. `--sign-only` stops before notarization; `--skip-build --app PATH` packages an existing universal app.

Credentials stay in Keychain; neither passwords nor private keys belong in source, logs, release artifacts, or local configuration files. Never rotate the Sparkle signing key casually: existing installations trust its public counterpart.

## Public GitHub repository

`macOS checks` runs on pull requests and main pushes with read-only permissions and no signing secrets. It tests DSP, routing, persistence, plugin crash isolation, and shaders, builds the universal app/widget, and uploads an unsigned development ZIP.

`Signed macOS build` runs manually on main or on version tags. Its first job tests and builds without secrets. The separate signing job downloads only that run's artifacts and uses the `signing` environment, restricted to main and `v*` tags. Tags must match the app version and point into main history. Both jobs use fresh GitHub-hosted macOS runners, pinned action commits, and read-only repository permissions. Fork pull requests cannot enter this signing path; there is no `pull_request_target` or self-hosted runner.

Environment secrets:

- `APPLE_CERT_P12`, `APPLE_CERT_PASSWORD`
- `APPLE_ID`, `APPLE_APP_PASSWORD`
- `SPARKLE_PRIVATE_KEY`

The signing job imports the encrypted identities into an ephemeral Keychain, validates notarization credentials, and deletes that Keychain in an always-run cleanup step. Only named distribution artifacts and notarization receipts are uploaded. Maintain trusted write access to main and tags: anyone who can change trusted signing scripts can use the environment's credentials.

## Publication

Neither local scripts nor Actions publish releases. Complete the [hardware and user-interface acceptance gates](VALIDATION.md), review the artifacts, then publish the version's DMG, PKG, appcast, and checksums together. The appcast URLs refer to `releases/download/vVERSION/`; the updater reads `releases/latest/download/appcast.xml`. Test an actual upgrade on a clean Mac before announcing updates. Install the generated cask in the intended Homebrew tap after the release asset exists.

Update both target versions, the generator's build settings, About label, and CHANGELOG before a new version. Preserve the existing Apache 2.0 license and stable bundle/signing identities for system-audio permission continuity.
## Public downloads and website

The signed macOS workflow now publishes a public GitHub release after successful signing on version tags, or on a manual run with `publish=true`. The default manual build still produces only CI artifacts. Publication validates checksums, accepted notary receipts, and appcast metadata, and refuses to replace an existing version. Bump the app version and build before creating the next tag on reviewed main history.

Published assets include the signed DMG, PKG, ZIP, Sparkle appcast, SHA256SUMS, cask, and notary receipts. Completion of the signed workflow starts Website checks, which resolve current public download assets and prepare the site. Automatic Firebase deployment is prepared but awaits approval of its project-wide Hosting role; see [website deployment](../website/README.md). The first public 0.1.1 release reuses verified artifacts from signed run `34664620176` at `4a16402ff5adfa2b55293deac043f097dc6eb636`.
