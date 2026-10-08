import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The Workspaces view after a pinned workspace's last tab closed: the rail
/// with the empty pin selected, and in place of a strip and panes the pin's
/// mark, name and folder over the launcher, in a dark and a light theme.
/// PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class EmptyPinRenderTests: XCTestCase {
    private static let size = CGSize(width: 1100, height: 640)
    private static let railWidth: CGFloat = 260
    private static let scale: CGFloat = 2
    private static let acme = WorkspaceID(rawValue: "w1")
    private static let web = WorkspaceID(rawValue: "w2")
    private static let docs = WorkspaceID(rawValue: "w3")

    private struct Probe: View {
        let theme: Theme
        let viewModel: SessionViewModel
        let pin: PinnedWorkspace
        let drag: DragCoordinator
        let railWidth: RailWidthStore
        let identity: WorkspaceIdentityStore
        let themeStore: ThemeStore
        let defaults: UserDefaults

        var body: some View {
            HStack(spacing: 0) {
                WorkspaceRail(theme: theme, viewModel: viewModel, onSelect: { _ in })
                    .frame(width: EmptyPinRenderTests.railWidth)
                EmptyPinView(theme: theme, viewModel: viewModel, pin: pin)
            }
            .environment(themeStore)
            .environment(drag)
            .environment(railWidth)
            .environment(SectionCollapseStore(userDefaults: defaults))
            .environment(BoardStore(sources: .unconfigured, userDefaults: defaults))
            .environment(HerdProgressStore(sources: .unanswered))
            .environment(ToastCenter())
            .environment(AllWorkspacesModeStore(userDefaults: defaults))
            .environment(MissionBottomLineStore(userDefaults: defaults))
            .environment(identity)
            .frame(width: EmptyPinRenderTests.size.width, height: EmptyPinRenderTests.size.height, alignment: .topLeading)
            .background(theme.chrome)
        }
    }

    func testTheShownEmptyPinDrawsItsIdentityOverTheLauncherRaisedOffCentre() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let (window, _) = try await host(theme)
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("empty-pin-\(scheme).png"))
            }
            let roles = theme.palette.chromeRoles
            let pane = CGRect(x: Self.railWidth, y: 0, width: Self.size.width - Self.railWidth, height: Self.size.height)
            XCTAssertEqual(hex(image, CGPoint(x: pane.maxX - 10, y: pane.maxY - 10)), roles.pane.hex, "\(scheme): the pin sits on the pane ground")
            let inked = inkedRows(image, in: pane, ground: roles.pane.hex)
            let top = try XCTUnwrap(inked.first), bottom = try XCTUnwrap(inked.last)
            XCTAssertLessThan((top + bottom) / 2, pane.midY - ChromeMetrics.EmptyPin.lift / 2, "\(scheme): the group is raised off centre")
        }
    }

    private func host(_ theme: Theme) async throws -> (NSWindow, PinnedWorkspace) {
        let suite = "EmptyPinRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let identity = WorkspaceIdentityStore(userDefaults: defaults)
        let viewModel = SessionViewModel(client: OfflineClient(), pinnedWorkspaceDefaults: nil, identity: identity)
        viewModel.update(model: model([Self.acme, Self.web, Self.docs], focused: Self.acme), connection: .live)
        viewModel.pin(workspace: Self.web)
        viewModel.pin(workspace: Self.acme)
        let acmePin = try XCTUnwrap(viewModel.pins.pin(linkedTo: Self.acme))
        viewModel.answerPinFolder(acmePin.id, with: "/Users/acme/code/acme-api")
        identity.setOverride("square.stack.3d.up", for: acmePin.identityKey)
        viewModel.update(model: model([Self.web, Self.docs], focused: Self.web), connection: .live)
        XCTAssertEqual(viewModel.shownEmptyPin, acmePin.id)
        let pin = try XCTUnwrap(viewModel.pins.pin(acmePin.id))

        let themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        let toasts = ToastCenter()
        let drag = DragCoordinator(toasts: toasts, rearrangeMode: RearrangeMode(), commit: { subject, target in await viewModel.perform(subject: subject, target: target) }, reveal: { _ in })
        let railWidth = RailWidthStore(userDefaults: defaults)
        railWidth.released(at: Self.railWidth - ChromeMetrics.ruleWidth)
        let probe = Probe(
            theme: theme, viewModel: viewModel, pin: pin, drag: drag, railWidth: railWidth, identity: identity,
            themeStore: themeStore, defaults: defaults
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: probe)
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return (window, pin)
    }

    private func model(_ ids: [WorkspaceID], focused: WorkspaceID) -> SessionModel {
        let labels = [Self.acme: "acme-api", Self.web: "web", Self.docs: "docs"]
        return SessionModel(snapshot: SessionSnapshot(
            version: "0.9.0", protocolVersion: 22,
            focusedWorkspaceID: focused, focusedTabID: TabID(rawValue: "\(focused.rawValue):t1"), focusedPaneID: nil,
            workspaces: ids.enumerated().map { index, id in
                WorkspaceRecord(
                    workspaceID: id, label: labels[id] ?? id.rawValue, number: index + 1,
                    activeTabID: TabID(rawValue: "\(id.rawValue):t1"), agentStatus: .idle
                )
            },
            tabs: ids.map { id in
                TabRecord(tabID: TabID(rawValue: "\(id.rawValue):t1"), workspaceID: id, label: "zsh", number: 1, paneCount: 1, agentStatus: .idle)
            },
            panes: [],
            layouts: []
        ))
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
