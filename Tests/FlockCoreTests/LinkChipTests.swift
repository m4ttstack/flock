import XCTest
@testable import FlockCore

/// When the link chip comes up, how long it stays, and where it sits. The
/// chip covers the line above a link, so one that appears on a pass, or will
/// not leave, costs more than it gives.
final class LinkChipTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private let sheet = PaneLink.file(URL(fileURLWithPath: "/Users/acme/sheet.html"))
    private let notes = PaneLink.file(URL(fileURLWithPath: "/Users/acme/notes.md"))

    private let rest = LinkChipState.rest
    private let grace = LinkChipState.grace

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func anchor(x: CGFloat = 200) -> LinkChip.Anchor {
        LinkChip.Anchor(x: x, lineTop: 100, lineBottom: 117)
    }

    private func resting(on link: PaneLink) -> LinkChipState {
        var state = LinkChipState()
        state.hover(link, anchor: anchor(), now: start)
        return state
    }

    // MARK: - Coming up

    func testNothingShowsBeforeThePointerHasRested() {
        let state = resting(on: sheet)
        XCTAssertNil(state.chip(at: at(rest - 0.01)))
        XCTAssertEqual(state.deadline, at(rest))
    }

    func testTheChipComesUpAfterTheRest() {
        XCTAssertEqual(resting(on: sheet).chip(at: at(rest))?.link, sheet)
    }

    func testARestThatHasEndedLeavesNothingToWaitFor() {
        var state = resting(on: sheet)
        state.tick(at(rest))
        XCTAssertNil(state.deadline)
    }

    func testAPassOverALinkShowsNothing() {
        var state = resting(on: sheet)
        state.hover(nil, anchor: anchor(), now: at(0.1))
        XCTAssertNil(state.chip(at: at(1)))
        XCTAssertNil(state.deadline)
    }

    func testMovingAlongTheSameLinkKeepsTheRest() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(x: 260), now: at(rest - 0.1))
        XCTAssertEqual(state.chip(at: at(rest))?.anchor.x, 260)
    }

    func testAnotherLinkStartsItsOwnRest() {
        var state = resting(on: sheet)
        state.hover(notes, anchor: anchor(), now: at(0.2))
        XCTAssertNil(state.chip(at: at(rest + 0.1)))
        XCTAssertEqual(state.chip(at: at(rest + 0.2))?.link, notes)
    }

    /// The pointer is on its way to the chip, which must not slide off.
    func testTheChipStaysWhereItCameUp() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(x: 320), now: at(rest + 0.2))
        XCTAssertEqual(state.chip(at: at(rest + 0.2))?.anchor.x, 200)
    }

    // MARK: - Leaving

    func testTheChipOutlivesThePointerLeavingItsLink() {
        var state = resting(on: sheet)
        state.hover(nil, anchor: anchor(), now: at(1))
        XCTAssertNotNil(state.chip(at: at(1 + grace - 0.01)))
        XCTAssertNil(state.chip(at: at(1 + grace)))
    }

    func testThePointerOnTheChipHoldsIt() {
        var state = resting(on: sheet)
        state.hover(nil, anchor: anchor(), now: at(1))
        state.chipHover(true, now: at(1.1))
        XCTAssertNotNil(state.chip(at: at(60)))
        XCTAssertNil(state.deadline)
    }

    func testLeavingTheChipLetsItGo() {
        var state = resting(on: sheet)
        state.hover(nil, anchor: anchor(), now: at(1))
        state.chipHover(true, now: at(1.1))
        state.chipHover(false, now: at(5))
        XCTAssertNotNil(state.chip(at: at(5 + grace - 0.01)))
        XCTAssertNil(state.chip(at: at(5 + grace)))
    }

    func testComingBackToTheLinkKeepsTheChip() {
        var state = resting(on: sheet)
        state.hover(nil, anchor: anchor(), now: at(1))
        state.hover(sheet, anchor: anchor(), now: at(1.2))
        XCTAssertNotNil(state.chip(at: at(60)))
    }

    /// The way from a link up to its chip crosses the row above.
    func testAnotherLinkOnTheWayToTheChipDoesNotTakeIt() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(), now: at(1))
        state.hover(notes, anchor: anchor(), now: at(1.05))
        XCTAssertEqual(state.chip(at: at(1.05))?.link, sheet)
        state.chipHover(true, now: at(1.1))
        XCTAssertEqual(state.chip(at: at(60))?.link, sheet)
    }

    func testStayingOnAnotherLinkBringsItsOwnChip() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(), now: at(1))
        state.hover(notes, anchor: anchor(x: 90), now: at(1.05))
        XCTAssertEqual(state.chip(at: at(1.05 + grace - 0.01))?.link, sheet)
        XCTAssertEqual(state.chip(at: at(1.05 + max(rest, grace))), LinkChip(link: notes, anchor: anchor(x: 90)))
    }

    func testBackAndForthBetweenALinkAndItsChipKeepsTheChip() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(), now: at(1))
        for round in 0..<3 {
            let time = 2 + Double(round)
            state.hover(notes, anchor: anchor(), now: at(time))
            state.chipHover(true, now: at(time + 0.1))
            state.chipHover(false, now: at(time + 0.5))
            state.hover(notes, anchor: anchor(), now: at(time + 0.55))
            state.hover(sheet, anchor: anchor(), now: at(time + 0.6))
            XCTAssertEqual(state.chip(at: at(time + 0.9))?.link, sheet, "round \(round)")
        }
    }

    // MARK: - Sent away

    func testADismissedChipStaysAwayWhileThePointerIsOnTheSameLink() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(), now: at(1))
        state.dismiss()
        XCTAssertNil(state.chip(at: at(1)))
        state.hover(sheet, anchor: anchor(), now: at(1.1))
        XCTAssertNil(state.chip(at: at(60)))
    }

    func testADismissedLinkAnswersAgainOnceThePointerHasLeftIt() {
        var state = resting(on: sheet)
        state.hover(sheet, anchor: anchor(), now: at(1))
        state.dismiss()
        state.hover(nil, anchor: anchor(), now: at(2))
        state.hover(sheet, anchor: anchor(), now: at(3))
        XCTAssertEqual(state.chip(at: at(3 + rest))?.link, sheet)
    }

    func testAKeyDuringTheRestCancelsIt() {
        var state = resting(on: sheet)
        state.dismiss()
        XCTAssertNil(state.chip(at: at(1)))
    }

    // MARK: - An action taken

    func testAnActionLightsItsButtonThenTheChipGoes() {
        var state = resting(on: sheet)
        state.act(.second, on: sheet, anchor: anchor(), now: at(1))
        let over = 1 + LinkChipState.flash
        XCTAssertEqual(state.flash(at: at(over - 0.01)), .second)
        XCTAssertNotNil(state.chip(at: at(over - 0.01)))
        XCTAssertNil(state.chip(at: at(over)))
        XCTAssertNil(state.flash(at: at(over)))
    }

    func testTheChipSaysSoWhereItAlreadyIs() {
        var state = resting(on: sheet)
        state.act(.open, on: sheet, anchor: anchor(x: 400), now: at(1))
        XCTAssertEqual(state.chip(at: at(1))?.anchor.x, 200)
    }

    func testAClickBeforeTheRestIsOverBringsTheChipUpToSaySo() {
        var state = resting(on: sheet)
        state.act(.open, on: sheet, anchor: anchor(x: 400), now: at(0.1))
        XCTAssertEqual(state.chip(at: at(0.1))?.anchor.x, 400)
        XCTAssertEqual(state.flash(at: at(0.1)), .open)
    }

    func testThePointerStillOnTheLinkDoesNotBringTheChipBackAfterAnAction() {
        var state = resting(on: sheet)
        state.act(.open, on: sheet, anchor: anchor(), now: at(1))
        state.hover(sheet, anchor: anchor(), now: at(1.05))
        state.hover(sheet, anchor: anchor(), now: at(2))
        XCTAssertNil(state.chip(at: at(60)))
    }

    // MARK: - Placement

    private let chip = CGSize(width: 120, height: 22)
    private let pane = CGSize(width: 600, height: 400)

    private func origin(_ anchor: LinkChip.Anchor) -> CGPoint {
        LinkChip.origin(for: anchor, chip: chip, pane: pane, gap: 3, inset: 4)
    }

    func testTheChipSitsCentredAboveTheLine() {
        XCTAssertEqual(origin(anchor()), CGPoint(x: 140, y: 75))
    }

    func testTheChipStaysInsideThePaneAtEitherEdge() {
        XCTAssertEqual(origin(anchor(x: 10)).x, 4)
        XCTAssertEqual(origin(anchor(x: 595)).x, 476)
    }

    func testTheChipGoesUnderALinkOnTheFirstLine() {
        let top = LinkChip.Anchor(x: 200, lineTop: 0, lineBottom: 17)
        XCTAssertEqual(origin(top).y, 20)
    }
}
