import AppKit
import PaddockCore
import SwiftUI
import XCTest

/// The property the terminal's standing down rests on: an inline rename
/// editor appearing in a window that has NO first responder takes the
/// window's field editor for itself.
///
/// `TerminalFocusClaim.standDown` leaves the window holding no first
/// responder precisely so the editor's own focus request is answered from
/// this state. If SwiftUI ever stops answering it, the rename editor goes
/// deaf and the failure belongs here rather than in a run on Matt's machine.
///
/// What this cannot do is reproduce the defect that made the stand-down
/// necessary: an `xctest` host cannot make its window key (`isKeyWindow`
/// stays false however the app is activated), and a non-key window installs
/// a field editor down a different path from the app's own. So this pins the
/// assumption, and the e2e rename cases remain the proof of the whole path.
@MainActor
final class InlineRenameFocusTests: XCTestCase {
    /// What the pane's terminal is, from the window's point of view: a view
    /// that accepts first responder and gives it up when asked.
    private final class ResponderHog: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Hog: NSViewRepresentable {
        let capture: (ResponderHog) -> Void

        func makeNSView(context: Context) -> ResponderHog {
            let view = ResponderHog()
            capture(view)
            return view
        }

        func updateNSView(_ nsView: ResponderHog, context: Context) {}
    }

    private struct Probe: View {
        let editing: Bool
        let capture: (ResponderHog) -> Void

        var body: some View {
            VStack(spacing: 0) {
                Hog(capture: capture).frame(width: 200, height: 100)
                if editing {
                    InlineRenameField(
                        theme: Theme.builtins[0], font: .body, initialText: "tabB",
                        accessibilityIdentifier: "probe.rename", onCommit: { _ in }, onCancel: {}
                    )
                    .frame(width: 200, height: 24)
                }
            }
            .frame(width: 200, height: 160)
        }
    }

    func testAnEditorOpeningIntoAWindowWithNoFirstResponderTakesTheKeyboard() async throws {
        var hog: ResponderHog?
        let hosting = NSHostingView(rootView: Probe(editing: false, capture: { hog = $0 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        await settle(window)

        // The state the terminal leaves behind when it stands down: it held
        // first responder, and now the window holds it instead.
        let terminal = try XCTUnwrap(hog, "the stand-in terminal never reached the window")
        XCTAssertTrue(window.makeFirstResponder(terminal), "the window refused the stand-in terminal")
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === terminal, "the stand-in terminal would not give up first responder")

        hosting.rootView = Probe(editing: true, capture: { hog = $0 })
        await settle(window)

        let responder = try XCTUnwrap(window.firstResponder as? NSTextView, "no field editor took the window's keyboard")
        XCTAssertTrue(responder.isFieldEditor, "the window's first responder is a text view that is not a field editor")
        XCTAssertEqual(responder.string, "tabB", "the field editor holds text from somewhere other than the editor")

        window.close()
    }

    // MARK: - The claim itself

    /// A field with the claim behind it and NO SwiftUI focus of its own, so
    /// the only thing that can move first responder is the claim. The control
    /// below is the same view without it.
    private struct ClaimedField: View {
        let claiming: Bool
        @State private var text = "tabB"

        var body: some View {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .background { if claiming { FirstResponderClaim() } }
        }
    }

    private struct ClaimProbe: View {
        let editing: Bool
        let claiming: Bool
        let capture: (ResponderHog) -> Void

        var body: some View {
            VStack(spacing: 0) {
                Hog(capture: capture).frame(width: 200, height: 100)
                if editing { ClaimedField(claiming: claiming).frame(height: 24) }
            }
            .frame(width: 200, height: 160)
        }
    }

    /// The claim takes the keyboard from an AppKit view that is holding it,
    /// which is what the editor opening over a focused pane has to do and
    /// what SwiftUI's own one-shot request does not manage.
    func testTheClaimTakesFirstResponderFromAViewHoldingIt() async throws {
        let (window, terminal, editor) = try await openEditor(claiming: true)
        defer { window.close() }

        XCTAssertFalse(
            window.firstResponder === terminal,
            "the claim left first responder with the stand-in terminal"
        )
        let responder = try XCTUnwrap(window.firstResponder as? NSTextView, "no field editor took the window's keyboard")
        XCTAssertTrue(responder.isFieldEditor)
        XCTAssertEqual(responder.string, "tabB")
        XCTAssertEqual(
            responder.selectedRange(), NSRange(location: 0, length: 4),
            "the claim did not select the name, so the next keystroke would append to it"
        )
        XCTAssertNotNil(editor, "the editor never reached the window")
    }

    /// The control, and the only thing that keeps the case above from being
    /// a test of SwiftUI rather than of the claim: the same field WITHOUT the
    /// claim behind it leaves first responder exactly where it was.
    func testWithoutTheClaimTheKeyboardStaysWithTheViewThatHasIt() async throws {
        let (window, terminal, _) = try await openEditor(claiming: false)
        defer { window.close() }

        XCTAssertTrue(
            window.firstResponder === terminal,
            "something other than the claim moved first responder, so the case above proves nothing"
        )
    }

    /// Opens the editor over a stand-in terminal that is holding first
    /// responder, and hands back the window, that stand-in, and the field.
    private func openEditor(claiming: Bool) async throws -> (NSWindow, ResponderHog, NSView?) {
        var hog: ResponderHog?
        let hosting = NSHostingView(rootView: ClaimProbe(editing: false, claiming: claiming, capture: { hog = $0 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        await settle(window)

        let terminal = try XCTUnwrap(hog, "the stand-in terminal never reached the window")
        XCTAssertTrue(window.makeFirstResponder(terminal), "the window refused the stand-in terminal")

        hosting.rootView = ClaimProbe(editing: true, claiming: claiming, capture: { hog = $0 })
        await settle(window)
        return (window, terminal, hosting.subviews.first)
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
