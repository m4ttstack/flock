import CoreGraphics
import XCTest
@testable import FlockCore

/// A thumbnail's drop preview as one animation carries it: at every sampled
/// fraction the slot and the mini panes tile the tab, neither crossing the
/// other nor opening more than the normal gap between them.
final class DropReflowTests: XCTestCase {
    private static let p1 = PaneID(rawValue: "w1:p1")
    private static let p2 = PaneID(rawValue: "w1:p2")
    private static let p3 = PaneID(rawValue: "w1:p3")
    private static let visitor = PaneID(rawValue: "w2:p9")
    private static let tab = TabID(rawValue: "w1:t1")
    private static let size = CGSize(width: 220, height: 140)
    private static let gap: CGFloat = 4
    private static let fractions: [CGFloat] = [0.25, 0.5, 0.75]

    /// p1 on the left, p2 over p3 on the right.
    private static let layout = LayoutSnapshot(
        workspaceID: WorkspaceID(rawValue: "w1"), tabID: tab, zoomed: false,
        area: CellRect(x: 0, y: 0, width: 80, height: 24), focusedPaneID: p1,
        panes: [
            PaneRect(paneID: p1, focused: true, rect: CellRect(x: 0, y: 0, width: 40, height: 24)),
            PaneRect(paneID: p2, focused: false, rect: CellRect(x: 40, y: 0, width: 40, height: 12)),
            PaneRect(paneID: p3, focused: false, rect: CellRect(x: 40, y: 12, width: 40, height: 12)),
        ],
        splits: []
    )

    private static let exported = ExportedLayoutDescription(
        workspaceID: WorkspaceID(rawValue: "w1"), tabID: tab, zoomed: false, focusedPaneID: p1,
        root: .split(
            direction: .right, ratio: 0.5,
            first: .pane(ExportedLayoutPane(paneID: p1)),
            second: .split(
                direction: .down, ratio: 0.5,
                first: .pane(ExportedLayoutPane(paneID: p2)), second: .pane(ExportedLayoutPane(paneID: p3))
            )
        )
    )

    private func boxes(_ arriving: MiniPaneLayout.Arrival?, tree: Bool) -> [MiniPaneLayout.Placed] {
        MiniPaneLayout.boxes(
            layout: Self.layout, exported: tree ? Self.exported : nil, fallbackPanes: [], size: Self.size,
            padding: 4, gap: Self.gap, displayScale: 2, arriving: arriving
        )
    }

    private func reflow(onto target: DropTarget?, tree: Bool) -> DropReflow {
        let arriving = target.map { MiniPaneLayout.Arrival(pane: Self.visitor, target: $0) }
        return DropReflow(boxes: boxes(arriving, tree: tree), resting: boxes(nil, tree: tree), arriving: arriving)
    }

    private static let targets: [DropTarget] = [
        .paneEdge(p1, .right), .paneEdge(p1, .left), .paneEdge(p1, .top), .paneEdge(p1, .bottom),
        .paneEdge(p2, .bottom), .paneEdge(p3, .left), .paneInterior(p2),
    ]

    /// Positive-area overlap; two rects that only share an edge do not cross.
    private func crosses(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0.01 && shared.height > 0.01
    }

    private func assertTiles(
        _ drawn: (panes: [MiniPaneLayout.Placed], slots: [CGRect]), _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for slot in drawn.slots {
            for pane in drawn.panes {
                XCTAssertFalse(crosses(slot, pane.frame), "\(label): the slot \(slot) crosses \(pane.pane.rawValue) at \(pane.frame)", file: file, line: line)
            }
        }
        for (index, a) in drawn.panes.enumerated() {
            for b in drawn.panes[(index + 1)...] {
                XCTAssertFalse(crosses(a.frame, b.frame), "\(label): \(a.pane.rawValue) crosses \(b.pane.rawValue)", file: file, line: line)
            }
        }
    }

    /// The distance between the slot and the pane it splits, along the split:
    /// never negative, never past the gap the two will rest at.
    private func assertMeets(
        slot: CGRect, target: CGRect, edge: Edge, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let apart: CGFloat
        switch edge {
        case .right: apart = slot.minX - target.maxX
        case .left: apart = target.minX - slot.maxX
        case .bottom: apart = slot.minY - target.maxY
        case .top: apart = target.minY - slot.maxY
        }
        XCTAssertGreaterThanOrEqual(apart, -0.01, "\(label): the slot runs under its target pane", file: file, line: line)
        XCTAssertLessThanOrEqual(apart, Self.gap + 0.01, "\(label): the slot and its target pane open a gap of \(apart)", file: file, line: line)
    }

