import XCTest
@testable import FlockCore

final class ChatPopoverEscTests: XCTestCase {
    func testEscAtTheRootClosesTheOpenPopoverAndIsConsumed() {
        var presented = true
        var drilledIn = false
        XCTAssertTrue(ChatPopoverEsc.handle(isPresented: &presented, isDrilledIn: &drilledIn))
        XCTAssertFalse(presented)
        XCTAssertFalse(drilledIn)
    }

    /// The chevron's own destination: one press steps back to the status
    /// root and leaves the popover itself open, exactly one level spent.
    func testEscInAFeatureSubViewStepsBackRatherThanClosing() {
        var presented = true
        var drilledIn = true
        XCTAssertTrue(ChatPopoverEsc.handle(isPresented: &presented, isDrilledIn: &drilledIn))
        XCTAssertTrue(presented)
        XCTAssertFalse(drilledIn)
    }

    /// Nothing to close, so this press is not spent: it has somewhere else to
    /// be (the rest of the responder chain, ending at the pane).
    func testEscOnAClosedPopoverIsNotConsumed() {
        var presented = false
        var drilledIn = false
        XCTAssertFalse(ChatPopoverEsc.handle(isPresented: &presented, isDrilledIn: &drilledIn))
        XCTAssertFalse(presented)
        XCTAssertFalse(drilledIn)
    }
}
