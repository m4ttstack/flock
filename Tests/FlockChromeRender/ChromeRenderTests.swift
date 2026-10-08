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
    nonisolated static let defaultsSuite = "dev.mattstack.flock.chrome-render"
    private static let windowSize = CGSize(width: 900, height: 560)
    /// Fixed sample points below the title bar are measured down from it.
    private static let bar = ChromeMetrics.TitleBar.height
    /// The grid's own window. A thumbnail is one fixed width now, so how many
    /// slots a card row holds is the window's answer: 900pt holds three and
    /// every card fixture below is written around the four a 1200pt window
    /// gives. The chrome renders keep `windowSize`, which is what makes them
    /// comparable across rounds.
    private static let gridWindowSize = CGSize(width: 1200, height: 560)
    private static let tallWindowSize = CGSize(width: 900, height: 1000)
    private static let themeIDs = [
        "tokyo-night", "dracula",
        "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
        "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
    ]
    /// A string's drawn width in the handle's own face. Every expectation
    /// about the button's width starts here, because the button's width
    /// starts at the handle's: a name is never abbreviated, so the text sizes
    /// to itself and the button grows around it.
    ///
    /// AppKit's measurement, not SwiftUI's, which has no public equivalent.
    /// The two agree to about a point, so every width assertion built on this
    /// carries a tolerance of `textLayoutSlack` rather than claiming an exact
    /// match it cannot make. What that still catches is the thing worth
    /// catching: a fixed frame, which is off by the whole difference between
    /// the frame and the text, or does not move between two names at all.
    private static let textLayoutSlack: CGFloat = 2

    private static func handleTextWidth(_ text: String) -> CGFloat {
        let font = NSFont(
            name: ChromeType.chatButtonHandleWeight.postScriptName, size: ChromeType.chatButtonHandleSize
        )
        return NSAttributedString(string: text, attributes: [.font: font as Any]).size().width
    }

    /// The signed-in chat button's content-derived width with no unread:
    /// leading and trailing padding around the handle, one gap, the glyph.
    private static func chatButtonNoUnreadWidth(handle: String) -> CGFloat {
        ChromeMetrics.ChatButton.horizontalPadding * 2 + handleTextWidth(handle)
            + ChromeMetrics.ChatButton.gap + ChromeMetrics.ChatButton.iconSize.width
    }

    /// The same button with a count child: one more gap and the count's text.
    private static func chatButtonWithUnreadWidth(handle: String, unread: Int) -> CGFloat {
        chatButtonNoUnreadWidth(handle: handle) + ChromeMetrics.ChatButton.gap + handleTextWidth("\(unread)")
    }

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
    /// sampled against the palette by name, and its frame against the sizes
    /// `measurements.md` gives -- signed out is fixed, signed in is measured
    /// from the render, since its width follows its content. The button is
    /// the only thing in its pane's legend here (idle, unzoomed), so its box
    /// sits flush against the legend's own padding with nothing else to make
    /// room for.
    func testChatButtonRendersSignedInAndSignedOutAtTheirMeasuredSizeAndHex() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        // A minted identity: the button draws the name, never the id, so it
        // measures as "kay" below. "kay.k3f9" would be several glyphs wider.
        let signedInJSON = #"""
        {"handle":"kay.k3f9","name":"kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
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
        let noUnreadSize = CGSize(width: Self.chatButtonNoUnreadWidth(handle: "kay"), height: ChromeMetrics.ChatButton.signedInHeight)
        let signedInFrame = Self.chatButtonFrame(inRawFrame: signedInBox, size: noUnreadSize)
        // Measured against the render, not assumed: this is what catches a
        // fixed frame coming back, which an assumed size cannot.
        let insetBox = PaneBox.frame(in: signedInBox, dividerThickness: DividerBand.gutter)
        let legendY = insetBox.minY + PaneChrome.verticalPadding + ChromeMetrics.ChatButton.signedInHeight / 2
        let scanFrom = insetBox.midX
        let scanTo = insetBox.maxX - PaneChrome.horizontalPadding
        let measuredMinX = try XCTUnwrap(
            firstX(signedInImage, y: legendY, from: scanFrom, to: scanTo, matching: theme.palette.selectionBg.hex),
            "no selectionBg pixel on the legend row -- the chat button did not draw"
        )
        let measuredMaxX = try XCTUnwrap(
            lastX(signedInImage, y: legendY, from: scanFrom, to: scanTo, matching: theme.palette.selectionBg.hex),
            "no selectionBg pixel on the legend row -- the chat button did not draw"
        )
        XCTAssertEqual(
            measuredMaxX - measuredMinX, Self.chatButtonNoUnreadWidth(handle: "kay"), accuracy: Self.textLayoutSlack,
            "signed-in width sized to content with no unread, not a fixed frame"
        )
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
        // The glyph, at its own measured offset past the leading padding and
        // the handle: pad(8) + handle(18) + gap(6) puts the 11pt glyph's
        // center at 37.5.
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: signedInFrame.minX + 37.5, y: signedInFrame.midY)),
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

    /// A handle is somebody's name and is never abbreviated, so the button
    /// grows to hold it.
    ///
    /// The handle used to sit in an 18pt frame taken from the canvas, which is
    /// the width of the one handle the canvas happened to draw. That fits
    /// "nell", whose two `l`s are barely there, and clips "olga" at "o...".
    /// Measuring one handle could never have caught that; this measures two of
    /// the same LENGTH and different widths, which is the actual shape of the
    /// bug.
    func testAWiderHandleGetsAWiderButtonRatherThanAnEllipsis() async throws {
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")

        func buttonWidth(handle: String) async throws -> CGFloat {
            // Two pound signs: the room name puts a `"#` inside the literal,
            // which ends a single-pound raw string right there.
            let json = ##"{"handle":"\##(handle)","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}"##
            let harness = try await Harness(theme: theme, chatAvailable: true, chatStatusJSON: [pane: json])
            let window = harness.makeWindow(size: Self.windowSize)
            defer { window.close() }
            await settle(window)
            let image = try snapshot(window)
            let box = try XCTUnwrap(harness.drag.canvas.paneFrames[pane])
            let insetBox = PaneBox.frame(in: box, dividerThickness: DividerBand.gutter)
            let legendY = insetBox.minY + PaneChrome.verticalPadding + ChromeMetrics.ChatButton.signedInHeight / 2
            let scanFrom = insetBox.midX
            let scanTo = insetBox.maxX - PaneChrome.horizontalPadding
            let fill = theme.palette.selectionBg.hex
            let minX = try XCTUnwrap(firstX(image, y: legendY, from: scanFrom, to: scanTo, matching: fill))
            let maxX = try XCTUnwrap(lastX(image, y: legendY, from: scanFrom, to: scanTo, matching: fill))
            return maxX - minX
        }

        let narrow = try await buttonWidth(handle: "nell")
        let wide = try await buttonWidth(handle: "olga")

        XCTAssertGreaterThan(
            wide, narrow,
            "'olga' and 'nell' are both four characters but not the same width; a button that draws them identically is clipping one"
        )
        XCTAssertEqual(
            wide - narrow, Self.handleTextWidth("olga") - Self.handleTextWidth("nell"), accuracy: Self.textLayoutSlack,
            "the button grew by something other than the difference between the two names"
        )
    }

    /// Measured against the same window with no program holding the mouse, so
    /// whatever else the legend draws on this machine (the rt button follows
    /// the startup PATH) cancels out: only the holder's legend changes.
    func testTheMouseBadgeShowsOnlyOnAPaneWhoseProgramHasTheMouse() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let holder = PaneID(rawValue: "w1:p2")
        let other = PaneID(rawValue: "w1:p1")
        for id in Self.themeIDs {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let quiet = try await Harness(theme: theme)
            let quietWindow = quiet.makeWindow(size: Self.windowSize)
            await settle(quietWindow)
            let before = try snapshot(quietWindow)
            let held = try await Harness(theme: theme, mouseHolders: [holder])
            let heldWindow = held.makeWindow(size: Self.windowSize)
            await settle(heldWindow)
            let after = try snapshot(heldWindow)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("mouse-badge-\(id).png")
                try XCTUnwrap(after.representation(using: .png, properties: [:])).write(to: url)
            }
            for (pane, changes) in [(holder, true), (other, false)] {
                let box = PaneBox.frame(in: try XCTUnwrap(held.drag.canvas.paneFrames[pane]), dividerThickness: DividerBand.gutter)
                let y = box.minY + PaneChrome.verticalPadding + PaneChrome.titleRowHeight / 2
                var changed = false
                var x = box.midX
                while x <= box.maxX - PaneChrome.horizontalPadding, !changed {
                    changed = hex(before, CGPoint(x: x, y: y)) != hex(after, CGPoint(x: x, y: y))
                    x += 0.5
                }
                XCTAssertEqual(changed, changes, "\(id): \(pane.rawValue)'s legend")
            }
            quietWindow.close()
            heldWindow.close()
        }
    }

    /// The badge's right button is lit, in the accent, while right-clicks go
    /// to the program, as a pane starts; a real click on the badge flips it.
    func testTheMouseBadgeLightsItsRightButtonInProgramModeAndAClickFlipsIt() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let holder = PaneID(rawValue: "w1:p2")
        let terminal = TerminalID(rawValue: "term_p2")
        for id in ["tokyo-night", "catppuccin-latte"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            var model = try Fixture.model()
            model.panes[holder]?.terminalID = terminal
            let harness = try await Harness(theme: theme, model: model, mouseHolders: [holder])
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let box = PaneBox.frame(in: try XCTUnwrap(harness.drag.canvas.paneFrames[holder]), dividerThickness: DividerBand.gutter)
            let legend = CGRect(
                x: box.midX, y: box.minY + PaneChrome.verticalPadding,
                width: box.maxX - PaneChrome.horizontalPadding - box.midX, height: PaneChrome.titleRowHeight
            )

            let onProgram = try snapshot(window)
            let lit = try XCTUnwrap(
                firstPixel(onProgram, in: legend, matching: theme.palette.accent.hex), "\(id): a pane starts unlit"
            )

            window.makeKeyAndOrderFront(nil)
            click(window, at: lit)
            await settle(window)
            XCTAssertEqual(harness.viewModel.rightClicks.mode(for: terminal), .menu, "\(id): the click did not flip it")
            let onMenu = try snapshot(window)
            XCTAssertNil(firstPixel(onMenu, in: legend, matching: theme.palette.accent.hex), "\(id): still lit on the menu")
            for (name, image) in [("menu", onMenu), ("program", onProgram)] {
                if let directory {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("mouse-mode-\(name)-\(id).png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            window.close()
        }
    }

    /// The grip's dots sit at the top middle of the title row. A render
    /// harness cannot drive a SwiftUI drag, so where a drag starts is a hand
    /// check.
    func testTheGripDrawsAtTheTopMiddleOfThePane() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let pane = PaneID(rawValue: "w1:p2")
        for id in ["tokyo-night", "catppuccin-latte"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("pane-grip-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            let box = PaneBox.frame(in: try XCTUnwrap(harness.drag.canvas.paneFrames[pane]), dividerThickness: DividerBand.gutter)
            let rowY = box.minY + PaneChrome.verticalPadding + PaneChrome.titleRowHeight / 2
            let pill = ChromeMetrics.Pane.Grip.pillSize
            let dots = CGRect(x: box.midX - pill.width / 2, y: rowY - pill.height / 2, width: pill.width, height: pill.height)
            XCTAssertNotNil(firstPixel(image, in: dots, matching: theme.palette.overlay0.hex), "\(id): no grip drawn")
            window.close()
        }
    }

    private func firstPixel(_ image: NSBitmapImageRep, in rect: CGRect, matching target: String) -> CGPoint? {
        firstPixel(image, in: rect) { $0 == target }
    }

    private func firstPixel(_ image: NSBitmapImageRep, in rect: CGRect, where accepts: (String) -> Bool) -> CGPoint? {
        var y = rect.minY
        while y <= rect.maxY {
            var x = rect.minX
            while x <= rect.maxX {
                if accepts(hex(image, CGPoint(x: x, y: y))) { return CGPoint(x: x, y: y) }
                x += 0.5
            }
            y += 0.5
        }
        return nil
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

    /// Chat is for Claude Code: with chat available, a pane herdr names no
    /// agent for draws no button beside the one that runs Claude. Measured
    /// against the same window with chat unavailable, so whatever else the
    /// legend draws on this machine cancels out.
    func testChatButtonIsAbsentOnAPaneNotRunningClaudeCode() async throws {
        let theme = Theme.tokyoNight
        var images: [NSBitmapImageRep] = []
        var frames: [PaneID: CGRect] = [:]
        for available in [false, true] {
            let harness = try await Harness(
                theme: theme, model: try Fixture.model(focusedPaneAgentStatus: "working"), chatAvailable: available
            )
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            images.append(try snapshot(window))
            frames = harness.drag.canvas.paneFrames
            window.close()
        }
        for (pane, drawn) in [(PaneID(rawValue: "w1:p2"), true), (PaneID(rawValue: "w1:p1"), false)] {
            let box = PaneBox.frame(in: try XCTUnwrap(frames[pane]), dividerThickness: DividerBand.gutter)
            let y = box.minY + PaneChrome.verticalPadding + PaneChrome.titleRowHeight / 2
            var changed = false
            var x = box.midX
            while x <= box.maxX - PaneChrome.horizontalPadding, !changed {
                changed = hex(images[0], CGPoint(x: x, y: y)) != hex(images[1], CGPoint(x: x, y: y))
                x += 0.5
            }
            XCTAssertEqual(changed, drawn, "\(pane.rawValue): a chat button")
        }
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
        {"handle":"kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
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
        let frame = Self.chatButtonFrame(
            inRawFrame: box, size: CGSize(width: Self.chatButtonNoUnreadWidth(handle: "kay"), height: ChromeMetrics.ChatButton.signedInHeight)
        )
        XCTAssertEqual(
            hex(image, CGPoint(x: frame.maxX - 0.5, y: frame.midY)),
            theme.palette.selectionBg.hex, "signed-in fill absent: the button still reads as signed out"
        )
        window.close()
    }

    /// The Count child, at render level rather than only the model: a
    /// fixture pane carrying both a non-idle agent status and a signed-in
    /// chat with unread. The button's frame is not assumed -- it is found by
    /// scanning the legend row's own pixels.
    func testChatButtonDrawsUnread() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        let signedInJSON = #"""
        {"handle":"kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":["#general"]}
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
        let legendY = insetBox.minY + PaneChrome.verticalPadding + ChromeMetrics.ChatButton.signedInHeight / 2
        let scanFrom = insetBox.midX
        let scanTo = insetBox.maxX - PaneChrome.horizontalPadding

        let buttonMaxX = try XCTUnwrap(
            lastX(image, y: legendY, from: scanFrom, to: scanTo, matching: theme.palette.selectionBg.hex),
            "no selectionBg pixel on the legend row -- the chat button did not draw"
        )
        let buttonMinX = try XCTUnwrap(
            firstX(image, y: legendY, from: scanFrom, to: scanTo, matching: theme.palette.selectionBg.hex),
            "no selectionBg pixel on the legend row -- the chat button did not draw"
        )
        // Measured, not assumed: a fixed frame reappearing would widen this
        // past the no-unread button's own measured width instead of matching
        // it, since a fixed frame draws the same width either way.
        XCTAssertEqual(
            buttonMaxX - buttonMinX, Self.chatButtonWithUnreadWidth(handle: "kay", unread: 3), accuracy: Self.textLayoutSlack,
            "signed-in width sized to content with unread present"
        )
        XCTAssertGreaterThan(
            buttonMaxX - buttonMinX, Self.chatButtonNoUnreadWidth(handle: "kay"),
            "the with-unread button is not wider than the empty one -- a fixed frame came back"
        )
        // Leading padding, the handle's own drawn width, a gap, the glyph and
        // another gap: where the count starts is derived rather than written
        // down, because the handle's width is now the text's and a constant
        // here would be a second, stale answer for it.
        //
        // A single digit at this size antialiases across its whole slot with
        // no pixel at full coverage (confirmed by dumping the row: the closest
        // sampled pixel to `palette.text` was #B5BEE9, twelve units off in the
        // worst channel, against a plain background over a hundred units off)
        // -- so this takes the CLOSEST pixel in the slot rather than demanding
        // an exact match, the same tolerance the file's own
        // `channelDistance`/`washDither` pattern uses for opacity blends.
        let countSlotStart = buttonMinX + ChromeMetrics.ChatButton.horizontalPadding
            + Self.handleTextWidth("kay") + ChromeMetrics.ChatButton.gap
            + ChromeMetrics.ChatButton.iconSize.width + ChromeMetrics.ChatButton.gap
        let countDistance = minChannelDistance(
            image, y: legendY, from: countSlotStart, to: countSlotStart + Self.handleTextWidth("3"),
            target: theme.palette.text.hex
        )
        XCTAssertLessThanOrEqual(
            countDistance, 20, "no pixel close enough to palette.text in the count's slot (closest off by \(countDistance))"
        )
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
            theme: theme, status: signedOutStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        XCTAssertEqual(fittingHeight(popover.header), ChromeMetrics.ChatPopover.Header.height, "header band")
        XCTAssertEqual(fittingHeight(popover.statusBlock), ChromeMetrics.ChatPopover.Status.heightSignedOut, "status band, signed out")
        XCTAssertEqual(fittingHeight(popover.featuresBlock), ChromeMetrics.ChatPopover.Features.bandHeight, "features band")
        XCTAssertEqual(fittingHeight(popover.signButtonsBlock), ChromeMetrics.ChatPopover.SignButtons.bandHeight, "sign buttons band")
        XCTAssertEqual(fittingHeight(popover.statusRoute), ChromeMetrics.ChatPopover.signedOutHeight, "signed-out total")

        let signedInPopover = ChatPopover(
            theme: theme, status: signedInStatus, isPresented: .constant(true),
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

    /// The sign button centers its own icon-and-label content rather than
    /// left-anchoring it against a literal `.padding()`: what centering
    /// promises, and what the band-height test above cannot see, is that the
    /// content sits with EQUAL clearance on every side -- never closer than
    /// the measured padding, and never nearer one edge than its opposite.
    /// This finds that content block by its own colour against the button's
    /// fill (not by an assumed position).
    func testSignButtonContentIsCenteredWithAtLeastItsMeasuredPadding() async throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let signedOutStatus = ChatStatus(handle: nil, state: "not signed in", pane: nil, signedIn: false, rooms: [])
        let popover = ChatPopover(
            theme: theme, status: signedOutStatus, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        let window = popoverWindow(popover)
        await settle(window)
        let image = try snapshot(window)

        let bandTop = ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedOut
            + 2 * ChromeMetrics.ChatPopover.SectionLabel.height + ChromeMetrics.ChatPopover.Features.bandHeight
        let buttonHeight = ChromeMetrics.ChatPopover.SignButtons.buttonSize.height
        let buttonWidth = ChromeMetrics.ChatPopover.SignButtons.buttonSize.width
        let buttonLeft = ChromeMetrics.ChatPopover.SignButtons.leadingPadding
        let minHorizontalMargin = ChromeMetrics.ChatPopover.SignButtons.buttonHorizontalPadding
        let minVerticalMargin = ChromeMetrics.ChatPopover.SignButtons.buttonVerticalPadding

        try assertContentCentered(
            image, buttonLeft: buttonLeft, buttonTop: bandTop, width: buttonWidth, height: buttonHeight,
            background: theme.palette.accent.hex, minHorizontalMargin: minHorizontalMargin, minVerticalMargin: minVerticalMargin,
            label: "signed-out Sign in"
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
            theme: theme, status: signedOutStatus, isPresented: .constant(true),
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
        // Where the pane chip used to sit. It named the pane this popover is
        // anchored to, which the legend row above it already says, so the
        // band's own ground is what belongs there now.
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 343, y: 63)), theme.palette.panelBg.hex, "signed-out status band, trailing end")
        XCTAssertLessThanOrEqual(
            hexChannelDistance(hex(signedOutImage, CGPoint(x: 200, y: 165)), theme.palette.panelBg.underHoverWash(theme).hex), 1,
            "signed-out hovered feature row wears the hover wash"
        )
        var bestIconDistance = Int.max
        for y in stride(from: CGFloat(159), through: 171, by: 0.5) {
            bestIconDistance = min(bestIconDistance, minChannelDistance(signedOutImage, y: y, from: 16, to: 30, target: theme.palette.accent.hex))
        }
        XCTAssertLessThanOrEqual(bestIconDistance, 20, "signed-out selected feature icon (closest off by \(bestIconDistance))")
        XCTAssertEqual(hex(signedOutImage, CGPoint(x: 20, y: 292.5)), theme.palette.accent.hex, "signed-out sign button fill, near the leading edge")
        XCTAssertEqual(
            hex(signedOutImage, CGPoint(x: 340, y: 292.5)), theme.palette.accent.hex,
            "signed-out sign button fill spans the band's full inner width"
        )
        signedOutWindow.close()

        let signedInStatus = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: ["#rt", "#flock"])
        let signedInPopover = ChatPopover(
            theme: theme, status: signedInStatus, isPresented: .constant(true),
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
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 343, y: 63)), theme.palette.panelBg.hex, "signed-in status band, trailing end")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 17, y: 87)), theme.palette.activeRowBg.hex, "signed-in room chip fill")
        XCTAssertLessThanOrEqual(
            hexChannelDistance(hex(signedInImage, CGPoint(x: 200, y: 188)), theme.palette.panelBg.underHoverWash(theme).hex), 1,
            "signed-in hovered feature row wears the hover wash"
        )
        var bestSignedInIconDistance = Int.max
        for y in stride(from: CGFloat(182), through: 194, by: 0.5) {
            bestSignedInIconDistance = min(bestSignedInIconDistance, minChannelDistance(signedInImage, y: y, from: 16, to: 30, target: theme.palette.accent.hex))
        }
        XCTAssertLessThanOrEqual(bestSignedInIconDistance, 20, "signed-in selected feature icon (closest off by \(bestSignedInIconDistance))")
        XCTAssertEqual(hex(signedInImage, CGPoint(x: 20, y: 315.5)), theme.palette.accent.hex, "signed-in sign button fill, near the leading edge")
        XCTAssertEqual(
            hex(signedInImage, CGPoint(x: 340, y: 315.5)), theme.palette.accent.hex,
            "signed-in sign button fill spans the band's full inner width"
        )
        signedInWindow.close()
    }

    /// A pane with no status yet is neither signed in nor out: the button
    /// still reads Sign in (the only honest label until a status arrives),
    /// but `.disabled` must actually be wired -- SwiftUI dims a disabled
    /// button's own content on its own, which this tells apart from the
    /// full-strength accent an enabled button paints.
    func testChatPopoverWithNoStatusYetShowsSignInDisabled() async throws {
        ChromeType.install()
        let theme = Theme.tokyoNight
        let popover = ChatPopover(
            theme: theme, status: nil, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        let window = popoverWindow(popover)
        await settle(window)
        let image = try snapshot(window)
        XCTAssertNotEqual(
            hex(image, CGPoint(x: 20, y: 292.5)), theme.palette.accent.hex,
            "a disabled sign button must not paint at full accent strength"
        )
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

    /// Every workspace symbol: a typo'd name resolves to nothing, silently,
    /// and the mark would draw blank.
    func testEveryWorkspaceSymbolResolves() {
        for symbol in WorkspaceSymbols.all {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil), symbol.name)
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

    /// The leftmost `x` (searching `from` to `to`, inclusive) whose pixel
    /// matches `target` exactly, or nil if it never appears in the range --
    /// `lastX(matching:)`'s twin, for measuring a fill's own left edge rather
    /// than assuming a width no fixed frame guarantees any more.
    private func firstX(
        _ image: NSBitmapImageRep, y: CGFloat, from: CGFloat, to: CGFloat, matching target: String, step: CGFloat = 0.25
    ) -> CGFloat? {
        var x = from
        while x <= to {
            if hex(image, CGPoint(x: x, y: y)) == target { return x }
            x += step
        }
        return nil
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

    /// The system title bar's height is the system's, not the chrome's, so
    /// whatever of ours lies inside it must say for itself whether a press
    /// moves the window. The top of the tab strip and the view tabs opt out;
    /// the rest of the chrome title bar drags and double-clicks through
    /// `TitleBarMouseView`, so every other point on it must reach that view.
    func testPressesInsideTheSystemTitleBarReachTheirOwnChrome() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let stripTop = ChromeMetrics.TitleBar.height
        let stripTopEdge = CGPoint(x: 260, y: stripTop + 1)
        XCTAssertTrue(contentViews(at: stripTopEdge, in: window).contains { !$0.mouseDownCanMoveWindow })
        for titlePoint in [CGPoint(x: 450, y: 10), CGPoint(x: 600, y: 30), CGPoint(x: 800, y: 3)] {
            XCTAssertTrue(contentViews(at: titlePoint, in: window).contains { $0 is TitleBarMouseView }, "\(titlePoint)")
        }
        // A view tab inside the system title bar's height still takes its
        // own press rather than moving the window.
        let tabPoint = CGPoint(x: ChromeMetrics.TitleBar.tabsLeadingInset + 20, y: 12)
        XCTAssertTrue(contentViews(at: tabPoint, in: window).contains { !$0.mouseDownCanMoveWindow }, "\(tabPoint)")
        XCTAssertFalse(isInsideScrollView(hitView(at: tabPoint, in: window)), "\(tabPoint) lands in the strip's scroll view")
        window.close()
    }

    /// The All Workspaces grid from fixture layouts, with a mini pane
    /// selected. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set;
    /// the samples and the no-attach check always run.
    func testAllWorkspacesGridRendersFromLayoutsWithoutAttachingAPane() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        harness.modeStore.select(.arrange)
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
        let rest = try snapshot(window)
        assertGridSamples(rest, theme: .tokyoNight)
        harness.drag.selectGridPane(claude.pane)
        await settle(window)
        // The selection outline is drawn against this box, so an outline drawn
        // anywhere else means the grid published a box the layout does not
        // agree with.
        let anchor = try XCTUnwrap(harness.drag.surfaces?.grid?.miniPaneFrame(of: claude.pane))
        XCTAssertEqual(anchor.minX, panes.minX + claude.frame.minX, accuracy: 0.5)
        XCTAssertEqual(anchor.minY, panes.minY + claude.frame.minY, accuracy: 0.5)
        // The tail end to end, through the real decode, on a tile big enough
        // to read (the claude mini pane is below `TileDetail.tail`): a tile
        // that drew and read nothing is what this render exists to catch.
        let tail = try XCTUnwrap(harness.viewModel.paneTails[GridFixture.srcPane], "the tile drew without reading its pane")
        XCTAssertEqual(tail.lines.count, PaneTailPolicy.lines)
        XCTAssertEqual(tail.lines.last, "Editing lib/daemon.ts")
        let selected = try snapshot(window)
        if let directory {
            try XCTUnwrap(selected.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-selected.png"))
        }
        for pane in model.panes.keys where !shownByTheCanvas.contains(pane) {
            XCTAssertNil(harness.viewModel.ghosttySurface(for: pane), "the grid attached \(pane.rawValue)")
        }
        XCTAssertEqual(
            hex(selected, CGPoint(x: anchor.midX, y: anchor.minY + 0.5)), Theme.tokyoNight.palette.accent.hex,
            "the selected pane carries no accent outline"
        )
        window.close()
    }

    /// Selection in a light theme: a click on another pane moves it, Return
    /// opens it in Workspaces, and Esc puts it down without closing the grid.
    func testASelectionMovesOpensAndEscPutsItAwayFirstInALightTheme() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == "catppuccin-latte" })
        let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        harness.modeStore.select(.arrange)
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        harness.drag.selectGridPane(GridFixture.buildPane)
        harness.drag.selectGridPane(GridFixture.claudePane)
        await settle(window)
        XCTAssertEqual(harness.drag.gridSelection, GridFixture.claudePane, "the last click's pane")
        XCTAssertNotNil(harness.viewModel.paneTails[GridFixture.srcPane], "the tile drew without reading its pane")
        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-selected-latte.png"))
        }
        let box = try XCTUnwrap(harness.drag.surfaces?.grid?.miniPaneFrame(of: GridFixture.claudePane))
        XCTAssertEqual(
            hex(image, CGPoint(x: box.midX, y: box.minY + 0.5)), theme.palette.accent.hex,
            "the selected pane carries no accent outline"
        )

        harness.drag.updateGrid { $0.escape() }
        XCTAssertNil(harness.drag.gridSelection)
        XCTAssertTrue(harness.drag.isGridShown, "Esc took the grid down with the selection")
        harness.drag.updateGrid { $0.escape() }
        XCTAssertFalse(harness.drag.isGridShown)
        window.close()
    }

    /// A full-screen TUI wider than its tile, read in herdr's ANSI format: the
    /// tile keeps the colours it was sent, and Copy Output hands back the
    /// plain text. PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
    func testAnArrangeTileDrawsAStyledTUIInItsOwnColours() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let latte = try XCTUnwrap(Theme.builtins.first { $0.id == "catppuccin-latte" })
        for (theme, name) in [(Theme.tokyoNight, "grid-tile-ansi.png"), (latte, "grid-tile-ansi-latte.png")] {
            let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: AnsiTUIClient(), attaching: [])
            harness.modeStore.select(.arrange)
            let window = harness.makeWindow(size: Self.gridWindowSize)
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            await settle(window)

            let tail = try XCTUnwrap(harness.viewModel.paneTails[GridFixture.srcPane], "the tile drew without reading its pane")
            XCTAssertEqual(tail.rows.map(\.columns).max(), AnsiTUIClient.columns)
            XCTAssertEqual(tail.lines.first, " acme switch · 5 accounts")
            XCTAssertFalse(tail.text.unicodeScalars.contains { $0.value == 0x1B }, "an escape reached the copied text")
            let copied = try XCTUnwrap(PaneOutputCopy.text(of: tail), "Copy Output found nothing to copy")
            XCTAssertEqual(copied, tail.text)
            XCTAssertTrue(copied.contains("acme-main"))

            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            // A tile shows the tail's last rows, which here end on the lowest
            // account, whose usage bar is a 24-bit colour: styled text
            // reaches the tile in the colour herdr sent.
            let bar = GhosttyThemeColor(red: 180, green: 120, blue: 255)
            XCTAssertGreaterThan(longestRun(of: bar, in: image), 0, "\(theme.id): no usage bar in the tile")
            window.close()
        }
    }

    /// The longest horizontal run of pixels within `washDither` of `color`,
    /// in device pixels.
    private func longestRun(of color: GhosttyThemeColor, in image: NSBitmapImageRep) -> Int {
        guard let data = image.bitmapData else { return 0 }
        let step = image.bitsPerPixel / 8
        let target = [Int(color.red), Int(color.green), Int(color.blue)]
        var longest = 0
        for y in 0..<image.pixelsHigh {
            var run = 0
            for x in 0..<image.pixelsWide {
                let offset = y * image.bytesPerRow + x * step
                let matches = (0..<3).allSatisfy { abs(Int(data[offset + $0]) - target[$0]) <= Self.washDither }
                run = matches ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
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
        XCTAssertEqual(hex(start, CGPoint(x: 100, y: Self.bar + 48)), hex(end, CGPoint(x: 100, y: Self.bar + 48)), "the rail")
        XCTAssertEqual(hex(start, CGPoint(x: 700, y: 400)), hex(end, CGPoint(x: 700, y: 400)), "the canvas")
        XCTAssertNotEqual(hex(start, CGPoint(x: 210, y: Self.bar + 14)), hex(end, CGPoint(x: 210, y: Self.bar + 14)), "the strip's leading edge")
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

    /// The trailing slot must sit at the tab's own right edge, not wherever
    /// the label happens to end: a one-character label leaves the tab at its
    /// minimum width with slack to spare, and a title too long for the
    /// maximum truncates with none at all. Both must land the slot at the
    /// same formula (`maxX - horizontalPadding - trailingSlot`), which is
    /// what tells a slot that floats with the label apart from one that is
    /// actually pinned to the edge.
    func testTheTrailingSlotSitsAtTheTabsRightEdgeNotAfterTheLabel() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let long = String(repeating: "wide ", count: 20)
        let harness = try await Harness(
            theme: .tokyoNight, model: try Fixture.model(flockTabLabels: ["x", "web", "claude", long])
        )
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let image = try snapshot(window)
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("tab-trailing-slot.png")
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }

        let frames = harness.drag.tabFrames
        let short = try XCTUnwrap(frames.first { $0.id == TabID(rawValue: "w1:t1") }).frame
        let wide = try XCTUnwrap(frames.first { $0.id == TabID(rawValue: "w1:t4") }).frame
        XCTAssertEqual(short.width, TabWidth.minimum, "a one-character label already fits the minimum, so this proves nothing about slack")
        XCTAssertEqual(wide.width, TabWidth.maximum, "the long title fits short of the maximum, so this proves nothing about the clamped case")

        for frame in [short, wide] {
            let slotMaxX = frame.maxX - ChromeMetrics.Tab.horizontalPadding
            let slotMinX = slotMaxX - ChromeMetrics.Tab.trailingSlot
            let dotMinX = slotMinX + (ChromeMetrics.Tab.trailingSlot - ChromeMetrics.Tab.statusDot) / 2
            let distance = minChannelDistance(
                image, y: frame.midY, from: dotMinX, to: dotMinX + ChromeMetrics.Tab.statusDot,
                target: Theme.tokyoNight.palette.green.hex
            )
            XCTAssertLessThanOrEqual(
                distance, 20, "no idle ring found at the tab's right edge, frame \(frame) (closest off by \(distance))"
            )
        }
        window.close()
    }

    /// An unnamed tab holding one pane wears that pane's title behind the
    /// pane glyph, sized for both; a named tab is untouched. PNGs go to
    /// `FLOCK_CHROME_RENDER_DIR`.
    func testAnUnnamedOnePaneTabWearsItsPanesTitleInDarkAndLightThemes() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        var model = try Fixture.model(flockTabLabels: ["1", "web", "claude", "4"])
        let claudeTitle = "✳ Fixing tab sizes"
        model.panes[PaneID(rawValue: "w1:p3")] = PaneRecord(
            paneID: PaneID(rawValue: "w1:p3"), workspaceID: WorkspaceID(rawValue: "w1"), tabID: TabID(rawValue: "w1:t1"),
            focused: false, agentStatus: .idle, revision: 1, terminalTitleStripped: claudeTitle, label: nil,
            cwd: "/private/tmp", scroll: nil
        )
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            let harness = try await Harness(theme: theme, model: model)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            if let directory {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("tab-pane-title-\(scheme).png"))
            }
            let frames = harness.drag.tabFrames
            let width = { (tab: String) in frames.first { $0.id == TabID(rawValue: tab) }?.frame.width }
            XCTAssertEqual(width("w1:t1"), TabSizing.width(of: TabTitle(text: claudeTitle, isFromPane: true)), scheme)
            XCTAssertEqual(width("w1:t4"), TabSizing.width(of: TabTitle(text: "shell", isFromPane: true)), scheme)
            XCTAssertEqual(width("w1:t2"), TabSizing.width(of: "web"), scheme)
            window.close()
        }
    }

    /// Complete tabs, selected and resting, move to the strip's end and lead
    /// with a checkmark; the resting one is compact. PNGs go to
    /// `FLOCK_CHROME_RENDER_DIR`.
    func testACompleteTabWearsACheckmarkInDarkAndLightThemes() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try Fixture.model(flockTabLabels: ["api", "Trash Runner", "claude", "logs"])
        let complete = [TabID(rawValue: "w1:t1"), TabID(rawValue: "w1:t3")]
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            let harness = try await Harness(theme: theme, model: model)
            complete.forEach(harness.viewModel.completedTabs.toggle)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            if let directory {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("tab-complete-\(scheme).png"))
            }
            let frames = harness.drag.tabFrames
            let width = { (tab: String) in frames.first { $0.id == TabID(rawValue: tab) }?.frame.width }
            XCTAssertEqual(width("w1:t1"), TabSizing.width(of: TabTitle(text: "api", isFromPane: false), isComplete: true), scheme)
            XCTAssertEqual(
                width("w1:t3"), TabSizing.width(of: TabTitle(text: "claude", isFromPane: false), isComplete: true, isSelected: true),
                "a selected complete tab is full width; \(scheme)"
            )
            XCTAssertEqual(width("w1:t2"), TabSizing.width(of: "Trash Runner"), scheme)
            XCTAssertEqual(
                frames.sorted { $0.frame.minX < $1.frame.minX }.map(\.id.rawValue), ["w1:t2", "w1:t4", "w1:t1", "w1:t3"],
                "complete tabs follow the open ones; \(scheme)"
            )
            window.close()
        }
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

        // The card's header row: inside the card, and no thumbnail covers it,
        // which is what makes it the card's own empty space.
        let card = try XCTUnwrap(grid.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        harness.drag.move(to: Self.headerGround(of: card))
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
    /// other way. Read through the focused tab's underline, which is drawn
    /// in one strip only: where it sits is where that tab is.
    func testACardOpensTheSlotATabReorderWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.repoTools })
        XCTAssertEqual(card.tabs.map(\.id.rawValue), (1...9).map { "w1:t\($0)" }, "a card draws every tab")
        let first = card.tabs[0].frame
        let second = card.tabs[1].frame
        let cardFrame = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.repoTools }?.frame)

        let atRest = try snapshot(window)
        XCTAssertNotEqual(hex(atRest, Self.focusBarPoint(of: first)), Self.bareHandle, "the focused tab's own handle underline")
        XCTAssertEqual(hex(atRest, Self.focusBarPoint(of: second)), Self.bareHandle, "and no other")

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
            hex(mid, Self.focusBarPoint(of: first)), Self.bareHandle,
            "the first slot still holds the focused tab, so nothing slid"
        )
        XCTAssertNotEqual(
            hex(mid, Self.focusBarPoint(of: second)), Self.bareHandle,
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
        // Tall enough that the glance card, in the grid's third row, is on
        // screen to be dropped on.
        let window = harness.makeWindow(size: CGSize(width: Self.gridWindowSize.width, height: 900))
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        // Three tabs, so every slot the card draws is a real one.
        let cells = try XCTUnwrap(harness.drag.surfaces?.grid?.cardTabs.first { $0.workspace == GridFixture.herdr }?.tabs)
        XCTAssertEqual(cells.map(\.id), [GridFixture.srcTab, GridFixture.buildTab, GridFixture.issuesTab])
        let slots = cells.map(\.frame)

        // From another workspace: the island keeps its three tabs and the
        // created one takes the next slot, which opens a row, since an
        // island is exactly as wide as its own tabs.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.claudePane, harness: harness, window: window,
            opensRowUnder: slots, render: nil, directory: nil
        )
        // From a multi-pane tab of this very island: the same slot, since the
        // tab the pane leaves keeps its other panes.
        try await assertNewTabSlot(
            of: GridFixture.herdr, dragging: GridFixture.buildPane, harness: harness, window: window,
            opensRowUnder: slots, render: nil, directory: nil
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
        follows previous: CGRect? = nil, opensRowUnder row: [CGRect]? = nil, lands: CGRect? = nil,
        render: String?, directory: String?
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
        if let row {
            assertSlotOpensRow(slot, under: row, "\(pane.rawValue): the island's full row")
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
        // The island's own outline, on the edge furthest from the proxy:
        // accent while it takes a drop, the label grey otherwise (it is the
        // focused workspace's island).
        let border = CGPoint(x: card.maxX - ChromeMetrics.selectionOutlineWidth / 2, y: card.midY)
        let atRest = try snapshot(window)
        XCTAssertNotEqual(hex(atRest, border), Theme.tokyoNight.palette.chromeRoles.accent.hex)

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
            hex(mid, Self.focusBarPoint(of: first)), Self.bareHandle,
            "the focused tab left the slot it still holds"
        )
        XCTAssertEqual(
            hex(mid, Self.focusBarPoint(of: cells[1].frame)), Self.bareHandle,
            "a cell slid for a drop that moves nothing"
        )
        window.close()
    }

    /// Every thumbnail in a window is one size, chosen per window: from the
    /// 120pt floor up as the window allows, never shrinking as it widens.
    /// Driven through the real view at four widths, so the fit cannot drift
    /// from the width the islands are actually given: no island's cells run
    /// past its own padding, and no island runs past the canvas padding.
    func testThumbnailsTakeOneSizePerWindowAndNoIslandOverruns() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let height: CGFloat = 1000
        var widths: [CGFloat] = []
        // 900 is the narrowest the app allows (`MainWindow` sets that minimum).
        for width in [Self.windowSize.width, 1200, 1600, 2000] as [CGFloat] {
            let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
            let window = harness.makeWindow(size: CGSize(width: width, height: height))
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let sizes = Set(grid.thumbnails.map { "\(($0.frame.width * 2).rounded())x\(($0.frame.height * 2).rounded())" })
            XCTAssertEqual(sizes.count, 1, "\(width): thumbnails of more than one size: \(sizes)")
            let thumbnail = try XCTUnwrap(grid.thumbnails.first?.frame)
            XCTAssertGreaterThanOrEqual(thumbnail.width, ChromeMetrics.Grid.minimumThumbnailWidth - 0.5, "\(width)")
            XCTAssertLessThanOrEqual(thumbnail.width, ChromeMetrics.Grid.islands.maximumWidth + 0.5, "\(width)")
            for island in grid.cardTabs {
                let frame = try XCTUnwrap(grid.cards.first { $0.id == island.workspace }?.frame)
                for cell in island.tabs {
                    XCTAssertLessThanOrEqual(
                        cell.frame.maxX, frame.maxX - ChromeMetrics.Grid.islands.horizontalPadding + 0.5,
                        "\(width): \(island.workspace.rawValue)'s row ran past its island"
                    )
                }
                XCTAssertLessThanOrEqual(
                    frame.maxX, width - ChromeMetrics.Grid.canvasPadding + 0.5,
                    "\(width): \(island.workspace.rawValue) ran past the canvas"
                )
            }
            widths.append(thumbnail.width)
            if let directory {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-rest-\(Int(width)).png"))
            }
            window.close()
        }
        XCTAssertEqual(widths, widths.sorted(), "a wider window shrank its thumbnails: \(widths)")
        XCTAssertGreaterThan(try XCTUnwrap(widths.last), ChromeMetrics.Grid.minimumThumbnailWidth, "a very wide window left its width unused")
    }

    /// One open Arrange view refits as its window resizes: narrower rewraps
    /// the islands inside the new edge, wider gives the larger fit back, and
    /// a resize under a live drag waits for the drag to end.
    func testArrangeRefitsWhenTheWindowResizesButNotMidDrag() async throws {
        try await resizeArrange(themed: "tokyo-night", renderSuffix: "dark")
        try await resizeArrange(themed: "catppuccin-latte", renderSuffix: "light")
    }

    private func resizeArrange(themed id: String, renderSuffix: String) async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
        let harness = try await Harness(theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        let wide = CGSize(width: 2000, height: 1000)
        let narrow = CGSize(width: Self.windowSize.width, height: 1000)
        let window = harness.makeWindow(size: wide)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        func measure(_ label: String, width: CGFloat) throws -> (thumbnail: CGFloat, rows: Int) {
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid, label)
            let thumbnail = try XCTUnwrap(grid.thumbnails.first?.frame.width, label)
            let cards = grid.cards.map(\.frame)
            for card in cards {
                XCTAssertLessThanOrEqual(card.maxX, width - ChromeMetrics.Grid.canvasPadding + 0.5, "\(label): an island ran past the window")
            }
            let rows = Set(cards.map { ($0.minY * 2).rounded() }).count
            return (thumbnail, rows)
        }

        let opened = try measure("wide", width: wide.width)
        window.setContentSize(narrow)
        await settle(window)
        let shrunk = try measure("narrowed", width: narrow.width)
        if let directory {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-resized-narrow-\(renderSuffix).png"))
        }
        XCTAssertGreaterThan(shrunk.rows, opened.rows, "narrowing the window did not rewrap the islands")
        window.setContentSize(wide)
        await settle(window)
        let regrown = try measure("widened", width: wide.width)
        XCTAssertEqual(regrown.thumbnail, opened.thumbnail, accuracy: 0.5, "widening again did not give the larger fit back")
        XCTAssertEqual(regrown.rows, opened.rows)
        if let directory {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-resized-wide-\(renderSuffix).png"))
        }

        let grabbed = try XCTUnwrap(harness.drag.surfaces?.grid?.miniPaneFrame(of: GridFixture.claudePane))
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: grabbed.size, isCompact: true),
            at: CGPoint(x: grabbed.midX, y: grabbed.midY)
        )
        await settle(window)
        window.setContentSize(CGSize(width: 1400, height: 1000))
        await settle(window)
        let frozen = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first?.frame.width)
        XCTAssertEqual(frozen, regrown.thumbnail, accuracy: 0.5, "the fit changed under a live drag")
        harness.drag.move(to: CGPoint(x: 5, y: 120))
        XCTAssertNil(harness.drag.target, "released where nothing resolves, so nothing commits")
        harness.drag.release()
        for _ in 0..<40 where harness.drag.activeSubject != nil {
            await settle(window)
        }
        XCTAssertNil(harness.drag.activeSubject, "the drag never ended")
        await settle(window)
        let released = try measure("after the drag", width: 1400)
        XCTAssertTrue(
            released.thumbnail != regrown.thumbnail || released.rows != regrown.rows,
            "the resize made during the drag was never applied: \(released) vs \(regrown)"
        )
        window.close()
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

        // A proxy too small to cover anything: at the floor-size thumbnail
        // a pane proxy's minimum size and shadow cover most of the slot,
        // leaving no wash to sample. A miniature is drawn at exactly its
        // footprint, which is what lets this one be 6pt.
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(
                title: "claude", symbol: "macwindow", originSize: CGSize(width: 6, height: 6), isCompact: true,
                tabMiniature: .init(title: "claude", status: .working, isFocusedTab: false, panes: [])
            ),
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
            // Sampled along the bottom of each box, clear of a mini pane's
            // own title row. The flatness pair sits either side of the slot's
            // middle on one line.
            XCTAssertLessThanOrEqual(
                channelDistance(
                    hex(image, CGPoint(x: slot.midX - 4, y: slot.maxY - 4)), hex(image, CGPoint(x: slot.midX + 4, y: slot.maxY - 4))
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
        // Every sample sits along the bottom of its box, below a mini pane's
        // own title row. The flatness pair sits either side of the slot's
        // middle on one line, so the proxy's shadow, which reaches this far
        // down a floor-size thumbnail, falls on both alike.
        XCTAssertEqual(
            hex(image, CGPoint(x: opened.midX - 4, y: opened.maxY - 4)), hex(image, CGPoint(x: opened.midX + 4, y: opened.maxY - 4)),
            "the slot the arriving pane takes is one flat wash"
        )
        XCTAssertNotEqual(
            hex(image, CGPoint(x: opened.midX, y: opened.maxY - 4)), hex(image, CGPoint(x: untouched.midX, y: untouched.maxY - 4)),
            "the slot reads the same as a mini pane still standing there"
        )
        window.close()
    }

    /// A pixel of a thumbnail's handle underline, clear of its title and
    /// status dot. Only the focused tab underlines its handle, so this pixel
    /// says where that tab is drawn.
    private static func focusBarPoint(of thumbnail: CGRect) -> CGPoint {
        CGPoint(
            x: thumbnail.minX + thumbnail.width * 0.7,
            y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight - ChromeMetrics.Grid.currentTabUnderline / 2
        )
    }

    /// A handle with no underline: the thumbnail's own `pane` ground.
    private static let bareHandle = Theme.tokyoNight.palette.chromeRoles.pane.hex

    /// The placeholder's frame against the frames of the tabs it follows,
    /// from real reported frames on both sides: the slot after a card's last
    /// tab, or the start of a new row when that tab ends one.
    func testTheNewTabPlaceholderTakesTheSlotTheTabWillLandIn() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        func lastTab(of workspace: WorkspaceID) throws -> CGRect {
            let frames = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails
                .filter { $0.id.rawValue.hasPrefix("\(workspace.rawValue):") }.map(\.frame))
            return try XCTUnwrap(frames.max { ($0.minY, $0.minX) < ($1.minY, $1.minX) })
        }
        let lastRepoToolsTab = try lastTab(of: GridFixture.repoTools)
        let herdrRow = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails
            .filter { $0.id.rawValue.hasPrefix("\(GridFixture.herdr.rawValue):") }.map(\.frame))
        let fullRow = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails
            .filter { $0.id.rawValue.hasPrefix("\(GridFixture.mattstackApps.rawValue):") }.map(\.frame))
        let fullCard = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)

        let source = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: source.size, isCompact: true),
            at: CGPoint(x: source.midX, y: source.midY)
        )

        // Nine tabs wrap to a second row with slots free beside the ninth.
        try await overEmptySpace(of: GridFixture.repoTools, harness: harness, window: window)
        let repoTools = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)))
        assertSlotFollows(repoTools, lastRepoToolsTab, "the card's last tab")
        if let directory {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-new-tab.png"))
        }

        try await overEmptySpace(of: GridFixture.herdr, harness: harness, window: window)
        XCTAssertNil(harness.drag.gridItemFrame(for: .newTab(GridFixture.repoTools)), "the placeholder left with the card it was over")
        assertSlotOpensRow(
            try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.herdr))), under: herdrRow, "the island's full row"
        )

        // Four tabs fill the row, so the created tab opens a row of its own,
        // and the drop keeps it.
        XCTAssertEqual(Set(fullRow.map(\.minY)).count, 1, "the premise: a card whose tabs fill exactly one row")
        try await overEmptySpace(of: GridFixture.mattstackApps, harness: harness, window: window)
        let opened = try XCTUnwrap(harness.drag.gridItemFrame(for: .newTab(GridFixture.mattstackApps)))
        let first = try XCTUnwrap(fullRow.min { $0.minX < $1.minX })
        XCTAssertEqual(opened.minX, first.minX, accuracy: 0.5, "the new row starts where the full one does")
        XCTAssertEqual(opened.minY, first.maxY + ChromeMetrics.Grid.tabGap, accuracy: 0.5)
        let grown = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == GridFixture.mattstackApps }?.frame)
        XCTAssertEqual(grown.height, fullCard.height + first.height + ChromeMetrics.Grid.tabGap, accuracy: 0.5)
        if let directory {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("grid-drag-new-row.png"))
        }
        window.close()
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
        let refusedSample = CGPoint(x: other.minX + ChromeMetrics.Grid.islands.horizontalPadding / 2, y: refusedGround.y)
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

    /// Mission control's lanes in a dark and a light theme. A pane that went
    /// working to blocked is a Needs-you card wearing the blocked outline,
    /// and, as the first card of the first lane, the selection ring outside it.
    func testMissionControlRendersInDarkAndLight() async throws {
        try await renderMissionControl(themed: "tokyo-night", into: "mission-dark.png")
        try await renderMissionControl(themed: "tokyo-night-day", into: "mission-light.png")
    }

    /// A selection left on a pane that is no longer a card (folded away, or
    /// closed) is replaced by the first card when mission control opens, so
    /// the ring and Return always agree on a card that is drawn.
    func testMissionControlReplacesAStaleSelectionWithTheFirstCard() async throws {
        var model = try GridFixture.model()
        let harness = try await Harness(theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [])
        model.panes[GridFixture.buildPane]?.agentStatus = .blocked
        harness.viewModel.update(model: model, connection: .live)
        harness.modeStore.select(.missionControl)
        harness.modeStore.missionSelection = PaneID(rawValue: "w9:p9")
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)
        XCTAssertEqual(harness.modeStore.missionSelection, GridFixture.buildPane, "the closed pane's id was kept")
        window.close()
    }

    /// Mission control draws no dock, so the stack's sweep cannot live in the
    /// dock: a finished card under a timed lifetime leaves Needs you on time.
    func testMissionControlExpiresAFinishedCardWithNoDockOnScreen() async throws {
        var model = try GridFixture.model()
        let clock = FixtureClock(Date(timeIntervalSince1970: 1_000_000))
        let harness = try await Harness(
            theme: .tokyoNight, model: model, client: GridFixtureClient(), attaching: [],
            now: { clock.date }, notificationLifetime: .fiveSeconds
        )
        model.panes[GridFixture.glancePane]?.agentStatus = .working
        harness.viewModel.update(model: model, connection: .live)
        clock.date = clock.date.addingTimeInterval(60)
        model.panes[GridFixture.glancePane]?.agentStatus = .done
        harness.viewModel.update(model: model, connection: .live)
        XCTAssertNotNil(harness.viewModel.attentionToasts.toast(pane: GridFixture.glancePane), "the premise: a finished card")
        harness.modeStore.select(.missionControl)
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)
        clock.date = clock.date.addingTimeInterval(10)
        await settle(window)
        await settle(window)
        XCTAssertNil(harness.viewModel.attentionToasts.toast(pane: GridFixture.glancePane), "the card outlived its lifetime")
        window.close()
    }

    /// Mission control opens over a terminal that holds the window's first
    /// responder, and a SwiftUI focus request is dropped while an AppKit view
    /// holds it (`FirstResponderClaim`). Arrows and Return still move and open
    /// the selection, and never reach the shell.
    func testMissionControlTakesArrowsFromATerminalHoldingTheKeyboard() async throws {
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        harness.modeStore.select(.missionControl)
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        let terminal = KeyHog(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal), "the premise: the stand-in terminal holds the keyboard")
        harness.drag.toggleGrid()
        await settle(window)
        let first = try XCTUnwrap(harness.modeStore.missionSelection, "the premise: a card is selected")
        pressKey(window, keyCode: 125, character: NSDownArrowFunctionKey)
        await settle(window)
        XCTAssertNotEqual(harness.modeStore.missionSelection, first, "the arrow moved the selection")
        XCTAssertEqual(terminal.keys, 0, "no key reached the terminal")
        window.close()
    }

    /// A card opened from Overview shows its pane in the focused view, in a
    /// dark and a light theme. The view stays up, the card leaves the stack,
    /// and herdr's focus is never asked to move.
    func testFocusedPaneRendersInDarkAndLight() async throws {
        for (id, file) in [("tokyo-night", "focused-dark.png"), ("tokyo-night-day", "focused-light.png")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let client = MethodRecordingClient()
            let (harness, window) = try await focusedOverview(theme: theme, client: client)
            JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore).open(pane: GridFixture.buildPane)
            await settle(window)
            let image = try snapshot(window)
            if let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
            }
            XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.buildPane, "\(id): the card opened in the focused view")
            XCTAssertTrue(harness.drag.isGridShown, "\(id): opening a card closed the view")
            XCTAssertNil(harness.viewModel.attentionToasts.toast(pane: GridFixture.buildPane), "\(id): the opened card is still in the stack")
            let header = CGRect(
                x: 0, y: ChromeMetrics.TitleBar.height, width: Self.gridWindowSize.width / 2, height: ChromeMetrics.Grid.headerHeight
            )
            XCTAssertNotNil(firstPoint(in: header, matching: theme.palette.red.hex, of: image), "\(id): no blocked hue in the header")
            let methods = await client.methods
            for focusing in ["tab.focus", "pane.focus", "workspace.focus"] {
                XCTAssertFalse(methods.contains(focusing), "\(id): opening the card sent \(focusing)")
            }
            window.close()
        }
    }

    /// Back from the focused view is Overview's lanes, with the card that was
    /// open selected.
    func testBackFromTheFocusedPaneSelectsItsCard() async throws {
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: MethodRecordingClient())
        let navigator = JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore)
        navigator.open(pane: GridFixture.buildPane)
        await settle(window)
        XCTAssertTrue(navigator.isFocusedInOverview, "Back to Overview is disabled in the focused view")
        navigator.backToOverview()
        await settle(window)
        XCTAssertNil(harness.drag.gridFocusedPane)
        XCTAssertTrue(harness.drag.isGridShown)
        XCTAssertEqual(harness.modeStore.shown(dragInFlight: false), .missionControl)
        XCTAssertEqual(harness.modeStore.missionSelection, GridFixture.buildPane)
        window.close()
    }

    /// The jump key in the focused view swaps in the next oldest card, and
    /// with none left it leaves the view as it is.
    func testJInTheFocusedViewOpensTheNextCard() async throws {
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: MethodRecordingClient())
        let navigator = JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore)
        XCTAssertEqual(harness.viewModel.oldestAttentionPane, PaneID(rawValue: "w2:p1"), "the premise: the oldest card")
        navigator.open(pane: GridFixture.buildPane)
        await settle(window)
        navigator.openOldest()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, PaneID(rawValue: "w2:p1"))
        navigator.openOldest()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.srcPane)
        XCTAssertNil(harness.viewModel.oldestAttentionPane, "the premise: no card left")
        navigator.openOldest()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.srcPane, "the jump key with no card left changed the view")
        XCTAssertTrue(harness.drag.isGridShown)
        window.close()
    }

    /// Open Next Card swaps in the card the Next chip names, the oldest other
    /// than the shown pane's; with the queue clear it does nothing, and it is
    /// off outside the focused view.
    func testNextInTheFocusedViewOpensTheCardTheChipNames() async throws {
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: MethodRecordingClient())
        let navigator = JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore)
        XCTAssertNil(navigator.nextCard, "Open Next Card is on outside the focused view")
        navigator.open(pane: GridFixture.buildPane)
        await settle(window)
        XCTAssertEqual(navigator.nextCard, PaneID(rawValue: "w2:p1"))
        navigator.openNext()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, PaneID(rawValue: "w2:p1"))
        navigator.openNext()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.srcPane)
        XCTAssertNil(navigator.nextCard, "the premise: the queue is clear")
        navigator.openNext()
        await settle(window)
        XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.srcPane, "Open Next Card with the queue clear changed the view")
        if let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
            try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("focused-queue-clear.png"))
        }
        window.close()
    }

    /// A focused pane that herdr stops reporting leaves the view on
    /// Overview's lanes, never on an empty canvas.
    func testAFocusedPaneThatClosesReturnsToOverview() async throws {
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: MethodRecordingClient())
        JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore).open(pane: GridFixture.buildPane)
        await settle(window)
        XCTAssertEqual(harness.viewModel.paneShownInOverview, GridFixture.buildPane, "the view model does not know the shown pane")
        var model = try XCTUnwrap(harness.viewModel.model)
        model.panes[GridFixture.buildPane] = nil
        harness.viewModel.update(model: model, connection: .live)
        await settle(window)
        XCTAssertNil(harness.drag.gridFocusedPane, "the closed pane is still focused")
        XCTAssertTrue(harness.drag.isGridShown, "the view closed")
        XCTAssertEqual(harness.modeStore.shown(dragInFlight: false), .missionControl)
        XCTAssertNil(harness.viewModel.paneShownInOverview, "the view model still watches the closed pane")
        window.close()
    }

    /// The focused view opens over a terminal holding the keyboard. Esc and
    /// the arrows reach the window's first responder untouched: Overview's
    /// key monitor is not installed, and Esc does not close the view.
    func testEscInTheFocusedViewReachesTheTerminal() async throws {
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: MethodRecordingClient())
        let terminal = KeyHog(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(terminal)
        JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore).open(pane: GridFixture.buildPane)
        await settle(window)
        // Key, so the application hands it the keys its monitors pass on.
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(terminal), "the premise: the stand-in terminal holds the keyboard")
        pressKey(window, keyCode: 53, character: 0x1B)
        await settle(window)
        pressKey(window, keyCode: 125, character: NSDownArrowFunctionKey)
        await settle(window)
        XCTAssertEqual(terminal.keys, 2, "a key did not reach the terminal")
        XCTAssertTrue(harness.drag.isGridShown, "Esc closed the view")
        XCTAssertEqual(harness.drag.gridFocusedPane, GridFixture.buildPane, "Esc left the focused view")
        XCTAssertEqual(harness.modeStore.missionSelection, GridFixture.buildPane, "the arrow moved Overview's selection")
        window.close()
    }

    /// A modal left open from another pane is neither drawn over the focused
    /// view nor closed by leaving it. The shown pane's own modal is drawn
    /// (its backdrop dims the canvas above the box) and back closes it,
    /// without asking herdr to move its focus.
    func testTheFocusedViewDrawsAndClosesOnlyItsOwnPanesRtModal() async throws {
        let client = MethodRecordingClient()
        let (harness, window) = try await focusedOverview(theme: .tokyoNight, client: client)
        let rt = harness.viewModel.rt
        var model = try XCTUnwrap(harness.viewModel.model)
        model.panes[GridFixture.buildPane]?.terminalID = TerminalID(rawValue: "term_build")
        model.panes[GridFixture.srcPane]?.terminalID = TerminalID(rawValue: "term_src")
        harness.viewModel.update(model: model, connection: .live)
        let navigator = JumpNavigator(viewModel: harness.viewModel, drag: harness.drag, mode: harness.modeStore)
        navigator.open(pane: GridFixture.buildPane)
        await settle(window)
        let backdrop = CGPoint(
            x: Self.gridWindowSize.width / 2, y: ChromeMetrics.TitleBar.height + ChromeMetrics.Grid.headerHeight + 12
        )
        let bare = hex(try snapshot(window), backdrop)

        showRtRun(harness.viewModel, linked: "term_src")
        await settle(window)
        XCTAssertEqual(hex(try snapshot(window), backdrop), bare, "another pane's modal is drawn over the shown one")
        navigator.backToOverview()
        await settle(window)
        await rt.settle()
        XCTAssertEqual(rt.modal?.itemID, "run-term_src", "leaving the focused view closed another pane's modal")

        navigator.open(pane: GridFixture.buildPane)
        await settle(window)
        showRtRun(harness.viewModel, linked: "term_build")
        await settle(window)
        XCTAssertNotEqual(hex(try snapshot(window), backdrop), bare, "the shown pane's own modal is not drawn")
        navigator.backToOverview()
        await settle(window)
        await rt.settle()
        XCTAssertNil(rt.modal, "back left the shown pane's modal up")
        let methods = await client.methods
        for focusing in ["tab.focus", "pane.focus", "workspace.focus"] {
            XCTAssertFalse(methods.contains(focusing), "the focused view sent \(focusing)")
        }
        window.close()
    }

    /// An rt run shown in the modal, linked to the pane holding `terminal`.
    private func showRtRun(_ viewModel: SessionViewModel, linked terminal: String) {
        let item = RtItem(
            id: "run-\(terminal)", kind: .run, linked: TerminalID(rawValue: terminal),
            workspaceID: WorkspaceID(rawValue: "rt"), tabID: TabID(rawValue: "rt:\(terminal)"),
            firstPaneID: PaneID(rawValue: "rt:p-\(terminal)"), title: "rt run", folder: "/tmp",
            isRunning: true, started: true, strip: nil
        )
        viewModel.rt.items[item.id] = item
        viewModel.rt.modal = RtModal(itemID: item.id, tabID: item.tabID, serviceTabID: nil)
    }

    /// Overview shown with three Needs-you cards, oldest first: `w2:p1`
    /// finished, the build pane blocked, the src pane finished.
    private func focusedOverview(theme: Theme, client: MethodRecordingClient) async throws -> (Harness, NSWindow) {
        var model = try GridFixture.model()
        let clock = FixtureClock(Date(timeIntervalSince1970: 1_000_000))
        let harness = try await Harness(theme: theme, model: model, client: client, attaching: [], now: { clock.date })
        let steps: [(minute: Double, pane: PaneID, status: AgentStatus)] = [
            (5, GridFixture.glancePane, .working),
            (10, GridFixture.buildPane, .working),
            (20, PaneID(rawValue: "w2:p1"), .working),
            (25, PaneID(rawValue: "w2:p1"), .done),
            (33, GridFixture.buildPane, .blocked),
            (40, GridFixture.srcPane, .done),
        ]
        let launch = clock.date
        for step in steps {
            clock.date = launch.addingTimeInterval(step.minute * 60)
            model.panes[step.pane]?.agentStatus = step.status
            harness.viewModel.update(model: model, connection: .live)
        }
        clock.date = launch.addingTimeInterval(45 * 60)
        harness.modeStore.select(.missionControl)
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)
        return (harness, window)
    }

    /// Opened mid-drag, the view is the drop surface, which is always Arrange,
    /// whatever mode is remembered; the remembered mode is left alone.
    func testOpenedMidDragTheViewDrawsArrangeAndRemembersMissionControl() async throws {
        let harness = try await Harness(theme: .tokyoNight, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [])
        harness.modeStore.select(.missionControl)
        MissionCardFrames.shared.frames = [:]
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.beginIfIdle(
            .pane(GridFixture.claudePane),
            ghost: DragCoordinator.Ghost(title: "claude", symbol: "macwindow", originSize: CGSize(width: 200, height: 120), isCompact: true),
            at: CGPoint(x: 600, y: 300)
        )
        harness.drag.toggleGrid()
        await settle(window)
        XCTAssertFalse(try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails).isEmpty, "Arrange's thumbnails are the drop surface")
        XCTAssertTrue(MissionCardFrames.shared.frames.isEmpty, "no mission-control card was drawn")
        XCTAssertEqual(harness.modeStore.active, .missionControl)
        window.close()
    }

    /// Repo and branch are re-read per open: the hook runs as the grid opens,
    /// before the view is shown, and not as it closes.
    func testOpeningTheGridRunsItsOpenHookBeforeItIsShown() {
        var coordinator: DragCoordinator?
        var shownAtHook: [Bool] = []
        let drag = DragCoordinator(
            toasts: ToastCenter(), rearrangeMode: RearrangeMode(),
            commit: { _, _ in fatalError("never drops") }, reveal: { _ in },
            gridOpened: { shownAtHook.append(coordinator?.isGridShown ?? true) }
        )
        coordinator = drag
        drag.toggleGrid()
        drag.toggleGrid()
        drag.openGrid()
        XCTAssertEqual(shownAtHook, [false, false])
    }

    private func renderMissionControl(themed id: String, into file: String) async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
        var model = try GridFixture.model()
        let clock = FixtureClock(Date(timeIntervalSince1970: 1_000_000))
        let harness = try await Harness(
            theme: theme, model: model, client: GridFixtureClient(), attaching: [], now: { clock.date }, oneTitle: true
        )
        // Minutes into the day after launch, and 45 of them have passed: a
        // pane left alone since launch has no known last change and rests
        // under Unknown, one changed before the last hour under Earlier
        // today, and `w2:p1` under Last hour.
        let steps: [(minute: Double, pane: PaneID, status: AgentStatus)] = [
            (-150, PaneID(rawValue: "w5:p1"), .done),
            (5, GridFixture.glancePane, .working),
            (10, GridFixture.buildPane, .working),
            (25, PaneID(rawValue: "w2:p1"), .done),
            (35, GridFixture.buildPane, .blocked),
            (40, GridFixture.srcPane, .done),
        ]
        let day = clock.date.addingTimeInterval(26 * 3600)
        for step in steps {
            clock.date = day.addingTimeInterval(step.minute * 60)
            model.panes[step.pane]?.agentStatus = step.status
            harness.viewModel.update(model: model, connection: .live)
        }
        clock.date = day.addingTimeInterval(45 * 60)
        harness.modeStore.select(.missionControl)
        MissionCardFrames.shared.frames = [:]
        let window = harness.makeWindow(size: Self.gridWindowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)

        let image = try snapshot(window)
        if let directory {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
        let card = try XCTUnwrap(harness.missionCardFrame(of: GridFixture.buildPane), "the blocked pane is a Needs-you card")
        XCTAssertEqual(harness.modeStore.missionSelection, GridFixture.buildPane, "\(id): the first open selects the top card")
        XCTAssertEqual(
            hex(image, CGPoint(x: card.minX + ChromeMetrics.selectionOutlineWidth / 2, y: card.midY)), theme.palette.accent.hex,
            "\(id): the selected card wears the selection outline, over its blocked one"
        )
        XCTAssertNotEqual(
            hex(image, CGPoint(x: card.minX - 1, y: card.midY)), theme.palette.accent.hex,
            "\(id): the selection outline is drawn inside the card"
        )

        let (board, _) = try XCTUnwrap(MissionBoard.make(
            viewModel: harness.viewModel, board: harness.board, herdProgress: HerdProgressStore(sources: .unanswered),
            opensOlder: false, now: harness.viewModel.currentTime
        ))
        let blocked = try XCTUnwrap(
            board.needsYou.cards.first { $0.status == .blocked && $0.paneID != GridFixture.buildPane },
            "the premise: a second blocked card"
        )
        let blockedCard = try XCTUnwrap(harness.missionCardFrame(of: blocked.paneID))
        XCTAssertEqual(
            hex(image, CGPoint(x: blockedCard.minX + 0.75, y: blockedCard.midY)), theme.palette.red.hex,
            "\(id): a blocked card wears the blocked hue"
        )
        XCTAssertGreaterThanOrEqual(board.atRest.count, 2, "\(id): At rest draws its time sections")
        XCTAssertEqual(board.atRest.first?.age, .lastHour)
        XCTAssertEqual(board.atRest.last?.age, .unknown, "\(id): panes left alone since launch rest under Unknown")
        XCTAssertEqual(board.atRest.first?.groups.flatMap(\.cards).map(\.paneID), [PaneID(rawValue: "w2:p1")])
        let firstWorking = try XCTUnwrap(board.working.first?.cards.first, "the premise: Working holds a group")
        let working = try XCTUnwrap(harness.missionCardFrame(of: firstWorking.paneID))
        XCTAssertNotEqual(
            hex(image, CGPoint(x: working.minX - ChromeMetrics.MissionControl.groupPadding / 2, y: working.midY)),
            theme.palette.chromeRoles.pane.hex,
            "\(id): a Working group sits on the neutral wash, not the lane's ground"
        )
        // Below the card, inside its group's padding, clear of the selection ring.
        XCTAssertNotEqual(
            hex(image, CGPoint(x: card.midX, y: card.maxY + ChromeMetrics.MissionControl.groupPadding - 2)),
            theme.palette.chromeRoles.pane.hex,
            "\(id): a Needs-you card sits in its workspace's group, not on the lane's ground"
        )
        window.close()
    }

    /// The rail's Herds section, expanded and folded, in a dark and a light
    /// theme. Open, a herd with a blocked worker carries a red dot like any
    /// workspace; folded, its rows and their red are gone.
    func testTheHerdsSectionRendersExpandedAndCollapsedWithStatusDots() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_HERDS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let red = theme.palette.red.hex
            let railBox = CGRect(x: 0, y: ChromeMetrics.TitleBar.height, width: RailWidth.default, height: Self.windowSize.height - ChromeMetrics.TitleBar.height)

            let baseline = try await Harness(theme: theme)
            let baselineWindow = baseline.makeWindow(size: Self.windowSize)
            await settle(baselineWindow)
            let baselineRed = count(red, in: railBox, of: try snapshot(baselineWindow))
            baselineWindow.close()
            XCTAssertGreaterThan(baselineRed, 0, "\(id): the blocked workspace's own dot is red")

            let harness = try await Harness(theme: theme, model: try Fixture.herdModel())
            XCTAssertFalse(harness.collapse.isCollapsed(.herds))
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let expanded = try snapshot(window)
            XCTAssertGreaterThan(count(red, in: railBox, of: expanded), baselineRed, "\(id): the blocked herd's row carries a red dot")

            harness.collapse.toggle(.herds)
            await settle(window)
            let collapsed = try snapshot(window)
            XCTAssertEqual(count(red, in: railBox, of: collapsed), baselineRed, "\(id): folded, the herd rows' red goes with them")
            if let directory {
                try XCTUnwrap(expanded.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("herds-rail-expanded-\(scheme)-\(id).png"))
                try XCTUnwrap(collapsed.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("herds-rail-collapsed-\(scheme)-\(id).png"))
            }
            harness.collapse.toggle(.herds)
            window.close()

            let inHerd = try await Harness(theme: theme, model: try Fixture.herdModel(focusing: "h1"), attaching: [])
            let herdWindow = inHerd.makeWindow(size: Self.windowSize)
            await settle(herdWindow)
            let herdSelected = try snapshot(herdWindow)
            let stripBox = CGRect(x: RailWidth.default, y: ChromeMetrics.TitleBar.height, width: Self.windowSize.width - RailWidth.default, height: ChromeMetrics.Strip.height)
            // Quiet in the rail, not once you have gone in: opening a herd is
            // asking to see its workers, and a blocked one still shows it.
            XCTAssertGreaterThan(count(red, in: stripBox, of: herdSelected), 0, "\(id): a herd's blocked worker tab keeps its red dot")
            if let directory {
                try XCTUnwrap(herdSelected.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("herds-herd-selected-\(scheme)-\(id).png"))
            }
            herdWindow.close()
        }
    }

    /// The Board section between the workspaces and Herds, open and folded,
    /// with board's logo and with its fetch failed, in a dark and a light
    /// theme. Folded, the header carries the blocked review's red dot at the
    /// rail's trailing edge; open, the rows carry it and the header does not.
    /// Without the logo, nothing but the logo's own box changes. PNGs are
    /// written only when `FLOCK_BOARD_RENDER_DIR` is set.
    func testTheBoardSectionRendersOpenFoldedAndWithoutItsLogo() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_BOARD_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let railTop = ChromeMetrics.TitleBar.height
        let railBox = CGRect(x: 0, y: railTop, width: RailWidth.default, height: Self.windowSize.height - railTop)
        let trailingEdge = CGRect(x: RailWidth.default - 24, y: railTop, width: 24, height: Self.windowSize.height - railTop)
        let logoColumn = ChromeMetrics.Rail.horizontalPadding...(ChromeMetrics.Rail.horizontalPadding + ChromeMetrics.RailSection.headerMark)
        let logoFill = "#8A5CF6"
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let red = theme.palette.red.hex
            var openRenders: [Bool: NSBitmapImageRep] = [:]
            for withLogo in [true, false] {
                let harness = try await Harness(
                    theme: theme, model: try Fixture.boardModel(),
                    boardSources: .canned(logo: withLogo ? BoardFixture.logo : nil)
                )
                XCTAssertEqual(harness.board.names, BoardFixture.names)
                XCTAssertEqual(harness.board.logo != nil, withLogo)
                XCTAssertFalse(harness.collapse.isCollapsed(.board), "a Board appearing is never folded for you")
                let window = harness.makeWindow(size: Self.windowSize)
                await settle(window)
                let open = try snapshot(window)
                let name = withLogo ? "board" : "board-no-logo"
                XCTAssertEqual(count(red, in: trailingEdge, of: open), 0, "\(name) \(id): an open header carries no dot")
                XCTAssertEqual(
                    count(logoFill, in: railBox, of: open) > 0, withLogo, "\(name) \(id): the logo is drawn exactly when there is one"
                )

                harness.collapse.toggle(.board)
                await settle(window)
                let folded = try snapshot(window)
                XCTAssertGreaterThan(
                    count(red, in: trailingEdge, of: folded), 0, "\(name) \(id): folded, the blocked review's red is at the header's edge"
                )
                harness.collapse.toggle(.board)
                window.close()

                openRenders[withLogo] = open
                if let directory {
                    for (state, image) in [("expanded", open), ("collapsed", folded)] {
                        let file = "\(name)-\(state)-\(scheme)-\(id)"
                        try XCTUnwrap(image.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(file).png"))
                        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                            x: 0, y: 0, width: Int((RailWidth.default + ChromeMetrics.ruleWidth) * 2), height: image.pixelsHigh
                        )))
                        try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(file)-rail.png"))
                    }
                }
            }
            let withLogo = try XCTUnwrap(openRenders[true])
            let without = try XCTUnwrap(openRenders[false])
            XCTAssertEqual(
                differingPixels(withLogo, without, in: railBox, outsideColumns: logoColumn), 0,
                "\(id): without its logo the header keeps every other pixel where it was"
            )
        }
    }

    /// Pixels that differ between two same-sized renders inside `box`,
    /// skipping the columns `excluded` spans, in window points.
    private func differingPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in box: CGRect, outsideColumns excluded: ClosedRange<CGFloat>, scale: CGFloat = 2
    ) -> Int {
        guard let left = a.bitmapData, let right = b.bitmapData, a.bytesPerRow == b.bytesPerRow else { return .max }
        let skip = Int(excluded.lowerBound * scale)...Int((excluded.upperBound * scale).rounded(.up))
        var differing = 0
        for y in Int(box.minY * scale)..<min(Int(box.maxY * scale), a.pixelsHigh) {
            for x in Int(box.minX * scale)..<min(Int(box.maxX * scale), a.pixelsWide) where !skip.contains(x) {
                let offset = y * a.bytesPerRow + x * (a.bitsPerPixel / 8)
                if left[offset] != right[offset] || left[offset + 1] != right[offset + 1] || left[offset + 2] != right[offset + 2] {
                    differing += 1
                }
            }
        }
        return differing
    }

    /// The rail with workspaces, the Herds section and the dock under them,
    /// holding a notice, a card that needs input and a finished one; and the
    /// tallest dock there is, three cards over a "more" pill under a notice
    /// long enough to reach its line limit. At the default rail and the
    /// narrowest, in a dark and a light theme. PNGs are written only when
    /// `FLOCK_DOCK_RENDER_DIR` is set; the geometry below is asserted always.
    func testTheDockSitsUnderTheRailsListsAtEveryRailWidth() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_DOCK_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            for width in [RailWidth.default, RailWidth.minimum] {
                for overflowing in [false, true] {
                    let harness = try await dockHarness(theme: theme, overflowing: overflowing)
                    harness.railWidth.released(at: width)
                    let window = harness.makeWindow(size: Self.windowSize)
                    await settle(window)
                    let image = try snapshot(window)
                    let name = "dock-\(overflowing ? "overflow" : "rest")-\(Int(width))pt-\(scheme)-\(id)"
                    if let directory {
                        try XCTUnwrap(image.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
                        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                            x: 0, y: 0, width: Int((width + ChromeMetrics.ruleWidth) * 2), height: image.pixelsHigh
                        )))
                        try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-rail.png"))
                    }

                    XCTAssertEqual(harness.viewModel.attentionToasts.toasts.count, overflowing ? 5 : 2, name)
                    XCTAssertNotNil(harness.toasts.current, "\(name): the notice expired before the snapshot")

                    // The lists end where the dock begins, and the rail keeps
                    // a real list above even its tallest dock.
                    let railFrame = try XCTUnwrap(harness.drag.railFrame)
                    let viewport = try XCTUnwrap(harness.drag.railViewport)
                    XCTAssertEqual(railFrame.width, width + ChromeMetrics.ruleWidth, accuracy: 0.5, name)
                    XCTAssertEqual(viewport.maxY, railFrame.maxY, accuracy: 0.5, name)
                    XCTAssertGreaterThan(
                        viewport.height, Self.dockFloorForTheLists, "\(name): the dock squeezed the lists to \(viewport.height)pt"
                    )
                    // The dock's top rule runs the rail's width just under the
                    // lists, one step off the chrome it separates.
                    XCTAssertEqual(
                        hex(image, CGPoint(x: width / 2, y: railFrame.maxY + 0.25)), theme.palette.chromeRoles.rule.hex,
                        "\(name): no rule between the lists and the dock"
                    )
                    // Nothing of the dock reaches past the rail's edge into
                    // the canvas: its bottom-left corner beside the rail is
                    // the canvas colour, not a card.
                    XCTAssertEqual(
                        hex(image, CGPoint(x: width + 4, y: Self.windowSize.height - 20)),
                        theme.palette.chromeRoles.canvas.hex, "\(name): something is drawn over the canvas beside the dock"
                    )
                    window.close()
                }
            }
        }
    }

    /// A tall window gives a busy dock more room than the three cards a short
    /// one keeps to, and never more than `DockCapacity.maximumShareOfRail`
    /// of the rail: the lists keep the rest. PNGs go to
    /// `FLOCK_DOCK_RENDER_DIR` as `dock-tall-*`.
    func testABusyDockGrowsIntoATallRailButLeavesTheListsTheirShare() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_DOCK_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            var dockHeights: [CGFloat] = []
            for size in [Self.windowSize, Self.tallWindowSize] {
                let harness = try await dockHarness(theme: theme, overflowing: true)
                let window = harness.makeWindow(size: size)
                await settle(window)
                await settle(window)
                let image = try snapshot(window)
                let name = "dock-tall-\(Int(size.height))-\(scheme)-\(id)"
                if let directory, size == Self.tallWindowSize {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
                }
                let lists = try XCTUnwrap(harness.drag.railFrame)
                let dock = size.height - lists.maxY
                dockHeights.append(dock)
                // A short rail keeps its three cards even past the share;
                // only a rail with room to spare is held to it.
                if size == Self.tallWindowSize {
                    XCTAssertLessThanOrEqual(
                        dock, (lists.height + dock) * DockCapacity.maximumShareOfRail + 1,
                        "\(name): the dock took \(dock)pt of a \(lists.height + dock)pt rail"
                    )
                }
                window.close()
            }
            XCTAssertGreaterThan(dockHeights[1], dockHeights[0] + 40, "\(scheme): the dock did not grow into the tall rail")
        }
    }

    /// Each Settings tab in both system appearances, all one size. PNGs go
    /// to `FLOCK_SETTINGS_RENDER_DIR`.
    func testTheSettingsWindowDrawsInBothAppearances() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_SETTINGS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        defaults.removeObject(forKey: NotificationLifetimeStore.defaultsKey)
        defaults.removeObject(forKey: RearrangeAfterMoveStore.defaultsKey)
        defaults.removeObject(forKey: MissionBottomLineStore.defaultsKey)
        defaults.removeObject(forKey: OneTitleStore.defaultsKey)
        for kind in NewTerminalKind.allCases {
            defaults.removeObject(forKey: StartingFolderStore.defaultsKey(for: kind))
            defaults.removeObject(forKey: StartingFolderStore.customPathKey(for: kind))
        }
        let customSuite = "\(ChromeRenderTests.defaultsSuite).custom"
        defer { UserDefaults().removePersistentDomain(forName: customSuite) }
        let customTab = StartingFolderStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: customSuite)))
        customTab.selectCustom(path: NSHomeDirectory() + "/notes", for: .tab)
        var cases: [(name: String, appearance: NSAppearance.Name, folders: StartingFolderStore, tab: SettingsTab)] = []
        for tab in SettingsTab.allCases {
            cases.append(("\(tab.rawValue)-light", .aqua, StartingFolderStore(userDefaults: defaults), tab))
            cases.append(("\(tab.rawValue)-dark", .darkAqua, StartingFolderStore(userDefaults: defaults), tab))
        }
        cases.append(("custom-tab-light", .aqua, customTab, .general))
        cases.append(("custom-tab-dark", .darkAqua, customTab, .general))
        var tabSizes: Set<CGSize> = []
        for (name, appearance, startingFolderStore, tab) in cases {
            let view = FlockSettingsView(
                herdrMousePatchStore: HerdrMousePatchStore(resolveBinaryPath: { nil }, resolveArtifactPath: { _ in nil }),
                notificationLifetimeStore: NotificationLifetimeStore(userDefaults: defaults),
                missionBottomLineStore: MissionBottomLineStore(userDefaults: defaults),
                overviewReturnStore: OverviewReturnStore(userDefaults: defaults),
                oneTitleStore: OneTitleStore(userDefaults: defaults),
                rearrangeAfterMoveStore: RearrangeAfterMoveStore(userDefaults: defaults),
                startingFolderStore: startingFolderStore,
                rtModalTextSizeStore: RtModalTextSizeStore(userDefaults: defaults),
                commandLineToolStore: CommandLineToolStore(
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent("flock-cli-\(UUID().uuidString)"),
                    executablePath: "/Applications/Flock.app/Contents/MacOS/Flock",
                    name: "flock"
                ),
                tab: tab
            )
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: FlockSettingsView.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            await settle(window)
            let content = window.contentRect(forFrameRect: window.frame).size
            XCTAssertEqual(content.width, FlockSettingsView.size.width, accuracy: 1, "\(name): Settings is not its fixed width")
            tabSizes.insert(host.fittingSize)
            let image = try snapshot(window)
            XCTAssertGreaterThan(image.pixelsWide, 0)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(name).png"))
            }
            window.close()
        }
        XCTAssertEqual(tabSizes.count, 1, "every tab is one size, so switching never moves the window: \(tabSizes)")
    }

    /// The unprompted mouse patch offer under the title bar. PNGs go to
    /// `FLOCK_CHROME_RENDER_DIR`; the assertion is that Install is drawn as a
    /// filled accent pill rather than a system button that fades into the band.
    func testTheMousePatchBannerDrawsInstallAsAnAccentPill() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let herdrDir = FileManager.default.temporaryDirectory.appendingPathComponent("flock-banner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: herdrDir) }
        try FileManager.default.createDirectory(at: herdrDir, withIntermediateDirectories: true)
        let herdr = herdrDir.appendingPathComponent("herdr").path
        let artifact = herdrDir.appendingPathComponent("herdr-patched").path
        try Data("herdr 0.9.3 terminal.mouse_capture".utf8).write(to: URL(fileURLWithPath: artifact))
        let bannerSuite = "flock-banner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bannerSuite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: bannerSuite) }
        let band = CGRect(x: Self.windowSize.width - 200, y: ChromeMetrics.TitleBar.height, width: 200, height: 60)

        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            try? FileManager.default.removeItem(atPath: HerdrMousePatchInstaller.backupPath(for: herdr))
            try Data("herdr 0.9.3 terminal.mouse".utf8).write(to: URL(fileURLWithPath: herdr))
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let store = HerdrMousePatchStore(
                resolveBinaryPath: { herdr }, resolveArtifactPath: { _ in artifact }, defaults: defaults
            )
            XCTAssertTrue(store.shouldOfferBanner, "\(scheme): a plain herdr 0.9.3 should be offered the patch")
            let harness = try await Harness(theme: theme, model: try Fixture.herdModel())
            let window = harness.makeWindow(size: Self.windowSize, herdrMousePatchStore: store)
            for stage in ["offer", "restart"] {
                if stage == "restart" {
                    store.requestInstall()
                    store.confirmPendingAction()
                    XCTAssertEqual(store.restartReason, .installed, "\(scheme): install did not land")
                }
                await settle(window)
                let image = try snapshot(window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("mouse-banner-\(stage)-\(scheme)-\(id).png"))
                }
                XCTAssertGreaterThan(
                    count(theme.palette.accent.hex, in: band, of: image), 200, "\(scheme) \(stage): no filled pill at the right"
                )
            }
            window.close()
        }
    }

    /// Flock Dev's title bar: the DEV tag beside the title, and the restart
    /// offer once a build with another stamp is on disk where this one was
    /// launched from. PNGs go to `FLOCK_DEV_RENDER_DIR`.
    func testFlockDevMarksItsTitleAndOffersARestartForANewerBuild() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_DEV_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let builds = FileManager.default.temporaryDirectory.appendingPathComponent("flock-dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: builds) }
        let bundle = builds.appendingPathComponent("Flock-dev.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["FlockBuildStamp": "2026-09-22 23:10:04 abc1234"], format: .xml, options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let watcher = DevBuildWatcher(bundleURL: bundle, runningStamp: "2026-09-22 22:40:00 fed9876")
            watcher.check()
            XCTAssertTrue(watcher.newerBuildReady, "\(scheme): a different stamp on disk is a newer build")

            let harness = try await Harness(theme: theme, model: try Fixture.herdModel())
            let window = harness.makeWindow(size: Self.windowSize, isDevBuild: true, devBuild: watcher)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("flock-dev-\(scheme)-\(id).png"))
            }
            // The tag and the offer both paint in the theme's amber.
            let amber = theme.palette.yellow.hex
            let titleBar = CGRect(x: 0, y: 0, width: Self.windowSize.width, height: ChromeMetrics.TitleBar.height)
            let centre = CGRect(x: Self.windowSize.width / 2, y: 0, width: 60, height: ChromeMetrics.TitleBar.height)
            let trailing = CGRect(x: Self.windowSize.width - 200, y: 0, width: 200, height: ChromeMetrics.TitleBar.height)
            XCTAssertGreaterThan(count(amber, in: centre, of: image), 0, "\(scheme): no DEV tag beside the title")
            XCTAssertGreaterThan(count(amber, in: trailing, of: image), 0, "\(scheme): no restart offer at the right")
            XCTAssertGreaterThan(count(amber, in: titleBar, of: image), 0)
            // The tab strip's scroll view reaches up through the system title
            // bar's safe area; every point of the pill must still reach the
            // pill rather than that scroll view.
            let pillColumns = stride(from: trailing.minX, to: trailing.maxX, by: 1).filter {
                count(amber, in: CGRect(x: $0, y: 0, width: 1, height: ChromeMetrics.TitleBar.height), of: image) > 0
            }
            let pillStart = try XCTUnwrap(pillColumns.first), pillEnd = try XCTUnwrap(pillColumns.last)
            for x in stride(from: pillStart + 2, to: pillEnd - 1, by: 4) {
                let point = CGPoint(x: x, y: ChromeMetrics.TitleBar.height / 2)
                XCTAssertFalse(isInsideScrollView(hitView(at: point, in: window)), "\(scheme): \(point) lands in a scroll view")
            }
            window.close()
        }
    }

    func testTheSameStampOnDiskOffersNoRestart() throws {
        let builds = FileManager.default.temporaryDirectory.appendingPathComponent("flock-dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: builds) }
        let bundle = builds.appendingPathComponent("Flock-dev.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let stamp = "2026-09-22 22:40:00 fed9876"
        try PropertyListSerialization.data(fromPropertyList: ["FlockBuildStamp": stamp], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let same = DevBuildWatcher(bundleURL: bundle, runningStamp: stamp)
        same.check()
        XCTAssertFalse(same.newerBuildReady)

        // A build dev-build.sh did not stamp (Xcode's own Debug build) never
        // offers anything, whatever lands beside it.
        let unstamped = DevBuildWatcher(bundleURL: bundle, runningStamp: nil)
        unstamped.check()
        XCTAssertFalse(unstamped.newerBuildReady)
    }

    /// The grid covers the rail, so Arrange's dock floats in the corner the
    /// rail would hold, at the rail's width, with flock's notice and none of
    /// the attention cards, which are Overview's Needs you lane. Read against
    /// the same grid with nothing to say: the notice's `chrome` ground
    /// appears there, and the needs-input card's red does not.
    func testOverTheGridTheDockFloatsWhereTheRailWouldBe() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_DOCK_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let theme = Theme.tokyoNight
        let red = theme.palette.red.hex
        let ground = theme.palette.chromeRoles.chrome.hex
        let corner = CGRect(
            x: 0, y: Self.gridWindowSize.height - 220, width: RailWidth.default, height: 220
        )
        var reds: [Int] = []
        var grounds: [Int] = []
        for withMessages in [false, true] {
            let harness = withMessages
                ? try await dockHarness(theme: theme, overflowing: false)
                : try await Harness(theme: theme, model: try Fixture.herdModel())
            let window = harness.makeWindow(size: Self.gridWindowSize)
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            XCTAssertEqual(harness.modeStore.shown(dragInFlight: false), .arrange, "the grid opens on Arrange")
            let image = try snapshot(window)
            reds.append(count(red, in: corner, of: image))
            grounds.append(count(ground, in: corner, of: image))
            if withMessages, let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("dock-over-grid-dark-tokyo-night.png"))
            }
            window.close()
        }
        XCTAssertGreaterThan(
            grounds[1], grounds[0] + 2_000, "no notice in the grid's bottom-left corner: the dock is not there"
        )
        XCTAssertEqual(reds[1], reds[0], "an attention card floated over Arrange")
    }

    /// The least the lists may be left with under the tallest dock, at the
    /// window's own minimum height: about seven rows.
    private static let dockFloorForTheLists: CGFloat = 180

    /// `herdModel()` with the attention cards the dock mock shows, raised in
    /// order so the one that needs input is newest and sits on top, plus a
    /// notice. `overflowing` adds three more cards and a notice that runs to
    /// the line limit.
    private func dockHarness(theme: Theme, overflowing: Bool) async throws -> Harness {
        var base = try Fixture.herdModel()
        let named: [(pane: String, tab: String, title: String, status: AgentStatus)] = [
            ("w2:p1", "pdf-audit", "claude", .idle),
            ("w4:p1", "herd-rail", "codex", .working),
            ("w3:p1", "tray-icons", "claude", .idle),
            ("w5:p1", "release-notes", "claude", .working),
            ("w4:p2", "herd-rail", "bun test", .working),
        ]
        for entry in named {
            let paneID = PaneID(rawValue: entry.pane)
            let pane = try XCTUnwrap(base.panes[paneID])
            base.panes[paneID] = PaneRecord(
                paneID: paneID, workspaceID: pane.workspaceID, tabID: pane.tabID, focused: false,
                agentStatus: entry.status, revision: 1, terminalTitleStripped: entry.title, label: nil,
                cwd: "/private/tmp", scroll: nil
            )
            base.tabs[pane.workspaceID] = base.tabs[pane.workspaceID]?.map { tab in
                guard tab.tabID == pane.tabID else { return tab }
                return TabRecord(
                    tabID: tab.tabID, workspaceID: tab.workspaceID, label: entry.tab, number: tab.number,
                    paneCount: tab.paneCount, agentStatus: tab.agentStatus
                )
            }
        }
        // Frozen, so no finished card is swept before the snapshot.
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        let harness = try await Harness(theme: theme, model: base, now: { frozen })
        var model = base
        func raise(_ pane: String, _ status: AgentStatus) {
            model.panes[PaneID(rawValue: pane)]?.agentStatus = status
            harness.viewModel.update(model: model, connection: .live)
        }
        if overflowing {
            raise("w5:p1", .done)
            raise("w4:p2", .done)
            raise("w3:p1", .blocked)
        }
        raise("w4:p1", .done)
        raise("w2:p1", .blocked)
        harness.toasts.show(
            overflowing
                ? "Undo Move pane partially: the split ratio of the source tab and the focus of the target not undone"
                : "Can't undo: Rename workspace, panes changed"
        )
        return harness
    }

    /// Pixels exactly `hex` inside `box`, in window points.
    private func count(_ hex: String, in box: CGRect, of image: NSBitmapImageRep, scale: CGFloat = 2) -> Int {
        guard let data = image.bitmapData else { return 0 }
        let target = hex.uppercased()
        var hits = 0
        for y in Int(box.minY * scale)..<min(Int(box.maxY * scale), image.pixelsHigh) {
            for x in Int(box.minX * scale)..<min(Int(box.maxX * scale), image.pixelsWide) {
                let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
                if String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2]) == target {
                    hits += 1
                }
            }
        }
        return hits
    }

    /// The main window with Settings > Titles on, over a tab of one pane and
    /// a tab of two. PNGs go to `FLOCK_CHROME_RENDER_DIR`. Alone, the pane's
    /// title row keeps its status chip and draws no title: the tab strip's is
    /// the one title.
    func testOneTitleHidesTheTitleOfAPaneAloneInItsTab() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            for (name, onePane) in [("one-pane", true), ("two-pane", false)] {
                let model = try Fixture.model(onePane: onePane)
                let harness = try await Harness(
                    theme: theme, model: model,
                    attaching: onePane ? [PaneID(rawValue: "w1:p2")] : Fixture.canvasPanes, oneTitle: true
                )
                let pane = try XCTUnwrap(model.panes[PaneID(rawValue: "w1:p2")])
                let shown = PaneNaming.shownTitle(pane: pane, model: model, oneTitle: true)
                XCTAssertEqual(shown == nil, onePane, "\(name): a pane is titled only while it shares its tab")
                let window = harness.makeWindow(size: Self.windowSize)
                await settle(window)
                let image = try snapshot(window)
                XCTAssertGreaterThan(image.pixelsWide, 0)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("titles-\(name)-\(scheme).png"))
                }
                window.close()
            }
        }
    }

    /// Arrange on a roomy window: thumbnails grow past the floor, each island
    /// is tinted off the canvas, and `glance`, left alone since launch, is an
    /// island like every other workspace.
    func testArrangeDrawsTintedIslandsThatFillTheWindow() async throws {
        for (id, file) in [("tokyo-night", "islands-dark.png"), ("tokyo-night-day", "islands-light.png")] {
            let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let clock = FixtureClock(Date(timeIntervalSince1970: 1_000_000))
            let harness = try await Harness(
                theme: theme, model: try GridFixture.model(), client: GridFixtureClient(), attaching: [], now: { clock.date },
                oneTitle: true
            )
            clock.date = clock.date.addingTimeInterval(45 * 60)
            harness.modeStore.select(.arrange)
            let window = harness.makeWindow(size: Self.islandsWindowSize)
            await settle(window)
            harness.drag.toggleGrid()
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
            }
            let grid = try XCTUnwrap(harness.drag.surfaces?.grid)
            let thumbnail = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
            XCTAssertGreaterThan(thumbnail.width, ChromeMetrics.Grid.minimumThumbnailWidth, "\(id): a roomy window buys bigger thumbnails")
            let islandGround = hex(image, CGPoint(x: thumbnail.minX - 8, y: thumbnail.midY))
            XCTAssertNotEqual(islandGround, theme.palette.chromeRoles.canvas.hex, "\(id): the island is tinted, not bare canvas")
            XCTAssertTrue(grid.thumbnails.contains { $0.id == GridFixture.glanceTab }, "\(id): a quiet workspace still draws its tabs")
            let quiet = try XCTUnwrap(grid.thumbnails.first { $0.id == GridFixture.glanceTab }?.frame)
            XCTAssertEqual(
                hex(image, CGPoint(x: quiet.minX - 8, y: quiet.midY)), islandGround,
                "\(id): every island sits on the same neutral wash"
            )
            window.close()
        }
    }

    private static let islandsWindowSize = CGSize(width: 1600, height: 1000)

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

        // The focused tab's handle has no fill, so it is told by the underline.
        let thumbnail = try XCTUnwrap(harness.drag.surfaces?.grid?.thumbnails.first { $0.id == GridFixture.agentsTab }?.frame)
        let underline = hex(image, CGPoint(
            x: thumbnail.midX, y: thumbnail.minY + ChromeMetrics.Grid.tabStripHeight - ChromeMetrics.Grid.currentTabUnderline / 2
        ))
        XCTAssertEqual(underline, theme.palette.accent.hex, "\(id): the focused tab's handle is underlined")
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
        harness.drag.move(to: Self.headerGround(of: target))
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
    /// row: no thumbnail covers it.
    private func overEmptySpace(of workspace: WorkspaceID, harness: Harness, window: NSWindow) async throws {
        let card = try XCTUnwrap(harness.drag.surfaces?.grid?.cards.first { $0.id == workspace }?.frame)
        harness.drag.move(to: Self.headerGround(of: card))
        XCTAssertEqual(harness.drag.target, .workspaceThumbnail(workspace))
        await settle(window)
    }

    /// An island's own empty space: the middle of its header row, which no
    /// thumbnail covers.
    private static func headerGround(of card: CGRect) -> CGPoint {
        CGPoint(
            x: card.midX,
            y: card.minY + ChromeMetrics.Grid.islandTopPadding + ChromeMetrics.Grid.islandHeaderHeight / 2
        )
    }

    /// The first cell of a new row under a full one: the row's leading edge,
    /// one `tabGap` below it, the same size as its cells.
    private func assertSlotOpensRow(_ slot: CGRect, under row: [CGRect], _ label: String) {
        guard let first = row.min(by: { $0.minX < $1.minX }), let bottom = row.map(\.maxY).max() else {
            return XCTFail("\(label): no row")
        }
        XCTAssertEqual(slot.minX, first.minX, accuracy: 0.5, "the leading edge of \(label)")
        XCTAssertEqual(slot.minY, bottom + ChromeMetrics.Grid.tabGap, accuracy: 0.5, "the row under \(label)")
        XCTAssertEqual(slot.width, first.width, accuracy: 0.5, "same width as \(label)")
        XCTAssertEqual(slot.height, first.height, accuracy: 0.5, "same height as \(label)")
    }

    /// Two cells of one row: same top edge and height, one `tabGap` apart.
    private func assertSlotFollows(_ slot: CGRect, _ previous: CGRect, _ label: String) {
        XCTAssertEqual(slot.minY, previous.minY, accuracy: 0.5, "same row as \(label)")
        XCTAssertEqual(slot.height, previous.height, accuracy: 0.5, "same height as \(label)")
        XCTAssertEqual(slot.width, previous.width, accuracy: 0.5, "same width as \(label)")
        XCTAssertEqual(slot.minX, previous.maxX + ChromeMetrics.Grid.tabGap, accuracy: 0.5, "the slot after \(label)")
    }

    /// Points are top-left in the window: the title bar, the grid header over
    /// its rule, and the canvas margin around the islands.
    private func assertGridSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let samples: [(String, CGPoint, RGB)] = [
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/header", CGPoint(x: 450, y: Self.bar + 2), roles.chrome),
            ("rule/header", CGPoint(x: 450, y: Self.bar + ChromeMetrics.Grid.headerHeight + 0.25), roles.rule),
            ("canvas/margin", CGPoint(x: 5, y: Self.bar + 94), roles.canvas),
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
    /// Inside a tab, clear of its label and its rounded top corners.
    private static var tabGroundY: CGFloat { bar + ChromeMetrics.Strip.tabTopClearance + 6 }

    private func assertSamples(_ image: NSBitmapImageRep, theme: Theme) {
        let roles = theme.palette.chromeRoles
        let palette = theme.palette
        let samples: [(String, CGPoint, RGB)] = [
            ("status/selectedRing", CGPoint(x: 21, y: Self.bar + 48), palette.green),
            ("status/selectedHollow", CGPoint(x: 24, y: Self.bar + 48), roles.selection),
            ("status/blocked", CGPoint(x: 24, y: Self.bar + 76), palette.red),
            ("status/working", CGPoint(x: 24, y: Self.bar + 104), palette.yellow),
            ("status/done", CGPoint(x: 24, y: Self.bar + 132), palette.teal),
            ("status/idleRing", CGPoint(x: 21, y: Self.bar + 160), palette.green),
            ("status/idleHollow", CGPoint(x: 24, y: Self.bar + 160), roles.chrome),
            ("chrome/title", CGPoint(x: 600, y: 4), roles.chrome),
            ("chrome/strip", CGPoint(x: 700, y: Self.bar + 4), roles.chrome),
            ("chrome/rail", CGPoint(x: 75, y: 400), roles.chrome),
            ("rule/rail", CGPoint(x: 192.25, y: 400), roles.rule),
            ("selection/row", CGPoint(x: 100, y: Self.bar + 38), roles.selection),
            ("tabRest", CGPoint(x: 253, y: Self.tabGroundY), roles.tabRest),
            ("selection/tab", CGPoint(x: 459, y: Self.tabGroundY), roles.selection),
            ("accent/underline", CGPoint(x: 459, y: Self.bar + ChromeMetrics.Strip.height - 0.75), roles.accent),
            ("rule/strip", CGPoint(x: 700, y: Self.bar + ChromeMetrics.Strip.height + 0.25), roles.rule),
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

    /// The canvas in solo mode shows one pane over the whole canvas, as the
    /// focused view draws it. The fixture's tab is zoomed on `w1:p2` and its
    /// canvas focus is `w1:p2` too, so soloing `w1:p1` fails if either the
    /// layout's own zoom or the main window's focus leaks through: the box
    /// spanning the row must be `w1:p1`'s and must wear the accent border,
    /// with no canvas-coloured gutter anywhere along it and no mauve zoom
    /// badge in its legend. Only `w1:p1`'s program holds the mouse, so its lit
    /// mouse badge in the legend names the pane drawn and shows the legend
    /// controls survive solo. No drag grip is drawn, and nothing is published
    /// to the drag coordinator.
    /// PNGs are written only when `FLOCK_GRID_RENDER_DIR` is set.
    func testASoloCanvasDrawsOnePaneAcrossTheWholeCanvasWithoutAZoomBadge() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_GRID_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let solo = PaneID(rawValue: "w1:p1")
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            let roles = theme.palette.chromeRoles
            var model = try Fixture.model(zoomed: true)
            model.panes[solo]?.terminalID = TerminalID(rawValue: "term_p1")
            let harness = try await Harness(theme: theme, model: model, mouseHolders: [solo])
            let window = harness.makeCanvasWindow(size: Self.windowSize, solo: solo)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("focused-canvas-\(scheme).png"))
            }

            let rowY = Self.windowSize.height / 2
            var accents: [CGFloat] = []
            for x in stride(from: CGFloat(0), to: Self.windowSize.width, by: 0.5)
            where hex(image, CGPoint(x: x, y: rowY)) == roles.accent.hex {
                accents.append(x)
            }
            let first = try XCTUnwrap(accents.first, "\(scheme): no accent border on the row: the solo pane does not hold the keyboard")
            let last = try XCTUnwrap(accents.last)
            let slack = ChromeMetrics.Canvas.margin + DividerBand.gutter + 2
            XCTAssertLessThan(first, slack, "\(scheme): the solo box does not start at the canvas's leading edge")
            XCTAssertGreaterThan(last, Self.windowSize.width - slack, "\(scheme): the solo box does not reach the canvas's trailing edge")
            XCTAssertNil(
                stride(from: first, through: last, by: 0.5).first { hex(image, CGPoint(x: $0, y: rowY)) == roles.canvas.hex },
                "\(scheme): a gutter is drawn inside the solo box: more than one pane is on the canvas"
            )

            let midX = Self.windowSize.width / 2
            let top = try XCTUnwrap(
                stride(from: CGFloat(0), to: Self.windowSize.height / 4, by: 0.5).first { hex(image, CGPoint(x: midX, y: $0)) == roles.accent.hex },
                "\(scheme): the solo box has no accent top border"
            )
            let legend = CGRect(
                x: midX, y: top + PaneChrome.verticalPadding,
                width: last - PaneChrome.horizontalPadding - midX, height: PaneChrome.titleRowHeight
            )
            XCTAssertNotNil(
                firstPoint(in: legend, matching: theme.palette.accent.hex, of: image),
                "\(scheme): no lit mouse badge in the legend: the pane drawn is not \(solo.rawValue), or its controls are gone"
            )
            XCTAssertNil(firstPoint(in: legend, matching: theme.palette.mauve.hex, of: image), "\(scheme): the solo pane wears a zoom badge")
            XCTAssertTrue(harness.drag.canvas.paneFrames.isEmpty, "\(scheme): the solo canvas published frames for drop hit-testing")

            // The same canvas without solo holds `w1:p2` open over the same
            // box, grip and all, so the grip's spot is known to be inked there.
            let tiled = harness.makeCanvasWindow(size: Self.windowSize, solo: nil)
            await settle(tiled)
            let tiledImage = try snapshot(tiled)
            let gripSpot = CGRect(x: midX - 15, y: legend.minY, width: 30, height: legend.height)
            XCTAssertNotNil(
                firstPointDiffering(in: gripSpot, from: roles.pane.hex, of: tiledImage),
                "\(scheme): the canvas without solo draws no grip there, so the check below proves nothing"
            )
            XCTAssertNil(firstPointDiffering(in: gripSpot, from: roles.pane.hex, of: image), "\(scheme): the solo pane draws a drag grip")
            tiled.close()
            window.close()
        }
    }

    /// The solo pane gives the keyboard up to an rt modal opened from it, as
    /// the main canvas does to any modal: its box loses the accent border.
    /// A modal from another pane, never drawn over it, leaves it focused.
    func testASoloPaneYieldsTheKeyboardOnlyToItsOwnRtModal() async throws {
        let solo = PaneID(rawValue: "w1:p1")
        var model = try Fixture.model(zoomed: true)
        model.panes[solo]?.terminalID = TerminalID(rawValue: "term_p1")
        let harness = try await Harness(theme: .tokyoNight, model: model)
        let accent = Theme.tokyoNight.palette.chromeRoles.accent.hex
        let rowY = Self.windowSize.height / 2
        func holdsKeyboard() async throws -> Bool {
            let window = harness.makeCanvasWindow(size: Self.windowSize, solo: solo)
            await settle(window)
            let image = try snapshot(window)
            window.close()
            return stride(from: CGFloat(0), to: Self.windowSize.width, by: 0.5).contains { hex(image, CGPoint(x: $0, y: rowY)) == accent }
        }
        let premise = try await holdsKeyboard()
        XCTAssertTrue(premise, "the premise: the solo pane holds the keyboard")
        showRtRun(harness.viewModel, linked: "term_other")
        let underForeign = try await holdsKeyboard()
        XCTAssertTrue(underForeign, "another pane's modal took the solo pane's keyboard")
        showRtRun(harness.viewModel, linked: "term_p1")
        let underOwn = try await holdsKeyboard()
        XCTAssertFalse(underOwn, "the solo pane kept the keyboard from its own modal")
    }

    private func firstPointDiffering(in rect: CGRect, from target: String, of image: NSBitmapImageRep) -> CGPoint? {
        for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) where hex(image, CGPoint(x: x, y: y)) != target {
                return CGPoint(x: x, y: y)
            }
        }
        return nil
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
        let tabPoint = CGPoint(x: 459, y: Self.tabGroundY)
        let railPoint = CGPoint(x: 100, y: Self.bar + 38)
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
        let legend = CGRect(x: 552, y: Self.bar + 40, width: 342, height: 26)
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

    /// Idle and unknown panes wear a chip too, so the title row always
    /// carries a status. Read just inside the chip's top-leading corner,
    /// above any glyph: a pane with no chip shows the pane ground there.
    func testEveryPaneWearsAStatusChip() async throws {
        let theme = Theme.tokyoNight
        let pane = PaneID(rawValue: "w1:p2")
        for status in ["idle", "unknown", "working"] {
            let harness = try await Harness(theme: theme, model: try Fixture.model(focusedPaneAgentStatus: status))
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            let box = PaneBox.frame(in: try XCTUnwrap(harness.drag.canvas.paneFrames[pane]), dividerThickness: DividerBand.gutter)
            let fill = CGPoint(
                x: box.minX + PaneChrome.horizontalPadding + 4,
                y: box.minY + PaneChrome.verticalPadding + 1.5
            )
            XCTAssertNotEqual(hex(image, fill), theme.palette.chromeRoles.pane.hex, "\(status): no status chip at the title's leading edge")
            window.close()
        }
    }

    /// The status chip leads the title and the zoom badge stays in the
    /// trailing corner. The same zoomed window is drawn idle and working: the
    /// chip is the only difference, so every changed pixel has to land in
    /// the row's leading half, which the badge never moves for. PNGs of both
    /// schemes are written only when `FLOCK_CHROME_RENDER_DIR` is set.
    func testTheStatusChipLeadsTheTitleAndTheZoomBadgeStaysTrailing() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let pane = PaneID(rawValue: "w1:p2")
        for (theme, scheme) in [(Theme.tokyoNight, "dark"), (Theme(.tokyoNightDay), "light")] {
            var images: [NSBitmapImageRep] = []
            var frame: CGRect?
            for status in ["idle", "working"] {
                let harness = try await Harness(theme: theme, model: try Fixture.model(zoomed: true, focusedPaneAgentStatus: status))
                let window = harness.makeWindow(size: Self.windowSize)
                await settle(window)
                images.append(try snapshot(window))
                frame = harness.drag.canvas.paneFrames[pane]
                window.close()
            }
            if let directory {
                try XCTUnwrap(images[1].representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("zoom-badge-status-\(scheme).png"))
            }
            let box = PaneBox.frame(in: try XCTUnwrap(frame), dividerThickness: DividerBand.gutter)
            let row = CGRect(
                x: box.minX, y: box.minY + PaneChrome.verticalPadding,
                width: box.width, height: PaneChrome.titleRowHeight
            )
            let trailingHalf = CGRect(x: box.midX, y: row.minY, width: box.width / 2, height: row.height)
            XCTAssertNotNil(firstX(in: trailingHalf, matching: theme.palette.mauve.hex, of: images[1]), "\(scheme): no zoom badge in the trailing corner")
            var chipEnd: CGFloat?
            for y in stride(from: row.minY, to: row.maxY, by: 0.5) {
                for x in stride(from: row.minX, to: row.maxX, by: 0.5)
                where hex(images[0], CGPoint(x: x, y: y)) != hex(images[1], CGPoint(x: x, y: y)) {
                    chipEnd = max(chipEnd ?? x, x)
                }
            }
            XCTAssertLessThan(try XCTUnwrap(chipEnd, "\(scheme): no status chip drew"), box.midX, "\(scheme): the status chip is not beside the title")
        }
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
    /// code. The check is the status hue appearing at the foot of the rail,
    /// where the dock sits, against the same stretch at rest -- a single pixel
    /// is not nameable on a mark this small with a glow behind it -- and never
    /// appearing in the bottom-right corner over the panes, where the stack
    /// used to float.
    func testTheAttentionStackDocksAtTheFootOfTheRailAndOverflowsToAPill() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        // The foot of the default rail in a 900x560 window, clear of the five
        // rows at its top, and the canvas's bottom-right corner.
        let railFoot = CGRect(x: 0, y: 320, width: RailWidth.default, height: 240)
        let corner = CGRect(x: 600, y: 320, width: 300, height: 240)
        let red = Theme.tokyoNight.palette.red.hex

        let resting = try await Harness(theme: .tokyoNight, model: try Fixture.model())
        let restingWindow = resting.makeWindow(size: Self.windowSize)
        await settle(restingWindow)
        let restingImage = try snapshot(restingWindow)
        let restingRailFrame = try XCTUnwrap(resting.drag.railFrame)

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
        XCTAssertEqual(harness.viewModel.attentionToasts.visible(limit: AttentionToastStack.minimumVisible).count, 3)
        XCTAssertEqual(harness.viewModel.attentionToasts.collapsedCount(limit: AttentionToastStack.minimumVisible), 1)
        XCTAssertNil(
            firstPoint(in: railFoot, matching: red, of: restingImage),
            "the resting rail foot already carries the status hue, so the check below proves nothing"
        )
        let docked = try XCTUnwrap(
            firstPoint(in: railFoot, matching: red, of: image),
            "no \(red) anywhere at the foot of the rail: the dock did not paint"
        )
        XCTAssertNil(
            firstPoint(in: corner, matching: red, of: image),
            "the status hue is still in the bottom-right corner: something floats over the panes"
        )

        // The lists shortened to make room rather than running on under the
        // dock, and the frame every rail drop is measured against stops
        // where they do.
        let railFrame = try XCTUnwrap(harness.drag.railFrame)
        let viewport = try XCTUnwrap(harness.drag.railViewport)
        XCTAssertLessThan(railFrame.maxY, restingRailFrame.maxY, "the lists kept their full height under the dock")
        XCTAssertLessThanOrEqual(railFrame.maxY, docked.y, "the rail's drop frame reaches into the dock")
        XCTAssertLessThanOrEqual(viewport.maxY, docked.y, "the rows' viewport runs on under the dock")
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

    private func firstX(in rect: CGRect, matching target: String, of image: NSBitmapImageRep) -> CGFloat? {
        var first: CGFloat?
        for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) where hex(image, CGPoint(x: x, y: y)) == target {
                first = min(first ?? x, x)
            }
        }
        return first
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
    /// The view AppKit would deliver a press at `point` to, from the window's
    /// frame view down, so the title bar's own views compete too.
    private func hitView(at point: CGPoint, in window: NSWindow) -> NSView? {
        guard let frameView = window.contentView?.superview else { return nil }
        let windowPoint = NSPoint(x: point.x, y: window.frame.height - point.y)
        return frameView.hitTest(frameView.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }

    private func isInsideScrollView(_ view: NSView?) -> Bool {
        sequence(first: view, next: { $0?.superview }).contains { $0 is NSScrollView }
    }

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

    /// Where the palette box's top lands in the window: the root is taller
    /// than `windowSize` by the system title bar, so the tab area is read
    /// from the window rather than worked out from the size asked for.
    private func paletteTop(_ window: NSWindow) -> CGFloat {
        let height = window.contentView?.bounds.height ?? Self.windowSize.height
        return ChromeMetrics.TitleBar.height + ChromeMetrics.Palette.top(inTabAreaHeight: height - ChromeMetrics.TitleBar.height)
    }

    /// The full-height palette (an empty search, the list at its maximum) is
    /// centred in the pane area below the tab strip, and never rides up
    /// under the strip in a short window.
    func testTheFullHeightPaletteIsCentredInThePaneArea() {
        let metrics = ChromeMetrics.Palette.self
        let tabArea: CGFloat = 800
        let top = metrics.top(inTabAreaHeight: tabArea)
        let paneArea = tabArea - ChromeMetrics.Strip.height
        let above = top - ChromeMetrics.Strip.height
        let below = paneArea - above - metrics.fullHeight
        XCTAssertEqual(above, below, accuracy: 0.5)
        XCTAssertEqual(metrics.top(inTabAreaHeight: 300), ChromeMetrics.Strip.height + metrics.minTop)
    }

    /// The palette over the window, empty and with a typed query, in both
    /// themes: its ground, a selected first row, and the match highlight.
    func testThePaletteDrawsOverTheTabAreaWithItsRowsAndHighlight() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            harness.palette.open()
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let empty = try snapshot(window)
            harness.palette.query = "rearr"
            await settle(window)
            let typed = try snapshot(window)
            if let directory {
                for (name, image) in [("empty", empty), ("typed", typed)] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("palette-\(name)-\(id).png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            let rows = try paletteRows(harness, window)
            XCTAssertNotNil(firstPixel(empty, in: rows, matching: theme.palette.chromeRoles.selection.hex), "\(id): no selected row")
            XCTAssertNotNil(
                firstPixel(typed, in: firstRowName(harness, window), near: theme.palette.accent.hex, within: Self.glyphEdgeTolerance),
                "\(id): no highlighted letters"
            )
            window.close()
        }
    }

    /// ⌃Tab's panel, in both themes: the current workspace on top, the last
    /// one used selected under it, centred in the pane area.
    func testTheWorkspaceSwitcherSelectsTheLastWorkspaceUnderTheCurrentOne() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let workspaces = try XCTUnwrap(harness.viewModel.model?.workspaces.map(\.workspaceID))
            let current = try XCTUnwrap(harness.viewModel.selectedWorkspaceID)
            let last = try XCTUnwrap(workspaces.last { $0 != current })
            harness.switcher.note(last)
            harness.switcher.note(current)
            XCTAssertTrue(harness.switcher.begin(workspaces: workspaces, current: current))
            harness.switcher.show(session: harness.switcher.session)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("switcher-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            XCTAssertEqual(harness.switcher.selected, last)
            typealias Metrics = ChromeMetrics.Palette
            let height = try XCTUnwrap(window.contentView?.bounds.height)
            let top = ChromeMetrics.TitleBar.height + ChromeMetrics.Switcher.top(
                inTabAreaHeight: height - ChromeMetrics.TitleBar.height, rowCount: workspaces.count
            )
            let rail = harness.railWidth.width
            let x = rail + (Self.windowSize.width - rail) / 2 + ChromeMetrics.Switcher.width / 4
            let selected = try XCTUnwrap(
                firstPixel(image, in: CGRect(x: x, y: top, width: 0, height: 200), matching: theme.palette.chromeRoles.selection.hex),
                "\(id): no selected row"
            )
            let secondRow = top + ChromeMetrics.Switcher.headerHeight + ChromeMetrics.ruleWidth + Metrics.listPadding + Metrics.rowHeight + 1
            XCTAssertEqual(selected.y, secondRow, accuracy: 1.5, "\(id): the selection is not on the second row")
            window.close()
        }
    }

    /// ⌥Tab's panel is ⌃Tab's over the selected workspace's tabs: the current
    /// tab on top, the last one used selected under it.
    func testTheTabSwitcherSelectsTheLastTabUnderTheCurrentOne() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let tabs = harness.viewModel.tabsForSelectedWorkspace.map(\.tabID)
            XCTAssertGreaterThan(tabs.count, 1, "the fixture's selected workspace needs a second tab")
            let current = try XCTUnwrap(harness.viewModel.selectedTabID)
            let last = try XCTUnwrap(tabs.last { $0 != current })
            harness.tabSwitcher.note(last)
            harness.tabSwitcher.note(current)
            XCTAssertTrue(harness.tabSwitcher.begin(items: tabs, current: current))
            harness.tabSwitcher.show(session: harness.tabSwitcher.session)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("tab-switcher-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            XCTAssertEqual(harness.tabSwitcher.selected, last)
            XCTAssertEqual(harness.tabSwitcher.order.first, current)
            window.close()
        }
    }

    /// Two people signed in to chat in the selected tab and one in another:
    /// each row names its tab's first in reading order, with how many more,
    /// in the wider box chat earns. PNGs go to `FLOCK_CHROME_RENDER_DIR`.
    func testTheTabSwitcherNamesWhoIsSignedInToChat() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let buddy = { (handle: String, name: String, pane: String) in
            #"{"handle":"\#(handle)","name":"\#(name)","paneId":"\#(pane)","status":"online","unread":0,"mentions":0}"#
        }
        let peek = #"{"buddies":[\#(buddy("@oak-claude", "oak", "w1:p2")),\#(buddy("@ivy-claude", "ivy", "w1:p1")),\#(buddy("@fern-codex", "fern", "w1:p4"))],"rooms":[]}"#
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme, chatAvailable: true, chatPeekJSON: peek)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let model = try XCTUnwrap(harness.viewModel.model)
            let tabs = harness.viewModel.tabsForSelectedWorkspace
            let label = { (tab: String) in
                tabs.first { $0.tabID == TabID(rawValue: tab) }.flatMap {
                    TabChatPresence.label(for: $0, in: model, buddies: harness.chatStore.buddies)
                }
            }
            XCTAssertEqual(label("w1:t3"), "ivy · 1 more", "\(id): the left pane reads first")
            XCTAssertEqual(label("w1:t2"), "fern", id)
            XCTAssertNil(label("w1:t1"), id)

            let current = try XCTUnwrap(harness.viewModel.selectedTabID)
            XCTAssertTrue(harness.tabSwitcher.begin(items: tabs.map(\.tabID), current: current))
            harness.tabSwitcher.show(session: harness.tabSwitcher.session)
            await settle(window)
            if let directory {
                try XCTUnwrap(try snapshot(window).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("tab-switcher-chat-\(id).png"))
            }
            window.close()
        }
    }

    /// More workspaces than fit: the box keeps its margins, draws no scroll
    /// bar, and scrolls the selection into view at the far end of the list.
    func testALongSwitcherListKeepsItsMarginsAndItsSelectionInView() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        var model = try Fixture.model()
        for index in 1...20 {
            let workspace = WorkspaceID(rawValue: "x\(index)")
            let tab = TabID(rawValue: "x\(index):t1")
            model.workspaces.append(WorkspaceRecord(
                workspaceID: workspace, label: "acme-\(index)", number: model.workspaces.count + 1,
                activeTabID: tab, agentStatus: .idle
            ))
            model.tabs[workspace] = [TabRecord(
                tabID: tab, workspaceID: workspace, label: "main", number: 1, paneCount: 1, agentStatus: .idle
            )]
        }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme, model: model)
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let workspaces = try XCTUnwrap(harness.viewModel.model?.workspaces.map(\.workspaceID))
            XCTAssertTrue(harness.switcher.begin(workspaces: workspaces, current: harness.viewModel.selectedWorkspaceID, reverse: true))
            harness.switcher.show(session: harness.switcher.session)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("switcher-long-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            let tabArea = try XCTUnwrap(window.contentView?.bounds.height) - ChromeMetrics.TitleBar.height
            let top = ChromeMetrics.Switcher.top(inTabAreaHeight: tabArea, rowCount: workspaces.count)
            XCTAssertGreaterThanOrEqual(top, ChromeMetrics.Strip.height + ChromeMetrics.Switcher.margin - 0.5, "\(id): the box rides into its top margin")
            let listTop = ChromeMetrics.TitleBar.height + top + ChromeMetrics.Switcher.headerHeight + ChromeMetrics.ruleWidth
            let listHeight = ChromeMetrics.Switcher.maxListHeight(inTabAreaHeight: tabArea)
            let rail = harness.railWidth.width
            let x = rail + (Self.windowSize.width - rail) / 2 + ChromeMetrics.Switcher.width / 4
            let selected = try XCTUnwrap(
                firstPixel(image, in: CGRect(x: x, y: listTop, width: 0, height: listHeight), matching: theme.palette.chromeRoles.selection.hex),
                "\(id): the last row's selection is not in view"
            )
            XCTAssertGreaterThan(selected.y, listTop + listHeight / 2, "\(id): the list did not scroll to its last row")
            let boxRight = rail + (Self.windowSize.width - rail + ChromeMetrics.Switcher.width) / 2
            let rowEnd = CGPoint(x: boxRight - ChromeMetrics.Palette.listPadding - 3, y: selected.y + ChromeMetrics.Palette.rowHeight / 2)
            XCTAssertLessThanOrEqual(
                channelDistance(hex(image, rowEnd), theme.palette.chromeRoles.selection.hex), 6, "\(id): a scroll gutter cuts the row short"
            )
            let belowRow = CGPoint(x: x, y: selected.y + ChromeMetrics.Palette.rowHeight + 2)
            XCTAssertNotEqual(hex(image, belowRow), theme.palette.chromeRoles.rule.hex, "\(id): the last row sits on the footer rule")
            window.close()
        }
    }

    /// A click on a row runs it and closes the palette first.
    func testClickingARowRunsItAndClosesThePalette() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        harness.palette.query = "rearrange"
        let window = harness.makeWindow(size: Self.windowSize)
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        let image = try snapshot(window)
        let row = try XCTUnwrap(
            firstPixel(image, in: try paletteRows(harness, window), matching: Theme.tokyoNight.palette.chromeRoles.selection.hex)
        )
        click(window, at: row)
        await settle(window)
        XCTAssertFalse(harness.palette.isOpen)
        XCTAssertTrue(harness.rearrange.isToggled)
        XCTAssertEqual(harness.paletteRecents.ids.first, "view.rearrangemode")
        window.close()
    }

    /// The grid replaces the tab area the palette draws over, so showing it
    /// closes the palette rather than leaving it open and unseen.
    func testShowingTheGridClosesThePalette() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.drag.toggleGrid()
        await settle(window)
        XCTAssertTrue(harness.drag.isGridShown)
        XCTAssertFalse(harness.palette.isOpen)
        window.close()
    }

    /// A rename editor opened from the live rail takes Return and Esc, so the
    /// palette gives way to it.
    func testARenameEditorClosesThePalette() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        harness.viewModel.beginRename(.workspace(WorkspaceID(rawValue: "w1")))
        await settle(window)
        XCTAssertTrue(harness.viewModel.renameEditorIsOnScreen)
        XCTAssertFalse(harness.palette.isOpen)
        window.close()
    }

    /// The badge is as wide as the widest namespace word, so "workspace"
    /// draws whole rather than tail-truncated.
    func testThePaletteBadgeDrawsTheWholeNamespaceWord() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let font = try XCTUnwrap(NSFont(name: ChromeType.Weight.semibold.postScriptName, size: 10.5))
        let word = NSAttributedString(string: PaletteNamespace.workspace.rawValue, attributes: [.font: font]).size().width
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            harness.palette.open()
            harness.palette.query = "new work"
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            XCTAssertEqual(rankedRows(harness).first?.command.namespace, .workspace, "\(id): New Workspace is not the first row")
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("palette-badge-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            let fill = ChromeRoles.isLight(panelBg: theme.palette.panelBg) ? theme.palette.surface1.hex : theme.palette.surface0.hex
            let badge = firstRowBadge(harness, window)
            var inked: [CGFloat] = []
            var y = badge.minY + ChromeMetrics.Palette.badgeCornerRadius
            while y <= badge.maxY - ChromeMetrics.Palette.badgeCornerRadius {
                var x = badge.minX + 1
                while x <= badge.maxX - 1 {
                    let sample = hex(image, CGPoint(x: x, y: y))
                    if sample != "?", channelDistance(sample, fill) > 30 { inked.append(x) }
                    x += 0.5
                }
                y += 0.5
            }
            let drawn = (inked.max() ?? 0) - (inked.min() ?? 0)
            XCTAssertGreaterThan(drawn, word - 4, "\(id): the badge draws \(drawn)pt of a \(word)pt word")
            window.close()
        }
    }

    /// ↓ moves the selection and Return runs the selected row, through the
    /// palette's key monitor rather than a click.
    func testArrowDownThenReturnRunsTheSecondRow() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        harness.palette.query = "re"
        let window = harness.makeWindow(size: Self.windowSize)
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        let rows = rankedRows(harness)
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows.dropFirst().first?.command.id, "view.rearrangemode")
        press(window, keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        await settle(window)
        XCTAssertEqual(harness.palette.selection, 1)
        XCTAssertTrue(harness.palette.isOpen)
        press(window, keyCode: 36, characters: "\r")
        await settle(window)
        XCTAssertFalse(harness.palette.isOpen)
        XCTAssertTrue(harness.rearrange.isToggled)
        XCTAssertEqual(harness.paletteRecents.ids, ["view.rearrangemode"])
        window.close()
    }

    /// Return with no rows runs nothing and keeps the palette up; Esc closes it.
    func testReturnWithNoMatchesRunsNothingAndEscCloses() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        harness.palette.query = "zzqqxx"
        let window = harness.makeWindow(size: Self.windowSize)
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        XCTAssertTrue(rankedRows(harness).isEmpty)
        press(window, keyCode: 36, characters: "\r")
        await settle(window)
        XCTAssertTrue(harness.palette.isOpen)
        XCTAssertTrue(harness.paletteRecents.ids.isEmpty)
        XCTAssertFalse(harness.rearrange.isToggled)
        press(window, keyCode: 53, characters: "\u{1B}")
        await settle(window)
        XCTAssertFalse(harness.palette.isOpen)
        XCTAssertTrue(harness.paletteRecents.ids.isEmpty)
        window.close()
    }

    /// The empty-search list stops part way through a row, so a list longer
    /// than the box reads as one that scrolls.
    func testTheEmptyListCutsItsLastVisibleRow() async throws {
        typealias Metrics = ChromeMetrics.Palette
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for id in ["tokyo-night", "one-light"] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            harness.palette.open()
            let window = harness.makeWindow(size: Self.windowSize)
            await settle(window)
            let image = try snapshot(window)
            if let directory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("palette-fold-\(id).png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
            }
            let x = paletteBoxLeft(harness) + Metrics.width * 0.7
            let top = paletteTop(window) + Metrics.searchHeight
            let rowTop = try XCTUnwrap(
                firstPixel(image, in: CGRect(x: x, y: top, width: 0, height: Metrics.maxListHeight), matching: theme.palette.chromeRoles.selection.hex),
                "\(id): no selected first row"
            ).y
            let listBottom = try XCTUnwrap(
                firstPixel(
                    image, in: CGRect(x: x, y: rowTop + Metrics.rowHeight, width: 0, height: Metrics.maxListHeight),
                    matching: theme.palette.chromeRoles.rule.hex
                ),
                "\(id): no rule under the list"
            ).y
            let pitch = Metrics.rowHeight + 1
            let visible = listBottom - rowTop
            let cut = visible.truncatingRemainder(dividingBy: pitch)
            XCTAssertGreaterThan(rankedRows(harness).count, Int(visible / pitch) + 1, "\(id): the list does not overflow")
            XCTAssertGreaterThan(cut, pitch * 0.3, "\(id): the last visible row shows only \(cut)pt")
            XCTAssertLessThan(cut, pitch * 0.7, "\(id): the last visible row shows \(cut)pt, nearly whole")
            window.close()
        }
    }

    /// A query change scrolls the list back to its first row, so typing after
    /// a scroll never leaves row 0 above the fold.
    func testTypingScrollsTheListBackToItsFirstRow() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        harness.palette.open()
        let window = harness.makeWindow(size: Self.windowSize)
        await settle(window)
        let scroll = try XCTUnwrap(paletteScrollView(in: window))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(document.isFlipped)
        let start = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: start + 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(window)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y - start, 20, "the list did not scroll")
        harness.palette.query = "e"
        await settle(window)
        XCTAssertGreaterThan(CGFloat(rankedRows(harness).count) * (ChromeMetrics.Palette.rowHeight + 1), ChromeMetrics.Palette.maxListHeight + 40)
        let after = try XCTUnwrap(paletteScrollView(in: window))
        XCTAssertEqual(after.contentView.bounds.origin.y, start, accuracy: 1, "row 0 is left above the fold")
        window.close()
    }

    /// The rows the palette shows for the harness's current query, built the
    /// way `CommandPaletteView` builds them.
    private func rankedRows(_ harness: Harness) -> [PaletteRanking.Row] {
        let entries = PaletteCatalog.entries(
            in: .current(viewModel: harness.viewModel, chatStore: harness.chatStore, rtInstalled: RtAvailability.installed)
        )
        return PaletteRanking.rows(commands: entries.map(\.command), query: harness.palette.query, recents: harness.paletteRecents.ids)
    }

    private func paletteScrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, abs(scroll.frame.width - ChromeMetrics.Palette.width) < 2 { return scroll }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(root)
    }

    private func press(_ window: NSWindow, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }

    private func paletteBoxLeft(_ harness: Harness) -> CGFloat {
        let rail = harness.railWidth.width
        return rail + (Self.windowSize.width - rail - ChromeMetrics.Palette.width) / 2
    }

    /// The first row's badge, with no section label above it (a typed query).
    private func firstRowBadge(_ harness: Harness, _ window: NSWindow) -> CGRect {
        typealias Metrics = ChromeMetrics.Palette
        let left = paletteBoxLeft(harness) + Metrics.listPadding + Metrics.rowPadding
        let rowTop = paletteTop(window) + Metrics.searchHeight + ChromeMetrics.ruleWidth + Metrics.listPadding
        let top = rowTop + (Metrics.rowHeight - Metrics.badgeSize.height) / 2
        return CGRect(x: left, y: top, width: Metrics.badgeSize.width, height: Metrics.badgeSize.height)
    }

    /// How far a glyph's inner pixels may sit from its fill colour: 13pt text
    /// antialiases, so few of its pixels land on the exact hex.
    private static let glyphEdgeTolerance = 12

    /// Below the palette's search row and right of the rail, so neither the
    /// rail's selected workspace nor a selected tab (both in the selection
    /// colour) can be what a probe finds first.
    private func paletteRows(_ harness: Harness, _ window: NSWindow) throws -> CGRect {
        let left = try XCTUnwrap(harness.drag.canvas.paneFrames.values.map(\.minX).min())
        let top = paletteTop(window) + ChromeMetrics.Palette.searchHeight
        return CGRect(x: left, y: top, width: Self.windowSize.width - left, height: 400 - top)
    }

    /// Where the first row's name starts: the box is centred on the tab
    /// area, and the name follows the list and row padding, the badge and
    /// the gap.
    private func firstRowName(_ harness: Harness, _ window: NSWindow) -> CGRect {
        typealias Metrics = ChromeMetrics.Palette
        let rail = harness.railWidth.width
        let boxLeft = rail + (Self.windowSize.width - rail - Metrics.width) / 2
        let name = boxLeft + Metrics.listPadding + Metrics.rowPadding + Metrics.badgeSize.width + Metrics.rowGap
        let top = paletteTop(window) + Metrics.searchHeight + Metrics.listPadding
        return CGRect(x: name - 4, y: top, width: 60, height: Metrics.rowHeight + 4)
    }

    private func firstPixel(_ image: NSBitmapImageRep, in rect: CGRect, near target: String, within tolerance: Int) -> CGPoint? {
        firstPixel(image, in: rect) { $0 != "?" && channelDistance($0, target) <= tolerance }
    }
}

