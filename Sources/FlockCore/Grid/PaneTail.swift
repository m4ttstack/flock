import Foundation

/// The tail of a pane's output: what the grid's hover card draws under the
/// rule, and what its copy button puts on the pasteboard.
public struct PaneTail: Equatable, Sendable {
    /// Newest last, as the pane has them on screen.
    public let lines: [String]

    public var isEmpty: Bool { lines.isEmpty }
    /// Exactly the lines the card shows, which is what a copy of the card's
    /// output has to be.
    public var text: String { lines.joined(separator: "\n") }

    public init(lines: [String]) {
        self.lines = lines
    }
}

/// How much of a pane the hover card reads, how often, and what it keeps.
///
/// The grid never attaches a pane, so `pane.read` is the only way it can show
/// output at all, and every read costs a round trip to herdr. The delay before
/// a card shows is what keeps that cheap: a sweep across thirty panes reads
/// nothing, because no card opens. Only the pane whose card is up is ever
/// read.
public enum PaneTailPolicy {
    /// Lines of the pane's visible screen the card asks for. Eight is the tail
    /// of a build, a test run or an agent's last exchange rather than a single
    /// line, and at the card's width and line height it leaves the card
    /// shorter than the grid is tall at the window's own minimum height, so a
    /// long tail can never push the card off screen.
    public static let lines = 8

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
    /// so the copied text has no padding in it, and never more lines than were
    /// asked for.
    public static func make(from text: String, limit: Int = lines) -> PaneTail {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(trimmingTrailingBlanks)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        return PaneTail(lines: Array(lines.suffix(max(0, limit))))
    }

    private static func trimmingTrailingBlanks(_ line: Substring) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" || line[previous] == "\r" else { break }
            end = previous
        }
        return String(line[line.startIndex..<end])
    }
}
