public enum JumpPlace: Equatable, Sendable {
    case missionControl
    case pane(PaneID)
}

/// Where the last jump left from, one level deep. Going back is itself a
/// jump, so pressing it twice returns to where it started.
public struct JumpBack: Equatable, Sendable {
    public private(set) var origin: JumpPlace?

    public init() {}

    public mutating func jumped(from place: JumpPlace) {
        origin = place
    }

    public func target(livePanes: Set<PaneID>) -> JumpPlace? {
        switch origin {
        case .pane(let pane)?: livePanes.contains(pane) ? origin : nil
        case .missionControl?: .missionControl
        case nil: nil
        }
    }
}
