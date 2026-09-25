import Foundation

/// The rows the palette shows for a query. Empty: RECENT (up to
/// `recentLimit`, only commands available now) then ALL COMMANDS grouped by
/// namespace in `PaletteNamespace` order. Typed: one list ranked by match
/// score, with a boost for recent use.
public enum PaletteRanking {
    public static let recentLimit = 3

    public enum Section: Equatable, Sendable { case recent, all }

    public struct Row: Equatable, Sendable, Identifiable {
        public let command: PaletteCommand
        public let section: Section?
        public let nameIndices: [Int]
        public var id: String { command.id }
    }

    public static func rows(commands: [PaletteCommand], query: String, recents: [String]) -> [Row] {
        if query.allSatisfy(\.isWhitespace) {
            let byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = recents.compactMap { byID[$0] }.prefix(recentLimit)
            let recentIDs = Set(recent.map(\.id))
            let order = PaletteNamespace.allCases
            let rest = commands.enumerated()
                .filter { !recentIDs.contains($0.element.id) }
                .sorted {
                    let lhs = order.firstIndex(of: $0.element.namespace) ?? 0
                    let rhs = order.firstIndex(of: $1.element.namespace) ?? 0
                    return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                }
                .map(\.element)
            return recent.map { Row(command: $0, section: .recent, nameIndices: []) }
                + rest.map { Row(command: $0, section: .all, nameIndices: []) }
        }
        return commands.enumerated()
            .compactMap { offset, command -> (Row, Int, Int)? in
                guard let match = PaletteMatcher.match(query, against: command) else { return nil }
                let boost = recents.firstIndex(of: command.id).map { max(0, 5 - $0) } ?? 0
                return (Row(command: command, section: nil, nameIndices: match.nameIndices), match.score + boost, offset)
            }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .map(\.0)
    }
}