@MainActor
private struct Harness {
    let themeStore: ThemeStore
    let textSize: TerminalTextSizeStore
    let rtModalSize: RtModalSizeStore
    let rtModalTextSize: RtModalTextSizeStore
    let railWidth: RailWidthStore
    let collapse: SectionCollapseStore
    let board: BoardStore
    let toasts: ToastCenter
    let rearrange: RearrangeMode
    let drag: DragCoordinator
    let dividerDrag: DividerDragCoordinator
    let chatStore: ChatStore
    let optionAsAlt: OptionAsAltStore
    let palette = CommandPaletteState()
    let switcher: WorkspaceSwitcher
    let tabSwitcher: TabSwitcher
    let paletteRecents: PaletteRecentsStore
    let viewModel: SessionViewModel
    /// Arrange unless a test selects otherwise: every grid render that
    /// predates mission control measures Arrange.
    let modeStore: AllWorkspacesModeStore

    @MainActor func missionCardFrame(of pane: PaneID) -> CGRect? { MissionCardFrames.shared.frames[pane] }

    init(
        theme: Theme, model: SessionModel? = nil, client: any HerdrCommandClient = OfflineHerdrClient(),
        attaching panes: [PaneID] = Fixture.canvasPanes,
        // Absent by default, same as a machine with no chat binary: a render
        // test that does not care about chat must keep seeing exactly what it
        // saw before this button existed.
        chatAvailable: Bool = false, chatStatusJSON: [PaneID: String] = [:], chatUnread: [PaneID: Int] = [:],
        chatPeekJSON: String? = nil,
        // False only for a test proving the production fetch wiring itself:
        // every other test wants status/unread in place before the first
        // render, which calling the store here directly gives for free.
        seedChatStatus: Bool = true,
        // Frozen by any test that renders the attention stack: a finished
        // toast expires six seconds after it is raised, and a render that
        // read the wall clock would flip on a loaded machine that took that
        // long to build and settle two windows.
        now: @escaping @MainActor () -> Date = { Date() },
        notificationLifetime: NotificationLifetime = .untilSeen,
        // No Board config by default, same as a machine without the board
        // app, so every render that predates the section is unchanged.
        boardSources: BoardSources = .unconfigured,
        mouseHolders: Set<PaneID> = [],
        // Off by default, so every render that predates Settings > Titles
        // keeps drawing each pane's own title.
        oneTitle: Bool = false
    ) async throws {
        ChromeType.install()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: ChromeRenderTests.defaultsSuite))
        themeStore = ThemeStore(userDefaults: defaults)
        themeStore.select(theme)
        textSize = TerminalTextSizeStore(userDefaults: defaults)
        rtModalSize = RtModalSizeStore(userDefaults: defaults)
        rtModalTextSize = RtModalTextSizeStore(userDefaults: defaults)
        railWidth = RailWidthStore(userDefaults: defaults)
        collapse = SectionCollapseStore(userDefaults: defaults)
        defaults.removeObject(forKey: BoardStore.logoDefaultsKey)
        let board = BoardStore(sources: boardSources, userDefaults: defaults)
        await board.refresh()
        self.board = board
        toasts = ToastCenter()
        rearrange = RearrangeMode()
        // The view model is built below; the app wires the same rule.
        var escapeOwner: SessionViewModel?
        drag = DragCoordinator(
            toasts: toasts, rearrangeMode: rearrange,
            commit: { _, _ in fatalError("a render never drops") },
            reveal: { _ in },
            gridHoldsEscape: { escapeOwner.map { $0.renameTarget != nil || $0.paneShownInOverview != nil } ?? false }
        )
        dividerDrag = DividerDragCoordinator(session: DividerDragSession(commit: { _, _, _ in }))
        optionAsAlt = OptionAsAltStore(userDefaults: defaults)
        paletteRecents = PaletteRecentsStore(userDefaults: defaults)
        switcher = WorkspaceSwitcher(userDefaults: defaults)
        tabSwitcher = TabSwitcher(userDefaults: defaults)
        chatStore = ChatStore(
            toasts: ToastCenter(),
            probe: { chatAvailable ? "/usr/bin/true" : nil },
            rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in FixtureChatRunning(statusJSON: chatStatusJSON, peekJSON: chatPeekJSON) }
        )
        await chatStore.probeTask.value
        await chatStore.peekTask?.value
        if seedChatStatus {
            for pane in chatStatusJSON.keys {
                await chatStore.refreshStatus(for: pane)
            }
            for (pane, count) in chatUnread {
                chatStore.setUnreadCount(count, for: pane)
            }
        }
        modeStore = AllWorkspacesModeStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: "flock-mode-\(UUID().uuidString)")))
        modeStore.select(.arrange)
        // Fixture folders name real checkouts on a developer's machine; a
        // render must not read their git files.
        let repoBranches = RepoBranchCache { folder in
            RepoBranch(repo: URL(fileURLWithPath: folder).lastPathComponent, branch: "main")
        }
        viewModel = SessionViewModel(
            client: client, ghosttyFactory: GroundSurfaceFactory(mouseHolders: mouseHolders), now: now,
            notificationLifetime: { notificationLifetime }, oneTitle: { oneTitle }, repoBranches: repoBranches
        )
        escapeOwner = viewModel
        viewModel.update(model: try model ?? Fixture.model(), connection: .live)
        for pane in panes {
            _ = await viewModel.attachPane(pane)
        }
    }

    func makeWindow(
        size: CGSize, isDevBuild: Bool = false, devBuild: DevBuildWatcher? = nil,
        herdrMousePatchStore: HerdrMousePatchStore? = nil
    ) -> NSWindow {
        // The default resolves to no herdr, so the patch banner stays off and
        // every render assertion here measures the same chrome on any machine.
        let root = MainWindow(
            viewModel: viewModel,
            sessionLabel: "render",
            herdrMousePatchStore: herdrMousePatchStore
                ?? HerdrMousePatchStore(resolveBinaryPath: { nil }, resolveArtifactPath: { _ in nil }),
            isDevBuild: isDevBuild
        )
            .environment(devBuild)
        return host(root, size: size)
    }

    /// The title bar alone, at a width the main window's minimum never allows.
    func makeTitleBarWindow(width: CGFloat, isDevBuild: Bool) -> NSWindow {
        host(
            VStack(spacing: 0) {
                TitleBar(theme: themeStore.active, sessionLabel: "render", connectionState: .live, isDevBuild: isDevBuild)
                Spacer(minLength: 0)
            }
            .background(themeStore.active.chrome)
            .ignoresSafeArea(edges: .top)
            .background(TitlebarConfigurator(windowBg: themeStore.active.chrome)),
            size: CGSize(width: width, height: 120)
        )
    }

    /// The main window's own canvas alone, for the selected tab.
    func makeCanvasWindow(size: CGSize, solo: PaneID?) -> NSWindow {
        host(
            PaneCanvas(theme: themeStore.active, viewModel: viewModel, layout: viewModel.selectedLayout, solo: solo),
            size: size
        )
    }

    private func host(_ content: some View, size: CGSize) -> NSWindow {
        let modeDefaults = UserDefaults(suiteName: "flock-mission-\(UUID().uuidString)")!
        let root = content
            .environment(themeStore)
            .environment(textSize)
            .environment(rtModalSize)
            .environment(rtModalTextSize)
            .environment(railWidth)
            .environment(collapse)
            .environment(board)
            .environment(HerdProgressStore(sources: .unanswered))
            .environment(toasts)
            .environment(rearrange)
            .environment(drag)
            .environment(modeStore)
            .environment(MissionBottomLineStore(userDefaults: modeDefaults))
            .environment(WorkspaceIdentityStore(userDefaults: modeDefaults))
            .environment(dividerDrag)
            .environment(chatStore)
            .environment(optionAsAlt)
            .environment(palette)
            .environment(paletteRecents)
            .environment(switcher)
            .environment(tabSwitcher)
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

/// Stands in for a pane's terminal: an AppKit view that takes the keyboard
/// and counts every key that reaches it.
private final class KeyHog: NSView {
    var keys = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys += 1 }
}

