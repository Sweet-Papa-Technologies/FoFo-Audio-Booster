import SwiftUI
import WidgetKit
import AppIntents
struct BoosterEntry: TimelineEntry {
    var date: Date
    var boost: Double
    var enabled: Bool
    var device: String
}
struct BoosterProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoosterEntry { .init(date: .now, boost: 6, enabled: true, device: "Headphones") }
    func getSnapshot(in context: Context, completion: @escaping (BoosterEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BoosterEntry>) -> Void) { completion(Timeline(entries: [read()], policy: .after(.now.addingTimeInterval(900)))) }
    func read() -> BoosterEntry {
        let defaults = UserDefaults(suiteName: "6Y5SZ2K5XY.com.sweetpapatechnologies.FoFoBooster")
        return .init(date: .now, boost: defaults?.double(forKey: "boost") ?? 0, enabled: defaults?.bool(forKey: "enabled") ?? false, device: defaults?.string(forKey: "device") ?? "Open FoFoBooster")
    }
}
struct BoosterWidgetView: View {
    var entry: BoosterEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("FoFoBooster", systemImage: "waveform.path").font(.caption.weight(.semibold)); Spacer(); Button(intent: WidgetToggleIntent()) { Image(systemName: "power") }.tint(entry.enabled ? .orange : .gray).buttonStyle(.bordered) }
            HStack(alignment: .firstTextBaseline) { Text("+\(entry.boost, specifier: "%.0f")").font(.system(size: 40, weight: .medium, design: .rounded)); Text("dB").foregroundStyle(.secondary) }
            Text(entry.device).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Text(entry.enabled ? "Boost is on" : "Bypassed").font(.caption2).foregroundStyle(entry.enabled ? .orange : .secondary)
        }.containerBackground(.quaternary, for: .widget).widgetURL(URL(string: "fofobooster://open"))
    }
}
@main
struct FoFoBoosterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FoFoBoosterWidget", provider: BoosterProvider()) { BoosterWidgetView(entry: $0) }
            .configurationDisplayName("FoFoBooster").description("Your output’s boost level, one tap away.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
