import XCTest
@testable import FlockCore

final class WorkspaceBlockMoveTests: XCTestCase {
    private func ids(_ raw: String...) -> [WorkspaceID] {
        raw.map { WorkspaceID(rawValue: $0) }
    }

    private func replay(_ moves: [(block: [WorkspaceID], before: WorkspaceID?)], on order: [WorkspaceID]) -> [WorkspaceID]? {
        var current = order
        for move in moves {
            guard let next = WorkspaceBlockMove.apply(block: move.block, before: move.before, to: current) else { return nil }
            current = next
        }
        return current
    }

    // MARK: - apply mirrors herdr's move_workspace_block

    /// herdr's own `move_workspace_block_collects_non_contiguous_members`
    /// case, verbatim: the block lands in its LISTED order before the anchor.
    func testApplyMatchesHerdrsOwnNonContiguousCase() {
        let order = ids("child-one", "normal", "parent", "child-two", "tail")
        let result = WorkspaceBlockMove.apply(block: ids("parent", "child-one", "child-two"), before: WorkspaceID(rawValue: "tail"), to: order)
        XCTAssertEqual(result, ids("normal", "parent", "child-one", "child-two", "tail"))
    }

    func testApplyWithNoAnchorAppendsTheBlockAtTheEnd() {
        XCTAssertEqual(WorkspaceBlockMove.apply(block: ids("w3", "w1"), before: nil, to: ids("w1", "w2", "w3")), ids("w2", "w3", "w1"))
    }

    func testApplyRejectsWhatHerdrRejects() {
        let order = ids("w1", "w2", "w3")
        XCTAssertNil(WorkspaceBlockMove.apply(block: [], before: nil, to: order), "empty block")
        XCTAssertNil(WorkspaceBlockMove.apply(block: ids("w1", "w1"), before: nil, to: order), "duplicate member")
        XCTAssertNil(WorkspaceBlockMove.apply(block: ids("w1", "w9"), before: nil, to: order), "unknown member")
        XCTAssertNil(WorkspaceBlockMove.apply(block: ids("w1", "w2"), before: WorkspaceID(rawValue: "w2"), to: order), "anchor inside the block")
        XCTAssertNil(WorkspaceBlockMove.apply(block: ids("w1"), before: WorkspaceID(rawValue: "w9"), to: order), "unknown anchor")
    }

    // MARK: - anchor

    func testAnchorIsTheFirstUnmovedWorkspaceAtOrPastTheGap() {
        let order = ids("w1", "w2", "w3", "w4")
        let block = ids("w1", "w3")
        XCTAssertEqual(WorkspaceBlockMove.anchor(forInsertIndex: 0, block: block, order: order), WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(WorkspaceBlockMove.anchor(forInsertIndex: 1, block: block, order: order), WorkspaceID(rawValue: "w2"))
        XCTAssertEqual(WorkspaceBlockMove.anchor(forInsertIndex: 2, block: block, order: order), WorkspaceID(rawValue: "w4"))
        XCTAssertNil(WorkspaceBlockMove.anchor(forInsertIndex: 4, block: block, order: order))
    }

    func testAnchorForTheGapBetweenTwoTrailingMembersIsTheEnd() {
        XCTAssertNil(WorkspaceBlockMove.anchor(forInsertIndex: 2, block: ids("w2", "w3"), order: ids("w1", "w2", "w3")))
    }

    // MARK: - inverse restores the exact prior order

    func testInverseOfAContiguousBlockIsOneMove() {
        let prior = ids("w1", "w2", "w3", "w4")
        let inverse = WorkspaceBlockMove.inverse(block: ids("w3", "w4"), before: WorkspaceID(rawValue: "w1"), prior: prior)
        XCTAssertEqual(inverse.map(\.block), [ids("w3", "w4")])
        XCTAssertEqual(inverse.map(\.before), [nil])
        let forward = WorkspaceBlockMove.apply(block: ids("w3", "w4"), before: WorkspaceID(rawValue: "w1"), to: prior)!
        XCTAssertEqual(replay(inverse, on: forward), prior)
    }

    func testInverseOfAScatteredBlockMovesEachRunBackBeforeItsOwnFollower() {
        let prior = ids("w1", "w2", "w3", "w4")
        let inverse = WorkspaceBlockMove.inverse(block: ids("w1", "w3"), before: nil, prior: prior)
        XCTAssertEqual(inverse.map(\.block), [ids("w1"), ids("w3")])
        XCTAssertEqual(inverse.map(\.before), [WorkspaceID(rawValue: "w2"), WorkspaceID(rawValue: "w4")])
    }

    func testInverseDropsARunTheForwardMoveLeftInPlace() {
        // [w1, w3] before w4 gives [w2, w1, w3, w4]: w3 is already back
        // before w4 once w1 returns, and a no-op move emits no event.
        let prior = ids("w1", "w2", "w3", "w4")
        let inverse = WorkspaceBlockMove.inverse(block: ids("w1", "w3"), before: WorkspaceID(rawValue: "w4"), prior: prior)
        XCTAssertEqual(inverse.map(\.block), [ids("w1")])
        XCTAssertEqual(inverse.map(\.before), [WorkspaceID(rawValue: "w2")])
    }

    /// Every block, every anchor, every listing order over a six-workspace
    /// rail: the inverse replayed on the forward result is the prior order,
    /// and none of its moves is one herdr would reject or ignore.
    func testInverseRoundTripsEverySelectionOverASixWorkspaceRail() {
        let prior = ids("a", "b", "c", "d", "e", "f")
        var checked = 0
        for mask in 1..<(1 << prior.count) {
            let inRailOrder = prior.indices.filter { mask & (1 << $0) != 0 }.map { prior[$0] }
            for block in [inRailOrder, Array(inRailOrder.reversed())] {
                let anchors: [WorkspaceID?] = [nil] + prior.filter { !block.contains($0) }
                for before in anchors {
                    guard let forward = WorkspaceBlockMove.apply(block: block, before: before, to: prior) else {
                        XCTFail("a valid forward move was rejected: \(block) before \(String(describing: before))")
                        continue
                    }
                    let inverse = WorkspaceBlockMove.inverse(block: block, before: before, prior: prior)
                    var current = forward
                    for move in inverse {
                        guard let next = WorkspaceBlockMove.apply(block: move.block, before: move.before, to: current) else {
                            XCTFail("inverse move rejected: \(move)")
                            break
                        }
                        XCTAssertNotEqual(next, current, "inverse carries a move that changes nothing")
                        current = next
                    }
                    XCTAssertEqual(current, prior, "\(block) before \(String(describing: before))")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 400)
    }
}
