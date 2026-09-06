import AppKit
import SwiftUI
import Metal
import AVFoundation

@MainActor
enum Diagnostics {
    static var active: Bool { CommandLine.arguments.contains("--diagnostics") || CommandLine.arguments.contains("--snapshot") }
    static func run() {
        if CommandLine.arguments.contains("--diagnostics") {
            let devices = OutputDevice.discover()
            let data: [String: Any] = [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "outputs": devices.map { ["name": $0.name, "sampleRate": $0.sampleRate, "channels": $0.channels, "bluetooth": $0.isBluetooth, "callMode": $0.isCallMode] as [String: Any] },
                "audioAppCount": AppDiscovery.discover().count,
                "audioUnitCount": PluginHost.discover().count,
                "metalAvailable": MTLCreateSystemDefaultDevice() != nil,
                "bundleID": Bundle.main.bundleIdentifier ?? "unbundled",
                "captureRequested": false
            ]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted,.sortedKeys]), let text = String(data: json, encoding: .utf8) { print(text) }
            NSApp.terminate(nil)
        } else {
            let model = AppModel()
            model.permissionGranted = true; model.bypassed = false
            model.devices = [.init(id: 1, uid: "preview", name: "Studio headphones", sampleRate: 48000, channels: 2, transport: kAudioDeviceTransportTypeBluetooth, latencyFrames: 7680, bufferFrames: 128)]
            model.selectedUID = "preview"; model.profile = DeviceProfile(name: "Studio headphones", boost: 6)
            model.apps = [.init(id: "browser", name: "Safari", processes: [], running: true, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")), .init(id: "music", name: "Music", processes: [], running: true, bundleURL: URL(fileURLWithPath: "/System/Applications/Music.app")), .init(id: "meeting", name: "FaceTime", processes: [], running: true, bundleURL: URL(fileURLWithPath: "/System/Applications/FaceTime.app"))]
            model.profile.apps = ["browser": .init(boost: 8), "music": .init(boost: 0), "meeting": .init(boost: 3)]
            model.reduction = 2.4
            let view = NSHostingView(rootView: MenuPanel(model: model).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.isReleasedWhenClosed = false
            view.frame.size = view.fittingSize; window.setContentSize(view.fittingSize); window.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("Snapshot failed"); exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let index = CommandLine.arguments.firstIndex(of: "--snapshot")!
                let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "/tmp/FoFoBooster.png"
                do { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); print("Snapshot: \(path)") }
                catch { print(error); exit(1) }
                window.close(); NSApp.terminate(nil)
            }
        }
    }
}
import CoreAudio
