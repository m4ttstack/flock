import AppKit
import FlockCore
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

    func testNamedAndCustomCopy() {
        let named = NoHerdrScreen.notRunning(for: .named("acme"), isOverride: false)
        XCTAssertEqual(named.headline, "The herdr server \u{201C}acme\u{201D} isn't running.")
        XCTAssertEqual(named.body, "flock is checking for it and will attach as soon as it starts.")
        XCTAssertEqual(named.hint, "Start it here, or run herdr --session acme in a terminal.")
        let custom = NoHerdrScreen.notRunning(for: .custom("/tmp/acme/x.sock"), isOverride: false)
        XCTAssertEqual(custom.headline, "Nothing is answering at /tmp/acme/x.sock.")
        XCTAssertEqual(custom.body, "flock is checking and will attach as soon as a herdr server is listening there.")
        XCTAssertEqual(custom.hint, "Start that server however it is normally started.")
    }

    func testDefaultCopyIsUnchanged() {
        XCTAssertEqual(NoHerdrScreen.notRunning(for: .defaultServer, isOverride: false), NoHerdrScreen.notRunning)
        XCTAssertEqual(
            NoHerdrScreen.notRunning(for: .custom("/tmp/acme/x.sock"), isOverride: true).hint,
            "Start it here, or start that server however it is normally started."
        )
    }

    func testOnlyAPickedCustomPathHasNoStartButton() {
        let path = "/tmp/acme/x.sock"
        XCTAssertNil(NoHerdrScreen.startTitle(for: .custom(path), isOverride: false, isStarting: false))
        XCTAssertEqual(NoHerdrScreen.startTitle(for: .custom(path), isOverride: true, isStarting: false), "Start herdr")
        XCTAssertEqual(NoHerdrScreen.startTitle(for: .named("acme"), isOverride: false, isStarting: true), "Starting herdr\u{2026}")
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
        let environment = HerdrServerLauncher.environment(from: ["RT_BATCH": "1", "PATH": "/usr/bin"], target: .defaultServer)
        XCTAssertNil(environment["RT_BATCH"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    /// The server must not inherit the socket of whichever session flock
    /// last pointed its tools at.
    func testDefaultAndNamedServersStartWithoutTheSessionsSocket() {
        for target: HerdrServerLauncher.Target in [.defaultServer, .named("acme")] {
            let environment = HerdrServerLauncher.environment(from: ["HERDR_SOCKET_PATH": "/tmp/h.sock"], target: target)
            XCTAssertNil(environment["HERDR_SOCKET_PATH"], "\(target)")
        }
    }

    func testAnOverrideServerStartsOnItsSocket() {
        let environment = HerdrServerLauncher.environment(from: [:], target: .overrideSocket("/tmp/acme/x.sock"))
        XCTAssertEqual(environment["HERDR_SOCKET_PATH"], "/tmp/acme/x.sock")
    }

    /// herdr's own client sets this when it starts a server; without it the
    /// server stays in the launching app's bootstrap context.
    func testTheServerAsksHerdrForThePerUserServiceContext() {
        let environment = HerdrServerLauncher.environment(from: ["PATH": "/usr/bin"], target: .defaultServer)
        XCTAssertEqual(environment["HERDR_MACOS_SERVER_CONTEXT"], "user")
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

            let named = NoHerdrScreen(
                theme: theme, copy: NoHerdrScreen.notRunning(for: .named("acme-review-session"), isOverride: false),
                primaryAction: .init(title: "Start herdr", perform: {})
            )
            let custom = NoHerdrScreen(
                theme: theme, copy: NoHerdrScreen.notRunning(for: .custom("/Users/acme/.config/herdr/sessions/review/herdr.sock"), isOverride: false)
            )
            for (name, screen) in [("named", AnyView(named)), ("custom", AnyView(custom))] {
                let window = hostWindow(screen)
                await settle(window)
                if let directory {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("no-herdr-\(name)-\(theme.id).png")
                    try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:])).write(to: url)
                }
                window.close()
            }
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
