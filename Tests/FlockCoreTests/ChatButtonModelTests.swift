import AppKit
import XCTest
@testable import FlockCore

final class ChatButtonModelTests: XCTestCase {
    private func status(signedIn: Bool, handle: String? = "kay", name: String? = nil) -> ChatStatus {
        ChatStatus(
            handle: signedIn ? handle : nil, name: signedIn ? name : nil, state: signedIn ? "live" : "not signed in",
            pane: "w1:p1", signedIn: signedIn, rooms: signedIn ? ["#rt"] : []
        )
    }

    func testNoBinaryIsAbsentRegardlessOfStatus() {
        XCTAssertEqual(
            ChatButtonModel.appearance(agent: "claude", availability: false, status: status(signedIn: true), unread: 3), .absent
        )
        XCTAssertEqual(ChatButtonModel.appearance(agent: "claude", availability: false, status: nil, unread: 0), .absent)
    }

    /// Chat is for Claude Code: a shell, another agent, or a pane herdr has
    /// named no agent for draws no button, whatever chat's own state.
    func testOnlyAClaudeCodePaneDrawsTheButton() {
        for agent in [nil, "codex", ""] as [String?] {
            XCTAssertEqual(
                ChatButtonModel.appearance(agent: agent, availability: true, status: status(signedIn: true), unread: 2),
                .absent, "agent=\(agent ?? "none")"
            )
        }
    }

    /// The boundary a caller must never collapse: chat exists on this machine
    /// but the status probe has not answered for this pane yet. That reads as
    /// signed out, not as absent.
    func testAvailableWithNoStatusYetReadsAsSignedOut() {
        XCTAssertEqual(ChatButtonModel.appearance(agent: "claude", availability: true, status: nil, unread: 0), .signedOut)
    }

    func testSignedOutStatusReadsAsSignedOut() {
        XCTAssertEqual(
            ChatButtonModel.appearance(agent: "claude", availability: true, status: status(signedIn: false), unread: 0), .signedOut
        )
    }

    func testSignedInStatusCarriesTheNameAndUnreadCount() {
        XCTAssertEqual(
            ChatButtonModel.appearance(
                agent: "claude", availability: true, status: status(signedIn: true, handle: "kay.k3f9", name: "kay"), unread: 3
            ),
            .signedIn(name: "kay", unread: 3)
        )
    }

    /// A legacy identity has no name row: its id is its name, so the handle
    /// is what the legend draws.
    func testALegacyStatusWithNoNameDrawsItsHandle() {
        XCTAssertEqual(
            ChatButtonModel.appearance(agent: "claude", availability: true, status: status(signedIn: true, handle: "kay"), unread: 0),
            .signedIn(name: "kay", unread: 0)
        )
    }

    /// The legend never shows an `@`, even from a herdr-chat that prints one.
    func testAnAtPrefixedHandleIsDrawnWithoutIt() {
        XCTAssertEqual(
            ChatButtonModel.appearance(agent: "claude", availability: true, status: status(signedIn: true, handle: "@kay"), unread: 0),
            .signedIn(name: "kay", unread: 0)
        )
    }

    /// A typo'd symbol name resolves to nothing, silently -- this is the one
    /// guard that catches it before it ships as an invisible glyph.
    func testTheChatGlyphSymbolResolves() {
        XCTAssertNotNil(NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil))
    }
}
