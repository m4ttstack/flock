import Foundation

/// What a link in a pane's text points at.
public enum PaneLink: Equatable {
    case file(URL)
    case web(URL)

    /// A link found on one row of a pane's text, and the columns it covers.
    public struct Match: Equatable {
        public let link: PaneLink
        public let columns: Range<Int>

        public init(link: PaneLink, columns: Range<Int>) {
            self.link = link
            self.columns = columns
        }
    }

    /// How many words of a row one path may run across. A path may hold
    /// spaces (`Application Support`), and each word more is one more guess
    /// to check on disk.
    static let wordsInAPath = 6

    /// The link `column` falls in on one row of a pane's text. flock looks
    /// for itself instead of asking libghostty: its matcher takes any run of
    /// words after a path as more of the path, so `~/src && git pull` is one
    /// link to it, and it knows a fixed list of schemes that leaves out
    /// `vscode://`.
    ///
    /// A path is the longest run of words, from one that starts a path, that
    /// names something on disk. `column` and the match's columns count the
    /// terminal's cells, of which an emoji or a CJK character takes two.
    public static func match(
        inRow row: String, column: Int, folder: String?, home: String,
        handled: (URL) -> Bool = { _ in false }, exists: (String) -> Bool
    ) -> Match? {
        var cellStarts: [Int] = []
        var cells = 0
        for character in row {
            cellStarts.append(cells)
            cells += cellWidth(of: character)
        }
        cellStarts.append(cells)
        guard column >= 0, column < cells, let index = cellStarts.lastIndex(where: { $0 <= column }) else { return nil }
        return match(inRow: row, character: index, folder: folder, home: home, handled: handled, exists: exists)
            .map { Match(link: $0.link, columns: cellStarts[$0.columns.lowerBound]..<cellStarts[$0.columns.upperBound]) }
    }

    /// Two for what a terminal draws double width: emoji shown as pictures,
    /// and the East Asian wide and fullwidth blocks.
    static func cellWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation { return 2 }
        if scalar.properties.isEmoji, character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// `match(inRow:column:)` with `column` and the answer's columns counted
    /// in characters.
    private static func match(
        inRow row: String, character column: Int, folder: String?, home: String,
        handled: (URL) -> Bool, exists: (String) -> Bool
    ) -> Match? {
        for (text, start) in addresses(inRow: row) where (start..<start + text.count).contains(column) {
            return resolve(text, folder: folder, home: home, handled: handled, exists: exists)
                .map { Match(link: $0, columns: start..<start + text.count) }
        }
        let characters = Array(row)
        let words = wordRanges(in: characters)
        for (index, word) in words.enumerated() where word.lowerBound <= column {
            var start = word.lowerBound
            while start < word.upperBound, "([{<\"'`".contains(characters[start]) { start += 1 }
            let first = String(characters[start..<word.upperBound])
            guard first.contains("/"), !first.contains("://"), first.contains(where: { $0.isLetter || $0.isNumber })
            else { continue }
            let rooted = ["~/", "/", "./", "../"].contains { first.hasPrefix($0) }
            let last = rooted ? min(index + wordsInAPath - 1, words.count - 1) : index
            for end in stride(from: last, through: index, by: -1) {
                let candidate = String(characters[start..<words[end].upperBound])
                guard let found = file(candidate, folder: folder, home: home, exists: exists) else { continue }
                let columns = start..<start + found.kept
                if columns.contains(column) { return Match(link: .file(found.url), columns: columns) }
                break
            }
        }
        return nil
    }

