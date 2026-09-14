import XCTest
import CoreGraphics
@testable import PaddockCore

final class DropPreviewTests: XCTestCase {
    private static let p1 = PaneID(rawValue: "w1:p1")
    private static let p2 = PaneID(rawValue: "w1:p2")
    private static let p3 = PaneID(rawValue: "w1:p3")
    private static let visitor = PaneID(rawValue: "w2:v1")
    private static let tabID = TabID(rawValue: "w1:t1")
    private static let area = CellRect(x: 0, y: 0, width: 80, height: 40)

    private func leaf(_ pane: PaneID) -> ExportedLayoutNode {
        .pane(ExportedLayoutPane(paneID: pane))
    }

    /// p1 on the left half, p2 over p3 stacked on the right half.
    private var root: ExportedLayoutNode {
        .split(
            direction: .right, ratio: 0.5,
            first: leaf(Self.p1),
            second: .split(direction: .down, ratio: 0.5, first: leaf(Self.p2), second: leaf(Self.p3))
        )
    }

    private func panes(of node: ExportedLayoutNode) -> [PaneID] {
        switch node {
        case .pane(let leaf): return leaf.paneID.map { [$0] } ?? []
        case .split(_, _, let first, let second): return panes(of: first) + panes(of: second)
        }
    }

    private func frames(_ node: ExportedLayoutNode, canvas: CGSize = CGSize(width: 800, height: 400)) -> [PaneID: CGRect] {
        CanvasGeometry(
            exportedRoot: node, area: Self.area, tabID: Self.tabID,
            grid: CanvasGrid(canvas: canvas, displayScale: 2)
        ).paneFrames
    }

    // MARK: - Edge drops

