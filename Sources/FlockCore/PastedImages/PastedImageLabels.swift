import Foundation

/// One label a pane's program drew for something pasted into it.
public struct PastedImageLabel: Equatable, Sendable {
    public enum Kind: Sendable {
        /// `[Image #N]`.
        case image
        /// `[Pasted text #N +M lines]`, which a dropped file arrives as.
        case text
    }

    public let kind: Kind
    public let number: Int
    /// In cells from the screen's top left.
    public let row: Int
    public let column: Int
    public let cells: Int
    public let inPrompt: Bool
    /// The program's own line repeating a sent message's attachment.
    public let isAttachmentLine: Bool
    /// The rest of a label its program wrapped, on the next row.
    public let tail: Tail?

    public struct Tail: Equatable, Sendable {
        public let column: Int
        public let cells: Int
    }

    init(
        kind: Kind = .image, number: Int, row: Int, column: Int, cells: Int, inPrompt: Bool, isAttachmentLine: Bool,
        tail: Tail? = nil
    ) {
        self.kind = kind
        self.number = number
        self.row = row
        self.column = column
        self.cells = cells
        self.inPrompt = inPrompt
        self.isAttachmentLine = isAttachmentLine
        self.tail = tail
    }
}

/// The labels on a pane's screen, read from its text.
public struct PastedImageLabels: Equatable, Sendable {
    /// What labels start with, for a cheap look before a full read.
    public static let markers = ["[Image", "[Pasted"]

    /// The images' labels.
    public let labels: [PastedImageLabel]
    /// The pasted texts' labels.
    public let texts: [PastedImageLabel]
    /// The row of the rule over the prompt, nil where no prompt is drawn.
    public let promptRow: Int?

    /// The numbers of the labels a paste could have put there: the prompt's
    /// alone where one is drawn, since the rest are messages already sent.
    func pasteTargets(_ kind: PastedImageLabel.Kind) -> [Int] {
        (kind == .image ? labels : texts).filter { promptRow == nil || $0.inPrompt }.map(\.number)
    }

    private nonisolated(unsafe) static let pattern = /\[(Image|Pasted text) #(\d+)(?: \+\d+ lines)?\]/

    /// `rows` is one string per screen row.
    public init(rows: [String]) {
        // Claude Code draws its prompt between the last two full-width rules.
        let rules = rows.indices.filter { rows[$0].hasPrefix("\u{2500}\u{2500}\u{2500}\u{2500}") }
        let prompt = rules.count >= 2 ? rules[rules.count - 2]..<rules[rules.count - 1] : nil
        promptRow = prompt?.lowerBound
        let found = rows.indices.flatMap { row -> [PastedImageLabel] in
            let line = rows[row]
            guard Self.markers.contains(where: line.contains) else { return [] }
            let inPrompt = prompt?.contains(row) ?? false
            let isAttachmentLine = line.drop { $0 == " " }.hasPrefix("\u{23BF}")
            var found = line.matches(of: Self.pattern).compactMap { match in
                Int(match.output.2).map { number in
                    PastedImageLabel(
                        kind: match.output.1 == "Image" ? .image : .text, number: number, row: row, column: Self.cells(line[..<match.range.lowerBound]),
                        cells: Self.cells(match.output.0), inPrompt: inPrompt, isAttachmentLine: isAttachmentLine
                    )
                }
            }
            if row + 1 < rows.count, let wrapped = Self.wrapped(line, onto: rows[row + 1]) {
                found.append(PastedImageLabel(
                    kind: wrapped.kind, number: wrapped.number, row: row, column: wrapped.column, cells: wrapped.cells,
                    inPrompt: inPrompt, isAttachmentLine: isAttachmentLine, tail: wrapped.tail
                ))
            }
            return found
        }
        labels = found.filter { $0.kind == .image }
        texts = found.filter { $0.kind == .text }
    }

    /// The label that runs off the end of `line`. The program wraps at a
    /// space, which is not drawn, and indents what follows.
    private static func wrapped(
        _ line: String, onto next: String
    ) -> (kind: PastedImageLabel.Kind, number: Int, column: Int, cells: Int, tail: PastedImageLabel.Tail)? {
        guard let start = line.lastIndex(of: "[") else { return nil }
        var head = line[start...]
        while head.last?.isWhitespace == true { head = head.dropLast() }
        guard !head.contains("]") else { return nil }
        let rest = next.drop { $0.isWhitespace }
        guard let match = (head + " " + rest).prefixMatch(of: pattern), let number = Int(match.output.2),
              match.output.0.count > head.count + 1
        else { return nil }
        let tail = rest.prefix(match.output.0.count - head.count - 1)
        return (
            match.output.1 == "Image" ? .image : .text, number, cells(line[..<start]), cells(head),
            PastedImageLabel.Tail(column: cells(next[..<rest.startIndex]), cells: cells(tail))
        )
    }

    private static func cells(_ text: Substring) -> Int {
        text.reduce(0) { $0 + PaneLink.cellWidth(of: $1) }
    }
}

/// Gives each pasted image its number. The program picks the number and says
/// so only on screen, so a paste takes the label that appears after it.
public struct PastedImageMatcher: Sendable {
    /// How long a paste waits for its label, from when it is sent.
    public static let window: TimeInterval = 15

