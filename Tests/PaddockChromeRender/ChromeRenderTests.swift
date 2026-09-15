import AppKit
import PaddockCore
import SwiftUI
import XCTest

/// Renders the real `MainWindow` offscreen from fixture data, with no app host
/// and no herdr connection. Pane bodies are ground-only surfaces, since
/// terminal content is not part of the chrome. PNGs are written only when
/// `PADDOCK_CHROME_RENDER_DIR` is set; the pixel and window assertions always
/// run.
@MainActor
final class ChromeRenderTests: XCTestCase {
    static let defaultsSuite = "dev.mattstack.paddock.chrome-render"
    private static let windowSize = CGSize(width: 900, height: 560)
    private static let themeIDs = [
        "tokyo-night", "dracula",
        "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
        "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
    ]

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.defaultsSuite)
        super.tearDown()
    }

    func testEveryChromeRolePaintsItsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in Self.themeIDs {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            assertSamples(image, theme: theme)
            window.close()
        }
    }

    /// A face that failed to register resolves to the system font with no
    /// error, so only a lookup by name shows the chrome is really in Inter.
    func testChromeFacesResolveToInterWithDistinctWeights() throws {
        ChromeType.install()
        var weights: [CGFloat] = []
        for weight in ChromeType.Weight.allCases {
            let font = try XCTUnwrap(NSFont(name: weight.postScriptName, size: 14), weight.postScriptName)
            XCTAssertEqual(font.familyName, "Inter", weight.postScriptName)
            let traits = try XCTUnwrap(CTFontCopyTraits(font) as? [CFString: Any])
            weights.append(try XCTUnwrap(traits[kCTFontWeightTrait] as? CGFloat, weight.postScriptName))
        }
        XCTAssertEqual(weights, weights.sorted())
        XCTAssertEqual(Set(weights).count, weights.count, "\(weights)")
    }

    func testWindowButtonsCenterOnTheTitleBarAndStayThereAfterAResize() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        assertButtonsCentered(in: window)

        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(window)
        assertButtonsCentered(in: window)
        window.close()
    }

    /// AppKit rebuilds the standard buttons on a style mask change. The next
    /// pass must move its frame observers onto the new buttons, or AppKit
    /// laying one out again later leaves it off center until some window event.
    func testReplacedWindowButtonsAreObservedAndKeptCentered() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let before = WindowButtonCentering.buttons(of: window)

        window.styleMask.remove(.titled)
        window.styleMask.insert(.titled)
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(window)
        let after = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(zip(before, after).contains { $0 === $1 }, "the style mask change kept the same buttons, so nothing was replaced")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + 6))
        assertButtonsCentered(in: window)
        window.close()
    }

    /// The system title bar is taller than the chrome's, so the top of the tab
    /// strip lies inside it. A press there must stay with the strip: some view
    /// of ours at that point opts out of moving the window. The chrome title
    /// bar drags and double-clicks through `TitleBarMouseView`, so every point
    /// on it must reach that view.
    func testTabStripTopInsideTheSystemTitleBarDoesNotMoveTheWindow() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let systemTitleBarHeight = window.frame.height - window.contentLayoutRect.maxY
        let stripTop = ChromeMetrics.TitleBar.height
        XCTAssertGreaterThan(systemTitleBarHeight, stripTop + 1, "the system title bar no longer reaches the tab strip, so this test exercises nothing")

        let stripTopEdge = CGPoint(x: 260, y: stripTop + 1)
        XCTAssertTrue(contentViews(at: stripTopEdge, in: window).contains { !$0.mouseDownCanMoveWindow })
        for titlePoint in [CGPoint(x: 450, y: 10), CGPoint(x: 250, y: 10), CGPoint(x: 800, y: 3)] {
            XCTAssertTrue(contentViews(at: titlePoint, in: window).contains { $0 is TitleBarMouseView }, "\(titlePoint)")
        }
        window.close()
    }

    /// The All Workspaces grid from fixture layouts: at rest with a pane's
    /// hover card open, then with the nine-tab card expanded. PNGs are
    /// written only when `PADDOCK_GRID_RENDER_DIR` is set; the samples and
    /// the no-attach check always run.
    func testAllWorkspacesGridRendersFromLayoutsWithoutAttachingAPane() async throws {
        let directory = ProcessInfo.processInfo.environment["PADDOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let boxes = MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: thumbnail.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        )
        let claude = try XCTUnwrap(boxes.first { $0.pane == GridFixture.claudePane })
        harness.drag.gridHoverMoved(pane: claude.pane, pointer: CGPoint(x: thumbnail.minX + claude.frame.midX, y: thumbnail.minY + claude.frame.midY))
        harness.drag.gridHoverIntentElapsed(pane: claude.pane)
        await settle(window)
        let rest = try snapshot(window)
        if let directory {
            try XCTUnwrap(rest.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-hover.png"))
        }
        for pane in model.panes.keys {
            XCTAssertNil(harness.viewModel.ghosttySurface(for: pane), "the grid attached \(pane.rawValue)")
        }
        assertGridSamples(rest, theme: .tokyoNight)

        harness.drag.gridHoverEnded(pane: claude.pane)
        harness.drag.toggleGridCard(GridFixture.repoTools)
        await settle(window)
        let expanded = try snapshot(window)
        if let directory {
            try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-expanded.png"))
        }
        assertGridSamples(expanded, theme: .tokyoNight)
        window.close()
    }

    /// Points are top-left in the 900x560 window: the title bar, the grid
    /// header over its rule, the canvas margin, and the first card's border,
    /// fill and focused accent bar.
    private func assertGridSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let samples: [(String, CGPoint, RGB)] = [
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/header", CGPoint(x: 450, y: 28), roles.chrome),
            ("rule/header", CGPoint(x: 450, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 5, y: 120), roles.canvas),
            ("paneBorder/card", CGPoint(x: 13.25, y: 150), roles.paneBorder),
            ("pane/card", CGPoint(x: 18, y: 80), roles.pane),
            ("accent/focusedBar", CGPoint(x: 27.5, y: 94), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    // MARK: - Helpers

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the role hexes.
    private func snapshot(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        view.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// Straight from the bitmap's bytes, with no color-space conversion on the
    /// way out.
    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat = 2) -> String {
        guard let data = image.bitmapData else { return "?" }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    /// Points are top-left, in the 900x560 window. Indicator samples sit on
    /// each row's 3x15 bar: the selected row is accent, the others take the
    /// fixture's workspace status. Rows start at y 61 on a 28pt pitch; tabs
    /// start at x 203 on a 103pt pitch, 28 tall on a strip spanning y 26 to 62.
    private func assertSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let palette = theme.palette
        let samples: [(String, CGPoint, RGB)] = [
            ("indicator/selected", CGPoint(x: 21, y: 74), roles.accent),
            ("indicator/blocked", CGPoint(x: 21, y: 102), palette.red),
            ("indicator/working", CGPoint(x: 21, y: 130), palette.yellow),
            ("indicator/done", CGPoint(x: 21, y: 158), palette.teal),
            ("indicator/idle", CGPoint(x: 21, y: 186), roles.chrome),
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/strip", CGPoint(x: 700, y: 30), roles.chrome),
            ("chrome/rail", CGPoint(x: 75, y: 400), roles.chrome),
            ("rule/rail", CGPoint(x: 192.25, y: 400), roles.rule),
            ("selection/row", CGPoint(x: 100, y: 64), roles.selection),
            ("tabRest", CGPoint(x: 253, y: 40), roles.tabRest),
            ("selection/tab", CGPoint(x: 459, y: 40), roles.selection),
            ("accent/underline", CGPoint(x: 459, y: 61.25), roles.accent),
            ("rule/strip", CGPoint(x: 700, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 196, y: 400), roles.canvas),
            ("paneBorder", CGPoint(x: 199.25, y: 400), roles.paneBorder),
            ("pane", CGPoint(x: 300, y: 400), roles.pane),
            ("canvas/gutter", CGPoint(x: 546, y: 400), roles.canvas),
            ("accent/focusedLeading", CGPoint(x: 551.25, y: 400), roles.accent),
            ("accent/focused", CGPoint(x: 893.25, y: 400), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    private func assertButtonsCentered(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        for button in buttons {
            let inWindow = button.convert(button.bounds, to: nil)
            let centerFromTop = window.frame.height - inWindow.midY
            XCTAssertEqual(centerFromTop, ChromeMetrics.TitleBar.height / 2, accuracy: 0.5, "\(button.frame)", file: file, line: line)
        }
    }

    /// Every visible view of ours under a top-left window point, the content
    /// view included: the views whose `mouseDownCanMoveWindow` decides whether
    /// a press there moves the window.
    private func contentViews(at point: CGPoint, in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        let windowPoint = NSPoint(x: point.x, y: window.frame.height - point.y)
        var found: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view.convert(view.bounds, to: nil).contains(windowPoint) {
                found.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}

@MainActor
private struct Harness {
    let themeStore: ThemeStore
    let textSize: TerminalTextSizeStore
    let toasts: ToastCenter
    let rearrange: RearrangeMode
    let drag: DragCoordinator
    let dividerDrag: DividerDragCoordinator
    let viewModel: SessionViewModel

    init(
        theme: Theme, model: SessionModel? = nil, client: any HerdrCommandClient = OfflineHerdrClient(),
        attaching panes: [PaneID] = Fixture.canvasPanes
    ) async throws {
        ChromeType.install()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }))
        viewModel = SessionViewModel(client: client, ghosttyFactory: GroundSurfaceFactory())
        viewModel.update(model: try model ?? Fixture.model(), connection: .live)
        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
    }

    func makeWindow(size: CGSize) -> NSWindow {
        let root = MainWindow(viewModel: viewModel, sessionLabel: "render")
            .environment(themeStore)
            .environment(textSize)
            .environment(toasts)
            .environment(rearrange)
            .environment(drag)
            .environment(dividerDrag)
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
}

private struct OfflineHerdrClient: HerdrCommandClient {
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
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}

/// Answers the hover card's last-line read and nothing else.
private struct GridFixtureClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { throw OfflineHerdrClient.Offline() }
        return Data(#"{"result":{"text":"Editing lib/daemon.ts\n"}}"#.utf8)
    }
}

/// Six workspaces, one with nine tabs and one with six, over split layouts
/// and every agent status.
private enum GridFixture {
    static let repoTools = WorkspaceID(rawValue: "w1")
    static let agentsTab = TabID(rawValue: "w1:t1")
    static let claudePane = PaneID(rawValue: "w1:p1")

    private typealias Rect = (x: Int, y: Int, width: Int, height: Int)
    private static let whole: [Rect] = [(0, 0, 80, 24)]
    private static let sideBySide: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 24)]
    private static let stacked: [Rect] = [(0, 0, 80, 12), (0, 12, 80, 12)]
    private static let leftAndStack: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 12), (40, 12, 40, 12)]

    private static let workspaces: [(label: String, status: String, tabs: [(label: String, status: String, shape: [Rect], panes: [(String, String)])])] = [
        ("repo-tools", "working", [
            ("agents", "working", leftAndStack, [("claude", "working"), ("bun test", "done"), ("nvim", "idle")]),
            ("server", "blocked", whole, [("codex", "blocked")]),
            ("scratch", "idle", stacked, [("bun dev", "working"), ("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("bun test", "done"), ("nvim", "idle")]),
            ("docs", "blocked", whole, [("claude", "working")]),
            ("release", "idle", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bench", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
            ("ci", "idle", leftAndStack, [("zsh", "idle"), ("tail -f", "idle"), ("claude", "working")]),
            ("notes", "done", whole, [("zsh", "idle")]),
        ]),
        ("paddock", "blocked", [
            ("migration", "working", whole, [("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("tail -f", "idle"), ("claude", "working")]),
            ("design", "done", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bridge", "idle", whole, [("zsh", "idle")]),
            ("logs", "blocked", whole, [("tail -f", "blocked")]),
            ("review", "idle", whole, [("codex", "idle")]),
        ]),
        ("mattstack-apps", "done", [
            ("tray", "working", whole, [("codex", "blocked")]),
            ("console", "idle", sideBySide, [("bun dev", "working"), ("zsh", "idle")]),
            ("deck", "done", stacked, [("tail -f", "idle"), ("claude", "working")]),
            ("board", "idle", leftAndStack, [("bun test", "done"), ("nvim", "idle"), ("codex", "blocked")]),
        ]),
        ("herdr", "idle", [
            ("src", "working", whole, [("bun dev", "working")]),
            ("build", "idle", sideBySide, [("zsh", "idle"), ("tail -f", "idle")]),
            ("issues", "done", stacked, [("claude", "working"), ("bun test", "done")]),
        ]),
        ("console", "working", [
            ("dev", "idle", whole, [("nvim", "idle")]),
            ("storybook", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
        ]),
        ("glance", "idle", [
            ("shell", "idle", whole, [("zsh", "idle")]),
        ]),
    ]

    static func model() throws -> SessionModel {
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        var layouts: [[String: Any]] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspaceID = "w\(workspaceIndex + 1)"
            workspaceRows.append([
                "workspace_id": workspaceID, "label": workspace.label, "number": workspaceIndex + 1,
                "active_tab_id": "\(workspaceID):t1", "agent_status": workspace.status,
            ])
            var paneNumber = 0
            for (tabIndex, tab) in workspace.tabs.enumerated() {
                let tabID = "\(workspaceID):t\(tabIndex + 1)"
                tabRows.append([
                    "tab_id": tabID, "workspace_id": workspaceID, "label": tab.label, "number": tabIndex + 1,
                    "pane_count": tab.panes.count, "agent_status": tab.status,
                ])
                var rects: [[String: Any]] = []
                for (rect, pane) in zip(tab.shape, tab.panes) {
                    paneNumber += 1
                    let paneID = "\(workspaceID):p\(paneNumber)"
                    paneRows.append([
                        "pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": paneID == "w1:p1",
                        "agent_status": pane.1, "revision": 1, "terminal_title_stripped": pane.0,
                        "cwd": NSHomeDirectory() + "/Documents/GitHub/\(workspace.label)",
                    ])
                    rects.append([
                        "pane_id": paneID, "focused": false,
                        "rect": ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height],
                    ])
                }
                layouts.append([
                    "workspace_id": workspaceID, "tab_id": tabID, "zoomed": false,
                    "area": ["x": 0, "y": 0, "width": 80, "height": 24], "panes": rects, "splits": [],
                ])
            }
        }
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t1",
            "focused_pane_id": "w1:p1", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": layouts,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}

private enum Fixture {
    static let canvasPanes = [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")]

    static func model() throws -> SessionModel {
        let workspaces: [(id: String, label: String, panes: Int, status: String)] = [
            ("w1", "paddock", 5, "idle"), ("w2", "repo-tools", 3, "blocked"), ("w3", "board", 2, "working"),
            ("w4", "mattstack-apps", 4, "done"), ("w5", "herdr", 1, "idle"),
        ]
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        for (index, workspace) in workspaces.enumerated() {
            let isPaddock = workspace.id == "w1"
            let tabLabels = isPaddock ? ["api", "web", "claude", "logs"] : ["main"]
            workspaceRows.append([
                "workspace_id": workspace.id, "label": workspace.label, "number": index + 1,
                "active_tab_id": isPaddock ? "w1:t3" : "\(workspace.id):t1", "agent_status": workspace.status,
            ])
            for (tabIndex, label) in tabLabels.enumerated() {
                tabRows.append([
                    "tab_id": "\(workspace.id):t\(tabIndex + 1)", "workspace_id": workspace.id, "label": label,
                    "number": tabIndex + 1, "pane_count": 1, "agent_status": "idle",
                ])
            }
            let paddockTabs = ["w1:t3", "w1:t3", "w1:t1", "w1:t2", "w1:t4"]
            for paneIndex in 0..<workspace.panes {
                paneRows.append([
                    "pane_id": "\(workspace.id):p\(paneIndex + 1)", "workspace_id": workspace.id,
                    "tab_id": isPaddock ? paddockTabs[paneIndex] : "\(workspace.id):t1",
                    "focused": isPaddock && paneIndex == 1, "agent_status": "idle", "revision": 1,
                    "terminal_title_stripped": "shell", "cwd": "/private/tmp",
                ])
            }
        }
        let area: [String: Int] = ["x": 0, "y": 0, "width": 120, "height": 40]
        let layout: [String: Any] = [
            "workspace_id": "w1", "tab_id": "w1:t3", "zoomed": false, "area": area, "focused_pane_id": "w1:p2",
            "panes": [
                ["pane_id": "w1:p1", "focused": false, "rect": ["x": 0, "y": 0, "width": 60, "height": 40]],
                ["pane_id": "w1:p2", "focused": true, "rect": ["x": 60, "y": 0, "width": 60, "height": 40]],
            ],
            "splits": [["id": "split_0_root", "direction": "right", "ratio": 0.5, "rect": area]],
        ]
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t3",
            "focused_pane_id": "w1:p2", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": [layout],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}
