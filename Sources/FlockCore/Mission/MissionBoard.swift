import Foundation

/// One pane as mission control draws it.
public struct MissionCard: Equatable, Sendable, Identifiable {
    public var id: PaneID { paneID }
    public let paneID: PaneID
    public let workspaceID: WorkspaceID
    public let tabID: TabID
    /// A herd's workspace reads "auth-sweep · herd 2/4".
    public let workspaceName: String
    public let tabTitle: String
    /// `PaneNaming.cardTitles`: the card's title and its small second line.
    public let title: String
    public var detail: String? = nil
    public let status: AgentStatus
    /// When the pane entered `status`, or when its attention card was raised.
    public let since: Date?
    public let folder: String
    /// What the pane runs in the background while herdr calls it idle or
    /// done; `status` is then `.working`.
    public var backgroundWork: String? = nil

    public var shown: ShownStatus { ShownStatus(status, backgroundWork: backgroundWork) }

    /// The status, with how long it has held when that is known: `blocked 12m`,
    /// or `working · 1 shell · 3m` for background work.
    public func stateText(at now: Date) -> String {
        guard let since else { return shown.word }
        let age = MissionAge.text(now.timeIntervalSince(since))
        return backgroundWork == nil ? "\(shown.word) \(age)" : "\(shown.word) · \(age)"
    }
}

extension MissionCard {
    /// `names` is `MissionBoard.workspaceNames`, built once per board.
    init(
        _ pane: PaneRecord, status: ShownStatus, since: Date?, model: SessionModel, names: [WorkspaceID: String], oneTitle: Bool
    ) {
        let tab = model.tabs[pane.workspaceID]?.first { $0.tabID == pane.tabID }
        let titles = PaneNaming.cardTitles(pane: pane, model: model, oneTitle: oneTitle)
        self.init(
            paneID: pane.paneID, workspaceID: pane.workspaceID, tabID: pane.tabID,
            workspaceName: names[pane.workspaceID] ?? pane.workspaceID.rawValue,
            tabTitle: tab.map { TabTitle.resolve($0, in: model).text } ?? pane.tabID.rawValue,
            title: titles.title, detail: titles.detail, status: status.status, since: since,
            folder: pane.foregroundCwd ?? pane.cwd, backgroundWork: status.backgroundWork
        )
    }
}

public struct MissionGroup: Equatable, Sendable, Identifiable {
    public var id: WorkspaceID { workspaceID }
    public let workspaceID: WorkspaceID
    public let name: String
    public let cards: [MissionCard]
}

/// How long ago an At rest pane last changed status, as the lane sections it.
public enum RestAge: CaseIterable, Sendable {
    case lastHour
    case earlierToday
    case yesterday
    case thisWeek
    case older
    /// No known last change: flock never saw the pane change, and nothing
    /// persisted dates its status.
    case unknown

    public var title: String {
        switch self {
        case .lastHour: "Last hour"
        case .earlierToday: "Earlier today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .older: "Older"
        case .unknown: "Unknown"
        }
    }

    /// Days are calendar days in `calendar`'s time zone.
    public static func of(_ since: Date?, now: Date, calendar: Calendar) -> RestAge {
        guard let since else { return .unknown }
        let age = now.timeIntervalSince(since)
        if age < 60 * 60 { return .lastHour }
        let today = calendar.startOfDay(for: now)
        if since >= today { return .earlierToday }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), since >= yesterday { return .yesterday }
        if age < 7 * 24 * 60 * 60 { return .thisWeek }
        return .older
    }
}

/// One of At rest's time sections. Never empty.
public struct MissionRestSection: Equatable, Sendable, Identifiable {
    /// Past this many panes, Older and Unknown can fold to their label.
    public static let collapsibleOver = 8

    public var id: RestAge { age }
    public let age: RestAge
    /// By workspace, the group with the most recent change first and each
    /// group's cards most recent first.
    public let groups: [MissionGroup]
    public let count: Int
    public let isCollapsible: Bool
    public let isCollapsed: Bool

    public init(age: RestAge, groups: [MissionGroup], count: Int, isCollapsible: Bool, isCollapsed: Bool) {
        self.age = age
        self.groups = groups
        self.count = count
        self.isCollapsible = isCollapsible
        self.isCollapsed = isCollapsed
    }
}