extension ChromeRenderTests {
    /// Through the application, where local monitors see an event before any
    /// window or menu does.
    fileprivate func pressKey(_ window: NSWindow, keyCode: UInt16, character: Int) {
        guard let scalar = UnicodeScalar(UInt32(character)) else { return }
        let text = String(Character(scalar))
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApplication.shared.sendEvent(event)
    }
}

@MainActor
private final class FixtureClock {
    var date: Date
    init(_ date: Date) { self.date = date }
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
    private let peekJSON: String?

    init(statusJSON: [PaneID: String], peekJSON: String? = nil) {
        self.statusJSON = statusJSON
        self.peekJSON = peekJSON
    }

    func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
        if case .peek = verb, let peekJSON { return (Data(peekJSON.utf8), 0) }
        guard case let .status(pane: rawPane) = verb, let json = statusJSON[PaneID(rawValue: rawPane)] else {
            throw ChatFailure(message: "FixtureChatRunning has no status for \(verb)")
        }
        return (Data(json.utf8), 0)
    }
}

@MainActor
private final class GroundSurface: GhosttyPaneSurface {
    let programHasMouse: Bool
    init(programHasMouse: Bool = false) { self.programHasMouse = programHasMouse }
    func detach() async {}
    func park() {}
    func unpark() {}
    func releaseHerdrHold() {}
    func takeHerdrHold() {}
    func resumeScreenActivityReporting() {}
    var hasFirstFrame: Bool { true }
    var hasClaimedMouse: Bool { programHasMouse }
}

