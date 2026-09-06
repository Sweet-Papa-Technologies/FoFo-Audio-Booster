import SwiftUI

@main
enum FoFoEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--plugin-worker") { PluginWorker.run() }
        else if CommandLine.arguments.contains("--validation-source") { AudioValidation.source() }
        else if AudioValidation.active { AudioValidation.run() }
        else { FoFoBoosterApp.main() }
    }
}

struct FoFoBoosterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra { MenuPanel(model: model) } label: {
            MenuStatusLabel(model: model)
        }.menuBarExtraStyle(.window)
        Window("Welcome to FoFoBooster", id: "onboarding") { OnboardingView(model: model) }.windowResizability(.contentSize)
        Window("FoFoBooster · Visualizer", id: "visualizer") { VisualizerView(model: model) }.defaultSize(width: 960, height: 640)
        Window("FoFoBooster · Plugins", id: "plugins") { PluginsView(model: model) }.windowResizability(.contentSize)
        Window("FoFoBooster · Fix issues", id: "issues") { IssuesView(model: model) }.windowResizability(.contentSize)
        Settings { BoosterSettings(model: model) }
        Window("FoFoBooster", id: "launcher") { LaunchRouter(model: model) }.windowResizability(.contentSize)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Diagnostics.active { Diagnostics.run(); return }
        AppModel.shared.start(); UpdateService.shared.start()
        if !AppModel.shared.permissionGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { if !Diagnostics.active { AppModel.shared.shutdown() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "fofobooster" {
            let model = AppModel.shared
            if url.host == "toggle" { model.toggleBypass() }
            if url.host == "boost", let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "db" })?.value.flatMap(Double.init) { model.setBoost(value) }
        }
    }
}
private struct LaunchRouter: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Text("FoFoBooster is in your menu bar.").padding(24)
            .onAppear { if !model.permissionGranted { openWindow(id: "onboarding") }; dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: .showVisualizer)) { _ in openWindow(id: "visualizer"); NSApp.activate(ignoringOtherApps: true) }
    }
}
// MenuBarExtra owns the status item. A local monitor intercepts just its own
// window, preserving the system's normal click handling for every other item.
private struct StatusItemEvents: NSViewRepresentable {
    var model: AppModel
    func makeNSView(context: Context) -> EventView { EventView(model: model) }
    func updateNSView(_ view: EventView, context: Context) { }
    final class EventView: NSView {
        weak var model: AppModel?
        var monitor: Any?
        init(model: AppModel) {
            self.model = model; super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, let model = self.model else { return event }
                if event.type == .leftMouseDown, event.modifierFlags.contains(.option) { model.toggleBypass(); return nil }
                if event.type == .scrollWheel, abs(event.scrollingDeltaY) > 0 { model.setBoost(model.profile.boost + (event.scrollingDeltaY > 0 ? 0.5 : -0.5)); return nil }
                return event
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct MenuStatusLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: model.stateSymbol).accessibilityLabel("FoFoBooster: \(model.stateName)")
            .background(StatusItemEvents(model: model))
            .onReceive(NotificationCenter.default.publisher(for: .showVisualizer)) { _ in openWindow(id: "visualizer"); NSApp.activate(ignoringOtherApps: true) }
            .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
    }
}
extension Notification.Name { static let showOnboarding = Notification.Name("FoFoShowOnboarding") }
