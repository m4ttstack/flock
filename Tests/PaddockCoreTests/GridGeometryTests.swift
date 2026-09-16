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

    /// The mini panes start under the tab's handle strip, not at the
    /// thumbnail's own top edge: a box read against the full frame would sit
    /// a strip's height above where it is drawn.
    func testThePaneAreaStartsBelowTheHandleStrip() {
        let thumbnail = CGRect(x: 20, y: 60, width: 100, height: 101)
        XCTAssertEqual(
            MiniPaneLayout.paneArea(in: thumbnail, stripHeight: 15),
            CGRect(x: 20, y: 75, width: 100, height: 86)
        )
    }

    /// A thumbnail shorter than its own strip (a transient layout pass) keeps
    /// a real rect rather than a negative one.
    func testAPaneAreaNeverGoesNegative() {
        let area = MiniPaneLayout.paneArea(in: CGRect(x: 0, y: 0, width: 100, height: 10), stripHeight: 15)
        XCTAssertEqual(area.height, 0)
    }

    /// The spring-back home is recorded against the thumbnail, so a mini
    /// pane's box has to cross from the pane area's space into it. Both
    /// directions read the same offset, so a strip that grows an inset moves
    /// them together instead of leaving the home behind.
    func testABoxCrossesIntoTheThumbnailsSpaceByTheSameOffsetThePaneAreaUses() {
        let stripHeight: CGFloat = 15
        let thumbnail = CGRect(x: 20, y: 60, width: 100, height: 101)
        let box = CGRect(x: 4, y: 4, width: 45, height: 74)

        let inThumbnail = MiniPaneLayout.boxInThumbnail(box, stripHeight: stripHeight)
        XCTAssertEqual(inThumbnail, CGRect(x: 4, y: 19, width: 45, height: 74))

        let area = MiniPaneLayout.paneArea(in: thumbnail, stripHeight: stripHeight)
        XCTAssertEqual(
            CGPoint(x: thumbnail.minX + inThumbnail.minX, y: thumbnail.minY + inThumbnail.minY),
            CGPoint(x: area.minX + box.minX, y: area.minY + box.minY),
            "the box lands in the same place whichever space it is stated in"
        )
    }

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

    // MARK: - a pane landing in a tab

    private let arriving = PaneID(rawValue: "w2:p1")

    private func landingBoxes(_ layout: LayoutSnapshot, exported: ExportedLayoutDescription? = nil) -> [MiniPaneLayout.Placed] {
        MiniPaneLayout.boxes(
            layout: layout, exported: exported, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2,
            arriving: MiniPaneLayout.Arrival(pane: arriving, target: .paneEdge(p1, .right))
        )
    }

    /// One pane holding the whole tab: the arriving pane takes the right half
    /// of it, which is what `pane.move` with no target pane does to a tab
    /// whose focused pane is the only one there is.
    func testAPaneLandingInAOnePaneTabSplitsThatPaneInHalf() throws {
        let whole = layout([(p1, CellRect(x: 0, y: 0, width: 80, height: 24))])
        let boxes = landingBoxes(whole)
        XCTAssertEqual(boxes.map(\.pane), [p1, arriving])
        XCTAssertEqual(boxes[0].frame, CGRect(x: 4, y: 4, width: 44, height: 74))
        XCTAssertEqual(boxes[1].frame, CGRect(x: 52, y: 4, width: 44, height: 74))

        let atRest = MiniPaneLayout.boxes(layout: whole, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(atRest.map(\.pane), [p1])
        XCTAssertEqual(atRest[0].frame.width, 92, "the pane really did have to make room")
    }

    /// Two panes side by side: only the focused one divides, and the pane
    /// beside it does not move at all, because a `pane.move` only ever
    /// divides the region it is aimed at.
    func testOnlyTheFocusedPaneMakesRoomInATwoPaneTab() throws {
        let boxes = landingBoxes(sideBySide)
        XCTAssertEqual(boxes.map(\.pane), [p1, arriving, p2])
        let resting = MiniPaneLayout.boxes(layout: sideBySide, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(try XCTUnwrap(boxes.first { $0.pane == p2 }).frame, try XCTUnwrap(resting.first { $0.pane == p2 }).frame)
        let focused = try XCTUnwrap(boxes.first { $0.pane == p1 })
        let landed = try XCTUnwrap(boxes.first { $0.pane == arriving })
        XCTAssertLessThan(focused.frame.maxX, landed.frame.minX, "the arriving pane takes the right half")
        XCTAssertEqual(landed.frame.minY, focused.frame.minY)
        XCTAssertEqual(landed.frame.height, focused.frame.height)
        XCTAssertEqual(focused.frame.width + landed.frame.width + 4, try XCTUnwrap(resting.first { $0.pane == p1 }).frame.width, accuracy: 1)
    }

    /// Three panes, the focused one down the left: it halves, the two on the
    /// right stay exactly where they were.
    func testAThreePaneTabOnlyDividesTheFocusedPanesOwnRegion() throws {
        let leftAndStack = layout([
            (p1, CellRect(x: 0, y: 0, width: 40, height: 24)),
            (p2, CellRect(x: 40, y: 0, width: 40, height: 12)),
            (p3, CellRect(x: 40, y: 12, width: 40, height: 12)),
        ])
        let boxes = landingBoxes(leftAndStack)
        let resting = MiniPaneLayout.boxes(layout: leftAndStack, exported: nil, fallbackPanes: [], size: thumbnail, padding: 4, gap: 4, displayScale: 2)
        XCTAssertEqual(boxes.count, 4)
        for pane in [p2, p3] {
            XCTAssertEqual(
                try XCTUnwrap(boxes.first { $0.pane == pane }).frame,
                try XCTUnwrap(resting.first { $0.pane == pane }).frame, pane.rawValue
            )
        }
        let landed = try XCTUnwrap(boxes.first { $0.pane == arriving })
        let focused = try XCTUnwrap(boxes.first { $0.pane == p1 })
        XCTAssertLessThan(focused.frame.maxX, landed.frame.minX)
        XCTAssertLessThan(landed.frame.maxX, try XCTUnwrap(boxes.first { $0.pane == p2 }).frame.minX, "both stay inside the focused pane's own column")
    }

    /// herdr's own split tree decides the shape wherever one is cached, and
    /// the arriving pane is grafted into it by the same transform the canvas
    /// previews an edge drop with, so the two cannot drift.
    func testACachedTreeDecidesWhereTheArrivingPaneLands() throws {
        let stacked = ExportedLayoutDescription(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false, focusedPaneID: p1,
            root: .split(direction: .down, ratio: 0.5, first: .pane(ExportedLayoutPane(paneID: p2)), second: .pane(ExportedLayoutPane(paneID: p1)))
        )
        let boxes = landingBoxes(sideBySide, exported: stacked)
        XCTAssertEqual(boxes.map(\.pane), [p2, p1, arriving], "drawn order under the tree, not the snapshot's rects")
        let focused = try XCTUnwrap(boxes.first { $0.pane == p1 })
        let landed = try XCTUnwrap(boxes.first { $0.pane == arriving })
        XCTAssertEqual(landed.frame.minY, focused.frame.minY, "beside the focused pane, in its own row")
        XCTAssertLessThan(focused.frame.maxX, landed.frame.minX)
        XCTAssertEqual(
            try XCTUnwrap(boxes.first { $0.pane == p2 }).frame.width, 92, "the untouched half of the tree keeps the full width"
        )
    }

    /// A pane already in this tab is a drop herdr refuses outright, so
    /// nothing is previewed for it; so is a tab that is not the one the drag
    /// is over, and a subject that is not a pane at all.
    func testOnlyADropThatCommitsPreviewsAnArrival() {
        let tabID = TabID(rawValue: "w1:t1")
        let otherTab = TabID(rawValue: "w1:t2")
        let model = model()
        XCTAssertNil(
            MiniPaneLayout.arrival(of: .pane(p1), onto: .tabThumbnail(tabID), tab: tabID, model: model),
            "a pane dropped on its own tab"
        )
        XCTAssertNil(
            MiniPaneLayout.arrival(of: .pane(p1), onto: .tabThumbnail(otherTab), tab: tabID, model: model),
            "another tab's thumbnail"
        )
        XCTAssertNil(MiniPaneLayout.arrival(of: .tab(otherTab), onto: .tabThumbnail(tabID), tab: tabID, model: model))
        XCTAssertNil(MiniPaneLayout.arrival(of: nil, onto: nil, tab: tabID, model: model))
    }

    /// The pane the arrival splits is the one herdr would: the target tab's
    /// own focused pane, whichever pane of another tab is coming in.
    func testAnArrivalLandsBesideTheTargetTabsFocusedPane() throws {
        let second = TabID(rawValue: "w1:t2")
        let model = model()
        let arrival = try XCTUnwrap(MiniPaneLayout.arrival(of: .pane(p1), onto: .tabThumbnail(second), tab: second, model: model))
        XCTAssertEqual(arrival.pane, p1)
        XCTAssertEqual(arrival.target, .paneEdge(PaneID(rawValue: "w1:p4"), .right), "the second tab's own pane, not the drag's")
        XCTAssertNil(
            MiniPaneLayout.arrival(of: .pane(PaneID(rawValue: "w1:p4")), onto: .tabThumbnail(second), tab: second, model: model),
            "a pane already in the tab it is over"
        )
    }

    /// A target tab paddock has no layout for yet cannot say where a pane
    /// would land, so it previews nothing rather than guessing at a split.
    func testATabWithNoLayoutYetPreviewsNoArrival() {
        let bare = TabID(rawValue: "w1:t3")
        XCTAssertNil(MiniPaneLayout.arrival(of: .pane(p1), onto: .tabThumbnail(bare), tab: bare, model: model()))
    }

    /// Two rungs and no more: the layout's own id, then the first pane there
    /// is. A rect's `focused` flag is not one of them, so sharing this read
    /// with the mutation path cannot move which pane a zoom comes back onto.
    func testTheFocusedPaneIsTheLayoutsOwnIdThenItsFirstPane() {
        let named = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: p2,
            panes: [PaneRect(paneID: p1, focused: true, rect: CellRect(x: 0, y: 0, width: 80, height: 24))], splits: []
        )
        XCTAssertEqual(named.focusedPane, p2)

        let flagged = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"), zoomed: false,
            area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: nil,
            panes: [
                PaneRect(paneID: p1, focused: false, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
                PaneRect(paneID: p2, focused: true, rect: CellRect(x: 40, y: 0, width: 40, height: 24)),
            ],
            splits: []
        )
        XCTAssertEqual(flagged.focusedPane, p1, "the flagged rect is not a rung")
        XCTAssertEqual(sideBySide.focusedPane, p1, "nothing marked at all")
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
                ["tab_id": "w1:t3", "workspace_id": "w1", "label": "scratch", "number": 3, "pane_count": 1, "agent_status": "idle"],
            ],
            "panes": [
                pane("w1:p3", status: "idle", title: "nvim", label: nil, cwd: "/tmp"),
                pane("w1:p2", status: "working", title: title, label: label, cwd: "/Users/matt/Documents/GitHub/repo-tools"),
                pane("w1:p1", status: "blocked", title: "codex", label: nil, cwd: "/Users/matt"),
                ["pane_id": "w1:p4", "workspace_id": "w1", "tab_id": "w1:t2", "focused": false,
                 "agent_status": "idle", "revision": 1, "cwd": "/tmp", "terminal_title_stripped": "zsh"],
            ],
            "layouts": [
                [
                    "workspace_id": "w1", "tab_id": "w1:t1", "zoomed": false,
                    "area": ["x": 0, "y": 0, "width": 80, "height": 24], "focused_pane_id": "w1:p1",
                    "panes": [
                        ["pane_id": "w1:p3", "focused": false, "rect": ["x": 0, "y": 12, "width": 80, "height": 12]],
                        ["pane_id": "w1:p2", "focused": false, "rect": ["x": 40, "y": 0, "width": 40, "height": 12]],
                        ["pane_id": "w1:p1", "focused": true, "rect": ["x": 0, "y": 0, "width": 40, "height": 12]],
                    ],
                    "splits": [],
                ],
                [
                    "workspace_id": "w1", "tab_id": "w1:t2", "zoomed": false,
                    "area": ["x": 0, "y": 0, "width": 80, "height": 24], "focused_pane_id": "w1:p4",
                    "panes": [["pane_id": "w1:p4", "focused": true, "rect": ["x": 0, "y": 0, "width": 80, "height": 24]]],
                    "splits": [],
                ],
            ],
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

    // MARK: - grid drop resolution

    /// Two cards side by side inside the grid's viewport, and a third scrolled
    /// below it. Card w1 holds a thumbnail and a +N tile; card w2 holds one
    /// thumbnail. Everything else inside a card is its empty space.
    private let viewport = CGRect(x: 0, y: 40, width: 600, height: 300)
    private let cardOne = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 10, y: 50, width: 280, height: 160))
    private let cardTwo = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w2"), frame: CGRect(x: 310, y: 50, width: 280, height: 160))
    private let cardThree = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w3"), frame: CGRect(x: 10, y: 350, width: 280, height: 160))
    private let gridThumbnail = TabItemFrame(id: TabID(rawValue: "w1:t2"), frame: CGRect(x: 20, y: 60, width: 90, height: 82))
    private let otherCardThumbnail = TabItemFrame(id: TabID(rawValue: "w2:t1"), frame: CGRect(x: 320, y: 60, width: 90, height: 82))
    private let scrolledAway = TabItemFrame(id: TabID(rawValue: "w3:t1"), frame: CGRect(x: 20, y: 360, width: 90, height: 82))
    private let plusTile = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 130, y: 60, width: 90, height: 82))
    /// Card w1 is previewing the tab a drop on it will create, in the slot
    /// after its tile. Drawn in the card's empty space and hit-tested by
    /// nothing.
    private let newTabSlot = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: 20, y: 150, width: 90, height: 40))
    /// Card w3's own tile, standing in for the tab its drop will create: the
    /// same rect reported under the new tab's id as well.
    private let tileAsNewTab = WorkspaceItemFrame(id: WorkspaceID(rawValue: "w3"), frame: CGRect(x: 130, y: 360, width: 90, height: 82))

    private func surfacesWithTheTileCarryingTheDrop() -> DropSurfaces {
        let base = surfaces(grid: true)
        let grid = base.grid
        return DropSurfaces(
            canvas: base.canvas, stripWorkspace: base.stripWorkspace, tabFrames: base.tabFrames,
            workspaceFrames: base.workspaceFrames, stripFrame: base.stripFrame, railFrame: base.railFrame,
            newTabZone: base.newTabZone, newWorkspaceZone: base.newWorkspaceZone,
            grid: GridDropSurfaces(
                viewport: grid?.viewport ?? .zero, thumbnails: grid?.thumbnails ?? [],
                tiles: (grid?.tiles ?? []) + [tileAsNewTab], cards: grid?.cards ?? [],
                newTabSlots: (grid?.newTabSlots ?? []) + [tileAsNewTab], cardTabs: grid?.cardTabs ?? []
            )
        )
    }

    /// Points inside a card that no thumbnail or tile covers.
    private var cardOneEmptySpace: CGPoint { CGPoint(x: 250, y: 180) }
    private var cardTwoEmptySpace: CGPoint { CGPoint(x: 550, y: 180) }

    /// A canvas pane, a strip tab and a rail row all lie where the grid now
    /// sits, as their last reported frames do while the grid covers them.
    private func surfaces(grid: Bool) -> DropSurfaces {
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
            grid: grid ? GridDropSurfaces(
                viewport: viewport,
                thumbnails: [gridThumbnail, otherCardThumbnail, scrolledAway],
                tiles: [plusTile],
                cards: [cardOne, cardTwo, cardThree],
                newTabSlots: [newTabSlot],
                cardTabs: [
                    GridCardTabs(workspace: cardOne.id, tabs: [gridThumbnail]),
                    GridCardTabs(workspace: cardTwo.id, tabs: [otherCardThumbnail]),
                    GridCardTabs(workspace: cardThree.id, tabs: [scrolledAway]),
                ]
            ) : nil
        )
    }

    private let pane = DragSubject.pane(PaneID(rawValue: "w1:p1"))
    private let tab = DragSubject.tab(TabID(rawValue: "w1:t1"))

    func testAPaneOverAGridThumbnailTargetsThatTab() {
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 60, y: 100), dragging: pane, surfaces: surfaces(grid: true)), .tabThumbnail(TabID(rawValue: "w1:t2")))
    }

    /// The tab's handle strip is drawn inside its thumbnail and reports no
    /// frame of its own, so a drop on the strip is a drop on that tab rather
    /// than a target of its own or the card's empty space.
    func testAPaneOverATabsHandleStripTargetsThatTab() {
        let strip = CGPoint(x: gridThumbnail.frame.midX, y: gridThumbnail.frame.minY + 2)
        XCTAssertEqual(resolveDropTarget(at: strip, dragging: pane, surfaces: surfaces(grid: true)), .tabThumbnail(TabID(rawValue: "w1:t2")))
    }

    /// Both tiles a card can show report as one grid item, so the "fewer" tile
    /// of an expanded card refuses a drop exactly as "+N" does rather than
    /// letting the card behind it make a tab.
    func testAPaneOverACardsTileTargetsTheTileNeverTheCardBehindIt() {
        XCTAssertEqual(resolveDropTarget(at: CGPoint(x: 170, y: 100), dragging: pane, surfaces: surfaces(grid: true)), .moreTabs(WorkspaceID(rawValue: "w1")))
        guard case .failure(.noOp) = plan(dragging: pane, onto: .moreTabs(WorkspaceID(rawValue: "w1")), model: model()) else {
            return XCTFail("a tile must spring back silently")
        }
    }

    /// The card's empty space is whatever its thumbnails and tiles do not
    /// cover, so it can only be answered after both of them miss.
    func testAPaneOverACardsEmptySpaceTargetsThatWorkspace() {
        XCTAssertEqual(resolveDropTarget(at: cardOneEmptySpace, dragging: pane, surfaces: surfaces(grid: true)), .workspaceThumbnail(WorkspaceID(rawValue: "w1")))
        XCTAssertEqual(resolveDropTarget(at: cardTwoEmptySpace, dragging: pane, surfaces: surfaces(grid: true)), .workspaceThumbnail(WorkspaceID(rawValue: "w2")))
    }

    /// The new-tab placeholder is drawn in the card's empty space but is never
    /// hit-tested, so a release inside it is a release on the card: it targets
    /// the workspace and plans a real move, not a no-op that springs back.
    func testAPaneInsideTheNewTabPlaceholderStillTargetsTheCardAndPlansAMove() throws {
        let workspace = WorkspaceID(rawValue: "w1")
        let inside = CGPoint(x: newTabSlot.frame.midX, y: newTabSlot.frame.midY)
        XCTAssertEqual(resolveDropTarget(at: inside, dragging: pane, surfaces: surfaces(grid: true)), .workspaceThumbnail(workspace))

        guard case .success(let plan) = plan(dragging: pane, onto: .workspaceThumbnail(workspace), model: model()) else {
            return XCTFail("a drop on the placeholder has to commit a new tab, not spring back")
        }
        XCTAssertFalse(plan.ops.isEmpty)
    }

    /// The landing rect a committed drop settles on: the slot the tab really
    /// takes, not the whole card, whose centre is nowhere the drop landed.
    /// The flash follows it for the same reason.
    func testTheLandingRectForACardPreviewingANewTabIsThatSlot() {
        let workspace = WorkspaceID(rawValue: "w1")
        XCTAssertEqual(
            dropTargetRect(for: .workspaceThumbnail(workspace), surfaces: surfaces(grid: true)), newTabSlot.frame
        )
        XCTAssertEqual(
            dropFlashRect(for: .workspaceThumbnail(workspace), surfaces: surfaces(grid: true)), newTabSlot.frame
        )
    }

    /// A resting card over its cap draws no placeholder and lights its tile
    /// instead, so the tile is the cell the created tab lands in. It reports
    /// its own rect under both ids, and the landing rect reads the same
    /// `newTabSlots` either way.
    func testTheLandingRectForACardPreviewingOnItsTileIsThatTile() {
        let workspace = WorkspaceID(rawValue: "w3")
        let surfaces = surfacesWithTheTileCarryingTheDrop()
        XCTAssertEqual(dropTargetRect(for: .workspaceThumbnail(workspace), surfaces: surfaces), tileAsNewTab.frame)
        XCTAssertEqual(dropFlashRect(for: .workspaceThumbnail(workspace), surfaces: surfaces), tileAsNewTab.frame)
        XCTAssertNotEqual(tileAsNewTab.frame, cardThree.frame, "the tile is not the card")
    }

    /// The gaps between cards, the header strip and the canvas margin are not
    /// anything: a release there springs back.
    func testAPaneBetweenTheCardsTargetsNothing() {
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 300, y: 180), dragging: pane, surfaces: surfaces(grid: true)))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 300, y: 45), dragging: pane, surfaces: surfaces(grid: true)))
    }

    func testAThumbnailScrolledOutOfTheGridIsNotThereToHit() {
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 60, y: 400), dragging: pane, surfaces: surfaces(grid: true)))
    }

    /// The card that thumbnail belongs to is scrolled out with it, so the
    /// viewport gate has to cover cards as well.
    func testACardScrolledOutOfTheGridIsNotThereToHit() {
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 250, y: 480), dragging: pane, surfaces: surfaces(grid: true)))
    }

    /// Without the grid the same point is a canvas pane: the grid answering
    /// alone is what keeps the hidden canvas from taking the drop.
    func testTheFramesUnderAShownGridNeverAnswer() {
        let overStaleCanvas = CGPoint(x: 400, y: 250)
        XCTAssertEqual(resolveDropTarget(at: overStaleCanvas, dragging: pane, surfaces: surfaces(grid: false)), .paneInterior(p2))
        XCTAssertNil(resolveDropTarget(at: overStaleCanvas, dragging: pane, surfaces: surfaces(grid: true)))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: -100, y: 50), dragging: pane, surfaces: surfaces(grid: true)), "a stale rail row")
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 50, y: 14), dragging: pane, surfaces: surfaces(grid: true)), "a stale strip tab")
    }

    /// A whole tab lands in another workspace wherever in that card it is
    /// dropped: a thumbnail or a +N tile inside it still resolves to the card.
    func testATabOverAnotherCardTargetsThatWorkspaceWhereverInTheCardItIs() {
        for point in [cardTwoEmptySpace, CGPoint(x: 350, y: 100)] {
            XCTAssertEqual(resolveDropTarget(at: point, dragging: tab, surfaces: surfaces(grid: true)), .workspaceThumbnail(WorkspaceID(rawValue: "w2")), "\(point)")
        }
    }

    /// A tab over the card it already belongs to is a reorder among that
    /// card's own cells, not a migration into the workspace it is already in.
    /// The index counts cells the point has passed, the way the strip counts
    /// tabs, so the same drag onto its own card plans a real `moveTab`.
    func testATabOverItsOwnCardReordersAmongThatCardsCells() throws {
        let workspace = WorkspaceID(rawValue: "w1")
        let own = DragSubject.tab(gridThumbnail.id)
        let before = CGPoint(x: gridThumbnail.frame.midX - 10, y: gridThumbnail.frame.midY)
        let after = CGPoint(x: gridThumbnail.frame.midX + 10, y: gridThumbnail.frame.midY)

        XCTAssertEqual(resolveDropTarget(at: before, dragging: own, surfaces: surfaces(grid: true)), .tabStrip(workspace: workspace, insertIndex: 0))
        XCTAssertEqual(resolveDropTarget(at: after, dragging: own, surfaces: surfaces(grid: true)), .tabStrip(workspace: workspace, insertIndex: 1))
        XCTAssertEqual(
            resolveDropTarget(at: cardOneEmptySpace, dragging: own, surfaces: surfaces(grid: true)),
            .tabStrip(workspace: workspace, insertIndex: 1), "past the card's only drawn tab"
        )

        // w1:t2 is the workspace's second tab, so the gap before it is a real
        // move and the gap after it is the place it already has.
        guard case .success(let moved) = plan(dragging: own, onto: .tabStrip(workspace: workspace, insertIndex: 0), model: model()) else {
            return XCTFail("a tab reordered inside its own card has to commit a move")
        }
        XCTAssertEqual(moved.ops, [.moveTab(gridThumbnail.id, insertIndex: 0)])
        guard case .failure(.noOp) = plan(dragging: own, onto: .tabStrip(workspace: workspace, insertIndex: 2), model: model()) else {
            return XCTFail("a tab dropped back in its own gap must commit nothing")
        }
    }

    /// A tab the card is not drawing (a hidden one behind a "+N" tile, or a
    /// drag that outlived the card's own reflow) has no cell to be placed
    /// among, so the card takes it as the migration it was before.
    func testATabTheCardDoesNotDrawStillTargetsTheCard() {
        XCTAssertEqual(
            resolveDropTarget(at: cardOneEmptySpace, dragging: tab, surfaces: surfaces(grid: true)),
            .workspaceThumbnail(WorkspaceID(rawValue: "w1"))
        )
    }

    /// The strip's frames go stale under a shown grid, so the bar they would
    /// place is nowhere the drop lands. The card previews the slot instead.
    func testAGridReorderHasNoInsertionBarOfItsOwn() {
        let target = DropTarget.tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 1)
        XCTAssertNil(dropTargetRect(for: target, surfaces: surfaces(grid: true)))
        XCTAssertNotNil(dropTargetRect(for: target, surfaces: surfaces(grid: false)), "the strip's own bar is untouched")
    }

    /// Cells that wrap are read the way they are drawn: a point below a row
    /// has passed every cell in it, whatever its x.
    func testTheInsertIndexReadsWrappedCellsInDrawingOrder() {
        let cells = (0..<8).map { CGRect(x: 10 + CGFloat($0 % 4) * 100, y: 50 + CGFloat($0 / 4) * 111, width: 90, height: 101) }
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 12, y: 60), cells: cells), 0, "before the first cell")
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 90, y: 60), cells: cells), 1, "past the first cell's centre")
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 12, y: 170), cells: cells), 4, "the second row's start is past the whole first row")
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 12, y: 155), cells: cells), 4, "in the gap between the rows")
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 390, y: 170), cells: cells), 8, "past everything")
        XCTAssertEqual(GridCardLayout.insertIndex(at: CGPoint(x: 390, y: 20), cells: cells), 0, "above the first row")
    }

    /// Every point of a card names a gap of its own list and no more, so a
    /// reorder can never plan an index the workspace has no room for.
    func testEveryPointOfACardNamesAGapOfItsOwnCells() {
        let cells = (0..<6).map { CGRect(x: 10 + CGFloat($0 % 4) * 100, y: 50 + CGFloat($0 / 4) * 111, width: 90, height: 101) }
        for x in stride(from: 0.0, through: 420.0, by: 15.0) {
            for y in stride(from: 30.0, through: 290.0, by: 13.0) {
                let index = GridCardLayout.insertIndex(at: CGPoint(x: x, y: y), cells: cells)
                XCTAssertTrue((0...cells.count).contains(index), "(\(x), \(y)) -> \(index)")
            }
        }
    }

    func testATabBetweenTheCardsTargetsNothing() {
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 300, y: 180), dragging: tab, surfaces: surfaces(grid: true)))
    }

    func testAWorkspaceDragHasNothingToLandOnInTheGrid() {
        for subject in [DragSubject.workspace(WorkspaceID(rawValue: "w1")), .workspaces([WorkspaceID(rawValue: "w1")])] {
            for point in [CGPoint(x: 60, y: 100), CGPoint(x: 170, y: 100), cardOneEmptySpace] {
                XCTAssertNil(resolveDropTarget(at: point, dragging: subject, surfaces: surfaces(grid: true)), "\(subject) at \(point)")
            }
        }
    }

    // MARK: - rects

    func testAGridThumbnailsRectIsItsGridFrameNotTheStripTabOfTheSameID() {
        XCTAssertEqual(dropTargetRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: true)), gridThumbnail.frame)
        XCTAssertEqual(dropTargetRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: false))?.minY, 0)
        XCTAssertEqual(dropFlashRect(for: .tabThumbnail(TabID(rawValue: "w1:t2")), surfaces: surfaces(grid: true)), gridThumbnail.frame)
    }

    /// The same target means a card in the grid and a rail row without it, so
    /// the ghost settles and the flash lands on whichever is on screen. Read
    /// against w2, the card drawing no placeholder of its own.
    func testAWorkspacesRectIsItsCardInTheGridAndItsRailRowWithoutIt() {
        XCTAssertEqual(dropTargetRect(for: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), surfaces: surfaces(grid: true)), cardTwo.frame)
        XCTAssertEqual(dropTargetRect(for: .workspaceThumbnail(WorkspaceID(rawValue: "w1")), surfaces: surfaces(grid: false))?.minX, -190)
        XCTAssertEqual(dropFlashRect(for: .workspaceThumbnail(WorkspaceID(rawValue: "w2")), surfaces: surfaces(grid: true)), cardTwo.frame)
    }

    func testTheDwellOnlyTargetHasARectButNeverFlashes() {
        XCTAssertEqual(dropTargetRect(for: .moreTabs(WorkspaceID(rawValue: "w1")), surfaces: surfaces(grid: true)), plusTile.frame)
        XCTAssertNil(dropFlashRect(for: .moreTabs(WorkspaceID(rawValue: "w1")), surfaces: surfaces(grid: true)))
    }

    // MARK: - planner

    func testADropOnADwellOnlyTargetIsANoOpNeverARejection() {
        for subject in [pane, tab] {
            guard case .failure(.noOp) = plan(dragging: subject, onto: .moreTabs(WorkspaceID(rawValue: "w1")), model: model()) else {
                return XCTFail("\(subject) onto a +N tile must spring back silently")
            }
        }
    }
}