    private let kind: PastedImageLabel.Kind
    private var waiting: [(paste: Int, path: String, deadline: Date)] = []
    private var pastes = 0
    /// The most of each number ever on screen at once since waiting began: a
    /// label that scrolls off and back is not another.
    private var seen: [Int: Int] = [:]
    /// Waiting began with a prompt drawn, so a screen without one says
    /// nothing about it.
    private var expectsPrompt = false

    public init(_ kind: PastedImageLabel.Kind = .image) {
        self.kind = kind
    }

    public var isWaiting: Bool { !waiting.isEmpty }

    /// `screen` is the one before the paste, which a paste that is `held`
    /// has yet to be sent after. The answer is for `sent` and `cancel`.
    public mutating func willPaste(
        _ paths: [String], over screen: PastedImageLabels, held: Bool = false, now: Date
    ) -> Int {
        expire(now)
        if waiting.isEmpty {
            seen = Self.counts(screen.pasteTargets(kind))
            expectsPrompt = screen.promptRow != nil
        }
        pastes += 1
        let deadline = held ? .distantFuture : now.addingTimeInterval(Self.window)
        waiting += paths.map { (pastes, $0, deadline) }
        return pastes
    }

    /// A held paste goes out, behind whatever went out while it was held.
    public mutating func sent(_ paste: Int, now: Date) {
        let outgoing = waiting.filter { $0.paste == paste }
        waiting.removeAll { $0.paste == paste }
        waiting += outgoing.map { ($0.paste, $0.path, now.addingTimeInterval(Self.window)) }
    }

    /// Forgets every paste, and answers none of their later `sent` or
    /// `cancel`: the count goes on.
    public mutating func reset() {
        waiting = []
        seen = [:]
    }

    /// A paste that never reached the program leaves no label to wait for.
    public mutating func cancel(_ paste: Int) {
        waiting.removeAll { $0.paste == paste }
    }

    /// The pastes whose labels have appeared, in order.
    public mutating func match(_ screen: PastedImageLabels, now: Date) -> [(number: Int, path: String)] {
        expire(now)
        guard !waiting.isEmpty, screen.promptRow != nil || !expectsPrompt else { return [] }
        let counts = Self.counts(screen.pasteTargets(kind))
        var matched: [(number: Int, path: String)] = []
        for number in counts.keys.sorted() where counts[number, default: 0] > seen[number, default: 0] {
            guard let next = waiting.firstIndex(where: { $0.deadline != .distantFuture }) else { break }
            matched.append((number, waiting.remove(at: next).path))
        }
        seen.merge(counts, uniquingKeysWith: max)
        return matched
    }

    private mutating func expire(_ now: Date) {
        waiting.removeAll { now > $0.deadline }
    }

    private static func counts(_ numbers: [Int]) -> [Int: Int] {
        numbers.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
