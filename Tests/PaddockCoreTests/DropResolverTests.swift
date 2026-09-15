import XCTest
import CoreGraphics
@testable import PaddockCore

final class DropResolverTests: XCTestCase {
    private static let p1 = PaneID(rawValue: "w1:p1")
    private static let p2 = PaneID(rawValue: "w1:p2")
    private static let strip = [
        TabItemFrame(id: TabID(rawValue: "t0"), frame: CGRect(x: 0, y: 300, width: 100, height: 40)),
        TabItemFrame(id: TabID(rawValue: "t1"), frame: CGRect(x: 100, y: 300, width: 100, height: 40)),
        TabItemFrame(id: TabID(rawValue: "t2"), frame: CGRect(x: 200, y: 300, width: 100, height: 40))
    ]
    private static let rail = [
        WorkspaceItemFrame(id: WorkspaceID(rawValue: "w0"), frame: CGRect(x: -100, y: 0, width: 60, height: 100)),
        WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: -100, y: 100, width: 60, height: 100)),
        WorkspaceItemFrame(id: WorkspaceID(rawValue: "w2"), frame: CGRect(x: -100, y: 200, width: 60, height: 100))
    ]
    private static let defaultNewTabZone = CGRect(x: 610, y: 0, width: 50, height: 40)
    private static let defaultNewWorkspaceZone = CGRect(x: 610, y: 50, width: 50, height: 40)
    private static let wide = PaneID(rawValue: "w1:wide")

    /// The two-pane 600x300 split fixture: `p1` fills x[0,300], `p2` fills
    /// x[300,600], both spanning the full y[0,300] height.
    private func canvas() throws -> CanvasGeometry {
        let snapshot = try HerdrDecoder.snapshot(fromResponseLine: try fixture("snapshot.json"))
        let layout = try XCTUnwrap(snapshot.layouts.first { $0.splits.count == 1 })
        let grid = CanvasGrid(canvas: CGSize(width: 600, height: 300))
        return CanvasGeometry(layout: layout, grid: grid)
    }

    /// Two panes with an explicit unclaimed band between their cell rects
    /// (x[25,35] of a 60-wide area), unlike `canvas()`'s abutting split: this
    /// is what a point landing on a divider resolves against, since
    /// `CanvasGeometry.paneFrames` itself carries no gutter between adjacent
    /// panes.
    private func gappedCanvas() -> CanvasGeometry {
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:t1"),
            zoomed: false,
            area: CellRect(x: 0, y: 0, width: 60, height: 30),
            focusedPaneID: nil,
            panes: [
                PaneRect(paneID: Self.p1, focused: false, rect: CellRect(x: 0, y: 0, width: 25, height: 30)),
                PaneRect(paneID: Self.p2, focused: false, rect: CellRect(x: 35, y: 0, width: 25, height: 30))
            ],
            splits: []
        )
        return CanvasGeometry(layout: layout, grid: CanvasGrid(canvas: CGSize(width: 600, height: 300)))
    }

    /// A single 400x100 pane: unlike every other fixture's square 300x300
    /// panes, its x and y edge bands differ (80 vs 20), so a test against it
    /// can tell `bandX`/`bandY` apart rather than passing on either value.
    private func nonSquareCanvas() -> CanvasGeometry {
        let layout = LayoutSnapshot(
            workspaceID: WorkspaceID(rawValue: "w1"),
            tabID: TabID(rawValue: "w1:wide"),
            zoomed: false,
            area: CellRect(x: 0, y: 0, width: 40, height: 10),
            focusedPaneID: nil,
            panes: [
                PaneRect(paneID: Self.wide, focused: false, rect: CellRect(x: 0, y: 0, width: 40, height: 10))
            ],
            splits: []
        )
        return CanvasGeometry(layout: layout, grid: CanvasGrid(canvas: CGSize(width: 400, height: 100)))
    }

    private func surfaces(
        canvas: CanvasGeometry,
        tabFrames: [TabItemFrame] = DropResolverTests.strip,
        workspaceFrames: [WorkspaceItemFrame] = DropResolverTests.rail,
        stripFrame: CGRect? = nil,
        railFrame: CGRect? = nil,
        newTabZone: CGRect? = DropResolverTests.defaultNewTabZone,
        newWorkspaceZone: CGRect? = DropResolverTests.defaultNewWorkspaceZone
    ) -> DropSurfaces {
        DropSurfaces(
            canvas: canvas,
            stripWorkspace: WorkspaceID(rawValue: "w1"),
            tabFrames: tabFrames,
            workspaceFrames: workspaceFrames,
            stripFrame: stripFrame,
            railFrame: railFrame,
            newTabZone: newTabZone,
            newWorkspaceZone: newWorkspaceZone
        )
    }

    // MARK: - Pane edge band and interior

    func testPaneEdgeLeftBand() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 0.05 * 300, y: 150)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneEdge(Self.p1, .left))
    }

    func testPaneInteriorCenter() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 150)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneInterior(Self.p1))
    }

    func testPaneEdgeBottomBand() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 0.9 * 300)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneEdge(Self.p1, .bottom))
    }

    func testCornerResolvesToNearerEdgeByRatio() throws {
        // left distance 50 / band 60 = 0.83; top distance 10 / band 60 = 0.17: top is proportionally nearer.
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 50, y: 10)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneEdge(Self.p1, .top))
    }

    func testCornerTieBreaksDeterministically() throws {
        // Square pane: left and top bands both apply at (15, 15) with equal ratios (0.25 each).
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 0.05 * 300, y: 0.05 * 300)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneEdge(Self.p1, .left))
    }

    func testBoundaryDistanceEqualsBandDepthResolvesToEdge() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 60, y: 150) // distance to the left edge is exactly the 20% band depth (60 on a 300-wide pane)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneEdge(Self.p1, .left))
    }

    func testNonSquarePaneBandsAreComputedPerAxis() throws {
        let surfaces = surfaces(canvas: nonSquareCanvas(), tabFrames: [], workspaceFrames: [], newTabZone: nil, newWorkspaceZone: nil)
        // x=200 is far outside the 80pt x band either way. y=50 is outside the true 20pt y band but
        // inside what an 80pt (width-derived) y band would wrongly allow, so this pins bandY to the
        // pane's own height rather than a value shared with bandX.
        let point = CGPoint(x: 200, y: 50)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces), .paneInterior(Self.wide))
    }

    func testDividerPointResolvesNil() throws {
        let surfaces = surfaces(canvas: gappedCanvas())
        let point = CGPoint(x: 300, y: 150) // inside the unclaimed band between the two pane frames
        XCTAssertNil(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces))
    }

    func testPointOutsideEverySurfaceResolvesNil() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -5000, y: -5000)
        XCTAssertNil(resolveDropTarget(at: point, dragging: .pane(Self.p2), surfaces: surfaces))
    }

    // MARK: - PANE subject over the strip / rail

    func testPaneSubjectOverTabItemBodyYieldsThumbnail() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 320) // inside t1's frame
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces), .tabThumbnail(TabID(rawValue: "t1")))
    }

    func testPaneSubjectOverWorkspaceItemBodyYieldsThumbnail() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 150) // inside w1's rail frame
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces), .workspaceThumbnail(WorkspaceID(rawValue: "w1")))
    }

    func testPaneSubjectOverStripGapResolvesNil() throws {
        let gapped = [
            TabItemFrame(id: TabID(rawValue: "t0"), frame: CGRect(x: 0, y: 300, width: 40, height: 40)),
            TabItemFrame(id: TabID(rawValue: "t1"), frame: CGRect(x: 60, y: 300, width: 40, height: 40))
        ]
        let surfaces = surfaces(canvas: try canvas(), tabFrames: gapped)
        let point = CGPoint(x: 50, y: 320) // between the two item bodies, still inside the strip's union bounds
        XCTAssertNil(resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces))
    }

    func testPaneSubjectOverRailGapResolvesNil() throws {
        let gapped = [
            WorkspaceItemFrame(id: WorkspaceID(rawValue: "w0"), frame: CGRect(x: -100, y: 0, width: 60, height: 40)),
            WorkspaceItemFrame(id: WorkspaceID(rawValue: "w1"), frame: CGRect(x: -100, y: 60, width: 60, height: 40))
        ]
        let surfaces = surfaces(canvas: try canvas(), workspaceFrames: gapped)
        let point = CGPoint(x: -70, y: 50) // between the two rail items, still inside the rail's union bounds
        XCTAssertNil(resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces))
    }

    // MARK: - TAB subject over the strip / rail

    func testTabSubjectBetweenItemsResolvesInsertIndex() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 100, y: 320) // at the t0/t1 boundary: t0's center (50) is left of it, t1's (150) is not
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 1)
        )
    }

    func testTabSubjectOverItemBodyResolvesGapIndexNotThumbnail() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 320) // squarely inside t1's body
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 1)
        )
    }

    func testTabSubjectLeftOfFirstItemResolvesIndexZero() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 10, y: 320) // inside t0's own body, left of every item center
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0)
        )
    }

    func testTabSubjectRightOfLastItemResolvesIndexEqualToCount() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 290, y: 320) // inside t2's own body, right of every item center
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 3)
        )
    }

    func testTabSubjectOverEmptyStripResolvesIndexZero() throws {
        let stripFrame = CGRect(x: 0, y: 300, width: 300, height: 40)
        let surfaces = surfaces(canvas: try canvas(), tabFrames: [], stripFrame: stripFrame)
        let point = CGPoint(x: 150, y: 320)
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 0)
        )
    }

    func testTabSubjectOverRailItemBodyYieldsWorkspaceThumbnail() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 150) // inside w1's rail frame
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t0")), surfaces: surfaces),
            .workspaceThumbnail(WorkspaceID(rawValue: "w1"))
        )
    }

    // MARK: - WORKSPACE subject: only rail gaps resolve

    func testWorkspaceSubjectOverPaneResolvesNil() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 150)
        XCTAssertNil(resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w2")), surfaces: surfaces))
    }

    func testWorkspaceSubjectOverStripResolvesNil() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 150, y: 320)
        XCTAssertNil(resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w2")), surfaces: surfaces))
    }

    func testWorkspaceSubjectOverZoneResolvesNil() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 630, y: 20) // inside the new-tab zone
        XCTAssertNil(resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w2")), surfaces: surfaces))
    }

    func testWorkspaceSubjectOverRailGapResolvesInsertIndex() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 100) // at the w0/w1 boundary
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w2")), surfaces: surfaces),
            .workspaceRail(insertIndex: 1)
        )
    }

    func testWorkspaceSubjectOverRailItemBodyStillResolvesInsertIndex() throws {
        // Per the strip's identical rule: an item body under a same-kind subject resolves to the gap index, not a thumbnail.
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 150) // squarely inside w1's body
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w2")), surfaces: surfaces),
            .workspaceRail(insertIndex: 1)
        )
    }

    func testWorkspaceSubjectAboveFirstItemResolvesIndexZero() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 10) // inside w0's own body, above every item center
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w9")), surfaces: surfaces),
            .workspaceRail(insertIndex: 0)
        )
    }

    func testWorkspaceSubjectBelowLastItemResolvesIndexEqualToCount() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: -70, y: 290) // inside w2's own body, below every item center
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w9")), surfaces: surfaces),
            .workspaceRail(insertIndex: 3)
        )
    }

    func testWorkspaceBlockOverRailResolvesTheSameGapIndexAsASingleWorkspace() throws {
        let surfaces = surfaces(canvas: try canvas())
        let block = DragSubject.workspaces([WorkspaceID(rawValue: "w0"), WorkspaceID(rawValue: "w2")])
        for y in stride(from: 5.0, through: 295.0, by: 10.0) {
            let point = CGPoint(x: -70, y: y)
            XCTAssertEqual(
                resolveDropTarget(at: point, dragging: block, surfaces: surfaces),
                resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w0")), surfaces: surfaces),
                "y \(y)"
            )
        }
    }

    func testWorkspaceBlockOverStripCanvasOrZoneResolvesNil() throws {
        let surfaces = surfaces(canvas: try canvas())
        let block = DragSubject.workspaces([WorkspaceID(rawValue: "w0"), WorkspaceID(rawValue: "w2")])
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 150, y: 320), dragging: block, surfaces: surfaces))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 150, y: 150), dragging: block, surfaces: surfaces))
        XCTAssertNil(resolveDropTarget(at: CGPoint(x: 630, y: 20), dragging: block, surfaces: surfaces))
    }

    func testWorkspaceSubjectOverEmptyRailResolvesIndexZero() throws {
        let railFrame = CGRect(x: -100, y: 0, width: 60, height: 300)
        let surfaces = surfaces(canvas: try canvas(), workspaceFrames: [], railFrame: railFrame)
        let point = CGPoint(x: -70, y: 150)
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .workspace(WorkspaceID(rawValue: "w9")), surfaces: surfaces),
            .workspaceRail(insertIndex: 0)
        )
    }

    // MARK: - Zones

    func testNewTabZoneResolvesForPaneSubject() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 630, y: 20)
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces),
            .newTab(WorkspaceID(rawValue: "w1"))
        )
    }

    func testNewWorkspaceZoneResolvesForPaneSubject() throws {
        let surfaces = surfaces(canvas: try canvas())
        let point = CGPoint(x: 630, y: 70)
        XCTAssertEqual(resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces), .newWorkspace)
    }

    // MARK: - Zones are subject-scoped

    /// The real geometry: each zone is the free run INSIDE its own chrome, so
    /// a subject the zone does not serve lands on that chrome instead.
    private func zonedSurfaces(canvas: CanvasGeometry) -> DropSurfaces {
        surfaces(
            canvas: canvas,
            stripFrame: CGRect(x: 0, y: 300, width: 600, height: 40),
            railFrame: CGRect(x: -100, y: 0, width: 60, height: 600),
            newTabZone: CGRect(x: 300, y: 300, width: 250, height: 40),
            newWorkspaceZone: CGRect(x: -100, y: 300, width: 60, height: 300)
        )
    }

    private static let inNewTabZone = CGPoint(x: 400, y: 320)
    private static let inNewWorkspaceZone = CGPoint(x: -70, y: 400)

    func testPaneOverTheStripsFreeRunMakesANewTab() throws {
        XCTAssertEqual(
            resolveDropTarget(at: Self.inNewTabZone, dragging: .pane(Self.p1), surfaces: zonedSurfaces(canvas: try canvas())),
            .newTab(WorkspaceID(rawValue: "w1"))
        )
    }

    /// Past the last tab means "move it to the end", never "make a new tab":
    /// the strip owns the same free run for a tab subject.
    func testTabOverTheStripsFreeRunIsTheEndInsertIndex() throws {
        XCTAssertEqual(
            resolveDropTarget(at: Self.inNewTabZone, dragging: .tab(TabID(rawValue: "t0")), surfaces: zonedSurfaces(canvas: try canvas())),
            .tabStrip(workspace: WorkspaceID(rawValue: "w1"), insertIndex: 3)
        )
    }

    func testWorkspaceOverTheStripsFreeRunResolvesToNothing() throws {
        XCTAssertNil(
            resolveDropTarget(
                at: Self.inNewTabZone, dragging: .workspace(WorkspaceID(rawValue: "w0")), surfaces: zonedSurfaces(canvas: try canvas())
            )
        )
    }

    func testPaneOverTheRailsFreeRunMakesANewWorkspace() throws {
        XCTAssertEqual(
            resolveDropTarget(at: Self.inNewWorkspaceZone, dragging: .pane(Self.p1), surfaces: zonedSurfaces(canvas: try canvas())),
            .newWorkspace
        )
    }

    /// A tab has no verb for a workspace that does not exist yet, and none for
    /// a position in the workspace ORDER either, so the rail's free run is
    /// nothing to it: the drop springs back silently instead of reporting a
    /// move it was never going to make.
    func testTabOverTheRailsFreeRunResolvesToNothing() throws {
        XCTAssertNil(
            resolveDropTarget(
                at: Self.inNewWorkspaceZone, dragging: .tab(TabID(rawValue: "t0")), surfaces: zonedSurfaces(canvas: try canvas())
            )
        )
    }

    /// A rail ITEM still takes a tab: that pair is a real migration.
    func testTabOverARailItemIsStillTheWorkspaceThumbnail() throws {
        XCTAssertEqual(
            resolveDropTarget(
                at: CGPoint(x: -70, y: 150), dragging: .tab(TabID(rawValue: "t0")), surfaces: zonedSurfaces(canvas: try canvas())
            ),
            .workspaceThumbnail(WorkspaceID(rawValue: "w1"))
        )
    }

    /// Splitting and swapping are things a pane does to a pane. A tab over the
    /// canvas resolves to nothing rather than to a canvas target no plan can
    /// serve.
    func testTabOverTheCanvasResolvesToNothing() throws {
        let surfaces = surfaces(canvas: try canvas(), newTabZone: nil, newWorkspaceZone: nil)
        for point in [CGPoint(x: 15, y: 150), CGPoint(x: 150, y: 150)] {
            XCTAssertNil(resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t0")), surfaces: surfaces), "\(point)")
        }
    }

    /// Below the last row means "move it to the bottom", never "make a new
    /// workspace": the rail owns the same free run for a workspace subject.
    func testWorkspaceOverTheRailsFreeRunIsTheEndInsertIndex() throws {
        XCTAssertEqual(
            resolveDropTarget(
                at: Self.inNewWorkspaceZone, dragging: .workspace(WorkspaceID(rawValue: "w0")), surfaces: zonedSurfaces(canvas: try canvas())
            ),
            .workspaceRail(insertIndex: 3)
        )
    }

    // MARK: - Precedence when surfaces overlap

    func testZoneTakesPrecedenceOverOverlappingRail() throws {
        let overlappingRail = [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w0"), frame: DropResolverTests.defaultNewTabZone)]
        let surfaces = surfaces(canvas: try canvas(), workspaceFrames: overlappingRail)
        let point = CGPoint(x: 630, y: 20)
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces),
            .newTab(WorkspaceID(rawValue: "w1"))
        )
    }

    func testRailTakesPrecedenceOverOverlappingCanvas() throws {
        let overlappingRail = [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w0"), frame: CGRect(x: 0, y: 0, width: 50, height: 50))]
        let surfaces = surfaces(canvas: try canvas(), workspaceFrames: overlappingRail, newTabZone: nil, newWorkspaceZone: nil)
        let point = CGPoint(x: 25, y: 25) // inside both the rail item and p1's edge band
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces),
            .workspaceThumbnail(WorkspaceID(rawValue: "w0"))
        )
    }

    func testRailTakesPrecedenceOverOverlappingStrip() throws {
        let overlap = CGRect(x: 1000, y: 1000, width: 50, height: 50)
        let overlappingRail = [WorkspaceItemFrame(id: WorkspaceID(rawValue: "w0"), frame: overlap)]
        let overlappingStrip = [TabItemFrame(id: TabID(rawValue: "t0"), frame: overlap)]
        let surfaces = surfaces(
            canvas: try canvas(),
            tabFrames: overlappingStrip,
            workspaceFrames: overlappingRail,
            newTabZone: nil,
            newWorkspaceZone: nil
        )
        let point = CGPoint(x: 1025, y: 1025) // inside both the rail item and the strip item
        // A TAB subject over its own-kind strip would resolve to `.tabStrip`, not `.workspaceThumbnail`,
        // so this result only holds if the rail tier is checked before the strip tier.
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .tab(TabID(rawValue: "t9")), surfaces: surfaces),
            .workspaceThumbnail(WorkspaceID(rawValue: "w0"))
        )
    }

    func testStripTakesPrecedenceOverOverlappingCanvas() throws {
        let overlappingStrip = [TabItemFrame(id: TabID(rawValue: "t0"), frame: CGRect(x: 0, y: 0, width: 50, height: 50))]
        let surfaces = surfaces(canvas: try canvas(), tabFrames: overlappingStrip, newTabZone: nil, newWorkspaceZone: nil)
        let point = CGPoint(x: 25, y: 25) // inside both the tab item and p1's edge band
        XCTAssertEqual(
            resolveDropTarget(at: point, dragging: .pane(Self.p1), surfaces: surfaces),
            .tabThumbnail(TabID(rawValue: "t0"))
        )
    }
}