@MainActor
private struct GroundSurfaceFactory: GhosttyPaneFactory {
    var mouseHolders: Set<PaneID> = []

    func makeSurface(
        for pane: PaneID, onUserInput: @escaping () -> Void,
        onClearRequested: @escaping () -> Void,
        onScreenActivity: @escaping (Int) -> Bool
    ) async -> any GhosttyPaneSurface {
        GroundSurface(programHasMouse: mouseHolders.contains(pane))
    }
}

/// Answers the hover card's tail read and nothing else, in herdr's own
/// envelope shape: the screen sits under `result.read`, and a payload written
/// anywhere else decodes to nothing and leaves every card blank with no error
/// to show for it.
private struct GridFixtureClient: HerdrCommandClient {
    static let screen = """
        $ bun install
        bun install v1.2.4
        Checked 212 installs across 240 packages (no changes) [41.00ms]
        $ bun test lib/daemon
        warn: lib/daemon/socket.ts:42 the idle timeout falls back to its default because DAEMON_IDLE_MS is unset in this environment
        lib/daemon/port-allocator.test.ts:
        (pass) allocates the first free port
        (pass) refuses a port already held
        (pass) releases on close
        (pass) hands a released port to the next caller before probing past it
        lib/daemon/lease.test.ts:
        (pass) renews a lease before it expires
        (pass) expires a lease nobody renewed
        (pass) keeps the newest lease when two renewals race
        lib/daemon/socket.test.ts:
        (pass) accepts a client on the unix socket
        (pass) drops a client that never sends a frame
        (pass) answers a ping with the daemon's own version string and uptime

         31 pass, 0 fail
         64 expect() calls
        Ran 31 tests across 3 files. [1.12s]
        Editing lib/daemon.ts

        """

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { throw OfflineHerdrClient.Offline() }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": Self.screen]]])
    }
}

