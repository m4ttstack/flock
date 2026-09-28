import AppKit
import XCTest

/// Which windows keep flock's saved frame. Decided from the window alone: the
/// content window becomes main before its views have run, so nothing they set
/// may be what qualifies it.
@MainActor
final class MainWindowFrameKeeperTests: XCTestCase {
    private func window(_ style: NSWindow.StyleMask) -> NSWindow {
        NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: style, backing: .buffered, defer: true)
    }

    func testAFreshContentWindowIsKept() {
        XCTAssertTrue(MainWindowFrameKeeper.isFlockWindow(window([.titled, .closable, .resizable])))
    }

    func testSettingsIsNotKeptEvenWhenResizable() {
        let byIdentifier = window([.titled, .closable, .resizable])
        byIdentifier.identifier = FlockWindow.settingsID
        XCTAssertFalse(MainWindowFrameKeeper.isFlockWindow(byIdentifier))

        let byRegistration = window([.titled, .closable, .resizable])
        FlockWindow.settings = byRegistration
        defer { FlockWindow.settings = nil }
        XCTAssertFalse(MainWindowFrameKeeper.isFlockWindow(byRegistration))
    }

    func testPanelsAndFixedWindowsAreNotKept() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        XCTAssertFalse(MainWindowFrameKeeper.isFlockWindow(panel))
        XCTAssertFalse(MainWindowFrameKeeper.isFlockWindow(window([.titled, .closable])))
    }
}
