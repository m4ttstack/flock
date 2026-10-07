import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// A click on a mini pane selects it: the accent outline marks it, Return
/// opens it in Workspaces, and Esc puts it down before anything else.
@MainActor
final class ArrangeSelectionTests: XCTestCase {
    private static let windowSize = CGSize(width: 1200, height: 760)
    private static let scale: CGFloat = 2
    private static let migrations = PaneID(rawValue: "w1:p3")

    func testTheSelectedMiniPaneTakesTheAccentOutline() async throws {
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model())
            let window = arrange.makeWindow(size: Self.windowSize)
            await settle(window)
            arrange.drag.toggleGrid()
            await settle(window)
            let pane = ArrangeFixture.apiClaude
            arrange.drag.selectGridPane(pane)
            await settle(window)
            let image = try snapshot(window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("arrange-selected-\(scheme).png"))
            }
            let box = try XCTUnwrap(arrange.drag.surfaces?.grid?.miniPaneFrame(of: pane))
            XCTAssertEqual(
                hex(image, CGPoint(x: box.midX, y: box.minY + 0.5)), theme.palette.accent.hex,
                "\(scheme): the selected pane carries no accent outline"
            )
            window.close()
        }
    }

    func testReturnOpensTheSelectedPaneInWorkspaces() async throws {
        let arrange = try await ArrangeHarness(theme: .tokyoNight, model: ArrangeFixture.model())
        let window = arrange.makeWindow(size: Self.windowSize)
        await settle(window)
        arrange.drag.toggleGrid()
        await settle(window)
        pressKey(window, keyCode: 36, characters: "\r")
        XCTAssertTrue(arrange.drag.isGridShown, "Return with nothing selected closed Arrange")
        arrange.drag.selectGridPane(Self.migrations)
        await settle(window)
        pressKey(window, keyCode: 36, characters: "\r")
        XCTAssertFalse(arrange.drag.isGridShown, "Return did not open the selected pane")
        XCTAssertEqual(arrange.viewModel.selectedTabID, TabID(rawValue: "w1:t2"))
        window.close()
    }

    func testEscPutsTheSelectionDownFirst() async throws {
        let arrange = try await ArrangeHarness(theme: .tokyoNight, model: ArrangeFixture.model())
        let window = arrange.makeWindow(size: Self.windowSize)
        await settle(window)
        arrange.drag.toggleGrid()
        await settle(window)
        arrange.drag.selectGridPane(Self.migrations)
        arrange.drag.updateGrid { $0.escape() }
        XCTAssertNil(arrange.drag.gridSelection)
        XCTAssertTrue(arrange.drag.isGridShown)
        window.close()
    }

    /// Rename Pane in a mini pane's menu begins the shared pane rename, whose
    /// editor the tile hosts over its top edge: an accent-stroked field where
    /// the tile had none. One theme only: a second test window in the same
    /// xctest process ends the editor on its first turn, and a render of the
    /// light theme is looked at by hand through `FLOCK_GRID_RENDER_DIR`.
    func testRenamePaneOpensTheEditorInsideTheTile() async throws {
        try await assertRenameEditor(id: "tokyo-night", scheme: "dark")
    }

    private func assertRenameEditor(id: String, scheme: String) async throws {
        do {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model())
            let window = arrange.makeWindow(size: Self.windowSize)
            await settle(window)
            arrange.drag.toggleGrid()
            await settle(window)
            let pane = ArrangeFixture.apiClaude
            let box = try XCTUnwrap(arrange.drag.surfaces?.grid?.miniPaneFrame(of: pane))
            let before = try snapshot(window)
            XCTAssertEqual(accentPixels(before, in: box, theme: theme), 0, "\(scheme): the tile starts with an accent stroke")

            arrange.viewModel.beginRename(.pane(pane))
            XCTAssertEqual(arrange.viewModel.renameTarget, arrange.viewModel.renameTarget(for: .pane(pane)))
            // One turn, not a settle: a test window is never key, so the
            // editor's focus-loss commit ends it a few turns later.
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertNotNil(arrange.viewModel.renameTarget, "\(scheme): the editor ended itself")
            let image = try snapshot(window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("arrange-rename-\(scheme).png"))
            }
            XCTAssertGreaterThan(accentPixels(image, in: box, theme: theme), 20, "\(scheme): no editor in the tile")
            window.close()
        }
    }

    private func accentPixels(_ image: NSBitmapImageRep, in box: CGRect, theme: Theme) -> Int {
        var count = 0
        for y in Int(box.minY * Self.scale)..<Int(box.maxY * Self.scale) {
            for x in Int(box.minX * Self.scale)..<Int(box.maxX * Self.scale)
            where hex(image, CGPoint(x: CGFloat(x) / Self.scale, y: CGFloat(y) / Self.scale)) == theme.palette.accent.hex {
                count += 1
            }
        }
        return count
    }

    private func pressKey(_ window: NSWindow, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }

    /// The pixel at a point in window space, top-left origin.
    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
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
