import AppKit
import FlockCore
import SwiftUI
import XCTest

/// A workspace header's mark at rest, hovered and pressed on the group wash,
/// then a header hosting the rename editor, then a herd's header whose ram is
/// no button even when forced hot, in a dark and a light theme. PNGs are
/// written only when `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class WorkspaceMarkRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let inset: CGFloat = 16
    private static let rowHeight: CGFloat = 40
    private static let rowGap: CGFloat = 12
    private static let rowWidth: CGFloat = 240
    private static let states: [ControlInteraction] = [.rest, .hover, .pressed]

    func testTheMarkLiftsOnHoverAndOnlyWhereItIsAButton() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let name = "WorkspaceMarkRenderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            defer { defaults.removePersistentDomain(forName: name) }
            let identity = WorkspaceIdentityStore(userDefaults: defaults)
            identity.assign(["w1"])
            let board = BoardStore(sources: .unconfigured, userDefaults: defaults)
            let sheet = self.sheet(theme).environment(board).environment(identity)
            let size = CGSize(
                width: Self.rowWidth + 2 * Self.inset,
                height: 2 * Self.inset + 5 * Self.rowHeight + 4 * Self.rowGap
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(
                rootView: ZStack(alignment: .topLeading) { theme.pane; sheet }.frame(width: size.width, height: size.height)
            )
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("workspace-mark-\(scheme).png"))
            }
            let wash = hex(image, CGPoint(x: Self.inset + 4, y: Self.inset + 4))
            let grounds = (0..<5).map { hex(image, fringe(row: $0)) }
            XCTAssertEqual(grounds[0], wash, "\(scheme): a resting mark draws no ground")
            XCTAssertNotEqual(grounds[1], grounds[0], "\(scheme): hover lifts the mark's ground")
            XCTAssertNotEqual(grounds[2], grounds[1], "\(scheme): a press reads stronger than a hover")
            XCTAssertEqual(grounds[4], wash, "\(scheme): a herd's ram is not a button, hot or not")
        }
    }

    /// A point just outside the 14pt mark's left edge, inside the button's ground.
    private func fringe(row: Int) -> CGPoint {
        CGPoint(
            x: Self.inset + ChromeMetrics.MissionControl.groupPadding - ChromeMetrics.MarkButton.padding / 2,
            y: Self.inset + CGFloat(row) * (Self.rowHeight + Self.rowGap) + Self.rowHeight / 2
        )
    }

    private func header(_ theme: Theme, key: String?, forced: ControlInteraction?, renaming: Bool = false) -> some View {
        HStack(spacing: ChromeMetrics.MissionControl.groupLabelSpacing) {
            WorkspaceMark(
                theme: theme, key: key, size: ChromeMetrics.MissionControl.groupMark, picking: .constant(false), forced: forced
            )
            if renaming {
                InlineRenameField(
                    theme: theme, font: ChromeType.missionGroupName, initialText: "acme api",
                    accessibilityIdentifier: "flock.mission.group.rename.w1", onCommit: { _ in }, onCancel: {}
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("acme api").font(ChromeType.missionGroupName).foregroundStyle(theme.textLabel)
            }
        }
        .padding(ChromeMetrics.MissionControl.groupPadding)
        .frame(width: Self.rowWidth, height: Self.rowHeight, alignment: .leading)
        .workspaceGround(theme, in: RoundedRectangle(cornerRadius: ChromeMetrics.MissionControl.groupCornerRadius))
    }

    private func sheet(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Self.rowGap) {
            ForEach(0..<Self.states.count, id: \.self) { self.header(theme, key: "w1", forced: Self.states[$0]) }
            header(theme, key: "w1", forced: nil, renaming: true)
            header(theme, key: nil, forced: .hover)
        }
        .padding(Self.inset)
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
