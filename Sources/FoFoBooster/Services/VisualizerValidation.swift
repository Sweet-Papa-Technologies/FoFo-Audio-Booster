import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Offscreen production-shader benchmark. No screen capture or audio permission.
@MainActor
enum VisualizerValidation {
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let url = Resources.bundle.url(forResource: "Visualizer", withExtension: "metal") else { throw AudioFailure(operation: "Metal unavailable") }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        func pipeline(_ fragment: String, vertex: String = "fullscreenVertex", format: MTLPixelFormat = .bgra8Unorm) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = library.makeFunction(name: vertex); d.fragmentFunction = library.makeFunction(name: fragment); d.colorAttachments[0].pixelFormat = format
            if vertex == "particleVertex" { d.colorAttachments[0].isBlendingEnabled = true; d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha; d.colorAttachments[0].sourceAlphaBlendFactor = .one; d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let regular = try pipeline("visualizerFragment"), particles = try pipeline("particleFragment", vertex: "particleVertex"), feedback = try pipeline("tideHistory", format: .r16Float), display = try pipeline("tideDisplay")
        func texture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false); d.usage = [.renderTarget,.shaderRead]; d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw AudioFailure(operation: "Metal texture allocation") }; return t
        }
        let output = try texture(width: 3840, height: 2160, format: .bgra8Unorm)
        let history = try (0..<2).map { _ in try texture(width: 1920, height: 1080, format: .r16Float) }
        var snapshotDirectory: URL?
        if let i = CommandLine.arguments.firstIndex(of: "--visualizer-snapshots"), CommandLine.arguments.indices.contains(i+1) {
            snapshotDirectory = URL(fileURLWithPath: CommandLine.arguments[i+1], isDirectory: true)
            try FileManager.default.createDirectory(at: snapshotDirectory!, withIntermediateDirectories: true)
        }
        var allTimes: [Double] = []
        for mode in 0..<5 {
            for light in 0...1 {
                var silentPixels: [UInt8] = []
                for audible in [false,true] {
                    var bins = [Float](repeating: 0,count:64), wave = [Float](repeating:0,count:SpectrumAnalyzer.waveCount)
                    var times: [Double] = []
                    for frame in 0..<90 {
                        let phase = Double(frame)/60
                        if audible {
                            for i in 0..<64 { bins[i] = Float(0.35 + 0.23*sin(Double(i)*0.24+phase*2) + 0.1*cos(Double(i)*0.7-phase)) }
                            for i in 0..<wave.count { wave[i] = Float(sin(Double(i)*0.1+phase*4)*0.46 + sin(Double(i)*0.037-phase)*0.19) }
                        }
                        var u: [Float] = [3840,2160,Float(phase+10),Float(mode),Float(light),1,audible ? 0.16:0,0.5,0.95,0.4,0.15,Float(phase+10),1/60,frame > 0 ? 1 : 0,audible ? 0.72:0,audible ? 0.6:0,audible ? 0.42:0,audible ? 0.3:0,audible ? 0.35:0]
                        guard let command = queue.makeCommandBuffer() else { throw AudioFailure(operation: "Metal command allocation") }
                        func encode(target: MTLTexture, state: MTLRenderPipelineState, sampled: MTLTexture? = nil, foreground: Bool = false) throws {
                            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw AudioFailure(operation: "Metal encoder") }
                            encoder.setRenderPipelineState(state); encoder.setFragmentBytes(&u, length: u.count*4, index: 0); encoder.setFragmentBytes(&bins, length: bins.count*4, index: 1); encoder.setFragmentBytes(&wave, length: wave.count*4, index: 2); encoder.setFragmentBytes(&bins, length: bins.count*4, index: 3)
                            if let sampled { encoder.setFragmentTexture(sampled, index: 0) }
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                            if foreground {
                                encoder.setRenderPipelineState(particles)
                                encoder.setVertexBytes(&u, length: u.count*4, index: 0); encoder.setVertexBytes(&bins, length: bins.count*4, index: 1)
                                encoder.drawPrimitives(type: .triangle,vertexStart:0,vertexCount:6,instanceCount:mode == 4 ? 512:128)
                            }
                            encoder.endEncoding()
                        }
                        if mode == 2 {
                            try encode(target: history[(frame+1)%2], state: feedback, sampled: history[frame%2])
                            try encode(target: output, state: display, sampled: history[(frame+1)%2])
                        } else { try encode(target: output, state: regular, foreground: mode == 0 || mode == 1 || mode == 4) }
                        command.commit(); command.waitUntilCompleted()
                        try AudioValidation.require(command.status == .completed, "Metal command failed")
                        if frame >= 30 { times.append((command.gpuEndTime-command.gpuStartTime)*1000) }
                    }
                    var pixels = [UInt8](repeating: 0, count: 3840*2160*4)
                    output.getBytes(&pixels, bytesPerRow: 3840*4, from: MTLRegionMake2D(0,0,3840,2160), mipmapLevel: 0)
                    try AudioValidation.require(stride(from:3,to:pixels.count,by:400).allSatisfy { pixels[$0] == 255 }, "Particles punched transparent holes in the background")
                    let luminance = stride(from: 0, to: pixels.count, by: 400).map { Int(pixels[$0])+Int(pixels[$0+1])+Int(pixels[$0+2]) }
                    try AudioValidation.require((luminance.max() ?? 0) > (luminance.min() ?? 0)+8, "Preset rendered a flat frame")
                    if audible {
                        var changed = 0
                        for i in stride(from: 0, to: pixels.count, by: 400) {
                            let red = abs(Int(pixels[i+2])-Int(silentPixels[i+2]))
                            let green = abs(Int(pixels[i+1])-Int(silentPixels[i+1]))
                            let blue = abs(Int(pixels[i])-Int(silentPixels[i]))
                            if red+green+blue > 8 { changed += 1 }
                        }
                        try AudioValidation.require(changed > luminance.count/40,"Music did not materially change the scene")
                    } else { silentPixels = pixels }
                    let name = "\(VisualPreset.allCases[mode].rawValue)-\(light == 0 ? "dark":"light")-\(audible ? "music":"silence")"
                    if let directory = snapshotDirectory { try snapshot(pixels, to: directory.appendingPathComponent(name+".png")) }
                    times.sort(); allTimes += times
                    AudioValidation.report(["event":"preset-passed", "preset":name, "resolution":"3840x2160", "gpuMeanMS":times.reduce(0,+)/Double(times.count), "gpuP95MS":times[Int(Double(times.count)*0.95)]])
                }
            }
        }
        AudioValidation.report(["event":"passed", "mode":"visualizer", "device":device.name, "maxGPUFrameMS":allTimes.max() ?? 0, "scope":"offscreen production shaders, silence and synthetic music; excludes window compositor, FFT, and audio engine"])
    }
    private static func snapshot(_ pixels: [UInt8], to url: URL) throws {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data:data), let image = CGImage(width:3840,height:2160,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:3840*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw AudioFailure(operation:"Could not create visualizer snapshot") }
        CGImageDestinationAddImage(destination,image,nil)
        try AudioValidation.require(CGImageDestinationFinalize(destination),"Could not write visualizer snapshot")
    }
}
