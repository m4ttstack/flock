import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// Renders the real `MainWindow` offscreen from fixture data, with no app host
/// and no herdr connection. Pane bodies are ground-only surfaces, since
/// terminal content is not part of the chrome. PNGs are written only when
/// `FLOCK_CHROME_RENDER_DIR` is set; the pixel and window assertions always
/// run.
@MainActor
final class ChromeRenderTests: XCTestCase {
    static let defaultsSuite = "dev.mattstack.flock.chrome-render"
    private static let windowSize = CGSize(width: 900, height: 560)
    /// The grid's own window. A thumbnail is one fixed width now, so how many
    /// slots a card row holds is the window's answer: 900pt holds three and
    /// every card fixture below is written around the four a 1200pt window
    /// gives. The chrome renders keep `windowSize`, which is what makes them
    /// comparable across rounds.
    private static let gridWindowSize = CGSize(width: 1200, height: 560)
    private static let themeIDs = [
        "tokyo-night", "dracula",
        "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
        "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
    ]

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.defaultsSuite)
        super.tearDown()
    }

    func testEveryChromeRolePaintsItsExactHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in Self.themeIDs {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            assertSamples(image, theme: theme)
            window.close()
        }
    }

    /// The pane legend's chat button, both states it can actually draw: fill
    /// and stroke sampled against the palette by name, and its frame against
    /// the sizes `measurements.md` gives. The button is the only thing in its
    /// pane's legend here (idle, unzoomed), so its box sits flush against the
    /// legend's own padding with nothing else to make room for.
    func testChatButtonRendersSignedInAndSignedOutAtTheirMeasuredSizeAndHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        // rt's own printed handle carries the `@`; the design's own button
        // does not, so the sample below reads "kay" rather than "@kay".
        let signedInJSON = #"""
        {"handle":"@kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
        """#

        let signedIn = try await Harness(theme: theme, chatAvailable: true, chatStatusJSON: [pane: signedInJSON])
        let signedInWindow = signedIn.makeWindow(size: Self.windowSize)
        await settle(signedInWindow)
        let signedInImage = try snapshot(signedInWindow)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chat-button-signed-in.png")
            try XCTUnwrap(signedInImage.representation(using: .png, properties: [:])).write(to: url)
        }
        let signedInBox = try XCTUnwrap(signedIn.drag.canvas.paneFrames[pane])
        let signedInFrame = Self.chatButtonFrame(inRawFrame: signedInBox, size: ChromeMetrics.ChatButton.signedInSize)
        XCTAssertEqual(signedInFrame.size, ChromeMetrics.ChatButton.signedInSize, "signed-in size")
        // Inside the leading padding, ahead of the handle text: the frame's
        // own center sits on the glyph, whose antialiased edge blends fill
        // and text color rather than reading as either.
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: signedInFrame.minX + 3, y: signedInFrame.midY)),
            theme.palette.selectionBg.hex, "signed-in fill"
        )
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: signedInFrame.maxX - 0.5, y: signedInFrame.midY)),
            theme.palette.selectionBg.hex, "signed-in carries no separate stroke"
        )
        // The divider and the glyph, at their own measured offsets past the
        // leading padding and the handle: pad(8) + handle(18) + gap(6) puts
        // the 1pt divider's center at 32.5; + divider(1) + gap(6) puts the
        // 11pt glyph's center at 44.5.
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: signedInFrame.minX + 32.5, y: signedInFrame.midY)),
            theme.palette.surface1.hex, "signed-in divider"
        )
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: signedInFrame.minX + 44.5, y: signedInFrame.midY)),
            theme.palette.green.hex, "signed-in glyph"
        )
        signedInWindow.close()

        let signedOut = try await Harness(theme: theme, chatAvailable: true)
        let signedOutWindow = signedOut.makeWindow(size: Self.windowSize)
        await settle(signedOutWindow)
        let signedOutImage = try snapshot(signedOutWindow)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chat-button-signed-out.png")
            try XCTUnwrap(signedOutImage.representation(using: .png, properties: [:])).write(to: url)
        }
        let signedOutBox = try XCTUnwrap(signedOut.drag.canvas.paneFrames[pane])
        let signedOutFrame = Self.chatButtonFrame(inRawFrame: signedOutBox, size: ChromeMetrics.ChatButton.signedOutSize)
        XCTAssertEqual(signedOutFrame.size, ChromeMetrics.ChatButton.signedOutSize, "signed-out size")
        // Just inside the rounded corner, clear of the centered glyph.
        XCTAssertEqual(
            hex(signedOutImage, CGPoint(x: signedOutFrame.minX + 2, y: signedOutFrame.minY + 2)),
            theme.palette.surface0.hex, "signed-out fill"
        )
        XCTAssertEqual(
            hex(signedOutImage, CGPoint(x: signedOutFrame.maxX - 0.5, y: signedOutFrame.midY)),
            theme.palette.surface0.hex, "signed-out carries no separate stroke"
        )
        signedOutWindow.close()
    }

    /// A machine with no chat binary draws no button: the legend's corner
    /// stays the pane's own ground, not `surface0` or `selectionBg`.
    func testChatButtonIsAbsentWhenChatIsUnavailable() async throws {
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        let harness = try await Harness(theme: theme)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)
        let box = try XCTUnwrap(harness.drag.canvas.paneFrames[pane])
        let frame = Self.chatButtonFrame(inRawFrame: box, size: ChromeMetrics.ChatButton.signedOutSize)
        XCTAssertEqual(
            hex(image, CGPoint(x: frame.midX, y: frame.midY)), theme.palette.chromeRoles.pane.hex,
            "no chat binary drew a button anyway"
        )
        window.close()
    }

    /// A pane already signed in must read that way on first render, with no
    /// popover ever opened: `seedChatStatus: false` withholds the harness's
    /// own direct `refreshStatus` call, so the button's appearance can only
    /// come from whatever production code fetches status on its own. A
    /// button still drawing the muted signed-out glyph here means nothing
    /// but a popover open ever populates `chatStore.status(for:)`.
    func testChatButtonReadsSignedInOnFirstRenderWithNoPopoverEverOpened() async throws {
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        let signedInJSON = #"""
        {"handle":"@kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
        """#
        let harness = try await Harness(
            theme: theme, chatAvailable: true, chatStatusJSON: [pane: signedInJSON], seedChatStatus: false
        )
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)
        let box = try XCTUnwrap(harness.drag.canvas.paneFrames[pane])
        // Every button size shares the same right edge (`chatButtonFrame`'s
        // own `box.maxX - horizontalPadding`), so this trailing-edge sample
        // reads the signed-in box's `selectionBg` fill when it fetched, or the
        // signed-out box's plain `surface0` fill when it did not -- the same
        // point `testChatButtonRendersSignedInAndSignedOutAtTheirMeasuredSizeAndHex`
        // reads for each state on its own.
        let frame = Self.chatButtonFrame(inRawFrame: box, size: ChromeMetrics.ChatButton.signedInSize)
        XCTAssertEqual(
            hex(image, CGPoint(x: frame.maxX - 0.5, y: frame.midY)),
            theme.palette.selectionBg.hex, "signed-in fill absent: the button still reads as signed out"
        )
        window.close()
    }

    /// The Count child, at render level rather than only the model: a
    /// fixture pane carrying both a non-idle agent status (so the status
    /// chip actually draws) and a signed-in chat with unread. Neither
    /// element's exact frame is assumed here -- both are found by scanning the
    /// legend row's own pixels, which is what proves the source order
    /// (`PaneCellView.swift`'s chat button written before `statusColor`)
    /// actually reaches the screen rather than just the compiler.
    func testChatButtonDrawsUnreadAndSitsLeftOfTheStatusDot() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        let signedInJSON = #"""
        {"handle":"@kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
        """#
        let harness = try await Harness(
            theme: theme, model: try Fixture.model(focusedPaneAgentStatus: "working"),
            chatAvailable: true, chatStatusJSON: [pane: signedInJSON], chatUnread: [pane: 3]
        )
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chat-button-signed-in-unread.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
        let box = try XCTUnwrap(harness.drag.canvas.paneFrames[pane])
        let insetBox = PaneBox.frame(in: box, dividerThickness: DividerBand.gutter)
        // The legend row's own vertical center: the chat button is its
        // tallest child (18pt against the status pill's 14), so the row's
        // top is the button's own top, and both center on the same line.
        let legendY = insetBox.minY + PaneChrome.verticalPadding + ChromeMetrics.ChatButton.signedInSize.height / 2
        let scanFrom = insetBox.midX
        let scanTo = insetBox.maxX - PaneChrome.horizontalPadding

        let buttonMaxX = try XCTUnwrap(
            lastX(image, y: legendY, from: scanFrom, to: scanTo, matching: theme.palette.selectionBg.hex),
            "no selectionBg pixel on the legend row -- the chat button did not draw"
        )
        let buttonMinX = buttonMaxX - ChromeMetrics.ChatButton.signedInSize.width
        // pad(8) + handle(18) + gap(6) + divider(1) + gap(6) + icon(11) + gap(6):
        // the count's own slot starts 56pt past the button's own leading edge.
        // A single digit at this size antialiases across its whole slot with
        // no pixel at full coverage (confirmed by dumping the row: the
        // closest sampled pixel to `palette.text` was #B5BEE9, twelve units
        // off in the worst channel, against a plain background over a
        // hundred units off) -- so this takes the CLOSEST pixel in the slot
        // rather than demanding an exact match, the same tolerance the file's
        // own `channelDistance`/`washDither` pattern uses for opacity blends.
        let countSlotStart = buttonMinX + 56
        let countDistance = minChannelDistance(
            image, y: legendY, from: countSlotStart, to: countSlotStart + ChromeMetrics.ChatButton.countSize.width,
            target: theme.palette.text.hex
        )
        XCTAssertLessThanOrEqual(
            countDistance, 20, "no pixel close enough to palette.text in the count's slot (closest off by \(countDistance))"
        )

        let pillMinX = try XCTUnwrap(
            firstX(image, y: legendY, after: buttonMaxX + 2, to: scanTo, notMatching: theme.palette.chromeRoles.pane.hex),
            "no status pill pixel found to the right of the chat button"
        )
        XCTAssertLessThan(buttonMaxX, pillMinX, "the chat button does not sit left of the status dot")
        window.close()
    }

    /// The popover's six bands, isolated from the whole view so each one's
    /// height is read directly rather than inferred from pixel scanning: a
    /// SwiftUI view with an explicit `.frame(height:)` reports that height as
    /// its `NSHostingView.fittingSize`, with no window or snapshot needed.
    /// The sum is cross-checked against the two named totals `measurements.md`
    /// gives, so the per-band constants and the totals can never drift apart.
    func testChatPopoverBandsMatchTheirMeasuredHeights() throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let signedOutStatus = ChatStatus(handle: nil, state: "not signed in", pane: nil, signedIn: false, rooms: [])
        let signedInStatus = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: ["#rt", "#flock"])

        let popover = ChatPopover(
            theme: theme, paneName: "claude", status: signedOutStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        XCTAssertEqual(fittingHeight(popover.header), ChromeMetrics.ChatPopover.Header.height, "header band")
        XCTAssertEqual(fittingHeight(popover.statusBlock), ChromeMetrics.ChatPopover.Status.heightSignedOut, "status band, signed out")
        XCTAssertEqual(fittingHeight(popover.featuresBlock), ChromeMetrics.ChatPopover.Features.bandHeight, "features band")
        XCTAssertEqual(fittingHeight(popover.signButtonsBlock), ChromeMetrics.ChatPopover.SignButtons.bandHeight, "sign buttons band")
        XCTAssertEqual(fittingHeight(popover.statusRoute), ChromeMetrics.ChatPopover.signedOutHeight, "signed-out total")

        let signedInPopover = ChatPopover(
            theme: theme, paneName: "claude", status: signedInStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        XCTAssertEqual(fittingHeight(signedInPopover.statusBlock), ChromeMetrics.ChatPopover.Status.heightSignedIn, "status band, signed in")
        XCTAssertEqual(fittingHeight(signedInPopover.statusRoute), ChromeMetrics.ChatPopover.signedInHeight, "signed-in total")

        XCTAssertEqual(
            ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedOut
                + 2 * ChromeMetrics.ChatPopover.SectionLabel.height + ChromeMetrics.ChatPopover.Features.bandHeight
                + ChromeMetrics.ChatPopover.SignButtons.bandHeight,
            ChromeMetrics.ChatPopover.signedOutHeight, "the six bands must sum to the named signed-out total"
        )
        XCTAssertEqual(
            ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedIn
                + 2 * ChromeMetrics.ChatPopover.SectionLabel.height + ChromeMetrics.ChatPopover.Features.bandHeight
                + ChromeMetrics.ChatPopover.SignButtons.bandHeight,
            ChromeMetrics.ChatPopover.signedInHeight, "the six bands must sum to the named signed-in total"
        )
    }

    /// A sign button centers its own icon-and-label content rather than
    /// left-anchoring it against a literal `.padding()`: the button's fixed
    /// width has to stay equal for both labels regardless of glyph width,
    /// which centering gives and a pinned leading inset does not. What
    /// centering promises, and what the band-height test above cannot see,
    /// is that the content sits with EQUAL clearance on every side -- never
    /// closer than the measured padding, and never nearer one edge than its
    /// opposite. This finds that content block by its own colour against the
    /// button's fill (not by an assumed position) and checks both.
    func testSignButtonContentIsCenteredWithAtLeastItsMeasuredPadding() async throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let signedOutStatus = ChatStatus(handle: nil, state: "not signed in", pane: nil, signedIn: false, rooms: [])
        let popover = ChatPopover(
            theme: theme, paneName: "claude", status: signedOutStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        let window = popoverWindow(popover)
        await settle(window)
        let image = try snapshot(window)

        let bandTop = ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedOut
            + 2 * ChromeMetrics.ChatPopover.SectionLabel.height + ChromeMetrics.ChatPopover.Features.bandHeight
        let buttonHeight = ChromeMetrics.ChatPopover.SignButtons.buttonSize.height
        let buttonWidth = ChromeMetrics.ChatPopover.SignButtons.buttonSize.width
        let primaryLeft = ChromeMetrics.ChatPopover.SignButtons.leadingPadding
        let secondaryLeft = primaryLeft + buttonWidth + ChromeMetrics.ChatPopover.SignButtons.gap
        let minHorizontalMargin = ChromeMetrics.ChatPopover.SignButtons.buttonHorizontalPadding
        let minVerticalMargin = ChromeMetrics.ChatPopover.SignButtons.buttonVerticalPadding

        // Signed out: Sign in is primary (accent fill), Sign out is
        // secondary (surface0 fill); each button's own fill is what
        // "background" means for that button's scan.
        try assertContentCentered(
            image, buttonLeft: primaryLeft, buttonTop: bandTop, width: buttonWidth, height: buttonHeight,
            background: theme.palette.accent.hex, minHorizontalMargin: minHorizontalMargin, minVerticalMargin: minVerticalMargin,
            label: "signed-out Sign in"
        )
        try assertContentCentered(
            image, buttonLeft: secondaryLeft, buttonTop: bandTop, width: buttonWidth, height: buttonHeight,
            background: theme.palette.surface0.hex, minHorizontalMargin: minHorizontalMargin, minVerticalMargin: minVerticalMargin,
            label: "signed-out Sign out"
        )
        window.close()
    }

    /// Brackets a button's icon-and-label content by scanning inward from
    /// each of its four straight edges (never the rounded corners, which can
    /// leak the ground behind the button and read as "content" falsely) for
    /// the first pixel that is not the button's own fill, then asserts the
    /// margin on every side is at least the measured padding and that
    /// opposite margins match -- centered, not merely present.
    private func assertContentCentered(
        _ image: NSBitmapImageRep, buttonLeft: CGFloat, buttonTop: CGFloat, width: CGFloat, height: CGFloat,
        background: String, minHorizontalMargin: CGFloat, minVerticalMargin: CGFloat, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let midY = buttonTop + height / 2
        let midX = buttonLeft + width / 2
        // Inset from the button's own true edges: at the vertical (or
        // horizontal) center a rounded rect's side is dead straight, but the
        // outermost pixel is still antialiased against the ground beyond it,
        // and a secondary button's own 1pt stroke sits just inside that --
        // both would otherwise read as "not background" the same as real
        // content.
        let edgeInset: CGFloat = 2
        let leftMargin = try XCTUnwrap(
            firstX(image, y: midY, after: buttonLeft + edgeInset, to: midX, notMatching: background), "\(label): no content found left of center",
            file: file, line: line
        ) - buttonLeft
        let rightEdge = try XCTUnwrap(
            lastX(image, y: midY, from: midX, to: buttonLeft + width - edgeInset, notMatching: background), "\(label): no content found right of center",
            file: file, line: line
        )
        let rightMargin = (buttonLeft + width) - rightEdge
        let topMargin = try XCTUnwrap(
            firstY(image, x: midX, after: buttonTop + edgeInset, to: midY, notMatching: background), "\(label): no content found above center",
            file: file, line: line
        ) - buttonTop
        let bottomEdge = try XCTUnwrap(
            lastY(image, x: midX, from: midY, to: buttonTop + height - edgeInset, notMatching: background), "\(label): no content found below center",
            file: file, line: line
        )
        let bottomMargin = (buttonTop + height) - bottomEdge

        XCTAssertGreaterThanOrEqual(leftMargin, minHorizontalMargin, "\(label): left margin narrower than the measured padding", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rightMargin, minHorizontalMargin, "\(label): right margin narrower than the measured padding", file: file, line: line)
        XCTAssertGreaterThanOrEqual(topMargin, minVerticalMargin, "\(label): top margin narrower than the measured padding", file: file, line: line)
        XCTAssertGreaterThanOrEqual(bottomMargin, minVerticalMargin, "\(label): bottom margin narrower than the measured padding", file: file, line: line)
        XCTAssertEqual(leftMargin, rightMargin, accuracy: 2, "\(label): content is not horizontally centered", file: file, line: line)
        // A wider tolerance than the horizontal check: a font's line-height
        // box is not symmetric around a glyph's visual center the way an
        // icon's own bounding box is, so a few points of vertical offset is
        // normal typography, not a redistribution bug.
        XCTAssertEqual(topMargin, bottomMargin, accuracy: 5, "\(label): content is not vertically centered", file: file, line: line)
    }

    /// Every distinct surface the popover paints, both states: the ground,
    /// the pane chip, a room chip (signed in only), the hovered/selected
    /// feature row with its accent icon, and both sign buttons -- whichever
    /// one is primary flips between the two states, so both fills are
    /// exercised across the pair. `previewHoveredFeature` seeds Chat peek as
    /// hovered, the same row the approved PNGs show, without a real pointer.
    func testChatPopoverPaintsExactHexSignedOutAndSignedIn() async throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        let signedOutStatus = ChatStatus(handle: nil, state: "not signed in", pane: nil, signedIn: false, rooms: [])
        let signedOutPopover = ChatPopover(
            theme: theme, paneName: "claude", status: signedOutStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}, previewHoveredFeature: .peek
        )
        let signedOutWindow = popoverWindow(signedOutPopover)
        await settle(signedOutWindow)
        let signedOutImage = try snapshot(signedOutWindow)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chat-popover-signed-out.png")
            try XCTUnwrap(signedOutImage.representation(using: .png, properties: [:])).write(to: url)
        }
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 200, y: 20)), theme.palette.panelBg.hex, "signed-out popover ground")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 0.5, y: 150)), theme.palette.surface1.hex, "signed-out outer stroke")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 200, y: 40.5)), theme.palette.surface0.hex, "signed-out header rule")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 200, y: 85.5)), theme.palette.surface0.hex, "signed-out status band rule")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 343, y: 63)), theme.palette.surface0.hex, "signed-out pane chip fill")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 200, y: 165)), theme.palette.selectionBg.hex, "signed-out selected feature row fill")
        var bestIconDistance = Int.max
        for y in stride(from: CGFloat(159), through: 171, by: 0.5) {
            bestIconDistance = min(bestIconDistance, minChannelDistance(signedOutImage, y: y, from: 16, to: 30, target: theme.palette.accent.hex))
        }
        XCTAssertLessThanOrEqual(bestIconDistance, 20, "signed-out selected feature icon (closest off by \(bestIconDistance))")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 30, y: 292.5)), theme.palette.accent.hex, "signed-out Sign in is primary")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 200, y: 292.5)), theme.palette.surface0.hex, "signed-out Sign out is secondary")
        XCTAssertEqual(
            hex(signedOutImage, CGPoint(x: 184.5, y: 292.5)), theme.palette.surface1.hex, "signed-out secondary Sign out stroke"
        )
        signedOutWindow.close()

        let signedInStatus = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: ["#rt", "#flock"])
        let signedInPopover = ChatPopover(
            theme: theme, paneName: "claude", status: signedInStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}, previewHoveredFeature: .peek
        )
        let signedInWindow = popoverWindow(signedInPopover)
        await settle(signedInWindow)
        let signedInImage = try snapshot(signedInWindow)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("chat-popover-signed-in.png")
            try XCTUnwrap(signedInImage.representation(using: .png, properties: [:])).write(to: url)
        }
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 200, y: 20)), theme.palette.panelBg.hex, "signed-in popover ground")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 0.5, y: 150)), theme.palette.surface1.hex, "signed-in outer stroke")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 200, y: 40.5)), theme.palette.surface0.hex, "signed-in header rule")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 200, y: 108.5)), theme.palette.surface0.hex, "signed-in status band rule")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 343, y: 63)), theme.palette.surface0.hex, "signed-in pane chip fill")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 17, y: 87)), theme.palette.activeRowBg.hex, "signed-in room chip fill")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 200, y: 188)), theme.palette.selectionBg.hex, "signed-in selected feature row fill")
        var bestSignedInIconDistance = Int.max
        for y in stride(from: CGFloat(182), through: 194, by: 0.5) {
            bestSignedInIconDistance = min(bestSignedInIconDistance, minChannelDistance(signedInImage, y: y, from: 16, to: 30, target: theme.palette.accent.hex))
        }
        XCTAssertLessThanOrEqual(bestSignedInIconDistance, 20, "signed-in selected feature icon (closest off by \(bestSignedInIconDistance))")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 30, y: 315.5)), theme.palette.surface0.hex, "signed-in Sign in is secondary")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 200, y: 315.5)), theme.palette.accent.hex, "signed-in Sign out is primary")
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: 14.5, y: 315.5)), theme.palette.surface1.hex, "signed-in secondary Sign in stroke"
        )
        signedInWindow.close()
    }

    /// A pane with no status yet is neither signed in nor out: both sign
    /// buttons must read as secondary rather than one being fabricated as
    /// primary from a guessed status.
    func testChatPopoverWithNoStatusYetShowsBothSignButtonsAsSecondary() async throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let popover = ChatPopover(
            theme: theme, paneName: "claude", status: nil, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        let window = popoverWindow(popover)
        await settle(window)
        let image = try snapshot(window)
        XCTAssertEqual(hex(image, CGPoint(x: 30, y: 292.5)), theme.palette.surface0.hex, "Sign in reads secondary with no status yet")
        XCTAssertEqual(hex(image, CGPoint(x: 200, y: 292.5)), theme.palette.surface0.hex, "Sign out reads secondary with no status yet")
        window.close()
    }

    /// Every SF Symbol the popover names, beyond `bubble.left.fill`
    /// (already covered by the chat button's own test): a typo'd name
    /// resolves to nothing, silently, so this is the guard that catches it.
    func testChatPopoverSymbolsResolve() {
        for symbolName in [
            "arrow.up.forward.square", "terminal", "dot.radiowaves.left.and.right", "person.2.fill",
            "paperplane.fill", "rectangle.portrait.and.arrow.forward", "rectangle.portrait.and.arrow.right",
            "chevron.left",
        ] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil), symbolName)
        }
    }

    /// A plain SwiftUI view's own ideal height, with no window and no
    /// snapshot: what `.frame(height:)` declares is what this reports, so a
    /// band's constant and its actually-laid-out height can never quietly
    /// disagree.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// Hosts a standalone view (never `MainWindow`) flush against the
    /// window's own top-left corner, so the sample coordinates below are the
    /// view's own coordinates with no canvas or chrome offset to account for.
    /// Borderless rather than `.titled`: a title bar is itself an opaque
    /// subview AppKit adds to the theme frame, which would paint over the
    /// content's own top band and shift every sample below it.
    private func popoverWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(
            rootView: ZStack(alignment: .topLeading) { view }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Where the chat button lands: `drag.canvas.paneFrames` carries the
    /// UNINSET split rect, and `PaneCanvas` insets it by the divider gutter
    /// before ever handing `PaneCellView` a box (`PaneBox.frame`) -- the same
    /// step the grid geometry tests take through `MiniPaneLayout` instead.
    /// The legend's overlay is then anchored to that box's own top-trailing
    /// corner, inset by the pane chrome's own padding.
    private static func chatButtonFrame(inRawFrame rawFrame: CGRect, size: CGSize) -> CGRect {
        let box = PaneBox.frame(in: rawFrame, dividerThickness: DividerBand.gutter)
        return CGRect(
            x: box.maxX - PaneChrome.horizontalPadding - size.width, y: box.minY + PaneChrome.verticalPadding,
            width: size.width, height: size.height
        )
    }

    /// The rightmost `x` (searching `from` to `to`, inclusive) whose pixel
    /// matches `target` exactly, or nil if it never appears in the range --
    /// finds an element by its own known colour rather than an assumed frame,
    /// for a legend that draws more than one thing at once.
    private func lastX(
        _ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, matching target: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var found: CGFloat?
        var x = from
        while x <= to {
            if hex(image, CGPoint(x: x, y: y)) == target { found = x }
            x += step
        }
        return found
    }

    /// The rightmost `x` (searching `from` to `to`) whose pixel is NOT
    /// `background`, or nil if the whole range is bare ground.
    private func lastX(
        _ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, notMatching background: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var found: CGFloat?
        var x = from
        while x <= to {
            if hex(image, CGPoint(x: x, y: y)) != background { found = x }
            x += step
        }
        return found
    }

    /// The first `x` strictly after `after` (up to `to`) whose pixel is NOT
    /// `background`, or nil if the rest of the row is bare ground.
    private func firstX(
        _ image: NSBitmapImageRep, y: CGFloat, after: CGFloat, to: CGFloat, notMatching background: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var x = after
        while x <= to {
            if hex(image, CGPoint(x: x, y: y)) != background { return x }
            x += step
        }
        return nil
    }

    /// The vertical twins of `firstX`/`lastX`: a fixed column, scanning down
    /// or up for the first pixel that is not `background`.
    private func firstY(
        _ image: NSBitmapImageRep, x: CGFloat, after: CGFloat, to: CGFloat, notMatching background: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var y = after
        while y <= to {
            if hex(image, CGPoint(x: x, y: y)) != background { return y }
            y += step
        }
        return nil
    }

    private func lastY(
        _ image: NSBitmapImageRep, x: CGFloat, from: CGFloat, to: CGFloat, notMatching background: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var found: CGFloat?
        var y = from
        while y <= to {
            if hex(image, CGPoint(x: x, y: y)) != background { found = y }
            y += step
        }
        return found
    }

    /// The smallest `channelDistance` to `target` found anywhere in the range
    /// -- for text small enough that no single pixel reaches full coverage,
    /// this is what "this glyph is drawn in this colour" has to mean.
    private func minChannelDistance(
        _ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, target: String, step: CGFloat = 0.25
    ) -> Int {
        var best = Int.max
        var x = from
        while x <= to {
            best = min(best, channelDistance(hex(image, CGPoint(x: x, y: y)), target))
            x += step
        }
        return best
    }

    /// A face that failed to register resolves to the system font with no
    /// error, so only a lookup by name shows the chrome is really in Inter.
    func testChromeFacesResolveToInterWithDistinctWeights() throws {
        ChromeType.install()
        var weights: [CGFloat] = []
        for weight in ChromeType.Weight.allCases {
            let font = try XCTUnwrap(NSFont(name: weight.postScriptName, size: 14), weight.postScriptName)
            XCTAssertEqual(font.familyName, "Inter", weight.postScriptName)
            let traits = try XCTUnwrap(CTFontCopyTraits(font) as? [CFString: Any])
            weights.append(try XCTUnwrap(traits[kCTFontWeightTrait] as? CGFloat, weight.postScriptName))
        }
        XCTAssertEqual(weights, weights.sorted())
        XCTAssertEqual(Set(weights).count, weights.count, "\(weights)")
    }

    func testWindowButtonsCenterOnTheTitleBarAndStayThereAfterAResize() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        assertButtonsCentered(in: window)

        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(window)
        assertButtonsCentered(in: window)
        window.close()
    }

    /// AppKit rebuilds the standard buttons on a style mask change. The next
    /// pass must move its frame observers onto the new buttons, or AppKit
    /// laying one out again later leaves it off center until some window event.
    func testReplacedWindowButtonsAreObservedAndKeptCentered() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let before = WindowButtonCentering.buttons(of: window)

        window.styleMask.remove(.titled)
        window.styleMask.insert(.titled)
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(window)
        let after = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(zip(before, after).contains { $0 === $1 }, "the style mask change kept the same buttons, so nothing was replaced")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.setFrameOrigin(NSPoint(x: close.frame.minX, y: close.frame.minY + 6))
        assertButtonsCentered(in: window)
        window.close()
    }

    /// The system title bar is taller than the chrome's, so the top of the tab
    /// strip lies inside it. A press there must stay with the strip: some view
    /// of ours at that point opts out of moving the window. The chrome title
    /// bar drags and double-clicks through `TitleBarMouseView`, so every point
    /// on it must reach that view.
    func testTabStripTopInsideTheSystemTitleBarDoesNotMoveTheWindow() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let systemTitleBarHeight = window.frame.height - window.contentLayoutRect.maxY
        let stripTop = ChromeMetrics.TitleBar.height
        XCTAssertGreaterThan(systemTitleBarHeight, stripTop + 1, "the system title bar no longer reaches the tab strip, so this test exercises nothing")

        let stripTopEdge = CGPoint(x: 260, y: stripTop + 1)
        XCTAssertTrue(contentViews(at: stripTopEdge, in: window).contains { !$0.mouseDownCanMoveWindow })
        for titlePoint in [CGPoint(x: 450, y: 10), CGPoint(x: 250, y: 10), CGPoint(x: 800, y: 3)] {
            XCTAssertTrue(contentViews(at: titlePoint, in: window).contains { $0 is TitleBarMouseView }, "\(titlePoint)")
        }
        window.close()
    }

    /// The All Workspaces grid from fixture layouts: at rest with a pane's
    /// hover card open, then with the nine-tab card expanded. PNGs are
    /// written only when `FLOCK_GRID_RENDER_DIR` is set; the samples and
    /// the no-attach check always run.
    func testAllWorkspacesGridRendersFromLayoutsWithoutAttachingAPane() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        let shownByTheCanvas = Set(model.panes.keys.filter { harness.viewModel.ghosttySurface(for: $0) != nil })
        XCTAssertLessThan(shownByTheCanvas.count, model.panes.count, "every pane is on the canvas, so the no-attach check below proves nothing")
        harness.drag.toggleGrid()
        await settle(window)

        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let panes = MiniPaneLayout.paneArea(in: thumbnail, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        let boxes = MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: panes.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        )
        let claude = try XCTUnwrap(boxes.first { $0.pane == GridFixture.claudePane })
        harness.drag.gridHoverMoved(pane: claude.pane)
        harness.drag.gridHoverIntentElapsed(pane: claude.pane)
        await settle(window)
        // The card is placed against this box, so a card drawn anywhere else
        // means the grid published a box the layout does not agree with.
        let anchor = try XCTUnwrap(harness.drag.gridPaneFrame(of: claude.pane))
        XCTAssertEqual(anchor.minX, panes.minX + claude.frame.minX, accuracy: 0.5)
        XCTAssertEqual(anchor.minY, panes.minY + claude.frame.minY, accuracy: 0.5)
        // The tail end to end, through the real decode: a card that opened and
        // read nothing is what this render exists to catch.
        let tail = try XCTUnwrap(harness.viewModel.paneTails[claude.pane], "the card opened without reading its pane")
        XCTAssertEqual(tail.lines.count, PaneTailPolicy.lines)
        XCTAssertEqual(tail.lines.last, "Editing lib/daemon.ts")
        let rest = try snapshot(window)
        if let directory {
            try XCTUnwrap(rest.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-hover.png"))
        }
        for pane in model.panes.keys where !shownByTheCanvas.contains(pane) {
            XCTAssertNil(harness.viewModel.ghosttySurface(for: pane), "the grid attached \(pane.rawValue)")
        }
        assertGridSamples(rest, theme: .tokyoNight)

        harness.drag.gridHoverEnded(pane: claude.pane)
        harness.drag.toggleGridCard(GridFixture.repoTools)
        await settle(window)
        let expanded = try snapshot(window)
        if let directory {
            try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-expanded.png"))
        }
        assertGridSamples(expanded, theme: .tokyoNight)
        window.close()
    }

    /// The strip's overflow hint, which no other render reaches: the fixture
    /// window's four tabs never overflow. repo-tools has nine, so the strip
    /// scrolls and each end of its run hides tabs on exactly one side.
    func testAnOverflowingStripFadesOnlyTheEdgeThatHidesTabs() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)

        XCTAssertEqual(harness.drag.stripEdgeFade, TabStripScrollGeometry.EdgeFade(leading: false, trailing: true))
        let start = try snapshot(window)
        if let directory {
            try XCTUnwrap(start.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("strip-fade-start.png"))
        }

        // Past the end of the run; the scroll view clamps it to the maximum.
        harness.drag.stripScroller?(10_000)
        await settle(window)
        XCTAssertEqual(harness.drag.stripEdgeFade, TabStripScrollGeometry.EdgeFade(leading: true, trailing: false))
        let end = try snapshot(window)
        if let directory {
            try XCTUnwrap(end.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("strip-fade-end.png"))
        }

        // The strip is the only thing that differs between the two: the rail,
        // the canvas and the title bar are untouched by a strip scroll.
        XCTAssertEqual(hex(start, CGPoint(x: 100, y: 74)), hex(end, CGPoint(x: 100, y: 74)), "the rail")
        XCTAssertEqual(hex(start, CGPoint(x: 700, y: 400)), hex(end, CGPoint(x: 700, y: 400)), "the canvas")
        XCTAssertNotEqual(hex(start, CGPoint(x: 210, y: 40)), hex(end, CGPoint(x: 210, y: 40)), "the strip's leading edge")
        window.close()
    }

    /// Tabs are drawn as wide as their titles need: a short name keeps the
    /// strip orderly at one width, and a name that would truncate there takes
    /// the room it measures instead, carrying the tabs after it along. Read
    /// off the frames the strip publishes for the drag layer, which are the
    /// tabs' own layout frames.
    func testATabGrowsToItsTitleAndAShortOneKeepsTheMinimum() async throws {
        let long = "Trash Runner"
        let harness = try await Harness(
            theme: .tokyoNight, model: try Fixture.model(flockTabLabels: ["api", long, "claude", "logs"])
        )
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)

        let frames = harness.drag.tabFrames
        XCTAssertEqual(frames.count, 4)
        let short = try XCTUnwrap(frames.first { $0.id == TabID(rawValue: "w1:t1") }).frame
        let grown = try XCTUnwrap(frames.first { $0.id == TabID(rawValue: "w1:t2") }).frame
        let after = try XCTUnwrap(frames.first { $0.id == TabID(rawValue: "w1:t3") }).frame

        XCTAssertGreaterThan(TabSizing.width(of: long), TabWidth.minimum, "the title fits the minimum, so this test proves nothing")
        XCTAssertEqual(short.width, TabWidth.minimum, "a title inside the minimum no longer gets a whole tab")
        XCTAssertEqual(grown.width, TabSizing.width(of: long))
        XCTAssertEqual(after.minX, grown.maxX + ChromeMetrics.Strip.tabGap, accuracy: 0.5, "the tab after it did not move along")
        window.close()
    }

    /// A pane dragged out of a mini pane, first over another workspace's
    /// thumbnail and then over a third workspace's card where no thumbnail
    /// sits. Both renders carry the ghost, the drop wash and the targeted
    /// card's accent outline.
    func testAGridDragWashesTheThumbnailThenTheCardItIsOver() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
        let source = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let sourcePanes = MiniPaneLayout.paneArea(in: source, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        let claude = try XCTUnwrap(MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: sourcePanes.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        ).first { $0.pane == GridFixture.claudePane })
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(
                title: "claude", symbol: "macwindow", originSize: claude.frame.size, isCompact: true
            ),
            at: CGPoint(x: sourcePanes.minX + claude.frame.midX, y: sourcePanes.minY + claude.frame.midY)
        )

        // The tab's handle strip, which is the one part of a thumbnail that
        // still means the whole tab: a point over a mini pane names that pane.
        let target = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.migrationTab }?.frame)
        harness.drag.move(to: CGPoint(x: target.midX, y: target.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(harness.drag.target, .tabThumbnail(GridFixture.migrationTab))
        await settle(window)
        let overThumbnail = try snapshot(window)
        if let directory {
            try XCTUnwrap(overThumbnail.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-thumbnail.png"))
        }
        assertGridSamples(overThumbnail, theme: .tokyoNight)

        // The card's header row: inside the card, and no thumbnail or tile
        // covers it, which is what makes it the card's own empty space.
        let card = try XCTUnwrap(grid.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        harness.drag.move(to: CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        ))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps))
        await settle(window)
        let overCard = try snapshot(window)
        if let directory {
            try XCTUnwrap(overCard.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-card.png"))
        }
        assertGridSamples(overCard, theme: .tokyoNight)
        window.close()
    }

    /// A tab dragged over its own card: the card opens the slot the drop will
    /// land it in, on the strip's rule, and the cells it passes come back the
    /// other way. Read through the focus bar, which is drawn in one strip
    /// only: where it sits is where that tab is.
    func testACardOpensTheSlotATabReorderWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.repoTools })
        XCTAssertEqual(card.tabs.map(\.id.rawValue), ["w1:t1", "w1:t2", "w1:t3"], "the three tabs a resting card draws")
        let first = card.tabs[0].frame
        let second = card.tabs[1].frame
        let cardFrame = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame)

        let atRest = try snapshot(window)
        XCTAssertEqual(hex(atRest, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.accent.hex, "the focused tab's own bar")
        XCTAssertEqual(hex(atRest, Self.focusBarPoint(of: second)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex, "and no other")

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: first.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: first.midX, y: first.minY + ChromeMetrics.Grid.tabStripHeight / 2),
            home: DragCoordinator.DragHome(atStart: first, item: .tab(GridFixture.agentsTab), boxInItem: CGRect(origin: .zero, size: first.size))
        )
        harness.drag.move(to: CGPoint(x: second.midX + 10, y: second.midY))
        XCTAssertEqual(harness.drag.target, .tabStrip(workspace: GridFixture.repoTools, insertIndex: 2))
        await settle(window)

        let slide = second.minX - first.minX
        let displacements = harness.drag.gridTabDisplacements(inCardFor: GridFixture.repoTools)
        XCTAssertEqual(displacements[GridFixture.agentsTab], CGSize(width: slide, height: 0))
        XCTAssertEqual(displacements[TabID(rawValue: "w1:t2")], CGSize(width: -slide, height: 0))
        XCTAssertEqual(displacements[TabID(rawValue: "w1:t3")], .zero, "a cell the drag never passed")
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame, cardFrame,
            "a reorder opens no row: the card is the shape it was"
        )

        let mid = try snapshot(window)
        XCTAssertEqual(
            hex(mid, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the first slot still holds the focused tab, so nothing slid"
        )
        XCTAssertNotEqual(
            hex(mid, Self.focusBarPoint(of: second)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the dragged tab did not slide into the slot it is about to take"
        )
        if let directory {
            try XCTUnwrap(mid.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-reorder.png"))
        }
        window.close()
    }

    /// A pane dropped in a card's empty space makes a tab there wherever the
    /// pane came from, and the card's own tabs stay where they are in all
    /// three ways it can arrive: from another workspace, from a multi-pane
    /// tab of this card, and from the only pane of a tab of this card, which
    /// the same drop takes away. The placeholder takes the free slot after
    /// them every time, so a card always keeps the tab the drag came from to
    /// drop back onto.
    func testACardPreviewsTheNewTabWhereverThePaneCameFrom() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        // Three tabs, none hidden, so every slot the card draws is a real one.
        let cells = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.herdr }?.tabs)
        XCTAssertEqual(cells.map(\.id), [GridFixture.srcTab, GridFixture.buildTab, GridFixture.issuesTab])
        let slots = cells.map(\.frame)

        // From another workspace: the card keeps its three tabs and the
        // created one takes the next slot.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.claudePane, harness: harness, window: window,
            follows: slots[2], render: nil, directory: nil
        )
        // From a multi-pane tab of this very card: the same slot, since the
        // tab the pane leaves keeps its other panes.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.buildPane, harness: harness, window: window,
            follows: slots[2], render: nil, directory: nil
        )
        // From the only pane of a tab of this card: that tab goes with the
        // drop, and it STAYS DRAWN in its own slot until then, so the
        // placeholder takes the same free slot as the other two. The created
        // tab lands one cell earlier though, in the slot the emptied tab
        // vacates, which is the rect the ghost and the flash have to use.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.srcPane, harness: harness, window: window,
            lands: slots[2], render: "grid-drag-new-tab-same-workspace.png", directory: directory
        )
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.herdr }?.tabs.map(\.frame), slots,
            "a card's own tabs moved for a drop it was only being hovered with"
        )
        // The smallest shape of the same case: a card of ONE tab, whose only
        // pane is the one being dragged. The tab it came from is still there
        // to drop back onto, and the placeholder stands beside it.
        let only = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.glanceTab }?.frame)
        try await assertNewTabSlot(
            of: GridFixture.glance, dragging: GridFixture.glancePane, harness: harness, window: window,
            lands: only, render: nil, directory: nil
        )
        XCTAssertEqual(
            harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.glanceTab }?.frame, only,
            "the one-tab card lost the very tab the drag came from"
        )
        window.close()
    }

    /// Drives one pane drag onto a card's empty space and pins where the
    /// placeholder stands: either in the slot after `follows`, or exactly on
    /// `lands`.
    private func assertNewTabSlot(
        of workspace: WorkspaceID, dragging pane: PaneID, harness: Harness, window: NSWindow,
        follows previous: CGRect? = nil, lands: CGRect? = nil, render: String?, directory: String?
    ) async throws {
        harness.drag.beginIfIdle(
            .pane(pane), ghost: DragCoordinator.Ghost(title: "pane", symbol: "macwindow", originSize: CGSize(width: 40, height: 40), isCompact: true),
            at: CGPoint(x: 10, y: 10)
        )
        try await overEmptySpace(of: workspace, harness: harness, window: window)
        let slot = try XCTUnwrap(
            harness.drag.gridItemFrame(for: .newTab(workspace)), "\(pane.rawValue): no slot was previewed at all"
        )
        if let previous {
            assertSlotFollows(slot, previous, "\(pane.rawValue): the card's last tab")
        }
        if let lands {
            XCTAssertEqual(slot.minX, lands.minX, accuracy: 0.5, "\(pane.rawValue)")
            XCTAssertEqual(slot.minY, lands.minY, accuracy: 0.5, "\(pane.rawValue)")
            XCTAssertEqual(slot.width, lands.width, accuracy: 0.5, "\(pane.rawValue)")
        }
        if let directory, let render {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
        }
        // Released over the gap between the cards, where nothing resolves:
        // this harness has no commit seam to run a real drop through.
        harness.drag.move(to: CGPoint(x: 5, y: 120))
        XCTAssertNil(harness.drag.target)
        harness.drag.release()
        await settle(window)
    }

    /// A tab dropped back in its own gap commits nothing, so its card
    /// previews nothing: no cell slides and the card does not outline itself,
    /// even though the drag still resolves to that card. The preview keys on
    /// the plan, the way every other grid preview does.
    func testACardPreviewsNothingForAReorderThatMovesNoTab() async throws {
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame)
        let cells = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.repoTools }?.tabs)
        let first = cells[0].frame
        // The card's own border, on the edge furthest from the proxy: accent
        // while the card takes a drop, `paneBorder` otherwise.
        let border = CGPoint(x: card.maxX - ChromeMetrics.ruleWidth / 4, y: card.midY)
        let atRest = try snapshot(window)
        XCTAssertEqual(hex(atRest, border), Theme.tokyoNight.palette.chromeRoles.paneBorder.hex)

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: first.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: first.midX, y: first.minY + ChromeMetrics.Grid.tabStripHeight / 2),
            home: DragCoordinator.DragHome(atStart: first, item: .tab(GridFixture.agentsTab), boxInItem: CGRect(origin: .zero, size: first.size))
        )
        // Left of its own centre: the gap before the slot it already holds.
        let target = DropTarget.tabStrip(workspace: GridFixture.repoTools, insertIndex: 0)
        harness.drag.move(to: CGPoint(x: first.midX - 10, y: first.midY))
        XCTAssertEqual(harness.drag.target, target, "it still resolves to a reorder in this card")
        guard case .failure(.noOp) = plan(dragging: .tab(GridFixture.agentsTab), onto: target, model: model) else {
            return XCTFail("a tab dropped in its own gap has to plan nothing, or this test proves nothing")
        }
        await settle(window)

        XCTAssertEqual(
            hex(try snapshot(window), border), hex(atRest, border),
            "the card outlined itself for a drop that commits nothing"
        )
        // The focused tab is still in slot 1 (its bar is there, faded with the
        // origin) and slot 2 still carries no bar at all.
        let mid = try snapshot(window)
        XCTAssertNotEqual(
            hex(mid, Self.focusBarPoint(of: first)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "the focused tab left the slot it still holds"
        )
        XCTAssertEqual(
            hex(mid, Self.focusBarPoint(of: cells[1].frame)), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex,
            "a cell slid for a drop that moves nothing"
        )
        window.close()
    }

    /// A thumbnail is the same size at every window and the row holds as many
    /// as fit, up to the cap. Driven at four window widths through the real
    /// view, so the arithmetic that derives the slot count cannot drift from
    /// the width the cards are actually given.
    func testAThumbnailIsTheSameWidthAtEveryWindowAndTheRowHoldsWhatFitsUpToTheCap() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()

        /// The cells one card draws in its first row, read off the frames the
        /// view published: its thumbnails plus its trailing tile.
        func firstRow(of harness: Harness, workspace: WorkspaceID, prefix: String) throws -> [CGRect] {
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let card = try XCTUnwrap(grid.cards.first { $0.id == workspace }?.frame)
            let tile = grid.tiles.first { $0.id == workspace }?.frame
            let thumbnails = grid.thumbnails.filter { $0.id.rawValue.hasPrefix(prefix) }.map(\.frame)
            let cells = thumbnails + (tile.map { [$0] } ?? [])
            let top = try XCTUnwrap(cells.map(\.minY).min())
            XCTAssertTrue(cells.allSatisfy { card.contains($0.origin) }, "a cell outside its own card")
            return cells.filter { $0.minY == top }.sorted { $0.minX < $1.minX }
        }

        var drawn: [CGFloat: [CGRect]] = [:]
        // 900 is the narrowest the app allows (`MainWindow` sets that
        // minimum), so it is the narrow case as well as the design one. 1090
        // is a width whose row is a few points short of a fifth slot: it is
        // rendered like the rest but it is here for the overrun check, since
        // that is where an over-generous slot count shows up as real points.
        // 2000 is the very wide case: its row fits well past the cap, so what
        // it draws is the cap's answer rather than the row's.
        let rendered: Set<CGFloat> = [Self.windowSize.width, 1200, 1600, 2000]
        for width in [Self.windowSize.width, 1090, 1200, 1600, 2000] as [CGFloat] {
            let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
            let window = harness.makeWindow(size: CGSize(width: width, height: Self.windowSize.height))
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            // The nine-tab card, which is over its cap at every width here, so
            // its row is full and its last slot is the tile.
            let row = try firstRow(of: harness, workspace: GridFixture.repoTools, prefix: "w1:")
            drawn[width] = row
            for cell in row {
                XCTAssertEqual(
                    cell.width, ChromeMetrics.Grid.thumbnailWidth, accuracy: 0.5,
                    "\(width): a cell is not the one thumbnail width"
                )
            }
            // One slot too many costs real points: the cells run past their
            // card's padding, and the cards then run past the grid's. Both
            // ends are checked, since SwiftUI spends the overrun on whichever
            // has slack. This is what pins the derived slot count against the
            // width a row is actually given.
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let card = try XCTUnwrap(grid.cards.first { $0.id == GridFixture.repoTools }?.frame)
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(row.last).maxX, card.maxX - ChromeMetrics.Grid.cardHorizontalPadding + 0.5,
                "\(width): the row ran past its card"
            )
            // And the derivation itself, against the card the view really laid
            // out. The overrun check above is what pins the derived slot COUNT
            // against real frames; this pins the width that count is derived
            // from. It reads the viewport rather than the `contentWidth` the
            // app measures, which are the same number for a grid that only
            // scrolls vertically and hides its indicators.
            XCTAssertEqual(
                GridCardLayout.rowWidth(
                    gridWidth: grid.viewport.width, canvasPadding: ChromeMetrics.Grid.canvasPadding,
                    cardGap: ChromeMetrics.Grid.cardGap, cardPadding: ChromeMetrics.Grid.cardHorizontalPadding
                ),
                card.width - ChromeMetrics.Grid.cardHorizontalPadding * 2, accuracy: 0.5,
                "\(width): the derived row width is not the width a card gives its row"
            )
            if let directory, rendered.contains(width) {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-\(Int(width)).png"))
            }
            window.close()
        }

        let design = try XCTUnwrap(drawn[Self.windowSize.width])
        let middle = try XCTUnwrap(drawn[1200])
        let wide = try XCTUnwrap(drawn[1600])
        let veryWide = try XCTUnwrap(drawn[2000])
        XCTAssertEqual(design.count, 3, "the narrowest window the app allows lost its shape")
        XCTAssertGreaterThan(middle.count, design.count, "a wider window drew no more cells")
        XCTAssertEqual(middle.count, ChromeMetrics.Grid.maxTabsPerRow, "1200 is the width that first reaches the cap")
        XCTAssertEqual(wide.count, middle.count, "a window past the cap kept buying slots")
        XCTAssertEqual(veryWide.count, middle.count, "a very wide window kept buying slots")
        XCTAssertEqual(
            Set(drawn.values.flatMap { $0 }.map { ($0.width * 100).rounded() }).count, 1,
            "a thumbnail changed size between windows"
        )
    }

    /// A pane aimed INSIDE another tab's thumbnail: the mini pane under the
    /// pointer answers, on the canvas's own rules, and the slot the thumbnail
    /// opens is the one that aim produces. Two aims, two renders: a mini
    /// pane's top edge, and the middle of the same pane.
    func testAPaneAimedAtAMiniPaneOpensTheSlotThatAimProduces() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let grabbed = try XCTUnwrap(
            harness.drag.surfaces?.grid?.miniPaneFrame(of: GridFixture.claudePane), "the pane being dragged"
        )
        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.testsTab }?.frame)
        XCTAssertEqual(target.height, ChromeMetrics.Grid.thumbnailHeight)
        XCTAssertEqual(
            target.width, ChromeMetrics.Grid.thumbnailWidth, accuracy: 0.5,
            "the thumbnail the pure band tests are sized against"
        )

        // The view's own published boxes, not a second layout pass: this is
        // what the resolver is actually hit-testing against.
        let drawn = try XCTUnwrap(harness.drag.surfaces?.grid?.miniPanes.first { $0.tab == GridFixture.testsTab })
        XCTAssertEqual(drawn.panes.count, 2, "the fixture's tests tab draws two mini panes")
        let left = try XCTUnwrap(drawn.panes.min { $0.frame.minX < $1.frame.minX })
        let right = try XCTUnwrap(drawn.panes.max { $0.frame.minX < $1.frame.minX })
        let leftBox = left.frame.offsetBy(dx: target.minX, dy: target.minY)

        let area = MiniPaneLayout.paneArea(in: target, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        func boxes(arriving: MiniPaneLayout.Arrival?) -> [MiniPaneLayout.Placed] {
            MiniPaneLayout.boxes(
                layout: model.layouts[GridFixture.testsTab], exported: nil, fallbackPanes: [], size: area.size,
                padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2,
                arriving: arriving
            )
        }
        func inWindow(_ box: CGRect) -> CGRect { box.offsetBy(dx: area.minX, dy: area.minY) }
        let resting = boxes(arriving: nil)

        // The proxy is the mini pane's own footprint, as the grid's pane drag
        // makes it: a thumbnail-sized one would cover the panes being sampled.
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: grabbed.size, isCompact: true),
            at: CGPoint(x: grabbed.midX, y: grabbed.midY)
        )
        XCTAssertTrue(source.contains(grabbed), "the grabbed pane is drawn in its own tab's thumbnail")

        /// Drives one aim to its render, and returns the slot the drop opens
        /// and the pane it opened it inside.
        func aim(
            at point: CGPoint, expecting expected: DropTarget, render: String, line: UInt = #line
        ) async throws -> (opened: CGRect, kept: CGRect) {
            harness.drag.move(to: point)
            XCTAssertEqual(harness.drag.target, expected, "the aim did not resolve", line: line)
            let arrival = try XCTUnwrap(MiniPaneLayout.arrival(
                of: harness.drag.activeSubject, onto: harness.drag.target, tab: GridFixture.testsTab, model: model
            ), "nothing previewed", line: line)
            XCTAssertEqual(arrival.target, expected, "the preview left the aim behind", line: line)
            await settle(window)

            let landing = boxes(arriving: arrival)
            let opened = try XCTUnwrap(landing.first { $0.pane == arrival.pane }).frame
            let kept = try XCTUnwrap(landing.first { $0.pane == left.pane }).frame
            XCTAssertEqual(
                landing.first { $0.pane == right.pane }?.frame, resting.first { $0.pane == right.pane }?.frame,
                "the pane the drop was not aimed at moved", line: line
            )

            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
            }
            let slot = inWindow(opened)
            let untouched = inWindow(try XCTUnwrap(landing.first { $0.pane == right.pane }).frame)
            // Sampled at the bottom of each box, clear of the proxy the
            // pointer carries and of a mini pane's own title row.
            XCTAssertLessThanOrEqual(
                channelDistance(
                    hex(image, CGPoint(x: slot.midX, y: slot.maxY - 10)), hex(image, CGPoint(x: slot.midX, y: slot.maxY - 4))
                ),
                Self.washDither, "the slot the arriving pane takes is not one wash", line: line
            )
            XCTAssertGreaterThan(
                channelDistance(
                    hex(image, CGPoint(x: slot.midX, y: slot.maxY - 4)),
                    hex(image, CGPoint(x: untouched.midX, y: untouched.maxY - 4))
                ),
                Self.washDither, "the slot reads the same as a mini pane still standing there", line: line
            )
            return (opened, kept)
        }

        // The top edge of the left mini pane: the slot opens across the top
        // of that pane alone, which no whole-thumbnail drop can produce.
        let edge = try await aim(
            at: CGPoint(x: leftBox.midX, y: leftBox.minY + 2),
            expecting: .paneEdge(left.pane, .top),
            render: "grid-drag-pane-onto-mini-pane-edge.png"
        )
        XCTAssertLessThan(edge.opened.maxY, edge.kept.minY, "the pane made room above itself")
        XCTAssertEqual(edge.opened.minX, left.frame.minX, accuracy: 1, "inside the aimed pane's own column")

        // The middle of the same pane: across tabs that is a `pane.move`
        // naming it, so it divides on the right instead.
        let interior = try await aim(
            at: CGPoint(x: leftBox.midX, y: leftBox.midY),
            expecting: .paneInterior(left.pane),
            render: "grid-drag-pane-onto-mini-pane-interior.png"
        )
        XCTAssertLessThan(interior.kept.maxX, interior.opened.minX, "the pane made room beside itself")
        XCTAssertLessThan(interior.opened.maxX, right.frame.minX, "still inside the aimed pane's own column")
        window.close()
    }

    /// A pane dragged over another tab's thumbnail: that tab's mini panes
    /// make room where herdr will really put it, beside the tab's focused
    /// pane, and the space they give up is drawn as the arriving pane's slot.
    func testAThumbnailOpensTheSplitAnArrivingPaneWillTake() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.testsTab }?.frame)
        let area = MiniPaneLayout.paneArea(in: target, stripHeight: ChromeMetrics.Grid.tabStripHeight)
        func boxes(arriving: MiniPaneLayout.Arrival?) -> [MiniPaneLayout.Placed] {
            MiniPaneLayout.boxes(
                layout: model.layouts[GridFixture.testsTab], exported: nil, fallbackPanes: [], size: area.size,
                padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2,
                arriving: arriving
            )
        }
        func inWindow(_ box: CGRect) -> CGRect { box.offsetBy(dx: area.minX, dy: area.minY) }

        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )
        // Aimed at the target's handle strip rather than its middle: the
        // proxy is centred on the pointer and a thumbnail's own size, so a
        // pointer in the middle would cover the very panes being sampled.
        harness.drag.move(to: CGPoint(x: target.midX, y: target.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(harness.drag.target, .tabThumbnail(GridFixture.testsTab))
        let arrival = try XCTUnwrap(MiniPaneLayout.arrival(
            of: harness.drag.activeSubject, onto: harness.drag.target, tab: GridFixture.testsTab, model: model
        ))
        let focused = try XCTUnwrap(model.layouts[GridFixture.testsTab]?.focusedPane)
        XCTAssertEqual(arrival.target, .paneEdge(focused, .right))
        await settle(window)

        let resting = boxes(arriving: nil)
        let landing = boxes(arriving: arrival)
        let gaveUp = try XCTUnwrap(resting.first { $0.pane == focused }).frame
        let kept = try XCTUnwrap(landing.first { $0.pane == focused }).frame
        let landed = try XCTUnwrap(landing.first { $0.pane == arrival.pane }).frame
        XCTAssertLessThan(kept.width, gaveUp.width, "the focused pane did not make room")

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-pane-into-tab.png"))
        }

        let opened = inWindow(landed)
        let untouched = inWindow(try XCTUnwrap(landing.first { ![arrival.pane, focused].contains($0.pane) }).frame)
        // Both samples sit in the bottom of their box, below the proxy and
        // below a mini pane's own title row.
        XCTAssertEqual(
            hex(image, CGPoint(x: opened.midX, y: opened.maxY - 14)), hex(image, CGPoint(x: opened.midX, y: opened.maxY - 4)),
            "the slot the arriving pane takes is one flat wash"
        )
        XCTAssertNotEqual(
            hex(image, CGPoint(x: opened.midX, y: opened.maxY - 4)), hex(image, CGPoint(x: untouched.midX, y: untouched.maxY - 4)),
            "the slot reads the same as a mini pane still standing there"
        )
        window.close()
    }

    /// The focus bar's own pixel inside a thumbnail's handle strip: the bar
    /// is drawn at the strip's leading edge, inside its padding.
    private static func focusBarPoint(of thumbnail: CGRect) -> CGPoint {
        CGPoint(
            x: thumbnail.minX + ChromeMetrics.Grid.tabStripHorizontalPadding + ChromeMetrics.Grid.tabStripIndicatorSize.width / 2,
            y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2
        )
    }

    /// The placeholder's frame against the frame the real tab takes, from
    /// real reported frames on both sides. The expanded card's collapse tile
    /// sits in exactly the slot the tenth tab will land in, so its rect
    /// BEFORE the drag is the answer to compare against.
    func testTheNewTabPlaceholderTakesTheSlotTheTabWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        harness.drag.toggleGridCard(GridFixture.repoTools)
        await settle(window)

        // Nine tabs plus the collapse tile fill ten slots, so the tile holds
        // the slot the tenth tab takes. Read before anything is dragged.
        let landing = try XCTUnwrap(harness.drag.surfaces?.grid?.tiles.first { $0.id == GridFixture.repoTools }?.frame)
        let herdrTabs = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.filter { $0.id.rawValue.hasPrefix("w4:") })
        let lastHerdrTab = try XCTUnwrap(herdrTabs.map(\.frame).max { $0.minX < $1.minX })

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )

        try await overEmptySpace(of: GridFixture.repoTools, harness: harness, window: window)
        let expandedPlaceholder = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)))
        XCTAssertEqual(expandedPlaceholder.minX, landing.minX, accuracy: 0.5, "the slot the tenth tab lands in")
        XCTAssertEqual(expandedPlaceholder.minY, landing.minY, accuracy: 0.5)
        XCTAssertEqual(expandedPlaceholder.width, landing.width, accuracy: 0.5)
        XCTAssertEqual(expandedPlaceholder.height, landing.height, accuracy: 0.5)

        let movedTile = try XCTUnwrap(harness.drag.surfaces?.grid?.tiles.first { $0.id == GridFixture.repoTools }?.frame)
        assertSlotFollows(movedTile, expandedPlaceholder, "the placeholder that took its slot")
        let expanded = try snapshot(window)
        if let directory {
            try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-new-tab.png"))
        }

        // A resting card under its cap draws the tab, so the placeholder
        // stands in the next slot of the row it is already in.
        try await overEmptySpace(of: GridFixture.herdr, harness: harness, window: window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)), "the placeholder left with the card it was over")
        let resting = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.herdr)))
        assertSlotFollows(resting, lastHerdrTab, "the card's last tab")

        // A resting card whose row is already full hides the tab it would
        // create, so it shows no placeholder and keeps its single row. It has
        // no tile either, so nothing carries the preview but its outline.
        try await assertNoPlaceholderAndNoNewRow(
            on: GridFixture.mattstackApps, harness: harness, window: window, directory: nil, render: nil
        )

        // A resting card already over its cap draws no tab either, but it has
        // a "+N" tile, and that tile is where the created tab really lands:
        // it gives up its own face for the new tab's while the drop is live.
        try await assertNoPlaceholderAndNoNewRow(
            on: GridFixture.flock, harness: harness, window: window,
            directory: directory, render: "grid-drag-resting-card.png"
        )
        window.close()
    }

    /// Moves the drag onto a card that will not draw the tab it creates, and
    /// pins that the card shows no placeholder and does not grow. A card with
    /// a tile also has to light that tile, which is the only preview such a
    /// drop can honestly carry.
    private func assertNoPlaceholderAndNoNewRow(
        on workspace: WorkspaceID, harness: Harness, window: NSWindow, directory: String?, render: String?
    ) async throws {
        let before = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        // A sibling thumbnail's own ground is the control: it carries the
        // card's wash and nothing else, so the tile can only differ from it by
        // taking a second one. Both are the same role at rest, which the
        // before-sample pins rather than assumes.
        // The cell that should light, and a control that should not: two cells
        // of the same card sharing a ground, so only a second wash can part
        // them. A card with no tile has nothing that may light, so the two
        // controls have to stay equal instead.
        let siblings = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails
            .filter { $0.id.rawValue.hasPrefix("\(workspace.rawValue):") }.map(\.frame))
        let tile = harness.drag.surfaces?.grid?.tiles.first { $0.id == workspace }?.frame
        let lights = tile ?? siblings.first
        let control = try XCTUnwrap(tile == nil ? siblings.dropFirst().first : siblings.first)
        let atRest = try snapshot(window)
        XCTAssertEqual(
            hex(atRest, groundPoint(of: try XCTUnwrap(lights))), hex(atRest, groundPoint(of: control)),
            "\(workspace.rawValue): the two sampled cells do not share a ground at rest, so the check below proves nothing"
        )

        try await overEmptySpace(of: workspace, harness: harness, window: window)
        let after = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        XCTAssertEqual(after.height, before.height, accuracy: 0.5, "\(workspace.rawValue) grew a row the drop will not keep")

        // Whatever stands in for the created tab is also where a committed
        // drop lands. A card with a tile publishes the tile's own rect under
        // that id, from the real view rather than a written-in frame; a card
        // with nothing to stand in has no rect at all and falls back to
        // itself.
        if let tile {
            XCTAssertEqual(
                harness.drag.gridItemFrame(for: .newTab(workspace)), tile,
                "\(workspace.rawValue)'s tile carries the drop but never published its rect for it"
            )
        } else {
            XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(workspace)), "\(workspace.rawValue)")
        }

        let image = try snapshot(window)
        let lit = hex(image, groundPoint(of: try XCTUnwrap(lights)))
        let unlit = hex(image, groundPoint(of: control))
        if let tile {
            XCTAssertNotEqual(lit, unlit, "\(workspace.rawValue)'s tile did not take the drop wash the card's other cells do without")
            // The tile is wearing the new tab's face, not just a wash: only
            // that face carries a handle strip, which is a second coat over
            // its own body. Sampled at the band's trailing end, clear of the
            // "new tab" label. At rest the tile's own face has no band at all,
            // which the before-sample pins.
            let band = CGPoint(
                x: tile.maxX - ChromeMetrics.Grid.tabStripHorizontalPadding - 1,
                y: tile.minY + ChromeMetrics.Grid.tabStripHeight / 2
            )
            XCTAssertEqual(
                hex(atRest, band), hex(atRest, groundPoint(of: tile)),
                "\(workspace.rawValue): the tile already had a band at rest, so the check below proves nothing"
            )
            XCTAssertNotEqual(
                hex(image, band), lit,
                "\(workspace.rawValue)'s tile only washed: it did not take the new tab's own face"
            )
        } else {
            XCTAssertEqual(unlit, lit, "\(workspace.rawValue) has no tile, so nothing inside it may take a second wash")
        }
        if let directory, let render {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(render))
        }
    }

    /// The largest per-channel gap between two sampled hexes. A blend against
    /// whatever is behind moves every channel; a shadow's bleed moves them by
    /// a unit or two, which is what this has to stay clear of.
    private func channelDistance(_ lhs: String, _ rhs: String) -> Int {
        func channels(_ hex: String) -> [Int] {
            let digits = Array(hex.dropFirst())
            return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 0 }
        }
        return zip(channels(lhs), channels(rhs)).map { abs($0 - $1) }.max() ?? 0
    }

    /// A cell's own ground: the BOTTOM-left corner, two points in. A
    /// thumbnail's top is its handle strip and its middle is mini panes, so
    /// only the padding below them is the ground a tile can be compared with.
    private func groundPoint(of cell: CGRect) -> CGPoint {
        CGPoint(x: cell.minX + 2, y: cell.maxY - 2)
    }

    /// A drop the planner refuses must promise nothing: no placeholder and no
    /// wash. It resolves to the card like any other, so a preview keyed on the
    /// resolved target alone would draw for it.
    func testACardPreviewsNothingForADropThePlannerRefuses() async throws {
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        // A multi-pane tab into ANOTHER workspace: this fixture carries no
        // split tree, so `planTabMigration` refuses the shape outright and
        // the card may not outline, wash or open a slot for it.
        let other = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        let refusedGround = Self.headerGround(of: other)
        // Clear of the proxy, which hangs from the pointer: the card's own
        // fill at its leading edge, on the same row.
        let refusedSample = CGPoint(x: other.minX + ChromeMetrics.Grid.cardHorizontalPadding / 2, y: refusedGround.y)
        let refusedAtRest = hex(try snapshot(window), refusedSample)
        let multiPane = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: multiPane.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: [])
            ),
            at: CGPoint(x: multiPane.midX, y: multiPane.minY + ChromeMetrics.Grid.tabStripHeight / 2)
        )
        harness.drag.move(to: refusedGround)
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps), "it still resolves to the card")
        guard case .failure = plan(dragging: .tab(GridFixture.agentsTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model) else {
            return XCTFail("the fixture grew a split tree, so this drop now commits and previews nothing wrongly")
        }
        await settle(window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(GridFixture.mattstackApps)), "a refused plan may not promise a tab")
        XCTAssertEqual(hex(try snapshot(window), refusedSample), refusedAtRest, "nor wash the card it will not change")
        // Released over the gap between the cards, where nothing resolves:
        // this harness has no commit seam to run a real drop through.
        harness.drag.move(to: CGPoint(x: 5, y: 120))
        XCTAssertNil(harness.drag.target)
        harness.drag.release()
        await settle(window)

        window.close()
    }

    /// The grid on the other side of the ladder, and on the theme where the
    /// handle strip's title has the least headroom of the seventeen. Every
    /// other grid render is Tokyo Night, which is where the strip's role was
    /// measured, so neither of these is the theme the choice was made on.
    func testTheGridRendersInALightThemeAndInTheTightestDarkOne() async throws {
        try await renderGrid(themed: "catppuccin-latte", into: "grid-rest-latte.png")
        try await renderGrid(themed: "nord", into: "grid-rest-nord.png")
    }

    private func renderGrid(themed id: String, into file: String) async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
        let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
        assertGridSamples(image, theme: theme)

        // The strip is a band, not the body it sits on: sampled inside a
        // thumbnail's strip and inside the same thumbnail's ground. The
        // sample sits in the run between the title and the status dot, clear
        // of both, since either would be its own colour.
        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let beforeTheDot = ChromeMetrics.Grid.tabStripHorizontalPadding
            + ChromeMetrics.Grid.labelStatusDot + ChromeMetrics.Grid.tabStripSpacing
        let strip = hex(image, CGPoint(x: thumbnail.maxX - beforeTheDot, y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight / 2))
        XCTAssertEqual(strip, theme.palette.chromeRoles.tabStripFill.hex, "\(id): the strip carries the role it was given")
        XCTAssertNotEqual(strip, theme.palette.chromeRoles.canvas.hex, "\(id): and it is not the thumbnail body")
        window.close()
    }

    /// A whole tab dragged by its handle strip is proxied as a miniature of
    /// its own thumbnail, at that thumbnail's exact frame. The compact cap
    /// would shrink it, which would read as a different tab than the one the
    /// drop is aimed beside.
    func testATabDraggedFromItsHandleStripIsProxiedAsAMiniatureOfItself() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let model = try GridFixture.model()
        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let area = MiniPaneLayout.paneArea(
            in: CGRect(origin: .zero, size: source.size), stripHeight: ChromeMetrics.Grid.tabStripHeight
        )
        let panes = MiniPaneLayout.boxes(
            layout: model.layouts[GridFixture.agentsTab], exported: nil, fallbackPanes: [], size: area.size,
            padding: ChromeMetrics.Grid.thumbnailPadding, gap: ChromeMetrics.Grid.miniPaneGap, displayScale: 2
        ).compactMap { placed -> DragCoordinator.Ghost.TabMiniature.Pane? in
            guard let pane = model.panes[placed.pane] else { return nil }
            return .init(title: pane.displayTitle, status: pane.agentStatus, box: placed.frame)
        }
        XCTAssertEqual(panes.count, 3, "the fixture tab's own three panes")

        harness.drag.beginIfIdle(
            .tab(GridFixture.agentsTab),
            ghost: DragCoordinator.Ghost(
                title: "agents", symbol: "rectangle.stack", originSize: source.size, isCompact: true,
                tabMiniature: .init(title: "agents", status: .working, isFocusedTab: true, panes: panes)
            ),
            at: CGPoint(x: source.midX, y: source.minY + ChromeMetrics.Grid.tabStripHeight / 2)
        )
        let ghost = try XCTUnwrap(harness.drag.ghost)
        XCTAssertEqual(
            DragVisuals.ghostSize(forOrigin: ghost.originSize, bounds: ghost.bounds), source.size,
            "the proxy is the thumbnail it was picked up from, one to one"
        )

        let target = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        harness.drag.move(to: CGPoint(
            x: target.midX,
            y: target.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        ))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(GridFixture.mattstackApps))
        // This fixture's tabs carry no split tree, so a MULTI-pane tab cannot
        // be migrated and the card it is over is left unlit. That is the
        // preview keying on the plan; the render is here for the proxy, and
        // a single-pane tab is what proves the lit path.
        guard case .failure = plan(
            dragging: .tab(GridFixture.agentsTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model
        ) else {
            return XCTFail("the fixture grew a split tree, so this render's card would now light")
        }
        guard case .success = plan(
            dragging: .tab(GridFixture.glanceTab), onto: .workspaceThumbnail(GridFixture.mattstackApps), model: model
        ) else {
            return XCTFail("a single-pane tab migrating into another workspace has to commit")
        }
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-tab.png"))
        }

        // The proxy is a thumbnail's size and centred on the pointer, so it
        // covers what it is aimed at: its own band has to let that through.
        // An opaque one would paint the fill role exactly.
        // Clear of both the title and the status dot, so the sample is the
        // band's own fill rather than an antialiased glyph edge.
        let proxy = try XCTUnwrap(harness.drag.ghostTopLeft)
        let band = CGPoint(x: proxy.x + source.width - 18, y: proxy.y + ChromeMetrics.Grid.tabStripHeight / 2)
        XCTAssertGreaterThan(
            channelDistance(hex(image, band), Theme.tokyoNight.palette.chromeRoles.tabStripFill.hex), 8,
            "the proxy's band reads as its own opaque fill, so nothing under the proxy shows through"
        )
        window.close()
    }

    /// Moves the live drag onto a card's own empty space, which is its header
    /// row: no thumbnail or tile covers it.
    private func overEmptySpace(of workspace: WorkspaceID, harness: Harness, window: NSWindow) async throws {
        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        harness.drag.move(to: Self.headerGround(of: card))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(workspace))
        await settle(window)
    }

    /// A card's own empty space: the middle of its header row, which no
    /// thumbnail or tile covers.
    private static func headerGround(of card: CGRect) -> CGPoint {
        CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.cardVerticalPadding + ChromeMetrics.WorkspaceRow.contentHeight / 2
        )
    }

    /// Two cells of one row: same top edge and height, one `tabGap` apart.
    private func assertSlotFollows(_ slot: CGRect, _ previous: CGRect, _ label: String) {
        XCTAssertEqual(slot.minY, previous.minY, accuracy: 0.5, "same row as \(label)")
        XCTAssertEqual(slot.height, previous.height, accuracy: 0.5, "same height as \(label)")
        XCTAssertEqual(slot.width, previous.width, accuracy: 0.5, "same width as \(label)")
        XCTAssertEqual(slot.minX, previous.maxX + ChromeMetrics.Grid.tabGap, accuracy: 0.5, "the slot after \(label)")
    }

    /// Points are top-left in the 900x560 window: the title bar, the grid
    /// header over its rule, the canvas margin, and the first card's border,
    /// fill and focused accent bar.
    private func assertGridSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let samples: [(String, CGPoint, RGB)] = [
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/header", CGPoint(x: 450, y: 28), roles.chrome),
            ("rule/header", CGPoint(x: 450, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 5, y: 120), roles.canvas),
            ("paneBorder/card", CGPoint(x: 13.25, y: 150), roles.paneBorder),
            ("pane/card", CGPoint(x: 18, y: 80), roles.pane),
            ("accent/focusedBar", CGPoint(x: 27.5, y: 94), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    /// Rearrange mode repaints every pane; it may not move or resize one. The
    /// rects the canvas lays the cells out at are the same rects
    /// `CanvasGeometry` publishes for drop hit-testing, so a pane drawn even
    /// slightly bigger than its box puts the pointer over a rect the drop
    /// resolver never looks at.
    ///
    /// Read along y 400, the row `assertSamples` already reads the resting
    /// canvas on: the box edges there are every crossing between the canvas
    /// ground and something drawn on it, which holds whatever colour the
    /// borders themselves take (they switch to the accent in this mode).
    func testRearrangeModeRepaintsPanesWithoutMovingOrResizingThem() async throws {
        let theme = Theme.tokyoNight
        let harness = try await Harness(theme: theme)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let restEdges = paneBoxEdges(in: try snapshot(window), theme: theme)
        XCTAssertFalse(restEdges.isEmpty, "no pane box was found at rest, so this test reads nothing")

        harness.rearrange.toggle()
        await settle(window)
        let image = try snapshot(window)
        XCTAssertTrue(harness.rearrange.active, "the toggle did not enter the mode")
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("rearrange-canvas.png"))
        }
        XCTAssertEqual(paneBoxEdges(in: image, theme: theme), restEdges)
        window.close()
    }

    // MARK: - Helpers

    /// Every crossing between the canvas ground and a pane box along one row,
    /// left to right, in top-left window points.
    private func paneBoxEdges(in image: NSBitmapImageRep, theme: Theme, y: CGFloat = 400) -> [CGFloat] {
        let ground = theme.palette.chromeRoles.canvas.hex
        var edges: [CGFloat] = []
        var onGround = true
        for step in stride(from: 150.0, to: Self.windowSize.width - 1, by: 0.25) {
            let isGround = hex(image, CGPoint(x: step, y: y)) == ground
            if isGround != onGround {
                edges.append(step)
                onGround = isGround
            }
        }
        return edges
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drawn into an sRGB context so sampled bytes compare directly against
    /// the role hexes.
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

    /// Straight from the bitmap's bytes, with no color-space conversion on the
    /// way out.
    /// How far apart two sampled colours may be and still be the same
    /// surface. A low-opacity wash over a dark ground does not composite to
    /// one exact byte across a region, so an exact comparison reads the
    /// renderer's own dither as a difference; a genuinely different surface
    /// is tens of units away.
    private static let washDither = 2

    private func hex(_ image: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat = 2) -> String {
        guard let data = image.bitmapData else { return "?" }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x < image.pixelsWide, y < image.pixelsHigh else { return "?" }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
    }

    /// Points are top-left, in the 900x560 window. Status samples sit on each
    /// row's 8pt dot, which spans x 20 to 28: x 24 is its center and x 21 is
    /// two points in, inside a hollow ring's stroke. Rows start at y 61 on a
    /// 28pt pitch; tabs start at x 203 on a 103pt pitch, 28 tall on a strip
    /// spanning y 26 to 62.
    ///
    /// Row 1 is the selected row AND an idle workspace, which is what pins
    /// that selection no longer takes the dot: its stroke has to be green,
    /// not the accent, and its middle has to be the row's own selection fill
    /// showing through the ring.
    private func assertSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let palette = theme.palette
        let samples: [(String, CGPoint, RGB)] = [
            ("status/selectedRing", CGPoint(x: 21, y: 74), palette.green),
            ("status/selectedHollow", CGPoint(x: 24, y: 74), roles.selection),
            ("status/blocked", CGPoint(x: 24, y: 102), palette.red),
            ("status/working", CGPoint(x: 24, y: 130), palette.yellow),
            ("status/done", CGPoint(x: 24, y: 158), palette.teal),
            ("status/idleRing", CGPoint(x: 21, y: 186), palette.green),
            ("status/idleHollow", CGPoint(x: 24, y: 186), roles.chrome),
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/strip", CGPoint(x: 700, y: 30), roles.chrome),
            ("chrome/rail", CGPoint(x: 75, y: 400), roles.chrome),
            ("rule/rail", CGPoint(x: 192.25, y: 400), roles.rule),
            ("selection/row", CGPoint(x: 100, y: 64), roles.selection),
            ("tabRest", CGPoint(x: 253, y: 40), roles.tabRest),
            ("selection/tab", CGPoint(x: 459, y: 40), roles.selection),
            ("accent/underline", CGPoint(x: 459, y: 61.25), roles.accent),
            ("rule/strip", CGPoint(x: 700, y: 62.25), roles.rule),
            ("canvas/margin", CGPoint(x: 196, y: 400), roles.canvas),
            ("paneBorder", CGPoint(x: 199.25, y: 400), roles.paneBorder),
            ("pane", CGPoint(x: 300, y: 400), roles.pane),
            ("canvas/gutter", CGPoint(x: 546, y: 400), roles.canvas),
            ("accent/focusedLeading", CGPoint(x: 551.25, y: 400), roles.accent),
            ("accent/focused", CGPoint(x: 893.25, y: 400), roles.accent),
        ]
        for (name, point, expected) in samples {
            XCTAssertEqual(hex(image, point), expected.hex, "\(theme.id) \(name) at \(point)")
        }
    }

    /// The rail is drawn at the width the user left it at, and the canvas
    /// starts where the rail stops. Read along y 400, the same row
    /// `assertSamples` reads the resting window on, where the default rail
    /// puts its rule at x 192.25 and the first pane's border at x 199.25.
    ///
    /// 260 is inside the bounds at this 900pt window (`RailWidth`), so the
    /// whole difference from the default render is the 68pt the rail gained
    /// and the canvas gave up.
    func testTheRailDrawsAtTheWidthItWasLeftAt() async throws {
        let theme = Theme.tokyoNight
        let roles = theme.palette.chromeRoles
        let harness = try await Harness(theme: theme)
        harness.railWidth.released(at: 260)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)

        XCTAssertEqual(hex(image, CGPoint(x: 240, y: 400)), roles.chrome.hex, "the rail stopped short of 260")
        XCTAssertEqual(hex(image, CGPoint(x: 260.25, y: 400)), roles.rule.hex, "the rail's rule is not at its new edge")
        XCTAssertEqual(hex(image, CGPoint(x: 264, y: 400)), roles.canvas.hex, "the canvas does not start after the rule")
        XCTAssertEqual(hex(image, CGPoint(x: 267.25, y: 400)), roles.paneBorder.hex, "the first pane did not move with the canvas")
    }

    /// A zoomed tab, read along the same row `assertSamples` reads the resting
    /// canvas on (y 400, clear of the divider's own 51pt handle). At rest that
    /// row crosses, in order: the canvas margin, the unfocused left pane's
    /// border, its body, the gutter between the boxes, the focused pane's
    /// accent border, its body, and its far accent border. Zoomed, herdr's
    /// renderer holds the focused pane open over the whole tab area, so the
    /// gutter and the left pane's own border have to be that pane's body and
    /// its accent border instead -- a canvas still drawing both boxes fails on
    /// the gutter, and one drawing the wrong pane over the whole area fails on
    /// the border color, which only the focused pane wears.
    func testAZoomedTabDrawsItsHeldPaneAcrossTheWholeCanvas() async throws {
        let theme = Theme.tokyoNight
        let roles = theme.palette.chromeRoles
        let resting = try await Harness(theme: theme, model: try Fixture.model())
        let restingWindow = resting.makeWindow(size: Self.windowSize)
        await settle(restingWindow)
        let restingImage = try snapshot(restingWindow)

        let zoomed = try await Harness(theme: theme, model: try Fixture.model(zoomed: true))
        let zoomedWindow = zoomed.makeWindow(size: Self.windowSize)
        await settle(zoomedWindow)
        let zoomedImage = try snapshot(zoomedWindow)
        if let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            try XCTUnwrap(zoomedImage.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("zoom-canvas.png"))
        }

        let leftBorder = CGPoint(x: 199.25, y: 400)
        let gutter = CGPoint(x: 546, y: 400)
        let focusedBorder = CGPoint(x: 551.25, y: 400)
        let farBorder = CGPoint(x: 893.25, y: 400)

        XCTAssertEqual(hex(restingImage, gutter), roles.canvas.hex, "the resting canvas draws no gutter, so the zoomed check below proves nothing")
        XCTAssertEqual(hex(restingImage, leftBorder), roles.paneBorder.hex, "the resting canvas does not put an unfocused pane at the left edge")

        XCTAssertEqual(hex(zoomedImage, gutter), roles.pane.hex, "the gutter between the two boxes is still drawn: the zoomed pane does not fill the canvas")
        XCTAssertEqual(hex(zoomedImage, focusedBorder), roles.pane.hex, "a box edge is still drawn mid-canvas")
        XCTAssertEqual(hex(zoomedImage, leftBorder), roles.accent.hex, "the pane at the canvas's left edge is not the focused one the zoom holds open")
        XCTAssertEqual(hex(zoomedImage, farBorder), roles.accent.hex, "the pane at the canvas's right edge is not the focused one the zoom holds open")

        zoomedWindow.close()
        restingWindow.close()
    }

    /// The three places the one inline rename editor opens, and the zoom
    /// badge. Each is compared against the SAME window at rest: the editor
    /// has to change its own surface and leave the other two alone, which is
    /// what says it opened where it was asked to and nowhere else. The badge
    /// is checked by its own color inside the legend it rides, since a
    /// whole-image comparison between two separately built windows would pass
    /// on any incidental difference. PNGs are written only when
    /// `FLOCK_CHROME_RENDER_DIR` is set.
    func testEachRenameEditorAndTheZoomBadgePaintOnlyTheirOwnSurface() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        // The selected tab's own midpoint, the selected rail row's, and a
        // point inside the focused pane -- the three sampled in `assertSamples`.
        let tabPoint = CGPoint(x: 459, y: 40)
        let railPoint = CGPoint(x: 100, y: 64)
        let panePoint = CGPoint(x: 700, y: 400)

        /// Renders `model` with `open` applied, against the same window at
        /// rest, and returns both images' data plus the three samples.
        func render(
            _ name: String, model: SessionModel, open: (Harness) -> Void
        ) async throws -> (rest: Data, changed: Data, restSamples: [String], changedSamples: [String]) {
            let harness = try await Harness(theme: .tokyoNight, model: model)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let rest = try snapshot(window)
            let restSamples = [tabPoint, railPoint, panePoint].map { hex(rest, $0) }

            open(harness)
            await settle(window)
            let changed = try snapshot(window)
            if let directory {
                try XCTUnwrap(changed.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            let changedSamples = [tabPoint, railPoint, panePoint].map { hex(changed, $0) }
            window.close()
            return (
                try XCTUnwrap(rest.representation(using: .png, properties: [:])),
                try XCTUnwrap(changed.representation(using: .png, properties: [:])),
                restSamples, changedSamples
            )
        }

        // Each editor is read the same way: the window as a whole has to
        // change, and the two surfaces it did not open on have to sample
        // exactly as they did at rest. The three points are the surfaces, not
        // the editors -- a rail row's field lands on the very fill its own
        // sample point reads, and a pane's stands on a one-point legend band
        // no sample point reaches, so only the image carries those.
        let tab = try await render("rename-tab.png", model: try Fixture.model()) { harness in
            harness.viewModel.beginRename(.tab(TabID(rawValue: "w1:t3")))
        }
        XCTAssertNotEqual(tab.rest, tab.changed, "the editor did not open on the tab")
        XCTAssertNotEqual(tab.restSamples[0], tab.changedSamples[0], "the tab's own label is not where it opened")
        XCTAssertEqual(tab.restSamples[1], tab.changedSamples[1], "renaming a tab repainted the rail")
        XCTAssertEqual(tab.restSamples[2], tab.changedSamples[2], "renaming a tab repainted the canvas")

        let workspace = try await render("rename-workspace.png", model: try Fixture.model()) { harness in
            harness.viewModel.beginRename(.workspace(WorkspaceID(rawValue: "w1")))
        }
        XCTAssertNotEqual(workspace.rest, workspace.changed, "the editor did not open on the rail row")
        XCTAssertEqual(workspace.restSamples[0], workspace.changedSamples[0], "renaming a workspace repainted the strip")
        XCTAssertEqual(workspace.restSamples[2], workspace.changedSamples[2], "renaming a workspace repainted the canvas")

        let pane = try await render("rename-pane.png", model: try Fixture.model()) { harness in
            harness.viewModel.beginRename(.pane(PaneID(rawValue: "w1:p2")))
        }
        XCTAssertNotEqual(pane.rest, pane.changed, "the editor did not open on the pane")
        XCTAssertEqual(pane.restSamples[0], pane.changedSamples[0], "renaming a pane repainted the strip")
        XCTAssertEqual(pane.restSamples[1], pane.changedSamples[1], "renaming a pane repainted the rail")

        // The badge is its own color and nothing else in the chrome is: the
        // parity checklist reserves mauve for it, never a status. So the
        // check is that mauve appears inside the focused pane's legend when
        // the tab is zoomed and nowhere in that band when it is not -- an
        // assertion that cannot pass unless the badge actually painted.
        let legend = CGRect(x: 552, y: 66, width: 342, height: 26)
        let mauve = Theme.tokyoNight.palette.mauve.hex
        let resting = try await Harness(theme: .tokyoNight, model: try Fixture.model())
        let restingWindow = resting.makeWindow(size: Self.windowSize)
        await settle(restingWindow)
        let restingImage = try snapshot(restingWindow)
        let zoomed = try await Harness(theme: .tokyoNight, model: try Fixture.model(zoomed: true))
        let zoomedWindow = zoomed.makeWindow(size: Self.windowSize)
        await settle(zoomedWindow)
        let zoomedImage = try snapshot(zoomedWindow)
        if let directory {
            try XCTUnwrap(zoomedImage.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("zoom-badge.png"))
        }
        XCTAssertNil(
            firstPoint(in: legend, matching: mauve, of: restingImage),
            "the unzoomed legend already carries the badge color, so the check below proves nothing"
        )
        XCTAssertNotNil(
            firstPoint(in: legend, matching: mauve, of: zoomedImage),
            "no \(mauve) anywhere in the focused pane's legend: the zoom badge did not paint"
        )
        XCTAssertEqual(hex(zoomedImage, tabPoint), tab.restSamples[0], "the badge repainted the strip")
        XCTAssertEqual(hex(zoomedImage, railPoint), tab.restSamples[1], "the badge repainted the rail")
        zoomedWindow.close()
        restingWindow.close()
    }

    /// herdr's dots style, the one rule every surface draws a status with:
    /// working, blocked and done filled, idle a hollow ring, unknown a small
    /// centered dot. Drawn on its own rather than off a window fixture, which
    /// carries no `unknown` workspace anywhere -- and the shapes are read at
    /// the 8pt the rail uses, where a ring and a dot are actually distinct.
    ///
    /// In a 20pt box an 8pt dot spans 6 to 14: x 10 is its center and x 7 is
    /// one point inside a ring's 2pt stroke, which the 4pt unknown dot never
    /// reaches.
    func testTheStatusDotDrawsHerdrsFillStyleForEveryState() async throws {
        let theme = Theme.tokyoNight
        let roles = theme.palette.chromeRoles
        let expectations: [(AgentStatus, center: RGB, edge: RGB)] = [
            (.working, center: theme.palette.yellow, edge: theme.palette.yellow),
            (.blocked, center: theme.palette.red, edge: theme.palette.red),
            (.done, center: theme.palette.teal, edge: theme.palette.teal),
            (.idle, center: roles.chrome, edge: theme.palette.green),
            (.unknown, center: theme.palette.overlay0, edge: roles.chrome),
        ]
        for (status, center, edge) in expectations {
            ChromeType.install()
            let root = StatusDot(status: status, theme: theme, size: ChromeMetrics.WorkspaceRow.statusDot)
                .frame(width: 20, height: 20)
                .background(theme.chrome)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.colorSpace = .sRGB
            window.contentView = NSHostingView(rootView: root)
            await settle(window)
            let image = try snapshot(window)
            XCTAssertEqual(hex(image, CGPoint(x: 10, y: 10)), center.hex, "\(status.rawValue) center")
            XCTAssertEqual(hex(image, CGPoint(x: 7, y: 10)), edge.hex, "\(status.rawValue) edge")
            window.close()
        }
    }

    /// Four panes go blocked at once in a workspace nobody is looking at, so
    /// the stack fills and overflows in one step. Built before the window
    /// exists rather than driven into a live one: the cards animate in, and a
    /// render caught mid-transition would differ between two runs of the same
    /// code. The check is the status hue appearing in the corner the stack
    /// occupies, against the same corner at rest -- a single pixel is not
    /// nameable on a mark this small with a glow behind it.
    func testTheAttentionStackFillsTheTopRightCornerAndOverflowsToAPill() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let corner = CGRect(x: 600, y: 66, width: 300, height: 240)
        let red = Theme.tokyoNight.palette.red.hex

        let resting = try await Harness(theme: .tokyoNight, model: try Fixture.model())
        let restingWindow = resting.makeWindow(size: Self.windowSize)
        await settle(restingWindow)
        let restingImage = try snapshot(restingWindow)

        // Two agents stop for input and two finish a run, all in workspaces
        // the window is not showing, so the stack carries both kinds at once.
        var working = try Fixture.model()
        working.panes[PaneID(rawValue: "w4:p1")]?.agentStatus = .working
        working.panes[PaneID(rawValue: "w4:p2")]?.agentStatus = .working
        var settled = working
        settled.panes[PaneID(rawValue: "w2:p1")]?.agentStatus = .blocked
        settled.panes[PaneID(rawValue: "w3:p1")]?.agentStatus = .blocked
        settled.panes[PaneID(rawValue: "w4:p1")]?.agentStatus = .done
        settled.panes[PaneID(rawValue: "w4:p2")]?.agentStatus = .idle

        // Frozen: two of these four toasts are `finished`, and a machine that
        // took six seconds to build and settle both windows would otherwise
        // sweep them away before the snapshot.
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        let harness = try await Harness(theme: .tokyoNight, model: working, now: { frozen })
        harness.viewModel.update(model: settled, connection: .live)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("attention-toasts.png"))
        }

        XCTAssertEqual(harness.viewModel.attentionToasts.toasts.count, 4)
        XCTAssertEqual(harness.viewModel.attentionToasts.visible.count, 3)
        XCTAssertEqual(harness.viewModel.attentionToasts.collapsedCount, 1)
        XCTAssertNil(
            firstPoint(in: corner, matching: red, of: restingImage),
            "the resting corner already carries the status hue, so the check below proves nothing"
        )
        XCTAssertNotNil(
            firstPoint(in: corner, matching: red, of: image),
            "no \(red) anywhere in the top-right corner: the attention stack did not paint"
        )
        window.close()
        restingWindow.close()
    }

    /// The first point of `rect` (top-left, window points) whose pixel is
    /// exactly `hex`, or `nil` when none is. Used for a mark too small and
    /// too antialiased at its edges to name a single reliable pixel for.
    private func firstPoint(in rect: CGRect, matching target: String, of image: NSBitmapImageRep) -> CGPoint? {
        for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
                let point = CGPoint(x: x, y: y)
                if hex(image, point) == target { return point }
            }
        }
        return nil
    }

    private func assertButtonsCentered(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = WindowButtonCentering.buttons(of: window)
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        for button in buttons {
            let inWindow = button.convert(button.bounds, to: nil)
            let centerFromTop = window.frame.height - inWindow.midY
            XCTAssertEqual(centerFromTop, ChromeMetrics.TitleBar.height / 2, accuracy: 0.5, "\(button.frame)", file: file, line: line)
        }
    }

    /// Every visible view of ours under a top-left window point, the content
    /// view included: the views whose `mouseDownCanMoveWindow` decides whether
    /// a press there moves the window.
    private func contentViews(at point: CGPoint, in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        let windowPoint = NSPoint(x: point.x, y: window.frame.height - point.y)
        var found: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view.convert(view.bounds, to: nil).contains(windowPoint) {
                found.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}

@MainActor
private struct Harness {
    let themeStore: ThemeStore
    let textSize: TerminalTextSizeStore
    let railWidth: RailWidthStore
    let toasts: ToastCenter
    let rearrange: RearrangeMode
    let drag: DragCoordinator
    let dividerDrag: DividerDragCoordinator
    let chatStore: ChatStore
    let viewModel: SessionViewModel

    init(
        theme: Theme, model: SessionModel? = nil, client: any HerdrCommandClient = OfflineHerdrClient(),
        attaching panes: [PaneID] = Fixture.canvasPanes,
        // Absent by default, same as a machine with no chat binary: a render
        // test that does not care about chat must keep seeing exactly what it
        // saw before this button existed.
        chatAvailable: Bool = false, chatStatusJSON: [PaneID: String] = [:], chatUnread: [PaneID: Int] = [:],
        // False only for a test proving the production fetch wiring itself:
        // every other test wants status/unread in place before the first
        // render, which calling the store here directly gives for free.
        seedChatStatus: Bool = true,
        // Frozen by any test that renders the attention stack: a finished
        // toast expires six seconds after it is raised, and a render that
        // read the wall clock would flip on a loaded machine that took that
        // long to build and settle two windows.
        now: @escaping @MainActor () -> Date = { Date() }
    ) async throws {
        ChromeType.install()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        railWidth = RailWidthStore(userDefaults: defaults)
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }))
        chatStore = ChatStore(
            toasts: ToastCenter(),
            probe: { chatAvailable ? "/usr/bin/true" : nil },
            rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in FixtureChatRunning(statusJSON: chatStatusJSON) }
        )
        await chatStore.probeTask.value
        if seedChatStatus {
            for pane in chatStatusJSON.keys {
                await chatStore.refreshStatus(for: pane)
            }
            for (pane, count) in chatUnread {
                chatStore.setUnreadCount(count, for: pane)
            }
        }
        viewModel = SessionViewModel(client: client, ghosttyFactory: GroundSurfaceFactory(), now: now)
        viewModel.update(model: try model ?? Fixture.model(), connection: .live)
        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
    }

    func makeWindow(size: CGSize) -> NSWindow {
        let root = MainWindow(viewModel: viewModel, sessionLabel: "render")
            .environment(themeStore)
            .environment(textSize)
            .environment(railWidth)
            .environment(toasts)
            .environment(rearrange)
            .environment(drag)
            .environment(dividerDrag)
            .environment(chatStore)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

private struct OfflineHerdrClient: HerdrCommandClient {
    struct Offline: Error {}

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        throw Offline()
    }
}

/// Answers `status` with the JSON keyed by that pane; any other verb, or a
/// pane not in the map, is not something a chrome render ever asks for.
private actor FixtureChatRunning: ChatRunning {
    private let statusJSON: [PaneID: String]

    init(statusJSON: [PaneID: String]) {
        self.statusJSON = statusJSON
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        guard case let .status(pane: rawPane) = verb, let json = statusJSON[PaneID(rawValue: rawPane)] else {
            throw ChatFailure(message: "FixtureChatRunning has no status for \(verb)")
        }
        return (Data(json.utf8), 0)
    }
}

@MainActor
private final class GroundSurface: GhosttyPaneSurface {
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    var hasFirstFrame: Bool { true }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface()
    }
}

/// Answers the hover card's tail read and nothing else, in herdr's own
/// envelope shape: the screen sits under `result.read`, and a payload written
/// anywhere else decodes to nothing and leaves every card blank with no error
/// to show for it.
private struct GridFixtureClient: HerdrCommandClient {
    static let screen = """
        $ bun test lib/daemon
        lib/daemon/port-allocator.test.ts:
        (pass) allocates the first free port
        (pass) refuses a port already held
        (pass) releases on close

         31 pass, 0 fail
        Editing lib/daemon.ts

        """

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { throw OfflineHerdrClient.Offline() }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": Self.screen]]])
    }
}

/// Six workspaces, one with nine tabs and one with six, over split layouts
/// and every agent status.
private enum GridFixture {
    static let repoTools = WorkspaceID(rawValue: "w1")
    /// Six tabs: a resting card already over its cap, so it draws a "+N" tile.
    static let flock = WorkspaceID(rawValue: "w2")
    static let mattstackApps = WorkspaceID(rawValue: "w3")
    /// Three tabs: a resting card still under its visible-tab cap. `src`
    /// holds one pane (a drop from it empties the tab), `build` holds two.
    static let herdr = WorkspaceID(rawValue: "w4")
    static let srcTab = TabID(rawValue: "w4:t1")
    static let buildTab = TabID(rawValue: "w4:t2")
    static let issuesTab = TabID(rawValue: "w4:t3")
    static let srcPane = PaneID(rawValue: "w4:p1")
    static let buildPane = PaneID(rawValue: "w4:p2")
    /// One tab holding one pane: the card whose own drop adds it nothing.
    static let glance = WorkspaceID(rawValue: "w6")
    static let glanceTab = TabID(rawValue: "w6:t1")
    static let glancePane = PaneID(rawValue: "w6:p1")
    static let agentsTab = TabID(rawValue: "w1:t1")
    static let migrationTab = TabID(rawValue: "w2:t1")
    /// Two panes side by side: a tab with a pane to make room and a pane that
    /// must not move.
    static let testsTab = TabID(rawValue: "w2:t2")
    static let claudePane = PaneID(rawValue: "w1:p1")

    private typealias Rect = (x: Int, y: Int, width: Int, height: Int)
    private static let whole: [Rect] = [(0, 0, 80, 24)]
    private static let sideBySide: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 24)]
    private static let stacked: [Rect] = [(0, 0, 80, 12), (0, 12, 80, 12)]
    private static let leftAndStack: [Rect] = [(0, 0, 40, 24), (40, 0, 40, 12), (40, 12, 40, 12)]

    private static let workspaces: [(label: String, status: String, tabs: [(label: String, status: String, shape: [Rect], panes: [(String, String)])])] = [
        ("repo-tools", "working", [
            ("agents", "working", leftAndStack, [("claude", "working"), ("bun test", "done"), ("nvim", "idle")]),
            ("server", "blocked", whole, [("codex", "blocked")]),
            ("scratch", "idle", stacked, [("bun dev", "working"), ("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("bun test", "done"), ("nvim", "idle")]),
            ("docs", "blocked", whole, [("claude", "working")]),
            ("release", "idle", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bench", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
            ("ci", "idle", leftAndStack, [("zsh", "idle"), ("tail -f", "idle"), ("claude", "working")]),
            ("notes", "done", whole, [("zsh", "idle")]),
        ]),
        ("flock", "blocked", [
            ("migration", "working", whole, [("zsh", "idle")]),
            ("tests", "idle", sideBySide, [("tail -f", "idle"), ("claude", "working")]),
            ("design", "done", stacked, [("bun test", "done"), ("nvim", "idle")]),
            ("bridge", "idle", whole, [("zsh", "idle")]),
            ("logs", "blocked", whole, [("tail -f", "blocked")]),
            ("review", "idle", whole, [("codex", "idle")]),
        ]),
        ("mattstack-apps", "done", [
            ("tray", "working", whole, [("codex", "blocked")]),
            ("console", "idle", sideBySide, [("bun dev", "working"), ("zsh", "idle")]),
            ("deck", "done", stacked, [("tail -f", "idle"), ("claude", "working")]),
            ("board", "idle", leftAndStack, [("bun test", "done"), ("nvim", "idle"), ("codex", "blocked")]),
        ]),
        ("herdr", "idle", [
            ("src", "working", whole, [("bun dev", "working")]),
            ("build", "idle", sideBySide, [("zsh", "idle"), ("tail -f", "idle")]),
            ("issues", "done", stacked, [("claude", "working"), ("bun test", "done")]),
        ]),
        ("console", "working", [
            ("dev", "idle", whole, [("nvim", "idle")]),
            ("storybook", "working", sideBySide, [("codex", "blocked"), ("bun dev", "working")]),
        ]),
        ("glance", "idle", [
            ("shell", "idle", whole, [("zsh", "idle")]),
        ]),
    ]

    static func model() throws -> SessionModel {
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        var layouts: [[String: Any]] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspaceID = "w\(workspaceIndex + 1)"
            workspaceRows.append([
                "workspace_id": workspaceID, "label": workspace.label, "number": workspaceIndex + 1,
                "active_tab_id": "\(workspaceID):t1", "agent_status": workspace.status,
            ])
            var paneNumber = 0
            for (tabIndex, tab) in workspace.tabs.enumerated() {
                let tabID = "\(workspaceID):t\(tabIndex + 1)"
                tabRows.append([
                    "tab_id": tabID, "workspace_id": workspaceID, "label": tab.label, "number": tabIndex + 1,
                    "pane_count": tab.panes.count, "agent_status": tab.status,
                ])
                var rects: [[String: Any]] = []
                for (rect, pane) in zip(tab.shape, tab.panes) {
                    paneNumber += 1
                    let paneID = "\(workspaceID):p\(paneNumber)"
                    paneRows.append([
                        "pane_id": paneID, "workspace_id": workspaceID, "tab_id": tabID, "focused": paneID == "w1:p1",
                        "agent_status": pane.1, "revision": 1, "terminal_title_stripped": pane.0,
                        "cwd": NSHomeDirectory() + "/Documents/GitHub/\(workspace.label)",
                    ])
                    rects.append([
                        "pane_id": paneID, "focused": false,
                        "rect": ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height],
                    ])
                }
                layouts.append([
                    "workspace_id": workspaceID, "tab_id": tabID, "zoomed": false,
                    "area": ["x": 0, "y": 0, "width": 80, "height": 24], "panes": rects, "splits": [],
                ])
            }
        }
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t1",
            "focused_pane_id": "w1:p1", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": layouts,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}

private enum Fixture {
    static let canvasPanes = [PaneID(rawValue: "w1:p1"), PaneID(rawValue: "w1:p2")]

    /// `flockTabLabels` replaces the four tabs of the selected workspace, for
    /// a test that needs a title of its own. Four of them either way: the
    /// third is the selected tab the rest of the fixture is written around.
    /// `focusedPaneAgentStatus` overrides only `w1:p2` (every other pane stays
    /// `idle`, the default every existing caller still gets): the one pane a
    /// test can also carry a chat status on, for a fixture with both a status
    /// dot and a chat button on the same legend.
    static func model(
        zoomed: Bool = false, flockTabLabels: [String]? = nil, focusedPaneAgentStatus: String = "idle"
    ) throws -> SessionModel {
        let workspaces: [(id: String, label: String, panes: Int, status: String)] = [
            ("w1", "flock", 5, "idle"), ("w2", "repo-tools", 3, "blocked"), ("w3", "board", 2, "working"),
            ("w4", "mattstack-apps", 4, "done"), ("w5", "herdr", 1, "idle"),
        ]
        var workspaceRows: [[String: Any]] = []
        var tabRows: [[String: Any]] = []
        var paneRows: [[String: Any]] = []
        for (index, workspace) in workspaces.enumerated() {
            let isFlock = workspace.id == "w1"
            let tabLabels = isFlock ? (flockTabLabels ?? ["api", "web", "claude", "logs"]) : ["main"]
            workspaceRows.append([
                "workspace_id": workspace.id, "label": workspace.label, "number": index + 1,
                "active_tab_id": isFlock ? "w1:t3" : "\(workspace.id):t1", "agent_status": workspace.status,
            ])
            for (tabIndex, label) in tabLabels.enumerated() {
                tabRows.append([
                    "tab_id": "\(workspace.id):t\(tabIndex + 1)", "workspace_id": workspace.id, "label": label,
                    "number": tabIndex + 1, "pane_count": 1, "agent_status": "idle",
                ])
            }
            let flockTabs = ["w1:t3", "w1:t3", "w1:t1", "w1:t2", "w1:t4"]
            for paneIndex in 0..<workspace.panes {
                let paneID = "\(workspace.id):p\(paneIndex + 1)"
                paneRows.append([
                    "pane_id": paneID, "workspace_id": workspace.id,
                    "tab_id": isFlock ? flockTabs[paneIndex] : "\(workspace.id):t1",
                    "focused": isFlock && paneIndex == 1,
                    "agent_status": paneID == "w1:p2" ? focusedPaneAgentStatus : "idle", "revision": 1,
                    "terminal_title_stripped": "shell", "cwd": "/private/tmp",
                ])
            }
        }
        let area: [String: Int] = ["x": 0, "y": 0, "width": 120, "height": 40]
        let layout: [String: Any] = [
            "workspace_id": "w1", "tab_id": "w1:t3", "zoomed": zoomed, "area": area, "focused_pane_id": "w1:p2",
            "panes": [
                ["pane_id": "w1:p1", "focused": false, "rect": ["x": 0, "y": 0, "width": 60, "height": 40]],
                ["pane_id": "w1:p2", "focused": true, "rect": ["x": 60, "y": 0, "width": 60, "height": 40]],
            ],
            "splits": [["id": "split_0_root", "direction": "right", "ratio": 0.5, "rect": area]],
        ]
        let snapshot: [String: Any] = [
            "version": "0.8.0", "protocol": 22, "focused_workspace_id": "w1", "focused_tab_id": "w1:t3",
            "focused_pane_id": "w1:p2", "workspaces": workspaceRows, "tabs": tabRows, "panes": paneRows,
            "layouts": [layout],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        return SessionModel(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
    }
}
