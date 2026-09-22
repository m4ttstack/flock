import AppKit
import FlockCore
import SwiftUI
import XCTest

/// What a workspace click costs on flock's side, measured rather than assumed.
/// Three legs are reachable with no herdr and no launched app:
///
/// 1. the view-model's own selection move (`select(workspace:)`),
/// 2. the SwiftUI pass that selection provokes, over the real `MainWindow`
///    hosted offscreen at window size: rail, strip and the whole pane canvas,
/// 3. the same pass plus AppKit's draw of it.
///
/// The wire leg (`workspace.focus`) is not measured here: it needs a real
/// herdr, and the report carries its number from a scratch session instead.
///
/// Numbers are printed, and the assertions are budgets an order of magnitude
/// above what the path costs today: they exist to catch a regression that
/// changes the shape of the cost, not to pin a machine's exact speed.
@MainActor
final class WorkspaceClickLatencyTests: XCTestCase {
    private static let windowSize = CGSize(width: 1200, height: 800)
    private static let iterations = 40

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: latencyDefaultsSuite)
        super.tearDown()
    }

    /// The whole main-actor cost of one rail click, from the selection move to
    /// pixels: what the user would wait if the click reached the view model the
    /// instant the mouse went down.
    func testWorkspaceSwitchRepaintCost() async throws {
        let harness = try await Harness()
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let contentView = try XCTUnwrap(window.contentView)
        let targets = [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w3"), WorkspaceID(rawValue: "w4")]

        var selectOnly: [Double] = []
        var throughLayout: [Double] = []
        var throughDraw: [Double] = []
        for index in 0..<Self.iterations {
            let target = targets[index % targets.count]
            let before = DispatchTime.now().uptimeNanoseconds
            harness.viewModel.select(workspace: target)
            let selected = DispatchTime.now().uptimeNanoseconds
            contentView.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            contentView.displayIfNeeded()
            let drawn = DispatchTime.now().uptimeNanoseconds
            selectOnly.append(Double(selected - before) / 1_000_000)
            throughLayout.append(Double(laidOut - before) / 1_000_000)
            throughDraw.append(Double(drawn - before) / 1_000_000)
            XCTAssertEqual(harness.viewModel.selectedWorkspaceID, target)
        }

        report("select(workspace:) alone", selectOnly)
        report("select + SwiftUI layout", throughLayout)
        report("select + layout + draw", throughDraw)
        XCTAssertLessThan(median(throughDraw), 100, "a workspace switch now costs a tenth of a second of main-actor work")
        window.close()
    }

    /// The delay a chrome row's selection waits out before it ever reaches the
    /// view model when a `count: 2` tap for rename sits over its single tap:
    /// SwiftUI holds the single one until a second click can no longer arrive.
    /// `NSEvent.doubleClickInterval` is the width of that window, read from the
    /// running system rather than assumed. `ChromeRowClick` is why no row in
    /// the chrome carries that pair any more.
    func testDoubleClickIntervalIsTheDelayAGatedTapWouldWaitOut() {
        let interval = NSEvent.doubleClickInterval
        print("CLICKPATH NSEvent.doubleClickInterval: \(String(format: "%.0f", interval * 1000))ms")
        XCTAssertGreaterThan(interval, 0)
    }

    /// What a pane the warm pool has no surface for costs the main actor when
    /// the switch brings it on screen: two FIFOs, the PATH lookup for herdr,
    /// and the session object. The bridge child is NOT in this number -- a
    /// session only builds its libghostty surface once its view enters a
    /// window, which is where the PTY child is spawned.
    ///
    /// The FIRST cold pane in a process is reported apart from the rest: it is
    /// the one that can find `ToolPath.resolved` unresolved and block the main
    /// actor on a login-shell PATH probe, which `ToolPath.warm` is racing to
    /// absorb on a background queue from launch.
    func testColdPaneSurfaceCostOnTheMainActor() async throws {
        let host = try XCTUnwrap(try? GhosttyHost(), "libghostty would not initialize")
        let factory = GhosttyControlSurfaceFactory(
            host: host, socketPath: "/tmp/flock-latency-never-connected.sock",
            themeColors: { Theme.tokyoNight.ghosttyThemeColors() }, fontSizePoints: { 13 },
            optionAsAlt: { .left }, scrollSpeed: { .normal }
        )
        var samples: [Double] = []
        for index in 0..<12 {
            let before = DispatchTime.now().uptimeNanoseconds
            let surface = await factory.makeSurface(
                for: PaneID(rawValue: "w9:p\(index)"), onUserInput: {}, onClearRequested: {},
                onScreenActivity: { _ in false }
            )
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000)
            await surface.detach()
        }
        print(String(format: "CLICKPATH cold pane surface, first in the process: %.2fms", samples[0]))
        report("cold pane surface, every one after", Array(samples.dropFirst()))
        XCTAssertLessThan(
            median(Array(samples.dropFirst())), 50,
            "a cold pane now costs the main actor a twentieth of a second before it can paint"
        )
    }

    // MARK: - helpers

    private func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        print(String(
            format: "CLICKPATH %@: min %.2fms median %.2fms p90 %.2fms max %.2fms",
            label, sorted.first ?? 0, median(samples),
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))], sorted.last ?? 0
        ))
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private let latencyDefaultsSuite = "dev.mattstack.flock.workspace-click-latency"

