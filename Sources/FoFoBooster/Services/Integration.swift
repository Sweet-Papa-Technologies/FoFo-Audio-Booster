import SwiftUI
import ServiceManagement
import AppIntents
#if canImport(Sparkle)
import Sparkle
#endif

enum LoginService {
    @MainActor static func set(_ enabled: Bool, model: AppModel) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { model.error = "Could not change launch at login: \(error.localizedDescription)" }
    }
}
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil }
    func start() {
        #if canImport(Sparkle)
        if configured { controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) }
        #endif
    }
    func check() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }
    func automatic(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "SUEnableAutomaticChecks")
        #if canImport(Sparkle)
        controller?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }
}
struct SetBoostIntent: AppIntent {
    static var title: LocalizedStringResource = "Set FoFoBooster Level"
    static var description = IntentDescription("Set the master boost on the current output device.")
    static var openAppWhenRun = true
    @Parameter(title: "Boost in decibels", default: 6) var decibels: Double
    @MainActor func perform() async throws -> some IntentResult {
        guard AppModel.shared.permissionGranted else { throw IntentFailure.permission }
        AppModel.shared.setBoost(decibels); return .result()
    }
}
struct ToggleBypassIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle FoFoBooster Bypass"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppModel.shared.toggleBypass(); return .result() }
}
struct SwitchProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch FoFoBooster Output"
    static var openAppWhenRun = true
    @Parameter(title: "Device name or UID") var device: String
    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard let output = model.devices.first(where: { $0.uid == device || $0.name == device }) else { throw IntentFailure.device }
        model.selectDevice(output.uid); return .result()
    }
}
enum IntentFailure: LocalizedError {
    case permission, device
    var errorDescription: String? { switch self { case .permission: "Complete audio access setup in FoFoBooster first."; case .device: "That output device is not connected." } }
}
struct BoosterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetBoostIntent(), phrases: ["Set my boost in \(.applicationName)"], shortTitle: "Set boost", systemImageName: "speaker.wave.3")
        AppShortcut(intent: ToggleBypassIntent(), phrases: ["Toggle \(.applicationName)"], shortTitle: "Toggle bypass", systemImageName: "power")
        AppShortcut(intent: SwitchProfileIntent(), phrases: ["Switch output in \(.applicationName)"], shortTitle: "Switch output", systemImageName: "headphones")
    }
}
