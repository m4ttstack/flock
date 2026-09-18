import Foundation
import XCTest
@testable import FlockCore

final class PaneTailTests: XCTestCase {
    func testTheTailIsTheLinesTheScreenEndsOn() {
        let tail = PaneTailPolicy.make(from: "one\ntwo\nthree\n", limit: 2)
        XCTAssertEqual(tail.lines, ["two", "three"])
        XCTAssertFalse(tail.isEmpty)
    }

    /// A shell at a fresh prompt leaves a blank row after its last output, and
    /// a card that ends in blank rows is a card that has thrown away the lines
    /// the reader wanted.
    func testBlankRowsAtEitherEndAreDropped() {
        XCTAssertEqual(PaneTailPolicy.make(from: "\n\nbuilt in 1.2s\n\n").lines, ["built in 1.2s"])
        XCTAssertEqual(PaneTailPolicy.make(from: "   \nrunning\n   \n").lines, ["running"])
    }

    /// Interior blanks are the pane's own shape, so they stay.
    func testABlankLineInsideTheTailIsKept() {
        XCTAssertEqual(PaneTailPolicy.make(from: "one\n\ntwo").lines, ["one", "", "two"])
    }

    /// Trailing spaces are the terminal padding a row out, never something the
    /// user asked to copy.
    func testTrailingSpacesAreCutFromEveryLine() {
        XCTAssertEqual(PaneTailPolicy.make(from: "ok   \t\nnext  ").lines, ["ok", "next"])
    }

    func testAScreenOfNothingIsAnEmptyTail() {
        XCTAssertTrue(PaneTailPolicy.make(from: "").isEmpty)
        XCTAssertTrue(PaneTailPolicy.make(from: "\n \n\t\n").isEmpty)
    }

    /// herdr caps `lines` itself, but the card decides what it can draw: an
    /// answer longer than was asked for must not stretch the card.
    func testMoreLinesThanAskedForAreCutFromTheTop() {
        let tail = PaneTailPolicy.make(from: (1...20).map(String.init).joined(separator: "\n"))
        XCTAssertEqual(tail.lines.count, PaneTailPolicy.lines)
        XCTAssertEqual(tail.lines.last, "20")
    }

    /// What the copy button puts on the pasteboard is what the card shows,
    /// line for line.
    func testTheCopiedTextIsTheLinesTheCardShows() {
        XCTAssertEqual(PaneTailPolicy.make(from: "one\ntwo\n").text, "one\ntwo")
        XCTAssertEqual(PaneTail(lines: []).text, "")
    }

    /// The card is read while scanning a grid, so the cost has to stay small
    /// enough that one pane's card is one read a second and no more.
    func testTheTailIsSmallAndRefreshesSlowly() {
        XCTAssertGreaterThan(PaneTailPolicy.lines, 1)
        XCTAssertLessThanOrEqual(PaneTailPolicy.lines, 12)
        XCTAssertGreaterThanOrEqual(PaneTailPolicy.refreshInterval, .milliseconds(500))
    }
}

/// What a `pane.read` for the card asks for, which is the whole of what the
/// grid ever costs herdr: the grid attaches nothing, so this request is how it
/// shows output at all.
private struct TailAsk: Decodable, Equatable {
    let paneID: String
    let source: String
    let lines: Int

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case lines
    }
}

private actor TailReadClient: HerdrCommandClient {
    private(set) var asks: [TailAsk] = []
    private let screen: String

    init(screen: String) {
        self.screen = screen
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read", let encoded = try? JSONEncoder().encode(params),
              let ask = try? JSONDecoder().decode(TailAsk.self, from: encoded)
        else {
            return Data("{}".utf8)
        }
        asks.append(ask)
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": screen]]])
    }
}

@MainActor
final class PaneTailReadTests: XCTestCase {
    private let pane = PaneID(rawValue: "w1:p1")

    private struct NeverRead: Error {}

    private func tail(_ viewModel: SessionViewModel) async throws -> PaneTail {
        for _ in 0..<200 {
            if let tail = viewModel.paneTails[pane] { return tail }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the read never landed")
        throw NeverRead()
    }

    func testTheCardAsksForTheVisibleTailOfTheOnePaneItIsShowing() async throws {
        let client = TailReadClient(screen: "one\ntwo\n")
        let viewModel = SessionViewModel(client: client)
        XCTAssertNil(viewModel.paneTail(for: pane), "nothing is cached, so the first ask is the read")
        let landed = try await tail(viewModel)
        XCTAssertEqual(landed.lines, ["one", "two"])
        let asks = await client.asks
        XCTAssertEqual(asks, [TailAsk(paneID: pane.rawValue, source: "visible", lines: PaneTailPolicy.lines)])
    }

    /// Every render of the card asks for the tail, and the card's cadence asks
    /// again on top of that. One read at a time is what keeps that from piling
    /// requests on a pane that is slow to answer.
    func testAsksWhileAReadIsStillOutAddNoSecondRead() async throws {
        let client = TailReadClient(screen: "x")
        let viewModel = SessionViewModel(client: client)
        _ = viewModel.paneTail(for: pane)
        viewModel.refreshPaneTail(for: pane)
        _ = viewModel.paneTail(for: pane)
        let landed = try await tail(viewModel)
        XCTAssertEqual(landed.lines, ["x"])
        let asks = await client.asks
        XCTAssertEqual(asks.count, 1)
    }

    /// The cached tail is never the answer to a refresh: a pane that is
    /// printing changes nothing the model reports, so only reading again can
    /// tell the card anything new.
    func testARefreshReadsAgainOnceTheLastReadHasLanded() async throws {
        let client = TailReadClient(screen: "x")
        let viewModel = SessionViewModel(client: client)
        _ = viewModel.paneTail(for: pane)
        _ = try await tail(viewModel)
        viewModel.refreshPaneTail(for: pane)
        var asks = await client.asks
        var attempts = 0
        while asks.count < 2, attempts < 200 {
            try await Task.sleep(for: .milliseconds(5))
            asks = await client.asks
            attempts += 1
        }
        XCTAssertEqual(asks.count, 2)
    }
}