/// Every pane in the lane its state puts it in. Needs you is the attention
/// stack itself, so the dock and the lane can never disagree.
public struct MissionBoard: Equatable, Sendable {
    /// By workspace, the group holding the oldest card first and each
    /// group's cards oldest first, so the top card is the oldest of all.
    public let needsYou: [MissionGroup]
    public let working: [MissionGroup]
    /// Most recent section first, panes with no known change last. A workspace with panes in two sections
    /// has a group in each.
    public let atRest: [MissionRestSection]

    public var atRestCount: Int { atRest.reduce(0) { $0 + $1.count } }

    /// The pane's card in whichever lane holds it, a folded section included.
    public func card(_ pane: PaneID) -> MissionCard? {
        let rest = atRest.flatMap { $0.groups.flatMap(\.cards) }
        return (needsYou.flatMap(\.cards) + working.flatMap(\.cards) + rest).first { $0.paneID == pane }
    }

    /// The drawn lanes, top to bottom, for the keyboard. A folded section's
    /// cards are not drawn.
    public var columns: [[PaneID]] {
        let rest = atRest.filter { !$0.isCollapsed }.flatMap { $0.groups.flatMap(\.cards) }
        return [needsYou.flatMap(\.cards).map(\.paneID), working.flatMap(\.cards).map(\.paneID), rest.map(\.paneID)]
    }

    /// One group per workspace, in the order each workspace's first card
    /// appears, each keeping its cards in the order given.
    static func grouped(_ cards: [MissionCard]) -> [MissionGroup] {
        var groups: [MissionGroup] = []
        var index: [WorkspaceID: Int] = [:]
        for card in cards {
            if let at = index[card.workspaceID] {
                let group = groups[at]
                groups[at] = MissionGroup(workspaceID: group.workspaceID, name: group.name, cards: group.cards + [card])
            } else {
                index[card.workspaceID] = groups.count
                groups.append(MissionGroup(workspaceID: card.workspaceID, name: card.workspaceName, cards: [card]))
            }
        }
        return groups
    }

    /// The pane's card as the board draws it, without building the board:
    /// which lane holds a card never changes how the card reads.
    public static func card(
        _ pane: PaneID, model: SessionModel, sections: RailSections, toasts: AttentionToastStack, history: PaneStatusHistory,
        backgroundWork: [PaneID: String] = [:], oneTitle: Bool = false
    ) -> MissionCard? {
        guard let record = model.panes[pane] else { return nil }
        let names = workspaceNames(model: model, sections: sections)
        if let toast = toasts.toast(pane: pane) {
            return MissionCard(
                record, status: ShownStatus(toast.status), since: toast.raisedAt, model: model, names: names, oneTitle: oneTitle
            )
        }
        return MissionCard(
            record, status: ShownStatus.of(record, backgroundWork: backgroundWork), since: history.lastChange(of: pane),
            model: model, names: names, oneTitle: oneTitle
        )
    }

