import Foundation
/// Monotonic time makes sleep, clock changes, and device transitions explicit.
struct ListeningMonitor {
    private var since: TimeInterval?
    private var device: String?
    private var dismissed = false
    mutating func update(time: TimeInterval, deviceUID: String, headphones: Bool, processing: Bool, activeBoost: Double) -> Bool {
        guard !dismissed else { return false }
        guard headphones, processing, activeBoost > 9 else { since = nil; device = nil; return false }
        if device != deviceUID { since = time; device = deviceUID }
        if since == nil { since = time }
        return time - (since ?? time) >= 1800
    }
    mutating func resetContinuity() { since = nil; device = nil }
    mutating func dismiss() { dismissed = true; resetContinuity() }
}
