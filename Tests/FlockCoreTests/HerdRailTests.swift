import XCTest
@testable import FlockCore

private struct WorkspaceSpec {
    let id: String
    let label: String
    var statuses: [AgentStatus] = []
}

private func model(_ specs: [WorkspaceSpec]) -> SessionModel {
    var workspaces: [String] = []
    var panes: [String] = []
    for (index, spec) in specs.enumerated() {
        workspaces.append(
            #"{"workspace_id":"\#(spec.id)","label":"\#(spec.label)","number":\#(index + 1),"active_tab_id":"\#(spec.id):t1","agent_status":"idle"}"#
        )
        for (paneIndex, status) in spec.statuses.enumerated() {
            panes.append(
                #"{"pane_id":"\#(spec.id):p\#(paneIndex + 1)","workspace_id":"\#(spec.id)","tab_id":"\#(spec.id):t\#(paneIndex + 1)","focused":false,"agent_status":"\#(status.rawValue)","revision":0,"cwd":"/tmp"}"#
            )
        }
    }
    let json = #"""
    {"version":"0.9.0","protocol":22,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,
     "workspaces":[\#(workspaces.joined(separator: ","))],"tabs":[],"panes":[\#(panes.joined(separator: ","))],"layouts":[]}
    """#
    return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)))
}

final class HerdRailTests: XCTestCase {
    // MARK: - Worker states

    /// herdr reports a finished agent as `done` until someone looks at it and
    /// `idle` after, so both are a worker that has finished its turn.
    func testDoneAndIdleAreBothAFinishedWorker() {
        XCTAssertTrue(HerdRail.isFinishedWorker(.done))
        XCTAssertTrue(HerdRail.isFinishedWorker(.idle))
        XCTAssertFalse(HerdRail.isFinishedWorker(.working))
        XCTAssertFalse(HerdRail.isFinishedWorker(.blocked))
        XCTAssertFalse(HerdRail.isFinishedWorker(.unknown))
    }

    /// A blocked worker is waiting on the shepherd's answer, which is still a
    /// herd in motion rather than one that needs anybody else.
    func testWorkingAndBlockedAreBothAWorkerStillGoing() {
        XCTAssertTrue(HerdRail.isWorkingWorker(.working))
        XCTAssertTrue(HerdRail.isWorkingWorker(.blocked))
        XCTAssertFalse(HerdRail.isWorkingWorker(.done))
        XCTAssertFalse(HerdRail.isWorkingWorker(.idle))
        XCTAssertFalse(HerdRail.isWorkingWorker(.unknown))
    }

    // MARK: - The split

    func testHerdWorkspacesLeaveTheWorkspaceListInOrderAndEverythingElseStays() {
        let rail = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "flock"),
            WorkspaceSpec(id: "w2", label: "herd: review-shapes"),
            WorkspaceSpec(id: "w3", label: "deck"),
            WorkspaceSpec(id: "w4", label: "herd: ci-sweep"),
        ]))
        XCTAssertEqual(rail.workspaces.map(\.workspaceID.rawValue), ["w1", "w3"])
        XCTAssertEqual(rail.herds.map(\.workspaceID.rawValue), ["w2", "w4"])
    }

    func testAHerdIsNamedByItsIdAlone() {
        let rail = HerdRail(model: model([WorkspaceSpec(id: "w1", label: "herd: review-shapes-20260922")]))
        XCTAssertEqual(rail.herds.first?.name, "review-shapes-20260922")
    }

    /// The shape rt's `mintHerdId` produces. The stamp is there for
    /// uniqueness and was most of what showed at rail width.
    func testTheMintedStampIsDropped() {
        let rail = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes-20260922-093843"),
            WorkspaceSpec(id: "w2", label: "herd: acme-batch-20260922-112541"),
        ]))
        XCTAssertEqual(rail.herds.map(\.name), ["review-shapes", "acme-batch"])
    }

    /// rt appends -N when a minted id is already taken.
    func testTheCollisionSuffixGoesWithTheStamp() {
        let rail = HerdRail(model: model([WorkspaceSpec(id: "w1", label: "herd: ci-sweep-20260922-093843-2")]))
        XCTAssertEqual(rail.herds.first?.name, "ci-sweep")
    }

    /// Only the exact minted suffix is taken off; a name that simply ends in
    /// digits keeps them.
    func testANameThatOnlyLooksStampedIsLeftAlone() {
        let rail = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: build-2026"),
            WorkspaceSpec(id: "w2", label: "herd: review-shapes-20260922"),
        ]))
        XCTAssertEqual(rail.herds.map(\.name), ["build-2026", "review-shapes-20260922"])
    }

    /// Two runs of one herd would read identically without their stamps, so
    /// those two, and only those, keep their start time.
    func testHerdsSharingANameKeepTheirStartTime() {
        let rail = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes-20260922-093843"),
            WorkspaceSpec(id: "w2", label: "herd: review-shapes-20260922-141005"),
            WorkspaceSpec(id: "w3", label: "herd: ci-sweep-20260922-112541"),
        ]))
        XCTAssertEqual(rail.herds.map(\.name), ["review-shapes 09:38", "review-shapes 14:10", "ci-sweep"])
    }

    func testNoHerdsMeansNoSection() {
        let rail = HerdRail(model: model([WorkspaceSpec(id: "w1", label: "flock", statuses: [.blocked])]))
        XCTAssertTrue(rail.herds.isEmpty)
        XCTAssertNil(rail.summary)
    }

    // MARK: - One herd

    func testAHerdCountsItsFinishedWorkersOutOfAllItsPanes() {
        let herd = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes", statuses: [.done, .idle, .working, .blocked, .working]),
        ])).herds[0]
        XCTAssertEqual(herd.done, 2)
        XCTAssertEqual(herd.total, 5)
        XCTAssertTrue(herd.isRunning)
        XCTAssertFalse(herd.isFinished)
    }

    func testAHerdWhoseEveryWorkerHasFinishedIsFinishedAndStill() {
        let herd = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: acme-sweep", statuses: [.done, .done, .idle]),
        ])).herds[0]
        XCTAssertEqual(herd.done, 3)
        XCTAssertEqual(herd.total, 3)
        XCTAssertFalse(herd.isRunning)
        XCTAssertTrue(herd.isFinished)
    }

    /// Only the herd's own panes count: a busy pane next door must not move
    /// this herd's mark or its tally.
    func testAHerdCountsOnlyThePanesInItsOwnWorkspace() {
        let herd = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "flock", statuses: [.working, .blocked]),
            WorkspaceSpec(id: "w2", label: "herd: ci-sweep", statuses: [.done]),
        ])).herds[0]
        XCTAssertEqual(herd.done, 1)
        XCTAssertEqual(herd.total, 1)
        XCTAssertFalse(herd.isRunning)
        XCTAssertTrue(herd.isFinished)
    }

    /// A pane nothing is detected in never finishes, so it holds the herd
    /// open without making it look busy.
    func testAPaneWithNoAgentHoldsTheHerdOpenWithoutMovingIt() {
        let herd = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: ci-sweep", statuses: [.done, .unknown]),
        ])).herds[0]
        XCTAssertEqual(herd.done, 1)
        XCTAssertEqual(herd.total, 2)
        XCTAssertFalse(herd.isRunning)
        XCTAssertFalse(herd.isFinished)
    }

    /// A workspace that has no panes yet has not finished anything.
    func testAHerdWithNoPanesYetIsNotFinished() {
        let herd = HerdRail(model: model([WorkspaceSpec(id: "w1", label: "herd: ci-sweep")])).herds[0]
        XCTAssertEqual(herd.total, 0)
        XCTAssertFalse(herd.isFinished)
        XCTAssertFalse(herd.isRunning)
    }

    // MARK: - rt's count

    /// herdr sees four idle panes; rt knows only one worker has reported.
    /// A worker that has not started reads idle, so the panes alone would
    /// call this herd finished before it had done anything.
    func testRtsCountOutranksThePanes() {
        let herd = HerdRail(
            model: model([WorkspaceSpec(id: "w1", label: "herd: acme-sweep", statuses: [.idle, .idle, .idle, .idle])]),
            progress: ["herd: acme-sweep": HerdProgress(done: 1, total: 4, isRunning: true)]
        ).herds[0]
        XCTAssertEqual(herd.done, 1)
        XCTAssertEqual(herd.total, 4)
        XCTAssertTrue(herd.isRunning)
        XCTAssertFalse(herd.isFinished)
    }

    func testAHerdRtHasNotAnsweredForIsCountedFromItsPanes() {
        let rail = HerdRail(
            model: model([
                WorkspaceSpec(id: "w1", label: "herd: acme-sweep", statuses: [.done]),
                WorkspaceSpec(id: "w2", label: "herd: ci-sweep", statuses: [.done, .working]),
            ]),
            progress: ["herd: acme-sweep": HerdProgress(done: 0, total: 3, isRunning: true)]
        )
        XCTAssertEqual(rail.herds.map(\.done), [0, 1])
        XCTAssertEqual(rail.herds.map(\.total), [3, 2])
    }

    // MARK: - The header summary

    func testTheSummaryCountsHerdsNotWorkers() {
        let summary = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes", statuses: [.working, .working, .done]),
            WorkspaceSpec(id: "w2", label: "herd: ci-sweep", statuses: [.done, .working]),
            WorkspaceSpec(id: "w3", label: "herd: acme-sweep", statuses: [.done, .done, .done, .done]),
        ])).summary
        XCTAssertEqual(summary?.running, 2)
        XCTAssertEqual(summary?.done, 1)
        XCTAssertEqual(summary?.isAnyRunning, true)
        XCTAssertEqual(summary?.text, "1/3 done")
    }

    func testEveryHerdDoneReadsOnlyDoneAndStops() {
        let summary = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes", statuses: [.done]),
            WorkspaceSpec(id: "w2", label: "herd: ci-sweep", statuses: [.idle, .done]),
        ])).summary
        XCTAssertEqual(summary?.text, "2/2 done")
        XCTAssertEqual(summary?.isAnyRunning, false)
    }

    func testNoHerdDoneYetReadsOnlyRunning() {
        let summary = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes", statuses: [.working]),
        ])).summary
        XCTAssertEqual(summary?.text, "0/1 done")
        XCTAssertEqual(summary?.isAnyRunning, true)
    }

    /// A herd held open by a pane with no agent still counts as running,
    /// while the mark stays still because nothing in it is working.
    func testAnOpenHerdWithNothingWorkingIsRunningButStill() {
        let summary = HerdRail(model: model([
            WorkspaceSpec(id: "w1", label: "herd: review-shapes", statuses: [.done, .unknown]),
        ])).summary
        XCTAssertEqual(summary?.running, 1)
        XCTAssertEqual(summary?.isAnyRunning, false)
    }

    // MARK: - Lookup by id

    func testAWorkspaceIsAHerdByItsLabel() {
        let full = model([
            WorkspaceSpec(id: "w1", label: "flock"),
            WorkspaceSpec(id: "w2", label: "herd: review-shapes"),
        ])
        XCTAssertFalse(HerdWorkspace.isHerd(WorkspaceID(rawValue: "w1"), in: full))
        XCTAssertTrue(HerdWorkspace.isHerd(WorkspaceID(rawValue: "w2"), in: full))
        XCTAssertFalse(HerdWorkspace.isHerd(WorkspaceID(rawValue: "w9"), in: full))
    }
}
