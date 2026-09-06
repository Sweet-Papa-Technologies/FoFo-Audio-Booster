# FoFoBooster — Requirements v0.1

**Product:** FoFoBooster
**Owner:** Sweet Papa Technologies (SPT)
**Price:** Free. No tiers, no trial, no nag.
**Platform:** macOS 14.4 (Sonoma) and later, Apple silicon + Intel universal. Windows explicitly out of scope for v1.
**Status:** Draft for AI-coder handoff — September 2026

---

## 1. One-paragraph pitch

FoFoBooster is a menu-bar sound booster for macOS that makes quiet audio louder *per source* — one app, one output device, or everything — without clipping, without a kernel extension, and without breaking the user's audio when they switch headphones. It also fixes the handful of common macOS audio problems that make Bluetooth headphones sound quiet or muffled, lets people route the boosted signal through their own Audio Units, and ships with a small, beautiful, GPU-efficient visualizer.

## 2. Why this exists (the Bluetooth problem, stated precisely)

The motivating case is "my Bluetooth headphones aren't loud enough." That problem has three distinct causes, and the app must handle each one differently:

1. **The headset is already at maximum and the content is quiet.** With Bluetooth A2DP, macOS sends the audio stream at up to full scale and the *headset* applies the volume (AVRCP absolute volume). Once the system slider is at 100%, there is no more volume in the system — only more volume in the *signal*. The fix is digital makeup gain applied before the Bluetooth encoder, with a limiter so the gain doesn't clip the AAC/SBC encoder. This is FoFoBooster's core job. Streaming services normalizing to −14 LUFS, quiet YouTube uploads, and meeting apps are the usual culprits.
2. **The headset firmware clamps output under absolute-volume control.** Some headsets implement absolute volume badly and never reach their real ceiling. Digital gain still helps here (same fix as #1), but the app should tell the user it's a headset limitation, not a Mac one.
3. **macOS is stuck on the wrong Bluetooth profile.** When a Bluetooth headset's mic is in use, macOS drops to the low-bandwidth SCO/HFP link (mono, 8–16 kHz). Audio sounds muffled and quiet. Boosting won't fix it. The app should *detect* this (the device's current format in Core Audio shows 1ch / 8 or 16 kHz) and offer the one-click remedy: switch the input device away from the headset so macOS re-negotiates A2DP.

Per-source matters because the loud thing and the quiet thing are usually playing at the same time: a quiet lecture video in a browser, a normal-volume Slack notification. Boosting everything makes the notification painful.

## 3. Product principles

- **Safe first.** Louder must never mean distorted. Every boosted path goes through a limiter. The app never makes a sudden loud noise (all gain changes ramp).
- **Never break the user's audio.** Any failure mode falls back to unprocessed pass-through. There is always a one-keystroke "bypass everything" escape hatch. Uninstall leaves the system exactly as it was found.
- **Least friction.** No kernel extensions, no reboot, no manual device selection in Audio MIDI Setup. One permission prompt, clearly explained.
- **Stay out of the way.** Lives in the menu bar. No Dock icon by default. No login items without asking.
- **Free means free.** No accounts, no analytics beyond an opt-in crash reporter, no upsell surface.

## 4. Architecture decision: Core Audio process taps, not a virtual driver

**Decision:** Build the audio path on Core Audio **process taps** (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.2+; target 14.4 for the stable TCC behavior). This is the lowest-friction path that delivers true per-source control, and it is what the newest entrants in this space (Mimir, SherlockEQ, iQualize, and Rogue Amoeba's newer engine) are built on. Background Music and eqMac are built on the older virtual-driver approach and carry its costs: a HAL plug-in install, a fake output device the user has to select, a "microphone" permission that confuses people, and audio that dies when the driver crashes.

**How the tap path works (per source):**

```
App audio → process tap (.mutedWhenTapped) → private aggregate device
         → IOProc callback: gain → [AU chain] → limiter → soft-clip
         → real output device (the user's headphones)
```

- `.mutedWhenTapped` mutes the app's direct output so the *only* copy the user hears is the processed one.
- Each tap is wrapped in a *private* aggregate device (`kAudioAggregateDeviceIsPrivateKey: true`) with the real output as main sub-device and drift compensation on, so nothing new appears in System Settings.
- A **system-wide "everything" tap** (exclude-self) provides the master boost and feeds the visualizer.
- Per-app taps are only created when the user boosts that app; untouched apps are never tapped (zero overhead, zero risk).

**Permission:** One TCC prompt — `NSAudioCaptureUsageDescription` (add to Info.plist manually; Xcode doesn't list it). On macOS 15+ this lands in the narrower "System Audio Recording Only" bucket rather than Screen Recording. There is no public API to pre-check or request it; the prompt fires on first tap creation, so the onboarding flow must trigger a tap deliberately and handle denial gracefully. **TCC is keyed on signing identity** — unsigned dev builds never show the prompt. Use `tccutil reset SystemAudioCaptureRequests <bundle-id>` to re-test onboarding.

**Where a driver still earns its place (deferred, not v1):** a HAL `AudioServerPlugIn` (user-space, no kext — the BlackHole/Background Music pattern) is the fallback if taps prove unable to cover a case that matters. Known candidates to verify in a spike: DRM/FairPlay-protected playback (TV app, some Music content) is expected to return silence through a tap; and macOS < 14.4. If a driver is added later, it must be signed, notarized, installed to `/Library/Audio/Plug-Ins/HAL`, and activated with a `coreaudiod` restart — and the app must still work fully without it.

## 5. Tech stack decision: native Swift, no Tauri

**Decision:** Pure native. SwiftUI for UI (AppKit where SwiftUI falls short — global hotkeys, some window behaviors), Core Audio (C API) for the engine, Accelerate/vDSP for FFT, Metal for the visualizer, AudioToolbox/AVFoundation for Audio Unit hosting.

**Why not Tauri:** every hard part of this app is a native macOS API with real-time constraints — taps, IOProc callbacks, AU hosting, `MenuBarExtra`, Metal. Tauri's webview would sit on top of a Swift core doing all the work, add a JS bridge across a real-time boundary, and make the menu-bar popover and full-screen visualizer *harder*, not easier. Cross-platform is not a v1 goal and Windows would need a completely different audio engine (WASAPI loopback / APO) anyway. Revisit only if Windows becomes real, and even then the engine stays native per platform.

**Real-time rules for the audio callback (non-negotiable):** no allocation, no locks, no Objective-C/Swift-runtime calls, no logging, no I/O. Parameters cross into the callback via lock-free atomics or a SPSC ring buffer. Gain changes ramp (~30 ms exponential) to avoid clicks.

## 6. Functional requirements

### 6.1 Boost engine
- **F1** Master boost per output device: 0 to +24 dB (default cap +12 dB; +24 dB behind an "I understand" toggle in settings).
- **F2** Per-app boost: same range, independent of master, applied in series before master.
- **F3** Per-app mute and per-app solo.
- **F4** Helper-process grouping: browsers, Electron and WebKit apps play audio from helper processes. Group them under the parent app with one slider. Maintain a bundle-ID alias table (Chrome/Brave/Edge/Arc helpers, Discord, Slack, Zoom, Teams, Spotify) and fall back to responsible-process lookup.
- **F5** Show only apps currently producing audio by default, with a "show all" expander. Detect via `kAudioProcessPropertyIsRunningOutput`.
- **F6** Output device profiles: remember boost, per-app levels, and plugin chain **per output device** (keyed by device UID). Switching from Bluetooth headphones to the Studio's speakers switches profiles automatically. This is the feature that makes "boost my Bluetooth headphones" a set-once experience.
- **F7** Optional **loudness-target mode**: instead of fixed gain, measure integrated loudness (ITU-R BS.1770 / LUFS, short-term window) and apply makeup gain to hit a user-chosen target (default −14 LUFS), bounded by the boost cap. This is the "make everything the same loudness" feature and directly addresses quiet streaming content.

### 6.2 Safety chain
- **F8** True-peak lookahead limiter after all gain stages (lookahead ~1.5 ms, ceiling −1 dBTP default, configurable). Runs on every processed path; cannot be disabled, only bypassed with the whole app.
- **F9** Soft-clip stage after the limiter as a last line of defense.
- **F10** All parameter changes ramped; device switches fade out → reconfigure → fade in.
- **F11** **Panic bypass:** global hotkey (default ⌥⇧B) and menu item that instantly tears down all taps and restores unprocessed audio. Also triggered automatically if the callback detects repeated overloads (dropouts) or if the engine throws.
- **F12** Listening-level hint: if boost exceeds +9 dB on a headphone-class device for more than 30 continuous minutes, show a single, dismissable, non-nagging notice referencing safe-listening guidance. Not a medical feature; no SPL claims.

### 6.3 Sound-issue fixes ("clean" mode)
- **F13** SCO/HFP trap detection: watch the selected output device's nominal format; if it's mono / ≤16 kHz on a Bluetooth device, show a banner: "Your headphones are in call mode — audio will sound muffled. Fix" → switches default input to the built-in mic (with undo).
- **F14** Sample-rate sanity: warn when the output device is running at a rate that mismatches the source and offer to set it (Core Audio device property, no Audio MIDI Setup trip).
- **F15** Device-change resilience: listen on `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices`; on change, snapshot state → invalidate taps → recreate against the new device → restore state. Poll for aggregate readiness before starting IOProcs (they are not ready immediately after creation).
- **F16** Sleep/wake and source-app relaunch recovery: re-establish taps when a boosted app restarts or after wake; never leave an app muted-when-tapped with no active tap (that is the "my audio disappeared" bug class, and it must have a watchdog).
- **F17** Balance and mono-downmix controls per output device (cheap, requested constantly for Bluetooth headphones with a weak side).
- **F18** Clean uninstall: Settings → Uninstall removes taps, aggregate devices, login item, preferences, and the app; confirm the default output device is restored.

### 6.4 Plugin hosting (Audio Units)
- **F19** Host AUv2 and AUv3 effects (`kAudioUnitType_Effect`, `MusicEffect`) discovered via `AVAudioUnitComponentManager` — the same list GarageBand/Logic sees. **Note on scope:** "if GarageBand can see it" is precisely Audio Units; GarageBand does not load VST/VST3. VST3 hosting requires the Steinberg SDK (GPLv3 or Steinberg proprietary license) or JUCE (GPL/commercial). Decision for v1: **AU only.** VST3 is a v1.x candidate if the project is open-sourced under GPL (JUCE GPL path) — see Open Questions.
- **F20** Per-output-device chain of up to 8 AUs, ordered, with per-slot bypass, positioned between gain and limiter. Optional per-app chains in v1.x.
- **F21** Plugin UI: present the AU's custom view when available, generic parameter view otherwise. Save/restore full state (`kAudioUnitProperty_ClassInfo`) in the device profile.
- **F22** Ship with useful Apple-provided AUs pre-wired as presets so the feature isn't empty on day one: `AUNBandEQ` (a real EQ for free), `AUDynamicsProcessor`, `AUPeakLimiter` (as an alternative limiter), `AUNewTimePitch` off by default.
- **F23** Render AUs in-process where allowed (AUv2, in-process AUv3) inside the same real-time chain; out-of-process AUv3 must be rendered with a fixed extra buffer of latency, clearly surfaced in the UI. Plugin crashes must not take down the engine — catch render failures and auto-bypass the slot.

### 6.5 Menu bar and UI
- **F24** `MenuBarExtra` with `.window` style. Icon reflects state (off / boosting / bypassed / warning). Left-click opens the panel; ⌥-click toggles bypass; scroll-wheel over the icon adjusts master boost.
- **F25** Panel layout (Control Center visual language — translucent material, rounded groups, SF Symbols):
  1. Output device picker (mirrors the system's list).
  2. Master boost slider with live gain-reduction meter from the limiter (so people can *see* why it's not getting louder).
  3. "Now playing" app list with per-app sliders, mute, solo.
  4. Row of buttons: Visualizer · Plugins · Fix issues (badge when F13/F14 fire) · Settings.
- **F26** Control Center note: third-party apps cannot add modules to Apple's Control Center. The closest legitimate integrations, all in scope: the menu-bar panel styled to match; **Shortcuts actions** via App Intents (set boost, toggle bypass, switch profile) so it can be scripted and put on a Stream Deck; an **interactive Notification Center widget** (WidgetKit + App Intents, macOS 14+) with a boost toggle and level; and **global keyboard shortcuts** (boost up/down/bypass/visualizer).
- **F27** Settings window (standard `Settings` scene): general, hotkeys, device profiles, plugins, limiter, launch at login (`SMAppService`), uninstall.
- **F28** Onboarding: three screens max — what it does, the one permission (with a deliberate tap creation to trigger the prompt), done. If permission is denied, the app explains and deep-links to the Privacy pane.
- **F29** Accessibility: full keyboard navigation, VoiceOver labels on sliders with dB values, respects Reduce Motion (visualizer falls back to a static meter) and Reduce Transparency.

### 6.6 Visualizer
- **F30** Source: the system-wide tap of the currently selected output device — it visualizes *what you hear*, regardless of which apps are boosted.
- **F31** Toggle from the menu-bar panel; opens as a floating resizable window; ⌃⌘F or double-click for true full screen (own Space). Remember size and last preset.
- **F32** Rendering: Metal, one draw call per preset where possible, shared FFT front end via vDSP (2048-point, Hann window, ~60 Hz analysis; log-frequency binning; exponential attack/decay smoothing, tunable per preset). Targets: 60 fps at 4K, under 3% CPU and under 10% GPU on an M-series machine while boosting; 0% when the window is closed (the analysis tap is released, not paused).
- **F33** Bluetooth latency compensation: A2DP adds roughly 100–250 ms. Visualizer frames are delayed by the output device's reported latency (`kAudioDevicePropertyLatency` + safety offset + user nudge slider) so the visuals land on the beat you actually hear.
- **F34** Five presets, each with a light/dark variant and a single accent color derived from the current system accent by default:
  1. **Ember** — spectrum bars as a soft, glowing waveform ridge; warm gradient; slow decay tails.
  2. **Halo** — circular spectrum around a breathing ring; bass modulates ring radius; designed for the full-screen "album" look.
  3. **Tide** — time-domain oscilloscope with phosphor persistence and gentle blur; the "pro audio" one.
  4. **Grid** — 32×16 LED matrix with per-cell falloff and peak-hold dots; retro, crisp, extremely cheap to render.
  5. **Drift** — particle field where particle velocity follows spectral flux and color follows spectral centroid; the show-off one, with an automatic quality step-down under load.
- **F35** Every preset must look good with *silence* (idle animation, no flat black) and must not flash (respect Reduce Motion; no strobing effects anywhere).

## 7. Non-functional requirements
- **N1** Added latency on the processed path ≤ 10 ms on top of device latency at 128-frame buffers (limiter lookahead included). Show current total latency in Settings.
- **N2** Idle footprint (boosting one app, visualizer closed): < 1% CPU, < 60 MB RSS.
- **N3** Zero dropouts in a 24-hour soak test with device switching, sleep/wake, and app relaunch scripted.
- **N4** Bit-transparent when all gains are 0 dB and no plugins are loaded (verified by null test in CI).
- **N5** No network access except the opt-in crash reporter and the updater.
- **N6** Localizable from day one (String Catalog); English only at launch.

## 8. Distribution, signing, updates
- Direct download (.dmg) plus a **Homebrew cask**. Not App Store for v1: system audio capture and the permission flow don't fit the sandbox cleanly, and taps/TCC behavior is easier to reason about with Developer ID.
- **Developer ID signed and notarized** with SPT's existing certificates, hardened runtime on. A stable bundle ID and signing identity are functional requirements (TCC keys on them), not just hygiene.
- **Sparkle** for updates, EdDSA-signed appcast, opt-out available.
- Universal binary. Minimum macOS 14.4.
- Public GitHub repo (see Open Questions on license). Release notes per version; a CHANGELOG the AI coder maintains.

## 9. Out of scope for v1
Windows; microphone/input processing; recording or export; a bespoke EQ UI (use `AUNBandEQ` via the plugin chain); VST/VST3; iOS/iPadOS companion; cloud sync of profiles; any paid tier.

## 10. Phased plan for the AI coder

**Spike (before Phase 1, 1–2 days):** prove the per-app tap + `.mutedWhenTapped` + aggregate + gain path on the M4 Studio with Bluetooth headphones, including a device-switch and a wake-from-sleep. Check DRM playback behavior through a tap. Confirm the TCC prompt appears under "System Audio Recording Only" on macOS 15/26. Outcome decides whether §4's fallback driver moves up.

**Phase 1 — Boost core.** Engine (F1–F5, F8–F11, F15–F16), device profiles (F6), minimal menu-bar panel (F24–F25 without plugins/visualizer), onboarding (F28), signing/notarization pipeline, null test in CI. *Ship as 0.1 to real users.*

**Phase 2 — Clean mode + polish.** F12–F14, F17–F18, Settings, hotkeys, Shortcuts actions and widget (F26–F27), accessibility pass (F29), Homebrew cask, Sparkle.

**Phase 3 — Plugins.** F19–F23 with the Apple-AU presets.

**Phase 4 — Visualizer.** F30–F35, one preset at a time; performance budget enforced per preset.

**Phase 5 — Loudness-target mode (F7)** and per-app plugin chains.

## 11. Reference material worth reading before coding
- Apple sample/guidance: `insidegui/AudioCap` — the de-facto documentation for process taps and the permission dance (the API docs are thin).
- `ThalesBMC/Mimir` — small open-source per-app mixer on taps; good reference for `.mutedWhenTapped`, ramping, and device-change recreation.
- `kyleneideck/BackgroundMusic` — the virtual-driver approach and its failure modes; read the issue tracker to see what *not* to inherit (Tahoe FaceTime silence, orphaned muted devices, mic-permission confusion).
- `ExistentialAudio/BlackHole` — cleanest reference HAL `AudioServerPlugIn` if the fallback driver ever becomes necessary.
- Rogue Amoeba's SoundSource / Audio Hijack — the UX bar for "audio utilities that don't break your Mac."
- ITU-R BS.1770-4 for loudness measurement; EBU Tech 3341/3342 for meters.

## 12. Open questions
1. **License.** Open-source under GPLv3 unlocks JUCE-GPL for VST3 later and matches "totally free"; MIT is friendlier but closes the JUCE door. Recommendation: GPLv3.
2. **Name collision check** for "FoFoBooster" on the App Store, Homebrew, and trademark databases before the repo goes public.
3. **Boost ceiling.** +12 dB default / +24 dB max is a proposal; confirm after the spike on real headphones.
4. **Login item default.** Off (ask on first run) vs on. Recommendation: ask once during onboarding.
5. **Should the visualizer be a separate lightweight process** (XPC) so a shader bug can't stall the audio host? Recommended yes if Phase 4 shows any interference; decide then.
6. **Analytics.** Proposal is none. If usage data is ever wanted, it must be opt-in and shown in full before the first send.
