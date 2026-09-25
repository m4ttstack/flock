import AppKit
import SwiftUI
import XCTest

/// The screen shown in place of `MainWindow` when herdr is not on this Mac
/// (`HerdrAvailabilityTests` in FlockCoreTests owns the pure show/hide
/// decision). PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class NoHerdrScreenTests: XCTestCase {
    private static let size = CGSize(width: 900, height: 560)

    /// Pinned so a copy edit is a deliberate change to this test, never a
    /// silent drift.
    func testTheShippedCopy() {
        XCTAssertEqual(NoHerdrScreen.headline, "You can't have a flock without a herdr!")
        XCTAssertEqual(NoHerdrScreen.body, "flock couldn't find herdr on this Mac, so there is nothing to drive a pane with.")
        XCTAssertEqual(NoHerdrScreen.hint, "Install herdr, then relaunch flock.")
    }

    func testTheNotRunningCopy() {
        XCTAssertEqual(NoHerdrScreen.notRunning.headline, "Oops! Doesn't look like herdr has started.")
        XCTAssertEqual(NoHerdrScreen.notRunning.body, "flock shows your herdr session, and no herdr server is running yet.")
        XCTAssertEqual(NoHerdrScreen.notRunning.hint, "Start it here, or run herdr in a terminal.")
    }

    func testTheNotRunningScreenOffersToStartHerdr() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for theme in [Theme.tokyoNight, Theme.builtins.first { $0.id == "one-light" }!] {
            let screen = NoHerdrScreen(
                theme: theme, copy: NoHerdrScreen.notRunning,
                primaryAction: .init(title: "Start herdr", perform: {})
            )
            let window = hostWindow(screen)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("herdr-not-running-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            XCTAssertEqual(hex(image, CGPoint(x: 10, y: 10)), theme.palette.chromeRoles.chrome.hex)
            window.close()
        }
    }

    /// The server's environment is every pane shell's, so rt's batch flag
    /// (set for flock's own children) must not reach it.
    func testTheServerStartsWithoutRtsBatchFlag() {
        let environment = HerdrServerLauncher.environment(from: ["RT_BATCH": "1", "PATH": "/usr/bin", "HERDR_SOCKET_PATH": "/tmp/h.sock"])
        XCTAssertNil(environment["RT_BATCH"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HERDR_SOCKET_PATH"], "/tmp/h.sock")
    }

    func testRendersOverTheThemesChromeWithNoButtonByDefault() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for theme in [Theme.tokyoNight, Theme.builtins.first { $0.id == "one-light" }!] {
            let window = hostWindow(NoHerdrScreen(theme: theme))
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("no-herdr-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            XCTAssertEqual(
                hex(image, CGPoint(x: 10, y: 10)), theme.palette.chromeRoles.chrome.hex,
                "the screen paints the chrome ground, not a stray default background"
            )
            window.close()
        }
    }

    /// Nil is every call site today: no button should draw, and nothing
    /// should claim a click where one would sit.
    func testNoPrimaryActionMeansNoButtonAtAll() {
        let withoutAction = fittingHeight(NoHerdrScreen(theme: .tokyoNight).content)
        let withAction = fittingHeight(
            NoHerdrScreen(theme: .tokyoNight, primaryAction: .init(title: "Patch herdr", perform: {})).content
        )
        XCTAssertGreaterThan(
            withAction, withoutAction,
            "supplying a primaryAction must grow the view -- proving the slot exists without a rewrite"
        )
    }

    // MARK: - harness

    private func hostWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat = 2) -> String {
        guard let data = image.bitmapData else { return "?" }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}
