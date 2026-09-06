import Foundation
struct PluginWorkerConfiguration: Codable {
    var bridgeName: String
    var sampleRate: Double
    var slots: [PluginSlot]
}
struct PluginWorkerMessage: Codable {
    var kind: String
    var request: String?
    var slot: Int?
    var message: String?
    var slots: [PluginSlot]?
    var latency: Double?
}
