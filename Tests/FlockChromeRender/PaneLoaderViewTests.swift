import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The pane attach loader's static composition: the mark and its caption,
/// forced through the reduced-motion path so the render is deterministic.
/// The trail's own loop is verified by eye and by `PaneLoaderChoreographyTests`
/// in FlockCoreTests, never by asserting a frame of a running animation here.
@MainActor
final class PaneLoaderViewTests: XCTestCase {
    private struct Probe: View {
        static let size = CGSize(width: 300, height: 260)
        let theme: Theme

        var body: some View {
            ZStack {
                theme.pane
                PaneLoaderView(theme: theme, reducedMotionOverride: true)
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    private func hostProbe(theme: Theme = .tokyoNight) async -> (window: NSWindow, hosting: NSHostingView<Probe>) {
        let hosting = NSHostingView(rootView: Probe(theme: theme))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Probe.size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (window, hosting)
    }

    private func snapshot(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        view.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func hex(_ image: NSBitmapImageRep, x: Int, y: Int) -> String? {
        guard let data = image.bitmapData else { return nil }
        guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    /// A human-reviewed PNG plus the one thing a pixel test can actually
    /// prove for painted vector art: something other than the bare pane
    /// ground landed in the mark's own square and in the caption's row.
    func testTheMarkAndCaptionPaintOverThePaneGround() async throws {
        let theme = Theme.tokyoNight
        let (window, _) = try await hostProbe(theme: theme)
        defer { window.close() }

        // The fade-in starts at zero opacity; the loader has to actually be
        // visible before any pixel assertion means anything.
        try? await Task.sleep(for: .milliseconds(400))
        let image = try snapshot(window)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("pane-loader.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }

        let paneHex = theme.palette.chromeRoles.pane.hex
        var markPixelCount = 0
        let markBand = CGRect(
            x: (Probe.size.width - ChromeMetrics.Loader.markSize) / 2, y: 20,
            width: ChromeMetrics.Loader.markSize, height: ChromeMetrics.Loader.markSize
        )
        for y in Int(markBand.minY)..<Int(markBand.maxY) {
            for x in Int(markBand.minX)..<Int(markBand.maxX) {
                if hex(image, x: x * 2, y: y * 2) != paneHex {
                    markPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(markPixelCount, 500, "no ram-shaped paint landed in the mark's own square")

        var captionPixelCount = 0
        for y in Int(markBand.maxY)..<Int(Probe.size.height) {
            for x in 0..<Int(Probe.size.width) {
                if hex(image, x: x * 2, y: y * 2) != paneHex {
                    captionPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(captionPixelCount, 20, "no caption text painted below the mark")
    }
}
