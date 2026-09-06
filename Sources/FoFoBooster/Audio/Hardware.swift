import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    var operation: String
    var status: OSStatus = -1
    var errorDescription: String? { "\(operation) (Core Audio \(status)). Audio has been returned to the system." }
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(operation: operation, status: status) }
}
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var a = address(selector, scope), result = fallback, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return status == noErr ? result : fallback
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }
    static func set<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws {
        var a = address(selector), v = value
        try withUnsafePointer(to: &v) { pointer in
            try check(AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), pointer), "Could not change audio setting")
        }
    }
    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        channelLayout(id, scope: scope).reduce(0, +)
    }
    static func channelLayout(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }
    static func defaultOutput() -> AudioObjectID { value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) }
    static func defaultInput() -> AudioObjectID { value(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0)) }
    static func processID(_ pid: pid_t) -> AudioObjectID {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject), p = pid, result: AudioObjectID = 0, size: UInt32 = 4
        _ = AudioObjectGetPropertyData(system, &a, 4, &p, &size, &result)
        return result
    }
}
struct OutputDevice: Identifiable, Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var sampleRate: Double
    var channels: Int
    var transport: UInt32
    var latencyFrames: UInt32
    var bufferFrames: UInt32
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isHeadphones: Bool { isBluetooth || name.localizedCaseInsensitiveContains("headphone") || name.localizedCaseInsensitiveContains("airpods") }
    var isCallMode: Bool { isBluetooth && channels == 1 && sampleRate <= 16000 }
    var symbol: String { isHeadphones ? "headphones" : transport == kAudioDeviceTransportTypeBuiltIn ? "hifispeaker.fill" : "speaker.wave.2.fill" }
    var latencyMS: Double { Double(latencyFrames) / max(sampleRate, 1) * 1000 }
    static func discover() -> [OutputDevice] {
        HAL.ids(HAL.system, kAudioHardwarePropertyDevices).compactMap { id in
            let channels = HAL.channels(id, scope: kAudioObjectPropertyScopeOutput)
            guard channels > 0 else { return nil }
            let uid = HAL.string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.hasPrefix("com.sweetpapatechnologies.FoFoBooster.aggregate") else { return nil }
            return OutputDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName),
                                sampleRate: HAL.value(id, kAudioDevicePropertyNominalSampleRate, default: 48000.0), channels: channels,
                                transport: HAL.value(id, kAudioDevicePropertyTransportType, default: UInt32(0)),
                                latencyFrames: HAL.value(id, kAudioDevicePropertyLatency, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput) + HAL.value(id, kAudioDevicePropertySafetyOffset, default: UInt32(0), scope: kAudioObjectPropertyScopeOutput),
                                bufferFrames: HAL.value(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(128)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
struct AudioApp: Identifiable, Equatable {
    var id: String
    var name: String
    var processes: [AudioObjectID]
    var running: Bool
    var bundleURL: URL?
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.processes == b.processes && a.running == b.running && a.name == b.name }
}
enum AppDiscovery {
    static let aliases = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.hnc.Discord", "com.tinyspeck.slackmacgap", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.spotify.client", "com.apple.Safari"]
    static func canonical(_ id: String) -> String {
        aliases.first { id == $0 || id.hasPrefix($0 + ".") } ?? id
    }
    static func parentApplication(pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_ppid > 1, pid_t(info.pbi_ppid) != current else { break }
            current = pid_t(info.pbi_ppid)
        }
        return nil
    }
    static func discover() -> [AudioApp] {
        var grouped: [String: AudioApp] = [:]
        for id in HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            let pid = HAL.value(id, kAudioProcessPropertyPID, default: pid_t(0))
            guard pid != getpid() else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let parent = parentApplication(pid: pid)
            let raw = HAL.string(id, kAudioProcessPropertyBundleID)
            var key = canonical(parent?.bundleIdentifier ?? (raw.isEmpty ? app?.bundleIdentifier ?? "process.\(pid)" : raw))
            var url = parent?.bundleURL ?? app?.bundleURL
            // Nested helper bundles reveal the owning app even if launchd has reparented them.
            if let bundle = url {
                let parts = bundle.pathComponents
                if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                    let outer = URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 1))))
                    if let identifier = Bundle(url: outer)?.bundleIdentifier { key = canonical(identifier); url = outer }
                }
            }
            if key == Bundle.main.bundleIdentifier { continue }
            let running = HAL.value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            if var existing = grouped[key] { existing.processes.append(id); existing.running = existing.running || running; grouped[key] = existing }
            else { grouped[key] = AudioApp(id: key, name: parent?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? app?.localizedName ?? key, processes: [id], running: running, bundleURL: url) }
        }
        return grouped.values.map { var app = $0; app.processes.sort(); return app }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
final class HardwareListener {
    private var entries: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, changed: @escaping () -> Void) {
        var address = HAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { entries.append((object, address, block)) }
    }
    func removeAll() { for (object, var address, block) in entries { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }; entries.removeAll() }
    deinit { removeAll() }
}
