# Architecture

## Audio ownership

All graph creation, teardown, persistence, Core Audio property access, and plugin discovery happen on the main actor. The IOProc is a C function in C++, registered directly with `AudioDeviceCreateIOProcID`; there is no Swift callback trampoline. The callback uses only preallocated memory, lock-free atomics, arithmetic, and Core Audio C entry points. Third-party effects render on a separate worker thread in a separate process.

A routing plan assigns a tap to each modified app group. If master gain, balance, mono, loudness targeting, an effect, or solo needs a complete mix, a final exclusive tap captures all remaining processes, excluding the app groups already claimed and FoFoBooster itself. This prevents both feedback and applying app gain twice. The aggregate combines the sources; app gains precede summation, followed by master processing, the output-device effect chain, and one stereo limiter. Untouched apps need no tap when no global processing is active.

Taps use a stereo process mixdown and `mutedWhenTapped`. The aggregate is private and includes the real output as its main subdevice. Physical input channels are requested as zero and IOProc stream usage explicitly disables physical inputs to avoid opening a Bluetooth microphone. Each tap has drift compensation. The input channel offset is calculated after aggregate readiness. Unexpected non-float or non-stereo tap formats fail to pass-through rather than reinterpret incompatible samples. Output streams must be float32. Unusual multistream/aggregate/HDMI device layouts require hardware qualification.

The aggregate is never set as the system default output. Choosing an output in the app changes the real system output directly. Consequently bypass/uninstall does not have a fake device to restore. The user's chosen real output remains selected.

## Lifecycle and failure handling

Reconfiguration fades the current route, coalesces changes, snapshots plugin state, stops the IOProc, destroys the aggregate, and destroys its taps. A generation token and cancellation protect against stale asynchronous AU construction. A new graph polls readiness for up to two seconds before starting. Device list/default output, sample rate, process changes, and sleep/wake trigger recovery. A periodic watchdog checks callback progress and deadline overruns; repeated failures invoke panic bypass. Temporary graphs clean up on every error.

Panic bypass cancels rebuilds and tears down processing and analysis immediately. A process crash relies on Core Audio's ownership of private objects to release taps. There is no persistent driver or public aggregate to orphan.

## Signal processing

- Each app has independent atomically published gain and mute. Solo silences non-solo apps and the residual system mix, including newly appearing processes.
- Gains, balance, mono interpolation, master fade, effect wet/dry bypass, and ceiling updates ramp. Parameter editors schedule 30 ms ramps when supported by the AU.
- The loudness target uses BS.1770 K-weighting coefficients transformed for the actual sample rate and a rolling three-second energy window. It waits for a minimum measurement interval, avoids makeup below the silence gate, and limits makeup to the configured cap. A separate integrated meter accumulates overlapping 400 ms blocks with 100 ms hops, an absolute −70 LUFS gate, and a relative −10 LU gate. Bounded 0.1 LU energy/count bins avoid allocation or unbounded program history. Formal conformance-vector qualification remains.
- A stereo-linked 1.5 ms lookahead limiter uses a 4× windowed-sinc peak detector, a monotonic maximum queue, immediate gain reduction, a 100 ms release, and a small reconstruction margin. A bounded soft knee follows it. Tests independently reconstruct output at 16× using a longer sinc kernel.
- A zero-processing routing plan creates no graph, preserving the original signal at every level. An offline delay-aligned null test additionally verifies the active unity path below the protection ceiling after its startup fade.

## Audio Units

AUv2 and AUv3 Effect/MusicEffect components are discovered through `AVAudioUnitComponentManager`. Instances use standard planar float stereo at the device rate. Parameters and full-state property lists live in the device profile; states are matched by slot UUID, so reorder cannot move a state to the wrong effect. Native custom controllers are requested through CoreAudioKit, with a generic parameter fallback.

Every effect and its editor lives in a child process launched from the signed app executable. AU bus formats are configured through `AUAudioUnitBus.setFormat`, then a C++ worker renders the chain into preallocated shared-memory packets. The parent callback submits a block and consumes the preceding block without waiting, locking, allocating, or invoking plugin code. This adds one fixed device buffer for the entire chain, plus reported AU latency.

If the worker misses a deadline, the parent emits the corresponding delayed dry block. Fatal crashes, render errors, and repeated misses mark the worker unavailable; the UI bypasses the responsible slot and rebuilds the remaining chain. A crash during ambiguous initialization/editor work conservatively bypasses the chain. JSON control/state pipes are separate from audio, suppress SIGPIPE in the parent, and use bounded messages. State is saved periodically and requested before reconfiguration. The shared-memory name is unlinked immediately after the child maps it; mappings disappear when their processes exit. A parent watchdog and bounded termination handle hung plugins. Tests exercise an actual Apple EQ, state round-trip, a frozen worker, and a forced fatal worker exit.

## Visualization

With a master/residual processing tap, visualization uses the final protected mix. With only per-app processing, an additional unmuted residual system tap joins the same aggregate; its signal is added to the processed mix only in the analysis ring and never written to output. Without processing, an unmuted exclude-self global tap supplies analysis. This avoids capturing both a source and its re-rendered copy.

The renderer drains a bounded SPSC mono ring, uses a 2048-point Hann-windowed vDSP FFT, maps 64 logarithmic bands, smooths attack/decay, and delays frames by reported latency plus a per-device nudge. Ember, Halo, and Grid draw a single fullscreen triangle. Tide retains phosphor energy in two half-resolution textures with elapsed-time decay and a five-tap blur, then composites at display resolution. Drift draws instanced particle quads in one call, avoiding a particle loop over every 4K pixel. Slow GPU frames reduce particle count and frame rate. A closed window releases the observer tap and stops rendering/FFT work. Reduce Motion uses a static display.

## Public API references

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap: process tap setup and permission notes](https://github.com/insidegui/AudioCap) — consulted as API guidance; no private TCC API or source copied.
- [Apple: AUAudioUnit](https://developer.apple.com/documentation/audiotoolbox/auaudiounit)
- [Sparkle integration and signing](https://sparkle-project.org/documentation/)

The local Xcode 16.4/macOS 15.5 SDK headers are the compilation authority for API names and availability.
