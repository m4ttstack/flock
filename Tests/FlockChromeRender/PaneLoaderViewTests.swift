import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The pane attach loader's static composition, rendered OVER a stand-in for
/// live terminal content rather than in isolation: an isolated render is
/// exactly what let the loader ship transparent, with real output showing
/// straight through it. The trail's own loop is verified by eye and by
/// `PaneLoaderChoreographyTests` in FlockCoreTests, never by asserting a
/// frame of a running animation here.
@MainActor
final class PaneLoaderViewTests: XCTestCase {
    /// A colour no pane ground, theme role, or brand mark colour can
    /// produce, standing in for real terminal output: any pixel of it
    /// surviving through the loader is the coverage bug back.
    private static let terminalMarkerColor = Color(red: 1, green: 0, blue: 1)
    private static let terminalMarkerHex = "#FF00FF"

    private struct Probe: View {
        let theme: Theme
        let paneSize: CGSize

        var body: some View {
            ZStack {
                PaneLoaderViewTests.terminalMarkerColor
                PaneLoaderView(theme: theme, reducedMotionOverride: true)
            }
            .frame(width: paneSize.width, height: paneSize.height)
        }
    }

    private func hostProbe(theme: Theme, paneSize: CGSize) async -> NSWindow {
        let hosting = NSHostingView(rootView: Probe(theme: theme, paneSize: paneSize))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: paneSize),
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
        return window
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

    private func render(theme: Theme, paneSize: CGSize, name: String) async throws -> NSBitmapImageRep {
        let window = await hostProbe(theme: theme, paneSize: paneSize)
        defer { window.close() }
        // The fade-in starts at zero opacity; the loader has to actually be
        // visible before any pixel assertion means anything.
        try? await Task.sleep(for: .milliseconds(400))
        let image = try snapshot(window)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("pane-loader-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// A human-reviewed PNG at each size, plus the two things a pixel test
    /// can actually prove: nothing of the marker colour behind the loader
    /// survives anywhere in the pane (full, opaque coverage), and something
    /// other than flat pane ground painted (the mark and caption are there).
    private func assertFullyOpaqueAndPainted(_ image: NSBitmapImageRep, paneSize: CGSize, groundHex: String) {
        var markerPixelCount = 0
        var nonGroundPixelCount = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: image.pixelsWide, by: 3) {
                guard let sampled = hex(image, x: x, y: y) else { continue }
                if sampled == Self.terminalMarkerHex { markerPixelCount += 1 }
                if sampled != groundHex { nonGroundPixelCount += 1 }
            }
        }
        XCTAssertEqual(markerPixelCount, 0, "terminal content showed through the loader at pane size \(paneSize)")
        XCTAssertGreaterThan(nonGroundPixelCount, 50, "nothing painted over the ground at pane size \(paneSize)")
    }

    func testTheLoaderFullyCoversTerminalContentAtASmallSplitSize() async throws {
        let theme = Theme.tokyoNight
        let paneSize = CGSize(width: 240, height: 160)
        let image = try await render(theme: theme, paneSize: paneSize, name: "small")
        assertFullyOpaqueAndPainted(image, paneSize: paneSize, groundHex: theme.palette.chromeRoles.pane.hex)
    }

    func testTheLoaderFullyCoversTerminalContentAtAMediumPaneSize() async throws {
        let theme = Theme.tokyoNight
        let paneSize = CGSize(width: 520, height: 360)
        let image = try await render(theme: theme, paneSize: paneSize, name: "medium")
        assertFullyOpaqueAndPainted(image, paneSize: paneSize, groundHex: theme.palette.chromeRoles.pane.hex)
    }

    func testTheLoaderFullyCoversTerminalContentAtAFullWidthPaneSize() async throws {
        let theme = Theme.tokyoNight
        let paneSize = CGSize(width: 1000, height: 640)
        let image = try await render(theme: theme, paneSize: paneSize, name: "large")
        assertFullyOpaqueAndPainted(image, paneSize: paneSize, groundHex: theme.palette.chromeRoles.pane.hex)
    }
}

/// The mark's own size rule: a fraction of the pane's shorter side, clamped
/// at both ends. Pure CGFloat/CGSize arithmetic, so this needs no host
/// window -- it just has to never regress back to a fixed constant.
final class ChromeMetricsLoaderSizingTests: XCTestCase {
    func testScalesWithTheShorterSideWithinBounds() {
        let size = ChromeMetrics.Loader.markSize(paneSize: CGSize(width: 900, height: 400))
        XCTAssertEqual(size, 400 * ChromeMetrics.Loader.markSizeFraction, accuracy: 0.01)
    }

    func testClampsToTheMinimumInANarrowSplit() {
        let size = ChromeMetrics.Loader.markSize(paneSize: CGSize(width: 150, height: 120))
        XCTAssertEqual(size, ChromeMetrics.Loader.markSizeMin)
    }

    func testClampsToTheMaximumInAVeryLargePane() {
        let size = ChromeMetrics.Loader.markSize(paneSize: CGSize(width: 2000, height: 1400))
        XCTAssertEqual(size, ChromeMetrics.Loader.markSizeMax)
    }
}
