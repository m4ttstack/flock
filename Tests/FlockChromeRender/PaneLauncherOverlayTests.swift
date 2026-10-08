import AppKit
import FlockCore
import SwiftUI
import XCTest

/// The launcher overlay's two halves of one contract, asserted through real
/// AppKit hit testing rather than by reading the view's modifiers: the
/// buttons answer a click, and every other point in the overlay lets the
/// click through to the terminal underneath.
///
/// Disabling hit testing on a container around the buttons satisfies the
/// second half and silently breaks the first, which is what shipped once:
/// a disabled ancestor takes its whole subtree out of hit testing, and the
/// `.allowsHitTesting(true)` the button row carried could not opt back in.
@MainActor
final class PaneLauncherOverlayTests: XCTestCase {
    /// What the overlay is drawn over. A point that hit-tests to this is a
    /// point the terminal would have received.
    private final class TerminalStandIn: NSView {}

    private struct Terminal: NSViewRepresentable {
        let capture: (TerminalStandIn) -> Void

        func makeNSView(context: Context) -> TerminalStandIn {
            let view = TerminalStandIn()
            capture(view)
            return view
        }

        func updateNSView(_ nsView: TerminalStandIn, context: Context) {}
    }

    private struct Probe: View {
        static let size = CGSize(width: 420, height: 300)
        var size = Self.size
        let theme: Theme
        let entries: [HarnessEntry]
        let navigator: HarnessEntry?
        var occupiedRows = 0
        var cellHeight: CGFloat?
        /// Paints `occupiedRows` lines of text where a terminal would, for
        /// renders a person looks at. Off for tests that sample the ground.
        var paintsRows = false
        let capture: (TerminalStandIn) -> Void

        var body: some View {
            ZStack {
                theme.terminalGround
                Terminal(capture: capture)
                if paintsRows, let cellHeight {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<occupiedRows, id: \.self) { row in
                            Text(row == occupiedRows - 1 ? "~/src/acme $" : "acme banner line \(row + 1)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(theme.textStrong)
                                .frame(height: cellHeight, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 6)
                    // A fixed, clipped frame: rows past the pane's bottom must
                    // not grow the stack the overlay measures.
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(false)
                }
                PaneLauncherOverlay(
                    theme: theme, entries: entries, navigator: navigator,
                    occupiedRows: occupiedRows, cellHeight: cellHeight, onLaunch: { _ in }
                )
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private static let entries = [
        HarnessEntry(id: "claude", binary: "claude", displayName: "claude", monogram: "C", monogramColor: .orange),
        HarnessEntry(id: "codex", binary: "codex", displayName: "codex", monogram: "X", monogramColor: .blue),
    ]

    func testTheButtonsTakeClicksAndEverywhereElseFallsThroughToTheTerminal() async throws {
        let probe = try await hostProbe(entries: Self.entries)
        defer { probe.window.close() }

        let claimed = probe.pointsClaimedByTheOverlay()
        XCTAssertFalse(claimed.isEmpty, "no point in the overlay answers a click, so neither button can be pressed")

        // One horizontal band, and both buttons in it: a single run would mean
        // only one entry is reachable.
        let band = claimed.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
        XCTAssertLessThan(band.height, 80, "the clickable region is taller than a button row: \(band)")
        XCTAssertLessThan(band.width, Probe.size.width - 80, "the clickable region spans the overlay: \(band)")
        XCTAssertEqual(probe.runs(in: claimed).count, Self.entries.count, "one clickable run per harness button")

        // The regions the overlay draws in but must never swallow: the prompt
        // it deliberately clears at the top, the hint it prints at the bottom,
        // and the empty space beside the buttons.
        for (name, point) in probe.passThroughProbePoints() {
            XCTAssertTrue(probe.hitTest(point) === probe.terminal, "\(name) at \(point) never reached the terminal")
        }
    }

    /// A machine with no harness on PATH renders the overlay with no buttons
    /// at all, and it must then be wholly transparent to the pointer.
    func testAnOverlayWithNoHarnessesClaimsNothing() async throws {
        let probe = try await hostProbe(entries: [])
        defer { probe.window.close() }

        let claimed = probe.pointsClaimedByTheOverlay()
        let box = claimed.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
        XCTAssertEqual(claimed.count, 0, "an empty launcher still eats clicks, over \(box)")
    }

    func testTheRtCdButtonIsAClickableRunOfItsOwn() async throws {
        let probe = try await hostProbe(entries: Self.entries, navigator: NavigatorRoster.rtCd)
        defer { probe.window.close() }

        let claimed = probe.pointsClaimedByTheOverlay()
        XCTAssertEqual(probe.runs(in: claimed).count, Self.entries.count + 1, "rt cd plus one run per harness")
        for (name, point) in probe.passThroughProbePoints() {
            XCTAssertTrue(probe.hitTest(point) === probe.terminal, "\(name) at \(point) never reached the terminal")
        }
    }

    /// rt on PATH with no agent CLI: the one button still has to be offered.
    func testTheRtCdButtonStandsAloneWithNoHarnesses() async throws {
        let probe = try await hostProbe(entries: [], navigator: NavigatorRoster.rtCd)
        defer { probe.window.close() }

        XCTAssertEqual(probe.runs(in: probe.pointsClaimedByTheOverlay()).count, 1)
    }

    /// rt's own pink on its plum ground, in a dark and a light theme. Writes
    /// both PNGs when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testTheRtBadgeWearsRtsColorsInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let probe = try await hostProbe(entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme)
            defer { probe.window.close() }

            let image = try snapshot(probe.window, scale: 4)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("launcher-rt-cd-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }

            var counts: [String: Int] = [:]
            var pink = 0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    counts[hex(image, x: x, y: y), default: 0] += 1
                    if isNear(image, x: x, y: y, to: (0xFF, 0x6B, 0x9D)) { pink += 1 }
                }
            }
            XCTAssertGreaterThan(counts["#161224", default: 0], 400, "\(theme.id): the badge's plum ground is not on screen")
            // Near, not exact: the 18pt badge's letters are thin enough that
            // the offscreen text raster leaves no pixel wholly inside a stroke.
            XCTAssertGreaterThan(pink, 20, "\(theme.id): the badge's pink letters are not on screen")
        }
    }

