import SwiftUI
import AudioToolbox
struct PluginsView: View {
    @ObservedObject var model: AppModel
    @State private var available: [AvailablePlugin] = []
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Shape your sound").font(.title2.bold()); Text("\(model.device?.name ?? "Output") · \(model.profile.plugins.count) of 8 effects").foregroundStyle(.secondary) }; Spacer(); Image(systemName: "slider.horizontal.3").font(.title).foregroundStyle(Color.fofo) }
            HStack(spacing: 7) { chip("Gain"); Image(systemName: "arrow.right"); chip("Your effects"); Image(systemName: "arrow.right"); chip("Peak protection") }.font(.caption)
            if model.profile.plugins.isEmpty {
                VStack(spacing: 10) { Image(systemName: "dial.medium").font(.system(size: 36, weight: .light)).foregroundStyle(Color.fofo); Text("A fresh canvas for your ears").font(.headline); Text("Start with an Apple effect, or add one of your installed Audio Units.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(24)
            } else {
                ForEach(Array(model.profile.plugins.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 10) {
                        Text(String(index + 1)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Toggle("Enable \(slot.name)", isOn: Binding(get: { !slot.bypass }, set: { enabled in model.change { $0.plugins[index].bypass = !enabled } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) { Text(slot.name).font(.callout).lineLimit(1); if model.pluginHost?.isolatedSlots.contains(slot.id) == true { Text("Isolated chain · +1 shared buffer").font(.caption2).foregroundStyle(.secondary) } }; Spacer()
                        Button { model.pluginHost?.showEditor(at: index) } label: { Image(systemName: "slider.horizontal.3") }.help("Edit effect").disabled(model.pluginHost == nil || model.working)
                        Button { model.savePluginState(); model.change { $0.plugins.swapAt(index, index-1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move effect earlier")
                        Button { model.savePluginState(); model.change { $0.plugins.remove(at: index) } } label: { Image(systemName: "trash") }.help("Remove effect")
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Menu("Add an Audio Unit…") {
                ForEach(available.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in Button(item.name) { model.savePluginState(); model.change { $0.plugins.append(item.slot) } } }
                if available.isEmpty { Text("No Audio Units found") }
            }.disabled(model.profile.plugins.count >= 8 || !model.permissionGranted)
            HStack {
                ForEach([("Equalizer", kAudioUnitSubType_NBandEQ), ("Dynamics", kAudioUnitSubType_DynamicsProcessor), ("Peak limiter", kAudioUnitSubType_PeakLimiter), ("Time / pitch", kAudioUnitSubType_NewTimePitch)], id: \.0) { title, subtype in
                    Button(title) {
                        if let item = available.first(where: { $0.description.componentSubType == subtype && $0.description.componentManufacturer == kAudioUnitManufacturer_Apple }) { var slot = item.slot; slot.bypass = subtype == kAudioUnitSubType_NewTimePitch; model.savePluginState(); model.change { $0.plugins.append(slot) } }
                    }.controlSize(.small).disabled(model.profile.plugins.count >= 8 || !model.permissionGranted)
                }
            }
            Text("Audio Units only · The safety limiter always follows your effects. All effects run in an isolated worker. A failed or stalled effect falls back to original audio before peak protection.").font(.caption).foregroundStyle(.secondary)
            if model.bypassed { Text("Resume boost to load and edit your effects.").font(.caption).foregroundStyle(Color.fofo) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(26).frame(width: 580).tint(.fofo).onAppear { available = PluginHost.discover() }.onDisappear { model.savePluginState() }
    }
    func chip(_ title: String) -> some View { Text(title).padding(.horizontal, 12).padding(.vertical, 7).background(.quaternary, in: Capsule()) }
}
