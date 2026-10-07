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

    public struct Group: Sendable {
        public let title: String
        public let symbols: [Symbol]
    }

    /// The picker's submenus, in order.
    public static let groups: [Group] = [
        Group(title: "Animals", symbols: [
            Symbol(name: "bird.fill", title: "Bird"),
            Symbol(name: "fish.fill", title: "Fish"),
            Symbol(name: "hare.fill", title: "Hare"),
            Symbol(name: "tortoise.fill", title: "Tortoise"),
            Symbol(name: "cat.fill", title: "Cat"),
            Symbol(name: "dog.fill", title: "Dog"),
            Symbol(name: "pawprint.fill", title: "Paw"),
            Symbol(name: "ladybug.fill", title: "Ladybug"),
            Symbol(name: "ant.fill", title: "Ant"),
            Symbol(name: "lizard.fill", title: "Lizard"),
            Symbol(name: "teddybear.fill", title: "Teddy bear"),
        ]),
        Group(title: "Nature", symbols: [
            Symbol(name: "leaf.fill", title: "Leaf"),
            Symbol(name: "tree.fill", title: "Tree"),
            Symbol(name: "mountain.2.fill", title: "Mountains"),
            Symbol(name: "flame.fill", title: "Flame"),
            Symbol(name: "drop.fill", title: "Drop"),
            Symbol(name: "snowflake", title: "Snowflake"),
            Symbol(name: "sun.max.fill", title: "Sun"),
            Symbol(name: "moon.fill", title: "Moon"),
            Symbol(name: "cloud.fill", title: "Cloud"),
            Symbol(name: "bolt.fill", title: "Bolt"),
            Symbol(name: "carrot.fill", title: "Carrot"),
        ]),
        Group(title: "Things", symbols: [
            Symbol(name: "paperplane.fill", title: "Paper plane"),
            Symbol(name: "sailboat.fill", title: "Sailboat"),
            Symbol(name: "airplane", title: "Airplane"),
            Symbol(name: "car.fill", title: "Car"),
            Symbol(name: "bicycle", title: "Bicycle"),
            Symbol(name: "tent.fill", title: "Tent"),
            Symbol(name: "crown.fill", title: "Crown"),
            Symbol(name: "gift.fill", title: "Gift"),
            Symbol(name: "cup.and.saucer.fill", title: "Cup"),
            Symbol(name: "gamecontroller.fill", title: "Controller"),
            Symbol(name: "camera.fill", title: "Camera"),
            Symbol(name: "globe.americas.fill", title: "Globe"),
            Symbol(name: "map.fill", title: "Map"),
            Symbol(name: "book.closed.fill", title: "Book"),
            Symbol(name: "key.fill", title: "Key"),
            Symbol(name: "tag.fill", title: "Tag"),
            Symbol(name: "puzzlepiece.fill", title: "Puzzle"),
            Symbol(name: "cube.fill", title: "Cube"),
        ]),
        Group(title: "Tools", symbols: [
            Symbol(name: "hammer.fill", title: "Hammer"),
            Symbol(name: "wrench.adjustable.fill", title: "Wrench"),
            Symbol(name: "paintbrush.fill", title: "Brush"),
            Symbol(name: "scissors", title: "Scissors"),
            Symbol(name: "flask.fill", title: "Flask"),
            Symbol(name: "atom", title: "Atom"),
            Symbol(name: "terminal.fill", title: "Terminal"),
            Symbol(name: "cpu.fill", title: "Chip"),
        ]),
    ]

    /// In the order workspaces are assigned them.
    public static let all: [Symbol] = groups.flatMap(\.symbols)

    public static func contains(_ name: String) -> Bool {
        all.contains { $0.name == name }
    }
}
