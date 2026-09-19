import AppKit
import FlockCore
import SwiftUI
import XCTest

/// `ChatSubviewHeader`'s two icon buttons used to hit-test only the drawn
/// symbol's own vector outline (`Image(systemName:)` inside a plain
/// `Button`, no `.contentShape`), so a click anywhere in the button's own
/// padded box that missed the glyph's stroke fell through to whatever sat
/// behind the popover. Proved the same way `PaneLauncherOverlayTests`
/// proves its own buttons: a stand-in view behind the header, and AppKit
/// `hitTest` at a point inside the button's box but off the glyph itself.
@MainActor
final class ChatSubviewHeaderHitTestTests: XCTestCase {
    private final class BehindStandIn: NSView {}

    private struct Behind: NSViewRepresentable {
        let capture: (BehindStandIn) -> Void

        func makeNSView(context: Context) -> BehindStandIn {
            let view = BehindStandIn()
            capture(view)
            return view
        }

        func updateNSView(_ nsView: BehindStandIn, context: Context) {}
    }

    private struct Probe: View {
        static let width: CGFloat = ChromeMetrics.ChatPeek.width
        let capture: (BehindStandIn) -> Void

        var body: some View {
            ZStack(alignment: .topLeading) {
                Behind(capture: capture)
                ChatSubviewHeader(theme: .tokyoNight, title: "Chat peek", width: Self.width, onBack: {}, onClose: {})
            }
            .frame(width: Self.width, height: ChromeMetrics.ChatSubviewHeader.height)
        }
    }

    /// The header's own vertical padding leaves this much room for its
    /// buttons; recomputed here (rather than read off a hit-box constant)
    /// so this test proves the fix by geometry that predates it too.
    private var laneHeight: CGFloat {
        ChromeMetrics.ChatSubviewHeader.height - 2 * ChromeMetrics.ChatSubviewHeader.verticalPadding
    }

    func testAClickNearTheTopOfEitherButtonsBoxLandsOnTheButtonNotWhatsBehindIt() async throws {
        var behind: BehindStandIn?
        let hosting = NSHostingView(rootView: Probe(capture: { behind = $0 }))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Probe.width, height: ChromeMetrics.ChatSubviewHeader.height)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        defer { window.close() }
        let behindView = try XCTUnwrap(behind)

        func hitTest(_ point: CGPoint) -> NSView? {
            hosting.hitTest(hosting.convert(point, to: hosting.superview))
        }

        // A sliver just inside the top of each button's own padded lane --
        // above where a 14pt glyph centered in that lane actually draws
        // ink, so only an enlarged, rectangular hit target claims it.
        let sliverY = ChromeMetrics.ChatSubviewHeader.verticalPadding + 0.3
        let backPoint = CGPoint(
            x: ChromeMetrics.ChatSubviewHeader.horizontalPadding + laneHeight / 2, y: sliverY
        )
        let closePoint = CGPoint(
            x: Probe.width - ChromeMetrics.ChatSubviewHeader.horizontalPadding - laneHeight / 2, y: sliverY
        )

        XCTAssertNotEqual(hitTest(backPoint), behindView, "back chevron's own padding fell through to what sits behind the header")
        XCTAssertNotEqual(hitTest(closePoint), behindView, "close button's own padding fell through to what sits behind the header")
    }
}
