import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The find bar over a terminal-sized ground, in a dark and a light theme.
/// PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class TerminalFindBarRenderTests: XCTestCase {
    private static let paneSize = CGSize(width: 560, height: 220)
    private static let groundColor = Color(red: 1, green: 0, blue: 1)
    private static let groundHex = "#FF00FF"

    private struct Probe: View {
        let theme: Theme
        let search: TerminalSearch

        var body: some View {
            ZStack(alignment: .topTrailing) {
                TerminalFindBarRenderTests.groundColor
                TerminalFindBar(
                    theme: theme, search: search, onSearch: { _ in }, onNavigate: { _ in }, onClose: {}
                )
                .padding(ChromeMetrics.FindBar.inset)
            }
            .frame(width: TerminalFindBarRenderTests.paneSize.width, height: TerminalFindBarRenderTests.paneSize.height)
        }
    }

    private func render(theme: Theme, name: String) async throws -> NSBitmapImageRep {
        let search = TerminalSearch()
        search.open(needle: "acme")
        search.report(total: 12)
        search.report(selected: 2)
        let hosting = NSHostingView(rootView: Probe(theme: theme, search: search))
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
            let url = URL(fileURLWithPath: directory).appendingPathComponent("find-bar-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// Every pixel that is not the ground, as a bounding box in a top-left
    /// origin bitmap.
    private func paintedBox(_ image: NSBitmapImageRep) -> CGRect? {
        guard let data = image.bitmapData else { return nil }
        var box = CGRect.null
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
                let hex = String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
                if hex != Self.groundHex { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) }
            }
        }
        return box.isNull ? nil : box
    }

    private func assertSitsInTheTopTrailingCorner(_ image: NSBitmapImageRep) throws {
        let box = try XCTUnwrap(paintedBox(image), "the find bar painted nothing")
        XCTAssertGreaterThan(Double(box.minX), Double(image.pixelsWide) / 3, "the bar strayed toward the leading edge: \(box)")
        XCTAssertLessThan(Double(box.maxY), Double(image.pixelsHigh) / 2, "the bar strayed below the top half: \(box)")
    }

    func testTheBarSitsTopTrailingInADarkTheme() async throws {
        try assertSitsInTheTopTrailingCorner(await render(theme: .tokyoNight, name: "dark"))
    }

    func testTheBarSitsTopTrailingInALightTheme() async throws {
        let light = try XCTUnwrap(Theme.builtins.first { $0.id == ThemePalette.tokyoNightDay.id })
        try assertSitsInTheTopTrailingCorner(await render(theme: light, name: "light"))
    }
}
