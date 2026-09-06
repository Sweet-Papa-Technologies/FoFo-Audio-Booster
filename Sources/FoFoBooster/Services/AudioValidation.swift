import AppKit
@preconcurrency import AVFoundation
import AudioDSP
import CoreAudio

@MainActor
enum AudioValidation {
    static var active: Bool { ["--validate-audio", "--validate-effects", "--validate-visualizer", "--soak"].contains { CommandLine.arguments.contains($0) } }
    static func run() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--validate-visualizer") { try VisualizerValidation.run() }
                else if CommandLine.arguments.contains("--validate-effects") { try await effects() }
                else { try await audio() }
                exit(0)
            } catch { print("VALIDATION FAILED: \(error.localizedDescription)"); fflush(stdout); exit(1) }
        }
        NSApp.run()
    }
    static func require(_ test: Bool, _ message: String) throws {
        if !test { throw AudioFailure(operation: message) }
    }
    static func report(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
        print(line); fflush(stdout)
    }
    static func seconds(_ flag: String, fallback: Double) -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index+1), let value = Double(CommandLine.arguments[index+1]), value > 0 else { return fallback }
        return value
    }
    static func startSource(duration: Double) async throws -> (Process, AudioObjectID) {
        let child = Process(); child.executableURL = Bundle.main.executableURL; child.arguments = ["--validation-source", String(duration)]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        for _ in 0..<100 {
            let id = HAL.processID(child.processIdentifier)
            if id != 0, HAL.value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 { return (child, id) }
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning { child.terminate() }
        throw AudioFailure(operation: "The isolated low-level validation source did not start")
    }
    static func peak(_ graph: TapGraph, duration: Double = 0.6) async throws -> Float {
        var maximum: Float = 0, samples = [Float](repeating: 0, count: 8192)
        let end = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(20))
            let count = Int(ff_read_samples(graph.dsp, &samples, UInt32(samples.count)))
            for sample in samples.prefix(count) { maximum = max(maximum, abs(sample)) }
        }
        return maximum
    }
    static func audio() async throws {
        let duration = CommandLine.arguments.contains("--soak") ? seconds("--soak", fallback: 86400) : 3
        guard var device = OutputDevice.discover().first(where: { $0.id == HAL.defaultOutput() }) else { throw AudioFailure(operation: "No current output device") }
        let originalOutput = device.id
        report(["event":"starting", "mode":duration > 3 ? "soak" : "audio-spike", "device":device.name, "rate":device.sampleRate, "capture":"permission may be requested", "sourceDBFS":-90.46, "durationSeconds":duration])
        var (source, processID) = try await startSource(duration: duration + 60)
        defer { if source.isRunning { source.terminate() } }
        var plan = [SourcePlan(key: "validation", processes: [processID], exclusive: false)]
        let observer = TapGraph(plan: plan, analysisOnly: true)
        do { try await observer.start(device: device, profile: DeviceProfile(), cap: 12, analyze: true) }
        catch { observer.stop(); throw error }
        _ = try await peak(observer, duration: 0.3)
        let baseline = try await peak(observer)
        let observerCallbacks = observer.meters.callbacks
        observer.stop()
        try require(observerCallbacks > 0, "The tap did not produce callbacks")
        try require(baseline > 1e-9, "The signed tap returned silence. Allow system audio capture in Privacy & Security, then retry")
        var profile = DeviceProfile(); profile.apps["validation"] = AppLevel(boost: 3)
        var graph = TapGraph(plan: plan)
        defer { graph.stop() }
        try await graph.start(device: device, profile: profile, cap: 12, analyze: true)
        _ = try await peak(graph, duration: 0.3)
        let processed = try await peak(graph)
        let measuredGain = 20 * log10(max(processed, 1e-12) / baseline)
        try require(abs(measuredGain-3) < 0.6, "The live per-source gain did not match +3 dB")
        report(["event":"tap-gain-passed", "baselinePeak":baseline, "processedPeak":processed, "measuredGainDB":measuredGain, "callbacks":graph.meters.callbacks, "tapRates":Array(graph.tapSampleRates)])
        let start = ProcessInfo.processInfo.systemUptime
        var usageStart = rusage(); getrusage(RUSAGE_SELF, &usageStart)
        var previousCallbacks: UInt64 = graph.meters.callbacks, stalls = 0, rebuilds = 0, failures: UInt32 = 0
        var lastRate = device.sampleRate, lastOutput = device.id
        let relaunchInterval = CommandLine.arguments.contains("--relaunch-every") ? seconds("--relaunch-every", fallback: 300) : Double.infinity
        var nextRelaunch = relaunchInterval, relaunches = 0
        while ProcessInfo.processInfo.systemUptime-start < duration {
            try await Task.sleep(for: .seconds(1))
            let elapsed = ProcessInfo.processInfo.systemUptime-start
            if elapsed >= nextRelaunch {
                graph.stop()
                if source.isRunning { source.terminate() }
                (source, processID) = try await startSource(duration: max(60, duration-elapsed+60))
                plan = [SourcePlan(key: "validation", processes: [processID], exclusive: false)]
                graph = TapGraph(plan: plan)
                try await graph.start(device: device, profile: profile, cap: 12, analyze: true)
                let restoredPeak = try await peak(graph, duration: 0.4)
                try require(restoredPeak > 1e-9, "Relaunched source did not recover")
                previousCallbacks = 0; stalls = 0; relaunches += 1; nextRelaunch += relaunchInterval
                report(["event":"source-relaunched", "count":relaunches, "elapsedSeconds":elapsed])
            }
            let current = OutputDevice.discover().first { $0.id == HAL.defaultOutput() }
            let meters = graph.meters
            stalls = meters.callbacks == previousCallbacks ? stalls+1 : 0; previousCallbacks = meters.callbacks
            failures = max(failures, meters.failures)
            if let current, current.id != lastOutput || current.sampleRate != lastRate || stalls >= 2 {
                graph.stop(); device = current; graph = TapGraph(plan: plan)
                try await graph.start(device: device, profile: profile, cap: 12, analyze: false)
                lastOutput = current.id; lastRate = current.sampleRate; stalls = 0; previousCallbacks = 0; rebuilds += 1
                report(["event":"recovered", "device":current.name, "rebuilds":rebuilds])
            }
            if Int(ProcessInfo.processInfo.systemUptime-start) % 60 == 0 {
                report(["event":"soak-progress", "elapsedSeconds":ProcessInfo.processInfo.systemUptime-start, "callbacks":meters.callbacks, "overruns":meters.failures, "rebuilds":rebuilds])
            }
        }
        let tapped = graph.taps, aggregate = graph.aggregate
        let stopTime = ProcessInfo.processInfo.systemUptime; graph.stop()
        let bypassMS = (ProcessInfo.processInfo.systemUptime-stopTime)*1000
        var released = false
        for _ in 0..<100 {
            let remainingTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList)), devices = Set(HAL.ids(HAL.system, kAudioHardwarePropertyDevices))
            if Set(tapped).isDisjoint(with: remainingTaps) && !devices.contains(aggregate) { released = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(released, "Private audio objects remained after bypass")
        if duration <= 3 { try require(HAL.defaultOutput() == originalOutput, "Validation changed the system output") }
        var usageEnd = rusage(); getrusage(RUSAGE_SELF, &usageEnd)
        func cpu(_ value: rusage) -> Double { Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec)/1e6 }
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        report(["event":"passed", "elapsedSeconds":elapsed, "cpuPercent":100*(cpu(usageEnd)-cpu(usageStart))/elapsed, "maxRSSMiB":Double(usageEnd.ru_maxrss)/1048576, "overruns":failures, "rebuilds":rebuilds, "sourceRelaunches":relaunches, "bypassMS":bypassMS, "objectsReleased":true, "scope":"engine process with validation source; no device switches were initiated"])
        try require(failures == 0, "The audio callback reported deadline overruns")
    }
    static func effects() async throws {
        let available = PluginHost.discover()
        for subtype in [kAudioUnitSubType_NBandEQ, kAudioUnitSubType_DynamicsProcessor, kAudioUnitSubType_PeakLimiter, kAudioUnitSubType_NewTimePitch] {
            guard let effect = available.first(where: { $0.description.componentSubType == subtype && $0.description.componentManufacturer == kAudioUnitManufacturer_Apple }), let engine = ff_create(48000, 1, 0, false) else { throw AudioFailure(operation: "Required Apple preset or DSP unavailable") }
            let host = PluginHost(), slot = effect.slot
            defer { host.stop(); ff_destroy(engine) }
            var failure: Int?
            host.onFailure = { index, _ in failure = index ?? -1 }
            try await host.prepare([slot], rate: 48000, bufferFrames: 128, engine: engine)
            var left = [Float](repeating: 0.01, count: 128), right = left, outLeft = left, outRight = left
            for _ in 0..<100 { ff_process(engine, &left, &right, &outLeft, &outRight, 128); try await Task.sleep(for: .milliseconds(5)) }
            await host.captureState()
            try require(failure == nil, "The effect failed before fault injection")
            try require(outLeft.allSatisfy { $0.isFinite } && outLeft.contains { abs($0) > 1e-6 }, "The effect did not render valid audio")
            let saved = host.snapshot([slot])
            try require(saved.first?.state != nil, "The worker did not return plugin state")
            guard let bridge = host.bridge else { throw AudioFailure(operation: "Worker bridge missing") }
            ff_bridge_test_fault(bridge, 0)
            for _ in 0..<100 {
                ff_process(engine, &left, &right, &outLeft, &outRight, 128)
                try require(outLeft.allSatisfy { $0.isFinite && abs($0) <= 0.892 }, "Invalid output after plugin crash")
                try await Task.sleep(for: .milliseconds(5))
                if failure != nil { break }
            }
            try require(failure == 0, "The worker crash was not attributed to its effect")
            ff_attach_remote(engine, nil); host.stop()
            failure = nil
            try await host.prepare(saved, rate: 48000, bufferFrames: 128, engine: engine)
            for _ in 0..<30 { ff_process(engine, &left, &right, &outLeft, &outRight, 128); try await Task.sleep(for: .milliseconds(5)) }
            try require(failure == nil, "Restoring the saved effect state failed")
            AudioValidation.report(["event":"preset-passed", "preset":effect.name, "parentSurvived":true, "dryFallback":true, "stateRestored":true])
        }
        report(["event":"passed", "mode":"effects", "presets":4, "parentSurvived":true, "dryFallback":true, "stateRoundTrip":true])
    }
    static func source() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for index in 0..<48000 { buffer.floatChannelData![channel][index] = Float(sin(2 * .pi * 1000 * Double(index)/48000)) * 0.00003 } }
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        func play() { do { try engine.start(); player.scheduleBuffer(buffer, at: nil, options: [.loops]); player.play() } catch { exit(2) } }
        play()
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in Task { @MainActor in player.stop(); play() } }
        let parentPID = getppid()
        let parentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if getppid() != parentPID { player.stop(); engine.stop(); exit(0) }
        }
        let duration = seconds("--validation-source", fallback: 60)
        DispatchQueue.main.asyncAfter(deadline: .now()+duration) { player.stop(); engine.stop(); NotificationCenter.default.removeObserver(observer); exit(0) }
        NSApp.run()
        withExtendedLifetime((engine,player,buffer,observer,parentTimer)) {}
    }
}