    static func workspaceNames(model: SessionModel, sections: RailSections) -> [WorkspaceID: String] {
        var names: [WorkspaceID: String] = Dictionary(model.workspaces.map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        for herd in sections.herds {
            names[herd.workspaceID] = "\(herd.name) · herd \(herd.done)/\(herd.total)"
        }
        return names
    }

    public init(
        model: SessionModel, sections: RailSections, toasts: AttentionToastStack,
        history: PaneStatusHistory, backgroundWork: [PaneID: String] = [:], now: Date, calendar: Calendar = .current,
        opensOlder: Bool = false, opensUnknown: Bool = false, oneTitle: Bool = false
    ) {
        let rank = Dictionary(sections.railOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Self.workspaceNames(model: model, sections: sections)

        func card(_ pane: PaneRecord, status: ShownStatus, since: Date?) -> MissionCard {
            MissionCard(pane, status: status, since: since, model: model, names: names, oneTitle: oneTitle)
        }

        func railKey(_ pane: PaneRecord) -> (Int, Int, String) {
            let tabIndex = model.tabs[pane.workspaceID]?.firstIndex { $0.tabID == pane.tabID } ?? Int.max
            return (rank[pane.workspaceID] ?? Int.max, tabIndex, pane.paneID.rawValue)
        }

        let toasted = Set(toasts.toasts.map(\.paneID))
        needsYou = Self.grouped(toasts.toasts.reversed().compactMap { toast in
            model.panes[toast.paneID].map { card($0, status: ShownStatus(toast.status), since: toast.raisedAt) }
        })

        var working: [PaneRecord] = []
        var resting: [(PaneRecord, Date?)] = []
        for pane in model.panes.values where !toasted.contains(pane.paneID) {
            if ShownStatus.of(pane, backgroundWork: backgroundWork).status == .working {
                working.append(pane)
            } else {
                resting.append((pane, history.lastChange(of: pane.paneID)))
            }
        }

        var groups: [MissionGroup] = []
        for pane in working.sorted(by: { railKey($0) < railKey($1) }) {
            let next = card(
                pane, status: ShownStatus.of(pane, backgroundWork: backgroundWork), since: history.lastChange(of: pane.paneID)
            )
            if let last = groups.last, last.workspaceID == pane.workspaceID {
                groups[groups.count - 1] = MissionGroup(workspaceID: last.workspaceID, name: last.name, cards: last.cards + [next])
            } else {
                groups.append(MissionGroup(workspaceID: pane.workspaceID, name: next.workspaceName, cards: [next]))
            }
        }
        self.working = groups
        let known = resting.compactMap { pane, since in
            since.map { (pane, $0) }
        }
        let unknown = resting.filter { $0.1 == nil }.map(\.0).sorted { railKey($0) < railKey($1) }
        let recentFirst = known
            .sorted { ($0.1, $1.0.paneID.rawValue) > ($1.1, $0.0.paneID.rawValue) }
            .map { card($0.0, status: ShownStatus($0.0.agentStatus), since: $0.1) }
            + unknown.map { card($0, status: ShownStatus($0.agentStatus), since: nil) }
        let byAge = Dictionary(grouping: recentFirst) { RestAge.of($0.since, now: now, calendar: calendar) }
        atRest = RestAge.allCases.compactMap { age in
            guard let cards = byAge[age] else { return nil }
            let collapsible = (age == .older || age == .unknown) && cards.count > MissionRestSection.collapsibleOver
            let opened = age == .unknown ? opensUnknown : opensOlder
            return MissionRestSection(
                age: age, groups: Self.grouped(cards), count: cards.count,
                isCollapsible: collapsible, isCollapsed: collapsible && !opened
            )
        }
    }
}

public enum MissionSelection {
    public enum Direction: Equatable, Sendable { case up, down, left, right }

    /// The selection while a drawn card holds it, else the first drawn card:
    /// a pane folded away or closed is never the selection. Nil with no card.
    public static func resolve(_ selection: PaneID?, in columns: [[PaneID]]) -> PaneID? {
        if let selection, columns.contains(where: { $0.contains(selection) }) { return selection }
        return columns.first { !$0.isEmpty }?.first
    }

    /// Up and down stay in a lane; left and right go to the nearest row of the
    /// next lane that has cards. With nothing selected, the first card.
    public static func move(_ selection: PaneID?, _ direction: Direction, in columns: [[PaneID]]) -> PaneID? {
        guard let selection,
              let column = columns.firstIndex(where: { $0.contains(selection) }),
              let row = columns[column].firstIndex(of: selection)
        else { return columns.first { !$0.isEmpty }?.first }
        switch direction {
        case .up: return columns[column][max(0, row - 1)]
        case .down: return columns[column][min(columns[column].count - 1, row + 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var next = column + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return selection
        }
    }
}

/// The keys mission control takes while it is shown, whatever holds the
/// window's first responder.
public enum MissionKey {
    public enum Decision: Equatable, Sendable {
        case move(MissionSelection.Direction)
        case open
        case pass
    }

    /// A modified key is someone else's: a menu shortcut, or a selection
    /// gesture this view does not have. While a text field is up every key
    /// is the field's.
    public static func decide(
        keyCode: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool, editingText: Bool = false
    ) -> Decision {
        guard !editingText, !command, !control, !option, !shift else { return .pass }
        switch keyCode {
        case 126: return .move(.up)
        case 125: return .move(.down)
        case 123: return .move(.left)
        case 124: return .move(.right)
        case 36, 76: return .open
        default: return .pass
        }
    }
}

public enum MissionAge {
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
