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
    /// The one tab the item lives in. A runner's attach tabs sit beside it in
    /// its workspace and are views onto services, never the item's own.
    public let tabID: TabID
    /// Where the typed lines go, and whose idleness ends a run's phase 1.
    public let firstPaneID: PaneID
    public var title: String
    public let folder: String
    public var isRunning: Bool
    /// Whether the command has held its pane's foreground, or has ended.
    /// Until then the pane shows only the shell's prompt and the typed line.
    public var started: Bool
    public var strip: RtStrip?

    public init(
        id: String, kind: RtKind, linked: TerminalID, workspaceID: WorkspaceID, tabID: TabID, firstPaneID: PaneID,
        title: String, folder: String, isRunning: Bool, started: Bool, strip: RtStrip?
    ) {
        self.id = id
        self.kind = kind
        self.linked = linked
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.firstPaneID = firstPaneID
        self.title = title
        self.folder = folder
        self.isRunning = isRunning
        self.started = started
        self.strip = strip
    }

    public var runRow: RtRunRow {
        switch strip {
        case .exited(let status):
            return RtRunRow(id: id, title: title, state: "exited\(status.map { " \($0)" } ?? "")", tone: .exited)
        case .finished(let status):
            return RtRunRow(id: id, title: title, state: "finished\(status.map { " · exit \($0)" } ?? "")", tone: .finished)
        case nil:
            return RtRunRow(id: id, title: title, state: isRunning ? "running" : "finished", tone: isRunning ? .running : .finished)
        }
    }

    public func modalTitle(home: String) -> String {
        let name = kind == .run ? title : kind.rawValue
        return "\(name) · \(RtPaths.tilde(folder, home: home))"
    }
}

public enum RtPaths {
    public static func tilde(_ folder: String, home: String) -> String {
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
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
        /// `count` is running rt run items only; a live runner is the pill's
        /// second half, never counted again.
        case active(count: Int, runner: Bool)
    }

    public static func appearance(rtInstalled: Bool, runningItems: Int, hasRunner: Bool) -> Appearance {
        guard rtInstalled else { return .absent }
        guard runningItems > 0 || hasRunner else { return .rest }
        return .active(count: runningItems, runner: hasRunner)
    }
}

public struct RtCommandRow: Equatable, Sendable, Identifiable {
    public let kind: RtKind
    public let title: String
    /// rt's own command, shown so the popover teaches it.
    public let hint: String

    public var id: RtKind { kind }
}

public struct RtRunRow: Equatable, Sendable, Identifiable {
    public enum Tone: Equatable, Sendable { case running, finished, exited }

    public let id: String
    public let title: String
    public let state: String
    public let tone: Tone

    public init(id: String, title: String, state: String, tone: Tone) {
        self.id = id
        self.title = title
        self.state = state
        self.tone = tone
    }
}

public enum RtPopoverModel {
    public static func commands(hasRunner: Bool) -> [RtCommandRow] {
        [
            RtCommandRow(kind: .nav, title: "Browse files", hint: "rt nav"),
            RtCommandRow(kind: .glitter, title: "Git status", hint: "rt glitter"),
            RtCommandRow(kind: .run, title: "Run a script…", hint: "rt run"),
            RtCommandRow(kind: .runner, title: hasRunner ? "Show runner" : "Start runner", hint: "rt runner"),
        ]
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
