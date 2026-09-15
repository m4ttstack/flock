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

    func testPanesComeBackInReadingOrderWhateverOrderTheSnapshotListsThem() {
        let shuffled = layout([
            (p3, CellRect(x: 0, y: 12, width: 80, height: 12)),
            (p2, CellRect(x: 40, y: 0, width: 40, height: 12)),
            (p1, CellRect(x: 0, y: 0, width: 40, height: 12)),
        ])
        XCTAssertEqual(MiniPaneLayout.readingOrder(layout: shuffled, fallbackPanes: []), [p1, p2, p3])
        let boxes = MiniPaneLayout.boxes(layout: shuffled, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(boxes.map(\.pane), [p1, p2, p3])
        XCTAssertEqual(boxes[2].frame.width, 92, "the bottom pane spans the whole thumbnail")
    }

    /// The snapshot's rects say side by side; herdr's own tree says stacked.
    /// The tree is what the canvas draws, so the thumbnail must agree with it.
    func testTheCachedExportDecidesTheShapeWhenItNamesTheTab() {
        let stacked = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false, focusedPaneID: p1,
            root: .split(direction: .down, ratio: 0.5, first: .pane(ExportedLayoutPane(paneID: p1)), second: .pane(ExportedLayoutPane(paneID: p2)))
        )
        let boxes = MiniPaneLayout.boxes(layout: sideBySide, exported: stacked, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        let frames = Dictionary(uniqueKeysWithValues: boxes.map { ($0.pane, $0.frame) })
        let top = try? XCTUnwrap(frames[p1])
        let bottom = try? XCTUnwrap(frames[p2])
        XCTAssertEqual(top?.minX, bottom?.minX)
        XCTAssertEqual(top?.width, 92)
        XCTAssertLessThan(top?.maxY ?? .infinity, bottom?.minY ?? 0)
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
        func pane(_ id: String, _ y: Int, _ x: Int, status: String, title: String?, label: String?, cwd: String) -> [String: Any] {
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
                pane("w1:p3", 12, 0, status: "idle", title: "nvim", label: nil, cwd: "/tmp"),
                pane("w1:p2", 0, 40, status: "working", title: title, label: label, cwd: "/Users/matt/Documents/GitHub/repo-tools"),
                pane("w1:p1", 0, 0, status: "blocked", title: "codex", label: nil, cwd: "/Users/matt"),
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

    func testTheCardSaysTitleStatusPositionAndAbbreviatedCwd() throws {
        let content = try XCTUnwrap(PaneHoverCardContent.make(pane: p2, model: model(), homeDirectory: "/Users/matt"))
        XCTAssertEqual(content.title, "claude")
        XCTAssertEqual(content.status, .working)
        XCTAssertEqual(content.statusWord, "working")
        XCTAssertEqual(content.position, "agents · pane 2 of 3")
        XCTAssertEqual(content.cwd, "~/Documents/GitHub/repo-tools")
    }

    func testAnEmptyTerminalTitleFallsBackToTheLabel() throws {
        XCTAssertEqual(try XCTUnwrap(PaneHoverCardContent.make(pane: p2, model: model(title: ""), homeDirectory: "/Users/matt")).title, "agent-1")
        XCTAssertEqual(try XCTUnwrap(PaneHoverCardContent.make(pane: p2, model: model(title: nil), homeDirectory: "/Users/matt")).title, "agent-1")
        XCTAssertEqual(try XCTUnwrap(PaneHoverCardContent.make(pane: p2, model: model(title: nil, label: nil), homeDirectory: "/Users/matt")).title, "shell")
    }

    func testPanesAreCountedInTheOrderTheThumbnailDrawsThem() throws {
        XCTAssertEqual(try XCTUnwrap(PaneHoverCardContent.make(pane: p1, model: model(), homeDirectory: "/")).position, "agents · pane 1 of 3")
        XCTAssertEqual(try XCTUnwrap(PaneHoverCardContent.make(pane: p3, model: model(), homeDirectory: "/")).position, "agents · pane 3 of 3")
    }

    func testAPaneTheModelNoLongerHasHasNoCard() {
        XCTAssertNil(PaneHoverCardContent.make(pane: PaneID(rawValue: "w1:p9"), model: model(), homeDirectory: "/Users/matt"))
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

    func testTheCardSitsBelowThePaneWhenItFits() {
        XCTAssertEqual(HoverCardPlacement.origin(anchor: CGRect(x: 10, y: 20, width: 50, height: 40), card: card, container: container, gap: 6), CGPoint(x: 10, y: 66))
    }

    func testTheCardFlipsAboveAPaneNearTheBottom() {
        XCTAssertEqual(HoverCardPlacement.origin(anchor: CGRect(x: 10, y: 240, width: 50, height: 40), card: card, container: container, gap: 6), CGPoint(x: 10, y: 154))
    }

    func testTheCardNeverRunsPastTheTrailingEdge() {
        XCTAssertEqual(HoverCardPlacement.origin(anchor: CGRect(x: 380, y: 20, width: 20, height: 20), card: card, container: container, gap: 6).x, 200)
    }

    func testWithRoomNeitherSideTheCardStaysInsideTheContainer() {
        let short = CGRect(x: 0, y: 0, width: 400, height: 100)
        XCTAssertEqual(HoverCardPlacement.origin(anchor: CGRect(x: 0, y: 30, width: 50, height: 40), card: card, container: short, gap: 6).y, 20)
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

    /// The resolver/planner invariant, swept over the grid and the rail entry.
    func testEveryPairTheGridOrTheRailEntryCanProduceHasAPlan() {
        var produced: [DropTarget] = []
        for surfaces in [surfaces(grid: true), surfaces(grid: false, entry: entry)] {
            for x in stride(from: -210.0, through: 610.0, by: 10.0) {
                for y in stride(from: -10.0, through: 610.0, by: 10.0) {
                    guard let target = resolveDropTarget(at: CGPoint(x: x, y: y), dragging: pane, surfaces: surfaces),
                          !produced.contains(target)
                    else { continue }
                    produced.append(target)
                }
            }
        }
        XCTAssertTrue(produced.contains(.allWorkspaces))
        XCTAssertTrue(produced.contains(.moreTabs(WorkspaceID(rawValue: "w1"))))
        XCTAssertTrue(produced.contains(.tabThumbnail(TabID(rawValue: "w1:t2"))))
        for target in produced {
            if case .failure(.invalidCombination) = plan(dragging: pane, onto: target, model: model()) {
                XCTFail("the resolver produces a pane onto \(target), which GesturePlanner has no case for")
            }
        }
    }
}
