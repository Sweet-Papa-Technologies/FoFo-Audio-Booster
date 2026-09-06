import SwiftUI
import CoreAudio
import AudioDSP
import ServiceManagement
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var devices: [OutputDevice] = []
    @Published var apps: [AudioApp] = []
    @Published var selectedUID = ""
    @Published var profile = DeviceProfile()
    @Published var bypassed = true
    @Published var error: String?
    @Published var working = false
    @Published var permissionGranted = UserDefaults.standard.bool(forKey: "onboarded")
    @Published var showAll = false
    @Published var reduction: Float = 0
    @Published var peak: Float = 0
    @Published var loudness: Float = -100
    @Published var integratedLoudness: Float = -100
    @Published var notice = false
    @Published var visualizerOpen = false
    @Published var advanced = UserDefaults.standard.bool(forKey: "advancedBoost")
    @Published var profiles: [String: DeviceProfile] = [:]
    @Published var undoInput: AudioObjectID?
    @Published var sourceRate: Double = 0
    @Published var detectedSourceRate: Double?
    var effectiveSourceRate: Double { sourceRate > 0 ? sourceRate : detectedSourceRate ?? 0 }
    @Published var hotkeyError: String?
    let analyzer = SpectrumAnalyzer()
    private let store = ProfileStore()
    private let listener = HardwareListener()
    private var deviceListener = HardwareListener()
    private var timer: Timer?
    private var graphTask: Task<Void, Never>?
    private var graph: TapGraph?
    private var analysisGraph: TapGraph?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var lastCallbacks: UInt64 = 0
    private var stalls = 0
    private var lastFailures: UInt32 = 0
    private var overloads = 0
    private var listeningMonitor = ListeningMonitor()
    private var suspended = false
    private var resumeAfterWake = false
        private(set) var hotkeys: Hotkeys?
    var device: OutputDevice? { devices.first { $0.uid == selectedUID } }
    var cap: Double { advanced ? 24 : 12 }
    var bypassShortcut: String { hotkeys?.bindings.first(where: { $0.id == 1 })?.display ?? "⌥⇧B" }
    var stateName: String { error != nil ? "Needs attention" : bypassed ? "Bypassed" : working ? "Connecting…" : graph == nil ? "Ready · original audio" : "Boost is on" }
    var stateSymbol: String { error != nil ? "exclamationmark.triangle.fill" : bypassed ? "speaker.slash" : graph != nil ? "speaker.wave.3.fill" : "speaker.wave.2" }
    var issueCount: Int { (device?.isCallMode == true ? 1 : 0) + (rateMismatch ? 1 : 0) }
    var rateMismatch: Bool { guard let device else { return false }; return effectiveSourceRate > 0 && !device.isCallMode && abs(device.sampleRate - effectiveSourceRate) > 1 }
    var totalLatency: Double { guard let device else { return 0 }; return device.latencyMS + (graph == nil ? 0 : Double(device.bufferFrames) / device.sampleRate * 1000 + 1.5 + (graph?.plugins.latency ?? 0) * 1000) }
    var pluginHost: PluginHost? { graph?.plugins }
    var visibleApps: [AudioApp] { showAll ? apps : apps.filter { $0.running } }
    init() { profiles = store.load() }
    func start() {
        refresh()
        listener.watch(HAL.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
        listener.watch(HAL.system, kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() }
        listener.watch(HAL.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleep() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.wake() } })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        hotkeys = Hotkeys(model: self); hotkeys?.register()
        if permissionGranted { bypassed = false; rebuild() }
    }
    func refresh() {
        let found = OutputDevice.discover()
        let current = found.first { $0.id == HAL.defaultOutput() }
        let changed = current?.uid != selectedUID || current?.sampleRate != device?.sampleRate
        if changed { savePluginState(); saveProfile() }
        devices = found
        let newApps = AppDiscovery.discover()
        let topologyChanged = apps.map { "\($0.id):\($0.processes)" } != newApps.map { "\($0.id):\($0.processes)" }
        apps = newApps
        if changed {
            selectedUID = current?.uid ?? ""
            profile = profiles[selectedUID] ?? DeviceProfile(name: current?.name ?? "Output")
            profile.sanitize(cap: cap)
            deviceListener.removeAll()
            if let current { deviceListener.watch(current.id, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.refresh() } }
            listeningMonitor.resetContinuity()
        }
        if changed || topologyChanged { rebuild() }
    }
    func selectDevice(_ uid: String) {
        guard let next = devices.first(where: { $0.uid == uid }) else { return }
        do { try HAL.set(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, next.id); refresh() }
        catch { fail(error) }
    }
    func change(_ edit: (inout DeviceProfile) -> Void) {
        let before = plan()
        let oldPlugins = profile.plugins
        edit(&profile); profile.sanitize(cap: cap)
        graph?.update(profile: profile, cap: cap)
        saveProfile()
        if before != plan() || oldPlugins.map({ "\($0.id):\($0.bypass)" }) != profile.plugins.map({ "\($0.id):\($0.bypass)" }) { rebuild() }
    }
    func setApp(_ key: String, edit: (inout AppLevel) -> Void) {
        change { profile in var level = profile.apps[key] ?? AppLevel(); edit(&level); profile.apps[key] = level }
    }
    func setAdvanced(_ enabled: Bool) {
        advanced = enabled; UserDefaults.standard.set(enabled, forKey: "advancedBoost")
        for key in profiles.keys { profiles[key]?.sanitize(cap: cap) }
        change { $0.sanitize(cap: cap) }
    }
    func setBoost(_ db: Double) {
        change { $0.boost = db }
        if bypassed && permissionGranted { bypassed = false; rebuild() }
    }
    func toggleBypass() {
        if !bypassed { panic() }
        else if permissionGranted { error = nil; bypassed = false; rebuild() }
    }
    func panic() {
        generation += 1; graphTask?.cancel(); graphTask = nil
        savePluginState(); graph?.stop(); graph = nil
        analysisGraph?.stop(); analysisGraph = nil
        bypassed = true; working = false; reduction = 0; peak = 0; listeningMonitor.resetContinuity(); detectedSourceRate = nil
        publishWidget()
    }
    func requestPermission() async {
        guard let device else { error = "Connect an output device, then try again."; return }
        working = true; error = nil
        let probe = TapGraph(plan: [SourcePlan(key: "permission", processes: ownProcesses(), exclusive: true)], analysisOnly: true)
        do {
            try await probe.start(device: device, profile: DeviceProfile(), cap: cap, analyze: false)
            probe.stop(); permissionGranted = true; UserDefaults.standard.set(true, forKey: "onboarded")
            bypassed = false; working = false; rebuild()
        } catch { probe.stop(); working = false; self.error = error.localizedDescription }
    }
    private func ownProcesses() -> [UInt32] {
        HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList).filter { HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == getpid() }
    }
    private func plan() -> [SourcePlan] { RoutingPlan.make(profile: profile, apps: apps, ownProcesses: ownProcesses()) }
    func rebuild() {
        guard permissionGranted, !bypassed, !suspended else { return }
        generation += 1; let token = generation
        graphTask?.cancel()
        graphTask = Task { @MainActor [weak self] in
            guard let self else { return }
            working = true
            do {
                // Coalesce slider changes and let the old path fade while it is still alive.
                graph?.fadeOut()
                try await Task.sleep(for: .milliseconds(100))
                guard token == generation else { return }
                await graph?.plugins.captureState()
                guard token == generation else { return }
                savePluginState(); graph?.stop(); graph = nil; analysisGraph?.stop(); analysisGraph = nil
                guard let device else { throw AudioFailure(operation: "No output device is available") }
                var nextPlan = plan()
                if visualizerOpen, !nextPlan.isEmpty, !nextPlan.contains(where: { $0.exclusive }) {
                    nextPlan.append(SourcePlan(key: "__analysis__", processes: (ownProcesses() + nextPlan.flatMap(\.processes)).sorted(), exclusive: true))
                }
                if !nextPlan.isEmpty {
                    let next = TapGraph(plan: nextPlan)
                    next.plugins.onStateChange = { [weak self] slots in
                        guard let self, var saved = self.profiles[device.uid] else { return }
                        for index in saved.plugins.indices {
                            if let state = slots.first(where: { $0.id == saved.plugins[index].id })?.state { saved.plugins[index].state = state }
                        }
                        self.profiles[device.uid] = saved; self.store.save(self.profiles)
                        if self.selectedUID == device.uid { self.profile.plugins = saved.plugins }
                    }
                    next.plugins.onFailure = { [weak self] index, message in
                        guard let self, self.generation == token else { return }
                        if let index, self.profile.plugins.indices.contains(index) { self.profile.plugins[index].bypass = true }
                        else { for index in self.profile.plugins.indices { self.profile.plugins[index].bypass = true } }
                        self.error = message; self.saveProfile(); self.rebuild()
                    }
                    do { try await next.start(device: device, profile: profile, cap: cap, analyze: visualizerOpen) }
                    catch { next.stop(); throw error }
                    guard token == generation, !Task.isCancelled else { next.stop(); return }
                    graph = next
                    detectedSourceRate = next.tapSampleRates.count == 1 ? next.tapSampleRates.first : nil
                }
                if visualizerOpen && nextPlan.isEmpty {
                    // With no processed sources, observe the system without muting anything.
                    let next = TapGraph(plan: [SourcePlan(key: "visualizer", processes: ownProcesses(), exclusive: true)], analysisOnly: true)
                    do { try await next.start(device: device, profile: DeviceProfile(), cap: cap, analyze: true) }
                    catch { next.stop(); throw error }
                    guard token == generation, !Task.isCancelled else { next.stop(); return }
                    analysisGraph = next
                }
                lastCallbacks = 0; lastFailures = 0; stalls = 0; overloads = 0
                working = false; error = nil; publishWidget()
            } catch is CancellationError { }
            catch { if token == generation { fail(error) } }
        }
    }
    func setVisualizer(_ open: Bool) {
        visualizerOpen = open
        if !open {
            analysisGraph?.stop(); analysisGraph = nil; analyzer.reset()
            if graph?.plan.contains(where: { $0.key == "__analysis__" }) == true { rebuild() }
            else if let dsp = graph?.dsp { ff_set_analysis(dsp, false) }
        }
        else if !bypassed { rebuild() }
    }
    func updateSpectrum() {
        guard visualizerOpen, let dsp = graph?.dsp ?? analysisGraph?.dsp, let device else { return }
        analyzer.consume(dsp: dsp, sampleRate: device.sampleRate, delayMS: max(0, device.latencyMS + profile.visualizerNudge))
    }
    func fixCallMode() {
        guard let builtIn = HAL.ids(HAL.system, kAudioHardwarePropertyDevices).first(where: { HAL.value($0, kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn && HAL.channels($0, scope: kAudioObjectPropertyScopeInput) > 0 }) else { error = "No built-in microphone is available. Choose a different microphone in System Settings → Sound → Input."; return }
        do { undoInput = HAL.defaultInput(); try HAL.set(HAL.system, kAudioHardwarePropertyDefaultInputDevice, builtIn); refresh() }
        catch { fail(error) }
    }
    func undoCallFix() {
        guard let input = undoInput else { return }
        do { try HAL.set(HAL.system, kAudioHardwarePropertyDefaultInputDevice, input); undoInput = nil; refresh() }
        catch { self.error = error.localizedDescription }
    }
    func fixSampleRate() {
        guard let device else { return }
        do { try HAL.set(device.id, kAudioDevicePropertyNominalSampleRate, effectiveSourceRate); refresh() }
        catch { fail(error) }
    }
    func dismissNotice() { notice = false; listeningMonitor.dismiss() }
    func savePluginState() {
        guard let host = graph?.plugins, host.loadedCount > 0 else { return }
        profile.plugins = host.snapshot(profile.plugins); saveProfile()
    }
    func saveProfile() {
        guard !selectedUID.isEmpty else { return }
        profiles[selectedUID] = profile; store.save(profiles); publishWidget()
    }
    func deleteProfile(_ uid: String) {
        profiles.removeValue(forKey: uid); store.save(profiles)
        if uid == selectedUID { profile = DeviceProfile(name: device?.name ?? "Output"); rebuild() }
    }
    private func publishWidget() {
        let defaults = UserDefaults(suiteName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")
        defaults?.set(profile.boost, forKey: "boost"); defaults?.set(!bypassed, forKey: "enabled"); defaults?.set(device?.name ?? "No output", forKey: "device")
        WidgetCenter.shared.reloadTimelines(ofKind: "FoFoBoosterWidget")
    }
    private func tick() {
        let widgetDefaults = UserDefaults(suiteName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")
        if widgetDefaults?.string(forKey: "pendingToggle") != nil {
            widgetDefaults?.removeObject(forKey: "pendingToggle"); toggleBypass()
        }
        refresh()
        if let graph, !working {
            let meter = graph.meters
            reduction = meter.reductionDB; peak = meter.peak; loudness = meter.loudnessLUFS; integratedLoudness = meter.integratedLUFS
            stalls = meter.callbacks == lastCallbacks ? stalls + 1 : 0; lastCallbacks = meter.callbacks
            let failures = meter.failures &- lastFailures; lastFailures = meter.failures
            overloads = failures > 0 ? overloads + Int(failures) : max(0, overloads - 1)
            if stalls >= 3 || overloads >= 5 { fail(AudioFailure(operation: "Audio processing stopped responding. Boost was bypassed automatically")); return }
            if meter.pluginFailures != 0 {
                for index in profile.plugins.indices where meter.pluginFailures & (1 << index) != 0 { profile.plugins[index].bypass = true }
                error = "An effect returned a render error and was bypassed. Other audio continues."; saveProfile()
            }
        }
        let activeBoost = max(profile.boost, apps.filter(\.running).map { (profile.apps[$0.id]?.boost ?? 0) + profile.boost }.max() ?? 0)
        notice = listeningMonitor.update(time: ProcessInfo.processInfo.systemUptime, deviceUID: device?.uid ?? "", headphones: device?.isHeadphones == true, processing: graph?.started == true && !bypassed, activeBoost: activeBoost)

    }
    private func fail(_ failure: Error) { panic(); error = failure.localizedDescription }
    private func sleep() { resumeAfterWake = !bypassed; suspended = true; panic() }
    private func wake() { suspended = false; refresh(); if resumeAfterWake { bypassed = false; rebuild() } }
    func shutdown() {
        savePluginState(); saveProfile(); panic(); timer?.invalidate(); listener.removeAll(); deviceListener.removeAll()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
    }
    func uninstall() {
        shutdown()
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            guard HAL.defaultOutput() != 0 else { throw AudioFailure(operation: "Choose an output device before uninstalling") }
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            UserDefaults(suiteName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")?.removePersistentDomain(forName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")
            WidgetCenter.shared.reloadAllTimelines()
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            NSApp.terminate(nil)
        } catch { self.error = "Audio is restored. Could not finish uninstalling: \(error.localizedDescription)" }
    }
}
