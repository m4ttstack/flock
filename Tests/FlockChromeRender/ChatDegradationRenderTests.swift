import AppKit
@testable import FlockCore
import SwiftUI
import XCTest

/// The view-level half of the degradation matrix (see also
/// `Tests/FlockCoreTests/ChatDegradationTests.swift` for the pure half):
/// the Chat menu's own item list, a hung verb failing on its deadline
/// through the real `ChatStore`, the popover's Retry banner, and Open
/// Viewer disabling itself alone when deck is missing.
@MainActor
final class ChatDegradationRenderTests: XCTestCase {
    private static let pane = PaneID(rawValue: "w1:p2")

    // MARK: - the Chat menu's item list (order, keys, enabled state)

    func testMenuOrderKeysAndSeparatorsMatchTheMeasurements() {
        let rows = ChatMenuModel.rows(
            isAvailable: true, hasFocusedPane: true, isSignedIn: false, viewerDisabledReason: nil
        )
        let items = try? XCTUnwrap(rows).map(\.item)
        XCTAssertEqual(items, [.chatPanel, .broadcast, .peek, .quickSend, .openViewer, .signIn, .signOut])

        XCTAssertEqual(ChatMenuItem.chatPanel.title, "Chat Panel")
        XCTAssertEqual(ChatMenuItem.chatPanel.key, "c")
        XCTAssertEqual(ChatMenuItem.broadcast.title, "Broadcast to Panes…")
        XCTAssertEqual(ChatMenuItem.broadcast.key, "b")
        XCTAssertEqual(ChatMenuItem.peek.title, "Chat Peek")
        XCTAssertEqual(ChatMenuItem.peek.key, "p")
        XCTAssertEqual(ChatMenuItem.quickSend.title, "Quick Send…")
        XCTAssertEqual(ChatMenuItem.quickSend.key, "s")
        XCTAssertEqual(ChatMenuItem.openViewer.title, "Open Viewer")
        XCTAssertEqual(ChatMenuItem.openViewer.key, "v")
        XCTAssertEqual(ChatMenuItem.signIn.title, "Sign In This Pane")
        XCTAssertEqual(ChatMenuItem.signIn.key, "i")
        XCTAssertEqual(ChatMenuItem.signOut.title, "Sign Out This Pane")
        XCTAssertEqual(ChatMenuItem.signOut.key, "o")

        XCTAssertEqual(ChatMenuItem.allCases.filter(\.hasSeparatorBefore), [.broadcast, .signIn])
    }

    /// The whole menu is absent when the binary is -- never a list of
    /// disabled rows standing in for it.
    func testMenuIsNilWhenChatIsUnavailable() {
        XCTAssertNil(ChatMenuModel.rows(isAvailable: false, hasFocusedPane: true, isSignedIn: false, viewerDisabledReason: nil))
    }

    func testMenuIsAllDisabledWithNoFocusedPane() throws {
        let rows = try XCTUnwrap(ChatMenuModel.rows(isAvailable: true, hasFocusedPane: false, isSignedIn: true, viewerDisabledReason: nil))
        XCTAssertTrue(rows.allSatisfy { !$0.isEnabled })
    }

    func testSignInAndSignOutAreEachOtherOppositeAndOpenViewerNeedsDeck() throws {
        let signedOut = try XCTUnwrap(ChatMenuModel.rows(isAvailable: true, hasFocusedPane: true, isSignedIn: false, viewerDisabledReason: nil))
        XCTAssertTrue(row(.signIn, in: signedOut).isEnabled)
        XCTAssertFalse(row(.signOut, in: signedOut).isEnabled)

        let signedIn = try XCTUnwrap(ChatMenuModel.rows(isAvailable: true, hasFocusedPane: true, isSignedIn: true, viewerDisabledReason: nil))
        XCTAssertFalse(row(.signIn, in: signedIn).isEnabled)
        XCTAssertTrue(row(.signOut, in: signedIn).isEnabled)

        // Deck missing disables Open Viewer alone; every other row (with a
        // focused pane) keeps working.
        let deckMissing = try XCTUnwrap(
            ChatMenuModel.rows(isAvailable: true, hasFocusedPane: true, isSignedIn: true, viewerDisabledReason: "no deck")
        )
        XCTAssertFalse(row(.openViewer, in: deckMissing).isEnabled)
        XCTAssertTrue(row(.chatPanel, in: deckMissing).isEnabled)
        XCTAssertTrue(row(.broadcast, in: deckMissing).isEnabled)
        XCTAssertTrue(row(.peek, in: deckMissing).isEnabled)
        XCTAssertTrue(row(.quickSend, in: deckMissing).isEnabled)
        XCTAssertTrue(row(.signOut, in: deckMissing).isEnabled)
    }

    private func row(_ item: ChatMenuItem, in rows: [ChatMenuModel.Row]) -> ChatMenuModel.Row {
        rows.first { $0.item == item }!
    }

    // MARK: - a shortcut names an action and has to deliver it, not a launcher

