# Changelog

## 0.1.0 — development preview (2026-09-05)

- Added native SwiftUI menu-bar app, three-step onboarding, output selection, per-app/master levels, mute/solo, and device profiles.
- Added Core Audio private process taps/aggregate routing, C++ real-time mixer, ramped changes, K-weighted short-term target mode and gated integrated LUFS metering, lookahead peak protection, and panic/watchdog recovery.
- Added Bluetooth call-mode repair with undo, captured-stream rate observation and known-source rate adjustment, balance/mono, listening hint, editable global shortcuts, login opt-in, and clean uninstall flow.
- Added eight-slot Audio Unit chains, native/generic editors, UUID-matched saved state, Apple presets, render-error bypass, and a separate worker for all AU rendering/editors, fixed shared-buffer latency, and fatal-crash/stall containment.
- Added five Metal visualizers with retained Tide phosphor feedback, vDSP FFT, latency/nudge compensation, residual-source monitoring, instanced Drift particles, and reduced-motion fallback.
- Added App Intents, interactive widget target, local English String Catalog, app icon, and configured-only Sparkle integration.
- Added universal Xcode project, SwiftPM development/test path, CI, DSP/routing/persistence tests, read-only diagnostics, UI snapshot mode, and SPT app/installer signing, Keychain notarization, signed appcasts, DMG/PKG/cask generation, and isolated public-repo GitHub signing jobs.
- Passed the signed +3 dB per-app capture/cleanup spike, 14 profile/routing/listening tests, and isolated Apple AU crash/state tests. Recorded remaining hardware, loudness conformance, performance/soak, and distribution acceptance gates in `docs/VALIDATION.md`.
