import AppKit
import FlockCore
import SwiftUI
import XCTest

/// The legend's rt control in every state it draws, and the popover it opens,
/// in a dark and a light theme. rt's own plum and pink are the same in every
/// theme, so they are counted by exact hex; the palette surfaces are sampled
/// against the theme they came from. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class RtButtonRenderTests: XCTestCase {
    private static let themes = [Theme(.tokyoNight), Theme(.tokyoNightDay)]
    private static let plum = "#161224"
    private static let pink = "#FF6B9D"
    private static let pane = PaneID(rawValue: "w1:p1")
    /// Where a hosted view's top-left corner sits in its window, so the
    /// rounded corners and the outer stroke draw against a ground.
    private static let inset: CGFloat = 10

    private static let states: [(name: String, appearance: RtButtonModel.Appearance)] = [
        ("rest", .rest),
        ("count", .active(count: 1, runner: false)),
        ("count-runner", .active(count: 1, runner: true)),
        ("runner", .active(count: 0, runner: true)),
        ("absent", .absent),
    ]

    private var directory: String? {
        ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The badge is in every state but `.absent`; rt's pink glyph is right of
    /// the badge only while the pane has a runner. The badge's own letters
    /// are pink too, which is why the glyph is counted past the badge's edge.
    func testEveryStateButAbsentDrawsTheBadgeAndOnlyARunnerDrawsTheGlyph() async throws {
        ChromeType.install()
        for theme in Self.themes {
            for state in Self.states {
                let button = RtButton(
                    theme: theme, paneID: Self.pane, appearance: state.appearance,
                    onOpenPopover: {}, onShowRunner: {}
                )
                let window = host(button, theme: theme, size: CGSize(width: 90, height: 38))
                await settle(window)
                let image = try snapshot(window)
                try write(image, "rt-button-\(state.name)-\(theme.id).png")
                window.close()

                let plumXs = pixels(in: image) { $0 == Self.plum }.map(\.x)
                let label = "\(theme.id) \(state.name)"
                guard state.appearance != .absent else {
                    XCTAssertEqual(plumXs.count, 0, "\(label): an absent button drew the badge")
                    XCTAssertEqual(pixels(in: image) { self.isPink($0) }.count, 0, "\(label): an absent button drew pink")
                    continue
                }
                XCTAssertGreaterThan(plumXs.count, 150, "\(label): the plum badge is not on screen")
                let badgeEdge = try XCTUnwrap(plumXs.max())
                let glyph = pixels(in: image) { self.isPink($0) }.filter { $0.x > badgeEdge }
                if case .active(_, true) = state.appearance {
                    XCTAssertGreaterThan(glyph.count, 10, "\(label): the runner glyph is not drawn in rt's pink")
                } else {
                    XCTAssertEqual(glyph.count, 0, "\(label): pink right of the badge with no runner")
                }
            }
        }
    }

    /// The pill's two halves meet at the divider with no dead strip between
    /// them: every point across the pill's middle row answers one of the two
    /// closures, the badge half left of the divider and the runner half from
    /// it on.
    func testTheTwoHalvesOfThePillSplitAtTheDividerWithNoDeadStrip() async throws {
        ChromeType.install()
        let theme = Theme(.tokyoNight)
        var fired: [String] = []
        let button = RtButton(
            theme: theme, paneID: Self.pane, appearance: .active(count: 1, runner: true),
            onOpenPopover: { fired.append("popover") }, onShowRunner: { fired.append("runner") }
        )
        let window = host(button, theme: theme, size: CGSize(width: 90, height: 38))
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        defer { window.close() }
        let image = try snapshot(window)

        let midY = Self.inset + ChromeMetrics.RtButton.activeHeight / 2
        let fill = theme.palette.selectionBg.hex
        let pillMin = try XCTUnwrap(firstX(image, y: midY, from: 0, to: 90) { $0 == fill }, "no pill on screen")
        let pillMax = try XCTUnwrap(lastX(image, y: midY, from: 0, to: 90) { $0 == fill })
        let divider = try XCTUnwrap(
            firstX(image, y: midY, from: pillMin + 20, to: pillMax) { $0 == theme.palette.overlay0.hex },
            "no divider on screen"
        )

        for x in stride(from: pillMin + 1, through: pillMax - 1, by: 1) {
            fired = []
            click(window, at: CGPoint(x: x, y: midY))
            await settle(window, passes: 1)
            let expected = x < divider ? "popover" : "runner"
            XCTAssertEqual(fired, [expected], "a click at x \(x) (divider at \(divider))")
        }
    }

    /// The popover as the approved design draws it: four commands with the
    /// first hovered, a running and a finished item under RUNS, the folder
    /// with home as `~`. Its window's appearance follows the theme, so the
    /// popover's own arrow matches its panel.
    func testThePopoverDrawsItsGroundBadgeHoveredRowAndRuns() async throws {
        ChromeType.install()
        for theme in Self.themes {
            let popover = RtPopover(
                theme: theme, folder: "~/src/acme",
                commands: RtPopoverModel.commands(hasRunner: true),
                runs: [
                    RtRunRow(id: "a", title: "pnpm run test", state: "running", tone: .running),
                    RtRunRow(id: "b", title: "pnpm run build", state: "finished · exit 0", tone: .finished),
                ],
                onCommand: { _ in }, onRun: { _ in }, previewHoveredCommand: .nav
            )
            let window = host(popover, theme: theme, size: CGSize(width: 320, height: 300))
            await settle(window)
            let image = try snapshot(window)
            try write(image, "rt-popover-\(theme.id).png")
            window.close()

            let label = theme.id
            let palette = theme.palette
            let expectedAppearance: NSAppearance.Name = ChromeRoles.isLight(panelBg: palette.panelBg) ? .aqua : .darkAqua
            XCTAssertEqual(window.appearance?.name, expectedAppearance, "\(label): the popover's window appearance")
            XCTAssertEqual(hex(image, at: point(150, 20)), palette.panelBg.hex, "\(label): the popover's ground")
            XCTAssertEqual(hex(image, at: point(0.5, 100)), palette.surface1.hex, "\(label): the outer stroke")
            XCTAssertEqual(hex(image, at: point(150, 40.5)), palette.surface0.hex, "\(label): the header rule")
            XCTAssertEqual(hex(image, at: point(16, 15)), Self.plum, "\(label): the header badge")
            XCTAssertEqual(hex(image, at: point(180, 50)), palette.selectionBg.hex, "\(label): the hovered row's fill")
            XCTAssertEqual(hex(image, at: point(180, 81)), palette.panelBg.hex, "\(label): a row not hovered has no fill")
            XCTAssertEqual(hex(image, at: point(180, 208)), palette.activeRowBg.hex, "\(label): the running item's fill")
            XCTAssertEqual(hex(image, at: point(180, 239)), palette.panelBg.hex, "\(label): a finished item has no fill")
            XCTAssertEqual(hex(image, at: point(150, 272)), palette.panelBg.hex, "\(label): the runs band's bottom padding")
            XCTAssertNotEqual(hex(image, at: point(150, 276)), palette.panelBg.hex, "\(label): the popover runs past its runs")
        }
    }

    /// RUNS and its band are there only while the pane has rt run items.
    func testThePopoverWithNoRunsEndsAfterItsCommands() async throws {
        ChromeType.install()
        let theme = Theme(.tokyoNight)
        let popover = RtPopover(
            theme: theme, folder: "~", commands: RtPopoverModel.commands(hasRunner: false), runs: [],
            onCommand: { _ in }, onRun: { _ in }
        )
        let hosting = NSHostingView(rootView: popover)
        hosting.layoutSubtreeIfNeeded()
        let commands = ChromeMetrics.RtPopover.Commands.self
        XCTAssertEqual(
            hosting.fittingSize.height,
            ChromeMetrics.RtPopover.Header.height + 2 * commands.verticalPadding + 4 * ChromeMetrics.RtPopover.Row.height
        )
        XCTAssertEqual(hosting.fittingSize.width, ChromeMetrics.RtPopover.width)
    }

    /// A misspelt symbol name draws nothing, with no error.
    func testEverySymbolTheButtonAndThePopoverNameResolves() {
        for name in ["folder", "arrow.triangle.branch", "play", "waveform.path.ecg"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    // MARK: - Helpers

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: Self.inset + x, y: Self.inset + y)
    }

    private func isPink(_ hex: String) -> Bool {
        channelDistance(hex, Self.pink) <= 24
    }

    /// Hosts `view` at `inset` from the top-left of a borderless window over
    /// the pane's own ground, which is what the legend sits on.
    private func host(_ view: some View, theme: Theme, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                theme.pane
                view.padding(.leading, Self.inset).padding(.top, Self.inset)
            }
            .frame(width: size.width, height: size.height)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow, passes: Int = 6) async {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A press and a release at `point`, top-left in the window's content.
    private func click(_ window: NSWindow, at point: CGPoint) {
        let height = window.contentView?.bounds.height ?? 0
        let location = NSPoint(x: point.x, y: height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the declared hexes.
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

    private func write(_ image: NSBitmapImageRep, _ name: String) throws {
        guard let directory else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Pixel coordinates, not points: every pixel of the 2x image whose hex
    /// passes `matches`.
    private func pixels(in image: NSBitmapImageRep, where matches: (String) -> Bool) -> [(x: Int, y: Int)] {
        var found: [(x: Int, y: Int)] = []
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where matches(hex(image, pixelX: x, pixelY: y)) {
                found.append((x, y))
            }
        }
        return found
    }

    private func hex(_ image: NSBitmapImageRep, at point: CGPoint, scale: CGFloat = 2) -> String {
        hex(image, pixelX: Int(point.x * scale), pixelY: Int(point.y * scale))
    }

    private func hex(_ image: NSBitmapImageRep, pixelX x: Int, pixelY y: Int) -> String {
        guard let data = image.bitmapData, x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private func firstX(_ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, where matches: (String) -> Bool) -> CGFloat? {
        stride(from: from, through: to, by: 0.5).first { matches(hex(image, at: CGPoint(x: $0, y: y))) }
    }

    private func lastX(_ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, where matches: (String) -> Bool) -> CGFloat? {
        stride(from: from, through: to, by: 0.5).reversed().first { matches(hex(image, at: CGPoint(x: $0, y: y))) }
    }

    private func channelDistance(_ lhs: String, _ rhs: String) -> Int {
        func channels(_ hex: String) -> [Int] {
            let digits = Array(hex.dropFirst())
            guard digits.count == 6 else { return [Int.max / 4, Int.max / 4, Int.max / 4] }
            return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
        }
        return zip(channels(lhs), channels(rhs)).map { abs($0 - $1) }.max() ?? Int.max
    }
}
