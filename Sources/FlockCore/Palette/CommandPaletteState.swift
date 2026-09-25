import Observation

/// Whether the palette is up, what is typed, and which row is selected. The
/// row count is the caller's: the rows depend on the moment, not on this.
@MainActor
@Observable
public final class CommandPaletteState {
    public private(set) var isOpen = false
    public var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    public private(set) var selection = 0

    public init() {}

    public func open() {
        query = ""
        selection = 0
        isOpen = true
    }

    public func close() {
        isOpen = false
    }

    public func toggle() {
        isOpen ? close() : open()
    }

    public func move(_ delta: Int, rowCount: Int) {
        selection = clamped(selection + delta, rowCount: rowCount)
    }

    public func clampSelection(rowCount: Int) {
        selection = clamped(selection, rowCount: rowCount)
    }

    public func selectedIndex(rowCount: Int) -> Int? {
        rowCount > 0 ? clamped(selection, rowCount: rowCount) : nil
    }

    private func clamped(_ index: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return min(max(index, 0), rowCount - 1)
    }
}

/// The keys the palette takes before its search field or the window sees
/// them. Command (⌘) combinations always pass, so the menu bar keeps them.
public enum PaletteKey {
    public enum Decision: Equatable, Sendable { case up, down, run, close, pass }

    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53

    public static func decide(keyCode: UInt16, characters: String?, control: Bool, command: Bool) -> Decision {
        guard !command else { return .pass }
        switch keyCode {
        case upArrow: return .up
        case downArrow: return .down
        case returnKey, keypadEnter: return .run
        case escape: return .close
        default: break
        }
        guard control else { return .pass }
        switch characters?.lowercased() {
        case "p": return .up
        case "n": return .down
        default: return .pass
        }
    }
}
