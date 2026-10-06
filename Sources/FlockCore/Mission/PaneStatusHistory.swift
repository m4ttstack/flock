import Foundation

/// Each pane's agent status over the last hour, as flock saw it change. Kept
/// in memory only: after a launch every pane starts with one entry, its
/// status at the first snapshot.
public struct PaneStatusHistory: Equatable, Sendable {
    public struct Transition: Equatable, Sendable {
        public let status: AgentStatus
        public let at: Date
    }

    /// A nil `status` is time before flock first saw the pane.
    public struct Segment: Equatable, Sendable {
        public let status: AgentStatus?
        public let start: Date
        public let end: Date

        public init(status: AgentStatus?, start: Date, end: Date) {
            self.status = status
            self.start = start
            self.end = end
        }

        /// The segments as a timeline `width` points wide can show them: a
        /// segment narrower than `minimumWidth` joins the one before it (the
        /// one after, at the start), taking the longer piece's status. Every
        /// band but the last is at least `minimumWidth` wide, so a pane whose
        /// status flaps draws no more bands than the timeline has points.
        public static func drawable(_ segments: [Segment], width: Double, minimumWidth: Double = 1) -> [Segment] {
            let total = segments.reduce(0) { $0 + $1.span }
            let minimumSpan = width > 0 ? total * minimumWidth / width : .infinity
            var result: [Segment] = []
            for segment in segments {
                guard let last = result.last,
                      segment.span < minimumSpan || last.span < minimumSpan || segment.status == last.status
                else {
                    result.append(segment)
                    continue
                }
                let status = segment.span > last.span ? segment.status : last.status
                result[result.count - 1] = Segment(status: status, start: last.start, end: segment.end)
            }
            return result
        }

        private var span: TimeInterval { end.timeIntervalSince(start) }
    }

    public static let window: TimeInterval = 60 * 60

    public private(set) var transitions: [PaneID: [Transition]] = [:]

    public init() {}

    public mutating func observe(_ model: SessionModel, at now: Date) {
        for (paneID, pane) in model.panes where transitions[paneID]?.last?.status != pane.agentStatus {
            transitions[paneID, default: []].append(Transition(status: pane.agentStatus, at: now))
        }
        for paneID in Array(transitions.keys) where model.panes[paneID] == nil {
            transitions[paneID] = nil
        }
        trim(at: now)
    }

    /// Keeps the transition in force at the window's start, so a pane quiet
    /// for hours still knows when it last changed.
    private mutating func trim(at now: Date) {
        let start = now.addingTimeInterval(-Self.window)
        for (paneID, list) in transitions {
            guard let inForce = list.lastIndex(where: { $0.at <= start }), inForce > 0 else { continue }
            transitions[paneID] = Array(list[inForce...])
        }
    }

    public func lastChange(of pane: PaneID) -> Date? {
        transitions[pane]?.last?.at
    }

    public func age(of pane: PaneID, at now: Date) -> TimeInterval? {
        lastChange(of: pane).map { now.timeIntervalSince($0) }
    }

    public func segments(of pane: PaneID, at now: Date) -> [Segment] {
        let start = now.addingTimeInterval(-Self.window)
        guard let list = transitions[pane], let first = list.first else {
            return [Segment(status: nil, start: start, end: now)]
        }
        var result: [Segment] = []
        if first.at > start {
            result.append(Segment(status: nil, start: start, end: first.at))
        }
        for (index, transition) in list.enumerated() {
            let end = index + 1 < list.count ? list[index + 1].at : now
            let from = max(transition.at, start)
            guard end > from else { continue }
            result.append(Segment(status: transition.status, start: from, end: end))
        }
        return result
    }
}
