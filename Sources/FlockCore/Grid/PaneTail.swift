import Foundation

/// The tail of a pane's output: what the grid's hover card draws under the
/// rule, and what its copy button puts on the pasteboard.
public struct PaneTail: Equatable, Sendable {
    /// Newest last, as the pane has them on screen, with the pane's styling.
    public let rows: [StyledRow]

    /// `rows` as plain text.
    public var lines: [String] { rows.map(\.text) }
    public var isEmpty: Bool { rows.isEmpty }
    /// Exactly the lines the card shows, which is what a copy of the card's
    /// output has to be.
    public var text: String { lines.joined(separator: "\n") }

    public init(rows: [StyledRow]) {
        self.rows = rows
    }

    public init(lines: [String]) {
        self.init(rows: lines.map(StyledRow.init(plain:)))
    }
}

/// How much of a pane the hover card reads, how often, and what it keeps.
///
/// The grid never attaches a pane, so `pane.read` is the only way it can show
/// output at all, and every read costs a round trip to herdr. A card opens
/// only on a click, so only the pane whose card is up is ever read.
public enum PaneTailPolicy {
    /// Lines of output the card draws: enough of a build, a test run or an
    /// agent's last exchange to follow what happened, while at the card's line
    /// height it still leaves the card shorter than the grid is tall at the
    /// window's own minimum height, so a long tail can never push the card off
    /// screen.
    public static let lines = 20

    /// Rows of the pane's visible screen the card asks for, which is more than
    /// it draws. A pane sitting at an agent's prompt spends its last rows on
    /// that prompt, and `outputRows` drops them, so a read of exactly what the
    /// card draws would arrive with a cardful of furniture and nothing under
    /// it. The gap is wider than the tallest frame the trim will take, so even
    /// a fully trimmed screen carries a whole card of output. It is also taller
    /// than any window's screen: a full-screen TUI draws at the top and leaves
    /// blank rows down to a footer, so a read of the screen's foot would carry
    /// the blanks and the footer and none of the TUI.
    public static let readLines = 200

    /// The tallest bottom strip `outputRows` will read as an agent's prompt.
    ///
    /// A prompt frame is a strip: two rules around a field of a few rows, with
    /// a status line or two beneath. A taller candidate is something else that
    /// happens to be framed, a picker's own results among them, and taking it
    /// would hide the output the card exists to show.
    public static let inputFrameRows = 12

    /// How often the card re-reads the pane it is showing. A pane whose output
    /// is moving while the card is up is the case this exists for: nothing
    /// herdr reports about a pane changes when it prints, so there is no event
    /// to follow and a cached tail would simply age on screen. One read a
    /// second is a full second of stale text at worst, against one request per
    /// second for exactly one pane.
    public static let refreshInterval: Duration = .milliseconds(1000)

    /// The lines a `pane.read` answer leaves the card showing: trailing blanks
    /// dropped (herdr's visible text ends where the screen's last written row
    /// does, but a shell sitting at a fresh prompt still leaves one), leading
    /// blanks dropped so the tail starts at text, per-line trailing spaces cut
    /// so the copied text has no padding in it, the agent's own prompt dropped,
    /// and never more lines than were asked for.
    ///
    /// `text` may carry ANSI escapes. Every rule here reads a row's plain
    /// text, so a styled screen keeps exactly the rows its plain read would.
    public static func make(from text: String, limit: Int = lines) -> PaneTail {
        let screen = trimmingBlankEnds(TerminalStyledText.rows(of: text))
        let output = trimmingBlankEnds(outputRows(ofStyled: screen))
        // A screen whose every row is the prompt keeps its untrimmed rows: a
        // blank card is the one outcome worse than a card full of furniture.
        let shown = collapsingBlankRuns(output.isEmpty ? screen : output)
        return PaneTail(rows: Array(shown.suffix(max(0, limit))))
    }

    /// The rows of a visible screen that are output, which is every row above
    /// the agent prompt the screen ends on.
    ///
    /// A terminal agent paints its prompt as a framed strip at the foot of the
    /// screen and scrolls the conversation above it, so the strip is furniture
    /// all the way down: the frame, the field being typed into, and whatever
    /// status the agent draws under the closing rule. The frame is read the way
    /// herdr's own agent detection reads it, as a pair of `─` rules with a
    /// prompt mark between them, so a pane holding no such prompt (a shell, an
    /// editor, a build) keeps every row it has.
    ///
    /// Both marks of the frame have to be present, and the strip has to be a
    /// strip: a shape that is ambiguous keeps its rows, since furniture shown
    /// costs the reader a glance where output hidden costs him the thing he
    /// opened the card for.
    public static func outputRows(of rows: [String]) -> [String] {
        guard let start = inputFrameStart(in: rows) else { return rows }
        return Array(rows[..<start])
    }

    private static func outputRows(ofStyled rows: [StyledRow]) -> [StyledRow] {
        guard let start = inputFrameStart(in: rows.map(\.text)) else { return rows }
        return Array(rows[..<start])
    }

    private static func inputFrameStart(in rows: [String]) -> Int? {
        guard let bottom = rows.lastIndex(where: isHorizontalRule),
              let top = rows[..<bottom].lastIndex(where: isHorizontalRule),
              rows.count - top <= inputFrameRows,
              rows[(top + 1)..<bottom].contains(where: isPromptField)
        else { return nil }
        return top
    }

    /// herdr's own mark for a rule: a run of `─`, either alone on the row or
    /// long enough that what trails it is a label rather than prose.
    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == "─" }.count
        guard run > 0 else { return false }
        return trimmed.dropFirst(run).drop(while: \.isWhitespace).isEmpty || run >= 3
    }

    /// The marks herdr's agent detection reads as an agent's input field: `❯`
    /// for Claude Code, `›` for Codex. `>` opens a quote, a diff hunk and a
    /// shell continuation, so it is not one of them.
    private static func isPromptField(_ line: String) -> Bool {
        guard let first = line.first(where: { !$0.isWhitespace }) else { return false }
        return first == "❯" || first == "›"
    }

    /// A run of blank rows is a TUI's empty space, not output, and spent on
    /// the card it pushes the TUI itself off the top. One blank keeps the gap.
    private static func collapsingBlankRuns(_ rows: [StyledRow]) -> [StyledRow] {
        var kept: [StyledRow] = []
        for row in rows where !(row.text.isEmpty && kept.last?.text.isEmpty == true) {
            kept.append(row)
        }
        return kept
    }

    private static func trimmingBlankEnds(_ rows: [StyledRow]) -> [StyledRow] {
        var rows = rows
        while rows.last?.text.isEmpty == true {
            rows.removeLast()
        }
        while rows.first?.text.isEmpty == true {
            rows.removeFirst()
        }
        return rows
    }
}
