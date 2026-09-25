import Foundation

/// The palette's namespaces, in the order ALL COMMANDS groups them.
public enum PaletteNamespace: String, CaseIterable, Sendable {
    case rt, pane, chat, mouse, view, tab, workspace
}

/// One row the palette can show. `id` is what recents remember, so it must
/// not change when a title does not.
public struct PaletteCommand: Equatable, Sendable, Identifiable {
    public let id: String
    public let namespace: PaletteNamespace
    public let name: String
    public let shortcut: String?
    /// Searchable, and drawn where a shortcut would be when there is none.
    public let hint: String?

    public init(id: String, namespace: PaletteNamespace, name: String, shortcut: String? = nil, hint: String? = nil) {
        self.id = id
        self.namespace = namespace
        self.name = name
        self.shortcut = shortcut
        self.hint = hint
    }
}