/// Answers the card's read with a full-screen account switcher as herdr's
/// ANSI format carries it: SGR in every form the parser reads, cursor and OSC
/// escapes it must swallow, `\r\n` row ends, and blank rows down to a footer.
private struct AnsiTUIClient: HerdrCommandClient {
    static let columns = 112

    static let screen: String = {
        let esc = "\u{1B}["
        func row(_ segments: [(String, String)], right: (String, String)? = nil) -> String {
            let plain = segments.map(\.0).joined().count
            var line = segments.map { "\(esc)0m\($0.1)\($0.0)" }.joined()
            if let right {
                let gap = max(1, columns - plain - right.0.count)
                line += "\(esc)0m" + String(repeating: " ", count: gap) + right.1 + right.0
            }
            return line + "\(esc)0m"
        }
        func bar(filled: Int, fill: String) -> [(String, String)] {
            [(String(repeating: " ", count: filled), fill), (String(repeating: " ", count: 30 - filled), "\(esc)100m")]
        }
        let accounts: [(name: String, plan: String, planStyle: String, used: Int, fill: String, reset: String)] = [
            ("acme-main", "pro", "\(esc)38;5;208m", 20, "\(esc)42m", "resets 14:05"),
            ("acme-ops", "team", "\(esc)36m", 7, "\(esc)42m", "resets 09:40"),
            ("acme-ci", "free", "\(esc)2m", 27, "\(esc)48;5;208m", "resets yesterday 22:15"),
            ("acme-lab", "pro", "\(esc)38;5;208m", 1, "\(esc)42m", "resets in 3d 01:00"),
            ("acme-edu", "team", "\(esc)36m", 14, "\(esc)48;2;180;120;255m", "resets 18:30"),
        ]
        let header = " acme switch · 5 accounts"
        var rows = [
            "\(esc)?25l\(esc)H\u{1B}]0;acme switch\u{07}" + row([(header + String(repeating: " ", count: columns - header.count), "\(esc)1;97;44m")]),
            "",
            row([("   ACCOUNT           PLAN    USAGE", "\(esc)1m")], right: ("RESET", "\(esc)1m")),
        ]
        for (index, account) in accounts.enumerated() {
            let selected = index == 1
            let mark = selected ? "\(esc)7m" : ""
            var segments: [(String, String)] = [
                (selected ? " > " : "   ", mark),
                (account.name.padding(toLength: 18, withPad: " ", startingAt: 0), mark + (selected ? "\(esc)1m" : "")),
                (account.plan.padding(toLength: 8, withPad: " ", startingAt: 0), account.planStyle),
            ]
            segments += bar(filled: account.used, fill: account.fill)
            segments.append(("  \(account.used * 100 / 30)%", account.used > 24 ? "\(esc)1;31m" : "\(esc)32m"))
            rows.append(row(segments, right: (account.reset, "\(esc)38:2::130:140:150m")))
        }
        rows += Array(repeating: "", count: 24)
        rows.append(row(
            [(" ↑↓ move  enter switch  s sort  q quit", "\(esc)2m")],
            right: ("acme switch 0.4.1 ", "\(esc)3;38;2;255;100;180m")
        ))
        return rows.joined(separator: "\r\n") + "\r\n"
    }()

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { throw OfflineHerdrClient.Offline() }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": Self.screen]]])
    }
}

