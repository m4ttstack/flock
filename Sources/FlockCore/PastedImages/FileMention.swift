import Foundation

/// A dropped file as an agent is handed it.
public enum FileMention {
    /// Agents that read `@path`, and fold a long paste into one label.
    public static func isRead(by agent: String?) -> Bool { agent == "claude" }

    private static let heading = "Attached file:"
    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-")

    /// Claude Code folds a paste longer than 800 characters into a label, and
    /// one with no line breaks into the shortest it has.
    private static let foldingLength = 801

    /// The paste that names `path`. Folded, the path is one thing to the
    /// prompt: it cannot be edited by accident, and takes the label's room
    /// rather than its own. The padding is inside the text because its ends
    /// may be trimmed, and differs by `drop` because the same paste twice
    /// running unfolds the first.
    ///
    /// Nil for a path the quoted form cannot hold.
    public static func paste(for path: String, folder: String?, drop: Int) -> String? {
        guard !path.contains("\""), !path.contains(where: \.isNewline) else { return nil }
        var name = path
        if let folder, !folder.isEmpty, path.hasPrefix(folder + "/") {
            name = String(path.dropFirst(folder.count + 1))
        }
        let mention = name.allSatisfy(plain.contains) ? "@" + name : "@\"" + name + "\""
        let padding = max(1, foldingLength - heading.count - mention.count) + drop % 16
        return heading + String(repeating: " ", count: padding) + mention
    }
}
