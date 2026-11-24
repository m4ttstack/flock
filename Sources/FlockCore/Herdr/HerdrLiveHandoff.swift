import Foundation

/// flock running `herdr server live-handoff` itself, to move the running
/// server onto the binary on disk without ending any pane.
public enum HerdrLiveHandoff {
    /// herdr's own lines, as v0.9.5 prints them: `server live-handoff` says
    /// "live handoff complete"; a handoff that errored but left the new
    /// server running says the second.
    private static let handoffLinePrefixes = ["live handoff complete", "the updated server is running for "]

    /// `server live-handoff` reads no stdin. `--import-exe` hands off to the
    /// binary flock resolved rather than whatever path the old server was
    /// started from; `--expected-version` makes the new server refuse the
    /// handoff, and the old one keep running, if that binary is not it.
    public static func liveHandoffArguments(binaryPath: String, expectedVersion: String) -> [String] {
        ["server", "live-handoff", "--import-exe", binaryPath, "--expected-version", expectedVersion]
    }

    public static func handedOff(status: Int32, output: String) -> Bool {
        status == 0 && lines(output).contains { line in handoffLinePrefixes.contains { line.hasPrefix($0) } }
    }

    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