    /// `ChatCommands.perform` is AppKit menu wiring and out of scope; what is
    /// worth pinning is the seam it drives -- `ChatStore.requestPopover`
    /// recording the right feature, and `ChatPopover` actually starting on
    /// the route that feature names.
    func testRequestPopoverRecordsTheFeatureAlongsideThePane() {
        let store = ChatStore(toasts: ToastCenter(), probe: { nil })

        store.requestPopover(for: Self.pane)
        XCTAssertEqual(store.requestedPopover, ChatPopoverRequest(pane: Self.pane, feature: nil))

        store.requestPopover(for: Self.pane, feature: .broadcast)
        XCTAssertEqual(store.requestedPopover, ChatPopoverRequest(pane: Self.pane, feature: .broadcast))

        store.clearPopoverRequest()
        XCTAssertNil(store.requestedPopover)
    }

    /// Chat Panel opens the root (that IS the panel); Broadcast, Peek and
    /// Quick Send each have to start the popover already on their own view,
    /// never on a launcher the user still has to navigate from.
    func testInitialFeatureSetsThePopoversStartingRoute() {
        func popover(initialFeature: ChatPopoverFeature?) -> ChatPopover {
            ChatPopover(
                theme: .tokyoNight, paneName: "claude", status: nil, isPresented: .constant(true),
                onSignIn: {}, onSignOut: {}, onOpenViewer: {}, initialFeature: initialFeature
            )
        }

        XCTAssertEqual(popover(initialFeature: nil).currentRoute, .status, "Chat Panel opens the root")
        XCTAssertEqual(popover(initialFeature: .broadcast).currentRoute, .feature(.broadcast))
        XCTAssertEqual(popover(initialFeature: .peek).currentRoute, .feature(.peek))
        XCTAssertEqual(popover(initialFeature: .quickSend).currentRoute, .feature(.quickSend))
    }

    // MARK: - rt missing collapses to the same absence as the plugin binary

    func testMissingRTMakesChatUnavailableEvenWithThePluginBinaryFound() async {
        let store = ChatStore(
            toasts: ToastCenter(), probe: { "/usr/bin/true" }, rtProbe: { false }, deckProbe: { true }
        )
        await store.probeTask.value
        XCTAssertFalse(store.isAvailable, "rt missing must read exactly like the plugin binary missing: absent, not broken")
    }

    // MARK: - deck missing disables Open Viewer alone; chat itself still works

    func testMissingDeckNamesAReasonWithoutTouchingAvailability() async {
        let store = ChatStore(
            toasts: ToastCenter(), probe: { "/usr/bin/true" }, rtProbe: { true }, deckProbe: { false }
        )
        await store.probeTask.value
        XCTAssertTrue(store.isAvailable, "deck is not part of the whole-feature gate")
        XCTAssertNotNil(store.viewerDisabledReason)
    }

    // MARK: - rt daemon down: every verb fails, the reason is kept for Retry, and nothing tries to start it

