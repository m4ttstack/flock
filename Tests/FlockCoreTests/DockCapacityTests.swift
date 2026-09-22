import XCTest
@testable import FlockCore

final class DockCapacityTests: XCTestCase {
    /// Cards 50pt tall, 6pt apart, a 20pt pill, 20pt of rule and insets.
    private func limit(cards: Int, rail: Double, fixed: Double = 20) -> Int {
        DockCapacity.cardLimit(
            cards: cards, railHeight: rail, fixedHeight: fixed, cardHeight: 50, pillHeight: 20, spacing: 6
        )
    }

    func testTheDockTakesAtMostFortyPercentOfTheRail() {
        XCTAssertEqual(DockCapacity.maximumShareOfRail, 0.4)
    }

    func testThreeOrFewerCardsAreAlwaysAllDrawn() {
        XCTAssertEqual(limit(cards: 0, rail: 1000), 0)
        XCTAssertEqual(limit(cards: 2, rail: 1000), 2)
        XCTAssertEqual(limit(cards: 3, rail: 100), 3)
    }

    /// A short rail keeps the three cards the dock always drew, whatever its
    /// share works out to.
    func testAShortRailStillDrawsTheMinimum() {
        XCTAssertEqual(limit(cards: 8, rail: 500), AttentionToastStack.minimumVisible)
    }

    /// 1000pt of rail is 400pt of dock, 380pt after the fixed 20: six cards
    /// (6 x 50 + 5 x 6 = 330) fit with no pill.
    func testATallRailDrawsEveryCardThatFits() {
        XCTAssertEqual(limit(cards: 6, rail: 1000), 6)
    }

    /// Seven cards need 7 x 50 + 6 x 6 = 386pt, past 380, so the pill takes
    /// the place of what does not fit: six cards over it would need
    /// 6 x 50 + 20 + 6 x 6 = 356pt, which does.
    func testPastWhatFitsTheRestGoUnderThePill() {
        XCTAssertEqual(limit(cards: 7, rail: 1000), 6)
        XCTAssertEqual(limit(cards: 20, rail: 1000), 6)
    }

    /// The notice is part of the fixed height, so a long one leaves room for
    /// fewer cards.
    func testANoticeLeavesLessRoomForCards() {
        XCTAssertEqual(limit(cards: 20, rail: 1000, fixed: 100), 5)
    }

    /// Before a card has been measured there is nothing to fit against.
    func testAnUnmeasuredCardDrawsTheMinimum() {
        XCTAssertEqual(
            DockCapacity.cardLimit(cards: 9, railHeight: 2000, fixedHeight: 0, cardHeight: 0, pillHeight: 0, spacing: 6),
            AttentionToastStack.minimumVisible
        )
    }
}