    /// A pane wide enough for the bar carries each item's ⌘ digit; a 300pt
    /// pane is the narrow case that drops them. Writes both PNGs when
    /// `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testAWidePaneShowsEachButtonsShortcutInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let wide = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, size: CGSize(width: 720, height: 300)
            )
            defer { wide.window.close() }
            let narrow = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, size: CGSize(width: 300, height: 300)
            )
            defer { narrow.window.close() }

            let image = try snapshot(wide.window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("launcher-shortcuts-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            XCTAssertGreaterThan(
                buttonRowWidth(image), buttonRowWidth(try snapshot(narrow.window)) + 60,
                "\(theme.id): the wide row should be wider by the three hints"
            )
        }
    }

    /// The marks are compiled path data, not bundled images, so this render is
    /// the whole proof that they draw: the same code and colors the app runs.
    /// Writes the PNG when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testBothVendorMarksPaintTheirOwnInk() async throws {
        let probe = try await hostProbe(entries: HarnessRoster.known)
        defer { probe.window.close() }

        // At 2x the Blossom's lines on an 18pt badge are thinner than a
        // pixel, so almost none is exactly its white.
        let image = try snapshot(probe.window, scale: 4)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("launcher-marks.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }

        var counts: [String: Int] = [:]
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                counts[hex(image, x: x, y: y), default: 0] += 1
            }
        }
        // Each mark's own fill, on its black disc. A badge whose path failed
        // to decode would leave the disc and nothing else.
        XCTAssertGreaterThan(counts["#D97757", default: 0], 40, "the Claude mark's ink is not on screen")
        XCTAssertGreaterThan(counts["#FFFFFF", default: 0], 40, "the Blossom's ink is not on screen")
        XCTAssertGreaterThan(counts["#000000", default: 0], 400, "neither badge drew its ground")
    }

    // MARK: - Helpers

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the colors the marks declare.
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

    /// Pixels across the band the buttons sit in that are not the terminal
    /// ground, from the first to the last.
    private func buttonRowWidth(_ image: NSBitmapImageRep) -> Int {
        let ground = hex(image, x: 2, y: 2)
        var xs: [Int] = []
        for y in stride(from: image.pixelsHigh / 2 - 20, through: image.pixelsHigh / 2 + 40, by: 10) {
            xs += (0..<image.pixelsWide).filter { hex(image, x: $0, y: y) != ground }
        }
        guard let first = xs.min(), let last = xs.max() else { return 0 }
        return last - first
    }

    /// Within 24 of `target` on every channel: close enough to take in a
    /// thin stroke's anti-aliased core, far enough to leave out the Claude
    /// mark's orange beside the pink.
    private func isNear(_ image: NSBitmapImageRep, x: Int, y: Int, to target: (Int, Int, Int)) -> Bool {
        guard let data = image.bitmapData else { return false }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        let tolerance = 24
        return abs(Int(data[offset]) - target.0) <= tolerance
            && abs(Int(data[offset + 1]) - target.1) <= tolerance
            && abs(Int(data[offset + 2]) - target.2) <= tolerance
    }

    private func hex(_ image: NSBitmapImageRep, x: Int, y: Int) -> String {
        guard let data = image.bitmapData else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    private struct HostedProbe {
        let window: NSWindow
        let hosting: NSHostingView<Probe>
        let terminal: TerminalStandIn

        func hitTest(_ point: CGPoint) -> NSView? {
            hosting.hitTest(hosting.convert(point, to: hosting.superview))
        }

        /// Every probed point the overlay itself answers. SwiftUI draws the
        /// buttons into the hosting view rather than into subviews of their
        /// own, so "the hosting view answered" is exactly "SwiftUI content
        /// claimed this point"; the terminal is a real `NSView` subview and
        /// answers for itself.
        func pointsClaimedByTheOverlay() -> [CGPoint] {
            var claimed: [CGPoint] = []
            for y in stride(from: CGFloat(2), to: Probe.size.height, by: 2) {
                for x in stride(from: CGFloat(2), to: Probe.size.width, by: 2) {
                    let point = CGPoint(x: x, y: y)
                    if hitTest(point) !== terminal { claimed.append(point) }
                }
            }
            return claimed
        }

        /// The clickable runs across the middle of the claimed band, one per
        /// item. Scanned at half a point rather than read off the 2pt grid:
        /// the items sit 2pt apart, which a 2pt grid steps straight over.
        func runs(in claimed: [CGPoint]) -> [ClosedRange<CGFloat>] {
            let band = claimed.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
            guard !band.isNull else { return [] }
            let step: CGFloat = 0.5
            var runs: [ClosedRange<CGFloat>] = []
            for x in stride(from: CGFloat(0), to: Probe.size.width, by: step)
            where hitTest(CGPoint(x: x, y: band.midY)) !== terminal {
                if let last = runs.last, x - last.upperBound <= step {
                    runs[runs.count - 1] = last.lowerBound...x
                } else {
                    runs.append(x...x)
                }
            }
            return runs
        }

        func passThroughProbePoints() -> [(String, CGPoint)] {
            [
                ("top left", CGPoint(x: 6, y: 6)),
                ("top right", CGPoint(x: Probe.size.width - 6, y: 6)),
                ("bottom left", CGPoint(x: 6, y: Probe.size.height - 6)),
                ("bottom right", CGPoint(x: Probe.size.width - 6, y: Probe.size.height - 6)),
                ("the prompt clearance", CGPoint(x: Probe.size.width / 2, y: 6)),
                ("the hint line", CGPoint(x: Probe.size.width / 2, y: Probe.size.height - 14)),
                ("beside the buttons", CGPoint(x: 10, y: Probe.size.height / 2)),
            ]
        }
    }

    /// The clearance follows the rows the screen holds: one row of breathing
    /// room above a four-row prompt at an 18pt cell is 90pt, and nothing on
    /// the overlay may answer a click inside it.
    func testTheClearanceFollowsTheOccupiedRows() async throws {
        XCTAssertEqual(PaneLauncherOverlay.promptClearance(occupiedRows: 4, cellHeight: 18), 90)
        XCTAssertEqual(
            PaneLauncherOverlay.promptClearance(occupiedRows: 0, cellHeight: 18),
            ChromeMetrics.Launcher.promptClearance,
            "never less than the fixed clearance"
        )
        XCTAssertEqual(
            PaneLauncherOverlay.promptClearance(occupiedRows: 4, cellHeight: nil),
            ChromeMetrics.Launcher.promptClearance,
            "no cell size yet: the fixed clearance"
        )

        let probe = try await hostProbe(entries: Self.entries, occupiedRows: 4, cellHeight: 18)
        defer { probe.window.close() }
        for y in stride(from: CGFloat(4), to: 90, by: 8) {
            XCTAssertTrue(probe.hitTest(CGPoint(x: Probe.size.width / 2, y: y)) === probe.terminal, "an item sits inside the clearance at y=\(y)")
        }
        XCTAssertFalse(probe.pointsClaimedByTheOverlay().isEmpty, "the items still draw below the clearance")
    }

    /// Room below the prompt for the bar and 12pt either side: the bar is
    /// centered in that room, clear of the prompt.
    func testTheBarCentersBelowThePromptWhenItFitsThere() {
        let bar = ChromeMetrics.Launcher.barHeight
        XCTAssertEqual(PaneLauncherOverlay.barTop(clearance: 90, availableHeight: 300, barHeight: 40), 175)

        let snug = 90 + bar + 2 * ChromeMetrics.Launcher.barMargin
        XCTAssertEqual(
            PaneLauncherOverlay.barTop(clearance: 90, availableHeight: snug, barHeight: bar),
            90 + ChromeMetrics.Launcher.barMargin,
            "exactly enough room still sits below the prompt"
        )
    }

    /// Too little room below the prompt: the bar centers in the whole pane,
    /// over the text, rather than squeezing against the prompt or the bottom.
    func testTheBarCentersInThePaneWhenThePromptLeavesNoRoom() {
        let bar = ChromeMetrics.Launcher.barHeight
        let short = 90 + bar + 2 * ChromeMetrics.Launcher.barMargin - 1
        XCTAssertEqual(PaneLauncherOverlay.barTop(clearance: 90, availableHeight: short, barHeight: bar), (short - bar) / 2)
        XCTAssertEqual(
            PaneLauncherOverlay.barTop(clearance: 414, availableHeight: 300, barHeight: 40), 130,
            "a banner taller than the pane"
        )
        XCTAssertEqual(
            PaneLauncherOverlay.barTop(clearance: 28, availableHeight: 20, barHeight: 40), 0,
            "a pane shorter than the bar keeps its top edge on the pane"
        )
    }

    /// A four-row prompt in a dark and a light theme. Writes both PNGs when
    /// `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testAFourRowPromptKeepsTheButtonsBelowItInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let probe = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, occupiedRows: 4, cellHeight: 18
            )
            defer { probe.window.close() }
            let image = try snapshot(probe.window)
            write(image, named: "launcher-four-rows-\(theme.id).png")
            let ground = hex(image, x: 2, y: 2)
            let scale = image.pixelsWide / Int(Probe.size.width)
            for y in stride(from: 4, to: 90 * scale, by: 16) {
                XCTAssertEqual(hex(image, x: image.pixelsWide / 2, y: y), ground, "\(theme.id): something drew inside the clearance at y=\(y)")
            }
            // The bar centers in what the clearance leaves.
            let rowCenter = (90 + (Int(Probe.size.height) - 90) / 2) * scale
            XCTAssertTrue(
                (0..<image.pixelsWide).contains { hex(image, x: $0, y: rowCenter) != ground },
                "\(theme.id): nothing drew across the bar at y=\(rowCenter)"
            )
        }
    }

    /// 22 rows of startup banner at an 18pt cell would want 414pt of
    /// clearance; on a 300pt pane the bar centers in the pane, over the text,
    /// with every item still clickable.
    func testABannerTallerThanThePaneCentersTheBarInThePane() async throws {
        let probe = try await hostProbe(entries: Self.entries, occupiedRows: 22, cellHeight: 18)
        defer { probe.window.close() }
        let claimed = probe.pointsClaimedByTheOverlay()
        XCTAssertEqual(probe.runs(in: claimed).count, Self.entries.count, "every item is clickable inside the pane")
        let band = claimed.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
        XCTAssertLessThan(band.maxY, Probe.size.height, "the items run off the bottom: \(band)")
        XCTAssertGreaterThan(band.height, ChromeMetrics.Launcher.itemHeight - 8, "the items are cut off: \(band)")
        XCTAssertEqual(band.midY, Probe.size.height / 2, accuracy: 3, "the bar is not centered in the pane: \(band)")
    }

    /// A two-row prompt, and a 22-row banner on a short pane, in a dark and
    /// a light theme. Writes the PNGs when `FLOCK_CHROME_RENDER_DIR` names a
    /// directory.
    func testTwoRowAndShortBannerRendersInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            for (name, rows) in [("two-rows", 2), ("banner-short", 22)] {
                let probe = try await hostProbe(
                    entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme,
                    occupiedRows: rows, cellHeight: 18, paintsRows: true
                )
                defer { probe.window.close() }
                let image = try snapshot(probe.window)
                write(image, named: "launcher-\(name)-\(theme.id).png")
                let claimed = probe.pointsClaimedByTheOverlay()
                XCTAssertEqual(probe.runs(in: claimed).count, 3, "\(theme.id) \(name): rt cd and both harnesses stay clickable")
                let band = claimed.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
                XCTAssertGreaterThan(
                    band.height, ChromeMetrics.Launcher.itemHeight - 8, "\(theme.id) \(name): the items are cut off: \(band)"
                )
            }
        }
    }

    private func write(_ image: NSBitmapImageRep, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        XCTAssertNoThrow(try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url))
    }

    private func hostProbe(
        entries: [HarnessEntry], navigator: HarnessEntry? = nil, theme: Theme = Theme.builtins[0], size: CGSize = Probe.size,
        occupiedRows: Int = 0, cellHeight: CGFloat? = nil, paintsRows: Bool = false
    ) async throws -> HostedProbe {
        ChromeType.install()
        var captured: TerminalStandIn?
        let hosting = NSHostingView(rootView: Probe(
            size: size, theme: theme, entries: entries, navigator: navigator,
            occupiedRows: occupiedRows, cellHeight: cellHeight, paintsRows: paintsRows, capture: { captured = $0 }
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return HostedProbe(window: window, hosting: hosting, terminal: try XCTUnwrap(captured, "the stand-in terminal never reached the window"))
    }
}

/// The rt cd button is offered on exactly the machines where rt resolves on
/// the PATH flock resolved at startup.
final class NavigatorRosterTests: XCTestCase {
    func testOfferedOnlyWhenRtResolvesOnThePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(NavigatorRoster.detected(pathEnvironment: directory.path))

        let rt = directory.appendingPathComponent("rt")
        try Data("#!/bin/sh\n".utf8).write(to: rt)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rt.path)

        XCTAssertEqual(NavigatorRoster.detected(pathEnvironment: directory.path), NavigatorRoster.rtCd)
    }
}

