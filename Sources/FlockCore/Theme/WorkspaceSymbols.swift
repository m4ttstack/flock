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

    /// The picker's sections, in order.
    public static let groups: [Group] = [
        Group(title: "Nature", symbols: [
            Symbol(name: "leaf.fill", title: "Leaf"),
            Symbol(name: "tree.fill", title: "Tree"),
            Symbol(name: "mountain.2.fill", title: "Mountains"),
            Symbol(name: "flame.fill", title: "Flame"),
            Symbol(name: "drop.fill", title: "Drop"),
            Symbol(name: "snowflake", title: "Snowflake"),
            Symbol(name: "sun.max.fill", title: "Sun"),
            Symbol(name: "moon.fill", title: "Moon"),
            Symbol(name: "moon.stars.fill", title: "Night"),
            Symbol(name: "cloud.fill", title: "Cloud"),
            Symbol(name: "cloud.rain.fill", title: "Rain"),
            Symbol(name: "cloud.bolt.fill", title: "Storm"),
            Symbol(name: "bolt.fill", title: "Bolt"),
            Symbol(name: "tornado", title: "Tornado"),
            Symbol(name: "rainbow", title: "Rainbow"),
            Symbol(name: "sparkles", title: "Sparkles"),
            Symbol(name: "wind", title: "Wind"),
            Symbol(name: "water.waves", title: "Waves"),
            Symbol(name: "carrot.fill", title: "Carrot"),
            Symbol(name: "globe.americas.fill", title: "Globe"),
            Symbol(name: "globe.europe.africa.fill", title: "Globe east"),
            Symbol(name: "globe.asia.australia.fill", title: "Globe south"),
        ]),
        Group(title: "Tools", symbols: [
            Symbol(name: "hammer.fill", title: "Hammer"),
            Symbol(name: "wrench.adjustable.fill", title: "Wrench"),
            Symbol(name: "wrench.and.screwdriver.fill", title: "Toolkit"),
            Symbol(name: "screwdriver.fill", title: "Screwdriver"),
            Symbol(name: "paintbrush.fill", title: "Brush"),
            Symbol(name: "paintbrush.pointed.fill", title: "Fine brush"),
            Symbol(name: "paintpalette.fill", title: "Palette"),
            Symbol(name: "pencil", title: "Pencil"),
            Symbol(name: "scissors", title: "Scissors"),
            Symbol(name: "ruler.fill", title: "Ruler"),
            Symbol(name: "flask.fill", title: "Flask"),
            Symbol(name: "testtube.2", title: "Test tubes"),
            Symbol(name: "atom", title: "Atom"),
            Symbol(name: "terminal.fill", title: "Terminal"),
            Symbol(name: "cpu.fill", title: "Chip"),
            Symbol(name: "memorychip.fill", title: "Memory"),
            Symbol(name: "server.rack", title: "Server"),
            Symbol(name: "externaldrive.fill", title: "Drive"),
            Symbol(name: "keyboard.fill", title: "Keyboard"),
            Symbol(name: "printer.fill", title: "Printer"),
            Symbol(name: "magnifyingglass", title: "Magnifier"),
            Symbol(name: "lightbulb.fill", title: "Bulb"),
            Symbol(name: "wand.and.stars", title: "Wand"),
            Symbol(name: "gearshape.fill", title: "Gear"),
            Symbol(name: "shippingbox.fill", title: "Parcel"),
            Symbol(name: "archivebox.fill", title: "Archive"),
            Symbol(name: "folder.fill", title: "Folder"),
            Symbol(name: "doc.fill", title: "Document"),
            Symbol(name: "paperclip", title: "Paperclip"),
            Symbol(name: "link", title: "Link"),
            Symbol(name: "briefcase.fill", title: "Briefcase"),
        ]),
        Group(title: "Things", symbols: [
            Symbol(name: "paperplane.fill", title: "Paper plane"),
            Symbol(name: "gift.fill", title: "Gift"),
            Symbol(name: "crown.fill", title: "Crown"),
            Symbol(name: "cup.and.saucer.fill", title: "Cup"),
            Symbol(name: "mug.fill", title: "Mug"),
            Symbol(name: "wineglass.fill", title: "Wineglass"),
            Symbol(name: "fork.knife", title: "Cutlery"),
            Symbol(name: "birthday.cake.fill", title: "Cake"),
            Symbol(name: "gamecontroller.fill", title: "Controller"),
            Symbol(name: "dice.fill", title: "Dice"),
            Symbol(name: "puzzlepiece.fill", title: "Puzzle"),
            Symbol(name: "cube.fill", title: "Cube"),
            Symbol(name: "camera.fill", title: "Camera"),
            Symbol(name: "film.fill", title: "Film"),
            Symbol(name: "music.note", title: "Note"),
            Symbol(name: "guitars.fill", title: "Guitars"),
            Symbol(name: "pianokeys", title: "Piano"),
            Symbol(name: "headphones", title: "Headphones"),
            Symbol(name: "mic.fill", title: "Mic"),
            Symbol(name: "book.closed.fill", title: "Book"),
            Symbol(name: "books.vertical.fill", title: "Books"),
            Symbol(name: "graduationcap.fill", title: "Cap"),
            Symbol(name: "backpack.fill", title: "Backpack"),
            Symbol(name: "bag.fill", title: "Bag"),
            Symbol(name: "cart.fill", title: "Cart"),
            Symbol(name: "creditcard.fill", title: "Card"),
            Symbol(name: "banknote.fill", title: "Banknote"),
            Symbol(name: "key.fill", title: "Key"),
            Symbol(name: "lock.fill", title: "Lock"),
            Symbol(name: "tag.fill", title: "Tag"),
            Symbol(name: "bookmark.fill", title: "Bookmark"),
            Symbol(name: "pin.fill", title: "Pin"),
            Symbol(name: "map.fill", title: "Map"),
            Symbol(name: "binoculars.fill", title: "Binoculars"),
            Symbol(name: "umbrella.fill", title: "Umbrella"),
            Symbol(name: "theatermasks.fill", title: "Masks"),
            Symbol(name: "trophy.fill", title: "Trophy"),
            Symbol(name: "medal.fill", title: "Medal"),
            Symbol(name: "balloon.fill", title: "Balloon"),
            Symbol(name: "party.popper.fill", title: "Party"),
            Symbol(name: "house.fill", title: "House"),
            Symbol(name: "building.2.fill", title: "Buildings"),
            Symbol(name: "building.columns.fill", title: "Columns"),
            Symbol(name: "tent.fill", title: "Tent"),
            Symbol(name: "lamp.desk.fill", title: "Lamp"),
            Symbol(name: "sofa.fill", title: "Sofa"),
            Symbol(name: "tshirt.fill", title: "T-shirt"),
            Symbol(name: "eyeglasses", title: "Glasses"),
        ]),
        Group(title: "Travel and sport", symbols: [
            Symbol(name: "airplane", title: "Airplane"),
            Symbol(name: "car.fill", title: "Car"),
            Symbol(name: "bus.fill", title: "Bus"),
            Symbol(name: "tram.fill", title: "Tram"),
            Symbol(name: "bicycle", title: "Bicycle"),
            Symbol(name: "sailboat.fill", title: "Sailboat"),
            Symbol(name: "ferry.fill", title: "Ferry"),
            Symbol(name: "fuelpump.fill", title: "Fuel"),
            Symbol(name: "signpost.right.fill", title: "Signpost"),
            Symbol(name: "figure.run", title: "Runner"),
            Symbol(name: "figure.hiking", title: "Hiker"),
            Symbol(name: "soccerball", title: "Football"),
            Symbol(name: "basketball.fill", title: "Basketball"),
            Symbol(name: "baseball.fill", title: "Baseball"),
            Symbol(name: "tennis.racket", title: "Racket"),
            Symbol(name: "skateboard.fill", title: "Skateboard"),
        ]),
        Group(title: "Shapes", symbols: [
            Symbol(name: "triangle.fill", title: "Triangle"),
            Symbol(name: "diamond.fill", title: "Diamond"),
            Symbol(name: "square.fill", title: "Square"),
            Symbol(name: "hexagon.fill", title: "Hexagon"),
            Symbol(name: "pentagon.fill", title: "Pentagon"),
            Symbol(name: "octagon.fill", title: "Octagon"),
            Symbol(name: "rhombus.fill", title: "Rhombus"),
            Symbol(name: "seal.fill", title: "Seal"),
            Symbol(name: "star.fill", title: "Star"),
            Symbol(name: "heart.fill", title: "Heart"),
            Symbol(name: "shield.fill", title: "Shield"),
            Symbol(name: "suit.club.fill", title: "Club"),
            Symbol(name: "suit.spade.fill", title: "Spade"),
        ]),
        Group(title: "Animals", symbols: [
            Symbol(name: "bird.fill", title: "Bird"),
            Symbol(name: "fish.fill", title: "Fish"),
            Symbol(name: "hare.fill", title: "Hare"),
            Symbol(name: "tortoise.fill", title: "Tortoise"),
            Symbol(name: "ladybug.fill", title: "Ladybug"),
            Symbol(name: "pawprint.fill", title: "Paw"),
        ]),
    ]

    /// Assigned first, being the most unlike one another.
    static let assignedFirst = [
        "leaf.fill", "bolt.fill", "flask.fill", "hammer.fill",
        "book.closed.fill", "terminal.fill", "globe.americas.fill", "cube.fill",
        "puzzlepiece.fill", "paperplane.fill", "flame.fill", "drop.fill",
        "mountain.2.fill", "cpu.fill", "key.fill", "tag.fill",
        "triangle.fill", "diamond.fill", "hexagon.fill", "star.fill",
    ]

    /// In the order workspaces are assigned them.
    public static let all: [Symbol] = {
        let every = groups.flatMap(\.symbols)
        let lead = assignedFirst.compactMap { name in every.first { $0.name == name } }
        return lead + every.filter { !assignedFirst.contains($0.name) }
    }()

    public static func contains(_ name: String) -> Bool {
        all.contains { $0.name == name }
    }
}
