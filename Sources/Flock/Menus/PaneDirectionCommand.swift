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

    /// Command+Option+arrow focuses, as it moves between splits in Ghostty.
    /// Command+Control+Option+arrow moves and Command+Control+Shift+arrow
    /// swaps; Command+Control+arrow alone is the tab strip's. None is claimed
    /// by the system.
    static let all: [PaneDirectionCommand] = {
        let directions: [(String, KeyEquivalent, PaneDirection)] = [
            ("Left", .leftArrow, .left), ("Right", .rightArrow, .right),
            ("Up", .upArrow, .up), ("Down", .downArrow, .down),
        ]
        let families: [(Kind, String, EventModifiers, String)] = [
            (.focus, "Focus Pane", [.command, .option], "focusPane"),
            (.move, "Move Pane", [.command, .control, .option], "movePane"),
            (.swap, "Swap Pane", [.command, .control, .shift], "swapPane"),
        ]
        return families.flatMap { kind, title, modifiers, identifier in
            directions.map { name, key, direction in
                PaneDirectionCommand(
                    title: "\(title) \(name)", key: key, modifiers: modifiers, direction: direction,
                    kind: kind, accessibilityIdentifier: "flock.view.\(identifier).\(name.lowercased())"
                )
            }
        }
    }()
}

/// F2. There is no `KeyEquivalent` case for a function key, so it is the
/// scalar AppKit itself uses (`NSF2FunctionKey`); the menu equivalent takes
/// no modifier.
extension KeyEquivalent {
    static let f2 = KeyEquivalent("\u{F705}")
}
