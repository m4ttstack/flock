import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// ⌥`'s panel: default current with acme-work, the last server used,
/// selected; then acme-work current with default selected. A stopped server
/// sits below both. Dark and light. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ServerSwitcherRenderTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let home = "/Users/acme"
    private static let defaultSocket = "/Users/acme/.config/herdr/herdr.sock"
    private static let workSocket = "/Users/acme/.config/herdr/sessions/acme-work/herdr.sock"
    private static let buildSocket = "/Users/acme/.config/herdr/sessions/acme-build/herdr.sock"
    private static let entries = [
        HerdrSessionEntry(name: "default", isRunning: true, socketPath: defaultSocket, isDefault: true),
        HerdrSessionEntry(name: "acme-work", isRunning: true, socketPath: workSocket, isDefault: false),
        HerdrSessionEntry(name: "acme-build", isRunning: false, socketPath: buildSocket, isDefault: false),
    ]

    func testTheServerSwitcherNamesServersAsTheServerMenuDoes() async throws {
        ChromeType.install()
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let column = CGSize(width: 480, height: 400)
        let cases = [(current: Self.defaultSocket, previous: Self.workSocket), (current: Self.workSocket, previous: Self.defaultSocket)]
        let size = CGSize(width: column.width * CGFloat(cases.count), height: column.height)
        typealias Metrics = ChromeMetrics.Palette
        for (scheme, themeID) in [("dark", "tokyo-night"), ("light", "tokyo-night-day")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == themeID })
            var pickers: [ServerPicker] = []
            var switchers: [ServerSwitcher] = []
            for item in cases {
                let picker = ServerPicker(
                    list: { Self.entries }, start: { _ in .success(()) }, choose: { _ in false },
                    currentSocket: { item.current }, isLocked: false, home: Self.home
                )
                await picker.refresh()
                let switcher = ServerSwitcher(userDefaults: try scratchDefaults())
                switcher.note(currentSocket: item.previous, home: Self.home)
                switcher.note(currentSocket: item.current, home: Self.home)
                XCTAssertTrue(switcher.begin(
                    items: ServerSwitcher.candidates(picker.entries, currentSocket: item.current, home: Self.home, canChangeServer: true),
                    current: ServerID(socketPath: item.current, home: Self.home),
                    last: ServerSwitcher.stopped(picker.entries, home: Self.home)
                ))
                switcher.show(session: switcher.session)
                pickers.append(picker)
                switchers.append(switcher)
            }
            let view = HStack(spacing: 0) {
                ForEach(cases.indices, id: \.self) { index in
                    ServerSwitcherOverlay(
                        theme: theme, switcher: switchers[index], picker: pickers[index], canChangeServer: true,
                        currentSocket: { cases[index].current }, blocked: { false }
                    )
                    .frame(width: column.width, height: column.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(theme.chrome)
            let image = try await render(view, size: size)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("server-switcher-\(scheme).png"))
            }

            XCTAssertEqual(switchers[0].selected?.rawValue, Self.workSocket, "\(scheme): a tap from default goes to acme-work")
            XCTAssertEqual(switchers[1].selected?.rawValue, Self.defaultSocket, "\(scheme): and back")
            XCTAssertEqual(switchers[0].order.last?.rawValue, Self.buildSocket, "\(scheme): the stopped server is offered last")
            let rowCount = switchers[0].order.count
            let area = column.height - ChromeMetrics.TitleBar.height
            let top = ChromeMetrics.TitleBar.height + ChromeMetrics.Switcher.top(inTabAreaHeight: area, rowCount: rowCount)
            let rowY = { (index: Int) in
                top + ChromeMetrics.Switcher.headerHeight + ChromeMetrics.ruleWidth + Metrics.listPadding + CGFloat(index) * (Metrics.rowHeight + 1)
            }
            let boxX = (column.width - ChromeMetrics.Switcher.width) / 2
            let selection = Color(theme.palette.chromeRoles.selection)
            for index in cases.indices {
                let x = CGFloat(index) * column.width + boxX
                let highlight = CGRect(x: x + ChromeMetrics.Switcher.width - 80, y: rowY(1) + 3, width: 8, height: 4)
                XCTAssertTrue(contains(image, highlight, selection), "\(scheme) column \(index): the second row is selected")
            }
        }
    }

    private func scratchDefaults() throws -> UserDefaults {
        let suite = "ServerSwitcherRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func render(_ view: some View, size: CGSize) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: view)
        defer { window.close() }
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width * Self.scale), height: Int(bounds.height * Self.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.scale, y: Self.scale)
        content.displayIgnoringOpacity(bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// Whether any pixel in `rect` (points, top-left origin) is within a few
    /// channel steps of `color`.
    private func contains(_ image: NSBitmapImageRep, _ rect: CGRect, _ color: Color) -> Bool {
        guard let target = NSColor(color).usingColorSpace(.sRGB), let data = image.bitmapData else { return false }
        let want = [target.redComponent, target.greenComponent, target.blueComponent].map { Int(($0 * 255).rounded()) }
        let stride = image.bitsPerPixel / 8
        for y in Int(rect.minY * Self.scale)..<Int(rect.maxY * Self.scale) where y >= 0 && y < image.pixelsHigh {
            for x in Int(rect.minX * Self.scale)..<Int(rect.maxX * Self.scale) where x >= 0 && x < image.pixelsWide {
                let offset = y * image.bytesPerRow + x * stride
                let have = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
                if zip(have, want).allSatisfy({ abs($0 - $1) <= 4 }) { return true }
            }
        }
        return false
    }
}