    private static func wordRanges(in characters: [Character]) -> [Range<Int>] {
        var words: [Range<Int>] = []
        var start: Int?
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                if let from = start { words.append(from..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let from = start { words.append(from..<characters.count) }
        return words
    }

    /// `text` is a link's text exactly as printed. A relative path is under
    /// `folder`, the pane's as herdr knows it.
    ///
    /// A path that names nothing on disk resolves to nothing, since the
    /// matcher also takes prose that merely contains a slash. So does an
    /// address no app is `handled` by; whether one that is may open without
    /// asking is `LinkTrust`'s.
    public static func resolve(
        _ text: String?, folder: String?, home: String, handled: (URL) -> Bool = { _ in false },
        exists: (String) -> Bool
    ) -> PaneLink? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var candidate = text
        if text.hasPrefix("file://") {
            guard let path = String(text.dropFirst("file://".count)).removingPercentEncoding else { return nil }
            candidate = path
        } else if text.range(of: Self.address, options: [.regularExpression, .caseInsensitive]) != nil {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  LinkTrust.builtIn.contains(scheme) || handled(url)
            else { return nil }
            return .web(url)
        }
        return file(candidate, folder: folder, home: home, exists: exists).map { .file($0.url) }
    }

    /// The file `candidate` names, and how much of it was the name: a
    /// trailing `:12` position and sentence punctuation come off until what
    /// is left is on disk.
    private static func file(
        _ candidate: String, folder: String?, home: String, exists: (String) -> Bool
    ) -> (url: URL, kept: Int)? {
        var candidate = candidate
        while true {
            guard let path = absolutePath(candidate, folder: folder, home: home) else { return nil }
            if exists(path) { return (URL(fileURLWithPath: path), candidate.count) }
            guard let shorter = droppingTail(candidate) else { return nil }
            candidate = shorter
        }
    }

    /// The `scheme://` address `column` falls in on one row of a pane's text.
    public static func address(inRow row: String, column: Int) -> String? {
        addresses(inRow: row).first { ($0.start..<$0.start + $0.text.count).contains(column) }?.text
    }

    /// Every `scheme://` and `mailto:` address on a row, with the column it
    /// starts at.
    /// Sentence punctuation after an address is left off, and so is a
    /// bracket that closes one opened before it.
    private static func addresses(inRow row: String) -> [(text: String, start: Int)] {
        let pattern = #"(?:[A-Za-z][A-Za-z0-9+.\-]*://|mailto:)[^\s<>"'`]+"#
        var found: [(String, Int)] = []
        var search = row.startIndex..<row.endIndex
        while let range = row.range(of: pattern, options: .regularExpression, range: search) {
            var match = row[range]
            while let last = match.last, ".,;:!?".contains(last) || closesNothing(last, in: match) {
                match = match.dropLast()
            }
            found.append((String(match), row.distance(from: row.startIndex, to: match.startIndex)))
            search = range.upperBound..<row.endIndex
        }
        return found
    }

    private static func closesNothing(_ last: Character, in match: Substring) -> Bool {
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        guard let opener = pairs[last] else { return false }
        return match.filter { $0 == last }.count > match.filter { $0 == opener }.count
    }

    /// Anything with `://`, and the schemes libghostty's matcher takes
    /// without it. A bare `name:` is left to the paths: `main.swift:12` is a
    /// file and a line.
    private static let address = #"^[a-z][a-z0-9+.\-]*://|^(mailto|ssh|tel|magnet|news):"#

    private static func absolutePath(_ path: String, folder: String?, home: String) -> String? {
        let joined: String
        if path == "~" {
            joined = home
        } else if path.hasPrefix("~/") {
            joined = home + path.dropFirst(1)
        } else if path.hasPrefix("/") {
            joined = path
        } else if let folder, !folder.isEmpty {
            joined = folder + "/" + path
        } else {
            return nil
        }
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }

    /// One step shorter: without a trailing `:12` position, or without one
    /// character of the punctuation a sentence puts after a path.
    private static func droppingTail(_ text: String) -> String? {
        if let position = text.range(of: #":\d+$"#, options: .regularExpression) {
            return String(text[..<position.lowerBound])
        }
        guard let last = text.last, ".,;:!?)]}'\"".contains(last), text.count > 1 else { return nil }
        return String(text.dropLast())
    }
}
