import XCTest
import CoreGraphics
@testable import FlockCore

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

    /// From another tab there is no leaf to trade with, and the plan is not a
    /// swap either: `planPaneInterior` sends a `pane.move` naming the target
    /// pane, which divides that pane's own region and keeps the target first.
    /// A preview that replaced the target would promise the target's
    /// disappearance, which no drop ever performs.
    func testInteriorDropFromAnotherTabDividesTheTargetsRegion() throws {
        let preview = try XCTUnwrap(DropPreview.root(root, dropping: Self.visitor, onto: .paneInterior(Self.p2)))
        XCTAssertEqual(panes(of: preview), [Self.p1, Self.p2, Self.visitor, Self.p3])
        XCTAssertEqual(
            preview, DropPreview.root(root, dropping: Self.visitor, onto: .paneEdge(Self.p2, .right)),
            "the same split the plan's own pane.move makes"
        )
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

    // MARK: - Previewed frames

    /// The same three panes as `root`, as a `LayoutSnapshot` (p1 left half,
    /// p2 top right, p3 bottom right of an 80x40 cell area).
    private var snapshot: LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: Self.tabID, zoomed: false, area: Self.area,
            focusedPaneID: Self.p1,
            panes: [
                PaneRect(paneID: Self.p1, focused: true, rect: CellRect(x: 0, y: 0, width: 40, height: 40)),
                PaneRect(paneID: Self.p2, focused: false, rect: CellRect(x: 40, y: 0, width: 40, height: 20)),
                PaneRect(paneID: Self.p3, focused: false, rect: CellRect(x: 40, y: 20, width: 40, height: 20))
            ],
            splits: []
        )
    }

    private var exported: ExportedLayoutDescription {
        ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: Self.tabID, zoomed: false,
            focusedPaneID: Self.p1, root: root
        )
    }

    private var canvasGrid: CanvasGrid {
        CanvasGrid(canvas: CGSize(width: 800, height: 400), displayScale: 2)
    }

    /// A zoomed tab shows one pane over the whole canvas, and the drop was
    /// hit-tested against exactly that. The wash has to land in the same
    /// geometry: laid out from the post-drop split tree instead, it would take
    /// the target's TILED half (p1's left half of the canvas, 194pt) and paint
    /// part of it over panes the zoom is holding closed.
    func testAZoomedCanvasPreviewsInsideTheOnePaneItIsShowing() throws {
        let zoomed = LayoutSnapshot(
            workspaceID: snapshot.workspaceID, tabID: snapshot.tabID, zoomed: true, area: snapshot.area,
            focusedPaneID: Self.p1, panes: snapshot.panes, splits: snapshot.splits
        )
        let preview = try XCTUnwrap(DropPreview.frames(
            target: .paneEdge(Self.p1, .left), dragging: .pane(Self.p3), layout: zoomed,
            exported: exported, grid: canvasGrid, dividerThickness: 6,
            composition: CanvasComposition.of(layout: zoomed)
        ))

        // Half of the whole 800pt canvas, less the box's own gutter.
        XCTAssertEqual(preview.incoming.minX, 3, accuracy: 1)
        XCTAssertEqual(preview.incoming.width, 394, accuracy: 1)
        XCTAssertEqual(preview.incoming.height, 394, accuracy: 1, "the wash is short of the canvas the zoomed pane fills")
    }

    func testPreviewedIncomingRectIsTheDroppedPanesNewHalf() throws {
        let preview = try XCTUnwrap(DropPreview.frames(
            target: .paneEdge(Self.p1, .left), dragging: .pane(Self.p3), layout: snapshot,
            exported: exported, grid: canvasGrid, dividerThickness: 6
        ))
        // 200pt half of the 800pt canvas, less the pane box's own gutter.
        XCTAssertEqual(preview.incoming.width, 194, accuracy: 1)
        XCTAssertEqual(preview.incoming.minX, 3, accuracy: 1)
    }

    /// No export cached for this tab: the incoming rect is still derived from
    /// the target's own frame, and nothing else is guessed at.
    func testPreviewedFramesFallBackToTheTargetHalfWithNoExportedTree() throws {
        let preview = try XCTUnwrap(DropPreview.frames(
            target: .paneEdge(Self.p2, .bottom), dragging: .pane(Self.p1), layout: snapshot,
            exported: nil, grid: canvasGrid, dividerThickness: 6
        ))
        // The bottom half of p2's 400pt column, inset by the gutter ONCE.
        XCTAssertEqual(preview.incoming.minY, 103, accuracy: 1)
        XCTAssertEqual(preview.incoming.height, 94, accuracy: 1)
    }

    func testPreviewedFramesAreNilForATabDrag() {
        XCTAssertNil(DropPreview.frames(
            target: .paneInterior(Self.p1), dragging: .tab(Self.tabID), layout: snapshot,
            exported: exported, grid: canvasGrid, dividerThickness: 6
        ))
    }

    func testPreviewedFramesAreNilWithNoTarget() {
        XCTAssertNil(DropPreview.frames(
            target: nil, dragging: .pane(Self.p1), layout: snapshot,
            exported: exported, grid: canvasGrid, dividerThickness: 6
        ))
    }

    func testPreviewedFramesAreNilForADropOntoItself() {
        XCTAssertNil(DropPreview.frames(
            target: .paneInterior(Self.p1), dragging: .pane(Self.p1), layout: snapshot,
            exported: exported, grid: canvasGrid, dividerThickness: 6
        ))
    }

    func testPreviewedFramesFallBackToTheWholeTargetForAnInteriorDrop() throws {
        let preview = try XCTUnwrap(DropPreview.frames(
            target: .paneInterior(Self.p2), dragging: .pane(Self.p1), layout: snapshot,
            exported: nil, grid: canvasGrid, dividerThickness: 6
        ))
        XCTAssertEqual(preview.incoming.minX, 403, accuracy: 1)
        XCTAssertEqual(preview.incoming.width, 394, accuracy: 1)
    }

    /// An export cached for a DIFFERENT tab is not this tab's tree, so the
    /// fallback runs rather than a layout from the wrong tab being drawn.
    func testAnExportForAnotherTabIsIgnored() throws {
        let other = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t9"), zoomed: false,
            focusedPaneID: Self.p1, root: root
        )
        let preview = try XCTUnwrap(DropPreview.frames(
            target: .paneInterior(Self.p2), dragging: .pane(Self.p1), layout: snapshot,
            exported: other, grid: canvasGrid, dividerThickness: 6
        ))
    }

    /// A degenerate cell area lays nothing out, so the transformed tree yields
    /// no frame for the incoming pane and there is nothing to preview.
    func testPreviewedFramesAreNilWhenTheTransformedTreeLaysOutNothing() {
        let degenerate = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: Self.tabID, zoomed: false,
            area: CellRect(x: 0, y: 0, width: 0, height: 40), focusedPaneID: Self.p1, panes: [], splits: []
        )
        XCTAssertNil(DropPreview.frames(
            target: .paneEdge(Self.p1, .left), dragging: .pane(Self.p3), layout: degenerate,
            exported: exported, grid: canvasGrid, dividerThickness: 6
        ))
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

    // MARK: - Flash rect

    func testAnInsertionBarHasNoFlashRegion() {
        XCTAssertNil(dropFlashRect(for: .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 1), surfaces: surfaces()))
        XCTAssertNil(dropFlashRect(for: .workspaceRail(insertIndex: 1), surfaces: surfaces()))
    }

    func testEveryOtherTargetFlashesWhereItLands() throws {
        for target in [
            DropTarget.paneInterior(Self.p1),
            .paneEdge(Self.p2, .right),
            .tabThumbnail(Self.tabID),
            .workspaceThumbnail(WorkspaceID(rawValue: "w1")),
            .newTab(WorkspaceID(rawValue: "w1")),
            .newWorkspace
        ] {
            XCTAssertEqual(
                dropFlashRect(for: target, surfaces: surfaces()),
                dropTargetRect(for: target, surfaces: surfaces()),
                "\(target)"
            )
        }
    }
}
