import CoreGraphics
import Foundation
import Observation

/// What the workspace rail may be made, whoever is asking. The rail's own
/// width is the user's to choose, but two floors are not: the rail itself,
/// which has to stay wide enough to grab back, and the canvas beside it,
/// which is what the window is for.
///
/// `minimumContentWidth` is stated against the window's own 900pt minimum
/// (`MainWindow`): the rail reaches `maximum` there, so the floor bites only
/// on a window narrower than flock asks for at all.
public enum RailWidth {
    public static let `default`: CGFloat = 192
    public static let minimum: CGFloat = 150
    public static let maximum: CGFloat = 360
    public static let minimumContentWidth: CGFloat = 520

    /// `windowWidth` is `nil` before the window has reported one, which
    /// clamps to the bounds alone.
    public static func clamped(_ width: CGFloat, inWindowWidth windowWidth: CGFloat?) -> CGFloat {
        var ceiling = maximum
        if let windowWidth {
            // A window with no room for both keeps the rail at its minimum
            // and lets the canvas take the shortfall: a rail clamped to
            // nothing is a rail no pointer can find again.
            ceiling = max(minimum, min(ceiling, windowWidth - minimumContentWidth))
        }
        return max(minimum, min(width, ceiling))
    }
}

/// The rail's width across launches, and during the drag that changes it.
///
/// The width the user asked for is kept apart from the width the window can
/// currently afford: a narrow window shrinks the rail on screen without
/// rewriting the request, so widening the window gives back what was asked
/// for rather than the compromise. Mirrors `TerminalTextSizeStore`'s
/// UserDefaults pattern, and is injected the same way.
@MainActor
@Observable
public final class RailWidthStore {
    public static let defaultsKey = "flock.railWidth"

    /// What a release last wrote down.
    private var preferred: CGFloat
    /// The pointer's own width while a drag is in flight.
    private var live: CGFloat?
    private var windowWidth: CGFloat?
    @ObservationIgnored private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.object(forKey: Self.defaultsKey) as? Double
        preferred = stored.map { CGFloat($0) } ?? RailWidth.default
    }

    /// What the rail is drawn at.
    public var width: CGFloat { RailWidth.clamped(live ?? preferred, inWindowWidth: windowWidth) }

    public func windowResized(to windowWidth: CGFloat) {
        self.windowWidth = windowWidth
    }

    public func dragged(to width: CGFloat) {
        live = width
    }

    /// The release carries its own pointer, which is the width that is kept:
    /// motion is coalesced and can be outrun, so the last position a drag
    /// reported is not where the hand finished.
    public func released(at width: CGFloat) {
        live = nil
        preferred = RailWidth.clamped(width, inWindowWidth: windowWidth)
        userDefaults.set(Double(preferred), forKey: Self.defaultsKey)
    }

    public func cancelDrag() {
        live = nil
    }
}
