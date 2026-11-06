import Foundation

/// The current machine's connection, as one dot: live while panes are served
/// with nothing to say, attention whenever the window shows a machine notice.
public enum ProfileConnectionDot: Equatable, Sendable {
    case live
    case attention

    public static func forMachine(hasNotice: Bool) -> ProfileConnectionDot {
        hasNotice ? .attention : .live
    }
}

public struct ProfilePickerRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let isMachine: Bool
    public let isCurrent: Bool
    /// Only the current machine's row has one: no other machine is connected.
    public let dot: ProfileConnectionDot?

    public init(id: String, title: String, isMachine: Bool, isCurrent: Bool, dot: ProfileConnectionDot?) {
        self.id = id
        self.title = title
        self.isMachine = isMachine
        self.isCurrent = isCurrent
        self.dot = dot
    }
}

/// The profile picker's list: Default and the user's profiles, then the
/// herdr machines, each section in `ProfileStore` order.
public struct ProfilePickerModel: Equatable, Sendable {
    public let local: [ProfilePickerRow]
    public let machines: [ProfilePickerRow]

    /// Keyboard order: the sections as drawn, top to bottom.
    public var rows: [ProfilePickerRow] { local + machines }
    public var current: ProfilePickerRow? { rows.first(where: \.isCurrent) }
    public var currentIndex: Int? { rows.firstIndex(where: \.isCurrent) }

    public init(profiles: [FlockProfile], currentID: String, currentDot: ProfileConnectionDot?) {
        let rows = profiles.map { profile in
            let isCurrent = profile.id == currentID
            return ProfilePickerRow(
                id: profile.id, title: profile.name, isMachine: profile.isMachine, isCurrent: isCurrent,
                dot: isCurrent && profile.isMachine ? currentDot : nil
            )
        }
        local = rows.filter { !$0.isMachine }
        machines = rows.filter(\.isMachine)
    }

    /// Up and down stop at the ends rather than wrap, as the pin folder list does.
    public static func step(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}
