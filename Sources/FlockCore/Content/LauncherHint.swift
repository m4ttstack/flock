import Foundation

/// The line under a pristine pane's launcher buttons.
///
/// It carries the empty case as well as the ordinary one because the launcher
/// renders whether or not anything resolved, and a PATH that holds no agent
/// CLI is otherwise indistinguishable from a pane with nothing to say.
public enum LauncherHint {
    public static func text(detected: [String], searched: [String]) -> String {
        guard detected.isEmpty else {
            return "detected on PATH \u{00B7} click launches in this pane \u{00B7} typing hides these"
        }
        guard !searched.isEmpty else { return "no agent CLI found on PATH" }
        return "no agent CLI found on PATH \u{00B7} looked for \(searched.joined(separator: ", "))"
    }
}
