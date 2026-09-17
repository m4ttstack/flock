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

    // MARK: - What a torn-down editor does with what was typed in it

    private struct TeardownProbe: View {
        let editing: Bool
        let onCommit: (String) -> Void
        let onCancel: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(width: 200, height: 100)
                if editing {
                    InlineRenameField(
                        theme: Theme.builtins[0], font: .body, initialText: "tabB",
                        accessibilityIdentifier: "probe.rename", onCommit: onCommit, onCancel: onCancel
                    )
                    .frame(width: 200, height: 24)
                }
            }
            .frame(width: 200, height: 160)
        }
    }

    /// An editor is destroyed without the user dismissing it whenever the tab
    /// or workspace it was opened on stops being drawn -- a toast jump, a
    /// click on another rail row, a `workspace.focus` from herdr itself. What
    /// it does with the half-typed name it was holding decides whether that
    /// is a silent rename or a silently dropped edit, and neither is
    /// something a caller should have to guess at.
    func testAnEditorTornDownWithoutBeingDismissed() async throws {
        var committed: [String] = []
        var cancelled = 0
        let hosting = NSHostingView(rootView: TeardownProbe(
            editing: false, onCommit: { committed.append($0) }, onCancel: { cancelled += 1 }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        await settle(window)

        hosting.rootView = TeardownProbe(
            editing: true, onCommit: { committed.append($0) }, onCancel: { cancelled += 1 }
        )
        await settle(window)
        XCTAssertTrue(window.firstResponder is NSTextView, "the editor never took the keyboard, so this measures nothing")

        hosting.rootView = TeardownProbe(
            editing: false, onCommit: { committed.append($0) }, onCancel: { cancelled += 1 }
        )
        await settle(window)

        // Recorded rather than asserted either way: this is the measurement
        // the visibility rule was written against, and its answer is what
        // says whether a torn-down editor renames anything behind the user's
        // back. It commits nothing and cancels nothing: the edit is dropped
        // where it stands, which is why the stale target below had to be the
        // thing that got fixed.
        XCTAssertEqual(committed, [], "a torn-down editor committed a name the user never finished")
        XCTAssertEqual(cancelled, 0, "a torn-down editor reported a cancel nobody asked for")

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
