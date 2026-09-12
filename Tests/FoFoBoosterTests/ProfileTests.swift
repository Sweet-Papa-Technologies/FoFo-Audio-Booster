import XCTest
@testable import FoFoBooster
final class ProfileTests: XCTestCase {
    let browser = AudioApp(id: "com.google.Chrome", name: "Chrome", processes: [10,11], running: true)
    let music = AudioApp(id: "com.spotify.client", name: "Spotify", processes: [12], running: true)
    func testUntouchedPathHasNoTap() {
        XCTAssertTrue(RoutingPlan.make(profile: DeviceProfile(), apps: [browser,music], ownProcesses: [99]).isEmpty)
    }
    func testPerAppTapLeavesOtherAppsUntouched() {
        var profile = DeviceProfile(); profile.apps[browser.id] = AppLevel(boost: 6)
        XCTAssertEqual(RoutingPlan.make(profile: profile, apps: [browser,music], ownProcesses: [99]), [SourcePlan(key: browser.id, processes: [10,11], exclusive: false)])
    }
    func testMasterExcludesClaimedAppsAndSelfToPreventDoubleBoost() {
        var profile = DeviceProfile(); profile.boost = 3; profile.apps[browser.id] = AppLevel(boost: 6)
        let plan = RoutingPlan.make(profile: profile, apps: [browser,music], ownProcesses: [99])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.last?.processes, [10,11,99]); XCTAssertEqual(plan.last?.exclusive, true)
    }
    func testSoloCatchesFutureAndUnknownSources() {
        var profile = DeviceProfile(); profile.apps[browser.id] = AppLevel(solo: true)
        let plan = RoutingPlan.make(profile: profile, apps: [browser,music], ownProcesses: [99])
        XCTAssertEqual(plan, [SourcePlan(key: browser.id, processes: [10,11], exclusive: false),
                              SourcePlan(key: "__remaining__", processes: [10,11,99], exclusive: true)])
    }
    func testHelperAliasesRespectBundleBoundaries() {
        XCTAssertEqual(AppDiscovery.canonical("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(AppDiscovery.canonical("com.google.ChromeBeta"), "com.google.ChromeBeta")
    }
    func testProfilesRoundTripByUIDWithPluginState() throws {
        let suite = "FoFoTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        var headphones = DeviceProfile(name: "Headphones"); headphones.boost = 9; headphones.apps[browser.id] = AppLevel(boost: 3, muted: false, solo: true)
        headphones.plugins = [PluginSlot(name: "EQ", type: 1, subtype: 2, manufacturer: 3, state: Data([1,2,3]))]
        let speakers = DeviceProfile(name: "Speakers")
        store.save(["uid-bt":headphones,"uid-speakers":speakers])
        XCTAssertEqual(store.load(), ["uid-bt":headphones,"uid-speakers":speakers])
    }
    func testCorruptedPreferencesFallBackSafely() {
        let suite = "FoFoTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "deviceProfiles")
        XCTAssertTrue(ProfileStore(defaults: defaults).load().isEmpty)
    }
    func testCapReductionClampsSavedLevels() {
        var p = DeviceProfile(); p.boost = 24; p.apps[browser.id] = AppLevel(boost: 22); p.balance = .infinity; p.target = .nan
        p.sanitize(cap: 12)
        XCTAssertEqual(p.boost, 12); XCTAssertEqual(p.apps[browser.id]?.boost, 12); XCTAssertEqual(p.balance, 0); XCTAssertEqual(p.target, -14)
    }
    func testDeviceProfileEnablesRouteForBalanceAndPlugins() {
        var p = DeviceProfile(); p.balance = 0.5; XCTAssertTrue(p.needsMaster)
        p.balance = 0; p.plugins = [PluginSlot(name: "EQ", type: 1, subtype: 2, manufacturer: 3, bypass: true)]
        XCTAssertFalse(p.needsMaster); p.plugins[0].bypass = false; XCTAssertTrue(p.needsMaster)
    }
    func testBluetoothCallModeRequiresAllThreeConditions() {
        var d = OutputDevice(id: 1, uid: "bt", name: "Headset", sampleRate: 16000, channels: 1, transport: 0x626c7565, latencyFrames: 0, bufferFrames: 128)
        XCTAssertTrue(d.isCallMode); d.channels = 2; XCTAssertFalse(d.isCallMode); d.channels = 1; d.sampleRate = 48000; XCTAssertFalse(d.isCallMode)
    }
}
