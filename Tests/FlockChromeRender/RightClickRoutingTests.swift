import AppKit
import XCTest
@testable import FlockCore

/// `GhosttySurfaceView.rightMouseDown` is where the pane's real state reaches
/// `RightClickDisposition.decide`. A view with a session that never attached
/// has no libghostty surface and no bridge child, so nothing here spawns or
/// draws; the recorded disposition is what the click would have done.
@MainActor
final class RightClickRoutingTests: XCTestCase {
    func testAPaneOnTheMenuOpensItAndSendsOptionToTheProgram() throws {
        let view = try surfaceView(focused: true, capture: true)
        XCTAssertEqual(try disposition(of: view, option: false), .menu, "a pane starts on the menu")
        XCTAssertEqual(try disposition(of: view, option: true), .forwardToPane)
    }

    func testAPaneSwitchedToItsProgramSendsItThePlainClickAndOptionToTheMenu() throws {
        let view = try surfaceView(focused: true, capture: true)
        view.rightClickMode = .program
        XCTAssertEqual(try disposition(of: view, option: false), .forwardToPane)
        XCTAssertEqual(try disposition(of: view, option: true), .menu)
    }

    func testTheModalSendsEveryRightClickToItsProgram() throws {
        let view = try surfaceView(focused: true, capture: true)
        view.rightClickMode = .programOnly
        XCTAssertEqual(try disposition(of: view, option: false), .forwardToPane)
        XCTAssertEqual(try disposition(of: view, option: true), .forwardToPane)
    }

    func testAPlainShellSendsAPlainRightClickToTheMenu() throws {
        let view = try surfaceView(focused: true, capture: false)
        view.rightClickMode = .program
        XCTAssertEqual(try disposition(of: view, option: false), .menu)
    }

    private func disposition(of view: GhosttySurfaceView, option: Bool) throws -> RightClickDisposition {
        view.rightMouseDown(with: try rightClick(option: option))
        return view.rightButtonDownDisposition
    }

    private func surfaceView(focused: Bool, capture: Bool) throws -> GhosttySurfaceView {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let session = host.makeSession(
            paneID: PaneID(rawValue: "w1:p1"),
            configuration: GhosttySession.Launch(commandArgv: ["/usr/bin/true"], themeColors: Self.colors)
        )
        XCTAssertNil(session.surface, "a session that never attached must have no surface to spawn a child for")
        session.setMouseCapture(enabled: capture)
        let view = GhosttySurfaceView(session: session)
        view.wantsFocus = focused
        return view
    }

    private func rightClick(option: Bool) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: option ? [.option] : [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private static let colors = GhosttyThemeColors(
        background: GhosttyThemeColor(red: 0, green: 0, blue: 0),
        foreground: GhosttyThemeColor(red: 255, green: 255, blue: 255),
        ansi: Array(repeating: GhosttyThemeColor(red: 128, green: 128, blue: 128), count: 16)
    )
}
