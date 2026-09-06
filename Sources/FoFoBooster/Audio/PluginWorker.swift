import AppKit
import SwiftUI
import AVFoundation
import CoreAudioKit
import AudioDSP

@MainActor
final class PluginWorker {
    private let configuration: PluginWorkerConfiguration
    private let bridge: OpaquePointer
    private var units: [Int: AVAudioUnit] = [:]
    private var windows: [NSWindow] = []
    private var input = Data()
    private var lastStates: [PluginSlot] = []
    private var timer: Timer?
    private var parentTimer: Timer?
    private let parentPID = getppid()
    init(configuration: PluginWorkerConfiguration, bridge: OpaquePointer) { self.configuration = configuration; self.bridge = bridge }
    static func run() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count > 2,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
              let configuration = try? JSONDecoder().decode(PluginWorkerConfiguration.self, from: data),
              let bridge = ff_bridge_open(configuration.bridgeName) else { exit(2) }
        let worker = PluginWorker(configuration: configuration, bridge: bridge)
        Task { await worker.start() }
        NSApp.run()
        // Retain worker, units, and mappings for the entire event loop.
        withExtendedLifetime(worker) {}
        exit(0)
    }
    func start() async {
        do {
            for (index, slot) in configuration.slots.enumerated() where !slot.bypass {
                ff_bridge_set_editing(bridge, Int32(index))
                let descriptor = AudioComponentDescription(componentType: slot.type, componentSubType: slot.subtype, componentManufacturer: slot.manufacturer, componentFlags: 0, componentFlagsMask: 0)
                let unit: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
                    AVAudioUnit.instantiate(with: descriptor, options: []) { unit, error in
                        if let unit { continuation.resume(returning: unit) }
                        else { continuation.resume(throwing: error ?? AudioFailure(operation: "Could not load \(slot.name)")) }
                    }
                }
                unit.auAudioUnit.deallocateRenderResources()
                let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate, channels: 2)!
                unit.auAudioUnit.maximumFramesToRender = 4096
                try unit.auAudioUnit.inputBusses[0].setFormat(format)
                try unit.auAudioUnit.outputBusses[0].setFormat(format)
                if let data = slot.state, let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { unit.auAudioUnit.fullState = state }
                try check(ff_bridge_add_unit(bridge, unit.audioUnit, UInt32(index)), "Plugin render connection")
                try check(AudioUnitInitialize(unit.audioUnit), "Plugin initialization")
                units[index] = unit
            }
            ff_bridge_set_editing(bridge, -1)
            ff_bridge_worker_start(bridge)
            emit(PluginWorkerMessage(kind: "ready", slots: snapshot(), latency: units.values.reduce(0) { $0 + $1.auAudioUnit.latency }))
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                Task { @MainActor in
                    guard let self else { return }
                    if bytes.isEmpty { self.finish(); return }
                    self.receive(bytes)
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let states = self.snapshot()
                    if states != self.lastStates { self.lastStates = states; self.emit(PluginWorkerMessage(kind: "state", slots: states)) }
                    let failed = ff_bridge_failed_slots(self.bridge)
                    if let fault = (0..<8).first(where: { failed & (1 << $0) != 0 }) { self.emit(PluginWorkerMessage(kind: "renderError", slot: fault, message: "An effect returned a render error.")) }
                }
            }
            parentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; if getppid() != self.parentPID { self.finish() } }
            }
        } catch { emit(PluginWorkerMessage(kind: "error", slot: Int(ff_bridge_fault_slot(bridge)), message: error.localizedDescription)); finish() }
    }
    private func emit(_ message: PluginWorkerMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(10); FileHandle.standardOutput.write(data)
    }
    private func snapshot() -> [PluginSlot] {
        configuration.slots.enumerated().map { index, slot in
            var copy = slot
            if let state = units[index]?.auAudioUnit.fullState { copy.state = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) }
            return copy
        }
    }
    private func receive(_ data: Data) {
        input.append(data)
        guard input.count < 1024 * 1024 else { finish(); return }
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(PluginWorkerMessage.self, from: line) else { continue }
            switch message.kind {
            case "state": emit(PluginWorkerMessage(kind: "state", request: message.request, slots: snapshot()))
            case "edit": if let index = message.slot { edit(index) }
            case "stop": emit(PluginWorkerMessage(kind: "state", slots: snapshot())); finish()
            default: break
            }
        }
    }
    private func edit(_ index: Int) {
        guard let unit = units[index] else { return }
        ff_bridge_set_editing(bridge, Int32(index))
        unit.auAudioUnit.requestViewController { [weak self] controller in
            Task { @MainActor in
                guard let self else { return }
                let content = controller ?? NSHostingController(rootView: GenericPluginView(unit: unit.auAudioUnit))
                let window = NSWindow(contentViewController: content)
                window.title = "\(unit.name) · FoFoBooster"; window.styleMask.formUnion([.titled, .closable, .resizable]); window.isReleasedWhenClosed = false
                if window.frame.width < 300 || window.frame.height < 150 { window.setContentSize(NSSize(width: 480, height: 380)) }
                self.windows.append(window); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    private func finish() {
        FileHandle.standardInput.readabilityHandler = nil; timer?.invalidate(); parentTimer?.invalidate()
        // A hostile plugin can hang teardown. The parent has a bounded kill timeout;
        // its realtime engine has already switched to dry audio.
        ff_bridge_worker_stop(bridge)
        for unit in units.values { AudioUnitUninitialize(unit.audioUnit) }
        ff_bridge_close(bridge)
        exit(0)
    }
}
