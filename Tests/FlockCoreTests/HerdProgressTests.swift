import XCTest
@testable import FlockCore

final class HerdProgressTests: XCTestCase {
    private func status(_ jobs: [String]) -> Data {
        let rows = jobs.enumerated().map { index, status in
            #"{"herd":"acme-sweep-20260922-081502","name":"job-\#(index)","pane":"w9:p\#(index + 1)","status":"\#(status)","openGate":null}"#
        }
        return Data(#"{"herd":{"id":"acme-sweep-20260922-081502","workspace":"herd: acme-sweep-20260922-081502","status":"active"},"jobs":[\#(rows.joined(separator: ","))]}"#.utf8)
    }

    // MARK: - Job states

    func testAReportedOrClosedJobIsFinished() {
        XCTAssertTrue(HerdProgress.isFinished(jobStatus: "done"))
        XCTAssertTrue(HerdProgress.isFinished(jobStatus: "closed"))
        for status in ["spawning", "active", "at-gate", "at-milestone", "stuck-at-modal", "crashed"] {
            XCTAssertFalse(HerdProgress.isFinished(jobStatus: status), status)
        }
    }

    /// A worker waiting on its shepherd, at a gate or a milestone, is a herd
    /// still in motion.
    func testEveryLiveJobStateIsRunning() {
        for status in ["spawning", "active", "at-gate", "at-milestone", "stuck-at-modal"] {
            XCTAssertTrue(HerdProgress.isRunning(jobStatus: status), status)
        }
        for status in ["done", "closed", "crashed"] {
            XCTAssertFalse(HerdProgress.isRunning(jobStatus: status), status)
        }
    }

    // MARK: - rt herd status

    func testCountsReportedWorkersOutOfEveryWorker() {
        let progress = HerdProgress.fromHerdStatus(stdout: status(["done", "active", "closed", "at-gate"]))
        XCTAssertEqual(progress, HerdProgress(done: 2, total: 4, isRunning: true))
    }

    /// Closing a reported worker's pane moves it to `closed`, and it still
    /// counts: 4/4 means four reports, not four panes still open.
    func testClosedWorkersStillCountAsReported() {
        let progress = HerdProgress.fromHerdStatus(stdout: status(["closed", "done", "closed", "closed"]))
        XCTAssertEqual(progress, HerdProgress(done: 4, total: 4, isRunning: false))
    }

    func testACrashedWorkerKeepsTheHerdFromReadingComplete() {
        let progress = HerdProgress.fromHerdStatus(stdout: status(["done", "crashed"]))
        XCTAssertEqual(progress, HerdProgress(done: 1, total: 2, isRunning: false))
    }

    func testAHerdWithNoJobsYetIsZeroOfZero() {
        XCTAssertEqual(HerdProgress.fromHerdStatus(stdout: status([])), HerdProgress(done: 0, total: 0, isRunning: false))
    }

    func testAnythingButTheStatusEnvelopeIsNoAnswer() {
        XCTAssertNil(HerdProgress.fromHerdStatus(stdout: Data("unknown herd".utf8)))
        XCTAssertNil(HerdProgress.fromHerdStatus(stdout: Data(#"{"ok":false,"error":"herd not found"}"#.utf8)))
        XCTAssertNil(HerdProgress.fromHerdStatus(stdout: Data()))
    }

    // MARK: - rt herd list

    func testListPairsEachHerdIdWithItsWorkspaceLabel() {
        let stdout = Data(#"""
        {"herds":[
          {"id":"acme-sweep-20260922-081502","workspace":"herd: acme-sweep-20260922-081502","status":"active","jobs":4},
          {"id":"ci-sweep-20260922-112541","workspace":"herd: ci-sweep-20260922-112541","status":"active","jobs":2}
        ]}
        """#.utf8)
        XCTAssertEqual(ListedHerd.fromHerdList(stdout: stdout), [
            ListedHerd(id: "acme-sweep-20260922-081502", workspaceLabel: "herd: acme-sweep-20260922-081502"),
            ListedHerd(id: "ci-sweep-20260922-112541", workspaceLabel: "herd: ci-sweep-20260922-112541"),
        ])
    }

    func testAnEmptyListIsNoHerdsAndGarbageIsNoAnswer() {
        XCTAssertEqual(ListedHerd.fromHerdList(stdout: Data(#"{"herds":[]}"#.utf8)), [])
        XCTAssertNil(ListedHerd.fromHerdList(stdout: Data("not json".utf8)))
    }
}
