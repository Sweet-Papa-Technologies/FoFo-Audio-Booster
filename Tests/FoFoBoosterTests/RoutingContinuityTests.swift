import XCTest
@testable import FoFoBooster

final class RoutingContinuityTests: XCTestCase {
    private let music = AudioApp(id: "music", name: "Music", processes: [10], running: true)
    private let background = AudioApp(id: "background", name: "Background", processes: [20], running: false)
    private let output = OutputDevice(id: 1, uid: "headphones", name: "Headphones", sampleRate: 48000, channels: 2, transport: 0, latencyFrames: 128, bufferFrames: 128)
    private func route(_ profile: DeviceProfile, _ apps: [AudioApp], own: [UInt32] = [99], device: OutputDevice? = nil) -> AudioRouteIdentity {
        AudioRouteIdentity(device: device ?? output, sources: RoutingPlan.make(profile: profile, apps: apps, ownProcesses: own))
    }
    func testMasterAndPluginChainsIgnoreBackgroundProcessChurn() {
        var profile = DeviceProfile(); profile.boost = 6
        for pluginOnly in [false, true] {
            if pluginOnly { profile.boost = 0; profile.plugins = [PluginSlot(name: "EQ", type: 1, subtype: 2, manufacturer: 3)] }
            let original = route(profile, [music])
            for process in UInt32(20)..<200 {
                var app = background; app.processes = [process, process+1000]; app.running = process.isMultiple(of: 2)
                XCTAssertEqual(route(profile, [app, music]), original)
                XCTAssertEqual(route(profile, [music]), original)
            }
        }
    }
    func testPerAppProcessingIgnoresUnrelatedHelpersAndActivity() {
        var profile = DeviceProfile(); profile.apps[music.id] = AppLevel(boost: 4)
        let original = route(profile, [music, background])
        var other = background; other.processes = [30,31,32]; other.running = true
        XCTAssertEqual(route(profile, [other, music]), original)
        XCTAssertEqual(route(profile, [music]), original)
    }
    func testSoloUsesStableResidualTapForNewApps() {
        var profile = DeviceProfile(); profile.apps[music.id] = AppLevel(solo: true)
        let original = route(profile, [music])
        XCTAssertEqual(route(profile, [music, background]), original)
        XCTAssertEqual(original.sources.count, 2)
        XCTAssertEqual(original.sources.last, SourcePlan(key: "__remaining__", processes: [10,99], exclusive: true))
        // Explicitly boosted/muted sources still need their independent controls.
        profile.apps[background.id] = AppLevel(boost: 3)
        XCTAssertNotEqual(route(profile, [music, background]), original)
    }
    func testDiscoveryReorderingNamesAndDuplicateIDsDoNotRebuild() {
        var profile = DeviceProfile(); profile.boost = 3
        profile.apps[music.id] = AppLevel(boost: 2); profile.apps[background.id] = AppLevel(muted: true)
        var renamed = music; renamed.name = "Z Music"; renamed.processes = [12,10,12]; renamed.running = false
        var original = music; original.processes = [10,12]
        XCTAssertEqual(route(profile, [background, renamed], own: [99,99]), route(profile, [original, background]))
    }
    func testControlledAppRelaunchStillChangesRoute() {
        var profile = DeviceProfile(); profile.apps[music.id] = AppLevel(boost: 4)
        var relaunched = music; relaunched.processes = [11]
        XCTAssertNotEqual(route(profile, [relaunched]), route(profile, [music]))
        XCTAssertNotEqual(route(profile, []), route(profile, [music]))
    }
    func testOwnProcessChangesStillUpdateFeedbackExclusion() {
        var profile = DeviceProfile(); profile.boost = 3
        XCTAssertNotEqual(route(profile, [music], own: []), route(profile, [music], own: [99]))
    }
    func testOnlyRelevantOutputChangesAffectRoute() {
        let original = route(DeviceProfile(), [music])
        var renamed = output; renamed.name = "Renamed"; renamed.latencyFrames = 256
        XCTAssertEqual(route(DeviceProfile(), [music], device: renamed), original)
        var changes = [OutputDevice]()
        var changed = output; changed.id = 2; changes.append(changed)
        changed = output; changed.uid = "speakers"; changes.append(changed)
        changed = output; changed.sampleRate = 44100; changes.append(changed)
        changed = output; changed.channels = 1; changes.append(changed)
        changed = output; changed.bufferFrames = 512; changes.append(changed)
        for device in changes { XCTAssertNotEqual(route(DeviceProfile(), [music], device: device), original) }
    }
    @MainActor
    func testAppRefreshDoesNotScheduleRebuildForBackgroundChurn() {
        let model = AppModel()
        // Keep hardware processing disabled; feed the same discovery handler used
        // by the actual property listeners and timer, with a known output snapshot.
        model.permissionGranted = false
        model.devices = [output]; model.selectedUID = output.uid
        model.profile = DeviceProfile()
        model.profile.plugins = [PluginSlot(name: "EQ", type: 1, subtype: 2, manufacturer: 3)]
        XCTAssertTrue(model.updateDiscovery(devices: [output], apps: [music], defaultOutput: output.id, ownProcesses: [99]))
        var otherDevice = output; otherDevice.id = 2; otherDevice.uid = "unused"
        for process in UInt32(20)..<100 {
            var app = background; app.processes = [process]; app.running = process.isMultiple(of: 2)
            XCTAssertFalse(model.updateDiscovery(devices: [otherDevice, output], apps: [app, music], defaultOutput: output.id, ownProcesses: [99]))
            XCTAssertEqual(model.apps.count, 2, "The panel should still refresh")
            XCTAssertFalse(model.updateDiscovery(devices: [output], apps: [music], defaultOutput: output.id, ownProcesses: [99]))
        }
        model.profile.apps[music.id] = AppLevel(boost: 4)
        XCTAssertTrue(model.updateDiscovery(devices: [output], apps: [music], defaultOutput: output.id, ownProcesses: [99]))
        var relaunched = music; relaunched.processes = [1001]
        XCTAssertTrue(model.updateDiscovery(devices: [output], apps: [relaunched], defaultOutput: output.id, ownProcesses: [99]))
        XCTAssertFalse(model.updateDiscovery(devices: [output], apps: [relaunched], defaultOutput: output.id, ownProcesses: [99]))
    }

}
