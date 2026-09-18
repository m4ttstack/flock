import Foundation

/// The set of directories flock resolves the tools it runs in -- `herdr` for
/// every pane's bridge, the agent CLIs the launcher offers.
///
/// A process inherits its PATH from whatever started it, and for a GUI app
/// that is launchd, whose PATH carries none of the directories a user's shell
/// profile adds. The same app started from a terminal inherits the profile's
/// PATH and finds everything. So the directory a tool lives in is a property
/// of how flock was launched, which is why the answer is merged here rather
/// than read straight out of the environment at each lookup.
///
/// Pure: asking a shell what its PATH is belongs to the app (`ToolPath`),
/// which passes the answer through `merged`.
public enum UserPath {
    /// The directories of a PATH string, in order.
    ///
    /// An empty entry is POSIX's spelling of the current directory. flock
    /// resolves binaries it is about to run, so it drops them rather than
    /// search whatever directory a launch happened to start in.
    public static func entries(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    /// The inherited PATH, plus every directory the login shell reported that
    /// it did not already carry.
    ///
    /// Strictly additive, in both senses: no inherited entry is ever dropped,
    /// and every inherited entry keeps its precedence over the added ones. A
    /// launch that already had a good PATH therefore resolves every tool to
    /// exactly the binary it resolved before, and a launch that had launchd's
    /// gains the profile's directories at the back. `nil` is a shell that gave
    /// no usable answer (failed to start, exited non-zero, or was still
    /// running when the probe gave up) and leaves the inherited PATH untouched.
    public static func merged(inherited: String, loginShell: String?) -> String {
        var seen = Set<String>()
        var merged: [String] = []
        for entry in entries(inherited) + entries(loginShell ?? "") where seen.insert(entry).inserted {
            merged.append(entry)
        }
        return merged.joined(separator: ":")
    }

    /// The first executable named `name` on `path`, or nil when no directory
    /// on it holds one. Searched in PATH order, which is the order a shell
    /// would have picked from.
    public static func resolve(
        _ name: String,
        on path: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        entries(path).lazy.map { "\($0)/\(name)" }.first(where: isExecutable)
    }
}
