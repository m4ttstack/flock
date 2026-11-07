import Foundation
import Observation

/// How the canvas tells the focused pane from the rest.
public enum PaneFocusStyle: String, CaseIterable, Sendable {
    case brighterBorder
    case dimOthers
    case lift
    case accentTick

    public var displayName: String {
        switch self {
        case .brighterBorder: "Brighter border"
        case .dimOthers: "Dim others"
        case .lift: "Lift"
        case .accentTick: "Accent tick"
        }
    }
}

/// Whether panes sit as boxes on the canvas or fill it, ruled apart.
public enum PaneLayoutStyle: String, CaseIterable, Sendable {
    case boxed
    case edgeToEdge

    public var displayName: String {
        switch self {
        case .boxed: "Boxed"
        case .edgeToEdge: "Edge to edge"
        }
    }
}

/// Both Settings choices, persisted across launches in the same UserDefaults
/// pattern as `RearrangeAfterMoveStore`.
@MainActor
@Observable
public final class PaneAppearanceStore {
    public static let focusStyleKey = "flock.paneFocusStyle"
    public static let layoutKey = "flock.paneLayout"

    public private(set) var focusStyle: PaneFocusStyle
    public private(set) var layout: PaneLayoutStyle

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        focusStyle = userDefaults.string(forKey: Self.focusStyleKey).flatMap(PaneFocusStyle.init(rawValue:)) ?? .brighterBorder
        layout = userDefaults.string(forKey: Self.layoutKey).flatMap(PaneLayoutStyle.init(rawValue:)) ?? .boxed
    }

    public func select(_ value: PaneFocusStyle) {
        focusStyle = value
        userDefaults.set(value.rawValue, forKey: Self.focusStyleKey)
    }

    public func select(_ value: PaneLayoutStyle) {
        layout = value
        userDefaults.set(value.rawValue, forKey: Self.layoutKey)
    }
}
