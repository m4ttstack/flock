import Foundation
import Observation

/// Whether Option acts as Alt in a pane's terminal, and on which key: mirrors
/// libghostty's `macos-option-as-alt` (`Vendor/ghostty/src/input/config.zig`'s
/// `OptionAsAlt`), which defaults OFF -- an untouched surface turns
/// Option+Backspace into nothing a shell can read, rather than the `ESC DEL`
/// that means delete-word.
public enum OptionAsAlt: String, CaseIterable, Sendable {
    case off
    case both
    case left
    case right

    /// The literal libghostty's config-line parser wants for this key.
    public var configValue: String {
        switch self {
        case .off: return "false"
        case .both: return "true"
        case .left: return "left"
        case .right: return "right"
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .both: return "Both"
        case .left: return "Left Option"
        case .right: return "Right Option"
        }
    }
}

/// Holds the active Option-as-Alt setting, persisted across launches,
/// mirroring `ScrollSpeedStore`/`TerminalTextSizeStore`'s own UserDefaults
/// pattern. A fresh store opens at `.left`, not at libghostty's own `.off`
/// default: left Option becomes Alt (word-delete, word-jump) while right
/// Option still types accented characters, which is what a real ghostty user
/// coming to flock already expects.
@MainActor
@Observable
public final class OptionAsAltStore {
    public static let defaultsKey = "flock.optionAsAlt"

    public private(set) var active: OptionAsAlt

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.string(forKey: Self.defaultsKey)
        active = stored.flatMap(OptionAsAlt.init(rawValue:)) ?? .left
    }

    public func select(_ value: OptionAsAlt) {
        active = value
        userDefaults.set(value.rawValue, forKey: Self.defaultsKey)
    }
}
