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
        var flashedSlot: String?
        /// The frosted bar the start screen and empty pins use, in place of
        /// the strip.
        var showsBar = false
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
                if showsBar {
                    LauncherBar(
                        style: LauncherBarStyle(theme: theme), slots: LauncherSlots.ordered(navigator: navigator, entries: entries),
                        showsShortcuts: true, onLaunch: { _ in }
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if !showsBar {
                    PaneLauncherOverlay(
                        theme: theme, entries: entries, navigator: navigator, flashedSlot: flashedSlot, onLaunch: { _ in }
                    )
                }
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

        // The regions the strip draws in or sits beside but must never
        // swallow: the terminal's body, and the band past its items.
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

        let runs = probe.runs(in: probe.pointsClaimedByTheOverlay())
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertLessThan(run.upperBound - run.lowerBound, 120, "the hint beside it took clicks")
    }

    /// A pane too narrow for the names keeps every item in reach as a keycap,
    /// and the gaps between them still reach the terminal.
    func testAPaneTooNarrowForTheNamesKeepsEveryKeycap() async throws {
        let width: CGFloat = 170
        let probe = try await hostProbe(
            entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, size: CGSize(width: width, height: 300)
        )
        defer { probe.window.close() }

        let y = Probe.size.height - ChromeMetrics.LauncherStrip.height / 2
        var runs = 0
        var claiming = false
        for x in stride(from: CGFloat(0), to: width, by: 0.5) {
            let claims = probe.hitTest(CGPoint(x: x, y: y)) !== probe.terminal
            if claims, !claiming { runs += 1 }
            claiming = claims
        }
        XCTAssertEqual(runs, 3, "one clickable run per item, with gaps between")
        XCTAssertFalse(claiming, "the last item ran off the pane's edge")
    }

    /// rt's own pink on its plum ground on the frosted bar, in a dark and a
    /// light theme. Writes both PNGs when `FLOCK_CHROME_RENDER_DIR` names a
    /// directory.
    func testTheRtBadgeWearsRtsColorsInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let probe = try await hostProbe(entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, showsBar: true)
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

    /// A pane wide enough for the items carries each one's keycap, with no
    /// title to confuse the measure; a narrower one drops them before it cuts
    /// off a name. Writes both PNGs when
    /// `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testAWidePaneShowsEachItemsKeycapInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let wide = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, size: CGSize(width: 420, height: 300)
            )
            defer { wide.window.close() }
            let narrow = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, size: CGSize(width: 230, height: 300)
            )
            defer { narrow.window.close() }

            let image = try snapshot(wide.window)
            write(image, named: "launcher-strip-keycaps-\(theme.id).png")
            XCTAssertGreaterThan(
                stripContentWidth(image), stripContentWidth(try snapshot(narrow.window)) + 60,
                "\(theme.id): the wide strip should be wider by the three keycaps"
            )
        }
    }

    /// The marks are compiled path data, not bundled images, so this render is
    /// the whole proof that they draw: the same code and colors the app runs.
    /// Writes the PNG when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testBothVendorMarksPaintTheirOwnInk() async throws {
        let probe = try await hostProbe(entries: HarnessRoster.known, showsBar: true)
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

    /// Pixels across the strip's middle row that are not the band, from the
    /// first to the last.
    private func stripContentWidth(_ image: NSBitmapImageRep) -> Int {
        let scale = image.pixelsHigh / Int(Probe.size.height)
        let y = image.pixelsHigh - Int(ChromeMetrics.LauncherStrip.height / 2) * scale
        let band = hex(image, x: 2, y: y)
        let inked = (0..<image.pixelsWide).filter { hex(image, x: $0, y: y) != band }
        guard let first = inked.first, let last = inked.last else { return 0 }
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
                ("the terminal's top", CGPoint(x: Probe.size.width / 2, y: 6)),
                ("the terminal's body", CGPoint(x: Probe.size.width / 2, y: Probe.size.height / 2)),
                ("the band past its items", CGPoint(x: Probe.size.width - 10, y: Probe.size.height - 14)),
            ]
        }
    }

    /// The strip runs edge to edge along the pane's bottom, and no taller
    /// than its own height claims a click.
    func testTheStripSitsOnThePanesBottomEdge() async throws {
        let probe = try await hostProbe(entries: Self.entries)
        defer { probe.window.close() }

        let band = probe.pointsClaimedByTheOverlay().reduce(into: CGRect.null) {
            $0 = $0.union(CGRect(origin: $1, size: .zero))
        }
        XCTAssertGreaterThanOrEqual(band.minY, Probe.size.height - ChromeMetrics.LauncherStrip.height, "above the strip: \(band)")
        XCTAssertGreaterThan(band.maxY, Probe.size.height - ChromeMetrics.LauncherStrip.height / 2 - 2, "off the bottom edge: \(band)")

        let image = try snapshot(probe.window)
        let scale = image.pixelsHigh / Int(Probe.size.height)
        let terminal = hex(image, x: 2, y: 2)
        let bottom = image.pixelsHigh - 2 * scale
        XCTAssertNotEqual(hex(image, x: 2, y: bottom), terminal, "the band does not reach the left edge")
        XCTAssertNotEqual(hex(image, x: image.pixelsWide - 3, y: bottom), terminal, "the band does not reach the right edge")
    }

    /// A pane wide enough for the title shows it, and the title and its
    /// divider still let a click through to the terminal. Writes the PNGs
    /// when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testTheTitleTakesNoClicksInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let wide = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, size: CGSize(width: 720, height: 300)
            )
            defer { wide.window.close() }
            let bare = try await hostProbe(entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme)
            defer { bare.window.close() }

            let image = try snapshot(wide.window)
            write(image, named: "launcher-strip-title-\(theme.id).png")
            let y = Probe.size.height - ChromeMetrics.LauncherStrip.height / 2
            XCTAssertTrue(wide.hitTest(CGPoint(x: 60, y: y)) === wide.terminal, "\(theme.id): the title took a click")
            XCTAssertFalse(bare.hitTest(CGPoint(x: 26, y: y)) === bare.terminal, "\(theme.id): no title, and the first key answers here")
            XCTAssertGreaterThan(
                stripContentWidth(image), stripContentWidth(try snapshot(bare.window)) + 100,
                "\(theme.id): the wide strip should be wider by the title"
            )
        }
    }

    /// The strip stands aside once the screen reaches it, rather than hiding
    /// the prompt and the cursor on the last rows.
    func testTheStripOnlyShowsWhenThePromptStaysClearOfIt() {
        XCTAssertTrue(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: 2, gridRows: 40, surfaceHeight: 720))

        let rowHeight: CGFloat = 18
        let clearRows = Int((720 - PaneLauncherOverlay.coveredHeight) / rowHeight) - 1
        XCTAssertTrue(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: clearRows, gridRows: 40, surfaceHeight: 720), "the last row that clears it")
        XCTAssertFalse(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: clearRows + 1, gridRows: 40, surfaceHeight: 720), "one row more")
        XCTAssertFalse(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: 22, gridRows: 22, surfaceHeight: 396), "a banner filling the pane")
        XCTAssertFalse(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: 1, gridRows: 2, surfaceHeight: 36), "a two-row pane")
        XCTAssertFalse(PaneLauncherOverlay.leavesPromptVisible(occupiedRows: 0, gridRows: 0, surfaceHeight: 0), "no grid yet")
    }

    /// A banner reaching the bottom of the pane must not run through the
    /// items: the band reads the same with text behind it as with none.
    func testTheBandHidesABannerBehindIt() async throws {
        let clean = try await hostProbe(entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd)
        defer { clean.window.close() }
        let banner = try await hostProbe(
            entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, occupiedRows: 22, cellHeight: 18, paintsRows: true
        )
        defer { banner.window.close() }

        let bare = try snapshot(clean.window)
        let covered = try snapshot(banner.window)
        let scale = bare.pixelsHigh / Int(Probe.size.height)
        for y in stride(from: bare.pixelsHigh - Int(ChromeMetrics.LauncherStrip.height) * scale, to: bare.pixelsHigh, by: scale) {
            for x in stride(from: 0, to: bare.pixelsWide, by: scale) {
                XCTAssertEqual(hex(covered, x: x, y: y), hex(bare, x: x, y: y), "banner text shows through at \(x),\(y)")
            }
        }
        write(covered, named: "launcher-strip-banner.png")
    }

    /// A ⌘ digit flashes the item it fired. The flash is the only sign a key
    /// press gives, and it must change the item without moving anything.
    /// Writes the PNGs when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testAFlashLightsItsItemWithoutMovingAnythingInDarkAndLightThemes() async throws {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let rest = try await hostProbe(entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme)
            defer { rest.window.close() }
            let flashed = try await hostProbe(
                entries: HarnessRoster.known, navigator: NavigatorRoster.rtCd, theme: theme, flashedSlot: "claude"
            )
            defer { flashed.window.close() }

            let claimed = rest.pointsClaimedByTheOverlay()
            let runs = rest.runs(in: claimed)
            XCTAssertEqual(flashed.runs(in: flashed.pointsClaimedByTheOverlay()), runs, "\(theme.id): the flash moved an item")

            let quiet = try snapshot(rest.window)
            let lit = try snapshot(flashed.window)
            write(quiet, named: "launcher-strip-rest-\(theme.id).png")
            write(lit, named: "launcher-strip-flash-\(theme.id).png")

            let scale = quiet.pixelsHigh / Int(Probe.size.height)
            let y = quiet.pixelsHigh - Int(ChromeMetrics.LauncherStrip.height / 2) * scale
            func changed(in run: ClosedRange<CGFloat>) -> Int {
                (Int(run.lowerBound) * scale..<Int(run.upperBound) * scale).filter { hex(quiet, x: $0, y: y) != hex(lit, x: $0, y: y) }.count
            }
            XCTAssertGreaterThan(changed(in: runs[1]), 0, "\(theme.id): the flashed item did not light up")
            XCTAssertEqual(changed(in: runs[0]), 0, "\(theme.id): the flash lit rt cd")
            XCTAssertEqual(changed(in: runs[2]), 0, "\(theme.id): the flash lit codex")
        }
    }

    private func write(_ image: NSBitmapImageRep, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        XCTAssertNoThrow(try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url))
    }

    private func hostProbe(
        entries: [HarnessEntry], navigator: HarnessEntry? = nil, theme: Theme = Theme.builtins[0], size: CGSize = Probe.size,
        occupiedRows: Int = 0, cellHeight: CGFloat? = nil, paintsRows: Bool = false, flashedSlot: String? = nil,
        showsBar: Bool = false
    ) async throws -> HostedProbe {
        ChromeType.install()
        var captured: TerminalStandIn?
        let hosting = NSHostingView(rootView: Probe(
            size: size, theme: theme, entries: entries, navigator: navigator,
            occupiedRows: occupiedRows, cellHeight: cellHeight, paintsRows: paintsRows, flashedSlot: flashedSlot,
            showsBar: showsBar, capture: { captured = $0 }
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

/// A key has three strengths of one treatment, and the strip has to stay
/// readable on every theme flock ships, not only the two it was drawn on.
@MainActor
final class LauncherStripStyleTests: XCTestCase {
    func testRestHoverAndPressAreThreeDifferentKeys() {
        for theme in [Theme(.tokyoNight), Theme(.tokyoNightDay)] {
            let style = LauncherStripStyle(theme: theme)
            let states: [LauncherStripStyle.KeyState] = [.rest, .hovered, .pressed]
            XCTAssertEqual(Set(states.map(style.keyFill)).count, 3, "\(theme.id): the key's fill must step")
            XCTAssertEqual(Set(states.map(style.keyEdge)).count, 3, "\(theme.id): the key's edge must step")
            XCTAssertNotEqual(style.text(.rest), style.text(.hovered), "\(theme.id): hovering must brighten the text")
        }
    }

    func testRestingTextStaysReadableOnEveryBuiltinTheme() {
        func contrast(_ a: RGB, _ b: RGB) -> Double {
            let (x, y) = (a.relativeLuminance, b.relativeLuminance)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for theme in Theme.builtins {
            let style = LauncherStripStyle(theme: theme)
            XCTAssertGreaterThanOrEqual(
                contrast(style.inkTone, style.bandTone), 4.5, "\(theme.id): resting text is too faint on the band"
            )
            typealias M = ChromeMetrics.LauncherStrip
            let key = style.bandTone.mixed(with: RGB(255, 255, 255), amount: (style.isDark ? M.darkKeyFill : M.lightKeyFill)[0])
            XCTAssertGreaterThanOrEqual(contrast(style.inkTone, key), 4.5, "\(theme.id): resting text is too faint on a key")
        }
    }
}
