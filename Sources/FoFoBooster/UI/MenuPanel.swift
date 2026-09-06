import SwiftUI

extension Color {
    static let fofo = Color(red: 0.96, green: 0.48, blue: 0.25)
}
struct PanelGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var solid
    var body: some View { content.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(solid ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.quaternary.opacity(0.45)), in: RoundedRectangle(cornerRadius: 18)) }
}
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.fofo)
                    .frame(width: 42, height: 42).background(Color.fofo.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) { Text("FoFoBooster").font(.system(size: 17, weight: .bold, design: .rounded)); Text("A little louder. A lot clearer.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.toggleBypass() } label: { Image(systemName: "power").font(.system(size: 16, weight: .semibold)).foregroundStyle(model.bypassed ? Color.secondary : Color.fofo).frame(width: 34, height: 34).background(model.bypassed ? Color.secondary.opacity(0.08) : Color.fofo.opacity(0.12), in: Circle()) }.buttonStyle(.plain).help("Toggle bypass · \(model.bypassShortcut)").accessibilityLabel(model.bypassed ? "Resume boosting" : "Bypass all processing")
            }.padding(.horizontal, 4).padding(.top, 4)
            if !model.permissionGranted {
                PanelGroup { VStack(alignment: .leading, spacing: 12) { Label("Your sound, with more room.", systemImage: "sparkles").font(.headline); Text("Boost a quiet app without turning up everything else. Set up system audio access to get started.").font(.callout).foregroundStyle(.secondary); Button("Set up FoFoBooster") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.borderedProminent).tint(.fofo) } }
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).font(.caption).fixedSize(horizontal: false, vertical: true); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            if model.device?.isCallMode == true {
                Button { openWindow(id: "issues") } label: { Label("Your headphones are in call mode. Fix →", systemImage: "headphones").font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.buttonStyle(.plain).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            PanelGroup {
                HStack(spacing: 12) {
                    Image(systemName: model.device?.symbol ?? "speaker.wave.2").font(.system(size: 21)).foregroundStyle(Color.fofo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OUTPUT").font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(.secondary)
                        Picker("Output device", selection: Binding(get: { model.selectedUID }, set: { model.selectDevice($0) })) {
                            if model.devices.isEmpty { Text("No output device").tag("") }
                            ForEach(model.devices) { Text($0.name).tag($0.uid) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            PanelGroup {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Master boost").font(.headline)
                        Spacer()
                        Text("+\(model.profile.boost, specifier: "%.1f")").font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(model.bypassed ? Color.secondary : .fofo)
                        Text("dB").font(.callout).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { model.profile.boost }, set: { model.setBoost(($0 * 2).rounded() / 2) }), in: 0...model.cap) { Text("Master boost") }.labelsHidden().tint(.fofo).accessibilityValue("\(model.profile.boost, specifier: "%.1f") decibels").disabled(!model.permissionGranted)
                    HStack { Text("Original"); Spacer(); Text("+\(Int(model.cap)) dB") }.font(.system(size: 10)).foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.fofo)
                        Text("Peak protection").foregroundStyle(.secondary)
                        GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(.quaternary); Capsule().fill(Color.fofo.opacity(0.7)).frame(width: proxy.size.width * CGFloat(min(model.reduction / 18, 1))) } }.frame(height: 4)
                        Text("−\(model.reduction, specifier: "%.1f") dB").monospacedDigit().foregroundStyle(.secondary)
                    }.font(.system(size: 10)).accessibilityElement(children: .ignore).accessibilityLabel("Limiter gain reduction \(model.reduction, specifier: "%.1f") decibels")
                }
            }
            VStack(spacing: 0) {
                HStack { Text("NOW PLAYING").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary); Spacer(); Button(model.showAll ? "Active only" : "Show all") { model.showAll.toggle() }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.fofo) }.padding(.horizontal, 6).padding(.vertical, 12)
                if model.visibleApps.isEmpty {
                    VStack(spacing: 8) { Image(systemName: "music.note").font(.title2).foregroundStyle(.tertiary); Text("A little quiet in here").font(.callout.weight(.medium)); Text("Play something in an app to give it a boost.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    ScrollView { VStack(spacing: 14) { ForEach(model.visibleApps) { app in AppRow(model: model, app: app) } }.padding(14) }.frame(maxHeight: 250).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            if model.notice {
                VStack(alignment: .leading, spacing: 8) { Text("Give your ears a breather").font(.headline); Text("You’ve been using a higher boost for a while. A lower level or a short listening break can help protect your hearing.").font(.caption); HStack { Link("Safe listening", destination: URL(string: "https://www.who.int/health-topics/safe-listening")!); Spacer(); Button("Got it") { model.dismissNotice() } } }.font(.caption).padding(12).background(Color.fofo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 4) {
                action("Visualizer", symbol: "waveform.path") { openWindow(id: "visualizer") }
                action("Plugins", symbol: "slider.horizontal.3") { openWindow(id: "plugins") }
                action("Fix issues", symbol: model.issueCount > 0 ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver") { openWindow(id: "issues") }
                action("Settings", symbol: "gearshape") { openSettings() }
            }.padding(.vertical, 6)
            Divider()
            HStack(spacing: 5) {
                Circle().fill(model.bypassed ? Color.secondary : Color.fofo).frame(width: 5, height: 5)
                Text(model.stateName).font(.system(size: 10))
                Spacer()
                Button("Bypass · \(model.bypassShortcut)") { model.panic() }.buttonStyle(.plain).font(.system(size: 10)).help("Immediately restore unprocessed audio")
                Menu { Button("Quit FoFoBooster") { model.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q") } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
            }.foregroundStyle(.secondary).padding(.horizontal, 4)
        }.padding(16).frame(width: 390).tint(.fofo)
    }
    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button { run(); NSApp.activate(ignoringOtherApps: true) } label: { VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 18)); Text(title).font(.system(size: 10, weight: .medium)) }.frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
private struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AudioApp
    var level: AppLevel { model.profile.apps[app.id] ?? AppLevel() }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                if let url = app.bundleURL { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 27, height: 27) }
                else { Image(systemName: "app.fill").font(.title2).foregroundStyle(.secondary).frame(width: 27) }
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button { model.setApp(app.id) { $0.muted.toggle() } } label: { Image(systemName: level.muted ? "speaker.slash.fill" : "speaker.wave.2").frame(width: 22) }.foregroundStyle(level.muted ? Color.fofo : Color.secondary).help("Mute \(app.name)").accessibilityLabel("Mute \(app.name)").accessibilityValue(level.muted ? "On" : "Off")
                Button { model.setApp(app.id) { $0.solo.toggle() } } label: { Text("S").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).background(level.solo ? Color.fofo.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5)) }.foregroundStyle(level.solo ? Color.fofo : Color.secondary).help("Solo \(app.name)").accessibilityLabel("Solo \(app.name)").accessibilityValue(level.solo ? "On" : "Off")
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Slider(value: Binding(get: { level.boost }, set: { value in model.setApp(app.id) { $0.boost = (value * 2).rounded() / 2 } }), in: 0...model.cap) { Text("\(app.name) boost") }.labelsHidden().controlSize(.small).tint(.fofo).accessibilityValue("\(level.boost, specifier: "%.1f") decibels")
                Text("+\(level.boost, specifier: "%.1f") dB").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            }.padding(.leading, 36)
        }.disabled(!model.permissionGranted)
    }
}
