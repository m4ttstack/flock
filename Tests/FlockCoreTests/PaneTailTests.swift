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
        XCTAssertEqual(PaneHoverCardCopy.text(of: PaneTailPolicy.make(from: "one\ntwo\n")), "one\ntwo")
    }

    /// A card with nothing read yet, or a pane with a blank screen, offers no
    /// copy at all: a control that puts an empty string on the pasteboard is
    /// worse than no control.
    func testAnEmptyTailOffersNothingToCopy() {
        XCTAssertNil(PaneHoverCardCopy.text(of: nil))
        XCTAssertNil(PaneHoverCardCopy.text(of: PaneTail(lines: [])))
        XCTAssertNil(PaneHoverCardCopy.text(of: PaneTailPolicy.make(from: "\n \n")))
    }

    /// The card is read while scanning a grid, so the cost has to stay small
    /// enough that one pane's card is one read a second and no more.
    func testTheTailIsSmallAndRefreshesSlowly() {
        XCTAssertGreaterThan(PaneTailPolicy.lines, 1)
        XCTAssertLessThanOrEqual(PaneTailPolicy.lines, 12)
        XCTAssertGreaterThanOrEqual(PaneTailPolicy.refreshInterval, .milliseconds(500))
    }

    /// The trim spends rows, so the read has to carry more than the card draws
    /// or a trimmed screen would arrive short of a cardful.
    func testTheReadCarriesACardfulPastTheTallestFrameItWouldDrop() {
        XCTAssertGreaterThanOrEqual(PaneTailPolicy.readLines - PaneTailPolicy.inputFrameRows, PaneTailPolicy.lines)
    }
}

/// The rows an agent's prompt owns, over screens shaped as the panes that
/// prompted this rule really are.
///
/// `zsh` and `nvim` are the two captures that say the rule is off for a plain
/// pane; the agent screen is herdr's own model of a Claude Code prompt (a `─`
/// rule, a field carrying `❯`, a closing rule, then a status strip), which is
/// what its agent detection reads to call such a pane idle.
final class PaneTailInputFrameTests: XCTestCase {
    private let rule = String(repeating: "─", count: 66)

    /// Captured from `nvim -u NONE` in a scratch herdr session: no rules and no
    /// prompt field, so every row is output and the tail is the rows the screen
    /// ends on.
    func testAPlainTUIPaneKeepsEveryRowItEndsOn() {
        let screen = Array(repeating: "~", count: 6) + ["probe.txt                    "]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), screen)
        XCTAssertEqual(PaneTailPolicy.make(from: screen.joined(separator: "\n"), limit: 3).lines, ["~", "~", "probe.txt"])
    }

    /// A shell pane is rows of output under rows of output, whatever its prompt
    /// character is.
    func testAShellPaneKeepsEveryRowItEndsOn() {
        let screen = ["$ swift build", "Compiling FlockCore", "Build complete!", "/private/tmp", "❯"]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), screen)
    }

    /// The complaint: every row under the rule is the agent's own input UI, and
    /// the conversation is the rows above it.
    func testTheRowsAnAgentsPromptOwnsAreDropped() {
        let screen = [
            "● Re-ran the check against the drafted addendum (chronic 30-day window).",
            "● The artifact is live, and the table now matches the addendum.",
            rule,
            "  ❯ ) posted, update the artifact with the new numbers",
            rule,
            "  F 5 [xhigh] | @example.com | 42% context",
            "  auto mode on (shift+tab to cycle)",
            "  cv2-pdf-reliability",
        ]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), Array(screen.prefix(2)))
        XCTAssertEqual(
            PaneTailPolicy.make(from: screen.joined(separator: "\n"), limit: 4).lines,
            Array(screen.prefix(2))
        )
    }

    /// A field the user has typed several rows into is still one field, and the
    /// status strip under the frame goes with it.
    func testAMultiRowFieldAndTheStripUnderItGoTogether() {
        let screen = [
            "● Done.",
            rule,
            "  ❯ first line of the message",
            "    second line of the message",
            rule,
            "",
            "  main · 12% context",
        ]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), ["● Done."])
    }

    /// A frame with nothing typed into it is a box in the output, not a prompt:
    /// the rule fires on the prompt character, never on the rules alone.
    func testAFramedBlockWithNoPromptFieldIsOutput() {
        let screen = [
            "running 3 suites",
            rule,
            "  FlockCoreTests    1130 passed",
            rule,
            "  ok",
        ]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), screen)
    }

    /// Captured from `fzf --border=horizontal --prompt='❯ '` in a scratch herdr
    /// session: a picker's frame carries a prompt character and rules, and the
    /// rows between them are its results, which are the pane's output. A frame
    /// that is a screenful rather than a strip is refused.
    func testAFrameTallerThanAStripIsNotAPrompt() {
        let screen = [rule] + (1...30).reversed().map { "▌ \($0)" } + ["❯   < 30/30 " + rule, rule]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), screen)
    }

    /// A screen whose every row is the agent's prompt shows the prompt rather
    /// than nothing: a blank card is the one outcome worse than a card full of
    /// furniture.
    func testAScreenThatIsNothingButAPromptKeepsItsUntrimmedTail() {
        let screen = [rule, "  ❯", rule, "  main · 12% context"]
        XCTAssertTrue(PaneTailPolicy.outputRows(of: screen).isEmpty)
        XCTAssertEqual(PaneTailPolicy.make(from: screen.joined(separator: "\n")).lines, screen)
    }

    /// Rules in the transcript are not the frame: the frame is the pair the
    /// screen ends on.
    func testRulesEarlierInTheTranscriptAreNotTheFrame() {
        let screen = [
            rule,
            "  ❯ an earlier turn, still on screen",
            rule,
            "● and its answer, which is output",
            rule,
            "  ❯ what is being typed now",
            rule,
            "  main · 12% context",
        ]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), Array(screen.prefix(4)))
    }

    /// Codex marks its field with `›` where Claude Code marks it with `❯`, the
    /// same two marks herdr's agent detection reads.
    func testTheOtherAgentsPromptMarkIsRecognised() {
        let screen = ["• ran the tests", rule, "› ask something", rule, "  ⏎ send"]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), ["• ran the tests"])
    }

    /// `>` opens a quote, a diff hunk and a shell continuation, so it is not a
    /// mark the trim may act on.
    func testAGreaterThanSignIsNotAPromptMark() {
        let screen = ["diff:", rule, "> quoted line from the report", rule, "  end"]
        XCTAssertEqual(PaneTailPolicy.outputRows(of: screen), screen)
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
        XCTAssertEqual(asks, [TailAsk(paneID: pane.rawValue, source: "visible", lines: PaneTailPolicy.readLines)])
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
