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
    /// Per flavor, so Flock and Flock Dev can both be installed at once.
    public static func name(bundleID: String?) -> String {
        bundleID == "dev.mattstack.Flock.dev" ? "flock-dev" : "flock"
    }

    /// `linkTarget` is the symlink's destination when the path is a symlink,
    /// dangling or not; `exists` counts the link itself, not what it names.
    public static func state(exists: Bool, linkTarget: String?, executablePath: String) -> CommandLineToolState {
        guard exists else { return .notInstalled }
        guard let linkTarget else { return .otherFile }
        return linkTarget == executablePath ? .installed : .otherLink(target: linkTarget)
    }

    public static let heading = "Command Line"

    public static func rowTitle(name: String) -> String {
        "\(name) release"
    }

    public static func body(for state: CommandLineToolState, linkPath: String) -> String {
        let what = "Hides Flock so herdr fits its panes to your phone."
        switch state {
        case .notInstalled:
            return "\(what) Installs to \(linkPath); ssh needs its folder on the PATH in ~/.zshenv."
        case .installed:
            return "\(what) Installed at \(linkPath)."
        case .otherLink(let target):
            return "\(linkPath) points at \(target). Replace links it to this Flock."
        case .otherFile:
            return "\(linkPath) is a file Flock did not put there, so Flock leaves it alone."
        }
    }

    public static func actionTitle(for state: CommandLineToolState) -> String? {
        switch state {
        case .notInstalled: "Install"
        case .installed: "Remove"
        case .otherLink: "Replace"
        case .otherFile: nil
        }
    }
}
