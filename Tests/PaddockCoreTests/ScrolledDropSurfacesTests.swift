import CoreGraphics
import XCTest
@testable import PaddockCore

/// A strip and a rail whose content overflows and has scrolled: item frames
/// are on screen, but some lie outside the scroll view that shows them.
final class ScrolledDropSurfacesTests: XCTestCase {
    private let stripFrame = CGRect(x: 0, y: 300, width: 460, height: 40)
    /// The strip's scroll view stops where its trailing readout begins.
    private let stripViewport = CGRect(x: 0, y: 300, width: 300, height: 40)
    private let railFrame = CGRect(x: -200, y: 0, width: 200, height: 280)
    private let railViewport = CGRect(x: -200, y: 0, width: 199, height: 200)

    /// Scrolled 150pt left: t0 is wholly off the leading edge, and t4 spans
    /// x 250 to 350, half of it under the readout.
    private var tabs: [TabItemFrame] {
        (0..<5).map { TabItemFrame(id: TabID(rawValue: "t\($0)"), frame: CGRect(x: CGFloat($0) * 100 - 150, y: 300, width: 100, height: 40)) }
    }

    /// Scrolled so w3 lies below the rail's visible area.
    private var rows: [WorkspaceItemFrame] {
        (0..<4).map { WorkspaceItemFrame(id: WorkspaceID(rawValue: "w\($0)"), frame: CGRect(x: -190, y: CGFloat($0) * 70, width: 180, height: 60)) }
    }

    private func surfaces(clipped: Bool) -> DropSurfaces {
        DropSurfaces(
            canvas: .empty,
            stripWorkspace: WorkspaceID(rawValue: "w0"),
            tabFrames: tabs,
            workspaceFrames: rows,
            stripFrame: stripFrame,
            railFrame: railFrame,
            stripViewport: clipped ? stripViewport : nil,
            railViewport: clipped ? railViewport : nil,
            newTabZone: nil,
            newWorkspaceZone: nil
        )
    }

    private let pane = DragSubject.pane(PaneID(rawValue: "w0:p1"))

    func testAPaneOverATabScrolledUnderTheReadoutHitsNothing() {
        let underReadout = CGPoint(x: 330, y: 320)
        XCTAssertEqual(resolveDropTarget(at: underReadout, dragging: pane, surfaces: surfaces(clipped: false)), .tabThumbnail(TabID(rawValue: "t4")))
        XCTAssertNil(resolveDropTarget(at: underReadout, dragging: pane, surfaces: surfaces(clipped: true)))
    }

    func testAPaneOverAVisibleTabStillHitsIt() {
        XCTAssertEqual(
            resolveDropTarget(at: CGPoint(x: 120, y: 320), dragging: pane, surfaces: surfaces(clipped: true)),
            .tabThumbnail(TabID(rawValue: "t2"))
        )
    }

    /// Two tab centers (t0 at -100, t1 at 0) lie at or left of the viewport's
    /// leading edge; both still count toward the gap a point just inside it
    /// names.
    func testATabReorderCountsTabsScrolledOutOfView() {
        XCTAssertEqual(
            resolveDropTarget(at: CGPoint(x: 10, y: 320), dragging: .tab(TabID(rawValue: "t3")), surfaces: surfaces(clipped: true)),
            .tabStrip(workspace: WorkspaceID(rawValue: "w0"), insertIndex: 2)
        )
    }

    func testAPaneOverARowBelowTheRailViewportHitsNothingButAReorderStillCountsIt() {
        let belowViewport = CGPoint(x: -100, y: 240)
        XCTAssertEqual(resolveDropTarget(at: belowViewport, dragging: pane, surfaces: surfaces(clipped: false)), .workspaceThumbnail(WorkspaceID(rawValue: "w3")))
        XCTAssertNil(resolveDropTarget(at: belowViewport, dragging: pane, surfaces: surfaces(clipped: true)))
        XCTAssertEqual(
            resolveDropTarget(at: belowViewport, dragging: .workspace(WorkspaceID(rawValue: "w0")), surfaces: surfaces(clipped: true)),
            .workspaceRail(insertIndex: 3)
        )
    }

    /// The bar for a gap past the visible run is pinned inside the viewport
    /// rather than drawn over the readout.
    func testAReorderBarIsKeptInsideTheStripViewport() throws {
        let unclipped = try XCTUnwrap(dropTargetRect(for: .tabStrip(workspace: WorkspaceID(rawValue: "w0"), insertIndex: 5), surfaces: surfaces(clipped: false)))
        let clipped = try XCTUnwrap(dropTargetRect(for: .tabStrip(workspace: WorkspaceID(rawValue: "w0"), insertIndex: 5), surfaces: surfaces(clipped: true)))
        XCTAssertGreaterThan(unclipped.maxX, stripViewport.maxX)
        XCTAssertLessThanOrEqual(clipped.maxX, stripViewport.maxX)
    }
}