    /// Never resolves on its own (a 999s sleep stands in for a hung daemon);
    /// its own short second branch is what "fails on its deadline" means
    /// here, without spawning any real process.
    private struct NeverAnsweringChatRunning: ChatRunning {
        func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
            try await withThrowingTaskGroup(of: (stdout: Data, exitCode: Int32).self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(999))
                    return (Data(), 0)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(100))
                    throw ChatFailure(message: "chat daemon unreachable")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
    }

    func testAHungDaemonFailsOnItsDeadlineAndTheBannerCarriesTheReason() async {
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { "/usr/bin/true" }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in NeverAnsweringChatRunning() }
        )
        await store.probeTask.value
        let started = Date()

        await store.refreshStatus(for: Self.pane)

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a hung verb must fail on its own deadline rather than hang the caller")
        XCTAssertEqual(store.statusError(for: Self.pane), "chat daemon unreachable")
        XCTAssertEqual(toasts.current?.message, "chat daemon unreachable")
    }

    /// A daemon that comes back up clears the banner: Retry is what a real
    /// popover wires to `refreshStatus`, so this proves the same call both
    /// clears a prior failure and never spawns anything beyond the one verb
    /// it was asked to run.
    func testRetrySucceedingClearsTheBannerAndRunsNothingButTheStatusVerb() async {
        actor FlakyRunner: ChatRunning {
            private(set) var calls: [ChatVerb] = []
            /// The store's own untracked launch-time `.peek` reaches this
            /// fake before the test's own calls do; answering it here,
            /// without touching `calls`, is what keeps "the first call"
            /// below meaning the test's own first `refreshStatus`.
            func run(_ verb: ChatVerb) async throws -> (stdout: Data, exitCode: Int32) {
                if case .peek = verb { return (Data(#"{"buddies":[],"rooms":[]}"#.utf8), 0) }
                calls.append(verb)
                guard calls.count > 1 else {
                    return (Data(#"{"error":"chat daemon unreachable"}"#.utf8), 1)
                }
                return (Data(#"{"handle":"@kay","state":"live","pane":"w1:p2","signedIn":true,"rooms":[]}"#.utf8), 0)
            }
            func recordedCalls() -> [ChatVerb] { calls }
        }
        let runner = FlakyRunner()
        let toasts = ToastCenter()
        let store = ChatStore(
            toasts: toasts, probe: { "/usr/bin/true" }, rtProbe: { true }, deckProbe: { true },
            makeRunner: { _ in runner }
        )
        await store.probeTask.value
        await store.peekTask?.value

        await store.refreshStatus(for: Self.pane)
        XCTAssertNotNil(store.statusError(for: Self.pane), "the first, failing call must set the banner")

        await store.refreshStatus(for: Self.pane)
        XCTAssertNil(store.statusError(for: Self.pane), "the retry succeeding must clear the banner")

        let calls = await runner.recordedCalls()
        XCTAssertEqual(
            calls, [.status(pane: Self.pane.rawValue), .status(pane: Self.pane.rawValue)],
            "retry must never trigger anything but that same verb -- nothing here ever tries to start rt"
        )
    }

    // MARK: - the popover: absent vs broken never collapse

    /// Absent (row 1/2, `testChatButtonIsAbsentWhenChatIsUnavailable` in
    /// `ChromeRenderTests`) draws no button and no popover at all. Broken
    /// draws the popover WITH a one-line Retry banner -- a strictly taller
    /// status route than the same popover with no error, which is what
    /// proves the banner actually rendered rather than merely being passed
    /// a string nobody drew.
    func testTheFailureBannerAddsHeightOnlyWhenThereIsAnError() {
        let status = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: [])
        let clean = ChatPopover(
            theme: .tokyoNight, paneName: "claude", status: status, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        let broken = ChatPopover(
            theme: .tokyoNight, paneName: "claude", status: status, statusError: "chat daemon unreachable",
            isPresented: .constant(true), onSignIn: {}, onSignOut: {}, onOpenViewer: {}
        )
        XCTAssertGreaterThan(
            fittingHeight(broken.statusRoute), fittingHeight(clean.statusRoute),
            "a set statusError must draw a visible banner, not just carry a string nobody shows"
        )
    }

    func testOpenViewerAloneStaysUnhighlightedWhileDeckIsMissingButPeekStillWorks() async throws {
        let theme = Theme.tokyoNight
        let status = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: [])
        let reason = "Open viewer needs deck, which isn't installed"

        let openViewerHovered = ChatPopover(
            theme: theme, paneName: "claude", status: status, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}, viewerDisabledReason: reason,
            previewHoveredFeature: .openViewer
        )
        let openViewerWindow = popoverWindow(openViewerHovered)
        await settle(openViewerWindow)
        let openViewerImage = try snapshot(openViewerWindow)
        // Open Viewer is the fourth (last) of the four feature rows.
        let openViewerRowY = ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedIn
            + ChromeMetrics.ChatPopover.SectionLabel.height + 3.5 * ChromeMetrics.ChatPopover.Features.rowSize.height
        XCTAssertEqual(
            hex(openViewerImage, CGPoint(x: 200, y: openViewerRowY)), theme.palette.panelBg.hex,
            "a disabled row must not draw the hovered/selected fill even while it is the hovered feature"
        )
        openViewerWindow.close()

        let peekHovered = ChatPopover(
            theme: theme, paneName: "claude", status: status, isPresented: .constant(true),
            onSignIn: {}, onSignOut: {}, onOpenViewer: {}, viewerDisabledReason: reason,
            previewHoveredFeature: .peek
        )
        let peekWindow = popoverWindow(peekHovered)
        await settle(peekWindow)
        let peekImage = try snapshot(peekWindow)
        // Peek is the second of the four feature rows.
        let peekRowY = ChromeMetrics.ChatPopover.Header.height + ChromeMetrics.ChatPopover.Status.heightSignedIn
            + ChromeMetrics.ChatPopover.SectionLabel.height + 1.5 * ChromeMetrics.ChatPopover.Features.rowSize.height
        XCTAssertEqual(
            hex(peekImage, CGPoint(x: 200, y: peekRowY)), theme.palette.selectionBg.hex,
            "deck missing must not stop every OTHER row from still highlighting when hovered"
        )
        peekWindow.close()
    }

    // MARK: - signed out: Quick send's footer says why, rather than staying blank

    func testQuickSendFooterNamesWhySendingIsDisabledWhenSignedOut() {
        let signedOut = ChatStatus(handle: nil, state: "not signed in", pane: nil, signedIn: false, rooms: [])
        let view = ChatQuickSendView(theme: .tokyoNight, status: signedOut, onBack: {}, onClose: {}, previewTargets: ["#rt"])
        XCTAssertEqual(view.footerHint, "Sign in to send")

        let signedIn = ChatStatus(handle: "kay", state: "working", pane: "w1:p2", signedIn: true, rooms: [])
        let signedInView = ChatQuickSendView(theme: .tokyoNight, status: signedIn, onBack: {}, onClose: {}, previewTargets: ["#rt"])
        XCTAssertEqual(signedInView.footerHint, "sent as kay")
    }

    // MARK: - harness

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

    /// A plain SwiftUI view's own ideal height, with no window and no
    /// snapshot: what `.frame(height:)` declares is what this reports.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}
