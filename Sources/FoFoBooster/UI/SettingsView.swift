import SwiftUI
import ServiceManagement
import Carbon
struct BoosterSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            SoundSettings(model: model).tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            HotkeySettings(model: model).tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ProfileSettings(model: model).tabItem { Label("Profiles", systemImage: "headphones") }
        }.frame(width: 580, height: 500).tint(.fofo)
    }
}
private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var login = SMAppService.mainApp.status == .enabled
    @AppStorage("SUEnableAutomaticChecks") private var updates = true
    @State private var confirmUninstall = false
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $login).onChange(of: login) { _, value in LoginService.set(value, model: model) }
                if SMAppService.mainApp.status == .requiresApproval { Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() } }
                Toggle("Automatically check for updates", isOn: $updates).onChange(of: updates) { _, value in UpdateService.shared.automatic(value) }.disabled(!UpdateService.shared.configured)
                Button("Check for Updates…") { UpdateService.shared.check() }.disabled(!UpdateService.shared.configured)
                if !UpdateService.shared.configured { Text("Updates become available in signed releases.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("About") {
                LabeledContent("FoFoBooster", value: "0.1.1 · Sweet Papa Technologies")
                Text("Free. No accounts, analytics, or audio uploads.").foregroundStyle(.secondary)
                Link("Source code & support", destination: URL(string: "https://github.com/Sweet-Papa-Technologies/FoFo-Audio-Booster")!)
            }
            Section {
                Button("Uninstall FoFoBooster…", role: .destructive) { confirmUninstall = true }
                Text("Restores original audio, removes the login item and saved profiles, and moves the app to the Trash.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.formStyle(.grouped).confirmationDialog("Uninstall FoFoBooster and remove its settings?", isPresented: $confirmUninstall) { Button("Uninstall", role: .destructive) { model.uninstall() }; Button("Cancel", role: .cancel) {} }
    }
}
private struct SoundSettings: View {
    @ObservedObject var model: AppModel
    @State private var confirmAdvanced = false
    var body: some View {
        Form {
            Section("\(model.device?.name ?? "Current output")") {
                Toggle("Allow up to +24 dB boost", isOn: Binding(get: { model.advanced }, set: { if $0 { confirmAdvanced = true } else { model.setAdvanced(false) } }))
                Toggle("Match quiet content to a loudness target", isOn: Binding(get: { model.profile.loudness }, set: { value in model.change { $0.loudness = value } }))
                if model.profile.loudness {
                    Slider(value: Binding(get: { model.profile.target }, set: { value in model.change { $0.target = value } }), in: -24 ... -9, step: 1) { Text("Target: \(Int(model.profile.target)) LUFS") }
                    Text("Integrated: \(model.integratedLoudness > -90 ? String(format: "%.1f LUFS", model.integratedLoudness) : "Waiting for audio")").font(.caption).foregroundStyle(.secondary)
                    Text("3-second K-weighted loudness: \(model.loudness > -90 ? String(format: "%.1f LUFS", model.loudness) : "Waiting for audio")").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Mono audio", isOn: Binding(get: { model.profile.mono }, set: { value in model.change { $0.mono = value } }))
                Slider(value: Binding(get: { model.profile.balance }, set: { value in model.change { $0.balance = value } }), in: -1...1) { Text("Balance") }
                HStack { Text("Left"); Spacer(); Button("Center") { model.change { $0.balance = 0 } }; Spacer(); Text("Right") }.font(.caption)
            }
            Section("Peak protection") {
                Slider(value: Binding(get: { model.profile.ceiling }, set: { value in model.change { $0.ceiling = value } }), in: -6 ... -0.3, step: 0.1) { Text("Ceiling: \(model.profile.ceiling, specifier: "%.1f") dBTP") }
                Text("1.5 ms lookahead · 4× peak detection · Always on while processing").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Reported path latency", value: String(format: "%.1f ms", model.totalLatency))
            }
            Section("Visualizer sync") {
                Slider(value: Binding(get: { model.profile.visualizerNudge }, set: { value in model.change { $0.visualizerNudge = value } }), in: -250...500, step: 5) { Text("Nudge: \(Int(model.profile.visualizerNudge)) ms") }
                Text("Added to the device’s reported latency. Adjust if Bluetooth visuals arrive early or late.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).confirmationDialog("Higher gain can produce very loud sound. Start low and adjust carefully.", isPresented: $confirmAdvanced) { Button("I understand — allow +24 dB") { model.setAdvanced(true) }; Button("Cancel", role: .cancel) {} }
    }
}
private struct ProfileSettings: View {
    @ObservedObject var model: AppModel
    @State private var deleting: String?
    var body: some View {
        Form {
            Section("Saved output devices") {
                if model.profiles.isEmpty { Text("Your first profile is saved when you adjust a level.").foregroundStyle(.secondary) }
                ForEach(model.profiles.keys.sorted(), id: \.self) { uid in
                    HStack { VStack(alignment: .leading) { Text(model.profiles[uid]?.name ?? uid); Text("+\(model.profiles[uid]?.boost ?? 0, specifier: "%.1f") dB · \(model.profiles[uid]?.plugins.count ?? 0) effects").font(.caption).foregroundStyle(.secondary) }; Spacer(); if uid == model.selectedUID { Text("Current").font(.caption).foregroundStyle(Color.fofo) }; Button("Reset") { deleting = uid } }
                }
            }
            Text("Boost, app levels, balance, mono, limiter, and effects follow the output device automatically.").font(.callout).foregroundStyle(.secondary)
        }.formStyle(.grouped).confirmationDialog("Reset this output’s saved profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("Reset profile", role: .destructive) { if let deleting { model.deleteProfile(deleting) }; deleting = nil }; Button("Cancel", role: .cancel) { deleting = nil } }
    }
}
private struct HotkeySettings: View {
    @ObservedObject var model: AppModel
    @State private var bindings = HotkeyBinding.defaults
    @State private var recording: UInt32?
    @State private var monitor: Any?
    var body: some View {
        Form {
            Section("Global keyboard shortcuts") {
                ForEach(bindings) { binding in HStack { Text(binding.name); Spacer(); Button(recording == binding.id ? "Press shortcut…" : binding.display) { record(binding.id) }.frame(minWidth: 120) } }
                Button("Restore defaults") { bindings = HotkeyBinding.defaults; model.hotkeys?.bindings = bindings }
            }
            Text("Click a shortcut and press a key with Control, Option, or Command. Escape cancels. Panic bypass always restores the original audio.").font(.callout).foregroundStyle(.secondary)
            if let error = model.hotkeyError { Text(error).foregroundStyle(.orange) }
        }.formStyle(.grouped).onAppear { bindings = model.hotkeys?.bindings ?? HotkeyBinding.defaults }.onDisappear { stop() }
    }
    func record(_ id: UInt32) {
        stop(); recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let flags = event.modifierFlags
            guard !flags.intersection([.command, .option, .control]).isEmpty, let index = bindings.firstIndex(where: { $0.id == id }) else { return nil }
            var mods: UInt32 = 0
            if flags.contains(.command) { mods |= UInt32(cmdKey) }; if flags.contains(.option) { mods |= UInt32(optionKey) }; if flags.contains(.control) { mods |= UInt32(controlKey) }; if flags.contains(.shift) { mods |= UInt32(shiftKey) }
            bindings[index].key = UInt32(event.keyCode); bindings[index].modifiers = mods; model.hotkeys?.bindings = bindings; stop(); return nil
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = nil }
}
