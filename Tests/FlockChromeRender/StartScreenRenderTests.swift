import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The Workspaces view on a server with no workspaces: the empty rail's New
/// Workspace row, and in place of a strip and panes the start screen over
/// the launcher, in a dark and a light theme, on the default server and on a
/// named one. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class StartScreenRenderTests: XCTestCase {
    private static let size = CGSize(width: 1100, height: 640)
    private static let railWidth: CGFloat = 260
    private static let scale: CGFloat = 2

    private struct Probe: View {
        let theme: Theme
        let viewModel: SessionViewModel
        let folders: StartingFolderStore
        let serverName: String?
        let drag: DragCoordinator
        let railWidth: RailWidthStore
        let identity: WorkspaceIdentityStore
        let themeStore: ThemeStore
        let defaults: UserDefaults

        var body: some View {
            HStack(spacing: 0) {
                WorkspaceRail(theme: theme, viewModel: viewModel, onSelect: { _ in })
                    .frame(width: StartScreenRenderTests.railWidth)
                StartScreenView(theme: theme, viewModel: viewModel, folders: folders, serverName: serverName, home: "/Users/acme")
            }
            .environment(themeStore)
            .environment(drag)
            .environment(railWidth)
            .environment(folders)
            .environment(SectionCollapseStore(userDefaults: defaults))
            .environment(BoardStore(sources: .unconfigured, userDefaults: defaults))
            .environment(HerdProgressStore(sources: .unanswered))
            .environment(ToastCenter())
            .environment(AllWorkspacesModeStore(userDefaults: defaults))
            .environment(MissionBottomLineStore(userDefaults: defaults))
            .environment(identity)
            .frame(width: StartScreenRenderTests.size.width, height: StartScreenRenderTests.size.height, alignment: .topLeading)
            .background(theme.chrome)
        }
    }

    func testTheStartScreenSitsRaisedOnThePaneWithTheRailOfferingNewWorkspace() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            for serverName in [nil, "acme"] as [String?] {
                let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
                let window = try await host(theme, serverName: serverName)
                defer { window.close() }
                let image = try snapshot(window)
                let name = "start-screen-\(serverName ?? "default")-\(scheme)"
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
                }
                let roles = theme.palette.chromeRoles
                let pane = CGRect(x: Self.railWidth, y: 0, width: Self.size.width - Self.railWidth, height: Self.size.height)
                XCTAssertEqual(hex(image, CGPoint(x: pane.maxX - 10, y: pane.maxY - 10)), roles.pane.hex, "\(name): on the pane ground")
                let inked = inkedRows(image, in: pane, ground: roles.pane.hex)
                let top = try XCTUnwrap(inked.first, name), bottom = try XCTUnwrap(inked.last, name)
                XCTAssertLessThan((top + bottom) / 2, pane.midY - ChromeMetrics.EmptyPin.lift / 2, "\(name): raised off centre")

                let railTop = CGRect(x: 0, y: 0, width: Self.railWidth - 4, height: 60)
                let railGround = hex(image, CGPoint(x: Self.railWidth / 2, y: Self.size.height / 2))
                XCTAssertFalse(inkedRows(image, in: railTop, ground: railGround).isEmpty, "\(name): the empty rail draws its New Workspace row")
            }
        }
    }

    func testTheFolderIsShortenedAgainstTheHomeItWasGiven() {
        XCTAssertEqual(StartScreenView.shortened("/Users/acme", home: "/Users/acme"), "~")
        XCTAssertEqual(StartScreenView.shortened("/Users/acme/code/acme-api", home: "/Users/acme"), "~/code/acme-api")
        XCTAssertEqual(StartScreenView.shortened("/Users/acmeother", home: "/Users/acme"), "/Users/acmeother")
        XCTAssertEqual(StartScreenView.shortened("/tmp", home: "/Users/acme"), "/tmp")
    }

    private func host(_ theme: Theme, serverName: String?) async throws -> NSWindow {
        let suite = "StartScreenRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        viewModel.update(model: SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [], tabs: [], panes: [], layouts: []
        )), connection: .live)
        XCTAssertTrue(viewModel.showsStartScreen)

        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { subject, target in await viewModel.perform(subject: subject, target: target) }, reveal: { _ in }
        )
        let railWidth = RailWidthStore(userDefaults: defaults)
        railWidth.released(at: Self.railWidth - ChromeMetrics.ruleWidth)
        let folders = StartingFolderStore(userDefaults: defaults)
        folders.select(.home, for: .workspace)
        let probe = Probe(
            theme: theme, viewModel: viewModel, folders: folders, serverName: serverName, drag: drag, railWidth: railWidth,
            identity: identity, themeStore: themeStore, defaults: defaults
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: probe)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return window
    }

    /// The window-space rows inside `rect` holding anything but the ground.
    private func inkedRows(_ image: NSBitmapImageRep, in rect: CGRect, ground: String) -> [CGFloat] {
        stride(from: rect.minY + 2, to: rect.maxY - 2, by: 1).filter { y in
            stride(from: rect.minX + 2, to: rect.maxX - 2, by: 2).contains { hex(image, CGPoint(x: $0, y: y)) != ground }
        }
    }

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
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
}

private struct OfflineClient: HerdrCommandClient {
    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data { Data("{}".utf8) }
}