/// `GridFixtureClient`, keeping every method it is asked for.
private actor MethodRecordingClient: HerdrCommandClient {
    private(set) var methods: [String] = []

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        methods.append(method)
        return try await GridFixtureClient().requestRaw(method, params)
    }
}

/// Six workspaces, one with nine tabs and one with six, over split layouts
/// and every agent status.
private enum GridFixture {
    static let repoTools = WorkspaceID(rawValue: "w1")
    static let flock = WorkspaceID(rawValue: "w2")
    /// Four tabs, which fill one row of the 1200pt grid exactly.
    static let mattstackApps = WorkspaceID(rawValue: "w3")
    /// Three tabs. `src` holds one pane (a drop from it empties the tab),
    /// `build` holds two.
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
                        "agent_status": pane.1, "revision": 1, "terminal_title_stripped": pane.0, "agent": "claude",
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

    /// `model()` plus three herds: one half through, one mostly working with
    /// a worker blocked on its shepherd, one finished. `focusing` selects a
    /// herd's workspace and its first tab instead of `flock`.
    static func herdModel(focusing herd: String? = nil) throws -> SessionModel {
        var model = try model()
        let herds: [(id: String, name: String, workers: [AgentStatus])] = [
            ("h1", "review-shapes-20260922-093843", [.done, .working, .done, .blocked, .working]),
            ("h2", "ci-sweep-20260922-112541", [.working, .working, .done, .working]),
            ("h3", "acme-sweep-20260922-081502", [.done, .done, .idle, .done, .done]),
        ]
        for (index, herd) in herds.enumerated() {
            let workspace = WorkspaceID(rawValue: herd.id)
            model.workspaces.append(WorkspaceRecord(
                workspaceID: workspace, label: HerdWorkspace.labelPrefix + herd.name, number: 6 + index,
                activeTabID: TabID(rawValue: "\(herd.id):t1"), agentStatus: AgentAttention.aggregate(herd.workers)
            ))
            for (worker, status) in herd.workers.enumerated() {
                let tab = TabID(rawValue: "\(herd.id):t\(worker + 1)")
                model.tabs[workspace, default: []].append(TabRecord(
                    tabID: tab, workspaceID: workspace, label: "worker-\(worker + 1)", number: worker + 1,
                    paneCount: 1, agentStatus: status
                ))
                let pane = PaneID(rawValue: "\(herd.id):p\(worker + 1)")
                model.panes[pane] = PaneRecord(
                    paneID: pane, workspaceID: workspace, tabID: tab, focused: false, agentStatus: status, revision: 1,
                    terminalTitleStripped: "claude", label: nil, cwd: "/private/tmp", scroll: nil
                )
            }
        }
        if let herd {
            model.focusedWorkspaceID = WorkspaceID(rawValue: herd)
            model.focusedTabID = TabID(rawValue: "\(herd):t1")
            model.focusedPaneID = nil
        }
        return model
    }

