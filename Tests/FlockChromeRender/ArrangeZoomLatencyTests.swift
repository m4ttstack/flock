import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// What zooming Arrange into a workspace and back out costs between the
/// click or key and the first frame that shows it, over the four-workspace
/// fixture with every tail already read.
///
/// Two legs are measured: how long the input waits before the zoom state
/// moves at all, and the main-actor pass (layout and draw) that state change
/// provokes, which is the first frame of the transition. Numbers are printed;
/// the budgets sit well above today's cost and below the lag a person sees.
@MainActor
final class ArrangeZoomLatencyTests: XCTestCase {
    private static let windowSize = CGSize(width: 1200, height: 760)
    private static let iterations = 8

    /// Space in, Esc out: the state moves inside the key's own dispatch, so
    /// all of the wait is the frame that follows.
    func testZoomFirstFrameCost() async throws {
        let arrange = try await openArrange()
        let window = arrange.window
        let content = try XCTUnwrap(window.contentView)
        var inFrames: [Double] = []
        var outFrames: [Double] = []
        var inHandlers: [Double] = []
        for _ in 0..<Self.iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            pressKey(window, keyCode: 49, characters: " ")
            let handled = DispatchTime.now().uptimeNanoseconds
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let drawn = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(arrange.harness.drag.gridZoomed, ArrangeFixture.api, "space did not zoom")
            inHandlers.append(Self.ms(start, handled))
            inFrames.append(Self.ms(start, drawn))
            await settle(window)

            let outStart = DispatchTime.now().uptimeNanoseconds
            arrange.harness.drag.updateGrid { $0.escape() }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            outFrames.append(Self.ms(outStart, DispatchTime.now().uptimeNanoseconds))
            XCTAssertNil(arrange.harness.drag.gridZoomed, "esc did not zoom out")
            await settle(window)
        }
        report("zoom in: key handler", inHandlers)
        report("zoom in: key to first frame drawn", inFrames)
        report("zoom out: esc to first frame drawn", outFrames)
        XCTAssertLessThan(median(inFrames), 120, "the first frame of a zoom in costs a person-visible pause")
        XCTAssertLessThan(median(outFrames), 120, "the first frame of a zoom out costs a person-visible pause")
        window.close()
    }

    /// The herd, five tiles, zoomed in and out by the coordinator directly:
    /// the largest island the fixture has.
    func testHerdZoomFirstFrameCost() async throws {
        let arrange = try await openArrange()
        let window = arrange.window
        let content = try XCTUnwrap(window.contentView)
        var inFrames: [Double] = []
        var outFrames: [Double] = []
        for _ in 0..<Self.iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            arrange.harness.drag.zoomGrid(into: ArrangeFixture.herd)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            inFrames.append(Self.ms(start, DispatchTime.now().uptimeNanoseconds))
            await settle(window)
            let outStart = DispatchTime.now().uptimeNanoseconds
            arrange.harness.drag.unzoomGrid()
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            outFrames.append(Self.ms(outStart, DispatchTime.now().uptimeNanoseconds))
            await settle(window)
        }
        report("herd zoom in: first frame drawn", inFrames)
        report("herd zoom out: first frame drawn", outFrames)
        XCTAssertLessThan(median(inFrames), 120)
        XCTAssertLessThan(median(outFrames), 120)
        window.close()
    }

    /// The whole transition as the window's own display cycle runs it: the
    /// main run loop's busy stretches from the zoom until the motion is over.
    /// The longest stretch is the worst hitch; the first is what the input
    /// waits on before anything moves.
    func testZoomTransitionMainThreadCost() async throws {
        let arrange = try await openArrange()
        let window = arrange.window
        var longestIn: [Double] = []
        var totalIn: [Double] = []
        var longestOut: [Double] = []
        var totalOut: [Double] = []
        for _ in 0..<Self.iterations {
            let zoomIn = await busy(during: ChromeMetrics.Grid.zoomDuration + 0.15) {
                arrange.harness.drag.zoomGrid(into: ArrangeFixture.herd)
            }
            longestIn.append(zoomIn.longest)
            totalIn.append(zoomIn.total)
            await settle(window)
            let zoomOut = await busy(during: ChromeMetrics.Grid.zoomDuration + 0.15) {
                arrange.harness.drag.updateGrid { $0.escape() }
            }
            longestOut.append(zoomOut.longest)
            totalOut.append(zoomOut.total)
            await settle(window)
        }
        report("transition in: longest main-thread stretch", longestIn)
        report("transition in: main-thread busy in total", totalIn)
        report("transition out: longest main-thread stretch", longestOut)
        report("transition out: main-thread busy in total", totalOut)
        window.close()
    }

    /// Twelve workspaces, so the grid a zoom out brings back is a full one.
    func testZoomFirstFrameCostWithTwelveWorkspaces() async throws {
        let arrange = try await openArrange(extra: 8)
        let window = arrange.window
        let content = try XCTUnwrap(window.contentView)
        var inFrames: [Double] = []
        var outFrames: [Double] = []
        for _ in 0..<Self.iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            arrange.harness.drag.zoomGrid(into: ArrangeFixture.api)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            inFrames.append(Self.ms(start, DispatchTime.now().uptimeNanoseconds))
            await settle(window)
            let outStart = DispatchTime.now().uptimeNanoseconds
            arrange.harness.drag.updateGrid { $0.escape() }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            outFrames.append(Self.ms(outStart, DispatchTime.now().uptimeNanoseconds))
            await settle(window)
        }
        report("12 workspaces zoom in: first frame drawn", inFrames)
        report("12 workspaces zoom out: first frame drawn", outFrames)
        XCTAssertLessThan(median(inFrames), 120)
        XCTAssertLessThan(median(outFrames), 120)
        window.close()
    }

    /// How long one click on the zoomed island's close control waits before
    /// the zoom state moves: the click is delivered, then the run loop is
    /// turned until the state changes. A gesture holding the click for a
    /// possible second one shows here as the double-click interval.
    func testCloseClickActsWithoutWaitingForADoubleClick() async throws {
        let arrange = try await openArrange()
        let window = arrange.window
        var waits: [Double] = []
        for _ in 0..<4 {
            arrange.harness.drag.zoomGrid(into: ArrangeFixture.api)
            await settle(window)
            let island = try XCTUnwrap(islandFrame(ArrangeFixture.api, arrange), "no zoomed island")
            let start = DispatchTime.now().uptimeNanoseconds
            click(window, at: zoomControl(of: island))
            let deadline = start + 2_000_000_000
            while arrange.harness.drag.gridZoomed != nil, DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertNil(arrange.harness.drag.gridZoomed, "the close control never zoomed out")
            waits.append(Self.ms(start, DispatchTime.now().uptimeNanoseconds))
            // Past the double-click interval, so the next click is a first one.
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            await settle(window)
        }
        report("close click: click to zoom state", waits)
        print(String(format: "ZOOMPATH NSEvent.doubleClickInterval %.0fms", NSEvent.doubleClickInterval * 1000))
        XCTAssertLessThan(median(waits), NSEvent.doubleClickInterval * 1000 / 2, "the close click waited out a double-click")
        window.close()
    }

    /// The grid stays built behind a zoom and reports nothing over the
    /// zoomed island: while zoomed a drop sees the zoomed island alone, and
    /// the moment the zoom ends it sees the grid exactly as it was, with no
    /// item having to report again.
    func testAZoomLeavesTheGridsDropSurfacesAsTheyWere() async throws {
        let arrange = try await openArrange()
        let drag = arrange.harness.drag
        let before = try XCTUnwrap(drag.gridSurfaces)
        drag.zoomGrid(into: ArrangeFixture.api)
        await settle(arrange.window)
        let zoomed = try XCTUnwrap(drag.gridSurfaces)
        XCTAssertEqual(zoomed.cards.map(\.id), [ArrangeFixture.api])
        let gridThumbnail = try XCTUnwrap(before.thumbnails.first { $0.id == ArrangeFixture.apiServerTab })
        let zoomedThumbnail = try XCTUnwrap(zoomed.thumbnails.first { $0.id == ArrangeFixture.apiServerTab })
        XCTAssertGreaterThan(zoomedThumbnail.frame.width, gridThumbnail.frame.width * 1.5)
        drag.updateGrid { $0.escape() }
        XCTAssertEqual(drag.gridSurfaces, before, "zooming out did not hand back the grid's surfaces at once")
        await settle(arrange.window)
        XCTAssertEqual(drag.gridSurfaces, before)
        arrange.window.close()
    }

    /// The island header acts on the click that makes a double-click and
    /// on no other: a first click, a right-click and a triple click all
    /// leave the zoom alone. Read off the event, since a test window never
    /// takes a SwiftUI tap: a test process is never the active app.
    func testOnlyThePrimaryDoubleClickZooms() {
        func event(_ type: NSEvent.EventType, count: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: count, pressure: 0
            )
        }
        XCTAssertTrue(NSEvent.isPrimaryDoubleClick(event(.leftMouseUp, count: 2)))
        XCTAssertFalse(NSEvent.isPrimaryDoubleClick(event(.leftMouseUp, count: 1)))
        XCTAssertFalse(NSEvent.isPrimaryDoubleClick(event(.leftMouseUp, count: 3)))
        XCTAssertFalse(NSEvent.isPrimaryDoubleClick(event(.rightMouseUp, count: 2)))
        XCTAssertFalse(NSEvent.isPrimaryDoubleClick(event(.leftMouseUp, count: 2, flags: .control)))
        XCTAssertFalse(NSEvent.isPrimaryDoubleClick(nil))
    }

    // MARK: - helpers

    private struct Open {
        let harness: ArrangeHarness
        let window: NSWindow
    }

    private func openArrange(extra: Int = 0) async throws -> Open {
        let harness = try await ArrangeHarness(theme: .tokyoNight, model: ArrangeFixture.model(extra: extra))
        let window = harness.makeWindow(size: Self.windowSize)
        // On screen, or the window's controls take no clicks at all.
        window.orderFront(nil)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)
        // Every tail read and cached before anything is timed.
        for pane in harness.viewModel.model?.panes.keys.sorted(by: { $0.rawValue < $1.rawValue }) ?? [] {
            harness.viewModel.refreshPaneTail(for: pane)
        }
        await settle(window)
        await settle(window)
        return Open(harness: harness, window: window)
    }

    private func pressKey(_ window: NSWindow, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }

    /// `point` is in window space with a top-left origin.
    private func click(_ window: NSWindow, at point: CGPoint) {
        let height = window.contentView?.superview?.bounds.height ?? window.frame.height
        let location = NSPoint(x: point.x, y: height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApplication.shared.sendEvent(event)
        }
    }

    /// An island's frame in window space with a top-left origin, which is
    /// the drag space the grid reports its items in.
    private func islandFrame(_ id: WorkspaceID, _ arrange: Open) -> CGRect? {
        arrange.harness.drag.gridItemFrame(for: .card(id))
    }

    /// The middle of the zoom control at the trailing end of an island's
    /// header.
    private func zoomControl(of island: CGRect) -> CGPoint {
        CGPoint(
            x: island.maxX - ChromeMetrics.Grid.islands.horizontalPadding - ChromeMetrics.Grid.zoomControlSize / 2,
            y: island.minY + ChromeMetrics.Grid.islandTopPadding + ChromeMetrics.Grid.islandHeaderHeight / 2
        )
    }

    /// Runs `change`, then lets the main run loop turn for `seconds`,
    /// timing every stretch it spends awake.
    private func busy(during seconds: Double, _ change: () -> Void) async -> (longest: Double, total: Double) {
        let meter = BusyMeter()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            meter.mark(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        meter.begin()
        change()
        try? await Task.sleep(for: .seconds(seconds))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return (meter.longest, meter.total)
    }

    private static func ms(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        print(String(
            format: "ZOOMPATH %@: min %.1fms median %.1fms max %.1fms",
            label, sorted.first ?? 0, median(samples), sorted.last ?? 0
        ))
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class BusyMeter: @unchecked Sendable {
    private var awakeSince: UInt64?
    private(set) var longest: Double = 0
    private(set) var total: Double = 0

    func begin() { awakeSince = DispatchTime.now().uptimeNanoseconds }

    func mark(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        if activity == .afterWaiting {
            awakeSince = now
        } else if let since = awakeSince {
            let stretch = Double(now - since) / 1_000_000
            longest = max(longest, stretch)
            total += stretch
            awakeSince = nil
        }
    }
}
