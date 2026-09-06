import Foundation
import Metal

/// Offscreen production-shader benchmark. No screen capture or audio permission.
@MainActor
enum VisualizerValidation {
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let url = Resources.bundle.url(forResource: "Visualizer", withExtension: "metal") else { throw AudioFailure(operation: "Metal unavailable") }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        func pipeline(_ fragment: String, vertex: String = "fullscreenVertex", format: MTLPixelFormat = .bgra8Unorm) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = library.makeFunction(name: vertex); d.fragmentFunction = library.makeFunction(name: fragment); d.colorAttachments[0].pixelFormat = format
            if vertex == "particleVertex" { d.colorAttachments[0].isBlendingEnabled = true; d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let regular = try pipeline("visualizerFragment"), particles = try pipeline("particleFragment", vertex: "particleVertex"), feedback = try pipeline("tideHistory", format: .r16Float), display = try pipeline("tideDisplay")
        func texture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false); d.usage = [.renderTarget,.shaderRead]; d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw AudioFailure(operation: "Metal texture allocation") }; return t
        }
        let output = try texture(width: 3840, height: 2160, format: .bgra8Unorm)
        let history = try (0..<2).map { _ in try texture(width: 1920, height: 1080, format: .r16Float) }
        var bins = (0..<64).map { Float(0.2 + 0.3 * sin(Double($0)*0.2)) }, wave = [Float](repeating: 0, count: 64)
        var allTimes: [Double] = []
        for mode in 0..<5 {
            for light in 0...1 {
                var times: [Double] = []
                for frame in 0..<90 {
                    for i in 0..<64 { wave[i] = Float(sin(Double(i)*0.3 + Double(frame)*0.08))*0.5 }
                    var u: [Float] = [3840,2160,Float(frame)/60,Float(mode),Float(light),1,0.03,0.5,0.9,0.4,0.1,Float(frame)/60,1/60,frame > 0 ? 1 : 0]
                    guard let command = queue.makeCommandBuffer() else { throw AudioFailure(operation: "Metal command allocation") }
                    func encode(target: MTLTexture, state: MTLRenderPipelineState, sampled: MTLTexture? = nil, particle: Bool = false) throws {
                        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColor(red: light == 0 ? 0.022 : 0.93, green: light == 0 ? 0.027 : 0.94, blue: light == 0 ? 0.035 : 0.96, alpha: 1)
                        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw AudioFailure(operation: "Metal encoder") }
                        encoder.setRenderPipelineState(state); encoder.setFragmentBytes(&u, length: u.count*4, index: 0); encoder.setFragmentBytes(&bins, length: bins.count*4, index: 1); encoder.setFragmentBytes(&wave, length: wave.count*4, index: 2); encoder.setFragmentBytes(&bins, length: bins.count*4, index: 3)
                        if let sampled { encoder.setFragmentTexture(sampled, index: 0) }
                        if particle { encoder.setVertexBytes(&u, length: u.count*4, index: 0); encoder.setVertexBytes(&bins, length: bins.count*4, index: 1) }
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: particle ? 6 : 3, instanceCount: particle ? 128 : 1); encoder.endEncoding()
                    }
                    if mode == 2 {
                        try encode(target: history[(frame+1)%2], state: feedback, sampled: history[frame%2])
                        try encode(target: output, state: display, sampled: history[(frame+1)%2])
                    } else { try encode(target: output, state: mode == 4 ? particles : regular, particle: mode == 4) }
                    command.commit(); command.waitUntilCompleted()
                    try AudioValidation.require(command.status == .completed, "Metal command failed")
                    if frame >= 30 { times.append((command.gpuEndTime-command.gpuStartTime)*1000) }
                }
                var pixels = [UInt8](repeating: 0, count: 3840*2160*4)
                output.getBytes(&pixels, bytesPerRow: 3840*4, from: MTLRegionMake2D(0,0,3840,2160), mipmapLevel: 0)
                let luminance = stride(from: 0, to: pixels.count, by: 400).map { Int(pixels[$0])+Int(pixels[$0+1])+Int(pixels[$0+2]) }
                try AudioValidation.require((luminance.max() ?? 0) > (luminance.min() ?? 0)+5, "Preset rendered a flat frame")
                times.sort(); allTimes += times
                AudioValidation.report(["event":"preset-passed", "preset":VisualPreset.allCases[mode].rawValue, "appearance":light == 0 ? "dark":"light", "resolution":"3840x2160", "gpuMeanMS":times.reduce(0,+)/Double(times.count), "gpuP95MS":times[Int(Double(times.count)*0.95)]])
            }
        }
        AudioValidation.report(["event":"passed", "mode":"visualizer", "device":device.name, "maxGPUFrameMS":allTimes.max() ?? 0, "scope":"offscreen production shaders, synthetic signal; excludes window compositor, FFT, and audio engine"])
    }
}