/// An item has no fill at rest, so hover and press are the only feedback it
/// gives: each state has to be visibly different from the other two, in a
/// dark and a light theme.
///
/// Asserted on the resolved fill rather than on pixels because
/// `ButtonStyle.Configuration` cannot be constructed by a test and no test can
/// move a real pointer over the view.
@MainActor
final class LauncherBarStyleTests: XCTestCase {
    private let themes = [Theme(.tokyoNight), Theme(.tokyoNightDay)]

    func testRestHoverAndPressAreThreeDifferentFills() {
        for theme in themes {
            let style = LauncherBarStyle(theme: theme)
            let rest = style.itemFill(isHovering: false, isPressed: false)
            let hovered = style.itemFill(isHovering: true, isPressed: false)
            let pressed = style.itemFill(isHovering: true, isPressed: true)
            XCTAssertEqual(rest, .clear, "\(theme.id): an item at rest has no fill")
            XCTAssertNotEqual(rest, hovered, "\(theme.id): hovering an item must change how it is drawn")
            XCTAssertNotEqual(hovered, pressed, "\(theme.id): pressing a hovered item must change how it is drawn")
        }
    }

    /// A press can begin without a hover ever being recorded (a click landing
    /// as the overlay appears under a stationary pointer), and it still has to
    /// light up rather than stay at rest.
    func testAPressWithoutHoverStillLightsTheItem() {
        let style = LauncherBarStyle(theme: themes[0])
        XCTAssertEqual(
            style.itemFill(isHovering: false, isPressed: true), style.itemFill(isHovering: true, isPressed: true)
        )
    }

    func testDarkAndLightThemesAreToldApartByThePanel() {
        XCTAssertTrue(LauncherBarStyle(theme: Theme(.tokyoNight)).isDark)
        XCTAssertFalse(LauncherBarStyle(theme: Theme(.tokyoNightDay)).isDark)
    }
}
