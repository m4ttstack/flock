import XCTest
@testable import FlockCore

@MainActor
final class RtCoordinatorTests: XCTestCase {
    private func finishWatch(_ rt: RtCoordinator, _ token: String) async throws {
        let watch = try XCTUnwrap(rt.watches[token])
        await watch.value
    }

    func testNavOpensHiddenInTheSharedWorkspaceAndClosesWhenItQuits() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 2, status: "0", out: ""))
        let rt = makeCoordinator(world)

        await rt.open(.nav, from: world.fixture.linkedPane)

        let create = try XCTUnwrap(world.calls("workspace.create").first)
        XCTAssertEqual(FakeRtWorld.string(create["label"]), "flock:rt")
        XCTAssertEqual(FakeRtWorld.string(create["cwd"]), "/src/acme")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.rename").first?["label"]), "nav term_a1 tok1")
        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt nav >"$FLOCK_RT_OUT"; echo $? >"$FLOCK_RT_STATUS""#])
        XCTAssertEqual(rt.modal?.itemID, "tok1")

        try await finishWatch(rt, "tok1")

        XCTAssertNil(rt.modal)
        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.close").first?["tab_id"]), "wF1:t1")
    }

    func testASecondCommandOpensALabelledTabInTheSharedWorkspace() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.glitter, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        await rt.open(.glitter, from: world.fixture.linkedPane)

        let tab = try XCTUnwrap(world.calls("tab.create").first)
        XCTAssertEqual(FakeRtWorld.string(tab["workspace_id"]), "wF1")
        XCTAssertEqual(FakeRtWorld.string(tab["label"]), "glitter term_a1 tok2")
        XCTAssertEqual(world.calls("workspace.create").count, 1)
        XCTAssertEqual(rt.modal?.itemID, "tok2")
    }

    func testCdHereTypesIntoAnIdleLinkedPane() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1, status: "0", out: "/src/acme/it's web\n"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        await rt.open(.nav, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.typed(into: "w1:p1"), [#"cd '/src/acme/it'\''s web'"#])
        XCTAssertTrue(world.calls("pane.split").isEmpty)
    }

    func testCdHereSplitsABusyLinkedPane() async throws {
        let world = FakeRtWorld()
        world.busyPanes = ["w1:p1"]
        world.script("command rt nav", .init(busyPolls: 1, status: "0", out: "/src/acme/web\n"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())

        await rt.open(.nav, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        let split = try XCTUnwrap(world.calls("pane.split").first)
        XCTAssertEqual(FakeRtWorld.string(split["target_pane_id"]), "w1:p1")
        XCTAssertEqual(FakeRtWorld.string(split["cwd"]), "/src/acme/web")
        XCTAssertTrue(world.typed(into: "w1:p1").isEmpty)
    }

    func testAnUncleanExitHoldsTheModalOnAnExitedStripUntilClosed() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 1, status: "1"))
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(rt.modalItem?.strip, .exited(1))
        XCTAssertTrue(world.calls("tab.close").isEmpty)

        await rt.closeModal()

        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertEqual(world.calls("tab.close").count, 1)
    }

    func testARunTypesPhaseTwoAndFinishesWithItsStatus() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: rtResultLine + "\n"))
        world.script("cd '/src/acme/web' && pnpm run test", .init(busyPolls: 2, status: "0"))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.typed(into: "wF1:p1").last, #"cd '/src/acme/web' && pnpm run test; echo $? >"$FLOCK_RT_STATUS""#)
        XCTAssertEqual(rt.items["tok1"]?.title, "pnpm run test")
        XCTAssertEqual(rt.items["tok1"]?.strip, .finished(0))
        XCTAssertEqual(rt.modal?.itemID, "tok1")
    }

    func testASelfLaunchedRunFinishesWithoutAnExitStatus() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "0", out: "", afterPolls: 3))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertEqual(rt.items["tok1"]?.strip, .finished(nil))
    }

    func testACancelledRunClosesItsModal() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1, status: "1", out: ""))
        let rt = makeCoordinator(world)

        await rt.open(.run, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertNil(rt.modal)
        XCTAssertTrue(rt.items.isEmpty)
    }

    func testClosingNavEarlyShutsItDown() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.nav, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertEqual(FakeRtWorld.strings(world.calls("pane.send_keys").first?["keys"]), ["ctrl+c"])
        XCTAssertEqual(world.calls("tab.close").count, 1)
        XCTAssertTrue(rt.items.isEmpty)
    }

    func testClosingARunningRunKeepsItCountedOnTheButton() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.run, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertTrue(world.calls("tab.close").isEmpty)
        XCTAssertEqual(rt.buttonAppearance(linkedTo: RtFixture.linkedTerminal, rtInstalled: true), .active(count: 1, runner: false))
        XCTAssertEqual(rt.runRows(linkedTo: RtFixture.linkedTerminal).last, RtRunRow(id: "tok1", title: "rt run", state: "running", tone: .running))
        rt.watches["tok1"]?.cancel()
    }

    func testTheRunnerGetsItsOwnWorkspaceAndASecondOpenShowsIt() async throws {
        let world = FakeRtWorld()
        world.script("command rt runner", .init(busyPolls: 1000, status: "0", foreground: ["bun", "rt-ui"]))
        let rt = makeCoordinator(world)

        await rt.open(.runner, from: world.fixture.linkedPane)
        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.create").first?["label"]), "flock:rt runner term_a1")
        XCTAssertEqual(FakeRtWorld.string(world.calls("tab.rename").first?["label"]), "runner term_a1 tok1")
        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt runner --herdr; echo $? >"$FLOCK_RT_STATUS""#])

        await rt.closeModal()
        XCTAssertNil(rt.modal)
        XCTAssertNotNil(rt.runner(linkedTo: RtFixture.linkedTerminal))
        XCTAssertEqual(rt.buttonAppearance(linkedTo: RtFixture.linkedTerminal, rtInstalled: true), .active(count: 0, runner: true))
        XCTAssertEqual(rt.commandRows(linkedTo: RtFixture.linkedTerminal).last?.title, "Show runner")

        await rt.open(.runner, from: world.fixture.linkedPane)
        XCTAssertEqual(world.calls("workspace.create").count, 1)
        XCTAssertEqual(rt.modal?.itemID, "tok1")
        rt.watches["tok1"]?.cancel()
    }

    func testAFishShellGetsItsStatusVariable() async throws {
        let world = FakeRtWorld()
        world.shell = "fish"
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)

        XCTAssertEqual(world.typed(into: "wF1:p1"), [#"command rt glitter; echo $status >"$FLOCK_RT_STATUS""#])
        rt.watches["tok1"]?.cancel()
    }

    func testAFailedOpenLeavesNothingHalfOpenAndSaysWhy() async throws {
        let world = FakeRtWorld()
        world.failing = ["tab.rename"]
        let notices = NoticeLog()
        let rt = makeCoordinator(world, notices: notices)

        await rt.open(.nav, from: world.fixture.linkedPane)

        XCTAssertEqual(FakeRtWorld.string(world.calls("workspace.close").first?["workspace_id"]), "wF1")
        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertNil(rt.modal)
        XCTAssertEqual(notices.lines.count, 1)
    }

    func testOpeningAnotherCommandClosesTheCurrentModalByItsRules() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.nav, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        await rt.open(.glitter, from: world.fixture.linkedPane)
        await rt.settle()

        XCTAssertNil(rt.items["tok1"], "nav only lives inside the modal")
        XCTAssertEqual(rt.modal?.itemID, "tok2")
        rt.watches["tok2"]?.cancel()
    }

    /// The chrome fires `open`/`show` from detached Tasks, so two can overlap
    /// with no await between them; the modal must still settle on whichever
    /// claimed it last, with nothing orphaned outside it.
    func testOverlappingOpensLeaveExactlyOneItemClaimingTheModal() async throws {
        let world = FakeRtWorld()
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        world.script("command rt glitter", .init(busyPolls: 1000, status: "0"))
        world.script("command rt nav", .init(busyPolls: 1000, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.nav, from: world.fixture.linkedPane)
        rt.update(model: world.model())

        async let second: Void = rt.open(.glitter, from: world.fixture.linkedPane)
        async let third: Void = rt.open(.nav, from: world.fixture.linkedPane)
        _ = await (second, third)
        await rt.settle()

        let live = rt.items.values.filter { $0.kind == .nav || $0.kind == .glitter }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(rt.modal?.itemID, live.first?.id)
        for id in rt.items.keys { rt.watches[id]?.cancel() }
    }

    func testASecondRunnerOpenForTheSamePaneIsIgnoredWhileTheFirstIsInFlight() async throws {
        let world = FakeRtWorld()
        world.script("command rt runner", .init(busyPolls: 1000, status: "0", foreground: ["bun", "rt-ui"]))
        let rt = makeCoordinator(world)

        async let first: Void = rt.open(.runner, from: world.fixture.linkedPane)
        async let second: Void = rt.open(.runner, from: world.fixture.linkedPane)
        _ = await (first, second)

        XCTAssertEqual(world.calls("workspace.create").count, 1)
        rt.watches["tok1"]?.cancel()
    }

    func testAPaneHerdrStopsAnsweringForIsForgotten() async throws {
        let world = FakeRtWorld()
        world.silentPanes = ["wF1:p1"]
        let rt = makeCoordinator(world)

        await rt.open(.glitter, from: world.fixture.linkedPane)
        try await finishWatch(rt, "tok1")

        XCTAssertTrue(rt.items.isEmpty)
        XCTAssertNil(rt.modal)
        XCTAssertTrue(world.calls("tab.close").isEmpty, "nothing answers, so there is nothing to close")
    }

    /// A herdr reconnect drops an answer; a live item must outlast it.
    func testOneUnansweredPollDoesNotForgetAnItem() async throws {
        let world = FakeRtWorld()
        world.script("command rt glitter", .init(busyPolls: 3, status: "0"))
        let rt = makeCoordinator(world)
        await rt.open(.glitter, from: world.fixture.linkedPane)
        world.silentOnce = ["wF1:p1"]

        try await finishWatch(rt, "tok1")

        XCTAssertEqual(world.calls("tab.close").count, 1, "it ran to its own clean end")
    }

    func testClosingTheModalHandsHerdrsFocusToTheLinkedPane() async throws {
        let world = FakeRtWorld()
        world.script("command rt run", .init(busyPolls: 100_000, status: "0"))
        let rt = makeCoordinator(world)
        rt.update(model: world.model())
        await rt.open(.run, from: world.fixture.linkedPane)

        await rt.closeModal()

        XCTAssertEqual(FakeRtWorld.string(world.calls("pane.focus").last?["pane_id"]), "w1:p1")
        rt.watches["tok1"]?.cancel()
    }
}
