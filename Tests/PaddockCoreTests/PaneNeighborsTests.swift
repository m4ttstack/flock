import XCTest
@testable import PaddockCore

final class PaneNeighborsTests: XCTestCase {
    private func layout(_ panes: [(String, CellRect)], area: CellRect = CellRect(x: 0, y: 0, width: 80, height: 24)) -> LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false, area: area,
            focusedPaneID: panes.first.map { PaneID(rawValue: $0.0) },
            panes: panes.map { PaneRect(paneID: PaneID(rawValue: $0.0), focused: false, rect: $0.1) },
            splits: []
        )
    }

    /// Three panes across one row: left | middle | right.
    private func row() -> LayoutSnapshot {
        layout([
            ("left", CellRect(x: 0, y: 0, width: 20, height: 24)),
            ("middle", CellRect(x: 20, y: 0, width: 20, height: 24)),
            ("right", CellRect(x: 40, y: 0, width: 40, height: 24)),
        ])
    }

    func testTheNearestPaneOnEachSideAnswers() {
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "middle"), toward: .left, in: row()), PaneID(rawValue: "left"))
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "middle"), toward: .right, in: row()), PaneID(rawValue: "right"))
    }

    /// The pane two columns away must never win over the one next to it.
    func testTheNEARESTPaneWinsNotMerelyAQualifyingOne() {
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "right"), toward: .left, in: row()), PaneID(rawValue: "middle"))
    }

    func testTheEdgeOfTheRowHasNoNeighborThatWay() {
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "left"), toward: .left, in: row()))
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "right"), toward: .right, in: row()))
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "left"), toward: .up, in: row()))
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "left"), toward: .down, in: row()))
    }

    /// A pane that is beyond the edge on one axis but shares no span on the
    /// other is diagonal, not adjacent: `top-left` sits left of `bottom-right`
    /// but no part of it is beside it.
    func testADiagonalPaneIsNotANeighbor() {
        let quadrants = layout([
            ("top-left", CellRect(x: 0, y: 0, width: 40, height: 12)),
            ("bottom-right", CellRect(x: 40, y: 12, width: 40, height: 12)),
        ])

        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "bottom-right"), toward: .left, in: quadrants))
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "top-left"), toward: .right, in: quadrants))
    }

    /// A partial overlap is still adjacency: a tall pane beside two stacked
    /// ones has both to its right, and the upper one answers first.
    func testAPartialSpanOverlapCountsAndTiesBreakTowardTheTopmost() {
        let stacked = layout([
            ("tall", CellRect(x: 0, y: 0, width: 40, height: 24)),
            ("upper", CellRect(x: 40, y: 0, width: 40, height: 12)),
            ("lower", CellRect(x: 40, y: 12, width: 40, height: 12)),
        ])

        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "tall"), toward: .right, in: stacked), PaneID(rawValue: "upper"))
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "upper"), toward: .left, in: stacked), PaneID(rawValue: "tall"))
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "lower"), toward: .left, in: stacked), PaneID(rawValue: "tall"))
    }

    func testAStackResolvesUpAndDown() {
        let stack = layout([
            ("top", CellRect(x: 0, y: 0, width: 80, height: 12)),
            ("bottom", CellRect(x: 0, y: 12, width: 80, height: 12)),
        ])

        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "top"), toward: .down, in: stack), PaneID(rawValue: "bottom"))
        XCTAssertEqual(PaneNeighbors.pane(PaneID(rawValue: "bottom"), toward: .up, in: stack), PaneID(rawValue: "top"))
    }

    func testAPaneTheLayoutDoesNotCarryHasNoNeighbor() {
        XCTAssertNil(PaneNeighbors.pane(PaneID(rawValue: "ghost"), toward: .left, in: row()))
    }

    // MARK: - Targets

    /// A move lands the pane on the FAR side of its neighbor, which is the
    /// same target the equivalent drag resolves to.
    func testAMoveTargetsTheNeighborsEdgeOnTheDirectionsOwnSide() {
        XCTAssertEqual(
            PaneNeighbors.moveTarget(for: PaneID(rawValue: "middle"), toward: .left, in: row()),
            .paneEdge(PaneID(rawValue: "left"), .left)
        )
        XCTAssertEqual(
            PaneNeighbors.moveTarget(for: PaneID(rawValue: "middle"), toward: .right, in: row()),
            .paneEdge(PaneID(rawValue: "right"), .right)
        )
    }

    func testEveryDirectionMapsToItsOwnEdge() {
        XCTAssertEqual(PaneDirection.allCases.map(\.edge), [.left, .right, .top, .bottom])
    }

    func testASwapTargetsTheNeighborsInterior() {
        XCTAssertEqual(
            PaneNeighbors.swapTarget(for: PaneID(rawValue: "middle"), toward: .left, in: row()),
            .paneInterior(PaneID(rawValue: "left"))
        )
    }

    func testNoNeighborMeansNoTargetOfEitherKind() {
        XCTAssertNil(PaneNeighbors.moveTarget(for: PaneID(rawValue: "left"), toward: .left, in: row()))
        XCTAssertNil(PaneNeighbors.swapTarget(for: PaneID(rawValue: "left"), toward: .left, in: row()))
    }
}
