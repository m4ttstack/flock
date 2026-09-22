import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Empty rail space is supposed to answer a right-click with New Workspace,
/// asserted through real AppKit hit testing rather than by reading the view's
/// modifiers: `ChromeMenuModelTests` already covers `RailMenuModel.entries()`,
/// which is pure model code that never touches hit testing, so it cannot
/// catch the zone sitting somewhere a click never reaches.
///
/// A `ScrollView` bridges to a real `NSScrollView`, whose clip view claims
/// hit testing across its own bounds; a point past where the scrolled
/// content actually ends resolves no further than that clip view. The zone
/// has to be real content the scroll view's document extends to cover, not a
/// layer drawn behind the scroll view, for a hit there to ever reach it.
@MainActor
final class WorkspaceRailNewWorkspaceZoneHitTestTests: XCTestCase {
    private static let workspace = WorkspaceID(rawValue: "w1")

    private struct Probe: View {
        static let size = CGSize(width: 220, height: 500)
        let viewModel: SessionViewModel
        let drag: DragCoordinator
        let railWidth: RailWidthStore
        let collapse: SectionCollapseStore
        let board: BoardStore
        let toasts: ToastCenter

        var body: some View {
            WorkspaceRail(theme: .tokyoNight, viewModel: viewModel, onSelect: { _ in })
                .environment(drag)
                .environment(railWidth)
                .environment(collapse)
                .environment(board)
                .environment(toasts)
                .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    private func model() -> SessionModel {
        SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [
                WorkspaceRecord(
                    workspaceID: Self.workspace, label: "one", number: 1,
                    activeTabID: TabID(rawValue: "w1:t1"), agentStatus: .idle
                ),
            ],
            tabs: [
                TabRecord(
                    tabID: TabID(rawValue: "w1:t1"), workspaceID: Self.workspace, label: "first",
                    number: 1, paneCount: 1, agentStatus: .idle
                ),
            ],
            panes: [],
            layouts: []
        ))
    }

    private func hostProbe() async throws -> (window: NSWindow, hosting: NSHostingView<Probe>) {
        let viewModel = SessionViewModel(client: OfflineClient())
        viewModel.update(model: model(), connection: .live)
        let toasts = ToastCenter()
        let drag = DragCoordinator(
            toasts: toasts, rearrangeMode: RearrangeMode(),
            commit: { _, _ in fatalError("a hit test never drops") },
            reveal: { _ in }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuite))
        let railWidth = RailWidthStore(userDefaults: defaults)
        let collapse = SectionCollapseStore(userDefaults: defaults)
        let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
        let hosting = NSHostingView(rootView: Probe(
            viewModel: viewModel, drag: drag, railWidth: railWidth, collapse: collapse, board: board, toasts: toasts
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Probe.size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (window, hosting)
    }

    private static let defaultsSuite = "dev.mattstack.flock.rail-hit-test"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.defaultsSuite)
        super.tearDown()
    }

    /// One workspace in a tall rail leaves a wide run of empty space below its
    /// only row. A right-click has to resolve into content the zone's own
    /// gesture and `.contextMenu` are attached to, not into the scroll view's
    /// bare clip view, which answers a click with nothing at all.
    func testEmptyRailSpaceBelowTheLastRowResolvesToTheNewWorkspaceZone() async throws {
        let (window, hosting) = try await hostProbe()
        defer { window.close() }

        let point = CGPoint(x: Probe.size.width / 2, y: Probe.size.height - 40)
        let hit = try XCTUnwrap(hosting.hitTest(hosting.convert(point, to: hosting.superview)))

        XCTAssertFalse(
            hit is NSClipView, "a right-click over empty rail space stops at the scroll view's clip view: \(hit)"
        )
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}
