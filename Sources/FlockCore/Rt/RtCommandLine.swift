import Foundation

public enum ShellFlavor: Equatable, Sendable {
    case posix, fish

    /// A login shell's name carries a leading `-` (`-zsh`).
    public init(processName: String?) {
        let name = (processName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        self = name.hasSuffix("fish") ? .fish : .posix
    }

    var statusVariable: String {
        switch self {
        case .posix: "$?"
        case .fish: "$status"
        }
    }
}

/// The lines flock types into a hidden rt pane. `command` skips a user's
/// `rt()` shell function, so a result lands in the file rather than in a `cd`;
/// the suffix records the exit status, the one signal that separates a clean
/// quit from an error.
public enum RtCommandLine {
    /// Single quotes, with an embedded quote closed, escaped and reopened. The
    /// same spelling works in POSIX shells and fish.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `seeded` reads a queue or preset's rows from the path the tab's env
    /// names as `FLOCK_RT_SEED`, never quoted into the line.
    public static func command(for kind: RtKind, shell: ShellFlavor, seeded: Bool = false) -> String {
        let body: String
        switch kind {
        case .nav: body = #"command rt nav >"$FLOCK_RT_OUT""#
        case .glitter: body = "command rt glitter"
        case .run: body = #"command rt run --resolve-only >"$FLOCK_RT_OUT""#
        case .runner: body = seeded ? #"command rt runner --herdr --seed-file "$FLOCK_RT_SEED""# : "command rt runner --herdr"
        }
        return body + statusSuffix(shell)
    }

    public static func phaseTwo(_ result: RunResolveResult, shell: ShellFlavor) -> String {
        "cd \(quoted(result.targetDir)) && \(result.commandTemplate)" + statusSuffix(shell)
    }

    public static func cd(_ path: String) -> String {
        "cd \(quoted(path))"
    }

    private static func statusSuffix(_ shell: ShellFlavor) -> String {
        #"; echo \#(shell.statusVariable) >"$FLOCK_RT_STATUS""#
    }
}
