import XCTest
@testable import FoFoBooster

final class AppActivityTests: XCTestCase {
    @MainActor func testPlaybackStartsWithoutAProcessListChange() {
        let model=AppModel(); model.permissionGranted=false
        model.apps=[AudioApp(id:"browser",name:"Browser",processes:[10,11],running:false)]
        model.profile=DeviceProfile()
        XCTAssertTrue(model.visibleApps.isEmpty)
        model.updateActivity { $0 == 11 }
        XCTAssertEqual(model.visibleApps.map(\.id),["browser"])
        XCTAssertFalse(model.working, "An activity notification must never restart audio")
        model.updateActivity { _ in false }
        XCTAssertTrue(model.visibleApps.isEmpty)
    }
    @MainActor func testAdjustedAndMutedAppsRemainReachableWhenOutputStops() {
        let model=AppModel(); model.permissionGranted=false
        model.apps=[AudioApp(id:"music",name:"Music",processes:[10],running:true)]
        for level in [AppLevel(boost:4), AppLevel(muted:true), AppLevel(solo:true)] {
            model.profile=DeviceProfile(); model.profile.apps["music"]=level
            model.updateActivity { _ in false }
            XCTAssertEqual(model.visibleApps.count,1)
            XCTAssertEqual(model.profile.apps["music"],level)
        }
        model.profile=DeviceProfile(); model.showAll=true
        XCTAssertEqual(model.visibleApps.count,1)
    }
}
