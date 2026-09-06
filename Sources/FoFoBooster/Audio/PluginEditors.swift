import AVFoundation
import AppKit
import SwiftUI
struct GenericPluginView: View {
    let unit: AUAudioUnit
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text(unit.audioUnitName ?? "Audio Unit").font(.title2.bold())
            if let parameters = unit.parameterTree?.allParameters, !parameters.isEmpty {
                ForEach(parameters, id: \.address) { ParameterRow(parameter: $0, unit: unit) }
            } else { Text("This effect has no editable parameters.").foregroundStyle(.secondary) }
        }.padding(24) }.frame(minWidth: 420, minHeight: 300)
    }
}
private struct ParameterRow: View {
    let parameter: AUParameter
    let unit: AUAudioUnit
    @State private var value: Float = 0
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(parameter.displayName); Spacer(); Text(parameter.string(fromValue: nil)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.001)) { Text(parameter.displayName) }
                .onChange(of: value) { _, new in unit.scheduleParameterBlock(AUEventSampleTimeImmediate, AUAudioFrameCount(unit.outputBusses[0].format.sampleRate * 0.03), parameter.address, new) }
        }.onAppear { value = parameter.value }
    }
}
