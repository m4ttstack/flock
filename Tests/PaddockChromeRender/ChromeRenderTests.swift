import AppKit
import PaddockCore
import SwiftUI
import XCTest

/// Renders the real `MainWindow` offscreen from fixture data, with no app host
/// and no herdr connection. Pane bodies are ground-only surfaces, since
/// terminal content is not part of the chrome. The PNG pass writes only when
/// `PADDOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ChromeRenderTests: XCTestCase {
    static let defaultsSuite = "dev.mattstack.paddock.chrome-render"
    private static let windowSize = CGSize(width: 900, height: 560)
    private static let themeIDs = ["tokyo-night", "catppuccin-latte", "tokyo-night-day", "dracula", "gruvbox-light", "one-light"]

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.defaultsSuite)
        super.tearDown()
    }

    func testRenderChromeForEachTheme() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PADDOCK_CHROME_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("set PADDOCK_CHROME_RENDER_DIR to write the renders")
        }
        for id in Self.themeIDs {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(id).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            printSamples(image, theme: theme)
            window.close()
        }
    }

    func testWindowButtonsCenterOnTheTitleBarAndStayThereAfterAResize() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        assertButtonsCentered(in: window)
        printTitleBarHits(in: window)

        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(window)
        assertButtonsCentered(in: window)
        window.close()
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

    /// Points are top-left, in the 900x560 window.
    private func printSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let samples: [(String, CGPoint, RGB)] = [
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/strip", CGPoint(x: 600, y: 30), roles.chrome),
            ("chrome/rail", CGPoint(x: 75, y: 400), roles.chrome),
            ("rule/rail", CGPoint(x: 150.25, y: 400), roles.rule),
            ("selection/row", CGPoint(x: 100, y: 52), roles.selection),
            ("tabRest", CGPoint(x: 232, y: 30), roles.tabRest),
            ("selection/tab", CGPoint(x: 392, y: 30), roles.selection),
            ("accent/underline", CGPoint(x: 392, y: 47.25), roles.accent),
            ("rule/strip", CGPoint(x: 600, y: 48.25), roles.rule),
            ("canvas/margin", CGPoint(x: 153, y: 400), roles.canvas),
            ("paneBorder", CGPoint(x: 156.25, y: 400), roles.paneBorder),
            ("pane", CGPoint(x: 300, y: 400), roles.pane),
            ("accent/focused", CGPoint(x: 894.25, y: 400), roles.accent),
        ]
        for (name, point, expected) in samples {
            let actual = hex(image, point)
            print("SAMPLE \(theme.id) \(name) expected=\(expected.hex) actual=\(actual)\(actual == expected.hex ? "" : " MISMATCH")")
        }
    }

    private func assertButtonsCentered(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        for button in buttons {
            let inWindow = button.convert(button.bounds, to: nil)
            let centerFromTop = window.frame.height - inWindow.midY
            print("BUTTON frame=\(button.frame) centerFromTop=\(centerFromTop) windowHeight=\(window.frame.height)")
            XCTAssertEqual(centerFromTop, ChromeMetrics.titleBarHeight / 2, accuracy: 0.5, file: file, line: line)
        }
    }

    private func printTitleBarHits(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        let height = frameView.bounds.height
        let points: [(String, CGPoint)] = [
            ("title center", CGPoint(x: 450, y: 10)),
            ("title left of name", CGPoint(x: 250, y: 10)),
            ("strip above tabs", CGPoint(x: 600, y: 23)),
            ("tab top sliver", CGPoint(x: 200, y: 27)),
            ("tab body", CGPoint(x: 200, y: 40)),
            ("rail heading", CGPoint(x: 40, y: 34)),
        ]
        for (name, point) in points {
            let hit = frameView.hitTest(NSPoint(x: point.x, y: height - point.y))
            let chain = sequence(first: hit, next: { $0?.superview }).prefix(4).compactMap { $0.map { String(describing: type(of: $0)) } }
            print("HIT \(name) \(chain.joined(separator: " < ")) canMoveWindow=\(hit?.mouseDownCanMoveWindow ?? false)")
        }
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

    init(theme: Theme) async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            springLoadAction: { _ in }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }, settle: {}))
        viewModel = SessionViewModel(client: OfflineHerdrClient(), ghosttyFactory: GroundSurfaceFactory())
        viewModel.update(model: try Fixture.model(), connection: .live)
        for pane in Fixture.canvasPanes {
            _ = await viewModel.attachPane(pane, cols: 80, rows: 24)
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
    func resize(cols: Int, rows: Int) {}
    func repaint(cols: Int, rows: Int) {}
    func detach() async {}
    func park() {}
    func unpark() {}
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, cols: Int, rows: Int, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}

private enum Fixture {
    static let canvasPanes = [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")]

    static func model() throws -> SessionModel {
        let workspaces: [(id: String, label: String, panes: Int)] = [
            ("w1", "paddock", 5), ("w2", "repo-tools", 3), ("w3", "board", 2),
            ("w4", "mattstack-apps", 4), ("w5", "herdr", 1),
        ]
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        for (index, workspace) in workspaces.enumerated() {
            let isPaddock = workspace.id == "w1"
            let tabLabels = isPaddock ? ["api", "web", "claude", "logs"] : ["main"]
            workspaceRows.append([
                "workspace_id": workspace.id, "label": workspace.label, "number": index + 1,
                "active_tab_id": isPaddock ? "w1:t3" : "\(workspace.id):t1", "agent_status": "idle",
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
