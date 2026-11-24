import Foundation

/// One `[Image #N]` a pane's program drew for an image pasted into it.
public struct PastedImageLabel: Equatable, Sendable {
    public let number: Int
    /// In cells from the screen's top left.
    public let row: Int
    public let column: Int
    public let cells: Int
    public let inPrompt: Bool
    /// The program's own line repeating a sent message's attachment.
    public let isAttachmentLine: Bool
}

/// The labels on a pane's screen, read from its text.
public struct PastedImageLabels: Equatable, Sendable {
    /// What every label starts with, for a cheap look before a full read.
    public static let marker = "[Image #"

    public let labels: [PastedImageLabel]
    /// The row of the rule over the prompt, nil where no prompt is drawn.
    public let promptRow: Int?

    /// `rows` is one string per screen row: a label broken by a wrap is not
    /// found.
    public init(rows: [String]) {
        // Claude Code draws its prompt between the last two full-width rules.
        let rules = rows.indices.filter { rows[$0].hasPrefix("\u{2500}\u{2500}\u{2500}\u{2500}") }
        let prompt = rules.count >= 2 ? rules[rules.count - 2]..<rules[rules.count - 1] : nil
        promptRow = prompt?.lowerBound
        labels = rows.enumerated().flatMap { row, line in
            line.matches(of: /\[Image #(\d+)\]/).compactMap { match in
                Int(match.output.1).map { number in
                    PastedImageLabel(
                        number: number, row: row,
                        column: line[..<match.range.lowerBound].reduce(0) { $0 + PaneLink.cellWidth(of: $1) },
                        cells: match.output.0.count,
                        inPrompt: prompt?.contains(row) ?? false,
                        isAttachmentLine: line.drop { $0 == " " }.hasPrefix("\u{23BF}")
                    )
                }
            }
        }
    }
}

/// Gives each pasted image its number. The program picks the number and says
/// so only on screen, so a paste takes the label that appears after it.
public struct PastedImageMatcher: Sendable {
    /// How long a paste waits for its label: one into a pane on another
    /// machine uploads first.
    public static let window: TimeInterval = 15

    private var waiting: [String] = []
    private var deadline = Date.distantPast
    private var seen: [Int: Int] = [:]

    public init() {}

    public var isWaiting: Bool { !waiting.isEmpty }

    /// `shown` is every label's number on the screen before the paste.
    public mutating func willPaste(_ paths: [String], shown: [Int], now: Date) {
        guard !paths.isEmpty else { return }
        expire(now)
        if waiting.isEmpty { seen = Self.counts(shown) }
        waiting += paths
        deadline = now.addingTimeInterval(Self.window)
    }

    /// The pastes whose labels have appeared, in order.
    public mutating func match(shown: [Int], now: Date) -> [(number: Int, path: String)] {
        guard !waiting.isEmpty else { return [] }
        let counts = Self.counts(shown)
        var matched: [(number: Int, path: String)] = []
        for number in counts.keys.sorted() where counts[number, default: 0] > seen[number, default: 0] {
            guard !waiting.isEmpty else { break }
            matched.append((number, waiting.removeFirst()))
        }
        seen = counts
        expire(now)
        return matched
    }

    private mutating func expire(_ now: Date) {
        if now > deadline { waiting = [] }
    }

    private static func counts(_ numbers: [Int]) -> [Int: Int] {
        numbers.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
