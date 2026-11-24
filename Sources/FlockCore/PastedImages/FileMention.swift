import Foundation

/// A dropped file as an agent is handed it.
public enum FileMention {
    /// Agents that read `@path`, and fold a long paste into one label.
    public static func isRead(by agent: String?) -> Bool { agent == "claude" }

    private static let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-")

    /// The paste that names `path`. Three line breaks are what Claude Code
    /// folds into a label, and they are inside the text because it may trim
    /// the ends. Folded, the path is one thing to the prompt: it cannot be
    /// edited by accident, and takes the label's room rather than its own.
    ///
    /// Nil for a path the quoted form cannot hold.
    public static func paste(for path: String, folder: String?) -> String? {
        guard !path.contains("\""), !path.contains(where: \.isNewline) else { return nil }
        var name = path
        if let folder, !folder.isEmpty, path.hasPrefix(folder + "/") {
            name = String(path.dropFirst(folder.count + 1))
        }
        let mention = name.allSatisfy(plain.contains) ? "@" + name : "@\"" + name + "\""
        return "Attached file:\n\n\n" + mention
    }
}
