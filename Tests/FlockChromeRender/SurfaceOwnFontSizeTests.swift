import AppKit
import XCTest
@testable import FlockCore

/// The rt modal's surface renders at a size of its own, while every surface
/// is born through an app-wide config push that libghostty hands to all live
/// surfaces, font size included. Creating one surface must not resize another.
@MainActor
final class SurfaceOwnFontSizeTests: XCTestCase {
    private static let colors = GhosttyThemeColors(
        background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
        foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
        ansi: Array(repeating: GhosttyThemeColor(red: 128, green: 128, blue: 128), count: 16)
    )

    func testANewSurfaceLeavesAnotherAtItsOwnFontSize() throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let large = host.makeSession(paneID: PaneID(rawValue: "w1:p1"), configuration: launch(points: 15))
        window.contentView?.addSubview(GhosttySurfaceView(session: large))
        let before = try XCTUnwrap(large.surfaceGeometry(), "the 15pt surface never reported a grid").cellPixels

        let compact = host.makeSession(paneID: PaneID(rawValue: "w1:p2"), configuration: launch(points: 11))
        window.contentView?.addSubview(GhosttySurfaceView(session: compact))
        let compactCell = try XCTUnwrap(compact.surfaceGeometry(), "the 11pt surface never reported a grid").cellPixels
        XCTAssertLessThan(compactCell.height, before.height, "the 11pt surface is not smaller than the 15pt one")

        let after = try XCTUnwrap(large.surfaceGeometry()).cellPixels
        XCTAssertEqual(after.width, before.width, "creating an 11pt surface resized the 15pt one")
        XCTAssertEqual(after.height, before.height, "creating an 11pt surface resized the 15pt one")
    }

    private func launch(points: Double) -> GhosttySession.Launch {
        var launch = GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        launch.fontSizePoints = points
        return launch
    }
}
