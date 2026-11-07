import Foundation
import Observation

/// How the canvas tells the focused pane from the rest.
public enum PaneFocusStyle: String, CaseIterable, Sendable {
    /// What a fresh install shows.
    public static let standard: PaneFocusStyle = .dimOthers

    case brighterBorder
    case dimOthers
    case lift

    public var displayName: String {
        switch self {
        case .brighterBorder: "Brighter border"
        case .dimOthers: "Dim others"
        case .lift: "Lift"
        }
    }
}

/// Whether panes sit as boxes on the canvas or fill it, ruled apart.
public enum PaneLayoutStyle: String, CaseIterable, Sendable {
    /// What a fresh install shows.
    public static let standard: PaneLayoutStyle = .edgeToEdge

    case boxed
    case edgeToEdge

    public var displayName: String {
        switch self {
        case .boxed: "Boxed"
        case .edgeToEdge: "Edge to edge"
        }
    }
}

/// The line under a pane's header that carries its agent's status. Working
/// takes the chosen motion; blocked always breathes red and done is a faint
/// still line, whatever is picked here.
public enum PaneStatusLineStyle: String, CaseIterable, Sendable {
    /// What a fresh install shows.
    public static let standard: PaneStatusLineStyle = .aurora

    case off
    case glint
    case comet
    case aurora
    case breathe

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .glint: "Glint"
        case .comet: "Comet"
        case .aurora: "Aurora"
        case .breathe: "Breathe"
        }
    }
}

/// Every Settings choice, persisted across launches in the same UserDefaults
/// pattern as `RearrangeAfterMoveStore`.
@MainActor
@Observable
public final class PaneAppearanceStore {
    public static let focusStyleKey = "flock.paneFocusStyle"
    public static let layoutKey = "flock.paneLayout"
    public static let statusLineKey = "flock.paneStatusLine"

    public private(set) var focusStyle: PaneFocusStyle
    public private(set) var layout: PaneLayoutStyle
    public private(set) var statusLine: PaneStatusLineStyle

    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        focusStyle = userDefaults.string(forKey: Self.focusStyleKey).flatMap(PaneFocusStyle.init(rawValue:)) ?? .standard
        layout = userDefaults.string(forKey: Self.layoutKey).flatMap(PaneLayoutStyle.init(rawValue:)) ?? .standard
        statusLine = userDefaults.string(forKey: Self.statusLineKey).flatMap(PaneStatusLineStyle.init(rawValue:)) ?? .standard
    }

    public func select(_ value: PaneFocusStyle) {
        focusStyle = value
        userDefaults.set(value.rawValue, forKey: Self.focusStyleKey)
    }

    public func select(_ value: PaneLayoutStyle) {
        layout = value
        userDefaults.set(value.rawValue, forKey: Self.layoutKey)
    }

    public func select(_ value: PaneStatusLineStyle) {
        statusLine = value
        userDefaults.set(value.rawValue, forKey: Self.statusLineKey)
    }
}