    func testEdgeDropCollapsesTheSplitTheDraggedPaneLeavesBehind() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.p3, onto: .paneEdge(Self.p1, .left)))
        XCTAssertEqual(panes(of: preview), [Self.p3, Self.p1, Self.p2])
    }

    func testLeftEdgeDropPutsTheIncomingPaneOnTheTargetsLeftHalf() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.p3, onto: .paneEdge(Self.p1, .left)))
        let rects = frames(preview)
        let incoming = try XCTUnwrap(rects[Self.p3])
        let target = try XCTUnwrap(rects[Self.p1])
        XCTAssertEqual(incoming.minX, 0, accuracy: 1)
        XCTAssertEqual(incoming.width, 200, accuracy: 1)
        XCTAssertEqual(target.minX, incoming.maxX, accuracy: 1)
        // p2 inherits the whole right half its split with p3 collapsed into.
        XCTAssertEqual(try XCTUnwrap(rects[Self.p2]).height, 400, accuracy: 1)
    }

    func testBottomEdgeDropPutsTheIncomingPaneUnderTheTarget() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.p1, onto: .paneEdge(Self.p2, .bottom)))
        let rects = frames(preview)
        let incoming = try XCTUnwrap(rects[Self.p1])
        let target = try XCTUnwrap(rects[Self.p2])
        XCTAssertEqual(target.maxY, incoming.minY, accuracy: 1)
        XCTAssertEqual(incoming.width, target.width, accuracy: 1)
    }

    func testEdgeDropFromAnotherTabLandsWithoutLiftingAnything() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.visitor, onto: .paneEdge(Self.p1, .right)))
        XCTAssertEqual(panes(of: preview), [Self.p1, Self.visitor, Self.p2, Self.p3])
    }

    func testEdgeDropOntoItselfPreviewsNothing() {
        XCTAssertNil(DropPreview.root(root, dropping: Self.p1, onto: .paneEdge(Self.p1, .left)))
    }

    /// Lifting the pane empties the tree and the target was never in it:
    /// nothing is left to preview against.
    func testEdgeDropThatWouldEmptyTheTreePreviewsNothing() {
        XCTAssertNil(DropPreview.root(leaf(Self.p1), dropping: Self.p1, onto: .paneEdge(Self.p2, .left)))
    }

    // MARK: - Interior drops

    func testInteriorDropInTheSameTabSwapsThePanes() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.p3, onto: .paneInterior(Self.p1)))
        XCTAssertEqual(panes(of: preview), [Self.p3, Self.p2, Self.p1])
    }

    func testInteriorDropFromAnotherTabTakesTheTargetsPlace() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.visitor, onto: .paneInterior(Self.p2)))
        XCTAssertEqual(panes(of: preview), [Self.p1, Self.visitor, Self.p3])
    }

    func testInteriorDropOntoItselfPreviewsNothing() {
        XCTAssertNil(DropPreview.root(root, dropping: Self.p1, onto: .paneInterior(Self.p1)))
    }

    func testNonCanvasTargetsPreviewNothing() {
        XCTAssertNil(DropPreview.root(root, dropping: Self.p1, onto: .newWorkspace))
        XCTAssertNil(DropPreview.root(root, dropping: Self.p1, onto: .tabThumbnail(Self.tabID)))
        XCTAssertNil(DropPreview.root(root, dropping: Self.p1, onto: .workspaceRail(insertIndex: 0)))
    }

    // MARK: - Incoming rect

    func testIncomingRectTakesTheNamedHalfOfTheTargetFrame() {
        let frame = CGRect(x: 100, y: 50, width: 400, height: 200)
        XCTAssertEqual(DropPreview.incomingRect(in: frame, edge: .left), CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertEqual(DropPreview.incomingRect(in: frame, edge: .right), CGRect(x: 300, y: 50, width: 200, height: 200))
        XCTAssertEqual(DropPreview.incomingRect(in: frame, edge: .top), CGRect(x: 100, y: 50, width: 400, height: 100))
        XCTAssertEqual(DropPreview.incomingRect(in: frame, edge: .bottom), CGRect(x: 100, y: 150, width: 400, height: 100))
    }

    // MARK: - Target rect

    private func surfaces() -> DropSurfaces {
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: Self.tabID, zoomed: false, area: Self.area,
            focusedPaneID: Self.p1,
            panes: [
                PaneRect(paneID: Self.p1, focused: true, rect: CellRect(x: 0, y: 0, width: 40, height: 40)),
                PaneRect(paneID: Self.p2, focused: false, rect: CellRect(x: 40, y: 0, width: 40, height: 40))
            ],
            splits: []
        )
        return DropSurfaces(
            canvas: CanvasGeometry(layout: layout, grid: CanvasGrid(canvas: CGSize(width: 800, height: 400), displayScale: 2)),
            stripWorkspace: WorkspaceID(rawValue: "w1"),
            tabFrames: [TabItemFrame(id: Self.tabID, frame: CGRect(x: 12, y: 7, width: 100, height: 28))],
            workspaceFrames: [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 8, y: 40, width: 200, height: 30))],
            stripFrame: CGRect(x: 0, y: 0, width: 600, height: 42),
            railFrame: CGRect(x: 0, y: 0, width: 216, height: 700),
            newTabZone: CGRect(x: 400, y: 0, width: 100, height: 42),
            newWorkspaceZone: CGRect(x: 0, y: 200, width: 216, height: 400)
        )
    }

    func testTargetRectForAnEdgeDropIsTheHalfThePaneWouldTake() throws {
        let rect = try XCTUnwrap(dropTargetRect(for: .paneEdge(Self.p2, .right), surfaces: surfaces()))
        XCTAssertEqual(rect.minX, 600, accuracy: 1)
        XCTAssertEqual(rect.width, 200, accuracy: 1)
    }

    func testTargetRectForAnInteriorDropIsTheWholePane() throws {
        let rect = try XCTUnwrap(dropTargetRect(for: .paneInterior(Self.p1), surfaces: surfaces()))
        XCTAssertEqual(rect.width, 400, accuracy: 1)
    }

    func testTargetRectForAStripInsertIsTheInsertionBar() throws {
        let rect = try XCTUnwrap(dropTargetRect(for: .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 1), surfaces: surfaces()))
        XCTAssertEqual(rect.width, InsertionBarGeometry.thickness)
    }

    func testTargetRectForZonesAndThumbnails() throws {
        XCTAssertEqual(try XCTUnwrap(dropTargetRect(for: .newTab(WorkspaceID(rawValue: "w1")), surfaces: surfaces())).minX, 400)
        XCTAssertEqual(try XCTUnwrap(dropTargetRect(for: .newWorkspace, surfaces: surfaces())).minY, 200)
        XCTAssertEqual(try XCTUnwrap(dropTargetRect(for: .tabThumbnail(Self.tabID), surfaces: surfaces())).minX, 12)
        XCTAssertEqual(try XCTUnwrap(dropTargetRect(for: .workspaceThumbnail(WorkspaceID(rawValue: "w1")), surfaces: surfaces())).minY, 40)
    }

    func testTargetRectIsNilForSomethingNotOnScreen() {
        XCTAssertNil(dropTargetRect(for: .tabThumbnail(TabID(rawValue: "w9:t9")), surfaces: surfaces()))
    }
}
