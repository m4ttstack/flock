import XCTest
@testable import FlockCore

@MainActor
final class RtCoordinatorLifetimeTests: XCTestCase {
    private func openRunner(_ world: FakeRtWorld, _ rt: RtCoordinator) async {
        world.script("command rt runner", .init(busyPolls: 100_000, status: "0", foreground: ["bun", "rt-ui"]))
        await rt.open(.runner, from: world.fixture.linkedPane)
        rt.update(model: world.model())
    }

    func testClosingTheLinkedPaneStopsItsRunnerCleanly() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.removeLinkedPane()
        rt.update(model: world.model())
        await rt.settle()

        let keys = world.calls("pane.send_keys").map { FakeRtWorld.strings($0["keys"]) }
        XCTAssertEqual(keys, [["ctrl+c"], ["y"]])
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wF1")
        XCTAssertNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
    }

    func testAMovedLinkedPaneKeepsItsRunner() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.moveLinkedPane(to: "w1:p9")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertTrue(world.calls("pane.send_keys").isEmpty)
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
    }

    func testWithoutTerminalIDsNothingIsReaped() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.stripTerminals()
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
    }

    func testANewTabNotYetInTheModelIsNotDropped() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        rt.update(model: RtFixture().model())

        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: RtFixture().model())

        XCTAssertNotNil(rt.items["tok1"])
        rt.watches["tok1"]?.cancel()
    }

    func testAnItemWhoseTabClosedElsewhereIsForgotten() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        rt.update(model: RtFixture().model())

        XCTAssertNil(rt.items["tok1"])
        XCTAssertTrue(world.calls("tab.close").isEmpty)
    }

    /// A model landing mid-open sees the new tab unlabelled or freshly
    /// labelled but not yet in `items`: adoption must wait it out rather than
    /// orphan it or double-register it once the open finishes.
    func testAdoptionWaitsOutAnOpenInFlight() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        world.silentPanes = ["wF1:p1"]
        let rt = makeCoordinator(world)

        async let opening: Void = rt.open(.run, from: world.fixture.linkedPane)
        try? await Task.sleep(for: .milliseconds(3))
        rt.update(model: world.model())
        world.silentPanes = []
        await opening
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertTrue(world.calls("tab.close").isEmpty)
        XCTAssertEqual(rt.runItems(linkedTo: RtFixture.linkedTerminal).count, 1)
        rt.watches["tok1"]?.cancel()
    }

    func testLaunchAdoptsALiveRunnerAndShutsDownAStaleNav() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wR", label: "flock:rt runner term_a1")
        world.seed(tab: "wR:t1", in: "wR", label: "runner term_a1 old1", number: 1)
        world.seed(pane: "wR:p1", tab: "wR:t1", workspace: "wR", terminal: "term_r1")
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "nav term_a1 old2", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(rt.runner(linkedTo: RtFixture.linkedTerminal)?.id, "old1")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
        rt.watches["old1"]?.cancel()
    }

    func testLaunchClosesARunnerWhoseBoardExited() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wR", label: "flock:rt runner term_a1")
        world.seed(tab: "wR:t1", in: "wR", label: "runner term_a1 old1", number: 1)
        world.seed(pane: "wR:p1", tab: "wR:t1", workspace: "wR", terminal: "term_r1")
        world.write("0\n", to: rtPaths("old1").status)
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wR")
    }

    func testLaunchClosesARunnerWhoseBoardExitedAndDeletesItsSeedFile() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wR", label: "flock:rt runner term_a1")
        world.seed(tab: "wR:t1", in: "wR", label: "runner term_a1 old1", number: 1)
        world.seed(pane: "wR:p1", tab: "wR:t1", workspace: "wR", terminal: "term_r1")
        world.write("0\n", to: rtPaths("old1").status)
        world.write(rtSeedLine, to: rtPaths("old1").seed)
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        XCTAssertNil(world.read(rtPaths("old1").seed))
    }

    func testLaunchAdoptsARunInItsPhase() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "run term_a1 old3", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        world.write(rtResultLine + "\n", to: rtPaths("old3").out)
        let rt = makeCoordinator(world)

        rt.update(model: world.model())

        let item = try XCTUnwrap(rt.items["old3"])
        XCTAssertEqual(item.title, "pnpm run test")
        XCTAssertTrue(item.isRunning)
        XCTAssertEqual(rt.lifecycles["old3"]?.stage, .script)
        rt.watches["old3"]?.cancel()
    }

    /// A hidden tab holds one pane, so a tab rt did not open through flock is
    /// never an item's: it is shut down even while a run is picking.
    func testAStrayTabIsShutDownEvenWhileARunPicks() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        world.seed(tab: "wF1:t9", in: "wF1", label: "zsh", number: 2)
        world.seed(pane: "wF1:p9", tab: "wF1:t9", workspace: "wF1", terminal: "term_9")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t9")
        XCTAssertEqual(rt.items["tok1"]?.tabID, TabID(rawValue: "wF1:t1"))
        XCTAssertTrue(world.calls("tab.rename").allSatisfy { FakeRtWorld.string($0["tab_id"]) != "wF1:t9" })
        rt.watches["tok1"]?.cancel()
    }

    func testAStrayTabWithNoRunPickingIsShutDown() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "zsh", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)

        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wS:t1")
    }

    func testFocusOnAnAttachTabOpensTheServiceViewAndHandsFocusBack() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.seed(tab: "wF1:t7", in: "wF1", label: "bg:p3", number: 2)
        world.seed(pane: "wF1:p7", tab: "wF1:t7", workspace: "wF1", terminal: "term_7")
        world.focus("wF1:p7")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(rt.modal?.serviceTabID, TabID(rawValue: "wF1:t7"))
        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")

        await rt.backToBoard()
        XCTAssertNil(rt.modal?.serviceTabID)
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t7")
        rt.watches["tok1"]?.cancel()
    }

    func testClosingTheModalWithTheServiceViewUpClosesTheAttachTabAndKeepsTheRunner() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.seed(tab: "wF1:t7", in: "wF1", label: "bg:p3", number: 2)
        world.seed(pane: "wF1:p7", tab: "wF1:t7", workspace: "wF1", terminal: "term_7")
        world.focus("wF1:p7")
        rt.update(model: world.model())
        await rt.settle()
        XCTAssertEqual(rt.modal?.serviceTabID, TabID(rawValue: "wF1:t7"))

        await rt.closeModal()
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t7")
        XCTAssertTrue(world.calls("tab.close").allSatisfy { FakeRtWorld.string($0["tab_id"]) != "wF1:t1" })
        XCTAssertNil(rt.modal)
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
    }

    func testSwappingAwayFromTheServiceViewClosesTheAttachTabAndKeepsTheRunner() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await openRunner(world, rt)

        world.seed(tab: "wF1:t7", in: "wF1", label: "bg:p3", number: 2)
        world.seed(pane: "wF1:p7", tab: "wF1:t7", workspace: "wF1", terminal: "term_7")
        world.focus("wF1:p7")
        rt.update(model: world.model())
        await rt.settle()
        XCTAssertEqual(rt.modal?.serviceTabID, TabID(rawValue: "wF1:t7"))

        await rt.open(.glitter, from: world.fixture.linkedPane)
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").last?["tab_id"]), "wF1:t7")
        XCTAssertTrue(world.calls("tab.close").allSatisfy { FakeRtWorld.string($0["tab_id"]) != "wF1:t1" })
        XCTAssertEqual(rt.modal?.itemID, "tok2")
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        rt.watches["tok1"]?.cancel()
        rt.watches["tok2"]?.cancel()
    }

    /// A flock tab nothing owns (an orphan on its way out, a click in the
    /// herdr TUI) still hands herdr's focus back, to the last visible pane.
    func testFocusOnAnUnownedFlockTabGoesBackToTheLastVisiblePane() async throws {
        let world = FakeRtWorld()
        world.seed(workspace: "wS", label: "flock:rt")
        world.seed(tab: "wS:t1", in: "wS", label: "run term_gone old9", number: 1)
        world.seed(pane: "wS:p1", tab: "wS:t1", workspace: "wS", terminal: "term_s1")
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        world.focus("wS:p1")
        rt.update(model: world.model())
        await rt.settle()

        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")
    }

    func testClosingTheLinkedPaneSendsNoYToAScriptThatIsNotRt() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        world.removeLinkedPane()
        rt.update(model: world.model())
        await rt.settle()

        let keys = world.calls("pane.send_keys").map { FakeRtWorld.strings($0["keys"]) }
        XCTAssertEqual(keys, [["ctrl+c"]])
        XCTAssertNil(rt.items["tok1"])
    }

    func testShutDownOfAnAlreadyGoneItemReleasesItFromReaping() async throws {
        let world = FakeRtWorld()
        let rt = makeCoordinator(world)
        rt.reaping.insert("ghost")

        await rt.shutDown("ghost")

        XCTAssertFalse(rt.reaping.contains("ghost"))
    }
}
