import Accelerate
import AudioDSP
import Foundation

final class SpectrumAnalyzer {
    private let size = 2048
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: 2048)
    private var samples = [Float](repeating: 0, count: 2048)
    private var incoming = [Float](repeating: 0, count: 8192)
    private var real = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)
    private var weighted = [Float](repeating: 0, count: 2048)
    private var pending: [(Double, [Float], [Float])] = []
    private(set) var bins = [Float](repeating: 0, count: 64)
    private(set) var waveform = [Float](repeating: 0, count: 64)
    private(set) var flux: Float = 0
    private(set) var centroid: Float = 0
    private var last = [Float](repeating: 0, count: 64)
    init() { vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    func reset() { bins = .init(repeating: 0, count: 64); waveform = bins; pending.removeAll() }
    func consume(dsp: OpaquePointer, sampleRate: Double, delayMS: Double) {
        let count = Int(ff_read_samples(dsp, &incoming, UInt32(incoming.count)))
        guard count > 0 else { return }
        if count >= size { samples.replaceSubrange(0..<size, with: incoming[(count-size)..<count]) }
        else { samples.removeFirst(count); samples.append(contentsOf: incoming.prefix(count)) }
        vDSP_vmul(samples, 1, window, 1, &weighted, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            weighted.withUnsafeBufferPointer { data in data.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ctoz($0, 2, &split, 1, 1024) } }
            vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
            split.imagp[0] = 0
            vDSP_zvmags(&split, 1, &magnitudes, 1, 1024)
        } }
        var next = [Float](repeating: 0, count: 64), wave = next
        for index in 0..<64 {
            let lo = max(1, Int(30 * pow(700, Double(index)/64) * Double(size)/sampleRate))
            let hi = min(1023, max(lo+1, Int(30 * pow(700, Double(index+1)/64) * Double(size)/sampleRate)))
            if lo <= hi {
                let energy = magnitudes[min(lo,1023)...hi].max() ?? 0
                let db = 10 * log10(max(energy / Float(size*size), 1e-10))
                let level = max(0, min(1, (db+70)/65))
                next[index] = last[index] + (level > last[index] ? 0.65 : 0.12) * (level-last[index])
            }
            wave[index] = samples[index * 32]
        }
        flux = zip(next,last).reduce(0) { $0 + max(0, $1.0 - $1.1) } / 64
        centroid = next.enumerated().reduce(0) { $0 + Float($1.offset) * $1.element } / max(next.reduce(0,+)*64, 0.001)
        last = next
        let time = ProcessInfo.processInfo.systemUptime
        pending.append((time + delayMS/1000, next, wave))
        while let first = pending.first, first.0 <= time { bins = first.1; waveform = first.2; pending.removeFirst() }
        if pending.count > 90 { pending.removeFirst(pending.count-90) }
    }
}