    /// `herdModel()` plus the three workspaces board launches into, held in
    /// herdr's order out of role order and among the others: a review blocked,
    /// a response working, the doctors idle.
    static func boardModel() throws -> SessionModel {
        var model = try herdModel()
        let board: [(id: String, label: String, index: Int, panes: [AgentStatus])] = [
            ("b3", "🛹 Doctors", 1, [.idle, .idle]),
            ("b1", "🛹 Reviews", 3, [.blocked, .working, .done]),
            ("b2", "🛹 Responses", model.workspaces.count + 2, [.working]),
        ]
        for workspace in board {
            let id = WorkspaceID(rawValue: workspace.id)
            let tab = TabID(rawValue: "\(workspace.id):t1")
            model.workspaces.insert(WorkspaceRecord(
                workspaceID: id, label: workspace.label, number: workspace.index + 1, activeTabID: tab,
                agentStatus: AgentAttention.aggregate(workspace.panes)
            ), at: min(workspace.index, model.workspaces.count))
            model.tabs[id] = [TabRecord(
                tabID: tab, workspaceID: id, label: "main", number: 1, paneCount: workspace.panes.count,
                agentStatus: AgentAttention.aggregate(workspace.panes)
            )]
            for (index, status) in workspace.panes.enumerated() {
                let pane = PaneID(rawValue: "\(workspace.id):p\(index + 1)")
                model.panes[pane] = PaneRecord(
                    paneID: pane, workspaceID: id, tabID: tab, focused: false, agentStatus: status, revision: 1,
                    terminalTitleStripped: "claude", label: nil, cwd: "/private/tmp", scroll: nil
                )
            }
        }
        return model
    }

