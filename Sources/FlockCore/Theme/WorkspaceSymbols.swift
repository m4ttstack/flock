import Foundation

/// The symbols a workspace can be marked with. Colour on a workspace would
/// read as agent status, so a workspace is told apart by shape alone. None
/// of these is a check, exclamation, clock, bell, cross or plain disc: those
/// are the shapes status already uses.
public enum WorkspaceSymbols {
    public struct Symbol: Equatable, Sendable {
        public let name: String
        public let title: String
    }

    /// In the order workspaces are assigned them.
    public static let all: [Symbol] = [
        Symbol(name: "leaf.fill", title: "Leaf"),
        Symbol(name: "bolt.fill", title: "Bolt"),
        Symbol(name: "flask.fill", title: "Flask"),
        Symbol(name: "hammer.fill", title: "Hammer"),
        Symbol(name: "book.closed.fill", title: "Book"),
        Symbol(name: "terminal.fill", title: "Terminal"),
        Symbol(name: "globe.americas.fill", title: "Globe"),
        Symbol(name: "cube.fill", title: "Cube"),
        Symbol(name: "puzzlepiece.fill", title: "Puzzle"),
        Symbol(name: "paperplane.fill", title: "Paper plane"),
        Symbol(name: "flame.fill", title: "Flame"),
        Symbol(name: "drop.fill", title: "Drop"),
        Symbol(name: "mountain.2.fill", title: "Mountains"),
        Symbol(name: "cpu.fill", title: "Chip"),
        Symbol(name: "wrench.adjustable.fill", title: "Wrench"),
        Symbol(name: "paintbrush.fill", title: "Brush"),
        Symbol(name: "gamecontroller.fill", title: "Controller"),
        Symbol(name: "camera.fill", title: "Camera"),
        Symbol(name: "map.fill", title: "Map"),
        Symbol(name: "key.fill", title: "Key"),
        Symbol(name: "tag.fill", title: "Tag"),
    ]

    public static func contains(_ name: String) -> Bool {
        all.contains { $0.name == name }
    }
}
