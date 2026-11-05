/// The headless verbs, each as the argument vector it becomes.
///
/// `Process` takes an argument vector rather than a command line, so nothing
/// here is quoted or escaped: a body holding spaces or a leading dash is one
/// argument, and quoting it would send the quotes.
public enum ChatVerb: Equatable, Sendable {
    case status(pane: String)
    case signIn(pane: String)
    case signOut(pane: String)
    case peek
    case targets(pane: String)
    case quickSend(pane: String, to: String, body: String)
    case broadcast(panes: [String], body: String)
    case jump(handle: String)
    case openViewer(room: String?)
    case slackClose(pane: String)
    case slackPeople

    /// The pane rt acts for. These verbs take no pane argument, and rt names
    /// a caller with no pane after its folder, so an app started from `/`
    /// would read and post as an identity nobody signed in.
    public var callerPane: String? {
        switch self {
        case let .targets(pane), let .quickSend(pane, _, _): pane
        default: nil
        }
    }

    public var arguments: [String] {
        switch self {
        case let .status(pane): ["status", "--json", "--pane", pane]
        case let .signIn(pane): ["sign-in", "--json", "--pane", pane]
        case let .signOut(pane): ["sign-out", "--json", "--pane", pane]
        case .peek: ["peek", "--json"]
        case .targets: ["targets", "--json"]
        case let .quickSend(_, to, body): ["quick-send", "--json", "--to", to, "--body", body]
        case let .broadcast(panes, body):
            ["broadcast", "--json", "--panes", panes.joined(separator: ","), "--body", body]
        case let .jump(handle): ["jump", "--json", "--handle", handle]
        case let .openViewer(room):
            ["open-viewer", "--json"] + (room.map { ["--room", $0] } ?? [])
        case let .slackClose(pane): ["slack-close", "--json", "--pane", pane]
        case .slackPeople: ["slack-people", "--json"]
        }
    }
}
