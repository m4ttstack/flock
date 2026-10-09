import FlockCore
import SwiftUI

/// One directional pane command: its title, the arrow that runs it, the
/// modifiers it runs under, and whether it focuses the neighbor, moves the
/// pane past it, or trades places with it. All three aim at the same
/// neighbor, so all three are enabled by the same predicate.
struct PaneDirectionCommand {
    enum Kind { case focus, move, swap }

    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let direction: PaneDirection
    let kind: Kind
    let accessibilityIdentifier: String

    /// What the row reads inside its family's submenu.
    let directionName: String

    /// A neighbor exists only in a drawn layout, which Overview's lone pane is not.
    static let paletteSurfaces: Set<PaletteSurface> = [.workspaces]

    /// Every pane family sits on Command+Option, as Ghostty's split focus
    /// does: Shift adds move, Control adds swap. Command+Control+arrow alone
    /// is the strip's and the rail's. None is claimed by the system.
    static let families: [(kind: Kind, title: String, modifiers: EventModifiers)] = [
        (.focus, "Focus Pane", [.command, .option]),
        (.move, "Move Pane", [.command, .option, .shift]),
        (.swap, "Swap Pane", [.command, .option, .control]),
    ]

    static let all: [PaneDirectionCommand] = families.flatMap { commands(for: $0.kind) }

    static func commands(for kind: Kind) -> [PaneDirectionCommand] {
        guard let family = families.first(where: { $0.kind == kind }) else { return [] }
        let identifier = switch kind {
        case .focus: "focusPane"
        case .move: "movePane"
        case .swap: "swapPane"
        }
        let directions: [(String, KeyEquivalent, PaneDirection)] = [
            ("Left", .leftArrow, .left), ("Right", .rightArrow, .right),
            ("Up", .upArrow, .up), ("Down", .downArrow, .down),
        ]
        return directions.map { name, key, direction in
            PaneDirectionCommand(
                title: "\(family.title) \(name)", key: key, modifiers: family.modifiers, direction: direction,
                kind: kind, accessibilityIdentifier: "flock.pane.\(identifier).\(name.lowercased())", directionName: name
            )
        }
    }
}

/// F2. There is no `KeyEquivalent` case for a function key, so it is the
/// scalar AppKit itself uses (`NSF2FunctionKey`); the menu equivalent takes
/// no modifier.
extension KeyEquivalent {
    static let f2 = KeyEquivalent("\u{F705}")
}
