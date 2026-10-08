import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The title bar carrying three top-bar workspaces: `dash` live and working,
/// `logs` empty, `board` live with its overlay open. Drawn icon only, with
/// names, and named in a window too narrow for names, in a dark and a light
/// theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class TopBarRenderTests: XCTestCase {
    private static let height: CGFloat = 38
    private static let scale: CGFloat = 2
    private static let main = WorkspaceID(rawValue: "w0")
    private static let dash = WorkspaceID(rawValue: "w1")
    private static let logs = WorkspaceID(rawValue: "w2")
    private static let board = WorkspaceID(rawValue: "w3")
    /// How far a filled mark's core may sit from its colour once rasterized.
    private static let inkTolerance: Double = 12

    private struct Hosted {
        let window: NSWindow
        let pins: [String: PinID]
    }

    private static let names = ["dash", "logs", "board"]

    /// The dot is centred on the mark's top-trailing corner.
    private static func dotCenter(in cell: CGRect) -> CGPoint {
        let mark = ChromeMetrics.TitleBar.topBarMark
        return CGPoint(x: cell.minX + ChromeMetrics.TitleBar.topBarCellPadding + mark, y: cell.midY - mark / 2)
    }

    func testCellsDrawIconOnlyWithNamesAndFallBackWhenNarrow() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let iconCellWidth = 2 * ChromeMetrics.TitleBar.topBarCellPadding + ChromeMetrics.TitleBar.topBarMark
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let roles = theme.palette.chromeRoles
            for (name, width, label) in [("icons", 1100.0, TopBarLabel.iconOnly), ("names", 1100.0, .iconAndName), ("narrow", 640.0, .iconAndName)] {
                let hosted = try await host(theme, width: width, label: label)
                defer { hosted.window.close() }
                let image = try snapshot(hosted.window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("top-bar-\(name)-\(scheme).png"))
                }
                let message = "\(name) \(scheme)"
                // The cells, read off the rules that part them, which run the
                // bar's full height as the view tabs' do.
                let cells = ruledCells(image, roles: roles, width: width)
                XCTAssertEqual(cells.count, 3, message)
                guard cells.count == 3 else { continue }
                let cell = { (pin: String) in cells[Self.names.firstIndex(of: pin)!] }
                // A cell is wider than its icon and padding exactly when it carries a name.
                XCTAssertEqual(cells.allSatisfy { $0.width > iconCellWidth + 1 }, name == "names", "\(message): \(cells)")
                XCTAssertEqual(try XCTUnwrap(cells.last).maxX, width, accuracy: 0.5, "\(message): flush with the bar's trailing edge")

                let dot = try XCTUnwrap(sample(image, Self.dotCenter(in: cell("dash"))))
                XCTAssertLessThanOrEqual(
                    distance(dot, theme.palette.yellow), Self.inkTolerance, "\(message): the working dot drew \(dot.hex)"
                )
                let emptyDot = try XCTUnwrap(sample(image, Self.dotCenter(in: cell("logs"))))
                XCTAssertGreaterThan(distance(emptyDot, theme.palette.yellow), 60, "\(message): the empty pin draws no dot")

                let board = cell("board")
                let fill = try XCTUnwrap(sample(image, CGPoint(x: board.maxX - 3, y: board.minY + 4)))
                XCTAssertLessThanOrEqual(distance(fill, roles.tabRest), 2, "\(message): the open cell has the selected tab's fill")
                let underline = try XCTUnwrap(sample(image, CGPoint(x: board.midX, y: board.maxY - 1)))
                XCTAssertLessThanOrEqual(distance(underline, roles.accent), 2, "\(message): the open cell is underlined in accent")
                let rest = try XCTUnwrap(sample(image, CGPoint(x: cell("dash").minX + 3, y: board.minY + 4)))
                XCTAssertLessThanOrEqual(distance(rest, roles.chrome), 2, "\(message): a closed cell draws no fill")
            }
        }
    }

    private func host(_ theme: Theme, width: CGFloat, label: TopBarLabel) async throws -> Hosted {
        let suite = "TopBarRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        let all = [Self.main, Self.dash, Self.logs, Self.board]
        viewModel.update(model: model(all), connection: .live)
        for workspace in [Self.dash, Self.logs, Self.board] {
            viewModel.moveToTopBar(workspace: workspace, at: nil)
        }
        viewModel.update(model: model(all.filter { $0 != Self.logs }), connection: .live)
        var pins: [String: PinID] = [:]
        for (name, symbol) in [("dash", "server.rack"), ("logs", "cylinder.fill"), ("board", "square.stack.3d.up.fill")] {
            let pin = try XCTUnwrap(viewModel.pins.pins.first { $0.name == name }, name)
            XCTAssertEqual(pin.placement, .topBar, name)
            identity.setOverride(symbol, for: pin.identityKey)
            pins[name] = pin.id
        }
        XCTAssertNil(viewModel.pins.pin(try XCTUnwrap(pins["logs"]))?.workspace, "logs' pin is empty")
        await viewModel.toggleTopBar(try XCTUnwrap(pins["board"]))
        XCTAssertEqual(viewModel.topBarOverlay.openPin, pins["board"])

        let labels = TopBarLabelStore(userDefaults: defaults)
        labels.select(label)
        let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
        await board.refresh()
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { subject, target in await viewModel.perform(subject: subject, target: target) },
            reveal: { _ in }
        )
        let root = VStack(spacing: 0) {
            TitleBar(theme: theme, sessionLabel: "render", connectionState: .live, isDevBuild: false, viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Self.height)
        .background(theme.chrome)
        .environment(drag)
        .environment(AllWorkspacesModeStore(userDefaults: defaults))
        .environment(identity)
        .environment(board)
        .environment(labels)
        .environment(TopBarOverlaySizeStore(userDefaults: defaults))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return Hosted(window: window, pins: pins)
    }

    private func model(_ ids: [WorkspaceID]) -> SessionModel {
        let labels = [Self.main: "main", Self.dash: "dash", Self.logs: "logs", Self.board: "board"]
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: Self.main, focusedTabID: nil, focusedPaneID: nil,
            workspaces: ids.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: labels[id] ?? id.rawValue, number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: id == Self.dash ? .working : .idle
                )
            },
            tabs: ids.map { id in
                TabRecord(
                    tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "first",
                    number: 1, paneCount: 1, agentStatus: id == Self.dash ? .working : .idle
                )
            },
            panes: [],
            layouts: []
        ))
    }

    /// The top-bar cells, leading to trailing: the spans between the last
    /// four columns from the bar's trailing edge drawn in the rule colour from
    /// the bar's top to below its marks. The strip's leading rule opens the
    /// first cell; each cell's trailing rule closes it.
    private func ruledCells(_ image: NSBitmapImageRep, roles: ChromeRoles, width: CGFloat) -> [CGRect] {
        let rows: [CGFloat] = [0.5, 5, 30]
        var rules: [ClosedRange<CGFloat>] = []
        var x = width - 0.5
        while x >= 0, rules.count < 4 {
            let ruled = rows.allSatisfy { y in sample(image, CGPoint(x: x, y: y)).map { distance($0, roles.rule) <= 3 } ?? false }
            if ruled {
                if let last = rules.last, last.lowerBound - x <= 0.5 {
                    rules[rules.count - 1] = x...last.upperBound
                } else {
                    rules.append(x...x)
                }
            }
            x -= 0.5
        }
        guard rules.count == 4 else { return [] }
        let edges = rules.reversed().enumerated().map { index, rule in index == 0 ? rule.lowerBound : rule.upperBound + 0.5 }
        return zip(edges, edges.dropFirst()).map { CGRect(x: $0, y: 0, width: $1 - $0, height: ChromeMetrics.TitleBar.height) }
    }

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = Double(a.red - b.red), dg = Double(a.green - b.green), db = Double(a.blue - b.blue)
        return (dr * dr + dg * dg + db * db).squareRoot()
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

    private func sample(_ image: NSBitmapImageRep, _ point: CGPoint) -> RGB? {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return RGB(Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }
}

private struct OfflineClient: HerdrCommandClient {
    struct Offline: Error {}
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { throw Offline() }
}
