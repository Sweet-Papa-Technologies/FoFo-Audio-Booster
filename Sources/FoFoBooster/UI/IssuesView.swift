import SwiftUI
struct IssuesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("A clearer connection", systemImage: "wrench.and.screwdriver").font(.title2.bold())
            Text("A boost helps quiet content. These checks help with the connection itself.").foregroundStyle(.secondary)
            PanelGroup { VStack(alignment: .leading, spacing: 12) {
                Label(model.device?.isCallMode == true ? "Your headphones are in call mode" : "Bluetooth profile looks good", systemImage: model.device?.isCallMode == true ? "exclamationmark.triangle" : "checkmark.circle").font(.headline)
                Text("Using your headset’s microphone can switch playback to a low-bandwidth call profile. Switch to your Mac’s microphone to let stereo audio return.").font(.callout).foregroundStyle(.secondary)
                if model.device?.isCallMode == true { Button("Switch to built-in microphone") { model.fixCallMode() } }
                if model.undoInput != nil { Button("Undo microphone change") { model.undoCallFix() } }
            } }
            PanelGroup { VStack(alignment: .leading, spacing: 12) {
                Label("Sample rate", systemImage: "waveform").font(.headline)
                Text("Output: \(Int(model.device?.sampleRate ?? 0)) Hz. Choose the rate of your source if it is known; macOS normally converts rates automatically.").font(.callout).foregroundStyle(.secondary)
                Picker("Known source rate", selection: $model.sourceRate) { Text("Unknown / automatic").tag(0.0); Text("44,100 Hz").tag(44100.0); Text("48,000 Hz").tag(48000.0); Text("96,000 Hz").tag(96000.0) }
                if let rate = model.detectedSourceRate { Text("Captured stream: \(Int(rate)) Hz").font(.caption).foregroundStyle(.secondary) }
                if model.rateMismatch { Button("Set output to \(Int(model.effectiveSourceRate)) Hz") { model.fixSampleRate() } }
            } }
            Text("Still quiet at maximum volume? Some headphones limit their own output. Digital boost can help quiet content, but it cannot override the headset’s firmware.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(28).frame(width: 480).tint(.fofo)
    }
}
