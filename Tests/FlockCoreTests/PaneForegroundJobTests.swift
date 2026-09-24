import XCTest
@testable import FlockCore

/// `pane.process_info` answers, shaped as herdr 0.9 sends them
/// (`PaneProcessInfo` in its api schema), reduced to the one question the
/// launcher asks: is anything but the shell in the pane's foreground?
final class PaneForegroundJobTests: XCTestCase {
    func testAShellAloneAtItsPromptIsIdle() {
        let data = Data(#"""
        {"id":"1","result":{"process_info":{"foreground_process_group_id":92134,"foreground_processes":[{"argv":["-zsh"],"argv0":"zsh","cmdline":"-zsh","cwd":"/Users/acme/src","name":"zsh","pid":92134}],"pane_id":"w1:p2","shell_pid":92134},"type":"pane_process_info"}}
        """#.utf8)

        XCTAssertEqual(PaneForegroundJob.isBusy(processInfoResponse: data), false)
    }

    /// A picker run from a shell function: the job has its own process group
    /// and the shell is not in the list at all.
    func testAPickerInItsOwnProcessGroupIsBusy() {
        let data = Data(#"""
        {"id":"1","result":{"process_info":{"foreground_process_group_id":39231,"foreground_processes":[{"argv":["/opt/rt/rt-ui","pick"],"argv0":"rt-ui","name":"rt-ui","pid":39248},{"argv0":"bun","name":"bun","pid":39231}],"pane_id":"w1:p2","shell_pid":39003},"type":"pane_process_info"}}
        """#.utf8)

        XCTAssertEqual(PaneForegroundJob.isBusy(processInfoResponse: data), true)
    }

    /// A command substitution a shell runs without job control shares the
    /// shell's own group, so the group id alone would read as idle.
    func testAChildSharingTheShellsProcessGroupIsBusy() {
        let data = Data(#"""
        {"id":"1","result":{"process_info":{"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500},{"name":"fzf","pid":512}],"pane_id":"w1:p2","shell_pid":500},"type":"pane_process_info"}}
        """#.utf8)

        XCTAssertEqual(PaneForegroundJob.isBusy(processInfoResponse: data), true)
    }

    /// herdr drops an empty process list from the wire; the group id is then
    /// all there is to go on.
    func testWithNoProcessListTheGroupIdDecides() {
        let idle = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":500}}}"#.utf8)
        let busy = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731}}}"#.utf8)

        XCTAssertEqual(PaneForegroundJob.isBusy(processInfoResponse: idle), false)
        XCTAssertEqual(PaneForegroundJob.isBusy(processInfoResponse: busy), true)
    }

    func testAnAnswerThatCannotTellHasNoVerdict() {
        let noShell = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","foreground_process_group_id":731}}}"#.utf8)
        let error = Data(#"{"id":"1","error":{"code":"pane_not_found","message":"no such pane"}}"#.utf8)

        XCTAssertNil(PaneForegroundJob.isBusy(processInfoResponse: noShell))
        XCTAssertNil(PaneForegroundJob.isBusy(processInfoResponse: error))
        XCTAssertNil(PaneForegroundJob.isBusy(processInfoResponse: Data("{}".utf8)))
    }

    func testTheSnapshotNamesTheShellAndWhatElseHoldsTheForeground() throws {
        let idle = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"fish","pid":500}]}}}"#.utf8)
        let busy = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731,"foreground_processes":[{"name":"bun","pid":731},{"name":"rt-ui","pid":740}]}}}"#.utf8)

        let idleSnapshot = try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: idle))
        XCTAssertFalse(idleSnapshot.busy)
        XCTAssertEqual(idleSnapshot.shellName, "fish")
        XCTAssertEqual(idleSnapshot.foregroundNames, [])

        let busySnapshot = try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: busy))
        XCTAssertTrue(busySnapshot.busy)
        XCTAssertNil(busySnapshot.shellName)
        XCTAssertEqual(busySnapshot.foregroundNames, ["bun", "rt-ui"])
    }

    /// The group holds the agent and its children, listed in no useful order,
    /// the children often working elsewhere: only the leader's folder is the
    /// agent's.
    func testTheSnapshotCarriesTheForegroundGroupLeadersFolder() throws {
        let idle = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":500,"foreground_processes":[{"name":"zsh","pid":500,"cwd":"/Users/acme/src/tools"}]}}}"#.utf8)
        let agent = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731,"foreground_processes":[{"name":"caffeinate","pid":740,"cwd":"/Users/acme/src/tools"},{"name":"node","pid":741,"cwd":"/Users/acme/src/tools"},{"name":"claude","pid":731,"cwd":"/Users/acme/src/flock"}]}}}"#.utf8)
        let noLeader = Data(#"{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":500,"foreground_process_group_id":731,"foreground_processes":[{"name":"node","pid":741,"cwd":"/Users/acme/src/tools"}]}}}"#.utf8)

        XCTAssertEqual(try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: idle)).leaderCwd, "/Users/acme/src/tools")
        XCTAssertEqual(try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: agent)).leaderCwd, "/Users/acme/src/flock")
        XCTAssertNil(try XCTUnwrap(PaneForegroundJob.snapshot(processInfoResponse: noLeader)).leaderCwd)
    }
}
