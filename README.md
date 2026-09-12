# FoFoBooster

A free, native macOS menu-bar audio booster from Sweet Papa Technologies. Built for macOS **14.4 or later**, on Apple silicon and Intel. No virtual audio driver, account, recording, or analytics.

[Website and download](https://fofo-booster.web.app/) · [Public releases](https://github.com/Sweet-Papa-Technologies/FoFo-Audio-Booster/releases) · [Website development and deployment](website/README.md)

**Development preview.** The universal app includes its widget and updater, SPT Developer ID signing, local notarization, and protected GitHub release builds. The signed per-app capture/gain/bypass test passes on this Mac, as do DSP, profile, routing, and isolated plugin-crash tests. Bluetooth transitions, a full hardware soak, and user-interface qualification remain. See [validation and remaining gaps](docs/VALIDATION.md).

## Run

Open `FoFoBooster.xcodeproj` in Xcode 16.4 or later. Select the **FoFoBooster** scheme and your SPT signing team for **both** targets. Keep the bundle IDs stable. Run the app and complete its three-screen onboarding.

```sh
scripts/build.sh
open build/FoFoBooster.app
```

The normal build uses SPT's confirmed local Developer ID identity. Run `python3 scripts/setup-signing.py` once on the SPT development Mac to configure notarization, Sparkle, and GitHub signing credentials from Keychain. See [signing and release builds](docs/RELEASING.md). Public contributors can run the unsigned Xcode build used by CI.

A dependency-free developer build is also available:

```sh
scripts/build.sh --standalone
```

This uses Swift Package Manager and omits the widget and Sparkle. Set `SIGNING_IDENTITY` for a stable local signature; otherwise the script ad-hoc signs the bundle. Xcode is the distribution build path.

## Use

- Select an output device; its saved profile loads automatically.
- Raise **Master boost**, or adjust one app. Helper processes are grouped under the owning app where public process metadata allows it.
- **Mute** and **Solo** work per app. Master and per-app gain are applied in series.
- Press **⌥⇧B** to immediately tear down all taps and restore original audio. Use the power button or Option-click the menu icon to resume. Default boost up/down shortcuts are **⌥⇧↑/↓**, and visualizer is **⌥⇧V**; all are editable.
- **Plugins** hosts up to eight Audio Units, with reorder, bypass, custom editors, generic parameters, and device-specific saved state. All effects and their editors run in an isolated worker with one shared buffer of latency; the main engine returns dry audio if the worker crashes or stalls. The safety limiter follows the chain.
- **Fix issues** detects Bluetooth call mode and switches to the built-in microphone with an undo action. Captured-stream rate mismatches are detected; an explicit known-original-source choice is available when the operating system has already resampled the source.
- **Visualizer** offers Ember, Halo, Tide, Grid, and Drift. Double-click or **⌃⌘F** for full screen. Closed windows release analysis taps. Reduce Motion uses a static display.
- Settings includes loudness targeting, balance, mono, limiter ceiling, extended boost consent, login items, profiles, shortcuts, and uninstall.

At 0 dB with no effects or other processing, the normal audio route stays untouched. Any processed route passes through peak protection. Digital boost cannot override a headphone firmware limit, restore a Bluetooth call profile's missing bandwidth, or guarantee capture of protected/DRM playback.

## Build and test

```sh
scripts/test.sh
# Read-only hardware diagnostics (no capture prompt):
build/FoFoBooster.app/Contents/MacOS/FoFoBooster --diagnostics
# Signed, nearly inaudible test source; may request system-audio permission:
build/FoFoBooster.app/Contents/MacOS/FoFoBooster --validate-audio
# Automated isolated effect/state/fatal-crash test:
build/FoFoBooster.app/Contents/MacOS/FoFoBooster --validate-effects
# All five production shaders at 4K in both appearances:
build/FoFoBooster.app/Contents/MacOS/FoFoBooster --validate-visualizer
# Background 24-hour soak; restarts only its own quiet test source:
python3 scripts/start-soak.py --app build/FoFoBooster.app
# Render the menu panel with isolated sample data, without audio processing:
build/FoFoBooster.app/Contents/MacOS/FoFoBooster --snapshot "$PWD/build/MenuPanel.png"
```

Tests need access to macOS's Audio Unit registry for the native AU integration case. A filesystem/process sandbox that hides that registry will fail that case; run it normally from Terminal.

`Package.swift` supports local development/tests. `scripts/generate-project.py` deterministically generates the checked-in Xcode project without XcodeGen. Run it after adding source/resource files. Sparkle **2.8.0** is pinned in the Xcode project; its resolved package is checked in. English strings live in `Localizable.xcstrings`; Xcode extracts new localizable SwiftUI strings during builds.

## Source map

| Location | Responsibility |
| --- | --- |
| `Sources/AudioDSP` | C++ IOProc, atomics, mixing, gain ramps, AU render callbacks, K-weighting, true-peak lookahead limiter, sample ring |
| `Sources/FoFoBooster/Audio` | HAL discovery/listeners, private tap/aggregate lifecycle, AU discovery/state/editors |
| `Sources/FoFoBooster/Models` | Device profiles, routing policy, recovery/watchdog, listening reminder |
| `Sources/FoFoBooster/UI` | Menu panel, onboarding, settings, effects, troubleshooting |
| `Sources/FoFoBooster/Visualizer` | vDSP FFT, latency history, Metal renderer |
| `Shared`, `Widget` | Interactive widget and app-group command delivery |
| `Config`, `scripts` | Signing metadata, app assembly, universal archive, notarization, appcast and cask generation |

Read [architecture](docs/ARCHITECTURE.md), [release instructions](docs/RELEASING.md), and the [original requirements](FoFoBooster-Requirements-v0.1.md).

## License

The repository's existing **Apache License 2.0** is preserved. No reference-project source code was copied. Sparkle is distributed under its own license, included in its framework. The original specification's GPL suggestion remains a product decision, not an automatic license change.
