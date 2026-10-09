import XCTest
@testable import FlockCore

final class CloseFocusTests: XCTestCase {
    private func pane(_ id: String, tab: String) -> PaneRecord {
        PaneRecord(
            paneID: PaneID(rawValue: id), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: tab),
            focused: false, agentStatus: .idle, revision: 0, terminalTitleStripped: nil, label: nil, cwd: "/tmp", scroll: nil
        )
    }

    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CellRect {
        CellRect(x: x, y: y, width: w, height: h)
    }

    /// t1: p1 on the left half; the right half split into p2 above p3.
    /// t2: p4 alone.
    private func fixture() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [WorkspaceRecord(
                workspaceID: WorkspaceID(rawValue: "w1"), label: "one", number: 1, activeTabID: TabID(rawValue: "t1"), agentStatus: .idle
            )],
            tabs: [
                TabRecord(tabID: TabID(rawValue: "t1"), workspaceID: WorkspaceID(rawValue: "w1"), label: "1", number: 1, paneCount: 3, agentStatus: .idle),
                TabRecord(tabID: TabID(rawValue: "t2"), workspaceID: WorkspaceID(rawValue: "w1"), label: "2", number: 2, paneCount: 1, agentStatus: .idle),
            ],
            panes: [pane("p1", tab: "t1"), pane("p2", tab: "t1"), pane("p3", tab: "t1"), pane("p4", tab: "t2")],
            layouts: [
                LayoutSnapshot(
                    workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "t1"), zoomed: false, area: rect(0, 0, 80, 24),
                    focusedPaneID: nil,
                    panes: [
                        PaneRect(paneID: PaneID(rawValue: "p1"), focused: false, rect: rect(0, 0, 40, 24)),
                        PaneRect(paneID: PaneID(rawValue: "p2"), focused: false, rect: rect(40, 0, 40, 12)),
                        PaneRect(paneID: PaneID(rawValue: "p3"), focused: false, rect: rect(40, 12, 40, 12)),
                    ],
                    splits: [
                        SplitInfo(id: "s1", direction: .right, ratio: 0.5, rect: rect(0, 0, 80, 24)),
                        SplitInfo(id: "s2", direction: .down, ratio: 0.5, rect: rect(40, 0, 40, 24)),
                    ]
                ),
                LayoutSnapshot(
                    workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "t2"), zoomed: false, area: rect(0, 0, 80, 24),
                    focusedPaneID: nil,
                    panes: [PaneRect(paneID: PaneID(rawValue: "p4"), focused: false, rect: rect(0, 0, 80, 24))],
                    splits: []
                ),
            ]
        ))
    }

    func testAFirstChildHandsFocusToTheNearestPaneAcrossItsDivider() {
        XCTAssertEqual(CloseFocus.successor(of: PaneID(rawValue: "p1"), model: fixture()), PaneID(rawValue: "p2"))
    }

    func testASecondChildHandsFocusToItsSiblingPane() {
        XCTAssertEqual(CloseFocus.successor(of: PaneID(rawValue: "p3"), model: fixture()), PaneID(rawValue: "p2"))
        XCTAssertEqual(CloseFocus.successor(of: PaneID(rawValue: "p2"), model: fixture()), PaneID(rawValue: "p3"))
    }

    func testATabsOnlyPaneHasNoSuccessor() {
        XCTAssertNil(CloseFocus.successor(of: PaneID(rawValue: "p4"), model: fixture()))
    }
}