/// The real `MainWindow` over a model where every workspace has a layout,
/// so a switch repaints a full canvas rather than the empty-state text.
@MainActor
private struct Harness {
    let themeStore: ThemeStore
    let textSize: TerminalTextSizeStore
    let railWidth: RailWidthStore
    let toasts: ToastCenter
    let rearrange: RearrangeMode
    let drag: DragCoordinator
    let dividerDrag: DividerDragCoordinator
    let chatStore: ChatStore
    let optionAsAlt: OptionAsAltStore
    let viewModel: SessionViewModel

    init() async throws {
        ChromeType.install()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: latencyDefaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(.tokyoNight)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        railWidth = RailWidthStore(userDefaults: defaults)
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a latency run never drops") },
            reveal: { _ in }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }))
        optionAsAlt = OptionAsAltStore(userDefaults: defaults)
        // No chat binary, same as a machine without one: a latency run does
        // not exercise the chat button at all.
        chatStore = ChatStore(toasts: ToastCenter(), probe: { nil }, makeRunner: { _ in fatalError("no verb runs") })
        await chatStore.probeTask.value
        viewModel = SessionViewModel(client: OfflineClient(), ghosttyFactory: GroundFactory())
        viewModel.update(model: try Self.model(), connection: .live)
        for pane in Self.everyPane {
            _ = await viewModel.attachPane(pane)
        }
    }

    func makeWindow(size: CGSize) -> NSWindow {
        // Resolves to no herdr, so the patch banner stays off and this
        // measures the same chrome on every machine. A real probe would make
        // the result depend on whichever herdr the host happens to have.
        let root = MainWindow(
            viewModel: viewModel,
            sessionLabel: "latency",
            herdrMousePatchStore: HerdrMousePatchStore(resolveBinaryPath: { nil }, resolveArtifactPath: { nil })
        )
            .environment(themeStore)
            .environment(textSize)
            .environment(railWidth)
            .environment(toasts)
            .environment(rearrange)
            .environment(drag)
            .environment(dividerDrag)
            .environment(chatStore)
            .environment(optionAsAlt)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    static let everyPane: [PaneID] = (1...5).flatMap { workspace in
        (1...2).map { PaneID(rawValue: "w\(workspace):p\($0)") }
    }

    /// Five workspaces, one tab each, two side-by-side panes each, and a
    /// layout for every tab.
    static func model() throws -> SessionModel {
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        var layoutRows: [[String: Any]] = []
        let area: [String: Int] = ["x": 0, "y": 0, "width": 200, "height": 50]
        for index in 1...5 {
            let workspace = "w\(index)"
            let tab = "\(workspace):t1"
            workspaceRows.append([
                "workspace_id": workspace, "label": "workspace \(index)", "number": index,
                "active_tab_id": tab, "agent_status": "idle",
            ])
            tabRows.append([
                "tab_id": tab, "workspace_id": workspace, "label": "main",
                "number": 1, "pane_count": 2, "agent_status": "idle",
            ])
            for pane in 1...2 {
                paneRows.append([
                    "pane_id": "\(workspace):p\(pane)", "workspace_id": workspace, "tab_id": tab,
                    "focused": pane == 1, "agent_status": "idle", "revision": 1,
                    "terminal_title_stripped": "shell", "cwd": "/private/tmp",
                ])
            }
            layoutRows.append([
                "workspace_id": workspace, "tab_id": tab, "zoomed": false, "area": area,
                "focused_pane_id": "\(workspace):p1",
                "panes": [
                    ["pane_id": "\(workspace):p1", "focused": true, "rect": ["x": 0, "y": 0, "width": 100, "height": 50]],
                    ["pane_id": "\(workspace):p2", "focused": false, "rect": ["x": 100, "y": 0, "width": 100, "height": 50]],
                ],
                "splits": [["id": "split_0_root", "direction": "right", "ratio": 0.5, "rect": area]],
            ])
        }
        let snapshot: [String: Any] = [
            "version": "0.9.1", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t1",
            "focused_pane_id": "w1:p1", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": layoutRows,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw Offline()
    }
}

@MainActor
private final class GroundSurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}
