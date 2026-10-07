import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The focused pane's header left of the Next chip: the back button at rest
/// and hovered, then the place and state, in a dark and a light theme. PNGs
/// are written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class FocusedHeaderRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 560, height: 2 * ChromeMetrics.Grid.focusedHeaderHeight)

    func testTheBackButtonIsQuietUntilHovered() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let name = "FocusedHeaderRenderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            let identity = WorkspaceIdentityStore(userDefaults: defaults)
            identity.assign(["w1"])
            let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(
                rootView: ZStack(alignment: .topLeading) { theme.pane; sheet(theme).environment(board).environment(identity) }
                    .frame(width: Self.size.width, height: Self.size.height)
            )
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("focused-header-\(scheme).png"))
            }
            let rowMid = ChromeMetrics.Grid.focusedHeaderHeight / 2
            let fringe = ChromeMetrics.Grid.headerHorizontalPadding - ChromeMetrics.MissionControl.focusedBackPullIn + 2
            let ground = hex(image, CGPoint(x: 2, y: rowMid))
            XCTAssertEqual(hex(image, CGPoint(x: fringe, y: rowMid)), ground, "\(scheme): a resting back button draws no ground")
            XCTAssertNotEqual(
                hex(image, CGPoint(x: fringe, y: rowMid + ChromeMetrics.Grid.focusedHeaderHeight)), ground,
                "\(scheme): hover lifts the back button"
            )
        }
    }

    private func row(_ theme: Theme, forced: ControlInteraction) -> some View {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let card = MissionCard(
            paneID: PaneID(rawValue: "w1:p1"), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            workspaceName: "acme", tabTitle: "api", title: "Refactor the request pipeline",
            status: .working, since: now.addingTimeInterval(-60), folder: "/tmp/acme"
        )
        return HStack(spacing: ChromeMetrics.Grid.focusedGroupSpacing) {
            FocusedBackButton(theme: theme, forced: forced) {}
            FocusedPlace(theme: theme, card: card, markKey: "w1")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChromeMetrics.Grid.headerHorizontalPadding)
        .frame(height: ChromeMetrics.Grid.focusedHeaderHeight)
    }

    private func sheet(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            row(theme, forced: .rest)
            row(theme, forced: .hover)
        }
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

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint) -> String {
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        guard let data = image.bitmapData, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }
}
