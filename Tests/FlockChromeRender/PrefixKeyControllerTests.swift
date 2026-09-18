import AppKit
import FlockCore
import XCTest

/// The two decisions the AppKit half owns: which key presses it takes out of
/// the responder chain, and when it takes none at all.
@MainActor
final class PrefixKeyControllerTests: XCTestCase {
    private func event(
        _ characters: String, _ unmodified: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: unmodified,
            isARepeat: false, keyCode: keyCode
        )!
    }

    private func controller(
        typing: Bool = false, into intents: Intents
    ) -> PrefixKeyController {
        PrefixKeyController(
            source: HerdrKeybindingsSource(
                stamp: { HerdrConfigStamp(modified: Date(timeIntervalSince1970: 0), size: 1) },
                contents: {
                    """
                    [keys]
                    prefix = "ctrl+a"
                    """
                }
            ),
            isTyping: { typing },
            context: { PrefixActionContext(focusedPane: PaneID(rawValue: "w1:p1")) },
            run: { intents.ran.append($0) }
        )
    }

    private final class Intents {
        var ran: [PrefixIntent] = []
    }

    /// Ctrl+A is beginning-of-line to the program in the pane; the prefix
    /// takes it, so it must not also arrive there.
    func testThePrefixPressIsTakenOutOfTheChain() {
        let intents = Intents()
        let controller = controller(into: intents)
        XCTAssertNil(controller.handle(event("\u{01}", "a", .control)))
        XCTAssertTrue(controller.isAwaitingKey)
    }

    func testABoundSecondKeyRunsItsIntentAndIsTaken() {
        let intents = Intents()
        let controller = controller(into: intents)
        _ = controller.handle(event("\u{01}", "a", .control))
        XCTAssertNil(controller.handle(event("x", "x")))
        XCTAssertEqual(intents.ran, [.closePane(PaneID(rawValue: "w1:p1"))])
        XCTAssertFalse(controller.isAwaitingKey)
    }

    func testAnOrdinaryKeyGoesStraightThrough() {
        let intents = Intents()
        let controller = controller(into: intents)
        XCTAssertNotNil(controller.handle(event("x", "x")))
        XCTAssertTrue(intents.ran.isEmpty)
    }

    /// While a rename editor is up every key is text, the prefix included.
    func testNothingIsTakenWhileTheUserIsTyping() {
        let intents = Intents()
        let controller = controller(typing: true, into: intents)
        XCTAssertNotNil(controller.handle(event("\u{01}", "a", .control)))
        XCTAssertFalse(controller.isAwaitingKey)
    }
}
