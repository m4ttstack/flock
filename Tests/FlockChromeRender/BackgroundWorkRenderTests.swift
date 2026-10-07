import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// A pane busy only in the background, beside plain working, idle and done
/// panes: Overview cards, the focused header's place and an Arrange
/// thumbnail, in a dark and a light theme. PNGs are written only when
/// `FLOCK_GRID_RENDER_DIR` is set.
@MainActor
final class BackgroundWorkRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let size = CGSize(width: 820, height: 470)
    /// A large background mark at a known place, for the pixel checks.
    private static let probe = CGRect(x: 16, y: 16, width: 24, height: 24)

    func testABackgroundBusyPaneReadsApartFromWorkingAndIdle() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (scheme, id) in [("dark", "tokyo-night"), ("light", "catppuccin-latte")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let name = "BackgroundWorkRenderTests.\(UUID().uuidString)"
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
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("background-work-\(scheme).png"))
            }
            let mauve = theme.palette.mauve.hex
            XCTAssertEqual(hex(image, CGPoint(x: Self.probe.minX + 1.5, y: Self.probe.midY)), mauve, "\(scheme): a mauve ring")
            XCTAssertEqual(hex(image, CGPoint(x: Self.probe.maxX - 1.5, y: Self.probe.midY)), mauve, "\(scheme): a mauve ring")
            XCTAssertEqual(
                hex(image, CGPoint(x: Self.probe.midX, y: Self.probe.midY)), theme.palette.terminalGround.hex,
                "\(scheme): the ring is open, like idle's"
            )
        }
    }

    private func card(
        _ status: AgentStatus, background: String? = nil, title: String, minutes: Double, theme: Theme
    ) -> MissionCard {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return MissionCard(
            paneID: PaneID(rawValue: "w1:\(title)"), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            workspaceName: "acme", tabTitle: "api", title: title,
            status: background == nil ? status : .working, since: now.addingTimeInterval(-60 * minutes), folder: "/tmp/acme",
            backgroundWork: background
        )
    }

    private func sheet(_ theme: Theme) -> some View {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cards = [
            card(.idle, background: "1 shell", title: "Watch the acme CI run", minutes: 3, theme: theme),
            card(.done, background: "1 shell, 1 monitor", title: "Wait on the acme review", minutes: 12, theme: theme),
            card(.working, title: "Refactor the request pipeline", minutes: 5, theme: theme),
            card(.idle, title: "Idle at the prompt", minutes: 40, theme: theme),
            card(.done, title: "Finished the acme migration", minutes: 2, theme: theme),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            BackgroundMarkView(theme: theme, size: Self.probe.width)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(cards, id: \.paneID) { card in
                        MissionCardView(
                            theme: theme, card: card, place: "acme @ main", segments: [], now: now,
                            isSelected: false, isCooling: false, forced: nil, rename: nil, activate: {}
                        )
                    }
                }
                .frame(width: 420)
                VStack(alignment: .leading, spacing: 16) {
                    FocusedPlace(theme: theme, card: cards[0], markKey: "w1")
                        .frame(height: ChromeMetrics.Grid.focusedHeaderHeight)
                    FocusedPlace(theme: theme, card: cards[2], markKey: "w1")
                        .frame(height: ChromeMetrics.Grid.focusedHeaderHeight)
                    thumbnail(theme)
                    HStack(spacing: 10) {
                        StatusDot(status: .working, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
                        StatusDot(status: .idle, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot, isBackground: true)
                        StatusDot(status: .idle, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
                        StatusDot(status: .done, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
                    }
                }
            }
        }
        .padding(16)
    }

    private func thumbnail(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            TabHandleStrip(theme: theme, title: "api", status: .idle, isBackground: true, isFocusedTab: false)
            HStack(spacing: ChromeMetrics.Grid.miniPaneGap) {
                MiniPane(theme: theme, title: "claude", status: .idle, backgroundWork: "1 shell")
                MiniPane(theme: theme, title: "zsh", status: .idle)
            }
            .padding(ChromeMetrics.Grid.thumbnailPadding)
        }
        .frame(width: 240, height: 110)
        .background(theme.pane, in: RoundedRectangle(cornerRadius: ChromeRadius.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeRadius.surface)
                .strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth)
        )
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
