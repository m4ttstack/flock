import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Arrange with four workspaces, one of them a five-tab herd, over panes in
/// every status, each answering its screen read with a few lines of an
/// agent's transcript. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is
/// set.
@MainActor
final class ArrangeRenderTests: XCTestCase {
    private static let windowSize = CGSize(width: 1200, height: 760)
    private static let scale: CGFloat = 2

    private var directory: String? {
        ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testArrangeRendersFourWorkspacesInDarkAndLight() async throws {
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model())
            let window = arrange.makeWindow(size: Self.windowSize)
            await settle(window)
            arrange.drag.toggleGrid()
            await settle(window)
            await settle(window)
            let image = try snapshot(window)
            try write(image, "arrange-\(scheme).png")
            let working = try XCTUnwrap(arrange.drag.gridPaneFrame(of: ArrangeFixture.apiClaude))
            XCTAssertEqual(
                hex(image, CGPoint(x: working.minX + 1, y: working.midY)), theme.palette.yellow.hex,
                "\(scheme): a working pane carries no yellow edge"
            )
            let idle = try XCTUnwrap(arrange.drag.gridPaneFrame(of: PaneID(rawValue: "w1:p2")))
            XCTAssertNotEqual(
                hex(image, CGPoint(x: idle.minX + 1, y: idle.midY)), theme.palette.green.hex,
                "\(scheme): an idle pane took a status edge"
            )
            window.close()
        }
    }

    /// The pixel at a point in window space, top-left origin.
    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    /// A full-screen window: the islands grow past the old fixed size
    /// instead of hugging the top.
    func testArrangeGrowsToFillALargeWindow() async throws {
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model())
            let window = arrange.makeWindow(size: CGSize(width: 1720, height: 1060))
            await settle(window)
            arrange.drag.toggleGrid()
            await settle(window)
            await settle(window)
            try write(snapshot(window), "arrange-large-\(scheme).png")
            let thumbnail = try XCTUnwrap(arrange.drag.surfaces?.grid?.thumbnails.first { $0.id == ArrangeFixture.apiServerTab }?.frame)
            XCTAssertGreaterThan(thumbnail.width, 260, "\(scheme): the thumbnails did not grow")
            window.close()
        }
    }

    func testArrangeWithManyWorkspacesRendersInDarkAndLight() async throws {
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let arrange = try await ArrangeHarness(theme: theme, model: ArrangeFixture.model(extra: 8))
            let window = arrange.makeWindow(size: Self.windowSize)
            await settle(window)
            arrange.drag.toggleGrid()
            await settle(window)
            try write(snapshot(window), "arrange-many-\(scheme).png")
            window.close()
        }
    }

    private func write(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let directory else { return }
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
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

/// The main window over a fixture model, with every store it reads and no
/// tool, socket or real terminal behind any of them.
@MainActor
struct ArrangeHarness {
    let viewModel: SessionViewModel
    let drag: DragCoordinator
    let modeStore: AllWorkspacesModeStore
    private let defaults: UserDefaults
    private let theme: Theme
    private let toasts = ToastCenter()
    private let rearrange = RearrangeMode()

    init(theme: Theme, model: SessionModel, client: any HerdrCommandClient = ArrangeFixtureClient()) async throws {
        ChromeType.install()
        self.theme = theme
        let suite = "flock-arrange-render-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in },
            gridHoldsEscape: { false }
        )
        modeStore = AllWorkspacesModeStore(userDefaults: defaults)
        modeStore.select(.arrange)
        let repoBranches = RepoBranchCache { folder in
            RepoBranch(repo: URL(fileURLWithPath: folder).lastPathComponent, branch: "main")
        }
        viewModel = SessionViewModel(
            client: client, ghosttyFactory: ArrangeGroundFactory(), now: { ArrangeFixture.now },
            backgroundWorkInterval: .seconds(600), repoBranches: repoBranches
        )
        viewModel.update(model: model, connection: .live)
    }

    func makeWindow(size: CGSize) -> NSWindow {
        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
        let root = MainWindow(
            viewModel: viewModel, sessionLabel: "render",
            herdrMousePatchStore: HerdrMousePatchStore(resolveBinaryPath: { nil }, resolveArtifactPath: { _ in nil }),
            isDevBuild: false
        )
        .environment(nil as DevBuildWatcher?)
        .environment(themeStore)
        .environment(TerminalTextSizeStore(userDefaults: defaults))
        .environment(RtModalSizeStore(userDefaults: defaults))
        .environment(RtModalTextSizeStore(userDefaults: defaults))
        .environment(RailWidthStore(userDefaults: defaults))
        .environment(SectionCollapseStore(userDefaults: defaults))
        .environment(board)
        .environment(HerdProgressStore(sources: .unanswered))
        .environment(toasts)
        .environment(rearrange)
        .environment(drag)
        .environment(modeStore)
        .environment(MissionBottomLineStore(userDefaults: defaults))
        .environment(WorkspaceIdentityStore(userDefaults: defaults))
        .environment(DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in })))
        .environment(ChatStore(
            toasts: ToastCenter(), probe: { nil }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in ArrangeNoChat() }
        ))
        .environment(OptionAsAltStore(userDefaults: defaults))
        .environment(CommandPaletteState())
        .environment(PaletteRecentsStore(userDefaults: defaults))
        .environment(WorkspaceSwitcher(userDefaults: defaults))
        .environment(TabSwitcher(userDefaults: defaults))
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

