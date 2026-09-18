import Foundation

/// herdr's two input modes, and what one key press does in each.
///
/// There is no deadline on the second key: herdr's client waits in prefix
/// mode until something is pressed, however long that takes, so this machine
/// takes no clock.
public struct PrefixKeyMachine: Sendable {
    public enum Mode: Equatable, Sendable {
        case terminal
        case prefix
    }

    public enum Outcome: Equatable, Sendable {
        /// Hand the key to the program in the pane.
        case sendToPane
        /// Take the key and do nothing with it.
        case swallow
        case enteredPrefix
        case run(HerdrBinding)
    }

    public private(set) var mode: Mode = .terminal
    public private(set) var keybindings: HerdrKeybindings

    public init(keybindings: HerdrKeybindings = .defaults) {
        self.keybindings = keybindings
    }

    /// Swaps in a keymap read from a changed config. A keymap that actually
    /// changed drops prefix mode: the key the user is halfway through may no
    /// longer mean what it did when they pressed the prefix.
    public mutating func update(keybindings: HerdrKeybindings) {
        guard keybindings != self.keybindings else { return }
        self.keybindings = keybindings
        mode = .terminal
    }

    public mutating func handle(_ press: HerdrKeyPress) -> Outcome {
        switch mode {
        case .terminal:
            if let binding = keybindings.direct(matching: press) {
                return .run(binding)
            }
            guard keybindings.prefix.matches(press) else { return .sendToPane }
            mode = .prefix
            return .enteredPrefix
        case .prefix:
            mode = .terminal
            if keybindings.prefix.matches(press) {
                return .sendToPane
            }
            if press.code == .escape {
                return .swallow
            }
            guard let binding = keybindings.prefixed(matching: press) else { return .swallow }
            return .run(binding)
        }
    }
}
