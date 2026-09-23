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
        let theme: Theme
        let entries: [HarnessEntry]
        let navigator: HarnessEntry?
        let capture: (TerminalStandIn) -> Void

        var body: some View {
            ZStack {
                theme.terminalGround
                Terminal(capture: capture)
                PaneLauncherOverlay(
                    theme: theme, entries: entries, navigator: navigator,
                    onLaunch: { _ in }, onNavigate: {}
                )
            }
            .frame(width: Self.size.width, height: Self.size.height)
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

            let image = try snapshot(probe.window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"], !directory.isEmpty {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("launcher-rt-cd-\(theme.id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }

            var counts: [String: Int] = [:]
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    counts[hex(image, x: x, y: y), default: 0] += 1
                }
            }
            XCTAssertGreaterThan(counts["#161224", default: 0], 400, "\(theme.id): the badge's plum ground is not on screen")
            XCTAssertGreaterThan(counts["#FF6B9D", default: 0], 20, "\(theme.id): the badge's pink letters are not on screen")
        }
    }

    /// The marks are compiled path data, not bundled images, so this render is
    /// the whole proof that they draw: the same code and colors the app runs.
    /// Writes the PNG when `FLOCK_CHROME_RENDER_DIR` names a directory.
    func testBothVendorMarksPaintTheirOwnInk() async throws {
        let probe = try await hostProbe(entries: HarnessRoster.known)
        defer { probe.window.close() }

        let image = try snapshot(probe.window)
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

        /// The claimed points grouped into horizontal runs, one per button.
        func runs(in claimed: [CGPoint]) -> [ClosedRange<CGFloat>] {
            let xs = Set(claimed.map(\.x)).sorted()
            var runs: [ClosedRange<CGFloat>] = []
            for x in xs {
                if let last = runs.last, x - last.upperBound <= 4 {
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

    private func hostProbe(
        entries: [HarnessEntry], navigator: HarnessEntry? = nil, theme: Theme = Theme.builtins[0]
    ) async throws -> HostedProbe {
        ChromeType.install()
        var captured: TerminalStandIn?
        let hosting = NSHostingView(rootView: Probe(
            theme: theme, entries: entries, navigator: navigator, capture: { captured = $0 }
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Probe.size),
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

/// These buttons shipped on `.plain`, which paints rest, hover and press
/// identically: putting the pointer on one or clicking it changed nothing on
/// screen, so it read as a label rather than a control. Each state has to be
/// visibly different from the other two.
///
/// Asserted on the resolved appearance rather than on pixels because
/// `ButtonStyle.Configuration` cannot be constructed by a test and no test can
/// move a real pointer over the view, which is why the flat version had no
/// failing test to begin with.
@MainActor
final class LauncherButtonAppearanceTests: XCTestCase {
    private let theme = Theme.builtins[0]

    private var rest: LauncherButtonAppearance {
        LauncherButtonAppearance.resolve(theme: theme, isHovering: false, isPressed: false)
    }

    private var hovered: LauncherButtonAppearance {
        LauncherButtonAppearance.resolve(theme: theme, isHovering: true, isPressed: false)
    }

    private var pressed: LauncherButtonAppearance {
        LauncherButtonAppearance.resolve(theme: theme, isHovering: true, isPressed: true)
    }

    func testRestHoverAndPressAreThreeDifferentAppearances() {
        XCTAssertNotEqual(rest, hovered, "hovering a launcher button must change how it is drawn")
        XCTAssertNotEqual(hovered, pressed, "pressing a hovered launcher button must change how it is drawn")
        XCTAssertNotEqual(rest, pressed)
    }

    /// Both halves move together, so a later edit cannot satisfy the test
    /// above by moving one of them and leaving the button still reading flat.
    func testHoverMovesBothTheFillAndTheBorder() {
        XCTAssertNotEqual(rest.fill, hovered.fill)
        XCTAssertNotEqual(rest.border, hovered.border)
    }

    func testOnlyAPressWashesAccentOverTheFillAndShrinksTheButton() {
        XCTAssertEqual(rest.pressWash, 0)
        XCTAssertEqual(hovered.pressWash, 0)
        XCTAssertGreaterThan(pressed.pressWash, 0)

        XCTAssertEqual(rest.scale, 1)
        XCTAssertEqual(hovered.scale, 1)
        XCTAssertLessThan(pressed.scale, 1)
    }

    /// A press can begin without a hover ever being recorded (a click landing
    /// as the overlay appears under a stationary pointer), and it still has to
    /// light up rather than stay at rest colours.
    func testAPressWithoutHoverStillLightsTheButton() {
        let pressedCold = LauncherButtonAppearance.resolve(theme: theme, isHovering: false, isPressed: true)

        XCTAssertEqual(pressedCold.fill, hovered.fill)
        XCTAssertGreaterThan(pressedCold.pressWash, 0)
    }
}
