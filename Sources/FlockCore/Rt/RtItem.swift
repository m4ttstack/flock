import Foundation

public enum RtStrip: Equatable, Sendable {
    case exited(Int32?)
    case finished(Int32?)

    public var text: String {
        switch self {
        case .exited(let status):
            return "exited\(status.map { " \($0)" } ?? "") · any key closes"
        case .finished(let status):
            return "finished\(status.map { " · exit \($0)" } ?? "") · any key closes"
        }
    }
}

extension RtKind {
    public var defaultTitle: String {
        switch self {
        case .nav: "nav"
        case .glitter: "glitter"
        case .run: "rt run"
        case .runner: "runner"
        }
    }
}

/// One thing a pane opened through rt, living in a hidden tab (a runner, in
/// its own hidden workspace), linked to that pane by its terminal.
public struct RtItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: RtKind
    public let linked: TerminalID
    public let workspaceID: WorkspaceID
    /// The tab flock opened first; tabs rt placed for "Launch all" follow it.
    public var tabIDs: [TabID]
    /// Where the typed lines go, and whose idleness ends a run's phase 1.
    public let firstPaneID: PaneID
    public var title: String
    public let folder: String
    public var isRunning: Bool
    public var strip: RtStrip?

    public init(
        id: String, kind: RtKind, linked: TerminalID, workspaceID: WorkspaceID, tabIDs: [TabID], firstPaneID: PaneID,
        title: String, folder: String, isRunning: Bool, strip: RtStrip?
    ) {
        self.id = id
        self.kind = kind
        self.linked = linked
        self.workspaceID = workspaceID
        self.tabIDs = tabIDs
        self.firstPaneID = firstPaneID
        self.title = title
        self.folder = folder
        self.isRunning = isRunning
        self.strip = strip
    }

    public var stateText: String {
        switch strip {
        case .exited: "exited"
        case .finished: "finished"
        case nil: isRunning ? "running" : "finished"
        }
    }

    public func modalTitle(home: String) -> String {
        let name = kind == .run ? title : kind.rawValue
        let place: String
        if folder == home {
            place = "~"
        } else if folder.hasPrefix(home + "/") {
            place = "~" + folder.dropFirst(home.count)
        } else {
            place = folder
        }
        return "\(name) · \(place)"
    }
}

public struct RtModal: Equatable, Sendable {
    public let itemID: String
    public var tabID: TabID
    /// A runner's service on screen instead of its board.
    public var serviceTabID: TabID?

    public init(itemID: String, tabID: TabID, serviceTabID: TabID?) {
        self.itemID = itemID
        self.tabID = tabID
        self.serviceTabID = serviceTabID
    }

    public var shownTabID: TabID { serviceTabID ?? tabID }
}

public enum RtButtonModel {
    public enum Appearance: Equatable, Sendable {
        case absent
        case rest
        case active(count: Int)
    }

    public static func appearance(rtInstalled: Bool, runningItems: Int, hasRunner: Bool) -> Appearance {
        guard rtInstalled else { return .absent }
        let count = runningItems + (hasRunner ? 1 : 0)
        return count > 0 ? .active(count: count) : .rest
    }
}

public struct RtMenuRow: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(RtKind)
        case show(String)
    }

    public let title: String
    public let action: Action
    public let startsSection: Bool
}

public enum RtMenuModel {
    public static func rows(hasRunner: Bool, runItems: [RtItem]) -> [RtMenuRow] {
        var rows = [
            RtMenuRow(title: "nav · browse files here", action: .open(.nav), startsSection: false),
            RtMenuRow(title: "glitter · git status", action: .open(.glitter), startsSection: false),
            RtMenuRow(title: "run · run a script…", action: .open(.run), startsSection: false),
            RtMenuRow(title: hasRunner ? "Show runner" : "runner", action: .open(.runner), startsSection: false),
        ]
        for (index, item) in runItems.enumerated() {
            rows.append(RtMenuRow(title: "\(item.title) · \(item.stateText)", action: .show(item.id), startsSection: index == 0))
        }
        return rows
    }
}

/// Which keys the modal takes before the terminal and the window see them:
/// ⌘W, which would otherwise close the window, and, while a strip is up, any
/// plain key. Other ⌘ keys always pass, so a strip never swallows ⌘Q.
public enum RtModalKey {
    public enum Decision: Equatable, Sendable { case close, pass }

    public static func decide(
        characters: String?, command: Bool, shift: Bool, option: Bool, control: Bool, stripShown: Bool
    ) -> Decision {
        if command, !shift, !option, !control, characters?.lowercased() == "w" { return .close }
        if stripShown, !command { return .close }
        return .pass
    }
}