    /// `flockTabLabels` replaces the four tabs of the selected workspace, for
    /// a test that needs a title of its own. Four of them either way: the
    /// third is the selected tab the rest of the fixture is written around.
    /// `focusedPaneAgentStatus` overrides only `w1:p2` (every other pane stays
    /// `idle`, the default every existing caller still gets): the one pane a
    /// test can also carry a chat status on, for a fixture with both a status
    /// dot and a chat button on the same legend.
    /// `onePane` moves `w1:p1` out to the `logs` tab, leaving the selected
    /// tab holding `w1:p2` alone.
    static func model(
        zoomed: Bool = false, flockTabLabels: [String]? = nil, focusedPaneAgentStatus: String = "idle",
        onePane: Bool = false
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
            let flockTabs = [onePane ? "w1:t4" : "w1:t3", "w1:t3", "w1:t1", "w1:t2", "w1:t4"]
            for paneIndex in 0..<workspace.panes {
                let paneID = "\(workspace.id):p\(paneIndex + 1)"
                paneRows.append([
                    "pane_id": paneID, "workspace_id": workspace.id,
                    "tab_id": isFlock ? flockTabs[paneIndex] : "\(workspace.id):t1",
                    "focused": isFlock && paneIndex == 1,
                    "agent_status": paneID == "w1:p2" ? focusedPaneAgentStatus : "idle", "revision": 1,
                    "terminal_title_stripped": "shell", "cwd": "/private/tmp",
                ].merging(paneID == "w1:p2" ? ["agent": "claude"] : [:]) { $1 })
            }
        }
        let area: [String: Int] = ["x": 0, "y": 0, "width": 120, "height": 40]
        let layout: [String: Any] = [
            "workspace_id": "w1", "tab_id": "w1:t3", "zoomed": zoomed, "area": area, "focused_pane_id": "w1:p2",
            "panes": onePane
                ? [["pane_id": "w1:p2", "focused": true, "rect": area]]
                : [
                    ["pane_id": "w1:p1", "focused": false, "rect": ["x": 0, "y": 0, "width": 60, "height": 40]],
                    ["pane_id": "w1:p2", "focused": true, "rect": ["x": 60, "y": 0, "width": 60, "height": 40]],
                ],
            "splits": onePane ? [] : [["id": "split_0_root", "direction": "right", "ratio": 0.5, "rect": area]],
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

extension ChromeRenderTests {
    /// The title bar's view tabs in each selected state, chosen through the
    /// same navigator the menu and the palette use, in a dark and a light
    /// theme. Workspaces keeps the rail, whose heading no longer carries a
    /// grid button. PNGs are written only when `FLOCK_CHROME_RENDER_DIR` is set.
    func testViewTabsSelectEachViewAndUnderlineOnlyTheSelectedTab() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            let window = harness.makeWindow(size: Self.gridWindowSize, isDevBuild: true)
            await settle(window)
            assertButtonsCentered(in: window)
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            let buttonsEnd = zoom.convert(zoom.bounds, to: nil).maxX
            let navigator = ViewTabNavigator(drag: harness.drag, mode: harness.modeStore)
            var underlineStarts: [CGFloat] = []
            for tab in ViewTab.allCases {
                navigator.choose(tab)
                await settle(window)
                XCTAssertEqual(navigator.selected, tab, "\(scheme)")
                XCTAssertEqual(harness.drag.isGridShown, tab != .workspaces, "\(scheme): \(tab)")
                if let gridMode = tab.gridMode { XCTAssertEqual(harness.modeStore.active, gridMode) }
                let image = try snapshot(window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("title-tabs-\(tab.rawValue)-\(scheme)-\(id).png"))
                }
                let runs = accentRuns(in: image, width: Self.gridWindowSize.width, theme: theme)
                XCTAssertEqual(runs.count, 1, "\(scheme) \(tab): one underline, under the selected tab only: \(runs)")
                let run = try XCTUnwrap(runs.first)
                XCTAssertGreaterThan(run.upperBound - run.lowerBound, 40, "\(scheme) \(tab)")
                XCTAssertGreaterThan(run.lowerBound, buttonsEnd, "\(scheme) \(tab): the tabs run under the window buttons")
                underlineStarts.append(run.lowerBound)
            }
            XCTAssertEqual(underlineStarts, underlineStarts.sorted(), "\(scheme): the underline does not follow tab order")
            XCTAssertEqual(Set(underlineStarts).count, 3, "\(scheme)")
            window.close()
        }
    }

    /// A focused pane is Overview's: its tab stays selected, choosing it again
    /// keeps the pane, and choosing Arrange or Workspaces shows that view
    /// while Overview keeps the pane to return to.
    func testAFocusedPaneKeepsOverviewSelectedUntilArrangeIsChosen() async throws {
        let harness = try await Harness(theme: .tokyoNight)
        let navigator = ViewTabNavigator(drag: harness.drag, mode: harness.modeStore)
        let pane = try XCTUnwrap(Fixture.canvasPanes.first)
        navigator.choose(.overview)
        harness.drag.focusGridPane(pane)
        XCTAssertEqual(navigator.selected, .overview)
        navigator.choose(.overview)
        XCTAssertEqual(harness.drag.gridFocusedPane, pane)
        navigator.choose(.arrange)
        XCTAssertEqual(navigator.selected, .arrange)
        XCTAssertEqual(harness.drag.gridFocusedPane, pane, "Arrange leaves Overview's place alone")
        navigator.choose(.overview)
        XCTAssertEqual(navigator.selected, .overview)
        XCTAssertEqual(harness.drag.gridFocusedPane, pane, "Overview returns to the pane it had open")
        navigator.choose(.workspaces)
        XCTAssertFalse(harness.drag.isGridShown)
        XCTAssertEqual(harness.drag.gridFocusedPane, pane, "closing the grid keeps it too")
    }

    /// Below the main window's minimum, "flock" and its DEV tag hide rather
    /// than run into the tabs. Rendered at a width where they still fit too.
    func testTheTitleHidesBeforeItWouldOverlapTheTabs() async throws {
        let directory = ProcessInfo.processInfo.environment["FLOCK_CHROME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        for (id, scheme) in [("tokyo-night", "dark"), ("catppuccin-latte", "light")] {
            let theme = try XCTUnwrap(Theme.builtins.first { $0.id == id })
            let harness = try await Harness(theme: theme)
            for (width, shows) in [(CGFloat(640), false), (CGFloat(900), true)] {
                let window = harness.makeTitleBarWindow(width: width, isDevBuild: true)
                await settle(window)
                let image = try snapshot(window)
                if let directory {
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("title-bar-\(Int(width))-\(scheme)-\(id).png"))
                }
                let centre = CGRect(x: width / 2 - 50, y: 0, width: 100, height: ChromeMetrics.TitleBar.height)
                XCTAssertEqual(count(theme.palette.yellow.hex, in: centre, of: image) > 0, shows, "\(scheme) at \(width)")
                window.close()
            }
        }
    }

    /// Runs of the accent along the title bar's last row, in window points.
    private func accentRuns(in image: NSBitmapImageRep, width: CGFloat, theme: Theme) -> [ClosedRange<CGFloat>] {
        let accent = theme.palette.chromeRoles.accent.hex
        let y = ChromeMetrics.TitleBar.height - 1
        var runs: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        var last: CGFloat = 0
        for x in stride(from: CGFloat(0), to: width, by: 1) {
            if hex(image, CGPoint(x: x, y: y)) == accent {
                if start == nil { start = x }
                last = x
            } else if let begun = start {
                runs.append(begun...last)
                start = nil
            }
        }
        if let begun = start { runs.append(begun...last) }
        return runs
    }
}