private actor ArrangeNoChat: ChatRunning {
    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        throw ChatFailure(message: "no chat in an Arrange render")
    }
}

@MainActor
private final class ArrangeGroundSurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    func resumeScreenActivityReporting() {}
    var hasFirstFrame: Bool { true }
    var hasClaimedMouse: Bool { false }
    var programHasMouse: Bool { false }
}

@MainActor
private struct ArrangeGroundFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        ArrangeGroundSurface()
    }
}

/// Answers every `pane.read` with that pane's fixture screen: ANSI when the
/// read asks for it, plain otherwise. Counts reads per pane.
actor ArrangeFixtureClient: HerdrCommandClient {
    private(set) var reads: [PaneID: Int] = [:]

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read", case .string(let raw)? = params["pane_id"] else {
            throw ArrangeFixture.Offline()
        }
        let pane = PaneID(rawValue: raw)
        reads[pane, default: 0] += 1
        var screen = ArrangeFixture.screen(for: pane)
        if case .string("ansi")? = params["format"] {} else {
            screen = screen.replacing(/\u{1B}\[[0-9;:]*m/, with: "")
        }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": screen]]])
    }
}

/// Four workspaces: two with two tabs, one with one, and a five-tab herd.
/// `extra` adds that many plain three-tab workspaces after them.
enum ArrangeFixture {
    struct Offline: Error {}

    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let herd = WorkspaceID(rawValue: "w4")
    static let api = WorkspaceID(rawValue: "w1")
    static let apiServerTab = TabID(rawValue: "w1:t1")
    static let apiClaude = PaneID(rawValue: "w1:p1")
    static let backgroundPane = PaneID(rawValue: "w2:p3")

