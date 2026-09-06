import SwiftUI
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    @State private var login = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: step == 0 ? "waveform.path" : step == 1 ? "lock.shield" : "checkmark.seal")
                .font(.system(size: 66, weight: .ultraLight)).foregroundStyle(Color.fofo).frame(height: 100)
            VStack(spacing: 12) {
                Text(step == 0 ? "Quiet audio. Meet your match." : step == 1 ? "One permission. Your control." : "Make yourself comfortable.").font(.system(size: 27, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                Text(step == 0 ? "Give a quiet video, a favorite song, or your headphones a little more room. A built-in limiter keeps every boost in check." : step == 1 ? "FoFoBooster needs system audio access to process sound from your apps. Audio stays on your Mac. Nothing is recorded or uploaded." : "You’ll find FoFoBooster in your menu bar. Your levels are remembered for each output device. Press ⌥⇧B any time to restore original audio.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }.frame(maxWidth: 380)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            if step == 1 {
                if model.working { ProgressView().controlSize(.small) }
                Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!) }.buttonStyle(.link)
            }
            if step == 2 { Toggle("Open FoFoBooster when I log in", isOn: $login).toggleStyle(.checkbox) }
            Spacer()
            HStack(spacing: 6) { ForEach(0..<3) { index in Capsule().fill(index == step ? Color.fofo : Color.secondary.opacity(0.2)).frame(width: index == step ? 22 : 6, height: 6) } }
            Button(step == 0 ? "Let’s get started" : step == 1 ? "Allow system audio" : "Sounds good") {
                if step == 0 { step = model.permissionGranted ? 2 : 1 }
                else if step == 1 { Task { await model.requestPermission(); if model.permissionGranted { step = 2 } } }
                else { if login { LoginService.set(true, model: model) }; dismiss() }
            }.buttonStyle(.borderedProminent).tint(.fofo).controlSize(.large).disabled(model.working)
            Text("FREE FOREVER  ·  MADE BY SWEET PAPA TECHNOLOGIES").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.tertiary)
        }.padding(36).frame(width: 460, height: 540)
    }
}
