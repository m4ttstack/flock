import AppKit
import FlockCore
import SwiftUI
import XCTest

/// The rail heading's All Workspaces button, lit as a hover lights it: the
/// glyph sits in the middle of the block behind it. Measured from pixels
/// rather than from layout, since a symbol's layout box and its drawn ink are
/// not the same rect. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is
/// set.
@MainActor
final class RailHeadingButtonRenderTests: XCTestCase {
    private static let inset: CGFloat = 10
    private static let scale: CGFloat = 2

    func testTheGridButtonsGlyphIsCenteredInItsHoverBlock() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for theme in [Theme(.tokyoNight), try XCTUnwrap(Theme.builtins.first { $0.id == "catppuccin-latte" })] {
            let button = Button {} label: { AllWorkspacesButton.glyph }
                .buttonStyle(HeadingButtonStyle(theme: theme, isHovering: true))
            let window = host(button, theme: theme, size: CGSize(width: 44, height: 44))
            for _ in 0..<6 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            defer { window.close() }
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("rail-grid-button-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }

            // Read off the block itself, inside its rounded corner, so the
            // check holds whichever role the style fills it with.
            let fill = hex(image, x: Int((Self.inset + 3) * Self.scale), y: Int((Self.inset + 3) * Self.scale))
            XCTAssertNotEqual(fill, hex(image, x: 2, y: 2), "\(theme.id): the hover block is not lit")
            let block = try XCTUnwrap(bounds(in: image) { $0 == fill }, "\(theme.id): no hover block")
            let ink = try XCTUnwrap(
                bounds(in: image, within: block.insetBy(dx: 2, dy: 2)) { $0 != fill },
                "\(theme.id): no glyph inside the block"
            )
            XCTAssertEqual(ink.midX, block.midX, accuracy: 1, "\(theme.id): glyph \(ink) is off center in \(block) across")
            XCTAssertEqual(ink.midY, block.midY, accuracy: 1, "\(theme.id): glyph \(ink) is off center in \(block) down")
        }
    }

    /// The pixel rect, in the 2x image, of every pixel passing `matches`.
    private func bounds(in image: NSBitmapImageRep, within area: CGRect? = nil, where matches: (String) -> Bool) -> CGRect? {
        let scan = area ?? CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in Int(scan.minY)..<Int(scan.maxY) {
            for x in Int(scan.minX)..<Int(scan.maxX) where matches(hex(image, x: x, y: y)) {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func host(_ view: some View, theme: Theme, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                theme.chrome
                view.padding(.leading, Self.inset).padding(.top, Self.inset)
            }
            .frame(width: size.width, height: size.height)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
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

    private func hex(_ image: NSBitmapImageRep, x: Int, y: Int) -> String {
        guard let data = image.bitmapData, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }
}