    private func edge(of target: DropTarget) -> (PaneID, Edge)? {
        switch target {
        case .paneEdge(let pane, let edge): (pane, edge)
        case .paneInterior(let pane): (pane, .right)
        default: nil
        }
    }

    func testTheSlotOpensInStepWithThePanesMakingRoom() {
        for tree in [true, false] {
            let rest = reflow(onto: nil, tree: tree)
            for target in Self.targets {
                let preview = reflow(onto: target, tree: tree)
                XCTAssertNotNil(preview.slot, "\(target): previews no slot")
                for t in Self.fractions {
                    let label = "\(target) tree=\(tree) opening at \(t)"
                    let drawn = DropReflow.drawn(from: rest, to: preview, progress: t)
                    assertTiles(drawn, label)
                    if let (pane, edge) = edge(of: target), let slot = drawn.slots.first,
                       let split = drawn.panes.first(where: { $0.pane == pane })?.frame {
                        assertMeets(slot: slot, target: split, edge: edge, label)
                    }
                }
            }
        }
    }

    func testTheSlotClosesInStepWhenThePointerLeaves() {
        for tree in [true, false] {
            let rest = reflow(onto: nil, tree: tree)
            for target in Self.targets {
                let preview = reflow(onto: target, tree: tree)
                for t in Self.fractions {
                    let label = "\(target) tree=\(tree) closing at \(t)"
                    let drawn = DropReflow.drawn(from: preview, to: rest, progress: t)
                    assertTiles(drawn, label)
                    if let (pane, edge) = edge(of: target), let slot = drawn.slots.first,
                       let split = drawn.panes.first(where: { $0.pane == pane })?.frame {
                        assertMeets(slot: slot, target: split, edge: edge, label)
                    }
                }
            }
        }
    }

    /// The pointer moving to another pane, or to another edge of the same
    /// one, closes the old slot where it is and opens the new one, rather
    /// than sliding one wash across the panes in between.
    func testMovingToAnotherSlotClosesOneAndOpensTheOther() {
        for tree in [true, false] {
            for from in Self.targets {
                for to in Self.targets where to != from {
                    let before = reflow(onto: from, tree: tree)
                    let after = reflow(onto: to, tree: tree)
                    XCTAssertNotEqual(before.slot?.key, after.slot?.key)
                    for t in Self.fractions {
                        let drawn = DropReflow.drawn(from: before, to: after, progress: t)
                        XCTAssertEqual(drawn.slots.count, 2)
                        assertTiles(drawn, "\(from) to \(to) tree=\(tree) at \(t)")
                    }
                }
            }
        }
    }

    /// The opening line sits on the target pane's resting edge, so the slot
    /// starts as nothing at all where the pane still reaches.
    func testTheSlotOpensFromTheTargetPanesOwnEdge() throws {
        let rest = reflow(onto: nil, tree: true)
        let p1 = try XCTUnwrap(rest.panes.first { $0.pane == Self.p1 }?.frame)
        let right = try XCTUnwrap(reflow(onto: .paneEdge(Self.p1, .right), tree: true).slot)
        XCTAssertEqual(right.collapsed.width, 0)
        XCTAssertEqual(right.collapsed.minX, p1.maxX, accuracy: 0.01)
        let top = try XCTUnwrap(reflow(onto: .paneEdge(Self.p1, .top), tree: true).slot)
        XCTAssertEqual(top.collapsed.height, 0)
        XCTAssertEqual(top.collapsed.minY, p1.minY, accuracy: 0.01)
    }

    /// A pane of this tab dropped inside another trades places with it, which
    /// opens from no edge; and the arriving pane is never drawn as a pane.
    func testASwapOpensFromTheCentreAndDrawsTheMovingPaneOnlyAsTheSlot() throws {
        let arriving = MiniPaneLayout.Arrival(pane: Self.p3, target: .paneInterior(Self.p1))
        let preview = DropReflow(boxes: boxes(arriving, tree: true), resting: boxes(nil, tree: true), arriving: arriving)
        let slot = try XCTUnwrap(preview.slot)
        XCTAssertNil(slot.key.edge)
        XCTAssertEqual(slot.collapsed.size, .zero)
        XCTAssertFalse(preview.panes.contains { $0.pane == Self.p3 })
    }

    func testHeldMatchesTheDrawnFraction() {
        let rest = reflow(onto: nil, tree: true)
        let preview = reflow(onto: .paneEdge(Self.p2, .bottom), tree: true)
        let held = DropReflow.held(from: rest, to: preview, progress: 0.4)
        let drawn = DropReflow.drawn(from: rest, to: preview, progress: 0.4)
        XCTAssertEqual(held.panes, drawn.panes)
        XCTAssertEqual(held.slot.map { [$0.frame] }, drawn.slots)
    }
}
