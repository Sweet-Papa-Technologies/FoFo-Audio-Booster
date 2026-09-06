# Validation and release gates

Status: development preview, September 5, 2026. A signed per-app capture/gain/cleanup spike now passes on this Mac; the Bluetooth/device-switch/sleep portions remain acceptance gates. Compilation and offline tests do not prove that a private aggregate reroutes every hardware/app combination correctly.

## Verified in this workspace

- Swift executable compiles with Swift 6.1.2 in Swift 5 language mode, macOS 14.4 deployment target.
- Xcode 16.4 builds the full app, Sparkle integration, and widget for both arm64 and x86_64.
- Fourteen XCTest cases pass: no-op routing, selective app routing, disjoint master coverage, solo coverage, helper aliases, profile/state persistence, corrupt-preference fallback, gain caps, processing activation, Bluetooth call-profile classification, and four monotonic listening-duration/continuity/dismissal cases.
- DSP tests pass at 44.1, 48, 96, and 192 kHz under +24 dB gain. Independent 16× reconstructed peaks remain below the −1 dBTP ceiling for the test signals.
- DSP tests cover K-weighted sine loudness, bounded sample delivery, balance, opposite-phase mono cancellation, non-finite sample containment, fade-out, input bounds, an exact delay-compensated unity null test, actual IOProc buffer mapping/series gains, monitor exclusion, and a real Apple AU render failure.
- The actual Swift plugin worker passes Apple EQ state round-trip and forced fatal-crash containment; C++ tests additionally freeze the worker and verify delayed dry fallback and shared-memory cleanup. The parent also survives closing a dead worker's command pipe.
- SPT-signed live capture on macOS 15.5, External Headphones, 44.1 kHz: +3 dB requested → +3.000012 dB measured, zero callback overruns, private objects released, real default output unchanged. Brief engine-process measurement: 0.784% CPU, 26.67 MiB maximum RSS, 7.61 ms synchronous bypass teardown. This is not a full GUI performance or Bluetooth qualification.
- Metal shader compiles. Native app diagnostics discover real output devices, active process groups, installed Audio Units, and Metal without requesting capture.
- The app's isolated menu-panel snapshot renders with sample values. This is UI validation, not evidence of active audio processing.

## Requirement coverage

| Requirements | Implementation / qualification |
| --- | --- |
| F1–F6 | Gain, mute, solo, aliases/public ancestry grouping, activity filtering, UID profiles implemented; live routing and helper attribution require the spike. |
| F7 | Short-term K-weighted target mode and gated integrated LUFS meter implemented. Absolute/relative gating tests pass; formal conformance vectors remain open. |
| F8–F11 | Peak chain, ramps, callback watchdog, panic implemented and offline-tested. Full intersample conformance, acoustic/device transition tests remain. |
| F12 | Continuous elevated headphone-gain timer and one-session dismissible hint implemented; four time-advance/continuity tests pass; VoiceOver interaction remains. No SPL estimate. |
| F13 | Bluetooth mono/low-rate detection, built-in-mic switch, undo implemented; live HFP→A2DP renegotiation needs headphones. |
| F14 | Automatic captured-stream rate observation plus optional known-original-source override and explicit set-output action. Original media rate cannot be inferred after OS resampling. |
| F15–F16 | Device/process listeners, readiness polling, sleep/wake rebuild, watchdog implemented; hardware soak remains. |
| F17–F18 | Balance/mono tested offline. Uninstall tears down, unregisters login item, clears preferences/group defaults, verifies a real output, and moves only the app to Trash. Destructive uninstall requires dedicated installed-build testing. |
| F19–F22 | Native discovery, eight-slot chain, UI/state, and Apple presets implemented. Custom editors and representative third-party compatibility need manual verification. |
| F23 | All AU rendering/editors isolated in a child process, one fixed shared buffer, nonblocking delayed dry fallback, culprit bypass and remaining-chain rebuild. Fatal worker crash/stall/state tests pass. Third-party compatibility remains. |
| F24–F29 | MenuBarExtra, modifiers/scroll, panel, settings, global keys, App Intents, widget target, onboarding, labels, reduced motion/transparency implemented. TCC, widget provisioning, Shortcuts discovery, and accessibility interaction need signed UI validation. |
| F30–F35 | Five Metal presets, FFT, residual monitoring, reported-latency delay/nudge, full screen, motion fallback, analysis cleanup implemented. Tide now uses retained phosphor textures with blur and time-based decay. A2DP sync and performance budgets remain unmeasured. |
| N1–N3 | Path latency is estimated from reported device/AU values. ≤10 ms, <1% CPU/<60 MB, and a 24-hour no-dropout soak are not certified. |
| N4 | No-tap no-op routing and active low-level delay-compensated null tests pass. End-to-end device null testing remains. |
| N5–N6 | No analytics/recording/network client beyond configured Sparkle. English String Catalog and Xcode extraction enabled; complete localization/accessibility audit remains. |
| Distribution | Universal app/widget builds; archive, signing, notarization, appcast, DMG, cask generators ready. SPT identities, validated local Keychain notarization profile, Sparkle key, and protected GitHub signing environment configured. Actual notarization/cloud-run results are recorded below; publication remains separate. |

## Live-audio spike checklist

Use a consistently signed installed build; start with low headphone/system volume.

1. Record macOS version, CPU, output UID/format, aggregate stream layout, buffer size, signing team, and app version. Do not write captured audio or personal process metadata into telemetry.
2. Reset only this app's test permission if needed: `tccutil reset SystemAudioCaptureRequests com.sweetpapatechnologies.FoFoBooster`. Launch, allow the deliberate capture prompt, and confirm its Privacy bucket. Repeat with denial and subsequent grant. Do not use private TCC APIs.
3. Play a browser tone/quiet video plus an unrelated notification source. Boost only the browser; confirm the second source stays unchanged, and confirm there is no doubled original/processed signal. Exercise multiple helper processes, mute, and solo.
4. Add master gain and verify app/master gains in series with exactly one final output-device effect/limiter chain. Check a 0 dB/no-effects null against the original.
5. Switch Bluetooth↔built-in output repeatedly, disconnect/reconnect headphones, change rates, stop/relaunch the source, and sleep/wake. Confirm original audio always returns on bypass, quit, force-quit, failed initialization, and callback overload.
6. Put Bluetooth headphones in call mode with a communication app. Verify the banner, fix, undo, and the absence of unintended microphone activation just from the aggregate.
7. Test DRM/FairPlay content explicitly. Silent tap data is not distinguishable from genuinely silent content using a permission pre-check; document playback results and keep bypass accessible.
8. Measure AU latency/compatibility, plugin state restoration and editors, AUv3 service termination, and deliberate invalid render failures. Verify representative third-party AUs in addition to the passing deliberately crashed worker.
9. At 128 frames, measure actual added latency. Use Instruments to measure CPU/RSS with one app boosted and the visualizer closed; measure all presets at 4K/60, GPU percentage, and closed-window zero analysis work.
10. Run a 24-hour soak on a test machine with scripted device switching, app relaunch, and scheduled sleep/wake. Log callback/dropout counters, output continuity, and restored default output; do not count an unrun soak as passed.
11. Validate VoiceOver, keyboard focus, customized hotkeys/conflicts, Reduced Motion/Transparency, Notification Center interaction, launch-at-login opt-in, and uninstall on a disposable installed build.

Do not publish a stable release until these gates are recorded. Name/trademark availability and license changes in the original open questions remain product decisions.
