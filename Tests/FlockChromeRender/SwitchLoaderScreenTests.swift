import AppKit
import FlockCore
import SwiftUI
import XCTest

/// The switch loader in each state it shows, dark and light (`SwitchLoader*Tests`
/// in FlockCoreTests own the copy and the timing). PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class SwitchLoaderScreenTests: XCTestCase {
    private static let size = CGSize(width: 900, height: 560)
    private static let mini = HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "acme-mini", target: "acme-mini", session: "default")

    private struct Still {
        let name: String
        let run: SwitchLoaderRun
        let time: Double
        var reduceMotion = false
        var isMachine = true
    }

    private func model(_ input: SwitchLoaderInput) throws -> SwitchLoaderModel {
        try XCTUnwrap(SwitchLoaderModel.make(input))
    }

    private func machine(_ tunnel: MachineTunnelState, _ store: ConnectionState, removed: Bool = false) throws -> SwitchLoaderModel {
        try model(SwitchLoaderInput(
            label: "acme-mini", isMachine: true, isDefaultProfile: false, tunnel: tunnel, store: store, currentMachineMissing: removed
        ))
    }

    private func stills() throws -> [Still] {
        let period = SwitchLoaderRun.Timing.period
        let connecting = SwitchLoaderRun(id: 1, startedAt: 0, model: try machine(.connecting, .connecting))
        var attaching = connecting
        attaching.apply(try machine(.up, .connecting), at: 1.3)
        func failing(_ failure: SwitchLoaderModel) -> SwitchLoaderRun {
            var run = connecting
            run.apply(failure, at: 2.4)
            return run
        }
        let local = SwitchLoaderRun(id: 2, startedAt: 0, model: try model(SwitchLoaderInput(
            label: "Default", isMachine: false, isDefaultProfile: true, store: .connecting, isSwitching: true
        )))
        var fading = attaching
        fading.apply(try machine(.up, .live), at: 3.0)
        return [
            Still(name: "connecting", run: connecting, time: 0.775),
            Still(name: "connecting-merged", run: connecting, time: period + 0.42),
            Still(name: "status-crossfade", run: attaching, time: 1.3 + 0.17),
            Still(name: "attaching", run: attaching, time: 2 * period + 0.775),
            Still(name: "cant-reach", run: failing(try machine(.unreachable(reason: "Permission denied (publickey)."), .reconnecting(attempt: 1))), time: 6),
            Still(name: "cant-reach-turning", run: failing(try machine(.unreachable(reason: "Connection timed out."), .connecting)), time: 2.6),
            Still(name: "not-running", run: failing(try machine(.noServer, .notRunning(attempt: 1))), time: 6),
            Still(name: "removed", run: failing(try machine(.connecting, .connecting, removed: true)), time: 6),
            Still(name: "local-switching", run: local, time: 0.775, isMachine: false),
            Still(name: "fading", run: fading, time: (fading.finishAt ?? 0) + 0.12),
            Still(name: "reduce-motion", run: connecting, time: 3.2, reduceMotion: true),
        ]
    }

    func testRendersEachStateOverTheThemesChrome() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let themes = try ["tokyo-night", "tokyo-night-day"].map { id in try XCTUnwrap(Theme.builtins.first { $0.id == id }) }
        let picker = try picker()
        for theme in themes {
            for still in try stills() {
                let screen = SwitchLoaderScreen(
                    theme: theme, run: still.run, profilePicker: picker,
                    profileDot: still.isMachine ? .attention : nil, stillAt: still.time, reduceMotionOverride: still.reduceMotion
                )
                let window = hostWindow(screen)
                await settle(window)
                let image = try snapshot(window)
                if let directory {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("switch-loader-\(still.name)-\(theme.id).png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                }
                if still.name != "fading" {
                    XCTAssertEqual(hex(image, CGPoint(x: 10, y: 10)), theme.palette.chromeRoles.chrome.hex, still.name)
                }
                window.close()
            }
        }
    }

    // MARK: - harness

    private func picker() throws -> ProfilePickerContext {
        let suite = "SwitchLoaderScreenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = ProfileStore(
            userDefaults: defaults, bundleID: "dev.acme.flock-tests", defaultSocketPath: "/tmp/acme.sock",
            home: "/Users/acme", removeSuite: { _ in }
        )
        store.syncMachines([Self.mini])
        store.select("machine.\(Self.mini.id)")
        return ProfilePickerContext(profiles: store, isLocked: false, switchProfile: { _ in false }, listMachines: { nil })
    }

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
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
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
}
