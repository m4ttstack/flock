import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The confirm card's other shapes, beyond the close warning's: one button
/// that only acknowledges, and a named card with no checkbox. Drawn by
/// themselves over a plain ground, in a dark and a light theme. PNGs are
/// written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ConfirmCardRenderTests: XCTestCase {
    private static let size = CGSize(width: 520, height: 360)

    @Observable
    final class Holder {
        var item: String?
    }

    struct Host: View {
        let theme: Theme
        let holder: Holder
        let content: ConfirmCardContent

        var body: some View {
            Color(theme.palette.panelBg)
                .modifier(ConfirmCardPresenter(theme: theme, item: holder.item, content: { _ in content }, answer: { _, _ in }))
        }
    }

    private func render(_ content: ConfirmCardContent, theme: Theme, name: String) async throws -> NSBitmapImageRep {
        ChromeType.install()
        let holder = Holder()
        let hosting = NSHostingView(rootView: Host(theme: theme, holder: holder, content: content).frame(width: Self.size.width, height: Self.size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        holder.item = "shown"
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("confirm-card-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// The card's ground is the scheme opposite the window's, so the middle of
    /// a shown card cannot be the window's own ground.
    func testTheOtherShapesDrawOverTheWindow() async throws {
        let shapes: [(String, ConfirmCardContent)] = [
            ("acknowledge", ConfirmCardContent(
                action: "\u{201C}acme\u{201D} can\u{2019}t move to the top bar",
                message: AttributedString("A workspace moves to the top bar with one tab. This one has 3."),
                cancelTitle: nil, confirmTitle: "OK", identifier: "test.acknowledge"
            )),
            ("named", ConfirmCardContent(
                action: "Close Workspace and Worktrees", name: "acme",
                message: AttributedString("herdr keeps this workspace and its linked worktree workspaces together. Closing it closes all of them."),
                confirmTitle: "Close Group", identifier: "test.named"
            )),
        ]
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            for (name, content) in shapes {
                let image = try await render(content, theme: theme, name: "\(name)-\(scheme)")
                let ground = hex(of: theme.palette.panelBg)
                let middle = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2).map(Self.hex)
                XCTAssertNotEqual(middle, ground, "\(name) \(scheme): no card over the window's middle")
            }
        }
    }

    private func hex(of rgb: RGB) -> String { String(format: "%02x%02x%02x", rgb.red, rgb.green, rgb.blue) }

    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
