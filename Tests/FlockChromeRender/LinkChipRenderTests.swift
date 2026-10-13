import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The link chip over a few lines of terminal text, in a dark and a light
/// theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class LinkChipRenderTests: XCTestCase {
    private static let paneSize = CGSize(width: 560, height: 140)
    private static let lineHeight: CGFloat = 17
    /// The fourth line, the one with the path on it.
    private static let anchor = LinkChip.Anchor(x: 300, lineTop: lineHeight * 3, lineBottom: lineHeight * 4)
    /// Wider than either chip, so the box under test is the placement's.
    private static let chipSize = CGSize(width: 130, height: ChromeMetrics.LinkChip.height)

    private struct Probe: View {
        let theme: Theme
        let link: PaneLink

        var body: some View {
            let lines = [
                "Both lanes have gone as far as they can without you.",
                "",
                "Look at these first (local files)",
                "- M2, 2x captures: ~/.cache/acme/runs/2026-10-12/sheet.html",
                "- M3, first report: same folder, m3-exit/sheet.html",
            ]
            ZStack(alignment: .topLeading) {
                theme.terminalGround
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(theme.terminalForeground)
                            .frame(height: LinkChipRenderTests.lineHeight)
                    }
                }
                .padding(.leading, 8)
                LinkChipView(theme: theme, link: link, onOpen: {}, onReveal: {}, onCopy: {})
                    .offset(x: LinkChipRenderTests.origin.x, y: LinkChipRenderTests.origin.y)
            }
            .frame(width: LinkChipRenderTests.paneSize.width, height: LinkChipRenderTests.paneSize.height)
        }
    }

    private static var origin: CGPoint {
        LinkChip.origin(
            for: anchor, chip: chipSize, pane: paneSize,
            gap: ChromeMetrics.LinkChip.gap, inset: ChromeMetrics.LinkChip.inset
        )
    }

    private func render(theme: Theme, link: PaneLink, name: String) async throws -> NSBitmapImageRep {
        ChromeType.install()
        let hosting = NSHostingView(rootView: Probe(theme: theme, link: link))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.paneSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }

        let scale: CGFloat = 2
        let bounds = hosting.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        hosting.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("link-chip-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    private func pixel(_ image: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> [UInt8] {
        let data = try XCTUnwrap(image.bitmapData)
        let offset = Int(y * 2) * image.bytesPerRow + Int(x * 2) * (image.bitsPerPixel / 8)
        return [data[offset], data[offset + 1], data[offset + 2]]
    }

    /// The chip's ground is the chrome's, which has to read as its own
    /// surface against the terminal it floats on.
    private func assertTheChipStandsOffTheTerminal(_ image: NSBitmapImageRep) throws {
        let ground = try pixel(image, x: Self.paneSize.width - 4, y: Self.paneSize.height - 4)
        let inside = try pixel(image, x: Self.origin.x + 4, y: Self.origin.y + ChromeMetrics.LinkChip.height / 2)
        XCTAssertNotEqual(inside, ground, "the chip's ground is the terminal's own")
    }

    private let file = PaneLink.file(URL(fileURLWithPath: "/Users/acme/sheet.html"))
    private let web = PaneLink.web(URL(string: "https://example.com/acme")!)

    func testTheFileChipInADarkTheme() async throws {
        try assertTheChipStandsOffTheTerminal(await render(theme: .tokyoNight, link: file, name: "file-dark"))
    }

    func testTheFileChipInALightTheme() async throws {
        let light = try XCTUnwrap(Theme.builtins.first { $0.id == ThemePalette.tokyoNightDay.id })
        try assertTheChipStandsOffTheTerminal(await render(theme: light, link: file, name: "file-light"))
    }

    func testTheAddressChipInADarkTheme() async throws {
        try assertTheChipStandsOffTheTerminal(await render(theme: .tokyoNight, link: web, name: "web-dark"))
    }

    func testTheAddressChipInALightTheme() async throws {
        let light = try XCTUnwrap(Theme.builtins.first { $0.id == ThemePalette.tokyoNightDay.id })
        try assertTheChipStandsOffTheTerminal(await render(theme: light, link: web, name: "web-light"))
    }
}
