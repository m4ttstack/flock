import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// A pane from one tab held over another tab's handle in a zoomed island,
/// with the preview held part of the way open: the slot has opened by
/// exactly what the tab's own pane has given up, never drawn over it. PNGs
/// are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class DropReflowRenderTests: XCTestCase {
    private static let windowSize = CGSize(width: 1200, height: 760)
    private static let scale: CGFloat = 2
    private static let moving = PaneID(rawValue: "w1:p3")
    private static let movingTab = TabID(rawValue: "w1:t2")
    /// The first pane of the targeted tab, which a drop on its handle splits.
    private static let split = PaneID(rawValue: "w1:p1")

    private var directory: String? {
        ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private struct Rendered {
        let image: NSBitmapImageRep
        /// On screen: the split pane at rest, and the split pane and slot as
        /// the drop leaves them.
        let resting: CGRect
        let shrunk: CGRect
        let slot: CGRect
    }

    private func render(theme: Theme, progress: CGFloat?) async throws -> Rendered {
        let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model())
        let window = arrange.makeWindow(size: Self.windowSize, dropReflow: progress)
        defer { window.close() }
        await settle(window)
        arrange.drag.toggleGrid()
        await settle(window)
        arrange.drag.zoomGrid(into: ArrangeFixture.api)
        await settle(window)
        await settle(window)

        let grid = try XCTUnwrap(arrange.drag.surfaces?.grid)
        let source = try XCTUnwrap(grid.miniPaneFrame(of: Self.moving))
        arrange.drag.beginIfIdle(
            .pane(Self.moving),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )
        let thumbnail = try XCTUnwrap(grid.thumbnails.first { $0.id == ArrangeFixture.apiServerTab }?.frame)
        arrange.drag.move(to: CGPoint(x: thumbnail.midX, y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(arrange.drag.target, .tabThumbnail(ArrangeFixture.apiServerTab))
        await settle(window)

        let area = MiniPaneLayout.paneArea(in: thumbnail, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        let model = try XCTUnwrap(arrange.viewModel.model)
        let landed = MiniPaneLayout.boxes(
            layout: model.layouts[ArrangeFixture.apiServerTab],
            exported: arrange.viewModel.exportedLayout(for: ArrangeFixture.apiServerTab),
            fallbackPanes: [], size: area.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: Self.scale,
            arriving: MiniPaneLayout.Arrival(pane: Self.moving, target: .paneEdge(Self.split, .right))
        )
        func onScreen(_ pane: PaneID) throws -> CGRect {
            try XCTUnwrap(landed.first { $0.pane == pane }?.frame).offsetBy(dx: area.minX, dy: area.minY)
        }
        return Rendered(
            image: try snapshot(window),
            resting: try XCTUnwrap(grid.miniPaneFrame(of: Self.split)),
            shrunk: try onScreen(Self.split),
            slot: try onScreen(Self.moving)
        )
    }

    func testTheSlotOpensInStepWithThePaneMakingRoom() async throws {
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let open = try await render(theme: theme, progress: nil)
            try write(open.image, "dropsync-\(scheme)-100.png")
            XCTAssertGreaterThan(open.slot.minX, open.shrunk.maxX, "\(scheme): the drop does not split on the right")
            let fullWash = hex(open.image, CGPoint(x: open.slot.midX, y: open.slot.midY))

            for progress: CGFloat in [0.25, 0.5, 0.75] {
                let held = try await render(theme: theme, progress: progress)
                try write(held.image, "dropsync-\(scheme)-\(Int(progress * 100)).png")
                let paneEdge = held.resting.maxX + (held.shrunk.maxX - held.resting.maxX) * progress
                let slotEdge = held.resting.maxX + (held.slot.minX - held.resting.maxX) * progress
                XCTAssertLessThanOrEqual(paneEdge, slotEdge, "\(scheme) at \(progress): the pane reaches into the slot")

                // Inside the slot as it is held, the wash; just inside the
                // pane's held edge, where a slot drawn at its full size would
                // already lie, the pane and no wash.
                let inSlot = CGPoint(x: (slotEdge + held.slot.maxX) / 2, y: held.slot.midY)
                XCTAssertEqual(hex(held.image, inSlot), fullWash, "\(scheme) at \(progress): the held slot is not where it opens to")
                let underPane = CGPoint(x: paneEdge - 2, y: held.resting.maxY - 3)
                XCTAssertNotEqual(hex(held.image, underPane), fullWash, "\(scheme) at \(progress): the slot is drawn over the pane")
            }
        }
    }

    /// The pixel at a point in window space, top-left origin.
    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private func write(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let directory else { return }
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * Self.scale), height: Int(bounds.height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.scale, y: Self.scale)
        view.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
}
