import Foundation

/// A dropped file as an agent is handed it.
public enum FileMention {
    /// Agents that read `@"path"`, and fold a long paste into one label.
    public static func isRead(by agent: String?) -> Bool { agent == "claude" }

    private static let heading = "Attached file:"

    /// Claude Code folds a paste longer than 800 characters into a label, and
    /// one with no line breaks into the shortest it has.
    private static let foldingLength = 801

    /// The paste that names `path`. Folded, the path is one thing to the
    /// prompt: it cannot be edited by accident, and takes the label's room
    /// rather than its own.
    ///
    /// In full, since a name relative to the pane's folder is only right if
    /// the agent works there too, and always quoted, since text may follow
    /// with no space. The padding is inside because the ends may be trimmed,
    /// and differs by `drop` because the same paste twice running unfolds
    /// the first.
    ///
    /// Nil for a path the quotes cannot hold.
    public static func paste(for path: String, drop: Int) -> String? {
        guard !path.contains("\""), !path.contains(where: \.isNewline) else { return nil }
        let mention = "@\"" + path + "\""
        let padding = max(1, foldingLength - heading.count - mention.count) + drop % 16
        return heading + String(repeating: " ", count: padding) + mention
    }
}
