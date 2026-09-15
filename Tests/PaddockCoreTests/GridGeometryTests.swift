import CoreGraphics
import XCTest
@testable import PaddockCore

final class GridGeometryTests: XCTestCase {
    private let p1 = PaneID(rawValue: "w1:p1")
    private let p2 = PaneID(rawValue: "w1:p2")
    private let p3 = PaneID(rawValue: "w1:p3")
    private let thumbnail = CGSize(width: 100, height: 82)

    private func layout(_ panes: [(PaneID, CellRect)], tab: String = "w1:t1") -> LayoutSnapshot {
        LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: tab), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: nil,
            panes: panes.map { PaneRect(paneID: $0.0, focused: false, rect: $0.1) }, splits: []
        )
    }

    private var sideBySide: LayoutSnapshot {
        layout([(p1, CellRect(x: 0, y: 0, width: 40, height: 24)), (p2, CellRect(x: 40, y: 0, width: 40, height: 24))])
    }

    // MARK: - mini pane geometry

    func testASideBySideSplitKeepsThePaddingOutsideAndTheGapBetween() {
        let boxes = MiniPaneLayout.boxes(
            layout: sideBySide, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2
        )
        XCTAssertEqual(boxes.map(\.pane), [p1, p2])
        let left = boxes[0].frame
        let right = boxes[1].frame
        XCTAssertEqual(left, CGRect(x: 4, y: 4, width: 44, height: 74))
        XCTAssertEqual(right, CGRect(x: 52, y: 4, width: 44, height: 74))
        XCTAssertEqual(right.minX - left.maxX, 4)
        XCTAssertEqual(thumbnail.width - right.maxX, 4)
        XCTAssertEqual(thumbnail.height - right.maxY, 4)
    }

    func testBoxesComeBackTopToBottomThenLeftToRightWhateverOrderTheSnapshotListsThem() {
        let shuffled = layout([
            (p3, CellRect(x: 0, y: 12, width: 80, height: 12)),
            (p2, CellRect(x: 40, y: 0, width: 40, height: 12)),
            (p1, CellRect(x: 0, y: 0, width: 40, height: 12)),
        ])
        let boxes = MiniPaneLayout.boxes(layout: shuffled, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(boxes.map(\.pane), [p1, p2, p3])
        XCTAssertEqual(boxes[2].frame.width, 92, "the bottom pane spans the whole thumbnail")
    }

    /// The snapshot's rects say side by side; herdr's own tree says stacked.
    /// The tree is what the canvas draws, so the thumbnail must agree with it.
    func testTheCachedExportDecidesTheShapeWhenItNamesTheTab() {
        let stacked = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false, focusedPaneID: p1,
            root: .split(direction: .down, ratio: 0.5, first: .pane(ExportedLayoutPane(paneID: p2)), second: .pane(ExportedLayoutPane(paneID: p1)))
        )
        let boxes = MiniPaneLayout.boxes(layout: sideBySide, exported: stacked, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(boxes.map(\.pane), [p2, p1], "drawn order, not snapshot order")
        XCTAssertEqual(boxes[0].frame.minX, boxes[1].frame.minX)
        XCTAssertEqual(boxes[0].frame.width, 92)
        XCTAssertLessThan(boxes[0].frame.maxY, boxes[1].frame.minY)
    }

    func testATabWithNoLayoutYetStacksItsPanesEvenlyRatherThanDrawingNothing() {
        let boxes = MiniPaneLayout.boxes(layout: nil, exported: nil, fallbackPanes: [p1, p2], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(boxes.map(\.pane), [p1, p2])
        XCTAssertEqual(boxes[0].frame, CGRect(x: 4, y: 4, width: 92, height: 35))
        XCTAssertEqual(boxes[1].frame, CGRect(x: 4, y: 43, width: 92, height: 35))
    }

    func testAThumbnailTooSmallForItsPanesNeverProducesANegativeBox() {
        let boxes = MiniPaneLayout.boxes(layout: sideBySide, exported: nil, fallbackPanes: [], size: CGSize(width: 3, height: 3), padding: 4, gap: 4, displayScale: 2)
        XCTAssertFalse(boxes.isEmpty)
        for box in boxes {
            XCTAssertGreaterThanOrEqual(box.frame.width, 0)
            XCTAssertGreaterThanOrEqual(box.frame.height, 0)
        }
    }

    // MARK: - hover card content

    private func model(title: String? = "claude", label: String? = "agent-1") -> SessionModel {
        func pane(_ id: String, status: String, title: String?, label: String?, cwd: String) -> [String: Any] {
            var row: [String: Any] = [
                "pane_id": id, "workspace_id": "w1", "tab_id": "w1:t1", "focused": false,
                "agent_status": status, "revision": 7, "cwd": cwd,
            ]
            row["terminal_title_stripped"] = title
            row["label"] = label
            return row
        }
        let snapshot: [String: Any] = [
            "version": "0.9.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t1", "focused_pane_id": "w1:p1",
            "workspaces": [["workspace_id": "w1", "label": "repo-tools", "number": 1, "active_tab_id": "w1:t1", "agent_status": "working"]],
            "tabs": [
                ["tab_id": "w1:t1", "workspace_id": "w1", "label": "agents", "number": 1, "pane_count": 3, "agent_status": "working"],
                ["tab_id": "w1:t2", "workspace_id": "w1", "label": "server", "number": 2, "pane_count": 1, "agent_status": "idle"],
            ],
            "panes": [
                pane("w1:p3", status: "idle", title: "nvim", label: nil, cwd: "/tmp"),
                pane("w1:p2", status: "working", title: title, label: label, cwd: "/Users/matt/Documents/GitHub/repo-tools"),
                pane("w1:p1", status: "blocked", title: "codex", label: nil, cwd: "/Users/matt"),
            ],
            "layouts": [[
                "workspace_id": "w1", "tab_id": "w1:t1", "zoomed": false,
                "area": ["x": 0, "y": 0, "width": 80, "height": 24], "focused_pane_id": "w1:p1",
                "panes": [
                    ["pane_id": "w1:p3", "focused": false, "rect": ["x": 0, "y": 12, "width": 80, "height": 12]],
                    ["pane_id": "w1:p2", "focused": false, "rect": ["x": 40, "y": 0, "width": 40, "height": 12]],
                    ["pane_id": "w1:p1", "focused": true, "rect": ["x": 0, "y": 0, "width": 40, "height": 12]],
                ],
                "splits": [],
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try! JSONDecoder().decode(SessionSnapshot.self, from: data))
    }

    private func content(_ pane: PaneID, model: SessionModel? = nil, exported: ExportedLayoutDescription? = nil, home: String = "/Users/matt") -> PaneHoverCardContent? {
        PaneHoverCardContent.make(pane: pane, model: model ?? self.model(), exported: exported, homeDirectory: home)
    }

    func testTheCardSaysTitleStatusPositionAndAbbreviatedCwd() throws {
        let content = try XCTUnwrap(content(p2))
        XCTAssertEqual(content.title, "claude")
        XCTAssertEqual(content.status, .working)
        XCTAssertEqual(content.statusWord, "working")
        XCTAssertEqual(content.position, "agents · pane 2 of 3")
        XCTAssertEqual(content.cwd, "~/Documents/GitHub/repo-tools")
    }

    func testAnEmptyTerminalTitleFallsBackToTheLabel() throws {
        XCTAssertEqual(try XCTUnwrap(content(p2, model: model(title: ""))).title, "agent-1")
        XCTAssertEqual(try XCTUnwrap(content(p2, model: model(title: nil))).title, "agent-1")
        XCTAssertEqual(try XCTUnwrap(content(p2, model: model(title: nil, label: nil))).title, "shell")
    }

    func testPanesAreCountedInTheOrderTheThumbnailDrawsThem() throws {
        XCTAssertEqual(try XCTUnwrap(content(p1, home: "/")).position, "agents · pane 1 of 3")
        XCTAssertEqual(try XCTUnwrap(content(p3, home: "/")).position, "agents · pane 3 of 3")
    }

    /// The export puts p3 across the top, where the snapshot's rects put it
    /// at the bottom. The thumbnail draws the export, so p3 is pane 1.
    func testACachedExportThatReshapesTheTabRenumbersItsPanes() throws {
        let reshaped = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false, focusedPaneID: p1,
            root: .split(
                direction: .down, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: p3)),
                second: .split(direction: .right, ratio: 0.5, first: .pane(ExportedLayoutPane(paneID: p1)), second: .pane(ExportedLayoutPane(paneID: p2)))
            )
        )
        XCTAssertEqual(try XCTUnwrap(content(p3, exported: reshaped)).position, "agents · pane 1 of 3")
        XCTAssertEqual(try XCTUnwrap(content(p2, exported: reshaped)).position, "agents · pane 3 of 3")
    }

    func testAPaneTheModelNoLongerHasHasNoCard() {
        XCTAssertNil(content(PaneID(rawValue: "w1:p9")))
    }

    func testOnlyTheHomeDirectoryItselfBecomesATilde() {
        XCTAssertEqual(PaneHoverCardContent.abbreviatingHome("/Users/matt", home: "/Users/matt"), "~")
        XCTAssertEqual(PaneHoverCardContent.abbreviatingHome("/Users/matt/src", home: "/Users/matt/"), "~/src")
        XCTAssertEqual(PaneHoverCardContent.abbreviatingHome("/Users/mattx/src", home: "/Users/matt"), "/Users/mattx/src")
        XCTAssertEqual(PaneHoverCardContent.abbreviatingHome("/tmp", home: "/"), "/tmp")
    }

    // MARK: - hover card placement

    private let container = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let card = CGSize(width: 200, height: 80)
    private let offset = CGSize(width: 12, height: 16)

    func testTheCardSitsBelowAndRightOfThePointer() {
        XCTAssertEqual(HoverCardPlacement.origin(pointer: CGPoint(x: 50, y: 40), card: card, container: container, offset: offset), CGPoint(x: 62, y: 56))
    }

    func testNearTheTrailingEdgeTheCardFlipsLeftOfThePointer() {
        XCTAssertEqual(HoverCardPlacement.origin(pointer: CGPoint(x: 300, y: 40), card: card, container: container, offset: offset), CGPoint(x: 88, y: 56))
    }

    func testNearTheBottomTheCardFlipsAboveThePointer() {
        XCTAssertEqual(HoverCardPlacement.origin(pointer: CGPoint(x: 50, y: 250), card: card, container: container, offset: offset), CGPoint(x: 62, y: 154))
    }

    func testInTheBottomTrailingCornerTheCardFlipsBothWays() {
        XCTAssertEqual(HoverCardPlacement.origin(pointer: CGPoint(x: 390, y: 290), card: card, container: container, offset: offset), CGPoint(x: 178, y: 194))
    }

    /// The pointer is part of the card's frame, never under it, wherever the
    /// pointer sits and whichever way the card flips.
    func testTheCardNeverCoversThePointerAndNeverLeavesTheContainer() {
        for x in stride(from: 0.0, through: 400.0, by: 25.0) {
            for y in stride(from: 0.0, through: 300.0, by: 25.0) {
                let pointer = CGPoint(x: x, y: y)
                let frame = CGRect(origin: HoverCardPlacement.origin(pointer: pointer, card: card, container: container, offset: offset), size: card)
                XCTAssertTrue(container.contains(frame), "\(pointer) -> \(frame)")
                XCTAssertFalse(frame.insetBy(dx: 1, dy: 1).contains(pointer), "\(pointer) -> \(frame)")
            }
        }
    }

    func testAContainerSmallerThanTheCardPinsItToTheLeadingTopCorner() {
        let tiny = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(HoverCardPlacement.origin(pointer: CGPoint(x: 50, y: 30), card: card, container: tiny, offset: offset), CGPoint(x: 10, y: 10))
    }

    // MARK: - the rail entry row

    /// A rail whose rows fill it, scrolled to its end during a pane drag: the
    /// margin stops the last row above the entry row, the row still takes a
    /// drop, and the bottom scroll band sits above the entry rather than on it.
    func testAFullyScrolledRailKeepsItsLastRowAndItsBandAboveTheEntryRow() throws {
        let rowHeight: CGFloat = 27
        let inset: CGFloat = 13
        let gap: CGFloat = 1
        let viewport = CGRect(x: -192, y: 50, width: 192, height: 510)
        let entry = CGRect(x: -182, y: viewport.maxY - inset - rowHeight, width: 172, height: rowHeight)
        let margin = AllWorkspacesEntry.railBottomMargin(restingMargin: inset, entryHeight: rowHeight, entryBottomInset: inset, gap: gap)
        let last = WorkspaceID(rawValue: "w16")
        let lastRow = CGRect(x: -182, y: viewport.maxY - margin - rowHeight, width: 172, height: rowHeight)
        XCTAssertLessThanOrEqual(lastRow.maxY, entry.minY - gap)

        let clipped = try XCTUnwrap(AllWorkspacesEntry.railViewport(viewport, above: entry))
        XCTAssertEqual(clipped.maxY, entry.minY)
        let surfaces = DropSurfaces(
            canvas: .empty, stripWorkspace: WorkspaceID(rawValue: "w1"), tabFrames: [],
            workspaceFrames: [WorkspaceItemFrame(id: last, frame: lastRow)],
            railFrame: viewport, railViewport: clipped, newTabZone: nil, newWorkspaceZone: nil, allWorkspacesEntry: entry
        )
        let pane = DragSubject.pane(PaneID(rawValue: "w1:p1"))
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: -100, y: lastRow.midY), dragging: pane, surfaces: surfaces), .workspaceThumbnail(last))
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: -100, y: entry.midY), dragging: pane, surfaces: surfaces), .allWorkspaces)

        var scroller = AutoScroller()
        let region = [AutoScroller.Region(surface: .rail, viewport: clipped, axis: .vertical, offset: 300, maximumOffset: 600)]
        XCTAssertFalse(scroller.pointerMoved(to: CGPoint(x: -100, y: entry.maxY - 2), regions: region), "the entry row is not part of the band")
        XCTAssertNil(scroller.tick(pointer: CGPoint(x: -100, y: entry.maxY - 2), regions: region, elapsed: 1.0 / 60))
        XCTAssertTrue(scroller.pointerMoved(to: CGPoint(x: -100, y: entry.minY - 2), regions: region), "the band sits just above it")
    }

    func testWithNoEntryRowTheRailKeepsItsRestingMarginAndViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 192, height: 400)
        XCTAssertEqual(AllWorkspacesEntry.railViewport(viewport, above: nil), viewport)
        XCTAssertNil(AllWorkspacesEntry.railViewport(nil, above: CGRect(x: 0, y: 360, width: 10, height: 10)))
        XCTAssertEqual(AllWorkspacesEntry.railBottomMargin(restingMargin: 50, entryHeight: 27, entryBottomInset: 13, gap: 1), 50)
    }

    // MARK: - grid drop resolution

    private let gridThumbnail = TabItemFrame(id: TabID(rawValue: "w1:t2"), frame: CGRect(x: 20, y: 60, width: 90, height: 82))
    private let scrolledAway = TabItemFrame(id: TabID(rawValue: "w1:t1"), frame: CGRect(x: 20, y: 360, width: 90, height: 82))
    private let plusTile = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 130, y: 60, width: 90, height: 82))
    private let entry = CGRect(x: -200, y: 540, width: 190, height: 27)

    /// A canvas pane, a strip tab and a rail row all lie where the grid now
    /// sits, as their last reported frames do while the grid covers them.
    private func surfaces(grid: Bool, entry: CGRect? = nil) -> DropSurfaces {
        let canvas = CanvasGeometry(layout: sideBySide, grid: CanvasGrid(canvas: CGSize(width: 600, height: 300)))
        let railFrame = CGRect(x: -200, y: 0, width: 200, height: 600)
        return DropSurfaces(
            canvas: canvas.offset(by: CGPoint(x: 0, y: 40)),
            stripWorkspace: WorkspaceID(rawValue: "w1"),
            tabFrames: [TabItemFrame(id: TabID(rawValue: "w1:t2"), frame: CGRect(x: 0, y: 0, width: 100, height: 28))],
            workspaceFrames: [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: -190, y: 40, width: 180, height: 27))],
            stripFrame: CGRect(x: 0, y: 0, width: 600, height: 36),
            railFrame: railFrame,
            newTabZone: nil,
            newWorkspaceZone: DropZones.below(in: railFrame, itemsEndingAt: 67),
            grid: grid ? GridDropSurfaces(viewport: CGRect(x: 0, y: 40, width: 600, height: 300), thumbnails: [gridThumbnail, scrolledAway], moreTiles: [plusTile]) : nil,
            allWorkspacesEntry: entry
        )
    }

    private let pane = DragSubject.pane(PaneID(rawValue: "w1:p1"))

    func testAPaneOverAGridThumbnailTargetsThatTab() {
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 60, y: 100), dragging: pane, surfaces: surfaces(grid: true)), .tabThumbnail(TabID(rawValue: "w1:t2")))
    }

    func testAPaneOverAPlusTileTargetsTheCardsHiddenTabs() {
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 170, y: 100), dragging: pane, surfaces: surfaces(grid: true)), .moreTabs(WorkspaceID(rawValue: "w1")))
    }

    func testAThumbnailScrolledOutOfTheGridIsNotThereToHit() {
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 60, y: 400), dragging: pane, surfaces: surfaces(grid: true)))
    }

    /// Without the grid the same point is a canvas pane: the grid answering
    /// alone is what keeps the hidden canvas from taking the drop.
    func testTheFramesUnderAShownGridNeverAnswer() {
        let overStaleCanvas = CGPoint(x: 400, y: 200)
        XCTAssertEqual(resolveDropTarget(at: overStaleCanvas, dragging: pane, surfaces: surfaces(grid: false)), .paneInterior(p2))
        XCTAssertNil(resolveDropTarget(at: overStaleCanvas, dragging: pane, surfaces: surfaces(grid: true)))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: -100, y: 50), dragging: pane, surfaces: surfaces(grid: true)), "a stale rail row")
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 50, y: 14), dragging: pane, surfaces: surfaces(grid: true)), "a stale strip tab")
    }

    func testOnlyAPaneDropsIntoTheGrid() {
        for subject in [DragSubject.tab(TabID(rawValue: "w1:t1")), .workspace(WorkspaceID(rawValue: "w1")), .workspaces([WorkspaceID(rawValue: "w1")])] {
            XCTAssertNil(resolveDropTarget(at: CGPoint(x: 60, y: 100), dragging: subject, surfaces: surfaces(grid: true)), "\(subject)")
            XCTAssertNil(resolveDropTarget(at: CGPoint(x: 170, y: 100), dragging: subject, surfaces: surfaces(grid: true)), "\(subject)")
        }
    }

    func testTheRailEntryOutranksTheNewWorkspaceRunItSitsIn() {
        let withEntry = surfaces(grid: false, entry: entry)
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: -100, y: 550), dragging: pane, surfaces: surfaces(grid: false)), .newWorkspace)
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: -100, y: 550), dragging: pane, surfaces: withEntry), .allWorkspaces)
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: -100, y: 300), dragging: pane, surfaces: withEntry), .newWorkspace)
    }

    func testTheRailEntryIsAPanesAlone() {
        let target = resolveDropTarget(at: CGPoint(x: -100, y: 550), dragging: .tab(TabID(rawValue: "w1:t1")), surfaces: surfaces(grid: false, entry: entry))
        XCTAssertNotEqual(target, .allWorkspaces)
    }

    // MARK: - rects

    func testAGridThumbnailsRectIsItsGridFrameNotTheStripTabOfTheSameID() {
        XCTAssertEqual(dropTargetRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: true)), gridThumbnail.frame)
        XCTAssertEqual(dropTargetRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: false))?.minY, 0)
        XCTAssertEqual(dropFlashRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: true)), gridThumbnail.frame)
    }

    func testTheDwellOnlyTargetsHaveARectButNeverFlash() {
        XCTAssertEqual(dropTargetRect(for: .moreTabs(WorkspaceID(rawValue: "w1")), surfaces: surfaces(grid: true)), plusTile.frame)
        XCTAssertEqual(dropTargetRect(for: .allWorkspaces, surfaces: surfaces(grid: false, entry: entry)), entry)
        XCTAssertNil(dropFlashRect(for: .moreTabs(WorkspaceID(rawValue: "w1")), surfaces: surfaces(grid: true)))
        XCTAssertNil(dropFlashRect(for: .allWorkspaces, surfaces: surfaces(grid: false, entry: entry)))
    }

    // MARK: - planner

    func testADropOnADwellOnlyTargetIsANoOpNeverARejection() {
        for subject in [pane, .tab(TabID(rawValue: "w1:t1"))] {
            for target in [DropTarget.allWorkspaces, .moreTabs(WorkspaceID(rawValue: "w1"))] {
                guard case .failure(.noOp) = plan(dragging: subject, onto: target, model: model()) else {
                    return XCTFail("\(subject) onto \(target) must spring back silently")
                }
            }
        }
    }
}
