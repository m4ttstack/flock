import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Overview's Needs you and Working lanes, each split into two subgroups that
/// share the lane's height, and their headings' marks, in a dark and a light
/// theme. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class MissionLanesRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 1200, height: 640)
    private static let themes = [("dark", "tokyo-night"), ("light", "catppuccin-latte")]

    private struct Scenario {
        let name: String
        let blocked: Int
        let done: Int
        let working: Int
        let background: Int
    }

    private typealias M = ChromeMetrics.MissionControl

    func testBothSubgroupsFitAtTheirOwnHeights() async throws {
        let scenario = Scenario(name: "fit", blocked: 1, done: 1, working: 2, background: 1)
        try await render(scenario) { theme, image, board in
            for lane in [board.needsYou, board.working] {
                let lastTop = try XCTUnwrap(lane.top.last?.cards.last.flatMap { MissionCardFrames.shared.frames[$0.paneID] })
                let firstBottom = try XCTUnwrap(lane.bottom.first?.cards.first.flatMap { MissionCardFrames.shared.frames[$0.paneID] })
                XCTAssertLessThan(firstBottom.minY - lastTop.maxY, 100, "\(theme.id): the bottom subgroup follows the top one")
                XCTAssertLessThan(firstBottom.maxY, Self.size.height - 100, "\(theme.id): with the spare room below")
            }
            try self.assertMarks(image, theme: theme, needsYou: [theme.palette.red.hex, theme.palette.teal.hex],
                                 working: [theme.palette.yellow.hex, theme.palette.mauve.hex])
        }
    }

    func testASmallSubgroupKeepsItsHeightAndTheLargeOneTakesTheRest() async throws {
        let scenario = Scenario(name: "one-large", blocked: 1, done: 8, working: 8, background: 1)
        try await render(scenario) { theme, _, board in
            let firstDone = try XCTUnwrap(board.needsYou.bottom.first?.cards.first?.paneID)
            let frame = try XCTUnwrap(MissionCardFrames.shared.frames[firstDone])
            XCTAssertLessThan(frame.minY, Self.size.height * 0.45, "\(theme.id): Done starts right under the one blocked card")
            let firstBackground = try XCTUnwrap(board.working.bottom.first?.cards.first?.paneID)
            let background = try XCTUnwrap(MissionCardFrames.shared.frames[firstBackground])
            XCTAssertGreaterThan(background.minY, Self.size.height * 0.6, "\(theme.id): Background sits under most of Working")
            XCTAssertLessThan(background.maxY, Self.size.height, "\(theme.id): and is on screen")
        }
    }

    func testTwoLargeSubgroupsShareTheLaneEvenly() async throws {
        let scenario = Scenario(name: "both-large", blocked: 6, done: 6, working: 7, background: 7)
        try await render(scenario) { theme, _, board in
            for first in [board.needsYou.bottom.first, board.working.bottom.first] {
                let pane = try XCTUnwrap(first?.cards.first?.paneID)
                let frame = try XCTUnwrap(MissionCardFrames.shared.frames[pane])
                XCTAssertEqual(frame.minY / Self.size.height, 0.6, accuracy: 0.08, "\(theme.id): the bottom subgroup starts mid-lane")
            }
        }
    }

    func testAnEmptySubgroupDrawsNothingAndTheMarkIsTheOtherOnesStatus() async throws {
        let scenario = Scenario(name: "bottom-only", blocked: 0, done: 3, working: 0, background: 3)
        try await render(scenario) { theme, image, _ in
            try self.assertMarks(image, theme: theme, needsYou: [theme.palette.teal.hex], working: [theme.palette.mauve.hex])
        }
        let top = Scenario(name: "top-only", blocked: 3, done: 0, working: 3, background: 0)
        try await render(top) { theme, image, _ in
            try self.assertMarks(image, theme: theme, needsYou: [theme.palette.red.hex], working: [theme.palette.yellow.hex])
        }
    }

    func testEmptyLanesKeepTheirRestingMark() async throws {
        let scenario = Scenario(name: "empty", blocked: 0, done: 0, working: 0, background: 0)
        try await render(scenario) { theme, image, _ in
            try self.assertMarks(image, theme: theme, needsYou: [theme.palette.red.hex], working: [theme.palette.yellow.hex])
        }
    }

    /// The heading after the mark stays put as a lane goes from one dot to
    /// two and back.
    func testALaneMarkIsTwoDotsWideWhateverItShows() {
        let theme = Theme.tokyoNight
        func width(front: ShownStatus?, back: ShownStatus?) -> CGFloat {
            let mark = LaneMark(
                theme: theme, front: front, back: back, resting: ShownStatus(.blocked), ground: theme.pane, size: M.laneDot
            )
            return NSHostingView(rootView: mark).fittingSize.width
        }
        let two = width(front: ShownStatus(.blocked), back: ShownStatus(.done))
        // Fitting sizes round to the pixel grid.
        XCTAssertEqual(two, M.laneDot * (1 + M.laneMarkOffset), accuracy: 0.5)
        XCTAssertEqual(width(front: ShownStatus(.blocked), back: nil), two, accuracy: 0.01)
        XCTAssertEqual(width(front: nil, back: ShownStatus(.done)), two, accuracy: 0.01)
        XCTAssertEqual(width(front: nil, back: nil), two, accuracy: 0.01)
    }

    // MARK: - rendering

    private func render(
        _ scenario: Scenario, check: (Theme, NSBitmapImageRep, MissionBoard) throws -> Void
    ) async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in Self.themes {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            MissionCardFrames.shared.frames = [:]
            let suite = "MissionLanesRenderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let start = Date(timeIntervalSince1970: 1_000_000)
            let clock = Clock(start)
            let viewModel = SessionViewModel(
                client: FooterClient(background: Set(panes(scenario, only: .background).map(\.rawValue))),
                now: { clock.date },
                repoBranches: RepoBranchCache { RepoBranch(repo: URL(fileURLWithPath: $0).lastPathComponent, branch: "main") }
            )
            viewModel.update(model: try model(scenario, settled: false), connection: .live)
            clock.date = start.addingTimeInterval(60)
            viewModel.update(model: try model(scenario, settled: true), connection: .live)
            clock.date = start.addingTimeInterval(5 * 60)

            let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
            let identity = WorkspaceIdentityStore(userDefaults: defaults)
            identity.assign(["w1", "w2", "w3"])
            let mode = AllWorkspacesModeStore(userDefaults: defaults)
            mode.select(.missionControl)
            let drag = DragCoordinator(
                toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
                commit: { _, _ in fatalError("a render never drops") }, reveal: { _ in }
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(
                rootView: MissionControlView(theme: theme, viewModel: viewModel)
                    .environment(drag)
                    .environment(mode)
                    .environment(MissionBottomLineStore(userDefaults: defaults))
                    .environment(board)
                    .environment(identity)
                    .environment(HerdProgressStore(sources: .unanswered))
                    .frame(width: Self.size.width, height: Self.size.height)
            )
            defer { window.close() }
            // Displayed as well as laid out: a split is measured in one pass
            // and drawn in the next, and an offscreen window only runs the
            // next when it is asked to draw.
            for _ in 0..<12 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("mission-lanes-\(scenario.name)-\(scheme).png"))
            }
            let (missionBoard, _) = try XCTUnwrap(MissionBoard.make(
                viewModel: viewModel, board: board, herdProgress: HerdProgressStore(sources: .unanswered), opensOlder: false,
                now: viewModel.currentTime
            ))
            XCTAssertEqual(
                [missionBoard.needsYou.topCount, missionBoard.needsYou.bottomCount, missionBoard.working.topCount, missionBoard.working.bottomCount],
                [scenario.blocked, scenario.done, scenario.working, scenario.background],
                "\(id): the premise"
            )
            try check(theme, image, missionBoard)
        }
    }

    /// Exactly `expected` of the four lane hues fill part of the lane's
    /// heading mark.
    private func assertMarks(_ image: NSBitmapImageRep, theme: Theme, needsYou: [String], working: [String]) throws {
        let hues = [theme.palette.red.hex, theme.palette.teal.hex, theme.palette.yellow.hex, theme.palette.mauve.hex]
        let laneWidth = (Self.size.width - 2 * M.canvasPadding - 2 * M.laneGap) / 3
        for (lane, expected) in [(0, needsYou), (1, working)] {
            let x = M.canvasPadding + CGFloat(lane) * (laneWidth + M.laneGap)
            let heading = CGRect(x: x + 4, y: M.canvasVerticalPadding + 2, width: 40, height: 30)
            let found = hues.filter { count($0, in: heading, of: image) > 0 }
            XCTAssertEqual(Set(found), Set(expected), "\(theme.id): lane \(lane)'s mark")
        }
    }

    private enum Kind { case blocked, done, working, background, rest }

    private static let titles = [
        "Pick a schema for refunds", "Approve the acme migration", "Finished the acme export", "Docs pass complete",
        "Refactor the request pipeline", "Port the billing worker", "Wire the audit log", "Trim the bundle",
        "Watch the acme CI run", "Wait on the acme review", "Sweep flaky tests", "Rename the ledger types",
    ]

    private func kinds(_ scenario: Scenario) -> [Kind] {
        Array(repeating: .blocked, count: scenario.blocked) + Array(repeating: .done, count: scenario.done)
            + Array(repeating: .working, count: scenario.working) + Array(repeating: .background, count: scenario.background)
            + [.rest, .rest]
    }

    private func paneID(_ index: Int) -> PaneID { PaneID(rawValue: "w\(index % 3 + 1):p\(index + 1)") }

    private func panes(_ scenario: Scenario, only kind: Kind? = nil) -> [PaneID] {
        kinds(scenario).enumerated().compactMap { index, each in
            (kind == nil ? each != .rest : each == kind) ? paneID(index) : nil
        }
    }

    /// Three acme workspaces, one tab per pane, panes dealt across them in
    /// turn. Before it settles, every pane that will need you is working.
    private func model(_ scenario: Scenario, settled: Bool) throws -> SessionModel {
        let labels = ["acme-api", "acme-web", "acme-ops"]
        var tabs: [[String: Any]] = [], panes: [[String: Any]] = [], layouts: [[String: Any]] = []
        for (index, kind) in kinds(scenario).enumerated() {
            let workspace = "w\(index % 3 + 1)", tab = "\(workspace):t\(index + 1)", pane = paneID(index).rawValue
            let status: String = switch kind {
            case .blocked: settled ? "blocked" : "working"
            case .done: settled ? "done" : "working"
            case .working: "working"
            case .background, .rest: "idle"
            }
            tabs.append([
                "tab_id": tab, "workspace_id": workspace, "label": "t\(index + 1)", "number": index + 1, "pane_count": 1,
                "agent_status": status,
            ])
            panes.append([
                "pane_id": pane, "workspace_id": workspace, "tab_id": tab, "focused": false, "agent_status": status,
                "revision": 1, "terminal_title_stripped": Self.titles[index % Self.titles.count], "agent": "claude",
                "cwd": "/tmp/\(labels[index % 3])",
            ])
            layouts.append([
                "workspace_id": workspace, "tab_id": tab, "zoomed": false,
                "area": ["x": 0, "y": 0, "width": 80, "height": 24], "splits": [],
                "panes": [["pane_id": pane, "focused": false, "rect": ["x": 0, "y": 0, "width": 80, "height": 24]]],
            ])
        }
        let workspaces = labels.enumerated().map { index, label -> [String: Any] in
            let id = "w\(index + 1)"
            let first = tabs.first { $0["workspace_id"] as? String == id }?["tab_id"] ?? "\(id):t0"
            return ["workspace_id": id, "label": label, "number": index + 1, "active_tab_id": first, "agent_status": "idle"]
        }
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "workspaces": workspaces, "tabs": tabs,
            "panes": panes, "layouts": layouts,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }

    private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
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

    private func count(_ hex: String, in rect: CGRect, of image: NSBitmapImageRep) -> Int {
        guard let data = image.bitmapData else { return 0 }
        var found = 0
        for y in Int(rect.minY * Self.scale)..<min(image.pixelsHigh, Int(rect.maxY * Self.scale)) {
            for x in Int(rect.minX * Self.scale)..<min(image.pixelsWide, Int(rect.maxX * Self.scale)) {
                let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
                if String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2]) == hex { found += 1 }
            }
        }
        return found
    }
}

@MainActor
private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// Answers a pane read with Claude Code's footer, counting a background
/// shell for the panes in `background` and nothing for the rest.
private struct FooterClient: HerdrCommandClient {
    let background: Set<String>

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read", case .string(let pane) = params["pane_id"] else { throw CocoaError(.featureUnsupported) }
        let footer = background.contains(pane) ? "  ⏵⏵ auto mode on · 1 shell · ← for agents" : "  ⏵⏵ auto mode on"
        let screen = "> \n" + String(repeating: "─", count: 40) + "\n" + footer + "\n"
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": screen]]])
    }
}
