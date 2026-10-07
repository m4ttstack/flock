import XCTest
@testable import FlockCore

private actor SilentClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
final class PaneLastChangeArchiveTests: XCTestCase {
    private let p1 = PaneID(rawValue: "w1:t1:p1")
    private let p2 = PaneID(rawValue: "w1:t1:p2")
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    private func scratchDefaults() -> UserDefaults {
        let name = "PaneLastChangeArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testASeedWithTheSameStatusDatesThePaneAndAnotherStatusIsUnknown() {
        let earlier = launch.addingTimeInterval(-3 * 3600)
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.idle, .idle]), at: launch, seeds: [
            p1: .init(status: .idle, at: earlier),
            p2: .init(status: .blocked, at: earlier),
        ])
        XCTAssertEqual(history.lastChange(of: p1), earlier)
        XCTAssertNil(history.lastChange(of: p2), "the pane changed while flock was closed, at a time nobody saw")
        XCTAssertEqual(Set(history.lastChanges.keys), [p1])
    }

    func testAPaneWithNoSeedAtAllIsUnknown() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.idle]), at: launch, seeds: [:])
        XCTAssertNil(history.lastChange(of: p1))
    }

    func testASeedNeverDatesAPaneAlreadySeen() {
        var history = PaneStatusHistory()
        history.observe(MissionFixture.single([.working]), at: launch)
        let later = launch.addingTimeInterval(60)
        history.observe(MissionFixture.single([.idle]), at: later, seeds: [p1: .init(status: .idle, at: launch.addingTimeInterval(-3600))])
        XCTAssertEqual(history.lastChange(of: p1), later)
    }

    func testTheArchiveRoundTripsAndForgetsWhenEmpty() {
        let defaults = scratchDefaults()
        let archive = PaneLastChangeArchive(userDefaults: defaults)
        XCTAssertEqual(archive.load(), [:])
        let changes: [PaneID: PaneStatusHistory.Transition] = [p1: .init(status: .done, at: launch)]
        archive.save(changes)
        XCTAssertEqual(PaneLastChangeArchive(userDefaults: defaults).load(), changes)
        archive.save([:])
        XCTAssertNil(defaults.data(forKey: PaneLastChangeArchive.defaultsKey))
    }

    func testARelaunchKeepsWhenAnUnchangedPaneLastChanged() {
        let defaults = scratchDefaults()
        let clock = Clock()
        let first = SessionViewModel(client: SilentClient(), now: { clock.now }, paneLastChangeArchive: PaneLastChangeArchive(userDefaults: defaults))
        first.update(model: MissionFixture.single([.working, .working]), connection: .live)
        clock.now = launch.addingTimeInterval(600)
        first.update(model: MissionFixture.single([.idle, .done]), connection: .live)

        clock.now = launch.addingTimeInterval(5 * 3600)
        let relaunched = SessionViewModel(client: SilentClient(), now: { clock.now }, paneLastChangeArchive: PaneLastChangeArchive(userDefaults: defaults))
        relaunched.update(model: MissionFixture.single([.idle, .working]), connection: .live)
        XCTAssertEqual(relaunched.statusHistory.lastChange(of: p1), launch.addingTimeInterval(600), "still idle since it went idle")
        XCTAssertNil(relaunched.statusHistory.lastChange(of: p2), "done then, working now: changed while closed")
    }

    func testAFreshInstallPersistsNothingUntilAPaneChanges() {
        let clock = Clock()
        let archive = PaneLastChangeArchive(userDefaults: scratchDefaults())
        let viewModel = SessionViewModel(client: SilentClient(), now: { clock.now }, paneLastChangeArchive: archive)
        viewModel.update(model: MissionFixture.single([.idle, .idle]), connection: .live)
        XCTAssertNil(viewModel.statusHistory.lastChange(of: p1))
        XCTAssertEqual(archive.load(), [:])
        clock.now = launch.addingTimeInterval(60)
        viewModel.update(model: MissionFixture.single([.idle, .working]), connection: .live)
        XCTAssertEqual(archive.load(), [p2: .init(status: .working, at: clock.now)])
    }

    func testAPaneHerdrNoLongerReportsLeavesTheArchive() {
        let clock = Clock()
        let archive = PaneLastChangeArchive(userDefaults: scratchDefaults())
        let viewModel = SessionViewModel(client: SilentClient(), now: { clock.now }, paneLastChangeArchive: archive)
        viewModel.update(model: MissionFixture.single([.working, .working]), connection: .live)
        clock.now = launch.addingTimeInterval(60)
        viewModel.update(model: MissionFixture.single([.idle, .idle]), connection: .live)
        XCTAssertEqual(Set(archive.load().keys), [p1, p2])
        clock.now = launch.addingTimeInterval(120)
        viewModel.update(model: MissionFixture.single([.idle]), connection: .live)
        XCTAssertEqual(Set(archive.load().keys), [p1])
    }
}
