import Foundation
import Observation

/// How far a wheel gesture carries, as a factor on the distance the gesture
/// itself reports. One step of a mouse wheel is one line at `normal`, which
/// is deliberately the plainest reading of the event and so the only one an
/// existing user can be left on without noticing a change.
///
/// The ladder is geometric, each step double the one below: a step the hand
/// cannot feel is a setting that reads as broken. `slow` halves rather than
/// stopping, so the slowest step still crosses a cell within one gesture (two
/// wheel notches, or a swipe of two cell heights).
public enum ScrollSpeed: String, CaseIterable, Sendable {
    case slow
    case normal
    case fast
    case fastest

    public var multiplier: Double {
        switch self {
        case .slow: return 0.5
        case .normal: return 1
        case .fast: return 2
        case .fastest: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .fastest: return "Fastest"
        }
    }
}

/// Holds the active scroll speed, persisted across launches, mirroring
/// `RailWidthStore` and `TerminalTextSizeStore`'s own UserDefaults pattern.
/// Read at wheel time rather than injected into the view tree: the setting
/// changes how an event is measured, never how anything is drawn, so nothing
/// re-renders when it changes.
@MainActor
@Observable
public final class ScrollSpeedStore {
    public static let defaultsKey = "flock.scrollSpeed"

    public private(set) var active: ScrollSpeed

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.string(forKey: Self.defaultsKey)
        active = stored.flatMap(ScrollSpeed.init(rawValue:)) ?? .normal
    }

    public func select(_ speed: ScrollSpeed) {
        active = speed
        userDefaults.set(speed.rawValue, forKey: Self.defaultsKey)
    }
}
