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
        let entries: [HarnessEntry]
        let capture: (TerminalStandIn) -> Void

        var body: some View {
            ZStack {
                Terminal(capture: capture)
                PaneLauncherOverlay(theme: Theme.builtins[0], entries: entries, onLaunch: { _ in })
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

    private func hostProbe(entries: [HarnessEntry]) async throws -> HostedProbe {
        var captured: TerminalStandIn?
        let hosting = NSHostingView(rootView: Probe(entries: entries, capture: { captured = $0 }))
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
