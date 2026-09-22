import AppKit
import XCTest

/// `PaneCellView` holds its ghostty surface at a fixed size for the whole of a
/// resize gesture, because a narrowing resize DISCARDS what is past the new
/// width and herdr cannot reflow it back. A divider drag has a coordinator to
/// say when that gesture starts and stops; the window's own edge has only
/// AppKit's live-resize notifications, which this view turns into the same
/// pair of answers.
///
/// What is asserted here is the gesture boundary, not the anchoring: a report
/// stuck true holds every pane's terminal frozen for the rest of the session,
/// and a report that never turns true leaves the storm of intermediate resizes
/// in place.
@MainActor
final class WindowLiveResizeReporterTests: XCTestCase {
    func testTheWindowsOwnResizeIsReportedFromStartToEnd() {
        var reports: [Bool] = []
        let window = makeWindow()
        let view = WindowLiveResizeObserverView { reports.append($0) }
        window.contentView?.addSubview(view)
        reports.removeAll()

        post(NSWindow.willStartLiveResizeNotification, for: window)
        XCTAssertEqual(reports, [true], "the start of a live resize must open the hold")

        post(NSWindow.didEndLiveResizeNotification, for: window)
        XCTAssertEqual(reports, [true, false], "the end of a live resize must release the hold")
    }

    /// The Settings scene is a window of its own. Its resize must leave the
    /// canvas alone.
    func testAnotherWindowsResizeIsNotReported() {
        var reports: [Bool] = []
        let window = makeWindow()
        let other = makeWindow()
        let view = WindowLiveResizeObserverView { reports.append($0) }
        window.contentView?.addSubview(view)
        reports.removeAll()

        post(NSWindow.willStartLiveResizeNotification, for: other)

        XCTAssertEqual(reports, [], "a resize of some other window must not reach this one's panes")
    }

    /// AppKit sends the end of a resize to the WINDOW, so a view taken out of
    /// the hierarchy mid-gesture never hears it.
    func testLeavingTheWindowMidResizeReleasesTheHold() {
        var reports: [Bool] = []
        let window = makeWindow()
        let view = WindowLiveResizeObserverView { reports.append($0) }
        window.contentView?.addSubview(view)
        reports.removeAll()

        post(NSWindow.willStartLiveResizeNotification, for: window)
        view.removeFromSuperview()

        XCTAssertEqual(reports.last, false, "a view pulled out mid-gesture must not leave the hold open")

        // The view it left behind must also be deaf to that window from then
        // on, or the hold reopens with nothing able to close it.
        reports.removeAll()
        post(NSWindow.willStartLiveResizeNotification, for: window)
        XCTAssertEqual(reports, [], "a detached view must have unsubscribed, not merely reported false once")
    }

    /// The start notification for a gesture already under way is gone; only
    /// the window's own state still says so.
    func testMountingIntoAWindowAlreadyBeingDraggedReportsTheHold() {
        var reports: [Bool] = []
        let window = ResizingStubWindow()
        let view = WindowLiveResizeObserverView { reports.append($0) }

        window.contentView?.addSubview(view)

        XCTAssertEqual(reports, [true], "a cell mounted mid-drag must start held, not wait for the next gesture")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func post(_ name: Notification.Name, for window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }
}

/// A real window cannot be put into a live resize from a test run; this is the
/// one property the observer reads to catch a gesture already in flight.
private final class ResizingStubWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        isReleasedWhenClosed = false
    }

    override var inLiveResize: Bool { true }
}
