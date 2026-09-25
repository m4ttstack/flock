import Foundation

/// The line under a pristine pane's launcher buttons, shown only when no
/// agent CLI resolved: a PATH that holds none is otherwise indistinguishable
/// from a pane with nothing to say.
public enum LauncherHint {
    public static func text(detected: [String], searched: [String]) -> String? {
        guard detected.isEmpty else { return nil }
        guard !searched.isEmpty else { return "no agent CLI found on PATH" }
        return "no agent CLI found on PATH \u{00B7} looked for \(searched.joined(separator: ", "))"
    }
}
