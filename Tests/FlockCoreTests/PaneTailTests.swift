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

    /// A full-screen TUI draws its list at the top and its key hints at the
    /// foot, with blank rows between; the card keeps the list.
    func testARunOfBlankRowsCollapsesToOneSoATUIsTopStaysOnTheCard() {
        let list = (1...8).map { "account \($0)" }
        let screen = ["watching all accounts", ""] + list + Array(repeating: "", count: 30) + ["Confirm  s Switch  esc Back"]
        let tail = PaneTailPolicy.make(from: screen.joined(separator: "\n"), limit: 12)
        XCTAssertEqual(tail.lines, ["watching all accounts", ""] + list + ["", "Confirm  s Switch  esc Back"])
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

    /// What Copy Output puts on the pasteboard is the tail as read, line for
    /// line.
    func testTheCopiedTextIsTheLinesAsRead() {
        XCTAssertEqual(PaneTailPolicy.make(from: "one\ntwo\n").text, "one\ntwo")
        XCTAssertEqual(PaneTail(lines: []).text, "")
        XCTAssertEqual(PaneOutputCopy.text(of: PaneTailPolicy.make(from: "one\ntwo\n")), "one\ntwo")
    }

    /// A pane with nothing read yet, or a blank screen, offers no copy at
    /// all.
    func testAnEmptyTailOffersNothingToCopy() {
        XCTAssertNil(PaneOutputCopy.text(of: nil))
        XCTAssertNil(PaneOutputCopy.text(of: PaneTail(lines: [])))
        XCTAssertNil(PaneOutputCopy.text(of: PaneTailPolicy.make(from: "\n \n")))
    }

    /// A tail is a screenful of output, not a scrollback.
    func testATailKeepsAShortRunOfLines() {
        XCTAssertGreaterThan(PaneTailPolicy.lines, 1)
        XCTAssertLessThanOrEqual(PaneTailPolicy.lines, 20)
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
            "● Re-ran the check against the drafted schedule (rolling 30-day window).",
            "● The artifact is live, and the table now matches the schedule.",
            rule,
            "  ❯ ) posted, update the artifact with the new numbers",
            rule,
            "  F 5 [xhigh] | @acme.example | 42% context",
            "  auto mode on (shift+tab to cycle)",
            "  acme-pdf-reliability",
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
    let format: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case lines
        case format
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

/// A herdr that predates the ansi read format: it refuses the format, or
/// answers it with something that is not a read.
private actor PlainOnlyReadClient: HerdrCommandClient {
    enum AnsiAnswer { case refused, unreadable }

    private(set) var formats: [String?] = []
    private let screen: String
    private let ansiAnswer: AnsiAnswer

    init(screen: String, ansiAnswer: AnsiAnswer) {
        self.screen = screen
        self.ansiAnswer = ansiAnswer
    }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { return Data("{}".utf8) }
        let format: String? = if case let .string(value) = params["format"] { value } else { nil }
        formats.append(format)
        guard format == nil else {
            switch ansiAnswer {
            case .refused: throw HerdrClientError.server(code: "invalid_params", message: "unknown variant `ansi`")
            case .unreadable: return Data(#"{"result":{"type":"ok"}}"#.utf8)
            }
        }
        return try JSONSerialization.data(withJSONObject: ["result": ["read": ["text": screen]]])
    }
}

/// The first read, an ansi one, fails on the wire; every later read answers.
private actor FlakyAnsiReadClient: HerdrCommandClient {
    private(set) var formats: [String?] = []
    private let screen: String

    init(screen: String) { self.screen = screen }

    func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        guard method == "pane.read" else { return Data("{}".utf8) }
        let format: String? = if case let .string(value) = params["format"] { value } else { nil }
        formats.append(format)
        if formats.count == 1 { throw HerdrClientError.transport("connection reset") }
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

    func testARefreshAsksForTheVisibleTailOfItsPane() async throws {
        let client = TailReadClient(screen: "one\ntwo\n")
        let viewModel = SessionViewModel(client: client)
        viewModel.refreshPaneTail(for: pane)
        XCTAssertNil(viewModel.paneTails[pane], "nothing is cached until the read lands")
        let landed = try await tail(viewModel)
        XCTAssertEqual(landed.lines, ["one", "two"])
        let asks = await client.asks
        XCTAssertEqual(asks, [TailAsk(paneID: pane.rawValue, source: "visible", lines: PaneTailPolicy.readLines, format: "ansi")])
    }

    func testAnOlderHerdrThatRefusesTheAnsiFormatStillShowsAPlainTail() async throws {
        for answer in [PlainOnlyReadClient.AnsiAnswer.refused, .unreadable] {
            let client = PlainOnlyReadClient(screen: "one\ntwo\n", ansiAnswer: answer)
            let viewModel = SessionViewModel(client: client)
            viewModel.refreshPaneTail(for: pane)
            let landed = try await tail(viewModel)
            XCTAssertEqual(landed.lines, ["one", "two"], "\(answer)")
            let formats = await client.formats
            XCTAssertEqual(formats, ["ansi", nil], "\(answer): one ansi read, then one plain retry")
        }
    }

    func testAfterARefusalLaterReadsSendOnlyThePlainRequest() async throws {
        for answer in [PlainOnlyReadClient.AnsiAnswer.refused, .unreadable] {
            let client = PlainOnlyReadClient(screen: "one\ntwo\n", ansiAnswer: answer)
            let viewModel = SessionViewModel(client: client)
            viewModel.refreshPaneTail(for: pane)
            _ = try await tail(viewModel)
            viewModel.refreshPaneTail(for: pane)
            var formats = await client.formats
            var attempts = 0
            while formats.count < 3, attempts < 200 {
                try await Task.sleep(for: .milliseconds(5))
                formats = await client.formats
                attempts += 1
            }
            XCTAssertEqual(formats, ["ansi", nil, nil], "\(answer): the second read skips the ansi request")
        }
    }

    func testATransportErrorDoesNotMarkTheAnsiFormatRefused() async throws {
        let client = FlakyAnsiReadClient(screen: "one\ntwo\n")
        let viewModel = SessionViewModel(client: client)
        viewModel.refreshPaneTail(for: pane)
        _ = try await tail(viewModel)
        viewModel.refreshPaneTail(for: pane)
        var formats = await client.formats
        var attempts = 0
        while formats.count < 3, attempts < 200 {
            try await Task.sleep(for: .milliseconds(5))
            formats = await client.formats
            attempts += 1
        }
        XCTAssertEqual(formats, ["ansi", nil, "ansi"], "the next read tries ansi again and it lands")
    }

    /// A pane drawn twice, in the grid and in a zoom, is asked for by both
    /// tiles' cadences. One read at a time is what keeps that from piling
    /// requests on a pane that is slow to answer.
    func testAsksWhileAReadIsStillOutAddNoSecondRead() async throws {
        let client = TailReadClient(screen: "x")
        let viewModel = SessionViewModel(client: client)
        viewModel.refreshPaneTail(for: pane)
        viewModel.refreshPaneTail(for: pane)
        viewModel.refreshPaneTail(for: pane)
        let landed = try await tail(viewModel)
        XCTAssertEqual(landed.lines, ["x"])
        let asks = await client.asks
        XCTAssertEqual(asks.count, 1)
    }

    /// The cached tail is never the answer to a refresh: a pane that is
    /// printing changes nothing the model reports, so only reading again can
    /// tell a tile anything new.
    func testARefreshReadsAgainOnceTheLastReadHasLanded() async throws {
        let client = TailReadClient(screen: "x")
        let viewModel = SessionViewModel(client: client)
        viewModel.refreshPaneTail(for: pane)
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
