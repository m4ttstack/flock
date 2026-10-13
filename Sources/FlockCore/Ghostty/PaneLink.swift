import Foundation

/// What a link libghostty found in a pane's text points at.
public enum PaneLink: Equatable {
    case file(URL)
    case web(URL)

    /// `text` is the matched text exactly as printed: libghostty resolves a
    /// relative path only against a working directory its own surface
    /// reported, and a flock surface runs the bridge, which reports none.
    /// `folder` is the pane's, as herdr knows it.
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
        while true {
            guard let path = absolutePath(candidate, folder: folder, home: home) else { return nil }
            if exists(path) { return .file(URL(fileURLWithPath: path)) }
            guard let shorter = droppingTail(candidate) else { return nil }
            candidate = shorter
        }
    }

    /// The `scheme://` address `column` falls in on one row of a pane's text,
    /// for the schemes libghostty's own matcher does not know (it takes a
    /// fixed list, and `vscode://` is not on it). Sentence punctuation after
    /// the address is left off, and so is a bracket that closes one opened
    /// before it.
    public static func address(inRow row: String, column: Int) -> String? {
        let pattern = #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"'`]+"#
        var search = row.startIndex..<row.endIndex
        while let found = row.range(of: pattern, options: .regularExpression, range: search) {
            var match = row[found]
            while let last = match.last, ".,;:!?".contains(last) || closesNothing(last, in: match) {
                match = match.dropLast()
            }
            let start = row.distance(from: row.startIndex, to: match.startIndex)
            if (start..<start + match.count).contains(column) { return String(match) }
            search = found.upperBound..<row.endIndex
        }
        return nil
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
