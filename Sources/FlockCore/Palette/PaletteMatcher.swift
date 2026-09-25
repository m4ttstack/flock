import Foundation

/// A fuzzy subsequence match over "namespace name hint", as VS Code's command
/// mode matches "Category: Name". Spaces in the query are ignored, so "rt gl"
/// and "rtgl" read the same.
public enum PaletteMatcher {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Offsets into the command's `name` of the characters that matched.
        public let nameIndices: [Int]

        public init(score: Int, nameIndices: [Int]) {
            self.score = score
            self.nameIndices = nameIndices
        }
    }

    static let consecutiveBonus = 3
    static let wordStartBonus = 5

    public static func match(_ query: String, against command: PaletteCommand) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, nameIndices: []) }
        let prefix = command.namespace.rawValue + " "
        let haystack = Array((prefix + command.name + (command.hint.map { " " + $0 } ?? "")).lowercased())
        let nameRange = prefix.count..<(prefix.count + command.name.count)
        var score = 0
        var indices: [Int] = []
        var previous: Int?
        var cursor = 0
        for character in needle {
            guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
            score += 1
            if let previous, found == previous + 1 { score += consecutiveBonus }
            if found == 0 || !haystack[found - 1].isLetter { score += wordStartBonus }
            if nameRange.contains(found) { indices.append(found - nameRange.lowerBound) }
            previous = found
            cursor = found + 1
        }
        return Match(score: score, nameIndices: indices)
    }
}
