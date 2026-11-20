import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The screen a pane shows once another client takes it over, in a dark and a
/// light theme. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class PaneHoldLostRenderTests: XCTestCase {
    private static let paneSize = CGSize(width: 640, height: 348)

    private func render(theme: Theme, reason: HoldLossReason, name: String) async throws -> NSBitmapImageRep {
        ChromeType.install()
        let hosting = NSHostingView(
            rootView: PaneHoldLostView(theme: theme, reason: reason, onTakeBack: {})
                .frame(width: Self.paneSize.width, height: Self.paneSize.height)
        )
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
            let url = URL(fileURLWithPath: directory).appendingPathComponent("hold-lost-\(name).png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    /// The button is the largest patch off the pane ground, and it sits
    /// centred: a wide run of non-ground pixels across the middle column.
    private func assertTheButtonShows(_ image: NSBitmapImageRep, theme: Theme) throws {
        let ground = try XCTUnwrap(image.colorAt(x: 2, y: 2))
        let midX = image.pixelsWide / 2
        var longestRun = 0
        var run = 0
        for y in 0..<image.pixelsHigh {
            guard let pixel = image.colorAt(x: midX - 60, y: y) else { continue }
            let differs = abs(pixel.redComponent - ground.redComponent)
                + abs(pixel.greenComponent - ground.greenComponent)
                + abs(pixel.blueComponent - ground.blueComponent) > 0.3
            run = differs ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        XCTAssertGreaterThan(longestRun, 16,"no button across the middle of the pane")
    }

    func testTakenOverInADarkTheme() async throws {
        try assertTheButtonShows(await render(theme: .tokyoNight, reason: .takenOver, name: "dark"), theme: .tokyoNight)
    }

    func testTakenOverInALightTheme() async throws {
        let light = try XCTUnwrap(Theme.builtins.first { $0.id == ThemePalette.tokyoNightDay.id })
        try assertTheButtonShows(await render(theme: light, reason: .takenOver, name: "light"), theme: light)
    }

    func testTheLostLineCarriesItsReason() {
        let line = Data(#"{"type":"flock.hold_lost","reason":"taken_over"}"#.utf8)
        XCTAssertEqual(PaneStatusChannel.parseHoldLossReason(line), .takenOver)
        XCTAssertEqual(PaneStatusChannel.parseHoldLossReason(Data(#"{"type":"flock.hold_lost"}"#.utf8)), .refused)
        XCTAssertNil(PaneStatusChannel.parseHoldLossReason(Data(#"{"type":"flock.first_frame"}"#.utf8)))
    }
}
