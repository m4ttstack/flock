import Foundation

/// flock running `herdr update --handoff` itself. With stdin not a terminal,
/// herdr takes its non-interactive paths: a prompt it cannot ask becomes an
/// error exit or a "no", never a wait.
public enum HerdrUpdateRun {
    public static let arguments = ["update", "--handoff"]

    public static let buttonTitle = "Update herdr"
    public static let progressTitle = "Updating herdr..."
    public static let pillTitle = "Updating herdr"

    public enum Outcome: Equatable, Sendable {
        /// herdr printed that the running server handed off.
        case updated
        /// herdr replaced the binary on disk but the server did not hand off
        /// (it declines to stop an old server without a terminal). Carries
        /// the version from herdr's `installed X` line, when it printed one.
        case installedWithoutHandoff(String?)
        /// herdr found nothing newer; carries the version of the binary on
        /// disk, which a server started earlier can still be behind.
        case alreadyUpToDate(String)
        /// Exit 0 with neither a handoff nor a new binary.
        case notHandedOff
        case failed(String)
    }

    public static let notHandedOffMessage = "herdr didn't hand off to the new version. Nothing else was changed."
    public static let serverBehindMessage =
        "herdr is already updated on disk but the running server is older. Restart herdr's server to finish."

    /// herdr's own lines, as v0.9.5 prints them: `update --handoff` and
    /// `server live-handoff` both say "live handoff complete"; a handoff that
    /// errored but left the new server running says the second.
    private static let handoffLinePrefixes = ["live handoff complete", "the updated server is running for "]
    private static let upToDatePrefix = "already up to date ("
    private static let installedPrefix = "installed "

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

    public static func confirmation(for notice: HerdrUpdateNotice) -> HerdrMousePatchCopy.Confirmation {
        let latest = switch notice {
        case .available(let latest, _, _, _), .breaksMouse(let latest, _, _): latest
        }
        var message = "flock runs herdr update --handoff. Your panes keep running; Flock restarts afterwards to reconnect them."
        if notice.isWarning {
            message += " Mouse support turns off until a flock update adds a patch for \(latest)."
        }
        return HerdrMousePatchCopy.Confirmation(
            title: "Update herdr to \(latest)?", message: message, confirmButtonTitle: "Update"
        )
    }

    /// herdr ends every failure on one line, prefixed `update failed: ` unless
    /// it is a package-manager refusal; the prefix would only repeat the
    /// sentence it is quoted into.
    public static func outcome(status: Int32, output: String, binaryChanged: Bool) -> Outcome {
        guard status == 0 else { return failure(status: status, output: output) }
        if handedOff(status: status, output: output) { return .updated }
        let all = lines(output)
        if binaryChanged {
            let versions = all.filter { $0.hasPrefix(installedPrefix) }
                .map { String($0.dropFirst(installedPrefix.count)) }
                .filter { !$0.isEmpty && !$0.contains(" ") }
            return .installedWithoutHandoff(versions.last)
        }
        if let line = all.first(where: { $0.hasPrefix(upToDatePrefix) && $0.hasSuffix(")") }) {
            return .alreadyUpToDate(String(line.dropFirst(upToDatePrefix.count).dropLast()))
        }
        return .notHandedOff
    }

    private static func failure(status: Int32, output: String) -> Outcome {
        guard var line = lines(output).last else { return .failed("herdr couldn't update: it exited with status \(status)") }
        let prefix = "update failed: "
        if line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        return .failed("herdr couldn't update: \(line)")
    }

    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
