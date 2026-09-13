import Accelerate
import AudioDSP
import Foundation

/// Runs on the display thread, never in the real-time audio callback. All visual
/// features travel together through the device-latency queue.
final class SpectrumAnalyzer {
    static let waveCount = 256
    struct Signal {
        var bins = [Float](repeating: 0, count: 64)
        var wave = [Float](repeating: 0, count: waveCount)
        var level: Float = 0
        var bass: Float = 0
        var mids: Float = 0
        var treble: Float = 0
        var onset: Float = 0
        var flux: Float = 0
        var centroid: Float = 0
    }
    private let size = 2048
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: 2048)
    private var samples = [Float](repeating: 0, count: 2048)
    private var incoming = [Float](repeating: 0, count: 8192)
    private var real = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)
    private var weighted = [Float](repeating: 0, count: 2048)
    private var pending: [(time: Double, signal: Signal)] = []
    private var previous = Signal()
    private var previousTime: Double?
    private var lastInputTime: Double?
    private var lastSampleRate: Double?
    private var peakUntil = [Double](repeating: 0, count: 64)
    private var displayTime: Double?
    private(set) var signal = Signal()
    private(set) var peaks = [Float](repeating: 0, count: 64)
    var bins: [Float] { signal.bins }
    var waveform: [Float] { signal.wave }
    var flux: Float { signal.flux }
    var centroid: Float { signal.centroid }
    init() { vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    func reset() {
        signal = Signal(); previous = signal; peaks = signal.bins
        samples = .init(repeating: 0, count: size)
        peakUntil = .init(repeating: 0, count: 64)
        pending.removeAll(); previousTime = nil; displayTime = nil
        lastInputTime = nil; lastSampleRate = nil
    }
    func consume(dsp: OpaquePointer, sampleRate: Double, delayMS: Double) {
        var latest: [Float] = []
        // Bounded drain of the 32K sample ring: after a dropped/minimized frame,
        // analyze recent sound rather than replaying a stale visual backlog.
        for _ in 0..<4 {
            let count = Int(ff_read_samples(dsp, &incoming, UInt32(incoming.count)))
            if count == 0 { break }
            latest.append(contentsOf: incoming.prefix(count))
            if latest.count > size { latest.removeFirst(latest.count-size) }
            if count < incoming.count { break }
        }
        consume(samples: latest, sampleRate: sampleRate,
                delayMS: delayMS, time: ProcessInfo.processInfo.systemUptime)
    }
    /// Explicit time/sample input also allows deterministic signal regression tests.
    func consume(samples chunk: [Float], sampleRate: Double, delayMS: Double, time: Double) {
        guard sampleRate.isFinite, sampleRate >= 8000, time.isFinite else { reset(); return }
        if lastSampleRate != nil && lastSampleRate != sampleRate { reset() }
        lastSampleRate = sampleRate
        let dt = Float(min(max(time - (previousTime ?? time - 1/60), 0), 0.1))
        previousTime = time
        let delay = delayMS.isFinite ? min(max(delayMS, 0), 1000)/1000 : 0
        if !chunk.isEmpty {
            let clean = chunk.suffix(size).map { $0.isFinite ? max(-4, min(4, $0)) : 0 }
            if clean.count == size { samples = clean }
            else { samples.removeFirst(clean.count); samples.append(contentsOf: clean) }
            lastInputTime = time
            vDSP_vmul(samples, 1, window, 1, &weighted, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                weighted.withUnsafeBufferPointer { data in data.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ctoz($0, 2, &split, 1, 1024) } }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &magnitudes, 1, 1024)
            } }
            var next = Signal()
            let upper = min(20000, sampleRate * 0.48)
            for index in 0..<64 {
                let low = 30 * pow(upper/30, Double(index)/64)
                let high = 30 * pow(upper/30, Double(index+1)/64)
                let lo = max(1, min(1023, Int(low * Double(size)/sampleRate)))
                let hi = max(lo, min(1023, Int(high * Double(size)/sampleRate)))
                let energy = magnitudes[lo...hi].max() ?? 0
                let db = 10 * log10(max(energy / Float(size*size), 1e-12))
                let level = max(0, min(1, (db+76)/68))
                next.bins[index] = smooth(previous.bins[index], level, dt, attack: 0.025, release: 0.22)
                if low < 250 { next.bass += next.bins[index] / Float(max(1, Int(log(250/30)/log(upper/30)*64))) }
                else if low < 3000 { next.mids += next.bins[index] / 25 }
                else { next.treble += next.bins[index] / 19 }
            }
            next.bass = min(1,next.bass); next.mids = min(1,next.mids); next.treble = min(1,next.treble)
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1*$1 } / Float(size))
            let targetLevel = max(0, min(1, (20*log10(max(rms,1e-8))+65)/59))
            next.level = smooth(previous.level, targetLevel, dt, attack: 0.035, release: 0.4)
            let rise = zip(next.bins,previous.bins).reduce(Float(0)) { $0 + max(0,$1.0-$1.1) } / 64
            next.flux = smooth(previous.flux, min(1,rise*10), dt, attack: 0.02, release: 0.18)
            next.onset = max(min(1,rise*14), previous.onset * exp(-dt/0.32))
            next.centroid = next.bins.enumerated().reduce(Float(0)) { $0 + Float($1.offset)*$1.element } / max(next.bins.reduce(0,+)*63, 0.001)
            // Bounded visual gain makes quiet material legible without amplifying
            // the user's audio or turning digital silence into a fake waveform.
            let gain = min(12, 0.55 / max(rms*2.8, 0.045))
            for i in 0..<Self.waveCount {
                let start = i * size / Self.waveCount
                next.wave[i] = tanh(samples[start..<start+8].reduce(0,+)/8 * gain)
            }
            previous = next
            pending.append((time+delay, next))
        }
        while let first = pending.first, first.time <= time { signal = first.signal; pending.removeFirst() }
        let elapsed = Float(min(max(time - (displayTime ?? time), 0), 0.1)); displayTime = time
        // Continue draining delayed frames and fading after a source pauses or an
        // IO callback stops; don't leave an old spectrum pinned on screen.
        if time - (lastInputTime ?? time) > delay + 0.1 {
            let fade = exp(-elapsed/0.22)
            signal.bins = signal.bins.map { $0*fade }; signal.wave = signal.wave.map { $0*fade }
            signal.level *= fade; signal.bass *= fade; signal.mids *= fade; signal.treble *= fade
            signal.flux *= fade; signal.onset *= fade
            previous = signal
        }
        for i in 0..<64 {
            if bins[i] >= peaks[i] { peaks[i] = bins[i]; peakUntil[i] = time+0.4 }
            else if time > peakUntil[i] { peaks[i] = max(bins[i], peaks[i]-elapsed*0.6) }
        }
        if pending.count > 120 { pending.removeFirst(pending.count-120) }
    }
    private func smooth(_ from: Float, _ to: Float, _ dt: Float, attack: Float, release: Float) -> Float {
        from + (to-from) * (1-exp(-dt/(to > from ? attack : release)))
    }
}
