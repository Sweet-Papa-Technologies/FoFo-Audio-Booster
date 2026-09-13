import SwiftUI
import MetalKit

enum VisualPreset: String, CaseIterable, Identifiable {
    case ember = "Ember", halo = "Halo", tide = "Tide", grid = "Grid", drift = "Drift"
    var id: String { rawValue }
    var index: UInt32 { UInt32(Self.allCases.firstIndex(of: self) ?? 0) }
    var subtitle: String {
        switch self { case .ember: "A little warmth in every frequency."; case .halo: "Let the room revolve around the music."; case .tide: "Every sound leaves a trace."; case .grid: "An old-school pulse. A new favorite."; case .drift: "Get a little lost in the sound." }
    }
}
struct VisualizerView: View {
    @ObservedObject var model: AppModel
    @AppStorage("visualPreset") private var preset = VisualPreset.ember.rawValue
    @AppStorage("visualLight") private var light = false
    @State private var controlsVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var selected: VisualPreset { VisualPreset(rawValue: preset) ?? .ember }
    var body: some View {
        ZStack(alignment: .bottom) {
            if reduceMotion {
                VStack(spacing: 20) { Image(systemName: "waveform").font(.system(size: 80, weight: .ultraLight)); Text("\(model.device?.name ?? "Your audio")").font(.title2); Text("Reduce Motion is on").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(light ? Color.white : Color.black)
            } else {
                MetalSurface(model: model, preset: selected, light: light).onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
            }
            if controlsVisible { VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(selected.rawValue.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3); Text(selected.subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Spacer()
                    Button { controlsVisible = false } label: { Image(systemName: "eye.slash") }.help("Hide visualizer controls").accessibilityLabel("Hide visualizer controls")
                    Button { light.toggle() } label: { Image(systemName: light ? "moon" : "sun.max") }.help("Switch light or dark appearance")
                    Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen").keyboardShortcut("f", modifiers: [.control, .command])
                }
                Picker("Visualizer preset", selection: $preset) { ForEach(VisualPreset.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
                if model.bypassed { Text("Boost is bypassed. Resume it to visualize system audio.").font(.caption).foregroundStyle(.secondary) }
            }.padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(24).frame(maxWidth: 640)
            } else {
                HStack { Spacer(); Button { controlsVisible = true } label: { Label("Show controls", systemImage: "slider.horizontal.3") }.buttonStyle(.bordered).padding(16) }
            }
        }.preferredColorScheme(light ? .light : .dark).frame(minWidth: 560, minHeight: 380)
            .onAppear { model.setVisualizer(!reduceMotion) }
            .onDisappear { model.setVisualizer(false) }
            .onChange(of: reduceMotion) { _, value in model.setVisualizer(!value) }
    }
}
private struct MetalSurface: NSViewRepresentable {
    var model: AppModel
    var preset: VisualPreset
    var light: Bool
    func makeCoordinator() -> Renderer { Renderer(model: model) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true; view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator; context.coordinator.configure(view)
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.preset = preset; context.coordinator.light = light }
    static func dismantleNSView(_ view: MTKView, coordinator: Renderer) { view.isPaused = true; view.delegate = nil }
    final class Renderer: NSObject, MTKViewDelegate {
        var model: AppModel
        var preset = VisualPreset.ember
        var light = false
        var queue: MTLCommandQueue?
        var pipeline: MTLRenderPipelineState?
        var particlePipeline: MTLRenderPipelineState?
        var tidePipeline: MTLRenderPipelineState?
        var tideDisplayPipeline: MTLRenderPipelineState?
        var history: [MTLTexture] = []
        var historyIndex = 0
        var historyValid = false
        var lastFrame = ProcessInfo.processInfo.systemUptime
        var driftClock: Float = 0
        var started = ProcessInfo.processInfo.systemUptime
        var slowFrames = 0
        var quality: Float = 1
        private let inFlight = DispatchSemaphore(value: 2)
        init(model: AppModel) { self.model = model }
        func configure(_ view: MTKView) {
            guard let device = view.device else { return }
            queue = device.makeCommandQueue()
            do {
                let url = Resources.bundle.url(forResource: "Visualizer", withExtension: "metal")!
                let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "visualizerFragment")
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                descriptor.fragmentFunction = library.makeFunction(name: "tideDisplay")
                tideDisplayPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                descriptor.fragmentFunction = library.makeFunction(name: "tideHistory")
                descriptor.colorAttachments[0].pixelFormat = .r16Float
                tidePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                particlePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch { Task { @MainActor in model.error = "The visualizer could not start: \(error.localizedDescription)" } }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
        func draw(in view: MTKView) {
            // Drop a visual frame instead of queuing work behind a busy GPU.
            // Never make the UI/audio-control thread wait for rendering.
            guard inFlight.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer { if !submitted { inFlight.signal() } }
            MainActor.assumeIsolated { model.updateSpectrum() }
            let time = ProcessInfo.processInfo.systemUptime
            let delta = Float(min(time-lastFrame, 0.1))
            driftClock += delta * (0.7 + model.analyzer.signal.level * 0.55 + model.analyzer.flux * 2.5); lastFrame = time
            view.clearColor = light ? MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1) : MTLClearColor(red: 0.022, green: 0.027, blue: 0.035, alpha: 1)
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let pipeline, let command = queue?.makeCommandBuffer() else { return }
            let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemOrange
            var uniforms: [Float] = [Float(view.drawableSize.width), Float(view.drawableSize.height), Float(ProcessInfo.processInfo.systemUptime-started), Float(preset.index), light ? 1 : 0, quality, model.analyzer.flux, model.analyzer.centroid, Float(accent.redComponent), Float(accent.greenComponent), Float(accent.blueComponent), driftClock, delta, historyValid ? 1 : 0, model.analyzer.signal.level, model.analyzer.signal.bass, model.analyzer.signal.mids, model.analyzer.signal.treble, model.analyzer.signal.onset]
            var bins = model.analyzer.bins, wave = model.analyzer.waveform, peaks = model.analyzer.peaks
            var tideTexture: MTLTexture?
            if preset == .tide, let device = view.device, let tidePipeline {
                let width = max(1, Int(view.drawableSize.width) / 2), height = max(1, Int(view.drawableSize.height) / 2)
                if history.first?.width != width || history.first?.height != height {
                    history.removeAll(); historyValid = false; historyIndex = 0
                    let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
                    texture.usage = [.shaderRead, .renderTarget]; texture.storageMode = .private
                    history = (0..<2).compactMap { _ in device.makeTexture(descriptor: texture) }
                }
                if history.count == 2 {
                    uniforms[13] = historyValid ? 1 : 0
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = history[1-historyIndex]
                    pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
                    if let feedback = command.makeRenderCommandEncoder(descriptor: pass) {
                        feedback.setRenderPipelineState(tidePipeline)
                        feedback.setFragmentBytes(&uniforms, length: uniforms.count * 4, index: 0)
                        feedback.setFragmentBytes(&wave, length: wave.count * 4, index: 2)
                        feedback.setFragmentTexture(history[historyIndex], index: 0)
                        feedback.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        feedback.endEncoding()
                        historyIndex = 1-historyIndex; historyValid = true; tideTexture = history[historyIndex]
                    }
                }
            } else { history.removeAll(); historyValid = false }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(tideTexture != nil ? tideDisplayPipeline ?? pipeline : pipeline)
            if let tideTexture { encoder.setFragmentTexture(tideTexture, index: 0) }
            encoder.setFragmentBytes(&uniforms, length: uniforms.count * 4, index: 0)
            encoder.setFragmentBytes(&bins, length: bins.count * 4, index: 1)
            encoder.setFragmentBytes(&wave, length: wave.count * 4, index: 2)
            encoder.setFragmentBytes(&peaks, length: peaks.count * 4, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if (preset == .drift || preset == .ember || preset == .halo), let particlePipeline {
                encoder.setRenderPipelineState(particlePipeline)
                encoder.setVertexBytes(&uniforms, length: uniforms.count * 4, index: 0)
                encoder.setVertexBytes(&bins, length: bins.count * 4, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: preset == .drift ? (quality > 0.75 ? 512 : 256) : 128)
            }
            encoder.endEncoding(); command.present(drawable)
            let framePermit = inFlight
            command.addCompletedHandler { [weak self] buffer in
                framePermit.signal()
                let duration = buffer.gpuEndTime - buffer.gpuStartTime
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.slowFrames = duration > 0.012 ? self.slowFrames + 1 : max(0, self.slowFrames - 1)
                    if self.slowFrames > 20 { self.quality = 0.5; view.preferredFramesPerSecond = 30 }
                }
            }
            submitted = true; command.commit()
        }
    }
}
