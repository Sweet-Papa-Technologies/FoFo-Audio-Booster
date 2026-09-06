import XCTest
@testable import FoFoBooster
final class ListeningMonitorTests: XCTestCase {
    func testHintRequiresThirtyContinuousMinutesAboveNineDB() {
        var monitor = ListeningMonitor()
        XCTAssertFalse(monitor.update(time: 0, deviceUID: "bt", headphones: true, processing: true, activeBoost: 12))
        XCTAssertFalse(monitor.update(time: 1799, deviceUID: "bt", headphones: true, processing: true, activeBoost: 12))
        XCTAssertTrue(monitor.update(time: 1800, deviceUID: "bt", headphones: true, processing: true, activeBoost: 12))
    }
    func testLowerLevelBypassAndDeviceSwitchBreakContinuity() {
        var monitor = ListeningMonitor()
        _ = monitor.update(time: 0, deviceUID: "a", headphones: true, processing: true, activeBoost: 12)
        XCTAssertFalse(monitor.update(time: 1799, deviceUID: "a", headphones: true, processing: true, activeBoost: 9))
        XCTAssertFalse(monitor.update(time: 2000, deviceUID: "a", headphones: true, processing: true, activeBoost: 12))
        XCTAssertFalse(monitor.update(time: 3700, deviceUID: "b", headphones: true, processing: true, activeBoost: 12))
        XCTAssertFalse(monitor.update(time: 5400, deviceUID: "b", headphones: true, processing: false, activeBoost: 12))
        XCTAssertFalse(monitor.update(time: 5500, deviceUID: "b", headphones: true, processing: true, activeBoost: 12))
    }
    func testDismissalDoesNotNagOnAnotherDevice() {
        var monitor = ListeningMonitor(); monitor.dismiss()
        XCTAssertFalse(monitor.update(time: 0, deviceUID: "a", headphones: true, processing: true, activeBoost: 24))
        XCTAssertFalse(monitor.update(time: 3600, deviceUID: "b", headphones: true, processing: true, activeBoost: 24))
        XCTAssertFalse(monitor.update(time: 9000, deviceUID: "b", headphones: true, processing: true, activeBoost: 24))
    }
    func testSpeakersNeverProduceHeadphoneHint() {
        var monitor = ListeningMonitor()
        XCTAssertFalse(monitor.update(time: 0, deviceUID: "speakers", headphones: false, processing: true, activeBoost: 24))
        XCTAssertFalse(monitor.update(time: 36000, deviceUID: "speakers", headphones: false, processing: true, activeBoost: 24))
    }
}
