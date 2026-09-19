import XCTest
@testable import FlockCore

final class ChatPopoverEscTests: XCTestCase {
    func testEscClosesAnOpenPopoverAndIsConsumed() {
        var presented = true
        XCTAssertTrue(ChatPopoverEsc.handle(isPresented: &presented))
        XCTAssertFalse(presented)
    }

    /// Nothing to close, so this press is not spent: it has somewhere else to
    /// be (the rest of the responder chain, ending at the pane).
    func testEscOnAClosedPopoverIsNotConsumed() {
        var presented = false
        XCTAssertFalse(ChatPopoverEsc.handle(isPresented: &presented))
        XCTAssertFalse(presented)
    }
}
