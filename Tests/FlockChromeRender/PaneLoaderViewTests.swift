import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The attach badge, rendered over the pane ground it actually sits on.
///
/// The previous full-pane version was asserted the other way round: that no
/// pixel of the content behind it survived. A badge is the opposite promise --
/// it covers almost nothing, stays in its corner, and leaves the rest of the
/// pane alone. The run itself is asserted at frozen instants
/// (`frozenElapsed`), never by sampling a running animation;
/// `PaneLoaderStrideTests` owns its path.
@MainActor
final class PaneLoaderViewTests: XCTestCase {
    /// Stands in for the pane ground the badge is drawn on. A colour nothing
    /// else in the composition can produce, so any pixel that is NOT this is
    /// the badge itself.
    private static let groundColor = Color(red: 1, green: 0, blue: 1)
    private static let groundHex = "#FF00FF"

    private struct Probe: View {
        let theme: Theme
        let paneSize: CGSize
        var frozenElapsed: Double?
        var onThemeGround = false

        var body: some View {
            ZStack {
                onThemeGround ? theme.pane : PaneLoaderViewTests.groundColor
                PaneLoaderView(theme: theme, reducedMotionOverride: frozenElapsed == nil, frozenElapsed: frozenElapsed)
            }
            .frame(width: paneSize.width, height: paneSize.height)
        }
    }

    private func hostProbe(
        theme: Theme, paneSize: CGSize, frozenElapsed: Double? = nil, onThemeGround: Bool = false
    ) async -> NSWindow {
        let hosting = NSHostingView(rootView: Probe(
            theme: theme, paneSize: paneSize, frozenElapsed: frozenElapsed, onThemeGround: onThemeGround
        ))
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

    private func render(
        theme: Theme, paneSize: CGSize, name: String, frozenElapsed: Double? = nil, onThemeGround: Bool = false
    ) async throws -> NSBitmapImageRep {
        let window = await hostProbe(
            theme: theme, paneSize: paneSize, frozenElapsed: frozenElapsed, onThemeGround: onThemeGround
        )
        defer { window.close() }
        // The badge fades in from zero opacity; it has to actually be visible
        // before any pixel assertion means anything.
        try? await Task.sleep(for: .milliseconds(400))
        let image = try snapshot(window)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("pane-loader-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// Every painted pixel, as a fraction of the pane, and the bounding box
    /// they fall in.
    private func paintedRegion(_ image: NSBitmapImageRep) -> (coverage: Double, box: CGRect)? {
        var painted = 0
        var sampled = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let sample = hex(image, x: x, y: y) else { continue }
                sampled += 1
                guard sample != Self.groundHex else { continue }
                painted += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard painted > 0, sampled > 0 else { return nil }
        return (
            Double(painted) / Double(sampled),
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }

    /// A badge is furniture: it says something is happening and gets out of
    /// the way. The full-pane version it replaced covered everything, which is
    /// what made every attach feel like a wait.
    private func assertIsASmallCornerBadge(
        _ image: NSBitmapImageRep, paneSize: CGSize, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let region = try XCTUnwrap(paintedRegion(image), "the badge painted nothing at all", file: file, line: line)

        XCTAssertLessThan(
            region.coverage, 0.1,
            "the badge covered \(Int(region.coverage * 100))% of a \(paneSize) pane; it is meant to be furniture",
            file: file, line: line
        )
        // Bottom trailing, in a top-left-origin bitmap: past the midpoint on
        // both axes. Anything centred fails this, which is the regression
        // that matters -- a badge that drifts back to the middle of the pane
        // is the thing being replaced.
        XCTAssertGreaterThan(
            Double(region.box.minX), Double(image.pixelsWide) / 2,
            "the badge strayed left of the pane's middle", file: file, line: line
        )
        XCTAssertGreaterThan(
            Double(region.box.minY), Double(image.pixelsHigh) / 2,
            "the badge strayed above the pane's middle", file: file, line: line
        )
    }

    func testTheBadgeStaysSmallAndInTheCornerOfASmallSplit() async throws {
        let paneSize = CGSize(width: 240, height: 160)
        let image = try await render(theme: .tokyoNight, paneSize: paneSize, name: "small")
        try assertIsASmallCornerBadge(image, paneSize: paneSize)
    }

    func testTheBadgeStaysSmallAndInTheCornerOfAnOrdinaryPane() async throws {
        let paneSize = CGSize(width: 520, height: 360)
        let image = try await render(theme: .tokyoNight, paneSize: paneSize, name: "medium")
        try assertIsASmallCornerBadge(image, paneSize: paneSize)
    }

    /// The size is fixed, so the bigger the pane the smaller the share it
    /// takes. A badge that scaled with its container would fail this.
    func testTheBadgeTakesAVanishingShareOfAFullWidthPane() async throws {
        let paneSize = CGSize(width: 1000, height: 640)
        let image = try await render(theme: .tokyoNight, paneSize: paneSize, name: "large")
        try assertIsASmallCornerBadge(image, paneSize: paneSize)

        let region = try XCTUnwrap(paintedRegion(image))
        XCTAssertLessThan(region.coverage, 0.02)
    }

    /// The run starts where the resting badge sits, stays on the bottom edge,
    /// and heads left, the way the ram faces.
    func testTheRunHugsTheBottomAndHeadsLeft() async throws {
        let paneSize = CGSize(width: 520, height: 360)
        let first = try await render(theme: .tokyoNight, paneSize: paneSize, name: "run-start", frozenElapsed: 0)
        let later = try await render(theme: .tokyoNight, paneSize: paneSize, name: "run-later", frozenElapsed: 1.5)

        let start = try XCTUnwrap(paintedRegion(first), "the run painted nothing at its start")
        let moved = try XCTUnwrap(paintedRegion(later), "the run painted nothing 1.5s in")
        XCTAssertGreaterThan(Double(start.box.minX), Double(first.pixelsWide) / 2, "the run did not start in the right half")
        XCTAssertLessThan(moved.box.minX, start.box.minX, "the run did not head left")
        for region in [start, moved] {
            XCTAssertGreaterThan(Double(region.box.minY), Double(first.pixelsHigh) * 0.75, "the run left the bottom edge")
        }
    }

    /// Frames on each theme's real pane ground, for looking at.
    /// Most waits end inside a second or two, so the early frames are the
    /// ones that matter; by 2s the trail is at full length.
    func testTheRunOnRealGroundsForReview() async throws {
        let paneSize = CGSize(width: 520, height: 200)
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            for elapsed in [0, 0.6, 1.2, 2.0] {
                _ = try await render(
                    theme: theme, paneSize: paneSize, name: "run-\(scheme)-\(Int(elapsed * 1000))ms",
                    frozenElapsed: elapsed, onThemeGround: true
                )
            }
        }
    }
}
