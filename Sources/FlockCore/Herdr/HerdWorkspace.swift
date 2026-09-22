import Foundation

/// Whether a pane belongs to a herd: a batch of agents started by `rt herd`
/// and watched by the shepherd that started them.
///
/// The only marker of one that reaches this client is the workspace label.
/// rt gives a herd its own workspace, labelled this prefix plus the herd id,
/// and every worker it spawns becomes a tab in that one workspace; nothing
/// per-pane on herdr's wire says "herd" (the `tokens` map herdr carries on a
/// pane holds no herd key). So the question is answered about the workspace
/// and read off for the pane.
public enum HerdWorkspace {
    public static let labelPrefix = "herd: "

    public static func isHerd(label: String) -> Bool {
        guard label.hasPrefix(labelPrefix) else { return false }
        return !label.dropFirst(labelPrefix.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A pane whose workspace is not in the snapshot answers `false`: an
    /// unproven claim of herd membership must not be what silences a toast.
    public static func isHerdPane(_ pane: PaneRecord, in model: SessionModel) -> Bool {
        guard let label = model.workspaces.first(where: { $0.workspaceID == pane.workspaceID })?.label
        else { return false }
        return isHerd(label: label)
    }
}
