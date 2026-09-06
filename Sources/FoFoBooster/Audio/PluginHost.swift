import AVFoundation
import AppKit
import AudioDSP

struct AvailablePlugin: Identifiable {
    var name: String
    var manufacturer: String
    var description: AudioComponentDescription
    var id: String { "\(description.componentType):\(description.componentSubType):\(description.componentManufacturer)" }
    var slot: PluginSlot { PluginSlot(name: name, type: description.componentType, subtype: description.componentSubType, manufacturer: description.componentManufacturer) }
}
@MainActor
final class PluginHost {
    private var process: Process?
    private var commands: FileHandle?
    private var responses: FileHandle?
    private var input = Data()
    private var directory: URL?
    private(set) var bridge: OpaquePointer?
    private var ready: CheckedContinuation<Void, Error>?
    private var stateRequests: [String: CheckedContinuation<Void, Never>] = [:]
    private var cached: [PluginSlot] = []
    private var epoch = UUID()
    private var monitor: Timer?
    private var previousMisses: UInt32 = 0
    private(set) var latency: Double = 0
    private(set) var isolatedSlots: Set<UUID> = []
    var onStateChange: (([PluginSlot]) -> Void)?
    var onFailure: ((Int?, String) -> Void)?
    var loadedCount: Int { isolatedSlots.count }
    static func discover() -> [AvailablePlugin] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }.map { AvailablePlugin(name: $0.name, manufacturer: $0.manufacturerName, description: $0.audioComponentDescription) }.sorted { $0.name < $1.name }
    }
    func prepare(_ slots: [PluginSlot], rate: Double, bufferFrames: UInt32, engine: OpaquePointer) async throws {
        guard slots.contains(where: { !$0.bypass }) else { return }
        cached = slots
        let token = UUID(); epoch = token
        let bridgeName = "/ffb.\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        guard let shared = ff_bridge_create(bridgeName) else { throw AudioFailure(operation: "Could not create isolated effect buffers") }
        bridge = shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoFoBooster-\(UUID().uuidString)")
        directory = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = folder.appendingPathComponent("plugins.json")
        try JSONEncoder().encode(PluginWorkerConfiguration(bridgeName: bridgeName, sampleRate: rate, slots: slots)).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let worker = Process(), stdin = Pipe(), stdout = Pipe()
        worker.executableURL = Bundle.main.executableURL
        worker.arguments = ["--plugin-worker", configuration.path]
        worker.standardInput = stdin; worker.standardOutput = stdout; worker.standardError = FileHandle.nullDevice
        commands = stdin.fileHandleForWriting; responses = stdout.fileHandleForReading; process = worker
        // A dead worker closes its pipe. Convert EPIPE into a thrown write error,
        // never SIGPIPE in the audio engine's process.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        responses?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in guard let self, self.epoch == token else { return }; self.receive(data, bufferLatency: Double(bufferFrames) / rate) }
        }
        worker.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == token else { return }
                ff_bridge_mark_dead(self.bridge)
                let slot = ff_bridge_fault_slot(self.bridge)
                self.failed(slot: slot >= 0 ? Int(slot) : nil, message: "An effect stopped responding and was bypassed. Your audio engine is still running.")
            }
        }
        do {
            try worker.run()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, self.epoch == token, self.ready != nil else { return }
                    self.failed(slot: nil, message: "The effect worker did not finish loading.")
                }
            }
            try Task.checkCancellation()
            ff_attach_remote(engine, shared)
            isolatedSlots = Set(slots.filter { !$0.bypass }.map(\.id))
            monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.epoch == token, let bridge = self.bridge else { return }
                    let missed = ff_bridge_misses(bridge), delta = missed &- self.previousMisses; self.previousMisses = missed
                    if delta > 12 { self.failed(slot: { let index = ff_bridge_fault_slot(bridge); return index >= 0 ? Int(index) : nil }(), message: "An effect could not keep up and was bypassed.") }
                }
            }
        } catch { stop(); throw error }
    }
    func snapshot(_ slots: [PluginSlot]) -> [PluginSlot] {
        slots.map { slot in var result = slot; if let state = cached.first(where: { $0.id == slot.id })?.state { result.state = state }; return result }
    }
    func captureState() async {
        guard process?.isRunning == true else { return }
        let request = UUID().uuidString
        await withCheckedContinuation { continuation in
            stateRequests[request] = continuation; send(PluginWorkerMessage(kind: "state", request: request))
            Task { @MainActor [weak self] in try? await Task.sleep(for: .milliseconds(300)); self?.stateRequests.removeValue(forKey: request)?.resume() }
        }
    }
    func showEditor(at index: Int) { send(PluginWorkerMessage(kind: "edit", slot: index)) }
    private func send(_ message: PluginWorkerMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }; data.append(10)
        try? commands?.write(contentsOf: data)
    }
    private func receive(_ data: Data, bufferLatency: Double) {
        input.append(data)
        guard input.count <= 16 * 1024 * 1024 else { failed(slot: nil, message: "An effect returned too much state data."); return }
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(PluginWorkerMessage.self, from: line) else { continue }
            if let states = message.slots { cached = states; onStateChange?(states) }
            switch message.kind {
            case "ready": latency = bufferLatency + (message.latency ?? 0); ready?.resume(); ready = nil
            case "state": if let request = message.request { stateRequests.removeValue(forKey: request)?.resume() }
            case "renderError", "error": failed(slot: message.slot, message: message.message ?? "An effect failed.")
            default: break
            }
        }
    }
    private func failed(slot: Int?, message: String) {
        ff_bridge_mark_dead(bridge)
        if let continuation = ready { ready = nil; continuation.resume(throwing: AudioFailure(operation: message)) }
        else { monitor?.invalidate(); monitor = nil; onFailure?(slot, message) }
    }
    func stop() {
        epoch = UUID(); monitor?.invalidate(); monitor = nil
        if let ready { self.ready = nil; ready.resume(throwing: CancellationError()) }
        for continuation in stateRequests.values { continuation.resume() }; stateRequests.removeAll()
        send(PluginWorkerMessage(kind: "stop")); try? commands?.close(); commands = nil
        responses?.readabilityHandler = nil; try? responses?.close(); responses = nil
        if let worker = process {
            worker.terminationHandler = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if worker.isRunning { worker.terminate() }
                try? await Task.sleep(for: .milliseconds(400))
                if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        // The graph owner stops its IOProc before this method; no RT reader remains.
        if let bridge { ff_bridge_mark_dead(bridge); ff_bridge_close(bridge) }; bridge = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        isolatedSlots.removeAll(); input.removeAll(); latency = 0
    }
}
