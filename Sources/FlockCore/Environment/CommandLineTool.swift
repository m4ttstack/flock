import Foundation

/// What sits where the Settings row would put the `flock` command.
public enum CommandLineToolState: Equatable, Sendable {
    case notInstalled
    case installed
    /// A symlink to some other binary, e.g. a Flock since moved or deleted.
    case otherLink(target: String)
    /// A real file, which Settings never overwrites.
    case otherFile
}

public enum CommandLineTool {
    /// One name for every flavor: each command acts on whichever Flocks are
    /// running, so it does not matter which one's binary the link names.
    public static let name = "flock"

    /// `linkTarget` is the symlink's destination when the path is a symlink,
    /// dangling or not; `exists` counts the link itself, not what it names.
    /// A link to any Flock counts as installed, so Flock and Flock Dev never
    /// offer to replace each other's.
    public static func state(
        exists: Bool, linkTarget: String?, isFlock: (String) -> Bool
    ) -> CommandLineToolState {
        guard exists else { return .notInstalled }
        guard let linkTarget else { return .otherFile }
        return isFlock(linkTarget) ? .installed : .otherLink(target: linkTarget)
    }

    public static let heading = "Command Line"
    public static let rowTitle = "Shell command"

    public static func body(for state: CommandLineToolState, name: String, linkPath: String) -> String {
        switch state {
        case .notInstalled:
            return "Install \(name) in your PATH to control Flock from a terminal or over ssh. "
                + "Over ssh, ~/.local/bin must be on the PATH in ~/.zshenv."
        case .installed:
            return "\(name) is installed at \(linkPath). Run \(name) help to see its commands."
        case .otherLink(let target):
            return "\(linkPath) points at \(target). Replace links it to this Flock."
        case .otherFile:
            return "\(linkPath) is a file Flock did not put there, so Flock leaves it alone."
        }
    }

    public static func actionTitle(for state: CommandLineToolState) -> String? {
        switch state {
        case .notInstalled: "Install"
        case .installed: "Uninstall"
        case .otherLink: "Replace"
        case .otherFile: nil
        }
    }
}

/// A `flock` subcommand, from the process's arguments.
public enum FlockCommand: Equatable, Sendable {
    case release
    /// Release, then run herdr in this terminal with these arguments.
    case attach([String])
    case help
    case unknown(String)

    /// Every command `flock help` lists, in order.
    public static let summaries: [(name: String, summary: String)] = [
        ("release", "Hide Flock so herdr sizes its panes for your other clients. Click Flock to take them back."),
        ("attach", "Release, then open herdr here. Arguments after attach go to herdr."),
        ("help", "Show this list."),
    ]

    /// The names the installed link can have, `flock-dev` from builds that
    /// installed one per flavor. Matched case-sensitively: the bundle's own
    /// binaries are `Flock` and `Flock-dev`.
    public static let linkNames: Set<String> = ["flock", "flock-dev"]

    /// nil means launch the app. Through the installed link every invocation
    /// is a command, so a bare `flock` prints help rather than opening a
    /// second Flock. Through the bundle's own binary only a named command is:
    /// Finder and launchd pass arguments of their own.
    ///
    /// Decided from `invokedAs` alone because a process started through the
    /// link has no main bundle to ask which flavor it is.
    public static func parse(invokedAs: String, arguments: [String]) -> FlockCommand? {
        let viaLink = linkNames.contains(invokedAs)
        switch arguments.first {
        case "release": return .release
        case "attach": return .attach(Array(arguments.dropFirst()))
        case "help", "-h", "--help": return .help
        case let other?: return viaLink ? .unknown(other) : nil
        case nil: return viaLink ? .help : nil
        }
    }

    public static func usage(name: String) -> String {
        let width = summaries.map(\.name.count).max() ?? 0
        let lines = summaries.map { "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        return (["usage: \(name) <command>", "", "commands:"] + lines).joined(separator: "\n")
    }
}
