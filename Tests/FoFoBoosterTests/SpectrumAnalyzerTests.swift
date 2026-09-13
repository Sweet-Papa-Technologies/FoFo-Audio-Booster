import XCTest
@testable import FoFoBooster

final class SpectrumAnalyzerTests: XCTestCase {
    private func tone(_ hz: Double, amplitude: Float = 0.2, rate: Double = 48000) -> [Float] {
        (0..<2048).map { amplitude * Float(sin(Double($0)*2*Double.pi*hz/rate)) }
    }
    func testQuietMusicIsVisibleAndSilenceIsNotInvented() {
        let a = SpectrumAnalyzer()
        for i in 0..<30 { a.consume(samples: tone(110,amplitude: 0.008), sampleRate: 48000, delayMS: 0,time: Double(i)/60) }
        XCTAssertGreaterThan(a.signal.level, 0.25)
        XCTAssertGreaterThan(a.waveform.map(abs).max() ?? 0, 0.06)
        XCTAssertGreaterThan(a.signal.bass,a.signal.treble)
        for i in 30..<180 { a.consume(samples: .init(repeating: 0,count:2048),sampleRate:48000,delayMS:0,time:Double(i)/60) }
        XCTAssertLessThan(a.signal.level, 0.005)
        XCTAssertEqual(a.waveform.map(abs).max(), 0)
    }
    func testTransientAndAllFeaturesRespectTheSameLatency() {
        let a = SpectrumAnalyzer()
        a.consume(samples:tone(100),sampleRate:48000,delayMS:200,time:0)
        XCTAssertEqual(a.signal.level,0); XCTAssertEqual(a.signal.onset,0)
        XCTAssertEqual(a.waveform.map(abs).max(),0)
        a.consume(samples:[],sampleRate:48000,delayMS:200,time:0.21)
        XCTAssertGreaterThan(a.signal.level,0)
        XCTAssertGreaterThan(a.signal.onset,0)
        XCTAssertGreaterThan(a.waveform.map(abs).max() ?? 0,0)
    }
    func testNoCallbacksDrainPendingFramesThenFadeInsteadOfFreezing() {
        let a = SpectrumAnalyzer()
        a.consume(samples:tone(440),sampleRate:48000,delayMS:100,time:0)
        for i in 1...180 { a.consume(samples:[],sampleRate:48000,delayMS:100,time:Double(i)/60) }
        XCTAssertLessThan(a.signal.level,0.001)
        XCTAssertLessThan(a.bins.max() ?? 1,0.001)
        XCTAssertLessThan(a.waveform.map(abs).max() ?? 1,0.001)
        XCTAssertLessThan(a.peaks.max() ?? 1,0.001)
    }
    func testFrequencyRegionsAndCentroidRespondToDifferentMusic() {
        let low=SpectrumAnalyzer(), high=SpectrumAnalyzer()
        for i in 0..<45 {
            low.consume(samples:tone(90),sampleRate:48000,delayMS:0,time:Double(i)/60)
            high.consume(samples:tone(7000),sampleRate:48000,delayMS:0,time:Double(i)/60)
        }
        XCTAssertGreaterThan(low.signal.bass,high.signal.bass)
        XCTAssertGreaterThan(high.signal.treble,low.signal.treble)
        XCTAssertGreaterThan(high.centroid,low.centroid+0.3)
    }
    func testResetClearsWindowAndDelayedFeatures() {
        let a=SpectrumAnalyzer()
        a.consume(samples:tone(80),sampleRate:48000,delayMS:200,time:0)
        a.reset()
        a.consume(samples:[],sampleRate:48000,delayMS:0,time:1)
        XCTAssertEqual(a.signal.level,0); XCTAssertEqual(a.signal.bass,0)
        XCTAssertEqual(a.waveform.map(abs).max(),0)
    }
    func testNonFiniteInputCannotReachShaders() {
        let a=SpectrumAnalyzer()
        a.consume(samples:[.nan,.infinity,-.infinity],sampleRate:8000,delayMS:.nan,time:0)
        XCTAssertTrue((a.bins+a.waveform).allSatisfy(\.isFinite))
        a.consume(samples:tone(200),sampleRate:.nan,delayMS:0,time:1)
        XCTAssertEqual(a.signal.level,0)
    }
}
