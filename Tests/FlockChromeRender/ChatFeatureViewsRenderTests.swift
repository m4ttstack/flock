import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Peek, Quick send and Broadcast: the three feature sub-views behind the
/// chat popover's chevrons. Geometry is measured with `previewX`-seeded
/// state and `fittingHeight` (no window, no live store), the same way
/// `ChromeRenderTests` measures `ChatPopover`'s own bands. Hex sampling and
/// symbol resolution render through a real window against a fixture
/// `ChatStore`, so the async `.task` fetch that populates each view in
/// production actually runs here too. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set.
@MainActor
final class ChatFeatureViewsRenderTests: XCTestCase {
    private static let theme = Theme.tokyoNight

    // MARK: - Fixture data

    /// claude/codex/kay/scout, exactly `measurements.md`'s own reference
    /// set, plus #rt/#flock -- what the geometry tests cross-check their
    /// named totals against.
    private static let cleanPeekJSON = #"""
    {"buddies":[
        {"handle":"claude","paneId":"w1:p1","status":"working","repo":"acme","branch":"docs","title":null,"unread":2,"mentions":0},
        {"handle":"codex","paneId":"w1:p2","status":"idle","repo":"repo-tools","branch":"server","title":null,"unread":0,"mentions":0},
        {"handle":"kay","paneId":"w1:p3","status":"done","repo":"flock","branch":"phase-0","title":null,"unread":0,"mentions":0},
        {"handle":"scout","paneId":"w1:p4","status":"blocked","repo":"glance","branch":"main","title":null,"unread":5,"mentions":0}
    ],"rooms":[
        {"room":"#rt","unread":3,"mentions":0},
        {"room":"#flock","unread":0,"mentions":0}
    ]}
    """#

    /// The clean set plus a fifth buddy whose status is not one of chat's
    /// own live words -- the one pane, in both Peek and Broadcast, that
    /// exercises the "not signed in" dot colour and the disabled checkbox.
    private static let peekJSONWithGhost = #"""
    {"buddies":[
        {"handle":"claude","paneId":"w1:p1","status":"working","repo":"acme","branch":"docs","title":null,"unread":2,"mentions":0},
        {"handle":"codex","paneId":"w1:p2","status":"idle","repo":"repo-tools","branch":"server","title":null,"unread":0,"mentions":0},
        {"handle":"kay","paneId":"w1:p3","status":"done","repo":"flock","branch":"phase-0","title":null,"unread":0,"mentions":0},
        {"handle":"scout","paneId":"w1:p4","status":"blocked","repo":"glance","branch":"main","title":null,"unread":5,"mentions":0},
        {"handle":"ghost","paneId":"w1:p5","status":"offline","repo":null,"branch":null,"title":"away","unread":0,"mentions":0}
    ],"rooms":[
        {"room":"#rt","unread":3,"mentions":0},
        {"room":"#flock","unread":0,"mentions":0}
    ]}
    """#

    private static let targetsJSON = #"""
    {"rooms":["#rt","#flock"],"people":["@scout","@codex"]}
    """#

    private static func decodePeek(_ json: String) -> ChatPeek {
        try! JSONDecoder().decode(ChatPeek.self, from: Data(json.utf8))
    }

    // MARK: - Peek: geometry

    func testChatPeekViewMatchesItsMeasuredSizeAndBandHeights() {
        let peek = Self.decodePeek(Self.cleanPeekJSON)
        let view = ChatPeekView(theme: Self.theme, onBack: {}, onClose: {}, onJump: { _ in }, previewPeek: peek)

        XCTAssertEqual(fittingHeight(ChatSubviewHeader(theme: Self.theme, title: "Chat peek", width: ChromeMetrics.ChatPeek.width, onBack: {}, onClose: {})), ChromeMetrics.ChatPopover.Header.height)
        XCTAssertEqual(fittingHeight(view.label("PANES ON CHAT")), ChromeMetrics.ChatPeek.Label.height)
        XCTAssertEqual(fittingHeight(view.paneRow(peek.buddies[0])), ChromeMetrics.ChatPeek.PaneRow.height)
        XCTAssertEqual(fittingHeight(view.roomRow(peek.rooms[0], isFirst: true)), ChromeMetrics.ChatPeek.RoomRow.firstHeight)
        XCTAssertEqual(fittingHeight(view.roomRow(peek.rooms[1], isFirst: false)), ChromeMetrics.ChatPeek.RoomRow.subsequentHeight)
        XCTAssertEqual(fittingWidth(view), ChromeMetrics.ChatPeek.width)
        XCTAssertEqual(fittingHeight(view), ChromeMetrics.ChatPeek.height, "the whole view must sum to measurements.md's own 326 total")
    }

    // MARK: - Peek: hex samples

    /// Every distinct surface Peek paints: the ground, the header rule, a
    /// filled row (unread) beside an unfilled one, all five dot colours
    /// (including the not-signed-in fallback), and both an unread pill on a
    /// pane row and one on a room row.
    func testChatPeekViewPaintsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Self.theme
        let store = await makeChatStore(peekJSON: Self.peekJSONWithGhost, targetsJSON: Self.targetsJSON)
        let view = ChatPeekView(theme: theme, onBack: {}, onClose: {}, onJump: { _ in })
        let window = hostWindow(view, chatStore: store, size: CGSize(width: ChromeMetrics.ChatPeek.width, height: 400))
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try writePNG(image, to: directory, name: "chat-peek.png")
        }

        XCTAssertEqual(hex(image, CGPoint(x: 300, y: 10)), theme.palette.panelBg.hex, "ground")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 40.5)), theme.palette.surface0.hex, "header rule")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 93)), theme.palette.activeRowBg.hex, "claude row (unread) is filled")
        XCTAssertEqual(hex(image, CGPoint(x: 17.5, y: 93)), theme.palette.yellow.hex, "claude dot: working")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 135)), theme.palette.panelBg.hex, "codex row (no unread) is unfilled")
        XCTAssertEqual(hex(image, CGPoint(x: 17.5, y: 135)), theme.palette.green.hex, "codex dot: idle")
        XCTAssertEqual(hex(image, CGPoint(x: 17.5, y: 177)), theme.palette.accent.hex, "kay dot: done")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 219)), theme.palette.activeRowBg.hex, "scout row (unread) is filled")
        XCTAssertEqual(hex(image, CGPoint(x: 17.5, y: 219)), theme.palette.red.hex, "scout dot: blocked")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 261)), theme.palette.panelBg.hex, "ghost row (not signed in) is unfilled")
        XCTAssertEqual(hex(image, CGPoint(x: 17.5, y: 261)), theme.palette.overlay0.hex, "ghost dot: not signed in falls back to overlay0")
        XCTAssertEqual(hex(image, CGPoint(x: 309, y: 93)), theme.palette.accent.hex, "claude's unread pill")
        XCTAssertEqual(hex(image, CGPoint(x: 309, y: 219)), theme.palette.accent.hex, "scout's unread pill")
        XCTAssertEqual(hex(image, CGPoint(x: 330, y: 327)), theme.palette.accent.hex, "#rt room's unread pill")
        window.close()
    }

    func testChatPeekViewSymbolsResolve() {
        for symbolName in ["chevron.left", "xmark", "arrow.turn.up.right"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil), symbolName)
        }
    }

    // MARK: - Shared header: both glyphs read the same colour

    /// The back chevron and the close X sit in the same header at the same
    /// size and the same `foregroundStyle`; a hex sample (not a look at a
    /// scaled screenshot) is what actually proves neither one is drawing in
    /// some other tone. `xmark`'s outline covers more of a square box than
    /// `chevron.left`'s does at the same point size, which is a weight
    /// difference worth guarding against too -- this only asserts colour;
    /// `ChatSubviewHeader`'s own font-sized (not `.resizable()`) rendering is
    /// what keeps the two visually matched in weight. Resting colour is
    /// `subtext0`, not `overlay0`: at this icon's size `overlay0` on
    /// `panelBg` reads as barely there.
    func testChatSubviewHeaderGlyphsAreBothExactlySubtext0AtRest() async throws {
        let theme = Self.theme
        let header = ChatSubviewHeader(theme: theme, title: "Chat peek", width: ChromeMetrics.ChatPeek.width, onBack: {}, onClose: {})
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 60), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) { header }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        await settle(window)
        let image = try snapshot(window)

        let chevronDistance = closestDistance(image, xRange: 12...30, yRange: 10...31, target: theme.palette.subtext0.hex)
        let closeDistance = closestDistance(image, xRange: ChromeMetrics.ChatPeek.width - 30...ChromeMetrics.ChatPeek.width - 12, yRange: 10...31, target: theme.palette.subtext0.hex)
        XCTAssertLessThanOrEqual(chevronDistance, 2, "back chevron is not subtext0 (closest off by \(chevronDistance))")
        XCTAssertLessThanOrEqual(closeDistance, 2, "close glyph is not subtext0 (closest off by \(closeDistance))")
        window.close()
    }

    // MARK: - Quick send: geometry

    func testChatQuickSendViewMatchesItsMeasuredSizeAndBandHeights() {
        let status = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: [])
        let view = ChatQuickSendView(theme: Self.theme, status: status, onBack: {}, onClose: {}, previewTargets: ["#rt", "#flock", "@scout"])

        XCTAssertEqual(fittingHeight(ChatSubviewHeader(theme: Self.theme, title: "Quick send", width: ChromeMetrics.ChatQuickSend.width, onBack: {}, onClose: {})), ChromeMetrics.ChatPopover.Header.height)
        XCTAssertEqual(fittingHeight(view.targetBand), ChromeMetrics.ChatQuickSend.TargetBand.height)
        XCTAssertEqual(fittingHeight(view.fieldBand), ChromeMetrics.ChatQuickSend.FieldBand.height)
        XCTAssertEqual(fittingWidth(view), ChromeMetrics.ChatQuickSend.width)
        XCTAssertEqual(fittingHeight(view), ChromeMetrics.ChatQuickSend.height, "the whole view must sum to measurements.md's own 234 total")
    }

    // MARK: - Quick send: hex samples

    /// The ground, the header rule, the field's `accent` stroke, the send
    /// button's `accent` fill, and -- since a chip's own width is text-driven
    /// rather than a fixed metric -- a region scan proving the selected chip
    /// fills `accent` and an unselected one fills `surface0` somewhere in the
    /// target row, rather than asserting either at a hand-picked point.
    func testChatQuickSendViewPaintsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Self.theme
        let store = await makeChatStore(peekJSON: Self.cleanPeekJSON, targetsJSON: Self.targetsJSON)
        let status = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: [])
        let view = ChatQuickSendView(theme: theme, status: status, onBack: {}, onClose: {})
        let window = hostWindow(view, chatStore: store, size: CGSize(width: ChromeMetrics.ChatQuickSend.width, height: ChromeMetrics.ChatQuickSend.height))
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try writePNG(image, to: directory, name: "chat-quick-send.png")
        }

        XCTAssertEqual(hex(image, CGPoint(x: 300, y: 10)), theme.palette.panelBg.hex, "ground")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 40.5)), theme.palette.surface0.hex, "header rule")
        XCTAssertTrue(
            regionContainsHex(image, xRange: 14...346, yRange: 54...94, target: theme.palette.accent.hex),
            "no accent chip fill found in the target row -- the selected chip did not draw"
        )
        XCTAssertTrue(
            regionContainsHex(image, xRange: 14...346, yRange: 54...94, target: theme.palette.surface0.hex),
            "no surface0 chip fill found in the target row -- an unselected chip did not draw"
        )
        XCTAssertEqual(hex(image, CGPoint(x: 180, y: 108.5)), theme.palette.accent.hex, "field stroke")
        XCTAssertEqual(hex(image, CGPoint(x: 268, y: 205.5)), theme.palette.accent.hex, "send button fills accent")
        window.close()
    }

    func testChatQuickSendViewSymbolsResolve() {
        for symbolName in ["chevron.left", "xmark"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil), symbolName)
        }
    }

    // MARK: - Broadcast: geometry

    func testChatBroadcastViewMatchesItsMeasuredSizeAndBandHeights() {
        let peek = Self.decodePeek(Self.cleanPeekJSON)
        let view = ChatBroadcastView(theme: Self.theme, onBack: {}, onClose: {}, previewBuddies: peek.buddies)

        XCTAssertEqual(fittingHeight(ChatSubviewHeader(theme: Self.theme, title: "Broadcast to panes", width: ChromeMetrics.ChatBroadcast.width, onBack: {}, onClose: {})), ChromeMetrics.ChatPopover.Header.height)
        XCTAssertEqual(fittingHeight(view.selectHead), ChromeMetrics.ChatBroadcast.SelectHead.height)
        XCTAssertEqual(fittingHeight(view.paneRow(peek.buddies[0])), ChromeMetrics.ChatBroadcast.PaneRow.height)
        XCTAssertEqual(fittingHeight(view.fieldBand), ChromeMetrics.ChatBroadcast.FieldBand.height)
        XCTAssertEqual(fittingWidth(view), ChromeMetrics.ChatBroadcast.width)
        XCTAssertEqual(fittingHeight(view), ChromeMetrics.ChatBroadcast.height, "the whole view must sum to measurements.md's own 370 total")
    }

    // MARK: - Broadcast: hex samples

    /// The ground, the header and field-band rules, a checked row's fill and
    /// tick, the ghost buddy (an unrecognised status string) checked and
    /// filled the same as every other row, every dot colour, the field's
    /// `accent` stroke, and the send button's `mauve` fill -- the one point
    /// Broadcast and Quick send deliberately differ.
    func testChatBroadcastViewPaintsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Self.theme
        let store = await makeChatStore(peekJSON: Self.peekJSONWithGhost, targetsJSON: Self.targetsJSON)
        let view = ChatBroadcastView(theme: theme, onBack: {}, onClose: {})
        let window = hostWindow(view, chatStore: store, size: CGSize(width: ChromeMetrics.ChatBroadcast.width, height: 420))
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try writePNG(image, to: directory, name: "chat-broadcast.png")
        }

        XCTAssertEqual(hex(image, CGPoint(x: 250, y: 10)), theme.palette.panelBg.hex, "ground")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 40.5)), theme.palette.surface0.hex, "header rule")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 93)), theme.palette.activeRowBg.hex, "claude row (checked) is filled")
        XCTAssertEqual(hex(image, CGPoint(x: 21.5, y: 93)), theme.palette.accent.hex, "claude checkbox: checked fill")
        XCTAssertEqual(hex(image, CGPoint(x: 42.5, y: 93)), theme.palette.yellow.hex, "claude dot: working")
        XCTAssertEqual(hex(image, CGPoint(x: 42.5, y: 135)), theme.palette.green.hex, "codex dot: idle")
        XCTAssertEqual(hex(image, CGPoint(x: 42.5, y: 177)), theme.palette.accent.hex, "kay dot: done")
        XCTAssertEqual(hex(image, CGPoint(x: 42.5, y: 219)), theme.palette.red.hex, "scout dot: blocked")
        // A buddy `peek` reports is on chat by definition, whatever its
        // agent-status string says, so the ghost row starts checked and
        // filled exactly like every other row -- only its dot colour reads
        // `status` at all.
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 261)), theme.palette.activeRowBg.hex, "ghost row is selectable and starts checked, so it is filled")
        XCTAssertEqual(hex(image, CGPoint(x: 21.5, y: 261)), theme.palette.accent.hex, "ghost checkbox starts checked like any other pane")
        let ghostDot = hex(image, CGPoint(x: 42.5, y: 261))
        let candidates: [(String, RGB)] = [
            ("yellow", theme.palette.yellow), ("green", theme.palette.green), ("accent", theme.palette.accent),
            ("red", theme.palette.red), ("overlay0", theme.palette.overlay0),
        ]
        let closest = candidates.min { channelDistance(ghostDot, $0.1.hex) < channelDistance(ghostDot, $1.1.hex) }
        XCTAssertEqual(closest?.0, "overlay0", "ghost dot: not signed in falls back to overlay0, closest was \(closest?.0 ?? "?")")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 282.5)), theme.palette.surface0.hex, "field-band rule")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 296.5)), theme.palette.accent.hex, "field stroke")
        XCTAssertEqual(hex(image, CGPoint(x: 278, y: 383.5)), theme.palette.mauve.hex, "send button fills mauve, not accent")
        window.close()
    }

    func testChatBroadcastViewSymbolsResolve() {
        for symbolName in ["chevron.left", "xmark", "checkmark"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil), symbolName)
        }
    }

    // MARK: - Shared harness

    private func makeChatStore(peekJSON: String, targetsJSON: String) async -> ChatStore {
        let store = ChatStore(
            toasts: ToastCenter(),
            probe: { "/usr/bin/true" }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in FeatureFixtureChatRunning(peekJSON: peekJSON, targetsJSON: targetsJSON) }
        )
        await store.probeTask.value
        return store
    }

    /// Every feature view relies on `ChatPopover`'s own shared background,
    /// stroke and clip (never painting its own), since production always
    /// hosts it inside that wrapper -- reproduced here so a standalone render
    /// samples the same ground `ChatPopover` would actually show it against.
    private func hostWindow(_ view: some View, chatStore: ChatStore, size: CGSize) -> NSWindow {
        let theme = Self.theme
        let chrome = view
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius).fill(Color(theme.palette.panelBg)))
            .overlay(
                RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius)
                    .strokeBorder(Color(theme.palette.surface1), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) { chrome }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(chatStore)
                .environment(ToastCenter())
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// An unavailable-chat store: `.task` resolves to nothing, harmlessly,
    /// so a geometry check can host a whole view (its `.task` included)
    /// without a real fixture -- only the environment slot needs filling.
    private func makeInertChatStore() -> ChatStore {
        ChatStore(toasts: ToastCenter(), probe: { nil }, rtProbe: { true }, deckProbe: { true })
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func snapshot(_ window: NSWindow, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView?.superview)
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

    /// Whether `target` appears anywhere in the box -- for the one place a
    /// child's exact position is text-driven (a quick-send chip's width)
    /// rather than a fixed metric, so presence is what a test can prove.
    private func channelDistance(_ lhs: String, _ rhs: String) -> Int {
        func channels(_ hex: String) -> [Int] {
            let digits = Array(hex.dropFirst())
            return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
        }
        return zip(channels(lhs), channels(rhs)).map { abs($0 - $1) }.max() ?? 0
    }

    /// The smallest `channelDistance` to `target` found anywhere in the box
    /// -- for a glyph small enough that no single pixel reaches full
    /// coverage, this is what "this icon is drawn in this colour" has to
    /// mean, the same tolerance `ChromeRenderTests`'s own icon checks use.
    private func closestDistance(
        _ image: NSBitmapImageRep, xRange: ClosedRange<CGFloat>, yRange: ClosedRange<CGFloat>, target: String, step: CGFloat = 0.5
    ) -> Int {
        var best = Int.max
        var y = yRange.lowerBound
        while y <= yRange.upperBound {
            var x = xRange.lowerBound
            while x <= xRange.upperBound {
                best = min(best, channelDistance(hex(image, CGPoint(x: x, y: y)), target))
                x += step
            }
            y += step
        }
        return best
    }

    private func regionContainsHex(
        _ image: NSBitmapImageRep, xRange: ClosedRange<CGFloat>, yRange: ClosedRange<CGFloat>, target: String, step: CGFloat = 1
    ) -> Bool {
        var y = yRange.lowerBound
        while y <= yRange.upperBound {
            var x = xRange.lowerBound
            while x <= xRange.upperBound {
                if hex(image, CGPoint(x: x, y: y)) == target { return true }
                x += step
            }
            y += step
        }
        return false
    }

    private func writePNG(_ image: NSBitmapImageRep, to directory: String, name: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A plain SwiftUI view's own ideal size, with no window and no
    /// snapshot: what `.frame(width:)`/`.frame(height:)` declares is what
    /// this reports, so a band's constant and its actually-laid-out size can
    /// never quietly disagree.
    /// `.task` fires even on this bare, windowless host, so every one of
    /// these views (each carrying its own fetch) needs a `ChatStore` in the
    /// environment or it crashes -- an inert one, since a band's declared
    /// size never depends on what that fetch answers.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.environment(makeInertChatStore()).environment(ToastCenter()))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func fittingWidth(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.environment(makeInertChatStore()).environment(ToastCenter()))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }
}

/// Answers `peek` and `targets` with canned JSON; any other verb is not
/// something rendering these views ever asks for (Quick send/Broadcast only
/// send on a button tap, never on appear).
private actor FeatureFixtureChatRunning: ChatRunning {
    private let peekJSON: String
    private let targetsJSON: String

    init(peekJSON: String, targetsJSON: String) {
        self.peekJSON = peekJSON
        self.targetsJSON = targetsJSON
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        switch verb {
        case .peek: return (Data(peekJSON.utf8), 0)
        case .targets: return (Data(targetsJSON.utf8), 0)
        default: throw ChatFailure(message: "FeatureFixtureChatRunning has no canned response for \(verb)")
        }
    }
}
