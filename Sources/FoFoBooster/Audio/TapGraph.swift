import Foundation
import CoreAudio
import AudioDSP

@MainActor
final class TapGraph {
    private(set) var taps: [AudioObjectID] = []
    private(set) var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private(set) var dsp: OpaquePointer?
    let plan: [SourcePlan]
    let analysisOnly: Bool
    let plugins = PluginHost()
    private(set) var started = false
    private(set) var tapSampleRates: Set<Double> = []
    init(plan: [SourcePlan], analysisOnly: Bool = false) { self.plan = plan; self.analysisOnly = analysisOnly }
    func start(device: OutputDevice, profile: DeviceProfile, cap: Double, analyze: Bool) async throws {
        do {
            guard plan.count <= 64 else { throw AudioFailure(operation: "Too many audio sources") }
            var descriptions: [CATapDescription] = []
            for source in plan {
                let description = source.exclusive ? CATapDescription(excludingProcesses: source.processes, deviceUID: device.uid, stream: 0) : CATapDescription(processes: source.processes, deviceUID: device.uid, stream: 0)
                description.name = "FoFoBooster · \(source.key)"
                description.isPrivate = true
                description.muteBehavior = analysisOnly || source.key == "__analysis__" ? .unmuted : .mutedWhenTapped
                var tap: AudioObjectID = 0
                try check(AudioHardwareCreateProcessTap(description, &tap), "System audio access is needed. Allow FoFoBooster in Privacy & Security → System Audio Recording")
                taps.append(tap); descriptions.append(description)
                let format = HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
                if format.mSampleRate > 0 { tapSampleRates.insert(format.mSampleRate) }
                guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mChannelsPerFrame == 2 else {
                    throw AudioFailure(operation: "Unsupported tap format: rate \(format.mSampleRate), ID \(format.mFormatID), flags \(format.mFormatFlags), bits \(format.mBitsPerChannel), channels \(format.mChannelsPerFrame)")
                }
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "FoFoBooster Private Audio",
                kAudioAggregateDeviceUIDKey: "com.sweetpapatechnologies.FoFoBooster.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: device.uid,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceOutputChannelsKey: 2]],
                kAudioAggregateDeviceTapListKey: descriptions.map { [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any] }
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Could not create the private audio route")
            // Aggregate streams appear asynchronously. Never start a half-configured graph.
            var ready = false
            for _ in 0..<100 {
                try Task.checkCancellation()
                if HAL.channels(aggregate, scope: kAudioObjectPropertyScopeInput) >= plan.count * 2,
                   HAL.channels(aggregate, scope: kAudioObjectPropertyScopeOutput) >= 2 { ready = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard ready else { throw AudioFailure(operation: "The output device did not become ready") }
            let rate = HAL.value(aggregate, kAudioDevicePropertyNominalSampleRate, default: device.sampleRate)
            let offset = HAL.channels(aggregate, scope: kAudioObjectPropertyScopeInput) - plan.count * 2
            // Reject non-float hardware streams rather than writing floats into an integer buffer.
            for stream in HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) {
                let f = HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
                guard f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32, f.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw AudioFailure(operation: "Unsupported output stream format") }
            }
            guard let pointer = ff_create(rate, UInt32(plan.count), UInt32(offset), analysisOnly) else { throw AudioFailure(operation: "Could not allocate audio buffers") }
            dsp = pointer
            if let monitor = plan.firstIndex(where: { $0.key == "__analysis__" }) { ff_set_monitor_source(pointer, Int32(monitor)) }
            update(profile: profile, cap: cap)
            ff_set_analysis(pointer, analyze)
            if !analysisOnly { try await plugins.prepare(profile.plugins, rate: rate, bufferFrames: HAL.value(aggregate, kAudioDevicePropertyBufferFrameSize, default: device.bufferFrames), engine: pointer) }
            try Task.checkCancellation()
            try check(AudioDeviceCreateIOProcID(aggregate, ff_io_proc, UnsafeMutableRawPointer(pointer), &ioProc), "Could not connect the audio callback")
            if let ioProc { try check(ff_configure_stream_usage(aggregate, ioProc, UInt32(plan.count), analysisOnly), "Could not restrict the route to output audio") }
            try check(AudioDeviceStart(aggregate, ioProc), "Could not start audio")
            started = true
        } catch { stop(); throw error }
    }
    func update(profile: DeviceProfile, cap: Double) {
        guard let dsp else { return }
        let solo = profile.apps.values.contains { $0.solo }
        for (index, source) in plan.enumerated() {
            let level = profile.apps[source.key] ?? AppLevel()
            ff_set_source(dsp, UInt32(index), Float(min(level.boost, cap)), source.key != "__analysis__" && (level.muted || (solo && !level.solo)))
        }
        ff_set_master(dsp, Float(min(profile.boost, cap)), Float(profile.ceiling), Float(profile.balance), profile.mono, profile.loudness, Float(profile.target), Float(cap))
        for (index, slot) in profile.plugins.enumerated() { ff_bypass_plugin(dsp, UInt32(index), slot.bypass) }
    }
    func fadeIn() { if let dsp { ff_set_fade(dsp, true) } }
    func fadeOut() { if let dsp { ff_set_fade(dsp, false) } }
    func stop() {
        // Stop the IOProc before disposing any memory it can access. Destroy the aggregate
        // before its taps; mutedWhenTapped then immediately restores each source's output.
        if let ioProc { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        ioProc = nil; started = false
        plugins.stop()
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        for tap in taps { AudioHardwareDestroyProcessTap(tap) }; taps.removeAll()
        if let dsp { ff_destroy(dsp) }; dsp = nil
    }
    var meters: FFMeters { ff_meters(dsp) }
}
