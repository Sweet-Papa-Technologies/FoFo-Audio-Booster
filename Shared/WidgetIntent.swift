import AppIntents
import Foundation
struct WidgetToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle boost"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        // The same intent is embedded in both targets. A single command nonce is
        // consumed by the main app, including on macOS 14 where OpenURLIntent is absent.
        UserDefaults(suiteName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")?.set(UUID().uuidString, forKey: "pendingToggle")
        return .result()
    }
}
