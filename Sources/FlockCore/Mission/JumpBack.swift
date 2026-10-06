public enum JumpPlace: Equatable, Sendable {
    case missionControl
    case pane(PaneID)
}

/// Where the last jump left from, one level deep. Going back is itself a
/// jump, so pressing it twice returns to where it started.
public struct JumpBack: Equatable, Sendable {
    public private(set) var origin: JumpPlace?

    public init() {}

    /// A jump that lands where it left records nothing: it would leave
    /// Jump Back pointing at the place the user is already in.
    public mutating func jumped(from place: JumpPlace, to destination: JumpPlace) {
        guard place != destination else { return }
        origin = place
    }

    /// Nil while the user is already at the origin, which they can reach by
    /// hand after a jump.
    public func target(livePanes: Set<PaneID>, current: JumpPlace?) -> JumpPlace? {
        let live: JumpPlace? = switch origin {
        case .pane(let pane)?: livePanes.contains(pane) ? origin : nil
        case .missionControl?: .missionControl
        case nil: nil
        }
        return live == current ? nil : live
    }
}