    private typealias Rect = (x: Int, y: Int, width: Int, height: Int)
    private static let whole: [Rect] = [(0, 0, 80, 24)]
    private static let sideBySide: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 24)]
    private static let stacked: [Rect] = [(0, 0, 80, 12), (0, 12, 80, 12)]

    private typealias Pane = (title: String, status: String, agent: String?)
    private typealias Tab = (label: String, status: String, shape: [Rect], panes: [Pane])

    private static let workspaces: [(label: String, status: String, tabs: [Tab])] = [
        ("acme-api", "blocked", [
            ("api server", "working", sideBySide, [("claude", "working", "claude"), ("zsh", "idle", nil)]),
            ("migrations", "blocked", whole, [("claude", "blocked", "claude")]),
        ]),
        ("acme-web", "done", [
            ("web ui", "done", whole, [("claude", "done", "claude")]),
            ("storybook", "working", stacked, [("bun dev", "working", nil), ("claude", "idle", "claude")]),
        ]),
        ("acme-docs", "idle", [
            ("docs", "idle", whole, [("nvim", "idle", nil)]),
        ]),
        ("herd: acme-rename", "working", [
            ("tube-attach", "working", whole, [("claude", "working", "claude")]),
            ("invite-state", "done", whole, [("claude", "done", "claude")]),
            ("converge", "blocked", whole, [("claude", "blocked", "claude")]),
            ("team-rename", "working", whole, [("claude", "working", "claude")]),
            ("integration-1", "idle", whole, [("claude", "idle", "claude")]),
        ]),
    ]

    static func model(extra: Int = 0) throws -> SessionModel {
        var all = workspaces
        for index in 0..<extra {
            all.append(("acme-\(index + 1)", "idle", [
                ("shell", "idle", whole, [("zsh", "idle", nil)]),
                ("build", "working", sideBySide, [("bun dev", "working", nil), ("zsh", "idle", nil)]),
                ("agent", "done", whole, [("claude", "done", "claude")]),
            ]))
        }
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        var layouts: [[String: Any]] = []
        for (workspaceIndex, workspace) in all.enumerated() {
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
                    var row: [String: Any] = [
                        "pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": paneID == "w1:p1",
                        "agent_status": pane.status, "revision": 1, "terminal_title_stripped": pane.title,
                        "cwd": "/tmp/acme/\(workspace.label.replacingOccurrences(of: "herd: ", with: ""))",
                    ]
                    if let agent = pane.agent { row["agent"] = agent }
                    paneRows.append(row)
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

    private static let esc = "\u{1B}["

    /// An agent's transcript, a shell or an editor, picked by the pane's
    /// number so neighbouring tiles differ.
    static func screen(for pane: PaneID) -> String {
        let e = esc
        let rule = "\(e)38;5;240m" + String(repeating: "─", count: 60) + "\(e)0m"
        let footer = pane == backgroundPane
            ? "  \(e)2m⏵⏵ auto mode on · 1 shell · ← for agents\(e)0m"
            : "  \(e)2m⏵⏵ auto mode on\(e)0m"
        let prompt = [rule, "\(e)1m❯\(e)0m ", rule, footer]
        let agent: [[String]] = [
            [
                "\(e)1m⏺\(e)0m Read(src/routes/invite.ts)",
                "  \(e)2m⎿ 214 lines\(e)0m",
                "",
                "\(e)1m⏺\(e)0m The invite route checks the team before the token, so an",
                "  expired token on a renamed team reads as a 404.",
                "",
                "\(e)1m⏺\(e)0m Update(src/routes/invite.ts)",
                "  \(e)32m⎿ +18 −6\(e)0m",
                "\(e)1m⏺\(e)0m Bash(bun test src/routes)",
                "  \(e)32m⎿ 42 pass\(e)0m, 0 fail",
                "",
                "\(e)33m✻ Cogitating… (1m 12s · esc to interrupt)\(e)0m",
            ],
            [
                "\(e)1m⏺\(e)0m Bash(bun run migrate --dry-run)",
                "  \(e)2m⎿ 3 migrations pending\(e)0m",
                "",
                "\(e)1m⏺\(e)0m Migration 0042 drops a column the web app still",
                "  reads. Run it anyway?",
                "",
                "  \(e)36m❯ 1. Yes\(e)0m",
                "    2. No, keep the column",
                "    3. Show the diff first",
            ],
            [
                "\(e)1m⏺\(e)0m Update(web/src/Invite.tsx)",
                "  \(e)32m⎿ +64 −12\(e)0m",
                "\(e)1m⏺\(e)0m Bash(bun run build)",
                "  \(e)32m⎿ built in 2.41s\(e)0m",
                "",
                "\(e)32m⏺\(e)0m Done. The invite page shows the team's new name.",
            ],
        ]
        let number = Int(pane.rawValue.split(separator: "p").last ?? "1") ?? 1
        let workspace = Int(pane.rawValue.dropFirst().split(separator: ":").first ?? "1") ?? 1
        switch pane == backgroundPane ? 1 : (workspace + number) % 5 {
        case 0:
            return [
                "\(e)32m~/acme\(e)0m \(e)34mmain\(e)0m $ bun dev",
                "  \(e)36mVITE v5.4.2\(e)0m ready in 412 ms",
                "  ➜  Local:   \(e)36mhttp://localhost:5173/\(e)0m",
                "\(e)2m12:04:11\(e)0m [vite] hmr update /src/Invite.tsx",
                "\(e)2m12:04:19\(e)0m [vite] hmr update /src/Team.tsx",
            ].joined(separator: "\n") + "\n"
        default:
            let body = agent[(workspace + number) % agent.count]
            return (body + [""] + prompt).joined(separator: "\n") + "\n"
        }
    }
}
