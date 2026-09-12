import Foundation

struct AppLevel: Codable, Equatable {
    var boost: Double = 0
    var muted = false
    var solo = false
}
struct PluginSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var bypass = false
    var state: Data?
}
struct DeviceProfile: Codable, Equatable {
    var name = "Output"
    var boost: Double = 0
    var apps: [String: AppLevel] = [:]
    var balance: Double = 0
    var mono = false
    var ceiling: Double = -1
    var loudness = false
    var target: Double = -14
    var plugins: [PluginSlot] = []
    var visualizerNudge: Double = 0
    mutating func sanitize(cap: Double) {
        boost = boost.isFinite ? min(max(boost, 0), cap) : 0
        balance = balance.isFinite ? min(max(balance, -1), 1) : 0
        ceiling = ceiling.isFinite ? min(max(ceiling, -12), -0.3) : -1
        target = target.isFinite ? min(max(target, -24), -9) : -14
        visualizerNudge = visualizerNudge.isFinite ? min(max(visualizerNudge, -250), 500) : 0
        plugins = Array(plugins.prefix(8))
        for key in apps.keys { var level = apps[key]!; level.boost = level.boost.isFinite ? min(max(level.boost, 0), cap) : 0; apps[key] = level }
    }
    var needsMaster: Bool { boost > 0 || balance != 0 || mono || loudness || plugins.contains { !$0.bypass } }
}
struct SourcePlan: Equatable {
    var key: String
    var processes: [UInt32]
    var exclusive: Bool
}
enum RoutingPlan {
    static func make(profile: DeviceProfile, apps: [AudioApp], ownProcesses: [UInt32]) -> [SourcePlan] {
        let solo = profile.apps.values.contains { $0.solo }
        let selected = apps.filter {
            let level = profile.apps[$0.id] ?? AppLevel()
            return level.boost > 0 || level.muted || level.solo
        }
        // UI discovery order and unrelated processes do not define the audio route.
        // Solo's residual tap already silences every unclaimed process, including
        // new background apps, without creating another tap for each one.
        var result = selected.sorted { $0.id < $1.id }.map { SourcePlan(key: $0.id, processes: Array(Set($0.processes)).sorted(), exclusive: false) }
        if profile.needsMaster || solo {
            result.append(SourcePlan(key: "__remaining__", processes: Array(Set(ownProcesses + selected.flatMap(\.processes))).sorted(), exclusive: true))
        }
        return result
    }
}
/// Only properties that change the running audio route. UI names, activity,
/// latency reporting and other connected devices must not restart plugins.
struct AudioRouteIdentity: Equatable {
    let deviceID: UInt32?
    let deviceUID: String?
    let sampleRate: Double?
    let channels: Int?
    let bufferFrames: UInt32?
    let sources: [SourcePlan]
    init(device: OutputDevice?, sources: [SourcePlan]) {
        deviceID = device?.id; deviceUID = device?.uid; sampleRate = device?.sampleRate
        channels = device?.channels; bufferFrames = device?.bufferFrames; self.sources = sources
    }
}

final class ProfileStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [String: DeviceProfile] {
        guard let data = defaults.data(forKey: "deviceProfiles"), let value = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) else { return [:] }
        return value
    }
    func save(_ profiles: [String: DeviceProfile]) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "deviceProfiles") }
    }
}
